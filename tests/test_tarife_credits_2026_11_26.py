"""Neues Tarifmodell (Entscheidung des Inhabers vom 26.11.2026, docs/TARIFE-CREDITS-2026-11-26.md).

Free; Plus 1,99 EUR im Monat oder 39,99 EUR einmalig fuer 5 Jahre mit allen Funktionen ohne KI; Pro AI 39,99 EUR im Jahr
mit 120 Credits je Monat. Die StudiNow-KI geht nur mit Credits ("Zusammenfassungen ohne Credits sollen nie klappen"),
Free kann keine Credits kaufen, die Probe ist 7 Tage Plus mit 25 Credits."""
import datetime as dt
import uuid
from datetime import UTC, datetime

from test_credit_packs import GROSS, buy, pack_tx
from test_credits import ask, cheap_calls, credits_of
from test_subscriptions import FakeAI, apple, ent, hosted, user, verify  # noqa: F401 (Fixtures)

FUENF = "de.uniflow.plus.fuenfjahre"


def once_tx(signer, user_id, bought: datetime, otid="9100000000000001", revoked=False, environment="Production"):
    """Signierte Transaktion des 5-Jahres-Kaufs wie von StoreKit 2: nicht verlaengernd, ohne expiresDate."""
    signer.seq += 1
    ms = lambda d: int(d.timestamp() * 1000)
    p = {"transactionId": otid, "originalTransactionId": otid, "productId": FUENF, "bundleId": "de.uniflow.ai",
         "type": "Non-Renewing Subscription", "purchaseDate": ms(bought), "environment": environment,
         "signedDate": ms(dt.datetime.now(UTC)) + signer.seq, "appAccountToken": str(uuid.UUID(hex=user_id))}
    if revoked:
        p["revocationDate"] = ms(dt.datetime.now(UTC))
    return signer.sign(p)


def test_contract_has_the_new_offers_and_rights():
    from app import plans
    assert plans.PLANS["plus"]["price_cents"] == 199 and plans.PLANS["plus"]["period"] == "month"
    assert plans.PLANS["plus"]["apple_product_id"] == "de.uniflow.plus.monthly"
    assert plans.PLANS["pro_ai"]["price_cents"] == 3999 and plans.PLANS["pro_ai"]["period"] == "year"
    assert plans.CREDITS == {"free": 0, "plus": 0, "pro_ai": 120, "trial": 25}
    assert [o["product_id"] for o in plans.contract()["offers"]] == ["de.uniflow.plus.monthly", "de.uniflow.proai.monthly",
                                                                     "de.uniflow.proai.yearly", FUENF]
    o = plans.OFFERS[FUENF]
    assert (o["plan"], o["kind"], o["price_cents"], o["years"], o["label"]) == ("plus", "non_renewing", 3999, 5,
                                                                                "39,99 € einmalig für 5 Jahre")
    assert [plans.is_sellable(p) for p in ("free", "plus", "pro_ai", "pro_connect")] == [False, True, True, False]
    # frueher verkaufte Produkte gelten weiter
    assert plans.plan_for_product("de.uniflow.plus.yearly") == "plus" and plans.plan_for_product("de.uniflow.proai.monthly") == "pro_ai"
    assert plans.plan_for_product(FUENF) == "plus"
    # nichts mehr "ab Pro AI": Plus hat jedes Recht, die KI-Rechte nur mit Credits
    assert all(e["from"] in ("free", "plus") for e in plans.ENTITLEMENTS.values())
    ai = {k for k, e in plans.ENTITLEMENTS.items() if e.get("needs_credits")}
    assert ai == {"can_generate_studora_ai_tests", "can_use_ai_chat", "can_use_ai_explanations", "can_use_ai_generated_questions",
                  "can_use_ai_summaries", "can_use_ai_recommendations", "can_use_prepared_week_sets"}
    assert plans.has("plus", "can_sync_annotations") and plans.has("plus", "can_use_due_reminders")
    assert plans.TRIAL == {"days": 7, "plan": "plus"}
    # Credits kaufen: bezahltes Plus und Pro AI, nie Free, nie die Probe allein; mit Plus gelten sie fuer ALLES
    assert [plans.can_buy_credits(p) for p in ("free", "plus", "pro_ai")] == [False, True, True]
    assert plans.can_buy_credits("plus", trial_only=True) is False
    assert plans.purchased_credits_scope("plus") == "all" and plans.purchased_credits_scope("free") == "none"


