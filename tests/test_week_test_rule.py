"""Wochentest nach der Entscheidung des Inhabers vom 29.10.2026 (docs/ENTSCHEIDUNGEN-INHABER-2026-10-29.md): jedes
Modul, aus allen Folien der Woche, genau 15 Aufgaben (4 leicht, 6 mittel, 5 schwer); mit Altklausur ist genau eine
schwere Aufgabe im Stil der Klausur. Eine Antwort in anderer Form wird verworfen und einmal neu angefordert."""
import json

import pytest

from test_ai_pdf import valid_test


@pytest.fixture
def fake_ask(monkeypatch):
    from app import ai
    calls, answers = [], []

    def ask(prompt, system="", timeout=600, allowed_tools=None, model=None, cwd=None, blocked_tools=None):
        calls.append(prompt)
        return json.dumps(answers.pop(0) if answers else {})

    monkeypatch.setattr(ai, "ask", ask)
    return calls, answers


def test_prompt_asks_for_exactly_15_with_distribution():
    from app import ai
    p = ai._test_prompt("Testmathe", 45, "### Folien")
    assert "Genau 15 Aufgaben: genau 4 leicht, genau 6 mittel und genau 5 schwer" in p
    assert '"difficulty": "leicht" | "mittel" | "schwer"' in p and "Altklausur" not in p
    with_exam = ai._test_prompt("Testmathe", 45, "### Folien", "### Klausur WiSe 25/26\nAufgabe 1 ...")
    assert "Genau EINE der 5 schweren Aufgaben ist im Stil dieser Klausur" in with_exam and "Aufgabe 1 ..." in with_exam


def test_check_accepts_only_the_decided_form():
    from app import ai
    assert ai.check_week_test(valid_test()) is None
    t = valid_test(); t["questions"].pop()
    assert ai.check_week_test(t) == "14 statt 15 Aufgaben"
    t = valid_test(); t["questions"][0]["difficulty"] = "mittel"
    assert ai.check_week_test(t) == "Verteilung 3 leicht, 7 mittel, 5 schwer statt 4 leicht, 6 mittel, 5 schwer"
    t = valid_test(); t["questions"][3]["difficulty"] = "einfach"
    assert ai.check_week_test(t) == "Aufgabe 4 ohne gueltige Schwierigkeit"
    t = valid_test(); t["questions"][2].update(type="mc", options=["A"])
    assert ai.check_week_test(t) == "Aufgabe 3 (Multiple-Choice) ohne Antwortmoeglichkeiten"
    t = valid_test(); t["questions"][5]["answer"] = " "
    assert ai.check_week_test(t) == "Aufgabe 6 ohne Text oder Musterloesung"
    t = valid_test(); t["questions"][7]["points"] = True
    assert ai.check_week_test(t) == "Aufgabe 8 ohne Punkte"
    assert ai.check_week_test([]) == "keine JSON-Objekt-Antwort"


def test_check_exam_style():
    from app import ai
    t = valid_test()
    assert ai.check_week_test(t, exam=True) == "nicht genau eine schwere Aufgabe im Stil der Altklausur"
    t["questions"][14]["exam_style"] = True
    assert ai.check_week_test(t, exam=True) is None
    assert ai.check_week_test(t, exam=False) == "Aufgabe im Stil einer Altklausur ohne Altklausur"
    t["questions"][14]["exam_style"], t["questions"][0]["exam_style"] = False, True       # leichte Aufgabe
    assert ai.check_week_test(t, exam=True) == "nicht genau eine schwere Aufgabe im Stil der Altklausur"


def test_wrong_form_is_requested_once_more(fake_ask):
    from app import ai
    calls, answers = fake_ask
    short = valid_test(); short["questions"] = short["questions"][:8]
    answers += [short, valid_test()]
    res = ai.generate_test("Testmathe", 45, [{"name": "vl.txt", "text": "Grenzwerte"}])
    assert res["_input"] == "text" and len(res["questions"]) == 15 and len(calls) == 2


