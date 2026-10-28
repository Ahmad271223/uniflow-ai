"""Studora-KI ueber das eigene Backend (Pro AI, KI-Tests ab Plus) mit Kostenkontrolle.

Die App ruft nie selbst einen KI-Anbieter mit einem Studora-Schluessel auf: alle Anfragen laufen ueber den Dienst.
Anbieter und Modell sind zentral konfiguriert (Umgebung), der Schluessel liegt nur auf dem Server.

    LERNAPP_AI_PROVIDER        openai | none (Standard: openai, wenn ein Schluessel gesetzt ist, sonst none)
    LERNAPP_OPENAI_API_KEY     Schluessel des Studora-Kontos bei OpenAI (nie in der App, nie im Repo)
    LERNAPP_AI_MODEL           Modell fuer alle Studora-KI-Anfragen (Pflicht, wenn der Anbieter aktiv ist)
    LERNAPP_AI_PRICE_IN_EUR    Preis je 1 Mio. Eingabe-Tokens in EUR (fuer die Kostenprotokollierung)
    LERNAPP_AI_PRICE_OUT_EUR   Preis je 1 Mio. Ausgabe-Tokens in EUR
    LERNAPP_AI_BUDGET_EUR      Gesamtbudget je Monat fuer alle Konten (Standard 50); erreicht -> Sperre
    LERNAPP_AI_USER_BUDGET_EUR Budget je Konto und Monat (Standard 2)
    LERNAPP_AI_RATE_PER_MINUTE Anfragen je Konto und Minute (Standard 6)

Kostenkontrolle (Tabellen in accounts.db):
- `ai_usage_log`: jede Anfrage mit Konto, Zweck, Modell, Tokens, Kosten. Vor dem Aufruf wird in einer
  Schreibtransaktion geprueft (Budget gesamt und je Konto, Rate-Limit) und eine Reservierung mit geschaetzten Kosten
  eingetragen; danach werden die echten Tokens und Kosten nachgetragen. Gleichzeitige Anfragen koennen das Budget
  dadurch nicht gemeinsam ueberschreiten.
- `ai_inflight`: Sperre je Generierungsschluessel (z. B. Fach+Thema+Schwierigkeit). Eine zweite gleiche Generierung
  wartet auf die erste und nutzt deren Ergebnis, statt doppelt zu bezahlen.
- `ai_cache`: Antworten fuer gleiche Anfragen (gleicher Zweck, gleiches Modell, gleicher Text), 30 Tage.
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from . import billing

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
    created_at TEXT NOT NULL
);
"""

RESERVE_MICROEUR = 20_000           # Reservierung je Anfrage vor dem Aufruf (2 Cent), danach echte Kosten
INFLIGHT_STALE_S = 600
CACHE_DAYS = 30


class AIUnavailable(Exception):
    def __init__(self, code: str, message: str, status: int = 503):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


@dataclass
class Completion:
    text: str
    input_tokens: int
    output_tokens: int
    model: str


# ---------------------------------------------------------------- Konfiguration

def _env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


def provider_name() -> str:
    p = (os.environ.get("LERNAPP_AI_PROVIDER") or "").strip().lower()
    if not p:
        return "openai" if os.environ.get("LERNAPP_OPENAI_API_KEY") else "none"
    return p


def model() -> str:
    return (os.environ.get("LERNAPP_AI_MODEL") or "").strip()


def budget_microeur() -> int:
    return int(_env_float("LERNAPP_AI_BUDGET_EUR", 50.0) * 1_000_000)


def user_budget_microeur() -> int:
    return int(_env_float("LERNAPP_AI_USER_BUDGET_EUR", 2.0) * 1_000_000)


def rate_per_minute() -> int:
    return int(_env_float("LERNAPP_AI_RATE_PER_MINUTE", 6))


def cost_microeur(input_tokens: int, output_tokens: int) -> int:
    pin, pout = _env_float("LERNAPP_AI_PRICE_IN_EUR", 0.0), _env_float("LERNAPP_AI_PRICE_OUT_EUR", 0.0)
    return int(round(input_tokens * pin + output_tokens * pout))      # Preis je 1 Mio. Tokens -> Millionstel EUR je Token


# ---------------------------------------------------------------- Anbieter

