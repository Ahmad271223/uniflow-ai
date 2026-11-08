"""Lastfestigkeit der StudiNow-KI im Dienst (08.11.2026, docs/release/BETRIEB.md "Kapazitaet und Lastgrenzen"):
asynchrone KI-Endpunkte, die die uebrigen Endpunkte nicht blockieren; Notbremse LERNAPP_AI_CONCURRENCY (503 +
Retry-After); laufende Monatssummen statt Summen ueber den ganzen Monat; Zeitlimit 90 s; eine Wiederholung bei
Netzfehler/5xx; "KI gerade ausgelastet" bei 429 des Anbieters; accounts.db mit WAL und synchronous=NORMAL."""
import asyncio
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest
from conftest import asgi_call
from test_ai_abuse import scaled_budgets, trial_account, tutor
from test_ai_routing import Fake, MODELS, install, rid_for, table_prices  # noqa: F401 - Fixture
from test_subscriptions import FakeAI, _j, hosted, user  # noqa: F401 - Fixture

ROOT = Path(__file__).resolve().parents[1]


async def asgi_acall(app, method, path, body=None, headers=None):
    """Wie conftest.asgi_call, aber innerhalb einer laufenden Ereignisschleife (mehrere Aufrufe gleichzeitig)."""
    hdrs = [(b"host", b"test"), (b"content-type", b"application/json")]
    for k, v in (headers or {}).items():
        hdrs.append((k.lower().encode(), v.encode()))
    raw = body.encode() if isinstance(body, str) else (body or b"")
    hdrs.append((b"content-length", str(len(raw)).encode()))
    scope = {"type": "http", "asgi": {"version": "3.0", "spec_version": "2.4"}, "http_version": "1.1", "method": method, "scheme": "http",
             "path": path, "raw_path": path.encode(), "query_string": b"", "headers": hdrs, "client": ("127.0.0.1", 5000), "server": ("test", 80)}
    out = {"status": None, "headers": [], "body": b""}
    sent = {"done": False}

    async def receive():
        if not sent["done"]:
            sent["done"] = True
            return {"type": "http.request", "body": raw, "more_body": False}
        return {"type": "http.disconnect"}

    async def send(m):
        if m["type"] == "http.response.start":
            out["status"] = m["status"]; out["headers"] = m["headers"]
        elif m["type"] == "http.response.body":
            out["body"] += m.get("body", b"")
    await app(scope, receive, send)
    return out["status"], out["headers"], out["body"]


class AsyncFake:
    """Anbieter mit asynchronem Weg (wie OpenAIProvider.acomplete): antwortet nach `delay` Sekunden, ohne Thread."""

    def __init__(self, delay: float = 0.0):
        self.delay, self.calls, self.inflight, self.peak = delay, 0, 0, 0

    async def acomplete(self, system, prompt, schema=None, **opts):
        from app.ai_backend import Completion
        self.calls += 1
        self.inflight += 1
        self.peak = max(self.peak, self.inflight)
        try:
            await asyncio.sleep(self.delay)
        finally:
            self.inflight -= 1
        return Completion("Erklärung: asynchron.", 120, 40, "fake-async")

    def complete(self, *a, **k):
        raise AssertionError("der Dienst muss den asynchronen Weg nehmen")


# ---------------------------------------------------------------- 1. KI blockiert die uebrigen Endpunkte nicht

