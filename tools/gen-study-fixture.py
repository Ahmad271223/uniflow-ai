"""Erzeugt packages/shared-contracts/fixtures/local-backend/study-plan.json: die Lernlogik aus app/study.py
(Lernkalender, Lernpakete, Aufgaben, Planen, Verschieben, Woche retten, Machbarkeit, Uebersicht) ueber
/api/calendar*, /api/tasks*, /api/packages*, /api/timetable/reslot und /api/dashboard aus app/server.py, auf
erfundenen Daten mit eingefrorener Uhr (Europe/Berlin). Der Swift-Kern (LocalStudyPlanTests) legt dieselben Daten
an, schickt dieselben Anfragen in derselben Reihenfolge an das lokale Backend und vergleicht jede Antwort und die
Tabellen danach exakt.

Inhalt:
- seed: SQL-Anweisungen nach init_db: Einstellungen (Lerntage mit dem Sonntag der Zeitumstellung, Sperrzeiten,
  Fahrtzeit), Module (eines inaktiv, eines mit Klausurtermin, eines ohne Wochentest), Kurse (einer mit Fach ohne
  Modul: ensure_modules legt es an, einer inaktiv), Stud.IP-Dateien ueber die Lehrwochen 0 bis 2 (eine am 25.10. in
  der doppelten Stunde), Analysen mit Dauer, Titel und Themen, Stundenplan mit Ausnahmen, Lernpakete vergangener
  Tage (nachholen, teilweise, erledigt), ein Wochentest mit Ergebnis
- steps: Anfragen mit Status und Antwort. Platzhalter in Pfad und Rumpf werden vor jedem Schritt aufgeloest und
  aufgeloest gespeichert: {pkg:DATUM:N} = ID des N-ten Pakets (nach ID) an diesem Tag, {task:DATUM:N:M} = ID der
  M-ten Aufgabe (nach sort, id) dieses Pakets, {new} = ID des zuletzt angelegten Pakets, {@name} = ID aus der
  benannten Antwort, {task:@name:M} = M-te Aufgabe dieses Pakets, "FROM:<name>" = moves der benannten Antwort. Schritte mit "now" stellen die Uhr weiter, Schritte mit "sql" aendern die Datenbank wie ein
  Abgleich (neue Dateien) oder wie eine Aenderung am Modul.
- tables_after: study_packages, study_tasks, task_history, modules und die Dateien (Status, gesehen)
- scenarios: weitere Ablaeufe auf eigener, frischer Datenbank mit demselben Seed ("nachgebessert": Korrekturen nach
  der Pruefung von S6 am 26.10.2026: freies Fenster, Plan ab Montag, Uhrzeit von Hand, Verschieben, "Uhrzeiten
  vergeben", leere Pakete, Ersetzen), je mit now, steps und tables_after
- derive_status: study._derive_status fuer alle Kombinationen der Aufgabenstatus

Keine KI-Aufrufe. Der Server laeuft nur gegen Dateien in einem Temp-Ordner (tools/schema_source.py), nie gegen data/.
Aufruf im Projektordner: python tools/gen-study-fixture.py [--check]
"""
from __future__ import annotations

import importlib.util
import itertools
import json
import re
import sqlite3
import sys
from datetime import date, datetime
from pathlib import Path

from schema_source import ROOT, SchemaSource, berlin_time, dump_tables, without_sync, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend" / "study-plan.json"
START = "2026-10-23T09:15:00"           # Freitag vor der Zeitumstellung (So 25.10.2026, 03:00 -> 02:00)
CLOCK = {"now": START}

