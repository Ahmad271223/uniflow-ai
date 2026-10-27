"""Zwischenstand eines laufenden Abgleichs fuer die Anzeige ("Datei 12 von 158 herunterladen"), je Konto (Dienst)
bzw. einmal (PC, Windows-App).

Nur Anzeige: nichts davon geht in die Datenbank, und ein Fehler hier bricht nie einen Abgleich ab. `/api/bg` zeigt den
Text, solange der Hintergrundlauf laeuft (`server._bg`); `server._run_bg` leert ihn am Anfang und am Ende.
"""
from __future__ import annotations

import threading

from . import config

_lock = threading.Lock()
_state: dict[str, str] = {}


def _key() -> str:
    try:
        return config.current_user_id() or ""
    except Exception:  # noqa: BLE001 - ohne Nutzerkontext gilt der eine Zustand des PCs
        return ""


def report(text: str) -> None:
    """Neuen Zwischenstand setzen (z. B. "Kurs 3 von 20: Termine und Dateiliste")."""
    with _lock:
        _state[_key()] = str(text or "")


def current() -> str:
    with _lock:
        return _state.get(_key(), "")


def clear() -> None:
    with _lock:
        _state.pop(_key(), None)
