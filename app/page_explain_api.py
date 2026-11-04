"""HTTP-Schnittstelle des Erklaerungsspeichers (app/page_explain.py), Routen /api/explain. Nur im gehosteten Dienst mit
Sitzung (wie app/community_api.py), sonst 501. Fehler wie beim Konto: {"detail": "...", "code": "..."}.

- GET    /api/explain?file_key=&page=&mode=         Varianten eines Schluessels, niedrigste zuerst (page/mode optional:
                                                     ohne beides alle Datensaetze der Datei, hoechstens QUERY_LIMIT)
- GET    /api/explain/{file_key}/{page}/{mode}/{variant}   ein Datensatz (404 not_found)
- POST   /api/explain                                neuen Datensatz anlegen: {file_key, page, mode, payload, version?, variant?};
                                                     naechster freier Platz 1..3, nie ueberschreiben, 409 explain_full /
                                                     explain_taken; nur mit bestaetigter E-Mail-Adresse (wie Veroeffentlichen)
- DELETE /api/explain/{file_key}/{page}/{mode}/{variant}   nur Ersteller oder Inhaber (403 not_owner)

Speichern und Loeschen zaehlen gegen accounts.LIMITS["explain_user"] (429 rate_limited mit Retry-After).
"""
from __future__ import annotations

from fastapi import APIRouter, Body, HTTPException, Request

from . import accounts, config, page_explain

router = APIRouter(prefix="/api/explain", tags=["explain"])


def _err(e: page_explain.PageExplainError) -> HTTPException:
    return HTTPException(e.status, {"detail": e.message, "code": e.code, **e.extra})


def _user(request: Request) -> dict:
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Den Erklärungsspeicher gibt es nur im gehosteten Dienst (LERNAPP_MODE=hosted).",
                                  "code": "not_hosted"})
    u = getattr(request.state, "user", None)
    if not u:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return u


def _limit(user: dict) -> None:
    try:
        accounts.hit_limit(page_explain.LIMIT_NAME, user["id"])
    except accounts.AccountError as e:
        headers = {"Retry-After": str(e.retry_after)} if getattr(e, "retry_after", None) else None
        raise HTTPException(e.status, {"detail": e.message, "code": e.code}, headers=headers)


def _run(fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs)
    except page_explain.PageExplainError as e:
        raise _err(e)


@router.get("")
def list_explanations(request: Request, file_key: str = "", page: str | None = None, mode: str | None = None):
    """Datensaetze zu einer Datei; mit page und mode dazu `free` (freie Plaetze) und `full` (alle drei belegt)."""
    u = _user(request)
    records = _run(page_explain.list_records, file_key, page, mode, u)
    out = {"file_key": file_key, "records": records, "max_variants": page_explain.MAX_VARIANTS}
    if page is not None and mode is not None:
        free = page_explain.free_variants(r["variant"] for r in records)
        out.update({"page": int(page), "mode": mode, "free": free, "full": not free,
                    "preferred": page_explain.preferred_variant(r["variant"] for r in records)})
    return out


@router.get("/{file_key}/{page}/{mode}/{variant}")
def get_explanation(request: Request, file_key: str, page: str, mode: str, variant: str):
    u = _user(request)
    rec = _run(page_explain.get_record, file_key, page, mode, variant, u)
    if not rec:
        raise HTTPException(404, {"detail": "Diese Erklärung gibt es nicht (mehr).", "code": "not_found"})
    return rec


@router.post("", status_code=201)
def store_explanation(request: Request, body: dict = Body(...)):
    """Neue Variante speichern. Der Dienst sieht nur das Chiffrat; `created_at` setzt der Dienst (UTC)."""
    u = _user(request)
    if not u.get("email_verified"):
        raise HTTPException(403, {"detail": "Bitte bestätige zuerst deine E-Mail-Adresse (Link in der Willkommensmail, "
                                            "neu anfordern unter Konto).", "code": "email_unverified"})
    if not isinstance(body, dict):
        raise HTTPException(400, {"detail": "Erwartet ein Objekt mit file_key, page, mode und payload.", "code": "bad_request"})
    _limit(u)
    return _run(page_explain.store, u, body.get("file_key"), body.get("page"), body.get("mode"), body.get("payload"),
                body.get("version"), body.get("variant"))


@router.delete("/{file_key}/{page}/{mode}/{variant}")
def delete_explanation(request: Request, file_key: str, page: str, mode: str, variant: str):
    u = _user(request)
    _limit(u)
    _run(page_explain.delete, u, file_key, page, mode, variant)
    return {"deleted": True}
