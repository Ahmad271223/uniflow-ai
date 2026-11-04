import Foundation

/// Zwischenspeicher des Dokument-Index im Container (`page_index`, nur auf dem Geraet, erst bei Bedarf angelegt wie
/// `page_ocr`), die Katalogangaben einer Datei fuer das Regal, das Regal selbst (nur eigene Dateien) und die Verweise auf
/// eigene Notizen. Gespeichert wird je Datei-SHA und Seite der geprueft entschluesselte Eintrag (JSON) - nie Seitentext,
/// nie ein Bild. Seite 0 ist die Zusammenfassung der Datei (`DocIndexFileSummary`).
enum DocIndexStore {
    static let tableSQL = """
        CREATE TABLE IF NOT EXISTS page_index (
            file_sha TEXT NOT NULL,
            page INTEGER NOT NULL,
            page_hash TEXT NOT NULL,
            content TEXT,                      -- JSON des Eintrags (DocIndexPageRecord bzw. DocIndexFileSummary), NULL bei failed
            status TEXT NOT NULL DEFAULT 'ok', -- ok | failed
            attempts INTEGER NOT NULL DEFAULT 0,
            source TEXT,                       -- ai (selbst gebaut) | cloud (uebernommen)
            shared INTEGER NOT NULL DEFAULT 0, -- 1 = beim Dienst gespeichert
            created_at TEXT,
            updated_at TEXT,
            PRIMARY KEY (file_sha, page))
        """
    /// so oft wird eine Seite hoechstens gebaut (ein Versuch, zwei Wiederholungen)
    static let maxAttempts = 3

    struct Row: Equatable, Sendable {
        var fileSHA: String
        var page: Int
        var pageHash: String
        var content: JSONValue?
        var status: String
        var attempts: Int
        var source: String?
        var shared: Bool
        var createdAt: String?
        var updatedAt: String?

        var isOK: Bool { status == "ok" && content != nil }
    }

    static func ensureTable(_ c: SQLiteConnection) throws { try c.executeScript(tableSQL) }

    static func hasTable(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='page_index'") != nil
    }

    private static func row(_ r: SQLiteRow) -> Row {
        Row(fileSHA: r["file_sha"]?.string ?? "", page: r["page"]?.int ?? 0, pageHash: r["page_hash"]?.string ?? "",
            content: r["content"]?.string.flatMap { try? JSONValue.parse($0) }, status: r["status"]?.string ?? "ok",
            attempts: r["attempts"]?.int ?? 0, source: r["source"]?.string, shared: (r["shared"]?.int ?? 0) != 0,
            createdAt: r["created_at"]?.string, updatedAt: r["updated_at"]?.string)
    }

    /// Alle Zeilen einer Datei (Seite 0 zuerst)
    static func rows(_ c: SQLiteConnection, fileSHA: String) throws -> [Row] {
        guard try hasTable(c) else { return [] }
        return try c.query("SELECT * FROM page_index WHERE file_sha=? ORDER BY page", [.text(fileSHA)]).map(row)
    }

    static func row(_ c: SQLiteConnection, fileSHA: String, page: Int) throws -> Row? {
        guard try hasTable(c) else { return nil }
        return try c.queryOne("SELECT * FROM page_index WHERE file_sha=? AND page=?", [.text(fileSHA), .integer(Int64(page))]).map(row)
    }

    /// Eintrag speichern (ersetzt einen gescheiterten); `shared` = schon beim Dienst
    static func store(_ c: SQLiteConnection, fileSHA: String, page: Int, pageHash: String, content: JSONValue, source: String,
                      shared: Bool, now: String) throws {
        try ensureTable(c)
        let existing = try c.queryOne("SELECT created_at FROM page_index WHERE file_sha=? AND page=?", [.text(fileSHA), .integer(Int64(page))])
        try c.execute("""
            INSERT OR REPLACE INTO page_index(file_sha, page, page_hash, content, status, attempts, source, shared, created_at, updated_at)
            VALUES (?,?,?,?,'ok',0,?,?,?,?)
            """, [.text(fileSHA), .integer(Int64(page)), .text(pageHash), .text(content.jsonString(sortedKeys: true)), .text(source),
                  .integer(shared ? 1 : 0), .text(existing?["created_at"]?.string ?? now), .text(now)])
    }

