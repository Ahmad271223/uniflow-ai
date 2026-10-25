import Foundation

/// `/api/timetable/*` wie app/server.py (Abschnitt "Stundenplan" und `/api/timetable/auto-status`), Logik in
/// `LocalTimetable`, `LocalFreeWindows` und `LocalTimetableImport`. `/api/timetable/reslot` gehoert zur Lernlogik
/// (S6) und bleibt bis dahin Platzhalter. Abweichungen: falsche Datumsangaben in der Query geben 422 statt 500;
/// Import aus PDF, Bild oder Text braucht KI und antwortet wie die anderen KI-Pfade (404 mit Meldung);
/// `conflicts?days=` hoechstens zehn Jahre.
public enum TimetableEndpoints: LocalEndpointModule {
    public static let name = "Stundenplan"

    typealias T = LocalTimetable

    /// Felder, die PATCH /api/timetable/events/{id} aendern darf
    static let allowed: Set<String> = ["module_id", "title", "kind", "weekday", "start_time", "end_time", "room", "lecturer",
                                       "rrule", "date_from", "date_to", "attend", "color"]

    public static func register(on router: LocalRouter) {
        router.get("/api/timetable/week") { req, ctx in
            let start = try T.queryDay(req, "start")
            return .json(try await ctx.database.withConnection { try T.weekGrid($0, start: start) })
        }

        router.get("/api/timetable/day") { req, ctx in
            let d = try T.queryDay(req, "date")
            return .json(try await ctx.database.withConnection { try T.dayTimeline($0, day: d) })
        }

        router.get("/api/timetable/events") { _, ctx in
            let rows = try await ctx.database.rows("SELECT e.*, m.name AS module_name FROM course_events e LEFT JOIN modules m ON m.id=e.module_id ORDER BY weekday, start_time")
            return .json(.array(rows.map(JSONValue.object)))
        }

        router.post("/api/timetable/events") { req, ctx in
            let b = try req.objectBody()
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { c -> JSONValue in
                try c.execute("""
                    INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, date_from, date_to, attend, source, color, created_at)
                                                  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,1,?,?,?)
                    """, [try T.bind(b["module_id"], "module_id"), try T.bind(b["course_id"], "course_id"),
                          try T.bind(T.or(b["title"], "Veranstaltung"), "title"), try T.bind(T.or(b["kind"], "vorlesung"), "kind"),
                          .integer(Int64(try T.int(b["weekday"] ?? 0, "weekday"))),
                          try T.bind(T.or(b["start_time"], "08:00"), "start_time"), try T.bind(T.or(b["end_time"], "09:30"), "end_time"),
                          try T.bind(T.or(b["room"], ""), "room"), try T.bind(T.or(b["lecturer"], ""), "lecturer"),
                          try T.bind(T.or(b["rrule"], "weekly"), "rrule"), try T.bind(b["date_from"], "date_from"), try T.bind(b["date_to"], "date_to"),
                          try T.bind(T.or(b["source"], "manual"), "source"), try T.bind(b["color"], "color"), .text(clock.nowISO)])
                return try event(c, .integer(c.lastInsertRowID))
            })
        }

