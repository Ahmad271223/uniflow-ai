"""KI-Credits zum Nachkaufen (Auftrag des Inhabers 15.11.2026, docs/KI-CREDITS-2026-11-15.md): zwei Toepfe je Konto.

Monats-Credits fuellen sich jeden Monat neu bis zum Rahmen des Tarifs, gekaufte Credits verfallen nie; verbraucht werden
zuerst die Monats-Credits. Ein Kauf (App-Store-Verbrauchskauf, signiert) wird genau einmal verbucht, eine Erstattung
zieht nur ab, was von diesem Kauf noch da ist. Das Monats-Budget je Konto blockiert gekaufte Credits nicht, und mehr als
Monats-Credits + gekaufte Credits kann ein Konto nie verbrauchen. Alte Apps sehen die bisherigen Felder unveraendert."""
import datetime as dt
import json
import sqlite3
import threading
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from conftest import asgi_call
from test_ai_abuse import trial_account
from test_api_schemas import check, schema_v2
from test_credits import ask, cheap_calls, credits_of, ledger_conn
from test_subscriptions import IN_30, FakeAI, _j, apple, end_trial, ent, hosted, notify, user, verify  # noqa: F401 (Fixtures)

T0 = datetime(2026, 11, 10, 9, 0, tzinfo=UTC)
KLEIN, GROSS = "de.uniflow.credits.klein", "de.uniflow.credits.gross"
OLD_FIELDS = ("period", "allowance", "used", "reserved", "remaining", "plan", "resets_at", "credit_eur")


def pack_tx(signer, user_id, product=KLEIN, tid="7000000000000001", token=True, revoked=False, environment="Production", **extra):
    """Signierte Transaktion eines Verbrauchskaufs wie von StoreKit 2 (transactionId = originalTransactionId)."""
    signer.seq += 1
    ms = lambda d: int(d.timestamp() * 1000)
    now = dt.datetime.now(UTC)
    p = {"transactionId": tid, "originalTransactionId": tid, "productId": product, "bundleId": "de.uniflow.ai", "type": "Consumable",
         "quantity": 1, "purchaseDate": ms(now), "environment": environment, "signedDate": ms(now) + signer.seq}
    if token:
        p["appAccountToken"] = str(uuid.UUID(hex=user_id))
    if revoked:
        p["revocationDate"] = ms(now)
    p.update(extra)
    return signer.sign(p)


def buy(app, headers, signed):
    return _j(asgi_call(app, "POST", "/api/billing/credits/apple", headers=headers, body=json.dumps({"signed_transaction": signed})))


def give(user_id, credits, tid="t-1", now=None, source="test"):
    """Gekaufte Credits direkt in den Topf (ohne Apple), wie ein anderer Bezahlweg es taete."""
    from app import credits as ledger
    conn = ledger_conn()
    try:
        return ledger.grant_purchase(conn, user_id, source, tid, credits, product_id=KLEIN, now=now)
    finally:
        conn.close()


def wallet(user_id):
    conn = ledger_conn()
    try:
        r = conn.execute("SELECT balance, reserved FROM credit_wallets WHERE user_id=?", (user_id,)).fetchone()
        return tuple(r) if r else (0, 0)
    finally:
        conn.close()


# ---------------------------------------------------------------- Regeln an einer Stelle

def test_pack_sizes_and_buy_rule_live_in_one_place(monkeypatch):
    from app import ai_prices, plans
    assert ai_prices.MICROEUR_PER_CREDIT == 6_500, "1 Credit = 0,65 Cent, ein Kurs fuer alle Credits"
    assert plans.credit_pack_sizes() == {KLEIN: 100, GROSS: 200}
    assert [(p["product_id"], p["credits"], p["price_cents"]) for p in plans.credit_packs()] == [(KLEIN, 100, 199), (GROSS, 200, 399)]
    assert not any(ch.isdigit() for pid in plans.credit_pack_sizes() for ch in pid), "Produkt-IDs ohne Zahl: andere Groesse, gleiche ID"
    # hoechste KI-Kosten je Paket bei vollem Verbrauch: 0,65 EUR und 1,30 EUR
    assert [p["credits"] * ai_prices.MICROEUR_PER_CREDIT / 1_000_000 for p in plans.credit_packs()] == [0.65, 1.3]
    # die Groesse ist eine Einstellung des Dienstes
    monkeypatch.setenv("LERNAPP_CREDIT_PACKS", f"{GROSS}=185, unbekannt=5, {KLEIN}=kaputt")
    assert plans.credit_pack_sizes() == {KLEIN: 100, GROSS: 185}
    assert plans.credit_pack_credits(GROSS) == 185 and plans.credit_pack_credits("de.uniflow.proai.yearly") is None
    # wer kaufen darf: bezahltes Pro AI; die Probe allein nicht; gekaufte Credits sind mit der StudiNow-KI nutzbar
    assert [plans.can_buy_credits(p) for p in ("free", "plus", "pro_ai", "pro_connect", None)] == [False, False, True, True, False]
    assert plans.can_buy_credits("pro_ai", trial_only=True) is False
    assert [plans.can_use_purchased_credits(p) for p in ("free", "plus", "pro_ai", "pro_connect")] == [False, False, True, True]
    monkeypatch.setitem(plans.CREDIT_PACKS, "buy_plans", ("plus", "pro_ai"))
    assert plans.can_buy_credits("plus") is True, "eine Stelle: spaeter duerfen auch andere Tarife kaufen"


# ---------------------------------------------------------------- zwei Toepfe: Monatswechsel, Reihenfolge

def test_month_change_refills_only_the_monthly_pot(hosted):
    from app import credits
    u, _ = user(hosted, "monat@beispiel.de", plan="pro_ai")
    uid = u["id"]
    give(uid, 100, now=T0)
    conn = ledger_conn()
    try:
        # November: 90 Monats-Credits verbraucht, dann eine Anfrage ueber 30: 10 aus dem Monat, 20 aus den gekauften
        credits.reserve(conn, uid, "a", "tutor:explain", 90, now=T0)
        assert credits.settle(conn, uid, "a", 90 * 6_500, now=T0) == 90
        r = credits.reserve(conn, uid, "b", "tutor:explain", 30, now=T0)
        assert (r.reserved, r.purchased) == (30, 20)
        assert credits.settle(conn, uid, "b", 30 * 6_500, now=T0) == 30
        b = credits.balance(conn, uid, now=T0)
        assert (b["allowance"], b["used"], b["remaining"], b["purchased"], b["available"]) == (100, 100, 0, 80, 80)
        # Dezember: der Monatstopf ist wieder voll (hoechstens 100, nichts angespart), die gekauften sind unveraendert
        dec = credits.balance(conn, uid, now=T0 + timedelta(days=30))
        assert (dec["period"], dec["allowance"], dec["used"], dec["remaining"], dec["purchased"], dec["available"]) == ("2026-12", 100, 0, 100, 80, 180)
        # auch ein Jahr spaeter: gekaufte Credits verfallen nie
        later = credits.balance(conn, uid, now=T0 + timedelta(days=400))
        assert (later["remaining"], later["purchased"]) == (100, 80)
        assert credits.wallet_consistent(conn, uid)
    finally:
        conn.close()


