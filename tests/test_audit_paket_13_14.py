"""Audit 08.11.2026, Pakete 13 und 14: Downloads in app/studip_sync.py und das Durchreichen in app/filestream.py.

Je Befund (P13-01 .. P13-12, P14-01 .. P14-12) ein Test: bestaetigte Befunde zuerst rot, dann der Fix; widerlegte oder
nicht erreichbare Befunde festgenagelt. Keine echten Logins und Downloads: lokale http.server-Attrappen und Monkeypatch.
Bericht: docs/audit/AUDIT-2026-11-08-PAKET-13-14.md."""
import http.server
import json
import os
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest
from conftest import asgi_call


# ---------------------------------------------------------------- Hilfen

class _Server:
    """Lokaler HTTP-Server mit festen Antworten je Pfad; merkt sich, wer welche Cookie-Kopfzeile bekam."""

    def __init__(self, routes):
        self.routes, self.seen = routes, []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                outer.seen.append({"host": self.headers.get("Host"), "path": self.path, "cookie": self.headers.get("Cookie")})
                status, headers, body = outer.routes.get(self.path, (404, {}, b""))
                self.send_response(status)
                for k, v in headers.items():
                    self.send_header(k, v.replace("{port}", str(outer.port)))
                self.end_headers()
                self.wfile.write(body)
                self.close_connection = True
            do_POST = do_GET

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


@pytest.fixture
def server():
    made = []

    def make(routes):
        s = _Server(routes)
        made.append(s)
        return s
    yield make
    for s in made:
        s.close()


@pytest.fixture
def course(app, tmp_path, monkeypatch):
    """PC-Betriebsart (store) mit eigenem Dateiordner und einem Kurs."""
    from app import config, db, studip_sync
    monkeypatch.setattr(config, "FILES_MODE", "store")
    monkeypatch.setattr(studip_sync, "FILES_DIR", tmp_path / "files")
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c-a13', 'Audit Kurs', 'vorlesung', 1, '2026-11-08')")
        conn.execute("DELETE FROM files WHERE course_id='c-a13'")
    yield {"id": "c-a13", "title": "Audit Kurs"}
    with db.cursor() as conn:
        conn.execute("DELETE FROM files WHERE course_id='c-a13'")
        conn.execute("DELETE FROM courses WHERE id='c-a13'")


def _file(fid, name="Folien.pdf", chdate=100, url=None, size=None):
    return {"id": fid, "name": name, "size": size, "mime": "application/pdf", "author": "Dozentin", "chdate": chdate,
            "download_url": url or f"https://studip.example/sendfile.php?file_id={fid}"}


def _writer(content: bytes, fail_for=(), delay=0.0):
    def dl(url, target: Path, size=0):
        if any(x in url for x in fail_for):
            raise RuntimeError("HTTP 500")
        if delay:
            time.sleep(delay)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    return dl


def _store(course, files, dl, new=None):
    from app import db, studip_sync
    with db.cursor() as conn:
        return studip_sync.store_course_files(conn, course, files, {}, dl, "2026-11-08", new if new is not None else [], pause=0)


def _row(fid):
    from app import db
    with db.cursor() as conn:
        return db.row(conn, "SELECT * FROM files WHERE id=?", (fid,))


# ================================================================= PAKET 13

def test_p13_01_store_course_files_reports_failed_downloads(course):
    res = _store(course, [_file("a1", "A.pdf"), _file("a2", "B.pdf")], _writer(b"%PDF-1.4 x", fail_for=("a2",)))
    assert res["downloaded"] == 1 and res["failed"] == 1 and res["failed_ids"] == ["a2"]
    assert _row("a1")["local_path"] and not _row("a2")["local_path"]


