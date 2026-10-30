"""Tests laufen auf einem eigenen Temp-Datenordner, nie auf data/lernapp.db."""
import asyncio
import os
import sys
import tempfile
from pathlib import Path

_TMP = tempfile.mkdtemp(prefix="lernapp-test-")
os.environ["LERNAPP_DATA_DIR"] = str(Path(_TMP) / "data")
os.environ["LERNAPP_LOG_DIR"] = str(Path(_TMP) / "logs")
os.environ["LERNAPP_ALLOWED_HOSTS"] = "test"        # Host-Kopfzeile der Test-Aufrufe
os.environ["LERNAPP_NO_SCHEDULER"] = "1"           # keine Hintergrund-Zeitplaene (app/weekly.py) in Tests
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402


def asgi_call(app, method, path, client=("127.0.0.1", 5000), body=None, cookies=None, headers=None, host="test",
              content_type="application/json", raw_path=False):
    """Minimaler ASGI-Aufruf ohne httpx; liefert (status, headers, body_bytes).
    Der Pfad wird wie bei uvicorn prozent-dekodiert (%5C -> Backslash), raw_path bleibt kodiert."""
    from urllib.parse import unquote
    p, _, q = path.partition("?")
    hdrs = [(b"host", host.encode()), (b"content-type", content_type.encode())]
    if cookies:
        hdrs.append((b"cookie", cookies.encode()))
    for k, v in (headers or {}).items():
        hdrs.append((k.lower().encode(), v.encode()))
    raw = body if isinstance(body, bytes) else (body.encode() if isinstance(body, str) else b"")
    hdrs.append((b"content-length", str(len(raw)).encode()))
    scope = {"type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"}, "http_version": "1.1", "method": method, "scheme": "http",
             "path": unquote(p), "raw_path": p.encode(), "query_string": q.encode(), "headers": hdrs,
             "client": client, "server": ("test", 80)}
    out = {"status": None, "headers": [], "body": b""}
    sent = {"done": False}

    async def receive():
        if not sent["done"]:
            sent["done"] = True
            return {"type": "http.request", "body": raw, "more_body": False}
        return {"type": "http.disconnect"}

    async def send(m):
        if m["type"] == "http.response.start":
            out["status"] = m["status"]; out["headers"] = m["headers"]
        elif m["type"] == "http.response.body":
            out["body"] += m.get("body", b"")

    asyncio.run(app(scope, receive, send))
    return out["status"], out["headers"], out["body"]


@pytest.fixture(scope="session")
def app():
    from app import config
    assert str(config.DATA_DIR).startswith(_TMP), "Tests duerfen nie den echten Datenordner nutzen"
    from app.server import app as fastapi_app
    return fastapi_app
