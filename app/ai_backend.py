"""StudiNow-KI ueber das eigene Backend (Pro AI, KI-Tests ab Plus) mit Kostenkontrolle.

Die App ruft nie selbst einen KI-Anbieter mit einem StudiNow-Schluessel auf: alle Anfragen laufen ueber den Dienst.
Anbieter und Modell sind zentral konfiguriert (Umgebung), der Schluessel liegt nur auf dem Server.

    LERNAPP_AI_PROVIDER        leer/mix = Modellmischung aller eingerichteten Anbieter (app/ai_router.py) | openai |
                               deepseek | anthropic = nur dieser | none = aus (DeepSeek nur auf Wunsch, ai_router.OPT_IN)
    LERNAPP_OPENAI_API_KEY     Schluessel des StudiNow-Kontos bei OpenAI (nie in der App, nie im Repo, nie im Protokoll);
                               ersatzweise OPENAI_API_KEY
    LERNAPP_OPENAI_BASE_URL    Standard https://api.openai.com/v1; EU-Datenresidenz: https://eu.api.openai.com/v1 (Projekt
                               mit EU-Region noetig; Preise dann +10 %, app/ai_prices.py). Im Dienst nur diese beiden
                               https-Adressen (check_openai_base_url), am PC auch Testserver.
    LERNAPP_AI_MODEL           OpenAI-Modell der StudiNow-KI (Pflicht fuer OpenAI); DeepSeek und Claude: app/ai_providers.py
    LERNAPP_AI_MODELS          weitere erlaubte Modelle (Komma-Liste), die ein Client ausdruecklich waehlen darf; jedes
                               braucht einen Preis in app/ai_prices.py
    LERNAPP_AI_PRICE_IN_EUR    aeltere Angabe: Preis je 1 Mio. Eingabe-Tokens in EUR fuer alle Modelle (sonst die Tabelle
    LERNAPP_AI_PRICE_OUT_EUR   in app/ai_prices.py); nur wirksam, wenn beide > 0
    LERNAPP_AI_MAX_OUTPUT      Obergrenze der Ausgabe-Tokens je Zweck, z. B. "tutor=2000,flashcards=3000" (MAX_OUTPUT)
    LERNAPP_AI_REASONING_EFFORT Denkaufwand fuer Denkmodelle (REASONING_EFFORTS, Standard low; leer/none = nicht senden)
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
Dienst kosten das Konto Credits (1 Credit = 0,9 Cent echter Kosten); `complete` reserviert vorher eine Schaetzung und
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

import asyncio
import hashlib
import json
import math
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
from urllib.parse import urlparse

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
-- Laufende Monatssummen (08.11.2026, Lastfestigkeit): die Budgetpruefung je Anfrage liest eine Zeile statt den ganzen
-- Monat zu summieren (19 ms bei 100k, 62 ms bei 300k Zeilen unter Schreibsperre). Trigger halten sie mit ai_usage_log
-- gleich (jede Einfuegung, Aenderung, Loeschung; nur Zeilen mit state<>'failed' zaehlen), ensure_schema baut sie beim
-- Start neu auf. pool = paid | trial | library (dieselben Becken wie vorher: library=1, sonst trial=1, sonst paid).
CREATE TABLE IF NOT EXISTS ai_usage_month (
    period TEXT NOT NULL,
    pool TEXT NOT NULL,
    cost_microeur INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (period, pool)
);
CREATE TABLE IF NOT EXISTS ai_usage_user_month (
    period TEXT NOT NULL,
    user_id TEXT NOT NULL,
    cost_microeur INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (period, user_id)
);
"""

# Beitrag einer Zeile von ai_usage_log zu den Monatssummen und ihr Becken (fuer die Trigger und den Neuaufbau)
_POOL_SQL = "CASE WHEN {r}.library=1 THEN 'library' WHEN {r}.trial=1 THEN 'trial' ELSE 'paid' END"
_COST_SQL = "CASE WHEN {r}.state<>'failed' THEN {r}.cost_microeur ELSE 0 END"

TRIGGERS = """
CREATE TRIGGER IF NOT EXISTS trg_ai_usage_month_ins AFTER INSERT ON ai_usage_log BEGIN
    INSERT INTO ai_usage_month(period, pool, cost_microeur) VALUES (NEW.period, {pool_new}, {cost_new})
        ON CONFLICT(period, pool) DO UPDATE SET cost_microeur = cost_microeur + excluded.cost_microeur;
    INSERT INTO ai_usage_user_month(period, user_id, cost_microeur) SELECT NEW.period, NEW.user_id, {cost_new} WHERE NEW.user_id IS NOT NULL
        ON CONFLICT(period, user_id) DO UPDATE SET cost_microeur = cost_microeur + excluded.cost_microeur;
END;
CREATE TRIGGER IF NOT EXISTS trg_ai_usage_month_upd AFTER UPDATE OF period, trial, library, state, cost_microeur, user_id ON ai_usage_log BEGIN
    UPDATE ai_usage_month SET cost_microeur = cost_microeur - ({cost_old}) WHERE period=OLD.period AND pool={pool_old};
    INSERT INTO ai_usage_month(period, pool, cost_microeur) VALUES (NEW.period, {pool_new}, {cost_new})
        ON CONFLICT(period, pool) DO UPDATE SET cost_microeur = cost_microeur + excluded.cost_microeur;
    UPDATE ai_usage_user_month SET cost_microeur = cost_microeur - ({cost_old}) WHERE period=OLD.period AND user_id=OLD.user_id;
    INSERT INTO ai_usage_user_month(period, user_id, cost_microeur) SELECT NEW.period, NEW.user_id, {cost_new} WHERE NEW.user_id IS NOT NULL
        ON CONFLICT(period, user_id) DO UPDATE SET cost_microeur = cost_microeur + excluded.cost_microeur;
END;
CREATE TRIGGER IF NOT EXISTS trg_ai_usage_month_del AFTER DELETE ON ai_usage_log BEGIN
    UPDATE ai_usage_month SET cost_microeur = cost_microeur - ({cost_old}) WHERE period=OLD.period AND pool={pool_old};
    UPDATE ai_usage_user_month SET cost_microeur = cost_microeur - ({cost_old}) WHERE period=OLD.period AND user_id=OLD.user_id;
END;
""".format(pool_new=_POOL_SQL.format(r="NEW"), cost_new=_COST_SQL.format(r="NEW"),
           pool_old=_POOL_SQL.format(r="OLD"), cost_old=_COST_SQL.format(r="OLD"))

