"""StudiNow-KI ueber das eigene Backend (Pro AI, KI-Tests ab Plus) mit Kostenkontrolle.

Die App ruft nie selbst einen KI-Anbieter mit einem StudiNow-Schluessel auf: alle Anfragen laufen ueber den Dienst.
Anbieter und Modell sind zentral konfiguriert (Umgebung), der Schluessel liegt nur auf dem Server.

    LERNAPP_AI_PROVIDER        openai | none (Standard: openai, wenn ein Schluessel gesetzt ist, sonst none)
    LERNAPP_OPENAI_API_KEY     Schluessel des StudiNow-Kontos bei OpenAI (nie in der App, nie im Repo)
    LERNAPP_AI_MODEL           Modell fuer alle StudiNow-KI-Anfragen (Pflicht, wenn der Anbieter aktiv ist)
    LERNAPP_AI_PRICE_IN_EUR    Preis je 1 Mio. Eingabe-Tokens in EUR (fuer die Kostenprotokollierung)
    LERNAPP_AI_PRICE_OUT_EUR   Preis je 1 Mio. Ausgabe-Tokens in EUR
    LERNAPP_AI_BUDGET_EUR      Gesamtbudget je Monat fuer alle Konten (Standard 50); erreicht -> Sperre
    LERNAPP_AI_USER_BUDGET_EUR Budget je Konto und Monat (Standard 2)
    LERNAPP_AI_TRIAL_BUDGET_EUR eigenes Budget je Monat fuer alle Probekonten zusammen (Standard 5); die Probe frisst
                               nie das Budget der zahlenden Konten
    LERNAPP_AI_RATE_PER_MINUTE Anfragen je Konto und Minute (Standard 6)
    LERNAPP_AI_LIBRARY_BUDGET_EUR eigenes Budget je Monat fuer die Vorarbeit der Bibliothek (fertige Wochenfragen,
                               app/week_library.py; Standard 20). Eigenes Becken (`library=1`, ohne Konto): die
                               Bibliothek frisst nie das Budget der Konten, die Konten nie das der Bibliothek.

Kostenkontrolle (Tabellen in accounts.db):
- `ai_usage_log`: jede Anfrage mit Konto, Zweck, Modell, Tokens, Kosten (Bibliothek: ohne Konto, `library=1`). Vor dem Aufruf wird in einer
  Schreibtransaktion geprueft (Budget gesamt und je Konto, Rate-Limit) und eine Reservierung mit geschaetzten Kosten
  eingetragen; Probekonten (nur die Probe aktiv) zaehlen in einem eigenen kleineren Becken (`trial=1`); danach werden die echten Tokens und Kosten nachgetragen. Gleichzeitige Anfragen koennen das Budget
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

from . import billing, config, db

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


def trial_budget_microeur() -> int:
    return int(_env_float("LERNAPP_AI_TRIAL_BUDGET_EUR", 5.0) * 1_000_000)


def library_budget_microeur() -> int:
    return int(_env_float("LERNAPP_AI_LIBRARY_BUDGET_EUR", 20.0) * 1_000_000)


def rate_per_minute() -> int:
    return int(_env_float("LERNAPP_AI_RATE_PER_MINUTE", 6))


def prices_set() -> bool:
    return _env_float("LERNAPP_AI_PRICE_IN_EUR", 0.0) > 0 and _env_float("LERNAPP_AI_PRICE_OUT_EUR", 0.0) > 0


def cost_microeur(input_tokens: int, output_tokens: int) -> int:
    pin, pout = _env_float("LERNAPP_AI_PRICE_IN_EUR", 0.0), _env_float("LERNAPP_AI_PRICE_OUT_EUR", 0.0)
    return int(round(input_tokens * pin + output_tokens * pout))      # Preis je 1 Mio. Tokens -> Millionstel EUR je Token


# ---------------------------------------------------------------- Anbieter

class OpenAIProvider:
    """Responses API von OpenAI mit dem StudiNow-Schluessel des Servers (urllib, keine Zusatzpakete)."""
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
    kommt je Anfrage aus der Ablage dieses Rechners (erneuert sich selbst), nie ein StudiNow-Schluessel. Mit diesem
    Token verlangt OpenAI `store: false` und `stream: true` je Anfrage, `input` als Liste und die Antwort als
    Ereignisstrom bis `response.completed` (Doku "Preview limitations", 3.11.2026). 401 heisst "neu anmelden",
    402/403/429 "Kontingent aufgebraucht oder Nutzung in Apps nicht freigegeben" (Nutzung verwalten in ChatGPT)."""

    LIMIT_MESSAGE = ("Dein ChatGPT-Kontingent ist aufgebraucht oder die Nutzung in Apps ist nicht freigegeben. "
                     "In ChatGPT unter Einstellungen → Nutzung verwalten.")
    LOGIN_MESSAGE = "Die Anmeldung bei ChatGPT ist abgelaufen – bitte in den Einstellungen neu verbinden."

    def __init__(self, model_name: str, timeout: int = 120):
        super().__init__("", model_name, timeout)

    @staticmethod
    def request_body(model: str, system: str, prompt: str, schema: dict | None = None) -> dict:
        """Anfrage an `POST /v1/responses` mit dem Token des Abos (wie Swift `ChatGPTProtocol.responsesBody`)."""
        body: dict = {"model": model, "instructions": system, "input": [{"role": "user", "content": prompt}], "store": False, "stream": True}
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

    def complete(self, system: str, prompt: str, schema: dict | None = None) -> Completion:
        from . import chatgpt_login
        try:
            token = chatgpt_login.access_token()
        except chatgpt_login.ChatGPTError as e:
            raise AIUnavailable(e.code, e.message, e.status)
        body = self.request_body(self.model, system, prompt, schema)
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
        usage = data.get("usage") or {}
        return Completion(text, int(usage.get("input_tokens") or 0), int(usage.get("output_tokens") or 0), data.get("model") or self.model)


