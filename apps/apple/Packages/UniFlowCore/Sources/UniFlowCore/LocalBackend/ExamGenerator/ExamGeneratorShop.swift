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
///
/// Nur ueber die StudiNow-KI des Kontos (auch wenn daneben ein eigenes ChatGPT verbunden ist); ohne sie 403
/// `exam_generator_needs_service`.
enum ExamGeneratorShop {
    static let folderName = "Probeklausuren"
    static let needsService = "Der Klausur-Generator läuft über die StudiNow-KI. Melde dich dafür mit deinem StudiNow-Konto an (StudiNow Pro AI)."

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
            let have = try await ExamGeneratorShop.saved(ctx)
            var added: [JSONValue] = []
            for item in v["variants"]?.array ?? [] where item["paid"]?.bool == true && item["status"]?.string == "ready" {
                guard let key = item["key"]?.string else { continue }
                let n = item["variant"]?.int ?? 0
                for (which, label) in [("aufgaben", "Aufgaben"), ("loesungen", "Lösungen")] where have[key]?[which] == nil {
                    let data = try await relay.download("/api/exam-shop/item/\(key)/pdf/\(which)")
                    let fid = try await ExamGeneratorShop.store(data, title: "Probeklausur \(n) – \(label)", moduleID: m, key: key, which: which, ctx: ctx)
                    added.append(["key": .string(key), "which": .string(which), "file_id": .string(fid), "variant": .number(Double(n))])
                }
            }
            var out = try await ExamGeneratorShop.withSaved(v, ctx).object ?? [:]
            out["added"] = .array(added)
            out["pending"] = .number(Double((v["variants"]?.array ?? []).filter {
                $0["owned"]?.bool == true && ["pending", "running"].contains($0["status"]?.string ?? "") }.count))
            return .json(.object(out))
        }
    }
}