RESERVE_MICROEUR = 20_000           # Reservierung je Anfrage vor dem Aufruf (2 Cent), danach echte Kosten
# Sperre gegen doppelte Generierung: verwaist erst nach 30 min - deutlich ueber der Frist einer Antwort (DEADLINE_S 600 s,
# dazu Ersatzanbieter und Wiederholungen); vorher galt eine noch laufende Generierung nach 600 s schon als verwaist (Audit P9-04)
INFLIGHT_STALE_S = 1800
WAIT_MAX_S = 60.0          # wait_for wartet hoechstens so lange (library_api reicht `wait_s` des Clients durch)
WAIT_POLL_MIN_S = 0.05     # und fragt hoechstens 20-mal je Sekunde
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
        # http_status: Antwortcode des Anbieters vor der Antwort (ai_providers.http_error); 0 = Netzfehler oder kein HTTP-Fehler
        self.http_status = 0

    def quick_retry_ok(self) -> bool:
        """Darf derselbe Anbieter EINMAL sofort noch einmal gefragt werden? Nur Netzfehler (nicht erreichbar) oder 5xx vor
        der Antwort, bei denen nichts berechnet wurde - nicht bei 429 (ausgelastet), 401/403 (Schluessel), 4xx."""
        return self.retryable and self.billed is None and not self.started and \
            (self.code == "ai_provider_unreachable" or (self.code == "ai_provider_error" and self.http_status >= 500))


TIMEOUT_MIN_S, TIMEOUT_MAX_S = 5, 600         # Obergrenze = ai_providers.DEADLINE_S (Audit P6-01, 08.11.2026)


def timeout_s() -> int:
    """Zeitlimit je Verbindung zum Anbieter (Verbinden, Warten auf das naechste Stueck): LERNAPP_AI_TIMEOUT_S, Standard
    90 s (vorher 120; 08.11.2026), 5 bis 600 s; nan/inf/unlesbar = Standard. Die Gesamtdauer einer Antwort begrenzt
    ai_providers.DEADLINE_S."""
    try:
        v = float(os.environ.get("LERNAPP_AI_TIMEOUT_S") or 90)
    except ValueError:
        return 90
    if not math.isfinite(v):
        return 90
    return int(min(TIMEOUT_MAX_S, max(TIMEOUT_MIN_S, v)))


RETRY_FAST_S = 10        # eine sofortige Wiederholung beim selben Anbieter nur, wenn der Fehler schnell kam (kein Zeitlimit)


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
        # Nutzung genannt? Ohne input_tokens/output_tokens gilt sie als unbekannt, und der Dienst rechnet die Obergrenze
        # ab (usage_known=False, _Call.succeed) - fehlende Zahlen sind nie "kostenlos" (Audit P7-07, 08.11.2026)
        known = any(k in usage for k in ("input_tokens", "output_tokens"))
        return Completion(text, n(usage.get("input_tokens")), n(usage.get("output_tokens")),
                          (data.get("model") if isinstance(data, dict) else None) or model,
                          cached_tokens=n(details_in.get("cached_tokens")), reasoning_tokens=n(details_out.get("reasoning_tokens")),
                          images=images, provider="openai", usage_known=known)


# ---------------------------------------------------------------- Konfiguration

def _env_float(name: str, default: float, low: float = 0.0) -> float:
    """Zahl aus der Umgebung; nur endliche Werte >= `low`, sonst der Standard (Audit P7-01/P6-03, 08.11.2026: `nan`
    und `inf` liessen int() in budget_microeur/rate_per_minute abstuerzen, negative Budgets sperrten alles)."""
    try:
        v = float(os.environ.get(name, default))
    except ValueError:
        return default
    return v if math.isfinite(v) and v >= low else default


def _env_rate(name: str, default: int) -> int:
    """Anfragen je Zeitraum: ganze Zahl >= 1 (0 oder negativ wuerde jede Anfrage sperren, Audit P7-02)."""
    return int(_env_float(name, default, low=1.0))


def api_key() -> str:
    """Schluessel des Dienstes bei OpenAI; wird nie protokolliert und nie in einer Antwort genannt."""
    return (os.environ.get("LERNAPP_OPENAI_API_KEY") or os.environ.get("OPENAI_API_KEY") or "").strip()


def provider_name() -> str:
    """mix (Standard, sobald irgendein Anbieter eingerichtet ist) | openai | deepseek | anthropic | none."""
    p = (os.environ.get("LERNAPP_AI_PROVIDER") or "").strip().lower()
    if not p or p == "mix":
        return "mix" if configured_providers(ignore_choice=True) else "none"
    return p


OPENAI_HOSTS = ("api.openai.com", "eu.api.openai.com")


def openai_base_url() -> str:
    return ((os.environ.get("LERNAPP_OPENAI_BASE_URL") or "").strip() or "https://api.openai.com/v1").rstrip("/")


def check_openai_base_url(url: str) -> str:
    """Im Dienst geht der Schluessel des Dienstes nur per https an OpenAI selbst (OPENAI_HOSTS); eine andere Adresse in
    LERNAPP_OPENAI_BASE_URL ist eine Fehlkonfiguration -> ai_not_configured (Audit P7-03/P6-04, 08.11.2026). Am eigenen
    PC (local) bleiben Testserver wie http://127.0.0.1 erlaubt."""
    if not config.is_hosted():
        return url
    u = urlparse(url)
    host = (u.hostname or "").lower()
    if u.scheme != "https" or host not in OPENAI_HOSTS:
        raise AIUnavailable("ai_not_configured", "LERNAPP_OPENAI_BASE_URL muss im Dienst eine https-Adresse von OpenAI sein "
                            "(api.openai.com oder eu.api.openai.com).", 503, retryable=True)
    return url


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


REASONING_EFFORTS = ("minimal", "low", "medium", "high", "xhigh")       # Werte der Responses API (reasoning.effort)


def reasoning_effort() -> str | None:
    """Denkaufwand fuer Denkmodelle: einer aus REASONING_EFFORTS, leer/none/off = nicht senden; ein unbekannter Wert
    wuerde JEDE Anfrage beim Anbieter scheitern lassen, darum gilt dann der Standard low (Audit P6-06, 08.11.2026)."""
    v = (os.environ.get("LERNAPP_AI_REASONING_EFFORT") if "LERNAPP_AI_REASONING_EFFORT" in os.environ else "low") or ""
    v = v.strip().lower()
    if v in ("", "none", "off"):
        return None
    return v if v in REASONING_EFFORTS else "low"


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
    return _env_rate("LERNAPP_AI_RATE_PER_MINUTE", 6)


def prices_set(model_name: str | None = None) -> bool:
    """Gibt es einen Preis fuer das Modell (Tabelle app/ai_prices.py, LERNAPP_AI_PRICES oder die aeltere EUR-Angabe)?"""
    return ai_prices.known(model_name if model_name is not None else model())


def cost_microeur(input_tokens: int, output_tokens: int, model_name: str | None = None, cached_tokens: int = 0) -> int:
    """Kosten in Millionstel EUR (eine Quelle: app/ai_prices.py)."""
    return ai_prices.cost_microeur(model_name if model_name is not None else model(), input_tokens, output_tokens, cached_tokens)


# ---------------------------------------------------------------- Anbieter

