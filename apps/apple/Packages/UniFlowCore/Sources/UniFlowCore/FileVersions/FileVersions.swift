import Foundation

/// Alte Original-Fassungen von Dateien mit Notizen (S7; Entwurf in docs/IPAD-OHNE-PC.md, Abschnitt 2 – in app/*.py
/// gibt es dafuer keine Regel: am PC ueberschreibt eine neue Fassung die Datei, die Notizen bleiben an den alten
/// Seitenzahlen).
///
/// Tabelle `file_versions`, nur auf dem Geraet und erst bei Bedarf angelegt (wie `studip_cycle_dates`): je alte
/// Fassung einer Datei ihre Kennzeichen (Name, Groesse, Aenderungszeit, Inhalts-Hash), die aufbewahrte PDF (Pfad
/// relativ zum App-Container; nie geloescht), die Notizen zum Zeitpunkt der neuen Fassung (Text wie
/// `annotations.data`) und die Seitenzuordnung (`PageMatch`) mit den zu pruefenden Seiten.
public enum FileVersions {
    static let tableSQL = """
        CREATE TABLE IF NOT EXISTS file_versions (
            file_id TEXT NOT NULL,
            version INTEGER NOT NULL,
            name TEXT,
            size INTEGER,
            mime TEXT,
            chdate INTEGER,
            content_sha256 TEXT,
            local_path TEXT,
            page_count INTEGER,
            annotations TEXT,
            mapping TEXT,
            source TEXT,
            replaced_at TEXT,
            seen INTEGER DEFAULT 0,
            PRIMARY KEY (file_id, version))
        """

    static func ensureTable(_ c: SQLiteConnection) throws { try c.executeScript(tableSQL) }

    static func hasTable(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='file_versions'") != nil
    }

    /// Kennung einer alten Fassung im Editor: die Pfade des Editors (`/api/files/{id}/content`, `/annotations`)
    /// treffen damit die Endpunkte der alten Fassung (`FileVersionEndpoints`); Journal und PDF-Zwischenspeicher
    /// liegen getrennt von denen der Datei
    public static func documentID(fileID: String, version: Int) -> String { "\(fileID)/versions/\(version)" }

    /// Alte Fassungen einer Datei, neueste zuerst, im Format von `GET /api/files/{id}/versions`
    static func list(_ c: SQLiteConnection, fileID: String, files: LocalFiles?) throws -> [JSONValue] {
        guard try hasTable(c) else { return [] }
        return try c.query("SELECT * FROM file_versions WHERE file_id=? ORDER BY version DESC", [.text(fileID)]).map { r in
            var o: [String: JSONValue] = [:]
            for k in ["version", "name", "size", "chdate", "content_sha256", "page_count", "source", "replaced_at"] { o[k] = r[k]?.json ?? .null }
            o["seen"] = .bool(LocalModules.truthy(r["seen"]))
            o["available"] = .bool(files?.exists(stored: r["local_path"]?.string) ?? false)
            o["document_id"] = .string(documentID(fileID: fileID, version: r["version"]?.int ?? 0))
            let mapping = (try? JSONValue.parse(r["mapping"]?.string ?? "")) ?? .object([:])
            for k in ["check", "removed", "added", "pages"] { o[k] = mapping[k] ?? .array([]) }
            return .object(o)
        }
    }

    /// Eine alte Fassung (Zeile), nil wenn es sie nicht gibt
    static func row(_ c: SQLiteConnection, fileID: String, version: Int) throws -> SQLiteRow? {
        guard try hasTable(c) else { return nil }
        return try c.queryOne("SELECT * FROM file_versions WHERE file_id=? AND version=?", [.text(fileID), .integer(Int64(version))])
    }

    /// Zuordnung als JSON fuer `file_versions.mapping`: alle Paare, die zu pruefenden Seiten mit Notizen (Text
    /// geaendert oder nur nach Position zugeordnet; alte und neue Seite), die Seiten mit Notizen, die es nur noch in der
    /// alten Fassung gibt, und die neuen Seiten
    static func mapping(_ match: PageMatch.Result, notes: Set<Int>) -> JSONValue {
        let check = match.pairs.filter { $0.kind != .same && notes.contains($0.old) }
        return .object([
            "pages": .array(match.pairs.map { .object(["old": .number(Double($0.old)), "new": .number(Double($0.new)),
                                                      "kind": .string($0.kind.rawValue), "ratio": .number(QISParser.round2($0.ratio))]) }),
            "check": .array(check.map { .object(["old": .number(Double($0.old)), "new": .number(Double($0.new))]) }),
            "removed": .array(match.removed.filter(notes.contains).map { .number(Double($0)) }),
            "added": .array(match.added.map { .number(Double($0)) }),
        ])
    }
}

