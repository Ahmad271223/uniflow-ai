"""Externer Audit 08.11.2026, Pakete 15 und 16 (app/unilogin.py, app/desktop_windows.py, app/vault.py,
app/token_store.py). Bericht: docs/audit/AUDIT-2026-11-08-PAKET-15-16.md. Je zutreffendem Befund erst der
fehlschlagende Test, dann die kleinste Behebung; widerlegte Befunde nageln das richtige Verhalten fest. Keine echten
Hochschulen, keine echten Logins: nur Attrappen und ein lokaler HTTP-Server."""
import base64
import http.server
import json
import os
import sqlite3
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest
from test_subscriptions import hosted, user  # noqa: F401 - Fixture

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def pc_session(monkeypatch, tmp_path):
    """PC-Version: Sitzungsdatei in einem eigenen Ordner."""
    from app import config, unilogin
    monkeypatch.setattr(config, "MODE", "local")
    monkeypatch.setattr(unilogin, "session_path", lambda: tmp_path / unilogin.SESSION_FILE)
    return tmp_path / unilogin.SESSION_FILE


@pytest.fixture
def dw_clean():
    from app import desktop_windows
    desktop_windows.reset()
    yield desktop_windows
    desktop_windows.reset()


@pytest.fixture
def fresh_key(monkeypatch, tmp_path):
    """vault.master_key gegen ein frisches Datenverzeichnis, ohne LERNAPP_SECRET_KEY."""
    from app import config, vault
    monkeypatch.delenv("LERNAPP_SECRET_KEY", raising=False)
    monkeypatch.setattr(config, "BASE_DATA_DIR", tmp_path / "base")
    vault.reset_master()
    yield vault
    vault.reset_master()


@pytest.fixture
def hosted_vault(hosted):  # noqa: F811
    from app import vault
    u, _ = user(hosted, f"p16-{time.time_ns()}@test.de")
    yield u["id"]
    vault.delete_all(u["id"])


# ---------------------------------------------------------------- P15-01: Sessiondatei parallel, gemeinsame .tmp

def test_p15_01_parallel_session_updates_keep_every_entry(pc_session):
    from app import unilogin
    names = [f"S{i}_COOKIES" for i in range(100)]
    errors = []
    start = threading.Barrier(len(names))

    def save(n):
        try:
            start.wait()
            unilogin.save_session(n, [{"name": "sid", "value": n, "domain": "x.test"}])
        except Exception as e:  # noqa: BLE001
            errors.append(e)
    ts = [threading.Thread(target=save, args=(n,)) for n in names]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert not errors, errors[:3]
    data = json.loads(pc_session.read_text(encoding="utf-8"))
    assert sorted(data) == sorted(names), f"{len(names) - len(data)} Sitzungen verloren"
    assert not list(pc_session.parent.glob("*.tmp")), "keine liegengebliebenen Temp-Dateien"


@pytest.mark.skipif(os.name == "nt", reason="POSIX-Rechte")
def test_p15_01_session_file_is_0600_from_creation(pc_session, monkeypatch):
    """Die Temp-Datei entsteht schon mit 0600 (kein Fenster mit umask-Rechten, auch wenn chmod ausbleibt)."""
    from app import unilogin
    monkeypatch.setattr(unilogin.os, "chmod", lambda *a, **k: None)
    old = os.umask(0)
    try:
        unilogin.save_session("STUDIP_COOKIES", [{"name": "sid", "value": "v", "domain": "x.test"}])
    finally:
        os.umask(old)
    assert stat.S_IMODE(pc_session.stat().st_mode) == 0o600


# ---------------------------------------------------------------- P15-02: Rechte (Bewertung, POSIX festgenagelt)

@pytest.mark.skipif(os.name == "nt", reason="POSIX-Rechte")
def test_p15_02_session_file_not_readable_for_others(pc_session):
    from app import unilogin
    unilogin.save_session("STUDIP_COOKIES", [{"name": "sid", "value": "v"}])
    assert stat.S_IMODE(pc_session.stat().st_mode) & 0o077 == 0


# ---------------------------------------------------------------- P15-03 / P15-04: Schema und Ablaufwerte