        // scope: series (ganze Reihe) | future (ab Datum: Serie teilen) | single (nur dieser Termin -> Ausnahme)
        router.patch("/api/timetable/events/{event_id:int}") { req, ctx in
            var body = try req.objectBody()
            let scope = body.removeValue(forKey: "scope") ?? "series"
            let d = body.removeValue(forKey: "date") ?? .null
            let id: SQLiteValue = .integer(Int64(req.intParam("event_id")))
            let clock = ctx.clock
            let patch = body
            return .json(try await ctx.database.transaction { c -> JSONValue in
                guard let e = try c.queryOne("SELECT * FROM course_events WHERE id=?", [id]) else { throw LocalHTTPError.notFound() }
                if scope == "single" && T.truthy(d) {
                    let date = try T.bind(d, "date")
                    try T.setException(c, eventID: id, date: date, type: "edit", newStart: try T.bind(patch["start_time"], "start_time"),
                                       newEnd: try T.bind(patch["end_time"], "end_time"), note: "einzeln bearbeitet", clock: clock)
                    // "date" ist oben schon entnommen: verschoben wird nur mit new_date (wie in Python)
                    if T.truthy(patch["date"]) || T.truthy(patch["new_date"]) {
                        try T.setException(c, eventID: id, date: date, type: "moved", newDate: try T.bind(patch["new_date"], "new_date"),
                                           newStart: try T.bind(patch["start_time"], "start_time"), newEnd: try T.bind(patch["end_time"], "end_time"),
                                           clock: clock)
                    }
                    return ["ok": true, "scope": "single"]
                }
                if scope == "future" && T.truthy(d) {
                    let prevEnd = T.iso(try T.day(d, "date") - 1)
                    try c.execute("UPDATE course_events SET date_to=? WHERE id=?", [.text(prevEnd), id])
                    var merged: [String: SQLiteValue] = [:]
                    for k in allowed { merged[k] = e[k] ?? .null }
                    for (k, v) in patch where allowed.contains(k) { merged[k] = try T.bind(v, k) }
                    merged["date_from"] = try T.bind(d, "date")
                    merged["date_to"] = e["date_to"] ?? .null
                    func m(_ k: String) -> SQLiteValue { merged[k] ?? .null }
                    try c.execute("""
                        INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, date_from, date_to, attend, source, color, created_at)
                                                      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """, [m("module_id"), e["course_id"] ?? .null, m("title"), m("kind"), m("weekday"), m("start_time"), m("end_time"), m("room"),
                              m("lecturer"), m("rrule"), m("date_from"), m("date_to"), m("attend"), e["source"] ?? .null, m("color"), .text(clock.nowISO)])
                    return ["ok": true, "scope": "future", "new_id": .number(Double(c.lastInsertRowID))]
                }
                for (k, v) in patch where allowed.contains(k) {
                    try c.execute("UPDATE course_events SET \(k)=? WHERE id=?", [try T.bind(v, k), id])
                }
                return try event(c, id)
            })
        }

        router.delete("/api/timetable/events/{event_id:int}") { req, ctx in
            let id: SQLiteValue = .integer(Int64(req.intParam("event_id")))
            try await ctx.database.transaction { c in
                try c.execute("DELETE FROM event_exceptions WHERE event_id=?", [id])
                try c.execute("DELETE FROM course_events WHERE id=?", [id])
            }
            return .ok
        }

