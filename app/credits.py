"""Credits der StudiNow-KI je Konto und Monat (Entscheidung des Inhabers 04.11.2026).

Regeln:
- Ein Credit ist 0,9 Cent echter OpenAI-Kosten (`ai_prices.MICROEUR_PER_CREDIT`) (app/ai_prices.py rechnet, aufgerundet auf ganze Cent). Pro AI hat 100
  Credits je Monat (= hoechstens 1 EUR KI-Kosten je Konto), alle anderen Tarife 0; einstellbar je Tarif ueber
  LERNAPP_CREDITS_PRO_AI, LERNAPP_CREDITS_PLUS, LERNAPP_CREDITS_FREE und fuer die 7-Tage-Probe
  LERNAPP_CREDITS_TRIAL (Vorschlag 25, damit das Probe-Becken in app/ai_backend.py fuer viele Probekonten reicht).
- Credit-Regel des Inhabers 08.11.2026: Probe ohne bezahltes Abo 25, Plus 0, Pro AI 100. Laufende Probe + Plus: 25, bis
  die Probe endet, danach 0; laufende Probe + Pro AI: 100 (`ai_backend.is_trial_account`).
- Nicht verbrauchte Credits verfallen am Monatsende. Der Monat ist der Kalendermonat in Europe/Berlin; der neue Monat
  beginnt "faul": die Zeile des Monats entsteht bei der ersten Nutzung (kein naechtlicher Lauf noetig).
- Der Rahmen eines Monats folgt dem aktuellen Tarif: wer mitten im Monat Pro AI abschliesst, hat sofort 100.
- Vor jedem Aufruf wird die Obergrenze der Anfrage reserviert (reserve; app/ai_prices.worst_case_microeur fuer das
  teuerste Modell der Anbieter-Kette), danach mit der echten Nutzung abgerechnet, nie mehr als reserviert (settle), oder
  bei einem Fehler, fuer den der Anbieter nichts berechnet hat, zurueckgegeben (refund). Damit ist die Grenze hart: ein
  Konto verursacht im Monat hoechstens seine Credits, auch mit gleichzeitigen Anfragen und Ersatz-Anbietern. Reicht der Rest nicht fuer die
  Reservierung: 429 credits_exhausted, "Credits für diesen Monat aufgebraucht – am 1. gibt es neue."
- Jede Anfrage traegt eine request_id (je Konto eindeutig): dieselbe ID wird nie zweimal berechnet. Laeuft sie noch:
  409 duplicate_request; ist sie fertig: die gespeicherte Antwort kommt noch 24 Stunden zurueck (ohne neue Kosten).
- Reihenfolge der Bezahlung (funding): erst Geteiltes (gemeinsamer Wochentest, Seite der Bibliothek: 0 Credits, kein
  KI-Aufruf), dann das eigene ChatGPT-Abo des Nutzers (0 Credits, laeuft auf dem Geraet), erst dann Credits.
- Dem Client wird nie geglaubt: Kosten kommen nur aus `usage` der Antwort von OpenAI (app/ai_backend.py).

Tabellen in accounts.db (neben ai_usage_log): credit_months (Monatsstand je Konto) und credit_ledger (jede Anfrage mit
Modell, Tokens, Kosten). Die Kostenansicht des Betriebs (admin_costs) fasst credit_ledger je Tag und Modell zusammen.
"""
from __future__ import annotations

import os
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from . import ai_prices, billing, db, plans

TZ = ZoneInfo("Europe/Berlin")
EXHAUSTED_MESSAGE = "Credits für diesen Monat aufgebraucht – am 1. gibt es neue."
# Tarif -> Umgebungsvariable und Standard aus dem Vertrag (plans.CREDITS: 100 fuer Pro AI, sonst 0, Probe 25)
ALLOWANCE_ENV = {"pro_ai": ("LERNAPP_CREDITS_PRO_AI", plans.CREDITS["pro_ai"]),
                 "plus": ("LERNAPP_CREDITS_PLUS", plans.CREDITS["plus"]), "free": ("LERNAPP_CREDITS_FREE", plans.CREDITS["free"])}
TRIAL_ENV = ("LERNAPP_CREDITS_TRIAL", plans.CREDITS["trial"])
# Reservierungen ohne Abrechnung (Prozess abgestuerzt) verfallen nach so vielen Minuten
STALE_MINUTES = 15
# so lange liefert dieselbe request_id die fertige Antwort noch einmal
REPLAY_HOURS = 24

