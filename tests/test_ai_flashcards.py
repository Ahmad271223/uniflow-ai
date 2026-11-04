"""Karteikarten aus einem Dokument (03.11.2026): Prompt und Pruefung in app/ai.py, Endpunkt POST /api/ai/flashcards
(nur Vorschlaege; gespeichert wird mit POST /api/flashcards), Lehrwoche fuer /api/tests/generate. Ohne KI-Aufruf."""
import json

from conftest import asgi_call


def test_prompt_names_pages_count_topic_and_marks_text_as_material():
    from app import ai
    p = ai.flashcards_prompt("Testmathe I", "vl02.pdf", [3, 4, 5], "  Konvergenz  ", 7, " Beweise ")
    assert p.startswith("Kurs: Testmathe I\nDatei: vl02.pdf, Seiten 3–5\n\nAUFGABE: Erstelle genau 7 Karteikarten")
    assert "SCHWERPUNKT: Beweise" in p and f"INHALT. {ai.UNTRUSTED}:\n<<<\nKonvergenz\n>>>" in p
    assert p.endswith('{"cards": [{"question": "Frage", "answer": "Antwort"}]}')
    assert "Seite 7\n" in ai.flashcards_prompt("K", "f.pdf", [7], "x")
    assert "[kein Text extrahierbar]" in ai.flashcards_prompt("K", "f.pdf", None, " \n") and "SCHWERPUNKT" not in ai.flashcards_prompt("K", "f.pdf", [], "x", 3, " ")
    assert len(ai.flashcards_prompt("K", "f.pdf", [], "x" * 20000)) < 20000 + 600, "Text gekuerzt"


def test_check_and_count():
    from app import ai
    assert ai.check_flashcards({"cards": [{"question": " F ", "answer": " A "}, {"question": "", "answer": "x"}, "Text"]}) == [{"question": "F", "answer": "A"}]
    assert ai.check_flashcards([{"question": 1, "answer": 2}]) == [{"question": "1", "answer": "2"}]
    assert ai.check_flashcards({"cards": "nein"}) == [] and ai.check_flashcards("Text") == [] and ai.check_flashcards(None) == []
    assert len(ai.check_flashcards({"cards": [{"question": "q", "answer": "a"}] * 50})) == ai.FLASHCARDS_MAX
    assert [ai.flashcards_count(x) for x in (None, "", 0, -1, 5, "12", 31, "abc", 2.7)] == [10, 10, 10, 10, 5, 12, 30, 10, 2]
    assert ai.FLASHCARDS_SCHEMA["required"] == ["cards"] and ai.FLASHCARDS_SCHEMA["properties"]["cards"]["items"]["required"] == ["question", "answer"]


def test_endpoint_uses_chosen_pages_and_schema_and_only_suggests(app, monkeypatch):
    from app import ai, db, scriptsearch
    db.init_db()
    with db.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO courses(id, title) VALUES ('fc-kurs', 'Analysis')")
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status) VALUES ('fc-datei', 'fc-kurs', 'vl03.pdf', 'neu')")
        before = conn.execute("SELECT COUNT(*) FROM flashcards").fetchone()[0]
    seen = {}
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, file_id: ["Seite eins Grenzwerte", "Seite zwei Cauchy", "Seite drei Reihen"])

    def fake_ask(prompt, system, schema=None):
        seen["prompt"], seen["system"], seen["schema"] = prompt, system, schema
        return '{"cards": [{"question": " Was ist eine Cauchy-Folge? ", "answer": "Glieder kommen sich beliebig nahe."}, {"question": "", "answer": "x"}]}'
    monkeypatch.setattr(ai, "ask", fake_ask)
    try:
        st, _, b = asgi_call(app, "POST", "/api/ai/flashcards", body=json.dumps({"file_id": "fc-datei", "pages": [3, 2, 3, 99, "2"], "count": "2", "topic": "Konvergenz"}))
        d = json.loads(b)
        assert st == 200, d
        assert d["pages"] == [2, 3] and d["count"] == 2
        assert d["cards"] == [{"question": "Was ist eine Cauchy-Folge?", "answer": "Glieder kommen sich beliebig nahe."}]
        assert seen["system"] == ai.SYSTEM and seen["schema"] == ai.FLASHCARDS_SCHEMA
        assert seen["prompt"].startswith("Kurs: Analysis\nDatei: vl03.pdf, Seiten 2–3\n") and "genau 2 Karteikarten" in seen["prompt"]
        assert "Seite zwei Cauchy\n\nSeite drei Reihen" in seen["prompt"] and "Seite eins" not in seen["prompt"]
        # ohne Seitenangabe die ersten Seiten, Vorgabe fuer die Zahl
        st, _, b = asgi_call(app, "POST", "/api/ai/flashcards", body=json.dumps({"file_id": "fc-datei"}))
        assert st == 200 and json.loads(b)["pages"] == [1, 2, 3] and json.loads(b)["count"] == ai.FLASHCARDS_DEFAULT
        with db.cursor() as conn:
            assert conn.execute("SELECT COUNT(*) FROM flashcards").fetchone()[0] == before, "nur Vorschlaege, nichts gespeichert"
        # Fehler: ohne file_id 400, unbekannte Datei 404, ohne Karten 502
        assert asgi_call(app, "POST", "/api/ai/flashcards", body=json.dumps({}))[0] == 400
        assert asgi_call(app, "POST", "/api/ai/flashcards", body=json.dumps({"file_id": "gibt-es-nicht"}))[0] == 404
        monkeypatch.setattr(ai, "ask", lambda prompt, system, schema=None: "keine Karten")
        st, _, b = asgi_call(app, "POST", "/api/ai/flashcards", body=json.dumps({"file_id": "fc-datei"}))
        assert st == 502 and json.loads(b)["code"] == "ai_no_cards", b
        monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, file_id: [])
        st, _, b = asgi_call(app, "POST", "/api/ai/flashcards", body=json.dumps({"file_id": "fc-datei"}))
        assert st == 404 and json.loads(b)["code"] == "no_content", b
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM files WHERE id='fc-datei'")
            conn.execute("DELETE FROM courses WHERE id='fc-kurs'")


def test_generate_passes_the_lecture_week(app, monkeypatch):
    from app import db, planner, server
    db.init_db()
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name) VALUES ('Wochen-Test')").lastrowid
    seen = {}
    monkeypatch.setattr(planner, "create_test", lambda subject, dur, **kw: seen.update(subject=subject, dur=dur, **kw) or 1)
    monkeypatch.setattr(server, "_run_bg", lambda name, fn: {"started": name, "result": fn()})
    try:
        st, _, b = asgi_call(app, "POST", "/api/tests/generate", body=json.dumps({"module_id": mid, "duration_min": 30, "week_no": "4"}))
        assert st == 200, b
        assert seen == {"subject": "Wochen-Test", "dur": 30, "module_id": mid, "week_no": 4, "auto": False,
                        "options": {"count": 15, "difficulty": "beliebig", "types": ["mc", "tf", "cloze", "short", "calc"], "topic": ""}}
        st, _, _ = asgi_call(app, "POST", "/api/tests/generate", body=json.dumps({"module_id": mid}))
        assert st == 200 and seen["week_no"] is None and seen["dur"] is None, "ohne Woche wie bisher"
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM modules WHERE id=?", (mid,))
