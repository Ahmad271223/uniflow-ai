"""Browserfenster in der Windows-App (app/desktop_windows.py): Auftraege fuer das Tauri-Fenster, Zustandsmeldungen,
Links als App-Fenster, Hochschul-Anmeldung ueber die Cookies des App-Fensters (27.10.2026)."""
import json
import threading
import time

import pytest

from conftest import asgi_call

LOOP = ("127.0.0.1", 5000)


@pytest.fixture(autouse=True)
def _clean():
    from app import desktop_windows
    desktop_windows.reset()
    yield
    desktop_windows.reset()


def _post(app, path, body, client=LOOP):
    st, _, b = asgi_call(app, "POST", path, client=client, body=json.dumps(body))
    return st, (json.loads(b) if b else None)


def test_queue_long_poll_report_and_finish():
    from app import desktop_windows as dw
    assert not dw.agent_connected(), "vor der ersten Abfrage kein Agent"
    assert dw.next_command(wait=0) is None
    w = dw.enqueue("login", "https://studip.test/login", "Anmeldung", ["https://studip.test"])
    assert dw.pending() == 1 and w.status == "pending"
    cmd = dw.next_command(wait=0)
    assert cmd == {"id": w.id, "kind": "login", "url": "https://studip.test/login", "title": "Anmeldung", "cookie_urls": ["https://studip.test"]}
    assert dw.agent_connected(), "eine Abfrage macht den Agenten bekannt"
    assert dw.report("w999", "open") == {"done": True, "known": False}, "verwaistes Fenster schliessen"
    r = dw.report(w.id, "open", "https://studip.test/dispatch.php/start", [{"name": "Seminar_Session", "value": "abc", "domain": "studip.test", "extra": 1}, {"nonsense": 1}])
    assert r == {"done": False, "known": True}
    cur = dw.wait_update(w.id, 0, 0.1)
    assert cur.status == "open" and cur.current_url.endswith("/start") and cur.cookies == [{"name": "Seminar_Session", "value": "abc", "domain": "studip.test", "path": None, "expires": None, "httpOnly": None, "secure": None}]
    dw.finish(w.id, "ok")
    assert dw.report(w.id, "open") == {"done": True, "known": True}
    assert dw.wait_update("w999", 0, 0.1) is None
    # lange Abfrage endet, sobald ein Auftrag kommt
    got = []
    t = threading.Thread(target=lambda: got.append(dw.next_command(wait=5)))
    t.start(); time.sleep(0.2)
    dw.enqueue("open", "https://example.org/", "example.org")
    t.join(5)
    assert got and got[0]["kind"] == "open"


def test_agent_endpoints_only_in_the_desktop_app(app, monkeypatch):
    from app import desktop_windows as dw
    monkeypatch.delenv("LERNAPP_DESKTOP", raising=False)
    assert asgi_call(app, "GET", "/api/desktop/commands?wait=0")[0] == 404
    monkeypatch.setenv("LERNAPP_DESKTOP", "1")
    assert asgi_call(app, "GET", "/api/desktop/commands?wait=0", client=("10.0.0.5", 1))[0] in (401, 403), "nur vom eigenen Rechner"
    st, _, body = asgi_call(app, "GET", "/api/desktop/commands?wait=0")
    assert st == 204 and body == b""
    assert json.loads(asgi_call(app, "GET", "/api/desktop")[2]) == {"desktop": True, "windows_agent": True}
    w = dw.enqueue("open", "https://studip.test/x", "studip.test")
    st, _, body = asgi_call(app, "GET", "/api/desktop/commands?wait=0")
    assert st == 200 and json.loads(body)["id"] == w.id
    st, d = _post(app, f"/api/desktop/windows/{w.id}/state", {"status": "open", "url": "https://studip.test/x", "cookies": [{"name": "a", "value": "b"}]})
    assert (st, d) == (200, {"done": False, "known": True})
    assert dw.wait_update(w.id, 0, 0.1).cookies[0]["value"] == "b"
    assert asgi_call(app, "GET", "/api/desktop/commands?wait=1.5")[0] == 204, "wait wird als Zahl gelesen"


