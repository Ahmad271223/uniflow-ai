import Foundation

/// Arbeitsordner einer ZIP-Datei: entpackter Inhalt (`inhalt/`), den man auf dem Geraet bearbeitet (Dateien
/// hinzufuegen, loeschen, umbenennen, Text aendern, PDFs annotieren), und `zip.json` mit dem Stand. Jede Aenderung
/// liegt sofort auf der Platte (bleibt nach dem Schliessen); `pack` macht daraus wieder eine ZIP-Datei (Abgabe,
/// Teilen). Alle Pfade sind relativ zu `inhalt/` und gehen durch `ZipArchive.safePath` (kein Weg hinaus).
public final class ZipWorkspace {
    /// Stand des Arbeitsordners
    public struct Meta: Codable, Equatable, Sendable {
        /// SHA-256 der ZIP-Datei, aus der entpackt wurde
        public var sourceSHA256: String
        public var sourceName: String
        public var extractedAt: Date
        /// Inhalt seit dem Entpacken geaendert
        public var changed: Bool
        /// beim Entpacken ausgelassen (unsicher oder nicht lesbar)
        public var skipped: [String]
        /// PDF im Inhalt -> Dokument der Bibliothek, in dem die Notizen dazu liegen
        public var links: [String: Link]

        public struct Link: Codable, Equatable, Sendable {
            public var fileID: String
            /// SHA-256 der PDF beim Import; aendert sich die Datei, gilt die Verknuepfung nicht mehr
            public var sha256: String
            public init(fileID: String, sha256: String) {
                self.fileID = fileID
                self.sha256 = sha256
            }
        }
    }

    /// Eintrag einer Ordneransicht
    public struct Item: Identifiable, Hashable, Sendable {
        /// relativer Pfad im Inhalt
        public let path: String
        public let name: String
        public let isDirectory: Bool
        public let size: Int
        public let modified: Date
        /// Dateien darin (nur Ordner)
        public let childCount: Int
        public var id: String { path }
        public var ext: String { (name as NSString).pathExtension.lowercased() }
    }

    /// Ergebnis von `prepare`
    public enum Prepared: Equatable, Sendable {
        /// neu entpackt
        case extracted(ZipArchive.Summary)
        /// vorhandener Stand weiter benutzt
        case kept
        /// die ZIP-Datei ist neuer, der Inhalt hier aber geaendert: weiter der eigene Stand (Hinweis zeigen)
        case keptWithNewerSource
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case invalidName
        case exists(String)
        case notFound(String)
        case notPrepared

        public var errorDescription: String? {
            switch self {
            case .invalidName: return "Ungültiger Name. Er darf nicht leer sein und keinen „/“ enthalten."
            case .exists(let n): return "„\(n)“ gibt es hier schon."
            case .notFound(let n): return "„\(n)“ wurde nicht gefunden."
            case .notPrepared: return "Die ZIP-Datei ist noch nicht entpackt."
            }
        }
    }

    public let root: URL
    public let limits: ZipArchive.Limits
    public var content: URL { root.appendingPathComponent("inhalt", isDirectory: true) }
    var metaURL: URL { root.appendingPathComponent("zip.json") }
    private let fm = FileManager.default

    public init(root: URL, limits: ZipArchive.Limits = .standard) {
        self.root = root
        self.limits = limits
    }

    public var meta: Meta? {
        guard let d = try? Data(contentsOf: metaURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Meta.self, from: d)
    }

