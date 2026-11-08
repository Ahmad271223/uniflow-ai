"""Externer Audit 08.11.2026, Pakete 6-8 (KI-Konfiguration, Streaming, Kostenkontrolle; app/ai_backend.py,
app/ai_providers.py, app/ai_prices.py). Bericht: docs/audit/AUDIT-2026-11-08-PAKET-6-8.md. Je Befund erst der
fehlschlagende Test, dann die kleinste Behebung; widerlegte Befunde nageln das richtige Verhalten fest. Keine echten
Anbieter, nur Attrappen."""
import io
import json
import sqlite3
import urllib.error
import urllib.request

import pytest
from test_ai_routing import Fake, MODELS, Transport, install, lines_of, table_prices  # noqa: F401 - Fixture
from test_subscriptions import hosted, user  # noqa: F401 - Fixture

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + (800).to_bytes(4, "big") + (600).to_bytes(4, "big") + b"\x08\x02\x00\x00\x00"


def _conn(tmp_path):
    conn = sqlite3.connect(tmp_path / "audit.db", isolation_level=None)
    from app import ai_backend
    ai_backend.ensure_schema(conn)
    return conn


# ---------------------------------------------------------------- P6-01: timeout_s ohne Obergrenze, inf stuerzt ab

@pytest.mark.parametrize("raw, want", [("inf", 90), ("nan", 90), ("-5", 5), ("100000", 600), ("abc", 90), ("", 90), ("45", 45)])
def test_p6_01_timeout_is_finite_and_bounded(monkeypatch, raw, want):
    from app import ai_backend
    monkeypatch.setenv("LERNAPP_AI_TIMEOUT_S", raw)
    assert ai_backend.timeout_s() == want


# ---------------------------------------------------------------- P6-03 / P7-01 / P7-02 / P8-04: Budget- und Ratenwerte

BUDGETS = [("LERNAPP_AI_BUDGET_EUR", "budget_microeur", 50_000_000), ("LERNAPP_AI_USER_BUDGET_EUR", "user_budget_microeur", 2_000_000),
           ("LERNAPP_AI_TRIAL_BUDGET_EUR", "trial_budget_microeur", 5_000_000),
           ("LERNAPP_AI_LIBRARY_BUDGET_EUR", "library_budget_microeur", 20_000_000)]


@pytest.mark.parametrize("env, fn, default", BUDGETS)
@pytest.mark.parametrize("raw", ["nan", "inf", "-inf", "-1", "abc", "", "1e400"])
def test_p7_01_budgets_fall_back_on_non_finite_or_negative_values(monkeypatch, env, fn, default, raw):
    from app import ai_backend
    monkeypatch.setenv(env, raw)
    assert getattr(ai_backend, fn)() == default
    monkeypatch.setenv(env, "0.5")
    assert getattr(ai_backend, fn)() == 500_000, "gueltige Werte gelten weiter"
    monkeypatch.setenv(env, "0")
    assert getattr(ai_backend, fn)() == 0, "0 = Becken zu (Absicht des Betreibers)"


@pytest.mark.parametrize("env, fn, default", [("LERNAPP_AI_RATE_PER_MINUTE", "rate_per_minute", 6), ("LERNAPP_AI_RATE_PER_HOUR", "rate_per_hour", 60)])
@pytest.mark.parametrize("raw", ["nan", "inf", "-1", "0", "abc", ""])
def test_p7_02_rates_are_positive_integers(monkeypatch, env, fn, default, raw):
    from app import ai_backend
    monkeypatch.setenv(env, raw)
    assert getattr(ai_backend, fn)() == default, "0 oder ungueltig wuerde sonst JEDE Anfrage sperren"
    monkeypatch.setenv(env, "12.9")
    assert getattr(ai_backend, fn)() == 12


def test_p7_01_reserve_survives_nan_budget_in_environment(hosted, monkeypatch, tmp_path):
    """Reproduktion des Audits: LERNAPP_AI_BUDGET_EUR=nan -> vorher ValueError beim int() mitten in der Reservierung."""
    from app import ai_backend
    monkeypatch.setenv("LERNAPP_AI_BUDGET_EUR", "nan")
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "inf")
    conn = _conn(tmp_path)
    try:
        conn.execute("CREATE TABLE entitlements (user_id TEXT, source TEXT, plan TEXT, expires_at TEXT, status TEXT)")
        assert ai_backend.reserve(conn, "u1", "tutor:explain") > 0
        assert conn.execute("SELECT state FROM ai_usage_log").fetchone()[0] == "reserved"
    finally:
        conn.close()


