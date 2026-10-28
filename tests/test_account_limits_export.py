"""E-Mail-Bestaetigung, Grenzen fuer Registrierung/Reset/Bestaetigung und Datenexport (28.10.2026)."""
import io
import json
import zipfile
from datetime import timedelta

import pytest
from conftest import asgi_call


@pytest.fixture
def hosted(app, monkeypatch):
    from app import accounts, config
    monkeypatch.setattr(config, "MODE", "hosted")
    accounts.db_path().unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "identity_verifiers", {})
    monkeypatch.setattr(accounts, "reset_sender", None)
    sent = []
    monkeypatch.setattr(accounts, "verify_sender", lambda email, tok: sent.append((email, tok)))
    monkeypatch.setattr(accounts, "LIMITS", dict(accounts.LIMITS))
    app.state.sent = sent
    yield app
    accounts.db_path().unlink(missing_ok=True)


def _j(r):
    st, _, b = r
    return st, (json.loads(b) if b else None)


def _register(app, email, ip=("127.0.0.1", 5000)):
    return _j(asgi_call(app, "POST", "/api/account/register", client=ip,
                        body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": "luh"})))


def test_email_verification_flow(hosted, monkeypatch):
    from app import accounts, mail
    welcome = []
    monkeypatch.setattr(mail, "send_welcome", lambda email, tok=None: welcome.append((email, tok)))
    st, d = _register(hosted, "neu@beispiel.de")
    assert st == 201 and d["user"]["email_verified"] is False
    assert welcome and welcome[0][1], "Willkommensmail mit Bestaetigungslink"
    h = {"Authorization": f"Bearer {d['token']}"}
    st, r = _j(asgi_call(hosted, "POST", "/api/account/verify-email", body=json.dumps({"token": "kaputt"})))
    assert (st, r["code"]) == (400, "verify_invalid")
    # Link aus der Willkommensmail, ohne Sitzung
    st, r = _j(asgi_call(hosted, "POST", "/api/account/verify-email", body=json.dumps({"token": welcome[0][1]})))
    assert st == 200 and r["user"]["email_verified"] is True
    st, r = _j(asgi_call(hosted, "POST", "/api/account/verify-email", body=json.dumps({"token": welcome[0][1]})))
    assert (st, r["code"]) == (400, "verify_invalid"), "nur einmal"
    st, r = _j(asgi_call(hosted, "POST", "/api/account/verify-email/resend", headers=h))
    assert st == 200 and r["already"] is True and hosted.state.sent == []
    st, r = _j(asgi_call(hosted, "GET", "/api/account/me", headers=h))
    assert r["user"]["email_verified"] is True


def test_verification_link_expires_and_resend_is_limited(hosted, monkeypatch):
    from app import accounts
    st, d = _register(hosted, "spaet@beispiel.de")
    h = {"Authorization": f"Bearer {d['token']}"}
    for _ in range(accounts.LIMITS["verify_user"][0]):
        assert _j(asgi_call(hosted, "POST", "/api/account/verify-email/resend", headers=h))[0] == 200
    st, r = _j(asgi_call(hosted, "POST", "/api/account/verify-email/resend", headers=h))
    assert (st, r["code"]) == (429, "rate_limited")
    tok = hosted.state.sent[-1][1]
    later = accounts.now() + timedelta(hours=accounts.VERIFY_HOURS + 1)
    monkeypatch.setattr(accounts, "now", lambda: later)
    st, r = _j(asgi_call(hosted, "POST", "/api/account/verify-email", body=json.dumps({"token": tok})))
    assert (st, r["code"]) == (400, "verify_invalid"), "abgelaufen"


def test_password_reset_link_also_confirms_the_address(hosted, monkeypatch):
    from app import accounts
    _register(hosted, "reset@beispiel.de")
    tok = accounts.request_password_reset("reset@beispiel.de")
    accounts.reset_password(tok, "ganz-neues-passwort-1")
    with accounts.cursor() as conn:
        assert conn.execute("SELECT email_verified FROM users WHERE email='reset@beispiel.de'").fetchone()[0] == 1


def test_register_limit_per_ip_counts_taken_addresses_too(hosted):
    from app import accounts
    accounts.LIMITS["register_ip"] = (3, 60)
    ip = ("203.0.113.7", 5000)
    assert _register(hosted, "a1@beispiel.de", ip)[0] == 201
    assert _register(hosted, "a1@beispiel.de", ip)[0] == 409, "vergebene Adresse zaehlt mit"
    assert _register(hosted, "a2@beispiel.de", ip)[0] == 201
    st, h, b = asgi_call(hosted, "POST", "/api/account/register", client=ip,
                         body=json.dumps({"email": "a3@beispiel.de", "password": "sehr-geheim-123", "university": "luh"}))
    assert st == 429 and json.loads(b)["code"] == "rate_limited"
    assert int(dict((k.decode(), v.decode()) for k, v in h)["retry-after"]) > 0
    assert _register(hosted, "a4@beispiel.de", ("198.51.100.9", 5000))[0] == 201, "andere IP unberuehrt"


def test_reset_limits_per_address_silently_and_per_ip_with_429(hosted):
    from app import accounts
    sent = []
    accounts.reset_sender = lambda email, tok: sent.append(email)
    try:
        _register(hosted, "r@beispiel.de")
        for _ in range(5):
            st, d = _j(asgi_call(hosted, "POST", "/api/account/password/reset-request", client=("198.51.100.20", 1),
                                 body=json.dumps({"email": "r@beispiel.de"})))
            assert st == 200 and "Wenn es ein Konto" in d["message"], "Antwort immer gleich"
        assert len(sent) == accounts.LIMITS["reset_email"][0], "je Adresse hoechstens 3 Mails je Stunde"
        accounts.LIMITS["reset_ip"] = (2, 60)
        ip = ("198.51.100.30", 1)
        for e in ("x@beispiel.de", "y@beispiel.de"):
            assert asgi_call(hosted, "POST", "/api/account/password/reset-request", client=ip, body=json.dumps({"email": e}))[0] == 200
        st, d = _j(asgi_call(hosted, "POST", "/api/account/password/reset-request", client=ip, body=json.dumps({"email": "z@beispiel.de"})))
        assert (st, d["code"]) == (429, "rate_limited")
    finally:
        accounts.reset_sender = None


def test_login_lock_per_ip_is_higher_than_per_address(hosted):
    """Viele Studierende hinter einer Hochschul-IP: acht Fehlversuche irgendwo im Netz sperren nicht alle anderen."""
    from app import accounts
    _register(hosted, "ich@beispiel.de")
    ip = ("192.0.2.50", 1)
    for i in range(accounts.MAX_FAILS + 2):
        asgi_call(hosted, "POST", "/api/account/login", client=ip, body=json.dumps({"email": f"fremd{i}@beispiel.de", "password": "falsch"}))
    st, d = _j(asgi_call(hosted, "POST", "/api/account/login", client=ip,
                         body=json.dumps({"email": "ich@beispiel.de", "password": "sehr-geheim-123"})))
    assert st == 200, "dieselbe IP, andere Adresse: weiter moeglich"
    for _ in range(accounts.MAX_FAILS):
        asgi_call(hosted, "POST", "/api/account/login", client=ip, body=json.dumps({"email": "ich@beispiel.de", "password": "falsch"}))
    st, d = _j(asgi_call(hosted, "POST", "/api/account/login", client=ip,
                         body=json.dumps({"email": "ich@beispiel.de", "password": "sehr-geheim-123"})))
    assert (st, d["code"]) == (429, "locked"), "je Adresse weiter nach 8 Fehlversuchen"


def test_export_contains_everything_but_no_secrets(hosted):
    from app import accounts, community, config, db, test_library, vault
    st, d = _register(hosted, "export@beispiel.de")
    uid, h = d["user"]["id"], {"Authorization": f"Bearer {d['token']}"}
    vault.set_values(uid, {"STUDIP_USER": "luh-id-123", "STUDIP_PASSWORD": "streng-geheim", "STUDIP_COOKIES": "cookie-geheim"})
    t = config.set_user_context(uid, "luh")
    try:
        db.init_db()
        with db.cursor() as conn:
            conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Export-Modul', '#111111', 0, '2026-10-28')")
    finally:
        config.reset_user_context(t)
    base = config.BASE_DATA_DIR / "users" / uid
    (base / "browser-profile").mkdir(parents=True, exist_ok=True)
    (base / "browser-profile" / "Cookies").write_bytes(b"uni-sitzung")
    (base / "files").mkdir(parents=True, exist_ok=True)
    (base / "files" / "eigene-notiz.txt").write_text("meine Notiz", encoding="utf-8")
    sid = f"{uid[:8]}-0000-4000-8000-0000000000aa"
    with community.cursor() as conn:
        conn.execute("""INSERT INTO solutions(id, fingerprint, university, author_id, pseudonym, display_name, title, created_at,
                        published_at, page_count, pages, size) VALUES (?, ?, 'luh', ?, 'Studi-e', 'Studi-e', 'Blatt 9', '2026-10-28',
                        '2026-10-28', 3, 1, 10)""", (sid, "c" * 64, uid))
    community.package_dir().mkdir(parents=True, exist_ok=True)
    (community.package_dir() / f"{sid}.uniflowsolution").write_bytes(b"paket")
    with test_library.cursor() as conn:
        conn.execute("""INSERT INTO questions(id, fingerprint, subject, subject_key, topic, topic_key, question, answer, tokens, source,
                        review, owner_hash, created_at) VALUES ('q-exp', 'q-exp', 'Mathe', 'mathe', 'T', 't', 'Meine Frage?', 'A', 'x',
                        'user_shared', 'private', ?, '2026-10-28')""", (test_library.owner_hash(uid),))
    st, hdrs, raw = asgi_call(hosted, "GET", "/api/account/export", headers=h)
    assert st == 200 and dict((k.decode(), v.decode()) for k, v in hdrs)["content-type"] == "application/zip"
    z = zipfile.ZipFile(io.BytesIO(raw))
    names = set(z.namelist())
    assert {"LIESMICH.txt", "konto.json", "testbibliothek.json", "community/meine-loesungen.json", f"community/pakete/{sid}.uniflowsolution",
            "daten/files/eigene-notiz.txt"} <= names
    assert not any("browser-profile" in n for n in names), "keine Hochschul-Sitzung im Export"
    konto = json.loads(z.read("konto.json"))
    assert konto["konto"]["email"] == "export@beispiel.de" and konto["sitzungen"]
    creds = konto["hochschul_zugangsdaten"]
    assert creds["STUDIP_USER"] == "luh-id-123" and "streng-geheim" not in json.dumps(konto) and "cookie-geheim" not in json.dumps(konto)
    assert creds["STUDIP_PASSWORD"].startswith("gespeichert")
    dbs = [n for n in names if n.endswith("lernapp.db")]
    assert dbs, names
    import sqlite3
    import tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "x.db"
        p.write_bytes(z.read(dbs[0]))
        c = sqlite3.connect(p)
        try:
            assert c.execute("SELECT COUNT(*) FROM modules WHERE name='Export-Modul'").fetchone()[0] == 1
        finally:
            c.close()
    assert [q["question"] for q in json.loads(z.read("testbibliothek.json"))] == ["Meine Frage?"]


def test_export_needs_a_session_and_is_limited(hosted):
    from app import accounts
    assert asgi_call(hosted, "GET", "/api/account/export")[0] == 401
    st, d = _register(hosted, "viel@beispiel.de")
    h = {"Authorization": f"Bearer {d['token']}"}
    accounts.LIMITS["export_user"] = (1, 1440)
    assert asgi_call(hosted, "GET", "/api/account/export", headers=h)[0] == 200
    st, r = _j(asgi_call(hosted, "GET", "/api/account/export", headers=h))
    assert (st, r["code"]) == (429, "rate_limited")


def test_limits_can_be_set_by_environment(hosted, monkeypatch):
    from app import accounts
    monkeypatch.setenv("LERNAPP_LIMIT_REGISTER_IP", "1/60")
    ip = ("203.0.113.99", 1)
    assert _register(hosted, "e1@beispiel.de", ip)[0] == 201
    assert _register(hosted, "e2@beispiel.de", ip)[0] == 429
    monkeypatch.setenv("LERNAPP_LIMIT_REGISTER_IP", "unsinn")
    assert accounts._limit("register_ip") == accounts.LIMITS["register_ip"]
