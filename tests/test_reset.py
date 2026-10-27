"""Hochschul-Konto entfernen (app/reset.py, 27.10.2026): danach darf auf dem Rechner nichts von der vorigen Person
bleiben, und die App ist leer wie nach einer frischen Installation."""
import json

import pytest

from conftest import asgi_call

COOKIE = {"name": "Seminar_Session", "value": "abc", "domain": "studip.uni-hannover.de", "path": "/"}


@pytest.fixture
def filled(app, monkeypatch, tmp_path):
    """Ein Rechner mit Daten: Kurs, Datei, Sitzung, Zugangsdaten, ChatGPT, Browser-Profil, Sicherung."""
    from app import chatgpt_login, config, db, reset, studip_sync, unilogin
    monkeypatch.setattr(config, "MODE", "local")
    monkeypatch.setattr(config, "env_file", lambda: tmp_path / ".env")
    monkeypatch.setattr(chatgpt_login, "auth_path", lambda: config.data_dir() / "chatgpt-auth.json")
    backups = tmp_path / "UniFlow-Sicherungen"
    backups.mkdir()
    (backups / "lernapp-1.db").write_bytes(b"alt")
    monkeypatch.setattr(reset, "backup_dir", lambda: backups)
    profile = studip_sync._profile_dir()
    profile.mkdir(parents=True, exist_ok=True)
    (profile / "Login Data").write_bytes(b"passwort-im-browser")
    unilogin.save_session("STUDIP_COOKIES", [COOKIE])
    config.save_credentials("luh123", "geheim")
    chatgpt_login.save({"host_id": "urn:uuid:1", "client_id": "oaiapp_x", "credentials": {"access_token": "at"},
                        "profile": {"email": "alt@example.org"}})
    with db.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO courses(id, title, kind, active, test_minutes, created_at) VALUES ('k1', 'Mathe I', 'vorlesung', 1, 60, ?)", (db.now_iso(),))
        conn.execute("INSERT INTO files(id, course_id, name, local_path, first_seen) VALUES ('f1', 'k1', 'skript.pdf', 'k1/skript.pdf', ?)", (db.now_iso(),))
        db.set_setting(conn, "auto_tests", 0)
    f = config.files_dir() / "k1" / "skript.pdf"
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_bytes(b"%PDF")
    yield {"backups": backups, "profile": profile, "file": f}
    unilogin.forget()                                                      # falls ein Test vorher abbrach


def test_wipe_removes_everything_personal_and_reseeds_the_database(filled):
    from app import chatgpt_login, config, db, desktop_windows, reset, unilogin
    desktop_windows.reset()
    desktop_windows.next_command(wait=0)                                   # Fenster-Agent "meldet sich"
    out = reset.wipe()
    assert out["ok"] and out["db_objects"] > 10 and out["files"] >= 1 and out["backups"] and out["browser_profiles"] == 1
    assert not unilogin.has_session("STUDIP_COOKIES")
    assert config.credentials() == ("", "")
    assert not chatgpt_login.connected(chatgpt_login.load()) and chatgpt_login.load().get("client_id") == "oaiapp_x"
    assert not filled["profile"].exists() and not filled["backups"].exists() and not filled["file"].exists()
    assert config.files_dir().exists()
    with db.cursor() as conn:
        assert db.rows(conn, "SELECT id FROM courses") == [{"id": "__user__"}]      # nur der Pseudo-Kurs fuer eigene Dokumente
        assert db.rows(conn, "SELECT * FROM files") == []
        s = db.get_settings(conn)
        assert s["university"] == config.university() and s["auto_tests"] != 0
        assert db.row(conn, "SELECT 1 AS ok FROM terms LIMIT 1")                 # ensure_term lief
    # Windows-App: der Fenster-Agent bekommt den Auftrag, Cookies und Speicher des WebView2-Profils zu loeschen
    cmd = desktop_windows.next_command(wait=0)
    assert out["webview"] and cmd["kind"] == "clear"
    desktop_windows.reset()


def test_wipe_without_window_agent_skips_webview(filled):
    from app import desktop_windows, reset
    desktop_windows.reset()
    out = reset.wipe()
    assert out["ok"] and out["webview"] is False and desktop_windows.pending() == 0


def test_api_reset_local_only_and_not_while_syncing(app, filled, monkeypatch):
    from app import config, server
    st, _, b = asgi_call(app, "POST", "/api/university/reset")
    assert st == 200 and json.loads(b)["ok"]
    monkeypatch.setitem(server._bg_state, "running", True)
    monkeypatch.setitem(server._bg_state, "task", "Abgleich")
    st, _, b = asgi_call(app, "POST", "/api/university/reset")
    assert st == 409 and "Abgleich" in json.loads(b)["detail"]
    monkeypatch.setitem(server._bg_state, "running", False)
    monkeypatch.setattr(config, "MODE", "hosted")
    st, _, b = asgi_call(app, "POST", "/api/university/reset")
    assert st in (400, 401)                                            # 401: der Dienst verlangt vorher die Anmeldung
    if st == 400:
        assert json.loads(b)["detail"]["code"] == "use_account"
