"""SQLite-Datenbank: Schema und kleine Helfer."""
from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime

from .config import DB_PATH

SCHEMA = """
CREATE TABLE IF NOT EXISTS courses (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    number TEXT,
    semester TEXT,
    subject TEXT,            -- zusammengefasstes Fach (VL + Uebung)
    kind TEXT,               -- vorlesung | uebung | sonstiges
    active INTEGER DEFAULT 1,
    test_minutes INTEGER DEFAULT 90,
    created_at TEXT
);

CREATE TABLE IF NOT EXISTS files (
    id TEXT PRIMARY KEY,     -- Stud.IP file_id
    course_id TEXT NOT NULL REFERENCES courses(id),
    name TEXT NOT NULL,
    size INTEGER,
    mime TEXT,
    author TEXT,
    chdate INTEGER,          -- Unix-Zeit der letzten Aenderung in Stud.IP
    download_url TEXT,
    local_path TEXT,
    downloaded_at TEXT,
    first_seen TEXT,
    status TEXT DEFAULT 'neu',   -- neu | gelesen | erledigt
    seen_by_user INTEGER DEFAULT 0,
    text_excerpt TEXT
);

CREATE TABLE IF NOT EXISTS analysis (
    file_id TEXT PRIMARY KEY REFERENCES files(id),
    doc_type TEXT,           -- vorlesung | uebung | loesung | skript | organisatorisch | klausur | sonstiges
    title TEXT,
    topics TEXT,             -- JSON-Liste
    difficulty INTEGER,      -- 1..5
    est_minutes INTEGER,
    summary TEXT,
    prerequisites TEXT,      -- JSON-Liste
    raw TEXT,
    created_at TEXT
);

CREATE TABLE IF NOT EXISTS annotations (
    file_id TEXT PRIMARY KEY REFERENCES files(id),
    data TEXT NOT NULL,      -- JSON: {pages: {"1": {strokes: [...], notes: [...]}}, zoom: 1.2}
    updated_at TEXT
);

CREATE TABLE IF NOT EXISTS annotation_versions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_id TEXT NOT NULL,
    version INTEGER NOT NULL,
    data TEXT NOT NULL,
    created_at TEXT
);

CREATE TABLE IF NOT EXISTS flashcards (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_id TEXT,
    subject TEXT,
    question TEXT NOT NULL,
    answer TEXT NOT NULL,
    created_at TEXT,
    box INTEGER DEFAULT 1,        -- Leitner-Fach 1..5
    due TEXT
);

CREATE TABLE IF NOT EXISTS flashcard_stacks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    subject TEXT,                 -- Modul (Fach) wie flashcards.subject
    file_id TEXT,                 -- Quelldokument, optional
    created_at TEXT,
    last_practised TEXT,          -- letzte Wiederholung oder Uebung im Stapel
    week INTEGER,                 -- Lehrwoche 1..n, NULL = "Allgemein"
    kind TEXT DEFAULT 'eigene',   -- vorlesung | uebung | eigene
    source TEXT,                  -- uebernommen: week (geteilter Wochenstapel) | community (geteilter Stapel), NULL = eigener
    source_ref TEXT,              -- Schluessel des Wochenstapels bzw. Kennung des geteilten Stapels
    shared_id TEXT                -- Kennung des eigenen geteilten Stapels in der Modul-Community, NULL = privat
);

CREATE TABLE IF NOT EXISTS plans (
    week_start TEXT PRIMARY KEY,   -- Montag, YYYY-MM-DD
    generated_at TEXT,
    notes TEXT
);

CREATE TABLE IF NOT EXISTS plan_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    week_start TEXT NOT NULL REFERENCES plans(week_start),
    day INTEGER NOT NULL,          -- 0 = Montag ... 6 = Sonntag
    start_time TEXT,               -- HH:MM
    duration_min INTEGER,
    course_id TEXT,
    subject TEXT,
    file_id TEXT,
    test_id INTEGER,
    title TEXT NOT NULL,
    kind TEXT,                     -- lernen | ueben | wiederholen | test
    done INTEGER DEFAULT 0,
    manual INTEGER DEFAULT 0,
    sort_order INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS tests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    subject TEXT NOT NULL,
    week_start TEXT,
    title TEXT,
    duration_min INTEGER,
    questions TEXT NOT NULL,       -- JSON-Liste
    created_at TEXT,
    started_at TEXT,
    submitted_at TEXT,
    answers TEXT,                  -- JSON
    score REAL,
    max_score REAL,
    feedback TEXT                  -- JSON
);

-- geloeschte Wochentests: werden beim naechsten Sync nicht automatisch neu erstellt
CREATE TABLE IF NOT EXISTS dismissed_tests (
    module_id INTEGER NOT NULL,
    week_no INTEGER NOT NULL,
    dismissed_at TEXT,
    PRIMARY KEY (module_id, week_no)
);

CREATE TABLE IF NOT EXISTS modules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    semester TEXT,
    color TEXT,
    icon TEXT,
    priority INTEGER DEFAULT 2,        -- 1 niedrig, 2 normal, 3 hoch
    exam_date TEXT,
    sort INTEGER DEFAULT 0,
    created_at TEXT
);

CREATE TABLE IF NOT EXISTS study_packages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date TEXT NOT NULL,                -- YYYY-MM-DD
    module_id INTEGER REFERENCES modules(id),
    subject TEXT,
    title TEXT,
    week_no INTEGER,
    planned_minutes INTEGER DEFAULT 0,
    status TEXT DEFAULT 'geplant',     -- geplant | in_bearbeitung | erledigt | teilweise | nachholen | verschoben | uebersprungen
    sort INTEGER DEFAULT 0,
    generated INTEGER DEFAULT 1,
    created_at TEXT
);

CREATE TABLE IF NOT EXISTS study_tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    package_id INTEGER NOT NULL REFERENCES study_packages(id) ON DELETE CASCADE,
    type TEXT NOT NULL,                -- vorlesung | uebung | test | wiederholung | frei
    file_id TEXT,
    test_id INTEGER,
    title TEXT NOT NULL,
    sort INTEGER DEFAULT 0,
    est_minutes INTEGER DEFAULT 45,
    actual_minutes INTEGER,
    status TEXT DEFAULT 'geplant',     -- geplant | in_bearbeitung | erledigt | nachholen | verschoben | uebersprungen
    done_at TEXT,
    moved_from TEXT,
    created_at TEXT
);

CREATE TABLE IF NOT EXISTS task_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id INTEGER,
    package_id INTEGER,
    old_status TEXT,
    new_status TEXT,
    old_date TEXT,
    new_date TEXT,
    note TEXT,
    at TEXT
);

CREATE TABLE IF NOT EXISTS folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    parent_id INTEGER,
    module_id INTEGER,
    color TEXT,
    created_at TEXT
);

CREATE TABLE IF NOT EXISTS terms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    start TEXT NOT NULL,
    end TEXT NOT NULL,
    active INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS course_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    module_id INTEGER,
    course_id TEXT,
    title TEXT NOT NULL,
    kind TEXT DEFAULT 'vorlesung',     -- vorlesung | uebung | tutorium | labor | seminar | sonstiges | persoenlich
    weekday INTEGER NOT NULL,          -- 0 = Montag
    start_time TEXT NOT NULL,          -- HH:MM
    end_time TEXT NOT NULL,
    room TEXT,
    lecturer TEXT,
    rrule TEXT DEFAULT 'weekly',       -- weekly | biweekly | once
    date_from TEXT,
    date_to TEXT,
    attend INTEGER DEFAULT 1,          -- 0 = dauerhaft nicht besuchen
    source TEXT DEFAULT 'manual',      -- manual | ics | ai | studip
    color TEXT,
    created_at TEXT
);

CREATE TABLE IF NOT EXISTS event_exceptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id INTEGER NOT NULL REFERENCES course_events(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    type TEXT NOT NULL,                -- skip | attend | cancelled | moved | edit
    new_date TEXT,
    new_start TEXT,
    new_end TEXT,
    note TEXT,
    created_at TEXT
);

CREATE TABLE IF NOT EXISTS schedule_imports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source TEXT,
    created_at TEXT,
    status TEXT,
    raw TEXT,
    parsed TEXT,
    confirmed INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS studip_events (
    id TEXT PRIMARY KEY,
    course_id TEXT NOT NULL,
    title TEXT,
    start TEXT,
    end TEXT,
    room TEXT,
    fetched_at TEXT
);

-- Eigener Stud.IP-Kalender (users/{id}/events.ics): Termin-IDs, die Stud.IP dem Nutzer selbst zeigt (eigene Gruppen,
-- Kurse mit Kalenderbindung). Gleiche Regel wie StudIPCalendar im Swift-Kern, siehe timetable._apply_calendar.
CREATE TABLE IF NOT EXISTS studip_calendar_dates (
    id TEXT PRIMARY KEY,               -- studip_events.id
    fetched_at TEXT
);

CREATE TABLE IF NOT EXISTS studip_series_relevance (
    series TEXT PRIMARY KEY,           -- Kurs|Wochentag|Beginn|Ende
    course_id TEXT NOT NULL,
    relevant INTEGER NOT NULL,         -- 1 = im eigenen Kalender, 0 = kuenftige Termine, aber keiner im Kalender
    decided_at TEXT
);

CREATE TABLE IF NOT EXISTS studip_schedule_entries (
    id TEXT PRIMARY KEY,               -- persoenliche Eintraege aus dem Stud.IP-Stundenplan
    title TEXT,
    weekday INTEGER,
    start TEXT,
    end TEXT,
    description TEXT,
    fetched_at TEXT
);

CREATE TABLE IF NOT EXISTS grades (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    pruefungsnr TEXT,
    text TEXT NOT NULL,
    semester TEXT,
    note TEXT,
    status TEXT,
    credits TEXT,
    versuch TEXT,
    datum TEXT,
    abschluss TEXT,
    raw TEXT,
    fetched_at TEXT,
    UNIQUE(pruefungsnr, text, semester, versuch)
);

CREATE TABLE IF NOT EXISTS qis_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT,
    finished_at TEXT,
    ok INTEGER,
    message TEXT,
    grades INTEGER DEFAULT 0,
    documents INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS qis_documents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT,
    local_path TEXT,
    fetched_at TEXT
);

CREATE TABLE IF NOT EXISTS recordings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_id TEXT NOT NULL,
    page INTEGER,
    title TEXT,
    url TEXT NOT NULL,
    duration REAL,
    created_at TEXT
);

-- Fristen aus dem Learnweb-Kalender (Abgabe faellig, Test beginnt/endet); due_at lokale Zeit 'YYYY-MM-DDTHH:MM'
CREATE TABLE IF NOT EXISTS deadlines (
    id TEXT PRIMARY KEY,                  -- lw-ev-<Moodle-Ereignis-id>
    source TEXT NOT NULL,                 -- learnweb
    course_id TEXT,                       -- lw-<Kurs-id>, NULL bei Terminen ohne Kurs
    title TEXT NOT NULL,                  -- ohne angehaengte Zeitangabe in Klammern
    full_title TEXT,                      -- Name wie im Learnweb
    kind TEXT NOT NULL,                   -- abgabe | test_ende | test_beginn | frist | termin
    module TEXT,                          -- assign | quiz | ...
    due_at TEXT NOT NULL,
    url TEXT,
    overdue INTEGER DEFAULT 0,            -- laut Learnweb ueberfaellig und noch nicht erledigt
    fetched_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_deadlines_due ON deadlines(due_at);

-- Bemerkung der Quelle zu einer Serie (LSF: Exkursion, "nur aus technischen Gruenden angezeigt"). Eigene Tabelle,
-- damit course_events und alle Antworten mit seinen Spalten unveraendert bleiben (der iPad-Kern vergleicht sie genau).
CREATE TABLE IF NOT EXISTS event_notes (
    event_id INTEGER PRIMARY KEY REFERENCES course_events(id) ON DELETE CASCADE,
    note TEXT NOT NULL,
    source TEXT,
    updated_at TEXT
);

-- Ankuendigungen der Lehrenden (Learnweb-Ankuendigungsforen, Stud.IP-News) mit erkannten Terminen (app/announcements.py)
CREATE TABLE IF NOT EXISTS announcements (
    id TEXT PRIMARY KEY,                  -- lw-post-<Beitrag> | sp-news-<id>
    source TEXT NOT NULL,                 -- learnweb | studip
    course_id TEXT,
    title TEXT NOT NULL,
    text TEXT,                            -- reiner Text (ohne HTML)
    author TEXT,
    posted_at TEXT NOT NULL,              -- ISO-8601
    url TEXT,
    discussion TEXT,                      -- lw-d-<Diskussion> (nur Learnweb)
    dates TEXT DEFAULT '[]',              -- JSON [{date, time, kind, snippet}]
    fetched_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_announcements_course ON announcements(course_id);

CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS sync_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT,
    finished_at TEXT,
    ok INTEGER,
    new_files INTEGER DEFAULT 0,
    message TEXT
);
"""

