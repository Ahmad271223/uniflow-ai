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
    # ohne Ende: geplante Dauer (75 Minuten), aber nie vor dem Ende der letzten Aufgabe (mit Pause 90 Minuten);
    # Ende nach Mitternacht als 24:45
    st, p = call(fresh, "PATCH", f"/api/packages/{pid}", {"start_time": "23:15"})
    assert (p["start_time"], p["end_time"]) == ("23:15", "24:45")
    st, full = call(fresh, "GET", f"/api/packages/{pid}")
    assert [(t["start_time"], t["end_time"]) for t in full["tasks"]] == [("23:15", "24:00"), ("24:15", "24:45")]

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


def _time_package(app, day: str, tasks: list[int], start: str, title: str = "Testpaket") -> tuple[int, list[int]]:
    """Paket mit Aufgaben, Uhrzeiten wie "Lernslots neu legen" ab `start` (15 Minuten Pause)"""
    from app import db, timetable
    pid, tids = _package(app, day, tasks, title)
    with db.cursor() as conn:
        cur = timetable.hm(start)
        for tid, m in zip(tids, tasks):
            conn.execute("UPDATE study_tasks SET start_time=?, end_time=? WHERE id=?", (timetable.mh(cur), timetable.mh(cur + m), tid))
            cur += m + 15
        conn.execute("UPDATE study_packages SET start_time=?, end_time=? WHERE id=?", (start, timetable.mh(cur - 15), pid))
    return pid, tids


def _overlaps(day: dict) -> list[tuple]:
    """Pakete mit Uhrzeit, die sich ueberschneiden"""
    from app import timetable
    blocks = [(p["id"], timetable.hm(p["start_time"]), timetable.hm(p["end_time"])) for p in day["packages"] if p["start_time"]]
    return [(a, b) for i, a in enumerate(blocks) for b in blocks[i + 1:] if a[1] < b[2] and b[1] < a[2]]


def test_package_time_dialog_never_cuts_off_tasks(fresh):
    """Der Uhrzeit-Dialog schickt Beginn + geplante Dauer (Summe der Aufgaben ohne Pausen). Vorher wurde ein gelegtes
    Paket mit 45 + 30 Minuten dadurch 08:00-09:15, die Aufgaben liefen bis 09:30, und das naechste Paket lag ab 09:15
    in der zweiten Aufgabe."""
    pid, tids = _time_package(fresh, "2026-10-28", [45, 30], "08:00")
    st, full = call(fresh, "GET", f"/api/packages/{pid}")
    assert (full["start_time"], full["end_time"], full["planned_minutes"]) == ("08:00", "09:30", 75)
    # unveraendert gespeichert, wie der Dialog es schickt
    st, p = call(fresh, "PATCH", f"/api/packages/{pid}", {"start_time": "08:00", "end_time": "09:15"})
    assert (st, p["start_time"], p["end_time"]) == (200, "08:00", "09:30")
    st, full = call(fresh, "GET", f"/api/packages/{pid}")
    assert [(t["start_time"], t["end_time"]) for t in full["tasks"]] == [("08:00", "08:45"), ("09:00", "09:30")]
    # ein Paket danach liegt hinter der letzten Aufgabe
    other, _ = _package(fresh, "2026-10-28", [30], "danach")
    assert call(fresh, "POST", "/api/timetable/reslot", {"dates": ["2026-10-28"], "only_unset": True})[0] == 200
    st, day = call(fresh, "GET", "/api/timetable/day?date=2026-10-28")
    assert {p["id"]: (p["start_time"], p["end_time"]) for p in day["packages"]}[other] == ("09:30", "10:00")
    assert _overlaps(day) == []
    # nur Beginn: die Aufgaben ruecken mit, das Ende folgt der letzten Aufgabe (nicht Beginn + 75 Minuten)
    st, p = call(fresh, "PATCH", f"/api/packages/{pid}", {"start_time": "13:00"})
    assert (p["start_time"], p["end_time"]) == ("13:00", "14:30")
    st, full = call(fresh, "GET", f"/api/packages/{pid}")
    assert [(t["start_time"], t["end_time"]) for t in full["tasks"]] == [("13:00", "13:45"), ("14:00", "14:30")]
    # ein laengeres Ende bleibt
    st, p = call(fresh, "PATCH", f"/api/packages/{pid}", {"start_time": "13:00", "end_time": "15:00"})
    assert (p["start_time"], p["end_time"]) == ("13:00", "15:00")


