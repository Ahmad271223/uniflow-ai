import Foundation

/// Wochen von Hand (07.11.2026, `ModuleSections`): Dateien in eine andere Woche oder einen eigenen Abschnitt legen,
/// zurueck auf automatisch, eigene Abschnitte je Modul anlegen, umbenennen, ordnen, loeschen. Nur im lokalen Backend
/// (der PC-Server kennt das nicht); registriert aus `ModulesEndpoints`.
///
/// - `POST /api/files/week` `{file_ids: [...], week: n}`: eine oder mehrere Dateien in die Woche `n` (Index der
///   Anzeige wie in `GET /api/modules/{id}`; ein Abschnitt hat die Nummer `ModuleSections.weekCode`);
///   `{file_ids: [...], auto: true}`: zurueck auf automatisch. Antwort `{changed: k}`.
/// - `GET /api/modules/{id}/sections`: `{sections: [...], choices: [...]}` (Abschnitte und die Wochenliste)
/// - `POST /api/modules/{id}/sections` `{name, after_week?, file_ids?}`: neuer Abschnitt (und gleich Dateien hinein)
/// - `PATCH /api/modules/{id}/sections/{sid}` `{name?, after_week?}`
/// - `POST /api/modules/{id}/sections/{sid}/move` `{direction: "up" | "down"}`
/// - `DELETE /api/modules/{id}/sections/{sid}`: Abschnitt weg, seine Dateien zurueck auf automatisch
enum WeekAssignmentEndpoints {

    static func ids(_ body: [String: JSONValue]) -> [String] {
        (body["file_ids"]?.array ?? []).compactMap { $0.string ?? $0.int.map(String.init) }
    }

    /// Abschnitte und Wochenliste eines Moduls
    static func listing(_ c: SQLiteConnection, moduleID: Int, clock: UniFlowClock) throws -> JSONValue {
        guard let d = try LocalModules.detail(c, moduleID: .integer(Int64(moduleID)), clock: clock) else {
            throw LocalHTTPError.notFound("Modul nicht gefunden")
        }
        return ["sections": d["sections"] ?? .array([]), "choices": d["week_choices"] ?? .array([])]
    }

    static func register(on router: LocalRouter) {
        router.post("/api/files/week") { req, ctx in
            let body = try req.objectBody()
            let files = ids(body)
            guard !files.isEmpty else { throw LocalHTTPError(status: 400, message: "file_ids fehlt") }
            let now = ctx.clock.nowISO
            let n = try await ctx.database.transaction { c -> Int in
                if body["auto"]?.bool == true || body["week"] == nil || body["week"] == .null {
                    return try ModuleSections.reset(c, fileIDs: files)
                }
                guard let week = body["week"]?.int else { throw LocalHTTPError(status: 400, message: "week: Zahl erwartet") }
                return try ModuleSections.set(c, fileIDs: files, week: week, now: now)
            }
            return .json(["changed": .number(Double(n))])
        }

        router.get("/api/modules/{module_id:int}/sections") { req, ctx in
            let id = req.intParam("module_id"), clock = ctx.clock
            return .json(try await ctx.database.withConnection { try listing($0, moduleID: id, clock: clock) })
        }

        router.post("/api/modules/{module_id:int}/sections") { req, ctx in
            let id = req.intParam("module_id")
            let body = try req.objectBody()
            guard let name = body["name"]?.string else { throw LocalHTTPError(status: 400, message: "Name fehlt") }
            let after = body["after_week"]?.int ?? ModuleSections.topAnchor
            let files = ids(body)
            let now = ctx.clock.nowISO
            let s = try await ctx.database.transaction { c -> ModuleSections.Section in
                let s = try ModuleSections.create(c, moduleID: id, name: name, afterWeek: after, now: now)
                if !files.isEmpty { try ModuleSections.set(c, fileIDs: files, week: s.week, now: now) }
                return s
            }
            return .json(s.json)
        }

        router.patch("/api/modules/{module_id:int}/sections/{section_id:int}") { req, ctx in
            let mid = req.intParam("module_id"), sid = req.intParam("section_id")
            let body = try req.objectBody()
            let s = try await ctx.database.transaction { c -> ModuleSections.Section in
                guard let s = try ModuleSections.get(c, id: sid), s.moduleID == mid else { throw LocalHTTPError.notFound("Abschnitt nicht gefunden") }
                return try ModuleSections.update(c, id: sid, name: body["name"]?.string, afterWeek: body["after_week"]?.int)
            }
            return .json(s.json)
        }

        router.post("/api/modules/{module_id:int}/sections/{section_id:int}/move") { req, ctx in
            let mid = req.intParam("module_id"), sid = req.intParam("section_id")
            let body = try req.objectBody(orEmpty: true)
            let up = body["direction"]?.string != "down"
            let clock = ctx.clock
            let out = try await ctx.database.transaction { c -> JSONValue in
                guard let s = try ModuleSections.get(c, id: sid), s.moduleID == mid else { throw LocalHTTPError.notFound("Abschnitt nicht gefunden") }
                guard let d = try LocalModules.detail(c, moduleID: .integer(Int64(mid)), clock: clock) else { throw LocalHTTPError.notFound("Modul nicht gefunden") }
                let weeks = (d["weeks"]?.array ?? []).compactMap { $0["week"]?.int }
                let sections = try ModuleSections.move(c, id: sid, up: up, weeks: weeks)
                return ["sections": .array(sections.map(\.json))]
            }
            return .json(out)
        }

        router.delete("/api/modules/{module_id:int}/sections/{section_id:int}") { req, ctx in
            let mid = req.intParam("module_id"), sid = req.intParam("section_id")
            try await ctx.database.transaction { c in
                guard let s = try ModuleSections.get(c, id: sid), s.moduleID == mid else { throw LocalHTTPError.notFound("Abschnitt nicht gefunden") }
                try ModuleSections.delete(c, id: sid)
            }
            return .ok
        }
    }
}