# Einmalige Vorbelegung von flashcards.last_result (siehe _init_db); woertlich auch in Migrations.swift
FLASHCARD_RESULT_BACKFILL = "UPDATE flashcards SET last_result='right' WHERE typeof(box)='integer' AND box > 1"

# Geschlossene Stapel (04.11.2026, docs/KARTEIKARTEN-STAPEL-2026-11-04.md): jede Karte gehoert zu genau einem Stapel.
# Karten ohne Stapel bekommen einen: Karten eines Dokuments den Stapel dieses Dokuments (Name = Titel, sonst Dateiname,
# sonst die Kennung), die uebrigen je Fach den Stapel "Allgemein", ohne Fach "Ohne Modul". Laeuft bei jedem Start und
# vor dem Lesen der Karten und Stapel (idempotent: nur Karten mit stack_id NULL, etwa nach einem Abgleich mit einem
# aelteren Geraet); woertlich auch in Migrations.swift (flashcardStackSQL).
FLASHCARD_STACK_SQL = (
    "INSERT INTO flashcard_stacks(name, subject, file_id, created_at) "
    "SELECT COALESCE(NULLIF(f.title, ''), NULLIF(f.name, ''), fc.file_id), MAX(fc.subject), fc.file_id, MIN(fc.created_at) "
    "FROM flashcards fc LEFT JOIN files f ON f.id = fc.file_id "
    "WHERE fc.stack_id IS NULL AND fc.file_id IS NOT NULL AND fc.file_id <> '' "
    "AND NOT EXISTS (SELECT 1 FROM flashcard_stacks s WHERE s.file_id = fc.file_id) GROUP BY fc.file_id",
    "UPDATE flashcards SET stack_id = (SELECT s.id FROM flashcard_stacks s WHERE s.file_id = flashcards.file_id ORDER BY s.id LIMIT 1) "
    "WHERE stack_id IS NULL AND file_id IS NOT NULL AND file_id <> ''",
    "INSERT INTO flashcard_stacks(name, subject, file_id, created_at) "
    "SELECT CASE WHEN fc.subject IS NULL OR fc.subject = '' THEN 'Ohne Modul' ELSE 'Allgemein' END, NULLIF(fc.subject, ''), NULL, MIN(fc.created_at) "
    "FROM flashcards fc WHERE fc.stack_id IS NULL "
    "AND NOT EXISTS (SELECT 1 FROM flashcard_stacks s WHERE s.file_id IS NULL AND s.subject IS NULLIF(fc.subject, '') "
    "AND s.name = CASE WHEN fc.subject IS NULL OR fc.subject = '' THEN 'Ohne Modul' ELSE 'Allgemein' END) GROUP BY NULLIF(fc.subject, '')",
    "UPDATE flashcards SET stack_id = (SELECT s.id FROM flashcard_stacks s WHERE s.file_id IS NULL AND s.subject IS NULLIF(flashcards.subject, '') "
    "AND s.name = CASE WHEN flashcards.subject IS NULL OR flashcards.subject = '' THEN 'Ohne Modul' ELSE 'Allgemein' END ORDER BY s.id LIMIT 1) "
    "WHERE stack_id IS NULL",
)


