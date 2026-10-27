"""Endpunkte der gemeinsamen Testbibliothek und der Lernfunktionen ab Pro Connect (gehosteter Dienst).

- POST /api/library/tests                       Test zusammenstellen: erst Pool, dann nur Fehlendes generieren
- POST /api/library/tests/{id}/share            eigenen Test ausdruecklich zur gemeinsamen Nutzung einreichen (Moderation)
- GET  /api/library/moderation                  wartende Fragen (Admin)
- POST /api/library/questions/{id}/moderate     {action: approve | reject} (Admin)
- POST /api/library/tests/{id}/submit           Bewertung ohne KI (Multiple-Choice, Musterloesung)
- GET  /api/learning/stats                      erweiterte Lernstatistiken (can_use_advanced_analytics)
- GET  /api/learning/review                     falsch beantwortete Fragen (can_review_wrong_answers)
- POST /api/learning/review/test                Wiederholungstest aus falschen Antworten, ohne KI
- GET  /api/learning/recommendations            Lernempfehlungen (can_get_recommendations)
"""
from __future__ import annotations

import json
import re
import uuid

from fastapi import APIRouter, Body, HTTPException, Request

from . import ai_backend, config, db, entitlements, test_library

router = APIRouter()

GEN_SYSTEM = ("Du erstellst Übungsfragen für Studierende. Fachlich korrekt, eindeutig, ohne Bezug auf Personen. "
              "Rechne jede Lösung selbst nach. Antworte ausschließlich mit JSON nach dem Schema.")
GEN_SCHEMA = {
    "type": "object", "required": ["questions"],
    "properties": {"questions": {"type": "array", "items": {
        "type": "object", "required": ["question", "options", "answer", "difficulty"],
        "properties": {"question": {"type": "string"}, "options": {"type": "array", "items": {"type": "string"}},
                       "answer": {"type": "string"}, "explanation": {"type": "string"},
                       "difficulty": {"type": "integer", "minimum": 1, "maximum": 5}}}}},
}
MIN_TEST = 3
MAX_TEST = 30


def _hosted(request: Request) -> dict:
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Die gemeinsame Testbibliothek gibt es mit Studora-Konto im Dienst; am eigenen PC "
                                            "erstellt die eigene KI die Tests.", "code": "not_hosted"})
    u = getattr(request.state, "user", None)
    if not u:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return u


def _admin(request: Request) -> dict:
    u = _hosted(request)
    if u.get("role") != "admin":
        raise HTTPException(403, {"detail": "Nur für die Moderation.", "code": "admin_required"})
    return u


def _req(body: dict) -> dict:
    subject, topic = str(body.get("subject") or "").strip(), str(body.get("topic") or "").strip()
    if not subject or not topic:
        raise HTTPException(400, {"detail": "Fach und Thema angeben.", "code": "topic_required"})
    d = body.get("difficulty")
    if d is not None and (not isinstance(d, int) or not 1 <= d <= 5):
        raise HTTPException(400, {"detail": "Schwierigkeit 1 bis 5.", "code": "difficulty_invalid"})
    count = body.get("count", 10)
    if not isinstance(count, int) or not MIN_TEST <= count <= MAX_TEST:
        raise HTTPException(400, {"detail": f"Anzahl {MIN_TEST} bis {MAX_TEST}.", "code": "count_invalid"})
    return {"subject": subject[:120], "topic": topic[:160], "subtopic": (body.get("subtopic") or "")[:160] or None,
            "learning_goal": (body.get("learning_goal") or "")[:300] or None, "difficulty": d, "harder": bool(body.get("harder")),
            "count": count, "module": (body.get("module") or "")[:120] or None, "university": config.university(),
            "doc_sha256": (body.get("doc_sha256") or "").lower() if re.fullmatch(r"[0-9a-fA-F]{64}", body.get("doc_sha256") or "") else None,
            "doc_ref": (body.get("doc_ref") or "")[:200] or None, "doc_version": (body.get("doc_version") or "")[:60] or None}


