"""Audit Paket 25-27 (08.11.2026): app/account_api.py, app/account_mode_api.py, Middleware/Abo-Gate in app/server.py.
Bericht: docs/audit/AUDIT-2026-11-08-PAKET-25-27.md."""
import json

import pytest
from conftest import asgi_call

BAD_VALUES = [None, 0, 123, 1.5, True, [], ["x"], {}, {"a": 1}]


@pytest.fixture
def hosted(app, monkeypatch):
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")
    accounts.db_path().unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "identity_verifiers",
                        {"google": lambda t, nonce=None: {"subject": "g-1", "email": "g@beispiel.de", "email_verified": True}})
    monkeypatch.setattr(accounts, "reset_sender", None)
    monkeypatch.setattr(accounts, "verify_sender", None)
    monkeypatch.setattr(accounts, "LIMITS", {k: (10_000, v[1]) for k, v in accounts.LIMITS.items()})
    yield app
    accounts.db_path().unlink(missing_ok=True)


def _call(app, method, path, body=None, headers=None, raw=False):
    """500 auch dann, wenn die Ausnahme bis zum Aufrufer durchschlaegt (ServerErrorMiddleware wirft weiter)."""
    try:
        st, h, b = asgi_call(app, method, path, body=(body if raw else (json.dumps(body) if body is not None else None)),
                             headers=headers)
    except Exception as e:  # noqa: BLE001
        return 500, {"exception": f"{type(e).__name__}: {e}"}
    try:
        return st, json.loads(b) if b else None
    except ValueError:
        return st, b[:200]


def _register(app, email="p25@beispiel.de"):
    st, d = _call(app, "POST", "/api/account/register", {"email": email, "password": "sehr-geheim-123", "university": "luh"})
    assert st == 201, d
    return {"Authorization": f"Bearer {d['token']}"}


# ---------------------------------------------------------------- P25-06: falsche JSON-Typen -> nie 500

PUBLIC_FIELDS = [
    ("/api/account/register", {"email": "typ@beispiel.de", "password": "sehr-geheim-123", "university": "luh"},
     ["email", "password", "university", "device_id", "device_name"]),
    ("/api/account/login", {"email": "typ@beispiel.de", "password": "sehr-geheim-123"},
     ["email", "password", "device_id", "device_name"]),
    ("/api/account/login/google", {"id_token": "t", "university": "luh"},
     ["id_token", "identity_token", "nonce", "university", "email", "device_id", "device_name"]),
    ("/api/account/password/reset-request", {"email": "typ@beispiel.de"}, ["email"]),
    ("/api/account/password/reset", {"token": "x", "new_password": "ganz-neues-passwort"}, ["token", "new_password"]),
    ("/api/account/verify-email", {"token": "x"}, ["token"]),
]
AUTH_FIELDS = [
    ("/api/account/password", {"old_password": "sehr-geheim-123", "new_password": "ganz-neues-passwort"},
     ["old_password", "new_password"]),
    ("/api/account/university", {"university": "luh"}, ["university"]),
    ("/api/account/link/google", {"id_token": "t"}, ["id_token", "identity_token", "nonce"]),
    ("/api/account/delete", {"password": "falsch"}, ["password"]),
]


def _cases(table):
    for path, base, fields in table:
        for f in fields:
            for v in BAD_VALUES:
                yield pytest.param(path, {**base, f: v}, id=f"{path}:{f}={json.dumps(v)}")


@pytest.mark.parametrize("path,body", list(_cases(PUBLIC_FIELDS)))
def test_p25_06_public_account_endpoints_reject_wrong_types_without_500(hosted, path, body):
    st, d = _call(hosted, "POST", path, body)
    assert st < 500, (st, d)


@pytest.mark.parametrize("path,body", list(_cases(AUTH_FIELDS)))
def test_p25_06_signed_in_account_endpoints_reject_wrong_types_without_500(hosted, path, body):
    h = _register(hosted)
    st, d = _call(hosted, "POST", path, body, headers=h)
    assert st < 500, (st, d)