/// Neue Original-Fassung einer Datei mit Notizen uebernehmen, fuer beide Abgleiche (Stud.IP in der App, Learnweb in
/// `HildesheimSync`). Zwei Schritte um das Ersetzen der Datei herum, keiner mit Netz oder `await` in einer
/// Transaktion:
/// 1. `prepare` (die neue Fassung liegt geladen bereit, die alte noch an ihrem Platz): Hat die Datei Notizen und ist
///    der Inhalt wirklich neu (anderer `content_sha256`), wird die alte PDF in `directory` kopiert (auf APFS ein Klon)
///    und ihr Seitentext gelesen (gespeichert in `page_texts` oder mit PDFKit). Scheitert das Sichern, darf die Datei
///    nicht ersetzt werden (Fehler; der naechste Abgleich versucht es erneut).
/// 2. `finish` (nach `UniStore.markDownloaded`): Seitentexte der neuen Fassung lesen und speichern (Index der Suche,
///    fuer jede geladene PDF), Seiten zuordnen (`PageMatch`), die alte Fassung mit dem Stand der Notizen in
///    `file_versions` ablegen und die Notizen umhaengen (`NoteTransfer`, neue Version der Notizen mit Verlauf).
/// Ohne Notizen wird ersetzt wie bisher; eine automatisch angelegte Seitenliste ohne Notizen wird dabei geleert, damit
/// der Editor sie fuer die neue Seitenzahl neu anlegt (sonst fehlten neue Seiten). Kopien der Datei ("Duplizieren")
/// teilen sich ihre PDF und bekommen die neue Fassung mit: auch ihre Notizen werden umgehaengt, jede mit eigener alter
/// Fassung (dieselbe aufbewahrte PDF).
public struct FileVersionKeeper: Sendable {
    public let database: SQLiteDatabase
    /// Ablage, in der die Pfade der Datenbank liegen (App-Container; Learnweb: Ordner der Hochschule), mit PDFKit
    public let files: LocalFiles
    /// Ordner fuer alte Fassungen relativ zu `files.container` (ohne iCloud-Backup, Entscheidung 6)
    public let directory: String
    /// Herkunft fuer den Hinweis im Dokument ("Stud.IP", "Learnweb")
    public let source: String
    public let clock: UniFlowClock
    /// Inhalts-Hash einer Datei (`content_sha256` wie `TestShare.contentHash(file:)`)
    public let hasher: @Sendable (URL) -> String?

    public init(database: SQLiteDatabase, files: LocalFiles, directory: String, source: String, clock: UniFlowClock = .system,
                hasher: @escaping @Sendable (URL) -> String? = { TestShare.contentHash(file: $0) }) {
        self.database = database
        self.files = files
        self.directory = directory
        self.source = source
        self.clock = clock
        self.hasher = hasher
    }

    /// Was nach dem Ersetzen zu tun ist
    public enum Plan: Sendable, Equatable {
        /// nichts (keine Notizen gespeichert, gleicher Inhalt)
        case none
        /// Notizen ohne Inhalt: Seitenliste fuer die neue Seitenzahl neu anlegen lassen
        case resetPageList
        /// alte Fassung aufbewahren und Notizen umhaengen
        case keep(Kept)
    }

    public struct Kept: Sendable, Equatable {
        public let name: String?
        public let size: Int?
        public let mime: String?
        public let chdate: Int?
        public let sha256: String?
        /// aufbewahrte PDF (relativ zum Container), nil wenn die alte Datei schon fehlte
        public let keptPath: String?
        /// Seitentexte der alten Fassung, nil wenn nicht lesbar
        public let pageTexts: [String]?
    }

    public struct Prepared: Sendable, Equatable {
        public let fileID: String
        public let plan: Plan
        /// Kopien der Datei ("Duplizieren"), die sich ihre PDF teilen und mit ihr die neue Fassung bekommen, je mit
        /// eigenem Plan fuer ihre eigenen Notizen
        public let copies: [Copy]

        public init(fileID: String, plan: Plan, copies: [Copy] = []) {
            self.fileID = fileID
            self.plan = plan
            self.copies = copies
        }
    }

    public struct Copy: Sendable, Equatable {
        public let fileID: String
        public let plan: Plan
    }

    /// Ergebnis von `finish` mit alter Fassung
    public struct Outcome: Sendable, Equatable {
        public let version: Int
        /// Seiten mit Notizen zu pruefen (Text geaendert oder nach Position) bzw. nur noch in der alten Fassung
        public let check: Int
        public let removed: Int
    }

