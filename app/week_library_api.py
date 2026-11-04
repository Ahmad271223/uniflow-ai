"""Endpunkte „Fertige Fragen je Vorlesungswoche“ (Pro AI, gehosteter Dienst; Logik in app/week_library.py).

Alle Pfade nehmen Modul und Lehrwoche des EIGENEN Kontos (eigene Datenbank): der Dienst berechnet daraus den Schluessel
der Woche und gibt nie Schluessel oder Listen fremder Inhalte heraus. Recht: can_use_prepared_week_sets (403
plan_required). Neu vorbereiten kostet StudiNow-KI-Budget der Bibliothek und braucht die bestaetigte E-Mail-Adresse
(403 email_unverified); es zaehlt NICHT auf „Neue KI-Tests“. Einen Satz als Test starten zaehlt wie ein Test aus der
Bibliothek (`library_tests`, Pro AI unbegrenzt mit Fair-Use 300).

- GET  /api/library/week-sets/{module_id}                       Stand je Lehrwoche: status, Zahl der Saetze
- GET  /api/library/week-sets/{module_id}/{week}                Themen, Hinweise, Loesungen mit Erklaerung, Saetze
- POST /api/library/week-sets/{module_id}/{week}/prepare        Vorarbeit anstossen {wait_s?: 0..60}; laeuft im
                                                                Hintergrund, Antwort wie GET (status preparing|ready|…)
- POST /api/library/week-sets/{module_id}/{week}/sets/{nr}/start  Satz als eigenen Test anlegen {request_id?}
                                                                -> {test_id, title, question_count, charged}
- GET  /api/library/week-sets/{module_id}/{week}/explain?question_id=…|task=…   Loesung und Erklaerung (ohne KI)

Am eigenen PC (Einzelplatz) gibt es die Bibliothek nicht (501 not_hosted), wie bei /api/library/tests: dort erstellt
die eigene KI die Wochentests (app/weekly.py, app/planner.py).
"""
from __future__ import annotations

import json
import uuid

from fastapi import APIRouter, Body, HTTPException, Request

from . import ai_backend, config, db, entitlements, test_library, week_library

router = APIRouter()
RIGHT = "can_use_prepared_week_sets"
MAX_WAIT_S = 60.0


def _hosted(request: Request) -> dict:
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Fertige Fragen je Vorlesungswoche gibt es im StudiNow-Dienst mit Pro AI. Am "
                                            "eigenen PC erstellt deine eigene KI die Wochentests.", "code": "not_hosted"})
    u = getattr(request.state, "user", None)
    if not u:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    entitlements.require(request, RIGHT)
    return u


def _week(week: int) -> int:
    if not isinstance(week, int) or not 1 <= week <= 30:
        raise HTTPException(400, {"detail": "Lehrwoche 1 bis 30.", "code": "week_invalid"})
    return week


def _module(conn, module_id: int) -> dict:
    m = db.row(conn, "SELECT id, name FROM modules WHERE id=?", (module_id,))
    if not m:
        raise HTTPException(404, {"detail": "Modul nicht gefunden.", "code": "not_found"})
    return m


def _detail(conn, module_id: int, week: int) -> dict:
    key, why = week_library.week_key(conn, module_id, week)
    if not key:
        return {"module_id": module_id, "week": week, **week_library.public(None, why)}
    row = week_library.get(key)
    st = week_library.effective_status(row)
    return {"module_id": module_id, "week": week, **week_library.public(row, st, week_library.own_task_labels(conn, module_id))}


@router.get("/api/library/week-sets/{module_id}")
def week_sets_overview(request: Request, module_id: int):
    _hosted(request)
    with db.cursor() as conn:
        _module(conn, module_id)
        weeks = week_library.overview(conn, module_id)
    return {"module_id": module_id, "sets_per_week": week_library.SETS, "set_size": week_library.SET_SIZE, "weeks": weeks}


@router.get("/api/library/week-sets/{module_id}/{week}")
def week_sets_detail(request: Request, module_id: int, week: int):
    _hosted(request)
    week = _week(week)
    with db.cursor() as conn:
        _module(conn, module_id)
        return _detail(conn, module_id, week)


@router.post("/api/library/week-sets/{module_id}/{week}/prepare")
def week_sets_prepare(request: Request, module_id: int, week: int, body: dict = Body(default={})):
    user = _hosted(request)
    week = _week(week)
    entitlements.require_verified_for_ai(request)            # Vorarbeit kostet KI-Budget: nur mit bestaetigter E-Mail
    try:
        wait_s = min(MAX_WAIT_S, max(0.0, float((body or {}).get("wait_s") or 0)))
    except (TypeError, ValueError):
        wait_s = 0.0
    with db.cursor() as conn:
        _module(conn, module_id)
        key, _ = week_library.week_key(conn, module_id, week)
        row = week_library.get(key) if key else None
        if key and week_library.effective_status(row) in ("ready", "preparing"):
            started = False
        else:
            try:
                snap = week_library.collect(conn, module_id, week, fetch=True)
            except week_library.PrepError as e:
                return {"module_id": module_id, "week": week, "started": False, **week_library.public(None, e.code),
                        "error_code": e.code, "error": e.message}
            key = snap["key"]
            started = False
            if week_library.effective_status(week_library.get(key)) not in ("ready", "preparing"):
                owner = test_library.owner_hash(user["id"])
                if week_library.claims_today(owner) >= week_library.prep_per_day():
                    raise HTTPException(429, {"detail": "Heute hast du schon viele Wochen vorbereiten lassen. Morgen geht es weiter; "
                                                        "fertige Fragen kannst du weiter nutzen.", "code": "library_prep_limit"})
                try:
                    ai_backend.check_library(week_library.CALLS_PER_PREP)
                except ai_backend.AIUnavailable as e:
                    raise HTTPException(e.status, {"detail": e.message, "code": e.code})
                token = week_library.claim(key, owner, snap["university"], snap["module"])
                if token:
                    week_library.start(snap, token)
                    started = True
    if wait_s and key:
        week_library.wait(key, wait_s)
    with db.cursor() as conn:
        return {**_detail(conn, module_id, week), "started": started}