def ensure_flashcard_stacks(conn) -> None:
    """FLASHCARD_STACK_SQL ausfuehren (Start und vor dem Lesen der Karten); ohne Karten ohne Stapel ohne Wirkung."""
    for sql in FLASHCARD_STACK_SQL:
        conn.execute(sql)

DEFAULT_SETTINGS = {
    "hours_per_day": "4",
    "free_days": "[6]",            # Sonntag frei
    "day_start": "09:00",
    "test_default_minutes": "90",
    "auto_plan": "1",
    "auto_tests": "1",
    # Lernkombination (interaktiver Lernkalender)
    "subjects_per_day": "2",
    "parts_lecture": "1",
    "parts_exercise": "1",
    "tests_per_subject": "0",      # ohne Testaufgaben (Entscheidung 2 vom 25.10.2026, keine KI noetig)
    "test_minutes": "45",
    "break_minutes": "15",
    "exam_priority": "1",
    "auto_suggest": "1",
    "theme": "auto", "user_name": "", "lan_pin": "",
    # Verfuegbarkeit (Stundenplan)
    "learn_start": "08:00",
    "learn_end": "21:00",
    "travel_minutes": "30",
    "min_slot_minutes": "30",
    "blocked_times": "[]",           # [{"weekday":0,"start":"12:00","end":"13:00","title":"Mittag"}]
    "pen_input": "all",              # all | pen_only
    "hand": "right",                 # Schreibhand: right | left (geteilte Ansicht: Skript auf der freien Seite)
}


