import Foundation

/// Bibliothek, Ordner, Notizbuecher und Dokument-Aktionen wie in app/server.py (Abschnitt "Bibliothek").
///
/// Abweichungen: Python scheitert bei falschen Zahlen (`int(folder_id)`) mit 500, hier 422 mit Meldung.
/// `delete_forever` loescht die Datei nur, wenn kein anderes Dokument sie noch nutzt (Duplikate teilen sich die
/// Datei); in app/server.py ebenso korrigiert.
public enum LibraryEndpoints: LocalEndpointModule {
    public static let name = "Bibliothek"

    /// Neue Kennung eigener Dokumente: `"u" + uuid4().hex[:23]`
    static func newDocumentID(_ ctx: LocalContext) -> String { "u" + String(ctx.newHex().prefix(23)) }

    /// Unix-Zeit jetzt (`int(datetime.now().timestamp())`)
    static func unixNow(_ ctx: LocalContext) -> Int64 { Int64(ctx.clock.now.timeIntervalSince1970.rounded(.down)) }

    public static func register(on router: LocalRouter) {
        router.get("/api/library") { _, ctx in
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { try LocalLibrary.library($0, clock: clock) })
        }

        // MARK: Ordner

        router.post("/api/folders") { req, ctx in
            let body = try req.pythonObjectBody()
            let name: SQLiteValue = LocalTerms.truthy(body.value("name")) ? try LocalTerms.bindable(body.value("name")!, field: "name") : .text("Neuer Ordner")
            let values: [SQLiteValue] = [name] + (try ["parent_id", "module_id", "color"].map { try LocalTerms.bindable(body.value($0) ?? .null, field: $0) })
                + [.text(ctx.clock.nowISO)]
            let row = try await ctx.database.transaction { c -> JSONValue in
                try c.execute("INSERT INTO folders(name, parent_id, module_id, color, created_at) VALUES (?,?,?,?,?)", values)
                return try c.queryOne("SELECT * FROM folders WHERE id=?", [.integer(c.lastInsertRowID)]).map { .object($0.json) } ?? .null
            }
            return .json(row)
        }

        router.patch("/api/folders/{folder_id:int}") { req, ctx in
            let body = try req.pythonObjectBody()
            let id = SQLiteValue.integer(Int64(req.intParam("folder_id")))
            var updates: [(String, SQLiteValue)] = []
            for k in ["name", "parent_id", "module_id", "color"] where body.has(k) {
                updates.append((k, try LocalTerms.bindable(body.value(k)!, field: k)))
            }
            let changes = updates
            let row = try await ctx.database.transaction { c -> JSONValue in
                for (k, v) in changes { try c.execute("UPDATE folders SET \(k)=? WHERE id=?", [v, id]) }
                return try c.queryOne("SELECT * FROM folders WHERE id=?", [id]).map { .object($0.json) } ?? .null
            }
            return .json(row)
        }

        // Inhalt und Unterordner wandern eine Ebene nach oben
        router.delete("/api/folders/{folder_id:int}") { req, ctx in
            let id = SQLiteValue.integer(Int64(req.intParam("folder_id")))
            try await ctx.database.transaction { c in
                try c.execute("UPDATE files SET folder_id=(SELECT parent_id FROM folders WHERE id=?) WHERE folder_id=?", [id, id])
                try c.execute("UPDATE folders SET parent_id=(SELECT parent_id FROM folders WHERE id=?) WHERE parent_id=?", [id, id])
                try c.execute("DELETE FROM folders WHERE id=?", [id])
            }
            return .ok
        }

        // MARK: Eigene Dokumente

        router.post("/api/notebooks") { req, ctx in try await createNotebook(req, ctx) }