_KEY_RE = re.compile(r"sk-[A-Za-z0-9_\-*.]{3,}")
_AWS_KEY_RE = re.compile(r"\b(AKIA|ASIA)[A-Z0-9]{12,}\b")
_BEARER_RE = re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=\-]{8,}")
_BEDROCK_KEY_RE = re.compile(r"\bABSK[A-Za-z0-9+/=]{16,}")
# Umgebungsvariablen mit Geheimnissen des Dienstes: ihr Wert wird in Fehlertexten immer ersetzt, egal welche Form er hat
_SECRET_ENV = ("LERNAPP_OPENAI_API_KEY", "OPENAI_API_KEY", "LERNAPP_DEEPSEEK_API_KEY", "LERNAPP_ANTHROPIC_API_KEY",
               "AWS_SECRET_ACCESS_KEY", "AWS_BEARER_TOKEN_BEDROCK", "AWS_SESSION_TOKEN")


def scrub(text: str) -> str:
    """Schluessel nie weitergeben (die Endpunkte reichen e.message als `detail` an den Client): OpenAI nennt bei 401
    einen Teil des Schluessels, andere Anbieter den Bearer-Header. Muster (sk-, AKIA/ASIA, ABSK von Bedrock, "Bearer …")
    plus die tatsaechlich eingerichteten Geheimnisse aus der Umgebung (Audit P7-04/P6-07, 08.11.2026)."""
    out = text or ""
    for name in _SECRET_ENV:
        secret = (os.environ.get(name) or "").strip()
        if len(secret) >= 8 and secret in out:
            out = out.replace(secret, "***")
    out = _BEARER_RE.sub("Bearer ***", out)
    return _BEDROCK_KEY_RE.sub("ABSK***", _AWS_KEY_RE.sub("AKIA***", _KEY_RE.sub("sk-***", out)))


ERROR_BODY_BYTES = 16_384            # hoechstens so viel eines Fehlerkoerpers lesen (Audit P7-05)
MAX_RESPONSE_BYTES = 16 * 1024 * 1024  # ChatGPT-Abo am PC: ganze Antwort im Speicher, aber nie unbegrenzt
MAX_STREAM_TEXT_CHARS = 4_000_000      # hoechstens so viel Text einer gestreamten Antwort (64 000 Tokens sind ~250 000 Zeichen)


async def aread_limited(r, limit: int | None = None) -> bytes:
    """Fehlerkoerper einer httpx-Antwort lesen, hoechstens `limit` Bytes (Standard ERROR_BODY_BYTES; Audit P9-06: vorher
    `aread()` ohne Grenze, gekuerzt erst danach)."""
    limit = ERROR_BODY_BYTES if limit is None else limit
    buf = bytearray()
    async for chunk in r.aiter_bytes():
        buf += chunk
        if len(buf) >= limit:
            break
    return bytes(buf[:limit])


def urllib_transport(url: str, headers: dict, body: bytes, timeout: float):
    """Standard-Transport: (Status, Zeilen der Antwort als Iterator). Zeilen kommen beim Eintreffen (Ereignisstrom), damit
    der Dienst sie weiterreichen kann. Netzfehler (URLError, Zeitueberschreitung) wirft er unveraendert."""
    req = urllib.request.Request(url, data=body, method="POST", headers=headers)
    try:
        r = urllib.request.urlopen(req, timeout=timeout)  # noqa: S310 - feste https-Adresse
    except urllib.error.HTTPError as e:
        try:
            text = e.read(ERROR_BODY_BYTES).decode("utf-8", "replace")[:4000]
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

    def __init__(self, api_key: str, model_name: str, timeout: int | None = None, transport=None, base_url: str | None = None):
        self.api_key, self.model, self.timeout = api_key, model_name, timeout or timeout_s()
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

    async def acomplete(self, system: str, prompt: str, schema: dict | None = None, *, image: bytes | None = None,
                        max_output_tokens: int | None = None, on_delta=None, cache_key: str | None = None,
                        user_tag: str | None = None) -> Completion:
        """Wie complete, aber asynchron (08.11.2026, Lastfestigkeit): eine offene Anfrage ist nur eine wartende Verbindung
        im gemeinsamen httpx-Client (async_http_client), kein Thread. Der Ereignisstrom wird Zeile fuer Zeile ausgewertet,
        nicht gepuffert. Mit einem Test-Transport (sync) laeuft complete in einem Thread."""
        if self.transport is not urllib_transport:
            return await run_sync_provider(self.complete, system, prompt, schema, image=image, max_output_tokens=max_output_tokens,
                                           on_delta=on_delta, cache_key=cache_key, user_tag=user_tag)
        body = self.request_body(system, prompt, schema, image=image, max_output_tokens=max_output_tokens, cache_key=cache_key,
                                 user_tag=user_tag)
        headers = {"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json", "Accept": "text/event-stream"}
        return await stream_responses_async(self.URL, headers, body, timeout=self.timeout, on_delta=on_delta, model=self.model,
                                            images=1 if image else 0)


# ---------------------------------------------------------------- asynchroner Weg zum Anbieter (httpx)

def _httpx():
    """httpx (im Repo als `httpx2`, die Abhaengigkeit des Anthropic-SDK; aeltere Umgebungen: `httpx`)."""
    try:
        import httpx2 as httpx
    except ImportError:                              # pragma: no cover - je nach Umgebung
        import httpx
    return httpx


_async_client = None
_async_client_loop = None


def async_http_client():
    """Ein httpx.AsyncClient je Prozess (und je Ereignisschleife): Verbindungs-Pool ohne Obergrenze (LERNAPP_AI_CONCURRENCY
    begrenzt die Anfragen, nicht der Pool), 200 offene Verbindungen bleiben fuer die naechsten Anfragen warm. Zeitlimits:
    Verbinden 10 s, Warten auf das naechste Stueck timeout_s(); die Gesamtdauer begrenzt ai_providers.DEADLINE_S."""
    global _async_client, _async_client_loop
    import asyncio
    loop = asyncio.get_running_loop()
    if _async_client is None or _async_client_loop is not loop:
        httpx = _httpx()
        _async_client = httpx.AsyncClient(timeout=httpx.Timeout(float(timeout_s()), connect=10.0, write=30.0, pool=30.0),
                                          limits=httpx.Limits(max_connections=None, max_keepalive_connections=200, keepalive_expiry=30.0),
                                          follow_redirects=False, trust_env=False)
        _async_client_loop = loop
    return _async_client


async def run_sync_provider(fn, *args, **kwargs):
    """Sync-Anbieter (Attrappen in Tests, ChatGPT-Abo am PC) im Thread; eigener Begrenzer, nicht der allgemeine Pool."""
    import anyio
    from functools import partial
    from . import ai_async
    return await anyio.to_thread.run_sync(partial(fn, *args, **kwargs), limiter=ai_async.provider_limiter())