def test_wrong_form_twice_is_an_error_not_a_test(fake_ask):
    from app import ai
    calls, answers = fake_ask
    short = valid_test(); short["questions"] = short["questions"][:8]
    answers += [short, short]
    with pytest.raises(ai.AIError, match="zweimal nicht in der geforderten Form"):
        ai.generate_test("Testmathe", 45, [{"name": "vl.txt", "text": "Grenzwerte"}])
    assert len(calls) == 2


def test_exam_goes_into_prompt_and_check(fake_ask):
    from app import ai
    calls, answers = fake_ask
    good = valid_test(); good["questions"][14]["exam_style"] = True
    answers += [valid_test(), good]                       # erste Antwort ohne Klausuraufgabe -> neu anfordern
    res = ai.generate_test("Testmathe", 45, [{"name": "vl.txt", "text": "Grenzwerte"}],
                           exam={"title": "Klausur WiSe 25/26", "text": "Aufgabe 1: Bestimmen Sie den Grenzwert"})
    assert len(calls) == 2 and "Aufgabe 1: Bestimmen Sie den Grenzwert" in calls[0]
    assert sum(q["exam_style"] for q in res["questions"]) == 1


def test_planner_finds_the_module_exam_and_keys_it(app, tmp_path, monkeypatch):
    from app import ai, db, planner, testshare
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, created_at) VALUES ('Testmodul Klausur', '#123456', '2026-10-29')").lastrowid
        conn.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active) VALUES ('wk-c', 'Testkurs', 'vorlesung', '2026-10-29', ?, 1)", (mid,))
        for fid, name, chdate, kind in [("wk-k1", "klausur-alt.pdf", 1, "klausur"), ("wk-k2", "klausur-neu.pdf", 2, "klausur"), ("wk-v", "vl1.pdf", 3, "vorlesung")]:
            conn.execute("INSERT INTO files(id, course_id, name, chdate, text_excerpt, content_sha256, kind) VALUES (?, 'wk-c', ?, ?, ?, ?, 'pdf')",
                         (fid, name, chdate, f"Text {name}", "h-" + fid))
            conn.execute("INSERT INTO analysis(file_id, doc_type, raw) VALUES (?, ?, '{}')", (fid, kind))
    try:
        with db.cursor() as conn:
            exam = planner._exam_for_test(conn, mid)
            assert exam["id"] == "wk-k2" and exam["text"] == "Text klausur-neu.pdf"
            assert planner._exam_for_test(conn, None) is None
        seen = {}

        def fake_generate(subject, minutes, materials, exam=None):
            seen["exam"] = exam
            return valid_test()

        monkeypatch.setattr(planner, "_materials_for_test", lambda conn, subject, **kw: [{"id": "wk-v", "name": "vl1.pdf", "text": "x", "content_sha256": "h-wk-v"}])
        monkeypatch.setattr(ai, "generate_test", fake_generate)
        tid = planner.create_test("Testmodul Klausur", 45, module_id=mid, week_no=2, auto=True, log=lambda *_: None)
        assert seen["exam"]["id"] == "wk-k2"
        with db.cursor() as conn:
            key = db.row(conn, "SELECT share_key FROM tests WHERE id=?", (tid,))["share_key"]
        assert key.startswith("wt2:")
        assert key == testshare.share_key("luh", 45, [{"content_sha256": "h-wk-v"}, {"content_sha256": "h-wk-k2"}])
        assert key != testshare.share_key("luh", 45, [{"content_sha256": "h-wk-v"}]), "Klausur aendert den Schluessel"
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM tests WHERE module_id=?", (mid,))
            conn.execute("DELETE FROM analysis WHERE file_id LIKE 'wk-%'")
            conn.execute("DELETE FROM files WHERE id LIKE 'wk-%'")
            conn.execute("DELETE FROM courses WHERE id='wk-c'")
            conn.execute("DELETE FROM modules WHERE id=?", (mid,))
