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

ABGESCHALTET (Entscheidung 06.11.2026, "Ja, abschalten"): StudiNow speichert Hochschul-Passwoerter, -Schluessel und
-Sitzungen nie auf dem Server, auch nicht fuer die Web-Version. `set_values` nimmt keine Werte mehr an (nur noch
Loeschen), `purge_all` leert die Tabelle beim Start des Dienstes, `users_with_credentials` ist immer leer: der
Hochschul-Abgleich laeuft auf dem iPad oder in der Windows-App. Die Windows-App (Einzelplatz, app/desktop.py) legt
optional eingetragene Hochschul-Zugangsdaten in der .env im Benutzerprofil ab (LERNAPP_ENV_FILE, nur auf diesem PC),
die Hochschul-Sitzung in der Sitzungsdatei des Datenordners (app/unilogin.py, 0600); nur das StudiNow-Konto-Token
liegt in der Windows-Anmeldeinformationsverwaltung (app/token_store.py). Nichts davon erreicht den Dienst. Die Tabelle
bleibt leer bestehen (Kontoloeschung und Datenexport lesen sie); `secret.key` bleibt, weil Pseudonyme (Community,
Testbibliothek) daraus abgeleitet werden.
"""
from __future__ import annotations

import base64
import os
import secrets
import time
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from . import accounts, config

VERSION = "v1"
NOT_STORED_MESSAGE = ("StudiNow speichert keine Hochschul-Passwörter auf dem Server. "
                      "Der Abgleich läuft auf deinem iPad oder in der Windows-App.")


class CredentialsNotStored(Exception):
    """Ein Wert sollte im Tresor landen: im Dienst nie (Entscheidung 06.11.2026). Die API antwortet 410."""

    def __init__(self):
        super().__init__(NOT_STORED_MESSAGE)
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
        if not p.exists():
            _create_key_file(p)
        key = _read_key_file(p)
    _master = key
    return key


def _create_key_file(p: Path) -> None:
    """secret.key einmalig anlegen, auch wenn mehrere Prozesse gleichzeitig starten (Audit 08.11.2026, P16-01/P16-07):
    der Schluessel geht zuerst vollstaendig in eine eindeutige Temp-Datei (O_EXCL, Rechte 0600 ab dem Anlegen), dann
    per Hardlink an den Zielnamen - das gelingt genau einem Prozess, die anderen lesen danach die gewinnende Datei.
    Ein Leser sieht nie eine halb geschriebene Datei. Ohne Hardlinks (z. B. FAT) direkt mit O_EXCL."""
    p.parent.mkdir(parents=True, exist_ok=True)
    data = base64.b64encode(secrets.token_bytes(32))
    tmp = p.with_name(f"{p.name}.{os.getpid()}.{secrets.token_hex(6)}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0), 0o600)
    try:
        try:
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
        try:
            os.link(tmp, p)
        except FileExistsError:
            pass                                          # ein anderer Prozess war schneller: dessen Datei gilt
        except OSError:
            try:
                fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0), 0o600)
            except FileExistsError:
                return
            try:
                os.write(fd, data)
                os.fsync(fd)
            finally:
                os.close(fd)
    finally:
        tmp.unlink(missing_ok=True)


def _read_key_file(p: Path) -> bytes:
    """Gewinnende Datei lesen; eine leere oder kaputte Datei ist ein Fehler, nie ein leerer Schluessel. Kurz
    wiederholen fuer den Fall ohne Hardlinks, in dem ein anderer Prozess gerade noch schreibt."""
    for _ in range(50):
        try:
            key = base64.b64decode(p.read_text(encoding="ascii").strip(), validate=True)
        except (OSError, ValueError):
            key = b""
        if len(key) == 32:
            return key
        time.sleep(0.02)
    raise RuntimeError(f"{p.name} ist unlesbar oder nicht 32 Byte lang; Datei pruefen oder LERNAPP_SECRET_KEY setzen")


def key_file() -> Path:
    return config.BASE_DATA_DIR / "secret.key"


def reset_master() -> None:
    """Fuer Tests: Geheimnis neu laden."""
    global _master
    _master = None
    _cache.clear()
    _stamps.clear()


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
    """None loescht den Wert. Namen wie in der .env (Grossbuchstaben, Unterstrich).
    Seit 06.11.2026 nur noch Loeschen: ein nicht leerer Wert loest `CredentialsNotStored` aus, bevor etwas geschrieben wird."""
    if any(v is not None and str(v).strip() != "" for v in values.values()):
        raise CredentialsNotStored()
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
    broken = []
    for r in rows:
        try:
            out[r["name"]] = decrypt(user_id, r["value_enc"])
        except Exception:  # noqa: BLE001 - anderes Geheimnis oder manipuliert: Wert gilt als nicht gesetzt
            broken.append(r["name"])
    if broken:                                            # P16-09: nur Namen und Anzahl, nie Wert oder Konto
        print(f"[vault] {len(broken)} Tresor-Eintrag/-Eintraege nicht entschluesselbar (anderes Geheimnis oder "
              f"beschaedigt), gelten als nicht gesetzt: {', '.join(sorted(broken))}", flush=True)
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


def purge_all() -> int:
    """Beim Start des Dienstes (06.11.2026): alle Tresor-Eintraege aller Konten loeschen. Liefert nur die Anzahl."""
    cm, conn = _conn()
    try:
        conn.execute("PRAGMA secure_delete=ON")          # geloeschte Chiffrate in der Datei mit Nullen ueberschreiben
        n = conn.execute("DELETE FROM vault").rowcount
    finally:
        cm.__exit__(None, None, None)
    if n:
        import sqlite3
        try:                                              # alte Seiten auch aus dem WAL holen
            c = sqlite3.connect(accounts.db_path(), timeout=15)
            c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            c.close()
        except sqlite3.Error:
            pass
    _cache.clear()
    _stamps.clear()
    return n


def purge_at_startup() -> int:
    """Gehosteter Modus: Tresor leeren und die Anzahl protokollieren (keine Namen, keine Konten)."""
    if not config.is_hosted():
        return 0
    n = purge_all()
    print(f"[vault] Hochschul-Zugangsdaten werden nicht gespeichert: {n} Tresor-Eintraege geloescht", flush=True)
    return n


def has_university_credentials(user_id: str, university: str) -> bool:
    """Seit 06.11.2026 immer False: der Dienst gleicht nie mit gespeicherten Zugangsdaten ab."""
    return False


def users_with_credentials() -> list[tuple[str, str]]:
    """Seit 06.11.2026 immer leer: kein Konto hat Zugangsdaten im Dienst, der Zeitplan legt keinen Hochschul-Abgleich an."""
    return []
