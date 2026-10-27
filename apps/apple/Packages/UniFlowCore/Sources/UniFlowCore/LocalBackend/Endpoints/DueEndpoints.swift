import Foundation

/// Abgaben, Tests und Pruefungstermine (nur auf dem Geraet; `DueDetection`, `DueStore`):
/// - `GET /api/due[?module_id=&hidden=1]`: kommende Termine "Abgaben & Prüfungen" (erkannte, Learnweb-Fristen,
///   Klausurtermine der Module) mit `days_left`/`in_days`, `hidden` = Zahl der ausgeblendeten erkannten. Rechnet vorher
///   neu, wenn noch nie oder heute noch nicht gerechnet wurde (`refreshed`: dabei kam etwas dazu oder fiel weg).
/// - `POST /api/due/refresh`: alles neu erkennen (die App nach jedem Abgleich); `{hits, changed}`
/// - `POST /api/due/backfill?limit=20`: Seitentexte fehlender PDFs lesen (vor S7 geladen, nie geoeffnet; PDFKit) und
///   gleich pruefen; `{read, remaining}`. Die App ruft es nach einem Abgleich, bis nichts mehr fehlt.
/// - `PATCH /api/due/{id}`: `{"hidden": true}` ("stimmt nicht"), `{"hidden": false}`, `{"confirmed": true}`,
///   `{"time": "14:00"}` bzw. `{"time": null}` (eigene Uhrzeit weg); 404 fuer unbekannte und nicht erkannte Termine.
/// Kalender und Uebersicht zeigen die erkannten in `deadlines` bzw. `upcoming` (Holidays.calendarExtras,
/// StudyCalendar.upcomingDeadlines). Am PC gibt es diese Pfade nicht.
public enum DueEndpoints: LocalEndpointModule {
    public static let name = "Abgaben und Prüfungen"

    private static let timeRE = HText.regex(#"^([01]\d|2[0-3]):[0-5]\d$"#)

    public static func register(on router: LocalRouter) {
        router.get("/api/due") { req, ctx in
            var module: Int?
            if let raw = req.query("module_id"), !raw.isEmpty {
                guard let v = Int(raw) else {
                    throw LocalHTTPError.validation(type: "int_parsing", loc: ["query", "module_id"],
                                                    msg: "Input should be a valid integer, unable to parse string as an integer", input: .string(raw))
                }
                module = v
            }
            let hidden = try req.boolQuery("hidden") ?? false
            let clock = ctx.clock, moduleID = module
            let v = try await ctx.database.transaction { try DueStore.list($0, clock: clock, moduleID: moduleID, includeHidden: hidden) }
            return .json(.object(v))
        }

        router.post("/api/due/refresh") { _, ctx in
            let clock = ctx.clock
            let r = try await ctx.database.transaction { try DueStore.refreshAll($0, clock: clock) }
            return .json(["hits": .number(Double(r.hits)), "changed": .bool(r.changed)])
        }

        router.post("/api/due/backfill") { req, ctx in
            let limit = min(max(Int(req.query("limit") ?? "") ?? 20, 1), 100)
            guard let files = ctx.files else { return .json(["read": 0, "remaining": 0]) }
            let ids = try await ctx.database.transaction { c -> [String] in
                try DueStore.ensureTables(c)
                return try DueStore.backfillCandidates(c, limit: limit)
            }
            var read = 0
            for id in ids {
                try Task.checkCancellation()
                // liest mit PDFKit, speichert und prueft die Seiten (`DueStore.refreshFile`)
                let pages = (try? await ScriptSearch.pageTexts(fileID: id, database: ctx.database, files: files, clock: ctx.clock)) ?? []
                if pages.isEmpty {
                    try await ctx.database.transaction { try DueStore.markUnreadable($0, fileID: id) }
                } else {
                    read += 1
                }
            }
            let remaining = try await ctx.database.withConnection { try DueStore.backfillCandidates($0, limit: 10_000).count }
            return .json(["read": .number(Double(read)), "remaining": .number(Double(remaining))])
        }

        router.patch("/api/due/{id}") { req, ctx in
            let body = try req.objectBody()
            func flag(_ k: String) throws -> Bool? {
                guard let v = body[k], !v.isNull else { return nil }
                guard let b = v.bool else { throw LocalHTTPError(status: 422, message: "\(k): true oder false erwartet") }
                return b
            }
            let hidden = try flag("hidden"), confirmed = try flag("confirmed")
            var time: String??
            if let v = body["time"] {
                if v.isNull {
                    time = .some(nil)
                } else if let s = v.string, DueDetection.has(timeRE, s) {
                    time = .some(s)
                } else {
                    throw LocalHTTPError(status: 422, message: "time: Uhrzeit als HH:MM erwartet")
                }
            }
            let id = req.param("id"), clock = ctx.clock, newTime = time
            let r = try await ctx.database.transaction {
                try DueStore.update($0, id: id, hidden: hidden, confirmed: confirmed, time: newTime, clock: clock)
            }
            guard let r else { throw LocalHTTPError.notFound("Termin nicht gefunden") }
            return .json(.object(r))
        }
    }
}
