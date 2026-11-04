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
    assert st == 200 and d["trial"] == {"days": 7, "plan": "pro_ai", "credits": 25} and d["purchase"]["web"]["available"] is False


# ================================================================ Stripe

@pytest.fixture
def stripe(monkeypatch):
    """Stripe eingerichtet, HTTP als Attrappe: alle Aufrufe werden mitgeschrieben, Antworten kommen aus `answers`."""
    from app import stripe_billing as sb
    monkeypatch.setenv("LERNAPP_STRIPE_SECRET_KEY", "sk_test_x")
    monkeypatch.setenv("LERNAPP_STRIPE_WEBHOOK_SECRET", "whsec_test")
    monkeypatch.setenv("LERNAPP_STRIPE_PRICES", "plus=price_plus, pro_connect=price_pc ,pro_ai=price_ai,free=price_nein,quatsch=price_x")
    monkeypatch.setenv("LERNAPP_PUBLIC_URL", "https://app.studinow.example/")
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


def event(eid, etype, obj, secret="whsec_test", t=None, created=None):
    """Signiertes Ereignis; `created` (Stripe setzt es immer) ist standardmaessig jetzt."""
    payload = json.dumps({"id": eid, "type": etype, "created": int(created if created is not None else time.time()),
                          "data": {"object": obj}}).encode()
    t = int(t if t is not None else time.time())
    sig = hmac.new(secret.encode(), f"{t}.".encode() + payload, hashlib.sha256).hexdigest()
    return payload, f"t={t},v1={sig}"


def webhook(app, payload, sig):
    return _j(asgi_call(app, "POST", "/api/billing/stripe/webhook", body=payload, headers={"Stripe-Signature": sig} if sig else None))


def test_prices_and_channels(hosted, stripe):
    sb = stripe.module
    assert sb.prices() == {"plus": "price_plus", "pro_ai": "price_ai"}, "nur kaufbare, bekannte Tarife (Pro Connect gibt es nicht mehr)"
    assert sb.plan_for_price("price_ai") == "pro_ai" and sb.plan_for_price("price_nein") is None and sb.available()
    st, d = _j(asgi_call(hosted, "GET", "/api/billing/plans"))
    assert d["purchase"]["web"]["available"] is True and d["purchase"]["web"]["plans"] == ["plus", "pro_ai"]
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
    assert sess["success_url"] == "https://app.studinow.example/#/abo?checkout=success" and sess["cancel_url"].endswith("checkout=cancel")
    # zweiter Checkout: Kunde wird nicht noch einmal angelegt; Tarif bleibt bis zum Webhook unveraendert
    _j(asgi_call(hosted, "POST", "/api/billing/stripe/checkout", headers=h, body=json.dumps({"plan": "pro_ai"})))
    assert len([c for c in stripe.calls if c[1] == "/customers"]) == 1
    assert ent(hosted, h)["source"] == "trial"
    for bad in ({"plan": "free"}, {"plan": "gold"}, {}):
        st, d = _j(asgi_call(hosted, "POST", "/api/billing/stripe/checkout", headers=h, body=json.dumps(bad)))
        assert st == 400 and d["code"] == "plan_invalid"
    assert asgi_call(hosted, "POST", "/api/billing/stripe/checkout", body=json.dumps({"plan": "plus"}))[0] == 401
    # Tarifwahl nach der Probe mit bezahltem Tarif: Antwort gemerkt und gleich die Checkout-Adresse
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/plan-choice", headers=h, body=json.dumps({"plan": "pro_ai"})))
    assert st == 200 and d["checkout_url"] == "https://checkout.stripe.com/c/cs_1" and d["entitlements"]["plan_choice"] == "pro_ai"
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/plan-choice", headers=h, body=json.dumps({"plan": "pro_connect"})))
    assert (st, d["code"]) == (400, "plan_invalid"), "Pro Connect ist nicht mehr waehlbar"


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


