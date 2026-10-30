"""Abo-Stand, Berechtigungen und monatliche Kontingente je Konto (gehosteter Dienst).

Die Tarif-Tabelle steht in app/plans.py. Dieses Modul entscheidet fuer ein Konto, welcher Tarif gerade gilt, und
zaehlt Kontingente. Alles liegt in `accounts.db` (zentral, nie in einem Nutzerordner), damit ein Konto auf allen
Geraeten denselben Stand hat.

Regeln:
- Die Berechtigung entscheidet der Server, nie die App allein. Kein Endpunkt nimmt einen Tarif aus der Anfrage an.
- Quellen eines Tarifs: `app_store` (gepruefte Transaktion, app/apple_store.py), `stripe` (Web und Windows,
  app/stripe_billing.py), `trial` (7 Tage Probe je neues Konto, plans.TRIAL), `manual` (Betrieb, CLI
  `python -m app.accounts plan ...`, steht wie bisher in users.plan/plan_until). Es gilt der hoechste aktive.
- Hochzaehlen und Grenze pruefen geschieht in einem UPDATE innerhalb einer Schreibtransaktion (BEGIN IMMEDIATE):
  zwei gleichzeitige Anfragen koennen nicht beide den letzten freien Test bekommen.
- Jede Anfrage traegt eine Anfrage-ID; dieselbe ID zaehlt hoechstens einmal (Wiederholung nach Netzfehler).
- Abrechnungszeitraum: Kalendermonat in UTC (`YYYY-MM`); ein neuer Monat beginnt mit neuem Zaehler, ohne Aufraeumlauf.
- Downgrade: wirkt erst zum Ende des bezahlten Zeitraums (`pending_plan`); Kuendigung (`will_renew = 0`) laesst den
  Tarif bis `expires_at` laufen. Ein Downgrade oder Ablauf loescht nie Daten: Notizen bleiben lesbar und exportierbar,
  nur Bearbeiten wird gesperrt.
- Einzelplatzmodus (PC, Windows-App): keine Konten, keine Tarife – dort gilt alles (`LOCAL_PLAN`).
"""
from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from . import plans

PLANS = plans.PLANS
LOCAL_PLAN = "local"            # Einzelplatz: alle Rechte, keine Kontingente
LEGACY = {"pro": "pro_ai"}      # fruehere Tarifnamen

SCHEMA = """
CREATE TABLE IF NOT EXISTS entitlements (
    user_id TEXT NOT NULL,
    source TEXT NOT NULL,                 -- app_store | manual
    plan TEXT NOT NULL,                   -- free | plus | pro_connect | pro_ai
    original_transaction_id TEXT,
    expires_at TEXT,                      -- ISO-8601 UTC, NULL = unbefristet
    status TEXT NOT NULL DEFAULT 'active',-- active | grace | billing_retry | expired | revoked
    will_renew INTEGER NOT NULL DEFAULT 1,
    pending_plan TEXT,                    -- Tarif ab der naechsten Verlaengerung (Downgrade)
    environment TEXT,                     -- Production | Sandbox | Xcode
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, source)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_entitlements_otid ON entitlements(original_transaction_id) WHERE original_transaction_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS usage (
    user_id TEXT NOT NULL,
    period TEXT NOT NULL,                 -- YYYY-MM (UTC)
    feature TEXT NOT NULL,                -- ai_tests_new | library_tests | ai_assist
    count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, period, feature)
);
CREATE TABLE IF NOT EXISTS usage_requests (
    request_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    period TEXT NOT NULL,
    feature TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_usage_requests_user ON usage_requests(user_id, period);
CREATE TABLE IF NOT EXISTS plan_choices (
    user_id TEXT PRIMARY KEY,             -- Antwort auf die Aufforderung nach der Probe (free | plus | ...), einmal
    plan TEXT NOT NULL,
    chosen_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS stripe_customers (
    user_id TEXT PRIMARY KEY,
    customer_id TEXT UNIQUE NOT NULL,     -- cus_…
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS stripe_events (
    id TEXT PRIMARY KEY,                  -- evt_…, jedes Ereignis zaehlt hoechstens einmal
    type TEXT,
    created_at TEXT NOT NULL
);
"""

ACTIVE_STATUSES = ("active", "grace", "billing_retry")


def _now(now: datetime | None) -> datetime:
    return (now or datetime.now(timezone.utc)).astimezone(timezone.utc)


