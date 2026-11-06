"""Uni-Mail und Uni-Kalender (SOGo der LUH bzw. der Uni Hildesheim, `sogo.SITES`) am PC (Windows-App, Einzelplatz), docs/UNI-MAIL-2026-11-05.md. Gleiche
JSON-Antworten wie der Swift-Kern auf dem iPad (`SOGo`, `UniMailConnection`). Im Dienst (hosted) gibt es nichts davon:
E-Mails gehen nie ueber StudiNow-Server.

GET    /api/sogo/status                     verfuegbar (LUH, Hildesheim)?, Name, Raum-Links?, verbunden?, Konto, ungelesene
POST   /api/sogo/login                      Anmeldefenster oeffnen (der Mensch meldet sich selbst an)
DELETE /api/sogo/session                    abmelden (Sitzung, Konto, Zwischenspeicher, Kalendertermine)
GET    /api/sogo/mailboxes                  Ordner
GET    /api/sogo/messages?folder=&page=&q=  Liste (Seite 0 mit allen UIDs; weitere Seiten je 50)
GET    /api/sogo/message?folder=&uid=       Nachricht lesen (markiert sie in SOGo als gelesen)
GET    /api/sogo/attachment?path=           Anhang herunterladen
POST   /api/sogo/flags                      {"folder","uids","read"?,"flagged"?}
POST   /api/sogo/trash                      {"folder","uids"} in den Papierkorb
POST   /api/sogo/restore                    {"uids"} aus dem Papierkorb zurueck in den Posteingang
POST   /api/sogo/draft                      {"action": compose|reply|replyall|forward, "folder", "uid"} -> Entwurf
POST   /api/sogo/draft/save                 {"draft", "to","cc","bcc","subject","text"} als Entwurf speichern
POST   /api/sogo/draft/attach               multipart (draft als JSON, file) Anhang hochladen
POST   /api/sogo/draft/send                 wie save, dazu "confirm": true (nur vom Knopf "Senden"); genau ein Versuch
POST   /api/sogo/calendar/import            {"days": 7|30} Termine in den Lernkalender/Stundenplan
GET    /api/sogo/calendar/events?days=      gespeicherte Termine
"""
from __future__ import annotations

import json
from datetime import date, timedelta

from fastapi import APIRouter, Body, File, Form, HTTPException, UploadFile
from fastapi.responses import Response

from . import config, db, sogo

router = APIRouter(prefix="/api/sogo", tags=["sogo"])


def _guard() -> None:
    if config.is_hosted():
        raise HTTPException(404, {"detail": sogo.NOT_AVAILABLE, "code": "not_available"})


def _fail(e: Exception):
    if isinstance(e, sogo.SOGoError):
        if e.code == "login":
            raise HTTPException(409, {"detail": "Die Anmeldung bei Uni-Mail ist abgelaufen. Bitte neu anmelden.", "code": "sogo_login"})
        if e.code == "offline":
            raise HTTPException(503, {"detail": "Keine Verbindung zu Uni-Mail (SOGo).", "code": "sogo_offline"})
        if e.code == "input":
            raise HTTPException(400, {"detail": e.detail, "code": "sogo_input"})
        if e.code == "refused":
            raise HTTPException(404, {"detail": e.detail, "code": "not_available"})
        raise HTTPException(502, {"detail": e.detail or f"Unerwartete Antwort von SOGo ({e.code}).", "code": f"sogo_{e.code}"})
    raise e


def _web() -> sogo.SOGoWeb:
    _guard()
    try:
        return sogo.live()
    except Exception as e:  # noqa: BLE001
        _fail(e)


def _uids(v) -> list[int]:
    u = sogo.flatten_uids(v if isinstance(v, list) else [v])
    if not u or len(u) > 500:
        raise HTTPException(400, {"detail": "uids: 1 bis 500 Nachrichten", "code": "sogo_input"})
    return u


def _folder(v) -> str:
    f = str(v or "INBOX").strip()
    if not f or ".." in f or len(f) > 200:
        raise HTTPException(400, {"detail": "Ordner ungültig", "code": "sogo_input"})
    return f