def schedule(sid="sub_sched_1", sub="sub_1", next_price="price_plus", cur_end=None, phases=None):
    """Subscription Schedule wie von GET /subscription_schedules/{id}: laufende Phase bis `cur_end`, dann `next_price`."""
    cur_end = cur_end if cur_end is not None else int(time.time()) + 30 * 86400
    if phases is None:
        phases = [{"start_date": cur_end - 30 * 86400, "end_date": cur_end, "items": [{"price": "price_ai", "quantity": 1}]},
                  {"start_date": cur_end, "end_date": cur_end + 30 * 86400, "items": [{"price": next_price, "quantity": 1}]}]
    return {"id": sid, "object": "subscription_schedule", "subscription": sub, "status": "active",
            "current_phase": {"start_date": phases[0]["start_date"], "end_date": phases[0]["end_date"]}, "phases": phases}


def test_portal_downgrade_is_scheduled_to_the_period_end(hosted, stripe):
    """Downgrade im Kundenportal: Stripe haengt einen Subscription Schedule an, die naechste Phase traegt den kleineren
    Preis -> Tarif bleibt, `pending_plan` zeigt den Wechsel (wie Apple `autoRenewProductId`). Wirkt der Wechsel, kommt
    `customer.subscription.updated` mit dem neuen Preis und ohne Schedule -> Tarif plus, pending leer."""
    from app import billing
    u, h = register(hosted, "runter@beispiel.de")
    conn = billing.connect(); billing.end_trial(conn, u["id"]); conn.close()
    end = int(time.time()) + 30 * 86400
    payload, sig = event("evt_d1", "customer.subscription.created", subscription(price="price_ai", end=end, meta={"user_id": u["id"]}))
    assert webhook(hosted, payload, sig)[1]["pending_plan"] is None
    # Portal: Wechsel auf Plus zum Periodenende -> Abo traegt die Schedule-ID
    stripe.answers["/subscription_schedules/sub_sched_1"] = schedule(next_price="price_plus", cur_end=end)
    sub = {**subscription(price="price_ai", end=end, meta={"user_id": u["id"]}), "schedule": "sub_sched_1"}
    payload, sig = event("evt_d2", "customer.subscription.updated", sub)
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["applied"] and d["plan"] == "pro_ai" and d["pending_plan"] == "plus", d
    assert ("GET", "/subscription_schedules/sub_sched_1", None, None) in stripe.calls
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai" and e["source"] == "stripe" and e["pending_plan"] == "plus" and e["will_renew"] is True
    assert e["entitlements"]["can_use_ai_explanations"], "bis zum Periodenende gilt der alte Tarif"
    # eingebetteter Schedule (expand) geht ohne weiteren Aufruf
    before = len(stripe.calls)
    sub2 = {**sub, "schedule": schedule(next_price="price_plus", cur_end=end)}
    payload, sig = event("evt_d3", "customer.subscription.updated", sub2)
    assert webhook(hosted, payload, sig)[1]["pending_plan"] == "plus" and len(stripe.calls) == before
    # Periodenende: Stripe stellt den Posten um, der Schedule ist abgeschlossen/abgehaengt
    payload, sig = event("evt_d4", "customer.subscription.updated", subscription(price="price_plus", end=end + 30 * 86400, meta={"user_id": u["id"]}))
    d = webhook(hosted, payload, sig)[1]
    assert d["plan"] == "plus" and d["pending_plan"] is None
    e = ent(hosted, h)
    assert e["plan"] == "plus" and e["pending_plan"] is None and not e["entitlements"]["can_use_ai_explanations"]


