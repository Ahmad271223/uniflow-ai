"""Credits der StudiNow-KI je Konto und Monat (app/credits.py, Entscheidung des Inhabers 04.11.2026): Rahmen je Tarif,
Monatszeile beim ersten Gebrauch, reservieren/abrechnen/zurueckgeben, 429 credits_exhausted, request_id (409 und
Wiederholung 24 h), Tarifwechsel im Monat, Loeschen des Kontos, Kosten nur aus `usage`."""
import json
from datetime import UTC, datetime, timedelta

import pytest
from conftest import asgi_call
from test_ai_abuse import trial_account
from test_subscriptions import FakeAI, _j, hosted, library_test, user  # noqa: F401 - hosted ist eine Fixture

T0 = datetime(2026, 11, 10, 9, 0, tzinfo=UTC)


def ask(app, headers, text, request_id, **extra):
    return _j(asgi_call(app, "POST", "/api/ai/tutor", headers=headers,
                        body=json.dumps({"mode": "explain", "page_text": text, "request_id": request_id, **extra})))


def credits_of(app, headers):
    st, d = _j(asgi_call(app, "GET", "/api/entitlements", headers=headers))
    assert st == 200, d
    return d["credits"]


def ledger_conn():
    from app import credits
    return credits.connect()


def cheap_calls(monkeypatch):
    """Ein FakeAI-Aufruf (120+40 Tokens) kostet bei 500 EUR je 1 Mio. Tokens 80.000 Millionstel EUR = 8 Credits; die
    Schaetzung vor dem Aufruf ist fest 10 Credits."""
    from app import ai_prices
    monkeypatch.setenv("LERNAPP_AI_PRICE_IN_EUR", "500")
    monkeypatch.setenv("LERNAPP_AI_PRICE_OUT_EUR", "500")
    monkeypatch.setenv("LERNAPP_AI_USER_BUDGET_EUR", "100")
    monkeypatch.setattr(ai_prices, "estimate_credits", lambda *a, **k: 10)


class FailingAI(FakeAI):
    """Anbieter antwortet mit Fehler, ohne dass OpenAI etwas berechnet haette."""

    def complete(self, system, prompt, schema=None):
        from app import ai_backend
        self.calls += 1
        raise ai_backend.AIUnavailable("ai_provider_error", "Der KI-Anbieter antwortete mit Fehler 500.", 502)


# ---------------------------------------------------------------- Rahmen je Tarif und Monat

def test_allowance_per_plan_and_env(monkeypatch):
    from app import credits
    assert credits.allowance("pro_ai", False) == 100
    assert [credits.allowance(p, False) for p in ("pro_connect", "plus", "free", "unbekannt")] == [0, 0, 0, 0]
    assert credits.allowance("free", True) == 25, "Probe: eigener Rahmen"
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "40")
    monkeypatch.setenv("LERNAPP_CREDITS_PLUS", "5")
    monkeypatch.setenv("LERNAPP_CREDITS_TRIAL", "7")
    assert (credits.allowance("pro_ai", False), credits.allowance("plus", False), credits.allowance("plus", True)) == (40, 5, 7)
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "kaputt")
    assert credits.allowance("pro_ai", False) == 100


def test_month_is_the_calendar_month_in_berlin():
    from app import credits
    assert credits.period_of(datetime(2026, 1, 31, 23, 30, tzinfo=UTC)) == "2026-02"
    assert credits.day_of(datetime(2026, 1, 31, 23, 30, tzinfo=UTC)) == "2026-02-01"
    assert credits.resets_at(datetime(2026, 2, 10, 12, 0, tzinfo=UTC)) == "2026-03-01T00:00:00+01:00"
    assert credits.resets_at(datetime(2026, 12, 31, 23, 30, tzinfo=UTC)) == "2027-02-01T00:00:00+01:00"


