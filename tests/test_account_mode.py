"""Konto- und Abo-Pflicht in Windows und Web (Entscheidung des Inhabers vom 05.11.2026: „anmelden immer muss ohne abo
geht nichts“; app/access.py, app/account_mode.py, app/app_login_api.py, app/token_store.py).

Der "Dienst" ist dieselbe App im gehosteten Modus, direkt per ASGI aufgerufen (wie tests/test_service_link.py); Stripe
und der Browser sind Attrappen. Nichts geht ins Netz, nichts wird bezahlt."""
import io
import json
import os
import time
import urllib.parse
import zipfile

import pytest
from conftest import asgi_call

SERVICE = "http://127.0.0.1:9"
PW = "sehr-geheim-123"
LOCAL_HOST = "127.0.0.1:8765"


def _j(r):
    st, _, b = r
    try:
        return st, (json.loads(b) if b else None)
    except ValueError:
        return st, b


def _hosted(app, method, path, body=None, headers=None, cookies=None):
    from app import config
    old = config.MODE
    config.MODE = "hosted"
    try:
        return _j(asgi_call(app, method, path, body=json.dumps(body) if body is not None else None, headers=headers, cookies=cookies))
    finally:
        config.MODE = old


def _local(app, method, path, body=None, host="test"):
    return _j(asgi_call(app, method, path, body=json.dumps(body) if body is not None else None, host=host))


@pytest.fixture
def svc(app, monkeypatch):
    """Windows-App (LERNAPP_DESKTOP=1, Konto-Pflicht) und Dienst im selben Prozess; `svc.offline` schaltet das Netz ab."""
    from app import account_mode, accounts, config, service_link, sync_client
    monkeypatch.setattr(sync_client, "start_background", lambda *a, **k: None)
    monkeypatch.setenv("LERNAPP_DESKTOP", "1")
    monkeypatch.setenv("LERNAPP_SERVICE_URL", SERVICE)
    monkeypatch.delenv("LERNAPP_OFFLINE_GRACE_DAYS", raising=False)
    accounts.db_path().unlink(missing_ok=True)
    service_link.state_path().unlink(missing_ok=True)
    account_mode.clear_cache()
    opened = []
    monkeypatch.setattr(account_mode, "open_url", lambda url: opened.append(url) or True)
    monkeypatch.setattr(account_mode, "run_later", lambda fn: fn())     # kein zweiter Thread, der config.MODE umschaltet

    class S:
        offline = False
        calls = []
    s = S()
    s.opened = opened

    def transport(method, url, headers, body, timeout):
        if s.offline:
            raise OSError("kein Netz")
        assert url.startswith(SERVICE), url
        path = url[len(SERVICE):]
        s.calls.append((method, path, dict(headers)))
        old = config.MODE
        config.MODE = "hosted"
        try:
            hdrs = {k: v for k, v in headers.items() if k.lower() in ("authorization", "x-studinow-client")}
            st, h, b = asgi_call(app, method, path, body=body or b"", headers=hdrs, content_type=headers.get("Content-Type", "application/json"))
        finally:
            config.MODE = old
        return st, {k.decode(): v.decode() for k, v in h}, b

    monkeypatch.setattr(service_link, "transport", transport)
    s.app = app
    yield s
    account_mode.clear_cache()
    service_link.state_path().unlink(missing_ok=True)
    accounts.db_path().unlink(missing_ok=True)
    assert config.MODE == "local"


def _register(app, email, verified=True):
    from app import accounts
    st, d = _hosted(app, "POST", "/api/account/register", {"email": email, "password": PW, "university": "luh"})
    assert st == 201, d
    if verified:
        accounts.mark_email_verified(d["user"]["id"])
    return d["user"], d["token"]


def _end_trial(uid):
    from app import accounts
    assert accounts.end_trial(uid)


def _login(app, email):
    st, d = _local(app, "POST", "/api/app-account/login", {"email": email, "password": PW})
    assert st == 200, d
    return d


# ================================================================ Ablage des Tokens

