"""Faecher im Lernkalender am PC-Dienst (Fehlerbericht des Inhabers 13.11.2026, Build 37): "Mathe 1" abgewaehlt
(Einstellung plan_modules_off, kommt vom iPad per Geraeteabgleich), trotzdem eingeplant. Ein abgewaehltes Fach bekommt
nie Lernpakete, Lernbloecke oder Lernziel-Vorschlaege; unberuehrte automatische Pakete verschwinden, selbst angelegte
und gesperrte bleiben; Umbenennen behaelt die Wahl; wieder angehakt plant normal. Gleiche Faelle wie
apps/apple/.../PlanModulesOffTests.swift. Feste Uhr: Montag, 16.11.2026, 08:00 (Berlin). Alle Werte erfunden."""
import json

from test_smart_goals import call, env, module  # noqa: F401 - Fixture und Helfer


def set_off(names):
    from app import db
    with db.cursor() as conn:
        conn.execute("INSERT INTO settings(key, value) VALUES ('plan_modules_off', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                     (json.dumps(sorted(names)),))


def packages(mid):
    from app import db
    with db.cursor() as conn:
        return db.rows(conn, "SELECT * FROM study_packages WHERE module_id=? ORDER BY date, start_time, id", (mid,))


def test_smart_planner_never_plans_a_deselected_module(env):  # noqa: F811
    app, _ = env
    math = module("Mathe 1", "2027-01-25", sort=0)
    prog = module("Programmieren", "2027-02-08", sort=1)
    for mid in (math, prog):
        assert call(app, "PUT", f"/api/goals/{mid}", {"target_hours": 60})[0] == 200
    assert call(app, "POST", "/api/goals/plan", {})[0] == 200
    mine = packages(math)
    assert len(mine) > 2
    locked = mine[-1]["id"]
    assert call(app, "PATCH", f"/api/goals/blocks/{locked}", {"locked": True})[0] == 200

    set_off({"Mathe 1"})                                   # Wahl kommt per Abgleich vom iPad
    st, o = call(app, "GET", "/api/goals")
    assert st == 200
    assert [p["id"] for p in packages(math)] == [locked], "automatische Bloecke weg, gesperrter bleibt"
    assert all(m["module_id"] != math for m in o["modules"])
    assert all(m["module_id"] != math for m in o["modules_without_goal"])
    assert any(m["module_id"] == prog for m in o["modules"])
    st, err = call(app, "PUT", f"/api/goals/{math}", {"target_hours": 80})
    assert st == 409 and "nicht im Lernkalender" in err["detail"]
    assert call(app, "POST", "/api/goals/plan", {})[0] == 200
    assert [p["id"] for p in packages(math)] == [locked], "neu planen legt nichts an"
    assert packages(prog), "andere Faecher bleiben geplant"

    set_off(set())                                         # wieder angehakt
    st, o = call(app, "GET", "/api/goals")
    assert any(m["module_id"] == math for m in o["modules"])
    assert call(app, "POST", "/api/goals/plan", {})[0] == 200
    assert len(packages(math)) > 1


def test_old_planner_rescue_sync_and_rename(env, monkeypatch):  # noqa: F811
    app, _ = env
    from app import db, study
    math = module("Mathe 1", sort=0)
    phys = module("Physik", sort=1)
    # alter Lernplan: jedes Modul haette offenen Stoff; das abgewaehlte kommt nicht in die Warteschlangen
    monkeypatch.setattr(study, "_units", lambda conn, mid, *a, **k: [{"week": 3, "vorlesungen": [], "uebungen": []}])
    set_off({"Mathe 1"})
    with db.cursor() as conn:
        queues, _ = study._queues(conn, set(), db.get_settings(conn))
        assert math not in queues and phys in queues
        # automatisches Paket (z. B. vor der Abwahl von einem anderen Geraet), eigenes Paket mit nachzuholender Aufgabe
        auto = conn.execute("INSERT INTO study_packages(date, module_id, subject, title, planned_minutes, status, sort, generated, created_at) "
                            "VALUES ('2026-11-18', ?, 'Mathe 1', 'Vom iPad', 45, 'geplant', 0, 1, '2026-11-15T09:00:00')", (math,)).lastrowid
        conn.execute("INSERT INTO study_tasks(package_id, type, title, sort, est_minutes, status, created_at) VALUES (?, 'frei', 'Reihen', 0, 45, 'geplant', '2026-11-15')", (auto,))
        own = conn.execute("INSERT INTO study_packages(date, module_id, subject, title, planned_minutes, status, sort, generated, created_at) "
                           "VALUES ('2026-11-10', ?, 'Mathe 1', 'Eigenes Paket', 30, 'geplant', 0, 0, '2026-11-09T09:00:00')", (math,)).lastrowid
        conn.execute("INSERT INTO study_tasks(package_id, type, title, sort, est_minutes, status, created_at) VALUES (?, 'frei', 'Altes Blatt', 0, 30, 'nachholen', '2026-11-09')", (own,))
        # Woche retten: die nachzuholende Aufgabe des abgewaehlten Fachs wird nicht neu verteilt
        assert all(m["module_id"] != math for m in study.suggest_reschedule(conn, horizon=7, max_share=0.6)["moves"])
        # nach dem Abgleich (auto_plan_week laeuft danach): automatisches Paket weg, eigenes bleibt
        study.auto_plan_week(conn, 0, log=lambda *a: None)
    assert [p["title"] for p in packages(math)] == ["Eigenes Paket"]

    # Umbenennen am PC behaelt die Abwahl
    assert call(app, "PATCH", f"/api/modules/{math}", {"name": "Mathe I"})[0] == 200
    with db.cursor() as conn:
        assert study.plan_off(conn) == {"Mathe I"}
        assert math in study.plan_off_ids(conn)