def test_ai_questions_run_async_and_leave_other_endpoints_fast(hosted, monkeypatch):
    """60 KI-Fragen, die je 1 s beim Anbieter warten, laufen gleichzeitig (ein Anbieter-Aufruf je Frage, alle offen);
    ein Abo-Abruf dazwischen antwortet in Millisekunden - vorher haette jede Frage einen der 40 Threads belegt."""
    from app import ai_backend
    fake = AsyncFake(delay=1.0)
    ai_backend.set_provider(fake)
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "1000")                 # ein Konto stellt hier alle Fragen
    monkeypatch.setenv("LERNAPP_CREDITS_TRIAL", "100000")
    _, h = trial_account(hosted, "async@beispiel.de")

    async def scenario():
        ais = [asyncio.create_task(asgi_acall(hosted, "POST", "/api/ai/tutor", headers=h,
                                              body=json.dumps({"mode": "explain", "page_text": f"Seite {i}", "request_id": f"as-{i}"})))
               for i in range(60)]
        await asyncio.sleep(0.4)                       # alle Fragen sind beim Anbieter
        t0 = time.monotonic()
        st, _, _ = await asgi_acall(hosted, "GET", "/api/entitlements", headers=h)
        quick = time.monotonic() - t0
        t1 = time.monotonic()
        results = await asyncio.gather(*ais)
        return st, quick, time.monotonic() - t1, results
    st, quick, rest, results = asyncio.run(scenario())
    assert st == 200 and quick < 0.5, f"Abo-Stand wartete {quick:.2f} s hinter den KI-Fragen"
    assert all(r[0] == 200 for r in results), [r[0] for r in results]
    assert fake.calls == 60 and fake.peak >= 50, (fake.calls, fake.peak)    # gleichzeitig offen, nicht nacheinander
    assert rest < 2.0, f"60 Fragen zu je 1 s brauchten zusammen {rest:.1f} s - sie liefen nicht parallel"


def test_relay_and_document_steps_take_the_async_path_too(hosted):
    from app import ai_backend
    fake = AsyncFake()
    ai_backend.set_provider(fake)
    _, h = trial_account(hosted, "relay-async@beispiel.de")
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/relay", headers=h,
                         body=json.dumps({"task": "tutor:explain", "prompt": "Erkläre Matrizen", "request_id": "ra-1"})))
    assert st == 200 and d["answer"].startswith("Erklärung") and d["model"] == "fake-async", d
    assert fake.calls == 1


def test_sync_fake_providers_still_work_through_the_async_endpoints(hosted):
    """Attrappen ohne acomplete (alle bisherigen Tests) laufen in einem eigenen Thread-Begrenzer."""
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    _, h = trial_account(hosted, "sync-fake@beispiel.de")
    st, d = tutor(hosted, h, "Vektoren")
    assert st == 200 and d["answer"].startswith("Erklärung"), d


# ---------------------------------------------------------------- 2. Notbremse LERNAPP_AI_CONCURRENCY

def test_over_the_concurrency_limit_the_service_answers_503_with_retry_after(hosted, monkeypatch):
    from app import ai_async, ai_backend
    ai_backend.set_provider(FakeAI())
    _, h = trial_account(hosted, "voll@beispiel.de")
    assert ai_async.concurrency_limit() == 5000, "Standard: 5000 je Prozess, nur Notbremse"
    monkeypatch.setenv("LERNAPP_AI_CONCURRENCY", "2")
    monkeypatch.setattr(ai_async, "_inflight", 2)       # zwei Fragen laufen in diesem Prozess
    st, headers, body = asgi_call(hosted, "POST", "/api/ai/tutor", headers=h,
                                  body=json.dumps({"mode": "explain", "page_text": "Voll", "request_id": "voll-1"}))
    d = json.loads(body)
    assert (st, d["code"]) == (503, "ai_overloaded") and "ausgelastet" in d["detail"], d
    assert dict(headers).get(b"retry-after") == b"3" and d["retry_after"] == 3
    monkeypatch.setattr(ai_async, "_inflight", 0)
    assert tutor(hosted, h, "Voll")[0] == 200, "unter der Grenze laeuft es"
    assert ai_async.inflight() == 0, "der Platz wird immer freigegeben"


# ---------------------------------------------------------------- 3. Laufende Monatssummen

