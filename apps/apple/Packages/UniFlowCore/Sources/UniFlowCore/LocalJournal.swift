import Foundation

/// Lokaler Stand einer Seite mit Revision. Eine Seite ist ungesendet, solange `localRev` groesser ist als die vom
/// Server bestaetigte Revision (`acks.json`). Weil jede Seitendatei ihre Revision selbst traegt, bleibt das auch nach
/// einem Absturz zwischen zwei Dateien erkennbar.
public struct JournalPage: Equatable, Sendable {
    public var page: JSONValue
    public var localRev: Int

    public init(page: JSONValue, localRev: Int) {
        self.page = page
        self.localRev = localRev
    }
}

public struct JournalSnapshot: Equatable, Sendable {
    public var serverVersion: Int = 0
    public var rootMeta: JSONValue = AnnotationDocument.empty().rootMeta
    public var metaRev: Int = 0
    public var metaAckedRev: Int = 0
    public var baseRootMeta: JSONValue?
    public var pages: [String: JournalPage] = [:]
    public var acked: [String: Int] = [:]
    /// Basis (letzter bestaetigter Serverstand) fuer geaenderte Seiten; `.null` = Seite gab es dort nicht.
    public var bases: [String: JSONValue] = [:]
    /// Dateien, die nicht gelesen werden konnten (werden gemeldet, nie still verworfen).
    public var damaged: [String] = []
    /// Seiten, deren Datei nicht lesbar war (Schluessel aus dem Dateinamen): ihr lokaler Stand ist unbekannt, bis der
    /// Serverstand geholt ist (`SyncEngine`). Die Datei bleibt liegen, bis sie ersetzt wird; ihr Inhalt ist in
    /// `damaged/` aufbewahrt.
    public var damagedPageKeys: [String] = []
    /// meta.json fehlt neben vorhandenen Seiten oder war nicht lesbar: Wurzelfelder erst vom Server (`SyncEngine`)
    public var metaUnknown = false
    /// acks.json war nicht lesbar: Bestaetigungen aus den Basisdateien hergeleitet (`SyncEngine`)
    public var acksDamaged = false
}

/// Ablage im Ordner `spaces/<namensraum>/docs/<id>/` (ohne Namensraum wie vor S2 `docs/<id>/`, siehe
/// `DataSourceNamespace` und `JournalNamespaceMigration`):
/// - `meta.json`: Wurzelfelder ohne Seiten, `metaRev`, Basis der Wurzelfelder
/// - `acks.json`: Serverversion und bestaetigte Revisionen
/// - `pages/<key>.json`: Seite + `localRev`
/// - `base/<key>.json`: Basis einer geaenderten Seite
/// - `damaged/<datei>`: unveraenderte Kopie einer beim Lesen beschaedigten Datei (nur aufbewahrt, nie gelesen)
///
/// Dateinamen: Schluessel aus a-z, A-Z, 0-9, "_" und "-" (bis 100 Zeichen) unveraendert, sonst "~" + UTF-8-Bytes
/// hexadezimal (umkehrbar, bis 124 Bytes) bzw. "~~" + SHA-256 (laengere Schluessel; die Datei traegt ihren Schluessel
/// im Feld `key`). So bleibt jeder Name unter der Grenze von 255 Bytes der Dateisysteme.
public final class LocalJournal: @unchecked Sendable {
    private let store: BlobStore
    private let dir: String

    /// `namespace`: Datenquelle des Dokuments (lokal oder ein bestimmter Server); nil nur fuer den alten Ort.
    public init(store: BlobStore, documentID: String, namespace: DataSourceNamespace? = nil) {
        self.store = store
        self.dir = LocalJournal.directory(documentID: documentID, namespace: namespace)
    }

    /// Ordner aller Journale eines Namensraums im Speicher (`spaces/<id>/docs`), z. B. fuer die Diagnose
    public static func documentsDirectory(_ namespace: DataSourceNamespace?) -> String {
        (namespace.map { $0.journalPrefix + "/" } ?? "") + "docs"
    }

