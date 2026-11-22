import Foundation

/// Erklaerungen von StudiNow zum Kaufen (Auftrag des Inhabers 22.11.2026): Zu einer Kursdatei (Vorlesung, Uebung,
/// Klausur …) gibt es beim Dienst ein fertiges PDF „Erklärung Seite für Seite“ bzw. „Lösung Schritt für Schritt“. Pro AI
/// kauft es einmal fuer 15 Credits, danach gehoert es dauerhaft zur Datei. Der Dienst (app/erklaerung_shop.py) kennt nur
/// die SHA-256 der Kursdatei (`files.content_sha256`, wie sie heruntergeladen wurde), nie Dateinamen.
///
/// Gekaufte PDFs legt das Geraet wie die Probeklausuren des Klausur-Generators als eigenes Dokument (Kurs `__user__`)
/// in den Ordner „StudiNow-Erklärungen“ des Moduls der Datei (Bibliothek), Name „<Datei ohne .pdf> – Erklärung
/// StudiNow.pdf“. Die Tabelle `erklaerung_saved` merkt je Pruefsumme die abgelegte Datei: nie zweimal laden.
///
/// - `POST /api/erklaerungen/offer` {file_ids} -> {enabled, price, items: [{file_id, sha256, title, kind, pages, owned,
///   price, stand, local_file_id?}]} nur fuer Dateien mit Angebot. Antworten des Dienstes je Pruefsumme 10 Minuten
///   gemerkt (`erklaerung_offer_cache`), auch „kein Angebot“: die Liste fragt nicht bei jedem Anzeigen.
/// - `POST /api/files/{file_id}/erklaerung/buy` -> kaufen (zweiter Kauf kostet beim Dienst nichts), PDF laden, ablegen;
///   {…, file_id, local_file_id, charged, module_id, folder}
/// - `POST /api/erklaerungen/collect` -> alles Gekaufte des Kontos (`/mine`), das noch nie auf diesem Geraet lag und
///   dessen Kursdatei es hier gibt, ablegen; {added: [{sha256, file_id, local_file_id, title, module_id, module}], unplaced}
///
/// Nur ueber die StudiNow-KI des Kontos; ohne sie 403 `erklaerung_needs_service`. Fehler des Dienstes (403
/// `plan_required`, 429 `credits_exhausted` mit `credits`, 404 `not_available`) gehen unveraendert durch.
enum ErklaerungShop {
    static let folderName = "StudiNow-Erklärungen"
    static let titleSuffix = " – Erklärung StudiNow"
    /// so lange gilt eine Antwort des Dienstes zu einer Pruefsumme
    static let cacheSeconds: Int64 = 600
    /// so viele Pruefsummen nimmt der Dienst auf einmal (`MAX_OFFER`)
    static let maxPerRequest = 2000
    static let needsService = "Die Erklärungen von StudiNow gibt es mit StudiNow Pro AI. Melde dich dafür mit deinem StudiNow-Konto an."
    /// Kauf und Abholen nie gleichzeitig (sonst laege dieselbe PDF doppelt im Ordner); eigene Sperre neben der des
    /// Klausur-Generators
    static let gate = ExamShopGate()

    static func relay(_ ctx: LocalContext) throws -> StudiNowAI {
        guard let r = ctx.ai.serviceProvider as? StudiNowAI else {
            throw LocalHTTPError(status: 403, detail: ["detail": .string(needsService), "code": "erklaerung_needs_service"])
        }
        return r
    }

    static func ensureTables(_ c: SQLiteConnection) throws {
        try c.execute("""
            CREATE TABLE IF NOT EXISTS erklaerung_saved (
                sha256 TEXT PRIMARY KEY, file_id TEXT NOT NULL, source_file_id TEXT, module_id INTEGER, stand TEXT, saved_at TEXT)
            """)
        try c.execute("""
            CREATE TABLE IF NOT EXISTS erklaerung_offer_cache (
                sha256 TEXT PRIMARY KEY, item TEXT, enabled INTEGER NOT NULL, price INTEGER NOT NULL, checked_at INTEGER NOT NULL)
            """)
    }

    // MARK: Dateien und Pruefsummen

