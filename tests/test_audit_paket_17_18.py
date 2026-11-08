"""Externer Audit 08.11.2026, Pakete 17 und 18 sowie die service_link-Befunde aus Paket 19 (app/token_store.py,
app/desktop.py, app/service_link.py; alles PC-Version: Windows-App bzw. Einzelplatz am Mac, die mit dem Dienst
spricht). Bericht: docs/audit/AUDIT-2026-11-08-PAKET-17-18.md. Je zutreffendem Befund erst der fehlschlagende Test,
dann die kleinste Behebung; widerlegte Befunde nageln das richtige Verhalten fest. Kein echter Dienst, keine echten
Konten: Attrappen fuer den Transport und lokale HTTP-Server auf 127.0.0.1."""
import ctypes
import http.server
import json
import logging
import os
import sqlite3
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
POSIX = sys.platform != "win32"
TOKEN = "tok-" + "A" * 40


def _mode(p: Path) -> int:
    return stat.S_IMODE(os.stat(p).st_mode)


# ================================================================ Attrappe des Dienstes fuer service_link

@pytest.fixture
def link(monkeypatch, tmp_path):
    from app import config, service_link
    monkeypatch.setattr(config, "MODE", "local")
    p = tmp_path / "service-account.json"
    monkeypatch.setattr(service_link, "state_path", lambda: p)
    monkeypatch.delenv("LERNAPP_SERVICE_URL", raising=False)
    calls, replies = [], []

    def transport(method, url, headers, body, timeout):
        calls.append({"method": method, "url": url, "headers": dict(headers), "body": body})
        r = replies.pop(0) if replies else (200, b"{}")
        if isinstance(r, BaseException):
            raise r
        return r[0], {"content-type": "application/json"}, r[1]
    monkeypatch.setattr(service_link, "transport", transport)
    return SimpleNamespace(sl=service_link, calls=calls, replies=replies, path=p)


def _linked(link, **extra):
    link.sl.save_state({"url": "https://app.studinow.app", "token": TOKEN, "user": {"email": "x@example.org"}, **extra})


# ================================================================ Paket 17: token_store

def test_p17_01_env_is_copied_when_its_rename_fails(tmp_path, monkeypatch):
    from app import desktop
    legacy, base = tmp_path / "UniFlow", tmp_path / "de.uniflow.desktop"
    (legacy / "data").mkdir(parents=True)
    (legacy / "data" / "lernapp.db").write_bytes(b"db")
    (legacy / ".env").write_text("STUDIP_USER=x\n", encoding="utf-8")
    real = Path.rename

    def rename(self, target):
        if self.name == ".env":
            raise PermissionError(32, "Datei wird verwendet")
        return real(self, target)
    monkeypatch.setattr(Path, "rename", rename)
    assert desktop.migrate_legacy(base, legacy) == base
    assert (base / "data" / "lernapp.db").is_file()
    assert (base / ".env").read_text(encoding="utf-8") == "STUDIP_USER=x\n", "Zugangseinstellungen gehen mit"


def test_p17_01_env_follows_on_the_next_start(tmp_path):
    """Stand nach einem frueheren Abbruch: Daten schon im neuen Ordner, .env noch im alten."""
    from app import desktop
    legacy, base = tmp_path / "UniFlow", tmp_path / "de.uniflow.desktop"
    (base / "data").mkdir(parents=True)
    (base / "data" / "lernapp.db").write_bytes(b"db")
    legacy.mkdir()
    (legacy / ".env").write_text("A=1\n", encoding="utf-8")
    assert desktop.migrate_legacy(base, legacy) == base
    assert (base / ".env").read_text(encoding="utf-8") == "A=1\n"
    # vorhandene neue .env wird nie ueberschrieben; alte Daten noch nicht umgezogen -> .env bleibt beim alten Ordner
    (legacy / ".env").write_text("B=2\n", encoding="utf-8")
    assert desktop.migrate_legacy(base, legacy) == base and (base / ".env").read_text(encoding="utf-8") == "A=1\n"


