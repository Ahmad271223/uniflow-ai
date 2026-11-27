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


def once_tx(signer, user_id, bought: datetime, otid="9100000000000001"):
    """Signierte Transaktion des 5-Jahres-Kaufs wie von StoreKit 2: nicht verlaengernd, ohne expiresDate."""
    signer.seq += 1
    ms = lambda d: int(d.timestamp() * 1000)
    return signer.sign({"transactionId": otid, "originalTransactionId": otid, "productId": FUENF, "bundleId": "de.uniflow.ai",
                        "type": "Non-Renewing Subscription", "purchaseDate": ms(bought), "environment": "Sandbox",
                        "signedDate": ms(dt.datetime.now(UTC)) + signer.seq, "appAccountToken": str(uuid.UUID(hex=user_id))})


def test_contract_has_the_new_offers_and_rights():
    from app import plans
    assert plans.PLANS["plus"]["price_cents"] == 199 and plans.PLANS["plus"]["period"] == "month"
    assert plans.PLANS["plus"]["apple_product_id"] == "de.uniflow.plus.monthly"
    assert plans.PLANS["pro_ai"]["price_cents"] == 3999 and plans.PLANS["pro_ai"]["period"] == "year"
    assert plans.CREDITS == {"free": 0, "plus": 0, "pro_ai": 120, "trial": 25}
    assert [o["product_id"] for o in plans.contract()["offers"]] == ["de.uniflow.plus.monthly", FUENF, "de.uniflow.proai.yearly"]
    assert plans.OFFERS[FUENF] == {"plan": "plus", "kind": "non_renewing", "price_cents": 3999, "years": 5,
                                  "label": "39,99 € einmalig für 5 Jahre"}
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