def test_package_emptied_by_moving_stays_moved(fresh):
    """Werden alle Aufgaben eines Pakets verschoben, bleibt es "verschoben" (vorher machte refresh_statuses daraus
    wieder "geplant": ein leeres Paket im Kalender, das sein Zeitfenster belegte und unter "Naechste Termine" stand)
    und hat keine Uhrzeit mehr (vorher blieb sie: Das Raster zeichnete den leeren Block, und ein neues Paket bekam
    genau diese Uhrzeit, zwei Bloecke uebereinander)."""
    from app import db
    with db.cursor() as conn:
        conn.execute("UPDATE settings SET value=? WHERE key='blocked_times'",
                     (json.dumps([{"weekday": 1, "start": "08:00", "end": "10:00", "title": "Sperrzeit Test"}]),))
    pid, tids = _package(fresh, "2026-10-27", [60])
    call(fresh, "PATCH", f"/api/packages/{pid}", {"start_time": "10:00", "end_time": "11:00"})
    st, r = call(fresh, "POST", "/api/calendar/apply", {"moves": [{"task_id": tids[0], "to": "2026-10-29"}]})
    assert (st, r) == (200, {"moved": 1})
    st, old = call(fresh, "GET", f"/api/packages/{pid}")
    assert (old["status"], old["planned_minutes"], old["tasks"]) == ("verschoben", 0, [])
    assert (old["start_time"], old["end_time"]) == (None, None), "leeres Paket ohne Uhrzeit"
    st, day = call(fresh, "GET", "/api/timetable/day?date=2026-10-27")
    assert [(w["start_hm"], w["end_hm"]) for w in day["free"]] == [("10:00", "21:00")], "Zeitfenster wieder frei"
    st, d = call(fresh, "GET", "/api/dashboard")
    assert [u["date"] for u in d["upcoming"] if u["kind"] == "lernpaket"] == ["2026-10-29"]
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-29")
    assert [[p["status"] for p in x["packages"]] for x in cal["days"]] == [["verschoben"], [], ["geplant"]]
    # ein neues Paket bekommt das freie Fenster, ohne Block uebereinander
    new, _ = _package(fresh, "2026-10-27", [60], "neu")
    assert call(fresh, "POST", "/api/timetable/reslot", {"dates": ["2026-10-27"], "only_unset": True})[0] == 200
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-27")
    assert [(p["id"], p["status"], p["start_time"]) for p in cal["days"][0]["packages"]] == [(pid, "verschoben", None), (new, "geplant", "10:00")]
    st, day = call(fresh, "GET", "/api/timetable/day?date=2026-10-27")
    assert [p["id"] for p in day["packages"] if p["start_time"]] == [new] and _overlaps(day) == []
    # eine neue Aufgabe im leeren Paket: wieder geplant
    assert call(fresh, "POST", f"/api/packages/{pid}/tasks", {"title": "Neu", "est_minutes": 30})[0] == 200
    st, old = call(fresh, "GET", f"/api/packages/{pid}")
    assert (old["status"], old["planned_minutes"]) == ("geplant", 30)


def _module_files(weeks: int = 2) -> None:
    """Ein Modul mit Vorlesung und Uebungsblatt je Lehrwoche (Vorlesungsbeginn 12.10.2026)"""
    from app import db
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Testfach Ersetzen', '#123456', 0, '2026-10-01T09:00:00')").lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, module_id, created_at) VALUES ('ke', 'Testfach Ersetzen', 'Testfach Ersetzen', 'vorlesung', ?, '2026-10-01')", (mid,))
        for w in range(weeks):
            for fid, name, folder in ((f"fe-v{w}", f"VL0{w + 1}.pdf", "Vorlesung"), (f"fe-u{w}", f"Blatt {w + 1}.pdf", "Übungsblätter")):
                conn.execute("INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES (?, 'ke', ?, ?, ?)",
                             (fid, name, int(datetime(2026, 10, 13 + 7 * w, 10).timestamp()), folder))