@pytest.mark.parametrize("path", [p for p, _, _ in PUBLIC_FIELDS + AUTH_FIELDS])
@pytest.mark.parametrize("raw", ["[]", "[\"x\"]", "\"text\"", "5", "null", "{kaputt"])
def test_p25_06_non_object_bodies_never_500(hosted, path, raw):
    h = _register(hosted, "roh@beispiel.de")
    st, d = _call(hosted, "POST", path, raw.encode(), headers=h, raw=True)
    assert st < 500, (st, d)


def test_p25_06_wrong_type_answer_is_400_invalid_input(hosted):
    st, d = _call(hosted, "POST", "/api/account/register", {"email": "x@beispiel.de", "password": "sehr-geheim-123", "university": 7})
    assert (st, d["code"]) == (400, "invalid_input")


# ---------------------------------------------------------------- P25-04: Konto steht, bevor die Mail rausgeht

@pytest.mark.parametrize("where", ["token", "mail"])
def test_p25_04_register_succeeds_when_the_welcome_mail_step_fails(hosted, monkeypatch, where):
    import sqlite3
    from app import accounts, mail
    original = accounts.request_email_verification

    def boom(*a, **k):
        raise sqlite3.OperationalError("database is locked") if where == "token" else RuntimeError("Warteschlange kaputt")
    if where == "token":
        monkeypatch.setattr(accounts, "request_email_verification", boom)
    else:
        monkeypatch.setattr(mail, "send_welcome", boom)
    st, d = _call(hosted, "POST", "/api/account/register",
                  {"email": "mailfehler@beispiel.de", "password": "sehr-geheim-123", "university": "luh"})
    assert st == 201 and d["token"], (st, d)           # vorher 500, obwohl Konto und Sitzung schon angelegt waren
    h = {"Authorization": f"Bearer {d['token']}"}
    st, d2 = _call(hosted, "GET", "/api/account/me", headers=h)
    assert st == 200 and d2["user"]["email_verified"] is False
    monkeypatch.setattr(accounts, "request_email_verification", original)
    sent = []
    monkeypatch.setattr(accounts, "verify_sender", lambda e, t: sent.append(e))
    st, _ = _call(hosted, "POST", "/api/account/verify-email/resend", headers=h)
    assert st == 200 and sent == ["mailfehler@beispiel.de"], "Bestaetigungslink laesst sich nachholen"


# ---------------------------------------------------------------- P25-02: CSRF auf Cookie-Sitzungen (Dienst)

