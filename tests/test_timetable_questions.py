"""Rückfragen zum eigenen Stud.IP-Kalender und Ausfälle laut Stud.IP am PC (app/timetable_questions.py), dieselben
Fälle wie StudIPCalendarTests im Swift-Kern (testHiddenCourseAnswerIsRemembered, testBusyCourseAnswerSetsAttendance)
auf derselben erfundenen Fixture packages/shared-contracts/fixtures/studip-schedule/kalender."""
import json

import pytest

from conftest import asgi_call
from test_studip_calendar import _calendar, _clean, _seed, _series


@pytest.fixture
def conn(app):
    from app import db
    with db.cursor() as c:
        try:
            yield c
        finally:
            c.execute("DROP TABLE IF EXISTS studip_course_choices")
            _clean(c)


def _ready(conn):
    from app import timetable
    _seed(conn)
    _calendar(conn)
    timetable.auto_import(conn)
    conn.commit()


def _get(app, path):
    status, _, body = asgi_call(app, "GET", path)
    return status, json.loads(body)


def _post(app, path, body):
    status, _, raw = asgi_call(app, "POST", path, body=json.dumps(body))
    return status, json.loads(raw)


def test_without_calendar_no_questions(app, conn):
    from app import timetable
    _seed(conn)
    timetable.auto_import(conn)
    conn.commit()
    assert _get(app, "/api/timetable/studip-questions") == (200, {"hidden": [], "busy": []})


def test_questions_like_ipad(app, conn):
    _ready(conn)
    status, q = _get(app, "/api/timetable/studip-questions")
    assert status == 200
    assert [x["course_id"] for x in q["hidden"]] == ["k-frei"]
    assert q["hidden"][0]["title"] == "Testmathe ohne Kalender" and q["hidden"][0]["times"] == 2
    assert [x["course_id"] for x in q["busy"]] == ["k-frage"]
    times = q["busy"][0]["times"]
    assert [t["attend"] for t in times] == [True, True, True, True], "alle vorausgewählt"
    assert [(t["weekday"], t["start_time"], t["room"]) for t in times] == [(0, "14:00", "Raum F1"), (1, "16:00", "Raum F1"),
                                                                          (2, "16:00", "Raum F1"), (3, "16:00", "Raum F1")]
    assert times[0]["cycle_id"] == "k-frage|0|14:00|" + times[0]["end_time"]
    assert _get(app, "/api/timetable/auto-status")[1]["pending_groups"] == 0


def test_hidden_course_include_is_remembered(app, conn):
    from app import timetable
    _ready(conn)
    status, r = _post(app, "/api/timetable/studip-questions/course", {"course_id": "k-frei", "include": True})
    assert status == 200 and r["ok"] and r["new"] == 2, "beide Vorlesungen wie mit der bisherigen Regel"
    s = _series(conn)
    assert "Testmathe ohne Kalender|1|10:00|Hörsaal K3|1" in s and "Testmathe ohne Kalender|3|10:00|Hörsaal K3|1" in s
    assert _get(app, "/api/timetable/studip-questions")[1]["hidden"] == []
    again = timetable.auto_import(conn)
    assert again["removed"] == 0 and again["new"] == 0, "übernommen bleibt übernommen, nichts doppelt"
    assert len([x for x in _series(conn) if x.startswith("Testmathe ohne Kalender")]) == 2


def test_hidden_course_exclude(app, conn):
    from app import timetable
    _ready(conn)
    assert _post(app, "/api/timetable/studip-questions/course", {"course_id": "k-frei", "include": False})[0] == 200
    timetable.auto_import(conn)
    assert not any(x.startswith("Testmathe ohne Kalender") for x in _series(conn))
    conn.commit()
    q = _get(app, "/api/timetable/studip-questions")[1]
    assert q["hidden"] == [] and [x["course_id"] for x in q["busy"]] == ["k-frage"], "nur noch die Fragestunden"


