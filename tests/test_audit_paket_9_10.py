"""Externer Audit 08.11.2026, Pakete 9 und 10 (Funktionen 242-301: app/ai_backend.py ab _Call, app/ai_providers.py,
app/ai_router.py, app/ai_prices.py). Bericht: docs/audit/AUDIT-2026-11-08-PAKET-9-10.md. Je bestaetigtem Befund erst der
fehlschlagende Test, dann die kleinste Behebung; widerlegte Befunde nageln das richtige Verhalten fest. Keine echten
Anbieter, keine Server: nur Attrappen, httpx.MockTransport und eine Test-Datenbank."""
import asyncio
import json
import math
import random
import sqlite3
import struct
from datetime import datetime, timedelta, timezone

import pytest
from test_ai_routing import MODELS, Fake, Transport, busy, install, lines_of, month, rid_for, table_prices  # noqa: F401 - Fixture
from test_subscriptions import hosted, user  # noqa: F401 - Fixture

T0 = datetime(2026, 11, 8, 12, 0, tzinfo=timezone.utc)


def _ledger(uid):
    from app import credits
    conn = credits.connect()
    try:
        led = conn.execute("SELECT state, reserved, charged FROM credit_ledger WHERE user_id=?", (uid,)).fetchall()
        log = conn.execute("SELECT state, cost_microeur FROM ai_usage_log WHERE user_id=?", (uid,)).fetchall()
    finally:
        conn.close()
    return led, log


# ================================================================== PAKET 9 (242-271)

# ---------------------------------------------------------------- P9-01 (#245): Zwischenspeicher ueber Konten hinweg

def test_p9_01_cache_answers_only_the_identical_request(hosted, table_prices, monkeypatch):
    """Der Schluessel umfasst Zweck, System, Prompt und Schema: ein Treffer liefert nur die Antwort auf genau den Text, den der
    Fragende selbst geschickt hat (geteilt zwischen Konten ist Absicht, docs: ai_cache). Anderer Prompt -> kein Treffer."""
    from app import ai_backend
    fakes = {"openai": Fake("openai", text="A")}
    install(monkeypatch, fakes)
    a, _ = user(hosted, "cache-a@beispiel.de", plan="pro_ai")
    b, _ = user(hosted, "cache-b@beispiel.de", plan="pro_ai")
    first = ai_backend.complete(a["id"], "tutor:explain", "SYS", "Seite 3 von Konto A", cache=True, request_id="a1")
    other = ai_backend.complete(b["id"], "tutor:explain", "SYS", "Seite 3 von Konto B", cache=True, request_id="b1")
    same = ai_backend.complete(b["id"], "tutor:explain", "SYS", "Seite 3 von Konto A", cache=True, request_id="b2")
    assert first.model != "cache" and other.model != "cache" and fakes["openai"].calls == 2
    assert same.model == "cache" and same.text == first.text and same.credits_charged == 0
    for schema in ({"type": "object"}, None):
        c = ai_backend.complete(b["id"], "tutor:ask", "SYS", "Seite 3 von Konto A", schema=schema, cache=True, request_id=f"z{schema}")
        assert c.model != "cache", "anderer Zweck: anderer Schluessel"


def test_p9_01_cache_hit_still_needs_consent(hosted, table_prices, monkeypatch):
    """Ein Treffer umgeht die Einwilligung nicht: _Call.__init__ prueft sie vor dem Zwischenspeicher (prepare)."""
    from app import ai_backend, ai_consent
    install(monkeypatch, {"openai": Fake("openai")})
    ai_backend.complete(None, "tutor:explain", "SYS", "gleich", cache=True, request_id="c1")

    def refuse(library=False):
        raise ai_backend.AIUnavailable("ai_consent_required", "Einwilligung fehlt", 428)
    monkeypatch.setattr(ai_consent, "require_hosted", refuse)
    with pytest.raises(ai_backend.AIUnavailable) as e:
        ai_backend.complete(None, "tutor:explain", "SYS", "gleich", cache=True, request_id="c2")
    assert e.value.code == "ai_consent_required"


