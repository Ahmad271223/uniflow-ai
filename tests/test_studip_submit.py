"""Abgeben in Stud.IP aus dem Web-Editor am PC (app/studip_submit.py, 05.11.2026, docs/ABGEBEN-STUDIP-2026-11-05.md):
Regeln wie StudIPSubmit.swift (Dateiname, Ordnerliste mit Hausaufgabenordner zuerst, Fehler, Lizenz), Hochladen genau
einmal, stille Erneuerung bei 401 mit genau einem zweiten Versuch, Verlauf ohne die PDF. Stud.IP ist ersetzt."""
import json

import pytest
from conftest import asgi_call

COURSE = "a" * 32
PDF = b"%PDF-1.4\n% Abgabe\n%%EOF\n"


def _j(res):
    st, _, b = res
    return st, (json.loads(b) if b else None)


def _folder(i, name, typ, writable, parent=None, visible=True):
    f = {"id": i, "type": "folders", "attributes": {"name": name, "folder-type": typ, "is-visible": visible}}
    if writable is not None:
        f["attributes"]["is-writable"] = writable
    if parent:
        f["relationships"] = {"parent": {"data": {"type": "folders", "id": parent}}}
    return f


FOLDERS = [
    _folder("root", "Analysis I Übung", "RootFolder", True),
    _folder("f-ueb", "Übungen", "StandardFolder", True, "root"),
    _folder("f-b3", "Abgabe Blatt 3", "StandardFolder", True, "f-ueb"),
    _folder("f-hw", "Hausaufgaben", "HomeworkFolder", True, "root"),
    _folder("f-zu", "Abgabe Blatt 1", "TimedFolder", False, "root"),
    _folder("f-ro", "Folien", "StandardFolder", False, "root"),
    _folder("f-alt", "Alt", "StandardFolder", None, "root"),
    _folder("f-hid", "Versteckt", "StandardFolder", True, "root", visible=False),
]


def test_rules_like_the_swift_core():
    from app import studip_submit as S
    assert S.proposed_file_name("Müller", "Übungsblatt 03") == "Mueller_Blatt3.pdf"
    assert S.proposed_file_name("Beispiel", "Blatt_07 Analysis") == "Beispiel_Blatt7.pdf"
    assert S.proposed_file_name("", "Sheet 2") == "Blatt2.pdf"
    assert S.proposed_file_name("Beispiel", "Mitschrift Lineare Algebra.pdf") == "Beispiel_Mitschrift_Lineare_Algebra.pdf"
    assert S.final_file_name("  Mein Name/ä.pdf ") == "Mein_Name_ae.pdf" and S.final_file_name(" .pdf") is None
    f = S.folders(FOLDERS, COURSE)
    assert [x["label"] for x in f["writable"]] == ["Hausaufgaben", "Übungen/Abgabe Blatt 3", "Übungen", "Hauptordner"]
    assert f["suggested"] == "f-hw"
    assert [x["id"] for x in f["closed"]] == ["f-zu"], "nur Abgabeordner als geschlossen; ohne is-writable nie"
    assert S.upload_error(201, b"") is None
    assert S.upload_error(413, b"").code == "too_large"
    assert S.upload_error(403, b"CSRF").code == "security_token"
    assert S.upload_error(403, b"Datei zu gross").code == "too_large"
    assert S.upload_error(403, b"").code == "not_writable" and S.upload_error(500, b"").code == "http"
    assert S.file_ref_id("https://x/jsonapi.php/v1/file-refs/r9", b"") == "r9"
    assert S.own_work_license_id([{"id": "FREE"}, {"id": "SELFMADE_NONPUB"}]) == "SELFMADE_NONPUB"
    assert S.own_work_license_id([{"id": "x7", "attributes": {"name": "Selbst verfasstes, nicht publiziertes Werk"}}]) == "x7"
    assert S.size_notice(8 * 1024 * 1024) == "Die Datei ist 8,0 MB groß. Manche Stud.IP-Ordner nehmen nur bis 7 MB an."
    body = S.multipart_body("B", 'a"b.pdf', "application/pdf", PDF)
    assert b'name="file"; filename="ab.pdf"' in body and PDF in body and body.endswith(b"\r\n--B--\r\n")


class FakeStudIP:
    def __init__(self):
        self.calls = []
        self.upload_status = [201]

    def __call__(self, method, url, headers, body):
        from app.studip_live import Reply
        self.calls.append((method, url, headers, body))
        assert headers.get("Cookie")
        J = "application/vnd.api+json"
        if url.endswith("/users/me"):
            return Reply(200, json.dumps({"data": {"id": "me", "attributes": {"family-name": "Müller"}}}).encode(), J)
        if f"/courses/{COURSE}/folders" in url:
            return Reply(200, json.dumps({"data": FOLDERS}).encode(), J)
        if "/terms-of-use" in url and method == "GET":
            return Reply(200, json.dumps({"data": [{"id": "SELFMADE_NONPUB"}]}).encode(), J)
        if method == "PATCH":
            return Reply(204)
        if method == "POST" and "/file-refs" in url:
            st = self.upload_status.pop(0) if self.upload_status else 201
            if st == 201:
                return Reply(201, b"", J, location="https://studip.uni-hannover.de/jsonapi.php/v1/file-refs/ref1")
            return Reply(st, b"", "text/plain")
        return Reply(404)

    def uploads(self):
        return [c for c in self.calls if c[0] == "POST"]


