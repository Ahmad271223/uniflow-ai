"""Windows-App: Backend-Starter (app/desktop.py), Content-Security-Policy der Oberflaeche, Tauri-Konfiguration,
PyInstaller-Beschreibung und Workflow. Laeuft ohne Rust und ohne gepacktes Backend."""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
WIN = ROOT / "apps" / "windows"


# ---------------------------------------------------------------- Starter

def test_base_dir_and_environment(tmp_path, monkeypatch):
    from app import desktop
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "Local"))
    assert desktop.app_base_dir() == tmp_path / "Local" / "UniFlow"
    monkeypatch.delenv("LOCALAPPDATA")
    assert desktop.app_base_dir().name in (".uniflow", "UniFlow")
    assert desktop.app_base_dir(str(tmp_path / "x")) == tmp_path / "x"
    base = tmp_path / "base"
    exe = tmp_path / "exe"
    exe.mkdir()
    for k in ("LERNAPP_DATA_DIR", "LERNAPP_LOG_DIR", "LERNAPP_ENV_FILE", "PLAYWRIGHT_BROWSERS_PATH"):
        monkeypatch.setenv(k, "")                 # merkt sich den Stand, stellt ihn nach dem Test wieder her
        monkeypatch.delenv(k)
    values = desktop.prepare_environment(base, exe)
    assert values == {"LERNAPP_DATA_DIR": str(base / "data"), "LERNAPP_LOG_DIR": str(base / "logs"), "LERNAPP_ENV_FILE": str(base / ".env")}
    assert (base / "data").is_dir() and (base / "logs").is_dir() and os.environ["LERNAPP_ENV_FILE"] == str(base / ".env")
    assert not os.environ.get("PLAYWRIGHT_BROWSERS_PATH"), "ohne mitgeliefertes Chromium gilt Playwrights Standard"
    (exe / "ms-playwright" / "chromium-1").mkdir(parents=True)
    assert desktop.browsers_path(base, exe) == exe / "ms-playwright"
    (base / "ms-playwright" / "chromium-2").mkdir(parents=True)
    assert desktop.browsers_path(base, exe) == exe / "ms-playwright", "neben der exe hat Vorrang"
    assert desktop.browsers_path(base, tmp_path / "leer") == base / "ms-playwright"


def test_free_port_state_file_and_process_alive(tmp_path):
    from app import desktop
    port = desktop.free_port()
    assert 1024 < port < 65536
    st = desktop.write_state(tmp_path / "s" / "backend.json", port, pid=4711)
    assert st["url"] == f"http://127.0.0.1:{port}/" and desktop.read_state(tmp_path / "s" / "backend.json")["pid"] == 4711
    assert not (tmp_path / "s" / "backend.json.part").exists()
    assert desktop.read_state(tmp_path / "nicht-da.json") is None
    assert desktop.process_alive(os.getpid())
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(0.4)"])
    assert desktop.process_alive(p.pid)
    p.wait()
    time.sleep(0.2)
    assert not desktop.process_alive(p.pid)


def test_watch_parent_fires_when_parent_ends():
    from app import desktop
    fired = []
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(0.6)"])
    t = desktop.watch_parent(p.pid, lambda: fired.append(time.time()), poll_seconds=0.1)
    t.join(timeout=10)
    assert fired, "Backend-Ende wird ausgeloest, wenn das Fenster weg ist"


def test_env_file_override_keeps_project_env_untouched(tmp_path, monkeypatch):
    from app import config
    monkeypatch.setenv("LERNAPP_ENV_FILE", str(tmp_path / "profil" / ".env"))
    assert config.env_file() == tmp_path / "profil" / ".env"
    config.set_env({"STUDIP_USER": "ab12cd"})
    assert "ab12cd" in (tmp_path / "profil" / ".env").read_text(encoding="utf-8")
    assert config._env().get("STUDIP_USER") == "ab12cd"
    monkeypatch.delenv("LERNAPP_ENV_FILE")
    assert config.env_file() == config.ROOT / ".env"