def test_schedule_without_a_real_change_sets_no_pending_plan(hosted, stripe):
    from app import billing, stripe_billing as sb
    u, h = register(hosted, "gleich@beispiel.de")
    conn = billing.connect(); billing.end_trial(conn, u["id"]); conn.close()
    end = int(time.time()) + 30 * 86400
    base = subscription(price="price_ai", end=end, meta={"user_id": u["id"]})
    # gleicher Preis in der naechsten Phase (z. B. Schedule nur fuer Rabatt/Menge)
    stripe.answers["/subscription_schedules/sub_sched_same"] = schedule(sid="sub_sched_same", next_price="price_ai", cur_end=end)
    payload, sig = event("evt_s1", "customer.subscription.updated", {**base, "schedule": "sub_sched_same"})
    assert webhook(hosted, payload, sig)[1]["pending_plan"] is None
    # unbekannter Preis in der Phase: kein Tarif, kein Fehler
    stripe.answers["/subscription_schedules/sub_sched_x"] = schedule(sid="sub_sched_x", next_price="price_x", cur_end=end)
    payload, sig = event("evt_s2", "customer.subscription.updated", {**base, "schedule": "sub_sched_x"})
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["applied"] and d["plan"] == "pro_ai" and d["pending_plan"] is None
    # Schedule ohne weitere Phase, Phase ohne Posten, Schedule nicht ladbar: ebenso None
    stripe.answers["/subscription_schedules/sub_sched_one"] = schedule(sid="sub_sched_one", cur_end=end, phases=[
        {"start_date": end - 30 * 86400, "end_date": end, "items": [{"price": "price_ai"}]}])
    payload, sig = event("evt_s3", "customer.subscription.updated", {**base, "schedule": "sub_sched_one"})
    assert webhook(hosted, payload, sig)[1]["pending_plan"] is None
    stripe.answers["/subscription_schedules/sub_sched_leer"] = schedule(sid="sub_sched_leer", cur_end=end, phases=[
        {"start_date": end - 30 * 86400, "end_date": end, "items": [{"price": "price_ai"}]}, {"start_date": end, "items": []}])
    payload, sig = event("evt_s4", "customer.subscription.updated", {**base, "schedule": "sub_sched_leer"})
    assert webhook(hosted, payload, sig)[1]["pending_plan"] is None

    def failing_get(path):
        raise sb.StripeError("stripe_error", "Stripe antwortete mit Fehler 404", 502)
    stripe.module.http_get = failing_get
    payload, sig = event("evt_s5", "customer.subscription.updated", {**base, "schedule": "sub_sched_weg"})
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["applied"] and d["pending_plan"] is None
    assert ent(hosted, h)["plan"] == "pro_ai" and ent(hosted, h)["pending_plan"] is None
    # ohne current_phase zaehlt die erste Phase, die nach jetzt beginnt; Phasen in der Vergangenheit nicht
    now = dt.datetime.now(UTC)
    sched = {"phases": [{"start_date": end - 60 * 86400, "items": [{"price": "price_ai"}]},
                        {"start_date": end + 10, "items": [{"price": {"id": "price_plus"}}]}]}
    assert sb.pending_plan_for({"schedule": sched}, "pro_ai", now) == "plus"
    assert sb.pending_plan_for({"schedule": None}, "pro_ai", now) is None
    assert sb.pending_plan_for({"schedule": {"id": "sub_sched_weg"}}, "pro_ai", now) is None, "Objekt ohne Phasen -> nachladen -> Fehler -> None"


def test_schedule_events_reload_the_subscription(hosted, stripe):
    """subscription_schedule.updated/released/canceled tragen nur den Schedule; das Abo wird geladen und frisch gesetzt."""
    from app import billing
    u, h = register(hosted, "plan@beispiel.de")
    conn = billing.connect(); billing.end_trial(conn, u["id"]); conn.close()
    end = int(time.time()) + 30 * 86400
    payload, sig = event("evt_e1", "customer.subscription.created", subscription(price="price_ai", end=end, meta={"user_id": u["id"]}))
    assert webhook(hosted, payload, sig)[1]["applied"]
    sched = schedule(next_price="price_plus", cur_end=end)
    stripe.answers["/subscription_schedules/sub_sched_1"] = sched
    stripe.answers["/subscriptions/sub_1"] = {**subscription(price="price_ai", end=end, meta={"user_id": u["id"]}), "schedule": "sub_sched_1"}
    payload, sig = event("evt_e2", "subscription_schedule.updated", sched)
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["applied"] and d["plan"] == "pro_ai" and d["pending_plan"] == "plus", d
    assert ("GET", "/subscriptions/sub_1", None, None) in stripe.calls
    assert ent(hosted, h)["pending_plan"] == "plus"
    # Wechsel im Portal zurueckgenommen: Schedule released, Abo ohne Schedule -> pending leer, Tarif bleibt
    stripe.answers["/subscriptions/sub_1"] = subscription(price="price_ai", end=end, meta={"user_id": u["id"]})
    payload, sig = event("evt_e3", "subscription_schedule.released", {**sched, "status": "released", "released_subscription": "sub_1"})
    d = webhook(hosted, payload, sig)[1]
    assert d["applied"] and d["plan"] == "pro_ai" and d["pending_plan"] is None
    assert ent(hosted, h)["plan"] == "pro_ai" and ent(hosted, h)["pending_plan"] is None
    payload, sig = event("evt_e4", "subscription_schedule.canceled", {**sched, "status": "canceled", "subscription": None})
    assert webhook(hosted, payload, sig)[1] == {"received": True, "type": "subscription_schedule.canceled", "applied": False, "reason": "no_subscription"}
    # Schedule-Ereignis fuer ein Abo ohne zuordenbares Konto: quittiert, nichts gesetzt
    stripe.answers["/subscriptions/sub_f"] = subscription(sid="sub_f", customer="cus_fremd")
    payload, sig = event("evt_e5", "subscription_schedule.updated", schedule(sid="sub_sched_f", sub="sub_f"))
    assert webhook(hosted, payload, sig)[1]["reason"] == "unknown_customer"


