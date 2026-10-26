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
            FROM study_packages p LEFT JOIN study_tasks t ON t.package_id=p.id ORDER BY p.id
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

    /// `_units(conn, module_id, exclude_files)`: je Lehrwoche ab 1 die offenen Vorlesungen und Uebungen (ohne schon
    /// eingeplante, ohne erledigte Dateien); Wochen ohne beides fallen weg
    static func units(_ c: SQLiteConnection, moduleID: SQLiteValue, exclude: Set<String>, dates: LocalModules.Dates) throws -> [Unit] {
        var weeks: [Int: (files: [LocalModules.FileRow], lectures: [LocalModules.FileRow], exercises: [LocalModules.FileRow])] = [:]
        for f in try LocalModules.fileRows(c, moduleID: moduleID) {
            if let id = f.id.string, exclude.contains(id) { continue }
            if f.json["status"]?.string == "erledigt" { continue }
            let w = try StudyWeeks.weekIndex(start: dates.start, chdate: f.chdate, today: dates.today)
            if w < 1 { continue }                    // alte und vorsemesterliche Unterlagen nicht automatisch einplanen
            weeks[w, default: ([], [], [])].files.append(f)
            if f.docType == "vorlesung" { weeks[w]!.lectures.append(f) } else if f.docType == "uebung" { weeks[w]!.exercises.append(f) }
        }
        var out: [Unit] = []
        for w in weeks.keys.sorted() {
            let u = weeks[w]!
            if u.lectures.isEmpty && u.exercises.isEmpty { continue }
            out.append(Unit(week: w, label: StudyWeeks.weekLabel(start: dates.start, week: w), topic: try LocalModules.weekTopic(u.files),
                            lectures: u.lectures, exercises: u.exercises))
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
                let title = T.or(f.json["ai_title"], f.json["name"] ?? .null)
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
            FROM study_packages p WHERE p.date BETWEEN ? AND ? ORDER BY p.id
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

    /// `_queues(conn, planned_files, s)`: Warteschlangen der aktiven Module mit offenen Einheiten und ihre
    /// Reihenfolge (hoechste Bewertung zuerst, bei Gleichstand wie die Module sortiert sind)
    static func queues(_ c: SQLiteConnection, planned: Set<String>, settings s: Settings, today: Int, clock: UniFlowClock) throws -> ([Int64: Queue], [Int64]) {
        let dates = try LocalModules.Dates(c, clock: clock)
        var queues: [Int64: Queue] = [:]
        var queueOrder: [Int64] = []
        for m in try c.query("SELECT * FROM modules WHERE COALESCE(active,1)=1 ORDER BY sort") {
            guard let id = m["id"]?.int64 else { continue }
            let units = try units(c, moduleID: .integer(id), exclude: planned, dates: dates)
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

    /// `generate_packages(conn, start, days, replace)`: Lernpakete fuer `days` Tage ab `start` (sonst heute) nach der
    /// Lernkombination; danach Zeitslots in den freien Fenstern. Tage vor heute werden nicht geplant; mit `replace`
    /// werden nur Pakete aus `replaceable` ersetzt, und erst, wenn es etwas zu planen gibt (Korrekturen vom
    /// 26.10.2026, zuerst in Python).
    static func generatePackages(_ c: SQLiteConnection, start: Int?, days: Int, replace: Bool, clock: UniFlowClock) throws -> JSONValue {
        try LocalModules.ensureModules(c, clock: clock)
        let today = T.today(clock)
        try refreshStatuses(c, today: today)
        let s = try Settings(c)
        let start = start ?? today
        let end = start + days - 1
        let drop = replace ? try replaceable(c, from: start, to: end) : []
        let (queues, order) = try queues(c, planned: try plannedFiles(c, excluding: drop), settings: s, today: today, clock: clock)
        if queues.isEmpty { return nothingToPlan }
        for pid in drop {
            try c.execute("DELETE FROM study_tasks WHERE package_id=?", [pid])
            try c.execute("DELETE FROM study_packages WHERE id=?", [pid])
        }

        let budgetDay = s.minutesPerDay
        let perPackage = max(30, BerlinClock.floorDiv(budgetDay, max(1, s.subjectsPerDay)))
        var rr = order
        var created = 0
        var existing: Set<String> = []
        for r in try c.query("SELECT date, COUNT(*) n FROM study_packages WHERE date BETWEEN ? AND ? GROUP BY date", [.text(iso(start)), .text(iso(end))])
            where LocalModules.truthy(r["n"]) {
            if let d = r["date"]?.string { existing.insert(d) }
        }
        for i in 0..<max(0, days) {
            let d = start + i
            if d < today || !s.isLearnDay(d) || existing.contains(iso(d)) { continue }
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
        for i in 0..<max(0, days) { try assignSlots(c, day: start + i) }
        let feas = try feasibility(c, clock: clock)
        return ["created": .number(Double(created)), "message": .string("\(created) Lernpakete erstellt"), "feasibility": feas]
    }

    // MARK: Zeitslots

    /// `assign_slots(conn, d, only_unset)`: Uhrzeiten fuer die Lernpakete eines Tages in den freien Fenstern
    /// (Hochschultermine, Sperrzeiten, Fahrtzeit, schon gelegte Lernslots). Ein Paket liegt am Stueck im ersten Fenster
    /// mit genug Platz; passt es in keines, werden seine Aufgaben auf mehrere Fenster verteilt. Ohne freies Fenster ab
    /// Lernbeginn hintereinander. Mit `packageID` nur dieses Paket (verschobenes Paket).
    static func assignSlots(_ c: SQLiteConnection, day d: Int, onlyUnset: Bool = true, packageID: SQLiteValue? = nil) throws {
        let s = try Settings(c)
        var pkgs = try c.query("SELECT * FROM study_packages WHERE date=? AND status NOT IN ('verschoben','uebersprungen','erledigt') ORDER BY sort, id",
                               [.text(iso(d))])
        if onlyUnset { pkgs = pkgs.filter { !LocalModules.truthy($0["start_time"]) } }
        if let packageID { pkgs = pkgs.filter { $0["id"] == packageID } }
        if pkgs.isEmpty { return }
        var windows = try LocalFreeWindows.compute(c, day: d, settings: s.raw).map { w in (start: w["start"]?.int ?? 0, end: w["end"]?.int ?? 0) }
        if windows.isEmpty {
            windows = [(try LocalFreeWindows.hm(s.raw["learn_start"], key: "learn_start"), try LocalFreeWindows.hm(s.raw["learn_end"], key: "learn_end"))]
        }
        let brk = s.breakMinutes
        var free = windows.map(\.start)               // naechste freie Minute je Fenster
        for p in pkgs {
            let tasks = try c.query("SELECT id, est_minutes FROM study_tasks WHERE package_id=? AND status NOT IN ('erledigt','uebersprungen','verschoben') ORDER BY sort",
                                    [p["id"] ?? .null])
            let needs = try tasks.map { LocalModules.truthy($0["est_minutes"]) ? try int($0["est_minutes"], "est_minutes") : 45 }
            // Am Stueck in das erste freie Fenster mit genug Platz: sonst lag der Lernblock ueber dem naechsten Termin
            // (Korrektur vom 26.10.2026, zuerst in Python). Passt es in keines, werden die Aufgaben der Reihe nach verteilt.
            let total = needs.reduce(0, +) + brk * max(0, needs.count - 1)
            var k = windows.indices.first { free[$0] + total <= windows[$0].end } ?? 0
            var first: Int?
            var last = 0
            for (t, need) in zip(tasks, needs) {
                var placed = false
                while k < windows.count {
                    let w = windows[k], cur = free[k]
                    if cur + need <= w.end || (w.end - w.start < need && cur == w.start) {
                        let st = cur, en = cur + need > w.end ? min(cur + need, w.end) : cur + need
                        try c.execute("UPDATE study_tasks SET start_time=?, end_time=? WHERE id=?",
                                      [.text(LocalFreeWindows.mh(st)), .text(LocalFreeWindows.mh(en)), t["id"] ?? .null])
                        first = first ?? st
                        last = en
                        free[k] = en + brk
                        placed = true
                        break
                    }
                    k += 1
                }
                if !placed {                          // ueber das Tagesende hinaus (hinter das letzte Fenster)
                    let st = free[free.count - 1]
                    try c.execute("UPDATE study_tasks SET start_time=?, end_time=? WHERE id=?",
                                  [.text(LocalFreeWindows.mh(st)), .text(LocalFreeWindows.mh(st + need)), t["id"] ?? .null])
                    first = first ?? st
                    last = st + need
                    free[free.count - 1] = st + need + brk
                }
            }
            if let first {
                try c.execute("UPDATE study_packages SET start_time=?, end_time=? WHERE id=?",
                              [.text(LocalFreeWindows.mh(first)), .text(LocalFreeWindows.mh(last)), p["id"] ?? .null])
            }
        }
    }

    /// `reslot_day(conn, d)`: alle Slots eines Tages neu vergeben (z. B. nach einer Stundenplan-Aenderung, "Lernslots
    /// neu legen"), auch von Hand gesetzte; "Uhrzeiten vergeben" nimmt `assignSlots` (nur Pakete ohne Uhrzeit)
    static func reslotDay(_ c: SQLiteConnection, day d: Int) throws {
        let di = SQLiteValue.text(iso(d))
        try c.execute("UPDATE study_packages SET start_time=NULL, end_time=NULL WHERE date=? AND status NOT IN ('erledigt')", [di])
        try c.execute("UPDATE study_tasks SET start_time=NULL, end_time=NULL WHERE package_id IN (SELECT id FROM study_packages WHERE date=? AND status NOT IN ('erledigt'))", [di])
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
        var b = LocalModules.truthy(end) ? try clockMinutes(end) : a + (LocalModules.truthy(p["planned_minutes"]) ? try int(p["planned_minutes"], "planned_minutes") : 0)
        guard b > a else { throw LocalHTTPError(status: 400, message: "Das Ende muss nach dem Beginn liegen.") }
        if LocalModules.truthy(p["start_time"]) {
            let shift = a - (try LocalFreeWindows.hm(p["start_time"]?.json, key: "start_time"))
            for t in try c.query("SELECT id, start_time, end_time FROM study_tasks WHERE package_id=? AND start_time IS NOT NULL AND end_time IS NOT NULL", [id]) {
                let ts = try LocalFreeWindows.hm(t["start_time"]?.json, key: "start_time"), te = try LocalFreeWindows.hm(t["end_time"]?.json, key: "end_time") + shift
                try c.execute("UPDATE study_tasks SET start_time=?, end_time=? WHERE id=?",
                              [.text(LocalFreeWindows.mh(ts + shift)), .text(LocalFreeWindows.mh(te)), t["id"] ?? .null])
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
        let a = try clockMinutes(start), b = try clockMinutes(end)
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
        for m in try c.query("SELECT id FROM modules WHERE COALESCE(active,1)=1") {
            for u in try units(c, moduleID: m[0], exclude: done, dates: dates) {
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
