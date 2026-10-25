"""Erzeugt packages/shared-contracts/fixtures/local-backend/timetable-logic.json: der Stundenplan aus app/timetable.py
und /api/timetable/* aus app/server.py auf erfundenen Daten, mit eingefrorener Uhr (Sonntag, 25.10.2026, 14:30:05
Ortszeit Europe/Berlin, Tag der Zeitumstellung). Der Swift-Kern (LocalTimetableTests) legt dieselben Daten an,
schickt dieselben Anfragen in derselben Reihenfolge an das lokale Backend und vergleicht jede Antwort exakt.

Inhalt:
- seed: SQL-Anweisungen nach init_db (Einstellungen, Module, Kurse, Termine, Ausnahmen, Lernpakete, Stud.IP-Termine
  und persoenliche Stud.IP-Eintraege, Stud.IP-Dateien der Module ueber mehrere Semesterwochen; alles erfunden)
- steps: Anfragen mit Status und Antwort; danach die Tabellen course_events, event_exceptions, schedule_imports.
  Mit den Dateien liefern /api/timetable/event-materials und /attendance echte Unterlagen zum Termin
  (materials_for_event, S4), GET /api/modules den naechsten Termin je Modul (next_event aus occurrences)
- dashboard_today: Termine und freie Fenster von heute aus GET /api/dashboard (die Uebersicht ist sonst S6)
- ics: parse_ics fuer Kalenderdateien (UTC, TZID, RRULE, BYDAY wie der LSF-Export, EXDATE, UID, DESCRIPTION,
  Ganztags, Faltung, Zeitumstellung)
- matcher: difflib.SequenceMatcher(None, a, b).ratio(); guess_module: Titel -> Modul auf den Seed-Daten
- merge_weekly: Einzeltermine -> Serien
- auto_import: timetable.auto_import zweimal auf frischen Seed-Daten mit einem neuen Kurs samt Fach (extra_seed, wie
  direkt nach dem Speichern im Abgleich: ensure_modules legt sein Modul an), Ergebnis, Tabellen und modules

Pfade mit KI (Import aus Text, PDF, Bild) werden nicht aufgerufen. Der Server laeuft nur gegen Dateien in einem
Temp-Ordner (tools/schema_source.py), nie gegen data/. Zeitzone Europe/Berlin (datetime.fromtimestamp der
Aenderungszeiten wie auf dem PC-Server in Berlin).
Aufruf im Projektordner: python tools/gen-timetable-fixture.py [--check]
"""
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
import time
from datetime import date, datetime
from pathlib import Path

from schema_source import ROOT, SchemaSource, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend" / "timetable-logic.json"
NOW = "2026-10-25T14:30:05"
TODAY = (2026, 10, 25)