def _store_test(req: dict, questions: list[dict], title: str) -> int:
    qs = [{"nr": i, "type": q["type"], "question": q["question"], "options": q.get("options"), "answer": q["answer"],
           "explanation": q.get("explanation"), "points": q.get("points") or 10, "topic": q.get("topic"),
           "difficulty": q.get("difficulty"), "library_id": q.get("id")} for i, q in enumerate(questions, start=1)]
    with db.cursor() as conn:
        cur = conn.execute("INSERT INTO tests(subject, title, duration_min, questions, created_at, auto) VALUES (?,?,?,?,?,0)",
                           (req["subject"], title, max(10, 2 * len(qs)), json.dumps(qs, ensure_ascii=False), db.now_iso()))
        return cur.lastrowid


def _generate(user_id: str, req: dict, n: int) -> int:
    """n fehlende Fragen von der Studora-KI; landen gepruft (auto_checked) im Pool. Liefert die Zahl neuer Fragen."""
    level = req.get("difficulty") or 3
    prompt = (f"Fach: {req['subject']}\nThema: {req['topic']}\n" + (f"Unterthema: {req['subtopic']}\n" if req.get("subtopic") else "")
              + (f"Lernziel: {req['learning_goal']}\n" if req.get("learning_goal") else "")
              + f"Erstelle {n} Multiple-Choice-Fragen mit je 4 Antwortmöglichkeiten, genau eine richtig. "
              + f"Schwierigkeit {'mindestens ' if req.get('harder') else 'etwa '}{level} von 5. "
              + "Die Lösung (answer) ist exakt der Text der richtigen Antwortmöglichkeit; dazu eine kurze Erklärung.")
    c = ai_backend.complete(user_id, "test_generation", GEN_SYSTEM, prompt, GEN_SCHEMA)
    try:
        data = json.loads(c.text)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", c.text, re.S)
        data = json.loads(m.group(0)) if m else {}
    qs = [{**q, "type": "mc"} for q in (data.get("questions") or []) if isinstance(q, dict)]
    meta = {k: req.get(k) for k in ("subject", "topic", "subtopic", "learning_goal", "university", "module", "doc_ref",
                                     "doc_version", "doc_sha256")}
    meta["difficulty"] = level
    return len(test_library.add(qs, meta, "studora_ai", "auto_checked"))