def test_monthly_credits_are_spent_before_purchased_ones(hosted):
    from app import credits
    u, _ = user(hosted, "reihenfolge@beispiel.de", plan="pro_ai")
    uid = u["id"]
    give(uid, 50, now=T0)
    conn = ledger_conn()
    try:
        # solange der Monat reicht, bleibt der gekaufte Topf unberuehrt
        r = credits.reserve(conn, uid, "a", "tutor:explain", 40, now=T0)
        assert r.purchased == 0 and wallet(uid) == (50, 0)
        credits.settle(conn, uid, "a", 40 * 6_500, now=T0)
        assert wallet(uid) == (50, 0)
        # die Reservierung nimmt den Rest des Monats (60) und holt den Rest (15) aus den gekauften
        r = credits.reserve(conn, uid, "b", "flashcards", 75, now=T0)
        assert (r.purchased, r.balance["remaining"], r.balance["purchased"], r.balance["available"]) == (15, 0, 35, 35)
        assert wallet(uid) == (50, 15)
        # abgerechnet werden 62: zuerst der Monats-Teil (60), nur 2 aus den gekauften; der Rest der Reservierung ist frei
        assert credits.settle(conn, uid, "b", 62 * 6_500, now=T0) == 62
        b = credits.balance(conn, uid, now=T0)
        assert (b["used"], b["reserved"], b["remaining"], b["purchased"]) == (100, 0, 0, 48)
        assert wallet(uid) == (48, 0)
        row = conn.execute("SELECT reserved, reserved_purchased, charged, charged_purchased, purchased_microeur FROM credit_ledger "
                           "WHERE user_id=? AND request_id='b'", (uid,)).fetchone()
        assert tuple(row) == (75, 15, 62, 2, 2 * 6_500)
        # kostet eine Anfrage weniger als ihr Monats-Teil, zahlen die gekauften nichts
        b = credits.balance(conn, uid, now=T0 + timedelta(days=30))
        credits.reserve(conn, uid, "c", "tutor:explain", 100, now=T0 + timedelta(days=30))
        r = credits.reserve(conn, uid, "d", "tutor:explain", 10, now=T0 + timedelta(days=30))
        assert r.purchased == 10
        assert credits.refund(conn, uid, "d") is True and wallet(uid) == (48, 0), "Fehler ohne Kosten: der gekaufte Teil kommt zurueck"
        assert credits.settle(conn, uid, "c", 5 * 6_500, now=T0 + timedelta(days=30)) == 5
        assert wallet(uid) == (48, 0) and credits.wallet_consistent(conn, uid)
    finally:
        conn.close()


def test_oldest_purchase_is_used_first_and_stale_reservations_free_both_pots(hosted):
    from app import credits
    u, _ = user(hosted, "aeltester@beispiel.de", plan="pro_ai")
    uid = u["id"]
    give(uid, 10, tid="alt", now=T0)
    give(uid, 10, tid="neu", now=T0 + timedelta(minutes=1))
    conn = ledger_conn()
    try:
        credits.reserve(conn, uid, "m", "tutor:explain", 100, now=T0 + timedelta(minutes=2))
        credits.settle(conn, uid, "m", 100 * 6_500, now=T0 + timedelta(minutes=2))
        credits.reserve(conn, uid, "a", "tutor:explain", 14, now=T0 + timedelta(minutes=3))
        credits.settle(conn, uid, "a", 14 * 6_500, now=T0 + timedelta(minutes=3))
        left = dict(conn.execute("SELECT transaction_id, remaining FROM credit_purchases WHERE user_id=?", (uid,)).fetchall())
        assert left == {"alt": 0, "neu": 6}
        # liegengebliebene Reservierung (Prozess abgestuerzt): nach dem Aufraeumen ist auch der gekaufte Teil wieder frei
        credits.reserve(conn, uid, "haengt", "tutor:explain", 4, now=T0 + timedelta(minutes=4))
        assert wallet(uid) == (6, 4)
        b = credits.balance(conn, uid, now=T0 + timedelta(minutes=5 + credits.stale_minutes()))
        assert (b["purchased"], b["reserved"]) == (6, 0) and wallet(uid) == (6, 0)
        assert conn.execute("SELECT state FROM credit_ledger WHERE user_id=? AND request_id='haengt'", (uid,)).fetchone()[0] == "expired"
    finally:
        conn.close()