@pytest.fixture
def studip(app, monkeypatch, tmp_path):
    from app import db, studip_live, studip_messages
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "abgeben.db")
    db.init_db()
    monkeypatch.setattr(studip_messages, "stud_ip_offered", lambda: True)
    monkeypatch.setattr(studip_messages, "stud_ip_connected", lambda: True)
    fake = FakeStudIP()
    fake.renewals = []
    monkeypatch.setattr(studip_live, "_send", fake)
    monkeypatch.setattr(studip_live, "_cookie", lambda: "Seminar_Session=alt")
    monkeypatch.setattr(studip_live, "_renew", lambda: fake.renewals.append(1) or "Seminar_Session=neu")
    with db.cursor() as conn:
        conn.execute("INSERT INTO modules(id, name, created_at) VALUES (1, 'Analysis I', 't')")
        conn.execute("INSERT INTO courses(id, title, kind, module_id, active, created_at) VALUES (?, 'Analysis I Übung', 'uebung', 1, 1, 't')", (COURSE,))
        conn.execute("INSERT INTO courses(id, title, kind, module_id, active, created_at) VALUES (?, 'Analysis I', 'vorlesung', 1, 1, 't')", ("b" * 32,))
        conn.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES ('lw-1', 'Learnweb', 'vorlesung', 1, 't')")
        conn.execute("INSERT INTO files(id, course_id, name, title) VALUES ('f1', ?, 'Übungsblatt 3.pdf', 'Übungsblatt 3')", ("b" * 32,))
    return fake


def _multipart(fields, pdf=PDF):
    b = "XyZ"
    parts = [f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields.items()]
    parts.append(f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="x.pdf"\r\nContent-Type: application/pdf\r\n\r\n'.encode() + pdf + b"\r\n")
    return b"".join(parts) + f"--{b}--\r\n".encode(), f"multipart/form-data; boundary={b}"


def _submit(app, **kw):
    fields = {"course_id": COURSE, "folder_id": "f-hw", "file_name": "Mueller_Blatt3", "document_id": "f1", "with_notes": "1", "pages": "6"}
    fields.update(kw)
    body, ct = _multipart(fields)
    return _j(asgi_call(app, "POST", "/api/studip/submit", body=body, content_type=ct))


def test_info_and_folders(app, studip):
    st, d = _j(asgi_call(app, "GET", "/api/studip/submit?file_id=f1"))
    assert st == 200 and [c["id"] for c in d["courses"]] == ["b" * 32, COURSE], "nur Stud.IP-Kennungen, Modul oben"
    assert d["suggested_course"] == "b" * 32 and d["title"] == "Übungsblatt 3" and d["warning"].startswith("Die Datei wird")
    st, d = _j(asgi_call(app, "GET", f"/api/studip/submit/folders?course_id={COURSE}&title=%C3%9Cbungsblatt%203"))
    assert st == 200 and d["suggested"] == "f-hw" and d["file_name"] == "Mueller_Blatt3.pdf"
    assert d["writable"][0]["web_url"].endswith(f"/dispatch.php/course/files/index/f-hw?cid={COURSE}")
    assert all(c[0] == "GET" for c in studip.calls), "Ordner lesen schreibt nichts"


def test_submit_uploads_once_sets_license_and_logs(app, studip):
    st, d = _submit(app)
    assert st == 200 and d["submitted"] is True and d["license_set"] is True
    assert d["record"]["line"].startswith("Abgegeben am ") and d["record"]["line"].endswith("in Analysis I Übung › Hausaufgaben")
    (_, url, headers, body), = studip.uploads()
    assert url.endswith("/jsonapi.php/v1/folders/f-hw/file-refs") and headers["Content-Type"].startswith("multipart/form-data; boundary=")
    assert b'filename="Mueller_Blatt3.pdf"' in body and PDF in body
    assert any(c[0] == "PATCH" and c[1].endswith("/file-refs/ref1/relationships/terms-of-use") for c in studip.calls)
    st, info = _j(asgi_call(app, "GET", "/api/studip/submit?file_id=f1"))
    assert info["history"][0]["file_name"] == "Mueller_Blatt3.pdf" and info["history"][0]["pages"] == 6
    assert "%PDF" not in json.dumps(info), "die PDF wird nie gespeichert"


def test_closed_folder_errors_and_renewal(app, studip):
    st, d = _submit(app, folder_id="f-zu")
    assert st == 409 and d["code"] == "submit_not_writable" and studip.uploads() == []
    studip.upload_status = [413]
    st, d = _submit(app)
    assert st == 413 and d["code"] == "submit_too_large" and len(studip.uploads()) == 1
    studip.calls.clear()
    studip.upload_status = [500]
    st, d = _submit(app)
    assert st == 502 and len(studip.uploads()) == 1, "5xx: kein zweites Hochladen"
    studip.calls.clear()
    studip.upload_status = [403]
    st, d = _submit(app)
    assert st == 409 and d["code"] == "submit_not_writable" and d["web_url"].endswith(f"index/f-hw?cid={COURSE}")
    studip.calls.clear()
    studip.upload_status = [401, 201]
    st, d = _submit(app)
    assert st == 200 and len(studip.uploads()) == 2 and studip.renewals == [1]
    body, ct = _multipart({"course_id": COURSE, "folder_id": "f-hw", "file_name": "x"}, pdf=b"kein pdf")
    st, d = _j(asgi_call(app, "POST", "/api/studip/submit", body=body, content_type=ct))
    assert st == 400 and d["code"] == "bad_pdf"