@router.post("/api/library/tests")
def create_library_test(request: Request, body: dict = Body(...)):
    user = _hosted(request)
    req = _req(body)
    may_reuse = entitlements.has(user, "can_access_shared_tests")
    may_generate = entitlements.has(user, "can_generate_studora_ai_tests")
    if not may_reuse and not may_generate:
        raise entitlements.forbidden("can_access_shared_tests")
    rid = str(body.get("request_id") or uuid.uuid4().hex)[:80]
    owner = test_library.owner_hash(user["id"])
    title = f"{req['subject']}: {req['topic']}" + (" (schwieriger)" if req["harder"] else "")

    def from_pool(found: list[dict], n: int, generated: int, charged: str) -> dict:
        picked = found[:n]
        test_id = _store_test(req, picked, title)
        test_library.mark_used(owner, [q["id"] for q in picked])
        return {"test_id": test_id, "title": title, "question_count": len(picked), "reused": len(picked) - min(generated, len(picked)),
                "generated": generated, "charged": charged}

    found = test_library.find(req, owner)
    if len(found) >= req["count"] and may_reuse:
        entitlements.consume(request, "library_tests", rid + ":lib")
        return from_pool(found, req["count"], 0, "library_tests")
    if not may_generate:
        if len(found) >= MIN_TEST and may_reuse:
            entitlements.consume(request, "library_tests", rid + ":lib")
            return from_pool(found, len(found), 0, "library_tests")
        raise HTTPException(409, {"detail": "Zu diesem Thema gibt es noch nicht genug geprüfte Fragen.", "code": "not_enough_questions"})

    lock = test_library.topic_lock_key(req)
    for _ in range(2):
        if ai_backend.acquire(lock, user["id"]):
            break
        # Gleiche Generierung laeuft schon (anderes Konto oder zweiter Tab): abwarten und deren Fragen nutzen
        ai_backend.wait_for(lock, timeout_s=float(body.get("wait_s") or 30))
        found = test_library.find(req, owner)
        if len(found) >= req["count"] and may_reuse:
            entitlements.consume(request, "library_tests", rid + ":lib")
            return from_pool(found, req["count"], 0, "library_tests")
    else:
        raise HTTPException(409, {"detail": "Zu diesem Thema läuft gerade eine Erstellung. Bitte gleich noch einmal.",
                                  "code": "generation_in_progress"})
    try:
        found = test_library.find(req, owner)            # waehrend des Wartens auf die Sperre koennte etwas dazugekommen sein
        if len(found) >= req["count"] and may_reuse:
            entitlements.consume(request, "library_tests", rid + ":lib")
            return from_pool(found, req["count"], 0, "library_tests")
        entitlements.consume(request, "ai_tests_new", rid + ":ai")
        missing = req["count"] - len(found)
        try:
            generated = _generate(user["id"], req, missing + 2)       # zwei Reserve-Fragen gegen verworfene
        except ai_backend.AIUnavailable as e:
            entitlements.refund(rid + ":ai")
            raise HTTPException(e.status, {"detail": e.message, "code": e.code})
        except Exception:
            entitlements.refund(rid + ":ai")
            raise
        found = test_library.find(req, owner)
        if len(found) < MIN_TEST:
            entitlements.refund(rid + ":ai")
            raise HTTPException(502, {"detail": "Die KI hat keine brauchbaren Fragen geliefert. Es wurde nichts berechnet.",
                                      "code": "generation_failed"})
        return from_pool(found, req["count"], generated, "ai_tests_new")
    finally:
        ai_backend.release(lock)


def _user_test(test_id: int) -> dict:
    with db.cursor() as conn:
        t = db.row(conn, "SELECT * FROM tests WHERE id=?", (test_id,))
    if not t:
        raise HTTPException(404, {"detail": "Test nicht gefunden.", "code": "not_found"})
    t["questions"] = json.loads(t["questions"] or "[]")
    return t


@router.post("/api/library/tests/{test_id}/share")
def share_test(request: Request, test_id: int, body: dict = Body(...)):
    """Nur auf ausdruecklichen Wunsch: eigene Fragen (nicht die schon aus dem Pool) bereinigt zur Moderation einreichen."""
    user = _hosted(request)
    entitlements.require(request, "can_share_solutions")
    if body.get("confirm") is not True:
        raise HTTPException(400, {"detail": "Freigabe bitte ausdrücklich bestätigen.", "code": "confirm_required"})
    t = _user_test(test_id)
    topic = str(body.get("topic") or "").strip()
    if not topic:
        raise HTTPException(400, {"detail": "Thema angeben.", "code": "topic_required"})
    own = [q for q in t["questions"] if not q.get("library_id")]
    meta = {"subject": t["subject"], "topic": topic, "subtopic": body.get("subtopic"), "learning_goal": body.get("learning_goal"),
            "university": config.university(), "difficulty": body.get("difficulty") or 3}
    out = test_library.submit_for_sharing(test_library.owner_hash(user["id"]), own, meta)
    out["skipped_from_pool"] = len(t["questions"]) - len(own)
    return out


@router.get("/api/library/moderation")
def moderation(request: Request):
    _admin(request)
    return {"questions": test_library.moderation_queue()}


