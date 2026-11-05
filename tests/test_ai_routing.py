"""Modellmischung der StudiNow-KI (05.11.2026: ChatGPT etwa 75 %, Sonnet 25 %, DeepSeek nur auf Wunsch; app/ai_router.py, app/ai_providers.py, docs/KI-MODELLMISCHUNG-2026-11-05.md):
Adapter lesen die Nutzung, der Router waehlt deterministisch nach Gewicht, schwere Faelle gehen an Sonnet, Ersatz ohne
doppelte Abrechnung, Preise fail closed, Zwischenspeicher ueber Modelle hinweg, Reservierung mit dem Preis des
gewaehlten Modells, und die harte Grenze: ein Konto verursacht im Monat nie mehr als seine 100 Credits (1 EUR).
Alles mit Attrappen, kein Aufruf eines echten Anbieters."""
import json
import re
import threading
from collections import Counter

import pytest
from test_subscriptions import FakeAI, hosted, user  # noqa: F401 - hosted ist eine Fixture

MODELS = {"deepseek": "deepseek-v4.1-flash-1017", "openai": "gpt-6-luna", "anthropic": "claude-sonnet-5-5"}


@pytest.fixture
def table_prices(monkeypatch):
    """Echte Preistabelle statt der winzigen Testpreise aus conftest."""
    monkeypatch.delenv("LERNAPP_AI_PRICE_IN_EUR", raising=False)
    monkeypatch.delenv("LERNAPP_AI_PRICE_OUT_EUR", raising=False)
    monkeypatch.delenv("LERNAPP_AI_ROUTES", raising=False)
    monkeypatch.delenv("LERNAPP_AI_DISABLED", raising=False)
    monkeypatch.delenv("LERNAPP_OPENAI_BASE_URL", raising=False)
    monkeypatch.setenv("LERNAPP_AI_USER_BUDGET_EUR", "100000")
    monkeypatch.setenv("LERNAPP_AI_BUDGET_EUR", "1000000")
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_MINUTE", "100000")
    monkeypatch.setenv("LERNAPP_AI_RATE_PER_HOUR", "100000")


# ---------------------------------------------------------------- Attrappen

def lines_of(events: list[dict], done: bool = True) -> list[str]:
    out = []
    for e in events:
        out += [f"data: {json.dumps(e)}", ""]
    if done:
        out += ["data: [DONE]", ""]
    return out


class Transport:
    """Ersatz fuer urllib_transport: merkt sich die Anfrage, liefert Status und Zeilen."""

    def __init__(self, status=200, lines=None, raise_exc=None):
        self.status, self.lines, self.raise_exc, self.seen = status, lines or [], raise_exc, []

    def __call__(self, url, headers, body, timeout):
        self.seen.append((url, headers, json.loads(body)))
        if self.raise_exc:
            raise self.raise_exc
        return self.status, iter(self.lines)


class Fake:
    """Anbieter-Attrappe fuer den Router: zaehlt Aufrufe, liefert Nutzung oder wirft einen Fehler."""
    supports_options = True

    def __init__(self, label, usage=(1000, 200), error=None, text=None, usage_known=True, worst=False):
        self.label, self.model, self.usage, self.error, self.usage_known, self.worst = label, MODELS[label], usage, error, usage_known, worst
        self.text = text or f"Antwort von {label}"
        self.calls, self.opts, self.lock = 0, [], threading.Lock()

    def complete(self, system, prompt, schema=None, **opts):
        from app import ai_backend, ai_prices
        with self.lock:
            self.calls += 1
            self.opts.append(opts)
        if self.error:
            raise self.error()
        if self.worst:                    # schlimmster Fall: so viele Tokens wie Bytes, Ausgabe voll ausgeschoepft
            tin = ai_prices.worst_input_tokens(system, prompt, schema)
            return ai_backend.Completion(self.text, tin, int(opts.get("max_output_tokens") or 0), self.model, provider=self.label)
        return ai_backend.Completion(self.text, self.usage[0], self.usage[1], self.model, provider=self.label,
                                     usage_known=self.usage_known)


def install(monkeypatch, fakes: dict):
    """Router mit Attrappen: nur diese Anbieter gelten als eingerichtet."""
    from app import ai_backend
    ai_backend.set_provider(None)
    monkeypatch.setattr(ai_backend, "configured_providers", lambda ignore_choice=False: set(fakes))
    monkeypatch.setattr(ai_backend, "build", lambda label, model_name=None: fakes[label])
    monkeypatch.setattr(ai_backend, "_default_model", lambda label: MODELS[label])


def busy():
    from app.ai_backend import AIUnavailable
    return AIUnavailable("ai_provider_error", "Fehler 503", 502, retryable=True)


