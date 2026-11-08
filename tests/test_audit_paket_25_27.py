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