def test_never_more_than_monthly_plus_purchased(hosted):
    """Kostenkontrolle dicht: reservieren geht nur, solange Monat + gekaufte reichen - auch gleichzeitig."""
    from app import credits
    u, _ = user(hosted, "dicht@beispiel.de", plan="pro_ai")
    uid = u["id"]
    give(uid, 20, now=T0)
    ok, errors = [], []

    def run(i):
        conn = ledger_conn()
        try:
            credits.reserve(conn, uid, f"r{i}", "tutor:explain", 10, now=T0)
            ok.append(i)
        except credits.CreditsError as e:
            errors.append(e.code)
        finally:
            conn.close()
    threads = [threading.Thread(target=run, args=(i,)) for i in range(20)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert len(ok) == 12 and errors == ["credits_exhausted"] * 8, "100 + 20 Credits = genau 12 Anfragen zu 10"
    conn = ledger_conn()
    try:
        for i in ok:
            assert credits.settle(conn, uid, f"r{i}", 999 * 6_500, now=T0) == 10, "nie mehr als reserviert"
        b = credits.balance(conn, uid, now=T0)
        assert (b["used"], b["remaining"], b["purchased"], b["available"]) == (100, 0, 0, 0)
        with pytest.raises(credits.CreditsError) as e:
            credits.reserve(conn, uid, "zuviel", "tutor:explain", 1, now=T0)
        state = e.value.extra["credits"]
        assert (e.value.code, state["remaining"], state["purchased"], state["available"], state["needed"]) == ("credits_exhausted", 0, 0, 0, 1)
        assert wallet(uid) == (0, 0) and credits.wallet_consistent(conn, uid)
    finally:
        conn.close()


# ---------------------------------------------------------------- Kauf: genau einmal, nur echte Kaeufe

def test_purchase_is_booked_exactly_once(hosted, apple):
    u, h = user(hosted, "kauf@beispiel.de", plan="pro_ai")
    signed = pack_tx(apple, u["id"], KLEIN, "7000000000000010")
    st, d = buy(hosted, h, signed)
    assert st == 200, d
    assert (d["status"], d["credits_added"], d["product_id"], d["transaction_id"]) == ("granted", 100, KLEIN, "7000000000000010")
    assert (d["credits"]["purchased"], d["credits"]["available"], d["credits"]["remaining"], d["other_account"]) == (100, 200, 100, False)
    assert check(d, schema_v2("credit-purchase")) == [], "Vertrag der Antwort"
    # dieselbe Meldung noch einmal (die App wiederholt, bis sie eine Antwort hat): nichts aendert sich
    st, d = buy(hosted, h, signed)
    assert (st, d["status"], d["credits_added"], d["credits"]["purchased"]) == (200, "already_granted", 0, 100)
    # dieselbe Transaktion neu signiert (spaeterer Start) und als Mitteilung von Apple: weiter einmal
    assert buy(hosted, h, pack_tx(apple, u["id"], KLEIN, "7000000000000010"))[1]["status"] == "already_granted"
    st, d = notify(hosted, apple.notification("ONE_TIME_CHARGE", pack_tx(apple, u["id"], KLEIN, "7000000000000010")))
    assert st == 200 and d["status"] == "already_granted" and not d["applied"], d
    # ein zweiter Kauf (andere Transaktion) zaehlt dazu; das grosse Paket hat 200
    st, d = buy(hosted, h, pack_tx(apple, u["id"], GROSS, "7000000000000011"))
    assert (st, d["credits_added"], d["credits"]["purchased"]) == (200, 200, 300)
    assert wallet(u["id"]) == (300, 0)


def test_concurrent_reports_of_one_purchase_count_once(hosted, apple):
    u, h = user(hosted, "gleichzeitig@beispiel.de", plan="pro_ai")
    signed = pack_tx(apple, u["id"], GROSS, "7000000000000020")
    results = []

    def run():
        results.append(buy(hosted, h, signed))
    threads = [threading.Thread(target=run) for _ in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert [st for st, _ in results] == [200] * 8, results
    assert sorted(d["status"] for _, d in results) == ["already_granted"] * 7 + ["granted"]
    assert sum(d["credits_added"] for _, d in results) == 200 and wallet(u["id"]) == (200, 0)


def test_apple_server_notification_books_a_purchase_the_app_never_reported(hosted, apple):
    u, h = user(hosted, "nurapple@beispiel.de", plan="pro_ai")
    note = apple.notification("ONE_TIME_CHARGE", pack_tx(apple, u["id"], KLEIN, "7000000000000030"))
    st, d = notify(hosted, note)
    assert st == 200 and d["applied"] and (d["status"], d["credits_added"]) == ("granted", 100), d
    assert notify(hosted, note)[1]["duplicate"], "gleiche Mitteilung zaehlt einmal"
    assert credits_of(hosted, h)["purchased"] == 100
    # die App meldet danach denselben Kauf: schon verbucht, sie darf abschliessen
    assert buy(hosted, h, pack_tx(apple, u["id"], KLEIN, "7000000000000030"))[1]["status"] == "already_granted"
    # ohne Konto (kein Token, nie gemeldet): 404, Apple versucht es spaeter erneut, nichts wird vermerkt
    st, d = notify(hosted, apple.notification("ONE_TIME_CHARGE", pack_tx(apple, u["id"], KLEIN, "7000000000000031", token=False)))
    assert (st, d["code"]) == (404, "unknown_account")


def test_forged_and_foreign_transactions_are_rejected(hosted, apple, tmp_path):
    from test_subscriptions import AppleSigner
    u, h = user(hosted, "echt@beispiel.de", plan="pro_ai")
    v, hv = user(hosted, "fremd@beispiel.de", plan="pro_ai")
    # gefaelscht: andere Zertifikatskette, veraenderte Nutzdaten, falsche App, unbekanntes Produkt, ohne Anmeldung
    forged = pack_tx(AppleSigner(tmp_path / "x") if (tmp_path / "x").mkdir() is None else None, u["id"], KLEIN, "7000000000000040")
    assert buy(hosted, h, forged)[1]["code"] == "jws_untrusted"
    good = pack_tx(apple, u["id"], KLEIN, "7000000000000041")
    head, body, sig = good.split(".")
    assert buy(hosted, h, f"{head}.{body[:-4]}AAAA.{sig}")[0] == 400
    assert buy(hosted, h, pack_tx(apple, u["id"], KLEIN, "7000000000000042", bundleId="de.andere.app"))[1]["code"] == "wrong_app"
    assert buy(hosted, h, pack_tx(apple, u["id"], "de.uniflow.credits.riesig", "7000000000000043"))[1]["code"] == "unknown_product"
    assert buy(hosted, h, pack_tx(apple, u["id"], "de.uniflow.proai.yearly", "7000000000000044"))[1]["code"] == "unknown_product"
    assert buy(hosted, h, "kein.jws")[1]["code"] == "jws_invalid" and buy(hosted, h, "")[1]["code"] == "jws_invalid"
    assert asgi_call(hosted, "POST", "/api/billing/credits/apple", body=json.dumps({"signed_transaction": good}))[0] == 401
    assert wallet(u["id"]) == (0, 0) and wallet(v["id"]) == (0, 0)
    # fremd: der Kauf von U (appAccountToken) kann V nichts gutschreiben - die Credits gehen an U, wer immer ihn meldet
    st, d = buy(hosted, hv, good)
    assert st == 200 and d["other_account"] is True and d["credits"]["purchased"] == 0, d
    assert wallet(u["id"]) == (100, 0) and wallet(v["id"]) == (0, 0)
    # und ein schon verbuchter Kauf wechselt nie das Konto, auch nicht ohne Token
    st, d = buy(hosted, hv, pack_tx(apple, v["id"], KLEIN, "7000000000000041", token=False))
    assert (d["status"], d["credits_added"], d["other_account"]) == ("already_granted", 0, True)
    assert wallet(v["id"]) == (0, 0)


def test_without_apple_root_the_service_answers_honestly(hosted, apple, monkeypatch):
    u, h = user(hosted, "ohnewurzel@beispiel.de", plan="pro_ai")
    signed = pack_tx(apple, u["id"], KLEIN, "7000000000000050")
    monkeypatch.delenv("LERNAPP_APPLE_ROOT_CERTS")
    st, d = buy(hosted, h, signed)
    assert (st, d["code"]) == (503, "apple_not_configured"), "die App schliesst den Kauf nicht ab und versucht es wieder"
    assert wallet(u["id"]) == (0, 0)


def test_sandbox_purchases_are_capped_per_account_and_month(hosted, apple, monkeypatch):
    """TestFlight und Apples Pruefung kaufen in der Sandbox ohne Geld: die Kaeufe zaehlen (sonst fiele die Pruefung durch),
    aber hoechstens LERNAPP_CREDITS_SANDBOX_MONTH Credits je Konto und Monat - sonst waeren es kostenlose KI-Kosten."""
    u, h = user(hosted, "sandbox@beispiel.de", plan="pro_ai")
    monkeypatch.setenv("LERNAPP_CREDITS_SANDBOX_MONTH", "250")
    st, d = buy(hosted, h, pack_tx(apple, u["id"], GROSS, "7000000000000060", environment="Sandbox"))
    assert (d["credits_added"], d["sandbox_limited"], d["environment"]) == (200, False, "Sandbox")
    st, d = buy(hosted, h, pack_tx(apple, u["id"], KLEIN, "7000000000000061", environment="Sandbox"))
    assert (st, d["status"], d["credits_added"], d["sandbox_limited"]) == (200, "granted", 50, True)
    st, d = buy(hosted, h, pack_tx(apple, u["id"], KLEIN, "7000000000000062", environment="Sandbox"))
    assert (st, d["credits_added"], d["sandbox_limited"]) == (200, 0, True), "200: die App schliesst den Kauf ab"
    # ein echter Kauf ist nie begrenzt
    assert buy(hosted, h, pack_tx(apple, u["id"], GROSS, "7000000000000063"))[1]["credits_added"] == 200
    assert wallet(u["id"]) == (450, 0)


# ---------------------------------------------------------------- Erstattung

def test_refund_removes_only_what_is_left_of_that_purchase(hosted, apple):
    from app import credits
    u, h = user(hosted, "erstattung@beispiel.de", plan="pro_ai")
    uid = u["id"]
    assert buy(hosted, h, pack_tx(apple, uid, KLEIN, "7000000000000070"))[1]["credits_added"] == 100
    assert buy(hosted, h, pack_tx(apple, uid, KLEIN, "7000000000000071"))[1]["credits_added"] == 100
    conn = ledger_conn()
    try:
        now = datetime.now(UTC)
        credits.reserve(conn, uid, "m", "tutor:explain", 100, now=now)
        credits.settle(conn, uid, "m", 100 * 6_500, now=now)
        credits.reserve(conn, uid, "a", "tutor:explain", 30, now=now)
        credits.settle(conn, uid, "a", 30 * 6_500, now=now)          # 30 aus dem aelteren Kauf verbraucht
    finally:
        conn.close()
    assert wallet(uid) == (170, 0)
    # Erstattung des aelteren Kaufs: nur seine restlichen 70 gehen weg, die 30 verbrauchten bleiben verbraucht
    refund = apple.notification("REFUND", pack_tx(apple, uid, KLEIN, "7000000000000070", revoked=True))
    st, d = notify(hosted, refund)
    assert st == 200 and d["applied"] and (d["status"], d["credits_removed"]) == ("refunded", 70), d
    assert wallet(uid) == (100, 0) and credits_of(hosted, h)["purchased"] == 100
    # doppelt gemeldet (gleiche und neue Mitteilung, dazu die App mit der widerrufenen Transaktion): kein zweiter Abzug
    assert notify(hosted, refund)[1]["duplicate"]
    st, d = notify(hosted, apple.notification("REFUND", pack_tx(apple, uid, KLEIN, "7000000000000070", revoked=True)))
    assert (d["status"], d["credits_removed"]) == ("already_refunded", 0)
    st, d = buy(hosted, h, pack_tx(apple, uid, KLEIN, "7000000000000070", revoked=True))
    assert (st, d["status"], d["credits_removed"]) == (200, "already_refunded", 0)
    # der erstattete Kauf laesst sich nicht noch einmal gutschreiben
    assert buy(hosted, h, pack_tx(apple, uid, KLEIN, "7000000000000070"))[1]["status"] == "refunded"
    assert wallet(uid) == (100, 0)
    # Apple nimmt die Erstattung zurueck: die abgezogenen 70 kommen wieder
    st, d = notify(hosted, apple.notification("REFUND_REVERSED", pack_tx(apple, uid, KLEIN, "7000000000000070")))
    assert st == 200 and (d["status"], d["credits_added"]) == ("granted", 70), d
    conn = ledger_conn()
    try:
        assert wallet(uid) == (170, 0) and credits.wallet_consistent(conn, uid)
    finally:
        conn.close()


def test_refund_never_goes_below_zero_and_unknown_refund_blocks_a_later_grant(hosted, apple):
    from app import credits
    u, h = user(hosted, "nieminus@beispiel.de", plan="pro_ai")
    uid = u["id"]
    assert buy(hosted, h, pack_tx(apple, uid, KLEIN, "7000000000000080"))[1]["credits_added"] == 100
    conn = ledger_conn()
    try:
        now = datetime.now(UTC)
        credits.reserve(conn, uid, "m", "tutor:explain", 100, now=now)
        credits.settle(conn, uid, "m", 100 * 6_500, now=now)
        credits.reserve(conn, uid, "alles", "tutor:explain", 100, now=now)
        credits.settle(conn, uid, "alles", 100 * 6_500, now=now)     # das ganze Paket ist verbraucht
        # eine Anfrage laeuft noch, waehrend die Erstattung eines zweiten Kaufs kommt
        assert buy(hosted, h, pack_tx(apple, uid, KLEIN, "7000000000000081"))[1]["credits_added"] == 100
        credits.reserve(conn, uid, "laeuft", "tutor:explain", 40, now=now)
        st, d = notify(hosted, apple.notification("REFUND", pack_tx(apple, uid, KLEIN, "7000000000000081", revoked=True)))
        assert d["credits_removed"] == 100 and wallet(uid) == (0, 40)
        assert credits.settle(conn, uid, "laeuft", 40 * 6_500, now=now) == 0, "nichts mehr da: nichts berechnet, nie ins Minus"
        assert wallet(uid) == (0, 0)
    finally:
        conn.close()
    # Erstattung eines voll verbrauchten Kaufs: 0 Credits weg, Stand bleibt 0
    st, d = notify(hosted, apple.notification("REFUND", pack_tx(apple, uid, KLEIN, "7000000000000080", revoked=True)))
    assert (d["status"], d["credits_removed"]) == ("refunded", 0) and wallet(uid) == (0, 0)
    assert credits_of(hosted, h)["purchased"] == 0
    # Erstattung kommt, bevor der Kauf je gemeldet wurde: vermerkt, eine spaete Meldung schreibt nichts mehr gut
    st, d = notify(hosted, apple.notification("REFUND", pack_tx(apple, uid, KLEIN, "7000000000000082", revoked=True)))
    assert st == 200 and d["status"] == "refunded", d
    assert buy(hosted, h, pack_tx(apple, uid, KLEIN, "7000000000000082"))[1] | {"credits": None} == {
        "status": "refunded", "credits_added": 0, "credits_removed": 0, "product_id": KLEIN, "transaction_id": "7000000000000082",
        "environment": "Production", "other_account": False, "sandbox_limited": False, "credits": None}
    # Mitteilungen ohne Folgen aendern nichts (Erstattung abgelehnt, Anfrage nach Verbrauchsangaben)
    assert buy(hosted, h, pack_tx(apple, uid, KLEIN, "7000000000000083"))[1]["credits_added"] == 100
    for ntype in ("REFUND_DECLINED", "CONSUMPTION_REQUEST"):
        st, d = notify(hosted, apple.notification(ntype, pack_tx(apple, uid, KLEIN, "7000000000000083")))
        assert st == 200 and not d["applied"], (ntype, d)
    assert wallet(uid) == (100, 0)


# ---------------------------------------------------------------- Budget dicht, gekaufte Credits nie blockiert

def test_monthly_budget_does_not_block_purchased_credits(hosted, monkeypatch):
    """Das Monats-Budget je Konto zaehlt nur, was nicht aus gekauften Credits bezahlt wird. Ein FakeAI-Aufruf kostet
    hier 56.000 Millionstel EUR = 9 Credits, die Schaetzung ist 20; der Monat hat 30 Credits, das Budget 0,14 EUR."""
    from app import ai_backend, ai_prices, credits
    cheap_calls(monkeypatch)
    monkeypatch.setattr(ai_prices, "estimate_credits", lambda *a, **k: 20)
    monkeypatch.setenv("LERNAPP_AI_USER_BUDGET_EUR", "0.14")
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "100")
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "30")
    ai_backend.set_provider(FakeAI())
    u, h = user(hosted, "budget-kauf@beispiel.de", plan="pro_ai")
    uid = u["id"]
    for i in range(2):
        st, d = ask(hosted, h, f"Seite {i}", f"m{i}")
        assert st == 200 and d["credits"]["charged"] == 9, d
    # ohne gekaufte Credits: der Monat reicht nicht mehr fuer die Schaetzung -> aufgebraucht (wie bisher)
    st, d = ask(hosted, h, "Seite leer", "leer")
    assert (st, d["code"], d["credits"]["remaining"], d["credits"]["available"]) == (429, "credits_exhausted", 12, 12)
    assert d["detail"] == "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.", "Text fuer alte Apps unveraendert"
    give(uid, 100)
    # jetzt geht es weiter: erst der Rest des Monats, dann die gekauften - auch nachdem das Monats-Budget des Kontos
    # (0,14 EUR) erreicht ist. Die erste Anfrage zahlt der Monat (12 frei, 9 berechnet), alle weiteren die gekauften.
    spent = []
    for i in range(6):
        st, d = ask(hosted, h, f"Gekauft {i}", f"k{i}")
        assert st == 200, (i, d)
        spent.append((d["credits"]["charged"], d["credits"]["remaining"], d["credits"]["purchased"]))
    assert spent == [(9, 3, 100), (9, 3, 91), (9, 3, 82), (9, 3, 73), (9, 3, 64), (9, 3, 55)]
    conn = ai_backend.connect()
    try:
        period = ai_backend._now().strftime("%Y-%m")
        counted = ai_backend._user_total(conn, period, uid)
        total, bought = conn.execute("SELECT SUM(cost_microeur), SUM(purchased_microeur) FROM ai_usage_log WHERE user_id=? AND state='done'",
                                     (uid,)).fetchone()
        assert (total, bought) == (8 * 56_000, 5 * 56_000)
        assert counted == total - bought == 3 * 56_000, "im Monats-Budget zaehlt nur, was nicht gekaufte Credits bezahlen"
        assert ai_backend.month_totals_match_log(conn) and credits.wallet_consistent(conn, uid)
        rep = ai_backend.month_report(conn)
        assert rep["purchased_cost_eur"] == pytest.approx(0.28) and rep["cost_eur"] == pytest.approx(0.448)
        # Kosten OHNE Credits (z. B. KI-Mail, KI-Test) zaehlen weiter gegen das Monats-Budget und sind gesperrt: die
        # gekauften Credits haben das Budget nicht aufgeweicht
        with pytest.raises(ai_backend.AIUnavailable) as e:
            ai_backend.reserve(conn, uid, "mail_rewrite")
        assert e.value.code == "ai_user_budget_exhausted"
    finally:
        conn.close()
    # sind auch die gekauften aufgebraucht, ist Schluss: nie mehr als Monat + gekauft
    monkeypatch.setenv("LERNAPP_AI_USER_BUDGET_EUR", "100")
    last = None
    for i in range(12):
        last = ask(hosted, h, f"Rest {i}", f"r{i}")
        if last[0] != 200:
            break
    assert (last[0], last[1]["code"]) == (429, "credits_exhausted")
    c = credits_of(hosted, h)
    assert c["available"] < 20 and c["used"] <= 30 and c["purchased"] >= 0
    conn = ledger_conn()
    try:
        charged, from_bought = conn.execute("SELECT SUM(charged), SUM(charged_purchased) FROM credit_ledger WHERE user_id=?", (uid,)).fetchone()
        assert charged <= 30 + 100 and from_bought == 100 - c["purchased"] and charged - from_bought == c["used"]
        assert credits.wallet_consistent(conn, uid)
    finally:
        conn.close()


