"""Erklaerungsspeicher der KI-Hilfe im Editor fuer Web und Windows (05.11.2026, app/explain_local.py, docs/ERKLAERUNGSSPEICHER-2026-11-04.md):
Eine Antwort fuer die ganze Seite wird gemerkt, beim naechsten Mal kommt sie sofort ("Schon erklaert - 0 Credits"), "Neu
erklaeren lassen" (`force`) belegt den naechsten Platz (hoechstens drei Varianten, nie ueberschreiben); Frage, Markierung,
eigene Loesung und Notizen bleiben live. Im Dienst sieht ein zweites Konto dieselbe Anfrage als gemeinsame Antwort
("sofort da"). KI-Attrappe statt Anbieter, kein echter Aufruf."""
import json
import uuid

import pytest
from conftest import asgi_call
from test_credits import cheap_calls
from test_subscriptions import FakeAI, _j, hosted, user  # noqa: F401


def uniq(prefix="Seite"):
    return f"{prefix} {uuid.uuid4().hex[:10]}"


def tutor(app, body, headers=None):
    st, _, b = asgi_call(app, "POST", "/api/ai/tutor", headers=headers or {}, body=json.dumps(body))
    return st, (json.loads(b) if b else None)


@pytest.fixture
def ask(app, monkeypatch):
    """Eigener PC: die KI des Nutzers antwortet mit Quellenmarken und zaehlt, wie oft sie gefragt wurde"""
    from app import ai
    calls = []

    def fake(prompt, system):
        calls.append(prompt)
        return f"Antwort {len(calls)} zur Seite [1] und [2]."
    monkeypatch.setattr(ai, "ask", fake)
    return calls


def test_first_answer_is_live_second_comes_from_the_store(app, ask):
    text = uniq()
    st, a = tutor(app, {"mode": "explain", "page": 3, "page_text": text})
    assert st == 200 and a["answer"] == "Antwort 1 zur Seite [1] und [2]."
    assert a["explain"] == {"stored": False, "variant": 1, "shared": False}
    st, b = tutor(app, {"mode": "explain", "page": 3, "page_text": text})
    assert st == 200 and len(ask) == 1, "kein zweiter KI-Aufruf"
    assert b["answer"].startswith("Antwort 1 zur Seite"), b["answer"]
    assert "[1]" not in b["answer"] and "[2]" not in b["answer"], "Quellenmarken des ersten Fragenden werden nicht weitergereicht"
    assert b["explain"]["stored"] is True and b["explain"]["source"] == "local" and b["explain"]["variant"] == 1
    assert b["explain"]["created_at"] and b["sources"] == [] and b["cards"] is None


def test_other_page_other_mode_or_changed_text_ask_again(app, ask):
    text = uniq()
    tutor(app, {"mode": "explain", "page": 1, "page_text": text})
    tutor(app, {"mode": "summary", "page": 1, "page_text": text})            # anderer Modus
    tutor(app, {"mode": "explain", "page": 2, "page_text": text})            # andere Seite
    tutor(app, {"mode": "explain", "page": 1, "page_text": text + " neu"})   # Seite hat sich geaendert
    assert len(ask) == 4
    st, d = tutor(app, {"mode": "explain", "page": 1, "page_text": text + "\n  "})   # nur Leerraum: gleicher Abdruck
    assert st == 200 and len(ask) == 4 and d["explain"]["stored"] is True


@pytest.mark.parametrize("extra", [{"question": "Warum?"}, {"selection": "Satz 1"}, {"own_solution": "x = 1"}, {"own_notes": "Meine Notiz"}])
def test_question_selection_solution_and_notes_stay_live(app, ask, extra):
    text = uniq()
    for _ in range(2):
        st, d = tutor(app, {"mode": "explain", "page": 1, "page_text": text, **extra})
        assert st == 200 and d["explain"] is None
    assert len(ask) == 2, "nichts gemerkt, nichts geteilt"
    # und die freie Frage, Pruefen, Ähnliche Aufgabe und Karteikarten gehoeren nie in den Speicher
    for mode in ("ask", "check", "similar"):
        for _ in range(2):
            assert tutor(app, {"mode": mode, "page": 1, "page_text": text})[1]["explain"] is None
    assert len(ask) == 2 + 6