    /// Ordner des Journals eines Dokuments im Speicher (z. B. zum Entfernen nach "Endgültig löschen")
    public static func directory(documentID: String, namespace: DataSourceNamespace?) -> String {
        documentsDirectory(namespace) + "/" + safeName(documentID)
    }

    /// Dokument-ID zu einem Ordnernamen unter `documentsDirectory` (Umkehrung von `safeName`)
    public static func documentID(forDirectory name: String) -> String {
        unsafeName(name + ".json") ?? name
    }

    /// Laengster Schluessel (UTF-8-Bytes), der noch umkehrbar hexadezimal im Dateinamen steht: "~" + 2 je Byte +
    /// ".json" bleibt so unter 255 Bytes (vorher wurde jeder Schluessel so geschrieben; ab 125 Bytes scheiterte das
    /// Schreiben am Dateisystem, die Seite liess sich nie sichern)
    static let maxHexKeyBytes = 124

    static func safeName(_ s: String) -> String {
        let ok = !s.isEmpty && s.count <= 100 && s.unicodeScalars.allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "-"
        }
        if ok { return s }
        let bytes = Array(s.utf8)
        // "~" kommt in sicheren Namen nie vor; "~~" in hexadezimalen nie (dort folgen nur Ziffern und a-f)
        if bytes.count <= maxHexKeyBytes { return "~" + SolutionSHA256.hexString(bytes) }
        return "~~" + SolutionSHA256.hex(Data(bytes))
    }

    /// Schluessel zu einem Dateinamen; nil fuer fremde Dateien (ohne ".json") und fuer gekuerzte Namen ("~~", dort
    /// steht der Schluessel nur in der Datei)
    static func unsafeName(_ file: String) -> String? {
        guard file.hasSuffix(".json") else { return nil }
        let base = String(file.dropLast(5))
        if base.hasPrefix("~~") { return nil }
        guard base.hasPrefix("~"), base.count % 2 == 1 else { return base }
        var bytes: [UInt8] = []
        var i = base.index(after: base.startIndex)
        while i < base.endIndex {
            let j = base.index(i, offsetBy: 2)
            guard let b = UInt8(base[i..<j], radix: 16) else { return base }
            bytes.append(b)
            i = j
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func pagePath(_ key: String) -> String { "\(dir)/pages/\(LocalJournal.safeName(key)).json" }
    private func basePath(_ key: String) -> String { "\(dir)/base/\(LocalJournal.safeName(key)).json" }

    // MARK: Lesen

    /// Liest das Journal. Eine einzelne Datei, die sich nicht lesen oder nicht verstehen laesst, verwirft nichts: sie
    /// steht in `damaged` (Seiten zusaetzlich in `damagedPageKeys`, Wurzelfelder in `metaUnknown`), ihr Inhalt wird
    /// nach `damaged/` kopiert, und die uebrigen Dateien werden normal gelesen. Geworfen wird nur, wenn sich ein
    /// Ordner nicht auflisten laesst (dann ist nichts ueber den lokalen Stand bekannt).
    public func load() throws -> JournalSnapshot? {
        let pageFiles = try store.list("\(dir)/pages").sorted()
        let baseFiles = try store.list("\(dir)/base").sorted()
        var snap = JournalSnapshot()
        var sawAnything = !pageFiles.isEmpty
        switch read("meta.json") {
        case .missing:
            // Seiten ohne meta.json (Absturz zwischen den Dateien, neues Dokument ohne Netz): Wurzelfelder unbekannt,
            // nie die leere Vorgabe hochladen (sie ersetzte Seitenliste, Lesezeichen und Papierkorb auf dem Server)
            if sawAnything { snap.metaUnknown = true }
        case .unreadable:
            sawAnything = true
            snap.damaged.append("meta.json")
            snap.metaUnknown = true
        case .data(let metaData):
            sawAnything = true
            do {
                let m = try JSONValue.parse(metaData)
                guard m.object != nil else { throw JSONParseError(offset: 0, reason: "kein Objekt") }
                snap.rootMeta = m["rootMeta"] ?? snap.rootMeta
                snap.metaRev = m["metaRev"]?.int ?? 0
                if let b = m["baseRootMeta"], !b.isNull { snap.baseRootMeta = b }
            } catch {
                snap.damaged.append("meta.json")
                snap.metaUnknown = true
                preserve("meta.json", metaData)
            }
        }
        if !sawAnything { return nil }
        switch read("acks.json") {
        case .missing: break
        case .unreadable:
            snap.damaged.append("acks.json")
            snap.acksDamaged = true
        case .data(let ackData):
            do {
                let a = try JSONValue.parse(ackData)
                guard a.object != nil else { throw JSONParseError(offset: 0, reason: "kein Objekt") }
                snap.serverVersion = a["serverVersion"]?.int ?? 0
                snap.metaAckedRev = a["metaAckedRev"]?.int ?? 0
                for (k, v) in a["acked"]?.object ?? [:] { snap.acked[k] = v.int ?? 0 }
            } catch {
                snap.damaged.append("acks.json")
                snap.acksDamaged = true
                preserve("acks.json", ackData)
            }
        }
        for file in pageFiles where file.hasSuffix(".json") {
            let name = "pages/\(file)"
            switch read(name) {
            case .missing: continue
            case .unreadable:
                snap.damaged.append(name)
                if let key = LocalJournal.unsafeName(file) { snap.damagedPageKeys.append(key) }
            case .data(let data):
                do {
                    let p = try JSONValue.parse(data)
                    guard let page = p["page"], let rev = p["localRev"]?.int,
                          let key = p["key"]?.string ?? LocalJournal.unsafeName(file) else {
                        throw JSONParseError(offset: 0, reason: "Felder fehlen")
                    }
                    snap.pages[key] = JournalPage(page: page, localRev: rev)
                } catch {
                    snap.damaged.append(name)
                    if let key = LocalJournal.unsafeName(file) { snap.damagedPageKeys.append(key) }
                    preserve(name, data)
                }
            }
        }
        for file in baseFiles where file.hasSuffix(".json") {
            let name = "base/\(file)"
            switch read(name) {
            case .missing: continue
            case .unreadable: snap.damaged.append(name)
            case .data(let data):
                do {
                    let b = try JSONValue.parse(data)
                    guard b.object != nil, let key = b["key"]?.string ?? LocalJournal.unsafeName(file) else {
                        throw JSONParseError(offset: 0, reason: "Felder fehlen")
                    }
                    snap.bases[key] = b["page"] ?? .null
                } catch {
                    snap.damaged.append(name)
                    preserve(name, data)
                }
            }
        }
        return snap
    }

    private enum ReadResult { case missing, unreadable, data(Data) }

    /// Eine Datei des Journals; ein Lesefehler betrifft nur diese Datei
    private func read(_ name: String) -> ReadResult {
        do {
            guard let d = try store.read("\(dir)/\(name)") else { return .missing }
            return .data(d)
        } catch {
            return .unreadable
        }
    }

    /// Unveraenderte Kopie einer beschaedigten Datei unter `damaged/` (einmal; eine schon aufbewahrte bleibt). Nur zum
    /// Aufbewahren fuer eine Wiederherstellung von Hand, nie gelesen; scheitert das Kopieren, bleibt es bei der Meldung.
    private func preserve(_ name: String, _ data: Data) {
        let target = "\(dir)/damaged/" + name.replacingOccurrences(of: "/", with: "_")
        if (try? store.read(target)) != nil { return }
        try? store.write(data, to: target)
    }

    // MARK: Schreiben (Fehler werden weitergegeben)

    public func writePage(_ key: String, _ p: JournalPage) throws {
        let v: JSONValue = .object(["key": .string(key), "localRev": .number(Double(p.localRev)), "page": p.page])
        try store.write(v.serialized(), to: pagePath(key))
    }

    public func removePage(_ key: String) throws { try store.remove(pagePath(key)) }

    /// Basis einer Seite; `nil` = Seite existierte beim letzten bestaetigten Stand nicht.
    public func writeBase(_ key: String, _ page: JSONValue?) throws {
        let v: JSONValue = .object(["key": .string(key), "page": page ?? .null])
        try store.write(v.serialized(), to: basePath(key))
    }

    public func removeBase(_ key: String) throws { try store.remove(basePath(key)) }

    public func writeMeta(rootMeta: JSONValue, metaRev: Int, baseRootMeta: JSONValue?) throws {
        let v: JSONValue = .object([
            "schema": .number(1), "rootMeta": rootMeta, "metaRev": .number(Double(metaRev)), "baseRootMeta": baseRootMeta ?? .null,
        ])
        try store.write(v.serialized(), to: "\(dir)/meta.json")
    }

    public func writeAcks(serverVersion: Int, acked: [String: Int], metaAckedRev: Int) throws {
        var a: [String: JSONValue] = [:]
        for (k, v) in acked { a[k] = .number(Double(v)) }
        let v: JSONValue = .object([
            "serverVersion": .number(Double(serverVersion)), "metaAckedRev": .number(Double(metaAckedRev)), "acked": .object(a),
        ])
        try store.write(v.serialized(), to: "\(dir)/acks.json")
    }
}

/// Zustand aller Journale eines Speichers fuer die Diagnose (ohne Inhalte): ungesendete Seiten, beschaedigte Dateien
/// und Ordner, die sich nicht lesen lassen. Vorher wurde ein nicht lesbares Journal stillschweigend uebersprungen und
/// fehlte in der Zusammenfassung. Jede Datei des Journals wird atomar ersetzt (`FileBlobStore`): auch waehrend gerade
/// geschrieben wird, liest die Diagnose je Datei den alten oder den neuen Stand, nie einen halben.
public struct JournalScan: Equatable, Sendable {
    public var documentsWithUnsent = 0
    public var unsentPages = 0
    /// beschaedigte Dateien, als "<namensraum>/<dokumentordner>/<datei>"
    public var damaged: [String] = []
    /// Ordner, die sich nicht lesen liessen (dort ist der Stand unbekannt)
    public var unreadable: [String] = []

    public init() {}

    /// Alle Datenquellen (`spaces/<id>/docs`) und ein noch nicht umgezogener alter Ort (`docs`)
    public static func scan(store: BlobStore) -> JournalScan {
        var out = JournalScan()
        var spaces: [DataSourceNamespace?] = [nil]
        do {
            spaces += try store.list("spaces").sorted().map { DataSourceNamespace.named($0) }
        } catch {
            out.unreadable.append("spaces")
        }
        for space in spaces {
            let prefix = space.map { $0.id + "/" } ?? ""
            let docs: [String]
            do {
                docs = try store.list(LocalJournal.documentsDirectory(space)).sorted()
            } catch {
                out.unreadable.append(prefix + "docs")
                continue
            }
            for dir in docs {
                let id = LocalJournal.documentID(forDirectory: dir)
                let snap: JournalSnapshot?
                do {
                    snap = try LocalJournal(store: store, documentID: id, namespace: space).load()
                } catch {
                    out.unreadable.append(prefix + dir)
                    continue
                }
                guard let snap else { continue }
                let unsent = snap.pages.filter { $0.value.localRev > (snap.acked[$0.key] ?? 0) }.count
                    + (snap.metaRev > snap.metaAckedRev ? 1 : 0)
                if unsent > 0 { out.documentsWithUnsent += 1; out.unsentPages += unsent }
                out.damaged += snap.damaged.map { prefix + dir + "/" + $0 }
            }
        }
        return out
    }
}