def broke_midway():
    from app.ai_backend import AIUnavailable
    return AIUnavailable("ai_provider_error", "abgebrochen", 502, started=True)


def rid_for(purpose: str, provider: str, configured=("deepseek", "openai", "anthropic"), prefix="r") -> str:
    from app import ai_router
    for i in range(5000):
        rid = f"{prefix}{i}"
        if ai_router.chain(purpose, rid, configured=set(configured))[0][0].provider == provider:
            return rid
    raise AssertionError("keine passende request_id")


def month(uid):
    from app import credits
    conn = credits.connect()
    try:
        return conn.execute("SELECT allowance, used, reserved FROM credit_months WHERE user_id=?", (uid,)).fetchone()
    finally:
        conn.close()


# ---------------------------------------------------------------- Adapter: OpenAI-kompatibel (DeepSeek in der EU)

def test_compat_adapter_streams_text_and_reads_usage():
    from app import ai_providers
    seen = []
    t = Transport(lines=lines_of([
        {"model": "deepseek-v4.1-flash-1017", "choices": [{"delta": {"content": "Hal"}, "finish_reason": None}]},
        {"choices": [{"delta": {"content": "lo"}, "finish_reason": "stop"}]},
        {"choices": [], "usage": {"prompt_tokens": 1200, "completion_tokens": 300, "prompt_tokens_details": {"cached_tokens": 200},
                                  "completion_tokens_details": {"reasoning_tokens": 40}}},
    ]))
    p = ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "geheim", "deepseek-v4.1-flash-1017", transport=t,
                                          reasoning_effort="none")
    png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8 + b"\x00\x00\x00\x10\x00\x00\x00\x10"
    c = p.complete("SYS", "Frage", {"type": "object", "properties": {}}, image=png, max_output_tokens=900, on_delta=seen.append)
    assert (c.text, c.input_tokens, c.cached_tokens, c.output_tokens, c.reasoning_tokens, c.images, c.provider, c.usage_known) == \
        ("Hallo", 1200, 200, 300, 40, 1, "deepseek", True)
    assert seen == ["Hal", "lo"]
    url, headers, body = t.seen[0]
    assert url == "https://api.scaleway.ai/v1/chat/completions" and headers["Authorization"] == "Bearer geheim"
    assert body["stream"] is True and body["stream_options"] == {"include_usage": True} and body["max_tokens"] == 900
    assert body["reasoning_effort"] == "none" and body["response_format"]["type"] == "json_schema"
    assert body["messages"][0] == {"role": "system", "content": "SYS"}
    assert body["messages"][1]["content"][1]["image_url"]["url"].startswith("data:image/png;base64,")


def test_compat_adapter_without_usage_and_on_errors():
    from app import ai_providers
    from app.ai_backend import AIUnavailable
    t = Transport(lines=lines_of([{"choices": [{"delta": {"content": "x"}, "finish_reason": "stop"}]}]))
    c = ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m", transport=t).complete("s", "p")
    assert c.text == "x" and c.usage_known is False, "ohne usage rechnet der Dienst die Reservierung ab"
    for status, retry in ((503, True), (429, True), (401, True), (400, False)):
        with pytest.raises(AIUnavailable) as e:
            ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m",
                                              transport=Transport(status=status, lines=['{"error": {"message": "nein"}}'])).complete("s", "p")
        assert e.value.retryable is retry and not e.value.started and e.value.billed is None, status
    with pytest.raises(AIUnavailable) as e:
        ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m", transport=Transport(raise_exc=TimeoutError())).complete("s", "p")
    assert e.value.retryable and e.value.code == "ai_provider_unreachable"
    cut = lines_of([{"choices": [{"delta": {"content": "x"}, "finish_reason": "length"}]},
                    {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 5}}])
    with pytest.raises(AIUnavailable) as e:
        ai_providers.OpenAICompatProvider("https://api.scaleway.ai/v1", "k", "m", transport=Transport(lines=cut)).complete("s", "p")
    assert e.value.started and e.value.billed.output_tokens == 5 and not e.value.retryable


@pytest.mark.parametrize("url", ["https://api.deepseek.com/v1", "https://eu.api.deepseek.com", "https://x.example.cn/v1",
                                 "http://api.scaleway.ai/v1"])
def test_deepseek_only_through_an_eu_host(url):
    from app import ai_providers
    from app.ai_backend import AIUnavailable
    with pytest.raises(AIUnavailable) as e:
        ai_providers.OpenAICompatProvider(url, "k", "deepseek-v4.1-flash-1017")
    assert e.value.code == "ai_not_configured"


# ---------------------------------------------------------------- Adapter: Claude (Anthropic-SDK, Test-Transport)

