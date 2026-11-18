import Foundation

/// Datei-Eingang (Auftrag des Inhabers vom 18.11.2026): neue Kurs-PDFs gehen einmal an einen eigenen Server und werden
/// dort nach Hochschule, Studiengang, Semester und Modul geordnet, noch ohne KI. Gegenstueck: app/intake_server.py;
/// die App schickt an den StudiNow-Dienst (app/intake_api.py), der ueber das private Netz weiterreicht.
///
/// Regeln (hier an EINER Stelle):
/// - nur PDFs aus aktiven Kursen, die auf dem Geraet liegen, und nur Vorlesung, Uebung, Loesung, Skript, Klausur
///   (`docTypes`); Organisatorisches und Sonstiges nie
/// - nie eine Liste mit Namen oder Matrikelnummern (`looksLikeNameList`, gleiche Regel wie der Server)
/// - jede Datei je Platz (Studiengang, Semester, Modul) einmal: gemerkt in `intake_sent`; der Server sagt ausserdem,
///   welche Dateien er schon hat, die gehen nicht noch einmal hoch
/// - keine Konto-ID: der Dienst reicht nur Hochschule und Datei an den Eingang weiter
///
/// Ob ueberhaupt geschickt wird (Zustimmung, WLAN, Anmeldung), entscheidet die App (`CourseFileIntakeRunner`).
public enum CourseFileIntake {
    public static let docTypes: Set<String> = ["vorlesung", "uebung", "loesung", "skript", "klausur"]
    /// hoechstens so viele Dateien je Lauf (der naechste Abgleich macht weiter)
    public static let filesPerRun = 60
    public static let maxFileBytes = 80 << 20
    static let checkBatch = 100

    // MARK: Karteikarte

    public struct Meta: Sendable, Equatable {
        public var sha256: String
        public var program: String?
        public var semester: String?
        public var module: String
        public var docType: String
        public var fileName: String
        public var courseTitle: String?
        public var courseNumber: String?
        public var week: Int?
        public var pages: Int?

        public var json: JSONValue {
            func opt(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
            return ["sha256": .string(sha256), "program": opt(program), "semester": opt(semester), "module": .string(module),
                    "doc_type": .string(docType), "file_name": .string(fileName), "course_title": opt(courseTitle),
                    "course_number": opt(courseNumber), "week": week.map { .number(Double($0)) } ?? .null,
                    "pages": pages.map { .number(Double($0)) } ?? .null]
        }

        /// Schluessel des Platzes in der Ordnung (eine Datei kann in mehreren Studiengaengen stehen)
        var placeKey: String { [program ?? "", semester ?? "", module].joined(separator: "\u{1F}") }
    }

    public struct Candidate: Sendable {
        public var fileID: String
        public var url: URL
        public var meta: Meta
    }

    // MARK: Listen mit Namen

    private static let nameListWords = try! NSRegularExpression(
        pattern: "matrikel|teilnehmerliste|teilnehmer\\*innen-?liste|anwesenheitsliste|notenliste|notenspiegel|klausurergebnis"
            + "|ergebnisliste|gruppeneinteilung|sitzplan|raumverteilung|unterschrift",
        options: [.caseInsensitive])
    private static let matriculation = try! NSRegularExpression(pattern: "(?<!\\d)\\d{7,8}(?!\\d)")

