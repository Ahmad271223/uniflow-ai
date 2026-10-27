"""Betriebsart LERNAPP_FILES=stream (Standard im Dienst): der Abgleich merkt nur die Dateiliste, der Inhalt wird beim
Oeffnen mit der Hochschulsitzung des Kontos durchgereicht, nichts landet auf der Platte; behalten werden Fingerabdruck
und Seitentext. Abgelaufene Stud.IP-Sitzung -> einmal neu anmelden; Learnweb ueber den Schluessel. Am PC (store)
aendert sich nichts."""
import hashlib
import io
import json
import time

import pytest
from conftest import asgi_call

def _pdf(text: str = "Hallo Netzwerk") -> bytes:
    """Kleinstes gueltiges PDF mit einer Textseite (richtige Querverweistabelle, damit pypdf den Text liest)."""
    stream = f"BT /F1 24 Tf 72 720 Td ({text}) Tj ET".encode()
    objs = [b"<</Type/Catalog/Pages 2 0 R>>", b"<</Type/Pages/Kids[3 0 R]/Count 1>>",
            b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>",
            b"<</Length " + str(len(stream)).encode() + b">>stream\n" + stream + b"\nendstream",
            b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>"]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + o + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += f"trailer\n<</Size {len(objs) + 1}/Root 1 0 R>>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)


MIN_PDF = _pdf()
LOGIN_HTML = b"<!DOCTYPE html><html><body>Anmeldung Stud.IP</body></html>"


@pytest.fixture
def hosted(app, monkeypatch):
    from app import accounts, config, filestream, vault
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setattr(config, "FILES_MODE", "")
    monkeypatch.setenv("LERNAPP_JOBS", "off")
    for suffix in ("", "-wal", "-shm"):
        accounts.db_path().with_name(accounts.db_path().name + suffix).unlink(missing_ok=True)
    vault.reset_master()
    filestream.forget()
    yield app
    filestream.forget()
    accounts.db_path().unlink(missing_ok=True)


def _user(app, email="s@beispiel.de", uni="luh"):
    st, _, b = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": uni}))
    assert st == 201, b
    d = json.loads(b)
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


def _with_user(user, uni, fn):
    from app import config, db
    t = config.set_user_context(user["id"], uni)
    try:
        db.init_db()
        with db.cursor() as conn:
            return fn(conn)
    finally:
        config.reset_user_context(t)


def _seed(user, uni="luh", file_id="f1", url="https://studip.uni-hannover.de/sendfile.php?type=0&file_id=f1&file_name=Blatt.pdf"):
    def go(conn):
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c1', 'Mathe I', 'vorlesung', 1, '2026-10-27')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, download_url, chdate, size) VALUES (?,?,?,?,?,?,?,?)",
                     (file_id, "c1", "Blatt 3.pdf", "pdf", "neu", url, 1761500000, 0))
    _with_user(user, uni, go)


def _fake_http(monkeypatch, answers):
    """answers: Liste von (bytes, content-type); jeder Aufruf nimmt das naechste. Aufrufe werden gesammelt."""
    from app import filestream
    calls = []

    def http(url, form=None, cookie=""):
        calls.append({"url": url, "form": form, "cookie": cookie})
        data, ctype = answers.pop(0)
        return data, ctype
    monkeypatch.setattr(filestream, "_http", http)
    return calls


def _h(headers, name):
    return [v.decode() for k, v in headers if k == name.encode()]


# ---------------------------------------------------------------- Betriebsart

def test_files_mode_defaults_and_override(app, monkeypatch):
    from app import config
    monkeypatch.setattr(config, "FILES_MODE", "")
    monkeypatch.setattr(config, "MODE", "local")
    assert config.files_mode() == "store"
    monkeypatch.setattr(config, "MODE", "hosted")
    assert config.files_mode() == "stream" and config.streams_files()
    monkeypatch.setattr(config, "FILES_MODE", "store")
    assert config.files_mode() == "store"
    monkeypatch.setattr(config, "FILES_MODE", "unsinn")
    assert config.files_mode() == "store"


# ---------------------------------------------------------------- Abgleich ohne Dateien

