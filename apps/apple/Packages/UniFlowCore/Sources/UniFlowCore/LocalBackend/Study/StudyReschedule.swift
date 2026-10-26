import Foundation

/// Verschieben, Nachholen, "Woche retten" wie app/study.py: `_capacity`, `suggest_reschedule` (erst Vorschlag, dann
/// Bestaetigung), `_suggest_text`, `apply_moves`, `move_package`, `rescue_week`, `skip_tasks`. Schreibt: in einer
/// Transaktion aufrufen.
enum StudyReschedule {
    typealias T = LocalTimetable

    /// `_capacity(conn, d, s)`: freie Lernminuten eines Tages (Tageszeit minus geplante Pakete)
    static func capacity(_ c: SQLiteConnection, day: Int, settings s: StudyPlan.Settings) throws -> Double {
        let used = try c.scalar("SELECT COALESCE(SUM(planned_minutes),0) m FROM study_packages WHERE date=? AND status NOT IN ('verschoben','uebersprungen')",
                                [.text(T.iso(day))])
        return max(0, Double(s.minutesPerDay) - (try StudyPlan.number(used, "planned_minutes")))
    }

    static let taskSQL = "SELECT t.*, p.date, p.module_id, p.subject FROM study_tasks t JOIN study_packages p ON p.id=t.package_id"

    /// `suggest_reschedule(conn, task_ids, package_id, horizon, max_share)`: freie Lerntage fuer offene Aufgaben
    /// (eines Pakets, ausgewaehlte oder alle nachzuholenden); heute zuerst, wenn heute ein Lerntag ist
    static func suggest(_ c: SQLiteConnection, taskIDs: [SQLiteValue]?, packageID: SQLiteValue?, horizon: Int, maxShare: Double = 1,
                        clock: UniFlowClock) throws -> JSONValue {
        let t0 = T.today(clock)
        try StudyPlan.refreshStatuses(c, today: t0)
        let s = try StudyPlan.Settings(c)
        let tasks: [SQLiteRow]
        if let packageID {
            tasks = try c.query(taskSQL + " WHERE p.id=? AND t.status IN ('geplant','in_bearbeitung','nachholen') ORDER BY t.sort", [packageID])
        } else if let taskIDs, !taskIDs.isEmpty {
            let marks = Array(repeating: "?", count: taskIDs.count).joined(separator: ",")
            tasks = try c.query(taskSQL + " WHERE t.id IN (\(marks)) ORDER BY p.date, t.sort", taskIDs)
        } else {                                       // alle nachzuholenden
            tasks = try c.query(taskSQL + " WHERE t.status='nachholen' ORDER BY p.date, t.sort")
        }
        // Lerntage mit freier Zeit, nach Datum (heute zuerst); bei gleichem Platz gilt der fruehere Tag
        var cap: [(day: Int, minutes: Double)] = []
        if s.isLearnDay(t0) { cap.append((t0, (try capacity(c, day: t0, settings: s) * maxShare).rounded(.towardZero))) }
        if horizon >= 1 {
            for i in 1...horizon where s.isLearnDay(t0 + i) {
                cap.append((t0 + i, (try capacity(c, day: t0 + i, settings: s) * maxShare).rounded(.towardZero)))
            }
        }
        var moves: [JSONValue] = []
        for t in tasks {
            let est = try StudyPlan.number(t["est_minutes"], "est_minutes")
            var placed: Int?
            for i in cap.indices where cap[i].minutes >= est && t["date"] != .text(T.iso(cap[i].day)) {
                cap[i].minutes -= est
                placed = cap[i].day
                break
            }
            if placed == nil, !cap.isEmpty {              // notfalls auf den Lerntag mit dem meisten Platz
                var best = 0
                for i in cap.indices where cap[i].minutes > cap[best].minutes { best = i }
                cap[best].minutes -= est
                placed = cap[best].day
            }
            moves.append(["task_id": t["id"]?.json ?? .null, "title": t["title"]?.json ?? .null, "type": t["type"]?.json ?? .null,
                          "subject": t["subject"]?.json ?? .null, "module_id": t["module_id"]?.json ?? .null,
                          "est_minutes": t["est_minutes"]?.json ?? .null, "from": t["date"]?.json ?? .null,
                          "to": placed.map { .string(T.iso($0)) } ?? .null])
        }
        return ["moves": .array(moves), "message": .string(try suggestText(moves))]
    }

    /// `rescue_week(conn)`: "Meine Woche retten" – alle nachzuholenden Aufgaben auf die naechsten 7 Tage, hoechstens
    /// 60 % der Tageszeit
    static func rescueWeek(_ c: SQLiteConnection, clock: UniFlowClock) throws -> JSONValue {
        try suggest(c, taskIDs: nil, packageID: nil, horizon: 7, maxShare: 0.6, clock: clock)
    }

