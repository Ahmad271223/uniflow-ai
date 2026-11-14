import Foundation

/// Lernpakete wie app/study.py: Status (`refresh_statuses`, `_derive_status`, `set_task_status`), Planung
/// (`_est`, `_units`, `_module_score`, `generate_packages`, `_next_tasks`, `_insert_package`), Zeitslots in den freien
/// Fenstern (`assign_slots`, `reslot_day`), Uhrzeit von Hand (`set_package_time`) und Machbarkeit (`feasibility`).
/// Kalender und Uebersicht: `StudyCalendar`, Verschieben und Woche retten: `StudyReschedule`.
///
/// Bausteine aus S4/S5, keine zweite Rechnung: Semesterwochen `StudyWeeks`, Dateien mit Einordnung
/// `LocalModules.fileRows`/`weekTopic`, Module `LocalModules.ensureModules`, freie Fenster `LocalFreeWindows`
/// (mit Terminen, Sperrzeiten, Fahrtzeit und schon gelegten Lernslots). Tage sind Tagesnummern wie in `BerlinClock`.
/// Schreibt: immer innerhalb einer Transaktion aufrufen (kein `await` darin). Ergebnisgleichheit mit Python:
/// `LocalStudyPlanTests` gegen study-plan.json (tools/gen-study-fixture.py).
enum StudyPlan {
    typealias T = LocalTimetable

    /// `DEFAULT_EST`: geschaetzte Minuten je Art, wenn keine Analyse eine Dauer nennt
    static let defaultEst: [String: Int] = ["vorlesung": 45, "skript": 60, "uebung": 60, "loesung": 30, "test": 45, "wiederholung": 30]

    // MARK: Einstellungen

    /// Die Werte aus `db.get_settings`, die die Planung braucht (alle schon als ganze Zahlen abgeleitet)
    struct Settings {
        let raw: [String: JSONValue]
        let minutesPerDay: Int
        let subjectsPerDay: Int
        let partsLecture: Int
        let partsExercise: Int
        let testsPerSubject: Int
        let testMinutes: Int
        let breakMinutes: Int
        let examPriority: Bool
        let learnDays: Set<Int>

        init(_ c: SQLiteConnection) throws {
            let s = try LocalSettings.read(c)
            raw = s
            func n(_ k: String) -> Int { s[k]?.int ?? 0 }
            minutesPerDay = n("minutes_per_day")
            subjectsPerDay = n("subjects_per_day")
            partsLecture = n("parts_lecture")
            partsExercise = n("parts_exercise")
            testsPerSubject = n("tests_per_subject")
            testMinutes = n("test_minutes")
            breakMinutes = n("break_minutes")
            examPriority = s["exam_priority"]?.bool ?? false
            learnDays = Set((s["learn_days"]?.array ?? []).compactMap(\.int))
        }

        func isLearnDay(_ day: Int) -> Bool { learnDays.contains(BerlinClock.weekday(day)) }
    }

    // MARK: Python-Werte

    /// `int(v)` fuer gespeicherte Werte (Zahl abgeschnitten, Text mit ganzer Zahl); sonst 500 wie in Python
    static func int(_ v: SQLiteValue?, _ field: String) throws -> Int {
        try T.int(v?.json ?? .null, field)
    }

    /// Zahl fuer Summen und Vergleiche (`sum(...)`, `cap[d] >= t["est_minutes"]`); NULL und Text scheitern in Python
    static func number(_ v: SQLiteValue?, _ field: String) throws -> Double {
        switch v {
        case .integer(let i)?: return Double(i)
        case .real(let d)?: return d
        default: throw LocalHTTPError(status: 500, message: "\(field) ist keine Zahl")
        }
    }

    /// Textvergleich `a < b` wie Python (Codepunkte); andere Typen scheitern dort (500)
    static func less(_ a: SQLiteValue?, _ b: String) throws -> Bool {
        guard let s = a?.string else { throw LocalHTTPError(status: 500, message: "Datum ist kein Text") }
        return PyText.less(s, b)
    }

    static func iso(_ day: Int) -> String { BerlinClock.isoDate(day) }

    // MARK: Status

    /// Status, die eine Aufgabe abschliessen
    static let closed: Set<String> = ["erledigt", "uebersprungen", "verschoben"]

    /// `_derive_status(statuses, past)`: Paketstatus aus den Aufgaben (nil = Status ohne Text, zaehlt wie in Python
    /// zu keiner Gruppe)
    static func deriveStatus(_ statuses: [String?], past: Bool) -> String {
        if statuses.isEmpty { return "geplant" }
        let s = Set(statuses)
        if s.allSatisfy({ $0.map(closed.contains) ?? false }) {
            if s.contains("erledigt") { return "erledigt" }
            return s.contains("verschoben") ? "verschoben" : "uebersprungen"
        }
        if s.contains("erledigt") && (past || s.contains("nachholen")) { return "teilweise" }
        if s.contains("nachholen") { return "nachholen" }
        if s.contains("in_bearbeitung") { return "in_bearbeitung" }
        return "geplant"
    }

    /// `refresh_statuses(conn)`: offene Aufgaben vergangener Pakete werden "nachholen", der Paketstatus folgt den
    /// Aufgaben. Pakete ohne Aufgaben behalten ihren Status ("verschoben" aus `recalcPackage`; Korrektur vom
    /// 26.10.2026, zuerst in Python, tests/test_study_plan.py).
    ///
    /// Eine Abfrage fuer alle Pakete samt Aufgaben statt einer je Paket (Python: N+1). Laeuft bei jeder Anfrage an
    /// Kalender, Paket, Abhaken und offene Aufgaben mit; mit 3000 Paketen dauerte die Uebersicht frueher ueber eine
    /// Sekunde. Ergebnis wie in Python (Reihenfolge der Aufgaben egal, `_derive_status` nimmt eine Menge).
    static func refreshStatuses(_ c: SQLiteConnection, today: Int) throws {
        let t = iso(today)
        try c.execute("""
            UPDATE study_tasks SET status='nachholen' WHERE status IN ('geplant','in_bearbeitung')
                                AND package_id IN (SELECT id FROM study_packages WHERE date < ?)
            """, [.text(t)])
        var order: [SQLiteValue] = []
        var packages: [SQLiteValue: (date: SQLiteValue?, status: SQLiteValue?, tasks: [String?])] = [:]
        for r in try c.query("""
            SELECT p.id, p.date, p.status, t.id AS task_id, t.status AS task_status
            FROM study_packages p LEFT JOIN study_tasks t ON t.package_id=p.id
            WHERE COALESCE(p.source,'')<>'smart' ORDER BY p.id
            """) {
            let id = r["id"] ?? .null
            if packages[id] == nil {
                order.append(id)
                packages[id] = (r["date"], r["status"], [])
            }
            if r["task_id"] != nil && r["task_id"] != .null { packages[id]!.tasks.append(r["task_status"]?.string) }
        }
        for id in order {
            let p = packages[id]!
            if p.tasks.isEmpty { continue }
            let st = deriveStatus(p.tasks, past: try less(p.date, t))
            if p.status != .text(st) {
                try c.execute("UPDATE study_packages SET status=? WHERE id=?", [.text(st), id])
            }
        }
    }

    /// `set_task_status(conn, task_id, status, actual_minutes, note)`: Status setzen, Verlauf schreiben, bei
    /// "erledigt" die Datei als erledigt und gesehen markieren. nil, wenn es die Aufgabe nicht gibt.
    static func setTaskStatus(_ c: SQLiteConnection, taskID: SQLiteValue, status: String, actualMinutes: SQLiteValue = .null,
                              note: SQLiteValue = "", clock: UniFlowClock) throws -> JSONValue? {
        guard let t = try c.queryOne("SELECT t.*, p.date FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.id=?", [taskID]) else {
            return nil
        }
        let now = SQLiteValue.text(clock.nowISO)
        try c.execute("UPDATE study_tasks SET status=?, done_at=?, actual_minutes=COALESCE(?, actual_minutes) WHERE id=?",
                      [.text(status), status == "erledigt" ? now : .null, actualMinutes, taskID])
        try c.execute("INSERT INTO task_history(task_id, package_id, old_status, new_status, old_date, new_date, note, at) VALUES (?,?,?,?,?,?,?,?)",
                      [taskID, t["package_id"] ?? .null, t["status"] ?? .null, .text(status), t["date"] ?? .null, t["date"] ?? .null, note, now])
        if status == "erledigt" && LocalModules.truthy(t["file_id"]) {
            try c.execute("UPDATE files SET status='erledigt', seen_by_user=1 WHERE id=?", [t["file_id"] ?? .null])
        } else if t["status"]?.string == "erledigt", ModuleDone.openTasks.contains(status), LocalModules.truthy(t["file_id"]),
                  !ModuleDone.ownResult.contains(t["type"]?.string ?? "") {
            // wieder geoeffnet: die Datei ist auch nicht mehr erledigt (ein Stand, `ModuleDone`)
            try c.execute("UPDATE files SET status='gelesen', seen_by_user=1 WHERE id=? AND status='erledigt'", [t["file_id"] ?? .null])
        }
        try refreshStatuses(c, today: T.today(clock))
        return try c.rows("SELECT * FROM study_tasks WHERE id=?", [taskID]).first.map(JSONValue.object) ?? .null
    }

