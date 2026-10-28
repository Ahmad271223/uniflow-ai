"""Windows-App mit dem Studora-Konto (app/service_link.py, 28.10.2026): anmelden am Dienst, eigene Hochschul-PDFs
melden, Community-Aufrufe weiterleiten. Der "Dienst" ist hier dieselbe App im gehosteten Modus, direkt per ASGI
aufgerufen; so laeuft der echte Weg Windows -> Dienst -> Community, nur ohne Netz."""
import json
from pathlib import Path

import pytest
from conftest import asgi_call

FP = "c" * 64
SERVICE = "http://127.0.0.1:9"


def _j(r):
    st, _, b = r
    return st, (json.loads(b) if b else None)


@pytest.fixture
def service(app, monkeypatch, tmp_path):
    """Lokale App (Einzelplatz) plus Dienst (gehostet) im selben Prozess."""
    from app import accounts, community, config, db, service_link
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)
    service_link.state_path().unlink(missing_ok=True)
    monkeypatch.setattr(accounts, "LIMITS", dict(accounts.LIMITS))
    calls = []

    def transport(method, url, headers, body, timeout):
        assert url.startswith(SERVICE), url
        path = url[len(SERVICE):]
        calls.append((method, path, headers.get("Authorization")))
        old = config.MODE
        config.MODE = "hosted"
        try:
            hdrs = {k: v for k, v in headers.items() if k.lower() in ("authorization",)}
            st, h, b = asgi_call(app, method, path, body=body or b"", headers=hdrs,
                                 content_type=headers.get("Content-Type", "application/json"))
        finally:
            config.MODE = old
        return st, {k.decode(): v.decode() for k, v in h}, b

    monkeypatch.setattr(service_link, "transport", transport)
    pdf = tmp_path / "Blatt1.pdf"
    pdf.write_bytes(b"%PDF-1.4 Testblatt")
    db.init_db()
    with db.cursor() as conn:
        conn.execute("DELETE FROM files WHERE id IN ('sl-1','sl-2','sl-3')")
        conn.execute("INSERT OR IGNORE INTO courses(id, title) VALUES ('c1', 'Testkurs')")
        conn.execute("""INSERT INTO files(id, course_id, name, mime, status, download_url, content_sha256)
                        VALUES ('sl-1', 'c1', 'Blatt0.pdf', 'application/pdf', 'neu', 'https://studip.example/f/1', ?)""", (FP,))
        conn.execute("""INSERT INTO files(id, course_id, name, mime, status, download_url, local_path)
                        VALUES ('sl-2', 'c1', 'Blatt1.pdf', 'application/pdf', 'neu', 'https://studip.example/f/2', ?)""", (str(pdf),))
        conn.execute("""INSERT INTO files(id, course_id, name, mime, status, local_path, content_sha256)
                        VALUES ('sl-3', '__user__', 'eigen.pdf', 'application/pdf', 'neu', ?, ?)""", (str(pdf), "d" * 64))
    yield app, calls, pdf
    with db.cursor() as conn:
        conn.execute("DELETE FROM files WHERE id IN ('sl-1','sl-2','sl-3')")
    service_link.state_path().unlink(missing_ok=True)
    accounts.db_path().unlink(missing_ok=True)
    community.db_path().unlink(missing_ok=True)


def _hosted(app, method, path, body=None, headers=None):
    from app import config
    old = config.MODE
    config.MODE = "hosted"
    try:
        return _j(asgi_call(app, method, path, body=json.dumps(body) if body is not None else None, headers=headers))
    finally:
        config.MODE = old


def _account(app, email, uni="luh", plus=True):
    from app import accounts
    st, d = _hosted(app, "POST", "/api/account/register", {"email": email, "password": "sehr-geheim-123", "university": uni})
    assert st == 201, d
    accounts.mark_email_verified(d["user"]["id"])
    if plus:
        accounts.set_plan(d["user"]["id"], "plus")
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


