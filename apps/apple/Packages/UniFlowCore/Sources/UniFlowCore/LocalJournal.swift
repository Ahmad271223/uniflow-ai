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
}

/// Ablage im Ordner `spaces/<namensraum>/docs/<id>/` (ohne Namensraum wie vor S2 `docs/<id>/`, siehe
/// `DataSourceNamespace` und `JournalNamespaceMigration`):
/// - `meta.json`: Wurzelfelder ohne Seiten, `metaRev`, Basis der Wurzelfelder
/// - `acks.json`: Serverversion und bestaetigte Revisionen
/// - `pages/<key>.json`: Seite + `localRev`
/// - `base/<key>.json`: Basis einer geaenderten Seite
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

    static func safeName(_ s: String) -> String {
        let ok = !s.isEmpty && s.count <= 100 && s.unicodeScalars.allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "_" || $0 == "-"
        }
        if ok { return s }
        return "~" + SolutionSHA256.hexString(Array(s.utf8))          // "~" kommt in sicheren Namen nie vor
    }

    static func unsafeName(_ file: String) -> String? {
        guard file.hasSuffix(".json") else { return nil }
        let base = String(file.dropLast(5))
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

    public func load() throws -> JournalSnapshot? {
        let metaData = try store.read("\(dir)/meta.json")
        let pageFiles = try store.list("\(dir)/pages")
        if metaData == nil && pageFiles.isEmpty { return nil }
        var snap = JournalSnapshot()
        if let metaData {
            do {
                let m = try JSONValue.parse(metaData)
                snap.rootMeta = m["rootMeta"] ?? snap.rootMeta
                snap.metaRev = m["metaRev"]?.int ?? 0
                if let b = m["baseRootMeta"], !b.isNull { snap.baseRootMeta = b }
            } catch { snap.damaged.append("meta.json") }
        }
        if let ackData = try store.read("\(dir)/acks.json") {
            do {
                let a = try JSONValue.parse(ackData)
                snap.serverVersion = a["serverVersion"]?.int ?? 0
                snap.metaAckedRev = a["metaAckedRev"]?.int ?? 0
                for (k, v) in a["acked"]?.object ?? [:] { snap.acked[k] = v.int ?? 0 }
            } catch { snap.damaged.append("acks.json") }
        }
        for file in pageFiles {
            guard let key = LocalJournal.unsafeName(file) else { continue }
            guard let data = try store.read("\(dir)/pages/\(file)") else { continue }
            do {
                let p = try JSONValue.parse(data)
                guard let page = p["page"], let rev = p["localRev"]?.int else { throw JSONParseError(offset: 0, reason: "Felder fehlen") }
                snap.pages[key] = JournalPage(page: page, localRev: rev)
            } catch { snap.damaged.append("pages/\(file)") }
        }
        for file in try store.list("\(dir)/base") {
            guard let key = LocalJournal.unsafeName(file), let data = try store.read("\(dir)/base/\(file)") else { continue }
            do { snap.bases[key] = try JSONValue.parse(data)["page"] ?? .null } catch { snap.damaged.append("base/\(file)") }
        }
        return snap
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