def test_p17_01_env_stays_while_old_data_is_not_moved(tmp_path):
    from app import desktop
    legacy, base = tmp_path / "UniFlow", tmp_path / "de.uniflow.desktop"
    (base / "data").mkdir(parents=True)
    (legacy / "data").mkdir(parents=True)
    (legacy / "data" / "x.db").write_bytes(b"alt")
    (legacy / ".env").write_text("A=1\n", encoding="utf-8")
    desktop.migrate_legacy(base, legacy)
    assert not (base / ".env").exists() and (legacy / ".env").is_file(), "zwei Datenbestaende: nichts vermischen"


def test_p17_02_filestore_uses_a_unique_temp_file(tmp_path):
    from app import token_store
    f = token_store.FileStore(tmp_path / "service-token")
    (tmp_path / "service-token.tmp").mkdir()              # fester Name belegt (Rest eines anderen Schreibers)
    f.set("abc")
    assert f.get() == "abc"


def test_p17_02_parallel_writers_never_fail(tmp_path):
    from app import token_store
    f = token_store.FileStore(tmp_path / "service-token")
    errors, values = [], [f"tok-{i}" for i in range(8)]

    def w(v):
        try:
            for _ in range(40):
                f.set(v)
        except Exception as e:                            # noqa: BLE001
            errors.append(e)
    ts = [threading.Thread(target=w, args=(v,)) for v in values]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert not errors and f.get() in values
    assert sorted(p.name for p in tmp_path.iterdir()) == ["service-token"], "keine liegengebliebenen Temp-Dateien"


@pytest.mark.skipif(not POSIX, reason="POSIX-Rechte")
def test_p17_03_existing_loose_temp_file_does_not_leak_its_mode(tmp_path):
    from app import token_store
    tmp = tmp_path / "service-token.tmp"
    tmp.write_text("alt", encoding="utf-8")
    os.chmod(tmp, 0o644)
    old = os.umask(0)
    try:
        token_store.FileStore(tmp_path / "service-token").set("abc")
    finally:
        os.umask(old)
    assert _mode(tmp_path / "service-token") == 0o600


@pytest.mark.parametrize("bad", ["a" * 2049, "ab\ncd", "a b", "", "ä" * 10, 123],
                         ids=["2049", "newline", "space", "empty", "non-ascii", "int"])
def test_p17_04_put_rejects_invalid_tokens_and_keeps_the_old_one(bad):
    from app import token_store
    token_store.put(TOKEN)
    if bad == "":
        token_store.put(bad)                              # leer = abmelden (bisheriger Vertrag)
        assert token_store.get() is None
        return
    with pytest.raises(token_store.TokenInvalid):
        token_store.put(bad)
    assert token_store.get() == TOKEN


def test_p17_04_boundary_2048_is_stored_and_read_back():
    from app import token_store
    token_store.put("a" * 2048)
    assert token_store.get() == "a" * 2048


def test_p17_05_windows_store_checks_the_blob_size_before_credwrite():
    from app import token_store
    s = object.__new__(token_store.WindowsCredentialStore)
    s._ct = ctypes

    def never(*a):
        raise AssertionError("CredWriteW darf nicht gerufen werden")
    s._write = never
    with pytest.raises(token_store.StoreError):
        s.set("ä" * 1300)                                 # 2600 Byte > CRED_MAX_CREDENTIAL_BLOB_SIZE (2560)


def test_p17_06_memory_fallback_is_visible_and_logged(monkeypatch, caplog, link):
    from app import token_store

    def boom(*a, **k):
        raise OSError("advapi32 fehlt")
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setattr(token_store, "WindowsCredentialStore", boom)
    with caplog.at_level(logging.WARNING, logger="uniflow.token_store"):
        token_store.use(None)
        assert token_store.kind() == "memory" and token_store.persistent() is False
    assert "nur im Speicher" in caplog.text
    monkeypatch.setattr(sys, "platform", "darwin")
    info = link.sl.status_info(refresh=False)
    assert info["token_store"] == "memory" and info["token_persistent"] is False


