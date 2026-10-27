"""Hochschul-Anmeldung im sichtbaren Browserfenster (Einzelplatz: Windows/PC, serve.py).

Vorgabe des Inhabers (27.10.2026): Das Hochschul-Passwort merkt sich nur der Browser, den die App zeigt, nie die App.
Die App oeffnet dafuer das Anmeldefenster der Hochschule (Chromium von Playwright, sichtbar, eigenes Profil im
Datenordner), der Mensch meldet sich selbst an, Chromium bietet "Passwort speichern?" an und fuellt beim naechsten
Mal vor (geprueft am 27.10.2026: Eintrag in "Login Data", Vorausfuellen beim naechsten Oeffnen). Die App behaelt nur
die Sitzung (Cookies) in `university-session.json` im Datenordner und nutzt sie fuer den Abgleich und das
Durchreichen von Dateien; ist sie abgelaufen, meldet der Abgleich "Anmeldung noetig" und der Mensch klickt erneut
"Im Browser anmelden". Zugangsdaten in der .env bleiben eine freiwillige Alternative fuer den Abgleich ohne Nachfrage.

Im Dienst (hosted) gibt es kein Fenster auf dem Server: dort liegen die Sitzungs-Cookies verschluesselt im Tresor des
Kontos (STUDIP_COOKIES / LEARNWEB_COOKIES), gesetzt vom Abgleich oder von der App auf dem Geraet."""
from __future__ import annotations

import json
import os
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from . import config

SESSION_FILE = "university-session.json"
COOKIE_KEYS = ("name", "value", "domain", "path", "expires", "httpOnly", "secure", "sameSite")
TIMEOUT_S = int(os.getenv("LERNAPP_UNILOGIN_TIMEOUT", "300"))      # so lange bleibt das Fenster offen
POLL_S = 1.0

_state: dict = {"state": "idle", "message": "", "since": None, "university": None}
_lock = threading.Lock()


class LoginRequired(RuntimeError):
    """Keine gueltige Hochschul-Sitzung und keine Zugangsdaten: der Mensch muss sich im Browserfenster anmelden."""
    code = "login_required"


# ---------------------------------------------------------------- Sitzung (Cookies)

def session_path() -> Path:
    return config.data_dir() / SESSION_FILE


def _read_file() -> dict:
    p = session_path()
    try:
        return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
    except (OSError, ValueError):
        return {}


def _write_file(data: dict) -> None:
    p = session_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, p)


def _trim(cookies: list[dict]) -> list[dict]:
    return [{k: c.get(k) for k in COOKIE_KEYS if c.get(k) is not None} for c in cookies if isinstance(c, dict) and c.get("name")]


def saved_cookies(name: str) -> list[dict]:
    """Gemerkte Sitzung (JSON-Liste wie Playwright context.cookies()): Tresor im Dienst, sonst Datei im Datenordner."""
    if config.is_hosted():
        raw = config.secret(name)
        try:
            data = json.loads(raw) if raw else []
        except ValueError:
            data = []
        return data if isinstance(data, list) else []
    entry = _read_file().get(name) or {}
    return entry.get("cookies") or [] if isinstance(entry, dict) else []


def saved_at(name: str) -> str | None:
    if config.is_hosted():
        return None
    entry = _read_file().get(name) or {}
    return entry.get("saved_at") if isinstance(entry, dict) else None


def has_session(name: str) -> bool:
    now = time.time()
    return any(not c.get("expires") or c["expires"] < 0 or c["expires"] > now for c in saved_cookies(name))


