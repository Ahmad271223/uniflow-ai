"""Endpunkte der Konto-Pflicht am eigenen PC (Windows-App, app/account_mode.py). Im Dienst gibt es sie nicht (404).

- GET  /api/app-account/status?refresh=1    Zustand (signed_out | unverified | trial | active | subscription_required),
                                            Konto, Tarif, Probe, Apple-Abo, Kulanzzeit; refresh=1 fragt den Dienst
- POST /api/app-account/login               {email, password}: Anmelden mit E-Mail und Passwort des StudiNow-Kontos
- POST /api/app-account/browser-login       {mode: login|register, provider?: apple|google}: im Systembrowser anmelden
- GET  /konto/rueckkehr?code&state          Rueckleitung aus dem Browser (HTML-Seite, ausserhalb von /api)
- POST /api/app-account/logout              abmelden (Token weg, Daten bleiben)
- POST /api/app-account/checkout            {plan}: Stripe-Checkout im Systembrowser; mit Apple-Abo 409
- POST /api/app-account/portal              Stripe-Kundenportal (wechseln, kuendigen) im Systembrowser
- GET  /api/app-account/export              eigene Daten dieses PCs als ZIP (auch ohne Abo)
"""
from __future__ import annotations

from fastapi import APIRouter, Body, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse
from starlette.background import BackgroundTask

from . import account_mode, config

router = APIRouter()
LOOPBACK = ("127.0.0.1", "::1", "localhost", "testclient")


def _local(request: Request | None = None, loopback: bool = False) -> None:
    if config.is_hosted():
        raise HTTPException(404, {"detail": "Gibt es nur in der Windows-App.", "code": "not_local"})
    if loopback and request is not None and (request.client.host if request.client else "") not in LOOPBACK:
        raise HTTPException(403, {"detail": "Nur auf dem PC, auf dem StudiNow läuft.", "code": "not_loopback"})


def _call(fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs)
    except account_mode.AccountModeError as e:
        raise HTTPException(e.status, {"detail": e.message, "code": e.code})


@router.get("/api/app-account/status")
def status(refresh: bool = False):
    _local()
    return account_mode.refresh() if refresh else account_mode.info()


@router.post("/api/app-account/login")
def login(body: dict = Body(...)):
    _local()
    return _call(account_mode.login_password, str(body.get("email") or ""), str(body.get("password") or ""))


@router.post("/api/app-account/browser-login")
def browser_login(request: Request, body: dict = Body(default={})):
    _local(request, loopback=True)
    b = body if isinstance(body, dict) else {}
    base = f"{request.url.scheme}://{request.url.netloc}"
    return _call(account_mode.start_browser_login, base, str(b.get("mode") or "login"), b.get("provider"),
                 open_browser=b.get("open_browser") is not False)


@router.get(account_mode.CALLBACK_PATH, include_in_schema=False)
def browser_return(request: Request):
    _local(request, loopback=True)
    status_code, page = account_mode.complete_browser_login(dict(request.query_params))
    return HTMLResponse(page, status_code=status_code, headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"})


@router.post("/api/app-account/logout")
def logout():
    _local()
    return account_mode.logout()


@router.post("/api/app-account/checkout")
def checkout(request: Request, body: dict = Body(...)):
    _local(request, loopback=True)
    return _call(account_mode.checkout, str(body.get("plan") or ""), open_browser=body.get("open_browser") is not False)


@router.post("/api/app-account/portal")
def portal(request: Request, body: dict = Body(default={})):
    _local(request, loopback=True)
    b = body if isinstance(body, dict) else {}
    return _call(account_mode.portal, open_browser=b.get("open_browser") is not False)


@router.get("/api/app-account/export")
def export(request: Request):
    """Export am PC: im WLAN nur mit PIN (server.lan_pin_guard), nie aus dem Netz; eine fremde Webseite darf ihn
    nicht anstossen (wie /api/account/export im Dienst, Audit P24-02/P26-01)."""
    _local()
    from .account_api import _from_foreign_site
    if _from_foreign_site(request):
        raise HTTPException(403, {"detail": "Anfrage von fremder Seite abgelehnt.", "code": "cross_site"})
    path = _call(account_mode.export_zip)
    from datetime import date
    return FileResponse(path, media_type="application/zip", filename=f"studinow-daten-pc-{date.today().isoformat()}.zip",
                        background=BackgroundTask(lambda: path.unlink(missing_ok=True)))