@router.get("/status")
def status():
    _guard()
    from . import unilogin
    connected = unilogin.has_session(sogo.SESSION)
    user = sogo.saved_user() if connected else None
    with db.cursor() as conn:
        c = sogo.cached(conn, "INBOX")
    window = unilogin.status()
    s = sogo.site()                                   # SOGo der Hochschule dieser Instanz; HsH: keins
    return {"available": s is not None, "university": s["key"] if s else None, "name": s["name"] if s else "Uni-Mail",
            "university_name": s["university"] if s else None, "host": s["host"] if s else None,
            "room_links": bool(s and s["room_links"]),
            "connected": connected, "user": user, "unseen": (c or {}).get("unseen"), "checked_at": (c or {}).get("fetched_at"),
            "window": window if window.get("university") == "sogo" else None,
            "hint": (f"Melde dich auf der echten SOGo-Seite der {s['short']} an. StudiNow merkt sich nur die Sitzung, nie dein Passwort."
                     if s else sogo.NOT_AT_UNI)}


@router.post("/login")
def login():
    _guard()
    if sogo.site() is None:
        raise HTTPException(404, {"detail": sogo.NOT_AT_UNI, "code": "not_available"})
    from . import unilogin
    from .server import _run_bg

    def run():
        out = unilogin.run("sogo")
        user = sogo.discover_user(unilogin.saved_cookies(sogo.SESSION))
        sogo.remember_user(user)
        return out
    return _run_bg("Anmeldung Uni-Mail", run)


@router.delete("/session")
def forget():
    _guard()
    from . import unilogin
    unilogin.forget(sogo.SESSION)
    sogo.remember_user(None)
    with db.cursor() as conn:
        sogo.forget_cache(conn)
        n = sogo.forget_events(conn)
    return {"ok": True, "events_removed": n}


@router.get("/mailboxes")
def mailboxes():
    web = _web()
    try:
        return {"mailboxes": web.mailboxes()}
    except Exception as e:  # noqa: BLE001
        _fail(e)


@router.get("/messages")
def messages(folder: str = "INBOX", page: int = 0, q: str = "", uids: str = ""):
    """Seite 0: Ordner neu lesen (alle UIDs, erste 50); Seite n: `uids` (Komma) aus der ersten Antwort mitschicken"""
    folder = _folder(folder)
    web = _web()
    try:
        if page <= 0:
            listing = web.folder(folder, q)
            if not q:
                with db.cursor() as conn:
                    sogo.store_cache(conn, listing, db.now_iso())
            return listing
        all_uids = [int(x) for x in uids.split(",") if x.strip().isdigit()]
        want = sogo.page_uids(all_uids, page)
        return {"folder": folder, "page": page, "messages": web.headers(folder, want)}
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        if isinstance(e, sogo.SOGoError) and e.code == "offline" and page <= 0 and not q:
            with db.cursor() as conn:
                c = sogo.cached(conn, folder)
            if c:
                return c
        _fail(e)


@router.get("/message")
def message(uid: int, folder: str = "INBOX"):
    web = _web()
    try:
        return web.message(_folder(folder), uid)
    except Exception as e:  # noqa: BLE001
        _fail(e)


@router.get("/attachment")
def attachment(path: str):
    web = _web()
    if not sogo.attachment_path(path, web.host):
        raise HTTPException(400, {"detail": "Anhang ungültig", "code": "sogo_input"})
    try:
        data, ctype = web.attachment(path)
    except Exception as e:  # noqa: BLE001
        _fail(e)
    name = sogo.clean_filename(path.rsplit("/", 1)[-1])
    from urllib.parse import quote
    return Response(data, media_type=ctype, headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}"})


@router.post("/flags")
def flags(b: dict = Body(...)):
    web = _web()
    folder, uids = _folder(b.get("folder")), _uids(b.get("uids"))
    try:
        for u in uids:
            if "read" in b:
                web.mark_read(folder, u, bool(b["read"]))
            if "flagged" in b:
                web.flag(folder, u, bool(b["flagged"]))
    except Exception as e:  # noqa: BLE001
        _fail(e)
    return {"ok": True}


