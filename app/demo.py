"""Demo-Inhalte fuer die App-Pruefung ohne Hochschulkonto (App Store / Play Store) und zum Ausprobieren.

Ein Demo-Modul "Grundlagen der Informatik" mit Vorlesung und Uebung: drei PDFs (Skript, Folien, Uebungsblatt) werden
hier erzeugt (keine fremden Inhalte), dazu Stundenplan-Termine (wochentlich), Lernpakete mit Aufgaben fuer diese Woche,
eine Abgabefrist und eine Ankuendigung mit Termin. Alles traegt die Kennung "demo-" bzw. source = "demo" und laesst sich
mit remove() rueckstandslos entfernen; der Schalter steht in den Einstellungen (Erweitert) und unter /api/demo.
Demo-Dateien sind eigene Dokumente ohne Hochschulquelle: sie werden gespeichert (auch im Dienst), nie gestreamt und
zaehlen nicht als "Datei aus dem Hochschul-Abgleich" (Community).
"""
from __future__ import annotations

import hashlib
from datetime import date, datetime, timedelta
from pathlib import Path

from . import config, db

MODULE_NAME = "Demo: Grundlagen der Informatik"
SUBJECT = "Demo Informatik"
COURSES = [
    {"id": "demo-vorlesung", "title": "Demo: Grundlagen der Informatik (Vorlesung)", "kind": "vorlesung", "number": "DEMO-101"},
    {"id": "demo-uebung", "title": "Demo: Grundlagen der Informatik (Übung)", "kind": "uebung", "number": "DEMO-101Ü"},
]
EVENTS = [
    {"course_id": "demo-vorlesung", "title": "Grundlagen der Informatik – Vorlesung", "kind": "vorlesung", "weekday": 0, "start_time": "10:00", "end_time": "12:00", "room": "Hörsaal A", "lecturer": "Prof. Demo"},
    {"course_id": "demo-vorlesung", "title": "Grundlagen der Informatik – Vorlesung", "kind": "vorlesung", "weekday": 3, "start_time": "08:15", "end_time": "09:45", "room": "Hörsaal A", "lecturer": "Prof. Demo"},
    {"course_id": "demo-uebung", "title": "Grundlagen der Informatik – Übung", "kind": "uebung", "weekday": 2, "start_time": "14:00", "end_time": "16:00", "room": "Seminarraum 3", "lecturer": "Tutorium"},
]
FILES = [
    {"id": "demo-skript", "course_id": "demo-vorlesung", "name": "Skript Kapitel 1 – Zahlensysteme.pdf", "pages": [
        ("Kapitel 1: Zahlensysteme", ["Dezimal-, Dual- und Hexadezimalsystem.", "Jede Zahl lässt sich als Summe von Potenzen der Basis schreiben.", "Beispiel: 13 = 1101 (dual) = D (hexadezimal)."]),
        ("1.1 Umrechnung", ["Dezimal nach Dual: fortgesetzte Division durch 2, Reste von unten lesen.", "Dual nach Dezimal: Stellenwerte 1, 2, 4, 8, ... addieren.", "Übung: Rechne 42 ins Dualsystem um."]),
        ("1.2 Zweierkomplement", ["Negative Zahlen: Bits invertieren und 1 addieren.", "Mit 8 Bit reicht der Bereich von -128 bis 127.", "Überlauf erkennen: Vorzeichen des Ergebnisses prüfen."]),
    ]},
    {"id": "demo-folien", "course_id": "demo-vorlesung", "name": "Folien Woche 1 – Einführung.pdf", "pages": [
        ("Grundlagen der Informatik", ["Willkommen zur Demo-Vorlesung.", "Organisatorisches, Literatur, Prüfung."]),
        ("Was ist Informatik?", ["Wissenschaft der systematischen Verarbeitung von Information.", "Algorithmus, Daten, Programm."]),
        ("Algorithmus", ["Eindeutige, endliche Handlungsvorschrift.", "Beispiel: Zähneputzen, Wegbeschreibung, Sortieren."]),
        ("Nächste Woche", ["Zahlensysteme und Zweierkomplement.", "Bitte Übungsblatt 1 bearbeiten."]),
    ]},
    {"id": "demo-blatt", "course_id": "demo-uebung", "name": "Übungsblatt 1 – Zahlensysteme.pdf", "pages": [
        ("Übungsblatt 1", ["Aufgabe 1: Rechne 42, 100 und 255 ins Dualsystem um.", "Aufgabe 2: Welche Dezimalzahl ist 1011 0110 (dual)?", "Aufgabe 3: Bilde das Zweierkomplement von -37 mit 8 Bit."]),
        ("Aufgabe 4 (Bonus)", ["Warum reicht ein Byte für Werte von 0 bis 255?", "Abgabe: nächste Woche vor der Übung."]),
    ]},
]
COLOR = "#7c3aed"


