import Foundation

/// Dateien frueherer Semester (Wunsch des Inhabers 03.11.2026): "Lade nur die Dateien des aktuellen Semesters und
/// frag, ob auch fruehere Semester geladen werden sollen; spaeter in der Bibliothek je Semester-Ordner nachladen."
///
/// - Kurse frueherer Semester bleiben als Kurs bekannt (`courses`, inaktiv nach der Semesterregel `Semesters`; die
///   Community prueft "hat oder hatte das Modul" daran), ihre Dateien laedt der Abgleich aber nur auf Wunsch.
/// - Wahl je Container (`older_semester_choice`): nil = noch nicht gefragt, `current` = nur aktuelles Semester
///   (Vorgabe), `all` = Dateien aller frueheren Semester mitladen.
/// - Einzelne Kurse (Bibliothek "Dateien laden"): `older_semester_courses` mit `requested_at`; nach einem Lauf, der
///   Dateiliste und alle Downloads eines Kurses geschafft hat, `loaded_at`. Alte Semester aendern sich kaum, darum
///   fragt ein spaeterer Abgleich einen schon geladenen Kurs nicht erneut ab (erneut "Dateien laden" schon).
///
/// Ein "frueherer" Kurs: aus (`active = 0`) und nach der Semesterregel nicht aktuell. Ein von Hand eingeschalteter
/// alter Kurs (`active_custom`) ist aktiv und wird wie jeder aktuelle abgeglichen; ein von Hand ausgeschalteter
/// aktueller Kurs bleibt aus (keine Dateien).
///
/// Beide Tabellen nur auf diesem Geraet (wie `studip_file_links` erst bei Bedarf angelegt, nicht im Geraete-Abgleich):
/// was ein Geraet laedt, entscheidet es selbst. Nur die App; am PC laedt run_sync alle Kurse (SEMESTER_FILTER).
public enum OlderSemesters {
    public enum Choice: String, Sendable, Equatable {
        /// nur das aktuelle Semester (Vorgabe)
        case current
        /// Dateien frueherer Semester mitladen
        case all
    }

    /// "Ältere Semester laden" (seit 05.11.2026, `SyncOrder`, app/older_semesters.py `mode`): im selben Feld wie die
    /// Wahl gespeichert; fruehere Werte gelten weiter (`all` = Automatisch, `current` = Aus). Nie gefragt = Aus
    /// (07.11.2026, Wunsch des Inhabers): vor der Antwort auf "Auch frühere Semester laden?" laedt Stufe (d) nichts,
    /// auch nicht im WLAN; "Frühere Semester auch laden" speichert Nur WLAN.
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        case auto, wifi, off