# ---------------------------------------------------------------- P6-02: Usage-Felder

def test_p6_02_usage_fields_become_non_negative_integers():
    from app.ai_backend import Completion
    c = Completion.from_usage("t", {"usage": {"input_tokens": 12.7, "output_tokens": -3, "input_tokens_details": {"cached_tokens": "abc"}}}, "m")
    assert (c.input_tokens, c.output_tokens, c.cached_tokens) == (12, 0, 0)
    assert c.usage_known, "Nutzung genannt (auch mit krummen Zahlen)"


# ---------------------------------------------------------------- P7-07: fehlende Nutzung darf nie kostenlos sein

def test_p7_07_missing_usage_is_unknown_not_zero():
    from app.ai_backend import Completion
    assert Completion.from_usage("x", {"output": []}, "m").usage_known is False
    assert Completion.from_usage("x", {"usage": {}}, "m").usage_known is False
    assert Completion.from_usage("x", {"usage": {"input_tokens": 0, "output_tokens": 0}}, "m").usage_known is True, "0 ist eine Angabe"
    assert Completion.from_usage("x", {"usage": {"output_tokens": 5}}, "m").usage_known is True


def test_p7_07_openai_answer_without_usage_is_billed_at_the_ceiling(hosted, monkeypatch, table_prices):
    """response.completed ohne usage: vorher 0 Tokens, usage_known=True -> Kosten 0, Credits frei. Jetzt gilt die Obergrenze."""
    from app import ai_backend, ai_prices
    done = {"type": "response.completed", "response": {"model": "gpt-6-luna", "output": [{"type": "message", "content": [{"type": "output_text", "text": "Antwort"}]}]}}
    t = Transport(lines=lines_of([done]))
    ai_backend.set_provider(ai_backend.OpenAIProvider("sk-test", "gpt-6-luna", transport=t))
    u, _ = user(hosted, "ohne-usage@beispiel.de", plan="pro_ai")
    c = ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage", request_id="nu-1", max_output_tokens=500)
    assert c.text == "Antwort" and c.usage_known is False
    assert c.credits_charged == c.credits_reserved == ai_prices.estimate_credits("gpt-6-luna", "SYS", "Frage", 500)
    conn = ai_backend.connect()
    try:
        cost = conn.execute("SELECT cost_microeur FROM ai_usage_log WHERE state='done'").fetchone()[0]
        assert cost == ai_prices.worst_case_microeur("gpt-6-luna", "SYS", "Frage", 500)
    finally:
        conn.close()


# ---------------------------------------------------------------- P6-06: reasoning_effort nur bekannte Werte

@pytest.mark.parametrize("raw, want", [("low", "low"), ("XHigh", "xhigh"), ("minimal", "minimal"), ("turbo", "low"), ("none", None), ("off", None), ("", None)])
def test_p6_06_reasoning_effort_allowlist(monkeypatch, raw, want):
    from app import ai_backend
    monkeypatch.setenv("LERNAPP_AI_REASONING_EFFORT", raw)
    assert ai_backend.reasoning_effort() == want
    monkeypatch.delenv("LERNAPP_AI_REASONING_EFFORT")
    assert ai_backend.reasoning_effort() == "low"


# ---------------------------------------------------------------- P6-04 / P7-03: Adresse des Anbieters im Dienst

@pytest.mark.parametrize("url", ["http://api.openai.com/v1", "https://evil.example/v1", "https://api.openai.com.evil.example/v1", "ftp://x",
                                 "http://127.0.0.1:9/v1"])
def test_p7_03_hosted_rejects_foreign_or_plain_http_openai_address(hosted, monkeypatch, url):
    from app import ai_backend
    monkeypatch.setenv("LERNAPP_OPENAI_API_KEY", "sk-test")
    monkeypatch.setenv("LERNAPP_AI_MODEL", "gpt-6-luna")
    monkeypatch.setenv("LERNAPP_OPENAI_BASE_URL", url)
    with pytest.raises(ai_backend.AIUnavailable) as e:
        ai_backend.build("openai")
    assert e.value.code == "ai_not_configured" and "sk-test" not in e.value.message