    // MARK: Lerneinheiten

    /// Eine Lehrwoche eines Moduls mit den noch offenen Vorlesungen und Uebungen (`_units`)
    struct Unit {
        let week: Int
        let label: String
        let topic: String
        let lectures: [LocalModules.FileRow]
        let exercises: [LocalModules.FileRow]
    }

    /// `_est(f)`: Dauer aus der Analyse, sonst nach Art
    static func est(_ f: LocalModules.FileRow) throws -> Int {
        if let m = f.json["est_minutes"], LocalModules.truthy(m) { return try T.int(m, "est_minutes") }
        return defaultEst[f.docType ?? ""] ?? 45
    }

    /// Datei und Lehrwoche einer Aufgabe (`_planned_file_weeks`)
    struct FileWeek: Hashable {
        let file: String
        let week: Int
    }

    /// `_units(conn, module_id, exclude_files, week, done_weeks)`: je Lehrwoche ab 1 die offenen Vorlesungen und
    /// Uebungen (ohne schon eingeplante, ohne erledigte Dateien und ohne Dateien im Papierkorb); Wochen ohne beides fallen weg. Mit `week` nur die
    /// Einheit dieser Lehrwoche (Regel des Inhabers vom 30.10.2026, zuerst in Python) und davor der Rest eines Skripts
    /// nach dem Marker der Vorwoche (`markerRest`).
    static func units(_ c: SQLiteConnection, moduleID: SQLiteValue, exclude: Set<String>, dates: LocalModules.Dates,
                      week: Int? = nil, doneWeeks: Set<FileWeek> = []) throws -> [Unit] {
        var weeks: [Int: (files: [LocalModules.FileRow], lectures: [LocalModules.FileRow], exercises: [LocalModules.FileRow])] = [:]
        // Dateien im Papierkorb nicht einplanen (vorher kamen sie beim naechsten Planen wieder in den Lernplan;
        // Abnahme Lernkalender vom 07.11.2026, zuerst in Python)
        let trashed = Set(try c.query("SELECT id FROM files WHERE deleted_at IS NOT NULL").compactMap { $0[0].string })
        let files = try LocalModules.fileRows(c, moduleID: moduleID).filter { f in f.id.string.map { !trashed.contains($0) } ?? true }
        for f in files {
            if let id = f.id.string, exclude.contains(id) { continue }
            if f.json["status"]?.string == "erledigt" { continue }
            let w = try LocalModules.week(f, dates: dates)
            if w < 1 { continue }                    // alte und vorsemesterliche Unterlagen und Klausuren nicht automatisch einplanen
            if let week, w != week { continue }
            weeks[w, default: ([], [], [])].files.append(f)
            if f.docType == "vorlesung" { weeks[w]!.lectures.append(f) } else if f.docType == "uebung" { weeks[w]!.exercises.append(f) }
        }
        if let week {
            let rest = try markerRest(c, moduleID: moduleID, week: week, dates: dates, files: files, doneWeeks: doneWeeks)
            if !rest.isEmpty {                       // der aeltere Stoff zuerst
                weeks[week, default: ([], [], [])].lectures.insert(contentsOf: rest, at: 0)
                weeks[week]!.files.insert(contentsOf: rest, at: 0)
            }
        }
        var out: [Unit] = []
        for w in weeks.keys.sorted() {
            let u = weeks[w]!
            if u.lectures.isEmpty && u.exercises.isEmpty { continue }
            out.append(Unit(week: w, label: dates.label(w), topic: try LocalModules.weekTopic(u.files),
                            lectures: u.lectures, exercises: u.exercises))
        }
        return out
    }

    /// `_marker_rest(conn, module_id, week, start, files, done_weeks)`: Rest eines Vorlesungsskripts frueherer
    /// Lehrwochen fuer die Lehrwoche `week`. Gibt es in der Vorwoche einen Marker ("Vorlesung bis hier") und endet der
    /// letzte Marker vor dieser Woche mitten im Skript, gehoeren die Seiten danach in diese Woche, bis zum Marker dieser
    /// Woche oder bis zur letzten Seite. Nur eigene Marker, keine geloeschten und keine zu pruefenden; kein Rest fuer
    /// erledigte Dateien und keiner, der schon in einem Paket dieser Lehrwoche steht. Dauer anteilig nach Seiten.
    static func markerRest(_ c: SQLiteConnection, moduleID: SQLiteValue, week: Int, dates: LocalModules.Dates,
                           files: [LocalModules.FileRow], doneWeeks: Set<FileWeek>) throws -> [LocalModules.FileRow] {
        var per: [String: [SQLiteRow]] = [:]
        for m in try c.query("""
            SELECT file_id, page, page_count, week_no FROM lecture_markers
            WHERE module_id=? AND deleted_at IS NULL AND COALESCE(needs_review,0)=0 AND scope='personal'
            AND user_id='local' AND week_no IS NOT NULL ORDER BY id
            """, [moduleID]) {
            if let f = m["file_id"]?.string { per[f, default: []].append(m) }
        }
        var out: [LocalModules.FileRow] = []
        for f in files {
            guard let id = f.id.string, let ms = per[id], f.json["status"]?.string != "erledigt",
                  ["vorlesung", "skript"].contains(f.docType ?? ""), !doneWeeks.contains(FileWeek(file: id, week: week)) else { continue }
            let fw = try LocalModules.week(f, dates: dates)
            guard 1 <= fw, fw < week else { continue }
            let before = ms.filter { ($0["week_no"]?.int ?? 0) < week }
            guard before.contains(where: { $0["week_no"]?.int == week - 1 }) else { continue }
            // max(before, key=page): bei gleicher Seite der erste
            var last = before[0]
            for m in before.dropFirst() where (m["page"]?.int ?? 0) > (last["page"]?.int ?? 0) { last = m }
            let page = last["page"]?.int ?? 0, count = last["page_count"]?.int ?? 0
            if page >= count { continue }            // Skript bis zur letzten Seite behandelt
            let now = ms.filter { $0["week_no"]?.int == week }.compactMap { $0["page"]?.int }.filter { $0 > page }
            let to = now.isEmpty ? count : min(now.max()!, count)
            let est = max(10, -BerlinClock.floorDiv(-(try est(f)) * (to - page), count))
            var g = f
            g.json["pages"] = .array([.number(Double(page + 1)), .number(Double(to))])
            g.json["est_minutes"] = .number(Double(est))
            out.append(g)
        }
        return out
    }

    /// `_module_score(m, open_units, settings)`: Prioritaet, offene Einheiten, Klausur in den naechsten 6 Wochen
    static func moduleScore(_ m: SQLiteRow, openUnits: Int, settings s: Settings, today: Int) throws -> Double {
        let priority = LocalModules.truthy(m["priority"]) ? try number(m["priority"], "priority") : 2
        var score = priority * 10 + Double(openUnits)
        if s.examPriority, LocalModules.truthy(m["exam_date"]) {
            guard let text = m["exam_date"]?.string else { throw LocalHTTPError(status: 500, message: "Klausurtermin ist kein Text") }
            if let exam = BerlinClock.parseISODate(text) {        // ValueError: kein Zuschlag
                let days = exam - today
                if (0...42).contains(days) { score += Double(42 - days) }
            }
        }
        return score
    }

    // MARK: Planen

    /// Eine geplante Aufgabe vor dem Speichern (`{"type", "file_id", "title", "est"}`)
    struct NewTask {
        let type: SQLiteValue
        let fileID: SQLiteValue
        let title: SQLiteValue
        let est: Int
    }

    /// Warteschlange eines Moduls in `generate_packages`; `pending`: Aufgaben der angefangenen Einheit
    final class Queue {
        let module: SQLiteRow
        let units: [Unit]
        var pos = 0
        var pending: [NewTask] = []
        var current: Unit?

        init(module: SQLiteRow, units: [Unit]) {
            self.module = module
            self.units = units
        }
    }

