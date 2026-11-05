"""Routen der KI-Hilfe fuer das ganze Dokument (05.11.2026, docs/KI-GANZES-DOKUMENT-2026-11-05.md; Regeln in
app/doc_explain.py, lokal gleich in DocExplainEndpoints.swift).

- POST /api/ai/document/plan  {file_id, page, mode?, scope?, question?, page_texts?} -> Plan ohne KI: Schritte, was schon
                               erklaert ist, Kostenzeile ("Kostet etwa 6 Credits, du hast 74."), ob vorher gefragt wird.
                               Mit `question` und ohne `mode`: Absicht aus der Frage; keine -> {intent: false}.
- POST /api/ai/document/step  {file_id, page, mode, scope, step, request_id?, force?, page_texts?} -> ein Schritt:
                               {step, blocks, stored, credits}. Der Plan wird aus dem Dokument neu gebildet; der Client
                               schickt nie einen Prompt.

Im Dienst wie die KI-Hilfe: Recht can_use_ai_explanations (Pro AI, Probe), bestaetigte E-Mail, je Schritt Kontingent
ai_assist und Credits (app/ai_backend.py, app/credits.py), dieselbe request_id wird nie zweimal berechnet. Schon erklaerte
Schritte (doc_explain_cache, fuer alle Konten) kosten 0 und werden als `shared` vermerkt. `page_texts` (Text der Seiten
aus dem Browser) zaehlt nur, wenn der Dienst selbst keinen Seitentext hat.
"""
from __future__ import annotations

import uuid

from fastapi import APIRouter, Body, HTTPException, Request

from . import config, db, doc_explain as de, entitlements

router = APIRouter(prefix="/api/ai/document", tags=["ai"])
# so viele Seiten nimmt der Dienst hoechstens aus `page_texts` an
CLIENT_PAGES_MAX = 1000


def _err(e: de.DocExplainError) -> HTTPException:
    return HTTPException(e.status, {"detail": e.message, "code": e.code})


def _texts(file_id: str, body: dict) -> list[str]:
    from . import scriptsearch
    with db.cursor() as conn:
        if not db.row(conn, "SELECT 1 AS x FROM files WHERE id=?", (file_id,)):
            raise HTTPException(404, {"detail": "Datei nicht gefunden.", "code": "not_found"})
        try:
            pages = scriptsearch.page_texts(conn, file_id)
        except Exception:  # noqa: BLE001 - ohne Seitentext gilt, was der Browser gelesen hat
            pages = []
    if not pages:
        raw = body.get("page_texts")
        if isinstance(raw, list):
            pages = [x[:de.PAGE_CHARS_MAX] if isinstance(x, str) else "" for x in raw[:CLIENT_PAGES_MAX]]
    if not pages:
        raise HTTPException(404, {"detail": "Kein Seitentext vorhanden.", "code": "no_content"})
    return pages


def _way() -> str:
    if config.is_hosted():
        return "credits"
    from . import ai
    return "chatgpt" if ai.uses_chatgpt() else "local"


def _guard(request: Request) -> None:
    if config.is_hosted():
        entitlements.require(request, "can_use_ai_explanations")
        entitlements.require_verified_for_ai(request)


def _build(body: dict) -> tuple[str, dict, list[str], dict]:
    """(mode, scope, texts, plan) aus der Anfrage; plan = de.plan_steps mit aufgeloestem Umfang"""
    file_id = str(body.get("file_id") or "")
    if not file_id:
        raise HTTPException(400, {"detail": "file_id fehlt", "code": "bad_request"})
    mode = body.get("mode")
    if mode not in de.MODES:
        raise HTTPException(400, {"detail": "mode muss lecture oder tasks sein.", "code": "bad_mode"})
    texts = _texts(file_id, body)
    try:
        page = int(body.get("page") or 1)
    except (TypeError, ValueError):
        page = 1
    try:
        scope = de.resolve_scope(body.get("scope"), len(texts), page, texts)
        plan = de.plan_steps(mode, texts, scope["from"], scope["to"])
    except de.DocExplainError as e:
        raise _err(e)
    return mode, scope, texts, plan


def _public(step: dict, cached: bool) -> dict:
    return {"id": step["id"], "kind": step["kind"], "from": step["from"], "to": step["to"], "title": step["title"],
            "tasks": step["tasks"], "cached": cached}


