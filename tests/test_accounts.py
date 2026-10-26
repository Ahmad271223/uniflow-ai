"""UniFlow-Konten (Vertrag G1) und gehosteter Modus: Registrierung, Anmeldung, Sitzungen, Reset, Apple/Google als
Anmeldeweg, Loeschen; jede Anfrage im Dienst braucht eine Sitzung; Nutzer A sieht nichts von Nutzer B."""
import json
from datetime import timedelta

import pytest
from conftest import asgi_call


@pytest.fixture
def hosted(app, monkeypatch):
    """Gehosteter Modus mit leerer Kontodatenbank; danach wieder Einzelplatzmodus."""
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")
    accounts.db_path().unlink(missing_ok=True)
    for suffix in ("-wal", "-shm"):
        p = accounts.db_path().with_name(accounts.db_path().name + suffix)
        p.unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "identity_verifiers", {})
    monkeypatch.setattr(accounts, "reset_sender", None)
    yield app
    accounts.db_path().unlink(missing_ok=True)


def _json(st_hdr_body):
    st, headers, body = st_hdr_body
    return st, (json.loads(body) if body else None), headers


def _register(app, email, uni="luh", pw="sehr-geheim-123"):
    st, data, headers = _json(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": pw, "university": uni})))
    assert st == 201, data
    return data["user"], data["token"], headers


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------- Regeln und Hash (ohne Server)

@pytest.mark.parametrize("email, ok", [("A.B@Example.DE ", True), ("kein-at", False), ("a@b", False), ("", False), ("x@y.de", True)])
def test_email_rules(email, ok):
    from app import accounts
    e = accounts.normalize_email(email)
    if ok:
        accounts.validate_email(e)
        assert e == email.strip().lower()
    else:
        with pytest.raises(accounts.AccountError) as x:
            accounts.validate_email(e)
        assert x.value.code == "email_invalid"


@pytest.mark.parametrize("pw, email, code", [("kurz", "", "password_short"), ("x" * 201, "", "password_long"),
                                             ("max@beispiel.de", "max@beispiel.de", "password_is_email"), ("zehnzeichen", "", None)])
def test_password_rules(pw, email, code):
    from app import accounts
    if code:
        with pytest.raises(accounts.AccountError) as x:
            accounts.validate_password(pw, email)
        assert x.value.code == code
    else:
        accounts.validate_password(pw, email)


def test_password_hash_is_salted_scrypt_and_verifies():
    from app import accounts
    h1, h2 = accounts.hash_password("geheim-passwort"), accounts.hash_password("geheim-passwort")
    assert h1 != h2 and h1.startswith("scrypt$16384$8$1$")
    assert accounts.verify_password("geheim-passwort", h1) and not accounts.verify_password("falsch", h1)
    assert not accounts.verify_password("x", None) and not accounts.verify_password("x", "kaputt")


# ---------------------------------------------------------------- Konto-Logik (Datenbank, ohne HTTP)

def test_register_login_sessions_and_lockout(hosted, monkeypatch):
    from app import accounts
    u = accounts.register("Erika@Beispiel.de", "sehr-geheim-123", "hildesheim")
    assert u["email"] == "erika@beispiel.de" and u["university"] == "hildesheim" and u["plan"] == "free"
    with pytest.raises(accounts.AccountError) as x:
        accounts.register("erika@beispiel.de", "anderes-passwort", "luh")
    assert x.value.code == "email_taken" and x.value.status == 409
    user, token = accounts.login("erika@beispiel.de", "sehr-geheim-123", device_id="ipad-1", device_name="iPad")
    assert accounts.authenticate(token)["id"] == user["id"]
    assert accounts.authenticate("falsches-token") is None and accounts.authenticate(None) is None
    # 8 Fehlversuche sperren das Konto 10 Minuten, auch das richtige Passwort
    for _ in range(8):
        with pytest.raises(accounts.AccountError):
            accounts.login("erika@beispiel.de", "falsch")
    with pytest.raises(accounts.AccountError) as x:
        accounts.login("erika@beispiel.de", "sehr-geheim-123")
    assert x.value.code == "locked" and x.value.status == 429
    later = accounts.now() + timedelta(minutes=11)
    monkeypatch.setattr(accounts, "now", lambda: later)
    accounts.login("erika@beispiel.de", "sehr-geheim-123")               # Sperre abgelaufen
    # Sitzungen: Ablauf nach 30 Tagen ohne Nutzung, Abmelden ueberall ausser der aktuellen
    _, t2 = accounts.login("erika@beispiel.de", "sehr-geheim-123", device_id="mac-1")
    assert len(accounts.sessions(user["id"], t2)) == 3 and [s for s in accounts.sessions(user["id"], t2) if s["current"]][0]["device_id"] == "mac-1"
    assert accounts.logout_all(user["id"], keep_token=t2) == 2
    assert accounts.authenticate(token) is None and accounts.authenticate(t2)["id"] == user["id"]
    monkeypatch.setattr(accounts, "now", lambda: later + timedelta(days=31))
    assert accounts.authenticate(t2) is None


def test_password_reset_flow(hosted):
    from app import accounts
    sent = []
    accounts.reset_sender = lambda email, token: sent.append((email, token))
    accounts.register("max@beispiel.de", "sehr-geheim-123", "luh")
    _, tok = accounts.login("max@beispiel.de", "sehr-geheim-123")
    assert accounts.request_password_reset("niemand@beispiel.de") is None and sent == []
    reset = accounts.request_password_reset("MAX@beispiel.de")
    assert sent == [("max@beispiel.de", reset)]
    with pytest.raises(accounts.AccountError):
        accounts.reset_password(reset, "kurz")
    accounts.reset_password(reset, "neues-geheimnis-9")
    assert accounts.authenticate(tok) is None, "alte Sitzungen sind nach dem Reset beendet"
    with pytest.raises(accounts.AccountError) as x:
        accounts.reset_password(reset, "noch-eins-12345")
    assert x.value.code == "reset_invalid"
    accounts.login("max@beispiel.de", "neues-geheimnis-9")


def test_identity_login_requires_configured_verifier_and_links_by_subject(hosted):
    from app import accounts
    with pytest.raises(accounts.AccountError) as x:
        accounts.login_with_identity("apple", "irgendein-token")
    assert x.value.code == "provider_not_configured" and x.value.status == 501
    accounts.identity_verifiers["apple"] = lambda t: {"subject": "apple-sub-1", "email": "relay-1@privaterelay.appleid.com"} if t == "gut" else None
    with pytest.raises(accounts.AccountError) as x:
        accounts.login_with_identity("apple", "schlecht", university="luh")
    assert x.value.code == "identity_invalid"
    u, tok, created = accounts.login_with_identity("apple", "gut", university="luh")
    assert created and u["email"] == "relay-1@privaterelay.appleid.com" and accounts.authenticate(tok)["id"] == u["id"]
    u2, _, created2 = accounts.login_with_identity("apple", "gut")
    assert not created2 and u2["id"] == u["id"], "zweite Anmeldung: dasselbe Konto ueber die Apple-Kennung"
    # Bestehendes E-Mail-Konto verknuepft Apple; dieselbe Apple-Kennung geht nicht an ein zweites Konto
    other = accounts.register("other@beispiel.de", "sehr-geheim-123", "luh")
    with pytest.raises(accounts.AccountError) as x:
        accounts.link_identity(other["id"], "apple", "gut")
    assert x.value.code == "identity_taken"
    accounts.identity_verifiers["google"] = lambda t: {"subject": "g-7", "email": "other@beispiel.de"}
    assert accounts.link_identity(other["id"], "google", "x") == {"provider": "google", "linked": True}
    u3, _, created3 = accounts.login_with_identity("google", "x")
    assert not created3 and u3["id"] == other["id"]


def test_delete_account_locks_and_retires_data(hosted, monkeypatch):
    from app import accounts, config
    u = accounts.register("weg@beispiel.de", "sehr-geheim-123", "luh")
    _, tok = accounts.login("weg@beispiel.de", "sehr-geheim-123")
    d = config.user_data_dir(u["id"], "luh")
    d.mkdir(parents=True, exist_ok=True)
    (d / "lernapp.db").write_bytes(b"x")
    with pytest.raises(accounts.AccountError):
        accounts.delete_account(u["id"], "falsch")
    assert accounts.delete_account(u["id"], "sehr-geheim-123") == {"deleted": True, "purge_after_days": 30}
    assert accounts.authenticate(tok) is None and not d.exists() and config.retired_user_data_dirs(u["id"])
    accounts.register("weg@beispiel.de", "sehr-geheim-123", "luh")            # Adresse ist wieder frei
    assert accounts.purge_deleted() == 0
    later = accounts.now() + timedelta(days=31)
    monkeypatch.setattr(accounts, "now", lambda: later)
    assert accounts.purge_deleted() == 1 and not config.retired_user_data_dirs(u["id"])


# ---------------------------------------------------------------- HTTP im gehosteten Modus

def test_hosted_requires_session_on_every_api_path(hosted):
    """Ohne Sitzung: 401 auf jedem /api-Pfad ausser den oeffentlichen Kontopfaden; Oberflaeche bleibt erreichbar."""
    from fastapi.routing import APIRoute
    from app import account_api
    for r in hosted.routes:
        if not isinstance(r, APIRoute) or not r.path.startswith("/api/") or r.path in account_api.PUBLIC_PATHS:
            continue
        for m in r.methods:
            if m in ("HEAD", "OPTIONS"):
                continue
            path = r.path.replace("{file_id}", "f1").replace("{doc_id}", "d1")
            import re
            path = re.sub(r"\{[a-z_]+\}", "1", path)
            st, _, body = asgi_call(hosted, m, path)
            assert st in (401, 501), (m, path, st, body[:100])
            if st == 501:
                assert b"not_available_hosted" in body
    assert asgi_call(hosted, "GET", "/api/account/info")[0] == 200
    assert asgi_call(hosted, "GET", "/")[0] == 200


def test_hosted_register_login_me_logout(hosted):
    user, token, headers = _register(hosted, "api@beispiel.de", "hildesheim")
    cookie = [v.decode() for k, v in headers if k == b"set-cookie"][0]
    assert cookie.startswith("uniflow_session=") and "HttpOnly" in cookie
    st, me, _ = _json(asgi_call(hosted, "GET", "/api/account/me", headers=_auth(token)))
    assert st == 200 and me["user"]["email"] == "api@beispiel.de" and len(me["sessions"]) == 1 and me["sessions"][0]["current"]
    st, me2, _ = _json(asgi_call(hosted, "GET", "/api/account/me", cookies=cookie.split(";")[0]))
    assert st == 200 and me2["user"]["id"] == user["id"], "Cookie-Sitzung fuer den Browser"
    st, data, _ = _json(asgi_call(hosted, "POST", "/api/account/login", body=json.dumps({"email": "api@beispiel.de", "password": "falsch"})))
    assert st == 401 and data == {"detail": "E-Mail-Adresse oder Passwort stimmt nicht.", "code": "credentials_invalid"}
    st, settings, _ = _json(asgi_call(hosted, "GET", "/api/settings", headers=_auth(token)))
    assert st == 200 and settings["university"] == "hildesheim" and settings["mode"] == "hosted" and "lan_pin" not in settings
    st, data, _ = _json(asgi_call(hosted, "PUT", "/api/settings", body=json.dumps({"university": "luh"}), headers=_auth(token)))
    assert st == 400 and data["code"] == "use_account"
    assert asgi_call(hosted, "POST", "/api/account/logout", headers=_auth(token))[0] == 200
    assert asgi_call(hosted, "GET", "/api/account/me", headers=_auth(token))[0] == 401
    st, data, _ = _json(asgi_call(hosted, "POST", "/api/account/password/reset-request", body=json.dumps({"email": "api@beispiel.de"})))
    assert st == 200 and "token" not in json.dumps(data).lower()


def test_hosted_local_only_paths_answer_501(hosted):
    _, token, _ = _register(hosted, "k@beispiel.de")
    for m, p in (("GET", "/api/network"), ("POST", "/api/ai/tutor"),
                 ("POST", "/api/files/abc/analyze"), ("POST", "/api/tests/generate-week"), ("POST", "/api/plan/generate")):
        st, data, _ = _json(asgi_call(hosted, m, p, headers=_auth(token), body="{}"))
        assert st == 501 and data["code"] == "not_available_hosted", (m, p, st, data)
    assert asgi_call(hosted, "GET", "/api/sync/status", headers=_auth(token))[0] == 200
    # Abgleich und Zugangsdaten gibt es im Dienst je Konto (tests/test_hosted_sync.py)
    st, data, _ = _json(asgi_call(hosted, "POST", "/api/sync", headers=_auth(token), body="{}"))
    assert st == 400 and data["code"] == "credentials_missing"
    assert asgi_call(hosted, "GET", "/api/credentials", headers=_auth(token))[0] == 200


def test_users_are_isolated_in_their_own_databases(hosted):
    """Nutzer A legt Modul, Ordner, Karteikarte, Notizbuch mit Notizen und Einstellungen an; Nutzer B sieht auf
    keinem GET-Pfad etwas davon und bekommt auf A's IDs 404. Beide Datenbanken liegen in getrennten Ordnern."""
    from fastapi.routing import APIRoute
    from app import config
    a, ta, _ = _register(hosted, "a@beispiel.de", "luh")
    b, tb, _ = _register(hosted, "b@beispiel.de", "luh")
    marker = "Geheim-A-7f3e"
    st, mod, _ = _json(asgi_call(hosted, "POST", "/api/modules", body=json.dumps({"name": f"Modul {marker}"}), headers=_auth(ta)))
    assert st == 200, mod
    st, folder, _ = _json(asgi_call(hosted, "POST", "/api/folders", body=json.dumps({"name": f"Ordner {marker}"}), headers=_auth(ta)))
    assert st == 200, folder
    st, card, _ = _json(asgi_call(hosted, "POST", "/api/flashcards", body=json.dumps({"cards": [{"question": f"Frage {marker}", "answer": "42"}]}), headers=_auth(ta)))
    assert st == 200 and card["count"] == 1, card
    st, cards_a, _ = _json(asgi_call(hosted, "GET", "/api/flashcards", headers=_auth(ta)))
    card = cards_a[0] if isinstance(cards_a, list) else cards_a["cards"][0]
    assert asgi_call(hosted, "PUT", "/api/settings", body=json.dumps({"hours_per_day": 7}), headers=_auth(ta))[0] == 200
    boundary = "----uniflowtest"
    form = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\nnotebook\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nNotizbuch {marker}\r\n--{boundary}--\r\n").encode()
    st, nb, _ = _json(asgi_call(hosted, "POST", "/api/notebooks", body=form, content_type=f"multipart/form-data; boundary={boundary}", headers=_auth(ta)))
    assert st == 200, nb
    fid = nb["id"]
    st, cur, _ = _json(asgi_call(hosted, "GET", f"/api/files/{fid}/annotations", headers=_auth(ta)))
    assert st == 200
    st, _, _ = _json(asgi_call(hosted, "PUT", f"/api/files/{fid}/annotations?base_version={cur.get('version', 0)}",
                               body=json.dumps({"pages": {"1": {"notes": [{"text": f"Notiz {marker}"}]}}}), headers=_auth(ta)))
    assert st == 200
    # A sieht alles, B nichts
    st, mods_a, _ = _json(asgi_call(hosted, "GET", "/api/modules", headers=_auth(ta)))
    assert [m["name"] for m in mods_a] == [f"Modul {marker}"]
    leaks = []
    for r in hosted.routes:
        if not isinstance(r, APIRoute) or "GET" not in r.methods or "{" in r.path or not r.path.startswith("/api/"):
            continue
        st, _, body = asgi_call(hosted, "GET", r.path, headers=_auth(tb))
        assert st != 500, (r.path, body[:200])
        if marker.encode() in body or fid.encode() in body:
            leaks.append(r.path)
    assert leaks == []
    st, settings_b, _ = _json(asgi_call(hosted, "GET", "/api/settings", headers=_auth(tb)))
    assert settings_b["hours_per_day"] == 4.0
    for m, p in (("PATCH", f"/api/modules/{mod['id']}"), ("DELETE", f"/api/modules/{mod['id']}"), ("DELETE", f"/api/flashcards/{card['id']}"),
                 ("PATCH", f"/api/folders/{folder['id']}"), ("GET", f"/api/files/{fid}"), ("GET", f"/api/files/{fid}/annotations"),
                 ("GET", f"/api/files/{fid}/content"), ("PATCH", f"/api/files/{fid}")):
        st, _, body = asgi_call(hosted, m, p, headers=_auth(tb), body=json.dumps({"name": "x", "title": "x"}))
        assert st == 404, (m, p, st, body[:100])
    # A kann weiter zugreifen; B's Datenbank ist eine andere Datei
    assert asgi_call(hosted, "GET", f"/api/files/{fid}/annotations", headers=_auth(ta))[0] == 200
    da, dbb = config.user_data_dir(a["id"], "luh"), config.user_data_dir(b["id"], "luh")
    assert (da / "lernapp.db").exists() and (dbb / "lernapp.db").exists() and da != dbb
    assert not (config.DATA_DIR / "lernapp.db").read_bytes().find(marker.encode()) >= 0, "nichts im Einzelplatz-Ordner"
