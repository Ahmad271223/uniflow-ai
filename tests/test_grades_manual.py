"""Selbst eingetragene Leistungen (Entscheidung des Inhabers 20.11.2026, app/grades_manual.py): abhaken und Note
eintragen, wenn QIS ein Modul nicht als bestanden meldet. Zaehlt in LP (Uni & Noten, Studienverlauf), in der Zahl der
bestandenen Leistungen und mit Note im Schnitt; QIS geht vor (keine Doppelzaehlung); 5,0 zaehlt nicht; Loeschen;
nie im Dienst. Nur erfundene Daten."""
import json
from pathlib import Path

import pytest
from conftest import asgi_call

ROOT = Path(__file__).resolve().parents[1]
FX = ROOT / "packages" / "shared-contracts" / "fixtures" / "study-plan-engine"


def qis(text, semester, status="bestanden", note="2,0", credits="5", nr=""):
    return (text, semester, status, note, "", nr, credits, "", None, None, "2026-11-01T08:00:00")


QIS_ROWS = [qis("Programmieren I", "WiSe 25/26", note="1,7"), qis("Mathematik I", "WiSe 25/26", credits="8", note="2,3"),
            qis("Programmieren II", "SoSe 26", "nicht bestanden", "5,0")]


@pytest.fixture()
def world(app, monkeypatch, tmp_path):
    """Datenbank mit Katalog (TIBSc22 aus dem Fixture) und drei QIS-Zeilen (13 LP bestanden), heute 04.11.2026"""
    from datetime import date
    from app import db, study
    monkeypatch.setattr(study, "today", lambda: date(2026, 11, 4))
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "selbst.db")
    db.init_db()
    fx = json.loads((FX / "endpoints.json").read_text(encoding="utf-8"))
    with db.cursor() as conn:
        for s in fx["seed"]:
            if not s["sql"].startswith("INSERT INTO grades"):
                conn.execute(s["sql"], s["params"])
        for s in next(s for s in fx["steps"] if "sql" in s)["sql"]:
            conn.execute(s["sql"], s["params"])
        add_qis(conn, QIS_ROWS)
    return app


