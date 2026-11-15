"""Credits der StudiNow-KI je Konto und Monat (Entscheidung des Inhabers 04.11.2026).

Regeln:
- Ein Credit ist 0,65 Cent echter KI-Kosten (`ai_prices.MICROEUR_PER_CREDIT`, Entscheidung des Inhabers 15.11.2026;
  app/ai_prices.py rechnet, aufgerundet auf ganze Credits) - ein Kurs fuer Monats-Credits, Probe und gekaufte Credits.
  Pro AI hat 100 Credits je Monat (= hoechstens 0,65 EUR KI-Kosten je Konto), alle anderen Tarife 0; einstellbar je Tarif ueber
  LERNAPP_CREDITS_PRO_AI, LERNAPP_CREDITS_PLUS, LERNAPP_CREDITS_FREE und fuer die 7-Tage-Probe
  LERNAPP_CREDITS_TRIAL (Vorschlag 25, damit das Probe-Becken in app/ai_backend.py fuer viele Probekonten reicht).
- Credit-Regel des Inhabers 08.11.2026: Probe ohne bezahltes Abo 25, Plus 0, Pro AI 100. Laufende Probe + Plus: 25, bis
  die Probe endet, danach 0; laufende Probe + Pro AI: 100 (`ai_backend.is_trial_account`).
- Nicht verbrauchte Credits verfallen am Monatsende. Der Monat ist der Kalendermonat in Europe/Berlin; der neue Monat
  beginnt "faul": die Zeile des Monats entsteht bei der ersten Nutzung (kein naechtlicher Lauf noetig).
- Der Rahmen eines Monats folgt dem aktuellen Tarif: wer mitten im Monat Pro AI abschliesst, hat sofort 100.
- Vor jedem Aufruf wird die Obergrenze der Anfrage reserviert (reserve; app/ai_prices.worst_case_microeur fuer das
  teuerste Modell der Anbieter-Kette), danach mit der echten Nutzung abgerechnet, nie mehr als reserviert (settle), oder
  bei einem Fehler, fuer den der Anbieter nichts berechnet hat, zurueckgegeben (refund). Damit ist die Grenze hart: ein
  Konto verursacht im Monat hoechstens seine Credits, auch mit gleichzeitigen Anfragen und Ersatz-Anbietern. Reicht der Rest nicht fuer die
  Reservierung: 429 credits_exhausted, "Credits für diesen Monat aufgebraucht – am 1. gibt es neue."
- Jede Anfrage traegt eine request_id (je Konto eindeutig): dieselbe ID wird nie zweimal berechnet. Laeuft sie noch:
  409 duplicate_request; ist sie fertig: die gespeicherte Antwort kommt noch 24 Stunden zurueck (ohne neue Kosten).
- Reihenfolge der Bezahlung (funding): erst Geteiltes (gemeinsamer Wochentest, Seite der Bibliothek: 0 Credits, kein
  KI-Aufruf), dann das eigene ChatGPT-Abo des Nutzers (0 Credits, laeuft auf dem Geraet), erst dann Credits.
- Dem Client wird nie geglaubt: Kosten kommen nur aus `usage` der Antwort von OpenAI (app/ai_backend.py).

Zwei Toepfe je Konto (Auftrag des Inhabers 15.11.2026, docs/KI-CREDITS-2026-11-15.md):
- Monats-Credits (`credit_months`, wie oben): jeden Monat neu bis zum Rahmen des Tarifs, der Rest verfaellt.
- Gekaufte Credits (`credit_wallets` = Stand je Konto, `credit_purchases` = jeder Kauf): verfallen nie, bleiben ueber
  Monatswechsel, Tarifwechsel und Probe-Ende. Wofuer sie gelten, haengt am Tarif (`plans.purchased_credits_scope`):
  mit der KI-Lernhilfe (Pro AI, Probe) fuer alles, mit Plus nur fuer den KI-Chat (`reserve` nimmt sie dort nur fuer
  die Aufgaben aus `plans.CREDIT_PACKS["chat_purposes"]`), mit Free ruhen sie. Wer kaufen darf: `plans.can_buy_credits`.
- Verbrauch: zuerst der Rest des Monats, erst danach die gekauften (`reserve` teilt die Reservierung so auf, `settle`
  rechnet in derselben Reihenfolge ab; aeltester Kauf zuerst). Mehr als Monats-Credits + gekaufte Credits geht nie.
- Ein Kauf wird genau einmal verbucht (`grant_purchase`: Quelle + Transaktions-ID sind der Schluessel, wiederholbar).
  Eine Erstattung zieht nur ab, was von genau diesem Kauf noch da ist, nie ins Minus (`refund_purchase`).
- Der Teil der Kosten, den gekaufte Credits bezahlen, zaehlt nicht gegen das Monats-Budget des Kontos
  (`credit_ledger.purchased_microeur` -> `ai_usage_log.purchased_microeur`, app/ai_backend.py).
- Die bisherigen Felder des Stands (`allowance`, `used`, `reserved`, `remaining`) bleiben die Monats-Credits; neu und
  zusaetzlich: `purchased`, `purchased_usable`, `purchased_scope` (all | chat | none), `available`, `can_buy` (alte Apps
  lesen sie nicht).

Tabellen in accounts.db (neben ai_usage_log): credit_months (Monatsstand je Konto), credit_ledger (jede Anfrage mit
Modell, Tokens, Kosten), credit_wallets und credit_purchases (gekaufte Credits). Die Kostenansicht des Betriebs
(admin_costs) fasst credit_ledger je Tag und Modell zusammen.
"""
from __future__ import annotations