def _sse_events(raw: str) -> list[str]:
    """`data:`-Inhalte der Ereignisse eines SSE-Stroms (mehrzeilige `data:` je Ereignis zusammengefuegt, `event:` und
    Kommentare uebergangen, `[DONE]` ausgelassen)."""
    out: list[str] = []
    current: list[str] = []

    def flush() -> None:
        d = "\n".join(current)
        current.clear()
        if d and d != "[DONE]":
            out.append(d)
    for line in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if not line:
            flush()
            continue
        if line.startswith("data:"):
            current.append(line[5:].removeprefix(" "))
    flush()
    return out


def _stream_error(code: str | None, message: str | None) -> AIUnavailable:
    """Fehlercodes der Responses API fuer das ChatGPT-Abo (developers.openai.com/siwc/…/errors-and-recovery)."""
    c, m = code or "", (message or "")[:200]
    if c in ("subscription_sharing_usage_limit_exceeded", "subscription_sharing_user_not_eligible"):
        return AIUnavailable("chatgpt_limit", ChatGPTProvider.LIMIT_MESSAGE, 429)
    if c in ("subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable"):
        return AIUnavailable("ai_provider_error", "ChatGPT kann die Nutzung deines Abos gerade nicht prüfen – bitte später noch einmal versuchen.", 502)
    if c == "subscription_sharing_invalid_user":
        return AIUnavailable("chatgpt_login_needed", ChatGPTProvider.LOGIN_MESSAGE, 401)
    return AIUnavailable("ai_provider_error", "ChatGPT antwortete mit Fehler" + (f" {c}" if c else "") + (f": {m}" if m else "."), 502)