class OpenAIProvider:
    """Responses API von OpenAI mit dem Studora-Schluessel des Servers (urllib, keine Zusatzpakete)."""
    URL = "https://api.openai.com/v1/responses"

    def __init__(self, api_key: str, model_name: str, timeout: int = 120):
        self.api_key, self.model, self.timeout = api_key, model_name, timeout

    def complete(self, system: str, prompt: str, schema: dict | None = None) -> Completion:
        body: dict = {"model": self.model, "instructions": system, "input": prompt}
        if schema:
            body["text"] = {"format": {"type": "json_schema", "name": "studora", "schema": schema, "strict": False}}
        req = urllib.request.Request(self.URL, data=json.dumps(body).encode("utf-8"), method="POST",
                                     headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                data = json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raise AIUnavailable("ai_provider_error", f"Der KI-Anbieter antwortete mit Fehler {e.code}.", 502)
        except (urllib.error.URLError, TimeoutError, OSError):
            raise AIUnavailable("ai_provider_unreachable", "Der KI-Anbieter ist nicht erreichbar.", 502)
        text = "".join(c.get("text", "") for item in data.get("output") or [] if item.get("type") == "message"
                       for c in item.get("content") or [] if c.get("type") == "output_text")
        usage = data.get("usage") or {}
        return Completion(text, int(usage.get("input_tokens") or 0), int(usage.get("output_tokens") or 0), data.get("model") or self.model)


class ChatGPTProvider(OpenAIProvider):
    """Responses API mit dem ChatGPT-Abo des Nutzers (Sign in with ChatGPT, app/chatgpt_login.py): das Zugriffstoken
    kommt je Anfrage aus der Ablage dieses Rechners (erneuert sich selbst), nie ein Studora-Schluessel. 401 heisst
    "neu anmelden", 402/403/429 "Kontingent aufgebraucht oder Nutzung in Apps nicht freigegeben" (Nutzung verwalten
    in ChatGPT)."""

    def __init__(self, model_name: str, timeout: int = 120):
        super().__init__("", model_name, timeout)

    def complete(self, system: str, prompt: str, schema: dict | None = None) -> Completion:
        from . import chatgpt_login
        try:
            token = chatgpt_login.access_token()
        except chatgpt_login.ChatGPTError as e:
            raise AIUnavailable(e.code, e.message, e.status)
        body: dict = {"model": self.model, "instructions": system, "input": prompt}
        if schema:
            body["text"] = {"format": {"type": "json_schema", "name": "studora", "schema": schema, "strict": False}}
        req = urllib.request.Request(self.URL, data=json.dumps(body).encode("utf-8"), method="POST",
                                     headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:  # noqa: S310 - feste https-Adresse
                data = json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = e.read().decode("utf-8", "replace")[:400]
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
        text = "".join(c.get("text", "") for item in data.get("output") or [] if item.get("type") == "message"
                       for c in item.get("content") or [] if c.get("type") == "output_text")
        usage = data.get("usage") or {}
        return Completion(text, int(usage.get("input_tokens") or 0), int(usage.get("output_tokens") or 0), data.get("model") or self.model)


_provider_override = None


def set_provider(p) -> None:
    """Fuer Tests: Attrappe statt OpenAI (None = wieder aus der Konfiguration)."""
    global _provider_override
    _provider_override = p


def provider():
    if _provider_override is not None:
        return _provider_override
    name = provider_name()
    if name == "openai":
        key = os.environ.get("LERNAPP_OPENAI_API_KEY") or ""
        if not key or not model():
            raise AIUnavailable("ai_not_configured", "Die Studora-KI ist auf dem Server noch nicht eingerichtet.")
        return OpenAIProvider(key, model())
    raise AIUnavailable("ai_not_configured", "Die Studora-KI ist auf dem Server noch nicht eingerichtet.")


def available() -> bool:
    try:
        provider()
        return True
    except AIUnavailable:
        return False


# ---------------------------------------------------------------- Budget, Rate-Limit, Protokoll

def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)


def connect() -> sqlite3.Connection:
    conn = billing.connect()
    ensure_schema(conn)
    return conn


def _now(now: datetime | None = None) -> datetime:
    return (now or datetime.now(timezone.utc)).astimezone(timezone.utc)


def reserve(conn: sqlite3.Connection, user_id: str | None, purpose: str, now: datetime | None = None) -> int:
    """Budget und Rate-Limit pruefen und eine Reservierung eintragen (atomar). Liefert die Protokoll-ID."""
    t = _now(now)
    period = t.strftime("%Y-%m")
    conn.execute("BEGIN IMMEDIATE")
    try:
        total = conn.execute("SELECT COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE period=? AND state<>'failed'",
                             (period,)).fetchone()[0]
        if total + RESERVE_MICROEUR > budget_microeur():
            raise AIUnavailable("ai_budget_exhausted", "Das KI-Budget von Studora für diesen Monat ist ausgeschöpft.", 503)
        if user_id:
            mine = conn.execute("SELECT COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE period=? AND user_id=? AND state<>'failed'",
                                (period, user_id)).fetchone()[0]
            if mine + RESERVE_MICROEUR > user_budget_microeur():
                raise AIUnavailable("ai_user_budget_exhausted", "Dein KI-Kostenrahmen für diesen Monat ist erreicht.", 429)
            recent = conn.execute("SELECT COUNT(*) FROM ai_usage_log WHERE user_id=? AND created_at>?",
                                  (user_id, (t - timedelta(seconds=60)).isoformat())).fetchone()[0]
            if recent >= rate_per_minute():
                raise AIUnavailable("ai_rate_limited", "Zu viele KI-Anfragen in kurzer Zeit. Bitte gleich noch einmal.", 429)
        cur = conn.execute("INSERT INTO ai_usage_log(user_id, period, purpose, cost_microeur, state, created_at) VALUES (?,?,?,?,?,?)",
                           (user_id, period, purpose, RESERVE_MICROEUR, "reserved", t.isoformat()))
        conn.execute("COMMIT")
        return cur.lastrowid
    except Exception:
        conn.execute("ROLLBACK")
        raise


def settle(conn: sqlite3.Connection, log_id: int, c: Completion | None, provider_label: str = "") -> None:
    if c is None:
        conn.execute("UPDATE ai_usage_log SET state='failed', cost_microeur=0 WHERE id=?", (log_id,))
        return
    conn.execute("UPDATE ai_usage_log SET state='done', provider=?, model=?, input_tokens=?, output_tokens=?, cost_microeur=? WHERE id=?",
                 (provider_label, c.model, c.input_tokens, c.output_tokens, cost_microeur(c.input_tokens, c.output_tokens), log_id))


def month_report(conn: sqlite3.Connection, now: datetime | None = None) -> dict:
    period = _now(now).strftime("%Y-%m")
    r = conn.execute("""SELECT COUNT(*), COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0), COALESCE(SUM(cost_microeur),0)
                        FROM ai_usage_log WHERE period=? AND state='done'""", (period,)).fetchone()
    return {"period": period, "requests": r[0], "input_tokens": r[1], "output_tokens": r[2],
            "cost_eur": round(r[3] / 1_000_000, 6), "budget_eur": budget_microeur() / 1_000_000}


import threading as _threading

# Gleichzeitige Anfragen an den Anbieter je Prozess (`LERNAPP_AI_PARALLEL`, Standard 8, Pruefpunkt 1196); dazu kommen
# Budget und Grenze je Konto. Wer keinen Platz bekommt, wartet hoechstens 30 Sekunden und bekommt dann 503.
_SLOTS = _threading.BoundedSemaphore(max(1, int(os.environ.get("LERNAPP_AI_PARALLEL") or 8)))


def complete(user_id: str | None, purpose: str, system: str, prompt: str, schema: dict | None = None,
             cache: bool = False, now: datetime | None = None) -> Completion:
    """Eine Studora-KI-Anfrage mit Budget, Rate-Limit, Protokoll und optionalem Cache."""
    if not _SLOTS.acquire(timeout=30):
        raise AIUnavailable("ai_busy", "Die Studora-KI ist gerade ausgelastet. Bitte gleich noch einmal versuchen.", 503)
    try:
        return _complete(user_id, purpose, system, prompt, schema, cache, now)
    finally:
        _SLOTS.release()


def _complete(user_id: str | None, purpose: str, system: str, prompt: str, schema: dict | None = None,
              cache: bool = False, now: datetime | None = None) -> Completion:
    p = provider()                                   # vor der Reservierung: nicht eingerichtet -> nichts protokollieren
    conn = connect()
    try:
        key = None
        if cache:
            key = "c:" + hashlib.sha256(json.dumps([purpose, model(), system, prompt, schema], sort_keys=True).encode()).hexdigest()
            hit = conn.execute("SELECT result, created_at FROM ai_cache WHERE key=?", (key,)).fetchone()
            if hit and hit[1] >= (_now(now) - timedelta(days=CACHE_DAYS)).isoformat():
                return Completion(hit[0], 0, 0, "cache")
        log_id = reserve(conn, user_id, purpose, now)
        try:
            c = p.complete(system, prompt, schema)
        except Exception:
            settle(conn, log_id, None)
            raise
        settle(conn, log_id, c, getattr(p, "label", type(p).__name__))
        if key and c.text:
            conn.execute("INSERT OR REPLACE INTO ai_cache(key, result, created_at) VALUES (?,?,?)", (key, c.text, _now(now).isoformat()))
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
