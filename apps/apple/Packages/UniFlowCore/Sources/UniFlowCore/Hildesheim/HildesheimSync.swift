import Foundation

/// Schreibt Hochschul-Daten in die lokale Datenbank, wie `studip_sync.upsert_course` / `store_course_files`,
/// `lsf.import_plan` und `qis.run` am PC. Alle Funktionen laufen innerhalb einer Transaktion (synchron, kein await).
/// Auch fuer den Stud.IP-Abgleich (S3) gedacht: Kurs anlegen und Dateizeilen schreiben sind quellenunabhaengig.
public enum UniStore {

    public struct CourseRow: Sendable, Equatable {
        public let id: String
        public let title: String
        public let number: String?
        public let semester: String?
        public init(id: String, title: String, number: String?, semester: String?) {
            self.id = id; self.title = title; self.number = number; self.semester = semester
        }
    }

    public struct FileRow: Sendable, Equatable {
        public let id: String
        public let name: String
        public let size: Int
        public let mime: String?
        public let chdate: Int
        public let downloadURL: String
        public let folder: String?
        public init(id: String, name: String, size: Int, mime: String?, chdate: Int, downloadURL: String, folder: String?) {
            self.id = id; self.name = name; self.size = size; self.mime = mime; self.chdate = chdate
            self.downloadURL = downloadURL; self.folder = folder
        }
    }

    /// Kurs anlegen/aktualisieren; Fach und Art nur setzen, wenn noch leer (der Nutzer darf sie aendern).
    public static func upsertCourse(_ conn: SQLiteConnection, _ c: CourseRow, now: String) throws {
        let (subject, kind) = UniRules.classify(c.title)
        try conn.execute("""
            INSERT INTO courses(id, title, number, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, number=excluded.number, semester=excluded.semester
            """, [.text(c.id), .text(c.title), SQLiteValue(c.number), SQLiteValue(c.semester), .text(subject), .text(kind), .text(now)])
        try conn.execute("UPDATE courses SET subject=COALESCE(subject, ?), kind=COALESCE(kind, ?) WHERE id=?",
                         [.text(subject), .text(kind), .text(c.id)])
    }

    /// Muss die Datei (neu) geladen werden? Neu, hoeherer chdate oder lokale Datei fehlt.
    public static func needsDownload(_ conn: SQLiteConnection, _ f: FileRow, fileExists: (String) -> Bool) throws -> Bool {
        guard let row = try conn.queryOne("SELECT chdate, local_path FROM files WHERE id=?", [.text(f.id)]) else { return true }
        let chdate = row["chdate"].flatMap { $0.int } ?? 0
        guard let path = row["local_path"]?.string, !path.isEmpty else { return true }
        return chdate < f.chdate || !fileExists(path)
    }

    /// Dateizeile schreiben. `localPath`/`sha256` nur nach erfolgreichem Download (relativ zum Ordner der Hochschule).
    public static func storeFile(_ conn: SQLiteConnection, courseID: String, _ f: FileRow, localPath: String?,
                                 sha256: String?, now: String) throws {
        let exists = try conn.queryOne("SELECT 1 FROM files WHERE id=?", [.text(f.id)]) != nil
        if exists {
            try conn.execute("UPDATE files SET name=?, size=?, mime=?, chdate=?, download_url=? WHERE id=?",
                             [.text(f.name), SQLiteValue(f.size), SQLiteValue(f.mime), SQLiteValue(f.chdate), .text(f.downloadURL), .text(f.id)])
        } else {
            try conn.execute("""
                INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, first_seen, status, kind)
                VALUES (?,?,?,?,?,NULL,?,?,?, 'neu', ?)
                """, [.text(f.id), .text(courseID), .text(f.name), SQLiteValue(f.size), SQLiteValue(f.mime), SQLiteValue(f.chdate),
                      .text(f.downloadURL), .text(now), .text(UniRules.fileKind(name: f.name, mime: f.mime))])
        }
        if let folder = f.folder, !folder.isEmpty {
            try conn.execute("UPDATE files SET studip_folder=? WHERE id=?", [.text(folder), .text(f.id)])
        }
        if let localPath {
            try conn.execute("UPDATE files SET local_path=?, downloaded_at=?, content_sha256=? WHERE id=?",
                             [.text(localPath), .text(now), SQLiteValue(sha256), .text(f.id)])
        }
    }

    // MARK: LSF-Stundenplan (lsf.import_plan)

    public struct PlanResult: Sendable, Equatable {
        public var new = 0, removed = 0, kept = 0, cancelledDates = 0
    }

    static func normSemester(_ s: String?) -> String {
        (s ?? "").lowercased().filter { !$0.isWhitespace && $0 != "." }
            .replacingOccurrences(of: "wintersemester", with: "wise").replacingOccurrences(of: "sommersemester", with: "sose")
    }