def stream_text(raw: str) -> tuple[str, dict]:
    """Antwort von `POST /v1/responses` mit `stream: true` (wie Swift `ChatGPTProtocol.streamedText`): Server-Sent
    Events, je Ereignis `data:` mit JSON und `type`. Fertig erst mit `response.completed` (Text aus der fertigen
    Antwort, sonst die gesammelten `response.output_text.delta`); `response.failed`, `error` und `response.incomplete`
    sind Fehler, ein Strom ohne Abschluss auch. Eine gewoehnliche JSON-Antwort wird wie bisher gelesen. Liefert
    (Text, fertige Antwort)."""
    def output_text(d: dict) -> str:
        return "".join(c.get("text", "") for item in d.get("output") or [] if isinstance(item, dict) and item.get("type") == "message"
                       for c in item.get("content") or [] if isinstance(c, dict) and c.get("type") == "output_text")
    stripped = raw.strip()
    if stripped.startswith("{"):
        try:
            data = json.loads(stripped)
        except ValueError:
            raise AIUnavailable("ai_provider_error", "ChatGPT antwortete unlesbar.", 502)
        err = data.get("error") if isinstance(data, dict) else None
        if isinstance(err, dict):
            raise _stream_error(err.get("code"), err.get("message"))
        return output_text(data), data
    deltas, completed, saw = [], None, False
    for event in _sse_events(raw):
        try:
            j = json.loads(event)
        except ValueError:
            continue
        if not isinstance(j, dict):
            continue
        saw = True
        t = j.get("type") or ""
        if t == "response.output_text.delta":
            deltas.append(str(j.get("delta") or ""))
        elif t == "response.completed":
            completed = j.get("response") if isinstance(j.get("response"), dict) else {}
        elif t == "response.failed":
            err = (j.get("response") or {}).get("error") if isinstance(j.get("response"), dict) else None
            err = err if isinstance(err, dict) else (j.get("error") if isinstance(j.get("error"), dict) else {})
            raise _stream_error(err.get("code"), err.get("message"))
        elif t == "error":
            raise _stream_error(j.get("code"), j.get("message"))
        elif t == "response.incomplete":
            why = ((j.get("response") or {}).get("incomplete_details") or {}).get("reason") or "unvollständig"
            raise AIUnavailable("ai_provider_error", f"ChatGPT hat die Antwort nicht beendet ({str(why)[:80]}).", 502)
    if completed is None:
        raise AIUnavailable("ai_provider_error", "ChatGPT hat die Antwort nicht beendet (kein response.completed)." if saw
                            else "ChatGPT antwortete unlesbar.", 502)
    final = output_text(completed)
    return (final or "".join(deltas)), completed


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
            raise AIUnavailable("ai_not_configured", "Die StudiNow-KI ist auf dem Server noch nicht eingerichtet.")
        return OpenAIProvider(key, model())
    raise AIUnavailable("ai_not_configured", "Die StudiNow-KI ist auf dem Server noch nicht eingerichtet.")


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


def connect() -> sqlite3.Connection:
    from . import accounts
    conn = billing.connect()
    db.schema_once(conn, "ai_backend", accounts.db_path(), ensure_schema)
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


def _library_pool(conn: sqlite3.Connection, period: str) -> int:
    return conn.execute("SELECT COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE period=? AND state<>'failed' AND library=1",
                        (period,)).fetchone()[0]


def library_exhausted() -> AIUnavailable:
    return AIUnavailable("ai_library_budget_exhausted", "Die Bibliothek hat ihr KI-Budget für diesen Monat aufgebraucht. "
                         "Fertige Fragen, die schon da sind, gehen weiter; neue Wochen kommen im nächsten Monat dazu.", 429)


def check_library(calls: int = 1, now: datetime | None = None) -> None:
    """Vorpruefung vor einer Vorarbeit der Bibliothek (mehrere Aufrufe): Anbieter eingerichtet, Preise gesetzt (Dienst),
    Budget der Bibliothek reicht fuer `calls` Reservierungen. Wirft AIUnavailable (503 bzw. 429), sonst nichts."""
    provider()
    if config.is_hosted() and not prices_set():
        raise AIUnavailable("ai_not_configured_prices", "Die StudiNow-KI ist noch nicht freigeschaltet: Die Token-Preise "
                            "(LERNAPP_AI_PRICE_IN_EUR / LERNAPP_AI_PRICE_OUT_EUR) fehlen auf dem Server.", 503)
    conn = connect()
    try:
        if _library_pool(conn, _now(now).strftime("%Y-%m")) + RESERVE_MICROEUR * max(1, calls) > library_budget_microeur():
            raise library_exhausted()
    finally:
        conn.close()


