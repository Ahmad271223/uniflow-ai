#!/usr/bin/env python3
"""KI-Vergleich: Wer generiert bessere Antworten – DeepSeek, OpenAI gpt-6-luna oder Claude Sonnet 5.5?
(docs/KI-VERGLEICH-2026-11-05.md)

Jede Aufgabe (tools/ki_vergleich_tasks.py, ~20 Stueck) geht einmal an jedes Modell, mit DEMSELBEN System-Text, Prompt,
Antwortschema und derselben Ausgabegrenze wie in der App: Prompt-Bausteine aus app/ai.py (Tutor-Modi explain/steps,
flashcards_prompt, _test_prompt, grade_prompt) und app/doc_explain.py (ganzes Dokument), Obergrenzen aus
app/ai_backend.MAX_OUTPUT bzw. doc_explain.MAX_OUTPUT. Gesendet wird ueber die Anbieter-Klassen des Dienstes
(ai_backend.OpenAIProvider, ai_providers.AnthropicProvider, ai_providers.OpenAICompatProvider fuer DeepSeek).

Schluessel nur aus Dateien unter ~/Studora-Builds/keys/ (deepseek.key, openai.key, bedrock.env); fehlt eine Datei, faellt
der Anbieter weg. Schluessel werden nie ausgegeben, protokolliert oder gespeichert. Die .env des Projekts wird NICHT
geladen.

    .venv/bin/python tools/ki-vergleich.py --dry-run            # alles gegen eine lokale Attrappe, ohne Netz
    .venv/bin/python tools/ki-vergleich.py --estimate           # Kostenschaetzung, ohne Netz
    .venv/bin/python tools/ki-vergleich.py                      # echter Lauf (alle Anbieter mit Schluessel)
    .venv/bin/python tools/ki-vergleich.py --only openai,deepseek --tasks mathe-loesen,et-loesen
    .venv/bin/python tools/ki-vergleich.py auswerten <Laufordner> <bewertung-export.json>

Ergebnis in ~/Studora-Builds/ki-vergleich/<Zeitstempel>/: results.jsonl, answers/<Aufgabe>/<Anbieter>.md, tasks.json,
bewertung.html (Blindbewertung A/B/C), key.json (Zuordnung der Buchstaben; nicht in die HTML), summary.md.
"""
from __future__ import annotations

import argparse
import html
import json
import math
import os
import random
import re
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = Path(__file__).resolve().parent
for p in (str(ROOT), str(TOOLS)):
    if p not in sys.path:
        sys.path.insert(0, p)


def _import_app():
    """app/* importieren, ohne die .env des Projekts (dort liegen Server-Schluessel) und ohne den echten Datenordner."""
    saved = {k: os.environ.get(k) for k in ("LERNAPP_ENV_FILE", "LERNAPP_DATA_DIR", "LERNAPP_LOG_DIR")}
    if "app.config" not in sys.modules:
        os.environ["LERNAPP_ENV_FILE"] = os.devnull
        if not saved["LERNAPP_DATA_DIR"]:
            tmp = tempfile.mkdtemp(prefix="ki-vergleich-")
            os.environ["LERNAPP_DATA_DIR"] = str(Path(tmp) / "data")
            os.environ["LERNAPP_LOG_DIR"] = str(Path(tmp) / "logs")
    try:
        from app import ai, ai_backend, ai_prices, ai_providers, demo, doc_explain
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    return ai, ai_backend, ai_prices, ai_providers, demo, doc_explain


ai, ai_backend, ai_prices, ai_providers, demo, de = _import_app()
import ki_vergleich_tasks  # noqa: E402

KEYS_DIR = Path.home() / "Studora-Builds" / "keys"
OUT_BASE = Path.home() / "Studora-Builds" / "ki-vergleich"

# ---------------------------------------------------------------- Anbieter, Modelle, Preise, Budget

DEEPSEEK_URL = "https://api.deepseek.com"
# USD je 1 Mio. Tokens (Preistabelle des Inhabers, 05.11.2026). Spitzenzeit Mo–Fr 01–04 und 06–10 UTC.
DEEPSEEK_PRICES = {"offpeak": {"miss": 0.15, "hit": 0.003, "out": 0.60},
                   "peak": {"miss": 0.30, "hit": 0.006, "out": 1.20}}
PEAK_HOURS_UTC = set(range(1, 4)) | set(range(6, 10))       # [01:00, 04:00) und [06:00, 10:00)


@dataclass
class ProviderSpec:
    name: str
    label: str
    model: str
    cap_usd: float


PROVIDERS = {
    "deepseek": ProviderSpec("deepseek", "DeepSeek", "deepseek-flash", 1.50),
    "openai": ProviderSpec("openai", "OpenAI", "gpt-6-luna", 1.50),
    "bedrock": ProviderSpec("bedrock", "Claude (Bedrock)", "anthropic.claude-sonnet-5-5", 3.00),
}
BEDROCK_ENV_KEYS = ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_BEARER_TOKEN_BEDROCK", "AWS_REGION",
                    "BEDROCK_MODEL")


def is_peak(t: datetime) -> bool:
    t = t.astimezone(timezone.utc)
    return t.weekday() < 5 and t.hour in PEAK_HOURS_UTC


def usd_prices(provider: str, t: datetime) -> dict:
    """{"in", "cached", "out"} USD je 1 Mio. Tokens zum Zeitpunkt t; DeepSeek nach Tageszeit."""
    if provider == "deepseek":
        p = DEEPSEEK_PRICES["peak" if is_peak(t) else "offpeak"]
        return {"in": p["miss"], "cached": p["hit"], "out": p["out"]}
    table = ai_prices.PRICES["gpt-6-luna" if provider == "openai" else "claude-sonnet-5-5"]
    return {"in": table["input"], "cached": table["cached_input"], "out": table["output"]}


def cost_usd(provider: str, t: datetime, input_tokens: int, cached_tokens: int, output_tokens: int) -> float:
    """input_tokens inklusive cached_tokens (Cache-Treffer), output_tokens inklusive Denk-Tokens."""
    p = usd_prices(provider, t)
    cached = min(max(0, cached_tokens), max(0, input_tokens))
    return ((input_tokens - cached) * p["in"] + cached * p["cached"] + output_tokens * p["out"]) / 1e6


def worst_case_usd(provider: str, system: str, prompt: str, max_output: int) -> float:
    """Obergrenze vor dem Aufruf (wie ai_prices.worst_case_microeur): Eingabe-Tokens <= Bytes + Aufschlag, Spitzenpreis,
    volle Ausgabegrenze."""
    tokens_in = len((system + prompt).encode("utf-8")) + ai_prices.WORST_OVERHEAD_TOKENS
    if provider == "deepseek":
        p = DEEPSEEK_PRICES["peak"]
        return (tokens_in * p["miss"] + max_output * p["out"]) / 1e6
    p = usd_prices(provider, datetime.now(timezone.utc))
    return (tokens_in * p["in"] + max_output * p["out"]) / 1e6


# ---------------------------------------------------------------- Schluessel (nur aus Dateien, nie ausgeben)

def _read_secret(path: Path) -> str | None:
    try:
        v = path.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, IsADirectoryError, PermissionError):
        return None
    return v or None


def read_bedrock_env(path: Path) -> dict | None:
    """KEY=VALUE-Zeilen (nur BEDROCK_ENV_KEYS); None ohne Datei oder ohne Zugangsdaten."""
    raw = _read_secret(path)
    if raw is None:
        return None
    out = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip().removeprefix("export ").strip()
        v = v.strip().strip('"').strip("'")
        if k in BEDROCK_ENV_KEYS and v:
            out[k] = v
    if not (out.get("AWS_BEARER_TOKEN_BEDROCK") or (out.get("AWS_ACCESS_KEY_ID") and out.get("AWS_SECRET_ACCESS_KEY"))):
        return None
    return out


