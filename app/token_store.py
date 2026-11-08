"""Ablage des Sitzungs-Tokens des StudiNow-Kontos am eigenen PC (Windows-App, 05.11.2026).

Gespeichert wird nur das Sitzungs-Token des Dienstes (gleitend 30 Tage, `accounts.SESSION_DAYS`; es ist zugleich das
Erneuerungs-Token, denn jede Nutzung verlaengert es), nie das Passwort. Der Dienst kann es jederzeit widerrufen
(Abmelden, "Andere Geraete abmelden", Konto loeschen).

Warum hier in Python und nicht in Tauri: Das Token braucht allein der lokale Python-Server (er ruft den Dienst auf);
das Tauri-Fenster sieht es nie. Die Windows-Anmeldeinformationsverwaltung (Credential Manager) wird direkt ueber
`advapi32` (CredWriteW/CredReadW/CredDeleteW) mit ctypes angesprochen: keine neue Abhaengigkeit (das Paket `keyring`
braucht unter Windows zusaetzlich pywin32-ctypes und versteckte Importe fuer PyInstaller), keine Aenderung am
Rust-Teil. Eintrag: Typ CRED_TYPE_GENERIC, Ziel "StudiNow/dienst-sitzung", Speicherung CRED_PERSIST_LOCAL_MACHINE
(nur dieser Windows-Benutzer auf diesem PC, wandert nicht mit einem Roaming-Profil). Windows verschluesselt den Inhalt
mit den Anmeldedaten des Benutzers (DPAPI).

Ausserhalb von Windows (Entwicklung auf dem Mac, Tests) liegt das Token in einer Datei mit Rechten 0600 im
Datenordner (`service-token`). Tests tauschen die Ablage ueber `use()` gegen `MemoryStore`.
"""
from __future__ import annotations

import logging
import os
import re
import sys
import tempfile
import threading
from pathlib import Path

TARGET = "StudiNow/dienst-sitzung"
FILE_NAME = "service-token"
MAX_TOKEN = 2048
CRED_MAX_CREDENTIAL_BLOB_SIZE = 5 * 512   # Windows: groesster Inhalt eines generischen Eintrags (Byte)
# Zeichen eines Bearer-Tokens (RFC 6750 b64token); der Dienst vergibt secrets.token_urlsafe(32), 43 Zeichen. Kein
# Leer- oder Steuerzeichen: das Token steht spaeter in "Authorization: Bearer ..." (Audit P17-04, P18-11)
_TOKEN_RE = re.compile(r"[A-Za-z0-9._~+/=-]{1,%d}" % MAX_TOKEN)
log = logging.getLogger("uniflow.token_store")


class StoreError(Exception):
    """Die Ablage ist nicht nutzbar (z. B. Anmeldeinformationsverwaltung gesperrt)."""


class TokenInvalid(ValueError):
    """Kein gueltiges Sitzungs-Token (Typ, Laenge, Zeichen); wird nicht gespeichert."""


def valid_token(token) -> bool:
    return isinstance(token, str) and bool(_TOKEN_RE.fullmatch(token))


class MemoryStore:
    """Nur im Speicher (Tests; Notbehelf, wenn die Windows-Ablage versagt: dann gilt die Anmeldung bis zum Beenden)."""
    kind = "memory"

    def __init__(self, token: str | None = None, fallback: bool = False):
        self._token = token
        self.fallback = fallback          # True = Notbehelf statt der dauerhaften Ablage (nach Neustart weg)

    def get(self) -> str | None:
        return self._token

    def set(self, token: str) -> None:
        self._token = token

    def delete(self) -> None:
        self._token = None


