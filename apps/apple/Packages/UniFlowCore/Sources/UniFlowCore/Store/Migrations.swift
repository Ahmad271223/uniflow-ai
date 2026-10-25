import Foundation

/// Schema und Migrationen 1:1 wie `app.db.init_db()`: dieselbe Datenbank, egal ob sie auf dem PC oder auf dem Geraet
/// angelegt wurde. Ein Lauf ist idempotent (jede Spalte wird ueber `PRAGMA table_info` geprueft, alles andere mit
/// IF NOT EXISTS / OR IGNORE), also bei jedem Start gefahrlos.
///
/// Reihenfolge wie in Python: Schema, Hochschule der Datenbank, Standardeinstellungen, die add_col-Folge mit der Korrektur der Dateiart
/// mittendrin, Index, Pseudokurs `__user__`, Standardsemester. Dazu `page_texts`, die Python erst bei der ersten
/// Skriptsuche anlegt. Aenderungen immer zuerst in app/db.py, dann hier und in den Fixtures
/// (tools/gen-swift-schema.py, tools/gen-schema-fixture.py).
public enum Migrations {
    /// `DEFAULT_SETTINGS` aus app/db.py, in derselben Reihenfolge (gleiche rowid-Folge in `settings`).
    public static let defaultSettings: [(key: String, value: String)] = [
        ("hours_per_day", "4"),
        ("free_days", "[6]"),            // Sonntag frei
        ("day_start", "09:00"),
        ("test_default_minutes", "90"),
        ("auto_plan", "1"),
        ("auto_tests", "1"),
        // Lernkombination (interaktiver Lernkalender)
        ("subjects_per_day", "2"),
        ("parts_lecture", "1"),
        ("parts_exercise", "1"),
        ("tests_per_subject", "1"),
        ("test_minutes", "45"),
        ("break_minutes", "15"),
        ("exam_priority", "1"),
        ("auto_suggest", "1"),
        ("theme", "auto"), ("user_name", ""), ("lan_pin", ""),
        // Verfuegbarkeit (Stundenplan)
        ("learn_start", "08:00"),
        ("learn_end", "21:00"),
        ("travel_minutes", "30"),
        ("min_slot_minutes", "30"),
        ("blocked_times", "[]"),         // [{"weekday":0,"start":"12:00","end":"13:00","title":"Mittag"}]
        ("pen_input", "all"),            // all | pen_only
        ("hand", "right"),               // Schreibhand: right | left (geteilte Ansicht: Skript auf der freien Seite)
    ]

    enum Step {
        /// `add_col(table, col, decl)`: Spalte anhaengen, wenn sie fehlt
        case addColumn(String, String, String)
        /// feste Anweisung
        case sql(String)
    }

    /// Die Migrationen fuer bestehende Datenbanken aus `init_db()`, woertlich und in derselben Reihenfolge.
    static let steps: [Step] = [
        .addColumn("annotations", "version", "INTEGER DEFAULT 1"),
        .addColumn("files", "studip_folder", "TEXT"),
        .addColumn("courses", "module_id", "INTEGER"),
        .addColumn("files", "favorite", "INTEGER DEFAULT 0"),
        .addColumn("files", "last_opened", "TEXT"),
        .addColumn("files", "last_page", "INTEGER DEFAULT 1"),
        .addColumn("files", "opened_count", "INTEGER DEFAULT 0"),
        .addColumn("files", "folder_id", "INTEGER"),
        .addColumn("files", "kind", "TEXT DEFAULT 'pdf'"),        // pdf | notebook | whiteboard | image | file
        // Stud.IP-Dateien bekamen frueher immer kind=pdf (auch .py/.zip/.gif) -> Editor versuchte sie als PDF zu laden
        .sql("""
            UPDATE files SET kind = CASE
                WHEN lower(name) GLOB '*.png' OR lower(name) GLOB '*.jpg' OR lower(name) GLOB '*.jpeg' OR lower(name) GLOB '*.gif' OR lower(name) GLOB '*.webp' THEN 'image'
                ELSE 'file' END
            WHERE kind = 'pdf' AND lower(name) NOT GLOB '*.pdf' AND course_id <> '__user__'
            """),
        .addColumn("files", "deleted_at", "TEXT"),
        .addColumn("files", "title", "TEXT"),
        .addColumn("files", "page_count", "INTEGER"),
        .addColumn("study_packages", "start_time", "TEXT"),
        .addColumn("study_packages", "end_time", "TEXT"),
        .addColumn("study_tasks", "start_time", "TEXT"),
        .addColumn("study_tasks", "end_time", "TEXT"),
        .addColumn("modules", "active", "INTEGER DEFAULT 1"),
        .addColumn("modules", "weekly_test", "INTEGER DEFAULT 1"),
        .addColumn("modules", "test_minutes", "INTEGER"),
        .addColumn("tests", "module_id", "INTEGER"),
        .addColumn("tests", "week_no", "INTEGER"),
        .addColumn("tests", "auto", "INTEGER DEFAULT 0"),
        .addColumn("tests", "share_key", "TEXT"),               // gemeinsamer Wochentest (app/testshare.py)
        .addColumn("files", "content_sha256", "TEXT"),          // Inhalts-Hash fuer gemeinsame Tests
        .sql("CREATE INDEX IF NOT EXISTS ix_tests_share_key ON tests(share_key)"),
        // Hoechstens ein automatischer Wochentest pro Modul und Lehrwoche
        .sql("CREATE UNIQUE INDEX IF NOT EXISTS ux_tests_auto ON tests(module_id, week_no) WHERE auto=1"),
    ]

