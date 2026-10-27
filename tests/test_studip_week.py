"""Wochenansicht direkt aus dem eigenen Stud.IP-Kalender (timetable.studip_dated / _merge_dated, 27.10.2026).

Befund mit echten Daten (KW 47/2026): alle 21 Termine der Woche standen in studip_events und im eigenen Kalender, die
Ableitung zu Wochenserien zeigte aber nur einen Teil (Mittwoch fehlte ganz) und dazu veraltete Serien. Jetzt zeigt die
Woche die Einzeltermine wie Stud.IP; Serien liefern nur noch Teilnahme, Ausnahmen und Notizen."""
from datetime import date

import pytest


def _clean(conn):
    conn.execute("DELETE FROM event_exceptions WHERE event_id IN (SELECT id FROM course_events WHERE course_id LIKE 'kw-%' OR title LIKE 'KW-%')")
    conn.execute("DELETE FROM course_events WHERE course_id LIKE 'kw-%' OR title LIKE 'KW-%'")
    conn.execute("DELETE FROM studip_events WHERE course_id LIKE 'kw-%'")
    conn.execute("DELETE FROM courses WHERE id LIKE 'kw-%'")
    conn.execute("DELETE FROM studip_calendar_dates")


@pytest.fixture
def week(app):
    """Woche 16.–22.11.2026: Vorlesung Mi 11:30 (im Kalender, ohne Serie), Uebung Mo 16:30 in drei Gruppen (zwei im
    Kalender), eine veraltete Serie Mo 13:45 (Stud.IP kennt den Termin nicht), eine passende Serie Mo 15:30 mit Notiz."""
    from app import db
    with db.cursor() as conn:
        _clean(conn)
        for cid, title, kind in (("kw-vl", "KW-Regelungstechnik II", "vorlesung"), ("kw-ue", "KW-Übung Energiewandlung", "uebung"),
                                 ("kw-ms", "KW-Mechatronische Systeme", "vorlesung")):
            conn.execute("INSERT INTO courses(id, title, kind, active, test_minutes, created_at) VALUES (?,?,?,1,90,?)", (cid, title, kind, db.now_iso()))
        ev = [("e-vl1", "kw-vl", "2026-11-18T11:30:00", "2026-11-18T13:00:00", "Raum 002"),
              ("e-vl2", "kw-vl", "2026-11-18T13:15:00", "2026-11-18T14:15:00", "Raum 002"),
              ("e-ue-a", "kw-ue", "2026-11-16T16:30:00", "2026-11-16T18:15:00", "Raum F303"),
              ("e-ue-b", "kw-ue", "2026-11-16T16:30:00", "2026-11-16T18:15:00", "Raum 031"),
              ("e-ue-c", "kw-ue", "2026-11-16T16:30:00", "2026-11-16T18:15:00", "Raum F102"),
              ("e-ms", "kw-ms", "2026-11-16T15:30:00", "2026-11-16T17:00:00", "Raum 003"),
              ("e-ms-alt", "kw-ms", "2026-11-09T15:30:00", "2026-11-09T17:00:00", "Raum 003")]
        for e in ev:
            conn.execute("INSERT INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,?,?,?,?,?,?)", (*e[:2], "x", *e[2:], db.now_iso()))
        conn.executemany("INSERT INTO studip_calendar_dates(id, fetched_at) VALUES (?, '2026-10-27T19:07:13')",
                         [("e-vl1",), ("e-vl2",), ("e-ue-a",), ("e-ue-b",), ("e-ms",), ("e-ms-alt",)])
        conn.execute("""INSERT INTO course_events(course_id, title, kind, weekday, start_time, end_time, rrule, date_from, date_to, source, attend)
                        VALUES ('kw-ms', 'KW-Mechatronische Systeme', 'vorlesung', 0, '15:30', '17:00', 'weekly', '2026-11-02', '2027-01-25', 'studip', 1)""")
        ms = conn.execute("SELECT id FROM course_events WHERE course_id='kw-ms' AND start_time='15:30'").fetchone()[0]
        conn.execute("INSERT INTO event_notes(event_id, note) VALUES (?, 'Skript mitbringen')", (ms,))
        conn.execute("""INSERT INTO course_events(course_id, title, kind, weekday, start_time, end_time, rrule, date_from, date_to, source, attend)
                        VALUES ('kw-ms', 'KW-Ü MecSys (alt)', 'uebung', 0, '13:45', '15:15', 'weekly', '2024-11-04', '2027-02-01', 'studip', 1)""")
        conn.execute("""INSERT INTO course_events(course_id, title, kind, weekday, start_time, end_time, rrule, date_from, date_to, source, attend)
                        VALUES (NULL, 'KW-Lerngruppe', 'persoenlich', 2, '18:00', '19:30', 'weekly', NULL, NULL, 'manual', 1)""")
    yield ms
    with db.cursor() as conn:
        _clean(conn)


