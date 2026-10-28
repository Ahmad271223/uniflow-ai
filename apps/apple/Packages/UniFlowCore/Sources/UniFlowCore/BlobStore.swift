import Foundation

/// Ablage fuer das lokale Journal. Schreibfehler werden immer geworfen, nie verschluckt.
public protocol BlobStore: Sendable {
    func read(_ path: String) throws -> Data?
    func write(_ data: Data, to path: String) throws
    func remove(_ path: String) throws
    func list(_ directory: String) throws -> [String]
}

/// Dateien unter einem Wurzelordner; jede Datei wird atomar ersetzt (Temp-Datei + Umbenennen).
public final class FileBlobStore: BlobStore, @unchecked Sendable {
    public let root: URL
    /// Darf noch geschrieben werden? (App: Schreibrecht des Containers, entzogen beim Loeschen.) Ohne Recht scheitern
    /// Schreiben und Entfernen mit einem Fehler, statt Ordner neu anzulegen.
    private let canWrite: (@Sendable () -> Bool)?

    public init(root: URL, canWrite: (@Sendable () -> Bool)? = nil) {
        self.root = root
        self.canWrite = canWrite
    }

    private func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    private func checkWritable(_ path: String) throws {
        if let canWrite, !canWrite() { throw BlobStoreError(path: path, reason: "Speicher gelöscht") }
    }

    public func read(_ path: String) throws -> Data? {
        let u = url(path)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Data(contentsOf: u)
    }

    public func write(_ data: Data, to path: String) throws {
        try checkWritable(path)
        let u = url(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: u, options: [.atomic])
        #endif
    }

    public func remove(_ path: String) throws {
        try checkWritable(path)
        let u = url(path)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
    }

    public func list(_ directory: String) throws -> [String] {
        let u = url(directory)
        guard FileManager.default.fileExists(atPath: u.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: u.path)
    }
}

public struct BlobStoreError: Error, CustomStringConvertible, Equatable {
    public let path: String
    public let reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
    public var description: String { "\(reason): \(path)" }
}

/// Speicher im Arbeitsspeicher, fuer Tests und Vorschauen. Schreibfehler lassen sich gezielt ausloesen.
public final class MemoryBlobStore: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var failingPrefixes: Set<String> = []
    private var failingRemovePrefixes: Set<String> = []
    private var failAll = false
    public private(set) var writeCount = 0

    public init() {}

    /// Alle Schreibzugriffe schlagen fehl (z. B. Speicher voll).
    public func setFailAllWrites(_ on: Bool) { lock.lock(); failAll = on; lock.unlock() }

    /// Schreibzugriffe auf Pfade mit diesem Anfang schlagen fehl.
    public func setFailWrites(prefix: String, _ on: Bool) {
        lock.lock()
        if on { failingPrefixes.insert(prefix) } else { failingPrefixes.remove(prefix) }
        lock.unlock()
    }

    /// Entfernen von Pfaden mit diesem Anfang schlaegt fehl (z. B. gesperrte Datei).
    public func setFailRemoves(prefix: String, _ on: Bool) {
        lock.lock()
        if on { failingRemovePrefixes.insert(prefix) } else { failingRemovePrefixes.remove(prefix) }
        lock.unlock()
    }

    public var paths: [String] { lock.lock(); defer { lock.unlock() }; return files.keys.sorted() }

    public func read(_ path: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[path]
    }

    public func write(_ data: Data, to path: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failAll || failingPrefixes.contains(where: { path.hasPrefix($0) }) {
            throw BlobStoreError(path: path, reason: "Schreiben fehlgeschlagen")
        }
        writeCount += 1
        files[path] = data
    }

    public func remove(_ path: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failingRemovePrefixes.contains(where: { path.hasPrefix($0) }) { throw BlobStoreError(path: path, reason: "Entfernen fehlgeschlagen") }
        files.removeValue(forKey: path)
    }

    public func list(_ directory: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return files.keys.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
            .map { String($0.dropFirst(prefix.count)) }
    }
}
