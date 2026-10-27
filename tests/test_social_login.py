"""„Mit Google/Apple anmelden“ (app/social_login.py, Konto-Endpunkte): ID-Tokens werden gegen die JWKS des Anbieters
geprueft (RS256 und ES256, iss, aud, exp, nonce); gueltig -> Sitzung, sonst 401; ohne Client-ID 501; dieselbe Kennung
fuehrt immer zum selben Konto; eine bestaetigte E-Mail verknuepft ein bestehendes Konto; Loeschen entfernt die
Verknuepfung. JWKS-Abruf und Uhr sind ausgetauscht, es geht nichts ins Netz."""
import base64
import hashlib
import json
import time

import pytest
from conftest import asgi_call
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

GOOGLE_ID = "123-android.apps.googleusercontent.com"
GOOGLE_WEB = "123-web.apps.googleusercontent.com"
APPLE_ID = "de.beispiel.uniflow"


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def _uint(n: int, size: int | None = None) -> str:
    return _b64(n.to_bytes(size or (n.bit_length() + 7) // 8, "big"))


class Keys:
    """Ein RSA- und ein EC-Schluesselpaar wie bei Google/Apple, plus die passende JWKS."""

    def __init__(self):
        self.rsa = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.ec = ec.generate_private_key(ec.SECP256R1())
        self.other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        pn = self.rsa.public_key().public_numbers()
        en = self.ec.public_key().public_numbers()
        self.jwks = {"keys": [{"kty": "RSA", "kid": "rsa-1", "use": "sig", "alg": "RS256", "n": _uint(pn.n), "e": _uint(pn.e)},
                              {"kty": "EC", "kid": "ec-1", "use": "sig", "alg": "ES256", "crv": "P-256", "x": _uint(en.x, 32), "y": _uint(en.y, 32)}]}
        self.fetches = 0

    def token(self, claims: dict, alg="RS256", kid="rsa-1", key=None) -> str:
        header = {"alg": alg, "kid": kid, "typ": "JWT"}
        signing = f"{_b64(json.dumps(header).encode())}.{_b64(json.dumps(claims).encode())}"
        if alg == "RS256":
            sig = (key or self.rsa).sign(signing.encode(), padding.PKCS1v15(), hashes.SHA256())
        else:
            r, s = decode_dss_signature((key or self.ec).sign(signing.encode(), ec.ECDSA(hashes.SHA256())))
            sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        return f"{signing}.{_b64(sig)}"


def google_claims(sub="g-1", email="erika@beispiel.de", verified=True, aud=GOOGLE_ID, **extra) -> dict:
    now = int(time.time())
    c = {"iss": "https://accounts.google.com", "aud": aud, "sub": sub, "iat": now - 10, "exp": now + 600}
    if email:
        c["email"], c["email_verified"] = email, verified
    c.update(extra)
    return c


def apple_claims(sub="apple-1", email="relay@privaterelay.appleid.com", **extra) -> dict:
    now = int(time.time())
    c = {"iss": "https://appleid.apple.com", "aud": APPLE_ID, "sub": sub, "iat": now - 10, "exp": now + 600,
         "email": email, "email_verified": "true", "is_private_email": "true"}
    c.update(extra)
    return c


@pytest.fixture
def keys(monkeypatch):
    from app import social_login
    k = Keys()

    def fetch(url):
        k.fetches += 1
        return k.jwks
    monkeypatch.setattr(social_login, "fetch_jwks", fetch)
    social_login.clear_cache()
    yield k
    social_login.clear_cache()


@pytest.fixture
def hosted(app, monkeypatch, keys, tmp_path):
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    monkeypatch.setenv("LERNAPP_MAIL", "off")
    monkeypatch.setattr(config, "LOG_DIR", tmp_path)
    monkeypatch.setenv("LERNAPP_GOOGLE_CLIENT_IDS", f"{GOOGLE_ID}, ios-client-id")
    monkeypatch.setenv("LERNAPP_GOOGLE_WEB_CLIENT_ID", GOOGLE_WEB)
    monkeypatch.setenv("LERNAPP_APPLE_CLIENT_IDS", APPLE_ID)
    for suffix in ("", "-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "identity_verifiers", {})
    monkeypatch.setattr(accounts, "reset_sender", None)
    yield app
    accounts.db_path().unlink(missing_ok=True)


def _j(res):
    st, h, b = res
    return st, (json.loads(b) if b else None), h


def _login(app, provider, body):
    return _j(asgi_call(app, "POST", f"/api/account/login/{provider}", body=json.dumps(body)))


# ---------------------------------------------------------------- Pruefung ohne Server

def test_verify_accepts_rs256_and_es256_and_caches_jwks(keys, monkeypatch):
    from app import social_login
    monkeypatch.setenv("LERNAPP_GOOGLE_CLIENT_IDS", GOOGLE_ID)
    monkeypatch.setenv("LERNAPP_APPLE_CLIENT_IDS", APPLE_ID)
    out = social_login.verify("google", keys.token(google_claims()))
    assert out == {"provider": "google", "subject": "g-1", "email": "erika@beispiel.de", "email_verified": True}
    out = social_login.verify("apple", keys.token(apple_claims(), alg="ES256", kid="ec-1"))
    assert out["subject"] == "apple-1" and out["email_verified"] is True and out["email"] == "relay@privaterelay.appleid.com"
    assert keys.fetches == 2, "je Anbieter einmal geladen"
    social_login.verify("google", keys.token(google_claims(sub="g-2")))
    assert keys.fetches == 2, "zweiter Aufruf aus dem Cache"
    # Google: iss ohne Schema ist ebenso erlaubt; aud als Liste; email_verified fehlt -> False
    c = google_claims(verified=False); c["iss"] = "accounts.google.com"; c["aud"] = ["fremd", GOOGLE_ID]
    assert social_login.verify("google", keys.token(c))["email_verified"] is False
    assert social_login.verify("google", keys.token(google_claims(email=None)))["email"] is None
    # unbekannte kid: Schluessel werden einmal frisch geladen, dann Fehler
    with pytest.raises(social_login.TokenError, match="nicht bekannt"):
        social_login.verify("google", keys.token(google_claims(), kid="rsa-9"))
    assert keys.fetches == 3


@pytest.mark.parametrize("case", ["expired", "aud", "iss", "signature", "alg_none", "garbage", "nonce", "no_sub", "ec_with_rsa_key", "future"])
def test_verify_rejects_bad_tokens(keys, monkeypatch, case):
    from app import social_login
    monkeypatch.setenv("LERNAPP_GOOGLE_CLIENT_IDS", GOOGLE_ID)
    monkeypatch.setenv("LERNAPP_APPLE_CLIENT_IDS", APPLE_ID)
    provider, nonce = "google", None
    if case == "expired":
        tok = keys.token(google_claims(exp=int(time.time()) - 120))
    elif case == "future":
        tok = keys.token(google_claims(iat=int(time.time()) + 600, nbf=int(time.time()) + 600))
    elif case == "aud":
        tok = keys.token(google_claims(aud="andere-app"))
    elif case == "iss":
        tok = keys.token(google_claims(iss="https://evil.example"))
    elif case == "signature":
        tok = keys.token(google_claims(), key=keys.other)
    elif case == "alg_none":
        signing = f"{_b64(json.dumps({'alg': 'none', 'kid': 'rsa-1'}).encode())}.{_b64(json.dumps(google_claims()).encode())}"
        tok = signing + "."
    elif case == "garbage":
        tok = "kein.jwt"
    elif case == "nonce":
        provider, nonce = "apple", "n-123"
        tok = keys.token(apple_claims(nonce="falsch"), alg="ES256", kid="ec-1")
    elif case == "no_sub":
        c = google_claims(); del c["sub"]; tok = keys.token(c)
    else:
        tok = keys.token(google_claims(), alg="ES256", kid="rsa-1")
    with pytest.raises(social_login.TokenError):
        social_login.verify(provider, tok, nonce)


def test_apple_nonce_plain_or_sha256(keys, monkeypatch):
    from app import social_login
    monkeypatch.setenv("LERNAPP_APPLE_CLIENT_IDS", APPLE_ID)
    assert social_login.verify("apple", keys.token(apple_claims(nonce="n-1")), "n-1")["subject"] == "apple-1"
    hashed = hashlib.sha256(b"n-1").hexdigest()
    assert social_login.verify("apple", keys.token(apple_claims(nonce=hashed)), "n-1")["subject"] == "apple-1", "iOS-SDK: SHA-256 der Nonce im Token"
    assert social_login.verify("apple", keys.token(apple_claims()), None)["subject"] == "apple-1", "ohne Nonce vom Client keine Pruefung"


def test_not_configured_without_client_ids(keys, monkeypatch):
    from app import social_login
    for k in ("LERNAPP_GOOGLE_CLIENT_IDS", "LERNAPP_GOOGLE_WEB_CLIENT_ID", "LERNAPP_APPLE_CLIENT_IDS", "LERNAPP_APPLE_WEB_CLIENT_ID"):
        monkeypatch.delenv(k, raising=False)
    assert not social_login.configured("google") and not social_login.configured("apple")
    assert social_login.status() == {"google": False, "google_web_client_id": None, "apple": False, "apple_web_client_id": None}
    monkeypatch.setenv("LERNAPP_GOOGLE_WEB_CLIENT_ID", GOOGLE_WEB)
    assert social_login.client_ids("google") == [GOOGLE_WEB], "die Web-Client-ID zaehlt automatisch als erlaubt"
    assert social_login.status()["google"] is True
    with pytest.raises(social_login.TokenError):
        social_login.verify("apple", keys.token(apple_claims()))


# ---------------------------------------------------------------- Endpunkte

def test_login_google_creates_account_and_second_login_reuses_it(hosted, keys):
    from app import accounts
    st, d, _ = _j(asgi_call(hosted, "GET", "/api/account/providers"))
    assert st == 200 and d == {"google": True, "google_web_client_id": GOOGLE_WEB, "apple": True, "apple_web_client_id": None}
    assert _j(asgi_call(hosted, "GET", "/api/account/info"))[1]["providers"] == ["apple", "google"]
    st, d, h = _login(hosted, "google", {"id_token": keys.token(google_claims()), "university": "hildesheim", "device_name": "Pixel"})
    assert st == 201 and d["created"] is True and d["user"]["email"] == "erika@beispiel.de" and d["user"]["email_verified"] is True
    assert d["user"]["university"] == "hildesheim" and d["token"]
    cookie = [v.decode() for k, v in h if k == b"set-cookie"][0]
    assert cookie.startswith("uniflow_session=") and "httponly" in cookie.lower(), "Web-Sitzung wie beim Passwort-Login"
    me = _j(asgi_call(hosted, "GET", "/api/account/me", headers={"Authorization": f"Bearer {d['token']}"}))[1]
    assert me["user"]["id"] == d["user"]["id"] and me["sessions"][0]["device_name"] == "Pixel"
    # zweiter Login derselben subject (anderer Client, Web-Client-ID als aud): dasselbe Konto, keine Hochschule noetig
    st, d2, _ = _login(hosted, "google", {"id_token": keys.token(google_claims(aud=GOOGLE_WEB))})
    assert st == 200 and d2["created"] is False and d2["user"]["id"] == d["user"]["id"]
    # Passwort-Login ist gesperrt, bis per Reset eines gesetzt wird
    st, e, _ = _j(asgi_call(hosted, "POST", "/api/account/login", body=json.dumps({"email": "erika@beispiel.de", "password": "irgendwas-123"})))
    assert (st, e["code"]) == (401, "credentials_invalid")
    sent = {}
    accounts.reset_sender = lambda email, token: sent.update(token=token)
    asgi_call(hosted, "POST", "/api/account/password/reset-request", body=json.dumps({"email": "erika@beispiel.de"}))
    assert asgi_call(hosted, "POST", "/api/account/password/reset", body=json.dumps({"token": sent["token"], "new_password": "jetzt-mit-passwort-1"}))[0] == 200
    assert _j(asgi_call(hosted, "POST", "/api/account/login", body=json.dumps({"email": "erika@beispiel.de", "password": "jetzt-mit-passwort-1"})))[0] == 200


def test_login_rejects_bad_tokens_with_401_and_unconfigured_with_501(hosted, keys, monkeypatch):
    for body in ({"id_token": keys.token(google_claims(exp=int(time.time()) - 120))},
                 {"id_token": keys.token(google_claims(aud="andere-app"))},
                 {"id_token": keys.token(google_claims(), key=keys.other)},
                 {"id_token": "kaputt"}, {}):
        st, d, h = _login(hosted, "google", body)
        assert (st, d["code"]) == (401, "token_invalid"), body
        assert not [1 for k, _ in h if k == b"set-cookie"]
    st, d, _ = _login(hosted, "apple", {"id_token": keys.token(apple_claims(nonce="x"), alg="ES256", kid="ec-1"), "nonce": "y"})
    assert (st, d["code"]) == (401, "token_invalid")
    assert _login(hosted, "github", {"id_token": "x"})[0] == 401, "kein oeffentlicher Pfad: die Sitzungspruefung greift zuerst"
    monkeypatch.delenv("LERNAPP_APPLE_CLIENT_IDS")
    st, d, _ = _login(hosted, "apple", {"id_token": keys.token(apple_claims())})
    assert (st, d["code"]) == (501, "provider_not_configured")
    assert _j(asgi_call(hosted, "GET", "/api/account/providers"))[1]["apple"] is False
    assert _j(asgi_call(hosted, "GET", "/api/account/info"))[1]["providers"] == ["google"]
    # Neues Konto ohne Hochschule bzw. ohne E-Mail
    st, d, _ = _login(hosted, "google", {"id_token": keys.token(google_claims(sub="g-neu"))})
    assert (st, d["code"]) == (400, "university_unknown")
    st, d, _ = _login(hosted, "google", {"id_token": keys.token(google_claims(sub="g-neu", email=None)), "university": "luh"})
    assert (st, d["code"]) == (400, "email_required")
    st, d, _ = _login(hosted, "google", {"id_token": keys.token(google_claims(sub="g-neu", email=None)), "university": "luh", "email": "vom-client@beispiel.de"})
    assert st == 201 and d["user"]["email"] == "vom-client@beispiel.de" and d["user"]["email_verified"] is False, "Adresse vom Client: unbestaetigt"


def test_verified_email_links_existing_account_and_delete_removes_link(hosted, keys):
    from app import accounts
    st, reg, _ = _j(asgi_call(hosted, "POST", "/api/account/register",
                              body=json.dumps({"email": "erika@beispiel.de", "password": "sehr-geheim-123", "university": "luh"})))
    assert st == 201
    # bestaetigte E-Mail des Anbieters = bestehendes Konto -> verknuepfen, kein neues Konto
    st, d, _ = _login(hosted, "apple", {"id_token": keys.token(apple_claims(email="Erika@Beispiel.de"), alg="ES256", kid="ec-1")})
    assert st == 200 and d["created"] is False and d["user"]["id"] == reg["user"]["id"]
    with accounts.cursor() as conn:
        rows = conn.execute("SELECT provider, subject, user_id, email FROM identities").fetchall()
    assert [tuple(r) for r in rows] == [("apple", "apple-1", reg["user"]["id"], "erika@beispiel.de")]
    # unbestaetigte E-Mail verknuepft nicht: 409, kein zweites Konto
    st, d, _ = _login(hosted, "google", {"id_token": keys.token(google_claims(sub="g-9", verified=False)), "university": "luh"})
    assert (st, d["code"]) == (409, "email_taken")
    # dieselbe Apple-Kennung kann nicht an ein zweites Konto verknuepft werden
    st, other, _ = _j(asgi_call(hosted, "POST", "/api/account/register",
                                body=json.dumps({"email": "other@beispiel.de", "password": "sehr-geheim-123", "university": "luh"})))
    st, d, _ = _j(asgi_call(hosted, "POST", "/api/account/link/apple", body=json.dumps({"id_token": keys.token(apple_claims())}),
                            headers={"Authorization": f"Bearer {other['token']}"}))
    assert (st, d["code"]) == (409, "identity_taken")
    # Konto loeschen entfernt die Verknuepfung; die Kennung legt danach ein neues Konto an
    st, d, _ = _j(asgi_call(hosted, "POST", "/api/account/delete", body=json.dumps({"password": "sehr-geheim-123"}),
                            headers={"Authorization": f"Bearer {reg['token']}"}))
    assert st == 200 and d["deleted"]
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM identities WHERE subject='apple-1'").fetchone()[0] == 0
    st, d, _ = _login(hosted, "apple", {"id_token": keys.token(apple_claims()), "university": "luh"})
    assert st == 201 and d["created"] is True and d["user"]["id"] != reg["user"]["id"]


def test_login_page_csp_allows_provider_hosts_only_when_configured(hosted, monkeypatch):
    from app import server
    st, h, body = asgi_call(hosted, "GET", "/login")
    csp = [v.decode() for k, v in h if k == b"content-security-policy"][0]
    assert st == 200 and csp == server.LOGIN_CSP and "https://accounts.google.com" in csp and "https://appleid.apple.com" in csp
    assert "script-src 'self' https://accounts.google.com https://appleid.cdn-apple.com;" in csp
    html = body.decode("utf-8")
    assert 'id="social"' in html and 'id="googleBtn"' in html and "Mit Apple anmelden" in html and "<script>" not in html
    assert [v.decode() for k, v in h if k == b"content-security-policy"] and "/api/account/providers" in (server.STATIC_DIR / "login.js").read_text(encoding="utf-8")
    # App-Seiten behalten die strenge CSP, auch mit eingerichteten Anbietern
    st, reg, hh = _j(asgi_call(hosted, "POST", "/api/account/register",
                               body=json.dumps({"email": "w@beispiel.de", "password": "sehr-geheim-123", "university": "luh"})))
    cookie = [v.decode() for k, v in hh if k == b"set-cookie"][0].split(";")[0]
    st, h, _ = asgi_call(hosted, "GET", "/", cookies=cookie)
    assert st == 200 and [v.decode() for k, v in h if k == b"content-security-policy"][0] == server.UI_CSP
    # ohne Anbieter: Anmeldeseite mit der strengen CSP
    for k in ("LERNAPP_GOOGLE_CLIENT_IDS", "LERNAPP_GOOGLE_WEB_CLIENT_ID", "LERNAPP_APPLE_CLIENT_IDS"):
        monkeypatch.delenv(k, raising=False)
    st, h, _ = asgi_call(hosted, "GET", "/login")
    assert [v.decode() for k, v in h if k == b"content-security-policy"][0] == server.UI_CSP


def test_legacy_verifier_path_still_works(hosted, monkeypatch):
    """Pruefer in accounts.identity_verifiers (Fixtures, Tests) gelten weiter, wenn fuer den Anbieter keine Client-ID gesetzt ist."""
    from app import accounts
    monkeypatch.delenv("LERNAPP_APPLE_CLIENT_IDS")
    accounts.identity_verifiers["apple"] = lambda t, nonce=None: {"subject": "apple-sub-1", "email": "relay-1@privaterelay.appleid.com"} if t == "gut" else None
    st, d, _ = _login(hosted, "apple", {"identity_token": "schlecht", "university": "luh"})
    assert (st, d["code"]) == (401, "identity_invalid")
    st, d, _ = _login(hosted, "apple", {"identity_token": "gut", "university": "luh"})
    assert st == 201 and d["user"]["email"] == "relay-1@privaterelay.appleid.com"
