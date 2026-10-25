"""Erweiterte Sicherheits-Regressionstests (Pruefung vom 25.10.2026, zweite Runde).

Wichtig: Antworten werden nie in Fehlermeldungen ausgegeben (sie koennten Geheimnisse enthalten)."""
import json

from conftest import asgi_call
from test_security import _multipart


def _add_file(file_id, name="x.pdf", mime=None, local_path=None, kind="pdf"):
    from app import db
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES ('c1', 'Testkurs', 'uebung', '2026-10-24')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, kind, status, mime, local_path) VALUES (?,?,?,?, 'neu', ?, ?)",
                     (file_id, "c1", name, kind, mime, local_path))


# ---------------------------------------------------------------- Pfad-Traversal (Varianten)

def test_asset_traversal_variants(app):
    from app import config
    canary = config.DATA_DIR / "kanarienvogel.txt"
    canary.write_text("GEHEIM-KANARIE", encoding="utf-8")
    variants = [
        "/api/assets/..%5C/kanarienvogel.txt",
        "/api/assets/..%5C..%5Cdata/kanarienvogel.txt",
        "/api/assets/%2E%2E%5C/kanarienvogel.txt",
        "/api/assets/....%5C/kanarienvogel.txt",
        "/api/assets/C:%5CWindows/win.ini",
        "/api/assets/ok/..%5Ckanarienvogel.txt",
        "/api/assets/ok/%2E%2E%5C%2E%2E%5Ckanarienvogel.txt",
        "/api/assets/%EF%BC%8E%EF%BC%8E%5C/kanarienvogel.txt",     # Vollbreiten-Punkte
    ]
    for path in variants:
        st, _, body = asgi_call(app, "GET", path, raw_path=True)
        leaked = b"GEHEIM-KANARIE" in body
        assert not leaked and st in (400, 404), path


def test_static_files_cannot_leave_static_dir(app):
    # .env.example liegt im Projektordner (ohne Geheimnisse) und dient als Kanarienvogel
    for path in ("/..%5C..%5C.env.example", "/%2E%2E%5C%2E%2E%5C.env.example", "/..%2F..%2F.env.example", "/static/..%5C..%5C..%5C.env.example"):
        st, _, body = asgi_call(app, "GET", path, raw_path=True)
        leaked = b"STUDIP_USER" in body
        assert not leaked, path


def test_recording_traversal_in_filename_is_harmless(app):
    _add_file("f-rec2")
    body, ctype = _multipart("upload", "..\\..\\..\\Startup\\x.webm", b"\x1aE\xdf\xa3")
    st, _, b = asgi_call(app, "POST", "/api/files/f-rec2/recordings", body=body, content_type=ctype)
    assert st == 200
    url = json.loads(b)["url"]
    assert url.startswith("/api/assets/f-rec2/rec_") and ".." not in url and "\\" not in url


# ---------------------------------------------------------------- Herkunft und Host

def test_origin_variants(app):
    for method in ("POST", "PUT", "PATCH", "DELETE"):
        st, _, _ = asgi_call(app, method, "/api/plan/items/999999", body="{}", headers={"origin": "https://boese.example"})
        assert st == 403, method
    assert asgi_call(app, "PUT", "/api/settings", body="{}", headers={"origin": "http://test:9999"})[0] == 403, "anderer Port = fremde Herkunft"
    assert asgi_call(app, "PUT", "/api/settings", body="{}", headers={"origin": "http://TEST"})[0] == 200, "Gross/Klein egal"
    assert asgi_call(app, "PUT", "/api/settings", body="{}")[0] == 200, "ohne Origin (native App) erlaubt"


def test_host_variants(app):
    for host in ("localhost.boese.example", "127.0.0.1.nip.io", "test.boese.example", "localhost.:8765"):
        assert asgi_call(app, "GET", "/api/settings", host=host)[0] == 421, host
    for host in ("[::1]:8765", "127.0.0.1:8765", "10.0.0.5:8765"):
        assert asgi_call(app, "GET", "/api/settings", host=host)[0] == 200, host


