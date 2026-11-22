"""StudiNow-Erklärungen: Adressen für die App (app/erklaerung_shop.py).

- `POST /api/erklaerungen/offer` {sha256: [...]} -> {enabled, price, items: [{sha256, title, kind, pages, owned}]}
  (nur Dateien, zu denen es ein PDF gibt)
- `POST /api/erklaerungen/buy` {sha256} -> gekauft ({…, owned: true, charged}); `429 credits_exhausted` wie überall,
  `404 not_available`, ein zweiter Kauf kostet nichts
- `GET /api/erklaerungen/mine` -> alles Gekaufte des Kontos (Abholen auf jedem Gerät)
- `GET /api/erklaerungen/{sha256}/pdf` -> das PDF (nur gekauft)

Nur Pro AI (Recht `can_use_ai_explanations`) und mit bestätigter E-Mail-Adresse, wie der Klausur-Generator.
"""
from __future__ import annotations

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse
from starlette.concurrency import run_in_threadpool

from . import config, entitlements, erklaerung_shop

router = APIRouter()


def _user(request: Request) -> str:
    entitlements.require(request, "can_use_ai_explanations")
    user = entitlements.require_verified_for_ai(request)
    if user:
        return str(user["id"])
    if config.is_hosted():
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return "local"


def _err(e: erklaerung_shop.ShopError) -> HTTPException:
    return HTTPException(e.status, {"detail": e.detail, "code": e.code, **e.extra})


async def _body(request: Request) -> dict:
    try:
        b = await request.json()
    except Exception:
        b = None
    if not isinstance(b, dict):
        raise HTTPException(422, {"detail": "JSON erwartet", "code": "bad_request"})
    return b


@router.post("/api/erklaerungen/offer")
async def offer(request: Request) -> dict:
    uid = _user(request)
    b = await _body(request)
    try:
        return await run_in_threadpool(erklaerung_shop.offer, uid, b.get("sha256"))
    except erklaerung_shop.ShopError as e:
        raise _err(e)


@router.get("/api/erklaerungen/mine")
async def mine(request: Request) -> dict:
    uid = _user(request)
    return await run_in_threadpool(erklaerung_shop.mine, uid)


@router.post("/api/erklaerungen/buy")
async def buy(request: Request) -> dict:
    uid = _user(request)
    b = await _body(request)
    try:
        return await run_in_threadpool(erklaerung_shop.buy, uid, b.get("sha256"))
    except erklaerung_shop.ShopError as e:
        raise _err(e)


@router.get("/api/erklaerungen/{sha}/pdf")
async def pdf(request: Request, sha: str):
    uid = _user(request)
    try:
        path = await run_in_threadpool(erklaerung_shop.pdf_for, uid, sha)
    except erklaerung_shop.ShopError as e:
        raise _err(e)
    return FileResponse(path, media_type="application/pdf", filename=f"StudiNow-Erklaerung-{sha[:10]}.pdf",
                        headers={"Cache-Control": "private, no-store"})