def test_month_totals_follow_every_change_of_the_usage_log(hosted):
    from app import ai_backend
    conn = ai_backend.connect()
    try:
        conn.execute("INSERT INTO ai_usage_log(user_id, period, purpose, cost_microeur, trial, library, state, created_at) VALUES "
                     "('u1','2026-11','tutor:explain',20000,0,0,'reserved','2026-11-08T10:00:00')")
        conn.execute("INSERT INTO ai_usage_log(user_id, period, purpose, cost_microeur, trial, library, state, created_at) VALUES "
                     "('u2','2026-11','tutor:explain',30000,1,0,'done','2026-11-08T10:00:00')")
        conn.execute("INSERT INTO ai_usage_log(user_id, period, purpose, cost_microeur, trial, library, state, created_at) VALUES "
                     "(NULL,'2026-11','test_generation',40000,0,1,'done','2026-11-08T10:00:00')")
        assert (ai_backend._pool_total(conn, "2026-11", "paid"), ai_backend._pool_total(conn, "2026-11", "trial"),
                ai_backend._library_pool(conn, "2026-11")) == (20000, 30000, 40000)
        assert ai_backend._user_total(conn, "2026-11", "u1") == 20000
        # Abrechnung: reserviert 20000 -> echte Kosten 7000; Fehler -> 0 und state failed
        log_id = conn.execute("SELECT id FROM ai_usage_log WHERE user_id='u1'").fetchone()[0]
        from app.ai_backend import Completion
        ai_backend.settle(conn, log_id, Completion("x", 100, 10, "m"), "openai", "m", cost_override=7000)
        assert ai_backend._pool_total(conn, "2026-11", "paid") == 7000 and ai_backend._user_total(conn, "2026-11", "u1") == 7000
        conn.execute("UPDATE ai_usage_log SET state='failed', cost_microeur=0 WHERE user_id='u2'")
        assert ai_backend._pool_total(conn, "2026-11", "trial") == 0
        conn.execute("UPDATE ai_usage_log SET state='done', cost_microeur=500 WHERE user_id='u2'")
        assert ai_backend._pool_total(conn, "2026-11", "trial") == 500
        conn.execute("DELETE FROM ai_usage_log WHERE library=1")
        assert ai_backend._library_pool(conn, "2026-11") == 0
        assert ai_backend.month_totals_match_log(conn)
        # von Hand verstellt -> der Neuaufbau beim Start stellt die Summen wieder her
        conn.execute("UPDATE ai_usage_month SET cost_microeur=999999")
        assert not ai_backend.month_totals_match_log(conn)
        ai_backend.rebuild_month_totals(conn)
        assert ai_backend.month_totals_match_log(conn) and ai_backend._pool_total(conn, "2026-11", "paid") == 7000
    finally:
        conn.close()


def test_budget_checks_give_the_same_answers_as_the_old_month_sums(hosted, monkeypatch):
    """Dieselben Faelle wie tests/test_ai_abuse.py (Probe-Becken, Gesamtbecken, je Konto): die Antworten der Reservierung
    stimmen mit einer Summe ueber den ganzen Monat ueberein - nur schneller."""
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    scaled_budgets(monkeypatch, total="0.1", user_="1", trial="0.04")          # ein Aufruf 0,016 EUR, Reservierung 0,02 EUR
    _, h = trial_account(hosted, "probe-summe@beispiel.de")
    codes = [tutor(hosted, h, f"Probe {i}")[0] for i in range(4)]
    assert codes == [200, 200, 429, 429], codes                                 # 0,04 EUR Probe-Becken: zwei Fragen
    conn = ai_backend.connect()
    try:
        period = ai_backend._now().strftime("%Y-%m")
        summed = conn.execute("SELECT COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE period=? AND state<>'failed' AND trial=1 AND library=0",
                              (period,)).fetchone()[0]
        assert ai_backend._pool_total(conn, period, "trial") == summed == 32000
        assert ai_backend.month_totals_match_log(conn)
        log_id = ai_backend.reserve(conn, None, "tutor:explain")                # zahlendes Becken (0,1 EUR): frei
        assert ai_backend._pool_total(conn, period, "paid") == 20000
        ai_backend.settle(conn, log_id, None)                                    # Fehler: Reservierung weg
        assert ai_backend._pool_total(conn, period, "paid") == 0
        for _ in range(5):
            ai_backend.reserve(conn, None, "tutor:explain")
        with pytest.raises(ai_backend.AIUnavailable) as e:
            ai_backend.reserve(conn, None, "tutor:explain")                     # 6 x 0,02 > 0,1 EUR
        assert e.value.code == "ai_budget_exhausted"
        assert ai_backend.month_totals_match_log(conn)
    finally:
        conn.close()


