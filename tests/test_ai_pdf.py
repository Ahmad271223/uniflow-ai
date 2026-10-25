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
    assert c["pdfs"] == {"material1.pdf": ai.PDF_PAGES_ANALYSIS}          # gekuerzte Kopie, nicht das Original
    assert str(src.parent) not in c["prompt"] and "Seiten 1 bis 12 von 30" in c["prompt"]
    assert not Path(c["cwd"]).exists()                                        # Arbeitsordner wieder geloescht


def test_analysis_falls_back_to_text(captured, tmp_path):
    from app import ai
    calls, answers = captured
    answers += [RuntimeError("CLI weg"), {"doc_type": "uebung", "title": "Blatt 1"}]
    src = _pdf(tmp_path / "blatt.pdf", 2)
    res = ai.analyze_file("Mathe I", "blatt.pdf", "Aufgabe 1: ...", pdf_path=str(src))
    assert res["_input"] == "text" and res["doc_type"] == "uebung"
    assert calls[1]["model"] == "haiku" and calls[1]["cwd"] is None and "Aufgabe 1" in calls[1]["prompt"]


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
    answers.append({"title": "Wochentest", "questions": [{"nr": 1, "type": "calc", "question": "x", "answer": "1", "points": 100}]})
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
    answers += [{"title": "leer"}, {"title": "Wochentest", "questions": [{"nr": 1, "points": 100}]}]   # PDF-Antwort ohne Fragen
    mats = [{"name": "vl.pdf", "local_path": str(_pdf(tmp_path / "vl.pdf", 3)), "text": "Grenzwerte"}]
    res = ai.generate_test("Mathe I", 45, mats)
    assert res["_input"] == "text" and "Grenzwerte" in calls[1]["prompt"] and calls[1]["cwd"] is None
