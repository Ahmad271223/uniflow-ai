"""Weitere Anbieter der StudiNow-KI neben OpenAI (app/ai_backend.OpenAIProvider): DeepSeek ueber einen Anbieter in der EU mit
OpenAI-kompatibler Schnittstelle (Chat Completions) und Claude Sonnet 5.5 ueber die Messages API (Amazon Bedrock in der
EU oder direkt bei Anthropic). Alle liefern dieselbe `Completion` (input_tokens inklusive zwischengespeicherter,
output_tokens inklusive Denk-Tokens), damit app/ai_prices.py und app/credits.py fuer alle gleich rechnen.

Fehler tragen zwei Merkmale fuer app/ai_backend.complete:
- `retryable`: der Anbieter hat nichts berechnet (Verbindung, HTTP-Fehler vor der Antwort) -> naechster Anbieter.
- `started`: der Anbieter hatte schon angenommen (HTTP 200), die Antwort brach ab, ohne Nutzung zu nennen -> kein
  Wechsel; abgerechnet wird die Reservierung (die Obergrenze), damit die Grenze je Konto hart bleibt.

Umgebung (deploy/.env):
    LERNAPP_DEEPSEEK_API_KEY     Schluessel beim EU-Anbieter (Scaleway: IAM-Secret-Key); ohne ihn ist DeepSeek aus
    LERNAPP_DEEPSEEK_BASE_URL    OpenAI-kompatible Adresse (Standard https://api.scaleway.ai/v1). Adressen von DeepSeek
                                 selbst (deepseek.com, China) werden abgelehnt.
    LERNAPP_DEEPSEEK_MODEL       Standard deepseek-v4.1-flash-1017 (braucht einen Preis in app/ai_prices.py)
    LERNAPP_DEEPSEEK_REASONING   reasoning_effort fuer DeepSeek (Standard none: kein Denken, guenstig; leer = nicht senden)
    LERNAPP_ANTHROPIC_BACKEND    bedrock (Standard; AWS, EU-Region) | anthropic (direkt, ohne EU-Verarbeitung)
    LERNAPP_ANTHROPIC_REGION     AWS-Region fuer Bedrock (Standard eu-central-1; nur eu-* erlaubt)
    LERNAPP_ANTHROPIC_API_KEY    Bedrock: API-Schluessel von Bedrock (sonst AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY);
                                 anthropic: Schluessel von Anthropic
    LERNAPP_ANTHROPIC_BASE_URL   andere Adresse (selten noetig)
    LERNAPP_ANTHROPIC_MODEL      Standard anthropic.claude-sonnet-5-5 (Bedrock) bzw. claude-sonnet-5-5 (anthropic)
    LERNAPP_ANTHROPIC_EFFORT     output_config.effort (Standard medium)
    LERNAPP_ANTHROPIC_ALLOW_NON_EU  1 = direkter Weg zu Anthropic trotz fehlender EU-Verarbeitung erlauben (Standard aus)
"""
from __future__ import annotations

import base64
import json
import os
import time
import urllib.error
from urllib.parse import urlparse

from . import ai_prices
from .ai_backend import AIUnavailable, Completion, _error_message, _iter_sse, scrub, urllib_transport

# Hoechstens so lange darf eine Antwort laufen (unter credits.STALE_MINUTES, damit eine Reservierung nie verfaellt, solange
# der Anbieter noch schreibt)
DEADLINE_S = 600
SCALEWAY_URL = "https://api.scaleway.ai/v1"
DEEPSEEK_DEFAULT = "deepseek-v4.1-flash-1017"
BLOCKED_HOST_SUFFIXES = ("deepseek.com", ".cn")       # DeepSeek nur ueber einen Anbieter in der EU (Inhaber, 05.11.2026)


def _n(v) -> int:
    try:
        return max(0, int(v or 0))
    except (TypeError, ValueError):
        return 0


def guarded(lines, deadline_s: float = DEADLINE_S):
    """Zeilen weiterreichen, bis die Frist ablaeuft (dann TimeoutError)."""
    end = time.monotonic() + deadline_s
    for line in lines:
        if time.monotonic() > end:
            raise TimeoutError("Frist der KI-Antwort abgelaufen")
        yield line


