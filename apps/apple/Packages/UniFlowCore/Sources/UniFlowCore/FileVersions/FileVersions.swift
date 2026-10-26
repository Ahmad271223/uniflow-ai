import Foundation

/// Alte Original-Fassungen von Dateien mit Notizen (S7; Entwurf in docs/IPAD-OHNE-PC.md, Abschnitt 2 – in app/*.py
/// gibt es dafuer keine Regel: am PC ueberschreibt eine neue Fassung die Datei, die Notizen bleiben an den alten
/// Seitenzahlen).
///
/// Tabelle `file_versions`, nur auf dem Geraet und erst bei Bedarf angelegt (wie `studip_cycle_dates`): je alte
/// Fassung einer Datei ihre Kennzeichen (Name, Groesse, Aenderungszeit, Inhalts-Hash), die aufbewahrte PDF (Pfad
/// relativ zum Container der Hochschule, `StudIP/Fassungen` bzw. `Learnweb/Fassungen`; nie geloescht), die Notizen zum
/// Zeitpunkt der neuen Fassung (Text wie `annotations.data`) und die Seitenzuordnung (`PageMatch`) mit den zu
/// pruefenden Seiten.
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
    /// geaendert, gleicher Text mehrfach oder nur nach Position zugeordnet; alte und neue Seite, Art), die Seiten mit
    /// Notizen, die es nur noch in der alten Fassung gibt, und die neuen Seiten
    static func mapping(_ match: PageMatch.Result, notes: Set<Int>) -> JSONValue {
        let check = match.pairs.filter { $0.kind != .same && notes.contains($0.old) }
        return .object([
            "pages": .array(match.pairs.map { .object(["old": .number(Double($0.old)), "new": .number(Double($0.new)),
                                                      "kind": .string($0.kind.rawValue), "ratio": .number(QISParser.round2($0.ratio))]) }),
            "check": .array(check.map { .object(["old": .number(Double($0.old)), "new": .number(Double($0.new)), "kind": .string($0.kind.rawValue)]) }),
            "removed": .array(match.removed.filter(notes.contains).map { .number(Double($0)) }),
            "added": .array(match.added.map { .number(Double($0)) }),
        ])
    }

    /// Spaete Notizen auf entfernten Seiten (nach `PUT …/annotations`, in derselben Transaktion): Kam die neue Fassung,
    /// waehrend das Dokument offen war, schickt der Editor noch Striche auf Seiten der alten Fassung, die es in der neuen
    /// nicht mehr gibt (Zusammenfuehren nach 409 behaelt die Seite, sie steht aber nicht mehr in `pageOrder`). Solche
    /// Seiten mit Objekten kommen in den Abzug der neuesten alten Fassung, die die Seite kennt, und stehen dort unter
    /// "Nur in der alten Fassung" (Hinweis wieder ungesehen). Geprueft nur, solange ein Hinweis ungesehen ist.
    static func keepLateNotes(_ c: SQLiteConnection, fileID: String, payload: String) throws {
        guard try hasTable(c),
              try c.queryOne("SELECT 1 FROM file_versions WHERE file_id=? AND seen=0", [.text(fileID)]) != nil,
              let root = try? JSONValue.parse(payload) else { return }
        let doc = AnnotationDocument(root: root)
        var placed = Set(doc.pageOrder.compactMap { $0["key"]?.string })
        for d in doc.root["deletedPages"]?.array ?? [] { if let k = d["entry"]?["key"]?.string { placed.insert(k) } }
        let late = doc.pages.filter { !placed.contains($0.key) && !($0.value["objects"]?.array ?? []).isEmpty }
        guard !late.isEmpty else { return }
        var open = late
        for r in try c.query("SELECT version, annotations, mapping FROM file_versions WHERE file_id=? ORDER BY version DESC", [.text(fileID)]) {
            guard !open.isEmpty, let text = r["annotations"]?.string, let oldRoot = try? JSONValue.parse(text) else { continue }
            var old = AnnotationDocument(root: oldRoot)
            var mapping = (try? JSONValue.parse(r["mapping"]?.string ?? "")) ?? .object([:])
            var removed = Set((mapping["removed"]?.array ?? []).compactMap(\.int))
            var changed = false
            for (key, page) in open {
                guard let entry = old.pageOrder.first(where: { $0["key"]?.string == key }) else { continue }
                open.removeValue(forKey: key)
                guard old.page(key) != page else { continue }
                old.pages[key] = page
                if (entry["type"]?.string ?? "pdf") == "pdf", let i = entry["index"]?.int { removed.insert(i) }
                changed = true
            }
            guard changed else { continue }
            mapping["removed"] = .array(removed.sorted().map { .number(Double($0)) })
            let payload = try PyJSON.parse(old.root.serialized()).dumps(ensureASCII: false)
            try c.execute("UPDATE file_versions SET annotations=?, mapping=?, seen=0 WHERE file_id=? AND version=?",
                          [.text(payload), .text(mapping.jsonString()), .text(fileID), r["version"] ?? .null])
        }
    }
}

