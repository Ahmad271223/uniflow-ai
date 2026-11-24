"""Probe nur einmal je Person und Geraet, auch nach "Konto loeschen" (Auftrag des Inhabers vom 24.11.2026).

Luecke vorher: die Probe hing nur am Konto (billing.start_trial). Wer sein Konto loeschte und sich neu anmeldete, bekam
ein neues Konto und damit neue 7 Tage; ebenso eine zweite Apple-ID auf demselben Geraet. Die Geraete-Marke der App
(LocalTrial.swift) half nicht, weil die App eine laufende Probe des Dienstes mit Vorrang uebernimmt (UFPlanPrecedence).

Regel jetzt: der Dienst merkt sich, dass eine Kennung ihre Probe schon hatte, und bis wann sie lief:
- Anmeldung beim Anbieter (Apple-/Google-Kennung `sub`) und E-Mail-Adresse: beim Anlegen des Kontos und beim Loeschen
  (dann mit dem tatsaechlichen Ende, auch fuer Konten von vor dieser Regel und fuer vom Betrieb verlaengerte Proben).
- Geraet (`device_id` der Apps): beim Anlegen, bei jeder Anmeldung eines Kontos mit Probe und beim Loeschen. Web
  schickt keine Kennung und zaehlt nicht.
Ein neues Konto, dessen Kennung schon bekannt ist, bekommt keine neue Probe, sondern die alte: laeuft sie noch, laeuft
sie bis zum alten Ende weiter (mit den schon verbrauchten Probe-Credits des Monats); ist sie vorbei, beginnt das Konto
im Stand "Probe vorbei" (Tarifwahl wie nach jeder Probe). Bei mehreren Treffern gilt das frueheste Ende.

Gespeichert wird nie die Kennung selbst, nur ein HMAC-SHA256 mit dem Dienst-Geheimnis (vault.master_key, wie die
Community-Pseudonyme) und das Ende der Probe - ohne Konto-ID, deshalb bleibt der Eintrag nach dem endgueltigen Loeschen
des Kontos stehen. Eintraege fallen `KEEP_DAYS` nach ihrer letzten Aenderung weg (accounts.purge_deleted).
Der Betrieb kann weiterhin jedem Konto eine Probe geben oder verlaengern (app/tester_freischalten.py, Geschenk-Tarif).
"""
from __future__ import annotations

import hashlib
import hmac
import sqlite3
from datetime import datetime, timedelta, timezone

from . import billing, plans

# Aufbewahrung der Eintraege nach der letzten Aenderung (3 Jahre)
KEEP_DAYS = 1095
IDENTITY_KINDS = ("apple", "google", "email")
BACKFILL_MARK = "backfill-v1"

SCHEMA = """
CREATE TABLE IF NOT EXISTS trial_claims (
    key TEXT PRIMARY KEY,                -- HMAC-SHA256 ueber "<art>:<kennung>", nie die Kennung selbst
    kind TEXT NOT NULL,                  -- apple | google | email | device | meta
    trial_ends_at TEXT NOT NULL,         -- Ende der Probe, die diese Kennung schon bekommen hat
    credits_period TEXT,                 -- Monat (YYYY-MM, Europe/Berlin) der verbrauchten Probe-Credits
    credits_used INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
"""


def _iso(t: datetime) -> str:
    return t.astimezone(timezone.utc).replace(microsecond=0).isoformat()


def _missing(e: sqlite3.OperationalError) -> bool:
    """Fehlt nur eine Tabelle (frische Datei, reine Konten-Datei in Tests)? Alles andere bleibt ein Fehler."""
    return "no such table" in str(e)


def claim_key(kind: str, value: str) -> str:
    from . import vault                                     # spaet: vault importiert accounts
    return hmac.new(vault.master_key(), f"trial-claim:{kind}:{value}".encode("utf-8"), hashlib.sha256).hexdigest()


def keys_for(email: str | None = None, identities=(), devices=()) -> list[tuple[str, str]]:
    """(Art, Schluessel) je Kennung; leere Werte und die Platzhalter-Adresse geloeschter Konten fallen weg."""
    out: list[tuple[str, str]] = []
    mail = (email or "").strip().lower()
    if mail and not mail.endswith("@invalid"):
        out.append(("email", claim_key("email", mail)))
    for provider, subject in identities:
        if provider and subject:
            out.append((str(provider), claim_key(str(provider), str(subject))))
    for d in devices:
        d = (d or "").strip()[:80]                          # wie sessions.device_id (accounts.create_session)
        if d:
            out.append(("device", claim_key("device", d)))
    seen, unique = set(), []
    for kind, key in out:
        if key not in seen:
            seen.add(key)
            unique.append((kind, key))
    return unique


