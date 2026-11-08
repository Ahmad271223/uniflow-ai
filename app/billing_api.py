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

- POST /api/billing/stripe/checkout       {plan, interval: month|year} -> Checkout-Adresse (Web, Windows; app/stripe_billing.py)
- POST /api/billing/stripe/portal         Kundenportal (Wechsel, Kuendigung, Rechnungen)
- POST /api/billing/stripe/webhook        Ereignisse von Stripe (oeffentlich, Signatur geprueft)
- POST /api/billing/plan-choice           {plan} Antwort auf die Aufforderung nach der 7-Tage-Probe
"""
from __future__ import annotations

from fastapi import APIRouter, Body, HTTPException, Request

from . import apple_store, billing, config, entitlements, plans, stripe_billing

router = APIRouter()

PUBLIC = {"/api/billing/plans", "/api/billing/apple/notifications", "/api/billing/stripe/webhook"}


def _user(request: Request) -> dict:
    u = getattr(request.state, "user", None)
    if not u:
        raise HTTPException(401, {"detail": "Anmeldung erforderlich.", "code": "unauthenticated"})
    return u


def _hosted() -> None:
    if not config.is_hosted():
        raise HTTPException(501, {"detail": "Abos gibt es nur mit StudiNow-Konto im Dienst; auf dem eigenen PC ist alles frei.",
                                  "code": "not_hosted"})


def purchase_channels() -> dict:
    """Wo man einen Tarif abschliessen kann. Nur, was es technisch gibt."""
    return {
        "apple": {"available": True, "note": "Abschluss, Wechsel, Kündigung und Wiederherstellen in der iPad-/Mac-App "
                                             "über den App Store."},
        "web": {"available": stripe_billing.available(),
                "note": ("Abschluss, Wechsel und Kündigung im Web und unter Windows über Stripe. Ein Abo aus der Apple-App gilt "
                         "hier automatisch, sobald du mit demselben StudiNow-Konto angemeldet bist.") if stripe_billing.available() else
                        ("Im Web und unter Windows gibt es noch keinen Abschluss. Ein Abo aus der Apple-App gilt hier "
                         "automatisch, sobald du mit demselben StudiNow-Konto angemeldet bist."),
                "plans": sorted(stripe_billing.prices(), key=plans.rank),
                # jaehrliche Zahlung je Tarif, sobald der Jahrespreis in LERNAPP_STRIPE_PRICES steht (08.11.2026)
                "yearly_plans": sorted(stripe_billing.yearly_prices(), key=plans.rank), "intervals": list(stripe_billing.INTERVALS)},
        "android": {"available": False, "note": "Die Android-App ist pausiert."},
    }


@router.get("/api/billing/plans")
def billing_plans():
    purchase = purchase_channels()
    if not config.is_hosted():
        from . import account_mode
        if account_mode.required():
            purchase = account_mode.cached_purchase() or purchase   # Windows-App: Kaufwege des Dienstes
    return {**plans.contract(), "purchase": purchase, "studora_ai_configured": _ai_configured()}


def _ai_configured() -> bool:
    from . import ai_backend
    return ai_backend.available()


@router.get("/api/entitlements")
def get_entitlements(request: Request):
    """Eigener Stand. Die Apps richten danach ihre Oberflaeche aus; der Server prueft trotzdem jeden Aufruf.
    `access` (05.11.2026, app/access.py): Abo-Pflicht je Client; fuer iPad/Android ("app") nur zur Information."""
    out = entitlements.status(request)
    out["purchase"] = purchase_channels()
    if config.is_hosted():
        from . import access, ai_backend
        u = _user(request)
        out["apple_account_token"] = apple_store.account_token(u["id"])
        # Credits des Monats (app/credits.py): period, allowance, used, reserved, remaining, resets_at, plan
        out["credits"] = ai_backend.credits_balance(u["id"])
        out["access"] = access.for_status(out, access.client_type(request), u.get("role"))
    else:
        from . import account_mode
        if account_mode.required():
            # Windows-App: Kaufwege so, wie der Dienst sie zuletzt gemeldet hat (Stripe ist nur dort eingerichtet)
            out["purchase"] = account_mode.cached_purchase() or out["purchase"]
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


# ---------------------------------------------------------------- Stripe (Web, Windows) und Tarifwahl nach der Probe

def _stripe_call(fn):
    conn = billing.connect()
    try:
        return fn(conn)
    except (stripe_billing.StripeError, billing.BillingError) as e:
        raise HTTPException(e.status, {"detail": e.message, "code": e.code})
    finally:
        conn.close()


@router.post("/api/billing/stripe/checkout")
def stripe_checkout(request: Request, body: dict = Body(...)):
    """Abschluss im Web: liefert die Checkout-Adresse von Stripe; den Tarif setzt erst der Webhook."""
    _hosted()
    u = _user(request)
    plan = str(body.get("plan") or "")
    if not plans.is_sellable(plan):
        raise HTTPException(400, {"detail": "Bitte einen kostenpflichtigen Tarif angeben.", "code": "plan_invalid"})
    client = "windows" if body.get("client") == "windows" else None
    interval = _interval(body)
    return _stripe_call(lambda conn: stripe_billing.checkout(conn, u, plan, client, interval))


def _interval(body: dict) -> str:
    """Zahlungszeitraum aus dem Body: month (Standard) oder year; sonst 400."""
    interval = str(body.get("interval") or "month").strip().lower()
    if interval not in stripe_billing.INTERVALS:
        raise HTTPException(400, {"detail": "Zahlungszeitraum: month oder year.", "code": "interval_invalid"})
    return interval


@router.post("/api/billing/stripe/portal")
def stripe_portal(request: Request, body: dict | None = Body(default=None)):
    _hosted()
    u = _user(request)
    client = "windows" if isinstance(body, dict) and body.get("client") == "windows" else None
    return _stripe_call(lambda conn: stripe_billing.portal(conn, u, client))


@router.post("/api/billing/stripe/webhook")
async def stripe_webhook(request: Request):
    """Oeffentlich; die Signatur im Kopf Stripe-Signature ersetzt die Sitzung."""
    _hosted()
    payload = await request.body()
    sig = request.headers.get("stripe-signature")
    return _stripe_call(lambda conn: stripe_billing.handle_event(conn, payload, sig))


@router.post("/api/billing/plan-choice")
def plan_choice(request: Request, body: dict = Body(...)):
    """Antwort auf die Aufforderung nach der Probe: free merken; einen bezahlten Tarif merken und, wenn Stripe
    eingerichtet ist, gleich die Checkout-Adresse liefern (sonst Hinweis auf die Apple-App)."""
    _hosted()
    u = _user(request)
    plan = str(body.get("plan") or "")
    if plan not in plans.ORDER:
        raise HTTPException(400, {"detail": "Unbekannter Tarif.", "code": "plan_invalid"})
    interval = _interval(body)
    conn = billing.connect()
    try:
        billing.record_plan_choice(conn, u["id"], plan)
        out = {"plan": plan, "checkout_url": None, "interval": interval}
        if plan != "free" and stripe_billing.available():
            try:
                out["checkout_url"] = stripe_billing.checkout(conn, u, plan, interval=interval)["url"]
            except stripe_billing.StripeError as e:
                out["checkout_error"] = e.message
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


@router.get("/api/billing/ai-costs")
def ai_costs(request: Request, days: int = 31):
    """Kostenansicht des Betriebs (Admin): credit_ledger je Tag (Berlin) und Modell, dazu der laufende Monat und die
    Preistabelle (app/credits.py admin_costs)."""
    _hosted()
    if _user(request).get("role") != "admin":
        raise HTTPException(403, {"detail": "Nur für den Betrieb.", "code": "admin_required"})
    from . import ai_backend, credits
    conn = ai_backend.connect()
    try:
        return credits.admin_costs(conn, days)
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
        # Produktregel: in der Oberflaeche ab Pro AI angeboten. Die Kontingentnutzung selbst haengt nicht am Tarif,
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
    die Oberflaeche fragt danach den Stand ab. Body: `new_account` (anderes Konto = neue Registrierung), `reconsent`
    (Freigabe der Abo-Nutzung nachholen). Im Dienst 503, solange OpenAI nicht freigegeben hat."""
    cg = _chatgpt_local()
    b = body if isinstance(body, dict) else {}
    open_browser = b.get("open_browser") is not False
    return _chatgpt_call(lambda: cg.start(open_browser=open_browser, new_account=bool(b.get("new_account")), reconsent=bool(b.get("reconsent"))))


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