    /// Gescheiterten Versuch zaehlen; Rueckgabe: Versuche bisher
    @discardableResult
    static func markFailed(_ c: SQLiteConnection, fileSHA: String, page: Int, pageHash: String, now: String) throws -> Int {
        try ensureTable(c)
        let before = try row(c, fileSHA: fileSHA, page: page)
        let attempts = (before?.status == "failed" ? before?.attempts ?? 0 : 0) + 1
        try c.execute("""
            INSERT OR REPLACE INTO page_index(file_sha, page, page_hash, content, status, attempts, source, shared, created_at, updated_at)
            VALUES (?,?,?,NULL,'failed',?,NULL,0,?,?)
            """, [.text(fileSHA), .integer(Int64(page)), .text(pageHash), .integer(Int64(attempts)), .text(before?.createdAt ?? now), .text(now)])
        return attempts
    }

    static func markShared(_ c: SQLiteConnection, fileSHA: String, page: Int) throws {
        try c.execute("UPDATE page_index SET shared=1 WHERE file_sha=? AND page=?", [.text(fileSHA), .integer(Int64(page))])
    }

    /// Zahlen fuer `GET /api/index/status`
    static func counts(_ c: SQLiteConnection) throws -> (files: Int, pages: Int, failed: Int, unshared: Int) {
        guard try hasTable(c) else { return (0, 0, 0, 0) }
        let files = try c.scalar("SELECT COUNT(DISTINCT file_sha) FROM page_index WHERE page=0 AND status='ok'")?.int ?? 0
        let pages = try c.scalar("SELECT COUNT(*) FROM page_index WHERE page>0 AND status='ok'")?.int ?? 0
        let failed = try c.scalar("SELECT COUNT(*) FROM page_index WHERE status='failed'")?.int ?? 0
        let unshared = try c.scalar("SELECT COUNT(*) FROM page_index WHERE status='ok' AND shared=0 AND source='ai'")?.int ?? 0
        return (files, pages, failed, unshared)
    }

    // MARK: Datei und Katalog

    /// Was der Index ueber eine Datei wissen muss (aus files, courses, modules, analysis; Einordnung wie die Bibliothek)
    struct FileMeta: Equatable, Sendable {
        var fileID: String
        var name: String
        var title: String?
        var sha: String?
        var localPath: String?
        var courseID: String
        var courseTitle: String
        var courseSemester: String?
        var moduleID: Int?
        var moduleName: String
        var docType: String
        var subLabel: String
        var week: Int
        /// Datum der Aenderung (YYYY-MM-DD, Berliner Ortszeit), "" ohne Datum
        var date: String
        var chdate: SQLiteValue
        var pageCount: Int?
        var deleted: Bool