def test_sync_keeps_only_the_file_list_in_stream_mode(app, hosted):
    from app import config, studip_sync
    user, _ = _user(hosted)

    def go(conn):
        from app import db
        c = {"id": "c1", "title": "Mathe I"}
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c1', 'Mathe I', 'vorlesung', 1, '2026-10-27')")
        files = [{"id": "f1", "name": "Blatt 1.pdf", "size": 1234, "mime": "application/pdf", "author": "Dozent", "chdate": 1761500000,
                  "download_url": "https://studip.uni-hannover.de/sendfile.php?file_id=f1"}]

        def never(url, target, size):
            raise AssertionError("im Stream-Modus wird nichts heruntergeladen")
        new = []
        studip_sync.store_course_files(conn, c, files, {}, never, "2026-10-27T08:00:00", new, pause=0)
        assert new == ["f1"]
        r = db.row(conn, "SELECT local_path, downloaded_at, content_sha256, size, chdate FROM files WHERE id='f1'")
        assert r["local_path"] is None and r["downloaded_at"] is None and r["content_sha256"] is None and r["size"] == 1234
        conn.execute("UPDATE files SET content_sha256='abc' WHERE id='f1'")
        new = []
        studip_sync.store_course_files(conn, c, files, {}, never, "2026-10-27T15:00:00", new, pause=0)
        assert new == [] and db.row(conn, "SELECT content_sha256 FROM files WHERE id='f1'")["content_sha256"] == "abc", "unveraendert: Hash bleibt"
        files[0]["chdate"] = 1761600000
        new = []
        studip_sync.store_course_files(conn, c, files, {}, never, "2026-10-28T08:00:00", new, pause=0)
        assert new == ["f1"] and db.row(conn, "SELECT content_sha256, chdate FROM files WHERE id='f1'")["content_sha256"] is None, "neue Fassung: Hash verworfen"
        assert not any(p.is_file() for p in config.files_dir().rglob("*")), "keine Datei auf der Platte"
    _with_user(user, "luh", go)


# ---------------------------------------------------------------- Durchreichen

def test_content_is_streamed_hashed_indexed_and_cached(app, hosted, monkeypatch):
    from app import config, vault
    user, h = _user(hosted)
    _seed(user)
    vault.set_values(user["id"], {"STUDIP_COOKIES": json.dumps([{"name": "Seminar_Session", "value": "abc", "domain": "studip.uni-hannover.de", "path": "/", "expires": -1}])})
    calls = _fake_http(monkeypatch, [(MIN_PDF, "application/pdf")])
    st, hdr, body = asgi_call(hosted, "GET", "/api/files/f1/content", headers=h)
    assert st == 200 and body == MIN_PDF and _h(hdr, "content-type")[0].startswith("application/pdf")
    assert "inline" in _h(hdr, "content-disposition")[0] and "private" in _h(hdr, "cache-control")[0]
    assert calls[0]["cookie"] == "Seminar_Session=abc" and calls[0]["form"] is None and "sendfile.php" in calls[0]["url"]

    def check(conn):
        from app import db
        r = db.row(conn, "SELECT content_sha256, size FROM files WHERE id='f1'")
        assert r["content_sha256"] == hashlib.sha256(MIN_PDF).hexdigest() and r["size"] == len(MIN_PDF)
        rows = db.rows(conn, "SELECT page, text FROM page_texts WHERE file_id='f1' ORDER BY page")
        assert len(rows) == 1 and "Hallo Netzwerk" in rows[0]["text"], "Seitentext beim Durchreichen abgelegt"
    _with_user(user, "luh", check)
    assert not any(p.is_file() for p in config.files_dir().rglob("*")), "nichts gespeichert"
    st, _, body = asgi_call(hosted, "GET", "/api/files/f1/content", headers=h)
    assert st == 200 and body == MIN_PDF and len(calls) == 1, "zweiter Abruf aus dem Zwischenspeicher"
    st, _, body = asgi_call(hosted, "GET", "/api/files/f1/pagetext?page=1", headers=h)
    assert st == 200 and "Hallo Netzwerk" in json.loads(body)["text"] and json.loads(body)["pages"] == 1
    st, _, body = asgi_call(hosted, "POST", "/api/files/f1/fingerprint", headers=h)
    assert st == 200 and json.loads(body) == {"sha256": hashlib.sha256(MIN_PDF).hexdigest(), "source": "bekannt"}