def load_credentials(keys_dir: Path) -> dict:
    """{"deepseek": key, "openai": key, "bedrock": {...}} – nur vorhandene."""
    creds = {}
    if k := _read_secret(keys_dir / "deepseek.key"):
        creds["deepseek"] = k
    if k := _read_secret(keys_dir / "openai.key"):
        creds["openai"] = k
    if b := read_bedrock_env(keys_dir / "bedrock.env"):
        creds["bedrock"] = b
    return creds


def secrets_of(creds: dict) -> list[str]:
    out = []
    for v in creds.values():
        if isinstance(v, str):
            out.append(v)
        elif isinstance(v, dict):
            out += [x for k, x in v.items() if k not in ("AWS_REGION", "BEDROCK_MODEL")]
    return [s for s in out if len(s) >= 6]


def redact(text: str, secrets: list[str]) -> str:
    t = ai_backend.scrub(str(text or ""))
    for s in secrets:
        t = t.replace(s, "***")
    return t


# ---------------------------------------------------------------- Prompts (Bausteine der App)

KIND_NAMES = {"explain": "Erklären", "steps": "Aufgabe lösen", "flashcards": "Karteikarten", "week_test": "Wochentest",
              "grade": "Antworten bewerten", "doc": "Ganzes Dokument"}


def build_prompt(task: dict) -> dict:
    """{system, prompt, schema, max_output, purpose, json, step?} fuer eine Aufgabe – genau wie die App."""
    k = task["kind"]
    if k in ("explain", "steps"):
        mode = "explain" if k == "explain" else "steps"
        prompt = ai.tutor_prompt(mode, task["page_text"], task.get("selection", ""), course=task["course"],
                                 file_name=task["file"], page=task.get("page"))
        return {"system": ai.TUTOR_SYSTEM, "prompt": prompt, "schema": None, "max_output": ai_backend.max_output(f"tutor:{mode}"),
                "purpose": f"tutor:{mode}", "json": False}
    if k == "flashcards":
        prompt = ai.flashcards_prompt(task["course"], task["file"], task.get("pages"), task["text"], task.get("count", 8))
        return {"system": ai.SYSTEM, "prompt": prompt, "schema": ai.FLASHCARDS_SCHEMA, "max_output": ai_backend.max_output("flashcards"),
                "purpose": "flashcards", "json": True}
    if k == "week_test":
        options = ai.week_test_options(task.get("options"))
        prompt = ai._test_prompt(task["subject"], task.get("duration", 30), ai.test_text_block(task["materials"]), "", options)
        return {"system": ai.SYSTEM, "prompt": prompt, "schema": None, "max_output": ai_backend.max_output("weekly_test"),
                "purpose": "weekly_test", "json": True, "options": options}
    if k == "grade":
        prompt = ai.grade_prompt(task["subject"], task["questions"], task["answers"])
        return {"system": ai.SYSTEM, "prompt": prompt, "schema": None, "max_output": ai_backend.max_output("test_grading"),
                "purpose": "test_grading", "json": True}
    if k == "doc":
        texts = task["pages"]
        plan = de.plan_steps("lecture", texts, 1, len(texts))
        if len(plan["steps"]) != 1:
            raise ValueError(f"{task['id']}: Dokument ergibt {len(plan['steps'])} Schritte statt einem")
        step = plan["steps"][0]
        prompt = de.step_prompt(step, len(texts))
        return {"system": de.SYSTEM, "prompt": prompt, "schema": None, "max_output": de.MAX_OUTPUT[step["kind"]],
                "purpose": f"tutor:doc_{step['kind']}", "json": False, "step": {x: step[x] for x in ("kind", "from", "to", "title", "tasks")}}
    raise ValueError(f"unbekannte Art {k}")


def load_tasks() -> list[dict]:
    tasks = ki_vergleich_tasks.build_tasks(demo.FILES)
    for t in tasks:
        t["built"] = build_prompt(t)
    return tasks


# ---------------------------------------------------------------- Automatische Vorpruefung

_FRAC = re.compile(r"\\d?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}")
_SUP = str.maketrans({"²": "^2", "³": "^3", "−": "-", "–": "-", "·": "*", "×": "*", "⋅": "*"})


def normalize(text: str) -> str:
    t = (text or "").translate(_SUP)
    for _ in range(3):
        t = _FRAC.sub(r"(\1)/(\2)", t)
    t = re.sub(r"\\(mid|vert)", "|", t)
    t = re.sub(r"\\(cdot|times)", "*", t)
    t = re.sub(r"\\(text|mathrm|operatorname|mathbf|left|right|displaystyle|quad|qquad)", "", t)
    t = t.replace("\\,", "").replace("\\;", "").replace("\\!", "").replace("\\ ", "").replace("~", "")
    t = t.replace("$", "").replace("{", "").replace("}", "").replace("**", "")
    # Leerraum innerhalb einer Zeile weg ("1011 0110" -> "10110110"), Zeilenumbrueche bleiben (Zahlen am Zeilenende)
    return re.sub(r"[ \t\u00a0\u202f]+", "", t.lower())


def extract_json(text: str):
    """JSON aus der Antwort (wie ai.parse_json; Markdown-Zaeune und Vorspann erlaubt). None, wenn unlesbar."""
    try:
        return ai.parse_json(text)
    except Exception:  # noqa: BLE001
        return None


def mc_key_ok(q: dict) -> bool:
    """MC-Loesung zeigt auf genau eine Option (Buchstabe oder Text)."""
    opts = [str(o).strip() for o in q.get("options") or []]
    ans = str(q.get("answer") or "").strip()
    if not opts or not ans:
        return False
    if ans in opts:
        return True
    m = re.match(r"^\(?([A-Ha-h])[\).:\s]", ans + " ")
    if m:
        letter = m.group(1).upper()
        hits = [o for o in opts if re.match(rf"^\(?{letter}[\).:\s]", o + " ")]
        if len(hits) == 1:
            return True
        if not any(re.match(r"^\(?[A-H][\).:\s]", o + " ") for o in opts):
            return 0 <= ord(letter) - 65 < len(opts)
    return sum(1 for o in opts if ans.lower() in o.lower() or o.lower() in ans.lower()) == 1


