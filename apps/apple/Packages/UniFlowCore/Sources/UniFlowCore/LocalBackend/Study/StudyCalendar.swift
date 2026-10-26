import Foundation

/// Lernkalender und Uebersicht wie app/study.py: `calendar`, `open_tasks`, `dashboard`. Termine kommen aus dem
/// Stundenplan (`LocalTimetable.occurrences`, S5), freie Fenster aus `LocalFreeWindows`, Module aus
/// `LocalModules.overview` (S4), neue Dateien und letzter Abgleich aus `LocalLibrary` (S3). Schreibt
/// (`ensure_modules`, `refresh_statuses`): in einer Transaktion aufrufen.
enum StudyCalendar {
    typealias T = LocalTimetable

    /// Spalten einer Aufgabe im Kalender und im Paket (Datei, letzte Seite, Ergebnis des Wochentests)
    static let taskColumns = "t.*, f.name AS file_name, f.last_page, te.submitted_at AS test_submitted, te.score AS test_score, te.max_score AS test_max"

    /// `calendar(conn, start, end)`: Tage mit Lernpaketen (samt Aufgaben), Terminen (bis 45 Tage) und Tagesstatus.
    /// `refresh: false`, wenn `refreshStatuses` in derselben Transaktion schon lief (Uebersicht; ein zweiter Lauf
    /// aendert nichts)
    static func calendar(_ c: SQLiteConnection, from start: Int, to end: Int, clock: UniFlowClock, refresh: Bool = true) throws -> [String: JSONValue] {
        try LocalModules.ensureModules(c, clock: clock)
        let today = T.today(clock)
        if refresh { try StudyPlan.refreshStatuses(c, today: today) }
        let pkgs = try c.rows("""
            SELECT p.*, m.color, m.name AS module_name FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id
                                         WHERE p.date BETWEEN ? AND ? ORDER BY p.date, p.sort, p.id
            """, [.text(T.iso(start)), .text(T.iso(end))])
        let ids = pkgs.compactMap { $0["id"].flatMap(SQLiteValue.init(json:)) }
        var byPackage: [JSONValue: [JSONValue]] = [:]
        if !ids.isEmpty {
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            for t in try c.rows("""
                SELECT \(taskColumns)
                FROM study_tasks t LEFT JOIN files f ON f.id=t.file_id LEFT JOIN tests te ON te.id=t.test_id
                WHERE t.package_id IN (\(marks)) ORDER BY t.package_id, t.sort
                """, ids) {
                byPackage[t["package_id"] ?? .null, default: []].append(.object(t))
            }
        }
        let s = try StudyPlan.Settings(c)
        let events = end - start <= 45 ? try T.occurrences(c, from: start, to: end) : []
        var days: [JSONValue] = []
        var d = start
        while d <= end {
            let di = T.iso(d)
            let dp: [[String: JSONValue]] = pkgs.filter { $0["date"]?.string == di }.map { p in
                var o = p
                o["tasks"] = .array(byPackage[p["id"] ?? .null] ?? [])
                return o
            }
            var minutes = 0.0
            for p in dp where LocalModules.truthy(p["planned_minutes"]) {
                guard let n = p["planned_minutes"]?.double else { throw LocalHTTPError(status: 500, message: "planned_minutes ist keine Zahl") }
                minutes += n
            }
            let tasks = dp.flatMap { $0["tasks"]?.array ?? [] }
            let done = tasks.filter { $0["status"]?.string == "erledigt" }.count
            let statuses = dp.map { $0["status"]?.string }
            let st: String
            if dp.isEmpty {
                st = s.isLearnDay(d) ? "leer" : "frei"
            } else if statuses.allSatisfy({ ["erledigt", "uebersprungen", "verschoben"].contains($0 ?? "") }) && statuses.contains("erledigt") {
                st = "erledigt"
            } else if statuses.contains("nachholen") || (d < today && statuses.contains { ["geplant", "in_bearbeitung"].contains($0 ?? "") }) {
                st = done == 0 ? "nachholen" : "teilweise"
            } else if statuses.contains("teilweise") {
                st = "teilweise"
            } else if statuses.contains("in_bearbeitung") {
                st = "in_bearbeitung"
            } else {
                st = "geplant"
            }
            days.append(["date": .string(di), "weekday": .number(Double(BerlinClock.weekday(d))), "status": .string(st),
                         "minutes": .number(minutes), "tasks_done": .number(Double(done)), "tasks_total": .number(Double(tasks.count)),
                         "packages": .array(dp.map(JSONValue.object)), "events": .array(events.filter { $0["date"]?.string == di })])
            d += 1
        }
        return ["start": .string(T.iso(start)), "end": .string(T.iso(end)), "days": .array(days), "settings": .object(s.raw)]
    }

    /// `open_tasks(conn)`: offene Aufgaben (geplant, in Bearbeitung, nachholen) nach Tag
    static func openTasks(_ c: SQLiteConnection, clock: UniFlowClock) throws -> [JSONValue] {
        try StudyPlan.refreshStatuses(c, today: T.today(clock))
        return try c.rows("""
            SELECT t.*, p.date, p.subject, p.title AS package_title, p.module_id, m.color, f.name AS file_name
                                        FROM study_tasks t JOIN study_packages p ON p.id=t.package_id LEFT JOIN modules m ON m.id=p.module_id
                                        LEFT JOIN files f ON f.id=t.file_id
                                        WHERE t.status IN ('geplant','in_bearbeitung','nachholen') ORDER BY p.date, p.sort, t.sort
            """).map(JSONValue.object)
    }

