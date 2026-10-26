"""Windows-App: Backend-Starter (app/desktop.py), Content-Security-Policy der Oberflaeche, Startseite des Fensters,
Tauri-Konfiguration, PyInstaller-Beschreibung und Workflow. Laeuft ohne Rust und ohne gepacktes Backend."""
import json
import os
import re
import shutil
import socket
import struct
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


def test_bind_socket_state_file_and_process_alive(tmp_path):
    from app import desktop
    sock = desktop.bind_socket()
    try:
        port = sock.getsockname()[1]
        assert 1024 < port < 65536 and sock.getsockname()[0] == "127.0.0.1"
        socket.create_connection(("127.0.0.1", port), timeout=2).close()     # hoert schon, bevor uvicorn laeuft
        with pytest.raises(OSError):
            desktop.bind_socket(port)                                         # fester Port belegt: kein stilles Ausweichen
        st = desktop.write_state(tmp_path / "s" / "backend.json", port, pid=4711)
    finally:
        sock.close()
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
    """Der 'Elternprozess' wird erst nach dem Ende der Ueberwachung abgeholt: wie das echte Fenster (kein Kind des
    Backends) muss er auch als Zombie (Unix) als beendet erkannt werden."""
    from app import desktop
    fired = []
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(0.6)"])
    try:
        t = desktop.watch_parent(p.pid, lambda: fired.append(time.time()), poll_seconds=0.1)
        t.join(timeout=10)
    finally:
        p.wait()
    assert fired, "Backend-Ende wird ausgeloest, wenn das Fenster weg ist"


@pytest.mark.skipif(sys.platform == "win32", reason="Windows kennt keine Zombie-Prozesse")
def test_process_alive_treats_zombie_as_dead():
    """Ein beendetes, nicht abgeholtes Kind (Zombie): os.kill(pid, 0) allein meldet es als lebendig (so schlug
    test_watch_parent_fires_when_parent_ends in der Linux-CI fehl)."""
    from app import desktop
    p = subprocess.Popen([sys.executable, "-c", "pass"])
    try:
        deadline = time.time() + 10
        while desktop.process_alive(p.pid) and time.time() < deadline:
            time.sleep(0.05)
        os.kill(p.pid, 0)                                 # den Zombie gibt es noch: nicht abgeholt
        assert not desktop.process_alive(p.pid), "Zombie gilt als beendet"
        assert desktop._unix_process_state(p.pid) == "Z"
    finally:
        p.wait()
    assert not desktop.process_alive(p.pid) and desktop._unix_process_state(p.pid) in ("", None)


def test_env_file_override_keeps_project_env_untouched(tmp_path, monkeypatch):
    from app import config
    monkeypatch.setenv("LERNAPP_ENV_FILE", str(tmp_path / "profil" / ".env"))
    assert config.env_file() == tmp_path / "profil" / ".env"
    config.set_env({"STUDIP_USER": "ab12cd"})
    assert "ab12cd" in (tmp_path / "profil" / ".env").read_text(encoding="utf-8")
    assert config._env().get("STUDIP_USER") == "ab12cd"
    monkeypatch.delenv("LERNAPP_ENV_FILE")
    assert config.env_file() == config.ROOT / ".env"


NO_CONSOLE = "import sys; sys.stdout = sys.stderr = None; from app.desktop import main; sys.exit(main(sys.argv[1:]))"


