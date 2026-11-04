"""Erzeugt packages/shared-contracts/fixtures/exams/exams.json: kommende Klausuren aus allen Quellen (app/exams.py,
04.11.2026) mit der Python-Referenz auf einer erfundenen Datenbank und eingefrorener Uhr (Mittwoch, 04.11.2026,
10:00 Europe/Berlin). Der Swift-Kern (ExamsTests) legt dieselbe Datenbank an, stellt dieselben Anfragen und vergleicht
Antworten und Tabellen exakt.

Inhalt:
- seed: SQL mit Parametern (Module, Kurse, Stud.IP-Termine mit Art, Ankuendigungen, Nachrichten, QIS, Fristen)
- steps: Anfragen an GET /api/exams/upcoming und PATCH /api/modules/{id} sowie SQL-Schritte (Stud.IP verlegt die
  Klausur), je mit Status und Antwort
- tables_after: modules (id, name, exam_date) und settings.exam_dates_auto
- exam_dates: exams.exam_dates fuer erfundene Saetze (Satzteil, Satz, Betreff, Anmeldung, Einsicht, Verlegung, Ausfall)
- chips: studip_extras.chips (Pruefungen immer zuerst, die Grenze von zwei gilt nur fuer die anderen Arten)
- events: studip_sync.event_from_studip fuer Termine mit und ohne `categories`

Aufruf im Projektordner: python tools/gen-exams-fixture.py [--check]
"""
from __future__ import annotations

import importlib.util
import json
import sys
from datetime import date, datetime
from pathlib import Path

from schema_source import ROOT, SchemaSource, dump_tables, without_sync, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "exams" / "exams.json"
TODAY = date(2026, 11, 4)
NOW = "2026-11-04T10:00:00"

