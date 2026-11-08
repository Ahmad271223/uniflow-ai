"""Eigenes ChatGPT ueber den eigenen OpenAI-API-Schluessel des Nutzers (Windows-App, 08.11.2026; wie auf dem iPad
`OpenAIKeySession.swift` / `OpenAIKeyLink.swift`, Einstellungen -> Erweitert).

Anders als "Sign in with ChatGPT" (app/chatgpt_login.py, braucht die Partnerfreigabe von OpenAI und ist aus wie auf dem
iPad, `chatgpt_login.ENABLED`) braucht ein API-Schluessel keine Freigabe: der Nutzer legt ihn bei platform.openai.com
selbst an und traegt ihn in den Einstellungen ein. Regeln:

- Der Schluessel liegt nur auf diesem PC: unter Windows in der Anmeldeinformationsverwaltung (DPAPI, Ziel
  `StudiNow/openai-schluessel`, app/token_store.WindowsCredentialStore), in der Entwicklung ausserhalb von Windows in
  einer Datei mit Rechten 0600. Er geht nie an den StudiNow-Dienst, steht in keiner Antwort und keinem Protokoll
  (`key_hint` zeigt nur die letzten vier Zeichen). Modell, Schalter und Pruefstand stehen ohne Schluessel in
  `openai-key.json` im Datenordner.
- Nur auf dem eigenen PC (Windows-App, serve.py). Im Dienst/Web gibt es keinen eigenen Schluessel, nur die
  StudiNow-KI (Vorgabe des Inhabers 08.11.2026): dort `available: false`, jede Aenderung 503.
- Vor dem Speichern braucht es die Einwilligung (`consent: true`, Text CONSENT_TEXT wie auf dem iPad): jede
  KI-Anfrage geht direkt vom PC an api.openai.com und kostet den Nutzer Geld bei OpenAI. Darum nie im Hintergrund,
  nur nach Antippen (ai.ask), und in jedem Tarif (keine Kopplung an einen bezahlten Tarif, Bedingungen von OpenAI).
- Reihenfolge der KI am PC (app/ai_relay.source): Geteiltes/Gespeichertes -> ChatGPT-Abo (aus) -> eigener Schluessel
  -> StudiNow-KI mit Credits.
"""
from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from fastapi import APIRouter, Body, HTTPException

from . import config, token_store

router = APIRouter(tags=["ai"])

FILE_NAME = "openai-key.json"          # Zustand ohne Schluessel
KEY_FILE = "openai-key"                # Schluessel ausserhalb von Windows (Entwicklung), Rechte 0600
TARGET = "StudiNow/openai-schluessel"  # Windows-Anmeldeinformationsverwaltung
DEFAULT_MODEL = "gpt-4o-mini"
KEYS_URL = "https://platform.openai.com/api-keys"
USAGE_URL = "https://platform.openai.com/usage"
MODELS_URL = "https://api.openai.com/v1/models"
KEY_MIN, KEY_MAX = 20, 400
MODELS_TTL_S = 600
HTTP_TIMEOUT_S = 30

# Einwilligung (Stand des Textes; ein neuer Stand fragt erneut). Wortlaut wie OpenAIKeyLink.consentText auf dem iPad,
# nur der Ort des Schluessels ist der des PCs.
CONSENT_VERSION = "2026-11-08"
CONSENT_TEXT = ("Dein Schlüssel bleibt in der Windows-Anmeldeinformationsverwaltung dieses PCs und geht nie an StudiNow. "
                "Wenn du eine KI-Funktion anklickst (Frage im Editor, Karteikarten, Wochentest, KI-Lernplan), schickt StudiNow "
                "den Text der Seite oder deiner Markierung, deine Frage und die Namen von Kurs und Datei – beim Lernplan nur "
                "Modultitel, Lehrwochen, Dateinamen und Zeiten – direkt an OpenAI. Die Anfragen rechnet OpenAI über dein Konto "
                "ab (platform.openai.com); es gelten die Bedingungen und die Datenschutzerklärung von OpenAI.")
CHECKED_TEXT = "Schlüssel geprüft – OpenAI hat geantwortet."
NOT_AVAILABLE = "Einen eigenen OpenAI-Schlüssel gibt es nur in der Windows-App; im Web läuft die KI über StudiNow."

