"""Lernstand je Modul (app/mastery.py, docs/LERNSTAND-2026-11-04.md): die gemeinsamen Faelle aus
packages/shared-contracts/fixtures/mastery/cases.json (dieselben prueft MasteryTests im Swift-Kern) und das Feld
`mastery` in GET /api/modules und GET /api/modules/{id} auf einer erfundenen Datenbank."""
import json
from pathlib import Path

from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "packages" / "shared-contracts" / "fixtures" / "mastery" / "cases.json"


def _cases():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))["cases"]


def test_fixture_cases():
    from app import mastery
    assert len(_cases()) >= 12
    for c in _cases():
        i = c["input"]
        got = mastery.compute([tuple(t) for t in i["tests"]], i["cards_right"], i["cards_wrong"], i["tasks_done"], i["tasks_total"])
        assert got == c["expected"], c["name"]


def test_fixture_rules_hold():
    """Was die Faelle zeigen sollen: der neueste Test wiegt mehr, ohne Signal None, Deckel bei 100."""
    from app import mastery
    assert mastery.compute([(5, 10), (9, 10)], 0, 0, 0, 0)["score"] > mastery.compute([(9, 10), (5, 10)], 0, 0, 0, 0)["score"]
    assert mastery.compute([], 0, 0, 0, 0) is None
    assert mastery.compute([("x", 10), (None, 10)], 0, 0, 0, 0) is None, "kaputte Werte zaehlen nicht"
    assert mastery.compute([(10, 10)], 9, 0, 3, 3)["score"] == 100
    assert mastery.reason(1, 1, 1, 1) == "1 Wochentest, 1 Karte, 1 von 1 Aufgabe"
    assert mastery.reason(0, 0, 0, 0) == ""


def _get(app, path):
    st, _, raw = asgi_call(app, "GET", path)
    assert st == 200, raw[:200]
    return json.loads(raw)


def test_module_endpoints_carry_mastery(app):
    from app import db
    name = "Lernstandmodul Test"
    with db.cursor() as conn:
        conn.execute("DELETE FROM modules WHERE name=?", (name,))
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES (?, '#175ee8', 99, '2026-11-01')", (name,)).lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES ('ls-vl', 'Vorlesung Lernstand', ?, 'vorlesung', 1, ?, '2026-11-01')", (name, mid))
        conn.execute("INSERT INTO files(id, course_id, name, chdate, status) VALUES ('ls-f1', 'ls-vl', 'V1.pdf', 1761900000, 'neu')")
        # Wochentests: der aeltere 50 %, der neuere 90 % (zaehlt doppelt); einer ohne Abgabe und einer eines anderen
        # Nutzers zaehlen nicht; der dritte nur ueber das Fach zugeordnet
        conn.execute("INSERT INTO tests(subject, questions, module_id, submitted_at, score, max_score) VALUES (?, '[]', ?, '2026-10-20T13:00:00', 5, 10)", (name, mid))
        conn.execute("INSERT INTO tests(subject, questions, module_id, submitted_at, score, max_score) VALUES (?, '[]', ?, '2026-10-27T13:00:00', 9, 10)", (name, mid))
        conn.execute("INSERT INTO tests(subject, questions, module_id) VALUES (?, '[]', ?)", (name, mid))
        conn.execute("INSERT INTO tests(subject, questions, module_id, user_id, submitted_at, score, max_score) VALUES (?, '[]', ?, 'fremd', '2026-10-28T13:00:00', 0, 10)", (name, mid))
        # Karten: 3 richtig, 1 falsch, 1 ohne Urteil, 1 versteckt (zaehlt nicht), 1 nur ueber das Fach zugeordnet (richtig)
        for res, hidden, fid, subj in (("right", 0, "ls-f1", None), ("right", 0, "ls-f1", None), ("wrong", 0, "ls-f1", None), (None, 0, "ls-f1", None),
                                       ("wrong", 1, "ls-f1", None), ("right", 0, None, name)):
            conn.execute("INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due, last_result, hidden) VALUES (?,?,?,?,'2026-11-01',1,'2026-11-02',?,?)",
                         (fid, subj, "F", "A", res, hidden))
        pid = conn.execute("INSERT INTO study_packages(date, module_id, subject, title, created_at) VALUES ('2026-11-02', ?, ?, 'Woche 3', '2026-10-27')", (mid, name)).lastrowid
        for st in ("erledigt", "erledigt", "geplant", "verschoben"):
            conn.execute("INSERT INTO study_tasks(package_id, type, file_id, title, status, created_at) VALUES (?, 'vorlesung', 'ls-f1', 'Lesen', ?, '2026-10-27')", (pid, st))
    try:
        # T = (1*50 + 2*90) / 3 = 76.67; K = 3 von 4 = 75; A = 2 von 4 = 50 -> 0.5*76.67 + 0.3*75 + 0.2*50 = 70.83 -> 71
        want = {"score": 71, "reason": "2 Wochentests, 4 Karten, 2 von 4 Aufgaben", "tests": 2, "cards": 4, "tasks_done": 2, "tasks_total": 4}
        detail = _get(app, f"/api/modules/{mid}")
        assert detail["mastery"] == want
        assert detail["progress"] == 100, "'bearbeitet' bleibt die alte Zahl (gelesene Vorlesung)"
        mods = {m["name"]: m for m in _get(app, "/api/modules")}
        assert mods[name]["mastery"] == want
        assert set(mods[name]) >= {"progress", "file_count", "task_count", "test_count", "mastery"}
        with db.cursor() as conn:
            conn.execute("UPDATE study_tasks SET status='erledigt' WHERE package_id=?", (pid,))
            conn.execute("DELETE FROM tests WHERE module_id=?", (mid,))
            conn.execute("UPDATE flashcards SET last_result=NULL WHERE subject=? OR file_id='ls-f1'", (name,))
        assert _get(app, f"/api/modules/{mid}")["mastery"] == {"score": 100, "reason": "4 von 4 Aufgaben", "tests": 0, "cards": 0, "tasks_done": 4, "tasks_total": 4}
        with db.cursor() as conn:
            conn.execute("DELETE FROM study_tasks WHERE package_id=?", (pid,))
        assert _get(app, f"/api/modules/{mid}")["mastery"] is None, "ohne Signal: noch kein Lernstand"
    finally:
        with db.cursor() as conn:
            conn.execute("DELETE FROM study_tasks WHERE package_id=?", (pid,))
            conn.execute("DELETE FROM study_packages WHERE id=?", (pid,))
            conn.execute("DELETE FROM flashcards WHERE subject=? OR file_id='ls-f1'", (name,))
            conn.execute("DELETE FROM tests WHERE module_id=?", (mid,))
            conn.execute("DELETE FROM files WHERE id='ls-f1'")
            conn.execute("DELETE FROM courses WHERE id='ls-vl'")
            conn.execute("DELETE FROM modules WHERE id=?", (mid,))