def test_backend_main_serves_the_app_in_a_subprocess(tmp_path):
    """Der Starter als eigener Prozess: Zustandsdatei, Antwort der API, CSP der Oberflaeche, Ende mit dem Elternprozess."""
    from app import desktop
    base = tmp_path / "base"
    state = tmp_path / "backend.json"
    parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"])
    env = {**os.environ, "LERNAPP_ALLOWED_HOSTS": "test"}
    for k in ("LERNAPP_DATA_DIR", "LERNAPP_LOG_DIR", "LERNAPP_ENV_FILE", "LERNAPP_MODE"):
        env.pop(k, None)
    proc = subprocess.Popen([sys.executable, "-m", "app.desktop", "--base", str(base), "--state", str(state), "--parent-pid", str(parent.pid)],
                            cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.time() + 60
        while not state.exists() and time.time() < deadline and proc.poll() is None:
            time.sleep(0.2)
        assert state.exists(), (proc.stderr.read().decode(errors="replace")[-800:] if proc.poll() is not None else "keine Zustandsdatei")
        st = desktop.read_state(state)
        for _ in range(100):
            try:
                with urllib.request.urlopen(st["url"] + "api/account/info", timeout=2) as r:
                    info = json.loads(r.read())
                break
            except Exception:  # noqa: BLE001
                time.sleep(0.2)
        else:
            pytest.fail("Backend antwortet nicht")
        assert info["mode"] == "local" and desktop.process_alive(st["pid"])      # eigener Prozess (der venv-Starter hat eine andere PID)
        with urllib.request.urlopen(st["url"], timeout=5) as r:
            assert "Content-Security-Policy" in r.headers and "script-src 'self'" in r.headers["Content-Security-Policy"]
        assert (base / "data" / "lernapp.db").exists() and (base / "logs" / "backend.log").exists()
        assert not (ROOT / "data" / "uniflow-test-marker").exists()
        parent.kill()
        parent.wait()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            pytest.fail("Backend laeuft nach dem Ende des Elternprozesses weiter")
    finally:
        if parent.poll() is None:
            parent.kill()
        if proc.poll() is None:
            proc.kill()


# ---------------------------------------------------------------- CSP der Oberflaeche

def test_ui_pages_have_strict_csp_and_api_does_not(app):
    st, headers, body = asgi_call(app, "GET", "/")
    h = {k.decode().lower(): v.decode() for k, v in headers}
    assert st == 200 and "unsafe-eval" not in h["content-security-policy"] and "script-src 'self'" in h["content-security-policy"]
    assert "frame-ancestors 'none'" in h["content-security-policy"] and h["x-frame-options"] == "DENY"
    st, headers, _ = asgi_call(app, "GET", "/api/settings")
    assert st == 200 and b"content-security-policy" not in {k.lower() for k, _ in headers}
    st, headers, _ = asgi_call(app, "GET", "/app.js")
    assert st == 200 and b"content-security-policy" not in {k.lower() for k, _ in headers}


def test_index_has_no_inline_scripts():
    html = (ROOT / "app" / "static" / "index.html").read_text(encoding="utf-8")
    inline = [m for m in re.findall(r"<script\b([^>]*)>", html) if "src=" not in m]
    assert inline == [], "Inline-Skripte sind durch die CSP gesperrt (theme.js)"
    assert "theme.js" in html and (ROOT / "app" / "static" / "theme.js").exists()
    assert not re.search(r"\son[a-z]+=", html), "keine Inline-Ereignisbehandlung"


# ---------------------------------------------------------------- Tauri, PyInstaller, Workflow

def test_tauri_config_is_restrictive_and_bundles_backend():
    conf = json.loads((WIN / "src-tauri" / "tauri.conf.json").read_text(encoding="utf-8"))
    csp = conf["app"]["security"]["csp"]
    assert csp and "unsafe-eval" not in csp and "script-src 'self'" in csp and "object-src 'none'" in csp
    assert conf["bundle"]["resources"] == {"../backend/dist/uniflow-backend/": "backend/"}
    assert conf["bundle"]["targets"] == ["nsis"] and conf["app"]["windows"][0]["label"] == "main"
    cap = json.loads((WIN / "src-tauri" / "capabilities" / "default.json").read_text(encoding="utf-8"))
    assert cap["windows"] == ["main"] and cap["permissions"] == ["core:default"]
    rs = (WIN / "src-tauri" / "src" / "main.rs").read_text(encoding="utf-8")
    assert "uniflow-backend.exe" in rs and "--parent-pid" in rs and "CREATE_NO_WINDOW" in rs and "child.kill()" in rs
    assert 'serde_json = "1"' in (WIN / "src-tauri" / "Cargo.toml").read_text(encoding="utf-8")
    start = (WIN / "dist" / "index.html").read_text(encoding="utf-8")
    assert "<script src=\"start.js\">" in start and not re.search(r"<script>|<style>", start)


def test_pyinstaller_spec_and_workflow():
    spec = (WIN / "backend" / "uniflow-backend.spec").read_text(encoding="utf-8")
    assert 'name="uniflow-backend"' in spec and "console=False" in spec and '"app/static"' in spec and '"tzdata"' in spec
    assert "entry.py" in spec and (WIN / "backend" / "entry.py").exists()
    wf = (ROOT / ".github" / "workflows" / "windows.yml").read_text(encoding="utf-8")
    for needle in ("PyInstaller apps/windows/backend/uniflow-backend.spec", "playwright install chromium", "ms-playwright",
                   "tests/test_desktop.py", "npx tauri build", "Content-Security-Policy"):
        assert needle in wf, needle
    assert wf.index("PyInstaller") < wf.index("npx tauri build"), "erst Backend packen, dann Installer"