def test_p17_06_put_fallback_marks_the_store_as_not_persistent(caplog):
    from app import token_store

    class Broken:
        kind = "windows_credential_manager"
        def get(self): raise token_store.StoreError("gesperrt")
        def set(self, t): raise token_store.StoreError("gesperrt")
        def delete(self): raise token_store.StoreError("gesperrt")
    token_store.use(Broken())
    with caplog.at_level(logging.WARNING, logger="uniflow.token_store"):
        assert token_store.put(TOKEN) is False
    assert token_store.persistent() is False and TOKEN not in caplog.text and "gesperrt" in caplog.text
    token_store.use(token_store.MemoryStore())
    assert token_store.put(TOKEN) is True and token_store.persistent() is True


def test_p17_07_unreadable_token_file_is_not_a_silent_logout(tmp_path, caplog):
    from app import token_store
    f = token_store.FileStore(tmp_path / "service-token")
    assert f.get() is None                                # fehlt = nicht angemeldet, ohne Meldung
    (tmp_path / "service-token").mkdir()                  # nicht lesbar
    with pytest.raises(token_store.StoreError):
        f.get()
    token_store.use(f)
    with caplog.at_level(logging.WARNING, logger="uniflow.token_store"):
        assert token_store.get() is None
    assert "nicht lesbar" in caplog.text


def test_p17_08_parallel_first_start_moves_data_exactly_once(tmp_path):
    """Widerlegt als Datenrisiko: rename ist atomar, wer verliert, findet base/data und arbeitet dort."""
    legacy, base = tmp_path / "UniFlow", tmp_path / "de.uniflow.desktop"
    (legacy / "data").mkdir(parents=True)
    (legacy / "data" / "lernapp.db").write_bytes(b"inhalt")
    (legacy / ".env").write_text("A=1\n", encoding="utf-8")
    go = time.time() + 1.5
    code = ("import sys,time; sys.path.insert(0, sys.argv[1]); from pathlib import Path; from app import desktop;"
            "time.sleep(max(0, float(sys.argv[4]) - time.time()));"
            "print(desktop.migrate_legacy(Path(sys.argv[2]), Path(sys.argv[3])))")
    ps = [subprocess.Popen([sys.executable, "-c", code, str(ROOT), str(base), str(legacy), str(go)],
                           stdout=subprocess.PIPE, text=True) for _ in range(6)]
    outs = [p.communicate(timeout=60)[0].strip() for p in ps]
    assert outs == [str(base)] * 6
    assert (base / "data" / "lernapp.db").read_bytes() == b"inhalt" and not (legacy / "data").exists()
    assert (base / ".env").read_text(encoding="utf-8") == "A=1\n"


# ================================================================ Paket 17: desktop

def test_p17_09_write_state_uses_a_unique_temp_file(tmp_path):
    from app import desktop
    p = tmp_path / "backend.json"
    (tmp_path / "backend.json.part").mkdir()
    st = desktop.write_state(p, 4321, pid=777)
    assert desktop.read_state(p) == st


def test_p17_09_cleanup_removes_only_its_own_state(tmp_path):
    from app import desktop
    p = tmp_path / "backend.json"
    desktop.write_state(p, 4321, pid=999999)              # ein anderes Backend hat die Datei inzwischen geschrieben
    desktop.remove_state(p, pid=777)
    assert p.exists()
    desktop.remove_state(p, pid=999999)
    assert not p.exists()


