"""Modellmischung der StudiNow-KI (Entscheidung des Inhabers 05.11.2026): etwa 50 % DeepSeek (nur ueber einen Anbieter in
der EU), 25 % ChatGPT (OpenAI), 25 % Claude Sonnet 5.5 - nicht zufaellig, sondern nach Aufgabe: einfache Fragen,
Karteikarten, Dokument-Index und Zusammenfassungen an die guenstigen Modelle, schwere Faelle (Rechnen und Herleiten,
"Erklaere alle Aufgaben", Bewerten von Loesungen, "Antwort war falsch" als Zweitmeinung) an Sonnet.
Bericht und Quellen: docs/KI-MODELLMISCHUNG-2026-11-05.md.

Umgebung (deploy/.env, alles optional):
    LERNAPP_AI_ROUTES     JSON, ueberschreibt die Wege je Zweck. Form:
                            {"routes": {"tutor:explain": "deepseek:65,openai:35", "default": [["deepseek", 50], ...]},
                             "hard": "anthropic:100", "hard_purposes": ["tutor:steps", ...], "math": true}
                          Ein Zweck sucht erst exakt (tutor:explain), dann den Anfang mit Stern (tutor:*), dann "default".
                          Eintraege: Anbieter (deepseek | openai | anthropic, auch chatgpt/claude/sonnet) mit Gewicht;
                          "anbieter/modell:gewicht" legt das Modell fest (sonst das Modell des Anbieters aus der Umgebung).
    LERNAPP_AI_DISABLED   Notschalter je Anbieter, Komma-Liste (z. B. "deepseek"): der Anbieter bekommt keine Anfrage
                          mehr, seine Anteile gehen an die anderen des Weges.

Regeln:
- Dieselbe request_id (Wiederholung nach Netzfehler) landet immer beim selben Modell: die Wahl ist ein Hash aus
  request_id und Zweck, kein Zufall.
- Nicht eingerichtete oder abgeschaltete Anbieter fallen aus dem Weg, die Gewichte der uebrigen zaehlen.
- Hinter dem gewaehlten Modell stehen die anderen als Ersatz (Reihenfolge: Gewicht im Weg, dann die uebrigen
  eingerichteten Anbieter). app/ai_backend.complete wechselt nur bei Fehlern, fuer die der Anbieter nichts berechnet
  (5xx, 429, Zeitueberschreitung vor der ersten Antwortzeile), und reserviert vorher fuer das teuerste Modell der Kette.
- Mit Bild nur Modelle, die Bilder lesen (app/ai_prices.py `vision`).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass

PROVIDERS = ("deepseek", "openai", "anthropic")
ALIASES = {"chatgpt": "openai", "gpt": "openai", "claude": "anthropic", "sonnet": "anthropic", "bedrock": "anthropic",
           "scaleway": "deepseek"}

# Standardwege (Gewichte je Zweck). Ergibt bei TYPICAL_MIX etwa 50 / 25 / 25 (expected_share, Test in
# tests/test_ai_routing.py).
SIMPLE = (("deepseek", 65), ("openai", 35))
MEDIUM = (("deepseek", 50), ("openai", 25), ("anthropic", 25))
HARD = (("anthropic", 100),)
DEFAULT_ROUTES: dict[str, tuple] = {
    "default": SIMPLE,
    "tutor:ask": MEDIUM, "tutor:similar": MEDIUM,
    "week_test": MEDIUM, "weekly_test": MEDIUM, "test_generation": MEDIUM,
}
# Immer schwer: Loesung Schritt fuer Schritt, Loesung pruefen (Bewerten), "Erklaere alle Aufgaben" im ganzen Dokument
HARD_PURPOSES = ("tutor:steps", "tutor:check", "tutor:doc_tasks")
# Schwer, wenn die Frage nach Rechnen oder Herleiten aussieht (looks_math)
MATH_PURPOSES = ("tutor:ask", "tutor:explain", "tutor:explain_simple", "tutor:similar", "tutor:hints")
# Hinweise der Aufrufer, die immer den schweren Weg nehmen ("Antwort war falsch" -> Zweitmeinung)
HARD_HINTS = ("hard", "second_opinion")

# Typische Nutzung je 100 Anfragen (Annahme fuer den Bericht, nicht gemessen): (Zweck, Anteil, schwer nach Inhalt)
TYPICAL_MIX: tuple[tuple[str, float, bool], ...] = (
    ("tutor:explain", 16, False), ("tutor:summary", 8, False), ("tutor:explain_simple", 5, False), ("tutor:terms", 4, False),
    ("tutor:hints", 3, False), ("flashcards", 8, False), ("tutor:flashcards", 2, False), ("doc_index_page", 8, False),
    ("tutor:doc_lecture", 3, False), ("tutor:doc_overview", 1, False), ("tutor:doc_full", 2, False),
    ("tutor:ask", 12, False), ("tutor:similar", 3, False), ("weekly_test", 3, False), ("test_generation", 2, False),
    ("tutor:steps", 6, False), ("tutor:check", 4, False), ("tutor:doc_tasks", 3, False),
    ("tutor:explain", 4, True), ("tutor:ask", 2, True), ("tutor:explain", 1, True),   # Rechnen/Herleiten, Zweitmeinung
)


@dataclass(frozen=True)
class Choice:
    provider: str
    model: str | None = None          # None = Modell des Anbieters aus der Umgebung


# ---------------------------------------------------------------- Konfiguration

def _norm_provider(name: str) -> str | None:
    n = (name or "").strip().lower()
    n = ALIASES.get(n, n)
    return n if n in PROVIDERS else None


def parse_route(raw) -> list[tuple[Choice, float]]:
    """"deepseek:65,openai:35" oder [["deepseek", 65], ...] oder {"deepseek": 65}; unbekannte Anbieter und Gewichte <= 0
    fallen weg."""
    items: list[tuple[str, object]] = []
    if isinstance(raw, str):
        for part in raw.split(","):
            name, _, w = part.strip().rpartition(":")
            if not name:                                   # ohne Gewicht: 1
                name, w = w, "1"
            items.append((name, w))
    elif isinstance(raw, dict):
        items = list(raw.items())
    elif isinstance(raw, (list, tuple)):
        for it in raw:
            if isinstance(it, (list, tuple)) and len(it) == 2:
                items.append((str(it[0]), it[1]))
            elif isinstance(it, str):
                items.append((it, 1))
    out: list[tuple[Choice, float]] = []
    for name, w in items:
        prov, _, model = str(name).strip().partition("/")
        p = _norm_provider(prov)
        try:
            weight = float(w)
        except (TypeError, ValueError):
            continue
        if p and weight > 0:
            out.append((Choice(p, model.strip() or None), weight))
    return out


def config() -> dict:
    """Wege, schwerer Weg, schwere Zwecke und Rechen-Regel aus LERNAPP_AI_ROUTES (unlesbares JSON: Standard)."""
    routes = {k: parse_route(v) for k, v in DEFAULT_ROUTES.items()}
    cfg = {"routes": routes, "hard": parse_route(HARD), "hard_purposes": list(HARD_PURPOSES), "math": True}
    raw = (os.environ.get("LERNAPP_AI_ROUTES") or "").strip()
    if not raw:
        return cfg
    try:
        data = json.loads(raw)
    except ValueError:
        return cfg
    if not isinstance(data, dict):
        return cfg
    if "routes" not in data and not ({"hard", "hard_purposes", "math"} & set(data)):
        data = {"routes": data}                         # Kurzform: nur Zweck -> Weg
    for k, v in (data.get("routes") or {}).items():
        r = parse_route(v)
        if r:
            routes[str(k)] = r
    if data.get("hard") is not None and parse_route(data["hard"]):
        cfg["hard"] = parse_route(data["hard"])
    if isinstance(data.get("hard_purposes"), list):
        cfg["hard_purposes"] = [str(x) for x in data["hard_purposes"]]
    if "math" in data:
        cfg["math"] = bool(data["math"])
    return cfg


def disabled() -> set[str]:
    return {p for p in (_norm_provider(x) for x in (os.environ.get("LERNAPP_AI_DISABLED") or "").split(",")) if p}


# ---------------------------------------------------------------- Schwere Faelle

_DERIVE = re.compile(r"\b(herleit\w*|leite\w*\b.{0,40}\bher|beweis\w*|beweise|zeige,? dass|rechne\w*|berechne\w*|ableit\w*|"
                     r"integrier\w*|integral|differenzier\w*|l(ö|oe)se die gleichung|umform\w*|proof|prove|derive|derivation|"
                     r"compute|calculate)\b", re.IGNORECASE)
_MATH_MARK = re.compile(r"\\(frac|int|sum|sqrt|partial|lim|cdot|infty|alpha|beta|lambda|omega)|[∫∑∏√∂∇≤≥≠≈∞±→⇒]|\^\{?\d|_\{")


def looks_math(text: str | None) -> bool:
    """Frage nach Rechnen oder Herleiten: Schluesselwort (herleiten, beweisen, berechnen, ...) oder viele Formelzeichen
    (mindestens 6 und mehr als 15 je 1000 Zeichen). Feste Regel ohne KI."""
    t = text or ""
    if not t.strip():
        return False
    if _DERIVE.search(t):
        return True
    marks = len(_MATH_MARK.findall(t))
    return marks >= 6 and marks * 1000 / max(1, len(t)) > 15


def is_hard(purpose: str, route_text: str | None = None, hint: str | None = None, cfg: dict | None = None) -> bool:
    cfg = cfg or config()
    if (hint or "") in HARD_HINTS:
        return True
    if purpose in cfg["hard_purposes"]:
        return True
    return bool(cfg["math"]) and purpose in MATH_PURPOSES and looks_math(route_text)


# ---------------------------------------------------------------- Wahl

def route_for(purpose: str, cfg: dict | None = None) -> list[tuple[Choice, float]]:
    cfg = cfg or config()
    routes = cfg["routes"]
    if purpose in routes:
        return routes[purpose]
    head = purpose.split(":", 1)[0]
    for key in (f"{head}:*", head):
        if key in routes:
            return routes[key]
    return routes.get("default") or parse_route(SIMPLE)


def pick(weighted: list[tuple[Choice, float]], seed: str) -> Choice:
    """Deterministisch nach Gewicht: derselbe seed waehlt immer dasselbe."""
    total = sum(w for _, w in weighted)
    x = int.from_bytes(hashlib.sha256(seed.encode("utf-8")).digest()[:8], "big") / 2 ** 64 * total
    acc = 0.0
    for c, w in weighted:
        acc += w
        if x < acc:
            return c
    return weighted[-1][0]


def chain(purpose: str, request_id: str, *, configured: set[str], route_text: str | None = None, hint: str | None = None,
          needs_vision: bool = False, vision_ok=None) -> tuple[list[Choice], bool]:
    """Reihenfolge der Anbieter fuer eine Anfrage: [gewaehlt, Ersatz ...] und ob der schwere Weg galt. `configured`:
    eingerichtete Anbieter; `vision_ok(choice) -> bool` prueft bei Bildern das Modell. Leer = keiner verfuegbar."""
    cfg = config()
    hard = is_hard(purpose, route_text, hint, cfg)
    usable = configured - disabled()

    def ok(c: Choice) -> bool:
        return c.provider in usable and (not needs_vision or vision_ok is None or vision_ok(c))
    route = [(c, w) for c, w in (cfg["hard"] if hard else route_for(purpose, cfg)) if ok(c)]
    if not route and hard:                               # schwerer Weg nicht verfuegbar: normaler Weg des Zwecks
        route = [(c, w) for c, w in route_for(purpose, cfg) if ok(c)]
    out: list[Choice] = []
    if route:
        out.append(pick(route, f"{request_id}|{purpose}"))
        for c, _w in sorted(route, key=lambda cw: -cw[1]):
            if c not in out:
                out.append(c)
    for p in PROVIDERS:                                  # letzte Reserve: die uebrigen eingerichteten Anbieter
        c = Choice(p)
        if ok(c) and all(x.provider != p for x in out):
            out.append(c)
    return out, hard


def expected_share(mix=TYPICAL_MIX, configured: set[str] | None = None) -> dict[str, float]:
    """Erwarteter Anteil der Anfragen je Anbieter fuer eine Nutzungsmischung (Zweck, Anteil, schwer nach Inhalt)."""
    cfg = config()
    usable = (configured if configured is not None else set(PROVIDERS)) - disabled()
    share = {p: 0.0 for p in PROVIDERS}
    total = sum(w for _, w, _ in mix) or 1
    for purpose, weight, content_hard in mix:
        hard = content_hard or purpose in cfg["hard_purposes"]
        route = [(c, w) for c, w in (cfg["hard"] if hard else route_for(purpose, cfg)) if c.provider in usable]
        if not route and hard:
            route = [(c, w) for c, w in route_for(purpose, cfg) if c.provider in usable]
        s = sum(w for _, w in route)
        for c, w in route:
            share[c.provider] += weight / total * w / s
    return {p: round(v, 4) for p, v in share.items()}
