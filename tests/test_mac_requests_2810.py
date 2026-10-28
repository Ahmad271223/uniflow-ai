"""Bitten der Mac-Sitzung an die PC-Seite (27./28.10.2026): offene Gruppenwahl ohne entschiedene Serien, existing_id
an der Vorschauzeile, Semesterdaten pruefen (569), keine internen Fehlertexte (555)."""
import json

from conftest import asgi_call


def test_pending_choices_skip_series_the_calendar_decided():
    from app import timetable
    entries = [{"title": "Mathe Ü", "selected": False}, {"title": "Physik Ü", "selected": False, "calendar": "fremd"},
               {"title": "Chemie", "selected": False, "calendar": "kurs_fehlt"}, {"title": "Info", "selected": True}]
    assert [e["title"] for e in timetable.pending_choices(entries)] == ["Mathe Ü"]


def test_preview_rows_carry_their_existing_series(app):
    from app import db, timetable
    db.init_db()
    with db.cursor() as conn:
        conn.execute("DELETE FROM course_events WHERE title='Doppelkurs'")
        a = conn.execute("INSERT INTO course_events(title, kind, weekday, start_time, end_time, source) VALUES ('Doppelkurs','vorlesung',2,'08:00','10:00','studip')").lastrowid
        b = conn.execute("INSERT INTO course_events(title, kind, weekday, start_time, end_time, source) VALUES ('Doppelkurs','vorlesung',2,'14:00','16:00','studip')").lastrowid
        rows = [{"title": "Doppelkurs", "kind": "vorlesung", "weekday": 2, "start_time": "08:00", "end_time": "10:00"},
                {"title": "Doppelkurs", "kind": "vorlesung", "weekday": 2, "start_time": "14:00", "end_time": "16:00"}]
        timetable.diff_against_existing(conn, rows)
        assert [r["existing_id"] for r in rows] == [a, b], "jede Zeile kennt ihre eigene Serie"
        conn.execute("DELETE FROM course_events WHERE title='Doppelkurs'")


def test_terms_put_rejects_invalid_or_swapped_dates(app):
    st, _, b = asgi_call(app, "GET", "/api/terms")
    before = json.loads(b)
    for body, msg in (({"start": "2026-10-01"}, "Ende"), ({"start": "kaputt", "end": "2027-03-31"}, "Beginn"),
                      ({"start": "2027-03-31", "end": "2026-10-01"}, "vor seinem Beginn"), ({"start": "2026-10-1", "end": "2027-03-31"}, "Beginn")):
        st, _, b = asgi_call(app, "PUT", "/api/terms", body=json.dumps(body))
        assert st == 422 and msg in json.loads(b)["detail"], body
    assert json.loads(asgi_call(app, "GET", "/api/terms")[2]) == before, "bisheriges Semester bleibt aktiv"


def test_public_errors_hide_internals():
    import sqlite3
    from app import ai, server
    assert server._public_error("Import fehlgeschlagen", ai.AIError("Die KI ist gerade nicht erreichbar.")) == \
        "Import fehlgeschlagen: Die KI ist gerade nicht erreichbar."
    for e in (sqlite3.OperationalError("no such column: course_events.foo"), KeyError("start"),
              ValueError(r"C:\Users\ahmad\AppData\x.db kaputt"), RuntimeError("SELECT * FROM terms")):
        msg = server._public_error("Import fehlgeschlagen", e)
        assert msg == "Import fehlgeschlagen (interner Fehler, Einzelheiten im Protokoll).", (e, msg)
