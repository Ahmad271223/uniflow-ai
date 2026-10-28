"""Hochschul-Zugangsdaten je Konto, verschluesselt (gehosteter Modus).

Werte wie in der .env des Einzelplatzmodus (STUDIP_USER, STUDIP_PASSWORD, HILDESHEIM_USER, HILDESHEIM_PASSWORD,
QIS_SAME_AS, LEARNWEB_TOKEN, ...) liegen je Konto in `accounts.db` (Tabelle `vault`), jeder Wert einzeln mit
AES-256-GCM verschluesselt. Der Schluessel je Konto kommt per HKDF-SHA256 aus dem Dienst-Geheimnis
(`LERNAPP_SECRET_KEY`, 32 Byte base64/hex; ohne Angabe eine beim ersten Start erzeugte Datei `secret.key` neben den
Nutzerordnern). Die Konto-ID ist zusaetzlich als AAD gebunden: ein Wert eines Kontos laesst sich nicht als Wert eines
anderen unterschieben.

Warum ein Dienst-Schluessel und keiner aus dem Nutzerpasswort: der Abgleich laeuft zweimal taeglich ohne den Nutzer.
Ein Datenbank-Abzug allein gibt die Zugangsdaten nicht preis; Geheimnis und Datenbank gehoeren getrennt aufbewahrt.
Der Nutzer kann seine Zugangsdaten jederzeit loeschen (`delete`), damit endet auch der automatische Abgleich.
"""
from __future__ import annotations

import base64
import os
import secrets
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from . import accounts, config

VERSION = "v1"
_master: bytes | None = None
_cache: dict[str, dict[str, str]] = {}
_stamps: dict[str, tuple] = {}          # Stand in der Datenbank je Konto beim Einlesen (P10)

SCHEMA = """
CREATE TABLE IF NOT EXISTS vault (
    user_id TEXT NOT NULL REFERENCES users(id),
    name TEXT NOT NULL,                  -- wie der .env-Schluessel, z. B. STUDIP_PASSWORD
    value_enc TEXT NOT NULL,             -- v1:<base64(nonce || ciphertext)>
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, name)
);
"""


def master_key() -> bytes:
    """Dienst-Geheimnis: LERNAPP_SECRET_KEY (base64 oder hex, 32 Byte) oder die Datei secret.key (wird erzeugt)."""
    global _master
    if _master:
        return _master
    raw = (os.environ.get("LERNAPP_SECRET_KEY") or "").strip()
    if raw:
        try:
            key = bytes.fromhex(raw) if len(raw) == 64 else base64.b64decode(raw, validate=True)
        except ValueError as e:
            raise RuntimeError("LERNAPP_SECRET_KEY muss 32 Byte als base64 oder hex sein") from e
        if len(key) != 32:
            raise RuntimeError("LERNAPP_SECRET_KEY muss 32 Byte lang sein")
    else:
        p = key_file()
        if p.exists():
            key = base64.b64decode(p.read_text(encoding="ascii").strip())
        else:
            key = secrets.token_bytes(32)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(base64.b64encode(key).decode("ascii"), encoding="ascii")
            try:
                os.chmod(p, 0o600)
            except OSError:
                pass
    _master = key
    return key


def key_file() -> Path:
    return config.BASE_DATA_DIR / "secret.key"


def reset_master() -> None:
    """Fuer Tests: Geheimnis neu laden."""
    global _master
    _master = None
    _cache.clear()


def user_key(user_id: str) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b"uniflow-vault:" + user_id.encode("ascii")).derive(master_key())


def encrypt(user_id: str, value: str) -> str:
    nonce = secrets.token_bytes(12)
    ct = AESGCM(user_key(user_id)).encrypt(nonce, value.encode("utf-8"), user_id.encode("ascii"))
    return VERSION + ":" + base64.b64encode(nonce + ct).decode("ascii")


def decrypt(user_id: str, token: str) -> str:
    ver, _, b64 = (token or "").partition(":")
    if ver != VERSION:
        raise ValueError("Unbekanntes Format")
    raw = base64.b64decode(b64)
    return AESGCM(user_key(user_id)).decrypt(raw[:12], raw[12:], user_id.encode("ascii")).decode("utf-8")


def _conn():
    cm = accounts.cursor()
    conn = cm.__enter__()
    from . import db
    db.schema_once(conn, "vault", accounts.db_path(), lambda c: c.executescript(SCHEMA))
    return cm, conn