def test_expired_studip_session_logs_in_once_and_retries(app, hosted, monkeypatch):
    from app import filestream, vault
    user, h = _user(hosted)
    _seed(user)
    vault.set_values(user["id"], {"STUDIP_COOKIES": json.dumps([{"name": "Seminar_Session", "value": "alt", "domain": "studip.uni-hannover.de", "path": "/", "expires": -1}])})
    calls = _fake_http(monkeypatch, [(LOGIN_HTML, "text/html"), (MIN_PDF, "application/pdf")])
    refreshed = []
    monkeypatch.setattr(filestream, "refresh_studip_session", lambda: refreshed.append(1) or "Seminar_Session=neu")
    st, _, body = asgi_call(hosted, "GET", "/api/files/f1/content", headers=h)
    assert st == 200 and body == MIN_PDF and refreshed == [1]
    assert [c["cookie"] for c in calls] == ["Seminar_Session=alt", "Seminar_Session=neu"]
    # Anmeldung klappt, Stud.IP gibt trotzdem nur HTML: klare Meldung, kein Absturz, nichts gespeichert
    filestream.forget()
    _fake_http(monkeypatch, [(LOGIN_HTML, "text/html"), (LOGIN_HTML, "text/html")])
    st, _, body = asgi_call(hosted, "GET", "/api/files/f1/content", headers=h)
    assert (st, json.loads(body)["code"]) == (409, "university_session_expired")
    # ohne gemerkte Sitzung: direkt neu anmelden, kein Abruf mit leerem Cookie
    filestream.forget()
    vault.set_values(user["id"], {"STUDIP_COOKIES": ""})
    calls = _fake_http(monkeypatch, [(MIN_PDF, "application/pdf")])
    st, _, _ = asgi_call(hosted, "GET", "/api/files/f1/content", headers=h)
    assert st == 200 and [c["cookie"] for c in calls] == ["Seminar_Session=neu"]
    # Anmeldung schlaegt fehl -> 502 mit Code
    filestream.forget()

    def boom():
        raise filestream.StreamError("university_login_failed", "nein", 502)
    monkeypatch.setattr(filestream, "refresh_studip_session", boom)
    st, _, body = asgi_call(hosted, "GET", "/api/files/f1/content", headers=h)
    assert (st, json.loads(body)["code"]) == (502, "university_login_failed")


def test_learnweb_file_uses_the_token_in_the_form(app, hosted, monkeypatch):
    from app import vault
    user, h = _user(hosted, "h@beispiel.de", "hildesheim")
    _seed(user, "hildesheim", "lw-7", "https://learnweb.uni-hildesheim.de/pluginfile.php/7/mod_resource/content/1/Blatt.pdf")
    vault.set_values(user["id"], {"LEARNWEB_TOKEN": "tok123"})
    calls = _fake_http(monkeypatch, [(MIN_PDF, "application/pdf")])
    st, _, body = asgi_call(hosted, "GET", "/api/files/lw-7/content", headers=h)
    assert st == 200 and body == MIN_PDF
    assert calls[0]["form"] == {"token": "tok123"} and "token=" not in calls[0]["url"] and calls[0]["cookie"] == ""


def test_learnweb_without_token_uses_cas_session_and_relogs_once(app, hosted, monkeypatch):
    from app import filestream, vault
    user, h = _user(hosted, "c@beispiel.de", "hildesheim")
    _seed(user, "hildesheim", "lw-8", "https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/8/mod_resource/content/1/Blatt.pdf")
    vault.set_values(user["id"], {"HILDESHEIM_USER": "peev", "HILDESHEIM_PASSWORD": "pw-pw-pw",
                                  "LEARNWEB_COOKIES": json.dumps([{"name": "MoodleSession", "value": "alt", "domain": "www.uni-hildesheim.de", "path": "/", "expires": -1}])})
    calls = _fake_http(monkeypatch, [(LOGIN_HTML, "text/html"), (MIN_PDF, "application/pdf")])
    relogged = []
    real_refresh = filestream.refresh_learnweb_session
    monkeypatch.setattr(filestream, "refresh_learnweb_session", lambda: relogged.append(1) or "MoodleSession=neu")
    st, _, body = asgi_call(hosted, "GET", "/api/files/lw-8/content", headers=h)
    assert st == 200 and body == MIN_PDF and relogged == [1]
    assert [c["cookie"] for c in calls] == ["MoodleSession=alt", "MoodleSession=neu"] and all(c["form"] is None for c in calls)
    # ohne Zugangsdaten und ohne Sitzung: klare Meldung statt Anmeldeversuch (echte refresh-Funktion, kein Playwright)
    filestream.forget()
    vault.set_values(user["id"], {"HILDESHEIM_USER": "", "HILDESHEIM_PASSWORD": "", "LEARNWEB_COOKIES": ""})
    monkeypatch.setattr(filestream, "refresh_learnweb_session", real_refresh)
    monkeypatch.setattr(filestream, "_http", lambda url, form=None, cookie="": (LOGIN_HTML, "text/html"))
    st, _, body = asgi_call(hosted, "GET", "/api/files/lw-8/content", headers=h)
    assert (st, json.loads(body)["code"]) == (409, "university_session_expired")