def period_of(now: datetime | None = None) -> str:
    return _now(now).strftime("%Y-%m")


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    cols = {r[1] for r in conn.execute("PRAGMA table_info(entitlements)")}
    for col, decl in (("will_renew", "INTEGER NOT NULL DEFAULT 1"), ("pending_plan", "TEXT"), ("environment", "TEXT")):
        if col not in cols:
            conn.execute(f"ALTER TABLE entitlements ADD COLUMN {col} {decl}")


def connect() -> sqlite3.Connection:
    """Verbindung zu accounts.db im Autocommit-Modus (Transaktionen steuert dieses Modul selbst)."""
    from . import accounts
    p = accounts.db_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(p, isolation_level=None, timeout=15, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=15000")
    from . import db
    db.schema_once(conn, "billing", p, ensure_schema)
    return conn


def normalize_plan(plan: str | None) -> str | None:
    plan = LEGACY.get(plan or "", plan)
    return plan if plan in PLANS else None


def _row_active(status: str, expires: str | None, t: str) -> bool:
    return status in ACTIVE_STATUSES and not (expires and expires <= t)


def current_plan(conn: sqlite3.Connection, user_id, now: datetime | None = None, legacy: dict | None = None) -> str:
    """Hoechster aktiver, nicht abgelaufener Tarif; sonst free. `legacy` = Zeile aus users (plan, plan_until)."""
    t = _now(now).isoformat()
    best = "free"
    for (plan, expires, status) in conn.execute(
            "SELECT plan, expires_at, status FROM entitlements WHERE user_id=?", (str(user_id),)):
        p = normalize_plan(plan)
        if p and _row_active(status, expires, t) and plans.rank(p) > plans.rank(best):
            best = p
    if legacy:
        p = normalize_plan(legacy.get("plan"))
        until = legacy.get("plan_until")
        # plan_until ist ein Datum (YYYY-MM-DD) und gilt bis einschliesslich dieses Tages
        if p and (not until or str(until)[:10] >= t[:10]) and plans.rank(p) > plans.rank(best):
            best = p
    return best


def allowed(conn: sqlite3.Connection, user_id, entitlement: str, now: datetime | None = None, legacy: dict | None = None) -> bool:
    return plans.has(current_plan(conn, user_id, now, legacy), entitlement)


@dataclass(frozen=True)
class ConsumeResult:
    ok: bool
    used: int
    limit: int
    duplicate: bool = False


def used(conn: sqlite3.Connection, user_id, feature: str, now: datetime | None = None) -> int:
    r = conn.execute("SELECT count FROM usage WHERE user_id=? AND period=? AND feature=?",
                     (str(user_id), period_of(now), feature)).fetchone()
    return r[0] if r else 0


def consume(conn: sqlite3.Connection, user_id, feature: str, request_id: str,
            now: datetime | None = None, legacy: dict | None = None, plan: str | None = None) -> ConsumeResult:
    """Ein Kontingent-Element verbrauchen (z. B. einen KI-Test). Sicher gegen parallele Anfragen und Wiederholungen.
    `conn` muss im Autocommit-Modus sein (isolation_level=None), damit die Transaktion hier gesteuert wird."""
    if not request_id:
        raise ValueError("request_id fehlt")
    t = _now(now)
    period = t.strftime("%Y-%m")
    uid = str(user_id)
    conn.execute("BEGIN IMMEDIATE")
    try:
        p = plan or current_plan(conn, uid, t, legacy)
        limit = plans.quota_limit(p, feature)
        seen = conn.execute("SELECT 1 FROM usage_requests WHERE request_id=?", (request_id,)).fetchone()
        row = conn.execute("SELECT count FROM usage WHERE user_id=? AND period=? AND feature=?", (uid, period, feature)).fetchone()
        n = row[0] if row else 0
        if seen:
            conn.execute("COMMIT")
            return ConsumeResult(ok=True, used=n, limit=limit, duplicate=True)
        conn.execute("INSERT OR IGNORE INTO usage(user_id, period, feature, count) VALUES (?,?,?,0)", (uid, period, feature))
        cur = conn.execute("UPDATE usage SET count = count + 1 WHERE user_id=? AND period=? AND feature=? AND count < ?",
                           (uid, period, feature, limit))
        if cur.rowcount == 0:
            conn.execute("ROLLBACK")
            return ConsumeResult(ok=False, used=n, limit=limit)
        conn.execute("INSERT INTO usage_requests(request_id, user_id, period, feature, created_at) VALUES (?,?,?,?,?)",
                     (request_id, uid, period, feature, t.isoformat()))
        conn.execute("COMMIT")
        return ConsumeResult(ok=True, used=n + 1, limit=limit)
    except Exception:
        conn.execute("ROLLBACK")
        raise


def refund(conn: sqlite3.Connection, request_id: str) -> bool:
    """Verbrauch zuruecknehmen, wenn die Leistung fehlschlug (z. B. KI-Test konnte nicht erstellt werden)."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        r = conn.execute("SELECT user_id, period, feature FROM usage_requests WHERE request_id=?", (request_id,)).fetchone()
        if not r:
            conn.execute("ROLLBACK")
            return False
        conn.execute("DELETE FROM usage_requests WHERE request_id=?", (request_id,))
        conn.execute("UPDATE usage SET count = MAX(count - 1, 0) WHERE user_id=? AND period=? AND feature=?", r)
        conn.execute("COMMIT")
        return True
    except Exception:
        conn.execute("ROLLBACK")
        raise


class BillingError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


def set_entitlement(conn: sqlite3.Connection, user_id, source: str, plan: str, *,
                    original_transaction_id: str | None = None, expires_at: str | None = None,
                    status: str = "active", will_renew: bool = True, pending_plan: str | None = None,
                    environment: str | None = None, now: datetime | None = None) -> None:
    """Berechtigung setzen (z. B. nach gepruefter App-Store-Transaktion). Ein Downgrade loescht keine Daten.
    Eine Transaktion gehoert genau einem Konto: dieselbe original_transaction_id an einem anderen Konto -> Fehler
    (verhindert, dass ein Abo mehrere Konten freischaltet oder ein Konto zwei Abos zaehlt)."""
    p = normalize_plan(plan)
    if not p:
        raise ValueError(f"unbekannter Tarif {plan}")
    uid = str(user_id)
    if original_transaction_id:
        other = conn.execute("SELECT user_id, source FROM entitlements WHERE original_transaction_id=?",
                             (original_transaction_id,)).fetchone()
        if other and (other[0] != uid or other[1] != source):
            raise BillingError("subscription_owned_by_other_account",
                               "Dieses Abo gehört zu einem anderen Studora-Konto.", 409)
    pend = normalize_plan(pending_plan) if pending_plan else None
    conn.execute(
        """INSERT INTO entitlements(user_id, source, plan, original_transaction_id, expires_at, status, will_renew,
                                    pending_plan, environment, updated_at)
           VALUES (?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(user_id, source) DO UPDATE SET plan=excluded.plan,
               original_transaction_id=excluded.original_transaction_id, expires_at=excluded.expires_at,
               status=excluded.status, will_renew=excluded.will_renew, pending_plan=excluded.pending_plan,
               environment=excluded.environment, updated_at=excluded.updated_at""",
        (uid, source, p, original_transaction_id, expires_at, status, 1 if will_renew else 0, pend, environment,
         _now(now).isoformat()))


# ---------------------------------------------------------------- Probe und Tarifwahl

def start_trial(conn: sqlite3.Connection, user_id, now: datetime | None = None) -> dict | None:
    """Probe fuer ein neues Konto (plans.TRIAL): alles frei bis `expires_at`, verlaengert nie. Nur einmal je Konto;
    ein zweiter Aufruf aendert nichts (liefert None)."""
    uid = str(user_id)
    if conn.execute("SELECT 1 FROM entitlements WHERE user_id=? AND source='trial'", (uid,)).fetchone():
        return None
    t = _now(now)
    ends = (t + timedelta(days=plans.TRIAL["days"])).replace(microsecond=0).isoformat()
    set_entitlement(conn, uid, "trial", plans.TRIAL["plan"], expires_at=ends, status="active", will_renew=False, now=t)
    return {"plan": plans.TRIAL["plan"], "ends_at": ends}


def end_trial(conn: sqlite3.Connection, user_id, now: datetime | None = None) -> bool:
    """Probe sofort beenden (Betrieb, Tests): der Eintrag bleibt als "vorbei" stehen, damit sie nicht erneut startet."""
    t = _now(now).isoformat()
    cur = conn.execute("UPDATE entitlements SET status='expired', expires_at=?, updated_at=? WHERE user_id=? AND source='trial' AND expires_at > ?",
                       (t, t, str(user_id), t))
    return cur.rowcount == 1


def trial_info(conn: sqlite3.Connection, user_id, now: datetime | None = None) -> dict:
    """Stand der Probe: active, ends_at, days_left (aufgerundet), expired."""
    t = _now(now)
    row = conn.execute("SELECT plan, expires_at, status FROM entitlements WHERE user_id=? AND source='trial'", (str(user_id),)).fetchone()
    if not row or not row[1]:
        return {"granted": False, "active": False, "ends_at": None, "days_left": 0, "expired": False, "plan": None}
    ends = datetime.fromisoformat(row[1])
    left = ends - t
    active = left.total_seconds() > 0 and row[2] in ACTIVE_STATUSES
    return {"granted": True, "active": active, "ends_at": row[1], "plan": normalize_plan(row[0]),
            "days_left": int((left.total_seconds() + 86399) // 86400) if active else 0,
            "expired": not active}


def record_plan_choice(conn: sqlite3.Connection, user_id, plan: str, now: datetime | None = None) -> str:
    """Antwort auf die Aufforderung nach der Probe merken (einmal; eine spaetere Wahl ersetzt die erste)."""
    p = normalize_plan(plan)
    if not p:
        raise ValueError(f"unbekannter Tarif {plan}")
    conn.execute("INSERT INTO plan_choices(user_id, plan, chosen_at) VALUES (?,?,?) ON CONFLICT(user_id) DO UPDATE SET plan=excluded.plan, chosen_at=excluded.chosen_at",
                 (str(user_id), p, _now(now).isoformat()))
    return p


def plan_choice(conn: sqlite3.Connection, user_id) -> str | None:
    row = conn.execute("SELECT plan FROM plan_choices WHERE user_id=?", (str(user_id),)).fetchone()
    return row[0] if row else None


def needs_plan_choice(conn: sqlite3.Connection, user_id, plan: str, now: datetime | None = None) -> bool:
    """Aufforderung zeigen? Probe vorbei, kein bezahlter Tarif, noch keine Antwort."""
    tr = trial_info(conn, user_id, now)
    return bool(tr["expired"] and plan == "free" and plan_choice(conn, user_id) is None)


def entitlement_rows(conn: sqlite3.Connection, user_id) -> list[dict]:
    cur = conn.execute("""SELECT source, plan, original_transaction_id, expires_at, status, will_renew, pending_plan,
                                 environment, updated_at FROM entitlements WHERE user_id=?""", (str(user_id),))
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def status(conn: sqlite3.Connection, user: dict, now: datetime | None = None) -> dict:
    """Abo-Stand fuer GET /api/entitlements: Tarif, Rechte, Kontingente, Quelle, Ablauf und geplanter Wechsel."""
    t = _now(now)
    legacy = {"plan": user.get("plan"), "plan_until": user.get("plan_until")}
    plan = current_plan(conn, user["id"], t, legacy)
    rows = entitlement_rows(conn, user["id"])
    active = [r for r in rows if normalize_plan(r["plan"]) == plan and _row_active(r["status"], r["expires_at"], t.isoformat())]
    src = active[0] if active else None
    if not src and plan != "free":
        src = {"source": "manual", "expires_at": user.get("plan_until"), "will_renew": 0, "pending_plan": None}
    quotas = {}
    for feature in plans.QUOTA_LABELS:
        raw = plans.QUOTAS[plan].get(feature, 0)
        quotas[feature] = {"used": used(conn, user["id"], feature, t), "limit": plans.quota_limit(plan, feature),
                           "unlimited": raw is None, "period": t.strftime("%Y-%m")}
    return {
        "plan": plan, "plan_name": PLANS[plan]["name"], "source": src["source"] if src else None,
        "expires_at": src["expires_at"] if src else None, "will_renew": bool(src["will_renew"]) if src else False,
        "pending_plan": src.get("pending_plan") if src else None,
        "entitlements": plans.entitlements(plan), "quotas": quotas,
        "integrations": plans.contract()["integrations"], "mode": "hosted",
        "trial": trial_info(conn, user["id"], t), "plan_choice": plan_choice(conn, user["id"]),
        "needs_plan_choice": needs_plan_choice(conn, user["id"], plan, t),
    }


def local_status() -> dict:
    """Einzelplatzmodus: kein Konto, kein Tarif; alle Rechte, Kontingente ohne Grenze (eigener PC, eigene KI)."""
    return {"plan": LOCAL_PLAN, "plan_name": "Eigener PC", "source": None, "expires_at": None, "will_renew": False,
            "pending_plan": None, "entitlements": {name: True for name in plans.ENTITLEMENTS} | {"chatgpt_connection_premium": False},
            "quotas": {f: {"used": 0, "limit": None, "unlimited": True, "period": period_of()} for f in plans.QUOTA_LABELS},
            "integrations": plans.contract()["integrations"], "mode": "local"}