def test_month_row_appears_lazily_on_first_use_and_follows_the_plan(hosted):
    from app import accounts, credits
    u, h = user(hosted, "faul@beispiel.de", plan="pro_ai")
    conn = ledger_conn()
    try:
        assert conn.execute("SELECT COUNT(*) FROM credit_months").fetchone()[0] == 0, "kein naechtlicher Lauf, keine Vorab-Zeile"
        c = credits_of(hosted, h)
        assert (c["period"], c["allowance"], c["used"], c["reserved"], c["remaining"], c["plan"]) == (credits.period_of(), 100, 0, 0, 100, "pro_ai")
        assert c["resets_at"] == credits.resets_at() and c["credit_eur"] == 0.01
        assert conn.execute("SELECT COUNT(*) FROM credit_months WHERE user_id=?", (u["id"],)).fetchone()[0] == 1
        # neuer Monat = neue Zeile mit frischem Rahmen; die alte bleibt (Verfall am Monatsende)
        credits.reserve(conn, u["id"], "x", "tutor:explain", 3, now=T0)
        credits.settle(conn, u["id"], "x", 30_000, now=T0)
        later = credits.balance(conn, u["id"], now=T0 + timedelta(days=40))
        assert (later["period"], later["used"], later["remaining"]) == ("2026-12", 0, 100)
        assert credits.balance(conn, u["id"], now=T0)["used"] == 3
    finally:
        conn.close()
    # Tarifwechsel mitten im Monat: der Rahmen folgt sofort, Verbrauchtes bleibt
    accounts.set_plan(u["id"], "plus")
    c = credits_of(hosted, h)
    assert (c["allowance"], c["plan"], c["remaining"]) == (0, "plus", 0)
    accounts.set_plan(u["id"], "pro_ai")
    assert credits_of(hosted, h)["allowance"] == 100


def test_trial_account_has_its_own_allowance(hosted, monkeypatch):
    _, h = trial_account(hosted, "probe@beispiel.de")
    c = credits_of(hosted, h)
    assert (c["allowance"], c["plan"]) == (25, "pro_ai:trial")
    monkeypatch.setenv("LERNAPP_CREDITS_TRIAL", "7")
    assert credits_of(hosted, h)["allowance"] == 7


# ---------------------------------------------------------------- reservieren, abrechnen, zurueckgeben (Buchhaltung)

def test_reserve_settle_refund_arithmetic(hosted):
    from app import credits
    u, _ = user(hosted, "buch@beispiel.de", plan="pro_ai")
    uid = u["id"]
    conn = ledger_conn()
    try:
        r = credits.reserve(conn, uid, "a", "tutor:explain", 12, now=T0, model="gpt-6-luna")
        assert (r.reserved, r.replay, r.balance["reserved"], r.balance["remaining"]) == (12, False, 12, 88)
        # abgerechnet wird die echte Nutzung: 2,3 Cent -> 3 Credits (aufgerundet), die Reservierung wird frei
        assert credits.settle(conn, uid, "a", 23_000, model="gpt-6-luna", input_tokens=900, cached_tokens=100, output_tokens=40, now=T0) == 3
        b = credits.balance(conn, uid, now=T0)
        assert (b["used"], b["reserved"], b["remaining"]) == (3, 0, 97)
        row = conn.execute("SELECT state, reserved, charged, cost_microeur, input_tokens, cached_tokens, output_tokens, model, day "
                           "FROM credit_ledger WHERE user_id=? AND request_id='a'", (uid,)).fetchone()
        assert tuple(row) == ("settled", 12, 3, 23_000, 900, 100, 40, "gpt-6-luna", "2026-11-10")
        # Fehler ohne Nutzung: Reservierung zurueck, nichts berechnet
        credits.reserve(conn, uid, "b", "flashcards", 5, now=T0)
        assert credits.refund(conn, uid, "b") is True
        assert credits.refund(conn, uid, "b") is False, "nur eine laufende Reservierung laesst sich zurueckgeben"
        assert credits.refund(conn, uid, "a") is False, "Abgerechnetes bleibt abgerechnet"
        b = credits.balance(conn, uid, now=T0)
        assert (b["used"], b["reserved"]) == (3, 0)
        assert conn.execute("SELECT state FROM credit_ledger WHERE user_id=? AND request_id='b'", (uid,)).fetchone()[0] == "refunded"
        # zurueckgegebene ID darf noch einmal versucht werden
        assert credits.reserve(conn, uid, "b", "flashcards", 5, now=T0).replay is False
        # 0 Kosten (z. B. leere Antwort) = 0 Credits; eine zweite Abrechnung derselben ID aendert nichts
        assert credits.settle(conn, uid, "b", 0, now=T0) == 0
        assert credits.settle(conn, uid, "b", 99_000, now=T0) == 0
        assert credits.balance(conn, uid, now=T0)["used"] == 3
        # liegengebliebene Reservierung (Prozess abgestuerzt) verfaellt nach 15 Minuten
        credits.reserve(conn, uid, "c", "tutor:ask", 9, now=T0)
        assert credits.balance(conn, uid, now=T0 + timedelta(minutes=5))["reserved"] == 9
        assert credits.balance(conn, uid, now=T0 + timedelta(minutes=16))["reserved"] == 0
        assert conn.execute("SELECT state FROM credit_ledger WHERE user_id=? AND request_id='c'", (uid,)).fetchone()[0] == "expired"
        with pytest.raises(ValueError):
            credits.reserve(conn, uid, "", "tutor:ask", 1, now=T0)
    finally:
        conn.close()