@pytest.mark.parametrize("doc", [[], "x", {"port": "1", "pid": 1, "url": "http://127.0.0.1:1/"},
                                 {"port": 0, "pid": 1, "url": "http://127.0.0.1:0/"},
                                 {"port": 70000, "pid": 1, "url": "http://127.0.0.1:70000/"},
                                 {"port": 80, "pid": -1, "url": "http://127.0.0.1:80/"},
                                 {"port": 80, "pid": True, "url": "http://127.0.0.1:80/"},
                                 {"port": 80, "pid": 1, "url": "http://evil.example:80/"},
                                 {"port": 80, "pid": 1, "url": "http://127.0.0.1:81/"}])
def test_p17_10_read_state_rejects_invalid_documents(tmp_path, doc):
    from app import desktop
    p = tmp_path / "backend.json"
    p.write_text(json.dumps(doc), encoding="utf-8")
    assert desktop.read_state(p) is None


def test_p17_10_read_state_accepts_its_own_document(tmp_path):
    from app import desktop
    st = desktop.write_state(tmp_path / "b.json", 8123)
    assert desktop.read_state(tmp_path / "b.json") == st


def test_p17_11_browsers_path_needs_a_chromium_folder(tmp_path):
    from app import desktop
    exe, base = tmp_path / "exe", tmp_path / "base"
    (exe / "ms-playwright").mkdir(parents=True)
    (exe / "ms-playwright" / "README.txt").write_text("x", encoding="utf-8")
    assert desktop.browsers_path(base, exe) is None, "beliebiger Inhalt ist keine Browser-Installation"
    (exe / "ms-playwright" / "chromium-1140").mkdir()
    assert desktop.browsers_path(base, exe) == exe / "ms-playwright"


def test_p17_12_permanent_permission_error_is_not_retried_outside_windows(tmp_path, monkeypatch):
    from app import desktop
    target = tmp_path / "gesperrt"
    calls, sleeps = [], []

    def deny(self, *a, **k):
        calls.append(1)
        raise PermissionError(13, "Zugriff verweigert")
    monkeypatch.setattr(type(target), "mkdir", deny)
    monkeypatch.setattr(desktop.time, "sleep", lambda s: sleeps.append(s))
    monkeypatch.setattr(sys, "platform", "darwin")
    with pytest.raises(PermissionError):
        desktop.ensure_dir(target)
    assert len(calls) == 1 and not sleeps
    calls.clear()
    monkeypatch.setattr(sys, "platform", "win32")          # unter Windows oft nur kurz (Virenscanner): wiederholen
    with pytest.raises(PermissionError):
        desktop.ensure_dir(target, attempts=4)
    assert len(calls) == 4


# ================================================================ Paket 18: Sicherungen

def _db(p: Path, rows=1):
    p.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(p)
    c.execute("CREATE TABLE IF NOT EXISTS t(x)")
    c.executemany("INSERT INTO t VALUES (?)", [(i,) for i in range(rows)])
    c.commit()
    c.close()


@pytest.mark.skipif(not POSIX, reason="POSIX-Rechte; unter Windows gilt die ACL von %LOCALAPPDATA%")
def test_p18_01_backups_are_private_and_restorable(tmp_path):
    from app import desktop
    base = tmp_path / "de.uniflow.desktop"
    _db(base / "data" / "lernapp.db", rows=3)
    old = os.umask(0o022)
    try:
        out = desktop.backup_databases(base, now=1_800_000_000)
    finally:
        os.umask(old)
    assert len(out) == 1 and _mode(out[0]) == 0o600 and _mode(out[0].parent) == 0o700
    c = sqlite3.connect(out[0])
    assert c.execute("SELECT COUNT(*) FROM t").fetchone()[0] == 3, "Sicherung ist wiederherstellbar"
    c.close()