SEED: list[tuple[str, list]] = [
    ("UPDATE settings SET value=? WHERE key=?", ["[5]", "free_days"]),                 # Samstag frei, Sonntag Lerntag
    ("UPDATE settings SET value=? WHERE key=?", ["4", "hours_per_day"]),
    ("UPDATE settings SET value=? WHERE key=?", ["20:00", "learn_end"]),
    ("UPDATE settings SET value=? WHERE key=?", ["20", "travel_minutes"]),
    ("UPDATE settings SET value=? WHERE key=?", ["10", "break_minutes"]),
    ("UPDATE settings SET value=? WHERE key=?",
     [json.dumps([{"weekday": 0, "start": "12:00", "end": "13:00", "title": "Mittag"}, {"weekday": 6, "start": "08:00", "end": "10:30"}]),
      "blocked_times"]),
]
for name, color, prio, exam, sort, active, weekly, tmin in [
    ("Testmathematik I", "#111111", 3, "2026-11-20", 0, 1, 1, None),
    ("Testphysik", "#222222", 2, None, 1, 1, 0, 30),
    ("Programmierkurs Beispiel", "#333333", 1, "2026-09-01", 2, 1, 1, 20),
    ("Altmodul", "#444444", 2, None, 3, 0, 1, None),
]:
    SEED.append(("INSERT INTO modules(name, semester, color, priority, exam_date, sort, active, weekly_test, test_minutes, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                 [name, "WiSe 2026/27", color, prio, exam, sort, active, weekly, tmin, "2026-10-01T09:00:00"]))
for cid, title, subject, kind, module, active in [
    ("k-ma-vl", "Testmathematik I", "Testmathematik I", "vorlesung", 1, 1),
    ("k-ma-ue", "Übung zu Testmathematik I", "Testmathematik I", "uebung", 1, 1),
    ("k-ph", "Testphysik für Ingenieure", "Testphysik", "vorlesung", 2, 1),
    ("k-pg", "Gruppenübung Programmierkurs Beispiel", "Programmierkurs Beispiel", "gruppenuebung", 3, 1),
    ("k-alt", "Altkurs Beispiel", "Altmodul", "vorlesung", 4, 1),
    ("k-ch", "Testchemie", "Testchemie", "vorlesung", None, 1),
    ("k-inaktiv", "Inaktiver Testkurs", "Testmathematik I", "vorlesung", 1, 0),
]:
    SEED.append(("INSERT INTO courses(id, title, semester, subject, kind, active, module_id, created_at) VALUES (?,?,?,?,?,?,?,?)",
                 [cid, title, "WiSe 2026/27", subject, kind, active, module, "2026-10-01T09:00:00"]))

# Stud.IP-Dateien (Aenderungszeit Ortszeit Berlin): Vorlesungsbeginn Montag 12.10.2026 (fuenf Kurse laden in dieser
# Woche hoch), Woche 0 nach dem Stichtag 1.10., aelteres Semester davor, ein inaktiver Kurs, ein inaktives Modul
FILES = [
    ("f-ma-v1", "k-ma-vl", "VL01 Einführung.pdf", "Vorlesung", "2026-10-12T10:00", "gelesen"),
    ("f-ma-u1", "k-ma-ue", "Blatt 1.pdf", "Übungsblätter", "2026-10-13T09:00", "erledigt"),
    ("f-ph-v1", "k-ph", "Folien Einführung.pdf", None, "2026-10-14T12:00", "neu"),
    ("f-pg-u1", "k-pg", "Blatt 1.pdf", None, "2026-10-15T08:00", "erledigt"),
    ("f-ch-v1", "k-ch", "Vorlesung 1.pdf", "Vorlesung", "2026-10-16T08:00", "neu"),
    ("f-alt-v1", "k-alt", "VL01.pdf", "Vorlesung", "2026-10-12T08:00", "neu"),
    ("f-ma-v2", "k-ma-vl", "VL02.pdf", "Vorlesung", "2026-10-19T10:00", "neu"),
    ("f-ma-u2", "k-ma-ue", "Blatt 2.pdf", "Übungsblätter", "2026-10-20T09:00", "neu"),
    ("f-ma-l1", "k-ma-ue", "Lösung Blatt 1.pdf", "Lösungen", "2026-10-20T18:00", "neu"),
    ("f-ma-s", "k-ma-vl", "Skript Testmathematik.pdf", "Skript", "2026-10-21T10:00", "neu"),
    ("f-ph-v2", "k-ph", "Folien Kapitel 2.pdf", None, "2026-10-21T12:00", "erledigt"),
    ("f-pg-u2", "k-pg", "Blatt 2.pdf", None, "2026-10-24T23:30", "neu"),
    ("f-ph-u2", "k-ph", "Übungsblatt 2.pdf", "Übungen", "2026-10-25T02:30", "neu"),     # doppelte Stunde (erste)
    ("f-ma-vk", "k-ma-vl", "Vorkurs Folien.pdf", "Vorlesung", "2026-10-05T10:00", "neu"),
    ("f-ma-alt", "k-ma-vl", "Altklausur 2025.pdf", "Klausuren", "2026-09-20T10:00", "neu"),
    ("f-inaktiv", "k-inaktiv", "VL01.pdf", "Vorlesung", "2026-10-13T10:00", "neu"),
]
ANALYSIS = [
    ("f-ma-v2", "vorlesung", "Grenzwerte und Stetigkeit", json.dumps(["Grenzwerte", "Folgen"]), 150),
    ("f-pg-u1", "uebung", None, None, 20),
    ("f-ph-v1", "vorlesung", "Einführung Physik", "kaputt", None),
]
for p in [
    # vergangene Pakete: offen -> nachholen, teilweise, erledigt; heute ein eigenes Paket mit Uhrzeit; am 27.10. ein
    # Wochentest mit Ergebnis
    [1, "2026-10-20", 1, "Testmathematik I", "Woche 1 · 12.10. – 18.10.", 1, 105, "geplant", 0, 1, "09:00", "10:45"],
    [2, "2026-10-21", 2, "Testphysik", "Einführung Physik", 1, 45, "geplant", 0, 1, "10:00", "10:45"],
    [3, "2026-10-22", 3, "Programmierkurs Beispiel", "Woche 1 · 12.10. – 18.10.", 1, 20, "geplant", 0, 1, None, None],
    [4, "2026-10-23", None, "Allgemein", "Lesen", None, 60, "geplant", 0, 0, "17:00", "18:00"],
    [5, "2026-10-27", 1, "Testmathematik I", "Wochentest", 1, 30, "geplant", 1, 1, None, None],
]:
    SEED.append(("INSERT INTO study_packages(id, date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, start_time, end_time, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                 p + ["2026-10-19T08:00:00"]))
SEED.append(("INSERT INTO tests(id, subject, title, duration_min, questions, created_at, submitted_at, score, max_score, module_id, week_no, auto) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
             [1, "Testmathematik I", "Wochentest Lehrwoche 1", 30, "[]", "2026-10-21T08:00:00", "2026-10-22T10:00:00", 7.5, 10, 1, 1, 1]))
for t in [
    [1, 1, "vorlesung", "f-ma-v1", None, "VL01 Einführung.pdf", 0, 45, "geplant", None, None, "09:00", "09:45"],
    [2, 1, "uebung", "f-ma-u1", None, "Blatt 1.pdf", 1, 60, "erledigt", "2026-10-20T11:00:00", None, "09:55", "10:55"],
    [3, 2, "vorlesung", "f-ph-v1", None, "Einführung Physik", 0, 45, "in_bearbeitung", None, None, "10:00", "10:45"],
    [4, 3, "uebung", "f-pg-u1", None, "Blatt 1.pdf", 0, 20, "erledigt", "2026-10-22T16:00:00", "2026-10-21", None, None],
    [5, 4, "frei", None, None, "Lesen", 0, 60, "geplant", None, None, None, None],
    [6, 5, "test", None, 1, "Gemeinsamer Wochentest Lehrwoche 1", 0, 30, "geplant", None, None, None, None],
]:
    SEED.append(("INSERT INTO study_tasks(id, package_id, type, file_id, test_id, title, sort, est_minutes, status, done_at, moved_from, start_time, end_time, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                 t + ["2026-10-19T08:00:00"]))
EVENT_COLS = "module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, date_from, date_to, attend, source, color, created_at"
for ev in [
    [1, "k-ma-vl", "Testmathematik I", "vorlesung", 0, "10:00", "11:30", "Raum A", "", "weekly", None, None, 1, "studip", None],
    [1, "k-ma-ue", "Übung zu Testmathematik I", "uebung", 1, "14:00", "15:30", "Raum B", "", "weekly", None, None, 1, "studip", None],
    [2, "k-ph", "Testphysik", "vorlesung", 2, "08:15", "09:45", "Raum C", "", "biweekly", "2026-10-14", None, 1, "manual", None],
    [None, None, "Sport (nicht besucht)", "sonstiges", 3, "18:00", "19:30", "", "", "weekly", None, None, 0, "personal", None],
    [3, "k-pg", "Programmierkurs Übung", "gruppenuebung", 4, "12:00", "13:30", "Pool 1", "", "weekly", None, None, 1, "studip", None],
    [None, None, "Sonntagstermin", "sonstiges", 6, "16:00", "17:00", "", "", "weekly", None, None, 1, "manual", ""],
]:
    SEED.append((f"INSERT INTO course_events({EVENT_COLS}) VALUES ({','.join('?' * 16)})", ev + ["2026-10-01T09:00:00"]))
for ex in [
    [1, "2026-11-02", "cancelled", None, None, None, "fällt aus"],
    [2, "2026-10-27", "moved", "2026-10-28", "10:00", "11:30", ""],
]:
    SEED.append(("INSERT INTO event_exceptions(event_id, date, type, new_date, new_start, new_end, note, created_at) VALUES (?,?,?,?,?,?,?,?)",
                 ex + ["2026-10-02T09:00:00"]))


def _ts(local: str) -> int:
    return int(datetime.fromisoformat(local).timestamp())


def _files_seed() -> list[tuple[str, list]]:
    """Dateien und Analysen (Unix-Zeiten erst hier: TZ=Europe/Berlin ist dann gesetzt)"""
    out = [("INSERT INTO files(id, course_id, name, size, mime, chdate, studip_folder, status, seen_by_user, first_seen) VALUES (?,?,?,?,?,?,?,?,?,?)",
            [fid, course, name, 1000 + i, "application/pdf", _ts(when), folder, status, 1 if status != "neu" else 0, "2026-10-22T08:00:00"])
           for i, (fid, course, name, folder, when, status) in enumerate(FILES)]
    out += [("INSERT INTO analysis(file_id, doc_type, title, topics, est_minutes, created_at) VALUES (?,?,?,?,?,?)",
             [fid, t, title, topics, est, "2026-10-22T08:00:00"]) for fid, t, title, topics, est in ANALYSIS]
    return out


def _week3_files() -> list[tuple[str, list]]:
    """Neue Dateien der Lehrwoche 3 (wie ein Abgleich am 28.10.)"""
    return [("INSERT INTO files(id, course_id, name, size, mime, chdate, studip_folder, status, seen_by_user, first_seen) VALUES (?,?,?,?,?,?,?,?,?,?)",
             [fid, course, name, 2000 + i, "application/pdf", _ts(when), folder, "neu", 0, "2026-10-28T07:00:00"])
            for i, (fid, course, name, folder, when) in enumerate([
                ("f-ma-v3", "k-ma-vl", "VL03.pdf", "Vorlesung", "2026-10-26T10:00"),
                ("f-ma-u3", "k-ma-ue", "Blatt 3.pdf", "Übungsblätter", "2026-10-27T09:00"),
                ("f-ph-v3", "k-ph", "Folien Kapitel 3.pdf", None, "2026-10-28T06:30"),
                ("f-ch-u3", "k-ch", "Übung 3.pdf", "Übungen", "2026-10-27T15:00"),
            ])]


STEPS: list[dict] = [
    {"method": "GET", "path": "/api/calendar/feasibility"},
    {"method": "GET", "path": "/api/calendar?start=2026-10-19&end=2026-10-25"},
    {"method": "GET", "path": "/api/tasks/open"},
    {"method": "GET", "path": "/api/dashboard"},
    {"method": "GET", "path": "/api/packages/1"},
    {"method": "GET", "path": "/api/packages/5"},
    # Plan ueber die Zeitumstellung: Samstag frei, Sonntag 25.10. mit Sperrzeit und Termin, 27.10. hat schon ein Paket
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-10-24", "days": 7}},
    {"method": "GET", "path": "/api/calendar?start=2026-10-24&end=2026-10-30"},
    {"method": "GET", "path": "/api/timetable/week?start=2026-10-26"},
    {"method": "GET", "path": "/api/timetable/day?date=2026-10-25"},
    {"method": "GET", "path": "/api/timetable/conflicts"},
    # Uhrzeit von Hand in die Vorlesung gelegt -> Konflikt -> Lernslots neu legen
    {"method": "PATCH", "path": "/api/packages/{pkg:2026-10-26:0}", "body": {"start_time": "10:15", "end_time": "11:15"}},
    {"method": "GET", "path": "/api/timetable/conflicts"},
    {"method": "POST", "path": "/api/timetable/reslot", "body": {}},
    {"method": "GET", "path": "/api/timetable/day?date=2026-10-26"},
    {"method": "POST", "path": "/api/timetable/reslot", "body": {"dates": ["2026-10-29"]}},
    {"method": "POST", "path": "/api/timetable/reslot"},
    # Aufgaben abhaken, bearbeiten, Fehler
    {"method": "POST", "path": "/api/tasks/{task:2026-10-26:0:0}/status", "body": {"status": "erledigt", "actual_minutes": 40, "note": "gut"}},
    {"method": "POST", "path": "/api/tasks/{task:2026-10-25:1:0}/status", "body": {"status": "in_bearbeitung"}},
    {"method": "POST", "path": "/api/tasks/1/status", "body": {"status": "kaputt"}},
    {"method": "POST", "path": "/api/tasks/999/status", "body": {"status": "erledigt"}},
    {"method": "POST", "path": "/api/tasks/2/status", "body": {"status": "geplant"}},
    {"method": "PATCH", "path": "/api/tasks/5", "body": {"title": "Lesen Kapitel 3", "est_minutes": 30, "unbekannt": 5}},
    {"method": "PATCH", "path": "/api/tasks/999", "body": {"title": "x"}},
    # Lernpakete von Hand ("+ Lernpaket", "Eigenen Lernblock anlegen", freie Zeit nutzen)
    {"method": "POST", "path": "/api/packages", "body": {"date": "2026-10-28", "module_id": 2, "title": "Physik wiederholen", "minutes": 50}},
    {"method": "PATCH", "path": "/api/packages/{new}", "body": {"start_time": "16:00", "end_time": "16:50"}},
    {"method": "GET", "path": "/api/packages/{new}"},
    {"method": "POST", "path": "/api/packages/{new}/tasks", "body": {"type": "frei", "title": "Formeln", "est_minutes": "25"}},
    {"method": "GET", "path": "/api/packages/{new}"},
    {"method": "POST", "path": "/api/packages", "name": "eigenes", "body": {"date": "2026-10-28", "subject": "Eigenes", "tasks": [
        {"type": "uebung", "file_id": "f-ma-u2", "title": "Blatt 2 rechnen", "est_minutes": 40}, {"title": "", "est_minutes": 0}]}},
    {"method": "POST", "path": "/api/packages", "name": "allgemein", "body": {"date": "2026-10-29", "module_id": 99, "title": ""}},
    {"method": "POST", "path": "/api/packages/999/tasks", "body": {"title": "x"}},
    {"method": "GET", "path": "/api/packages/999"},
    {"method": "PATCH", "path": "/api/packages/4", "body": {"date": "2026-10-30", "title": "Lesen (verschoben)", "sort": 1}},
    {"method": "PATCH", "path": "/api/packages/999", "body": {"date": "2026-10-30"}},
    {"method": "PATCH", "path": "/api/packages/4", "body": {"start_time": "kaputt", "title": "nicht gespeichert"}},
    {"method": "PATCH", "path": "/api/packages/4", "body": {"start_time": "19:30"}},
    {"method": "GET", "path": "/api/timetable/day?date=2026-10-30"},
    # Paket mit zwei Aufgaben passt nicht vor die Vorlesung am Montag: am Stueck danach, kein Konflikt; ein kurzes
    # Paket nutzt die Luecke davor (Korrektur vom 26.10.2026; vorher 08:00-14:00 ueber der Vorlesung)
    {"method": "POST", "path": "/api/packages", "body": {"date": "2026-11-09", "module_id": 1, "title": "Zwei Stunden", "tasks": [
        {"type": "uebung", "title": "Teil A", "est_minutes": 60}, {"type": "uebung", "title": "Teil B", "est_minutes": 60}]}},
    {"method": "POST", "path": "/api/packages", "body": {"date": "2026-11-09", "title": "Kurz", "minutes": 30}},
    {"method": "POST", "path": "/api/timetable/reslot", "body": {"dates": ["2026-11-09"]}},
    {"method": "GET", "path": "/api/timetable/day?date=2026-11-09"},
    {"method": "GET", "path": "/api/timetable/conflicts?days=20"},
    # Nachholen, Neu einplanen, Woche retten
    {"method": "POST", "path": "/api/calendar/suggest", "body": {}},
    {"method": "POST", "path": "/api/calendar/suggest", "body": {"package_id": 1}},
    {"method": "POST", "path": "/api/calendar/suggest", "body": {"task_ids": [3, 2]}},
    {"method": "POST", "path": "/api/calendar/suggest", "body": {"horizon": 2}},
    {"method": "POST", "path": "/api/calendar/suggest", "body": {"rescue": True}, "name": "rescue"},
    {"method": "POST", "path": "/api/calendar/apply", "body": "FROM:rescue"},
    {"method": "POST", "path": "/api/calendar/apply", "body": {"moves": [{"task_id": 6, "to": None}, {"task_id": 999, "to": "2026-10-28"}, {"task_id": 2, "to": "2026-10-28"}]}},
    {"method": "GET", "path": "/api/calendar?start=2026-10-20&end=2026-10-31"},
    {"method": "GET", "path": "/api/packages/1"},
    {"method": "POST", "path": "/api/tasks/skip", "body": {"task_ids": [999]}},
    {"method": "POST", "path": "/api/tasks/skip", "body": {"task_ids": ["{task:@allgemein:0}"]}},
    {"method": "POST", "path": "/api/tasks/skip", "body": {"task_ids": []}},
    {"method": "GET", "path": "/api/tasks/history?limit=12"},
    {"method": "DELETE", "path": "/api/tasks/{task:@eigenes:1}"},
    {"method": "DELETE", "path": "/api/packages/{@allgemein}"},
    {"method": "DELETE", "path": "/api/packages/999"},
    {"method": "DELETE", "path": "/api/tasks/999"},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-10-26", "days": 7, "replace": True}},
    {"method": "GET", "path": "/api/calendar?start=2026-10-26&end=2026-11-01"},
    {"method": "GET", "path": "/api/dashboard"},
    {"method": "GET", "path": "/api/modules"},
    {"method": "GET", "path": "/api/modules/1"},
    {"method": "GET", "path": "/api/calendar?start=2026-11-01&end=2026-12-20"},
    {"method": "GET", "path": "/api/calendar?start=2026-11-02&end=2026-11-01"},
    # Mittwoch, 28.10.: Pakete vom 26./27. sind nachzuholen, neue Dateien der Lehrwoche 3
    {"now": "2026-10-28T07:45:00", "sql": "WEEK3"},
    {"method": "GET", "path": "/api/dashboard"},
    {"method": "GET", "path": "/api/calendar/feasibility"},
    {"method": "POST", "path": "/api/calendar/suggest", "body": {"rescue": True}},
    # keine Lerntage: nichts zu verteilen, nichts zu planen
    {"method": "PUT", "path": "/api/settings", "body": {"free_days": [0, 1, 2, 3, 4, 5, 6]}},
    {"method": "POST", "path": "/api/calendar/suggest", "body": {"rescue": True}},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-10-28", "days": 3}},
    # mit Wochentest und Wiederholung (am PC mit KI waehlbar), drei Faecher in 90 Minuten: Hinweis der Machbarkeit,
    # Physik ohne Wochentest, Programmierkurs mit eigener Testdauer
    {"method": "PUT", "path": "/api/settings", "body": {"free_days": [5], "tests_per_subject": "2", "subjects_per_day": "3", "hours_per_day": "1.5"}},
    {"method": "GET", "path": "/api/calendar/feasibility"},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-10-28", "days": 14}},
    {"method": "GET", "path": "/api/calendar?start=2026-10-28&end=2026-11-03"},
    {"method": "GET", "path": "/api/tasks/open"},
    {"method": "PUT", "path": "/api/settings", "body": {"tests_per_subject": "0", "subjects_per_day": "2", "hours_per_day": "4"}},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-11-16", "days": 28}},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"days": 2}},
    {"method": "GET", "path": "/api/dashboard"},
    {"method": "GET", "path": "/api/modules"},
]

# Korrekturen nach der Pruefung von S6 (26.10.2026): eigene Datenbank mit demselben Seed, Mittwoch 28.10.2026. An
# diesem Tag liegen Physik 08:15-09:45 und die verlegte Uebung 10:00-11:30 (frei erst ab 11:50).
FIXES_NOW = "2026-10-28T09:00:00"
FIXES: list[dict] = [
    # "Lerneinheit automatisch einplanen" im freien Fenster: ein Paket genau in dieses Fenster, auch an einem Tag mit
    # Paket (die Planung fuer den Tag uebergeht ihn weiter); zu kleines Fenster; falsche Uhrzeiten 400
    {"method": "POST", "path": "/api/packages", "name": "eigenes", "body": {"date": "2026-10-29", "title": "Eigenes Kapitel", "minutes": 30}},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-10-29", "days": 1}},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-10-29", "window_start": "14:00", "window_end": "15:30"}},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-10-29", "window_start": "19:00", "window_end": "19:10"}},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-10-29", "window_start": "15:30", "window_end": "15:00"}},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"window_start": "kaputt", "window_end": "15:00"}},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"window_end": "15:00"}},
    {"method": "GET", "path": "/api/calendar?start=2026-10-29&end=2026-10-29"},
    # "Plan erstellen" ab Montag: Montag und Dienstag liegen zurueck und werden nicht geplant
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-10-26", "days": 7}},
    {"method": "GET", "path": "/api/calendar?start=2026-10-26&end=2026-11-01"},
    # Uhrzeit von Hand: das Paket endet nie vor seiner letzten Aufgabe (Dialog: Ende = Beginn + geplante Dauer)
    {"method": "POST", "path": "/api/packages", "name": "zwei", "body": {"date": "2026-11-02", "title": "Zwei Aufgaben", "tasks": [
        {"type": "frei", "title": "Lesen", "est_minutes": 45}, {"type": "frei", "title": "Rechnen", "est_minutes": 30}]}},
    {"method": "POST", "path": "/api/timetable/reslot", "body": {"dates": ["2026-11-02"], "only_unset": True}},
    {"method": "PATCH", "path": "/api/packages/{@zwei}", "body": {"start_time": "16:00", "end_time": "17:15"}},
    {"method": "PATCH", "path": "/api/packages/{@zwei}", "body": {"start_time": "10:30"}},
    {"method": "GET", "path": "/api/packages/{@zwei}"},
    # Verschieben: dieselbe Uhrzeit, wenn sie am neuen Tag frei ist (Donnerstag), sonst ein freies Fenster (Mittwoch:
    # 10:30 liegt in der Uebung); ohne Uhrzeit bleibt es ohne
    {"method": "PATCH", "path": "/api/packages/{@zwei}", "body": {"date": "2026-11-05"}},
    {"method": "PATCH", "path": "/api/packages/{@zwei}", "body": {"date": "2026-10-28"}},
    {"method": "GET", "path": "/api/packages/{@zwei}"},
    {"method": "PATCH", "path": "/api/packages/{@zwei}", "body": {"date": "2026-11-06", "start_time": "17:00"}},
    {"method": "PATCH", "path": "/api/packages/{@eigenes}", "body": {"date": "2026-11-03"}},
    {"method": "GET", "path": "/api/timetable/conflicts"},
    # "Uhrzeiten vergeben" (only_unset) behaelt Uhrzeiten von Hand, "Lernslots neu legen" legt alles neu
    {"method": "POST", "path": "/api/packages", "name": "lose", "body": {"date": "2026-11-06", "title": "Ohne Uhrzeit", "minutes": 30}},
    {"method": "POST", "path": "/api/timetable/reslot", "body": {"dates": ["2026-11-06"], "only_unset": True}},
    {"method": "GET", "path": "/api/timetable/day?date=2026-11-06"},
    {"method": "POST", "path": "/api/timetable/reslot", "body": {"dates": ["2026-11-06"]}},
    {"method": "GET", "path": "/api/timetable/day?date=2026-11-06"},
    # leeres Paket: keine Uhrzeit mehr, sein Fenster ist frei
    {"method": "POST", "path": "/api/calendar/apply", "body": {"moves": [{"task_id": "{task:@lose:0}", "to": "2026-11-09"}]}},
    {"method": "GET", "path": "/api/packages/{@lose}"},
    {"method": "GET", "path": "/api/timetable/day?date=2026-11-06"},
    # Ersetzen: eigene Pakete, neu eingeplante Aufgaben und Tage mit begonnenem Paket bleiben, leere Pakete gehen;
    # gibt es nichts zu planen, wird nichts geloescht
    {"method": "POST", "path": "/api/calendar/apply", "body": {"moves": [{"task_id": "{task:2026-10-30:0:0}", "to": "2026-11-01"}]}},
    {"method": "POST", "path": "/api/tasks/{task:2026-10-28:0:0}/status", "body": {"status": "erledigt"}},
    {"method": "POST", "path": "/api/calendar/apply", "body": {"moves": [{"task_id": "{task:2026-10-30:1:0}", "to": "2026-11-12"}]}},
    {"now": FIXES_NOW, "sql": ["UPDATE modules SET active=0"]},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-10-28", "days": 7, "replace": True}},
    {"now": FIXES_NOW, "sql": ["UPDATE modules SET active=1 WHERE name != 'Altmodul'"]},
    {"method": "POST", "path": "/api/calendar/generate", "body": {"start": "2026-10-28", "days": 7, "replace": True}},
    {"method": "GET", "path": "/api/calendar?start=2026-10-28&end=2026-11-03"},
    {"method": "GET", "path": "/api/dashboard"},
]

