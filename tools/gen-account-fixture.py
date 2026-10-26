"""Erzeugt packages/shared-contracts/fixtures/account/contract.json: Vertrag G1 (UniFlow-Konto) aus der Python-Referenz.

Inhalt: Regeln (Passwortlaenge, Sitzungsdauer, Sperre), Pruef-Faelle fuer E-Mail und Passwort, alle Endpunkte mit
Beispiel-Anfrage und -Antwort (aufgezeichnet gegen den echten Server im gehosteten Modus, Tokens/IDs/Zeiten durch
Platzhalter ersetzt) und die Fehlercodes. Der Swift- und der Kotlin-Client bauen ihre Aufrufe und Modelle danach.
Aufruf im Projektordner: python tools/gen-account-fixture.py [--check]
"""
from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "account" / "contract.json"


def _setup_env() -> None:
    tmp = tempfile.mkdtemp(prefix="uniflow-account-fixture-")
    os.environ["LERNAPP_DATA_DIR"] = str(Path(tmp) / "data")
    os.environ["LERNAPP_LOG_DIR"] = str(Path(tmp) / "logs")
    os.environ["LERNAPP_ALLOWED_HOSTS"] = "test"
    sys.path.insert(0, str(ROOT))
    sys.path.insert(0, str(ROOT / "tests"))


_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{40,50}$")
_HEX32_RE = re.compile(r"^[a-f0-9]{32}$")
_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})?$")


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
        if x.startswith("deleted-") and x.endswith("@invalid"):
            return "deleted-<user-id>@invalid"
    return x


