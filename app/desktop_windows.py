"""Browserfenster IN der Windows-App (Tauri) statt eines fremden Browsers.

Vorgabe des Inhabers (27.10.2026): Alles, was die App im Browser zeigt – die Anmeldung bei der Hochschule, Links wie
„Im Stud.IP öffnen“, spaeter die ChatGPT-Anmeldung – soll als Fenster der App erscheinen, nicht als Edge oder Chrome.

So geht es: Das Tauri-Fenster (apps/windows/src-tauri/src/main.rs) fragt dieses Backend in einer Schleife nach
Auftraegen (`GET /api/desktop/commands?wait=25`, lange Abfrage), oeffnet dafuer ein eigenes WebView-Fenster und meldet
dessen Zustand zurueck (`POST /api/desktop/windows/{id}/state`: offen/geschlossen, aktuelle Adresse, Cookies der
gewuenschten Hosts). Das Backend entscheidet, wann ein Fenster fertig ist (`done`), dann schliesst Tauri es.

- `open`: Link in einem App-Fenster (Titel = Host). Nichts kommt zurueck.
- `login`: Anmeldefenster der Hochschule; Tauri liefert jede Sekunde die Cookies der genannten Adressen, das Backend
  prueft damit die Anmeldung (app/unilogin.py) und merkt die Sitzung. Das Passwort sieht nur das Fenster.

Nur im lokalen Betrieb der Windows-App (LERNAPP_DESKTOP=1). Ist kein Fenster-Agent verbunden (aelteres Tauri-Fenster,
Entwicklung mit serve.py), faellt alles auf den Systembrowser bzw. Playwright zurueck (`agent_connected()`).
"""
from __future__ import annotations

import itertools
import threading
import time
from dataclasses import dataclass, field

AGENT_TIMEOUT_S = 60          # so lange nach der letzten Abfrage gilt der Agent als verbunden
MAX_WAIT_S = 30               # laengste Wartezeit einer Abfrage
COOKIE_KEYS = ("name", "value", "domain", "path", "expires", "httpOnly", "secure")
# Grenzen (Audit 08.11.2026, P15-08/P15-09): so viele Fenster merkt das Backend (fertige zuerst verworfen), so viele
# Cookies je Meldung, so lang darf ein Feld eines Cookies sein (laengere Cookies werden verworfen, nicht gekuerzt)
MAX_WINDOWS = 200
MAX_COOKIES = 300
MAX_COOKIE_FIELD = 8192

_cond = threading.Condition()
_queue: list[dict] = []
_windows: dict[str, "Window"] = {}
_ids = itertools.count(1)
_agent_seen: float = 0.0


@dataclass
class Window:
    id: str
    kind: str
    url: str
    status: str = "pending"           # pending | open | closed
    current_url: str = ""
    cookies: list[dict] = field(default_factory=list)
    updated_at: float = 0.0
    done: bool = False                # das Backend ist fertig: Tauri schliesst das Fenster
    result: str | None = None


def agent_connected(now: float | None = None) -> bool:
    return (time.time() if now is None else now) - _agent_seen < AGENT_TIMEOUT_S


def enqueue(kind: str, url: str, title: str, cookie_urls: list[str] | None = None) -> Window:
    """Auftrag an das Tauri-Fenster; liefert das Fenster-Objekt (Zustand folgt ueber `report`)."""
    with _cond:
        w = Window(id=f"w{next(_ids)}", kind=kind, url=url, updated_at=time.time())
        _windows[w.id] = w
        _prune()
        _queue.append({"id": w.id, "kind": kind, "url": url, "title": title, "cookie_urls": list(cookie_urls or [])})
        _cond.notify_all()
        return w


def _prune() -> None:
    """Hoechstens MAX_WINDOWS Fenster: zuerst die aeltesten fertigen, dann die aeltesten Link-Fenster (`open`, die
    nie fertig gemeldet werden). Ein laufendes Anmeldefenster bleibt. Aufruf unter `_cond`."""
    excess = len(_windows) - MAX_WINDOWS
    if excess <= 0:
        return
    order = sorted((w for w in _windows.values() if w.done or w.kind != "login"),
                   key=lambda w: (not w.done, int(w.id[1:]) if w.id[1:].isdigit() else 0))
    for w in order[:excess]:
        _windows.pop(w.id, None)


def _clean_cookies(cookies: list) -> list[dict]:
    out = []
    for c in cookies:
        if len(out) >= MAX_COOKIES:
            break
        if not (isinstance(c, dict) and c.get("name")):
            continue
        d = {k: c.get(k) for k in COOKIE_KEYS}
        if any(isinstance(v, str) and len(v) > MAX_COOKIE_FIELD for v in d.values()):
            continue
        out.append(d)
    return out


def next_command(wait: float = MAX_WAIT_S, now: float | None = None) -> dict | None:
    """Naechster Auftrag fuer das Tauri-Fenster; wartet bis zu `wait` Sekunden (lange Abfrage). None = nichts."""
    global _agent_seen
    deadline = time.monotonic() + max(0.0, min(wait, MAX_WAIT_S))
    with _cond:
        _agent_seen = time.time() if now is None else now
        while not _queue:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            _cond.wait(remaining)
        return _queue.pop(0)


def report(window_id: str, status: str | None = None, url: str | None = None, cookies: list | None = None) -> dict:
    """Zustandsmeldung des Fensters; Antwort sagt, ob es sich schliessen soll (`done`). Unbekannte IDs: done, damit
    ein verwaistes Fenster (Backend neu gestartet) nicht offen bleibt."""
    with _cond:
        w = _windows.get(window_id)
        if w is None:
            return {"done": True, "known": False}
        if status in ("open", "closed"):
            w.status = status
        if isinstance(url, str):
            w.current_url = url[:2048]
        if isinstance(cookies, list) and not w.done:     # fertig: keine Cookies mehr im Speicher halten
            w.cookies = _clean_cookies(cookies)
        w.updated_at = time.time()
        _cond.notify_all()
        return {"done": w.done, "known": True}


def finish(window_id: str, result: str | None = None) -> None:
    """Das Backend ist mit dem Fenster fertig: die naechste Zustandsmeldung bekommt done=true."""
    with _cond:
        w = _windows.get(window_id)
        if w:
            w.done, w.result = True, (result if result is not None else w.result)
            w.cookies = []                               # Sitzung ist gemerkt (oder verworfen): nicht im RAM lassen
            _cond.notify_all()


def wait_update(window_id: str, after: float, timeout: float) -> Window | None:
    """Wartet auf eine Zustandsmeldung nach `after` (hoechstens `timeout` Sekunden) und liefert den Stand."""
    deadline = time.monotonic() + timeout
    with _cond:
        while True:
            w = _windows.get(window_id)
            if w is None:
                return None
            if w.updated_at > after or w.status == "closed":
                return w
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return w
            _cond.wait(remaining)


def forget(window_id: str) -> None:
    with _cond:
        _windows.pop(window_id, None)


def pending() -> int:
    with _cond:
        return len(_queue)


def reset() -> None:
    """Fuer Tests."""
    global _agent_seen
    with _cond:
        _queue.clear(); _windows.clear(); _agent_seen = 0.0
        _cond.notify_all()