def _cookie_of(app, email):
    st, h, b = asgi_call(app, "POST", "/api/account/register",
                         body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": "luh"}))
    assert st == 201
    raw = next(v.decode() for k, v in h if k == b"set-cookie" and v.startswith(b"uniflow_session="))
    return raw.split(";", 1)[0], raw


@pytest.mark.parametrize("origin", ["https://evil.example", "null", "https://evil.studinow.app", "http://test.evil"])
@pytest.mark.parametrize("method,path,body", [
    ("POST", "/api/account/logout-all", None), ("POST", "/api/account/password", {"old_password": "a", "new_password": "b"}),
    ("POST", "/api/account/university", {"university": "hildesheim"}), ("POST", "/api/account/delete", {"password": "x"}),
    ("DELETE", "/api/account/sessions/1", None), ("POST", "/api/app-login/code", {})])
def test_p25_02_cookie_session_writes_from_a_foreign_or_same_site_origin_are_403(hosted, origin, method, path, body):
    from app import accounts
    ck, _ = _cookie_of(hosted, "csrf25@beispiel.de")
    st, _, _ = asgi_call(hosted, method, path, cookies=ck, headers={"origin": origin},
                         body=json.dumps(body) if body is not None else None)
    assert st == 403
    u = accounts.authenticate(ck.split("=", 1)[1])
    assert u and u["university"] == "luh", "nichts geaendert, Sitzung lebt"


def test_p25_02_text_plain_form_post_without_origin_is_still_json_checked(hosted):
    """Kein Origin (sehr alte Browser, Skripte): Koerper muss JSON-Objekt sein; ein Formular (urlencoded) ergibt 422."""
    ck, _ = _cookie_of(hosted, "form25@beispiel.de")
    st, _, _ = asgi_call(hosted, "POST", "/api/account/university", cookies=ck, body="university=hildesheim",
                         content_type="application/x-www-form-urlencoded")
    assert st == 422


# ---------------------------------------------------------------- P25-03 / P25-05: Token im JSON, Cookie-Flags

def test_p25_03_web_login_page_never_keeps_the_token_from_json():
    from pathlib import Path
    js = (Path(__file__).resolve().parent.parent / "app" / "static" / "login.js").read_text(encoding="utf-8")
    assert "localStorage" not in js and "sessionStorage" not in js and "document.cookie" not in js
    assert ".token" not in js.replace("{ token", "").replace("token:", ""), "Antwort-Token wird nicht gelesen"


def test_p25_05_cookie_flags_with_https_switch(hosted, monkeypatch):
    monkeypatch.setenv("LERNAPP_HTTPS", "1")
    _, raw = _cookie_of(hosted, "flags@beispiel.de")
    low = raw.lower()
    assert "httponly" in low and "samesite=lax" in low and "secure" in low and "path=/" in low
    monkeypatch.delenv("LERNAPP_HTTPS")
    _, raw = _cookie_of(hosted, "flags2@beispiel.de")
    assert "secure" not in raw.lower(), "ohne Schalter kein Secure (http-Tests, Entwicklung)"


# ---------------------------------------------------------------- P25-07: Pruefer nicht erreichbar -> 503, nicht 500

def test_p25_07_provider_key_download_failure_is_503_without_internal_details(hosted, monkeypatch):
    import base64
    from app import social_login
    monkeypatch.setenv("LERNAPP_GOOGLE_CLIENT_IDS", "cid.apps.googleusercontent.com")
    social_login.clear_cache()

    def offline(url):
        raise OSError(f"Netz weg beim Laden von {url}")
    monkeypatch.setattr(social_login, "fetch_jwks", offline)
    enc = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")   # noqa: E731
    tok = f"{enc({'alg': 'RS256', 'kid': 'k1'})}.{enc({'sub': 'x'})}.AAAA"
    st, d = _call(hosted, "POST", "/api/account/login/google", {"id_token": tok, "university": "luh"})
    assert (st, d.get("code")) == (503, "provider_unavailable"), d
    assert "http" not in d["detail"] and "googleapis" not in d["detail"]
    social_login.clear_cache()


def test_p25_07_token_error_texts_are_our_own_wording(hosted, monkeypatch):
    from app import social_login
    monkeypatch.setenv("LERNAPP_GOOGLE_CLIENT_IDS", "cid.apps.googleusercontent.com")
    st, d = _call(hosted, "POST", "/api/account/login/google", {"id_token": "kein.jwt", "university": "luh"})
    assert (st, d["code"]) == (401, "token_invalid") and "Traceback" not in d["detail"]


# ---------------------------------------------------------------- P25-10 / P25-11 / P25-12 / P26-10

def test_p25_10_failed_export_counts_against_the_daily_limit(hosted, monkeypatch):
    """Festgenagelt (Abwaegung Missbrauchsschutz): das Kontingent zaehlt vor dem Bau, auch wenn er scheitert."""
    from app import account_export, accounts
    h = _register(hosted, "export25@beispiel.de")
    accounts.LIMITS["export_user"] = (1, 1440)
    real = account_export.build
    monkeypatch.setattr(account_export, "build", lambda u: (_ for _ in ()).throw(OSError("Platte voll")))
    assert _call(hosted, "GET", "/api/account/export", headers=h)[0] == 500
    monkeypatch.setattr(account_export, "build", real)
    st, d = _call(hosted, "GET", "/api/account/export", headers=h)
    assert (st, d["code"]) == (429, "rate_limited")


def test_p25_11_revoked_device_is_locked_out_and_double_revoke_is_404(hosted):
    a = _register(hosted, "geraet@beispiel.de")
    st, d = _call(hosted, "POST", "/api/account/login", {"email": "geraet@beispiel.de", "password": "sehr-geheim-123",
                                                          "device_name": "iPad"})
    b = {"Authorization": f"Bearer {d['token']}"}
    sessions = _call(hosted, "GET", "/api/account/me", headers=a)[1]["sessions"]
    other = next(s["id"] for s in sessions if not s["current"])
    st, r = _call(hosted, "DELETE", f"/api/account/sessions/{other}", headers=a)
    assert st == 200 and r["current"] is False
    assert _call(hosted, "GET", "/api/account/me", headers=b)[0] == 401, "widerrufenes Geraet sofort draussen"
    assert _call(hosted, "DELETE", f"/api/account/sessions/{other}", headers=a)[0] == 404
    # fremdes Konto kann die Sitzung eines anderen nicht widerrufen
    c = _register(hosted, "fremd25@beispiel.de")
    mine = next(s["id"] for s in _call(hosted, "GET", "/api/account/me", headers=a)[1]["sessions"] if s["current"])
    assert _call(hosted, "DELETE", f"/api/account/sessions/{mine}", headers=c)[0] == 404
    assert _call(hosted, "GET", "/api/account/me", headers=a)[0] == 200


def test_p25_11_revoking_the_own_cookie_session_clears_the_cookie(hosted):
    ck, _ = _cookie_of(hosted, "selbst@beispiel.de")
    st, _, b = asgi_call(hosted, "GET", "/api/account/me", cookies=ck)
    mine = next(s["id"] for s in json.loads(b)["sessions"] if s["current"])
    st, h, b = asgi_call(hosted, "DELETE", f"/api/account/sessions/{mine}", cookies=ck)
    assert st == 200 and json.loads(b)["current"] is True
    assert any(k == b"set-cookie" and b"uniflow_session=" in v and b"Max-Age=0" in v for k, v in h)
    assert asgi_call(hosted, "GET", "/api/account/me", cookies=ck)[0] == 401


def test_p25_12_university_switch_keeps_each_universitys_data_apart(hosted):
    from app import accounts, config
    h = _register(hosted, "wechsel@beispiel.de")
    uid = _call(hosted, "GET", "/api/account/me", headers=h)[1]["user"]["id"]
    luh = config.user_data_dir(uid, "luh")
    (luh / "marker.txt").parent.mkdir(parents=True, exist_ok=True)
    (luh / "marker.txt").write_text("luh")
    assert _call(hosted, "POST", "/api/account/university", {"university": "hildesheim"}, headers=h)[0] == 200
    hil = config.user_data_dir(uid, "hildesheim")
    assert hil != luh and not (hil / "marker.txt").exists()
    assert accounts.authenticate(h["Authorization"][7:])["university"] == "hildesheim", "naechste Anfrage im neuen Ordner"
    assert _call(hosted, "POST", "/api/account/university", {"university": "luh"}, headers=h)[0] == 200
    assert (luh / "marker.txt").read_text() == "luh", "zurueck: Daten der LUH unveraendert da"


def test_p26_10_deleted_account_token_is_dead_everywhere(hosted):
    h = _register(hosted, "weg@beispiel.de")
    assert _call(hosted, "POST", "/api/account/delete", {"password": "sehr-geheim-123"}, headers=h)[0] == 200
    for method, path in (("GET", "/api/account/me"), ("GET", "/api/entitlements"), ("GET", "/api/files"),
                         ("POST", "/api/account/university"), ("GET", "/api/account/export")):
        assert _call(hosted, method, path, {"university": "luh"} if method == "POST" else None, headers=h)[0] == 401, path


# ---------------------------------------------------------------- P26-04: App-Login-Code genau einmal (Dienst)

def test_p26_04_parallel_redemption_of_one_code_yields_exactly_one_session(hosted, monkeypatch):
    import base64
    import hashlib
    import threading
    from contextlib import contextmanager
    from app import accounts, app_login_api
    _register(hosted, "pkce@beispiel.de")
    with accounts.cursor() as conn:
        uid = conn.execute("SELECT id FROM users WHERE email='pkce@beispiel.de'").fetchone()[0]
        conn.execute(app_login_api.SCHEMA)
    verifier = "v" * 43
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    code, redirect = "einmal-code-123", "http://127.0.0.1:8765/konto/rueckkehr"
    t = accounts.now()
    with accounts.cursor() as conn:
        conn.execute("INSERT INTO app_login_codes(code_hash, user_id, challenge, redirect_uri, client, created_at, expires_at) "
                     "VALUES (?,?,?,?,?,?,?)", (app_login_api._hash(code), uid, challenge, redirect, "windows",
                                                accounts.iso(t), accounts.iso(t + __import__("datetime").timedelta(seconds=120))))
    barrier = threading.Barrier(2, timeout=5)
    real = accounts.cursor

    class _Row:
        def __init__(self, row):
            self.row = row

        def fetchone(self):
            return self.row

    class _Proxy:
        def __init__(self, conn):
            self._c = conn

        def execute(self, sql, *a):
            cur = self._c.execute(sql, *a)
            if sql.startswith("SELECT * FROM app_login_codes"):
                row = cur.fetchone()
                try:
                    barrier.wait()                       # beide haben den unverbrauchten Code gelesen
                except threading.BrokenBarrierError:
                    pass
                return _Row(row)
            return cur

        def __getattr__(self, name):
            return getattr(self._c, name)

    @contextmanager
    def slow_cursor():
        with real() as conn:
            yield _Proxy(conn)
    monkeypatch.setattr(accounts, "cursor", slow_cursor)
    results = []

    def redeem():
        try:
            results.append(("ok", app_login_api.exchange(None, {"code": code, "code_verifier": verifier, "redirect_uri": redirect})))
        except Exception as e:  # noqa: BLE001
            results.append(("err", getattr(e, "status_code", type(e).__name__)))
    threads = [threading.Thread(target=redeem) for _ in range(2)]
    [x.start() for x in threads]
    [x.join(10) for x in threads]
    monkeypatch.setattr(accounts, "cursor", real)
    assert sorted(r[0] for r in results) == ["err", "ok"], results
    assert [r[1] for r in results if r[0] == "err"] == [400]
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM sessions WHERE user_id=? AND device_name='StudiNow für Windows'",
                            (uid,)).fetchone()[0] == 1


