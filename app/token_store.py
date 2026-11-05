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

import os
import sys
import threading
from pathlib import Path

TARGET = "StudiNow/dienst-sitzung"
FILE_NAME = "service-token"
MAX_TOKEN = 2048


class StoreError(Exception):
    """Die Ablage ist nicht nutzbar (z. B. Anmeldeinformationsverwaltung gesperrt)."""


class MemoryStore:
    """Nur im Speicher (Tests; Notbehelf, wenn die Windows-Ablage versagt: dann gilt die Anmeldung bis zum Beenden)."""
    kind = "memory"

    def __init__(self, token: str | None = None):
        self._token = token

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

    def path(self) -> Path:
        if self._path is not None:
            return self._path
        from . import config
        return config.DATA_DIR / FILE_NAME

    def get(self) -> str | None:
        try:
            t = self.path().read_text(encoding="utf-8").strip()
        except OSError:
            return None
        return t or None

    def set(self, token: str) -> None:
        p = self.path()
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(token)
        os.replace(tmp, p)

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
        except (OSError, AttributeError):
            return MemoryStore()
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


def get() -> str | None:
    try:
        t = store().get()
    except StoreError:
        return None
    return t if t and len(t) <= MAX_TOKEN else None


def put(token: str | None) -> None:
    """Token speichern (None oder leer = loeschen). Versagt die Windows-Ablage, gilt das Token bis zum Beenden im
    Speicher; geschrieben wird es dann nirgends."""
    global _store
    s = store()
    try:
        if token:
            s.set(token)
        else:
            s.delete()
    except StoreError:
        if token:
            with _lock:
                _store = MemoryStore(token)