    /// `_next_tasks(q, s, budget)`: naechste Aufgaben eines Moduls im Budget. Reihenfolge Vorlesung -> Uebung ->
    /// Test -> Wiederholung; lange Materialien in hoechstens 4 Teile.
    static func nextTasks(_ q: Queue, settings s: Settings, budget: Int) throws -> [NewTask] {
        if q.pending.isEmpty {
            guard q.pos < q.units.count else { return [] }
            let u = q.units[q.pos]
            q.pos += 1
            q.current = u
            var tasks: [NewTask] = []
            func add(_ kind: String, _ f: LocalModules.FileRow) throws {
                let est = try est(f)
                var title = T.or(f.json["ai_title"], f.json["name"] ?? .null)
                if let p = f.json["pages"]?.array, p.count == 2 {    // Rest nach dem Marker der Vorwoche
                    title = .string("\(T.text(title)) · S. \(p[0].int ?? 0)–\(p[1].int ?? 0)")
                }
                if est > budget {                     // lange Materialien in Teile splitten (max. 4)
                    let n = min(4, -BerlinClock.floorDiv(-est, budget))
                    let part = -BerlinClock.floorDiv(-est, n)
                    for k in 0..<n {
                        tasks.append(NewTask(type: .text(kind), fileID: try T.bind(f.id, "file_id"),
                                             title: .text("\(T.text(title)) (Teil \(k + 1)/\(n))"), est: part))
                    }
                } else {
                    tasks.append(NewTask(type: .text(kind), fileID: try T.bind(f.id, "file_id"), title: try T.bind(title, "title"), est: est))
                }
            }
            // Alle Vorlesungen und alle Uebungen der Lehrwoche (Hoersaal-, Gruppenuebung ...), hoechstens 4 je Art
            if s.partsLecture != 0 { for f in u.lectures.prefix(4) { try add("vorlesung", f) } }
            if s.partsExercise != 0 { for f in u.exercises.prefix(4) { try add("uebung", f) } }
            // Genau EIN gemeinsamer Wochentest fuer das Modul und die Lehrwoche (am iPad Standard 0: ohne Test)
            let weekly = q.module["weekly_test"] ?? .integer(1)
            if s.testsPerSubject >= 1 && weekly != .integer(0) && weekly != .real(0) {
                let minutes = LocalModules.truthy(q.module["test_minutes"]) ? try int(q.module["test_minutes"], "test_minutes") : s.testMinutes
                tasks.append(NewTask(type: "test", fileID: .null,
                                     title: .text("Gemeinsamer Wochentest Lehrwoche \(u.week)" + (u.topic.isEmpty ? "" : " – \(u.topic)")), est: minutes))
            }
            if s.testsPerSubject >= 2 {
                tasks.append(NewTask(type: "wiederholung", fileID: .null,
                                     title: .text("Wiederholung Lehrwoche \(u.week) (Karteikarten, Fehler aus dem Test)"), est: 15))
            }
            q.pending = tasks
        }
        var out: [NewTask] = []
        var used = 0
        while let t = q.pending.first {
            if !out.isEmpty && used + t.est > budget { break }
            out.append(q.pending.removeFirst())
            used += t.est
        }
        return out
    }

    /// `_insert_package(conn, d, m, tasks, unit)`: Paket mit Aufgaben anlegen; Titel = Thema, sonst Wochenname,
    /// sonst Modulname. Liefert die ID.
    static func insertPackage(_ c: SQLiteConnection, day: Int, moduleID: SQLiteValue, subject: SQLiteValue, title: SQLiteValue,
                              weekNo: SQLiteValue, tasks: [NewTask], clock: UniFlowClock) throws -> Int64 {
        let now = SQLiteValue.text(clock.nowISO)
        try c.execute("""
            INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at)
            VALUES (?,?,?,?,?,?, 'geplant', 0, 1, ?)
            """, [.text(iso(day)), moduleID, subject, title, weekNo, .integer(Int64(tasks.reduce(0) { $0 + $1.est })), now])
        let pid = c.lastInsertRowID
        for (i, t) in tasks.enumerated() {
            try c.execute("""
                INSERT INTO study_tasks(package_id, type, file_id, test_id, title, sort, est_minutes, status, created_at)
                VALUES (?,?,?,?,?,?,?, 'geplant', ?)
                """, [.integer(pid), t.type, t.fileID, .null, t.title, .integer(Int64(i)), .integer(Int64(t.est)), now])
        }
        return pid
    }

    /// `_insert_package` fuer eine Lehrwoche eines Moduls (Planung)
    static func insertPackage(_ c: SQLiteConnection, day: Int, module m: SQLiteRow, tasks: [NewTask], unit: Unit?, clock: UniFlowClock) throws -> Int64 {
        let title: SQLiteValue
        if let u = unit, !u.topic.isEmpty { title = .text(u.topic) } else if let u = unit, !u.label.isEmpty { title = .text(u.label) } else { title = m["name"] ?? .null }
        return try insertPackage(c, day: day, moduleID: m["id"] ?? .null, subject: m["name"] ?? .null, title: title,
                                 weekNo: unit.map { .integer(Int64($0.week)) } ?? .null, tasks: tasks, clock: clock)
    }

    /// `_recalc_package(conn, pid)`: geplante Minuten aus den Aufgaben; ohne Aufgaben "verschoben" mit 0 Minuten und
    /// ohne Uhrzeit (vorher blieb sie: leerer Block im Raster, ein neues Paket bekam dieselbe Uhrzeit; Korrektur vom
    /// 26.10.2026, zuerst in Python)
    static func recalcPackage(_ c: SQLiteConnection, _ pid: SQLiteValue) throws {
        // Block des Stundenplaners: Dauer = Stundenbudget, unabhaengig von den Aufgaben (Smart Planner 2.0)
        if try c.queryOne("SELECT 1 FROM study_packages WHERE id=? AND source='smart'", [pid]) != nil { return }
        guard let r = try c.queryOne("SELECT COUNT(*) n, COALESCE(SUM(est_minutes),0) m FROM study_tasks WHERE package_id=?", [pid]) else { return }
        if r["n"]?.int == 0 {
            if try c.queryOne("SELECT generated FROM study_packages WHERE id=?", [pid]) != nil {
                try c.execute("UPDATE study_packages SET status='verschoben', planned_minutes=0, start_time=NULL, end_time=NULL WHERE id=?", [pid])
            }
        } else {
            try c.execute("UPDATE study_packages SET planned_minutes=? WHERE id=?", [r["m"] ?? .null, pid])
        }
    }

    /// `_replaceable(conn, start, end)`: Pakete, die "ersetzen" loeschen darf: automatisch erstellte, noch nicht
    /// begonnene (alle Aufgaben geplant, keine verschoben) und leere; tageweise (ein Paket, das bleibt, haelt seinen
    /// Tag). Korrektur vom 26.10.2026, zuerst in Python: vorher auch eigene Pakete und neu eingeplante Aufgaben.
    static func replaceable(_ c: SQLiteConnection, from start: Int, to end: Int) throws -> [SQLiteValue] {
        let rows = try c.query("""
            SELECT p.id, p.date,
                   (p.generated=1 AND p.status='geplant' AND NOT EXISTS (SELECT 1 FROM study_tasks t WHERE t.package_id=p.id
                        AND (t.status != 'geplant' OR t.moved_from IS NOT NULL))) AS fresh,
                   NOT EXISTS (SELECT 1 FROM study_tasks t WHERE t.package_id=p.id) AS empty
            FROM study_packages p WHERE p.date BETWEEN ? AND ? AND COALESCE(p.source,'')<>'smart' ORDER BY p.id
            """, [.text(iso(start)), .text(iso(end))])
        let keep = Set(rows.filter { !LocalModules.truthy($0["fresh"]) && !LocalModules.truthy($0["empty"]) }.map { $0["date"] ?? .null })
        return rows.filter { !keep.contains($0["date"] ?? .null) }.map { $0["id"] ?? .null }
    }

    /// `_planned_files(conn, exclude_packages)`: Dateien in offenen oder erledigten Aufgaben (ohne diese Pakete)
    static func plannedFiles(_ c: SQLiteConnection, excluding packages: [SQLiteValue] = []) throws -> Set<String> {
        var sql = "SELECT file_id FROM study_tasks WHERE file_id IS NOT NULL AND status IN ('geplant','in_bearbeitung','erledigt','nachholen')"
        if !packages.isEmpty { sql += " AND package_id NOT IN (\(Array(repeating: "?", count: packages.count).joined(separator: ",")))" }
        return Set(try c.query(sql, packages).compactMap { $0[0].string })
    }

    /// `_planned_file_weeks(conn, exclude_packages)`: (Datei, Lehrwoche) der Aufgaben in Paketen wie `plannedFiles`;
    /// ein Skriptrest steht je Lehrwoche hoechstens einmal im Plan
    static func plannedFileWeeks(_ c: SQLiteConnection, excluding packages: [SQLiteValue] = []) throws -> Set<FileWeek> {
        var sql = """
            SELECT t.file_id, p.week_no FROM study_tasks t JOIN study_packages p ON p.id=t.package_id
            WHERE t.file_id IS NOT NULL AND p.week_no IS NOT NULL AND t.status IN ('geplant','in_bearbeitung','erledigt','nachholen')
            """
        if !packages.isEmpty { sql += " AND t.package_id NOT IN (\(Array(repeating: "?", count: packages.count).joined(separator: ",")))" }
        return Set(try c.query(sql, packages).compactMap { r in r[0].string.flatMap { f in r[1].int.map { FileWeek(file: f, week: $0) } } })
    }

