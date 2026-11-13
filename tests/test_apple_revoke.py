"""Widerruf bei Apple beim Loeschen eines Kontos (App-Review-Richtlinie 5.1.1(v), app/apple_signin.py): die App
schickt bei „Mit Apple anmelden“ den einmaligen `authorization_code`, der Dienst tauscht ihn gegen ein Refresh-Token
(verschluesselt in accounts.db) und widerruft es bei `POST /api/account/delete`. Apple ist durch eine Attrappe von
`apple_signin.post_form` ersetzt, der Schluessel wird im Test erzeugt; es geht nichts ins Netz."""
import base64
import json
import logging

import pytest
from conftest import asgi_call
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from test_social_login import APPLE_ID, _j, _login, apple_claims, hosted, keys  # noqa: F401 - Fixtures

REFRESH = "r.apple-refresh-token-geheim-123"


class FakeApple:
    """Antworten von appleid.apple.com: /auth/token liefert ein Refresh-Token, /auth/revoke 200 (oder `revoke_status`)."""

    def __init__(self):
        self.calls: list[tuple[str, dict]] = []
        self.revoke_status = 200
        self.token_status = 200

    def __call__(self, url, data):
        self.calls.append((url, dict(data)))
        if url.endswith("/auth/token"):
            if self.token_status != 200:
                return self.token_status, {"error": "invalid_grant"}
            return 200, {"access_token": "a.x", "refresh_token": REFRESH, "id_token": "i.x", "token_type": "Bearer"}
        if url.endswith("/auth/revoke"):
            return self.revoke_status, ({} if self.revoke_status == 200 else {"error": "invalid_client"})
        raise AssertionError(url)

    def urls(self):
        return [u.rsplit("/", 1)[1] for u, _ in self.calls]


@pytest.fixture
def signing_key(tmp_path):
    key = ec.generate_private_key(ec.SECP256R1())
    p = tmp_path / "AuthKey_TEST123456.p8"
    p.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    return key, p


@pytest.fixture
def apple(hosted, monkeypatch, signing_key):  # noqa: F811
    from app import apple_signin
    fake = FakeApple()
    monkeypatch.setattr(apple_signin, "post_form", fake)
    monkeypatch.setenv("LERNAPP_APPLE_TEAM_ID", "TEAM123456")
    monkeypatch.setenv("LERNAPP_APPLE_SIGNIN_KEY_ID", "KEY1234567")
    monkeypatch.setenv("LERNAPP_APPLE_SIGNIN_KEY_FILE", str(signing_key[1]))
    return fake


def _apple_login(app, keys, sub="apple-1", code="c.einmalig", email="relay@privaterelay.appleid.com", **extra):  # noqa: F811
    body = {"id_token": keys.token(apple_claims(sub=sub, email=email), alg="ES256", kid="ec-1"), "university": "luh", **extra}
    if code:
        body["authorization_code"] = code
    return _login(app, "apple", body)


def _delete(app, token, body=None):
    return _j(asgi_call(app, "POST", "/api/account/delete", body=json.dumps(body or {}), headers={"Authorization": f"Bearer {token}"}))


def _b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def test_client_secret_is_an_es256_jwt_apple_accepts(apple, signing_key):
    from app import apple_signin
    tok = apple_signin.client_secret(APPLE_ID, now=1_800_000_000)
    h, p, sig = tok.split(".")
    header, payload = json.loads(_b64d(h)), json.loads(_b64d(p))
    assert header == {"alg": "ES256", "kid": "KEY1234567", "typ": "JWT"}
    assert payload == {"iss": "TEAM123456", "iat": 1_800_000_000, "exp": 1_800_000_000 + apple_signin.SECRET_TTL,
                       "aud": "https://appleid.apple.com", "sub": APPLE_ID}
    assert payload["exp"] - payload["iat"] <= 180 * 86400, "Apple: hoechstens 6 Monate"
    raw = _b64d(sig)
    assert len(raw) == 64, "JWS: r||s, nicht DER"
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    signing_key[0].public_key().verify(der, f"{h}.{p}".encode(), ec.ECDSA(hashes.SHA256()))