def _sse(events):
    return "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode()


def claude_events(text="Hallo Welt", stop="end_turn", usage_in=(800, 150, 0), out=120):
    return [
        {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant", "content": [],
                                               "model": "claude-sonnet-5-5", "stop_reason": None, "stop_sequence": None,
                                               "usage": {"input_tokens": usage_in[0], "cache_read_input_tokens": usage_in[1],
                                                         "cache_creation_input_tokens": usage_in[2], "output_tokens": 1}}},
        {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text[:5]}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text[5:]}},
        {"type": "content_block_stop", "index": 0},
        {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": out}},
        {"type": "message_stop"},
    ]


def sdk_client(handler):
    anthropic = pytest.importorskip("anthropic")
    httpx2 = pytest.importorskip("httpx2")
    return anthropic.Anthropic(api_key="test-key", base_url="https://claude.invalid", max_retries=0,
                               http_client=httpx2.Client(transport=httpx2.MockTransport(handler)))


def test_claude_adapter_reads_usage_through_the_sdk():
    from app import ai_providers
    httpx2 = pytest.importorskip("httpx2")
    seen, deltas = [], []

    def handler(request):
        seen.append(json.loads(request.content))
        return httpx2.Response(200, headers={"content-type": "text/event-stream"}, content=_sse(claude_events()))
    p = ai_providers.AnthropicProvider("claude-sonnet-5-5", backend="anthropic", client=sdk_client(handler), effort="medium")
    schema = {"type": "object", "properties": {"cards": {"type": "array", "minItems": 3, "items": {
        "type": "object", "properties": {"q": {"type": "string", "maxLength": 200}}}}}}
    c = p.complete("SYS", "Frage", schema, max_output_tokens=700, on_delta=deltas.append)
    assert (c.text, c.input_tokens, c.cached_tokens, c.output_tokens, c.model, c.provider) == \
        ("Hallo Welt", 950, 150, 120, "claude-sonnet-5-5", "anthropic")
    assert "".join(deltas) == "Hallo Welt"
    body = seen[0]
    assert body["model"] == "claude-sonnet-5-5" and body["max_tokens"] == 700 and body["system"] == "SYS"
    assert body["output_config"]["effort"] == "medium" and "temperature" not in body and "fallbacks" not in body
    sent = body["output_config"]["format"]["schema"]
    assert sent["additionalProperties"] is False and sent["properties"]["cards"]["items"]["additionalProperties"] is False
    assert "minItems" not in sent["properties"]["cards"] and "maxLength" not in json.dumps(sent)


def test_claude_adapter_errors_refusal_and_cut_answers():
    from app import ai_providers
    from app.ai_backend import AIUnavailable
    httpx2 = pytest.importorskip("httpx2")
    for status, retry in ((529, True), (500, True), (400, False)):
        p = ai_providers.AnthropicProvider("claude-sonnet-5-5", backend="anthropic", client=sdk_client(
            lambda r, s=status: httpx2.Response(s, json={"type": "error", "error": {"type": "x", "message": "nein"}})))
        with pytest.raises(AIUnavailable) as e:
            p.complete("s", "p")
        assert e.value.retryable is retry and not e.value.started and e.value.billed is None, status
    for stop, code in (("refusal", "ai_refused"), ("max_tokens", "ai_provider_error")):
        p = ai_providers.AnthropicProvider("claude-sonnet-5-5", backend="anthropic", client=sdk_client(
            lambda r, s=stop: httpx2.Response(200, headers={"content-type": "text/event-stream"}, content=_sse(claude_events(stop=s)))))
        with pytest.raises(AIUnavailable) as e:
            p.complete("s", "p")
        assert e.value.code == code and e.value.started and e.value.billed.output_tokens == 120 and not e.value.retryable


def test_claude_only_from_the_eu_unless_explicitly_allowed(monkeypatch):
    from app import ai_providers
    from app.ai_backend import AIUnavailable
    with pytest.raises(AIUnavailable):
        ai_providers.AnthropicProvider("anthropic.claude-sonnet-5-5", backend="bedrock", region="us-east-1")
    with pytest.raises(AIUnavailable):
        ai_providers.AnthropicProvider("claude-sonnet-5-5", backend="anthropic")
    assert ai_providers.AnthropicProvider("anthropic.claude-sonnet-5-5", backend="bedrock", region="eu-central-1").region == "eu-central-1"
    monkeypatch.setenv("LERNAPP_ANTHROPIC_API_KEY", "k")
    monkeypatch.setenv("LERNAPP_ANTHROPIC_BACKEND", "anthropic")
    assert not ai_providers.anthropic_configured(), "direkt nur mit LERNAPP_ANTHROPIC_ALLOW_NON_EU=1"
    monkeypatch.setenv("LERNAPP_ANTHROPIC_BACKEND", "bedrock")
    assert ai_providers.anthropic_configured() and ai_providers.anthropic_model() == "anthropic.claude-sonnet-5-5"


