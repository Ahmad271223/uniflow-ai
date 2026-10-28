"""HTTP-Schnittstelle des Community-Dienstes (Vertrag G4). Nur im gehosteten Modus mit Sitzung; sonst 501.
Fehler wie beim Konto: {"detail": "...", "code": "..."}."""
from __future__ import annotations

from fastapi import APIRouter, Body, HTTPException, Request

from . import community, config

router = APIRouter(prefix="/api/community", tags=["community"])


def _err(e: community.CommunityError) -> HTTPException:
    return HTTPException(e.status, {"detail": e.message, "code": e.code})


def _user(request: Request) -> dict:
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Die Community gibt es nur im gehosteten Dienst (LERNAPP_MODE=hosted).", "code": "not_hosted"})
    u = getattr(request.state, "user", None)
    if not u:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return u


def _run(fn, *args):
    try:
        return fn(*args)
    except community.CommunityError as e:
        raise _err(e)


@router.get("/info")
def info(request: Request):
    """Regeln des Dienstes und eigener Tarifstand; im Einzelplatzmodus 501."""
    return community.info(_user(request))


@router.post("/solutions", status_code=201)
def publish(request: Request, body: dict = Body(...)):
    """Paket veroeffentlichen: {package: <uniflow-solution>, title?}; nur fuer PDFs aus dem eigenen Abgleich, Tarif Plus,
    bestaetigte E-Mail-Adresse (Schutz gegen Wegwerf-Konten, 28.10.2026)."""
    u = _user(request)
    if not u.get("email_verified"):
        raise HTTPException(403, {"detail": "Bitte bestätige zuerst deine E-Mail-Adresse (Link in der Willkommensmail, "
                                            "neu anfordern unter Konto).", "code": "email_unverified"})
    return _run(community.publish, u, config.university(), body.get("package"), body.get("title"))


@router.get("/solutions")
def find(request: Request, fingerprint: str = "", limit: int = 200, offset: int = 0):
    """Loesungen zu einer PDF (Fingerabdruck = SHA-256 der Originaldatei), ohne gesperrte Autoren, meistgelikte
    zuerst; seitenweise mit `limit` (hoechstens 200) und `offset`, `total` = alle."""
    u = _user(request)
    rows = _run(community.find, u, config.university(), fingerprint.lower())
    limit, offset = max(1, min(int(limit), 200)), max(0, int(offset))
    return {"solutions": rows[offset:offset + limit], "total": len(rows)}


@router.get("/mine")
def mine(request: Request):
    return {"solutions": community.mine(_user(request))}


@router.get("/blocks")
def blocks(request: Request):
    return {"blocked": community.blocks(_user(request))}


@router.get("/moderation")
def moderation(request: Request):
    return {"solutions": _run(community.moderation_queue, _user(request))}


@router.post("/claims")
def claims(request: Request, body: dict = Body(...)):
    """Geraet meldet die Fingerabdruecke (SHA-256) seiner PDFs aus dem Hochschul-Abgleich: {fingerprints: [...],
    replace?: bool}. Danach findet, laedt, liked und kommentiert das Konto Loesungen zu diesen PDFs."""
    u = _user(request)
    return _run(community.claim_files, u, config.university(), body.get("fingerprints") or [], bool(body.get("replace")))


@router.post("/solutions/{solution_id}/like")
def like(request: Request, solution_id: str):
    """Gefaellt mir (nicht fuer die eigene Loesung; bestaetigte E-Mail)."""
    return _run(community.like, _user(request), solution_id, True)


@router.delete("/solutions/{solution_id}/like")
def unlike(request: Request, solution_id: str):
    return _run(community.like, _user(request), solution_id, False)


@router.get("/solutions/{solution_id}/comments")
def comments(request: Request, solution_id: str):
    """Kommentare zur Loesung, Antworten direkt unter ihrem Kommentar; mit Seite und Stelle (anchor x/y 0..1)."""
    return {"comments": _run(community.comments, _user(request), solution_id)}


@router.post("/solutions/{solution_id}/comments", status_code=201)
def add_comment(request: Request, solution_id: str, body: dict = Body(...)):
    """{text, parent_id?, page_key?, anchor?: {x, y}}; ab Studora Plus, bestaetigte E-Mail."""
    return _run(community.add_comment, _user(request), solution_id, body.get("text"), body.get("parent_id"),
                body.get("page_key"), body.get("anchor"))