    /// `_queues(conn, planned_files, s, week, done_weeks)`: Warteschlangen der aktiven Module mit offenen Einheiten und
    /// ihre Reihenfolge (hoechste Bewertung zuerst, bei Gleichstand wie die Module sortiert sind); mit `week` nur die
    /// Einheiten dieser Lehrwoche
    static func queues(_ c: SQLiteConnection, planned: Set<String>, settings s: Settings, today: Int, clock: UniFlowClock,
                       week: Int? = nil, doneWeeks: Set<FileWeek> = []) throws -> ([Int64: Queue], [Int64]) {
        let dates = try LocalModules.Dates(c, clock: clock)
        var queues: [Int64: Queue] = [:]
        var queueOrder: [Int64] = []
        for m in try StudyPlanModules.plannedModules(c) {
            guard let id = m["id"]?.int64 else { continue }
            let units = try units(c, moduleID: .integer(id), exclude: planned, dates: dates, week: week, doneWeeks: doneWeeks)
            if !units.isEmpty {
                if queues[id] == nil { queueOrder.append(id) }
                queues[id] = Queue(module: m, units: units)
            }
        }
        var scores: [Int64: Double] = [:]
        for id in queueOrder { scores[id] = -(try moduleScore(queues[id]!.module, openUnits: queues[id]!.units.count, settings: s, today: today)) }
        return (queues, T.stableSorted(queueOrder) { scores[$0]! < scores[$1]! })
    }

    static let nothingToPlan: JSONValue = ["created": 0, "message": "Keine offenen Vorlesungen oder Übungen für die Planung."]
    static let nothingThisWeek: JSONValue = ["created": 0, "message": "Keine offenen Vorlesungen oder Übungen für diese Woche."]

    /// `generate_packages(conn, start, days, replace)`: Lernpakete fuer `days` Tage ab `start` (sonst heute) nach der
    /// Lernkombination; danach Zeitslots in den freien Fenstern. Tage vor heute werden nicht geplant; mit `replace`
    /// werden nur Pakete aus `replaceable` ersetzt, und erst, wenn es etwas zu planen gibt (Korrekturen vom
    /// 26.10.2026, zuerst in Python). Ein Tag bekommt nur Stoff seiner Lehrwoche und den Skriptrest nach dem Marker der
    /// Vorwoche (Regel des Inhabers vom 30.10.2026); aeltere offene Unterlagen plant das freie Fenster (`planWindow`).
    static func generatePackages(_ c: SQLiteConnection, start: Int?, days: Int, replace: Bool, clock: UniFlowClock) throws -> JSONValue {
        try LocalModules.ensureModules(c, clock: clock)
        let today = T.today(clock)
        try StudyPlanModules.dropUnplanned(c, today: today)       // abgewaehlte Faecher: keine Pakete (Build 37)
        try refreshStatuses(c, today: today)
        try repairTimes(c, today: today)                           // Uhrzeiten nach Mitternacht aus Build 41 und frueher
        let s = try Settings(c)
        let start = start ?? today
        let end = start + days - 1
        let drop = replace ? try replaceable(c, from: start, to: end) : []
        let planned = try plannedFiles(c, excluding: drop), doneWeeks = try plannedFileWeeks(c, excluding: drop)
        let sem = try LocalModules.Dates(c, clock: clock).start
        // Ferien: an freien Tagen der Stoff der letzten Vorlesungswoche davor (`StudIPTerms`, app/studip_terms.py)
        let free = StudIPTerms.freeDays(from: start, to: end, university: try Holidays.university(c), studip: try StudIPTerms.load(c))
        var perWeek: [Int: (queues: [Int64: Queue], rr: [Int64])] = [:]       // Lehrwoche -> Warteschlangen, Reihenfolge
        for i in 0..<max(0, days) {
            let lw = StudIPTerms.lectureWeek(semesterStart: sem, day: start + i, today: today, free: free)
            if lw >= 1 && perWeek[lw] == nil {
                let (q, order) = try queues(c, planned: planned, settings: s, today: today, clock: clock, week: lw, doneWeeks: doneWeeks)
                perWeek[lw] = (q, order)
            }
        }
        if !perWeek.values.contains(where: { !$0.queues.isEmpty }) { return nothingThisWeek }
        for pid in drop {
            try c.execute("DELETE FROM study_tasks WHERE package_id=?", [pid])
            try c.execute("DELETE FROM study_packages WHERE id=?", [pid])
        }

        let budgetDay = s.minutesPerDay
        let perPackage = max(30, BerlinClock.floorDiv(budgetDay, max(1, s.subjectsPerDay)))
        var created = 0
        var existing: Set<String> = []
        for r in try c.query("SELECT date, COUNT(*) n FROM study_packages WHERE date BETWEEN ? AND ? GROUP BY date", [.text(iso(start)), .text(iso(end))])
            where LocalModules.truthy(r["n"]) {
            if let d = r["date"]?.string { existing.insert(d) }
        }
        for i in 0..<max(0, days) {
            let d = start + i
            if d < today || !s.isLearnDay(d) || existing.contains(iso(d)) { continue }
            // Tag ohne freie Zeit (Termine bis Lernende): nichts automatisch planen (Abnahme 07.11.2026, zuerst in Python)
            if try LocalFreeWindows.compute(c, day: d, settings: s.raw).isEmpty { continue }
            let lw = StudIPTerms.lectureWeek(semesterStart: sem, day: d, today: today, free: free)
            let queues = perWeek[lw]?.queues ?? [:]
            var rr = perWeek[lw]?.rr ?? []
            defer { if perWeek[lw] != nil { perWeek[lw]!.rr = rr } }
            var picked: [(Queue, Int64)] = []
            var dayUsed = 0
            var attempts = 0
            while picked.count < s.subjectsPerDay && !rr.isEmpty && attempts < rr.count {
                let mid = rr.removeFirst()
                let q = queues[mid]!
                let tasks = try nextTasks(q, settings: s, budget: perPackage)
                if !tasks.isEmpty {
                    let pid = try insertPackage(c, day: d, module: q.module, tasks: tasks, unit: q.current, clock: clock)
                    dayUsed += tasks.reduce(0) { $0 + $1.est }
                    picked.append((q, pid))
                    created += 1
                    if !q.pending.isEmpty || q.pos < q.units.count { rr.append(mid) }
                } else {
                    attempts += 1
                    if q.pos < q.units.count || !q.pending.isEmpty { rr.append(mid) }
                }
            }
            // Restzeit des Tages mit weiteren Aufgaben der gewaehlten Faecher auffuellen (keine neuen Einheiten)
            var changed = true
            while changed && dayUsed < budgetDay {
                changed = false
                for (q, pid) in picked {
                    while let t = q.pending.first, dayUsed + t.est <= budgetDay {
                        q.pending.removeFirst()
                        let n = try c.scalar("SELECT COUNT(*) n FROM study_tasks WHERE package_id=?", [.integer(pid)]) ?? .integer(0)
                        try c.execute("""
                            INSERT INTO study_tasks(package_id, type, file_id, test_id, title, sort, est_minutes, status, created_at)
                            VALUES (?,?,?,?,?,?,?, 'geplant', ?)
                            """, [.integer(pid), t.type, t.fileID, .null, t.title, n, .integer(Int64(t.est)), .text(clock.nowISO)])
                        dayUsed += t.est
                        changed = true
                    }
                    try recalcPackage(c, .integer(pid))
                }
            }
        }
        // Zeitslots in freien Fenstern des Stundenplans vergeben
        for i in 0..<max(0, days) { try assignSlots(c, day: start + i, spill: spillDays) }
        let feas = try feasibility(c, clock: clock)
        return ["created": .number(Double(created)), "message": .string("\(created) Lernpakete erstellt"), "feasibility": feas]
    }