# ---------------------------------------------------------------- Router

def test_routing_is_deterministic_and_follows_the_weights(table_prices):
    from app import ai_router
    every = {"openai", "anthropic"}
    first = [ai_router.chain("tutor:ask", f"id{i}", configured=every)[0] for i in range(40)]
    assert first == [ai_router.chain("tutor:ask", f"id{i}", configured=every)[0] for i in range(40)], "Wiederholung = gleiches Modell"
    n = 6000
    simple = Counter(ai_router.chain("tutor:explain", f"s{i}", configured=every)[0][0].provider for i in range(n))
    assert simple == {"openai": n}, "einfache Aufgaben: nur ChatGPT"
    medium = Counter(ai_router.chain("tutor:ask", f"m{i}", configured=every)[0][0].provider for i in range(n))
    assert abs(medium["openai"] / n - 0.75) < 0.03 and abs(medium["anthropic"] / n - 0.25) < 0.03 and not medium["deepseek"]
    order, _ = ai_router.chain("tutor:ask", "x", configured=every)
    assert sorted(c.provider for c in order) == sorted(every), "alle anderen stehen als Ersatz dahinter"


def test_typical_mix_lands_near_75_25_without_deepseek(table_prices):
    """Inhaber 05.11.2026 ("also nein dann benutz gpt eher als deepseek"): ChatGPT statt DeepSeek, Sonnet behaelt die
    schweren Faelle."""
    from app import ai_router
    share = ai_router.expected_share()
    assert share["deepseek"] == 0 and abs(share["openai"] - 0.75) <= 0.03 and abs(share["anthropic"] - 0.25) <= 0.03, share
    assert abs(sum(share.values()) - 1) < 1e-6
    assert all(c.provider != "deepseek" for route in (*ai_router.DEFAULT_ROUTES.values(), ai_router.HARD) for c, _ in
               ai_router.parse_route(route)), "kein DeepSeek in den Standardwegen"


def test_deepseek_is_off_by_default_even_with_a_key(table_prices, monkeypatch):
    from app import ai_backend, ai_router
    ai_backend.set_provider(None)
    monkeypatch.setenv("LERNAPP_OPENAI_API_KEY", "sk-test")
    monkeypatch.setenv("LERNAPP_AI_MODEL", "gpt-6-luna")
    monkeypatch.setenv("LERNAPP_DEEPSEEK_API_KEY", "scw-test")
    monkeypatch.delenv("LERNAPP_AI_PROVIDER", raising=False)
    assert ai_backend.configured_providers() == {"openai"}, "Schluessel allein schaltet DeepSeek nicht ein"
    for i in range(200):                                   # auch nicht als Ersatz
        assert [c.provider for c in ai_router.chain("tutor:explain", f"d{i}", configured=ai_backend.configured_providers())[0]] == ["openai"]
    # wieder einschalten: Weg mit DeepSeek in LERNAPP_AI_ROUTES (Beispiel in deploy/.env.example) -> etwa 49/26/25
    monkeypatch.setenv("LERNAPP_AI_ROUTES", ai_router.DEEPSEEK_ROUTES_EXAMPLE)
    assert ai_backend.configured_providers() == {"openai", "deepseek"}
    share = ai_router.expected_share()
    assert abs(share["deepseek"] - 0.49) <= 0.03 and abs(share["openai"] - 0.26) <= 0.03 and abs(share["anthropic"] - 0.25) <= 0.03, share
    monkeypatch.delenv("LERNAPP_AI_ROUTES")
    monkeypatch.setenv("LERNAPP_AI_PROVIDER", "deepseek")
    assert ai_backend.configured_providers() == {"deepseek"}, "ausdruecklich gewaehlt"
    monkeypatch.delenv("LERNAPP_DEEPSEEK_API_KEY")
    assert ai_backend.configured_providers() == set(), "ohne Schluessel nie"
    env_example = (__import__("pathlib").Path(__file__).resolve().parents[1] / "deploy" / ".env.example").read_text(encoding="utf-8")
    assert f"# LERNAPP_AI_ROUTES={ai_router.DEEPSEEK_ROUTES_EXAMPLE}" in env_example
    assert re.search(r"^LERNAPP_DEEPSEEK_API_KEY=\s*$", env_example, re.M), "in der Vorlage leer"


