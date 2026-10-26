import Foundation

/// Lernkalender, Lernpakete, Aufgaben und Uebersicht wie app/server.py: `/api/calendar*`, `/api/tasks*` (ohne
/// `start-test`: Wochentests entfallen), `/api/packages*`, `/api/timetable/reslot` und `/api/dashboard`. Logik in
/// `StudyPlan`, `StudyCalendar`, `StudyReschedule`; jede Anfrage ist eine Transaktion wie `db.cursor()` (scheitert sie,
/// bleibt nichts geaendert). Ersetzt die Platzhalter aus S2.
///
/// Abweichungen von Python: falsche Datumsangaben (Query, `date`, `start`, `dates`) geben 422 statt 500; Zeitraeume
/// von Kalender und Planung und `horizon` hoechstens `LocalTimetable.maxDays` Tage; `suggest` erwartet `task_ids` als
/// Liste.
public enum StudyEndpoints: LocalEndpointModule {
    public static let name = "Lernkalender"

    typealias T = LocalTimetable

    /// Gueltige Status fuer `POST /api/tasks/{id}/status`
    static let statuses: Set<String> = ["geplant", "in_bearbeitung", "erledigt", "nachholen", "uebersprungen"]
    /// Felder, die `PATCH /api/tasks/{id}` aendern darf
    static let taskFields: Set<String> = ["title", "est_minutes", "sort", "type"]

    /// `date.fromisoformat(v)` fuer Werte aus dem Rumpf (Python: 500, hier 422)
    static func day(_ v: JSONValue?, _ field: String) throws -> Int { try T.day(v, field, status: 422) }

    /// Einstellungen in Antworten wie `_public_settings`
    static func publicSettings(_ o: [String: JSONValue]) -> [String: JSONValue] {
        var out = o
        if let s = o["settings"]?.object { out["settings"] = .object(LocalSettings.publicSettings(s)) }
        return out
    }

    public static func register(on router: LocalRouter) {
        registerCalendar(on: router)
        registerTasks(on: router)
        registerPackages(on: router)

        // Lernslots der betroffenen Tage neu in freie Fenster legen (ohne Angabe: Tage mit Konflikten in 4 Wochen). Mit
        // only_unset ("Uhrzeiten vergeben") nur Pakete ohne Uhrzeit, von Hand gesetzte bleiben (seit dem 26.10.2026)
        router.post("/api/timetable/reslot") { req, ctx in
            let b = try req.objectBody(orEmpty: true)
            let onlyUnset = T.truthy(b["only_unset"])
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { c -> JSONValue in
                var dates = T.truthy(b["dates"]) ? b["dates"]! : .array([])
                if dates.array?.isEmpty == true {
                    let t = T.today(clock)
                    let found = Set(try T.slotConflicts(c, from: t, to: t + 28).compactMap { $0["date"]?.string })
                    dates = .array(found.sorted(by: PyText.less).map(JSONValue.string))
                }
                guard let list = dates.array else { throw LocalHTTPError(status: 422, message: "dates ist keine Liste") }
                for d in list {
                    if onlyUnset { try StudyPlan.assignSlots(c, day: try day(d, "dates")) } else { try StudyPlan.reslotDay(c, day: try day(d, "dates")) }
                }
                return ["reslotted": dates]
            })
        }

