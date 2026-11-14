import Foundation

/// Lernplaner: Wochenwunsch und "Thema gemacht" (Auftrag des Inhabers 14.11.2026, Teil 1;
/// docs/PLANER-FAECHER-WOCHENWUNSCH.md). Spiegel von app/study_choice.py, gleiche Pfade und Antworten
/// (study-plan.json, Szenario "faecher_wunsch"). Faecher im Lernkalender: `StudyPlanModules`.
///
/// - `GET/PUT /api/calendar/week-wish`: "Diese Woche will ich vor allem X und Y machen" (`plan_week_wish`: Montag und
///   Namen, weil die IDs je Geraet verschieden sind); Speichern plant den Rest der Woche neu.
/// - `POST /api/calendar/topic-done`: Thema erledigt (frueher oder im Termin eines anderen Fachs): Termin wird frei, der
///   verdraengte Termin rueckt nach; dieselbe Datei woanders wird mit erledigt, es entsteht nichts Neues.
enum StudyChoice {
    typealias T = LocalTimetable
    static let wishKey = "plan_week_wish"
    static let maxTasks = 50
    static let openTasks = ["geplant", "in_bearbeitung", "nachholen"]

    // MARK: Wochenwunsch

    /// Faecher, die man sich wuenschen kann: aktive, im Lernkalender gewaehlte Module mit Namen (nach sort, name)
    static func choices(_ c: SQLiteConnection) throws -> [(id: Int64, name: String, color: SQLiteValue)] {
        let off = try StudyPlanModules.offModuleIDs(c)
        return try c.query("SELECT id, name, color FROM modules WHERE COALESCE(active,1)=1 ORDER BY sort, name").compactMap { m in
            guard let id = m["id"]?.int64, !off.contains(id), let name = m["name"]?.string, !name.isEmpty else { return nil }
            return (id, name, m["color"] ?? .null)
        }
    }

    /// Wunsch einer Woche, die noch nicht vorbei ist: Montag, Sonntag, Modul-IDs in der gewuenschten Reihenfolge
    static func wishFor(_ c: SQLiteConnection, today: Int) throws -> (monday: Int, sunday: Int, ids: [Int64])? {
        guard let text = try c.queryOne("SELECT value FROM settings WHERE key=?", [.text(wishKey)])?[0].string, !text.isEmpty,
              let v = (try? PyJSON.parse(text))?.json, v.object != nil,
              let week = v["week"]?.string, let mon = BerlinClock.parseISODate(week), week.count == 10 else { return nil }
        let sun = mon + 6
        if sun < today { return nil }
        var byName: [String: Int64] = [:]
        for ch in try choices(c) where byName[ch.name] == nil { byName[ch.name] = ch.id }
        var ids: [Int64] = []
        for n in v["modules"]?.array ?? [] {
            if let s = n.string, let id = byName[s], !ids.contains(id) { ids.append(id) }
        }
        return ids.isEmpty ? nil : (mon, sun, ids)
    }

