"""HTTP-Schnittstelle des Community-Dienstes (Vertrag G4). Nur im gehosteten Modus mit Sitzung; sonst 501.
Fehler wie beim Konto: {"detail": "...", "code": "..."}."""
from __future__ import annotations

import json
import os

from fastapi import APIRouter, Body, HTTPException, Request
from fastapi.responses import StreamingResponse

from . import community, config, entitlements

router = APIRouter(prefix="/api/community", tags=["community"])
PACKAGE_CHUNK = 1 << 20             # Loesungspaket in Stuecken zu 1 MiB (Liste 95 Nr. 33)


def _err(e: community.CommunityError) -> HTTPException:
    return HTTPException(e.status, {"detail": e.message, "code": e.code, **e.extra})


def _account(request: Request) -> dict:
    """Angemeldet im Dienst, ohne Tarifpruefung: nur fuer eigene Daten (eigene Beitraege auflisten, zurueckziehen,
    loeschen, austreten, Sperrliste), Geraete-Meldungen und die Moderation."""
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Die Community gibt es nur im gehosteten Dienst (LERNAPP_MODE=hosted).", "code": "not_hosted"})
    u = getattr(request.state, "user", None)
    if not u:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return u


def _user(request: Request) -> dict:
    """Angemeldet und Recht `can_read_community` (Entscheidung 05.11.2026: Community ab StudiNow Plus, auch das Lesen;
    403 plan_required "Die Community gibt es ab StudiNow Plus."). Die Moderation (Rolle admin) braucht keinen Tarif."""
    u = _account(request)
    if u.get("role") != "admin":
        entitlements.require(request, "can_read_community")
    return u


def _run(fn, *args):
    try:
        return fn(*args)
    except community.CommunityError as e:
        raise _err(e)


@router.get("/info")
def info(request: Request):
    """Regeln des Dienstes und eigener Tarifstand; im Einzelplatzmodus 501."""
    return community.info(_account(request))


@router.post("/solutions", status_code=201)
def publish(request: Request, body: dict = Body(...)):
    """Paket veroeffentlichen: {package: <uniflow-solution>, title?}; nur fuer PDFs aus dem eigenen Abgleich, Tarif Plus,
    bestaetigte E-Mail-Adresse (Schutz gegen Wegwerf-Konten, 28.10.2026)."""
    u = _user(request)
    if not u.get("email_verified"):
        raise HTTPException(403, {"detail": "Bitte bestätige zuerst deine E-Mail-Adresse (Link in der Willkommensmail, "
                                            "neu anfordern unter Konto).", "code": "email_unverified"})
    return _run(community.publish, u, config.university(), body.get("package"), body.get("title"), body.get("community_key"))


@router.put("/solutions/{solution_id}")
def update(request: Request, solution_id: str, body: dict = Body(...)):
    """Paket der eigenen Loesung ersetzen: {package, title?, community_key?}. Nur der Autor; Kopf-ID, Fingerabdruck und
    Community bleiben gleich. Der Client hat die Seiten vorher zusammengefuehrt (Antwort auf 409 `already_published`)."""
    u = _user(request)
    if not u.get("email_verified"):
        raise HTTPException(403, {"detail": "Bitte bestätige zuerst deine E-Mail-Adresse (Link in der Willkommensmail, "
                                            "neu anfordern unter Konto).", "code": "email_unverified"})
    return _run(community.update, u, config.university(), solution_id, body.get("package"), body.get("title"), body.get("community_key"))


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
    return {"solutions": community.mine(_account(request))}


@router.get("/blocks")
def blocks(request: Request):
    return {"blocked": community.blocks(_account(request))}


@router.get("/moderation")
def moderation(request: Request):
    u = _account(request)
    return {"solutions": _run(community.moderation_queue, u), **_run(community_qa.moderation_posts, u)}


@router.post("/claims")
def claims(request: Request, body: dict = Body(...)):
    """Geraet meldet die Fingerabdruecke (SHA-256) seiner PDFs aus dem Hochschul-Abgleich: {fingerprints: [...],
    replace?: bool}. Danach findet, laedt, liked und kommentiert das Konto Loesungen zu diesen PDFs."""
    u = _account(request)
    return _run(community.claim_files, u, config.university(), body.get("fingerprints") or [], bool(body.get("replace")), body.get("course_keys"))


@router.get("/communities")
def communities(request: Request):
    """Gemeldete Kurse und eigene Lerngruppen, je mit `joined`, Mitgliedern und Loesungen."""
    return {"communities": _run(community.communities, _user(request), config.university())}


@router.post("/communities/{community_key}/join")
def join(request: Request, community_key: str, body: dict = Body(default={})):
    """{kind: course | group}; Kurs nur aus dem eigenen Abgleich."""
    return _run(community.join, _user(request), config.university(), community_key, body.get("kind") or "course")


@router.delete("/communities/{community_key}/join")
def leave(request: Request, community_key: str):
    return _run(community.leave, _account(request), community_key)