        router.get("/api/dashboard") { _, ctx in
            let clock = ctx.clock
            var d = try await ctx.database.transaction { try StudyCalendar.dashboard($0, clock: clock) }
            d["bg"] = LocalPending.bg
            return .json(.object(publicSettings(d)))
        }
    }

    // MARK: Kalender

    static func registerCalendar(on router: LocalRouter) {
        router.get("/api/calendar") { req, ctx in
            let start = try T.queryDay(req, "start"), end = try T.queryDay(req, "end")
            _ = try T.span(end - start)
            let clock = ctx.clock
            let cal = try await ctx.database.transaction { try StudyCalendar.calendar($0, from: start, to: end, clock: clock) }
            return .json(.object(publicSettings(cal)))
        }

        router.post("/api/calendar/generate") { req, ctx in
            let b = try req.objectBody(orEmpty: true)
            let start: Int? = T.truthy(b["start"]) ? try day(b["start"], "start") : nil
            let clock = ctx.clock
            // "Lerneinheit automatisch einplanen" im freien Fenster: ein Paket genau in dieses Fenster
            if T.truthy(b["window_start"]) || T.truthy(b["window_end"]) {
                let from = b["window_start"], to = b["window_end"]
                return .json(try await ctx.database.transaction { c in
                    try StudyPlan.planWindow(c, day: start ?? T.today(clock), start: from, end: to, clock: clock)
                })
            }
            let days = try T.span(try T.int(T.or(b["days"], 7), "days"))
            let replace = T.truthy(b["replace"])
            return .json(try await ctx.database.transaction { c in
                try StudyPlan.generatePackages(c, start: start, days: days, replace: replace, clock: clock)
            })
        }

        router.get("/api/calendar/feasibility") { _, ctx in
            let clock = ctx.clock
            return .json(try await ctx.database.withConnection { try StudyPlan.feasibility($0, clock: clock) })
        }

        // Vorschlag: "Woche retten" (rescue), Paket neu einplanen (package_id), Auswahl (task_ids), sonst alles Nachzuholende
        router.post("/api/calendar/suggest") { req, ctx in
            let b = try req.objectBody(orEmpty: true)
            let clock = ctx.clock
            if T.truthy(b["rescue"]) {
                return .json(try await ctx.database.transaction { try StudyReschedule.rescueWeek($0, clock: clock) })
            }
            var ids: [SQLiteValue]?
            if T.truthy(b["task_ids"]) {
                guard let list = b["task_ids"]?.array else { throw LocalHTTPError(status: 500, message: "task_ids ist keine Liste") }
                ids = try list.map { try T.bind($0, "task_ids") }
            }
            var package: SQLiteValue?                  // `package_id is not None`
            if let p = b["package_id"], !p.isNull { package = try T.bind(p, "package_id") }
            let horizon = try T.span(try T.int(T.or(b["horizon"], 10), "horizon"))
            let taskIDs = ids, packageID = package
            return .json(try await ctx.database.transaction { c in
                try StudyReschedule.suggest(c, taskIDs: taskIDs, packageID: packageID, horizon: horizon, clock: clock)
            })
        }

        router.post("/api/calendar/apply") { req, ctx in
            let b = try req.objectBody()
            let moves: [JSONValue]
            if T.truthy(b["moves"]) {
                guard let list = b["moves"]?.array else { throw LocalHTTPError(status: 500, message: "moves ist keine Liste") }
                moves = list
            } else {
                moves = []
            }
            let clock = ctx.clock
            let n = try await ctx.database.transaction { try StudyReschedule.applyMoves($0, moves, clock: clock) }
            return .json(["moved": .number(Double(n))])
        }
    }

    // MARK: Aufgaben

    static func registerTasks(on router: LocalRouter) {
        router.get("/api/tasks/open") { _, ctx in
            let clock = ctx.clock
            return .json(.array(try await ctx.database.transaction { try StudyCalendar.openTasks($0, clock: clock) }))
        }

        router.post("/api/tasks/{task_id:int}/status") { req, ctx in
            let b = try req.objectBody()
            guard let st = b["status"]?.string, statuses.contains(st) else { throw LocalHTTPError(status: 400, message: "Ungültiger Status") }
            let id = SQLiteValue.integer(Int64(req.intParam("task_id")))
            let minutes = try T.bind(b["actual_minutes"], "actual_minutes"), note = try T.bind(T.or(b["note"], ""), "note")
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { c -> JSONValue in
                guard let t = try StudyPlan.setTaskStatus(c, taskID: id, status: st, actualMinutes: minutes, note: note, clock: clock) else {
                    throw LocalHTTPError.notFound("Aufgabe nicht gefunden")
                }
                return t
            })
        }

        router.patch("/api/tasks/{task_id:int}") { req, ctx in
            let b = try req.objectBody()
            let id = SQLiteValue.integer(Int64(req.intParam("task_id")))
            var changes: [(String, SQLiteValue)] = []
            for k in b.keys.sorted() where taskFields.contains(k) { changes.append((k, try T.bind(b[k], k))) }
            let set = changes
            return .json(try await ctx.database.transaction { c -> JSONValue in
                for (k, v) in set { try c.execute("UPDATE study_tasks SET \(k)=? WHERE id=?", [v, id]) }
                if let t = try c.queryOne("SELECT package_id FROM study_tasks WHERE id=?", [id]) {
                    try StudyPlan.recalcPackage(c, t["package_id"] ?? .null)
                }
                return try c.rows("SELECT * FROM study_tasks WHERE id=?", [id]).first.map(JSONValue.object) ?? .null
            })
        }

        router.delete("/api/tasks/{task_id:int}") { req, ctx in
            let id = SQLiteValue.integer(Int64(req.intParam("task_id")))
            try await ctx.database.transaction { c in
                let t = try c.queryOne("SELECT package_id FROM study_tasks WHERE id=?", [id])
                try c.execute("DELETE FROM study_tasks WHERE id=?", [id])
                if let t { try StudyPlan.recalcPackage(c, t["package_id"] ?? .null) }
            }
            return .ok
        }

        router.post("/api/tasks/skip") { req, ctx in
            let b = try req.objectBody()
            let ids = try TimetableEndpoints.iterable(b["task_ids"], "task_ids", strict: false).map { try T.int($0, "task_ids") }
            let clock = ctx.clock
            try await ctx.database.transaction { try StudyReschedule.skipTasks($0, ids, clock: clock) }
            return .ok
        }

        router.get("/api/tasks/history") { req, ctx in
            var limit = 50
            if let raw = req.query("limit") {
                guard let n = Int(raw.trimmingCharacters(in: .whitespaces)) else {
                    throw LocalHTTPError.validation(type: "int_parsing", loc: ["query", "limit"],
                                                    msg: "Input should be a valid integer, unable to parse string as an integer", input: .string(raw))
                }
                limit = n
            }
            let l = limit
            return .json(.array(try await ctx.database.rows(
                "SELECT h.*, t.title FROM task_history h LEFT JOIN study_tasks t ON t.id=h.task_id ORDER BY h.id DESC LIMIT ?",
                [.integer(Int64(l))]).map(JSONValue.object)))
        }
    }

    // MARK: Lernpakete

    static func registerPackages(on router: LocalRouter) {
        // Lernpaket von Hand ("+ Lernpaket", eigener Lernblock, freie Zeit nutzen) mit Aufgaben, sonst einer freien
        // Aufgabe ueber die Dauer
        router.post("/api/packages") { req, ctx in
            let b = try req.objectBody()
            var tasks: [StudyPlan.NewTask] = []
            for t in try TimetableEndpoints.iterable(b["tasks"], "tasks", strict: true) {
                guard let o = t.object else { throw LocalHTTPError(status: 500, message: "Aufgabe ist kein Objekt") }
                tasks.append(StudyPlan.NewTask(type: try T.bind(T.or(o["type"], "frei"), "type"), fileID: try T.bind(o["file_id"], "file_id"),
                                               title: try T.bind(T.or(o["title"], "Lernen"), "title"),
                                               est: try T.int(T.or(o["est_minutes"], 45), "est_minutes")))
            }
            if tasks.isEmpty {
                tasks = [StudyPlan.NewTask(type: "frei", fileID: .null, title: try T.bind(T.or(b["title"], "Lernen"), "title"),
                                           est: try T.int(T.or(b["minutes"], 60), "minutes"))]
            }
            let date = try day(b["date"], "date")
            // ohne Ternaer: `nil` waere dort SQLiteValue.null (ExpressibleByNilLiteral), nicht "kein Wert"
            var moduleID: SQLiteValue?
            if T.truthy(b["module_id"]) { moduleID = try T.bind(b["module_id"], "module_id") }
            let subject = try T.bind(T.or(b["subject"], "Allgemein"), "subject")
            var title: SQLiteValue?
            if T.truthy(b["title"]) { title = try T.bind(b["title"], "title") }
            let planned = tasks, module = moduleID, heading = title
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { c -> JSONValue in
                let m = try module.flatMap { try c.queryOne("SELECT * FROM modules WHERE id=?", [$0]) }
                let name = m.map { $0["name"] ?? .null } ?? subject
                let pid = try StudyPlan.insertPackage(c, day: date, moduleID: m?["id"] ?? .null, subject: name, title: heading ?? name,
                                                      weekNo: .null, tasks: planned, clock: clock)
                try c.execute("UPDATE study_packages SET generated=0 WHERE id=?", [.integer(pid)])
                return try c.rows("SELECT * FROM study_packages WHERE id=?", [.integer(pid)]).first.map(JSONValue.object) ?? .null
            })
        }

        router.get("/api/packages/{package_id:int}") { req, ctx in
            let id = SQLiteValue.integer(Int64(req.intParam("package_id")))
            let clock = ctx.clock
            guard let p = try await ctx.database.transaction({ try StudyCalendar.package($0, id: id, clock: clock) }) else {
                throw LocalHTTPError.notFound()
            }
            return .json(p)
        }

        router.post("/api/packages/{package_id:int}/tasks") { req, ctx in
            let b = try req.objectBody()
            let id = SQLiteValue.integer(Int64(req.intParam("package_id")))
            let type = try T.bind(T.or(b["type"], "frei"), "type"), file = try T.bind(T.or(b["file_id"], .null), "file_id")
            let title = try T.bind(T.or(b["title"], "Lernen"), "title")
            let est = try T.int(T.or(b["est_minutes"], 45), "est_minutes")
            let clock = ctx.clock
            try await ctx.database.transaction { c in
                guard try c.queryOne("SELECT 1 FROM study_packages WHERE id=?", [id]) != nil else { throw LocalHTTPError.notFound() }
                let n = try c.scalar("SELECT COUNT(*) n FROM study_tasks WHERE package_id=?", [id]) ?? .integer(0)
                try c.execute("INSERT INTO study_tasks(package_id, type, file_id, test_id, title, sort, est_minutes, status, created_at) VALUES (?,?,?,?,?,?,?, 'geplant', ?)",
                              [id, type, file, .null, title, n, .integer(Int64(est)), .text(clock.nowISO)])
                try StudyPlan.recalcPackage(c, id)
                try StudyPlan.refreshStatuses(c, today: T.today(clock))
            }
            return .ok
        }

        // Tag (verschieben), Titel, Reihenfolge, Uhrzeit (seit dem 26.10.2026 gespeichert, zuerst in Python korrigiert)
        router.patch("/api/packages/{package_id:int}") { req, ctx in
            let b = try req.objectBody()
            let id = SQLiteValue.integer(Int64(req.intParam("package_id")))
            var newDate: SQLiteValue?                  // ohne Ternaer, siehe POST /api/packages
            if T.truthy(b["date"]) { newDate = try T.bind(b["date"], "date") }
            var fields: [(String, SQLiteValue)] = []
            for k in ["title", "sort"] where b[k] != nil { fields.append((k, try T.bind(b[k], k))) }
            let time = b["start_time"] != nil || b["end_time"] != nil ? (b["start_time"], b["end_time"]) : nil
            let set = fields, moveTo = newDate
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { c -> JSONValue in
                if let moveTo, !(try StudyReschedule.movePackage(c, id: id, to: moveTo, clock: clock)) {
                    throw LocalHTTPError.notFound("Paket nicht gefunden")
                }
                for (k, v) in set { try c.execute("UPDATE study_packages SET \(k)=? WHERE id=?", [v, id]) }
                if let time { try StudyPlan.setPackageTime(c, packageID: id, start: time.0, end: time.1) }
                return try c.rows("SELECT * FROM study_packages WHERE id=?", [id]).first.map(JSONValue.object) ?? .null
            })
        }

        router.delete("/api/packages/{package_id:int}") { req, ctx in
            let id = SQLiteValue.integer(Int64(req.intParam("package_id")))
            try await ctx.database.transaction { c in
                try c.execute("DELETE FROM study_tasks WHERE package_id=?", [id])
                try c.execute("DELETE FROM study_packages WHERE id=?", [id])
            }
            return .ok
        }
    }
}