def test_p18_04_backup_errors_are_reported(tmp_path):
    from app import desktop
    base = tmp_path / "de.uniflow.desktop"
    (base / "data").mkdir(parents=True)
    (base / "data" / "lernapp.db").write_bytes(b"kein sqlite" * 100)
    msgs = []
    assert desktop.backup_databases(base, now=1_800_000_000, on_error=msgs.append) == []
    assert len(msgs) == 1 and "lernapp" in msgs[0] and "fehlgeschlagen" in msgs[0]
    assert not list(desktop.backup_dir(base).glob("*.part")), "keine halbe Sicherung bleibt liegen"


def test_p18_04_run_writes_backup_errors_to_the_log(tmp_path, monkeypatch):
    from app import desktop
    base = tmp_path / "de.uniflow.desktop"
    (base / "data").mkdir(parents=True)
    (base / "data" / "lernapp.db").write_bytes(b"kein sqlite" * 100)
    monkeypatch.setattr(desktop, "serve", lambda *a: None)
    for k in ("LERNAPP_DATA_DIR", "LERNAPP_LOG_DIR", "LERNAPP_ENV_FILE", "LERNAPP_DESKTOP", "PLAYWRIGHT_BROWSERS_PATH"):
        monkeypatch.setenv(k, os.environ.get(k, ""))
    assert desktop._run(desktop.parse_args(["--base", str(base)]), base) == 0
    assert "Sicherung fehlgeschlagen" in (base / "logs" / "backend.log").read_text(encoding="utf-8")


def test_p18_05_backup_uses_a_unique_temp_file(tmp_path):
    from app import desktop
    base = tmp_path / "de.uniflow.desktop"
    _db(base / "data" / "lernapp.db")
    now = 1_800_000_000
    dest = desktop.backup_dir(base)
    dest.mkdir(parents=True)
    (dest / f"lernapp-{time.strftime('%Y%m%d-%H%M%S', time.localtime(now))}.part").mkdir()
    assert len(desktop.backup_databases(base, now=now)) == 1


@pytest.mark.parametrize("keep", [0, -2, 1])
def test_p18_06_keep_below_one_keeps_exactly_the_newest(tmp_path, keep):
    from app import desktop
    base = tmp_path / "de.uniflow.desktop"
    _db(base / "data" / "lernapp.db")
    for i in range(4):
        desktop.backup_databases(base, now=1_800_000_000 + i * 86400, keep=keep)
    left = desktop._backups_of(desktop.backup_dir(base), "lernapp")
    assert len(left) == 1 and left[0][0] == time.mktime(time.localtime(1_800_000_000 + 3 * 86400))


@pytest.mark.skipif(not POSIX, reason="Windows wartet auf das Prozess-Handle")
def test_p18_07_watch_parent_notices_reparenting_despite_pid_reuse(monkeypatch):
    from app import desktop
    monkeypatch.setattr(desktop, "process_alive", lambda pid: True)    # PID schon an einen anderen Prozess vergeben
    seq = iter([4242, 4242, 4242])
    monkeypatch.setattr(desktop.os, "getppid", lambda: next(seq, 1))   # danach: von launchd/init uebernommen
    done = threading.Event()
    desktop.watch_parent(4242, done.set, poll_seconds=0.01)
    assert done.wait(5), "Ende des Fensters erkannt, obwohl die PID wieder lebt"


@pytest.mark.skipif(not POSIX, reason="POSIX-Rechte")
def test_p18_12_emergency_log_fallback_is_private(tmp_path, monkeypatch):
    from app import desktop
    monkeypatch.setenv("TEMP", str(tmp_path))
    old = os.umask(0o022)
    try:
        desktop.emergency_log(None, "Traceback mit /Users/x/Pfad")
    finally:
        os.umask(old)
    p = tmp_path / desktop.FALLBACK_LOG
    assert "Pfad" in p.read_text(encoding="utf-8") and _mode(p) == 0o600


