"""Sign in with ChatGPT auf dem eigenen PC (app/chatgpt_login.py): PKCE, Rueckleitung, Erstregistrierung, Erneuerung,
Ablage nur auf dem Rechner, Umleitung der KI-Anfragen, Endpunkte. Ohne Netz: Token-Endpunkt und ID-Token-Pruefung sind
Attrappen. Im Dienst bleibt alles aus (503), siehe tests/test_subscriptions.py::test_14."""
import base64
import hashlib
import json
import os
import time
import urllib.parse
import urllib.request

import pytest
from conftest import asgi_call


@pytest.fixture
def cg(app, monkeypatch, tmp_path):
    """Frische Ablage je Test, keine echten Aufrufe, kein Browser."""
    from app import chatgpt_login as m, config
    monkeypatch.setattr(config, "MODE", "local")
    monkeypatch.setattr(m, "auth_path", lambda: tmp_path / "chatgpt-auth.json")
    m._flow = None
    m._models_cache = None
    monkeypatch.setattr(m, "http_post_form", lambda url, fields: pytest.fail(f"unerwarteter Aufruf {url}"))
    monkeypatch.setattr(m, "http_get_json", lambda url, bearer: pytest.fail(f"unerwarteter Aufruf {url}"))
    monkeypatch.setattr(m, "verify_id_token", lambda token, client_id, nonce, now=None: {"sub": "u1", "email": "ich@example.org", "name": "Ich"})
    import webbrowser
    monkeypatch.setattr(webbrowser, "open", lambda *a, **k: pytest.fail("Browser darf im Test nicht aufgehen"))
    return m


def _token_response(**extra):
    return {"access_token": "at-1", "refresh_token": "rt-1", "id_token": "idt.1.x", "token_type": "Bearer", "expires_in": 3600,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", **extra}


def _login(cg, monkeypatch, client_id="oaiapp_test"):
    """Verbundenen Zustand herstellen (wie nach einer erfolgreichen Rueckleitung)."""
    monkeypatch.setattr(cg, "http_post_form", lambda url, fields: _token_response())
    d = cg.load()
    cg.complete_login(d, client_id, "code-1", "verifier", "http://127.0.0.1:1/auth/callback", "nonce")
    cg.set_model("gpt-5")
    return cg.load()


def test_pkce_and_authorization_url(cg):
    verifier, challenge = cg.pkce()
    assert 43 <= len(verifier) <= 128 and all(c.isalnum() or c in "-_" for c in verifier)
    assert challenge == base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    assert "=" not in challenge
    host = cg.host_id()
    assert host.startswith("urn:uuid:") and cg.host_id() == host, "Rechnerkennung bleibt"
    first = urllib.parse.urlsplit(cg.build_auth_url(None, host, "http://127.0.0.1:1455/auth/callback", "st", "no", challenge))
    q = dict(urllib.parse.parse_qsl(first.query))
    assert first.scheme == "https" and first.netloc == "auth.openai.com" and first.path == "/api/accounts/authorize"
    assert q["client_id"] == "dynamic_agent_client" and q["agent_name_hint"] == "Studora" and q["ext_agent_host_id"] == host
    assert q["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    assert q["resource"] == "https://api.openai.com/v1" and q["response_type"] == "code"
    assert q["redirect_uri"] == "http://127.0.0.1:1455/auth/callback" and "localhost" not in q["redirect_uri"]
    assert (q["state"], q["nonce"], q["code_challenge"], q["code_challenge_method"]) == ("st", "no", challenge, "S256")
    again = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(cg.build_auth_url("oaiapp_x", host, "http://127.0.0.1:2/auth/callback", "s", "n", "c", login_hint="ich@example.org")).query))
    assert again["client_id"] == "oaiapp_x" and "agent_name_hint" not in again and again["login_hint"] == "ich@example.org"
    assert "id_token_hint" not in again and "prompt" not in again, "kein Token in der Browser-Adresse, keine erzwungene Zustimmung"
    consent = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(cg.build_auth_url("oaiapp_x", host, "r", "s", "n", "c", reconsent=True)).query))
    assert consent["prompt"] == "consent" and "login_hint" not in consent
    fresh = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(cg.build_auth_url(None, host, "r", "s", "n", "c", login_hint="x@y")).query))
    assert "login_hint" not in fresh, "bei der Erstregistrierung gibt es kein Profil"


