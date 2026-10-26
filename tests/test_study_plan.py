"""Lernplan (app/study.py, /api/packages, /api/tasks): Korrekturen vom 26.10.2026, zuerst in Python und danach in
den Swift-Kern des iPads portiert (docs/IPAD-OHNE-PC.md, S6; Entscheidungen 1 und 2 des Inhabers). Jeder Test hat
eine eigene, frische Datenbank und eine feste Uhr. Alle Werte erfunden."""
import json
from datetime import date, datetime

import pytest

from conftest import asgi_call


@pytest.fixture()
def fresh(app, tmp_path, monkeypatch):
    from app import db, study
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "plan.db")
    db.init_db()
    monkeypatch.setattr(study, "today", lambda: date(2026, 10, 26))     # Montag
    return app


def call(app, method, path, body=None):
    status, _, raw = asgi_call(app, method, path, body=json.dumps(body) if body is not None else None)
    return status, json.loads(raw) if raw else None


def _package(app, day: str, tasks: list[int], title: str = "Testpaket") -> tuple[int, list[int]]:
    st, p = call(app, "POST", "/api/packages", {"date": day, "title": title,
                                                 "tasks": [{"type": "frei", "title": f"Aufgabe {i + 1}", "est_minutes": m} for i, m in enumerate(tasks)]})
    assert st == 200, p
    st, full = call(app, "GET", f"/api/packages/{p['id']}")
    return p["id"], [t["id"] for t in full["tasks"]]


def test_package_time_is_saved_and_tasks_follow(fresh):
    """PATCH /api/packages/{id} speichert die Uhrzeit ("Uhrzeit" im Lernpaket, "Beginn" beim Anlegen); vorher
    wurden start_time und end_time ignoriert (docs/PRUEFBERICHT-IPAD.md, S1)."""
    st, p = call(fresh, "POST", "/api/packages", {"date": "2026-10-27", "title": "Kapitel 2", "minutes": 90})
    assert st == 200 and p["start_time"] is None
    st, p = call(fresh, "PATCH", f"/api/packages/{p['id']}", {"start_time": "14:15", "end_time": "15:45"})
    assert st == 200 and (p["start_time"], p["end_time"]) == ("14:15", "15:45")
    st, day = call(fresh, "GET", "/api/timetable/day?date=2026-10-27")
    assert [(x["start_time"], x["end_time"]) for x in day["packages"]] == [("14:15", "15:45")]
    assert [(w["start_hm"], w["end_hm"]) for w in day["free"]] == [("08:00", "14:15"), ("15:45", "21:00")]

    # Aufgaben mit Uhrzeit ruecken mit: zuerst wie "Lernslots neu legen" ab 08:00 mit 15 Minuten Pause
    pid, tids = _package(fresh, "2026-10-28", [45, 30])
    st, r = call(fresh, "POST", "/api/timetable/reslot", {"dates": ["2026-10-28"]})
    assert st == 200
    st, full = call(fresh, "GET", f"/api/packages/{pid}")
    assert (full["start_time"], full["end_time"]) == ("08:00", "09:30")
    assert [(t["start_time"], t["end_time"]) for t in full["tasks"]] == [("08:00", "08:45"), ("09:00", "09:30")]
    st, p = call(fresh, "PATCH", f"/api/packages/{pid}", {"start_time": "10:00", "end_time": "11:30"})
    st, full = call(fresh, "GET", f"/api/packages/{pid}")
    assert [(t["start_time"], t["end_time"]) for t in full["tasks"]] == [("10:00", "10:45"), ("11:00", "11:30")]
    # ohne Ende: geplante Dauer (75 Minuten); Ende nach Mitternacht als 24:30
    st, p = call(fresh, "PATCH", f"/api/packages/{pid}", {"start_time": "23:15"})
    assert (p["start_time"], p["end_time"]) == ("23:15", "24:30")

    # ungueltig: 400, nichts geaendert (auch nicht der Titel aus derselben Anfrage)
    for body in ({"start_time": "25 Uhr"}, {"start_time": "10:00", "end_time": "09:00"}, {"start_time": "10:60"},
                 {"start_time": 900, "title": "x"}, {"start_time": "١٠:٠٠"}):
        st, r = call(fresh, "PATCH", f"/api/packages/{pid}", body)
        assert st == 400, (body, r)
    st, full = call(fresh, "GET", f"/api/packages/{pid}")
    assert (full["title"], full["start_time"]) == ("Testpaket", "23:15")
    # leerer Beginn: Uhrzeit weg, auch bei den Aufgaben
    st, p = call(fresh, "PATCH", f"/api/packages/{pid}", {"start_time": "", "end_time": ""})
    st, full = call(fresh, "GET", f"/api/packages/{pid}")
    assert full["start_time"] is None and all(t["start_time"] is None for t in full["tasks"])
    # fehlendes Paket: nichts zu aendern
    assert call(fresh, "PATCH", "/api/packages/999", {"start_time": "10:00"}) == (200, None)


