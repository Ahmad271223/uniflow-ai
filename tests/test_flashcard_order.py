"""KI-Karteikarten auf Auftrag (04.11.2026, app/flashcard_order.py, POST /api/ai/flashcards mit module_id): Material
genau dieser Lehrwoche, Anzahl 5-50, Schwerpunkt, vorhandene Karten der Stapel des Moduls weder im Prompt noch in der
Antwort doppelt. Aus der Cloud-Sitzung (tests/test_flashcard_stacks.py dort) an das Stapel-Modell angepasst: die
Karten liegen in `flashcard_stacks` (Fach = Modulname, Woche). Ohne echten KI-Aufruf."""
import json
import sqlite3
import time

import pytest
from conftest import asgi_call


def _j(r):
    st, _, b = r
    return st, (json.loads(b) if b else None)


def call(app, method, path, body=None):
    return _j(asgi_call(app, method, path, body=json.dumps(body) if body is not None else None))


@pytest.fixture
def world(app):
    """Modul mit Vorlesungen und Uebung in Lehrwoche 5 und 6 (Wochen aus dem Dateinamen, wie im Moduldetail)."""
    from app import db
    db.init_db()
    now = int(time.time())
    with db.cursor() as conn:
        conn.execute("DELETE FROM flashcards")
        conn.execute("DELETE FROM flashcard_stacks")
        mid = conn.execute("INSERT INTO modules(name, color) VALUES ('Analysis Stapeltest', '#175ee8')").lastrowid
        other = conn.execute("INSERT INTO modules(name) VALUES ('Anderes Modul Stapeltest')").lastrowid
        conn.execute("INSERT OR REPLACE INTO courses(id, title, kind, active, module_id) VALUES ('st-kurs', 'Analysis Stapeltest', 'vorlesung', 1, ?)", (mid,))
        for fid, name in (("st-vl5", "VL05_Reihen.pdf"), ("st-ue5", "Blatt05.pdf"), ("st-vl6", "VL06_Potenzreihen.pdf")):
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, status, kind, chdate) VALUES (?, 'st-kurs', ?, 'neu', 'pdf', ?)", (fid, name, now))
    yield {"mid": mid, "other": other}
    with db.cursor() as conn:
        conn.execute("DELETE FROM flashcards")
        conn.execute("DELETE FROM flashcard_stacks")
        conn.execute("DELETE FROM lecture_markers WHERE module_id=?", (mid,))
        conn.execute("DELETE FROM files WHERE course_id='st-kurs'")
        conn.execute("DELETE FROM courses WHERE id='st-kurs'")
        conn.execute("DELETE FROM modules WHERE id IN (?, ?)", (mid, other))


TEXTS = {"st-vl5": ["Reihen Definition Partialsumme", "Quotientenkriterium fuer Reihen", "Wurzelkriterium"],
         "st-ue5": ["Aufgabe 1: Konvergenz der harmonischen Reihe"],
         "st-vl6": ["Potenzreihen und Konvergenzradius"]}


def test_inputs_and_duplicates():
    from app import flashcard_order as fs
    assert [fs.stack_count(x) for x in (None, "abc", 1, 5, "30", 50, 51, 999, True)] == [20, 20, 5, 5, 30, 50, 50, 50, 20]
    assert [fs.parse_week(x) for x in (None, "", "module", 5, "7", 30)] == [None, None, None, 5, 7, 30]
    for bad in (0, 31, "x", 2.5, True, -1):
        with pytest.raises(fs.OrderError):
            fs.parse_week(bad)
    cards, dropped = fs.without_duplicates(
        [{"question": "Was ist eine Reihe?", "answer": "a"}, {"question": "  was IST eine reihe ", "answer": "b"},
         {"question": "Was besagt das Quotientenkriterium fuer Reihen genau?", "answer": "c"},
         {"question": "Was ist der Konvergenzradius?", "answer": "d"}],
        ["Was besagt das Quotientenkriterium fuer Reihen?"])
    assert [c["answer"] for c in cards] == ["a", "d"] and dropped == 2, "gleiche und fast gleiche Fragen fallen weg"
    assert fs.without_duplicates([{"question": "Ableitung?", "answer": "a"}, {"question": "Integral?", "answer": "b"}], ["ableitung"]) == \
        ([{"question": "Integral?", "answer": "b"}], 1), "kurze Fragen: gleicher Text zaehlt"
    assert len(fs.check_cards({"cards": [{"question": "q", "answer": "a"}] * 60}, 50)) == 50