def test_callback_rejects_wrong_state_and_denial_without_exchange(cg):
    flow = cg.Flow(1455, None)
    status, page = cg.handle_callback(flow, {"code": "c", "state": "falsch", "client_id": "oaiapp_x"})
    assert status == 400 and "state" in page and not flow.done.is_set()
    status, page = cg.handle_callback(flow, {"error": "access_denied", "state": flow.state})
    assert status == 200 and "abgebrochen" in page and flow.done.is_set() and not flow.ok
    assert not cg.connected() and cg.load().get("client_id") is None


def test_first_registration_saves_client_id_before_exchange(cg, monkeypatch):
    seen = {}

    def exchange(url, fields):
        seen["fields"] = fields
        assert cg.load()["client_id"] == "oaiapp_neu", "Client-ID muss vor dem Tausch gespeichert sein"
        return _token_response()
    monkeypatch.setattr(cg, "http_post_form", exchange)
    flow = cg.Flow(1455, None)
    status, page = cg.handle_callback(flow, {"code": "code-7", "state": flow.state, "client_id": "oaiapp_neu"})
    assert status == 200 and flow.ok and "verbunden" in page
    assert seen["fields"] == {"grant_type": "authorization_code", "client_id": "oaiapp_neu", "code": "code-7",
                              "code_verifier": flow.verifier, "redirect_uri": "http://127.0.0.1:1455/auth/callback",
                              "resource": "https://api.openai.com/v1"}
    d = cg.load()
    assert d["credentials"]["access_token"] == "at-1" and d["credentials"]["refresh_token"] == "rt-1"
    assert "chatgpt.tokens.use.direct" in d["credentials"]["scopes"] and cg.sharing()
    assert d["profile"] == {"sub": "u1", "email": "ich@example.org", "name": "Ich"}
    assert d["credentials"]["expires_at"] > time.time() + 3000
    # Erstregistrierung ohne ausgestellte Client-ID ist unvollstaendig; bei Neuanmeldung muss die ID passen
    flow2 = cg.Flow(1456, None)
    assert cg.handle_callback(flow2, {"code": "x", "state": flow2.state})[0] == 400
    flow3 = cg.Flow(1457, "oaiapp_neu")
    assert cg.handle_callback(flow3, {"code": "x", "state": flow3.state, "client_id": "oaiapp_anders"})[0] == 400 and not flow3.ok


def test_refresh_replaces_everything_together_and_401_needs_login(cg, monkeypatch):
    _login(cg, monkeypatch)
    d = cg.load()
    d["credentials"]["expires_at"] = time.time() + 10          # laeuft gleich ab
    cg.save(d)
    calls = []
    monkeypatch.setattr(cg, "http_post_form", lambda url, fields: calls.append(fields) or _token_response(access_token="at-2", refresh_token="rt-2", scope="openid chatgpt.tokens.use.direct"))
    assert cg.access_token() == "at-2"
    assert calls == [{"grant_type": "refresh_token", "refresh_token": "rt-1", "client_id": "oaiapp_test", "resource": "https://api.openai.com/v1"}]
    c = cg.load()["credentials"]
    assert (c["access_token"], c["refresh_token"], c["scopes"]) == ("at-2", "rt-2", ["openid", "chatgpt.tokens.use.direct"])
    assert cg.access_token() == "at-2" and len(calls) == 1, "gueltiges Token wird nicht erneuert"
    # abgelehnte Erneuerung: neu anmelden, KI bleibt aus
    d = cg.load(); d["credentials"]["expires_at"] = 0; cg.save(d)
    monkeypatch.setattr(cg, "http_post_form", lambda url, fields: (_ for _ in ()).throw(cg.ChatGPTError("chatgpt_http_error", "invalid_grant", 400)))
    with pytest.raises(cg.ChatGPTError) as e:
        cg.access_token()
    assert e.value.code == "chatgpt_login_needed" and cg.status()["needs_reauth"] and not cg.enabled_for_ai()
    host = cg.host_id()
    cg.disconnect()
    assert not cg.connected() and cg.load()["client_id"] == "oaiapp_test" and cg.load()["host_id"] == host, "Kennung und Client-ID bleiben"
    with pytest.raises(cg.ChatGPTError):
        cg.access_token()


