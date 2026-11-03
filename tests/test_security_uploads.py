"""Sicherheitspruefung 3.11.2026, Fund 3: Uploads (Aufnahmen, Notizbuch-Import, Editor-Bilder) haben Groessengrenzen
vor bzw. waehrend des Lesens, Aufnahmen brauchen das Recht und eine eigene Datei, im Dienst gilt ein Speicherkontingent."""
import asyncio
import json
import re

import pytest
from conftest import asgi_call
from test_community import _user, hosted  # noqa: F401
from test_security import _add_file, _multipart


@pytest.fixture
def small_limits(monkeypatch):
    from app import server
    monkeypatch.setattr(server, "MAX_ASSET_BYTES", 64 << 10)
    monkeypatch.setattr(server, "MAX_RECORDING_BYTES", 64 << 10)
    monkeypatch.setattr(server, "MAX_IMPORT_BYTES", 64 << 10)
    monkeypatch.setattr(server, "_MULTIPART_SLACK", 4 << 10)
    monkeypatch.setattr(server, "_UPLOAD_LIMITS", ((re.compile(r"^/api/files/[^/]+/assets$"), 64 << 10),
                                                    (re.compile(r"^/api/files/[^/]+/recordings$"), 64 << 10),
                                                    (re.compile(r"^/api/notebooks$"), 64 << 10)))


def test_oversized_uploads_are_rejected_by_content_length(app, small_limits):
    _add_file("f-big")
    big = b"\0" * (80 << 10)
    for path, fname, extra in (("/api/files/f-big/recordings", "a.mp3", None), ("/api/files/f-big/assets", "a.png", None),
                               ("/api/notebooks", "a.pdf", {"kind": "pdf", "title": "x"})):
        body, ctype = _multipart("upload", fname, (b"%PDF" if fname.endswith(".pdf") else b"") + big, extra)
        st, _, b = asgi_call(app, "POST", path, body=body, content_type=ctype)
        assert st == 413 and b"too_large" in b, (path, st, b[:200])


def test_upload_limit_while_streaming_without_content_length(app, small_limits):
    """Ohne Content-Length (chunked) zaehlt die Schicht mit und bricht ab, bevor alles empfangen ist."""
    _add_file("f-stream")
    body, ctype = _multipart("upload", "a.mp3", b"\0" * (200 << 10))
    chunks = [body[i:i + (16 << 10)] for i in range(0, len(body), 16 << 10)]
    pulled = {"n": 0}
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "POST", "scheme": "http",
             "path": "/api/files/f-stream/recordings", "raw_path": b"/api/files/f-stream/recordings", "query_string": b"",
             "headers": [(b"host", b"test"), (b"content-type", ctype.encode())], "client": ("127.0.0.1", 5000), "server": ("test", 80)}
    out = {}

    async def receive():
        if pulled["n"] < len(chunks):
            pulled["n"] += 1
            return {"type": "http.request", "body": chunks[pulled["n"] - 1], "more_body": pulled["n"] < len(chunks)}
        return {"type": "http.disconnect"}

    async def send(m):
        if m["type"] == "http.response.start":
            out["status"] = m["status"]
    from app.server import app as fastapi_app
    asyncio.run(fastapi_app(scope, receive, send))
    assert out["status"] == 413
    assert pulled["n"] < len(chunks), "Abbruch vor dem vollstaendigen Empfang"


def test_recording_needs_own_file(app):
    body, ctype = _multipart("upload", "a.webm", b"\x1aE\xdf\xa3")
    st, _, _ = asgi_call(app, "POST", "/api/files/gibtsnicht123/recordings", body=body, content_type=ctype)
    assert st == 404


def test_recording_needs_entitlement_in_hosted(hosted):  # noqa: F811
    _, free = _user(hosted, "free@beispiel.de", plus=False, verified=False)
    body, ctype = _multipart("upload", "a.mp3", b"\0" * 1024, {"page": "1"})
    st, _, b = asgi_call(hosted, "POST", "/api/files/egal123/recordings", body=body, headers=free, content_type=ctype)
    assert st == 403 and b"plan_required" in b


def test_storage_quota_per_account(hosted, monkeypatch):  # noqa: F811
    monkeypatch.setenv("LERNAPP_UPLOAD_QUOTA_MB", "1")
    _, h = _user(hosted, "voll@beispiel.de")
    pdf = b"%PDF-1.4\n" + b"\0" * (600 << 10)
    body, ctype = _multipart("upload", "a.pdf", pdf, {"kind": "pdf", "title": "eins"})
    st, _, b = asgi_call(hosted, "POST", "/api/notebooks", body=body, headers=h, content_type=ctype)
    assert st == 200, b[:200]
    st, _, b = asgi_call(hosted, "POST", "/api/notebooks", body=body, headers=h, content_type=ctype)
    assert st == 413 and b"storage_quota" in b
    # anderes Konto hat sein eigenes Kontingent
    _, h2 = _user(hosted, "leer@beispiel.de")
    assert asgi_call(hosted, "POST", "/api/notebooks", body=body, headers=h2, content_type=ctype)[0] == 200


def test_notebook_pdf_is_checked_before_storing(app):
    body, ctype = _multipart("upload", "a.pdf", b"<html>keine pdf</html>", {"kind": "pdf", "title": "x"})
    st, _, _ = asgi_call(app, "POST", "/api/notebooks", body=body, content_type=ctype)
    assert st == 400


def test_image_pixel_limit():
    Image = pytest.importorskip("PIL.Image")
    from app import server
    assert Image.MAX_IMAGE_PIXELS == server.MAX_IMAGE_PIXELS == 40_000_000


def test_upload_limits_are_sane():
    from app import server
    assert server.MAX_ASSET_BYTES == 15 << 20 and server.MAX_IMPORT_BYTES <= 100 << 20 and server.MAX_RECORDING_BYTES <= 200 << 20
    assert json.dumps(server.UPLOAD_QUOTA_MB) == "2048"