SEED: list[tuple[str, list]] = [
    ("UPDATE settings SET value=? WHERE key='blocked_times'",
     [json.dumps([{"weekday": 0, "start": "12:00", "end": "13:00", "title": "Mittag"}, {"weekday": 3, "start": "17:00", "end": "18:30"}])]),
    ("UPDATE settings SET value='20' WHERE key='travel_minutes'", []),
    ("INSERT INTO modules(name, color, sort, created_at) VALUES (?,?,?,?)", ["Testmathematik I", "#111111", 0, "2026-10-01T09:00:00"]),
    ("INSERT INTO modules(name, color, sort, created_at) VALUES (?,?,?,?)", ["Testphysik", "#222222", 1, "2026-10-01T09:00:00"]),
    ("INSERT INTO modules(name, color, sort, created_at) VALUES (?,?,?,?)", ["Programmierkurs Beispiel", "#333333", 2, "2026-10-01T09:00:00"]),
]
for cid, title, kind, module, active in [
    ("k-ma-vl", "Testmathematik I", "vorlesung", 1, 1),
    ("k-ma-ue", "Übung zu Testmathematik I", "uebung", 1, 1),
    ("k-ph", "Testphysik für Ingenieure", "vorlesung", 2, 1),
    ("k-prog-ue", "Gruppenübung Programmierkurs Beispiel", "gruppenuebung", 3, 1),
    ("k-block", "Blockseminar Beispiel", "vorlesung", None, 1),
    ("k-sonst", "Begrüßung der Erstsemester", "sonstiges", None, 1),
    ("k-alt", "Altkurs Inaktiv", "vorlesung", None, 0),
]:
    SEED.append(("INSERT INTO courses(id, title, number, semester, subject, kind, active, module_id, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                 [cid, title, None, "WiSe 2026/27", None, kind, active, module, "2026-10-01T09:00:00"]))
EVENT_COLS = "module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, date_from, date_to, attend, source, color, created_at"
for ev in [
    [1, "k-ma-vl", "Testmathematik I", "vorlesung", 0, "10:00", "11:30", "Raum A", "Prof. Beispiel", "weekly", None, None, 1, "studip", None],
    [2, "k-ph", "Testphysik", "vorlesung", 2, "08:15", "09:45", "Raum B", "", "biweekly", "2026-10-14", None, 1, "manual", "#ff0000"],
    [None, None, "Laborpraktikum Test", "labor", 4, "14:00", "17:00", "Labor 1", "", "once", "2026-10-30", None, 1, "manual", None],
    [None, None, "Sport (nicht besucht)", "sonstiges", 1, "18:00", "19:30", "", "", "weekly", None, None, 0, "personal", None],
    [1, "k-ma-ue", "Übung zu Testmathematik I", "uebung", 3, "12:15", "13:45", "Raum C", "", "weekly", "2026-10-19", "2026-12-17", 1, "studip", None],
    [None, None, "Sonntagstermin", "sonstiges", 6, "09:00", "10:00", "", "", "weekly", None, None, 1, "manual", ""],
]:
    SEED.append((f"INSERT INTO course_events({EVENT_COLS}) VALUES ({','.join('?' * 16)})", ev + ["2026-10-01T09:00:00"]))
for ex in [
    [1, "2026-10-26", "cancelled", None, None, None, "fällt aus"],
    [1, "2026-11-02", "moved", "2026-11-03", "10:00", "11:30", ""],
    [5, "2026-10-22", "skip", None, None, None, ""],
    [4, "2026-10-27", "attend", None, None, None, ""],
    [2, "2026-10-28", "edit", None, "08:30", "10:00", "einzeln bearbeitet"],
    [6, "2026-11-01", "skip", None, None, None, ""],
]:
    SEED.append(("INSERT INTO event_exceptions(event_id, date, type, new_date, new_start, new_end, note, created_at) VALUES (?,?,?,?,?,?,?,?)",
                 ex + ["2026-10-02T09:00:00"]))
for pk in [
    ["2026-10-29", 1, "Testmathematik I", "Paket A", "12:00", "13:00", "geplant"],
    ["2026-10-29", 2, "Testphysik", "Paket B", "15:00", "16:00", "in_bearbeitung"],
    ["2026-10-27", 1, "Testmathematik I", "Paket verschoben", "09:00", "10:00", "verschoben"],
    ["2026-10-25", 3, "Programmierkurs Beispiel", "Paket C", "15:00", "16:30", "geplant"],
    ["2026-11-03", 3, "Programmierkurs Beispiel", "Paket D", "10:30", "11:00", "geplant"],
    ["2026-10-30", 2, "Testphysik", "Paket ohne Zeit", None, None, "geplant"],
]:
    SEED.append(("INSERT INTO study_packages(date, module_id, subject, title, start_time, end_time, status, planned_minutes, created_at) VALUES (?,?,?,?,?,?,?,45,?)",
                 pk + ["2026-10-02T09:00:00"]))
STUDIP_EVENTS = [
    *[(f"se-ma-{i}", "k-ma-vl", f"{d}T10:00:00", f"{d}T11:30:00", "Hörsaal 1, Gebäude 3") for i, d in enumerate(["2026-10-19", "2026-10-26", "2026-11-02", "2026-11-09"])],
    ("se-ma-x", "k-ma-vl", "kaputt", "2026-11-16T11:30:00", "Hörsaal 1"),
    *[(f"se-ph-{i}", "k-ph", f"{d}T08:15:00", f"{d}T09:45:00", "") for i, d in enumerate(["2026-10-14", "2026-10-28", "2026-11-11"])],
    ("se-ue-0", "k-ma-ue", "2026-10-22T12:15:00", "2026-10-22T13:45:00", "Raum C"),
    ("se-ue-1", "k-ma-ue", "2026-10-29T12:15:00+01:00", "2026-10-29T13:45:00+01:00", "Raum C"),
    *[(f"se-pg-{g}-{i}", "k-prog-ue", f"{d}T{t}:00", f"{d}T{e}:00", f"Pool {g}")
      for g, (days, t, e) in enumerate([(["2026-10-20", "2026-10-27", "2026-11-03"], "08:00", "09:30"),
                                         (["2026-10-20", "2026-10-27", "2026-11-03"], "10:00", "11:30"),
                                         (["2026-10-21", "2026-10-28", "2026-11-04"], "14:00", "15:30"),
                                         (["2026-10-23", "2026-10-30", "2026-11-06"], "08:00", "09:30")])
      for i, d in enumerate(days)],
    ("se-bl-0", "k-block", "2026-11-07T09:00:00", "2026-11-07T16:00:00", "Seminarraum"),
    ("se-bl-1", "k-block", "2026-11-14T09:00:00", "2026-11-14T16:00:00", "Seminarraum"),
    ("se-bl-2", "k-block", "2026-10-25T02:30:00", "2026-10-25T03:30:00", None),
    ("se-so-0", "k-sonst", "2026-10-12T09:00:00", "2026-10-12T12:00:00", "Audimax"),
    ("se-alt-0", "k-alt", "2026-10-13T09:00:00", "2026-10-13T12:00:00", "Raum Z"),
    ("se-pg-biw-0", "k-ph", "2026-10-16T10:00:00", "2026-10-16T11:00:00", "Raum B"),
]
for sid, course, st, en, room in STUDIP_EVENTS:
    SEED.append(("INSERT INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,?,?,?,?,?,?)",
                 [sid, course, "Sitzung", st, en, room, "2026-10-24T08:00:00"]))
for pe in [
    ["pe1", "Lerngruppe Testmathematik alle 2 Wochen", 1, "16:00", "17:30", ""],
    ["pe2", "Chor", 4, "18:00", "20:00", "zweiwöchentlich"],
    ["pe3", None, 2, "07:00", "07:45", None],
]:
    SEED.append(("INSERT INTO studip_schedule_entries(id, title, weekday, start, end, description, fetched_at) VALUES (?,?,?,?,?,?,?)",
                 pe + ["2026-10-24T08:00:00"]))

# Stud.IP-Dateien der Module (Aenderungszeit Ortszeit Berlin): Semesterbeginn ist der Montag 12.10.2026 (drei Kurse
# laden in dieser Woche hoch); Woche 0 nach dem Stichtag 1.10., aeltere Unterlagen davor, ein inaktiver Kurs
SEED_FILES = [
    ("tf-ma-skript", "k-ma-vl", "Skript Testmathematik.pdf", None, "2026-10-05T10:00"),
    ("tf-ma-alt", "k-ma-vl", "Altklausur 2025.pdf", "Klausuren", "2026-09-20T10:00"),
    ("tf-ma-1", "k-ma-vl", "Vorlesung_01.pdf", "Vorlesung", "2026-10-13T10:00"),
    ("tf-ue-1", "k-ma-ue", "Übungsblatt 1.pdf", "Übungsblätter", "2026-10-14T09:00"),
    ("tf-ph-1", "k-ph", "Folien Einführung.pdf", None, "2026-10-15T12:00"),
    ("tf-pg-1", "k-prog-ue", "Blatt 1.pdf", None, "2026-10-16T08:00"),
    ("tf-ma-2", "k-ma-vl", "Vorlesung_02.pdf", "Vorlesung", "2026-10-20T10:00"),
    ("tf-ue-2", "k-ma-ue", "Lösung Blatt 1.pdf", "Lösungen", "2026-10-21T18:00"),
    ("tf-ma-3", "k-ma-vl", "Vorlesung_03.pdf", "Vorlesung", "2026-10-24T23:30"),
    ("tf-alt", "k-alt", "Folien Altkurs.pdf", None, "2026-10-13T10:00"),
]


def _files_seed() -> list[tuple[str, list]]:
    """INSERT der Dateien (Unix-Zeiten erst hier: TZ=Europe/Berlin ist dann gesetzt)"""
    return [("INSERT INTO files(id, course_id, name, size, mime, chdate, studip_folder, status, first_seen) VALUES (?,?,?,?,?,?,?,?,?)",
             [fid, course, name, 1000 + i, "application/pdf", int(datetime.fromisoformat(when).timestamp()), folder,
              "gelesen" if i % 3 == 0 else "neu", "2026-10-24T08:00:00"])
            for i, (fid, course, name, folder, when) in enumerate(SEED_FILES)]


# auto_import direkt nach dem Speichern eines neuen Kurses mit Fach (noch ohne Modul): ensure_modules zuerst
AUTO_EXTRA: list[tuple[str, list]] = [
    ("INSERT INTO courses(id, title, number, semester, subject, kind, active, module_id, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
     ["k-neu", "Testchemie", None, "WiSe 2026/27", "Testchemie", "vorlesung", 1, None, "2026-10-24T08:00:00"]),
    *[("INSERT INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,?,?,?,?,?,?)",
       [f"se-neu-{i}", "k-neu", "Sitzung", f"{d}T14:00:00", f"{d}T15:30:00", "Labor C", "2026-10-24T08:00:00"])
      for i, d in enumerate(["2026-10-19", "2026-10-26", "2026-11-02"])],
]

ICS_IN_FORM = ("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Testkurs Physik – Vorlesung\r\nDTSTART:20261021T061500Z\r\nDTEND:20261021T074500Z\r\n"
               "RRULE:FREQ=WEEKLY;UNTIL=20270127T235959Z\r\nLOCATION:P 101\\, Haus 2\r\nEXDATE:20261223T071500Z\r\nEND:VEVENT\r\n"
               "BEGIN:VEVENT\r\nSUMMARY:Testmathematik I\r\nDTSTART;TZID=Europe/Berlin:20261019T101500\r\nDTEND;TZID=Europe/Berlin:20261019T114500\r\n"
               "RRULE:FREQ=WEEKLY\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")

STEPS: list[dict] = [
    {"method": "GET", "path": "/api/timetable/week?start=2026-10-19"},
    {"method": "GET", "path": "/api/timetable/week?start=2026-10-26"},
    {"method": "GET", "path": "/api/timetable/week?start=2026-11-02"},
    {"method": "GET", "path": "/api/timetable/week?start=2027-01-25"},
    {"method": "GET", "path": "/api/timetable/day?date=2026-10-25"},
    {"method": "GET", "path": "/api/timetable/day?date=2026-10-29"},
    {"method": "GET", "path": "/api/timetable/day?date=2026-11-03"},
    {"method": "GET", "path": "/api/timetable/events"},
    {"method": "GET", "path": "/api/timetable/free?date=2026-10-28"},
    {"method": "GET", "path": "/api/timetable/conflicts"},
    {"method": "GET", "path": "/api/timetable/conflicts?days=3"},
    {"method": "GET", "path": "/api/timetable/auto-status"},
    {"method": "GET", "path": "/api/timetable/event-materials/1?date=2026-10-26"},
    {"method": "GET", "path": "/api/timetable/event-materials/5?date=2026-10-22"},
    {"method": "GET", "path": "/api/timetable/event-materials/2?date=2026-10-14"},
    {"method": "GET", "path": "/api/timetable/event-materials/1?date=2026-10-05"},
    {"method": "GET", "path": "/api/timetable/event-materials/1?date=2026-09-28"},
    {"method": "GET", "path": "/api/timetable/event-materials/3?date=2026-10-30"},
    {"method": "GET", "path": "/api/timetable/event-materials/999?date=2026-10-26"},
    {"method": "GET", "path": "/api/modules"},
    {"method": "POST", "path": "/api/timetable/import/preview", "form": {"source": "studip"}, "name": "studip"},
    {"method": "POST", "path": "/api/timetable/import/preview", "form": {"source": "ics", "text": ICS_IN_FORM}},
    {"method": "POST", "path": "/api/timetable/import/preview", "form": {"source": "ics"},
     "file": {"field": "upload", "filename": "plan.ics", "content_type": "text/calendar", "text": ICS_IN_FORM.replace("Testkurs Physik", "Testkurs Upload")}},
    {"method": "POST", "path": "/api/timetable/import/preview", "form": {"text": "x"}},
    {"method": "POST", "path": "/api/timetable/import/confirm", "body": "FROM_STUDIP_PREVIEW"},
    {"method": "GET", "path": "/api/timetable/week?start=2026-10-26"},
    {"method": "GET", "path": "/api/timetable/auto-status"},
    {"method": "POST", "path": "/api/timetable/events", "body": {"title": "Neuer Termin", "weekday": 4, "start_time": "09:00", "end_time": "10:30", "module_id": 2}},
    {"method": "POST", "path": "/api/timetable/events", "body": {}},
    {"method": "POST", "path": "/api/timetable/events", "body": {"title": "Text-Wochentag", "weekday": "2", "rrule": "once", "date_from": "2026-11-04"}},
    {"method": "PATCH", "path": "/api/timetable/events/2", "body": {"scope": "series", "room": "Neuer Raum", "color": "#00ff00", "unbekannt": 1}},
    {"method": "PATCH", "path": "/api/timetable/events/1", "body": {"scope": "future", "date": "2026-11-16", "start_time": "10:15", "end_time": "11:45"}},
    {"method": "PATCH", "path": "/api/timetable/events/5", "body": {"scope": "single", "date": "2026-11-05", "start_time": "13:00", "end_time": "14:30"}},
    {"method": "PATCH", "path": "/api/timetable/events/5", "body": {"scope": "single", "date": "2026-11-12", "new_date": "2026-11-13", "start_time": "08:00", "end_time": "09:30"}},
    {"method": "PATCH", "path": "/api/timetable/events/4", "body": {"scope": "single", "attend": 1}},
    {"method": "PATCH", "path": "/api/timetable/events/999", "body": {"title": "x"}},
    {"method": "POST", "path": "/api/timetable/attendance", "body": {"event_id": 2, "date": "2026-11-11", "mode": "today_skip"}},
    {"method": "POST", "path": "/api/timetable/attendance", "body": {"event_id": 4, "date": "2026-11-03", "mode": "permanent_attend"}},
    {"method": "POST", "path": "/api/timetable/attendance", "body": {"event_id": 1, "mode": "cancelled"}},
    {"method": "POST", "path": "/api/timetable/attendance", "body": {"event_id": 5, "date": "2026-10-22", "mode": "reset"}},
    {"method": "POST", "path": "/api/timetable/attendance", "body": {"event_id": "5", "date": "2026-11-19", "mode": "permanent_skip"}},
    {"method": "POST", "path": "/api/timetable/attendance", "body": {"event_id": 999, "mode": "today_skip"}},
    {"method": "POST", "path": "/api/timetable/exceptions", "body": {"event_id": 2, "date": "2026-11-25", "type": "cancelled", "note": "Dozent krank"}},
    {"method": "POST", "path": "/api/timetable/exceptions", "body": {"event_id": "3", "date": "2026-10-30", "type": "moved", "new_date": "2026-10-31", "new_start": "10:00", "new_end": "13:00"}},
    {"method": "GET", "path": "/api/timetable/week?start=2026-10-26"},
    {"method": "GET", "path": "/api/timetable/week?start=2026-11-09"},
    {"method": "GET", "path": "/api/timetable/week?start=2026-11-16"},
    {"method": "GET", "path": "/api/modules"},
    {"method": "DELETE", "path": "/api/timetable/events/3"},
    {"method": "DELETE", "path": "/api/timetable/events/999"},
    {"method": "GET", "path": "/api/timetable/events"},
    {"method": "GET", "path": "/api/timetable/conflicts"},
    {"method": "POST", "path": "/api/timetable/import/confirm", "body": {"entries": [], "remove_ids": "12", "source": "ics"}},
    # Kalenderdatei mit Ausfaellen uebernehmen, Nutzer aendert zwei Tage, dann neue Fassung der Datei fuer dieselbe
    # Serie: nicht mehr gemeldete Ausfaelle entfallen, die Tage des Nutzers bleiben ("id:<Titel>" = ID der Serie)
    {"method": "POST", "path": "/api/timetable/import/confirm", "body": {"entries": [
        {"title": "Testkurs Mechanik", "kind": "vorlesung", "weekday": 2, "start_time": "08:15", "end_time": "09:45", "room": "M 1",
         "rrule": "weekly", "date_from": "2026-10-21", "date_to": "2027-01-27", "exdates": ["2026-11-04", "2026-11-11", "2026-11-18"]}],
        "source": "ics", "remove_ids": []}},
    {"method": "POST", "path": "/api/timetable/exceptions", "body": {"event_id": "id:Testkurs Mechanik", "date": "2026-11-25", "type": "cancelled", "note": "Dozent krank"}},
    {"method": "POST", "path": "/api/timetable/attendance", "body": {"event_id": "id:Testkurs Mechanik", "date": "2026-11-11", "mode": "today_attend"}},
    {"method": "POST", "path": "/api/timetable/import/confirm", "body": {"entries": [
        {"existing_id": "id:Testkurs Mechanik", "title": "Testkurs Mechanik", "kind": "vorlesung", "weekday": 2, "start_time": "08:30", "end_time": "10:00",
         "room": "", "exdates": ["2026-11-11", "2026-12-02", "kaputt"]}], "source": "ics", "remove_ids": []}},
    {"method": "GET", "path": "/api/timetable/week?start=2026-11-02"},
    {"method": "POST", "path": "/api/timetable/import/confirm", "body": {"entries": [
        {"existing_id": "id:Testkurs Mechanik", "title": "Testkurs Mechanik", "weekday": 2, "start_time": "08:30", "end_time": "10:00"}],
        "source": "ics", "remove_ids": []}},
]

ICS_CASES: list[tuple[str, str]] = [
    ("utc-sommer", "SUMMARY:UTC Sommer\nDTSTART:20261021T061500Z\nDTEND:20261021T074500Z\nRRULE:FREQ=WEEKLY"),
    ("utc-winter", "SUMMARY:UTC Winter\nDTSTART:20261104T071500Z\nDTEND:20261104T084500Z"),
    ("utc-zeitumstellung", "SUMMARY:Umstellung vorher\nDTSTART:20261025T003000Z\nDTEND:20261025T005959Z\nEND:VEVENT\nBEGIN:VEVENT\n"
                           "SUMMARY:Umstellung nachher\nDTSTART:20261025T010000Z\nDTEND:20261025T013000Z"),
    ("utc-maerz", "SUMMARY:Maerz\nDTSTART:20270328T005900Z\nDTEND:20270328T010000Z"),
    ("utc-mitternacht", "SUMMARY:Nachtkurs\nDTSTART:20261105T233000Z\nDTEND:20261106T003000Z"),
    ("tzid-berlin", "SUMMARY:Berlin\nDTSTART;TZID=Europe/Berlin:20261021T081500\nDTEND;TZID=Europe/Berlin:20261021T094500"),
    ("tzid-quoted", 'SUMMARY:Quoted\nDTSTART;TZID="Europe/Berlin":20261021T081500\nDTEND;VALUE=DATE-TIME;TZID="Europe/Berlin":20261021T094500'),
    ("tzid-utc", "SUMMARY:TZID UTC\nDTSTART;TZID=UTC:20261021T061500\nDTEND;TZID=Etc/UTC:20261021T074500"),
    ("tzid-windows", "SUMMARY:Windows\nDTSTART;TZID=W. Europe Standard Time:20261021T081500\nDTEND;TZID=W. Europe Standard Time:20261021T094500"),
    ("tzid-newyork", "SUMMARY:New York\nDTSTART;TZID=America/New_York:20261021T101500\nDTEND;TZID=America/New_York:20261021T114500\nEND:VEVENT\n"
                     "BEGIN:VEVENT\nSUMMARY:New York Luecke\nDTSTART;TZID=America/New_York:20261028T101500\nDTEND;TZID=America/New_York:20261028T114500"),
    ("tzid-unbekannt", "SUMMARY:Unbekannt\nDTSTART;TZID=Mars/Olympus:20261021T081500\nDTEND;TZID=GMT+1:20261021T094500"),
    ("rrule", "SUMMARY:Testkurs Analysis – Übung\nDTSTART;TZID=Europe/Berlin:20261020T101500\nDTEND;TZID=Europe/Berlin:20261020T114500\n"
              "RRULE:FREQ=WEEKLY;INTERVAL=2;UNTIL=20270126T225959Z\nEND:VEVENT\nBEGIN:VEVENT\n"
              "SUMMARY:Until vor Beginn\nDTSTART:20261020T091500Z\nDTEND:20261020T104500Z\nRRULE:FREQ=WEEKLY;UNTIL=20270126T235959Z\nEND:VEVENT\nBEGIN:VEVENT\n"
              "SUMMARY:Until gleicher Tag\nDTSTART;TZID=Europe/Berlin:20261020T101500\nDTEND;TZID=Europe/Berlin:20261020T114500\nRRULE:FREQ=WEEKLY;UNTIL=20270126T080000Z\nEND:VEVENT\nBEGIN:VEVENT\n"
              "SUMMARY:Until Datum\nDTSTART:20261020T101500\nDTEND:20261020T114500\nRRULE:FREQ=WEEKLY;UNTIL=20270126\nEND:VEVENT\nBEGIN:VEVENT\n"
              "SUMMARY:Intervall 02\nDTSTART:20261020T101500\nDTEND:20261020T114500\nRRULE:FREQ=WEEKLY;INTERVAL=02\nEND:VEVENT\nBEGIN:VEVENT\n"
              "SUMMARY:Taeglich Labor\nDTSTART:20261020T101500\nDTEND:20261020T114500\nRRULE:FREQ=DAILY;COUNT=5"),
    ("exdate", "SUMMARY:Testkurs Mechanik\nDTSTART;TZID=Europe/Berlin:20261021T081500\nDTEND;TZID=Europe/Berlin:20261021T094500\nRRULE:FREQ=WEEKLY\n"
               "EXDATE;TZID=Europe/Berlin:20261104T081500,20261111T081500\nEXDATE:20261223T071500Z\nEXDATE;VALUE=DATE:20261230\n"
               "EXDATE:20261105T233000Z\nEXDATE:kaputt\nEXDATE;TZID=America/New_York:20261118T030000"),
    ("ganztags", "SUMMARY:Exkursion\nDTSTART;VALUE=DATE:20261106\nDTEND;VALUE=DATE:20261107"),
    ("ohne-ende-und-kaputt", "SUMMARY:Ohne Ende\nDTSTART:20261022T233000\nEND:VEVENT\nBEGIN:VEVENT\nSUMMARY:Ohne Beginn\nDTEND:20261021T094500Z\n"
                             "END:VEVENT\nBEGIN:VEVENT\nSUMMARY:Kaputt\nDTSTART:20260230T081500\nEND:VEVENT\nBEGIN:VEVENT\nSUMMARY:Kurz\nDTSTART:20261021T0815\n"
                             "END:VEVENT\nBEGIN:VEVENT\nSUMMARY:Sekunde 60\nDTSTART:20261021T081560\nEND:VEVENT\nBEGIN:VEVENT\nDTSTART:20261021T081500\nLOCATION:"),
    ("faltung", "SUMMARY:Testkurs mit langem\n  Titel\\, Teil 2\nDTSTART:20261021T081500Z\nDTEND:20261021T094500Z\nLOCATION:Raum 1\\, Haus 2\n"
                "DESCRIPTION:Zeit: 10:00\n\tweiter\ndtstart:20261022T081500\nX-LEER\nSUMMARY;LANGUAGE=de:Überschrieben"),
    ("verschachtelt", "SUMMARY:Erster\nDTSTART:20261021T081500\nBEGIN:VEVENT\nSUMMARY:Zweiter\nDTSTART:20261023T081500"),
    # wie der LSF-Export (Uni Hildesheim): DTSTART ist der Semesterbeginn (Montag), der Wochentag steht in BYDAY
    ("byday", "SUMMARY:0815 - Testseminar Wohnen\\, Raum und Kultur\nDTSTART;TZID=Europe/Berlin:20261026T160000\n"
              "DTEND;TZID=Europe/Berlin:20261026T180000\nRRULE:FREQ=WEEKLY;UNTIL=20270205T235900Z;INTERVAL=1;BYDAY=TH\n"
              "EXDATE;TZID=Europe/Berlin:20261224T160000,20261231T160000,\nUID:4711:0815\n"
              "DESCRIPTION:Erste Sitzung\\nBitte Text lesen\\, danach Diskussion"),
    ("byday-mehrere", "SUMMARY:1234 - Testvorlesung Pädagogik\nDTSTART;TZID=Europe/Berlin:20261026T100000\n"
                      "DTEND;TZID=Europe/Berlin:20261026T120000\nRRULE:FREQ=WEEKLY;UNTIL=20270205T235900Z;BYDAY=TU,TH,-1SU,XX\n"
                      "EXDATE;TZID=Europe/Berlin:20261222T100000\nEXDATE;TZID=Europe/Berlin:20261224T100000\nEXDATE:20261225"),
    ("byday-doppelt", "SUMMARY:Doppelt\nDTSTART:20261021T081500\nDTEND:20261021T094500\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,MO\n"
                      "EXDATE:20261102T081500"),
    ("byday-unbekannt", "SUMMARY:Unbekannt\nDTSTART:20261021T081500\nDTEND:20261021T094500\nRRULE:FREQ=WEEKLY;BYDAY=xx\n"
                        "EXDATE:20261104T081500,20261106T081500"),
    ("byday-taeglich", "SUMMARY:Taeglich\nDTSTART:20261021T081500\nDTEND:20261021T094500\nRRULE:FREQ=DAILY;BYDAY=FR\nUID:  mit Leerzeichen  "),
]

MATCHER_CASES = [
    ("testkurs mathematik i", "mathematik i"), ("", ""), ("abc", ""), ("übung zu testmathematik i", "testmathematik i"),
    ("programmierkurs beispiel", "gruppenübung programmierkurs beispiel"), ("abcd", "bcda"), ("aaaa", "aa"),
    ("einführung in die testphysik", "testphysik für ingenieure"), ("x" * 210 + "abc", "y" + "x" * 205 + "abc"),
    ("ab" * 120, "ba" * 130), ("é", "é"), ("qwertzuiop", "poiuztrewq"),
]

GUESS_TITLES = ["Testmathematik I", "Übung zu Testmathematik I", "Testphysik für Ingenieure", "Gruppenübung Programmierkurs Beispiel",
                "Lerngruppe Testmathematik alle 2 Wochen", "Chor", "Termin", "", "Programmier", "Physik", "TESTPHYSIK", "Beispiel Programmierkurs"]

MERGE_CASES = [
    [{"title": "A", "weekday": 0, "start_time": "10:00", "end_time": "11:00", "date_from": d, "room": "R1"} for d in ["2026-10-19", "2026-10-26", "2026-11-02"]],
    [{"title": "B", "weekday": 2, "start_time": "08:00", "end_time": "09:00", "date_from": d} for d in ["2026-11-11", "2026-10-14", "2026-10-28"]],
    [{"title": "C", "weekday": 1, "start_time": "08:00", "end_time": "09:00", "date_from": d} for d in ["2026-10-20", "2026-10-20", "2026-10-27"]]
    + [{"title": "D", "weekday": 1, "start_time": "08:00", "end_time": "09:00", "date_from": "2026-10-20"}]
    + [{"title": "C", "weekday": 1, "start_time": "08:00", "end_time": "09:30", "date_from": "2026-10-20"}],
    [{"title": "E", "weekday": 3, "start_time": "08:00", "end_time": "09:00", "date_from": d} for d in ["2026-10-22", "2026-11-05", "2026-11-12", "2026-11-26"]],
]


def frozen(src: SchemaSource):
    """Uhr einfrieren: date.today() in server/study und db.now_iso()"""
    class FrozenDate(date):
        @classmethod
        def today(cls):
            return cls(*TODAY)

    from app import server, study
    server.date = FrozenDate
    study.date = FrozenDate
    src.db.now_iso = lambda: NOW


def fresh(src: SchemaSource, name: str) -> Path:
    path = src.tmp / f"{name}.db"
    for suffix in ("", "-wal", "-shm"):
        path.with_name(path.name + suffix).unlink(missing_ok=True)
    src.use_db(path)
    src.db.init_db()
    with src.db.cursor() as conn:
        for sql, params in SEED:
            conn.execute(sql, params)
    return path


def tables(path: Path) -> dict:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    try:
        out = {t: [dict(r) for r in conn.execute(f"SELECT * FROM {t} ORDER BY id")] for t in ("course_events", "event_exceptions", "schedule_imports")}
    finally:
        conn.close()
    for r in out["schedule_imports"]:
        r["parsed"] = json.loads(r["parsed"]) if r["parsed"] else r["parsed"]
    return out


def confirm_body(preview: dict) -> dict:
    """Auswahl wie die Importvorschau der App: vorausgewaehlte Eintraege und die erste parallele Gruppe, mit
    existing_id aus diff.changed/diff.same (gleicher Titel und Wochentag); eine entfernte Serie wird geloescht."""
    entries = []
    first_group = True
    for e in preview["entries"]:
        if e.get("selected") is False:
            if not first_group:
                continue
            first_group = False
        o = {**e, "selected": True}
        match = next((c for c in preview["diff"]["changed"] if c["title"] == e["title"] and c["weekday"] == e["weekday"]), None) \
            or next((c for c in preview["diff"]["same"] if c["title"] == e["title"] and c["weekday"] == e["weekday"]), None)
        o["existing_id"] = match["existing_id"] if match else None
        entries.append(o)
    removed = [x["id"] for x in preview["diff"]["removed"] if x["title"] == "Sonntagstermin"]
    return {"entries": entries, "source": "studip", "import_id": preview["import_id"], "remove_ids": removed}


def series_ids(body, path: Path):
    """Platzhalter "id:<Titel>" -> ID der juengsten Serie mit diesem Titel (haengt von den Schritten davor ab)"""
    if isinstance(body, dict):
        return {k: series_ids(v, path) for k, v in body.items()}
    if isinstance(body, list):
        return [series_ids(v, path) for v in body]
    if isinstance(body, str) and body.startswith("id:"):
        conn = sqlite3.connect(path)
        try:
            return conn.execute("SELECT id FROM course_events WHERE title=? ORDER BY id DESC", (body[3:],)).fetchone()[0]
        finally:
            conn.close()
    return body


def main() -> int:
    check = "--check" in sys.argv[1:]
    saved_tz = os.environ.get("TZ")
    os.environ["TZ"] = "Europe/Berlin"                  # datetime.fromtimestamp wie auf dem PC-Server in Berlin
    time.tzset()
    SEED.extend(_files_seed())
    src = SchemaSource()
    try:
        from app import server, timetable
        frozen(src)
        spec = importlib.util.spec_from_file_location("gen_local_backend_fixture", Path(__file__).with_name("gen-local-backend-fixture.py"))
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)

        path = fresh(src, "stundenplan")
        steps, previews = [], {}
        for s in STEPS:
            body = s.get("body")
            if body == "FROM_STUDIP_PREVIEW":
                body = confirm_body(previews["studip"])
            elif body is not None:
                body = series_ids(body, path)
            form = dict(s.get("form") or {})
            if "file" in s:
                status, value = asgi_file(server.app, s["path"], form, s["file"])
            else:
                status, value = gen.asgi(server.app, s["method"], s["path"], body, form if "form" in s else None)
            if s.get("name"):
                previews[s["name"]] = value
            step = {"method": s["method"], "path": s["path"], "status": status, "response": value}
            for k in ("form", "file"):
                if k in s:
                    step[k] = s[k]
            if body is not None:
                step["body"] = body
            steps.append(step)
        after = tables(path)

        path = fresh(src, "uebersicht")
        status, dash = gen.asgi(server.app, "GET", "/api/dashboard")
        assert status == 200, dash
        dashboard_today = {"events": dash["today"]["events"], "free": dash["today"]["free"]}

        ics = [{"name": n, "text": _ics(t), "entries": timetable.parse_ics(_ics(t))} for n, t in ICS_CASES]
        matcher = [{"a": a, "b": b, "ratio": __import__("difflib").SequenceMatcher(None, a, b).ratio()} for a, b in MATCHER_CASES]
        with src.db.cursor() as conn:
            guess = [{"title": t, "module_id": timetable.guess_module(conn, t)} for t in GUESS_TITLES]
        merge = [{"entries": c, "merged": timetable.merge_weekly([dict(e) for e in c])} for c in MERGE_CASES]

        path = fresh(src, "autoimport")
        with src.db.cursor() as conn:
            conn.execute("DELETE FROM course_events")
            for sql, params in AUTO_EXTRA:
                conn.execute(sql, params)
            first = timetable.auto_import(conn)
            second = timetable.auto_import(conn)
            modules = [dict(r) for r in conn.execute("SELECT * FROM modules ORDER BY id")]
        auto = {"extra_seed": [{"sql": q, "params": p} for q, p in AUTO_EXTRA], "first": first, "second": second,
                "tables": tables(path), "modules": modules}
    finally:
        src.cleanup()
        if saved_tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = saved_tz
        time.tzset()
    out = {"generator": "tools/gen-timetable-fixture.py", "now": NOW, "timezone": "Europe/Berlin", "seed": [{"sql": q, "params": p} for q, p in SEED],
           "steps": steps, "tables_after": after, "dashboard_today": dashboard_today, "ics": ics, "matcher": matcher,
           "guess_module": guess, "merge_weekly": merge, "auto_import": auto}
    ok = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
    return 0 if ok or not check else 1


def _ics(body: str) -> str:
    return "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n" + body.replace("\n", "\r\n") + "\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"


def asgi_file(app, path: str, form: dict, file: dict):
    """multipart mit Textfeldern und einer Datei (wie die App beim ICS-Import)"""
    import asyncio
    b = "uniflow-fixture"
    parts = [f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n' for k, v in sorted(form.items())]
    parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{file["field"]}"; filename="{file["filename"]}"\r\n'
                 f'Content-Type: {file["content_type"]}\r\n\r\n{file["text"]}\r\n')
    raw = ("".join(parts) + f"--{b}--\r\n").encode()
    headers = [(b"host", b"localhost"), (b"content-type", f"multipart/form-data; boundary={b}".encode()), (b"content-length", str(len(raw)).encode())]
    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "POST", "scheme": "http", "path": path,
             "raw_path": path.encode(), "query_string": b"", "headers": headers, "client": ("127.0.0.1", 5000), "server": ("localhost", 80)}
    out = {"status": None, "body": b""}
    sent = {"done": False}

    async def receive():
        if not sent["done"]:
            sent["done"] = True
            return {"type": "http.request", "body": raw, "more_body": False}
        return {"type": "http.disconnect"}

    async def send(msg):
        if msg["type"] == "http.response.start":
            out["status"] = msg["status"]
        elif msg["type"] == "http.response.body":
            out["body"] += msg.get("body", b"")

    asyncio.run(app(scope, receive, send))
    return out["status"], json.loads(out["body"]) if out["body"] else None


if __name__ == "__main__":
    sys.exit(main())