def test_global_budget_does_not_block_purchased_credits_but_blocks_monthly_ones(hosted, monkeypatch):
    from app import ai_backend, ai_prices
    cheap_calls(monkeypatch)
    monkeypatch.setattr(ai_prices, "estimate_credits", lambda *a, **k: 20)
    monkeypatch.setenv("LERNAPP_AI_BUDGET_EUR", "0.01")
    ai_backend.set_provider(FakeAI())
    u, h = user(hosted, "becken@beispiel.de", plan="pro_ai")
    st, d = ask(hosted, h, "Seite", "a")
    assert (st, d["code"]) == (503, "ai_budget_exhausted")
    c = credits_of(hosted, h)
    assert (c["reserved"], c["used"]) == (0, 0), "Reservierung zurueckgegeben"
    give(u["id"], 100)
    # mit gekauften Credits: der Monat bleibt gesperrt (und unberuehrt), bezahlt wird ganz aus den gekauften
    st, d = ask(hosted, h, "Seite", "b")
    assert st == 200 and (d["credits"]["charged"], d["credits"]["remaining"], d["credits"]["purchased"]) == (9, 100, 91), d
    # reichen die gekauften nicht fuer die ganze Anfrage, bleibt es beim Fehler des Budgets (nichts haengt)
    monkeypatch.setattr(ai_prices, "estimate_credits", lambda *a, **k: 95)
    st, d = ask(hosted, h, "Andere Seite", "c")
    assert (st, d["code"]) == (503, "ai_budget_exhausted")
    c = credits_of(hosted, h)
    assert (c["reserved"], c["purchased"]) == (0, 91) and wallet(u["id"]) == (91, 0)


