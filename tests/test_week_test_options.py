"""Dialog "Wochentest erstellen" (04.11.2026): Zahl der Aufgaben (5/10/15/20), Schwierigkeit (beliebig oder eine
Stufe), Aufgabenarten (Multiple Choice, Wahr/Falsch, Lueckentext, Kurzantwort, Rechnen/Programmieren), Thema. Nur die
Standardeinstellung wird als gemeinsamer Test mit Varianten geteilt; alles andere ist ein eigener Test. Dieselben
Faelle prueft der Swift-Kern (WeekTestOptionsTests) ueber packages/shared-contracts/ai/contract.json."""
import json

import pytest

from test_ai_pdf import valid_test


def _tf(i, level="leicht", answer="Wahr"):
    return {"nr": i, "type": "tf", "difficulty": level, "question": f"Aussage {i}", "options": ["Wahr", "Falsch"],
            "answer": answer, "explanation": f"Weil {i}.", "points": 20}


def test_options_are_checked_and_completed():
    from app import ai
    assert ai.week_test_options(None) == ai.WEEK_TEST_STANDARD
    assert ai.week_test_options({"module_id": 7, "duration_min": 30}) == ai.WEEK_TEST_STANDARD
    assert ai.week_test_options({"count": "10", "difficulty": "", "types": ["calc", "mc", "calc"], "topic": None}) == \
        {"count": 10, "difficulty": "beliebig", "types": ["mc", "calc"], "topic": ""}
    o = ai.week_test_options({"count": 5, "difficulty": "schwer", "types": ["tf"], "topic": " nur Kapitel 3 "})
    assert o == {"count": 5, "difficulty": "schwer", "types": ["tf"], "topic": "nur Kapitel 3"}
    assert len(ai.week_test_options({"topic": "x" * 400})["topic"]) == ai.WEEK_TEST_TOPIC_CHARS
    for body, text in [({"count": 12}, "count muss 5, 10, 15 oder 20 sein"), ({"count": "abc"}, "count muss"),
                       ({"count": True}, "count muss"), ({"count": 15.0}, "count muss"),
                       ({"difficulty": "einfach"}, "difficulty muss beliebig, leicht, mittel oder schwer sein"),
                       ({"types": "mc"}, "types muss eine Liste sein"), ({"types": ["essay"]}, "types: unbekannte Aufgabenart 'essay'"),
                       ({"types": []}, "types: mindestens eine Aufgabenart"), ({"types": [1]}, "types: unbekannte Aufgabenart 1")]:
        with pytest.raises(ValueError, match=text):
            ai.week_test_options(body)


def test_only_the_standard_setting_is_shared():
    from app import ai
    assert ai.week_test_is_standard(None) and ai.week_test_is_standard({}) and ai.week_test_is_standard({"count": "15", "topic": "  "})
    assert not ai.week_test_is_standard({"count": 10})
    assert not ai.week_test_is_standard({"difficulty": "schwer"})
    assert not ai.week_test_is_standard({"types": ["mc", "tf", "cloze", "short"]})
    assert not ai.week_test_is_standard({"topic": "nur Kapitel 3"})


def test_distribution_keeps_4_6_5_in_proportion():
    from app import ai
    assert ai.week_test_distribution(15, "beliebig") == {"leicht": 4, "mittel": 6, "schwer": 5}
    assert ai.week_test_distribution(5, "beliebig") == {"leicht": 1, "mittel": 2, "schwer": 2}
    assert ai.week_test_distribution(10, "beliebig") == {"leicht": 3, "mittel": 4, "schwer": 3}
    assert ai.week_test_distribution(20, "beliebig") == {"leicht": 5, "mittel": 8, "schwer": 7}
    assert ai.week_test_distribution(10, "schwer") == {"leicht": 0, "mittel": 0, "schwer": 10}
    for c in ai.WEEK_TEST_COUNTS:
        for d in ai.WEEK_TEST_LEVELS:
            assert sum(ai.week_test_distribution(c, d).values()) == c