SEED_SQL = [
    ("INSERT INTO modules(id, name, color, exam_date, sort, created_at) VALUES (?,?,?,?,?,?)", [1, "Analysis I", "#4f5bd5", None, 1, "2026-10-01T08:00:00"]),
    ("INSERT INTO modules(id, name, color, exam_date, sort, created_at) VALUES (?,?,?,?,?,?)", [2, "Lineare Algebra", "#e8590c", "2027-02-20", 2, "2026-10-01T08:00:00"]),
    ("INSERT INTO modules(id, name, color, exam_date, sort, created_at) VALUES (?,?,?,?,?,?)", [3, "Programmieren", "#2b8a3e", None, 3, "2026-10-01T08:00:00"]),
    ("INSERT INTO modules(id, name, color, exam_date, sort, created_at) VALUES (?,?,?,?,?,?)", [4, "Statistik", "#c2255c", "", 4, "2026-10-01T08:00:00"]),
    ("INSERT INTO modules(id, name, color, exam_date, sort, created_at) VALUES (?,?,?,?,?,?)", [5, "Physik", "#1971c2", None, 5, "2026-10-01T08:00:00"]),
    # Physik: Klausurtermin war automatisch uebernommen und wurde vom Nutzer geleert
    ("INSERT INTO settings(key, value) VALUES (?, ?)", ["exam_dates_auto", '{"5": "2027-02-10"}']),
    *[("INSERT INTO courses(id, title, kind, module_id, active, created_at) VALUES (?,?,?,?,?,?)", [cid, title, kind, mid, 1, "2026-10-01T08:00:00"])
      for cid, title, kind, mid in [("c-ana", "Analysis I", "vorlesung", 1), ("c-la", "Lineare Algebra", "vorlesung", 2),
                                    ("c-prog", "Programmieren", "vorlesung", 3), ("c-stat", "Statistik", "vorlesung", 4),
                                    ("c-phy", "Physik", "vorlesung", 5), ("c-chem", "Chemie für Ingenieure", "sonstiges", None),
                                    ("lw-77", "Programmieren (Learnweb)", "vorlesung", 3)]],
    *[("INSERT INTO studip_events(id, course_id, title, start, end, room, description, cancelled, category, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
       [eid, cid, title, st, en, room, desc, canc, cat, "2026-11-03T08:00:00"])
      for eid, cid, title, st, en, room, desc, canc, cat in [
          ("e1", "c-ana", "Klausur", "2027-02-12T09:00:00", "2027-02-12T11:00:00", "Hörsaal F 303", "", 0, "Klausur"),
          ("e2", "c-ana", "Klausur", "2027-02-12T09:00:00", "2027-02-12T11:00:00", "Hörsaal F 102", "", 0, "Klausur"),
          ("e3", "c-ana", "Sitzung 5", "2026-11-10T10:00:00", "2026-11-10T11:30:00", "Hörsaal F 303", "Folgen", 0, "Sitzung"),
          ("e4", "c-prog", "Sitzung 14", "2027-02-18T14:00:00", "2027-02-18T16:00:00", "Raum 101", "Klausur", 0, "Sitzung"),
          ("e5", "c-prog", "Sitzung 13", "2027-01-20T14:00:00", "2027-01-20T16:00:00", "Raum 101", "Klausurvorbereitung", 0, "Sitzung"),
          ("e6", "c-stat", "Klausur", "2027-02-01T08:00:00", "2027-02-01T10:00:00", "", "", 1, "Klausur"),
          ("e7", "c-ana", "Klausur", "2026-10-01T09:00:00", "2026-10-01T11:00:00", "", "", 0, "Klausur"),
          ("e8", "c-chem", "Termin", "2027-03-01T08:00:00", "2027-03-01T10:00:00", "Chemiehörsaal 2", "", 0, "Prüfung"),
          ("e9", "c-phy", "Klausur", "2027-02-10T12:00:00", "2027-02-10T14:00:00", "", "", 0, "Klausur"),
          ("e10", "c-la", "Sitzung", "2026-11-11T08:00:00", "2026-11-11T09:30:00", "", "", 0, None),
      ]],
    *[("INSERT INTO announcements(id, source, course_id, title, text, author, posted_at, url, discussion, dates, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
       [aid, src, cid, title, text, "", posted, url, None, "[]", "2026-11-03T08:00:00"])
      for aid, src, cid, title, text, posted, url in [
          ("sp-news-a1", "studip", "c-stat", "Klausurtermin",
           "Die Klausur findet am 15.02.2027 um 10 Uhr im Hörsaal E 214 statt. Die Anmeldung ist bis zum 01.02.2027 möglich.",
           "2026-11-02T09:00:00+01:00", "https://studip.test/dispatch.php/course/overview?cid=c-stat"),
          ("lw-post-a2", "learnweb", "c-ana", "Infos zur Klausur", "Die Klausur ist am 12.02.2027 um 9:15 Uhr. Einsicht am 20.02.2027.",
           "2026-11-01T12:00:00", "https://learnweb.test/mod/forum/discuss.php?d=2"),
          ("sp-news-a3", "studip", "c-la", "Probeklausur", "Die Probeklausur schreiben wir am 20.11. in der Übung.",
           "2026-11-03T09:00:00+01:00", None),
          ("sp-news-a4", "studip", None, "Prüfungszeitraum", "Die Klausur Mathematik findet am 10.02.2027 statt.",
           "2026-11-03T09:00:00+01:00", None),
          ("sp-news-a5", "studip", "c-prog", "Verlegung", "Die Klausur wird vom 18.02.2027 auf den 25.02.2027 verschoben.",
           "2026-11-03T10:00:00+01:00", None),
          ("sp-news-a6", "studip", "c-la", "Klausur", "Termin: 20.02.2027, Raum 1101-E214.", "2026-10-20T10:00:00+02:00", None),
      ]],
    *[("INSERT INTO studip_messages(id, sender, subject, preview, sent_at, url, dates, fetched_at) VALUES (?,?,?,?,?,?,?,?)",
       [mid, "Lehrende", subj, text, sent, "https://studip.test/dispatch.php/messages/overview", "[]", "2026-11-03T08:00:00"])
      for mid, subj, text, sent in [
          ("sp-msg-m1", "Statistik: Nachklausur", "Liebe Studierende,\ndie Nachklausur findet am 30.03.2027 um 14 Uhr statt.", "2026-11-03T08:00:00+01:00"),
          ("sp-msg-m2", "Termine", "Am 12.12. ist die Weihnachtsfeier.", "2026-11-02T08:00:00+01:00"),
          ("sp-msg-m3", "Wichtig", "Die Klausur am 01.04.2027 um 8 Uhr ist Pflicht.", "2026-11-02T07:00:00+01:00"),
      ]],
    *[("INSERT INTO grades(pruefungsnr, text, semester, note, status, datum, fetched_at) VALUES (?,?,?,?,?,?,?)", row)
      for row in [["1001", "Lineare Algebra", "WiSe 26/27", None, "AN", "20.02.2027", "2026-11-03T08:00:00"],
                  ["1002", "Analysis I", "SoSe 26", "1,7", "BE", "01.10.2026", "2026-11-03T08:00:00"],
                  ["1003", "Experimentalphysik", "WiSe 26/27", None, "angemeldet", "2027-03-05", "2026-11-03T08:00:00"]]],
    *[("INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)", row)
      for row in [["lw-ev-1", "learnweb", "lw-77", "E-Klausur Programmieren", None, "test_beginn", "quiz", "2027-02-05T10:00", "https://learnweb.test/mod/quiz/view.php?id=1", 0, "2026-11-03T08:00:00"],
                  ["lw-ev-2", "learnweb", "lw-77", "Abgabe Blatt 5", None, "abgabe", "assign", "2026-11-20T23:59", None, 0, "2026-11-03T08:00:00"]]],
]

