"""Angemeldet bleiben auf Windows/PC (05.11.2026, Gegenstueck zu UniSessionKeeper/UniCookiePolicy der iPad-App, Commit 1f99d9b):
die Sitzung ueberlebt den Neustart (Datei im Datenordner), schliesst die Cookies der Anmeldeseite der Hochschule ein (WebSSO,
CAS), wird beim Abgleich still erneuert (ohne Passwort) und die App merkt nie ein Passwort."""
import json
import os
import stat
import threading
import time

import pytest

IDP = {"name": "shib_idp_session", "value": "idp1", "domain": "sso.idm.uni-hannover.de", "path": "/idp", "secure": True, "httpOnly": True}
STUDIP = {"name": "Seminar_Session", "value": "s1", "domain": "studip.uni-hannover.de", "path": "/"}


def test_login_window_reports_the_cookies_of_the_login_page_too(app, monkeypatch):
    """Das Anmeldefenster der Windows-App meldet nicht nur Stud.IP, auch die Anmeldeseite (WebSSO) bzw. CAS und LSF."""
    from app import config, unilogin
    monkeypatch.setattr("app.hildesheim.learnweb_base", lambda: "https://www.uni-hildesheim.de/learnweb2026")
    luh = unilogin._cookie_urls("luh")
    assert luh[0] == config.STUDIP_BASE and "https://sso.idm.uni-hannover.de/idp/" in luh
    hi = unilogin._cookie_urls("hildesheim")
    assert any(u.startswith("https://www.uni-hildesheim.de/sso") for u in hi) and any("lsf.uni-hildesheim.de" in u for u in hi)
    assert all(u.startswith("https://") for u in luh + hi), "nie ueber http"


def test_session_survives_a_restart_with_the_sso_cookie_and_renews_without_a_password(app, monkeypatch):
    """Anmelden im App-Fenster -> Datei -> 'Neustart' (Speicher leer, nur die Datei) -> Abgleich ohne Passwort: das WebSSO
    kennt die Sitzung (shib_idp_session) und stellt die Stud.IP-Sitzung neu aus."""
    from app import config, desktop_windows as dw, studip_sync, unilogin
    monkeypatch.setenv("LERNAPP_DESKTOP", "1")
    monkeypatch.setattr(unilogin, "TIMEOUT_S", 20)
    monkeypatch.setattr(unilogin, "check_cookies", lambda key, cookies: any(c.get("name") == "Seminar_Session" for c in cookies))
    unilogin.forget()
    dw.next_command(wait=0)
    out = {}
    t = threading.Thread(target=lambda: out.update(result=unilogin.run("luh", launch=None)))
    t.start()
    cmd = dw.next_command(wait=5)
    assert unilogin.LUH_SSO_URL in cmd["cookie_urls"]
    # Tauri liefert die Cookies beider Hosts (Sitzungs-Cookies ohne Ablauf = expires null)
    dw.report(cmd["id"], "open", "https://studip.uni-hannover.de/dispatch.php/start", [{**STUDIP, "expires": None}, {**IDP, "expires": None}])
    t.join(10)
    assert out.get("result") == "angemeldet"
    # "Neustart": nur die Datei im Datenordner bleibt
    assert unilogin.session_path().exists()
    assert {c["name"] for c in unilogin.saved_cookies("STUDIP_COOKIES")} == {"Seminar_Session", "shib_idp_session"}
    assert unilogin.has_session("STUDIP_COOKIES"), "Sitzungs-Cookies ohne Ablauf gelten bis der Server sie beendet"

    class Ctx:
        def __init__(self): self.added = []
        def add_cookies(self, c): self.added.extend(c)
    ctx = Ctx()
    assert unilogin.restore(ctx, "STUDIP_COOKIES") == 2 and {c["domain"] for c in ctx.added} == {"studip.uni-hannover.de", "sso.idm.uni-hannover.de"}

    # Abgleich ohne Zugangsdaten: Stud.IP-Sitzung abgelaufen, das WebSSO erneuert sie still
    class Page:
        url = ""
        visited: list
        def __init__(self): self.visited = []
        def goto(self, url, **kw): self.url = url; self.visited.append(url)
        def wait_for_timeout(self, ms): pass
    monkeypatch.setattr(config, "credentials", lambda: ("", ""))
    idp_known = {"yes": True}
    monkeypatch.setattr(studip_sync, "_is_logged_in", lambda page: "Shibboleth.sso/Login" in page.url and idp_known["yes"])
    page = Page()
    studip_sync._login(page)                                    # kein Fehler, kein Passwortfeld angefasst (Page hat keinen locator)
    assert any("Shibboleth.sso/Login" in u for u in page.visited)
    # Das WebSSO kennt die Sitzung nicht mehr: erst jetzt "Anmeldung noetig"
    idp_known["yes"] = False
    page = Page()
    with pytest.raises(unilogin.LoginRequired):
        studip_sync._login(page)
    assert any("Shibboleth.sso/Login" in u for u in page.visited), "der stille Versuch kam vor der Meldung"
    unilogin.forget()


def test_no_password_is_ever_kept(app):
    """Cookies mit passwortaehnlichem Namen werden nie gemerkt; die Sitzungsdatei steht nur fuer den Nutzer; die .env
    bleibt frei von Sitzung und Passwort."""
    from app import config, unilogin
    unilogin.forget()
    unilogin.save_session("STUDIP_COOKIES", [STUDIP, {"name": "user_password", "value": "geheim", "domain": "studip.uni-hannover.de"},
                                             {"name": "LoginPasswd", "value": "geheim", "domain": "sso.idm.uni-hannover.de"},
                                             {"name": "PWD_hint", "value": "geheim", "domain": "x"}, {"name": "Kennwort", "value": "g", "domain": "x"}, IDP])
    p = unilogin.session_path()
    data = json.loads(p.read_text(encoding="utf-8"))
    assert [c["name"] for c in data["STUDIP_COOKIES"]["cookies"]] == ["Seminar_Session", "shib_idp_session"]
    assert "geheim" not in p.read_text(encoding="utf-8")
    if os.name == "posix":
        assert stat.S_IMODE(p.stat().st_mode) == 0o600
    env = config.env_file().read_text(encoding="utf-8") if config.env_file().exists() else ""
    assert "Seminar_Session" not in env and "geheim" not in env
    assert unilogin.looks_like_secret("Passwort") and not unilogin.looks_like_secret("Seminar_Session")
    unilogin.forget()


def test_forgetting_the_session_removes_the_file(app):
    from app import unilogin
    unilogin.save_session("STUDIP_COOKIES", [STUDIP])
    assert unilogin.session_path().exists()
    unilogin.forget("STUDIP_COOKIES")
    assert not unilogin.session_path().exists() and not unilogin.has_session("STUDIP_COOKIES")


def test_expired_cookies_do_not_count_as_a_session(app):
    from app import unilogin
    unilogin.save_session("STUDIP_COOKIES", [{**STUDIP, "expires": time.time() - 5}])
    assert not unilogin.has_session("STUDIP_COOKIES")
    unilogin.forget()
