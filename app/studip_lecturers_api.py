"""Lehrende und Kontakte (LUH, Stud.IP) am PC und in der Windows-App (06.11.2026, docs/LEHRENDE-KONTAKTE-2026-11-06.md);
gleiche Antwort wie der Swift-Kern (`StudIPLecturersEndpoints`).

- GET  /api/lecturers[?course_id=|module_id=][&q=]   Lehrende eines Kurses, eines Moduls oder aller aktiven Kurse
- POST /api/lecturers/{user_id}/message              {subject, text}: Nachricht ueber Stud.IP (nur an Lehrende der eigenen
                                                      Kurse, genau ein Versuch, nur auf Knopfdruck; app/studip_reply.py)
Im Dienst: `available: false` (E-Mail-Adressen bleiben auf dem Geraet bzw. PC), Senden 404.
"""
from __future__ import annotations

import urllib.error

from fastapi import APIRouter, Body, HTTPException

from . import config, db, studip_lecturers, studip_live, studip_reply
from .mensa_api import _university

router = APIRouter(prefix="/api/lecturers", tags=["lecturers"])


@router.get("")
def api_lecturers(course_id: str | None = None, module_id: int | None = None, q: str | None = None):
    with db.cursor() as conn:
        return studip_lecturers.overview(conn, _university(), config.STUDIP_BASE, course_id=course_id or None,
                                         module_id=module_id, q=q, allowed=not config.is_hosted())


@router.post("/{user_id}/message")
def api_message(user_id: str, b: dict = Body(...)):
    if config.is_hosted() or not studip_live.available():
        raise HTTPException(404, {"detail": "Nachrichten über Stud.IP gibt es nur in der Windows-App mit Stud.IP.", "code": "not_available"})
    with db.cursor() as conn:
        person = studip_lecturers.known_person(conn, user_id)
    if person is None:                       # nur Lehrende der eigenen Kurse, nie eine beliebige Kennung
        raise HTTPException(404, {"detail": "Diese Person steht nicht bei deinen Lehrenden.", "code": "not_found"})
    text = str(b.get("text") or "")
    subject = str(b.get("subject") or "").strip()[:studip_reply.MAX_SUBJECT]
    if not text.strip():
        raise HTTPException(400, {"detail": "Bitte einen Text schreiben.", "code": "reply_empty"})
    if not subject:
        raise HTTPException(400, {"detail": "Bitte einen Betreff schreiben.", "code": "reply_no_subject"})
    if len(text) > studip_reply.MAX_TEXT:
        raise HTTPException(400, {"detail": "Der Text ist zu lang.", "code": "reply_too_long"})
    web = studip_lecturers.message_url(studip_live.base(), person["username"])
    try:
        new_id = studip_reply.send(subject, text.strip(), [user_id])
    except studip_live.NotConnected:
        raise HTTPException(409, {"detail": studip_reply.ERRORS["not_connected"], "code": "studip_not_connected", "web_url": web})
    except studip_live.SessionExpired:
        raise HTTPException(409, {"detail": studip_reply.ERRORS["login"], "code": "studip_login", "web_url": web})
    except studip_reply.ReplyError as e:
        raise HTTPException(502 if e.code == "http" else 409, {"detail": e.message.replace("Antworte", "Schreib"), "code": f"reply_{e.code}",
                                                               "web_url": web})
    except (urllib.error.URLError, OSError, TimeoutError):
        raise HTTPException(503, {"detail": studip_reply.ERRORS["offline"], "code": "reply_offline", "web_url": web})
    return {"sent": True, "sent_id": new_id, "to": person["name"], "notice": studip_reply.NOTICE,
            "outbox_url": studip_reply.outbox_web_url(studip_live.base())}