def test_ai_request_quota_does_not_block_purchased_credits(hosted, monkeypatch):
    from app import ai_backend, plans
    cheap_calls(monkeypatch)
    ai_backend.set_provider(FakeAI())
    monkeypatch.setitem(plans.QUOTAS["pro_ai"], "ai_assist", 1)
    u, h = user(hosted, "kontingent@beispiel.de", plan="pro_ai")
    assert ask(hosted, h, "eins", "q1")[0] == 200
    st, d = ask(hosted, h, "zwei", "q2")
    assert (st, d["code"]) == (429, "quota_exhausted"), "ohne gekaufte Credits gilt das Kontingent wie bisher"
    give(u["id"], 100)
    st, d = ask(hosted, h, "drei", "q3")
    assert st == 200, d
    assert ent(hosted, h)["quotas"]["ai_assist"]["used"] == 1, "die Anfrage zaehlt nicht mehr auf das Kontingent"
    # andere Kontingente (KI-Tests, KI-Mails) bleiben, wie sie sind
    from app import entitlements
    assert entitlements.PURCHASED_CREDITS_FEATURES == {"ai_assist"}


# ---------------------------------------------------------------- Tarif endet und kommt wieder, Probe

def test_purchased_credits_rest_without_pro_ai_and_return_with_it(hosted, apple, monkeypatch):
    from app import accounts, ai_backend
    cheap_calls(monkeypatch)
    ai_backend.set_provider(FakeAI())
    u, h = user(hosted, "ruht@beispiel.de", plan="pro_ai")
    uid = u["id"]
    assert buy(hosted, h, pack_tx(apple, uid, KLEIN, "7000000000000090"))[1]["credits_added"] == 100
    c = credits_of(hosted, h)
    assert (c["purchased"], c["purchased_usable"], c["can_buy"], c["available"]) == (100, True, True, 200)
    # Pro AI endet (Plus bzw. Free): die gekauften bleiben beim Konto, sind aber nicht nutzbar und nicht kaufbar
    for plan in ("plus", "free"):
        accounts.set_plan(uid, plan)
        c = credits_of(hosted, h)
        assert (c["allowance"], c["remaining"], c["purchased"], c["purchased_usable"], c["can_buy"], c["available"]) == (0, 0, 100, False, False, 0), plan
        st, d = ask(hosted, h, "Seite", f"ohne-{plan}")
        assert (st, d["code"]) == (403, "plan_required"), "die StudiNow-KI gehoert zu Pro AI; nichts wird abgebucht"
        assert wallet(uid) == (100, 0)
    # ein bezahlter Kauf wird trotzdem immer gutgeschrieben (wer bezahlt hat, bekommt seine Credits)
    st, d = buy(hosted, h, pack_tx(apple, uid, KLEIN, "7000000000000091"))
    assert (st, d["credits_added"], d["credits"]["purchased"], d["credits"]["purchased_usable"]) == (200, 100, 200, False)
    # auch direkt im Ledger: ohne die KI im Tarif wird aus dem gekauften Topf nichts reserviert
    from app import credits
    conn = ledger_conn()
    try:
        with pytest.raises(credits.CreditsError):
            credits.reserve(conn, uid, "direkt", "tutor:explain", 1)
    finally:
        conn.close()
    # Pro AI ist wieder da: alles wieder nutzbar, zuerst der Monat
    accounts.set_plan(uid, "pro_ai")
    c = credits_of(hosted, h)
    assert (c["remaining"], c["purchased"], c["purchased_usable"], c["can_buy"], c["available"]) == (100, 200, True, True, 300)
    st, d = ask(hosted, h, "Seite", "wieder")
    assert st == 200 and (d["credits"]["remaining"], d["credits"]["purchased"]) == (100 - d["credits"]["charged"], 200)


