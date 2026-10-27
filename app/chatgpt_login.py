"""Sign in with ChatGPT fuer den eigenen PC (Einzelplatz, Windows-App): OAuth 2.0 mit PKCE und Loopback-Rueckleitung.

Der Nutzer meldet sich im Browser bei OpenAI an und erlaubt UniFlow, sein ChatGPT-Abo fuer KI-Anfragen zu nutzen
(Scope `chatgpt.tokens.use.direct`). UniFlow bekommt nur Tokens und Name/E-Mail aus dem ID-Token, nie ein Passwort,
nie Cookies, nie Zugriff auf die ChatGPT-Unterhaltungen. Alles liegt in `chatgpt-auth.json` im Datenordner dieses
Rechners (0600). Im gehosteten Dienst ist der Ablauf aus, bis OpenAI Studora freigibt (docs/KI-CHATGPT-PLAN.md).

Ablauf (developers.openai.com/siwc/token-sharing-open-source/sign-in):
1. `start()` bindet einen freien Port auf 127.0.0.1, baut die Autorisierungsadresse (beim ersten Mal
   `client_id=dynamic_agent_client` mit `agent_name_hint`, danach die ausgestellte `oaiapp_…`-ID) und oeffnet den Browser.
2. Die Rueckleitung `/auth/callback` bringt `code`, `state` und bei der Erstregistrierung die ausgestellte `client_id`;
   die wird gespeichert, BEVOR der Code getauscht wird (ein zweiter Versuch nutzt sie wieder).
3. Tausch am Token-Endpunkt (form-encoded, ohne Secret), ID-Token gegen JWKS, Aussteller, Audience und Nonce pruefen,
   Zugangsdaten speichern. Erneuerung 60 s vor Ablauf; das Refresh-Token rotiert und wird mit ersetzt.
4. KI-Anfragen gehen mit dem Zugriffstoken an die Responses API (app/ai_backend.ChatGPTProvider).
"""
from __future__ import annotations

import base64
import hashlib
import html
import json
import os
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from . import config, social_login

AUTH_URL = "https://auth.openai.com/api/accounts/authorize"
TOKEN_URL = "https://auth.openai.com/api/accounts/oauth/token"
ISSUER = "https://auth.openai.com"
JWKS_URL = "https://auth.openai.com/.well-known/jwks.json"
RESOURCE = "https://api.openai.com/v1"
RESPONSES_URL = "https://api.openai.com/v1/responses"
MODELS_URL = "https://api.openai.com/v1/models"
USAGE_HELP_URL = "https://chatgpt.com/#settings"
SCOPE = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
USAGE_SCOPE = "chatgpt.tokens.use.direct"
FIRST_CLIENT_ID = "dynamic_agent_client"
AGENT_NAME = "UniFlow"
CALLBACK_PATH = "/auth/callback"
FLOW_TIMEOUT_S = 600
REFRESH_MARGIN_S = 60
HTTP_TIMEOUT_S = 30
MODELS_TTL_S = 600
FILE_NAME = "chatgpt-auth.json"

_lock = threading.Lock()
_flow: "Flow | None" = None
_models_cache: tuple[float, list[str]] | None = None
_jwks_cache: tuple[float, list[dict]] | None = None


class ChatGPTError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


# ---------------------------------------------------------------- Zustand

def available() -> bool:
    """Nur auf dem eigenen PC / in der Windows-App; im Dienst erst nach der Freigabe durch OpenAI."""
    return not config.is_hosted()


def _require_local() -> None:
    if not available():
        raise ChatGPTError("chatgpt_not_available", "Die ChatGPT-Verbindung gibt es im Dienst noch nicht.", 503)


def auth_path() -> Path:
    return config.data_dir() / FILE_NAME


def load() -> dict:
    p = auth_path()
    if not p.is_file():
        return {}
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (ValueError, OSError):
        return {}


def save(d: dict) -> None:
    p = auth_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1), encoding="utf-8")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, p)


def host_id(d: dict | None = None) -> str:
    """Stabile Kennung dieses Rechners (`ext_agent_host_id`), einmal erzeugt und behalten."""
    d = load() if d is None else d
    if not d.get("host_id"):
        d["host_id"] = f"urn:uuid:{uuid.uuid4()}"
        save(d)
    return d["host_id"]


def connected(d: dict | None = None) -> bool:
    d = load() if d is None else d
    c = d.get("credentials") or {}
    return bool(c.get("access_token") and c.get("refresh_token"))