    private static let nonWordRE = HText.regex("\\W+")

    static func planKey(_ title: String, _ weekday: Int, _ start: String, _ end: String, _ rrule: String, _ from: String) -> String {
        [String(HText.replace(nonWordRE, in: title.lowercased(), with: "").prefix(40)), String(weekday), start, end, rrule, from]
            .joined(separator: "|")
    }

    /// LSF-Serien (Quelle 'lsf') abgleichen: neue anlegen, nicht mehr vorhandene entfernen, bestehende samt Ausnahmen
    /// behalten; vorlesungsfreie Tage (EXDATE) als Ausfall. Andere Quellen bleiben unberuehrt.
    public static func importPlan(_ conn: SQLiteConnection, _ entries: [LSFCalendar.Entry], now: String) throws -> PlanResult {
        let termName = normSemester(try conn.queryOne("SELECT name FROM terms WHERE active=1 ORDER BY id DESC LIMIT 1")?["name"]?.string)
        var existing: [String: Int64] = [:]
        for r in try conn.query("SELECT * FROM course_events WHERE source='lsf'") {
            let key = planKey(r["title"]?.string ?? "", r["weekday"]?.int ?? 0, r["start_time"]?.string ?? "",
                              r["end_time"]?.string ?? "", r["rrule"]?.string ?? "weekly", r["date_from"]?.string ?? "")
            existing[key] = r["id"]?.int64
        }
        var want: [(String, LSFCalendar.Entry)] = []
        var wantKeys = Set<String>()
        for e in entries {
            let k = planKey(e.title, e.weekday, e.startTime, e.endTime, e.rrule, e.dateFrom)
            if wantKeys.insert(k).inserted { want.append((k, e)) }
        }
        var res = PlanResult()
        var ids: [String: Int64] = [:]
        for (k, e) in want {
            if let id = existing[k] { ids[k] = id; res.kept += 1; continue }
            var courseID: String?, moduleID: Int64?
            if let num = e.number {
                for r in try conn.query("SELECT id, module_id, semester FROM courses WHERE number=?", [.text(num)])
                where normSemester(r["semester"]?.string) == termName {
                    courseID = r["id"]?.string; moduleID = r["module_id"]?.int64
                    break
                }
            }
            try conn.execute("""
                INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule,
                                          date_from, date_to, attend, source, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1,'lsf',?)
                """, [SQLiteValue(moduleID), SQLiteValue(courseID), .text(e.title), .text(UniRules.eventKind(e.title)), SQLiteValue(e.weekday),
                      .text(e.startTime), .text(e.endTime), .text(e.room), .text(e.lecturer), .text(e.rrule), .text(e.dateFrom),
                      SQLiteValue(e.dateTo), .text(now)])
            ids[k] = conn.lastInsertRowID
            res.new += 1
        }
        for (k, id) in existing where !wantKeys.contains(k) {
            try conn.execute("DELETE FROM course_events WHERE id=?", [.integer(id)])
            res.removed += 1
        }
        for (k, e) in want {
            guard let eid = ids[k] else { continue }
            for d in e.exdates where try conn.queryOne("SELECT 1 FROM event_exceptions WHERE event_id=? AND date=?", [.integer(eid), .text(d)]) == nil {
                try conn.execute("INSERT INTO event_exceptions(event_id, date, type, note, created_at) VALUES (?,?, 'cancelled', ?, ?)",
                                 [.integer(eid), .text(d), .text("fällt aus laut LSF"), .text(now)])
                res.cancelledDates += 1
            }
        }
        try conn.execute("INSERT INTO schedule_imports(source, created_at, status, raw, parsed, confirmed) VALUES ('lsf-auto', ?, 'auto', '', ?, 1)",
                         [.text(now), .text("{\"neu\": \(res.new), \"entfernt\": \(res.removed)}")])
        return res
    }

    // MARK: Notenspiegel (qis.run)

    public static func storeGrades(_ conn: SQLiteConnection, _ grades: [GradeRows.Grade], now: String) throws {
        for g in grades {
            try conn.execute("""
                INSERT INTO grades(pruefungsnr, text, semester, note, status, credits, versuch, datum, abschluss, raw, fetched_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(pruefungsnr, text, semester, versuch) DO UPDATE SET note=excluded.note, status=excluded.status,
                  credits=excluded.credits, datum=excluded.datum, abschluss=excluded.abschluss, raw=excluded.raw, fetched_at=excluded.fetched_at
                """, [SQLiteValue(g["pruefungsnr"]), .text(g["text"] ?? ""), SQLiteValue(g["semester"]), SQLiteValue(g["note"]),
                      SQLiteValue(g["status"]), SQLiteValue(g["credits"]), SQLiteValue(g["versuch"]), SQLiteValue(g["datum"]),
                      .text(g.abschluss), .text(g.raw), .text(now)])
        }
    }
}