def test_week_material_prefers_marked_pages_then_lectures_then_exercises(app, world, monkeypatch):
    from app import db, flashcard_order as fs, scriptsearch
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, file_id, *a, **k: TEXTS.get(file_id, []))
    mid = world["mid"]
    with db.cursor() as conn:
        m = fs.week_material(conn, mid, 5)
        assert [s["file_id"] for s in m["sources"]] == ["st-vl5", "st-ue5"] and not m["markers"]
        assert "Wurzelkriterium" in m["text"] and "harmonischen" in m["text"] and "Potenzreihen" not in m["text"]
        assert m["text"].index("Reihen Definition") < m["text"].index("Aufgabe 1"), "Vorlesung vor Uebung"
        # Marker "Vorlesung bis hier": in Woche 6 wurde VL05 bis Seite 3 behandelt (Seite 1-2 in Woche 5)
        for page, week in ((2, 5), (3, 6)):
            conn.execute("""INSERT INTO lecture_markers(user_id, module_id, file_id, doc_version, page, lecture_date, week_no, scope, created_at)
                            VALUES ('local', ?, 'st-vl5', 'v1', ?, ?, ?, 'personal', '2026-11-01T10:00:00')""", (mid, page, f"2026-11-0{page}", week))
        m6 = fs.week_material(conn, mid, 6)
        assert m6["markers"] and m6["sources"][0] == {"file_id": "st-vl5", "name": "VL05_Reihen.pdf", "pages": [3], "marked": True}
        assert "Wurzelkriterium" in m6["text"] and "Partialsumme" not in m6["text"] and "Potenzreihen" in m6["text"]
        whole = fs.week_material(conn, mid, None)
        assert [s["file_id"] for s in whole["sources"]] == ["st-vl5", "st-vl6"], "ganzes Modul: Vorlesungen aller Wochen"
        small = fs.week_material(conn, mid, None, budget=40)
        assert sum(len(t) for t in [small["text"]]) < 200 and len(small["sources"]) >= 1, "Budget wird eingehalten"
    assert fs.client_material([{"title": "Folie", "text": " Inhalt "}, {"text": ""}, "x"])["text"] == "### Folie\nInhalt"