        var kind: (kind: String, label: String) { DocIndexCatalog.kind(docType: docType, subLabel: subLabel) }
        /// Anzeigename der Datei (wie die Bibliothek: KI-Titel, Titel, Name)
        var displayTitle: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? name }
    }

    static let fileSQL = """
        SELECT f.id, f.name, f.title, f.content_sha256, f.local_path, f.chdate, f.course_id, f.studip_folder, f.page_count, f.deleted_at,
               f.download_url, c.title AS course_title, c.kind AS course_kind, c.module_id, c.semester AS course_semester,
               a.doc_type, a.title AS ai_title, m.name AS module_name
        FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id LEFT JOIN modules m ON m.id=c.module_id
        """

    static func fileMeta(_ c: SQLiteConnection, fileID: String, clock: UniFlowClock) throws -> FileMeta? {
        guard let r = try c.queryOne(fileSQL + " WHERE f.id=?", [.text(fileID)]) else { return nil }
        return try fileMeta(c, r, dates: LocalModules.Dates(c, clock: clock))
    }

    static func fileMeta(_ c: SQLiteConnection, _ r: SQLiteRow, dates: LocalModules.Dates) throws -> FileMeta {
        let enriched = StudyClassify.enrichFile(r.json)
        let docType = enriched["doc_type"]?.string ?? "sonstiges", subLabel = enriched["sub_label"]?.string ?? ""
        let chdate = r["chdate"] ?? .null
        let week = try LocalModules.week(docType: docType, subLabel: subLabel, weekHint: enriched["week_hint"]?.int, chdate: chdate,
                                         start: dates.start, today: dates.today)
        let date = StudyWeeks.isEmpty(chdate: chdate) ? "" : BerlinClock.isoDate(try StudyWeeks.localDay(chdate: chdate))
        let courseTitle = r["course_title"]?.string ?? ""
        let moduleName = r["module_name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? CommunityKeys.moduleName(courseTitle: courseTitle)
        let aiTitle = r["ai_title"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        return FileMeta(fileID: r["id"]?.string ?? "", name: r["name"]?.string ?? "", title: aiTitle ?? r["title"]?.string,
                        sha: r["content_sha256"]?.string.flatMap { DocIndexFingerprint.isSHA256Hex($0.lowercased()) ? $0.lowercased() : nil },
                        localPath: r["local_path"]?.string, courseID: r["course_id"]?.string ?? "", courseTitle: courseTitle,
                        courseSemester: r["course_semester"]?.string, moduleID: r["module_id"]?.int, moduleName: moduleName,
                        docType: docType, subLabel: subLabel, week: week, date: date, chdate: chdate, pageCount: r["page_count"]?.int,
                        deleted: r["deleted_at"]?.string.map { !$0.isEmpty } ?? false)
    }

    /// Hochschule der Datenbank (Schluessel) und ihr Name
    static func university(_ c: SQLiteConnection) throws -> (key: String, name: String) {
        let key = try c.scalar("SELECT value FROM settings WHERE key='university'")?.string ?? Migrations.defaultUniversity
        return (key, UniversityProfile.profile(forKey: key)?.name ?? key)
    }

    /// Studiengang: aus dem Notenspiegel (haeufigster Abschluss), sonst "Allgemein" (Vorgabe des Inhabers)
    static func studyProgram(_ c: SQLiteConnection) throws -> String {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='grades'") != nil,
              let p = try c.scalar("""
                SELECT abschluss FROM grades WHERE abschluss IS NOT NULL AND trim(abschluss)<>''
                GROUP BY abschluss ORDER BY COUNT(*) DESC, abschluss LIMIT 1
                """)?.string, !p.isEmpty else { return DocIndexCatalog.generalProgram }
        return String(p.prefix(120))
    }

    /// Semester einer Datei: das des Kurses, sonst das aktive Semester des Stundenplans
    static func semester(_ c: SQLiteConnection, courseSemester: String?) throws -> String {
        if let s = courseSemester, !s.isEmpty { return s }
        return try c.scalar("SELECT name FROM terms WHERE active=1 ORDER BY id DESC LIMIT 1")?.string ?? ""
    }

    /// Katalogangaben einer Datei fuer das Regal; nur aus Kursdaten (Modul-Schluessel wie die Community)
    static func catalog(_ c: SQLiteConnection, meta: FileMeta) throws -> DocIndexCatalog {
        let uni = try university(c)
        let k = meta.kind
        return DocIndexCatalog(university: uni.key, studyProgram: try studyProgram(c), semester: try semester(c, courseSemester: meta.courseSemester),
                               moduleKey: CommunityKeys.moduleKey(university: uni.key, courseTitle: meta.courseTitle)
                                   ?? CommunityKeys.courseKey(university: uni.key, courseName: meta.moduleName) ?? "",
                               moduleName: meta.moduleName, week: meta.week, date: meta.date, kind: k.kind, kindLabel: k.label)
    }

    /// Pfad im Regal fuer die Anzeige: Hochschule › Studiengang › Semester › Modul › Woche › Art
    static func shelfPath(university name: String, catalog: DocIndexCatalog, weekLabel: String) -> [String] {
        [name, catalog.studyProgram, catalog.semester, catalog.moduleName, weekLabel, catalog.kindLabel].filter { !$0.isEmpty }
    }

    // MARK: Regal (nur eigene Dateien)

    /// `GET /api/index/shelf?module=`: Baum Hochschule -> Studiengang -> Semester -> Modul -> Lehrwoche + Datum -> Art ->
    /// Datei (mit Stand des Index). Feste Reihenfolge: Studiengaenge und Module nach Name, Semester neueste zuerst (nach
    /// juengster Datei, dann Name), Wochen wie das Moduldetail, Arten wie `DocIndexCatalog.kindOrder`, Dateien nach Name.
    static func shelf(_ c: SQLiteConnection, moduleID: Int?, clock: UniFlowClock) throws -> JSONValue {
        let uni = try university(c)
        let program = try studyProgram(c)
        let dates = try LocalModules.Dates(c, clock: clock)
        var sql = fileSQL + " WHERE f.deleted_at IS NULL AND f.course_id <> '__user__' AND (f.mime LIKE '%pdf' OR lower(f.name) LIKE '%.pdf')"
        var params: [SQLiteValue] = []
        if let moduleID { sql += " AND c.module_id=?"; params.append(.integer(Int64(moduleID))) }
        let metas = try c.query(sql + " ORDER BY f.name, f.id", params).map { try fileMeta(c, $0, dates: dates) }
        let index = try hasTable(c) ? Dictionary(grouping: try c.query("SELECT file_sha, page, status FROM page_index").map {
            ($0["file_sha"]?.string ?? "", $0["page"]?.int ?? 0, $0["status"]?.string ?? "")
        }, by: \.0) : [:]
        let activeTerm = try c.scalar("SELECT name FROM terms WHERE active=1 ORDER BY id DESC LIMIT 1")?.string ?? ""

        struct Leaf { let semester: String; let module: String; let moduleID: Int?; let week: Int; let kind: String; let meta: FileMeta }
        let leaves = metas.map { m in
            Leaf(semester: (m.courseSemester?.isEmpty == false ? m.courseSemester! : activeTerm), module: m.moduleName, moduleID: m.moduleID,
                 week: m.week, kind: m.kind.kind, meta: m)
        }
        func fileJSON(_ m: FileMeta) -> JSONValue {
            let rows = m.sha.flatMap { index[$0] } ?? []
            let ok = rows.filter { $0.1 > 0 && $0.2 == "ok" }.count
            let failed = rows.filter { $0.2 == "failed" }.count
            let summary = rows.contains { $0.1 == 0 && $0.2 == "ok" }
            let status = summary ? "ready" : (ok > 0 ? "partial" : "none")
            return ["file_id": .string(m.fileID), "name": .string(m.name), "title": .string(m.displayTitle), "date": .string(m.date),
                    "sha": m.sha.map(JSONValue.string) ?? .null, "page_count": m.pageCount.map { .number(Double($0)) } ?? .null,
                    "indexed_pages": .number(Double(ok)), "failed_pages": .number(Double(failed)), "status": .string(status),
                    "kind": .string(m.kind.kind), "kind_label": .string(m.kind.label)]
        }
        let semesters = Dictionary(grouping: leaves, by: \.semester)
        let semesterOrder = semesters.keys.sorted { a, b in
            let da = semesters[a]!.map(\.meta.date).max() ?? "", db = semesters[b]!.map(\.meta.date).max() ?? ""
            return da != db ? da > db : a < b
        }
        var semesterJSON: [JSONValue] = []
        for s in semesterOrder {
            let modules = Dictionary(grouping: semesters[s]!, by: \.module)
            var moduleJSON: [JSONValue] = []
            for name in modules.keys.sorted(by: PyText.less) {
                let weeks = Dictionary(grouping: modules[name]!, by: \.week)
                var weekJSON: [JSONValue] = []
                for w in weeks.keys.sorted(by: LocalModules.weekOrder) {
                    let kinds = Dictionary(grouping: weeks[w]!, by: \.kind)
                    var kindJSON: [JSONValue] = []
                    for k in DocIndexCatalog.kindOrder where kinds[k] != nil {
                        let files = kinds[k]!.sorted { ($0.meta.name, $0.meta.fileID) < ($1.meta.name, $1.meta.fileID) }
                        kindJSON.append(["kind": .string(k), "label": .string(DocIndexCatalog.kindLabels[k] ?? k),
                                         "files": .array(files.map { fileJSON($0.meta) })])
                    }
                    let days = weeks[w]!.map(\.meta.date).filter { !$0.isEmpty }
                    weekJSON.append(["week": .number(Double(w)), "label": .string(StudyWeeks.weekLabel(start: dates.start, week: w)),
                                     "from": .string(days.min() ?? ""), "to": .string(days.max() ?? ""), "kinds": .array(kindJSON)])
                }
                let first = modules[name]!.first!
                moduleJSON.append(["name": .string(name), "module_id": first.moduleID.map { .number(Double($0)) } ?? .null,
                                   "key": .string(CommunityKeys.courseKey(university: uni.key, courseName: name) ?? ""), "weeks": .array(weekJSON)])
            }
            semesterJSON.append(["name": .string(s), "modules": .array(moduleJSON)])
        }
        return ["university": ["key": .string(uni.key), "name": .string(uni.name)],
                "programs": [["name": .string(program), "semesters": .array(semesterJSON)]],
                "files": .number(Double(metas.count))]
    }

    // MARK: Eigene Notizen (nur lokal)

    /// Verweis auf eigene Notizen einer Seite derselben Datei: Seite (PDF, 1-basiert), Datum des Stands (YYYY-MM-DD)
    struct OwnNote: Equatable, Sendable {
        var page: Int
        var date: String
        var label: String { DocIndexStore.shortDate(date) }
    }

    /// "31.10." aus einem ISO-Datum oder -Zeitpunkt; leer ohne Datum
    static func shortDate(_ iso: String) -> String {
        let d = iso.prefix(10)
        guard d.count == 10 else { return "" }
        let p = d.split(separator: "-")
        guard p.count == 3 else { return "" }
        return "\(p[2]).\(p[1])."
    }

    /// Hat die Notizseite Inhalt (Objekte, Striche, PencilKit-Zeichnung)?
    static func hasContent(_ page: JSONValue) -> Bool {
        if let o = page["objects"]?.array, !o.isEmpty { return true }
        if let s = page["strokes"]?.array, !s.isEmpty { return true }
        if let d = page["pkdrawing"]?["data"]?.string, !d.isEmpty { return true }
        return false
    }

    /// Eigene Notizen zu einer Datei je PDF-Seite mit dem Datum, seit dem die Seite so aussieht (aus dem
    /// Versionsverlauf: die aelteste Fassung in Folge mit demselben Inhalt; ist die Aenderung juenger als alle
    /// Fassungen, das Speicherdatum). Nichts davon verlaesst das Geraet.
    static func ownNotes(_ c: SQLiteConnection, fileID: String) throws -> [OwnNote] {
        guard let r = try c.queryOne("SELECT data, updated_at FROM annotations WHERE file_id=?", [.text(fileID)]),
              let text = r["data"]?.string, let root = try? JSONValue.parse(text) else { return [] }
        let doc = AnnotationDocument(root: root)
        let updated = r["updated_at"]?.string ?? ""
        let versions = try c.query("SELECT data, created_at FROM annotation_versions WHERE file_id=? ORDER BY version DESC", [.text(fileID)])
            .compactMap { v -> (pages: [String: JSONValue], at: String)? in
                guard let t = v["data"]?.string, let j = try? JSONValue.parse(t) else { return nil }
                return (AnnotationDocument(root: j).pages, v["created_at"]?.string ?? "")
            }
        var out: [OwnNote] = []
        for (key, page) in doc.pages where hasContent(page) {
            let pdf = doc.pdfIndex(forPageKey: key) ?? (doc.pageOrder.isEmpty && key.hasPrefix("p") ? Int(key.dropFirst()) : nil)
            guard let pdf, pdf >= 1 else { continue }
            var date = updated
            for v in versions {
                guard let vp = v.pages[key], vp == page else { break }
                date = v.at
            }
            out.append(OwnNote(page: pdf, date: String(date.prefix(10))))
        }
        return out.sorted { $0.page < $1.page }
    }
}