def test_p15_03_saved_cookies_skip_broken_entries(pc_session):
    from app import unilogin
    pc_session.write_text(json.dumps({"STUDIP_COOKIES": {"cookies": [None, 1, "x", {}, {"name": "ok", "value": "1"}]}}))
    assert unilogin.saved_cookies("STUDIP_COOKIES") == [{"name": "ok", "value": "1"}]
    pc_session.write_text(json.dumps({"STUDIP_COOKIES": {"cookies": {"name": "kein-array"}}}))
    assert unilogin.saved_cookies("STUDIP_COOKIES") == []
    pc_session.write_text(json.dumps({"STUDIP_COOKIES": {"cookies": [None, 1, "x", {}]}}))
    assert unilogin.has_session("STUDIP_COOKIES") is False


def test_p15_03_hosted_saved_cookies_skip_broken_entries(monkeypatch):
    from app import config, unilogin
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setattr(config, "secret", lambda n: json.dumps([None, 2, {"name": "a", "value": "b"}]))
    assert unilogin.saved_cookies("STUDIP_COOKIES") == [{"name": "a", "value": "b"}]


@pytest.mark.parametrize("expires, want", [
    ("abc", False), ([1], False), ({"x": 1}, False), (True, False), ("nan", False),
    (None, True), (-1, True), (0, True), (str(int(time.time()) + 3600), True), (1.0, False),
    (time.time() + 3600, True)])
def test_p15_04_has_session_parses_expires_robustly(pc_session, expires, want):
    from app import unilogin
    pc_session.write_text(json.dumps({"STUDIP_COOKIES": {"cookies": [{"name": "sid", "value": "v", "expires": expires}]}}))
    assert unilogin.has_session("STUDIP_COOKIES") is want


# ---------------------------------------------------------------- P15-05: Cookie-Header nur passender Host/Pfad/secure

def test_p15_05_cookie_header_respects_secure_path_and_host_only():
    from app import unilogin
    cookies = [
        {"name": "sec", "value": "1", "domain": "studip.test", "secure": True},
        {"name": "plain", "value": "2", "domain": "studip.test"},
        {"name": "deep", "value": "3", "domain": "studip.test", "path": "/studip"},
        {"name": "other", "value": "4", "domain": "studip.test", "path": "/studipx"},
        {"name": "sub", "value": "5", "domain": ".test"},
        {"name": "hostonly", "value": "6"},
        {"name": "bad", "value": "7", "domain": "studip.test", "expires": "x"},
    ]
    assert unilogin._cookie_header(cookies, "https://studip.test/studip/jsonapi.php") == "sec=1; plain=2; deep=3; sub=5; hostonly=6"
    assert unilogin._cookie_header(cookies, "http://studip.test/studip") == "plain=2; deep=3; sub=5; hostonly=6", "secure nie ueber http"
    assert unilogin._cookie_header(cookies, "https://studip.test/") == "sec=1; plain=2; sub=5; hostonly=6"
    assert unilogin._cookie_header(cookies, "https://evilstudip.test/studip") == "sub=5", "kein Suffix ohne Punkt"
    assert unilogin._cookie_header([{"name": "a", "value": "1", "domain": "studip.test"}], "ftp://studip.test/") == ""
    assert unilogin._cookie_header([{"name": "a", "value": "1", "domain": "studip.test"}], "file:///etc/passwd") == ""


# ---------------------------------------------------------------- P15-06: keine Cookies an fremde Hosts nach Redirect

class _Recorder(http.server.BaseHTTPRequestHandler):
    seen: list = []

    def do_GET(self):  # noqa: N802
        host = (self.headers.get("Host") or "").split(":")[0]
        _Recorder.seen.append((host, self.path, self.headers.get("Cookie")))
        if host == "127.0.0.1" and self.path == "/start":
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{self.server.server_address[1]}/fremd")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if host == "127.0.0.1" and self.path == "/same":
            self.send_response(302)
            self.send_header("Location", "/ziel")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


@pytest.fixture
def recorder(monkeypatch):
    for k in ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("no_proxy", "*")
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Recorder)
    _Recorder.seen = []
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield srv.server_address[1]
    srv.shutdown()
    srv.server_close()


def test_p15_06_redirect_to_foreign_host_gets_no_cookies(recorder):
    from app import unilogin
    cookies = [{"name": "sid", "value": "geheim", "domain": "127.0.0.1"}]
    assert unilogin._get_with_cookies(f"http://127.0.0.1:{recorder}/start", cookies) == "ok"
    assert ("127.0.0.1", "/start", "sid=geheim") in _Recorder.seen
    foreign = [s for s in _Recorder.seen if s[0] == "localhost"]
    assert foreign and all(c is None for _, _, c in foreign), _Recorder.seen


