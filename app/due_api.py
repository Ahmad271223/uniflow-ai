"""Endpunkte "Abgaben & Prüfungen" (erkannte Fristen, app/due_store.py), gleiche Form wie DueEndpoints.swift auf dem iPad:

- GET   /api/due[?module_id=&hidden=1]  kommende Termine (erkannte, Learnweb/Courseware-Fristen, Klausurtermine der Module)
                                        mit days_left/in_days; rechnet vorher neu, wenn sich die Eingaben geaendert haben
- POST  /api/due/refresh                neu erkennen (ohne geaenderte Eingaben nichts); {hits, changed}
- POST  /api/due/backfill?limit=20      Seitentexte lokaler PDFs ohne Text lesen (nur Dateien auf der Platte, nie ueber
                                        das Netz) und gleich pruefen; {read, remaining}
- PATCH /api/due/{id}                   {"hidden": true} ("stimmt nicht"), {"hidden": false}, {"confirmed": true},
                                        {"time": "14:00"} bzw. {"time": null}; 404 fuer unbekannte Termine
Lernkalender, Stundenplan und Uebersicht zeigen die erkannten in `deadlines` bzw. `upcoming` (holidays.calendar_extras,
study.upcoming_deadlines). Erinnerungen daran plant die Oberflaeche (app/static/due-reminders.js).
"""
from __future__ import annotations

import re
from pathlib import Path

from fastapi import APIRouter, Body, HTTPException

from . import db, scriptsearch
from . import due_store as S

router = APIRouter()
TIME_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


@router.get("/api/due")
def api_due(module_id: int | None = None, hidden: bool = False):
    with db.cursor() as conn:
        return S.list_due(conn, module_id=module_id, include_hidden=hidden)


@router.post("/api/due/refresh")
def api_due_refresh():
    with db.cursor() as conn:
        return S.refresh_all(conn)


def _candidates(conn, limit: int) -> list[dict]:
    S.ensure_tables(conn)
    scriptsearch.ensure_table(conn)
    return db.rows(conn, f"""SELECT f.id, f.local_path, COALESCE(f.chdate, 0) AS chdate FROM files f JOIN courses c ON c.id=f.course_id
                             WHERE {S.FILE_FILTER} AND COALESCE(f.local_path, '') <> '' AND lower(f.local_path) LIKE '%.pdf'
                               AND NOT EXISTS (SELECT 1 FROM page_texts p WHERE p.file_id=f.id AND COALESCE(p.chdate, 0)=COALESCE(f.chdate, 0))
                               AND NOT EXISTS (SELECT 1 FROM due_meta m WHERE m.key='unreadable:' || f.id AND m.value=CAST(COALESCE(f.chdate, 0) AS TEXT))
                             ORDER BY f.chdate DESC, f.id LIMIT ?""", (limit,))


@router.post("/api/due/backfill")
def api_due_backfill(limit: int = 20):
    limit = min(max(limit, 1), 100)
    read = 0
    with db.cursor() as conn:
        for f in _candidates(conn, limit):
            pages = scriptsearch.page_texts(conn, f["id"]) if Path(f["local_path"]).exists() else []
            if any((p or "").strip() for p in pages):
                read += 1
            else:
                # nicht lesbar oder nicht auf der Platte: erst mit einer neuen Fassung wieder versuchen
                conn.execute("INSERT INTO due_meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                             ("unreadable:" + f["id"], str(f["chdate"])))
        remaining = len(_candidates(conn, 10_000))
    return {"read": read, "remaining": remaining}


@router.patch("/api/due/{gid}")
def api_due_update(gid: str, body: dict = Body(default={})):
    def flag(k):
        v = body.get(k)
        if v is None:
            return None
        if not isinstance(v, bool):
            raise HTTPException(422, f"{k}: true oder false erwartet")
        return v
    hidden, confirmed = flag("hidden"), flag("confirmed")
    time = S.UNSET
    if "time" in body:
        v = body["time"]
        if v is None:
            time = None
        elif isinstance(v, str) and TIME_RE.match(v):
            time = v
        else:
            raise HTTPException(422, "time: Uhrzeit als HH:MM erwartet")
    with db.cursor() as conn:
        r = S.update(conn, gid, hidden=hidden, confirmed=confirmed, time=time)
    if r is None:
        raise HTTPException(404, "Termin nicht gefunden")
    return r