SCHEMA = """
CREATE TABLE IF NOT EXISTS credit_months (
    user_id TEXT NOT NULL,
    period TEXT NOT NULL,                  -- YYYY-MM (Europe/Berlin)
    allowance INTEGER NOT NULL,            -- Credits des Monats (aus dem aktuellen Tarif)
    used INTEGER NOT NULL DEFAULT 0,       -- abgerechnet
    reserved INTEGER NOT NULL DEFAULT 0,   -- laufende Anfragen
    plan TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, period)
);
CREATE TABLE IF NOT EXISTS credit_ledger (
    user_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    period TEXT NOT NULL,
    day TEXT NOT NULL,                     -- YYYY-MM-DD (Europe/Berlin), fuer die Kostenansicht
    purpose TEXT NOT NULL,
    funding TEXT NOT NULL,                 -- credits | shared | own_chatgpt
    state TEXT NOT NULL,                   -- reserved | settled | refunded | expired | free
    model TEXT,
    reserved INTEGER NOT NULL DEFAULT 0,
    charged INTEGER NOT NULL DEFAULT 0,
    cost_microeur INTEGER NOT NULL DEFAULT 0,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    cached_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    images INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    settled_at TEXT,
    result TEXT,                           -- Antwort fuer eine Wiederholung derselben request_id, nach 24 h geleert
    PRIMARY KEY (user_id, request_id)
);
CREATE INDEX IF NOT EXISTS idx_credit_ledger_day ON credit_ledger(day, model);
CREATE INDEX IF NOT EXISTS idx_credit_ledger_user ON credit_ledger(user_id, state, created_at);
"""


class CreditsError(Exception):
    def __init__(self, code: str, message: str, status: int = 429, extra: dict | None = None):
        super().__init__(message)
        self.code, self.message, self.status, self.extra = code, message, status, extra or {}


@dataclass
class Reservation:
    request_id: str
    reserved: int
    replay: bool = False
    result: str | None = None
    charged: int = 0
    balance: dict = field(default_factory=dict)


def _now(now: datetime | None = None) -> datetime:
    return (now or datetime.now(timezone.utc)).astimezone(timezone.utc)


def period_of(now: datetime | None = None) -> str:
    return _now(now).astimezone(TZ).strftime("%Y-%m")


def day_of(now: datetime | None = None) -> str:
    return _now(now).astimezone(TZ).strftime("%Y-%m-%d")


def resets_at(now: datetime | None = None) -> str:
    """Beginn des naechsten Monats in Berlin (ISO mit Versatz): ab dann gibt es neue Credits."""
    local = _now(now).astimezone(TZ)
    nxt = datetime(local.year + (local.month == 12), local.month % 12 + 1, 1, tzinfo=TZ)
    return nxt.isoformat()


def ensure_schema(conn: sqlite3.Connection) -> None:
    if conn.in_transaction:
        conn.commit()
    conn.executescript(SCHEMA)


def connect() -> sqlite3.Connection:
    from . import accounts
    conn = billing.connect()
    db.schema_once(conn, "credits", accounts.db_path(), ensure_schema)
    return conn


def _int_env(name: str, default: int) -> int:
    try:
        return max(0, int(os.environ.get(name) or default))
    except ValueError:
        return default


def plan_and_trial(conn: sqlite3.Connection, user_id: str, now: datetime | None = None) -> tuple[str, bool]:
    """Tarif des Kontos (mit users.plan) und ob nur die Probe laeuft."""
    legacy = None
    try:
        r = conn.execute("SELECT plan, plan_until FROM users WHERE id=?", (str(user_id),)).fetchone()
        legacy = {"plan": r[0], "plan_until": r[1]} if r else None
    except sqlite3.OperationalError as e:
        # Nur eine fehlende Tabelle/Spalte (reine Billing-Datei in Tests und Werkzeugen) heisst "kein Altbestand". Ein
        # echter Datenbankfehler (gesperrt, Platte) bleibt sichtbar, statt still als Tarif free zu enden (Audit B03, 08.11.2026).
        if "no such table" not in str(e) and "no such column" not in str(e):
            raise
        legacy = None
    plan = billing.current_plan(conn, str(user_id), _now(now), legacy)
    from . import ai_backend
    return plan, ai_backend.is_trial_account(conn, str(user_id), _now(now))


def allowance(plan: str, trial: bool) -> int:
    if trial:
        return _int_env(*TRIAL_ENV)
    name, default = ALLOWANCE_ENV.get(plan, ("", 0))
    return _int_env(name, default) if name else 0