def test_reservation_happens_before_the_provider_and_blocks_the_budget_under_concurrency(hosted, monkeypatch):
    """Harte Kostenbremse: 30 gleichzeitige Fragen gegen ein Budget fuer genau 5 Reservierungen - nie mehr als 5 kommen
    zum Anbieter, der Rest bekommt 503 ai_budget_exhausted, ohne dass der Anbieter gerufen wurde."""
    from app import accounts, ai_backend
    fake = AsyncFake(delay=0.3)
    ai_backend.set_provider(fake)
    monkeypatch.setenv("LERNAPP_AI_PRICE_IN_EUR", "100")
    monkeypatch.setenv("LERNAPP_AI_PRICE_OUT_EUR", "100")
    monkeypatch.setenv("LERNAPP_AI_BUDGET_EUR", "0.1")                        # 5 x 0,02 EUR Reservierung
    monkeypatch.setenv("LERNAPP_AI_USER_BUDGET_EUR", "10")
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "1000")
    monkeypatch.setenv("LERNAPP_CREDITS_PRO_AI", "100000")
    u, h = user(hosted, "bremse@beispiel.de", plan="pro_ai")

    async def scenario():
        return await asyncio.gather(*(asgi_acall(hosted, "POST", "/api/ai/tutor", headers=h,
                                                 body=json.dumps({"mode": "explain", "page_text": f"Budget {i}", "request_id": f"b-{i}"}))
                                      for i in range(30)))
    results = asyncio.run(scenario())
    codes = sorted(json.loads(b).get("code") or "ok" for st, _, b in results)
    assert codes.count("ok") == 5 and codes.count("ai_budget_exhausted") == 25, codes
    assert fake.calls == 5, "nur reservierte Fragen erreichen den Anbieter"


# ---------------------------------------------------------------- 4. Zeitlimit, Wiederholung, 429 des Anbieters

def test_provider_timeout_is_90_seconds_and_configurable(monkeypatch):
    from app import ai_backend, ai_providers
    monkeypatch.delenv("LERNAPP_AI_TIMEOUT_S", raising=False)
    assert ai_backend.timeout_s() == 90
    assert ai_backend.OpenAIProvider("k", "m").timeout == 90
    assert ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m").timeout == 90
    assert ai_providers.AnthropicProvider("m", client=object()).timeout == 90
    monkeypatch.setenv("LERNAPP_AI_TIMEOUT_S", "45")
    assert ai_backend.timeout_s() == 45 and ai_backend.OpenAIProvider("k", "m").timeout == 45
    assert ai_backend.OpenAIProvider("k", "m", timeout=120).timeout == 120, "ausdruecklich gesetzt bleibt"