def _generated(*pids: int) -> None:
    """Pakete wie von "Plan erstellen" (generated=1)"""
    from app import db
    with db.cursor() as conn:
        for pid in pids:
            conn.execute("UPDATE study_packages SET generated=1 WHERE id=?", (pid,))


def test_replace_keeps_started_packages(fresh):
    """"Automatisch erstellte, noch nicht begonnene Pakete ersetzen" loescht keine Pakete mit erledigten Aufgaben mehr
    (deren Status ist heute und spaeter ebenfalls "geplant")."""
    started, tids = _package(fresh, "2026-10-27", [45, 45], "begonnen")
    untouched, _ = _package(fresh, "2026-10-28", [45], "nicht begonnen")
    _generated(started, untouched)
    _module_files(1)
    assert call(fresh, "POST", f"/api/tasks/{tids[0]}/status", {"status": "erledigt"})[0] == 200
    st, p = call(fresh, "GET", f"/api/packages/{started}")
    assert p["status"] == "geplant"
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "days": 2, "replace": True})
    assert st == 200 and r["created"] == 1
    st, p = call(fresh, "GET", f"/api/packages/{started}")
    assert st == 200 and [t["status"] for t in p["tasks"]] == ["erledigt", "geplant"]
    assert call(fresh, "GET", f"/api/packages/{untouched}")[0] == 404
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-28")
    assert [[p["title"] for p in x["packages"]] for x in cal["days"]] == [["begonnen"], ["Woche 1 · 12.10. – 18.10."]]


def test_replace_keeps_own_and_moved_packages(fresh):
    """Ersetzen nimmt nur automatisch erstellte, nicht begonnene Pakete und leere Pakete, tageweise. Vorher wurden
    auch eigene Pakete ("+ Lernpaket", "Eigener Lernblock") und mit "Neu einplanen"/"Woche retten" verschobene
    Aufgaben geloescht, auch wenn es gar nichts zu planen gab; ein leeres Paket sperrte seinen Tag; an einem Tag mit
    begonnenem Paket wurde das nicht begonnene geloescht, aber nicht ersetzt."""
    own, _ = _package(fresh, "2026-10-28", [45], "Mein eigenes Kapitel")
    rescued, _ = _package(fresh, "2026-10-29", [30], "Woche gerettet")
    elsewhere, etids = _package(fresh, "2026-10-26", [30], "Eigene Notizen durcharbeiten")
    started, stids = _package(fresh, "2026-10-30", [30, 30], "begonnen")
    beside, _ = _package(fresh, "2026-10-30", [30], "daneben, nicht begonnen")
    emptied, mtids = _package(fresh, "2026-10-27", [30], "wird leer")
    stale, _ = _package(fresh, "2026-10-31", [30], "automatisch, nicht begonnen")
    _generated(rescued, started, beside, emptied, stale)
    call(fresh, "POST", "/api/calendar/apply", {"moves": [{"task_id": etids[0], "to": "2026-10-29"}, {"task_id": mtids[0], "to": "2026-11-02"}]})
    call(fresh, "POST", f"/api/tasks/{stids[0]}/status", {"status": "erledigt"})
    st, p = call(fresh, "GET", f"/api/packages/{emptied}")
    assert (p["status"], p["tasks"]) == ("verschoben", [])
    kept = (own, rescued, started, beside, emptied, stale)

    # nichts zu planen (keine Unterlagen): nichts geloescht
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "days": 7, "replace": True})
    assert (st, r["created"], r["message"]) == (200, 0, "Keine offenen Vorlesungen oder Übungen für die Planung.")
    assert [call(fresh, "GET", f"/api/packages/{pid}")[0] for pid in kept] == [200] * 6

    _module_files(2)
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "days": 5, "replace": True})
    assert st == 200 and r["created"] == 2
    gone = [pid for pid in kept if call(fresh, "GET", f"/api/packages/{pid}")[0] == 404]
    assert gone == [emptied, stale], "nur das leere und das automatische, nicht begonnene Paket"
    st, p = call(fresh, "GET", f"/api/packages/{rescued}")
    assert [t["moved_from"] for t in p["tasks"]] == [None, "2026-10-26"], "die neu eingeplante Aufgabe bleibt"
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-31")
    assert [len(x["packages"]) for x in cal["days"]] == [2, 1, 1, 2, 0], "neu geplant nur am 27.10., dem Tag des leeren Pakets"
    assert {p["generated"] for p in cal["days"][0]["packages"]} == {1}
    st, opened = call(fresh, "GET", "/api/tasks/open")
    assert len([t for t in opened if t["package_id"] == rescued]) == 2


