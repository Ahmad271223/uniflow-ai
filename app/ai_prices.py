"""Preise der Modelle fuer die StudiNow-KI: die EINE Stelle, an der der Dienst Kosten ausrechnet.

PRUEFEN VOR START (und bei jedem Modellwechsel): die Zahlen in PRICES mit den Preislisten vergleichen (SOURCE, Stand
CHECKED). OpenAI und Anthropic/Bedrock rechnen in US-Dollar, Scaleway (DeepSeek in der EU) in Euro, jeweils je 1 Mio.
Tokens; der Dienst rechnet in Euro-Cent (1 Credit = 0,9 Cent echter KI-Kosten, app/credits.py). Ohne Preis fuer das
Modell sperrt der Dienst die KI (fail closed). Modellmischung: docs/KI-MODELLMISCHUNG-2026-11-05.md, app/ai_router.py.

Umgebung (deploy/.env, alles optional):
    LERNAPP_AI_PRICES        JSON, ueberschreibt/ergaenzt die Tabelle je Modell (USD je 1 Mio. Tokens), z. B.
                             {"gpt-6-luna": {"input": 0.1, "cached_input": 0.01, "output": 0.5}}; mit "currency": "EUR"
                             fuer Preise in Euro (wie Scaleway)
    LERNAPP_AI_USD_EUR       Umrechnung USD -> EUR (Standard 1.0: ein Dollar zaehlt als ein Euro. Das ist absichtlich
                             vorsichtig: der Dollar ist weniger wert als der Euro, die echten Kosten liegen also eher
                             unter dem, was der Dienst zaehlt; ein Konto kostet so sicher hoechstens die Credits.)
    LERNAPP_AI_PRICE_IN_EUR / LERNAPP_AI_PRICE_OUT_EUR
                             aeltere Angabe: EUR je 1 Mio. Tokens fuer alle Modelle. Nur wenn BEIDE > 0 sind, gelten sie
                             statt der Tabelle (zwischengespeicherte Eingabe dann zum vollen Eingabepreis).

    OpenAI mit EU-Datenresidenz (LERNAPP_OPENAI_BASE_URL auf eu.api.openai.com): +10 % auf alle OpenAI-Preise, von selbst.

Nie dem Client glauben: Kosten entstehen hier nur aus den Zahlen, die der Anbieter in `usage` zurueckgibt (input_tokens
inklusive cached_tokens, output_tokens inklusive Denk-Tokens), vor dem Aufruf aus der Obergrenze `worst_case_microeur`
(harte Grenze je Konto: was reserviert ist, kann eine Anfrage hoechstens kosten).
"""
from __future__ import annotations

import json
import math
import os
import re
import struct
from dataclasses import dataclass

CHECKED = "2026-11-05"
SOURCE = ("OpenAI: https://developers.openai.com/api/docs/pricing (Standard, kurzer Kontext <= 272K Tokens; Bilder: "
          "guides/images-vision); Scaleway (DeepSeek, EUR): oeffentlicher Katalog api.scaleway.com/product-catalog/v2alpha1/"
          "public-catalog/products?product_types=generative_apis; Claude: AWS-Preisliste Bedrock eu-central-1, EU-Endpunkt "
          "(+10 % gegenueber platform.claude.com/docs/en/about-claude/pricing)")