def sharing(d: dict | None = None) -> bool:
    """Darf UniFlow das Abo nutzen? Nur, wenn OpenAI den Scope wirklich gewaehrt hat."""
    d = load() if d is None else d
    return USAGE_SCOPE in ((d.get("credentials") or {}).get("scopes") or [])


# ---------------------------------------------------------------- PKCE und Adressen

def pkce() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)[:96]          # 43–128 Zeichen aus [A-Za-z0-9-_]
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).decode("ascii").rstrip("=")
    return verifier, challenge


def build_auth_url(client_id: str | None, host: str, redirect_uri: str, state: str, nonce: str, challenge: str,
                   id_token_hint: str | None = None) -> str:
    """Erstregistrierung ohne eigene Client-ID (`dynamic_agent_client` + Name der App), sonst die ausgestellte ID."""
    q: list[tuple[str, str]] = [("client_id", client_id or FIRST_CLIENT_ID)]
    if not client_id:
        q.append(("agent_name_hint", AGENT_NAME))
    q += [("ext_agent_host_id", host), ("response_type", "code"), ("redirect_uri", redirect_uri), ("scope", SCOPE),
          ("resource", RESOURCE), ("state", state), ("nonce", nonce), ("code_challenge", challenge), ("code_challenge_method", "S256")]
    if client_id and id_token_hint:
        q.append(("id_token_hint", id_token_hint))
    return AUTH_URL + "?" + urllib.parse.urlencode(q)


# ---------------------------------------------------------------- HTTP (Tests tauschen diese zwei Funktionen aus)

def http_post_form(url: str, fields: dict[str, str]) -> dict:
    data = urllib.parse.urlencode(fields).encode("ascii")
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json",
                                          "User-Agent": "UniFlow/1.0"})
    return _send(req)


def http_get_json(url: str, bearer: str) -> dict:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {bearer}", "Accept": "application/json", "User-Agent": "UniFlow/1.0"})
    return _send(req)