    /// Kursdatei auf dem Geraet: Pruefsumme (nil = noch keine und nicht berechenbar), Name, Modul
    struct Source {
        var fileID: String
        var name: String
        var sha: String?
        var moduleID: Int64?
        var localPath: String?
    }

    static func isPDF(name: String, mime: String?) -> Bool {
        name.lowercased().hasSuffix(".pdf") || mime?.lowercased() == "application/pdf"
    }

    /// Dateien zu `ids` (nur PDFs, nicht geloescht, keine abgelegten Erklaerungen); Modul ueber den Kurs, sonst den Ordner
    static func sources(_ ids: [String], _ c: SQLiteConnection) throws -> [Source] {
        try ensureTables(c)
        var out: [Source] = []
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for r in try c.query("""
                SELECT f.id, f.name, f.mime, f.local_path, f.content_sha256, COALESCE(c.module_id, d.module_id) AS module_id
                FROM files f LEFT JOIN courses c ON c.id=f.course_id LEFT JOIN folders d ON d.id=f.folder_id
                WHERE f.deleted_at IS NULL AND f.id IN (\(marks)) AND f.id NOT IN (SELECT file_id FROM erklaerung_saved)
                """, chunk.map { .text($0) }) {
                guard let id = r["id"]?.string, let name = r["name"]?.string, isPDF(name: name, mime: r["mime"]?.string) else { continue }
                let sha = r["content_sha256"]?.string.flatMap { $0.count == 64 ? $0.lowercased() : nil }
                out.append(Source(fileID: id, name: name, sha: sha, moduleID: r["module_id"]?.int64, localPath: r["local_path"]?.string))
            }
        }
        return out
    }

    /// Fehlende Pruefsummen einmal aus der Datei berechnen und in `files.content_sha256` merken (wie der Datei-Eingang:
    /// nur, wo noch keine steht). Ausserhalb jeder Transaktion, die Dateien koennen gross sein.
    static func withChecksums(_ list: [Source], _ ctx: LocalContext) async -> [Source] {
        var out = list
        guard let files = ctx.files else { return out }
        for i in out.indices where out[i].sha == nil {
            guard let p = out[i].localPath, files.exists(stored: p), let url = files.url(stored: p), let h = ContentHash.file(url) else { continue }
            out[i].sha = h.lowercased()
            _ = try? await ctx.database.execute("UPDATE files SET content_sha256=? WHERE id=? AND (content_sha256 IS NULL OR content_sha256='')",
                                                [.text(h.lowercased()), .text(out[i].fileID)])
        }
        return out
    }

    // MARK: Angebot (mit Merker)

    struct Offer {
        var enabled = false
        var price = 15
        /// sha256 -> Eintrag des Dienstes; fehlt = kein Angebot
        var items: [String: JSONValue] = [:]
    }

    /// Angebot zu den Pruefsummen: frisch Gemerktes aus `erklaerung_offer_cache`, den Rest beim Dienst
    static func offer(_ shas: [String], _ ctx: LocalContext) async throws -> Offer {
        let all = Array(Set(shas)).sorted()
        let now = LibraryEndpoints.unixNow(ctx)
        var out = Offer()
        var newest: Int64 = -1
        let cached = try await ctx.database.transaction { c -> [String: (item: JSONValue?, enabled: Bool, price: Int, at: Int64)] in
            try ensureTables(c)
            var m: [String: (JSONValue?, Bool, Int, Int64)] = [:]
            for chunk in stride(from: 0, to: all.count, by: 500).map({ Array(all[$0..<min($0 + 500, all.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                for r in try c.query("SELECT sha256, item, enabled, price, checked_at FROM erklaerung_offer_cache WHERE sha256 IN (\(marks)) AND checked_at>?",
                                     chunk.map { .text($0) } + [.integer(now - cacheSeconds)]) {
                    guard let s = r["sha256"]?.string else { continue }
                    m[s] = (r["item"]?.string.flatMap { try? JSONValue.parse($0) }, r["enabled"]?.int == 1, r["price"]?.int ?? 15,
                            r["checked_at"]?.int64 ?? 0)
                }
            }
            return m
        }
        for (s, e) in cached {
            if let item = e.item { out.items[s] = item }
            if e.at > newest { newest = e.at; out.enabled = e.enabled; out.price = e.price }
        }
        let missing = all.filter { cached[$0] == nil }
        guard !missing.isEmpty else { return out }
        let relay = try relay(ctx)
        for start in stride(from: 0, to: missing.count, by: maxPerRequest) {
            let chunk = Array(missing[start..<min(start + maxPerRequest, missing.count)])
            let v = try await relay.json("POST", "/api/erklaerungen/offer", body: ["sha256": .array(chunk.map(JSONValue.string))])
            out.enabled = v["enabled"]?.bool ?? false
            out.price = v["price"]?.int ?? out.price
            var got: [String: JSONValue] = [:]
            for item in v["items"]?.array ?? [] {
                if let s = item["sha256"]?.string?.lowercased() { got[s] = item }
            }
            let enabled = out.enabled, price = out.price, answers = got
            try await ctx.database.transaction { c in
                try ensureTables(c)
                for s in chunk {
                    try c.execute("INSERT OR REPLACE INTO erklaerung_offer_cache(sha256, item, enabled, price, checked_at) VALUES (?,?,?,?,?)",
                                  [.text(s), answers[s].map { .text($0.jsonString(sortedKeys: true)) } ?? .null, .integer(enabled ? 1 : 0),
                                   .integer(Int64(price)), .integer(now)])
                }
            }
            for (s, item) in got { out.items[s] = item }
        }
        return out
    }

    /// Nach Kauf oder Abholen: im Merker als gekauft eintragen (sonst zeigte die Liste bis zu 10 Minuten „kaufen“)
    static func rememberOwned(_ item: JSONValue, sha: String, _ c: SQLiteConnection, now: Int64) throws {
        try ensureTables(c)
        guard var o = item.object else { return }
        o["owned"] = true
        o.removeValue(forKey: "charged")
        let old = try c.queryOne("SELECT enabled, price FROM erklaerung_offer_cache WHERE sha256=?", [.text(sha)])
        try c.execute("INSERT OR REPLACE INTO erklaerung_offer_cache(sha256, item, enabled, price, checked_at) VALUES (?,?,?,?,?)",
                      [.text(sha), .text(JSONValue.object(o).jsonString(sortedKeys: true)), .integer(Int64(old?["enabled"]?.int ?? 1)),
                       .integer(Int64(old?["price"]?.int ?? 15)), .integer(now)])
    }

    // MARK: Ablage

    /// Abgelegte, nicht geloeschte Erklaerung je Pruefsumme
    static func saved(_ c: SQLiteConnection) throws -> [String: String] {
        try ensureTables(c)
        var out: [String: String] = [:]
        for r in try c.query("SELECT s.sha256, s.file_id FROM erklaerung_saved s JOIN files f ON f.id=s.file_id WHERE f.deleted_at IS NULL") {
            if let s = r["sha256"]?.string, let f = r["file_id"]?.string { out[s] = f }
        }
        return out
    }

    /// „VL03 Folgen.pdf“ -> „VL03 Folgen – Erklärung StudiNow“
    static func title(forFile name: String) -> String {
        var base = name.trimmingCharacters(in: .whitespaces)
        if base.lowercased().hasSuffix(".pdf") { base = String(base.dropLast(4)) }
        if base.isEmpty { base = "Datei" }
        return base + titleSuffix
    }

    /// PDF als eigenes Dokument in den Ordner „StudiNow-Erklärungen“ des Moduls (ohne Modul: Ordner oben in der
    /// Bibliothek) legen und merken
    static func store(_ data: Data, title: String, moduleID: Int64?, sha: String, sourceFileID: String?, stand: String?,
                      ctx: LocalContext) async throws -> String {
        let files = try ctx.requireFiles()
        guard data.starts(with: Array("%PDF".utf8)) else { throw LocalHTTPError(status: 502, message: "Der Dienst lieferte keine PDF") }
        let fid = LibraryEndpoints.newDocumentID(ctx)
        let local = files.ownDocumentsDirectory + "/" + fid + ".pdf"
        _ = try files.write(data, to: local)
        let pages = files.tools.pdfPageCount(data)
        let now = ctx.clock.nowISO, unix = LibraryEndpoints.unixNow(ctx)
        let module: SQLiteValue = moduleID.map { .integer($0) } ?? .null
        do {
            try await ctx.database.transaction { c in
                try ensureTables(c)
                var folder = try c.scalar("SELECT id FROM folders WHERE module_id IS ? AND parent_id IS NULL AND name=?", [module, .text(folderName)])
                if folder == nil {
                    try c.execute("INSERT INTO folders(name, parent_id, module_id, created_at) VALUES (?, NULL, ?, ?)", [.text(folderName), module, .text(now)])
                    folder = .integer(c.lastInsertRowID)
                }
                try c.execute("""
                    INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, local_path, downloaded_at, first_seen, status,
                                      seen_by_user, folder_id, kind, title, page_count)
                    VALUES (?,'__user__',?,?,'application/pdf','StudiNow',?,'',?,?,?,'neu',0,?,'pdf',?,?)
                    """, [.text(fid), .text(title + ".pdf"), .integer(Int64(data.count)), .integer(unix), .text(local), .text(now), .text(now),
                          folder ?? .null, .text(title), pages.map { .integer(Int64($0)) } ?? .null])
                try c.execute("INSERT OR REPLACE INTO erklaerung_saved(sha256, file_id, source_file_id, module_id, stand, saved_at) VALUES (?,?,?,?,?,?)",
                              [.text(sha), .text(fid), sourceFileID.map { .text($0) } ?? .null, module, stand.map { .text($0) } ?? .null, .text(now)])
            }
        } catch {
            files.remove(stored: local)
            throw error
        }
        return fid
    }

    // MARK: Ablaeufe

    /// Kaufen und ablegen; liegt die Erklaerung schon auf dem Geraet, wird nichts geladen
    static func buy(fileID: String, _ ctx: LocalContext) async throws -> JSONValue {
        let relay = try relay(ctx)
        let found = try await ctx.database.withConnection { try sources([fileID], $0) }
        guard let src = await withChecksums(found, ctx).first, let sha = src.sha else {
            throw LocalHTTPError(status: 404, detail: ["detail": "Zu dieser Datei gibt es keine Erklärung von StudiNow.", "code": "not_available"])
        }
        let item = try await relay.json("POST", "/api/erklaerungen/buy", body: ["sha256": .string(sha)])
        let now = LibraryEndpoints.unixNow(ctx)
        return try await gate.run { () async throws -> JSONValue in
            var local = try await ctx.database.transaction { c -> String? in
                try rememberOwned(item, sha: sha, c, now: now)
                return try saved(c)[sha]
            }
            if local == nil {
                let data = try await relay.download("/api/erklaerungen/\(sha)/pdf")
                local = try await store(data, title: title(forFile: src.name), moduleID: src.moduleID, sha: sha, sourceFileID: src.fileID,
                                        stand: item["stand"]?.string, ctx: ctx)
            }
            var o = item.object ?? [:]
            o["owned"] = true
            o["file_id"] = .string(src.fileID)
            o["local_file_id"] = local.map(JSONValue.string) ?? .null
            o["module_id"] = src.moduleID.map { .number(Double($0)) } ?? .null
            o["folder"] = .string(folderName)
            return .object(o)
        }
    }

    /// Alles Gekaufte des Kontos ablegen, das noch nie hier lag und dessen Kursdatei es auf dem Geraet gibt. Was schon
    /// einmal abgelegt war, bleibt in Ruhe, auch wenn es inzwischen geloescht ist (wie beim Klausur-Generator); wieder
    /// holen geht ueber das Abzeichen an der Datei.
    static func collect(_ ctx: LocalContext) async throws -> JSONValue {
        let relay = try relay(ctx)
        let items = try await relay.json("GET", "/api/erklaerungen/mine")["items"]?.array ?? []
        let now = LibraryEndpoints.unixNow(ctx)
        return try await gate.run { () async throws -> JSONValue in
            let had = try await ctx.database.transaction { c -> Set<String> in
                try ensureTables(c)
                return Set(try c.query("SELECT sha256 FROM erklaerung_saved").compactMap { $0["sha256"]?.string })
            }
            var added: [JSONValue] = []
            var unplaced = 0
            for item in items {
                guard let sha = item["sha256"]?.string?.lowercased(), sha.count == 64, !had.contains(sha) else { continue }
                let place = try await ctx.database.withConnection { c -> (Source, String)? in
                    try ensureTables(c)
                    guard let r = try c.queryOne("""
                        SELECT f.id, f.name, COALESCE(c.module_id, d.module_id) AS module_id, m.name AS module
                        FROM files f LEFT JOIN courses c ON c.id=f.course_id LEFT JOIN folders d ON d.id=f.folder_id
                        LEFT JOIN modules m ON m.id=COALESCE(c.module_id, d.module_id)
                        WHERE f.deleted_at IS NULL AND lower(f.content_sha256)=? AND f.id NOT IN (SELECT file_id FROM erklaerung_saved)
                        ORDER BY (c.module_id IS NULL), f.chdate DESC, f.id LIMIT 1
                        """, [.text(sha)]), let id = r["id"]?.string else { return nil }
                    return (Source(fileID: id, name: r["name"]?.string ?? "", sha: sha, moduleID: r["module_id"]?.int64), r["module"]?.string ?? "")
                }
                guard let place else { unplaced += 1; continue }
                let (src, module) = place
                let data = try await relay.download("/api/erklaerungen/\(sha)/pdf")
                let title = title(forFile: src.name)
                let fid = try await store(data, title: title, moduleID: src.moduleID, sha: sha, sourceFileID: src.fileID,
                                          stand: item["stand"]?.string, ctx: ctx)
                try await ctx.database.transaction { try rememberOwned(item, sha: sha, $0, now: now) }
                added.append(["sha256": .string(sha), "file_id": .string(src.fileID), "local_file_id": .string(fid), "title": .string(title),
                              "module_id": src.moduleID.map { .number(Double($0)) } ?? .null, "module": .string(module)])
            }
            return ["added": .array(added), "unplaced": .number(Double(unplaced))]
        }
    }
}

public enum ErklaerungEndpoints: LocalEndpointModule {
    public static let name = "Erklärungen von StudiNow"

    public static func register(on router: LocalRouter) {
        router.post("/api/erklaerungen/offer") { req, ctx in
            _ = try ErklaerungShop.relay(ctx)
            let ids = Array(Set((try req.objectBody()["file_ids"]?.array ?? []).compactMap(\.string))).sorted()
            guard ids.count <= 5000 else { throw LocalHTTPError(status: 422, detail: ["detail": "Zu viele Dateien auf einmal.", "code": "bad_request"]) }
            let found = try await ctx.database.withConnection { try ErklaerungShop.sources(ids, $0) }
            let list = await ErklaerungShop.withChecksums(found, ctx).filter { $0.sha != nil }
            let offer = try await ErklaerungShop.offer(list.compactMap(\.sha), ctx)
            let saved = try await ctx.database.withConnection { try ErklaerungShop.saved($0) }
            var items: [JSONValue] = []
            if offer.enabled {
                for src in list {
                    guard let sha = src.sha, let item = offer.items[sha] else { continue }
                    let local = saved[sha]
                    var o: [String: JSONValue] = ["file_id": .string(src.fileID), "sha256": .string(sha), "price": .number(Double(offer.price)),
                                                  "title": item["title"] ?? "", "kind": item["kind"] ?? "", "pages": item["pages"] ?? 0,
                                                  "stand": item["stand"] ?? "", "owned": .bool(item["owned"]?.bool == true || local != nil)]
                    if let local { o["local_file_id"] = .string(local) }
                    items.append(.object(o))
                }
            }
            return .json(["enabled": .bool(offer.enabled), "price": .number(Double(offer.price)), "items": .array(items)])
        }

        router.post("/api/files/{file_id}/erklaerung/buy") { req, ctx in
            .json(try await ErklaerungShop.buy(fileID: req.param("file_id"), ctx))
        }

        router.post("/api/erklaerungen/collect") { _, ctx in
            .json(try await ErklaerungShop.collect(ctx))
        }
    }
}
