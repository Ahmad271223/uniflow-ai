import Foundation

/// LSF-Stundenplan und Notenspiegel in die lokale Datenbank, wie `lsf.import_plan` und `qis.run` am PC. Kurse und
/// Dateien schreibt `UniStore` in UniStore.swift (dieselbe Fassung fuer Stud.IP und Learnweb). Alle Funktionen laufen
/// innerhalb einer Transaktion (synchron, kein await).
extension UniStore {

    // MARK: LSF-Stundenplan (lsf.import_plan)

    public struct PlanResult: Sendable, Equatable {
        public var new = 0, removed = 0, kept = 0, cancelledDates = 0
        /// Serien, die laut Bemerkung "nur aus technischen Gruenden angezeigt" werden und einmalig auf "nicht besuchen" gingen
        public var placeholders = 0
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
        // Bemerkung aus dem LSF uebernehmen (event_notes, `lsf.note_text`). Platzhalter ("nur aus technischen Gruenden
        // angezeigt") werden einmalig auf "nicht besuchen" gestellt, wenn der Hinweis neu ist; eine spaetere
        // Entscheidung des Nutzers bleibt bestehen.
        var placeholders = 0
        for (k, e) in want {
            guard let eid = ids[k], LocalModules.truthy(eid) else { continue }
            let event = try LocalTimetable.bind(eid, "event_id")
            let old = try conn.queryOne("SELECT note FROM event_notes WHERE event_id=?", [event])?["note"]?.string ?? ""
            let note = e["note"]?.string ?? ""
            guard old != note else { continue }
            if !note.isEmpty {
                try conn.execute("""
                    INSERT INTO event_notes(event_id, note, source, updated_at) VALUES (?, ?, 'lsf', ?)
                                                ON CONFLICT(event_id) DO UPDATE SET note=excluded.note, updated_at=excluded.updated_at
                    """, [event, .text(note), .text(clock.nowISO)])
            } else {
                try conn.execute("DELETE FROM event_notes WHERE event_id=?", [event])
            }
            if LSFCalendar.isPlaceholder(note), !LSFCalendar.isPlaceholder(old) {
                try conn.execute("UPDATE course_events SET attend=0 WHERE id=?", [event])
                placeholders += 1
            }
        }
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
        return PlanResult(new: res["new"]?.int ?? 0, removed: removed.count, kept: want.count - new.count, cancelledDates: cancelled,
                          placeholders: placeholders)
    }

    // MARK: Notenspiegel (qis.run)

    /// Wie `qis.store_grades`: dieselbe Leistung (Pruefungsnr., Text, Semester, Versuch) wird aktualisiert, sonst neu
    /// angelegt. Der Vergleich ist NULL-sicher (`IS`): Der Notenspiegel der Uni Hildesheim hat weder Semester noch
    /// Versuch, und fuer SQLite sind zwei NULL in einer UNIQUE-Spalte verschieden (ON CONFLICT griffe nie, jeder Abruf
    /// legte alle Leistungen noch einmal an).
    public static func storeGrades(_ conn: SQLiteConnection, _ grades: [QISGrade], now: String) throws {
        for g in grades {
            let key: [SQLiteValue] = [SQLiteValue(g.pruefungsnr), .text(g.text), SQLiteValue(g.semester), SQLiteValue(g.versuch)]
            let values: [SQLiteValue] = [SQLiteValue(g.note), SQLiteValue(g.status), SQLiteValue(g.credits), SQLiteValue(g.datum),
                                         .text(g.abschluss ?? ""), .text(g.raw), .text(now)]
            let updated = try conn.execute("""
                UPDATE grades SET note=?, status=?, credits=?, datum=?, abschluss=?, raw=?, fetched_at=?
                WHERE pruefungsnr IS ? AND text=? AND semester IS ? AND versuch IS ?
                """, values + key)
            if updated > 0 { continue }
            try conn.execute("""
                INSERT INTO grades(note, status, credits, datum, abschluss, raw, fetched_at, pruefungsnr, text, semester, versuch)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """, values + key)
        }
    }
}