def test_request_id_is_never_charged_twice(hosted):
    from app import ai_backend, credits
    u, _ = user(hosted, "einmal@beispiel.de", plan="pro_ai")
    uid = u["id"]
    conn = ledger_conn()
    try:
        credits.reserve(conn, uid, "r1", "tutor:explain", 4, now=T0)
        with pytest.raises(credits.CreditsError) as e:          # laeuft noch
            credits.reserve(conn, uid, "r1", "tutor:explain", 4, now=T0)
        assert (e.value.code, e.value.status) == ("duplicate_request", 409)
        with pytest.raises(ai_backend.AIUnavailable) as e2:
            ai_backend.replay(uid, "r1", now=T0)
        assert e2.value.status == 409
        credits.settle(conn, uid, "r1", 15_000, result="Antwort A", now=T0)
        # fertig: dieselbe ID liefert die gespeicherte Antwort, ohne neue Kosten
        again = credits.reserve(conn, uid, "r1", "tutor:explain", 4, now=T0 + timedelta(hours=23))
        assert (again.replay, again.result, again.charged, again.reserved) == (True, "Antwort A", 2, 0)
        c = ai_backend.replay(uid, "r1", now=T0 + timedelta(hours=23))
        assert c.replay and c.text == "Antwort A" and c.credits_charged == 0
        assert credits.balance(conn, uid, now=T0)["used"] == 2
        # nach 24 h ist die Antwort geleert; berechnet wird die ID trotzdem nie ein zweites Mal
        late = credits.reserve(conn, uid, "r1", "tutor:explain", 4, now=T0 + timedelta(hours=25))
        assert (late.replay, late.result) == (True, None)
        assert ai_backend.replay(uid, "r1", now=T0 + timedelta(hours=25)) is None
        assert credits.balance(conn, uid, now=T0 + timedelta(hours=25))["used"] == 2
        # eine andere Kennung ist eine neue Anfrage; dieselbe ID eines anderen Kontos auch
        assert credits.reserve(conn, uid, "r2", "tutor:explain", 4, now=T0).replay is False
        other, _ = user(hosted, "andere@beispiel.de", plan="pro_ai")
        assert credits.reserve(conn, other["id"], "r1", "tutor:explain", 4, now=T0).replay is False
    finally:
        conn.close()


def test_funding_order_shared_then_own_chatgpt_then_credits():
    from app import ai_backend, credits
    assert credits.funding_for(shared_hit=True, own_chatgpt=True) == "shared"
    assert credits.funding_for(own_chatgpt=True) == "own_chatgpt"
    assert credits.funding_for() == "credits"
    assert ai_backend.charges_credits("tutor:explain") and ai_backend.charges_credits("flashcards")
    assert not ai_backend.charges_credits("test_generation") and not ai_backend.charges_credits("weekly_test")


# ---------------------------------------------------------------- ueber die Endpunkte

def test_tutor_charges_credits_and_reports_the_balance(hosted, monkeypatch):
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    cheap_calls(monkeypatch)
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "25")
    u, h = user(hosted, "pro@beispiel.de", plan="pro_ai")
    st, d = ask(hosted, h, "Matrizen", "q1")
    assert st == 200, d
    c = d["credits"]
    assert (c["allowance"], c["used"], c["reserved"], c["remaining"], c["charged"], c["replay"]) == (25, 8, 0, 17, 8, False)
    assert credits_of(hosted, h)["remaining"] == 17
    conn = ledger_conn()
    try:
        row = conn.execute("SELECT purpose, funding, state, model, reserved, charged, cost_microeur, input_tokens, output_tokens, result "
                           "FROM credit_ledger WHERE user_id=? AND request_id='q1'", (u["id"],)).fetchone()
        assert tuple(row) == ("tutor:explain", "credits", "settled", "fake", 10, 8, 80_000, 120, 40, d["answer"])
    finally:
        conn.close()