def test_login_stores_refresh_token_encrypted_and_delete_revokes_it(apple, hosted, keys):  # noqa: F811
    from app import accounts
    st, d, _ = _apple_login(hosted, keys)
    assert st == 201
    assert apple.urls() == ["token"]
    url, form = apple.calls[0]
    assert url == "https://appleid.apple.com/auth/token"
    assert form["grant_type"] == "authorization_code" and form["code"] == "c.einmalig" and form["client_id"] == APPLE_ID
    assert form["client_secret"].count(".") == 2
    with accounts.cursor() as conn:
        row = conn.execute("SELECT apple_refresh_enc, apple_client_id FROM identities WHERE subject='apple-1'").fetchone()
    assert row["apple_client_id"] == APPLE_ID and row["apple_refresh_enc"].startswith("v1:")
    raw = accounts.db_path().read_bytes() + b"".join(p.read_bytes() for p in accounts.db_path().parent.glob("accounts.db-wal"))
    assert REFRESH.encode() not in raw, "nie im Klartext in accounts.db"
    st, out, _ = _delete(hosted, d["token"])
    assert st == 200 and out["deleted"]
    assert apple.urls() == ["token", "revoke"]
    url, form = apple.calls[1]
    assert url == "https://appleid.apple.com/auth/revoke"
    assert form["token"] == REFRESH and form["token_type_hint"] == "refresh_token" and form["client_id"] == APPLE_ID
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM identities").fetchone()[0] == 0


def test_revoke_failure_still_deletes_and_logs_without_secrets(apple, hosted, keys, caplog):  # noqa: F811
    from app import accounts
    st, d, _ = _apple_login(hosted, keys)
    apple.revoke_status = 400
    with caplog.at_level(logging.INFO):
        st, out, _ = _delete(hosted, d["token"])
    assert st == 200 and out["deleted"], "ein Fehler bei Apple verhindert das Loeschen nicht"
    with accounts.cursor() as conn:
        assert conn.execute("SELECT status FROM users WHERE id=?", (d["user"]["id"],)).fetchone()["status"] == "deleted"
    text = "\n".join(r.getMessage() for r in caplog.records)
    assert "Widerruf bei Apple fehlgeschlagen" in text and "HTTP 400" in text
    assert REFRESH not in text and "c.einmalig" not in text and "client_secret" not in text


def test_network_error_at_apple_never_breaks_login_or_delete(apple, hosted, keys, monkeypatch):  # noqa: F811
    from app import apple_signin

    def down(url, data):
        raise OSError("kein Netz")
    monkeypatch.setattr(apple_signin, "post_form", down)
    st, d, _ = _apple_login(hosted, keys)
    assert st == 201, "Code-Tausch scheitert: Anmeldung gilt trotzdem"
    assert _delete(hosted, d["token"])[0] == 200


def test_without_configuration_or_code_no_call_to_apple(hosted, keys, monkeypatch, caplog):  # noqa: F811
    from app import apple_signin
    fake = FakeApple()
    monkeypatch.setattr(apple_signin, "post_form", fake)
    for k in ("LERNAPP_APPLE_TEAM_ID", "LERNAPP_APPLE_SIGNIN_KEY_ID", "LERNAPP_APPLE_SIGNIN_KEY_FILE"):
        monkeypatch.delenv(k, raising=False)
    assert not apple_signin.configured()
    st, d, _ = _apple_login(hosted, keys)
    assert st == 201
    with caplog.at_level(logging.INFO):
        assert _delete(hosted, d["token"])[0] == 200
    assert fake.calls == [], "ohne Team-ID, Key-ID und .p8 kein Aufruf bei Apple"
    assert "kein Apple-Token gespeichert" in "\n".join(r.getMessage() for r in caplog.records)


def test_login_without_code_stores_nothing_and_link_with_code_stores_token(apple, hosted, keys):  # noqa: F811
    from app import accounts
    st, d, _ = _apple_login(hosted, keys, code=None)
    assert st == 201 and apple.calls == []
    # zweite Anmeldung derselben Apple-ID mit Code (z. B. zweites iPad): Token wird nachgetragen
    st, d2, _ = _apple_login(hosted, keys)
    assert st == 200 and d2["user"]["id"] == d["user"]["id"] and apple.urls() == ["token"]
    with accounts.cursor() as conn:
        assert conn.execute("SELECT apple_refresh_enc FROM identities WHERE subject='apple-1'").fetchone()[0]
    # abgelehnter Tausch: Anmeldung gilt, nichts gespeichert
    apple.token_status = 400
    st, d3, _ = _apple_login(hosted, keys, sub="apple-2", email="zwei@privaterelay.appleid.com")
    assert st == 201
    with accounts.cursor() as conn:
        assert conn.execute("SELECT apple_refresh_enc FROM identities WHERE subject='apple-2'").fetchone()[0] is None


def test_redelete_after_restore_also_revokes(apple, hosted, keys):  # noqa: F811
    from app import accounts
    st, d, _ = _apple_login(hosted, keys)
    assert accounts.redelete(d["user"]["id"]) is True
    assert apple.urls() == ["token", "revoke"]
