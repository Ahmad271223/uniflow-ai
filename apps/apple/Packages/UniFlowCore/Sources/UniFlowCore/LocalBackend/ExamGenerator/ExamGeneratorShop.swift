import Foundation

/// Klausur-Generator, Kauf auf dem Geraet (Entscheidung des Inhabers 18.11.2026: „einmal erzeuge dann verkaufen“,
/// 15 Credits je Probeklausur). Der Dienst (app/exam_shop.py) erzeugt jede Probeklausur einmal und verkauft sie an alle
/// mit denselben Dateien; das Geraet nennt nur Fingerabdruck, Art und Seitenzahl seiner Dateien. Die Seitentexte gehen
/// nur mit, wenn der Dienst eine Probeklausur neu erzeugen muss (`needs_texts`). Fertige PDFs legt das Geraet in den
/// Ordner „Probeklausuren“ des Moduls (Bibliothek), als eigenes Dokument (Kurs `__user__`): sie zaehlen nie als
/// Altklausur des Moduls und landen nie in einer Auswahl.
///
/// - `POST /api/modules/{id}/exam-generator/offer` {file_ids} -> Stand beim Dienst (Preis, je Probeklausur fertig/gekauft)
/// - `POST /api/modules/{id}/exam-generator/buy` {file_ids, count} -> gekauft; schickt die Seitentexte nur bei Bedarf
/// - `POST /api/modules/{id}/exam-generator/collect` {file_ids} -> fertige, gekaufte PDFs ins Modul legen
/// - `GET /api/modules/{id}/exam-generator/saved` -> Probeklausuren, die auf dem Geraet im Modul liegen (fuer die Karte
///   auf der Modulseite, 22.11.2026: der Inhaber fand sie in der Bibliothek nicht); nur lokal, ohne Dienst
/// - `POST /api/exam-generator/collect` -> alles Gekaufte des Kontos abholen, ohne Auswahl (22.11.2026): eine
///   Probeklausur war fertig und bezahlt, kam aber nie aufs iPad, weil nur das offene Kauf-Blatt abholte. Das Modul
///   ergibt sich aus den Fingerabdruecken der Unterlagen (`moduleID(forFiles:)`).
///
/// Nur ueber die StudiNow-KI des Kontos (auch wenn daneben ein eigenes ChatGPT verbunden ist); ohne sie 403
/// `exam_generator_needs_service`.
/// Nie zwei Abhol-Laeufe zugleich (Kauf-Blatt und Abholen von selbst): sonst laege dieselbe PDF doppelt im Ordner
actor ExamShopGate {
    static let shared = ExamShopGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        return try await body()
    }
}

enum ExamGeneratorShop {
    static let folderName = "Probeklausuren"
    /// die zwei PDFs je Probeklausur: Kennung beim Dienst und Zusatz im Titel
    static let parts = [("aufgaben", "Aufgaben"), ("loesungen", "Lösungen")]
    static let needsService = "Der Klausur-Generator läuft über die StudiNow-KI. Melde dich dafür mit deinem StudiNow-Konto an (StudiNow Plus oder Pro AI, mit Credits)."

    static func relay(_ ctx: LocalContext) throws -> StudiNowAI {
        guard let r = ctx.ai.serviceProvider as? StudiNowAI else {
            throw LocalHTTPError(status: 403, detail: ["detail": .string(needsService), "code": "exam_generator_needs_service"])
        }
        return r
    }

    /// Gewaehlte Datei mit Fingerabdruck (fuer den Dienst) und Ort (fuer die Seitentexte)
    struct Picked {
        var fileID: String
        var title: String
        var sha: String
        var docType: String
        var pages: Int
    }