def test_hard_cases_go_to_sonnet(table_prices, monkeypatch):
    from app import ai_router
    every = {"deepseek", "openai", "anthropic"}
    for purpose, text, hint in (("tutor:check", "", None), ("tutor:steps", "", None), ("tutor:doc_tasks", "", None),
                                ("tutor:explain", "Kannst du die Formel herleiten?", None),
                                ("tutor:ask", r"\frac{a}{b} + \int_0^1 x^2 dx = \sqrt{2} \sum_k \lambda_k ∂f/∂x", None),
                                ("tutor:explain", "Was heißt das?", "second_opinion")):
        chain, hard = ai_router.chain(purpose, "egal", configured=every, route_text=text, hint=hint)
        assert hard and chain[0].provider == "anthropic", (purpose, text, hint)
    _, hard = ai_router.chain("tutor:explain", "egal", configured=every, route_text="Was bedeutet dieser Satz?")
    assert not hard
    assert not ai_router.looks_math("Erkläre mir das Kapitel über Märkte.")
    # Notschalter: Sonnet aus -> der schwere Fall nimmt den normalen Weg, nie ein abgeschaltetes Modell
    monkeypatch.setenv("LERNAPP_AI_DISABLED", "anthropic")
    chain, _ = ai_router.chain("tutor:check", "egal", configured=every)
    assert chain and all(c.provider != "anthropic" for c in chain)
    monkeypatch.setenv("LERNAPP_AI_DISABLED", "deepseek,openai")
    assert [c.provider for c in ai_router.chain("tutor:explain", "egal", configured=every)[0]] == ["anthropic"]


def test_routes_are_configurable(table_prices, monkeypatch):
    from app import ai_router
    monkeypatch.setenv("LERNAPP_AI_ROUTES", json.dumps({"routes": {"tutor:*": "openai:1", "flashcards": [["claude", 3]]},
                                                        "hard": "deepseek:1", "hard_purposes": ["tutor:summary"], "math": False}))
    every = {"deepseek", "openai", "anthropic"}
    assert ai_router.chain("tutor:explain", "a", configured=every)[0][0].provider == "openai"
    assert ai_router.chain("flashcards", "a", configured=every)[0][0].provider == "anthropic"
    assert ai_router.chain("tutor:summary", "a", configured=every)[0][0].provider == "deepseek"
    assert not ai_router.chain("tutor:ask", "a", configured=every, route_text="Bitte herleiten")[1], "Rechen-Regel aus"
    monkeypatch.setenv("LERNAPP_AI_ROUTES", "{kaputt")
    assert ai_router.config()["routes"]["tutor:ask"] == ai_router.parse_route(ai_router.MEDIUM)


def test_requests_with_image_only_go_to_models_that_read_images(table_prices, monkeypatch):
    from app import ai_backend
    monkeypatch.setenv("LERNAPP_DEEPSEEK_MODEL", "deepseek-v4-flash-0731")         # nur Text
    monkeypatch.setenv("LERNAPP_AI_ROUTES", ai_router_example())                   # DeepSeek eingeschaltet
    monkeypatch.setattr(ai_backend, "configured_providers", lambda ignore_choice=False: {"deepseek", "openai"})
    built = []
    monkeypatch.setattr(ai_backend, "build", lambda label, model_name=None: built.append(label) or Fake(label))
    monkeypatch.setattr(ai_backend, "_default_model",
                        lambda label: {"deepseek": "deepseek-v4-flash-0731", "openai": "gpt-6-luna"}[label])
    for i in range(30):
        built.clear()
        ai_backend.route("doc_index_page", f"b{i}", image=b"\x89PNG\r\n\x1a\n")
        assert built == ["openai"]


def ai_router_example() -> str:
    from app import ai_router
    return ai_router.DEEPSEEK_ROUTES_EXAMPLE


# ---------------------------------------------------------------- Preise

def test_prices_fail_closed_and_currency(table_prices, monkeypatch):
    from app import ai_prices
    assert ai_prices.price("deepseek-v9-unbekannt") is None and not ai_prices.known("claude-unbekannt")
    monkeypatch.setenv("LERNAPP_AI_USD_EUR", "0.9")
    assert ai_prices.price("deepseek-v4.1-flash-1017").input_eur == pytest.approx(0.60), "Euro-Preise bleiben Euro"
    assert ai_prices.price("claude-sonnet-5-5").output_eur == pytest.approx(9.9)
    assert ai_prices.price("eu.anthropic.claude-sonnet-5-5-v1:0").model == "claude-sonnet-5-5"
    monkeypatch.setenv("LERNAPP_AI_USD_EUR", "1")
    monkeypatch.setenv("LERNAPP_OPENAI_BASE_URL", "https://eu.api.openai.com/v1")
    assert ai_prices.price("gpt-6-luna").output_eur == pytest.approx(0.55), "EU-Datenresidenz bei OpenAI: +10 %"
    assert ai_prices.provider_of("anthropic.claude-sonnet-5-5") == "anthropic" and ai_prices.provider_of("deepseek-v4-flash-0731") == "deepseek"