def _month(conn: sqlite3.Connection, user_id: str, now: datetime) -> sqlite3.Row | tuple:
    """Zeile des Monats anlegen (neuer Monat = neuer Stand) und den Rahmen auf den aktuellen Tarif setzen. In einer
    laufenden Transaktion aufrufen."""
    period, t = period_of(now), now.isoformat()
    plan, trial = plan_and_trial(conn, user_id, now)
    allow = allowance(plan, trial)
    label = plan + (":trial" if trial else "")
    conn.execute("INSERT OR IGNORE INTO credit_months(user_id, period, allowance, used, reserved, plan, created_at, updated_at) "
                 "VALUES (?,?,?,0,0,?,?,?)", (user_id, period, allow, label, t, t))
    conn.execute("UPDATE credit_months SET allowance=?, plan=?, updated_at=? WHERE user_id=? AND period=? AND (allowance<>? OR plan<>?)",
                 (allow, label, t, user_id, period, allow, label))
    return conn.execute("SELECT allowance, used, reserved, plan FROM credit_months WHERE user_id=? AND period=?",
                        (user_id, period)).fetchone()


def _balance_dict(row, now: datetime) -> dict:
    allow, used, reserved, plan = row
    return {"period": period_of(now), "allowance": allow, "used": used, "reserved": reserved,
            "remaining": max(0, allow - used - reserved), "plan": plan, "resets_at": resets_at(now),
            "credit_eur": ai_prices.MICROEUR_PER_CREDIT / 1_000_000}


def _housekeeping(conn: sqlite3.Connection, user_id: str, now: datetime) -> None:
    """Liegengebliebene Reservierungen dieses Kontos freigeben und alte gespeicherte Antworten leeren."""
    stale = (now - timedelta(minutes=STALE_MINUTES)).isoformat()
    for period, amount in conn.execute("SELECT period, reserved FROM credit_ledger WHERE user_id=? AND state='reserved' AND created_at<?",
                                       (user_id, stale)).fetchall():
        conn.execute("UPDATE credit_months SET reserved=MAX(reserved-?, 0) WHERE user_id=? AND period=?", (amount, user_id, period))
    conn.execute("UPDATE credit_ledger SET state='expired' WHERE user_id=? AND state='reserved' AND created_at<?", (user_id, stale))
    conn.execute("UPDATE credit_ledger SET result=NULL WHERE user_id=? AND result IS NOT NULL AND settled_at<?",
                 (user_id, (now - timedelta(hours=REPLAY_HOURS)).isoformat()))


def balance(conn: sqlite3.Connection, user_id: str, now: datetime | None = None) -> dict:
    t = _now(now)
    conn.execute("BEGIN IMMEDIATE")
    try:
        _housekeeping(conn, str(user_id), t)
        row = _month(conn, str(user_id), t)
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return _balance_dict(row, t)


def lookup(conn: sqlite3.Connection, user_id: str, request_id: str, now: datetime | None = None) -> tuple[str, str | None] | None:
    """Stand einer request_id dieses Kontos nach dem Aufraeumen: (state, gespeicherte Antwort) oder None, wenn unbekannt.
    Fuer die Endpunkte: eine fertige ID mit Antwort wird wiederholt (0 Credits), eine laufende abgewiesen (409), bevor das
    Kontingent (app/entitlements.py) dieselbe ID als Doppelte sieht."""
    uid, t = str(user_id), _now(now)
    conn.execute("BEGIN IMMEDIATE")
    try:
        _housekeeping(conn, uid, t)
        row = conn.execute("SELECT state, result FROM credit_ledger WHERE user_id=? AND request_id=?", (uid, request_id)).fetchone()
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return (row[0], row[1]) if row else None


def funding_for(*, shared_hit: bool = False, own_chatgpt: bool = False) -> str:
    """Wer bezahlt: Geteiltes zuerst (kein KI-Aufruf), dann das eigene ChatGPT-Abo, erst dann Credits."""
    if shared_hit:
        return "shared"
    if own_chatgpt:
        return "own_chatgpt"
    return "credits"