# ---------------------------------------------------------------- P9-02 (#247, #249): Transaktionen

def test_p9_02_bookings_are_committed_for_other_connections(hosted, table_prices, monkeypatch):
    """Autocommit (billing.connect: isolation_level=None), Credits in eigener BEGIN-IMMEDIATE/COMMIT-Transaktion: nach
    succeed sieht eine fremde Verbindung Protokoll, Credits und Zwischenspeicher - nichts haengt an einer offenen Transaktion."""
    from app import accounts, ai_backend, billing
    conn = billing.connect()
    try:
        assert conn.isolation_level is None
    finally:
        conn.close()
    u, _ = user(hosted, "commit@beispiel.de", plan="pro_ai")
    install(monkeypatch, {"openai": Fake("openai")})
    ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage", cache=True, request_id="t1")
    other = sqlite3.connect(accounts.db_path())
    try:
        assert other.execute("SELECT state FROM credit_ledger WHERE user_id=?", (u["id"],)).fetchone() == ("settled",)
        assert other.execute("SELECT state FROM ai_usage_log WHERE user_id=?", (u["id"],)).fetchone() == ("done",)
        assert other.execute("SELECT COUNT(*) FROM ai_cache").fetchone()[0] == 1
    finally:
        other.close()


def test_p9_02_failure_inside_succeed_heals_through_housekeeping(hosted, table_prices, monkeypatch):
    """#253: wirft das Abrechnen selbst (succeed), ruft complete crashed() NICHT (der Anbieter hat schon gerechnet; eine
    Rueckbuchung waere falsch). Die Credits-Reservierung bleibt stehen und verfaellt nach STALE_MINUTES ohne Belastung."""
    from app import ai_backend, credits
    u, _ = user(hosted, "succeed@beispiel.de", plan="pro_ai")
    install(monkeypatch, {"openai": Fake("openai")})
    real = credits.settle
    monkeypatch.setattr(credits, "settle", lambda *a, **k: (_ for _ in ()).throw(sqlite3.OperationalError("disk I/O error")))
    with pytest.raises(sqlite3.OperationalError):
        ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage", request_id="s1")
    monkeypatch.setattr(credits, "settle", real)
    led, log = _ledger(u["id"])
    assert led[0][0] == "reserved" and log[0][0] == "done", (led, log)
    conn = credits.connect()
    try:
        credits.balance(conn, u["id"], datetime.now(timezone.utc) + timedelta(minutes=credits.STALE_MINUTES + 1))
    finally:
        conn.close()
    assert _ledger(u["id"])[0][0][0] == "expired" and month(u["id"])[1:] == (0, 0)


# ---------------------------------------------------------------- P9-03 (#245): Reservierung = Obergrenze?

def test_p9_03_credits_hold_the_ceiling_pool_holds_the_fixed_reserve(hosted, table_prices, monkeypatch):
    """Credits je Konto: reserviert wird die harte Obergrenze des teuersten Modells der Kette (self.ceiling, in Credits).
    Becken des Dienstes: fest RESERVE_MICROEUR (Produktentscheidung, siehe P8-06) - kein Aufrufer setzt budget_reserve."""
    from app import ai_backend, ai_prices, credits
    u, _ = user(hosted, "decke@beispiel.de", plan="pro_ai")
    seen = {}

    class Peek(Fake):
        def complete(self, system, prompt, schema=None, **opts):
            conn = credits.connect()
            try:
                seen["held"] = conn.execute("SELECT reserved FROM credit_ledger WHERE user_id=?", (u["id"],)).fetchone()[0]
                seen["pool"] = conn.execute("SELECT state, cost_microeur FROM ai_usage_log WHERE user_id=?", (u["id"],)).fetchone()
            finally:
                conn.close()
            return super().complete(system, prompt, schema, **opts)
    install(monkeypatch, {"openai": Peek("openai"), "anthropic": Peek("anthropic")})
    rid = rid_for("tutor:ask", "openai", configured={"openai", "anthropic"})
    ai_backend.complete(u["id"], "tutor:ask", "SYS", "Frage " * 300, request_id=rid)
    out = ai_backend.max_output("tutor:ask")
    worst = max(ai_prices.worst_case_microeur(m, "SYS", "Frage " * 300, out) for m in (MODELS["openai"], MODELS["anthropic"]))
    assert seen["held"] == ai_prices.credits_for(worst), "Credits: Obergrenze ueber die ganze Kette"
    assert seen["pool"] == ("reserved", ai_backend.RESERVE_MICROEUR)


