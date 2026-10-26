import Foundation

/// Schema und Migrationen 1:1 wie `app.db.init_db()`: dieselbe Datenbank, egal ob sie auf dem PC oder auf dem Geraet
/// angelegt wurde. Ein Lauf ist idempotent (jede Spalte wird ueber `PRAGMA table_info` geprueft, alles andere mit
/// IF NOT EXISTS / OR IGNORE), also bei jedem Start gefahrlos.
///
/// Reihenfolge wie in Python: Schema, Hochschule der Datenbank, Standardeinstellungen, die add_col-Folge mit der Korrektur der Dateiart
/// mittendrin, Index, Pseudokurs `__user__`, Standardsemester (`ensure_term`). Dazu `page_texts`, die Python erst bei
/// der ersten Skriptsuche anlegt. Aenderungen immer zuerst in app/db.py, dann hier und in den Fixtures
/// (tools/gen-swift-schema.py, tools/gen-schema-fixture.py).
///
/// Bekannte Abweichung: `sync.ensure_schema` (Vertrag G2, Geraete-Synchronisierung ueber UniFlow-Konten: Spalten
/// sync_version/sync_updated_at/sync_device, Trigger, Tabelle sync_tombstones) laeuft am PC am Ende von `init_db`.
/// Das iPad V1 hat keine Konten und keinen Geraete-Sync; die Spalten kommen mit G2 (SQLiteStoreTests markiert den
/// Unterschied als erwartete Abweichung).
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
        ("tests_per_subject", "0"),      // ohne Testaufgaben (Entscheidung 2 vom 25.10.2026, keine KI noetig)
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
        .addColumn("deadlines", "full_title", "TEXT"),          // Learnweb-Name mit Zeitangabe (Tooltip)
        .addColumn("deadlines", "overdue", "INTEGER DEFAULT 0"),  // laut Learnweb ueberfaellig und nicht erledigt
        .sql("CREATE INDEX IF NOT EXISTS ix_tests_share_key ON tests(share_key)"),
        // Hoechstens ein automatischer Wochentest pro Modul und Lehrwoche
        .sql("CREATE UNIQUE INDEX IF NOT EXISTS ux_tests_auto ON tests(module_id, week_no) WHERE auto=1"),
        // Learnweb: Pluginfile-Revision (steigt beim Ersetzen); erkennt ueber die Sitzung eine neue Fassung, chdate bleibt
        // eine Unix-Zeit (studip_sync.version_stamp, UniStore.versionStamp)
        .addColumn("files", "revision", "INTEGER"),
    ]

    /// Reine Geraete-Umzuege ueber `PRAGMA user_version`: nur fuer Aenderungen, die es in app/db.py nicht gibt (etwa
    /// Tabellen oder Werte nur fuer das Geraet). Alles aus Python laeuft oben ohne Versionsnummer, damit eine
    /// Datenbank vom PC und eine vom Geraet gleich behandelt werden; jeder Schritt laeuft genau einmal je Datenbank.
    public struct DeviceStep: Sendable {
        public let version: Int32
        public let apply: @Sendable (SQLiteConnection) throws -> Void

        public init(version: Int32, apply: @escaping @Sendable (SQLiteConnection) throws -> Void) {
            self.version = version
            self.apply = apply
        }
    }

    public static let deviceSteps: [DeviceStep] = [
        // 1: ohne PC keine Wochentests (Entscheidung 2 vom 25.10.2026). Der Standard 0 gilt ueber INSERT OR IGNORE nur
        // fuer neue Datenbanken; eine aus einem Build vor S6 (oder vom PC) behielt '1': "Plan erstellen" legte
        // Wochentest-Aufgaben an, deren "Test starten" mit 404 scheiterte (Korrektur vom 26.10.2026). Danach
        // speichert die Lernkombination ohne PC immer 0.
        DeviceStep(version: 1) { try $0.execute("UPDATE settings SET value='0' WHERE key='tests_per_subject'") },
    ]

    /// `holidays.default_term`: laufendes oder naechstes Semester laut Zeitplan (`Holidays.semesters`, die eine
    /// Tabelle wie app/holidays.py); nil, wenn der Zeitplan nichts (mehr) kennt.
    static func defaultTerm(university: String, today: String) -> (name: String, start: String, end: String)? {
        Holidays.defaultTerm(university: university, today: today).map { ($0.name, $0.start, $0.end) }
    }

    /// `db.ensure_term`: Semester fuer den Stundenplan. Frueher stand hier fuer alle Hochschulen die LUH-Vorlesungszeit;
    /// diese unveraenderte Vorgabe wird bei anderen Hochschulen korrigiert. Ein vom Nutzer eingetragenes Semester bleibt.
    static func ensureTerm(_ conn: SQLiteConnection, university: String, today: String) throws {
        let term = defaultTerm(university: university, today: today) ?? ("WiSe 2026/27", "2026-10-12", "2027-01-30")
        let values: [SQLiteValue] = [.text(term.name), .text(term.start), .text(term.end)]
        if try conn.queryOne("SELECT 1 FROM terms") == nil {
            try conn.execute("INSERT INTO terms(name, start, end, active) VALUES (?, ?, ?, 1)", values)
        } else if university != "luh" {
            try conn.execute("""
                UPDATE terms SET name=?, start=?, end=? WHERE name='WiSe 2026/27' AND start='2026-10-12' AND end='2027-01-30'
                AND (SELECT COUNT(*) FROM terms)=1
                """, values)
        }
    }

    /// Hochschule ohne Wahl (`universities.DEFAULT`, `config.UNIVERSITY` in Python; eine Quelle: `UniversityKey`)
    public static let defaultUniversity = UniversityKey.default.rawValue

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
            try ensureTerm(conn, university: university, today: clock.today)
            try conn.executeScript(SchemaSQL.pageTexts)
            // wie ensure_table: Suchform der Seitentexte (kam spaeter dazu; aeltere Zeilen fuellt `ScriptSearch.findPages`)
            if !(try conn.columnNames("page_texts")).contains("search") {
                try conn.execute("ALTER TABLE page_texts ADD COLUMN search TEXT")
            }

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

    public init(stored: String?, expected: String) {
        self.stored = stored
        self.expected = expected
    }

    public var description: String {
        "Diese Daten gehören zur Hochschule „\(Self.name(stored))“, gewählt ist „\(Self.name(expected))“. "
            + "Sie werden nicht geöffnet, damit keine Daten gemischt werden."
    }

    /// Name der Hochschule fuer die Meldung (unbekannte Schluessel unveraendert)
    static func name(_ key: String?) -> String {
        guard let key else { return "unbekannt" }
        return UniversityProfile.profile(forKey: key)?.name ?? key
    }
}

extension SQLiteDatabase {
    /// Schema anlegen bzw. bestehende Datenbank auf den aktuellen Stand bringen (bei jedem Start).
    public func migrate(clock: UniFlowClock = .system, university: String = Migrations.defaultUniversity,
                        deviceSteps: [Migrations.DeviceStep] = Migrations.deviceSteps) throws {
        try withConnection { try Migrations.migrate($0, clock: clock, university: university, deviceSteps: deviceSteps) }
    }
}