    static func wishOut(_ c: SQLiteConnection, today: Int) throws -> JSONValue {
        let mon = StudyWeeks.monday(today)
        let w = try wishFor(c, today: today)
        let order = (w != nil && w!.monday == mon) ? w!.ids : []
        let all = try choices(c)
        let names = Dictionary(all.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return ["week": .string(T.iso(mon)), "modules": .array(order.compactMap { names[$0].map(JSONValue.string) }),
                "choices": .array(all.map { ["id": .number(Double($0.id)), "name": .string($0.name), "color": $0.color.json ?? .null,
                                             "wished": .bool(order.contains($0.id))] })]
    }

    /// Wunsch dieser Woche speichern (leere Liste: kein Wunsch) und den Rest der Woche neu planen
    static func saveWish(_ c: SQLiteConnection, _ body: JSONValue, clock: UniFlowClock) throws -> JSONValue {
        let today = T.today(clock)
        guard body.object != nil, let list = body["modules"]?.array, list.allSatisfy({ $0.string != nil }) else {
            throw LocalHTTPError(status: 422, message: "modules: Liste von Fächern")
        }
        let known = Set(try choices(c).map(\.name))
        var wanted: [String] = []
        for n in list.compactMap(\.string) {
            if !known.contains(n) { throw LocalHTTPError(status: 422, message: "„\(n)“ ist kein Fach im Lernkalender.") }
            if !wanted.contains(n) { wanted.append(n) }
        }
        let mon = StudyWeeks.monday(today)
        let value = "{\"week\":\"\(T.iso(mon))\",\"modules\":" + JSONValue.array(wanted.map(JSONValue.string)).jsonString() + "}"
        try c.execute("INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                      [.text(wishKey), .text(value)])
        let plan: JSONValue
        if try SmartGoals.active(c) {
            let r = try SmartGoals.planNow(c, [:], clock: clock)
            plan = ["smart": true, "applied": r["applied"] ?? .null, "message": r["result"]?["message"] ?? .null]
        } else {
            let r = try StudyPlan.generatePackages(c, start: today, days: mon + 6 - today + 1, replace: true, clock: clock)
            plan = ["smart": false, "created": r["created"] ?? .number(0), "message": r["message"] ?? .null]
        }
        var out = try wishOut(c, today: today).object ?? [:]
        out["plan"] = plan
        return .object(out)
    }

    // MARK: Thema gemacht

    private static let taskSQL = """
        SELECT t.*, p.date, p.module_id, p.subject, p.title AS ptitle, p.week_no, p.source
        FROM study_tasks t JOIN study_packages p ON p.id=t.package_id WHERE t.id=?
        """

    private static func badIDs() -> LocalHTTPError { LocalHTTPError(status: 422, message: "task_ids: Liste von Aufgaben (1 bis \(maxTasks))") }

    /// Ganze Zahl aus JSON (kein Wahrheitswert, keine Kommazahl)
    private static func integer(_ v: JSONValue?) -> Int64? {
        guard case .number(let d)? = v, d == d.rounded(), abs(d) < 9e15 else { return nil }
        return Int64(d)
    }

    /// Paket von heute fuer dieses Fach (nicht vom Stundenplaner), sonst ein neues eigenes
    private static func todayPackage(_ c: SQLiteConnection, _ t: SQLiteRow, today: Int, clock: UniFlowClock) throws -> Int64 {
        if let r = try c.queryOne("""
            SELECT id FROM study_packages WHERE date=? AND module_id IS ? AND COALESCE(source,'')<>'smart' ORDER BY id LIMIT 1
            """, [.text(T.iso(today)), t["module_id"] ?? .null]), let id = r["id"]?.int64 {
            return id
        }
        let subject = t["subject"] ?? .null
        let title: SQLiteValue = (subject.string ?? "").isEmpty ? .text("Erledigt") : subject
        try c.execute("""
            INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at)
            VALUES (?,?,?,?,?,0,'erledigt',0,0,?)
            """, [.text(T.iso(today)), t["module_id"] ?? .null, subject, title, t["week_no"] ?? .null, .text(clock.nowISO)])
        return c.lastInsertRowID
    }

    private static func moveTask(_ c: SQLiteConnection, _ t: SQLiteRow, to pid: Int64, note: String, clock: UniFlowClock) throws {
        try c.execute("""
            UPDATE study_tasks SET package_id=?, moved_from=?, start_time=NULL, end_time=NULL,
            sort=(SELECT COALESCE(MAX(sort),-1)+1 FROM study_tasks WHERE package_id=?) WHERE id=?
            """, [.integer(pid), t["date"] ?? .null, .integer(pid), t["id"] ?? .null])
        let newDate = try c.queryOne("SELECT date FROM study_packages WHERE id=?", [.integer(pid)])?["date"] ?? .null
        try c.execute("""
            INSERT INTO task_history(task_id, package_id, old_status, new_status, old_date, new_date, note, at) VALUES (?,?,?,?,?,?,?,?)
            """, [t["id"] ?? .null, .integer(pid), t["status"] ?? .null, t["status"] ?? .null, t["date"] ?? .null, newDate, .text(note), .text(clock.nowISO)])
    }

    static func topicDone(_ c: SQLiteConnection, _ body: JSONValue, clock: UniFlowClock) throws -> JSONValue {
        let today = T.today(clock), ti = T.iso(today)
        guard body.object != nil, let raw = body["task_ids"]?.array, !raw.isEmpty, raw.count <= maxTasks else { throw badIDs() }
        var ids: [Int64] = []
        for v in raw {
            guard let i = integer(v) else { throw badIDs() }
            if !ids.contains(i) { ids.append(i) }
        }
        var host: SQLiteRow?
        if let ip = body["in_package"], !ip.isNull {
            guard let i = integer(ip) else { throw LocalHTTPError(status: 422, message: "in_package: Lernpaket") }
            guard let row = try c.queryOne("SELECT * FROM study_packages WHERE id=?", [.integer(i)]) else {
                throw LocalHTTPError.notFound("Lernpaket nicht gefunden")
            }
            host = row
        }
        var tasks: [SQLiteRow] = []
        for i in ids {
            guard let t = try c.queryOne(taskSQL, [.integer(i)]) else { throw LocalHTTPError.notFound("Aufgabe nicht gefunden") }
            tasks.append(t)
        }
        let own = ModuleDone.ownResult
        let files = Array(Set(tasks.compactMap { t -> String? in
            guard let f = t["file_id"]?.string, !f.isEmpty, !own.contains(t["type"]?.string ?? "") else { return nil }
            return f
        })).sorted { PyText.less($0, $1) }
        var closing = Set(tasks.filter { openTasks.contains($0["status"]?.string ?? "") }.compactMap { $0["id"]?.int64 })
        if !files.isEmpty {
            let fm = Array(repeating: "?", count: files.count).joined(separator: ",")
            let om = Array(repeating: "?", count: openTasks.count).joined(separator: ",")
            let rm = Array(repeating: "?", count: own.count).joined(separator: ",")
            for r in try c.query("SELECT id FROM study_tasks WHERE file_id IN (\(fm)) AND status IN (\(om)) AND type NOT IN (\(rm))",
                                 files.map { .text($0) } + openTasks.map { .text($0) } + own.map { .text($0) }) {
                if let id = r["id"]?.int64 { closing.insert(id) }
            }
        }
        for t in tasks where openTasks.contains(t["status"]?.string ?? "") {
            let f = t["file_id"]?.string ?? ""
            if f.isEmpty || own.contains(t["type"]?.string ?? "") {
                _ = try StudyPlan.setTaskStatus(c, taskID: t["id"] ?? .null, status: "erledigt", note: "Thema gemacht", clock: clock)
            }
        }
        if !files.isEmpty { _ = try ModuleDone.set(c, fileIDs: files, done: true, clock: clock) }
        // erledigte Aufgaben aus kuenftigen Paketen dorthin, wo sie gemacht wurden
        var touched: [Int64] = []
        var origin: SQLiteRow?
        let hostToday = host.map { !PyText.less(ti, $0["date"]?.string ?? "") && ($0["source"]?.string ?? "") != "smart" } ?? false
        for i in closing.sorted() {
            guard let t = try c.queryOne(taskSQL, [.integer(i)]), let pkg = t["package_id"]?.int64 else { continue }
            if !touched.contains(pkg) { touched.append(pkg) }
            let date = t["date"]?.string ?? ""
            if !PyText.less(ti, date) || t["source"]?.string == "smart" { continue }
            let target = hostToday ? host!["id"]!.int64! : try todayPackage(c, t, today: today, clock: clock)
            try moveTask(c, t, to: target, note: "Thema gemacht", clock: clock)
            if let host, target == host["id"]?.int64, origin == nil, t["module_id"] != host["module_id"] { origin = t }
            if !touched.contains(target) { touched.append(target) }
        }
        // frei gewordene Termine: kuenftige, automatisch erstellte Pakete ohne Aufgaben verschwinden
        var freed: [(date: String, start: SQLiteValue, end: SQLiteValue)] = []
        for pid in touched {
            guard let p = try c.queryOne("SELECT * FROM study_packages WHERE id=?", [.integer(pid)]),
                  (p["source"]?.string ?? "") != "smart" else { continue }
            let n = try c.scalar("SELECT COUNT(*) n FROM study_tasks WHERE package_id=?", [.integer(pid)])?.int64 ?? 0
            let date = p["date"]?.string ?? ""
            if n == 0 && !PyText.less(date, ti) && LocalModules.truthy(p["generated"]) {
                freed.append((date, p["start_time"] ?? .null, p["end_time"] ?? .null))
                try c.execute("UPDATE study_sessions SET package_id=NULL WHERE package_id=?", [.integer(pid)])
                try c.execute("DELETE FROM study_packages WHERE id=?", [.integer(pid)])
            } else {
                try StudyPlan.recalcPackage(c, .integer(pid))
            }
        }
        // der verdraengte Termin: offene Aufgaben von in_package in den ersten frei gewordenen Termin, sonst weiter hinten
        var moved = 0
        if let host, (host["source"]?.string ?? "") != "smart", let hid = host["id"]?.int64 {
            let hostDate = host["date"]?.string ?? ""
            let rest = try c.query("""
                SELECT t.*, p.date FROM study_tasks t JOIN study_packages p ON p.id=t.package_id
                WHERE t.package_id=? AND t.status IN ('geplant','in_bearbeitung','nachholen') ORDER BY t.sort, t.id
                """, [.integer(hid)])
            let slot = freed.sorted { a, b in
                a.date != b.date ? PyText.less(a.date, b.date) : PyText.less(a.start.string ?? "", b.start.string ?? "")
            }.first { !PyText.less($0.date, ti) && !PyText.less($0.date, hostDate) }
            if !rest.isEmpty, let slot {
                try c.execute("""
                    INSERT INTO study_packages(date, module_id, subject, title, week_no, planned_minutes, status, sort, generated, created_at, start_time, end_time)
                    VALUES (?,?,?,?,?,0,'geplant',0,?,?,?,?)
                    """, [.text(slot.date), host["module_id"] ?? .null, host["subject"] ?? .null, host["title"] ?? .null, host["week_no"] ?? .null,
                          host["generated"] ?? .null, .text(clock.nowISO), slot.start, slot.end])
                let pid = c.lastInsertRowID
                for t in rest {
                    try moveTask(c, t, to: pid, note: "Platz für ein anderes Thema", clock: clock)
                    moved += 1
                }
                try StudyPlan.recalcPackage(c, .integer(pid))
            } else if !rest.isEmpty {
                let s = try StudyReschedule.suggest(c, taskIDs: rest.map { $0["id"] ?? .null }, packageID: nil, horizon: 7, clock: clock)
                moved = try StudyReschedule.applyMoves(c, s["moves"]?.array ?? [], clock: clock)
            }
            // bleibt im Termin nur das dort gemachte Thema eines anderen Fachs, ist es jetzt dessen Termin
            let left = Set(try c.query("SELECT id FROM study_tasks WHERE package_id=?", [.integer(hid)]).compactMap { $0["id"]?.int64 })
            if let origin, !left.isEmpty, left.isSubset(of: closing) {
                try c.execute("UPDATE study_packages SET module_id=?, subject=?, title=? WHERE id=?",
                              [origin["module_id"] ?? .null, origin["subject"] ?? .null, origin["ptitle"] ?? .null, .integer(hid)])
            }
            try StudyPlan.recalcPackage(c, .integer(hid))
        }
        try StudyPlan.refreshStatuses(c, today: today)
        let done = closing.count
        var parts = ["\(done) \(done == 1 ? "Aufgabe" : "Aufgaben") erledigt"]
        if !freed.isEmpty { parts.append("\(freed.count) \(freed.count == 1 ? "Termin" : "Termine") frei") }
        if moved > 0 { parts.append("\(moved) \(moved == 1 ? "Aufgabe" : "Aufgaben") neu eingeordnet") }
        return ["done": .number(Double(done)),
                "freed": .array(freed.map { ["date": .string($0.date), "start_time": $0.start.json ?? .null, "end_time": $0.end.json ?? .null] }),
                "moved": .number(Double(moved)), "message": .string(parts.joined(separator: ", ") + ".")]
    }

    // MARK: Lernschritte

    /// `check_step`: Lernschritt abhaken (`{"index": i, "done": true|false}`); alle abgehakt: Aufgabe erledigt; einer
    /// wieder offen bei erledigter Aufgabe: wieder geplant. `steps_done`: JSON-Liste der Nummern, aufsteigend
    static func checkStep(_ c: SQLiteConnection, taskID: Int64, _ body: JSONValue, clock: UniFlowClock) throws -> JSONValue {
        let id = SQLiteValue.integer(taskID)
        guard let t = try c.queryOne("SELECT * FROM study_tasks WHERE id=?", [id]) else { throw LocalHTTPError.notFound("Aufgabe nicht gefunden") }
        let steps = (try? PyJSON.parse(t["steps"]?.string ?? "[]"))?.json.array ?? []
        guard body.object != nil, let index = integer(body["index"]), 0 <= index, index < steps.count,
              let done = body["done"]?.bool else {
            throw LocalHTTPError(status: 422, message: "index: Nummer eines Lernschritts (0 bis \(max(0, steps.count - 1))), done: ja oder nein")
        }
        var got = Set(((try? PyJSON.parse(t["steps_done"]?.string ?? "[]"))?.json.array ?? []).compactMap { v -> Int64? in
            guard let i = integer(v), 0 <= i, i < steps.count else { return nil }
            return i
        })
        if done { got.insert(index) } else { got.remove(index) }
        try c.execute("UPDATE study_tasks SET steps_done=? WHERE id=?",
                      [.text(JSONValue.array(got.sorted().map { .number(Double($0)) }).jsonString()), id])
        let status = t["status"]?.string ?? ""
        if got.count == steps.count && openTasks.contains(status) {
            _ = try StudyPlan.setTaskStatus(c, taskID: id, status: "erledigt", note: "Alle Lernschritte erledigt", clock: clock)
        } else if got.count < steps.count && status == "erledigt" {
            _ = try StudyPlan.setTaskStatus(c, taskID: id, status: "geplant", note: "Lernschritt wieder offen", clock: clock)
        }
        return try c.queryOne("SELECT * FROM study_tasks WHERE id=?", [id]).map { .object($0.json) } ?? .null
    }
}

/// `/api/calendar/week-wish`, `/api/calendar/topic-done`, `/api/tasks/{id}/steps`
enum StudyChoiceEndpoints: LocalEndpointModule {
    static let name = "Wochenwunsch und Thema gemacht"

    static func register(on router: LocalRouter) {
        router.get("/api/calendar/week-wish") { _, ctx in
            let today = LocalTimetable.today(ctx.clock)
            return .json(try await ctx.database.withConnection { try StudyChoice.wishOut($0, today: today) })
        }
        router.put("/api/calendar/week-wish") { req, ctx in
            let body = try req.jsonBody()
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { try StudyChoice.saveWish($0, body, clock: clock) })
        }
        router.post("/api/calendar/topic-done") { req, ctx in
            let body = try req.jsonBody()
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { try StudyChoice.topicDone($0, body, clock: clock) })
        }
        router.post("/api/tasks/{task_id:int}/steps") { req, ctx in
            let body = try req.jsonBody()
            let id = Int64(req.intParam("task_id"))
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { try StudyChoice.checkStep($0, taskID: id, body, clock: clock) })
        }
    }
}