@router.patch("/comments/{comment_id}")
def edit_comment(request: Request, comment_id: str, body: dict = Body(...)):
    return _run(community.edit_comment, _user(request), comment_id, body.get("text"))


@router.delete("/comments/{comment_id}")
def delete_comment(request: Request, comment_id: str):
    return _run(community.delete_comment, _user(request), comment_id)


@router.post("/comments/{comment_id}/report")
def report_comment(request: Request, comment_id: str, body: dict = Body(...)):
    return _run(community.report_comment, _user(request), comment_id, body.get("reason"))


@router.get("/admin/leaderboard")
def leaderboard(request: Request, limit: int = 50):
    """Nur Inhaber (Rolle admin): Autoren nach erhaltenen Likes, mit Konto-E-Mail."""
    return {"authors": _run(community.leaderboard, _user(request), limit)}


@router.get("/solutions/{solution_id}")
def download(request: Request, solution_id: str):
    """Das Paket (verschluesselt) samt Kopfdaten; zaehlt als Download, ausser bei der eigenen Loesung."""
    u = _user(request)
    pkg, summary = _run(community.get_package, u, solution_id)
    return {"package": pkg, "solution": summary}


@router.delete("/solutions/{solution_id}")
def withdraw(request: Request, solution_id: str):
    return _run(community.withdraw, _user(request), solution_id)


@router.post("/solutions/{solution_id}/report")
def report(request: Request, solution_id: str, body: dict = Body(...)):
    return _run(community.report, _user(request), solution_id, body.get("reason") or "", body.get("note"))


@router.post("/solutions/{solution_id}/block")
def block(request: Request, solution_id: str):
    return _run(community.block, _user(request), solution_id)


@router.delete("/blocks/{pseudonym}")
def unblock(request: Request, pseudonym: str):
    return _run(community.unblock, _user(request), pseudonym)


@router.post("/solutions/{solution_id}/moderate")
def moderate(request: Request, solution_id: str, body: dict = Body(...)):
    """Nur Admin: hide | restore | remove | ban_author | unban_author."""
    return _run(community.moderate, _user(request), solution_id, body.get("action") or "", body.get("reason"))


# ---------------------------------------------------------------- Teil 2: Fragen je Kurs, Lesezeichen, Benachrichtigungen

from . import community_qa  # noqa: E402


@router.get("/courses/{course_key}/questions")
def qa_list(request: Request, course_key: str, limit: int = 30, before: str | None = None, fingerprint: str | None = None):
    """Fragen eines Kurses (Schluessel wie CommunityKeys.courseKey), neueste Aktivitaet zuerst; `next` fuer die naechste Seite."""
    return _run(community_qa.list_questions, _user(request), config.university(), course_key, limit, before, fingerprint)


@router.post("/courses/{course_key}/questions", status_code=201)
def qa_ask(request: Request, course_key: str, body: dict = Body(...)):
    """{title, body?, fingerprint?, page?}; ab Studora Plus, bestaetigte E-Mail, 10 je Stunde."""
    return _run(community_qa.ask, _user(request), config.university(), course_key, body.get("title"), body.get("body"),
                body.get("fingerprint"), body.get("page"))


@router.get("/questions/{qid}")
def qa_get(request: Request, qid: str):
    return _run(community_qa.get_question, _user(request), qid)


@router.patch("/questions/{qid}")
def qa_edit(request: Request, qid: str, body: dict = Body(...)):
    return _run(community_qa.edit, _user(request), "question", qid, body.get("body"), body.get("title"))


@router.delete("/questions/{qid}")
def qa_delete(request: Request, qid: str):
    return _run(community_qa.delete, _user(request), "question", qid)


@router.post("/questions/{qid}/answers", status_code=201)
def qa_answer(request: Request, qid: str, body: dict = Body(...)):
    return _run(community_qa.answer, _user(request), qid, body.get("body"))


@router.post("/questions/{qid}/accept")
def qa_accept(request: Request, qid: str, body: dict = Body(...)):
    return _run(community_qa.accept, _user(request), qid, body.get("answer_id"))


@router.patch("/answers/{aid}")
def qa_answer_edit(request: Request, aid: str, body: dict = Body(...)):
    return _run(community_qa.edit, _user(request), "answer", aid, body.get("body"))


