import Foundation

/// Module wie app/server.py: `GET /api/modules` (Uebersicht), `GET /api/modules/{id}` (Detail mit Wochen),
/// Anlegen, Aendern, Loeschen, automatische Zuordnung und die Modul-Zuordnung eines Kurses
/// (`POST /api/courses/{id}/module`). Kursliste und Kurs aendern (`/api/courses`) gehoeren zu den Dokumenten (S3).
///
/// Abweichung wie bei `PUT /api/terms`: Werte, die sich nicht in SQLite speichern lassen (Listen, Objekte, zu grosse
/// Zahlen), beantwortet Python mit 500 (InterfaceError/OverflowError), hier 422 mit Meldung.
public enum ModulesEndpoints: LocalEndpointModule {
    public static let name = "Module"

    /// Felder, die `PATCH /api/modules/{id}` aendern darf
    static let patchable: Set<String> = ["name", "color", "icon", "priority", "exam_date", "sort", "semester", "active", "weekly_test", "test_minutes"]

    /// Rumpf als Python-dict: doppelte Schluessel behalten den letzten Wert an der ersten Stelle (PyJSON.parse)
    static func body(_ req: LocalRequest) throws -> [PyJSON.Member] {
        try req.pythonObjectBody()
    }

    static func value(_ members: [PyJSON.Member], _ key: String) -> PyJSON? {
        members.first { $0.key == key }?.value
    }