def test_p13_02_older_semester_not_finished_after_download_error(course, monkeypatch):
    from app import db, older_semesters, studip_sync, sync_order
    finished = []
    monkeypatch.setattr(older_semesters, "pending", lambda conn: {"c-old"})
    monkeypatch.setattr(older_semesters, "finish", lambda conn, ids, now: finished.extend(ids) or list(ids))
    monkeypatch.setattr(sync_order, "older_continue", lambda pause=None: True)
    monkeypatch.setattr(studip_sync, "fetch_files", lambda page, cid: [_file("o1", "Alt.pdf"), _file("o2", "Alt2.pdf")])
    monkeypatch.setattr(studip_sync, "fetch_folder_paths", lambda page, cid: {})

    def download(page, url, target, size=0):
        if "o2" in url:
            raise RuntimeError("Download fehlgeschlagen (500)")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF-1.4 alt")
    monkeypatch.setattr(studip_sync, "download", download)
    old = {"id": "c-old", "title": "Alter Kurs", "semester": "WiSe 2024/25"}
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c-old', 'Alter Kurs', 'vorlesung', 0, '2026-11-08')")
        studip_sync.sync_older_files(None, conn, [old], "2026-11-08", [])
    assert finished == [], "ein Downloadfehler: der Kurs bleibt offen und wird erneut versucht"
    monkeypatch.setattr(studip_sync, "download", lambda page, url, target, size=0: target.write_bytes(b"%PDF-1.4 alt"))
    with db.cursor() as conn:
        studip_sync.sync_older_files(None, conn, [old], "2026-11-08", [])
        conn.execute("DELETE FROM files WHERE course_id='c-old'"); conn.execute("DELETE FROM courses WHERE id='c-old'")
    assert finished == ["c-old"], "ohne Fehler fertig"


def test_p13_03_unique_part_file_does_not_clobber_parallel_writer(tmp_path, server):
    from app import studip_sync
    s = server({"/f": (200, {"Content-Length": "9"}, b"%PDF-neu!")})
    target = tmp_path / "Folien.pdf"
    foreign = target.with_name(target.name + ".part")
    foreign.write_bytes(b"fremd")                      # .part eines gleichzeitigen zweiten Abgleichs
    studip_sync._stream_once(urllib.request.Request(f"http://127.0.0.1:{s.port}/f"), target, "Folien.pdf", 10)
    assert target.read_bytes() == b"%PDF-neu!"
    assert foreign.read_bytes() == b"fremd", "die Temp-Datei des anderen Laufs bleibt unberuehrt"
    assert sorted(p.name for p in tmp_path.iterdir()) == ["Folien.pdf", "Folien.pdf.part"], "keine Reste"


def test_p13_03_parallel_syncs_same_name_get_distinct_paths(course):
    from app import db, studip_sync
    errors = []

    def run(fid, content):
        try:
            with db.cursor() as conn:
                studip_sync.store_course_files(conn, course, [_file(fid, "Gleich.pdf")], {}, _writer(content, delay=0.2),
                                               "2026-11-08", [], pause=0)
        except Exception as e:  # noqa: BLE001
            errors.append(e)
    ts = [threading.Thread(target=run, args=("p1", b"%PDF eins")), threading.Thread(target=run, args=("p2", b"%PDF zwei"))]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert not errors
    p1, p2 = _row("p1")["local_path"], _row("p2")["local_path"]
    assert p1 and p2 and p1 != p2
    assert Path(p1).read_bytes() == b"%PDF eins" and Path(p2).read_bytes() == b"%PDF zwei"


def test_p13_03_parallel_renamed_files_get_distinct_paths(course):
    """Zwei vorhandene Dateien bekommen im selben Moment denselben neuen Namen (neuere Fassung): ohne Schreibzugriff
    vor dem Download (P13-04) darf die Kollisionspruefung trotzdem nicht beide auf denselben Pfad legen."""
    from app import db, studip_sync
    _store(course, [_file("r1", "Erst1.pdf"), _file("r2", "Erst2.pdf")], _writer(b"%PDF alt"))
    errors = []

    def run(fid, content):
        try:
            with db.cursor() as conn:
                studip_sync.store_course_files(conn, course, [_file(fid, "Gleich2.pdf", chdate=200)], {},
                                               _writer(content, delay=0.3), "2026-11-08", [], pause=0)
        except Exception as e:  # noqa: BLE001
            errors.append(e)
    ts = [threading.Thread(target=run, args=("r1", b"%PDF eins")), threading.Thread(target=run, args=("r2", b"%PDF zwei"))]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert not errors
    p1, p2 = _row("r1")["local_path"], _row("r2")["local_path"]
    assert p1 != p2 and Path(p1).read_bytes() == b"%PDF eins" and Path(p2).read_bytes() == b"%PDF zwei"