def set_values(user_id: str, values: dict[str, str | None]) -> None:
    """None loescht den Wert. Namen wie in der .env (Grossbuchstaben, Unterstrich)."""
    cm, conn = _conn()
    try:
        now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        for name, value in values.items():
            if not name.replace("_", "").isalnum() or name != name.upper():
                raise ValueError(f"Ungueltiger Name: {name}")
            if value is None or str(value).strip() == "":
                conn.execute("DELETE FROM vault WHERE user_id=? AND name=?", (user_id, name))
            else:
                conn.execute("INSERT INTO vault(user_id, name, value_enc, updated_at) VALUES (?,?,?,?) "
                             "ON CONFLICT(user_id, name) DO UPDATE SET value_enc=excluded.value_enc, updated_at=excluded.updated_at",
                             (user_id, name, encrypt(user_id, str(value)), now))
    finally:
        cm.__exit__(None, None, None)
    _cache.pop(user_id, None)


def env_for(user_id: str) -> dict[str, str]:
    """Alle entschluesselten Werte eines Kontos (wie ein .env-Abbild), mit Zwischenspeicher bis zur naechsten Aenderung.
    Der Zwischenspeicher gilt nur, solange der Stand in der Datenbank derselbe ist (P10, 28.10.2026): aendert ein
    anderer Prozess (Arbeiter fuer den Hochschul-Abgleich, zweiter API-Prozess) die Werte, wird neu gelesen. Der
    Vergleich ist eine Abfrage ohne Entschluesseln; die Chiffrate haben zufaellige Nonces, jede Aenderung aendert sie."""
    cm, conn = _conn()
    try:
        st = tuple(conn.execute("SELECT COUNT(*), MAX(updated_at), MAX(value_enc), MIN(value_enc) FROM vault WHERE user_id=?",
                                (user_id,)).fetchone())
        hit = _cache.get(user_id)
        if hit is not None and _stamps.get(user_id) == st:
            return dict(hit)
        rows = conn.execute("SELECT name, value_enc FROM vault WHERE user_id=?", (user_id,)).fetchall()
    finally:
        cm.__exit__(None, None, None)
    _stamps[user_id] = st
    out = {}
    for r in rows:
        try:
            out[r["name"]] = decrypt(user_id, r["value_enc"])
        except Exception:  # noqa: BLE001 - anderes Geheimnis oder manipuliert: Wert gilt als nicht gesetzt
            continue
    _cache[user_id] = out
    return dict(out)


def delete_all(user_id: str) -> int:
    cm, conn = _conn()
    try:
        n = conn.execute("DELETE FROM vault WHERE user_id=?", (user_id,)).rowcount
    finally:
        cm.__exit__(None, None, None)
    _cache.pop(user_id, None)
    return n


def has_university_credentials(user_id: str, university: str) -> bool:
    """Reichen die gespeicherten Werte fuer den Abgleich dieser Hochschule?"""
    env = env_for(user_id)
    if university == "hildesheim":
        return bool((env.get("HILDESHEIM_USER") and env.get("HILDESHEIM_PASSWORD")) or env.get("LEARNWEB_TOKEN")
                    or _has_cookies(env.get("LEARNWEB_COOKIES")))
    return bool((env.get("STUDIP_USER") and env.get("STUDIP_PASSWORD")) or _has_cookies(env.get("STUDIP_COOKIES")))


def _has_cookies(raw: str | None) -> bool:
    """Sitzung, die die App auf dem Geraet nach der Anmeldung im Anmeldefenster hinterlegt hat (nicht abgelaufen)."""
    import json
    import time
    try:
        cookies = json.loads(raw) if raw else []
    except ValueError:
        return False
    now = time.time()
    return any(isinstance(c, dict) and c.get("name") and (not c.get("expires") or c["expires"] < 0 or c["expires"] > now)
               for c in cookies)


def users_with_credentials() -> list[tuple[str, str]]:
    """(Konto-ID, Hochschule) aller aktiven Konten, die Zugangsdaten fuer ihre Hochschule hinterlegt haben."""
    cm, conn = _conn()
    try:
        rows = conn.execute("SELECT DISTINCT u.id, u.university FROM users u JOIN vault v ON v.user_id=u.id WHERE u.status='active'").fetchall()
    finally:
        cm.__exit__(None, None, None)
    return [(r["id"], r["university"]) for r in rows if has_university_credentials(r["id"], r["university"])]
