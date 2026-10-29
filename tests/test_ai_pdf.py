"""KI liest Lehrmaterial als PDF-Seiten mit Haiku 5.5 (docs/KI-MODELLVERGLEICH-2026-10-25.md)."""
import json
from pathlib import Path

import pytest


def _pdf(path: Path, pages: int) -> Path:
    from pypdf import PdfWriter
    w = PdfWriter()
    for _ in range(pages):
        w.add_blank_page(width=200, height=200)
    with open(path, "wb") as f:
        w.write(f)
    return path


def valid_test(title="Wochentest"):
    """Wochentest in der Form vom 29.10.2026: 15 Aufgaben, 4 leicht, 6 mittel, 5 schwer"""
    diffs = ["leicht"] * 4 + ["mittel"] * 6 + ["schwer"] * 5
    return {"title": title, "questions": [{"nr": i + 1, "type": "calc", "difficulty": d, "question": f"Aufgabe {i + 1}",
                                           "answer": "1", "points": 6 if i < 10 else 8, "exam_style": False}
                                          for i, d in enumerate(diffs)]}


@pytest.fixture
def captured(monkeypatch):
    """ai.ask ersetzen: merkt sich Aufrufe und den Inhalt des Arbeitsordners waehrend des Aufrufs."""
    from app import ai
    calls = []
    answers = []

    def fake_ask(prompt, system="", timeout=600, allowed_tools=None, model=None, cwd=None, blocked_tools=None):
        from pypdf import PdfReader
        seen = {p.name: len(PdfReader(str(p)).pages) for p in Path(cwd).glob("*.pdf")} if cwd else {}
        calls.append({"prompt": prompt, "model": model, "cwd": cwd, "allowed": allowed_tools, "blocked": blocked_tools, "pdfs": seen})
        a = answers.pop(0) if answers else {}
        if isinstance(a, Exception):
            raise a
        return json.dumps(a)

    monkeypatch.setattr(ai, "ask", fake_ask)
    return calls, answers


def test_default_material_model_is_haiku():
    from app import config
    assert config.CLAUDE_MODEL_MATERIAL == "haiku"


def test_analysis_reads_pdf_pages_in_isolated_folder(captured, tmp_path):
    from app import ai
    calls, answers = captured
    answers.append({"doc_type": "vorlesung", "title": "Laplace", "topics": ["Laplace"], "difficulty": 4})
    src = _pdf(tmp_path / "folien.pdf", 30)
    res = ai.analyze_file("Signale und Systeme", "folien.pdf", "kaputter Text", pdf_path=str(src))
    c = calls[0]
    assert res["doc_type"] == "vorlesung" and res["_input"] == "pdf"
    assert c["model"] == "haiku" and c["allowed"] == ["Read(./**)"]
    assert {"Bash", "Write", "Edit", "WebFetch", "WebSearch"} <= set(c["blocked"])
    assert c["pdfs"] == {"material1.pdf": ai.PDF_PAGES_ANALYSIS} == {"material1.pdf": 10}   # gekuerzte Kopie
    assert str(Path(c["cwd"]) / "material1.pdf") in c["prompt"]              # absoluter Pfad im Arbeitsordner
    assert str(src) not in c["prompt"] and "Seiten 1 bis 10 von 30" in c["prompt"]
    assert not Path(c["cwd"]).exists()                                        # Arbeitsordner wieder geloescht


def test_analysis_falls_back_to_text(captured, tmp_path):
    from app import ai
    calls, answers = captured
    answers += [RuntimeError("CLI weg"), RuntimeError("CLI weg"), {"doc_type": "uebung", "title": "Blatt 1"}]
    src = _pdf(tmp_path / "blatt.pdf", 2)
    res = ai.analyze_file("Mathe I", "blatt.pdf", "Aufgabe 1: ...", pdf_path=str(src))
    assert res["_input"] == "text" and res["doc_type"] == "uebung"                 # zwei PDF-Versuche, dann Text
    assert calls[2]["model"] == "haiku" and calls[2]["cwd"] is None and "Aufgabe 1" in calls[2]["prompt"]


def test_unreadable_answer_is_not_stored_as_analysis(captured, tmp_path):
    """Live-Fehler 25.10.2026: 'PDF nicht lesbar' wurde als Analyse uebernommen und ersetzte gute alte."""
    from app import ai
    calls, answers = captured
    answers += [{"doc_type": "sonstiges", "title": "Analyse nicht moeglich: material1.pdf nicht lesbar"},
                {"doc_type": "vorlesung", "title": "Laplace-Transformation", "summary": "..."}]
    res = ai.analyze_file("SigSys", "vl.pdf", "", pdf_path=str(_pdf(tmp_path / "vl.pdf", 3)))
    assert res["_input"] == "pdf" and res["doc_type"] == "vorlesung" and len(calls) == 2
    assert ai._unreadable({"title": "PDF konnte nicht gelesen werden"}) and not ai._unreadable({"title": "Lesbarkeit von Code"})


