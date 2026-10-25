"""Stundenplan: ICS mit UTC/TZID und Ausfaellen (EXDATE), Ausfaelle beim Import (Korrektur vom 25.10.2026).

Vorher wurden "...Z"-Zeiten und TZID ignoriert (Termine um eine oder zwei Stunden verschoben) und EXDATE fiel weg.
Alle Werte erfunden.
"""
import json

from conftest import asgi_call


def _ics(*events: str) -> str:
    return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + "".join(f"BEGIN:VEVENT\r\n{e.strip()}\r\nEND:VEVENT\r\n" for e in events) + "END:VCALENDAR\r\n"


def _one(text: str) -> dict:
    from app import timetable
    out = timetable.parse_ics(text)
    assert len(out) == 1, out
    return out[0]


def test_berlin_from_utc_follows_eu_rule():
    from datetime import datetime

    from app import timetable
    f = timetable._berlin_from_utc
    assert f(datetime(2026, 10, 21, 6, 15)) == datetime(2026, 10, 21, 8, 15)          # Sommerzeit
    assert f(datetime(2026, 11, 4, 7, 15)) == datetime(2026, 11, 4, 8, 15)            # Winterzeit
    # Sonntag, 25.10.2026: bis 00:59:59 UTC Sommerzeit, ab 01:00 UTC Winterzeit (02:30 gibt es zweimal)
    assert f(datetime(2026, 10, 25, 0, 30)) == datetime(2026, 10, 25, 2, 30)
    assert f(datetime(2026, 10, 25, 1, 0)) == datetime(2026, 10, 25, 2, 0)
    assert f(datetime(2026, 10, 25, 1, 30)) == datetime(2026, 10, 25, 2, 30)
    # Maerz 2027: letzter Sonntag ist der 28.
    assert f(datetime(2027, 3, 28, 0, 59)) == datetime(2027, 3, 28, 1, 59)
    assert f(datetime(2027, 3, 28, 1, 0)) == datetime(2027, 3, 28, 3, 0)


def test_ics_utc_times_become_berlin_time():
    e = _one(_ics("SUMMARY:Testkurs Physik\nDTSTART:20261021T061500Z\nDTEND:20261021T074500Z\nRRULE:FREQ=WEEKLY"))
    assert (e["weekday"], e["start_time"], e["end_time"], e["date_from"], e["rrule"]) == (2, "08:15", "09:45", "2026-10-21", "weekly")
    w = _one(_ics("SUMMARY:Testkurs Winter\nDTSTART:20261104T071500Z\nDTEND:20261104T084500Z"))
    assert (w["start_time"], w["end_time"], w["rrule"]) == ("08:15", "09:45", "once")
    # spaet am Abend in UTC ist schon der naechste Tag in Berlin
    n = _one(_ics("SUMMARY:Nachtkurs\nDTSTART:20261105T233000Z\nDTEND:20261106T003000Z"))
    assert (n["weekday"], n["date_from"], n["start_time"], n["end_time"]) == (4, "2026-11-06", "00:30", "01:30")


