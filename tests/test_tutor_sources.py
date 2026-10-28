"""KI-Tutor mit Quellen und Seitenangabe (28.10.2026, Pruefpunkt P13): die offene Seite und passende Seiten aus dem
Modul gehen nummeriert in den Prompt, die Antwort belegt mit [Nummer], die Oberflaeche verlinkt die Seiten."""
import json

from conftest import asgi_call


def test_tutor_gets_numbered_sources_and_reports_which_were_cited(app, monkeypatch):
    from app import ai, db, scriptsearch
    db.init_db()
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name) VALUES ('Quellen-Test')").lastrowid
        conn.execute("INSERT OR REPLACE INTO courses(id, title, module_id) VALUES ('q-kurs', 'Analysis', ?)", (mid,))
        conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status) VALUES ('q-blatt', 'q-kurs', 'Blatt3.pdf', 'neu')")
    seen = {}

    def fake_search(conn, module_id, query, exclude=None, limit=3):
        seen["module"], seen["query"] = module_id, query
        return {"results": [{"file_id": "q-blatt", "page": 2, "name": "Blatt3.pdf", "title": "Blatt 3", "snippet": "gleiche Seite"},
                            {"file_id": "q-skript", "page": 14, "name": "Skript.pdf", "title": "Skript Analysis", "snippet": "Sandwich-Lemma: ..."}]}
    monkeypatch.setattr(scriptsearch, "search", fake_search)
    monkeypatch.setattr(ai, "ask", lambda prompt, system: seen.setdefault("prompt", prompt) and "Nutze das Sandwich-Lemma [2], wie auf dieser Seite [1].")
    try:
        st, _, b = asgi_call(app, "POST", "/api/ai/tutor", body=json.dumps({"file_id": "q-blatt", "page": 2, "mode": "hints",
                                                                           "question": "Wie zeige ich Konvergenz?", "page_text": "Aufgabe 1: Konvergenz"}))
        d = json.loads(b)
        assert st == 200, d
        assert seen["module"] == mid and "Konvergenz" in seen["query"]
        assert "[1] Blatt3.pdf, Seite 2 (diese Seite)" in seen["prompt"] and "[2] Skript Analysis, Seite 14: Sandwich-Lemma" in seen["prompt"]
        assert "erfinde keine Quellen" in seen["prompt"]
        assert [(x["n"], x["file_id"], x["page"], x["cited"]) for x in d["sources"]] == [(1, "q-blatt", 2, True), (2, "q-skript", 14, True)], \
            "dieselbe Seite nicht doppelt, beide zitiert"
        # ohne Datei: keine Quellen, der Tutor laeuft weiter
        st, _, b = asgi_call(app, "POST", "/api/ai/tutor", body=json.dumps({"mode": "explain", "page_text": "x"}))
        assert st == 200 and json.loads(b)["sources"] == []
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM files WHERE id='q-blatt'")
            conn.execute("DELETE FROM courses WHERE id='q-kurs'")
            conn.execute("DELETE FROM modules WHERE id=?", (mid,))
