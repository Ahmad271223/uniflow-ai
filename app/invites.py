"""Einladungen ("Freunde einladen") mit Belohnungen als Apple-Angebotscodes (Entscheidung des Inhabers 04.11.2026).

Regeln:
- Waehrend der 7-Tage-Probe (oder in den ersten 7 Tagen des Kontos) kann eine Person bis zu 20 Einladungslinks
  anlegen: `https://studinow.app/i/<CODE>`, Code 10 Zeichen ohne verwechselbare Zeichen, gueltig 30 Tage.
- Gezaehlt wird jede eingeladene Person, die StudiNow neu beginnt und sich anmeldet: ein NEUES Konto (nach dem Link
  angelegt, innerhalb der 30 Tage), hoechstens eine Einloesung je Person, nie das eigene Konto. Die App ruft dafuer
  nach der ersten Anmeldung einmal POST /api/invites/redeem; der Aufruf ist idempotent.
- Belohnungen in Stufen (`TIERS`, Fixture packages/shared-contracts/fixtures/invites/cases.json, in Swift
  `InviteRewards`): 5 Personen -> 1 Monat Plus gratis, 10 -> 3 Monate Plus gratis, 20 -> 12 Monate Plus gratis ODER
  Pro AI 12 Monate zum Plus-Preis (1,99 EUR). Jede Stufe laesst sich einmal einloesen.
- Apple-Regeln: Belohnungen gibt es nur als Angebotscodes (App Store Connect, je Produkt), eingeloest in Apples Dialog
  (`https://apps.apple.com/redeem?ctx=offercodes&id=<APP_ID>&code=<CODE>`). Der Dienst schaltet nie selbst einen Tarif
  frei; er gibt nur den Code aus seinem Vorrat heraus. Den Vorrat laedt der Betrieb als Stapel hoch
  (POST /api/billing/offer-codes, Export aus App Store Connect). Ist der Vorrat leer: 409 offer_codes_exhausted.
- Loeschen des Kontos: eigene Links, Einloesungen (als Eingeladener und als Einladender) und Belohnungen werden
  entfernt (accounts.ACCOUNT_TABLES, `forget_user`); ein schon ausgegebener Angebotscode bleibt als ausgegeben
  vermerkt, ohne Konto. Der Datenexport enthaelt die eigenen Einladungen (`export_rows`).

Tabellen in accounts.db: invites, invite_redemptions, offer_codes, invite_rewards.
"""
from __future__ import annotations

import os
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone

from . import billing, db, plans

LINK_BASE = "https://studinow.app/i/"
CODE_LENGTH = 10
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"           # ohne 0/O, 1/I/L
MAX_PER_USER = 20
LINK_DAYS = 30
CREATE_DAYS = 7                                              # Links nur in der Probe bzw. den ersten 7 Tagen des Kontos
STOCK_WARN_BELOW = 5                                         # Hinweis fuer den Betrieb, wenn der Vorrat einer Stufe knapp wird
APP_ID_ENV = "LERNAPP_APPLE_APP_ID"
EXHAUSTED_MESSAGE = "Für diese Belohnung sind gerade keine Codes hinterlegt – bitte später noch einmal versuchen."

# Stufen (aufsteigend). `choices`: welche Angebotscodes es fuer die Stufe gibt (Produkt in offer_codes.product).
TIERS: tuple[dict, ...] = (
    {"count": 5, "choices": ("plus",), "label": "1 Monat Plus gratis"},
    {"count": 10, "choices": ("plus",), "label": "3 Monate Plus gratis"},
    {"count": 20, "choices": ("plus", "proai"), "label": "12 Monate Plus gratis oder Pro AI 12 Monate zum Plus-Preis"},
)
# Wahl -> Produkt im Vorrat (offer_codes.product) und Text
CHOICES: dict[str, dict] = {
    "plus": {"product": "plus", "apple_product_id": plans.PLANS["plus"]["apple_product_id"]},
    "proai": {"product": "pro_ai", "apple_product_id": plans.PLANS["pro_ai"]["apple_product_id"]},
}
# Text je Stufe und Wahl (so steht es in der Oberflaeche und im Dokument docs/EINLADUNGEN.md)
REWARD_LABELS: dict[tuple[int, str], str] = {
    (5, "plus"): "1 Monat StudiNow Plus gratis",
    (10, "plus"): "3 Monate StudiNow Plus gratis",
    (20, "plus"): "12 Monate StudiNow Plus gratis",
    (20, "proai"): "12 Monate StudiNow Pro AI zum Plus-Preis (1,99 € statt 3,99 €)",
}