# study._derive_status: alle Teilmengen der Aufgabenstatus, je vergangen und nicht
DERIVE_STATUSES = ["geplant", "in_bearbeitung", "erledigt", "nachholen", "uebersprungen", "verschoben"]


def frozen(src: SchemaSource):
    """Uhr einfrieren und weiterstellbar machen: date.today() in server/study, study.today(), db.now_iso() und
    datetime.now() in server.py lesen CLOCK["now"]."""
    src.freeze(lambda: date.fromisoformat(CLOCK["now"][:10]), lambda: CLOCK["now"], lambda: datetime.fromisoformat(CLOCK["now"]))


def resolve(value, path: Path, names: dict):
    """Platzhalter {pkg:DATUM:N}, {task:DATUM:N:M}, {new} und "FROM:<name>" aufloesen"""
    if isinstance(value, dict):
        return {k: resolve(v, path, names) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v, path, names) for v in value]
    if not isinstance(value, str):
        return value
    if value.startswith("FROM:"):
        return {"moves": names[value[5:]]["moves"]}
    conn = sqlite3.connect(path)

    def one(m: re.Match) -> str:
        kind, _, rest = m.group(1).partition(":")
        if kind == "new":
            return str(conn.execute("SELECT MAX(id) FROM study_packages").fetchone()[0])
        if kind.startswith("@"):
            return str(names[kind[1:]]["id"])
        parts = rest.split(":")
        if parts[0].startswith("@"):
            pid, parts = names[parts[0][1:]]["id"], [None, None] + parts[1:]
        else:
            pid = [r[0] for r in conn.execute("SELECT id FROM study_packages WHERE date=? ORDER BY id", (parts[0],))][int(parts[1])]
        if kind == "pkg":
            return str(pid)
        tasks = [r[0] for r in conn.execute("SELECT id FROM study_tasks WHERE package_id=? ORDER BY sort, id", (pid,))]
        return str(tasks[int(parts[2])])

    try:
        out = re.sub(r"\{((?:pkg|task|new|@)[^}]*)\}", one, value)
    finally:
        conn.close()
    if out != value and re.fullmatch(r"\{[^}]*\}", value):
        return int(out)                       # ganzer Wert: ID als Zahl
    return out