@router.post("/plan")
def plan(request: Request, body: dict = Body(...)):
    if not body.get("mode"):
        it = de.parse_intent(str(body.get("question") or ""))
        if not it:
            return {"intent": False}
        body = {**body, "mode": it["mode"], "scope": it["scope"]}
    _guard(request)
    mode, scope, _texts_, p = _build(body)
    conn = de.connect()
    try:
        have = de.cached_keys(conn, [s["hash"] for s in p["steps"]])
    finally:
        conn.close()
    steps = p["steps"]
    todo = [s for s in steps if s["hash"] not in have]
    way = _way()
    credits, balance, remaining = None, None, None
    if way == "credits":
        from . import ai_backend
        # Modellmischung: je Schritt der Preis des teuersten Modells seines Weges (Aufgaben gehen an Sonnet)
        credits = sum(de.estimate_step_credits(s, ai_backend.estimate_model(f"tutor:doc_{s['kind']}")) for s in todo)
        balance = ai_backend.credits_balance(request.state.user["id"]) if getattr(request.state, "user", None) else None
        remaining = balance.get("remaining") if balance else None
    est = de.estimate_message(way, len(todo), len(steps) - len(todo), credits, remaining)
    title = ("Ganze Vorlesung erklären" if mode == "lecture" else "Alle Aufgaben erklären") + " · " + scope["label"]
    return {"intent": True, "mode": mode, "scope": scope, "title": title, "pages": scope["to"] - scope["from"] + 1,
            "steps": [_public(s, s["hash"] in have) for s in steps], "calls": len(todo), "cached": len(steps) - len(todo),
            "estimate": {"way": way, "credits": credits, "calls": len(todo)}, "balance": balance,
            "skipped_pages": p["skipped_pages"], **est}


@router.post("/step")
def step(request: Request, body: dict = Body(...)):
    _guard(request)
    mode, scope, texts, p = _build(body)
    sid = str(body.get("step") or "")
    st = next((s for s in p["steps"] if s["id"] == sid), None)
    if st is None:
        raise HTTPException(404, {"detail": "Diesen Teil gibt es im Dokument nicht mehr. Bitte neu starten.", "code": "step_not_found"})
    hosted = config.is_hosted()
    second = bool(body.get("second_opinion"))              # "Antwort war falsch": Zweitmeinung von Sonnet, neu erzeugt
    force = bool(body.get("force")) or second
    rid = str(body.get("request_id") or uuid.uuid4().hex)[:80]
    conn = de.connect()
    try:
        hit = None if force else de.cached(conn, st["hash"])
        if hit:
            de.note_hit(conn, st["hash"], hit["variant"])
        sections: list[dict] = []
        if not hit and st["kind"] == "overview":
            for s in p["steps"]:
                if s["kind"] != "lecture":
                    continue
                prev = de.cached(conn, s["hash"])
                if not prev:
                    raise HTTPException(409, {"detail": "Erst die Abschnitte erklären lassen, dann den Überblick.", "code": "sections_missing"})
                sections += de.parse_blocks(prev["text"], s)
    finally:
        conn.close()
    if hit:
        credits_state = None
        if hosted:
            from . import ai_backend, credits as ledger
            lc = ledger.connect()
            try:
                ledger.record_free(lc, request.state.user["id"], rid, f"tutor:doc_{st['kind']}", "shared")
            finally:
                lc.close()
            bal = ai_backend.credits_balance(request.state.user["id"])
            credits_state = {**bal, "charged": 0, "replay": False} if bal else None
        return {"step": sid, "blocks": de.parse_blocks(hit["text"], st),
                "stored": {"stored": True, "source": "cache", "variant": hit["variant"], "created_at": hit["created_at"]},
                "credits": credits_state}
    prompt = de.step_prompt(st, len(texts), sections)
    model_used = None
    credits_state = None
    if hosted:
        from . import ai_backend
        from .server import _ai_replay, _credits_state
        c = _ai_replay(request, rid)
        if c is None:
            entitlements.consume(request, "ai_assist", rid)
            try:
                c = ai_backend.complete(request.state.user["id"], f"tutor:doc_{st['kind']}", de.SYSTEM, prompt, request_id=rid,
                                        keep_result=True, max_output_tokens=de.MAX_OUTPUT[st["kind"]],
                                        route_hint="second_opinion" if second else None)
            except ai_backend.AIUnavailable as e:
                entitlements.refund(request, "ai_assist", rid)
                raise HTTPException(e.status, {"detail": e.message, "code": e.code, **e.extra})
            except Exception:
                entitlements.refund(request, "ai_assist", rid)
                raise
        answer, model_used, credits_state = c.text, c.model, _credits_state(request, c)
    else:
        from . import ai
        try:
            answer = ai.ask(prompt, de.SYSTEM)
        except ai.AIError as e:
            raise HTTPException(500, str(e))
    conn = de.connect()
    try:
        saved = de.store(conn, st["hash"], st["kind"], answer, model_used)
    finally:
        conn.close()
    return {"step": sid, "blocks": de.parse_blocks(answer, st), "stored": saved, "credits": credits_state}
