import Foundation

/// LSF-Stundenplan und Notenspiegel in die lokale Datenbank, wie `lsf.import_plan` und `qis.run` am PC. Kurse und
/// Dateien schreibt `UniStore` in UniStore.swift (dieselbe Fassung fuer Stud.IP und Learnweb). Alle Funktionen laufen
/// innerhalb einer Transaktion (synchron, kein await).
extension UniStore {

    // MARK: LSF-Stundenplan (lsf.import_plan)

    public struct PlanResult: Sendable, Equatable {
        public var new = 0, removed = 0, kept = 0, cancelledDates = 0
    }

    /// `_norm_sem`: klein, ohne Leerraum und Punkte, "wintersemester" -> "wise", "sommersemester" -> "sose"
    static func normSemester(_ s: String?) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: PyText.lower(s ?? "").unicodeScalars.filter { !PyText.isSpace($0) && $0 != "." })
        return String(v).replacingOccurrences(of: "wintersemester", with: "wise").replacingOccurrences(of: "sommersemester", with: "sose")
    }

    /// `_key(e)`: Titel ohne Nicht-Wortzeichen (klein, hoechstens 40 Zeichen), Wochentag, Beginn, Ende, Rhythmus, erster Tag
    static func planKey(_ e: [String: JSONValue]) -> String {
        var title = String.UnicodeScalarView()
        title.append(contentsOf: PyText.lower(e["title"]?.string ?? "").unicodeScalars.filter(LocalTimetableImport.isWordChar).prefix(40))
        let rrule = LocalTimetable.or(e["rrule"], "weekly").string ?? "weekly"
        let from = LocalTimetable.or(e["date_from"], "").string ?? ""
        return [String(title), String(e["weekday"]?.int ?? 0), e["start_time"]?.string ?? "", e["end_time"]?.string ?? "", rrule, from]
            .joined(separator: "|")
    }

    /// LSF-Serien (Quelle 'lsf') uebernehmen wie `lsf.import_plan`: Kurs ueber Nummer und Semester, Modul wie beim
    /// Stundenplan-Import geraten (`enrich`), neue Serien ueber `apply_import` (`LocalTimetableImport.applyImport`),
    /// nicht mehr vorhandene entfernen, bestehende samt Ausnahmen und Teilnahme behalten; vorlesungsfreie Tage
    /// (EXDATE) als Ausfall "fällt aus laut LSF" fuer neue und bestehende Serien, ohne Doppelte. Andere Quellen
    /// (manuell, Stud.IP, ICS-Import) bleiben unberuehrt.
    public static func importPlan(_ conn: SQLiteConnection, _ plan: [LSFCalendar.Entry], clock: UniFlowClock) throws -> PlanResult {
        let termName = normSemester(try LocalTimetable.term(conn)["name"]?.string)
        var entries: [[String: JSONValue]] = []
        for p in plan {
            var e = p.json
            var course: [String: JSONValue]?
            if let number = p.number, !number.isEmpty {
                for r in try conn.rows("SELECT id, module_id, semester FROM courses WHERE number=?", [.text(number)])
                where normSemester(r["semester"]?.string) == termName {
                    course = r
                    break
                }
            }
            e["course_id"] = course?["id"] ?? .null
            e["module_id"] = course?["module_id"] ?? .null
            entries.append(e)
        }
        entries = try LocalTimetableImport.enrich(conn, entries)
        var existing: [String: [String: JSONValue]] = [:]
        for x in try conn.rows("SELECT * FROM course_events WHERE source='lsf' ORDER BY id") { existing[planKey(x)] = x }
        var want: [(key: String, entry: [String: JSONValue])] = []
        var wantKeys = Set<String>()
        for e in entries {
            let k = planKey(e)
            if wantKeys.insert(k).inserted { want.append((k, e)) }
        }
        let new = want.filter { existing[$0.key] == nil }
        let removed = existing.filter { !wantKeys.contains($0.key) }.compactMap { $0.value["id"] }
        // Ausfaelle legt import_plan unten selbst an (Notiz "laut LSF", auch fuer bestehende Serien), nicht apply_import
        let res = try LocalTimetableImport.applyImport(conn, new.map { n in var e = n.entry; e["exdates"] = .null; return .object(e) },
                                                       source: "lsf", removeIDs: removed, clock: clock)
        var ids: [String: JSONValue] = [:]
        for (k, x) in existing where wantKeys.contains(k) { ids[k] = x["id"] ?? .null }
        for (n, id) in zip(new, res["ids"]?.array ?? []) { ids[n.key] = id }
        var cancelled = 0
        for (k, e) in want {
            guard let eid = ids[k], LocalModules.truthy(eid) else { continue }
            let event = try LocalTimetable.bind(eid, "event_id")
            for d in e["exdates"]?.array?.compactMap(\.string) ?? []
            where try conn.queryOne("SELECT 1 FROM event_exceptions WHERE event_id=? AND date=?", [event, .text(d)]) == nil {
                try conn.execute("INSERT INTO event_exceptions(event_id, date, type, note, created_at) VALUES (?,?, 'cancelled', ?, ?)",
                                 [event, .text(d), .text("fällt aus laut LSF"), .text(clock.nowISO)])
                cancelled += 1
            }
        }
        try conn.execute("INSERT INTO schedule_imports(source, created_at, status, raw, parsed, confirmed) VALUES ('lsf-auto', ?, 'auto', '', ?, 1)",
                         [.text(clock.nowISO), .text(JSONValue.array(new.map { .object($0.entry) }).jsonString(sortedKeys: true))])
        return PlanResult(new: res["new"]?.int ?? 0, removed: removed.count, kept: want.count - new.count, cancelledDates: cancelled)
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
/// Ablauf wie `hildesheim.sync_learnweb` am PC: alle Kurse (`UniStore.upsertCourse`), dann je Kurs Dateiliste
/// (`UniStore.storeFiles`), Downloads und je geladene Datei `UniStore.markDownloaded`, dieselben Funktionen wie der
/// Stud.IP-Abgleich. Ausfallsicher: kein Netz in einer Transaktion, jede Transaktion kurz; ein Fehler betrifft nur
/// diesen Kurs bzw. diese Datei. Nichts wird geloescht, weil die Gegenseite nicht antwortet; LSF-Serien verschwinden
/// nur nach einem vollstaendig gelesenen Plan. Downloads gehen erst in eine .part-Datei und ersetzen eine gute Datei
/// nie halb; eine neue Fassung, die nicht ankam, laedt der naechste Abgleich.
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
    /// Inhalts-Hash einer geladenen Datei (`content_sha256`); die App darf CryptoKit einsetzen (schneller)
    private let hasher: @Sendable (URL) -> String?
    private let retry: UniRetry

    public init(db: SQLiteDatabase, root: URL, learnweb: LearnwebAPI?, lsf: LSFClient?, transport: UniTransport,
                clock: UniFlowClock = .system, retry: UniRetry = UniRetry(),
                hasher: @escaping @Sendable (URL) -> String? = { TestShare.contentHash(file: $0) }) {
        self.db = db
        self.root = root
        self.learnweb = learnweb
        self.lsf = lsf
        self.transport = transport
        self.clock = clock
        self.retry = retry
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
            let now = clock.nowISO
            try await db.transaction { conn in
                for c in courses {
                    try UniStore.upsertCourse(conn, UniStore.CourseRow(id: c.id, title: c.title, number: c.number, semester: c.semester), now: now)
                }
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
        let rootPath = root.path
        // Jeder Kurs einzeln: ein Fehler in einem Kurs verwirft nicht die schon geholten Dateien
        for c in courses {
            do {
                let files = try await api.files(moodleID: c.moodleID)
                let now = clock.nowISO
                let todo = try await db.transaction { conn in
                    try UniStore.storeFiles(conn, courseID: c.id, files.map(\.row), now: now,
                                            fileExists: { FileManager.default.fileExists(atPath: rootPath + "/" + $0) })
                }
                for row in todo {
                    guard let f = files.first(where: { $0.id == row.id }) else { continue }
                    do {
                        guard let req = await api.downloadRequest(f) else { continue }
                        let (rel, sha) = try await download(req, fileID: row.id, name: row.name, shownURL: row.downloadURL)
                        let at = clock.nowISO
                        try await db.transaction { try UniStore.markDownloaded($0, row, localPath: rel, sha256: sha, now: at) }
                        report.newFiles.append(row.id)
                    } catch {
                        report.failedFiles.append(row.name)
                        if Self.isLoginError(error), !report.needsLogin.contains("Learnweb") { report.needsLogin.append("Learnweb") }
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

    /// Download wie `stream_download` am PC: in eine .part-Datei (Wiederholung bei abgerissener Verbindung),
    /// Pruefung (keine Anmelde- oder andere Webseite, `UniStore.isWebPage`), dann atomar ersetzen.
    /// Rueckgabe (Pfad relativ zum Ordner der Hochschule, Inhalts-Hash)
    private func download(_ req: UniRequest, fileID: String, name: String, shownURL: String) async throws -> (String, String?) {
        let rel = Self.relativePath(fileID: fileID, name: name)
        let target = root.appendingPathComponent(rel)
        let part = target.appendingPathExtension("part")
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: part) }
        let resp = try await retry.run { try await transport.download(req, to: part) }
        if HildesheimCAS.isCASPage(resp.finalURL?.absoluteString ?? "") { throw HildesheimError.sessionExpired("Learnweb") }
        guard resp.status == 200 else { throw HildesheimError.http(status: resp.status, url: shownURL) }
        if UniStore.isWebPage(file: part, name: name) { throw HildesheimError.htmlInsteadOfFile(shownURL) }
        // rename ersetzt atomar: entweder die alte oder die neue Datei, nie eine halbe
        guard rename(part.path, target.path) == 0 else { throw HildesheimError.badResponse("Datei nicht gespeichert: \(name)") }
        return (rel, hasher(target))
    }

    private func syncPlan(_ lsf: LSFClient, into report: inout Report) async {
        do {
            guard let entries = try await lsf.planEntries() else {
                report.messages.append("LSF-Stundenplan ist leer")
                return
            }
            let clock = self.clock
            let r = try await db.transaction { conn in try UniStore.importPlan(conn, entries, clock: clock) }
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
