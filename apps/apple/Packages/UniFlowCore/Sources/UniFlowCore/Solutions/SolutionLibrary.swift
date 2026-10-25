import Foundation

/// Lokale Ablage der Loesungen auf dem Geraet (App: `Application Support/UniFlow/solutions/`), ohne Server.
///
/// - `received/<id>.uniflowsolution`: empfangene Pakete verschluesselt wie empfangen (in der kanonischen Form von
///   `SolutionPackage.encoded()`: Kopf und Chiffrat unveraendert, sonst nichts). Entschluesselt wird nur im
///   Arbeitsspeicher, wenn das passende Dokument offen ist.
/// - `shared/<id>.uniflowsolution`: eigene, als Datei geteilte Pakete ("Meine geteilten Lösungen").
/// - `index.json`: empfangene Loesungen nach Fingerabdruck der Original-PDF, dazu die geteilten.
///
/// Das eigene Notizmodell (Journal, DocumentStore) wird hier nie beruehrt.
public final class SolutionLibrary: @unchecked Sendable {

    /// Empfangene Loesung im Index (nur Kopfdaten, kein Inhalt).
    public struct Entry: Equatable, Sendable {
        public var solutionID: String
        public var fingerprint: String
        public var pdfPageCount: Int
        /// Leer = anonym.
        public var displayName: String
        public var createdAt: String
        public var receivedAt: String
        public var pageCount: Int
        public var missingImages: Int
        /// Im Editor eingeblendet.
        public var visible: Bool

        var json: JSONValue {
            .object([
                "solutionId": .string(solutionID), "fingerprint": .string(fingerprint),
                "pdfPageCount": .number(Double(pdfPageCount)), "displayName": .string(displayName),
                "createdAt": .string(createdAt), "receivedAt": .string(receivedAt),
                "pageCount": .number(Double(pageCount)), "missingImages": .number(Double(missingImages)),
                "visible": .bool(visible),
            ])
        }

        init?(json: JSONValue) {
            guard let id = json["solutionId"]?.string, SolutionValidator.isUUID(id),
                  let fp = json["fingerprint"]?.string, SolutionValidator.isHex64(fp) else { return nil }
            solutionID = id.lowercased()
            fingerprint = fp
            pdfPageCount = json["pdfPageCount"]?.int ?? 0
            displayName = json["displayName"]?.string ?? ""
            createdAt = json["createdAt"]?.string ?? ""
            receivedAt = json["receivedAt"]?.string ?? ""
            pageCount = json["pageCount"]?.int ?? 0
            missingImages = json["missingImages"]?.int ?? 0
            visible = json["visible"]?.bool ?? true
        }

        init(header h: SolutionHeader, receivedAt: Date) {
            solutionID = h.solutionID
            fingerprint = h.fingerprint
            pdfPageCount = h.pdfPageCount
            displayName = h.displayName
            createdAt = h.createdAt
            self.receivedAt = SolutionPackage.timestamp(receivedAt)
            pageCount = h.pageCount
            missingImages = h.missingImageCount
            visible = true
        }
    }

    /// Eigene, als Datei geteilte Loesung.
    public struct SharedEntry: Equatable, Sendable {
        public var solutionID: String
        public var fingerprint: String
        public var title: String
        public var displayName: String
        public var createdAt: String
        public var pageCount: Int
        public var missingImages: Int

        var json: JSONValue {
            .object([
                "solutionId": .string(solutionID), "fingerprint": .string(fingerprint), "title": .string(title),
                "displayName": .string(displayName), "createdAt": .string(createdAt),
                "pageCount": .number(Double(pageCount)), "missingImages": .number(Double(missingImages)),
            ])
        }

        init?(json: JSONValue) {
            guard let id = json["solutionId"]?.string, SolutionValidator.isUUID(id),
                  let fp = json["fingerprint"]?.string, SolutionValidator.isHex64(fp) else { return nil }
            solutionID = id.lowercased()
            fingerprint = fp
            title = json["title"]?.string ?? ""
            displayName = json["displayName"]?.string ?? ""
            createdAt = json["createdAt"]?.string ?? ""
            pageCount = json["pageCount"]?.int ?? 0
            missingImages = json["missingImages"]?.int ?? 0
        }

        init(header h: SolutionHeader, title: String) {
            solutionID = h.solutionID
            fingerprint = h.fingerprint
            self.title = title
            displayName = h.displayName
            createdAt = h.createdAt
            pageCount = h.pageCount
            missingImages = h.missingImageCount
        }
    }

    public let root: URL
    private let lock = NSLock()

    public init(root: URL) { self.root = root }

    var receivedDir: URL { root.appendingPathComponent("received", isDirectory: true) }
    var sharedDir: URL { root.appendingPathComponent("shared", isDirectory: true) }
    var indexURL: URL { root.appendingPathComponent("index.json") }

    /// Dateiname aus der Loesungs-ID (nur Hexziffern und Bindestriche, kein Pfad).
    public static func fileName(_ id: String) -> String {
        let safe = String(id.lowercased().unicodeScalars.filter { ("0"..."9").contains($0) || ("a"..."f").contains($0) || $0 == "-" })
        return (safe.isEmpty ? "ungueltig" : safe) + "." + SolutionPackage.fileExtension
    }

    // MARK: Index

    private struct Index {
        /// Fingerabdruck -> empfangene Loesungen (aelteste zuerst)
        var byFingerprint: [String: [Entry]] = [:]
        var shared: [SharedEntry] = []

        var json: JSONValue {
            .object([
                "formatVersion": 1,
                "byFingerprint": .object(byFingerprint.mapValues { .array($0.map(\.json)) }),
                "shared": .array(shared.map(\.json)),
            ])
        }
    }