@pytest.mark.parametrize("uri,ok", [
    ("http://127.0.0.1:8765/konto/rueckkehr", True), ("http://localhost:1/konto/rueckkehr", True),
    ("http://[::1]:65535/konto/rueckkehr", True), ("http://127.0.0.1:0/konto/rueckkehr", False),
    ("http://127.0.0.1:65536/konto/rueckkehr", False), ("http://127.0.0.1/konto/rueckkehr", False),
    ("https://127.0.0.1:8765/konto/rueckkehr", False), ("http://127.0.0.1:8765/konto/rueckkehr?x=1", False),
    ("http://127.0.0.1:8765/konto/rueckkehr#f", False), ("http://127.1:8765/konto/rueckkehr", False),
    ("http://2130706433:8765/konto/rueckkehr", False), ("http://127.0.0.1.evil.example:8765/konto/rueckkehr", False),
    ("http://127.0.0.1:8765@evil.example/konto/rueckkehr", False), ("http://lоcalhost:8765/konto/rueckkehr", False),
    ("http://127.0.0.1:8765/konto/rueckkehr\n", False), ("", False)])
def test_p26_11_valid_redirect_matrix(uri, ok):
    from app import app_login_api
    assert app_login_api.valid_redirect(uri) is ok


# ---------------------------------------------------------------- P26-01/02, P27-01: Endpunkte am PC

