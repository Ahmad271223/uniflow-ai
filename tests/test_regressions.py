"""Regressionstests fuer die am 24.10.2026 gefundenen Live-Blocker."""
import hashlib
import json

from conftest import asgi_call


def _add_file(file_id, name, kind="pdf"):
    from app import db
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES ('c1', 'Testkurs', 'uebung', '2026-10-24')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES (?,?,?,?, 'neu')", (file_id, "c1", name, kind))


# -- P1: Nicht-PDF-Dateien wurden als PDF in den Editor geladen ("text/x-python – keine PDF")
def test_file_kind_from_name_and_mime():
    from app.studip_sync import file_kind
    assert file_kind("uebung01.py", "text/x-python") == "file"
    assert file_kind("AlteKlausuren.zip", "application/x-zip-compressed") == "file"
    assert file_kind("Folie.PDF", None) == "pdf"
    assert file_kind("plot.gif", "image/gif") == "image"


def test_db_migration_fixes_old_pdf_kind(app):
    from app import db
    _add_file("f-py", "uebung02.py", kind="pdf")
    _add_file("f-pdf", "blatt.pdf", kind="pdf")
    db.init_db()
    with db.cursor() as conn:
        kinds = dict(conn.execute("SELECT id, kind FROM files WHERE id IN ('f-py','f-pdf')").fetchall())
    assert kinds == {"f-py": "file", "f-pdf": "pdf"}


# -- P0: Datenverlust bei Annotationen (Konflikt, unbekannte Felder)
def test_annotations_conflict_does_not_overwrite(app):
    _add_file("f-ann", "notizen.pdf")
    v1 = {"version": 2, "pages": {"p1": {"objects": [{"id": "a", "type": "stroke", "points": [1, 2, 3, 4]}]}}, "pageOrder": [{"key": "p1", "type": "pdf", "index": 1}]}
    st, _, b = asgi_call(app, "PUT", "/api/files/f-ann/annotations?base_version=0", body=json.dumps(v1))
    assert st == 200 and json.loads(b)["version"] == 1
    stale = {"version": 2, "pages": {"p1": {"objects": []}}, "pageOrder": v1["pageOrder"]}
    st, _, b = asgi_call(app, "PUT", "/api/files/f-ann/annotations?base_version=0", body=json.dumps(stale))
    assert st == 409, "veralteter Stand darf nicht ueberschreiben"
    st, _, b = asgi_call(app, "GET", "/api/files/f-ann/annotations")
    assert len(json.loads(b)["data"]["pages"]["p1"]["objects"]) == 1


def test_deleted_weekly_test_is_not_recreated(app, monkeypatch):
    from datetime import date

    from app import db, planner, study
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, active, weekly_test) VALUES ('Loeschmodul', 1, 1)").lastrowid
        tid = conn.execute("INSERT INTO tests(subject, title, duration_min, questions, created_at, module_id, week_no, auto) "
                           "VALUES ('Loeschmodul', 'Wochentest', 30, '[]', ?, ?, 3, 1)", (db.now_iso(), mid)).lastrowid
    st, _, _ = asgi_call(app, "DELETE", f"/api/tests/{tid}")
    assert st == 200
    # Inhalte in Lehrwoche 3 vorhanden -> ohne Merker wuerde der Sync den Test sofort neu anlegen
    monkeypatch.setattr(study, "semester_start", lambda conn: date(2026, 10, 12))
    monkeypatch.setattr(study, "_file_rows", lambda conn, m: [{"doc_type": "vorlesung", "chdate": 0}] if m == mid else [])
    monkeypatch.setattr(study, "week_index", lambda start, chdate: 3)
    made = []
    monkeypatch.setattr(planner, "create_test", lambda *a, **k: made.append(k.get("module_id")) or 0)
    planner.create_weekly_tests(log=lambda *_: None)
    assert mid not in made, "geloeschter Wochentest wurde neu erstellt"
    with db.cursor() as conn:
        assert not db.row(conn, "SELECT 1 FROM tests WHERE id=?", (tid,))
        conn.execute("UPDATE modules SET active=0 WHERE id=?", (mid,))