    public static func register(on router: LocalRouter) {
        router.get("/api/modules") { _, ctx in
            let clock = ctx.clock
            return .json(.array(try await ctx.database.transaction { try LocalModules.overview($0, clock: clock) }))
        }

        router.get("/api/modules/{module_id:int}") { req, ctx in
            let id = SQLiteValue.integer(Int64(req.intParam("module_id")))
            let clock = ctx.clock
            guard let d = try await ctx.database.withConnection({ try LocalModules.detail($0, moduleID: id, clock: clock) }) else {
                throw LocalHTTPError.notFound()
            }
            return .json(.object(d))
        }

        // Kurse ohne Modul per Namensaehnlichkeit zuordnen; manuelle Zuordnungen bleiben unangetastet
        router.post("/api/modules/auto-assign") { _, ctx in
            let clock = ctx.clock
            let result = try await ctx.database.transaction { c -> JSONValue in
                try LocalModules.ensureModules(c, clock: clock)
                var assigned = 0
                var uncertain: [JSONValue] = []
                for course in try c.query("SELECT id, title, kind FROM courses WHERE module_id IS NULL AND id != '__user__'") {
                    if course["kind"]?.string == "sonstiges" { continue }
                    let mid = try ModuleGuess.guessModule(c, title: course["title"]?.string)
                    if LocalModules.truthy(mid) {
                        try c.execute("UPDATE courses SET module_id=?, subject=(SELECT name FROM modules WHERE id=?) WHERE id=?",
                                      [mid ?? .null, mid ?? .null, course["id"] ?? .null])
                        assigned += 1
                    } else {
                        uncertain.append(["id": course.json["id"] ?? .null, "title": course.json["title"] ?? .null, "suggestion": .null])
                    }
                }
                return ["assigned": .number(Double(assigned)), "uncertain": .array(uncertain)]
            }
            return .json(result)
        }

        router.patch("/api/modules/{module_id:int}") { req, ctx in
            let members = try body(req)
            let id = SQLiteValue.integer(Int64(req.intParam("module_id")))
            // for k, v in body.items(): Reihenfolge der ersten Nennung, Wert der letzten
            let updates: [(String, SQLiteValue)] = try members.filter { patchable.contains($0.key) }.map { m in
                (m.key, m.key == "exam_date" && !LocalTerms.truthy(m.value) ? .null : try LocalTerms.bindable(m.value, field: m.key))
            }
            let rename = try value(members, "name").map { try LocalTerms.bindable($0, field: "name") }
            let colorSent = members.contains { $0.key == "color" }
            let custom = members.contains { $0.key == "active" }
            let row = try await ctx.database.transaction { c -> JSONValue in
                let before = try c.queryOne("SELECT color FROM modules WHERE id=?", [id])
                for (k, v) in updates { try c.execute("UPDATE modules SET \(k)=? WHERE id=?", [v, id]) }
                // selbst geschaltet: Module ohne aktiven Kurs schaltet `Semesters.deactivateStaleModules` dann nicht aus
                if custom { try c.execute("UPDATE modules SET active_custom=1 WHERE id=?", [id]) }
                // Merker fuer eine selbst gewaehlte Farbe (ModuleColors): nur, wenn sich die Farbe wirklich aendert (die
                // Bearbeiten-Dialoge schicken sie auch unveraendert mit)
                if colorSent, let before, let after = try c.queryOne("SELECT color FROM modules WHERE id=?", [id]),
                   LocalModules.truthy(after["color"]), after["color"] != before["color"] {
                    try c.execute("UPDATE modules SET color_custom=1 WHERE id=?", [id])
                }
                if let rename {
                    try c.execute("UPDATE courses SET subject=? WHERE module_id=?", [rename, id])
                    try c.execute("UPDATE study_packages SET subject=? WHERE module_id=?", [rename, id])
                }
                // Regel G6 (server._found): kein Datensatz -> 404
                guard let row = try c.queryOne("SELECT * FROM modules WHERE id=?", [id]) else { throw LocalHTTPError.notFound("Modul nicht gefunden") }
                return .object(row.json)
            }
            return .json(row)
        }

        router.post("/api/modules") { req, ctx in
            let members = try body(req)
            // (body.get("name") or "").strip(); kein Text: Python scheitert (500), hier 422
            let rawName = value(members, "name")
            let name: String
            if LocalTerms.truthy(rawName) {
                guard case .string(let s)? = rawName else { throw LocalHTTPError(status: 422, message: "name: Text erwartet") }
                name = PyText.strip(s)
            } else {
                name = ""
            }
            if name.isEmpty { throw LocalHTTPError(status: 400, message: "Name fehlt") }
            let semester = try LocalTerms.bindable(value(members, "semester") ?? .null, field: "semester")
            // body.get("color") or next_color(conn) (SQLiteValue kennt nil als NULL: darum ausdruecklich); eine
            // mitgeschickte Farbe hat der Nutzer gewaehlt (Merker color_custom)
            let colorValue = value(members, "color")
            let color: SQLiteValue? = LocalTerms.truthy(colorValue) ? .some(try LocalTerms.bindable(colorValue ?? .null, field: "color")) : .none
            let now = ctx.clock.nowISO
            let row = try await ctx.database.transaction { c -> JSONValue in
                let n = Int(try c.scalar("SELECT COUNT(*) n FROM modules")?.int64 ?? 0)
                let chosen = try color ?? .text(ModuleColors.next(c))
                try c.execute("INSERT INTO modules(name, semester, color, color_custom, sort, created_at) VALUES (?,?,?,?,?,?)",
                              [.text(name), semester, chosen, .integer(color == nil ? 0 : 1), .integer(Int64(n)), .text(now)])
                return try c.queryOne("SELECT * FROM modules WHERE id=?", [.integer(c.lastInsertRowID)]).map { .object($0.json) } ?? .null
            }
            return .json(row)
        }

        router.delete("/api/modules/{module_id:int}") { req, ctx in
            let id = SQLiteValue.integer(Int64(req.intParam("module_id")))
            try await ctx.database.transaction { c in
                if try c.queryOne("SELECT 1 FROM courses WHERE module_id=?", [id]) != nil {
                    throw LocalHTTPError(status: 400, message: "Modul enthält noch Kurse. Erst Kurse einem anderen Modul zuordnen.")
                }
                try c.execute("DELETE FROM modules WHERE id=?", [id])
                if c.changes == 0 { throw LocalHTTPError.notFound("Modul nicht gefunden") }       // Regel G6 (server._changed)
            }
            return .ok
        }

        // Kurs einem Modul zuordnen (manuell korrigierbar); ohne module_id: Zuordnung loesen
        router.post("/api/courses/{course_id}/module") { req, ctx in
            let members = try body(req)
            let course = SQLiteValue.text(req.param("course_id"))
            let moduleValue = value(members, "module_id")
            guard LocalTerms.truthy(moduleValue) else {
                try await ctx.database.execute("UPDATE courses SET module_id=NULL WHERE id=?", [course])
                return .ok
            }
            let mid = try LocalTerms.bindable(moduleValue ?? .null, field: "module_id")
            try await ctx.database.transaction { c in
                guard let m = try c.queryOne("SELECT id, name FROM modules WHERE id=?", [mid]) else {
                    throw LocalHTTPError.notFound("Modul nicht gefunden")
                }
                try c.execute("UPDATE courses SET module_id=?, subject=? WHERE id=?", [m["id"] ?? .null, m["name"] ?? .null, course])
            }
            return .ok
        }
    }
}