# ---------------------------------------------------------------- P9-04 (#255, #256, #257): Sperre gegen Doppeltes

def test_p9_04_lock_outlives_the_longest_answer_and_has_an_owner(hosted):
    from app import ai_backend, ai_providers
    a = ai_backend.acquire("thema", "u1", now=T0)
    assert a
    assert ai_backend.INFLIGHT_STALE_S > ai_providers.DEADLINE_S * 2, "TTL deutlich ueber der Frist einer Antwort"
    assert not ai_backend.acquire("thema", "u2", now=T0 + timedelta(seconds=ai_providers.DEADLINE_S + 60)), \
        "eine noch laufende Generierung (knapp ueber DEADLINE_S) darf nicht als verwaist gelten"
    late = T0 + timedelta(seconds=ai_backend.INFLIGHT_STALE_S + 1)
    b = ai_backend.acquire("thema", "u2", now=late)
    assert b and b != a
    ai_backend.release("thema", a)                       # der verspaetete alte Arbeiter
    assert not ai_backend.acquire("thema", "u3", now=late), "alter Besitzer darf die neue Sperre nicht loeschen"
    ai_backend.release("thema", b)
    assert ai_backend.acquire("thema", "u3", now=late)


class _Clock:
    def __init__(self):
        self.t, self.sleeps = 1000.0, []

    def monotonic(self):
        return self.t

    def sleep(self, s):
        self.sleeps.append(s)
        self.t += max(s, 0.001)


@pytest.mark.parametrize("timeout_s, poll_s", [(float("inf"), 0.0), (1e12, -1.0), (float("nan"), float("nan")), (5.0, 0.0)])
def test_p9_04_wait_for_is_bounded_and_never_busy_loops(hosted, monkeypatch, timeout_s, poll_s):
    """library_api reicht `wait_s` des Clients durch: inf haette einen Thread fuer immer gebunden, poll 0 = Dauerschleife."""
    from app import ai_backend
    assert ai_backend.acquire("busy", "u1")
    clock = _Clock()
    monkeypatch.setattr(ai_backend, "time", clock)
    assert ai_backend.wait_for("busy", timeout_s=timeout_s, poll_s=poll_s) is False
    assert clock.t - 1000.0 <= ai_backend.WAIT_MAX_S + 1
    assert clock.sleeps and min(clock.sleeps) >= ai_backend.WAIT_POLL_MIN_S


def test_p9_04_wait_for_treats_an_orphaned_lock_as_gone(hosted):
    from app import ai_backend
    assert ai_backend.acquire("alt", "u1", now=datetime.now(timezone.utc) - timedelta(seconds=ai_backend.INFLIGHT_STALE_S + 5))
    assert ai_backend.wait_for("alt", timeout_s=0.5) is True, "eine verwaiste Sperre loest acquire ohnehin auf"


# ---------------------------------------------------------------- P9-05 (#261, #262): EU-Adresse

@pytest.mark.parametrize("url", ["https://api.example.com/v1", "https://openrouter.ai/api/v1", "https://api.scaleway.ai.evil.io/v1"])
def test_p9_05_hosted_compat_provider_only_on_listed_eu_hosts(hosted, url):
    from app import ai_providers
    from app.ai_backend import AIUnavailable
    with pytest.raises(AIUnavailable) as e:
        ai_providers.OpenAICompatProvider(url, "k", "deepseek-v4.1-flash-1017")
    assert e.value.code == "ai_not_configured"
    assert ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m").base_url == "https://api.scaleway.ai/v1"