def now_iso() -> str:
    return datetime.now().replace(microsecond=0).isoformat()


_schema_done: set = set()
_schema_lock = __import__("threading").Lock()


def schema_once(conn: sqlite3.Connection, key: str, path, fn) -> None:
    """Schema-Arbeit (CREATE IF NOT EXISTS, Spalten anhaengen) je Datei nur einmal je Prozess statt bei jeder
    Verbindung (Pruefung P8, 28.10.2026: im Dienst lief `executescript(SCHEMA)` bei jeder Anfrage, mehrfach). Eine neu
    angelegte oder ersetzte Datei (andere Erstellungszeit oder Dateinummer, z. B. in Tests) bekommt das Schema erneut."""
    import os
    try:
        st = os.stat(path)
        ident = (key, str(path), st.st_ino, st.st_ctime_ns)
    except OSError:
        ident = None
    if ident is not None and ident in _schema_done:
        return
    with _schema_lock:
        fn(conn)
        if ident is not None:
            _schema_done.add(ident)


_wal_done: set = set()
_wal_lock = __import__("threading").Lock()


def wal_once(conn: sqlite3.Connection, path) -> None:
    """WAL-Modus je Datenbankdatei einmal je Prozess einschalten, nicht bei jeder Verbindung (04.11.2026). Der Wechsel
    schreibt in den Dateikopf: liefen zwei Verbindungen gleichzeitig `PRAGMA journal_mode=WAL` auf einer neuen Datei,
    hielten beide die Lesesperre und wollten schreiben - SQLite bricht dann sofort mit 'database is locked' ab, ohne
    das Zeitlimit (busy_timeout) zu nutzen. Gilt fuer alle Oeffner derselben Datei (Schluessel ist nur der Pfad, z. B.
    accounts.cursor und billing.connect auf accounts.db). Unter der Sperre wird erst der aktuelle Modus gelesen; nur
    eine Datei im alten Modus wird umgestellt. WAL bleibt in der Datei gespeichert. Eine neu angelegte oder ersetzte
    Datei (andere Dateinummer oder Aenderungszeit) wird erneut geprueft, wie bei schema_once."""
    import os
    try:
        st = os.stat(path)
        ident = (str(path), st.st_ino, st.st_ctime_ns)       # vor dem Umstellen gelesen, siehe tests/test_db_wal_race.py
    except OSError:
        ident = None
    if ident is not None and ident in _wal_done:
        return
    with _wal_lock:
        mode = (conn.execute("PRAGMA journal_mode").fetchone() or [""])[0]
        if str(mode).lower() != "wal":
            conn.execute("PRAGMA journal_mode=WAL")
        if ident is not None:
            _wal_done.add(ident)
            try:                                            # der Wechsel aendert die Zeit der Datei: auch den neuen Stand merken
                st = os.stat(path)
                _wal_done.add((str(path), st.st_ino, st.st_ctime_ns))
            except OSError:
                pass


