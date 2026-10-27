"""Serverseitige Pruefung der Rechte und Kontingente fuer die Endpunkte (gehosteter Dienst).

Jeder Endpunkt mit einer Bezahlfunktion ruft `require(request, "can_...")`. Der Tarif kommt immer aus der Datenbank
(app/billing.py), nie aus der Anfrage: ein manipulierter Client kann sich nichts freischalten. Im Einzelplatzmodus
(eigener PC, Windows-App) gibt es keine Konten und keine Tarife – dort ist alles erlaubt, ausser Integrationen, die
global ausgeschaltet sind (ChatGPT).
"""
from __future__ import annotations

from fastapi import HTTPException, Request

from . import billing, config, plans


def _legacy(user: dict) -> dict:
    return {"plan": user.get("plan"), "plan_until": user.get("plan_until")}


def plan_of(user: dict | None) -> str:
    if not config.is_hosted():
        return billing.LOCAL_PLAN
    if not user:
        return "free"
    conn = billing.connect()
    try:
        return billing.current_plan(conn, user["id"], legacy=_legacy(user))
    finally:
        conn.close()


def has(user: dict | None, entitlement: str) -> bool:
    if entitlement == "chatgpt_connection_premium" and plans.INTEGRATIONS["chatgpt"]["status"] != "enabled":
        # Produktregel nur fuer die Anzeige; solange die Integration aus ist, bewirbt sie niemand als verfuegbar
        return False
    if not config.is_hosted():
        return True
    return plans.has(plan_of(user), entitlement)


def user_of(request: Request | None) -> dict | None:
    return getattr(getattr(request, "state", None), "user", None)


def required_plan(entitlement: str) -> str | None:
    e = plans.ENTITLEMENTS.get(entitlement)
    return e["from"] if e else None


def forbidden(entitlement: str) -> HTTPException:
    need = required_plan(entitlement)
    name = plans.PLANS[need]["name"] if need else "einem höheren Tarif"
    return HTTPException(403, {"detail": f"Diese Funktion gibt es ab {name}.", "code": "plan_required",
                               "entitlement": entitlement, "required_plan": need})


def require(request: Request, entitlement: str) -> dict | None:
    """403 plan_required, wenn das Konto der Anfrage das Recht nicht hat. Liefert den Nutzer (lokal: None)."""
    user = user_of(request)
    if not has(user, entitlement):
        raise forbidden(entitlement)
    return user


def consume(request: Request, feature: str, request_id: str) -> billing.ConsumeResult:
    """Ein Element eines Monatskontingents verbrauchen; 429 quota_exhausted, wenn es aufgebraucht ist.
    Lokal (eigener PC) gibt es keine Kontingente."""
    if not config.is_hosted():
        return billing.ConsumeResult(ok=True, used=0, limit=0)
    user = user_of(request)
    if not user:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    conn = billing.connect()
    try:
        r = billing.consume(conn, user["id"], feature, request_id, legacy=_legacy(user))
    finally:
        conn.close()
    if not r.ok:
        label = plans.QUOTA_LABELS.get(feature, feature)
        raise HTTPException(429, {"detail": f"{label}: Kontingent für diesen Monat aufgebraucht ({r.used} von {r.limit}).",
                                  "code": "quota_exhausted", "feature": feature, "used": r.used, "limit": r.limit})
    return r


def refund(request_id: str) -> None:
    if not config.is_hosted():
        return
    conn = billing.connect()
    try:
        billing.refund(conn, request_id)
    finally:
        conn.close()


def status(request: Request) -> dict:
    if not config.is_hosted():
        return billing.local_status()
    user = user_of(request)
    conn = billing.connect()
    try:
        out = billing.status(conn, user)
    finally:
        conn.close()
    out["entitlements"]["chatgpt_connection_premium"] = has(user, "chatgpt_connection_premium")
    return out
