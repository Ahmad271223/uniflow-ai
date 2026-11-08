"""Windows-App mit Konto-Pflicht (Entscheidung des Inhabers vom 05.11.2026, app/access.py).

Bis 0.5 war die Windows-App ein Einzelplatz ohne Konto und ohne Tarif ("Eigener PC", alles frei). Jetzt gilt: ohne
Anmeldung mit dem StudiNow-Konto nur der Anmeldebildschirm; ohne aktives Abo (nach der 7-Tage-Probe) nur die
Abo-Seite und die eigenen Daten zum Ansehen und Exportieren. Die Daten bleiben auf dem PC und werden nie geloescht.

Gilt, wenn der lokale Server in der Windows-App laeuft (`LERNAPP_DESKTOP=1`, app/desktop.py) oder ausdruecklich mit
`LERNAPP_ACCOUNT_REQUIRED=1` (z. B. zum Ausprobieren im Browser). `serve.py` ohne diese Schalter (Entwicklung, Tests)
bleibt der alte Einzelplatz.

Anmelden (Dienst: `LERNAPP_SERVICE_URL`, sonst https://app.studinow.app, app/service_link.py):
- E-Mail und Passwort: einmal ueber den lokalen Server an `/api/account/login` (wie bisher service_link.login);
  gespeichert wird nur das Sitzungs-Token.
- "Mit Apple anmelden", "Mit Google anmelden", "Konto anlegen": im Systembrowser (nicht im App-Fenster: Google sperrt
  eingebettete Browser, und Passwort-Manager und Apple-ID funktionieren dort am besten). Ablauf wie OAuth fuer native
  Apps (RFC 8252, Loopback-Rueckleitung mit PKCE S256): `start_browser_login` oeffnet `{dienst}/login?app=windows&
  redirect_uri=http://127.0.0.1:<port>/konto/rueckkehr&state=..&code_challenge=..`; die Anmeldeseite des Dienstes
  meldet an (Passwort, Apple, Google - alles, was sie kann), holt mit der Browser-Sitzung einen Einmal-Code
  (`POST /api/app-login/code`, 2 Minuten gueltig, an Challenge und Rueckleitung gebunden) und leitet auf den lokalen
  Server zurueck. `complete_browser_login` prueft `state` und tauscht den Code mit dem Verifier gegen ein eigenes
  Sitzungs-Token des Geraets "StudiNow für Windows" (`POST /api/app-login/token`).
- Das Token liegt in der Windows-Anmeldeinformationsverwaltung (app/token_store.py).

Abo (Rechte aus dem Dienst, Quelle "account"): `refresh` holt `GET /api/entitlements` mit `X-StudiNow-Client:
windows` und legt die Antwort mit Zeitpunkt in `account-cache.json` ab. Die Sperre richtet sich nach diesem Stand
(`evaluate`); ohne Netz gilt er hoechstens `LERNAPP_OFFLINE_GRACE_DAYS` Tage (Standard 7) ab dem letzten Abruf, eine
laufende Probe hoechstens bis zu ihrem Ende. Laeuft die Uhr mehr als einen Tag rueckwaerts, gilt der Stand als
ungeprueft. Danach: nur lesen, bis der PC wieder online ist. Ein Apple-Abo vom iPad gilt automatisch (der Dienst kennt
es am Konto); Credits der StudiNow-KI zaehlt allein der Dienst, fuer alle Geraete gemeinsam.

Kaufen: `checkout` laesst den Dienst eine Stripe-Checkout-Sitzung anlegen (mit dem Token der App, ohne zweite
Anmeldung im Browser) und oeffnet sie im Systembrowser; danach fragt die Oberflaeche den Stand neu ab. Hat das Konto
ein Apple-Abo, gibt es keinen zweiten Kauf (hier und im Dienst, app/stripe_billing.py). Kuendigen und Wechseln:
Stripe-Kundenportal (`portal`).

Grenze: Die Sperre am PC ist eine Sperre der Oberflaeche und des lokalen Servers, keine Kopierschutz-Technik. Was
Geld kostet oder geteilt wird (StudiNow-KI mit Credits, Community, Geraete-Abgleich, Bibliothek), prueft der Dienst
selbst je Anfrage.
"""
from __future__ import annotations

import base64
import hashlib
import html
import json
import os
import re
import secrets
import sqlite3
import tempfile
import threading
import time
import urllib.parse
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from . import access, config, plans, service_link, token_store