def test_p13_04_failed_download_keeps_old_metadata(course):
    _store(course, [_file("m1", "Alt.pdf", chdate=100, url="https://studip.example/alt")], _writer(b"%PDF alt"))
    _store(course, [_file("m1", "Neu.pdf", chdate=200, url="https://studip.example/neu-a1")], _writer(b"x", fail_for=("neu",)))
    r = _row("m1")
    assert (r["name"], r["download_url"], r["chdate"]) == ("Alt.pdf", "https://studip.example/alt", 100)
    assert Path(r["local_path"]).read_bytes() == b"%PDF alt"
    _store(course, [_file("m1", "Neu.pdf", chdate=200, url="https://studip.example/neu-a1")], _writer(b"%PDF neu"))
    r = _row("m1")
    assert (r["name"], r["download_url"], r["chdate"]) == ("Neu.pdf", "https://studip.example/neu-a1", 200)


class _FakeResp:
    def __init__(self, body=b"", headers=None, status=200):
        self._body, self.headers, self.status, self.ok = body, headers or {}, status, 200 <= status < 300

    def body(self):
        if self._body is None:
            raise AssertionError("body() darf bei zu grosser Datei nicht gelesen werden")
        return self._body

    def dispose(self):
        pass


def _fallback(monkeypatch, resp):
    from app import studip_sync

    def no_stream(*a, **k):
        raise RuntimeError("Cookie-Eigenheit")
    monkeypatch.setattr(studip_sync, "stream_download", no_stream)

    class Page:
        class request:  # noqa: N801
            @staticmethod
            def get(url):
                return resp
    return Page()


def test_p13_05_fallback_refuses_huge_file_before_reading_body(tmp_path, monkeypatch):
    from app import studip_sync
    page = _fallback(monkeypatch, _FakeResp(None, {"content-length": str(studip_sync.FALLBACK_MAX_BYTES + 1)}))
    host = studip_sync.download_hosts().pop()
    with pytest.raises(RuntimeError, match="zu groß"):
        studip_sync.download(page, f"https://{host}/sendfile.php?file_id=1", tmp_path / "x.pdf")
    assert not (tmp_path / "x.pdf").exists()


def test_p13_06_short_stream_body_is_not_stored(tmp_path, server):
    from app import studip_sync
    s = server({"/f": (200, {"Content-Length": "1000"}, b"%PDF" + b"x" * 96)})
    target = tmp_path / "Kurz.pdf"
    with pytest.raises(Exception, match="unvollst"):
        studip_sync._stream_once(urllib.request.Request(f"http://127.0.0.1:{s.port}/f"), target, "Kurz.pdf", 10)
    assert not target.exists() and list(tmp_path.iterdir()) == []


def test_p13_06_short_fallback_body_is_not_stored(tmp_path, monkeypatch):
    from app import studip_sync
    page = _fallback(monkeypatch, _FakeResp(b"%PDF kurz", {"content-length": "5000"}))
    host = studip_sync.download_hosts().pop()
    with pytest.raises(RuntimeError, match="unvollst"):
        studip_sync.download(page, f"https://{host}/sendfile.php?file_id=1", tmp_path / "x.pdf")
    assert not (tmp_path / "x.pdf").exists()


def test_p13_06_stored_size_contract_unchanged(course):
    """Festgenagelt (Designfrage): gespeichert wird die Groesse laut Quelle, ohne Angabe die der geladenen Datei
    (Vertrag, tests/test_regressions.py). Die Vollstaendigkeit prueft der Download ueber Content-Length."""
    _store(course, [_file("s1", "Groesse.pdf", size=999)], _writer(b"%PDF-1.4 12"))
    _store(course, [_file("s2", "OhneGroesse.pdf", size=None)], _writer(b"%PDF-1.4 12"))
    assert (_row("s1")["size"], _row("s2")["size"]) == (999, len(b"%PDF-1.4 12"))


def test_p13_07_download_allowed_checks_port():
    from app import studip_sync
    host = studip_sync.download_hosts().pop()
    assert studip_sync.download_allowed(f"https://{host}/x") and studip_sync.download_allowed(f"https://{host}:443/x")
    for bad in (f"https://{host}:4443/x", f"https://{host}:80/x", f"https://{host}:0/x"):
        assert not studip_sync.download_allowed(bad), bad
    assert not studip_sync.download_allowed(f"https://{host}:99999/x"), "ungueltiger Port: nicht erlaubt, kein Absturz"