@pytest.mark.parametrize("url", ["", "https://api.openai.com/v1", "https://eu.api.openai.com/v1/", "https://EU.api.openai.com/v1"])
def test_p7_03_hosted_accepts_openai_addresses(hosted, monkeypatch, url):
    from app import ai_backend
    monkeypatch.setenv("LERNAPP_OPENAI_API_KEY", "sk-test")
    monkeypatch.setenv("LERNAPP_AI_MODEL", "gpt-6-luna")
    monkeypatch.setenv("LERNAPP_OPENAI_BASE_URL", url)
    p = ai_backend.build("openai")
    assert p.URL.startswith("https://") and p.URL.endswith("/responses") and "//responses" not in p.URL


def test_p7_03_local_mode_keeps_test_servers(monkeypatch):
    from app import ai_backend, config
    monkeypatch.setattr(config, "MODE", "local")
    monkeypatch.setenv("LERNAPP_OPENAI_API_KEY", "sk-test")
    monkeypatch.setenv("LERNAPP_AI_MODEL", "gpt-6-luna")
    monkeypatch.setenv("LERNAPP_OPENAI_BASE_URL", "http://127.0.0.1:8123/v1")
    assert ai_backend.build("openai").URL == "http://127.0.0.1:8123/v1/responses"


# ---------------------------------------------------------------- P7-04 / P6-07: Geheimnisse in Fehlertexten

def test_p7_04_scrub_masks_bearer_tokens_and_configured_secrets(monkeypatch):
    from app import ai_backend
    bearer = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.SYNTHETIC-SIGNATURE-123456"
    scaleway = "4f1c2d3e-5a6b-4c7d-8e9f-0a1b2c3d4e5f"
    monkeypatch.setenv("LERNAPP_DEEPSEEK_API_KEY", scaleway)
    monkeypatch.setenv("LERNAPP_ANTHROPIC_API_KEY", "ABSKQmVkcm9ja0FQSUtleS1zeW50aGV0aWMtMTIzNDU2Nzg5MA==")
    text = f"Authorization: Bearer {bearer}; key {scaleway}; sk-proj-ABCDEFGHIJKLMNOP; AKIAABCDEFGHIJKLMNOP; ABSKQmVkcm9ja0FQSUtleS1zeW50aGV0aWMtMTIzNDU2Nzg5MA=="
    out = ai_backend.scrub(text)
    for secret in (bearer, scaleway, "sk-proj-ABCDEFGHIJKLMNOP", "AKIAABCDEFGHIJKLMNOP", "ABSKQmVkcm9ja0FQSUtleS1zeW50aGV0aWMtMTIzNDU2Nzg5MA=="):
        assert secret not in out, out
    assert ai_backend.scrub("Fehler 429: zu viele Anfragen") == "Fehler 429: zu viele Anfragen", "harmloser Text bleibt"
    assert ai_backend.scrub("") == ""


def test_p7_04_provider_error_text_reaches_the_client_only_scrubbed(monkeypatch):
    """Die Endpunkte geben e.message als detail weiter (ai_async.http_error): der Text MUSS also sauber sein."""
    from app import ai_async, ai_backend
    token = "SYNTHETIC-bearer-token-0123456789abcdef"
    monkeypatch.setenv("LERNAPP_OPENAI_API_KEY", token)
    body = json.dumps({"error": {"message": f"Invalid Authorization header: Bearer {token}"}})
    p = ai_backend.OpenAIProvider(token, "gpt-6-luna", transport=Transport(status=400, lines=[body]))
    with pytest.raises(ai_backend.AIUnavailable) as e:
        p.complete("SYS", "Frage")
    assert token not in e.value.message and "Bearer" in e.value.message
    http = ai_async.http_error(e.value)
    assert http.status_code == 502 and token not in json.dumps(http.detail)


# ---------------------------------------------------------------- P7-05: Fehlerkoerper des Anbieters begrenzt lesen

class _Body(io.RawIOBase):
    """Antwortkoerper ohne Ende: merkt sich, wie viel gelesen wurde."""

    def __init__(self):
        self.asked = []

    def readable(self):
        return True

    def read(self, n=-1):
        self.asked.append(n)
        if n is None or n < 0:
            raise AssertionError("unbegrenztes read()")
        return b"x" * n

    def readinto(self, b):
        self.asked.append(len(b))
        b[:] = b"x" * len(b)
        return len(b)