async def stream_responses_async(url: str, headers: dict, body: dict, *, timeout: float, on_delta=None, model: str = "",
                                 images: int = 0, who: str = "Der KI-Anbieter") -> Completion:
    """POST an die Responses API als Ereignisstrom, asynchron: Fehler vor der Antwort -> http_error (retryable), Netzfehler
    vor der Antwort -> ai_provider_unreachable (retryable), Abbruch danach -> started=True (kein Wechsel des Anbieters)."""
    from .ai_providers import DEADLINE_S, http_error
    httpx = _httpx()
    client = async_http_client()
    started = False
    consumer = _ResponsesConsumer(on_delta, who, model, images)
    parser = _SSEParser()
    end = time.monotonic() + DEADLINE_S
    try:
        async with client.stream("POST", url, headers=headers, content=json.dumps(body).encode("utf-8"),
                                 timeout=httpx.Timeout(float(timeout), connect=10.0, write=30.0, pool=30.0)) as r:
            if r.status_code >= 400:
                raw = (await aread_limited(r)).decode("utf-8", "replace")[:4000]          # Audit P9-06
                raise http_error(who, r.status_code, scrub(_error_message(raw)))
            started = True
            head: list[str] = []
            plain = None
            async for line in r.aiter_lines():
                if time.monotonic() > end:
                    raise TimeoutError("Frist der KI-Antwort abgelaufen")
                if plain is None:
                    if not line.strip():
                        continue
                    plain = line.lstrip().startswith("{")        # gewoehnliches JSON statt Ereignisstrom
                if plain:
                    head.append(line)
                    continue
                for event in parser.feed(line):
                    consumer.feed(event)
                if consumer.result is not None:
                    break
            if plain:
                text, data = _plain_json("\n".join(head).strip(), who)
            else:
                for event in parser.flush():
                    consumer.feed(event)
                text, data = consumer.finish()
    except AIUnavailable as e:
        if started:
            e.started = True                         # angenommen, dann abgebrochen: kein Wechsel des Anbieters
        raise
    except (httpx.HTTPError, TimeoutError, OSError):
        if started:
            raise AIUnavailable("ai_provider_unreachable", f"{who} hat die Antwort abgebrochen.", 502, started=True)
        raise AIUnavailable("ai_provider_unreachable", f"{who} ist nicht erreichbar.", 502, retryable=True)
    return Completion.from_usage(text, data, model, images=images)


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

    def __init__(self, model_name: str, timeout: int | None = None):
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
                raw = r.read(MAX_RESPONSE_BYTES).decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = chatgpt_login._error_text(e.read(ERROR_BODY_BYTES).decode("utf-8", "replace")[:600])
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

    async def acomplete(self, system: str, prompt: str, schema: dict | None = None, *, image: bytes | None = None, **_options) -> Completion:
        """Nur am PC (ein Nutzer): im Thread, die Ablage des Tokens ist synchron."""
        return await run_sync_provider(self.complete, system, prompt, schema, image=image)


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


class _SSEParser:
    """SSE-Zeilen zu `data:`-Inhalten, Stueck fuer Stueck (wie _iter_sse, aber fuer Zeilen, die einzeln eintreffen,
    z. B. aus dem asynchronen Strom): feed(line) liefert die fertigen Ereignisse, flush() den Rest."""

    def __init__(self) -> None:
        self.current: list[str] = []

    def feed(self, line) -> list[str]:
        out: list[str] = []
        for part in str(line).replace("\r\n", "\n").replace("\r", "\n").split("\n"):
            if not part:
                d = "\n".join(self.current)
                self.current.clear()
                if d and d != "[DONE]":
                    out.append(d)
                continue
            if part.startswith("data:"):
                self.current.append(part[5:].removeprefix(" "))
        return out

    def flush(self) -> list[str]:
        d = "\n".join(self.current)
        self.current.clear()
        return [d] if d and d != "[DONE]" else []


class _ResponsesConsumer:
    """Ereignisse der Responses API auswerten (siehe stream_text), ein Ereignis nach dem anderen: feed(event) fuer jedes
    Ereignis beim Eintreffen (gepuffert wird nur der Text selbst), finish() liefert (Text, fertige Antwort).
    `on_delta` bekommt jedes Textstueck sofort. Bricht die Antwort ab (failed, incomplete), traegt der Fehler die schon
    berechnete Nutzung (`billed`). Nach einer gekuerzten Antwort (Ausgabegrenze) steht das Ergebnis in `result`."""

    def __init__(self, on_delta=None, who: str = "ChatGPT", model: str = "", images: int = 0) -> None:
        self.on_delta, self.who, self.model, self.images = on_delta, who, model, images
        self.deltas: list[str] = []
        self.chars = 0
        self.completed: dict | None = None
        self.saw = False
        self.result: tuple[str, dict] | None = None

    def feed(self, event: str) -> None:
        try:
            j = json.loads(event)
        except ValueError:
            return
        if not isinstance(j, dict):
            return
        self.saw = True
        who, model, images = self.who, self.model, self.images
        t = j.get("type") or ""
        resp = j.get("response") if isinstance(j.get("response"), dict) else None
        if t == "response.output_text.delta":
            piece = str(j.get("delta") or "")
            self.deltas.append(piece)
            self.chars += len(piece)
            if self.chars > MAX_STREAM_TEXT_CHARS:       # Audit P9-06: nie unbegrenzt Text puffern
                raise AIUnavailable("ai_provider_error", f"{who} hat eine zu lange Antwort geschickt.", 502)
            if self.on_delta and piece:
                self.on_delta(piece)
        elif t == "response.completed":
            self.completed = resp if resp is not None else {}
        elif t == "response.failed":
            err = resp.get("error") if resp is not None else None
            err = err if isinstance(err, dict) else (j.get("error") if isinstance(j.get("error"), dict) else {})
            billed = Completion.from_usage("", resp, model, images) if resp and resp.get("usage") else None
            raise _stream_error(err.get("code"), err.get("message"), who, billed)
        elif t == "error":
            raise _stream_error(j.get("code"), j.get("message"), who)
        elif t == "response.incomplete":
            why = ((resp or {}).get("incomplete_details") or {}).get("reason") or "unvollständig"
            text = "".join(self.deltas)
            # Ausgabegrenze erreicht (Test 06.11.2026: "Alle Aufgaben" auf 12 Seiten brauchte 4 360 Tokens): der Nutzer hat
            # den Text bezahlt, also bekommt er ihn mit einem Hinweis statt eines Fehlers. JSON-Antworten scheitern weiter
            # beim Auslesen, freier Text ist auch gekuerzt brauchbar.
            if why == "max_output_tokens" and text.strip() and resp is not None:
                self.result = (text + TRUNCATED_NOTE, {**resp, "truncated": True})
                return
            billed = Completion.from_usage(text, resp, model, images) if resp and resp.get("usage") else None
            raise AIUnavailable("ai_provider_error", f"{who} hat die Antwort nicht beendet ({str(why)[:80]}).", 502, billed=billed)

    def finish(self) -> tuple[str, dict]:
        if self.result is not None:
            return self.result
        if self.completed is None:
            raise AIUnavailable("ai_provider_error", f"{self.who} hat die Antwort nicht beendet (kein response.completed)." if self.saw
                                else f"{self.who} antwortete unlesbar.", 502)
        final = _output_text(self.completed)
        return (final or "".join(self.deltas)), self.completed