def test_store_mode_and_own_documents_are_unchanged(app, hosted, monkeypatch, tmp_path):
    from app import config
    user, h = _user(hosted)
    _seed(user)
    # eigenes Dokument (kein Hochschul-Abgleich) wird nie bei der Hochschule geholt
    _with_user(user, "luh", lambda conn: conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES ('own', '__user__', 'Notizbuch.pdf', 'pdf', 'neu')"))
    _with_user(user, "luh", lambda conn: conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('__user__', 'Eigene', 'sonstiges', 1, '2026-10-27')"))
    calls = _fake_http(monkeypatch, [])
    assert asgi_call(hosted, "GET", "/api/files/own/content", headers=h)[0] == 404 and calls == []
    # Betriebsart store im Dienst: keine Datei auf der Platte -> 404, kein Durchreichen
    monkeypatch.setattr(config, "FILES_MODE", "store")
    assert asgi_call(hosted, "GET", "/api/files/f1/content", headers=h)[0] == 404 and calls == []
    # Datei auf der Platte wird in jeder Betriebsart von dort geliefert
    monkeypatch.setattr(config, "FILES_MODE", "")
    p = tmp_path / "Blatt 3.pdf"
    p.write_bytes(MIN_PDF)
    _with_user(user, "luh", lambda conn: conn.execute("UPDATE files SET local_path=? WHERE id='f1'", (str(p),)))
    st, _, body = asgi_call(hosted, "GET", "/api/files/f1/content", headers=h)
    assert st == 200 and body == MIN_PDF and calls == []


def test_local_mode_never_streams(app, monkeypatch):
    from app import config, db
    monkeypatch.setattr(config, "MODE", "local")
    monkeypatch.setattr(config, "FILES_MODE", "")
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c9', 'Kurs', 'vorlesung', 1, '2026-10-27')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, download_url) VALUES ('f9', 'c9', 'x.pdf', 'pdf', 'neu', 'https://studip.uni-hannover.de/sendfile.php?file_id=f9')")
    calls = _fake_http(monkeypatch, [(MIN_PDF, "application/pdf")])
    assert asgi_call(app, "GET", "/api/files/f9/content")[0] == 404 and calls == []
    assert asgi_call(app, "GET", "/api/files/f9/pagetext")[0] == 404
    with db.cursor() as conn:
        conn.execute("DELETE FROM files WHERE id='f9'")


def test_cookie_header_filters_host_and_expiry(monkeypatch):
    from app import config, filestream
    cookies = [{"name": "a", "value": "1", "domain": "studip.uni-hannover.de", "expires": -1},
               {"name": "b", "value": "2", "domain": ".uni-hannover.de", "expires": time.time() + 3600},
               {"name": "alt", "value": "3", "domain": "studip.uni-hannover.de", "expires": time.time() - 10},
               {"name": "fremd", "value": "4", "domain": "example.org", "expires": -1}]
    monkeypatch.setattr(config, "is_hosted", lambda: True)        # Dienst: Sitzung aus dem Tresor (PC: Datei, tests/test_unilogin.py)
    monkeypatch.setattr(config, "secret", lambda k: json.dumps(cookies) if k == "STUDIP_COOKIES" else "")
    assert filestream.studip_cookie_header("https://studip.uni-hannover.de") == "a=1; b=2"
    monkeypatch.setattr(config, "secret", lambda k: "kaputt")
    assert filestream.studip_cookie_header("https://studip.uni-hannover.de") == ""
    assert filestream.looks_like_html(LOGIN_HTML, "application/pdf") and not filestream.looks_like_html(MIN_PDF, "application/pdf")