class FileStore:
    """Datei mit Rechten 0600 (Entwicklung ausserhalb von Windows)."""
    kind = "file"

    def __init__(self, path: Path | None = None):
        self._path = path
        self._lock = threading.Lock()

    def path(self) -> Path:
        if self._path is not None:
            return self._path
        from . import config
        return config.DATA_DIR / FILE_NAME

    def get(self) -> str | None:
        """Fehlt die Datei: None (nicht angemeldet). Ist sie nicht lesbar: StoreError, damit das nicht wie eine
        Abmeldung aussieht (Audit P17-07)."""
        try:
            t = self.path().read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            return None
        except (OSError, UnicodeDecodeError) as e:
            raise StoreError(f"Token-Datei nicht lesbar ({type(e).__name__})") from None
        return t or None

    def set(self, token: str) -> None:
        """Eindeutige Temp-Datei (mkstemp: O_EXCL, 0600) im selben Ordner, dann atomar ersetzen; ein Schreiber je
        Ablage zugleich (Audit P17-02, P17-03: frueher fester Name `service-token.tmp`, Rechte einer schon vorhandenen
        Datei blieben stehen)."""
        p = self.path()
        with self._lock:
            p.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix=p.name + ".", suffix=".tmp", dir=p.parent)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(token)
                os.replace(tmp, p)
            except BaseException:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise

    def delete(self) -> None:
        self.path().unlink(missing_ok=True)


class WindowsCredentialStore:
    """Windows-Anmeldeinformationsverwaltung ueber advapi32 (nur unter Windows ladbar)."""
    kind = "windows_credential_manager"
    CRED_TYPE_GENERIC = 1
    CRED_PERSIST_LOCAL_MACHINE = 2
    ERROR_NOT_FOUND = 1168

    def __init__(self, target: str = TARGET):
        import ctypes
        from ctypes import wintypes
        self.target = target
        self._ct = ctypes

        class FILETIME(ctypes.Structure):
            _fields_ = [("dwLowDateTime", wintypes.DWORD), ("dwHighDateTime", wintypes.DWORD)]

        class CREDENTIALW(ctypes.Structure):
            _fields_ = [("Flags", wintypes.DWORD), ("Type", wintypes.DWORD), ("TargetName", wintypes.LPWSTR),
                        ("Comment", wintypes.LPWSTR), ("LastWritten", FILETIME), ("CredentialBlobSize", wintypes.DWORD),
                        ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)), ("Persist", wintypes.DWORD),
                        ("AttributeCount", wintypes.DWORD), ("Attributes", ctypes.c_void_p),
                        ("TargetAlias", wintypes.LPWSTR), ("UserName", wintypes.LPWSTR)]

        self._CRED = CREDENTIALW
        adv = ctypes.WinDLL("advapi32", use_last_error=True)          # type: ignore[attr-defined]
        self._write = adv.CredWriteW
        self._write.argtypes = [ctypes.POINTER(CREDENTIALW), wintypes.DWORD]
        self._write.restype = wintypes.BOOL
        self._read = adv.CredReadW
        self._read.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(ctypes.POINTER(CREDENTIALW))]
        self._read.restype = wintypes.BOOL
        self._delete = adv.CredDeleteW
        self._delete.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
        self._delete.restype = wintypes.BOOL
        self._free = adv.CredFree
        self._free.argtypes = [ctypes.c_void_p]
        self._free.restype = None

    def get(self) -> str | None:
        ct = self._ct
        p = ct.POINTER(self._CRED)()
        if not self._read(self.target, self.CRED_TYPE_GENERIC, 0, ct.byref(p)):
            if ct.get_last_error() == self.ERROR_NOT_FOUND:
                return None
            raise StoreError(f"Anmeldeinformationsverwaltung nicht lesbar (Fehler {ct.get_last_error()})")
        try:
            c = p.contents
            raw = ct.string_at(c.CredentialBlob, c.CredentialBlobSize)
        finally:
            self._free(p)
        return raw.decode("utf-8") or None

    def set(self, token: str) -> None:
        ct = self._ct
        blob = token.encode("utf-8")
        if len(blob) > CRED_MAX_CREDENTIAL_BLOB_SIZE:          # Audit P17-05: vor CredWriteW pruefen
            raise StoreError(f"Token zu gross fuer die Anmeldeinformationsverwaltung ({len(blob)} Byte)")
        buf = (ct.c_ubyte * len(blob)).from_buffer_copy(blob)
        cred = self._CRED()
        cred.Type = self.CRED_TYPE_GENERIC
        cred.TargetName = self.target
        cred.Comment = "StudiNow: Sitzung des StudiNow-Kontos (kein Passwort)"
        cred.CredentialBlobSize = len(blob)
        cred.CredentialBlob = ct.cast(buf, ct.POINTER(ct.c_ubyte))
        cred.Persist = self.CRED_PERSIST_LOCAL_MACHINE
        cred.UserName = "StudiNow"
        if not self._write(ct.byref(cred), 0):
            raise StoreError(f"Anmeldeinformationsverwaltung nicht beschreibbar (Fehler {ct.get_last_error()})")

    def delete(self) -> None:
        ct = self._ct
        if not self._delete(self.target, self.CRED_TYPE_GENERIC, 0) and ct.get_last_error() != self.ERROR_NOT_FOUND:
            raise StoreError(f"Eintrag nicht loeschbar (Fehler {ct.get_last_error()})")