def test_five_years_end_on_the_same_day_and_leap_day():
    from app import plans
    assert plans.offer_end(FUENF, datetime(2026, 11, 26, 10, 0, tzinfo=UTC)) == datetime(2031, 11, 26, 10, 0, tzinfo=UTC)
    assert plans.offer_end(FUENF, datetime(2028, 2, 29, tzinfo=UTC)) == datetime(2033, 2, 28, tzinfo=UTC)
    assert plans.offer_end("de.uniflow.plus.monthly", datetime(2026, 1, 1, tzinfo=UTC)) is None


def test_plus_without_credits_gets_no_studinow_ai_not_even_a_summary(hosted, monkeypatch):
    from app import ai_backend
    cheap_calls(monkeypatch)
    fake = FakeAI()
    ai_backend.set_provider(fake)
    _, h = user(hosted, "plus-ohne@beispiel.de", plan="plus")
    c = credits_of(hosted, h)
    assert (c["allowance"], c["available"], c["can_buy"], c["purchased_scope"]) == (0, 0, True, "all")
    for mode in ("explain", "summary"):
        st, d = ask(hosted, h, "Seite 1", f"r-{mode}", mode=mode)
        assert (st, d["code"]) == (429, "credits_exhausted"), (mode, d)
        assert d["credits"]["can_buy"] is True and d["credits"]["available"] == 0, d
    assert fake.calls == 0, "ohne Credits kein einziger KI-Aufruf"
    # alles ohne KI hat Plus (frueher Pro AI)
    e = ent(hosted, h)["entitlements"]
    assert e["can_sync_annotations"] and e["can_use_due_reminders"] and e["can_use_extended_test_history"]


def test_plus_with_bought_credits_uses_all_ai_features(hosted, apple, monkeypatch):
    from app import ai_backend
    cheap_calls(monkeypatch)
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "500")
    fake = FakeAI()
    ai_backend.set_provider(fake)
    u, h = user(hosted, "plus-mit@beispiel.de", plan="plus")
    st, d = buy(hosted, h, pack_tx(apple, u["id"], GROSS, "7900000000000001"))
    assert st == 200 and d["credits_added"] == 160, d
    st, d = ask(hosted, h, "Seite 1", "e1")
    assert st == 200 and d["credits"]["charged"] > 0, d
    assert fake.calls == 1


def test_free_cannot_buy_credits_and_gets_no_ai(hosted, apple, monkeypatch):
    from app import ai_backend
    cheap_calls(monkeypatch)
    ai_backend.set_provider(FakeAI())
    u, h = user(hosted, "free@beispiel.de")
    c = credits_of(hosted, h)
    assert c["can_buy"] is False and c["purchased_scope"] == "none", "die App zeigt Free keinen Kauf"
    # kommt trotzdem ein bezahlter Apple-Kauf an (z. B. vor dem Herabstufen gekauft), wird er verbucht, ruht aber
    st, d = buy(hosted, h, pack_tx(apple, u["id"], GROSS, "7900000000000002"))
    assert st == 200 and d["credits"]["purchased_usable"] is False and d["credits"]["available"] == 0, d
    st, d = ask(hosted, h, "Seite 1", "f1")
    assert st == 403 and d["code"] == "plan_required", d


def test_pro_ai_has_120_credits_each_month(hosted, monkeypatch):
    monkeypatch.delenv("LERNAPP_CREDITS_PRO_AI", raising=False)
    _, h = user(hosted, "pro@beispiel.de", plan="pro_ai")
    c = credits_of(hosted, h)
    assert (c["allowance"], c["available"], c["can_buy"]) == (120, 120, True)


def test_five_year_purchase_counts_five_years_then_ends(hosted, apple):
    from app import billing
    u, h = user(hosted, "fuenf@beispiel.de")
    bought = datetime.now(UTC) - dt.timedelta(days=10)
    st, d = verify(hosted, h, once_tx(apple, u["id"], bought))
    assert st == 200, d
    me = ent(hosted, h)
    assert me["plan"] == "plus" and me["will_renew"] is False, me
    end = datetime.fromisoformat(me["expires_at"])
    assert end.date() == bought.replace(year=bought.year + 5).date(), me["expires_at"]
    assert me["subscriptions"]["app_store"] is True, "Web und Windows sehen den Kauf bei Apple"
    conn = billing.connect()
    try:
        assert billing.current_plan(conn, u["id"], now=end - dt.timedelta(days=1)) == "plus"
        assert billing.current_plan(conn, u["id"], now=end + dt.timedelta(days=1)) == "free"
        src = conn.execute("SELECT source FROM entitlements WHERE user_id=? AND plan='plus'", (u["id"],)).fetchone()[0]
    finally:
        conn.close()
    assert src == "app_store_once"


