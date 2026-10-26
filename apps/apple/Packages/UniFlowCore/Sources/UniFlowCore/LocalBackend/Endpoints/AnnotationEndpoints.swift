import Foundation

/// Notizen eines Dokuments mit Versionen und Bilder der Notizen wie in app/server.py.
///
/// `PUT .../annotations?base_version=n`: Ist der gespeicherte Stand neuer, kommt 409 mit `version` und `data` (die
/// App fuehrt zusammen). Gespeichert wird derselbe Text wie in Python (`json.dumps(body, ensure_ascii=False)`), die
/// letzten 30 Versionen bleiben erhalten.
///
/// Abweichung: Fuer ein Dokument, das es in der lokalen Datenbank nicht gibt, scheitert Python mit 500 (Fremdschluessel
/// `annotations.file_id`); hier 409 mit Meldung und ohne `version` – die App wertet das als "kann hier nicht
/// speichern" und behaelt die Notizen im Journal, statt ohne Ende zu wiederholen. Nur auf dem Geraet: Striche auf
/// Seiten, die eine neue Original-Fassung entfernt hat, kommen zusaetzlich zur alten Fassung
/// (`FileVersions.keepLateNotes`; die Antwort bleibt wie in Python).
public enum AnnotationEndpoints: LocalEndpointModule {
    public static let name = "Notizen"

    /// Hoechstens so viele Versionen je Dokument
    static let keptVersions = 30

    /// `_SAFE_ID`: Datei-IDs werden fuer Pfade benutzt
    static func isSafeID(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (1...80).contains(u.count), isAlnum(u[0]) else { return false }
        return u.dropFirst().allSatisfy { isAlnum($0) || $0 == 0x5F || $0 == 0x2D }
    }

    /// `_SAFE_NAME`: `[A-Za-z0-9][A-Za-z0-9_-]{0,99}\.[A-Za-z0-9]{1,6}`
    static func isSafeName(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard let dot = u.lastIndex(of: 0x2E), dot >= 1, dot <= 100 else { return false }
        let head = u[..<dot], ext = u[(dot + 1)...]
        guard isAlnum(head.first!), head.dropFirst().allSatisfy({ isAlnum($0) || $0 == 0x5F || $0 == 0x2D }) else { return false }
        return (1...6).contains(ext.count) && ext.allSatisfy(isAlnum)
    }