def test_file_is_private_and_hosted_mode_refuses(cg, monkeypatch, tmp_path):
    modes = []
    monkeypatch.setattr(os, "chmod", lambda p, m: modes.append(m))
    cg.save({"x": 1})
    assert modes == [0o600] and json.loads((tmp_path / "chatgpt-auth.json").read_text(encoding="utf-8")) == {"x": 1}
    from app import config
    monkeypatch.setattr(config, "MODE", "hosted")
    assert not cg.available() and cg.status() == {**cg.status(), "available": False, "connected": False}
    with pytest.raises(cg.ChatGPTError) as e:
        cg.start(open_browser=False)
    assert e.value.status == 503
    with pytest.raises(cg.ChatGPTError):
        cg.access_token()
    assert not cg.enabled_for_ai()


def test_login_opens_in_the_app_window_when_the_agent_is_connected(cg, monkeypatch):
    """Windows-App: die Anmeldung geht als Fenster der App auf (Fenster-Agent verbunden), sonst Standardbrowser."""
    from app import desktop_windows
    desktop_windows.reset()
    monkeypatch.setattr(desktop_windows, "agent_connected", lambda now=None: True)
    assert cg.open_url("https://auth.openai.com/x") is True
    cmd = desktop_windows.next_command(wait=0)
    assert cmd["kind"] == "open" and cmd["url"] == "https://auth.openai.com/x" and cmd["title"] == "ChatGPT verbinden"
    monkeypatch.setattr(desktop_windows, "agent_connected", lambda now=None: False)
    opened = []
    import webbrowser
    monkeypatch.setattr(webbrowser, "open", lambda url, new=0: opened.append(url) or True)
    assert cg.open_url("https://auth.openai.com/y") is False and opened == ["https://auth.openai.com/y"]
    desktop_windows.reset()


def test_loopback_server_completes_a_real_callback(cg, monkeypatch):
    monkeypatch.setattr(cg, "http_post_form", lambda url, fields: _token_response())
    r = cg.start(open_browser=False)
    assert r["redirect_uri"] == f"http://127.0.0.1:{r['port']}/auth/callback" and r["auth_url"].startswith("https://auth.openai.com/")
    assert cg.status()["pending"]["port"] == r["port"]
    flow = cg._flow
    url = r["redirect_uri"] + "?" + urllib.parse.urlencode({"code": "c-1", "state": flow.state, "client_id": "oaiapp_live"})
    with urllib.request.urlopen(url, timeout=10) as resp:
        body = resp.read().decode("utf-8")
    assert resp.status == 200 and "verbunden" in body and flow.ok
    st = cg.status()
    assert st["connected"] and st["sharing"] and st["email"] == "ich@example.org" and st["pending"] is None
    # ein zweiter Start beendet den alten Ablauf; die neue Anmeldung nutzt die ausgestellte Client-ID
    r2 = cg.start(open_browser=False)
    assert "client_id=oaiapp_live" in r2["auth_url"] and "agent_name_hint" not in r2["auth_url"]
    cg._flow.done.set()


def test_ask_uses_chatgpt_only_when_wanted(cg, monkeypatch):
    from app import ai, ai_backend
    assert not ai.uses_chatgpt(), "nicht verbunden: Claude"
    _login(cg, monkeypatch)
    assert ai.uses_chatgpt()
    sent = {}

    class Fake:
        def __init__(self, model_name, timeout=120):
            sent["model"] = model_name

        def complete(self, system, prompt, schema=None):
            sent["system"], sent["prompt"] = system, prompt
            return ai_backend.Completion("Antwort von ChatGPT", 10, 5, "gpt-5")
    monkeypatch.setattr(ai_backend, "ChatGPTProvider", Fake)
    assert ai.ask("Frage?", "System") == "Antwort von ChatGPT" and sent == {"model": "gpt-5", "system": "System", "prompt": "Frage?"}
    with pytest.raises(ai.AIError, match="nur Claude"):
        ai.ask("Bild lesen", allowed_tools=["Read"])
    cg.set_use_for_ai(False)
    assert not ai.uses_chatgpt(), "Schalter aus: Claude"
    cg.set_use_for_ai(True)
    d = cg.load(); d["model"] = ""; cg.save(d)
    assert not ai.uses_chatgpt(), "ohne Modell: Claude"
    with pytest.raises(cg.ChatGPTError):
        cg.set_model("kein modell")


