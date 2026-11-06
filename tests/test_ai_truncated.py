"""Gekuerzte Antworten (06.11.2026): erreicht die KI ihre Ausgabegrenze, bekommt der Nutzer den bezahlten Text mit Hinweis
statt eines Fehlers; andere Abbrueche bleiben Fehler."""
import json

import pytest

from app import ai_backend


def sse(*events):
    return [line for e in events for line in (f"data: {json.dumps(e)}", "")]


def test_max_output_tokens_returns_the_text_with_a_note():
    usage = {"input_tokens": 100, "output_tokens": 7000}
    lines = sse({"type": "response.output_text.delta", "delta": "Aufgabe 1: "},
                {"type": "response.output_text.delta", "delta": "Lösungsweg …"},
                {"type": "response.incomplete", "response": {"incomplete_details": {"reason": "max_output_tokens"}, "usage": usage}})
    text, data = ai_backend.consume_stream(lines)
    assert text.startswith("Aufgabe 1: Lösungsweg …") and "gekürzt" in text
    assert data["truncated"] is True and data["usage"] == usage


def test_other_incomplete_reasons_and_empty_text_stay_errors():
    with pytest.raises(ai_backend.AIUnavailable, match="nicht beendet"):
        ai_backend.consume_stream(sse({"type": "response.output_text.delta", "delta": "x"},
                                      {"type": "response.incomplete", "response": {"incomplete_details": {"reason": "content_filter"}}}))
    with pytest.raises(ai_backend.AIUnavailable, match="nicht beendet"):
        ai_backend.consume_stream(sse({"type": "response.incomplete", "response": {"incomplete_details": {"reason": "max_output_tokens"}}}))
