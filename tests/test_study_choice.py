"""Lernplaner: Faecher, Wochenwunsch, "Thema gemacht" (app/study_choice.py, Auftrag des Inhabers 14.11.2026). Die
Endpunkte im Einzelnen vergleicht study-plan.json (Szenario "faecher_wunsch") mit dem iPad-Kern; hier die Regeln:
Wunsch verschiebt Zeit ohne Klausuren zu gefaehrden, dringende Klausur bleibt vorn, abgewaehlte Faecher nie, nichts
doppelt. Feste Uhr, erfundene Module."""
from datetime import date, timedelta

from app import smart_planner as sp
from test_smart_goals import call, env, module  # noqa: F401 - Fixture und Helfer


def _days(n, start=date(2026, 11, 16), win=(540, 900)):
    return [{"date": (start + timedelta(i)).isoformat(), "weekday": (start + timedelta(i)).weekday(), "windows": [list(win)], "reserve": []}
            for i in range(n)]


def _minutes(blocks, mid, upto):
    return sum(b["minutes"] for b in blocks if b["module_id"] == mid and b["date"] <= upto)


def test_wish_moves_time_to_the_wished_subject_in_that_week_only():
    d = _days(70)
    inp = {"days": d, "settings": {"utilization": 60},
           "modules": [{"id": 1, "exam_date": d[40]["date"], "remaining_minutes": 40 * 60},
                       {"id": 2, "exam_date": d[60]["date"], "remaining_minutes": 40 * 60}]}
    plain = sp.plan(inp)
    wished = sp.plan(dict(inp, wish={"from": d[0]["date"], "to": d[6]["date"], "modules": [2]}))
    assert plain["status"] == wished["status"] == "ok"
    week = d[6]["date"]
    assert _minutes(wished["blocks"], 2, week) > _minutes(plain["blocks"], 2, week)
    assert _minutes(wished["blocks"], 1, week) < _minutes(plain["blocks"], 1, week)
    # beide Ziele voll, nie am oder nach dem Klausurtag
    for mid, exam in ((1, d[40]["date"]), (2, d[60]["date"])):
        assert sum(b["minutes"] for b in wished["blocks"] if b["module_id"] == mid) >= 40 * 60
        assert all(b["date"] < exam for b in wished["blocks"] if b["module_id"] == mid)


def test_wish_never_endangers_an_earlier_exam():
    d = _days(21, win=(540, 720))
    inp = {"days": d, "settings": {"utilization": 100}, "wish": {"from": d[0]["date"], "to": d[6]["date"], "modules": [2]},
           "modules": [{"id": 1, "exam_date": d[8]["date"], "remaining_minutes": 20 * 60},
                       {"id": 2, "exam_date": d[20]["date"], "remaining_minutes": 10 * 60}]}
    r = sp.plan(inp)
    assert r["feasible"], r["message"]
    assert sum(b["minutes"] for b in r["blocks"] if b["module_id"] == 1 and b["date"] < d[8]["date"]) >= 20 * 60


def test_wish_drops_a_deselected_subject(env):  # noqa: F811
    """Reihenfolge im alten Lernplan (dringende Klausur zuerst, dann der Wunsch) prueft study-plan.json Szenario
    faecher_wunsch ueber generate_packages; hier: abgewaehlt faellt aus dem Wunsch und ist nicht waehlbar"""
    app, _ = env
    from app import db, study, study_choice
    module("Physik", None, sort=0)
    c = module("Chemie", None, sort=1)
    st, w = call(app, "PUT", "/api/calendar/week-wish", {"modules": ["Chemie"]})
    assert st == 200 and w["modules"] == ["Chemie"]
    with db.cursor() as conn:
        assert study_choice.wish_for(conn, study.today())[2] == [c]
    assert call(app, "POST", "/api/calendar/modules", {"modules": [{"name": "Chemie", "planned": False}]})[0] == 200
    st, err = call(app, "PUT", "/api/calendar/week-wish", {"modules": ["Chemie"]})
    assert st == 422 and "kein Fach" in err["detail"]
    with db.cursor() as conn:
        assert study_choice.wish_for(conn, study.today()) is None
    assert all(x["name"] != "Chemie" for x in call(app, "GET", "/api/calendar/week-wish")[1]["choices"])


