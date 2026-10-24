"""Sicherheits- und Datenverlust-Regressionstests aus der Bestandsaufnahme vom 25.10.2026 (Phase 1)."""
import json
import threading

from conftest import asgi_call


def _add_file(file_id, name="x.pdf"):
    from app import db
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES ('c1', 'Testkurs', 'uebung', '2026-10-24')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status) VALUES (?,?,?,?, 'neu')", (file_id, "c1", name, "pdf"))


def _multipart(field, filename, data: bytes, extra: dict | None = None):
    boundary = "----uniflowtest"
    parts = []
    for k, v in (extra or {}).items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{filename}\"\r\n"
                 f"Content-Type: application/octet-stream\r\n\r\n".encode() + data + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


# -- P0: Pfad-Traversal ueber Backslashes in der Datei-ID (Windows) liest beliebige Dateien, z. B. die .env
def test_asset_read_rejects_path_traversal(app, tmp_path):
    from app import config
    secret = config.DATA_DIR / "geheim.txt"
    secret.write_text("PASSWORT=1234", encoding="utf-8")
    st, _, body = asgi_call(app, "GET", "/api/assets/..%5C/geheim.txt", raw_path=True)
    assert b"PASSWORT" not in body and st in (400, 404)


# -- P0: Pfad-Traversal beim Hochladen von Aufnahmen schreibt Dateien mit beliebiger Endung an beliebige Orte
def test_recording_upload_rejects_path_traversal_and_bad_extension(app):
    from app import config
    body, ctype = _multipart("upload", "x.bat", b"echo pwned")
    st, _, _ = asgi_call(app, "POST", "/api/files/..%5C..%5Coutside/recordings", body=body, content_type=ctype, raw_path=True)
    assert st in (400, 404, 422)
    assert not (config.DATA_DIR.parent / "outside").exists()
    _add_file("f-rec")
    body, ctype = _multipart("upload", "x.bat", b"echo pwned")
    st, _, _ = asgi_call(app, "POST", "/api/files/f-rec/recordings", body=body, content_type=ctype)
    assert st == 400, "nur Audio-Endungen erlaubt"
    body, ctype = _multipart("upload", "a.webm", b"\x1aE\xdf\xa3")
    st, _, b = asgi_call(app, "POST", "/api/files/f-rec/recordings", body=body, content_type=ctype)
    assert st == 200 and json.loads(b)["url"].startswith("/api/assets/f-rec/rec_")


# -- P0: Fremde Webseiten im Browser des PCs duerfen keine Aenderungen ausloesen (CSRF ueber 127.0.0.1)
def test_cross_site_post_is_rejected(app):
    st, _, _ = asgi_call(app, "POST", "/api/sync", headers={"origin": "https://boese.example"})
    assert st == 403
    st, _, _ = asgi_call(app, "PUT", "/api/settings", body=json.dumps({"x_test": "1"}), headers={"origin": "null"})
    assert st == 403
    st, _, _ = asgi_call(app, "PUT", "/api/settings", body=json.dumps({"x_test": "1"}), headers={"origin": "http://test"})
    assert st == 200, "eigene Oberflaeche (gleicher Host) bleibt erlaubt"


# -- P0: DNS-Rebinding: fremder Hostname zeigt auf 127.0.0.1 und liest die PIN/Daten aus
def test_foreign_host_header_is_rejected(app):
    st, _, _ = asgi_call(app, "GET", "/api/network", host="evil.example:8765")
    assert st == 421
    assert asgi_call(app, "GET", "/api/network", host="192.168.178.46:8765")[0] == 200
    assert asgi_call(app, "GET", "/api/network", host="localhost:8765")[0] == 200


# -- P0: zwei gleichzeitige Speicherungen mit derselben base_version ueberschrieben sich still
def test_concurrent_annotation_saves_do_not_both_win(app, monkeypatch):
    from app import db, server
    _add_file("f-race")
    first = {"version": 2, "pages": {"p1": {"objects": [{"id": "a", "type": "stroke", "points": [1, 2, 3, 4]}]}}}
    assert server.put_annotations("f-race", first, base_version=0)["version"] == 1
    barrier = threading.Barrier(2)
    real_row = db.row

    def slow_row(conn, sql, params=()):
        r = real_row(conn, sql, params)
        if sql.startswith("SELECT version, data FROM annotations"):
            try:
                barrier.wait(timeout=1.0)        # beide lesen denselben Stand, bevor einer schreibt
            except threading.BrokenBarrierError:
                pass
        return r
    monkeypatch.setattr(db, "row", slow_row)
    results = []

    def save(obj_id):
        body = {"version": 2, "pages": {"p1": {"objects": [{"id": obj_id, "type": "stroke", "points": [5, 6, 7, 8]}]}}}
        r = server.put_annotations("f-race", body, base_version=1)
        results.append(getattr(r, "status_code", 200))
    threads = [threading.Thread(target=save, args=(i,)) for i in ("geraet-a", "geraet-b")]
    [t.start() for t in threads]
    [t.join(10) for t in threads]
    assert sorted(results) == [200, 409], f"genau eine Speicherung darf gewinnen, war {results}"


# -- P1: .env wird atomar geschrieben, Sonderzeichen in Passwoertern bleiben erhalten, keine Zeileninjektion
def test_env_roundtrip_special_characters(monkeypatch, tmp_path):
    from app import config
    monkeypatch.setattr(config, "ROOT", tmp_path)
    (tmp_path / ".env").write_text("# Kommentar\nSTUDIP_USER=abc123\nANDERES=bleibt\n", encoding="utf-8")
    pw = 'a #b "c" \\d ${HOME} \'e\''
    config.save_credentials("abc123", pw, "QIS")
    assert config.service_credentials("QIS") == ("abc123", pw)
    text = (tmp_path / ".env").read_text(encoding="utf-8")
    assert "# Kommentar" in text and "ANDERES=bleibt" in text
    try:
        config.save_credentials("abc123", "x\nSTUDIP_PASSWORD=boese", "QIS")
        raised = False
    except ValueError:
        raised = True
    assert raised and "boese" not in (tmp_path / ".env").read_text(encoding="utf-8")