    private func readIndex() -> Index {
        guard let data = try? Data(contentsOf: indexURL), let json = try? JSONValue.parse(data) else { return Index() }
        var index = Index()
        for (fp, list) in json["byFingerprint"]?.object ?? [:] {
            let entries = (list.array ?? []).compactMap(Entry.init(json:)).filter { $0.fingerprint == fp }
            if !entries.isEmpty { index.byFingerprint[fp] = entries }
        }
        index.shared = (json["shared"]?.array ?? []).compactMap(SharedEntry.init(json:))
        return index
    }

    private func writeIndex(_ index: Index) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try index.json.serialized(sortedKeys: true).write(to: indexURL, options: .atomic)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Empfangene Loesungen

    /// Paket pruefen (Kopf) und verschluesselt ablegen. Gespeichert wird nur die gepruefte, kanonische Form
    /// (`encoded()`), nie die empfangenen Rohbytes.
    ///
    /// Gleiche Loesungs-ID: Beim Import ist der Kopf noch nicht authentifiziert (das geht erst mit der PDF). Ein
    /// erneuter Import desselben Pakets ist daher erlaubt (Sichtbarkeit bleibt), ein ANDERES Paket mit derselben ID
    /// (anderer Fingerabdruck, anderer Kopf oder anderes Chiffrat) verdraengt die vorhandene Loesung nie: es wird mit
    /// `conflictingSolution` abgewiesen. Ist die vorhandene Datei unlesbar, wird sie ersetzt.
    /// Wirft bei ungueltigen Paketen; dann wird nichts gespeichert.
    @discardableResult
    public func importPackage(_ data: Data, now: Date = Date()) throws -> Entry {
        let package = try SolutionPackage.decode(data)
        return try locked {
            var index = readIndex()
            var entry = Entry(header: package.header, receivedAt: now)
            let url = receivedDir.appendingPathComponent(Self.fileName(entry.solutionID))
            let known = index.byFingerprint.values.flatMap { $0 }.first { $0.solutionID == entry.solutionID }
            if let stored = try? SolutionPackage.decode(Data(contentsOf: url)), stored != package {
                throw SolutionError.conflictingSolution
            }
            if let known { entry.visible = known.visible }
            for (fp, list) in index.byFingerprint {
                index.byFingerprint[fp] = list.filter { $0.solutionID != entry.solutionID }
                if index.byFingerprint[fp]?.isEmpty == true { index.byFingerprint[fp] = nil }
            }
            try FileManager.default.createDirectory(at: receivedDir, withIntermediateDirectories: true)
            try package.encoded().write(to: url, options: .atomic)
            index.byFingerprint[entry.fingerprint, default: []].append(entry)
            try writeIndex(index)
            return entry
        }
    }

    /// Empfangene Loesungen zu einer Original-PDF.
    public func entries(fingerprint: String) -> [Entry] {
        locked { readIndex().byFingerprint[fingerprint.lowercased()] ?? [] }
    }

    public func allEntries() -> [Entry] {
        locked { readIndex().byFingerprint.values.flatMap { $0 }.sorted { $0.receivedAt < $1.receivedAt } }
    }

    /// Gespeichertes Paket (verschluesselt, wie empfangen).
    public func package(_ id: String) throws -> SolutionPackage {
        try SolutionPackage.decode(Data(contentsOf: receivedDir.appendingPathComponent(Self.fileName(id))))
    }

    public func setVisible(_ id: String, _ visible: Bool) throws {
        try locked {
            var index = readIndex()
            for (fp, list) in index.byFingerprint {
                index.byFingerprint[fp] = list.map { e in
                    var e = e
                    if e.solutionID == id.lowercased() { e.visible = visible }
                    return e
                }
            }
            try writeIndex(index)
        }
    }

    /// Empfangene Loesung entfernen (Paket und Indexeintrag).
    public func remove(_ id: String) throws {
        try locked {
            var index = readIndex()
            for (fp, list) in index.byFingerprint {
                let rest = list.filter { $0.solutionID != id.lowercased() }
                index.byFingerprint[fp] = rest.isEmpty ? nil : rest
            }
            try? FileManager.default.removeItem(at: receivedDir.appendingPathComponent(Self.fileName(id)))
            try writeIndex(index)
        }
    }

    // MARK: Eigene geteilte Loesungen

    /// Als Datei geteiltes eigenes Paket merken (Kopie unter `shared/`).
    @discardableResult
    public func recordShared(_ package: SolutionPackage, title: String) throws -> SharedEntry {
        try locked {
            var index = readIndex()
            let entry = SharedEntry(header: package.header, title: title)
            try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
            try package.encoded().write(to: sharedDir.appendingPathComponent(Self.fileName(entry.solutionID)), options: .atomic)
            index.shared.removeAll { $0.solutionID == entry.solutionID }
            index.shared.append(entry)
            try writeIndex(index)
            return entry
        }
    }

    /// Neueste zuerst.
    public func sharedEntries() -> [SharedEntry] {
        locked { readIndex().shared.sorted { $0.createdAt > $1.createdAt } }
    }

    public func sharedPackageURL(_ id: String) -> URL { sharedDir.appendingPathComponent(Self.fileName(id)) }

    /// Eigene geteilte Loesung lokal entfernen ("zurueckziehen", solange es keinen Dienst gibt). Bereits
    /// weitergegebene Dateien bleiben beim Empfaenger.
    public func removeShared(_ id: String) throws {
        try locked {
            var index = readIndex()
            index.shared.removeAll { $0.solutionID == id.lowercased() }
            try? FileManager.default.removeItem(at: sharedPackageURL(id))
            try writeIndex(index)
        }
    }
}
