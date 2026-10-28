"""Anmeldeseite des gehosteten Dienstes (Web): Umleitungen ohne/mit Sitzung, Seite mit CSP und ohne Inline-Skript,
Abmelden loescht das Cookie, Passwort-vergessen-Ablauf ueber den Link /login?reset=TOKEN; am PC gibt es die Seite nicht."""
import json
import re
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
STATIC = ROOT / "app" / "static"


@pytest.fixture
def hosted(app, monkeypatch):
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    for suffix in ("", "-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "reset_sender", None)
    yield app
    accounts.db_path().unlink(missing_ok=True)


def _h(headers, name):
    return [v.decode() for k, v in headers if k == name.encode()]


def _register(app, email):
    st, h, body = asgi_call(app, "POST", "/api/account/register",
                            body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": "luh", "device_name": "Browser Windows"}))
    assert st == 201, body
    cookie = _h(h, "set-cookie")[0].split(";")[0]
    assert cookie.startswith("uniflow_session=")
    return cookie


def test_hosted_root_redirects_to_login_without_session(hosted):
    st, h, _ = asgi_call(hosted, "GET", "/")
    assert (st, _h(h, "location")) == (302, ["/login"])
    st, h, _ = asgi_call(hosted, "GET", "/index.html")
    assert (st, _h(h, "location")) == (302, ["/login"])
    st, h, body = asgi_call(hosted, "GET", "/login")
    assert st == 200 and _h(h, "content-type")[0].startswith("text/html")
    assert "script-src 'self'" in _h(h, "content-security-policy")[0], "Anmeldeseite unter derselben CSP wie die App"
    assert "no-cache" in _h(h, "cache-control")[0]
    html = body.decode("utf-8")
    assert 'src="login.js' in html and "<script>" not in html, "kein Inline-Skript"
    for fid in ("login", "register", "forgot", "reset"):
        assert f'<form id="{fid}"' in html
    assert "uniflow_session" not in html
    st, h, _ = asgi_call(hosted, "GET", "/login.js")
    assert st == 200 and "javascript" in _h(h, "content-type")[0]
    # Oeffentliche Kontopfade bleiben ohne Sitzung erreichbar, alles andere nicht
    assert asgi_call(hosted, "GET", "/api/account/info")[0] == 200
    assert asgi_call(hosted, "GET", "/api/settings")[0] == 401


def test_hosted_session_cookie_opens_app_and_logout_closes_it(hosted):
    cookie = _register(hosted, "web@beispiel.de")
    st, h, body = asgi_call(hosted, "GET", "/", cookies=cookie)
    assert st == 200 and b"<title>UniFlow AI</title>" in body, "mit Sitzung die App"
    st, h, _ = asgi_call(hosted, "GET", "/login", cookies=cookie)
    assert (st, _h(h, "location")) == (302, ["/"]), "angemeldet: Anmeldeseite leitet zur App"
    st, _, body = asgi_call(hosted, "GET", "/api/account/me", cookies=cookie)
    me = json.loads(body)
    assert st == 200 and me["user"]["email"] == "web@beispiel.de" and me["sessions"][0]["device_name"] == "Browser Windows"
    # Abmelden: Cookie weg, Sitzung ungueltig, Startseite wieder zur Anmeldung
    st, h, _ = asgi_call(hosted, "POST", "/api/account/logout", cookies=cookie)
    assert st == 200
    gone = _h(h, "set-cookie")[0]
    assert gone.startswith("uniflow_session=") and ("max-age=0" in gone.lower() or "expires=" in gone.lower())
    assert asgi_call(hosted, "GET", "/api/account/me", cookies=cookie)[0] == 401
    st, h, _ = asgi_call(hosted, "GET", "/", cookies=cookie)
    assert (st, _h(h, "location")) == (302, ["/login"])


def test_login_with_wrong_password_sets_no_cookie(hosted):
    _register(hosted, "w@beispiel.de")
    st, h, body = asgi_call(hosted, "POST", "/api/account/login", body=json.dumps({"email": "w@beispiel.de", "password": "falsch-falsch-1"}))
    assert st == 401 and not _h(h, "set-cookie") and json.loads(body)["detail"]


def test_password_reset_link_flow(hosted, monkeypatch):
    """Passwort vergessen: Antwort immer gleich; der Link /login?reset=TOKEN oeffnet die Seite, das neue Passwort
    meldet alle Geraete ab, danach Anmelden mit dem neuen."""
    from app import accounts
    sent = {}
    monkeypatch.setattr(accounts, "reset_sender", lambda email, token: sent.update(email=email, token=token))
    cookie = _register(hosted, "r@beispiel.de")
    st, _, body = asgi_call(hosted, "POST", "/api/account/password/reset-request", body=json.dumps({"email": "r@beispiel.de"}))
    assert st == 200 and "Link" in json.loads(body)["message"] and sent["email"] == "r@beispiel.de"
    st, _, body2 = asgi_call(hosted, "POST", "/api/account/password/reset-request", body=json.dumps({"email": "niemand@beispiel.de"}))
    assert (st, body2) == (200, body), "verraet nicht, ob es das Konto gibt"
    st, h, _ = asgi_call(hosted, "GET", f"/login?reset={sent['token']}")
    assert st == 200
    st, _, body = asgi_call(hosted, "POST", "/api/account/password/reset", body=json.dumps({"token": sent["token"], "new_password": "noch-geheimer-456"}))
    assert st == 200, body
    assert asgi_call(hosted, "GET", "/api/account/me", cookies=cookie)[0] == 401, "alte Sitzungen beendet"
    st, h, _ = asgi_call(hosted, "POST", "/api/account/login", body=json.dumps({"email": "r@beispiel.de", "password": "noch-geheimer-456"}))
    assert st == 200 and _h(h, "set-cookie")[0].startswith("uniflow_session=")
    st, _, body = asgi_call(hosted, "POST", "/api/account/password/reset", body=json.dumps({"token": sent["token"], "new_password": "noch-geheimer-789"}))
    assert (st, json.loads(body)["code"]) == (400, "reset_invalid"), "Link nur einmal"


def test_local_mode_has_no_login_page(app):
    st, h, _ = asgi_call(app, "GET", "/login")
    assert (st, _h(h, "location")) == (302, ["/"])
    st, _, body = asgi_call(app, "GET", "/")
    assert st == 200 and b"<title>UniFlow AI</title>" in body


def test_login_script_uses_only_public_account_paths():
    """Die Anmeldeseite darf nur die oeffentlichen Kontopfade rufen (alles andere braucht eine Sitzung) und
    verschickt nie ein Token selbst (Cookie kommt vom Server)."""
    from app import account_api
    js = (STATIC / "login.js").read_text(encoding="utf-8")
    used = {"/api/account" + p for p in re.findall(r'post\("(/[a-z/-]+)"', js)}
    assert used == {"/api/account/login", "/api/account/register", "/api/account/password/reset-request", "/api/account/password/reset",
                    "/api/account/login/google", "/api/account/login/apple", "/api/account/verify-email"}
    assert used <= account_api.PUBLIC_PATHS
    assert "/api/account/info" in js and "Authorization" not in js and "localStorage" not in js
    app_js = (STATIC / "app.js").read_text(encoding="utf-8")
    assert '"/account/logout"' in app_js and 'location.replace("/login")' in app_js, "Abmelden fuehrt zur Anmeldeseite"
