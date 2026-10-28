"""Erzeugt packages/shared-contracts/fixtures/studip-schedule/woche.json: Woche 1:1 aus dem eigenen Stud.IP-Kalender und
nur das aktuelle Semester (PC-Stand 28.10.2026), mit der Python-Referenz auf erfundenen Daten und eingefrorener Uhr
(Mittwoch, 28.10.2026 = WiSe 2026/27). Der Swift-Kern soll dieselben Schritte gehen und exakt vergleichen.

Inhalt:
- semester_keys / semester_cases: app/semesters.key und is_current (Titel, end-semester, Ende als Datum, unbegrenzt)
- fetch_courses: Antwort von users/{id}/courses?include=start-semester,end-semester -> gelesene Kurse
  (semester, semester_end, semester_ends_at; fehlende end-semester-Daten = "unbegrenzt")
- courses_in -> courses_after: studip_sync.upsert_course nacheinander, danach study.ensure_modules; aktiv ist nur, was
  laut Regel aktuell ist; modules_after: Module nur fuer aktive Kurse, Module ohne aktiven Kurs aus
- user_choice: der Nutzer schaltet einen alten Kurs ein (active_custom) -> ein erneuter Abgleich laesst ihn
- merge_weekly_multi_year: derselbe Kurstitel in zwei Jahrgaengen (zwei Kurs-IDs) -> zwei Serien, nicht eine
  (Ursache "Mittwoch fehlt" am 28.10.2026)
- seed + week: Stud.IP-Einzeltermine, eigener Kalender (Abruf 27.10.2026), Serien (passend mit Notiz, veraltet,
  von Hand bestaetigt, persoenlich, mit gespeichertem Ausfall), dann timetable.studip_dated und timetable.occurrences
  fuer 16.-22.11.2026. Erwartet: Woche wie Stud.IP, derselbe Termin in drei Raeumen = ein Eintrag mit allen Raeumen,
  andere Gruppe fehlt, veraltete Serie fehlt, Ausfall bleibt sichtbar.

Aufruf im Projektordner: python tools/gen-studip-week-fixture.py [--check]
"""
from __future__ import annotations

import json
import sys
from datetime import date

from schema_source import ROOT, SchemaSource, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "studip-schedule" / "woche.json"
TODAY = date(2026, 10, 28)
NOW = "2026-10-28T08:00:00"
WEEK = ("2026-11-16", "2026-11-22")
CAL_FETCHED = "2026-10-27T19:07:13"

SEMESTER_KEYS = ["WiSe 2026/27", "SoSe 2026", "WS 26/27", "SS 2024", "Wintersemester 2025/2026", "Sommersemester 2027", "Projektkurs", ""]
SEMESTER_CASES = [
    {"semester": "WiSe 2026/27", "semester_end": None, "ends_at": None},
    {"semester": "SoSe 2026", "semester_end": None, "ends_at": None},
    {"semester": "SoSe 2027", "semester_end": None, "ends_at": None},
    {"semester": "Projektkurs", "semester_end": None, "ends_at": None},
    {"semester": "SoSe 2024", "semester_end": "WiSe 2026/27", "ends_at": "2027-03-31T23:59:59+02:00"},
    {"semester": "WiSe 2026/27", "semester_end": "WiSe 2025/26", "ends_at": "2026-03-31T23:59:59+02:00"},
    {"semester": "WiSe 2022/23", "semester_end": "unbegrenzt", "ends_at": None},
    {"semester": "WiSe 2022/23", "semester_end": "SoSe 2025", "ends_at": None},
    {"semester": "WiSe 2026/27", "semester_end": None, "ends_at": "2026-10-28T00:00:00+01:00"},
]
CURRENT_DAYS = ["2026-10-28", "2027-03-31", "2027-04-01", "2026-09-30", "2026-01-15"]

