"""Raumfinder am PC und im Dienst (05.11.2026, docs/RAUMFINDER-2026-11-05.md): gleiche Antworten wie der Swift-Kern
(Rooms/LocalRooms.swift, `RoomsEndpoints`). In jedem Tarif frei, ohne Konto-Daten.

- GET /api/rooms/search?q=F102[&page=0]: Suche im Standortfinder der LUH (Raeume, Gebaeude, Einrichtungen) mit Kartenlinks
- GET /api/rooms/resolve?text=1101 - F102[&university=luh]: Raumangabe aus Stundenplan, Lernkalender oder Klausur aufloesen
- GET /api/rooms/campuses[?university=hsh]: Standorte der Hochschule mit Adresse und Kartenlinks
"""
from __future__ import annotations

from fastapi import APIRouter
from starlette.concurrency import run_in_threadpool

from . import rooms
from .mensa_api import _university

router = APIRouter(prefix="/api/rooms", tags=["rooms"])


@router.get("/search")
async def search(q: str | None = None, page: int = 0):
    return await run_in_threadpool(rooms.search, q, page)


@router.get("/resolve")
async def resolve(text: str | None = None, university: str | None = None):
    return await run_in_threadpool(rooms.resolve, text, university or _university())


@router.get("/campuses")
def campuses(university: str | None = None):
    return rooms.campuses(university or _university())