def http_error(who: str, status: int, detail: str) -> AIUnavailable:
    """HTTP-Fehler vor der Antwort: der Anbieter hat nichts berechnet. 5xx, 401/403 (Schluessel), 408 und 429 -> Ersatz."""
    retry = status >= 500 or status in (401, 403, 408, 429)
    if status == 429:
        return AIUnavailable("ai_provider_busy", f"{who} ist gerade ausgelastet. Bitte gleich noch einmal.", 503, retryable=True)
    if status == 401:
        return AIUnavailable("ai_provider_error", f"{who} hat den Schlüssel des Dienstes abgelehnt.", 502, retryable=True)
    return AIUnavailable("ai_provider_error", f"{who} antwortete mit Fehler {status}." + (f" {detail[:200]}" if detail else ""), 502,
                         retryable=retry)


# ---------------------------------------------------------------- OpenAI-kompatibel (DeepSeek in der EU)

def check_eu_base_url(url: str) -> str:
    """https-Adresse, nie DeepSeek selbst (Server in China). Wirft AIUnavailable ai_not_configured."""
    u = urlparse((url or "").strip())
    host = (u.hostname or "").lower()
    if u.scheme != "https" or not host:
        raise AIUnavailable("ai_not_configured", "Die Adresse des KI-Anbieters muss mit https:// beginnen.", 503, retryable=True)
    if any(host == s.lstrip(".") or host.endswith(s if s.startswith(".") else "." + s) for s in BLOCKED_HOST_SUFFIXES):
        raise AIUnavailable("ai_not_configured", "DeepSeek nur über einen Anbieter in der EU, nie über die Server von DeepSeek.",
                            503, retryable=True)
    return url.strip().rstrip("/")