def test_annotations_keep_unknown_fields(app):
    _add_file("f-pk", "pk.pdf")
    data = {"version": 2, "format": "uniflow-annotations/1", "pages": {"p1": {"objects": [], "pkdrawing": {"data": "AAEC", "objectsSig": "0"}}}, "pageOrder": [{"key": "p1", "type": "pdf", "index": 1}]}
    asgi_call(app, "PUT", "/api/files/f-pk/annotations?base_version=0", body=json.dumps(data))
    _, _, b = asgi_call(app, "GET", "/api/files/f-pk/annotations")
    got = json.loads(b)["data"]
    assert got["format"] == "uniflow-annotations/1" and got["pages"]["p1"]["pkdrawing"]["data"] == "AAEC"


# -- P1: Zugriff aus dem WLAN nur mit PIN, Fehlversuche begrenzt
def test_lan_pin_guard(app):
    from app import db
    with db.cursor() as conn:
        db.set_setting(conn, "lan_pin", "123456")
    remote = ("192.168.0.77", 5000)
    assert asgi_call(app, "GET", "/api/modules", client=remote)[0] == 401
    assert asgi_call(app, "GET", "/api/modules", client=("127.0.0.1", 5000))[0] == 200
    st, headers, _ = asgi_call(app, "GET", "/api/modules?pin=123456", client=remote)
    assert st == 200 and any(k == b"set-cookie" and b"lernapp_pin=123456" in v for k, v in headers)
    assert asgi_call(app, "GET", "/api/modules", client=remote, cookies="lernapp_pin=123456")[0] == 200
    attacker = ("192.168.0.99", 5000)
    for i in range(8):
        assert asgi_call(app, "GET", f"/api/modules?pin={100000 + i}", client=attacker)[0] == 401
    assert asgi_call(app, "GET", "/api/modules?pin=123456", client=attacker)[0] == 429, "nach 8 Fehlversuchen gesperrt"


# -- P2: Ordner- und Wochenzuordnung (Gruppenuebung, Hoersaaluebung, Altklausuren)
def test_document_type_from_studip_folder():
    from app.study import effective_type, week_hint
    assert effective_type("GU01.pdf", "Gruppenübung", None) == ("uebung", "Gruppenübung")
    assert effective_type("ueb2.pdf", "Zentralübung", "uebung") == ("uebung", "Hörsaalübung")
    assert effective_type("KK1.pdf", "Alte Klausuren/WS 24/25", "klausur") == ("klausur", "Altklausur")
    assert effective_type("KK1aWS2425lsg.pdf", "Alte Klausuren/WS 24/25", "loesung") == ("loesung", "Klausur-Lösung")
    assert effective_type("x.pdf", "Mitschriften Tranche I", None) == ("skript", "Mitschrift")
    assert week_hint("GU01.pdf", "Gruppenübung") == 1
    assert week_hint("02A.pdf", "Vorlesung") == 2
    assert week_hint("Übungsblatt 3.pdf", None) == 3


# -- P2: Skript-Hinweis startete nie, weil die Dokumentabfrage kein Modul lieferte
def test_file_meta_has_module_id(app):
    from app import db
    _add_file("f-mod", "ZU02.pdf")
    with db.cursor() as conn:
        conn.execute("INSERT INTO modules(id, name, created_at) VALUES (77, 'Mathe I', '2026-10-24')")
        conn.execute("UPDATE courses SET module_id=77 WHERE id='c1'")
    st, _, b = asgi_call(app, "GET", "/api/files/f-mod")
    assert st == 200 and json.loads(b)["module_id"] == 77


# -- Datenverlust: "Endgueltig loeschen" einer Kopie loeschte die Datei des Originals mit (Duplikate teilen local_path)
def test_delete_forever_of_duplicate_keeps_shared_file(app, tmp_path):
    from app import db
    pdf = tmp_path / "eigen.pdf"
    pdf.write_bytes(b"%PDF-1.4 Testdokument")
    with db.cursor() as conn:
        conn.execute("INSERT INTO files(id, course_id, name, kind, status, local_path) VALUES ('u-orig', '__user__', 'eigen.pdf', 'pdf', 'gelesen', ?)",
                     (str(pdf),))
    st, _, b = asgi_call(app, "PATCH", "/api/library/files/u-orig", body=json.dumps({"duplicate": True}))
    assert st == 200
    copy = json.loads(b)["id"]
    st, _, _ = asgi_call(app, "PATCH", f"/api/library/files/{copy}", body=json.dumps({"delete_forever": True}))
    assert st == 200
    assert pdf.exists(), "das Original nutzt die Datei noch"
    st, _, _ = asgi_call(app, "PATCH", "/api/library/files/u-orig", body=json.dumps({"delete_forever": True}))
    assert st == 200 and not pdf.exists(), "letztes Dokument: die Datei wird geloescht"


