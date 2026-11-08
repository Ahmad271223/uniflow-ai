"""Asynchroner Weg der StudiNow-KI im Dienst (08.11.2026, Lastfestigkeit; docs/release/BETRIEB.md "Kapazitaet und
Lastgrenzen").

Vorher waren die KI-Endpunkte synchrone Funktionen: jede Frage belegte fuer 5-30 s einen der 40 Plaetze des allgemeinen
Thread-Pools je Prozess (anyio-Standard). Ab etwa 80 gleichzeitigen Fragen warteten darum ALLE Endpunkte (Anmelden,
Abo-Stand, Abgleich; gemessen 10 s bei 80, 50 s bei 300). Jetzt sind die KI-Endpunkte `async def`: der Anbieter wird
asynchron gefragt (httpx bzw. Async-SDK, app/ai_backend.complete_async), eine offene Frage ist nur eine wartende
Verbindung. Die kurzen Datenbankschritte (Credits, Budget, Protokoll, Seitentexte) laufen in einem EIGENEN kleinen
Thread-Begrenzer, nie im allgemeinen Pool.

Schalter (deploy/.env):
    LERNAPP_AI_CONCURRENCY   gleichzeitige KI-Anfragen je Prozess (Standard 5000, nur Notbremse); darueber sofort 503
                             ai_overloaded mit Retry-After statt endlosem Warten
    LERNAPP_AI_DB_THREADS    Threads je Prozess fuer die Datenbankschritte der KI-Anfragen (Standard 8)
    LERNAPP_AI_SYNC_THREADS  Threads je Prozess fuer synchrone Anbieter (Attrappen in Tests, ChatGPT-Abo am PC; Standard 64)
    LERNAPP_AI_TIMEOUT_S     Zeitlimit je Verbindung zum Anbieter (Standard 90 s, app/ai_backend.timeout_s)
"""
from __future__ import annotations

import contextlib
import os
from functools import partial

from fastapi import HTTPException

OVERLOADED_CODE = "ai_overloaded"
OVERLOADED_MESSAGE = "Die KI ist gerade ausgelastet, bitte gleich noch einmal."
OVERLOADED_RETRY_AFTER_S = 3

_inflight = 0
_db_limiter = None
_provider_limiter = None


def _env_int(name: str, default: int, low: int = 1) -> int:
    try:
        return max(low, int(os.environ.get(name) or default))
    except ValueError:
        return default


def concurrency_limit() -> int:
    return _env_int("LERNAPP_AI_CONCURRENCY", 5000)


def inflight() -> int:
    """Gerade laufende KI-Anfragen in diesem Prozess (Betrieb, Tests)."""
    return _inflight


def db_limiter():
    """Begrenzer fuer die Datenbankschritte der KI-Anfragen (eigene Threads, nicht der allgemeine Pool von 40)."""
    global _db_limiter
    if _db_limiter is None:
        import anyio
        _db_limiter = anyio.CapacityLimiter(_env_int("LERNAPP_AI_DB_THREADS", 8))
    return _db_limiter


def provider_limiter():
    global _provider_limiter
    if _provider_limiter is None:
        import anyio
        _provider_limiter = anyio.CapacityLimiter(_env_int("LERNAPP_AI_SYNC_THREADS", 64))
    return _provider_limiter


async def db(fn, *args, **kwargs):
    """Kurzen synchronen Schritt (SQLite, Seitentexte, Kontingent) in einem Thread des eigenen Begrenzers ausfuehren.
    Der Kontext (Konto, Hochschule, Einwilligung - contextvars) geht mit."""
    import anyio
    return await anyio.to_thread.run_sync(partial(fn, *args, **kwargs), limiter=db_limiter())


_detached: list = []


def db_detached(fn, *args, **kwargs):
    """Aufraeumen nach einem Abbruch (Credits/Kontingent zurueck): in einem eigenen Thread, unabhaengig von der Ereignisschleife.
    `await asyncio.shield(db(...))` im `except CancelledError` reicht nicht: Starlette laeuft in einem anyio-Cancel-Scope, der
    jedes weitere await sofort erneut abbricht; der abgeschirmte Schritt blieb dann als lose Aufgabe liegen und ging bei
    Prozessende verloren (unter Python 3.12 des Dienstes nachgestellt, 08.11.2026). Der Kontext (Konto) geht mit."""
    import contextvars
    import threading
    ctx = contextvars.copy_context()
    t = threading.Thread(target=ctx.run, args=(partial(fn, *args, **kwargs),), name="ai-aufraeumen", daemon=False)
    t.start()
    _detached.append(t)
    del _detached[:-64]
    return t


def wait_detached(timeout: float = 10.0) -> None:
    """Fuer Tests und das Herunterfahren: auf laufende Aufraeum-Threads warten."""
    for t in list(_detached):
        t.join(timeout)


def overloaded() -> HTTPException:
    return HTTPException(503, {"detail": OVERLOADED_MESSAGE, "code": OVERLOADED_CODE, "retry_after": OVERLOADED_RETRY_AFTER_S},
                         headers={"Retry-After": str(OVERLOADED_RETRY_AFTER_S)})


@contextlib.asynccontextmanager
async def slot():
    """Platz fuer eine KI-Anfrage in diesem Prozess. Ueber LERNAPP_AI_CONCURRENCY hinaus wird nicht gewartet, sondern
    sofort mit 503 ai_overloaded und Retry-After geantwortet (Notbremse; die Clients wiederholen mit derselben request_id,
    die nie doppelt berechnet wird)."""
    global _inflight
    if _inflight >= concurrency_limit():
        raise overloaded()
    _inflight += 1
    try:
        yield
    finally:
        _inflight -= 1


def http_error(e) -> HTTPException:
    """AIUnavailable -> HTTPException wie bisher ({detail, code, ...}); bei "ausgelastet" (ai_provider_busy, 503) mit
    Retry-After, damit die Clients nach ein paar Sekunden von selbst noch einmal fragen."""
    extra = dict(getattr(e, "extra", None) or {})
    headers = None
    if extra.get("retry_after"):
        headers = {"Retry-After": str(int(extra["retry_after"]))}
    return HTTPException(e.status, {"detail": e.message, "code": e.code, **extra}, headers=headers)
