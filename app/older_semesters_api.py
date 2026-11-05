"""Fruehere Semester in der Bibliothek (Routen wie OlderSemesterEndpoints in der iPad-App, Logik in app/older_semesters.py).

GET  /api/older-semesters                       Wahl, aktuelles Semester und die frueheren mit ihren Kursen
POST /api/older-semesters/choice                {"choice": "current" | "all"} (fruehere Form der Wahl)
POST /api/older-semesters/mode                  {"mode": "auto" | "wifi" | "off"}: "Ältere Semester laden" (app/sync_order.py)
POST /api/older-semesters/request               {"course_ids": [...]}: "Dateien laden" vormerken und den Abgleich der
                                                Hochschule nur fuer diese Kurse starten
POST /api/older-semesters/load                  den Abgleich fuer vorgemerkte Kurse starten (nach der Wahl "all")
GET  /api/older-semesters/courses/{id}/files    Dateien eines Kurses (auch eines inaktiven)
"""
from __future__ import annotations

from fastapi import APIRouter, Body, HTTPException

from . import config, db, older_semesters, vault

router = APIRouter(prefix="/api/older-semesters", tags=["older-semesters"])

QUEUED_NOTE = "Vorgemerkt: Die Dateien kommen mit dem nächsten Abgleich."
STARTED_NOTE = "Die Dateien werden geladen. Das dauert einen Moment."


def start_loading() -> dict:
    """Abgleich nur fuer die Dateien der gewuenschten fruehen Kurse starten (PC: Hintergrundlauf ohne KI und
    Stundenplan; Dienst: ein normaler Abgleich-Job, der die vorgemerkten Kurse mitnimmt). Laeuft schon einer, holt der
    naechste Abgleich die vorgemerkten Kurse. Rueckgabe: {"started": bool, "note": Text}."""
    from . import server
    if config.is_hosted():
        uid = config.current_user_id()
        if not uid or not vault.has_university_credentials(uid, config.university()):
            return {"started": False, "note": QUEUED_NOTE}
        from . import jobs
        j = jobs.enqueue(uid, "sync", "manual")
        return {"started": not j.get("already"), "note": QUEUED_NOTE if j.get("already") else STARTED_NOTE}
    from . import sync_order
    from .studip_sync import run_sync
    if sync_order.older_active():                      # Stufe (d) laeuft schon im Hintergrund und nimmt sie mit
        return {"started": False, "note": QUEUED_NOTE}
    try:
        server._run_bg("Frühere Semester", lambda: run_sync(older_only=True)["message"])
    except HTTPException as e:
        if e.status_code == 409:                       # es laeuft schon ein Abgleich
            return {"started": False, "note": QUEUED_NOTE}
        raise
    return {"started": True, "note": STARTED_NOTE}


@router.get("")
def api_overview():
    with db.cursor() as conn:
        return older_semesters.overview(conn)


@router.post("/choice")
def api_choice(body: dict = Body(...)):
    value = body.get("choice")
    if value not in older_semesters.CHOICES:
        raise HTTPException(422, "choice: current oder all")
    with db.cursor() as conn:
        older_semesters.set_choice(conn, value, db.now_iso())
    return {"choice": value}


@router.post("/mode")
def api_mode(body: dict = Body(...)):
    """"Ältere Semester laden: Automatisch / Nur WLAN / Aus" (Einstellungen → Module). Nicht "Aus": Stufe (d) startet
    gleich im Hintergrund (PC, nur waehrend die App offen ist), sonst haelt eine laufende an."""
    from . import sync_order
    value = body.get("mode")
    if value not in older_semesters.MODES:
        raise HTTPException(422, "mode: auto, wifi oder off")
    with db.cursor() as conn:
        older_semesters.set_mode(conn, value, db.now_iso())
    if value == "off":
        sync_order.stop_older(wait_s=0)
        started = False
    else:
        started = sync_order.start_older_background()
    return {"mode": value, "started": started}


@router.post("/request")
def api_request(body: dict = Body(...)):
    ids = body.get("course_ids") or []
    if not isinstance(ids, list):
        raise HTTPException(422, "course_ids: Liste")
    with db.cursor() as conn:
        n = older_semesters.request(conn, [i for i in ids if isinstance(i, str)], db.now_iso())
    out = {"requested": n}
    if n:
        out.update(start_loading())
    return out


@router.post("/load")
def api_load():
    with db.cursor() as conn:
        n = len(older_semesters.pending(conn))
    if not n:
        return {"started": False, "note": "Keine Dateien früherer Semester zu laden."}
    return start_loading()


@router.get("/courses/{course_id}/files")
def api_course_files(course_id: str):
    with db.cursor() as conn:
        files = older_semesters.course_files(conn, course_id)
    if files is None:
        raise HTTPException(404, "Kurs nicht gefunden")
    return files
