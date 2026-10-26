"""Erzeugt die Schema-Fixtures in packages/shared-contracts/fixtures/schema/ mit der Python-Referenz.

- schema.json: neue Datenbank nach app.db.init_db() (plus page_texts aus scriptsearch.ensure_table), normalisiert:
  Tabellen mit Spalten (Typ, Default, NotNull, PK), Fremdschluesseln und Indizes, SQL der eigenen Indizes,
  settings-Standardwerte, Pseudokurs __user__ und Standardsemester.
- legacy.json: eine aeltere Datenbank (Grundschema ohne die per add_col nachgetragenen Spalten, teils schon halb
  migriert, mit erfundenen Zeilen), dazu Schema und Zeilen, wie init_db() sie daraus macht (sync_updated_at der
  Geraete-Synchronisierung als "<zeit>", die SQLite-Uhr laesst sich nicht einfrieren).

Der Swift-Kern (SQLiteStoreTests) legt dieselben Datenbanken mit Schema und Migrationen an und vergleicht.
init_db() laeuft nur gegen Dateien in einem Temp-Ordner, nie gegen data/.
Aufruf im Projektordner: python tools/gen-schema-fixture.py [--check]
"""
from __future__ import annotations

import json
import sqlite3
import sys

from schema_source import ROOT, SchemaSource, write_or_check

OUT = ROOT / "packages" / "shared-contracts" / "fixtures" / "schema"

# Aelterer Stand (erfunden, aber im Aufbau wie fruehe Versionen): nur einige Tabellen, ohne die spaeteren Spalten.
# annotations hat version und files hat studip_folder schon (halb migrierte Datenbank), terms fehlt ganz.
LEGACY_SQL = """
CREATE TABLE courses (id TEXT PRIMARY KEY, title TEXT NOT NULL, number TEXT, semester TEXT, subject TEXT, kind TEXT,
                      active INTEGER DEFAULT 1, test_minutes INTEGER DEFAULT 90, created_at TEXT);
CREATE TABLE files (id TEXT PRIMARY KEY, course_id TEXT NOT NULL REFERENCES courses(id), name TEXT NOT NULL, size INTEGER,
                    mime TEXT, author TEXT, chdate INTEGER, download_url TEXT, local_path TEXT, downloaded_at TEXT,
                    first_seen TEXT, status TEXT DEFAULT 'neu', seen_by_user INTEGER DEFAULT 0, text_excerpt TEXT,
                    studip_folder TEXT);
CREATE TABLE annotations (file_id TEXT PRIMARY KEY REFERENCES files(id), data TEXT NOT NULL, updated_at TEXT,
                          version INTEGER DEFAULT 1);
CREATE TABLE tests (id INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT NOT NULL, week_start TEXT, title TEXT,
                    duration_min INTEGER, questions TEXT NOT NULL, created_at TEXT, started_at TEXT, submitted_at TEXT,
                    answers TEXT, score REAL, max_score REAL, feedback TEXT);
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);

INSERT INTO courses(id, title, kind, created_at) VALUES ('k1', 'Testkurs Algebra', 'vorlesung', '2026-09-30T08:00:00');
INSERT INTO courses(id, title, kind, active, created_at) VALUES ('k2', 'Testkurs Algebra Uebung', 'uebung', 0, '2026-09-30T08:01:00');
INSERT INTO courses(id, title, kind, created_at) VALUES ('__user__', 'Eigene Dokumente', 'sonstiges', '2026-09-01T07:00:00');
INSERT INTO files(id, course_id, name, size, mime, chdate, status) VALUES ('f1', 'k1', 'Folien_01.pdf', 1024, 'application/pdf', 1760000000, 'gelesen');
INSERT INTO files(id, course_id, name, mime, studip_folder) VALUES ('f2', 'k2', 'blatt1.py', 'text/x-python', 'Uebungen');
INSERT INTO files(id, course_id, name, mime) VALUES ('f3', 'k2', 'Skizze.PNG', 'image/png');
INSERT INTO files(id, course_id, name) VALUES ('f4', 'k1', 'archiv.zip');
INSERT INTO files(id, course_id, name) VALUES ('f5', 'k1', 'Tafel.JPeG');
INSERT INTO files(id, course_id, name) VALUES ('f6', 'k1', 'Altklausur.PDF');
INSERT INTO files(id, course_id, name) VALUES ('u1', '__user__', 'Mein Notizbuch');
INSERT INTO annotations(file_id, data, updated_at, version) VALUES ('f1', '{"version":2,"pages":{}}', '2026-10-02T10:00:00', 3);
INSERT INTO annotations(file_id, data, updated_at) VALUES ('f6', '{"version":2,"pages":{"p1":{"objects":[]}}}', '2026-10-03T11:00:00');
INSERT INTO tests(subject, title, duration_min, questions, score) VALUES ('Algebra', 'Probetest', 45, '[]', 7.5);
INSERT INTO settings(key, value) VALUES ('hours_per_day', '6');
INSERT INTO settings(key, value) VALUES ('user_name', 'Testperson');
INSERT INTO settings(key, value) VALUES ('eigener_schluessel', 'x');
"""

# Tabellen, deren Zeilen nach der Migration in legacy.json stehen
LEGACY_ROWS = ["courses", "files", "annotations", "tests", "settings", "terms"]