def test_immediate_change_in_the_portal_switches_at_once(hosted, stripe):
    """Sofortiger Wechsel (anteilig berechnet): der Posten traegt den neuen Preis, kein Schedule -> Tarif sofort, pending leer."""
    from app import billing
    u, h = register(hosted, "sofort@beispiel.de")
    conn = billing.connect(); billing.end_trial(conn, u["id"]); conn.close()
    end = int(time.time()) + 30 * 86400
    payload, sig = event("evt_u1", "customer.subscription.created", subscription(price="price_plus", end=end, meta={"user_id": u["id"]}))
    assert webhook(hosted, payload, sig)[1]["plan"] == "plus" and ent(hosted, h)["plan"] == "plus"
    payload, sig = event("evt_u2", "customer.subscription.updated", {**subscription(price="price_ai", end=end, meta={"user_id": u["id"]}), "schedule": None})
    d = webhook(hosted, payload, sig)[1]
    assert d["plan"] == "pro_ai" and d["pending_plan"] is None
    e = ent(hosted, h)
    assert e["plan"] == "pro_ai" and e["pending_plan"] is None and e["entitlements"]["can_use_ai_explanations"]
    # sofortiges Downgrade genauso: Preis am Posten entscheidet
    payload, sig = event("evt_u3", "customer.subscription.updated", subscription(price="price_plus", end=end, meta={"user_id": u["id"]}))
    assert webhook(hosted, payload, sig)[1]["plan"] == "plus" and ent(hosted, h)["plan"] == "plus"
    assert not [c for c in stripe.calls if c[0] == "GET"], "ohne Schedule wird nichts nachgeladen"


def test_portal_needs_a_customer(hosted, stripe):
    u, h = register(hosted, "portal@beispiel.de")
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/stripe/portal", headers=h, body="{}"))
    assert st == 404 and d["code"] == "no_subscription"
    _j(asgi_call(hosted, "POST", "/api/billing/stripe/checkout", headers=h, body=json.dumps({"plan": "plus"})))
    st, d = _j(asgi_call(hosted, "POST", "/api/billing/stripe/portal", headers=h, body="{}"))
    assert st == 200 and d["url"] == "https://billing.stripe.com/p/bps_1"
    call = [c for c in stripe.calls if c[1] == "/billing_portal/sessions"][0][2]
    assert call == {"customer": "cus_1", "return_url": "https://app.studinow.example/#/abo"}


def test_local_mode_has_no_stripe(app):
    st, d = _j(asgi_call(app, "POST", "/api/billing/stripe/checkout", body=json.dumps({"plan": "plus"})))
    assert st == 501 and d["code"] == "not_hosted"
    st, d = _j(asgi_call(app, "POST", "/api/billing/stripe/webhook", body="{}"))
    assert st == 501


# ================================================================ Wiederholung nach Fehler, Reihenfolge der Ereignisse