def check(task: dict, text: str) -> list[dict]:
    """[{name, ok, detail}] – leere Liste = keine automatische Pruefung moeglich."""
    k, exp, out = task["kind"], task.get("expect") or {}, []
    if k == "steps":
        n = normalize(text)
        for name, pat in exp.get("patterns", []):
            out.append({"name": name, "ok": re.search(pat, n, re.S) is not None, "detail": "Muster im Text (Regex, grob)"})
    elif k == "explain":
        n = (text or "").lower()
        kws = exp.get("keywords") or []
        hit = [w for w in kws if w in n]
        if kws:
            out.append({"name": f"Stichworte {len(hit)}/{len(kws)}", "ok": len(hit) >= math.ceil(0.6 * len(kws)),
                        "detail": "gefunden: " + ", ".join(hit) if hit else "keins gefunden"})
    elif k == "flashcards":
        res = extract_json(text)
        out.append({"name": "gültiges JSON", "ok": res is not None, "detail": ""})
        cards = ai.check_flashcards(res) if res is not None else []
        want = exp.get("count", task.get("count", 8))
        out.append({"name": f"{want} Karten", "ok": len(cards) == want, "detail": f"{len(cards)} Karten mit Frage und Antwort"})
        qs = [c["question"].strip().lower() for c in cards]
        out.append({"name": "keine doppelten Fragen", "ok": len(set(qs)) == len(qs), "detail": ""})
    elif k == "week_test":
        res = extract_json(text)
        out.append({"name": "gültiges JSON", "ok": res is not None, "detail": ""})
        if res is not None:
            why = ai.check_week_test(res, exam=False, options=task["built"]["options"])
            out.append({"name": "Form wie in der App (check_week_test)", "ok": why is None, "detail": why or "in Ordnung"})
            qs = res.get("questions") if isinstance(res, dict) and isinstance(res.get("questions"), list) else []
            mcs = [q for q in qs if isinstance(q, dict) and q.get("type") == "mc"]
            if mcs:
                bad = [str(q.get("nr")) for q in mcs if not mc_key_ok(q)]
                out.append({"name": "MC-Lösung ist eine der Optionen", "ok": not bad,
                            "detail": ("falsch bei Aufgabe " + ", ".join(bad)) if bad else f"{len(mcs)} MC-Aufgaben"})
            pts = sum(q.get("points") for q in qs if isinstance(q, dict) and isinstance(q.get("points"), (int, float))
                      and not isinstance(q.get("points"), bool))
            out.append({"name": "Punkte gesamt = 100", "ok": abs(pts - 100) < 0.01, "detail": f"{pts:g} Punkte"})
    elif k == "grade":
        res = extract_json(text)
        out.append({"name": "gültiges JSON", "ok": isinstance(res, dict), "detail": ""})
        if isinstance(res, dict):
            maxp = sum(q["points"] for q in task["questions"])
            per = {str(x.get("nr")): x for x in res.get("per_question") or [] if isinstance(x, dict)}
            for nr, (lo, hi) in task["expect"].items():
                got = per.get(nr, {}).get("points")
                ok = isinstance(got, (int, float)) and not isinstance(got, bool) and lo - 1e-9 <= got <= hi + 1e-9
                out.append({"name": f"Aufgabe {nr}: {lo:g}" + (f"–{hi:g}" if hi != lo else "") + " P.", "ok": ok,
                            "detail": f"vergeben: {got!r}"})
            total = res.get("total")
            s = sum(x.get("points") for x in per.values() if isinstance(x.get("points"), (int, float)))
            out.append({"name": f"max = {maxp}", "ok": res.get("max") == maxp, "detail": f"angegeben: {res.get('max')!r}"})
            out.append({"name": "total = Summe der Punkte", "ok": isinstance(total, (int, float)) and abs(total - s) < 0.01,
                        "detail": f"total {total!r}, Summe {s:g}"})
    elif k == "doc":
        step = dict(task["built"]["step"])
        blocks = de.parse_blocks(text, step)
        titles = [b["title"].lower() for b in blocks]
        n = len(task["pages"])
        out.append({"name": "beginnt mit Überblick", "ok": bool(titles) and titles[0].startswith("überblick"), "detail": ""})
        out.append({"name": "endet mit Prüfungsrelevant", "ok": bool(titles) and titles[-1].startswith("prüfungsrelevant"), "detail": ""})
        heads = re.findall(r"^#{1,3}[ \t]+.*$", text or "", re.M)
        with_pages = [h for h in heads if de._PAGES_RE.search(h)]
        out.append({"name": "Überschriften mit [S. x]", "ok": bool(heads) and len(with_pages) == len(heads),
                    "detail": f"{len(with_pages)}/{len(heads)} Überschriften mit Seitenangabe"})
        covered = set()
        for b in blocks:
            if b["kind"] == "section":
                covered |= set(range(b["from"], b["to"] + 1))
        out.append({"name": "Abschnitte decken ≥ 8 von 10 Seiten", "ok": len(covered) >= min(8, n),
                    "detail": f"{len(covered)} Seiten in Abschnitten"})
    return out


def auto_status(checks: list[dict]) -> str:
    if not checks:
        return "none"
    return "pass" if all(c["ok"] for c in checks) else "fail"


# ---------------------------------------------------------------- Anbieter (Klassen des Dienstes)

class DeepSeekDirect(ai_providers.OpenAICompatProvider):
    """DeepSeek ueber api.deepseek.com (Auftrag des Inhabers fuer diesen Vergleich; nur erfundene, oeffentliche und
    Demo-Inhalte). Bewusst ohne check_eu_base_url: der Dienst selbst laesst deepseek.com nicht zu (app/ai_providers.py).
    Antwortschema: DeepSeek kennt nur json_object, daher bei Aufgaben mit Schema `response_format: json_object`.
    Nutzung: prompt_cache_hit_tokens zaehlt als Cache-Treffer."""

    def __init__(self, api_key: str, model_name: str, *, transport=None, timeout: int = 180):
        self.base_url, self.api_key, self.model, self.label, self.timeout = DEEPSEEK_URL, api_key, model_name, "deepseek", timeout
        self.transport = transport or ai_backend.urllib_transport
        self.reasoning_effort = None

    def request_body(self, system, prompt, schema=None, *, image=None, max_output_tokens=None) -> dict:
        body = super().request_body(system, prompt, schema, image=image, max_output_tokens=max_output_tokens)
        if schema:
            body["response_format"] = {"type": "json_object"}
        return body

    def _completion(self, text, usage, model, images):
        c = super()._completion(text, usage, model, images)
        u = usage if isinstance(usage, dict) else {}
        if "prompt_cache_hit_tokens" in u:
            c.cached_tokens = ai_providers._n(u.get("prompt_cache_hit_tokens"))
        return c


def make_provider(name: str, creds: dict, dry_task: dict | None = None):
    """Anbieter-Objekt; mit dry_task eine Attrappe ohne Netz (gleiche Klassen, nur der Transport ist ausgetauscht)."""
    spec = PROVIDERS[name]
    if name == "deepseek":
        return DeepSeekDirect(creds.get("deepseek", "stub"), spec.model,
                              transport=stub_chat_transport(dry_task, name) if dry_task else None)
    if name == "openai":
        return ai_backend.OpenAIProvider(creds.get("openai", "stub"), spec.model,
                                         transport=stub_responses_transport(dry_task, name) if dry_task else None, timeout=180)
    if name == "bedrock":
        b = creds.get("bedrock") or {}
        model = b.get("BEDROCK_MODEL") or spec.model
        region = b.get("AWS_REGION") or "eu-central-1"
        if dry_task:
            client = StubAnthropicClient(dry_task, name)
        else:
            if not region.startswith("eu-"):
                raise RuntimeError("Bedrock nur aus einer EU-Region (AWS_REGION=eu-…)")
            import anthropic
            client = anthropic.AnthropicBedrockMantle(
                aws_region=region, api_key=b.get("AWS_BEARER_TOKEN_BEDROCK") or None,
                aws_access_key=b.get("AWS_ACCESS_KEY_ID") or None, aws_secret_key=b.get("AWS_SECRET_ACCESS_KEY") or None,
                aws_session_token=b.get("AWS_SESSION_TOKEN") or None, timeout=180, max_retries=0)
        p = ai_providers.AnthropicProvider(model, backend="bedrock", region=region, client=client)
        return p
    raise ValueError(name)


# ---------------------------------------------------------------- Attrappe (--dry-run, Tests)

