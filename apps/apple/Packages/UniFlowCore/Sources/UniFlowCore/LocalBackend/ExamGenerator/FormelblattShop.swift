import Foundation

/// Formelblaetter (Auftrag des Inhabers 22.11.2026): fertige PDFs zu einem Modul, mit Pro AI einmal fuer feste Credits
/// kaufen (Dienst: app/formelblatt.py). Das Geraet nennt dem Dienst nur den Namen des offenen Moduls; gekaufte Blaetter
/// legt es als eigenes Dokument (Kurs `__user__`) in den Ordner „Formelblätter“ des Moduls, wie die Probeklausuren.
///
/// - `GET /api/modules/{id}/formelblatt` -> {items: [{id, title, credits, pages, version, description, owned, file_id?, current}]}
///   ohne StudiNow-KI oder ohne Pro AI still `{items: []}` (die Karte bleibt dann weg)
/// - `POST /api/modules/{id}/formelblatt/{sheet}/get` -> kaufen (schon gekauft: 0 Credits) und PDF ins Modul legen;
///   {item, file_id, credits_charged}
enum FormelblattShop {
    static let folderName = "Formelblätter"

    static func ensureTable(_ c: SQLiteConnection) throws {
        try c.execute("""
            CREATE TABLE IF NOT EXISTS formelblatt_saved (
                sheet_id TEXT PRIMARY KEY, file_id TEXT NOT NULL, module_id INTEGER, version TEXT, saved_at TEXT)
            """)
    }

    static func moduleName(_ id: Int64, _ ctx: LocalContext) async throws -> String {
        try await ctx.database.withConnection { c in
            guard let n = try c.scalar("SELECT name FROM modules WHERE id=?", [.integer(id)])?.string else {
                throw LocalHTTPError.notFound("Modul nicht gefunden")
            }
            return n
        }
    }

    /// Was davon schon auf dem Geraet liegt: sheet_id -> (file_id, version); geloeschte Dokumente zaehlen nicht
    static func saved(_ ctx: LocalContext) async throws -> [String: (String, String)] {
        try await ctx.database.transaction { c in
            try ensureTable(c)
            var out: [String: (String, String)] = [:]
            for r in try c.query("SELECT s.sheet_id, s.file_id, s.version FROM formelblatt_saved s JOIN files f ON f.id=s.file_id WHERE f.deleted_at IS NULL") {
                if let id = r["sheet_id"]?.string, let fid = r["file_id"]?.string { out[id] = (fid, r["version"]?.string ?? "") }
            }
            return out
        }
    }

    static func decorate(_ item: JSONValue, _ have: [String: (String, String)]) -> JSONValue {
        guard var o = item.object else { return item }
        if let id = o["id"]?.string, let s = have[id] {
            o["file_id"] = .string(s.0)
            o["current"] = .bool(s.1 == (o["version"]?.string ?? ""))
        }
        return .object(o)
    }

    /// PDF als eigenes Dokument im Ordner „Formelblätter“ des Moduls; eine neue Fassung ersetzt den Eintrag (das alte
    /// Dokument bleibt, mit Notizen, in der Bibliothek)
    static func store(_ data: Data, title: String, moduleID: Int64, sheetID: String, version: String, ctx: LocalContext) async throws -> String {
        let files = try ctx.requireFiles()
        guard data.starts(with: Array("%PDF".utf8)) else { throw LocalHTTPError(status: 502, message: "Der Dienst lieferte keine PDF") }
        let fid = LibraryEndpoints.newDocumentID(ctx)
        let local = files.ownDocumentsDirectory + "/" + fid + ".pdf"
        _ = try files.write(data, to: local)
        let pages = files.tools.pdfPageCount(data)
        let now = ctx.clock.nowISO, unix = LibraryEndpoints.unixNow(ctx)
        do {
            try await ctx.database.transaction { c in
                try ensureTable(c)
                var folder = try c.scalar("SELECT id FROM folders WHERE module_id=? AND parent_id IS NULL AND name=?", [.integer(moduleID), .text(folderName)])
                if folder == nil {
                    try c.execute("INSERT INTO folders(name, parent_id, module_id, created_at) VALUES (?, NULL, ?, ?)", [.text(folderName), .integer(moduleID), .text(now)])
                    folder = .integer(c.lastInsertRowID)
                }
                try c.execute("""
                    INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, local_path, downloaded_at, first_seen, status,
                                      seen_by_user, folder_id, kind, title, page_count)
                    VALUES (?,'__user__',?,?,'application/pdf','StudiNow',?,'',?,?,?,'neu',0,?,'pdf',?,?)
                    """, [.text(fid), .text(title + ".pdf"), .integer(Int64(data.count)), .integer(unix), .text(local), .text(now), .text(now),
                          folder ?? .null, .text(title), pages.map { .integer(Int64($0)) } ?? .null])
                try c.execute("INSERT OR REPLACE INTO formelblatt_saved(sheet_id, file_id, module_id, version, saved_at) VALUES (?,?,?,?,?)",
                              [.text(sheetID), .text(fid), .integer(moduleID), .text(version), .text(now)])
            }
        } catch {
            files.remove(stored: local)
            throw error
        }
        return fid
    }
}

/// Adressen der Formelblaetter auf dem Geraet
public enum FormelblattEndpoints: LocalEndpointModule {
    public static let name = "Formelblätter"

    public static func register(on router: LocalRouter) {
        router.get("/api/modules/{module_id:int}/formelblatt") { req, ctx in
            let m = Int64(req.intParam("module_id"))
            let name = try await FormelblattShop.moduleName(m, ctx)
            guard let relay = ctx.ai.serviceProvider as? StudiNowAI else { return .json(["items": .array([])]) }
            let v: JSONValue
            do {
                v = try await relay.json("POST", "/api/formelblatt/offer", body: ["modules": .array([.string(name)])])
            } catch let e as LocalHTTPError where [401, 403, 404].contains(e.status) {
                return .json(["items": .array([])])          // ohne Pro AI, ohne Konto oder alter Dienst: keine Karte
            }
            let have = try await FormelblattShop.saved(ctx)
            return .json(["items": .array((v["items"]?.array ?? []).map { FormelblattShop.decorate($0, have) })])
        }

        router.post("/api/modules/{module_id:int}/formelblatt/{sheet_id}/get") { req, ctx in
            let m = Int64(req.intParam("module_id"))
            let sheet = req.param("sheet_id")
            guard sheet.range(of: "^[a-z0-9][a-z0-9-]{2,63}$", options: .regularExpression) != nil else { throw LocalHTTPError.notFound("Nicht gefunden") }
            _ = try await FormelblattShop.moduleName(m, ctx)
            guard let relay = ctx.ai.serviceProvider as? StudiNowAI else {
                throw LocalHTTPError(status: 403, detail: ["detail": .string(ExamGeneratorShop.needsService), "code": "formelblatt_needs_service"])
            }
            let bought = try await relay.json("POST", "/api/formelblatt/\(sheet)/buy")
            let item = bought["item"] ?? .null
            let data = try await relay.download("/api/formelblatt/\(sheet)/pdf")
            let title = item["title"]?.string ?? "Formelblatt"
            let fid = try await FormelblattShop.store(data, title: title, moduleID: m, sheetID: sheet,
                                                      version: item["version"]?.string ?? "", ctx: ctx)
            return .json(["item": FormelblattShop.decorate(item, [sheet: (fid, item["version"]?.string ?? "")]),
                          "file_id": .string(fid), "credits_charged": bought["credits_charged"] ?? .number(0)])
        }
    }
}