/// Neue Original-Fassung einer Datei mit Notizen uebernehmen, fuer beide Abgleiche (Stud.IP in der App, Learnweb in
/// `HildesheimSync`), aufgerufen nur aus dem einen Download-Ablauf `UniDownloads.load`. Zwei Schritte um das Ersetzen
/// der Datei herum, keiner mit Netz oder `await` in einer Transaktion:
/// 1. `prepare` (die neue Fassung liegt geladen bereit, die alte noch an ihrem Platz): Seitentexte der neuen Fassung
///    aus der geladenen Datei lesen (PDFKit). Hat die Datei Notizen und ist der Inhalt wirklich neu (anderer
///    `content_sha256`), wird die alte PDF in `directory` kopiert (auf APFS ein Klon) und ihr Seitentext gelesen
///    (gespeichert in `page_texts` oder mit PDFKit); dann die Seiten zuordnen (`PageMatch`, einmal fuer die Datei und
///    alle Kopien). Scheitert das Sichern, darf die Datei nicht ersetzt werden (Fehler; der naechste Abgleich versucht
///    es erneut).
/// 2. `commit` (nach dem Ersetzen der Datei) in EINER Transaktion: `UniStore.markDownloaded` (vom Aufrufer), die
///    Seitentexte der neuen Fassung (Index der Suche, fuer jede geladene PDF), die alte Fassung mit dem Stand der
///    Notizen in `file_versions` und die umgehaengten Notizen (`NoteTransfer`, neue Version mit Verlauf). Endet die App
///    zwischen Ersetzen und `commit` oder scheitert `commit`, bleibt die Datenbank beim alten Stand: der naechste
///    Abgleich laedt die Datei erneut und nimmt die schon aufbewahrte alte PDF.
/// Ohne Notizen wird ersetzt wie bisher; eine automatisch angelegte Seitenliste ohne Notizen wird dabei geleert, damit
/// der Editor sie fuer die neue Seitenzahl neu anlegt (sonst fehlten neue Seiten). Kopien der Datei ("Duplizieren",
/// `UniStore.sharingCopies`) teilen sich ihre PDF und bekommen die neue Fassung mit: auch ihre Notizen werden
/// umgehaengt, jede mit eigener alter Fassung (dieselbe aufbewahrte PDF), ihre Seitentexte gelten nicht mehr.
public struct FileVersionKeeper: Sendable {
    public let database: SQLiteDatabase
    /// Ablage, in der die Pfade der Datenbank liegen (Container der Hochschule, `UniDownloads.files`), mit PDFKit
    public let files: LocalFiles
    /// Ordner fuer alte Fassungen relativ zu `files.container` (ohne iCloud-Backup, Entscheidung 6)
    public let directory: String
    /// Herkunft fuer den Hinweis im Dokument ("Stud.IP", "Learnweb")
    public let source: String
    public let clock: UniFlowClock
    /// Inhalts-Hash einer Datei (`content_sha256` wie `ContentHash.file`)
    public let hasher: @Sendable (URL) -> String?

