"""KI-Hilfe mit den eigenen Notizen zur Seite (05.11.2026, docs/NOTIZEN-MITSCHICKEN-2026-11-05.md): Seitennotizen und
Blatt daneben (Textfelder und erkannte Handschrift) gehen als `own_notes` mit und stehen als eigener Block im Prompt;
ohne Notizen bleibt der Prompt byte-gleich (Vertrag mit AIPrompts.swift)."""
import json

from conftest import asgi_call


def test_own_notes_go_into_the_prompt_after_my_solution(app, monkeypatch):
    from app import ai
    seen = {}
    monkeypatch.setattr(ai, "ask", lambda prompt, system: seen.setdefault("prompt", prompt) and "Passt.")
    notes = "Notiz zu Folie 4:\nEigenwert = Nullstelle des charakteristischen Polynoms"
    st, _, b = asgi_call(app, "POST", "/api/ai/tutor", body=json.dumps({"mode": "ask", "page_text": "Folie 4", "question": "Stimmt meine Notiz?",
                                                                       "own_notes": "  " + notes + "  "}))
    assert st == 200, b
    p = seen["prompt"]
    block = "\n".join(["", ai.OWN_NOTES_HEADING, "<<<", notes, ">>>"])
    assert block in p
    assert p.index(ai.OWN_NOTES_HEADING) < p.index("MEINE FRAGE: Stimmt meine Notiz?") < p.index("SEITENINHALT")


def test_without_or_with_unusable_notes_the_prompt_is_unchanged(app, monkeypatch):
    from app import ai
    prompts = []
    monkeypatch.setattr(ai, "ask", lambda prompt, system: prompts.append(prompt) or "Ok.")
    for extra in ({}, {"own_notes": "   "}, {"own_notes": 5}, {"own_notes": ["x"]}):
        st, _, b = asgi_call(app, "POST", "/api/ai/tutor", body=json.dumps({"mode": "explain", "page_text": "Folie 2", **extra}))
        assert st == 200, b
    assert len(set(prompts)) == 1 and ai.OWN_NOTES_HEADING not in prompts[0]
    assert ai.tutor_prompt("explain", "Folie 2") == ai.tutor_prompt("explain", "Folie 2", own_notes="")


def test_own_notes_are_cut_like_the_other_blocks():
    from app import ai
    p = ai.tutor_prompt("ask", "Seite", own_notes="x" * 5000)
    assert "x" * ai.OWN_NOTES_CHARS + "\n>>>" in p and "x" * (ai.OWN_NOTES_CHARS + 1) not in p