def test_token_store_memory_file_and_fallback(tmp_path):
    from app import token_store
    f = token_store.FileStore(tmp_path / "t")
    assert f.get() is None
    f.set("abc")
    assert f.get() == "abc" and oct(os.stat(tmp_path / "t").st_mode & 0o777) == "0o600", "nur fuer den eigenen Benutzer"
    f.delete()
    assert f.get() is None and not (tmp_path / "t").exists()

    class Broken:
        kind = "windows_credential_manager"
        def get(self):
            raise token_store.StoreError("gesperrt")
        def set(self, t):
            raise token_store.StoreError("gesperrt")
        def delete(self):
            raise token_store.StoreError("gesperrt")
    token_store.use(Broken())
    assert token_store.get() is None, "eine gesperrte Ablage gilt als leer"
    token_store.put("xyz")
    assert token_store.kind() == "memory" and token_store.get() == "xyz", "dann nur im Speicher, nie in einer Datei"
    token_store.use(None)
    assert token_store.kind() == "file", "ausserhalb von Windows: Datei mit 0600"


def test_token_never_in_the_state_file_and_old_files_migrate(svc):
    from app import service_link, token_store
    p = service_link.state_path()
    p.write_text(json.dumps({"url": SERVICE, "token": "alt-token", "user": {"email": "x@example.org"}}), encoding="utf-8")
    st = service_link.load_state()
    assert st["token"] == "alt-token" and token_store.get() == "alt-token"
    assert "token" not in json.loads(p.read_text(encoding="utf-8")), "altes Token zieht in die Ablage um"
    st["token"] = "neu"
    service_link.save_state(st)
    assert token_store.get() == "neu" and "neu" not in p.read_text(encoding="utf-8")
    service_link.logout()
    assert token_store.get() is None


def test_windows_credential_store_is_only_used_on_windows():
    import sys
    from app import token_store
    src = open(token_store.__file__, encoding="utf-8").read()
    assert "CredWriteW" in src and "CredReadW" in src and "CredDeleteW" in src and "CRED_PERSIST_LOCAL_MACHINE" in src
    if sys.platform != "win32":
        assert isinstance(token_store.default_store(), token_store.FileStore)


# ================================================================ Zustand (reine Rechnung)

def _cache(plan, source=None, paid=None, ends_in_days=None, age_s=0, now=1_800_000_000, role="user"):
    import datetime as dt
    trial = {"granted": source == "trial", "active": source == "trial", "days_left": 0, "expired": False, "plan": "pro_ai"}
    if ends_in_days is not None:
        trial["ends_at"] = dt.datetime.fromtimestamp(now + ends_in_days * 86400, dt.timezone.utc).isoformat()
    return {"fetched_at": now - age_s, "user": {"role": role},
            "entitlements": {"plan": plan, "source": source, "paid_plan": paid or ("free" if source == "trial" else plan), "trial": trial}}


def test_evaluate_states_grace_and_clock():
    from app import account_mode as am
    now = 1_800_000_000
    assert am.evaluate(False, None, now, 7)["state"] == "signed_out"
    assert am.evaluate(True, None, now, 7)["state"] == "unverified"
    t = am.evaluate(True, _cache("pro_ai", "trial", ends_in_days=5), now, 7)
    assert (t["state"], t["locked"], t["plan"], t["trial_days_left"]) == ("trial", False, "pro_ai", 5)
    over = am.evaluate(True, _cache("pro_ai", "trial", ends_in_days=-0.5, age_s=86400), now, 7)
    assert over["state"] == "subscription_required" and over["locked"] and over["plan"] == "free", "Probe endet auch offline"
    assert am.evaluate(True, _cache("free"), now, 7)["state"] == "subscription_required"
    plus = am.evaluate(True, _cache("plus", "stripe", age_s=6 * 86400), now, 7)
    assert plus["state"] == "active" and plus["plan"] == "plus", "innerhalb der Kulanzzeit gilt der letzte Stand"
    old = am.evaluate(True, _cache("plus", "stripe", age_s=8 * 86400), now, 7)
    assert old["state"] == "unverified" and old["locked"] and "7 Tagen" in old["message"]
    assert am.evaluate(True, _cache("plus", "stripe", age_s=2 * 86400), now, 1)["state"] == "unverified", "Kulanzzeit einstellbar"
    back = am.evaluate(True, _cache("plus", "stripe", age_s=-3 * 86400), now, 7)
    assert back["state"] == "unverified", "Uhr zurueckgestellt: Stand gilt nicht"
    admin = am.evaluate(True, _cache("free", role="admin"), now, 7)
    assert not admin["locked"], "Betrieb und Moderation sind ausgenommen"