def snapshot(conn: sqlite3.Connection) -> dict:
    """Normalisierte Beschreibung des Schemas; SQLiteStoreTests.snapshot baut dieselbe Form in Swift."""
    tables = {}
    names = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
    for name in names:
        columns = [{"name": r[1], "type": r[2], "notnull": r[3], "default": r[4], "pk": r[5]}
                   for r in conn.execute(f'PRAGMA table_info("{name}")')]
        fks = [{"table": r[2], "from": r[3], "to": r[4], "on_update": r[5], "on_delete": r[6]}
               for r in conn.execute(f'PRAGMA foreign_key_list("{name}")')]
        fks.sort(key=lambda f: (f["from"], f["table"], f["to"] or ""))
        indexes = []
        for r in conn.execute(f'PRAGMA index_list("{name}")'):
            cols = [c[2] for c in conn.execute(f'PRAGMA index_info("{r[1]}")')]
            indexes.append({"name": r[1], "unique": r[2], "origin": r[3], "partial": r[4], "columns": cols})
        indexes.sort(key=lambda i: i["name"])
        tables[name] = {"columns": columns, "foreign_keys": fks, "indexes": indexes}
    index_sql = {r[0]: r[1] for r in conn.execute(
        "SELECT name, sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY name")}
    return {"tables": tables, "index_sql": index_sql,
            "user_version": conn.execute("PRAGMA user_version").fetchone()[0]}


# sync.ensure_schema setzt sync_updated_at mit der SQLite-Uhr (strftime 'now'): nicht einfrierbar, darum wie in
# tools/gen-sync-fixture.py durch "<zeit>" ersetzt (SQLiteStoreTests maskiert die Spalte genauso)
SYNC_TIME = "<zeit>"


def rows(conn: sqlite3.Connection, table: str) -> list[dict]:
    conn.row_factory = sqlite3.Row
    try:
        out = [dict(r) for r in conn.execute(f'SELECT * FROM "{table}" ORDER BY rowid')]
        for r in out:
            if isinstance(r.get("sync_updated_at"), str):
                r["sync_updated_at"] = SYNC_TIME
        return out
    finally:
        conn.row_factory = None


def _flat(v) -> bool:
    """Passt in eine Zeile: Liste von Werten oder Objekt aus Werten und Wertelisten (eine Spalte, ein Index ...)."""
    def scalar(x) -> bool:
        return not isinstance(x, (dict, list))
    if isinstance(v, list):                     # lange Wertelisten (setup_sql) lieber eine Zeile je Eintrag
        return all(scalar(x) for x in v) and len(json.dumps(v, ensure_ascii=False)) <= 120
    return all(scalar(x) or (isinstance(x, list) and all(scalar(y) for y in x)) for x in v.values())


def dump(obj, indent: str = "") -> str:
    """JSON mit einer Zeile je Spalte/Index/Zeile (lesbare Diffs), sonst eingerueckt."""
    if not isinstance(obj, (dict, list)) or not obj or _flat(obj):
        text = json.dumps(obj, ensure_ascii=False)
        return text if indent else text + "\n"
    inner = indent + "  "
    if isinstance(obj, dict):
        parts = [f"{inner}{json.dumps(k, ensure_ascii=False)}: {dump(v, inner)}" for k, v in obj.items()]
        text = "{\n" + ",\n".join(parts) + f"\n{indent}}}"
    else:
        text = "[\n" + ",\n".join(f"{inner}{dump(v, inner)}" for v in obj) + f"\n{indent}]"
    return text if indent else text + "\n"


def fresh(src: SchemaSource) -> dict:
    path = src.tmp / "neu.db"
    src.use_db(path)
    src.db.init_db()
    with src.db.connect() as conn:
        src.scriptsearch.ensure_table(conn)
    conn = sqlite3.connect(path)
    try:
        user = rows(conn, "courses")
        for r in user:
            r.pop("created_at")                 # now_iso() beim Anlegen, im Swift-Test aus der eingefrorenen Uhr
        return {
            "generator": "tools/gen-schema-fixture.py",
            "schema": snapshot(conn),
            "settings": [[k, v] for k, v in conn.execute("SELECT key, value FROM settings ORDER BY rowid")],
            "courses": user,
            "terms": rows(conn, "terms"),
        }
    finally:
        conn.close()


def legacy(src: SchemaSource) -> dict:
    path = src.tmp / "alt.db"
    with sqlite3.connect(path) as c:
        c.executescript(LEGACY_SQL)
    c.close()
    src.use_db(path)
    src.db.init_db()
    with src.db.connect() as conn:
        src.scriptsearch.ensure_table(conn)
    conn = sqlite3.connect(path)
    try:
        return {
            "generator": "tools/gen-schema-fixture.py",
            "setup_sql": LEGACY_SQL.strip("\n").splitlines(),       # Zeilen, in Swift mit "\\n" verbunden
            "schema": snapshot(conn),
            "rows": {t: rows(conn, t) for t in LEGACY_ROWS},
        }
    finally:
        conn.close()


def main() -> int:
    check = "--check" in sys.argv[1:]
    src = SchemaSource()
    try:
        out = {"schema.json": dump(fresh(src)), "legacy.json": dump(legacy(src))}
    finally:
        src.cleanup()
    ok = all([write_or_check(OUT / name, content, check) for name, content in out.items()])
    return 0 if ok or not check else 1


if __name__ == "__main__":
    sys.exit(main())