def test_ics_tzid_variants():
    berlin = _one(_ics("SUMMARY:Testkurs A\nDTSTART;TZID=Europe/Berlin:20261021T081500\nDTEND;TZID=Europe/Berlin:20261021T094500"))
    assert (berlin["start_time"], berlin["end_time"]) == ("08:15", "09:45")
    quoted = _one(_ics('SUMMARY:Testkurs B\nDTSTART;TZID="Europe/Berlin":20261021T081500\nDTEND;TZID="Europe/Berlin":20261021T094500'))
    assert quoted["start_time"] == "08:15"
    utc = _one(_ics("SUMMARY:Testkurs C\nDTSTART;TZID=UTC:20261021T061500\nDTEND;TZID=Etc/UTC:20261021T074500"))
    assert (utc["start_time"], utc["end_time"]) == ("08:15", "09:45")
    # Windows-Name ohne Datenbank: gilt als Berliner Zeit
    win = _one(_ics("SUMMARY:Testkurs D\nDTSTART;TZID=W. Europe Standard Time:20261021T081500\nDTEND;TZID=W. Europe Standard Time:20261021T094500"))
    assert win["start_time"] == "08:15"
    # New York (EDT -4): 10:15 -> 16:15 Berlin; in der Woche nach dem 25.10. (USA noch Sommerzeit) -> 15:15
    ny = _one(_ics("SUMMARY:Testkurs E\nDTSTART;TZID=America/New_York:20261021T101500\nDTEND;TZID=America/New_York:20261021T114500"))
    assert (ny["start_time"], ny["end_time"]) == ("16:15", "17:45")
    ny2 = _one(_ics("SUMMARY:Testkurs F\nDTSTART;TZID=America/New_York:20261028T101500\nDTEND;TZID=America/New_York:20261028T114500"))
    assert ny2["start_time"] == "15:15"


def test_zone_database_available():
    """TZID wie America/New_York braucht eine Zeitzonendatenbank. Windows hat keine; ohne das Paket tzdata wuerde
    eine solche Kalenderdatei stillschweigend als Berliner Zeit gelesen (6 Stunden daneben), darum steht es fest in
    requirements.txt (Korrektur vom 25.10.2026)."""
    import re
    from pathlib import Path
    from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

    req = (Path(__file__).resolve().parent.parent / "requirements.txt").read_text(encoding="utf-8")
    assert re.search(r"^tzdata==\d{4}\.\d+\s*$", req, re.M), "tzdata fehlt in requirements.txt"
    try:
        ZoneInfo("America/New_York")
    except ZoneInfoNotFoundError:
        raise AssertionError("keine Zeitzonendatenbank: pip install -r requirements.txt (tzdata)") from None


def test_ics_rrule_until_and_interval():
    e = _one(_ics("SUMMARY:Testkurs Analysis – Übung\nDTSTART;TZID=Europe/Berlin:20261020T101500\nDTEND;TZID=Europe/Berlin:20261020T114500\n"
                  "RRULE:FREQ=WEEKLY;INTERVAL=2;UNTIL=20270126T225959Z"))
    assert (e["rrule"], e["kind"], e["date_to"]) == ("biweekly", "uebung", "2027-01-26")
    # 23:59:59Z ist 00:59 am Folgetag und liegt vor dem Beginn: der Vortag zaehlt
    late = _one(_ics("SUMMARY:Testkurs G\nDTSTART:20261020T091500Z\nDTEND:20261020T104500Z\nRRULE:FREQ=WEEKLY;UNTIL=20270126T235959Z"))
    assert late["date_to"] == "2027-01-26"
    # UNTIL vor dem Beginn am selben Tag: dieser Tag faellt weg
    before = _one(_ics("SUMMARY:Testkurs H\nDTSTART;TZID=Europe/Berlin:20261020T101500\nDTEND;TZID=Europe/Berlin:20261020T114500\n"
                       "RRULE:FREQ=WEEKLY;UNTIL=20270126T080000Z"))
    assert before["date_to"] == "2027-01-25"
    plain = _one(_ics("SUMMARY:Testkurs I\nDTSTART:20261020T101500\nDTEND:20261020T114500\nRRULE:FREQ=WEEKLY;UNTIL=20270126"))
    assert (plain["date_to"], plain["start_time"]) == ("2027-01-26", "10:15")


def test_ics_exdates_with_zones_and_dates():
    e = _one(_ics("SUMMARY:Testkurs Mechanik\nDTSTART;TZID=Europe/Berlin:20261021T081500\nDTEND;TZID=Europe/Berlin:20261021T094500\nRRULE:FREQ=WEEKLY\n"
                  "EXDATE;TZID=Europe/Berlin:20261104T081500,20261111T081500\nEXDATE:20261223T071500Z\nEXDATE;VALUE=DATE:20261230\n"
                  "EXDATE:20261105T233000Z\nEXDATE:kaputt"))
    assert e["exdates"] == ["2026-11-04", "2026-11-06", "2026-11-11", "2026-12-23", "2026-12-30"]
    assert _one(_ics("SUMMARY:Ohne\nDTSTART:20261021T081500\nDTEND:20261021T094500"))["exdates"] == []


