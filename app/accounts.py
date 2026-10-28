"""UniFlow-Konten (Vertrag G1, docs/AUFGABENTEILUNG-APPLE-PC.md): ein Konto fuer alle Geraete.

Zentrale Datenbank `accounts.db` neben den Nutzerordnern (nie in einem Nutzerordner). Jedes Konto hat eine eigene
UniFlow-ID; "Mit Apple/Google anmelden" sind Anmeldewege, die ueber `identities` mit dieser ID verknuepft werden
(nie ueber die E-Mail: Apple liefert Relay-Adressen). Die Daten eines Kontos liegen in einem eigenen Ordner mit
eigener SQLite-Datenbank (`config.user_data_dir`), getrennt wie heute die Hochschulen; dadurch kann keine Abfrage
eines Nutzers Daten eines anderen erreichen.

Passwoerter: scrypt (Standardbibliothek, n=2^14, r=8, p=1, 16-Byte-Salz), nur der Hash wird gespeichert.
Sitzungen: zufaellige Tokens (32 Byte), gespeichert als SHA-256; Ablauf nach 30 Tagen ohne Nutzung; Abmelden auf
allen Geraeten. Passwort-Reset: Einmal-Token, 30 Minuten, kommt nie ueber die API zurueck (nur ueber den
eingestellten Versandweg, siehe `reset_sender`). Fehlversuche je Konto und je Adresse werden in der Datenbank
gezaehlt (gilt auch nach Neustart und mit mehreren Serverprozessen).
"""
from __future__ import annotations

import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable

from . import config

SESSION_DAYS = 30
RESET_MINUTES = 30
MAX_FAILS = 8
MAX_FAILS_IP = 50          # je IP spaeter als je Adresse: an der Hochschule sitzen viele hinter wenigen IPs (NAT, eduroam)
LOCK_MINUTES = 10
VERIFY_HOURS = 48          # Bestaetigungslink fuer die E-Mail-Adresse
# Grenzen (Anzahl, Minuten) je Schluessel; jeder Versuch zaehlt (28.10.2026). IP-Grenzen grosszuegig wegen NAT im
# Hochschulnetz, Adress- und Kontogrenzen streng. LERNAPP_LIMIT_<NAME>=Anzahl/Minuten ueberschreibt (z. B. 50/60).
LIMITS = {"register_ip": (30, 60), "reset_email": (3, 60), "reset_ip": (30, 60), "verify_user": (5, 60), "export_user": (3, 1440)}
PASSWORD_MIN = 10
PASSWORD_MAX = 200
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$")
SCRYPT = {"n": 2 ** 14, "r": 8, "p": 1}

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,                 -- UniFlow-ID (uuid4 hex)
    email TEXT UNIQUE NOT NULL,          -- normalisiert (klein, getrimmt)
    email_verified INTEGER DEFAULT 0,
    pw_hash TEXT,                        -- scrypt$n$r$p$salz$hash (hex); NULL bei reinem Apple/Google-Konto
    university TEXT NOT NULL,            -- luh | hildesheim
    plan TEXT DEFAULT 'free',            -- free | plus | pro_connect | pro_ai (Quelle "manual", app/billing.py)
    plan_until TEXT,
    role TEXT DEFAULT 'user',            -- user | admin
    status TEXT DEFAULT 'active',        -- active | deleted
    created_at TEXT NOT NULL,
    deleted_at TEXT
);
CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash TEXT UNIQUE NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id),
    device_id TEXT,
    device_name TEXT,
    created_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    revoked_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