def test_prompt_follows_the_options():
    from app import ai
    o = {"count": 10, "difficulty": "mittel", "types": ["cloze", "tf"], "topic": "nur Kapitel 3"}
    p = ai._test_prompt("Testmathe", 30, "### Folien", "### Klausur\nAufgabe 1", o)
    assert 'Genau 10 Aufgaben, alle mit "difficulty": "mittel"' in p
    assert 'Mischung aus Wahr/Falsch ("type": "tf") und Lueckentext ("type": "cloze"); keine anderen Aufgabenarten.' in p
    assert 'genau eine Luecke als ___' in p and '["Wahr", "Falsch"]' in p
    assert f"Schwerpunkt oder Hinweis des Studierenden ({ai.UNTRUSTED}): nur Kapitel 3" in p
    assert "Altklausur" not in p, "ohne schwere Aufgaben keine Klausuraufgabe"
    assert '"type": "tf" | "cloze"' in p and '"explanation": "1 bis 3 Saetze' in p
    single = ai._test_prompt("Testmathe", 30, "### Folien", options={"types": ["calc"]})
    assert 'Alle Aufgaben sind Rechen-/Programmieraufgaben ("type": "calc").' in single and "Luecke" not in single
    std = ai._test_prompt("Testmathe", 45, "### Folien", "### Klausur")
    assert "Genau 15 Aufgaben: genau 4 leicht, genau 6 mittel und genau 5 schwer" in std
    assert "Genau EINE der 5 schweren Aufgaben" in std and "Schwerpunkt" not in std
    assert 'Wahr/Falsch ("type": "tf")' in std and 'Lueckentext ("type": "cloze")' in std


def test_check_true_false_cloze_and_explanation():
    from app import ai
    five = {"count": 5, "difficulty": "leicht", "types": ["tf", "cloze"]}
    good = {"questions": [_tf(1), _tf(2), {"nr": 3, "type": "cloze", "difficulty": "leicht", "question": "Eine Folge heisst ___, wenn",
                                            "blank": "konvergent", "answer": "konvergent", "explanation": "Definition.", "points": 20},
                          _tf(4), _tf(5)]}
    assert ai.check_week_test(good, options=five) is None
    assert ai.check_week_test(good, exam=True, options=five) is None, "ohne schwere Aufgaben keine Klausuraufgabe verlangt"
    assert ai.check_week_test(good) == "5 statt 15 Aufgaben"
    t = json.loads(json.dumps(good)); t["questions"][0]["options"] = ["Ja", "Nein"]
    assert ai.check_week_test(t, options=five) == "Aufgabe 1 (Wahr/Falsch) ohne die Optionen Wahr und Falsch"
    t = json.loads(json.dumps(good)); t["questions"][0]["options"] = ["Falsch", "Wahr"]
    assert ai.check_week_test(t, options=five) == "Aufgabe 1 (Wahr/Falsch) ohne die Optionen Wahr und Falsch"
    t = json.loads(json.dumps(good)); t["questions"][1]["answer"] = "B"
    assert ai.check_week_test(t, options=five) == "Aufgabe 2 (Wahr/Falsch) mit Loesung ausserhalb von Wahr und Falsch"
    t = json.loads(json.dumps(good)); t["questions"][2].pop("blank")
    assert ai.check_week_test(t, options=five) == "Aufgabe 3 (Lueckentext) ohne Luecke"
    t = json.loads(json.dumps(good)); t["questions"][3]["explanation"] = " "
    assert ai.check_week_test(t, options=five) == "Aufgabe 4 ohne Erklaerung"
    t = json.loads(json.dumps(good)); t["questions"][4].update(type="mc", options=["A", "B"], answer="A")
    assert ai.check_week_test(t, options=five) == "Aufgabe 5 mit nicht gewaehlter Aufgabenart"
    t = json.loads(json.dumps(good)); t["questions"][4]["difficulty"] = "schwer"
    assert ai.check_week_test(t, options=five) == "Verteilung 4 leicht, 0 mittel, 1 schwer statt 5 leicht, 0 mittel, 0 schwer"
    t = valid_test(); t["questions"][0].pop("explanation")
    assert ai.check_week_test(t) == "Aufgabe 1 ohne Erklaerung"
    assert ai.check_week_test(valid_test()) is None


