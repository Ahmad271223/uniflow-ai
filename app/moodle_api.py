"""Abgeben in einer Moodle-Aufgabe am PC (Windows-App/Einzelplatz; HsH-Moodle und Learnweb der Uni Hildesheim),
Vorlage: MoodleSubmitSheet.swift auf dem iPad, Regeln in app/moodle.py (docs/HSH-2026-11-05.md).

GET  /api/moodle/assign                       Aufgaben aus den Moodle-Fristen, Verbindung, Hinweis, Verlauf
GET  /api/moodle/assign/{cmid}                Stand der Aufgabe live (Abgabestatus, Bewertungsstatus, Versuch)
POST /api/moodle/assign/{cmid}/draft          PDF als Entwurf hochladen und speichern (noch KEINE Abgabe)
GET  /api/moodle/assign/{cmid}/confirm        Bestaetigungsseite lesen: verlangt die Aufgabe eine Erklaerung?
POST /api/moodle/assign/{cmid}/submit         "Jetzt abgeben" (mit Erklaerung, falls verlangt)

Jeder schreibende Schritt genau einmal und nur auf Knopfdruck; im Dienst (hosted) gibt es das nicht. Gespeichert wird nur
ein knapper Verlauf (Aufgabe, Zeitpunkt, Schritt), nie der Dateiname der Abgabe.
"""
from __future__ import annotations

import json

from fastapi import APIRouter, Body, File, Form, HTTPException, UploadFile

from . import db, moodle

router = APIRouter(prefix="/api/moodle/assign", tags=["moodle-assign"])

LOG_KEY = "moodle_submit_log"
LOG_LIMIT = 50
MAX_UPLOAD = 50 * 1024 * 1024
WARNING = ("Abgegeben wird erst mit „Jetzt abgeben“. „Als Entwurf hochladen“ legt die PDF nur in deinen Entwurf; prüfe "
           "danach in {name}, ob alles stimmt. StudiNow wiederholt nichts von selbst.")


def _instance() -> dict:
    from . import config
    inst = moodle.instance()
    if config.is_hosted() or inst is None:
        raise HTTPException(404, {"detail": "Abgeben in Moodle gibt es nur in der Windows-App an der HsH und der Uni Hildesheim.",
                                  "code": "not_available"})
    return inst


def _web(inst: dict) -> moodle.MoodleWeb:
    return moodle.live(inst)


def _fail(e: Exception, inst: dict, cmid: int | None = None):
    web = f"{inst['base']}/mod/assign/view.php?id={int(cmid)}" if cmid else None
    if isinstance(e, moodle.MoodleError):
        if e.code == "login":
            raise HTTPException(409, {"detail": f"Die {inst['name']}-Anmeldung ist abgelaufen. Bitte neu anmelden.", "code": "moodle_login", "web_url": web})
        if e.code == "offline":
            raise HTTPException(503, {"detail": f"Keine Verbindung zu {inst['name']}.", "code": "moodle_offline", "web_url": web})
        status = 409 if e.code == "refused" else 502
        raise HTTPException(status, {"detail": e.message, "code": f"moodle_{e.code}", "web_url": web})
    raise e


def history(conn) -> list[dict]:
    r = conn.execute("SELECT value FROM settings WHERE key=?", (LOG_KEY,)).fetchone()
    try:
        v = json.loads(r[0]) if r and r[0] else []
    except ValueError:
        v = []
    return [x for x in v if isinstance(x, dict)] if isinstance(v, list) else []


def add_history(conn, record: dict) -> None:
    items = [record, *history(conn)][:LOG_LIMIT]
    conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", (LOG_KEY, json.dumps(items, ensure_ascii=False)))


def history_line(r: dict) -> str:
    from . import studip_reply
    d = studip_reply.instant(r.get("at"))
    when = d.astimezone(studip_reply.BERLIN).strftime("%d.%m.%Y, %H:%M") if d else ""
    verb = "Abgegeben" if r.get("step") == "submit" else "Entwurf hochgeladen"
    return f"{verb} am {when}: {r.get('title') or 'Aufgabe'}"


def _record(conn, cmid: int, step: str, state: str) -> dict:
    from . import studip_reply
    a = next((x for x in moodle.assignments(conn) if x["cmid"] == cmid), None)
    rec = {"cmid": cmid, "title": (a or {}).get("title") or "Aufgabe", "at": studip_reply.now_iso(), "step": step, "state": state}
    add_history(conn, rec)
    return {**rec, "line": history_line(rec)}


@router.get("")
def api_assignments():
    inst = _instance()
    from . import filestream
    with db.cursor() as conn:
        items = moodle.assignments(conn)
        hist = [{**r, "line": history_line(r)} for r in history(conn)]
    for a in items:
        a["url"] = f"{inst['base']}/mod/assign/view.php?id={a['cmid']}"
    return {"source": inst["name"], "connected": bool(filestream.cookie_header(inst["session"], inst["base"])),
            "assignments": items, "history": hist, "warning": WARNING.format(name=inst["name"]), "max_upload": MAX_UPLOAD}


@router.get("/{cmid}")
def api_status(cmid: int):
    inst = _instance()
    try:
        return {"cmid": cmid, **moodle.fetch_status(_web(inst), cmid)}
    except Exception as e:  # noqa: BLE001
        _fail(e, inst, cmid)


@router.post("/{cmid}/draft")
async def api_draft(cmid: int, file: UploadFile = File(...), file_name: str = Form(...)):
    inst = _instance()
    name = " ".join(str(file_name or "").replace("/", "_").replace("\\", "_").split())[:120]
    if not name:
        raise HTTPException(400, {"detail": "Bitte einen Dateinamen eingeben.", "code": "bad_name"})
    if not name.lower().endswith(".pdf"):
        name += ".pdf"
    data = await file.read(MAX_UPLOAD + 1)
    if len(data) > MAX_UPLOAD:
        raise HTTPException(413, {"detail": "Die PDF ist zu groß für das Hochladen.", "code": "moodle_too_large"})
    if not data.startswith(b"%PDF"):
        raise HTTPException(400, {"detail": "Das ist keine PDF.", "code": "bad_pdf"})
    from starlette.concurrency import run_in_threadpool
    try:
        st, saved = await run_in_threadpool(moodle.save_draft, _web(inst), cmid, data, name)
    except Exception as e:  # noqa: BLE001
        _fail(e, inst, cmid)
    with db.cursor() as conn:
        rec = _record(conn, cmid, "draft", st["state"])
    return {"cmid": cmid, "status": st, "saved_name": saved, "record": rec}


@router.get("/{cmid}/confirm")
def api_confirm(cmid: int):
    inst = _instance()
    try:
        form = moodle.fetch_confirm(_web(inst), cmid)
    except Exception as e:  # noqa: BLE001
        _fail(e, inst, cmid)
    return {"cmid": cmid, "statement": form["statement"]}


@router.post("/{cmid}/submit")
def api_submit(cmid: int, b: dict = Body(default={})):
    inst = _instance()
    try:
        st = moodle.submit(_web(inst), cmid, bool(b.get("statement_accepted")))
    except Exception as e:  # noqa: BLE001
        _fail(e, inst, cmid)
    with db.cursor() as conn:
        rec = _record(conn, cmid, "submit", st["state"])
    return {"cmid": cmid, "status": st, "record": rec}