    /// `GET /api/packages/{id}`: Paket mit Farbe, Modulname und Aufgaben; nil, wenn es das Paket nicht gibt
    static func package(_ c: SQLiteConnection, id: SQLiteValue, clock: UniFlowClock) throws -> JSONValue? {
        try StudyPlan.refreshStatuses(c, today: T.today(clock))
        guard var p = try c.rows("SELECT p.*, m.color, m.name AS module_name FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id WHERE p.id=?",
                                 [id]).first else { return nil }
        p["tasks"] = .array(try c.rows("""
            SELECT \(taskColumns)
            FROM study_tasks t LEFT JOIN files f ON f.id=t.file_id LEFT JOIN tests te ON te.id=t.test_id WHERE t.package_id=? ORDER BY t.sort
            """, [id]).map(JSONValue.object))
        return .object(p)
    }

    /// `dashboard(conn)`: heute (Pakete, Termine, freie Fenster), Module, neue Dateien, Woche, Nachholen, naechste
    /// Termine (Klausuren, Lernpakete, Wochentests), letzter Abgleich. Ohne `bg` und mit allen Einstellungen (die
    /// oeffentliche Form setzt der Endpunkt). Die Status werden einmal abgeleitet, nicht je Kalender noch einmal.
    static func dashboard(_ c: SQLiteConnection, clock: UniFlowClock) throws -> [String: JSONValue] {
        try LocalModules.ensureModules(c, clock: clock)
        let t = T.today(clock)
        try StudyPlan.refreshStatuses(c, today: t)
        let cal = try calendar(c, from: t, to: t, clock: clock, refresh: false)
        var today = cal["days"]?.array?.first?.object ?? [:]
        let mods = try LocalModules.overview(c, clock: clock)
        let newFiles = try LocalLibrary.newFiles(c)
        let weekStart = StudyWeeks.monday(t)
        let week = (try calendar(c, from: weekStart, to: weekStart + 6, clock: clock, refresh: false))["days"]?.array ?? []
        let wkTotal = week.reduce(0) { $0 + ($1["tasks_total"]?.int ?? 0) }
        let wkDone = week.reduce(0) { $0 + ($1["tasks_done"]?.int ?? 0) }
        let backlog = try c.scalar("SELECT COUNT(*) n FROM study_tasks WHERE status='nachholen'")?.int ?? 0
        let ti = T.iso(t)
        var upcoming: [[String: JSONValue]] = []
        for m in mods {
            guard LocalModules.truthy(m["exam_date"]) else { continue }
            guard let exam = m["exam_date"]?.string else { throw LocalHTTPError(status: 500, message: "Klausurtermin ist kein Text") }
            if !PyText.less(exam, ti) {
                upcoming.append(["date": .string(exam), "kind": "klausur", "title": .string("Klausur \(T.text(m["name"]))"),
                                 "module_id": m["id"] ?? .null, "color": m["color"] ?? .null])
            }
        }
        for p in try c.rows("SELECT p.*, m.color FROM study_packages p LEFT JOIN modules m ON m.id=p.module_id WHERE p.date > ? AND p.status IN ('geplant') ORDER BY p.date LIMIT 6",
                            [.text(ti)]) {
            upcoming.append(["date": p["date"] ?? .null, "kind": "lernpaket", "title": .string("\(T.text(p["subject"])): \(T.text(p["title"]))"),
                             "module_id": p["module_id"] ?? .null, "color": p["color"] ?? .null, "package_id": p["id"] ?? .null])
        }
        for x in try c.rows("""
            SELECT t.id, t.title, p.date, p.subject FROM study_tasks t JOIN study_packages p ON p.id=t.package_id
            WHERE t.type='test' AND t.status IN ('geplant') AND p.date>=? ORDER BY p.date LIMIT 4
            """, [.text(ti)]) {
            upcoming.append(["date": x["date"] ?? .null, "kind": "test", "title": .string("\(T.text(x["subject"])): \(T.text(x["title"]))"),
                             "task_id": x["id"] ?? .null])
        }
        // upcoming.sort(key=lambda x: x["date"]), stabil
        upcoming = try T.stableSorted(upcoming) { a, b in
            guard let x = a["date"]?.string, let y = b["date"]?.string else { throw LocalHTTPError(status: 500, message: "Datum ist kein Text") }
            return PyText.less(x, y)
        }
        today["events"] = .array(try T.occurrences(c, from: t, to: t))
        today["free"] = .array(try LocalFreeWindows.compute(c, day: t, settings: try LocalSettings.read(c)))
        return ["today": .object(today), "modules": .array(mods), "new_files": .array(Array(newFiles.prefix(50))),
                "new_total": .number(Double(newFiles.count)),
                "week": ["start": .string(T.iso(weekStart)), "done": .number(Double(wkDone)), "total": .number(Double(wkTotal)),
                         "days": .array(week.map { ["date": $0["date"] ?? .null, "status": $0["status"] ?? .null, "minutes": $0["minutes"] ?? .null] })],
                "backlog": .number(Double(backlog)), "upcoming": .array(Array(upcoming.prefix(8)).map(JSONValue.object)),
                "last_sync": try LocalLibrary.lastSync(c), "settings": .object(try LocalSettings.read(c))]
    }
}