def add_qis(conn, rows):
    conn.executemany("INSERT INTO grades(text, semester, status, note, versuch, pruefungsnr, credits, datum, abschluss, raw, "
                     "fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows)


def call(app, method, path, body=None):
    st, _, raw = asgi_call(app, method, path, body=None if body is None else json.dumps(body))
    return st, json.loads(raw)


def mods(plan):
    return {m["id"]: m for s in plan["semesters"] for m in s["modules"]}


def test_tick_off_counts_once_in_all_figures(world):
    app = world
    _, plan0 = call(app, "GET", "/api/study-plan")
    _, grades0 = call(app, "GET", "/api/grades")
    assert plan0["lp_done"] == grades0["credits"] == 13 and "lp_manual" not in plan0 and "manual" not in grades0
    _, detail = call(app, "GET", "/api/study-plan/module/rechnerstrukturen")
    assert detail["own"]["can_mark"] is True and detail["own"]["manual"] is None

    st, out = call(app, "POST", "/api/grades/manual", {"module_id": "rechnerstrukturen", "grade": "1,7", "semester": "SoSe 26",
                                                      "lp": 99, "title": "egal"})
    assert st == 200, out
    e = out["entry"]
    assert (e["title"], e["lp"], e["grade"], e["passed"], e["semester"], e["counted"], e["replaced"]) == \
        ("Rechnerstrukturen", 5, "1,7", True, "SoSe 26", True, False), "LP und Titel aus dem Katalog"

    _, plan = call(app, "GET", "/api/study-plan")
    m = mods(plan)["rechnerstrukturen"]
    assert (m["status"], m["grade"], m.get("manual")) == ("bestanden", "1,7", True)
    assert plan["lp_done"] == 18 and plan["lp_manual"] == 5
    assert "Rechnerstrukturen" not in plan["unmatched"]
    _, grades = call(app, "GET", "/api/grades")
    assert grades["credits"] == 18 and grades["credits_manual"] == 5 and grades["credits_qis"] == 13
    assert grades["passed"] == grades0["passed"] + 1
    assert grades["graded_count"] == grades0["graded_count"] + 1
    assert grades["average_exact"] == round((1.7 * 5 + 2.3 * 8 + 1.7 * 5) / 18, 2)
    assert not any(r.get("source") == "manuell" for r in grades["grades"]), "Notenspiegel-Zeilen bleiben QIS"
    _, detail = call(app, "GET", "/api/study-plan/module/rechnerstrukturen")
    assert detail["own"]["status"] == "bestanden" and detail["own"]["grade"] == "1,7"
    assert detail["own"]["manual"]["id"] == e["id"] and detail["own"]["can_mark"] is True
    assert detail["own"]["attempts"] == [], "der eigene Eintrag ist kein QIS-Versuch"

    # nochmal fuer dasselbe Modul: derselbe Eintrag wird geaendert (ohne Note: zaehlt, aber nicht im Schnitt)
    st, out = call(app, "POST", "/api/grades/manual", {"module_id": "rechnerstrukturen", "grade": ""})
    assert st == 200 and out["entry"]["id"] == e["id"] and out["entry"]["grade"] is None
    _, grades = call(app, "GET", "/api/grades")
    assert grades["credits"] == 18 and grades["graded_count"] == grades0["graded_count"]
    assert grades["average_exact"] == grades0["average_exact"]
    _, listed = call(app, "GET", "/api/grades/manual")
    assert len(listed["entries"]) == 1 and listed["credits_manual"] == 5


def test_qis_later_wins_without_double_count(world):
    from app import db
    app = world
    call(app, "POST", "/api/grades/manual", {"module_id": "rechnerstrukturen", "grade": "1,0"})
    with db.cursor() as conn:
        add_qis(conn, [qis("Rechnerstrukturen", "SoSe 26", note="2,7")])
    _, grades = call(app, "GET", "/api/grades")
    e = grades["manual"][0]
    assert e["replaced"] is True and e["counted"] is False and e["replaced_by"]["note"] == "2,7"
    assert grades["credits"] == 18 and grades["credits_manual"] == 0, "5 LP aus QIS, nicht noch einmal 5 selbst"
    _, plan = call(app, "GET", "/api/study-plan")
    m = mods(plan)["rechnerstrukturen"]
    assert plan["lp_done"] == 18 and m["grade"] == "2,7" and "manual" not in m
    _, detail = call(app, "GET", "/api/study-plan/module/rechnerstrukturen")
    assert detail["own"]["can_mark"] is False and detail["own"]["manual"]["replaced"] is True
    # QIS ueber die Pruefungsnummer (Programmieren II hat Kuerzel 1234 im Katalog), anderer Text
    call(app, "POST", "/api/grades/manual", {"module_id": "programmieren-2", "grade": "3,0"})
    _, grades = call(app, "GET", "/api/grades")
    assert grades["credits_manual"] == 5
    with db.cursor() as conn:
        add_qis(conn, [qis("Prog. 2 (Klausur)", "WiSe 26/27", note="3,3", nr="1234")])
    _, grades = call(app, "GET", "/api/grades")
    assert [x["replaced"] for x in grades["manual"]] == [True, True] and grades["credits"] == 23


def test_grade_five_is_not_passed_and_removal_works(world):
    app = world
    st, out = call(app, "POST", "/api/grades/manual", {"module_id": "et-2", "grade": "5,0"})
    assert st == 200 and out["entry"]["passed"] is False and out["entry"]["counted"] is False
    _, plan = call(app, "GET", "/api/study-plan")
    assert plan["lp_done"] == 13 and mods(plan)["et-2"]["status"] != "bestanden"
    _, grades = call(app, "GET", "/api/grades")
    assert grades["credits"] == 13 and grades["credits_manual"] == 0 and len(grades["manual"]) == 1
    st, _ = call(app, "DELETE", f"/api/grades/manual/{out['entry']['id']}")
    assert st == 200
    assert call(app, "DELETE", f"/api/grades/manual/{out['entry']['id']}")[0] == 404
    _, grades = call(app, "GET", "/api/grades")
    assert "manual" not in grades and grades["credits"] == 13


def test_free_entry_without_module_and_validation(world):
    app = world
    st, out = call(app, "POST", "/api/grades/manual", {"title": "  Spanisch   A1 ", "lp": "4,5", "grade": 2})
    assert st == 200 and (out["entry"]["title"], out["entry"]["lp"], out["entry"]["grade"]) == ("Spanisch A1", 4.5, "2,0")
    _, grades = call(app, "GET", "/api/grades")
    assert grades["credits"] == 17.5
    _, plan = call(app, "GET", "/api/study-plan")
    assert plan["lp_done"] == 17.5 and "Spanisch A1" not in plan["unmatched"]
    for bad in ({"title": "x", "grade": "0,7"}, {"title": "x", "grade": "2,35"}, {"title": "x", "grade": "sehr gut"},
                {"title": "x", "lp": "viele"}, {"title": "x", "lp": 61}, {"title": "x", "semester": "Herbst"},
                {"title": ""}, {"title": "x", "passed": "ja"}, {"id": 999, "title": "x"}):
        st, out = call(app, "POST", "/api/grades/manual", bad)
        assert st in (400, 404), (bad, out)


def test_never_in_hosted_service():
    from app import server
    for m, p in (("GET", "/api/grades/manual"), ("POST", "/api/grades/manual"), ("DELETE", "/api/grades/manual/3")):
        assert server.hosted_unavailable(m, p) == "Selbst eingetragene Noten bleiben auf deinem Gerät."


def test_not_in_device_sync():
    from app import sync
    assert "grades_manual" not in json.dumps(sync.ENTITIES, default=str)


def test_resolve_matches_module_rows_and_parts():
    from app import grades_manual, grades_model
    rows = grades_model.model([
        {"text": "Thermodynamik I", "semester": "WiSe 25/26", "status": "bestanden", "note": "2,0", "credits": "5"},
        {"text": "Studium Generale", "semester": "WiSe 25/26", "status": "", "note": "", "credits": "5", "versuch": ""},
        {"text": "Kompetenzbereich Pflichtmodule", "semester": "", "status": "bestanden", "note": "", "credits": "60"},
    ])
    out = grades_manual.resolve(rows, [
        {"id": 1, "title": "Thermodynamik I / Chemie", "code": None, "passed": True, "lp": 10},
        {"id": 2, "title": "Pflichtmodule", "code": None, "passed": True, "lp": 5},
        {"id": 3, "title": "Chemie", "code": None, "passed": True, "lp": 5},
    ])
    assert [e["replaced"] for e in out] == [True, False, False], "Teil laut QIS bestanden; Bereichszeilen nie"
