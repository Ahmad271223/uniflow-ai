"""Ticket fuer den Datei-Eingang (app/intake_server.py), Auftrag des Inhabers vom 18.11.2026.

`POST /api/intake/ticket` {university?} -> {ticket, expires, url}

- Nur mit StudiNow-Konto (im Dienst angemeldet). Welcher Tarif, ist egal ("egal wer sich einloggt").
- Das Ticket traegt keine Konto-ID: der Eingang erfaehrt nie, wer eine Datei geschickt hat.
- Hoechstens TICKETS_PER_DAY Tickets je Konto und Tag (Schutz gegen Missbrauch); gezaehlt in accounts.db, ohne Bezug
  zu den Dateien.
- Ohne LERNAPP_INTAKE_URL und LERNAPP_INTAKE_SECRET (mindestens 32 Zeichen) ist der Eingang aus: 503 intake_off.
"""
from __future__ import annotations

import os
import time

from fastapi import APIRouter, HTTPException, Request

from . import config, entitlements, intake_server

router = APIRouter()

TICKETS_PER_DAY = 30


def intake_url() -> str | None:
    """Adresse des Eingangs; nil = aus. Im Dienst nur https, am eigenen PC auch http (Tests, lokaler Eingang)."""
    url = os.environ.get("LERNAPP_INTAKE_URL", "").strip().rstrip("/")
    if not url or len(os.environ.get("LERNAPP_INTAKE_SECRET", "")) < 32:
        return None
    if url.startswith("https://") or (url.startswith("http://") and not config.is_hosted()):
        return url
    return None


def _count_today(user_id: str) -> int:
    from . import accounts
    day = time.strftime("%Y-%m-%d", time.gmtime())
    with accounts.cursor() as conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS intake_ticket_days (
                            user_id TEXT NOT NULL, day TEXT NOT NULL, n INTEGER NOT NULL DEFAULT 0,
                            PRIMARY KEY (user_id, day))""")
        conn.execute("DELETE FROM intake_ticket_days WHERE day < ?", (day,))
        conn.execute("""INSERT INTO intake_ticket_days(user_id, day, n) VALUES (?,?,1)
                        ON CONFLICT(user_id, day) DO UPDATE SET n=n+1""", (user_id, day))
        return conn.execute("SELECT n FROM intake_ticket_days WHERE user_id=? AND day=?", (user_id, day)).fetchone()["n"]


@router.post("/api/intake/ticket")
async def ticket(request: Request) -> dict:
    url = intake_url()
    if not url:
        raise HTTPException(503, {"detail": "Der Datei-Eingang ist gerade aus.", "code": "intake_off"})
    user = entitlements.user_of(request)
    if config.is_hosted() and not user:
        raise HTTPException(401, {"detail": "Bitte mit dem StudiNow-Konto anmelden.", "code": "login_required"})
    try:
        body = await request.json()
    except Exception:
        body = {}
    uni = (body or {}).get("university") if isinstance(body, dict) else None
    uni = uni if uni in config.known_universities() else (user or {}).get("university")
    if uni not in config.known_universities():
        raise HTTPException(422, {"detail": "Unbekannte Hochschule.", "code": "university_unknown"})
    if user:
        from starlette.concurrency import run_in_threadpool
        if await run_in_threadpool(_count_today, user["id"]) > TICKETS_PER_DAY:
            raise HTTPException(429, {"detail": "Für heute ist genug angekommen.", "code": "intake_limit"},
                                headers={"Retry-After": "3600"})
    t = intake_server.make_ticket(uni, secret=os.environ["LERNAPP_INTAKE_SECRET"].encode())
    return {**t, "url": url}
