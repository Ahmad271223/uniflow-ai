"""Lernpakete nie nach der Lernzeit und nie nach 24:00 (Fehler vom echten iPhone vom 14.11.2026: study_packages mit
23:15 bis "25:15" und 23:00 bis "25:15" bei Lernzeit 08:00-21:00, 4 Stunden je Tag, 15 Minuten Pause, 2 Faecher je
Tag, Sonntag frei). Ursache: assign_slots legte, was in kein freies Fenster mehr passte, "hinter den letzten belegten
Block", ohne Tagesgrenze (im Swift-Kern genauso). Gemeinsame Fixture mit dem Swift-Kern: study-plan.json, Szenario
"lernzeit" (LocalStudyPlanTests.testLearningTimeScenarioMatchesPythonServer). Alle Werte erfunden."""
import json
from datetime import date
from pathlib import Path

import pytest

from conftest import asgi_call

FIXTURE = Path(__file__).resolve().parents[1] / "packages" / "shared-contracts" / "fixtures" / "local-backend" / "study-plan.json"
TODAY = date(2026, 11, 11)          # Mittwoch


@pytest.fixture()
def fresh(app, tmp_path, monkeypatch):
    from app import db, study
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "zeiten.db")
    db.init_db()
    monkeypatch.setattr(study, "today", lambda: TODAY)
    with db.cursor() as conn:
        for k, v in (("learn_start", "08:00"), ("learn_end", "21:00"), ("hours_per_day", "4"), ("break_minutes", "15"),
                     ("subjects_per_day", "2"), ("free_days", "[6]")):
            conn.execute("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (k, v))
    return app


def call(app, method, path, body=None):
    status, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    return status, json.loads(raw) if raw else None


def _pkg(conn, day: str, minutes: list[int], *, start=None, end=None, times=None, generated=1, manual=0, status="geplant", subject="Fach A") -> int:
    pid = conn.execute("INSERT INTO study_packages(date, subject, title, planned_minutes, status, sort, generated, manual, created_at, start_time, end_time) "
                       "VALUES (?,?,?,?,?,0,?,?,'2026-11-11T16:25:40',?,?)",
                       (day, subject, subject, sum(minutes), status, generated, manual, start, end)).lastrowid
    for i, m in enumerate(minutes):
        ts, te = (times or [(None, None)] * len(minutes))[i]
        conn.execute("INSERT INTO study_tasks(package_id, type, title, sort, est_minutes, status, start_time, end_time, created_at) "
                     "VALUES (?, 'uebung', ?, ?, ?, ?, ?, ?, '2026-11-11')", (pid, f"Aufgabe {i + 1}", i, m, "nachholen" if status == "nachholen" else "geplant", ts, te))
    return pid


def _all(conn):
    from app import db
    return db.rows(conn, "SELECT * FROM study_packages ORDER BY id"), db.rows(conn, "SELECT * FROM study_tasks ORDER BY id")


def _valid(rows):
    for r in rows:
        if r["start_time"] and r["end_time"]:
            assert r["start_time"] < r["end_time"] <= "24:00", r


def test_fixture_scenario_never_after_learning_time():
    """Gemeinsame Fixture: im Szenario "lernzeit" endet nichts nach 24:00, automatische Pakete ab heute liegen in
    08:00-21:00, der volle Donnerstag gibt an den Freitag ab, der Altbestand ist repariert"""
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    sc = next(s for s in fx["scenarios"] if s["name"] == "lernzeit")
    pk, tk = sc["tables_after"]["study_packages"], sc["tables_after"]["study_tasks"]
    _valid(pk)
    _valid(tk)
    for p in pk:
        if p["generated"] == 1 and p["date"] >= sc["now"][:10] and p["start_time"]:
            assert "08:00" <= p["start_time"] and p["end_time"] <= "21:00", p
    old = {p["title"]: p for p in pk if p["title"].startswith("Altbestand")}
    assert old["Altbestand 2026-10-29"]["date"] == "2026-10-30", "voller Donnerstag: ganzes Paket auf Freitag"
    rest = [p for p in pk if p["title"] == "Altbestand 2026-11-12"]
    assert [(p["date"], p["start_time"], p["end_time"]) for p in rest] == [("2026-11-12", "20:00", "20:45"), ("2026-11-13", "08:00", "09:00")]
    assert (old["Altbestand 2026-10-27"]["start_time"], old["Altbestand 2026-10-27"]["end_time"]) == ("23:15", "24:00"), "vergangen: gekappt"
    assert (old["Altbestand 2026-11-06"]["start_time"], old["Altbestand 2026-11-06"]["end_time"]) == ("20:45", "21:45"), "Ende vor Beginn"
    many = [p for p in pk if p["title"].startswith("Doppelt geplant")]
    assert all("08:00" <= p["start_time"] and p["end_time"] <= "21:00" for p in many), "viele Faecher: nichts nach 21:00"
    assert {p["date"] for p in many} == {"2026-11-18", "2026-11-19"} and sum(p["planned_minutes"] for p in many) == 7 * 105
    # die Reparatur laeuft beim ersten Kalenderaufruf ganz (bis 22.11.); der zweite (bis 6.11.) zeigt dieselben Tage gleich
    first, second = [s["response"]["days"] for s in sc["steps"] if s.get("path", "").startswith("/api/calendar?start=2026-10-27")]
    assert first[:len(second)] == second, "zweiter Aufruf aendert nichts"


def test_overloaded_day_spills_to_next_learning_day(fresh):
    """Wie auf dem iPhone: zu viele automatische Pakete an einem Tag (zwei Geraete haben geplant). Kein Paket nach
    21:00; was nicht passt, kommt auf den naechsten Lerntag (Samstag 14.11. -> Montag 16.11., Sonntag ist frei)"""
    from app import db, study
    with db.cursor() as conn:
        for i in range(7):
            _pkg(conn, "2026-11-14", [45, 60], subject=f"Fach {i}")
        study.assign_slots(conn, date(2026, 11, 14), spill=study.SPILL_DAYS)
        pk, tk = _all(conn)
    _valid(pk)
    _valid(tk)
    assert all(p["start_time"] and "08:00" <= p["start_time"] and p["end_time"] <= "21:00" for p in pk), pk
    assert {p["date"] for p in pk} == {"2026-11-14", "2026-11-16"}
    assert sum(t["est_minutes"] for t in tk) == 7 * 105, "nichts verloren"
    assert all(t["start_time"] for t in tk)


def test_without_spill_tasks_lose_their_time_instead_of_running_past_midnight(fresh):
    """"Lernslots neu legen" (ohne Weitergabe): was keinen Platz hat, bleibt am Tag, aber ohne Uhrzeit"""
    from app import db, study
    with db.cursor() as conn:
        ids = [_pkg(conn, "2026-11-12", [120, 120], subject=f"Fach {i}") for i in range(4)]
    st, _ = call(fresh, "POST", "/api/timetable/reslot", {"dates": ["2026-11-12"]})
    assert st == 200
    with db.cursor() as conn:
        pk, tk = _all(conn)
    _valid(pk)
    _valid(tk)
    assert {p["date"] for p in pk} == {"2026-11-12"} and [p["id"] for p in pk][:4] == ids
    assert all(p["end_time"] is None or p["end_time"] <= "21:00" for p in pk)
    assert sum(t["est_minutes"] for t in tk) == 4 * 240, "nichts verloren, nichts gekappt"
    # jedes Paket mit Uhrzeit hat nur Aufgaben mit Uhrzeit; was keinen Platz hat, liegt in Paketen ohne Uhrzeit
    timed = {p["id"] for p in pk if p["start_time"]}
    assert all((t["start_time"] is not None) == (t["package_id"] in timed) for t in tk)
    assert any(not p["start_time"] for p in pk)


def test_old_times_after_midnight_are_repaired_once(fresh):
    """Altbestand wie vom iPhone (Zeiten aus dem Fehlerbericht, Faecher erfunden): unberuehrte automatische Pakete ab
    heute neu eingeplant, vergangene und von Hand gesetzte gekappt, erledigte Aufgaben bleiben erledigt, nichts
    geloescht; ein zweiter Lauf aendert nichts (keine Schleife zwischen zwei Geraeten)"""
    from app import db, study
    with db.cursor() as conn:
        past = _pkg(conn, "2026-11-10", [45, 60], start="23:15", end="25:15", times=[("23:15", "24:00"), ("24:15", "25:15")], status="nachholen")
        auto = _pkg(conn, "2026-11-12", [60, 60], start="23:00", end="25:15", times=[("23:00", "24:00"), ("24:15", "25:15")])
        own = _pkg(conn, "2026-11-13", [60, 60], start="20:45", end="23:00", times=[("20:45", "21:45"), ("22:00", "23:00")], generated=0, manual=1)
        hand = _pkg(conn, "2026-11-13", [45, 60], start="23:00", end="25:15", times=[("23:00", "23:45"), ("24:15", "25:15")], generated=1, manual=1)
        done = _pkg(conn, "2026-11-12", [60], start="23:15", end="24:15", times=[("23:15", "24:15")])
        conn.execute("UPDATE study_tasks SET status='erledigt' WHERE package_id=?", (done,))
        before = len(_all(conn)[0]), len(_all(conn)[1])
    st, _ = call(fresh, "GET", "/api/calendar?start=2026-11-09&end=2026-11-15")
    assert st == 200
    with db.cursor() as conn:
        pk, tk = _all(conn)
        assert (len(pk), len(tk)) == before, "nichts geloescht"
        _valid(pk)
        _valid(tk)
        by = {p["id"]: p for p in pk}
        assert by[auto]["date"] == "2026-11-12" and "08:00" <= by[auto]["start_time"] and by[auto]["end_time"] <= "21:00"
        assert (by[past]["start_time"], by[past]["end_time"]) == ("23:15", "24:00")
        assert (by[own]["start_time"], by[own]["end_time"]) == ("20:45", "23:00"), "gueltige Zeit von Hand bleibt"
        assert (by[hand]["start_time"], by[hand]["end_time"]) == ("23:00", "24:00")
        assert (by[done]["start_time"], by[done]["end_time"]) == ("23:15", "24:00")
        tasks = {(t["package_id"], t["sort"]): t for t in tk}
        assert (tasks[(hand, 1)]["start_time"], tasks[(past, 1)]["start_time"]) == (None, None)
        assert tasks[(done, 0)]["status"] == "erledigt" and tasks[(done, 0)]["end_time"] == "24:00"
        snapshot = _all(conn)
        assert study.repair_times(conn) == 0
        assert _all(conn) == snapshot


def test_manual_time_ends_at_midnight_at_the_latest(fresh):
    """Von Hand: spaet ist erlaubt, aber das Ende bleibt eine Uhrzeit (hoechstens 24:00); Beginn ab 24:00 ist 400"""
    st, p = call(fresh, "POST", "/api/packages", {"date": "2026-11-12", "title": "Spaet", "minutes": 120})
    assert st == 200
    st, r = call(fresh, "PATCH", f"/api/packages/{p['id']}", {"start_time": "23:00"})
    assert st == 200 and (r["start_time"], r["end_time"]) == ("23:00", "24:00")
    st, r = call(fresh, "PATCH", f"/api/packages/{p['id']}", {"start_time": "22:00", "end_time": "25:15"})
    assert st == 200 and (r["start_time"], r["end_time"]) == ("22:00", "24:00")
    assert call(fresh, "PATCH", f"/api/packages/{p['id']}", {"start_time": "24:30"})[0] == 400