def test_plan_skips_past_days(fresh, monkeypatch):
    """"Plan erstellen" in der Wochenansicht beginnt am Montag: Tage vor heute werden nicht geplant. Vorher lagen die
    Unterlagen am Mittwoch zuerst auf Montag und Dienstag und waren sofort "nachholen"."""
    from app import study
    monkeypatch.setattr(study, "today", lambda: date(2026, 10, 28))     # Mittwoch
    _module_files(2)
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-26", "days": 7})
    assert (st, r["created"]) == (200, 2)
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-26&end=2026-11-01")
    assert [len(x["packages"]) for x in cal["days"]] == [0, 0, 2, 0, 0, 0, 0]
    st, d = call(fresh, "GET", "/api/dashboard")
    assert d["backlog"] == 0


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


def _lecture(weekday: int, start: str, end: str, title: str) -> None:
    from app import db
    with db.cursor() as conn:
        conn.execute("""INSERT INTO course_events(title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
                        VALUES (?, 'vorlesung', ?, ?, ?, 'weekly', 1, 'manual', '2026-10-01')""", (title, weekday, start, end))


def test_assign_times_keeps_manual_times(fresh):
    """"Uhrzeiten vergeben" (only_unset) legt nur Pakete ohne Uhrzeit; eine von Hand gesetzte Uhrzeit bleibt. Vorher
    vergab es alle Uhrzeiten des Tages neu (15:00-16:00 von Hand wurde 08:00-09:00). "Lernslots neu legen" (ohne
    only_unset) legt wie bisher alles neu."""
    manual, _ = _package(fresh, "2026-10-27", [60], "von Hand")
    unset, _ = _package(fresh, "2026-10-27", [30], "ohne Uhrzeit")
    call(fresh, "PATCH", f"/api/packages/{manual}", {"start_time": "15:00", "end_time": "16:00"})
    st, r = call(fresh, "POST", "/api/timetable/reslot", {"dates": ["2026-10-27"], "only_unset": True})
    assert (st, r) == (200, {"reslotted": ["2026-10-27"]})
    st, day = call(fresh, "GET", "/api/timetable/day?date=2026-10-27")
    assert {p["id"]: (p["start_time"], p["end_time"]) for p in day["packages"]} == {manual: ("15:00", "16:00"), unset: ("08:00", "08:30")}
    st, r = call(fresh, "POST", "/api/timetable/reslot", {"dates": ["2026-10-27"]})
    st, day = call(fresh, "GET", "/api/timetable/day?date=2026-10-27")
    assert {p["id"]: p["start_time"] for p in day["packages"]} == {manual: "08:00", unset: "09:15"}