@pytest.mark.skipif(not POSIX, reason="Symlinks")
def test_p18_12_emergency_log_does_not_follow_a_planted_symlink(tmp_path, monkeypatch):
    from app import desktop
    monkeypatch.setenv("TEMP", str(tmp_path / "tmp"))
    (tmp_path / "tmp").mkdir()
    victim = tmp_path / "opfer.txt"
    victim.write_text("", encoding="utf-8")
    (tmp_path / "tmp" / desktop.FALLBACK_LOG).symlink_to(victim)
    desktop.emergency_log(None, "geheim")
    assert victim.read_text(encoding="utf-8") == ""


# ================================================================ Paket 18: service_link

class _Redirector(http.server.BaseHTTPRequestHandler):
    target = ""
    seen: list = []

    def do_GET(self):
        self.seen.append(("A", self.headers.get("Authorization")))
        self.send_response(302)
        self.send_header("Location", self.target)
        self.end_headers()

    def log_message(self, *a):
        pass


class _Foreign(http.server.BaseHTTPRequestHandler):
    seen: list = []

    def do_GET(self):
        self.seen.append(("B", self.headers.get("Authorization")))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *a):
        pass


def test_p18_02_bearer_token_never_follows_a_redirect(monkeypatch):
    from app import service_link
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("NO_PROXY", "*")
    _Redirector.seen, _Foreign.seen = [], []
    b = http.server.HTTPServer(("127.0.0.1", 0), _Foreign)
    _Redirector.target = f"http://localhost:{b.server_address[1]}/stehlen"
    a = http.server.HTTPServer(("127.0.0.1", 0), _Redirector)
    for s in (a, b):
        threading.Thread(target=s.serve_forever, daemon=True).start()
    try:
        status, _, _ = service_link._urllib_transport("GET", f"http://127.0.0.1:{a.server_address[1]}/api/account/me",
                                                      {"Authorization": "Bearer " + TOKEN}, None, 5)
    finally:
        a.shutdown(); b.shutdown()
    assert _Redirector.seen == [("A", "Bearer " + TOKEN)]
    assert _Foreign.seen == [], "fremder Host bekommt weder Anfrage noch Token"
    assert status == 302


@pytest.mark.parametrize("bad", ["http://evil.example", "ftp://x", "https://u:p@x.example", "javascript:alert(1)"])
def test_p18_03_stored_service_url_is_validated_again(link, bad):
    link.path.write_text(json.dumps({"url": bad, "user": {"email": "x@example.org"}}), encoding="utf-8")
    from app import token_store
    token_store.put(TOKEN)
    assert link.sl.service_url() == ""
    with pytest.raises(link.sl.LinkError):
        link.sl.call("GET", "/api/account/me")
    assert link.calls == [], "kein Bearer-Token an eine ungueltige Adresse"


def test_p18_03_invalid_env_url_is_not_used(link, monkeypatch):
    monkeypatch.setenv("LERNAPP_SERVICE_URL", "http://evil.example")
    assert link.sl.service_url({}) == ""
    monkeypatch.setenv("LERNAPP_SERVICE_URL", "https://dienst.example/")
    assert link.sl.service_url({}) == "https://dienst.example"


def test_p18_08_state_file_uses_a_unique_temp_file(link):
    (link.path.parent / (link.path.name + ".tmp")).mkdir()
    _linked(link)
    assert link.sl.load_state()["token"] == TOKEN


