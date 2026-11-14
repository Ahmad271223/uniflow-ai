"""Erzeugt packages/shared-contracts/fixtures/device-limit/contract.json: die Geraete-Regel (Auftrag des Inhabers vom
14.11.2026, app/device_limit.py) aus der Python-Referenz.

Inhalt: die Kopfzeile der Faehigkeit, die Zustaende, der genannte Tarif mit Preis, die reine Regel des Dienstes
(`rule_cases`), was die App aus Auskunft und eigenem Tarif macht (`client_cases`) und aufgezeichnete Ablaeufe gegen den
echten Server im gehosteten Modus (Tokens, IDs und Zeiten durch Platzhalter ersetzt; von GET /api/entitlements nur die
Felder, die die App fuer die Regel liest). Der Swift-Kern liest dieselbe Datei (DeviceRuleTests.swift).
Aufruf im Projektordner: python tools/gen-device-limit-fixture.py [--check]
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "device-limit" / "contract.json"
PW = "sehr-geheim-123"
ENTITLEMENT_KEYS = ("plan", "paid_plan", "needs_plan_choice", "device")

_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{40,50}$")
_HEX32_RE = re.compile(r"^[a-f0-9]{32}$")
_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$")


def _setup_env() -> None:
    tmp = tempfile.mkdtemp(prefix="uniflow-device-limit-fixture-")
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
        if _TOKEN_RE.match(x):
            return "<token>"
        if _HEX32_RE.match(x):
            return "<user-id>"
        if _ISO_RE.match(x):
            return "<zeit-utc>"
    return x


def build(app=None) -> dict:
    """Zeichnet die Ablaeufe auf. `app`: der Server im gehosteten Modus mit leerer Kontodatenbank (Tests geben ihn);
    ohne Angabe stellt die Funktion den Modus selbst her und raeumt danach auf."""
    from conftest import asgi_call
    from app import accounts, billing, config, device_limit, plans
    own = app is None
    if own:
        from app.server import app as server_app
        app = server_app
        config.MODE = "hosted"
        accounts.db_path().unlink(missing_ok=True)
    flows: list[dict] = []
    caps = {"X-StudiNow-Caps": device_limit.CAP}

    def call(step, method, path, body=None, token=None, capable=True, note=None):
        headers = dict(caps) if capable else {}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        st, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None, headers=headers)
        data = json.loads(raw) if raw else None
        shown = data
        if path == "/api/entitlements" and isinstance(data, dict):
            shown = {k: data[k] for k in ENTITLEMENT_KEYS if k in data}
        entry = {"step": step, "method": method, "path": path, "capability": capable, "auth": bool(token), "request": body,
                 "status": st, "response": scrub(shown)}
        if note:
            entry["note"] = note
        flows.append(entry)
        return data

    def register(email, plan):
        st, _, raw = asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": email, "password": PW, "university": "luh"}))
        user = json.loads(raw)["user"]
        conn = billing.connect()
        try:
            billing.end_trial(conn, user["id"])                  # "Free" meint den Stand nach der 7-Tage-Probe
        finally:
            conn.close()
        if plan != "free":
            accounts.set_plan(user["id"], plan)
        return user

    def login(step, email, device_id, name, capable=True, note=None):
        return call(step, "POST", "/api/account/login", {"email": email, "password": PW, "device_id": device_id, "device_name": name},
                    capable=capable, note=note)

    try:
        free = register("free@beispiel.de", "free")
        a = login("Free: erstes Geraet anmelden (wird das eine Geraet)", "free@beispiel.de", "ipad-1", "iPad")
        b = login("Free: zweites Geraet anmelden (Hinweis-Bildschirm)", "free@beispiel.de", "iphone-1", "iPhone")
        call("Free: Stand auf dem ersten Geraet", "GET", "/api/entitlements", token=a["token"])
        call("Free: Stand auf dem zweiten Geraet", "GET", "/api/entitlements", token=b["token"])
        call("Free: Konto auf dem zweiten Geraet", "GET", "/api/account/me", token=b["token"])
        flows[-1]["response"] = {"device": flows[-1]["response"]["device"]}
        call("Free: dieses Geraet stattdessen nutzen", "POST", "/api/account/device/primary", token=b["token"])
        call("Free: danach zeigt das andere Geraet den Hinweis", "GET", "/api/entitlements", token=a["token"])
        accounts.set_plan(free["id"], "pro_ai")
        call("Nach dem Kauf von Pro AI: kein Hinweis mehr", "GET", "/api/entitlements", token=a["token"])
        accounts.set_plan(free["id"], "free")

        register("plus@beispiel.de", "plus")
        login("Plus: erstes Geraet anmelden", "plus@beispiel.de", "ipad-1", "iPad")
        p2 = login("Plus: zweites Geraet anmelden (einmaliger Hinweis, nie gesperrt)", "plus@beispiel.de", "iphone-1", "iPhone")
        call("Plus: Stand auf dem zweiten Geraet", "GET", "/api/entitlements", token=p2["token"])

        register("pro@beispiel.de", "pro_ai")
        login("Pro AI: erstes Geraet anmelden", "pro@beispiel.de", "ipad-1", "iPad")
        login("Pro AI: zweites Geraet anmelden (keine Einschraenkung)", "pro@beispiel.de", "iphone-1", "iPhone")

        asgi_call(app, "POST", "/api/account/register", body=json.dumps({"email": "probe@beispiel.de", "password": PW, "university": "luh"}))
        login("Probe: erstes Geraet anmelden", "probe@beispiel.de", "ipad-1", "iPad")
        login("Probe: zweites Geraet anmelden (zaehlt wie Pro AI)", "probe@beispiel.de", "iphone-1", "iPhone")

        register("alt@beispiel.de", "free")
        login("Aeltere App ohne die Faehigkeit: erstes Geraet", "alt@beispiel.de", "ipad-1", "iPad", capable=False)
        old = login("Aeltere App ohne die Faehigkeit: zweites Geraet (merkt nichts)", "alt@beispiel.de", "iphone-1", "iPhone", capable=False,
                    note="ohne X-StudiNow-Caps: kein Feld device, kein Hauptgeraet")
        call("Aeltere App: Stand ohne Feld device", "GET", "/api/entitlements", token=old["token"], capable=False)
        web = call("Sitzung ohne Geraete-Kennung", "POST", "/api/account/login", {"email": "alt@beispiel.de", "password": PW}, capable=False)
        call("Dieses Geraet nutzen ohne Geraete-Kennung", "POST", "/api/account/device/primary", token=web["token"])
        call("Dieses Geraet nutzen ohne Sitzung", "POST", "/api/account/device/primary")
        call("Dieses Geraet nutzen ohne die Faehigkeit (aeltere App, Web, Windows zaehlen nicht)", "POST", "/api/account/device/primary",
             token=old["token"], capable=False)
    finally:
        if own:
            config.MODE = "local"
            accounts.db_path().unlink(missing_ok=True)

    up = device_limit.upgrade_plan()
    rule_cases = [{"plan": plan, "device_id": dev, "primary_device_id": prim, "state": device_limit.evaluate(plan, dev, prim)}
                  for plan in ("free", "plus", "pro_ai") for dev, prim in (("a", "a"), ("b", "a"), (None, "a"), ("b", None))]
    client_cases = [{"server_state": s, "local_plan": p, "shown": device_limit.shown_state(s, p)}
                    for s in (None, "ok", "blocked", "hint_plus", "unbekannt") for p in ("free", "plus", "pro_ai")]
    return {
        "_hinweis": "Erzeugt mit tools/gen-device-limit-fixture.py aus der Python-Referenz (app/device_limit.py); nicht von Hand aendern.",
        "capability": {"header": "X-StudiNow-Caps", "value": device_limit.CAP,
                       "rule": "Die Regel greift nur fuer Apple-Apps, die diese Kopfzeile schicken. Aeltere Apps, Web und Windows "
                               "bekommen kein Feld device und werden nie Hauptgeraet."},
        "states": list(device_limit.STATES),
        "upgrade": {"plan": up, "name": plans.PLANS[up]["name"], "price_cents": plans.PLANS[up]["price_cents"],
                    "currency": plans.PLANS[up]["currency"], "period": plans.PLANS[up]["period"]},
        "rule_cases": rule_cases,
        "client_cases": client_cases,
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
