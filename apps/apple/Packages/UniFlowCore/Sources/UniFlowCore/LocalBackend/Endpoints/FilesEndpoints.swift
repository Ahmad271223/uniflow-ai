import Foundation

/// Kurse, Dateien und Datei-Inhalte wie in app/server.py ("Kurse & Dateien"), dazu das Abgleichprotokoll.
/// Die Daten schreibt der Stud.IP-Abgleich der App (`StudIPLibrary`), eigene Dokumente `POST /api/notebooks`.
///
/// Abweichungen: falsche Zahlen (`int(...)`) und Listen als Wert antworten mit 422 statt 500 wie in Python.
public enum FilesEndpoints: LocalEndpointModule {
    public static let name = "Kurse und Dateien"

    /// Felder, die `PATCH /api/courses/{id}` aendern darf
    static let courseFields: Set<String> = ["subject", "kind", "active", "test_minutes"]

    public static func register(on router: LocalRouter) {
        // MARK: Kurse (mit Pseudokurs "Eigene Dokumente")

        router.get("/api/courses") { _, ctx in
            let rows = try await ctx.database.rows("""
                SELECT c.*, (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id) AS file_count,
                       (SELECT COUNT(*) FROM files f WHERE f.course_id=c.id AND f.status='neu') AS new_count
                FROM courses c ORDER BY c.subject, c.kind, c.title
                """)
            return .json(.array(rows.map(JSONValue.object)))
        }

        router.patch("/api/courses/{course_id}") { req, ctx in
            let body = try req.pythonObjectBody()
            let id = SQLiteValue.text(req.param("course_id"))
            var updates: [(String, SQLiteValue)] = []
            for m in body where courseFields.contains(m.key) { updates.append((m.key, try LocalTerms.bindable(m.value, field: m.key))) }
            let changes = updates
            let row = try await ctx.database.transaction { c -> JSONValue in
                for (k, v) in changes { try c.execute("UPDATE courses SET \(k)=? WHERE id=?", [v, id]) }
                // Regel G6 (server._found): kein Datensatz -> 404, nie `null` mit 200
                guard let row = try c.queryOne("SELECT * FROM courses WHERE id=?", [id]) else { throw LocalHTTPError.notFound("Kurs nicht gefunden") }
                return .object(row.json)
            }
            return .json(row)
        }

        // MARK: Dateien

        router.get("/api/files") { req, ctx in
            var sql = """
                SELECT f.*, c.title AS course_title, c.subject, c.kind AS course_kind,
                       a.doc_type, a.title AS ai_title, a.topics, a.difficulty, a.est_minutes, a.summary,
                       (SELECT 1 FROM annotations an WHERE an.file_id=f.id) AS has_notes
                FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id WHERE 1=1
                """
            var params: [SQLiteValue] = []
            if let course = req.query("course_id"), !course.isEmpty { sql += " AND f.course_id=?"; params.append(.text(course)) }
            if let subject = req.query("subject"), !subject.isEmpty { sql += " AND c.subject=?"; params.append(.text(subject)) }
            sql += " ORDER BY f.chdate DESC"
            // f.* bringt download_url und content_sha256 schon mit; dazu die Herkunft wie study.file_source
            let rows = try await ctx.database.rows(sql, params).map { f -> [String: JSONValue] in
                var out = f
                out["source"] = .string(StudyClassify.fileSource(f))
                return out
            }
            return .json(.array(rows.map(JSONValue.object)))
        }

        router.get("/api/files/{file_id}") { req, ctx in
            guard var f = try await ctx.database.queryOne("""
                SELECT f.*, c.title AS course_title, c.subject, c.module_id, a.doc_type, a.title AS ai_title, a.topics,
                       a.difficulty, a.est_minutes, a.summary, a.prerequisites
                FROM files f JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
                WHERE f.id=?
                """, [.text(req.param("file_id"))])?.json else { throw LocalHTTPError.notFound() }
            f["exists"] = .bool(ctx.files?.exists(stored: f["local_path"]?.string) ?? false)
            return .json(.object(f))
        }

        // Bytes der lokalen Datei; PDF, Bilder und Text inline, alles andere nur zum Herunterladen. Unbekannte ID und
        // fehlende Datei mit verschiedenen Meldungen wie file_content (das Durchreichen ohne Datei auf der Platte,
        // LERNAPP_FILES=stream, gibt es nur im Dienst; das Geraet laedt die Datei selbst)
        router.get("/api/files/{file_id}/content") { req, ctx in
            guard let f = try await ctx.database.queryOne("SELECT local_path, name, mime FROM files WHERE id=?", [.text(req.param("file_id"))]) else {
                throw LocalHTTPError.notFound("Datei nicht gefunden")
            }
            guard let path = f["local_path"]?.string, !path.isEmpty, let files = ctx.files, files.exists(stored: path),
                  let url = files.url(stored: path) else {
                throw LocalHTTPError.notFound("Datei nicht lokal vorhanden")
            }
            let name = f["name"]?.string ?? ""
            let mime = f["mime"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            let mt = (mime ?? LocalFileResponse.guess(name) ?? "application/octet-stream")
                .split(separator: ";", omittingEmptySubsequences: false).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? "application/octet-stream"
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if LocalFileResponse.inlineTypes.contains(mt) {
                return LocalFileResponse.response(data, mediaType: mt, filename: name, disposition: "inline")
            }
            // HTML, SVG, Skripte usw. nie im Kontext der App anzeigen, sondern herunterladen
            return LocalFileResponse.response(data, mediaType: "application/octet-stream", filename: name, disposition: "attachment")
        }

        router.patch("/api/files/{file_id}") { req, ctx in
            let body = try req.pythonObjectBody()
            let id = SQLiteValue.text(req.param("file_id"))
            var status: String?
            if case .string(let s)? = body.value("status"), ["neu", "gelesen", "erledigt"].contains(s) { status = s }
            let difficulty = try body.has("difficulty") ? LocalTerms.pyInt(body.value("difficulty"), field: "difficulty") : nil
            let newStatus = status
            let row = try await ctx.database.transaction { c -> JSONValue in
                if let newStatus { try c.execute("UPDATE files SET status=?, seen_by_user=1 WHERE id=?", [.text(newStatus), id]) }
                if let difficulty { try c.execute("UPDATE analysis SET difficulty=? WHERE file_id=?", [.integer(Int64(difficulty)), id]) }
                // Regel G6 (server._changed/_found): unbekannte Datei -> 404
                guard let row = try c.queryOne("SELECT * FROM files WHERE id=?", [id]) else { throw LocalHTTPError.notFound("Datei nicht gefunden") }
                return .object(row.json)
            }
            return .json(row)
        }

        // Geoeffnet (zaehlt, gilt als gesehen) oder nur die zuletzt gelesene Seite merken
        router.post("/api/files/{file_id}/opened") { req, ctx in
            let body = req.body.isEmpty ? [] : try req.pythonObjectBody()
            let id = SQLiteValue.text(req.param("file_id"))
            let page = try body.has("last_page") ? LocalTerms.pyInt(body.value("last_page"), field: "last_page") : nil
            let now = ctx.clock.nowISO
            try await ctx.database.transaction { c in
                if let page {
                    try c.execute("UPDATE files SET last_page=? WHERE id=?", [.integer(Int64(page)), id])
                } else {
                    try c.execute("UPDATE files SET last_opened=?, opened_count=COALESCE(opened_count,0)+1, seen_by_user=1 WHERE id=?", [.text(now), id])
                }
                if c.changes == 0 { throw LocalHTTPError.notFound("Datei nicht gefunden") }     // Regel G6 (server._changed)
            }
            return .ok
        }

        router.post("/api/files/{file_id}/favorite") { req, ctx in
            let body = try req.pythonObjectBody()
            let fav: Int64 = LocalTerms.truthy(body.value("favorite")) ? 1 : 0
            let id = SQLiteValue.text(req.param("file_id"))
            try await ctx.database.transaction { c in
                try c.execute("UPDATE files SET favorite=? WHERE id=?", [.integer(fav), id])
                if c.changes == 0 { throw LocalHTTPError.notFound("Datei nicht gefunden") }     // Regel G6 (server._changed)
            }
            return .ok
        }

        router.post("/api/files/mark-seen") { _, ctx in
            try await ctx.database.transaction { c in try c.execute("UPDATE files SET seen_by_user=1") }
            return .ok
        }

        // MARK: Abgleich

        // Protokoll der Stud.IP-Abgleiche auf diesem Geraet (StudIPLibrary.log); eine Hintergrundaufgabe gibt es nicht
        router.get("/api/sync/status") { _, ctx in
            let log = try await ctx.database.rows("SELECT * FROM sync_log ORDER BY id DESC LIMIT 20")
            return .json(["bg": LocalPending.bg, "log": .array(log.map(JSONValue.object))])
        }
    }
}