def _send(req: urllib.request.Request) -> dict:
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as r:  # noqa: S310 - feste https-Adressen oben
            return json.loads(r.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")[:600]
        except Exception:  # noqa: BLE001
            pass
        raise ChatGPTError("chatgpt_http_error", f"OpenAI antwortete mit Fehler {e.code}: {_error_text(body)}", e.code)
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise ChatGPTError("chatgpt_unreachable", f"OpenAI ist nicht erreichbar: {e}", 502)


def _error_text(body: str) -> str:
    try:
        j = json.loads(body)
        err = j.get("error") if isinstance(j, dict) else None
        if isinstance(err, dict):
            return str(err.get("message") or err.get("code") or body)[:300]
        if isinstance(j, dict) and j.get("error_description"):
            return str(j["error_description"])[:300]
    except ValueError:
        pass
    return body[:300]


# ---------------------------------------------------------------- ID-Token pruefen

def _jwks(force: bool = False) -> list[dict]:
    global _jwks_cache
    if _jwks_cache and not force and time.monotonic() - _jwks_cache[0] < social_login.JWKS_TTL:
        return _jwks_cache[1]
    data = social_login.fetch_jwks(JWKS_URL)
    keys = data.get("keys") if isinstance(data, dict) else None
    if not isinstance(keys, list):
        raise ChatGPTError("chatgpt_token_invalid", "Die Schluesselliste von OpenAI ist unbrauchbar.", 502)
    _jwks_cache = (time.monotonic(), keys)
    return keys


def verify_id_token(token: str, client_id: str, nonce: str | None, now: float | None = None) -> dict:
    """Signatur (JWKS), Aussteller, Audience (= ausgestellte Client-ID), Ablauf und Nonce; liefert die Claims."""
    try:
        header, payload, signature, signing_input = social_login.decode_unverified(token)
        alg = header.get("alg")
        if alg not in ("RS256", "ES256"):
            raise social_login.TokenError("Algorithmus nicht erlaubt.")
        kid = header.get("kid")
        jwk = None
        for force in (False, True):
            keys = _jwks(force=force)
            jwk = next((k for k in keys if k.get("kid") == kid or (kid is None and len(keys) == 1)), None)
            if jwk:
                break
        if not jwk:
            raise social_login.TokenError("Der Signaturschluessel des Tokens ist OpenAI nicht bekannt.")
        social_login._verify_signature(jwk, alg, signing_input, signature)
        if payload.get("iss") != ISSUER:
            raise social_login.TokenError("Der Aussteller des Tokens passt nicht.")
        aud = payload.get("aud")
        auds = aud if isinstance(aud, list) else [aud]
        if client_id not in auds:
            raise social_login.TokenError("Das Token ist nicht fuer diese App ausgestellt.")
        t = time.time() if now is None else now
        exp = payload.get("exp")
        if not isinstance(exp, (int, float)) or exp + social_login.LEEWAY < t:
            raise social_login.TokenError("Das Token ist abgelaufen.")
        if not social_login._nonce_ok(nonce, payload.get("nonce")):
            raise social_login.TokenError("Die Nonce des Tokens stimmt nicht.")
    except social_login.TokenError as e:
        raise ChatGPTError("chatgpt_token_invalid", f"ID-Token abgelehnt: {e}", 400)
    return payload


# ---------------------------------------------------------------- Token tauschen und erneuern

def _credentials_from(resp: dict, previous: dict | None = None) -> dict:
    """Zugangsdaten aus einer Token-Antwort; alles zusammen ersetzen (auch das rotierte Refresh-Token)."""
    access = resp.get("access_token")
    if not isinstance(access, str) or not access:
        raise ChatGPTError("chatgpt_token_invalid", "Die Antwort von OpenAI enthaelt kein Zugriffstoken.", 502)
    try:
        expires_in = int(resp.get("expires_in") or 3600)
    except (TypeError, ValueError):
        expires_in = 3600
    scopes = [s for s in str(resp.get("scope") or "").split() if s] or list((previous or {}).get("scopes") or [])
    return {"access_token": access, "refresh_token": resp.get("refresh_token") or (previous or {}).get("refresh_token"),
            "id_token": resp.get("id_token") or (previous or {}).get("id_token"), "token_type": resp.get("token_type") or "Bearer",
            "expires_at": time.time() + expires_in, "scopes": scopes, "saved_at": time.strftime("%Y-%m-%dT%H:%M:%S")}


def exchange_code(client_id: str, code: str, verifier: str, redirect_uri: str) -> dict:
    return http_post_form(TOKEN_URL, {"grant_type": "authorization_code", "client_id": client_id, "code": code,
                                      "code_verifier": verifier, "redirect_uri": redirect_uri, "resource": RESOURCE})


def _profile_from(claims: dict) -> dict:
    return {"sub": claims.get("sub"), "email": claims.get("email"), "name": claims.get("name") or claims.get("given_name")}


def complete_login(d: dict, client_id: str, code: str, verifier: str, redirect_uri: str, nonce: str) -> dict:
    """Code tauschen, ID-Token pruefen, Zugangsdaten und Profil speichern. Liefert den gespeicherten Zustand."""
    resp = exchange_code(client_id, code, verifier, redirect_uri)
    creds = _credentials_from(resp)
    if creds.get("id_token"):
        claims = verify_id_token(creds["id_token"], client_id, nonce)
        d["profile"] = _profile_from(claims)
    d["client_id"] = client_id
    d["credentials"] = creds
    d.pop("needs_reauth", None)
    d.pop("last_error", None)
    d.setdefault("use_for_ai", True)
    save(d)
    return d


def refresh(d: dict | None = None) -> dict:
    """Zugriffstoken erneuern; scheitert es endgueltig (400/401), bleibt nur "neu anmelden"."""
    d = load() if d is None else d
    creds = d.get("credentials") or {}
    if not creds.get("refresh_token") or not d.get("client_id"):
        raise ChatGPTError("chatgpt_login_needed", "Bitte ChatGPT neu verbinden.", 401)
    try:
        resp = http_post_form(TOKEN_URL, {"grant_type": "refresh_token", "refresh_token": creds["refresh_token"],
                                          "client_id": d["client_id"], "resource": RESOURCE})
    except ChatGPTError as e:
        if e.status in (400, 401, 403):
            mark_reauth(d, f"Erneuerung abgelehnt: {e.message}")
            raise ChatGPTError("chatgpt_login_needed", "Die Anmeldung bei ChatGPT ist abgelaufen – bitte neu verbinden.", 401)
        raise
    d["credentials"] = _credentials_from(resp, creds)
    d.pop("needs_reauth", None)
    save(d)
    return d


def access_token() -> str:
    """Gueltiges Zugriffstoken (erneuert 60 s vor Ablauf)."""
    _require_local()
    with _lock:
        d = load()
        if not connected(d):
            raise ChatGPTError("chatgpt_login_needed", "ChatGPT ist nicht verbunden.", 401)
        if d.get("needs_reauth"):
            raise ChatGPTError("chatgpt_login_needed", "Die Anmeldung bei ChatGPT ist abgelaufen – bitte neu verbinden.", 401)
        if float(d["credentials"].get("expires_at") or 0) - REFRESH_MARGIN_S <= time.time():
            d = refresh(d)
        return d["credentials"]["access_token"]


def mark_reauth(d: dict | None = None, why: str = "") -> None:
    d = load() if d is None else d
    d["needs_reauth"] = True
    if why:
        d["last_error"] = why[:300]
    save(d)


def disconnect() -> None:
    """Zugangsdaten und Profil loeschen; Rechnerkennung und ausgestellte Client-ID bleiben fuer die Neuanmeldung."""
    with _lock:
        d = load()
        for k in ("credentials", "profile", "needs_reauth", "last_error"):
            d.pop(k, None)
        save(d)
    global _models_cache
    _models_cache = None


# ---------------------------------------------------------------- Anmeldeablauf mit Loopback-Server

class Flow:
    def __init__(self, port: int, client_id: str | None):
        self.port = port
        self.redirect_uri = f"http://127.0.0.1:{port}{CALLBACK_PATH}"
        self.state = secrets.token_urlsafe(32)
        self.nonce = secrets.token_urlsafe(16)
        self.verifier, self.challenge = pkce()
        self.client_id = client_id                    # None = Erstregistrierung
        self.started = time.time()
        self.done = threading.Event()
        self.ok = False
        self.error: str | None = None
        self.server: HTTPServer | None = None

    @property
    def expired(self) -> bool:
        return time.time() - self.started > FLOW_TIMEOUT_S


def handle_callback(flow: Flow, query: dict[str, str]) -> tuple[int, str]:
    """Rueckleitung auswerten (ohne Netz testbar): Status und HTML-Seite fuer den Browser."""
    if flow.done.is_set():
        return 400, _page("Diese Anmeldung ist schon abgeschlossen.", ok=False)
    if query.get("state") != flow.state:
        return 400, _page("Die Antwort gehoert nicht zu dieser Anmeldung (state). Bitte in UniFlow erneut „ChatGPT verbinden“.", ok=False)
    if query.get("error"):
        flow.error = "Anmeldung abgebrochen." if query["error"] == "access_denied" else f"OpenAI meldet: {query.get('error_description') or query['error']}"
        flow.done.set()
        return 200, _page(flow.error, ok=False)
    code = query.get("code")
    if not code:
        return 400, _page("Die Antwort enthaelt keinen Code.", ok=False)
    d = load()
    issued = query.get("client_id")
    if flow.client_id is None:
        if not issued:
            flow.error = "OpenAI hat keine Client-ID ausgestellt (Registrierung unvollstaendig)."
            flow.done.set()
            return 400, _page(flow.error, ok=False)
        d["client_id"] = issued                      # vor dem Tausch merken: ein zweiter Versuch nutzt sie wieder
        save(d)
        client_id = issued
    else:
        if issued and issued != flow.client_id:
            flow.error = "OpenAI nannte eine andere Client-ID als gespeichert – Antwort abgelehnt."
            flow.done.set()
            return 400, _page(flow.error, ok=False)
        client_id = flow.client_id
    try:
        with _lock:
            complete_login(d, client_id, code, flow.verifier, flow.redirect_uri, flow.nonce)
    except ChatGPTError as e:
        flow.error = e.message
        flow.done.set()
        return 502, _page(f"Verbindung nicht abgeschlossen: {e.message}", ok=False)
    flow.ok = True
    flow.done.set()
    return 200, _page("UniFlow ist jetzt mit deinem ChatGPT-Konto verbunden. Du kannst dieses Fenster schliessen.", ok=True)


def _page(text: str, ok: bool) -> str:
    color = "#1a7f37" if ok else "#b42318"
    return ("<!doctype html><html lang=\"de\"><head><meta charset=\"utf-8\"><title>UniFlow – ChatGPT</title></head>"
            "<body style=\"font-family:system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem\">"
            f"<h1 style=\"color:{color};font-size:1.3rem\">{'Verbunden' if ok else 'Nicht verbunden'}</h1>"
            f"<p>{html.escape(text)}</p><p style=\"color:#666\">Zurueck zu UniFlow.</p></body></html>")


def _serve(flow: Flow) -> None:
    srv = flow.server
    assert srv is not None
    srv.timeout = 1.0
    try:
        while not flow.done.is_set() and not flow.expired:
            srv.handle_request()
    finally:
        if not flow.done.is_set():
            flow.error = "Zeit abgelaufen – bitte erneut „ChatGPT verbinden“."
            flow.done.set()
        srv.server_close()


def start(open_browser: bool = True) -> dict:
    """Anmeldung beginnen: Loopback-Server, Browser oeffnen. Liefert {"auth_url", "port"}; nur ein Ablauf zugleich."""
    global _flow
    _require_local()
    with _lock:
        if _flow and not _flow.done.is_set() and not _flow.expired:
            _flow.done.set()                          # alten Ablauf beenden, der Server-Thread raeumt auf
        d = load()
        host = host_id(d)
        client_id = d.get("client_id") or None
        srv = HTTPServer(("127.0.0.1", 0), _handler_class())
        flow = Flow(srv.server_address[1], client_id)
        flow.server = srv
        srv.flow = flow                               # type: ignore[attr-defined]
        _flow = flow
        hint = (d.get("credentials") or {}).get("id_token") if client_id else None
        url = build_auth_url(client_id, host, flow.redirect_uri, flow.state, flow.nonce, flow.challenge, id_token_hint=hint)
        threading.Thread(target=_serve, args=(flow,), name="uniflow-chatgpt-login", daemon=True).start()
    if open_browser:
        import webbrowser
        webbrowser.open(url, new=2)
    return {"auth_url": url, "port": flow.port, "redirect_uri": flow.redirect_uri}


def _handler_class():
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 - http.server
            flow: Flow = self.server.flow  # type: ignore[attr-defined]
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.path != CALLBACK_PATH:
                self._reply(404, _page("Unbekannte Adresse.", ok=False))
                return
            query = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query, keep_blank_values=True).items()}
            status, page = handle_callback(flow, query)
            self._reply(status, page)

        def _reply(self, status: int, page: str) -> None:
            body = page.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):  # noqa: D401 - keine Konsolenausgabe (Codes gehoeren nicht ins Protokoll)
            return
    return Handler


