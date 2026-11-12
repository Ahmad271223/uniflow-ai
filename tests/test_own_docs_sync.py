"""Eigene Dokumente zwischen Windows-App und Dienst (12.11.2026, app/own_docs.py, app/own_docs_sync.py, E3 in
docs/WINDOWS-FERTIG-2026-11-12.md). Zwei Seiten eines Kontos: die Windows-App (eigene Datenbank, Einzelplatz) und das Web
(der Dienst selbst, per ASGI mit dem Bearer-Token des Kontos). Notizbuecher, importierte PDFs, ihre Notizen und Bilder
gehen in beide Richtungen; Umbenennen, Papierkorb und endgueltiges Loeschen ebenso. Das veroeffentlichte iPad (G2 ohne
`own=1`) bekommt die Notizen eigener Dokumente nicht."""
import hashlib
import io
import json

import pytest
from conftest import asgi_call
from test_security import _multipart
from test_sync_client import SERVICE, _hosted, ipad_pull, two_devices  # noqa: F401

PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 64


def make_pdf(pages=1) -> bytes:
    from pypdf import PdfWriter
    w = PdfWriter()
    for _ in range(pages):
        w.add_blank_page(595, 842)
    buf = io.BytesIO()
    w.write(buf)
    return buf.getvalue()


def _hosted_raw(app, method, path, body=b"", ctype="application/json", headers=None):
    from app import config
    old = config.MODE
    config.MODE = "hosted"
    try:
        st, _, b = asgi_call(app, method, path, body=body, content_type=ctype, headers=headers)
    finally:
        config.MODE = old
    return st, b


def web_new(app, ipad, kind, title, data=None, fname="x.pdf"):
    body, ctype = _multipart("upload", fname, data, {"kind": kind, "title": title}) if data is not None \
        else _multipart("upload", "leer.txt", b"", {"kind": kind, "title": title})
    if data is None:          # Notizbuch ohne Datei: nur Formularfelder
        body, ctype = _form({"kind": kind, "title": title})
    st, b = _hosted_raw(app, "POST", "/api/notebooks", body, ctype, ipad)
    assert st == 200, b[:300]
    return json.loads(b)["id"]


def _form(fields: dict):
    boundary = "----own-docs-test"
    parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields.items()]
    return b"".join(parts) + f"--{boundary}--\r\n".encode(), f"multipart/form-data; boundary={boundary}"


def pc_new(app, kind, title, data=None, fname="x.pdf"):
    body, ctype = _multipart("upload", fname, data, {"kind": kind, "title": title}) if data is not None else _form({"kind": kind, "title": title})
    st, _, b = asgi_call(app, "POST", "/api/notebooks", body=body, content_type=ctype)
    assert st == 200, b[:300]
    return json.loads(b)["id"]


def pc_note(fid, objects):
    from app import db
    with db.cursor() as conn:
        cur = json.loads(db.row(conn, "SELECT data FROM annotations WHERE file_id=?", (fid,))["data"])
        key = cur["pageOrder"][0]["key"]
        cur["pages"].setdefault(key, {})["objects"] = objects
        conn.execute("UPDATE annotations SET data=?, version=version+1 WHERE file_id=?", (json.dumps(cur), fid))


def web_note(app, ipad, fid, objects):
    st, cur = _hosted(app, "GET", f"/api/files/{fid}/annotations", headers=ipad)
    assert st == 200, cur
    doc = cur["data"]
    key = doc["pageOrder"][0]["key"]
    doc["pages"].setdefault(key, {})["objects"] = objects
    st, r = _hosted(app, "PUT", f"/api/files/{fid}/annotations?base_version={cur['version']}", doc, ipad)
    assert st == 200, r


def web_objects(app, ipad, fid):
    st, cur = _hosted(app, "GET", f"/api/files/{fid}/annotations", headers=ipad)
    assert st == 200, cur
    return sorted(o["id"] for p in cur["data"]["pages"].values() for o in p.get("objects", []))


def pc_objects(fid):
    from app import db
    with db.cursor() as conn:
        a = json.loads(db.row(conn, "SELECT data FROM annotations WHERE file_id=?", (fid,))["data"])
    return sorted(o["id"] for p in a["pages"].values() for o in p.get("objects", []))


def run_sync():
    from app import sync_client
    out = sync_client.run()
    assert out["ok"], out
    return out


def code_of(d) -> str | None:
    det = d.get("detail") if isinstance(d, dict) else None
    return det.get("code") if isinstance(det, dict) else (d.get("code") if isinstance(d, dict) else None)


def web_list(app, ipad):
    st, d = _hosted(app, "GET", "/api/sync/own-documents", headers=ipad)
    assert st == 200, d
    return {x["id"]: x for x in d["documents"]}, {t["id"] for t in d["tombstones"]}