def test_exhausted_credits_answer_429_with_the_german_message(hosted, monkeypatch):
    from app import ai_backend, credits
    fake = FakeAI()
    ai_backend.set_provider(fake)
    cheap_calls(monkeypatch)
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "25")
    _, h = user(hosted, "leer@beispiel.de", plan="pro_ai")
    assert ask(hosted, h, "eins", "e1")[0] == 200                       # 8 verbraucht, 17 uebrig
    assert ask(hosted, h, "zwei", "e2")[0] == 200                       # 16 verbraucht, 9 uebrig < Schaetzung 10
    st, d = ask(hosted, h, "drei", "e3")
    assert (st, d["code"]) == (429, "credits_exhausted")
    assert d["detail"] == credits.EXHAUSTED_MESSAGE == "Credits für diesen Monat aufgebraucht – am 1. gibt es neue."
    assert (d["credits"]["remaining"], d["credits"]["needed"], d["credits"]["allowance"]) == (9, 10, 25)
    assert fake.calls == 2, "kein Aufruf des Anbieters ohne Credits"
    st, e = _j(asgi_call(hosted, "GET", "/api/entitlements", headers=h))
    assert e["credits"]["used"] == 16 and e["quotas"]["ai_assist"]["used"] == 2, "Kontingent der abgewiesenen Anfrage zurueckgebucht"
    # dieselbe ID darf nach dem Zurueckbuchen neu versucht werden - und scheitert wieder ehrlich
    assert ask(hosted, h, "drei", "e3")[0] == 429
    # anderes Konto, eigener Rahmen
    _, h2 = user(hosted, "voll@beispiel.de", plan="pro_ai")
    assert ask(hosted, h2, "vier", "e4")[0] == 200


def test_same_request_id_replays_within_24h_without_new_cost(hosted, monkeypatch):
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    cheap_calls(monkeypatch)
    u, h = user(hosted, "retry@beispiel.de", plan="pro_ai")
    st, first = ask(hosted, h, "Vektorraum", "same-id")
    assert st == 200 and first["credits"]["charged"] == 8
    # Wiederholung nach Netzfehler: anderer Text (kein Treffer im Zwischenspeicher), dieselbe ID
    st, second = ask(hosted, h, "Vektorraum (noch einmal)", "same-id")
    assert st == 200, second
    assert second["answer"] == first["answer"] and fake.calls == 1
    assert (second["credits"]["charged"], second["credits"]["replay"], second["credits"]["used"]) == (0, True, 8)
    assert credits_of(hosted, h)["used"] == 8
    # laeuft die Anfrage noch, wird dieselbe ID abgewiesen
    from app import credits
    conn = ledger_conn()
    try:
        credits.reserve(conn, u["id"], "running", "tutor:explain", 5)
    finally:
        conn.close()
    st, d = ask(hosted, h, "laeuft", "running")
    assert (st, d["code"]) == (409, "duplicate_request") and fake.calls == 1


def test_provider_error_refunds_the_reservation(hosted, monkeypatch):
    from app import ai_backend
    failing = FailingAI()
    ai_backend.set_provider(failing)
    cheap_calls(monkeypatch)
    u, h = user(hosted, "fehler@beispiel.de", plan="pro_ai")
    st, d = ask(hosted, h, "Kern", "f1")
    assert (st, d["code"]) == (502, "ai_provider_error")
    c = credits_of(hosted, h)
    assert (c["used"], c["reserved"], c["remaining"]) == (0, 0, 100)
    conn = ledger_conn()
    try:
        assert conn.execute("SELECT state FROM credit_ledger WHERE user_id=? AND request_id='f1'", (u["id"],)).fetchone()[0] == "refunded"
    finally:
        conn.close()
    ai_backend.set_provider(FakeAI())
    st, d = ask(hosted, h, "Kern", "f1")                         # derselbe Versuch noch einmal
    assert st == 200 and d["credits"]["charged"] == 8 and d["credits"]["used"] == 8


def test_cost_comes_only_from_usage_never_from_the_client(hosted, monkeypatch):
    from app import ai_backend, ai_prices
    ai_backend.set_provider(FakeAI())
    cheap_calls(monkeypatch)
    _, h = user(hosted, "trick@beispiel.de", plan="pro_ai")
    st, d = ask(hosted, h, "Basis", "t1", credits=0, usage={"input_tokens": 0, "output_tokens": 0}, cost_microeur=0)
    assert st == 200 and d["credits"]["charged"] == 8, "Angaben des Clients zaehlen nicht"
    # usage der Responses API: input_tokens enthaelt cached_tokens, output_tokens die Denk-Tokens
    data = {"model": "gpt-6-luna-2026-10-01", "usage": {"input_tokens": 1000, "input_tokens_details": {"cached_tokens": 400},
                                                        "output_tokens": 50, "output_tokens_details": {"reasoning_tokens": 20}}}
    c = ai_backend.Completion.from_usage("Text", data, "gpt-6-luna", images=1)
    assert (c.input_tokens, c.cached_tokens, c.output_tokens, c.reasoning_tokens, c.images, c.model) == (1000, 400, 50, 20, 1, "gpt-6-luna-2026-10-01")
    monkeypatch.delenv("LERNAPP_AI_PRICE_IN_EUR")
    monkeypatch.delenv("LERNAPP_AI_PRICE_OUT_EUR")
    assert ai_prices.cost_microeur("gpt-6-luna-2026-10-01", 1000, 50, 400) == 600 * 0.10 + 400 * 0.01 + 50 * 0.50 == 89
    assert ai_prices.credits_for(89) == 1 and ai_prices.credits_for(10_000) == 1 and ai_prices.credits_for(10_001) == 2
    assert ai_prices.price("gibt-es-nicht") is None, "ohne Preis sperrt der Dienst"
    assert ai_backend.Completion.from_usage("x", {"output": []}, "m").input_tokens == 0