def pending() -> dict | None:
    """Laufender Ablauf (fuer die Anzeige): {"port", "started"} oder None."""
    f = _flow
    if f and not f.done.is_set() and not f.expired:
        return {"port": f.port, "started": f.started}
    return None


def last_flow_error() -> str | None:
    f = _flow
    return f.error if f and f.done.is_set() and not f.ok else None


# ---------------------------------------------------------------- Modelle und Einstellungen

def models(force: bool = False) -> list[str]:
    """Modelle, die ueber das Abo verfuegbar sind (GET /v1/models mit dem Zugriffstoken); 10 Minuten gemerkt."""
    global _models_cache
    if _models_cache and not force and time.monotonic() - _models_cache[0] < MODELS_TTL_S:
        return _models_cache[1]
    token = access_token()
    try:
        data = http_get_json(MODELS_URL, token)
    except ChatGPTError as e:
        if e.status == 401:
            mark_reauth(why=e.message)
            raise ChatGPTError("chatgpt_login_needed", "Die Anmeldung bei ChatGPT ist abgelaufen – bitte neu verbinden.", 401)
        raise
    ids = sorted({str(m.get("id") or m.get("slug")) for m in (data.get("data") or []) if isinstance(m, dict) and (m.get("id") or m.get("slug"))})
    _models_cache = (time.monotonic(), ids)
    return ids


