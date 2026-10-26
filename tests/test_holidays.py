"""Feiertage (Niedersachsen), Unterbrechungen und vorlesungsfreie Zeit je Hochschule; Anzeige in den Kalendern."""
import json
from datetime import date

import pytest


def test_easter_and_moving_holidays():
    from app.holidays import easter, public_holidays
    assert [easter(y).isoformat() for y in (2024, 2025, 2026, 2027, 2028, 2030)] == [
        "2024-03-31", "2025-04-20", "2026-04-05", "2027-03-28", "2028-04-16", "2030-04-21"]
    h = public_holidays(2026)
    assert h["2026-04-03"] == "Karfreitag" and h["2026-05-14"] == "Christi Himmelfahrt" and h["2026-05-25"] == "Pfingstmontag"
    assert h["2026-10-31"] == "Reformationstag" and len(h) == 10
    assert "2016-10-31" not in public_holidays(2016)


def test_day_marks_christmas_hildesheim_vs_luh():
    from app.holidays import day_marks
    hi = day_marks(date(2026, 12, 21), date(2027, 1, 7), "hildesheim")
    luh = day_marks(date(2026, 12, 21), date(2027, 1, 7), "luh")
    assert min(hi) == "2026-12-23" and max(hi) == "2027-01-01"           # Hildesheim: Weihnachtspause bis 01.01.
    assert min(luh) == "2026-12-23" and max(luh) == "2027-01-05"         # LUH: Pause bis 05.01. (06.01. ist in NDS kein Feiertag)
    assert [m["kind"] for m in hi["2026-12-25"]] == ["feiertag", "pause"]
    assert hi["2026-12-24"] == [{"kind": "pause", "label": "Weihnachtspause"}]


def test_lecture_free_between_semesters_and_unknown_future():
    from app.holidays import day_marks, lecture_free
    assert day_marks(date(2027, 2, 6), date(2027, 2, 6), "hildesheim")["2027-02-06"][0]["kind"] == "vorlesungsfrei"
    assert not lecture_free(date(2027, 2, 5), "hildesheim")             # letzter Vorlesungstag
    assert lecture_free(date(2027, 1, 31), "luh") and not lecture_free(date(2027, 1, 29), "luh")
    assert not lecture_free(date(2027, 4, 5), "luh")                     # Vorlesungsbeginn SoSe 2027
    assert day_marks(date(2031, 2, 10), date(2031, 2, 14), "hildesheim") == {}   # nach dem letzten Zeitplan: nichts erfinden
    assert set(day_marks(date(2031, 12, 24), date(2031, 12, 27), "unbekannt")) == {"2031-12-25", "2031-12-26"}


def test_semester_table_is_ordered_and_consistent():
    from app.holidays import SEMESTERS
    for uni, sems in SEMESTERS.items():
        for (_, s, e, breaks), nxt in zip(sems, sems[1:] + [None]):
            assert s < e, (uni, s)
            assert all(s <= a <= b <= e for a, b, _ in breaks), (uni, s, breaks)
            if nxt:
                assert e < nxt[1], (uni, e, nxt[1])


@pytest.fixture
def cal_data(app, monkeypatch):
    from app import config, db
    db.init_db()
    monkeypatch.setattr(config, "UNIVERSITY", "hildesheim")
    with db.cursor() as conn:
        conn.execute("DELETE FROM deadlines")
        conn.execute("INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url) VALUES "
                     "('lw-ev-x1', 'learnweb', NULL, 'Blatt 9', 'Blatt 9 (schließt am 23.12.)', 'abgabe', 'assign', '2026-12-23T23:59', 'https://lw.example/a')")
    yield
    with db.cursor() as conn:
        conn.execute("DELETE FROM deadlines")