    public init(database: SQLiteDatabase, files: LocalFiles, directory: String, source: String, clock: UniFlowClock = .system,
                hasher: @escaping @Sendable (URL) -> String? = { ContentHash.file($0) }) {
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
        /// Plan fuer die Datei selbst (Stand von `prepare`; `commit` prueft die Notizen erneut)
        public let plan: Plan
        /// Kopien der Datei ("Duplizieren"), die sich ihre PDF teilen und mit ihr die neue Fassung bekommen, je mit
        /// eigenem Plan fuer ihre eigenen Notizen
        public let copies: [Copy]
        /// Seitentexte der neuen Fassung (aus der geladenen Datei), nil ohne PDF oder wenn sie sich nicht lesen laesst
        public let newTexts: [String]?
        /// Inhalt anders als die gespeicherte Fassung (oder unbekannt)
        let changed: Bool
        /// aufbewahrte alte Fassung, nil ohne Notizen
        let kept: Kept?
        /// Seitenzuordnung ueber den Text, vor dem Ersetzen gerechnet; nil, wenn eine Fassung keine Texte hat
        let textMatch: PageMatch.Result?
    }

    public struct Copy: Sendable, Equatable {
        public let fileID: String
        public let plan: Plan
    }

    /// Ergebnis von `commit` mit alter Fassung
    public struct Outcome: Sendable, Equatable {
        public let version: Int
        /// Seiten mit Notizen zu pruefen (Text geaendert, mehrfach vorhanden oder nach Position) bzw. nur noch in der
        /// alten Fassung
        public let check: Int
        public let removed: Int
    }

    /// Schritt 1, vor dem Ersetzen der Datei. `newSHA`: Inhalts-Hash der geladenen neuen Fassung, `newFile`: wo sie
    /// liegt, `newPath`: ihr kuenftiger Ablageort (Pfad wie `local_path`, entscheidet ueber "PDF").
    public func prepare(fileID: String, newSHA: String?, newFile: URL? = nil, newPath: String? = nil) async throws -> Prepared {
        let id = SQLiteValue.text(fileID)
        let newTexts = newFile.flatMap { url in newPath.flatMap { ScriptSearch.hasPDFSuffix($0) ? files.tools.pdfPageTexts(url) : nil } }
        // die Datei und ihre Kopien, die dieselbe PDF benutzen, je mit ihren Notizen
        let (file, notes) = try await database.withConnection { c -> (SQLiteRow?, [(id: String, data: String?)]) in
            guard let f = try c.queryOne("SELECT local_path, content_sha256, chdate, size, mime, name FROM files WHERE id=?", [id]) else { return (nil, []) }
            let ids = [fileID] + (try UniStore.sharingCopies(c, fileID: fileID))
            return (f, try ids.map { ($0, try c.scalar("SELECT data FROM annotations WHERE file_id=?", [.text($0)])?.string) })
        }
        let docs = notes.map { n in (id: n.id, doc: Self.document(n.data)) }
        let oldPath = file?["local_path"]?.string ?? ""
        let oldURL = files.exists(stored: oldPath) ? files.url(stored: oldPath) : nil
        var oldSHA = file?["content_sha256"]?.string
        if oldSHA == nil, let oldURL { oldSHA = hasher(oldURL) }
        let changed = !(oldSHA != nil && newSHA != nil && oldSHA == newSHA)
        var kept: Kept?
        if let file, changed, docs.contains(where: { $0.doc.map(NoteTransfer.hasNotes) ?? false }) {
            kept = try await keepOldFile(fileID: fileID, file: file, oldPath: oldPath, oldURL: oldURL, sha: oldSHA)
        }
        var textMatch: PageMatch.Result?
        if let old = kept?.pageTexts, !old.isEmpty, let new = newTexts, !new.isEmpty { textMatch = PageMatch.match(old: old, new: new) }
        let plans = docs.map { Copy(fileID: $0.id, plan: Self.plan($0.doc, kept: kept, changed: changed)) }
        return Prepared(fileID: fileID, plan: plans.first?.plan ?? .none, copies: Array(plans.dropFirst()), newTexts: newTexts,
                        changed: changed, kept: kept, textMatch: textMatch)
    }

    private static func document(_ data: String?) -> AnnotationDocument? {
        data.flatMap { try? JSONValue.parse($0) }.map(AnnotationDocument.init(root:))
    }

