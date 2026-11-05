"""Mensa am PC und im Dienst (05.11.2026, docs/MENSA-2026-11-05.md): gleiche Antworten wie der Swift-Kern
(Mensa/MensaEndpoints.swift). In jedem Tarif frei, ohne Konto-Daten; der Server holt die oeffentlichen Speiseplaene
(app/mensa.py) und haelt sie je Mensa im Cache.

- GET /api/mensa/canteens[?university=luh|hsh|hildesheim]: Mensen (eigene Region zuerst), Standard-Mensa der Hochschule,
  Preisgruppen, Kennzeichen und Allergene fuer die Filter.
- GET /api/mensa/menu?canteen=hauptmensa&date=2026-11-05[&days=7]: Tage mit Status open/closed/none und Speisen.
"""
from __future__ import annotations

from datetime import date

from fastapi import APIRouter, HTTPException
from starlette.concurrency import run_in_threadpool

from . import db, mensa

router = APIRouter(prefix="/api/mensa", tags=["mensa"])


def _university() -> str:
    try:
        conn = db.connect()
        try:
            r = conn.execute("SELECT value FROM settings WHERE key='university'").fetchone()
        finally:
            conn.close()
        if r and r[0]:
            return str(r[0])
    except Exception:  # noqa: BLE001 - ohne Datenbank (Dienst ohne Anmeldung) die Uni dieser Instanz
        pass
    try:
        from . import universities
        return universities.current_key()
    except Exception:  # noqa: BLE001
        return "luh"


@router.get("/canteens")
def canteens(university: str | None = None):
    return mensa.canteens_response(university or _university())


@router.get("/menu")
async def menu(canteen: str | None = None, date: str | None = None, days: int = 1, university: str | None = None):  # noqa: A002
    cid = canteen or mensa.default_canteen(university or _university())
    if not mensa.canteen(cid):
        raise HTTPException(404, "Diese Mensa kenne ich nicht.")
    try:
        day = _parse_date(date)
    except ValueError:
        raise HTTPException(400, "Datum bitte als JJJJ-MM-TT.") from None
    return await run_in_threadpool(mensa.menu, cid, day, days)


def _parse_date(s: str | None):
    return date.fromisoformat(s) if s else None