def is_enabled(conn) -> bool:
    return str(db.get_settings(conn).get("demo_content", "0")) == "1"


def _esc(s: str) -> bytes:
    return s.encode("cp1252", "replace").replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")


def pdf_bytes(pages: list[tuple[str, list[str]]]) -> bytes:
    """Kleines gueltiges PDF (A4, Helvetica, WinAnsi) mit Ueberschrift und Zeilen je Seite; pypdf liest den Text."""
    objs: list[bytes] = [b"", b""]                                        # 1 Katalog, 2 Seitenbaum (spaeter)
    font_no = 3
    objs.append(b"<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>")
    page_nos = []
    for title, lines in pages:
        content = b"BT /F1 20 Tf 60 770 Td (" + _esc(title) + b") Tj ET\n"
        y = 730
        for line in lines:
            content += b"BT /F1 12 Tf 60 " + str(y).encode() + b" Td (" + _esc(line) + b") Tj ET\n"
            y -= 22
        content += b"BT /F1 9 Tf 60 40 Td (UniFlow Demo-Inhalt) Tj ET\n"
        objs.append(b"<</Length " + str(len(content)).encode() + b">>stream\n" + content + b"\nendstream")
        stream_no = len(objs)
        objs.append(b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Contents " + str(stream_no).encode()
                    + b" 0 R/Resources<</Font<</F1 " + str(font_no).encode() + b" 0 R>>>>>>")
        page_nos.append(len(objs))
    objs[0] = b"<</Type/Catalog/Pages 2 0 R>>"
    objs[1] = b"<</Type/Pages/Kids[" + b" ".join(f"{n} 0 R".encode() for n in page_nos) + b"]/Count " + str(len(page_nos)).encode() + b">>"
    out, offsets = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"), []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + o + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += f"trailer\n<</Size {len(objs) + 1}/Root 1 0 R>>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)


def demo_dir() -> Path:
    return config.files_dir() / "Demo"


def remove(conn) -> dict:
    """Alle Demo-Daten entfernen (Dateien, Notizen, Kurse, Modul, Termine, Pakete, Fristen, Ankuendigungen)."""
    n = {"files": 0, "events": 0, "packages": 0}
    for f in db.rows(conn, "SELECT id, local_path FROM files WHERE id LIKE 'demo-%'"):
        if f["local_path"]:
            Path(f["local_path"]).unlink(missing_ok=True)
        n["files"] += 1
    conn.execute("DELETE FROM annotations WHERE file_id LIKE 'demo-%'")
    conn.execute("DELETE FROM analysis WHERE file_id LIKE 'demo-%'")
    try:
        conn.execute("DELETE FROM page_texts WHERE file_id LIKE 'demo-%'")
    except Exception:  # noqa: BLE001 - Tabelle erst nach der ersten Suche vorhanden
        pass
    conn.execute("DELETE FROM files WHERE id LIKE 'demo-%'")
    n["packages"] = conn.execute("SELECT COUNT(*) FROM study_packages WHERE module_id IN (SELECT id FROM modules WHERE name=?)", (MODULE_NAME,)).fetchone()[0]
    conn.execute("DELETE FROM study_tasks WHERE package_id IN (SELECT id FROM study_packages WHERE module_id IN (SELECT id FROM modules WHERE name=?))", (MODULE_NAME,))
    conn.execute("DELETE FROM study_packages WHERE module_id IN (SELECT id FROM modules WHERE name=?)", (MODULE_NAME,))
    n["events"] = conn.execute("SELECT COUNT(*) FROM course_events WHERE source='demo' OR course_id LIKE 'demo-%'").fetchone()[0]
    conn.execute("DELETE FROM event_exceptions WHERE event_id IN (SELECT id FROM course_events WHERE source='demo' OR course_id LIKE 'demo-%')")
    conn.execute("DELETE FROM course_events WHERE source='demo' OR course_id LIKE 'demo-%'")
    conn.execute("DELETE FROM deadlines WHERE source='demo'")
    conn.execute("DELETE FROM announcements WHERE source='demo'")
    conn.execute("DELETE FROM courses WHERE id LIKE 'demo-%'")
    conn.execute("DELETE FROM modules WHERE name=?", (MODULE_NAME,))
    db.set_setting(conn, "demo_content", 0)
    d = demo_dir()
    if d.exists() and not any(d.iterdir()):
        d.rmdir()
    return n