API_RESPONSE = {"data": [
    {"id": "w-alt", "type": "courses", "attributes": {"title": "Testmesstechnik  I", "course-number": "32975"},
     "relationships": {"start-semester": {"data": {"type": "semesters", "id": "s24"}}, "end-semester": {"data": {"type": "semesters", "id": "s24"}}}},
    {"id": "w-offen", "type": "courses", "attributes": {"title": "Testdauerkurs"},
     "relationships": {"start-semester": {"data": {"type": "semesters", "id": "s24"}}, "end-semester": {"data": None}}},
    {"id": "w-ohne", "type": "courses", "attributes": {"title": "Testkurs alte Fassung"},
     "relationships": {"start-semester": {"data": {"type": "semesters", "id": "s26"}}}},
    {"id": "w-neu", "type": "courses", "attributes": {"title": "Testmesstechnik I", "course-number": "32975"},
     "relationships": {"start-semester": {"data": {"type": "semesters", "id": "s26"}}, "end-semester": {"data": {"type": "semesters", "id": "s26"}}}},
], "included": [
    {"type": "semesters", "id": "s24", "attributes": {"title": "WiSe 2024/25", "start": "2024-10-01T00:00:00+02:00", "end": "2025-03-31T23:59:59+02:00",
                                                       "start-of-lectures": "2024-10-14T00:00:00+02:00", "end-of-lectures": "2025-02-01T23:59:00+01:00", "visible": True, "is-current": False}},
    {"type": "semesters", "id": "s26", "attributes": {"title": "WiSe 2026/27", "start": "2026-10-01T00:00:00+02:00", "end": "2027-03-31T23:59:59+02:00",
                                                       "start-of-lectures": "2026-10-12T00:00:00+02:00", "end-of-lectures": "2027-01-30T23:59:59+01:00", "visible": True, "is-current": True}},
], "links": {}}


def C(cid, title, sem, end=None, ends=None):
    return {"id": cid, "title": title, "number": None, "semester": sem, "semester_end": end, "semester_ends_at": ends}


COURSES_IN = [
    C("w-mt-24", "Testmesstechnik I", "WiSe 2024/25", "WiSe 2024/25", "2025-03-31T23:59:59+02:00"),
    C("w-mt-26", "Testmesstechnik I", "WiSe 2026/27", "WiSe 2026/27", "2027-03-31T23:59:59+02:00"),
    C("w-rt-26", "Testregelungstechnik II", "WiSe 2026/27", "WiSe 2026/27", "2027-03-31T23:59:59+02:00"),
    C("w-ue-26", "Übung: Testenergiewandlung", "WiSe 2026/27", "WiSe 2026/27", "2027-03-31T23:59:59+02:00"),
    C("w-ms-26", "Testmechatronik", "WiSe 2026/27", "WiSe 2026/27", "2027-03-31T23:59:59+02:00"),
    C("w-alt-23", "Testwerkstoffkunde", "SoSe 2023", "SoSe 2023", "2023-09-30T23:59:59+02:00"),
    C("w-lw", "Testlernweb-Kurs", "SoSe 2026"),                      # ohne end-semester (Learnweb): nach dem Titel
    C("w-dauer", "Testdauerkurs", "WiSe 2022/23", "unbegrenzt"),
]