def test_ics_folded_lines_and_broken_events():
    from app import timetable
    text = _ics("SUMMARY:Testkurs mit langem\n  Titel\\, Teil 2\nDTSTART:20261021T081500Z\nDTEND:20261021T094500Z\nLOCATION:Raum 1\\, Haus 2",
                "SUMMARY:Ohne Beginn\nDTEND:20261021T094500Z",
                "SUMMARY:Ohne Ende\nDTSTART:20261022T120000")
    out = timetable.parse_ics(text)
    assert [(o["title"], o["start_time"], o["end_time"], o["room"]) for o in out] == [
        ("Testkurs mit langem Titel, Teil 2", "10:15", "11:45", "Raum 1, Haus 2"), ("Ohne Ende", "12:00", "13:30", "")]


def test_apply_import_adds_cancellations(app):
    from datetime import date

    from app import db, timetable
    with db.cursor() as conn:
        res = timetable.apply_import(conn, [{"title": "Testkurs Ausfall", "weekday": 2, "start_time": "08:15", "end_time": "09:45", "rrule": "weekly",
                                            "date_from": "2026-10-21", "date_to": "2026-12-16", "exdates": ["2026-11-04", "2026-11-04", "x", 5]}], "ics")
        eid = db.row(conn, "SELECT id FROM course_events WHERE title='Testkurs Ausfall'")["id"]
        assert res == {"new": 1, "updated": 0, "removed": 0, "ids": [eid]}
        rows = db.rows(conn, "SELECT date, type, note FROM event_exceptions WHERE event_id=?", (eid,))
        assert rows == [{"date": "2026-11-04", "type": "cancelled", "note": "Ausfall laut Kalender"}]
        occ = {o["date"]: o["status"] for o in timetable.occurrences(conn, date(2026, 10, 28), date(2026, 11, 11)) if o["event_id"] == eid}
        assert occ == {"2026-10-28": "teilnahme", "2026-11-04": "ausfall", "2026-11-11": "teilnahme"}
        # erneuter Import (vorhandene Serie): neue Ausfaelle dazu, vom Nutzer verschobener Tag bleibt
        timetable.set_exception(conn, eid, "2026-11-11", "moved", "2026-11-12", "10:00", "11:30")
        res = timetable.apply_import(conn, [{"existing_id": eid, "title": "Testkurs Ausfall", "weekday": 2, "start_time": "08:15", "end_time": "09:45",
                                            "exdates": ["2026-11-11", "2026-11-18"]}], "studip")
        assert res["updated"] == 1
        rows = db.rows(conn, "SELECT date, type, note FROM event_exceptions WHERE event_id=? ORDER BY date", (eid,))
        assert rows == [{"date": "2026-11-04", "type": "cancelled", "note": "Ausfall laut Kalender"},
                        {"date": "2026-11-11", "type": "moved", "note": ""},
                        {"date": "2026-11-18", "type": "cancelled", "note": "Ausfall laut Stud.IP"}]
        # unbekannte Serie: kein Fehler (vorher wie jetzt ohne Wirkung)
        assert timetable.apply_import(conn, [{"existing_id": 99999, "start_time": "08:00", "end_time": "09:00", "exdates": ["2026-11-04"]}], "ics")["updated"] == 1
        assert not db.row(conn, "SELECT 1 FROM event_exceptions WHERE event_id=99999")
        conn.execute("DELETE FROM course_events WHERE id=?", (eid,))


