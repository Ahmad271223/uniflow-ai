import Foundation

/// Suche und Skriptsuche wie in app/server.py (S7), offline aus der lokalen Datenbank: `GET /api/search` (Dateien,
/// Module, Aufgaben des Lernplans, Seitentexte), `POST /api/related` (passende Vorlesungs- und Skriptstellen,
/// `ScriptSearch`), `GET /api/files/{id}/pagetext`. Die Seitentexte liest PDFKit (`LocalDocumentTools`) und speichert
/// sie in `page_texts` wie app/scriptsearch.py; der Index fuellt sich beim Download und beim Oeffnen.
///
/// Abweichungen: `/pagetext` liest den gespeicherten Text (am PC jedes Mal neu mit pypdf; gleiche Antwort), eine
/// nicht lesbare Datei antwortet mit eigener Meldung in `error` (am PC die Meldung von pypdf); ein `text`, der kein
/// Text ist, und falsche Zahlen in `page` antworten mit 422 statt 500.
public enum SearchEndpoints: LocalEndpointModule {
    public static let name = "Suche und Skriptsuche"

    public static func register(on router: LocalRouter) {
        router.get("/api/search") { req, ctx in
            let q = PyText.lower(PyText.strip(try req.requiredQuery("q")))
            if PyText.length(q) < 2 { return .json(["files": [], "modules": [], "tasks": [], "pages": []]) }
            let like = SQLiteValue.text("%" + q + "%")
            let result = try await ctx.database.transaction { c -> JSONValue in
                let files = try c.rows("""
                    SELECT f.id, f.name, c.subject, c.module_id, a.title AS ai_title, a.doc_type, a.topics FROM files f
                    JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
                    WHERE lower(f.name) LIKE ? OR lower(COALESCE(a.title,'')) LIKE ? OR lower(COALESCE(a.topics,'')) LIKE ? OR lower(c.subject) LIKE ?
                    ORDER BY f.chdate DESC LIMIT 20
                    """, [like, like, like, like])
                let mods = try c.rows("SELECT id, name, color FROM modules WHERE lower(name) LIKE ? LIMIT 5", [like])
                let tasks = try c.rows("""
                    SELECT t.id, t.title, t.type, t.status, t.file_id, t.package_id, p.date, p.subject, p.module_id
                    FROM study_tasks t JOIN study_packages p ON p.id=t.package_id
                    WHERE lower(t.title) LIKE ? ORDER BY p.date DESC, t.id LIMIT 10
                    """, [like])
                return ["files": .array(files.map(JSONValue.object)), "modules": .array(mods.map(JSONValue.object)),
                        "tasks": .array(tasks.map(JSONValue.object)), "pages": .array(try ScriptSearch.findPages(c, q))]
            }
            return .json(result)
        }

        router.post("/api/related") { req, ctx in
            let body = try req.pythonObjectBody()
            let fid = body.value("file_id").flatMap { SQLiteValue(json: $0.json) } ?? .null
            var text = ""
            if let t = body.value("text"), LocalModules.truthy(t.json) {
                guard case .string(let s) = t else { throw LocalHTTPError(status: 422, message: "text: Text erwartet") }
                text = PyText.strip(s)
            }
            let raw = body.value("page")
            let page = LocalModules.truthy(raw?.json) ? try LocalTerms.pyInt(raw, field: "page") : 0
            let module = try await ctx.database.withConnection { c -> SQLiteValue? in
                try c.queryOne("SELECT f.id, c.module_id FROM files f JOIN courses c ON c.id=f.course_id WHERE f.id=?", [fid])?["module_id"]
            }
            guard let module, LocalModules.truthy(module) else {
                return .json(["terms": [], "results": [], "note": "Dokument gehoert zu keinem Modul"])
            }
            let id = fid.string
            if text.isEmpty, page != 0 {
                let pages = try await ScriptSearch.pageTexts(fileID: id ?? "", database: ctx.database, files: ctx.files)
                text = 0 < page && page <= pages.count ? pages[page - 1] : ""
            }
            return .json(try await ScriptSearch.search(moduleID: module, query: PyText.slice(text, 0, 6000), exclude: id,
                                                       database: ctx.database, files: ctx.files, cache: ctx.scriptIndex))
        }

        router.get("/api/files/{file_id}/pagetext") { req, ctx in
            var page = 1
            if let raw = req.query("page") {
                guard let v = PyConvert.int(raw) else {
                    throw LocalHTTPError.validation(type: "int_parsing", loc: ["query", "page"],
                                                    msg: "Input should be a valid integer, unable to parse string as an integer", input: .string(raw))
                }
                page = v
            }
            let id = req.param("file_id")
            let path = try await ctx.database.scalar("SELECT local_path FROM files WHERE id=?", [.text(id)])?.string
            guard let path, !path.isEmpty, let files = ctx.files, files.exists(stored: path) else { throw LocalHTTPError.notFound() }
            let pages = try await ScriptSearch.pageTexts(fileID: id, database: ctx.database, files: files)
            // jede PDF hat mindestens eine Seite: keine Texte heisst nicht lesbar (am PC die Meldung von pypdf)
            guard !pages.isEmpty else { return .json(["text": "", "error": "Seitentext nicht lesbar"]) }
            guard page >= 1, page <= pages.count else { return .json(["text": "", "pages": .number(Double(pages.count))]) }
            return .json(["text": .string(pages[page - 1]), "pages": .number(Double(pages.count))])
        }
    }
}