def test_hosted_refuses_a_chain_without_prices(hosted, table_prices, monkeypatch):
    from app import ai_backend
    fakes = {"deepseek": Fake("deepseek")}
    fakes["deepseek"].model = "deepseek-ohne-preis"
    install(monkeypatch, fakes)
    with pytest.raises(ai_backend.AIUnavailable) as e:
        ai_backend.complete(None, "tutor:explain", "s", "p", request_id="np")
    assert e.value.code == "ai_not_configured_prices" and fakes["deepseek"].calls == 0


def test_worst_case_is_an_upper_bound_for_any_text():
    from app import ai_prices
    for text in ("abc" * 100, "∫∑√" * 300, "数学" * 400, "x"):
        assert ai_prices.worst_input_tokens("", text) >= len(text.encode("utf-8")), "nie weniger Tokens als Bytes angenommen"
    big = ai_prices.worst_case_microeur("claude-sonnet-5-5", "s", "p" * 1000, 2000)
    assert big >= ai_prices.estimate_microeur("claude-sonnet-5-5", "s", "p" * 1000, 2000)
    assert ai_prices.max_output_within("gpt-6-luna", "s", "p", 10_000) > 0
    assert ai_prices.worst_case_microeur("gpt-6-luna", "s", "p", ai_prices.max_output_within("gpt-6-luna", "s", "p", 10_000)) <= 10_000


# ---------------------------------------------------------------- Ablauf im Dienst: Ersatz, Zwischenspeicher, Schaetzung

def test_fallback_on_5xx_charges_once(hosted, table_prices, monkeypatch):
    from app import ai_backend, credits
    u, _ = user(hosted, "ersatz@beispiel.de", plan="pro_ai")
    fakes = {"openai": Fake("openai", error=busy), "anthropic": Fake("anthropic", usage=(1000, 200))}
    install(monkeypatch, fakes)
    rid = rid_for("tutor:ask", "openai", configured=fakes)
    c = ai_backend.complete(u["id"], "tutor:ask", "SYS", "Frage", request_id=rid)
    assert c.provider == "anthropic" and (fakes["openai"].calls, fakes["anthropic"].calls) == (1, 1)
    conn = credits.connect()
    try:
        rows = conn.execute("SELECT state, charged, model FROM credit_ledger WHERE user_id=?", (u["id"],)).fetchall()
        log = conn.execute("SELECT state, provider, model FROM ai_usage_log WHERE user_id=?", (u["id"],)).fetchall()
    finally:
        conn.close()
    assert rows == [("settled", 1, "claude-sonnet-5-5")] and log == [("done", "anthropic", "claude-sonnet-5-5")], (rows, log)
    assert month(u["id"])[1:] == (1, 0)


def test_no_fallback_after_the_provider_started(hosted, table_prices, monkeypatch):
    from app import ai_backend
    u, _ = user(hosted, "angefangen@beispiel.de", plan="pro_ai")
    fakes = {"openai": Fake("openai", error=broke_midway), "anthropic": Fake("anthropic")}
    install(monkeypatch, fakes)
    rid = rid_for("tutor:explain", "openai", configured=fakes)
    with pytest.raises(ai_backend.AIUnavailable) as e:
        ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage", request_id=rid)
    allowance, used, reserved = month(u["id"])
    assert fakes["anthropic"].calls == 0, "angenommen und abgebrochen: kein zweiter Anbieter, sonst doppelte Kosten"
    assert reserved == 0 and 0 < used == e.value.extra["credits_charged"], "Nutzung unbekannt: die Obergrenze wird berechnet"


def test_cache_is_shared_across_models_and_records_the_producer(hosted, table_prices, monkeypatch):
    from app import ai_backend
    fakes = {"openai": Fake("openai"), "anthropic": Fake("anthropic")}
    install(monkeypatch, fakes)
    a = rid_for("tutor:ask", "openai", configured=fakes, prefix="a")
    b = rid_for("tutor:ask", "anthropic", configured=fakes, prefix="b")
    first = ai_backend.complete(None, "tutor:ask", "SYS", "Seite 3", cache=True, request_id=a)
    again = ai_backend.complete(None, "tutor:ask", "SYS", "Seite 3", cache=True, request_id=b)
    assert first.provider == "openai" and again.model == "cache" and again.text == first.text
    assert again.source_model == "gpt-6-luna" and fakes["anthropic"].calls == 0, "kein Fragmentieren nach Modell"