def test_provider_maps_errors(cg, monkeypatch):
    from app import ai_backend
    _login(cg, monkeypatch)
    import urllib.error

    def fail(code):
        def opener(req, timeout=0):
            raise urllib.error.HTTPError(req.full_url, code, "x", {}, None)
        return opener
    p = ai_backend.ChatGPTProvider("gpt-5")
    monkeypatch.setattr(urllib.request, "urlopen", fail(429))
    with pytest.raises(ai_backend.AIUnavailable) as e:
        p.complete("s", "p")
    assert e.value.code == "chatgpt_limit" and "Nutzung" in e.value.message
    monkeypatch.setattr(urllib.request, "urlopen", fail(401))
    with pytest.raises(ai_backend.AIUnavailable) as e:
        p.complete("s", "p")
    assert e.value.code == "chatgpt_login_needed" and cg.status()["needs_reauth"]


def test_api_endpoints_local(app, cg, monkeypatch):
    j = lambda r: (r[0], json.loads(r[2]))
    st, d = j(asgi_call(app, "GET", "/api/integrations/chatgpt"))
    assert st == 200 and d["available"] and d["status"] == "local" and not d["connected"] and d["plan_gating_allowed"] is False
    st, d = j(asgi_call(app, "POST", "/api/integrations/chatgpt/connect", body=json.dumps({"open_browser": False})))
    assert st == 200 and d["auth_url"].startswith("https://auth.openai.com/") and d["port"] > 0
    cg._flow.done.set()
    _login(cg, monkeypatch)
    monkeypatch.setattr(cg, "http_get_json", lambda url, bearer: {"data": [{"id": "gpt-5"}, {"id": "gpt-5-mini"}]} if bearer == "at-1" else pytest.fail("Token"))
    st, d = j(asgi_call(app, "GET", "/api/integrations/chatgpt/models"))
    assert (st, d) == (200, {"models": ["gpt-5", "gpt-5-mini"], "model": "gpt-5"})
    st, d = j(asgi_call(app, "PUT", "/api/integrations/chatgpt/settings", body=json.dumps({"model": "gpt-5-mini", "use_for_ai": False})))
    assert st == 200 and d["model"] == "gpt-5-mini" and d["use_for_ai"] is False
    st, d = j(asgi_call(app, "PUT", "/api/integrations/chatgpt/settings", body=json.dumps({"model": "mit leerzeichen"})))
    assert st == 400 and d["code"] == "chatgpt_model_invalid"
    st, d = j(asgi_call(app, "POST", "/api/integrations/chatgpt/disconnect", body="{}"))
    assert (st, d) == (200, {"connected": False}) and not cg.connected()


# ================================================================ Abgleich mit dem Devkit (30.10.2026)
def test_start_uses_login_hint_reconsent_and_new_account(cg, monkeypatch):
    _login(cg, monkeypatch)
    urls = []
    monkeypatch.setattr(cg, "open_url", lambda u: urls.append(u) or True)
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(cg.start()["auth_url"]).query))
    assert q["client_id"] == "oaiapp_test" and q["login_hint"] == "ich@example.org" and "prompt" not in q
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(cg.start(reconsent=True)["auth_url"]).query))
    assert q["prompt"] == "consent" and q["login_hint"] == "ich@example.org"
    host = cg.host_id()
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(cg.start(new_account=True)["auth_url"]).query))
    d = cg.load()
    assert q["client_id"] == "dynamic_agent_client" and q["agent_name_hint"] == "Studora" and "login_hint" not in q
    assert "client_id" not in d and "credentials" not in d and "profile" not in d and d["host_id"] == host, "Rechnerkennung bleibt"
    assert len(urls) == 3


