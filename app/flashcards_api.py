"""HTTP-Schnittstelle der Karteikarten-Stapel (app/flashcard_stacks.py) und der KI-Auftrag nach Modul und Lernwoche.

Lokal (eigener PC) ohne Konten und Tarife; im Dienst je Konto (eigene Datenbank) mit den Rechten aus app/plans.py:
Karten anlegen `can_create_flashcards` (Plus), Karten aus der Community uebernehmen zusaetzlich `can_share_flashcards`
(Plus), KI-Auftrag `can_generate_ai_flashcards` (Pro AI) mit bestaetigter E-Mail, Kontingent `ai_assist` (Anfrage-ID,
Rueckbuchung bei Fehlern) und Budget/Preispflicht der StudiNow-KI (app/ai_backend.py). Fehler: {"detail", "code"}.
"""
from __future__ import annotations

import uuid

from fastapi import APIRouter, Body, HTTPException, Request

from . import config, db, entitlements
from . import flashcard_stacks as fs

router = APIRouter(tags=["flashcards"])


def _err(e: fs.StackError) -> HTTPException:
    return HTTPException(e.status, {"detail": e.message, "code": e.code})


@router.get("/api/flashcards/stacks")
def stacks():
    """Alle Stapel {stacks: [{key, module_id, module_name, color, lecture_week, label, count, due, right, wrong,
    unlearned, hidden, origins: {own, ai, community}, card_ids}], modules: [{id, name, color, weeks: [{week, label,
    topic, files}]}], current_week}."""
    with db.cursor() as conn:
        return fs.overview(conn)


@router.get("/api/flashcards/stack")
def stack(module_id: int, lecture_week: str | None = None):
    """Karten eines Stapels (lecture_week leer oder 'module' = ganzes Modul)."""
    try:
        w = fs.parse_week(lecture_week)
        with db.cursor() as conn:
            m = fs.module_row(conn, module_id)
            return {"module_id": m["id"], "module_name": m["name"], "lecture_week": w, "cards": fs.stack_cards(conn, m["id"], w)}
    except fs.StackError as e:
        raise _err(e)


@router.post("/api/flashcards/stack")
def add_to_stack(request: Request, body: dict = Body(...)):
    """{module_id, lecture_week (Zahl oder null), cards: [{question, answer}], origin?: 'ai' | 'community:<id>', file_id?}
    -> {added, skipped, ids, module_id, lecture_week}. Gleiche Fragen des Stapels werden uebersprungen."""
    if config.is_hosted():
        entitlements.require(request, "can_create_flashcards")
        if str(body.get("origin") or "").startswith("community:"):
            entitlements.require(request, "can_share_flashcards")
    try:
        with db.cursor() as conn:
            return fs.add_cards(conn, body.get("module_id"), body.get("lecture_week"), body.get("cards"), body.get("origin"), body.get("file_id"))
    except fs.StackError as e:
        raise _err(e)


@router.post("/api/flashcards/move")
def move(request: Request, body: dict = Body(...)):
    """{ids: [int], module_id, lecture_week}: Karten einem Stapel zuordnen."""
    if config.is_hosted():
        entitlements.require(request, "can_create_flashcards")
    try:
        with db.cursor() as conn:
            return fs.move_cards(conn, body.get("ids"), body.get("module_id"), body.get("lecture_week"))
    except fs.StackError as e:
        raise _err(e)


def ai_stack(request: Request, body: dict) -> dict:
    """KI-Auftrag (POST /api/ai/flashcards mit module_id): {module_id, lecture_week, count (5-50), topic?, request_id?,
    material?, again?} (again = andere Karten als beim letzten gleichen Auftrag, ohne Zwischenspeicher) -> {cards, count, module_id, module_name, lecture_week, sources, duplicates_removed, existing}.
    Nur ein Vorschlag; gespeichert wird mit POST /api/flashcards/stack (origin 'ai')."""
    from . import ai
    hosted = config.is_hosted()
    if hosted:
        entitlements.require(request, "can_generate_ai_flashcards")
        entitlements.require_verified_for_ai(request)
    try:
        mid = fs.parse_module(body.get("module_id"))
        week = fs.parse_week(body.get("lecture_week"))
    except fs.StackError as e:
        raise _err(e)
    count = fs.stack_count(body.get("count"))
    topic = str(body.get("topic") or "")[:fs.TOPIC_CHARS]
    with db.cursor() as conn:
        try:
            m = fs.module_row(conn, mid)
        except fs.StackError as e:
            raise _err(e)
        mat = fs.week_material(conn, mid, week)
        existing = fs.module_questions(conn, mid, week)
    if not mat["text"].strip():
        mat = fs.client_material(body.get("material"))
    if not mat["text"].strip():
        what = f"Lernwoche {week}" if week is not None else "dieses Modul"
        raise HTTPException(404, {"detail": f"Für {what} gibt es noch keinen lesbaren Text (Vorlesung, Skript oder Übung). "
                                            "Gleiche zuerst deine Hochschule ab oder wähle eine andere Woche.", "code": "no_content"})
    prompt = fs.stack_prompt(m["name"], week, mat["sources"], mat["text"], count, topic, existing)
    rid = str(body.get("request_id") or uuid.uuid4().hex)[:80]
    if hosted:
        from . import ai_backend
        entitlements.consume(request, "ai_assist", rid)
        try:
            answer = ai_backend.complete(request.state.user["id"], "flashcards_stack", ai.SYSTEM, prompt, schema=ai.FLASHCARDS_SCHEMA,
                                        cache=not body.get("again")).text
        except ai_backend.AIUnavailable as e:
            entitlements.refund(request, "ai_assist", rid)
            raise HTTPException(e.status, {"detail": e.message, "code": e.code})
        except Exception:
            entitlements.refund(request, "ai_assist", rid)
            raise
    else:
        try:
            answer = ai.ask(prompt, ai.SYSTEM, schema=ai.FLASHCARDS_SCHEMA)
        except ai.AIError as e:
            raise HTTPException(500, str(e))
    cards, dropped = fs.without_duplicates(fs.parse_answer(answer, count), existing)
    if not cards:
        if hosted:
            entitlements.refund(request, "ai_assist", rid)       # nichts Brauchbares: nicht auf das Kontingent
        raise HTTPException(502, {"detail": "Die KI hat keine neuen Karteikarten geliefert. Bitte erneut versuchen oder "
                                            "einen anderen Schwerpunkt wählen.", "code": "ai_no_cards"})
    return {"cards": cards, "count": count, "module_id": mid, "module_name": m["name"], "lecture_week": week,
            "sources": mat["sources"], "duplicates_removed": dropped, "existing": len(existing)}