def stub_answer(task: dict, provider: str) -> str:
    """Plausible Antwort je Art; je Anbieter leicht verschieden, damit die Vorpruefung auch Fehler zeigt."""
    k = task["kind"]
    flaw = provider == "deepseek"
    if k == "explain":
        kws = (task.get("expect") or {}).get("keywords") or []
        use = kws[:3] if flaw else kws
        return "## Erklärung\n\nKurz gesagt: " + ", ".join(use) + ".\n\n- Schritt 1\n- Schritt 2\n\n**Beispiel:** …"
    if k == "steps":
        names = [n for n, _ in (task.get("expect") or {}).get("patterns", [])]
        if flaw and names:
            names = names[:-1]
        return "## Lösung\n\n" + "\n".join(f"{i + 1}. {n}" for i, n in enumerate(names)) + "\n\nErgebnis siehe oben."
    if k == "flashcards":
        n = task.get("count", 8) - (1 if flaw else 0)
        return json.dumps({"cards": [{"question": f"Was bedeutet Begriff{i + 1} in {task['subject']}?", "answer": f"Antwort {i + 1}.",
                                      "kind": "begriff", "page": 0}
                                     for i in range(n)]}, ensure_ascii=False)
    if k == "week_test":
        o = task["built"]["options"]
        dist = ai.week_test_distribution(o["count"], o["difficulty"])
        diffs = [d for d in ("leicht", "mittel", "schwer") for _ in range(dist[d])]
        types = list(o["types"])
        qs, pts = [], [20] * len(diffs)
        for i, d in enumerate(diffs):
            t = types[i % len(types)]
            q = {"nr": i + 1, "type": t, "difficulty": d, "question": f"Aufgabe {i + 1} ___", "answer": "B Zwei",
                 "explanation": "Weil.", "points": pts[i], "exam_style": False}
            if t == "mc":
                q["options"] = ["A Eins", "B Zwei", "C Drei", "D Vier"]
                if flaw:
                    q["answer"] = "E Fünf"
            if t == "tf":
                q["options"], q["answer"] = ["Wahr", "Falsch"], "Wahr"
            if t == "cloze":
                q["blank"] = q["answer"] = "Zwei"
            qs.append(q)
        return "```json\n" + json.dumps({"title": f"Wochentest {task['subject']}", "questions": qs}, ensure_ascii=False) + "\n```"
    if k == "grade":
        per = []
        for q in task["questions"]:
            lo, hi = task["expect"][str(q["nr"])]
            got = hi if not flaw else (q["points"] if lo == 0 and hi == 0 and q["nr"] == len(task["questions"]) else lo)
            per.append({"nr": q["nr"], "points": got, "max": q["points"], "feedback": "…"})
        total = sum(x["points"] for x in per)
        return json.dumps({"total": total, "max": sum(q["points"] for q in task["questions"]), "per_question": per,
                           "summary": "…", "weak_topics": []}, ensure_ascii=False)
    if k == "doc":
        n = len(task["pages"])
        parts = [f"## Überblick [S. 1–{n}]\nWorum es geht."]
        for a in range(1, n, 3 if not flaw else 5):
            b = min(n, a + 2)
            parts.append(f"## Abschnitt {a} [S. {a}–{b}]\nKernideen mit $x^2$.\nPrüfungsrelevant: …")
        parts.append(f"## Prüfungsrelevant [S. 1–{n}]\n- Punkt (S. 2)")
        return "\n\n".join(parts)
    return "…"


def _stub_usage(task: dict, text: str) -> tuple[int, int]:
    b = task["built"]
    return (len(b["system"]) + len(b["prompt"])) // 4 + 20, max(1, len(text) // 4)


def stub_chat_transport(task: dict, provider: str):
    """Chat Completions als SSE (wie DeepSeek), mit prompt_cache_hit_tokens."""
    def transport(url, headers, body, timeout):
        assert url.startswith("https://api.deepseek.com"), url
        text = stub_answer(task, provider)
        tin, tout = _stub_usage(task, text)
        hit = tin // 3
        lines = []
        for i in range(0, len(text), 40):
            lines += ["data: " + json.dumps({"choices": [{"delta": {"content": text[i:i + 40]}, "finish_reason": None}]}), ""]
        lines += ["data: " + json.dumps({"model": PROVIDERS[provider].model, "choices": [{"delta": {}, "finish_reason": "stop"}],
                                         "usage": {"prompt_tokens": tin, "completion_tokens": tout, "prompt_cache_hit_tokens": hit,
                                                   "prompt_cache_miss_tokens": tin - hit}}), "", "data: [DONE]", ""]
        return 200, iter(lines)
    return transport


def stub_responses_transport(task: dict, provider: str):
    """Responses API als SSE (wie OpenAI)."""
    def transport(url, headers, body, timeout):
        assert url == "https://api.openai.com/v1/responses", url
        text = stub_answer(task, provider)
        tin, tout = _stub_usage(task, text)
        lines = []
        for i in range(0, len(text), 40):
            lines += ["data: " + json.dumps({"type": "response.output_text.delta", "delta": text[i:i + 40]}), ""]
        resp = {"model": PROVIDERS[provider].model, "output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}],
                "usage": {"input_tokens": tin, "output_tokens": tout + 50, "input_tokens_details": {"cached_tokens": 0},
                          "output_tokens_details": {"reasoning_tokens": 50}}}
        lines += ["data: " + json.dumps({"type": "response.completed", "response": resp}), ""]
        return 200, iter(lines)
    return transport


class _NS:
    def __init__(self, **kw):
        self.__dict__.update(kw)


class StubAnthropicClient:
    """Wie anthropic.AnthropicBedrockMantle: messages.stream(**kwargs) als Kontextmanager."""

    def __init__(self, task: dict, provider: str):
        self.task, self.provider = task, provider
        self.messages = self

    def stream(self, **kwargs):
        text = stub_answer(self.task, self.provider)
        tin, tout = _stub_usage(self.task, text)
        msg = _NS(content=[_NS(type="text", text=text)], stop_reason="end_turn", model=PROVIDERS[self.provider].model,
                  usage=_NS(input_tokens=tin, output_tokens=tout, cache_read_input_tokens=0, cache_creation_input_tokens=0))
        chunks = [text[i:i + 40] for i in range(0, len(text), 40)]

        class _Stream:
            def __enter__(s):
                s.text_stream = iter(chunks)
                return s

            def __exit__(s, *a):
                return False

            def get_final_message(s):
                return msg
        return _Stream()


# ---------------------------------------------------------------- Lauf

@dataclass
class Budget:
    cap: float
    spent: float = 0.0
    stopped: str | None = None
    lock: threading.Lock = field(default_factory=threading.Lock)


def run_one(task: dict, provider: str, creds: dict, budget: Budget, dry: bool, secrets: list[str]) -> dict:
    b = task["built"]
    rec = {"task_id": task["id"], "kind": task["kind"], "subject": task["subject"], "provider": provider,
           "model": PROVIDERS[provider].model, "started_at": None, "latency_s": None, "ttft_s": None, "input_tokens": 0,
           "cached_tokens": 0, "output_tokens": 0, "reasoning_tokens": 0, "cost_usd": 0.0, "price_period": None,
           "usage_known": None, "error": None, "skipped": None, "text": ""}
    worst = worst_case_usd(provider, b["system"], b["prompt"], b["max_output"])
    with budget.lock:
        if budget.stopped:
            rec["skipped"] = budget.stopped
            return rec
        if budget.spent + worst > budget.cap:
            budget.stopped = (f"Budget: {budget.spent:.4f} $ ausgegeben, nächste Anfrage bis {worst:.4f} $, "
                              f"Grenze {budget.cap:.2f} $")
            rec["skipped"] = budget.stopped
            return rec
    first = {}

    def on_delta(_piece):
        first.setdefault("t", time.monotonic())
    t_start = datetime.now(timezone.utc)
    rec["started_at"] = t_start.isoformat(timespec="seconds")
    rec["price_period"] = ("peak" if is_peak(t_start) else "offpeak") if provider == "deepseek" else "standard"
    t0 = time.monotonic()
    c = None
    try:
        p = make_provider(provider, creds, dry_task=task if dry else None)
        c = p.complete(b["system"], b["prompt"], b["schema"], max_output_tokens=b["max_output"], on_delta=on_delta)
    except ai_backend.AIUnavailable as e:
        rec["error"] = redact(f"{e.code}: {e.message}", secrets)
        c = getattr(e, "billed", None)
        if c is None and getattr(e, "started", False):
            rec["cost_usd"] = worst                  # angenommen, Nutzung unbekannt: Obergrenze zaehlen
    except Exception as e:  # noqa: BLE001
        rec["error"] = redact(f"{type(e).__name__}: {e}", secrets)[:500]
    rec["latency_s"] = round(time.monotonic() - t0, 2)
    if "t" in first:
        rec["ttft_s"] = round(first["t"] - t0, 2)
    if c is not None:
        rec.update(input_tokens=c.input_tokens, cached_tokens=c.cached_tokens, output_tokens=c.output_tokens,
                   reasoning_tokens=c.reasoning_tokens, usage_known=c.usage_known, model=c.model or rec["model"])
        rec["cost_usd"] = worst if not c.usage_known else cost_usd(provider, t_start, c.input_tokens, c.cached_tokens, c.output_tokens)
        if rec["error"] is None:
            rec["text"] = c.text or ""
    with budget.lock:
        budget.spent += rec["cost_usd"]
    rec["cost_usd"] = round(rec["cost_usd"], 6)
    if rec["error"] is None:
        rec["checks"] = check(task, rec["text"])
        rec["auto"] = auto_status(rec["checks"])
    return rec