# ---------------------------------------------------------------- beide Richtungen

def test_windows_documents_reach_the_web_with_notes_and_pictures(two_devices):
    app, ipad = two_devices
    from app import config
    pdf = make_pdf(2)
    nb = pc_new(app, "notebook", "Analysis Mitschrift")
    imp = pc_new(app, "pdf", "Skript Kapitel 1", pdf)
    name = "0123456789abcdef0123456789abcdef.png"
    (config.data_dir() / "assets" / nb).mkdir(parents=True, exist_ok=True)
    (config.data_dir() / "assets" / nb / name).write_bytes(PNG)
    pc_note(nb, [{"id": "s1", "type": "stroke", "points": [1, 2, 3, 4]},
                 {"id": "b1", "type": "image", "src": f"/api/assets/{nb}/{name}", "x": 10, "y": 10}])

    out = run_sync()
    assert out["own_documents"] == "ok" and out["own_up"] == 2 and out["assets_up"] == 1, out
    docs, _ = web_list(app, ipad)
    assert docs[nb]["title"] == "Analysis Mitschrift" and docs[nb]["kind"] == "notebook" and not docs[nb]["has_content"]
    assert docs[imp]["sha256"] == hashlib.sha256(pdf).hexdigest() and docs[imp]["page_count"] == 2
    # das Web sieht beides in der Bibliothek, die PDF mit demselben Inhalt, das Notizbuch mit Strich und Bild
    st, lib = _hosted(app, "GET", "/api/library", headers=ipad)
    assert st == 200 and {nb, imp} <= {f["id"] for f in lib["files"]}, lib
    st, body = _hosted_raw(app, "GET", f"/api/files/{imp}/content", headers=ipad)
    assert st == 200 and body == pdf
    assert web_objects(app, ipad, nb) == ["b1", "s1"]
    st, img = _hosted_raw(app, "GET", f"/api/assets/{nb}/{name}", headers=ipad)
    assert st == 200 and img == PNG
    # zweiter Lauf: nichts mehr zu tun
    again = run_sync()
    assert again["own_up"] == 0 and again["own_down"] == 0 and again["assets_up"] == 0, again


def test_web_documents_reach_windows_with_notes(two_devices):
    app, ipad = two_devices
    from app import db
    pdf = make_pdf(3)
    nb = web_new(app, ipad, "notebook", "Lineare Algebra")
    imp = web_new(app, ipad, "pdf", "Altklausur", pdf)
    web_note(app, ipad, nb, [{"id": "web-1", "type": "stroke", "points": [5, 6, 7, 8]}])

    out = run_sync()
    assert out["own_down"] == 2 and out["pending"] == 0, out
    with db.cursor() as conn:
        f = db.row(conn, "SELECT * FROM files WHERE id=?", (imp,))
        assert f["course_id"] == "__user__" and f["title"] == "Altklausur"
        assert hashlib.sha256(open(f["local_path"], "rb").read()).hexdigest() == hashlib.sha256(pdf).hexdigest()
        assert db.row(conn, "SELECT title FROM files WHERE id=?", (nb,))["title"] == "Lineare Algebra"
    assert pc_objects(nb) == ["web-1"]
    # Umbenennen und Papierkorb im Web kommen an
    assert _hosted(app, "PATCH", f"/api/library/files/{imp}", {"title": "Altklausur 2025"}, ipad)[0] == 200
    assert _hosted(app, "PATCH", f"/api/library/files/{nb}", {"trash": True}, ipad)[0] == 200
    out = run_sync()
    with db.cursor() as conn:
        assert db.row(conn, "SELECT title FROM files WHERE id=?", (imp,))["title"] == "Altklausur 2025"
        assert db.row(conn, "SELECT deleted_at FROM files WHERE id=?", (nb,))["deleted_at"]
    assert out["own_up"] == 0, out


def test_notes_on_both_sides_merge_and_last_local_edit_wins_for_the_title(two_devices):
    app, ipad = two_devices
    from app import db
    nb = pc_new(app, "notebook", "Physik")
    run_sync()
    # gleichzeitig: Strich am PC, Strich im Web, Titel an beiden Stellen
    pc_note(nb, [{"id": "pc-1", "type": "stroke", "points": [1, 1, 2, 2]}])
    web_note(app, ipad, nb, [{"id": "web-1", "type": "stroke", "points": [3, 3, 4, 4]}])
    assert _hosted(app, "PATCH", f"/api/library/files/{nb}", {"title": "Physik (Web)"}, ipad)[0] == 200
    assert asgi_call(app, "PATCH", f"/api/library/files/{nb}", body=json.dumps({"title": "Physik (PC)"}))[0] == 200
    run_sync()
    run_sync()
    assert pc_objects(nb) == ["pc-1", "web-1"]
    assert web_objects(app, ipad, nb) == ["pc-1", "web-1"]
    docs, _ = web_list(app, ipad)
    assert docs[nb]["title"] == "Physik (PC)", "zuletzt an diesem PC bearbeitet gewinnt"