def test_ai_stack_uses_week_material_and_avoids_existing(app, world, monkeypatch):
    from app import ai, db, flashcard_order as fs, scriptsearch
    monkeypatch.setattr(scriptsearch, "page_texts", lambda conn, file_id, *a, **k: TEXTS.get(file_id, []))
    mid = world["mid"]
    st, stack = call(app, "POST", "/api/flashcard-stacks", {"name": "Reihen", "subject": "Analysis Stapeltest", "week": 5})
    assert st == 200, stack
    assert call(app, "POST", "/api/flashcards", {"stack_id": stack["id"], "cards": [{"question": "Was ist eine Reihe?", "answer": "a"}]})[0] == 200
    seen = {}

    def fake_ask(prompt, system, schema=None):
        seen.update(prompt=prompt, system=system, schema=schema)
        return json.dumps({"cards": [{"question": "Was ist eine Reihe?", "answer": "doppelt"},
                                     {"question": "Was sagt das Wurzelkriterium?", "answer": "lim sup |a_n|^(1/n) < 1"},
                                     {"question": "", "answer": "leer"}]})
    monkeypatch.setattr(ai, "ask", fake_ask)
    with db.cursor() as conn:
        before = conn.execute("SELECT COUNT(*) FROM flashcards").fetchone()[0]
    st, d = call(app, "POST", "/api/ai/flashcards", {"module_id": mid, "week": 5, "count": 30, "topic": "Kriterien"})
    assert st == 200, d
    assert d["cards"] == [{"question": "Was sagt das Wurzelkriterium?", "answer": "lim sup |a_n|^(1/n) < 1"}]
    assert (d["count"], d["week"], d["duplicates_removed"], d["existing"], d["module_name"]) == (30, 5, 1, 1, "Analysis Stapeltest")
    assert [s["file_id"] for s in d["sources"]] == ["st-vl5", "st-ue5"]
    p = seen["prompt"]
    assert p.startswith("Modul: Analysis Stapeltest\nUmfang: Lernwoche 5\nQuellen: VL05_Reihen.pdf (Seiten 1–3); Blatt05.pdf (Seite 1)")
    assert "genau 30 Karteikarten" in p and "SCHWERPUNKT: Kriterien" in p and "- Was ist eine Reihe?" in p
    assert f"MATERIAL. {ai.UNTRUSTED}:" in p and "Potenzreihen" not in p
    assert seen["schema"] == ai.FLASHCARDS_SCHEMA and seen["system"] == ai.SYSTEM
    with db.cursor() as conn:
        assert conn.execute("SELECT COUNT(*) FROM flashcards").fetchone()[0] == before, "nur ein Vorschlag"
    # ganzes Modul, Anzahl begrenzt
    st, d = call(app, "POST", "/api/ai/flashcards", {"module_id": mid, "week": None, "count": 500})
    assert st == 200 and d["count"] == fs.STACK_COUNT_MAX and d["week"] is None and "Umfang: das ganze Modul" in seen["prompt"]
    # Fehler: unbekanntes Modul, falsche Woche, Woche ohne Material, nur Doppel
    assert call(app, "POST", "/api/ai/flashcards", {"module_id": 999999})[0] == 404
    assert call(app, "POST", "/api/ai/flashcards", {"module_id": mid, "lecture_week": "x"})[1]["code"] == "week_invalid"
    st, e = call(app, "POST", "/api/ai/flashcards", {"module_id": mid, "lecture_week": 9})
    assert (st, e["code"]) == (404, "no_content") and "Lernwoche 9" in e["detail"]
    st, d = call(app, "POST", "/api/ai/flashcards", {"module_id": mid, "lecture_week": 9, "material": [{"title": "Notiz", "text": "Taylorreihen"}]})
    assert st == 200 and d["sources"] == [{"file_id": None, "name": "Notiz", "pages": []}], "Material vom Geraet, wenn der Dienst keins hat"
    # aeltere Clients schicken lecture_week statt week
    st, d = call(app, "POST", "/api/ai/flashcards", {"module_id": mid, "lecture_week": 9, "material": [{"title": "Notiz", "text": "Taylorreihen"}]})
    assert st == 200 and d["week"] == 9
    monkeypatch.setattr(ai, "ask", lambda prompt, system, schema=None: '{"cards": [{"question": "Was ist eine Reihe?", "answer": "x"}]}')
    st, e = call(app, "POST", "/api/ai/flashcards", {"module_id": mid, "lecture_week": 5})
    assert (st, e["code"]) == (502, "ai_no_cards")
    # der alte Weg (Dokument) bleibt
    assert call(app, "POST", "/api/ai/flashcards", {})[0] == 400




def test_stacks_fixture_is_current():
    """Pruefdaten KI-Auftrag und geteilte Stapel (packages/shared-contracts/fixtures/flashcards/stacks.json) sind aktuell."""
    import subprocess
    import sys
    from pathlib import Path
    root = Path(__file__).resolve().parents[1]
    r = subprocess.run([sys.executable, "tools/gen-flashcard-stacks-fixture.py", "--check"], cwd=root, capture_output=True, text=True,
                       encoding="utf-8", timeout=300)
    assert r.returncode == 0, f"python tools/gen-flashcard-stacks-fixture.py neu ausfuehren\n{r.stdout}\n{r.stderr}"