def test_trial_keeps_its_25_credits_cannot_buy_and_purchases_survive_its_end(hosted, apple):
    u, h = trial_account(hosted, "probe-kauf@beispiel.de")
    uid = u["id"]
    c = credits_of(hosted, h)
    assert (c["allowance"], c["plan"], c["can_buy"], c["purchased"], c["purchased_usable"]) == (25, "pro_ai:trial", False, 0, True)
    # kommt trotzdem ein bezahlter Kauf (z. B. Pro AI in der Probe gekauft und wieder erstattet): gutgeschrieben, nutzbar
    assert buy(hosted, h, pack_tx(apple, uid, KLEIN, "7000000000000100"))[1]["credits_added"] == 100
    c = credits_of(hosted, h)
    assert (c["remaining"], c["purchased"], c["available"]) == (25, 100, 125)
    # Probe vorbei, kein Tarif: die Monats-Credits sind weg, die gekauften bleiben (ruhen)
    end_trial(uid)
    c = credits_of(hosted, h)
    assert (c["allowance"], c["remaining"], c["purchased"], c["purchased_usable"], c["available"]) == (0, 0, 100, False, 0)
    # Probe + bezahltes Pro AI: darf kaufen
    v, hv = trial_account(hosted, "probe-pro@beispiel.de")
    assert verify(hosted, hv, apple.tx(v["id"], "de.uniflow.proai.yearly", IN_30, otid="7100000000000001"))[1]["plan"] == "pro_ai"
    c = credits_of(hosted, hv)
    assert (c["allowance"], c["can_buy"]) == (100, True)


# ---------------------------------------------------------------- alte Apps: Antworten unveraendert

