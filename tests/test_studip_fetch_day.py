"""Woche aus dem eigenen Stud.IP-Kalender am Abruftag und vor dem ersten Abruf (28.10.2026).

Befund der Mac-Sitzung mit echten Daten: Abruf am 27.10. um 02:39, Montag 26.10. und Dienstag 27.10. zeigten jede
parallele Uebungsgruppe. Nach jedem Abgleich ist heute der Abruftag, also zeigte "Heute" immer alle Gruppen.
Dieselben Faelle wie StudIPCalendarFetchDayTests im Swift-Kern, Regel in docs/IPAD-STUDIP-SYNC.md §10. Alles erfunden.

Kurse: Vorlesung montags 10:00, Uebung dienstags in drei Gruppen (A 10:00 eigene, B 12:00, C 14:00), ein Kurs ganz
ohne Kalendertermin (mittwochs 08:00) und eine Fruehuebung dienstags 01:00 (eigene) neben einer fremden um 00:30.
Erster Abruf am Dienstag 27.10.2026 um 02:39: der Export beginnt mit dem Abruf, die Fruehuebung des Tages fehlt darin.
"""
from datetime import date

import pytest

FETCH1 = "2026-10-27T02:39:00"
FETCH2 = "2026-11-04T09:00:00"
COURSES = [("fd-vl", "Testvorlesung Abruf", "vorlesung"), ("fd-ue", "Übung Testprogrammierung Abruf", "uebung"),
           ("fd-frei", "Testkurs ohne Kalender", "vorlesung"), ("fd-frueh", "Frühübung Abruf", "uebung")]
EVENTS = ([(f"vl-{d}", "fd-vl", f"{d}T10:00:00", f"{d}T11:30:00") for d in ["2026-10-19", "2026-10-26", "2026-11-02", "2026-11-09"]]
          + [(f"ue-{g}-{d}", "fd-ue", f"{d}T{t}:00", f"{d}T{e}:00") for d in ["2026-10-20", "2026-10-27", "2026-11-03", "2026-11-10"]
             for g, t, e in [("A", "10:00", "11:30"), ("B", "12:00", "13:30"), ("C", "14:00", "15:30")]]
          + [(f"frei-{d}", "fd-frei", f"{d}T08:00:00", f"{d}T09:30:00") for d in ["2026-10-21", "2026-10-28", "2026-11-04"]]
          + [("fr-2026-10-27", "fd-frueh", "2026-10-27T01:00:00", "2026-10-27T02:00:00"),
             ("fr-2026-11-03", "fd-frueh", "2026-11-03T01:00:00", "2026-11-03T02:00:00"),
             ("frx-2026-10-27", "fd-frueh", "2026-10-27T00:30:00", "2026-10-27T01:30:00")])       # fremde Gruppe
CALENDAR1 = ["ue-A-2026-10-27", "ue-A-2026-11-03", "ue-A-2026-11-10", "vl-2026-11-02", "vl-2026-11-09", "fr-2026-11-03"]
OWN_TUE = ["Frühübung Abruf 01:00 teilnahme", "Übung Testprogrammierung Abruf 10:00 teilnahme"]


def _clean(conn):
    conn.execute("DELETE FROM event_exceptions WHERE event_id IN (SELECT id FROM course_events WHERE course_id LIKE 'fd-%' OR title='Testlerngruppe Abruf')")
    conn.execute("DELETE FROM course_events WHERE course_id LIKE 'fd-%' OR title='Testlerngruppe Abruf'")
    conn.execute("DELETE FROM studip_events WHERE course_id LIKE 'fd-%'")
    conn.execute("DELETE FROM courses WHERE id LIKE 'fd-%'")
    conn.execute("DELETE FROM studip_calendar_dates")


@pytest.fixture
def cal(app):
    from app import db, timetable
    with db.cursor() as conn:
        _clean(conn)
        for cid, title, kind in COURSES:
            conn.execute("INSERT INTO courses(id, title, semester, kind, active, test_minutes, created_at) VALUES (?,?,'WiSe 2026/27',?,1,90,'2026-10-01T08:00:00')", (cid, title, kind))
        for e in EVENTS:
            conn.execute("INSERT INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,?,'Termin',?,?,'',?)", (*e, FETCH1))
        assert timetable.store_calendar(conn, CALENDAR1, FETCH1)
    yield
    with db.cursor() as conn:
        _clean(conn)


def day(iso: str) -> list[str]:
    from app import db, timetable
    d = date.fromisoformat(iso)
    with db.cursor() as conn:
        occ = timetable.occurrences(conn, d, d)
    return [f"{o['title']} {o['start']} {o['status']}" for o in occ if (o.get("course_id") or "").startswith("fd-") or o["title"] == "Testlerngruppe Abruf"]


def test_fetch_day_shows_only_own_groups(cal):
    """Abruftag: nur die eigene Gruppe; die Fruehuebung, die vor dem Abruf begann, ueber ihren Zeitschlitz; die
    fremde um 00:30 nicht. Vorher standen alle fuenf Termine da."""
    assert day("2026-10-27") == OWN_TUE