def test_p15_06_redirect_on_the_same_host_keeps_matching_cookies(recorder):
    from app import unilogin
    cookies = [{"name": "sid", "value": "geheim", "domain": "127.0.0.1"},
               {"name": "only_same", "value": "1", "domain": "127.0.0.1", "path": "/same"}]
    assert unilogin._get_with_cookies(f"http://127.0.0.1:{recorder}/same", cookies) == "ok"
    assert ("127.0.0.1", "/same", "sid=geheim; only_same=1") in _Recorder.seen
    assert ("127.0.0.1", "/ziel", "sid=geheim") in _Recorder.seen, "neue Adresse bekommt nur die dort passenden Cookies"


# ---------------------------------------------------------------- P15-07: Erfolgspruefung

def test_p15_07_luh_check_needs_a_real_users_me_answer(monkeypatch):
    from app import unilogin
    cookies = [{"name": "a", "value": "1", "domain": "studip.test"}]
    login_html = '<form><input name="username" id="username"><input name="password"></form>'
    monkeypatch.setattr(unilogin, "_get_with_cookies", lambda *a, **k: login_html)
    assert unilogin.check_cookies("luh", cookies) is False, "Anmeldeformular mit name=\"username\" ist keine Anmeldung"
    monkeypatch.setattr(unilogin, "_get_with_cookies", lambda *a, **k: '{"data": {"attributes": {"username": ""}}}')
    assert unilogin.check_cookies("luh", cookies) is False
    monkeypatch.setattr(unilogin, "_get_with_cookies", lambda *a, **k: '[{"username": "x"}]')
    assert unilogin.check_cookies("luh", cookies) is False
    monkeypatch.setattr(unilogin, "_get_with_cookies", lambda *a, **k: '{"data": {"type": "users", "attributes": {"username": "abc-123"}}}')
    assert unilogin.check_cookies("luh", cookies) is True


def test_p15_07_moodle_login_page_with_sesskey_is_not_logged_in(monkeypatch):
    """Widerlegt fuer Moodle: die Anmeldeseite hat sesskey in M.cfg, aber body class notloggedin -> nicht angemeldet."""
    from app import unilogin
    monkeypatch.setattr("app.hildesheim.learnweb_base", lambda: "https://lw.test")
    monkeypatch.setattr("app.hsh.moodle_base", lambda: "https://moodle.test")
    page = '<body id="page-login-index" class="notloggedin">M.cfg = {"sesskey":"abc"}'
    monkeypatch.setattr(unilogin, "_get_with_cookies", lambda *a, **k: page)
    assert unilogin.check_cookies("hildesheim", [{"name": "a"}]) is False
    assert unilogin.check_cookies("hsh", [{"name": "a"}]) is False


# ---------------------------------------------------------------- P15-08 / P15-09 / P16-03: Fenster begrenzen

def test_p15_08_report_limits_cookie_count_and_size(dw_clean):
    dw = dw_clean
    w = dw.enqueue("login", "https://x.test", "x")
    many = [{"name": f"c{i}", "value": "v"} for i in range(10_000)]
    many.insert(0, {"name": "big", "value": "x" * 1_000_000})
    dw.report(w.id, "open", "https://x.test", many)
    cur = dw.wait_update(w.id, 0, 0)
    assert len(cur.cookies) <= dw.MAX_COOKIES
    assert all(len(str(v)) <= dw.MAX_COOKIE_FIELD for c in cur.cookies for v in c.values() if v is not None)


def test_p15_09_finished_windows_do_not_pile_up(dw_clean):
    dw = dw_clean
    for i in range(10_000):
        w = dw.enqueue("login", f"https://x.test/{i}", "x")
        dw.report(w.id, "open", None, [{"name": "sid", "value": "geheim"}])
        dw.finish(w.id, "ok")
    assert len(dw._windows) <= dw.MAX_WINDOWS
    assert all(not w.cookies for w in dw._windows.values() if w.done), "fertige Fenster behalten keine Cookies"


def test_p15_09_finished_window_drops_cookies_and_ignores_late_reports(dw_clean):
    dw = dw_clean
    w = dw.enqueue("login", "https://x.test", "x")
    dw.report(w.id, "open", None, [{"name": "sid", "value": "geheim"}])
    dw.finish(w.id, "ok")
    assert w.cookies == []
    assert dw.report(w.id, "open", None, [{"name": "sid", "value": "geheim"}]) == {"done": True, "known": True}
    assert w.cookies == []


