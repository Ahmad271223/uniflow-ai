"""HTTP-Schnittstelle des Weck-Signals (app/wake_push.py, docs/WECK-SIGNAL-2026-11-17.md): die Apple-App meldet ihr
APNs-Token, damit der Dienst sie tagsueber alle 30 Minuten zum Abgleich wecken kann.

    PUT    /api/account/push-token   {token, platform, app_version, timezone, environment}  -> {ok, push, schedule}
    DELETE /api/account/push-token   {token} oder ohne Rumpf (Geraet dieser Sitzung)        -> {ok, removed}

Anmeldung wie alle Konto-Pfade: `Authorization: Bearer <Sitzungs-Token>` (hosted_guard in app/server.py), sonst 401
`unauthenticated`; nur im gehosteten Dienst (sonst 501 `not_hosted`). Fehler in der ueblichen Form
`{"detail": "...", "code": "..."}`. Das Token steht nur im Rumpf, nie im Pfad oder in der Abfrage (beides landet im
Zugriffsprotokoll).

Eigener Router statt app/account_api.py: dessen Routenliste ist Teil des Konto-Vertrags
(packages/shared-contracts/fixtures/account/contract.json, tools/gen-account-fixture.py).
"""
from __future__ import annotations

from fastapi import APIRouter, Body, Request

from . import account_api, accounts, wake_push

router = APIRouter(prefix="/api/account", tags=["account"], route_class=account_api.NoStoreRoute)
FIELDS = ("token", "platform", "app_version", "timezone", "environment")


@router.put("/push-token")
def set_push_token(request: Request, body: dict = Body(...)):
    """Geraet fuer das Weck-Signal melden oder die Meldung auffrischen (Zeitzone, App-Version); beliebig oft."""
    account_api._hosted_only()
    u = account_api._user(request)
    values = [account_api._text(body, key) for key in FIELDS]
    try:
        wake_push.hit_limit(u["id"])
        out = wake_push.register(u["id"], account_api.token_of(request), *values)
    except accounts.AccountError as e:
        raise account_api._err(e)
    return {"ok": True, **out}


@router.delete("/push-token")
def delete_push_token(request: Request, body: dict = Body(default={})):
    """Meldung zuruecknehmen: `token` im Rumpf oder, ohne Rumpf, das Geraet dieser Sitzung. Nichts da: trotzdem ok."""
    account_api._hosted_only()
    u = account_api._user(request)
    try:
        removed = wake_push.unregister(u["id"], account_api.token_of(request), account_api._text(body, "token") or None)
    except accounts.AccountError as e:
        raise account_api._err(e)
    return {"ok": True, "removed": removed}