_lock = threading.RLock()        # reentrant: remove()/save_key() halten ihn und rufen key_store()
_key_store = None
_models_cache: tuple[float, list[str]] | None = None


class OpenAIKeyError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


# ---------------------------------------------------------------- Regeln (rein, wie OpenAIKeyRules auf dem iPad)

def normalize(raw: str | None) -> str | None:
    """Schluessel in gueltiger Form: aussen ohne Leerraum, beginnt mit "sk-", 20-400 Zeichen, nur sichtbare
    ASCII-Zeichen; sonst None."""
    k = (raw or "").strip()
    if not k.startswith("sk-") or not (KEY_MIN <= len(k) <= KEY_MAX):
        return None
    if any(not (32 < ord(c) < 127) for c in k):
        return None
    return k


def masked(key: str) -> str:
    """Anzeige: nur die letzten vier Zeichen ("sk-…ab12")."""
    if not key:
        return ""
    return "sk-…" + key[-4:] if len(key) >= 8 else "sk-…"


_SPECIAL = ("audio", "realtime", "search", "transcribe", "tts", "image", "embedding", "instruct", "moderation",
            "dall", "whisper", "computer", "vision", "oss", "codex", "chatgpt-4o-latest")


def is_chat_model(model_id: str) -> bool:
    """Chat-Modelle aus GET /v1/models: "gpt-…" und "o<Ziffer>…", ohne Spezialmodelle."""
    low = (model_id or "").lower()
    if not (low.startswith("gpt-") or re.match(r"^o\d", low)):
        return False
    return not any(s in low for s in _SPECIAL)


def _text_less(a: str, b: str) -> bool:
    return a < b


def chat_models(ids: list[str]) -> list[str]:
    """Nur die Chat-Modelle, alphabetisch, die "mini"-Modelle (Standardfamilie) vorn; ohne Doppel."""
    chat = [i for i in ids if is_chat_model(i)]
    minis = sorted(i for i in chat if "mini" in i.lower())
    rest = sorted(i for i in chat if "mini" not in i.lower())
    out: list[str] = []
    for i in minis + rest:
        if i not in out:
            out.append(i)
    return out


def _dated(model_id: str) -> bool:
    return re.search(r"\d{4}-\d{2}-\d{2}|-\d{4}$", model_id) is not None


def _numeric_key(s: str):
    return [int(p) if p.isdigit() else p for p in re.split(r"(\d+)", s)]


def pick_default(ids: list[str]) -> str | None:
    """Modell ohne Wahl: DEFAULT_MODEL, wenn die Liste es fuehrt; sonst das neueste "mini"-Modell ohne Datum; sonst
    das erste Chat-Modell; None bei leerer Liste."""
    chat = chat_models(ids)
    if DEFAULT_MODEL in chat:
        return DEFAULT_MODEL
    minis = [i for i in chat if i.lower().startswith("gpt-") and "mini" in i.lower() and not _dated(i)]
    if minis:
        return sorted(minis, key=_numeric_key, reverse=True)[0]
    return chat[0] if chat else None


def model_ids(data) -> list[str]:
    items = data.get("data") if isinstance(data, dict) else None
    return sorted({str(m.get("id") or "").strip() for m in (items or []) if isinstance(m, dict) and str(m.get("id") or "").strip()})


# ---------------------------------------------------------------- Ablage

def available() -> bool:
    """Nur auf dem eigenen PC (Windows-App, serve.py); im Dienst/Web nie."""
    return not config.is_hosted()


def _require_local() -> None:
    if not available():
        raise OpenAIKeyError("openai_key_not_available", NOT_AVAILABLE, 503)


class _KeyFile(token_store.FileStore):
    """Datei im Datenordner (Entwicklung ausserhalb von Windows)."""
    def path(self) -> Path:
        return config.data_dir() / KEY_FILE


def default_key_store():
    if sys.platform == "win32":
        try:
            return token_store.WindowsCredentialStore(TARGET)
        except (OSError, AttributeError):
            return token_store.MemoryStore()
    return _KeyFile()


def key_store():
    global _key_store
    with _lock:
        if _key_store is None:
            _key_store = default_key_store()
        return _key_store


def use_key_store(store) -> None:
    """Ablage austauschen (Tests); None = beim naechsten Zugriff wieder die Standardablage."""
    global _key_store, _models_cache
    with _lock:
        _key_store = store
        _models_cache = None


