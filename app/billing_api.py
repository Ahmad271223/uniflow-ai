"""Endpunkte fuer Tarife, Abo-Stand, App-Store-Kaeufe und die ChatGPT-Integration.

- GET  /api/billing/plans                 Tarife, Rechte, Kontingente, Kaufwege je Plattform (oeffentlich)
- GET  /api/entitlements                  eigener Abo-Stand (Tarif, Rechte, Kontingente, Ablauf, geplanter Wechsel)
- POST /api/billing/apple/verify          gepruefter Kauf / Wiederherstellung aus der App {signed_transaction, signed_renewal?}
- POST /api/billing/apple/notifications   App Store Server Notifications V2 {signedPayload} (oeffentlich, Signatur geprueft)
- GET  /api/billing/ai-usage              KI-Kosten des Monats (nur Admin)
- GET  /api/integrations/chatgpt          Stand der offiziellen ChatGPT-Verbindung
- POST /api/integrations/chatgpt/connect  ohne Freigabe von OpenAI: 503 chatgpt_not_available (nie eine vorgetaeuschte Verbindung)

Zahlung im Web gibt es noch nicht (kein Zahlungsanbieter eingerichtet); die Tarife werden in der Apple-App gekauft.
"""
from __future__ import annotations

from fastapi import APIRouter, Body, HTTPException, Request

from . import apple_store, billing, config, entitlements, plans

router = APIRouter()

PUBLIC = {"/api/billing/plans", "/api/billing/apple/notifications"}


def _user(request: Request) -> dict:
    u = getattr(request.state, "user", None)
    if not u:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return u


def _hosted() -> None:
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Abos gibt es nur mit Studora-Konto im Dienst; auf dem eigenen PC ist alles frei.",
                                  "code": "not_hosted"})


def purchase_channels() -> dict:
    """Wo man einen Tarif abschliessen kann. Nur, was es technisch gibt."""
    return {
        "apple": {"available": True, "note": "Abschluss, Wechsel, Kündigung und Wiederherstellen in der iPad-/Mac-App "
                                             "über den App Store."},
        "web": {"available": False, "note": "Im Web und unter Windows gibt es noch keinen Abschluss. Ein Abo aus der "
                                            "Apple-App gilt hier automatisch, sobald du mit demselben Studora-Konto angemeldet bist."},
        "android": {"available": False, "note": "Die Android-App ist pausiert."},
    }


@router.get("/api/billing/plans")
def billing_plans():
    return {**plans.contract(), "purchase": purchase_channels(), "studora_ai_configured": _ai_configured()}


def _ai_configured() -> bool:
    from . import ai_backend
    return ai_backend.available()


@router.get("/api/entitlements")
def get_entitlements(request: Request):
    """Eigener Stand. Die Apps richten danach ihre Oberflaeche aus; der Server prueft trotzdem jeden Aufruf."""
    out = entitlements.status(request)
    out["purchase"] = purchase_channels()
    if config.is_hosted():
        out["apple_account_token"] = apple_store.account_token(_user(request)["id"])
    return out


@router.post("/api/billing/apple/verify")
def apple_verify(request: Request, body: dict = Body(...)):
    _hosted()
    u = _user(request)
    signed = body.get("signed_transaction")
    if not isinstance(signed, str) or not signed:
        raise HTTPException(400, {"detail": "signed_transaction fehlt.", "code": "jws_invalid"})
    conn = billing.connect()
    try:
        out = apple_store.verify_purchase(conn, u["id"], signed, body.get("signed_renewal") or None)
    except (apple_store.AppleError, billing.BillingError) as e:
        raise HTTPException(e.status, {"detail": e.message, "code": e.code})
    finally:
        conn.close()
    out["entitlements"] = entitlements.status(request)
    return out


@router.post("/api/billing/apple/notifications")
def apple_notifications(body: dict = Body(...)):
    _hosted()
    payload = body.get("signedPayload")
    if not isinstance(payload, str) or not payload:
        raise HTTPException(400, {"detail": "signedPayload fehlt.", "code": "jws_invalid"})
    conn = billing.connect()
    try:
        return apple_store.handle_notification(conn, payload)
    except (apple_store.AppleError, billing.BillingError) as e:
        raise HTTPException(e.status, {"detail": e.message, "code": e.code})
    finally:
        conn.close()


@router.get("/api/billing/ai-usage")
def ai_usage(request: Request):
    _hosted()
    if _user(request).get("role") != "admin":
        raise HTTPException(403, {"detail": "Nur für den Betrieb.", "code": "admin_required"})
    from . import ai_backend
    conn = ai_backend.connect()
    try:
        return ai_backend.month_report(conn)
    finally:
        conn.close()


# ---------------------------------------------------------------- ChatGPT (offizielle Integration, derzeit aus)

def chatgpt_state(user: dict | None) -> dict:
    integ = plans.INTEGRATIONS["chatgpt"]
    enabled = integ["status"] == "enabled"
    return {
        "status": integ["status"], "available": enabled, "connected": False, "reason": None if enabled else integ["reason"],
        # Produktregel: in der Oberflaeche ab Pro Connect angeboten. Die Kontingentnutzung selbst haengt nicht am Tarif,
        # solange die Bedingungen von OpenAI das nicht erlauben (plan_gating_allowed = False).
        "premium_rule_plan": plans.ENTITLEMENTS["chatgpt_connection_premium"]["from"],
        "plan_gating_allowed": integ["plan_gating_allowed"],
        "shown_in_ui": enabled and (not integ["plan_gating_allowed"] or entitlements.has(user, "chatgpt_connection_premium")),
    }


@router.get("/api/integrations/chatgpt")
def chatgpt_status(request: Request):
    return chatgpt_state(getattr(request.state, "user", None))


@router.post("/api/integrations/chatgpt/connect")
def chatgpt_connect(request: Request):
    st = chatgpt_state(getattr(request.state, "user", None))
    if not st["available"]:
        raise HTTPException(503, {"detail": st["reason"], "code": "chatgpt_not_available"})
    # Freigabe vorhanden: hier beginnt spaeter der OAuth-Ablauf (PKCE) laut docs/KI-CHATGPT-PLAN.md.
    raise HTTPException(501, {"detail": "Die ChatGPT-Verbindung wird nach der Freigabe durch OpenAI gebaut.",
                              "code": "chatgpt_not_implemented"})
