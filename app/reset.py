"""Hochschul-Konto entfernen (Einzelplatz und Windows-App, 27.10.2026).

Ein Laptop wechselt den Besitzer oder jemand meldet sich mit einem anderen Hochschul-Account an: dann darf von der
vorigen Person nichts bleiben. `wipe()` loescht auf diesem Rechner alles, was zum Konto gehoert, und laesst die App im
Zustand einer frischen Installation (Hochschule und App-Einstellungen in der .env bleiben):

- gemerkte Hochschul-Sitzung (university-session.json) und gespeicherte Zugangsdaten in der .env
- Browser-Profile der Anmeldefenster (Chromium: dort merkt sich der Browser das Passwort)
- Datenbank: alle Tabellen (Kurse, Dateien, Notizen, Karteikarten, Tests, Lernplaene, Stundenplan, Noten, Protokolle)
  werden geloescht und das Schema neu angelegt
- heruntergeladene Dateien, KI-Arbeitsordner, Protokolle (soweit nicht geoeffnet)
- ChatGPT-Verbindung (Token und Profil; Rechnerkennung und Client-ID bleiben)
- Sicherungen der Windows-App (%LOCALAPPDATA%\\UniFlow-Sicherungen) – sonst liesse sich alles zurueckholen
- Windows-App: Cookies und Speicher des WebView2-Profils (WebSSO-, Stud.IP-, OpenAI-Sitzungen der Anmeldefenster)
  ueber den Fenster-Agenten (Auftrag `clear`, apps/windows/src-tauri/src/main.rs)

Im gehosteten Dienst gibt es das nicht: dort loescht man das Konto (account_api), der Datenordner wird stillgelegt.
"""
from __future__ import annotations

import os
import shutil
from pathlib import Path

from . import config, db

ENV_KEYS = ("STUDIP_USER", "STUDIP_PASSWORD", "STUDIP_SAME_AS", "HILDESHEIM_USER", "HILDESHEIM_PASSWORD",
            "HILDESHEIM_SAME_AS", "QIS_USER", "QIS_PASSWORD", "QIS_SAME_AS", "STUDIP_COOKIES", "LEARNWEB_COOKIES")


def backup_dir() -> Path | None:
    """Sicherungen der Windows-App (app/desktop.py legt sie neben den Datenordner); sonst None."""
    if os.environ.get("LERNAPP_DESKTOP") != "1":
        return None
    base = Path(os.environ.get("LERNAPP_DATA_DIR") or "").parent          # <base>/data -> <base>
    from . import desktop
    return desktop.backup_dir(base)


def _remove_tree(path: Path | None) -> bool:
    if not path or not path.exists():
        return False
    shutil.rmtree(path, ignore_errors=True)
    return not path.exists()


def _clear_dir(path: Path, recreate: bool = True) -> int:
    """Inhalt eines Ordners loeschen (geoeffnete Dateien werden uebersprungen); Ordner bleibt/entsteht neu."""
    n = 0
    if path.exists():
        for child in list(path.iterdir()):
            try:
                if child.is_dir() and not child.is_symlink():
                    shutil.rmtree(child)
                else:
                    child.unlink()
                n += 1
            except OSError:
                pass
    if recreate:
        path.mkdir(parents=True, exist_ok=True)
    return n


def wipe_db() -> int:
    """Alle Tabellen, Sichten, Trigger und Indizes der Datenbank loeschen, Datei verdichten, Schema neu anlegen.
    Liefert die Zahl der entfernten Objekte."""
    conn = db.connect()
    try:
        conn.isolation_level = None                                      # DROP/VACUUM ausserhalb einer Transaktion
        conn.execute("PRAGMA foreign_keys=OFF")
        order = {"trigger": 0, "view": 1, "index": 2, "table": 3}
        objs = [(r[0], r[1]) for r in conn.execute("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")]
        for typ, name in sorted(objs, key=lambda o: order.get(o[0], 9)):
            conn.execute(f'DROP {typ.upper()} IF EXISTS "{name}"')
        conn.execute("VACUUM")
        conn.isolation_level = ""
        with conn:
            db._init_db(conn)
        return len(objs)
    finally:
        conn.close()


def wipe(clear_webview: bool = True) -> dict:
    """Alles Persoenliche auf diesem Rechner loeschen (siehe Modulbeschreibung). Nur Einzelplatz."""
    if config.is_hosted():
        raise RuntimeError("Im Dienst wird das Konto geloescht, nicht der Rechner zurueckgesetzt.")
    from . import chatgpt_login, desktop_windows, hildesheim, studip_sync, unilogin
    out: dict = {}
    unilogin.forget()
    config.set_env({k: None for k in ENV_KEYS})
    out["session"] = True
    try:
        chatgpt_login.disconnect()
        out["chatgpt"] = True
    except Exception:  # noqa: BLE001 - z. B. Datei nicht lesbar: der Rest soll trotzdem laufen
        out["chatgpt"] = False
    out["browser_profiles"] = sum(_remove_tree(p) for p in {studip_sync._profile_dir(), hildesheim._profile_dir()})
    out["db_objects"] = wipe_db()
    data = config.data_dir()
    out["files"] = _clear_dir(config.files_dir())
    out["ai_tmp"] = _clear_dir(data / "ai-tmp", recreate=False)
    out["logs"] = _clear_dir(config.log_dir())
    out["backups"] = _remove_tree(backup_dir())
    out["webview"] = False
    if clear_webview and desktop_windows.agent_connected():
        w = desktop_windows.enqueue("clear", "about:blank", "Studora")
        desktop_windows.forget(w.id)                                     # keine Rueckmeldung noetig
        out["webview"] = True
    out["ok"] = True
    return out