def _ready_row(conn, module_id: int, week: int) -> dict:
    key, why = week_library.week_key(conn, module_id, week)
    row = week_library.get(key) if key else None
    if week_library.effective_status(row) != "ready":
        raise HTTPException(409, {"detail": "Die fertigen Fragen dieser Woche sind noch nicht da.", "code": why or "not_prepared"})
    return row


@router.post("/api/library/week-sets/{module_id}/{week}/sets/{nr}/start")
def week_sets_start(request: Request, module_id: int, week: int, nr: int, body: dict = Body(default={})):
    """Satz als eigenen Test des Kontos anlegen (Bewertung ohne KI: POST /api/tests/{id}/submit). Ein noch nicht
    abgegebener Test desselben Satzes wird wiederverwendet und nicht noch einmal gezaehlt."""
    user = _hosted(request)
    week = _week(week)
    with db.cursor() as conn:
        m = _module(conn, module_id)
        row = _ready_row(conn, module_id, week)
    s = next((x for x in row["sets"] if x["nr"] == nr), None)
    if not s:
        raise HTTPException(404, {"detail": "Diesen Satz gibt es nicht.", "code": "set_not_found"})
    title = f"Fertige Fragen · Lehrwoche {week} · {s['title']}"
    with db.cursor() as conn:
        ex = db.row(conn, "SELECT id FROM tests WHERE module_id=? AND week_no=? AND title=? AND auto=0 AND submitted_at IS NULL",
                    (module_id, week, title))
    if ex:
        return {"test_id": ex["id"], "title": title, "question_count": len(s["question_ids"]), "charged": None, "reused": True}
    qs = [q for q in (test_library.get(i) for i in s["question_ids"]) if q]
    if not qs:
        raise HTTPException(409, {"detail": "Die Fragen dieses Satzes sind nicht mehr da.", "code": "set_empty"})
    rid = str((body or {}).get("request_id") or uuid.uuid4().hex)[:80]
    entitlements.consume(request, "library_tests", rid + ":week")
    questions = [{"nr": i, "type": q["type"], "question": q["question"], "options": q.get("options"), "answer": q["answer"],
                  "explanation": q.get("explanation"), "points": q.get("points") or 10, "topic": q.get("topic"),
                  "difficulty": q.get("difficulty"), "library_id": q["id"]} for i, q in enumerate(qs, start=1)]
    try:
        with db.cursor() as conn:
            cur = conn.execute("""INSERT INTO tests(subject, title, duration_min, questions, created_at, auto, module_id, week_no)
                                  VALUES (?,?,?,?,?,0,?,?)""",
                               (m["name"], title, max(10, 2 * len(questions)), json.dumps(questions, ensure_ascii=False), db.now_iso(),
                                module_id, week))
            test_id = cur.lastrowid
    except Exception:
        entitlements.refund(request, "library_tests", rid + ":week")
        raise
    test_library.mark_used(test_library.owner_hash(user["id"]), [q["id"] for q in qs])
    return {"test_id": test_id, "title": title, "question_count": len(questions), "charged": "library_tests", "reused": False}


@router.get("/api/library/week-sets/{module_id}/{week}/explain")
def week_sets_explain(request: Request, module_id: int, week: int, question_id: str | None = None, task: str | None = None):
    """Vorbereitete Loesung und Erklaerung zu einer Frage eines Satzes oder einer Aufgabe der Woche (ohne KI)."""
    _hosted(request)
    week = _week(week)
    with db.cursor() as conn:
        _module(conn, module_id)
        row = _ready_row(conn, module_id, week)
        labels = week_library.own_task_labels(conn, module_id)
    if question_id:
        if not any(question_id in s["question_ids"] for s in row["sets"]):
            raise HTTPException(404, {"detail": "Diese Frage gehört nicht zu dieser Woche.", "code": "not_found"})
        q = test_library.get(question_id)
        if not q:
            raise HTTPException(404, {"detail": "Frage nicht gefunden.", "code": "not_found"})
        return {"kind": "question", "question_id": q["id"], "question": q["question"], "options": q["options"],
                "answer": q["answer"], "explanation": q["explanation"], "topic": q.get("topic")}
    if task:
        s = next((x for x in row["solutions"] if x["task_hash"] == task), None)
        if not s:
            raise HTTPException(404, {"detail": "Zu dieser Aufgabe gibt es keine vorbereitete Lösung.", "code": "not_found"})
        return {"kind": "task", **s, "label": labels.get(s["task_hash"]) or s["label"]}
    raise HTTPException(400, {"detail": "question_id oder task angeben.", "code": "target_required"})