        router.patch("/api/library/files/{file_id}") { req, ctx in try await patchLibraryFile(req, ctx) }
    }

    /// `POST /api/notebooks`: Notizbuch oder Whiteboard (leer, mit Vorlage) oder Import einer PDF bzw. eines Bilds.
    static func createNotebook(_ req: LocalRequest, _ ctx: LocalContext) async throws -> LocalResponse {
        let form = try req.multipart()
        let fid = newDocumentID(ctx)                                            // wie Python vor allen Pruefungen
        // FastAPI: leeres Formularfeld = Standardwert
        func field(_ k: String, _ d: String) -> String {
            guard let v = form.fields[k], !v.isEmpty else { return d }
            return v
        }
        var kind = field("kind", "notebook")
        var title = field("title", "Neues Notizbuch")
        let moduleID = field("module_id", "")
        let folderID = field("folder_id", "")
        let template = field("template", "blank")
        let folder: Int? = try folderID.isEmpty ? nil : LocalTerms.pyInt(.string(folderID), field: "folder_id")
        let module: Int? = try moduleID.isEmpty ? nil : LocalTerms.pyInt(.string(moduleID), field: "module_id")
        var local: String?
        var pageCount: Int?
        if let upload = form.file("upload"), kind == "pdf" || kind == "image" {
            let files = try ctx.requireFiles()
            let ext = LocalFileResponse.suffix(upload.filename.isEmpty ? "datei.pdf" : upload.filename)?.lowercased() ?? ".pdf"
            if kind == "image" && ![".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"].contains(ext) {
                throw LocalHTTPError(status: 400, message: "Nur Bilddateien")
            }
            let data = upload.data
            if kind == "pdf" && !data.starts(with: Array("%PDF".utf8)) { throw LocalHTTPError(status: 400, message: "Die Datei ist keine PDF") }
            let dir = files.ownDocumentsDirectory
            if kind == "image" {
                if let pdf = files.tools.pdfFromImage(data) {
                    // Bild als PDF-Seite (Pillow in Python)
                    local = dir + "/" + fid + ".pdf"
                    _ = try files.write(pdf, to: local!)
                    pageCount = 1
                } else {
                    // ohne Umwandlung als Bild ablegen, wie Python ohne Pillow
                    local = dir + "/" + fid + ext
                    _ = try files.write(data, to: local!)
                    kind = "image"
                }
            } else {
                local = dir + "/" + fid + ".pdf"
                _ = try files.write(data, to: local!)
                pageCount = files.tools.pdfPageCount(data)
            }
            if title.isEmpty { title = stem(upload.filename.isEmpty ? "Dokument" : upload.filename) }
        }
        let now = ctx.clock.nowISO
        let docTitle = title.isEmpty ? "Dokument" : title
        let values: [SQLiteValue] = [
            .text(fid), .text(docTitle + (local != nil ? ".pdf" : "")), 0, local != nil ? .text("application/pdf") : .null, .text("Ich"),
            .integer(unixNow(ctx)), .text(""), SQLiteValue(local), .text(now), .text(now), SQLiteValue(folder), .text(kind),
            .text(docTitle), SQLiteValue(pageCount),
        ]
        var model: String?
        if kind == "notebook" || kind == "whiteboard" {
            let size: [PyJSON.Member] = kind == "whiteboard" ? [.init("w", .int("842")), .init("h", .int("595"))] : [.init("w", .int("595")), .init("h", .int("842"))]
            let page: [PyJSON.Member] = [.init("key", .string("b1")), .init("type", .string("blank")), .init("template", .string(template))] + size
            model = PyJSON.object([
                .init("version", .int("2")), .init("zoom", .float(1.2)), .init("pages", .object([.init("b1", .object([.init("objects", .array([]))]))])),
                .init("pageOrder", .array([.object(page)])), .init("bookmarks", .array([])), .init("outline", .array([])),
            ]).dumps
        }
        let stored = local, annotations = model
        do {
            let row = try await ctx.database.transaction { c -> JSONValue in
                try c.execute("""
                    INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, local_path, downloaded_at, first_seen, status, seen_by_user,
                                      folder_id, kind, title, page_count)
                    VALUES (?,'__user__',?,?,?,?,?,?,?,?,?,'gelesen',1,?,?,?,?)
                    """, values)
                if let annotations {
                    try c.execute("INSERT INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,1)", [.text(fid), .text(annotations), .text(now)])
                }
                if let module, try c.queryOne("SELECT name FROM modules WHERE id=?", [.integer(Int64(module))]) != nil {
                    // Notizbuch dem Modul zuordnen: ueber den Ordner "Eigene Notizen" des Moduls
                    var folderRow = try c.scalar("SELECT id FROM folders WHERE module_id=? AND parent_id IS NULL AND name='Eigene Notizen'", [.integer(Int64(module))])
                    if folderRow == nil {
                        try c.execute("INSERT INTO folders(name, parent_id, module_id, created_at) VALUES ('Eigene Notizen', NULL, ?, ?)", [.integer(Int64(module)), .text(now)])
                        folderRow = .integer(c.lastInsertRowID)
                    }
                    try c.execute("UPDATE files SET folder_id=? WHERE id=?", [folderRow ?? .null, .text(fid)])
                }
                return try c.queryOne("SELECT * FROM files WHERE id=?", [.text(fid)]).map { .object($0.json) } ?? .null
            }
            return .json(row)
        } catch {
            if let stored { ctx.files?.remove(stored: stored) }          // keine verwaiste Datei
            throw error
        }
    }

    /// `Path(name).stem`
    static func stem(_ name: String) -> String {
        let last = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        guard let suffix = LocalFileResponse.suffix(last) else { return last }
        return String(last.dropLast(suffix.count))
    }

    /// `PATCH /api/library/files/{file_id}`: Titel, Ordner, Papierkorb, Wiederherstellen, Duplizieren, endgueltig
    /// loeschen (nur eigene Dokumente). Alles in einer Transaktion: scheitert ein Schritt, bleibt alles wie vorher
    /// (Python: kein commit nach der Ausnahme).
    static func patchLibraryFile(_ req: LocalRequest, _ ctx: LocalContext) async throws -> LocalResponse {
        let body = try req.pythonObjectBody()
        let id = SQLiteValue.text(req.param("file_id"))
        let title = try body.value("title").map { try LocalTerms.bindable($0, field: "title") }
        let folder = try body.value("folder_id").map { try LocalTerms.bindable($0, field: "folder_id") }
        let trash = LocalTerms.truthy(body.value("trash")), restore = LocalTerms.truthy(body.value("restore"))
        let duplicate = LocalTerms.truthy(body.value("duplicate")), deleteForever = LocalTerms.truthy(body.value("delete_forever"))
        let now = ctx.clock.nowISO, unix = unixNow(ctx)
        let nid = duplicate ? newDocumentID(ctx) : ""
        let files = ctx.files
        let result = try await ctx.database.transaction { c -> (JSONValue, String?) in
            if let title { try c.execute("UPDATE files SET title=? WHERE id=?", [title, id]) }
            if let folder { try c.execute("UPDATE files SET folder_id=? WHERE id=?", [folder, id]) }
            if trash { try c.execute("UPDATE files SET deleted_at=? WHERE id=?", [.text(now), id]) }
            if restore { try c.execute("UPDATE files SET deleted_at=NULL WHERE id=?", [id]) }
            if duplicate {
                let ann = try c.scalar("SELECT data FROM annotations WHERE file_id=?", [id])
                try c.execute("""
                    INSERT INTO files(id, course_id, name, size, mime, author, chdate, download_url, local_path, downloaded_at, first_seen, status, seen_by_user, folder_id, kind, title, page_count)
                    SELECT ?, course_id, name, size, mime, author, ?, download_url, local_path, downloaded_at, ?, 'gelesen', 1, folder_id, kind, COALESCE(title, name) || ' (Kopie)', page_count FROM files WHERE id=?
                    """, [.text(nid), .integer(unix), .text(now), id])
                if let ann {
                    try c.execute("INSERT INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,1)", [.text(nid), ann, .text(now)])
                }
                return (["ok": true, "id": .string(nid)], nil)
            }
            if deleteForever {
                let f = try c.queryOne("SELECT local_path, course_id FROM files WHERE id=?", [id])
                if let f, f["course_id"]?.string != "__user__" {
                    throw LocalHTTPError(status: 400, message: "Stud.IP-Dokumente können nur in den Papierkorb, nicht endgültig gelöscht werden.")
                }
                for t in ["annotation_versions", "annotations", "analysis", "flashcards", "recordings"] {
                    try c.execute("DELETE FROM \(t) WHERE file_id=?", [id])
                }
                try c.execute("UPDATE study_tasks SET file_id=NULL WHERE file_id=?", [id])
                try c.execute("DELETE FROM files WHERE id=?", [id])
                // Duplikate teilen sich die Datei: nur loeschen, wenn sie kein anderes Dokument mehr nutzt
                var unlink: String?
                if let path = f?["local_path"]?.string, !path.isEmpty,
                   try c.queryOne("SELECT 1 FROM files WHERE local_path=?", [.text(path)]) == nil {
                    unlink = path
                }
                return (["ok": true], unlink)
            }
            return (["ok": true], nil)
        }
        if let path = result.1, files?.exists(stored: path) == true { files?.remove(stored: path) }
        return .json(result.0)
    }
}