def test_relogin_with_other_account_is_rejected(cg, monkeypatch):
    _login(cg, monkeypatch)
    monkeypatch.setattr(cg, "verify_id_token", lambda token, client_id, nonce, now=None: {"sub": "u2", "email": "anderer@example.org"})
    monkeypatch.setattr(cg, "http_post_form", lambda url, fields: _token_response(access_token="at-9"))
    with pytest.raises(cg.ChatGPTError) as e:
        cg.complete_login(cg.load(), "oaiapp_test", "code-2", "v", "http://127.0.0.1:1/auth/callback", "n")
    assert e.value.code == "chatgpt_account_mismatch" and e.value.status == 409
    d = cg.load()
    assert d["profile"]["sub"] == "u1" and d["credentials"]["access_token"] == "at-1", "nichts ueberschrieben"
    # Erneuerung mit rotiertem ID-Token eines anderen Kontos: neu anmelden
    with pytest.raises(cg.ChatGPTError) as e:
        cg.refresh(cg.load())
    assert e.value.code == "chatgpt_login_needed" and cg.load()["needs_reauth"]
    # Erneuerung ohne ID-Token oder mit demselben Konto geht wie bisher
    cg.load(); d = cg.load(); d.pop("needs_reauth"); cg.save(d)
    monkeypatch.setattr(cg, "http_post_form", lambda url, fields: {"access_token": "at-3", "expires_in": 60})
    assert cg.refresh(cg.load())["credentials"]["access_token"] == "at-3"
    monkeypatch.setattr(cg, "verify_id_token", lambda token, client_id, nonce, now=None: {"sub": "u1", "email": "ich@example.org"})
    monkeypatch.setattr(cg, "http_post_form", lambda url, fields: _token_response(access_token="at-4", refresh_token="rt-4"))
    assert cg.refresh(cg.load())["credentials"]["refresh_token"] == "rt-4"


def test_earliest_refresh_at_delays_the_refresh(cg, monkeypatch):
    now = time.time()
    c = cg._credentials_from(_token_response(earliest_refresh_at=1_900_000_000))
    assert c["earliest_refresh_at"] == 1_900_000_000.0
    c = cg._credentials_from(_token_response(earliest_refresh_at="2030-01-01T00:00:00Z"))
    assert c["earliest_refresh_at"] == 1_893_456_000.0
    assert cg._credentials_from(_token_response(earliest_refresh_at="2030-01-01T00:00:00"))["earliest_refresh_at"] == 1_893_456_000.0, "ohne Zone = UTC"
    assert "earliest_refresh_at" not in cg._credentials_from(_token_response(earliest_refresh_at="irgendwann"))
    assert "earliest_refresh_at" not in cg._credentials_from(_token_response(earliest_refresh_at=True))
    _login(cg, monkeypatch)
    calls = []
    monkeypatch.setattr(cg, "http_post_form", lambda url, fields: calls.append(fields) or {"access_token": "at-neu", "expires_in": 3600})
    # kurz vor Ablauf, Erneuerung noch nicht erlaubt: das alte Token bleibt gueltig und wird genutzt
    d = cg.load(); d["credentials"]["expires_at"] = now + 30; d["credentials"]["earliest_refresh_at"] = now + 600; cg.save(d)
    assert cg.access_token() == "at-1" and not calls
    # abgelaufen und Erneuerung noch nicht erlaubt: klare Meldung, kein Aufruf
    d = cg.load(); d["credentials"]["expires_at"] = now - 1; cg.save(d)
    with pytest.raises(cg.ChatGPTError) as e:
        cg.access_token()
    assert e.value.code == "chatgpt_refresh_not_ready" and e.value.status == 503 and not calls
    # Sperre vorbei: erneuern
    d = cg.load(); d["credentials"]["earliest_refresh_at"] = now - 1; cg.save(d)
    assert cg.access_token() == "at-neu" and calls[0]["grant_type"] == "refresh_token"


def test_status_points_to_usage_settings(cg):
    assert cg.status()["usage_help_url"] == "https://chatgpt.com/settings/usage"
