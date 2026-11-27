"""Absturzmeldungen der Apple-Apps (25.11.2026, docs/ABSTURZMELDUNG-2026-11-25.md).

Wozu: der Inhaber will sehen, wie viele Abstuerze es je Tag, App-Version und Geraeteart gab. Bis heute meldete die App
nichts; Apples eigene Zahlen (Xcode Organizer) kommen mit Verzug und nur von Nutzern, die Diagnosedaten mit
Entwicklern teilen.

    POST /api/diagnose/crashes   {v, install, reports: [...]}   -> {ok, stored, duplicates, dropped}

Ohne Konto und ohne Sitzung (oeffentlicher Pfad, `PUBLIC`, hosted_guard in app/server.py). Gruende:
- Ein Absturz beim ersten Start oder in der Begruessung passiert, bevor es ein Konto gibt - genau diese Meldungen
  fehlten sonst.
- Datensparsamkeit: die Meldung braucht keinen Bezug zu einer Person. Gespeichert werden weder Konto, E-Mail,
  IP-Adresse noch eine dauerhafte Geraete-Kennung.

Was gespeichert wird (und nichts sonst; unbekannte Felder werden verworfen, nicht abgelegt):
- App-Version und Build, Geraeteart (iphone | ipad | mac), Modellkennung (z. B. "iPad14,3"), Systemversion, Quelle
  (store | test), Zeitpunkt
- Art: crash (Absturz), hang (Haenger), exit (Tageszaehlung von iOS: App im Vordergrund beendet, z. B. Speicher)
- Absturz: Signal, Ausnahme-Typ und -Code, Beendigungsgrund von iOS, Name der Ausnahme-Klasse (nie ihr Text)
- die oberste Aufrufkette: je Zeile Name der Programmdatei, Abstand in der Datei und deren Kennung (zum Zuordnen
  mit den Symboldateien des Builds). Keine Werte aus dem Speicher, keine Dateinamen, keine Dokumentinhalte.
- `device_day`: HMAC aus Eingangstag und der zufaelligen Installations-Kennung der App (Dienst-Geheimnis,
  vault.master_key). Damit laesst sich zaehlen, wie viele Geraete an einem Tag betroffen waren, und die Menge je Geraet
  und Tag begrenzen. Der Wert ist jeden Tag ein anderer: Tage lassen sich nicht verketten, und die Kennung selbst
  steht nirgends.

Grenzen: `MAX_REPORTS` Meldungen je Anfrage, `DEVICE_DAY_LIMIT` je Geraet und Tag, `DAY_TOTAL` insgesamt je Tag,
Anfragen je IP ueber accounts.rate_limits (Schluessel `crash_ip`; die Adresse steht dort wie bei `register_ip`
hoechstens zwei Tage und nie bei einer Meldung). Rumpf hoechstens 64 KB (PUBLIC_BODY_LIMITS in app/server.py).
Aufbewahrung: `KEEP_DAYS` Tage, dann loescht app/retention.py die Zeilen.

Auswertung: `python -m app.crash_reports` (im Container) bzw. `python tools/absturz-auswertung.py`.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import re
import sqlite3
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, HTTPException, Request

from . import account_api, accounts, config

PATH = "/api/diagnose/crashes"
# Ohne Sitzung erreichbar (hosted_guard); tests/test_rechte_alle_routen.py fuehrt die Liste der oeffentlichen Pfade
PUBLIC = {PATH}
router = APIRouter(prefix="/api/diagnose", tags=["diagnose"], route_class=account_api.NoStoreRoute)

VERSION = 1
KEEP_DAYS = 90                  # Aufbewahrung der Meldungen (app/retention.py)
MAX_REPORTS = 20                # Meldungen je Anfrage; mehr -> 400
DEVICE_DAY_LIMIT = 30           # gespeicherte Meldungen je Geraet und Eingangstag; weitere fallen weg
DAY_TOTAL = 5_000               # gespeicherte Meldungen aller Geraete je Eingangstag (Schutz der Platte; 27.11.2026: 20 000 -> 5 000)
IP_LIMIT = (60, 60)             # Anfragen je IP und Stunde (NAT im Hochschulnetz: viele Geraete hinter einer Adresse; 27.11.2026: 120 -> 60)
MAX_AGE_DAYS = 30               # aeltere Meldungen nimmt der Dienst nicht mehr an
MAX_FRAMES = 24
KINDS = ("crash", "hang", "exit")
DEVICE_CLASSES = ("iphone", "ipad", "mac")
CHANNELS = ("store", "test")
# Gruende der Tageszaehlung von iOS (MXAppExitMetric, nur Vordergrund); Text fuer die Auswertung
EXIT_REASONS = {"memory_limit": "Speicher voll", "watchdog": "reagierte zu lange nicht", "cpu_limit": "zu viel Rechenzeit",
                "bad_access": "Speicherzugriff", "illegal_instruction": "ungültiger Befehl", "abnormal": "anderer Abbruch"}
SIGNALS = {4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE"}
# Programmdateien der App selbst (CFBundleExecutable): die erste Zeile daraus benennt die Absturzstelle
APP_BINARIES = ("UniFlow", "StudiNowWidgets")
BERLIN = ZoneInfo("Europe/Berlin")

ID_RE = re.compile(r"^[0-9a-f]{32}$")
VERSION_RE = re.compile(r"^[0-9][0-9A-Za-z.\-]{0,19}$")
BUILD_RE = re.compile(r"^[0-9A-Za-z.]{1,12}$")
MODEL_RE = re.compile(r"^[A-Za-z][A-Za-z0-9,_\-]{0,31}$")
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]{0,79}$")
UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-?[0-9A-Fa-f]{4}-?[0-9A-Fa-f]{4}-?[0-9A-Fa-f]{4}-?[0-9A-Fa-f]{12}$")
_NOT_PLAIN = re.compile(r"[^A-Za-z0-9 .,:;()_+\-/]")

SCHEMA = """
CREATE TABLE IF NOT EXISTS crash_reports (
    id TEXT PRIMARY KEY,                 -- zufaellige Kennung der Meldung vom Geraet (gegen doppelte Zustellung)
    received_at TEXT NOT NULL,           -- Eingang beim Dienst (UTC)
    received_day TEXT NOT NULL,          -- Eingangstag (UTC, YYYY-MM-DD): Grenzen je Tag
    device_day TEXT NOT NULL,            -- HMAC(Eingangstag + Installations-Kennung), jeden Tag anders; nie die Kennung
    kind TEXT NOT NULL,                  -- crash | hang | exit
    happened_at TEXT NOT NULL,           -- Zeitpunkt laut Geraet (UTC)
    day TEXT NOT NULL                    -- Tag des Ereignisses (Europe/Berlin, YYYY-MM-DD): Auswertung
);
CREATE INDEX IF NOT EXISTS idx_crash_reports_day ON crash_reports(day);
CREATE INDEX IF NOT EXISTS idx_crash_reports_device ON crash_reports(received_day, device_day);
"""
# Alle weiteren Spalten per db.add_column (wie accounts._migrate): eine spaetere Spalte kommt hier einfach dazu.
# reason: nur exit (Schluessel aus EXIT_REASONS). count: exit = Anzahl am Tag, crash/hang = 1.
# frames: JSON-Liste [{"b": Programmdatei, "o": Abstand, "u": Kennung der Datei}], oberste Zeile zuerst.
COLUMNS = (("app_version", "TEXT"), ("app_build", "TEXT"), ("device_class", "TEXT"), ("device_model", "TEXT"),
           ("os_version", "TEXT"), ("channel", "TEXT"), ("signal", "INTEGER"), ("exception_type", "INTEGER"),
           ("exception_code", "INTEGER"), ("termination", "TEXT"), ("exception_name", "TEXT"), ("hang_seconds", "REAL"),
           ("reason", "TEXT"), ("count", "INTEGER NOT NULL DEFAULT 1"), ("frames", "TEXT"))
TABLE = "crash_reports"


# ---------------------------------------------------------------- Datenbank

def ensure_schema(conn: sqlite3.Connection) -> None:
    """Tabelle und Spalten anlegen; wiederholbar, auch wenn mehrere Dienst-Prozesse gleichzeitig starten."""
    from . import db
    conn.executescript(SCHEMA)
    for col, decl in COLUMNS:
        db.add_column(conn, TABLE, col, decl)


def db_path():
    """Eigene Datei (Sicherheitspruefung 27.11.2026): eine Flut von Meldungen haelt nie die Schreibsperre von accounts.db,
    hinter der Anmeldung und Sitzungen liegen."""
    return config.BASE_DATA_DIR / "crash_reports.db"


def _move_from_accounts(conn: sqlite3.Connection) -> None:
    """Meldungen aus der frueheren Tabelle in accounts.db einmal hierher holen und dort loeschen (bis 27.11.2026)."""
    old = accounts.db_path()
    if not old.exists():
        return
    conn.execute("ATTACH DATABASE ? AS acc", (str(old),))
    try:
        if conn.execute("SELECT 1 FROM acc.sqlite_master WHERE type='table' AND name=?", (TABLE,)).fetchone():
            cols = [r[1] for r in conn.execute(f"PRAGMA acc.table_info({TABLE})")]
            mine = {r[1] for r in conn.execute(f"PRAGMA main.table_info({TABLE})")}
            common = ", ".join(c for c in cols if c in mine)
            conn.execute(f"INSERT OR IGNORE INTO main.{TABLE}({common}) SELECT {common} FROM acc.{TABLE}")
            conn.execute(f"DELETE FROM acc.{TABLE}")
        conn.commit()
    finally:
        conn.execute("DETACH DATABASE acc")


def _schema(conn: sqlite3.Connection) -> None:
    ensure_schema(conn)
    _move_from_accounts(conn)


@contextmanager
def cursor():
    """Verbindung zur eigenen Datei crash_reports.db (wird beim ersten Zugriff angelegt)."""
    from . import db
    p = db_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(p, check_same_thread=False, timeout=15)
    conn.row_factory = sqlite3.Row
    db.wal_once(conn, p)
    db.fast_commits(conn)
    db.schema_once(conn, "crash_reports", p, _schema)
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def device_day_key(install: str, day: str) -> str:
    """Tages-Marke eines Geraets: ohne das Dienst-Geheimnis nicht zurueckzurechnen, am naechsten Tag eine andere."""
    from . import vault                                     # spaet: vault importiert accounts
    return hmac.new(vault.master_key(), f"crash-report:{day}:{install}".encode("utf-8"), hashlib.sha256).hexdigest()[:32]


# ---------------------------------------------------------------- Pruefen einer Meldung (rein)

def _invalid(message: str) -> accounts.AccountError:
    return accounts.AccountError("invalid_input", message, 400)


def _plain(value, limit: int) -> str | None:
    """Kurzer Text nur aus harmlosen Zeichen (Buchstaben, Ziffern, einfache Satzzeichen); alles andere faellt weg."""
    if not isinstance(value, str):
        return None
    s = _NOT_PLAIN.sub("", value).strip()[:limit]
    return s or None


def _match(value, rx: re.Pattern) -> str | None:
    return value if isinstance(value, str) and rx.fullmatch(value) else None


def _int(value, low: int, high: int) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
        return None
    try:
        n = int(value)
    except (OverflowError, ValueError):
        return None
    return n if low <= n <= high else None


def _time(value) -> datetime | None:
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        t = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        return None
    return t.astimezone(timezone.utc).replace(microsecond=0)


def _frames(value) -> list[dict]:
    out: list[dict] = []
    if not isinstance(value, list):
        return out
    for f in value[:MAX_FRAMES]:
        if not isinstance(f, dict):
            continue
        b = _plain(f.get("b"), 64)
        o = _int(f.get("o"), 0, 1 << 44)
        if b is None or o is None:
            continue
        row = {"b": b, "o": o}
        u = _match(f.get("u"), UUID_RE)
        if u:
            row["u"] = u.upper()
        out.append(row)
    return out


def clean(report, now: datetime) -> dict | None:
    """Eine Meldung auf die erlaubten Felder bringen; None, wenn Pflichtangaben fehlen oder nicht passen. Texte werden
    nicht abgelehnt, sondern auf harmlose Zeichen gekuerzt (eine Ueberraschung im Format kostet so keine Meldung)."""
    if not isinstance(report, dict):
        return None
    rid = _match(report.get("id"), ID_RE)
    kind = report.get("kind") if report.get("kind") in KINDS else None
    at = _time(report.get("at"))
    version = _match(report.get("app_version"), VERSION_RE)
    device_class = report.get("device_class") if report.get("device_class") in DEVICE_CLASSES else None
    if not (rid and kind and at and version and device_class):
        return None
    if at > now + timedelta(days=1) or at < now - timedelta(days=MAX_AGE_DAYS):
        return None
    out = {"id": rid, "kind": kind, "happened_at": accounts.iso(at), "day": at.astimezone(BERLIN).strftime("%Y-%m-%d"),
           "app_version": version, "app_build": _match(report.get("app_build"), BUILD_RE), "device_class": device_class,
           "device_model": _match(report.get("device_model"), MODEL_RE), "os_version": _plain(report.get("os_version"), 48),
           "channel": report.get("channel") if report.get("channel") in CHANNELS else None,
           "signal": None, "exception_type": None, "exception_code": None, "termination": None, "exception_name": None,
           "hang_seconds": None, "reason": None, "count": 1, "frames": None}
    if kind == "exit":
        reason = report.get("reason") if report.get("reason") in EXIT_REASONS else None
        count = _int(report.get("count"), 1, 10_000)
        if not reason or not count:
            return None
        out["reason"], out["count"] = reason, count
        return out
    if kind == "crash":
        out["signal"] = _int(report.get("signal"), 0, 255)
        out["exception_type"] = _int(report.get("exception_type"), 0, 1 << 31)
        out["exception_code"] = _int(report.get("exception_code"), -(1 << 62), 1 << 62)
        out["termination"] = _plain(report.get("termination"), 160)
        out["exception_name"] = _match(report.get("exception_name"), NAME_RE)
    else:
        secs = report.get("hang_seconds")
        if isinstance(secs, (int, float)) and not isinstance(secs, bool) and 0 <= secs <= 86_400:
            out["hang_seconds"] = round(float(secs), 2)
    frames = _frames(report.get("frames"))
    out["frames"] = json.dumps(frames, separators=(",", ":")) if frames else None
    return out


# ---------------------------------------------------------------- Annehmen

FIELDS = ("id", "received_at", "received_day", "device_day", "kind", "happened_at", "day") + tuple(c for c, _ in COLUMNS)


def accept(body, ip: str | None = None, now: datetime | None = None) -> dict:
    """Meldungen eines Geraets pruefen und ablegen. Wirft AccountError (400 invalid_input, 429 rate_limited).
    Antwort {stored, duplicates, dropped}: `dropped` zaehlt ungueltige Meldungen und solche ueber der Tagesgrenze -
    die App loescht nach einer 200 alles Gesendete, es gibt keinen zweiten Versuch (sonst kaeme Unpassendes ewig)."""
    t = now or accounts.now()
    if not isinstance(body, dict) or body.get("v") != VERSION:
        raise _invalid("Unbekanntes Format der Meldung.")
    install = _match(body.get("install"), ID_RE)
    reports = body.get("reports")
    if not install or not isinstance(reports, list) or not reports or len(reports) > MAX_REPORTS:
        raise _invalid("Die Meldung ist unvollständig.")
    if ip:
        accounts.hit_limit("crash_ip", ip, default=IP_LIMIT)
    day = t.strftime("%Y-%m-%d")
    key = device_day_key(install, day)
    stored = duplicates = dropped = 0
    with cursor() as conn:
        conn.execute("BEGIN IMMEDIATE")                     # Zaehlen und Einfuegen als eine Einheit (mehrere Prozesse)
        used = conn.execute("SELECT COUNT(*) FROM crash_reports WHERE received_day=? AND device_day=?", (day, key)).fetchone()[0]
        total = conn.execute("SELECT COUNT(*) FROM crash_reports WHERE received_day=?", (day,)).fetchone()[0]
        # Tagesgrenze voll: "spaeter" (503 mit Retry-After) statt still verwerfen - die App behaelt die Meldungen dann
        # und sendet sie spaeter (Sicherheitspruefung 27.11.2026: vorher gingen echte Meldungen nach einer Flut verloren)
        if total + len(reports) > DAY_TOTAL:
            conn.execute("ROLLBACK")
            raise accounts.AccountError("busy", "Gerade nehmen wir keine Meldungen an. Bitte später erneut senden.", 503,
                                        retry_after=3600)
        for raw in reports:
            row = clean(raw, t)
            if row is None:
                dropped += 1
                continue
            if conn.execute("SELECT 1 FROM crash_reports WHERE id=?", (row["id"],)).fetchone():
                duplicates += 1
                continue
            if used >= DEVICE_DAY_LIMIT or total >= DAY_TOTAL:
                dropped += 1
                continue
            row.update(received_at=accounts.iso(t), received_day=day, device_day=key)
            conn.execute(f"INSERT INTO crash_reports({', '.join(FIELDS)}) VALUES ({', '.join('?' * len(FIELDS))})",
                         [row[f] for f in FIELDS])
            stored += 1
            used += 1
            total += 1
    return {"stored": stored, "duplicates": duplicates, "dropped": dropped}


@router.post("/crashes")
def post_crashes(request: Request, body: dict = Body(...)):
    """Absturzmeldungen eines Geraets annehmen (ohne Sitzung). Die IP-Adresse dient nur der Grenze je Adresse."""
    account_api._hosted_only()
    try:
        out = accept(body, ip=account_api._ip(request))
    except accounts.AccountError as e:
        raise account_api._err(e)
    return {"ok": True, **out}


def purge_old(conn: sqlite3.Connection, now: datetime, dry_run: bool = False) -> int:
    """Meldungen aelter als KEEP_DAYS loeschen (app/retention.py, taeglich); liefert die Anzahl."""
    if not accounts._has_table(conn, TABLE):
        return 0
    cutoff = accounts.iso(now - timedelta(days=KEEP_DAYS))
    n = conn.execute("SELECT COUNT(*) FROM crash_reports WHERE received_at < ?", (cutoff,)).fetchone()[0]
    if n and not dry_run:
        conn.execute("DELETE FROM crash_reports WHERE received_at < ?", (cutoff,))
    return n


# ---------------------------------------------------------------- Auswertung

# Programmstart: steht an dem Ende der Kette, das am weitesten vom Absturz weg ist
START_BINARIES = ("dyld", "libdyld.dylib")
CUT_MARKER = "(...)"            # Platzhalter der App fuer die ausgelassene Mitte einer langen Kette


def ordered_frames(row: dict) -> list[dict]:
    """Aufrufkette mit der Absturzstelle zuerst. Die App schickt die Kette so, wie Apple sie liefert; gespeichert wird
    sie unveraendert. Steht der Programmstart (dyld) vorn, ist sie andersherum und wird hier gedreht. Am echten Geraet
    noch nicht bestaetigt (docs/ABSTURZMELDUNG-2026-11-25.md, Abschnitt "Nicht geprueft") - deshalb erst beim Lesen."""
    try:
        frames = [f for f in json.loads(row.get("frames") or "[]") if isinstance(f, dict) and f.get("b") != CUT_MARKER]
    except ValueError:
        return []
    if len(frames) > 1 and frames[0].get("b") in START_BINARIES and frames[-1].get("b") not in START_BINARIES:
        frames.reverse()
    return frames


def signature(row: dict) -> str:
    """Kurzname der Absturzstelle: erste Zeile der Kette aus der App selbst, sonst die oberste; dazu Signal/Ausnahme."""
    frames = ordered_frames(row)
    own = next((f for f in frames if f.get("b") in APP_BINARIES), None) or (frames[0] if frames else None)
    place = f"{own['b']}+0x{int(own['o']):x}" if own else "ohne Aufrufkette"
    what = row.get("exception_name") or SIGNALS.get(row.get("signal")) or (f"Signal {row['signal']}" if row.get("signal") is not None else None)
    if row.get("kind") == "hang":
        what = "Hänger"
    return f"{place} ({what})" if what else place


def summary(days: int = 14, now: datetime | None = None, channel: str | None = None) -> dict:
    """Zahlen fuer die Auswertung: je Tag, Version und Geraeteart Abstuerze, Haenger und betroffene Geraete; dazu die
    Tageszaehlung von iOS und die haeufigsten Absturzstellen. `channel`: nur "store" oder nur "test"."""
    t = now or accounts.now()
    first = (t.astimezone(BERLIN) - timedelta(days=max(1, days) - 1)).strftime("%Y-%m-%d")
    where, params = "day >= ?", [first]
    if channel:
        where += " AND COALESCE(channel, 'store') = ?"
        params.append(channel)
    with cursor() as conn:
        rows = [dict(r) for r in conn.execute(f"SELECT * FROM crash_reports WHERE {where} ORDER BY day DESC, received_at DESC", params)]
    groups: dict[tuple, dict] = {}
    exits: dict[tuple, int] = {}
    places: dict[str, dict] = {}
    for r in rows:
        version = f"{r['app_version']} ({r['app_build']})" if r.get("app_build") else r["app_version"]
        source = r.get("channel") or "store"
        if r["kind"] == "exit":
            k = (r["day"], version, r["device_class"], source, r["reason"])
            exits[k] = exits.get(k, 0) + int(r["count"] or 0)
            continue
        g = groups.setdefault((r["day"], version, r["device_class"], source),
                              {"crashes": 0, "hangs": 0, "devices": set(), "models": set(), "systems": set()})
        g["crashes" if r["kind"] == "crash" else "hangs"] += 1
        g["devices"].add((r["received_day"], r["device_day"]))
        if r.get("device_model"):
            g["models"].add(r["device_model"])
        if r.get("os_version"):
            g["systems"].add(r["os_version"])
        p = places.setdefault(signature(r), {"count": 0, "versions": set(), "last": r["day"]})
        p["count"] += 1
        p["versions"].add(version)
    table = [{"day": d, "version": v, "device": dev, "source": s, "crashes": g["crashes"], "hangs": g["hangs"],
              "devices": len(g["devices"]), "models": sorted(g["models"]), "systems": sorted(g["systems"])}
             for (d, v, dev, s), g in sorted(groups.items(), key=lambda kv: (kv[0][0], kv[0][1], kv[0][2]), reverse=True)]
    exit_table = [{"day": d, "version": v, "device": dev, "source": s, "reason": reason, "count": n}
                  for (d, v, dev, s, reason), n in sorted(exits.items(), reverse=True)]
    top = [{"place": k, "count": p["count"], "versions": sorted(p["versions"]), "last": p["last"]}
           for k, p in sorted(places.items(), key=lambda kv: (-kv[1]["count"], kv[0]))[:10]]
    return {"from": first, "to": t.astimezone(BERLIN).strftime("%Y-%m-%d"), "days": days,
            "crashes": sum(r["crashes"] for r in table), "hangs": sum(r["hangs"] for r in table),
            "rows": table, "exits": exit_table, "top": top}


DEVICE_TEXT = {"iphone": "iPhone", "ipad": "iPad", "mac": "Mac"}
SOURCE_TEXT = {"store": "App Store", "test": "Test"}


def _table(head: list[str], lines: list[list[str]]) -> list[str]:
    width = [max(len(str(x)) for x in col) for col in zip(head, *lines)]
    fmt = lambda cells: "  ".join(str(c).ljust(w) for c, w in zip(cells, width)).rstrip()  # noqa: E731
    return [fmt(head), fmt(["-" * w for w in width]), *(fmt(x) for x in lines)]


def text(s: dict) -> str:
    """Die Auswertung als Text in einfacher Sprache (Tage neu zuerst)."""
    out = [f"Abstürze von {s['from']} bis {s['to']} ({s['days']} Tage)", ""]
    if not s["rows"] and not s["exits"]:
        out += ["Keine Meldungen in diesem Zeitraum.",
                "Das heißt: Kein Gerät hat einen Absturz gemeldet. Geräte mit ausgeschalteter Meldung zählen nicht mit."]
        return "\n".join(out) + "\n"
    out.append(f"Zusammen: {s['crashes']} Abstürze, {s['hangs']} Hänger.")
    if s["rows"]:
        out += ["", *_table(["Tag", "Version", "Gerät", "Quelle", "Abstürze", "Hänger", "Geräte"],
                            [[r["day"], r["version"], DEVICE_TEXT.get(r["device"], r["device"]), SOURCE_TEXT.get(r["source"], r["source"]),
                              r["crashes"], r["hangs"], r["devices"]] for r in s["rows"]])]
    if s["top"]:
        out += ["", "Häufigste Stellen (für die Fehlersuche):"]
        out += [f"  {p['count']}×  {p['place']}  –  {', '.join(p['versions'])}, zuletzt {p['last']}" for p in s["top"]]
    if s["exits"]:
        out += ["", "Von iOS beendet, während die App offen war (Tageszählung von Apple):",
                *_table(["Tag", "Version", "Gerät", "Quelle", "Grund", "Anzahl"],
                        [[r["day"], r["version"], DEVICE_TEXT.get(r["device"], r["device"]), SOURCE_TEXT.get(r["source"], r["source"]),
                          EXIT_REASONS.get(r["reason"], r["reason"]), r["count"]] for r in s["exits"]]),
                "Hinweis: Diese Zählung überschneidet sich mit den Abstürzen oben (außer „Speicher voll“). Nicht zusammenzählen."]
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="absturz-auswertung", description="Abstürze je Tag, App-Version und Geräteart (nur lesen).")
    p.add_argument("--tage", type=int, default=14, help="Zeitraum in Tagen bis heute (Standard 14)")
    p.add_argument("--quelle", choices=CHANNELS, help="nur App Store (store) oder nur Testfassungen (test)")
    p.add_argument("--json", action="store_true", help="Zahlen als JSON statt als Text")
    a = p.parse_args(sys.argv[1:] if argv is None else argv)
    s = summary(days=a.tage, channel=a.quelle)
    sys.stdout.write(json.dumps(s, ensure_ascii=False, indent=2) + "\n" if a.json else text(s))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
