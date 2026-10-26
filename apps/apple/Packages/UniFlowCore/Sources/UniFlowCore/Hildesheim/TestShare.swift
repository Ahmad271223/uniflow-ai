import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Gemeinsame Wochentests (`app/testshare.py`, docs/GEMEINSAME-WOCHENTESTS.md): gleiche Vorlesung und Uebung
/// ergeben denselben Test. Schluessel aus Hochschule, Dauer-Stufe und SHA-256 des Dateiinhalts.
public enum TestShare {
    public static let version = "wt1"
    public static let minuteSteps = [15, 30, 45, 60, 90, 120]

    public static func minutesBucket(_ minutes: Int?) -> Int {
        let m = minutes ?? 45
        return minuteSteps.first { m <= $0 } ?? minuteSteps.last!
    }

    /// Inhalts-Hash einer Datei (beim Download einmal berechnen und speichern)
    public static func contentHash(_ data: Data) -> String { SolutionSHA256.hex(data) }

    /// `testshare.file_sha256(path)`: Inhalts-Hash einer Datei auf der Platte in 1-MB-Bloecken (konstanter Speicher,
    /// auch fuer Vorlesungsvideos); nil, wenn die Datei fehlt oder nicht lesbar ist. Die eine Fassung fuer alle
    /// Abgleiche (Stud.IP, Learnweb: `UniDownloads`). Synchron und je nach Groesse langsam: nicht auf dem Hauptthread
    /// und nicht in einer Datenbank-Transaktion aufrufen.
    public static func contentHash(file url: URL) -> String? {
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

    /// SHA-256 fuer `contentHash(file:)`: auf Apple-Geraeten CryptoKit (um ein Vielfaches schneller, grosse Dateien
    /// und Videos), sonst (Linux) `SolutionSHA256`; derselbe Wert (UniStoreTests vergleicht beide).
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

    /// Schluessel oder nil, wenn eine Datei keinen Inhalts-Hash hat (dann nicht teilen).
    /// Kanonisch wie `json.dumps(..., sort_keys=True, separators=(",", ":"))` in Python.
    public static func shareKey(university: String, minutes: Int?, contentHashes: [String?]) -> String? {
        guard !contentHashes.isEmpty, contentHashes.allSatisfy({ $0 != nil && !$0!.isEmpty }) else { return nil }
        let prints = Set(contentHashes.compactMap { $0 }).sorted()
        let canon = "{\"materials\":[" + prints.map { "\"\($0)\"" }.joined(separator: ",") + "],\"minutes\":\(minutesBucket(minutes))"
            + ",\"uni\":\"\(jsonEscape(university))\",\"v\":\"\(version)\"}"
        return "\(version):" + HText.sha256Hex(canon)
    }

    static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
