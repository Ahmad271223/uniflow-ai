import Foundation

/// Notizen eines Dokuments mit Versionen und Bilder der Notizen wie in app/server.py.
///
/// `PUT .../annotations?base_version=n`: Ist der gespeicherte Stand neuer, kommt 409 mit `version` und `data` (die
/// App fuehrt zusammen). Gespeichert wird derselbe Text wie in Python (`json.dumps(body, ensure_ascii=False)`).
/// Versionsverlauf wie `_put_annotations` (Editor-Schritt 4, P0-9): hoechstens eine Version je 5 Minuten; mit
/// `snapshot=true` (Schliessen, nach einem Konflikt, Wiederherstellen) dazu der ersetzte und der neue Stand; die
/// letzten 30 bleiben erhalten.
///
/// Abweichung: Fuer ein Dokument, das es in der lokalen Datenbank nicht gibt, scheitert Python mit 500 (Fremdschluessel
/// `annotations.file_id`); hier 409 mit Meldung und ohne `version` – die App wertet das als "kann hier nicht
/// speichern" und behaelt die Notizen im Journal, statt ohne Ende zu wiederholen. Nur auf dem Geraet: Striche auf
/// Seiten, die eine neue Original-Fassung entfernt hat, kommen zusaetzlich zur alten Fassung
/// (`FileVersions.keepLateNotes`; die Antwort bleibt wie in Python).
public enum AnnotationEndpoints: LocalEndpointModule {
    public static let name = "Notizen"

    /// Hoechstens so viele Versionen je Dokument (`KEPT_VERSIONS`)
    static let keptVersions = 30
    /// Hoechstens eine Version je so vielen Sekunden (`VERSION_EVERY_S`)
    static let versionEvery = 300

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
            let fileID = SQLiteValue.text(req.param("file_id"))
            // Regel G6 (server._found): unbekannte Datei -> 404 statt leerer Notizen
            guard try await ctx.database.queryOne("SELECT 1 FROM files WHERE id=?", [fileID]) != nil else {
                throw LocalHTTPError.notFound("Datei nicht gefunden")
            }
            let r = try await ctx.database.queryOne("SELECT data, updated_at, version FROM annotations WHERE file_id=?", [fileID])
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
            let snapshot = try req.boolQuery("snapshot") ?? false
            // einmal lesen (bei dichten Dokumenten der groesste Posten einer Runde, docs/EDITOR-MESSUNG.md M1); nur
            // wenn es kein Objekt ist, noch einmal fuer dieselbe 422 wie FastAPI
            let body: PyJSON
            if let parsed = try? PyJSON.parse(req.body), case .object = parsed {
                body = parsed
            } else {
                _ = try req.objectBody()
                body = try PyJSON.parse(req.body)
            }
            return try await save(fileID: req.param("file_id"), body: body, baseVersion: base, snapshot: snapshot, ctx)
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
            return try await save(fileID: id, body: body, baseVersion: nil, snapshot: true, ctx)    // Stand davor bleibt im Verlauf
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

    /// Schreiben wie `put_annotations` nach der Versionspruefung (in einer Transaktion): Stand und, wenn faellig
    /// (`snapshot` oder `versionDue`), Versionsverlauf; die letzten `keptVersions` Versionen bleiben. Auch fuer Notizen,
    /// die eine neue Original-Fassung umhaengt (`FileVersionKeeper`, immer mit Version). Rueckgabe: die geschriebene Version.
    @discardableResult
    static func write(_ c: SQLiteConnection, fileID: String, payload: String, version: Int, now: String, snapshot: Bool = true) throws -> Int {
        let id = SQLiteValue.text(fileID)
        let newV = Int64(version)
        let due = try snapshot || versionDue(c, fileID: fileID, now: now)
        try c.execute("INSERT INTO annotations(file_id, data, updated_at, version) VALUES (?,?,?,?) "
                      + "ON CONFLICT(file_id) DO UPDATE SET data=excluded.data, updated_at=excluded.updated_at, version=excluded.version",
                      [id, .text(payload), .text(now), .integer(newV)])
        guard due else { return version }
        try c.execute("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES (?,?,?,?)",
                      [id, .integer(newV), .text(payload), .text(now)])
        try c.execute("""
            DELETE FROM annotation_versions WHERE file_id=? AND id NOT IN (
                SELECT id FROM annotation_versions WHERE file_id=? ORDER BY version DESC LIMIT \(keptVersions))
            """, [id, id])
        return version
    }