CACHE_FILE = "account-cache.json"
DEFAULT_GRACE_DAYS = 7
CALLBACK_PATH = "/konto/rueckkehr"
FLOW_TTL_S = 600
MAX_FLOWS = 5
CLOCK_SKEW_S = 86400
# Pfade unter /api, die in jedem Zustand gehen (Anmelden, Stand, Abo-Seite, Fenster der Windows-App)
ALWAYS_OPEN = ("/api/app-account/", "/api/desktop", "/api/account/info", "/api/billing/plans", "/api/entitlements")
# zusaetzlich zu access.LOCKED_WRITE_PREFIXES: schreiben trotz fehlendem Abo (Abmelden)
# Hochschul-Konto entfernen (PC weitergeben, app/reset.py) geht auch ohne Abo: Loeschen haengt nie am Tarif
LOCKED_WRITE_EXTRA = ("/api/app-account/", "/api/desktop/", "/api/studora/logout", "/api/university/reset")
_LOOPBACK_REDIRECT = re.compile(r"^http://(127\.0\.0\.1|localhost|\[::1\]):(\d{1,5})" + re.escape(CALLBACK_PATH) + r"$")


class AccountModeError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


# ---------------------------------------------------------------- Schalter und Einstellungen

def required() -> bool:
    """Konto-Pflicht am eigenen PC: Windows-App (LERNAPP_DESKTOP=1) oder LERNAPP_ACCOUNT_REQUIRED=1; nie im Dienst."""
    if config.is_hosted():
        return False
    return os.environ.get("LERNAPP_DESKTOP") == "1" or os.environ.get("LERNAPP_ACCOUNT_REQUIRED") == "1"


def grace_days() -> int:
    """Kulanzzeit ohne Netz in Tagen (LERNAPP_OFFLINE_GRACE_DAYS, 0 bis 60, Standard 7)."""
    try:
        v = int(os.environ.get("LERNAPP_OFFLINE_GRACE_DAYS") or DEFAULT_GRACE_DAYS)
    except ValueError:
        v = DEFAULT_GRACE_DAYS
    return max(0, min(60, v))


# ---------------------------------------------------------------- Zwischenspeicher des Abo-Stands

_cache_mem: dict = {"mtime": None, "data": None}
_cache_lock = threading.Lock()
_last: dict = {"error": None, "offline": False, "at": None}


def cache_path() -> Path:
    return config.DATA_DIR / CACHE_FILE


def load_cache() -> dict | None:
    p = cache_path()
    try:
        mtime = p.stat().st_mtime_ns
    except OSError:
        return None
    with _cache_lock:
        if _cache_mem["mtime"] == mtime:
            return _cache_mem["data"]
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        d = None
    d = d if isinstance(d, dict) and isinstance(d.get("entitlements"), dict) else None
    with _cache_lock:
        _cache_mem.update(mtime=mtime, data=d)
    return d


def save_cache(entitlements: dict, user: dict | None, now: float | None = None) -> dict:
    keep = ("plan", "plan_name", "source", "expires_at", "will_renew", "pending_plan", "quotas", "trial", "paid_plan",
            "subscriptions", "credits", "purchase", "access")
    d = {"fetched_at": float(now if now is not None else time.time()),
         "user": {k: (user or {}).get(k) for k in ("id", "email", "email_verified", "university", "role")},
         "entitlements": {k: entitlements.get(k) for k in keep if k in entitlements}}
    p = cache_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, p)
    with _cache_lock:
        _cache_mem.update(mtime=None, data=None)
    return d


def clear_cache() -> None:
    cache_path().unlink(missing_ok=True)
    with _cache_lock:
        _cache_mem.update(mtime=None, data=None)


# ---------------------------------------------------------------- Zustand (reine Rechnung, Uhr von aussen)