# USD je 1 Mio. Tokens. image: ("patch", Faktor) = 32-px-Kacheln mal Faktor, hoechstens 2.500 Kacheln bei detail=high;
# ("tile", Grund, je Kachel) = 512-px-Kacheln nach Skalierung (kurze Seite 768 px). reasoning: Denkmodell (dann sendet
# der Dienst reasoning.effort, app/ai_backend.py).
PRICES: dict[str, dict] = {
    # guenstig, fuer Fragen, Karteikarten und den Dokument-Index empfohlen
    "gpt-6-luna": {"input": 0.10, "cached_input": 0.01, "output": 0.50, "image": ("patch", 1.2), "reasoning": True},
    "gpt-5.6-luna": {"input": 0.20, "cached_input": 0.02, "output": 1.20, "image": ("patch", 1.2), "reasoning": True},
    "gpt-5.4-nano": {"input": 0.20, "cached_input": 0.02, "output": 1.25, "image": ("patch", 1.2), "reasoning": True},
    "gpt-5-nano": {"input": 0.05, "cached_input": 0.005, "output": 0.40, "image": ("patch", 1.5), "reasoning": True},
    "gpt-5-mini": {"input": 0.25, "cached_input": 0.025, "output": 2.00, "image": ("patch", 1.2), "reasoning": True},
    "gpt-5.4-mini": {"input": 0.75, "cached_input": 0.075, "output": 4.50, "image": ("patch", 1.2), "reasoning": True},
    "gpt-4.1-mini": {"input": 0.40, "cached_input": 0.10, "output": 1.60, "image": ("patch", 1.62), "reasoning": False},
    "gpt-4o-mini": {"input": 0.15, "cached_input": 0.075, "output": 0.60, "image": ("tile", 2833, 5667), "reasoning": False},
    # mittel
    "gpt-6.1-terra": {"input": 1.00, "cached_input": 0.05, "output": 5.00, "image": ("patch", 1.2), "reasoning": True},
    "gpt-5.6-terra": {"input": 2.00, "cached_input": 0.20, "output": 12.00, "image": ("patch", 1.2), "reasoning": True},
    "gpt-5": {"input": 1.25, "cached_input": 0.125, "output": 10.00, "image": ("tile", 70, 140), "reasoning": True},
    "gpt-5.1": {"input": 1.25, "cached_input": 0.125, "output": 10.00, "image": ("tile", 70, 140), "reasoning": True},
    "gpt-4.1": {"input": 2.00, "cached_input": 0.50, "output": 8.00, "image": ("tile", 85, 170), "reasoning": False},
    # teuer (fuer 1 EUR je Konto und Monat ungeeignet; nur der Vollstaendigkeit halber, damit nichts ungezaehlt bleibt)
    "gpt-6.1-sol": {"input": 2.00, "cached_input": 0.10, "output": 10.00, "image": ("patch", 1.2), "reasoning": True},
    "gpt-6-sol": {"input": 2.00, "cached_input": 0.20, "output": 10.00, "image": ("patch", 1.2), "reasoning": True},
    "gpt-5.2": {"input": 1.75, "cached_input": 0.175, "output": 14.00, "image": ("patch", 1.2), "reasoning": True},
    "gpt-5.4": {"input": 2.50, "cached_input": 0.25, "output": 15.00, "image": ("patch", 1.2), "reasoning": True},
    "gpt-5.5": {"input": 5.00, "cached_input": 0.50, "output": 30.00, "image": ("patch", 1.2), "reasoning": True},
    "gpt-5.6-sol": {"input": 4.00, "cached_input": 0.40, "output": 20.00, "image": ("patch", 1.2), "reasoning": True},
    "gpt-6-astra": {"input": 10.00, "cached_input": 1.00, "output": 50.00, "image": ("patch", 1.2), "reasoning": True},
    # DeepSeek (offene Gewichte) bei Scaleway in Paris, Preise in EURO (Katalog 05.11.2026, Status "preview"); Denk-Tokens
    # zaehlen als Ausgabe. V4.1-Flash liest auch Bilder, V4-Flash nur Text.
    "deepseek-v4.1-flash-1017": {"input": 0.60, "cached_input": 0.12, "output": 1.80, "currency": "EUR", "provider": "deepseek",
                                 "image": ("fixed", 8000), "vision": True, "reasoning": True},
    "deepseek-v4-flash-0731": {"input": 0.40, "cached_input": 0.08, "output": 0.80, "currency": "EUR", "provider": "deepseek",
                               "image": ("fixed", 8000), "vision": False, "reasoning": True},
    # Claude Sonnet 5.5 ueber Amazon Bedrock, eu-central-1, EU-Endpunkt (USD, +10 % Regionalaufschlag; direkt bei Anthropic
    # 2.00/0.10/10.00, aber ohne EU-Verarbeitung). Bilder: Pixel/750 Tokens, hoechstens etwa 5.000.
    "claude-sonnet-5-5": {"input": 2.20, "cached_input": 0.11, "output": 11.00, "provider": "anthropic", "image": ("fixed", 5000),
                          "vision": True, "reasoning": True},
}