def test_p13_08_tokens_never_in_error_messages_or_log(tmp_path, monkeypatch):
    from app import studip_sync
    host = studip_sync.download_hosts().pop()
    url = f"https://{host}/sendfile.php?file_id=1&token=GEHEIM123#frag"

    def http_500(*a, **k):
        raise urllib.error.HTTPError(url, 500, "Fehler", {}, None)
    monkeypatch.setattr(studip_sync, "_stream_once", http_500)
    with pytest.raises(RuntimeError) as ei:
        studip_sync.stream_download(None, url, tmp_path / "x.pdf")
    assert "GEHEIM123" not in str(ei.value) and "sendfile.php" in str(ei.value)
    logged = []
    monkeypatch.setattr(studip_sync, "log", logged.append)
    page = _fallback(monkeypatch, _FakeResp(b"", status=500))
    with pytest.raises(RuntimeError) as ei:
        studip_sync.download(page, url, tmp_path / "x.pdf")
    assert "GEHEIM123" not in str(ei.value) + " ".join(logged)
    assert studip_sync.log_url("https://nutzer:pw@h.example/a/b?x=1#y") == "https://h.example/a/b"


def test_p13_09_safe_name_keeps_extension_and_collisions_get_distinct_paths(course):
    from app import studip_sync
    long = "Ü" * 200 + ".pdf"
    n = studip_sync.safe_name(long)
    assert len(n) <= 120 and n.endswith(".pdf")
    assert studip_sync.safe_name("ä.pdf") == studip_sync.safe_name("ä.pdf")       # NFC
    # zwei verschiedene Namen, ein lokaler Name: der zweite bekommt die Datei-ID angehaengt (nacheinander)
    _store(course, [_file("k1", "Blatt:1.pdf"), _file("k2", "Blatt?1.pdf")], _writer(b"%PDF k"))
    assert _row("k1")["local_path"] != _row("k2")["local_path"]


def test_p13_10_pdf_kind_only_with_pdf_signature(course):
    _store(course, [_file("z1", "Keine.pdf")], _writer(b"PK\x03\x04 eigentlich ein ZIP"))
    _store(course, [_file("z2", "Echt.pdf")], _writer(b"%PDF-1.7\n..."))
    assert _row("z1")["kind"] == "file" and _row("z2")["kind"] == "pdf"


class _HtmlResp:
    status, ok = 200, True

    def __init__(self, text, url=None):
        from app import studip_sync
        self._t, self.url = text, url or f"{studip_sync.STUDIP_BASE}/dispatch.php/course/files/flat?cid=c1"

    def text(self):
        return self._t


def _page(resp):
    class Page:
        class request:  # noqa: N801
            @staticmethod
            def get(url, headers=None):
                return resp
    return Page()


def test_p13_11_login_page_is_not_an_empty_file_list():
    from app import studip_sync
    login = '<html><form action="/Shibboleth.sso/Login"><input type="password" name="password"></form></html>'
    with pytest.raises(studip_sync.FileListUnreadable):
        studip_sync.fetch_files(_page(_HtmlResp(login)), "c1")
    with pytest.raises(studip_sync.FileListUnreadable):
        studip_sync.fetch_files(_page(_HtmlResp("<html>x</html>", url=studip_sync.LOGIN_URL)), "c1")
    assert studip_sync.fetch_files(_page(_HtmlResp('<div data-files="[]"></div>')), "c1") == []
    # Kurs ohne Dateibereich (keine Anmeldeseite, kein data-files): wie bisher leer, kein Fehler (Designfrage im Bericht)
    assert studip_sync.fetch_files(_page(_HtmlResp("<html><body>Keine Dateien</body></html>")), "c1") == []


def test_p13_12_user_agent_cache_is_bounded():
    from app import studip_sync
    studip_sync._UA.clear()

    class P:
        def __init__(self):
            self.context = object()

        def evaluate(self, js):
            return "UA"
    keep = [P() for _ in range(200)]
    for p in keep:
        assert studip_sync._user_agent(p) == "UA"
    assert len(studip_sync._UA) <= studip_sync.UA_CACHE_MAX


# ================================================================= PAKET 14