# ---------------------------------------------------------------- Loeschen

def test_deleting_forever_reaches_the_other_side_both_ways(two_devices):
    app, ipad = two_devices
    from app import db
    a = pc_new(app, "pdf", "Weg am PC", make_pdf())
    b = pc_new(app, "notebook", "Weg im Web")
    c = pc_new(app, "notebook", "Im Web geloescht, am PC weiter bearbeitet")
    run_sync()
    assert asgi_call(app, "PATCH", f"/api/library/files/{a}", body=json.dumps({"delete_forever": True}))[0] == 200
    assert _hosted(app, "PATCH", f"/api/library/files/{b}", {"delete_forever": True}, ipad)[0] == 200
    assert _hosted(app, "PATCH", f"/api/library/files/{c}", {"delete_forever": True}, ipad)[0] == 200
    pc_note(c, [{"id": "nach-dem-loeschen", "type": "stroke", "points": [1, 2, 3, 4]}])
    out = run_sync()
    docs, tombs = web_list(app, ipad)
    assert a not in docs and a in tombs
    with db.cursor() as conn:
        assert not db.row(conn, "SELECT 1 FROM files WHERE id=?", (b,)), "im Web geloescht -> am PC weg"
        assert db.row(conn, "SELECT 1 FROM files WHERE id=?", (c,)), "am PC danach geaendert -> bleibt"
    assert c in docs, "und geht neu hoch: lieber doppelt als verloren"
    assert out["own_deleted"] >= 2, out


# ---------------------------------------------------------------- iPad, Tarif, alter Dienst, Grenzen

def test_published_ipad_does_not_get_notes_of_own_documents(two_devices):
    app, ipad = two_devices
    nb = pc_new(app, "notebook", "Nur Geraete mit own=1")
    pc_note(nb, [{"id": "s", "type": "stroke", "points": [1, 2, 3, 4]}])
    run_sync()
    changes, _ = ipad_pull(app, ipad)
    assert nb not in {a["file_id"] for a in changes.get("annotations", [])}
    st, d = _hosted(app, "GET", "/api/sync/changes?limit=2000&own=1", headers=ipad)
    assert nb in {a["file_id"] for a in d["changes"].get("annotations", [])}


def test_without_pro_ai_nothing_of_own_documents_moves(two_devices):
    app, ipad = two_devices
    from app import accounts
    st, me = _hosted(app, "GET", "/api/account/me", headers=ipad)
    accounts.set_plan(me["user"]["id"] if "user" in me else me["id"], "plus")
    pc_new(app, "notebook", "Bleibt am PC")
    out = run_sync()
    assert out["own_documents"] == "plan_required" and out["own_up"] == 0, out
    st, d = _hosted(app, "GET", "/api/sync/own-documents", headers=ipad)
    assert st == 403 and code_of(d) == "plan_required", d


def test_an_older_service_without_the_route_keeps_g2_running(two_devices, monkeypatch):
    app, ipad = two_devices
    from app import db, service_link
    real = service_link.transport

    def old_service(method, url, headers, body, timeout):
        if "/api/sync/own-documents" in url or "/api/sync/assets" in url:
            return 404, {}, b'{"detail":"Not Found"}'
        return real(method, url, headers, body, timeout)
    monkeypatch.setattr(service_link, "transport", old_service)
    pc_new(app, "notebook", "Wartet auf den neuen Dienst")
    with db.cursor() as conn:
        db.set_setting(conn, "hours_per_day", "7")
    out = run_sync()
    assert out["own_documents"] == "unavailable" and out["pushed"] >= 1, out


def test_files_over_the_limit_stay_on_the_pc_and_are_named(two_devices, monkeypatch):
    app, ipad = two_devices
    from app import own_docs
    pc_new(app, "pdf", "Riesiges Skript", make_pdf(5))
    monkeypatch.setattr(own_docs, "MAX_SYNC_BYTES", 100)
    st, d = _hosted(app, "GET", "/api/sync/own-documents", headers=ipad)
    assert st == 200
    out = run_sync()
    # die Grenze kommt vom Dienst (max_bytes) - hier im selben Prozess also auch 100 Bytes
    assert "Riesiges Skript" in out["own_skipped"] and out["own_up"] == 0, out


# ---------------------------------------------------------------- Dienst: Pruefungen