def test_five_year_test_purchase_lasts_one_day_only(hosted, apple):
    """Sicherheitspruefung 27.11.2026: ein Testkauf (Sandbox: TestFlight, Pruefung durch Apple) des Pakets kostet kein
    Geld und gab trotzdem Plus fuer 5 Jahre. Jetzt hoechstens ein Tag ab dem Kauf; der echte Kauf bleibt bei 5 Jahren."""
    from app import billing
    u, h = user(hosted, "testkauf@beispiel.de")
    bought = datetime.now(UTC) - dt.timedelta(hours=2)
    st, d = verify(hosted, h, once_tx(apple, u["id"], bought, otid="9100000000000077", environment="Sandbox"))
    assert st == 200, d
    me = ent(hosted, h)
    assert me["plan"] == "plus", "Pruefer und TestFlight sehen, dass der Kauf Plus freischaltet"
    end = datetime.fromisoformat(me["expires_at"])
    assert abs((end - (bought + dt.timedelta(days=1))).total_seconds()) < 5, me["expires_at"]
    conn = billing.connect()
    try:
        assert billing.current_plan(conn, u["id"], now=bought + dt.timedelta(days=2)) == "free"
    finally:
        conn.close()


def test_trial_is_plus_with_25_credits(hosted):
    import json
    from conftest import asgi_call
    from test_subscriptions import _j
    st, d = _j(asgi_call(hosted, "POST", "/api/account/register",
                         body=json.dumps({"email": "probe@beispiel.de", "password": "sehr-geheim-123", "university": "luh"})))
    assert st == 201, d
    h = {"Authorization": f"Bearer {d['token']}"}
    me = ent(hosted, h)
    assert me["plan"] == "plus" and me["trial"]["active"] is True, me
    assert me["credits"]["allowance"] == 25 and me["credits"]["can_buy"] is False


# ---------------------------------------------------------------- 27.11.2026: Pro AI monatlich + Tarifuebersicht

PRO_MONAT = "de.uniflow.proai.monthly"


def test_overview_groups_and_savings_as_the_owner_ordered():
    """Inhaber 27.11.2026: monatlich Free -> Plus 1,99 -> Pro AI 3,99, jaehrlich Pro AI 39,99, ganz stark hervorgehoben
    das "Bachelor+Master-Paket" (Plus 5 Jahre 39,99 einmalig) mit der Ersparnis gegenueber normalem Plus."""
    from app import plans
    c = plans.contract()
    assert [g["key"] for g in c["offer_groups"]] == ["special", "monthly", "yearly"]  # 27.11.: Special nach oben
    by = {o["product_id"]: o for o in c["offers"]}
    assert [(p, by[p]["group"], by[p]["price_cents"]) for p in by] == [
        ("de.uniflow.plus.monthly", "monthly", 199), (PRO_MONAT, "monthly", 399),
        ("de.uniflow.proai.yearly", "yearly", 3999), (FUENF, "special", 3999)]
    paket = by[FUENF]
    assert (paket["name"], paket["badge"], paket["highlight"]) == ("Bachelor+Master-Paket", "Unser Special", True)
    sv = paket["savings"]
    assert (sv["months"], sv["regular_cents"], sv["saved_cents"], sv["saved_percent"], sv["per_month_cents"]) == (60, 11940, 7941, 67, 67)
    assert sv["text"] == "Du sparst 79,41 € (67 %) gegenüber 60 × 1,99 € = 119,40 €" and sv["per_month_text"] == "nur 0,67 € im Monat"
    sy = by["de.uniflow.proai.yearly"]["savings"]
    assert (sy["regular_cents"], sy["saved_cents"], sy["saved_percent"]) == (4788, 789, 16)
    assert by["de.uniflow.plus.monthly"]["savings"] is None and by[PRO_MONAT]["savings"] is None
    assert PRO_MONAT not in plans.LEGACY_PRODUCTS and plans.plan_for_product(PRO_MONAT) == "pro_ai"


def test_pro_ai_monthly_purchase_unlocks_pro_ai_with_120_credits(hosted, apple, monkeypatch):
    from datetime import timedelta
    monkeypatch.delenv("LERNAPP_CREDITS_PRO_AI", raising=False)
    u, h = user(hosted, "pro-monat@beispiel.de")
    st, d = verify(hosted, h, apple.tx(u["id"], PRO_MONAT, datetime.now(UTC) + timedelta(days=30), otid="9200000000000001"))
    assert st == 200, d
    me = ent(hosted, h)
    assert me["plan"] == "pro_ai" and me["will_renew"] is not False, me
    c = credits_of(hosted, h)
    assert (c["allowance"], c["available"]) == (120, 120), c