    /// `_suggest_text(moves)`: "3 offene Aufgaben (Fach A, Fach B) können auf Mo 26.10., Di 27.10. verteilt werden."
    static func suggestText(_ moves: [JSONValue]) throws -> String {
        if moves.isEmpty { return "Keine offenen Aufgaben." }
        func texts(_ key: String) throws -> [String] {
            var seen = Set<[Unicode.Scalar]>()
            var out: [String] = []
            for m in moves where T.truthy(m[key]) {
                guard let s = m[key]?.string else { throw LocalHTTPError(status: 500, message: "\(key) ist kein Text") }
                if seen.insert(Array(s.unicodeScalars)).inserted { out.append(s) }
            }
            return out.sorted(by: PyText.less)
        }
        let wd = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
        let days = try texts("to").map { d -> String in
            guard let n = BerlinClock.parseISODate(d) else { throw LocalHTTPError(status: 500, message: "Ungültiges Datum: \(d)") }
            return "\(wd[BerlinClock.weekday(n)]) \(StudyWeeks.dayMonth(n))"
        }
        return "\(moves.count) offene Aufgaben (\(try texts("subject").joined(separator: ", "))) können auf \(days.joined(separator: ", ")) verteilt werden."
    }

    /// `apply_moves(conn, moves)`: Aufgaben in ein Paket desselben Moduls am Zieltag (sonst ein neues); erledigte und
    /// schon dort liegende bleiben. Liefert die Zahl der verschobenen Aufgaben.
    static func applyMoves(_ c: SQLiteConnection, _ moves: [JSONValue], clock: UniFlowClock) throws -> Int {
        var n = 0
        for mv in moves {
            guard let o = mv.object else { throw LocalHTTPError(status: 500, message: "Verschiebung ist kein Objekt") }
            guard T.truthy(o["to"]) else { continue }
            guard let taskID = o["task_id"] else { throw LocalHTTPError(status: 500, message: "task_id fehlt") }
            let to = try T.bind(o["to"], "to")
            guard let t = try c.queryOne("""
                SELECT t.*, p.date, p.module_id, p.subject, p.title AS ptitle, p.week_no FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.id=?
                """, [try T.bind(taskID, "task_id")]) else { continue }
            if t["status"]?.string == "erledigt" || t["date"] == to { continue }
            let now = SQLiteValue.text(clock.nowISO)
            let pid: SQLiteValue
            if let target = try c.queryOne("SELECT id FROM study_packages WHERE date=? AND module_id IS ? AND status IN ('geplant','in_bearbeitung') ORDER BY id LIMIT 1",
                                           [to, t["module_id"] ?? .null]) {
                pid = target["id"] ?? .null
            } else {
                try c.execute("INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at) VALUES (?,?,?,?,?,0,'geplant',0,0,?)",
                              [to, t["module_id"] ?? .null, t["subject"] ?? .null, t["ptitle"] ?? .null, t["week_no"] ?? .null, now])
                pid = .integer(c.lastInsertRowID)
            }
            let old = t["package_id"] ?? .null
            try c.execute("UPDATE study_tasks SET package_id=?, status='geplant', moved_from=?, sort=(SELECT COALESCE(MAX(sort),-1)+1 FROM study_tasks WHERE package_id=?) WHERE id=?",
                          [pid, t["date"] ?? .null, pid, t["id"] ?? .null])
            try c.execute("INSERT INTO task_history(task_id, package_id, old_status, new_status, old_date, new_date, note, at) VALUES (?,?,?,?,?,?,?,?)",
                          [t["id"] ?? .null, pid, t["status"] ?? .null, "geplant", t["date"] ?? .null, to, "verschoben", now])
            try StudyPlan.recalcPackage(c, old)
            try StudyPlan.recalcPackage(c, pid)
            n += 1
        }
        try StudyPlan.refreshStatuses(c, today: T.today(clock))
        return n
    }

    /// `move_package(conn, package_id, new_date)`: Paket auf einen anderen Tag; nachzuholende Aufgaben werden wieder
    /// geplant. false, wenn es das Paket nicht gibt (Python: ValueError, seit dem 26.10.2026 404).
    static func movePackage(_ c: SQLiteConnection, id: SQLiteValue, to newDate: SQLiteValue, clock: UniFlowClock) throws -> Bool {
        guard let p = try c.queryOne("SELECT * FROM study_packages WHERE id=?", [id]) else { return false }
        try c.execute("UPDATE study_packages SET date=? WHERE id=?", [newDate, id])
        try c.execute("UPDATE study_tasks SET moved_from=?, status=CASE WHEN status='nachholen' THEN 'geplant' ELSE status END WHERE package_id=? AND status!='erledigt'",
                      [p["date"] ?? .null, id])
        for t in try c.query("SELECT id, status FROM study_tasks WHERE package_id=?", [id]) {
            try c.execute("INSERT INTO task_history(task_id, package_id, old_status, new_status, old_date, new_date, note, at) VALUES (?,?,?,?,?,?,?,?)",
                          [t["id"] ?? .null, id, t["status"] ?? .null, t["status"] ?? .null, p["date"] ?? .null, newDate, "Paket verschoben", .text(clock.nowISO)])
        }
        try StudyPlan.refreshStatuses(c, today: T.today(clock))
        return true
    }

    /// `skip_tasks(conn, task_ids)`: bewusst ueberspringen; eine unbekannte Aufgabe bricht alles ab (404)
    static func skipTasks(_ c: SQLiteConnection, _ ids: [Int], clock: UniFlowClock) throws {
        for id in ids {
            guard try StudyPlan.setTaskStatus(c, taskID: .integer(Int64(id)), status: "uebersprungen", note: "bewusst übersprungen", clock: clock) != nil else {
                throw LocalHTTPError.notFound("Aufgabe nicht gefunden")
            }
        }
    }
}
