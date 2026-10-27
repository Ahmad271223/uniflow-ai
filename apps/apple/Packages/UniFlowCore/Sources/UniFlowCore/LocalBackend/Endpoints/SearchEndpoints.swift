import Foundation

/// Suche und Skriptsuche wie in app/server.py (S7), offline aus der lokalen Datenbank: `GET /api/search` (Dateien,
/// Module, Aufgaben des Lernplans, Seitentexte), `POST /api/related` (passende Vorlesungs- und Skriptstellen,
/// `ScriptSearch`), `GET /api/files/{id}/pagetext`. Die Seitentexte liest PDFKit (`LocalDocumentTools`) und speichert
/// sie in `page_texts` wie app/scriptsearch.py; der Index fuellt sich beim Download und beim Oeffnen.
///
/// `/pagetext` liest wie am PC (seit b718cfb) den gespeicherten Text (`page_texts`): ohne Seitentext 404 mit
/// `code: no_content`, unbekannte Datei 404 "Datei nicht gefunden".
///
/// Abweichungen: ein Fehler beim Lesen der Datenbank antwortet mit eigener Meldung in `error` (am PC `str(e)`); ein
/// `text`, der kein Text ist, und falsche Zahlen in `page` antworten mit 422 statt 500.
public enum SearchEndpoints: LocalEndpointModule {
    public static let name = "Suche und Skriptsuche"

    public static func register(on router: LocalRouter) {
        // Namen, Titel und Faecher in der Suchform als Teiltext (`ScriptSearch.contains`) wie api_search: SQLite
        // lower() und LIKE kennen nur ASCII, % und _ der Anfrage waren Platzhalter; Papierkorb und abgewaehlte Kurse
        // fehlen wie in der Bibliothek
        router.get("/api/search") { req, ctx in
            let q = PyText.lower(PyText.strip(try req.requiredQuery("q")))
            if PyText.length(q) < 2 { return .json(["files": [], "modules": [], "tasks": [], "pages": []]) }
            let result = try await ctx.database.transaction { c -> JSONValue in
                let files = try c.rows("""
                    SELECT f.id, f.name, c.subject, c.module_id, a.title AS ai_title, a.doc_type, a.topics FROM files f
                    JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
                    WHERE f.deleted_at IS NULL AND c.active=1 ORDER BY f.chdate DESC
                    """).filter { ScriptSearch.contains(q, $0["name"]?.string, $0["ai_title"]?.string, $0["topics"]?.string, $0["subject"]?.string) }
                    .prefix(20)
                let mods = try c.rows("SELECT id, name, color FROM modules").filter { ScriptSearch.contains(q, $0["name"]?.string) }.prefix(5)
                let tasks = try c.rows("""
                    SELECT t.id, t.title, t.type, t.status, t.file_id, t.package_id, p.date, p.subject, p.module_id
                    FROM study_tasks t JOIN study_packages p ON p.id=t.package_id ORDER BY p.date DESC, t.id
                    """).filter { ScriptSearch.contains(q, $0["title"]?.string) }.prefix(10)
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
                let pages = try await ScriptSearch.pageTexts(fileID: id ?? "", database: ctx.database, files: ctx.files, clock: ctx.clock)
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
            guard try await ctx.database.queryOne("SELECT 1 FROM files WHERE id=?", [.text(id)]) != nil else {
                throw LocalHTTPError.notFound("Datei nicht gefunden")
            }
            let pages: [String]
            do {
                pages = try await ScriptSearch.pageTexts(fileID: id, database: ctx.database, files: ctx.files, clock: ctx.clock)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // am PC `str(e)`; hier ohne Datenbank-Meldung nach aussen (Pruefpunkt 555)
                return .json(["text": "", "error": "Seitentext nicht lesbar"])
            }
            // keine gueltigen gespeicherten Texte und keine lesbare lokale PDF (nie gelesen, nicht lesbar, keine PDF)
            guard !pages.isEmpty else { return .json(["detail": "Kein Seitentext vorhanden.", "code": "no_content"], status: 404) }
            guard page >= 1, page <= pages.count else { return .json(["text": "", "pages": .number(Double(pages.count))]) }
            return .json(["text": .string(pages[page - 1]), "pages": .number(Double(pages.count))])
        }
    }
}