def save_session(name: str, cookies: list[dict]) -> None:
    """Nach der Anmeldung: Cookies merken (Dienst: verschluesselt im Tresor des Kontos; PC: Datei im Datenordner)."""
    keep = _trim(cookies)
    if config.is_hosted():
        config.set_env({name: json.dumps(keep, ensure_ascii=False)})
        return
    data = _read_file()
    data[name] = {"cookies": keep, "saved_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    _write_file(data)


def forget(name: str | None = None) -> None:
    names = [name] if name else ["STUDIP_COOKIES", "LEARNWEB_COOKIES"]
    if config.is_hosted():
        config.set_env({n: None for n in names})
        return
    data = _read_file()
    for n in names:
        data.pop(n, None)
    if data:
        _write_file(data)
    else:
        session_path().unlink(missing_ok=True)


def restore(ctx, name: str) -> int:
    """Gemerkte Sitzung in einen Playwright-Kontext legen (Chromium verwirft Sitzungs-Cookies beim Schliessen)."""
    cookies = []
    for c in saved_cookies(name):
        if not (c.get("name") and c.get("domain")):
            continue
        d = {"name": c["name"], "value": str(c.get("value") or ""), "domain": c["domain"], "path": c.get("path") or "/"}
        for k in ("expires", "httpOnly", "secure", "sameSite"):
            if c.get(k) is not None:
                d[k] = c[k]
        cookies.append(d)
    if cookies:
        ctx.add_cookies(cookies)
    return len(cookies)


# ---------------------------------------------------------------- Hochschulen

def _target(university: str | None) -> tuple[str, str, str, object, Path]:
    """(Schluessel, Name der Sitzung, Startadresse, Pruefung angemeldet(page), Profilordner)."""
    from . import universities
    key = university or universities.current_key()
    if key == "hildesheim":
        from . import hildesheim, learnweb
        base = hildesheim.learnweb_base()
        return (key, "LEARNWEB_COOKIES", f"{base}/login/index.php?authCAS=CAS",
                lambda page: learnweb.SessionClient(page, base).is_logged_in(), hildesheim._profile_dir())
    from . import studip_sync
    return key, "STUDIP_COOKIES", studip_sync.SHIB_LOGIN_URL, studip_sync._is_logged_in, studip_sync._profile_dir()


def session_name(university: str | None = None) -> str:
    return _target(university)[1]


# ---------------------------------------------------------------- Fenster

def status() -> dict:
    with _lock:
        return dict(_state)


def _set(**kw) -> None:
    with _lock:
        _state.update(kw)


def run(university: str | None = None, launch=None) -> str:
    """Oeffnet das Anmeldefenster und wartet, bis die Hochschule angemeldet ist (hoechstens TIMEOUT_S Sekunden).
    Blockiert; der Server ruft es als Hintergrundaufgabe auf (ein Chromium-Profil vertraegt nur ein Fenster).
    `launch` (Tests): Funktion, die einen Kontext mit pages/new_page/cookies/close liefert."""
    if config.is_hosted():
        raise RuntimeError("Im Dienst meldet sich die App auf dem Geraet an; auf dem Server gibt es kein Fenster.")
    key, name, url, check, profile = _target(university)
    _set(state="open", message="Anmeldefenster ist offen – bitte dort anmelden.", since=time.time(), university=key)
    try:
        if launch is None:
            from playwright.sync_api import sync_playwright
            with sync_playwright() as p:
                ctx = p.chromium.launch_persistent_context(
                    str(profile), headless=False, locale="de-DE",
                    ignore_default_args=["--enable-automation"],     # normales Chromium: Passwort-Manager bietet Speichern an
                    args=["--window-size=1000,820"])
                return _wait(ctx, name, url, check)
        return _wait(launch(profile), name, url, check)
    except LoginRequired:
        raise                                                        # Zustand (closed/timeout) ist schon gesetzt
    except Exception as e:  # noqa: BLE001
        _set(state="error", message=f"Anmeldung fehlgeschlagen: {e}")
        raise


def _wait(ctx, name: str, url: str, check) -> str:
    try:
        page = ctx.pages[0] if getattr(ctx, "pages", None) else ctx.new_page()
        page.goto(url, wait_until="domcontentloaded")
        deadline = time.time() + TIMEOUT_S
        while time.time() < deadline:
            try:
                if page.is_closed():
                    pages = [p for p in ctx.pages if not p.is_closed()]
                    if not pages:
                        _set(state="closed", message="Fenster geschlossen, nicht angemeldet.")
                        raise LoginRequired("Fenster geschlossen, ohne angemeldet zu sein.")
                    page = pages[0]
                if check(page):
                    save_session(name, ctx.cookies())
                    _set(state="ok", message="Angemeldet, Sitzung gemerkt.")
                    return "angemeldet"
            except LoginRequired:
                raise
            except Exception as e:  # noqa: BLE001 - Fenster weg oder Seite mitten im Wechsel
                if "closed" in str(e).lower() or "target" in str(e).lower():
                    _set(state="closed", message="Fenster geschlossen, nicht angemeldet.")
                    raise LoginRequired("Fenster geschlossen, ohne angemeldet zu sein.") from None
            time.sleep(POLL_S)
        _set(state="timeout", message="Zeit abgelaufen, nicht angemeldet.")
        raise LoginRequired("Zeit abgelaufen, ohne angemeldet zu sein.")
    finally:
        try:
            ctx.close()
        except Exception:  # noqa: BLE001
            pass