    private static func count(_ re: NSRegularExpression, _ s: String) -> Int {
        re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    /// Liste mit Namen oder Matrikelnummern? Dann geht die Datei nie hoch (app/intake_server.py `looks_like_name_list`)
    public static func looksLikeNameList(text: String, fileName: String) -> Bool {
        if count(nameListWords, fileName) > 0 { return true }
        if count(matriculation, text) >= 5 { return true }
        return count(nameListWords, text) >= 2
    }

    // MARK: Auswahl

    static let candidateSQL = """
        SELECT f.id, f.name, f.chdate, f.local_path, f.content_sha256, f.page_count, f.studip_folder, f.size,
               c.title AS course_title, c.number AS course_number, c.semester, c.kind AS course_kind, c.subject,
               m.name AS module_name, a.doc_type
        FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN modules m ON m.id=c.module_id
        LEFT JOIN analysis a ON a.file_id=f.id
        WHERE COALESCE(c.active, 1)=1 AND f.deleted_at IS NULL AND f.local_path IS NOT NULL AND c.id <> '__user__'
        ORDER BY f.chdate DESC, f.id
        """

    static func ensureTable(_ c: SQLiteConnection) throws {
        try c.execute("""
            CREATE TABLE IF NOT EXISTS intake_sent (
                sha256 TEXT NOT NULL,
                place TEXT NOT NULL,
                status TEXT NOT NULL,
                at TEXT NOT NULL,
                PRIMARY KEY (sha256, place)
            )
            """)
    }

    /// Studiengang fuer die Ordnung: der im Studienverlauf gewaehlte (nil ohne Wahl)
    static func program(_ c: SQLiteConnection) throws -> String? {
        let uni = try StudyPlanAPI.university(c)
        return StudyPlanAPI.chosenProgramName(try StudyPlanAPI.loadSettings(c).po, university: uni)
    }

    /// Dateien, die noch nicht geschickt wurden, mit Karteikarte (ohne Namenslisten-Pruefung, die braucht den Text)
    static func candidates(_ c: SQLiteConnection, files: LocalFiles, limit: Int = filesPerRun) throws -> [(Candidate, needsHash: Bool)] {
        try ensureTable(c)
        let program = try program(c)
        let stored = try LectureWeeks.stored(c)
        var sent = Set<String>()
        for r in try c.query("SELECT sha256, place FROM intake_sent") {
            sent.insert((r["sha256"]?.string ?? "") + "|" + (r["place"]?.string ?? ""))
        }
        var out: [(Candidate, Bool)] = []
        for r in try c.query(candidateSQL) {
            guard out.count < limit, let id = r["id"]?.string, let name = r["name"]?.string,
                  PyText.lower(name).hasSuffix(".pdf"), let path = r["local_path"]?.string,
                  let url = files.url(stored: path), files.exists(stored: path) else { continue }
            if let size = r["size"]?.int, size > maxFileBytes { continue }
            let f = LectureWeeks.withStoredType(StudyClassify.enrichFile(r.json), stored: stored)
            guard let type = f["doc_type"]?.string, docTypes.contains(type) else { continue }
            let module = r["module_name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? r["subject"]?.string ?? r["course_title"]?.string ?? ""
            guard !module.isEmpty else { continue }
            let sha = r["content_sha256"]?.string.flatMap { $0.count == 64 ? $0.lowercased() : nil }
            let meta = Meta(sha256: sha ?? "", program: program, semester: r["semester"]?.string, module: module, docType: type,
                            fileName: name, courseTitle: r["course_title"]?.string, courseNumber: r["course_number"]?.string,
                            week: f["week_hint"]?.int, pages: r["page_count"]?.int)
            if let sha, sent.contains(sha + "|" + meta.placeKey) { continue }
            out.append((Candidate(fileID: id, url: url, meta: meta), sha == nil))
        }
        return out
    }

    // MARK: Lauf

    /// Verbindung zum Eingang (App: ueber den StudiNow-Dienst, `AccountCourseFileIntake`; Tests: Attrappe)
    public protocol Transport: Sendable {
        /// noch fehlende Fingerabdruecke; legt beim Eingang die Plaetze aller Karteikarten an
        func check(_ metas: [Meta]) async throws -> [String]
        /// eine Datei hochladen; "stored" oder "known"
        func upload(_ meta: Meta, file: URL) async throws -> String
    }

    /// Fehler des Eingangs mit Code (`name_list`, `ticket_used_up`, ...)
    public struct IntakeError: Error, Equatable, Sendable {
        public let status: Int
        public let code: String
        public init(status: Int, code: String) { self.status = status; self.code = code }
    }

    public struct Report: Sendable, Equatable {
        public var checked = 0
        public var uploaded = 0
        public var known = 0
        public var skippedNameLists = 0
        public var failed = 0
        public init() {}
    }

    /// Ein Lauf: Kandidaten bestimmen, Fingerabdruck nachholen, Namenslisten aussortieren, beim Eingang pruefen,
    /// fehlende Dateien hochladen, alles merken. Bricht beim ersten Netz- oder Grenzfehler ab (naechster Lauf).
    public static func run(_ ctx: LocalContext, transport: Transport, limit: Int = filesPerRun,
                           shouldStop: @Sendable () -> Bool = { false }) async throws -> Report {
        var report = Report()
        guard let files = ctx.files else { return report }
        let found = try await ctx.database.withConnection { try candidates($0, files: files, limit: limit) }
        var ready: [Candidate] = []
        for (cand, needsHash) in found {
            if shouldStop() { return report }
            var cand = cand
            if needsHash {
                guard let sha = ContentHash.file(cand.url) else { continue }
                cand.meta.sha256 = sha
                _ = try? await ctx.database.execute("UPDATE files SET content_sha256=? WHERE id=? AND (content_sha256 IS NULL OR content_sha256='')",
                                                    [.text(sha), .text(cand.fileID)])
            }
            let texts = (try? await ScriptSearch.pageTexts(fileID: cand.fileID, ctx: ctx, ocrScope: .none)) ?? []
            if looksLikeNameList(text: texts.prefix(3).joined(separator: "\n"), fileName: cand.meta.fileName) {
                report.skippedNameLists += 1
                try await mark(ctx, cand.meta, status: "name_list")
                continue
            }
            if cand.meta.pages == nil, !texts.isEmpty { cand.meta.pages = texts.count }
            ready.append(cand)
        }
        var index = 0
        while index < ready.count {
            if shouldStop() { return report }
            let batch = Array(ready[index..<min(index + checkBatch, ready.count)])
            index += batch.count
            let missing = Set(try await transport.check(batch.map(\.meta)))
            report.checked += batch.count
            for cand in batch where !missing.contains(cand.meta.sha256) {
                report.known += 1
                try await mark(ctx, cand.meta, status: "known")
            }
            // Ergebnis je Inhalt: gleiche Datei zweimal (zweiter Kurs, zweiter Platz) geht nur einmal hoch
            var outcome: [String: String] = [:]
            for cand in batch where missing.contains(cand.meta.sha256) {
                if shouldStop() { return report }
                if let earlier = outcome[cand.meta.sha256] {
                    // hochgeladen: dieser Platz steht beim Eingang schon (check); abgelehnt: hier genauso
                    try await mark(ctx, cand.meta, status: earlier == "uploaded" ? "known" : earlier)
                    if earlier == "uploaded" { report.known += 1 }
                    continue
                }
                let status: String
                do {
                    status = try await transport.upload(cand.meta, file: cand.url) == "known" ? "known" : "uploaded"
                } catch let e as IntakeError where e.code == "name_list" {
                    status = "name_list"
                } catch let e as IntakeError where e.status == 413 || e.status == 415 || e.code == "sha_mismatch" {
                    status = "rejected"                              // diese Datei passt nicht; nicht immer wieder versuchen
                }
                outcome[cand.meta.sha256] = status
                switch status {
                case "uploaded": report.uploaded += 1
                case "known": report.known += 1
                case "name_list": report.skippedNameLists += 1
                default: report.failed += 1
                }
                try await mark(ctx, cand.meta, status: status)
            }
        }
        return report
    }

    static func mark(_ ctx: LocalContext, _ m: Meta, status: String) async throws {
        let now = ctx.clock.nowISO
        try await ctx.database.transaction { c in
            try ensureTable(c)
            try c.execute("INSERT OR REPLACE INTO intake_sent(sha256, place, status, at) VALUES (?,?,?,?)",
                          [.text(m.sha256), .text(m.placeKey), .text(status), .text(now)])
        }
    }

    /// Wie viele Dateien schon beim Eingang sind (fuer die Einstellungen)
    public static func sentCount(_ c: SQLiteConnection) throws -> Int {
        try ensureTable(c)
        return try c.queryOne("SELECT COUNT(DISTINCT sha256) AS n FROM intake_sent WHERE status IN ('uploaded','known')")?["n"]?.int ?? 0
    }
}

// MARK: - Ueber den StudiNow-Dienst

/// Eingang ueber den StudiNow-Dienst (Umbau "ohne Domain", 18.11.2026): `POST /api/intake/check` und
/// `POST /api/intake/file` mit der Anmeldung des Kontos; der Dienst reicht ueber das private Netz an den Eingang weiter.
public struct AccountCourseFileIntake: CourseFileIntake.Transport {
    let account: StudoraAccount
    let university: String?

    public init(account: StudoraAccount, university: String?) {
        self.account = account
        self.university = university
    }

    private func call(_ path: String, body: Data, contentType: String) async throws -> JSONValue {
        do {
            let r = try await account.request("POST", path, raw: body, contentType: contentType)
            return (try? JSONValue.parse(r.body)) ?? .null
        } catch let e as AccountError {
            throw CourseFileIntake.IntakeError(status: e.status, code: e.code)
        }
    }

    public func check(_ metas: [CourseFileIntake.Meta]) async throws -> [String] {
        let body: JSONValue = ["university": university.map(JSONValue.string) ?? .null, "files": .array(metas.map(\.json))]
        return try await call("/api/intake/check", body: body.serialized(), contentType: "application/json")["missing"]?.array?
            .compactMap(\.string) ?? []
    }

    public func upload(_ meta: CourseFileIntake.Meta, file: URL) async throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let boundary = "studinow-" + UUID().uuidString
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"meta\"\r\n\r\n")
        body.append(meta.json.serialized())
        if let university {
            add("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"university\"\r\n\r\n\(university)")
        }
        add("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"datei.pdf\"\r\nContent-Type: application/pdf\r\n\r\n")
        body.append(data)
        add("\r\n--\(boundary)--\r\n")
        return try await call("/api/intake/file", body: body, contentType: "multipart/form-data; boundary=\(boundary)")["status"]?.string ?? "stored"
    }
}

extension CourseFileIntake {
    /// Hochschule dieses Datenbereichs (fuer die Ordnung beim Eingang)
    public static func university(_ c: SQLiteConnection) throws -> String { try StudyPlanAPI.university(c) }
}