# Empfehlung fuer den Start (Kosten je typischer Anfrage siehe docs/START-DIENST-CHECKLISTE.md, Abschnitt KI-Kosten)
RECOMMENDED = "gpt-6-luna"
# Empfehlung je Anbieter der Modellmischung (app/ai_router.py)
RECOMMENDED_BY_PROVIDER = {"openai": "gpt-6-luna", "deepseek": "deepseek-v4.1-flash-1017", "anthropic": "claude-sonnet-5-5"}

# 1 Credit = 0,9 Cent = 9.000 Millionstel Euro (Entscheidung des Inhabers 08.11.2026: Pro AI zeigt 100 Credits im Monat,
# die echten KI-Kosten je Konto bleiben dabei unter 0,90 EUR; die Probe mit 25 Credits unter 0,23 EUR)
MICROEUR_PER_CREDIT = 9_000
# Schaetzung vor dem Aufruf: Zeichen je Token (deutscher Text liegt bei etwa 4; 3 ist vorsichtig) und Aufschlag je Anfrage
CHARS_PER_TOKEN = 3
OVERHEAD_TOKENS = 64
# Bild ohne lesbare Groesse: so viele Tokens annehmen (Hoechstwert der Kachelmodelle bei detail=high: 2.500 x 1,2)
IMAGE_TOKENS_FALLBACK = 3000
# Obergrenze vor dem Aufruf (harte Grenze je Konto): ein Token umfasst bei allen Byte-BPE-Tokenizern (OpenAI, Claude,
# DeepSeek) mindestens ein Byte UTF-8 - mehr Eingabe-Tokens als Bytes kann eine Anfrage nicht haben. Dazu ein Aufschlag
# fuer Rollen, Vorlage und das JSON-Schema der Antwort.
WORST_OVERHEAD_TOKENS = 512
# Bild im schlimmsten Fall, wenn das Modell keine eigene Regel hat
IMAGE_TOKENS_WORST = 8000
PATCH = 32
PATCH_BUDGET_HIGH = 2500


@dataclass(frozen=True)
class Price:
    """EUR je 1 Mio. Tokens (= Millionstel Euro je Token)."""
    model: str
    input_eur: float
    cached_eur: float
    output_eur: float
    image: tuple
    reasoning: bool
    source: str                      # table | env | legacy
    provider: str = "openai"         # openai | deepseek | anthropic (app/ai_router.py)
    vision: bool = True              # liest Bilder (sonst leitet der Router Anfragen mit Bild woanders hin)


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default) or default)
    except ValueError:
        return default


def usd_to_eur() -> float:
    v = _env_float("LERNAPP_AI_USD_EUR", 1.0)
    return v if v > 0 else 1.0


def table() -> dict[str, dict]:
    """Tabelle mit den Ueberschreibungen aus LERNAPP_AI_PRICES (unlesbares JSON wird ignoriert)."""
    out = {k: dict(v) for k, v in PRICES.items()}
    raw = (os.environ.get("LERNAPP_AI_PRICES") or "").strip()
    if raw:
        try:
            extra = json.loads(raw)
        except ValueError:
            extra = {}
        for name, p in (extra.items() if isinstance(extra, dict) else []):
            if not isinstance(p, dict):
                continue
            try:
                entry = {**out.get(name, {"image": ("patch", 1.2), "reasoning": False}),
                         **{k: float(p[k]) for k in ("input", "cached_input", "output") if k in p}, "_env": True}
            except (TypeError, ValueError):
                continue
            if "reasoning" in p:
                entry["reasoning"] = bool(p["reasoning"])
            for k in ("currency", "provider"):
                if isinstance(p.get(k), str):
                    entry[k] = p[k].strip().lower() if k == "provider" else p[k].strip().upper()
            if "vision" in p:
                entry["vision"] = bool(p["vision"])
            entry.setdefault("cached_input", entry.get("input"))
            if all(isinstance(entry.get(k), float | int) and entry[k] >= 0 for k in ("input", "cached_input", "output")):
                out[str(name)] = entry
    return out