def test_force_asks_again_and_fills_up_to_three_variants_without_overwriting(app, ask):
    text = uniq()
    body = {"mode": "steps", "page": 5, "page_text": text}
    assert tutor(app, body)[1]["explain"]["variant"] == 1
    for want in (2, 3):
        st, d = tutor(app, {**body, "force": True})
        assert st == 200 and d["explain"] == {"stored": False, "variant": want, "shared": False}
    assert len(ask) == 3
    st, d = tutor(app, {**body, "force": True})
    assert st == 200 and d["explain"]["variant"] == 0, "alle drei belegt: die neue Antwort bleibt nur auf dem Bildschirm"
    assert d["answer"].startswith("Antwort 4")
    # Leser nehmen die niedrigste Variante; die vierte Antwort hat nichts ueberschrieben
    st, d = tutor(app, body)
    assert d["explain"]["stored"] is True and d["explain"]["variant"] == 1 and d["answer"].startswith("Antwort 1") and len(ask) == 4


def test_unusable_requests_do_not_touch_the_store(app, ask):
    # ohne Seitentext gibt es nichts zu merken
    for _ in range(2):
        assert tutor(app, {"mode": "explain", "page": 1, "page_text": "  "})[1]["explain"] is None
    assert len(ask) == 2
    from app import explain_local
    assert explain_local.is_shareable("explain") and not explain_local.is_shareable("flashcards")
    assert explain_local.strip_marks("A [1], B [12] und [x]") == "A, B und [x]"
    assert explain_local.text_hash("a  b\n c") == explain_local.text_hash("a b c") != explain_local.text_hash("a b d")


# ---------------------------------------------------------------- Dienst (gehostet)

def test_hosted_stored_answer_costs_nothing_and_does_not_count(hosted, monkeypatch):  # noqa: F811
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    cheap_calls(monkeypatch)
    u, h = user(hosted, "speicher-a@beispiel.de", plan="pro_ai")
    text = uniq()
    st, first = tutor(hosted, {"mode": "explain", "page": 1, "page_text": text, "request_id": "e1"}, h)
    assert st == 200 and first["explain"]["stored"] is False and first["credits"]["charged"] > 0 and fake.calls == 1
    remaining = first["credits"]["remaining"]
    st, again = tutor(hosted, {"mode": "explain", "page": 1, "page_text": text, "request_id": "e2"}, h)
    assert st == 200 and fake.calls == 1, "kein zweiter KI-Aufruf"
    assert again["explain"]["stored"] is True and again["explain"]["source"] == "local"
    assert again["credits"]["charged"] == 0 and again["credits"]["remaining"] == remaining
    assert again["answer"] == first["answer"]
    q = _j(asgi_call(hosted, "GET", "/api/entitlements", headers=h))[1]["quotas"]["ai_assist"]["used"]
    assert q == 1, "das Lesen einer gespeicherten Antwort zaehlt nicht gegen das Kontingent"
    # dieselbe request_id wiederholt weiter die Rechnung der ersten Anfrage (Wiederholung nach Netzfehler)
    st, replay = tutor(hosted, {"mode": "explain", "page": 1, "page_text": text, "request_id": "e1"}, h)
    assert st == 200 and replay["credits"]["replay"] is True and fake.calls == 1


def test_hosted_second_account_gets_the_shared_answer_and_force_asks_again(hosted, monkeypatch):  # noqa: F811
    from app import ai_backend
    fake = FakeAI()
    ai_backend.set_provider(fake)
    cheap_calls(monkeypatch)
    _, ha = user(hosted, "speicher-b1@beispiel.de", plan="pro_ai")
    _, hb = user(hosted, "speicher-b2@beispiel.de", plan="pro_ai")
    text = uniq()
    body = {"mode": "summary", "page": 2, "page_text": text}
    assert tutor(hosted, body, ha)[1]["explain"]["stored"] is False and fake.calls == 1
    st, d = tutor(hosted, body, hb)
    assert st == 200 and fake.calls == 1, "gleiche Anfrage: die gemeinsame Antwort, kein KI-Aufruf"
    assert d["explain"]["stored"] is True and d["explain"]["source"] == "cloud" and d["credits"]["charged"] == 0
    # das zweite Konto hat sie danach auch selbst gemerkt (Herkunft bleibt "gemeinsam", wie auf dem iPad)
    assert tutor(hosted, body, hb)[1]["explain"]["source"] == "cloud"
    # "Neu erklaeren lassen": am Zwischenspeicher vorbei, es kostet wieder eine Anfrage
    st, d = tutor(hosted, {**body, "force": True}, hb)
    assert st == 200 and fake.calls == 2 and d["explain"]["stored"] is False and d["explain"]["variant"] == 2
    assert d["credits"]["charged"] > 0