def _consume(events, on_delta=None, who: str = "ChatGPT", model: str = "", images: int = 0) -> tuple[str, dict]:
    """Ereignisse der Responses API auswerten (siehe stream_text, _ResponsesConsumer)."""
    c = _ResponsesConsumer(on_delta, who, model, images)
    for event in events:
        c.feed(event)
        if c.result is not None:
            break
    return c.finish()


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
        return OpenAIProvider(api_key(), model_name or model(), base_url=check_openai_base_url(openai_base_url()))
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
        p = ai_prices.price(model_name)
        if image and p is not None and not p.vision:   # ausdruecklich gewaehltes Textmodell liest keine Bilder (Audit P8-07)
            raise AIUnavailable("model_not_allowed", "Dieses Modell liest keine Bilder.", 400)
        return [build(prov, model_name)]

    def vision_ok(c) -> bool:
        # ohne Preis gilt ein Modell nicht als bildfaehig (fail closed, Audit P8-07): im Dienst sperrt es ohnehin _prices_missing
        p = ai_prices.price(c.model or _default_model(c.provider))
        return p is not None and p.vision
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


ESTIMATE_INPUT_TOKENS = 4000     # Eingabe einer typischen Seite fuer den Modellvergleich in estimate_model


def estimate_model(purpose: str) -> str | None:
    """Modell fuer die Kostenzeile vor einem Lauf (app/doc_explain_api.py): das teuerste Modell des Weges dieses Zwecks
    unter den eingerichteten Anbietern - die Zeile verspricht so nie zu wenig. Verglichen werden die Kosten einer
    typischen Anfrage (Eingabe ESTIMATE_INPUT_TOKENS + Ausgabe bis max_output), nicht nur der Ausgabepreis (Audit P8-03)."""
    from . import ai_router
    if _provider_override is not None:
        return getattr(_provider_override, "model", None) or model()
    configured = configured_providers()
    choices, _ = ai_router.chain(purpose, "estimate", configured=configured)
    best, best_cost = None, -1.0
    out_tokens = max_output(purpose)
    for c in choices[:max(1, len(ai_router.route_for(purpose)))]:
        m = c.model or _default_model(c.provider)
        p = ai_prices.price(m)
        cost = p.input_eur * ESTIMATE_INPUT_TOKENS + p.output_eur * out_tokens if p else -1.0
        if p and cost > best_cost:
            best, best_cost = m, cost
    return best or model()


def available() -> bool:
    try:
        provider()
        return True
    except AIUnavailable:
        return False


# ---------------------------------------------------------------- Budget, Rate-Limit, Protokoll

def _run_statements(conn: sqlite3.Connection, script: str) -> None:
    """Anweisungen eines Skripts einzeln ausfuehren. `conn.executescript` wuerde eine offene Transaktion des Aufrufers
    vorher stillschweigend abschliessen (COMMIT) - so bleibt sie unberuehrt (Audit P8-02, 08.11.2026). Trigger mit
    BEGIN … END trennt sqlite3.complete_statement richtig."""
    buf = ""
    for line in script.splitlines(keepends=True):
        buf += line
        if sqlite3.complete_statement(buf):
            if buf.strip():
                conn.execute(buf)
            buf = ""
    if buf.strip():
        conn.execute(buf)


def ensure_schema(conn: sqlite3.Connection) -> None:
    _run_statements(conn, SCHEMA)
    cols = {r[1] for r in conn.execute("PRAGMA table_info(ai_usage_log)")}
    if "trial" not in cols:                                       # Tabelle aus aelterem Stand
        conn.execute("ALTER TABLE ai_usage_log ADD COLUMN trial INTEGER NOT NULL DEFAULT 0")
    if "library" not in cols:
        conn.execute("ALTER TABLE ai_usage_log ADD COLUMN library INTEGER NOT NULL DEFAULT 0")
    if "model" not in {r[1] for r in conn.execute("PRAGMA table_info(ai_cache)")}:
        conn.execute("ALTER TABLE ai_cache ADD COLUMN model TEXT")
    _run_statements(conn, TRIGGERS)
    _rebuild_once(conn)


_rebuilt: set = set()


def _rebuild_once(conn: sqlite3.Connection) -> None:
    """Neuaufbau der Monatssummen einmal je Prozess und Datei (Pfad + Dateinummer). db.schema_once allein reicht nicht:
    sein Merkmal enthaelt die Aenderungszeit der Datei, die sich bei jedem Checkpoint aendert - dann liefe der Neuaufbau
    (GROUP BY ueber den ganzen Monat unter Schreibsperre) bei jeder Verbindung noch einmal (Ledger-Messung 08.11.2026:
    47 statt 1.300 Fragen/s bei 100k Zeilen)."""
    try:
        row = conn.execute("PRAGMA database_list").fetchone()
        path = row[2] if row else ""
        ident = (path, os.stat(path).st_ino) if path else None
    except (OSError, sqlite3.Error):
        ident = None
    if ident is not None and ident in _rebuilt:
        return
    rebuild_month_totals(conn)
    if ident is not None:
        _rebuilt.add(ident)


def rebuild_month_totals(conn: sqlite3.Connection) -> None:
    """Monatssummen aus ai_usage_log neu aufbauen (einmal je Prozess beim Start, _rebuild_once): danach stimmen sie
    auch, wenn jemand die Tabelle von Hand geaendert oder einen alten Stand eingespielt hat; ab dann halten die Trigger
    sie aktuell."""
    own = not conn.in_transaction
    if own:
        conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute("DELETE FROM ai_usage_month")
        conn.execute("DELETE FROM ai_usage_user_month")
        conn.execute(f"INSERT INTO ai_usage_month(period, pool, cost_microeur) SELECT period, {_POOL_SQL.format(r='ai_usage_log')}, "
                     "COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE state<>'failed' GROUP BY 1, 2")
        conn.execute("INSERT INTO ai_usage_user_month(period, user_id, cost_microeur) SELECT period, user_id, COALESCE(SUM(cost_microeur),0) "
                     "FROM ai_usage_log WHERE state<>'failed' AND user_id IS NOT NULL GROUP BY 1, 2")
        if own:
            conn.execute("COMMIT")
    except Exception:
        if own and conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


def month_totals_match_log(conn: sqlite3.Connection) -> bool:
    """Pruefung (Tests, Betrieb): stimmen die laufenden Summen mit ai_usage_log ueberein?"""
    pools = {(p, k): v for p, k, v in conn.execute(f"SELECT period, {_POOL_SQL.format(r='ai_usage_log')}, COALESCE(SUM(cost_microeur),0) "
                                                   "FROM ai_usage_log WHERE state<>'failed' GROUP BY 1, 2")}
    have = {(p, k): v for p, k, v in conn.execute("SELECT period, pool, cost_microeur FROM ai_usage_month WHERE cost_microeur<>0")}
    users = {(p, u): v for p, u, v in conn.execute("SELECT period, user_id, COALESCE(SUM(cost_microeur),0) FROM ai_usage_log "
                                                   "WHERE state<>'failed' AND user_id IS NOT NULL GROUP BY 1, 2")}
    have_u = {(p, u): v for p, u, v in conn.execute("SELECT period, user_id, cost_microeur FROM ai_usage_user_month WHERE cost_microeur<>0")}
    return {k: v for k, v in pools.items() if v} == have and {k: v for k, v in users.items() if v} == have_u