def test_pool_generation_and_shared_tests_cost_no_credits(hosted, monkeypatch):
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    cheap_calls(monkeypatch)
    _, h = user(hosted, "pool@beispiel.de", plan="pro_ai")
    assert library_test(hosted, h, "Determinanten")[0] == 200
    assert credits_of(hosted, h)["used"] == 0
    conn = ledger_conn()
    try:
        assert conn.execute("SELECT COUNT(*) FROM credit_ledger").fetchone()[0] == 0, "Pool-Erzeugung laeuft ueber das Kontingent"
        from app import credits
        credits.record_free(conn, "u", "shared-1", "week_test", "shared", now=T0)
        assert conn.execute("SELECT state, charged FROM credit_ledger WHERE request_id='shared-1'").fetchone()[:] == ("free", 0)
    finally:
        conn.close()


# ---------------------------------------------------------------- Konto loeschen und Betrieb

def test_purge_removes_credit_rows_of_the_account_but_keeps_costs(hosted, monkeypatch):
    from app import accounts, credits
    u = accounts.register("weg@beispiel.de", "sehr-geheim-123", "luh")
    uid = u["id"]
    accounts.set_plan(uid, "pro_ai")
    conn = ledger_conn()
    try:
        credits.reserve(conn, uid, "p1", "tutor:explain", 4, now=T0, model="gpt-6-luna")
        credits.settle(conn, uid, "p1", 25_000, model="gpt-6-luna", input_tokens=50, output_tokens=5, result="geheime Antwort", now=T0)
    finally:
        conn.close()
    accounts.delete_account(uid, "sehr-geheim-123")
    monkeypatch.setattr(accounts, "now", lambda: datetime.now(UTC) + timedelta(days=31))
    assert accounts.purge_deleted() == 1
    with accounts.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM credit_months WHERE user_id=?", (uid,)).fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM credit_ledger WHERE user_id=?", (uid,)).fetchone()[0] == 0
        rows = conn.execute("SELECT user_id, cost_microeur, charged, result FROM credit_ledger WHERE request_id='p1'").fetchall()
        assert len(rows) == 1 and rows[0][0].startswith("deleted:") and rows[0][1:] == (25_000, 3, None), "Kosten ohne Konto, ohne Antwort"


def test_admin_costs_view(hosted, monkeypatch):
    from app import ai_backend, credits
    ai_backend.set_provider(FakeAI())
    cheap_calls(monkeypatch)
    _, hadmin = user(hosted, "chef@beispiel.de", plan="pro_ai", admin=True)
    _, h = user(hosted, "nutzer@beispiel.de", plan="pro_ai")
    assert ask(hosted, h, "Rang", "k1")[0] == 200
    assert ask(hosted, h, "Spur", "k2")[0] == 200
    assert asgi_call(hosted, "GET", "/api/billing/ai-costs", headers=h)[0] == 403
    st, d = _j(asgi_call(hosted, "GET", "/api/billing/ai-costs?days=7", headers=hadmin))
    assert st == 200, d
    assert d["month"]["period"] == credits.period_of()
    assert (d["month"]["requests"], d["month"]["accounts"], d["month"]["credits"], d["month"]["cost_eur"]) == (2, 1, 16, 0.16)
    assert d["month"]["cost_per_account_eur"] == 0.16 and d["month"]["accounts_exhausted"] == 0 and d["month"]["max_used_credits"] == 16
    day = d["per_day_model"][0]
    assert (day["day"], day["model"], day["requests"], day["credits"], day["input_tokens"], day["output_tokens"]) == (credits.day_of(), "fake", 2, 16, 240, 80)
    assert d["prices_checked"] == "2026-11-04" and any(p["model"] == "gpt-6-luna" for p in d["prices"])