def test_p18_08_parallel_save_and_load_stay_consistent(link):
    _linked(link)
    errors = []

    def w(i):
        try:
            for j in range(30):
                st = link.sl.load_state()
                st["n"] = i * 100 + j
                link.sl.save_state(st)
        except Exception as e:                            # noqa: BLE001
            errors.append(e)
    ts = [threading.Thread(target=w, args=(i,)) for i in range(6)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert not errors
    d = json.loads(link.path.read_text(encoding="utf-8"))
    assert "token" not in d and link.sl.load_state()["token"] == TOKEN
    assert sorted(p.name for p in link.path.parent.iterdir()) == [link.path.name]


def test_p18_09_legacy_token_stays_in_the_file_while_the_store_is_broken(link):
    from app import token_store

    class Broken:
        kind = "windows_credential_manager"
        def get(self): raise token_store.StoreError("gesperrt")
        def set(self, t): raise token_store.StoreError("gesperrt")
        def delete(self): raise token_store.StoreError("gesperrt")
    link.path.write_text(json.dumps({"url": "https://app.studinow.app", "token": TOKEN}), encoding="utf-8")
    token_store.use(Broken())
    assert link.sl.load_state()["token"] == TOKEN
    assert json.loads(link.path.read_text(encoding="utf-8")).get("token") == TOKEN, "nicht dauerhaft umgezogen"
    token_store.use(Broken())                             # Neustart, Ablage weiter gesperrt
    assert link.sl.load_state()["token"] == TOKEN
    token_store.use(token_store.MemoryStore())            # Ablage wieder in Ordnung: jetzt zieht es um
    assert link.sl.load_state()["token"] == TOKEN
    assert "token" not in json.loads(link.path.read_text(encoding="utf-8"))


@pytest.mark.parametrize("path,code,logout", [
    ("/api/account/password", "credentials_invalid", False),
    ("/api/community/x", "irgendwas", False),
    ("/api/community/x", None, False),
    ("/api/entitlements", "unauthenticated", True),
    ("/api/community/info", "unauthenticated", True),
])
def test_p18_10_only_an_invalid_session_logs_out(link, path, code, logout):
    _linked(link)
    body = json.dumps({"detail": {"detail": "x", "code": code}} if code else {}).encode()
    link.replies.append((401, body))
    status, _, _ = link.sl.call("GET", path)
    assert status == 401
    st = link.sl.load_state()
    assert ("token" not in st) is logout and bool(st.get("expired_at")) is logout


@pytest.mark.parametrize("tok", [123, "x" * 3000, "ab cd", "ab\r\nX-Evil: 1", ["t"]],
                         ids=["int", "3000", "space", "crlf", "list"])
def test_p18_11_login_rejects_a_malformed_token(link, tok):
    from app import token_store
    link.replies.append((200, json.dumps({"token": tok, "user": {"email": "x@example.org"}}).encode()))
    with pytest.raises(link.sl.LinkError) as e:
        link.sl.login("https://app.studinow.app", "x@example.org", "geheim-geheim-1")
    assert e.value.code == "service_error" and e.value.status == 502
    assert token_store.get() is None and "token" not in link.sl.load_state()


def test_p18_11_save_state_rejects_a_malformed_token(link):
    with pytest.raises(link.sl.LinkError):
        link.sl.save_state({"url": "https://app.studinow.app", "token": "a\nb"})
    from app import token_store
    assert token_store.get() is None


# ================================================================ Paket 19: service_link

@pytest.mark.parametrize("reply,local_only", [(OSError("offline"), True), ((500, b"{}"), True), ((200, b"{}"), False)])
def test_p19_01_offline_logout_is_marked_as_local_only(link, reply, local_only):
    _linked(link)
    link.replies.append(reply)
    out = link.sl.logout()
    assert not out["linked"] and out["logout_local_only"] is local_only
    if local_only:
        assert "Geräte" in out["logout_hint"]
    from app import token_store
    assert token_store.get() is None


@pytest.fixture
def pc_db(monkeypatch, tmp_path):
    from app import db
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "lernapp.db")
    db.init_db()
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title) VALUES ('c1', 'Kurs')")
    return db