def storage_kind() -> str:
    return getattr(key_store(), "kind", "unknown")


def state_path() -> Path:
    return config.data_dir() / FILE_NAME


def load_state() -> dict:
    p = state_path()
    if not p.is_file():
        return {}
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (ValueError, OSError):
        return {}


def save_state(d: dict) -> None:
    assert "api_key" not in d and "key" not in d, "der Schluessel gehoert nie in die Zustandsdatei"
    p = state_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1), encoding="utf-8")
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, p)


def api_key() -> str:
    if not available():
        return ""
    try:
        k = key_store().get()
    except token_store.StoreError:
        return ""
    return k if k and normalize(k) else ""


def has_key() -> bool:
    return bool(api_key())


def model() -> str:
    return str(load_state().get("model") or "")


def consent_given(d: dict | None = None) -> bool:
    d = load_state() if d is None else d
    return d.get("consent_version") == CONSENT_VERSION and bool(d.get("consent_at"))


def enabled_for_ai() -> bool:
    """KI-Anfragen ueber den eigenen Schluessel: nur lokal, Schluessel da, Einwilligung, Schalter an, Modell gewaehlt."""
    if not available():
        return False
    d = load_state()
    return has_key() and consent_given(d) and bool(d.get("use_for_ai", True)) and bool(d.get("model"))


# ---------------------------------------------------------------- HTTP (Tests tauschen http_get_json aus)

