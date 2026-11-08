"""Audit 08.11.2026, Paket 49 (KI-Datenfluss, Uebungen, Altklausuren) – Python-Seite von app/weekly.py.

Gleiche Regeln im Swift-Kern (apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/AuditPaket4849Tests.swift):
- P49-06: Musterloesung ueber den Dateinamen – "Blatt 1" bekam ueber den Teilwort-Rueckfall die Loesung von "Blatt 10"
- Textmengen: der Prompt der Fachpruefung blieb mit vielen Uebungsquellen nicht unter der Grenze der Aufgabe `weekly`
  (app/ai_relay.py, 120 000 Zeichen), der Wochentest scheiterte dann in jeder Runde mit 413
Bericht: docs/audit/AUDIT-2026-11-08-PAKET-48-49.md
"""
import pytest

from test_weekly import env  # noqa: F401  (Fixture: frische Datenbank, Modul 1, FakeAI)

MOD = 1


def _task(c, file_id, source, nr):
    c.execute("""INSERT INTO task_index(file_id, version, module_id, source, nr, label, page_from, page_to, text, lecture_refs,
                 content_hash, indexed_at) VALUES (?, 'v', ?, ?, ?, ?, 1, 1, ?, '[]', 'h', '2026-11-01T10:00:00')""",
              (file_id, MOD, source, nr, f"{file_id} {nr}", f"Text von {file_id}, Aufgabe {nr}"))


def _solution(c, file_id, nr):
    r = c.execute("SELECT solution_file_id FROM task_index WHERE file_id=? AND nr=?", (file_id, nr)).fetchone()
    return r[0] if r else "fehlt"


def test_p49_06_sheet_one_never_gets_the_solution_of_sheet_ten(env):  # noqa: F811
    from app import weekly
    for fid, name in [("b1", "Übungsblatt 1.pdf"), ("b10", "Übungsblatt 10.pdf"), ("l10", "Übungsblatt 10 Lösung.pdf"),
                      ("b2", "Blatt 2.pdf"), ("b20", "Blatt 20.pdf"), ("l2", "Lösung Blatt 2.pdf"),
                      ("b3", "Blatt 3.pdf"), ("l3", "Übungsblatt 3 Musterlösung.pdf")]:
        env.add_file(fid, name, "Übungsblätter", [f"Aufgabe 1: Text von {name} mit genug Inhalt fuer eine Aufgabe."])
    with env.conn() as c:
        c.execute("DELETE FROM task_index")
        for f in ("b1", "b10", "b2", "b20", "b3"):
            _task(c, f, "uebungsblatt", "1")
        for f in ("l10", "l2", "l3"):
            _task(c, f, "loesung", "1")
        weekly._link_solutions(c, MOD)
        assert _solution(c, "b10", "1") == "l10"
        assert _solution(c, "b1", "1") is None, "Blatt 1 hat keine Loesung, nie die von Blatt 10"
        assert _solution(c, "b2", "1") == "l2"
        assert _solution(c, "b20", "1") is None, "Blatt 20 hat keine Loesung, nie die von Blatt 2"
        assert _solution(c, "b3", "1") == "l3", "Rueckfall ueber den Namensteil mit gleicher Nummer bleibt"


def _long(n):
    return ("wort " * (n // 5 + 1))[:n]


def _big_context(env):  # noqa: F811
    """Echtes build_context: 60 neue Seiten (von 80 markierten), 12 fruehere Abschnitte, fuenf Uebungsquellen mit je 5
    Aufgaben und 4 Altklausuraufgaben (das Hoechstmass von build_context), lange Aufgaben und Loesungen, Kursbeschreibung.
    Vorher: Entwurf ~89 000, Fachpruefung mit 15 ausfuehrlichen Aufgaben ~123 000 Zeichen (Grenze 120 000)."""
    import json

    from app import db, weekly
    seg = {"file_id": "lec-prog1", "version": "v", "week": 3, "marker_id": 2, "topic": "Neues Thema", "lecture_date": "2026-11-03",
           "lecture_end": "2026-11-03T12:00:00"}
    prior = [{**seg, "from": k + 1, "to": k + 1, "week": 1, "topic": "T" * 120} for k in range(12)]
    cov = {"new": [{**seg, "from": 13, "to": 92}], "prior": prior, "blocked": []}
    plan = {"id": 1, "module_id": MOD, "week_no": 3, "scope_key": "k", "coverage": json.dumps(cov), "lecture_end": "2026-11-03T12:00:00"}
    srcs = ["uebungsblatt", "zusatz", "hoersaaluebung", "gruppenuebung", "tutorium"]
    ok = [{"id": k + 1, "source": s, "label": f"{s} · Blatt · Aufgabe {k + 1}", "text": _long(6000), "solution_text": _long(5000),
           "file_id": "ex4", "page_from": 1, "points": 10.0, "difficulty": 3, "exam_term": "WS 23" if s == "altklausur" else None,
           "is_new_week": True, "refs": [{"file_id": "lec-prog1", "page": 20, "score": 9.0}]}
          for k, s in enumerate([x for x in srcs for _ in range(5)] + ["altklausur"] * 4)]
    with env.conn() as c:
        # Stud.IP-Kurs mit Beschreibung und Hinweisen (geht als Einordnung mit, app/course_context.py)
        c.execute("UPDATE courses SET description=?, miscellaneous=? WHERE id='cv'", (_long(2000), _long(1000)))
        db.row(c, "SELECT 1")
        return weekly.build_context(c, plan, {"ok": ok, "excluded": []}, [])


def test_p49_prompts_stay_below_the_relay_limit_with_many_exercise_sources(env):  # noqa: F811
    from app import ai_relay, weekly
    limit = ai_relay._tasks()["weekly"].max_chars
    ctx = _big_context(env)
    assert len(ctx["tasks"]) == 29 and len(ctx["lecture"]) == 60
    q = {"nr": 1, "level": "mittel", "type": "calc", "topic": "Thema", "difficulty": 3, "question": _long(400), "answer": _long(800),
         "steps": [_long(150)] * 4, "rubric": [{"criterion": _long(80), "points": 5}] * 3, "points": 7, "refs": ["L1", "A2"],
         "from_exam": None, "exam_mode": None}
    assert len(weekly._gen_prompt(ctx)) < limit
    assert len(weekly._review_prompt(ctx, [q] * 15)) < limit, "die Fachpruefung muss der Dienst annehmen"
    assert all(len(t["text"]) >= 500 and len(t["solution"]) >= 300 for t in ctx["tasks"])


@pytest.mark.parametrize("n,task,sol", [(1, 1400, 900), (14, 1400, 900), (29, 689, 448), (100, 500, 300)])
def test_p49_few_tasks_keep_their_full_length(n, task, sol):
    """Bis 14 Aufgaben wie bisher (1400/900 Zeichen), Vertrag weekly.json unveraendert"""
    from app import weekly
    assert (weekly._task_chars(n), weekly._solution_chars(n)) == (task, sol)