    /// Auswahl aus `file_ids`: nur PDFs des Moduls, die auf dem Geraet liegen; Fingerabdruck wird nachgeholt
    static func picked(_ req: LocalRequest, _ ctx: LocalContext) async throws -> [Picked] {
        let o = try req.objectBody()
        let ids = Set((o["file_ids"]?.array ?? []).compactMap(\.string))
        guard !ids.isEmpty else { throw LocalHTTPError(status: 422, detail: ["detail": "Bitte Unterlagen auswählen.", "code": "no_files"]) }
        let m = Int64(req.intParam("module_id"))
        guard let files = ctx.files else { throw LocalHTTPError(status: 503, message: "Keine Dateien auf diesem Gerät") }
        let rows = try await ctx.database.withConnection { c -> [ExamGeneratorSelection.Row] in
            guard try c.queryOne("SELECT 1 FROM modules WHERE id=?", [.integer(m)]) != nil else { throw LocalHTTPError.notFound("Modul nicht gefunden") }
            return try ExamGeneratorSelection.rows(c, moduleID: m)
        }
        let items = ExamGeneratorSelection.withPages(rows, files: files)
        var out: [Picked] = []
        for (row, item) in zip(rows, items) where ids.contains(item.id) && item.isAvailable {
            var sha = try await ctx.database.withConnection {
                try $0.queryOne("SELECT content_sha256 FROM files WHERE id=?", [.text(item.id)])?["content_sha256"]?.string
            }
            if sha?.count != 64, let path = row.localPath, let url = files.url(stored: path), let h = ContentHash.file(url) {
                sha = h
                _ = try? await ctx.database.execute("UPDATE files SET content_sha256=? WHERE id=?", [.text(h), .text(item.id)])
            }
            guard let sha, sha.count == 64 else { continue }
            let type = item.isSolution ? "loesung" : (item.group == .exams ? "klausur" : item.group == .exercises ? "uebung"
                                                      : (item.label == "Skript" || item.label == "Mitschrift") ? "skript" : "vorlesung")
            out.append(Picked(fileID: item.id, title: item.title, sha: sha.lowercased(), docType: type, pages: item.pages ?? 0))
        }
        guard !out.isEmpty else { throw LocalHTTPError(status: 422, detail: ["detail": "Keine der Dateien liegt auf diesem Gerät.", "code": "no_files"]) }
        return out
    }

    static func filesJSON(_ p: [Picked]) -> JSONValue {
        .array(p.map { ["sha256": .string($0.sha), "doc_type": .string($0.docType), "pages": .number(Double($0.pages))] })
    }

    /// Seitentexte fuer den Dienst (nur wenn er neu erzeugen muss); Seiten ohne Text liest die Texterkennung
    static func texts(_ p: [Picked], _ ctx: LocalContext) async throws -> JSONValue {
        var out: [JSONValue] = []
        for f in p {
            let pages = (try? await ScriptSearch.pageTexts(fileID: f.fileID, ctx: ctx, ocrScope: .all)) ?? []
            out.append(["sha256": .string(f.sha), "title": .string(f.title), "pages": .array(pages.map(JSONValue.string))])
        }
        return .array(out)
    }

    /// Wo jede gekaufte Probeklausur auf dem Geraet liegt (`exam_shop_saved`)
    static func ensureTable(_ c: SQLiteConnection) throws {
        try c.execute("""
            CREATE TABLE IF NOT EXISTS exam_shop_saved (
                key TEXT NOT NULL, which TEXT NOT NULL, file_id TEXT NOT NULL, module_id INTEGER, saved_at TEXT,
                PRIMARY KEY (key, which))
            """)
    }

    static func saved(_ ctx: LocalContext) async throws -> [String: [String: String]] {
        try await ctx.database.transaction { c in
            try ensureTable(c)
            var out: [String: [String: String]] = [:]
            for r in try c.query("SELECT s.key, s.which, s.file_id FROM exam_shop_saved s JOIN files f ON f.id=s.file_id WHERE f.deleted_at IS NULL") {
                out[r["key"]?.string ?? "", default: [:]][r["which"]?.string ?? ""] = r["file_id"]?.string
            }
            return out
        }
    }

    /// Modul einer Probeklausur aus den Fingerabdruecken ihrer Unterlagen: das Modul, in dem die meisten davon liegen
    /// (aktive Kurse, wie die Auswahl). nil = keine der Unterlagen ist auf diesem Geraet einem Modul zugeordnet.
    static func moduleID(forFiles shas: [String], _ c: SQLiteConnection) throws -> Int64? {
        let list = Array(Set(shas.map { $0.lowercased() }.filter { $0.count == 64 })).sorted().prefix(500)
        guard !list.isEmpty else { return nil }
        let marks = Array(repeating: "?", count: list.count).joined(separator: ",")
        return try c.queryOne("""
            SELECT c.module_id AS m, COUNT(DISTINCT lower(f.content_sha256)) AS n
            FROM files f JOIN courses c ON c.id=f.course_id JOIN modules mo ON mo.id=c.module_id
            WHERE c.active=1 AND f.deleted_at IS NULL AND lower(f.content_sha256) IN (\(marks))
            GROUP BY c.module_id ORDER BY n DESC, m LIMIT 1
            """, list.map { .text($0) })?["m"]?.int64
    }