def http_get_json(url: str, bearer: str) -> dict:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {bearer}", "Accept": "application/json",
                                               "User-Agent": "StudiNow/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as r:  # noqa: S310 - feste https-Adresse
            return json.loads(r.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")[:600]
        except Exception:  # noqa: BLE001
            pass
        if e.code == 401:
            raise OpenAIKeyError("openai_key_rejected", "OpenAI hat den Schlüssel abgelehnt (401). Prüfe ihn auf platform.openai.com.", 401)
        raise OpenAIKeyError("openai_http_error", f"OpenAI antwortete mit Fehler {e.code}: {_error_text(body)}", e.code)
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise OpenAIKeyError("openai_unreachable", f"OpenAI ist nicht erreichbar: {e}", 502)


def _error_text(body: str) -> str:
    try:
        j = json.loads(body)
        err = j.get("error") if isinstance(j, dict) else None
        if isinstance(err, dict) and err.get("message"):
            return str(err["message"])[:300]
    except ValueError:
        pass
    return body[:300]


# ---------------------------------------------------------------- Aenderungen

def save_key(raw: str | None, consent: bool) -> dict:
    """Schluessel eintragen (mit Einwilligung) und gleich pruefen; bei ungueltiger Form bleibt der alte Stand.
    Schlaegt die Pruefung fehl (kein Netz, abgelehnt), bleibt der Schluessel gespeichert und `last_error` sagt warum."""
    _require_local()
    if not consent:
        raise OpenAIKeyError("consent_required", "Bitte stimme zuerst zu, dass StudiNow deine Anfragen mit deinem Schlüssel direkt an OpenAI senden darf.", 428)
    key = normalize(raw)
    if not key:
        raise OpenAIKeyError("openai_key_invalid", "Der Schlüssel beginnt mit „sk-“ und hat 20 bis 400 Zeichen ohne Leerzeichen.", 400)
    global _models_cache
    with _lock:
        try:
            key_store().set(key)
        except token_store.StoreError as e:
            raise OpenAIKeyError("openai_key_store_failed", f"Der Schlüssel konnte nicht gespeichert werden: {e}", 500)
        _models_cache = None
        d = load_state()
        d.update({"consent_version": CONSENT_VERSION, "consent_at": _now(), "key_hint": masked(key), "last_error": None,
                  "use_for_ai": bool(d.get("use_for_ai", True))})
        d.pop("checked_at", None)
        save_state(d)
    try:
        check()
    except OpenAIKeyError:
        pass
    return status()


def check() -> dict:
    """GET /v1/models mit dem Schluessel: merkt den Pruefstand, waehlt ohne Wahl das Standardmodell; Fehler als
    OpenAIKeyError (Text ohne Schluessel) und in `last_error`."""
    _require_local()
    key = api_key()
    if not key:
        raise OpenAIKeyError("openai_key_missing", "Noch kein OpenAI-Schlüssel eingetragen.", 404)
    global _models_cache
    try:
        ids = model_ids(http_get_json(MODELS_URL, key))
    except OpenAIKeyError as e:
        with _lock:
            d = load_state()
            d["last_error"] = e.message
            save_state(d)
        raise
    with _lock:
        _models_cache = (time.monotonic(), ids)
        d = load_state()
        d["checked_at"], d["last_error"] = _now(), None
        if not d.get("model") or (ids and d["model"] not in ids and d["model"] not in chat_models(ids)):
            picked = pick_default(ids)
            if picked:
                d["model"] = picked
        save_state(d)
    return status()


def models(force: bool = False) -> list[str]:
    """Chat-Modelle des Kontos (GET /v1/models), 10 Minuten gemerkt."""
    _require_local()
    global _models_cache
    if _models_cache and not force and time.monotonic() - _models_cache[0] < MODELS_TTL_S:
        return chat_models(_models_cache[1])
    key = api_key()
    if not key:
        raise OpenAIKeyError("openai_key_missing", "Noch kein OpenAI-Schlüssel eingetragen.", 404)
    ids = model_ids(http_get_json(MODELS_URL, key))
    _models_cache = (time.monotonic(), ids)
    return chat_models(ids)


def set_model(slug: str) -> None:
    _require_local()
    slug = (slug or "").strip()
    if not slug or len(slug) > 100 or any(c.isspace() for c in slug):
        raise OpenAIKeyError("openai_model_invalid", "Ungültiger Modellname.", 400)
    with _lock:
        d = load_state()
        d["model"] = slug
        save_state(d)


def set_use_for_ai(flag: bool) -> None:
    _require_local()
    with _lock:
        d = load_state()
        d["use_for_ai"] = bool(flag)
        save_state(d)


def remove() -> None:
    """Schluessel und Zustand von diesem PC entfernen (Einstellungen, "Hochschul-Konto entfernen")."""
    global _models_cache
    with _lock:
        try:
            key_store().delete()
        except token_store.StoreError:
            pass
        _models_cache = None
        try:
            state_path().unlink(missing_ok=True)
        except OSError:
            pass


def status() -> dict:
    d = load_state() if available() else {}
    key = api_key()
    return {
        "available": available(), "has_key": bool(key), "key_hint": masked(key) if key else "",
        "model": d.get("model") or "", "use_for_ai": bool(d.get("use_for_ai", True)),
        "checked": bool(d.get("checked_at")), "checked_at": d.get("checked_at"), "last_error": d.get("last_error"),
        "enabled_for_ai": enabled_for_ai(), "consent_given": consent_given(d), "consent_version": CONSENT_VERSION,
        "consent_text": CONSENT_TEXT, "checked_text": CHECKED_TEXT, "keys_url": KEYS_URL, "usage_url": USAGE_URL,
        "default_model": DEFAULT_MODEL, "storage": storage_kind() if available() else None,
        "message": None if available() else NOT_AVAILABLE,
    }


def _now() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# ---------------------------------------------------------------- Endpunkte

def _call(fn):
    try:
        return fn()
    except OpenAIKeyError as e:
        raise HTTPException(e.status, {"detail": e.message, "code": e.code})


@router.get("/api/integrations/openai-key")
def api_status():
    """Stand des eigenen OpenAI-Schluessels (nie der Schluessel selbst) samt Einwilligungstext."""
    return status()


@router.put("/api/integrations/openai-key")
def api_put(body: dict = Body(...)):
    """{key, consent: true}: Schluessel speichern (nur auf diesem PC) und pruefen; 428 ohne Einwilligung."""
    return _call(lambda: save_key(str(body.get("key") or ""), bool(body.get("consent"))))


@router.post("/api/integrations/openai-key/check")
def api_check():
    return _call(check)


@router.get("/api/integrations/openai-key/models")
def api_models(force: bool = False):
    return {"models": _call(lambda: models(force=force)), "model": model()}


@router.put("/api/integrations/openai-key/settings")
def api_settings(body: dict = Body(...)):
    def go():
        if "model" in body:
            set_model(str(body.get("model") or ""))
        if "use_for_ai" in body:
            set_use_for_ai(bool(body["use_for_ai"]))
        return status()
    return _call(go)


@router.delete("/api/integrations/openai-key")
def api_delete():
    def go():
        _require_local()
        remove()
        return status()
    return _call(go)
