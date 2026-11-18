"""Klausur-Generator: Adressen fuer App, Web und Windows (app/exam_shop.py).

- `POST /api/exam-shop/offer` {files: [{sha256, doc_type, pages}]} -> Stand je Probeklausur (1..10), Preis, ob der Dienst
  die Seitentexte gerade hat
- `POST /api/exam-shop/buy` {files, count, texts?, wait_s?} -> gekauft; `409 needs_texts`, wenn neue Probeklausuren
  erzeugt werden muessen und der Dienst die Seitentexte nicht hat; `429 credits_exhausted` wie ueberall
- `GET /api/exam-shop/item/{key}/pdf/{aufgaben|loesungen}` -> PDF (nur gekauft und fertig)

Nur Pro AI (Recht `can_use_ai_explanations`) und mit bestaetigter E-Mail-Adresse, wie die uebrige StudiNow-KI.
"""
from __future__ import annotations

import re

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse
from starlette.concurrency import run_in_threadpool

from . import config, entitlements, exam_shop

router = APIRouter()

KEY_RE = re.compile(r"^pk-[0-9a-f]{40}-\d{2}$")


def _user(request: Request) -> str:
    entitlements.require(request, "can_use_ai_explanations")
    user = entitlements.require_verified_for_ai(request)
    if user:
        return str(user["id"])
    if config.is_hosted():
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return "local"


def _err(e: exam_shop.ShopError) -> HTTPException:
    return HTTPException(e.status, {"detail": e.detail, "code": e.code, **e.extra})


async def _body(request: Request) -> dict:
    try:
        b = await request.json()
    except Exception:
        b = None
    if not isinstance(b, dict):
        raise HTTPException(422, {"detail": "JSON erwartet", "code": "bad_request"})
    return b


@router.post("/api/exam-shop/offer")
async def offer(request: Request) -> dict:
    uid = _user(request)
    b = await _body(request)
    try:
        files = exam_shop.clean_files(b.get("files"))
    except exam_shop.ShopError as e:
        raise _err(e)
    return await run_in_threadpool(exam_shop.overview, uid, exam_shop.set_key_of(files))


@router.post("/api/exam-shop/buy")
async def buy(request: Request) -> dict:
    uid = _user(request)
    b = await _body(request)
    count = b.get("count", 1)
    wait = b.get("wait_s", 0)
    try:
        return await run_in_threadpool(exam_shop.buy, uid, b.get("files"), count if isinstance(count, int) else -1,
                                       b.get("texts"), float(wait) if isinstance(wait, (int, float)) else 0)
    except exam_shop.ShopError as e:
        raise _err(e)


@router.get("/api/exam-shop/item/{key}/pdf/{which}")
async def pdf(request: Request, key: str, which: str):
    uid = _user(request)
    if not KEY_RE.match(key):
        raise HTTPException(404, {"detail": "Nicht gefunden.", "code": "not_found"})
    try:
        path = await run_in_threadpool(exam_shop.pdf_for, uid, key, which)
    except exam_shop.ShopError as e:
        raise _err(e)
    return FileResponse(path, media_type="application/pdf", filename=path.name,
                        headers={"Cache-Control": "private, no-store"})