def evaluate(has_token: bool, cache: dict | None, now: float, grace: int) -> dict:
    """Zustand der Sperre am PC: signed_out | unverified | trial | active | subscription_required (siehe app/access.py)."""
    if not has_token:
        return {"state": "signed_out", "locked": True, "signed_in": False, "plan": None, "message": access.MESSAGES["signed_out"],
                "trial_days_left": None, "cache_age_s": None}
    if not cache:
        return {"state": "unverified", "locked": True, "signed_in": True, "plan": None, "trial_days_left": None,
                "cache_age_s": None, "message": access.MESSAGES["unverified"].format(days=grace)}
    age = now - float(cache.get("fetched_at") or 0)
    if age < -CLOCK_SKEW_S or age > grace * 86400:
        return {"state": "unverified", "locked": True, "signed_in": True, "plan": None, "trial_days_left": None,
                "cache_age_s": int(age), "message": access.MESSAGES["unverified"].format(days=grace)}
    ent = cache.get("entitlements") or {}
    user = cache.get("user") or {}
    plan = ent.get("plan") if ent.get("plan") in plans.PLANS else "free"
    source = access.source_kind(plan, ent.get("paid_plan")) if "paid_plan" in ent else ("trial" if ent.get("source") == "trial" else (None if plan == "free" else "paid"))
    a = access.evaluate(plan, source, ent.get("trial"), "windows", user.get("role"), datetime.fromtimestamp(now, timezone.utc))
    return {"state": a["state"], "locked": a["locked"], "signed_in": True, "plan": plan if not a["locked"] else "free",
            "trial_days_left": a["trial_days_left"], "trial_ends_at": a["trial_ends_at"], "cache_age_s": int(age),
            "message": a["message"]}


def state() -> dict:
    """Zustand jetzt, aus Token und Zwischenspeicher (ohne Netz)."""
    return evaluate(bool(token_store.get()), load_cache(), time.time(), grace_days())


def locked() -> bool:
    return required() and state()["locked"]


def effective_plan() -> str:
    """Tarif, nach dem die Rechte am PC gelten: der Tarif des Kontos, solange nicht gesperrt; sonst free."""
    s = state()
    return s["plan"] if not s["locked"] and s["plan"] in plans.PLANS else "free"


def info() -> dict:
    """Stand fuer die Oberflaeche (GET /api/app-account/status)."""
    s = state()
    cache = load_cache() or {}
    ent = cache.get("entitlements") or {}
    subs = ent.get("subscriptions") or {}
    st = service_link.load_state()
    return {**s, "required": required(), "service_url": service_link.service_url(st),
            "user": (cache.get("user") or service_link._public_user(st.get("user"))) if s["signed_in"] else None,
            "last_email": st.get("last_email") or (st.get("user") or {}).get("email"),
            "plan_name": plans.PLANS.get(s["plan"] or "free", plans.PLANS["free"])["name"],
            "source": ent.get("source"), "expires_at": ent.get("expires_at"), "will_renew": ent.get("will_renew"),
            "apple_subscription": bool(subs.get("app_store")), "stripe_subscription": bool(subs.get("stripe")),
            "fetched_at": cache.get("fetched_at"), "grace_days": grace_days(), "offline": _last["offline"],
            "last_error": _last["error"], "token_store": token_store.kind(),
            "purchase_note": APPLE_NOTE if subs.get("app_store") else None}


APPLE_NOTE = "Du hast schon ein Abo über Apple – verwalten in den Einstellungen deines iPads/iPhones."


def entitlements_status() -> dict:
    """GET /api/entitlements am PC mit Konto-Pflicht: Form wie billing.status, Quelle "account" (mode)."""
    from . import billing
    s = info()
    plan = effective_plan()
    cache = load_cache() or {}
    ent = cache.get("entitlements") or {}
    rights = plans.entitlements(plan)
    rights["chatgpt_connection_premium"] = False if plans.INTEGRATIONS["chatgpt"]["status"] != "enabled" else rights["chatgpt_connection_premium"]
    quotas = ent.get("quotas") or {f: {"used": 0, "limit": plans.quota_limit(plan, f), "unlimited": plans.QUOTAS[plan].get(f) is None,
                                        "period": billing.period_of()} for f in plans.QUOTA_LABELS}
    return {"plan": plan, "plan_name": plans.PLANS[plan]["name"], "source": ent.get("source") if not s["locked"] else None,
            "expires_at": ent.get("expires_at"), "will_renew": bool(ent.get("will_renew")), "pending_plan": ent.get("pending_plan"),
            "entitlements": rights, "quotas": quotas, "integrations": plans.contract()["integrations"], "mode": "account",
            "trial": ent.get("trial") or {"granted": False, "active": False, "ends_at": None, "days_left": 0, "expired": False, "plan": None},
            "plan_choice": None, "needs_plan_choice": False, "paid_plan": ent.get("paid_plan"),
            "subscriptions": ent.get("subscriptions") or {"app_store": False, "stripe": False}, "credits": ent.get("credits"),
            "access": {"client": "windows", "account_required": True, "state": s["state"], "locked": s["locked"],
                       "read_only": s["locked"], "trial_days_left": s.get("trial_days_left"),
                       "trial_ends_at": s.get("trial_ends_at"), "message": s.get("message")},
            "account": s}