def test_p26_01_pc_export_refuses_a_foreign_site_but_serves_the_own_window(app):
    for fremd in ({"sec-fetch-site": "cross-site"}, {"sec-fetch-site": "same-site"}, {"origin": "https://evil.example"},
                  {"referer": "https://evil.example/x"}):
        st, _, b = asgi_call(app, "GET", "/api/app-account/export", headers=fremd)
        assert st == 403 and json.loads(b)["code"] == "cross_site", fremd
    for eigen in ({}, {"sec-fetch-site": "same-origin", "referer": "http://test/"}, {"sec-fetch-site": "none"}):
        st, _, b = asgi_call(app, "GET", "/api/app-account/export", headers=eigen)
        assert st == 200 and b[:2] == b"PK", eigen


def test_p26_01_pc_export_from_the_lan_needs_the_pin(app):
    st, _, _ = asgi_call(app, "GET", "/api/app-account/export", client=("192.168.178.50", 1))
    assert st == 401
    st, _, _ = asgi_call(app, "GET", "/api/app-account/export", client=("203.0.113.5", 1))
    assert st == 403


@pytest.mark.parametrize("path,body", [("/api/app-account/login", {"email": "a@b.de", "password": "x"}),
                                       ("/api/app-account/logout", None)])
def test_p26_02_pc_login_logout_from_a_foreign_origin_are_403(app, path, body):
    st, _, _ = asgi_call(app, "POST", path, headers={"origin": "https://evil.example"},
                         body=json.dumps(body) if body is not None else None)
    assert st == 403