def run(tasks: list[dict], providers: list[str], creds: dict, out_dir: Path, dry: bool, caps: dict | None = None,
        seed: int | None = None, log=print) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "answers").mkdir(exist_ok=True)
    secrets = secrets_of(creds)
    budgets = {p: Budget((caps or {}).get(p, PROVIDERS[p].cap_usd)) for p in providers}
    results: dict[tuple[str, str], dict] = {}
    lock = threading.Lock()
    jsonl = (out_dir / "results.jsonl").open("w", encoding="utf-8")

    def worker(provider: str):
        for t in tasks:
            rec = run_one(t, provider, creds, budgets[provider], dry, secrets)
            rec["run"] = out_dir.name
            ans = out_dir / "answers" / t["id"] / f"{provider}.md"
            if rec["error"] is None and rec["skipped"] is None:
                ans.parent.mkdir(parents=True, exist_ok=True)
                ans.write_text(f"# {t['id']} – {PROVIDERS[provider].label} ({rec['model']})\n\n{rec['text']}\n", encoding="utf-8")
                rec["answer_file"] = str(ans.relative_to(out_dir))
            line = {k: v for k, v in rec.items() if k != "text"}
            with lock:
                results[(t["id"], provider)] = rec
                jsonl.write(json.dumps(line, ensure_ascii=False) + "\n")
                jsonl.flush()
            state = rec["skipped"] and "übersprungen" or rec["error"] and f"FEHLER {rec['error'][:80]}" or \
                f"{rec['latency_s']} s, {rec['input_tokens']}+{rec['output_tokens']} Tok., {rec['cost_usd']:.5f} $, auto {rec.get('auto')}"
            log(f"[{provider:8}] {t['id']:20} {state}")
    try:
        with ThreadPoolExecutor(max_workers=len(providers) or 1) as ex:
            list(ex.map(worker, providers))
    finally:
        jsonl.close()
    seed = seed if seed is not None else random.SystemRandom().randrange(1 << 30)
    write_tasks_json(tasks, out_dir)
    key = write_grading_sheet(tasks, providers, results, out_dir, seed)
    summary = write_summary(tasks, providers, results, budgets, out_dir, dry)
    return {"results": results, "key": key, "summary": summary, "budgets": {p: b.spent for p, b in budgets.items()}}