def connect() -> sqlite3.Connection:
    from . import config
    # hosted: Datenbank des angemeldeten Kontos; sonst DB_PATH (Modulvariable, von Werkzeugen und Tests umlenkbar)
    p = config.db_path() if config.current_user_id() else DB_PATH
    conn = sqlite3.connect(p, check_same_thread=False, timeout=15)      # timeout = busy_timeout 15 s je Verbindung
    conn.row_factory = sqlite3.Row
    wal_once(conn, p)
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


class UniversityMismatch(RuntimeError):
    """Der Datenordner gehoert zu einer anderen Hochschule: lieber nicht starten als Daten vermischen."""


_FINGERPRINT: int | None = None


def schema_fingerprint() -> int:
    """Kennzahl des Schema-Codes (db.py, weekly.py, sync.py als Bytes, CRC32, positiv): steht sie als `PRAGMA
    user_version` in einer Konto-Datenbank, hat genau dieser Code-Stand `_init_db` dort schon vollstaendig ausgefuehrt.
    Jede Aenderung an einer der drei Dateien ergibt eine andere Zahl, dann laeuft die Schema-Arbeit wieder."""
    global _FINGERPRINT
    if _FINGERPRINT is None:
        import os
        import zlib
        here = os.path.dirname(os.path.abspath(__file__))
        data = b""
        for n in ("db.py", "weekly.py", "sync.py"):
            p = os.path.join(here, n)
            if os.path.exists(p):
                with open(p, "rb") as f:
                    data += f.read()
        _FINGERPRINT = (zlib.crc32(data) & 0x7FFFFFFF) or 1
    return _FINGERPRINT


