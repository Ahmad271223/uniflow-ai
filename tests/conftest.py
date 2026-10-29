"""Tests laufen auf einem eigenen Temp-Datenordner, nie auf data/lernapp.db."""
import asyncio
import os
import sys
import tempfile
from pathlib import Path

_TMP = tempfile.mkdtemp(prefix="lernapp-test-")
os.environ["LERNAPP_DATA_DIR"] = str(Path(_TMP) / "data")
os.environ["LERNAPP_LOG_DIR"] = str(Path(_TMP) / "logs")
os.environ["LERNAPP_NO_SCHEDULER"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402


def asgi_call(app, method, path, client=("127.0.0.1", 5000), body=None, cookies=None):
    """Minimaler ASGI-Aufruf ohne httpx; liefert (status, headers, body_bytes)."""
    q = path.split("?", 1)[1].encode() if "?" in path else b""
    headers = [(b"host", b"test"), (b"content-type", b"application/json")]
    if cookies:
        headers.append((b"cookie", cookies.encode()))
    raw = body if isinstance(body, bytes) else (body.encode() if isinstance(body, str) else b"")
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": method, "scheme": "http",
             "path": path.split("?")[0], "raw_path": path.encode(), "query_string": q, "headers": headers,
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