def _event_ids():
    from app import billing
    conn = billing.connect()
    try:
        return [r[0] for r in conn.execute("SELECT id FROM stripe_events")]
    finally:
        conn.close()


def test_failed_processing_leaves_the_event_retryable(hosted, stripe):
    """Schlaegt der Stripe-Abruf beim ersten Zustellen fehl (502), gilt die Ereignis-ID nicht: Stripes Wiederholung wirkt."""
    from app import billing, stripe_billing as sb
    u, h = register(hosted, "wieder@beispiel.de")
    conn = billing.connect(); billing.end_trial(conn, u["id"]); conn.close()
    sess = {"id": "cs_1", "object": "checkout.session", "mode": "subscription", "subscription": "sub_s1", "customer": "cus_1",
            "client_reference_id": u["id"]}

    def failing_get(path):
        raise sb.StripeError("stripe_unreachable", "Stripe ist nicht erreichbar.", 502)
    stripe.module.http_get = failing_get
    payload, sig = event("evt_cs_1", "checkout.session.completed", sess)
    st, d = webhook(hosted, payload, sig)
    assert st == 502 and d["code"] == "stripe_unreachable"
    assert _event_ids() == [] and ent(hosted, h)["plan"] == "free"
    stripe.module.http_get = lambda path: subscription(sid="sub_s1", price="price_ai", meta={})
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["applied"] and not d.get("duplicate") and ent(hosted, h)["plan"] == "pro_ai"
    assert _event_ids() == ["evt_cs_1"]
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["duplicate"] is True


def test_database_error_rolls_back_event_id_and_entitlement(hosted, stripe, monkeypatch):
    """Ein Fehler nach dem Vermerken (hier beim Setzen der Berechtigung) nimmt auch die Ereignis-ID und den Kunden zurueck."""
    from app import billing
    u, h = register(hosted, "rollback@beispiel.de")
    conn = billing.connect(); billing.end_trial(conn, u["id"]); conn.close()
    sess = {"id": "cs_1", "object": "checkout.session", "mode": "subscription", "subscription": "sub_s1", "customer": "cus_1",
            "client_reference_id": u["id"]}
    stripe.answers["/subscriptions/sub_s1"] = subscription(sid="sub_s1", price="price_ai", meta={})
    real = billing.set_entitlement

    def broken(*a, **k):
        raise RuntimeError("database is locked")
    monkeypatch.setattr(billing, "set_entitlement", broken)
    payload, sig = event("evt_cs_2", "checkout.session.completed", sess)
    with pytest.raises(RuntimeError):
        webhook(hosted, payload, sig)
    conn = billing.connect()
    try:
        assert not conn.in_transaction
        assert conn.execute("SELECT COUNT(*) FROM stripe_events").fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM stripe_customers").fetchone()[0] == 0
    finally:
        conn.close()
    monkeypatch.setattr(billing, "set_entitlement", real)
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["applied"] and ent(hosted, h)["plan"] == "pro_ai"


def test_stripe_is_fetched_before_the_write_transaction(hosted, stripe):
    """Kein Stripe-Abruf unter der Schreibsperre: beim Abruf laeuft noch keine Transaktion."""
    from app import billing
    u, h = register(hosted, "sperre@beispiel.de")
    seen = []
    conn = billing.connect()
    try:
        def get(path):
            seen.append(conn.in_transaction)
            return subscription(sid="sub_1", price="price_plus", meta={"user_id": u["id"]}) if path.startswith("/subscriptions/") \
                else schedule(sid="sub_sched_9", next_price="price_ai")
        stripe.module.http_get = get
        sub = {**subscription(sid="sub_1", price="price_plus", meta={"user_id": u["id"]}), "schedule": "sub_sched_9"}
        payload, sig = event("evt_x1", "customer.subscription.updated", sub)
        out = stripe.module.handle_event(conn, payload, sig)
        assert out["applied"] and out["pending_plan"] == "pro_ai"
        sess = {"id": "cs_1", "mode": "subscription", "subscription": "sub_1", "customer": "cus_1", "client_reference_id": u["id"]}
        payload, sig = event("evt_x2", "checkout.session.completed", sess)
        assert stripe.module.handle_event(conn, payload, sig)["applied"]
    finally:
        conn.close()
    assert seen and not any(seen)