def test_p9_05_local_mode_keeps_other_https_hosts():
    from app import ai_providers
    assert ai_providers.OpenAICompatProvider("https://mein-test.example/v1", "k", "m").base_url == "https://mein-test.example/v1"


# ---------------------------------------------------------------- P9-06 (#265, #266, #269): Lesegrenzen

class _FakeHttpx:
    """Ersatz fuer das Modul httpx (im Test ohne Netz, auch ohne installiertes httpx)."""
    class HTTPError(Exception):
        pass

    @staticmethod
    def Timeout(*a, **k):
        return None


class _FakeResponse:
    def __init__(self, status, chunks, counter):
        self.status_code, self.chunks, self.counter = status, chunks, counter

    async def aiter_bytes(self):
        for c in self.chunks:
            self.counter.append(len(c))
            yield c

    async def aread(self):                     # wie httpx: liest alles
        return b"".join([c async for c in self.aiter_bytes()])

    async def aiter_lines(self):
        for line in b"".join([c async for c in self.aiter_bytes()]).decode().splitlines():
            yield line


class _FakeClient:
    def __init__(self, response):
        self.response = response

    def stream(self, *a, **k):
        resp = self.response

        class Ctx:
            async def __aenter__(self):
                return resp

            async def __aexit__(self, *exc):
                return False
        return Ctx()


def _mock_client(monkeypatch, status, chunks, counter):
    from app import ai_backend
    monkeypatch.setattr(ai_backend, "_httpx", lambda: _FakeHttpx)
    monkeypatch.setattr(ai_backend, "async_http_client", lambda: _FakeClient(_FakeResponse(status, chunks, counter)))


@pytest.mark.parametrize("which", ["compat", "responses"])
def test_p9_06_async_error_body_is_read_with_a_limit(monkeypatch, which):
    from app import ai_backend, ai_providers
    counter = []
    chunk = b"x" * 65_536
    _mock_client(monkeypatch, 500, [chunk] * 64, counter)

    async def run():
        if which == "compat":
            p = ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m")
            return await p.acomplete("s", "p")
        return await ai_backend.stream_responses_async("https://api.openai.com/v1/responses", {}, {"model": "m"}, timeout=5)
    with pytest.raises(ai_backend.AIUnavailable) as e:
        asyncio.run(run())
    assert e.value.retryable and e.value.code == "ai_provider_error"
    assert sum(counter) <= ai_backend.ERROR_BODY_BYTES + len(chunk), f"{sum(counter)} Bytes gelesen statt hoechstens ~16 KiB"


def test_p9_06_streamed_text_has_an_upper_bound(monkeypatch):
    """Ein defekter Anbieter, der ohne Ende Text schickt: abbrechen (angenommen -> Obergrenze), nicht den Speicher fuellen."""
    from app import ai_backend, ai_providers
    monkeypatch.setattr(ai_backend, "MAX_STREAM_TEXT_CHARS", 1000)
    events = [{"choices": [{"delta": {"content": "y" * 300}}]} for _ in range(10)]
    with pytest.raises(ai_backend.AIUnavailable) as e:
        ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m", transport=Transport(lines=lines_of(events))).complete("s", "p")
    assert e.value.started and not e.value.retryable
    consumer = ai_backend._ResponsesConsumer()
    with pytest.raises(ai_backend.AIUnavailable) as e:
        for _ in range(10):
            consumer.feed(json.dumps({"type": "response.output_text.delta", "delta": "y" * 300}))
    assert e.value.code == "ai_provider_error"


# ---------------------------------------------------------------- P9-07 (#254, #251): Abbruch und Absturz