SCHEMA = """
CREATE TABLE IF NOT EXISTS invites (
    code TEXT PRIMARY KEY,                 -- 10 Zeichen aus CODE_ALPHABET
    user_id TEXT NOT NULL,                 -- wer einlaedt
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL               -- created_at + 30 Tage
);
CREATE INDEX IF NOT EXISTS idx_invites_user ON invites(user_id);
CREATE TABLE IF NOT EXISTS invite_redemptions (
    code TEXT NOT NULL,
    user_id TEXT NOT NULL UNIQUE,          -- eingeladene Person: hoechstens eine Einloesung je Konto
    inviter_id TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_invite_redemptions_inviter ON invite_redemptions(inviter_id);
CREATE TABLE IF NOT EXISTS offer_codes (
    code TEXT PRIMARY KEY,                 -- Angebotscode aus App Store Connect
    product TEXT NOT NULL,                 -- plus | pro_ai
    tier INTEGER NOT NULL,                 -- 5 | 10 | 20
    uploaded_at TEXT NOT NULL,
    assigned_to TEXT,                      -- Konto, das ihn bekommen hat (NULL = frei)
    assigned_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_offer_codes_free ON offer_codes(product, tier, assigned_to);
CREATE TABLE IF NOT EXISTS invite_rewards (
    user_id TEXT NOT NULL,
    tier INTEGER NOT NULL,
    choice TEXT NOT NULL,                  -- plus | proai
    offer_code TEXT NOT NULL,
    claimed_at TEXT NOT NULL,
    PRIMARY KEY (user_id, tier)            -- jede Stufe einmal
);
"""


class InviteError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


def _now(now: datetime | None = None) -> datetime:
    return (now or datetime.now(timezone.utc)).astimezone(timezone.utc).replace(microsecond=0)


def _parse(s: str | None) -> datetime | None:
    if not s:
        return None
    return datetime.fromisoformat(str(s).replace("Z", "+00:00")).astimezone(timezone.utc)


def ensure_schema(conn: sqlite3.Connection) -> None:
    if conn.in_transaction:
        conn.commit()
    conn.executescript(SCHEMA)


def connect() -> sqlite3.Connection:
    from . import accounts
    conn = billing.connect()
    db.schema_once(conn, "invites", accounts.db_path(), ensure_schema)
    return conn


# ---------------------------------------------------------------- Stufen (reine Funktionen, Fixture in beiden Welten)

def reward_tier(count: int) -> int | None:
    """Hoechste erreichte Stufe (5, 10, 20) fuer so viele angekommene Personen; None unter der ersten Stufe."""
    reached = None
    for t in TIERS:
        if int(count) >= t["count"]:
            reached = t["count"]
    return reached


def tiers_reached(count: int) -> list[int]:
    return [t["count"] for t in TIERS if int(count) >= t["count"]]


def tier_for(count: int) -> dict | None:
    return next((t for t in TIERS if t["count"] == int(count)), None)


def contract() -> dict:
    """Stufen als JSON (Fixture packages/shared-contracts/fixtures/invites/cases.json, Abschnitt "tiers")."""
    return {"max_links": MAX_PER_USER, "link_days": LINK_DAYS, "create_days": CREATE_DAYS, "link_base": LINK_BASE,
            "tiers": [{"count": t["count"], "choices": list(t["choices"]),
                       "rewards": {c: REWARD_LABELS[(t["count"], c)] for c in t["choices"]}} for t in TIERS]}