# ---------------------------------------------------------------- nur eigene Netze

def test_public_client_ip_is_rejected_even_with_pin(app):
    from app import db
    with db.cursor() as conn:
        db.set_setting(conn, "lan_pin", "112233")
    for ip in ("8.8.8.8", "203.0.113.7", "::ffff:8.8.8.8", "2001:db8::1"):
        st, _, _ = asgi_call(app, "GET", "/api/settings?pin=112233", client=(ip, 5000))
        assert st == 403, ip
    for ip in ("192.168.178.20", "10.1.2.3", "172.16.0.9", "100.101.102.103", "fe80::1", "fd00::5"):
        st, _, _ = asgi_call(app, "GET", "/api/settings", client=(ip, 5000))
        assert st == 401, f"{ip}: privates Netz -> PIN erforderlich"
    assert asgi_call(app, "GET", "/api/settings?pin=112233", client=("192.168.178.20", 5000))[0] == 200


def test_pin_cookie_is_httponly(app):
    from app import db
    with db.cursor() as conn:
        db.set_setting(conn, "lan_pin", "445566")
    st, headers, _ = asgi_call(app, "GET", "/api/settings?pin=445566", client=("192.168.1.50", 5000))
    cookies = [v.decode() for k, v in headers if k == b"set-cookie"]
    assert st == 200 and any("lernapp_pin=" in c and "httponly" in c.lower() for c in cookies)


# ---------------------------------------------------------------- ausgelieferte Dateien

def test_html_from_studip_is_downloaded_not_rendered(app, tmp_path):
    page = tmp_path / "material.html"
    page.write_text("<script>fetch('/api/credentials')</script>", encoding="utf-8")
    _add_file("f-html", name="material.html", mime="text/html", local_path=str(page), kind="file")
    st, headers, _ = asgi_call(app, "GET", "/api/files/f-html/content")
    h = {k.decode().lower(): v.decode() for k, v in headers}
    assert st == 200
    assert h["content-type"].startswith("application/octet-stream")
    assert h["content-disposition"].startswith("attachment")
    assert "sandbox" in h["content-security-policy"] and h["x-content-type-options"] == "nosniff"


def test_pdf_is_shown_inline_without_sandbox(app, tmp_path):
    pdf = tmp_path / "skript.pdf"
    pdf.write_bytes(b"%PDF-1.4\n%%EOF\n")
    _add_file("f-pdf2", name="skript.pdf", mime="application/pdf", local_path=str(pdf))
    st, headers, _ = asgi_call(app, "GET", "/api/files/f-pdf2/content")
    h = {k.decode().lower(): v.decode() for k, v in headers}
    assert st == 200 and h["content-type"].startswith("application/pdf") and h["content-disposition"].startswith("inline")
    assert "content-security-policy" not in h and h["x-content-type-options"] == "nosniff"


def test_svg_asset_runs_sandboxed(app):
    _add_file("f-svg")
    body, ctype = _multipart("upload", "bild.svg", b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>')
    st, _, b = asgi_call(app, "POST", "/api/files/f-svg/assets", body=body, content_type=ctype)
    assert st == 200
    st, headers, _ = asgi_call(app, "GET", json.loads(b)["url"])
    h = {k.decode().lower(): v.decode() for k, v in headers}
    assert st == 200 and "sandbox" in h.get("content-security-policy", "")


# ---------------------------------------------------------------- Uploads

def test_notebook_import_checks_type(app):
    body, ctype = _multipart("upload", "fake.pdf", b"<html>keine pdf</html>", extra={"kind": "pdf", "title": "Test"})
    assert asgi_call(app, "POST", "/api/notebooks", body=body, content_type=ctype)[0] == 400
    body, ctype = _multipart("upload", "seite.html", b"<html></html>", extra={"kind": "image", "title": "Test"})
    assert asgi_call(app, "POST", "/api/notebooks", body=body, content_type=ctype)[0] == 400