def test_network_error_or_5xx_is_retried_once_at_the_same_provider(hosted, table_prices, monkeypatch):
    from app import ai_backend, ai_providers
    u, _ = user(hosted, "wiederholung@beispiel.de", plan="pro_ai")

    def unreachable():
        return ai_backend.AIUnavailable("ai_provider_unreachable", "nicht erreichbar", 502, retryable=True)
    fakes = {"openai": Fake("openai", error=unreachable), "anthropic": Fake("anthropic")}
    install(monkeypatch, fakes)
    rid = rid_for("tutor:explain", "openai", configured=fakes)
    c = ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage", request_id=rid)
    assert c.provider == "anthropic" and (fakes["openai"].calls, fakes["anthropic"].calls) == (2, 1), "einmal wiederholt, dann Ersatz"
    # 5xx vor der Antwort ebenso; 429 (ausgelastet) und 401 nicht
    for status, expect in ((503, 2), (500, 2), (429, 1), (401, 1), (400, 1)):
        fakes = {"openai": Fake("openai", error=lambda s=status: ai_providers.http_error("Der KI-Anbieter", s, "")),
                 "anthropic": Fake("anthropic")}
        install(monkeypatch, fakes)
        rid = rid_for("tutor:explain", "openai", configured=fakes, prefix=f"s{status}")
        try:
            ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage", request_id=rid)
        except ai_backend.AIUnavailable:
            assert status == 400, status                                        # 400 ist kein Fall fuer Ersatz
        assert fakes["openai"].calls == expect, (status, fakes["openai"].calls)
    # nichts wird doppelt berechnet
    from app import credits
    conn = credits.connect()
    try:
        rows = conn.execute("SELECT state, COUNT(*) FROM credit_ledger WHERE user_id=? GROUP BY state", (u["id"],)).fetchall()
    finally:
        conn.close()
    assert dict(rows) == {"settled": 5, "refunded": 1}, rows


def test_slow_failures_are_not_retried(monkeypatch):
    """Ein Fehler nach langem Warten (Zeitlimit) wird nicht noch einmal 90 s lang probiert."""
    from app import ai_backend
    e = ai_backend.AIUnavailable("ai_provider_unreachable", "x", 502, retryable=True)
    assert e.quick_retry_ok()
    monkeypatch.setattr(ai_backend, "RETRY_FAST_S", 0.05)
    calls = []

    class Slow:
        def complete(self, system, prompt, schema=None, **_):
            calls.append(1)
            time.sleep(0.1)
            raise ai_backend.AIUnavailable("ai_provider_unreachable", "x", 502, retryable=True)
    ai_backend.set_provider(Slow())
    with pytest.raises(ai_backend.AIUnavailable):
        ai_backend.complete(None, "tutor:explain", "s", "p")
    assert len(calls) == 1


def test_provider_429_becomes_a_friendly_busy_message_with_retry_after(hosted, table_prices, monkeypatch):
    from app import ai_providers
    e = ai_providers.http_error("Der KI-Anbieter", 429, "Rate limit reached")
    assert (e.code, e.status, e.http_status, e.retryable) == ("ai_provider_busy", 503, 429, True)
    assert e.message == "Die KI ist gerade ausgelastet, bitte gleich noch einmal." and e.extra == {"retry_after": 5}
    u, h = user(hosted, "busy@beispiel.de", plan="pro_ai")
    fakes = {"openai": Fake("openai", error=lambda: ai_providers.http_error("Der KI-Anbieter", 429, "")),
             "anthropic": Fake("anthropic", error=lambda: ai_providers.http_error("Claude", 429, ""))}
    install(monkeypatch, fakes)
    rid = rid_for("tutor:explain", "openai", configured=fakes)
    st, headers, body = asgi_call(hosted, "POST", "/api/ai/tutor", headers=h,
                                  body=json.dumps({"mode": "explain", "page_text": "Voll", "request_id": rid}))
    d = json.loads(body)
    assert (st, d["code"]) == (503, "ai_provider_busy") and d["detail"] == ai_providers.BUSY_MESSAGE, d
    assert dict(headers).get(b"retry-after") == b"5"
    assert "Fehler" not in d["detail"]


# ---------------------------------------------------------------- 5. echter asynchroner Weg (httpx) gegen die Attrappe

def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