def test_p9_07_cancelled_async_request_releases_its_reservation(hosted, table_prices, monkeypatch):
    from app import ai_backend
    u, _ = user(hosted, "abbruch@beispiel.de", plan="pro_ai")

    class Slow(Fake):
        entered = None

        async def acomplete(self, system, prompt, schema=None, **opts):
            self.calls += 1
            self.entered.set()
            await asyncio.sleep(30)
    slow = Slow("openai")
    install(monkeypatch, {"openai": slow})

    async def run():
        slow.entered = asyncio.Event()
        task = asyncio.create_task(ai_backend.complete_async(u["id"], "tutor:explain", "SYS", "Frage", request_id="x1"))
        await asyncio.wait_for(slow.entered.wait(), 10)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    asyncio.run(run())
    led, log = _ledger(u["id"])
    assert led == [("refunded", led[0][1], 0)] and log == [("failed", 0)], (led, log)
    assert month(u["id"])[1:] == (0, 0), "keine Reservierung bleibt bis zum Aufraeumen stehen"


def test_p9_07_unexpected_error_refunds_like_before(hosted, table_prices, monkeypatch):
    """#251 Produktentscheidung (dokumentiert): ein unerwarteter Fehler im Anbieter-Adapter gibt die Credits zurueck."""
    from app import ai_backend
    u, _ = user(hosted, "absturz@beispiel.de", plan="pro_ai")

    def boom():
        raise RuntimeError("Adapterfehler")
    install(monkeypatch, {"openai": Fake("openai", error=boom)})
    with pytest.raises(RuntimeError):
        ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage", request_id="r1")
    led, log = _ledger(u["id"])
    assert led[0][0] == "refunded" and log == [("failed", 0)]


# ---------------------------------------------------------------- P9-08 (#271): Strom ohne Abschluss

def test_p9_08_compat_stream_without_finish_reason_is_not_a_complete_answer():
    from app import ai_providers
    from app.ai_backend import AIUnavailable
    cut = lines_of([{"choices": [{"delta": {"content": "Die Antwort beginnt"}}]}], done=False)
    with pytest.raises(AIUnavailable) as e:
        ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m", transport=Transport(lines=cut)).complete("s", "p")
    assert e.value.started and not e.value.retryable and e.value.billed is None, "Nutzung unbekannt: Obergrenze, kein Ersatz"
    with_usage = lines_of([{"choices": [{"delta": {"content": "halb"}}]},
                           {"choices": [], "usage": {"prompt_tokens": 7, "completion_tokens": 3}}])
    with pytest.raises(AIUnavailable) as e:
        ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m", transport=Transport(lines=with_usage)).complete("s", "p")
    assert e.value.billed.output_tokens == 3
    ok = lines_of([{"choices": [{"delta": {"content": "fertig"}, "finish_reason": "stop"}]},
                   {"choices": [], "usage": {"prompt_tokens": 7, "completion_tokens": 3}}])
    c = ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m", transport=Transport(lines=ok)).complete("s", "p")
    assert c.text == "fertig" and c.usage_known


# ---------------------------------------------------------------- Einzelzeilen 242-271 ohne eigenen Auftrag

@pytest.mark.parametrize("raw", [-5, 0, None, 10 ** 9])
def test_242_max_output_tokens_stays_positive_and_bounded(hosted, table_prices, monkeypatch, raw):
    from app import ai_backend
    fake = Fake("openai")
    install(monkeypatch, {"openai": fake})
    ai_backend.complete(None, "tutor:explain", "SYS", "Frage", request_id=f"m{raw}", max_output_tokens=raw)
    assert fake.opts[0]["max_output_tokens"] == ai_backend.max_output("tutor:explain")


def test_243_chain_is_never_empty(hosted, monkeypatch):
    from app import ai_backend
    install(monkeypatch, {})
    with pytest.raises(ai_backend.AIUnavailable) as e:
        ai_backend.complete(None, "tutor:explain", "SYS", "Frage")
    assert e.value.code == "ai_not_configured"


def test_246_every_real_provider_takes_the_options():
    from app import ai_backend, ai_providers
    for cls in (ai_backend.OpenAIProvider, ai_backend.ChatGPTProvider, ai_providers.OpenAICompatProvider, ai_providers.AnthropicProvider):
        assert cls.supports_options is True, cls


