import Foundation

/// Vorlesungs-Seitenmarker, gemeinsame Wochentests und Probeklausuren wie in app/server.py (`/api/markers…`,
/// `/api/weekly/…`). Fehler aus den Regeln (`Weekly.Failure`, in Python `WeeklyError`) kommen als 400 mit Meldung,
/// alle anderen als 500 (`_werr`). Erzeugen und Bewerten brauchen die KI des Nutzers; Marker, Stoffumfang und
/// Uebersicht gehen ohne.
enum WeeklyEndpoints: LocalEndpointModule {
    static let name = "Seitenmarker und gemeinsame Wochentests"

    static func werr(_ e: Error) -> LocalHTTPError {
        if let f = e as? Weekly.Failure { return LocalHTTPError(status: 400, message: f.message) }
        if let h = e as? LocalHTTPError { return h }
        return LocalHTTPError(status: 500, message: "\(e)")
    }

    static func intQuery(_ req: LocalRequest, _ name: String) throws -> Int? {
        guard let raw = req.query(name) else { return nil }
        guard let v = PyConvert.int(raw) else {
            throw LocalHTTPError.validation(type: "int_parsing", loc: ["query", name],
                                            msg: "Input should be a valid integer, unable to parse string as an integer", input: .string(raw))
        }
        return v
    }

    static func register(on router: LocalRouter) {
        router.get("/api/markers") { req, ctx in
            let moduleID = try intQuery(req, "module_id"), fileID = req.query("file_id")
            if let fileID { try await Weekly.ensurePages([fileID], ctx) }
            let now = Weekly.now(ctx)
            return .json(.array(try await ctx.database.transaction { c in
                if let fileID { try Weekly.revalidateMarkers(c, fileID: fileID, now: now) }
                return try Weekly.listMarkers(c, moduleID: moduleID, fileID: fileID).map(JSONValue.object)
            }))
        }

        router.get("/api/markers/preview") { req, ctx in
            guard let fileID = req.query("file_id") else {
                throw LocalHTTPError.validation(type: "missing", loc: ["query", "file_id"], msg: "Field required", input: .null)
            }
            guard let page = try intQuery(req, "page") else {
                throw LocalHTTPError.validation(type: "missing", loc: ["query", "page"], msg: "Field required", input: .null)
            }
            try await Weekly.ensurePages([fileID], ctx)
            let now = Weekly.now(ctx), date = req.query("lecture_date")
            do {
                return .json(.object(try await ctx.database.withConnection { c in
                    try Weekly.markerPreview(c, fileID: fileID, page: page, now: now, lectureDate: date)
                }))
            } catch { throw werr(error) }
        }

        router.post("/api/markers") { req, ctx in
            let body = try req.objectBody()
            guard let fileID = body["file_id"] else { throw LocalHTTPError(status: 400, message: "Feld fehlt: 'file_id'") }
            guard let rawPage = body["page"] else { throw LocalHTTPError(status: 400, message: "Feld fehlt: 'page'") }
            let fid = fileID.string ?? PyJSON(fileID).dumps
            try await Weekly.ensurePages([fid], ctx)
            let now = Weekly.now(ctx)
            do {
                guard let page = rawPage.int ?? rawPage.string.flatMap(PyConvert.int) else { throw LocalHTTPError(status: 500, message: "invalid literal for int()") }
                return .json(.object(try await ctx.database.transaction { c in
                    try Weekly.createMarker(c, fileID: fid, page: page, lectureDate: body["lecture_date"]?.string, topic: body["topic"]?.string,
                                            pageKey: body["page_key"]?.string, now: now)
                }))
            } catch { throw werr(error) }
        }

        router.patch("/api/markers/{marker_id:int}") { req, ctx in
            let id = Int64(req.param("marker_id")) ?? 0
            let body = try req.objectBody()
            let page: Int? = body["page"].flatMap { $0 == .null ? nil : ($0.int ?? $0.string.flatMap(PyConvert.int)) }
            let now = Weekly.now(ctx)
            do {
                if let f = try await ctx.database.withConnection({ c in try Weekly.markerRow(c, id)?["file_id"]?.string }) {
                    try await Weekly.ensurePages([f], ctx)
                }
                return .json(.object(try await ctx.database.transaction { c in
                    try Weekly.updateMarker(c, id: id, page: page, lectureDate: body["lecture_date"]?.string, topic: body["topic"]?.string,
                                            pageKey: body["page_key"]?.string, now: now)
                }))
            } catch { throw werr(error) }
        }

        router.delete("/api/markers/{marker_id:int}") { req, ctx in
            let id = Int64(req.param("marker_id")) ?? 0
            let now = Weekly.now(ctx)
            do {
                try await ctx.database.transaction { c in try Weekly.deleteMarker(c, id: id, now: now) }
                return .json(["ok": true])
            } catch { throw werr(error) }
        }

        router.post("/api/markers/{marker_id:int}/release") { req, ctx in
            let id = Int64(req.param("marker_id")) ?? 0
            let body = try req.objectBody(orEmpty: true)
            let confirm = body["confirm"].map { LocalModules.truthy(Weekly.v($0)) || ($0.object.map { !$0.isEmpty } ?? false) || ($0.array.map { !$0.isEmpty } ?? false) } ?? false
            let now = Weekly.now(ctx)
            do {
                return .json(.object(try await ctx.database.transaction { c in try Weekly.releaseMarker(c, id: id, confirm: confirm, now: now) }))
            } catch { throw werr(error) }
        }

        router.get("/api/weekly/module/{module_id:int}") { req, ctx in
            let mid = Int(req.param("module_id")) ?? 0
            let now = Weekly.now(ctx)
            return .json(try await ctx.database.withConnection { c in try Weekly.moduleOverview(c, mid, now: now) })
        }

        router.get("/api/weekly/defs/{def_id:int}") { req, ctx in
            let id = Int64(req.param("def_id")) ?? 0
            do { return .json(try await ctx.database.withConnection { c in try Weekly.defDetails(c, id) }) } catch { throw werr(error) }
        }

        router.post("/api/weekly/defs/{def_id:int}/attempt") { req, ctx in
            let id = Int64(req.param("def_id")) ?? 0
            let now = ctx.clock.nowISO
            do {
                return .json(["test_id": .number(Double(try await ctx.database.transaction { c in try Weekly.attemptFor(c, id, nowISO: now) }))])
            } catch { throw werr(error) }
        }

        router.get("/api/weekly/ranking") { req, ctx in
            guard let mid = try intQuery(req, "module_id") else {
                throw LocalHTTPError.validation(type: "missing", loc: ["query", "module_id"], msg: "Field required", input: .null)
            }
            let week = try intQuery(req, "week_no")
            return .json(.array(try await ctx.database.withConnection { c in try Weekly.moduleRanking(c, mid, week: week) }))
        }

        router.post("/api/weekly/tick") { _, ctx in
            // "Erneut versuchen": fehlgeschlagene Plaene bekommen wieder drei Versuche (nie veroeffentlicht ohne Pruefung)
            _ = try await ctx.database.execute("UPDATE wt_plans SET attempts=0 WHERE status='fehlgeschlagen'")
            return .json(try await ctx.jobs.start("Wochentests") { Weekly.summary(try await Weekly.tick(ctx)) })
        }

        router.post("/api/weekly/mock-exam") { req, ctx in
            let body = try req.objectBody()
            let mid = body["module_id"].flatMap { LocalModules.truthy(Weekly.v($0)) ? ($0.int ?? $0.string.flatMap(PyConvert.int)) : 0 } ?? 0
            let full = body["full"].map { LocalModules.truthy(Weekly.v($0)) } ?? false
            do {   // Vorpruefung sofort (z. B. "noch nicht alles markiert"), Erzeugung im Hintergrund
                let empty = try await ctx.database.withConnection { c in try Weekly.coverage(c, moduleID: mid).segments.isEmpty }
                if empty { throw Weekly.Failure("Noch kein Vorlesungsstoff markiert – Probeklausur nicht möglich.") }
            } catch { throw werr(error) }
            return .json(try await ctx.jobs.start("Probeklausur") {
                let r = try await Weekly.createMockExam(ctx, moduleID: mid, full: full)
                return r["test_id"]?.int.map(String.init)
            })
        }
    }
}