def test_old_apps_see_the_same_fields_with_the_same_meaning(hosted, apple, monkeypatch):
    from app import ai_backend, credits
    cheap_calls(monkeypatch)
    ai_backend.set_provider(FakeAI())
    u, h = user(hosted, "alteapp@beispiel.de", plan="pro_ai")
    e = ent(hosted, h)
    c = e["credits"]
    # die bisherigen Felder sind da und meinen weiter nur die Monats-Credits
    assert [k for k in OLD_FIELDS if k not in c] == []
    assert (c["allowance"], c["used"], c["reserved"], c["remaining"], c["plan"], c["credit_eur"]) == (100, 0, 0, 100, "pro_ai", 0.0065)
    assert c["resets_at"] == credits.resets_at()
    assert check(e, schema_v2("me")) == [], "Vertrag der Antwort (nur zusaetzliche, freiwillige Felder)"
    give(u["id"], 300)
    c = credits_of(hosted, h)
    assert (c["allowance"], c["remaining"]) == (100, 100), "gekaufte Credits veraendern die alten Felder nicht"
    # neu und zusaetzlich
    assert (c["purchased"], c["purchased_usable"], c["available"], c["can_buy"]) == (300, True, 400, True)
    assert e["credit_packs"]["packs"] == [{"product_id": KLEIN, "credits": 100}, {"product_id": GROSS, "credits": 200}]
    assert e["credit_packs"]["purchase"]["web"]["available"] is False and "iPhone und iPad" in e["credit_packs"]["purchase"]["web"]["note"]
    # KI-Antwort: `credits` mit charged/replay wie bisher
    st, d = ask(hosted, h, "Seite", "alt-1")
    assert st == 200 and [k for k in (*OLD_FIELDS, "charged", "replay") if k not in d["credits"]] == []
    assert d["credits"]["remaining"] == 100 - d["credits"]["charged"]
    # die Abo-Route antwortet fuer Abos wie bisher ...
    st, d = verify(hosted, h, apple.tx(u["id"], "de.uniflow.proai.yearly", IN_30, otid="7200000000000001"))
    assert st == 200 and check(d, schema_v2("apple-verify")) == [] and "credit_purchase" not in d
    # ... und schreibt ein Credit-Paket gut, falls eine aeltere App es dort meldet und danach abschliesst
    st, d = verify(hosted, h, pack_tx(apple, u["id"], KLEIN, "7200000000000002"))
    assert st == 200 and d["plan"] is None and d["credit_purchase"]["credits_added"] == 100, d
    assert d["entitlements"]["plan"] == "pro_ai" and credits_of(hosted, h)["purchased"] == 400
    assert verify(hosted, h, pack_tx(apple, u["id"], KLEIN, "7200000000000002"))[1]["credit_purchase"]["status"] == "already_granted"
    # die Tarife (oeffentlich) nennen die Pakete zusaetzlich
    st, p = _j(asgi_call(hosted, "GET", "/api/billing/plans"))
    assert st == 200 and p["plans"]["pro_ai"]["credits"] == 100 and p["credits"] == {"free": 0, "plus": 0, "pro_ai": 100, "trial": 25}
    assert [x["product_id"] for x in p["credit_packs"]["packs"]] == [KLEIN, GROSS] and p["credit_packs"]["buy_plans"] == ["pro_ai"]


def test_local_mode_has_no_credit_shop(app):
    st, d = _j(asgi_call(app, "POST", "/api/billing/credits/apple", body=json.dumps({"signed_transaction": "a.b.c"})))
    assert (st, d["code"]) == (501, "not_hosted")
    st, e = _j(asgi_call(app, "GET", "/api/entitlements"))
    assert st == 200 and "credit_packs" not in e


# ---------------------------------------------------------------- Migration, Konto loeschen, Export

OLD_ACCOUNTS_SQL = """
CREATE TABLE credit_months (user_id TEXT NOT NULL, period TEXT NOT NULL, allowance INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0,
    reserved INTEGER NOT NULL DEFAULT 0, plan TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (user_id, period));
CREATE TABLE credit_ledger (user_id TEXT NOT NULL, request_id TEXT NOT NULL, period TEXT NOT NULL, day TEXT NOT NULL, purpose TEXT NOT NULL,
    funding TEXT NOT NULL, state TEXT NOT NULL, model TEXT, reserved INTEGER NOT NULL DEFAULT 0, charged INTEGER NOT NULL DEFAULT 0,
    cost_microeur INTEGER NOT NULL DEFAULT 0, input_tokens INTEGER NOT NULL DEFAULT 0, cached_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0, images INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, settled_at TEXT, result TEXT,
    PRIMARY KEY (user_id, request_id));
CREATE TABLE ai_usage_log (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT, period TEXT NOT NULL, purpose TEXT NOT NULL, provider TEXT,
    model TEXT, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0, cost_microeur INTEGER NOT NULL DEFAULT 0,
    trial INTEGER NOT NULL DEFAULT 0, library INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'reserved', created_at TEXT NOT NULL);
CREATE TABLE ai_usage_month (period TEXT NOT NULL, pool TEXT NOT NULL, cost_microeur INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (period, pool));
CREATE TABLE ai_usage_user_month (period TEXT NOT NULL, user_id TEXT NOT NULL, cost_microeur INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (period, user_id));
CREATE TRIGGER trg_ai_usage_month_ins AFTER INSERT ON ai_usage_log BEGIN
    INSERT INTO ai_usage_month(period, pool, cost_microeur) VALUES (NEW.period, 'paid', NEW.cost_microeur)
        ON CONFLICT(period, pool) DO UPDATE SET cost_microeur = cost_microeur + excluded.cost_microeur;
END;
CREATE TRIGGER trg_ai_usage_month_upd AFTER UPDATE OF period, trial, library, state, cost_microeur, user_id ON ai_usage_log BEGIN
    UPDATE ai_usage_month SET cost_microeur = cost_microeur - OLD.cost_microeur WHERE period=OLD.period AND pool='paid';
END;
INSERT INTO credit_months VALUES ('u1', '2026-11', 100, 30, 0, 'pro_ai', '2026-11-01T00:00:00+00:00', '2026-11-01T00:00:00+00:00');
INSERT INTO credit_ledger(user_id, request_id, period, day, purpose, funding, state, reserved, charged, cost_microeur, created_at)
    VALUES ('u1', 'alt', '2026-11', '2026-11-05', 'tutor:explain', 'credits', 'settled', 40, 30, 270000, '2026-11-05T10:00:00+00:00');
INSERT INTO ai_usage_log(user_id, period, purpose, cost_microeur, state, created_at) VALUES ('u1', '2026-11', 'tutor:explain', 270000, 'done', '2026-11-05T10:00:00+00:00');
"""