def _pool_total(conn: sqlite3.Connection, period: str, pool: str) -> int:
    row = conn.execute("SELECT cost_microeur FROM ai_usage_month WHERE period=? AND pool=?", (period, pool)).fetchone()
    return int(row[0]) if row else 0


def _user_total(conn: sqlite3.Connection, period: str, user_id: str) -> int:
    row = conn.execute("SELECT cost_microeur FROM ai_usage_user_month WHERE period=? AND user_id=?", (period, str(user_id))).fetchone()
    return int(row[0]) if row else 0


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
    except sqlite3.OperationalError as e:
        if "no such table" not in str(e):            # gesperrt, kaputtes Schema o. ae. bleibt sichtbar (Audit P8-05)
            raise
        u = None                                     # accounts.db ohne Konten-Tabelle (nur Abrechnung angelegt)
    if u and billing.normalize_plan(u[0]) not in (None, "free") and (not u[1] or str(u[1])[:10] >= now_iso[:10]):
        return False
    return True


def _now(now: datetime | None = None) -> datetime:
    return (now or datetime.now(timezone.utc)).astimezone(timezone.utc)


def rate_per_hour() -> int:
    return _env_rate("LERNAPP_AI_RATE_PER_HOUR", 60)


def _library_pool(conn: sqlite3.Connection, period: str) -> int:
    return _pool_total(conn, period, "library")


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
            if _library_pool(conn, period) + amount > library_budget_microeur():     # `amount`, nicht die festen 2 Cent (Audit P8-01)
                raise library_exhausted()
            cur = conn.execute("INSERT INTO ai_usage_log(user_id, period, purpose, cost_microeur, trial, library, state, created_at) "
                               "VALUES (NULL,?,?,?,0,1,'reserved',?)", (period, purpose, amount, t.isoformat()))
            conn.execute("COMMIT")
            return cur.lastrowid
        except Exception:
            conn.execute("ROLLBACK")
            raise
    try:
        trial = 1 if user_id and is_trial_account(conn, user_id, t) else 0
        # zwei Becken: Probekonten verbrauchen nur ihr eigenes kleines Budget, nie das der zahlenden Konten; die Summen
        # kommen aus ai_usage_month (laufend, Trigger), nicht aus einer Summe ueber den ganzen Monat
        pool = _pool_total(conn, period, "trial" if trial else "paid")
        if trial:
            if pool + amount > trial_budget_microeur():
                raise AIUnavailable("ai_trial_budget_exhausted", "Das Probe-Kontingent der StudiNow-KI ist für diesen Monat ausgeschöpft.", 429)
        elif pool + amount > budget_microeur():
            raise AIUnavailable("ai_budget_exhausted", "Das KI-Budget von StudiNow für diesen Monat ist ausgeschöpft.", 503)
        if user_id:
            mine = _user_total(conn, period, user_id)
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
    # nie negativ (Audit P8-06): Kosten und Tokens sind Betraege; eine Obergrenze gibt es hier absichtlich nicht - das
    # Becken zaehlt die echten Kosten (die Reservierung ist eine Schaetzung), die harte Grenze je Konto halten die Credits
    cost = max(0, int(cost_override) if cost_override is not None else _cost(c, requested_model))
    conn.execute("UPDATE ai_usage_log SET state='done', provider=?, model=?, input_tokens=?, output_tokens=?, cost_microeur=? WHERE id=?",
                 (provider_label, c.model, max(0, int(c.input_tokens or 0)), max(0, int(c.output_tokens or 0)), cost, log_id))
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