    /// `auto_plan_week(conn, new_files)`: nach einem Abgleich mit `auto_plan` die laufende Woche ab heute planen, wenn
    /// neue Dateien kamen oder in dieser Woche noch kein automatisches Paket liegt; ersetzt nur automatisch erstellte,
    /// nicht begonnene Pakete. Am PC vorher der KI-Wochenplan (`planner.generate_plan`), dessen Ergebnis keine Ansicht
    /// zeigte; auf dem iPad gab es nach dem Abgleich gar keine Planung.
    static func autoPlanWeek(_ c: SQLiteConnection, newFiles: Int, clock: UniFlowClock) throws -> JSONValue? {
        guard try LocalSettings.read(c)["auto_plan"]?.bool == true else { return nil }
        if try SmartGoals.active(c) { return nil }        // Lernziele in Stunden: der Stundenplaner plant
        let t0 = T.today(clock)
        let sunday = StudyWeeks.monday(t0) + 6
        let planned = try c.queryOne("SELECT 1 FROM study_packages WHERE generated=1 AND date BETWEEN ? AND ?", [.text(iso(t0)), .text(iso(sunday))]) != nil
        if newFiles == 0 && planned { return nil }
        return try generatePackages(c, start: t0, days: sunday - t0 + 1, replace: true, clock: clock)
    }

    // MARK: Zeitslots

    /// `assign_slots(conn, d, only_unset)`: Uhrzeiten fuer die Lernpakete eines Tages in den freien Fenstern
    /// (Hochschultermine, Sperrzeiten, Fahrtzeit, schon gelegte Lernslots). Ein Paket liegt am Stueck im ersten Fenster
    /// mit genug Platz. Mit `packageID` nur dieses Paket (verschobenes Paket).
    ///
    /// Passt es in keines, werden seine Aufgaben auf mehrere Fenster verteilt und das Paket geteilt: je Fenster ein
    /// eigenes Paket desselben Tages (`splitPackage`). Eine Aufgabe liegt immer mit ihrer vollen Dauer in einem Fenster
    /// mit genug Platz; passt sie in keines mehr, hat sie an diesem Tag keinen Platz (siehe unten). Vorher bekam das Paket Beginn der ersten
    /// und Ende der letzten Aufgabe: ein Lernblock von 09:45 bis 17:30 ueber allen Vorlesungen, und eine zu lange Aufgabe
    /// wurde im zu kleinen Fenster gekappt (45 min als 09:45–10:15) und ragte in den naechsten Termin (Fehlerbericht
    /// des Inhabers vom 10.11.2026: Lernbloecke nie waehrend besuchter Termine).
    /// `notBefore`: erste nutzbare Minute (heute: jetzt), damit ein neu gelegter Block nicht in schon vergangener Zeit liegt.
    ///
    /// Nie ausserhalb der Lernzeit (Fehler vom echten iPhone, 14.11.2026): Vorher kam, was in kein Fenster mehr passte,
    /// hinter den letzten belegten Block, ohne Tagesgrenze, z. B. 23:15 bis "25:15" bei Lernzeit 08–21 Uhr. Jetzt
    /// bekommen solche Aufgaben keine Uhrzeit; mit `spill` (automatische Planung) kommen sie auf den naechsten Lerntag
    /// (das ganze Paket wird verlegt, ein Rest wird ein eigenes Paket), hoechstens `spill` Lerntage weit (`_spill`).
    static func assignSlots(_ c: SQLiteConnection, day d: Int, onlyUnset: Bool = true, packageID: SQLiteValue? = nil, notBefore: Int? = nil,
                            spill: Int = 0) throws {
        let s = try Settings(c)
        var pkgs = try c.query("SELECT * FROM study_packages WHERE date=? AND status NOT IN ('verschoben','uebersprungen','erledigt') ORDER BY sort, id",
                               [.text(iso(d))])
        if onlyUnset { pkgs = pkgs.filter { !LocalModules.truthy($0["start_time"]) } }
        if let packageID { pkgs = pkgs.filter { $0["id"] == packageID } }
        if pkgs.isEmpty { return }
        let blocks = try LocalFreeWindows.busyBlocks(c, day: d, settings: s.raw)
        let lo = try LocalFreeWindows.hm(s.raw["learn_start"], key: "learn_start"), hi = try LocalFreeWindows.hm(s.raw["learn_end"], key: "learn_end")
        var windows = try LocalFreeWindows.windows(lo: lo, hi: hi, blocks: blocks, settings: s.raw)
            .map { w in (start: w["start"]?.int ?? 0, end: w["end"]?.int ?? 0) }
        if let notBefore {
            windows = windows.map { (start: max($0.start, notBefore), end: $0.end) }.filter { $0.end > $0.start }
        }
        let brk = s.breakMinutes
        var free = windows.map(\.start)               // naechste freie Minute je Fenster
        for p in pkgs {
            let tasks = try c.query("SELECT id, est_minutes, status FROM study_tasks WHERE package_id=? AND status NOT IN ('erledigt','uebersprungen','verschoben') ORDER BY sort",
                                    [p["id"] ?? .null])
            if tasks.isEmpty { continue }
            let needs = try tasks.map { LocalModules.truthy($0["est_minutes"]) ? try int($0["est_minutes"], "est_minutes") : 45 }
            // Lage je Aufgabe (slot = Fenster); was in keines mehr passt, kommt in `rest`
            var placed: [(task: SQLiteRow, start: Int, end: Int, slot: Int)] = []
            var rest: [SQLiteRow] = []
            // Am Stueck in das erste freie Fenster mit genug Platz: sonst lag der Lernblock ueber dem naechsten Termin
            // (Korrektur vom 26.10.2026, zuerst in Python)
            let total = needs.reduce(0, +) + brk * max(0, needs.count - 1)
            if let k = windows.indices.first(where: { free[$0] + total <= windows[$0].end }) {
                var cur = free[k]
                for (t, need) in zip(tasks, needs) {
                    placed.append((t, cur, cur + need, k))
                    cur += need + brk
                }
                free[k] = cur
            } else {
                // der Reihe nach: jede Aufgabe ganz in das naechste Fenster mit genug Platz, nie gekappt; passt eine in
                // keines mehr, haben sie und die folgenden an diesem Tag keinen Platz
                var k = 0
                for (t, need) in zip(tasks, needs) {
                    while k < windows.count && free[k] + need > windows[k].end { k += 1 }
                    if k < windows.count {
                        placed.append((t, free[k], free[k] + need, k))
                        free[k] += need + brk
                    } else {
                        rest.append(t)
                    }
                }
            }
            for x in placed {
                try c.execute("UPDATE study_tasks SET start_time=?, end_time=? WHERE id=?",
                              [.text(LocalFreeWindows.mh(x.start)), .text(LocalFreeWindows.mh(x.end)), x.task["id"] ?? .null])
            }
            // je Fenster ein Paket: die erste Gruppe bleibt im Paket, jede weitere wird ein eigenes
            var groups: [[(task: SQLiteRow, start: Int, end: Int, slot: Int)]] = []
            for x in placed {
                if let g = groups.last, g[0].slot == x.slot { groups[groups.count - 1].append(x) } else { groups.append([x]) }
            }
            let pid = p["id"] ?? .null
            for (i, g) in groups.enumerated() {
                let a = g[0].start, b = g[g.count - 1].end
                if i == 0 {
                    try c.execute("UPDATE study_packages SET start_time=?, end_time=? WHERE id=?",
                                  [.text(LocalFreeWindows.mh(a)), .text(LocalFreeWindows.mh(b)), pid])
                } else {
                    try splitPackage(c, p, tasks: g.map(\.task), start: a, end: b)
                }
            }
            if groups.count > 1 { try recalcPackage(c, pid) }
            if !rest.isEmpty { try spillTasks(c, p, rest, day: d, spill: spill, whole: placed.isEmpty, settings: s) }
        }
    }

    /// `_spill`: Aufgaben ohne Platz an ihrem Tag (`assignSlots`). Mit `spill` auf den naechsten Lerntag (das ganze
    /// Paket wird verlegt, ein Rest wird ein eigenes Paket: gleiches Modul, Fach, Titel, Lehrwoche); ohne bleiben sie am
    /// Tag, aber ohne Uhrzeit, ein Rest als eigenes Paket, damit jedes Paket mit Uhrzeit nur Aufgaben mit Uhrzeit hat und
    /// seine geplanten Minuten zu seinem Block passen.
    static func spillTasks(_ c: SQLiteConnection, _ p: SQLiteRow, _ tasks: [SQLiteRow], day d: Int, spill: Int, whole: Bool, settings s: Settings) throws {
        let ids = tasks.map { $0["id"] ?? .null }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        try c.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE id IN (\(marks))", ids)
        let pid = p["id"] ?? .null
        if whole { try c.execute("UPDATE study_packages SET start_time=NULL, end_time=NULL WHERE id=?", [pid]) }
        let next = spill > 0 ? (1...7).map({ d + $0 }).first(where: { s.isLearnDay($0) }) : nil
        let target: SQLiteValue
        if whole {
            guard let next else { return }
            try c.execute("UPDATE study_packages SET date=? WHERE id=?", [.text(iso(next)), pid])
            target = pid
        } else {
            try c.execute("""
                INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at)
                VALUES (?,?,?,?,?,0,'geplant',?,?,?)
                """, [.text(iso(next ?? d)), p["module_id"] ?? .null, p["subject"] ?? .null, p["title"] ?? .null, p["week_no"] ?? .null,
                      p["sort"] ?? .null, p["generated"] ?? .null, p["created_at"] ?? .null])
            target = .integer(c.lastInsertRowID)
            for (i, id) in ids.enumerated() {
                try c.execute("UPDATE study_tasks SET package_id=?, sort=? WHERE id=?", [target, .integer(Int64(i)), id])
            }
            try recalcPackage(c, pid)
            try recalcPackage(c, target)
        }
        guard let next else { return }
        try assignSlots(c, day: next, packageID: target, spill: spill - 1)
    }