# ---------------------------------------------------------------- Codes

def new_code() -> str:
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))


def normalize_code(code: str | None) -> str:
    """Eingabe aus Link, QR oder Tastatur: gross, ohne Leerzeichen und Bindestriche; nur Zeichen des Alphabets."""
    raw = "".join(ch for ch in str(code or "").upper() if ch not in " -_\t\r\n")
    if raw.startswith(LINK_BASE.upper()):
        raw = raw[len(LINK_BASE):]
    return raw.strip("/")


def link_for(code: str) -> str:
    return LINK_BASE + code


def app_id() -> str | None:
    v = (os.environ.get(APP_ID_ENV) or "").strip()
    return v or None


def redeem_url(code: str) -> str | None:
    """Apples Einloese-Dialog fuer den Angebotscode; None, solange die Apple-ID der App nicht eingetragen ist."""
    aid = app_id()
    return f"https://apps.apple.com/redeem?ctx=offercodes&id={aid}&code={code}" if aid else None


# ---------------------------------------------------------------- Einladende Person

def _user_row(conn: sqlite3.Connection, user_id: str) -> tuple | None:
    return conn.execute("SELECT created_at, role FROM users WHERE id=?", (user_id,)).fetchone()


def create_window(conn: sqlite3.Connection, user_id: str, now: datetime | None = None) -> tuple[bool, str | None]:
    """Darf das Konto gerade Links anlegen? (in der Probe oder in den ersten 7 Tagen) und bis wann."""
    t = _now(now)
    row = _user_row(conn, user_id)
    if not row:
        return False, None
    created = _parse(row[0]) or t
    until = created + timedelta(days=CREATE_DAYS)
    tr = billing.trial_info(conn, user_id, t)
    if tr["active"] and tr["ends_at"]:
        ends = _parse(tr["ends_at"]) or until
        until = max(until, ends)
    return t < until, until.isoformat()


def create(conn: sqlite3.Connection, user_id: str, now: datetime | None = None) -> dict:
    """Neuen Einladungslink anlegen (hoechstens 20 je Konto, nur im Anlegefenster)."""
    uid, t = str(user_id), _now(now)
    conn.execute("BEGIN IMMEDIATE")
    try:
        ok, until = create_window(conn, uid, t)
        if not ok:
            conn.execute("ROLLBACK")
            raise InviteError("invite_window_closed", "Einladungslinks gibt es nur in der Probewoche. Deine bestehenden Links "
                                                      "gelten weiter.", 403)
        n = conn.execute("SELECT COUNT(*) FROM invites WHERE user_id=?", (uid,)).fetchone()[0]
        if n >= MAX_PER_USER:
            conn.execute("ROLLBACK")
            raise InviteError("invite_limit", f"Du hast schon {MAX_PER_USER} Einladungslinks – mehr gibt es nicht.", 409)
        code = new_code()
        while conn.execute("SELECT 1 FROM invites WHERE code=?", (code,)).fetchone():
            code = new_code()
        expires = t + timedelta(days=LINK_DAYS)
        conn.execute("INSERT INTO invites(code, user_id, created_at, expires_at) VALUES (?,?,?,?)",
                     (code, uid, t.isoformat(), expires.isoformat()))
        conn.execute("COMMIT")
    except InviteError:
        raise
    except Exception:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    return {"code": code, "url": link_for(code), "created_at": t.isoformat(), "expires_at": expires.isoformat(),
            "redemptions": 0, "expired": False}


def arrived(conn: sqlite3.Connection, user_id: str) -> int:
    """Angekommene Personen: Einloesungen aller Links dieses Kontos."""
    return conn.execute("SELECT COUNT(*) FROM invite_redemptions WHERE inviter_id=?", (str(user_id),)).fetchone()[0]


