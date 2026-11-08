"""Verschluesselte Ablage lokaler Geheimnisse in der .env der Windows-App (08.11.2026, Punkt 6 der Windows-Fertigstellung).

Bis dahin lagen QIS-, Stud.IP-, Learnweb- und HsH-Passwoerter, gemerkte Cookies und der Learnweb-Schluessel im Klartext
in `%LOCALAPPDATA%\\de.uniflow.desktop\\.env`. Jetzt schreibt `config.set_env` solche Werte (Schluessel mit `_PASSWORD`,
`_COOKIES` oder `_TOKEN`) nur noch verschluesselt und `config._env` entschluesselt sie beim Lesen; `migrate_env_file`
verschluesselt beim Start der App einmal den Altbestand.

- Windows: DPAPI (`CryptProtectData`/`CryptUnprotectData`, crypt32 ueber ctypes, Benutzerbereich, kein Dialog) wie der
  Schluesselbund auf dem iPad: nur dieser Windows-Benutzer auf diesem PC kann die Werte lesen. Form `dpapi:<base64>`.
- Ausserhalb von Windows (Entwicklung, Tests): AES-GCM mit einem zufaelligen Schluessel in `local-secrets.key` (0600) im
  Datenordner. Form `local:<base64(nonce+ciphertext)>`. Schuetzt gegen Mitlesen der .env allein, nicht gegen einen
  Angreifer mit Zugriff auf den ganzen Datenordner - das kann nur DPAPI/der Schluesselbund.

Das Verschluesseln beim Schreiben gilt in der Windows-App (LERNAPP_DESKTOP=1) und mit LERNAPP_ENCRYPT_ENV=1 (Tests); der
Entwicklungsserver laesst die .env lesbar (`LERNAPP_ENCRYPT_ENV=0` erzwingt das auch in der App - nur zur Fehlersuche).
Entschluesselt wird immer. Die Werte gehen nie an den Dienst; der Dienst speichert keine Hochschul-Zugangsdaten
(Entscheidung 06.11.2026).
"""
from __future__ import annotations

import base64
import os
import secrets
import sys
import threading
from pathlib import Path

DPAPI_PREFIX = "dpapi:"
LOCAL_PREFIX = "local:"
PREFIXES = (DPAPI_PREFIX, LOCAL_PREFIX)
SECRET_SUFFIXES = ("_PASSWORD", "_COOKIES", "_TOKEN")
KEY_FILE = "local-secrets.key"
ENTROPY = b"StudiNow/.env"          # bindet DPAPI-Werte an StudiNow (ein anderes Programm desselben Nutzers muesste sie kennen)
ENV_FLAG = "LERNAPP_ENCRYPT_ENV"

_lock = threading.Lock()
_key: bytes | None = None


class SecretError(Exception):
    """Ver- oder Entschluesseln nicht moeglich (z. B. anderer Windows-Benutzer, Schluesseldatei weg)."""


def is_secret_key(name: str | None) -> bool:
    return bool(name) and str(name).upper().endswith(SECRET_SUFFIXES)


def is_protected(value) -> bool:
    return isinstance(value, str) and value.startswith(PREFIXES)


def encrypt_on_write() -> bool:
    """Beim Schreiben verschluesseln? Windows-App ja, Tests mit LERNAPP_ENCRYPT_ENV=1, sonst nein."""
    flag = os.environ.get(ENV_FLAG)
    if flag in ("0", "1"):
        return flag == "1"
    return os.environ.get("LERNAPP_DESKTOP") == "1"


def backend() -> str:
    """dpapi unter Windows, sonst local."""
    return "dpapi" if sys.platform == "win32" else "local"


# ---------------------------------------------------------------- Windows: DPAPI

def _dpapi(data: bytes, protect: bool) -> bytes:
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)      # type: ignore[attr-defined]
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)    # type: ignore[attr-defined]
    buf_in = ctypes.create_string_buffer(data, len(data))
    blob_in = DATA_BLOB(len(data), ctypes.cast(buf_in, ctypes.POINTER(ctypes.c_char)))
    buf_ent = ctypes.create_string_buffer(ENTROPY, len(ENTROPY))
    blob_ent = DATA_BLOB(len(ENTROPY), ctypes.cast(buf_ent, ctypes.POINTER(ctypes.c_char)))
    blob_out = DATA_BLOB()
    CRYPTPROTECT_UI_FORBIDDEN = 0x01
    fn = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    if protect:
        ok = fn(ctypes.byref(blob_in), "StudiNow", ctypes.byref(blob_ent), None, None, CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(blob_out))
    else:
        ok = fn(ctypes.byref(blob_in), None, ctypes.byref(blob_ent), None, None, CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(blob_out))
    if not ok:
        raise SecretError(f"DPAPI-Fehler {ctypes.get_last_error()}")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


