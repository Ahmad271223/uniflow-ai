import Foundation

/// Schluessel gemeinsamer Wochentests (`app/testshare.py`, docs/GEMEINSAME-WOCHENTESTS.md): gleiche Vorlesung und
/// Uebung ergeben denselben Test. Schluessel aus Hochschule, Dauer-Stufe und den Inhalts-Hashes der Materialien
/// (`content_sha256`, `ContentHash.file`).
///
/// Erst ab V2: Wochentests entfallen in V1 (KI, `DroppedEndpoints`); in der App ruft niemand `shareKey` auf. Der
/// Schluessel bleibt mit seinen Erwartungswerten (fixtures/testshare/cases.json) gleich wie am PC, damit V2 ihn
/// unveraendert nutzen kann.
public enum TestShare {
    public static let version = "wt2"
    public static let minuteSteps = [15, 30, 45, 60, 90, 120]

    /// `minutes_bucket`: naechste feste Stufe; ohne Angabe oder 0 wie `int(minutes or 45)` die Stufe 45 (vorher
    /// wurde 0 zur Stufe 15 und damit zu einem anderen Schluessel als am PC)
    public static func minutesBucket(_ minutes: Int?) -> Int {
        let m = minutes.flatMap { $0 == 0 ? nil : $0 } ?? 45
        return minuteSteps.first { m <= $0 } ?? minuteSteps.last!
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
