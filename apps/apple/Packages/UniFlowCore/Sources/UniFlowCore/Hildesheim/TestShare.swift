import Foundation

/// Schluessel gemeinsamer Wochentests (`app/testshare.py`, docs/GEMEINSAME-WOCHENTESTS.md): gleiche Vorlesung und
/// Uebung ergeben denselben Test. Schluessel aus Hochschule, Dauer-Stufe und den Inhalts-Hashes der Materialien
/// (`content_sha256`, `ContentHash.file`).
///
/// Varianten (Regel des Inhabers, 04.11.2026): je Schluessel hoechstens `maxVariants` = 3 Tests, egal wie viele
/// Studierende das Modul haben. Jeder Nutzer bekommt eine feste Variante `variant(userID:key:)`; vorhandene wird
/// uebernommen, erzeugt wird nur, solange weniger als drei da sind (`pick`). Erwartungswerte wie am PC in
/// fixtures/testshare/cases.json (`variants`, `pick_cases`). Der Ablauf mit Dienst (CloudKit in V1) steht in
/// `WeeklyTestShare`, die Anbindung im Wochentest-Endpunkt (`WeekTests.create`).
public enum TestShare {
    public static let version = "wt2"
    public static let minuteSteps = [15, 30, 45, 60, 90, 120]
    /// hoechstens so viele Tests je Schluessel (`testshare.MAX_VARIANTS`)
    public static let maxVariants = 3
    /// Quellen eines uebernommenen Tests (`tests.adopted_from`), wie `testshare.ADOPTED_*`; NULL = selbst erzeugt
    public static let adoptedLocal = "local", adoptedService = "service", adoptedCloudKit = "cloudkit"

    /// `testshare.variant`: feste Variante 0..maxVariants-1 eines Nutzers fuer einen Schluessel. SHA-256 ueber
    /// "<userID>|<key>", die ersten 4 Byte als Zahl (big-endian), modulo maxVariants: deterministisch, gleich verteilt.
    public static func variant(userID: String, key: String) -> Int {
        let d = SolutionSHA256.hash(Data("\(userID)|\(key)".utf8))
        let n = (UInt32(d[0]) << 24) | (UInt32(d[1]) << 16) | (UInt32(d[2]) << 8) | UInt32(d[3])
        return Int(n % UInt32(maxVariants))
    }

    /// `adopt`: Variante uebernehmen (keine KI); `generate`: erzeugen und als Variante veroeffentlichen; `none`: nichts
    /// zu uebernehmen und kein Platz frei (eigener Test ohne Veroeffentlichung)
    public enum Action: String, Equatable, Sendable { case adopt, generate, none }

    /// `testshare.pick`: `ready` fertige Varianten, `pending` belegte, noch leere (ein anderer erzeugt gerade). Eigene
    /// fertig -> uebernehmen; sonst erzeugen, solange weniger als maxVariants Plaetze belegt sind (die eigene, bei einem
    /// Wettlauf die naechste freie); bei drei belegten nie erzeugen, sondern die naechste fertige uebernehmen.
    public static func pick(ready: Set<Int>, assigned: Int, pending: Set<Int> = []) -> (action: Action, variant: Int?) {
        let have = ready.filter { (0..<maxVariants).contains($0) }
        let taken = have.union(pending.filter { (0..<maxVariants).contains($0) })
        if have.contains(assigned) { return (.adopt, assigned) }
        if taken.count < maxVariants {
            for i in 0..<maxVariants {
                let v = (assigned + i) % maxVariants
                if !taken.contains(v) { return (.generate, v) }
            }
        }
        let others = have.sorted { ($0 - assigned + maxVariants) % maxVariants < ($1 - assigned + maxVariants) % maxVariants }
        return others.first.map { (.adopt, $0) } ?? (.none, nil)
    }

    /// `testshare.shared_info`: `shared` im Test-JSON ("Gemeinsamer Test · Variante 2 von 3"): variant 1-basiert,
    /// of = maxVariants, adopted = uebernommen statt selbst erzeugt; null ohne Variante
    public static func sharedInfo(variant: JSONValue?, adoptedFrom: JSONValue?) -> JSONValue {
        guard let v = variant?.int else { return .null }
        let adopted = adoptedFrom.map { $0 != .null && !($0.string?.isEmpty ?? true) } ?? false
        return ["variant": .number(Double(v + 1)), "of": .number(Double(maxVariants)), "adopted": .bool(adopted)]
    }

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