def test_p15_09_running_windows_are_kept(dw_clean):
    dw = dw_clean
    login = dw.enqueue("login", "https://x.test/login", "x")
    for i in range(3 * dw.MAX_WINDOWS):
        dw.finish(dw.enqueue("open", f"https://x.test/{i}", "x").id)
    assert login.id in dw._windows, "ein laufendes Anmeldefenster wird nie verdraengt"


# ---------------------------------------------------------------- P15-10 / P15-12 / P16-02 / P16-04: nicht im Dienst

def test_p15_12_desktop_routes_do_not_exist_in_the_service(hosted, monkeypatch, dw_clean):  # noqa: F811
    """Im Dienst gibt es die Fenster-Routen nicht (auch angemeldet, auch mit LERNAPP_DESKTOP=1): kein Konto erreicht
    Auftraege oder Cookies eines anderen."""
    _, h = user(hosted, f"p15-12-{time.time_ns()}@test.de")
    monkeypatch.setenv("LERNAPP_DESKTOP", "1")
    assert asgi_call(hosted, "GET", "/api/desktop/commands?wait=0")[0] == 401
    assert asgi_call(hosted, "GET", "/api/desktop/commands?wait=0", headers=h)[0] == 404
    w = dw_clean.enqueue("login", "https://x.test", "x")
    st, _, _ = asgi_call(hosted, "POST", f"/api/desktop/windows/{w.id}/state", headers=h,
                         body=json.dumps({"cookies": [{"name": "a"}]}))
    assert st == 404 and w.cookies == []
    assert json.loads(asgi_call(hosted, "GET", "/api/desktop", headers=h)[2]) == {"desktop": False, "windows_agent": False}
    assert dw_clean.agent_connected() is False


def test_p15_10_foreign_poller_cannot_fake_the_agent(app, monkeypatch, dw_clean):
    """Polling ohne das Geheimnis der App (oder nicht vom eigenen Rechner) zaehlt nicht als verbundener Agent."""
    monkeypatch.setenv("LERNAPP_DESKTOP", "1")
    monkeypatch.setenv("LERNAPP_AGENT_TOKEN", "geheim-0123456789abcdef")
    assert asgi_call(app, "GET", "/api/desktop/commands?wait=0")[0] == 403
    assert asgi_call(app, "GET", "/api/desktop/commands?wait=0", client=("10.0.0.5", 1),
                     headers={"X-UniFlow-Agent": "geheim-0123456789abcdef"})[0] in (401, 403)
    assert dw_clean.agent_connected() is False


# ---------------------------------------------------------------- P15-11 / P16-05: wait_update bei Timeout

def test_p15_11_wait_desktop_does_not_recheck_an_unchanged_state(dw_clean, monkeypatch, pc_session):
    """wait_update liefert bei Timeout den alten Stand; _wait_desktop prueft ihn nur nach einer neuen Meldung."""
    from app import unilogin
    dw = dw_clean
    monkeypatch.setattr(unilogin, "TIMEOUT_S", 0.3)
    real_enqueue = dw.enqueue

    def enqueue(*a, **k):
        w = real_enqueue(*a, **k)
        dw.report(w.id, "open", None, [{"name": "sid", "value": "v"}])
        return w
    monkeypatch.setattr(dw, "enqueue", enqueue)
    calls = []
    with pytest.raises(unilogin.LoginRequired):
        unilogin._wait_desktop("luh", "STUDIP_COOKIES", "https://x.test", check=lambda k, c: calls.append(1) or False)
    assert len(calls) == 1, "derselbe Stand wird nur einmal geprueft"


# ---------------------------------------------------------------- P16-01 / P16-07: secret.key

def test_p16_01_master_key_reads_the_winning_file(fresh_key, monkeypatch):
    """Ein anderer Prozess legt secret.key an, waehrend dieser den eigenen Schluessel erzeugt: es gilt die Datei."""
    vault = fresh_key
    winner = b"W" * 32
    real = vault.secrets.token_bytes

    def token_bytes(n):
        p = vault.key_file()
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.exists():
            p.write_text(base64.b64encode(winner).decode("ascii"), encoding="ascii")
        return real(n)
    monkeypatch.setattr(vault.secrets, "token_bytes", token_bytes)
    assert vault.master_key() == winner
    assert base64.b64decode(vault.key_file().read_text()) == winner


