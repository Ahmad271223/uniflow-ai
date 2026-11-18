"""Antwortstil der KI-Hilfe wie ChatGPT (18.11.2026, Auftrag des Inhabers mit Bildschirmfotos zu Aufgabe 5.1, GU05):
Regeln im System-Prompt (Gliederung, Schritte, Block-Formeln, Kaesten, Merke, Tabelle, Verstaendnisfrage, ALLE
Teilaufgaben), neue Modus-Texte auch fuer aeltere Apps (Relay ersetzt die alten), Hoechstlaenge, Kosten, die
Rechenseiten-Weiche (nur mit LERNAPP_AI_MATH_PAGES) und alte flache Antworten im Erklaerungsspeicher. Die KI-Antwort ist
nachgebaut (packages/shared-contracts/fixtures/ai-tutor), es gibt keinen echten KI-Aufruf."""
import json
import re
import uuid
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "packages" / "shared-contracts" / "fixtures" / "ai-tutor"
ANSWER = (FIXTURES / "erklaeren-gu05-5-1.md").read_text(encoding="utf-8")
OLD_ANSWER = (FIXTURES / "erklaeren-gu05-5-1-alt.md").read_text(encoding="utf-8")
# Text der Seite (PDF-Textebene des Uebungsblatts GU05, Aufgabe 5.1)
PAGE = ("Uebung GU05 Aufgabe 5.1 Geben Sie die folgenden Brueche komplexer Zahlen in Normaldarstellung x + yi an. "
        "(a) (3+4i)/(1-2i) (b) (1+i)/(1-i) (c) (2+i)/(3-i)")


# ---------------------------------------------------------------- Regeln im Prompt

def test_system_prompt_asks_for_the_chatgpt_structure():
    from app import ai
    s = ai.TUTOR_SYSTEM
    for rule in ("Du-Form", "ermutigend", "EINEM Satz", "'## 1. ...'", "'---'", "'**Gegeben:**'", "'### Schritt 1: ...'",
                 "warum", "jede Umformung als eigene Block-Formel", "$$\\boxed{...}$$", "'> **Merke: ...**'",
                 "Markdown-Tabelle", "genau EINER kurzen Verstaendnisfrage", "ALLE Teilaufgaben", "pruefe jedes Ergebnis",
                 "\\frac{...}{...}", "am Ende eines Absatzes", "Deutsch"):
        assert rule in s, rule
    assert ai.MATH_STYLE in s
    # die alten Bremsen sind weg (daraus wurde der eine flache Absatz)
    for gone in ("200 Woertern", "keine Rueckfrage am Ende", "Markdown sparsam", "keine langen Herleitungen"):
        assert gone not in s, gone
    # JSON-Modi bleiben moeglich: die Form gilt nur, wenn die AUFGABE nichts anderes verlangt
    assert "wenn die AUFGABE nichts anderes verlangt" in s and "NUR mit JSON" in ai.TUTOR_MODES["flashcards"]


def test_modes_follow_the_style():
    from app import ai
    m = ai.TUTOR_MODES
    assert "ALLER Teilaufgaben" in m["explain"] and "begruende jeden Schritt" in m["explain"]
    assert "Vergleich aus dem Alltag" in m["explain_simple"] and "Rechnungen trotzdem vollstaendig" in m["explain_simple"]
    assert "alle Teilaufgaben" in m["ask"] and "Ergebnis im Kasten" in m["steps"] and "Ergebnistabelle" in m["steps"]
    assert "keine fertige Loesung" in m["hints"] and "kein Merke-Kasten" in m["hints"]
    assert "Keine Schritte" in m["summary"] and "Keine Abschnitte" in m["terms"]
    assert set(m) == set(ai.TUTOR_MODES_BEFORE_2026_11_18) | {"flashcards"}
    # die Texte lassen sich als Swift-Raw-Literal schreiben (tools/gen-swift-ai-texts.py)
    for t in [ai.TUTOR_SYSTEM, *m.values()]:
        assert '"#' not in t