@router.post("/trash")
def trash(b: dict = Body(...)):
    """In den Papierkorb (SOGo verschiebt); die Oberflaeche bietet vorher einige Sekunden "Rückgängig" an und schickt
    erst danach diese Anfrage. Endgueltig geloescht wird nie."""
    web = _web()
    try:
        web.trash(_folder(b.get("folder")), _uids(b.get("uids")))
    except Exception as e:  # noqa: BLE001
        _fail(e)
    return {"ok": True}


@router.post("/restore")
def restore(b: dict = Body(...)):
    web = _web()
    try:
        boxes = web.mailboxes()
        web.move(sogo.folder_of_type(boxes, "trash", "Trash"), _uids(b.get("uids")), sogo.folder_of_type(boxes, "inbox", "INBOX"))
    except Exception as e:  # noqa: BLE001
        _fail(e)
    return {"ok": True}


@router.post("/draft")
def new_draft(b: dict = Body(default={})):
    web = _web()
    action = str(b.get("action") or "compose")
    try:
        return web.new_draft(action, _folder(b.get("folder")), int(b["uid"]) if b.get("uid") else None)
    except Exception as e:  # noqa: BLE001
        _fail(e)


def _body(b: dict) -> tuple[dict, dict]:
    d = b.get("draft")
    if not isinstance(d, dict) or not d.get("draft_id"):
        raise HTTPException(400, {"detail": "Entwurf fehlt", "code": "sogo_input"})
    return d, sogo.payload(d, b.get("to") or [], b.get("cc") or [], b.get("bcc") or [], str(b.get("subject") or ""), str(b.get("text") or ""))


@router.post("/draft/save")
def save(b: dict = Body(...)):
    web = _web()
    d, body = _body(b)
    try:
        return {"ok": True, **web.save(d, body)}
    except Exception as e:  # noqa: BLE001
        _fail(e)


@router.post("/draft/attach")
async def attach(draft: str = Form(...), file: UploadFile = File(...)):
    web = _web()
    try:
        d = json.loads(draft)
    except ValueError:
        raise HTTPException(400, {"detail": "Entwurf fehlt", "code": "sogo_input"}) from None
    data = await file.read(sogo.MAX_ATTACHMENT + 1)
    from starlette.concurrency import run_in_threadpool
    try:
        return await run_in_threadpool(web.attach, d, file.filename or "Anhang", data, file.content_type or "application/octet-stream")
    except Exception as e:  # noqa: BLE001
        _fail(e)


@router.post("/draft/send")
def send(b: dict = Body(...)):
    """Senden nur mit "confirm": true (Knopf "Senden" in der Oberflaeche); genau eine Anfrage an SOGo, kein Wiederholen"""
    if b.get("confirm") is not True:
        raise HTTPException(400, {"detail": "Senden nur über den Knopf „Senden“.", "code": "sogo_confirm"})
    web = _web()
    d, body = _body(b)
    try:
        r = web.send(d, body)
    except Exception as e:  # noqa: BLE001
        _fail(e)
    if not r["ok"]:
        raise HTTPException(409, {"detail": r["message"], "code": "sogo_send_refused"})
    return r


@router.post("/calendar/import")
def calendar_import(b: dict = Body(default={})):
    web = _web()
    days = 30 if int(b.get("days") or 7) > 7 else 7
    today = date.today()
    try:
        events = web.events(today, days)
    except Exception as e:  # noqa: BLE001
        _fail(e)
    with db.cursor() as conn:
        n = sogo.store_events(conn, events, today, today + timedelta(days=days), db.now_iso())
    timed = sum(1 for e in events if not e["all_day"])
    return {"ok": True, "events": n, "timed": timed, "all_day": n - timed, "days": days}


@router.get("/calendar/events")
def calendar_events(days: int = 30):
    _guard()
    today = date.today()
    with db.cursor() as conn:
        return {"events": sogo.stored_events(conn, today, today + timedelta(days=max(1, min(days, 62))))}
