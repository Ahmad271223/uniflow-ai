"""Erzeugt packages/shared-contracts/fixtures/demo/demo.json: die Demo-Inhalte fuer die App-Pruefung (app/demo.py) aus
der Python-Referenz. Der Swift-Kern (DemoContentTests) legt dieselben Inhalte im lokalen Backend an und vergleicht
Antworten, Tabellen und PDF-Bytes; so sind die Inhalte auf dem iPad dieselben wie am PC.

Inhalt:
- pdfs: je Demo-Datei die Bytes von `demo.pdf_bytes` (Base64, SHA-256, Groesse) und der Text, den pypdf liest; dazu
  Grenzfaelle des PDF-Bauers (Klammern, Rueckstrich, Umlaute, Zeichen ausserhalb von cp1252)
- constants: Modul, Fach, Farbe, Kurse, Termine, Dateien wie in app/demo.py
- scenarios: Folgen von Anfragen an GET/POST /api/demo mit eingefrorener Uhr (Ortszeit Berlin; `date.today()` in
  app/demo.py, `db.now_iso()`), gesendete Bytes (`raw`), Status und Antwort, an Merkpunkten die Tabellen (Pfade der
  Dateien relativ zum Datenordner) und die Dateien unter `files/`. "leer": anlegen, erneut anlegen (frisch, keine
  Doppel), entfernen, Ruempfe wie FastAPI (`Body(default={})`, Wahrheitswert wie Python). "eigene-daten": erfundene
  Daten des Nutzers (Modul, Kurs, Datei, Termine, Lernpaket, Learnweb-Frist, Stud.IP-Ankuendigung, Notizen, Einstellung),
  danach die Demo, Spuren des Nutzers an der Demo (Notizen, Version, Seitentext, Ausnahme und Notiz am Termin, Analyse)
  per SQL und das Entfernen: die Daten des Nutzers bleiben unveraendert.
- dates: Datumslogik "diese Woche" an mehreren Tagen (Montag, Sonntag, Jahreswechsel, Schaltjahr, beide
  Zeitumstellungen beim Aenderungsdatum heute - 3 Tage): Lernpakete, Frist, Ankuendigung (Text und Termin), chdate.

Der Server laeuft nur gegen Dateien in einem Temp-Ordner (tools/schema_source.py), nie gegen data/.
Aufruf im Projektordner: python tools/gen-demo-fixture.py [--check]
"""
from __future__ import annotations

import base64
import hashlib
import importlib.util
import io
import json
import os
import sys
from datetime import date, datetime
from pathlib import Path

from schema_source import ROOT, SchemaSource, berlin_time, without_sync, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "demo" / "demo.json"

# Tabellen an den Merkpunkten (Reihenfolge fest)
TABLES = {
    "modules": "SELECT * FROM modules ORDER BY id",
    "courses": "SELECT * FROM courses ORDER BY id",
    "files": "SELECT * FROM files ORDER BY id",
    "analysis": "SELECT * FROM analysis ORDER BY file_id",
    "annotations": "SELECT * FROM annotations ORDER BY file_id",
    "annotation_versions": "SELECT * FROM annotation_versions ORDER BY id",
    "flashcards": "SELECT * FROM flashcards ORDER BY id",
    "course_events": "SELECT * FROM course_events ORDER BY id",
    "event_exceptions": "SELECT * FROM event_exceptions ORDER BY id",
    "event_notes": "SELECT * FROM event_notes ORDER BY event_id",
    "study_packages": "SELECT * FROM study_packages ORDER BY id",
    "study_tasks": "SELECT * FROM study_tasks ORDER BY id",
    "deadlines": "SELECT * FROM deadlines ORDER BY id",
    "announcements": "SELECT * FROM announcements ORDER BY id",
    "page_texts": "SELECT file_id, page, text FROM page_texts ORDER BY file_id, page",
    "settings": "SELECT key, value FROM settings ORDER BY key",
}

# Grenzfaelle des PDF-Bauers: Klammern und Rueckstrich maskiert, Umlaute in WinAnsi, Zeichen ausserhalb von cp1252
# werden "?" (encode "replace"), ein zerlegter Umlaut zwei Zeichen
PDF_CASES = [
    [["Titel (mit) Klammern", ["Zeile \\ eins", "Umlaute äöü ß ÄÖÜ", "Euro € – „Anführung“ … •"]]],
    [["Nicht in cp1252: Ω 😀 \u0081", ["zerlegt: ä ö", "Tab\tund ) ( \\) Ende"]], ["Zweite Seite", []]],
]