    private func save(_ m: Meta) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try enc.encode(m).write(to: metaURL, options: .atomic)
    }

    private func update(_ change: (inout Meta) -> Void) throws {
        guard var m = meta else { throw Failure.notPrepared }
        change(&m)
        try save(m)
    }

    // MARK: Entpacken

    /// Inhalt bereitstellen: noch nichts da, `force` oder neue ZIP-Datei bei unveraendertem Inhalt -> neu entpacken
    /// (erst in einen Nebenordner, dann tauschen: ein Fehler laesst den alten Stand stehen)
    @discardableResult
    public func prepare(source: Data, name: String, force: Bool = false) throws -> Prepared {
        let sha = SolutionSHA256.hex(source)
        if !force, let m = meta, fm.fileExists(atPath: content.path) {
            if m.sourceSHA256 == sha { return .kept }
            if m.changed { return .keptWithNewerSource }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let fresh = root.appendingPathComponent("inhalt-neu-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: fresh) }
        let summary = try ZipArchive.extract(source, to: fresh, limits: limits)
        try? fm.removeItem(at: content)
        try fm.moveItem(at: fresh, to: content)
        try save(Meta(sourceSHA256: sha, sourceName: name, extractedAt: Date(), changed: false,
                      skipped: summary.unsafe + summary.unreadable, links: [:]))
        return .extracted(summary)
    }

    /// Arbeitsordner ganz entfernen
    public func remove() { try? fm.removeItem(at: root) }

    // MARK: Ansehen

    /// Inhalt eines Ordners: Ordner zuerst, dann Dateien, Namen wie im Finder sortiert; versteckte Dateien nicht
    public func list(_ dir: String = "") throws -> [Item] {
        let base = try url(dir)
        let names = try fm.contentsOfDirectory(atPath: base.path).filter { !$0.hasPrefix(".") }
        var out: [Item] = []
        for n in names {
            let u = base.appendingPathComponent(n)
            let attrs = try fm.attributesOfItem(atPath: u.path)
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink { continue }
            let isDir = type == .typeDirectory
            let children = isDir ? ((try? fm.contentsOfDirectory(atPath: u.path))?.filter { !$0.hasPrefix(".") }.count ?? 0) : 0
            out.append(Item(path: dir.isEmpty ? n : dir + "/" + n, name: n, isDirectory: isDir,
                            size: (attrs[.size] as? NSNumber)?.intValue ?? 0,
                            modified: attrs[.modificationDate] as? Date ?? Date(), childCount: children))
        }
        return out.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Anzahl Dateien und Bytes im ganzen Inhalt
    public func totals() -> (files: Int, bytes: Int) {
        guard let e = fm.enumerator(at: content, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return (0, 0) }
        var files = 0, bytes = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true, !u.lastPathComponent.hasPrefix(".") { files += 1; bytes += v?.fileSize ?? 0 }
        }
        return (files, bytes)
    }

    /// Datei-URL eines relativen Pfads ("" = Inhalt selbst); wirft bei unsicherem Pfad
    public func url(_ path: String) throws -> URL {
        guard fm.fileExists(atPath: content.path) else { throw Failure.notPrepared }
        if path.isEmpty { return content }
        guard let safe = ZipArchive.safePath(path) else { throw ZipArchive.Failure.unsafePath(path) }
        return try ZipArchive.inside(content, safe)
    }

    // MARK: Bearbeiten

    /// Neuer Name im selben Ordner; Rueckgabe: neuer Pfad
    @discardableResult
    public func rename(_ path: String, to newName: String) throws -> String {
        let name = try Self.checkedName(newName)
        let from = try url(path)
        guard fm.fileExists(atPath: from.path) else { throw Failure.notFound(path) }
        let parent = (path as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty ? name : parent + "/" + name
        if newPath == path { return path }
        let to = try url(newPath)
        // nur Gross-/Kleinschreibung geaendert: auf APFS ohne Unterscheidung ueber einen Zwischennamen
        if newPath.lowercased() == path.lowercased() {
            let tmp = try url((parent.isEmpty ? "" : parent + "/") + ".umbenennen-\(UUID().uuidString)")
            try fm.moveItem(at: from, to: tmp)
            try fm.moveItem(at: tmp, to: to)
        } else {
            guard !fm.fileExists(atPath: to.path) else { throw Failure.exists(name) }
            try fm.moveItem(at: from, to: to)
        }
        try update { m in
            m.changed = true
            var moved: [String: Meta.Link] = [:]
            for (k, v) in m.links {
                if k == path { moved[newPath] = v } else if k.hasPrefix(path + "/") { moved[newPath + k.dropFirst(path.count)] = v } else { moved[k] = v }
            }
            m.links = moved
        }
        return newPath
    }

    /// Datei oder Ordner (mit Inhalt) loeschen
    public func delete(_ path: String) throws {
        guard !path.isEmpty else { throw Failure.invalidName }
        let u = try url(path)
        guard fm.fileExists(atPath: u.path) else { throw Failure.notFound(path) }
        try fm.removeItem(at: u)
        try update { m in
            m.changed = true
            m.links = m.links.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        }
    }

    /// Neuer Ordner; Rueckgabe: sein Pfad
    @discardableResult
    public func makeFolder(named name: String, in dir: String = "") throws -> String {
        let n = try Self.checkedName(name)
        let path = dir.isEmpty ? n : dir + "/" + n
        let u = try url(path)
        guard !fm.fileExists(atPath: u.path) else { throw Failure.exists(n) }
        try fm.createDirectory(at: u, withIntermediateDirectories: false)
        try update { $0.changed = true }
        return path
    }

    /// Datei von aussen in einen Ordner kopieren; gibt es den Namen schon, "Name 2.ext". Rueckgabe: neuer Pfad
    @discardableResult
    public func add(fileAt source: URL, named: String? = nil, into dir: String = "") throws -> String {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        return try add(data, named: named ?? source.lastPathComponent, into: dir)
    }

    @discardableResult
    public func add(_ data: Data, named: String, into dir: String = "") throws -> String {
        let name = try Self.checkedName(named)
        let base = try url(dir)
        let unique = Self.uniqueName(name) { fm.fileExists(atPath: base.appendingPathComponent($0).path) }
        let path = dir.isEmpty ? unique : dir + "/" + unique
        try data.write(to: try url(path), options: .atomic)
        try update { $0.changed = true }
        return path
    }

    /// Inhalt einer vorhandenen Datei ersetzen (Text geaendert, Datei ersetzt)
    public func write(_ data: Data, to path: String) throws {
        let u = try url(path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { throw Failure.notFound(path) }
        try data.write(to: u, options: .atomic)
        try update { m in
            m.changed = true
            if let l = m.links[path], l.sha256 != SolutionSHA256.hex(data) { m.links[path] = nil }
        }
    }

    // MARK: Notizen zu PDFs

    /// Dokument der Bibliothek zu einer PDF im Inhalt, solange die PDF dieselbe ist
    public func link(for path: String) -> Meta.Link? {
        guard let l = meta?.links[path], let u = try? url(path), let d = try? Data(contentsOf: u),
              SolutionSHA256.hex(d) == l.sha256 else { return nil }
        return l
    }

    public func setLink(_ fileID: String?, for path: String) throws {
        let u = try url(path)
        let sha = SolutionSHA256.hex(try Data(contentsOf: u))
        try update { m in
            m.links[path] = fileID.map { Meta.Link(fileID: $0, sha256: sha) }
            // Notizen sind eine Aenderung der Abgabe
            if fileID != nil { m.changed = true }
        }
    }

    // MARK: Packen

    /// Inhalt als ZIP-Datei; `replacing` ersetzt einzelne Dateien (PDF mit Notizen)
    public func pack(replacing: [String: Data] = [:]) throws -> Data {
        try ZipArchive.pack(directory: try url(""), replacing: replacing)
    }

    // MARK: Namen

    /// Name fuer eine Datei oder einen Ordner: getrimmt, ohne "/" und "\", nicht "." oder "..", keine Steuerzeichen
    public static func checkedName(_ raw: String) throws -> String {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !n.isEmpty, n != ".", n != "..", !n.contains("/"), !n.contains("\\"), !n.hasPrefix("."), n.count <= 255,
              !n.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw Failure.invalidName }
        return n
    }

    /// "Blatt.pdf", "Blatt 2.pdf", "Blatt 3.pdf" …
    public static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            if !exists(candidate) { return candidate }
            i += 1
        }
    }
}