STEPS = [
    {"method": "GET", "path": "/api/exams/upcoming"},
    {"method": "GET", "path": "/api/exams/upcoming"},
    {"method": "GET", "path": "/api/exams/upcoming?module_id=1"},
    {"method": "GET", "path": "/api/exams/upcoming?module_id=99"},
    # Stud.IP verlegt die Analysis-Klausur, die Ankuendigung mit dem alten Tag ist weg: der automatisch uebernommene
    # Termin folgt
    {"sql": [["UPDATE studip_events SET start='2027-02-13T09:00:00', end='2027-02-13T11:00:00' WHERE id IN ('e1', 'e2')", []],
             ["DELETE FROM announcements WHERE id='lw-post-a2'", []]]},
    {"method": "GET", "path": "/api/exams/upcoming"},
    # eigener Termin fuer Statistik: bleibt, die Quellen stehen daneben
    {"method": "PATCH", "path": "/api/modules/4", "body": {"exam_date": "2027-02-16"}},
    {"method": "GET", "path": "/api/exams/upcoming"},
    # automatisch uebernommenen Termin geleert: derselbe Tag kommt nicht wieder
    {"method": "PATCH", "path": "/api/modules/3", "body": {"exam_date": None}},
    {"method": "GET", "path": "/api/exams/upcoming?module_id=3"},
]

EXAM_TEXTS = [
    ("Klausurtermin", "Die Klausur findet am 12.02.2027 um 9 Uhr im Hörsaal F 303 statt, die Anmeldung ist bis 01.02. möglich."),
    ("Info", "Klausur: Do., 11.02.2027, 10 Uhr, Raum E214. Einsicht am 20.02."),
    ("Verlegung", "Die Klausur wird vom 10.02. auf den 15.02.2027 verschoben."),
    ("Klausur", "Termin: 12.02.2027, 10:00, HS 1"),
    ("Klausur", "Termine: 12.02.2027 und 19.02.2027."),
    ("Probeklausur", "Die Probeklausur schreiben wir am 20.11."),
    ("Ausfall", "Die Klausur am 12.02. entfällt."),
    ("Nachklausur Mathe", "Nachklausur am 1. April 2027 um 14 Uhr"),
    ("Prüfung", "Die mündlichen Prüfungen finden am 3. März 2027 statt."),
    ("Anmeldung", "Bitte meldet euch bis zum 15.01. zur Klausur an."),
    ("Ergebnisse", "Die Klausurergebnisse und die Klausureinsicht am 01.03.2027."),
    ("Final exam", "The final exam takes place on 12.02.2027 at 10 Uhr."),
    ("Klausurvorbereitung", "Fragestunde zur Klausur am 05.02.2027."),
    ("", "Prüfungstermin ist der 22.02.2027, Prüfungsdatum bestätigt."),
    ("Klausuren", "Die Klausuren sind am 12.02.2027 und am 26.03.2027 (Nachklausur)."),
    ("Raum", "Die Klausur ist am 12.02.2027 im Seminarraum 3."),
]
POSTED = date(2026, 11, 2)