    /// Schritt 1, vor dem Ersetzen der Datei. `newSHA`: Inhalts-Hash der geladenen neuen Fassung.
    public func prepare(fileID: String, newSHA: String?) async throws -> Prepared {
        let id = SQLiteValue.text(fileID)
        // die Datei und ihre Kopien, die dieselbe PDF benutzen, je mit ihren Notizen
        let (file, notes) = try await database.withConnection { c -> (SQLiteRow?, [(id: String, data: String?)]) in
            guard let f = try c.queryOne("SELECT local_path, content_sha256, chdate, size, mime, name FROM files WHERE id=?", [id]) else { return (nil, []) }
            var ids = [fileID]
            if let path = f["local_path"]?.string, !path.isEmpty {
                ids += try c.query("SELECT id FROM files WHERE local_path=? AND id<>? ORDER BY id", [.text(path), id]).compactMap { $0["id"]?.string }
            }
            return (f, try ids.map { ($0, try c.scalar("SELECT data FROM annotations WHERE file_id=?", [.text($0)])?.string) })
        }
        let docs = notes.map { n in (id: n.id, doc: n.data.flatMap { try? JSONValue.parse($0) }.map(AnnotationDocument.init(root:))) }
        guard let file, docs.contains(where: { $0.doc != nil }) else { return Prepared(fileID: fileID, plan: .none) }
        let oldPath = file["local_path"]?.string ?? ""
        let oldURL = files.exists(stored: oldPath) ? files.url(stored: oldPath) : nil
        var oldSHA = file["content_sha256"]?.string
        if oldSHA == nil, let oldURL { oldSHA = hasher(oldURL) }
        if let oldSHA, let newSHA, oldSHA == newSHA { return Prepared(fileID: fileID, plan: .none) }

        var kept: Kept?
        if docs.contains(where: { $0.doc.map(NoteTransfer.hasNotes) ?? false }) {
            kept = try await keepOldFile(fileID: fileID, file: file, oldPath: oldPath, oldURL: oldURL, sha: oldSHA)
        }
        func plan(_ doc: AnnotationDocument?) -> Plan {
            guard let doc else { return .none }
            guard NoteTransfer.hasNotes(doc), let kept else { return .resetPageList }
            return .keep(kept)
        }
        return Prepared(fileID: fileID, plan: plan(docs[0].doc), copies: docs.dropFirst().map { Copy(fileID: $0.id, plan: plan($0.doc)) })
    }