def reserve(conn: sqlite3.Connection, user_id: str | None, purpose: str, now: datetime | None = None, library: bool = False) -> int:
    """Budget und Rate-Limit pruefen und eine Reservierung eintragen (atomar). Liefert die Protokoll-ID.
    `library=True`: Vorarbeit der Bibliothek fuer alle Konten; nur das eigene Becken (LERNAPP_AI_LIBRARY_BUDGET_EUR)
    zaehlt, ohne Konto, ohne Budget und Rate-Limit je Konto (die Sperre je Inhalt verhindert Doppeltes)."""
    t = _now(now)
    period = t.strftime("%Y-%m")
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
            if pool + RESERVE_MICROEUR > trial_budget_microeur():
                raise AIUnavailable("ai_trial_budget_exhausted", "Das Probe-Kontingent der StudiNow-KI ist für diesen Monat ausgeschöpft.", 429)
        elif pool + RESERVE_MICROEUR > budget_microeur():
            raise AIUnavailable("ai_budget_exhausted", "Das KI-Budget von StudiNow für diesen Monat ist ausgeschöpft.", 503)
        if user_id:
            mine = conn.execute("SELECT COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE period=? AND user_id=? AND state<>'failed'",
                                (period, user_id)).fetchone()[0]
            if mine + RESERVE_MICROEUR > user_budget_microeur():
                raise AIUnavailable("ai_user_budget_exhausted", "Dein KI-Kostenrahmen für diesen Monat ist erreicht.", 429)
            recent = conn.execute("SELECT COUNT(*) FROM ai_usage_log WHERE user_id=? AND created_at>?",
                                  (user_id, (t - timedelta(seconds=60)).isoformat())).fetchone()[0]
            if recent >= rate_per_minute():
                raise AIUnavailable("ai_rate_limited", "Zu viele KI-Anfragen in kurzer Zeit. Bitte gleich noch einmal.", 429)
        cur = conn.execute("INSERT INTO ai_usage_log(user_id, period, purpose, cost_microeur, trial, state, created_at) VALUES (?,?,?,?,?,?,?)",
                           (user_id, period, purpose, RESERVE_MICROEUR, trial, "reserved", t.isoformat()))
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
    lib = conn.execute("SELECT COUNT(*), COALESCE(SUM(cost_microeur),0) FROM ai_usage_log WHERE period=? AND state='done' AND library=1",
                       (period,)).fetchone()
    return {"period": period, "requests": r[0], "input_tokens": r[1], "output_tokens": r[2],
            "cost_eur": round(r[3] / 1_000_000, 6), "budget_eur": budget_microeur() / 1_000_000,
            "library_requests": lib[0], "library_cost_eur": round(lib[1] / 1_000_000, 6),
            "library_budget_eur": library_budget_microeur() / 1_000_000}


def complete(user_id: str | None, purpose: str, system: str, prompt: str, schema: dict | None = None,
             cache: bool = False, now: datetime | None = None, library: bool = False) -> Completion:
    """Eine StudiNow-KI-Anfrage mit Budget, Rate-Limit, Protokoll und optionalem Cache. `library=True`: Vorarbeit der
    Bibliothek (eigenes Monatsbudget, ohne Konto; `user_id` wird dann nicht gespeichert)."""
    p = provider()                                   # vor der Reservierung: nicht eingerichtet -> nichts protokollieren
    if config.is_hosted() and not prices_set():
        # ohne Token-Preise rechnet kein Budget (Kosten blieben 0): im Dienst lieber sperren als unbegrenzt ausgeben
        raise AIUnavailable("ai_not_configured_prices", "Die StudiNow-KI ist noch nicht freigeschaltet: Die Token-Preise "
                            "(LERNAPP_AI_PRICE_IN_EUR / LERNAPP_AI_PRICE_OUT_EUR) fehlen auf dem Server.", 503)
    conn = connect()
    try:
        key = None
        if cache:
            key = "c:" + hashlib.sha256(json.dumps([purpose, model(), system, prompt, schema], sort_keys=True).encode()).hexdigest()
            hit = conn.execute("SELECT result, created_at FROM ai_cache WHERE key=?", (key,)).fetchone()
            if hit and hit[1] >= (_now(now) - timedelta(days=CACHE_DAYS)).isoformat():
                return Completion(hit[0], 0, 0, "cache")
        log_id = reserve(conn, None if library else user_id, purpose, now, library=library)
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
