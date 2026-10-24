"""Regressionstests fuer die am 24.10.2026 gefundenen Live-Blocker."""
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