class _Call:
    """Eine StudiNow-KI-Anfrage in Schritten, damit der synchrone Weg (`complete`: Jobs, Bibliothek, Tests) und der
    asynchrone Weg der Endpunkte (`complete_async`) denselben Ablauf teilen (08.11.2026, Lastfestigkeit):

      prepare()      Cache, Credits-Reservierung, Budget/Rate-Limit-Reservierung - EINE kurze Verbindung, danach zu
      options(i)     Argumente fuer den Anbieter i der Kette
      succeed(c, i)  abrechnen und in den Zwischenspeicher
      failed(e, i)   True = der naechste Anbieter uebernimmt (nichts berechnet), sonst abgerechnet/zurueckgebucht
      crashed()      unerwarteter Fehler: Protokoll 'failed', Credits zurueck

    Waehrend der Anbieter antwortet (5-30 s) haelt die Anfrage KEINE Datenbankverbindung (bei 4.000 offenen Fragen waeren
    das 12.000 Dateideskriptoren); jeder Schritt oeffnet kurz seine eigene. Die Reservierung (Credits je Konto, Becken des
    Dienstes) geschieht VOR dem Aufruf des Anbieters in einer BEGIN-IMMEDIATE-Transaktion: gleichzeitige Anfragen koennen
    das Budget nie gemeinsam ueberschreiten, auch nicht zu Tausenden."""

    def __init__(self, user_id, purpose, system, prompt, schema, cache, now, *, image, model_name, max_output_tokens,
                 request_id, credits, rate_limit, on_delta, keep_result, budget_reserve, library, route_hint, route_text, fresh):
        from . import ai_consent
        # Web-Oberflaeche des Dienstes: kein Anbieter ohne Einwilligung des Kontos (428 ai_consent_required)
        ai_consent.require_hosted(library)
        if library:
            user_id = None
        self.user_id, self.purpose, self.system, self.prompt, self.schema = user_id, purpose, system, prompt, schema
        self.cache, self.now, self.image, self.on_delta, self.keep_result = cache, now, image, on_delta, keep_result
        self.budget_reserve, self.library, self.rate_limit, self.fresh = budget_reserve, library, rate_limit, fresh
        self.rid = request_id or ("auto:" + uuid.uuid4().hex)
        # vor der Reservierung: nicht eingerichtet -> nichts protokollieren
        self.chain = route(purpose, self.rid, model_name=model_name, image=image, route_text=route_text, route_hint=route_hint)
        self.models = [model_name or getattr(p, "model", None) or model() for p in self.chain]
        self.hosted = config.is_hosted()
        if self.hosted:
            # ohne Token-Preise rechnet kein Budget (Kosten blieben 0): im Dienst lieber sperren als unbegrenzt ausgeben
            keep = [i for i, m in enumerate(self.models) if prices_set(m)]
            if not keep:
                raise _prices_missing()
            self.chain, self.models = [self.chain[i] for i in keep], [self.models[i] for i in keep]
        self.requested = self.models[0]
        self.charge = bool(user_id) and (credits if credits is not None else (self.hosted and charges_credits(purpose)))
        # Ausgabegrenze positiv und hoechstens 64 000 (wie LERNAPP_AI_MAX_OUTPUT), sonst die des Zwecks (Audit #242)
        mo = int(max_output_tokens or 0)
        self.max_out = mo if 0 < mo <= 64_000 else max_output(purpose)
        self.images = [image] if image else None
        self.key: str | None = None
        self.held = None
        self.log_id: int | None = None
        self.ceiling = 0
        self.result: Completion | None = None       # fertig ohne Anbieter (Zwischenspeicher, Wiederholung)

    def _worst(self, out_tokens: int) -> int:
        return max(ai_prices.worst_case_microeur(m, self.system, self.prompt, out_tokens, self.images, self.schema) for m in self.models)

    def _estimate(self, out_tokens: int) -> int:
        return max(ai_prices.estimate_credits(m, self.system, self.prompt, out_tokens, self.images, schema=self.schema) for m in self.models)

    def prepare(self) -> None:
        from . import credits as ledger
        conn = connect()
        try:
            if self.cache and not self.image:
                # ohne Modell im Schluessel: dieselbe Antwort gilt fuer jedes Modell der Mischung (gespeichert wird, wer sie schrieb)
                self.key = "c2:" + hashlib.sha256(json.dumps([self.purpose, self.system, self.prompt, self.schema], sort_keys=True).encode()).hexdigest()
                hit = None if self.fresh else conn.execute("SELECT result, created_at, model FROM ai_cache WHERE key=?", (self.key,)).fetchone()
                if hit and hit[1] >= (_now(self.now) - timedelta(days=CACHE_DAYS)).isoformat():
                    self.result = Completion(hit[0], 0, 0, "cache", source_model=hit[2] or "")
                    return
            if self.charge:
                try:
                    self.held = ledger.reserve(conn, self.user_id, self.rid, self.purpose, self._estimate(self.max_out), self.now, model=self.requested)
                except ledger.CreditsError as e:
                    remaining = int(((e.extra or {}).get("credits") or {}).get("remaining") or 0)
                    fit = min(ai_prices.max_output_within(m, self.system, self.prompt, remaining * ai_prices.MICROEUR_PER_CREDIT, self.images,
                                                          self.schema) for m in self.models) if e.code == "credits_exhausted" and remaining > 0 else 0
                    fit = min(fit, self.max_out - 1)
                    if fit < min(MIN_SHRUNK_OUTPUT, self.max_out - 1) or self._estimate(fit) > remaining:
                        raise AIUnavailable(e.code, e.message, e.status, e.extra)
                    self.max_out = fit                   # kleinere Antwort, die sicher in den Rest passt
                    try:
                        self.held = ledger.reserve(conn, self.user_id, self.rid, self.purpose, self._estimate(self.max_out), self.now,
                                                   model=self.requested)
                    except ledger.CreditsError as e2:
                        raise AIUnavailable(e2.code, e2.message, e2.status, e2.extra)
                if self.held.replay:
                    if self.held.result is not None:
                        self.result = Completion(self.held.result, 0, 0, self.requested, credits_charged=0, replay=True)
                        return
                    raise AIUnavailable("duplicate_request", "Diese Anfrage wurde schon verarbeitet.", 409)
            self.ceiling = self._worst(self.max_out)     # hoechstens so viel kann diese Anfrage kosten (auch mit Ersatz)
            try:
                # Becken (gesamt, Probe, je Konto): Reservierung wie bisher; die harte Grenze je Konto halten die Credits
                self.log_id = reserve(conn, self.user_id, self.purpose, self.now, rate_limit=self.rate_limit,
                                      amount_microeur=self.budget_reserve, library=self.library)
            except Exception:
                if self.held:
                    ledger.refund(conn, self.user_id, self.rid)
                raise
        finally:
            conn.close()

    def options(self, i: int) -> dict:
        p = self.chain[i]
        if not getattr(p, "supports_options", False):
            return {}
        return {"image": self.image, "max_output_tokens": self.max_out, "on_delta": self.on_delta,
                "cache_key": "studinow:" + self.purpose.split(":", 1)[0], "user_tag": user_tag(self.user_id)}

    def _book(self, conn, c: Completion, label: str, used_model: str, cost_override: int | None = None) -> int:
        from . import credits as ledger
        cost = settle(conn, self.log_id, c, label, used_model, cost_override)
        if self.held:
            c.credits_charged = ledger.settle(conn, self.user_id, self.rid, cost, model=c.model, input_tokens=c.input_tokens,
                                              cached_tokens=c.cached_tokens, output_tokens=c.output_tokens, images=c.images,
                                              result=c.text if self.keep_result and c.text else None, now=self.now)
            c.credits_reserved = self.held.reserved
        return cost

    def label(self, i: int) -> str:
        return getattr(self.chain[i], "label", type(self.chain[i]).__name__)

    def succeed(self, c: Completion, i: int) -> Completion:
        if not c.provider:
            c.provider = self.label(i)
        conn = connect()
        try:
            self._book(conn, c, self.label(i), self.models[i], None if c.usage_known else self.ceiling)
            if self.key and c.text:
                conn.execute("INSERT OR REPLACE INTO ai_cache(key, result, created_at, model) VALUES (?,?,?,?)",
                             (self.key, c.text, _now(self.now).isoformat(), c.model))
        finally:
            conn.close()
        return c

    def failed(self, e: AIUnavailable, i: int) -> bool:
        from . import credits as ledger
        if e.retryable and e.billed is None and not e.started and i + 1 < len(self.chain):
            return True                              # nichts berechnet: der naechste Anbieter, dieselbe Reservierung
        label = self.label(i)
        conn = connect()
        try:
            if e.billed is not None:                 # der Anbieter hat schon gerechnet (abgebrochene Antwort): abrechnen
                if not e.billed.provider:
                    e.billed.provider = label
                self._book(conn, e.billed, label, self.models[i], None if e.billed.usage_known else self.ceiling)
                if self.held:
                    e.extra = {**e.extra, "credits_charged": e.billed.credits_charged}
            elif e.started:                          # angenommen, Nutzung unbekannt: die Obergrenze abrechnen
                gone = Completion("", 0, 0, self.models[i], provider=label, usage_known=False)
                self._book(conn, gone, label, self.models[i], self.ceiling)
                if self.held:
                    e.extra = {**e.extra, "credits_charged": gone.credits_charged}
            else:
                settle(conn, self.log_id, None)
                if self.held:
                    ledger.refund(conn, self.user_id, self.rid)
        finally:
            conn.close()
        return False

    def crashed(self) -> None:
        from . import credits as ledger
        conn = connect()
        try:
            settle(conn, self.log_id, None)
            if self.held:
                ledger.refund(conn, self.user_id, self.rid)
        finally:
            conn.close()