_store = None
_lock = threading.Lock()


def default_store():
    """Windows: Anmeldeinformationsverwaltung; sonst Datei. Laesst sich advapi32 nicht laden, bleibt das Token nur im
    Speicher (nie stillschweigend in eine Datei unter Windows)."""
    if sys.platform == "win32":
        try:
            return WindowsCredentialStore()
        except (OSError, AttributeError) as e:
            log.warning("Anmeldeinformationsverwaltung nicht nutzbar (%s): Anmeldung gilt nur im Speicher bis zum "
                        "Beenden", type(e).__name__)
            return MemoryStore(fallback=True)
    return FileStore()


def store():
    global _store
    with _lock:
        if _store is None:
            _store = default_store()
        return _store


def use(s) -> None:
    """Ablage austauschen (Tests); None = beim naechsten Zugriff wieder die Standardablage."""
    global _store
    with _lock:
        _store = s


def kind() -> str:
    return getattr(store(), "kind", "unknown")


def persistent() -> bool:
    """Ueberlebt das Token einen Neustart? False beim Notbehelf im Speicher (Audit P17-06, P18-09); fuer die Anzeige
    (`service_link.status_info`: token_persistent) und damit ein altes Token nicht aus seiner Datei verschwindet."""
    return not getattr(store(), "fallback", False)


def get() -> str | None:
    try:
        t = store().get()
    except StoreError as e:
        log.warning("Sitzungs-Token nicht lesbar: %s", e)          # nie der Inhalt
        return None
    return t if valid_token(t) else None


def put(token: str | None) -> bool:
    """Token speichern (None oder leer = loeschen); ein ungueltiges Token wirft TokenInvalid, das alte bleibt
    (Audit P17-04: frueher gespeichert und nach dem Neustart von get() verworfen). Versagt die Windows-Ablage, gilt
    das Token bis zum Beenden im Speicher; geschrieben wird es dann nirgends. Liefert True, wenn der Stand dauerhaft
    ist, False beim Notbehelf."""
    global _store
    if token and not valid_token(token):
        raise TokenInvalid("Ungueltiges Sitzungs-Token")
    s = store()
    try:
        if token:
            s.set(token)
        else:
            s.delete()
    except StoreError as e:
        if not token:
            log.warning("Sitzungs-Token nicht geloescht: %s", e)
            return False
        log.warning("Sitzungs-Token nicht gespeichert (%s): gilt nur im Speicher bis zum Beenden", e)
        with _lock:
            _store = MemoryStore(token, fallback=True)
        return False
    return not getattr(s, "fallback", False)