@router.delete("/answers/{aid}")
def qa_answer_delete(request: Request, aid: str):
    return _run(community_qa.delete, _user(request), "answer", aid)


@router.post("/answers/{aid}/vote")
def qa_vote(request: Request, aid: str):
    return _run(community_qa.vote, _user(request), aid, True)


@router.delete("/answers/{aid}/vote")
def qa_unvote(request: Request, aid: str):
    return _run(community_qa.vote, _user(request), aid, False)


@router.post("/{kind}/{target_id}/report-post")
def qa_report(request: Request, kind: str, target_id: str, body: dict = Body(...)):
    """Frage oder Antwort melden: kind = questions | answers."""
    k = {"questions": "question", "answers": "answer"}.get(kind)
    if not k:
        raise HTTPException(404, {"detail": "Unbekannt", "code": "not_found"})
    return _run(community_qa.report, _user(request), k, target_id, body.get("reason"))


@router.get("/bookmarks")
def bm_list(request: Request):
    return community_qa.bookmarks(_user(request))


@router.post("/bookmarks/{kind}/{target_id}")
def bm_add(request: Request, kind: str, target_id: str):
    return _run(community_qa.bookmark, _user(request), kind, target_id, True)


@router.delete("/bookmarks/{kind}/{target_id}")
def bm_del(request: Request, kind: str, target_id: str):
    return _run(community_qa.bookmark, _user(request), kind, target_id, False)


@router.get("/notifications")
def notif_list(request: Request, unread: bool = False, limit: int = 50):
    return community_qa.notifications(_user(request), unread, limit)


@router.post("/notifications/read")
def notif_read(request: Request, body: dict = Body(default={})):
    """{ids?: [...]} oder alles gelesen."""
    ids = body.get("ids") if isinstance(body, dict) else None
    return community_qa.mark_read(_user(request), ids if isinstance(ids, list) else None)


# ---------------------------------------------------------------- Gemeinsamer Wochentest je Kursgruppe (app/weekly_tests.py)

from . import weekly_tests  # noqa: E402


@router.get("/weekly/{course_key}")
def wk_list(request: Request, course_key: str, term: str = ""):
    return _run(weekly_tests.list_for_course, _user(request), config.university(), course_key, term)


@router.get("/weekly/{course_key}/{week}")
def wk_get(request: Request, course_key: str, week: str, term: str = ""):
    """Test der Kursgruppe fuer die Kalenderwoche (ohne Loesungen, bis man abgegeben hat); 404 not_generated."""
    return _run(weekly_tests.get_for_week, _user(request), config.university(), course_key, term, week)


@router.post("/weekly/{course_key}/{week}", status_code=202)
def wk_request(request: Request, course_key: str, week: str, body: dict = Body(...)):
    """{term, materials: [{kind, title, sha256, pages: [{page, text}]}]}: den Test holen oder einmal erstellen lassen."""
    return _run(weekly_tests.request, _user(request), config.university(), course_key, body.get("term"), week, body.get("materials"))


@router.post("/weekly/tests/{test_id}/attempt")
def wk_start(request: Request, test_id: str, body: dict = Body(default={})):
    return _run(weekly_tests.start, _user(request), test_id, bool((body or {}).get("practice")))


@router.put("/weekly/attempts/{attempt_id}")
def wk_save(request: Request, attempt_id: str, body: dict = Body(...)):
    return _run(weekly_tests.save, _user(request), attempt_id, body.get("answers"))


@router.post("/weekly/attempts/{attempt_id}/submit")
def wk_submit(request: Request, attempt_id: str, body: dict = Body(default={})):
    b = body or {}
    return _run(weekly_tests.submit, _user(request), attempt_id, b.get("answers"), bool(b.get("leaderboard")), b.get("display_name"))


@router.post("/weekly/attempts/{attempt_id}/leaderboard")
def wk_lb_set(request: Request, attempt_id: str, body: dict = Body(...)):
    return _run(weekly_tests.set_leaderboard, _user(request), attempt_id, bool(body.get("on")), body.get("display_name"))


@router.get("/weekly/tests/{test_id}/leaderboard")
def wk_lb(request: Request, test_id: str):
    return _run(weekly_tests.leaderboard, _user(request), test_id)