def test_p7_05_http_error_body_is_read_with_a_limit(monkeypatch):
    from app import ai_backend
    body = _Body()

    def boom(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 500, "kaputt", {}, body)
    monkeypatch.setattr(urllib.request, "urlopen", boom)
    status, lines = ai_backend.urllib_transport("https://api.openai.com/v1/responses", {}, b"{}", 5)
    assert status == 500 and body.asked and all(n is not None and 0 < n <= 65_536 for n in body.asked)
    assert 0 < len("".join(lines)) <= 4000, "der Fehlertext kommt begrenzt an, nicht leer"


def test_p7_05_chatgpt_answer_is_read_with_a_limit(monkeypatch):
    from app import ai_backend, chatgpt_login
    body = _Body()

    class R:
        def __enter__(self):
            return body

        def __exit__(self, *a):
            return False
    monkeypatch.setattr(urllib.request, "urlopen", lambda req, timeout=None: R())
    monkeypatch.setattr(chatgpt_login, "access_token", lambda: "tok")
    monkeypatch.setattr(chatgpt_login, "account_id_from_token", lambda t: None)
    p = ai_backend.ChatGPTProvider("gpt-6-luna")
    with pytest.raises(ai_backend.AIUnavailable):
        p.complete("SYS", "Frage")
    assert body.asked and all(n is not None and 0 < n <= ai_backend.MAX_RESPONSE_BYTES for n in body.asked)


# ---------------------------------------------------------------- P7-06 / P6-05: explizite Modellwahl mit Preis und Budget

def test_p7_06_explicit_model_matrix(hosted, monkeypatch, table_prices):
    from app import ai_backend, ai_prices, credits
    fakes = {"openai": Fake("openai"), "anthropic": Fake("anthropic")}
    install(monkeypatch, fakes)
    monkeypatch.setenv("LERNAPP_AI_MODEL", "gpt-6-luna")
    monkeypatch.setenv("LERNAPP_AI_MODELS", "claude-sonnet-5-5, ohne-preis-x")
    u, _ = user(hosted, "matrix@beispiel.de", plan="pro_ai")
    # 1. nicht freigegeben: 400, kein Aufruf, keine Protokollzeile
    with pytest.raises(ai_backend.AIUnavailable) as e:
        ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage", model_name="gpt-6-astra", request_id="m1")
    assert (e.value.code, e.value.status) == ("model_not_allowed", 400)
    # 2. freigegeben, aber ohne Preis: im Dienst gesperrt, bevor irgendetwas reserviert wird
    with pytest.raises(ai_backend.AIUnavailable) as e:
        ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage", model_name="ohne-preis-x", request_id="m2")
    assert (e.value.code, e.value.status) == ("ai_not_configured_prices", 503)
    assert fakes["openai"].calls == fakes["anthropic"].calls == 0
    conn = ai_backend.connect()
    try:
        assert conn.execute("SELECT COUNT(*) FROM ai_usage_log").fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM credit_ledger").fetchone()[0] == 0
    finally:
        conn.close()
    # 3. freigegeben mit Preis: Reservierung mit der Obergrenze GENAU DIESES Modells, dann der Aufruf
    c = ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage", model_name="claude-sonnet-5-5", request_id="m3", max_output_tokens=800)
    assert fakes["anthropic"].calls == 1 and fakes["openai"].calls == 0 and c.provider == "anthropic"
    assert c.credits_reserved == ai_prices.estimate_credits("claude-sonnet-5-5", "SYS", "Frage", 800)
    assert c.credits_reserved > ai_prices.estimate_credits("gpt-6-luna", "SYS", "Frage", 800), "teureres Modell -> hoehere Reservierung"
    # 4. Becken des Dienstes voll: 503 vor dem Aufruf
    monkeypatch.setenv("LERNAPP_AI_BUDGET_EUR", "0.000001")
    with pytest.raises(ai_backend.AIUnavailable) as e:
        ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage 2", model_name="gpt-6-luna", request_id="m4")
    assert e.value.code == "ai_budget_exhausted" and fakes["openai"].calls == 0
    conn = credits.connect()
    try:
        assert conn.execute("SELECT state FROM credit_ledger WHERE request_id='m4'").fetchone()[0] == "refunded", "Credits zurueck"
    finally:
        conn.close()


# ---------------------------------------------------------------- P8-01: Bibliothek reserviert immer 2 Cent