# -- Abgleich: eine neue Fassung ging still verloren, wenn ihr Download scheiterte (chdate stand schon in der Datenbank,
#    der naechste Abgleich hielt die alte Datei fuer aktuell). Seit dem Zusammenfuehren mit dem PC-Stand kommt der
#    Inhalts-Hash (content_sha256) im selben Schritt wie die neue Fassung.
def test_failed_download_of_new_version_is_retried(app, monkeypatch, tmp_path):
    from app import db, studip_sync, timetable
    remote = {"f-sync-1": {"name": "Folien.pdf", "size": 10, "chdate": 1792000000}}
    failing: set = set()
    loaded: list = []

    class Request:
        def get(self, *a, **k):
            raise RuntimeError("kein Netz im Test")

    class Page:
        request = Request()

    class Ctx:
        def new_page(self):
            return Page()

        def close(self):
            pass

    class Chromium:
        def launch_persistent_context(self, *a, **k):
            return Ctx()

    class PW:
        chromium = Chromium()

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def download(page, url, target):
        fid = url.split("/file-refs/")[1].split("/")[0]
        if fid in failing:
            raise RuntimeError("Verbindung abgebrochen")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"%PDF Fassung " + str(remote[fid]["chdate"]).encode())
        loaded.append(fid)

    def fetch_files(page, cid):
        return [{"id": k, "name": v["name"], "size": v["size"], "mime": "application/pdf", "author": None, "chdate": v["chdate"],
                 "download_url": f"https://studip.test/jsonapi.php/v1/file-refs/{k}/content"} for k, v in remote.items()]

    monkeypatch.setattr(studip_sync, "sync_playwright", lambda: PW())
    monkeypatch.setattr(studip_sync, "login", lambda page: None)
    monkeypatch.setattr(studip_sync, "fetch_courses",
                        lambda page: [{"id": "c-sync", "title": "Testkurs Abgleich", "number": None, "semester": ""}])
    monkeypatch.setattr(studip_sync, "fetch_events", lambda page, cid: [])
    monkeypatch.setattr(studip_sync, "fetch_files", fetch_files)
    monkeypatch.setattr(studip_sync, "fetch_folder_paths", lambda page, cid: {})
    monkeypatch.setattr(studip_sync, "download", download)
    monkeypatch.setattr(studip_sync, "classify", lambda title: (None, None))
    monkeypatch.setattr(studip_sync, "SEMESTER_FILTER", "")
    monkeypatch.setattr(studip_sync, "FILES_DIR", tmp_path / "files")
    monkeypatch.setattr(studip_sync.time, "sleep", lambda s: None)
    monkeypatch.setattr(timetable, "auto_import", lambda conn: {"new": 0})

    def row():
        with db.cursor() as conn:
            return dict(db.row(conn, "SELECT chdate, size, local_path, content_sha256 FROM files WHERE id='f-sync-1'"))

    def sha(chdate):
        return hashlib.sha256(b"%PDF Fassung " + str(chdate).encode()).hexdigest()

    assert studip_sync.run_sync()["ok"] and loaded == ["f-sync-1"]
    assert row()["content_sha256"] == sha(1792000000), "Inhalts-Hash mit dem Download (gemeinsame Wochentests)"
    remote["f-sync-1"].update(size=12, chdate=1792100000)
    failing.add("f-sync-1")
    assert studip_sync.run_sync()["ok"]
    r = row()
    assert (r["chdate"], r["size"]) == (1792000000, 10), "neue Fassung erst mit ihrem Download"
    assert r["content_sha256"] == sha(1792000000), "Hash gehoert zur Datei auf der Platte"
    failing.clear()
    assert studip_sync.run_sync()["new_files"] == ["f-sync-1"], "naechster Abgleich laedt die neue Fassung"
    r = row()
    assert (r["chdate"], r["size"], r["content_sha256"]) == (1792100000, 12, sha(1792100000))
    with open(r["local_path"], "rb") as fh:
        assert fh.read() == b"%PDF Fassung 1792100000"
    assert studip_sync.run_sync()["new_files"] == [], "danach unveraendert"