def test_service_routes_check_ids_owner_content_and_quota(two_devices, monkeypatch):
    app, ipad = two_devices
    from app import server
    fid = "u" + "a" * 23
    st, d = _hosted(app, "PUT", "/api/sync/own-documents/../etc", {"title": "x"}, ipad)
    assert st in (400, 404, 405)
    for bad in ("kein-eigenes", "u..aaaaaaaaaa", "U" + "a" * 23, "u" + "a" * 41):
        st, d = _hosted(app, "PUT", f"/api/sync/own-documents/{bad}", {"title": "x"}, ipad)
        assert st == 400 and code_of(d) == "id_invalid", (bad, d)
    st, d = _hosted(app, "PUT", f"/api/sync/own-documents/{fid}", {"kind": "pdf", "title": "Skript", "name": "Skript.pdf"}, ipad)
    assert st == 200 and d["id"] == fid and not d["has_content"]
    pdf = make_pdf()
    # falscher Fingerabdruck: nichts bleibt liegen
    st, b = _hosted_raw(app, "PUT", f"/api/sync/own-documents/{fid}/content?sha256={'0' * 64}", pdf, "application/octet-stream", ipad)
    assert st == 400 and code_of(json.loads(b)) == "content_mismatch"
    st, b = _hosted_raw(app, "PUT", f"/api/sync/own-documents/{fid}/content", b"keine pdf", "application/octet-stream", ipad)
    assert st == 400
    # jeder Upload schreibt in eine neue Datei (Audit P28-02)
    seen = []
    real = server._save_upload

    async def spy(upload, target, limit, head=None):
        seen.append((target, target.exists()))
        return await real(upload, target, limit, head)
    monkeypatch.setattr(server, "_save_upload", spy)
    for _ in range(2):
        st, b = _hosted_raw(app, "PUT", f"/api/sync/own-documents/{fid}/content?sha256={hashlib.sha256(pdf).hexdigest()}", pdf,
                            "application/octet-stream", ipad)
        assert st == 200 and json.loads(b)["sha256"] == hashlib.sha256(pdf).hexdigest()
    assert len({t for t, _ in seen}) == 2 and not any(e for _, e in seen)
    monkeypatch.setattr(server, "_save_upload", real)
    # Kontingent des Kontos gilt auch hier
    monkeypatch.setenv("LERNAPP_UPLOAD_QUOTA_MB", "0")
    st, b = _hosted_raw(app, "PUT", f"/api/sync/own-documents/{fid}/content", pdf, "application/octet-stream", ipad)
    assert st == 413 and code_of(json.loads(b)) == "storage_quota"
    monkeypatch.delenv("LERNAPP_UPLOAD_QUOTA_MB")
    # eine Hochschuldatei laesst sich nie als eigenes Dokument ueberschreiben oder loeschen
    from app import config, db
    st, me = _hosted(app, "GET", "/api/account/me", headers=ipad)
    uid = me["user"]["id"] if "user" in me else me["id"]
    tok = config.set_user_context(uid, "luh")
    try:
        with db.cursor() as conn:
            conn.execute("INSERT OR IGNORE INTO courses(id, title) VALUES ('k1', 'Kurs')")
            conn.execute("INSERT INTO files(id, course_id, name, status) VALUES (?, 'k1', 'Blatt.pdf', 'neu')", ("u" + "b" * 23,))
    finally:
        config.reset_user_context(tok)
    st, d = _hosted(app, "PUT", f"/api/sync/own-documents/{'u' + 'b' * 23}", {"title": "x"}, ipad)
    assert st == 409 and code_of(d) == "not_own_document"
    st, d = _hosted(app, "DELETE", f"/api/sync/own-documents/{'u' + 'b' * 23}", headers=ipad)
    assert st == 400 and code_of(d) == "not_own_document"          # wie Endgueltig-Loeschen in der Bibliothek
    tok = config.set_user_context(uid, "luh")
    try:
        with db.cursor() as conn:
            assert db.row(conn, "SELECT course_id FROM files WHERE id=?", ("u" + "b" * 23,))["course_id"] == "k1"
    finally:
        config.reset_user_context(tok)
    # Bilder nur mit gueltigem Namen und nur, wenn eine Notiz oder ein Dokument dazu gehoert
    st, b = _hosted_raw(app, "PUT", "/api/sync/assets/fremd/0123456789abcdef0123456789abcdef.png", PNG, "application/octet-stream", ipad)
    assert st == 404
    st, b = _hosted_raw(app, "PUT", f"/api/sync/assets/{fid}/aufnahme.m4a", b"x", "application/octet-stream", ipad)
    assert st == 400
    st, b = _hosted_raw(app, "PUT", f"/api/sync/assets/{fid}/0123456789abcdef0123456789abcdef.png", b"<html>", "application/octet-stream", ipad)
    assert st == 400 and code_of(json.loads(b)) == "asset_content"


def test_routes_exist_only_in_the_service(app):
    for method, path in (("GET", "/api/sync/own-documents"), ("GET", "/api/sync/assets")):
        assert asgi_call(app, method, path)[0] == 404