def write_tasks_json(tasks: list[dict], out_dir: Path) -> None:
    rows = []
    for t in tasks:
        b = t["built"]
        rows.append({"id": t["id"], "kind": t["kind"], "subject": t["subject"], "system": b["system"], "prompt": b["prompt"],
                     "schema": b["schema"] is not None, "max_output": b["max_output"], "purpose": b["purpose"],
                     "expect": t.get("expect")})
    (out_dir / "tasks.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1, default=list), encoding="utf-8")


def write_summary(tasks, providers, results, budgets, out_dir: Path, dry: bool) -> str:
    lines = [f"# KI-Vergleich {out_dir.name}" + (" (Attrappe, --dry-run)" if dry else ""), "",
             "| Anbieter | Modell | Antworten | Fehler | übersprungen | Eingabe-Tok. | davon Cache | Ausgabe-Tok. | Kosten $ | "
             "Latenz Median s | Auto ok |", "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for p in providers:
        rs = [results[(t["id"], p)] for t in tasks if (t["id"], p) in results]
        ok = [r for r in rs if not r["error"] and not r["skipped"]]
        lat = sorted(r["latency_s"] for r in ok if r["latency_s"] is not None)
        med = lat[len(lat) // 2] if lat else 0
        autos = [r for r in ok if r.get("auto") in ("pass", "fail")]
        lines.append(f"| {PROVIDERS[p].label} | {PROVIDERS[p].model} | {len(ok)} | {sum(1 for r in rs if r['error'])} | "
                     f"{sum(1 for r in rs if r['skipped'])} | {sum(r['input_tokens'] for r in rs)} | {sum(r['cached_tokens'] for r in rs)} | "
                     f"{sum(r['output_tokens'] for r in rs)} | {budgets[p].spent:.4f} | {med} | "
                     f"{sum(1 for r in autos if r['auto'] == 'pass')}/{len(autos)} |")
    lines += ["", "## Automatische Vorprüfung je Aufgabe", "", "| Aufgabe | Art | " + " | ".join(PROVIDERS[p].label for p in providers) + " |",
              "| --- | --- | " + " | ".join("---" for _ in providers) + " |"]
    for t in tasks:
        cells = []
        for p in providers:
            r = results.get((t["id"], p))
            if not r:
                cells.append("–")
            elif r["skipped"]:
                cells.append("übersprungen")
            elif r["error"]:
                cells.append("Fehler")
            else:
                cs = r.get("checks") or []
                cells.append("–" if not cs else f"{sum(c['ok'] for c in cs)}/{len(cs)}")
        lines.append(f"| {t['id']} | {KIND_NAMES[t['kind']]} | " + " | ".join(cells) + " |")
    stopped = [f"- {PROVIDERS[p].label}: {b.stopped}" for p, b in budgets.items() if b.stopped]
    if stopped:
        lines += ["", "## Budgetgrenze erreicht", ""] + stopped
    text = "\n".join(lines) + "\n"
    (out_dir / "summary.md").write_text(text, encoding="utf-8")
    return text


# ---------------------------------------------------------------- Blindbewertung (statische HTML-Seite)

def assign_labels(tasks, providers, results, seed: int) -> dict:
    """{task_id: {"A": provider, ...}} – je Aufgabe neu gemischt (fester Seed, steht in key.json)."""
    rng = random.Random(seed)
    out = {}
    for t in tasks:
        ps = [p for p in providers if (t["id"], p) in results and not results[(t["id"], p)]["skipped"]]
        rng.shuffle(ps)
        out[t["id"]] = {chr(65 + i): p for i, p in enumerate(ps)}
    return out


def write_grading_sheet(tasks, providers, results, out_dir: Path, seed: int) -> dict:
    labels = assign_labels(tasks, providers, results, seed)
    data = {"run": out_dir.name, "tasks": []}
    for t in tasks:
        b = t["built"]
        answers = []
        for letter, p in labels[t["id"]].items():
            r = results[(t["id"], p)]
            answers.append({"label": letter, "error": bool(r["error"]), "text": r["text"] if not r["error"] else "",
                            "checks": r.get("checks") or [], "auto": r.get("auto")})
        data["tasks"].append({"id": t["id"], "kind": t["kind"], "kindName": KIND_NAMES[t["kind"]], "subject": t["subject"],
                              "system": b["system"], "prompt": b["prompt"], "json": b["json"], "answers": answers})
    key = {"run": out_dir.name, "seed": seed, "labels": labels,
           "models": {p: PROVIDERS[p].model for p in providers}}
    (out_dir / "key.json").write_text(json.dumps(key, ensure_ascii=False, indent=1), encoding="utf-8")
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/").replace("<!--", "<\\!--")
    (out_dir / "bewertung.html").write_text(GRADING_HTML.replace("__TITLE__", html.escape(out_dir.name))
                                            .replace("__DATA__", payload), encoding="utf-8")
    return key


GRADING_HTML = r"""<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>KI-Vergleich blind</title>
<style>
:root{--bg:#f7f7f5;--card:#fff;--ink:#1d1d1f;--mute:#6b6b70;--line:#e2e2e0;--acc:#5b4bd6;--ok:#1f7a4a;--bad:#b3261e;--code:#f0f0ee}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#151517;--card:#1f1f22;--ink:#ececef;--mute:#9a9aa2;--line:#33333a;--acc:#9d93ff;--ok:#5bd08f;--bad:#ff8a80;--code:#2a2a2f}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:10px 16px;display:flex;gap:12px;align-items:center;flex-wrap:wrap}
header h1{font-size:16px;margin:0;flex:1 1 auto}button,label.btn{font:inherit;border:1px solid var(--line);background:var(--card);color:var(--ink);border-radius:8px;padding:5px 10px;cursor:pointer}
main{max-width:1100px;margin:0 auto;padding:16px}nav{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:16px}nav a{font-size:13px;text-decoration:none;color:var(--ink);border:1px solid var(--line);border-radius:999px;padding:2px 9px;background:var(--card)}
nav a.done{border-color:var(--ok);color:var(--ok)}
section.task{scroll-margin-top:110px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:22px}
.meta{color:var(--mute);font-size:13px}details{margin:8px 0}summary{cursor:pointer;color:var(--mute);font-size:13px}
pre{white-space:pre-wrap;word-break:break-word;background:var(--code);padding:10px;border-radius:8px;font-size:12.5px;max-height:420px;overflow:auto}
.answers{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));margin-top:12px}
.ans{border:1px solid var(--line);border-radius:10px;padding:12px;min-width:0}.ans h3{margin:0 0 6px;font-size:18px;color:var(--acc)}
.body{overflow-wrap:anywhere}.body h1,.body h2,.body h3,.body h4{font-size:15px;margin:12px 0 4px}.body code{background:var(--code);padding:0 3px;border-radius:4px}
.body table{border-collapse:collapse}.body td,.body th{border:1px solid var(--line);padding:3px 6px;font-size:13px;vertical-align:top}
.score{display:grid;grid-template-columns:auto 1fr;gap:4px 10px;align-items:center;margin-top:10px;font-size:13px}
.score .opts{display:flex;gap:4px;flex-wrap:wrap}.score input{display:none}.score .opts label{border:1px solid var(--line);border-radius:6px;width:30px;text-align:center;cursor:pointer;padding:2px 0}
.score input:checked+label{background:var(--acc);border-color:var(--acc);color:#fff}
textarea{width:100%;min-height:52px;font:inherit;font-size:13px;margin-top:8px;background:var(--bg);color:var(--ink);border:1px solid var(--line);border-radius:8px;padding:6px}
.chk{font-size:12.5px;margin:2px 0}.chk.ok{color:var(--ok)}.chk.bad{color:var(--bad)}.err{color:var(--bad)}
.card{border-left:3px solid var(--acc);padding:2px 8px;margin:6px 0}
@media (max-width:600px){main{padding:10px 16px}.answers{grid-template-columns:1fr}}
</style></head><body>
<header><h1>KI-Vergleich blind · __TITLE__</h1><span id="progress" class="meta"></span>
<button id="export">Export JSON</button><label class="btn">Import<input id="import" type="file" accept=".json" hidden></label>
<button id="raw">Rohtext</button></header>
<main><p class="meta">Je Aufgabe sind die Antworten gemischt und mit A/B/C beschriftet (Zuordnung steht nur in key.json).
Bewerte 1 (schlecht) bis 5 (sehr gut). Alles wird in diesem Browser gespeichert; „Export JSON“ lädt die Bewertung herunter
(auswerten: <code>tools/ki-vergleich.py auswerten &lt;Laufordner&gt; &lt;export.json&gt;</code>).</p>
<nav id="nav"></nav><div id="tasks"></div></main>
<script id="data" type="application/json">__DATA__</script>
<script>
(function(){
const DATA = JSON.parse(document.getElementById('data').textContent);
const KEY = 'ki-vergleich:' + DATA.run;
const CRIT = [['richtigkeit','Richtigkeit'],['verstaendlichkeit','Verständlichkeit'],['vollstaendigkeit','Vollständigkeit']];
let store = {};
try { store = JSON.parse(localStorage.getItem(KEY) || '{}') || {}; } catch (e) { store = {}; }
let raw = false;
try { raw = localStorage.getItem(KEY + ':raw') === '1'; } catch (e) {}
function save(){ try { localStorage.setItem(KEY, JSON.stringify(store)); } catch (e) {} progress(); }
function esc(s){ return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
function inline(s){
  return s.replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>')
          .replace(/(^|[^*])\*([^*\s][^*]*)\*/g,'$1<em>$2</em>');
}
function md(src){
  const lines = esc(src).split('\n'); let out = [], list = null, code = null, para = [], table = null;
  const flush = () => { if (para.length){ out.push('<p>' + inline(para.join('<br>')) + '</p>'); para = []; }
    if (list){ out.push('</' + list + '>'); list = null; } if (table){ out.push('<table>' + table.join('') + '</table>'); table = null; } };
  for (const l of lines){
    if (code !== null){ if (/^```/.test(l)){ out.push('<pre>' + code.join('\n') + '</pre>'); code = null; } else code.push(l); continue; }
    if (/^```/.test(l)){ flush(); code = []; continue; }
    let m;
    if ((m = l.match(/^(#{1,4})\s+(.*)$/))){ flush(); out.push('<h' + (m[1].length + 1) + '>' + inline(m[2]) + '</h' + (m[1].length + 1) + '>'); continue; }
    if (/^\s*\|.*\|\s*$/.test(l)){ if (/^\s*\|[\s:\-|]+\|\s*$/.test(l)) continue;
      if (!table){ flush(); table = []; } table.push('<tr>' + l.trim().slice(1, -1).split('|').map(c => '<td>' + inline(c.trim()) + '</td>').join('') + '</tr>'); continue; }
    if ((m = l.match(/^\s*([-*•]|\d+[.)])\s+(.*)$/))){ const t = /^\d/.test(m[1]) ? 'ol' : 'ul';
      if (para.length || table){ const keep = list; list = null; flush(); list = keep; }
      if (list !== t){ if (list) out.push('</' + list + '>'); out.push('<' + t + '>'); list = t; }
      out.push('<li>' + inline(m[2]) + '</li>'); continue; }
    if (!l.trim()){ flush(); continue; }
    if (list || table){ flush(); }
    para.push(l);
  }
  if (code !== null) out.push('<pre>' + code.join('\n') + '</pre>');
  flush(); return out.join('');
}
function parseJSON(t){
  let s = String(t || '').trim(); const m = s.match(/```(?:json)?\s*([\s\S]*?)```/); if (m) s = m[1];
  const i = Math.min(...['{','['].map(c => { const k = s.indexOf(c); return k < 0 ? 1e9 : k; }));
  if (i < 1e9) s = s.slice(i);
  try { return JSON.parse(s); } catch (e) { return null; }
}
function renderJSON(task, text){
  const j = parseJSON(text); if (!j) return '<p class="err">Kein gültiges JSON.</p><pre>' + esc(text) + '</pre>';
  if (task.kind === 'flashcards'){ const cards = Array.isArray(j) ? j : (j.cards || []);
    return '<ol>' + cards.map(c => '<li class="card"><strong>' + esc(c.question || '') + '</strong><br>' + esc(c.answer || '') + '</li>').join('') + '</ol>'; }
  if (task.kind === 'week_test'){ const qs = j.questions || [];
    return '<p><strong>' + esc(j.title || '') + '</strong></p><ol>' + qs.map(q => '<li class="card"><span class="meta">' + esc(q.type) + ' · ' + esc(q.difficulty) + ' · ' + esc(q.points) + ' P.</span><br>' +
      esc(q.question || '') + (q.options ? '<br><span class="meta">' + q.options.map(esc).join(' | ') + '</span>' : '') +
      '<br><strong>Lösung:</strong> ' + esc(q.answer || '') + '<br><em>' + esc(q.explanation || '') + '</em></li>').join('') + '</ol>'; }
  if (task.kind === 'grade'){ const per = j.per_question || [];
    return '<p><strong>' + esc(j.total) + ' / ' + esc(j.max) + ' Punkte</strong></p><table>' + per.map(p => '<tr><td>' + esc(p.nr) + '</td><td>' + esc(p.points) + '/' + esc(p.max) + '</td><td>' + esc(p.feedback || '') + '</td></tr>').join('') +
      '</table><p>' + esc(j.summary || '') + '</p>' + ((j.weak_topics || []).length ? '<p class="meta">Schwächen: ' + j.weak_topics.map(esc).join(', ') + '</p>' : ''); }
  return '<pre>' + esc(JSON.stringify(j, null, 2)) + '</pre>';
}
function scoreBox(tid, label){
  const g = (store[tid] || {})[label] || {}; const name = tid + '__' + label;
  let h = '<div class="score">';
  for (const [k, n] of CRIT){ h += '<span>' + n + '</span><span class="opts">';
    for (let v = 1; v <= 5; v++){ const id = name + '_' + k + '_' + v;
      h += '<input type="radio" name="' + name + '_' + k + '" id="' + id + '" value="' + v + '" data-t="' + tid + '" data-l="' + label + '" data-k="' + k + '"' + (g[k] == v ? ' checked' : '') + '><label for="' + id + '">' + v + '</label>'; }
    h += '</span>'; }
  return h + '</div><textarea placeholder="Notiz" data-t="' + tid + '" data-l="' + label + '" data-k="note">' + esc(g.note || '') + '</textarea>';
}
function render(){
  const nav = document.getElementById('nav'), box = document.getElementById('tasks');
  nav.innerHTML = DATA.tasks.map(t => '<a href="#' + t.id + '" id="nav-' + t.id + '">' + esc(t.id) + '</a>').join('');
  box.innerHTML = DATA.tasks.map(t => {
    const ans = t.answers.map(a => {
      let body;
      if (a.error) body = '<p class="err">Keine Antwort (Fehler beim Anbieter).</p>';
      else if (raw) body = '<pre>' + esc(a.text) + '</pre>';
      else body = '<div class="body">' + (t.json ? renderJSON(t, a.text) : md(a.text)) + '</div>';
      const chk = (a.checks || []).length ? '<details><summary>Automatische Vorprüfung: ' + a.checks.filter(c => c.ok).length + '/' + a.checks.length + '</summary>' +
        a.checks.map(c => '<div class="chk ' + (c.ok ? 'ok' : 'bad') + '">' + (c.ok ? '✓ ' : '✗ ') + esc(c.name) + (c.detail ? ' <span class="meta">(' + esc(c.detail) + ')</span>' : '') + '</div>').join('') + '</details>' : '';
      return '<div class="ans"><h3>' + a.label + '</h3>' + chk + body + (a.error ? '' : scoreBox(t.id, a.label)) + '</div>';
    }).join('');
    return '<section class="task" id="' + t.id + '"><h2 style="margin:0;font-size:17px">' + esc(t.subject) + ' · ' + esc(t.kindName) + '</h2><div class="meta">' + esc(t.id) + '</div>' +
      '<details><summary>Prompt anzeigen (System und Auftrag, wie in der App)</summary><pre>' + esc('SYSTEM: ' + t.system + '\n\n' + t.prompt) + '</pre></details>' +
      '<div class="answers">' + ans + '</div></section>';
  }).join('');
  progress();
}
function progress(){
  let need = 0, done = 0;
  for (const t of DATA.tasks){ let all = true;
    for (const a of t.answers){ if (a.error) continue; need++; const g = (store[t.id] || {})[a.label] || {};
      if (CRIT.every(([k]) => g[k])) done++; else all = false; }
    const n = document.getElementById('nav-' + t.id); if (n) n.classList.toggle('done', all && t.answers.some(a => !a.error)); }
  document.getElementById('progress').textContent = done + ' / ' + need + ' Antworten bewertet';
}
document.addEventListener('change', e => { const el = e.target; if (!el.dataset || !el.dataset.t) return;
  const t = el.dataset.t, l = el.dataset.l, k = el.dataset.k; store[t] = store[t] || {}; store[t][l] = store[t][l] || {};
  store[t][l][k] = k === 'note' ? el.value : Number(el.value); save(); });
document.addEventListener('input', e => { const el = e.target; if (el.tagName === 'TEXTAREA' && el.dataset.t){
  const t = el.dataset.t, l = el.dataset.l; store[t] = store[t] || {}; store[t][l] = store[t][l] || {}; store[t][l].note = el.value; save(); } });
document.getElementById('export').onclick = () => {
  const blob = new Blob([JSON.stringify({run: DATA.run, exported_at: new Date().toISOString(), grades: store}, null, 1)], {type: 'application/json'});
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'bewertung-' + DATA.run + '.json'; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000); };
document.getElementById('import').onchange = e => { const f = e.target.files[0]; if (!f) return; f.text().then(s => {
  try { const j = JSON.parse(s); if (j.run && j.run !== DATA.run && !confirm('Export gehört zu Lauf ' + j.run + '. Trotzdem laden?')) return;
    store = j.grades || {}; save(); render(); } catch (err) { alert('Datei ist kein gültiges JSON.'); } }); };
document.getElementById('raw').onclick = () => { raw = !raw; try { localStorage.setItem(KEY + ':raw', raw ? '1' : '0'); } catch (e) {} render(); };
render();
})();
</script></body></html>
"""


# ---------------------------------------------------------------- Auswertung der Blindbewertung

CRITERIA = ("richtigkeit", "verstaendlichkeit", "vollstaendigkeit")


def evaluate(run_dir: Path, export_path: Path) -> str:
    key = json.loads((run_dir / "key.json").read_text(encoding="utf-8"))
    exp = json.loads(export_path.read_text(encoding="utf-8"))
    grades = exp.get("grades") or {}
    tasks = {r["id"]: r for r in json.loads((run_dir / "tasks.json").read_text(encoding="utf-8"))}
    recs = [json.loads(line) for line in (run_dir / "results.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    providers = list(key["models"])
    sums = {p: {c: [] for c in CRITERIA} for p in providers}
    by_kind: dict[tuple[str, str], list[float]] = {}
    wins = {p: 0 for p in providers}
    graded_tasks = 0
    for tid, labels in key["labels"].items():
        g = grades.get(tid) or {}
        means = {}
        for letter, p in labels.items():
            s = g.get(letter) or {}
            vals = [s[c] for c in CRITERIA if isinstance(s.get(c), (int, float))]
            for c in CRITERIA:
                if isinstance(s.get(c), (int, float)):
                    sums[p][c].append(s[c])
            if len(vals) == len(CRITERIA):
                means[p] = sum(vals) / len(vals)
                by_kind.setdefault((p, tasks.get(tid, {}).get("kind", "?")), []).append(means[p])
        if len(means) >= 2:
            graded_tasks += 1
            best = max(means.values())
            for p, m in means.items():
                if m == best:
                    wins[p] += 1

    def avg(xs):
        return f"{sum(xs) / len(xs):.2f}" if xs else "–"
    lines = [f"# Auswertung {key['run']}", "", f"Bewertungsdatei: {export_path.name}; Aufgaben mit mindestens zwei bewerteten "
             f"Antworten: {graded_tasks}", "", "| Anbieter | Modell | Richtigkeit | Verständlichkeit | Vollständigkeit | Mittel | "
             "beste Antwort (inkl. Gleichstand) | Auto-Prüfung ok | Kosten $ |", "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for p in providers:
        allv = [x for c in CRITERIA for x in sums[p][c]]
        rs = [r for r in recs if r["provider"] == p]
        autos = [r for r in rs if r.get("auto") in ("pass", "fail")]
        lines.append(f"| {PROVIDERS[p].label if p in PROVIDERS else p} | {key['models'][p]} | " +
                     " | ".join(avg(sums[p][c]) for c in CRITERIA) + f" | {avg(allv)} | {wins[p]} | "
                     f"{sum(1 for r in autos if r['auto'] == 'pass')}/{len(autos)} | {sum(r.get('cost_usd') or 0 for r in rs):.4f} |")
    kinds = sorted({k for _, k in by_kind})
    if kinds:
        lines += ["", "## Mittel je Art", "", "| Art | " + " | ".join(PROVIDERS[p].label if p in PROVIDERS else p for p in providers) + " |",
                  "| --- | " + " | ".join("---" for _ in providers) + " |"]
        for k in kinds:
            lines.append(f"| {KIND_NAMES.get(k, k)} | " + " | ".join(avg(by_kind.get((p, k), [])) for p in providers) + " |")
    text = "\n".join(lines) + "\n"
    (run_dir / f"auswertung-{datetime.now().strftime('%Y%m%d-%H%M%S')}.md").write_text(text, encoding="utf-8")
    return text


# ---------------------------------------------------------------- Kostenschaetzung

# erwartete Ausgabe-Tokens je Art (sichtbarer Text) und Zuschlag fuer Denk-Tokens je Anbieter
EXPECTED_OUT = {"explain": 900, "steps": 1300, "flashcards": 900, "week_test": 2500, "grade": 700, "doc": 2400}
THINK_FACTOR = {"deepseek": 1.0, "openai": 1.4, "bedrock": 1.3}


def estimate(tasks: list[dict], providers: list[str]) -> str:
    now = datetime.now(timezone.utc)
    lines = ["| Anbieter | Eingabe-Tok. (≈ Zeichen/3,5) | Ausgabe-Tok. erwartet | erwartet $ | Obergrenze $ (alle Ausgabegrenzen voll) | Budget $ |",
             "| --- | --- | --- | --- | --- | --- |"]
    for p in providers:
        tin = sum(int((len(t["built"]["system"]) + len(t["built"]["prompt"])) / 3.5) for t in tasks)
        tout = sum(int(EXPECTED_OUT[t["kind"]] * THINK_FACTOR[p]) for t in tasks)
        if p == "deepseek":
            lo = (tin * DEEPSEEK_PRICES["offpeak"]["miss"] + tout * DEEPSEEK_PRICES["offpeak"]["out"]) / 1e6
            peak = (tin * DEEPSEEK_PRICES["peak"]["miss"] + tout * DEEPSEEK_PRICES["peak"]["out"]) / 1e6
            exp_txt = f"{lo:.3f} (außerhalb Spitze) / {peak:.3f} (Spitze)"
        else:
            exp_txt = f"{cost_usd(p, now, tin, 0, tout):.3f}"
        worst = sum(worst_case_usd(p, t["built"]["system"], t["built"]["prompt"], t["built"]["max_output"]) for t in tasks)
        lines.append(f"| {PROVIDERS[p].label} ({PROVIDERS[p].model}) | {tin} | {tout} | {exp_txt} | {worst:.3f} | {PROVIDERS[p].cap_usd:.2f} |")
    return "\n".join(lines)


# ---------------------------------------------------------------- Kommandozeile

def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "auswerten":
        if len(argv) != 3:
            print("Aufruf: tools/ki-vergleich.py auswerten <Laufordner> <bewertung-export.json>", file=sys.stderr)
            return 2
        print(evaluate(Path(argv[1]).expanduser(), Path(argv[2]).expanduser()))
        return 0
    ap = argparse.ArgumentParser(description="KI-Vergleich DeepSeek / OpenAI / Claude mit den Prompts der App")
    ap.add_argument("--dry-run", action="store_true", help="lokale Attrappe statt Netz (keine Schluessel noetig)")
    ap.add_argument("--estimate", action="store_true", help="nur Kostenschaetzung ausgeben")
    ap.add_argument("--only", default="", help="Anbieter, Komma-Liste: deepseek,openai,bedrock")
    ap.add_argument("--tasks", default="", help="nur diese Aufgaben (ids, Komma-Liste)")
    ap.add_argument("--keys-dir", default=str(KEYS_DIR))
    ap.add_argument("--out", default="", help="Laufordner (Standard ~/Studora-Builds/ki-vergleich/<Zeitstempel>)")
    ap.add_argument("--seed", type=int, default=None, help="Seed fuer die Mischung A/B/C")
    ap.add_argument("--list", action="store_true", help="Aufgaben auflisten")
    a = ap.parse_args(argv)

    tasks = load_tasks()
    if a.tasks:
        want = {x.strip() for x in a.tasks.split(",") if x.strip()}
        unknown = want - {t["id"] for t in tasks}
        if unknown:
            print("unbekannte Aufgaben: " + ", ".join(sorted(unknown)), file=sys.stderr)
            return 2
        tasks = [t for t in tasks if t["id"] in want]
    if a.list:
        for t in tasks:
            print(f"{t['id']:20} {KIND_NAMES[t['kind']]:18} {t['subject']}")
        return 0
    providers = [p.strip() for p in a.only.split(",") if p.strip()] or list(PROVIDERS)
    bad = [p for p in providers if p not in PROVIDERS]
    if bad:
        print("unbekannte Anbieter: " + ", ".join(bad), file=sys.stderr)
        return 2
    if a.estimate:
        print(estimate(tasks, providers))
        return 0
    if a.dry_run:
        creds = {}
    else:
        creds = load_credentials(Path(a.keys_dir).expanduser())
        missing = [p for p in providers if p not in creds]
        for p in missing:
            print(f"übersprungen: {PROVIDERS[p].label} (keine Schlüsseldatei in {a.keys_dir})")
        providers = [p for p in providers if p in creds]
        if not providers:
            print("Kein Anbieter mit Schlüssel – nichts zu tun.", file=sys.stderr)
            return 1
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S") + ("-dry" if a.dry_run else "")
    out_dir = Path(a.out).expanduser() if a.out else OUT_BASE / stamp
    print(f"{len(tasks)} Aufgaben × {len(providers)} Anbieter ({', '.join(providers)}) -> {out_dir}")
    res = run(tasks, providers, creds, out_dir, a.dry_run, seed=a.seed)
    print()
    print(res["summary"])
    print(f"Blindbewertung: {out_dir / 'bewertung.html'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
