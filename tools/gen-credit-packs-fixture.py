"""Erzeugt packages/shared-contracts/fixtures/credit-packs/contract.json: KI-Credits zum Nachkaufen (Auftrag des
Inhabers vom 15.11.2026, docs/KI-CREDITS-2026-11-15.md) aus der Python-Referenz.

Inhalt: die Pakete (Credits je Produkt-ID, Listenpreis), der Wert eines Credits, die Regel "wer darf kaufen", Faelle
fuer die Anzeige beider Toepfe mit den Texten aus app/credit_texts.py und aufgezeichnete Ablaeufe gegen den echten
Server im gehosteten Modus (Kauf, Wiederholung, Erstattung, Tarifende, Probe, Fehler; Tokens, signierte Kaufdaten und
Zeiten durch Platzhalter ersetzt; von GET /api/entitlements nur `plan`, `credits`, `credit_packs`). Der Swift-Kern liest
dieselbe Datei (CreditPacksTests.swift), die Web-Oberflaeche prueft ihre Texte dagegen (tests/js/credit-packs.test.mjs).
Aufruf im Projektordner: python tools/gen-credit-packs-fixture.py [--check]
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "credit-packs" / "contract.json"
PW = "sehr-geheim-123"
ENTITLEMENT_KEYS = ("plan", "credits", "credit_packs")

_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{40,50}$")
_HEX32_RE = re.compile(r"^[a-f0-9]{32}$")
_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$")
_MONTH_RE = re.compile(r"^\d{4}-\d{2}$")
_JWS_RE = re.compile(r"^[A-Za-z0-9_-]{100,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$")


def _setup_env() -> None:
    tmp = tempfile.mkdtemp(prefix="uniflow-credit-packs-fixture-")
    os.environ["LERNAPP_DATA_DIR"] = str(Path(tmp) / "data")
    os.environ["LERNAPP_LOG_DIR"] = str(Path(tmp) / "logs")
    os.environ["LERNAPP_ALLOWED_HOSTS"] = "test"
    os.environ["LERNAPP_NO_SCHEDULER"] = "1"
    sys.path.insert(0, str(ROOT))
    sys.path.insert(0, str(ROOT / "tests"))


def scrub(x):
    """Zufaelliges und Zeitabhaengiges durch Platzhalter ersetzen, damit die Datei vergleichbar bleibt."""
    if isinstance(x, dict):
        return {k: scrub(v) for k, v in x.items()}
    if isinstance(x, list):
        return [scrub(v) for v in x]
    if isinstance(x, str):
        if _JWS_RE.match(x):
            return "<signierte-transaktion>"
        if _TOKEN_RE.match(x):
            return "<token>"
        if _HEX32_RE.match(x):
            return "<user-id>"
        if _ISO_RE.match(x):
            return "<zeit>"
        if _MONTH_RE.match(x):
            return "<monat>"
    return x


def balance_cases() -> list[dict]:
    """Staende, wie der Dienst sie liefert, mit den Texten der Referenz (app/credit_texts.py)."""
    from app import credit_texts as texts

    def state(allowance, remaining, purchased=None, usable=True, can_buy=True, resets_at="2026-12-01T00:00:00+01:00", plan="pro_ai",
              scope=None):
        c = {"period": "2026-11", "allowance": allowance, "used": max(0, allowance - remaining), "reserved": 0, "remaining": remaining,
             "plan": plan, "resets_at": resets_at, "credit_eur": 0.0065}
        if purchased is not None:
            c.update({"purchased": purchased, "purchased_usable": usable, "purchased_scope": scope or ("all" if usable else "none"),
                      "available": remaining + (purchased if usable else 0), "can_buy": can_buy})
        return c

    cases = [
        ("Pro AI, beide Toepfe gefuellt", state(100, 37, 80)),
        ("Pro AI, Monat leer, gekaufte da", state(100, 0, 80)),
        ("Pro AI, alles aufgebraucht", state(100, 0, 0)),
        ("Pro AI ohne Kauf", state(100, 100, 0)),
        ("Probe: 25 Credits, kaufen geht nicht", state(25, 9, 0, can_buy=False, plan="pro_ai:trial")),
        ("Plus mit gekauften Credits: nur der KI-Chat", state(0, 0, 60, scope="chat", plan="plus")),
        ("Plus ohne Credits: darf kaufen", state(0, 0, 0, scope="chat", plan="plus")),
        ("Free mit ruhenden gekauften Credits", state(0, 0, 60, usable=False, can_buy=False, plan="free")),
        ("Free ohne Credits", state(0, 0, 0, usable=False, can_buy=False, plan="free")),
        ("Jahreswechsel", state(100, 5, 12, resets_at="2027-01-01T00:00:00+01:00")),
        ("aelterer Dienst ohne die neuen Felder", state(100, 37)),
        ("Stand ohne lesbares Datum", state(100, 0, 3, resets_at="")),
    ]
    return [{"name": name, "credits": c,
             "expect": {"line": texts.balance_line(c), "keep_note": texts.keep_note(c), "dormant_note": texts.dormant_note(c),
                        "scope": texts.scope(c), "scope_note": texts.scope_note(c),
                        "available": texts.available(c), "offers_shop": texts.offers_shop(c), "reset_day": texts.reset_day(c.get("resets_at"))}}
            for name, c in cases]


def build(app=None) -> dict:
    """Zeichnet die Ablaeufe auf. `app`: der Server im gehosteten Modus mit leerer Kontodatenbank (Tests geben ihn);
    ohne Angabe stellt die Funktion den Modus selbst her und raeumt danach auf."""
    from conftest import asgi_call
    from test_credit_packs import pack_tx
    from test_subscriptions import AppleSigner, FakeAI
    from app import accounts, ai_backend, ai_prices, billing, config, credit_texts, credits, plans
    own = app is None
    if own:
        from app.server import app as server_app
        app = server_app
        config.MODE = "hosted"
        accounts.db_path().unlink(missing_ok=True)
    signer = AppleSigner(Path(tempfile.mkdtemp(prefix="uniflow-credit-packs-apple-")))
    saved = {k: os.environ.get(k) for k in ("LERNAPP_APPLE_ROOT_CERTS", "LERNAPP_CREDITS_PRO_AI", "LERNAPP_AI_PRICE_IN_EUR",
                                             "LERNAPP_AI_PRICE_OUT_EUR", "LERNAPP_CREDIT_PACKS", "LERNAPP_CREDITS_SANDBOX_MONTH")}
    os.environ["LERNAPP_APPLE_ROOT_CERTS"] = str(signer.root_path)
    for k in ("LERNAPP_CREDIT_PACKS", "LERNAPP_CREDITS_SANDBOX_MONTH", "LERNAPP_CREDITS_PRO_AI"):
        os.environ.pop(k, None)
    flows: list[dict] = []
    klein, gross = [p["product_id"] for p in plans.credit_packs()]

    def call(step, method, path, body=None, token=None, note=None):
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None, headers=headers)
        data = json.loads(raw) if raw else None
        shown = data
        if path == "/api/entitlements" and isinstance(data, dict):
            shown = {k: data[k] for k in ENTITLEMENT_KEYS if k in data}
        entry = {"step": step, "method": method, "path": path, "auth": bool(token), "request": scrub(body), "status": st,
                 "response": scrub(shown)}
        if note:
            entry["note"] = note
        flows.append(entry)
        return data

    def register(email, plan, trial=False):
        st, _, raw = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": PW, "university": "luh"}))
        d = json.loads(raw)
        if not trial:
            conn = billing.connect()
            try:
                billing.end_trial(conn, d["user"]["id"])
            finally:
                conn.close()
        accounts.mark_email_verified(d["user"]["id"])
        if plan != "free":
            accounts.set_plan(d["user"]["id"], plan)
        return d["user"], d["token"]

    def spend(user_id, amount, rid):
        conn = credits.connect()
        try:
            credits.reserve(conn, user_id, rid, "tutor:explain", amount)
            credits.settle(conn, user_id, rid, amount * ai_prices.MICROEUR_PER_CREDIT)
        finally:
            conn.close()

    try:
        pro, tok = register("pro@beispiel.de", "pro_ai")
        call("Pro AI: Stand vor dem Kauf (beide Toepfe, Pakete, wo man kaufen kann)", "GET", "/api/entitlements", token=tok)
        buy = lambda step, signed, token=tok, note=None: call(step, "POST", "/api/billing/credits/apple",
                                                              {"signed_transaction": signed}, token=token, note=note)
        buy("Kleines Paket kaufen: gutgeschrieben, danach darf die App abschliessen", pack_tx(signer, pro["id"], klein, "9000000000000001"))
        buy("Dieselbe Transaktion noch einmal (Wiederholung nach Netzfehler): nichts doppelt",
            pack_tx(signer, pro["id"], klein, "9000000000000001"))
        buy("Grosses Paket kaufen", pack_tx(signer, pro["id"], gross, "9000000000000002"))
        spend(pro["id"], 100, "monat")
        spend(pro["id"], 30, "gekauft")
        call("Verbrauch: erst die 100 Monats-Credits, dann 30 gekaufte", "GET", "/api/entitlements", token=tok)
        note = signer.notification("REFUND", pack_tx(signer, pro["id"], klein, "9000000000000001", revoked=True))
        st, _, raw = asgi_call(app, "POST", "/api/billing/apple/notifications", body=json.dumps({"signedPayload": note}))
        flows.append({"step": "Apple meldet die Erstattung des kleinen Pakets: nur sein Rest (70) geht weg", "method": "POST",
                      "path": "/api/billing/apple/notifications", "auth": False, "request": {"signedPayload": "<signierte-mitteilung>"},
                      "status": st, "response": scrub({k: v for k, v in json.loads(raw).items()
                                                       if k in ("ok", "type", "applied", "status", "credits_added", "credits_removed", "product_id")})})
        call("Stand nach der Erstattung", "GET", "/api/entitlements", token=tok)
        buy("Die App meldet die erstattete Transaktion: nichts mehr gutzuschreiben, abschliessen",
            pack_tx(signer, pro["id"], klein, "9000000000000001", revoked=True))

        os.environ["LERNAPP_AI_PRICE_IN_EUR"], os.environ["LERNAPP_AI_PRICE_OUT_EUR"] = "350", "350"
        ai_backend.set_provider(FakeAI())
        leer, tok_leer = register("leer@beispiel.de", "pro_ai")
        spend(leer["id"], 100, "monat-leer")
        call("Credits reichen nicht: 429 mit dem Stand (die App zeigt das Blatt, weil can_buy true ist)", "POST", "/api/ai/tutor",
             {"mode": "explain", "page_text": "Matrizen", "request_id": "leer-1"}, token=tok_leer)
        _, tok_plus = register("plus@beispiel.de", "plus")
        call("Plus ohne Credits: der KI-Chat antwortet 429 mit dem Stand (Pakete kaufen), Erklaeren 403", "POST", "/api/ai/tutor",
             {"mode": "ask", "page_text": "Matrizen", "question": "Was ist eine Matrix?", "request_id": "plus-leer-1"}, token=tok_plus)

        accounts.set_plan(pro["id"], "plus")
        call("Wechsel zu Plus: die gekauften Credits bleiben, gelten aber nur noch fuer den KI-Chat", "GET", "/api/entitlements", token=tok)
        call("Plus: der KI-Chat (freie Frage) laeuft aus gekauften Credits", "POST", "/api/ai/tutor",
             {"mode": "ask", "page_text": "Matrizen", "question": "Was ist eine Matrix?", "request_id": "plus-chat-1"}, token=tok)
        call("Plus: Erklaeren ist KI-Lernhilfe und bleibt Pro AI (403, nichts abgebucht)", "POST", "/api/ai/tutor",
             {"mode": "explain", "page_text": "Matrizen", "request_id": "plus-lernhilfe-1"}, token=tok)
        accounts.set_plan(pro["id"], "free")
        call("Pro AI ist vorbei: die gekauften Credits bleiben beim Konto und ruhen", "GET", "/api/entitlements", token=tok)
        accounts.set_plan(pro["id"], "pro_ai")
        call("Pro AI laeuft wieder: die gekauften Credits sind wieder nutzbar", "GET", "/api/entitlements", token=tok)

        _, tok_probe = register("probe@beispiel.de", "free", trial=True)
        call("Probe: 25 Credits, kaufen geht erst mit Pro AI", "GET", "/api/entitlements", token=tok_probe)

        buy("Beschaedigte Kaufdaten: 400, die App schliesst nicht ab", "kaputt")
        buy("Unbekanntes Produkt: 400", pack_tx(signer, pro["id"], "de.uniflow.credits.unbekannt", "9000000000000003"))
        buy("Ohne Anmeldung: 401", pack_tx(signer, pro["id"], klein, "9000000000000004"), token=None)
        other, tok_other = register("anderes@beispiel.de", "pro_ai")
        buy("Ein anderes Konto meldet den Kauf: die Credits gehen an das Konto, das gekauft hat",
            pack_tx(signer, pro["id"], klein, "9000000000000005"), token=tok_other)
    finally:
        ai_backend.set_provider(None)
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        if own:
            config.MODE = "local"
            accounts.db_path().unlink(missing_ok=True)

    packs = plans.credit_packs()
    buy_cases = [{"plan": plan, "trial_only": trial, "can_buy": plans.can_buy_credits(plan, trial),
                  "purchased_usable": plans.can_use_purchased_credits(plan), "purchased_scope": plans.purchased_credits_scope(plan)}
                 for plan in ("free", "plus", "pro_ai", "pro_connect") for trial in (False, True)]
    return {
        "_hinweis": "Erzeugt mit tools/gen-credit-packs-fixture.py aus der Python-Referenz (app/plans.py, app/credits.py, "
                    "app/credit_texts.py); nicht von Hand aendern.",
        "credit_microeur": ai_prices.MICROEUR_PER_CREDIT,
        "packs": [{**p, "label": credit_texts.pack_label(p["credits"]),
                   "max_cost_microeur": p["credits"] * ai_prices.MICROEUR_PER_CREDIT} for p in packs],
        "buy_rule": {"buy_plans": list(plans.CREDIT_PACKS["buy_plans"]), "buy_in_trial": plans.CREDIT_PACKS["buy_in_trial"],
                     "use_right": plans.CREDIT_PACKS["use_right"], "chat_right": plans.CREDIT_PACKS["chat_right"],
                     "chat_purposes": list(plans.CREDIT_PACKS["chat_purposes"]), "cases": buy_cases},
        "purchase": {"path": "/api/billing/credits/apple", "request": {"signed_transaction": "<Transaction.jwsRepresentation>"},
                     "finish_rule": "Die App ruft finish() nur nach Status 200 (jeder status-Wert). Bei jedem anderen Status und "
                                    "ohne Antwort bleibt der Kauf offen und wird beim naechsten Start erneut gemeldet.",
                     "statuses": ["granted", "already_granted", "refunded", "already_refunded"],
                     "exhausted_code": "credits_exhausted"},
        "texts": {"title_exhausted": credit_texts.TITLE_EXHAUSTED, "title_shop": credit_texts.TITLE_SHOP, "not_now": credit_texts.NOT_NOW,
                  "keep": credit_texts.KEEP, "buy_needs_pro_ai": credit_texts.BUY_NEEDS_PRO_AI, "web_hint": credit_texts.WEB_HINT,
                  "no_credits": credit_texts.NO_CREDITS, "chat_only": credit_texts.CHAT_ONLY, "chat_lock": credit_texts.CHAT_LOCK},
        "balance_cases": balance_cases(),
        "flows": flows,
    }


def main(check: bool) -> bool:
    _setup_env()
    from schema_source import write_or_check
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    return write_or_check(OUT, text, check)


if __name__ == "__main__":
    sys.path.insert(0, str(ROOT / "tools"))
    ok = main("--check" in sys.argv)
    sys.exit(0 if ok or "--check" not in sys.argv else 1)
