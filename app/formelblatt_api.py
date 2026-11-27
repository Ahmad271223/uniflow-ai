"""Formelblaetter: Adressen fuer App, Web und Windows (app/formelblatt.py).

- `POST /api/formelblatt/offer` {modules: [Name, …]} -> {items: [{id, title, module, credits, pages, version, description, owned}]}
- `POST /api/formelblatt/{id}/buy` -> {item, credits_charged}; schon gekauft: 0 Credits; `429 credits_exhausted` wie ueberall
- `GET /api/formelblatt/{id}/pdf` -> PDF (nur gekauft)

Nur Pro AI (Recht `can_use_ai_explanations`) und mit bestaetigter E-Mail-Adresse, wie der Klausur-Generator.
"""
from __future__ import annotations

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse
from starlette.concurrency import run_in_threadpool

from . import config, entitlements, formelblatt, plans

router = APIRouter()


def _user(request: Request, needs_credits: bool = True) -> tuple[str, str]:
    """`needs_credits` False (26.11.2026 neues Modell): ein gekauftes Blatt abholen (pdf) braucht den Tarif, aber keine
    verfuegbaren Credits - sonst kaeme ein Konto mit aufgebrauchten Credits nicht mehr an seinen Kauf."""
    if needs_credits or not config.is_hosted():
        entitlements.require(request, "can_use_ai_explanations")
    elif not plans.has(entitlements.plan_of(entitlements.user_of(request)), "can_use_ai_explanations"):
        raise entitlements.forbidden("can_use_ai_explanations")
    user = entitlements.require_verified_for_ai(request)
    if user:
        return str(user["id"]), config.normalize_university(user.get("university"))
    if config.is_hosted():
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return "local", config.UNIVERSITY


def _err(e: formelblatt.SheetError) -> HTTPException:
    return HTTPException(e.status, {"detail": e.detail, "code": e.code, **e.extra})


def _id(sheet_id: str) -> str:
    if not formelblatt.ID_RE.match(sheet_id or ""):
        raise HTTPException(404, {"detail": "Nicht gefunden.", "code": "not_found"})
    return sheet_id


@router.post("/api/formelblatt/offer")
async def offer(request: Request) -> dict:
    uid, uni = _user(request)
    try:
        b = await request.json()
    except Exception:
        b = None
    if not isinstance(b, dict):
        raise HTTPException(422, {"detail": "JSON erwartet", "code": "bad_request"})
    try:
        return await run_in_threadpool(formelblatt.offers, uid, uni, b.get("modules"))
    except formelblatt.SheetError as e:
        raise _err(e)


@router.post("/api/formelblatt/{sheet_id}/buy")
async def buy(request: Request, sheet_id: str) -> dict:
    uid, uni = _user(request)
    try:
        return await run_in_threadpool(formelblatt.buy, uid, uni, _id(sheet_id))
    except formelblatt.SheetError as e:
        raise _err(e)


@router.get("/api/formelblatt/{sheet_id}/pdf")
async def pdf(request: Request, sheet_id: str):
    uid, uni = _user(request, needs_credits=False)
    try:
        path = await run_in_threadpool(formelblatt.pdf_for, uid, uni, _id(sheet_id))
    except formelblatt.SheetError as e:
        raise _err(e)
    return FileResponse(path, media_type="application/pdf", filename=path.name, headers={"Cache-Control": "private, no-store"})