def test_p19_02_hashing_happens_outside_the_write_transaction(pc_db, tmp_path, monkeypatch, link):
    from app import testshare
    for i in range(3):
        f = tmp_path / f"b{i}.pdf"
        f.write_bytes(b"%PDF " + bytes([i]) * 10)
        with pc_db.cursor() as conn:
            conn.execute("""INSERT INTO files(id, course_id, name, mime, status, download_url, local_path)
                            VALUES (?, 'c1', ?, 'application/pdf', 'neu', 'https://studip.example/f', ?)""",
                         (f"h{i}", f.name, str(f)))
    blocked = []
    real = testshare.file_sha256

    def hashing(p):
        c = sqlite3.connect(pc_db.DB_PATH, timeout=0)
        try:
            c.execute("BEGIN IMMEDIATE")
            c.execute("ROLLBACK")
        except sqlite3.OperationalError:
            blocked.append(p.name)
        finally:
            c.close()
        return real(p)
    monkeypatch.setattr(testshare, "file_sha256", hashing)
    fps = link.sl.local_fingerprints()
    assert len(fps) == 3 and blocked == [], "andere Schreiber warten nicht auf das Hashen"
    with pc_db.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM files WHERE content_sha256 IS NOT NULL").fetchone()[0] == 3


def test_p19_03_more_than_max_claims_are_sent_in_pages(pc_db, link, monkeypatch):
    n = link.sl.MAX_CLAIMS + 7
    with pc_db.cursor() as conn:
        conn.executemany("""INSERT INTO files(id, course_id, name, mime, status, download_url, content_sha256)
                            VALUES (?, 'c1', ?, 'application/pdf', 'neu', 'https://studip.example/f', ?)""",
                         [(f"m{i}", f"{i}.pdf", f"{i:064x}") for i in range(n)])
    _linked(link)
    from app import config
    monkeypatch.setattr(config, "university", lambda: None)
    link.replies.extend([(200, b'{"total": 5000}'), (200, b'{"total": 5007}')])
    out = link.sl.claim_local_files()
    posts = [json.loads(c["body"]) for c in link.calls if c["url"].endswith("/api/community/claims")]
    assert [len(p["fingerprints"]) for p in posts] == [link.sl.MAX_CLAIMS, 7]
    assert all(not p.get("replace") for p in posts), "ergaenzend, nie ersetzend"
    assert out["sent"] == n and out["total"] == 5007


def test_p19_04_quiet_claim_errors_are_logged_rate_limited(link, caplog, monkeypatch):
    _linked(link)
    from app import config
    monkeypatch.setattr(config, "university", lambda: None)
    monkeypatch.setattr(link.sl, "local_fingerprints", lambda *a, **k: ["f" * 64])
    link.sl._claim_log.clear()
    link.replies.extend([OSError("offline"), OSError("offline")])
    with caplog.at_level(logging.WARNING, logger="uniflow.service_link"):
        link.sl.claim_quietly()
        link.sl.claim_quietly()
    lines = [r for r in caplog.records if r.name == "uniflow.service_link"]
    assert len(lines) == 1 and "service_unreachable" in lines[0].getMessage()
    assert "f" * 64 not in caplog.text


@pytest.mark.parametrize("q", ["a=" + "x" * 5000, "a=\x7f", "a=ä", "a=1 2", "a=1\r\nHost: x"],
                         ids=["5000", "del", "non-ascii", "space", "crlf"])
def test_p19_05_proxy_rejects_oversized_or_malformed_queries(link, q, monkeypatch):
    _linked(link)
    from app import config
    monkeypatch.setattr(config, "university", lambda: None)
    with pytest.raises(link.sl.LinkError) as e:
        link.sl.proxy("GET", "info", q, None, None)
    assert e.value.status == 400 and e.value.code == "query_invalid" and link.calls == []


def test_p19_05_proxy_forwards_a_normal_query_unchanged(link, monkeypatch):
    _linked(link)
    from app import config
    monkeypatch.setattr(config, "university", lambda: None)
    link.sl.proxy("GET", "questions", "course=abc&tag=a&tag=b&q=Gau%C3%9F", None, None)
    assert link.calls[-1]["url"] == "https://app.studinow.app/api/community/questions?course=abc&tag=a&tag=b&q=Gau%C3%9F"