CHIP_CASES = [
    [{"date": "2026-11-10", "kind": "frist"}, {"date": "2026-11-11", "kind": "ausfall"}, {"date": "2026-11-12", "kind": "verlegt"},
     {"date": "2027-02-12", "kind": "pruefung"}, {"date": "2027-03-01", "kind": "pruefung"}],
    [{"date": "2026-11-01", "kind": "pruefung"}, {"date": "2026-11-10", "kind": "pruefung"}, {"date": "2026-11-10", "kind": "pruefung", "time": "10:00"},
     {"date": "2026-11-12", "kind": "raum"}],
    [{"date": "2026-11-10", "kind": "frist"}, {"date": "2026-11-12", "kind": "frist"}, {"date": "2026-11-13", "kind": "frist"}],
    [],
    "kaputt",
    [{"date": 5, "kind": "pruefung"}, {"kind": "frist"}, "x", {"date": "2026-12-01", "kind": "pruefung"}],
]

EVENTS = [
    {"id": "x1", "attributes": {"title": "Klausur", "start": "2027-02-12T09:00:00+01:00", "end": "2027-02-12T11:00:00+01:00",
                                "categories": "Klausur", "location": "Hörsaal F 303, Gebäude 1", "is-cancelled": False}},
    {"id": "x2", "attributes": {"title": "Sitzung 1", "start": "2026-10-12T10:00:00+02:00", "end": "2026-10-12T11:30:00+02:00",
                                "type": "1", "categories": "  Sitzung  "}},
    {"id": "x3", "attributes": {"title": "Ohne Art", "start": "2026-10-13T10:00:00+02:00", "end": "2026-10-13T11:30:00+02:00", "categories": 3}},
    {"id": "x4", "attributes": {"title": "Null", "start": "2026-10-14T10:00:00+02:00", "end": "2026-10-14T11:30:00+02:00", "categories": None}},
]


def build(check: bool) -> int:
    src = SchemaSource()
    try:
        from app import exams, server, studip_extras, studip_sync

        src.freeze(lambda: TODAY, lambda: NOW, lambda: datetime.fromisoformat(NOW))
        spec = importlib.util.spec_from_file_location("gen_local_backend_fixture", Path(__file__).with_name("gen-local-backend-fixture.py"))
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)

        path = src.fresh_db("klausuren")
        seed = [{"sql": studip_extras.MESSAGES_TABLE, "params": []}] + [{"sql": sql, "params": params} for sql, params in SEED_SQL]
        with src.db.cursor() as conn:
            for s in seed:
                conn.execute(s["sql"], s["params"])
        steps = []
        for s in STEPS:
            if "sql" in s:
                with src.db.cursor() as conn:
                    for sql, params in s["sql"]:
                        conn.execute(sql, params)
                steps.append({"sql": [{"sql": q, "params": p} for q, p in s["sql"]]})
                continue
            status, value = gen.asgi(server.app, s["method"], s["path"], s.get("body"))
            step = {"method": s["method"], "path": s["path"], "status": status, "response": without_sync(value)}
            if "body" in s:
                step["body"] = s["body"]
            steps.append(step)
        after = dump_tables(path, {"modules": "SELECT id, name, exam_date FROM modules ORDER BY id",
                                   "settings": "SELECT key, value FROM settings WHERE key='exam_dates_auto'"})
        texts = [{"title": t, "text": x, "posted": POSTED.isoformat(), "dates": exams.exam_dates(t, x, POSTED)} for t, x in EXAM_TEXTS]
        chips = [{"dates": c, "today": "2026-11-04", "chips": studip_extras.chips(c, "2026-11-04")} for c in CHIP_CASES]
        events = [{"event": e, "parsed": studip_sync.event_from_studip(e, "c1")} for e in EVENTS]
        out = {"generator": "tools/gen-exams-fixture.py", "today": TODAY.isoformat(), "now": NOW, "seed": seed, "steps": steps,
               "tables_after": after, "exam_dates": texts, "chips": chips, "events": events}
        text = json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
        return 0 if write_or_check(OUT, text, check) or not check else 1
    finally:
        src.cleanup()


if __name__ == "__main__":
    sys.exit(build("--check" in sys.argv[1:]))
