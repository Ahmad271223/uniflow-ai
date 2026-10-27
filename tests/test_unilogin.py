"""Hochschul-Anmeldung im Browserfenster (app/unilogin.py): Die App merkt nur die Sitzung, nie das Passwort; der
Abgleich laeuft mit der gemerkten Sitzung ohne Zugangsdaten und verlangt sonst die Anmeldung im Fenster."""
import json
import time

from conftest import asgi_call


class FakePage:
    def __init__(self, ctx):
        self.ctx = ctx
        self.url = ""
        self.closed = False

    def goto(self, url, **kw):
        self.url = url

    def is_closed(self):
        return self.closed

    def wait_for_timeout(self, ms):
        pass


class FakeCtx:
    def __init__(self, cookies=None):
        self.added = []
        self._cookies = cookies or []
        self.pages = []
        self.closed = False

    def new_page(self):
        p = FakePage(self)
        self.pages.append(p)
        return p

    def add_cookies(self, cookies):
        self.added.extend(cookies)

    def cookies(self):
        return self._cookies + [{"name": c["name"], "value": c["value"], "domain": c["domain"], "path": c.get("path", "/"), "expires": c.get("expires", -1)} for c in self.added]

    def close(self):
        self.closed = True


COOKIE = {"name": "Seminar_Session", "value": "s1", "domain": "studip.uni-hannover.de", "path": "/", "expires": -1, "httpOnly": True, "secure": True}


def test_session_store_in_data_dir_and_cookie_header(app):
    from app import config, filestream, unilogin
    assert not config.is_hosted()
    assert unilogin.saved_cookies("STUDIP_COOKIES") == [] and not unilogin.has_session("STUDIP_COOKIES")
    unilogin.save_session("STUDIP_COOKIES", [COOKIE, {"name": "alt", "value": "x", "domain": "studip.uni-hannover.de", "expires": time.time() - 10}, {"value": "ohne-namen"}])
    p = unilogin.session_path()
    assert p.exists() and p.parent == config.data_dir() and p.name == "university-session.json"
    data = json.loads(p.read_text(encoding="utf-8"))
    assert [c["name"] for c in data["STUDIP_COOKIES"]["cookies"]] == ["Seminar_Session", "alt"] and data["STUDIP_COOKIES"]["saved_at"]
    assert unilogin.has_session("STUDIP_COOKIES") and unilogin.saved_at("STUDIP_COOKIES")
    assert filestream.studip_cookie_header("https://studip.uni-hannover.de") == "Seminar_Session=s1", "abgelaufene fallen weg"
    ctx = FakeCtx()
    assert unilogin.restore(ctx, "STUDIP_COOKIES") == 2 and ctx.added[0]["httpOnly"] is True and ctx.added[0]["path"] == "/"
    env = (config.env_file().read_text(encoding="utf-8") if config.env_file().exists() else "")
    assert "Seminar_Session" not in env and "s1" not in env, "Sitzung landet nie in der .env"
    unilogin.forget("STUDIP_COOKIES")
    assert not unilogin.has_session("STUDIP_COOKIES") and not p.exists()


def test_login_window_saves_session_when_logged_in(app, monkeypatch):
    from app import unilogin
    calls = {"n": 0}
    ctx = FakeCtx(cookies=[COOKIE])
    monkeypatch.setattr(unilogin, "_target", lambda u: ("luh", "STUDIP_COOKIES", "https://sso/login", lambda page: calls.__setitem__("n", calls["n"] + 1) or calls["n"] >= 2, None))
    monkeypatch.setattr(unilogin, "POLL_S", 0)
    assert unilogin.run(launch=lambda profile: ctx) == "angemeldet"
    assert ctx.closed and ctx.pages[0].url == "https://sso/login"
    assert unilogin.has_session("STUDIP_COOKIES") and unilogin.status()["state"] == "ok"
    unilogin.forget()


def test_login_window_closed_or_timeout_leaves_no_session(app, monkeypatch):
    import pytest
    from app import unilogin
    monkeypatch.setattr(unilogin, "_target", lambda u: ("luh", "STUDIP_COOKIES", "https://sso/login", lambda page: False, None))
    monkeypatch.setattr(unilogin, "POLL_S", 0)
    ctx = FakeCtx()

    def launch(profile):
        p = ctx.new_page(); p.closed = True
        return ctx
    with pytest.raises(unilogin.LoginRequired):
        unilogin.run(launch=launch)
    assert unilogin.status()["state"] == "closed" and not unilogin.has_session("STUDIP_COOKIES")
    monkeypatch.setattr(unilogin, "TIMEOUT_S", 0)
    with pytest.raises(unilogin.LoginRequired):
        unilogin.run(launch=lambda profile: FakeCtx())
    assert unilogin.status()["state"] == "timeout"


def test_studip_sync_uses_saved_session_without_credentials(app, monkeypatch):
    """Abgleich ohne Passwort in der .env: gemerkte Sitzung wird in den Browser gelegt, Anmeldung erkannt."""
    from app import config, studip_sync, unilogin
    ctx = FakeCtx()

    class PW:
        def __enter__(self):
            class Chromium:
                def launch_persistent_context(self, *a, **kw):
                    return ctx
            class P:
                chromium = Chromium()
            return P()

        def __exit__(self, *a):
            return False
    monkeypatch.setattr(studip_sync, "sync_playwright", lambda: PW())
    monkeypatch.setattr(config, "credentials", lambda: ("", ""))
    monkeypatch.setattr(studip_sync, "_is_logged_in", lambda page: any(c["name"] == "Seminar_Session" for c in ctx.added))
    monkeypatch.setattr(studip_sync, "_login", lambda page: None if studip_sync._is_logged_in(page) else (_ for _ in ()).throw(unilogin.LoginRequired("Anmeldung bei Stud.IP noetig")))
    monkeypatch.setattr(studip_sync, "fetch_courses", lambda page: [])
    # ohne Sitzung: Abgleich verlangt die Anmeldung im Fenster
    r = studip_sync.run_studip_sync()
    assert not r["ok"] and "Anmeldung bei Stud.IP noetig" in r["message"]
    # mit Sitzung: laeuft durch und merkt die Sitzung erneut
    unilogin.save_session("STUDIP_COOKIES", [COOKIE])
    r = studip_sync.run_studip_sync()
    assert r["ok"], r["message"]
    assert ctx.added and ctx.added[0]["name"] == "Seminar_Session"
    assert unilogin.has_session("STUDIP_COOKIES")
    unilogin.forget()