    static let spillDays = 14          // so viele Lerntage weiter sucht ein automatisches Paket Platz (SPILL_DAYS)
    static let dayEnd = 24 * 60        // spaetestes Ende einer Uhrzeit ("24:00", DAY_END)

    /// `_clock(v)`: "HH:MM" in Minuten (auch Stunden ab 24), sonst nil
    static func clock(_ v: SQLiteValue?) -> Int? {
        guard let s = v?.string else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        func digits(_ p: Substring) -> Bool { p.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) } }
        guard parts.count == 2, (1...2).contains(parts[0].unicodeScalars.count), parts[1].unicodeScalars.count == 2,
              digits(parts[0]), digits(parts[1]), let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    /// `_bad_span(start, end)`: Uhrzeit, die es nicht gibt: Beginn ab 24:00, Ende nach 24:00 oder Ende nicht nach dem Beginn
    static func badSpan(_ start: SQLiteValue?, _ end: SQLiteValue?) -> Bool {
        guard let a = clock(start), let b = clock(end) else { return false }
        return a >= dayEnd || b > dayEnd || b <= a
    }

    /// `_fit_day(a, b)`: Ende hoechstens 24:00; beginnt der Zeitraum erst nach Mitternacht, endet er um 24:00 mit
    /// derselben Dauer
    static func fitDay(_ a: Int, _ b: Int) -> (Int, Int) {
        a >= dayEnd ? (max(0, dayEnd - (b - a)), dayEnd) : (a, min(b, dayEnd))
    }

    /// `repair_times(conn)`: Uhrzeiten nach Mitternacht reparieren (Altbestand bis Build 41: "25:15", Ende vor Beginn;
    /// Fehler vom echten iPhone vom 14.11.2026). Automatisch erzeugte, unberuehrte Pakete ab heute werden neu eingeplant
    /// (`assignSlots` mit Weitergabe an den naechsten Lerntag), alle anderen (von Hand geaendert, begonnen, erledigt,
    /// vergangen) nur gekappt: Ende hoechstens 24:00 (beginnt ein Paket erst nach Mitternacht, endet es um 24:00 mit
    /// derselben Dauer), Aufgaben mit Beginn nach Mitternacht ohne Uhrzeit. Geloescht wird nichts. Laeuft mit jedem
    /// Lernkalender und jeder Planung; was einmal gueltig ist, bleibt unberuehrt, darum keine Schleife zwischen zwei
    /// Geraeten, die beide reparieren. Liefert die Zahl reparierter Pakete.
    @discardableResult
    static func repairTimes(_ c: SQLiteConnection, today: Int) throws -> Int {
        let pre = "(p.start_time >= '24:' OR p.end_time > '24:00' OR p.end_time <= p.start_time)"     // grob, genau: badSpan
        let preTask = "(t.start_time >= '24:' OR t.end_time > '24:00' OR t.end_time <= t.start_time)"
        var rows = try c.query("""
            SELECT DISTINCT p.* FROM study_packages p LEFT JOIN study_tasks t ON t.package_id=p.id
            WHERE \(pre) OR \(preTask) ORDER BY p.date, p.sort, p.id
            """)
        if rows.isEmpty { return 0 }
        let ids = rows.map { $0["id"] ?? .null }
        var tasks: [SQLiteValue: [SQLiteRow]] = [:]
        for t in try c.query("SELECT id, package_id, start_time, end_time FROM study_tasks WHERE package_id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ","))) ORDER BY id", ids)
        where badSpan(t["start_time"], t["end_time"]) {
            tasks[t["package_id"] ?? .null, default: []].append(t)
        }
        rows = rows.filter { badSpan($0["start_time"], $0["end_time"]) || tasks[$0["id"] ?? .null] != nil }
        if rows.isEmpty { return 0 }
        let redo = Set(try c.query("SELECT p.id FROM study_packages p WHERE p.date >= ? AND COALESCE(p.source,'')<>'smart' AND \(StudyPlanModules.untouchedAutoSQL)",
                                   [.text(iso(today))]).map { $0["id"] ?? .null })
        for p in rows {
            let pid = p["id"] ?? .null
            if redo.contains(pid), let text = p["date"]?.string, let d = BerlinClock.parseISODate(text) {
                try c.execute("UPDATE study_packages SET start_time=NULL, end_time=NULL WHERE id=?", [pid])
                try c.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE package_id=? AND status NOT IN ('erledigt','uebersprungen','verschoben')", [pid])
                try assignSlots(c, day: d, packageID: pid, spill: spillDays)
                continue
            }
            if badSpan(p["start_time"], p["end_time"]), var a = clock(p["start_time"]), var b = clock(p["end_time"]) {
                if b <= a { b = a + max(15, p["planned_minutes"]?.int ?? 0) }
                (a, b) = fitDay(a, b)
                try c.execute("UPDATE study_packages SET start_time=?, end_time=? WHERE id=?", [.text(LocalFreeWindows.mh(a)), .text(LocalFreeWindows.mh(b)), pid])
            }
            for t in tasks[pid] ?? [] {
                guard let ta = clock(t["start_time"]), let tb = clock(t["end_time"]) else { continue }
                if ta >= dayEnd || tb <= ta {
                    try c.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE id=?", [t["id"] ?? .null])
                } else {
                    try c.execute("UPDATE study_tasks SET end_time=? WHERE id=?", [.text(LocalFreeWindows.mh(min(tb, dayEnd))), t["id"] ?? .null])
                }
            }
        }
        return rows.count
    }

    /// Teil eines Pakets als eigenes Paket desselben Tages in einem eigenen freien Fenster (`assignSlots`): gleiches
    /// Modul, Fach, Titel, Lehrwoche, `generated` und Anlagezeit, gleiche Sortierung (in `sort, id` damit hinter dem
    /// Paket). Die Aufgaben wandern mit ihrer Uhrzeit, die Minuten beider Pakete werden neu gerechnet, der Status folgt
    /// den Aufgaben. Liefert die ID.
    @discardableResult
    static func splitPackage(_ c: SQLiteConnection, _ p: SQLiteRow, tasks: [SQLiteRow], start: Int, end: Int) throws -> SQLiteValue {
        let status = deriveStatus(tasks.map { $0["status"]?.string }, past: false)
        try c.execute("""
            INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at, start_time, end_time)
            VALUES (?,?,?,?,?,0,?,?,?,?,?,?)
            """, [p["date"] ?? .null, p["module_id"] ?? .null, p["subject"] ?? .null, p["title"] ?? .null, p["week_no"] ?? .null, .text(status),
                  p["sort"] ?? .integer(0), p["generated"] ?? .integer(1), p["created_at"] ?? .null,
                  .text(LocalFreeWindows.mh(start)), .text(LocalFreeWindows.mh(end))])
        let pid = SQLiteValue.integer(c.lastInsertRowID)
        for (i, t) in tasks.enumerated() {
            try c.execute("UPDATE study_tasks SET package_id=?, sort=? WHERE id=?", [pid, .integer(Int64(i)), t["id"] ?? .null])
        }
        try recalcPackage(c, pid)
        return pid
    }

    /// Lernbloecke von `start` bis `end`, die nicht (mehr) in einem freien Fenster liegen, neu legen (Fehlerbericht des
    /// Inhabers vom 10.11.2026). Laeuft mit jedem Lernkalender und der Uebersicht (`StudyCalendar.calendar`, ab heute),
    /// also nach jeder Aenderung des Stundenplans (Teilnahme, Ausnahme, Stud.IP-Abgleich, Fragen zu Kurszeiten), ohne
    /// dass jede dieser Stellen daran denken muss. Neu gelegt (`assignSlots` mit `packageID`, wenn noetig geteilt) werden
    /// nur offene Pakete mit Uhrzeit, deren
    /// - Zeitraum oder eine Aufgabe (mit voller geschaetzter Dauer) einen besuchten Termin oder eine Sperrzeit
    ///   ueberschneidet (auch ein Termin, der nach dem Planen wieder besucht wird),
    /// - Zeitraum ein frueheres Lernpaket desselben Tages ueberschneidet,
    /// - Aufgabe ausserhalb des Pakets liegt (alte Pakete ueber mehrere Fenster) oder
    /// - Aufgabe gekappt wurde (kuerzer als geschaetzt und endet an einem belegten Block oder am Lernende).
    /// Von Hand gesetzte Uhrzeiten ohne Konflikt bleiben. Liefert die Zahl neu gelegter Pakete.
    @discardableResult
    static func repairSlots(_ c: SQLiteConnection, from start: Int, to end: Int, now: LocalTimetableImport.LocalTime? = nil) throws -> Int {
        guard start <= end else { return 0 }
        let rows = try c.query("""
            SELECT id, date, status, start_time, end_time, source FROM study_packages
            WHERE date BETWEEN ? AND ? AND start_time IS NOT NULL AND status NOT IN ('verschoben','uebersprungen') ORDER BY date, sort, id
            """, [.text(iso(start)), .text(iso(end))])
        if rows.isEmpty { return 0 }
        let settings = try LocalSettings.read(c)
        let travel = settings["travel_minutes"]?.int ?? 30
        let learnEnd = (try? LocalFreeWindows.hm(settings["learn_end"], key: "learn_end")) ?? 24 * 60
        func minutes(_ v: SQLiteValue?) -> Int? {
            guard let text = v?.string, let (h, m) = LocalFreeWindows.hourMinute(text) else { return nil }
            return h * 60 + m
        }
        var days: [String: [SQLiteRow]] = [:]
        var order: [String] = []
        for r in rows {
            guard let di = r["date"]?.string else { continue }
            if days[di] == nil { order.append(di) }
            days[di, default: []].append(r)
        }
        var fixed = 0
        for di in order {
            guard let d = BerlinClock.parseISODate(di), let pkgs = days[di] else { continue }
            // besuchte Termine und Sperrzeiten; Grenzen fuer gekappte Aufgaben: deren Beginn, Fahrtzeit, Lernende
            let hard = try LocalFreeWindows.busyBlocks(c, day: d, settings: settings, includePackages: false)
            var bounds = Set(hard.map(\.start))
            bounds.insert(learnEnd)
            let events = hard.filter { $0.kind == "event" }
            if let first = events.first, let last = events.last { bounds.formUnion([first.start - travel, last.end]) }
            var kept: [(start: Int, end: Int)] = []  // Lernpakete, die bleiben (erledigte immer)
            // Bloecke des Stundenplaners legt nur der Stundenplaner (gesperrte und von Hand gelegte nie ungefragt);
            // sie bleiben, belegen aber ihre Zeit
            for p in pkgs where p["status"]?.string == "erledigt" || p["source"]?.string == "smart" {
                if let a = minutes(p["start_time"]), let b = minutes(p["end_time"]) { kept.append((a, b)) }
            }
            var redo: [SQLiteValue] = []
            for p in pkgs where p["status"]?.string != "erledigt" && p["source"]?.string != "smart" {
                guard let ps = minutes(p["start_time"]), let pe = minutes(p["end_time"]) else { continue }
                var bad = hard.contains { ps < $0.end && pe > $0.start } || kept.contains { ps < $0.end && pe > $0.start }
                if !bad {
                    let ends = bounds.union(kept.map(\.start))
                    for t in try c.query("SELECT start_time, end_time, est_minutes FROM study_tasks WHERE package_id=? AND status NOT IN ('erledigt','uebersprungen','verschoben')",
                                         [p["id"] ?? .null]) {
                        guard let ts = minutes(t["start_time"]), let te = minutes(t["end_time"]) else { continue }
                        let est = t["est_minutes"]?.int ?? (te - ts)
                        let full = max(te, ts + est)
                        if ts < ps || te > pe || hard.contains(where: { ts < $0.end && full > $0.start }) || (te - ts < est && ends.contains(te)) {
                            bad = true
                            break
                        }
                    }
                }
                if bad { redo.append(p["id"] ?? .null) } else { kept.append((ps, pe)) }
            }
            if redo.isEmpty { continue }
            for id in redo {
                try c.execute("UPDATE study_packages SET start_time=NULL, end_time=NULL WHERE id=?", [id])
                try c.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE package_id=? AND status NOT IN ('erledigt','uebersprungen','verschoben')", [id])
            }
            // heute nicht vor der aktuellen Minute (sonst landete ein neu gelegter Block in schon vergangener Zeit)
            let notBefore = now.flatMap { $0.day == d ? $0.minutes : nil }
            // was an diesem Tag keinen Platz mehr hat: unberuehrte automatische Pakete auf den naechsten Lerntag, die
            // uebrigen ohne Uhrzeit (vorher hinter den letzten Block, auch nach Mitternacht; Fehler vom 14.11.2026)
            let marks = Array(repeating: "?", count: redo.count).joined(separator: ",")
            let auto = Set(try c.query("SELECT p.id FROM study_packages p WHERE p.id IN (\(marks)) AND COALESCE(p.source,'')<>'smart' AND \(StudyPlanModules.untouchedAutoSQL)",
                                       redo).map { $0["id"] ?? .null })
            for id in redo { try assignSlots(c, day: d, packageID: id, notBefore: notBefore, spill: auto.contains(id) ? spillDays : 0) }
            fixed += redo.count
        }
        return fixed
    }

    /// `reslot_day(conn, d)`: alle Slots eines Tages neu vergeben (z. B. nach einer Stundenplan-Aenderung, "Lernslots
    /// neu legen"), auch von Hand gesetzte; "Uhrzeiten vergeben" nimmt `assignSlots` (nur Pakete ohne Uhrzeit)
    static func reslotDay(_ c: SQLiteConnection, day d: Int) throws {
        let di = SQLiteValue.text(iso(d))
        // Bloecke des Stundenplaners legt nur der Stundenplaner (Smart Planner 2.0)
        try c.execute("UPDATE study_packages SET start_time=NULL, end_time=NULL WHERE date=? AND status NOT IN ('erledigt') AND COALESCE(source,'')<>'smart'", [di])
        try c.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE package_id IN (SELECT id FROM study_packages WHERE date=? AND status NOT IN ('erledigt') AND COALESCE(source,'')<>'smart')", [di])
        try assignSlots(c, day: d)
    }

    /// `_clock_minutes(v)`: "HH:MM" (auch "24:30" fuer ein Ende nach Mitternacht) in Minuten, sonst 400
    static func clockMinutes(_ v: JSONValue?) throws -> Int {
        let bad = LocalHTTPError(status: 400, message: "Ungültige Uhrzeit: \(T.text(v))")
        guard let s = v?.string else { throw bad }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        func digits(_ p: Substring) -> Bool { p.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) } }
        guard parts.count == 2, (1...2).contains(parts[0].unicodeScalars.count), parts[1].unicodeScalars.count == 2,
              digits(parts[0]), digits(parts[1]), let h = Int(parts[0]), let m = Int(parts[1]), m <= 59 else { throw bad }
        return h * 60 + m
    }

    /// `set_package_time(conn, package_id, start, end)`: Uhrzeit von Hand ("Uhrzeit", "Beginn" beim Anlegen); ohne
    /// Beginn entfaellt sie, ohne Ende gilt die geplante Dauer. Aufgaben mit Uhrzeit ruecken mit, und das Paket endet
    /// nie vor seiner letzten Aufgabe (die geplante Dauer zaehlt keine Pausen, der Dialog schickt Beginn + Dauer).
    /// Korrekturen vom 26.10.2026 (vorher speicherte PATCH /api/packages/{id} keine Uhrzeit, danach wurde das Paket
    /// kuerzer als seine Aufgaben), zuerst in Python.
    static func setPackageTime(_ c: SQLiteConnection, packageID id: SQLiteValue, start: JSONValue?, end: JSONValue?) throws {
        guard let p = try c.queryOne("SELECT start_time, planned_minutes FROM study_packages WHERE id=?", [id]) else { return }
        guard LocalModules.truthy(start) else {
            try c.execute("UPDATE study_packages SET start_time=NULL, end_time=NULL WHERE id=?", [id])
            try c.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE package_id=?", [id])
            return
        }
        let a = try clockMinutes(start)
        guard a < dayEnd else { throw LocalHTTPError(status: 400, message: "Der Beginn muss vor 24:00 liegen.") }
        var b = min(dayEnd, LocalModules.truthy(end) ? try clockMinutes(end) : a + (LocalModules.truthy(p["planned_minutes"]) ? try int(p["planned_minutes"], "planned_minutes") : 0))
        guard b > a else { throw LocalHTTPError(status: 400, message: "Das Ende muss nach dem Beginn liegen.") }
        if LocalModules.truthy(p["start_time"]) {
            let shift = a - (try LocalFreeWindows.hm(p["start_time"]?.json, key: "start_time"))
            for t in try c.query("SELECT id, start_time, end_time FROM study_tasks WHERE package_id=? AND start_time IS NOT NULL AND end_time IS NOT NULL", [id]) {
                let ts = try LocalFreeWindows.hm(t["start_time"]?.json, key: "start_time") + shift
                let te = min(dayEnd, try LocalFreeWindows.hm(t["end_time"]?.json, key: "end_time") + shift)
                // hoechstens bis 24:00 (vorher "25:15"; Fehler vom 14.11.2026): begaenne die Aufgabe erst danach, ohne Uhrzeit
                if ts >= dayEnd || te <= ts {
                    try c.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE id=?", [t["id"] ?? .null])
                    continue
                }
                try c.execute("UPDATE study_tasks SET start_time=?, end_time=? WHERE id=?",
                              [.text(LocalFreeWindows.mh(ts)), .text(LocalFreeWindows.mh(te)), t["id"] ?? .null])
                b = max(b, te)
            }
        }
        try c.execute("UPDATE study_packages SET start_time=?, end_time=? WHERE id=?", [.text(LocalFreeWindows.mh(a)), .text(LocalFreeWindows.mh(b)), id])
    }

    /// `plan_window(conn, d, start, end)`: "Lerneinheit automatisch einplanen" im freien Fenster: die naechsten
    /// Aufgaben eines Moduls als ein Paket genau in dieses Fenster, auch an einem Tag mit Paketen (vorher uebersprang
    /// die Planung fuer den Tag ihn: "0 Lernpakete erstellt"; Korrektur vom 26.10.2026, zuerst in Python). Das Modul
    /// mit der hoechsten Bewertung, dessen erste Aufgabe passt; weitere Aufgaben der Einheit, solange sie mit Pause
    /// passen; Dateien ungeteilt. Falsche Uhrzeit: 400.
    static func planWindow(_ c: SQLiteConnection, day d: Int, start: JSONValue?, end: JSONValue?, clock: UniFlowClock) throws -> JSONValue {
        let a = try clockMinutes(start), b = min(dayEnd, try clockMinutes(end))     // hoechstens bis 24:00
        guard b > a else { throw LocalHTTPError(status: 400, message: "Das Ende muss nach dem Beginn liegen.") }
        try LocalModules.ensureModules(c, clock: clock)
        let today = T.today(clock)
        try refreshStatuses(c, today: today)
        let s = try Settings(c)
        let (queues, order) = try queues(c, planned: try plannedFiles(c), settings: s, today: today, clock: clock)
        if queues.isEmpty { return nothingToPlan }
        for mid in order {
            let q = queues[mid]!
            let tasks = try nextTasks(q, settings: s, budget: 24 * 60)        // ganze Einheit, ohne Teile
            guard let first = tasks.first, a + first.est <= b else { continue }
            var fit: [(task: NewTask, start: Int)] = []
            var cur = a
            for t in tasks {
                if !fit.isEmpty && cur + t.est > b { break }
                fit.append((t, cur))
                cur += t.est + s.breakMinutes
            }
            let pid = try insertPackage(c, day: d, module: q.module, tasks: fit.map(\.task), unit: q.current, clock: clock)
            let ids = try c.query("SELECT id FROM study_tasks WHERE package_id=? ORDER BY sort", [.integer(pid)]).map { $0["id"] ?? .null }
            for (tid, f) in zip(ids, fit) {
                try c.execute("UPDATE study_tasks SET start_time=?, end_time=? WHERE id=?",
                              [.text(LocalFreeWindows.mh(f.start)), .text(LocalFreeWindows.mh(f.start + f.task.est)), tid])
            }
            let last = fit[fit.count - 1].start + fit[fit.count - 1].task.est
            try c.execute("UPDATE study_packages SET start_time=?, end_time=? WHERE id=?",
                          [.text(LocalFreeWindows.mh(a)), .text(LocalFreeWindows.mh(last)), .integer(pid)])
            return ["created": 1, "message": "1 Lernpaket erstellt", "feasibility": try feasibility(c, clock: clock)]
        }
        return ["created": 0, "message": .string("Keine Lerneinheit passt in \(b - a) Minuten.")]
    }

    // MARK: Machbarkeit

    /// `feasibility(conn)`: offene Lernmenge gegen die verfuegbare Zeit der naechsten 4 Wochen
    static func feasibility(_ c: SQLiteConnection, clock: UniFlowClock) throws -> JSONValue {
        let s = try Settings(c)
        let done = Set(try c.query("SELECT file_id FROM study_tasks WHERE file_id IS NOT NULL AND status='erledigt'").compactMap { $0[0].string })
        let dates = try LocalModules.Dates(c, clock: clock)
        var total = 0
        for m in try StudyPlanModules.plannedModules(c) {            // Faecher im Lernkalender (12.11.2026)
            for u in try units(c, moduleID: m["id"] ?? .null, exclude: done, dates: dates) {
                if s.partsLecture != 0 { for f in u.lectures.prefix(4) { total += try est(f) } }
                if s.partsExercise != 0 { for f in u.exercises.prefix(4) { total += try est(f) } }
                if s.testsPerSubject != 0 { total += s.testMinutes }
            }
        }
        let today = dates.today
        let avail = (0..<28).filter { s.isLearnDay(today + $0) }.count * s.minutesPerDay
        let need = s.subjectsPerDay * (s.partsLecture * 45 + s.partsExercise * 60 + s.testsPerSubject * s.testMinutes)
        var hint: JSONValue = .null
        if need > s.minutesPerDay {
            hint = .string("Deine Kombination braucht etwa \(need) Minuten pro Tag, verfügbar sind \(s.minutesPerDay). Weniger Fächer pro Tag, kürzere Tests oder mehr Lernzeit wählen.")
        } else if total > avail {
            // round() in Python rundet auf die gerade Zahl
            func hours(_ m: Int) -> Int { Int((Double(m) / 60).rounded(.toNearestOrEven)) }
            hint = .string("Offene Materialien brauchen etwa \(hours(total)) Stunden, in 4 Wochen sind \(hours(avail)) Stunden verfügbar. Die Planung verteilt den Rest auf spätere Wochen.")
        }
        return ["open_minutes": .number(Double(total)), "available_minutes_4w": .number(Double(avail)), "per_day_need": .number(Double(need)),
                "per_day_available": .number(Double(s.minutesPerDay)), "hint": hint]
    }
}

