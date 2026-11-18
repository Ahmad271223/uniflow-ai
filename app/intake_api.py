"""Datei-Eingang ueber den Dienst (Auftrag des Inhabers vom 18.11.2026, Umbau "ohne Domain").

Die App schickt neue Kurs-PDFs an den StudiNow-Dienst; der Dienst reicht sie ueber ein privates Netz an den Eingang
(app/intake_server.py) weiter. Der Eingang hat keine Domain, kein Zertifikat und keinen oeffentlichen Port.

- `POST /api/intake/check` {university?, files: [Karteikarte]} -> {missing: [sha256]}
- `POST /api/intake/file` multipart (meta, upload) -> {status: stored | known}

Regeln:
- Nur mit StudiNow-Konto (im Dienst angemeldet); welcher Tarif, ist egal ("egal wer sich einloggt").
- Der Eingang erfaehrt nie, wer geschickt hat: der Dienst gibt nur Hochschule und Datei weiter, mit einem kurzen,
  signierten Ticket ohne Konto-ID (gemeinsames Geheimnis LERNAPP_INTAKE_SECRET).
- Der Dienst speichert nichts: die Datei liegt nur waehrend der Weitergabe in der Upload-Zwischendatei von Starlette
  und wird in Stuecken weitergereicht (`Stream`), nie ganz im Arbeitsspeicher (Inhaber 18.11.2026: "problemlos,
  normale App-Nutzer sollen nichts mitbekommen").
- Hoechstens PARALLEL_UPLOADS Weitergaben je Arbeitsprozess gleichzeitig; darueber 503 intake_busy, die App versucht es
  still beim naechsten Abgleich. So bleiben KI, Abgleich und Anmeldung immer schnell.
- Hoechstens FILES_PER_DAY Dateien je Konto und Tag (nur Schutz vor Missbrauch, normale Nutzer erreichen sie nie;
  gezaehlt in accounts.db, ohne Bezug zu den Dateien).
- LERNAPP_INTAKE_URL: interne Adresse des Eingangs, z. B. http://10.0.0.3:8780 (privates Netz), oder https. Ohne Adresse
  und Geheimnis (mindestens 32 Zeichen) ist der Eingang aus: 503 intake_off.
"""
from __future__ import annotations

import ipaddress
import json
import os
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

from fastapi import APIRouter, File, Form, HTTPException, Request, UploadFile
from starlette.concurrency import run_in_threadpool

from . import config, entitlements, intake_server

router = APIRouter()

FILES_PER_DAY = 5000
CHECKS_PER_DAY = 2000
TIMEOUT_S = 120
CHUNK = 1 << 20


def parallel_uploads() -> int:
    """Gleichzeitige Weitergaben je Arbeitsprozess (LERNAPP_INTAKE_PARALLEL, 1-16, Standard 2)."""
    try:
        return max(1, min(16, int(os.environ.get("LERNAPP_INTAKE_PARALLEL") or 2)))
    except ValueError:
        return 2


_uploads_running = 0   # je Arbeitsprozess; asyncio laeuft in einem Faden, ein Zaehler reicht


class Stream:
    """Anfrage-Koerper aus Vorspann, Datei (in Stuecken gelesen) und Abspann, mit fester Laenge fuer Content-Length."""

    def __init__(self, head: bytes, file, size: int, tail: bytes):
        self.head, self.file, self.size, self.tail = head, file, size, tail

    def __len__(self) -> int:
        return len(self.head) + self.size + len(self.tail)

    def __iter__(self):
        yield self.head
        self.file.seek(0)
        left = self.size
        while left > 0:
            chunk = self.file.read(min(CHUNK, left))
            if not chunk:
                break
            left -= len(chunk)
            yield chunk
        yield self.tail


def intake_url() -> str | None:
    """Interne Adresse des Eingangs; nil = aus. http nur zu einer privaten Adresse (privates Netz, localhost)."""
    url = os.environ.get("LERNAPP_INTAKE_URL", "").strip().rstrip("/")
    if not url or len(os.environ.get("LERNAPP_INTAKE_SECRET", "")) < 32:
        return None
    parts = urlsplit(url)
    if parts.scheme == "https" and parts.hostname:
        return url
    if parts.scheme == "http" and parts.hostname:
        try:
            ip = ipaddress.ip_address(parts.hostname)
        except ValueError:
            return url if parts.hostname == "localhost" else None
        return url if (ip.is_private or ip.is_loopback) else None
    return None