# Erfundene Daten des Nutzers (Szenario "eigene-daten"); Zeitstempel fest
USER_SEED = [
    ("INSERT INTO modules(name, semester, color, sort, created_at) VALUES (?,?,?,?,?)",
     ["Lineare Algebra Test", "WiSe 2026/27", "#2563eb", 1, "2026-10-01T09:00:00"]),
    ("INSERT INTO courses(id, title, number, semester, subject, kind, active, created_at, module_id) VALUES (?,?,?,?,?,?,?,?,?)",
     ["k-la", "Lineare Algebra Test", "LA-1", "WiSe 2026/27", "Lineare Algebra Test", "vorlesung", 1, "2026-10-01T09:00:00", 1]),
    ("INSERT INTO files(id, course_id, name, status, kind, first_seen, title) VALUES (?,?,?,?,?,?,?)",
     ["f-la1", "k-la", "LA_Vorlesung_01.pdf", "neu", "pdf", "2026-10-20T08:00:00", "LA Vorlesung 01"]),
    ("INSERT INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,?)",
     ["f-la1", '{"version": 2, "pages": {"1": {"objects": []}}}', "2026-10-21T10:00:00", 1]),
    ("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES (?,?,?,?)",
     ["f-la1", 1, '{"version": 2, "pages": {}}', "2026-10-21T10:00:00"]),
    ("INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due) VALUES (?,?,?,?,?,?,?)",
     ["f-la1", "Lineare Algebra Test", "Was ist eine Basis?", "Erzeugendensystem", "2026-10-21T10:00:00", 1, "2026-10-22"]),
    ("INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, rrule, attend, source, created_at) "
     "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
     [1, "k-la", "Lineare Algebra Test – Vorlesung", "vorlesung", 1, "10:00", "12:00", "Raum 1", "weekly", 1, "studip", "2026-10-01T09:00:00"]),
    ("INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, rrule, attend, source, created_at) "
     "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
     [None, None, "Sport", "persoenlich", 4, "18:00", "19:30", None, "weekly", 1, "manual", "2026-10-01T09:00:00"]),
    ("INSERT INTO event_exceptions(event_id, date, type, created_at) VALUES (?,?,?,?)", [1, "2026-10-27", "skip", "2026-10-01T09:00:00"]),
    ("INSERT INTO event_notes(event_id, note, source, updated_at) VALUES (?,?,?,?)", [1, "Raum 1 statt 2", "manual", "2026-10-01T09:00:00"]),
    ("INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at) "
     "VALUES (?,?,?,?,?,?,?,?,?,?)",
     ["2026-10-28", 1, "Lineare Algebra Test", "LA nacharbeiten", 1, 45, "geplant", 0, 1, "2026-10-01T09:00:00"]),
    ("INSERT INTO study_tasks(package_id, type, file_id, title, sort, est_minutes, status, created_at) VALUES (?,?,?,?,?,?,?,?)",
     [1, "vorlesung", "f-la1", "Vorlesung 01 lesen", 0, 45, "geplant", "2026-10-01T09:00:00"]),
    ("INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
     ["lw-ev-1", "learnweb", "k-la", "Blatt 1 abgeben", "Blatt 1 abgeben (Fr, 30.10.)", "abgabe", "assign", "2026-10-30T12:00", "", 0, "2026-10-01T09:00:00"]),
    ("INSERT INTO announcements(id, source, course_id, title, text, author, posted_at, url, dates, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
     ["sp-news-1", "studip", "k-la", "Willkommen", "Die Vorlesung beginnt am 27.10.", "Prof. Test", "2026-10-20T08:00:00", "", "[]", "2026-10-20T08:00:00"]),
    ("INSERT INTO settings(key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", ["user_name", "Testperson"]),
]

# Spuren des Nutzers an den Demo-Inhalten (nach dem Anlegen): verschwinden mit dem Entfernen
TOUCH_DEMO = [
    ("INSERT INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,?)",
     ["demo-skript", '{"version": 2, "pages": {"1": {"objects": [{"id": "s1", "type": "stroke"}]}}}', "2026-10-28T10:00:00", 1]),
    ("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES (?,?,?,?)",
     ["demo-skript", 1, '{"version": 2, "pages": {}}', "2026-10-28T10:00:00"]),
    ("INSERT INTO analysis(file_id, doc_type, title, created_at) VALUES (?,?,?,?)", ["demo-folien", "vorlesung", "Einführung", "2026-10-28T10:00:00"]),
    ("INSERT INTO event_exceptions(event_id, date, type, created_at) SELECT id, ?, ?, ? FROM course_events WHERE source='demo' AND weekday=2",
     ["2026-10-28", "skip", "2026-10-28T10:00:00"]),
    ("INSERT INTO event_notes(event_id, note, source, updated_at) SELECT id, ?, ?, ? FROM course_events WHERE source='demo' AND weekday=0",
     ["Hörsaal B", "manual", "2026-10-28T10:00:00"]),
]