def test_link_claim_find_like_comment_and_logout(service):
    app, calls, pdf = service
    from app import config, service_link
    from app.testshare import file_sha256
    _account(app, "windows@example.org")
    other, oh = _account(app, "ipad@example.org")

    st, d = _j(asgi_call(app, "POST", "/api/studora/login", body=json.dumps({"url": SERVICE + "/", "email": "windows@example.org", "password": "sehr-geheim-123"})))
    assert st == 200, d
    assert d["linked"] and d["user"]["email"] == "windows@example.org" and d["url"] == SERVICE
    sha2 = file_sha256(pdf)
    assert d["claims"]["sent"] == 2 and d["claims"]["total"] == 2, "Stud.IP-PDF mit Hash und PDF auf der Platte, nicht das eigene Dokument"
    state = service_link.load_state()
    assert state["token"] and "password" not in json.dumps(state), "nur das Token liegt auf dem PC"
    assert sha2 in service_link.local_fingerprints() and "d" * 64 not in service_link.local_fingerprints()

    # das iPad desselben Dienstes teilt eine Loesung zu derselben PDF
    from app import community
    assert _hosted(app, "POST", "/api/community/claims", {"fingerprints": [FP]}, oh)[0] == 200
    pkg = community.sample_package(FP)
    st, pub = _hosted(app, "POST", "/api/community/solutions", {"package": pkg, "title": "Blatt 0 vom iPad"}, oh)
    assert st == 201, pub
    sid = pub["solution_id"]

    # Windows: suchen, laden, liken, kommentieren - alles ueber dieselben Pfade wie im Dienst
    st, found = _j(asgi_call(app, "GET", f"/api/community/solutions?fingerprint={FP}"))
    assert st == 200 and [s["solution_id"] for s in found["solutions"]] == [sid]
    st, dl = _j(asgi_call(app, "GET", f"/api/community/solutions/{sid}"))
    assert st == 200 and dl["package"]["header"]["solutionId"] == sid
    assert _j(asgi_call(app, "POST", f"/api/community/solutions/{sid}/like"))[0] == 200
    st, c = _j(asgi_call(app, "POST", f"/api/community/solutions/{sid}/comments",
                         body=json.dumps({"text": "Aufgabe 2b: Vorzeichen?", "page_key": "p1", "anchor": {"x": 0.4, "y": 0.25}})))
    assert st == 201, c
    st, lst = _hosted(app, "GET", f"/api/community/solutions/{sid}/comments", headers=oh)
    assert st == 200 and lst["comments"][0]["anchor"] == {"x": 0.4, "y": 0.25}
    st, found = _hosted(app, "GET", f"/api/community/solutions?fingerprint={FP}", headers=oh)
    assert found["solutions"][0]["likes"] == 1 and found["solutions"][0]["comments"] == 1
    assert all(a and a.startswith("Bearer ") for m, p, a in calls if p.startswith("/api/community/")), "jede Weiterleitung mit Token"

    # Fehler des Dienstes kommen unveraendert an (fremde PDF)
    st, e = _j(asgi_call(app, "GET", "/api/community/solutions?fingerprint=" + "9" * 64))
    assert st == 403 and e["code"] == "file_not_owned"

    # abmelden: Token weg, Community meldet "nicht verbunden"
    st, out = _j(asgi_call(app, "POST", "/api/studora/logout"))
    assert st == 200 and not out["linked"] and out["url"] == SERVICE
    assert "token" not in service_link.load_state() and service_link.load_state()["last_email"] == "windows@example.org"
    st, e = _j(asgi_call(app, "GET", "/api/community/info"))
    assert st == 409 and e["code"] == "not_linked"
    assert config.MODE == "local"


