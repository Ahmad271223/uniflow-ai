"""Backend der Windows-App (Tauri): startet den Server auf einem freien Port auf 127.0.0.1, nur fuer das Fenster.

Ablauf: das Tauri-Fenster startet `uniflow-backend.exe --parent-pid <pid> --state <datei>`; das Backend legt die
Datenordner unter %LOCALAPPDATA%\\UniFlow an (Daten, Protokolle, .env), schreibt `{"port", "pid", "url"}` in die
Zustandsdatei und laeuft, bis das Fenster (Elternprozess) endet. Dieselbe App wie `serve.py`: gleiche Oberflaeche,
gleiche Datenbank, gleicher Abgleich. Playwrights Chromium kommt aus dem Ordner `ms-playwright` neben der exe
(vom Installer mitgeliefert); fehlt er, gilt Playwrights Standardordner (Entwicklung).

Die Umgebungsvariablen muessen gesetzt sein, BEVOR `app.config` importiert wird (es liest sie beim Import).
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import threading
import time
from pathlib import Path


def app_base_dir(override: str | None = None) -> Path:
    """%LOCALAPPDATA%\\UniFlow (Windows) bzw. ~/.uniflow; mit --base ueberschreibbar (Tests)."""
    if override:
        return Path(override)
    local = os.environ.get("LOCALAPPDATA")
    return Path(local) / "UniFlow" if local else Path.home() / ".uniflow"


def exe_dir() -> Path:
    """Ordner der exe (PyInstaller) bzw. der Projektordner (Entwicklung)."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


def browsers_path(base: Path, exe_folder: Path | None = None) -> Path | None:
    """Chromium fuer Playwright: neben der exe mitgeliefert, sonst unter dem Datenordner (von `playwright install`),
    sonst None (Playwright-Standard, z. B. in der Entwicklung)."""
    for p in ((exe_folder or exe_dir()) / "ms-playwright", base / "ms-playwright"):
        if p.is_dir() and any(p.iterdir()):
            return p
    return None


def prepare_environment(base: Path, exe_folder: Path | None = None) -> dict[str, str]:
    """Datenordner anlegen und die Umgebung fuer app.config setzen; liefert die gesetzten Werte."""
    values = {"LERNAPP_DATA_DIR": str(base / "data"), "LERNAPP_LOG_DIR": str(base / "logs"), "LERNAPP_ENV_FILE": str(base / ".env")}
    bp = browsers_path(base, exe_folder)
    if bp:
        values["PLAYWRIGHT_BROWSERS_PATH"] = str(bp)
    for d in (base, base / "data", base / "logs"):
        d.mkdir(parents=True, exist_ok=True)
    for k, v in values.items():
        os.environ[k] = v
    return values


def free_port(host: str = "127.0.0.1") -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind((host, 0))
        return s.getsockname()[1]


def write_state(path: Path, port: int, pid: int | None = None) -> dict:
    state = {"port": port, "pid": pid or os.getpid(), "url": f"http://127.0.0.1:{port}/", "started_at": time.time()}
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".part")
    tmp.write_text(json.dumps(state), encoding="utf-8")
    os.replace(tmp, path)
    return state


def read_state(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def process_alive(pid: int) -> bool:
    if sys.platform == "win32":
        import ctypes
        SYNCHRONIZE, STILL_ACTIVE = 0x00100000, 259
        h = ctypes.windll.kernel32.OpenProcess(SYNCHRONIZE | 0x0400, False, pid)   # 0x0400 = QUERY_INFORMATION
        if not h:
            return False
        try:
            code = ctypes.c_ulong()
            ok = ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
            return bool(ok) and code.value == STILL_ACTIVE
        finally:
            ctypes.windll.kernel32.CloseHandle(h)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def watch_parent(pid: int, on_exit, poll_seconds: float = 1.0) -> threading.Thread:
    """Beendet das Backend (on_exit), sobald der Elternprozess (das Fenster) weg ist. Windows: Warten auf das
    Prozess-Handle; sonst regelmaessige Pruefung."""
    def run():
        if sys.platform == "win32":
            import ctypes
            SYNCHRONIZE, INFINITE = 0x00100000, 0xFFFFFFFF
            h = ctypes.windll.kernel32.OpenProcess(SYNCHRONIZE, False, pid)
            if h:
                ctypes.windll.kernel32.WaitForSingleObject(h, INFINITE)
                ctypes.windll.kernel32.CloseHandle(h)
                on_exit()
                return
        while process_alive(pid):
            time.sleep(poll_seconds)
        on_exit()
    t = threading.Thread(target=run, name="uniflow-parent-watch", daemon=True)
    t.start()
    return t


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="uniflow-backend", description="UniFlow-Backend fuer die Windows-App")
    p.add_argument("--parent-pid", type=int, default=None, help="Fenster-Prozess; endet er, endet das Backend")
    p.add_argument("--state", type=str, default=None, help="Zustandsdatei (Port, PID); Standard <base>/backend.json")
    p.add_argument("--port", type=int, default=0, help="0 = freier Port")
    p.add_argument("--base", type=str, default=None, help="Datenordner (Standard %%LOCALAPPDATA%%\\UniFlow)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    base = app_base_dir(args.base)
    prepare_environment(base)
    port = args.port or free_port()
    state_path = Path(args.state) if args.state else base / "backend.json"
    log_path = base / "logs" / "backend.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    if args.parent_pid:
        watch_parent(args.parent_pid, lambda: os._exit(0))
    import uvicorn
    from app import config                                   # erst jetzt: liest die Umgebung oben
    from app.server import app
    write_state(state_path, port)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} Backend: Port {port}, Daten {config.DATA_DIR}, Hochschule {config.UNIVERSITY}\n")
    try:
        uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
    finally:
        try:
            state_path.unlink()
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
