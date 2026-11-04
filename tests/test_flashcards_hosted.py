"""Karteikarten im Dienst (04.11.2026): selbst anlegen ab Plus (`can_use_flashcards`, auch beim Geraete-Abgleich: neue
Karten und Stapel), KI-Auftrag nach Modul/Lernwoche/Anzahl nur mit Pro AI (`can_use_ai_generated_questions`),
bestaetigter E-Mail, Kontingent `ai_assist` mit Anfrage-ID und Rueckbuchung bei Fehlern, Budget/Preispflicht der
StudiNow-KI. Aus der Cloud-Sitzung an das Stapel-Modell angepasst (flashcard_stacks, POST /api/flashcards mit
stack_id). Mit einer Attrappe statt eines echten KI-Anbieters."""
import json
import re
import threading
import time

import pytest
from conftest import asgi_call
from test_subscriptions import _j, ent, hosted, user  # noqa: F401


class FakeCardsAI:
    """Attrappe fuer die StudiNow-KI: liefert so viele Karten, wie der Prompt verlangt, und zaehlt die Aufrufe."""

    def __init__(self, fail=None, empty=False):
        self.calls, self.prompts, self.fail, self.empty, self.lock = 0, [], fail, empty, threading.Lock()

    def complete(self, system, prompt, schema=None):
        from app.ai_backend import AIUnavailable, Completion
        with self.lock:
            self.calls += 1
            self.prompts.append(prompt)
        if self.fail == "unavailable":
            raise AIUnavailable("ai_provider_error", "Anbieter antwortet nicht.", 502)
        if self.fail == "crash":
            raise RuntimeError("kaputt")
        n = int(re.search(r"genau (\d+) Karteikarten", prompt).group(1))
        cards = [] if self.empty else [{"question": f"Frage {i} Lauf {self.calls}?", "answer": f"Antwort {i}"} for i in range(n)]
        return Completion(json.dumps({"cards": cards}), 400, 300, "fake")


def seed(app, headers):
    """Modul mit einer Vorlesung in Lehrwoche 3 in der Datenbank des Kontos; liefert die Modul-ID."""
    from app import config, db
    st, me = _j(asgi_call(app, "GET", "/api/account/me", headers=headers))
    t = config.set_user_context(me["user"]["id"], me["user"]["university"])
    try:
        db.init_db()
        with db.cursor() as conn:
            mid = conn.execute("INSERT INTO modules(name) VALUES ('Lineare Algebra')").lastrowid
            conn.execute("INSERT OR REPLACE INTO courses(id, title, kind, active, module_id) VALUES ('c1', 'Lineare Algebra', 'vorlesung', 1, ?)", (mid,))
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status, kind, chdate) VALUES ('f3', 'c1', 'VL03_Determinanten.pdf', 'neu', 'pdf', ?)",
                         (int(time.time()),))
    finally:
        config.reset_user_context(t)
    return mid


@pytest.fixture
def texts(monkeypatch):
    from app import scriptsearch
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, file_id, *a, **k: ["Determinante Leibniz-Formel", "Laplace-Entwicklung"])


def post(app, h, path, body):
    return _j(asgi_call(app, "POST", path, headers=h, body=json.dumps(body)))


def save(app, h, cards, week=3, name="KI Woche 3"):
    """Vorschlag in einen Stapel des Moduls legen (wie die Oberflaeche): Stapel anlegen, dann die Karten."""
    st, stack = post(app, h, "/api/flashcard-stacks", {"name": name, "subject": "Lineare Algebra", "week": week})
    assert st == 200, stack
    st, d = post(app, h, "/api/flashcards", {"stack_id": stack["id"], "cards": cards})
    assert st == 200, d
    return stack["id"], d


def test_free_cannot_create_but_plus_can(hosted):  # noqa: F811
    _, hf = user(hosted, "frei@beispiel.de")
    mid = seed(hosted, hf)
    card = {"cards": [{"question": "Was ist eine Matrix?", "answer": "Zahlenschema"}]}
    st, d = post(hosted, hf, "/api/flashcards", card)
    assert (st, d["code"], d["entitlement"], d["required_plan"]) == (403, "plan_required", "can_use_flashcards", "plus"), d
    st, d = post(hosted, hf, "/api/flashcard-stacks", {"name": "Woche 3", "subject": "Lineare Algebra", "week": 3})
    assert (st, d["entitlement"]) == (403, "can_use_flashcards")
    # Geraete-Abgleich: neue Karten und Stapel abgewiesen, Module laufen weiter
    st, d = post(hosted, hf, "/api/sync/push", {"device_id": "ipad", "items": [
        {"entity": "flashcard_stacks", "local_id": -3, "data": {"name": "S", "subject": "M2", "created_at": "2026-11-04T10:00:00"}},
        {"entity": "flashcards", "local_id": -1, "data": {"question": "Q", "answer": "A"}},
        {"entity": "modules", "local_id": -2, "data": {"name": "M2"}}]})
    assert st == 200 and {r["entity"]: r["status"] for r in d["results"]} == {
        "flashcards": "plan_required", "flashcard_stacks": "plan_required", "modules": "created"}, d
    assert next(r for r in d["results"] if r["entity"] == "flashcards") == {"entity": "flashcards", "local_id": -1, "status": "plan_required", "required_plan": "plus"}
    assert _j(asgi_call(hosted, "GET", "/api/flashcards", headers=hf)) == (200, []), "nichts gespeichert"

    _, hp = user(hosted, "plus@beispiel.de", plan="plus")
    mid = seed(hosted, hp)
    sid, d = save(hosted, hp, card["cards"])
    assert d["count"] == 1, d
    st, d = post(hosted, hp, "/api/sync/push", {"device_id": "ipad", "items": [
        {"entity": "flashcards", "local_id": -1, "data": {"question": "Q", "answer": "A", "stack_id": sid}}]})
    assert d["results"][0]["status"] == "created", d
    st, stacks = _j(asgi_call(hosted, "GET", "/api/flashcard-stacks", headers=hp))
    assert st == 200 and [s["cards"] for s in stacks if s["id"] == sid] == [2]