def _week(conn):
    from app import timetable
    return [o for o in timetable.occurrences(conn, date(2026, 11, 16), date(2026, 11, 22)) if (o.get("course_id") or "").startswith("kw-") or o["title"].startswith("KW-")]


def test_week_shows_the_studip_calendar_and_drops_stale_series(app, week):
    from app import db
    with db.cursor() as conn:
        occ = _week(conn)
    slots = sorted((o["date"], o["start"], o["title"]) for o in occ)
    assert ("2026-11-18", "11:30", "KW-Regelungstechnik II") in slots and ("2026-11-18", "13:15", "KW-Regelungstechnik II") in slots
    # Uebung: nur die beiden Gruppen aus dem eigenen Kalender, nicht die dritte
    ue = [o for o in occ if o["course_id"] == "kw-ue"]
    assert len(ue) == 1 and ue[0]["room"] == "Raum F303 · Raum 031" and ue[0]["kind"] == "uebung"     # ein Kasten, beide Raeume
    # passende Serie bleibt mit ihrer ID, Notiz und dem Raum aus Stud.IP; die veraltete Serie 13:45 ist weg
    ms = [o for o in occ if o["course_id"] == "kw-ms"]
    assert len(ms) == 1 and ms[0]["event_id"] == week and ms[0]["note"] == "Skript mitbringen" and ms[0]["room"] == "Raum 003" and ms[0]["studip_id"] == "e-ms"
    assert not any(o["title"].startswith("KW-Ü MecSys") for o in occ)
    # persoenliche Serie ohne Kurs bleibt
    assert any(o["title"] == "KW-Lerngruppe" and o["date"] == "2026-11-18" for o in occ)
    # Einzeltermine ohne Serie zaehlen als belegte Zeit (Planer)
    from app import timetable
    with db.cursor() as conn:
        busy = timetable.busy_blocks(conn, date(2026, 11, 18), db.get_settings(conn), include_packages=False)
    assert any(b["title"] == "KW-Regelungstechnik II" and b["start"] == 11 * 60 + 30 for b in busy)


def test_before_the_calendar_day_all_groups_show_and_manual_series_stay(app, week):
    from app import db, timetable
    with db.cursor() as conn:
        conn.execute("UPDATE studip_calendar_dates SET fetched_at='2026-11-20T08:00:00'")   # Kalender erst am Fr geholt
        conn.execute("UPDATE course_events SET source='studip-manual' WHERE title='KW-Ü MecSys (alt)'")
        occ = _week(conn)
        ue = [o for o in occ if o["course_id"] == "kw-ue"]
        assert len(ue) == 1 and ue[0]["room"].count(" · ") == 2          # vor dem Abruf: alle drei Raeume
        assert any(o["title"].startswith("KW-Ü MecSys") for o in occ)   # von Hand bestaetigte Serie bleibt
        # ohne Serien ueberhaupt: nur die Einzeltermine
        conn.execute("DELETE FROM course_events WHERE course_id LIKE 'kw-%' OR title LIKE 'KW-%'")
        only = [o for o in timetable.occurrences(conn, date(2026, 11, 16), date(2026, 11, 22)) if (o.get("course_id") or "").startswith("kw-")]
        assert {o["title"] for o in only} == {"KW-Regelungstechnik II", "KW-Übung Energiewandlung", "KW-Mechatronische Systeme"}
        assert all(o["event_id"] is None and o["source"] == "studip-kalender" for o in only)