TODAY = "2026-10-28T09:30:00"                         # Mittwoch; Montag dieser Woche: 26.10.2026
DATES = ["2026-10-26T08:00:00", "2026-11-01T23:59:59", "2026-12-31T12:00:00", "2028-02-29T07:00:00",
         "2026-10-27T00:30:00", "2027-03-30T12:00:00"]


def raw(body) -> str | None:
    return json.dumps(body, ensure_ascii=False) if body is not None else None


STEPS_EMPTY = [
    ("GET", "/api/demo", None, None),
    ("POST", "/api/demo", raw({"enabled": False}), None),            # ohne Demo: nichts zu entfernen
    ("GET", "/api/demo", None, None),
    ("POST", "/api/demo", raw({"enabled": True}), "angelegt"),
    ("GET", "/api/demo", None, None),
    ("POST", "/api/demo", raw({"enabled": True}), "erneut"),         # frisch, keine Doppel
    ("POST", "/api/demo", raw({"enabled": False}), "entfernt"),
    ("GET", "/api/demo", None, None),
    # Ruempfe wie FastAPI: Body(default={}) und Wahrheitswert wie Python
    ("POST", "/api/demo", raw({"enabled": 1}), None),
    ("POST", "/api/demo", "", None),                                 # leer = {} -> entfernen
    ("POST", "/api/demo", raw({"enabled": "nein"}), None),           # Text ist wahr
    ("POST", "/api/demo", raw({}), None),
    ("POST", "/api/demo", raw({"enabled": 2.5}), None),
    ("POST", "/api/demo", raw({"enabled": 0}), None),
    ("POST", "/api/demo", raw({"enabled": [0]}), None),
    ("POST", "/api/demo", raw({"enabled": ""}), None),
    ("POST", "/api/demo", raw({"enabled": {"x": 1}}), None),
    ("POST", "/api/demo", raw({"enabled": None}), None),
    ("POST", "/api/demo", raw({"enabled": 0.0}), None),
    ("POST", "/api/demo", raw({"enabled": []}), None),
    ("POST", "/api/demo", raw({"anders": True}), "zuletzt"),
    ("POST", "/api/demo", raw([1]), None),                           # 422
    ("POST", "/api/demo", "null", None),
    ("POST", "/api/demo", "{kaputt", None),                          # 422
    ("GET", "/api/demo", None, None),
]

STEPS_USER = [
    ("GET", "/api/demo", None, "vorher"),
    ("POST", "/api/demo", raw({"enabled": True}), "angelegt"),
    ("SQL", "touch", None, "spuren"),
    ("GET", "/api/demo", None, None),
    ("POST", "/api/demo", raw({"enabled": False}), "entfernt"),
    ("POST", "/api/demo", raw({"enabled": True}), "wieder"),
    ("POST", "/api/demo", raw({"enabled": False}), "wieder-entfernt"),
]


def load_gen():
    spec = importlib.util.spec_from_file_location("gen_local_backend_fixture", Path(__file__).with_name("gen-local-backend-fixture.py"))
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    return gen


class Clock:
    """Uhr fuer date.today() in app/demo.py und server.py, db.now_iso() und datetime.now() (weiterstellbar)"""

    def __init__(self, src: SchemaSource):
        from app import demo
        self.now = TODAY
        src.freeze(lambda: date.fromisoformat(self.now[:10]), lambda: self.now, lambda: datetime.fromisoformat(self.now))
        clock = self

        class FrozenDate(date):
            @classmethod
            def today(cls):
                d = date.fromisoformat(clock.now[:10])
                return cls(d.year, d.month, d.day)

        demo.date = FrozenDate


def tables(src: SchemaSource) -> dict:
    """Tabellen wie TABLES; local_path relativ zum Datenordner (am PC absolut, auf dem iPad relativ zum Container)"""
    from app import config
    prefix = str(config.data_dir()) + os.sep
    out = {}
    with src.db.cursor() as conn:
        exists = {r["name"] for r in src.db.rows(conn, "SELECT name FROM sqlite_master WHERE type='table'")}
        for name, sql in TABLES.items():
            if name == "page_texts" and name not in exists:
                out[name] = []
                continue
            rows = src.db.rows(conn, sql)
            for r in rows:
                if isinstance(r.get("local_path"), str) and r["local_path"].startswith(prefix):
                    r["local_path"] = r["local_path"][len(prefix):].replace(os.sep, "/")
            out[name] = rows
    return out