def test_grace_days_setting(monkeypatch):
    from app import account_mode as am
    monkeypatch.setenv("LERNAPP_OFFLINE_GRACE_DAYS", "3")
    assert am.grace_days() == 3
    monkeypatch.setenv("LERNAPP_OFFLINE_GRACE_DAYS", "999")
    assert am.grace_days() == 60
    monkeypatch.setenv("LERNAPP_OFFLINE_GRACE_DAYS", "nix")
    assert am.grace_days() == 7


def test_client_type_cannot_be_spoofed_into_more_rights():
    from app import access

    class R:
        def __init__(self, h):
            self.headers = {k.lower(): v for k, v in h.items()}
    assert access.client_type(R({})) == "web", "Cookie (Browser)"
    assert access.client_type(R({"Authorization": "Bearer x"})) == "app", "iPad/Android wie bisher"
    assert access.client_type(R({"Authorization": "Bearer x", "X-StudiNow-Client": "windows"})) == "windows"
    assert access.client_type(R({"Authorization": "Bearer x", "X-StudiNow-Client": "ipad"})) == "app"
    assert access.client_type(R({"Authorization": "Bearer x", "X-StudiNow-Client": "admin"})) == "app"
    free_app = access.evaluate("free", None, {}, "app")
    free_web = access.evaluate("free", None, {}, "web")
    assert (free_app["state"], free_app["locked"]) == ("free", False) and free_web["locked"]
    # der Tarif entscheidet die Rechte, nicht der Client: "app" bekommt fuer free genau die Free-Rechte
    for client in ("app", "web", "windows"):
        assert access.evaluate("plus", "paid", {}, client)["state"] == "active"


# ================================================================ Windows: Sperre je Zustand

def test_signed_out_shows_only_the_login(svc):
    app = svc.app
    st, d = _local(app, "GET", "/api/app-account/status")
    assert st == 200 and d["required"] and d["state"] == "signed_out" and d["service_url"] == SERVICE
    for method, path in (("GET", "/api/modules"), ("GET", "/api/settings"), ("PUT", "/api/settings"), ("POST", "/api/sync")):
        st, d = _local(app, method, path, {} if method != "GET" else None)
        assert (st, d["code"]) == (401, "account_required"), (method, path)
    assert asgi_call(app, "GET", "/")[0] == 200, "die Oberflaeche selbst laedt (zeigt den Anmeldebildschirm)"
    assert _local(app, "GET", "/api/desktop")[0] == 200 and _local(app, "GET", "/api/billing/plans")[0] == 200
    st, d = _local(app, "GET", "/api/entitlements")
    from app import plans
    assert st == 200 and d["mode"] == "account" and d["access"]["state"] == "signed_out" and d["access"]["locked"]
    assert d["entitlements"] == {**plans.entitlements("free"), "chatgpt_connection_premium": False}, "gesperrt: nur die Leserechte von Free"


