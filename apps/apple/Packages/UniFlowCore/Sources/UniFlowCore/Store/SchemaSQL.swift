// erzeugt von tools/gen-swift-schema.py, nicht von Hand aendern
// Quelle: app/db.py (SCHEMA) und app/scriptsearch.py (ensure_table, Tabelle page_texts)

/// Schema der Python-Referenz, woertlich. `Migrations` fuehrt es aus und bringt bestehende Datenbanken danach wie
/// `init_db()` auf den aktuellen Stand.
enum SchemaSQL {
    /// `app.db.SCHEMA`
    static let schema = #"""

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

"""#

    /// `app.scriptsearch.ensure_table` (in Python erst bei der ersten Skriptsuche angelegt)
    static let pageTexts = #"""
CREATE TABLE IF NOT EXISTS page_texts (
        file_id TEXT NOT NULL, page INTEGER NOT NULL, text TEXT, chdate INTEGER,
        PRIMARY KEY (file_id, page))
"""#
}
