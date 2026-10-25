import Foundation

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
