import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Inhalts-Hash einer Datei (`files.content_sha256`, `testshare.file_sha256` am PC): SHA-256 des Dateiinhalts als
/// Hex. Beim Download einmal berechnet (`UniDownloads`); damit erkennt S7 eine neue Fassung mit gleichem Inhalt
/// (`FileVersionKeeper`), und der Editor prueft, ob die geoeffnete Original-PDF noch dieselbe ist.
public enum ContentHash {
    /// Datei auf der Platte in 1-MB-Bloecken (konstanter Speicher, auch fuer Vorlesungsvideos); nil, wenn die Datei
    /// fehlt oder nicht lesbar ist. Die eine Fassung fuer alle Abgleiche (Stud.IP, Learnweb) und den Editor.
    /// Synchron und je nach Groesse langsam: nicht auf dem Hauptthread und nicht in einer Datenbank-Transaktion
    /// aufrufen.
    public static func file(_ url: URL) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = FileHasher()
        do {
            // nil oder leer: Dateiende
            while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(block) }
        } catch {
            return nil
        }
        return hasher.hex()
    }

    /// SHA-256 fuer `file(_:)`: auf Apple-Geraeten CryptoKit (um ein Vielfaches schneller, grosse Dateien und
    /// Videos), sonst (Linux) `SolutionSHA256`; derselbe Wert (UniStoreTests vergleicht beide).
    private struct FileHasher {
        #if canImport(CryptoKit)
        private var sha = CryptoKit.SHA256()
        mutating func update(_ block: Data) { sha.update(data: block) }
        func hex() -> String { SolutionSHA256.hexString(Array(sha.finalize())) }
        #else
        private var sha = SolutionSHA256.Hasher()
        mutating func update(_ block: Data) { sha.update(block) }
        func hex() -> String { SolutionSHA256.hexString(sha.finalize()) }
        #endif
    }
}