def test_trial_then_expired_then_plus_then_pro_ai(svc):
    from app import accounts
    app = svc.app
    u, _ = _register(app, "probe@example.org")
    d = _login(app, "probe@example.org")
    assert d["state"] == "trial" and d["trial_days_left"] == 7 and d["plan"] == "pro_ai" and not d["locked"]
    assert d["token_store"] == "memory" and d["user"]["email"] == "probe@example.org"
    hdr = [h for m, p, h in svc.calls if p == "/api/entitlements"][0]
    assert hdr.get("X-StudiNow-Client") == "windows", "der Dienst erfaehrt den Client"
    st, e = _local(app, "GET", "/api/entitlements")
    assert e["access"]["state"] == "trial" and e["entitlements"]["can_annotate_pdf"] and e["entitlements"]["can_use_extended_test_history"]
    assert _local(app, "PUT", "/api/settings", {"user_name": "Lea"})[0] == 200, "in der Probe alles wie Pro AI"

    # Probe vorbei, kein Abo: nur lesen und exportieren
    _end_trial(u["id"])
    st, d = _local(app, "GET", "/api/app-account/status?refresh=1")
    assert d["state"] == "subscription_required" and d["locked"] and d["plan"] == "free"
    assert _local(app, "GET", "/api/settings")[0] == 200, "Lesen geht"
    st, err = _local(app, "PUT", "/api/settings", {"user_name": "X"})
    assert (st, err["code"]) == (402, "subscription_required") and "ansehen und exportieren" in err["detail"]
    st, err = _local(app, "POST", "/api/sync", {})
    assert st == 402
    st, e = _local(app, "GET", "/api/entitlements")
    assert e["access"]["locked"] and not e["entitlements"]["can_annotate_pdf"] and e["plan"] == "free"
    st, _, body = asgi_call(app, "GET", "/api/app-account/export")
    z = zipfile.ZipFile(io.BytesIO(body))
    assert st == 200 and "LIESMICH.txt" in z.namelist() and "daten/lernapp.db" in z.namelist()
    assert not any(n.endswith((".env", "service-account.json", "university-session.json")) for n in z.namelist())

    # Plus (Betrieb setzt den Tarif): wieder schreiben; Plus hat keine vollstaendige Testliste
    accounts.set_plan(u["id"], "plus")
    st, d = _local(app, "GET", "/api/app-account/status?refresh=1")
    assert d["state"] == "active" and d["plan"] == "plus"
    assert _local(app, "PUT", "/api/settings", {"user_name": "Lea"})[0] == 200
    st, e = _local(app, "GET", "/api/entitlements")
    assert e["entitlements"]["can_annotate_pdf"] and not e["entitlements"]["can_use_extended_test_history"]
    accounts.set_plan(u["id"], "pro_ai")
    st, d = _local(app, "GET", "/api/app-account/status?refresh=1")
    assert d["plan"] == "pro_ai"
    st, e = _local(app, "GET", "/api/entitlements")
    assert e["entitlements"]["can_use_extended_test_history"] and e["mode"] == "account"

    # abmelden: Token weg, wieder nur der Anmeldebildschirm; Daten bleiben
    st, d = _local(app, "POST", "/api/app-account/logout", {})
    assert d["state"] == "signed_out"
    assert _local(app, "GET", "/api/modules")[0] == 401


def test_offline_grace_and_revoked_session(svc, monkeypatch):
    from app import account_mode, accounts
    app = svc.app
    u, _ = _register(app, "offline@example.org")
    accounts.set_plan(u["id"], "plus")
    _login(app, "offline@example.org")
    svc.offline = True
    st, d = _local(app, "GET", "/api/app-account/status?refresh=1")
    assert d["state"] == "active" and d["offline"] and "nicht erreichbar" in d["last_error"]
    assert _local(app, "PUT", "/api/settings", {"user_name": "offline"})[0] == 200, "ohne Netz gilt der letzte Stand"
    c = json.loads(account_mode.cache_path().read_text(encoding="utf-8"))
    c["fetched_at"] = time.time() - 8 * 86400
    account_mode.cache_path().write_text(json.dumps(c), encoding="utf-8")
    st, d = _local(app, "GET", "/api/app-account/status")
    assert d["state"] == "unverified" and d["locked"]
    st, err = _local(app, "PUT", "/api/settings", {"user_name": "x"})
    assert (st, err["code"]) == (402, "subscription_unverified")
    svc.offline = False
    st, d = _local(app, "GET", "/api/app-account/status?refresh=1")
    assert d["state"] == "active", "wieder online: neu geprueft"
    # Sitzung im Dienst widerrufen (z. B. "Andere Geraete abmelden" am iPad): beim naechsten Abruf abgemeldet
    accounts.logout_all(u["id"])
    st, d = _local(app, "GET", "/api/app-account/status?refresh=1")
    assert d["state"] == "signed_out" and "abgelaufen" in d["last_error"]


def test_university_reset_also_signs_out_and_works_without_subscription(svc):
    app = svc.app
    u, _ = _register(app, "weitergeben@example.org")
    _login(app, "weitergeben@example.org")
    _end_trial(u["id"])
    _local(app, "GET", "/api/app-account/status?refresh=1")
    from app import reset
    out = reset.wipe(clear_webview=False)
    assert out["studinow_account"] is True
    assert _local(app, "GET", "/api/app-account/status")[1]["state"] == "signed_out"


# ================================================================ Anmeldung im Systembrowser (Loopback + PKCE)