@pytest.mark.parametrize("raw, want", [(None, 0), ("12", 12), (-4, 0), ("abc", 0), (3.9, 3), ({}, 0)])
def test_258_usage_numbers(raw, want):
    from app import ai_providers
    assert ai_providers._n(raw) == want


def test_259_guarded_stops_after_the_deadline(monkeypatch):
    from app import ai_providers
    clock = iter([0.0, 1.0, 2.0, 9999.0])
    monkeypatch.setattr(ai_providers.time, "monotonic", lambda: next(clock))
    with pytest.raises(TimeoutError):
        list(ai_providers.guarded(iter(["a", "b", "c"]), deadline_s=10))


@pytest.mark.parametrize("status, retry", [(401, True), (403, True), (408, True), (429, True), (500, True), (400, False), (404, False)])
def test_260_http_errors_before_the_answer_bill_nothing(status, retry):
    from app import ai_providers
    e = ai_providers.http_error("X", status, "nein")
    assert e.retryable is retry and e.billed is None and not e.started


def test_267_270_usage_known_and_broken_stream():
    from app import ai_providers
    p = ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m")
    assert not p._completion("t", {}, "m", 0).usage_known and p._completion("t", {"prompt_tokens": 1}, "m", 0).usage_known
    st = ai_providers._CompatState(p, "X", 0, None)
    assert st.broken().started


# ================================================================== PAKET 10 (272-301)

@pytest.mark.parametrize("w", ["inf", "-inf", "nan", "1e400", "0", "-3", "1e300"])
def test_p10_01_route_weights_must_be_finite_and_bounded(monkeypatch, w):
    from app import ai_router
    for raw in (f"openai:{w},anthropic:25", [["openai", float(w)], ["anthropic", 25]], {"openai": float(w), "anthropic": 25}):
        assert ai_router.parse_route(raw) == [(ai_router.Choice("anthropic"), 25.0)], (raw, ai_router.parse_route(raw))
    monkeypatch.setenv("LERNAPP_AI_ROUTES", json.dumps({"default": f"openai:{w},anthropic:25"}))
    share = ai_router.expected_share()
    assert all(math.isfinite(v) for v in share.values()), share
    picks = {ai_router.chain("tutor:summary", f"r{i}", configured={"openai", "anthropic"})[0][0].provider for i in range(50)}
    assert picks == {"anthropic"}


def test_p10_01_sum_of_large_weights_stays_finite():
    from app import ai_router
    r = ai_router.parse_route("openai:1e9,anthropic:1e9")
    assert math.isfinite(sum(w for _, w in r)) and len(r) == 2
    seen = {ai_router.pick(r, f"s{i}").provider for i in range(200)}
    assert seen == {"openai", "anthropic"}


def test_p10_02_expected_share_with_no_usable_provider_is_zero_not_a_crash(monkeypatch):
    from app import ai_router
    assert ai_router.expected_share(configured=set()) == {"deepseek": 0.0, "openai": 0.0, "anthropic": 0.0}
    monkeypatch.setenv("LERNAPP_AI_DISABLED", "openai,anthropic,deepseek")
    assert sum(ai_router.expected_share().values()) == 0
    monkeypatch.delenv("LERNAPP_AI_DISABLED")
    assert abs(sum(ai_router.expected_share().values()) - 1) < 1e-3


@pytest.mark.parametrize("rate", ["inf", "-inf", "nan", "1e400", "0", "-1", "abc"])
def test_p10_03_exchange_rate_must_be_finite(table_prices, monkeypatch, rate):
    from app import ai_prices
    monkeypatch.setenv("LERNAPP_AI_USD_EUR", rate)
    assert ai_prices.usd_to_eur() == 1.0
    p = ai_prices.price("gpt-6-luna")
    assert p is not None and math.isfinite(p.input_eur) and math.isfinite(p.output_eur)
    assert ai_prices.cost_microeur("gpt-6-luna", 10_000, 1000) >= 0
    assert ai_prices.estimate_credits("gpt-6-luna", "s", "p", 1000) >= 1