def test_fetch_day_before_first_own_date_follows_the_calendar(cal):
    from app import db, timetable
    with db.cursor() as conn:
        conn.execute("INSERT INTO courses(id, title, semester, kind, active, test_minutes, created_at) VALUES ('fd-spaet','Spätgruppe Abruf','WiSe 2026/27','uebung',1,90,'2026-10-01T08:00:00')")
        for d in ["2026-10-20", "2026-10-27", "2026-11-03", "2026-11-10"]:
            conn.execute("INSERT INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,'fd-spaet','Termin',?,?,'',?)",
                         (f"sp-{d}", f"{d}T08:15:00", f"{d}T09:45:00", FETCH1))
        assert timetable.store_calendar(conn, CALENDAR1 + ["sp-2026-11-10"], FETCH1)
    assert day("2026-10-27") == OWN_TUE
    assert not any(x.startswith("Spätgruppe") for x in day("2026-11-03"))
    assert day("2026-11-10") == ["Spätgruppe Abruf 08:15 teilnahme", "Übung Testprogrammierung Abruf 10:00 teilnahme"]
    assert day("2026-10-20") == ["Spätgruppe Abruf 08:15 teilnahme", "Übung Testprogrammierung Abruf 10:00 teilnahme"], "Zeitschlitz"


def test_week_before_first_fetch_shows_own_slots_only(cal):
    from app import db, timetable
    cols = "course_id, title, kind, weekday, start_time, end_time, room, rrule, date_from, date_to, source, attend, created_at"
    with db.cursor() as conn:
        for v in [("fd-ue", "Übung Testprogrammierung Abruf", "uebung", 1, "12:00", "13:30", "", "weekly", "2026-10-13", "2027-01-26", "studip"),
                  ("fd-frei", "Testkurs ohne Kalender", "vorlesung", 2, "08:00", "09:30", "", "weekly", "2026-10-14", "2027-01-27", "studip-manual"),
                  (None, "Testlerngruppe Abruf", "sonstiges", 3, "18:00", "19:30", "", "weekly", "2026-10-15", "2027-01-28", "manual")]:
            conn.execute(f"INSERT INTO course_events({cols}) VALUES (?,?,?,?,?,?,?,?,?,?,?,1,'2026-10-01T08:00:00')", v)
        b12 = conn.execute("SELECT id FROM course_events WHERE course_id='fd-ue' AND start_time='12:00'").fetchone()[0]
        conn.execute("INSERT INTO event_exceptions(event_id, date, type, note, created_at) VALUES (?, '2026-10-20', 'cancelled', 'Ausfall laut Stud.IP', '2026-10-02T08:00:00')", (b12,))
    assert day("2026-10-19") == ["Testvorlesung Abruf 10:00 teilnahme"], "Zeitschlitz der Vorlesung steht im Kalender"
    assert day("2026-10-20") == ["Übung Testprogrammierung Abruf 10:00 teilnahme", "Übung Testprogrammierung Abruf 12:00 ausfall"]
    assert day("2026-10-21") == ["Testkurs ohne Kalender 08:00 teilnahme"], "nur die von Hand bestaetigte Serie"
    with db.cursor() as conn:
        assert timetable.studip_dated(conn, date(2026, 10, 21), date(2026, 10, 21)) == [], "Kurs ganz ohne Kalendertermin"
    assert day("2026-10-22") == ["Testlerngruppe Abruf 18:00 teilnahme"]
    assert day("2026-10-26") == ["Testvorlesung Abruf 10:00 teilnahme"]
    assert day("2026-10-27") == OWN_TUE, "die fremde Serie ohne Ausnahme faellt weg"


def test_second_fetch_keeps_earlier_ids(cal):
    from app import db, timetable
    with db.cursor() as conn:
        assert timetable.store_calendar(conn, ["ue-A-2026-11-10", "vl-2026-11-09"], FETCH2)
        assert [r["id"] for r in db.rows(conn, "SELECT id FROM studip_calendar_dates ORDER BY id")] == sorted(CALENDAR1)
        assert db.row(conn, "SELECT MAX(fetched_at) AS m FROM studip_calendar_dates")["m"] == FETCH2
        assert db.row(conn, "SELECT fetched_at FROM studip_calendar_dates WHERE id='ue-A-2026-10-27'")["fetched_at"] == FETCH1
    assert day("2026-11-03") == OWN_TUE
    assert day("2026-10-27") == OWN_TUE


def test_removed_date_disappears_from_the_new_fetch_on_but_not_before(cal):
    from app import db, timetable
    with db.cursor() as conn:
        assert timetable.store_calendar(conn, ["ue-B-2026-11-10", "vl-2026-11-09"], FETCH2)
        ids = {r["id"] for r in db.rows(conn, "SELECT id FROM studip_calendar_dates")}
    assert "ue-A-2026-11-10" not in ids and "ue-A-2026-11-03" in ids
    assert day("2026-11-10") == ["Übung Testprogrammierung Abruf 12:00 teilnahme"], "neue Gruppe"
    assert day("2026-11-03") == OWN_TUE, "alte Gruppe davor"


def test_unknown_date_keeps_its_id(cal):
    from app import db, timetable
    with db.cursor() as conn:
        conn.execute("INSERT INTO studip_calendar_dates(id, fetched_at) VALUES ('unbekannt', ?)", (FETCH1,))
        assert timetable.store_calendar(conn, ["vl-2026-11-09"], FETCH2)
        assert db.row(conn, "SELECT COUNT(*) AS n FROM studip_calendar_dates WHERE id='unbekannt'")["n"] == 1