def _browser_login(svc, email, tab="login", provider=None):
    app = svc.app
    body = {"mode": tab, **({"provider": provider} if provider else {})}
    st, d = _local(app, "POST", "/api/app-account/browser-login", body, host=LOCAL_HOST)
    assert st == 200, d
    assert svc.opened[-1] == d["url"], "Systembrowser, kein App-Fenster"
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(d["url"]).query))
    assert d["url"].startswith(SERVICE + "/login?") and q["app"] == "windows"
    assert q["redirect_uri"] == f"http://{LOCAL_HOST}/konto/rueckkehr" and len(q["code_challenge"]) == 43
    # die Anmeldeseite des Dienstes: anmelden, dann mit der Sitzung den Einmal-Code holen
    st, login = _hosted(app, "POST", "/api/account/login", {"email": email, "password": PW})
    assert st == 200
    h = {"Authorization": f"Bearer {login['token']}"}
    st, code = _hosted(app, "POST", "/api/app-login/code", {"redirect_uri": q["redirect_uri"], "state": q["state"], "code_challenge": q["code_challenge"]}, headers=h)
    assert st == 200, code
    back = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(code["redirect"]).query))
    assert code["redirect"].startswith(q["redirect_uri"] + "?") and back["state"] == q["state"]
    return q, back, h


def test_browser_login_with_pkce_and_loopback(svc):
    app = svc.app
    _register(app, "apple@example.org")
    q, back, h = _browser_login(svc, "apple@example.org", provider="apple")
    assert q["provider"] == "apple"
    st, _, page = asgi_call(app, "GET", f"/konto/rueckkehr?code={back['code']}&state={back['state']}", host=LOCAL_HOST)
    assert st == 200 and "angemeldet" in page.decode() and "apple@example.org" in page.decode()
    st, d = _local(app, "GET", "/api/app-account/status")
    assert d["state"] == "trial" and d["user"]["email"] == "apple@example.org"
    # dieselbe Rueckleitung noch einmal: abgelaufen (state gilt einmal)
    st, _, page = asgi_call(app, "GET", f"/konto/rueckkehr?code={back['code']}&state={back['state']}", host=LOCAL_HOST)
    assert st == 400 and "abgelaufen" in page.decode()
    # der Code gilt einmal, auch direkt beim Dienst
    st, e = _hosted(app, "POST", "/api/app-login/token", {"code": back["code"], "code_verifier": "x" * 43, "redirect_uri": q["redirect_uri"]})
    assert (st, e["code"]) == (400, "code_invalid")


def test_app_login_code_rules(svc):
    app = svc.app
    _register(app, "regeln@example.org")
    st, login = _hosted(app, "POST", "/api/account/login", {"email": "regeln@example.org", "password": PW})
    h = {"Authorization": f"Bearer {login['token']}"}
    ch = "A" * 43
    for bad in ("https://boese.example/konto/rueckkehr", "http://127.0.0.1.boese.example:80/konto/rueckkehr",
                "http://127.0.0.1:8765/anders", "http://192.168.0.5:8765/konto/rueckkehr", ""):
        st, e = _hosted(app, "POST", "/api/app-login/code", {"redirect_uri": bad, "state": "zustand-123", "code_challenge": ch}, headers=h)
        assert (st, e["code"]) == (400, "redirect_invalid"), bad
    assert _hosted(app, "POST", "/api/app-login/code", {"redirect_uri": "http://127.0.0.1:1/konto/rueckkehr", "state": "zustand-123", "code_challenge": ch})[0] == 401
    # falscher Verifier verbraucht den Code
    import base64
    import hashlib
    verifier = "v" * 60
    good = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    redirect = "http://127.0.0.1:5555/konto/rueckkehr"
    st, c = _hosted(app, "POST", "/api/app-login/code", {"redirect_uri": redirect, "state": "zustand-123", "code_challenge": good}, headers=h)
    code = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(c["redirect"]).query))["code"]
    assert _hosted(app, "POST", "/api/app-login/token", {"code": code, "code_verifier": "w" * 60, "redirect_uri": redirect})[1]["code"] == "code_invalid"
    assert _hosted(app, "POST", "/api/app-login/token", {"code": code, "code_verifier": verifier, "redirect_uri": redirect})[0] == 400, "verbraucht"
    # richtiger Verifier, aber andere Rueckleitung: nein; passend: eigene Sitzung des Geraets
    st, c = _hosted(app, "POST", "/api/app-login/code", {"redirect_uri": redirect, "state": "zustand-123", "code_challenge": good}, headers=h)
    code = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(c["redirect"]).query))["code"]
    st, t = _hosted(app, "POST", "/api/app-login/token", {"code": code, "code_verifier": verifier, "redirect_uri": redirect,
                                                          "device_id": "win-1", "device_name": "StudiNow für Windows"})
    assert st == 200 and t["token"] and t["token"] != login["token"] and t["user"]["email"] == "regeln@example.org"
    st, me = _hosted(app, "GET", "/api/account/me", headers={"Authorization": f"Bearer {t['token']}"})
    assert any(s["device_name"] == "StudiNow für Windows" and s["current"] for s in me["sessions"])
    # lokal: Rueckleitung nur fuer diesen PC
    assert _local(app, "POST", "/api/app-account/browser-login", {"mode": "login"}, host="studinow.example")[0] in (400, 421)


