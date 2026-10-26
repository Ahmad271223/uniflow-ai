"""HTTP-Schnittstelle der UniFlow-Konten (Vertrag G1). Nur im gehosteten Modus erreichbar (`LERNAPP_MODE=hosted`);
im Einzelplatzmodus antworten alle Pfade 501, damit kein Client ein Konto an einem PC anlegt, der keines verwaltet.

Sitzung: Antwort von /login enthaelt `token` (fuer native Apps: `Authorization: Bearer <token>`); der Browser
bekommt zusaetzlich das Cookie `uniflow_session` (HttpOnly, SameSite=Lax, Secure bei LERNAPP_HTTPS=1).
Fehler: `{"detail": "...", "code": "<stabiler Code>"}` mit dem HTTP-Status aus app/accounts.py.
"""
from __future__ import annotations

import os

from fastapi import APIRouter, Body, HTTPException, Request, Response
from fastapi.responses import JSONResponse

from . import accounts, config

router = APIRouter(prefix="/api/account", tags=["account"])
COOKIE = "uniflow_session"
# Pfade ohne Sitzung (alles andere unter /api braucht im gehosteten Modus eine Sitzung)
PUBLIC_PATHS = {"/api/account/register", "/api/account/login", "/api/account/login/apple", "/api/account/login/google",
                "/api/account/password/reset-request", "/api/account/password/reset", "/api/account/info"}


def _err(e: accounts.AccountError) -> HTTPException:
    return HTTPException(e.status, {"detail": e.message, "code": e.code})


def token_of(request: Request) -> str | None:
    auth = request.headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        return auth[7:].strip() or None
    return request.cookies.get(COOKIE)


def _set_cookie(response: Response, token: str | None) -> None:
    secure = os.environ.get("LERNAPP_HTTPS") == "1"
    if token:
        response.set_cookie(COOKIE, token, max_age=accounts.SESSION_DAYS * 86400, httponly=True, samesite="lax", secure=secure, path="/")
    else:
        response.delete_cookie(COOKIE, path="/")


def _hosted_only() -> None:
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Konten gibt es nur im gehosteten Dienst (LERNAPP_MODE=hosted).", "code": "not_hosted"})


def _user(request: Request) -> dict:
    u = getattr(request.state, "user", None)
    if not u:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return u


def _device(body: dict, request: Request) -> tuple[str | None, str | None]:
    return (body.get("device_id") or None, body.get("device_name") or (request.headers.get("user-agent") or "")[:120] or None)


@router.get("/info")
def info():
    """Oeffentlich: Betriebsart und Regeln, damit Clients das Formular passend bauen."""
    return {"mode": config.MODE, "hosted": config.is_hosted(), "password_min": accounts.PASSWORD_MIN,
            "session_days": accounts.SESSION_DAYS, "universities": list(config.KNOWN_UNIVERSITIES),
            "providers": sorted(accounts.identity_verifiers)}


@router.post("/register", status_code=201)
def register(request: Request, body: dict = Body(...)):
    _hosted_only()
    try:
        user = accounts.register(body.get("email"), body.get("password"), (body.get("university") or "").strip().lower())
        _, token = accounts.login(user["email"], body.get("password"), *_device(body, request))
    except accounts.AccountError as e:
        raise _err(e)
    resp = JSONResponse({"user": user, "token": token}, status_code=201)
    _set_cookie(resp, token)
    return resp


@router.post("/login")
def login(request: Request, body: dict = Body(...)):
    _hosted_only()
    ip = request.client.host if request.client else None
    try:
        user, token = accounts.login(body.get("email"), body.get("password") or "", *_device(body, request), client_ip=ip)
    except accounts.AccountError as e:
        raise _err(e)
    resp = JSONResponse({"user": user, "token": token})
    _set_cookie(resp, token)
    return resp


@router.post("/login/{provider}")
def login_provider(provider: str, request: Request, body: dict = Body(...)):
    """Anmelden mit Apple/Google: `identity_token` vom Anbieter; neues Konto braucht `university`."""
    _hosted_only()
    if provider not in ("apple", "google"):
        raise HTTPException(404, {"detail": "Unbekannter Anbieter", "code": "provider_unknown"})
    try:
        user, token, created = accounts.login_with_identity(provider, body.get("identity_token") or "", *_device(body, request),
                                                            university=(body.get("university") or "").strip().lower() or None)
    except accounts.AccountError as e:
        raise _err(e)
    resp = JSONResponse({"user": user, "token": token, "created": created}, status_code=201 if created else 200)
    _set_cookie(resp, token)
    return resp


@router.post("/link/{provider}")
def link(provider: str, request: Request, body: dict = Body(...)):
    _hosted_only()
    u = _user(request)
    if provider not in ("apple", "google"):
        raise HTTPException(404, {"detail": "Unbekannter Anbieter", "code": "provider_unknown"})
    try:
        return accounts.link_identity(u["id"], provider, body.get("identity_token") or "")
    except accounts.AccountError as e:
        raise _err(e)


@router.get("/me")
def me(request: Request):
    _hosted_only()
    u = _user(request)
    return {"user": u, "sessions": accounts.sessions(u["id"], token_of(request))}


@router.post("/logout")
def logout(request: Request):
    _hosted_only()
    accounts.logout(token_of(request))
    resp = JSONResponse({"ok": True})
    _set_cookie(resp, None)
    return resp


@router.post("/logout-all")
def logout_all(request: Request):
    """Alle anderen Sitzungen beenden (diese bleibt)."""
    _hosted_only()
    u = _user(request)
    return {"revoked": accounts.logout_all(u["id"], keep_token=token_of(request))}


@router.post("/password")
def change_password(request: Request, body: dict = Body(...)):
    _hosted_only()
    u = _user(request)
    try:
        accounts.change_password(u["id"], body.get("old_password") or "", body.get("new_password") or "")
    except accounts.AccountError as e:
        raise _err(e)
    accounts.logout_all(u["id"], keep_token=token_of(request))
    return {"ok": True}


@router.post("/password/reset-request")
def reset_request(body: dict = Body(...)):
    """Antwort immer gleich: verraet nicht, ob es das Konto gibt. Das Token geht nur ueber den Versandweg."""
    _hosted_only()
    accounts.request_password_reset(body.get("email") or "")
    return {"ok": True, "message": "Wenn es ein Konto mit dieser Adresse gibt, wurde ein Link zum Zurücksetzen verschickt."}


@router.post("/password/reset")
def reset(body: dict = Body(...)):
    _hosted_only()
    try:
        accounts.reset_password(body.get("token") or "", body.get("new_password") or "")
    except accounts.AccountError as e:
        raise _err(e)
    return {"ok": True}


@router.post("/university")
def set_university(request: Request, body: dict = Body(...)):
    """Hochschule wechseln: die Daten jeder Hochschule bleiben in ihrem eigenen Ordner erhalten."""
    _hosted_only()
    u = _user(request)
    try:
        return {"user": accounts.set_university(u["id"], (body.get("university") or "").strip().lower())}
    except accounts.AccountError as e:
        raise _err(e)


@router.post("/delete")
def delete(request: Request, body: dict = Body(default={})):
    """Konto loeschen: sofort gesperrt und abgemeldet, Daten nach 30 Tagen endgueltig weg."""
    _hosted_only()
    u = _user(request)
    try:
        out = accounts.delete_account(u["id"], body.get("password"))
    except accounts.AccountError as e:
        raise _err(e)
    resp = JSONResponse(out)
    _set_cookie(resp, None)
    return resp