def _count_today(user_id: str, kind: str) -> int:
    from . import accounts
    day = time.strftime("%Y-%m-%d", time.gmtime())
    with accounts.cursor() as conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS intake_days (
                            user_id TEXT NOT NULL, day TEXT NOT NULL, kind TEXT NOT NULL, n INTEGER NOT NULL DEFAULT 0,
                            PRIMARY KEY (user_id, day, kind))""")
        conn.execute("DELETE FROM intake_days WHERE day < ?", (day,))
        conn.execute("""INSERT INTO intake_days(user_id, day, kind, n) VALUES (?,?,?,1)
                        ON CONFLICT(user_id, day, kind) DO UPDATE SET n=n+1""", (user_id, day, kind))
        return conn.execute("SELECT n FROM intake_days WHERE user_id=? AND day=? AND kind=?", (user_id, day, kind)).fetchone()["n"]


async def _gate(request: Request, kind: str, limit: int) -> tuple[str, dict | None]:
    url = intake_url()
    if not url:
        raise HTTPException(503, {"detail": "Der Datei-Eingang ist gerade aus.", "code": "intake_off"})
    user = entitlements.user_of(request)
    if config.is_hosted() and not user:
        raise HTTPException(401, {"detail": "Bitte mit dem StudiNow-Konto anmelden.", "code": "login_required"})
    if user and await run_in_threadpool(_count_today, user["id"], kind) > limit:
        raise HTTPException(429, {"detail": "Für heute ist genug angekommen.", "code": "intake_limit"},
                            headers={"Retry-After": "3600"})
    return url, user


def _university(asked: object, user: dict | None) -> str:
    uni = asked if asked in config.known_universities() else (user or {}).get("university")
    if uni not in config.known_universities():
        raise HTTPException(422, {"detail": "Unbekannte Hochschule.", "code": "university_unknown"})
    return uni


def forward(url: str, path: str, body: bytes | Stream, content_type: str, university: str) -> tuple[int, dict]:
    """Anfrage an den Eingang (blockierend; im Thread-Pool aufrufen). Tests ersetzen diese Funktion."""
    ticket = intake_server.make_ticket(university, secret=os.environ["LERNAPP_INTAKE_SECRET"].encode())["ticket"]
    headers = {"Authorization": f"Bearer {ticket}", "Content-Type": content_type}
    if isinstance(body, Stream):
        headers["Content-Length"] = str(len(body))
    req = urllib.request.Request(url + path, data=body, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}
    except (urllib.error.URLError, TimeoutError, OSError):
        return 502, {"detail": {"code": "intake_unreachable", "detail": "Der Datei-Eingang ist gerade nicht erreichbar."}}


def _answer(status: int, data: dict) -> dict:
    if 200 <= status < 300:
        return data
    inner = data.get("detail") if isinstance(data.get("detail"), dict) else {"detail": data.get("detail")}
    headers = {"Retry-After": "300"} if status in (429, 503) else None
    raise HTTPException(status if status in (409, 413, 415, 422, 429, 502, 503) else 502,
                        {"detail": inner.get("detail") or "Der Datei-Eingang hat die Datei nicht angenommen.",
                         "code": inner.get("code") or f"intake_{status}"}, headers=headers)


@router.post("/api/intake/check")
async def check(request: Request) -> dict:
    url, user = await _gate(request, "check", CHECKS_PER_DAY)
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(422, {"detail": "JSON erwartet", "code": "bad_request"})
    if not isinstance(body, dict) or not isinstance(body.get("files"), list):
        raise HTTPException(422, {"detail": "files: Liste erwartet", "code": "bad_request"})
    uni = _university(body.get("university"), user)
    payload = json.dumps({"files": body["files"]}).encode()
    return _answer(*await run_in_threadpool(forward, url, "/intake/v1/check", payload, "application/json", uni))


@router.post("/api/intake/file")
async def file(request: Request, upload: UploadFile = File(...), meta: str = Form(...), university: str = Form(default="")) -> dict:
    global _uploads_running
    if _uploads_running >= parallel_uploads():
        raise HTTPException(503, {"detail": "Gerade viel los, später nochmal.", "code": "intake_busy"},
                            headers={"Retry-After": "300"})
    url, user = await _gate(request, "file", FILES_PER_DAY)
    uni = _university(university or None, user)
    f = upload.file
    f.seek(0, os.SEEK_END)
    size = f.tell()
    if size > intake_server.MAX_FILE_BYTES:
        raise HTTPException(413, {"detail": "Die Datei ist zu groß.", "code": "too_large"})
    boundary = "studinow-weiter-" + os.urandom(8).hex()
    body = Stream(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"meta\"\r\n\r\n".encode() + meta.encode() + b"\r\n"
        + f"--{boundary}\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"datei.pdf\"\r\n"
          f"Content-Type: application/pdf\r\n\r\n".encode(),
        f, size, f"\r\n--{boundary}--\r\n".encode())
    _uploads_running += 1
    try:
        return _answer(*await run_in_threadpool(forward, url, "/intake/v1/file", body, f"multipart/form-data; boundary={boundary}", uni))
    finally:
        _uploads_running -= 1
