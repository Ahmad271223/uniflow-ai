"""Tarife, Berechtigungen und monatliche Kontingente.

VORBEREITET, NICHT EINGEBUNDEN: Der Server laeuft im Einzelplatz-Modus ohne Konten. Dieses Modul legt keine
Tabellen in der echten Datenbank an, solange es nicht ausdruecklich aufgerufen wird (siehe docs/KONTEN-ABOS-PLAN.md).

Regeln:
- Die Berechtigung entscheidet der Server, nie die App allein.
- Hochzaehlen und Grenze pruefen geschieht in einem einzigen UPDATE innerhalb einer Schreibtransaktion
  (BEGIN IMMEDIATE): zwei gleichzeitige Anfragen koennen nicht beide den letzten freien Test bekommen.
- Jede Anfrage traegt eine Anfrage-ID; dieselbe ID zaehlt hoechstens einmal (Wiederholung nach Netzfehler).
- Downgrade loescht nie Daten: Notizen bleiben lesbar und exportierbar, nur Bearbeiten wird gesperrt.
"""
from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone

PLANS: dict[str, dict] = {
    "free": {"rank": 0, "annotate": False, "pencil": False, "split_screen": False, "ai_advanced": False, "ai_tests": 1},
    "plus": {"rank": 1, "annotate": True, "pencil": True, "split_screen": True, "ai_advanced": False, "ai_tests": 6},
    "pro": {"rank": 2, "annotate": True, "pencil": True, "split_screen": True, "ai_advanced": True, "ai_tests": 40},
}

# Apple-Produkte (nur Testkonfiguration, keine echten Produkte) -> Tarif
APPLE_PRODUCTS = {"de.uniflow.plus.monthly": "plus", "de.uniflow.pro.monthly": "pro"}

SCHEMA = """
CREATE TABLE IF NOT EXISTS entitlements (
    user_id INTEGER NOT NULL,
    source TEXT NOT NULL,                 -- app_store | manual | ...
    plan TEXT NOT NULL,
    original_transaction_id TEXT,
    expires_at TEXT,                      -- ISO-8601 UTC, NULL = unbefristet
    status TEXT NOT NULL DEFAULT 'active',-- active | expired | revoked | billing_retry
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, source)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_entitlements_otid ON entitlements(original_transaction_id) WHERE original_transaction_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS usage (
    user_id INTEGER NOT NULL,
    period TEXT NOT NULL,                 -- YYYY-MM
    feature TEXT NOT NULL,                -- ai_tests
    count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, period, feature)
);
CREATE TABLE IF NOT EXISTS usage_requests (
    request_id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL,
    period TEXT NOT NULL,
    feature TEXT NOT NULL,
    created_at TEXT NOT NULL
);
"""


def _now(now: datetime | None) -> datetime:
    return (now or datetime.now(timezone.utc)).astimezone(timezone.utc)


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)


def current_plan(conn: sqlite3.Connection, user_id: int, now: datetime | None = None) -> str:
    """Hoechster aktiver, nicht abgelaufener Tarif; sonst free."""
    t = _now(now).isoformat()
    best = "free"
    for (plan, expires, status) in conn.execute(
            "SELECT plan, expires_at, status FROM entitlements WHERE user_id=?", (user_id,)):
        if status not in ("active", "billing_retry") or plan not in PLANS:
            continue
        if expires and expires <= t:
            continue
        if PLANS[plan]["rank"] > PLANS[best]["rank"]:
            best = plan
    return best


def allowed(conn: sqlite3.Connection, user_id: int, capability: str, now: datetime | None = None) -> bool:
    """Darf der Nutzer diese Funktion nutzen (annotate, pencil, split_screen, ai_advanced)? Lesen ist immer erlaubt."""
    if capability == "read":
        return True
    return bool(PLANS[current_plan(conn, user_id, now)].get(capability))


@dataclass(frozen=True)
class ConsumeResult:
    ok: bool
    used: int
    limit: int
    duplicate: bool = False


def consume(conn: sqlite3.Connection, user_id: int, feature: str, request_id: str,
            now: datetime | None = None) -> ConsumeResult:
    """Ein Kontingent-Element verbrauchen (z. B. einen KI-Test). Sicher gegen parallele Anfragen und Wiederholungen.
    `conn` muss im Autocommit-Modus sein (isolation_level=None), damit die Transaktion hier gesteuert wird."""
    if not request_id:
        raise ValueError("request_id fehlt")
    t = _now(now)
    period = t.strftime("%Y-%m")
    conn.execute("BEGIN IMMEDIATE")
    try:
        plan = current_plan(conn, user_id, t)
        limit = int(PLANS[plan].get(feature, 0))
        seen = conn.execute("SELECT 1 FROM usage_requests WHERE request_id=?", (request_id,)).fetchone()
        used_row = conn.execute("SELECT count FROM usage WHERE user_id=? AND period=? AND feature=?",
                                (user_id, period, feature)).fetchone()
        used = used_row[0] if used_row else 0
        if seen:
            conn.execute("COMMIT")
            return ConsumeResult(ok=True, used=used, limit=limit, duplicate=True)
        conn.execute("INSERT OR IGNORE INTO usage(user_id, period, feature, count) VALUES (?,?,?,0)", (user_id, period, feature))
        cur = conn.execute("UPDATE usage SET count = count + 1 WHERE user_id=? AND period=? AND feature=? AND count < ?",
                           (user_id, period, feature, limit))
        if cur.rowcount == 0:
            conn.execute("ROLLBACK")
            return ConsumeResult(ok=False, used=used, limit=limit)
        conn.execute("INSERT INTO usage_requests(request_id, user_id, period, feature, created_at) VALUES (?,?,?,?,?)",
                     (request_id, user_id, period, feature, t.isoformat()))
        conn.execute("COMMIT")
        return ConsumeResult(ok=True, used=used + 1, limit=limit)
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


def set_entitlement(conn: sqlite3.Connection, user_id: int, source: str, plan: str, *,
                    original_transaction_id: str | None = None, expires_at: str | None = None,
                    status: str = "active", now: datetime | None = None) -> None:
    """Berechtigung setzen (z. B. nach gepruefter App-Store-Transaktion). Ein Downgrade loescht keine Daten."""
    if plan not in PLANS:
        raise ValueError(f"unbekannter Tarif {plan}")
    conn.execute(
        """INSERT INTO entitlements(user_id, source, plan, original_transaction_id, expires_at, status, updated_at)
           VALUES (?,?,?,?,?,?,?)
           ON CONFLICT(user_id, source) DO UPDATE SET plan=excluded.plan,
               original_transaction_id=excluded.original_transaction_id, expires_at=excluded.expires_at,
               status=excluded.status, updated_at=excluded.updated_at""",
        (user_id, source, plan, original_transaction_id, expires_at, status, _now(now).isoformat()))