def test_reimport_drops_stale_cancellations(app):
    """Erneuter Import einer vorhandenen Serie: Ausfaelle derselben Quelle, die nicht mehr gemeldet werden, entfallen
    (z. B. andere Uebungsgruppe gewaehlt); Ausnahmen des Nutzers und anderer Quellen bleiben (Korrektur vom 25.10.2026)."""
    from app import db, timetable

    def exceptions(conn, eid):
        return [(r["date"], r["type"], r["note"]) for r in db.rows(conn, "SELECT date, type, note FROM event_exceptions WHERE event_id=? ORDER BY date", (eid,))]

    with db.cursor() as conn:
        base = {"title": "Testkurs Wechsel", "weekday": 4, "start_time": "10:00", "end_time": "11:30", "rrule": "weekly"}
        timetable.apply_import(conn, [{**base, "exdates": ["2026-12-25", "2027-01-01"]}], "studip")
        eid = db.row(conn, "SELECT id FROM course_events WHERE title='Testkurs Wechsel'")["id"]
        timetable.apply_import(conn, [{**base, "existing_id": eid, "exdates": ["2026-11-20"]}], "ics")
        timetable.set_exception(conn, eid, "2026-11-27", "cancelled", note="Dozent krank")
        timetable.set_exception(conn, eid, "2026-12-04", "moved", "2026-12-05", "10:00", "11:30")
        # andere Gruppe derselben Uebung (Freitag 08:00, ohne Ausfaelle) ersetzt die bisherige
        res = timetable.apply_import(conn, [{**base, "existing_id": eid, "start_time": "08:00", "end_time": "09:30", "exdates": []}], "studip")
        assert res == {"new": 0, "updated": 1, "removed": 0}
        assert exceptions(conn, eid) == [("2026-11-20", "cancelled", "Ausfall laut Kalender"), ("2026-11-27", "cancelled", "Dozent krank"),
                                         ("2026-12-04", "moved", "")]
        # Kalenderdatei ohne den alten EXDATE, dafuer ein neuer
        timetable.apply_import(conn, [{**base, "existing_id": eid, "exdates": ["2026-12-11", 7]}], "ics")
        assert exceptions(conn, eid) == [("2026-11-27", "cancelled", "Dozent krank"), ("2026-12-04", "moved", ""),
                                         ("2026-12-11", "cancelled", "Ausfall laut Kalender")]
        # ohne Liste der Ausfaelle (KI, Stud.IP-Einzeltermine am PC): nichts entfernt
        timetable.apply_import(conn, [{**base, "existing_id": eid}], "ics")
        timetable.apply_import(conn, [{**base, "existing_id": eid, "exdates": None}], "ics")
        assert len(exceptions(conn, eid)) == 3
        conn.execute("DELETE FROM course_events WHERE id=?", (eid,))


def test_import_preview_ics_upload(app):
    ics = _ics("SUMMARY:Testkurs Upload – Vorlesung\nDTSTART:20261021T061500Z\nDTEND:20261021T074500Z\nRRULE:FREQ=WEEKLY;UNTIL=20270127T235959Z\n"
               "EXDATE:20261223T071500Z")
    b = "uniflow-test"
    body = (f'--{b}\r\nContent-Disposition: form-data; name="source"\r\n\r\nics\r\n'
            f'--{b}\r\nContent-Disposition: form-data; name="upload"; filename="plan.ics"\r\nContent-Type: text/calendar\r\n\r\n{ics}\r\n--{b}--\r\n')
    st, _, raw = asgi_call(app, "POST", "/api/timetable/import/preview", body=body.encode(), content_type=f"multipart/form-data; boundary={b}")
    assert st == 200, raw
    r = json.loads(raw)
    e = r["entries"][0]
    assert (e["start_time"], e["end_time"], e["date_to"], e["exdates"]) == ("08:15", "09:45", "2027-01-27", ["2026-12-23"])
    assert r["diff"]["new"][0]["exdates"] == ["2026-12-23"]