def test_ai_stack_needs_pro_ai_and_verified_email(hosted, texts):  # noqa: F811
    from app import ai_backend
    fake = FakeCardsAI()
    ai_backend.set_provider(fake)
    _, hp = user(hosted, "plus2@beispiel.de", plan="plus")
    mid = seed(hosted, hp)
    st, d = post(hosted, hp, "/api/ai/flashcards", {"module_id": mid, "lecture_week": 3, "count": 10})
    assert (st, d["code"], d["entitlement"], d["required_plan"]) == (403, "plan_required", "can_use_ai_generated_questions", "pro_ai"), d
    _, hu = user(hosted, "unbestaetigt@beispiel.de", plan="pro_ai", verified=False)
    mid_u = seed(hosted, hu)
    st, d = post(hosted, hu, "/api/ai/flashcards", {"module_id": mid_u, "lecture_week": 3, "count": 10})
    assert (st, d["code"]) == (403, "email_unverified")
    assert fake.calls == 0 and ent(hosted, hu)["quotas"]["ai_assist"]["used"] == 0


def test_ai_stack_consumes_ai_assist_and_refunds_on_errors(hosted, texts, monkeypatch):  # noqa: F811
    from app import ai_backend
    fake = FakeCardsAI()
    ai_backend.set_provider(fake)
    _, h = user(hosted, "proai@beispiel.de", plan="pro_ai")
    mid = seed(hosted, h)
    used = lambda: ent(hosted, h)["quotas"]["ai_assist"]["used"]  # noqa: E731
    st, d = post(hosted, h, "/api/ai/flashcards", {"module_id": mid, "lecture_week": 3, "count": 12, "request_id": "r-1"})
    assert st == 200 and len(d["cards"]) == 12 and d["sources"][0]["file_id"] == "f3", d
    assert "Umfang: Lernwoche 3" in fake.prompts[-1] and "Laplace-Entwicklung" in fake.prompts[-1]
    assert used() == 1
    st, again = post(hosted, h, "/api/ai/flashcards", {"module_id": mid, "lecture_week": 3, "count": 12, "request_id": "r-1"})
    assert st == 200 and again["cards"] == d["cards"] and fake.calls == 1, "gleiche Anfrage-ID: gespeicherte Antwort, nicht doppelt bezahlt"
    assert used() == 1
    # Vorschlag in einen Stapel der Woche speichern, danach erneut: vorhandene Fragen stehen im Prompt
    st, d = post(hosted, h, "/api/ai/flashcards", {"module_id": mid, "week": 3, "count": 5, "request_id": "r-2"})
    _, s = save(hosted, h, d["cards"])
    assert s["count"] == 5
    st, d = post(hosted, h, "/api/ai/flashcards", {"module_id": mid, "lecture_week": 3, "count": 5, "request_id": "r-3", "again": True})
    assert st == 200 and "SCHON VORHANDEN" in fake.prompts[-1] and "Frage 0 Lauf 2?" in fake.prompts[-1]
    assert used() == 3
    # Fehler beim Anbieter, Absturz, keine Karten: zurueckgebucht
    for fail, empty, code in (("unavailable", False, 502), ("crash", False, 500), (None, True, 502)):
        ai_backend.set_provider(FakeCardsAI(fail=fail, empty=empty))
        body = json.dumps({"module_id": mid, "lecture_week": 3, "count": 5, "request_id": f"r-{fail}-{empty}"})
        if fail == "crash":                          # unerwarteter Fehler: 500 (im Test wirft der Aufruf durch)
            with pytest.raises(RuntimeError):
                asgi_call(hosted, "POST", "/api/ai/flashcards", headers=h, body=body)
        else:
            st, _, raw = asgi_call(hosted, "POST", "/api/ai/flashcards", headers=h, body=body)
            assert st == code, raw
        assert used() == 3, (fail, empty)
    # ohne Material: kein Verbrauch
    st, d = post(hosted, h, "/api/ai/flashcards", {"module_id": mid, "lecture_week": 9, "count": 5})
    assert (st, d["code"]) == (404, "no_content") and used() == 3
    # ohne Token-Preise sperrt der Dienst (Preispflicht) und bucht zurueck
    ai_backend.set_provider(FakeCardsAI())
    monkeypatch.delenv("LERNAPP_AI_PRICE_IN_EUR")
    st, d = post(hosted, h, "/api/ai/flashcards", {"module_id": mid, "lecture_week": 3, "count": 5})
    assert (st, d["code"]) == (503, "ai_not_configured_prices") and used() == 3


def test_ai_stack_respects_user_budget(hosted, texts, monkeypatch):  # noqa: F811
    from app import ai_backend
    ai_backend.set_provider(FakeCardsAI())
    monkeypatch.setenv("LERNAPP_AI_USER_BUDGET_EUR", "0.001")
    _, h = user(hosted, "budget@beispiel.de", plan="pro_ai")
    mid = seed(hosted, h)
    st, d = post(hosted, h, "/api/ai/flashcards", {"module_id": mid, "lecture_week": 3, "count": 5})
    assert (st, d["code"]) == (429, "ai_user_budget_exhausted"), d
    assert ent(hosted, h)["quotas"]["ai_assist"]["used"] == 0
