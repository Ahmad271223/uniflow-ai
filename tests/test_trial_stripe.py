"""7-Tage-Probe fuer neue Konten und Stripe fuer Web und Windows (Entscheidung des Inhabers vom 30.10.2026,
docs/PLAN-WEB-ZUERST-2026-10-30.md Stufe D): app/billing.py (trial, plan_choices), app/stripe_billing.py (Checkout,
Portal, Webhook mit Signatur, Ereignisse hoechstens einmal), app/billing_api.py. Ohne Netz: die zwei HTTP-Funktionen von
Stripe sind Attrappen, die Webhook-Signatur wird mit einem Testgeheimnis gerechnet."""
import datetime as dt
import hashlib
import hmac
import json
import time

import pytest
from conftest import asgi_call
from test_subscriptions import _j, ent, hosted, user  # noqa: F401 - Fixture und Helfer wiederverwenden

UTC = dt.timezone.utc


def register(app, email):
    st, d = _j(asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": "sehr-geheim-123", "university": "luh"})))
    assert st == 201, d
    return d["user"], {"Authorization": f"Bearer {d['token']}"}


# ================================================================ Probe

def test_new_account_gets_seven_days_of_everything(hosted):
    from app import billing, plans
    u, h = register(hosted, "neu@beispiel.de")
    e = ent(hosted, h)
    assert e["plan"] == plans.TRIAL["plan"] == "pro_ai" and e["source"] == "trial" and e["will_renew"] is False
    assert e["trial"]["active"] and e["trial"]["granted"] and e["trial"]["days_left"] == 7 and not e["needs_plan_choice"]
    assert e["entitlements"]["can_annotate_pdf"] and e["entitlements"]["can_use_ai_explanations"]
    conn = billing.connect()
    try:
        ends = dt.datetime.fromisoformat(e["trial"]["ends_at"])
        assert 6.99 < (ends - dt.datetime.now(UTC)).total_seconds() / 86400 <= 7.0
        assert billing.current_plan(conn, u["id"], ends - dt.timedelta(seconds=1)) == "pro_ai"
        assert billing.current_plan(conn, u["id"], ends) == "free", "zum Ablauf zurueck auf Free"
        assert billing.start_trial(conn, u["id"]) is None, "nur einmal je Konto"
        later = ends + dt.timedelta(days=1)
        tr = billing.trial_info(conn, u["id"], later)
        assert tr["expired"] and not tr["active"] and tr["days_left"] == 0
        assert billing.needs_plan_choice(conn, u["id"], "free", later), "nach der Probe: Tarif waehlen"
        assert not billing.needs_plan_choice(conn, u["id"], "plus", later), "mit bezahltem Tarif keine Aufforderung"
        billing.record_plan_choice(conn, u["id"], "free")
        assert not billing.needs_plan_choice(conn, u["id"], "free", later), "Antwort gemerkt"
    finally:
        conn.close()


def test_trial_can_be_ended_and_apple_purchase_still_wins(hosted):
    from app import billing
    u, h = register(hosted, "ende@beispiel.de")
    conn = billing.connect()
    try:
        assert billing.end_trial(conn, u["id"]) and not billing.end_trial(conn, u["id"])
        assert billing.current_plan(conn, u["id"]) == "free"
        assert billing.start_trial(conn, u["id"]) is None, "beendete Probe startet nicht neu"
        billing.set_entitlement(conn, u["id"], "app_store", "plus", original_transaction_id="t1",
                                expires_at=(dt.datetime.now(UTC) + dt.timedelta(days=30)).isoformat())
    finally:
        conn.close()
    e = ent(hosted, h)
    assert e["plan"] == "plus" and e["source"] == "app_store" and e["trial"]["expired"] and not e["needs_plan_choice"]


def test_plan_choice_endpoint(hosted, monkeypatch):
    u, h = register(hosted, "wahl@beispiel.de")
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/plan-choice", headers=h, body=json.dumps({"plan": "free"})))
    assert st == 200 and d["plan"] == "free" and d["checkout_url"] is None and d["entitlements"]["plan_choice"] == "free"
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/plan-choice", headers=h, body=json.dumps({"plan": "gold"})))
    assert st == 400 and d["code"] == "plan_invalid"
    # bezahlter Tarif ohne Stripe: gemerkt, aber keine Checkout-Adresse
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/plan-choice", headers=h, body=json.dumps({"plan": "plus"})))
    assert st == 200 and d["plan"] == "plus" and d["checkout_url"] is None and d["entitlements"]["plan_choice"] == "plus"
    assert asgi_call(hosted, "POST", "/api/billing/plan-choice", body=json.dumps({"plan": "free"}))[0] == 401


def test_plans_contract_names_the_trial(hosted):
    st, d = _j(asgi_call(hosted, "GET", "/api/billing/plans"))
    assert st == 200 and d["trial"] == {"days": 7, "plan": "pro_ai"} and d["purchase"]["web"]["available"] is False


# ================================================================ Stripe

@pytest.fixture
def stripe(monkeypatch):
    """Stripe eingerichtet, HTTP als Attrappe: alle Aufrufe werden mitgeschrieben, Antworten kommen aus `answers`."""
    from app import stripe_billing as sb
    monkeypatch.setenv("LERNAPP_STRIPE_SECRET_KEY", "sk_test_x")
    monkeypatch.setenv("LERNAPP_STRIPE_WEBHOOK_SECRET", "whsec_test")
    monkeypatch.setenv("LERNAPP_STRIPE_PRICES", "plus=price_plus, pro_connect=price_pc ,pro_ai=price_ai,free=price_nein,quatsch=price_x")
    monkeypatch.setenv("LERNAPP_PUBLIC_URL", "https://app.studora.example/")
    calls = []
    answers = {}

    def post(path, fields, idempotency_key=None):
        calls.append(("POST", path, fields, idempotency_key))
        if path == "/customers":
            return {"id": "cus_1", "email": fields["email"]}
        if path == "/checkout/sessions":
            return {"id": "cs_1", "url": "https://checkout.stripe.com/c/cs_1"}
        if path == "/billing_portal/sessions":
            return {"id": "bps_1", "url": "https://billing.stripe.com/p/bps_1"}
        raise AssertionError(path)

    def get(path):
        calls.append(("GET", path, None, None))
        return answers[path]
    monkeypatch.setattr(sb, "http_post_form", post)
    monkeypatch.setattr(sb, "http_get", get)

    class S:
        pass
    s = S(); s.calls = calls; s.answers = answers; s.module = sb
    return s


def subscription(sid="sub_1", price="price_plus", status="active", customer="cus_1", end=None, cancel=False, meta=None, new_api=False):
    end = end if end is not None else int(time.time()) + 30 * 86400
    item = {"id": "si_1", "price": {"id": price}}
    sub = {"id": sid, "object": "subscription", "status": status, "customer": customer, "cancel_at_period_end": cancel,
           "items": {"data": [item]}, "metadata": meta or {}, "livemode": False}
    if new_api:
        item["current_period_end"] = end
    else:
        sub["current_period_end"] = end
    return sub


def event(eid, etype, obj, secret="whsec_test", t=None):
    payload = json.dumps({"id": eid, "type": etype, "data": {"object": obj}}).encode()
    t = int(t if t is not None else time.time())
    sig = hmac.new(secret.encode(), f"{t}.".encode() + payload, hashlib.sha256).hexdigest()
    return payload, f"t={t},v1={sig}"


def webhook(app, payload, sig):
    return _j(asgi_call(app, "POST", "/api/billing/stripe/webhook", body=payload, headers={"Stripe-Signature": sig} if sig else None))


def test_prices_and_channels(hosted, stripe):
    sb = stripe.module
    assert sb.prices() == {"plus": "price_plus", "pro_connect": "price_pc", "pro_ai": "price_ai"}, "nur kaufbare, bekannte Tarife"
    assert sb.plan_for_price("price_ai") == "pro_ai" and sb.plan_for_price("price_nein") is None and sb.available()
    st, d = _j(asgi_call(hosted, "GET", "/api/billing/plans"))
    assert d["purchase"]["web"]["available"] is True and d["purchase"]["web"]["plans"] == ["plus", "pro_connect", "pro_ai"]
    assert "Stripe" in d["purchase"]["web"]["note"]


def test_checkout_creates_customer_once_and_returns_the_url(hosted, stripe):
    u, h = register(hosted, "kauf@beispiel.de")
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/stripe/checkout", headers=h, body=json.dumps({"plan": "plus"})))
    assert st == 200 and d == {"url": "https://checkout.stripe.com/c/cs_1", "session_id": "cs_1", "plan": "plus"}, d
    cust = [c for c in stripe.calls if c[1] == "/customers"]
    assert len(cust) == 1 and cust[0][2] == {"email": "kauf@beispiel.de", "metadata": {"user_id": u["id"]}} and cust[0][3] == f"customer-{u['id']}"
    sess = [c for c in stripe.calls if c[1] == "/checkout/sessions"][0][2]
    assert sess["mode"] == "subscription" and sess["customer"] == "cus_1" and sess["client_reference_id"] == u["id"]
    assert sess["line_items"] == [{"price": "price_plus", "quantity": 1}] and sess["subscription_data"]["metadata"] == {"user_id": u["id"], "plan": "plus"}
    assert sess["success_url"] == "https://app.studora.example/#/abo?checkout=success" and sess["cancel_url"].endswith("checkout=cancel")
    # zweiter Checkout: Kunde wird nicht noch einmal angelegt; Tarif bleibt bis zum Webhook unveraendert
    _j(asgi_call(hosted, "POST", "/api/billing/stripe/checkout", headers=h, body=json.dumps({"plan": "pro_ai"})))
    assert len([c for c in stripe.calls if c[1] == "/customers"]) == 1
    assert ent(hosted, h)["source"] == "trial"
    for bad in ({"plan": "free"}, {"plan": "gold"}, {}):
        st, d = _j(asgi_call(hosted, "POST", "/api/billing/stripe/checkout", headers=h, body=json.dumps(bad)))
        assert st == 400 and d["code"] == "plan_invalid"
    assert asgi_call(hosted, "POST", "/api/billing/stripe/checkout", body=json.dumps({"plan": "plus"}))[0] == 401
    # Tarifwahl nach der Probe mit bezahltem Tarif: Antwort gemerkt und gleich die Checkout-Adresse
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/plan-choice", headers=h, body=json.dumps({"plan": "pro_connect"})))
    assert st == 200 and d["checkout_url"] == "https://checkout.stripe.com/c/cs_1" and d["entitlements"]["plan_choice"] == "pro_connect"


def test_checkout_without_stripe_is_honest(hosted, monkeypatch):
    u, h = register(hosted, "ohne@beispiel.de")
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/stripe/checkout", headers=h, body=json.dumps({"plan": "plus"})))
    assert st == 503 and d["code"] == "stripe_not_configured"
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/stripe/portal", headers=h, body="{}"))
    assert st == 503 and d["code"] == "stripe_not_configured"


def test_flatten_matches_stripes_bracket_form():
    from app import stripe_billing as sb
    assert sb._flatten({"a": 1, "b": {"c": "x", "d": {"e": True}}, "l": [{"price": "p", "quantity": 1}, "s"], "n": None}) == [
        ("a", "1"), ("b[c]", "x"), ("b[d][e]", "true"), ("l[0][price]", "p"), ("l[0][quantity]", "1"), ("l[1]", "s")]


def test_webhook_signature_is_checked(hosted, stripe):
    from app import stripe_billing as sb
    payload, sig = event("evt_sig", "ping", {})
    assert webhook(hosted, payload, None)[0] == 400
    st, d = webhook(hosted, payload, sig.replace("v1=", "v1=0"))
    assert st == 400 and d["code"] == "signature_invalid"
    st, d = webhook(hosted, payload, "t=abc,v1=00")
    assert st == 400 and d["code"] == "signature_invalid"
    old, oldsig = event("evt_alt", "ping", {}, t=time.time() - 400)
    st, d = webhook(hosted, old, oldsig)
    assert st == 400 and d["code"] == "signature_expired"
    payload2, sig2 = event("evt_fremd", "ping", {}, secret="whsec_anders")
    assert webhook(hosted, payload2, sig2)[1]["code"] == "signature_invalid"
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d == {"received": True, "type": "ping", "applied": False, "reason": "ignored"}
    assert webhook(hosted, payload + b" ", sig)[0] == 400, "veraenderter Inhalt"
    with pytest.raises(sb.StripeError):
        sb.verify_signature(b"{}", "t=1,v1=x", secret="")


def test_checkout_completed_sets_the_plan_and_events_count_once(hosted, stripe):
    from app import billing
    u, h = register(hosted, "voll@beispiel.de")
    end = int(time.time()) + 30 * 86400
    stripe.answers["/subscriptions/sub_1"] = subscription(end=end, meta={})
    session = {"id": "cs_1", "object": "checkout.session", "mode": "subscription", "subscription": "sub_1", "customer": "cus_1",
               "client_reference_id": u["id"]}
    payload, sig = event("evt_1", "checkout.session.completed", session)
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["applied"] and d["plan"] == "plus" and d["user_id"] == u["id"] and d["will_renew"] is True, d
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai" and e["source"] == "trial", "die laufende Probe ist hoeher und gilt weiter"
    conn = billing.connect()
    try:
        billing.end_trial(conn, u["id"])
        assert billing.current_plan(conn, u["id"]) == "plus"
        rows = {r["source"]: r for r in billing.entitlement_rows(conn, u["id"])}
        assert rows["stripe"]["original_transaction_id"] == "sub_1" and rows["stripe"]["expires_at"] == dt.datetime.fromtimestamp(end, UTC).replace(microsecond=0).isoformat()
        assert billing.needs_plan_choice(conn, u["id"], "plus") is False
    finally:
        conn.close()
    e = ent(hosted, h)
    assert e["plan"] == "plus" and e["source"] == "stripe" and e["will_renew"] and e["entitlements"]["can_annotate_pdf"]
    # dasselbe Ereignis noch einmal: quittiert, aber nicht erneut verarbeitet
    before = len(stripe.calls)
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["duplicate"] and len(stripe.calls) == before
    # Kunde aus dem Checkout gemerkt: spaetere Ereignisse ohne metadata finden das Konto ueber den Kunden
    upd = subscription(price="price_ai", end=end, cancel=True, new_api=True)
    payload, sig = event("evt_2", "customer.subscription.updated", upd)
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["applied"] and d["plan"] == "pro_ai" and d["will_renew"] is False
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai" and e["will_renew"] is False and e["expires_at"].startswith(dt.datetime.fromtimestamp(end, UTC).strftime("%Y-%m-%d"))
    # Zahlung fehlgeschlagen: billing_retry, Tarif bleibt; geloescht: expired, zurueck auf Free, Notizen bleiben
    payload, sig = event("evt_3", "customer.subscription.updated", subscription(price="price_ai", status="past_due", end=end))
    assert webhook(hosted, payload, sig)[1]["status"] == "billing_retry" and ent(hosted, h)["plan"] == "pro_ai"
    payload, sig = event("evt_4", "customer.subscription.deleted", subscription(price="price_ai", status="canceled", end=end))
    assert webhook(hosted, payload, sig)[1]["status"] == "expired"
    e = ent(hosted, h)
    assert e["plan"] == "free" and e["entitlements"]["can_view_pdf"] and not e["entitlements"]["can_annotate_pdf"]


def test_unknown_price_or_customer_is_acknowledged_but_never_applied(hosted, stripe):
    u, h = register(hosted, "fremd@beispiel.de")
    payload, sig = event("evt_5", "customer.subscription.created", subscription(customer="cus_unbekannt"))
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["applied"] is False and d["reason"] == "unknown_customer"
    payload, sig = event("evt_6", "customer.subscription.created", subscription(price="price_x", meta={"user_id": u["id"]}))
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["applied"] is False and d["reason"] == "unknown_price"
    payload, sig = event("evt_7", "customer.subscription.created", subscription(status="incomplete", meta={"user_id": u["id"]}))
    assert webhook(hosted, payload, sig)[1]["reason"] == "status_incomplete"
    payload, sig = event("evt_8", "checkout.session.completed", {"mode": "payment", "id": "cs_x"})
    assert webhook(hosted, payload, sig)[1]["reason"] == "not_a_subscription"
    assert ent(hosted, h)["source"] == "trial"
    # ein Abo gehoert genau einem Konto
    other, _ = register(hosted, "zwei@beispiel.de")
    payload, sig = event("evt_9", "customer.subscription.created", subscription(sid="sub_9", meta={"user_id": u["id"]}))
    assert webhook(hosted, payload, sig)[1]["applied"]
    payload, sig = event("evt_10", "customer.subscription.created", subscription(sid="sub_9", meta={"user_id": other["id"]}))
    st, d = webhook(hosted, payload, sig)
    assert st == 409 and d["code"] == "subscription_owned_by_other_account"


def test_portal_needs_a_customer(hosted, stripe):
    u, h = register(hosted, "portal@beispiel.de")
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/stripe/portal", headers=h, body="{}"))
    assert st == 404 and d["code"] == "no_subscription"
    _j(asgi_call(hosted, "POST", "/api/billing/stripe/checkout", headers=h, body=json.dumps({"plan": "plus"})))
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/stripe/portal", headers=h, body="{}"))
    assert st == 200 and d["url"] == "https://billing.stripe.com/p/bps_1"
    call = [c for c in stripe.calls if c[1] == "/billing_portal/sessions"][0][2]
    assert call == {"customer": "cus_1", "return_url": "https://app.studora.example/#/abo"}


def test_local_mode_has_no_stripe(app):
    st, d = _j(asgi_call(app, "POST", "/api/billing/stripe/checkout", body=json.dumps({"plan": "plus"})))
    assert st == 501 and d["code"] == "not_hosted"
    st, d = _j(asgi_call(app, "POST", "/api/billing/stripe/webhook", body="{}"))
    assert st == 501