def test_p14_01_filestream_redirect_to_foreign_host_refused_without_cookie(server):
    from app import filestream
    s = server({"/r": (302, {"Location": "http://localhost:{port}/t"}, b""), "/t": (200, {}, b"%PDF"),
                "/same": (302, {"Location": "/t"}, b"")})
    with pytest.raises(filestream.StreamError) as ei:
        filestream._http(f"http://127.0.0.1:{s.port}/r", cookie="Seminar_Session=geheim")
    assert ei.value.code == "redirect_refused"
    assert [x["path"] for x in s.seen] == ["/r"], "der fremde Host bekommt keine Anfrage (und kein Cookie)"
    data, _ = filestream._http(f"http://127.0.0.1:{s.port}/same", cookie="Seminar_Session=geheim")
    assert data == b"%PDF" and s.seen[-1]["cookie"] == "Seminar_Session=geheim", "Weiterleitung auf demselben Host geht"


def test_p14_02_fetch_refuses_foreign_download_url(app, monkeypatch):
    from app import filestream
    called = []
    monkeypatch.setattr(filestream, "_http", lambda *a, **k: called.append(a) or (b"%PDF", "application/pdf"))
    monkeypatch.setattr(filestream, "studip_cookie_header", lambda base: "Seminar_Session=geheim")
    for bad in ("https://boese.example/x.pdf", "http://studip.uni-hannover.de/x", "file:///etc/passwd",
                "https://127.0.0.1/x", "https://studip.uni-hannover.de:8443/x"):
        with pytest.raises(filestream.StreamError) as ei:
            filestream.fetch({"id": "f1", "download_url": bad})
        assert ei.value.code == "source_not_allowed", bad
    assert called == []
    from app import studip_sync
    host = studip_sync.download_hosts().pop()
    assert filestream.fetch({"id": "f1", "download_url": f"https://{host}/sendfile.php?file_id=1"})[0] == b"%PDF"


def test_p14_03_cookie_domain_needs_dot_boundary(monkeypatch):
    from app import filestream, unilogin
    jar = [{"name": "gut", "value": "1", "domain": ".uni-hannover.de"},
           {"name": "genau", "value": "2", "domain": "studip.uni-hannover.de"},
           {"name": "fremd", "value": "3", "domain": "annover.de"},
           {"name": "ohne", "value": "4"}]
    monkeypatch.setattr(unilogin, "saved_cookies", lambda name: jar)
    assert filestream.cookie_header("X", "https://studip.uni-hannover.de/") == "gut=1; genau=2; ohne=4"
    assert filestream.cookie_header("X", "https://evil-uni-hannover.de/") == "ohne=4"


def test_p14_04_full_sync_reports_failed_downloads(course, monkeypatch):
    from app import db, studip_sync, sync_order

    class Ctx:
        def new_page(self):
            class Page:
                class request:  # noqa: N801
                    @staticmethod
                    def get(*a, **k):
                        raise RuntimeError("kein Netz in Tests")
            return Page()

        def cookies(self):
            return []

        def close(self):
            pass

    class PW:
        def __enter__(self):
            return type("P", (), {"chromium": type("C", (), {"launch_persistent_context": staticmethod(lambda *a, **k: Ctx())})()})()

        def __exit__(self, *a):
            return False
    c = {"id": "c-a13", "title": "Audit Kurs", "number": "1", "semester": "WiSe 2026/27"}
    monkeypatch.setattr(studip_sync, "sync_playwright", lambda: PW())
    monkeypatch.setattr(studip_sync, "login", lambda page: None)
    monkeypatch.setattr(studip_sync, "fetch_courses", lambda page: [c])
    monkeypatch.setattr(studip_sync, "fetch_events", lambda page, cid: [])
    monkeypatch.setattr(studip_sync, "fetch_news", lambda page, cid: None)
    monkeypatch.setattr(studip_sync, "fetch_files", lambda page, cid: [_file("v1", "V1.pdf"), _file("v2", "V2.pdf")])
    monkeypatch.setattr(studip_sync, "fetch_folder_paths", lambda page, cid: {})
    monkeypatch.setattr(sync_order, "split", lambda *a, **k: {"current": [c], "upcoming": [], "older": []})

    def download(page, url, target, size=0):
        if "v2" in url:
            raise RuntimeError("Download fehlgeschlagen (500)")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF v1")
    monkeypatch.setattr(studip_sync, "download", download)
    res = studip_sync.run_studip_sync()
    assert res["ok"] and res["failed_downloads"] == 1 and "1 Datei nicht geladen" in res["message"]
    with db.cursor() as conn:
        assert "nicht geladen" in db.row(conn, "SELECT message FROM sync_log ORDER BY id DESC LIMIT 1")["message"]