extension Weekly {
    /// Meldung des Hintergrundauftrags nach `tick` (am PC `str(dict)`)
    static func summary(_ r: JSONValue) -> String? {
        func n(_ k: String) -> Int { r[k]?.array?.count ?? 0 }
        let text = "\(n("published")) veröffentlicht, \(n("waiting")) wartend, \(n("failed")) fehlgeschlagen, \(n("nachtraege")) Nachträge"
        return text
    }
}

/// Takt der gemeinsamen Wochentests auf dem iPad wie `_weekly_loop` in app/server.py: alle 10 min, nur mit
/// `auto_tests`, nie neben einem anderen Hintergrundauftrag (am PC `_bg_lock`). Zusaetzlich gilt: ohne verbundene KI
/// kein Lauf, denn jeder Lauf ohne KI wuerde einen der drei Versuche eines faelligen Plans verbrauchen. Die App ruft
/// ihn beim Oeffnen und danach im Vordergrund alle `interval` Sekunden auf (`WeeklyAutoTicker`).
public enum WeeklyAutoTick {
    public static let interval: TimeInterval = 600

    public enum Outcome: Equatable, Sendable {
        case off, noAI, busy
        /// gelaufen: Meldung wie der Hintergrundauftrag, `changed` = etwas veroeffentlicht oder ein Nachtrag
        case ran(String, changed: Bool)
        /// am PC nur `print(f"Wochentest-Takt: {e}")`
        case failed(String)
    }

    public static func run(_ ctx: LocalContext) async -> Outcome {
        let on: Bool
        do { on = try await ctx.database.withConnection { c in try LocalSettings.read(c)["auto_tests"]?.bool ?? true } }
        catch { return .failed("\(error)") }
        guard on else { return .off }
        guard ctx.ai.provider != nil else { return .noAI }
        guard (await ctx.jobs.state["running"]?.bool) != true else { return .busy }
        do {
            let r = try await Weekly.tick(ctx)
            let changed = !(r["published"]?.array ?? []).isEmpty || !(r["nachtraege"]?.array ?? []).isEmpty
            return .ran(Weekly.summary(r) ?? "", changed: changed)
        } catch {
            return .failed("\(error)")
        }
    }
}