def legacy_eur() -> tuple[float, float] | None:
    pin, pout = _env_float("LERNAPP_AI_PRICE_IN_EUR", 0.0), _env_float("LERNAPP_AI_PRICE_OUT_EUR", 0.0)
    return (pin, pout) if pin > 0 and pout > 0 else None


_DATED = re.compile(r"-(\d{4}-\d{2}-\d{2}|\d{8}|latest)$")


_PREFIX = re.compile(r"^((eu|us|global|apac)\.)?(anthropic\.)?")
_BEDROCK_VERSION = re.compile(r"-v\d+(:\d+)?$")


def _lookup(name: str, t: dict) -> tuple[str, dict] | None:
    """Exakt, sonst ohne Datums-Endung (gpt-5-mini-2025-08-07 -> gpt-5-mini) und ohne die Vorsaetze von Bedrock
    (eu.anthropic.claude-sonnet-5-5-v1:0 -> claude-sonnet-5-5)."""
    n = (name or "").strip().lower()
    if not n:
        return None
    if n in t:
        return n, t[n]
    for base in (_DATED.sub("", n), _BEDROCK_VERSION.sub("", _PREFIX.sub("", n))):
        if base in t:
            return base, t[base]
        if _DATED.sub("", base) in t:
            return _DATED.sub("", base), t[_DATED.sub("", base)]
    return None


def provider_of(model: str | None) -> str:
    """Anbieter eines Modells laut Tabelle (Standard openai; claude-* -> anthropic, deepseek-* -> deepseek)."""
    hit = _lookup(model or "", table())
    if hit and hit[1].get("provider"):
        return hit[1]["provider"]
    n = (model or "").lower()
    return "anthropic" if "claude" in n else "deepseek" if "deepseek" in n else "openai"


def provider_factor(provider: str) -> float:
    """Aufschlag je Anbieter: OpenAI mit EU-Datenresidenz (eu.api.openai.com) +10 % (Doku "your-data", 05.11.2026)."""
    if provider == "openai" and "eu.api.openai.com" in (os.environ.get("LERNAPP_OPENAI_BASE_URL") or "").lower():
        return 1.10
    return 1.0


def price(model: str | None) -> Price | None:
    """Preis eines Modells in EUR; None = unbekannt (dann sperrt der Dienst)."""
    t = table()
    hit = _lookup(model or "", t)
    legacy = legacy_eur()
    prov = provider_of(model)
    if legacy:
        image = hit[1].get("image", ("patch", 1.2)) if hit else ("patch", 1.2)
        reasoning = bool(hit[1].get("reasoning")) if hit else False
        vision = bool(hit[1].get("vision", True)) if hit else True
        return Price(model or "", legacy[0], legacy[0], legacy[1], tuple(image), reasoning, "legacy", prov, vision)
    if not hit:
        return None
    name, p = hit
    # Euro-Preise (Scaleway) bleiben Euro; Dollar zaehlen nach LERNAPP_AI_USD_EUR (Standard 1:1, vorsichtig)
    r = (1.0 if str(p.get("currency") or "USD").upper() == "EUR" else usd_to_eur()) * provider_factor(prov)
    return Price(name, p["input"] * r, p.get("cached_input", p["input"]) * r, p["output"] * r, tuple(p.get("image") or ("patch", 1.2)),
                 bool(p.get("reasoning")), "env" if p.get("_env") else "table", prov, bool(p.get("vision", True)))


def known(model: str | None) -> bool:
    return price(model) is not None


