"""Datenbank-Migration: eine Datenbank im Stand der ersten Version (ohne spaetere Spalten) wird beim Start
ohne Datenverlust auf das aktuelle Schema gebracht. Laeuft auf einer eigenen Temp-Datei, nie auf data/."""
import sqlite3

from app import db

# Tabellen so, wie sie vor den spaeteren add_col-Migrationen angelegt wurden (Grundschema ohne Zusatzspalten)
OLD_SCHEMA = """
CREATE TABLE courses (id TEXT PRIMARY KEY, title TEXT NOT NULL, number TEXT, semester TEXT, subject TEXT, kind TEXT,
                      active INTEGER DEFAULT 1, test_minutes INTEGER DEFAULT 90, created_at TEXT);
CREATE TABLE files (id TEXT PRIMARY KEY, course_id TEXT NOT NULL REFERENCES courses(id), name TEXT NOT NULL, size INTEGER,
                    mime TEXT, author TEXT, chdate INTEGER, download_url TEXT, local_path TEXT, downloaded_at TEXT,
                    first_seen TEXT, status TEXT DEFAULT 'neu', seen_by_user INTEGER DEFAULT 0, text_excerpt TEXT);
CREATE TABLE annotations (file_id TEXT PRIMARY KEY REFERENCES files(id), data TEXT NOT NULL, updated_at TEXT);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
"""


def test_old_database_is_migrated_without_data_loss(tmp_path, monkeypatch):
    path = tmp_path / "alt.db"
    with sqlite3.connect(path) as c:
        c.executescript(OLD_SCHEMA)
        c.execute("INSERT INTO courses(id, title, kind, created_at) VALUES ('c1', 'Mathe I', 'vorlesung', '2026-10-01')")
        c.execute("INSERT INTO files(id, course_id, name, mime, status) VALUES ('f1', 'c1', 'Folien.pdf', 'application/pdf', 'gelesen')")
        c.execute("INSERT INTO files(id, course_id, name, mime, status) VALUES ('f2', 'c1', 'uebung.py', 'text/x-python', 'neu')")
        c.execute("INSERT INTO annotations VALUES ('f1', '{\"version\":2,\"pages\":{}}', '2026-10-02')")
        c.execute("INSERT INTO settings VALUES ('user_name', 'Test')")
    before = {t: sqlite3.connect(path).execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in ("courses", "files", "annotations", "settings")}

    monkeypatch.setattr(db, "DB_PATH", path)
    db.init_db()
    db.init_db()                                   # zweiter Start: Migration ist wiederholbar

    c = sqlite3.connect(path)
    c.row_factory = sqlite3.Row
    for t, n in before.items():
        assert c.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] >= n, f"{t}: Zeilen verloren"
    cols = {r[1] for r in c.execute("PRAGMA table_info(files)")}
    assert {"kind", "studip_folder", "last_page", "favorite", "title", "deleted_at"} <= cols
    assert {r[1] for r in c.execute("PRAGMA table_info(courses)")} >= {"module_id"}
    assert {r[1] for r in c.execute("PRAGMA table_info(annotations)")} >= {"version"}
    kinds = dict(c.execute("SELECT id, kind FROM files").fetchall())
    assert kinds == {"f1": "pdf", "f2": "file"}, "Dateiart aus Endung/MIME nachgetragen"
    assert c.execute("SELECT data FROM annotations WHERE file_id='f1'").fetchone()[0].startswith('{"version":2')
    assert c.execute("SELECT status FROM files WHERE id='f1'").fetchone()[0] == "gelesen", "bestehende Werte bleiben"
    assert c.execute("SELECT value FROM settings WHERE key='user_name'").fetchone()[0] == "Test"
    assert c.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