@router.post("/api/library/questions/{question_id}/moderate")
def moderate(request: Request, question_id: str, body: dict = Body(...)):
    u = _admin(request)
    try:
        return test_library.moderate(question_id, str(body.get("action") or ""), u["id"])
    except KeyError:
        raise HTTPException(404, {"detail": "Frage nicht gefunden.", "code": "not_found"})
    except ValueError as e:
        raise HTTPException(400, {"detail": str(e), "code": "action_invalid"})


def grade_and_store(test_id: int, answers: dict) -> dict:
    """Bewertung ohne KI; speichert Antworten und Ergebnis wie planner.grade (gleiche Felder)."""
    t = _user_test(test_id)
    res = test_library.grade(t["questions"], answers)
    with db.cursor() as conn:
        conn.execute("UPDATE tests SET submitted_at=?, answers=?, score=?, max_score=?, feedback=? WHERE id=?",
                     (db.now_iso(), json.dumps(answers, ensure_ascii=False), res["total"], res["max"],
                      json.dumps(res, ensure_ascii=False), test_id))
        conn.execute("UPDATE plan_items SET done=1 WHERE test_id=?", (test_id,))
    return res


@router.post("/api/library/tests/{test_id}/submit")
def submit(request: Request, test_id: int, body: dict = Body(...)):
    if config.is_hosted():
        _hosted(request)
    answers = {str(k): v for k, v in (body.get("answers") or {}).items()}
    return grade_and_store(test_id, answers)


# ---------------------------------------------------------------- Lernfunktionen ab Pro Connect (ohne KI)

def _submitted() -> list[dict]:
    with db.cursor() as conn:
        rows = db.rows(conn, "SELECT id, subject, title, questions, answers, feedback, score, max_score, submitted_at FROM tests "
                             "WHERE submitted_at IS NOT NULL ORDER BY submitted_at")
    for r in rows:
        for k in ("questions", "answers", "feedback"):
            try:
                r[k] = json.loads(r[k]) if r[k] else ({} if k != "questions" else [])
            except json.JSONDecodeError:
                r[k] = {} if k != "questions" else []
    return rows


def _wrong_items(t: dict) -> list[dict]:
    items = (t.get("feedback") or {}).get("items") or []
    by_nr = {str(q.get("nr") or i): q for i, q in enumerate(t["questions"], start=1)}
    out = []
    for it in items:
        wrong = it.get("correct") is False or (it.get("correct") is None and float(it.get("points") or 0) < float(it.get("max") or 0))
        q = by_nr.get(str(it.get("nr")))
        if wrong and q:
            out.append({"test_id": t["id"], "subject": t["subject"], "nr": str(it.get("nr")), "question": q.get("question"),
                        "options": q.get("options"), "type": q.get("type") or "mc", "given": it.get("given"),
                        "answer": q.get("answer"), "explanation": q.get("explanation"), "topic": q.get("topic"),
                        "points": q.get("points") or 10, "library_id": q.get("library_id"), "submitted_at": t["submitted_at"]})
    return out


def stats_from(tests: list[dict]) -> dict:
    subjects: dict[str, dict] = {}
    topics: dict[tuple[str, str], list[int]] = {}
    for t in tests:
        if not t.get("max_score"):
            continue
        pct = round(100 * float(t["score"] or 0) / float(t["max_score"]))
        s = subjects.setdefault(t["subject"], {"subject": t["subject"], "tests": 0, "scores": []})
        s["tests"] += 1
        s["scores"].append(pct)
        by_nr = {str(q.get("nr") or i): q for i, q in enumerate(t["questions"], start=1)}
        for it in (t.get("feedback") or {}).get("items") or []:
            q = by_nr.get(str(it.get("nr"))) or {}
            topic = q.get("topic") or it.get("topic")
            if topic and it.get("correct") is not None:
                topics.setdefault((t["subject"], topic), []).append(1 if it["correct"] else 0)
    out = []
    for s in subjects.values():
        sc = s.pop("scores")
        recent, before = sc[-3:], sc[-6:-3]
        s["average"] = round(sum(sc) / len(sc))
        s["last"] = sc[-1]
        s["trend"] = (round(sum(recent) / len(recent) - sum(before) / len(before)) if before else None)
        out.append(s)
    weak = sorted(({"subject": k[0], "topic": k[1], "correct_rate": round(100 * sum(v) / len(v)), "answers": len(v)}
                   for k, v in topics.items() if len(v) >= 2), key=lambda x: (x["correct_rate"], -x["answers"]))
    return {"subjects": sorted(out, key=lambda x: x["average"]), "weak_topics": weak[:10],
            "tests_total": sum(s["tests"] for s in out)}