# Stud.IP-Einzeltermine (id, Kurs, Beginn, Ende, Raum) und welche im eigenen Kalender stehen
EVENTS = [
    ("e-rt-1", "w-rt-26", "2026-11-18T11:30:00", "2026-11-18T13:00:00", "Raum 002"),
    ("e-rt-2", "w-rt-26", "2026-11-18T13:15:00", "2026-11-18T14:15:00", "Raum 002"),
    ("e-mt-1", "w-mt-26", "2026-11-18T10:00:00", "2026-11-18T10:45:00", "Raum E214: Großer Physiksaal"),
    ("e-mt-24", "w-mt-24", "2024-11-20T10:00:00", "2024-11-20T10:45:00", "Raum E214: Großer Physiksaal"),
    ("e-ue-a", "w-ue-26", "2026-11-16T16:30:00", "2026-11-16T18:15:00", "Raum F303: Testsaal"),
    ("e-ue-b", "w-ue-26", "2026-11-16T16:30:00", "2026-11-16T18:15:00", "Raum 031: e-Classroom"),
    ("e-ue-c", "w-ue-26", "2026-11-16T16:30:00", "2026-11-16T18:15:00", "Raum F102"),
    ("e-ue-x", "w-ue-26", "2026-11-17T08:00:00", "2026-11-17T09:30:00", "Raum B227"),     # andere Gruppe
    ("e-ms-1", "w-ms-26", "2026-11-16T15:30:00", "2026-11-16T17:00:00", "Raum 003"),
    ("e-ms-0", "w-ms-26", "2026-11-09T15:30:00", "2026-11-09T17:00:00", "Raum 003"),
    ("e-ms-2", "w-ms-26", "2026-11-30T15:30:00", "2026-11-30T17:00:00", "Raum 003"),
]
CALENDAR = ["e-rt-1", "e-rt-2", "e-mt-1", "e-ue-a", "e-ue-b", "e-ue-c", "e-ms-1", "e-ms-0", "e-ms-2"]
SERIES_SQL = """INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, rrule, date_from, date_to, source, attend)
                VALUES ((SELECT module_id FROM courses WHERE id=?), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)"""
SERIES = [
    # passt zum Stud.IP-Termin Mo 15:30 (bleibt, mit Notiz, bekommt Termin-ID)
    ["w-ms-26", "w-ms-26", "Testmechatronik", "vorlesung", 0, "15:30", "17:00", "", "weekly", "2026-11-02", "2027-01-25", "studip"],
    # veraltet: automatisch uebernommen, Stud.IP kennt Mo 13:45 nicht (faellt weg)
    ["w-ms-26", "w-ms-26", "Testmechatronik (Hörsaalübung)", "hoersaaluebung", 0, "13:45", "15:15", "Raum 031", "weekly", "2026-11-02", "2027-01-25", "studip"],
    # von Hand bestaetigt, ohne Stud.IP-Termin (bleibt)
    ["w-ms-26", "w-ms-26", "Testmechatronik Tutorium", "tutorium", 3, "08:00", "09:00", "", "weekly", "2026-11-05", "2027-01-28", "studip-manual"],
    # automatisch, Do 10:00 alle 14 Tage, an diesem Tag mit gespeichertem Ausfall laut Stud.IP (bleibt sichtbar)
    ["w-rt-26", "w-rt-26", "Testregelungstechnik II", "vorlesung", 3, "10:00", "12:00", "Raum 029", "biweekly", "2026-11-05", "2027-01-28", "studip"],
]