/// Abgleich Uni Hildesheim auf dem Geraet: Learnweb (Kurse, Dateien), LSF (Stundenplan, Noten).
///
/// Ausfallsicher: Netz zuerst, dann je Kurs eine kurze Transaktion; ein Fehler betrifft nur diesen Kurs bzw. diese
/// Datei. Nichts wird geloescht, weil die Gegenseite nicht antwortet; LSF-Serien verschwinden nur nach einem
/// vollstaendig gelesenen Plan. Downloads gehen erst in eine .part-Datei und ersetzen eine gute Datei nie halb.
public actor HildesheimSync {

    public struct Report: Sendable, Equatable {
        public var courses = 0
        public var newFiles: [String] = []
        public var failedFiles: [String] = []
        public var failedCourses: [String] = []
        public var plan: UniStore.PlanResult?
        public var grades: Int?
        /// verstaendliche Meldungen fuer die Statusleiste
        public var messages: [String] = []
        /// Neu anmelden noetig (Learnweb oder LSF)
        public var needsLogin: [String] = []
        public var ok: Bool { failedCourses.isEmpty && needsLogin.isEmpty }
    }

    private let db: SQLiteDatabase
    /// Ordner der Hochschule (`UniversityStorage.containerPath`); Dateien unter files/<id>/<name>
    private let root: URL
    private let learnweb: LearnwebAPI?
    private let lsf: LSFClient?
    private let transport: UniTransport
    private let clock: UniFlowClock
    private let hasher: @Sendable (URL) throws -> String

    public init(db: SQLiteDatabase, root: URL, learnweb: LearnwebAPI?, lsf: LSFClient?, transport: UniTransport,
                clock: UniFlowClock = .system,
                hasher: @escaping @Sendable (URL) throws -> String = { try SolutionSHA256.hex(Data(contentsOf: $0)) }) {
        self.db = db
        self.root = root
        self.learnweb = learnweb
        self.lsf = lsf
        self.transport = transport
        self.clock = clock
        self.hasher = hasher
    }

    /// Neu anmelden noetig (abgelaufene Sitzung oder ungueltiger Schluessel)
    static func isLoginError(_ error: Error) -> Bool {
        switch error as? HildesheimError {
        case .sessionExpired?, .invalidToken?: return true
        default: return false
        }
    }

    public static func relativePath(fileID: String, name: String) -> String {
        "files/\(StudIPImport.safeFileName(fileID))/\(StudIPImport.safeFileName(name))"
    }

    /// semesterFilter: nur Kurse, deren Semester den Text enthaelt (wie HILDESHEIM_SEMESTER_FILTER)
    public func run(semesterFilter: String? = nil, includeGrades: Bool = true) async -> Report {
        var report = Report()
        let started = clock.nowISO
        if let learnweb { await syncLearnweb(learnweb, filter: semesterFilter, into: &report) }
        if let lsf {
            await syncPlan(lsf, into: &report)
            if includeGrades { await syncGrades(lsf, into: &report) }
        }
        let message = report.messages.joined(separator: ", ")
        _ = try? await db.execute("INSERT INTO sync_log(started_at, finished_at, ok, new_files, message) VALUES (?,?,?,?,?)",
                                  [.text(started), .text(clock.nowISO), .integer(report.ok ? 1 : 0),
                                   .integer(Int64(report.newFiles.count)), .text(message)])
        return report
    }

    private func syncLearnweb(_ api: LearnwebAPI, filter: String?, into report: inout Report) async {
        let courses: [Learnweb.Course]
        do {
            courses = try await api.courses().filter { c in
                !c.hidden && (filter.map { f in f.isEmpty || c.semester.lowercased().contains(f.lowercased()) } ?? true)
            }
        } catch let e as HildesheimError {
            if Self.isLoginError(e) { report.needsLogin.append("Learnweb") }
            report.messages.append("Learnweb: \(e.description)")
            return
        } catch {
            report.messages.append("Learnweb: \(error)")
            return
        }
        report.courses = courses.count
        for c in courses {
            do {
                let files = try await api.files(moodleID: c.moodleID)
                // Netz: noetige Downloads vor der Transaktion
                let rows = files.map { UniStore.FileRow(id: $0.id, name: $0.name, size: $0.size, mime: $0.mime, chdate: $0.chdate,
                                                         downloadURL: $0.downloadURL, folder: $0.folder) }
                let rootPath = root.path
                let todo = try await db.withConnection { conn in
                    try rows.filter { try UniStore.needsDownload(conn, $0, fileExists: { FileManager.default.fileExists(atPath: rootPath + "/" + $0) }) }
                }
                var stored: [String: (String, String?)] = [:]
                for (f, row) in zip(files, rows) where todo.contains(row) {
                    do {
                        guard let req = await api.downloadRequest(f) else { continue }
                        stored[row.id] = try await download(req, fileID: row.id, name: row.name, shownURL: row.downloadURL)
                        report.newFiles.append(row.id)
                    } catch {
                        report.failedFiles.append(row.name)
                        if Self.isLoginError(error), !report.needsLogin.contains("Learnweb") { report.needsLogin.append("Learnweb") }
                    }
                }
                let now = clock.nowISO
                let course = UniStore.CourseRow(id: c.id, title: c.title, number: c.number, semester: c.semester)
                let snapshot = stored
                try await db.transaction { conn in
                    try UniStore.upsertCourse(conn, course, now: now)
                    for row in rows {
                        let s = snapshot[row.id]
                        try UniStore.storeFile(conn, courseID: course.id, row, localPath: s?.0, sha256: s?.1, now: now)
                    }
                }
            } catch {
                report.failedCourses.append(c.title)
                if Self.isLoginError(error), !report.needsLogin.contains("Learnweb") { report.needsLogin.append("Learnweb") }
            }
        }
        report.messages.append("\(report.newFiles.count) neue/geänderte Dateien aus \(courses.count) Learnweb-Kursen"
                               + (report.failedFiles.isEmpty ? "" : ", \(report.failedFiles.count) Dateien später erneut"))
    }

    /// Download in eine .part-Datei, Pruefung (keine Webseite), dann atomar ersetzen; Rueckgabe (Pfad, SHA-256)
    private func download(_ req: UniRequest, fileID: String, name: String, shownURL: String) async throws -> (String, String?) {
        let rel = Self.relativePath(fileID: fileID, name: name)
        let target = root.appendingPathComponent(rel)
        let part = target.appendingPathExtension("part")
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: part) }
        let resp = try await UniRetry().run { try await transport.download(req, to: part) }
        if HildesheimCAS.isCASPage(resp.finalURL?.absoluteString ?? "") { throw HildesheimError.sessionExpired("Learnweb") }
        guard resp.status == 200 else { throw HildesheimError.http(status: resp.status, url: shownURL) }
        let handle = try? FileHandle(forReadingFrom: part)
        let head = handle?.readData(ofLength: 64) ?? Data()
        try? handle?.close()
        let start = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isHTMLName = name.lowercased().hasSuffix(".html") || name.lowercased().hasSuffix(".htm")
        if !isHTMLName && (start.hasPrefix("<!doctype html") || start.hasPrefix("<html")) { throw HildesheimError.htmlInsteadOfFile(shownURL) }
        // rename ersetzt atomar: entweder die alte oder die neue Datei, nie eine halbe
        guard rename(part.path, target.path) == 0 else { throw HildesheimError.badResponse("Datei nicht gespeichert: \(name)") }
        return (rel, try? hasher(target))
    }

    private func syncPlan(_ lsf: LSFClient, into report: inout Report) async {
        do {
            guard let entries = try await lsf.planEntries() else {
                report.messages.append("LSF-Stundenplan ist leer")
                return
            }
            let now = clock.nowISO
            let r = try await db.transaction { conn in try UniStore.importPlan(conn, entries, now: now) }
            report.plan = r
            report.messages.append("Stundenplan: \(r.new) neu, \(r.kept) unverändert, \(r.removed) entfernt")
        } catch {
            if Self.isLoginError(error) { report.needsLogin.append("LSF") }
            report.messages.append("LSF-Stundenplan: \((error as? HildesheimError)?.description ?? "\(error)")")
        }
    }

    private func syncGrades(_ lsf: LSFClient, into report: inout Report) async {
        let started = clock.nowISO
        do {
            let grades = try await lsf.grades()
            let now = clock.nowISO
            try await db.transaction { conn in
                try UniStore.storeGrades(conn, grades, now: now)
                try conn.execute("INSERT INTO qis_runs(started_at, finished_at, ok, message, grades, documents) VALUES (?,?,1,?,?,0)",
                                 [.text(started), .text(now), .text("\(grades.count) Leistungen"), .integer(Int64(grades.count))])
            }
            report.grades = grades.count
            report.messages.append("Notenspiegel: \(grades.count) Leistungen")
        } catch {
            if Self.isLoginError(error), !report.needsLogin.contains("LSF") { report.needsLogin.append("LSF") }
            let msg = (error as? HildesheimError)?.description ?? "\(error)"
            _ = try? await db.execute("INSERT INTO qis_runs(started_at, finished_at, ok, message, grades, documents) VALUES (?,?,0,?,0,0)",
                                      [.text(started), .text(clock.nowISO), .text("FEHLER: \(msg)")])
            report.messages.append("Notenspiegel: \(msg)")
        }
    }
}