@pytest.mark.parametrize("pin, pout", [("inf", "1"), ("1", "inf"), ("nan", "1"), ("1e400", "1")])
def test_p10_03_legacy_prices_must_be_finite(monkeypatch, pin, pout):
    from app import ai_prices
    monkeypatch.setenv("LERNAPP_AI_PRICE_IN_EUR", pin)
    monkeypatch.setenv("LERNAPP_AI_PRICE_OUT_EUR", pout)
    assert ai_prices.legacy_eur() is None
    assert ai_prices.price("gpt-6-luna").source == "table"


def test_p10_03_absurd_but_finite_prices_close_the_ai(table_prices, monkeypatch):
    """Ein Wechselkurs von 1e300 laesst die Preise ueber jede sinnvolle Grenze steigen: fail closed (kein Preis -> keine KI),
    statt spaeter in round()/ceil() mit OverflowError abzustuerzen."""
    from app import ai_prices
    monkeypatch.setenv("LERNAPP_AI_USD_EUR", "1e300")
    assert not ai_prices.known("gpt-6-luna")
    assert ai_prices.worst_case_microeur("gpt-6-luna", "s", "p" * 10_000, 4000) == 0
    assert ai_prices.known("deepseek-v4.1-flash-1017"), "Euro-Preise haengen nicht am Kurs"


@pytest.mark.parametrize("value", [float("inf"), "Infinity", "NaN", -1, 1e9, "1e400"])
def test_p10_04_price_overrides_must_be_finite_non_negative_and_sane(table_prices, monkeypatch, value):
    from app import ai_prices
    raw = '{"gpt-6-luna": {"input": %s, "output": 1}, "neu-modell": {"input": %s, "output": 1}}' % (
        json.dumps(value) if not isinstance(value, float) or math.isfinite(value) else "Infinity", json.dumps(value))
    monkeypatch.setenv("LERNAPP_AI_PRICES", raw)
    t = ai_prices.table()
    assert t["gpt-6-luna"]["input"] == ai_prices.PRICES["gpt-6-luna"]["input"], "ungueltige Ueberschreibung: Tabelle gilt"
    assert "neu-modell" not in t and not ai_prices.known("neu-modell"), "neues Modell ohne gueltigen Preis bleibt gesperrt"
    assert ai_prices.cost_microeur("gpt-6-luna", 10 ** 6, 10 ** 6) < 10 ** 7


def test_p10_05_zero_prices_are_accepted_but_still_reserve_one_credit(table_prices, monkeypatch):
    """Produktentscheidung (dokumentiert): 0 ist ein gueltiger Preis (z. B. ein kostenloses Testmodell). Die Reservierung
    bleibt mindestens 1 Credit, abgerechnet wird 0; das Verkleinern (max_output_within) laesst ein Nullpreis-Modell nicht zu."""
    from app import ai_prices
    monkeypatch.setenv("LERNAPP_AI_PRICES", '{"gratis": {"input": 0, "output": 0}}')
    assert ai_prices.known("gratis") and ai_prices.price("gratis").source == "env"
    assert ai_prices.estimate_credits("gratis", "s", "p", 4000) == 1
    assert ai_prices.cost_microeur("gratis", 10 ** 6, 10 ** 6) == 0
    assert ai_prices.max_output_within("gratis", "s", "p", 10 ** 6) == 0


def test_p10_06_route_model_must_belong_to_its_provider(monkeypatch):
    from app import ai_router
    assert ai_router.parse_route("openai/claude-sonnet-5-5:50,anthropic:50") == [(ai_router.Choice("anthropic"), 50.0)]
    assert ai_router.parse_route("anthropic/gpt-6-luna:50") == []
    keep = ai_router.parse_route("openai/gpt-5-mini:50,anthropic/eu.anthropic.claude-sonnet-5-5-v1:0:50")
    assert [c.provider for c, _ in keep] == ["openai", "anthropic"]