def tables(path: Path) -> dict:
    q = {t: f"SELECT * FROM {t} ORDER BY id" for t in ("study_packages", "study_tasks", "task_history", "modules")}
    return dump_tables(path, q | {"files": "SELECT id, status, seen_by_user FROM files ORDER BY id"})


def run(src: SchemaSource, gen, name: str, now: str, seed: list, plan: list[dict]) -> tuple[list[dict], dict]:
    """Frische Datenbank mit Seed, Uhr auf `now`, dann die Schritte; liefert die Schritte mit Antworten und die
    Tabellen danach. Schritte mit "now" stellen die Uhr und fuehren SQL aus ("WEEK3" oder eine Liste)."""
    from app import server
    CLOCK["now"] = now
    path = src.fresh_db(name)
    with src.db.cursor() as conn:
        for sql, params in seed:
            conn.execute(sql, params)
    steps, names = [], {}
    for s in plan:
        if "now" in s:
            CLOCK["now"] = s["now"]
            sql = _week3_files() if s["sql"] == "WEEK3" else [(q, []) for q in s["sql"]]
            with src.db.cursor() as conn:
                for q, params in sql:
                    conn.execute(q, params)
            steps.append({"now": s["now"], "sql": [{"sql": q, "params": p} for q, p in sql]})
            continue
        p = resolve(s["path"], path, names)
        body = resolve(s["body"], path, names) if "body" in s else None
        status, value = gen.asgi(server.app, s["method"], p, body)
        assert status != 500, (s, value)
        if s.get("name"):
            names[s["name"]] = value
        step = {"method": s["method"], "path": p, "status": status, "response": value}
        if "body" in s:
            step["body"] = body
        steps.append(step)
    return steps, tables(path)