def lookup(conn: sqlite3.Connection, keys: list[tuple[str, str]]) -> dict | None:
    """Der strengste Treffer (fruehestes Ende) unter den Kennungen, sonst None."""
    best = None
    for _, key in keys:
        r = conn.execute("SELECT trial_ends_at, credits_period, credits_used FROM trial_claims WHERE key=?", (key,)).fetchone()
        if not r:
            continue
        ends = billing._parse_utc(r[0])
        if ends is None:
            continue
        if best is None or ends < best["ends"]:
            best = {"ends": ends, "ends_at": r[0], "credits_period": r[1], "credits_used": int(r[2] or 0)}
    return best


def remember(conn: sqlite3.Connection, keys: list[tuple[str, str]], ends_at: str, now: datetime, *,
             overwrite_identity: bool = False, credits_period: str | None = None, credits_used: int = 0) -> None:
    """Eintraege anlegen. Vorhandene bleiben, wie sie sind - ausser `overwrite_identity` (Loeschen): dann bekommen
    Anbieter-Kennung und Adresse das tatsaechliche Ende und den Credit-Stand des Kontos. Geraete werden nie
    ueberschrieben: ein Geraet kann mehrere Konten gesehen haben, es gilt seine erste Probe."""
    t = _iso(now)
    for kind, key in keys:
        conn.execute("INSERT OR IGNORE INTO trial_claims(key, kind, trial_ends_at, credits_period, credits_used, created_at, updated_at) "
                     "VALUES (?,?,?,?,?,?,?)", (key, kind, ends_at, credits_period, int(credits_used or 0), t, t))
        if overwrite_identity and kind in IDENTITY_KINDS:
            conn.execute("UPDATE trial_claims SET trial_ends_at=?, credits_period=?, credits_used=?, updated_at=? WHERE key=?",
                         (ends_at, credits_period, int(credits_used or 0), t, key))


def grant(conn: sqlite3.Connection, user_id: str, keys: list[tuple[str, str]], now: datetime | None = None) -> dict:
    """Probe fuer ein NEUES Konto in der Transaktion des Aufrufers: neu (billing.start_trial), wenn keine Kennung
    bekannt ist; sonst die schon gewaehrte Probe mit ihrem alten Ende. Liefert {"ends_at", "inherited", "active"}."""
    t = billing._now(now)
    claim = lookup(conn, keys)
    if claim is None:
        out = billing.start_trial(conn, user_id, t)
        if out is None:                                     # Konto hat schon eine Probe: nichts aendern
            return {"ends_at": None, "inherited": False, "active": False}
        remember(conn, keys, out["ends_at"], t)
        return {"ends_at": out["ends_at"], "inherited": False, "active": True}
    active = claim["ends"] > t
    billing.set_entitlement(conn, str(user_id), "trial", plans.TRIAL["plan"], expires_at=claim["ends_at"],
                            status="active" if active else "expired", will_renew=False, now=t)
    if active:
        _carry_credits(conn, str(user_id), claim, t)
    remember(conn, keys, claim["ends_at"], t)               # neue Kennungen (z. B. das neue Geraet) kennen die Probe jetzt auch
    return {"ends_at": claim["ends_at"], "inherited": True, "active": active}


def _carry_credits(conn: sqlite3.Connection, user_id: str, claim: dict, t: datetime) -> None:
    """Schon verbrauchte Probe-Credits des laufenden Monats ins neue Konto uebernehmen: Loeschen und neu anmelden
    fuellt den Rahmen nicht wieder auf. Rahmen und Tarif der Zeile setzt credits._month beim ersten Zugriff."""
    from . import credits
    used = int(claim.get("credits_used") or 0)
    if used <= 0 or claim.get("credits_period") != credits.period_of(t):
        return
    try:
        conn.execute("INSERT OR IGNORE INTO credit_months(user_id, period, allowance, used, reserved, plan, created_at, updated_at) "
                     "VALUES (?,?,?,?,0,?,?,?)",
                     (user_id, claim["credits_period"], credits.allowance(plans.TRIAL["plan"], True), used,
                      plans.TRIAL["plan"] + ":trial", t.isoformat(), t.isoformat()))
    except sqlite3.OperationalError as e:
        if not _missing(e):
            raise


def _trial_end(conn: sqlite3.Connection, user_id: str) -> str | None:
    try:
        r = conn.execute("SELECT expires_at FROM entitlements WHERE user_id=? AND source='trial'", (str(user_id),)).fetchone()
    except sqlite3.OperationalError as e:
        if not _missing(e):
            raise
        return None
    return r[0] if r and r[0] else None