def stock(conn: sqlite3.Connection) -> dict[str, dict[str, int]]:
    """Freie Angebotscodes je Produkt und Stufe (nur Betrieb)."""
    out: dict[str, dict[str, int]] = {}
    for t in TIERS:
        for c in t["choices"]:
            product = CHOICES[c]["product"]
            n = conn.execute("SELECT COUNT(*) FROM offer_codes WHERE product=? AND tier=? AND assigned_to IS NULL",
                             (product, t["count"])).fetchone()[0]
            out.setdefault(product, {})[str(t["count"])] = n
    return out


def overview(conn: sqlite3.Connection, user: dict, now: datetime | None = None) -> dict:
    """GET /api/invites: eigene Links, Zaehler, Stufen (erreicht, eingeloest, einloesbar); Vorrat nur fuer Admins."""
    uid, t = str(user["id"]), _now(now)
    rows = conn.execute("SELECT code, created_at, expires_at FROM invites WHERE user_id=? ORDER BY created_at", (uid,)).fetchall()
    counts = dict(conn.execute("SELECT code, COUNT(*) FROM invite_redemptions WHERE inviter_id=? GROUP BY code", (uid,)).fetchall())
    codes = [{"code": r[0], "url": link_for(r[0]), "created_at": r[1], "expires_at": r[2], "redemptions": counts.get(r[0], 0),
              "expired": (_parse(r[2]) or t) <= t} for r in rows]
    count = sum(counts.values())
    claimed = {r[0]: {"tier": r[0], "choice": r[1], "offer_code": r[2], "claimed_at": r[3], "redeem_url": redeem_url(r[2])}
               for r in conn.execute("SELECT tier, choice, offer_code, claimed_at FROM invite_rewards WHERE user_id=?", (uid,)).fetchall()}
    tiers = []
    for tdef in TIERS:
        n = tdef["count"]
        reached = count >= n
        tiers.append({"count": n, "choices": list(tdef["choices"]),
                      "rewards": {c: REWARD_LABELS[(n, c)] for c in tdef["choices"]},
                      "reached": reached, "claimed": claimed.get(n), "claimable": reached and n not in claimed})
    can_create, until = create_window(conn, uid, t)
    out = {"codes": codes, "arrived": count, "max_links": MAX_PER_USER, "remaining_links": max(0, MAX_PER_USER - len(codes)),
           "can_create": can_create and len(codes) < MAX_PER_USER, "create_until": until, "link_days": LINK_DAYS,
           "link_base": LINK_BASE, "tier": reward_tier(count), "tiers": tiers, "apple_app_id": app_id()}
    if user.get("role") == "admin":
        st = stock(conn)
        out["stock"] = st
        out["stock_warning"] = [f"{p}:{tier}" for p, by_tier in st.items() for tier, n in by_tier.items() if n < STOCK_WARN_BELOW]
    return out


# ---------------------------------------------------------------- Eingeladene Person