def build(check: bool) -> int:
    src = SchemaSource()
    try:
        from app import semesters, study, studip_sync, timetable

        study.today = lambda: TODAY                 # semesters fragt study.today (wie der uebrige Kern)
        src.db.now_iso = lambda: NOW
        db = src.db

        out: dict = {"today": TODAY.isoformat(), "now": NOW, "week": {"start": WEEK[0], "end": WEEK[1]}}
        out["semester_keys"] = [{"title": t, "key": list(k) if (k := semesters.key(t)) else None} for t in SEMESTER_KEYS]
        out["current"] = [{"day": d, "key": list(semesters.current(date.fromisoformat(d))), "label": semesters.label(semesters.current(date.fromisoformat(d)))} for d in CURRENT_DAYS]
        out["semester_cases"] = [{**c, "is_current": semesters.is_current(c["semester"], c["semester_end"], c["ends_at"], TODAY)} for c in SEMESTER_CASES]

        class Resp:
            def __init__(self, data):
                self.data = data

            def json(self):
                return self.data

        class Req:
            def get(self, url, headers=None):
                return Resp({"data": {"id": "u-test"}} if url.endswith("/users/me") else API_RESPONSE)

        class Page:
            request = Req()

        out["fetch_courses"] = {"request": "users/{id}/courses?page[limit]=100&include=start-semester,end-semester",
                                "response": API_RESPONSE, "courses": studip_sync.fetch_courses(Page())}

        merged = timetable.merge_weekly([
            {"title": "Testmesstechnik I", "course_id": cid, "weekday": 2, "start_time": "10:00", "end_time": "10:45", "date_from": d}
            for cid, days in (("w-mt-24", ["2024-10-16", "2024-10-23", "2024-10-30"]), ("w-mt-26", ["2026-10-21", "2026-10-28", "2026-11-04"]))
            for d in days])
        out["merge_weekly_multi_year"] = {"merged": merged}

        src.fresh_db("woche")
        seed: list[dict] = []
        with db.cursor() as conn:
            for c in COURSES_IN:
                studip_sync.upsert_course(conn, c, NOW)
            study.ensure_modules(conn)
            out["courses_in"] = COURSES_IN
            out["courses_after"] = db.rows(conn, """SELECT id, title, semester, semester_end, semester_ends_at, subject, kind, active, active_custom, module_id
                                                    FROM courses WHERE id LIKE 'w-%' ORDER BY id""")
            out["modules_after"] = db.rows(conn, "SELECT id, name, semester, color, active, active_custom FROM modules ORDER BY id")

            # Nutzer schaltet den alten Kurs selbst ein; der naechste Abgleich laesst ihn
            conn.execute("UPDATE courses SET active=1, active_custom=1 WHERE id='w-alt-23'")
            studip_sync.upsert_course(conn, COURSES_IN[5], NOW)
            out["user_choice"] = {"sql": "UPDATE courses SET active=1, active_custom=1 WHERE id='w-alt-23'", "then_upsert": "w-alt-23",
                                  "course": db.row(conn, "SELECT id, active, active_custom FROM courses WHERE id='w-alt-23'")}
            conn.execute("UPDATE courses SET active=0, active_custom=0 WHERE id='w-alt-23'")
            seed.append({"sql": "UPDATE courses SET active=0, active_custom=0 WHERE id='w-alt-23'", "params": []})

            def run(sql, params):
                conn.execute(sql, params)
                seed.append({"sql": " ".join(sql.split()), "params": list(params)})

            for e in EVENTS:
                run("INSERT INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,?,?,?,?,?,?)", [e[0], e[1], "Termin", e[2], e[3], e[4], NOW])
            for i in CALENDAR:
                run("INSERT INTO studip_calendar_dates(id, fetched_at) VALUES (?,?)", [i, CAL_FETCHED])
            for s in SERIES:
                run(SERIES_SQL, s)
            run("""INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, rrule, date_from, date_to, source, attend)
                   VALUES (NULL, NULL, 'Testlerngruppe', 'persoenlich', 2, '18:00', '19:30', '', 'weekly', NULL, NULL, 'manual', 1)""", [])
            run("INSERT INTO event_notes(event_id, note, source, updated_at) VALUES ((SELECT id FROM course_events WHERE title='Testmechatronik'), 'Skript mitbringen', 'user', ?)", [NOW])
            run("""INSERT INTO event_exceptions(event_id, date, type, note, created_at)
                   VALUES ((SELECT id FROM course_events WHERE title='Testregelungstechnik II'), '2026-11-19', 'cancelled', 'Ausfall laut Stud.IP', ?)""", [NOW])
            out["seed"] = seed
            start, end = date.fromisoformat(WEEK[0]), date.fromisoformat(WEEK[1])
            out["week"]["studip_dated"] = timetable.studip_dated(conn, start, end)
            out["week"]["occurrences"] = timetable.occurrences(conn, start, end)
            out["week"]["busy_2026_11_18"] = timetable.busy_blocks(conn, date(2026, 11, 18), db.get_settings(conn), include_packages=False)
        ok = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
        return 0 if ok or not check else 1
    finally:
        src.cleanup()


if __name__ == "__main__":
    sys.exit(build("--check" in sys.argv[1:]))