def model() -> str:
    return str(load().get("model") or "")


def set_model(slug: str) -> None:
    slug = (slug or "").strip()
    if not slug or len(slug) > 100 or any(c.isspace() for c in slug):
        raise ChatGPTError("chatgpt_model_invalid", "Ungueltiger Modellname.", 400)
    with _lock:
        d = load()
        d["model"] = slug
        save(d)


def set_use_for_ai(flag: bool) -> None:
    with _lock:
        d = load()
        d["use_for_ai"] = bool(flag)
        save(d)


def enabled_for_ai() -> bool:
    """KI-Anfragen ueber ChatGPT leiten: nur lokal, verbunden, Abo-Nutzung gewaehrt, Schalter an, Modell gewaehlt."""
    if not available():
        return False
    d = load()
    return connected(d) and sharing(d) and bool(d.get("use_for_ai", True)) and bool(d.get("model")) and not d.get("needs_reauth")


def status() -> dict:
    d = load() if available() else {}
    creds = d.get("credentials") or {}
    profile = d.get("profile") or {}
    return {
        "available": available(), "status": "local" if available() else "disabled",
        "connected": connected(d), "sharing": sharing(d), "needs_reauth": bool(d.get("needs_reauth")),
        "email": profile.get("email"), "name": profile.get("name"),
        "expires_at": creds.get("expires_at"), "scopes": creds.get("scopes") or [],
        "model": d.get("model") or "", "use_for_ai": bool(d.get("use_for_ai", True)),
        "registered": bool(d.get("client_id")), "pending": pending(), "last_error": d.get("last_error") or last_flow_error(),
        "usage_help_url": USAGE_HELP_URL,
    }