def test_calendar_and_timetable_days_carry_marks_and_deadlines(app, cal_data):
    from conftest import asgi_call
    status, _, body = asgi_call(app, "GET", "/api/calendar?start=2026-12-21&end=2026-12-27")
    days = {d["date"]: d for d in json.loads(body)["days"]}
    assert status == 200 and days["2026-12-21"]["marks"] == [] and days["2026-12-21"]["deadlines"] == []
    assert days["2026-12-25"]["marks"][0] == {"kind": "feiertag", "label": "1. Weihnachtstag"}
    (dl,) = days["2026-12-23"]["deadlines"]
    assert (dl["time"], dl["kind_label"], dl["title"], dl["full_title"]) == ("23:59", "Abgabe", "Blatt 9", "Blatt 9 (schließt am 23.12.)")
    status, _, body = asgi_call(app, "GET", "/api/timetable/week?start=2026-12-21")
    wk = {d["date"]: d for d in json.loads(body)["days"]}
    assert status == 200 and wk["2026-12-24"]["marks"][0]["label"] == "Weihnachtspause" and len(wk["2026-12-23"]["deadlines"]) == 1


def test_web_calendar_renders_green_marks_and_deadline_links():
    """Die Web-Oberflaeche nutzt die Felder: gruene Markierung im Lernkalender (Woche, Monat, Tag) und im Stundenplan."""
    from pathlib import Path
    st = Path(__file__).resolve().parents[1] / "app" / "static"
    plan, tt, core = ((st / f).read_text(encoding="utf-8") for f in ("views-plan.js", "views-tt.js", "core.js"))
    assert plan.count("holClass(dd)") >= 3 and "dlChips(days[0])" in plan and "holChips(dd, true)" in plan
    assert "holClass(d)" in tt and "dlChips(d, true)" in tt
    assert "safeUrl(x.url)" in core and ".is-hol" in (st / "style.css").read_text(encoding="utf-8")


def test_default_term_per_university_and_fix_of_old_luh_default(app):
    from app import db, holidays
    assert holidays.default_term("luh", date(2026, 10, 26)) == {"name": "WiSe 2026/27", "start": "2026-10-12", "end": "2027-01-30"}
    assert holidays.default_term("hildesheim", date(2026, 10, 26)) == {"name": "WiSe 2026/27", "start": "2026-10-19", "end": "2027-02-05"}
    assert holidays.default_term("hildesheim", date(2027, 3, 1))["name"] == "SoSe 2027"   # zwischen den Semestern: das naechste
    assert holidays.default_term("hildesheim", date(2031, 1, 1)) is None
    db.init_db()
    with db.cursor() as conn:
        saved = db.rows(conn, "SELECT name, start, end, active FROM terms")
        conn.execute("DELETE FROM terms")
        conn.execute("INSERT INTO terms(name, start, end, active) VALUES ('WiSe 2026/27', '2026-10-12', '2027-01-30', 1)")
        db.ensure_term(conn, "luh")                                              # LUH: Vorgabe stimmt, bleibt
        assert db.row(conn, "SELECT start FROM terms")["start"] == "2026-10-12"
        db.ensure_term(conn, "hildesheim")                                       # alte LUH-Vorgabe in Hildesheim: korrigiert
        exp = holidays.default_term("hildesheim")
        assert [(r["name"], r["start"], r["end"]) for r in db.rows(conn, "SELECT * FROM terms")] == [(exp["name"], exp["start"], exp["end"])]
        conn.execute("UPDATE terms SET name='WiSe 2026/27', start='2026-10-12', end='2027-02-12'")   # vom Nutzer geaendert: bleibt
        db.ensure_term(conn, "hildesheim")
        assert db.row(conn, "SELECT end FROM terms")["end"] == "2027-02-12"
        conn.execute("DELETE FROM terms")
        db.ensure_term(conn, "hildesheim")                                       # leere Tabelle: Vorgabe der Hochschule
        assert db.row(conn, "SELECT start FROM terms")["start"] == exp["start"]
        conn.execute("DELETE FROM terms")
        for r in saved:
            conn.execute("INSERT INTO terms(name, start, end, active) VALUES (?,?,?,?)", (r["name"], r["start"], r["end"], r["active"]))