def redeem(conn: sqlite3.Connection, user: dict, code: str, now: datetime | None = None) -> dict:
    """Einloesung durch das neue Konto (einmal je Person, idempotent). Prueft: Code bekannt, nicht das eigene Konto,
    Konto nach dem Link angelegt, innerhalb der 30 Tage."""
    uid, t = str(user["id"]), _now(now)
    code = normalize_code(code)
    conn.execute("BEGIN IMMEDIATE")
    try:
        old = conn.execute("SELECT code, inviter_id, created_at FROM invite_redemptions WHERE user_id=?", (uid,)).fetchone()
        if old:
            conn.execute("COMMIT")
            return {"redeemed": True, "already": True, "code": old[0], "created_at": old[2]}
        inv = conn.execute("SELECT code, user_id, created_at, expires_at FROM invites WHERE code=?", (code,)).fetchone()
        if not inv or len(code) != CODE_LENGTH:
            conn.execute("ROLLBACK")
            raise InviteError("invite_unknown", "Diesen Einladungslink gibt es nicht.", 404)
        if inv[1] == uid:
            conn.execute("ROLLBACK")
            raise InviteError("invite_self", "Den eigenen Einladungslink kannst du nicht einlösen.", 400)
        if not conn.execute("SELECT 1 FROM users WHERE id=? AND status='active'", (inv[1],)).fetchone():
            conn.execute("ROLLBACK")
            raise InviteError("invite_unknown", "Diesen Einladungslink gibt es nicht mehr.", 404)
        link_created, link_expires = _parse(inv[2]) or t, _parse(inv[3]) or t
        row = _user_row(conn, uid)
        account_created = (_parse(row[0]) if row else None) or t
        if account_created < link_created:
            conn.execute("ROLLBACK")
            raise InviteError("invite_account_older", "Einladungen zählen nur für neue Konten, die nach dem Link angelegt wurden.", 400)
        if account_created > link_expires or t > link_expires:
            conn.execute("ROLLBACK")
            raise InviteError("invite_expired", "Dieser Einladungslink ist abgelaufen (30 Tage).", 410)
        conn.execute("INSERT INTO invite_redemptions(code, user_id, inviter_id, created_at) VALUES (?,?,?,?)",
                     (code, uid, inv[1], t.isoformat()))
        conn.execute("COMMIT")
    except InviteError:
        raise
    except Exception:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    return {"redeemed": True, "already": False, "code": code, "created_at": t.isoformat()}


# ---------------------------------------------------------------- Belohnung einloesen

def claim(conn: sqlite3.Connection, user: dict, tier: int, choice: str, now: datetime | None = None) -> dict:
    """Angebotscode fuer eine erreichte Stufe herausgeben (einmal je Stufe; ein zweiter Aufruf liefert denselben Code).
    Leerer Vorrat: 409 offer_codes_exhausted. Der Tarif wird nie hier freigeschaltet, nur in Apples Dialog."""
    uid, t = str(user["id"]), _now(now)
    try:
        tier = int(tier)
    except (TypeError, ValueError):
        raise InviteError("invite_tier_invalid", "Unbekannte Stufe.", 400)
    tdef = tier_for(tier)
    if not tdef:
        raise InviteError("invite_tier_invalid", "Unbekannte Stufe.", 400)
    choice = str(choice or "plus")
    if choice not in tdef["choices"]:
        raise InviteError("invite_choice_invalid", "Diese Belohnung gibt es für die Stufe nicht.", 400)
    product = CHOICES[choice]["product"]
    conn.execute("BEGIN IMMEDIATE")
    try:
        old = conn.execute("SELECT choice, offer_code, claimed_at FROM invite_rewards WHERE user_id=? AND tier=?", (uid, tier)).fetchone()
        if old:
            conn.execute("COMMIT")
            return _claimed(tier, old[0], old[1], old[2], already=True)
        if arrived(conn, uid) < tier:
            conn.execute("ROLLBACK")
            raise InviteError("invite_tier_not_reached", f"Diese Stufe ist noch nicht erreicht ({tier} Personen).", 403)
        free = conn.execute("SELECT code FROM offer_codes WHERE product=? AND tier=? AND assigned_to IS NULL ORDER BY uploaded_at, code LIMIT 1",
                            (product, tier)).fetchone()
        if not free:
            conn.execute("ROLLBACK")
            raise InviteError("offer_codes_exhausted", EXHAUSTED_MESSAGE, 409)
        conn.execute("UPDATE offer_codes SET assigned_to=?, assigned_at=? WHERE code=? AND assigned_to IS NULL", (uid, t.isoformat(), free[0]))
        conn.execute("INSERT INTO invite_rewards(user_id, tier, choice, offer_code, claimed_at) VALUES (?,?,?,?,?)",
                     (uid, tier, choice, free[0], t.isoformat()))
        conn.execute("COMMIT")
    except InviteError:
        raise
    except Exception:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise
    return _claimed(tier, choice, free[0], t.isoformat(), already=False)


