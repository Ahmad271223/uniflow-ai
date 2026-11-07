"""StudiNow-KI ueber das eigene Backend (Pro AI, KI-Tests ab Plus) mit Kostenkontrolle.

Die App ruft nie selbst einen KI-Anbieter mit einem StudiNow-Schluessel auf: alle Anfragen laufen ueber den Dienst.
Anbieter und Modell sind zentral konfiguriert (Umgebung), der Schluessel liegt nur auf dem Server.

    LERNAPP_AI_PROVIDER        leer/mix = Modellmischung aller eingerichteten Anbieter (app/ai_router.py) | openai |
                               deepseek | anthropic = nur dieser | none = aus (DeepSeek nur auf Wunsch, ai_router.OPT_IN)
    LERNAPP_OPENAI_API_KEY     Schluessel des StudiNow-Kontos bei OpenAI (nie in der App, nie im Repo, nie im Protokoll);
                               ersatzweise OPENAI_API_KEY
    LERNAPP_OPENAI_BASE_URL    Standard https://api.openai.com/v1; EU-Datenresidenz: https://eu.api.openai.com/v1 (Projekt
                               mit EU-Region noetig; Preise dann +10 %, app/ai_prices.py)
    LERNAPP_AI_MODEL           OpenAI-Modell der StudiNow-KI (Pflicht fuer OpenAI); DeepSeek und Claude: app/ai_providers.py
    LERNAPP_AI_MODELS          weitere erlaubte Modelle (Komma-Liste), die ein Client ausdruecklich waehlen darf; jedes
                               braucht einen Preis in app/ai_prices.py
    LERNAPP_AI_PRICE_IN_EUR    aeltere Angabe: Preis je 1 Mio. Eingabe-Tokens in EUR fuer alle Modelle (sonst die Tabelle
    LERNAPP_AI_PRICE_OUT_EUR   in app/ai_prices.py); nur wirksam, wenn beide > 0
    LERNAPP_AI_MAX_OUTPUT      Obergrenze der Ausgabe-Tokens je Zweck, z. B. "tutor=2000,flashcards=3000" (MAX_OUTPUT)
    LERNAPP_AI_REASONING_EFFORT Denkaufwand fuer Denkmodelle (Standard low; leer/none = nicht senden)
    LERNAPP_AI_BUDGET_EUR      Gesamtbudget je Monat fuer alle Konten (Standard 50); erreicht -> Sperre
    LERNAPP_AI_USER_BUDGET_EUR Budget je Konto und Monat (Standard 2; die eigentliche Grenze je Konto sind die Credits,
                               app/credits.py)
    LERNAPP_AI_TRIAL_BUDGET_EUR eigenes Budget je Monat fuer alle Probekonten zusammen (Standard 5); die Probe frisst
                               nie das Budget der zahlenden Konten
    LERNAPP_AI_RATE_PER_MINUTE Anfragen je Konto und Minute (Standard 6)
    LERNAPP_AI_RATE_PER_HOUR   Anfragen je Konto und Stunde (Standard 60)
    LERNAPP_AI_LIBRARY_BUDGET_EUR eigenes Budget je Monat fuer die Vorarbeit der Bibliothek (fertige Wochenfragen,
                               app/week_library.py; Standard 20). Eigenes Becken (`library=1`, ohne Konto): die
                               Bibliothek frisst nie das Budget der Konten, die Konten nie das der Bibliothek.

Credits (app/credits.py, 04.11.2026): Fragen, Erklaerungen, Karteikarten, Dokument-Index und Wochentests ueber den
Dienst kosten das Konto Credits (1 Credit = 1 Cent echter Kosten); `complete` reserviert vorher eine Schaetzung und
rechnet danach mit `usage` der Antwort ab. Erzeugen fuer den gemeinsamen Fragenpool der Bibliothek (test_generation) und
die automatischen Wochentests (weekly_test) zaehlen weiter ueber die Kontingente des Tarifs (app/plans.py QUOTAS).

Kostenkontrolle (Tabellen in accounts.db):
- `ai_usage_log`: jede Anfrage mit Konto, Zweck, Modell, Tokens, Kosten (Bibliothek: ohne Konto, `library=1`). Vor dem Aufruf wird in einer
  Schreibtransaktion geprueft (Budget gesamt und je Konto, Rate-Limit) und eine Reservierung mit geschaetzten Kosten
  eingetragen; Probekonten (nur die Probe aktiv) zaehlen in einem eigenen kleineren Becken (`trial=1`); danach werden die echten Tokens und Kosten nachgetragen. Gleichzeitige Anfragen koennen das Budget
  dadurch nicht gemeinsam ueberschreiten.
- `ai_inflight`: Sperre je Generierungsschluessel (z. B. Fach+Thema+Schwierigkeit). Eine zweite gleiche Generierung
  wartet auf die erste und nutzt deren Ergebnis, statt doppelt zu bezahlen.
- `ai_cache`: Antworten fuer gleiche Anfragen (gleicher Zweck, gleicher Text), 30 Tage; das Modell gehoert nicht zum
  Schluessel (eine Antwort von OpenAI gilt auch fuer den naechsten, den der Router zu Sonnet schicken wuerde), es wird
  aber mit gespeichert (`model`).

Modellmischung (05.11.2026, app/ai_router.py, docs/KI-MODELLMISCHUNG-2026-11-05.md): je Anfrage waehlt der Router
deterministisch aus request_id und Zweck einen Anbieter (Standard: OpenAI gpt-6-luna etwa 75 %, Claude Sonnet 5.5 ueber
Bedrock Frankfurt etwa 25 % fuer schwere Faelle; DeepSeek in der EU nur auf Wunsch). Vor dem Aufruf wird die harte Obergrenze (app/ai_prices.worst_case_microeur) fuer das TEUERSTE Modell
der Kette reserviert; reicht der Rest der Credits nicht, wird die Ausgabegrenze verkleinert oder abgelehnt. Faellt der
gewaehlte Anbieter aus, ohne etwas zu berechnen (5xx, 429, keine Verbindung), uebernimmt der naechste innerhalb derselben
Reservierung; abgerechnet wird genau einmal. So verursacht ein Konto nie mehr als seine Credits (Pro AI 100 = 1 EUR).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import time
import urllib.error
import uuid
import urllib.request
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from . import ai_prices, billing, config, db

SCHEMA = """
CREATE TABLE IF NOT EXISTS ai_usage_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT,
    period TEXT NOT NULL,
    purpose TEXT NOT NULL,                -- test_generation | explain | summary | questions | ...
    provider TEXT,
    model TEXT,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    cost_microeur INTEGER NOT NULL DEFAULT 0,  -- Millionstel EUR
    trial INTEGER NOT NULL DEFAULT 0,          -- 1 = Probekonto (eigenes Budget-Becken)
    library INTEGER NOT NULL DEFAULT 0,        -- 1 = Vorarbeit der Bibliothek fuer alle Konten (eigenes Becken, ohne Konto)
    state TEXT NOT NULL DEFAULT 'reserved',    -- reserved | done | failed
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ai_usage_period ON ai_usage_log(period);
CREATE INDEX IF NOT EXISTS idx_ai_usage_user ON ai_usage_log(user_id, created_at);
CREATE TABLE IF NOT EXISTS ai_inflight (
    key TEXT PRIMARY KEY,
    user_id TEXT,
    started_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS ai_cache (
    key TEXT PRIMARY KEY,
    result TEXT NOT NULL,
    created_at TEXT NOT NULL,
    model TEXT                             -- welches Modell die Antwort erzeugt hat (nicht Teil des Schluessels)
);
"""

RESERVE_MICROEUR = 20_000           # Reservierung je Anfrage vor dem Aufruf (2 Cent), danach echte Kosten
INFLIGHT_STALE_S = 600
CACHE_DAYS = 30

# Obergrenze der Ausgabe-Tokens je Zweck (Denk-Tokens zaehlen mit); ueberschreibbar mit LERNAPP_AI_MAX_OUTPUT
MAX_OUTPUT = {"tutor": 2000, "flashcards": 3000, "doc_index_page": 3000, "week_test": 9000, "test_generation": 8000,
              "weekly_test": 9000, "study_plan": 4000, "default": 2000}
# Zwecke, die das Konto Credits kosten (app/credits.py); alles mit "tutor:" am Anfang auch
CREDIT_PURPOSES = ("flashcards", "doc_index_page", "week_test", "study_plan")


class AIUnavailable(Exception):
    def __init__(self, code: str, message: str, status: int = 503, extra: dict | None = None, billed: "Completion | None" = None,
                 *, retryable: bool = False, started: bool = False):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status
        # extra: zusaetzliche Felder fuer die Antwort (z. B. Credits); billed: Nutzung, die der Anbieter trotz Fehler
        # berechnet hat (abgebrochene Antwort) - die wird abgerechnet, nicht zurueckgegeben
        self.extra, self.billed = extra or {}, billed
        # retryable: der Anbieter hat nichts berechnet, der naechste der Kette darf uebernehmen (app/ai_router.py);
        # started: der Anbieter hatte angenommen, die Nutzung ist unbekannt -> die Reservierung wird abgerechnet
        self.retryable, self.started = retryable, started


@dataclass
class Completion:
    text: str
    input_tokens: int
    output_tokens: int
    model: str
    cached_tokens: int = 0
    reasoning_tokens: int = 0
    images: int = 0
    credits_charged: int = 0
    credits_reserved: int = 0
    replay: bool = False
    provider: str = ""                # Anbieter, der geantwortet hat (openai | deepseek | anthropic | Attrappe)
    usage_known: bool = True          # False: Anbieter nannte keine Nutzung -> die Reservierung wird abgerechnet
    source_model: str = ""            # bei Treffern im Zwischenspeicher: Modell, das die Antwort erzeugt hat

    @staticmethod
    def from_usage(text: str, data: dict, model: str, images: int = 0) -> "Completion":
        """Aus der fertigen Antwort der Responses API: input_tokens (inkl. cached), output_tokens (inkl. Denk-Tokens)."""
        usage = data.get("usage") if isinstance(data, dict) and isinstance(data.get("usage"), dict) else {}
        details_in = usage.get("input_tokens_details") if isinstance(usage.get("input_tokens_details"), dict) else {}
        details_out = usage.get("output_tokens_details") if isinstance(usage.get("output_tokens_details"), dict) else {}

        def n(v) -> int:
            try:
                return max(0, int(v or 0))
            except (TypeError, ValueError):
                return 0
        return Completion(text, n(usage.get("input_tokens")), n(usage.get("output_tokens")),
                          (data.get("model") if isinstance(data, dict) else None) or model,
                          cached_tokens=n(details_in.get("cached_tokens")), reasoning_tokens=n(details_out.get("reasoning_tokens")),
                          images=images, provider="openai")


# ---------------------------------------------------------------- Konfiguration

def _env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


def api_key() -> str:
    """Schluessel des Dienstes bei OpenAI; wird nie protokolliert und nie in einer Antwort genannt."""
    return (os.environ.get("LERNAPP_OPENAI_API_KEY") or os.environ.get("OPENAI_API_KEY") or "").strip()


def provider_name() -> str:
    """mix (Standard, sobald irgendein Anbieter eingerichtet ist) | openai | deepseek | anthropic | none."""
    p = (os.environ.get("LERNAPP_AI_PROVIDER") or "").strip().lower()
    if not p or p == "mix":
        return "mix" if configured_providers(ignore_choice=True) else "none"
    return p


def openai_base_url() -> str:
    return ((os.environ.get("LERNAPP_OPENAI_BASE_URL") or "").strip() or "https://api.openai.com/v1").rstrip("/")


def configured_providers(ignore_choice: bool = False) -> set[str]:
    """Anbieter mit Schluessel (und Modell); LERNAPP_AI_PROVIDER=openai|deepseek|anthropic laesst nur diesen, none keinen.
    DeepSeek ist standardmaessig aus (ai_router.OPT_IN, Inhaber 05.11.2026): er zaehlt nur mit Schluessel UND wenn
    LERNAPP_AI_ROUTES ihn nennt oder LERNAPP_AI_PROVIDER=deepseek gilt."""
    from . import ai_providers, ai_router
    out = set()
    choice = (os.environ.get("LERNAPP_AI_PROVIDER") or "").strip().lower()
    if api_key() and model():
        out.add("openai")
    if ai_providers.deepseek_configured() and (choice == "deepseek" or ai_router.named_in_config("deepseek")):
        out.add("deepseek")
    if ai_providers.anthropic_configured():
        out.add("anthropic")
    if ignore_choice:
        return out
    if choice in ("", "mix"):
        return out
    return out & {choice}


def model() -> str:
    return (os.environ.get("LERNAPP_AI_MODEL") or "").strip()


def allowed_models() -> list[str]:
    """Modelle, die ein Client ausdruecklich waehlen darf: LERNAPP_AI_MODEL und LERNAPP_AI_MODELS (Komma-Liste)."""
    out = [model()] if model() else []
    for m in (os.environ.get("LERNAPP_AI_MODELS") or "").split(","):
        m = m.strip()
        if m and m not in out:
            out.append(m)
    return out


def max_output(purpose: str) -> int:
    """Obergrenze der Ausgabe-Tokens fuer einen Zweck (tutor:explain -> tutor)."""
    kind = "tutor" if purpose.startswith("tutor") else purpose
    limits = dict(MAX_OUTPUT)
    for part in (os.environ.get("LERNAPP_AI_MAX_OUTPUT") or "").split(","):
        k, _, v = part.partition("=")
        if k.strip() and v.strip().isdigit() and 64 <= int(v) <= 64_000:
            limits[k.strip()] = int(v)
    return limits.get(kind, limits["default"])


def reasoning_effort() -> str | None:
    v = (os.environ.get("LERNAPP_AI_REASONING_EFFORT") if "LERNAPP_AI_REASONING_EFFORT" in os.environ else "low") or ""
    v = v.strip().lower()
    return None if v in ("", "none", "off") else v


def charges_credits(purpose: str) -> bool:
    return purpose.startswith("tutor:") or purpose in CREDIT_PURPOSES


def budget_microeur() -> int:
    return int(_env_float("LERNAPP_AI_BUDGET_EUR", 50.0) * 1_000_000)


def user_budget_microeur() -> int:
    return int(_env_float("LERNAPP_AI_USER_BUDGET_EUR", 2.0) * 1_000_000)


def trial_budget_microeur() -> int:
    return int(_env_float("LERNAPP_AI_TRIAL_BUDGET_EUR", 5.0) * 1_000_000)


def library_budget_microeur() -> int:
    return int(_env_float("LERNAPP_AI_LIBRARY_BUDGET_EUR", 20.0) * 1_000_000)


def rate_per_minute() -> int:
    return int(_env_float("LERNAPP_AI_RATE_PER_MINUTE", 6))


def prices_set(model_name: str | None = None) -> bool:
    """Gibt es einen Preis fuer das Modell (Tabelle app/ai_prices.py, LERNAPP_AI_PRICES oder die aeltere EUR-Angabe)?"""
    return ai_prices.known(model_name if model_name is not None else model())


def cost_microeur(input_tokens: int, output_tokens: int, model_name: str | None = None, cached_tokens: int = 0) -> int:
    """Kosten in Millionstel EUR (eine Quelle: app/ai_prices.py)."""
    return ai_prices.cost_microeur(model_name if model_name is not None else model(), input_tokens, output_tokens, cached_tokens)


# ---------------------------------------------------------------- Anbieter

_KEY_RE = re.compile(r"sk-[A-Za-z0-9_\-*.]{3,}")
_AWS_KEY_RE = re.compile(r"\b(AKIA|ASIA)[A-Z0-9]{12,}\b")


def scrub(text: str) -> str:
    """Schluessel nie weitergeben: OpenAI nennt bei 401 einen Teil davon in der Fehlermeldung."""
    return _AWS_KEY_RE.sub("AKIA***", _KEY_RE.sub("sk-***", text or ""))


def urllib_transport(url: str, headers: dict, body: bytes, timeout: float):
    """Standard-Transport: (Status, Zeilen der Antwort als Iterator). Zeilen kommen beim Eintreffen (Ereignisstrom), damit
    der Dienst sie weiterreichen kann. Netzfehler (URLError, Zeitueberschreitung) wirft er unveraendert."""
    req = urllib.request.Request(url, data=body, method="POST", headers=headers)
    try:
        r = urllib.request.urlopen(req, timeout=timeout)  # noqa: S310 - feste https-Adresse
    except urllib.error.HTTPError as e:
        try:
            text = e.read().decode("utf-8", "replace")[:4000]
        except Exception:  # noqa: BLE001
            text = ""
        return e.code, iter(text.splitlines())

    def lines():
        with r:
            for raw in r:
                yield raw.decode("utf-8", "replace").rstrip("\r\n")
    return getattr(r, "status", 200), lines()


def _error_message(raw: str) -> str:
    try:
        j = json.loads(raw)
    except ValueError:
        return raw.strip()[:300]
    err = j.get("error") if isinstance(j, dict) else None
    if isinstance(err, dict):
        return str(err.get("message") or err.get("code") or "")[:300]
    return ""


class OpenAIProvider:
    """Responses API von OpenAI mit dem StudiNow-Schluessel des Servers (urllib, keine Zusatzpakete). Antwort immer als
    Ereignisstrom (`stream: true`), ausgewertet mit `consume_stream`; Text, optional ein Bild der Seite (`input_image`,
    data-URL), Obergrenze der Ausgabe (`max_output_tokens`), keine Speicherung bei OpenAI (`store: false`). `transport`
    ist fuer Tests austauschbar (Attrappe mit SSE und usage)."""
    URL = "https://api.openai.com/v1/responses"
    label = "openai"
    supports_options = True

    def __init__(self, api_key: str, model_name: str, timeout: int = 120, transport=None, base_url: str | None = None):
        self.api_key, self.model, self.timeout = api_key, model_name, timeout
        self.transport = transport or urllib_transport
        if base_url:                                 # EU-Datenresidenz: https://eu.api.openai.com/v1
            self.URL = base_url.rstrip("/") + "/responses"

    def __repr__(self) -> str:                       # nie den Schluessel zeigen
        return f"{type(self).__name__}(model={self.model!r})"

    def request_body(self, system: str, prompt: str, schema: dict | None = None, *, image: bytes | None = None,
                     max_output_tokens: int | None = None, cache_key: str | None = None, user_tag: str | None = None) -> dict:
        import base64
        content: list[dict] = [{"type": "input_text", "text": prompt}]
        if image:
            mime = ai_prices.image_mime(image) or "image/jpeg"
            content.append({"type": "input_image", "image_url": f"data:{mime};base64,{base64.b64encode(image).decode('ascii')}",
                            "detail": "high"})
        body: dict = {"model": self.model, "instructions": system, "input": [{"role": "user", "content": content}],
                      "store": False, "stream": True}
        if max_output_tokens:
            body["max_output_tokens"] = int(max_output_tokens)
        p = ai_prices.price(self.model)
        effort = reasoning_effort()
        if effort and p and p.reasoning:
            body["reasoning"] = {"effort": effort}
        if schema:
            body["text"] = {"format": {"type": "json_schema", "name": "studora", "schema": schema, "strict": False}}
        if cache_key:
            body["prompt_cache_key"] = cache_key[:64]
        if user_tag:
            body["safety_identifier"] = user_tag[:64]
        return body

    def complete(self, system: str, prompt: str, schema: dict | None = None, *, image: bytes | None = None,
                 max_output_tokens: int | None = None, on_delta=None, cache_key: str | None = None,
                 user_tag: str | None = None) -> Completion:
        body = self.request_body(system, prompt, schema, image=image, max_output_tokens=max_output_tokens, cache_key=cache_key,
                                 user_tag=user_tag)
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json", "Accept": "text/event-stream"}
        from .ai_providers import guarded, http_error
        try:
            status, lines = self.transport(self.URL, headers, json.dumps(body).encode("utf-8"), self.timeout)
        except (urllib.error.URLError, TimeoutError, OSError):
            raise AIUnavailable("ai_provider_unreachable", "Der KI-Anbieter ist nicht erreichbar.", 502, retryable=True)
        if status >= 400:
            raise http_error("Der KI-Anbieter", status, scrub(_error_message("\n".join(lines))))
        try:
            text, data = consume_stream(guarded(lines), on_delta=on_delta, who="Der KI-Anbieter", model=self.model, images=1 if image else 0)
        except AIUnavailable as e:
            e.started = True                         # angenommen, dann abgebrochen: kein Wechsel des Anbieters
            raise
        except (urllib.error.URLError, TimeoutError, OSError):
            raise AIUnavailable("ai_provider_unreachable", "Der KI-Anbieter hat die Antwort abgebrochen.", 502, started=True)
        return Completion.from_usage(text, data, self.model, images=1 if image else 0)


class ChatGPTProvider(OpenAIProvider):
    """Responses API mit dem ChatGPT-Abo des Nutzers (Sign in with ChatGPT, app/chatgpt_login.py): das Zugriffstoken
    kommt je Anfrage aus der Ablage dieses Rechners (erneuert sich selbst), nie ein StudiNow-Schluessel. Mit diesem
    Token verlangt OpenAI `store: false` und `stream: true` je Anfrage, `input` als Liste und die Antwort als
    Ereignisstrom bis `response.completed` (Doku "Preview limitations", 3.11.2026). 401 heisst "neu anmelden",
    402/403/429 "Kontingent aufgebraucht oder Nutzung in Apps nicht freigegeben" (Nutzung verwalten in ChatGPT)."""

    LIMIT_MESSAGE = ("Dein ChatGPT-Kontingent ist aufgebraucht oder die Nutzung in Apps ist nicht freigegeben. "
                     "In ChatGPT unter Einstellungen → Nutzung verwalten.")
    LOGIN_MESSAGE = "Die Anmeldung bei ChatGPT ist abgelaufen – bitte in den Einstellungen neu verbinden."

    label = "chatgpt"

    def __init__(self, model_name: str, timeout: int = 120):
        super().__init__("", model_name, timeout)

    @staticmethod
    def request_body(model: str, system: str, prompt: str, schema: dict | None = None, image: bytes | None = None) -> dict:
        """Anfrage an `POST /v1/responses` mit dem Token des Abos (wie Swift `ChatGPTProtocol.responsesBody`); mit `image`
        geht die Seite als `input_image` (data-URL) mit, wie `ChatGPTVisionAI` auf dem Geraet."""
        content: str | list = prompt
        if image:
            import base64
            mime = ai_prices.image_mime(image) or "image/jpeg"
            content = [{"type": "input_text", "text": prompt},
                       {"type": "input_image", "image_url": f"data:{mime};base64,{base64.b64encode(image).decode('ascii')}"}]
        body: dict = {"model": model, "instructions": system, "input": [{"role": "user", "content": content}], "store": False, "stream": True}
        if schema:
            body["text"] = {"format": {"type": "json_schema", "name": "studora", "schema": schema, "strict": False}}
        return body

    @staticmethod
    def request_headers(token: str) -> dict[str, str]:
        """Kopfzeilen: Bearer, JSON, Antwort als Ereignisstrom, `originator` = Name der App, und – falls das Token die
        Kennung des ChatGPT-Kontos nennt – `chatgpt-account-id` wie der Codex-Client."""
        from . import chatgpt_login
        h = {"Authorization": f"Bearer {token}", "Content-Type": "application/json", "Accept": "text/event-stream",
             "originator": chatgpt_login.AGENT_NAME}
        acct = chatgpt_login.account_id_from_token(token)
        if acct:
            h["chatgpt-account-id"] = acct
        return h

    def complete(self, system: str, prompt: str, schema: dict | None = None, *, image: bytes | None = None, **_options) -> Completion:
        """Mit dem Abo des Nutzers: Ausgabegrenze und Cache-Schluessel gehen hier nicht mit (Vorgaben des Abos)."""
        from . import chatgpt_login
        try:
            token = chatgpt_login.access_token()
        except chatgpt_login.ChatGPTError as e:
            raise AIUnavailable(e.code, e.message, e.status)
        body = self.request_body(self.model, system, prompt, schema, image)
        req = urllib.request.Request(self.URL, data=json.dumps(body).encode("utf-8"), method="POST", headers=self.request_headers(token))
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:  # noqa: S310 - feste https-Adresse
                raw = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = chatgpt_login._error_text(e.read().decode("utf-8", "replace")[:600])
            except Exception:  # noqa: BLE001
                pass
            if e.code == 401:
                chatgpt_login.mark_reauth(why=f"Responses API 401: {detail[:120]}")
                raise AIUnavailable("chatgpt_login_needed", "Die Anmeldung bei ChatGPT ist abgelaufen – bitte in den Einstellungen neu verbinden.", 401)
            if e.code in (402, 403, 429):
                raise AIUnavailable("chatgpt_limit", "Dein ChatGPT-Kontingent ist aufgebraucht oder die Nutzung in Apps ist nicht "
                                    "freigegeben. In ChatGPT unter Einstellungen → Nutzung verwalten.", 429)
            raise AIUnavailable("ai_provider_error", f"ChatGPT antwortete mit Fehler {e.code}: {detail[:200]}", 502)
        except (urllib.error.URLError, TimeoutError, OSError):
            raise AIUnavailable("ai_provider_unreachable", "ChatGPT ist nicht erreichbar.", 502)
        text, data = stream_text(raw)
        return Completion.from_usage(text, data, self.model, images=1 if image else 0)


def _iter_sse(lines) -> "Iterator[str]":
    """`data:`-Inhalte der Ereignisse eines SSE-Stroms, Zeile fuer Zeile beim Eintreffen (mehrzeilige `data:` je Ereignis
    zusammengefuegt, `event:` und Kommentare uebergangen, `[DONE]` ausgelassen)."""
    current: list[str] = []
    for line in lines:
        for part in str(line).replace("\r\n", "\n").replace("\r", "\n").split("\n"):
            if not part:
                d = "\n".join(current)
                current.clear()
                if d and d != "[DONE]":
                    yield d
                continue
            if part.startswith("data:"):
                current.append(part[5:].removeprefix(" "))
    d = "\n".join(current)
    if d and d != "[DONE]":
        yield d


def _sse_events(raw: str) -> list[str]:
    """Alle `data:`-Inhalte eines vollstaendigen SSE-Stroms (siehe _iter_sse)."""
    return list(_iter_sse([raw]))


def _stream_error(code: str | None, message: str | None, who: str = "ChatGPT", billed: Completion | None = None) -> AIUnavailable:
    """Fehlercodes der Responses API fuer das ChatGPT-Abo (developers.openai.com/siwc/…/errors-and-recovery)."""
    c, m = code or "", scrub((message or "")[:200])
    if c in ("subscription_sharing_usage_limit_exceeded", "subscription_sharing_user_not_eligible"):
        return AIUnavailable("chatgpt_limit", ChatGPTProvider.LIMIT_MESSAGE, 429)
    if c in ("subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable"):
        return AIUnavailable("ai_provider_error", "ChatGPT kann die Nutzung deines Abos gerade nicht prüfen – bitte später noch einmal versuchen.", 502)
    if c == "subscription_sharing_invalid_user":
        return AIUnavailable("chatgpt_login_needed", ChatGPTProvider.LOGIN_MESSAGE, 401)
    return AIUnavailable("ai_provider_error", f"{who} antwortete mit Fehler" + (f" {c}" if c else "") + (f": {m}" if m else "."), 502,
                         billed=billed)


def _output_text(d: dict) -> str:
    return "".join(c.get("text", "") for item in d.get("output") or [] if isinstance(item, dict) and item.get("type") == "message"
                   for c in item.get("content") or [] if isinstance(c, dict) and c.get("type") == "output_text")


TRUNCATED_NOTE = "\n\n*(Die Antwort wurde hier gekürzt. Frag nach dem Rest, z. B. „Erkläre ab Aufgabe 5“.)*"


def _consume(events, on_delta=None, who: str = "ChatGPT", model: str = "", images: int = 0) -> tuple[str, dict]:
    """Ereignisse der Responses API auswerten (siehe stream_text). `on_delta` bekommt jedes Textstueck beim Eintreffen.
    Bricht die Antwort ab (failed, incomplete), traegt der Fehler die schon berechnete Nutzung (`billed`)."""
    deltas, completed, saw = [], None, False
    for event in events:
        try:
            j = json.loads(event)
        except ValueError:
            continue
        if not isinstance(j, dict):
            continue
        saw = True
        t = j.get("type") or ""
        resp = j.get("response") if isinstance(j.get("response"), dict) else None
        if t == "response.output_text.delta":
            piece = str(j.get("delta") or "")
            deltas.append(piece)
            if on_delta and piece:
                on_delta(piece)
        elif t == "response.completed":
            completed = resp if resp is not None else {}
        elif t == "response.failed":
            err = resp.get("error") if resp is not None else None
            err = err if isinstance(err, dict) else (j.get("error") if isinstance(j.get("error"), dict) else {})
            billed = Completion.from_usage("", resp, model, images) if resp and resp.get("usage") else None
            raise _stream_error(err.get("code"), err.get("message"), who, billed)
        elif t == "error":
            raise _stream_error(j.get("code"), j.get("message"), who)
        elif t == "response.incomplete":
            why = ((resp or {}).get("incomplete_details") or {}).get("reason") or "unvollständig"
            text = "".join(deltas)
            # Ausgabegrenze erreicht (Test 06.11.2026: "Alle Aufgaben" auf 12 Seiten brauchte 4 360 Tokens): der Nutzer hat
            # den Text bezahlt, also bekommt er ihn mit einem Hinweis statt eines Fehlers. JSON-Antworten scheitern weiter
            # beim Auslesen, freier Text ist auch gekuerzt brauchbar.
            if why == "max_output_tokens" and text.strip() and resp is not None:
                return text + TRUNCATED_NOTE, {**resp, "truncated": True}
            billed = Completion.from_usage(text, resp, model, images) if resp and resp.get("usage") else None
            raise AIUnavailable("ai_provider_error", f"{who} hat die Antwort nicht beendet ({str(why)[:80]}).", 502, billed=billed)
    if completed is None:
        raise AIUnavailable("ai_provider_error", f"{who} hat die Antwort nicht beendet (kein response.completed)." if saw
                            else f"{who} antwortete unlesbar.", 502)
    final = _output_text(completed)
    return (final or "".join(deltas)), completed


def _plain_json(stripped: str, who: str) -> tuple[str, dict]:
    try:
        data = json.loads(stripped)
    except ValueError:
        raise AIUnavailable("ai_provider_error", f"{who} antwortete unlesbar.", 502)
    err = data.get("error") if isinstance(data, dict) else None
    if isinstance(err, dict):
        raise _stream_error(err.get("code"), err.get("message"), who)
    return _output_text(data), data


def stream_text(raw: str) -> tuple[str, dict]:
    """Antwort von `POST /v1/responses` mit `stream: true` (wie Swift `ChatGPTProtocol.streamedText`): Server-Sent
    Events, je Ereignis `data:` mit JSON und `type`. Fertig erst mit `response.completed` (Text aus der fertigen
    Antwort, sonst die gesammelten `response.output_text.delta`); `response.failed`, `error` und `response.incomplete`
    sind Fehler, ein Strom ohne Abschluss auch. Eine gewoehnliche JSON-Antwort wird wie bisher gelesen. Liefert
    (Text, fertige Antwort)."""
    stripped = raw.strip()
    if stripped.startswith("{"):
        return _plain_json(stripped, "ChatGPT")
    return _consume(_sse_events(raw))


def consume_stream(lines, on_delta=None, who: str = "Der KI-Anbieter", model: str = "", images: int = 0) -> tuple[str, dict]:
    """Wie stream_text, aber Zeile fuer Zeile (Ereignisse koennen beim Eintreffen weitergereicht werden). Beginnt die
    Antwort mit `{`, ist es gewoehnliches JSON."""
    it = iter(lines)
    head: list[str] = []
    for line in it:
        head.append(line)
        if str(line).strip():
            break
    if head and str(head[-1]).lstrip().startswith("{"):
        return _plain_json("\n".join(head + list(it)).strip(), who)

    def chained():
        yield from head
        yield from it
    return _consume(_iter_sse(chained()), on_delta, who, model, images)


_provider_override = None


def set_provider(p) -> None:
    """Fuer Tests: Attrappe statt OpenAI (None = wieder aus der Konfiguration)."""
    global _provider_override
    _provider_override = p


def _not_configured() -> AIUnavailable:
    return AIUnavailable("ai_not_configured", "Die StudiNow-KI ist auf dem Server noch nicht eingerichtet.")


def build(provider_label: str, model_name: str | None = None):
    """Anbieter-Objekt fuer openai | deepseek | anthropic (Modell aus der Umgebung, wenn keins genannt)."""
    from . import ai_providers
    if provider_label == "openai":
        if not api_key() or not (model_name or model()):
            raise _not_configured()
        return OpenAIProvider(api_key(), model_name or model(), base_url=openai_base_url())
    if provider_label == "deepseek":
        return ai_providers.deepseek_provider(model_name)
    if provider_label == "anthropic":
        return ai_providers.anthropic_provider(model_name)
    raise _not_configured()


def provider(model_name: str | None = None):
    """Erster Anbieter fuer eine Anfrage ohne Zweck (Vorpruefungen). `model_name` (Wunsch des Clients) muss in
    allowed_models() stehen, sonst 400 model_not_allowed."""
    return route("default", "probe", model_name=model_name)[0]


def route(purpose: str, request_id: str, *, model_name: str | None = None, image: bytes | None = None,
          route_text: str | None = None, route_hint: str | None = None) -> list:
    """Anbieter-Kette einer Anfrage (app/ai_router.py): [gewaehlt, Ersatz ...]. Mit `model_name` genau dieses Modell
    (beim Anbieter laut app/ai_prices.py). Tests: set_provider ersetzt alles durch eine Attrappe."""
    from . import ai_router
    if model_name and model_name not in allowed_models():
        raise AIUnavailable("model_not_allowed", "Dieses Modell ist für die StudiNow-KI nicht freigegeben.", 400)
    if _provider_override is not None:
        return [_provider_override]
    configured = configured_providers()
    if not configured:
        raise _not_configured()
    if model_name:
        prov = ai_prices.provider_of(model_name)
        if prov not in configured:
            raise _not_configured()
        return [build(prov, model_name)]

    def vision_ok(c) -> bool:
        p = ai_prices.price(c.model or _default_model(c.provider))
        return p is None or p.vision
    choices, _hard = ai_router.chain(purpose, request_id, configured=configured, route_text=route_text, hint=route_hint,
                                     needs_vision=bool(image), vision_ok=vision_ok)
    out = []
    for c in choices:
        try:
            out.append(build(c.provider, c.model))
        except AIUnavailable:                        # falsch eingerichtet (z. B. Adresse in China): ueberspringen
            continue
    if not out:
        raise _not_configured()
    return out


def _default_model(provider_label: str) -> str:
    from . import ai_providers
    return {"openai": model(), "deepseek": ai_providers.deepseek_model(),
            "anthropic": ai_providers.anthropic_model()}.get(provider_label, "")


def estimate_model(purpose: str) -> str | None:
    """Modell fuer die Kostenzeile vor einem Lauf (app/doc_explain_api.py): das teuerste Modell des Weges dieses Zwecks
    unter den eingerichteten Anbietern - die Zeile verspricht so nie zu wenig."""
    from . import ai_router
    if _provider_override is not None:
        return getattr(_provider_override, "model", None) or model()
    configured = configured_providers()
    choices, _ = ai_router.chain(purpose, "estimate", configured=configured)
    best, best_out = None, -1.0
    for c in choices[:max(1, len(ai_router.route_for(purpose)))]:
        m = c.model or _default_model(c.provider)
        p = ai_prices.price(m)
        if p and p.output_eur > best_out:
            best, best_out = m, p.output_eur
    return best or model()


def available() -> bool:
    try:
        provider()
        return True
    except AIUnavailable:
        return False


# ---------------------------------------------------------------- Budget, Rate-Limit, Protokoll

def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)
    cols = {r[1] for r in conn.execute("PRAGMA table_info(ai_usage_log)")}
    if "trial" not in cols:                                       # Tabelle aus aelterem Stand
        conn.execute("ALTER TABLE ai_usage_log ADD COLUMN trial INTEGER NOT NULL DEFAULT 0")
    if "library" not in cols:
        conn.execute("ALTER TABLE ai_usage_log ADD COLUMN library INTEGER NOT NULL DEFAULT 0")
    if "model" not in {r[1] for r in conn.execute("PRAGMA table_info(ai_cache)")}:
        conn.execute("ALTER TABLE ai_cache ADD COLUMN model TEXT")


def connect() -> sqlite3.Connection:
    from . import accounts, credits
    conn = billing.connect()
    db.schema_once(conn, "ai_backend", accounts.db_path(), ensure_schema)
    db.schema_once(conn, "credits", accounts.db_path(), credits.ensure_schema)      # Credits in derselben Datei
    return conn


def is_trial_account(conn: sqlite3.Connection, user_id: str, t: datetime) -> bool:
    """Probekonto: die Probe ist aktiv und kein bezahlter oder von Hand gesetzter Tarif (auch nicht aus `users.plan`)."""
    now_iso = t.isoformat()
    trial = False
    for source, plan, expires, status in conn.execute("SELECT source, plan, expires_at, status FROM entitlements WHERE user_id=?",
                                                      (str(user_id),)):
        if billing.normalize_plan(plan) not in (None, "free") and billing._row_active(status, expires, now_iso):
            if source != "trial":
                return False
            trial = True
    if not trial:
        return False
    try:
        u = conn.execute("SELECT plan, plan_until FROM users WHERE id=?", (str(user_id),)).fetchone()
    except sqlite3.OperationalError:                 # accounts.db ohne Konten-Tabelle (nur Abrechnung angelegt)
        u = None
    if u and billing.normalize_plan(u[0]) not in (None, "free") and (not u[1] or str(u[1])[:10] >= now_iso[:10]):
        return False
    return True


def _now(now: datetime | None = None) -> datetime:
    return (now or datetime.now(timezone.utc)).astimezone(timezone.utc)


def rate_per_hour() -> int:
    return int(_env_float("LERNAPP_AI_RATE_PER_HOUR", 60))


def _library_pool(conn: sqlite3.Connection, period: str) -> int:
    return conn.execute("SELECT COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE period=? AND state<>'failed' AND library=1",
                        (period,)).fetchone()[0]


def library_exhausted() -> AIUnavailable:
    return AIUnavailable("ai_library_budget_exhausted", "Die Bibliothek hat ihr KI-Budget für diesen Monat aufgebraucht. "
                         "Fertige Fragen, die schon da sind, gehen weiter; neue Wochen kommen im nächsten Monat dazu.", 429)


def check_library(calls: int = 1, now: datetime | None = None) -> None:
    """Vorpruefung vor einer Vorarbeit der Bibliothek (mehrere Aufrufe): Anbieter eingerichtet, Preise gesetzt (Dienst),
    Budget der Bibliothek reicht fuer `calls` Reservierungen. Wirft AIUnavailable (503 bzw. 429), sonst nichts."""
    chain = route("library", "check")
    if config.is_hosted() and not any(prices_set(getattr(p, "model", None) or model()) for p in chain):
        raise AIUnavailable("ai_not_configured_prices", "Die StudiNow-KI ist noch nicht freigeschaltet: Die Token-Preise "
                            "(LERNAPP_AI_PRICE_IN_EUR / LERNAPP_AI_PRICE_OUT_EUR) fehlen auf dem Server.", 503)
    conn = connect()
    try:
        if _library_pool(conn, _now(now).strftime("%Y-%m")) + RESERVE_MICROEUR * max(1, calls) > library_budget_microeur():
            raise library_exhausted()
    finally:
        conn.close()


def reserve(conn: sqlite3.Connection, user_id: str | None, purpose: str, now: datetime | None = None, *,
            rate_limit: bool = True, amount_microeur: int | None = None, library: bool = False) -> int:
    """Budget und Rate-Limit pruefen und eine Reservierung eintragen (atomar). Liefert die Protokoll-ID.
    `rate_limit=False` fuer Auftraege des Dienstes selbst (Seiten eines Index-Uploads nacheinander, Wiederholungen nach
    einer unbrauchbaren Antwort); `amount_microeur` = Reservierung statt der festen 2 Cent (Schaetzung der Anfrage).
    `library=True`: Vorarbeit der Bibliothek fuer alle Konten; nur das eigene Becken (LERNAPP_AI_LIBRARY_BUDGET_EUR)
    zaehlt, ohne Konto, ohne Budget und Rate-Limit je Konto (die Sperre je Inhalt verhindert Doppeltes)."""
    t = _now(now)
    period = t.strftime("%Y-%m")
    amount = max(RESERVE_MICROEUR, int(amount_microeur or 0))
    conn.execute("BEGIN IMMEDIATE")
    if library:
        try:
            if _library_pool(conn, period) + RESERVE_MICROEUR > library_budget_microeur():
                raise library_exhausted()
            cur = conn.execute("INSERT INTO ai_usage_log(user_id, period, purpose, cost_microeur, trial, library, state, created_at) "
                               "VALUES (NULL,?,?,?,0,1,'reserved',?)", (period, purpose, RESERVE_MICROEUR, t.isoformat()))
            conn.execute("COMMIT")
            return cur.lastrowid
        except Exception:
            conn.execute("ROLLBACK")
            raise
    try:
        trial = 1 if user_id and is_trial_account(conn, user_id, t) else 0
        # zwei Becken: Probekonten verbrauchen nur ihr eigenes kleines Budget, nie das der zahlenden Konten
        pool = conn.execute("SELECT COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE period=? AND state<>'failed' AND trial=? "
                            "AND library=0", (period, trial)).fetchone()[0]
        if trial:
            if pool + amount > trial_budget_microeur():
                raise AIUnavailable("ai_trial_budget_exhausted", "Das Probe-Kontingent der StudiNow-KI ist für diesen Monat ausgeschöpft.", 429)
        elif pool + amount > budget_microeur():
            raise AIUnavailable("ai_budget_exhausted", "Das KI-Budget von StudiNow für diesen Monat ist ausgeschöpft.", 503)
        if user_id:
            mine = conn.execute("SELECT COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE period=? AND user_id=? AND state<>'failed'",
                                (period, user_id)).fetchone()[0]
            if mine + amount > user_budget_microeur():
                raise AIUnavailable("ai_user_budget_exhausted", "Dein KI-Kostenrahmen für diesen Monat ist erreicht.", 429)
            if rate_limit:
                recent = conn.execute("SELECT COUNT(*) FROM ai_usage_log WHERE user_id=? AND created_at>?",
                                      (user_id, (t - timedelta(seconds=60)).isoformat())).fetchone()[0]
                if recent >= rate_per_minute():
                    raise AIUnavailable("ai_rate_limited", "Zu viele KI-Anfragen in kurzer Zeit. Bitte gleich noch einmal.", 429)
                hour = conn.execute("SELECT COUNT(*) FROM ai_usage_log WHERE user_id=? AND created_at>?",
                                    (user_id, (t - timedelta(hours=1)).isoformat())).fetchone()[0]
                if hour >= rate_per_hour():
                    raise AIUnavailable("ai_rate_limited", "Zu viele KI-Anfragen in dieser Stunde. Bitte später noch einmal.", 429)
        cur = conn.execute("INSERT INTO ai_usage_log(user_id, period, purpose, cost_microeur, trial, state, created_at) VALUES (?,?,?,?,?,?,?)",
                           (user_id, period, purpose, amount, trial, "reserved", t.isoformat()))
        conn.execute("COMMIT")
        return cur.lastrowid
    except Exception:
        conn.execute("ROLLBACK")
        raise


def _cost(c: Completion, requested_model: str | None) -> int:
    """Kosten aus der echten Nutzung; nennt die Antwort ein Modell ohne Preis, gilt der Preis des angefragten Modells."""
    m = c.model if ai_prices.known(c.model) else requested_model
    return cost_microeur(c.input_tokens, c.output_tokens, m, c.cached_tokens)


def settle(conn: sqlite3.Connection, log_id: int, c: Completion | None, provider_label: str = "", requested_model: str | None = None,
           cost_override: int | None = None) -> int:
    """Protokollzeile abschliessen; liefert die Kosten in Millionstel EUR (0 bei Fehler ohne Nutzung). `cost_override`:
    Nutzung unbekannt -> die reservierte Obergrenze."""
    if c is None:
        conn.execute("UPDATE ai_usage_log SET state='failed', cost_microeur=0 WHERE id=?", (log_id,))
        return 0
    cost = int(cost_override) if cost_override is not None else _cost(c, requested_model)
    conn.execute("UPDATE ai_usage_log SET state='done', provider=?, model=?, input_tokens=?, output_tokens=?, cost_microeur=? WHERE id=?",
                 (provider_label, c.model, c.input_tokens, c.output_tokens, cost, log_id))
    return cost


def month_report(conn: sqlite3.Connection, now: datetime | None = None) -> dict:
    period = _now(now).strftime("%Y-%m")
    r = conn.execute("""SELECT COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cost_microeur),0)
                        FROM ai_usage_log WHERE period=? AND state='done'""", (period,)).fetchone()
    lib = conn.execute("SELECT COUNT(*), COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE period=? AND state='done' AND library=1",
                       (period,)).fetchone()
    by = conn.execute("SELECT COALESCE(provider, ''), COUNT(*), COALESCE(SUM(cost_microeur),0) FROM ai_usage_log "
                      "WHERE period=? AND state='done' GROUP BY provider", (period,)).fetchall()
    return {"period": period, "requests": r[0], "input_tokens": r[1], "output_tokens": r[2],
            "cost_eur": round(r[3] / 1_000_000, 6), "budget_eur": budget_microeur() / 1_000_000,
            "library_requests": lib[0], "library_cost_eur": round(lib[1] / 1_000_000, 6),
            "library_budget_eur": library_budget_microeur() / 1_000_000,
            "by_provider": {p or "?": {"requests": n, "cost_eur": round(cst / 1_000_000, 6),
                                       "share": round(n / r[0], 4) if r[0] else 0.0} for p, n, cst in by}}


def user_tag(user_id: str | None) -> str | None:
    """Nicht umkehrbare Kennung des Kontos fuer OpenAI (`safety_identifier`, Missbrauchserkennung); nie die Konto-ID."""
    if not user_id:
        return None
    return hashlib.sha256(f"studinow-safety:{user_id}".encode()).hexdigest()[:32]


def credits_balance(user_id: str | None, now: datetime | None = None) -> dict | None:
    """Stand der Credits des Kontos im laufenden Monat (app/credits.py) fuer die Antworten an den Client; None ohne Konto
    oder am eigenen PC (dort gibt es keine Credits)."""
    if not user_id or not config.is_hosted():
        return None
    from . import credits as ledger
    conn = connect()
    try:
        return ledger.balance(conn, user_id, now)
    finally:
        conn.close()


def replay(user_id: str | None, request_id: str | None, now: datetime | None = None) -> Completion | None:
    """Dieselbe request_id noch einmal (Wiederholung nach Netzfehler): die innerhalb von 24 h gespeicherte Antwort kommt
    ohne neue Kosten zurueck (replay=True); laeuft die Anfrage noch, 409 duplicate_request. None = neue Anfrage. Die
    Endpunkte fragen das vor dem Kontingent (app/entitlements.py), das dieselbe ID sonst als Doppelte abweist."""
    if not user_id or not request_id or not config.is_hosted():
        return None
    from . import credits as ledger
    conn = connect()
    try:
        found = ledger.lookup(conn, user_id, request_id, now)
    finally:
        conn.close()
    if not found:
        return None
    state, result = found
    if state == "reserved":
        raise AIUnavailable("duplicate_request", "Diese Anfrage läuft schon.", 409)
    if state in ("settled", "free") and result is not None:
        return Completion(result, 0, 0, "replay", replay=True)
    return None


MIN_SHRUNK_OUTPUT = 400          # kleiner wird eine Ausgabegrenze beim Verkleinern nie (sonst lieber 429 credits_exhausted)


def _prices_missing() -> AIUnavailable:
    return AIUnavailable("ai_not_configured_prices", "Die StudiNow-KI ist noch nicht freigeschaltet: Die Token-Preise "
                         "fuer das Modell fehlen auf dem Server (app/ai_prices.py, LERNAPP_AI_PRICES oder "
                         "LERNAPP_AI_PRICE_IN_EUR / LERNAPP_AI_PRICE_OUT_EUR).", 503)


def complete(user_id: str | None, purpose: str, system: str, prompt: str, schema: dict | None = None,
             cache: bool = False, now: datetime | None = None, *, image: bytes | None = None, model_name: str | None = None,
             max_output_tokens: int | None = None, request_id: str | None = None, credits: bool | None = None,
             rate_limit: bool = True, on_delta=None, keep_result: bool = False, budget_reserve: int | None = None,
             library: bool = False, route_hint: str | None = None, route_text: str | None = None, fresh: bool = False) -> Completion:
    """Eine StudiNow-KI-Anfrage mit Budget, Rate-Limit, Credits (app/credits.py), Protokoll und optionalem Cache.

    Modellmischung (app/ai_router.py): der Router waehlt aus request_id und Zweck einen Anbieter, schwere Faelle
    (`route_hint` "hard"/"second_opinion", Rechnen in `route_text` = Frage oder Markierung) gehen an Sonnet.
    credits: None = automatisch (im Dienst fuer Konten bei den Zwecken aus charges_credits). Vor dem Aufruf wird die
    harte Obergrenze (app/ai_prices.worst_case_microeur) fuer das teuerste Modell der Kette reserviert - reicht der Rest
    nicht, wird `max_output_tokens` verkleinert (hoechstens bis MIN_SHRUNK_OUTPUT), sonst 429 credits_exhausted. Danach
    wird mit `usage` abgerechnet (nie mehr als reserviert); ein Fehler ohne Nutzung gibt die Reservierung zurueck und
    der naechste Anbieter der Kette uebernimmt, wenn der erste nichts berechnet hat. Dieselbe request_id wird nie zweimal
    berechnet (`keep_result`: die Antwort bleibt 24 h fuer eine Wiederholung). image: Seite als PNG/JPEG.
    `library=True`: Vorarbeit der Bibliothek (eigenes Monatsbudget, ohne Konto und ohne Credits; `user_id` wird dann
    nicht gespeichert). `fresh=True` ("Neu erklaeren lassen"): den Zwischenspeicher nicht lesen, die neue Antwort ersetzt
    die gespeicherte."""
    from . import ai_consent, credits as ledger
    # Web-Oberflaeche des Dienstes: kein Anbieter ohne Einwilligung des Kontos (428 ai_consent_required)
    ai_consent.require_hosted(library)
    if library:
        user_id = None
    rid = request_id or ("auto:" + uuid.uuid4().hex)
    # vor der Reservierung: nicht eingerichtet -> nichts protokollieren
    chain = route(purpose, rid, model_name=model_name, image=image, route_text=route_text, route_hint=route_hint)
    models = [model_name or getattr(p, "model", None) or model() for p in chain]
    hosted = config.is_hosted()
    if hosted:
        # ohne Token-Preise rechnet kein Budget (Kosten blieben 0): im Dienst lieber sperren als unbegrenzt ausgeben
        keep = [i for i, m in enumerate(models) if prices_set(m)]
        if not keep:
            raise _prices_missing()
        chain, models = [chain[i] for i in keep], [models[i] for i in keep]
    requested = models[0]
    charge = bool(user_id) and (credits if credits is not None else (hosted and charges_credits(purpose)))
    max_out = int(max_output_tokens or max_output(purpose))
    images = [image] if image else None

    def worst(out_tokens: int) -> int:
        return max(ai_prices.worst_case_microeur(m, system, prompt, out_tokens, images, schema) for m in models)

    def estimate(out_tokens: int) -> int:
        return max(ai_prices.estimate_credits(m, system, prompt, out_tokens, images, schema=schema) for m in models)
    conn = connect()
    try:
        key = None
        if cache and not image:
            # ohne Modell im Schluessel: dieselbe Antwort gilt fuer jedes Modell der Mischung (gespeichert wird, wer sie schrieb)
            key = "c2:" + hashlib.sha256(json.dumps([purpose, system, prompt, schema], sort_keys=True).encode()).hexdigest()
            hit = None if fresh else conn.execute("SELECT result, created_at, model FROM ai_cache WHERE key=?", (key,)).fetchone()
            if hit and hit[1] >= (_now(now) - timedelta(days=CACHE_DAYS)).isoformat():
                return Completion(hit[0], 0, 0, "cache", source_model=hit[2] or "")
        held = None
        if charge:
            try:
                held = ledger.reserve(conn, user_id, rid, purpose, estimate(max_out), now, model=requested)
            except ledger.CreditsError as e:
                remaining = int(((e.extra or {}).get("credits") or {}).get("remaining") or 0)
                fit = min(ai_prices.max_output_within(m, system, prompt, remaining * ai_prices.MICROEUR_PER_CREDIT, images, schema)
                          for m in models) if e.code == "credits_exhausted" and remaining > 0 else 0
                fit = min(fit, max_out - 1)
                if fit < min(MIN_SHRUNK_OUTPUT, max_out - 1) or estimate(fit) > remaining:
                    raise AIUnavailable(e.code, e.message, e.status, e.extra)
                max_out = fit                        # kleinere Antwort, die sicher in den Rest passt
                try:
                    held = ledger.reserve(conn, user_id, rid, purpose, estimate(max_out), now, model=requested)
                except ledger.CreditsError as e2:
                    raise AIUnavailable(e2.code, e2.message, e2.status, e2.extra)
            if held.replay:
                if held.result is not None:
                    return Completion(held.result, 0, 0, requested, credits_charged=0, replay=True)
                raise AIUnavailable("duplicate_request", "Diese Anfrage wurde schon verarbeitet.", 409)
        ceiling = worst(max_out)                     # hoechstens so viel kann diese Anfrage kosten (auch mit Ersatz)
        try:
            # Becken (gesamt, Probe, je Konto): Reservierung wie bisher; die harte Grenze je Konto halten die Credits
            log_id = reserve(conn, user_id, purpose, now, rate_limit=rate_limit, amount_microeur=budget_reserve, library=library)
        except Exception:
            if held:
                ledger.refund(conn, user_id, rid)
            raise

        def book(c: Completion, label: str, used_model: str, cost_override: int | None = None) -> int:
            cost = settle(conn, log_id, c, label, used_model, cost_override)
            if held:
                c.credits_charged = ledger.settle(conn, user_id, rid, cost, model=c.model, input_tokens=c.input_tokens,
                                                  cached_tokens=c.cached_tokens, output_tokens=c.output_tokens, images=c.images,
                                                  result=c.text if keep_result and c.text else None, now=now)
                c.credits_reserved = held.reserved
            return cost
        c = None
        for i, p in enumerate(chain):
            label = getattr(p, "label", type(p).__name__)
            opts = {}
            if getattr(p, "supports_options", False):
                opts = {"image": image, "max_output_tokens": max_out, "on_delta": on_delta,
                        "cache_key": "studinow:" + purpose.split(":", 1)[0], "user_tag": user_tag(user_id)}
            try:
                c = p.complete(system, prompt, schema, **opts) if opts else p.complete(system, prompt, schema)
            except AIUnavailable as e:
                if e.retryable and e.billed is None and not e.started and i + 1 < len(chain):
                    continue                         # nichts berechnet: der naechste Anbieter, dieselbe Reservierung
                if e.billed is not None:             # der Anbieter hat schon gerechnet (abgebrochene Antwort): abrechnen
                    if not e.billed.provider:
                        e.billed.provider = label
                    book(e.billed, label, models[i], None if e.billed.usage_known else ceiling)
                    if held:
                        e.extra = {**e.extra, "credits_charged": e.billed.credits_charged}
                elif e.started:                      # angenommen, Nutzung unbekannt: die Obergrenze abrechnen
                    gone = Completion("", 0, 0, models[i], provider=label, usage_known=False)
                    book(gone, label, models[i], ceiling)
                    if held:
                        e.extra = {**e.extra, "credits_charged": gone.credits_charged}
                else:
                    settle(conn, log_id, None)
                    if held:
                        ledger.refund(conn, user_id, rid)
                raise
            except Exception:
                settle(conn, log_id, None)
                if held:
                    ledger.refund(conn, user_id, rid)
                raise
            if not c.provider:
                c.provider = label
            book(c, label, models[i], None if c.usage_known else ceiling)
            break
        if key and c is not None and c.text:
            conn.execute("INSERT OR REPLACE INTO ai_cache(key, result, created_at, model) VALUES (?,?,?,?)",
                         (key, c.text, _now(now).isoformat(), c.model))
        return c
    finally:
        conn.close()


# ---------------------------------------------------------------- Sperre gegen doppelte Generierung

def acquire(key: str, user_id: str | None = None, now: datetime | None = None) -> bool:
    """True: diese Anfrage generiert; False: eine gleiche Generierung laeuft schon (nicht aelter als 10 Minuten)."""
    t = _now(now)
    conn = connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute("DELETE FROM ai_inflight WHERE key=? AND started_at<?", (key, (t - timedelta(seconds=INFLIGHT_STALE_S)).isoformat()))
            got = conn.execute("INSERT OR IGNORE INTO ai_inflight(key, user_id, started_at) VALUES (?,?,?)",
                               (key, user_id, t.isoformat())).rowcount == 1
            conn.execute("COMMIT")
            return got
        except Exception:
            conn.execute("ROLLBACK")
            raise
    finally:
        conn.close()


def release(key: str) -> None:
    conn = connect()
    try:
        conn.execute("DELETE FROM ai_inflight WHERE key=?", (key,))
    finally:
        conn.close()


def wait_for(key: str, timeout_s: float = 30.0, poll_s: float = 0.1) -> bool:
    """Wartet, bis die laufende Generierung fertig ist. True, wenn sie in der Zeit fertig wurde."""
    end = time.monotonic() + timeout_s
    while time.monotonic() < end:
        conn = connect()
        try:
            busy = conn.execute("SELECT 1 FROM ai_inflight WHERE key=?", (key,)).fetchone()
        finally:
            conn.close()
        if not busy:
            return True
        time.sleep(poll_s)
    return False
