"""Luecken in Stud.IP-Serien (Weihnachtspause, Feiertage) werden Ausfaelle statt Vorlesungen (Befund 26.10.2026)."""
from datetime import date, timedelta


def _weekly(start: str, end: str, step: int = 7, skip=()):
    d, out = date.fromisoformat(start), []
    while d <= date.fromisoformat(end):
        if d.isoformat() not in skip:
            out.append(d.isoformat())
        d += timedelta(days=step)
    return out


def _entries(dates, title="Mathematik I", start="10:00", end="12:00"):
    return [{"title": title, "kind": "vorlesung", "weekday": date.fromisoformat(d).weekday(), "start_time": start, "end_time": end,
             "room": "", "rrule": "once", "date_from": d, "date_to": d, "module_id": None, "course_id": "c-gap", "uncertain": False}
            for d in dates]


def test_weekly_series_with_christmas_break_gets_cancellations():
    from app.timetable import merge_weekly
    dates = _weekly("2026-10-12", "2027-01-25", skip={"2026-12-28", "2027-01-04"})
    (s,) = merge_weekly(_entries(dates))
    assert (s["rrule"], s["date_from"], s["date_to"]) == ("weekly", "2026-10-12", "2027-01-25")
    assert s["exdates"] == ["2026-12-28", "2027-01-04"]


def test_biweekly_series_survives_christmas_gap():
    from app.timetable import merge_weekly
    dates = ["2026-10-14", "2026-10-28", "2026-11-11", "2026-11-25", "2026-12-09", "2027-01-06", "2027-01-20"]   # 28 Tage Pause
    (s,) = merge_weekly(_entries(dates))
    assert s["rrule"] == "biweekly"                     # vorher: "weekly", weil eine Luecke 28 statt 14 Tage war
    assert s["exdates"] == ["2026-12-23"]


def test_series_without_gaps_has_no_cancellations():
    from app.timetable import merge_weekly
    (s,) = merge_weekly(_entries(_weekly("2026-10-12", "2026-12-21")))
    assert "exdates" not in s and s["rrule"] == "weekly"       # Antwortform ohne Luecken unveraendert


def test_auto_import_adds_missing_cancellations_only_to_studip_series(app):
    from app import db, timetable
    dates = _weekly("2026-10-12", "2027-01-25", skip={"2026-12-28", "2027-01-04"})
    with db.cursor() as conn:
        conn.execute("INSERT OR REPLACE INTO courses(id, title, kind, active, created_at) VALUES ('c-gap', 'Mathematik I', 'vorlesung', 1, '2026-10-26')")
        for i, d in enumerate(dates):
            conn.execute("INSERT OR REPLACE INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,?,?,?,?,?,?)",
                         (f"ev-gap-{i}", "c-gap", "Vorlesung", f"{d}T10:00:00", f"{d}T12:00:00", "", "2026-10-26"))
            # zweite Serie desselben Kurses am selben Wochentag (Live-Befund: 09:00 und 15:00)
            conn.execute("INSERT OR REPLACE INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,?,?,?,?,?,?)",
                         (f"ev-gap2-{i}", "c-gap", "Vorlesung", f"{d}T15:00:00", f"{d}T16:30:00", "", "2026-10-26"))
        timetable.auto_import(conn)
        eid2 = db.row(conn, "SELECT id FROM course_events WHERE course_id='c-gap' AND start_time='15:00'")["id"]
        exc2 = lambda: sorted(r["date"] for r in db.rows(conn, "SELECT date FROM event_exceptions WHERE event_id=?", (eid2,)))
        assert exc2() == ["2026-12-28", "2027-01-04"]
        conn.execute("DELETE FROM event_exceptions WHERE event_id=?", (eid2,))
        timetable.auto_import(conn)
        assert exc2() == ["2026-12-28", "2027-01-04"]                 # beide Serien bekommen ihre Ausfaelle nachgetragen
        eid = db.row(conn, "SELECT id FROM course_events WHERE course_id='c-gap' AND start_time='10:00'")["id"]
        exc = lambda: sorted(r["date"] for r in db.rows(conn, "SELECT date FROM event_exceptions WHERE event_id=? AND type='cancelled'", (eid,)))
        assert exc() == ["2026-12-28", "2027-01-04"]
        occ = {o["date"]: o["status"] for o in timetable.occurrences(conn, date(2026, 12, 21), date(2027, 1, 11))}
        assert occ["2026-12-28"] == "ausfall" and occ["2027-01-04"] == "ausfall" and occ["2027-01-11"] == "teilnahme"

        # Serie aus einem frueheren Import ohne Ausfaelle: der naechste Abgleich traegt sie nach
        conn.execute("DELETE FROM event_exceptions WHERE event_id=?", (eid,))
        timetable.auto_import(conn)
        assert exc() == ["2026-12-28", "2027-01-04"]

        # Vom Nutzer angelegte Serie gleichen Namens: nie Ausfaelle aus Stud.IP
        conn.execute("DELETE FROM event_exceptions WHERE event_id=?", (eid,))
        conn.execute("DELETE FROM event_exceptions WHERE event_id=?", (eid2,))
        conn.execute("UPDATE course_events SET source='manual' WHERE id IN (?,?)", (eid, eid2))
        timetable.auto_import(conn)
        assert exc() == [] and exc2() == []

        conn.execute("DELETE FROM course_events WHERE course_id='c-gap'")
        conn.execute("DELETE FROM studip_events WHERE course_id='c-gap'")
        conn.execute("DELETE FROM courses WHERE id='c-gap'")