def test_generated_device_texts_and_contract_are_current():
    import subprocess
    import sys
    for tool in ("gen-swift-ai-texts.py", "gen-ai-contract.py"):
        r = subprocess.run([sys.executable, str(ROOT / "tools" / tool), "--check"], cwd=ROOT, capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr


def test_prompt_of_the_page_carries_the_new_task():
    from app import ai
    p = ai.tutor_prompt("explain", PAGE, course="Mathematik I", file_name="GU05.pdf", page=1)
    assert "AUFGABE: " + ai.TUTOR_MODES["explain"] in p and "(c) (2+i)/(3-i)" in p


# ---------------------------------------------------------------- aeltere Apps (Prompt vom iPad ueber /api/ai/relay)

def test_old_task_text_is_upgraded_once_and_only_for_its_mode():
    from app import ai
    for mode, old in ai.TUTOR_MODES_BEFORE_2026_11_18.items():
        prompt = ai.tutor_prompt(mode, PAGE).replace(ai.TUTOR_MODES[mode], old)
        assert ai.upgrade_tutor_prompt(f"tutor:{mode}", prompt) == ai.tutor_prompt(mode, PAGE)
    new = ai.tutor_prompt("explain", PAGE)
    assert ai.upgrade_tutor_prompt("tutor:explain", new) == new, "neue Prompts bleiben"
    old_explain = "AUFGABE: " + ai.TUTOR_MODES_BEFORE_2026_11_18["explain"]
    assert ai.upgrade_tutor_prompt("tutor:summary", old_explain) == old_explain, "nur der eigene Modus"
    assert ai.upgrade_tutor_prompt("flashcards", old_explain) == old_explain
    # der Text steht im Seiteninhalt (Material): nur das erste Vorkommen, die Zeile AUFGABE steht vorn
    twice = old_explain + "\n" + old_explain
    assert ai.upgrade_tutor_prompt("tutor:explain", twice).count(ai.TUTOR_MODES["explain"]) == 1


def test_relay_sends_the_new_task_and_system_for_an_old_app(monkeypatch):
    from app import ai, ai_relay

    seen = {}

    def fake_complete(user_id, purpose, system, prompt, **kw):
        seen.update(system=system, prompt=prompt, purpose=purpose)
        return type("C", (), {"text": ANSWER})()
    from app import ai_backend
    monkeypatch.setattr(ai_backend, "complete", fake_complete)
    old_prompt = ai.tutor_prompt("explain", PAGE).replace(ai.TUTOR_MODES["explain"], ai.TUTOR_MODES_BEFORE_2026_11_18["explain"])
    task = ai_relay._tasks()["tutor:explain"]
    prompt = ai.upgrade_tutor_prompt("tutor:explain", old_prompt)       # wie _relay_prepare
    c = ai_relay._complete({"id": "u1"}, task, "tutor:explain", prompt, "r1", {})
    assert c.text == ANSWER
    assert seen["system"] == ai.TUTOR_SYSTEM and seen["purpose"] == "tutor:explain"
    assert ai.TUTOR_MODES["explain"] in seen["prompt"] and ai.TUTOR_MODES_BEFORE_2026_11_18["explain"] not in seen["prompt"]


def test_relay_prepare_upgrades_the_prompt(monkeypatch):
    """_relay_prepare selbst ersetzt den alten Text (Pruefungen der Anmeldung als Attrappe)."""
    from app import ai, ai_backend, ai_relay, config, entitlements
    monkeypatch.setattr(config, "is_hosted", lambda: True)
    monkeypatch.setattr(entitlements, "require", lambda *a, **k: None)
    monkeypatch.setattr(entitlements, "require_verified_for_ai", lambda *a, **k: None)
    monkeypatch.setattr(ai_backend, "replay", lambda *a, **k: None)
    req = type("R", (), {"state": type("S", (), {"user": {"id": "u1"}})()})()
    old = ai.tutor_prompt("steps", PAGE).replace(ai.TUTOR_MODES["steps"], ai.TUTOR_MODES_BEFORE_2026_11_18["steps"])
    pre = ai_relay._relay_prepare(req, {"task": "tutor:steps", "prompt": old})
    assert pre["prompt"] == ai.tutor_prompt("steps", PAGE)
    pre = ai_relay._relay_prepare(req, {"task": "mail", "prompt": "AUFGABE: " + ai.TUTOR_MODES_BEFORE_2026_11_18["steps"]})
    assert pre["prompt"].endswith(ai.TUTOR_MODES_BEFORE_2026_11_18["steps"]), "andere Aufgaben bleiben unveraendert"


# ---------------------------------------------------------------- nachgebaute Antwort, Laenge, Kosten

def shape(answer: str) -> dict:
    """Bestandteile einer Antwort im ChatGPT-Stil (wie der Prompt sie verlangt)"""
    return {
        "intro": bool(re.match(r"^[^#\n>|$].+\.\s*$", answer.strip().split("\n", 1)[0])),
        "sections": re.findall(r"(?m)^## \d+\. .+$", answer),
        "steps": re.findall(r"(?m)^### Schritt \d+: .+$", answer),
        "given": answer.count("**Gegeben:**"),
        "blocks": re.findall(r"(?m)^\$\$.+\$\$$", answer),
        "boxed": re.findall(r"\\boxed\{", answer),
        "merke": bool(re.search(r"(?m)^> \*\*Merke: .+\*\*$", answer)),
        "table": bool(re.search(r"(?m)^\|.+\|\n\|[-| :]+\|$", answer)),
        "question": answer.strip().split("\n")[-1].strip().endswith("?"),
        "marks": re.findall(r"\[\d{1,2}\]", answer),
    }


def test_fixture_answer_has_every_part_of_the_chatgpt_answer():
    s = shape(ANSWER)
    assert s["intro"] and s["merke"] and s["table"] and s["question"] and not s["marks"]
    assert [x.split(". ", 1)[1] for x in s["sections"]] == ["Was ist überhaupt eine komplexe Zahl?", "Aufgabe (a)", "Aufgabe (b)",
                                                            "Aufgabe (c)", "Die wichtigste Regel für deine Klausur"]
    assert s["given"] == 3 and len(s["steps"]) == 12 and len(s["boxed"]) >= 10 and len(s["blocks"]) >= 25
    # die Ergebnisse stimmen (Kasten am Ende jeder Teilaufgabe)
    for result in ("\\boxed{-1 + 2i}", "\\boxed{i}", "\\boxed{\\frac{1}{2} + \\frac{1}{2}i}"):
        assert result in ANSWER
    assert complex(3, 4) / complex(1, -2) == complex(-1, 2) and complex(1, 1) / complex(1, -1) == 1j
    assert abs(complex(2, 1) / complex(3, -1) - complex(0.5, 0.5)) < 1e-12
    # die alte Antwort hatte davon fast nichts
    o = shape(OLD_ANSWER)
    assert not o["sections"] and not o["steps"] and not o["boxed"] and not o["table"] and o["marks"] == ["[1]"]


def test_output_limit_fits_three_subtasks_with_thinking():
    from app import ai_backend, ai_prices
    assert ai_backend.max_output("tutor:explain") == ai_backend.max_output("tutor:ask") == 6000
    answer_tokens = len(ANSWER) / ai_prices.CHARS_PER_TOKEN          # vorsichtig gerechnet (3 Zeichen je Token)
    assert answer_tokens < 1500
    assert answer_tokens + 3000 <= ai_backend.max_output("tutor:explain"), "Platz fuer Denk-Tokens"
    assert ai_backend.max_output("doc_index_page") == 3000, "andere Zwecke unveraendert"


def credits(model: str, inp: int, out: int) -> int:
    from app import ai_prices
    return ai_prices.credits_for(ai_prices.cost_microeur(model, inp, out))


def test_cost_per_answer_before_and_after(monkeypatch):
    """Preise aus der Tabelle (app/ai_prices.py; die Tests setzen sonst winzige Preise).
    Kosten je Antwort (Eingabe: System + Seite + Quellen etwa 3.000 Tokens vorher, 3.700 nachher; Ausgabe mit
    Denk-Tokens etwa 900 vorher, 3.800 nachher): mit gpt-6-luna bleibt es 1 Credit."""
    for k in ("LERNAPP_AI_PRICE_IN_EUR", "LERNAPP_AI_PRICE_OUT_EUR", "LERNAPP_AI_PRICES", "LERNAPP_AI_USD_EUR", "LERNAPP_OPENAI_BASE_URL"):
        monkeypatch.delenv(k, raising=False)
    assert credits("gpt-6-luna", 3000, 900) == 1 and credits("gpt-6-luna", 3700, 3800) == 1
    # stuerzt das Modell bis an die Grenze aus: immer noch 1 Credit
    assert credits("gpt-6-luna", 4000, 6000) == 1
    # staerkere Modelle (nur mit Okay, LERNAPP_AI_MATH_PAGES): mehr Credits je Antwort
    assert credits("gpt-6.1-terra", 3000, 900) == 2 and credits("gpt-6.1-terra", 3700, 3800) == 4
    assert credits("claude-sonnet-5-5", 3000, 900) == 3 and credits("claude-sonnet-5-5", 3700, 3800) == 8


# ---------------------------------------------------------------- Rechenseiten (nur mit Okay des Inhabers)

def test_math_page_switch_is_off_by_default_and_one_line_to_turn_on(monkeypatch):
    from app import ai, ai_router
    prompt = ai.tutor_prompt("explain", PAGE)
    assert ai_router.looks_math_page(PAGE) and ai_router.looks_math_page(prompt)
    assert not ai_router.looks_math_page("Organisatorisches: Die Vorlesung beginnt am Montag im Raum F 102 (Hauptgebaeude).")
    assert not ai_router.looks_math_page("Grundlagen der Informatik-Systeme und Software-Architektur im Ueberblick, Termine 2026-11-18.")
    every = {"openai", "anthropic"}
    monkeypatch.delenv("LERNAPP_AI_ROUTES", raising=False)
    monkeypatch.delenv(ai_router.MATH_PAGES_ENV, raising=False)
    chain, hard = ai_router.chain("tutor:explain", "r1", configured=every, page_text=prompt)
    assert chain[0].provider == "openai" and not hard, "Standard: unveraendert das guenstige Modell"
    monkeypatch.setenv(ai_router.MATH_PAGES_ENV, "1")
    chain, hard = ai_router.chain("tutor:explain", "r1", configured=every, page_text=prompt)
    assert chain[0].provider == "anthropic" and hard
    chain, _ = ai_router.chain("tutor:explain", "r1", configured=every, page_text="Die Vorlesung beginnt am Montag.")
    assert chain[0].provider == "openai", "Seiten ohne Rechnung bleiben guenstig"
    chain, _ = ai_router.chain("tutor:summary", "r1", configured=every, page_text=prompt)
    assert chain[0].provider == "openai", "Zusammenfassen gehoert nicht dazu"
    monkeypatch.setenv(ai_router.MATH_PAGES_ENV, "openai/gpt-6.1-terra:100")
    chain, _ = ai_router.chain("tutor:explain", "r1", configured=every, page_text=prompt)
    assert (chain[0].provider, chain[0].model) == ("openai", "gpt-6.1-terra")
    monkeypatch.setenv(ai_router.MATH_PAGES_ENV, "0")
    assert ai_router.chain("tutor:explain", "r1", configured=every, page_text=prompt)[0][0].provider == "openai"
    # nur OpenAI eingerichtet: der Schalter fuehrt nicht ins Leere
    monkeypatch.setenv(ai_router.MATH_PAGES_ENV, "1")
    assert ai_router.chain("tutor:explain", "r1", configured={"openai"}, page_text=prompt)[0][0].provider == "openai"


def test_backend_routes_with_the_prompt_as_page(monkeypatch):
    from app import ai, ai_backend, ai_router
    seen = {}
    real = ai_router.chain

    def spy(*a, **k):
        seen.update(k)
        return real(*a, **k)
    monkeypatch.setattr(ai_router, "chain", spy)
    monkeypatch.setattr(ai_backend, "configured_providers", lambda ignore_choice=False: {"openai"})
    monkeypatch.setattr(ai_backend, "build", lambda prov, model=None: type("P", (), {"model": model or "gpt-6-luna"})())
    prompt = ai.tutor_prompt("explain", PAGE)
    ai_backend.route("tutor:explain", "r1", page_text=prompt)
    assert seen["page_text"] == prompt


# ---------------------------------------------------------------- Erklaerungsspeicher: alte flache Antworten

def test_old_flat_answer_in_the_store_is_not_shown_again(app, monkeypatch):
    from app import ai, db, explain_local
    assert not explain_local.current_style("explain", OLD_ANSWER) and explain_local.current_style("explain", ANSWER)
    assert explain_local.current_style("summary", "- Punkt eins"), "Zusammenfassungen bleiben gueltig"
    text = PAGE + " " + uuid.uuid4().hex
    with db.cursor() as conn:
        assert explain_local.store(conn, text, 1, "explain", OLD_ANSWER) == 1
        assert explain_local.lookup(conn, text, 1, "explain") is None
    calls = []

    def fake(prompt, system):
        calls.append((prompt, system))
        return ANSWER
    monkeypatch.setattr(ai, "ask", fake)
    body = {"mode": "explain", "page": 1, "page_text": text}
    st, _, b = asgi_call(app, "POST", "/api/ai/tutor", body=json.dumps(body))
    d = json.loads(b)
    assert st == 200 and len(calls) == 1 and d["answer"] == ANSWER, "live statt der alten Antwort"
    assert d["explain"]["variant"] == 2, "die alte belegt Platz 1, die neue kommt auf Platz 2 (nichts ueberschrieben)"
    assert calls[0][1] == ai.TUTOR_SYSTEM and ai.TUTOR_MODES["explain"] in calls[0][0]
    st, _, b = asgi_call(app, "POST", "/api/ai/tutor", body=json.dumps(body))
    d = json.loads(b)
    assert st == 200 and len(calls) == 1 and d["explain"]["stored"] is True and d["explain"]["variant"] == 2
    assert d["answer"] == ANSWER.strip()


@pytest.mark.parametrize("answer", [ANSWER, OLD_ANSWER])
def test_answer_text_comes_back_unchanged(app, monkeypatch, answer):
    """Der Dienst laesst die Antwort, wie sie ist (Markdown, LaTeX); die Darstellung machen App und Web."""
    from app import ai
    monkeypatch.setattr(ai, "ask", lambda prompt, system: answer)
    st, _, b = asgi_call(app, "POST", "/api/ai/tutor", body=json.dumps({"mode": "ask", "page": 1, "page_text": PAGE,
                                                                        "question": "Wie geht 5.1?"}))
    assert st == 200 and json.loads(b)["answer"] == answer