@router.get("/communities/{community_key}/solutions")
def community_solutions(request: Request, community_key: str):
    """Loesungen der Community, nur fuer Mitglieder, auch ohne die PDF."""
    return {"solutions": _run(community.community_solutions, _user(request), community_key)}


@router.post("/groups", status_code=201)
def create_group(request: Request, body: dict = Body(...)):
    """{group_key, name}: Lerngruppe anlegen und beitreten (ab Plus); der Code bleibt beim Geraet."""
    return _run(community.create_group, _user(request), config.university(), body.get("group_key"), body.get("name"))


@router.get("/groups/{group_key}")
def group_preview(request: Request, group_key: str):
    """Name einer Lerngruppe vor dem Beitritt (wer den Code kennt, kennt den Schluessel)."""
    return _run(community.group_preview, _user(request), config.university(), group_key)


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
    """{text, parent_id?, page_key?, anchor?: {x, y}}; ab StudiNow Plus, bestaetigte E-Mail."""
    return _run(community.add_comment, _user(request), solution_id, body.get("text"), body.get("parent_id"),
                body.get("page_key"), body.get("anchor"))


@router.patch("/comments/{comment_id}")
def edit_comment(request: Request, comment_id: str, body: dict = Body(...)):
    return _run(community.edit_comment, _user(request), comment_id, body.get("text"))


@router.delete("/comments/{comment_id}")
def delete_comment(request: Request, comment_id: str):
    return _run(community.delete_comment, _account(request), comment_id)


@router.post("/comments/{comment_id}/report")
def report_comment(request: Request, comment_id: str, body: dict = Body(...)):
    return _run(community.report_comment, _user(request), comment_id, body.get("reason"))


@router.get("/admin/leaderboard")
def leaderboard(request: Request, limit: int = 50):
    """Nur Inhaber (Rolle admin): Autoren nach erhaltenen Likes, mit Konto-E-Mail."""
    return {"authors": _run(community.leaderboard, _account(request), limit)}


@router.get("/solutions/{solution_id}")
def download(request: Request, solution_id: str):
    """Das Paket (verschluesselt) samt Kopfdaten; zaehlt als Download, ausser bei der eigenen Loesung."""
    u = _user(request)
    f, summary = _run(community.open_package_file, u, solution_id)
    # Das Paket liegt schon als JSON-Text vor: nicht einlesen und neu schreiben, sondern in Stuecken in die Antwort
    # einsetzen - vorher bis ~65 MB je Abruf dreifach im Speicher und in einem Stueck (Liste 95 Nr. 33)
    head = b'{"package":'
    tail = (',"solution":' + json.dumps(summary, ensure_ascii=False) + "}").encode("utf-8")
    size = os.fstat(f.fileno()).st_size

    def chunks():
        try:
            yield head
            while True:
                chunk = f.read(PACKAGE_CHUNK)
                if not chunk:
                    break
                yield chunk
            yield tail
        finally:
            f.close()
    return StreamingResponse(chunks(), media_type="application/json",
                             headers={"Content-Length": str(len(head) + size + len(tail))})


@router.delete("/solutions/{solution_id}")
def withdraw(request: Request, solution_id: str):
    return _run(community.withdraw, _account(request), solution_id)


@router.post("/solutions/{solution_id}/report")
def report(request: Request, solution_id: str, body: dict = Body(...)):
    return _run(community.report, _user(request), solution_id, body.get("reason") or "", body.get("note"))


@router.post("/solutions/{solution_id}/block")
def block(request: Request, solution_id: str):
    return _run(community.block, _user(request), solution_id)


@router.delete("/blocks/{pseudonym}")
def unblock(request: Request, pseudonym: str):
    return _run(community.unblock, _account(request), pseudonym)


@router.post("/solutions/{solution_id}/moderate")
def moderate(request: Request, solution_id: str, body: dict = Body(...)):
    """Nur Admin: hide | restore | remove | ban_author | unban_author."""
    return _run(community.moderate, _account(request), solution_id, body.get("action") or "", body.get("reason"))


# ---------------------------------------------------------------- Teil 2: Fragen je Kurs, Lesezeichen, Benachrichtigungen

from . import community_qa  # noqa: E402


@router.get("/courses/{course_key}/questions")
def qa_list(request: Request, course_key: str, limit: int = 30, before: str | None = None, fingerprint: str | None = None,
            unanswered: bool = False):
    """Fragen eines Kurses (Schluessel wie CommunityKeys.courseKey), neueste Aktivitaet zuerst; `next` fuer die naechste Seite.
    `unanswered=true`: nur Fragen ohne Antwort (Filter der Community-Seite)."""
    return _run(community_qa.list_questions, _user(request), config.university(), course_key, limit, before, fingerprint, unanswered)


@router.post("/courses/{course_key}/questions", status_code=201)
def qa_ask(request: Request, course_key: str, body: dict = Body(...)):
    """{title, body?, fingerprint?, page?}; ab StudiNow Plus, bestaetigte E-Mail, 10 je Stunde."""
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
    return _run(community_qa.delete, _account(request), "question", qid)


