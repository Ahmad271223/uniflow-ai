"""Endpunkte fuer Einladungen (app/invites.py, docs/EINLADUNGEN.md). Alle brauchen eine Sitzung (Middleware in app/server.py).

- POST /api/invites                 neuen Einladungslink anlegen (nur in der Probewoche, hoechstens 20)
- GET  /api/invites                 eigene Links mit Einloesungen, Zaehler, Stufen (erreicht, eingeloest, einloesbar);
                                    Vorrat der Angebotscodes nur fuer Admins
- POST /api/invites/redeem {code}   Einloesung durch das neue Konto (einmal je Person, idempotent)
- POST /api/invites/claim {tier, choice}   Angebotscode fuer eine erreichte Stufe + Apples Einloese-Adresse
- POST /api/billing/offer-codes {product, tier, codes|text}   Vorrat hochladen (nur Admin, Export aus App Store Connect)
- GET  /api/billing/offer-codes     Vorrat je Produkt und Stufe (nur Admin)

Anlegen, Einloesen und Belohnung abholen zaehlen je Konto gegen invites.LIMITS (429 rate_limited mit Retry-After),
zusaetzlich zur Grenze aller /api-Aufrufe in app/server.py.

Windows-App (Einzelplatz, 05.11.2026): mit angemeldetem StudiNow-Konto reicht der lokale Server die vier Endpunkte
des Kontos (Uebersicht, neuer Link, Einloesen, Belohnung) mit dessen Token an den Dienst weiter (`_forward`, wie
/api/community); ohne Konto bleibt es bei 501 not_hosted. Die Vorrats-Endpunkte (Admin) gibt es nur im Dienst.
"""
from __future__ import annotations

import json

from fastapi import APIRouter, Body, HTTPException, Request
from fastapi.responses import Response

from . import config, invites

router = APIRouter()


def _user(request: Request) -> dict:
    u = getattr(request.state, "user", None)
    if not u:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return u


def _hosted() -> None:
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Einladungen gibt es nur mit StudiNow-Konto im Dienst.", "code": "not_hosted"})


def _forward(method: str, path: str, body: dict | None = None):
    """Einzelplatz mit StudiNow-Konto: Anfrage mit dem Token des Kontos an den Dienst; sonst None (dann 501)."""
    if config.is_hosted():
        return None
    from . import service_link
    if not service_link.linked():
        return None
    try:
        status, hdrs, data = service_link.call(method, path, json.dumps(body).encode() if body is not None else None)
    except service_link.LinkError as e:
        raise HTTPException(e.status, {"detail": e.message, "code": e.code})
    return Response(content=data, status_code=status, media_type=hdrs.get("content-type") or "application/json",
                    headers={"Cache-Control": "no-store"})


def _admin(request: Request) -> dict:
    u = _user(request)
    if u.get("role") != "admin":
        raise HTTPException(403, {"detail": "Nur für den Betrieb.", "code": "admin_required"})
    return u


def _call(fn):
    conn = invites.connect()
    try:
        return fn(conn)
    except invites.InviteError as e:
        headers = {"Retry-After": str(e.retry_after)} if e.retry_after else None
        raise HTTPException(e.status, {"detail": e.message, "code": e.code}, headers=headers)
    finally:
        conn.close()


@router.get("/api/invites")
def my_invites(request: Request):
    if (fw := _forward("GET", "/api/invites")) is not None:
        return fw
    _hosted()
    u = _user(request)
    return _call(lambda conn: invites.overview(conn, u))


@router.post("/api/invites", status_code=201)
def create_invite(request: Request):
    if (fw := _forward("POST", "/api/invites", {})) is not None:
        return fw
    _hosted()
    u = _user(request)

    def run(conn):
        created = invites.create(conn, u["id"])
        return {"invite": created, **invites.overview(conn, u)}
    return _call(run)


@router.post("/api/invites/redeem")
def redeem_invite(request: Request, body: dict = Body(...)):
    if (fw := _forward("POST", "/api/invites/redeem", body)) is not None:
        return fw
    _hosted()
    u = _user(request)
    code = body.get("code")
    if not isinstance(code, str) or not code.strip():
        raise HTTPException(400, {"detail": "code fehlt.", "code": "invite_code_missing"})
    return _call(lambda conn: invites.redeem(conn, u, code))


@router.post("/api/invites/claim")
def claim_reward(request: Request, body: dict = Body(...)):
    if (fw := _forward("POST", "/api/invites/claim", body)) is not None:
        return fw
    _hosted()
    u = _user(request)
    return _call(lambda conn: invites.claim(conn, u, body.get("tier"), body.get("choice") or "plus"))


@router.get("/api/billing/offer-codes")
def offer_code_stock(request: Request):
    _hosted()
    _admin(request)
    return _call(lambda conn: {"stock": invites.stock(conn), "tiers": invites.contract()["tiers"]})


@router.post("/api/billing/offer-codes")
def upload_offer_codes(request: Request, body: dict = Body(...)):
    """Stapel aus App Store Connect: `codes` als Liste oder `text` mit einer Zeile je Code (Kopfzeilen mit # werden
    uebersprungen), dazu `product` (plus | pro_ai) und `tier` (5 | 10 | 20)."""
    _hosted()
    _admin(request)
    codes = body.get("codes")
    if not isinstance(codes, list):
        codes = str(body.get("text") or "").splitlines()
    if len(codes) > invites.MAX_UPLOAD_LINES:
        raise HTTPException(413, {"detail": f"Der Stapel ist zu groß (höchstens {invites.MAX_UPLOAD_LINES} Zeilen je Upload).",
                                  "code": "offer_codes_too_many"})
    return _call(lambda conn: invites.upload_codes(conn, str(body.get("product") or ""), body.get("tier"),
                                                   [c if isinstance(c, str) else "" for c in codes]))