def test_login_page_keeps_the_browser_session_for_the_app_flow(svc):
    app = svc.app
    _, tok = _register(app, "seite@example.org")
    from app import config
    old = config.MODE
    config.MODE = "hosted"
    try:
        st, h, _ = asgi_call(app, "GET", "/login", cookies=f"uniflow_session={tok}")
        assert st == 302, "normale Anmeldeseite mit Sitzung: weiter zur App"
        st, h, _ = asgi_call(app, "GET", "/login?app=windows&redirect_uri=x", cookies=f"uniflow_session={tok}")
        assert st == 200, "fuer die Windows-App bleibt die Seite stehen (Nachfrage: Weiter / Anderes Konto)"
    finally:
        config.MODE = old
    js = (svc_root() / "app" / "static" / "login.js").read_text(encoding="utf-8")
    assert '"/api/app-login/code"' in js and "konto\\/rueckkehr" in js and "Anderes Konto" in js


def svc_root():
    from pathlib import Path
    return Path(__file__).resolve().parents[1]


# ================================================================ Kaufen und verwalten

@pytest.fixture
def stripe(monkeypatch):
    from app import stripe_billing as sb
    monkeypatch.setenv("LERNAPP_STRIPE_SECRET_KEY", "sk_test_x")
    monkeypatch.setenv("LERNAPP_STRIPE_PRICES", "plus=price_plus,pro_ai=price_ai")
    monkeypatch.setenv("LERNAPP_PUBLIC_URL", "https://app.studinow.example")
    calls = []

    def post(path, fields, idempotency_key=None):
        calls.append((path, fields))
        if path == "/customers":
            return {"id": "cus_1"}
        if path == "/checkout/sessions":
            return {"id": "cs_1", "url": "https://checkout.stripe.com/c/cs_1"}
        if path == "/billing_portal/sessions":
            return {"url": "https://billing.stripe.com/p/bps_1"}
        raise AssertionError(path)
    monkeypatch.setattr(sb, "http_post_form", post)
    return calls


def test_checkout_opens_the_system_browser_and_returns_to_a_plain_page(svc, stripe):
    app = svc.app
    u, _ = _register(app, "kauf@example.org")
    _login(app, "kauf@example.org")
    st, d = _local(app, "GET", "/api/billing/plans")
    assert d["purchase"]["web"]["available"] is True, "Kaufwege kommen aus dem Dienst (Stripe ist nur dort eingerichtet)"
    st, d = _local(app, "POST", "/api/app-account/checkout", {"plan": "plus"})
    assert st == 200 and d["url"] == "https://checkout.stripe.com/c/cs_1" and svc.opened[-1] == d["url"]
    sess = [f for p, f in stripe if p == "/checkout/sessions"][0]
    assert sess["success_url"] == "https://app.studinow.example/abo-fertig?checkout=success"
    assert sess["cancel_url"] == "https://app.studinow.example/abo-fertig?checkout=cancel"
    for bad in ("free", "gold", ""):
        assert _local(app, "POST", "/api/app-account/checkout", {"plan": bad})[1]["code"] == "plan_invalid"
    st, d = _local(app, "POST", "/api/app-account/portal", {})
    assert st == 200 and d["url"].startswith("https://billing.stripe.com/") and svc.opened[-1] == d["url"]
    assert [f for p, f in stripe if p == "/billing_portal/sessions"][0]["return_url"] == "https://app.studinow.example/abo-fertig?portal=1"
    from app import config
    old = config.MODE
    config.MODE = "hosted"
    try:
        st, _, page = asgi_call(app, "GET", "/abo-fertig?checkout=success")
        assert st == 200 and "zu StudiNow zurückkehren" in page.decode(), "ohne Anmeldung erreichbar"
    finally:
        config.MODE = old
    # waehrend gesperrt geht Kaufen weiter (sonst kaeme man nie heraus)
    _end_trial(u["id"])
    _local(app, "GET", "/api/app-account/status?refresh=1")
    assert _local(app, "POST", "/api/app-account/checkout", {"plan": "pro_ai"})[0] == 200