    /// Plan fuer ein Dokument: ohne Notizen-Zeile oder bei gleichem Inhalt nichts; mit Notizen umhaengen (wenn die alte
    /// Fassung aufbewahrt ist; Notizen, die erst nach `prepare` entstanden, ohne aufbewahrte Fassung bleiben, wie sie
    /// sind), sonst die automatische Seitenliste neu anlegen lassen
    private static func plan(_ doc: AnnotationDocument?, kept: Kept?, changed: Bool) -> Plan {
        guard let doc, changed else { return .none }
        guard NoteTransfer.hasNotes(doc) else { return .resetPageList }
        return kept.map(Plan.keep) ?? .none
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
            // schon aufbewahrt (z. B. ein Abgleich endete zwischen Ersetzen und `commit`): die Kopie gilt, die Datei am
            // alten Platz kann dann schon die neue Fassung sein
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

    /// Schritt 2, nach dem Ersetzen der Datei, alles in einer Transaktion: `download` (der Aufrufer schreibt darin
    /// `UniStore.markDownloaded`), Seitentexte der neuen Fassung, alte Fassungen und umgehaengte Notizen der Datei und
    /// ihrer Kopien. Ein Fehler laesst alles beim alten Stand (der naechste Abgleich laedt erneut). Die Notizen werden
    /// hier noch einmal gelesen (inzwischen Geschriebenes zaehlt mit); Rueckgabe nur, wenn fuer die Datei selbst eine
    /// alte Fassung angelegt wurde.
    @discardableResult
    public func commit(_ p: Prepared, download: @escaping @Sendable (SQLiteConnection) throws -> Void) async throws -> Outcome? {
        let now = clock.nowISO, source = self.source, fileID = p.fileID
        return try await database.transaction { c -> Outcome? in
            try download(c)
            // Kopien, die sich die PDF teilen (seit `markDownloaded` am neuen Ablageort), und die aus `prepare`
            let copies = Set(p.copies.map(\.fileID)).union(try UniStore.sharingCopies(c, fileID: fileID)).sorted()
            // Seitentexte: die der Datei gehoeren zur alten Fassung (auch bei gleicher Aenderungszeit), die der Kopien
            // ebenso (ihre Aenderungszeit bleibt die vom Duplizieren); die neuen gleich mit der neuen Aenderungszeit
            for id in [fileID] + copies { try c.execute("DELETE FROM page_texts WHERE file_id=?", [.text(id)]) }
            if let texts = p.newTexts, let chdate = try c.queryOne("SELECT chdate FROM files WHERE id=?", [.text(fileID)])?["chdate"] {
                try ScriptSearch.storePages(c, fileID: fileID, pages: texts, chdate: chdate)
            }
            var outcome: Outcome?
            for target in [fileID] + copies {
                let data = try c.scalar("SELECT data FROM annotations WHERE file_id=?", [.text(target)])?.string
                guard let data, let doc = Self.document(data) else { continue }
                switch Self.plan(doc, kept: p.kept, changed: p.changed) {
                case .none:
                    continue
                case .resetPageList:
                    guard !doc.pageOrder.isEmpty else { continue }
                    var reset = doc
                    reset.root["pageOrder"] = .array([])
                    reset.pages = [:]
                    try Self.save(c, fileID: target, reset, now: now)
                case .keep(let k):
                    let oldCount = k.pageTexts?.count ?? NoteTransfer.highestPDFIndex(doc)
                    let newCount = p.newTexts.map { $0.isEmpty ? oldCount : $0.count } ?? oldCount
                    let match = p.textMatch ?? PageMatch.byPosition(oldCount: oldCount, newCount: newCount)
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
                    if target == fileID {
                        outcome = Outcome(version: version, check: mapping["check"]?.array?.count ?? 0,
                                          removed: mapping["removed"]?.array?.count ?? 0)
                    }
                }
            }
            return outcome
        }
    }

    /// Neuen Stand der Notizen wie `PUT /api/files/{id}/annotations` schreiben (Text wie `json.dumps`)
    private static func save(_ c: SQLiteConnection, fileID: String, _ doc: AnnotationDocument, now: String) throws {
        let cur = try c.queryOne("SELECT version FROM annotations WHERE file_id=?", [.text(fileID)]).map { AnnotationEndpoints.version($0["version"]) } ?? 0
        let payload = try PyJSON.parse(doc.root.serialized()).dumps(ensureASCII: false)
        try AnnotationEndpoints.write(c, fileID: fileID, payload: payload, version: cur + 1, now: now)
    }
}