    /// Alles Gekaufte des Kontos abholen, das noch nie auf diesem Geraet lag (`GET /api/exam-shop/mine`). Was schon
    /// einmal abgelegt war, bleibt in Ruhe, auch wenn es inzwischen geloescht ist: sonst kaeme eine bewusst geloeschte
    /// Probeklausur bei jedem Start wieder (wiederholen geht ueber das Kauf-Blatt, „Fertige abholen“).
    /// `added` nennt je Datei Modul und Titel, `pending` zaehlt, was der Dienst noch erstellt, `unplaced`, was zu
    /// keinem Modul dieses Geraets passt.
    static func collectAll(_ ctx: LocalContext) async throws -> JSONValue {
        let relay = try relay(ctx)
        return try await ExamShopGate.shared.run { () async throws -> JSONValue in
            let items = try await relay.json("GET", "/api/exam-shop/mine")["items"]?.array ?? []
            let had = try await ctx.database.transaction { c -> Set<String> in
                try ensureTable(c)
                return Set(try c.query("SELECT key, which FROM exam_shop_saved").map { "\($0["key"]?.string ?? "")|\($0["which"]?.string ?? "")" })
            }
            var added: [JSONValue] = []
            var unplaced = 0
            for item in items where item["paid"]?.bool == true && item["status"]?.string == "ready" {
                guard let key = item["key"]?.string else { continue }
                let missing = parts.filter { !had.contains("\(key)|\($0.0)") }
                guard !missing.isEmpty else { continue }
                let shas = (item["files"]?.array ?? []).compactMap(\.string)
                let place = try await ctx.database.withConnection { c -> (Int64, String)? in
                    guard let m = try moduleID(forFiles: shas, c) else { return nil }
                    return (m, try c.scalar("SELECT name FROM modules WHERE id=?", [.integer(m)])?.string ?? "")
                }
                guard let place else { unplaced += 1; continue }
                let n = item["variant"]?.int ?? 0
                for (which, label) in missing {
                    let data = try await relay.download("/api/exam-shop/item/\(key)/pdf/\(which)")
                    let title = "Probeklausur \(n) – \(label)"
                    let fid = try await store(data, title: title, moduleID: place.0, key: key, which: which, ctx: ctx)
                    added.append(["key": .string(key), "which": .string(which), "file_id": .string(fid), "variant": .number(Double(n)),
                                  "title": .string(title), "module_id": .number(Double(place.0)), "module": .string(place.1)])
                }
            }
            let pending = items.filter { ["pending", "running"].contains($0["status"]?.string ?? "") }.count
            return ["added": .array(added), "pending": .number(Double(pending)), "unplaced": .number(Double(unplaced))]
        }
    }

    /// Probeklausuren eines Moduls auf dem Geraet: je Probeklausur Nummer und die Dokumente (`aufgaben`, `loesungen`),
    /// geloeschte nicht. Nummer aus dem Schluessel (`pk-<set>-NN`); mehrere Unterlagen-Saetze mit derselben Nummer
    /// bleiben getrennt (nach Ablage geordnet).
    static func savedInModule(_ moduleID: Int64, _ c: SQLiteConnection) throws -> [JSONValue] {
        try ensureTable(c)
        var order: [String] = []
        var byKey: [String: [String: JSONValue]] = [:]
        for r in try c.query("""
            SELECT s.key, s.which, s.file_id, s.saved_at FROM exam_shop_saved s JOIN files f ON f.id=s.file_id
            WHERE s.module_id=? AND f.deleted_at IS NULL ORDER BY s.saved_at, s.key
            """, [.integer(moduleID)]) {
            guard let key = r["key"]?.string, let which = r["which"]?.string, let fid = r["file_id"]?.string else { continue }
            if byKey[key] == nil {
                order.append(key)
                let n = Int(key.split(separator: "-").last ?? "") ?? 0
                byKey[key] = ["key": .string(key), "variant": .number(Double(n)), "saved_at": r["saved_at"]?.string.map(JSONValue.string) ?? .null]
            }
            byKey[key]?[which] = .string(fid)
        }
        return order.compactMap { byKey[$0].map(JSONValue.object) }
    }

    /// Antwort des Dienstes plus, was davon schon auf dem Geraet liegt
    static func withSaved(_ v: JSONValue, _ ctx: LocalContext) async throws -> JSONValue {
        guard var o = v.object else { return v }
        let s = try await saved(ctx)
        o["variants"] = .array((v["variants"]?.array ?? []).map { item in
            guard var x = item.object else { return item }
            let files = s[x["key"]?.string ?? ""] ?? [:]
            x["files"] = .object(files.mapValues(JSONValue.string))
            return .object(x)
        })
        return .object(o)
    }