def build() -> dict:
    """Setzt den gehosteten Modus im Prozess (Konto-Datenbank im Temp-Ordner) und zeichnet die Ablaeufe auf."""
    from conftest import asgi_call
    from app import account_api, accounts, config
    from app.server import app
    config.MODE = "hosted"
    accounts.db_path().unlink(missing_ok=True)
    accounts.identity_verifiers.clear()
    accounts.identity_verifiers["apple"] = lambda t: {"subject": "apple-subject-1", "email": "relay@privaterelay.appleid.com"} if t == "<apple-identity-token>" else None
    flows: list[dict] = []

    def call(step, method, path, body=None, token=None, cookies=None):
        headers = {"Authorization": f"Bearer {token}"} if token else None
        st, hdrs, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None, headers=headers, cookies=cookies)
        data = json.loads(raw) if raw else None
        entry = {"step": step, "method": method, "path": path, "auth": bool(token) or bool(cookies), "request": body,
                 "status": st, "response": scrub(data)}
        cookie = [v.decode() for k, v in hdrs if k == b"set-cookie"]
        if cookie:
            c = re.sub(r"=[^;]+", "=<token>", cookie[0], count=1)
            entry["set_cookie"] = re.sub(r"expires=[^;]+", "expires=<datum>", c)
        flows.append(entry)
        return st, data

    pw, pw2 = "sehr-geheim-123", "noch-geheimer-456"
    st, reg = call("Konto anlegen", "POST", "/api/account/register", {"email": "Erika@Beispiel.de", "password": pw, "university": "hildesheim", "device_id": "ipad-1", "device_name": "iPad"})
    token = reg["token"]
    call("Konto anlegen: Adresse schon vergeben", "POST", "/api/account/register", {"email": "erika@beispiel.de", "password": pw, "university": "luh"})
    call("Konto anlegen: Passwort zu kurz", "POST", "/api/account/register", {"email": "neu@beispiel.de", "password": "kurz", "university": "luh"})
    call("Konto anlegen: Hochschule unbekannt", "POST", "/api/account/register", {"email": "neu@beispiel.de", "password": pw, "university": "tum"})
    call("Oeffentliche Info", "GET", "/api/account/info")
    call("Wer bin ich", "GET", "/api/account/me", token=token)
    call("Ohne Sitzung", "GET", "/api/account/me")
    call("Daten-Endpunkt ohne Sitzung", "GET", "/api/modules")
    call("Daten-Endpunkt mit Sitzung (leere Datenbank des Kontos)", "GET", "/api/modules", token=token)
    call("Im Dienst nicht verfuegbar (KI bis zum KI-Update)", "POST", "/api/ai/tutor", {"mode": "explain"}, token=token)
    call("Abgleich ohne hinterlegte Hochschul-Zugangsdaten", "POST", "/api/sync", token=token)
    st, login2 = call("Anmelden auf zweitem Geraet", "POST", "/api/account/login", {"email": "erika@beispiel.de", "password": pw, "device_id": "mac-1", "device_name": "MacBook"})
    call("Anmelden: falsches Passwort", "POST", "/api/account/login", {"email": "erika@beispiel.de", "password": "falsch"})
    call("Sitzungen des Kontos", "GET", "/api/account/me", token=login2["token"])
    call("Andere Sitzungen beenden", "POST", "/api/account/logout-all", token=login2["token"])
    call("Beendete Sitzung", "GET", "/api/account/me", token=token)
    call("Passwort aendern", "POST", "/api/account/password", {"old_password": pw, "new_password": pw2}, token=login2["token"])
    call("Passwort aendern: altes falsch", "POST", "/api/account/password", {"old_password": "falsch", "new_password": pw2}, token=login2["token"])
    call("Reset anfordern (Antwort immer gleich)", "POST", "/api/account/password/reset-request", {"email": "erika@beispiel.de"})
    call("Reset anfordern: unbekannte Adresse", "POST", "/api/account/password/reset-request", {"email": "niemand@beispiel.de"})
    call("Reset mit ungueltigem Token", "POST", "/api/account/password/reset", {"token": "abgelaufen", "new_password": pw2})
    call("Hochschule wechseln", "POST", "/api/account/university", {"university": "luh"}, token=login2["token"])
    call("Hochschule ueber Einstellungen (nicht erlaubt)", "PUT", "/api/settings", {"university": "hildesheim"}, token=login2["token"])
    call("Apple verknuepfen", "POST", "/api/account/link/apple", {"identity_token": "<apple-identity-token>"}, token=login2["token"])
    call("Apple verknuepfen: Token ungueltig", "POST", "/api/account/link/apple", {"identity_token": "kaputt"}, token=login2["token"])
    call("Google verknuepfen: Anbieter nicht eingerichtet", "POST", "/api/account/link/google", {"identity_token": "x"}, token=login2["token"])
    call("Anmelden mit Apple (bekannte Kennung)", "POST", "/api/account/login/apple", {"identity_token": "<apple-identity-token>", "device_id": "ipad-1"})
    call("Abmelden", "POST", "/api/account/logout", token=login2["token"])
    st, login3 = call("Anmelden mit neuem Passwort", "POST", "/api/account/login", {"email": "erika@beispiel.de", "password": pw2})
    call("Konto loeschen: Passwort fehlt", "POST", "/api/account/delete", {}, token=login3["token"])
    call("Konto loeschen", "POST", "/api/account/delete", {"password": pw2}, token=login3["token"])
    call("Nach dem Loeschen", "GET", "/api/account/me", token=login3["token"])
    for i in range(accounts.MAX_FAILS):
        asgi_call(app, "POST", "/api/account/login", body=json.dumps({"email": "sperre@beispiel.de", "password": "falsch"}))
    call("Nach 8 Fehlversuchen gesperrt", "POST", "/api/account/login", {"email": "sperre@beispiel.de", "password": "egal"})

    errors = {}
    for f in flows:
        r = f["response"]
        if isinstance(r, dict) and r.get("code"):
            errors.setdefault(r["code"], {"status": f["status"], "message": r["detail"]})
    errors["not_hosted"] = {"status": 501, "message": "Konten gibt es nur im gehosteten Dienst (LERNAPP_MODE=hosted)."}

    email_cases = []
    for e in ("A.B@Example.DE ", "kein-at", "a@b", "", "x@y.de", "ä@umlaut.de"):
        n = accounts.normalize_email(e)
        try:
            accounts.validate_email(n)
            email_cases.append({"input": e, "normalized": n, "valid": True})
        except accounts.AccountError as x:
            email_cases.append({"input": e, "normalized": n, "valid": False, "code": x.code})
    password_cases = []
    for pwc, em in (("kurz", ""), ("x" * 201, ""), ("max@beispiel.de", "max@beispiel.de"), ("zehnzeichen", ""), ("  mit leerzeichen ", "")):
        try:
            accounts.validate_password(pwc, em)
            password_cases.append({"password": pwc, "email": em, "code": None})
        except accounts.AccountError as x:
            password_cases.append({"password": pwc, "email": em, "code": x.code})

    endpoints = []
    for r in account_api.router.routes:
        for m in sorted(r.methods - {"HEAD", "OPTIONS"}):
            endpoints.append({"method": m, "path": r.path, "public": r.path in account_api.PUBLIC_PATHS, "summary": (r.endpoint.__doc__ or "").strip().split("\n")[0]})
    endpoints.sort(key=lambda e: (e["path"], e["method"]))
    config.MODE = "local"
    accounts.db_path().unlink(missing_ok=True)
    return {
        "_hinweis": "Erzeugt mit tools/gen-account-fixture.py aus der Python-Referenz (app/accounts.py, app/account_api.py); nicht von Hand aendern.",
        "rules": {"password_min": accounts.PASSWORD_MIN, "password_max": accounts.PASSWORD_MAX, "session_days": accounts.SESSION_DAYS,
                  "reset_minutes": accounts.RESET_MINUTES, "max_fails": accounts.MAX_FAILS, "lock_minutes": accounts.LOCK_MINUTES,
                  "email_regex": accounts.EMAIL_RE.pattern, "universities": list(config.KNOWN_UNIVERSITIES),
                  "auth": "Authorization: Bearer <token> (Apps) oder Cookie uniflow_session (Browser)",
                  "error_shape": {"detail": "<Meldung fuer den Nutzer>", "code": "<stabiler Code>"},
                  "identity": "Apple/Google sind Anmeldewege zum UniFlow-Konto; Verknuepfung ueber die Anbieter-Kennung (subject), nie ueber die E-Mail"},
        "email-cases": email_cases,
        "password-cases": password_cases,
        "endpoints": endpoints,
        "errors": dict(sorted(errors.items())),
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