    /// `_version_due`: keine Version bisher, die letzte mindestens `versionEvery` Sekunden alt oder die Uhr zurueckgestellt.
    /// Wie Python rechnet der Abstand mit der Ortszeit ohne Zone (`datetime.fromisoformat`).
    static func versionDue(_ c: SQLiteConnection, fileID: String, now: String) throws -> Bool {
        guard let last = try c.scalar("SELECT created_at FROM annotation_versions WHERE file_id=? ORDER BY version DESC LIMIT 1",
                                      [.text(fileID)])?.string, !last.isEmpty,
              let a = naiveSeconds(last), let b = naiveSeconds(now) else { return true }
        let elapsed = b - a
        return elapsed >= versionEvery || elapsed < 0
    }

    /// "YYYY-MM-DDTHH:MM:SS" (auch ohne Sekunden, mit Leerzeichen statt "T") als Sekunden ohne Zone
    static func naiveSeconds(_ s: String) -> Int? {
        let u = Array(s.utf8)
        func num(_ r: Range<Int>) -> Int? {
            guard r.upperBound <= u.count, r.allSatisfy({ (0x30...0x39).contains(u[$0]) }) else { return nil }
            return r.reduce(0) { $0 * 10 + Int(u[$1] - 0x30) }
        }
        guard u.count >= 16, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54 || u[10] == 0x20, u[13] == 0x3A,
              let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10), let h = num(11..<13), let mi = num(14..<16),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60 else { return nil }
        var sec = 0
        if u.count > 16 {
            guard u.count == 19, u[16] == 0x3A, let x = num(17..<19), x < 60 else { return nil }
            sec = x
        }
        // Tage seit 1970-01-01 (proleptischer gregorianischer Kalender)
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return days * 86_400 + h * 3600 + mi * 60 + sec
    }

    /// `put_annotations(file_id, body, base_version)`: Versionspruefung und Schreiben in einer Transaktion
    static func save(fileID: String, body: PyJSON, baseVersion: Int?, snapshot: Bool = false, _ ctx: LocalContext) async throws -> LocalResponse {
        let payload = body.dumps(ensureASCII: false)
        let now = ctx.clock.nowISO
        let id = SQLiteValue.text(fileID)
        enum Outcome: Sendable { case saved(Int), conflict(Int, String), unknownFile }
        let outcome = try await ctx.database.transaction { c -> Outcome in
            // nur die Version lesen; den gespeicherten Text (bei dichten Dokumenten zig MB) nur bei einem Konflikt
            let cur = try c.queryOne("SELECT version FROM annotations WHERE file_id=?", [id])
            let curV = cur.map { version($0["version"]) } ?? 0
            if let baseVersion, cur != nil, curV != baseVersion {
                return .conflict(curV, try c.scalar("SELECT data FROM annotations WHERE file_id=?", [id])?.string ?? "null")
            }
            guard try c.queryOne("SELECT 1 FROM files WHERE id=?", [id]) != nil else { return .unknownFile }
            // snapshot: auch der ersetzte Stand kommt in den Verlauf (nur hier wird der gespeicherte Text gelesen)
            if snapshot, cur != nil,
               try c.queryOne("SELECT 1 FROM annotation_versions WHERE file_id=? AND version=?", [id, .integer(Int64(curV))]) == nil,
               let old = try c.queryOne("SELECT data, updated_at FROM annotations WHERE file_id=?", [id]),
               old["data"]?.string != payload {
                let at = old["updated_at"].flatMap { LocalModules.truthy($0) ? $0 : nil } ?? .text(now)
                try c.execute("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES (?,?,?,?)",
                              [id, .integer(Int64(curV)), old["data"] ?? .null, at])
            }
            let v = try write(c, fileID: fileID, payload: payload, version: curV + 1, now: now, snapshot: snapshot)
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