CREATE TABLE IF NOT EXISTS identities (
    provider TEXT NOT NULL,              -- apple | google
    subject TEXT NOT NULL,               -- stabile Kennung des Anbieters
    user_id TEXT NOT NULL REFERENCES users(id),
    created_at TEXT NOT NULL,
    PRIMARY KEY (provider, subject)
);
CREATE TABLE IF NOT EXISTS reset_tokens (
    token_hash TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT
);
CREATE TABLE IF NOT EXISTS login_attempts (
    key TEXT PRIMARY KEY,                -- email:<adresse> | ip:<adresse>
    fails INTEGER DEFAULT 0,
    last_fail_at TEXT
);
CREATE TABLE IF NOT EXISTS verify_tokens (
    token_hash TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    email TEXT NOT NULL,                 -- Adresse, fuer die der Link gilt
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT
);
CREATE TABLE IF NOT EXISTS rate_limits (
    key TEXT PRIMARY KEY,                -- <grenze>:<ip | adresse | konto>
    count INTEGER NOT NULL,
    window_start TEXT NOT NULL
);
"""


class AccountError(ValueError):
    """Fachlicher Fehler mit stabilem Code (fuer die API und die Fixtures)."""

    def __init__(self, code: str, message: str, status: int = 400, retry_after: int | None = None):
        super().__init__(message)
        self.code, self.message, self.status, self.retry_after = code, message, status, retry_after


# ---------------------------------------------------------------- Zeit und Datenbank

def now() -> datetime:
    return datetime.now(timezone.utc).replace(microsecond=0)


def iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


def db_path() -> Path:
    return config.BASE_DATA_DIR / "accounts.db"


def _migrate(conn) -> None:
    """Spalten fuer bestehende Datenbanken (Muster wie db.init_db): fehlt eine, wird sie angehaengt."""
    def add_col(table, col, decl):
        cols = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
        if col not in cols:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
    add_col("identities", "email", "TEXT")          # vom Anbieter gelieferte Adresse (Apple: Relay), nur zur Anzeige


@contextmanager
def cursor():
    p = db_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(p, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(SCHEMA)
    _migrate(conn)
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------- Normalisierung, Pruefung, Hash

def normalize_email(email: str | None) -> str:
    return (email or "").strip().lower()


def validate_email(email: str) -> None:
    if not EMAIL_RE.match(email) or len(email) > 254:
        raise AccountError("email_invalid", "Bitte eine gültige E-Mail-Adresse angeben.")


def validate_password(password: str | None, email: str = "") -> None:
    pw = password or ""
    if len(pw) < PASSWORD_MIN:
        raise AccountError("password_short", f"Das Passwort braucht mindestens {PASSWORD_MIN} Zeichen.")
    if len(pw) > PASSWORD_MAX:
        raise AccountError("password_long", f"Das Passwort darf höchstens {PASSWORD_MAX} Zeichen haben.")
    if email and pw.strip().lower() == email:
        raise AccountError("password_is_email", "Das Passwort darf nicht die E-Mail-Adresse sein.")


def hash_password(password: str, salt: bytes | None = None) -> str:
    salt = salt or secrets.token_bytes(16)
    h = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=SCRYPT["n"], r=SCRYPT["r"], p=SCRYPT["p"], dklen=32)
    return f"scrypt${SCRYPT['n']}${SCRYPT['r']}${SCRYPT['p']}${salt.hex()}${h.hex()}"


def verify_password(password: str, stored: str | None) -> bool:
    try:
        algo, n, r, p, salt, h = (stored or "").split("$")
        if algo != "scrypt":
            return False
        calc = hashlib.scrypt(password.encode("utf-8"), salt=bytes.fromhex(salt), n=int(n), r=int(r), p=int(p), dklen=32)
        return hmac.compare_digest(calc.hex(), h)
    except (ValueError, TypeError):
        return False


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _public(u) -> dict:
    return {"id": u["id"], "email": u["email"], "email_verified": bool(u["email_verified"]), "university": u["university"],
            "plan": u["plan"], "plan_until": u["plan_until"], "role": u["role"], "created_at": u["created_at"]}


# ---------------------------------------------------------------- Fehlversuche

def _locked(conn, key: str) -> bool:
    r = conn.execute("SELECT fails, last_fail_at FROM login_attempts WHERE key=?", (key,)).fetchone()
    if not r or r["fails"] < (MAX_FAILS_IP if key.startswith("ip:") else MAX_FAILS) or not r["last_fail_at"]:
        return False
    last = datetime.fromisoformat(r["last_fail_at"].replace("Z", "+00:00"))
    return now() - last < timedelta(minutes=LOCK_MINUTES)


def _fail(conn, key: str) -> None:
    r = conn.execute("SELECT fails, last_fail_at FROM login_attempts WHERE key=?", (key,)).fetchone()
    fails = 1
    if r and r["last_fail_at"]:
        last = datetime.fromisoformat(r["last_fail_at"].replace("Z", "+00:00"))
        fails = (r["fails"] + 1) if now() - last < timedelta(minutes=LOCK_MINUTES) else 1
    conn.execute("INSERT INTO login_attempts(key, fails, last_fail_at) VALUES (?,?,?) "
                 "ON CONFLICT(key) DO UPDATE SET fails=excluded.fails, last_fail_at=excluded.last_fail_at", (key, fails, iso(now())))


def _clear_fails(conn, *keys: str) -> None:
    for k in keys:
        conn.execute("DELETE FROM login_attempts WHERE key=?", (k,))


def _limit(name: str) -> tuple[int, int]:
    import os
    raw = (os.environ.get(f"LERNAPP_LIMIT_{name.upper()}") or "").strip()
    if raw:
        try:
            n, m = (int(x) for x in raw.split("/", 1))
            if n > 0 and m > 0:
                return n, m
        except ValueError:
            pass
    return LIMITS[name]


def _hit(conn, name: str, ident: str) -> None:
    """Versuch zaehlen; ueber der Grenze 429 rate_limited mit Wartezeit. Der Zaehler wird sofort gespeichert, auch wenn
    der Aufruf danach mit einem Fehler endet (z. B. email_taken), sonst liesse sich die Grenze umgehen."""
    limit, minutes = _limit(name)
    key, t = f"{name}:{ident}", now()
    r = conn.execute("SELECT count, window_start FROM rate_limits WHERE key=?", (key,)).fetchone()
    start = datetime.fromisoformat(r["window_start"].replace("Z", "+00:00")) if r else None
    if start and t - start < timedelta(minutes=minutes):
        if r["count"] >= limit:
            wait = int((start + timedelta(minutes=minutes) - t).total_seconds()) + 1
            raise AccountError("rate_limited", f"Zu viele Versuche. Bitte in {max(1, wait // 60)} Minuten erneut versuchen.", 429, wait)
        conn.execute("UPDATE rate_limits SET count=count+1 WHERE key=?", (key,))
    else:
        conn.execute("INSERT INTO rate_limits(key, count, window_start) VALUES (?,1,?) "
                     "ON CONFLICT(key) DO UPDATE SET count=1, window_start=excluded.window_start", (key, iso(t)))
    conn.commit()


def hit_limit(name: str, ident: str) -> None:
    """Grenze von aussen pruefen (z. B. Datenexport); wirft AccountError rate_limited."""
    with cursor() as conn:
        _hit(conn, name, ident)


# ---------------------------------------------------------------- Konto anlegen, anmelden, Sitzungen

def register(email: str, password: str, university: str, client_ip: str | None = None) -> dict:
    email = normalize_email(email)
    validate_email(email)
    validate_password(password, email)
    if university not in config.known_universities():
        raise AccountError("university_unknown", "Unbekannte Hochschule.")
    with cursor() as conn:
        if client_ip:
            _hit(conn, "register_ip", client_ip)          # begrenzt auch das Ausprobieren vergebener Adressen
        if conn.execute("SELECT 1 FROM users WHERE email=?", (email,)).fetchone():
            raise AccountError("email_taken", "Für diese E-Mail-Adresse gibt es schon ein Konto.", 409)
        uid = uuid.uuid4().hex
        conn.execute("INSERT INTO users(id, email, pw_hash, university, created_at) VALUES (?,?,?,?,?)",
                     (uid, email, hash_password(password), university, iso(now())))
        return _public(conn.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone())


def create_session(conn, user_id: str, device_id: str | None, device_name: str | None) -> str:
    token = secrets.token_urlsafe(32)
    t = now()
    conn.execute("INSERT INTO sessions(token_hash, user_id, device_id, device_name, created_at, last_seen_at, expires_at) VALUES (?,?,?,?,?,?,?)",
                 (_token_hash(token), user_id, (device_id or "")[:80] or None, (device_name or "")[:120] or None,
                  iso(t), iso(t), iso(t + timedelta(days=SESSION_DAYS))))
    return token


def login(email: str, password: str, device_id: str | None = None, device_name: str | None = None,
          client_ip: str | None = None) -> tuple[dict, str]:
    email = normalize_email(email)
    keys = [f"email:{email}"] + ([f"ip:{client_ip}"] if client_ip else [])
    with cursor() as conn:
        if any(_locked(conn, k) for k in keys):
            raise AccountError("locked", f"Zu viele Fehlversuche. Bitte {LOCK_MINUTES} Minuten warten.", 429)
        u = conn.execute("SELECT * FROM users WHERE email=? AND status='active'", (email,)).fetchone()
        if not u or not verify_password(password, u["pw_hash"]):
            for k in keys:
                _fail(conn, k)
            conn.commit()                  # der Fehlversuch zaehlt auch, wenn gleich die Ausnahme folgt
            raise AccountError("credentials_invalid", "E-Mail-Adresse oder Passwort stimmt nicht.", 401)
        _clear_fails(conn, *keys)
        token = create_session(conn, u["id"], device_id, device_name)
        return _public(u), token


def authenticate(token: str | None) -> dict | None:
    """Nutzer zur Sitzung; verlaengert die Sitzung bei Nutzung (gleitend, hoechstens SESSION_DAYS seit der letzten Nutzung)."""
    if not token:
        return None
    with cursor() as conn:
        s = conn.execute("SELECT s.*, u.status FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=?",
                         (_token_hash(token),)).fetchone()
        if not s or s["revoked_at"] or s["status"] != "active" or s["expires_at"] <= iso(now()):
            return None
        t = now()
        conn.execute("UPDATE sessions SET last_seen_at=?, expires_at=? WHERE id=?",
                     (iso(t), iso(t + timedelta(days=SESSION_DAYS)), s["id"]))
        return _public(conn.execute("SELECT * FROM users WHERE id=?", (s["user_id"],)).fetchone())


def logout(token: str | None) -> bool:
    if not token:
        return False
    with cursor() as conn:
        return conn.execute("UPDATE sessions SET revoked_at=? WHERE token_hash=? AND revoked_at IS NULL",
                            (iso(now()), _token_hash(token))).rowcount > 0


def logout_all(user_id: str, keep_token: str | None = None) -> int:
    with cursor() as conn:
        return conn.execute("UPDATE sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL AND token_hash<>?",
                            (iso(now()), user_id, _token_hash(keep_token) if keep_token else "")).rowcount


def sessions(user_id: str, current_token: str | None = None) -> list[dict]:
    cur = _token_hash(current_token) if current_token else ""
    with cursor() as conn:
        return [{"id": r["id"], "device_id": r["device_id"], "device_name": r["device_name"], "created_at": r["created_at"],
                 "last_seen_at": r["last_seen_at"], "expires_at": r["expires_at"], "current": r["token_hash"] == cur}
                for r in conn.execute("SELECT * FROM sessions WHERE user_id=? AND revoked_at IS NULL AND expires_at>? ORDER BY last_seen_at DESC, id DESC",
                                      (user_id, iso(now())))]


# ---------------------------------------------------------------- Passwort aendern, Reset

def change_password(user_id: str, old: str, new: str) -> None:
    with cursor() as conn:
        u = conn.execute("SELECT * FROM users WHERE id=? AND status='active'", (user_id,)).fetchone()
        if not u or not verify_password(old, u["pw_hash"]):
            raise AccountError("credentials_invalid", "Das bisherige Passwort stimmt nicht.", 401)
        validate_password(new, u["email"])
        conn.execute("UPDATE users SET pw_hash=? WHERE id=?", (hash_password(new), user_id))


# Versandweg fuer Reset-Links: (email, token) -> None. Standard: kein Versand, nur ein Protokolleintrag ohne Token.
# Der Betreiber setzt hier seinen Mailversand ein (oder holt Tokens mit `python -m app.accounts reset-token`).
reset_sender: Callable[[str, str], None] | None = None


def request_password_reset(email: str, client_ip: str | None = None) -> str | None:
    """Legt ein Einmal-Token an und uebergibt es dem Versandweg. Liefert das Token nur an den Aufrufer im Prozess
    (CLI), nie an die API: dort kommt immer dieselbe Antwort, ob es das Konto gibt oder nicht.
    Grenzen: je IP (429, verraet nichts ueber das Konto) und je Adresse (still: keine weitere Mail, gleiche Antwort)."""
    email = normalize_email(email)
    with cursor() as conn:
        if client_ip:
            _hit(conn, "reset_ip", client_ip)
        u = conn.execute("SELECT id FROM users WHERE email=? AND status='active'", (email,)).fetchone()
        if not u:
            return None
        try:
            _hit(conn, "reset_email", email)
        except AccountError:
            return None
        token = secrets.token_urlsafe(32)
        t = now()
        conn.execute("INSERT INTO reset_tokens(token_hash, user_id, created_at, expires_at) VALUES (?,?,?,?)",
                     (_token_hash(token), u["id"], iso(t), iso(t + timedelta(minutes=RESET_MINUTES))))
    if reset_sender:
        reset_sender(email, token)
    return token


def reset_password(token: str, new_password: str) -> None:
    with cursor() as conn:
        r = conn.execute("SELECT * FROM reset_tokens WHERE token_hash=?", (_token_hash(token or ""),)).fetchone()
        if not r or r["used_at"] or r["expires_at"] <= iso(now()):
            raise AccountError("reset_invalid", "Der Link ist ungültig oder abgelaufen.", 400)
        u = conn.execute("SELECT email FROM users WHERE id=? AND status='active'", (r["user_id"],)).fetchone()
        if not u:
            raise AccountError("reset_invalid", "Der Link ist ungültig oder abgelaufen.", 400)
        validate_password(new_password, u["email"])
        # der Link kam per Mail an genau diese Adresse: damit ist sie auch bestaetigt
        conn.execute("UPDATE users SET pw_hash=?, email_verified=1 WHERE id=?", (hash_password(new_password), r["user_id"]))
        conn.execute("UPDATE reset_tokens SET used_at=? WHERE token_hash=?", (iso(now()), r["token_hash"]))
        conn.execute("UPDATE sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL", (iso(now()), r["user_id"]))


# ---------------------------------------------------------------- E-Mail-Adresse bestaetigen (28.10.2026)

# Versandweg fuer Bestaetigungslinks: (email, token) -> None; im Dienst app/mail.py::send_verify (server.py).
verify_sender: Callable[[str, str], None] | None = None


def request_email_verification(user_id: str, send: bool = True, count: bool = True) -> str | None:
    """Bestaetigungslink anlegen (gilt VERIFY_HOURS, nur fuer die aktuelle Adresse) und verschicken. None, wenn das
    Konto fehlt oder schon bestaetigt ist. `count`: zaehlt gegen die Grenze verify_user (erneut senden); der erste
    Link bei der Registrierung zaehlt nicht."""
    with cursor() as conn:
        u = conn.execute("SELECT id, email, email_verified FROM users WHERE id=? AND status='active'", (user_id,)).fetchone()
        if not u or u["email_verified"]:
            return None
        if count:
            _hit(conn, "verify_user", user_id)
        token = secrets.token_urlsafe(32)
        t = now()
        conn.execute("INSERT INTO verify_tokens(token_hash, user_id, email, created_at, expires_at) VALUES (?,?,?,?,?)",
                     (_token_hash(token), user_id, u["email"], iso(t), iso(t + timedelta(hours=VERIFY_HOURS))))
        email = u["email"]
    if send and verify_sender:
        verify_sender(email, token)
    return token


def verify_email(token: str) -> dict:
    """Link einloesen: Adresse des Kontos bestaetigt. Ungueltig, abgelaufen, schon benutzt oder fuer eine andere
    Adresse ausgestellt -> 400 verify_invalid."""
    with cursor() as conn:
        r = conn.execute("SELECT * FROM verify_tokens WHERE token_hash=?", (_token_hash(token or ""),)).fetchone()
        u = conn.execute("SELECT * FROM users WHERE id=? AND status='active'", (r["user_id"],)).fetchone() if r else None
        if not r or r["used_at"] or r["expires_at"] <= iso(now()) or not u or u["email"] != r["email"]:
            raise AccountError("verify_invalid", "Der Bestätigungslink ist ungültig oder abgelaufen.", 400)
        conn.execute("UPDATE users SET email_verified=1 WHERE id=?", (u["id"],))
        conn.execute("UPDATE verify_tokens SET used_at=? WHERE token_hash=?", (iso(now()), r["token_hash"]))
        return _public(conn.execute("SELECT * FROM users WHERE id=?", (u["id"],)).fetchone())


def mark_email_verified(user_id: str) -> dict:
    """Von Hand (Betrieb, Tests): Adresse als bestaetigt markieren."""
    with cursor() as conn:
        conn.execute("UPDATE users SET email_verified=1 WHERE id=?", (user_id,))
        return _public(conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone())


# ---------------------------------------------------------------- Apple / Google als Anmeldeweg

# Pruefer je Anbieter: (identity_token[, nonce=...]) -> {"subject": ..., "email": ..., "email_verified": bool}.
# Im Dienst prueft app/social_login.py die ID-Tokens (Client-IDs des Inhabers in LERNAPP_GOOGLE_CLIENT_IDS /
# LERNAPP_APPLE_CLIENT_IDS); dieses Woerterbuch bleibt fuer Tests und Fixtures. Ohne eingerichteten Pruefer antwortet
# die API 501; es wird nie ein ungeprueftes Token akzeptiert.
identity_verifiers: dict[str, Callable[..., dict]] = {}


def verify_identity(provider: str, identity_token: str, nonce: str | None = None) -> dict:
    v = identity_verifiers.get(provider)
    if not v:
        raise AccountError("provider_not_configured",
                           f"Anmeldung mit {provider.capitalize()} ist noch nicht eingerichtet (Prüfung der Signatur fehlt).", 501)
    try:
        info = v(identity_token, nonce=nonce) if nonce else v(identity_token)
    except Exception as e:  # noqa: BLE001
        raise AccountError("identity_invalid", f"Die Anmeldung bei {provider.capitalize()} konnte nicht geprüft werden: {e}", 401)
    if not info or not info.get("subject"):
        raise AccountError("identity_invalid", f"Die Anmeldung bei {provider.capitalize()} konnte nicht geprüft werden.", 401)
    return info


def link_provider(user_id: str, provider: str, subject: str, email: str | None = None) -> dict:
    """Geprueft (subject vom Anbieter) mit dem Konto verknuepfen; dieselbe Kennung geht nie an ein zweites Konto."""
    with cursor() as conn:
        other = conn.execute("SELECT user_id FROM identities WHERE provider=? AND subject=?", (provider, subject)).fetchone()
        if other and other["user_id"] != user_id:
            raise AccountError("identity_taken", f"Diese {provider.capitalize()}-Anmeldung gehört schon zu einem anderen Konto.", 409)
        conn.execute("INSERT OR IGNORE INTO identities(provider, subject, user_id, email, created_at) VALUES (?,?,?,?,?)",
                     (provider, subject, user_id, normalize_email(email) or None, iso(now())))
    return {"provider": provider, "linked": True}


def link_identity(user_id: str, provider: str, identity_token: str, nonce: str | None = None) -> dict:
    info = verify_identity(provider, identity_token, nonce)
    return link_provider(user_id, provider, info["subject"], info.get("email"))


def login_with_provider(provider: str, subject: str, email: str | None = None, email_verified: bool = False,
                        university: str | None = None, device_id: str | None = None, device_name: str | None = None,
                        fallback_email: str | None = None) -> tuple[dict, str, bool]:
    """Anmelden mit einer GEPRUEFTEN Anbieter-Kennung (app/social_login.py oder ein Pruefer aus `identity_verifiers`).
    1. bekannte Verknuepfung -> Sitzung wie beim normalen Login;
    2. sonst: vom Anbieter bestaetigte E-Mail und ein aktives Konto mit dieser Adresse -> verknuepfen und anmelden;
    3. sonst: neues Konto ohne Passwort (Passwort-Login gesperrt, bis die Person per Reset eines setzt). Dafuer braucht
       es eine Adresse (vom Anbieter, sonst `fallback_email` vom Client, dann unbestaetigt) und die Hochschule.
    Liefert (Nutzer, Token, neu_angelegt)."""
    if provider not in ("apple", "google"):
        raise AccountError("provider_unknown", "Unbekannter Anbieter", 404)
    if not subject:
        raise AccountError("identity_invalid", f"Die Anmeldung bei {provider.capitalize()} konnte nicht geprüft werden.", 401)
    email = normalize_email(email)
    with cursor() as conn:
        row = conn.execute("SELECT u.* FROM identities i JOIN users u ON u.id=i.user_id WHERE i.provider=? AND i.subject=? AND u.status='active'",
                           (provider, subject)).fetchone()
        created = False
        if not row and email and email_verified:
            existing = conn.execute("SELECT * FROM users WHERE email=? AND status='active'", (email,)).fetchone()
            if existing:
                conn.execute("INSERT OR IGNORE INTO identities(provider, subject, user_id, email, created_at) VALUES (?,?,?,?,?)",
                             (provider, subject, existing["id"], email, iso(now())))
                row = existing
        if not row:
            new_email = email or normalize_email(fallback_email)
            if not new_email:
                raise AccountError("email_required", "Der Anbieter hat keine E-Mail-Adresse geliefert; bitte die Adresse mitschicken "
                                                     "oder mit E-Mail registrieren.", 400)
            validate_email(new_email)
            if conn.execute("SELECT 1 FROM users WHERE email=?", (new_email,)).fetchone():
                raise AccountError("email_taken", "Für diese E-Mail-Adresse gibt es schon ein Konto. Bitte dort anmelden und die "
                                                  f"{provider.capitalize()}-Anmeldung verknüpfen.", 409)
            if university not in config.known_universities():
                raise AccountError("university_unknown", "Bitte die Hochschule angeben.")
            uid = uuid.uuid4().hex
            conn.execute("INSERT INTO users(id, email, email_verified, pw_hash, university, created_at) VALUES (?,?,?,?,?,?)",
                         (uid, new_email, 1 if (email and email_verified) else 0, None, university, iso(now())))
            conn.execute("INSERT INTO identities(provider, subject, user_id, email, created_at) VALUES (?,?,?,?,?)",
                         (provider, subject, uid, email or None, iso(now())))
            row = conn.execute("SELECT * FROM users WHERE id=?", (uid,)).fetchone()
            created = True
        token = create_session(conn, row["id"], device_id, device_name)
        return _public(row), token, created


def login_with_identity(provider: str, identity_token: str, device_id: str | None = None, device_name: str | None = None,
                        university: str | None = None, nonce: str | None = None, fallback_email: str | None = None) -> tuple[dict, str, bool]:
    """Anmelden ueber Apple/Google mit einem Token, das ein Pruefer aus `identity_verifiers` bestaetigt; Ablauf wie
    `login_with_provider`. Liefert (Nutzer, Token, neu_angelegt)."""
    info = verify_identity(provider, identity_token, nonce)
    return login_with_provider(provider, info["subject"], info.get("email"), bool(info.get("email_verified")),
                               university, device_id, device_name, fallback_email)


# ---------------------------------------------------------------- Hochschule, Loeschen

def set_university(user_id: str, university: str) -> dict:
    if university not in config.known_universities():
        raise AccountError("university_unknown", "Unbekannte Hochschule.")
    with cursor() as conn:
        conn.execute("UPDATE users SET university=? WHERE id=? AND status='active'", (university, user_id))
        return _public(conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone())


def delete_account(user_id: str, password: str | None = None) -> dict:
    """Konto sofort sperren (alle Sitzungen weg), Daten endgueltig nach 30 Tagen (`purge_deleted`). Die E-Mail wird
    freigegeben (umbenannt), damit die Person sich neu registrieren kann."""
    with cursor() as conn:
        u = conn.execute("SELECT * FROM users WHERE id=? AND status='active'", (user_id,)).fetchone()
        if not u:
            raise AccountError("not_found", "Konto nicht gefunden.", 404)
        if u["pw_hash"] and not verify_password(password or "", u["pw_hash"]):
            raise AccountError("credentials_invalid", "Zum Löschen bitte das Passwort angeben.", 401)
        t = iso(now())
        conn.execute("UPDATE users SET status='deleted', deleted_at=?, email=?, pw_hash=NULL WHERE id=?",
                     (t, f"deleted-{user_id}@invalid", user_id))
        conn.execute("UPDATE sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL", (t, user_id))
        conn.execute("DELETE FROM identities WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM reset_tokens WHERE user_id=?", (user_id,))
        if _has_table(conn, "sync_jobs"):                    # wartende Abgleiche laufen nicht mehr
            conn.execute("UPDATE sync_jobs SET status='failed', finished_at=?, message='Konto gelöscht' "
                         "WHERE user_id=? AND status='queued'", (t, user_id))
    config.retire_user_data_dir(user_id)
    from . import community
    community.withdraw_all(user_id, "account_deleted")      # Community-Beitraege sofort nicht mehr sichtbar
    return {"deleted": True, "purge_after_days": 30}


# Tabellen in accounts.db mit Spalte user_id, die beim endgueltigen Loeschen geleert werden (dazu jede Tabelle mit
# Fremdschluessel auf users, siehe _purge_user). ai_usage_log bleibt ohne Konto-Bezug fuer die Kostenrechnung.
ACCOUNT_TABLES = ("vault", "sync_jobs", "entitlements", "usage", "usage_requests", "ai_inflight", "apple_transactions",
                  "identities", "reset_tokens", "verify_tokens", "sessions")


def _has_table(conn, name: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _purge_user(conn, user_id: str) -> None:
    """Alles eines Kontos endgueltig entfernen (28.10.2026). Vorher loeschte purge_deleted nur Sitzungen und die
    Nutzerzeile; Tresor (Hochschul-Zugangsdaten) und Abgleich-Auftraege verweisen per Fremdschluessel auf users, also
    scheiterte das Loeschen, sobald ein Konto Zugangsdaten hatte, und Abo-, Nutzungs- und Community-Daten blieben."""
    from . import community, test_library, vault
    community.forget_author(user_id)
    test_library.forget_owner(user_id)
    tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    for t in ACCOUNT_TABLES:
        if t in tables:
            conn.execute(f"DELETE FROM {t} WHERE user_id=?", (user_id,))
    for t in tables:                                        # jede weitere Tabelle mit Fremdschluessel auf users
        for fk in conn.execute(f"PRAGMA foreign_key_list({t})").fetchall():
            if fk[2] == "users" and t != "users":
                conn.execute(f"DELETE FROM {t} WHERE {fk[3]}=?", (user_id,))
    if "ai_usage_log" in tables:
        conn.execute("UPDATE ai_usage_log SET user_id=NULL WHERE user_id=?", (user_id,))
    conn.execute("DELETE FROM users WHERE id=?", (user_id,))
    vault._cache.pop(user_id, None)


def purge_deleted(days: int = 30) -> int:
    """Endgueltig loeschen: Konten, die seit `days` Tagen geloescht sind, mit allen Daten (_purge_user) und dem
    beiseitegelegten Datenordner. Ein Fehler bei einem Konto haelt die anderen nicht auf (Sicherungspunkt je Konto)."""
    import logging
    import shutil
    cutoff = iso(now() - timedelta(days=days))
    n = 0
    with cursor() as conn:
        for r in conn.execute("SELECT id FROM users WHERE status='deleted' AND deleted_at<=?", (cutoff,)).fetchall():
            conn.execute("SAVEPOINT purge_user")
            try:
                _purge_user(conn, r["id"])
            except Exception:  # noqa: BLE001 - beim naechsten Lauf erneut, die uebrigen Konten laufen weiter
                conn.execute("ROLLBACK TO purge_user")
                conn.execute("RELEASE purge_user")
                logging.getLogger("uniflow.accounts").exception("Konto %s nicht endgueltig geloescht", r["id"])
                continue
            conn.execute("RELEASE purge_user")
            for d in config.retired_user_data_dirs(r["id"]):
                shutil.rmtree(d, ignore_errors=True)
            n += 1
    return n


def set_plan(user_id: str, plan: str, until: str | None = None) -> dict:
    """Tarif von Hand setzen (Quelle "manual": Betrieb, Tests, Gutscheine). Kaeufe aus dem App Store laufen ueber
    app/apple_store.py in die Tabelle entitlements; es gilt der hoechste aktive Tarif beider Quellen (app/billing.py)."""
    from . import billing
    plan = billing.normalize_plan(plan) or ""
    if not plan:
        raise AccountError("plan_invalid", "Unbekannter Tarif (free, plus, pro_connect, pro_ai).")
    with cursor() as conn:
        conn.execute("UPDATE users SET plan=?, plan_until=? WHERE id=?", (plan, until, user_id))
        return _public(conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone())


def set_role(user_id: str, role: str) -> dict:
    if role not in ("user", "admin"):
        raise AccountError("role_invalid", "Unbekannte Rolle.")
    with cursor() as conn:
        conn.execute("UPDATE users SET role=? WHERE id=?", (role, user_id))
        return _public(conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone())


def user_by_email(email: str) -> dict | None:
    with cursor() as conn:
        u = conn.execute("SELECT * FROM users WHERE email=?", (normalize_email(email),)).fetchone()
        return _public(u) if u else None


def get_user(user_id: str) -> dict | None:
    with cursor() as conn:
        u = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        return _public(u) if u else None


# ---------------------------------------------------------------- Kommandozeile (Betrieb)

def main(argv: list[str]) -> int:
    """python -m app.accounts reset-token <email> | purge | list | plan <email> free|plus|pro_connect|pro_ai [bis YYYY-MM-DD] | role <email> user|admin"""
    cmd = argv[0] if argv else ""
    if cmd in ("plan", "role") and len(argv) >= 3:
        u = user_by_email(argv[1])
        if not u:
            print("Kein Konto mit dieser Adresse.")
            return 1
        try:
            out = set_plan(u["id"], argv[2], argv[3] if len(argv) > 3 else None) if cmd == "plan" else set_role(u["id"], argv[2])
        except AccountError as e:
            print(e.message if hasattr(e, "message") else str(e))
            return 1
        print(json.dumps({k: out[k] for k in ("email", "plan", "plan_until", "role")}, ensure_ascii=False))
        return 0
    if cmd == "reset-token" and len(argv) == 2:
        tok = request_password_reset(argv[1])
        print(tok or "Kein aktives Konto mit dieser Adresse.")
        return 0
    if cmd == "purge":
        print(f"{purge_deleted()} Konten endgültig gelöscht.")
        return 0
    if cmd == "list":
        with cursor() as conn:
            for r in conn.execute("SELECT id, email, university, plan, status, created_at FROM users ORDER BY created_at"):
                print(json.dumps(dict(r), ensure_ascii=False))
        return 0
    print(main.__doc__)
    return 2


if __name__ == "__main__":
    import sys
    raise SystemExit(main(sys.argv[1:]))