def _claimed(tier: int, choice: str, code: str, at: str, already: bool) -> dict:
    return {"tier": tier, "choice": choice, "offer_code": code, "claimed_at": at, "already": already,
            "redeem_url": redeem_url(code), "apple_product_id": CHOICES[choice]["apple_product_id"],
            "reward": REWARD_LABELS[(tier, choice)]}


# ---------------------------------------------------------------- Betrieb: Vorrat hochladen

def upload_codes(conn: sqlite3.Connection, product: str, tier: int, codes: list[str], now: datetime | None = None) -> dict:
    """Stapel aus App Store Connect (eine Zeile je Code) in den Vorrat legen. Doppelte werden uebersprungen."""
    t = _now(now)
    product = billing.normalize_plan(product) or ""
    try:
        tier = int(tier)
    except (TypeError, ValueError):
        raise InviteError("invite_tier_invalid", "Unbekannte Stufe.", 400)
    tdef = tier_for(tier)
    if not tdef:
        raise InviteError("invite_tier_invalid", "Unbekannte Stufe (5, 10 oder 20).", 400)
    if product not in {CHOICES[c]["product"] for c in tdef["choices"]}:
        raise InviteError("offer_product_invalid", f"Für Stufe {tier} gibt es keine Codes für dieses Produkt.", 400)
    clean, total = [], 0
    for c in codes:
        s = str(c or "").strip()
        if s and not s.startswith("#"):
            total += 1
            if s not in clean:
                clean.append(s)
    if not clean:
        raise InviteError("offer_codes_missing", "Keine Codes im Stapel.", 400)
    added = 0
    conn.execute("BEGIN IMMEDIATE")
    try:
        for c in clean:
            cur = conn.execute("INSERT OR IGNORE INTO offer_codes(code, product, tier, uploaded_at) VALUES (?,?,?,?)",
                               (c, product, tier, t.isoformat()))
            added += cur.rowcount
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return {"added": added, "skipped": total - added, "stock": stock(conn)}


# ---------------------------------------------------------------- Loeschen und Export

def forget_user(conn: sqlite3.Connection, user_id: str) -> None:
    """Endgueltiges Loeschen (accounts._purge_user): Zeilen mit user_id entfernt ACCOUNT_TABLES; hier zusaetzlich die
    Einloesungen, bei denen das Konto der Einladende war, und der Konto-Bezug ausgegebener Angebotscodes."""
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if "invite_redemptions" in tables:
        conn.execute("DELETE FROM invite_redemptions WHERE inviter_id=?", (user_id,))
    if "offer_codes" in tables:
        conn.execute("UPDATE offer_codes SET assigned_to=? WHERE assigned_to=?", ("deleted:" + secrets.token_hex(8), user_id))


def export_rows(conn: sqlite3.Connection, user_id: str) -> dict:
    """Fuer konto.json im Datenexport."""
    def rows(sql, params):
        try:
            cur = conn.execute(sql, params)
            names = [d[0] for d in cur.description]
            return [dict(zip(names, r)) for r in cur.fetchall()]
        except sqlite3.OperationalError:
            return []
    uid = str(user_id)
    return {"links": rows("SELECT code, created_at, expires_at FROM invites WHERE user_id=? ORDER BY created_at", (uid,)),
            "angekommen": rows("SELECT code, created_at FROM invite_redemptions WHERE inviter_id=? ORDER BY created_at", (uid,)),
            "eingeloest": rows("SELECT code, created_at FROM invite_redemptions WHERE user_id=?", (uid,)),
            "belohnungen": rows("SELECT tier, choice, offer_code, claimed_at FROM invite_rewards WHERE user_id=? ORDER BY tier", (uid,))}