def test_existing_plus_yearly_subscriptions_keep_plus_but_it_is_not_sold(hosted, apple):
    """Bestehende Jahres-Plus-Abos (19,99 EUR, bis 26.11.2026 verkauft) gelten weiter; angeboten wird das Produkt nicht."""
    from datetime import timedelta
    from app import plans
    u, h = user(hosted, "plus-jahr@beispiel.de")
    st, d = verify(hosted, h, apple.tx(u["id"], "de.uniflow.plus.yearly", datetime.now(UTC) + timedelta(days=200), otid="9200000000000002"))
    assert st == 200, d
    me = ent(hosted, h)
    assert me["plan"] == "plus" and me["entitlements"]["can_sync_annotations"], me
    assert "de.uniflow.plus.yearly" not in plans.OFFERS and plans.plan_for_product("de.uniflow.plus.yearly") == "plus"


def test_refund_of_the_five_year_package_ends_plus_at_once(hosted, apple):
    """Erstattung/Widerruf (REFUND bzw. revocationDate) beendet das Paket sofort, wie bei den Abos."""
    from test_subscriptions import notify
    u, h = user(hosted, "paket-erstattet@beispiel.de")
    bought = datetime.now(UTC) - dt.timedelta(days=3)
    assert verify(hosted, h, once_tx(apple, u["id"], bought, otid="9300000000000001"))[0] == 200
    assert ent(hosted, h)["plan"] == "plus"
    st, d = notify(hosted, apple.notification("REFUND", once_tx(apple, u["id"], bought, otid="9300000000000001", revoked=True)))
    assert st == 200 and d["status"] == "revoked", d
    assert ent(hosted, h)["plan"] == "free"


def test_pro_ai_on_top_of_the_package_and_plus_stays_after_pro_ai_ends(hosted, apple):
    """Inhaber 27.11.2026: "man kann Pro AI dazu kaufen wenn man will, aber man behaelt weiterhin fuer 5 Jahre Plus".
    Tarif = hoechste aktive Quelle: Paket + Pro AI -> Pro AI; Pro AI vorbei -> Plus aus dem Paket bis Kauf + 5 Jahre."""
    from app import billing
    u, h = user(hosted, "paket-und-pro@beispiel.de")
    bought = datetime.now(UTC) - dt.timedelta(days=20)
    assert verify(hosted, h, once_tx(apple, u["id"], bought, otid="9400000000000001"))[0] == 200
    pro_end = datetime.now(UTC) + dt.timedelta(days=10)
    assert verify(hosted, h, apple.tx(u["id"], "de.uniflow.proai.monthly", pro_end, otid="9400000000000002"))[0] == 200
    assert ent(hosted, h)["plan"] == "pro_ai"
    conn = billing.connect()
    try:
        assert billing.current_plan(conn, u["id"], now=pro_end - dt.timedelta(days=1)) == "pro_ai"
        assert billing.current_plan(conn, u["id"], now=pro_end + dt.timedelta(days=1)) == "plus", "Paket laeuft weiter"
        five = bought.replace(year=bought.year + 5)
        assert billing.current_plan(conn, u["id"], now=five - dt.timedelta(days=1)) == "plus"
        assert billing.current_plan(conn, u["id"], now=five + dt.timedelta(days=1)) == "free"
    finally:
        conn.close()
    # Pro AI gekuendigt (EXPIRED-Meldung): Plus aus dem Paket bleibt sofort
    from test_subscriptions import notify
    st, d = notify(hosted, apple.notification("EXPIRED", apple.tx(u["id"], "de.uniflow.proai.monthly", datetime.now(UTC) - dt.timedelta(minutes=1),
                                                                   otid="9400000000000002")))
    assert st == 200, d
    assert ent(hosted, h)["plan"] == "plus"


def test_grading_and_mail_rewrite_cost_credits():
    """Sicherheitspruefung 27.11.2026, Regel des Inhabers "KI nur mit Credits": Test-Bewertung (`test_grading`) und
    Uni-Mail "Mit KI verbessern" (`mail_rewrite`) liefen vorher ohne Abzug - mit Plus und 0 Credits nutzbar."""
    from app import ai_backend
    for purpose in ("test_grading", "mail_rewrite", "weekly_test", "test_generation", "tutor:ask"):
        assert ai_backend.charges_credits(purpose), purpose