def test_api_login_window_and_session_endpoints(app, monkeypatch):
    from app import unilogin
    monkeypatch.setattr(unilogin, "run", lambda university=None, launch=None: (unilogin.save_session("STUDIP_COOKIES", [COOKIE]), "angemeldet")[1])
    st, _, b = asgi_call(app, "GET", "/api/university/session")
    assert st == 200 and json.loads(b)["session"] is False and json.loads(b)["name"] == "STUDIP_COOKIES"
    st, _, b = asgi_call(app, "POST", "/api/university/login")
    assert st == 200 and json.loads(b)["started"] == "Anmeldung"
    for _ in range(50):
        st, _, b = asgi_call(app, "GET", "/api/university/session")
        if json.loads(b)["session"]:
            break
        time.sleep(0.05)
    assert json.loads(b)["session"] is True and json.loads(b)["saved_at"]
    st, _, _ = asgi_call(app, "DELETE", "/api/university/session")
    assert st == 200 and not unilogin.has_session("STUDIP_COOKIES")


def test_hosted_has_no_login_window_but_device_session_counts_as_credentials(app, monkeypatch):
    from app import accounts, config, vault
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    for suffix in ("", "-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    try:
        st, _, b = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": "u1@beispiel.de", "password": "sehr-geheim-123", "university": "luh"}))
        h = {"Authorization": f"Bearer {json.loads(b)['token']}"}
        uid = json.loads(asgi_call(app, "GET", "/api/account/me", headers=h)[2])["user"]["id"]
        st, _, b = asgi_call(app, "POST", "/api/university/login", headers=h)
        assert st == 400 and json.loads(b)["code"] == "use_app_login"
        assert not vault.has_university_credentials(uid, "luh")
        vault.set_values(uid, {"STUDIP_COOKIES": json.dumps([COOKIE])})
        assert vault.has_university_credentials(uid, "luh"), "Sitzung vom Geraet reicht fuer den Abgleich im Dienst"
        vault.set_values(uid, {"STUDIP_COOKIES": json.dumps([{"name": "x", "value": "y", "domain": "d", "expires": time.time() - 1}])})
        assert not vault.has_university_credentials(uid, "luh")
    finally:
        accounts.db_path().unlink(missing_ok=True)


def test_hosted_device_can_store_its_session_for_the_service_sync(app, monkeypatch):
    """Android/iPad: nach der Anmeldung im Anmeldefenster legt die App die Sitzung (nie das Passwort) im Tresor ab;
    damit laeuft der Abgleich im Dienst ohne Zugangsdaten. Fremde Hosts werden abgelehnt."""
    from app import accounts, config, vault
    # am PC gibt es den Weg nicht (dort: Fenster)
    st, _, b = asgi_call(app, "PUT", "/api/university/session", body=json.dumps({"cookies": [COOKIE]}))
    assert st == 400 and json.loads(b)["code"] == "use_browser_login"
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    for suffix in ("", "-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    try:
        st, _, b = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": "u2@beispiel.de", "password": "sehr-geheim-123", "university": "luh"}))
        h = {"Authorization": f"Bearer {json.loads(b)['token']}"}
        uid = json.loads(asgi_call(app, "GET", "/api/account/me", headers=h)[2])["user"]["id"]
        st, _, b = asgi_call(app, "PUT", "/api/university/session", headers=h, body=json.dumps({"cookies": [COOKIE, {"name": "shib", "value": "t", "domain": ".idm.uni-hannover.de"}]}))
        assert st == 200 and json.loads(b) == {"ok": True, "name": "STUDIP_COOKIES", "cookies": 2}
        assert vault.has_university_credentials(uid, "luh")
        stored = json.loads(vault.env_for(uid)["STUDIP_COOKIES"])
        assert [c["name"] for c in stored] == ["Seminar_Session", "shib"] and stored[1]["expires"] == -1 and stored[1]["path"] == "/"
        assert "STUDIP_PASSWORD" not in vault.env_for(uid) or not vault.env_for(uid)["STUDIP_PASSWORD"]
        st, _, b = asgi_call(app, "PUT", "/api/university/session", headers=h, body=json.dumps({"cookies": [{"name": "x", "value": "y", "domain": "example.org"}]}))
        assert st == 400 and json.loads(b)["code"] == "cookies_foreign_host"
        st, _, b = asgi_call(app, "PUT", "/api/university/session", headers=h, body=json.dumps({"cookies": []}))
        assert st == 400 and json.loads(b)["code"] == "cookies_invalid"
        st, _, b = asgi_call(app, "POST", "/api/sync", headers=h)
        assert st == 200 and json.loads(b)["started"] == "Sync", "Abgleich im Dienst startet mit der Sitzung vom Geraet"
        st, _, _ = asgi_call(app, "DELETE", "/api/university/session", headers=h)
        assert st == 200 and not vault.has_university_credentials(uid, "luh")
    finally:
        accounts.db_path().unlink(missing_ok=True)