        // mode: today_skip | today_attend | permanent_skip | permanent_attend | cancelled | reset; liefert freigewordene Zeit
        router.post("/api/timetable/attendance") { req, ctx in
            let b = try req.objectBody()
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { c -> JSONValue in
                guard let e = try c.rows("SELECT * FROM course_events WHERE id=?", [try T.bind(b["event_id"], "event_id")]).first else {
                    throw LocalHTTPError.notFound()
                }
                let dv = T.or(b["date"], .string(clock.today))
                let day = try T.day(dv, "date")
                let before = try LocalFreeWindows.compute(c, day: day, settings: try LocalSettings.read(c))
                try T.setAttendance(c, eventID: try T.bind(e["id"], "id"), date: try T.bind(dv, "date"), mode: b["mode"], clock: clock)
                let after = try LocalFreeWindows.compute(c, day: day, settings: try LocalSettings.read(c))
                func total(_ w: [JSONValue]) -> Int { w.reduce(0) { $0 + ($1["minutes"]?.int ?? 0) } }
                let mats = try T.materials(c, event: e, day: day, clock: clock)
                let fresh = after.filter { w in !before.contains { $0["start"] == w["start"] && $0["end"] == w["end"] } }
                return ["ok": true, "freed_minutes": .number(Double(max(0, total(after) - total(before)))), "windows": .array(fresh),
                        "materials": .array(mats), "event": .object(e)]
            })
        }

        router.post("/api/timetable/exceptions") { req, ctx in
            let b = try req.objectBody()
            guard let eid = b["event_id"] else { throw LocalHTTPError(status: 500, message: "event_id fehlt") }
            guard let date = b["date"] else { throw LocalHTTPError(status: 500, message: "date fehlt") }
            let clock = ctx.clock
            try await ctx.database.transaction { c in
                try T.setException(c, eventID: .integer(Int64(try T.int(eid, "event_id"))), date: try T.bind(date, "date"),
                                   type: try T.bind(T.or(b["type"], "edit"), "type"), newDate: try T.bind(b["new_date"], "new_date"),
                                   newStart: try T.bind(b["new_start"], "new_start"), newEnd: try T.bind(b["new_end"], "new_end"),
                                   note: try T.bind(T.or(b["note"], ""), "note"), clock: clock)
            }
            return .ok
        }

        router.get("/api/timetable/free") { req, ctx in
            let d = try T.queryDay(req, "date")
            return .json(.array(try await ctx.database.withConnection { c in
                try LocalFreeWindows.compute(c, day: d, settings: try LocalSettings.read(c))
            }))
        }

        router.get("/api/timetable/event-materials/{event_id:int}") { req, ctx in
            let raw = try req.requiredQuery("date")
            let id: SQLiteValue = .integer(Int64(req.intParam("event_id")))
            let clock = ctx.clock
            return .json(.array(try await ctx.database.withConnection { c in
                guard let e = try c.rows("SELECT * FROM course_events WHERE id=?", [id]).first else { throw LocalHTTPError.notFound() }
                guard let d = BerlinClock.parseISODate(raw) else { throw LocalHTTPError(status: 422, message: "Ungültiges Datum: \(raw)") }
                return try T.materials(c, event: e, day: d, clock: clock)
            }))
        }

        // Quelle: studip | ics | text | pdf | image. Liefert bearbeitbare Vorschau + Vergleich mit vorhandenem Plan.
        router.post("/api/timetable/import/preview") { req, ctx in
            let form = try req.multipart()
            guard let source = form.fields["source"] else {
                throw LocalHTTPError.validation(type: "missing", loc: ["body", "source"], msg: "Field required", input: .null)
            }
            let upload = form.file("upload")
            var raw = form.fields["text"] ?? ""
            switch source {
            case "studip":
                break
            case "ics":
                if let upload { raw = String(decoding: upload.data, as: UTF8.self) }
            case "pdf":
                guard upload != nil else { throw LocalHTTPError(status: 400, message: "PDF fehlt") }
                throw LocalHTTPError.notFound(DroppedEndpoints.noAI)
            case "image":
                guard let upload else { throw LocalHTTPError(status: 400, message: "Bild fehlt") }
                let ext = suffix(upload.filename.isEmpty ? "x.png" : upload.filename).lowercased()
                guard [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"].contains(ext.isEmpty ? ".png" : ext) else {
                    throw LocalHTTPError(status: 400, message: "Nur Bilddateien")
                }
                throw LocalHTTPError.notFound(DroppedEndpoints.noAI)
            default:
                // Text: Stundenplan per KI lesen (ai_parse) gibt es in dieser Version nicht
                throw LocalHTTPError.notFound(DroppedEndpoints.noAI)
            }
            let text = raw
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { c -> JSONValue in
                var entries: [LocalTimetableImport.Entry]
                do {
                    if source == "studip" {
                        entries = try LocalTimetableImport.studipEntries(c)
                    } else {
                        entries = LocalTimetableImport.parseICS(text)
                    }
                } catch {
                    let why = (error as? LocalHTTPError)?.detail.string ?? (error as? SQLiteError)?.message ?? "\(error)"
                    throw LocalHTTPError(status: 500, message: "Import fehlgeschlagen: \(why)")
                }
                entries = try LocalTimetableImport.enrich(c, entries)
                var diff = try LocalTimetableImport.diffAgainstExisting(c, entries)
                // Kurszeiten ueber die Verknuepfung zuordnen statt ueber Titel und Wochentag (nur auf dem Geraet)
                if source == "studip" { diff = try StudIPScheduleImport.previewDiff(c, diff, entries: entries) }
                let list: JSONValue = .array(entries.map(JSONValue.object))
                try c.execute("INSERT INTO schedule_imports(source, created_at, status, raw, parsed, confirmed) VALUES (?,?,?,?,?,0)",
                              [.text(source), .text(clock.nowISO), "preview", .text(LocalTimetableImport.slice(text, 0, 20000)),
                               .text(list.jsonString(sortedKeys: true))])
                let importID = c.lastInsertRowID
                let modules = try c.rows("SELECT id, name, color FROM modules ORDER BY name")
                return ["import_id": .number(Double(importID)), "entries": list, "diff": diff, "modules": .array(modules.map(JSONValue.object))]
            })
        }

        router.post("/api/timetable/import/confirm") { req, ctx in
            let b = try req.objectBody()
            let entries = try iterable(b["entries"], "entries", strict: true)
            let source = T.or(b["source"], "manual")
            let removeIDs = try iterable(b["remove_ids"], "remove_ids", strict: false)
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { c -> JSONValue in
                let src = source.string ?? T.text(source)
                var res = try LocalTimetableImport.applyImport(c, entries, source: src, removeIDs: removeIDs, clock: clock,
                                                               imported: StudIPScheduleImport.confirmed(c, source: src, clock: clock))
                if T.truthy(b["import_id"]) {
                    try c.execute("UPDATE schedule_imports SET confirmed=1, status='confirmed' WHERE id=?", [try T.bind(b["import_id"], "import_id")])
                }
                let t = T.today(clock)
                res["conflicts"] = .array(try T.slotConflicts(c, from: t, to: t + 28))
                return res
            })
        }

        router.get("/api/timetable/conflicts") { req, ctx in
            var days = 28
            if let raw = req.query("days") {
                guard let n = Int(raw.trimmingCharacters(in: .whitespaces)) else {
                    throw LocalHTTPError.validation(type: "int_parsing", loc: ["query", "days"],
                                                    msg: "Input should be a valid integer, unable to parse string as an integer", input: .string(raw))
                }
                guard n <= 3660 else { throw LocalHTTPError(status: 422, message: "Höchstens 3660 Tage") }
                days = n
            }
            let t = T.today(ctx.clock)
            let span = days
            return .json(.array(try await ctx.database.withConnection { try T.slotConflicts($0, from: t, to: t + span) }))
        }

        router.get("/api/timetable/auto-status") { _, ctx in
            .json(try await ctx.database.withConnection { c -> JSONValue in
                let entries = try LocalTimetableImport.studipEntries(c)
                // Gruppen aus Kurszeiten, aus denen schon gewaehlt ist, zaehlen nicht (ohne Kurszeiten wie Python)
                let pending = try StudIPScheduleImport.openGroups(c, entries)
                let groups = Set(pending.compactMap { $0["title"]?.string }).sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
                return ["pending_groups": .number(Double(pending.count)), "courses": .array(groups.map(JSONValue.string)),
                        "personal": .array(entries.filter { T.truthy($0["personal"]) }.map(JSONValue.object))]
            })
        }
    }

    /// `db.row(conn, "SELECT * FROM course_events WHERE id=?")`: Zeile oder null
    static func event(_ c: SQLiteConnection, _ id: SQLiteValue) throws -> JSONValue {
        try c.rows("SELECT * FROM course_events WHERE id=?", [id]).first.map(JSONValue.object) ?? .null
    }

    /// `x or []` und danach `for v in x`: Listen ihre Eintraege; Text seine Zeichen und Objekte ihre Schluessel
    /// (wie Python; bei `entries` scheitert beides spaeter mit 500, darum `strict`); andere Werte 500.
    static func iterable(_ v: JSONValue?, _ field: String, strict: Bool) throws -> [JSONValue] {
        guard T.truthy(v), let v else { return [] }
        switch v {
        case .array(let a): return a
        case .string(let s) where !strict: return s.unicodeScalars.map { .string(String($0)) }
        case .object(let o) where !strict: return o.keys.sorted().map(JSONValue.string)
        default: throw LocalHTTPError(status: 500, message: "\(field) ist keine Liste")
        }
    }

    /// `Path(name).suffix` wie in Python: Endung des letzten Teils ab dem letzten Punkt, nicht am Anfang oder Ende
    static func suffix(_ name: String) -> String {
        let last = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        let u = Array(last.unicodeScalars)
        guard let i = u.lastIndex(of: "."), i > 0, i < u.count - 1 else { return "" }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: u[i...])
        return String(out)
    }
}