def cached_purchase() -> dict | None:
    return ((load_cache() or {}).get("entitlements") or {}).get("purchase")


# ---------------------------------------------------------------- Abruf beim Dienst

def refresh() -> dict:
    """Abo-Stand beim Dienst holen und ablegen. Ohne Netz bleibt der letzte Stand (Kulanzzeit). Liefert `info()`."""
    st = service_link.load_state()
    if not st.get("token"):
        return info()
    try:
        status, _, data = service_link.call("GET", "/api/entitlements", st=st)
    except service_link.LinkError as e:
        _last.update(error=e.message, offline=True, at=time.time())
        return info()
    if status == 401:
        # Sitzung abgelaufen oder widerrufen: service_link.call hat das Token schon vergessen
        clear_cache()
        _last.update(error="Deine Anmeldung ist abgelaufen. Bitte melde dich neu an.", offline=False, at=time.time())
        return info()
    if status != 200:
        _last.update(error=f"Der StudiNow-Dienst antwortet mit Fehler {status}.", offline=True, at=time.time())
        return info()
    try:
        ent = json.loads(data or b"{}")
    except ValueError:
        ent = {}
    if not isinstance(ent, dict) or ent.get("plan") is None:
        _last.update(error="Unerwartete Antwort des Dienstes.", offline=True, at=time.time())
        return info()
    user = st.get("user") or {}
    try:
        s2, _, me = service_link.call("GET", "/api/account/me", st=st)
        if s2 == 200:
            u = json.loads(me or b"{}").get("user")
            if isinstance(u, dict):
                user = u
                st["user"] = u
                service_link.save_state(st)
    except (service_link.LinkError, ValueError):
        pass
    save_cache(ent, user)
    _last.update(error=None, offline=False, at=time.time())
    return info()


# ---------------------------------------------------------------- Anmelden und Abmelden

def run_later(fn) -> None:
    """Nach dem Anmelden im Hintergrund: eigene Hochschul-PDFs melden (kann bei vielen Dateien dauern). Tests
    tauschen das gegen einen direkten Aufruf."""
    threading.Thread(target=fn, name="studora-claims", daemon=True).start()


def login_password(email: str, password: str) -> dict:
    try:
        service_link.login(None, email, password)
    except service_link.LinkError as e:
        raise AccountModeError(e.code, e.message, e.status)
    clear_cache()
    out = refresh()
    run_later(service_link.claim_quietly)
    return out


def logout() -> dict:
    service_link.logout()
    clear_cache()
    _last.update(error=None, offline=False)
    return info()


def _b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


_flows: dict[str, dict] = {}
_flows_lock = threading.Lock()


def open_url(url: str) -> bool:
    """Im Systembrowser oeffnen (nie als Fenster der App): Anmeldung bei Apple/Google und Bezahlseiten gehoeren in den
    echten Browser mit Adresszeile."""
    import webbrowser
    return bool(webbrowser.open(url, new=2))


def start_browser_login(local_base: str, mode: str = "login", provider: str | None = None, open_browser: bool = True) -> dict:
    """Anmeldung im Systembrowser beginnen. `local_base` = Adresse dieses Servers (http://127.0.0.1:<port>)."""
    redirect = local_base.rstrip("/") + CALLBACK_PATH
    if not _LOOPBACK_REDIRECT.match(redirect):
        raise AccountModeError("not_loopback", "Die Anmeldung im Browser geht nur auf diesem PC.", 400)
    base = service_link.service_url()
    try:
        service_link.normalize_url(base)
    except service_link.LinkError as e:
        raise AccountModeError(e.code, e.message, e.status)
    verifier = _b64url(secrets.token_bytes(48))
    challenge = _b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    flow_state = secrets.token_urlsafe(24)
    with _flows_lock:
        now = time.time()
        for k in [k for k, v in _flows.items() if now - v["created"] > FLOW_TTL_S]:
            _flows.pop(k, None)
        while len(_flows) >= MAX_FLOWS:
            _flows.pop(min(_flows, key=lambda k: _flows[k]["created"]))
        _flows[flow_state] = {"verifier": verifier, "redirect_uri": redirect, "created": now, "base": base}
    q = {"app": "windows", "redirect_uri": redirect, "state": flow_state, "code_challenge": challenge}
    if mode in ("login", "register", "forgot"):
        q["tab"] = mode
    if provider in ("apple", "google"):
        q["provider"] = provider
    url = base + "/login?" + urllib.parse.urlencode(q)
    if open_browser:
        open_url(url)
    return {"url": url, "redirect_uri": redirect, "expires_in": FLOW_TTL_S}