def test_p8_01_library_reservation_honours_the_amount(monkeypatch, tmp_path):
    from app import ai_backend
    conn = _conn(tmp_path)
    try:
        log_id = ai_backend.reserve(conn, None, "library", amount_microeur=50_000, library=True)
        assert conn.execute("SELECT cost_microeur, library, user_id FROM ai_usage_log WHERE id=?", (log_id,)).fetchone() == (50_000, 1, None)
        monkeypatch.setenv("LERNAPP_AI_LIBRARY_BUDGET_EUR", "0.08")       # 80.000: 50.000 belegt, 20.000 passen, 50.000 nicht
        with pytest.raises(ai_backend.AIUnavailable) as e:
            ai_backend.reserve(conn, None, "library", amount_microeur=50_000, library=True)
        assert e.value.code == "ai_library_budget_exhausted"
        assert ai_backend.reserve(conn, None, "library", library=True) > 0, "die feste Reservierung passt noch"
    finally:
        conn.close()


# ---------------------------------------------------------------- P8-02: ensure_schema in fremder Transaktion

def test_p8_02_ensure_schema_does_not_commit_a_foreign_transaction(tmp_path):
    from app import ai_backend
    path = tmp_path / "tx.db"
    a = sqlite3.connect(path, isolation_level=None)
    b = sqlite3.connect(path, isolation_level=None)
    try:
        a.execute("CREATE TABLE fremd (x INTEGER)")
        a.execute("BEGIN IMMEDIATE")
        a.execute("INSERT INTO fremd VALUES (1)")
        ai_backend.ensure_schema(a)
        assert a.in_transaction, "executescript hat die Transaktion stillschweigend abgeschlossen"
        assert b.execute("SELECT COUNT(*) FROM fremd").fetchone()[0] == 0, "fremde Einfuegung vor dem COMMIT sichtbar"
        a.execute("ROLLBACK")
        assert a.execute("SELECT COUNT(*) FROM fremd").fetchone()[0] == 0
        ai_backend.ensure_schema(a)                                          # ohne Transaktion wie bisher
        assert not a.in_transaction and a.execute("SELECT COUNT(*) FROM ai_usage_month").fetchone()[0] == 0
    finally:
        a.close()
        b.close()


# ---------------------------------------------------------------- P8-03: estimate_model nur nach Ausgabepreis

def test_p8_03_estimate_model_compares_whole_request_costs(hosted, monkeypatch, table_prices):
    from app import ai_backend
    install(monkeypatch, {"openai": Fake("openai"), "anthropic": Fake("anthropic")})
    assert ai_backend.estimate_model("tutor:ask") == "claude-sonnet-5-5", "Tabelle: Sonnet ist bei Eingabe und Ausgabe teurer"
    # Eingabe sehr teuer, Ausgabe billig: fuer eine Seite Text ist dieses Modell das teurere
    monkeypatch.setenv("LERNAPP_AI_PRICES", json.dumps({"gpt-6-luna": {"input": 500.0, "cached_input": 50.0, "output": 1.0}}))
    assert ai_backend.estimate_model("tutor:ask") == "gpt-6-luna"


# ---------------------------------------------------------------- P8-05: is_trial_account verschluckt jeden OperationalError

def _trial_db(tmp_path, users_sql: str | None):
    from app import ai_backend
    conn = _conn(tmp_path)
    conn.execute("CREATE TABLE entitlements (user_id TEXT, source TEXT, plan TEXT, expires_at TEXT, status TEXT)")
    conn.execute("INSERT INTO entitlements VALUES ('u1', 'trial', 'pro_ai', NULL, 'active')")
    if users_sql:
        conn.execute(users_sql)
    return conn, ai_backend


def test_p8_05_missing_users_table_still_means_trial(tmp_path):
    conn, ai_backend = _trial_db(tmp_path, None)
    try:
        assert ai_backend.is_trial_account(conn, "u1", ai_backend._now()) is True
    finally:
        conn.close()


def test_p8_05_other_database_errors_stay_visible(tmp_path):
    conn, ai_backend = _trial_db(tmp_path, "CREATE TABLE users (id TEXT PRIMARY KEY)")      # ohne plan/plan_until: Schema kaputt
    try:
        with pytest.raises(sqlite3.OperationalError):
            ai_backend.is_trial_account(conn, "u1", ai_backend._now())
    finally:
        conn.close()


# ---------------------------------------------------------------- P8-06: settle mit negativen Betraegen