def test_apple_subscription_blocks_a_second_purchase_on_both_sides(svc, stripe):
    from app import billing
    app = svc.app
    u, tok = _register(app, "apple-abo@example.org")
    _end_trial(u["id"])
    conn = billing.connect()
    try:
        billing.set_entitlement(conn, u["id"], "app_store", "plus", original_transaction_id="2000001", expires_at="2099-01-01T00:00:00+00:00")
        conn.commit()
    finally:
        conn.close()
    d = _login(app, "apple-abo@example.org")
    assert d["state"] == "active" and d["plan"] == "plus" and d["apple_subscription"], "Apple-Abo vom iPad gilt automatisch"
    assert "über Apple" in d["purchase_note"]
    st, e = _local(app, "POST", "/api/app-account/checkout", {"plan": "pro_ai"})
    assert (st, e["code"]) == (409, "apple_subscription_active") and "iPads/iPhones" in e["detail"]
    assert not [p for p, f in stripe if p == "/checkout/sessions"]
    # auch direkt beim Dienst (Web oder ein veraenderter Client): kein zweites Abo
    for headers in ({"Authorization": f"Bearer {tok}"}, {"Authorization": f"Bearer {tok}", "X-StudiNow-Client": "windows"}):
        st, e = _hosted(app, "POST", "/api/billing/stripe/checkout", {"plan": "pro_ai"}, headers=headers)
        assert (st, e["code"]) == (409, "apple_subscription_active")
    st, e = _hosted(app, "POST", "/api/billing/stripe/checkout", {"plan": "pro_ai"}, cookies=f"uniflow_session={tok}")
    assert (st, e["code"]) == (409, "apple_subscription_active")
    st, pc = _hosted(app, "POST", "/api/billing/plan-choice", {"plan": "pro_ai"}, headers={"Authorization": f"Bearer {tok}"})
    assert st == 200 and pc["checkout_url"] is None and "Apple" in pc["checkout_error"]


def test_second_stripe_purchase_goes_to_the_portal(svc, stripe):
    from app import billing
    app = svc.app
    u, tok = _register(app, "stripe2@example.org")
    conn = billing.connect()
    try:
        billing.set_entitlement(conn, u["id"], "stripe", "plus", original_transaction_id="sub_9", expires_at="2099-01-01T00:00:00+00:00")
        conn.commit()
    finally:
        conn.close()
    st, e = _hosted(app, "POST", "/api/billing/stripe/checkout", {"plan": "pro_ai"}, headers={"Authorization": f"Bearer {tok}"})
    assert (st, e["code"]) == (409, "stripe_subscription_active") and "Abo verwalten" in e["detail"]


# ================================================================ Web (Dienst): dieselbe Regel, iPad unveraendert