@pytest.fixture
def fake_openai():
    """tools/lasttest-ki-anbieter.py auf einem freien Port, Antwort sofort."""
    procs = []

    def start(status=200, delay=0.0):
        port = _free_port()
        p = subprocess.Popen([sys.executable, str(ROOT / "tools" / "lasttest-ki-anbieter.py"), "--port", str(port), "--delay", str(delay),
                              "--status", str(status), "--quiet"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs.append(p)
        end = time.monotonic() + 10
        while time.monotonic() < end:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)
        return f"http://127.0.0.1:{port}/v1"
    yield start
    for p in procs:
        p.kill()
        p.wait()


def test_openai_provider_streams_asynchronously_over_httpx(fake_openai):
    from app import ai_backend
    p = ai_backend.OpenAIProvider("sk-test", "gpt-6-luna", base_url=fake_openai())

    async def go():
        return await p.acomplete("SYS", "Was ist eine Matrix?", max_output_tokens=500, cache_key="studinow:tutor", user_tag="t")
    c = asyncio.run(go())
    assert c.text.startswith("Erklärung") and (c.input_tokens, c.output_tokens, c.model, c.provider) == (1500, 220, "gpt-6-luna", "openai")
    # 40 gleichzeitig auf einer Ereignisschleife, kein Thread
    async def many():
        return await asyncio.gather(*(p.acomplete("SYS", f"Frage {i}") for i in range(40)))
    t0 = time.monotonic()
    out = asyncio.run(many())
    assert len(out) == 40 and all(c.output_tokens == 220 for c in out) and time.monotonic() - t0 < 5


def test_async_provider_errors_map_like_the_sync_path(fake_openai):
    from app import ai_backend
    busy = ai_backend.OpenAIProvider("sk-test", "gpt-6-luna", base_url=fake_openai(status=429))
    with pytest.raises(ai_backend.AIUnavailable) as e:
        asyncio.run(busy.acomplete("SYS", "Frage"))
    assert (e.value.code, e.value.http_status, e.value.retryable, e.value.started) == ("ai_provider_busy", 429, True, False)
    down = ai_backend.OpenAIProvider("sk-test", "gpt-6-luna", base_url=f"http://127.0.0.1:{_free_port()}/v1")
    with pytest.raises(ai_backend.AIUnavailable) as e:
        asyncio.run(down.acomplete("SYS", "Frage"))
    assert (e.value.code, e.value.retryable) == ("ai_provider_unreachable", True) and e.value.quick_retry_ok()


# ---------------------------------------------------------------- 6. accounts.db: WAL, busy_timeout, synchronous=NORMAL

def test_accounts_db_runs_wal_with_normal_sync_and_busy_timeout(hosted):
    from app import accounts, billing
    conn = billing.connect()
    try:
        assert conn.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
        assert conn.execute("PRAGMA synchronous").fetchone()[0] == 1, "NORMAL"
        assert conn.execute("PRAGMA busy_timeout").fetchone()[0] == 15000
    finally:
        conn.close()
    with accounts.cursor() as conn:
        assert conn.execute("PRAGMA synchronous").fetchone()[0] == 1


def test_env_example_and_compose_know_the_load_switches():
    env = (ROOT / "deploy" / ".env.example").read_text(encoding="utf-8")
    for key in ("LERNAPP_AI_CONCURRENCY", "LERNAPP_AI_TIMEOUT_S", "LERNAPP_AI_DB_THREADS", "LERNAPP_AI_SYNC_THREADS"):
        assert f"{key}=" in env, key
    doc = (ROOT / "docs" / "release" / "BETRIEB.md").read_text(encoding="utf-8")
    assert "Kapazität und Lastgrenzen" in doc and "LERNAPP_AI_CONCURRENCY" in doc and "LERNAPP_AI_BUDGET_EUR" in doc
    assert "platform.openai.com" in doc and "nofile" in doc

