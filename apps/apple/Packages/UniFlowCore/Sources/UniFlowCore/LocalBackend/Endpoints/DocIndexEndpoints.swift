import Foundation

/// Endpunkte des Dokument-Index ("Bibliothek") fuer die App (docs/DOKUMENT-INDEX-2026-11-04.md):
/// - GET  /api/index/file/{id}/page/{n}   Eintrag der Seite aus dem Zwischenspeicher (0 Anfragen), Querverweise, eigene Notizen;
///                                         mit ?lookup=1 fehlt er lokal: in der Bibliothek nachsehen (ohne KI)
/// - POST /api/index/file/{id}/page/{n}   {force, image, solutions}: diese Seite bauen (KI) - vorher "kenne ich schon?"
/// - POST /api/index/file/{id}/prewarm    alle Seiten (erst Bibliothek, dann KI mit sparsamem Modell, nur Text)
/// - GET  /api/index/shelf?module=        Regal: Hochschule > Studiengang > Semester > Modul > Woche > Art > Datei (nur eigene Dateien)
/// - GET  /api/index/status               Zahlen des Zwischenspeichers
/// Lesen geht ohne KI (jeder darf uebernehmen); bauen nur mit verbundener KI (`LocalContext.ai`).
enum DocIndexEndpoints: LocalEndpointModule {
    static let name = "Dokument-Index (Bibliothek)"

    static func register(on router: LocalRouter) {
        router.get("/api/index/file/{file_id}/page/{page}") { req, ctx in
            let fileID = req.param("file_id")
            guard let page = Int(req.param("page")), page >= 1 else { throw LocalHTTPError(status: 400, message: "page ungueltig") }
            let view = try await pageView(fileID: fileID, page: page, ctx: ctx, report: nil)
            // ?lookup=1 (KI-Hilfe oeffnet eine Seite): fehlt sie lokal, in der Bibliothek nachsehen - ohne KI, 0 Credits
            guard req.query("lookup") == "1", view["status"]?.string == "none", ctx.docIndex.cloud != nil else { return .json(view) }
            let report = try? await run(fileID: fileID, ctx: ctx, ai: nil, options: DocIndexBuildOptions(pages: [page]))
            return .json(try await pageView(fileID: fileID, page: page, ctx: ctx, report: report))
        }

        router.post("/api/index/file/{file_id}/page/{page}") { req, ctx in
            let fileID = req.param("file_id")
            guard let page = Int(req.param("page")), page >= 1 else { throw LocalHTTPError(status: 400, message: "page ungueltig") }
            let body = (try? req.jsonBody()) ?? .object([:])
            guard let ai = ctx.docIndex.ai(from: ctx.ai.provider) else { throw LocalHTTPError.notFound(DroppedEndpoints.noAI) }
            let options = DocIndexBuildOptions(force: body["force"]?.bool ?? false, withImage: body["image"]?.bool ?? true,
                                               fullImage: body["force"]?.bool ?? false, withSolutions: body["solutions"]?.bool ?? false,
                                               pages: [page])
            let report = try await run(fileID: fileID, ctx: ctx, ai: ai, options: options)
            return .json(try await pageView(fileID: fileID, page: page, ctx: ctx, report: report))
        }

        router.post("/api/index/file/{file_id}/prewarm") { req, ctx in
            let fileID = req.param("file_id")
            let ai = ctx.docIndex.ai(from: ctx.ai.provider)
            let report = try await run(fileID: fileID, ctx: ctx, ai: ai, options: DocIndexBuildOptions(withImage: false, small: true))
            return .json(reportJSON(report))
        }

        router.get("/api/index/shelf") { req, ctx in
            let module = req.query("module").flatMap { Int($0) }
            return .json(try await ctx.database.withConnection { try DocIndexStore.shelf($0, moduleID: module, clock: ctx.clock) })
        }

        router.get("/api/index/status") { _, ctx in
            let c = try await ctx.database.withConnection { try DocIndexStore.counts($0) }
            return .json(["files": .number(Double(c.files)), "pages": .number(Double(c.pages)), "failed": .number(Double(c.failed)),
                          "unshared": .number(Double(c.unshared)), "library": .bool(ctx.docIndex.cloud != nil),
                          "can_build": .bool(ctx.ai.provider != nil)])
        }
    }

    /// Aufbau mit den Anschluessen des Backends; KI-Fehler wie die anderen KI-Endpunkte (429 Kontingent, sonst 503)
    static func run(fileID: String, ctx: LocalContext, ai: DocIndexAI?, options: DocIndexBuildOptions) async throws -> DocIndexBuildReport {
        do {
            return try await DocIndexBuilder.build(fileID: fileID, ctx: ctx, cloud: ctx.docIndex.cloud, ai: ai, cipher: ctx.docIndex.cipher,
                                                   options: options)
        } catch let e as AIError {
            throw LocalHTTPError(status: e.code == "chatgpt_limit" ? 429 : 503, detail: ["detail": .string(e.message), "code": .string(e.code)])
        }
    }