def test_p14_05_cache_key_includes_revision_and_source(app, monkeypatch):
    from app import db, filestream
    filestream.forget()
    answers = [(b"%PDF eins", "application/pdf"), (b"%PDF zwei", "application/pdf")]
    monkeypatch.setattr(filestream, "fetch", lambda f: answers.pop(0))
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c-a14', 'K', 'vorlesung', 1, '2026-11-08')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, download_url, chdate, revision) "
                     "VALUES ('lw-c1', 'c-a14', 'a.txt', 'file', 'neu', 'https://lw.example/pluginfile.php/1/a.txt', 100, 1)")
    with db.cursor() as conn:
        assert filestream.content(conn, "lw-c1")[0] == b"%PDF eins"
        conn.execute("UPDATE files SET revision=2, download_url='https://lw.example/pluginfile.php/2/a.txt' WHERE id='lw-c1'")
        assert filestream.content(conn, "lw-c1")[0] == b"%PDF zwei", "neue Revision bei gleichem chdate: kein alter Inhalt"
        conn.execute("DELETE FROM files WHERE id='lw-c1'"); conn.execute("DELETE FROM courses WHERE id='c-a14'")
    filestream.forget()


def test_p14_06_hosted_service_never_fetches_from_university(app, monkeypatch):
    """P14-06/P14-07: das Durchreichen (bis 300 MiB im Speicher) ist im Dienst nicht erreichbar: ohne gemerkte Sitzung
    (Tresor seit 06.11.2026 leer) endet jeder Abruf mit 410, bevor eine Verbindung aufgebaut wird."""
    from app import config, filestream, vault
    monkeypatch.setattr(config, "MODE", "hosted")
    monkeypatch.setattr(vault, "env_for", lambda uid: {})
    monkeypatch.setattr(filestream, "_http", lambda *a, **k: (_ for _ in ()).throw(AssertionError("kein Abruf im Dienst")))
    t = config.set_user_context("a" * 32, "luh")
    try:
        from app import studip_sync
        host = studip_sync.download_hosts().pop()
        for row in ({"id": "f1", "download_url": f"https://{host}/sendfile.php?file_id=1"},
                    {"id": "lw-1", "download_url": "https://www.uni-hildesheim.de/learnweb2025/pluginfile.php/1/a.pdf"}):
            with pytest.raises(filestream.StreamError) as ei:
                filestream.fetch(row)
            assert (ei.value.code, ei.value.status) == ("credentials_not_stored", 410)
        with pytest.raises(vault.CredentialsNotStored):
            vault.set_values("a" * 32, {"STUDIP_COOKIES": "[]x"})
    finally:
        config.reset_user_context(t)


def test_p14_08_forget_is_per_file_and_harmless(app):
    from app import filestream
    filestream.forget()
    with filestream._lock:
        filestream._cache[("u1", "f1", 1, None, "x")] = (time.time(), b"a", "m", "s")
        filestream._cache[("u2", "f1", 1, None, "x")] = (time.time(), b"b", "m", "s")
        filestream._cache[("u1", "f2", 1, None, "x")] = (time.time(), b"c", "m", "s")
    filestream.forget("f1")
    assert list(filestream._cache) == [("u1", "f2", 1, None, "x")], "nur Eintraege dieser Datei-ID (alle Konten), sonst nichts"
    filestream.forget()


def test_p14_12_streamed_html_labelled_file_is_attachment_with_nosniff(app, monkeypatch):
    from app import config, db, filestream
    monkeypatch.setattr(config, "FILES_MODE", "stream")
    monkeypatch.setattr(filestream, "content", lambda conn, fid: (b"<script>alert(1)</script>", "text/html", "x"))
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, active, created_at) VALUES ('c-a14b', 'K', 'vorlesung', 1, '2026-11-08')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, download_url, mime) "
                     "VALUES ('h1', 'c-a14b', 'seite.html', 'file', 'neu', 'https://studip.example/x', 'text/html')")
    st, hdr, body = asgi_call(app, "GET", "/api/files/h1/content")
    h = {k.decode(): v.decode() for k, v in hdr}
    assert st == 200 and h["content-type"].startswith("application/octet-stream") and h["content-disposition"].startswith("attachment")
    assert h["x-content-type-options"] == "nosniff"
    with db.cursor() as conn:
        conn.execute("DELETE FROM files WHERE id='h1'"); conn.execute("DELETE FROM courses WHERE id='c-a14b'")