def test_links_open_in_app_windows_when_the_agent_is_connected(app, monkeypatch):
    import webbrowser
    from app import desktop_windows as dw
    opened = []
    monkeypatch.setattr(webbrowser, "open", lambda url, new=0: opened.append(url) or True)
    monkeypatch.setenv("LERNAPP_DESKTOP", "1")
    url = "https://studip.uni-hannover.de/dispatch.php/course/overview?cid=abc"
    st, d = _post(app, "/api/desktop/open", {"url": url})
    assert (st, d) == (200, {"opened": True, "in_app": False}) and opened == [url], "ohne Agent: Systembrowser"
    dw.next_command(wait=0)                                                     # der Agent meldet sich
    st, d = _post(app, "/api/desktop/open", {"url": url})
    assert st == 200 and d["in_app"] is True and opened == [url], "mit Agent: Fenster der App, kein zweiter Browser"
    cmd = dw.next_command(wait=0)
    assert cmd["kind"] == "open" and cmd["url"] == url and cmd["title"] == "studip.uni-hannover.de" and cmd["id"] == d["window"]


def test_university_login_in_app_window(app, monkeypatch, tmp_path):
    """Die Anmeldung laeuft in einem Fenster der App: der Agent liefert Cookies, das Backend prueft sie, merkt die
    Sitzung und laesst das Fenster schliessen. Geschlossenes Fenster -> keine Sitzung."""
    from app import desktop_windows as dw, unilogin
    monkeypatch.setenv("LERNAPP_DESKTOP", "1")
    monkeypatch.setattr(unilogin, "TIMEOUT_S", 20)
    monkeypatch.setattr(unilogin, "check_cookies", lambda key, cookies: any(c.get("name") == "Seminar_Session" for c in cookies))
    monkeypatch.setattr(unilogin, "_cookie_urls", lambda key: ["https://studip.test"])
    unilogin.forget()
    dw.next_command(wait=0)                                                     # Agent verbunden
    out = {}
    t = threading.Thread(target=lambda: out.update(result=unilogin.run("luh", launch=None)))
    t.start()
    cmd = dw.next_command(wait=5)
    assert cmd and cmd["kind"] == "login" and cmd["cookie_urls"] == ["https://studip.test"] and "Shibboleth" in cmd["url"]
    assert dw.report(cmd["id"], "open", cmd["url"], [{"name": "fremd", "value": "x"}])["done"] is False
    time.sleep(0.3)
    assert unilogin.status()["state"] == "open"
    r = dw.report(cmd["id"], "open", "https://studip.test/dispatch.php/start", [{"name": "Seminar_Session", "value": "s1", "domain": "studip.test"}])
    t.join(10)
    assert out.get("result") == "angemeldet" and unilogin.status()["state"] == "ok"
    assert dw.report(cmd["id"], "open")["done"] is True, "Backend fertig: Fenster schliessen"
    assert [c["name"] for c in unilogin.saved_cookies("STUDIP_COOKIES")] == ["Seminar_Session"]
    assert r["done"] in (False, True)

    # Fenster geschlossen, bevor angemeldet
    unilogin.forget()
    out.clear()
    err = {}
    def run_closed():
        try:
            unilogin.run("luh", launch=None)
        except unilogin.LoginRequired as e:
            err["e"] = str(e)
    t = threading.Thread(target=run_closed); t.start()
    cmd = dw.next_command(wait=5)
    dw.report(cmd["id"], "closed")
    t.join(10)
    assert "geschlossen" in err.get("e", "") and unilogin.status()["state"] == "closed" and not unilogin.has_session("STUDIP_COOKIES")


def test_cookie_header_and_checks(monkeypatch):
    from app import unilogin
    cookies = [{"name": "a", "value": "1", "domain": ".studip.test"}, {"name": "b", "value": "2", "domain": "other.test"},
               {"name": "c", "value": "3", "domain": "studip.test", "expires": 1}, {"name": "d", "value": "4", "domain": "studip.test", "expires": -1}]
    assert unilogin._cookie_header(cookies, "https://studip.test/x") == "a=1; d=4"
    assert unilogin._cookie_header([], "https://studip.test/x") == ""
    monkeypatch.setattr(unilogin, "_get_with_cookies", lambda url, cookies, accept="text/html,*/*", timeout=20: '{"data": {"attributes": {"username": "x"}}}' if "users/me" in url else None)
    assert unilogin.check_cookies("luh", cookies) is True
    monkeypatch.setattr(unilogin, "_get_with_cookies", lambda *a, **k: None)
    assert unilogin.check_cookies("luh", cookies) is False
    monkeypatch.setattr(unilogin, "_get_with_cookies", lambda *a, **k: '<body class="notloggedin">M.cfg.sesskey')
    monkeypatch.setattr("app.hildesheim.learnweb_base", lambda: "https://lw.test")
    assert unilogin.check_cookies("hildesheim", cookies) is False
    monkeypatch.setattr(unilogin, "_get_with_cookies", lambda *a, **k: '<body class="path-my">M.cfg = {sesskey: "k"}')
    assert unilogin.check_cookies("hildesheim", cookies) is True