def reserve(conn: sqlite3.Connection, user_id: str, request_id: str, purpose: str, estimate: int,
            now: datetime | None = None, model: str | None = None) -> Reservation:
    """Schaetzung (Credits) fuer eine Anfrage reservieren, atomar. Wirft CreditsError credits_exhausted (429), wenn der Rest
    nicht reicht, und duplicate_request (409), wenn dieselbe ID gerade laeuft. Eine fertige ID liefert replay=True."""
    if not request_id:
        raise ValueError("request_id fehlt")
    uid, t = str(user_id), _now(now)
    estimate = max(1, int(estimate))
    conn.execute("BEGIN IMMEDIATE")
    try:
        _housekeeping(conn, uid, t)
        row = _month(conn, uid, t)
        old = conn.execute("SELECT state, result, charged FROM credit_ledger WHERE user_id=? AND request_id=?", (uid, request_id)).fetchone()
        if old and old[0] == "reserved":
            conn.execute("COMMIT")
            raise CreditsError("duplicate_request", "Diese Anfrage läuft schon.", 409)
        if old and old[0] in ("settled", "free"):
            conn.execute("COMMIT")
            return Reservation(request_id, 0, replay=True, result=old[1], charged=old[2], balance=_balance_dict(row, t))
        allow, used, reserved, _plan = row
        available = allow - used - reserved
        if estimate > available:
            conn.execute("COMMIT")
            raise CreditsError("credits_exhausted", EXHAUSTED_MESSAGE, 429,
                               {"credits": {**_balance_dict(row, t), "needed": estimate}})
        period, day = period_of(t), day_of(t)
        if old:                                     # refunded/expired: derselbe Versuch noch einmal
            conn.execute("UPDATE credit_ledger SET period=?, day=?, purpose=?, funding='credits', state='reserved', model=?, reserved=?, "
                         "charged=0, cost_microeur=0, input_tokens=0, cached_tokens=0, output_tokens=0, images=0, created_at=?, "
                         "settled_at=NULL, result=NULL WHERE user_id=? AND request_id=?",
                         (period, day, purpose, model, estimate, t.isoformat(), uid, request_id))
        else:
            conn.execute("INSERT INTO credit_ledger(user_id, request_id, period, day, purpose, funding, state, model, reserved, created_at) "
                         "VALUES (?,?,?,?,?,'credits','reserved',?,?,?)", (uid, request_id, period, day, purpose, model, estimate, t.isoformat()))
        conn.execute("UPDATE credit_months SET reserved=reserved+?, updated_at=? WHERE user_id=? AND period=?",
                     (estimate, t.isoformat(), uid, period))
        row = conn.execute("SELECT allowance, used, reserved, plan FROM credit_months WHERE user_id=? AND period=?", (uid, period)).fetchone()
        conn.execute("COMMIT")
        return Reservation(request_id, estimate, balance=_balance_dict(row, t))
    except CreditsError:
        raise
    except Exception:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


def settle(conn: sqlite3.Connection, user_id: str, request_id: str, cost_microeur: int, *, model: str | None = None,
           input_tokens: int = 0, cached_tokens: int = 0, output_tokens: int = 0, images: int = 0, result: str | None = None,
           now: datetime | None = None) -> int:
    """Mit der echten Nutzung abrechnen: Credits = Kosten in Cent, aufgerundet. Die Reservierung wird frei. Eine schon
    abgerechnete ID bleibt, wie sie ist (liefert ihre Credits). Liefert die berechneten Credits.

    Harte Grenze (Inhaber 05.11.2026, Pro AI 100 Credits = hoechstens 1 EUR je Monat): berechnet wird nie mehr als
    reserviert (die Reservierung ist die Obergrenze aus app/ai_prices.worst_case_microeur), bei einer verfallenen
    Reservierung nie mehr als der freie Rest des Monats. `cost_microeur` bleibt die echte Zahl (Kostenansicht)."""
    uid, t = str(user_id), _now(now)
    charged = ai_prices.credits_for(cost_microeur)
    conn.execute("BEGIN IMMEDIATE")
    try:
        old = conn.execute("SELECT state, period, reserved, charged FROM credit_ledger WHERE user_id=? AND request_id=?",
                           (uid, request_id)).fetchone()
        if not old or old[0] not in ("reserved", "expired"):
            conn.execute("COMMIT")
            return old[3] if old else 0
        state, period, reserved = old[0], old[1], old[2]
        held = reserved if state == "reserved" else 0  # eine verfallene Reservierung ist schon freigegeben
        if state == "reserved":
            charged = min(charged, reserved)
        else:
            m = conn.execute("SELECT allowance, used, reserved FROM credit_months WHERE user_id=? AND period=?", (uid, period)).fetchone()
            charged = min(charged, max(0, (m[0] - m[1] - m[2]) if m else 0))
        conn.execute("UPDATE credit_months SET reserved=MAX(reserved-?, 0), used=used+?, updated_at=? WHERE user_id=? AND period=?",
                     (held, charged, t.isoformat(), uid, period))
        conn.execute("UPDATE credit_ledger SET state='settled', charged=?, cost_microeur=?, model=COALESCE(?, model), input_tokens=?, "
                     "cached_tokens=?, output_tokens=?, images=?, settled_at=?, result=? WHERE user_id=? AND request_id=?",
                     (charged, int(cost_microeur), model, int(input_tokens), int(cached_tokens), int(output_tokens), int(images),
                      t.isoformat(), result, uid, request_id))
        conn.execute("COMMIT")
        return charged
    except Exception:
        conn.execute("ROLLBACK")
        raise


