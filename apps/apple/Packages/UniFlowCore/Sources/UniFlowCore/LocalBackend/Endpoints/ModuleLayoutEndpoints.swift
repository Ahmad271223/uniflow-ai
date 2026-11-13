import Foundation

/// Eigene Wochen und Abschnitte eines Moduls (`ModuleLayout`, Auftrag 12.11.2026). Alle Aenderungen nur auf dem
/// Geraet; der Abgleich schreibt hier nie. Gleiche Pfade am PC-Server (`app/server.py`).
///
/// - `POST /api/modules/{id}/sections` {title, after?} -> {key}
/// - `POST /api/modules/{id}/sections/rename` {key, title}
/// - `POST /api/modules/{id}/sections/delete` {key}
/// - `PUT  /api/modules/{id}/sections/order` {keys}
/// - `POST /api/modules/{id}/place` {file_ids, to}  (`to` null: wieder automatisch)
/// - `POST /api/modules/{id}/suggestions/accept` {file_ids?}
/// - `POST /api/modules/{id}/suggestions/scan`  erste Seiten der nicht zugeordneten Dateien lesen (fuer Vorschlaege)
/// - `DELETE /api/modules/{id}/layout`  eigene Ordnung verwerfen
/// - `POST /api/modules/{id}/done` {file_ids, done}  Haken "erledigt" je Datei bzw. ganze Woche (`ModuleDone`, 13.11.2026)
public enum ModuleLayoutEndpoints: LocalEndpointModule {
    public static let name = "Eigene Wochen"

    static func moduleID(_ req: LocalRequest, _ c: SQLiteConnection) throws -> Int64 {
        let m = Int64(req.intParam("module_id"))
        guard try c.queryOne("SELECT 1 FROM modules WHERE id=?", [.integer(m)]) != nil else { throw LocalHTTPError.notFound("Modul nicht gefunden") }
        return m
    }

    static func edit<T: Sendable>(_ req: LocalRequest, _ ctx: LocalContext,
                                  _ body: @escaping @Sendable (SQLiteConnection, Int64, LocalModules.Dates, String) throws -> T) async throws -> T {
        let clock = ctx.clock
        return try await ctx.database.transaction { c in
            let m = try moduleID(req, c)
            do { return try body(c, m, try LocalModules.Dates(c, clock: clock), clock.nowISO) } catch let e as ModuleLayout.EditError {
                throw LocalHTTPError(status: 400, message: e.message)
            }
        }
    }

    static func text(_ o: [String: JSONValue], _ k: String) -> String? { o[k]?.string }
    static func strings(_ o: [String: JSONValue], _ k: String) -> [String] { o[k]?.array?.compactMap(\.string) ?? [] }

    public static func register(on router: LocalRouter) {
        router.post("/api/modules/{module_id:int}/sections") { req, ctx in
            let o = try req.objectBody()
            let key = try await edit(req, ctx) { c, m, d, now in
                try ModuleLayout.create(c, moduleID: m, title: text(o, "title") ?? "", after: text(o, "after"), start: d.start, term: d.term, now: now)
            }
            return .json(["key": .string(key)])
        }

        router.post("/api/modules/{module_id:int}/sections/rename") { req, ctx in
            let o = try req.objectBody()
            try await edit(req, ctx) { c, m, _, now in try ModuleLayout.rename(c, moduleID: m, key: text(o, "key") ?? "", title: text(o, "title") ?? "", now: now) }
            return .ok
        }

        router.post("/api/modules/{module_id:int}/sections/delete") { req, ctx in
            let o = try req.objectBody()
            try await edit(req, ctx) { c, m, _, now in try ModuleLayout.remove(c, moduleID: m, key: text(o, "key") ?? "", now: now) }
            return .ok
        }

        router.put("/api/modules/{module_id:int}/sections/order") { req, ctx in
            let o = try req.objectBody()
            try await edit(req, ctx) { c, m, _, now in try ModuleLayout.reorder(c, moduleID: m, keys: strings(o, "keys"), now: now) }
            return .ok
        }

        router.post("/api/modules/{module_id:int}/place") { req, ctx in
            let o = try req.objectBody()
            let n = try await edit(req, ctx) { c, m, _, now in
                try ModuleLayout.place(c, moduleID: m, fileIDs: strings(o, "file_ids"), to: text(o, "to"), now: now)
            }
            return .json(["placed": .number(Double(n))])
        }

        router.post("/api/modules/{module_id:int}/suggestions/accept") { req, ctx in
            let o = try req.objectBody(orEmpty: true)
            let only = Set(strings(o, "file_ids"))
            let clock = ctx.clock
            let n = try await edit(req, ctx) { c, m, _, now -> Int in
                let d = try LocalModules.detail(c, moduleID: .integer(m), clock: clock) ?? [:]
                var by: [String: [String]] = [:]
                for f in d["files"]?.array ?? [] {
                    guard let id = f["id"]?.string, let k = f["suggest_key"]?.string, only.isEmpty || only.contains(id) else { continue }
                    by[k, default: []].append(id)
                }
                return try by.reduce(0) { n, e in n + (try ModuleLayout.place(c, moduleID: m, fileIDs: e.value, to: e.key, now: now)) }
            }
            return .json(["placed": .number(Double(n))])
        }

        router.post("/api/modules/{module_id:int}/suggestions/scan") { req, ctx in
            let clock = ctx.clock
            let ids = try await ctx.database.withConnection { c -> [String] in
                let m = try moduleID(req, c)
                let d = try LocalModules.detail(c, moduleID: .integer(m), clock: clock) ?? [:]
                return (d["files"]?.array ?? []).filter {
                    $0["section"]?.string == ModuleLayout.key(week: ModuleLayout.unassignedWeek) && $0["suggest_key"] == nil
                }.compactMap { $0["id"]?.string }
            }
            var read = 0
            for id in ids.prefix(60) where !Task.isCancelled {
                if let p = try? await ScriptSearch.pageTexts(fileID: id, ctx: ctx, ocrScope: .none), !p.isEmpty { read += 1 }
            }
            return .json(["read": .number(Double(read))])
        }

        router.post("/api/modules/{module_id:int}/done") { req, ctx in
            let o = try req.objectBody()
            guard let done = o["done"]?.bool else { throw LocalHTTPError(status: 400, message: "done: true oder false") }
            let wanted = strings(o, "file_ids")
            guard !wanted.isEmpty, wanted.count <= 500 else { throw LocalHTTPError(status: 400, message: "file_ids: 1 bis 500 Dateien") }
            let clock = ctx.clock
            let r = try await edit(req, ctx) { c, m, _, _ -> (files: [String], tasks: Int) in
                // nur Dateien dieses Moduls (wie im Moduldetail)
                let mine = Set((try LocalModules.detail(c, moduleID: .integer(m), clock: clock)?["files"]?.array ?? []).compactMap { $0["id"]?.string })
                return try ModuleDone.set(c, fileIDs: wanted.filter { mine.contains($0) }, done: done, clock: clock)
            }
            return .json(["changed": .array(r.files.map { .string($0) }), "tasks": .number(Double(r.tasks))])
        }

        router.delete("/api/modules/{module_id:int}/layout") { req, ctx in
            try await edit(req, ctx) { c, m, _, _ in try ModuleLayout.reset(c, moduleID: m) }
            return .ok
        }
    }
}