def init_db() -> None:
    """Schema der (Konto-)Datenbank anlegen bzw. nachziehen. Schnellpfad (08.11.2026, Launch mit 4.000 Konten): tragt
    die Datei die Kennzahl dieses Code-Stands (`schema_fingerprint`), ist nichts zu tun - nur die Hochschule wird
    geprueft. Vorher kostete der erste Kontakt jedes Kontos in jedem API-Prozess die ganze Schema-Arbeit (41 Tabellen,
    Migrationen, ~55 ms); bei 12 Prozessen und 4.000 Konten 48.000-mal nach jedem Neustart."""
    from . import config
    conn = connect()
    try:
        mark = schema_fingerprint()
        if (conn.execute("PRAGMA user_version").fetchone() or [0])[0] == mark:
            owner = conn.execute("SELECT value FROM settings WHERE key='university'").fetchone()
            if owner is not None and owner[0] != config.university():
                raise UniversityMismatch(f"Der Datenordner {config.data_dir()} gehoert zur Hochschule '{owner[0]}', "
                                         f"die App laeuft fuer '{config.university()}'. Es werden keine Daten gemischt.")
            return
        with conn:                      # Transaktion; schliesst die Verbindung NICHT (sqlite3), daher finally
            _init_db(conn)
        conn.execute(f"PRAGMA user_version={mark}")
    finally:
        conn.close()