def files_on_disk() -> list:
    """Dateien unter <Datenordner>/files (Pfad relativ zum Datenordner, Groesse, SHA-256)"""
    from app import config
    base = config.data_dir()
    root = base / "files"
    if not root.exists():
        return []
    return [{"path": p.relative_to(base).as_posix(), "size": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
            for p in sorted(root.rglob("*")) if p.is_file()]


def dirs_on_disk() -> list:
    from app import config
    base = config.data_dir()
    root = base / "files"
    return [p.relative_to(base).as_posix() for p in sorted(root.rglob("*")) if p.is_dir()] if root.exists() else []


def run_steps(src: SchemaSource, gen, server, name: str, seed: list, steps: list) -> dict:
    src.fresh_db(name)
    from app import config, demo
    import shutil
    shutil.rmtree(config.files_dir(), ignore_errors=True)
    with src.db.cursor() as conn:
        for sql, params in seed:
            conn.execute(sql, params)
    out, marks = [], {}
    for method, path, body, mark in steps:
        if method == "SQL":
            with src.db.cursor() as conn:
                for sql, params in TOUCH_DEMO:
                    conn.execute(sql, params)
                from app import scriptsearch
                scriptsearch.ensure_table(conn)
                conn.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES (?,?,?,?)", ["demo-blatt", 1, "Übungsblatt 1", 0])
            out.append({"sql": path})
        else:
            status, value = gen.asgi(server.app, method, path, raw_body=body)
            step = {"method": method, "path": path, "raw": body, "status": status}
            if status != 500:
                step["response"] = value
            out.append(step)
        if mark:
            marks[mark] = {"after_step": len(out) - 1, "tables": tables(src), "files": files_on_disk(), "dirs": dirs_on_disk()}
    return {"name": name, "now": TODAY, "seed": [{"sql": q, "params": p} for q, p in seed], "steps": out, "marks": marks}


def date_cases(src: SchemaSource, gen, server, clock: Clock) -> list:
    cases = []
    for now in DATES:
        src.fresh_db("datum")
        clock.now = now
        status, value = gen.asgi(server.app, "POST", "/api/demo", raw_body=raw({"enabled": True}))
        assert status == 200, (now, status, value)
        t = tables(src)
        cases.append({"now": now,
                      "study_packages": [{k: p[k] for k in ("date", "title", "planned_minutes", "sort")} for p in t["study_packages"]],
                      "deadlines": [{k: d[k] for k in ("id", "due_at")} for d in t["deadlines"]],
                      "announcements": [{k: a[k] for k in ("id", "text", "dates", "posted_at")} for a in t["announcements"]],
                      "files": [{k: f[k] for k in ("id", "chdate", "first_seen")} for f in t["files"]]})
    clock.now = TODAY
    return cases


def pdfs() -> dict:
    from app import demo
    from pypdf import PdfReader

    def entry(pages) -> dict:
        data = demo.pdf_bytes([(t, list(lines)) for t, lines in pages])
        r = PdfReader(io.BytesIO(data))
        return {"pages": pages, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                "base64": base64.b64encode(data).decode("ascii"), "page_count": len(r.pages),
                "text": [p.extract_text() for p in r.pages]}

    files = [{"id": f["id"], "name": f["name"], **entry([[t, lines] for t, lines in f["pages"]])} for f in demo.FILES]
    return {"files": files, "cases": [entry(c) for c in PDF_CASES]}


def constants() -> dict:
    from app import demo
    return {"module": demo.MODULE_NAME, "subject": demo.SUBJECT, "color": demo.COLOR, "courses": demo.COURSES, "events": demo.EVENTS,
            "files": [{"id": f["id"], "course_id": f["course_id"], "name": f["name"], "pages": [[t, lines] for t, lines in f["pages"]]}
                      for f in demo.FILES]}


def main() -> int:
    check = "--check" in sys.argv[1:]
    src = SchemaSource()
    try:
        from app import server
        gen = load_gen()
        with berlin_time():
            clock = Clock(src)
            out = {"generator": "tools/gen-demo-fixture.py", "constants": constants(), "pdfs": pdfs(),
                   "scenarios": [run_steps(src, gen, server, "leer", [], STEPS_EMPTY),
                                 run_steps(src, gen, server, "eigene-daten", USER_SEED, STEPS_USER)],
                   "touch_demo": [{"sql": q, "params": p} for q, p in TOUCH_DEMO]
                   + [{"sql": "INSERT INTO page_texts(file_id, page, text, chdate) VALUES (?,?,?,?)", "params": ["demo-blatt", 1, "Übungsblatt 1", 0]}],
                   "dates": date_cases(src, gen, server, clock)}
    finally:
        src.cleanup()
    out = without_sync(out)
    ok = write_or_check(OUT, json.dumps(out, ensure_ascii=False, indent=1) + "\n", check)
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())
