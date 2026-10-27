"""Endpunkte fuer Tarife, Abo-Stand, App-Store-Kaeufe und die ChatGPT-Integration.

- GET  /api/billing/plans                 Tarife, Rechte, Kontingente, Kaufwege je Plattform (oeffentlich)
- GET  /api/entitlements                  eigener Abo-Stand (Tarif, Rechte, Kontingente, Ablauf, geplanter Wechsel)
- POST /api/billing/apple/verify          gepruefter Kauf / Wiederherstellung aus der App {signed_transaction, signed_renewal?}
- POST /api/billing/apple/notifications   App Store Server Notifications V2 {signedPayload} (oeffentlich, Signatur geprueft)
- GET  /api/billing/ai-usage              KI-Kosten des Monats (nur Admin)
- GET  /api/integrations/chatgpt          Stand der offiziellen ChatGPT-Verbindung
- POST /api/integrations/chatgpt/connect  im Dienst ohne Freigabe von OpenAI: 503 chatgpt_not_available (nie eine
                                          vorgetaeuschte Verbindung); auf dem eigenen PC: Sign in with ChatGPT starten
- POST /api/integrations/chatgpt/disconnect, GET .../models, PUT .../settings {model, use_for_ai}  nur auf dem eigenen PC

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
    if not config.is_hosted():
        # Eigener PC / Windows-App: Sign in with ChatGPT fuer den eigenen Gebrauch (app/chatgpt_login.py), ohne Tarif
        from . import chatgpt_login
        st = chatgpt_login.status()
        return {**st, "reason": None, "premium_rule_plan": plans.ENTITLEMENTS["chatgpt_connection_premium"]["from"],
                "plan_gating_allowed": False, "shown_in_ui": True}
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


def _chatgpt_local():
    """Nur auf dem eigenen PC; im Dienst wie bisher 503 (keine vorgetaeuschte Verbindung)."""
    if config.is_hosted():
        raise HTTPException(503, {"detail": plans.INTEGRATIONS["chatgpt"]["reason"], "code": "chatgpt_not_available"})
    from . import chatgpt_login
    return chatgpt_login


def _chatgpt_call(fn):
    from . import chatgpt_login
    try:
        return fn()
    except chatgpt_login.ChatGPTError as e:
        raise HTTPException(e.status, {"detail": e.message, "code": e.code})


@router.post("/api/integrations/chatgpt/connect")
def chatgpt_connect(request: Request, body: dict | None = Body(default=None)):
    """Eigener PC: Anmeldung bei OpenAI im Browser beginnen (Loopback-Rueckleitung). Liefert die Adresse und den Port;
    die Oberflaeche fragt danach den Stand ab. Im Dienst 503, solange OpenAI nicht freigegeben hat."""
    cg = _chatgpt_local()
    open_browser = not (isinstance(body, dict) and body.get("open_browser") is False)
    return _chatgpt_call(lambda: cg.start(open_browser=open_browser))


@router.post("/api/integrations/chatgpt/disconnect")
def chatgpt_disconnect():
    cg = _chatgpt_local()
    cg.disconnect()
    return {"connected": False}


@router.get("/api/integrations/chatgpt/models")
def chatgpt_models(force: bool = False):
    cg = _chatgpt_local()
    return {"models": _chatgpt_call(lambda: cg.models(force=force)), "model": cg.model()}


@router.put("/api/integrations/chatgpt/settings")
def chatgpt_settings(body: dict = Body(...)):
    cg = _chatgpt_local()
    if "model" in body:
        _chatgpt_call(lambda: cg.set_model(str(body.get("model") or "")))
    if "use_for_ai" in body:
        cg.set_use_for_ai(bool(body["use_for_ai"]))
    return cg.status()