@router.post("/questions/{qid}/answers", status_code=201)
def qa_answer(request: Request, qid: str, body: dict = Body(...)):
    return _run(community_qa.answer, _user(request), qid, body.get("body"))


@router.post("/questions/{qid}/like")
def qa_like(request: Request, qid: str):
    """Gefaellt mir fuer eine Frage (nicht die eigene; bestaetigte E-Mail)."""
    return _run(community_qa.like_question, _user(request), qid, True)


@router.delete("/questions/{qid}/like")
def qa_unlike(request: Request, qid: str):
    return _run(community_qa.like_question, _user(request), qid, False)


@router.post("/questions/{qid}/accept")
def qa_accept(request: Request, qid: str, body: dict = Body(...)):
    return _run(community_qa.accept, _user(request), qid, body.get("answer_id"))


@router.patch("/answers/{aid}")
def qa_answer_edit(request: Request, aid: str, body: dict = Body(...)):
    return _run(community_qa.edit, _user(request), "answer", aid, body.get("body"))


@router.delete("/answers/{aid}")
def qa_answer_delete(request: Request, aid: str):
    return _run(community_qa.delete, _account(request), "answer", aid)


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


@router.post("/{kind}/{target_id}/moderate")
def qa_moderate(request: Request, kind: str, target_id: str, body: dict = Body(...)):
    """Nur Admin: verborgenen Kommentar, verborgene Frage oder Antwort wiederherstellen ({action: restore});
    kind = comments | questions | answers | corrections | card-stacks (geteilte Karteikarten-Stapel)."""
    k = {"comments": "comment", "questions": "question", "answers": "answer", "corrections": "correction",
         "card-stacks": "card_stack"}.get(kind)
    if not k:
        raise HTTPException(404, {"detail": "Unbekannt", "code": "not_found"})
    return _run(community_qa.moderate_post, _account(request), k, target_id, body.get("action") or "")


@router.get("/bookmarks")
def bm_list(request: Request):
    return community_qa.bookmarks(_user(request))


@router.post("/bookmarks/{kind}/{target_id}")
def bm_add(request: Request, kind: str, target_id: str):
    return _run(community_qa.bookmark, _user(request), kind, target_id, True)


@router.delete("/bookmarks/{kind}/{target_id}")
def bm_del(request: Request, kind: str, target_id: str):
    return _run(community_qa.bookmark, _account(request), kind, target_id, False)


@router.get("/notifications")
def notif_list(request: Request, unread: bool = False, limit: int = 50):
    return community_qa.notifications(_user(request), unread, limit)


@router.post("/notifications/read")
def notif_read(request: Request, body: dict = Body(default={})):
    """{ids?: [...]} oder alles gelesen."""
    ids = body.get("ids") if isinstance(body, dict) else None
    return _run(community_qa.mark_read, _account(request), ids if isinstance(ids, list) else None)


# ---------------------------------------------------------------- Korrekturvorschlaege (03.11.2026, app/community_corrections.py)

from . import community_corrections  # noqa: E402


@router.post("/solutions/{solution_id}/corrections", status_code=201)
def correction_send(request: Request, solution_id: str, body: dict = Body(...)):
    """{id, payload}: Korrektur an den Ersteller der Loesung. `id` = UUID, `payload` = Chiffrat (Base64) wie
    `CommunityCorrections.seal`. Ab StudiNow Plus (Tarif wie Teilen), bestaetigte E-Mail, `correction_user` je Tag."""
    u = _user(request)
    return _run(community_corrections.send, u, solution_id, body.get("id"), body.get("payload"))


@router.get("/solutions/{solution_id}/corrections")
def correction_list(request: Request, solution_id: str):
    """Korrekturen zu einer Loesung (alle Mitglieder), neueste zuerst, mit Chiffrat."""
    return {"corrections": _run(community_corrections.for_solution, _user(request), solution_id)}


@router.get("/corrections/inbox")
def correction_inbox(request: Request, limit: int = 50, count_only: bool = False):
    """Posteingang des Erstellers: Korrekturhinweise an eigene Loesungen (ohne Chiffrat), `open` = Zahl am Menuepunkt,
    `seen` = Gruppe "Gesehen". `count_only=true` liefert nur die Zahlen."""
    return community_corrections.inbox(_user(request), limit, count_only)


@router.get("/corrections/{correction_id}")
def correction_get(request: Request, correction_id: str):
    return _run(community_corrections.get, _user(request), correction_id)


@router.post("/corrections/{correction_id}/status")
def correction_status(request: Request, correction_id: str, body: dict = Body(...)):
    """Nur der Ersteller der Loesung: {status: open | seen | ignored}; gilt fuer alle Geraete des Kontos."""
    return _run(community_corrections.set_status, _user(request), correction_id, body.get("status"))


@router.delete("/corrections/{correction_id}")
def correction_delete(request: Request, correction_id: str):
    return _run(community_corrections.delete, _account(request), correction_id)


@router.post("/corrections/{correction_id}/report")
def correction_report(request: Request, correction_id: str, body: dict = Body(...)):
    return _run(community_corrections.report, _user(request), correction_id, body.get("reason"))