# ---------------------------------------------------------------- P27-02 / P27-03: Client-Typ, Ausnahmen der Sperre

def test_p27_02_client_type_rules_are_as_documented():
    from types import SimpleNamespace as NS
    from app import access
    assert access.client_type(NS(headers={})) == "web"
    assert access.client_type(NS(headers={"authorization": "Bearer x"})) == "app"
    assert access.client_type(NS(headers={"authorization": "Bearer x", "x-studinow-client": "ipad"})) == "app"
    assert access.client_type(NS(headers={"authorization": "Bearer x", "x-studinow-client": "Windows "})) == "windows"
    assert access.client_type(NS(headers={"authorization": "Basic x", "x-studinow-client": "app"})) == "web"


LOCKED_WRITE_ROUTES = {
    "POST /api/account/register", "POST /api/account/login", "POST /api/account/login/{provider}",
    "POST /api/account/link/{provider}", "DELETE /api/account/identities/{provider}",
    "DELETE /api/account/sessions/{session_id}", "POST /api/account/logout", "POST /api/account/logout-all",
    "POST /api/account/password", "POST /api/account/password/reset-request", "POST /api/account/verify-email",
    "POST /api/account/verify-email/resend", "POST /api/account/password/reset", "POST /api/account/university",
    "POST /api/account/delete", "POST /api/billing/apple/verify", "POST /api/billing/stripe/checkout",
    "POST /api/billing/stripe/portal", "POST /api/billing/stripe/webhook", "POST /api/billing/plan-choice",
    "POST /api/billing/apple/notifications", "POST /api/billing/offer-codes", "POST /api/app-account/login",
    "POST /api/app-account/browser-login", "POST /api/app-account/logout", "POST /api/app-account/checkout",
    "POST /api/app-account/portal", "POST /api/app-login/code", "POST /api/app-login/token", "POST /api/studora/logout",
    "POST /api/university/reset", "POST /api/desktop/open", "POST /api/desktop/windows/{window_id}/state"}


def test_p27_03_every_write_route_that_passes_the_lock_is_reviewed(app):
    """Neue schreibende Route unter /api/account/, /api/billing/, /api/app-login/ (bzw. den PC-Extras) geht ohne Abo
    durch: hier eintragen heisst, die Abo-Regel bewusst geprueft zu haben."""
    from app import access, account_mode

    def walk(routes):
        for r in routes:
            yield from walk(r.original_router.routes) if hasattr(r, "original_router") else [r]
    found = set()
    for r in walk(app.routes):
        p = getattr(r, "path", "")
        for m in getattr(r, "methods", None) or ():
            if m not in ("GET", "HEAD", "OPTIONS") and access.write_allowed_when_locked(m, p, account_mode.LOCKED_WRITE_EXTRA):
                found.add(f"{m} {p}")
    assert found == LOCKED_WRITE_ROUTES


# ---------------------------------------------------------------- P27-07: PIN-Fehlversuche begrenzt im Speicher (PC)

def test_p27_07_pin_fail_table_stays_bounded_and_counts_only_wrong_pins(app, monkeypatch):
    from app import server
    server._PIN_FAILS.clear()
    for i in range(30):                                      # ohne PIN: nur PIN-Seite, kein Eintrag
        asgi_call(app, "GET", "/api/files", client=(f"fd00::{i:x}", 1))
    assert len(server._PIN_FAILS) == 0
    monkeypatch.setattr(server, "PIN_FAILS_MAX", 50)
    for i in range(200):                                     # rotierende IPv6-Adressen mit falscher PIN
        asgi_call(app, "GET", "/api/files?pin=000000", client=(f"fd00::1:{i:x}", 1))
    assert len(server._PIN_FAILS) <= 50
    # Sperre je Adresse unveraendert: 8 falsche PINs, dann 429 auch mit der richtigen
    server._PIN_FAILS.clear()
    host = ("192.168.178.77", 1)
    for _ in range(8):
        assert asgi_call(app, "GET", "/api/files?pin=000001", client=host)[0] == 401
    assert asgi_call(app, "GET", f"/api/files?pin={server._lan_pin()}", client=host)[0] == 429
    server._PIN_FAILS.clear()