def test_moved_package_gets_free_slot(fresh):
    """Verschieben auf einen anderen Tag: Ist die Uhrzeit dort frei, bleibt sie, sonst ein freies Fenster des neuen
    Tags. Vorher blieb 10:15-11:15 und lag am Mittwoch ueber der Vorlesung (Konflikt bis "Lernslots neu legen")."""
    from app import db, study
    _lecture(2, "10:00", "11:30", "Testvorlesung Mittwoch")
    pid, tids = _time_package(fresh, "2026-10-27", [60], "10:15")
    st, p = call(fresh, "PATCH", f"/api/packages/{pid}", {"date": "2026-10-29"})
    assert (p["date"], p["start_time"], p["end_time"]) == ("2026-10-29", "10:15", "11:15"), "Donnerstag frei: Uhrzeit bleibt"
    st, p = call(fresh, "PATCH", f"/api/packages/{pid}", {"date": "2026-10-28"})
    # Mittwoch: 30 Minuten Fahrt vor 10:00, frei ab 08:00
    assert (p["date"], p["start_time"], p["end_time"]) == ("2026-10-28", "08:00", "09:00")
    st, full = call(fresh, "GET", f"/api/packages/{pid}")
    assert [(t["start_time"], t["end_time"]) for t in full["tasks"]] == [("08:00", "09:00")]
    with db.cursor() as conn:
        assert study.slot_conflicts(conn, date(2026, 10, 28), date(2026, 10, 28)) == []
    # Tag mit Uhrzeit von Hand in derselben Anfrage: die Uhrzeit gilt
    st, p = call(fresh, "PATCH", f"/api/packages/{pid}", {"date": "2026-10-30", "start_time": "17:00"})
    assert (p["date"], p["start_time"], p["end_time"]) == ("2026-10-30", "17:00", "18:00")
    # ohne Uhrzeit bleibt das Paket ohne Uhrzeit
    loose, _ = _package(fresh, "2026-10-27", [30], "ohne Uhrzeit")
    st, p = call(fresh, "PATCH", f"/api/packages/{loose}", {"date": "2026-10-28"})
    assert (p["date"], p["start_time"]) == ("2026-10-28", None)


def test_free_window_plans_one_unit_into_the_window(fresh):
    """"Lerneinheit automatisch einplanen" im freien Fenster: ein Paket genau in dieses Fenster, auch wenn am Tag schon
    ein Paket liegt. Vorher rief es die Planung fuer den Tag auf und meldete "0 Lernpakete erstellt"."""
    _module_files(2)
    _package(fresh, "2026-10-27", [30], "eigenes Paket")
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "days": 1})
    assert (st, r["created"]) == (200, 0), "die Planung fuer den Tag uebergeht ihn weiter"
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "days": 1, "window_start": "14:00", "window_end": "15:30"})
    assert (st, r["created"], r["message"]) == (200, 1, "1 Lernpaket erstellt") and "feasibility" in r
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-27")
    p = cal["days"][0]["packages"][1]
    # 45 Minuten Vorlesung passen, das Blatt (60) passt mit Pause nicht mehr ins Fenster
    assert (p["title"], p["start_time"], p["end_time"], p["generated"], p["planned_minutes"]) == ("Woche 1 · 12.10. – 18.10.", "14:00", "14:45", 1, 45)
    assert [(t["type"], t["start_time"], t["end_time"]) for t in p["tasks"]] == [("vorlesung", "14:00", "14:45")]
    # grosses Fenster: die naechste Einheit mit Pause, nichts ausserhalb
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "window_start": "16:00", "window_end": "18:00"})
    assert r["created"] == 1
    st, cal = call(fresh, "GET", "/api/calendar?start=2026-10-27&end=2026-10-27")
    p = cal["days"][0]["packages"][2]
    assert [(t["title"], t["start_time"], t["end_time"]) for t in p["tasks"]] == [("Blatt 1.pdf", "16:00", "17:00")]
    # zu klein fuer die naechste Vorlesung (45 Minuten): keine Teile (der Rest bliebe sonst ungeplant); falsche Uhrzeiten
    st, r = call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", "window_start": "19:00", "window_end": "19:40"})
    assert (st, r["created"], r["message"]) == (200, 0, "Keine Lerneinheit passt in 40 Minuten.")
    for body in ({"window_start": "19:00", "window_end": "18:00"}, {"window_start": "kaputt", "window_end": "19:00"}, {"window_end": "19:00"}):
        assert call(fresh, "POST", "/api/calendar/generate", {"start": "2026-10-27", **body})[0] == 400, body