def _call_kwargs(image, model_name, max_output_tokens, request_id, credits, rate_limit, on_delta, keep_result, budget_reserve,
                 library, route_hint, route_text, fresh) -> dict:
    return dict(image=image, model_name=model_name, max_output_tokens=max_output_tokens, request_id=request_id, credits=credits,
                rate_limit=rate_limit, on_delta=on_delta, keep_result=keep_result, budget_reserve=budget_reserve, library=library,
                route_hint=route_hint, route_text=route_text, fresh=fresh)


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
    der naechste Anbieter der Kette uebernimmt, wenn der erste nichts berechnet hat. Netzfehler oder 5xx vor der Antwort,
    die schnell kamen (RETRY_FAST_S), bekommen beim selben Anbieter EINE sofortige Wiederholung (AIUnavailable.quick_retry_ok).
    Dieselbe request_id wird nie zweimal berechnet (`keep_result`: die Antwort bleibt 24 h fuer eine Wiederholung).
    image: Seite als PNG/JPEG. `library=True`: Vorarbeit der Bibliothek (eigenes Monatsbudget, ohne Konto und ohne Credits;
    `user_id` wird dann nicht gespeichert). `fresh=True` ("Neu erklaeren lassen"): den Zwischenspeicher nicht lesen, die
    neue Antwort ersetzt die gespeicherte. Synchron (Jobs, Bibliothek, Tests); die Endpunkte nutzen complete_async."""
    call = _Call(user_id, purpose, system, prompt, schema, cache, now,
                 **_call_kwargs(image, model_name, max_output_tokens, request_id, credits, rate_limit, on_delta, keep_result,
                                budget_reserve, library, route_hint, route_text, fresh))
    call.prepare()
    if call.result is not None:
        return call.result
    for i, p in enumerate(call.chain):
        retried = False
        while True:
            t0 = time.monotonic()
            try:
                opts = call.options(i)
                c = p.complete(system, prompt, schema, **opts) if opts else p.complete(system, prompt, schema)
            except AIUnavailable as e:
                if not retried and e.quick_retry_ok() and time.monotonic() - t0 < RETRY_FAST_S:
                    retried = True
                    continue
                if call.failed(e, i):
                    break
                raise
            except Exception:
                call.crashed()
                raise
            return call.succeed(c, i)
    raise _not_configured()                          # Kette leer (kommt nicht vor: route() wirft vorher)


async def complete_async(user_id: str | None, purpose: str, system: str, prompt: str, schema: dict | None = None,
                         cache: bool = False, now: datetime | None = None, *, image: bytes | None = None, model_name: str | None = None,
                         max_output_tokens: int | None = None, request_id: str | None = None, credits: bool | None = None,
                         rate_limit: bool = True, on_delta=None, keep_result: bool = False, budget_reserve: int | None = None,
                         library: bool = False, route_hint: str | None = None, route_text: str | None = None,
                         fresh: bool = False) -> Completion:
    """Wie complete, fuer die Endpunkte des Dienstes (08.11.2026): die Datenbankschritte laufen kurz in einem eigenen
    kleinen Thread-Begrenzer (app/ai_async.py, nicht im allgemeinen Pool von 40), der Anbieter wird asynchron gefragt
    (`acomplete`: httpx bzw. Async-SDK; Attrappen und Sync-Anbieter in einem Thread). Eine wartende Anfrage belegt so
    nur eine Verbindung - Anmelden, Abo-Stand und Abgleich laufen daneben ungebremst weiter."""
    from . import ai_async
    call = await ai_async.db(_Call, user_id, purpose, system, prompt, schema, cache, now,
                             **_call_kwargs(image, model_name, max_output_tokens, request_id, credits, rate_limit, on_delta, keep_result,
                                            budget_reserve, library, route_hint, route_text, fresh))
    await ai_async.db(call.prepare)
    if call.result is not None:
        return call.result
    for i, p in enumerate(call.chain):
        retried = False
        while True:
            t0 = time.monotonic()
            try:
                opts = call.options(i)
                if hasattr(p, "acomplete"):
                    c = await p.acomplete(system, prompt, schema, **opts)
                else:
                    c = await run_sync_provider(p.complete, system, prompt, schema, **opts)
            except AIUnavailable as e:
                if not retried and e.quick_retry_ok() and time.monotonic() - t0 < RETRY_FAST_S:
                    retried = True
                    continue
                if await ai_async.db(call.failed, e, i):
                    break
                raise
            except asyncio.CancelledError:
                # abgebrochen, waehrend der Anbieter antwortete (Client weg, Zeitlimit): wie crashed sofort freigeben, statt die
                # Reservierung bis zum Aufraeumen (credits.STALE_MINUTES) und die Protokollzeile fuer immer stehen zu lassen
                # (Audit P9-07); shield: das Freigeben laeuft auch bei einem zweiten Abbruch zu Ende
                await asyncio.shield(ai_async.db(call.crashed))
                raise
            except Exception:
                await ai_async.db(call.crashed)
                raise
            return await ai_async.db(call.succeed, c, i)
    raise _not_configured()


# ---------------------------------------------------------------- Sperre gegen doppelte Generierung

def acquire(key: str, user_id: str | None = None, now: datetime | None = None) -> str | None:
    """Besitz-Marke (wahr): diese Anfrage generiert, mit der Marke an release() zurueckgeben; None: eine gleiche
    Generierung laeuft schon (nicht aelter als INFLIGHT_STALE_S). Die Marke verhindert, dass ein verspaeteter alter
    Arbeiter die Sperre eines neuen loescht (Audit P9-04)."""
    t = _now(now)
    conn = connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute("DELETE FROM ai_inflight WHERE key=? AND started_at<?", (key, (t - timedelta(seconds=INFLIGHT_STALE_S)).isoformat()))
            token = t.isoformat() + "|" + uuid.uuid4().hex
            got = conn.execute("INSERT OR IGNORE INTO ai_inflight(key, user_id, started_at) VALUES (?,?,?)",
                               (key, user_id, token)).rowcount == 1
            conn.execute("COMMIT")
            return token if got else None
        except Exception:
            conn.execute("ROLLBACK")
            raise
    finally:
        conn.close()


def release(key: str, token: str | None = None) -> None:
    """Sperre freigeben; mit der Marke aus acquire nur die eigene (Vergleichen und Loeschen in einem Schritt)."""
    conn = connect()
    try:
        if token is None:
            conn.execute("DELETE FROM ai_inflight WHERE key=?", (key,))
        else:
            conn.execute("DELETE FROM ai_inflight WHERE key=? AND started_at=?", (key, token))
    finally:
        conn.close()


def wait_for(key: str, timeout_s: float = 30.0, poll_s: float = 0.1) -> bool:
    """Wartet, bis die laufende Generierung fertig ist (oder ihre Sperre verwaist). True: Sperre weg - ob es ein Ergebnis
    gibt, prueft der Aufrufer selbst. Hoechstens WAIT_MAX_S, frühestens alle WAIT_POLL_MIN_S (nan/inf/negativ -> Grenzen;
    Audit P9-04)."""
    timeout_s = min(WAIT_MAX_S, max(0.0, timeout_s)) if math.isfinite(timeout_s) else WAIT_MAX_S
    poll_s = max(WAIT_POLL_MIN_S, poll_s) if math.isfinite(poll_s) else WAIT_POLL_MIN_S
    end = time.monotonic() + timeout_s
    while time.monotonic() < end:
        stale = (_now() - timedelta(seconds=INFLIGHT_STALE_S)).isoformat()
        conn = connect()
        try:
            busy = conn.execute("SELECT 1 FROM ai_inflight WHERE key=? AND started_at>=?", (key, stale)).fetchone()
        finally:
            conn.close()
        if not busy:
            return True
        time.sleep(poll_s)
    return False