    /// Reine Geraete-Umzuege ueber `PRAGMA user_version`: nur fuer kuenftige Aenderungen, die es in app/db.py nicht
    /// gibt (etwa Tabellen nur fuer das Geraet). Alles aus Python laeuft oben ohne Versionsnummer, damit eine
    /// Datenbank vom PC und eine vom Geraet gleich behandelt werden. Heute leer.
    public struct DeviceStep: Sendable {
        public let version: Int32
        public let apply: @Sendable (SQLiteConnection) throws -> Void

        public init(version: Int32, apply: @escaping @Sendable (SQLiteConnection) throws -> Void) {
            self.version = version
            self.apply = apply
        }
    }

    public static let deviceSteps: [DeviceStep] = []

    /// Hochschule dieser App (V1 nur LUH, `config.UNIVERSITY` in Python)
    public static let defaultUniversity = "luh"

    /// Alles in einer Transaktion: bricht ein Schritt ab, bleibt die Datenbank im alten Stand. Gehoert die Datenbank
    /// einer anderen Hochschule, bricht der Lauf mit `UniversityMismatch` ab (wie `init_db`), nichts wird geaendert.
    public static func migrate(_ conn: SQLiteConnection, clock: UniFlowClock = .system,
                               university: String = Migrations.defaultUniversity,
                               deviceSteps: [DeviceStep] = Migrations.deviceSteps) throws {
        try conn.transaction { conn in
            try conn.executeScript(SchemaSQL.schema)
            // Jede Datenbank gehoert genau einer Hochschule (Schutz gegen vertauschte Datenordner)
            if let owner = try conn.queryOne("SELECT value FROM settings WHERE key='university'") {
                guard owner[0].string == university else {
                    throw UniversityMismatch(stored: owner[0].string, expected: university)
                }
            } else {
                try conn.execute("INSERT INTO settings(key, value) VALUES ('university', ?)", [.text(university)])
            }
            for (key, value) in defaultSettings {
                try conn.execute("INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)", [.text(key), .text(value)])
            }
            for step in steps {
                switch step {
                case .addColumn(let table, let column, let decl):
                    if !(try conn.columnNames(table)).contains(column) {
                        try conn.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(decl)")
                    }
                case .sql(let sql):
                    try conn.execute(sql)
                }
            }
            // Pseudo-Kurs fuer eigene Dokumente (Notizbuecher, Whiteboards, Importe)
            try conn.execute("""
                INSERT OR IGNORE INTO courses(id, title, number, semester, subject, kind, active, test_minutes, created_at)
                VALUES ('__user__', 'Eigene Dokumente', NULL, NULL, NULL, 'sonstiges', 1, 90, ?)
                """, [.text(clock.nowISO)])
            if try conn.queryOne("SELECT 1 FROM terms") == nil {
                try conn.execute("INSERT INTO terms(name, start, end, active) VALUES ('WiSe 2026/27', '2026-10-12', '2027-01-30', 1)")
            }
            try conn.executeScript(SchemaSQL.pageTexts)

            var version = try conn.scalar("PRAGMA user_version")?.int64 ?? 0
            for step in deviceSteps.sorted(by: { $0.version < $1.version }) where Int64(step.version) > version {
                try step.apply(conn)
                version = Int64(step.version)
                try conn.execute("PRAGMA user_version = \(step.version)")
            }
        }
    }
}

/// `db.UniversityMismatch`: Der Datenordner gehoert zu einer anderen Hochschule. Lieber nicht oeffnen als Daten mischen.
public struct UniversityMismatch: Error, Equatable, CustomStringConvertible {
    /// Hochschule laut Datenbank (nil, wenn der Eintrag kein Text ist)
    public let stored: String?
    public let expected: String

    public var description: String {
        "Diese Daten gehören zur Hochschule „\(stored ?? "unbekannt")“, die App läuft für „\(expected)“. "
            + "Es werden keine Daten gemischt."
    }
}

extension SQLiteDatabase {
    /// Schema anlegen bzw. bestehende Datenbank auf den aktuellen Stand bringen (bei jedem Start).
    public func migrate(clock: UniFlowClock = .system, university: String = Migrations.defaultUniversity,
                        deviceSteps: [Migrations.DeviceStep] = Migrations.deviceSteps) throws {
        try withConnection { try Migrations.migrate($0, clock: clock, university: university, deviceSteps: deviceSteps) }
    }
}