def main() -> int:
    with berlin_time():                                 # datetime.fromtimestamp wie auf dem PC-Server in Berlin
        return build("--check" in sys.argv[1:])


def build(check: bool) -> int:
    src = SchemaSource()
    try:
        seed = SEED + _files_seed()
        from app import study
        frozen(src)
        spec = importlib.util.spec_from_file_location("gen_local_backend_fixture", Path(__file__).with_name("gen-local-backend-fixture.py"))
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        steps, after = run(src, gen, "lernplan", START, seed, STEPS)
        fix_steps, fix_after = run(src, gen, "nachgebessert", FIXES_NOW, seed, FIXES)
        derive = [{"statuses": list(c), "past": past, "status": study._derive_status(list(c), past)}
                  for n in range(len(DERIVE_STATUSES) + 1) for c in itertools.combinations(DERIVE_STATUSES, n) for past in (False, True)]
    finally:
        src.cleanup()
    out = {"generator": "tools/gen-study-fixture.py", "now": START, "timezone": "Europe/Berlin",
           "seed": [{"sql": q, "params": p} for q, p in seed], "steps": steps, "tables_after": after,
           "scenarios": [{"name": "nachgebessert", "now": FIXES_NOW, "steps": fix_steps, "tables_after": fix_after}],
           "derive_status": derive}
    out = without_sync(out)                       # G2-Spalten: siehe schema_source
    ok = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())