    static func reportJSON(_ r: DocIndexBuildReport) -> JSONValue {
        ["file_id": .string(r.fileID), "pages_total": .number(Double(r.pageCount)), "known": .number(Double(r.known)),
         "adopted": .number(Double(r.adopted)), "built": .number(Double(r.built)), "failed": .number(Double(r.failed)),
         "skipped": .number(Double(r.skipped)), "ai_calls": .number(Double(r.aiCalls)), "needs_ai": .bool(r.needsAI),
         "complete": .bool(r.complete), "log": .array(r.log.map(JSONValue.string))]
    }

    /// Antwort fuer die KI-Hilfe: Eintrag der Seite (wenn bekannt), Querverweise im Modul, eigene Notizen derselben Datei,
    /// Katalog und Regalpfad, Stand der Datei. Nichts davon fragt die KI.
    static func pageView(fileID: String, page: Int, ctx: LocalContext, report: DocIndexBuildReport?) async throws -> JSONValue {
        let clock = ctx.clock
        return try await ctx.database.withConnection { c -> JSONValue in
            guard let meta = try DocIndexStore.fileMeta(c, fileID: fileID, clock: clock) else { throw LocalHTTPError.notFound("Datei nicht gefunden") }
            let sha = meta.sha ?? report?.fileSHA
            var o: [String: JSONValue] = ["file_id": .string(fileID), "page": .number(Double(page)), "status": "none", "known": false,
                                          "entry": .null, "cross_refs": [], "own_notes": [], "catalog": .null, "shelf_path": [],
                                          "can_build": .bool(ctx.ai.provider != nil), "library": .bool(ctx.docIndex.cloud != nil),
                                          "file_complete": false, "pages_total": .number(Double(meta.pageCount ?? report?.pageCount ?? 0)),
                                          "pages_known": 0, "title": .string(meta.displayTitle)]
            if let report { o["report"] = reportJSON(report) }
            let uni = try DocIndexStore.university(c)
            let catalog = try DocIndexStore.catalog(c, meta: meta)
            let dates = try LocalModules.Dates(c, clock: clock)
            o["catalog"] = catalog.json
            o["shelf_path"] = .array(DocIndexStore.shelfPath(university: uni.name, catalog: catalog,
                                                              weekLabel: StudyWeeks.weekLabel(start: dates.start, week: meta.week)).map(JSONValue.string))
            // eigene Notizen derselben Datei (nur lokal): die aktuelle Seite zuerst, dann die naechsten
            let notes = try DocIndexStore.ownNotes(c, fileID: fileID).sorted { a, b in
                (a.page == page ? 0 : 1, abs(a.page - page), a.page) < (b.page == page ? 0 : 1, abs(b.page - page), b.page)
            }
            o["own_notes"] = .array(notes.prefix(4).map {
                ["page": .number(Double($0.page)), "date": .string($0.date), "label": .string($0.label), "current": .bool($0.page == page)]
            })
            guard let sha else { o["status"] = "no_file"; return .object(o) }
            let rows = try DocIndexStore.rows(c, fileSHA: sha)
            let known = rows.filter { $0.page > 0 && $0.isOK }.count
            o["pages_known"] = .number(Double(known))
            o["file_complete"] = .bool(rows.contains { $0.page == 0 && $0.isOK })
            if let summary = rows.first(where: { $0.page == 0 })?.content, let count = summary["pageCount"]?.int, count > 0 {
                o["pages_total"] = .number(Double(count))
            }
            guard let row = rows.first(where: { $0.page == page }) else { return .object(o) }
            if row.status == "failed" {
                o["status"] = "failed"
                o["attempts"] = .number(Double(row.attempts))
                return .object(o)
            }
            guard let rec = row.content.flatMap(DocIndexPageRecord.init(json:)) else { return .object(o) }
            o["status"] = "ready"
            o["known"] = true
            o["source"] = .string(row.source ?? "")
            o["entry"] = rec.entry.json
            o["with_image"] = .bool(rec.withImage)
            o["created_at"] = .string(rec.createdAt)
            o["model"] = rec.model.map(JSONValue.string) ?? .null
            o["cross_refs"] = .array(try DocIndexBuilder.crossRefs(c, fileID: fileID, fileSHA: sha, page: page, entry: rec.entry,
                                                                   moduleID: meta.moduleID, clock: clock).map(\.json))
            return .object(o)
        }
    }
}