def test_package_emptied_by_moving_stays_moved(fresh):
    """Werden alle Aufgaben eines Pakets verschoben, bleibt es "verschoben" (vorher machte refresh_statuses daraus
    wieder "geplant": ein leeres Paket im Kalender, das sein Zeitfenster belegte und unter "Naechste Termine" stand)."""
    pid, tids = _package(fresh, "2026-10-27", [60])
    call(fresh, "PATCH", f"/api/packages/{pid}", {"start_time": "10:00", "end_time": "11:00"})
    st, r = call(fresh, "POST", "/api/calendar/apply", {"moves": [{"task_id": tids[0], "to": "2026-10-29"}]})
    assert (st, r) == (200, {"moved": 1})
    st, old = call(fresh, "GET", f"/api/packages/{pid}")
    assert (old["status"], old["planned_minutes"], old["tasks"]) == ("verschoben", 0, [])
    st, day = call(fresh, "GET", "/api/timetable/day?date=2026-10-27")
    assert [(w["start_hm"], w["end_hm"]) for w in day["free"]] == [("08:00", "21:00")], "Zeitfenster wieder frei"
    st, d = call(fresh, "GET", "/api/dashboard")
    assert [u["date"] for u in d["upcoming"] if u["kind"] == "lernpaket"] == ["2026-10-29"]
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-29")
    assert [[p["status"] for p in x["packages"]] for x in cal["days"]] == [["verschoben"], [], ["geplant"]]
    # eine neue Aufgabe im leeren Paket: wieder geplant
    assert call(fresh, "POST", f"/api/packages/{pid}/tasks", {"title": "Neu", "est_minutes": 30})[0] == 200
    st, old = call(fresh, "GET", f"/api/packages/{pid}")
    assert (old["status"], old["planned_minutes"]) == ("geplant", 30)


def test_replace_keeps_started_packages(fresh):
    """"Bereits geplante, noch nicht begonnene Pakete ersetzen" loescht keine Pakete mit erledigten Aufgaben mehr
    (deren Status ist heute und spaeter ebenfalls "geplant")."""
    started, tids = _package(fresh, "2026-10-27", [45, 45], "begonnen")
    untouched, _ = _package(fresh, "2026-10-27", [45], "nicht begonnen")
    assert call(fresh, "POST", f"/api/tasks/{tids[0]}/status", {"status": "erledigt"})[0] == 200
    st, p = call(fresh, "GET", f"/api/packages/{started}")
    assert p["status"] == "geplant"
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "days": 1, "replace": True})
    assert st == 200 and r["created"] == 0
    st, p = call(fresh, "GET", f"/api/packages/{started}")
    assert st == 200 and [t["status"] for t in p["tasks"]] == ["erledigt", "geplant"]
    assert call(fresh, "GET", f"/api/packages/{untouched}")[0] == 404


def test_missing_package_or_task_is_404(fresh):
    """Verschieben eines fehlenden Pakets und Ueberspringen einer fehlenden Aufgabe: 404 statt 500"""
    st, r = call(fresh, "PATCH", "/api/packages/999", {"date": "2026-10-28"})
    assert (st, r["detail"]) == (404, "Paket nicht gefunden")
    pid, tids = _package(fresh, "2026-10-27", [30])
    st, r = call(fresh, "POST", "/api/tasks/skip", {"task_ids": [tids[0], 999]})
    assert (st, r["detail"]) == (404, "Aufgabe nicht gefunden")
    st, p = call(fresh, "GET", f"/api/packages/{pid}")
    assert p["tasks"][0]["status"] == "geplant", "nichts uebersprungen"
    assert call(fresh, "POST", "/api/tasks/skip", {"task_ids": [tids[0]]}) == (200, {"ok": True})