def test_smart_goals_follow_the_wish_and_skip_deselected(env):  # noqa: F811
    app, _ = env
    from app import db
    math = module("Mathe 1", "2027-01-25", sort=0)
    prog = module("Programmieren", "2027-02-22", sort=1)
    for mid in (math, prog):
        assert call(app, "PUT", f"/api/goals/{mid}", {"target_hours": 60})[0] == 200
    assert call(app, "POST", "/api/goals/plan", {})[0] == 200

    def week(mid):
        with db.cursor() as conn:
            return db.row(conn, "SELECT COALESCE(SUM(planned_minutes),0) m FROM study_packages WHERE source='smart' AND module_id=? "
                                "AND date BETWEEN '2026-11-16' AND '2026-11-22'", (mid,))["m"]
    before = week(prog)
    st, w = call(app, "PUT", "/api/calendar/week-wish", {"modules": ["Programmieren"]})
    assert st == 200 and w["plan"]["smart"] and w["plan"]["applied"]
    assert week(prog) > before
    st, _ = call(app, "POST", "/api/calendar/modules", {"modules": [{"name": "Programmieren", "planned": False}]})
    assert st == 200
    assert call(app, "GET", "/api/goals")[0] == 200
    assert week(prog) == 0, "abgewaehlt: keine Bloecke, auch mit Wunsch"


def test_topic_done_twice_is_once_and_adds_nothing(env):  # noqa: F811
    app, _ = env
    from app import db
    m = module("Mathe 1", sort=0)
    with db.cursor() as conn:
        conn.execute("INSERT INTO courses(id, title, subject, kind, module_id, active, created_at) VALUES ('k1', 'Mathe 1', 'Mathe 1', 'vorlesung', ?, 1, '2026-10-01')", (m,))
        conn.execute("INSERT INTO files(id, course_id, name, status) VALUES ('f1', 'k1', 'VL03.pdf', 'neu')")
        ids = []
        for day in ("2026-11-17", "2026-11-19"):                 # dieselbe Datei zweimal geplant
            pid = conn.execute("INSERT INTO study_packages(date, module_id, subject, title, planned_minutes, status, sort, generated, created_at, start_time, end_time) "
                               "VALUES (?, ?, 'Mathe 1', 'Reihen', 45, 'geplant', 0, 1, '2026-11-15', '10:00', '10:45')", (day, m)).lastrowid
            ids.append(conn.execute("INSERT INTO study_tasks(package_id, type, file_id, title, sort, est_minutes, status, created_at) "
                                    "VALUES (?, 'vorlesung', 'f1', 'VL03.pdf', 0, 45, 'geplant', '2026-11-15')", (pid,)).lastrowid)
        n_tasks = db.row(conn, "SELECT COUNT(*) n FROM study_tasks")["n"]
    st, r = call(app, "POST", "/api/calendar/topic-done", {"task_ids": [ids[0]]})
    assert st == 200 and r["done"] == 2 and len(r["freed"]) == 2, r
    st, r2 = call(app, "POST", "/api/calendar/topic-done", {"task_ids": [ids[0]]})
    assert st == 200 and r2["done"] == 0 and r2["freed"] == []
    with db.cursor() as conn:
        assert db.row(conn, "SELECT COUNT(*) n FROM study_tasks")["n"] == n_tasks, "keine neuen Eintraege (keine Wiederholungen)"
        assert db.rows(conn, "SELECT status FROM study_tasks") == [{"status": "erledigt"}] * n_tasks
        assert not db.row(conn, "SELECT 1 FROM study_packages WHERE date > '2026-11-16'"), "kuenftige Termine frei"