def complete_browser_login(query: dict) -> tuple[int, str]:
    """Rueckleitung aus dem Browser: (HTTP-Status, HTML-Seite). Tauscht den Code gegen das Token des Geraets."""
    flow_state = str(query.get("state") or "")
    with _flows_lock:
        flow = _flows.pop(flow_state, None) if flow_state else None
    if not flow or time.time() - flow["created"] > FLOW_TTL_S:
        return 400, page("Diese Anmeldung ist abgelaufen oder gehört nicht zu dieser App. Bitte in StudiNow erneut "
                         "„Im Browser anmelden“ wählen.", False)
    if query.get("error"):
        return 400, page("Die Anmeldung wurde abgebrochen. Du kannst es in StudiNow erneut versuchen.", False)
    code = str(query.get("code") or "")
    if not code or len(code) > 200:
        return 400, page("Die Rückmeldung des StudiNow-Dienstes war unvollständig. Bitte erneut anmelden.", False)
    st = service_link.load_state()
    body = json.dumps({"code": code, "code_verifier": flow["verifier"], "redirect_uri": flow["redirect_uri"],
                       "device_id": service_link._device_id(st), "device_name": service_link.DEVICE_NAME}).encode()
    try:
        status, _, data = service_link.call("POST", "/api/app-login/token", body, st=st, url=flow["base"], token="")
    except service_link.LinkError as e:
        return 502, page(e.message, False)
    try:
        d = json.loads(data or b"{}")
    except ValueError:
        d = {}
    if status != 200 or not d.get("token") or not isinstance(d.get("user"), dict):
        msg = d.get("detail") if isinstance(d.get("detail"), str) else "Die Anmeldung konnte nicht abgeschlossen werden."
        return 400, page(msg, False)
    st.update({"url": flow["base"], "token": d["token"], "user": d["user"], "linked_at": int(time.time())})
    st.pop("expired_at", None)
    service_link.save_state(st)
    clear_cache()
    refresh()
    run_later(service_link.claim_quietly)
    return 200, page(f"Du bist als {d['user'].get('email') or 'StudiNow-Nutzer'} angemeldet. Du kannst dieses Fenster "
                     "schließen und zu StudiNow zurückkehren.", True)


def page(text: str, ok: bool) -> str:
    color = "#1a7f37" if ok else "#b42318"
    title = "Angemeldet" if ok else "Nicht angemeldet"
    return ("<!doctype html><html lang=\"de\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, "
            "initial-scale=1\"><title>StudiNow – Anmeldung</title></head><body style=\"font-family:system-ui,sans-serif;"
            "max-width:32rem;margin:4rem auto;padding:0 1rem;color:#171a26\">"
            f"<h1 style=\"color:{color};font-size:1.3rem\">{title}</h1><p>{html.escape(text)}</p></body></html>")


# ---------------------------------------------------------------- Abo abschliessen und verwalten

def _service_json(method: str, path: str, body: dict | None = None) -> dict:
    st = service_link.load_state()
    if not st.get("token"):
        raise AccountModeError("account_required", access.MESSAGES["signed_out"], 401)
    try:
        status, _, data = service_link.call(method, path, json.dumps(body or {}).encode(), st=st)
    except service_link.LinkError as e:
        raise AccountModeError(e.code, e.message, e.status)
    try:
        d = json.loads(data or b"{}")
    except ValueError:
        d = {}
    if status >= 400:
        code, msg = service_link._detail(data, "Der StudiNow-Dienst hat die Anfrage abgelehnt.")
        raise AccountModeError(code, msg, status if status < 500 else 502)
    return d if isinstance(d, dict) else {}