    /// Alte PDF in `directory` sichern (einmal je Inhalt) und ihre Seitentexte lesen
    private func keepOldFile(fileID: String, file: SQLiteRow, oldPath: String, oldURL: URL?, sha oldSHA: String?) async throws -> Kept {
        var kept: String?
        var texts: [String]?
        let chdate = file["chdate"] ?? .null
        if let oldURL {
            let stored = directory + "/" + StudIPImport.safeFileName(fileID) + "/"
                + (oldSHA ?? "chdate-\(chdate.int64 ?? 0)") + (ScriptSearch.hasPDFSuffix(oldPath) ? ".pdf" : "")
            guard let target = files.url(stored: stored) else { throw LocalHTTPError(status: 400, message: "Ungültiger Pfad") }
            let fm = FileManager.default
            if !fm.fileExists(atPath: target.path) {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: oldURL, to: target)                     // APFS: Klon, kein zweiter Speicherplatz
            }
            kept = stored
            // Seitentexte: gespeichert und so alt wie die alte Fassung, sonst aus der aufbewahrten Kopie
            if case .fresh(let pages)? = try? await database.withConnection({ try ScriptSearch.storedPages($0, fileID: fileID, files: files) }) {
                texts = pages
            } else if ScriptSearch.hasPDFSuffix(oldPath) {
                texts = files.tools.pdfPageTexts(target)
            }
        } else {
            // alte Datei fehlt (z. B. nach "Dateien löschen"): nur noch gespeicherte Seitentexte derselben Fassung
            let stamp: SQLiteValue = LocalModules.truthy(chdate) ? chdate : .integer(0)
            let rows = try await database.withConnection {
                try $0.query("SELECT text FROM page_texts WHERE file_id=? AND COALESCE(chdate, 0)=? ORDER BY page", [.text(fileID), stamp])
            }
            texts = rows.isEmpty ? nil : rows.map { $0["text"]?.string ?? "" }
        }
        return Kept(name: file["name"]?.string, size: file["size"]?.int, mime: file["mime"]?.string, chdate: chdate.int,
                    sha256: oldSHA, keptPath: kept, pageTexts: texts)
    }

    /// Schritt 2, nach `UniStore.markDownloaded`. Fehler beim Schreiben lassen die Notizen, wie sie sind (die alte PDF
    /// ist dann schon aufbewahrt); Rueckgabe nur, wenn fuer die Datei selbst eine alte Fassung angelegt wurde.
    @discardableResult
    public func finish(_ p: Prepared) async -> Outcome? {
        let now = clock.nowISO, source = self.source, fileID = p.fileID
        let all = [Copy(fileID: p.fileID, plan: p.plan)] + p.copies
        // Kopien, die sich die PDF teilen, haben jetzt ebenfalls die neue Fassung: Ladezeitpunkt mit, damit der Editor
        // seinen PDF-Zwischenspeicher auch fuer sie erneuert
        _ = try? await database.transaction { c in
            try c.execute("""
                UPDATE files SET downloaded_at=(SELECT downloaded_at FROM files WHERE id=?)
                WHERE id<>? AND COALESCE(local_path, '')<>'' AND local_path=(SELECT local_path FROM files WHERE id=?)
                """, [.text(fileID), .text(fileID), .text(fileID)])
        }
        if all.contains(where: { $0.plan != .none }) {
            // anderer Inhalt: gespeicherte Seitentexte gehoeren zur alten Fassung, auch bei gleicher Aenderungszeit
            let ids = all.map { SQLiteValue.text($0.fileID) }
            _ = try? await database.transaction { c in for id in ids { try c.execute("DELETE FROM page_texts WHERE file_id=?", [id]) } }
        }
        let newTexts = (try? await ScriptSearch.pageTexts(fileID: fileID, database: database, files: files)) ?? []
        var outcome: Outcome?
        for item in all {
            let target = item.fileID
            switch item.plan {
            case .none:
                continue
            case .resetPageList:
                _ = try? await database.transaction { c in
                    guard let data = try c.scalar("SELECT data FROM annotations WHERE file_id=?", [.text(target)])?.string,
                          let root = try? JSONValue.parse(data) else { return }
                    var doc = AnnotationDocument(root: root)
                    guard !NoteTransfer.hasNotes(doc), !doc.pageOrder.isEmpty else { return }
                    doc.root["pageOrder"] = .array([])
                    doc.pages = [:]
                    try Self.save(c, fileID: target, doc, now: now)
                }
            case .keep(let k):
                let o = try? await database.transaction { c -> Outcome? in
                    guard let data = try c.scalar("SELECT data FROM annotations WHERE file_id=?", [.text(target)])?.string,
                          let root = try? JSONValue.parse(data) else { return nil }
                    let doc = AnnotationDocument(root: root)
                    guard NoteTransfer.hasNotes(doc) else { return nil }
                    let oldCount = k.pageTexts?.count ?? NoteTransfer.highestPDFIndex(doc)
                    let newCount = newTexts.isEmpty ? oldCount : newTexts.count
                    let match: PageMatch.Result
                    if let old = k.pageTexts, !old.isEmpty, !newTexts.isEmpty { match = PageMatch.match(old: old, new: newTexts) }
                    else { match = PageMatch.byPosition(oldCount: oldCount, newCount: newCount) }
                    try FileVersions.ensureTable(c)
                    let version = (try c.scalar("SELECT MAX(version) FROM file_versions WHERE file_id=?", [.text(target)])?.int ?? 0) + 1
                    let mapping = FileVersions.mapping(match, notes: NoteTransfer.pagesWithNotes(doc))
                    let sha = try c.scalar("SELECT content_sha256 FROM files WHERE id=?", [.text(fileID)])?.string
                    let moved = NoteTransfer.transfer(doc, match: match, version: version + 1, sha256: sha)
                    try c.execute("""
                        INSERT INTO file_versions(file_id, version, name, size, mime, chdate, content_sha256, local_path, page_count,
                                                  annotations, mapping, source, replaced_at, seen)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0)
                        """, [.text(target), .integer(Int64(version)), SQLiteValue(k.name), SQLiteValue(k.size.map(Int64.init)),
                              SQLiteValue(k.mime), SQLiteValue(k.chdate.map(Int64.init)), SQLiteValue(k.sha256), SQLiteValue(k.keptPath),
                              .integer(Int64(oldCount)), .text(data), .text(mapping.jsonString()), .text(source), .text(now)])
                    try Self.save(c, fileID: target, moved.document, now: now)
                    return Outcome(version: version, check: mapping["check"]?.array?.count ?? 0, removed: mapping["removed"]?.array?.count ?? 0)
                }
                if target == fileID { outcome = o ?? nil }
            }
        }
        return outcome
    }

    /// Neuen Stand der Notizen wie `PUT /api/files/{id}/annotations` schreiben (Text wie `json.dumps`)
    private static func save(_ c: SQLiteConnection, fileID: String, _ doc: AnnotationDocument, now: String) throws {
        let cur = try c.queryOne("SELECT version FROM annotations WHERE file_id=?", [.text(fileID)]).map { AnnotationEndpoints.version($0["version"]) } ?? 0
        let payload = try PyJSON.parse(doc.root.serialized()).dumps(ensureASCII: false)
        try AnnotationEndpoints.write(c, fileID: fileID, payload: payload, version: cur + 1, now: now)
    }
}