def refund(conn: sqlite3.Connection, user_id: str, request_id: str) -> bool:
    """Reservierung zurueckgeben (Fehler, fuer den OpenAI nichts berechnet hat). Abgerechnetes bleibt abgerechnet."""
    uid = str(user_id)
    conn.execute("BEGIN IMMEDIATE")
    try:
        old = conn.execute("SELECT state, period, reserved FROM credit_ledger WHERE user_id=? AND request_id=?", (uid, request_id)).fetchone()
        if not old or old[0] != "reserved":
            conn.execute("COMMIT")
            return False
        conn.execute("UPDATE credit_months SET reserved=MAX(reserved-?, 0) WHERE user_id=? AND period=?", (old[2], uid, old[1]))
        conn.execute("UPDATE credit_ledger SET state='refunded' WHERE user_id=? AND request_id=?", (uid, request_id))
        conn.execute("COMMIT")
        return True
    except Exception:
        conn.execute("ROLLBACK")
        raise


def record_free(conn: sqlite3.Connection, user_id: str, request_id: str, purpose: str, funding: str, now: datetime | None = None,
                result: str | None = None) -> None:
    """Anfrage ohne Kosten fuer das Konto vermerken (geteilter Inhalt): 0 Credits, nur fuer die Statistik."""
    t = _now(now)
    conn.execute("INSERT OR IGNORE INTO credit_ledger(user_id, request_id, period, day, purpose, funding, state, created_at, settled_at, result) "
                 "VALUES (?,?,?,?,?,?,'free',?,?,?)", (str(user_id), request_id, period_of(t), day_of(t), purpose, funding,
                                                      t.isoformat(), t.isoformat(), result))


# ---------------------------------------------------------------- Betrieb

def admin_costs(conn: sqlite3.Connection, days: int = 31, now: datetime | None = None) -> dict:
    """Kosten je Tag (Berlin) und Modell der letzten `days` Tage, dazu der laufende Monat: Anfragen, Tokens, Kosten in
    EUR, berechnete Credits, Konten, Anfragen aus Geteiltem (0 Credits). Nur fuer den Betrieb."""
    t = _now(now)
    since = (t.astimezone(TZ) - timedelta(days=max(1, min(int(days), 366)) - 1)).strftime("%Y-%m-%d")
    rows = conn.execute("""SELECT day, COALESCE(model, ''), COUNT(*), COUNT(DISTINCT user_id), SUM(input_tokens), SUM(cached_tokens),
                                  SUM(output_tokens), SUM(images), SUM(cost_microeur), SUM(charged)
                           FROM credit_ledger WHERE day>=? AND state='settled' GROUP BY day, model ORDER BY day DESC, model""",
                        (since,)).fetchall()
    per_day = [{"day": r[0], "model": r[1], "requests": r[2], "accounts": r[3], "input_tokens": r[4] or 0, "cached_tokens": r[5] or 0,
                "output_tokens": r[6] or 0, "images": r[7] or 0, "cost_eur": round((r[8] or 0) / 1_000_000, 6), "credits": r[9] or 0}
               for r in rows]
    period = period_of(t)
    m = conn.execute("""SELECT COUNT(*), COUNT(DISTINCT user_id), COALESCE(SUM(cost_microeur), 0), COALESCE(SUM(charged), 0)
                        FROM credit_ledger WHERE period=? AND state='settled'""", (period,)).fetchone()
    free = conn.execute("SELECT funding, COUNT(*) FROM credit_ledger WHERE period=? AND state='free' GROUP BY funding", (period,)).fetchall()
    top = conn.execute("""SELECT used, allowance FROM credit_months WHERE period=? ORDER BY used DESC LIMIT 1""", (period,)).fetchone()
    exhausted = conn.execute("SELECT COUNT(*) FROM credit_months WHERE period=? AND allowance>0 AND used>=allowance", (period,)).fetchone()[0]
    return {"since": since, "per_day_model": per_day,
            "month": {"period": period, "requests": m[0], "accounts": m[1], "cost_eur": round(m[2] / 1_000_000, 6), "credits": m[3],
                      "cost_per_account_eur": round(m[2] / 1_000_000 / m[1], 6) if m[1] else 0.0,
                      "free_requests": {f: n for f, n in free}, "max_used_credits": top[0] if top else 0,
                      "accounts_exhausted": exhausted},
            "prices": ai_prices.listing(), "prices_checked": ai_prices.CHECKED, "usd_eur": ai_prices.usd_to_eur()}
