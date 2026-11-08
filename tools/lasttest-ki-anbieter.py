"""Schein-KI-Anbieter fuer den Lasttest (tools/lasttest-ki.py, 08.11.2026): spielt die Responses API von OpenAI
(`POST /v1/responses`, Ereignisstrom) und antwortet nach einer Wartezeit mit einem festen Text und einer `usage`.

Zweck: den echten asynchronen Weg des Dienstes (httpx -> Anbieter) unter Last pruefen, ohne einen Anbieter zu rufen
und ohne Geld auszugeben. Der Dienst zeigt mit LERNAPP_OPENAI_BASE_URL=http://127.0.0.1:<port>/v1 hierher.

Aufruf:  python tools/lasttest-ki-anbieter.py --port 8799 --delay 10 [--jitter 10]
         (Wartezeit je Anfrage: delay + zufaellig 0..jitter Sekunden; Standard 10 s fest)

Reines asyncio ohne Zusatzpakete; haelt viele tausend offene Verbindungen gleichzeitig (eine Koroutine je Verbindung).
Zaehler auf stderr alle 5 s: offene Verbindungen, beantwortete Anfragen. Nie gegen den echten Server richten - das
Werkzeug laeuft nur lokal.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import random
import resource
import sys
import time

TEXT = ("Erklärung: Eine Matrix ist ein rechteckiges Zahlenschema mit m Zeilen und n Spalten. "
        "Die Determinante einer quadratischen Matrix sagt, ob sie invertierbar ist. ") * 6   # ~900 Zeichen wie eine kurze Antwort
USAGE = {"input_tokens": 1500, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 220,
         "output_tokens_details": {"reasoning_tokens": 0}}

open_conns = 0
answered = 0
errors = 0


def _raise_nofile() -> None:
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = min(hard if hard != resource.RLIM_INFINITY else 1 << 20, 1 << 20)
    if soft < want:
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
        except (ValueError, OSError):
            pass


async def _read_request(reader: asyncio.StreamReader) -> tuple[str, dict, bytes]:
    head = await reader.readuntil(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    request_line = lines[0]
    headers = {}
    for ln in lines[1:]:
        if ":" in ln:
            k, v = ln.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    n = int(headers.get("content-length") or 0)
    body = await reader.readexactly(n) if n else b""
    return request_line, headers, body


def _sse(obj: dict) -> bytes:
    return b"event: " + str(obj.get("type", "")).encode() + b"\ndata: " + json.dumps(obj).encode("utf-8") + b"\n\n"


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, delay: float, jitter: float, status: int) -> None:
    global open_conns, answered, errors
    open_conns += 1
    try:
        while True:                                   # Keep-Alive: mehrere Anfragen je Verbindung
            try:
                request_line, headers, body = await asyncio.wait_for(_read_request(reader), timeout=120)
            except (asyncio.IncompleteReadError, asyncio.TimeoutError, ConnectionError):
                return
            try:
                req = json.loads(body or b"{}")
            except ValueError:
                req = {}
            model = str(req.get("model") or "gpt-6-luna")
            if status >= 400:
                payload = json.dumps({"error": {"message": "Rate limit reached for requests", "type": "requests", "code": "rate_limit_exceeded"}}).encode()
                writer.write(f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n"
                             "Connection: keep-alive\r\n\r\n".encode() + payload)
                await writer.drain()
                answered += 1
                continue
            await asyncio.sleep(delay + (random.random() * jitter if jitter > 0 else 0.0))
            rid = "resp_" + str(int(time.time() * 1000))
            chunks = [TEXT[i:i + 120] for i in range(0, len(TEXT), 120)]
            events = [_sse({"type": "response.created", "response": {"id": rid, "model": model}})]
            events += [_sse({"type": "response.output_text.delta", "delta": c}) for c in chunks]
            events.append(_sse({"type": "response.completed", "response": {
                "id": rid, "model": model, "status": "completed", "usage": USAGE,
                "output": [{"type": "message", "content": [{"type": "output_text", "text": TEXT}]}]}}))
            payload = b"".join(events)
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n"
                         + f"Content-Length: {len(payload)}\r\nConnection: keep-alive\r\n\r\n".encode() + payload)
            await writer.drain()
            answered += 1
            if headers.get("connection", "").lower() == "close" or request_line.endswith("HTTP/1.0"):
                return
    except Exception:  # noqa: BLE001 - Verbindung weg
        errors += 1
    finally:
        open_conns -= 1
        try:
            writer.close()
        except Exception:  # noqa: BLE001
            pass


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--delay", type=float, default=10.0, help="Wartezeit je Anfrage in Sekunden")
    ap.add_argument("--jitter", type=float, default=0.0, help="zufaellig bis zu so viele Sekunden dazu")
    ap.add_argument("--status", type=int, default=200, help="Fehlerantwort statt Text, z. B. 429 oder 503")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    _raise_nofile()
    server = await asyncio.start_server(lambda r, w: handle(r, w, a.delay, a.jitter, a.status), "127.0.0.1", a.port, backlog=8192)
    print(f"Schein-Anbieter auf http://127.0.0.1:{a.port}/v1 (Wartezeit {a.delay} s + 0..{a.jitter} s, Status {a.status})", file=sys.stderr, flush=True)

    async def report():
        while True:
            await asyncio.sleep(5)
            if not a.quiet:
                print(f"[anbieter] offen={open_conns} beantwortet={answered} fehler={errors}", file=sys.stderr, flush=True)
    asyncio.create_task(report())
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