def _init_db(conn) -> None:
    from . import config
    conn.executescript(SCHEMA)
    # Jede Datenbank gehoert genau einer Hochschule (Schutz gegen vertauschte Datenordner)
    uni = config.university()
    # OR IGNORE: zwei API-Prozesse koennen die Datenbank beim ersten Start gleichzeitig anlegen (Server 06.11.2026)
    conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES ('university', ?)", (uni,))
    owner = conn.execute("SELECT value FROM settings WHERE key='university'").fetchone()
    if owner is not None and owner[0] != uni:
        raise UniversityMismatch(f"Der Datenordner {config.data_dir()} gehoert zur Hochschule '{owner[0]}', "
                                 f"die App laeuft fuer '{uni}'. Es werden keine Daten gemischt.")
    for k, v in DEFAULT_SETTINGS.items():
        conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)", (k, v))
    # Migrationen fuer bestehende Datenbanken
    def add_col(table, col, decl):
        cols = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
        if col not in cols:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
    add_col("annotations", "version", "INTEGER DEFAULT 1")
    add_col("files", "studip_folder", "TEXT")
    add_col("courses", "module_id", "INTEGER")
    add_col("courses", "semester_end", "TEXT")          # Titel des letzten Semesters laut Stud.IP, 'unbegrenzt' oder NULL
    add_col("courses", "semester_ends_at", "TEXT")      # Ende dieses Semesters (ISO) oder NULL
    add_col("courses", "active_custom", "INTEGER DEFAULT 0")   # vom Nutzer selbst geschaltet: der Abgleich laesst es
    add_col("modules", "active_custom", "INTEGER DEFAULT 0")
    add_col("files", "favorite", "INTEGER DEFAULT 0")
    add_col("files", "last_opened", "TEXT")
    add_col("files", "last_page", "INTEGER DEFAULT 1")
    add_col("files", "opened_count", "INTEGER DEFAULT 0")
    add_col("files", "folder_id", "INTEGER")
    add_col("files", "kind", "TEXT DEFAULT 'pdf'")        # pdf | notebook | whiteboard | image | file
    # Stud.IP-Dateien bekamen frueher immer kind=pdf (auch .py/.zip/.gif) -> Editor versuchte sie als PDF zu laden
    conn.execute("""UPDATE files SET kind = CASE
                        WHEN lower(name) GLOB '*.png' OR lower(name) GLOB '*.jpg' OR lower(name) GLOB '*.jpeg' OR lower(name) GLOB '*.gif' OR lower(name) GLOB '*.webp' THEN 'image'
                        ELSE 'file' END
                    WHERE kind = 'pdf' AND lower(name) NOT GLOB '*.pdf' AND course_id <> '__user__'""")
    add_col("files", "deleted_at", "TEXT")
    add_col("files", "title", "TEXT")
    add_col("files", "page_count", "INTEGER")
    add_col("study_packages", "start_time", "TEXT")
    add_col("study_packages", "end_time", "TEXT")
    add_col("study_tasks", "start_time", "TEXT")
    add_col("study_tasks", "end_time", "TEXT")
    add_col("modules", "active", "INTEGER DEFAULT 1")
    add_col("modules", "weekly_test", "INTEGER DEFAULT 1")
    add_col("modules", "test_minutes", "INTEGER")
    add_col("tests", "module_id", "INTEGER")
    add_col("tests", "week_no", "INTEGER")
    add_col("tests", "auto", "INTEGER DEFAULT 0")
    add_col("tests", "share_key", "TEXT")               # gemeinsamer Wochentest (app/testshare.py)
    # Varianten gemeinsamer Wochentests (04.11.2026): feste Variante 0..2 des Nutzers (testshare.variant) und woher der
    # Test uebernommen wurde (local | service | cloudkit), NULL = selbst erzeugt
    add_col("tests", "share_variant", "INTEGER")
    add_col("tests", "adopted_from", "TEXT")
    add_col("files", "content_sha256", "TEXT")          # Inhalts-Hash fuer gemeinsame Tests
    add_col("deadlines", "full_title", "TEXT")          # Learnweb-Name mit Zeitangabe (Tooltip)
    add_col("deadlines", "overdue", "INTEGER DEFAULT 0")  # laut Learnweb ueberfaellig und nicht erledigt
    conn.execute("CREATE INDEX IF NOT EXISTS ix_tests_share_key ON tests(share_key)")
    # Hoechstens ein automatischer Wochentest pro Modul und Lehrwoche
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS ux_tests_auto ON tests(module_id, week_no) WHERE auto=1")
    # Learnweb: Pluginfile-Revision (steigt beim Ersetzen); erkennt ueber die Sitzung eine neue Fassung, chdate bleibt
    # eine Unix-Zeit (studip_sync.version_stamp)
    add_col("files", "revision", "INTEGER")
    # Stud.IP (02.11.2026): Kursbeschreibung und Sonstiges des Kurses, Sitzungsthema und Ausfall je Einzeltermin
    # (abgesagte Termine bleiben gespeichert und gelten im Planer als bestaetigter Ausfall)
    add_col("courses", "description", "TEXT")
    add_col("courses", "miscellaneous", "TEXT")
    add_col("studip_events", "description", "TEXT")
    add_col("studip_events", "cancelled", "INTEGER DEFAULT 0")
    # Art des Stud.IP-Termins (Attribut `categories`: Sitzung, Klausur ...), 04.11.2026 fuer die Klausurtermine (app/exams.py)
    add_col("studip_events", "category", "TEXT")
    # Karteikarten-Trainer (03.11.2026): Lesezeichen, versteckte Karten und das letzte eigene Urteil (right | wrong |
    # NULL = noch nicht gelernt). Fach und Faelligkeit (Leitner) bleiben davon unberuehrt. Einmalig beim Anlegen der
    # Spalte: Karten ab Fach 2 kamen nur durch "richtig" dorthin und gelten als gewusst, alle anderen als ungelernt.
    add_col("flashcards", "bookmarked", "INTEGER DEFAULT 0")
    add_col("flashcards", "hidden", "INTEGER DEFAULT 0")
    if "last_result" not in {r[1] for r in conn.execute("PRAGMA table_info(flashcards)")}:
        conn.execute("ALTER TABLE flashcards ADD COLUMN last_result TEXT")
        conn.execute(FLASHCARD_RESULT_BACKFILL)
    # Geschlossene Stapel (04.11.2026): Stapel je Karte, Bestand bekommt Stapel je Dokument bzw. Fach (FLASHCARD_STACK_SQL)
    add_col("flashcards", "stack_id", "INTEGER")
    ensure_flashcard_stacks(conn)
    # Geteilte Stapel (04.11.2026, app/cardshare.py, app/community_cards.py): Herkunft eines uebernommenen Stapels und
    # die Kennung des eigenen geteilten Stapels
    add_col("flashcard_stacks", "source", "TEXT")
    add_col("flashcard_stacks", "source_ref", "TEXT")
    add_col("flashcard_stacks", "shared_id", "TEXT")
    # Fachfarben (27.10.2026, app/colors.py): neue Palette mit 12 klar verschiedenen Farben. Einmalig mit der neuen
    # Spalte color_custom (Merker fuer eine selbst gewaehlte Farbe): Farben ausserhalb der alten Palette bleiben und
    # bekommen den Merker, alle anderen Module der Reihe nach eindeutige Farben aus der neuen Palette.
    if "color_custom" not in {r[1] for r in conn.execute("PRAGMA table_info(modules)")}:
        conn.execute("ALTER TABLE modules ADD COLUMN color_custom INTEGER DEFAULT 0")
        from . import colors
        colors.migrate_palette(conn)
    # Pseudo-Kurs fuer eigene Dokumente (Notizbuecher, Whiteboards, Importe)
    conn.execute("""INSERT OR IGNORE INTO courses(id, title, number, semester, subject, kind, active, test_minutes, created_at)
                    VALUES ('__user__', 'Eigene Dokumente', NULL, NULL, NULL, 'sonstiges', 1, 90, ?)""", (now_iso(),))
    ensure_term(conn, uni)
    from . import sync
    sync.ensure_schema(conn)        # Versionsspalten, Trigger und Tombstones fuer die Geraete-Synchronisierung (G2)
    # Doppelte Module aus dem Wettlauf in study.ensure_modules (27.10.2026) zusammenfuehren; danach ohne Wirkung
    from . import study
    study.merge_duplicate_modules(conn)
    # Nur aktuelle Semester einplanen (28.10.2026, app/semesters.py): einmalig alle Kurse nach der Regel schalten
    from . import semesters
    semesters.migrate(conn)
    # Vorlesungs-Seitenmarker, Aufgabenindex, gemeinsame Wochentests (app/weekly.py, PR #6)
    from . import scriptsearch, weekly
    scriptsearch.ensure_table(conn)                 # Seitentexte (Skriptsuche), Grundlage des Aufgabenindex
    weekly.ensure_schema(conn)