/// Abgleich Uni Hildesheim auf dem Geraet: Learnweb (Kurse, Dateien), LSF (Stundenplan, Noten).
///
/// Ablauf wie `hildesheim.sync_learnweb` am PC: alle Kurse (`UniStore.upsertCourse`), dann je aktivem Kurs Dateiliste
/// (Semesterregel und eigene Schalter wie beim Stud.IP-Abgleich: Kurse frueherer Semester bleiben samt ihren Dateien
/// gespeichert, bekommen aber keine neuen Dateien und keine Ankuendigungen; Wunsch des Inhabers 28.10.2026, am PC
/// `hildesheim.active_courses` seit a7827c6)
/// (`UniStore.storeFiles`), Downloads und je geladene Datei `UniStore.markDownloaded` ueber `UniDownloads`, dieselben
/// Funktionen wie der Stud.IP-Abgleich. Ausfallsicher: kein Netz in einer Transaktion, jede Transaktion kurz; ein
/// Fehler betrifft nur diesen Kurs bzw. diese Datei. Nichts wird geloescht, weil die Gegenseite nicht oder leer
/// antwortet; LSF-Serien verschwinden nur nach einem vollstaendig gelesenen Plan (`LSFClient.planEntries`). Downloads
/// gehen erst in eine .part-Datei und ersetzen eine gute Datei nie halb und nie durch eine leere; eine neue Fassung,
/// die nicht ankam, laedt der naechste Abgleich. Laeuft die Anmeldung ab oder wird der Lauf abgebrochen
/// (`Task.cancel`), endet der Learnweb-Teil; die uebrigen Kurse stehen in `notAttempted` und gelten nicht als Fehler.
/// Wie beim Stud.IP-Abgleich bleibt ueber `UniDownloads` (S7) die alte Fassung einer Datei mit Notizen erhalten und
/// die Notizen kommen auf die passenden Seiten der neuen (`FileVersionKeeper`, alte Fassungen unter
/// `Learnweb/Fassungen`); die Seitentexte jeder geladenen PDF fuellen den Suchindex (`tools`, in der App PDFKit).
///
/// Speicher: der Container (Apple-Nutzer, Uni Hildesheim) wie beim Stud.IP-Abgleich der LUH (`DataContainerLayout`).
/// Downloads unter `Learnweb/files/<id>/<name>`, `files.local_path` relativ zum Container. Passt der Container oder
/// seine Datenbank nicht zur Uni Hildesheim (`UniversityMismatch`, anderes Konto) oder fehlt seine Kennzeichnung
/// (geloescht), laeuft nichts; vor jedem Schreiben einer Datei wird das erneut geprueft (`UniDownloads`).
public actor HildesheimSync {

    public struct Report: Sendable, Equatable {
        public var courses = 0
        public var newFiles: [String] = []
        public var failedFiles: [String] = []
        public var failedCourses: [String] = []
        public var plan: UniStore.PlanResult?
        public var grades: Int?
        /// Learnweb-Fristen und Ankuendigungen (nach den Dateien; ein Fehler dort stoppt den Lauf nicht)
        public var deadlines: Announcements.StoreResult?
        public var announcements: Announcements.StoreResult?
        /// verstaendliche Meldungen fuer die Statusleiste
        public var messages: [String] = []
        /// Neu anmelden noetig (Learnweb oder LSF)
        public var needsLogin: [String] = []
        /// Lauf abgebrochen (z. B. Ansicht geschlossen): kein Fehler der Kurse
        public var cancelled = false
        /// Learnweb-Kurse, die wegen abgelaufener Anmeldung oder Abbruch nicht (fertig) abgefragt wurden
        public var notAttempted: [String] = []
        /// Learnweb-Kurse frueherer Semester (`courses.active` = 0 nach der Semesterregel oder vom Nutzer
        /// ausgeschaltet): gespeichert, aber ohne Dateiliste, Downloads und Ankuendigungen
        public var olderCourses: [String] = []
        /// nur Listen (`downloads: false`, Hintergrund S8): Dateien, die der naechste volle Abgleich laedt
        public var waiting = 0
        /// Container oder Datenbank gehoeren nicht zur Uni Hildesheim bzw. diesem Konto: nichts abgeglichen
        public var refused: String?
        /// Teile, die ohne Fehler zu Ende gelaufen sind (`Part`), in dieser Reihenfolge; fuer den Stand je Quelle in
        /// der Statusleiste der App ("Learnweb: 16:30 ok"). Ein Learnweb-Lauf mit einzelnen Kursfehlern zaehlt mit
        /// (die Kurse stehen in `failedCourses` und in der Meldung), einer ohne lesbaren Kurs, ein abgebrochener oder
        /// an der Anmeldung gescheiterter nicht.
        public var completed: [String] = []
        public var ok: Bool { failedCourses.isEmpty && needsLogin.isEmpty && !cancelled && refused == nil }

        /// leerer Bericht (die App, wenn sie keinen Teil abfragen kann, z. B. Learnweb-Schluessel fehlt)
        public init() {}

        /// Namen der Teile in `completed`
        public enum Part {
            public static let learnweb = "Learnweb"
            public static let plan = "LSF-Stundenplan"
            public static let grades = "Notenspiegel"
        }
    }

    private let db: SQLiteDatabase
    /// Container der Hochschule (`DataContainerLayout`); Dateien unter `Learnweb/`
    private let container: DataContainerLayout
    private let learnweb: LearnwebAPI?
    private let lsf: LSFClient?
    private let transport: UniTransport
    private let clock: UniFlowClock
    private let retry: UniRetry
    /// Seitentexte geladener PDFs fuer Suche und Seitenzuordnung einer neuen Fassung (S7; App: PDFKit, ohne: keine)
    private let tools: LocalDocumentTools

    public init(db: SQLiteDatabase, container: DataContainerLayout, learnweb: LearnwebAPI?, lsf: LSFClient?, transport: UniTransport,
                clock: UniFlowClock = .system, retry: UniRetry = UniRetry(), tools: LocalDocumentTools = NoDocumentTools()) {
        self.db = db
        self.container = container
        self.learnweb = learnweb
        self.lsf = lsf
        self.transport = transport
        self.clock = clock
        self.retry = retry
        self.tools = tools
    }

    /// Neu anmelden noetig (abgelaufene Sitzung oder ungueltiger Schluessel)
    static func isLoginError(_ error: Error) -> Bool {
        switch error as? HildesheimError {
        case .sessionExpired?, .invalidToken?: return true
        default: return false
        }
    }

    /// Abbruch ist kein Fehler (auch `URLError(.cancelled)` einer abgebrochenen Aufgabe)
    static func isCancellation(_ error: Error) -> Bool { error is CancellationError || Task.isCancelled }

    /// Meldung ohne Adressen: `URLError` traegt die volle Adresse (mit sesskey) in seiner Beschreibung
    static func describe(_ error: Error) -> String {
        (error as? HildesheimError)?.description ?? (error as? UniversityMismatch)?.description ?? (error as? DataContainerError)?.description
            ?? (error as NSError).localizedDescription
    }

    /// semesterFilter: nur Kurse, deren Semester den Text enthaelt (wie HILDESHEIM_SEMESTER_FILTER). `downloads: false`
    /// (kurzer Hintergrundlauf, S8): Kurse und Dateilisten wie immer in die Datenbank, aber keine Downloads; die
    /// Dateien stehen in `waiting` und kommen mit dem naechsten vollen Abgleich.
    public func run(semesterFilter: String? = nil, includeGrades: Bool = true, downloads: Bool = true) async -> Report {
        var report = Report()
        if let problem = await refusal() {
            report.refused = problem
            report.messages.append(problem)
            return report
        }
        let started = clock.nowISO
        if let learnweb {
            let courses = await syncLearnweb(learnweb, filter: semesterFilter, loadFiles: downloads, into: &report)
            // wie run_sync am PC: Fristen und Ankuendigungen nach den Dateien; ein Fehler dort stoppt den Lauf nicht,
            // nach abgelaufener Anmeldung oder Abbruch wird nichts mehr gefragt
            if let courses, !report.cancelled, !Task.isCancelled, !report.needsLogin.contains("Learnweb") {
                await syncDeadlines(learnweb, into: &report)
                if !report.cancelled, !Task.isCancelled { await syncAnnouncements(learnweb, courses: courses, into: &report) }
            }
        }
        if let lsf, !report.cancelled, !Task.isCancelled {
            await syncPlan(lsf, into: &report)
            if includeGrades { await syncGrades(lsf, into: &report) }
        }
        if Task.isCancelled { report.cancelled = true }
        let message = report.messages.joined(separator: ", ")
        let finished = clock.nowISO, ok = report.ok, newFiles = report.newFiles.count
        _ = try? await db.transaction {
            try UniStore.logSync($0, startedAt: started, finishedAt: finished, ok: ok, newFiles: newFiles, message: message)
        }
        return report
    }

    /// Nur der Container der Uni Hildesheim mit seiner Kennzeichnung (streng: ohne Kennzeichnung nicht) und eine
    /// Datenbank dieser Hochschule (`settings.university`) werden beschrieben; sonst die Meldung, warum nicht.
    private func refusal() async -> String? {
        let want = UniversityKey.hildesheim.rawValue
        guard container.university == .hildesheim else {
            return UniversityMismatch(stored: container.university.rawValue, expected: want).description
        }
        do {
            try container.verifyPresent()
            let stored = try await db.scalar("SELECT value FROM settings WHERE key='university'")?.string
            if stored != want { return UniversityMismatch(stored: stored, expected: want).description }
        } catch {
            return Self.describe(error)
        }
        return nil
    }

    /// Liefert die aktiven Kurse (fuer die Ankuendigungen, wie `active_courses` in `hildesheim.sync_announcements`);
    /// nil, wenn die Kursliste oder kein Kurs lesbar war (Learnweb gestoert: dann auch keine weiteren Anfragen)
    private func syncLearnweb(_ api: LearnwebAPI, filter: String?, loadFiles: Bool, into report: inout Report) async -> [Learnweb.Course]? {
        let courses: [Learnweb.Course]
        /// Kurse, deren Dateien dieser Lauf abfragt: nur aktive wie `hildesheim.active_courses` am PC (a7827c6): Kurse
        /// mit `active = 0` (Semesterregel oder eigener Schalter in Einstellungen -> Module) fallen weg. Kurse
        /// frueherer Semester bleiben gespeichert, ihre Dateien auch
        let current: [Learnweb.Course]
        let downloads = UniDownloads(container, folder: container.learnweb, tools: tools, source: "Learnweb")
        defer { downloads.end() }
        do {
            courses = try await api.courses().filter { c in
                !c.hidden && (filter.map { f in f.isEmpty || c.semester.lowercased().contains(f.lowercased()) } ?? true)
            }
            let now = clock.nowISO
            let off = try await db.transaction { conn -> Set<String> in
                for c in courses {
                    try UniStore.upsertCourse(conn, UniStore.CourseRow(id: c.id, title: c.title, number: c.number, semester: c.semester), now: now)
                }
                return Set(try conn.rows("SELECT id FROM courses WHERE active=0").compactMap { $0["id"]?.string })
            }
            current = courses.filter { !off.contains($0.id) }
            report.olderCourses = courses.filter { off.contains($0.id) }.map(\.id)
            try downloads.begin()
        } catch {
            if Self.isCancellation(error) {
                report.cancelled = true
                return nil
            }
            if Self.isLoginError(error) { report.needsLogin.append("Learnweb") }
            report.messages.append("Learnweb: \(Self.describe(error))")
            return nil
        }
        report.courses = courses.count
        let files = container.files()
        // Jeder Kurs einzeln: ein Fehler in einem Kurs verwirft nicht die schon geholten Dateien
        courseLoop: for (i, c) in current.enumerated() {
            /// Learnweb-Teil beenden: Abbruch oder abgelaufene Anmeldung; dieser und alle weiteren Kurse bleiben offen
            func stop(_ error: Error) -> Bool {
                if Self.isCancellation(error) {
                    report.cancelled = true
                } else if Self.isLoginError(error) {
                    if !report.needsLogin.contains("Learnweb") { report.needsLogin.append("Learnweb") }
                } else {
                    return false
                }
                report.notAttempted = current[i...].map(\.id)
                return true
            }
            if Task.isCancelled, stop(CancellationError()) { break courseLoop }
            do {
                let list = try await api.files(moodleID: c.moodleID)
                let now = clock.nowISO
                let todo = try await db.transaction { conn in
                    try UniStore.storeFiles(conn, courseID: c.id, list.map(\.row), now: now, fileExists: { files.exists(stored: $0) })
                }
                // nur Listen: die Dateien laedt der naechste volle Abgleich (beim Oeffnen der App oder im langen
                // Hintergrundlauf mit Netz)
                guard loadFiles else {
                    report.waiting += todo.count
                    continue
                }
                for row in todo {
                    guard let f = list.first(where: { $0.id == row.id }) else { continue }
                    do {
                        try Task.checkCancellation()
                        let req = try await api.downloadRequest(f)
                        try await downloads.load(row, to: StudIPImport.relativePath(fileID: row.id, name: row.name), db: db, clock: clock,
                                                 fetch: Self.fetch(req, name: row.name, shownURL: row.downloadURL, transport: transport, retry: retry))
                        report.newFiles.append(row.id)
                    } catch {
                        if stop(error) { break courseLoop }
                        report.failedFiles.append(row.name)
                    }
                }
            } catch {
                if stop(error) { break courseLoop }
                report.failedCourses.append(c.title)
            }
        }
        if report.cancelled {
            report.messages.append("Learnweb abgebrochen")
            return nil
        }
        // kein einziger Kurs lesbar (Learnweb gestoert): Fehler statt "Learnweb: 16:30 ok" (wie beim Stud.IP-Abgleich);
        // einzelne unlesbare Kurse stehen in der Meldung (vorher nur in `failedCourses`, das niemand las)
        let allUnreadable = !current.isEmpty && report.failedCourses.count == current.count
        if report.notAttempted.isEmpty, !allUnreadable { report.completed.append(Report.Part.learnweb) }
        report.messages.append(Self.learnwebMessage(courses: current.count, newFiles: report.newFiles.count,
                                                    failedFiles: report.failedFiles.count, failedCourses: report.failedCourses.count,
                                                    waiting: report.waiting, older: report.olderCourses.count))
        // Learnweb gestoert: keine weiteren Anfragen (Fristen, Ankuendigungen) in diesem Lauf; Ankuendigungen wie am
        // PC nur fuer aktive Kurse
        return allUnreadable ? nil : current
    }

    /// `hildesheim.sync_deadlines`: Fristen aus dem Learnweb-Kalender (Abgaben, Tests) in die Tabelle `deadlines`;
    /// im Abfragefenster Verschwundenes wird entfernt, Aelteres bleibt
    private func syncDeadlines(_ api: LearnwebAPI, into report: inout Report) async {
        do {
            let now = Int(clock.now.timeIntervalSince1970)
            let items = try await api.deadlines(now: now)
            let fetched = clock.nowISO
            let windowFrom = Learnweb.localISO(now - Learnweb.deadlineDaysBack * 86400)
            let r = try await db.transaction { conn in try UniStore.storeDeadlines(conn, items, fetchedAt: fetched, windowFrom: windowFrom) }
            report.deadlines = r
            report.messages.append("Fristen: \(r.total) (\(r.new) neu, \(r.removed) entfernt)")
        } catch {
            if Self.isCancellation(error) { report.cancelled = true; return }
            if Self.isLoginError(error), !report.needsLogin.contains("Learnweb") { report.needsLogin.append("Learnweb") }
            report.messages.append("Learnweb-Fristen: \(Self.describe(error))")
        }
    }

    /// `hildesheim.sync_announcements`: Ankuendigungsforen aller sichtbaren Kurse; geloeschte Diskussionen
    /// verschwinden auch in der App
    private func syncAnnouncements(_ api: LearnwebAPI, courses: [Learnweb.Course], into report: inout Report) async {
        do {
            let known = try await db.withConnection { try Announcements.knownDiscussions($0) }
            let today = BerlinClock.parseISODate(clock.today) ?? 0
            let (items, seen) = try await api.announcements(courses: courses, known: known, today: today)
            let fetched = clock.nowISO
            let (r, gone) = try await db.transaction { conn -> (Announcements.StoreResult, Int) in
                let r = try Announcements.store(conn, items, source: "learnweb", fetchedAt: fetched)
                var gone = 0
                for (cid, ids) in seen.sorted(by: { $0.key < $1.key }) {
                    let marks = ids.isEmpty ? "''" : Array(repeating: "?", count: ids.count).joined(separator: ",")
                    gone += try conn.execute("""
                        DELETE FROM announcements WHERE source='learnweb' AND course_id=?
                                                                 AND (discussion IS NULL OR discussion NOT IN (\(marks)))
                        """, [.text(cid)] + ids.map(SQLiteValue.text))
                }
                return (r, gone)
            }
            let withDates = items.filter { !$0.dates.isEmpty }.count
            report.announcements = Announcements.StoreResult(new: r.new, total: r.total, removed: gone)
            report.messages.append("Ankündigungen: \(r.new) neu (\(withDates) mit Termin), \(gone) entfernt")
        } catch {
            if Self.isCancellation(error) { report.cancelled = true; return }
            if Self.isLoginError(error), !report.needsLogin.contains("Learnweb") { report.needsLogin.append("Learnweb") }
            report.messages.append("Learnweb-Ankündigungen: \(Self.describe(error))")
        }
    }

    /// Meldung des Learnweb-Teils fuer die Statusleiste
    static func learnwebMessage(courses: Int, newFiles: Int, failedFiles: Int, failedCourses: Int, waiting: Int = 0, older: Int = 0) -> String {
        if courses > 0, failedCourses == courses {
            return "Learnweb: kein Kurs lesbar (\(courses) \(courses == 1 ? "Kurs" : "Kurse")), später erneut"
        }
        var text = "\(newFiles) neue/geänderte Dateien aus \(courses) Learnweb-Kursen"
        if failedFiles > 0 { text += ", \(failedFiles) Dateien später erneut" }
        if failedCourses > 0 { text += ", \(failedCourses) Learnweb-\(failedCourses == 1 ? "Kurs" : "Kurse") nicht lesbar" }
        if waiting > 0 { text += ", \(waiting) \(waiting == 1 ? "Datei wartet" : "Dateien warten") auf den Download" }
        // wie der Hinweis beim Stud.IP-Abgleich: alte Kurse sind bekannt, bekommen aber keine Dateien mehr
        if older > 0 { text += ", \(older) \(older == 1 ? "Kurs" : "Kurse") aus früheren Semestern ohne Dateien (Einstellungen → Module)" }
        return text
    }

    /// Download einer Learnweb-Datei in die Zwischendatei von `UniDownloads.load`, wie `stream_download` am PC
    /// (Wiederholung bei abgerissener Verbindung), mit den Pruefungen des Learnweb: keine CAS-Anmeldung, HTTP 200,
    /// keine Anmelde- oder andere Webseite (`UniStore.isWebPage`), keine Fehlermeldung von Moodle statt der Datei
    /// (`Learnweb.downloadError`)
    private static func fetch(_ req: UniRequest, name: String, shownURL: String, transport: UniTransport,
                              retry: UniRetry) -> @Sendable (URL) async throws -> Void {
        { part in
            let resp = try await retry.run { try await transport.download(req, to: part) }
            if HildesheimCAS.isCASPage(resp.finalURL?.absoluteString ?? "") { throw HildesheimError.sessionExpired("Learnweb") }
            guard resp.status == 200 else { throw HildesheimError.http(status: resp.status, url: shownURL) }
            if UniStore.isWebPage(file: part, name: name) { throw HildesheimError.htmlInsteadOfFile(shownURL) }
            if let e = Learnweb.downloadError(file: part, name: name) { throw e }
        }
    }

    private func syncPlan(_ lsf: LSFClient, into report: inout Report) async {
        do {
            guard let entries = try await lsf.planEntries() else {
                report.completed.append(Report.Part.plan)
                report.messages.append("LSF-Stundenplan ist leer")
                return
            }
            let clock = self.clock
            let r = try await db.transaction { conn in try UniStore.importPlan(conn, entries, clock: clock) }
            report.plan = r
            report.completed.append(Report.Part.plan)
            report.messages.append("Stundenplan: \(r.new) neu, \(r.kept) unverändert, \(r.removed) entfernt")
        } catch {
            if Self.isCancellation(error) { report.cancelled = true; return }
            if Self.isLoginError(error) { report.needsLogin.append("LSF") }
            report.messages.append("LSF-Stundenplan: \(Self.describe(error))")
        }
    }

    private func syncGrades(_ lsf: LSFClient, into report: inout Report) async {
        guard !report.cancelled else { return }
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
            report.completed.append(Report.Part.grades)
            report.messages.append("Notenspiegel: \(grades.count) Leistungen")
        } catch {
            if Self.isCancellation(error) { report.cancelled = true; return }
            if Self.isLoginError(error), !report.needsLogin.contains("LSF") { report.needsLogin.append("LSF") }
            let msg = Self.describe(error)
            _ = try? await db.execute("INSERT INTO qis_runs(started_at, finished_at, ok, message, grades, documents) VALUES (?,?,0,?,0,0)",
                                      [.text(started), .text(clock.nowISO), .text("FEHLER: \(msg)")])
            report.messages.append("Notenspiegel: \(msg)")
        }
    }
}