def test_older_subscription_event_does_not_overwrite_newer_state(hosted, stripe):
    """Zuerst "geloescht" (neuer), danach ein aelteres "updated" (aktiv): das Abo bleibt beendet."""
    from app import billing
    u, h = register(hosted, "reihe@beispiel.de")
    conn = billing.connect(); billing.end_trial(conn, u["id"]); conn.close()
    end = int(time.time()) + 20 * 86400
    t0 = int(time.time()) - 600
    active = subscription(sid="sub_s2", price="price_ai", status="active", end=end, meta={"user_id": u["id"]})
    canceled = subscription(sid="sub_s2", price="price_ai", status="canceled", end=end, meta={"user_id": u["id"]})
    payload, sig = event("evt_new", "customer.subscription.deleted", canceled, created=t0 + 100)
    assert webhook(hosted, payload, sig)[0] == 200 and ent(hosted, h)["plan"] == "free"
    payload, sig = event("evt_old", "customer.subscription.updated", active, created=t0)
    st, d = webhook(hosted, payload, sig)
    assert st == 200 and d["applied"] is False and d["reason"] == "stale_event"
    assert ent(hosted, h)["plan"] == "free"
    assert "evt_old" in _event_ids(), "das uebersprungene Ereignis zaehlt als erledigt (Wiederholung aendert nichts)"
    # gleicher Zeitstempel wird angewandt; ein spaeteres Ereignis ebenso
    payload, sig = event("evt_same", "customer.subscription.updated", active, created=t0 + 100)
    assert webhook(hosted, payload, sig)[1]["applied"] and ent(hosted, h)["plan"] == "pro_ai"
    payload, sig = event("evt_later", "customer.subscription.deleted", canceled, created=t0 + 200)
    assert webhook(hosted, payload, sig)[1]["applied"] and ent(hosted, h)["plan"] == "free"


def test_stale_downgrade_does_not_overwrite_a_newer_upgrade(hosted, stripe):
    u, h = register(hosted, "hoch@beispiel.de")
    from app import billing
    conn = billing.connect(); billing.end_trial(conn, u["id"]); conn.close()
    t0 = int(time.time()) - 600
    meta = {"user_id": u["id"]}
    up = subscription(sid="sub_u", price="price_ai", meta=meta)
    down = subscription(sid="sub_u", price="price_plus", meta=meta)
    payload, sig = event("evt_up", "customer.subscription.updated", up, created=t0 + 50)
    assert webhook(hosted, payload, sig)[1]["plan"] == "pro_ai"
    payload, sig = event("evt_down", "customer.subscription.updated", down, created=t0)
    assert webhook(hosted, payload, sig)[1]["reason"] == "stale_event"
    assert ent(hosted, h)["plan"] == "pro_ai"


def test_event_order_is_tracked_per_subscription(hosted, stripe):
    """Der gemerkte Zeitstempel gilt je (Konto, Abo): ein anderes Abo desselben Kontos ist unabhaengig."""
    from app import billing
    u, h = register(hosted, "zwei-abos@beispiel.de")
    conn = billing.connect(); billing.end_trial(conn, u["id"]); conn.close()
    t0 = int(time.time()) - 600
    meta = {"user_id": u["id"]}
    payload, sig = event("evt_a", "customer.subscription.updated", subscription(sid="sub_a", price="price_plus", meta=meta), created=t0 + 100)
    assert webhook(hosted, payload, sig)[1]["applied"]
    payload, sig = event("evt_b", "customer.subscription.updated", subscription(sid="sub_b", price="price_plus", meta=meta), created=t0)
    st, d = webhook(hosted, payload, sig)
    assert d["applied"] is True and d.get("reason") != "stale_event"
    conn = billing.connect()
    try:
        rows = dict(conn.execute("SELECT subscription_id, event_created FROM stripe_subscription_state WHERE user_id=?", (u["id"],)).fetchall())
    finally:
        conn.close()
    assert rows == {"sub_a": t0 + 100, "sub_b": t0}
