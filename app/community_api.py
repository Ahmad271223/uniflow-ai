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
    """Paket veroeffentlichen: {package: <uniflow-solution>, title?}; nur fuer PDFs aus dem eigenen Abgleich, Tarif Plus."""
    u = _user(request)
    return _run(community.publish, u, config.university(), body.get("package"), body.get("title"))


@router.get("/solutions")
def find(request: Request, fingerprint: str = ""):
    """Loesungen zu einer PDF (Fingerabdruck = SHA-256 der Originaldatei), ohne gesperrte Autoren."""
    u = _user(request)
    return {"solutions": _run(community.find, u, config.university(), fingerprint.lower())}


@router.get("/mine")
def mine(request: Request):
    return {"solutions": community.mine(_user(request))}


@router.get("/blocks")
def blocks(request: Request):
    return {"blocked": community.blocks(_user(request))}


@router.get("/moderation")
def moderation(request: Request):
    return {"solutions": _run(community.moderation_queue, _user(request))}


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