# ---------------------------------------------------------------- Sicherheitspruefung 04.11.2026

def test_no_division_by_zero_bounds_and_determinism():
    """Null-Nenner (Hoechstpunkte 0, keine Karten, keine Aufgaben) sind kein Signal statt eines Absturzes; jede
    Kombination auch abwegiger Werte bleibt zwischen 0 und 100; derselbe Eingang gibt immer dasselbe Ergebnis."""
    import itertools
    import random
    from app import mastery
    inf, nan = float("inf"), float("nan")
    assert mastery.compute([(5, 0), (0, 0), (3, -2), (nan, 10), (4, nan)], 0, 0, 0, 0) is None
    assert mastery.compute([], 0, 0, 7, 0) is None, "erledigte Aufgaben ohne Aufgaben zaehlen nicht"
    odd_tests = [[], [(inf, 10)], [(10, inf)], [(inf, inf)], [(-50, 10)], [(500, 10)], [(1e308, 1e-308)], [(0, 10), (10, 10)]]
    odd_counts = [0, 1, 7, 10**9]
    for tests, r, w, d, n in itertools.product(odd_tests, odd_counts, [0, 3], [0, 5, 10**9], [0, 3, 10**9]):
        got = mastery.compute(tests, r, w, d, n)
        if got is None:
            continue
        assert isinstance(got["score"], int) and 0 <= got["score"] <= 100, (tests, r, w, d, n, got)
        assert got == mastery.compute(list(tests), r, w, d, n)
    assert mastery.compute([(inf, inf)], 0, 0, 0, 0)["score"] == 0, "inf/inf ist NaN -> 0 wie max(0, NaN) in Swift"
    # Zufall mit festem Startwert: Grenzen und Wiederholbarkeit
    rnd = random.Random(20261104)
    for _ in range(2000):
        tests = [(rnd.uniform(-20, 120), rnd.choice([0, 10, 100, 0.5])) for _ in range(rnd.randint(0, 6))]
        args = (tests, rnd.randint(0, 50), rnd.randint(0, 50), rnd.randint(0, 40), rnd.randint(0, 30))
        a, b = mastery.compute(*args), mastery.compute(*args)
        assert a == b
        assert a is None or 0 <= a["score"] <= 100
    # Reihenfolge der Tests zaehlt (neuester wiegt mehr), sonst nichts Zufaelliges
    assert mastery.compute([(0, 10), (10, 10)], 0, 0, 0, 0)["score"] == 67
    assert mastery.compute([(10, 10), (0, 10)], 0, 0, 0, 0)["score"] == 33