def test_reservation_uses_the_price_of_the_routed_model(hosted, table_prices, monkeypatch):
    from app import ai_backend, ai_prices, credits
    reserved = {}
    for label in ("deepseek", "openai", "anthropic"):
        u, _ = user(hosted, f"preis-{label}@beispiel.de", plan="pro_ai")
        install(monkeypatch, {label: Fake(label)})
        ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage " * 400, request_id="e1")
        conn = credits.connect()
        try:
            reserved[label] = conn.execute("SELECT reserved FROM credit_ledger WHERE user_id=?", (u["id"],)).fetchone()[0]
        finally:
            conn.close()
        assert reserved[label] == ai_prices.estimate_credits(MODELS[label], "SYS", "Frage " * 400, ai_backend.max_output("tutor:explain"))
    assert reserved["anthropic"] > reserved["deepseek"] >= reserved["openai"], reserved
    # mit Ersatz-Kette: reserviert wird fuer das teuerste Modell der Kette
    u, _ = user(hosted, "kette@beispiel.de", plan="pro_ai")
    install(monkeypatch, {"openai": Fake("openai"), "anthropic": Fake("anthropic")})
    ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage " * 400, request_id="e2")
    conn = credits.connect()
    try:
        assert conn.execute("SELECT reserved FROM credit_ledger WHERE user_id=?", (u["id"],)).fetchone()[0] == reserved["anthropic"]
    finally:
        conn.close()


def test_doc_plan_estimate_uses_the_route(hosted, table_prices, monkeypatch):
    from app import ai_backend
    install(monkeypatch, {"deepseek": Fake("deepseek"), "openai": Fake("openai"), "anthropic": Fake("anthropic")})
    assert ai_backend.estimate_model("tutor:doc_tasks") == "claude-sonnet-5-5", "Aufgaben gehen an Sonnet"
    assert ai_backend.estimate_model("tutor:doc_lecture") == "gpt-6-luna", "einfacher Weg: ChatGPT"
    assert ai_backend.estimate_model("tutor:ask") == "claude-sonnet-5-5", "teuerstes Modell des Weges"


def test_second_opinion_skips_the_cache_and_asks_sonnet(hosted, table_prices, monkeypatch):
    from conftest import asgi_call
    from test_subscriptions import _j
    _, h = user(hosted, "falsch@beispiel.de", plan="pro_ai")
    fakes = {"deepseek": Fake("deepseek"), "openai": Fake("openai"), "anthropic": Fake("anthropic")}
    install(monkeypatch, fakes)
    body = {"mode": "explain", "page_text": "Satz von Gauss"}
    rid = rid_for("tutor:explain", "openai", prefix="t")
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/tutor", headers=h, body=json.dumps({**body, "request_id": rid})))
    assert st == 200 and d["answer"] == "Antwort von openai", d
    st, d = _j(asgi_call(hosted, "POST", "/api/ai/tutor", headers=h, body=json.dumps({**body, "request_id": rid + "x", "second_opinion": True})))
    assert st == 200 and d["answer"] == "Antwort von anthropic" and fakes["anthropic"].calls == 1, d


# ---------------------------------------------------------------- harte Grenze: nie mehr als 100 Credits je Monat

def test_pro_ai_never_exceeds_100_credits_with_concurrency(hosted, table_prices, monkeypatch):
    from app import ai_backend
    u, _ = user(hosted, "parallel-hart@beispiel.de", plan="pro_ai")
    fakes = {p: Fake(p, worst=True) for p in ("deepseek", "openai", "anthropic")}
    install(monkeypatch, fakes)
    results, lock = [], threading.Lock()
    start = threading.Barrier(24)

    def run(i):
        start.wait()
        try:
            r = ai_backend.complete(u["id"], "tutor:check", "SYS", f"Lösung {i}: " + "x" * 4000, request_id=f"c{i}")
        except ai_backend.AIUnavailable as e:
            r = e
        with lock:
            results.append(r)
    for _round in range(3):                                   # mehrere Wellen, bis der Rahmen leer ist
        start = threading.Barrier(24)
        ts = [threading.Thread(target=run, args=(i + 100 * _round,)) for i in range(24)]
        [t.start() for t in ts]
        [t.join() for t in ts]
    allowance, used, reserved = month(u["id"])
    charged = sum(r.credits_charged for r in results if isinstance(r, ai_backend.Completion))
    assert allowance == 100 and reserved == 0 and used == charged <= 100, (used, charged)
    assert any(isinstance(r, ai_backend.AIUnavailable) and r.code == "credits_exhausted" for r in results)