    /// PDF als eigenes Dokument im Ordner „Probeklausuren“ des Moduls ablegen
    static func store(_ data: Data, title: String, moduleID: Int64, key: String, which: String, ctx: LocalContext) async throws -> String {
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
                try c.execute("INSERT OR REPLACE INTO exam_shop_saved(key, which, file_id, module_id, saved_at) VALUES (?,?,?,?,?)",
                              [.text(key), .text(which), .text(fid), .integer(moduleID), .text(now)])
            }
        } catch {
            files.remove(stored: local)
            throw error
        }
        return fid
    }
}

extension ExamGeneratorEndpoints {
    static func registerShop(on router: LocalRouter) {
        router.post("/api/modules/{module_id:int}/exam-generator/offer") { req, ctx in
            let relay = try ExamGeneratorShop.relay(ctx)
            let p = try await ExamGeneratorShop.picked(req, ctx)
            let v = try await relay.json("POST", "/api/exam-shop/offer", body: ["files": ExamGeneratorShop.filesJSON(p)])
            return .json(try await ExamGeneratorShop.withSaved(v, ctx))
        }

        router.post("/api/modules/{module_id:int}/exam-generator/buy") { req, ctx in
            let relay = try ExamGeneratorShop.relay(ctx)
            let p = try await ExamGeneratorShop.picked(req, ctx)
            let count = try req.objectBody()["count"]?.int ?? 1
            var body: [String: JSONValue] = ["files": ExamGeneratorShop.filesJSON(p), "count": .number(Double(count))]
            do {
                return .json(try await ExamGeneratorShop.withSaved(try await relay.json("POST", "/api/exam-shop/buy", body: .object(body)), ctx))
            } catch let e as LocalHTTPError where e.status == 409 && e.detail["code"]?.string == "needs_texts" {
                // neue Probeklausuren: einmal die Seitentexte mitschicken (bleiben beim Dienst nur fuer das Erzeugen)
                body["texts"] = try await ExamGeneratorShop.texts(p, ctx)
                return .json(try await ExamGeneratorShop.withSaved(try await relay.json("POST", "/api/exam-shop/buy", body: .object(body)), ctx))
            }
        }

        router.post("/api/modules/{module_id:int}/exam-generator/collect") { req, ctx in
            let relay = try ExamGeneratorShop.relay(ctx)
            let m = Int64(req.intParam("module_id"))
            let p = try await ExamGeneratorShop.picked(req, ctx)
            let v = try await relay.json("POST", "/api/exam-shop/offer", body: ["files": ExamGeneratorShop.filesJSON(p)])
            // hinter der Sperre: laeuft gerade das Abholen von selbst, liegt danach schon alles da
            let added = try await ExamShopGate.shared.run { () async throws -> [JSONValue] in
                let have = try await ExamGeneratorShop.saved(ctx)
                var added: [JSONValue] = []
                for item in v["variants"]?.array ?? [] where item["paid"]?.bool == true && item["status"]?.string == "ready" {
                    guard let key = item["key"]?.string else { continue }
                    let n = item["variant"]?.int ?? 0
                    for (which, label) in ExamGeneratorShop.parts where have[key]?[which] == nil {
                        let data = try await relay.download("/api/exam-shop/item/\(key)/pdf/\(which)")
                        let fid = try await ExamGeneratorShop.store(data, title: "Probeklausur \(n) – \(label)", moduleID: m, key: key, which: which, ctx: ctx)
                        added.append(["key": .string(key), "which": .string(which), "file_id": .string(fid), "variant": .number(Double(n))])
                    }
                }
                return added
            }
            var out = try await ExamGeneratorShop.withSaved(v, ctx).object ?? [:]
            out["added"] = .array(added)
            out["pending"] = .number(Double((v["variants"]?.array ?? []).filter {
                $0["owned"]?.bool == true && ["pending", "running"].contains($0["status"]?.string ?? "") }.count))
            return .json(.object(out))
        }

        router.get("/api/modules/{module_id:int}/exam-generator/saved") { req, ctx in
            let m = Int64(req.intParam("module_id"))
            let items = try await ctx.database.transaction { c in try ExamGeneratorShop.savedInModule(m, c) }
            return .json(["items": .array(items)])
        }

        router.post("/api/exam-generator/collect") { _, ctx in
            return .json(try await ExamGeneratorShop.collectAll(ctx))
        }
    }
}