import os
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from . import ai_prices, billing, db, plans

TZ = ZoneInfo("Europe/Berlin")
EXHAUSTED_MESSAGE = "Credits für diesen Monat aufgebraucht – am 1. gibt es neue."
# Plus mit dem KI-Chat (15.11.2026): keine Monats-Credits, am 1. kommt nichts Neues - es helfen nur gekaufte Credits
EXHAUSTED_NO_MONTHLY_MESSAGE = "Du hast keine Credits mehr. Credits kaufst du in der App für iPhone und iPad."
# Tarif -> Umgebungsvariable und Standard aus dem Vertrag (plans.CREDITS: 100 fuer Pro AI, sonst 0, Probe 25)
ALLOWANCE_ENV = {"pro_ai": ("LERNAPP_CREDITS_PRO_AI", plans.CREDITS["pro_ai"]),
                 "plus": ("LERNAPP_CREDITS_PLUS", plans.CREDITS["plus"]), "free": ("LERNAPP_CREDITS_FREE", plans.CREDITS["free"])}
TRIAL_ENV = ("LERNAPP_CREDITS_TRIAL", plans.CREDITS["trial"])
# Reservierungen ohne Abrechnung (Prozess abgestuerzt) verfallen nach so vielen Minuten
STALE_MINUTES = 15
# so lange liefert dieselbe request_id die fertige Antwort noch einmal
REPLAY_HOURS = 24

SCHEMA = """
CREATE TABLE IF NOT EXISTS credit_months (
    user_id TEXT NOT NULL,
    period TEXT NOT NULL,                  -- YYYY-MM (Europe/Berlin)
    allowance INTEGER NOT NULL,            -- Credits des Monats (aus dem aktuellen Tarif)
    used INTEGER NOT NULL DEFAULT 0,       -- abgerechnet
    reserved INTEGER NOT NULL DEFAULT 0,   -- laufende Anfragen
    plan TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (user_id, period)
);
CREATE TABLE IF NOT EXISTS credit_ledger (
    user_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    period TEXT NOT NULL,
    day TEXT NOT NULL,                     -- YYYY-MM-DD (Europe/Berlin), fuer die Kostenansicht
    purpose TEXT NOT NULL,
    funding TEXT NOT NULL,                 -- credits | shared | own_chatgpt
    state TEXT NOT NULL,                   -- reserved | settled | refunded | expired | free
    model TEXT,
    reserved INTEGER NOT NULL DEFAULT 0,
    charged INTEGER NOT NULL DEFAULT 0,
    cost_microeur INTEGER NOT NULL DEFAULT 0,
    input_tokens INTEGER NOT NULL DEFAULT 0,
    cached_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    images INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    settled_at TEXT,
    result TEXT,                           -- Antwort fuer eine Wiederholung derselben request_id, nach 24 h geleert
    PRIMARY KEY (user_id, request_id)
);
CREATE INDEX IF NOT EXISTS idx_credit_ledger_day ON credit_ledger(day, model);
CREATE INDEX IF NOT EXISTS idx_credit_ledger_user ON credit_ledger(user_id, state, created_at);
-- Gekaufte Credits (15.11.2026): Stand je Konto. Ohne Fremdschluessel auf users, damit die Tabellen auch in einer
-- alten oder halb angelegten Datei entstehen (Migration vom 14.11.2026: "no such table: users").
CREATE TABLE IF NOT EXISTS credit_wallets (
    user_id TEXT PRIMARY KEY,
    balance INTEGER NOT NULL DEFAULT 0,    -- gekaufte Credits, noch nicht verbraucht (= Summe credit_purchases.remaining)
    reserved INTEGER NOT NULL DEFAULT 0,   -- davon von laufenden Anfragen gehalten
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS credit_purchases (
    source TEXT NOT NULL,                  -- app_store (spaeter z. B. stripe)
    transaction_id TEXT NOT NULL,          -- Kennung des Kaufs bei der Quelle: jede zaehlt genau einmal
    user_id TEXT NOT NULL,
    product_id TEXT,
    credits INTEGER NOT NULL,              -- gutgeschrieben
    remaining INTEGER NOT NULL,            -- davon noch da (Verbrauch: aeltester Kauf zuerst)
    state TEXT NOT NULL DEFAULT 'granted', -- granted | refunded
    refunded_credits INTEGER NOT NULL DEFAULT 0,   -- bei der Erstattung abgezogen (fuer REFUND_REVERSED)
    environment TEXT,                      -- Production | Sandbox | Xcode
    purchased_at TEXT,
    created_at TEXT NOT NULL,
    refunded_at TEXT,
    PRIMARY KEY (source, transaction_id)
);
CREATE INDEX IF NOT EXISTS idx_credit_purchases_user ON credit_purchases(user_id, created_at);
"""

# Spalten an credit_ledger fuer den gekauften Teil einer Anfrage (bestehende Dateien bekommen sie in ensure_schema)
LEDGER_COLUMNS = ("reserved_purchased", "charged_purchased", "purchased_microeur")


class CreditsError(Exception):
    def __init__(self, code: str, message: str, status: int = 429, extra: dict | None = None):
        super().__init__(message)
        self.code, self.message, self.status, self.extra = code, message, status, extra or {}


@dataclass
class Reservation:
    request_id: str
    reserved: int
    replay: bool = False
    result: str | None = None
    charged: int = 0
    balance: dict = field(default_factory=dict)
    purchased: int = 0                 # Teil der Reservierung aus den gekauften Credits


def _now(now: datetime | None = None) -> datetime:
    return (now or datetime.now(timezone.utc)).astimezone(timezone.utc)