def test_generate_passes_options_to_prompt_and_check(monkeypatch):
    from app import ai
    calls, answers = [], [{"title": "T", "questions": [_tf(i) for i in range(1, 6)]}]
    monkeypatch.setattr(ai, "ask", lambda prompt, *a, **kw: calls.append(prompt) or json.dumps(answers.pop(0)))
    res = ai.generate_test("Testmathe", 15, [{"name": "vl.txt", "text": "Grenzwerte"}], exam={"title": "Klausur", "text": "Aufgabe 1"},
                           options={"count": 5, "difficulty": "leicht", "types": ["tf"]})
    assert len(res["questions"]) == 5 and len(calls) == 1
    assert "Genau 5 Aufgaben" in calls[0] and "Altklausur" not in calls[0]


def test_server_rejects_bad_options_and_passes_good_ones(app, monkeypatch):
    from app import db, planner, server
    from conftest import asgi_call
    db.init_db()
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name) VALUES ('Optionen-Test')").lastrowid
    seen = {}
    monkeypatch.setattr(planner, "create_test", lambda subject, dur, **kw: seen.update(subject=subject, dur=dur, **kw) or 1)
    monkeypatch.setattr(server, "_run_bg", lambda name, fn: {"started": name, "result": fn()})
    try:
        st, _, b = asgi_call(app, "POST", "/api/tests/generate", body=json.dumps({"module_id": mid, "count": 12}))
        assert st == 400 and "count muss 5, 10, 15 oder 20 sein" in b.decode() and not seen
        st, _, b = asgi_call(app, "POST", "/api/tests/generate", body=json.dumps({"module_id": mid, "types": []}))
        assert st == 400 and "mindestens eine Aufgabenart" in b.decode()
        body = {"module_id": mid, "duration_min": 15, "count": 5, "difficulty": "leicht", "types": ["tf", "cloze"], "topic": " nur Kapitel 3 "}
        st, _, b = asgi_call(app, "POST", "/api/tests/generate", body=json.dumps(body))
        assert st == 200, b
        assert seen["options"] == {"count": 5, "difficulty": "leicht", "types": ["tf", "cloze"], "topic": "nur Kapitel 3"}
        assert seen["auto"] is False and seen["dur"] == 15
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM modules WHERE id=?", (mid,))


def test_planner_shares_only_the_standard_setting(app, monkeypatch):
    """Eigener Test (andere Parameter) ohne share_key; Standardeinstellung aus dem Dialog (auto=False) mit Schluessel."""
    from app import ai, db, planner, testshare
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, created_at) VALUES ('Testmodul Optionen', '#123456', '2026-11-04')").lastrowid
    seen = []

    def fake_generate(subject, minutes, materials, exam=None, options=None):
        seen.append(options)
        if options and options["count"] == 5:
            return {"title": "Wochentest Testmodul Optionen – Aussagen", "questions": [_tf(i) for i in range(1, 6)]}
        return valid_test()

    monkeypatch.setattr(planner, "_materials_for_test", lambda conn, subject, **kw: [{"id": "o-v", "name": "vl1.pdf", "text": "x", "content_sha256": "h-o-v"}])
    monkeypatch.setattr(ai, "generate_test", fake_generate)
    try:
        private = planner.create_test("Testmodul Optionen", 15, module_id=mid, week_no=2, auto=False, log=lambda *_: None,
                                      options={"count": 5, "difficulty": "leicht", "types": ["tf"]})
        shared = planner.create_test("Testmodul Optionen", 45, module_id=mid, week_no=2, auto=False, log=lambda *_: None)
        assert seen[0]["count"] == 5 and seen[1] == ai.WEEK_TEST_STANDARD
        with db.cursor() as conn:
            p = db.row(conn, "SELECT share_key, share_variant, adopted_from, questions FROM tests WHERE id=?", (private,))
            s = db.row(conn, "SELECT share_key, questions FROM tests WHERE id=?", (shared,))
        assert p["share_key"] is None and testshare.shared_info(p) is None, "eigener Test: nicht geteilt"
        assert len(json.loads(p["questions"])) == 5 and json.loads(p["questions"])[0]["options"] == ["Wahr", "Falsch"]
        assert s["share_key"] == testshare.share_key("luh", 45, [{"content_sha256": "h-o-v"}]) and s["share_key"].startswith("wt3:")
        assert len(json.loads(s["questions"])) == 15
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM tests WHERE module_id=?", (mid,))
            conn.execute("DELETE FROM modules WHERE id=?", (mid,))