        public var label: String {
            switch self {
            case .auto: return "Automatisch"
            case .wifi: return "Nur WLAN"
            case .off: return "Aus"
            }
        }
    }

    /// Vorgabe, solange nie gefragt: Aus (nichts Frueheres laden, bevor die Frage beantwortet ist; bis 07.11.2026
    /// Nur WLAN, dann lud Stufe (d) im WLAN schon vor der Antwort)
    public static let defaultMode = Mode.off
    /// Wahl bei "Frühere Semester auch laden" (Frage nach dem ersten Abgleich): im Hintergrund, nur im WLAN
    public static let yesMode = Mode.wifi

    static let tables = """
        CREATE TABLE IF NOT EXISTS older_semester_choice (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            choice TEXT NOT NULL,
            decided_at TEXT
        );
        CREATE TABLE IF NOT EXISTS older_semester_courses (
            course_id TEXT PRIMARY KEY,
            requested_at TEXT,
            loaded_at TEXT
        );
        """

    private static func exists(_ c: SQLiteConnection, _ table: String) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(table)]) != nil
    }

    // MARK: Wahl

    private static func raw(_ c: SQLiteConnection) throws -> String? {
        guard try exists(c, "older_semester_choice") else { return nil }
        let v = try c.queryOne("SELECT choice FROM older_semester_choice WHERE id=1")?["choice"]?.string
        return v.flatMap { Choice(rawValue: $0) != nil || Mode(rawValue: $0) != nil ? $0 : nil }
    }

    /// Gespeicherte Wahl in der frueheren Form (`current` = Aus, `all` = laden); nil = noch nicht gefragt
    public static func choice(_ c: SQLiteConnection) throws -> Choice? {
        guard let v = try raw(c) else { return nil }
        return v == Choice.current.rawValue || v == Mode.off.rawValue ? .current : .all
    }

    public static func setChoice(_ c: SQLiteConnection, _ choice: Choice, now: String) throws {
        try store(c, choice.rawValue, now: now)
    }

    /// "Ältere Semester laden": Automatisch, Nur WLAN oder Aus (auch solange nie gefragt, `defaultMode`)
    public static func mode(_ c: SQLiteConnection) throws -> Mode {
        switch try raw(c) {
        case nil: return defaultMode
        case Choice.all.rawValue: return .auto
        case Choice.current.rawValue: return .off
        case let v?: return Mode(rawValue: v) ?? defaultMode
        }
    }

    public static func setMode(_ c: SQLiteConnection, _ mode: Mode, now: String) throws {
        try store(c, mode.rawValue, now: now)
    }

    private static func store(_ c: SQLiteConnection, _ value: String, now: String) throws {
        try c.executeScript(tables)
        try c.execute("INSERT OR REPLACE INTO older_semester_choice(id, choice, decided_at) VALUES (1, ?, ?)", [.text(value), .text(now)])
    }

    // MARK: Kurse

    /// Kurs eines frueheren Semesters mit dem Stand seiner Dateien
    public struct Course: Sendable, Equatable {
        public let id: String
        public let title: String
        /// Semester zum Gruppieren (Startsemester, sonst Ende); nil ohne erkennbares Semester
        public let key: Semesters.Key?
        /// Anzeige des Semesters ("SoSe 2026"), ohne Schluessel der Text aus der Quelle
        public let label: String
        /// bekannte Dateien (ohne Papierkorb) und davon geladene
        public let files: Int
        public let downloaded: Int
        /// "Dateien laden" gewaehlt und noch nicht fertig
        public let requested: Bool
        /// Dateiliste und Downloads einmal vollstaendig
        public let loaded: Bool
    }

    /// Kurse frueherer Semester (aus und nach der Regel nicht aktuell), neueste Semester zuerst, dann nach Titel
    public static func courses(_ c: SQLiteConnection, today: String) throws -> [Course] {
        let marks = try exists(c, "older_semester_courses")
        let rows = try c.rows("""
            SELECT c.id, c.title, c.semester, c.semester_end, c.semester_ends_at,
                   (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id AND f.deleted_at IS NULL) AS files,
                   (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id AND f.deleted_at IS NULL AND COALESCE(f.local_path, '')<>'') AS downloaded
                   \(marks ? ", o.requested_at, o.loaded_at" : "")
            FROM courses c \(marks ? "LEFT JOIN older_semester_courses o ON o.course_id=c.id" : "")
            WHERE c.id <> '__user__' AND COALESCE(c.active, 1)=0
            """)
        let list: [Course] = rows.compactMap { r in
            guard let id = r["id"]?.string else { return nil }
            let semester = r["semester"]?.string, end = r["semester_end"]?.string
            guard Semesters.isCurrent(semester: semester, semesterEnd: end, endsAt: r["semester_ends_at"]?.string, today: today) == false else { return nil }
            let key = Semesters.key(semester) ?? Semesters.key(end)
            let text = [semester, end].compactMap { $0 }.first { !$0.isEmpty }
            let requested = r["requested_at"]?.string != nil
            let loaded = r["loaded_at"]?.string != nil
            return Course(id: id, title: r["title"]?.string ?? "Kurs", key: key, label: key.map(Semesters.label) ?? text ?? "Früheres Semester",
                          files: r["files"]?.int ?? 0, downloaded: r["downloaded"]?.int ?? 0, requested: requested && !loaded, loaded: loaded)
        }
        return list.sorted { a, b in
            if a.key != b.key {
                guard let ka = a.key else { return false }
                guard let kb = b.key else { return true }
                return ka > kb
            }
            if a.label != b.label { return a.label < b.label }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// Kurse frueherer Semester, deren Dateien Stufe (d) holen soll (`SyncOrder`): bei Automatisch / Nur WLAN alle
    /// noch nicht geladenen, bei "Aus" und solange nie gefragt nur die angeforderten ("Dateien laden")
    public static func pending(_ c: SQLiteConnection, today: String) throws -> Set<String> {
        let all = try mode(c) != .off
        return Set(try courses(c, today: today).filter { !$0.loaded && (all || $0.requested) }.map(\.id))
    }

    /// Frage "Auch frühere Semester laden?" noch offen: nie entschieden und es gibt Kurse frueherer Semester
    public static func needsQuestion(_ c: SQLiteConnection, today: String) throws -> Bool {
        try choice(c) == nil && !courses(c, today: today).isEmpty
    }

    /// "Dateien laden" fuer diese Kurse (auch erneut nach einem fertigen Laden): der naechste Lauf holt Dateiliste
    /// und Dateien. Rueckgabe: Zahl der Kurse frueherer Semester darunter.
    @discardableResult
    public static func request(_ c: SQLiteConnection, courseIDs: [String], today: String, now: String) throws -> Int {
        let older = Set(try courses(c, today: today).map(\.id))
        let ids = courseIDs.filter(older.contains)
        guard !ids.isEmpty else { return 0 }
        try c.executeScript(tables)
        for id in ids {
            try c.execute("""
                INSERT INTO older_semester_courses(course_id, requested_at, loaded_at) VALUES (?, ?, NULL)
                ON CONFLICT(course_id) DO UPDATE SET requested_at=excluded.requested_at, loaded_at=NULL
                """, [.text(id), .text(now)])
        }
        return ids.count
    }

    /// Dateiliste und alle Downloads dieser Kurse sind durch
    public static func markLoaded(_ c: SQLiteConnection, courseIDs: [String], now: String) throws {
        guard !courseIDs.isEmpty else { return }
        try c.executeScript(tables)
        for id in courseIDs {
            try c.execute("""
                INSERT INTO older_semester_courses(course_id, requested_at, loaded_at) VALUES (?, NULL, ?)
                ON CONFLICT(course_id) DO UPDATE SET loaded_at=excluded.loaded_at
                """, [.text(id), .text(now)])
        }
    }

    // MARK: Fuer die Bibliothek

    /// Semester-Ordner der Bibliothek: je frueheres Semester seine Kurse, neuestes zuerst
    public struct Group: Sendable, Equatable {
        public let label: String
        public let courses: [Course]
    }

    public static func groups(_ c: SQLiteConnection, today: String) throws -> [Group] {
        var out: [Group] = []
        for course in try courses(c, today: today) {
            if let last = out.last, last.label == course.label {
                out[out.count - 1] = Group(label: last.label, courses: last.courses + [course])
            } else {
                out.append(Group(label: course.label, courses: [course]))
            }
        }
        return out
    }

    /// `GET /api/older-semesters`: Wahl, aktuelles Semester und die frueheren mit ihren Kursen
    static func overview(_ c: SQLiteConnection, today: String) throws -> JSONValue {
        let groups = try groups(c, today: today)
        let choice = try choice(c)
        return [
            "choice": choice.map { .string($0.rawValue) } ?? .null,
            "mode": .string(try mode(c).rawValue),
            "current": .string(Semesters.label(SyncOrder.currentTerm(today: today, university: try SyncOrder.university(c)))),
            "progress": try SyncOrder.status(c, today: today),
            "semesters": .array(groups.map { g in
                ["label": .string(g.label), "courses": .array(g.courses.map { k in
                    ["id": .string(k.id), "title": .string(k.title), "files": .number(Double(k.files)),
                     "downloaded": .number(Double(k.downloaded)), "requested": .bool(k.requested), "loaded": .bool(k.loaded)]
                })]
            }),
        ]
    }

    /// Dateien eines Kurses (auch eines inaktiven), ohne Papierkorb; mit Einordnung wie `/api/library`
    static func courseFiles(_ c: SQLiteConnection, courseID: String) throws -> [JSONValue]? {
        guard try c.queryOne("SELECT 1 FROM courses WHERE id=?", [.text(courseID)]) != nil else { return nil }
        return try c.rows("""
            SELECT f.id, f.name, COALESCE(f.title, f.name) AS title, f.chdate, f.status, f.favorite, f.last_opened, f.folder_id, f.kind,
                   f.page_count, f.size, f.downloaded_at, f.course_id, f.studip_folder, f.download_url, f.content_sha256,
                   c.module_id, c.subject, c.kind AS course_kind, a.doc_type, a.title AS ai_title, a.difficulty,
                   (SELECT 1 FROM annotations an WHERE an.file_id=f.id) AS has_notes, (SELECT updated_at FROM annotations an WHERE an.file_id=f.id) AS edited_at,
                   CASE WHEN COALESCE(f.local_path, '')<>'' THEN 1 ELSE 0 END AS downloaded
            FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
            WHERE f.course_id=? AND f.deleted_at IS NULL ORDER BY COALESCE(f.studip_folder, ''), f.name, f.id
            """, [.text(courseID)]).map { .object(StudyClassify.enrichFile($0)) }
    }
}

/// Fruehere Semester in der Bibliothek (nur lokal, die PC-Fassung kennt das nicht): Ueberblick, Wahl, "Dateien laden"
/// und die Dateien eines Kurses. Geladen wird nicht hier, sondern im Abgleich der App (`StudIPSync`, Learnweb).
enum OlderSemesterEndpoints: LocalEndpointModule {
    static let name = "Frühere Semester"

    static func register(on router: LocalRouter) {
        router.get("/api/older-semesters") { _, ctx in
            let today = ctx.clock.today
            return .json(try await ctx.database.withConnection { try OlderSemesters.overview($0, today: today) })
        }

        router.post("/api/older-semesters/choice") { req, ctx in
            guard let raw = try req.jsonBody()["choice"]?.string, let choice = OlderSemesters.Choice(rawValue: raw) else {
                throw LocalHTTPError(status: 422, message: "choice: current oder all")
            }
            let now = ctx.clock.nowISO
            try await ctx.database.transaction { try OlderSemesters.setChoice($0, choice, now: now) }
            return .json(["choice": .string(choice.rawValue)])
        }

        router.post("/api/older-semesters/mode") { req, ctx in
            guard let raw = try req.jsonBody()["mode"]?.string, let mode = OlderSemesters.Mode(rawValue: raw) else {
                throw LocalHTTPError(status: 422, message: "mode: auto, wifi oder off")
            }
            let now = ctx.clock.nowISO
            try await ctx.database.transaction { try OlderSemesters.setMode($0, mode, now: now) }
            // geladen wird nicht hier, sondern vom Abgleich der App (`OlderSemesterLoader`), der auf die Aenderung hoert
            return .json(["mode": .string(mode.rawValue), "started": .bool(false)])
        }

        router.post("/api/older-semesters/request") { req, ctx in
            let ids = try req.jsonBody()["course_ids"]?.array?.compactMap(\.string) ?? []
            let today = ctx.clock.today, now = ctx.clock.nowISO
            let n = try await ctx.database.transaction { try OlderSemesters.request($0, courseIDs: ids, today: today, now: now) }
            return .json(["requested": .number(Double(n))])
        }

        router.get("/api/older-semesters/courses/{course_id}/files") { req, ctx in
            let id = req.param("course_id")
            guard let files = try await ctx.database.withConnection({ try OlderSemesters.courseFiles($0, courseID: id) }) else {
                throw LocalHTTPError.notFound("Kurs nicht gefunden")
            }
            return .json(.array(files))
        }
    }
}