# ---------------------------------------------------------------- sonst: AES-GCM mit Schluesseldatei

def key_path() -> Path:
    from . import config
    return config.DATA_DIR / KEY_FILE


def _local_key() -> bytes:
    global _key
    with _lock:
        if _key is not None:
            return _key
        p = key_path()
        try:
            raw = base64.b64decode(p.read_text(encoding="ascii").strip())
            if len(raw) != 32:
                raise ValueError("falsche Laenge")
        except (OSError, ValueError):
            raw = secrets.token_bytes(32)
            p.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="ascii") as f:
                f.write(base64.b64encode(raw).decode("ascii"))
        _key = raw
        return raw


def reset_cache() -> None:
    """Tests: Schluessel neu laden (anderer Datenordner)."""
    global _key
    with _lock:
        _key = None


def _local_encrypt(data: bytes) -> bytes:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    nonce = secrets.token_bytes(12)
    return nonce + AESGCM(_local_key()).encrypt(nonce, data, ENTROPY)


def _local_decrypt(data: bytes) -> bytes:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    try:
        return AESGCM(_local_key()).decrypt(data[:12], data[12:], ENTROPY)
    except Exception as e:  # noqa: BLE001 - InvalidTag u. a.
        raise SecretError(f"Wert nicht entschluesselbar: {type(e).__name__}") from None


# ---------------------------------------------------------------- oeffentlich

def protect(value: str) -> str:
    """Klartext -> geschuetzter Wert (idempotent: ein geschuetzter Wert bleibt, wie er ist)."""
    if not isinstance(value, str) or value == "" or is_protected(value):
        return value
    raw = value.encode("utf-8")
    if backend() == "dpapi":
        return DPAPI_PREFIX + base64.b64encode(_dpapi(raw, True)).decode("ascii")
    return LOCAL_PREFIX + base64.b64encode(_local_encrypt(raw)).decode("ascii")


def unprotect(value):
    """Geschuetzter Wert -> Klartext; Klartext bleibt. Nicht entschluesselbar (anderer Benutzer, Schluessel weg): leer,
    damit die App laeuft und der Nutzer das Passwort neu eintraegt (nie ein Absturz beim Lesen der .env)."""
    if not is_protected(value):
        return value
    try:
        if value.startswith(DPAPI_PREFIX):
            if backend() != "dpapi":
                raise SecretError("DPAPI-Wert ausserhalb von Windows")
            return _dpapi(base64.b64decode(value[len(DPAPI_PREFIX):]), False).decode("utf-8")
        return _local_decrypt(base64.b64decode(value[len(LOCAL_PREFIX):])).decode("utf-8")
    except (SecretError, ValueError, UnicodeDecodeError):
        return ""


def protect_values(values: dict) -> dict:
    """Fuer config.set_env: geheime Schluessel verschluesseln, wenn das Schreiben verschluesselt sein soll."""
    if not encrypt_on_write():
        return values
    return {k: (protect(str(v)) if v is not None and is_secret_key(k) else v) for k, v in values.items()}


def unprotect_values(values: dict) -> dict:
    """Fuer config._env: alle geschuetzten Werte entschluesseln (unabhaengig vom Schreibmodus)."""
    return {k: (unprotect(v) if is_protected(v) else v) for k, v in values.items()}


def migrate_env_file(path: Path) -> int:
    """Klartext-Geheimnisse in einer .env einmal verschluesseln (Start der Windows-App). Liefert die Zahl der Zeilen;
    0, wenn nichts zu tun ist oder das Schreiben nicht verschluesselt sein soll. Schreibt atomar."""
    if not encrypt_on_write() or not path.is_file():
        return 0
    from dotenv import dotenv_values
    values = dotenv_values(path, interpolate=False)
    todo = {k: v for k, v in values.items() if is_secret_key(k) and isinstance(v, str) and v and not is_protected(v)}
    if not todo:
        return 0
    from . import config
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        key = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else None
        out.append(f"{key}={config._env_quote(protect(todo[key]))}" if key in todo else line)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("\n".join(out) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    return len(todo)


def storage_label() -> str:
    """Fuer die Oberflaeche: wo und wie Passwoerter auf diesem PC liegen."""
    if not encrypt_on_write():
        return "plain"
    return backend()