def test_plan_without_test_tasks_by_default(fresh):
    """Lernplan ohne Testaufgaben (keine KI): tests_per_subject ist standardmaessig 0 (Entscheidung 2)"""
    from app import db
    st, s = call(fresh, "GET", "/api/settings")
    assert s["tests_per_subject"] == 0
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Testfach Plan', '#123456', 0, '2026-10-01T09:00:00')").lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, module_id, created_at) VALUES ('kp', 'Testfach Plan', 'Testfach Plan', 'vorlesung', ?, '2026-10-01')", (mid,))
        for fid, name, folder in (("fp1", "VL01.pdf", "Vorlesung"), ("fp2", "Blatt 1.pdf", "Übungsblätter")):
            conn.execute("INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES (?, 'kp', ?, ?, ?)",
                         (fid, name, int(datetime(2026, 10, 13, 10).timestamp()), folder))
    st, f = call(fresh, "GET", "/api/calendar/feasibility")
    assert (f["per_day_need"], f["hint"]) == (210, None)
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "days": 1})
    assert (st, r["created"]) == (200, 1)
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-27")
    assert [t["type"] for t in cal["days"][0]["packages"][0]["tasks"]] == ["vorlesung", "uebung"]
    # mit Wochentest (am PC mit KI weiter waehlbar): eine Testaufgabe dazu
    call(fresh, "PUT", "/api/settings", {"tests_per_subject": "1"})
    call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "days": 1, "replace": True})
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-27")
    assert [t["type"] for p in cal["days"][0]["packages"] for t in p["tasks"]] == ["vorlesung", "uebung", "test"]


def test_package_stays_in_one_window_next_to_lecture(fresh):
    """Lernslots: Ein Paket liegt am Stueck im ersten freien Fenster mit genug Platz. Vorher begann es vor der
    Vorlesung und endete danach (08:00-13:00 ueber 10:00-11:30): Konflikt im Stundenplan, den "Lernslots neu legen"
    nicht aufloesen konnte; ein kurzes Paket danach nutzte die Luecke vor der Vorlesung nicht mehr."""
    from app import db, study
    with db.cursor() as conn:
        conn.execute("""INSERT INTO course_events(title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
                        VALUES ('Testvorlesung Slots', 'vorlesung', 1, '10:00', '11:30', 'weekly', 1, 'manual', '2026-10-01')""")
    early, _ = _package(fresh, "2026-10-27", [45, 60], "passt nicht vor die Vorlesung")
    late, _ = _package(fresh, "2026-10-27", [30], "danach")
    big, _ = _package(fresh, "2026-10-27", [400, 400], "zu gross fuer jedes Fenster")
    assert call(fresh, "POST", "/api/timetable/reslot", {"dates": ["2026-10-27"]})[0] == 200
    st, day = call(fresh, "GET", "/api/timetable/day?date=2026-10-27")
    slots = {p["id"]: (p["start_time"], p["end_time"]) for p in day["packages"]}
    # frei 08:00-09:30 (30 Minuten Fahrt vor 10:00) und ab 12:00; 45 + 15 Pause + 60 = 120 Minuten passen erst ab 12:00
    assert slots[early] == ("12:00", "14:00")
    assert slots[late] == ("08:00", "08:30"), "kurzes Paket in die Luecke vor der Vorlesung"
    st, full = call(fresh, "GET", f"/api/packages/{early}")
    assert [(t["start_time"], t["end_time"]) for t in full["tasks"]] == [("12:00", "12:45"), ("13:00", "14:00")]
    # passt in kein Fenster: Aufgaben wie bisher der Reihe nach verteilt (die zweite hinter das Tagesende)
    assert slots[big] == ("14:15", "27:50")
    st, full = call(fresh, "GET", f"/api/packages/{big}")
    assert [(t["start_time"], t["end_time"]) for t in full["tasks"]] == [("14:15", "20:55"), ("21:10", "27:50")]
    with db.cursor() as conn:
        assert study.slot_conflicts(conn, date(2026, 10, 27), date(2026, 10, 27)) == []