@pytest.mark.skipif(os.name == "nt", reason="POSIX-Rechte")
def test_p16_07_key_file_created_with_0600_even_with_umask_0(fresh_key, monkeypatch):
    vault = fresh_key
    monkeypatch.setattr(vault.os, "chmod", lambda *a, **k: None)
    old = os.umask(0)
    try:
        vault.master_key()
    finally:
        os.umask(old)
    assert stat.S_IMODE(vault.key_file().stat().st_mode) == 0o600
    assert [p.name for p in vault.key_file().parent.iterdir()] == ["secret.key"], "keine Temp-Reste"


def test_p16_01_broken_key_file_is_an_error_not_an_empty_key(fresh_key):
    vault = fresh_key
    vault.key_file().parent.mkdir(parents=True, exist_ok=True)
    vault.key_file().write_text("", encoding="ascii")
    with pytest.raises(RuntimeError):
        vault.master_key()


_RACE = r"""
import base64, sys, time
sys.path.insert(0, sys.argv[1])
from app import vault
go = float(sys.argv[2])
while time.time() < go:
    pass
print(base64.b64encode(vault.master_key()).decode())
"""


def test_p16_01_twelve_processes_on_a_fresh_data_dir_agree(tmp_path):
    """Wie der Start von 12 uvicorn-Prozessen gegen ein frisches Datenverzeichnis ohne LERNAPP_SECRET_KEY."""
    script = tmp_path / "race.py"
    script.write_text(_RACE)
    for round_ in range(3):
        base = tmp_path / f"r{round_}"
        env = {k: v for k, v in os.environ.items() if k != "LERNAPP_SECRET_KEY"}
        env.update(LERNAPP_DATA_DIR=str(base / "data"), LERNAPP_LOG_DIR=str(base / "logs"))
        go = time.time() + 5.0
        procs = [subprocess.Popen([sys.executable, str(script), str(ROOT), str(go)], env=env, cwd=str(tmp_path),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(12)]
        outs = [p.communicate(timeout=120) for p in procs]
        assert all(p.returncode == 0 for p in procs), [e[-500:] for _, e in outs if e][:2]
        keys = {o.strip() for o, _ in outs}
        on_disk = (base / "data" / "secret.key").read_text().strip()
        assert keys == {on_disk}, f"Runde {round_}: {len(keys)} verschiedene Schluessel"
        assert len(base64.b64decode(on_disk)) == 32


# ---------------------------------------------------------------- P16-06 / P16-08 / P16-09: Tresor-Cache, Fehler

def test_p16_06_env_for_cache_follows_changes_from_another_process(hosted_vault):
    from conftest import legacy_vault

    from app import accounts, vault
    uid = hosted_vault
    legacy_vault(uid, {"STUDIP_USER": "a"})
    assert vault.env_for(uid) == {"STUDIP_USER": "a"}
    c = sqlite3.connect(accounts.db_path())             # "anderer Prozess": direkt in der Datenbank
    c.execute("DELETE FROM vault WHERE user_id=?", (uid,))
    c.commit()
    c.close()
    assert vault.env_for(uid) == {}


def test_p16_08_reset_master_also_clears_stamps(hosted_vault):
    from app import vault
    vault.env_for(hosted_vault)
    assert vault._stamps
    vault.reset_master()
    assert vault._stamps == {} and vault._cache == {}


def test_p16_09_undecryptable_entry_is_logged_without_secret(hosted_vault, capsys):
    from app import vault
    uid = hosted_vault
    cm, conn = vault._conn()
    try:
        conn.execute("INSERT OR REPLACE INTO vault(user_id, name, value_enc, updated_at) VALUES (?,?,?,?)",
                     (uid, "STUDIP_PASSWORD", "v1:" + base64.b64encode(b"\x00" * 40).decode(), "2026-11-08T00:00:00Z"))
    finally:
        cm.__exit__(None, None, None)
    vault._cache.pop(uid, None)
    capsys.readouterr()
    assert vault.env_for(uid) == {}
    out = capsys.readouterr().out
    assert "[vault]" in out and "STUDIP_PASSWORD" in out and uid not in out


# ---------------------------------------------------------------- P16-10: FileStore-Pfad

def test_p16_10_filestore_path_matches_the_pc_data_dir():
    """Widerlegt: in der PC-Version gibt es keinen Nutzerkontext, data_dir() ist DATA_DIR; Token und Zustand von
    service_link liegen im selben Ordner."""
    from app import config, service_link, token_store
    assert config.data_dir() == config.DATA_DIR
    assert token_store.FileStore().path().parent == service_link.state_path().parent == config.DATA_DIR