def cost_microeur(model: str | None, input_tokens: int, output_tokens: int, cached_tokens: int = 0) -> int:
    """Kosten einer Antwort in Millionstel Euro aus der echten Nutzung. `input_tokens` enthaelt die zwischengespeicherten
    (`cached_tokens`) wie bei OpenAI. Unbekanntes Modell: 0 (der Dienst laesst es gar nicht erst zu, siehe known)."""
    p = price(model)
    if p is None:
        return 0
    i, c, o = max(0, int(input_tokens or 0)), max(0, int(cached_tokens or 0)), max(0, int(output_tokens or 0))
    c = min(c, i)
    return int(round((i - c) * p.input_eur + c * p.cached_eur + o * p.output_eur))


def credits_for(microeur: int) -> int:
    """Credits (ganze Cent) fuer Kosten in Millionstel Euro: immer aufgerundet."""
    return max(0, math.ceil(max(0, int(microeur)) / MICROEUR_PER_CREDIT))


# ---------------------------------------------------------------- Schaetzung vor dem Aufruf

def image_size(data: bytes | None) -> tuple[int, int] | None:
    """Breite und Hoehe aus dem Kopf eines PNG oder JPEG (ohne Bildbibliothek); None, wenn nicht lesbar."""
    if not data:
        return None
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        w, h = struct.unpack(">II", data[16:24])
        return (w, h) if w and h else None
    if data[:3] == b"\xff\xd8\xff":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            seg = struct.unpack(">H", data[i + 2:i + 4])[0]
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return (w, h) if w and h else None
            i += 2 + seg
    return None


def image_mime(data: bytes | None) -> str | None:
    if not data:
        return None
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    return None


def image_tokens(model: str | None, size: tuple[int, int] | None, detail: str = "high") -> int:
    """Eingabe-Tokens eines Bildes nach den Regeln von OpenAI (Kacheln zu 32 px mal Faktor, hoechstens 2.500 bei high;
    oder 512-px-Kacheln). Ohne Groesse IMAGE_TOKENS_FALLBACK. Nur fuer die Schaetzung, abgerechnet wird `usage`."""
    p = price(model)
    rule = p.image if p else ("patch", 1.2)
    if rule[0] == "fixed":
        return int(rule[1])
    if not size:
        return IMAGE_TOKENS_FALLBACK
    w, h = max(1, size[0]), max(1, size[1])
    if rule[0] == "tile":
        base, per = rule[1], rule[2]
        if detail == "low":
            return int(base)
        s = min(1.0, 2048 / max(w, h))
        w, h = w * s, h * s
        if min(w, h) > 768:
            s = 768 / min(w, h)
            w, h = w * s, h * s
        return int(base + per * math.ceil(w / 512) * math.ceil(h / 512))
    factor = float(rule[1])
    if detail == "low":
        s = min(1.0, 512 / max(w, h))
        w, h = int(w * s), int(h * s)
    else:
        s = min(1.0, 2048 / max(w, h))
        w, h = int(w * s), int(h * s)
    patches = math.ceil(w / PATCH) * math.ceil(h / PATCH)
    if detail != "low" and patches > PATCH_BUDGET_HIGH:
        s = math.sqrt(PATCH_BUDGET_HIGH / patches)
        w, h = int(w * s), int(h * s)
        patches = min(PATCH_BUDGET_HIGH, math.ceil(w / PATCH) * math.ceil(h / PATCH))
    return math.ceil(patches * factor)


def estimate_input_tokens(*texts: str) -> int:
    return OVERHEAD_TOKENS + sum(math.ceil(len(t or "") / CHARS_PER_TOKEN) for t in texts)


def estimate_microeur(model: str | None, system: str, prompt: str, max_output_tokens: int,
                      images: list[bytes] | None = None, detail: str = "high") -> int:
    """Vorsichtige Obergrenze vor dem Aufruf: alle Eingabe-Tokens zum vollen Preis (kein Cache), Bilder nach ihrer Groesse,
    die Ausgabe bis max_output_tokens."""
    p = price(model)
    if p is None:
        return 0
    tokens_in = estimate_input_tokens(system, prompt) + sum(image_tokens(model, image_size(b), detail) for b in (images or []))
    return int(math.ceil(tokens_in * p.input_eur + max(0, int(max_output_tokens)) * p.output_eur))