def ensure_term(conn, university: str) -> None:
    """Semester fuer den Stundenplan: Vorlesungszeit laut Zeitplan der eigenen Hochschule (app/holidays.py).
    Frueher stand hier fuer alle Hochschulen die LUH-Vorlesungszeit; diese unveraenderte Vorgabe wird bei anderen
    Hochschulen korrigiert. Ein vom Nutzer eingetragenes Semester bleibt."""
    from . import holidays
    term = holidays.default_term(university) or {"name": "WiSe 2026/27", "start": "2026-10-12", "end": "2027-01-30"}
    if not conn.execute("SELECT 1 FROM terms").fetchone():
        conn.execute("INSERT INTO terms(name, start, end, active) VALUES (?, ?, ?, 1)", (term["name"], term["start"], term["end"]))
    elif university != "luh":
        conn.execute("""UPDATE terms SET name=?, start=?, end=? WHERE name='WiSe 2026/27' AND start='2026-10-12' AND end='2027-01-30'
                        AND (SELECT COUNT(*) FROM terms)=1""", (term["name"], term["start"], term["end"]))


@contextmanager
def cursor():
    conn = connect()
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def rows(conn: sqlite3.Connection, sql: str, params=()) -> list[dict]:
    return [dict(r) for r in conn.execute(sql, params).fetchall()]


def row(conn: sqlite3.Connection, sql: str, params=()) -> dict | None:
    r = conn.execute(sql, params).fetchone()
    return dict(r) if r else None


def get_settings(conn: sqlite3.Connection) -> dict:
    s = {r["key"]: r["value"] for r in conn.execute("SELECT key, value FROM settings")}
    out = dict(s)
    out["hours_per_day"] = float(s.get("hours_per_day", 4))
    out["free_days"] = json.loads(s.get("free_days", "[6]"))
    out["test_default_minutes"] = int(s.get("test_default_minutes", 90))
    out["auto_plan"] = s.get("auto_plan", "1") == "1"
    out["auto_tests"] = s.get("auto_tests", "1") == "1"
    for k, d in (("subjects_per_day", 2), ("parts_lecture", 1), ("parts_exercise", 1), ("tests_per_subject", 0),
                 ("test_minutes", 45), ("break_minutes", 15)):
        try:
            out[k] = int(s.get(k, d))
        except ValueError:
            out[k] = d
    out["exam_priority"] = s.get("exam_priority", "1") == "1"
    out["auto_suggest"] = s.get("auto_suggest", "1") == "1"
    out["minutes_per_day"] = int(out["hours_per_day"] * 60)
    out["learn_days"] = [d for d in range(7) if d not in out["free_days"]]
    for k, d in (("travel_minutes", 30), ("min_slot_minutes", 30)):
        try:
            out[k] = int(s.get(k, d))
        except ValueError:
            out[k] = d
    out["learn_start"] = s.get("learn_start", "08:00")
    out["learn_end"] = s.get("learn_end", "21:00")
    try:
        out["blocked_times"] = json.loads(s.get("blocked_times", "[]"))
    except json.JSONDecodeError:
        out["blocked_times"] = []
    out["pen_input"] = s.get("pen_input", "all")
    return out


def set_setting(conn: sqlite3.Connection, key: str, value) -> None:
    if isinstance(value, (list, dict, bool)):
        value = json.dumps(value) if not isinstance(value, bool) else ("1" if value else "0")
    conn.execute(
        "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, str(value)),
    )