def test_migration_on_an_old_and_half_created_database(hosted):
    """Stand vor dem 15.11.: Tabellen der Credits und der KI-Kosten ohne die neuen Spalten, alte Trigger, keine Tabelle
    `users` (am 14.11.2026 scheiterte so eine Migration an `no such table: users`). Der Start zieht alles nach,
    wiederholbar, und bestehende Zahlen bleiben."""
    from app import accounts, ai_backend, credits
    p = accounts.db_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    raw = sqlite3.connect(p)
    raw.executescript(OLD_ACCOUNTS_SQL)
    raw.commit()
    raw.close()
    for _ in range(2):                                   # zweimal: wiederholbar
        conn = ai_backend.connect()
        try:
            for fn in (ai_backend.ensure_schema, credits.ensure_schema):
                fn(conn)
            cols = {r[1] for r in conn.execute("PRAGMA table_info(credit_ledger)")}
            assert set(credits.LEDGER_COLUMNS) <= cols
            assert "purchased_microeur" in {r[1] for r in conn.execute("PRAGMA table_info(ai_usage_log)")}
            tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            assert {"credit_wallets", "credit_purchases"} <= tables and "users" not in tables
            triggers = dict(conn.execute("SELECT name, sql FROM sqlite_master WHERE type='trigger'").fetchall())
            assert set(triggers) == set(ai_backend.TRIGGER_NAMES) and all("purchased_microeur" in sql for sql in triggers.values())
            assert ai_backend.month_totals_match_log(conn), "Monatssummen neu aufgebaut"
            assert ai_backend._user_total(conn, "2026-11", "u1") == 270_000
        finally:
            conn.close()
    conn = credits.connect()
    try:
        # alte Zeilen gelten weiter, der neue Topf arbeitet auf der alten Datei (ohne users: Tarif free -> ruht)
        b = credits.balance(conn, "u1", now=T0)
        assert (b["used"], b["purchased"], b["purchased_usable"]) == (30, 0, False)
        assert credits.grant_purchase(conn, "u1", "test", "t1", 100, now=T0)["status"] == "granted"
        assert credits.grant_purchase(conn, "u1", "test", "t1", 100, now=T0)["status"] == "already_granted"
        assert credits.balance(conn, "u1", now=T0)["purchased"] == 100
        assert tuple(conn.execute("SELECT reserved_purchased, charged_purchased, purchased_microeur FROM credit_ledger WHERE request_id='alt'").fetchone()) == (0, 0, 0)
    finally:
        conn.close()


def test_account_deletion_and_export_cover_purchased_credits(hosted, apple):
    import zipfile
    from app import account_export, accounts
    u, h = user(hosted, "loeschen-kauf@beispiel.de", plan="pro_ai")
    uid = u["id"]
    assert buy(hosted, h, pack_tx(apple, uid, KLEIN, "7300000000000001"))[1]["credits_added"] == 100
    path = account_export.build(accounts.get_user(uid) if hasattr(accounts, "get_user") else u)
    try:
        with zipfile.ZipFile(path) as z:
            konto = json.loads(z.read("konto.json"))
    finally:
        path.unlink(missing_ok=True)
    assert konto["ki_credits_gekauft"][0]["balance"] == 100
    assert [(k["transaction_id"], k["credits"], k["state"]) for k in konto["ki_credits_kaeufe"]] == [("7300000000000001", 100, "granted")]
    with accounts.cursor() as conn:
        accounts._purge_user(conn, uid)
    conn = ledger_conn()
    try:
        assert conn.execute("SELECT COUNT(*) FROM credit_wallets WHERE user_id=?", (uid,)).fetchone()[0] == 0
        row = conn.execute("SELECT user_id, remaining FROM credit_purchases WHERE transaction_id='7300000000000001'").fetchone()
        assert row[0].startswith("deleted:") and row[1] == 0, "Kauf bleibt ohne Konto (Buchhaltung), nichts mehr gutzuschreiben"
    finally:
        conn.close()
    # dieselbe Transaktion kann danach kein anderes Konto fuellen
    v, hv = user(hosted, "danach@beispiel.de", plan="pro_ai")
    st, d = buy(hosted, hv, pack_tx(apple, uid, KLEIN, "7300000000000001"))
    assert (st, d["status"], d["credits_added"]) == (200, "already_granted", 0) and wallet(v["id"]) == (0, 0)


# ---------------------------------------------------------------- gemeinsame Fixture (Swift-Kern, Web)

def test_credit_packs_fixture_is_current(hosted):
    """packages/shared-contracts/fixtures/credit-packs/contract.json stammt aus der Python-Referenz; der Swift-Kern
    (CreditPacksTests.swift) und die Web-Oberflaeche (tests/js/credit-packs.test.mjs) lesen dieselbe Datei."""
    import importlib.util
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    stored = json.loads((root / "packages/shared-contracts/fixtures/credit-packs/contract.json").read_text(encoding="utf-8"))
    spec = importlib.util.spec_from_file_location("gen_credit_packs_fixture", root / "tools" / "gen-credit-packs-fixture.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert mod.build(hosted) == stored, "python tools/gen-credit-packs-fixture.py neu ausfuehren"


def test_texts_for_both_pots():
    from app import credit_texts as t
    full = {"allowance": 100, "remaining": 37, "purchased": 80, "purchased_usable": True, "can_buy": True,
            "resets_at": "2026-12-01T00:00:00+01:00"}
    assert t.balance_line(full) == "Diesen Monat: 37 von 100 · Gekauft: 80"
    assert t.keep_note(full) == "Gekaufte Credits verfallen nicht. Deine 100 Monats-Credits gibt es am 1. Dezember wieder."
    assert t.available(full) == 117 and t.offers_shop(full) and t.dormant_note(full) is None
    resting = {"allowance": 0, "remaining": 0, "purchased": 60, "purchased_usable": False, "can_buy": False}
    assert t.balance_line(resting) == "Gekauft: 60 · nutzbar mit StudiNow Pro AI" and t.available(resting) == 0
    assert "bleiben bei deinem Konto" in t.dormant_note(resting) and not t.offers_shop(resting)
    assert t.balance_line({"allowance": 0, "remaining": 0}) == "Keine Credits in deinem Tarif" and t.balance_line(None) is None
    assert t.pack_label(200) == "200 Credits" and t.reset_day("kaputt") is None and t.reset_day("2026-13-01T00:00:00") is None
    for text in (t.TITLE_EXHAUSTED, t.TITLE_SHOP, t.KEEP, t.BUY_NEEDS_PRO_AI, t.WEB_HINT, t.keep_note(full), t.dormant_note(resting)):
        assert "Cent" not in text and "€" not in text, "kein Preis und kein Centwert im Code: der Preis kommt aus dem Store"