def test_expired_token_wrong_password_mismatch_and_bad_urls(service):
    app, _, _ = service
    from app import service_link
    _account(app, "a@example.org")
    _account(app, "hi@example.org", uni="hildesheim")
    st, e = _j(asgi_call(app, "POST", "/api/studora/login", body=json.dumps({"url": SERVICE, "email": "a@example.org", "password": "falsch-falsch-1"})))
    assert st == 401 and e["code"] and not service_link.linked()
    for bad in ("http://studora.example", "ftp://x", "https://u:p@x.example", "https://x.example/?a=1"):
        st, e = _j(asgi_call(app, "POST", "/api/studora/login", body=json.dumps({"url": bad, "email": "a@example.org", "password": "x"})))
        assert st == 400 and e["code"] == "service_url_invalid", bad

    assert _j(asgi_call(app, "POST", "/api/studora/login", body=json.dumps({"url": SERVICE, "email": "a@example.org", "password": "sehr-geheim-123"})))[0] == 200
    s = service_link.load_state()
    s["token"] = "abgelaufen"
    service_link.save_state(s)
    st, e = _j(asgi_call(app, "GET", "/api/community/info"))
    assert st == 401
    st, info = _j(asgi_call(app, "GET", "/api/studora/status"))
    assert not info["linked"] and info["expired"], "abgelaufenes Token wird vergessen, neu anmelden"

    # Konto einer anderen Hochschule: anmelden geht, Melden und Community nicht (keine gemeinsamen PDFs)
    st, d = _j(asgi_call(app, "POST", "/api/studora/login", body=json.dumps({"url": SERVICE, "email": "hi@example.org", "password": "sehr-geheim-123"})))
    assert st == 200 and d["university_mismatch"] and d["claims_error"]["code"] == "university_mismatch"
    st, e = _j(asgi_call(app, "GET", "/api/community/info"))
    assert st == 409 and e["code"] == "university_mismatch"
    st, e = _j(asgi_call(app, "GET", "/api/community/../account/me"))
    assert st in (400, 404, 409)


def test_unreachable_service_is_a_clear_error(service, monkeypatch):
    app, _, _ = service
    from app import service_link
    _account(app, "b@example.org")
    assert _j(asgi_call(app, "POST", "/api/studora/login", body=json.dumps({"url": SERVICE, "email": "b@example.org", "password": "sehr-geheim-123"})))[0] == 200

    def down(*a, **k):
        raise OSError("Verbindung abgelehnt")
    monkeypatch.setattr(service_link, "transport", down)
    st, e = _j(asgi_call(app, "GET", "/api/community/info"))
    assert st == 502 and e["code"] == "service_unreachable"
    st, info = _j(asgi_call(app, "GET", "/api/studora/status"))
    assert st == 200 and info["linked"] and info["offline"] and info["user"]["email"] == "b@example.org"


def test_devices_listed_and_signed_out_one_by_one(service):
    """Geraete einzeln abmelden (28.10.2026): im Dienst je Sitzung, aus der Windows-App ueber das Konto."""
    app, _, _ = service
    from app import service_link
    _, ipad = _account(app, "geraete@example.org")
    st, _ = _j(asgi_call(app, "POST", "/api/studora/login", body=json.dumps({"url": SERVICE, "email": "geraete@example.org", "password": "sehr-geheim-123"})))
    assert st == 200
    st, d = _j(asgi_call(app, "GET", "/api/studora/devices"))
    assert st == 200 and len(d["sessions"]) == 2
    me = next(x for x in d["sessions"] if x["current"])
    other = next(x for x in d["sessions"] if not x["current"])
    assert me["device_name"] == "Studora für Windows"
    st, r = _j(asgi_call(app, "DELETE", f"/api/studora/devices/{other['id']}"))
    assert st == 200 and not r["current"]
    assert _hosted(app, "GET", "/api/account/me", headers=ipad)[0] == 401, "das andere Geraet ist abgemeldet"
    st, r = _hosted(app, "DELETE", f"/api/account/sessions/{other['id']}", headers={"Authorization": "Bearer " + service_link.load_state()["token"]})
    assert st == 404 and r["code"] == "session_not_found"
    st, r = _j(asgi_call(app, "DELETE", f"/api/studora/devices/{me['id']}"))
    assert st == 200 and r["current"] and not service_link.linked(), "dieses Geraet: Verbindung getrennt"