def image_tokens_worst(model: str | None) -> int:
    """Eingabe-Tokens eines Bildes im schlimmsten Fall (fuer die harte Obergrenze)."""
    p = price(model)
    rule = p.image if p else ("fixed", IMAGE_TOKENS_WORST)
    if rule[0] == "fixed":
        return int(rule[1])
    if rule[0] == "patch":
        return math.ceil(PATCH_BUDGET_HIGH * float(rule[1])) + 100
    return int(rule[1] + rule[2] * 4 * 2) + 100                       # 512-px-Kacheln: hoechstens 2 x 4 nach Skalierung


def worst_input_tokens(system: str, prompt: str, schema: dict | None = None, images: int = 0, model: str | None = None) -> int:
    """Hoechstens so viele Eingabe-Tokens: Bytes in UTF-8 (ein Token >= ein Byte) plus Aufschlag plus Bilder."""
    n = sum(len((t or "").encode("utf-8")) for t in (system, prompt))
    if schema:
        n += len(json.dumps(schema, ensure_ascii=False).encode("utf-8"))
    return n + WORST_OVERHEAD_TOKENS + max(0, int(images)) * image_tokens_worst(model)


def worst_case_microeur(model: str | None, system: str, prompt: str, max_output_tokens: int, images: list[bytes] | None = None,
                        schema: dict | None = None) -> int:
    """Harte Obergrenze vor dem Aufruf in Millionstel Euro: alle Eingabe-Tokens hoechstens so viele wie Bytes, zum vollen
    Preis (kein Cache), Bilder im schlimmsten Fall, die Ausgabe bis max_output_tokens (bei allen Anbietern inklusive der
    Denk-Tokens: max_output_tokens bei OpenAI, max_tokens bei Claude und Scaleway). Unbekanntes Modell: 0 (gesperrt)."""
    p = price(model)
    if p is None:
        return 0
    tokens_in = worst_input_tokens(system, prompt, schema, len(images or []), model)
    return int(math.ceil(tokens_in * p.input_eur + max(0, int(max_output_tokens)) * p.output_eur))


def max_output_within(model: str | None, system: str, prompt: str, budget_microeur: int, images: list[bytes] | None = None,
                      schema: dict | None = None) -> int:
    """Groesste Ausgabegrenze, deren Obergrenze in `budget_microeur` passt (0, wenn schon die Eingabe nicht passt)."""
    p = price(model)
    if p is None or p.output_eur <= 0:
        return 0
    rest = budget_microeur - worst_case_microeur(model, system, prompt, 0, images, schema)
    return max(0, int(math.floor(rest / p.output_eur)))


def estimate_credits(model: str | None, system: str, prompt: str, max_output_tokens: int, images: list[bytes] | None = None,
                     schema: dict | None = None) -> int:
    """Reservierung in Credits vor dem Aufruf: die harte Obergrenze (worst_case_microeur), aufgerundet, mindestens 1. Die
    echten Kosten koennen nie darueber liegen; abgerechnet wird danach `usage` (app/credits.py gibt den Rest frei)."""
    return max(1, credits_for(worst_case_microeur(model, system, prompt, max_output_tokens, images, schema)))


def listing() -> list[dict]:
    """Tabelle fuer die Betriebsansicht (EUR je 1 Mio. Tokens nach Umrechnung)."""
    out = []
    for name in sorted(table()):
        p = price(name)
        if p:
            out.append({"model": name, "input_eur": round(p.input_eur, 6), "cached_input_eur": round(p.cached_eur, 6),
                        "output_eur": round(p.output_eur, 6), "source": p.source, "reasoning": p.reasoning,
                        "provider": p.provider, "vision": p.vision})
    return out