@router.get("/api/learning/stats")
def learning_stats(request: Request):
    entitlements.require(request, "can_use_advanced_analytics")
    return stats_from(_submitted())


@router.get("/api/learning/review")
def learning_review(request: Request):
    entitlements.require(request, "can_review_wrong_answers")
    items = [w for t in reversed(_submitted()) for w in _wrong_items(t)]
    return {"items": items[:100], "total": len(items)}


@router.post("/api/learning/review/test")
def learning_review_test(request: Request, body: dict = Body(default={})):
    entitlements.require(request, "can_review_wrong_answers")
    subject = (body.get("subject") or "").strip()
    items = [w for t in reversed(_submitted()) for w in _wrong_items(t) if not subject or w["subject"] == subject]
    seen, picked = set(), []
    for w in items:
        k = (w["question"] or "").strip()
        if k and k not in seen:
            seen.add(k)
            picked.append({"id": w.get("library_id"), "type": w["type"], "question": w["question"], "options": w["options"],
                           "answer": w["answer"], "explanation": w["explanation"], "points": w["points"], "topic": w["topic"]})
        if len(picked) >= 20:
            break
    if not picked:
        raise HTTPException(409, {"detail": "Keine falschen Antworten zum Wiederholen.", "code": "nothing_to_review"})
    req = {"subject": subject or picked[0].get("topic") or "Wiederholung"}
    test_id = _store_test({"subject": subject or "Wiederholung"}, picked, f"Wiederholung: falsche Antworten{' – ' + subject if subject else ''}")
    return {"test_id": test_id, "question_count": len(picked), "subject": req["subject"]}


@router.get("/api/learning/recommendations")
def learning_recommendations(request: Request):
    entitlements.require(request, "can_get_recommendations")
    st = stats_from(_submitted())
    recs = []
    for s in st["subjects"][:3]:
        if s["average"] < 70:
            recs.append({"kind": "review_subject", "subject": s["subject"],
                         "text": f"{s['subject']}: Durchschnitt {s['average']} % – falsche Antworten wiederholen."})
        if s["trend"] is not None and s["trend"] < -5:
            recs.append({"kind": "trend_down", "subject": s["subject"],
                         "text": f"{s['subject']}: zuletzt {abs(s['trend'])} Prozentpunkte schwächer als davor."})
    for w in st["weak_topics"][:3]:
        recs.append({"kind": "weak_topic", "subject": w["subject"], "topic": w["topic"],
                     "text": f"{w['subject']} – {w['topic']}: nur {w['correct_rate']} % richtig. Ein Bibliothekstest dazu hilft."})
    with db.cursor() as conn:
        n = db.row(conn, "SELECT COUNT(*) AS n FROM study_tasks WHERE status='nachholen'")
    if n and n["n"]:
        recs.append({"kind": "catch_up", "text": f"{n['n']} Aufgaben sind zum Nachholen offen – „Woche retten“ verteilt sie neu."})
    if not recs:
        recs.append({"kind": "keep_going", "text": "Alles im grünen Bereich. Mach mit dem Lernplan weiter."})
    return {"recommendations": recs, "based_on_tests": st["tests_total"]}