def test_p8_06_settle_never_books_negative_costs(tmp_path):
    from app import ai_backend
    conn = _conn(tmp_path)
    try:
        conn.execute("CREATE TABLE entitlements (user_id TEXT, source TEXT, plan TEXT, expires_at TEXT, status TEXT)")
        log_id = ai_backend.reserve(conn, "u1", "tutor:explain", amount_microeur=30_000)
        assert ai_backend._pool_total(conn, ai_backend._now().strftime("%Y-%m"), "paid") == 30_000
        c = ai_backend.Completion("t", -100, -50, "gpt-6-luna")
        assert ai_backend.settle(conn, log_id, c, "openai", "gpt-6-luna", cost_override=-5) == 0
        row = conn.execute("SELECT cost_microeur, state, input_tokens, output_tokens FROM ai_usage_log WHERE id=?", (log_id,)).fetchone()
        assert row == (0, "done", 0, 0)
        assert ai_backend._pool_total(conn, ai_backend._now().strftime("%Y-%m"), "paid") == 0
        assert ai_backend.month_totals_match_log(conn)
    finally:
        conn.close()


# ---------------------------------------------------------------- P8-07: Bilder nur an Modelle, die sie lesen

def test_p8_07_explicit_text_only_model_refuses_images(hosted, monkeypatch, table_prices):
    from app import ai_backend
    install(monkeypatch, {"openai": Fake("openai"), "deepseek": Fake("deepseek")})
    monkeypatch.setenv("LERNAPP_AI_MODEL", "gpt-6-luna")
    monkeypatch.setenv("LERNAPP_AI_MODELS", "deepseek-v4-flash-0731")
    with pytest.raises(ai_backend.AIUnavailable) as e:
        ai_backend.route("tutor:explain", "r1", model_name="deepseek-v4-flash-0731", image=PNG)
    assert (e.value.code, e.value.status) == ("model_not_allowed", 400)
    assert ai_backend.route("tutor:explain", "r1", model_name="deepseek-v4-flash-0731")[0].label == "deepseek", "ohne Bild erlaubt"


def test_p8_07_unknown_price_is_not_vision_capable(hosted, monkeypatch, table_prices):
    from app import ai_backend
    install(monkeypatch, {"openai": Fake("openai"), "anthropic": Fake("anthropic")})
    monkeypatch.setattr(ai_backend, "_default_model", lambda label: "unbekannt-xyz" if label == "openai" else MODELS[label])
    chain = ai_backend.route("tutor:explain", "r2", image=PNG)
    assert [p.label for p in chain] == ["anthropic"], "ohne Preis gilt ein Modell nicht als bildfaehig (fail closed)"


# ---------------------------------------------------------------- P8-08: user_tag (nur Bewertung) und Paket-8-Beobachtungen

def test_p8_08_user_tag_is_stable_and_hides_the_id():
    from app import ai_backend
    uid = "3f2a9c1e5b7d4a6f8e0c1b2a3d4e5f60"
    tag = ai_backend.user_tag(uid)
    assert tag == ai_backend.user_tag(uid) and len(tag) == 32 and uid not in tag and uid[:8] not in tag
    assert ai_backend.user_tag(None) is None and ai_backend.user_tag("") is None


def test_p6_08_sse_abort_after_start_is_billed_not_retried():
    """Abbruch nach HTTP 200 ohne response.completed: started=True (kein Wechsel des Anbieters), kein quick_retry."""
    from app import ai_backend
    delta = {"type": "response.output_text.delta", "delta": "Teil"}
    p = ai_backend.OpenAIProvider("sk-test", "gpt-6-luna", transport=Transport(lines=lines_of([delta], done=False)))
    with pytest.raises(ai_backend.AIUnavailable) as e:
        p.complete("SYS", "Frage")
    assert e.value.started and not e.value.retryable and not e.value.quick_retry_ok() and e.value.code == "ai_provider_error"


def test_p8_async_client_uses_the_connection_timeout_as_read_timeout(monkeypatch):
    import asyncio
    from app import ai_backend
    monkeypatch.setenv("LERNAPP_AI_TIMEOUT_S", "33")

    async def go():
        return ai_backend.async_http_client()
    c = asyncio.run(go())
    assert c.timeout.read == 33.0 and c.timeout.connect == 10.0, "ohne Zeilen greift das Lese-Zeitlimit, nicht erst DEADLINE_S"