@pytest.mark.parametrize("console", [True, False], ids=["konsole", "ohne-konsole"])
def test_backend_main_serves_the_app_in_a_subprocess(tmp_path, console):
    """Der Starter als eigener Prozess: Zustandsdatei, Antwort der API, CSP der Oberflaeche, Ende mit dem Elternprozess.
    'ohne-konsole' stellt die uniflow-backend.exe nach (PyInstaller console=False: sys.stdout/sys.stderr None)."""
    from app import desktop
    base = tmp_path / "base"
    state = tmp_path / "backend.json"
    parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"])
    env = {**os.environ, "LERNAPP_ALLOWED_HOSTS": "test"}
    for k in ("LERNAPP_DATA_DIR", "LERNAPP_LOG_DIR", "LERNAPP_ENV_FILE", "LERNAPP_MODE"):
        env.pop(k, None)
    launcher = ["-m", "app.desktop"] if console else ["-c", NO_CONSOLE]
    proc = subprocess.Popen([sys.executable, *launcher, "--base", str(base), "--state", str(state), "--parent-pid", str(parent.pid)],
                            cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.time() + 60
        while not state.exists() and time.time() < deadline and proc.poll() is None:
            time.sleep(0.2)
        assert state.exists(), (proc.stderr.read().decode(errors="replace")[-800:] if proc.poll() is not None else "keine Zustandsdatei")
        st = desktop.read_state(state)
        assert st["url"] == f"http://127.0.0.1:{st['port']}/"
        socket.create_connection(("127.0.0.1", st["port"]), timeout=2).close()   # Datei da = Port offen, ohne Warten
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
        assert (base / "data" / "lernapp.db").exists() and "Backend: Port" in (base / "logs" / "backend.log").read_text(encoding="utf-8")
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


def test_backend_main_fails_before_state_when_port_taken(tmp_path, monkeypatch):
    """Fester Port belegt: der Starter bricht beim Binden ab, bevor er die Zustandsdatei schreibt (kein Fenster, das
    zu einem fremden Dienst navigiert), endet mit 1 und schreibt den Fehler ins Protokoll statt in ein Fehlerfenster."""
    from app import desktop
    for k in ("LERNAPP_DATA_DIR", "LERNAPP_LOG_DIR", "LERNAPP_ENV_FILE", "PLAYWRIGHT_BROWSERS_PATH"):
        monkeypatch.setenv(k, os.environ.get(k, ""))      # merkt sich den Stand, stellt ihn nach dem Test wieder her
    blocker = desktop.bind_socket()
    state = tmp_path / "backend.json"
    try:
        rc = desktop.main(["--base", str(tmp_path / "base"), "--state", str(state), "--port", str(blocker.getsockname()[1])])
    finally:
        blocker.close()
    assert rc == 1 and not state.exists() and not state.with_suffix(".json.part").exists()
    protokoll = (tmp_path / "base" / "logs" / "backend.log").read_text(encoding="utf-8")
    assert "Backend-Start fehlgeschlagen" in protokoll and "OSError" in protokoll


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


# ---------------------------------------------------------------- Startseite des Fensters (dist/start.js)

START_HARNESS = """
// Prueft start.js ohne Browser: document, location, MutationObserver und fetch sind Attrappen; je Fall eine Antwort
// des Entwicklungsservers (status null = Netzfehler). Ausgabe: je Fall, wohin die Seite gewechselt hat.
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const cases = JSON.parse(process.argv[3]);
(async function () {
  const out = [];
  for (const c of cases) {
    const replaced = [];
    let observer = null;
    const els = { msg: { textContent: "" }, help: { hidden: true }, retry: { hidden: true, addEventListener: function () {} } };
    const document = { getElementById: function (id) { return els[id]; } };
    const location = { replace: function (u) { replaced.push(u); } };
    function MutationObserver(cb) { observer = cb; }
    MutationObserver.prototype.observe = function () {};
    const fetch = function () {
      if (c.status === null) { return Promise.reject(new TypeError("Failed to fetch")); }
      return Promise.resolve({ status: c.status, ok: c.status === 200,
                               json: function () { return Promise.resolve().then(function () { return JSON.parse(c.body); }); } });
    };
    new Function("document", "location", "MutationObserver", "fetch", src)(document, location, MutationObserver, fetch);
    els.msg.textContent = "Entwicklungsmodus: verbinde mit http://127.0.0.1:8765";
    observer();
    await new Promise(function (r) { setTimeout(r, 20); });
    out.push({ replaced: replaced, msg: els.msg.textContent, retry: !els.retry.hidden });
  }
  process.stdout.write(JSON.stringify(out));
})();
"""


def test_start_page_redirects_only_on_uniflow_answer(tmp_path):
    """Entwicklungsmodus: start.js wechselt nur bei Status 200 und JSON mit "mode" von /api/account/info zum Server,
    nicht bei irgendeiner HTTP-Antwort (ein fremder Dienst auf Port 8765, Fehlerseite, falsches JSON)."""
    node = shutil.which("node")
    if not node:
        pytest.skip("node fehlt")
    harness = tmp_path / "harness.js"
    harness.write_text(START_HARNESS, encoding="utf-8")
    cases = [{"status": 200, "body": '{"mode": "local"}'}, {"status": 200, "body": "<html>fremd</html>"},
             {"status": 200, "body": '{"ok": true}'}, {"status": 500, "body": '{"mode": "local"}'},
             {"status": 404, "body": ""}, {"status": None, "body": ""}]
    out = subprocess.run([node, str(harness), str(WIN / "dist" / "start.js"), json.dumps(cases)],
                         capture_output=True, encoding="utf-8", timeout=60, check=True)
    results = json.loads(out.stdout)
    assert results[0] == {"replaced": ["http://127.0.0.1:8765/"], "msg": "Verbinde mit dem UniFlow-Server auf diesem PC …", "retry": False}
    for r in results[1:]:
        assert r["replaced"] == [] and r["retry"] and r["msg"].startswith("Keine Verbindung zu http://127.0.0.1:8765/"), r


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


def test_tauri_window_checks_backend_pid_url_and_exit():
    """main.rs: die Zustandsdatei zaehlt nur mit der PID des gestarteten Kindes, die URL nur als
    http://127.0.0.1:<port>/, und ein vorzeitig beendetes Backend (try_wait) bricht das Warten sofort ab."""
    rs = (WIN / "src-tauri" / "src" / "main.rs").read_text(encoding="utf-8")
    assert "fn check_state(text: &str, child_pid: u32)" in rs and 'v.get("pid")' in rs and "child.id()" in rs
    assert 'strip_prefix("http://127.0.0.1:")' in rs and "fn local_port" in rs
    assert "try_wait()" in rs and "fn exited" in rs
    assert "started_at" not in rs, "Zeitstempel statt PID reicht nicht (alte Datei, fremder Prozess)"
    assert "win.navigate(parsed)" in rs and rs.index("fn check_state") < rs.index("win.navigate(parsed)")


def test_windows_app_versions_match():
    """package.json, package-lock.json, tauri.conf.json und Cargo.toml nennen dieselbe Version (der Installer
    heisst UniFlow_<version>_x64-setup.exe)."""
    pkg = json.loads((WIN / "package.json").read_text(encoding="utf-8"))
    lock = json.loads((WIN / "package-lock.json").read_text(encoding="utf-8"))
    conf = json.loads((WIN / "src-tauri" / "tauri.conf.json").read_text(encoding="utf-8"))
    cargo = re.search(r'^version = "([^"]+)"', (WIN / "src-tauri" / "Cargo.toml").read_text(encoding="utf-8"), re.M).group(1)
    assert re.fullmatch(r"\d+\.\d+\.\d+", pkg["version"])
    assert pkg["version"] == conf["version"] == cargo == lock["version"] == lock["packages"][""]["version"]


def test_pyinstaller_spec_and_workflow():
    spec = (WIN / "backend" / "uniflow-backend.spec").read_text(encoding="utf-8")
    assert 'name="uniflow-backend"' in spec and "console=False" in spec and '"app/static"' in spec and '"tzdata"' in spec
    assert "entry.py" in spec and (WIN / "backend" / "entry.py").exists()
    wf = (ROOT / ".github" / "workflows" / "windows.yml").read_text(encoding="utf-8")
    for needle in ("PyInstaller apps/windows/backend/uniflow-backend.spec", "playwright install chromium", "ms-playwright",
                   "tests/test_desktop.py", "npx tauri build", "scripts/check-backend.ps1", "scripts/check-installer.ps1"):
        assert needle in wf, needle
    assert wf.index("PyInstaller") < wf.index("npx tauri build"), "erst Backend packen, dann Installer"
    assert wf.index("npx tauri build") < wf.index("check-installer.ps1") < wf.index("upload-artifact"), "Installer testen, dann hochladen"
    # Ausloeser: push auf develop bei Aenderungen an App/Backend, dazu von Hand
    assert re.search(r"^on:\n  push:\n    branches: \[develop\]\n    paths:\n", wf, re.M) and "workflow_dispatch:" in wf
    for p in ('"apps/windows/**"', '"app/**"', '"requirements.txt"', '".github/workflows/windows.yml"'):
        assert p in wf, p
    # Chromium: Ordner chromium-* muss da sein, sonst klare Meldung
    assert 'Filter "chromium-*"' in wf and "throw" in wf.split("Chromium ins Paket")[1].split("- name:")[0]
    # Icons nur aus apps/windows, nicht aus apps/apple
    assert "apple" not in wf and "tauri icon app-icon.png" in wf
    head = (WIN / "app-icon.png").read_bytes()[:24]
    w, h = struct.unpack(">II", head[16:24])
    assert head[:8] == b"\x89PNG\r\n\x1a\n" and w == h >= 512, "tauri icon braucht ein quadratisches PNG"
    # Start-Test des Pakets und des installierten Pakets
    backend = (WIN / "scripts" / "check-backend.ps1").read_text(encoding="utf-8")
    for needle in ("--state", "--base", "api/account/info", "Content-Security-Policy", "$st.pid -ne $p.Id", "TcpClient"):
        assert needle in backend, needle
    inst = (WIN / "scripts" / "check-installer.ps1").read_text(encoding="utf-8")
    for needle in ('"/S"', "uninstall.exe", "backend\\uniflow-backend.exe", "check-backend.ps1", "chromium-*", "Remove-Item"):
        assert needle in inst, needle
    assert inst.index('"/S"') < inst.index('$PSScriptRoot "check-backend.ps1"') < inst.index('"uninstall.exe") -ArgumentList')