def period_of(now: datetime | None = None) -> str:
    return _now(now).astimezone(TZ).strftime("%Y-%m")


def day_of(now: datetime | None = None) -> str:
    return _now(now).astimezone(TZ).strftime("%Y-%m-%d")


def resets_at(now: datetime | None = None) -> str:
    """Beginn des naechsten Monats in Berlin (ISO mit Versatz): ab dann gibt es neue Credits."""
    local = _now(now).astimezone(TZ)
    nxt = datetime(local.year + (local.month == 12), local.month % 12 + 1, 1, tzinfo=TZ)
    return nxt.isoformat()


def ensure_schema(conn: sqlite3.Connection) -> None:
    """Tabellen anlegen und bestehende Dateien nachziehen. Wiederholbar, vertraegt eine alte oder halb angelegte Datei
    (alles CREATE IF NOT EXISTS, keine Abhaengigkeit von `users`) und den gleichzeitigen Start mehrerer Prozesse
    (db.add_column)."""
    if conn.in_transaction:
        conn.commit()
    conn.executescript(SCHEMA)
    for col in LEDGER_COLUMNS:
        db.add_column(conn, "credit_ledger", col, "INTEGER NOT NULL DEFAULT 0")


def connect() -> sqlite3.Connection:
    from . import accounts
    conn = billing.connect()
    db.schema_once(conn, "credits", accounts.db_path(), ensure_schema)
    return conn


def _int_env(name: str, default: int) -> int:
    try:
        return max(0, int(os.environ.get(name) or default))
    except ValueError:
        return default


def plan_and_trial(conn: sqlite3.Connection, user_id: str, now: datetime | None = None) -> tuple[str, bool]:
    """Tarif des Kontos (mit users.plan) und ob nur die Probe laeuft."""
    legacy = None
    try:
        r = conn.execute("SELECT plan, plan_until FROM users WHERE id=?", (str(user_id),)).fetchone()
        legacy = {"plan": r[0], "plan_until": r[1]} if r else None
    except sqlite3.OperationalError as e:
        # Nur eine fehlende Tabelle/Spalte (reine Billing-Datei in Tests und Werkzeugen) heisst "kein Altbestand". Ein
        # echter Datenbankfehler (gesperrt, Platte) bleibt sichtbar, statt still als Tarif free zu enden (Audit B03, 08.11.2026).
        if "no such table" not in str(e) and "no such column" not in str(e):
            raise
        legacy = None
    plan = billing.current_plan(conn, str(user_id), _now(now), legacy)
    from . import ai_backend
    return plan, ai_backend.is_trial_account(conn, str(user_id), _now(now))


def allowance(plan: str, trial: bool) -> int:
    if trial:
        return _int_env(*TRIAL_ENV)
    name, default = ALLOWANCE_ENV.get(plan, ("", 0))
    return _int_env(name, default) if name else 0


def _month(conn: sqlite3.Connection, user_id: str, now: datetime, state: dict | None = None) -> sqlite3.Row | tuple:
    """Zeile des Monats anlegen (neuer Monat = neuer Stand) und den Rahmen auf den aktuellen Tarif setzen. In einer
    laufenden Transaktion aufrufen. `state` nimmt Tarif und Probe fuer den gekauften Topf mit (`_wallet`)."""
    period, t = period_of(now), now.isoformat()
    plan, trial = plan_and_trial(conn, user_id, now)
    if state is not None:
        state["plan"], state["trial"] = plan, trial
    allow = allowance(plan, trial)
    label = plan + (":trial" if trial else "")
    conn.execute("INSERT OR IGNORE INTO credit_months(user_id, period, allowance, used, reserved, plan, created_at, updated_at) "
                 "VALUES (?,?,?,0,0,?,?,?)", (user_id, period, allow, label, t, t))
    conn.execute("UPDATE credit_months SET allowance=?, plan=?, updated_at=? WHERE user_id=? AND period=? AND (allowance<>? OR plan<>?)",
                 (allow, label, t, user_id, period, allow, label))
    return conn.execute("SELECT allowance, used, reserved, plan FROM credit_months WHERE user_id=? AND period=?",
                        (user_id, period)).fetchone()


def _wallet(conn: sqlite3.Connection, user_id: str, state: dict | None = None) -> dict:
    """Gekaufter Topf des Kontos: `balance` (noch da), `reserved` (von laufenden Anfragen gehalten), `free` (frei),
    `usable` (der Tarif hat die StudiNow-KI) und `can_buy` (plans.can_buy_credits). `state`: Tarif und Probe aus `_month`."""
    r = conn.execute("SELECT balance, reserved FROM credit_wallets WHERE user_id=?", (user_id,)).fetchone()
    bal, res = (int(r[0]), int(r[1])) if r else (0, 0)
    plan, trial = (state or {}).get("plan"), bool((state or {}).get("trial"))
    scope = plans.purchased_credits_scope(plan)
    return {"balance": bal, "reserved": res, "free": max(0, bal - res), "plan": plan, "scope": scope,
            "usable": scope != "none", "can_buy": plans.can_buy_credits(plan, trial)}