/// Lernplan nach einem Abgleich auf dem iPad (Stud.IP, Learnweb) und beim Oeffnen der App: mit `auto_plan` nur neue
/// Dokumente in den bestehenden Plan einordnen (`StudyPlan.insertNewFiles`, Entscheidung des Inhabers vom 08.11.2026),
/// keine Neuplanung der Woche mehr. Am PC plant `study.auto_plan_week` weiter die Woche (`StudyPlan.autoPlanWeek`).
public enum StudyAutoPlan {
    /// Tarifpruefung der App (der Kern kennt keinen Tarif): automatisch planen erst ab Plus (`UFFeature.autoPlan`,
    /// Free plant von Hand). Vorher plante jeder Abgleich auch in Free die Woche, weil `auto_plan` von Anfang an an
    /// ist (Abnahme Lernkalender vom 07.11.2026). Ohne App (Kern-Tests, PC) immer erlaubt.
    @MainActor public static var allowed: () -> Bool = { true }

    /// Ergebnis der Einordnung, nil = am Plan nichts geaendert (aus, Tarif ohne automatischen Lernplan, keine neuen
    /// Dokumente). `newFiles` ist nur noch ein Hinweis des Abgleichs: welche Dokumente neu sind, weiss der Planer
    /// selbst (`study_plan_seen_files`), darum zaehlt eine doppelt gemeldete Datei einmal. Ohne Tarif werden die
    /// Dateien nur gemerkt (spaeter Plus plant dann nicht alles Alte auf einmal ein).
    public static func afterSync(_ backend: LocalBackend, newFiles: Int) async throws -> JSONValue? {
        let ok = await MainActor.run(body: { allowed() })
        let clock = backend.context.clock
        return try await backend.context.database.transaction { c in
            // abgewaehlte Faecher: auch Pakete, die ein anderes Geraet vor der Abwahl angelegt hat, kommen hier weg
            try StudyPlanModules.dropUnplanned(c, today: LocalTimetable.today(clock))
            guard ok else {
                try StudyPlan.markAllSeen(c, clock: clock)
                return nil
            }
            return try StudyPlan.insertNewFiles(c, clock: clock)
        }
    }

    /// Beim Oeffnen der App: Dokumente, die ein Hintergrundabgleich gebracht hat, ohne dass danach eingeordnet wurde
    public static func catchUp(_ backend: LocalBackend) async throws -> JSONValue? {
        try await afterSync(backend, newFiles: 0)
    }
}