def test_course_answer_errors(app, conn):
    _ready(conn)
    assert _post(app, "/api/timetable/studip-questions/course", {"course_id": "k-vl", "include": True})[0] == 404
    assert _post(app, "/api/timetable/studip-questions/course", {"course_id": "k-frei"})[0] == 400
    assert _post(app, "/api/timetable/studip-questions/course", {"include": True})[0] == 400
    assert _post(app, "/api/timetable/studip-questions/times", {"course_id": "k-frage"})[0] == 400


def test_busy_course_answer_sets_attendance(app, conn):
    from app import db, timetable
    _ready(conn)
    times = _get(app, "/api/timetable/studip-questions")[1]["busy"][0]["times"]
    keep = [times[0]["cycle_id"], times[2]["cycle_id"]]
    status, r = _post(app, "/api/timetable/studip-questions/times", {"course_id": "k-frage", "attend": keep})
    assert status == 200 and r == {"ok": True, "attend": 2, "skipped": 2}
    s = _series(conn)
    for line in ("Fragestunden Testmathe|0|14:00|Raum F1|1", "Fragestunden Testmathe|1|16:00|Raum F1|0",
                 "Fragestunden Testmathe|2|16:00|Raum F1|1", "Fragestunden Testmathe|3|16:00|Raum F1|0"):
        assert line in s
    assert _get(app, "/api/timetable/studip-questions")[1]["busy"] == []
    again = timetable.auto_import(conn)
    assert again["removed"] == 0 and _series(conn) == s, "Antwort gilt weiter, nichts entfernt"
    # abgewählte Serie gelöscht: der nächste Abgleich legt sie neu an, gleich als "nicht besucht"
    gone = db.row(conn, "SELECT id FROM course_events WHERE title='Fragestunden Testmathe' AND weekday=1")["id"]
    conn.execute("DELETE FROM course_events WHERE id=?", (gone,))
    third = timetable.auto_import(conn)
    assert third["new"] == 1 and "Fragestunden Testmathe|1|16:00|Raum F1|0" in _series(conn)
    conn.commit()
    assert _post(app, "/api/timetable/studip-questions/times", {"course_id": "k-frage", "attend": []})[0] == 404, "schon beantwortet"


def test_studip_cancelled_lists_only_studip_cancellations(app, conn):
    from app import db, timetable
    _ready(conn)
    ev = db.row(conn, "SELECT id FROM course_events WHERE title='Fragestunden Testmathe' AND weekday=0")["id"]
    conn.execute("DELETE FROM event_exceptions WHERE event_id=?", (ev,))
    conn.execute("INSERT INTO event_exceptions(event_id, date, type, note, created_at) VALUES (?, '2026-11-02', 'cancelled', ?, '2026-10-30')",
                 (ev, timetable.STUDIP_CANCEL_NOTE))
    conn.execute("INSERT INTO event_exceptions(event_id, date, type, note, created_at) VALUES (?, '2026-11-09', 'cancelled', '', '2026-10-30')", (ev,))
    conn.commit()
    status, lst = _get(app, "/api/timetable/studip-cancelled?start=2026-11-02&end=2026-11-08")
    assert status == 200 and {"event_id": ev, "date": "2026-11-02"} in lst
    assert all(x["date"] <= "2026-11-08" for x in lst)
    status, lst = _get(app, "/api/timetable/studip-cancelled?start=2026-11-09&end=2026-11-15")
    assert {"event_id": ev, "date": "2026-11-09"} not in lst, "selbst markierter Ausfall bleibt sichtbar"
    assert _get(app, "/api/timetable/studip-cancelled?start=2026-11-09&end=2026-11-01")[0] == 422
    assert _get(app, "/api/timetable/studip-cancelled?start=gestern&end=2026-11-01")[0] == 422
    assert _get(app, "/api/timetable/studip-cancelled?start=2026-01-01&end=2027-12-31")[0] == 422