def _balance_dict(row, now: datetime, wallet: dict | None = None) -> dict:
    """Stand fuer die Clients. Die bisherigen Felder (allowance, used, reserved, remaining) sind die Monats-Credits und
    bleiben unveraendert; dazu der gekaufte Topf: `purchased` (frei), `purchased_usable`, `available` (Rest des Monats +
    nutzbare gekaufte) und `can_buy`."""
    allow, used, reserved, plan = row
    w = wallet or {"free": 0, "usable": False, "can_buy": False, "scope": "none"}
    remaining = max(0, allow - used - reserved)
    return {"period": period_of(now), "allowance": allow, "used": used, "reserved": reserved,
            "remaining": remaining, "plan": plan, "resets_at": resets_at(now),
            "credit_eur": ai_prices.MICROEUR_PER_CREDIT / 1_000_000,
            "purchased": w["free"], "purchased_usable": bool(w["usable"]),
            # wofuer die gekauften Credits gelten: all (KI-Lernhilfe im Tarif), chat (Plus: nur der KI-Chat), none (ruhen)
            "purchased_scope": w.get("scope") or ("all" if w["usable"] else "none"),
            "available": remaining + (w["free"] if w["usable"] else 0), "can_buy": bool(w["can_buy"])}


def stale_minutes() -> int:
    """Nach so vielen Minuten gilt eine Reservierung als liegengeblieben. Nie kuerzer, als eine Anfrage laufen kann
    (Liste 95 Nr. 94): nach einem Fehler vor der Antwort uebernehmen Ersatz-Anbieter (hoechstens alle aus
    ai_router.PROVIDERS), jeder bis zum Verbindungs-Zeitlimit (LERNAPP_AI_TIMEOUT_S, 5-600 s, plus 10 s Verbinden), der
    letzte bis ai_providers.DEADLINE_S. Verfiele die Reservierung vorher, belastete die spaete Abrechnung nur noch das
    freie Guthaben. Mit dem Standard (90 s) bleibt es bei STALE_MINUTES."""
    from . import ai_backend, ai_providers, ai_router
    longest = (len(ai_router.PROVIDERS) - 1) * (ai_backend.timeout_s() + 10) + ai_providers.DEADLINE_S
    return max(STALE_MINUTES, longest // 60 + 2)


def _housekeeping(conn: sqlite3.Connection, user_id: str, now: datetime) -> None:
    """Liegengebliebene Reservierungen dieses Kontos freigeben und alte gespeicherte Antworten leeren."""
    stale = (now - timedelta(minutes=stale_minutes())).isoformat()
    for period, amount, bought in conn.execute("SELECT period, reserved, reserved_purchased FROM credit_ledger WHERE user_id=? "
                                               "AND state='reserved' AND created_at<?", (user_id, stale)).fetchall():
        conn.execute("UPDATE credit_months SET reserved=MAX(reserved-?, 0) WHERE user_id=? AND period=?", (amount - bought, user_id, period))
        if bought:
            conn.execute("UPDATE credit_wallets SET reserved=MAX(reserved-?, 0) WHERE user_id=?", (bought, user_id))
    conn.execute("UPDATE credit_ledger SET state='expired' WHERE user_id=? AND state='reserved' AND created_at<?", (user_id, stale))
    conn.execute("UPDATE credit_ledger SET result=NULL WHERE user_id=? AND result IS NOT NULL AND settled_at<?",
                 (user_id, (now - timedelta(hours=REPLAY_HOURS)).isoformat()))


def balance(conn: sqlite3.Connection, user_id: str, now: datetime | None = None) -> dict:
    t = _now(now)
    conn.execute("BEGIN IMMEDIATE")
    try:
        _housekeeping(conn, str(user_id), t)
        st: dict = {}
        row = _month(conn, str(user_id), t, st)
        wallet = _wallet(conn, str(user_id), st)
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return _balance_dict(row, t, wallet)


def lookup(conn: sqlite3.Connection, user_id: str, request_id: str, now: datetime | None = None) -> tuple[str, str | None] | None:
    """Stand einer request_id dieses Kontos nach dem Aufraeumen: (state, gespeicherte Antwort) oder None, wenn unbekannt.
    Fuer die Endpunkte: eine fertige ID mit Antwort wird wiederholt (0 Credits), eine laufende abgewiesen (409), bevor das
    Kontingent (app/entitlements.py) dieselbe ID als Doppelte sieht."""
    uid, t = str(user_id), _now(now)
    conn.execute("BEGIN IMMEDIATE")
    try:
        _housekeeping(conn, uid, t)
        row = conn.execute("SELECT state, result FROM credit_ledger WHERE user_id=? AND request_id=?", (uid, request_id)).fetchone()
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return (row[0], row[1]) if row else None


def funding_for(*, shared_hit: bool = False, own_chatgpt: bool = False) -> str:
    """Wer bezahlt: Geteiltes zuerst (kein KI-Aufruf), dann das eigene ChatGPT-Abo, erst dann Credits."""
    if shared_hit:
        return "shared"
    if own_chatgpt:
        return "own_chatgpt"
    return "credits"


def reserve(conn: sqlite3.Connection, user_id: str, request_id: str, purpose: str, estimate: int,
            now: datetime | None = None, model: str | None = None, purchased_only: bool = False) -> Reservation:
    """Schaetzung (Credits) fuer eine Anfrage reservieren, atomar: zuerst aus dem Rest des Monats, was fehlt aus den
    gekauften Credits (nur wenn der Tarif sie nutzen darf). Wirft CreditsError credits_exhausted (429), wenn beide Toepfe
    zusammen nicht reichen, und duplicate_request (409), wenn dieselbe ID gerade laeuft. Eine fertige ID liefert
    replay=True. `purchased_only`: die ganze Reservierung aus den gekauften Credits (app/ai_backend.py nimmt das, wenn
    das Monats-Budget den Monats-Teil sperrt - gekaufte Credits blockiert es nie)."""
    if not request_id:
        raise ValueError("request_id fehlt")
    uid, t = str(user_id), _now(now)
    estimate = max(1, int(estimate))
    conn.execute("BEGIN IMMEDIATE")
    try:
        _housekeeping(conn, uid, t)
        st: dict = {}
        row = _month(conn, uid, t, st)
        wallet = _wallet(conn, uid, st)
        old = conn.execute("SELECT state, result, charged FROM credit_ledger WHERE user_id=? AND request_id=?", (uid, request_id)).fetchone()
        if old and old[0] == "reserved":
            conn.execute("COMMIT")
            raise CreditsError("duplicate_request", "Diese Anfrage läuft schon.", 409)
        if old and old[0] in ("settled", "free"):
            conn.execute("COMMIT")
            return Reservation(request_id, 0, replay=True, result=old[1], charged=old[2], balance=_balance_dict(row, t, wallet))
        allow, used, reserved, _plan = row
        month_free = 0 if purchased_only else max(0, allow - used - reserved)
        # gekaufte Credits nur fuer Aufgaben, fuer die sie mit diesem Tarif gelten (Plus: nur der KI-Chat)
        bought_free = wallet["free"] if plans.can_use_purchased_credits(wallet["plan"], purpose) else 0
        if estimate > month_free + bought_free:
            conn.execute("COMMIT")
            # Plus (nur KI-Chat, keine Monats-Credits): dort kommt am 1. nichts Neues - ehrlicher Text
            message = EXHAUSTED_NO_MONTHLY_MESSAGE if allow <= 0 and wallet["scope"] == "chat" else EXHAUSTED_MESSAGE
            raise CreditsError("credits_exhausted", message, 429,
                               {"credits": {**_balance_dict(row, t, wallet), "needed": estimate}})
        from_month = min(estimate, month_free)              # zuerst die Monats-Credits
        from_bought = estimate - from_month                 # erst danach die gekauften
        period, day = period_of(t), day_of(t)
        if old:                                     # refunded/expired: derselbe Versuch noch einmal
            conn.execute("UPDATE credit_ledger SET period=?, day=?, purpose=?, funding='credits', state='reserved', model=?, reserved=?, "
                         "reserved_purchased=?, charged=0, charged_purchased=0, purchased_microeur=0, cost_microeur=0, input_tokens=0, "
                         "cached_tokens=0, output_tokens=0, images=0, created_at=?, settled_at=NULL, result=NULL "
                         "WHERE user_id=? AND request_id=?",
                         (period, day, purpose, model, estimate, from_bought, t.isoformat(), uid, request_id))
        else:
            conn.execute("INSERT INTO credit_ledger(user_id, request_id, period, day, purpose, funding, state, model, reserved, "
                         "reserved_purchased, created_at) VALUES (?,?,?,?,?,'credits','reserved',?,?,?,?)",
                         (uid, request_id, period, day, purpose, model, estimate, from_bought, t.isoformat()))
        conn.execute("UPDATE credit_months SET reserved=reserved+?, updated_at=? WHERE user_id=? AND period=?",
                     (from_month, t.isoformat(), uid, period))
        if from_bought:
            conn.execute("UPDATE credit_wallets SET reserved=reserved+?, updated_at=? WHERE user_id=?", (from_bought, t.isoformat(), uid))
        row = conn.execute("SELECT allowance, used, reserved, plan FROM credit_months WHERE user_id=? AND period=?", (uid, period)).fetchone()
        wallet = _wallet(conn, uid, st)
        conn.execute("COMMIT")
        return Reservation(request_id, estimate, balance=_balance_dict(row, t, wallet), purchased=from_bought)
    except CreditsError:
        raise
    except Exception:
        if conn.in_transaction:
            conn.execute("ROLLBACK")
        raise


def settle(conn: sqlite3.Connection, user_id: str, request_id: str, cost_microeur: int, *, model: str | None = None,
           input_tokens: int = 0, cached_tokens: int = 0, output_tokens: int = 0, images: int = 0, result: str | None = None,
           now: datetime | None = None) -> int:
    """Mit der echten Nutzung abrechnen: Credits = Kosten in Cent, aufgerundet. Die Reservierung wird frei. Eine schon
    abgerechnete ID bleibt, wie sie ist (liefert ihre Credits). Liefert die berechneten Credits.

    Harte Grenze (Inhaber 05.11.2026): berechnet wird nie mehr als reserviert (die Reservierung ist die Obergrenze aus
    app/ai_prices.worst_case_microeur), bei einer verfallenen Reservierung nie mehr als der freie Rest des Monats plus
    die freien gekauften Credits. `cost_microeur` bleibt die echte Zahl (Kostenansicht).

    Zwei Toepfe (15.11.2026): zuerst wird der Monats-Teil der Reservierung belastet, erst danach der gekaufte Teil
    (aeltester Kauf zuerst), nie mehr, als im gekauften Topf noch liegt. `purchased_microeur` haelt fest, welchen Teil der
    Kosten die gekauften Credits bezahlt haben (zaehlt nicht gegen das Monats-Budget, `purchased_share`)."""
    uid, t = str(user_id), _now(now)
    charged = ai_prices.credits_for(cost_microeur)
    conn.execute("BEGIN IMMEDIATE")
    try:
        old = conn.execute("SELECT state, period, reserved, charged, reserved_purchased FROM credit_ledger WHERE user_id=? AND request_id=?",
                           (uid, request_id)).fetchone()
        if not old or old[0] not in ("reserved", "expired"):
            conn.execute("COMMIT")
            return old[3] if old else 0
        state, period, reserved, held_bought = old[0], old[1], old[2], int(old[4] or 0)
        w = conn.execute("SELECT balance, reserved FROM credit_wallets WHERE user_id=?", (uid,)).fetchone()
        bal, bal_reserved = (int(w[0]), int(w[1])) if w else (0, 0)
        if state == "reserved":
            held_month = reserved - held_bought
            charged = min(charged, reserved)
            from_month = min(charged, held_month)           # zuerst der Monats-Teil
            from_bought = min(charged - from_month, held_bought, bal)   # nie mehr, als noch im gekauften Topf liegt
        else:                                               # eine verfallene Reservierung ist schon freigegeben
            held_month = held_bought = 0
            m = conn.execute("SELECT allowance, used, reserved FROM credit_months WHERE user_id=? AND period=?", (uid, period)).fetchone()
            from_month = min(charged, max(0, (m[0] - m[1] - m[2]) if m else 0))
            from_bought = min(charged - from_month, max(0, bal - bal_reserved))
        charged = from_month + from_bought
        conn.execute("UPDATE credit_months SET reserved=MAX(reserved-?, 0), used=used+?, updated_at=? WHERE user_id=? AND period=?",
                     (held_month, from_month, t.isoformat(), uid, period))
        if held_bought or from_bought:
            conn.execute("UPDATE credit_wallets SET reserved=MAX(reserved-?, 0), balance=MAX(balance-?, 0), updated_at=? WHERE user_id=?",
                         (held_bought, from_bought, t.isoformat(), uid))
            _spend_purchases(conn, uid, from_bought)
        # Kosten, die die gekauften Credits tragen: was ueber den Monats-Teil hinausgeht, hoechstens ihr Gegenwert
        bought_cost = min(from_bought * ai_prices.MICROEUR_PER_CREDIT,
                          max(0, int(cost_microeur) - from_month * ai_prices.MICROEUR_PER_CREDIT)) if from_bought else 0
        conn.execute("UPDATE credit_ledger SET state='settled', charged=?, charged_purchased=?, purchased_microeur=?, cost_microeur=?, "
                     "model=COALESCE(?, model), input_tokens=?, cached_tokens=?, output_tokens=?, images=?, settled_at=?, result=? "
                     "WHERE user_id=? AND request_id=?",
                     (charged, from_bought, bought_cost, int(cost_microeur), model, int(input_tokens), int(cached_tokens),
                      int(output_tokens), int(images), t.isoformat(), result, uid, request_id))
        conn.execute("COMMIT")
        return charged
    except Exception:
        conn.execute("ROLLBACK")
        raise


def refund(conn: sqlite3.Connection, user_id: str, request_id: str) -> bool:
    """Reservierung zurueckgeben (Fehler, fuer den OpenAI nichts berechnet hat). Abgerechnetes bleibt abgerechnet."""
    uid = str(user_id)
    conn.execute("BEGIN IMMEDIATE")
    try:
        old = conn.execute("SELECT state, period, reserved, reserved_purchased FROM credit_ledger WHERE user_id=? AND request_id=?",
                           (uid, request_id)).fetchone()
        if not old or old[0] != "reserved":
            conn.execute("COMMIT")
            return False
        bought = int(old[3] or 0)
        conn.execute("UPDATE credit_months SET reserved=MAX(reserved-?, 0) WHERE user_id=? AND period=?", (old[2] - bought, uid, old[1]))
        if bought:
            conn.execute("UPDATE credit_wallets SET reserved=MAX(reserved-?, 0) WHERE user_id=?", (bought, uid))
        conn.execute("UPDATE credit_ledger SET state='refunded' WHERE user_id=? AND request_id=?", (uid, request_id))
        conn.execute("COMMIT")
        return True
    except Exception:
        conn.execute("ROLLBACK")
        raise


def record_free(conn: sqlite3.Connection, user_id: str, request_id: str, purpose: str, funding: str, now: datetime | None = None,
                result: str | None = None) -> None:
    """Anfrage ohne Kosten fuer das Konto vermerken (geteilter Inhalt): 0 Credits, nur fuer die Statistik."""
    t = _now(now)
    conn.execute("INSERT OR IGNORE INTO credit_ledger(user_id, request_id, period, day, purpose, funding, state, created_at, settled_at, result) "
                 "VALUES (?,?,?,?,?,?,'free',?,?,?)", (str(user_id), request_id, period_of(t), day_of(t), purpose, funding,
                                                      t.isoformat(), t.isoformat(), result))


# ---------------------------------------------------------------- Gekaufte Credits

def purchased_share(conn: sqlite3.Connection, user_id: str, request_id: str) -> int:
    """Teil der Kosten einer abgerechneten Anfrage (Millionstel EUR), den gekaufte Credits bezahlt haben; 0 sonst."""
    r = conn.execute("SELECT purchased_microeur FROM credit_ledger WHERE user_id=? AND request_id=? AND state='settled'",
                     (str(user_id), request_id)).fetchone()
    return int(r[0] or 0) if r else 0


def purchased_free(conn: sqlite3.Connection, user_id: str, now: datetime | None = None) -> int:
    """Freie, jetzt nutzbare gekaufte Credits des Kontos (0, wenn der Tarif sie nicht nutzen darf)."""
    uid = str(user_id)
    plan, trial = plan_and_trial(conn, uid, _now(now))
    w = _wallet(conn, uid, {"plan": plan, "trial": trial})
    return w["free"] if w["usable"] else 0


def _spend_purchases(conn: sqlite3.Connection, user_id: str, amount: int) -> None:
    """`amount` Credits von den Kaeufen des Kontos abziehen, aeltester Kauf zuerst (in einer laufenden Transaktion)."""
    left = int(amount)
    if left <= 0:
        return
    for source, tid, remaining in conn.execute("SELECT source, transaction_id, remaining FROM credit_purchases WHERE user_id=? "
                                               "AND state='granted' AND remaining>0 ORDER BY created_at, transaction_id",
                                               (user_id,)).fetchall():
        take = min(left, int(remaining))
        conn.execute("UPDATE credit_purchases SET remaining=remaining-? WHERE source=? AND transaction_id=?", (take, source, tid))
        left -= take
        if left <= 0:
            break


class _tx:
    """BEGIN IMMEDIATE bis zum Ende des Blocks; in einer laufenden Transaktion des Aufrufers: nichts tun."""

    def __init__(self, conn: sqlite3.Connection):
        self.conn, self.own = conn, False

    def __enter__(self):
        if not self.conn.in_transaction:
            self.conn.execute("BEGIN IMMEDIATE")
            self.own = True
        return self.conn

    def __exit__(self, exc_type, *_):
        if self.own and self.conn.in_transaction:
            self.conn.execute("ROLLBACK" if exc_type else "COMMIT")
        return False


def _purchase_row(conn: sqlite3.Connection, source: str, transaction_id: str) -> dict | None:
    r = conn.execute("SELECT user_id, product_id, credits, remaining, state, refunded_credits FROM credit_purchases "
                     "WHERE source=? AND transaction_id=?", (source, transaction_id)).fetchone()
    return dict(zip(("user_id", "product_id", "credits", "remaining", "state", "refunded_credits"), r)) if r else None


def _purchase_result(status: str, row: dict, added: int = 0, removed: int = 0) -> dict:
    return {"status": status, "credits_added": added, "credits_removed": removed, "user_id": row["user_id"],
            "product_id": row["product_id"], "credits": row["credits"]}


def grant_purchase(conn: sqlite3.Connection, user_id: str, source: str, transaction_id: str, credits: int, *,
                   product_id: str | None = None, environment: str | None = None, purchased_at: str | None = None,
                   now: datetime | None = None) -> dict:
    """Einen geprueften Kauf gutschreiben - genau einmal. Schluessel ist (Quelle, Transaktions-ID): eine zweite Meldung
    desselben Kaufs (Wiederholung, gleichzeitige Meldungen, App und Server-Mitteilung) aendert nichts und liefert
    `already_granted` bzw. `refunded`. Die Quelle prueft vorher selbst, dass der Kauf echt ist (app/apple_store.py);
    ein anderer Bezahlweg fuellt denselben Topf ueber diese Funktion. Liefert status, credits_added, user_id."""
    if not transaction_id or not source:
        raise ValueError("Quelle und Transaktions-ID fehlen")
    uid, t, n = str(user_id), _now(now).isoformat(), max(0, int(credits))
    with _tx(conn):
        row = _purchase_row(conn, source, transaction_id)
        if row:
            return _purchase_result("refunded" if row["state"] == "refunded" else "already_granted", row)
        conn.execute("INSERT INTO credit_purchases(source, transaction_id, user_id, product_id, credits, remaining, state, environment, "
                     "purchased_at, created_at) VALUES (?,?,?,?,?,?,'granted',?,?,?)",
                     (source, transaction_id, uid, product_id, n, n, environment, purchased_at, t))
        conn.execute("INSERT INTO credit_wallets(user_id, balance, reserved, updated_at) VALUES (?,?,0,?) "
                     "ON CONFLICT(user_id) DO UPDATE SET balance=balance+excluded.balance, updated_at=excluded.updated_at", (uid, n, t))
        return _purchase_result("granted", {"user_id": uid, "product_id": product_id, "credits": n}, added=n)


def refund_purchase(conn: sqlite3.Connection, source: str, transaction_id: str, *, user_id: str | None = None,
                    product_id: str | None = None, credits: int = 0, environment: str | None = None,
                    now: datetime | None = None) -> dict:
    """Erstattung eines Kaufs: die noch vorhandenen Credits GENAU dieses Kaufs abziehen, nie ins Minus; Verbrauchtes
    bleibt verbraucht. Wiederholbar (`already_refunded`). Ein noch nie gemeldeter Kauf wird mit `user_id` als erstattet
    vermerkt (0 Credits), damit eine spaetere Meldung ihn nicht mehr gutschreibt; ohne Konto: `unknown`."""
    t = _now(now).isoformat()
    with _tx(conn):
        row = _purchase_row(conn, source, transaction_id)
        if not row:
            if not user_id:
                return {"status": "unknown", "credits_added": 0, "credits_removed": 0, "user_id": None, "product_id": product_id, "credits": 0}
            conn.execute("INSERT INTO credit_purchases(source, transaction_id, user_id, product_id, credits, remaining, state, environment, "
                         "created_at, refunded_at) VALUES (?,?,?,?,?,0,'refunded',?,?,?)",
                         (source, transaction_id, str(user_id), product_id, max(0, int(credits)), environment, t, t))
            return _purchase_result("refunded", {"user_id": str(user_id), "product_id": product_id, "credits": max(0, int(credits))})
        if row["state"] == "refunded":
            return _purchase_result("already_refunded", row)
        take = max(0, int(row["remaining"]))
        conn.execute("UPDATE credit_purchases SET remaining=0, state='refunded', refunded_credits=?, refunded_at=? "
                     "WHERE source=? AND transaction_id=?", (take, t, source, transaction_id))
        conn.execute("UPDATE credit_wallets SET balance=MAX(balance-?, 0), updated_at=? WHERE user_id=?", (take, t, row["user_id"]))
        return _purchase_result("refunded", row, removed=take)


def restore_purchase(conn: sqlite3.Connection, source: str, transaction_id: str, now: datetime | None = None) -> dict:
    """Erstattung zurueckgenommen (Apple: REFUND_REVERSED): die bei der Erstattung abgezogenen Credits kommen zurueck.
    Ohne erstatteten Kauf aendert sich nichts."""
    t = _now(now).isoformat()
    with _tx(conn):
        row = _purchase_row(conn, source, transaction_id)
        if not row:
            return {"status": "unknown", "credits_added": 0, "credits_removed": 0, "user_id": None, "product_id": None, "credits": 0}
        if row["state"] != "refunded":
            return _purchase_result("already_granted", row)
        back = max(0, int(row["refunded_credits"]))
        conn.execute("UPDATE credit_purchases SET remaining=remaining+?, state='granted', refunded_credits=0, refunded_at=NULL "
                     "WHERE source=? AND transaction_id=?", (back, source, transaction_id))
        conn.execute("INSERT INTO credit_wallets(user_id, balance, reserved, updated_at) VALUES (?,?,0,?) "
                     "ON CONFLICT(user_id) DO UPDATE SET balance=balance+excluded.balance, updated_at=excluded.updated_at",
                     (row["user_id"], back, t))
        return _purchase_result("granted", row, added=back)


def granted_since(conn: sqlite3.Connection, user_id: str, since_iso: str, environments: tuple[str, ...]) -> int:
    """Summe der seit `since_iso` gutgeschriebenen Credits des Kontos aus den genannten Umgebungen (Grenze fuer Kaeufe
    aus der Testumgebung, app/apple_store.py)."""
    rows = conn.execute("SELECT credits, environment FROM credit_purchases WHERE user_id=? AND created_at>=?",
                        (str(user_id), since_iso)).fetchall()
    return sum(int(n or 0) for n, env in rows if env in environments)


def purchases(conn: sqlite3.Connection, user_id: str) -> list[dict]:
    """Kaeufe eines Kontos (Konto-Export, Betrieb), aeltester zuerst."""
    cur = conn.execute("SELECT source, transaction_id, product_id, credits, remaining, state, refunded_credits, environment, "
                       "purchased_at, created_at, refunded_at FROM credit_purchases WHERE user_id=? ORDER BY created_at, transaction_id",
                       (str(user_id),))
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def wallet_consistent(conn: sqlite3.Connection, user_id: str) -> bool:
    """Pruefung (Tests, Betrieb): der Stand des Kontos ist die Summe dessen, was von seinen Kaeufen noch da ist."""
    w = conn.execute("SELECT balance FROM credit_wallets WHERE user_id=?", (str(user_id),)).fetchone()
    s = conn.execute("SELECT COALESCE(SUM(remaining), 0) FROM credit_purchases WHERE user_id=? AND state='granted'",
                     (str(user_id),)).fetchone()
    return (int(w[0]) if w else 0) == int(s[0] or 0)


# ---------------------------------------------------------------- Betrieb

def admin_costs(conn: sqlite3.Connection, days: int = 31, now: datetime | None = None) -> dict:
    """Kosten je Tag (Berlin) und Modell der letzten `days` Tage, dazu der laufende Monat: Anfragen, Tokens, Kosten in
    EUR, berechnete Credits, Konten, Anfragen aus Geteiltem (0 Credits). Nur fuer den Betrieb."""
    t = _now(now)
    since = (t.astimezone(TZ) - timedelta(days=max(1, min(int(days), 366)) - 1)).strftime("%Y-%m-%d")
    rows = conn.execute("""SELECT day, COALESCE(model, ''), COUNT(*), COUNT(DISTINCT user_id), SUM(input_tokens), SUM(cached_tokens),
                                  SUM(output_tokens), SUM(images), SUM(cost_microeur), SUM(charged)
                           FROM credit_ledger WHERE day>=? AND state='settled' GROUP BY day, model ORDER BY day DESC, model""",
                        (since,)).fetchall()
    per_day = [{"day": r[0], "model": r[1], "requests": r[2], "accounts": r[3], "input_tokens": r[4] or 0, "cached_tokens": r[5] or 0,
                "output_tokens": r[6] or 0, "images": r[7] or 0, "cost_eur": round((r[8] or 0) / 1_000_000, 6), "credits": r[9] or 0}
               for r in rows]
    period = period_of(t)
    m = conn.execute("""SELECT COUNT(*), COUNT(DISTINCT user_id), COALESCE(SUM(cost_microeur), 0), COALESCE(SUM(charged), 0)
                        FROM credit_ledger WHERE period=? AND state='settled'""", (period,)).fetchone()
    free = conn.execute("SELECT funding, COUNT(*) FROM credit_ledger WHERE period=? AND state='free' GROUP BY funding", (period,)).fetchall()
    top = conn.execute("""SELECT used, allowance FROM credit_months WHERE period=? ORDER BY used DESC LIMIT 1""", (period,)).fetchone()
    exhausted = conn.execute("SELECT COUNT(*) FROM credit_months WHERE period=? AND allowance>0 AND used>=allowance", (period,)).fetchone()[0]
    return {"since": since, "per_day_model": per_day,
            "month": {"period": period, "requests": m[0], "accounts": m[1], "cost_eur": round(m[2] / 1_000_000, 6), "credits": m[3],
                      "cost_per_account_eur": round(m[2] / 1_000_000 / m[1], 6) if m[1] else 0.0,
                      "free_requests": {f: n for f, n in free}, "max_used_credits": top[0] if top else 0,
                      "accounts_exhausted": exhausted},
            "prices": ai_prices.listing(), "prices_checked": ai_prices.CHECKED, "usd_eur": ai_prices.usd_to_eur()}