def test_underestimated_input_and_runaway_usage_are_capped(hosted, table_prices, monkeypatch):
    from app import ai_backend, credits
    u, _ = user(hosted, "riesig@beispiel.de", plan="pro_ai")
    # der Anbieter meldet absurd viel mehr Tokens als moeglich: berechnet wird hoechstens die Reservierung
    install(monkeypatch, {"anthropic": Fake("anthropic", usage=(5_000_000, 900_000))})
    total = 0
    for i in range(200):
        try:
            c = ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage", request_id=f"u{i}")
        except ai_backend.AIUnavailable as e:
            assert e.code == "credits_exhausted"
            break
        assert c.credits_charged <= c.credits_reserved
        total += c.credits_charged
    allowance, used, reserved = month(u["id"])
    assert used == total <= 100 and reserved == 0
    conn = credits.connect()
    try:
        real = conn.execute("SELECT MAX(cost_microeur) FROM credit_ledger WHERE user_id=?", (u["id"],)).fetchone()[0]
    finally:
        conn.close()
    assert real > 100 * 10_000, "die echte Zahl bleibt in der Kostenansicht sichtbar"


def test_fallback_and_unknown_usage_stay_inside_the_reservation(hosted, table_prices, monkeypatch):
    from app import ai_backend
    u, _ = user(hosted, "ersatz-hart@beispiel.de", plan="pro_ai")
    fakes = {"deepseek": Fake("deepseek", error=busy), "anthropic": Fake("anthropic", worst=True),
             "openai": Fake("openai", usage_known=False)}
    install(monkeypatch, fakes)
    charged = 0
    for i in range(300):
        try:
            c = ai_backend.complete(u["id"], "tutor:explain", "SYS", "Frage " * 200, request_id=f"f{i}")
        except ai_backend.AIUnavailable as e:
            assert e.code == "credits_exhausted", e.code
            break
        assert c.credits_charged <= c.credits_reserved, "Ersatz und unbekannte Nutzung passen in die eine Reservierung"
        charged += c.credits_charged
    allowance, used, reserved = month(u["id"])
    assert used == charged <= 100 and reserved == 0
    assert fakes["anthropic"].calls + fakes["openai"].calls > 0


def test_request_shrinks_to_fit_the_last_credits(hosted, table_prices, monkeypatch):
    from app import ai_backend, credits
    u, _ = user(hosted, "rest@beispiel.de", plan="pro_ai")
    conn = credits.connect()
    try:
        credits.balance(conn, u["id"])
        conn.execute("UPDATE credit_months SET used=97 WHERE user_id=?", (u["id"],))
    finally:
        conn.close()
    fake = Fake("anthropic", worst=True)
    install(monkeypatch, {"anthropic": fake})
    c = ai_backend.complete(u["id"], "tutor:check", "SYS", "Lösung", request_id="s1", max_output_tokens=8000)
    got = fake.opts[0]["max_output_tokens"]
    assert 400 <= got < 8000 and c.credits_charged <= 3, (got, c.credits_charged)
    assert month(u["id"])[1] <= 100
    conn = credits.connect()
    try:
        conn.execute("UPDATE credit_months SET used=100 WHERE user_id=?", (u["id"],))
    finally:
        conn.close()
    with pytest.raises(ai_backend.AIUnavailable) as e:
        ai_backend.complete(u["id"], "tutor:check", "SYS", "Lösung", request_id="s2")
    assert e.value.code == "credits_exhausted" and len(fake.opts) == 1


def test_expired_reservation_never_pushes_past_the_allowance(hosted):
    from datetime import UTC, datetime, timedelta

    from app import credits
    u, _ = user(hosted, "verfallen@beispiel.de", plan="pro_ai")
    t0 = datetime(2026, 11, 10, 9, 0, tzinfo=UTC)
    conn = credits.connect()
    try:
        credits.reserve(conn, u["id"], "alt", "tutor:explain", 30, now=t0)
        later = t0 + timedelta(minutes=20)                   # Reservierung verfaellt, der Rahmen wird anders belegt
        credits.reserve(conn, u["id"], "neu", "tutor:explain", 90, now=later)
        assert credits.settle(conn, u["id"], "alt", 300_000, now=later) == 10, "nur der freie Rest (100 - 90)"
        assert credits.settle(conn, u["id"], "neu", 5_000_000, now=later) == 90, "nie mehr als reserviert"
        b = credits.balance(conn, u["id"], now=later)
        assert (b["used"], b["reserved"], b["remaining"]) == (100, 0, 0)
    finally:
        conn.close()


def test_existing_fake_providers_still_work(hosted):
    """set_provider (alle bisherigen Tests) umgeht den Router weiter."""
    from app import ai_backend
    ai_backend.set_provider(FakeAI())
    assert ai_backend.complete(None, "tutor:explain", "s", "p").text.startswith("Erklärung")