def test_p10_06_fallbacks_respect_disabled_providers_and_vision(monkeypatch):
    from app import ai_router
    monkeypatch.setenv("LERNAPP_AI_DISABLED", "anthropic")
    out, _ = ai_router.chain("tutor:ask", "r1", configured={"openai", "anthropic"})
    assert [c.provider for c in out] == ["openai"], "anthropic abgeschaltet: auch nicht als letzte Reserve"
    monkeypatch.delenv("LERNAPP_AI_DISABLED")
    out, _ = ai_router.chain("tutor:ask", "r1", configured={"openai", "anthropic"}, needs_vision=True,
                             vision_ok=lambda c: c.provider == "anthropic")
    assert [c.provider for c in out] == ["anthropic"]


def test_p10_06_backend_chain_models_match_their_prices(hosted, table_prices, monkeypatch):
    """Ersatzkette im Dienst: jedes Glied hat einen Preis des eigenen Anbieters; reserviert wird fuer das teuerste."""
    from app import ai_backend, ai_prices
    install(monkeypatch, {"openai": Fake("openai"), "anthropic": Fake("anthropic")})
    call = ai_backend._Call(None, "tutor:ask", "SYS", "Frage", None, False, None, image=None, model_name=None,
                            max_output_tokens=None, request_id="k1", credits=False, rate_limit=True, on_delta=None,
                            keep_result=False, budget_reserve=None, library=False, route_hint=None, route_text=None, fresh=False)
    assert sorted(call.models) == sorted([MODELS["openai"], MODELS["anthropic"]])
    for p, m in zip(call.chain, call.models):
        assert ai_prices.provider_of(m) == p.label and ai_prices.known(m)


def _jpeg(w=640, h=480):
    sof = b"\xff\xc0" + struct.pack(">HBHHB", 17, 8, h, w, 3) + b"\x01\x22\x00\x02\x11\x01\x03\x11\x01"
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    return b"\xff\xd8" + app0 + sof + b"\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00" + b"\x00" * 32 + b"\xff\xd9"


def test_p10_07_jpeg_parser_reads_sizes_and_never_raises_on_garbage():
    from app import ai_prices
    good = _jpeg()
    assert ai_prices.image_size(good) == (640, 480)
    rnd = random.Random(20261108)
    samples = [good[:n] for n in range(len(good) + 1)]
    samples += [b"\xff\xd8\xff" + rnd.randbytes(rnd.randrange(0, 64)) for _ in range(20_000)]
    samples += [b"\xff\xd8\xff" + bytes([m]) + bytes([a, b]) + rnd.randbytes(8) for m in (0xC0, 0xE0, 0xD8, 0x01, 0xFF)
                for a in (0, 0xFF) for b in (0, 1, 2, 0xFF)]
    samples += [bytearray(good) for _ in range(2000)]
    for s in samples[-2000:]:
        for _ in range(3):
            s[rnd.randrange(len(s))] = rnd.randrange(256)
    samples += [b"\x89PNG\r\n\x1a\n" + rnd.randbytes(rnd.randrange(0, 40)) for _ in range(2000)]
    for s in samples:
        got = ai_prices.image_size(bytes(s))
        assert got is None or (len(got) == 2 and all(isinstance(v, int) and v > 0 for v in got)), (s, got)


@pytest.mark.parametrize("size", [(100_000, 1), (1, 100_000), (2 ** 32 - 1, 1), (2 ** 32 - 1, 2 ** 32 - 1), (65_535, 65_535), (1, 1), (0, 0)])
def test_p10_08_image_estimate_stays_between_one_and_the_worst_case(size):
    from app import ai_prices
    for m in ai_prices.PRICES:
        for detail in ("high", "low"):
            t = ai_prices.image_tokens(m, size, detail)
            assert 1 <= t <= ai_prices.image_tokens_worst(m), (m, size, detail, t)


def test_272_273_default_anthropic_model_has_a_price():
    from app import ai_prices, ai_providers
    m = ai_providers.anthropic_model()
    assert ai_prices.known(m) and ai_prices.provider_of(m) == "anthropic" and ai_prices.price(m).vision
