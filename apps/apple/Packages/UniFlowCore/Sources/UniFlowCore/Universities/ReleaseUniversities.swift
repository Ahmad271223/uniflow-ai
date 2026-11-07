import Foundation

/// Welche Hochschulen dieser Build zur Wahl stellt. Entscheidung des Inhabers (07.11.2026, 14:10): Version 1.0 (Build 16)
/// geht nur mit der Leibniz Universitaet Hannover (Stud.IP, QIS) in den App Store. Hochschule Hannover (Moodle, HISinOne)
/// und Universitaet Hildesheim (Learnweb, LSF, PLuS) bleiben vollstaendig im Code, erscheinen im Store-Build aber nicht
/// (Hochschulwahl beim ersten Start, "Hochschule wechseln" in den Einstellungen, Hochschul-Liste in `/api/services`)
/// und kommen 1-2 Tage spaeter mit 1.0.1. Nichts wird geloescht: ein schon gewaehlter Container einer nicht ausgelieferten
/// Hochschule (Entwickler-iPads) bleibt voll nutzbar, `choices(current:)` fuehrt ihn weiter auf.
///
/// Quelle: Build-Einstellung `UF_SHIPPED_UNIVERSITIES` in apps/apple/project.yml (Release "luh", Debug "luh hildesheim hsh")
/// -> Info.plist `UFShippedUniversities`. **Fuer 1.0.1 dort den Release-Wert auf "luh hildesheim hsh" (oder "all") setzen
/// und `xcodegen generate` ausfuehren**; der Code bleibt. Nur in Debug-Builds uebersteuern die Umgebungsvariable
/// `UF_SHIPPED_UNIVERSITIES` (Testplan, Schema) oder das Startargument `-UFShippedUniversities "luh hsh"` den Build.
/// Ohne Angabe gilt der Store-Stand (nur LUH) - nie still alle.
public enum UFReleaseUniversities {
    /// Schluessel in der Info.plist des App-Bundles (project.yml: `UFShippedUniversities: $(UF_SHIPPED_UNIVERSITIES)`)
    public static let infoKey = "UFShippedUniversities"
    /// Umgebungsvariable (nur Debug), z. B. im Testplan oder Schema: "luh hildesheim hsh" oder "all"
    public static let environmentKey = "UF_SHIPPED_UNIVERSITIES"
    /// Startargument `-UFShippedUniversities <Wert>` (nur Debug; liegt wie -UFUniversity in UserDefaults.standard)
    public static let launchArgumentKey = "UFShippedUniversities"
    /// Wert fuer alle bekannten Hochschulen
    public static let allValue = "all"
    /// Stand des App Store ohne Angabe: Version 1.0 nur die LUH
    public static let storeDefault: Set<UniversityKey> = [.luh]

    /// "luh", "luh,hildesheim", "luh hildesheim hsh", "all" -> Menge der Schluessel (ohne Gross-/Kleinschreibung, Trenner
    /// Komma, Semikolon oder Leerraum). Unbekannte Schluessel zaehlen nicht; bleibt nichts uebrig, ergibt das nil (dann
    /// gilt die naechste Quelle bzw. der Store-Stand) - ein Tippfehler schaltet nie still alle Hochschulen frei.
    public static func parse(_ raw: String?) -> Set<UniversityKey>? {
        guard let raw else { return nil }
        let parts = raw.lowercased().split { $0 == "," || $0 == ";" || $0.isWhitespace }.map(String.init)
        if parts.contains(allValue) { return Set(UniversityKey.allCases) }
        let keys = Set(parts.compactMap(UniversityKey.init(rawValue:)))
        return keys.isEmpty ? nil : keys
    }

    /// Reihenfolge: Startargument, Umgebungsvariable (beide nur in Debug-Builds), Info.plist, Store-Stand.
    public static func resolve(launchArgument: String? = nil, environment: [String: String] = [:], info: [String: Any]? = nil,
                               debug: Bool = isDebugBuild) -> Set<UniversityKey> {
        if debug, let forced = parse(launchArgument) ?? parse(environment[environmentKey]) { return forced }
        return parse(info?[infoKey] as? String) ?? storeDefault
    }

    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: Set<UniversityKey>?

    /// Die Hochschulen dieses Prozesses: beim ersten Zugriff aus Startargument, Umgebung und Info.plist des App-Bundles;
    /// setzen nur Tests (`withShipped`, `reset`).
    public static var shipped: Set<UniversityKey> {
        get {
            lock.withLock {
                if let current { return current }
                let resolved = resolve(launchArgument: UserDefaults.standard.string(forKey: launchArgumentKey),
                                       environment: ProcessInfo.processInfo.environment, info: Bundle.main.infoDictionary)
                current = resolved
                return resolved
            }
        }
        set { lock.withLock { current = newValue } }
    }

    /// Zurueck auf den Stand des Prozesses (Tests)
    public static func reset() { lock.withLock { current = nil } }

    /// Bietet dieser Build die Hochschule zur Wahl an?
    public static func isShipped(_ university: UniversityKey) -> Bool { shipped.contains(university) }

    /// Hochschulen zur Wahl in fester Reihenfolge (`UniversityKey.allCases`). Die aktuelle Hochschule des Nutzers steht
    /// immer dabei, auch wenn dieser Build sie nicht mehr anbietet (verbundenes HsH-/Hildesheim-Konto bleibt nutzbar).
    public static func choices(current: UniversityKey? = nil) -> [UniversityKey] {
        let set = shipped
        return UniversityKey.allCases.filter { set.contains($0) || $0 == current }
    }

    /// Fehlen in diesem Build bekannte Hochschulen? (Hinweis "Weitere Hochschulen folgen mit einem Update.")
    public static var moreToCome: Bool { shipped.count < UniversityKey.allCases.count }

    /// Fuer Tests: waehrend `body` genau diese Hochschulen, danach wieder der vorige Stand.
    public static func withShipped<T>(_ set: Set<UniversityKey>, _ body: () throws -> T) rethrows -> T {
        let before = lock.withLock { current }
        shipped = set
        defer { lock.withLock { current = before } }
        return try body()
    }
}
