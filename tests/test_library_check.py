"""Pruefung der StudiNow-KI-Fragen vor dem Pool (app/test_library.check): auch Antwortmoeglichkeiten und Erklaerung
duerfen keine Links oder Personenangaben enthalten."""
import pytest

from app import test_library

GOOD = {"question": "Was ist die Ableitung von x^2?", "type": "mc", "options": ["2x", "x", "x^2", "2"], "answer": "2x",
        "explanation": "Potenzregel.", "difficulty": 3}


def test_clean_question_passes():
    assert test_library.check(dict(GOOD)) == []


@pytest.mark.parametrize("patch", [
    {"options": ["2x", "Mehr unter https://beispiel.de/loesung", "x^2", "2"]},
    {"options": ["2x", "x", "schreib an max@beispiel.de", "2"]},
    {"explanation": "Siehe https://beispiel.de/x oder max@beispiel.de"},
    {"explanation": "Name: Erika Mustermann, Matrikelnummer 1234567"},
])
def test_links_and_personal_data_in_options_or_explanation_are_rejected(patch):
    assert test_library.check({**GOOD, **patch}), patch


def test_add_skips_ai_questions_with_planted_text(app):
    meta = {"subject": "Analysis", "topic": "Ableitungen"}
    bad = {**GOOD, "explanation": "Mehr unter https://beispiel.de/x"}
    assert test_library.add([bad], meta, "studora_ai", "auto_checked") == []
    assert len(test_library.add([GOOD], meta, "studora_ai", "auto_checked")) == 1
    # eingereichte Nutzerfragen werden dagegen bereinigt und bleiben nutzbar
    kept = test_library.submit_for_sharing("o" * 24, [bad], {**meta, "topic": "Ableitungen 2"})
    assert kept["submitted"] == 1