class OpenAICompatProvider:
    """Chat Completions einer OpenAI-kompatiblen Schnittstelle (Scaleway u. a.): Ereignisstrom mit
    `stream_options.include_usage`, Nutzung aus `usage` des letzten Ereignisses (prompt_tokens inklusive
    prompt_tokens_details.cached_tokens, completion_tokens inklusive Denk-Tokens). Fehlt die Nutzung, rechnet
    app/ai_backend die Reservierung ab (usage_known=False). `transport` ist fuer Tests austauschbar."""
    supports_options = True

    def __init__(self, base_url: str, api_key: str, model_name: str, *, label: str = "deepseek", timeout: int = 120,
                 transport=None, reasoning_effort: str | None = None):
        self.base_url = check_eu_base_url(base_url)
        self.api_key, self.model, self.label, self.timeout = api_key, model_name, label, timeout
        self.transport = transport or urllib_transport
        self.reasoning_effort = reasoning_effort

    def __repr__(self) -> str:
        return f"{type(self).__name__}(label={self.label!r}, model={self.model!r})"

    def request_body(self, system: str, prompt: str, schema: dict | None = None, *, image: bytes | None = None,
                     max_output_tokens: int | None = None) -> dict:
        content: str | list = prompt
        if image:
            mime = ai_prices.image_mime(image) or "image/jpeg"
            content = [{"type": "text", "text": prompt},
                       {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{base64.b64encode(image).decode('ascii')}"}}]
        body: dict = {"model": self.model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": content}],
                      "stream": True, "stream_options": {"include_usage": True}}
        if max_output_tokens:
            body["max_tokens"] = int(max_output_tokens)
        if self.reasoning_effort:
            body["reasoning_effort"] = self.reasoning_effort
        if schema:
            body["response_format"] = {"type": "json_schema", "json_schema": {"name": "studora", "schema": schema, "strict": False}}
        return body

    def complete(self, system: str, prompt: str, schema: dict | None = None, *, image: bytes | None = None,
                 max_output_tokens: int | None = None, on_delta=None, **_ignored) -> Completion:
        who = "Der KI-Anbieter"
        body = self.request_body(system, prompt, schema, image=image, max_output_tokens=max_output_tokens)
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json", "Accept": "text/event-stream"}
        images = 1 if image else 0
        try:
            status, lines = self.transport(self.base_url + "/chat/completions", headers, json.dumps(body).encode("utf-8"), self.timeout)
        except (urllib.error.URLError, TimeoutError, OSError):
            raise AIUnavailable("ai_provider_unreachable", f"{who} ist nicht erreichbar.", 502, retryable=True)
        if status >= 400:
            raise http_error(who, status, scrub(_error_message("\n".join(lines))))
        deltas: list[str] = []
        usage, finish, model = None, None, self.model
        try:
            for event in _iter_sse(guarded(lines)):
                try:
                    j = json.loads(event)
                except ValueError:
                    continue
                if not isinstance(j, dict):
                    continue
                if isinstance(j.get("error"), dict):
                    err = j["error"]
                    billed = self._completion("".join(deltas), usage, model, images) if usage else None
                    raise AIUnavailable("ai_provider_error", f"{who} antwortete mit Fehler: {scrub(str(err.get('message') or '')[:200])}",
                                        502, billed=billed, started=True)
                model = j.get("model") or model
                if isinstance(j.get("usage"), dict):
                    usage = j["usage"]
                for ch in j.get("choices") or []:
                    if not isinstance(ch, dict):
                        continue
                    piece = str(((ch.get("delta") or {}).get("content")) or "")
                    if piece:
                        deltas.append(piece)
                        if on_delta:
                            on_delta(piece)
                    finish = ch.get("finish_reason") or finish
        except AIUnavailable:
            raise
        except (urllib.error.URLError, TimeoutError, OSError):
            raise AIUnavailable("ai_provider_unreachable", f"{who} hat die Antwort abgebrochen.", 502,
                                billed=self._completion("".join(deltas), usage, model, images) if usage else None, started=True)
        c = self._completion("".join(deltas), usage, model, images)
        if finish == "length":
            raise AIUnavailable("ai_provider_error", f"{who} hat die Antwort nicht beendet (Ausgabegrenze).", 502,
                                billed=c if usage else None, started=True)
        if finish is None and not deltas:
            raise AIUnavailable("ai_provider_error", f"{who} antwortete unlesbar.", 502, started=True)
        return c

    def _completion(self, text: str, usage: dict | None, model: str, images: int) -> Completion:
        u = usage if isinstance(usage, dict) else {}
        d_in = u.get("prompt_tokens_details") if isinstance(u.get("prompt_tokens_details"), dict) else {}
        d_out = u.get("completion_tokens_details") if isinstance(u.get("completion_tokens_details"), dict) else {}
        return Completion(text, _n(u.get("prompt_tokens")), _n(u.get("completion_tokens")), model or self.model,
                          cached_tokens=_n(d_in.get("cached_tokens")), reasoning_tokens=_n(d_out.get("reasoning_tokens")),
                          images=images, provider=self.label, usage_known=bool(usage))


# ---------------------------------------------------------------- Claude (Messages API ueber das Anthropic-SDK)

_UNSUPPORTED_SCHEMA_KEYS = ("minLength", "maxLength", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
                            "minItems", "maxItems", "uniqueItems", "minProperties", "maxProperties")


def claude_schema(schema):
    """JSON-Schema fuer `output_config.format` von Claude: jedes Objekt mit additionalProperties false, Zahl-, Text- und
    Listen-Grenzen entfernt (nicht unterstuetzt; die Aufrufer pruefen die Antwort ohnehin selbst)."""
    if isinstance(schema, list):
        return [claude_schema(x) for x in schema]
    if not isinstance(schema, dict):
        return schema
    out = {k: claude_schema(v) for k, v in schema.items() if k not in _UNSUPPORTED_SCHEMA_KEYS}
    if out.get("type") == "object" or "properties" in out:
        out["additionalProperties"] = False
    return out


class AnthropicProvider:
    """Claude ueber die Messages API mit dem offiziellen SDK (`anthropic`): Amazon Bedrock (Mantle-Endpunkt,
    `AnthropicBedrockMantle`, Region eu-*) oder direkt (`Anthropic`). Antwort als Strom (`messages.stream`), Text aus
    `text_stream`, Nutzung aus der fertigen Nachricht: input_tokens + cache_read_input_tokens (+ Cache-Schreiben mit
    Aufschlag) = Eingabe, output_tokens inklusive Denken. Keine serverseitigen `fallbacks` auf andere Claude-Modelle: deren
    Preis stuende nicht in der Reservierung (harte Grenze je Konto); eine Ablehnung (`refusal`) endet mit einer Meldung.
    `client` ist fuer Tests austauschbar (Attrappe oder SDK mit Test-Transport)."""
    supports_options = True
    label = "anthropic"

    def __init__(self, model_name: str, *, backend: str = "bedrock", region: str = "eu-central-1", api_key: str | None = None,
                 base_url: str | None = None, effort: str | None = "medium", timeout: int = 120, client=None,
                 allow_non_eu: bool = False):
        self.model, self.backend, self.region = model_name, backend, region
        self.api_key, self.base_url, self.effort, self.timeout = api_key, base_url, effort, timeout
        self.client = client
        if client is None:
            if backend == "bedrock" and not (region or "").lower().startswith("eu-"):
                raise AIUnavailable("ai_not_configured", "Claude nur aus einer EU-Region (LERNAPP_ANTHROPIC_REGION=eu-…).", 503,
                                    retryable=True)
            if backend == "anthropic" and not allow_non_eu:
                raise AIUnavailable("ai_not_configured", "Claude direkt bei Anthropic verarbeitet nicht in der EU "
                                    "(LERNAPP_ANTHROPIC_ALLOW_NON_EU=1 zum Erlauben).", 503, retryable=True)

    def __repr__(self) -> str:
        return f"{type(self).__name__}(backend={self.backend!r}, model={self.model!r})"

    def _client(self):
        if self.client is not None:
            return self.client
        try:
            import anthropic
        except ImportError:
            raise AIUnavailable("ai_not_configured", "Das Paket anthropic fehlt auf dem Server (requirements.txt).", 503, retryable=True)
        if self.backend == "bedrock":
            self.client = anthropic.AnthropicBedrockMantle(aws_region=self.region, api_key=self.api_key or None,
                                                           base_url=self.base_url or None, timeout=self.timeout, max_retries=0)
        else:
            self.client = anthropic.Anthropic(api_key=self.api_key, base_url=self.base_url or None, timeout=self.timeout, max_retries=0)
        return self.client

    def request_kwargs(self, system: str, prompt: str, schema: dict | None = None, *, image: bytes | None = None,
                       max_output_tokens: int | None = None) -> dict:
        content: list[dict] = []
        if image:
            mime = ai_prices.image_mime(image) or "image/jpeg"
            content.append({"type": "image", "source": {"type": "base64", "media_type": mime,
                                                        "data": base64.b64encode(image).decode("ascii")}})
        content.append({"type": "text", "text": prompt})
        kwargs: dict = {"model": self.model, "max_tokens": int(max_output_tokens or 2000), "system": system,
                        "messages": [{"role": "user", "content": content}]}
        output_config: dict = {}
        if self.effort:
            output_config["effort"] = self.effort
        if schema:
            output_config["format"] = {"type": "json_schema", "schema": claude_schema(schema)}
        if output_config:
            kwargs["output_config"] = output_config
        return kwargs

    def complete(self, system: str, prompt: str, schema: dict | None = None, *, image: bytes | None = None,
                 max_output_tokens: int | None = None, on_delta=None, **_ignored) -> Completion:
        who = "Claude"
        client = self._client()
        kwargs = self.request_kwargs(system, prompt, schema, image=image, max_output_tokens=max_output_tokens)
        images = 1 if image else 0
        try:
            import anthropic
            errors = (anthropic.APIConnectionError, anthropic.APIStatusError)
        except ImportError:                          # nur mit Attrappe in Tests
            anthropic, errors = None, ()
        started, deltas = False, []
        end = time.monotonic() + DEADLINE_S
        try:
            with client.messages.stream(**kwargs) as stream:
                started = True
                for piece in stream.text_stream:
                    if time.monotonic() > end:
                        raise TimeoutError("Frist der KI-Antwort abgelaufen")
                    if piece:
                        deltas.append(piece)
                        if on_delta:
                            on_delta(piece)
                msg = stream.get_final_message()
        except AIUnavailable:
            raise
        except errors as e:  # type: ignore[misc]
            status = getattr(e, "status_code", None)
            if not started and status:
                raise http_error(who, int(status), scrub(str(getattr(e, "message", "") or "")))
            if not started:
                raise AIUnavailable("ai_provider_unreachable", f"{who} ist nicht erreichbar.", 502, retryable=True)
            raise AIUnavailable("ai_provider_error", f"{who} hat die Antwort abgebrochen.", 502, started=True)
        except (TimeoutError, OSError):
            raise AIUnavailable("ai_provider_unreachable", f"{who} hat die Antwort abgebrochen.", 502, started=started,
                                retryable=not started)
        text = "".join(b.text for b in (getattr(msg, "content", None) or []) if getattr(b, "type", "") == "text") or "".join(deltas)
        c = self.completion(text, msg, images)
        stop = getattr(msg, "stop_reason", None)
        if stop == "refusal":
            raise AIUnavailable("ai_refused", "Claude hat diese Anfrage abgelehnt. Bitte anders formulieren.", 422, billed=c, started=True)
        if stop == "max_tokens":
            raise AIUnavailable("ai_provider_error", f"{who} hat die Antwort nicht beendet (Ausgabegrenze).", 502, billed=c, started=True)
        return c

    def completion(self, text: str, msg, images: int) -> Completion:
        u = getattr(msg, "usage", None)
        fresh, read = _n(getattr(u, "input_tokens", 0)), _n(getattr(u, "cache_read_input_tokens", 0))
        write = _n(getattr(u, "cache_creation_input_tokens", 0))
        # Cache-Schreiben kostet 1,25 x Eingabe: als Eingabe plus ein Viertel zaehlen (der Dienst setzt kein cache_control)
        total_in = fresh + read + write + (write + 3) // 4
        return Completion(text, total_in, _n(getattr(u, "output_tokens", 0)), getattr(msg, "model", None) or self.model,
                          cached_tokens=read, images=images, provider=self.label, usage_known=u is not None)


# ---------------------------------------------------------------- aus der Umgebung

def deepseek_configured() -> bool:
    return bool((os.environ.get("LERNAPP_DEEPSEEK_API_KEY") or "").strip())


def deepseek_model() -> str:
    return (os.environ.get("LERNAPP_DEEPSEEK_MODEL") or DEEPSEEK_DEFAULT).strip()


def deepseek_provider(model_name: str | None = None) -> OpenAICompatProvider:
    effort = os.environ.get("LERNAPP_DEEPSEEK_REASONING") if "LERNAPP_DEEPSEEK_REASONING" in os.environ else "none"
    return OpenAICompatProvider(os.environ.get("LERNAPP_DEEPSEEK_BASE_URL") or SCALEWAY_URL,
                                (os.environ.get("LERNAPP_DEEPSEEK_API_KEY") or "").strip(), model_name or deepseek_model(),
                                label="deepseek", reasoning_effort=(effort or "").strip() or None)


def anthropic_backend() -> str:
    return (os.environ.get("LERNAPP_ANTHROPIC_BACKEND") or "bedrock").strip().lower()


def anthropic_configured() -> bool:
    if anthropic_backend() == "anthropic":
        return bool((os.environ.get("LERNAPP_ANTHROPIC_API_KEY") or "").strip()) and \
            os.environ.get("LERNAPP_ANTHROPIC_ALLOW_NON_EU") == "1"
    return bool((os.environ.get("LERNAPP_ANTHROPIC_API_KEY") or os.environ.get("AWS_ACCESS_KEY_ID")
                 or os.environ.get("AWS_BEARER_TOKEN_BEDROCK") or "").strip())


def anthropic_model() -> str:
    default = "anthropic.claude-sonnet-5-5" if anthropic_backend() == "bedrock" else "claude-sonnet-5-5"
    return (os.environ.get("LERNAPP_ANTHROPIC_MODEL") or default).strip()


def anthropic_provider(model_name: str | None = None) -> AnthropicProvider:
    effort = os.environ.get("LERNAPP_ANTHROPIC_EFFORT") if "LERNAPP_ANTHROPIC_EFFORT" in os.environ else "medium"
    return AnthropicProvider(model_name or anthropic_model(), backend=anthropic_backend(),
                             region=(os.environ.get("LERNAPP_ANTHROPIC_REGION") or "eu-central-1").strip(),
                             api_key=(os.environ.get("LERNAPP_ANTHROPIC_API_KEY") or "").strip() or None,
                             base_url=(os.environ.get("LERNAPP_ANTHROPIC_BASE_URL") or "").strip() or None,
                             effort=(effort or "").strip() or None,
                             allow_non_eu=os.environ.get("LERNAPP_ANTHROPIC_ALLOW_NON_EU") == "1")