def test_web_gate_with_cookie_after_the_trial(svc):
    app = svc.app
    u, tok = _register(app, "web@example.org")
    ck = f"uniflow_session={tok}"
    st, e = _hosted(app, "GET", "/api/entitlements", cookies=ck)
    assert e["access"] == {"client": "web", "account_required": True, "state": "trial", "locked": False, "read_only": False,
                           "trial_days_left": 7, "trial_ends_at": e["trial"]["ends_at"], "message": None}
    assert _hosted(app, "PUT", "/api/settings", {"user_name": "Web"}, cookies=ck)[0] == 200
    _end_trial(u["id"])
    st, e = _hosted(app, "GET", "/api/entitlements", cookies=ck)
    assert e["access"]["state"] == "subscription_required" and e["access"]["locked"] and e["plan"] == "free"
    st, err = _hosted(app, "PUT", "/api/settings", {"user_name": "X"}, cookies=ck)
    assert (st, err["code"]) == (402, "subscription_required")
    assert _hosted(app, "GET", "/api/settings", cookies=ck)[0] == 200, "lesen geht"
    st, _, body = asgi_call_hosted(app, "GET", "/api/account/export", cookies=ck)
    assert st == 200 and body[:2] == b"PK", "eigene Daten exportieren geht"
    assert _hosted(app, "POST", "/api/billing/plan-choice", {"plan": "free"}, cookies=ck)[0] == 200, "Abo-Seite bleibt bedienbar"
    # Windows-Client mit Bearer: dieselbe Regel
    st, err = _hosted(app, "PUT", "/api/settings", {"user_name": "X"}, headers={"Authorization": f"Bearer {tok}", "X-StudiNow-Client": "windows"})
    assert st == 402
    # Plus: wieder alles
    from app import accounts
    accounts.set_plan(u["id"], "plus")
    assert _hosted(app, "PUT", "/api/settings", {"user_name": "Plus"}, cookies=ck)[0] == 200
    assert _hosted(app, "POST", "/api/account/logout", {}, cookies=ck)[0] == 200


def asgi_call_hosted(app, method, path, **kw):
    from app import config
    old = config.MODE
    config.MODE = "hosted"
    try:
        return asgi_call(app, method, path, **kw)
    finally:
        config.MODE = old


def test_ipad_contract_unchanged_free_stays_free(svc):
    """iPad (Bearer ohne Client-Kopfzeile, oder eine gefaelschte "ipad"): nach der Probe Free mit genau den Free-Rechten,
    keine Sperre durch die Abo-Pflicht; Free-Grenzen (403 plan_required) wie bisher."""
    from app import plans
    app = svc.app
    u, tok = _register(app, "ipad@example.org")
    _end_trial(u["id"])
    for h in ({"Authorization": f"Bearer {tok}"}, {"Authorization": f"Bearer {tok}", "X-StudiNow-Client": "ipad"}):
        st, e = _hosted(app, "GET", "/api/entitlements", headers=h)
        assert st == 200 and e["plan"] == "free" and e["needs_plan_choice"] is True
        assert e["entitlements"] == {**plans.entitlements("free"), "chatgpt_connection_premium": False}, "genau Free, nie mehr"
        assert e["access"]["client"] == "app" and e["access"]["state"] == "free" and not e["access"]["locked"]
        for key in ("plan", "plan_name", "source", "expires_at", "will_renew", "pending_plan", "entitlements", "quotas",
                    "integrations", "mode", "trial", "plan_choice", "needs_plan_choice", "purchase", "apple_account_token", "credits"):
            assert key in e, key
        assert _hosted(app, "PUT", "/api/settings", {"user_name": "iPad"}, headers=h)[0] == 200, "Free schreibt wie bisher"
        st, err = _hosted(app, "POST", "/api/sync/push", {"items": [{"entity": "flashcards", "data": {"front": "a", "back": "b"}}], "deletes": []}, headers=h)
        assert st != 402 and (err or {}).get("code") != "subscription_required", "Free-Grenzen kommen weiter vom Tarif, nicht von der Abo-Pflicht"


def test_admin_is_exempt(svc):
    from app import accounts
    app = svc.app
    u, tok = _register(app, "betrieb@example.org")
    _end_trial(u["id"])
    accounts.set_role(u["id"], "admin")
    assert _hosted(app, "PUT", "/api/settings", {"user_name": "Admin"}, cookies=f"uniflow_session={tok}")[0] == 200


def test_ui_wires_the_gate():
    root = svc_root() / "app" / "static"
    app_js = (root / "app.js").read_text(encoding="utf-8")
    core = (root / "core.js").read_text(encoding="utf-8")
    abo = (root / "views-abo.js").read_text(encoding="utf-8")
    assert "account-gate.js?v=" in app_js and "mountLogin(document.body" in app_js and "renderGateBar()" in app_js
    assert "/api/app-account/status?refresh=1" in app_js and '"focus"' in app_js
    assert "!(state.hosted || state.gated)" in core and "state.appAccount" in core
    assert "/app-account/checkout" in abo and "/app-account/portal" in abo and "GATE_TEXTS.apple" in abo
    assert "id=\"aboBrowse\"" in abo and "exportHref(me)" in abo