def test_analysis_of_non_pdf_uses_text(captured, tmp_path):
    from app import ai
    calls, answers = captured
    answers.append({"doc_type": "uebung"})
    p = tmp_path / "loesung.py"; p.write_text("print(1)")
    assert ai.analyze_file("Programmieren", "loesung.py", "print(1)", pdf_path=str(p))["_input"] == "text"
    assert len(calls) == 1 and calls[0]["cwd"] is None


def test_weekly_test_page_budget_and_text_rest(captured, tmp_path):
    from app import ai
    calls, answers = captured
    answers.append(valid_test())
    mats = [{"name": f"vl{i}.pdf", "title": f"VL {i}", "doc_type": "vorlesung", "difficulty": 3,
             "local_path": str(_pdf(tmp_path / f"vl{i}.pdf", 15)), "text": f"Text {i}"} for i in range(5)]
    mats.append({"name": "code.py", "title": "Code", "doc_type": "uebung", "local_path": None, "text": "def f(): pass"})
    res = ai.generate_test("Mathe I", 45, mats)
    c = calls[0]
    assert res["_input"] == "pdf" and c["model"] == "haiku"
    assert sorted(c["pdfs"].values()) == [10, 10, 10, 10]                    # 40 Seiten Budget, 10 je Datei
    assert "Text 4" in c["prompt"] and "def f(): pass" in c["prompt"]        # Rest als Text dabei
    assert "VL 0 (vorlesung" in c["prompt"]                                   # Zuordnung Datei -> Titel


def test_weekly_test_falls_back_to_text(captured, tmp_path):
    from app import ai
    calls, answers = captured
    answers += [{"title": "leer"}, valid_test("PDF nicht lesbar"),       # zwei untaugliche PDF-Antworten
                valid_test()]
    mats = [{"name": "vl.pdf", "local_path": str(_pdf(tmp_path / "vl.pdf", 3)), "text": "Grenzwerte"}]
    res = ai.generate_test("Mathe I", 45, mats)
    assert res["_input"] == "text" and "Grenzwerte" in calls[2]["prompt"] and calls[2]["cwd"] is None


def test_reanalyze_replaces_only_text_analyses(app, tmp_path, monkeypatch):
    from app import ai, db, planner
    pdf = str(_pdf(tmp_path / "vl.pdf", 3))
    with db.cursor() as conn:
        conn.execute("INSERT OR IGNORE INTO courses(id, title, kind, created_at) VALUES ('ra-c', 'Mathe RA', 'vorlesung', '2026-10-25')")
        for fid in ("ra-1", "ra-2", "ra-3"):
            conn.execute("INSERT OR REPLACE INTO files(id, course_id, name, local_path, kind) VALUES (?, 'ra-c', ?, ?, 'pdf')", (fid, f"{fid}.pdf", pdf))
        conn.execute("INSERT OR REPLACE INTO analysis(file_id, doc_type, raw) VALUES ('ra-1', 'sonstiges', '{}')")              # aus Text
        conn.execute("""INSERT OR REPLACE INTO analysis(file_id, doc_type, raw) VALUES ('ra-2', 'vorlesung', '{"_input": "pdf"}')""")  # schon PDF
        conn.execute("INSERT OR REPLACE INTO analysis(file_id, doc_type, raw) VALUES ('ra-3', 'uebung', '{}')")                 # aus Text, scheitert

    def fake(course, name, text, pdf_path=None):
        if name.startswith("ra-3"):
            return {"doc_type": "vorlesung", "_input": "text"}      # nur Text-Rueckfall -> alte Analyse behalten
        return {"doc_type": "vorlesung", "title": "neu", "_input": "pdf"}

    monkeypatch.setattr(ai, "analyze_file", fake)
    r = planner.reanalyze_pdfs(workers=1, log=lambda *_: None)
    with db.cursor() as conn:
        types = dict(conn.execute("SELECT file_id, doc_type FROM analysis WHERE file_id LIKE 'ra-%'").fetchall())
        conn.execute("DELETE FROM analysis WHERE file_id LIKE 'ra-%'"); conn.execute("DELETE FROM files WHERE id LIKE 'ra-%'")
        conn.execute("DELETE FROM courses WHERE id='ra-c'")
    assert r == {"gesamt": 2, "neu": 1, "behalten": 1, "typ_geaendert": 1}
    assert types == {"ra-1": "vorlesung", "ra-2": "vorlesung", "ra-3": "uebung"}