def note_device(conn: sqlite3.Connection, user_id: str, device_id: str | None, now: datetime | None = None) -> None:
    """Anmeldung eines Kontos mit Probe auf einem Geraet: das Geraet hat seine Probe damit gehabt (wie die
    Geraete-Marke der App). Ohne Kennung (Web) oder ohne Probe nichts."""
    keys = keys_for(devices=[device_id])
    if not keys:
        return
    ends = _trial_end(conn, user_id)
    if ends:
        remember(conn, keys, ends, billing._now(now))


def on_delete(conn: sqlite3.Connection, user_id: str, now: datetime | None = None) -> int:
    """Vor dem Loeschen (accounts._mark_deleted, solange Adresse, Anmeldewege und Sitzungen noch da sind): Kennungen
    des Kontos mit dem tatsaechlichen Ende seiner Probe festhalten. Gilt auch fuer Konten von vor dieser Regel.
    Ohne Probe nichts. Liefert die Zahl der Kennungen."""
    uid = str(user_id)
    ends = _trial_end(conn, uid)
    if not ends:
        return 0
    t = billing._now(now)
    u = conn.execute("SELECT email FROM users WHERE id=?", (uid,)).fetchone()
    idents = [(r[0], r[1]) for r in conn.execute("SELECT provider, subject FROM identities WHERE user_id=?", (uid,)).fetchall()]
    devices = [r[0] for r in conn.execute("SELECT DISTINCT device_id FROM sessions WHERE user_id=? AND device_id IS NOT NULL", (uid,)).fetchall()]
    keys = keys_for(u[0] if u else None, idents, devices)
    period, used = _credits_used(conn, uid, t)
    remember(conn, keys, ends, t, overwrite_identity=True, credits_period=period, credits_used=used)
    return len(keys)


def _credits_used(conn: sqlite3.Connection, user_id: str, t: datetime) -> tuple[str | None, int]:
    """Verbrauchte (und gerade gehaltene) Probe-Credits des laufenden Monats; (None, 0), wenn das Konto diesen Monat
    nicht als Probekonto gerechnet wurde."""
    from . import credits
    period = credits.period_of(t)
    try:
        r = conn.execute("SELECT used, reserved, plan FROM credit_months WHERE user_id=? AND period=?", (user_id, period)).fetchone()
    except sqlite3.OperationalError as e:
        if not _missing(e):
            raise
        return None, 0
    if not r or not str(r[2] or "").endswith(":trial"):
        return None, 0
    return period, int(r[0] or 0) + int(r[1] or 0)


def backfill(conn: sqlite3.Connection, now: datetime | None = None) -> int:
    """Einmalig beim ersten Start mit dieser Regel: Geraete aller Konten mit Probe eintragen (auch schon geloeschter
    Konten, deren Sitzungen bis zum endgueltigen Loeschen stehen). Anbieter-Kennung und Adresse aktiver Konten
    brauchen keinen Eintrag: sie fuehren ohnehin ins selbe Konto, und `on_delete` haelt sie beim Loeschen fest.
    Je Geraet gilt das frueheste Ende. Liefert die Zahl neuer Eintraege (0, wenn schon gelaufen)."""
    if conn.execute("SELECT 1 FROM trial_claims WHERE key=?", (BACKFILL_MARK,)).fetchone():
        return 0
    t = billing._now(now)
    try:
        rows = conn.execute("SELECT s.device_id, e.expires_at FROM sessions s JOIN entitlements e ON e.user_id=s.user_id "
                            "WHERE e.source='trial' AND e.expires_at IS NOT NULL AND s.device_id IS NOT NULL").fetchall()
    except sqlite3.OperationalError as e:
        if not _missing(e):
            raise
        rows = []                                           # frische Datei: nichts nachzutragen
    first: dict[str, tuple[datetime, str]] = {}
    for device, ends_at in rows:
        ends = billing._parse_utc(ends_at)
        if ends is not None and (device not in first or ends < first[device][0]):
            first[device] = (ends, ends_at)
    n = 0
    for device, (_, ends_at) in first.items():
        keys = keys_for(devices=[device])
        if keys and not conn.execute("SELECT 1 FROM trial_claims WHERE key=?", (keys[0][1],)).fetchone():
            remember(conn, keys, ends_at, t)
            n += 1
    conn.execute("INSERT OR IGNORE INTO trial_claims(key, kind, trial_ends_at, created_at, updated_at) VALUES (?,?,?,?,?)",
                 (BACKFILL_MARK, "meta", _iso(t), _iso(t), _iso(t)))
    return n


def purge_old(conn: sqlite3.Connection, days: int = KEEP_DAYS, now: datetime | None = None) -> int:
    """Eintraege entfernen, die seit `days` Tagen nicht mehr geaendert wurden (taeglich, accounts.purge_deleted)."""
    cutoff = _iso(billing._now(now) - timedelta(days=days))
    return conn.execute("DELETE FROM trial_claims WHERE kind<>'meta' AND updated_at<=?", (cutoff,)).rowcount