def checkout(plan: str, open_browser: bool = True, interval: str = "month") -> dict:
    """Stripe-Checkout im Systembrowser, monatlich oder jaehrlich (`interval`, 08.11.2026). Mit Apple-Abo am Konto:
    kein zweiter Kauf (409 apple_subscription_active)."""
    if not plans.is_sellable(plan):
        raise AccountModeError("plan_invalid", "Bitte StudiNow Plus oder StudiNow Pro AI wählen.", 400)
    if interval not in ("month", "year"):
        raise AccountModeError("interval_invalid", "Zahlungszeitraum: month oder year.", 400)
    subs = ((load_cache() or {}).get("entitlements") or {}).get("subscriptions") or {}
    if subs.get("app_store"):
        raise AccountModeError("apple_subscription_active", APPLE_NOTE, 409)
    d = _service_json("POST", "/api/billing/stripe/checkout", {"plan": plan, "client": "windows", "interval": interval})
    url = d.get("url")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise AccountModeError("stripe_error", "Der Dienst hat keine Bezahlseite geliefert.", 502)
    if open_browser:
        open_url(url)
    return {"opened": open_browser, "url": url, "plan": plan, "interval": interval}


def portal(open_browser: bool = True) -> dict:
    d = _service_json("POST", "/api/billing/stripe/portal", {"client": "windows"})
    url = d.get("url")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise AccountModeError("stripe_error", "Der Dienst hat keine Adresse fürs Kundenportal geliefert.", 502)
    if open_browser:
        open_url(url)
    return {"opened": open_browser, "url": url}


# ---------------------------------------------------------------- Eigene Daten exportieren (auch ohne Abo)

EXPORT_README = """StudiNow für Windows – Export deiner Daten auf diesem PC

Erstellt: {at}
Konto: {email}

daten/lernapp.db    Deine Daten auf diesem PC als SQLite-Datenbank (öffnen z. B. mit „DB Browser for SQLite“):
                    Kurse, Module, Notizen (Tabelle annotations), Stundenplan, Lernkalender, Aufgaben, Karteikarten,
                    Tests und Noten.
daten/assets/       Bilder und Aufnahmen aus deinen Notizen.
eigene-dateien/     Dokumente, die du selbst hinzugefügt hast.

Dateien deiner Hochschule (Stud.IP, Learnweb) sind nicht im Export; sie liegen weiter im Datenordner der App und in
Stud.IP bzw. im Learnweb. Hochschul-Zugangsdaten, Sitzungen und Schlüssel sind aus Sicherheitsgründen nicht enthalten.
Die Daten deines StudiNow-Kontos im Dienst exportierst du auf app.studinow.app unter Konto → „Meine Daten exportieren“.
"""


def _add_db(z: zipfile.ZipFile, src: Path, arc: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        dst = Path(tmp) / "kopie.db"
        a = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
        b = sqlite3.connect(dst)
        try:
            a.backup(b)
        finally:
            b.close()
            a.close()
        z.write(dst, arc)


def export_zip() -> Path:
    """ZIP mit den eigenen Daten dieses PCs; der Aufrufer loescht die Datei nach dem Senden."""
    from . import db
    fd, name = tempfile.mkstemp(prefix="studinow-export-", suffix=".zip")
    os.close(fd)
    path = Path(name)
    user = ((load_cache() or {}).get("user") or {}).get("email") or (service_link.load_state().get("user") or {}).get("email") or "-"
    at = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=True) as z:
        z.writestr("LIESMICH.txt", EXPORT_README.format(at=at, email=user))
        dbp = config.db_path()
        if dbp.is_file():
            _add_db(z, dbp, "daten/lernapp.db")
        assets = config.DATA_DIR / "assets"
        if assets.is_dir():
            for p in sorted(assets.rglob("*")):
                if p.is_file():
                    z.write(p, "daten/assets/" + p.relative_to(assets).as_posix())
        seen: set[str] = set()
        with db.cursor() as conn:
            rows = db.rows(conn, "SELECT id, name, local_path FROM files WHERE course_id='__user__' AND deleted_at IS NULL ORDER BY id")
        for r in rows:
            lp = r.get("local_path")
            if not lp or not Path(lp).is_file():
                continue
            safe = re.sub(r"[^\w.\- ]+", "_", r.get("name") or Path(lp).name).strip() or "datei"
            arc = f"eigene-dateien/{safe}"
            if arc in seen:
                arc = f"eigene-dateien/{r['id']}-{safe}"
            seen.add(arc)
            z.write(lp, arc)
    return path