    private static func isAlnum(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) }

    static let assetExtensions: Set<String> = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".pdf"]
    static let maxAssetBytes = 15 * 1024 * 1024

    public static func register(on router: LocalRouter) {
        router.get("/api/files/{file_id}/annotations") { req, ctx in
            let r = try await ctx.database.queryOne("SELECT data, updated_at, version FROM annotations WHERE file_id=?", [.text(req.param("file_id"))])
            guard let r else { return .json(LocalPending.emptyAnnotations) }
            return .json(["data": try parseStored(r["data"]), "updated_at": r["updated_at"]?.json ?? .null,
                          "version": .number(Double(version(r["version"])))])
        }

        router.put("/api/files/{file_id}/annotations") { req, ctx in
            var base: Int?
            if let raw = req.query("base_version") {
                guard let v = PyConvert.int(raw) else {
                    throw LocalHTTPError.validation(type: "int_parsing", loc: ["query", "base_version"],
                                                   msg: "Input should be a valid integer, unable to parse string as an integer", input: .string(raw))
                }
                base = v
            }
            _ = try req.objectBody()                                              // 422 wie FastAPI, wenn kein Objekt
            let body = try PyJSON.parse(req.body)
            return try await save(fileID: req.param("file_id"), body: body, baseVersion: base, ctx)
        }

        router.get("/api/files/{file_id}/annotations/versions") { req, ctx in
            let rows = try await ctx.database.rows("SELECT version, created_at, length(data) AS size FROM annotation_versions WHERE file_id=? ORDER BY version DESC",
                                                   [.text(req.param("file_id"))])
            return .json(.array(rows.map(JSONValue.object)))
        }

        router.post("/api/files/{file_id}/annotations/restore/{version:int}") { req, ctx in
            let id = req.param("file_id")
            guard let data = try await ctx.database.scalar("SELECT data FROM annotation_versions WHERE file_id=? AND version=?",
                                                           [.text(id), .integer(Int64(req.intParam("version")))])?.string else {
                throw LocalHTTPError.notFound("Version nicht gefunden")
            }
            let body: PyJSON
            do { body = try PyJSON.parse(data) } catch { throw LocalHTTPError(status: 500, message: "Gespeicherte Version ist kein gültiges JSON") }
            return try await save(fileID: id, body: body, baseVersion: nil, ctx)
        }

        // MARK: Bilder der Notizen

        router.post("/api/files/{file_id}/assets") { req, ctx in
            let form = try req.multipart()
            guard let upload = form.file("upload") else {
                throw LocalHTTPError.validation(type: "missing", loc: ["body", "upload"], msg: "Field required", input: .null)
            }
            let fileID = req.param("file_id")
            guard isSafeID(fileID) else { throw LocalHTTPError(status: 400, message: "Ungueltige ID") }
            let ext = LocalFileResponse.suffix(upload.filename.isEmpty ? "bild.png" : upload.filename)?.lowercased() ?? ".png"
            guard assetExtensions.contains(ext) else { throw LocalHTTPError(status: 400, message: "Nur Bild- oder PDF-Dateien") }
            let files = try ctx.requireFiles()
            let name = ctx.newHex() + ext                                       // Reihenfolge wie Python (Kennung vor der Groessenpruefung)
            guard upload.data.count <= maxAssetBytes else { throw LocalHTTPError(status: 400, message: "Bild zu gross (max. 15 MB)") }
            _ = try files.write(upload.data, to: files.assetsDirectory(fileID: fileID) + "/" + name)
            return .json(["url": .string("/api/assets/\(fileID)/\(name)"), "name": .string(name)])
        }

        router.get("/api/assets/{file_id}/{name}") { req, ctx in
            let fileID = req.param("file_id"), name = req.param("name")
            guard isSafeID(fileID) else { throw LocalHTTPError(status: 400, message: "Ungueltige ID") }
            guard isSafeName(name) else { throw LocalHTTPError(status: 400, message: "Ungueltiger Dateiname") }
            guard let files = ctx.files else { throw LocalHTTPError.notFound() }
            let path = files.assetsDirectory(fileID: fileID) + "/" + name
            guard files.exists(stored: path), let url = files.url(stored: path) else { throw LocalHTTPError.notFound() }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            // FileResponse ohne Typ: aus dem Namen geraten, sonst text/plain
            return LocalFileResponse.response(data, mediaType: LocalFileResponse.guess(name) ?? "text/plain", filename: nil, disposition: "inline")
        }
    }

    /// `version or 1`
    static func version(_ v: SQLiteValue?) -> Int {
        guard let v, LocalModules.truthy(v) else { return 1 }
        return v.int ?? Int(v.double ?? 1)
    }

    /// `json.loads(data)` des gespeicherten Texts
    static func parseStored(_ v: SQLiteValue?) throws -> JSONValue {
        guard let text = v?.string else { throw LocalHTTPError(status: 500, message: "Gespeicherte Notizen sind kein Text") }
        do { return try JSONValue.parse(text) } catch { throw LocalHTTPError(status: 500, message: "Gespeicherte Notizen sind kein gültiges JSON") }
    }

    /// Schreiben wie `put_annotations` nach der Versionspruefung (in einer Transaktion): Stand, Versionsverlauf, die
    /// letzten `keptVersions` Versionen bleiben. Auch fuer Notizen, die eine neue Original-Fassung umhaengt
    /// (`FileVersionKeeper`). Rueckgabe: die geschriebene Version.
    @discardableResult
    static func write(_ c: SQLiteConnection, fileID: String, payload: String, version: Int, now: String) throws -> Int {
        let id = SQLiteValue.text(fileID)
        let newV = Int64(version)
        try c.execute("INSERT INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,?) "
                      + "ON CONFLICT(file_id) DO UPDATE SET data=excluded.data, updated_at=excluded.updated_at, version=excluded.version",
                      [id, .text(payload), .text(now), .integer(newV)])
        try c.execute("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES (?,?,?,?)",
                      [id, .integer(newV), .text(payload), .text(now)])
        try c.execute("""
            DELETE FROM annotation_versions WHERE file_id=? AND id NOT IN (
                SELECT id FROM annotation_versions WHERE file_id=? ORDER BY version DESC LIMIT \(keptVersions))
            """, [id, id])
        return version
    }

    /// `put_annotations(file_id, body, base_version)`: Versionspruefung und Schreiben in einer Transaktion
    static func save(fileID: String, body: PyJSON, baseVersion: Int?, _ ctx: LocalContext) async throws -> LocalResponse {
        let payload = body.dumps(ensureASCII: false)
        let now = ctx.clock.nowISO
        let id = SQLiteValue.text(fileID)
        enum Outcome: Sendable { case saved(Int), conflict(Int, String), unknownFile }
        let outcome = try await ctx.database.transaction { c -> Outcome in
            let cur = try c.queryOne("SELECT version, data FROM annotations WHERE file_id=?", [id])
            let curV = cur.map { version($0["version"]) } ?? 0
            if let baseVersion, let cur, curV != baseVersion {
                return .conflict(curV, cur["data"]?.string ?? "null")
            }
            guard try c.queryOne("SELECT 1 FROM files WHERE id=?", [id]) != nil else { return .unknownFile }
            let v = try write(c, fileID: fileID, payload: payload, version: curV + 1, now: now)
            // nur auf dem Geraet (S7): spaete Striche auf Seiten, die eine neue Fassung entfernt hat, zur alten Fassung
            try FileVersions.keepLateNotes(c, fileID: fileID, payload: payload)
            return .saved(v)
        }
        switch outcome {
        case .saved(let v):
            return .json(["ok": true, "version": .number(Double(v))])
        case .conflict(let v, let data):
            return .json(["detail": "Konflikt: Server hat eine neuere Version", "version": .number(Double(v)),
                          "data": try parseStored(.text(data))], status: 409)
        case .unknownFile:
            throw LocalHTTPError(status: 409, message: "Dieses Dokument gibt es auf diesem iPad nicht. Deine Notizen bleiben lokal gesichert.")
        }
    }
}
