"""Echte Lernaufgaben mit Lernschritten (app/outline.py, Auftrag des Inhabers 14.11.2026, Teil 2). Gleiche Rechnung wie
der iPad-Kern: outline.json (tools/gen-outline-fixture.py) und study-plan.json Szenario "gliederung". Hier: Abgleichsdatei
aktuell, und der ganze Weg am PC - lokale PDF mit Lesezeichen, Gliederung beim Planen gelesen, Aufgaben nach Kapiteln
mit Seiten und Lernschritten statt "Datei.pdf (Teil 1/4)". Erfundene PDF aus den Fixtures, kein Netz."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = ROOT / "packages" / "shared-contracts" / "fixtures" / "local-backend" / "outline-sample.pdf"


def test_outline_fixture_is_current():
    r = subprocess.run([sys.executable, "tools/gen-outline-fixture.py", "--check"], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr


def test_planning_reads_the_outline_and_makes_real_tasks(app, tmp_path, monkeypatch):
    from datetime import date, datetime
    from zoneinfo import ZoneInfo

    from app import db, outline, study
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "outline.db")
    db.init_db()
    monkeypatch.setattr(study, "today", lambda: date(2026, 10, 28))
    pdf = tmp_path / "Beispielskript.pdf"
    shutil.copy(SAMPLE, pdf)
    with db.cursor() as conn:
        mid = conn.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Signale', '#336699', 0, '2026-10-01')").lastrowid
        conn.execute("INSERT INTO courses(id, title, subject, kind, module_id, active, semester, created_at) "
                     "VALUES ('k1', 'Signale', 'Signale', 'vorlesung', ?, 1, 'WiSe 2026/27', '2026-10-01')", (mid,))
        conn.execute("INSERT INTO files(id, course_id, name, chdate, local_path, status, studip_folder) VALUES ('f1', 'k1', 'Beispielskript.pdf', ?, ?, 'neu', 'Vorlesung')",
                     (int(datetime(2026, 10, 26, 9, tzinfo=ZoneInfo("Europe/Berlin")).timestamp()), str(pdf)))   # Mo 26.10.2026
        conn.execute("INSERT INTO analysis(file_id, doc_type, title, est_minutes, created_at) VALUES ('f1', 'skript', 'Beispielskript', 45, '2026-10-28')")
        conn.execute("UPDATE settings SET value='2.00' WHERE key='hours_per_day'")
        r = study.generate_packages(conn, date(2026, 10, 28), 5)
        o = outline.load(conn, "f1")
        tasks = db.rows(conn, "SELECT title, est_minutes, page_from, page_to, steps FROM study_tasks WHERE file_id='f1' ORDER BY page_from")
    assert o and o["page_count"] == 30 and len(o["sections"]) == 9, o
    assert r["created"] >= 1 and tasks, r
    assert not any(".pdf" in t["title"] or "Teil 1/" in t["title"] for t in tasks), [t["title"] for t in tasks]
    assert tasks[0]["title"].startswith("1 Signale · S. 4–9") or tasks[0]["title"].startswith("1.1 "), tasks[0]["title"]
    assert all(t["page_from"] and t["page_to"] >= t["page_from"] for t in tasks)
    steps = json.loads(tasks[0]["steps"])
    assert len(steps) == 4 and steps[0].startswith("Überfliegen") and f"S. {tasks[0]['page_from']}" in steps[0]


def test_unreadable_or_missing_pdf_keeps_the_old_way(tmp_path):
    from app import outline
    assert outline.read_pdf(str(tmp_path / "fehlt.pdf")) is None
    bad = tmp_path / "kaputt.pdf"
    bad.write_bytes(b"%PDF-1.4 kein echtes PDF")
    assert outline.read_pdf(str(bad)) is None
    assert outline.parts([], 0, 60, 30) == []