def install(conn, today: date | None = None) -> dict:
    """Demo-Inhalte anlegen (vorher vorhandene Demo-Daten entfernen, damit der Stand immer frisch ist)."""
    remove(conn)
    today = today or date.today()
    now = db.now_iso()
    cur = conn.execute("INSERT INTO modules(name, semester, color, sort, created_at) VALUES (?,?,?,?,?)",
                       (MODULE_NAME, None, COLOR, 99, now))
    module_id = cur.lastrowid
    for c in COURSES:
        conn.execute("INSERT INTO courses(id, title, number, semester, subject, kind, active, test_minutes, created_at, module_id) VALUES (?,?,?,?,?,?,1,60,?,?)",
                     (c["id"], c["title"], c["number"], None, SUBJECT, c["kind"], now, module_id))
    d = demo_dir()
    d.mkdir(parents=True, exist_ok=True)
    chdate = int(datetime.combine(today - timedelta(days=3), datetime.min.time()).timestamp())
    for f in FILES:
        data = pdf_bytes(f["pages"])
        p = d / f["name"]
        p.write_bytes(data)
        conn.execute("""INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, local_path, downloaded_at, first_seen, status,
                                          seen_by_user, kind, title, page_count, content_sha256)
                        VALUES (?,?,?,?,'application/pdf','Prof. Demo',?,'',?,?,?,'neu',0,'pdf',?,?,?)""",
                     (f["id"], f["course_id"], f["name"], len(data), chdate, str(p), now, now, Path(f["name"]).stem, len(f["pages"]),
                      hashlib.sha256(data).hexdigest()))
    for e in EVENTS:
        conn.execute("""INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, attend, source, color, created_at)
                        VALUES (?,?,?,?,?,?,?,?,?,'weekly',1,'demo',?,?)""",
                     (module_id, e["course_id"], e["title"], e["kind"], e["weekday"], e["start_time"], e["end_time"], e["room"], e["lecturer"], COLOR, now))
    monday = today - timedelta(days=today.weekday())
    plan = [(monday + timedelta(days=0), "Vorlesung nacharbeiten", [("vorlesung", "demo-folien", "Folien Woche 1 durchgehen", 30), ("vorlesung", "demo-skript", "Skript Kapitel 1 lesen", 45)]),
            (monday + timedelta(days=2), "Übungsblatt 1", [("uebung", "demo-blatt", "Aufgaben 1–3 rechnen", 60)]),
            (monday + timedelta(days=4), "Wiederholung", [("wiederholung", "demo-skript", "Zweierkomplement wiederholen", 25)])]
    for i, (day, title, tasks) in enumerate(plan):
        cur = conn.execute("INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at) VALUES (?,?,?,?,1,?,'geplant',?,0,?)",
                           (day.isoformat(), module_id, SUBJECT, title, sum(t[3] for t in tasks), i, now))
        for j, (typ, fid, ttitle, minutes) in enumerate(tasks):
            conn.execute("INSERT INTO study_tasks(package_id, type, file_id, title, sort, est_minutes, status, created_at) VALUES (?,?,?,?,?,?,'geplant',?)",
                         (cur.lastrowid, typ, fid, ttitle, j, minutes, now))
    due = datetime.combine(monday + timedelta(days=9), datetime.min.time()).replace(hour=13, minute=45)
    conn.execute("INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,0,?)",
                 ("demo-abgabe-1", "demo", "demo-uebung", "Übungsblatt 1 abgeben", "Übungsblatt 1 abgeben (Demo)", "abgabe", "assign", due.isoformat(timespec="minutes"), "", now))
    ann_date = monday + timedelta(days=7)
    conn.execute("INSERT INTO announcements(id, source, course_id, title, text, author, posted_at, url, dates, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                 ("demo-ankuendigung-1", "demo", "demo-vorlesung", "Raumwechsel nächste Woche",
                  f"Die Vorlesung am {ann_date.strftime('%d.%m.')} findet im Hörsaal B statt. Bitte Übungsblatt 1 vorher bearbeiten.", "Prof. Demo",
                  now, "", f'[{{"date": "{ann_date.isoformat()}", "time": "10:00", "kind": "raumwechsel", "snippet": "Vorlesung im Hörsaal B"}}]', now))
    db.set_setting(conn, "demo_content", 1)
    return status(conn)


def status(conn) -> dict:
    return {"enabled": is_enabled(conn),
            "files": conn.execute("SELECT COUNT(*) FROM files WHERE id LIKE 'demo-%'").fetchone()[0],
            "events": conn.execute("SELECT COUNT(*) FROM course_events WHERE source='demo'").fetchone()[0],
            "packages": conn.execute("SELECT COUNT(*) FROM study_packages WHERE module_id IN (SELECT id FROM modules WHERE name=?)", (MODULE_NAME,)).fetchone()[0],
            "module": MODULE_NAME}
