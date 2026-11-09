import Foundation

/// iCloud-Schluessel-Wert-Speicher des Apple-Kontos (App: `NSUbiquitousKeyValueStore.default`), fuer Tests austauschbar.
/// Die Signaturen sind die von `NSUbiquitousKeyValueStore`, die App braucht nur `extension NSUbiquitousKeyValueStore:
/// UbiquitousValueStore {}`.
public protocol UbiquitousValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

/// Community-Zustand eines Containers, den iPad und Mac ("Designed for iPad", dieselbe App, dieselbe Apple-ID) gleich
/// sehen muessen (Paritaet 09.11.2026, docs/paritaet/COMMUNITY-UND-ABGLEICH-2026-11-09.md, Abschnitt Mac):
/// beigetretene Kurs-Communities, Lerngruppen (Code und Name), Sperrliste (Zwischenspeicher), Pseudonym und der Zustand
/// "gesehen"/"ignoriert" der Korrekturhinweise. Bis Build 28 lag das nur in den UserDefaults des Geraets: auf dem Mac
/// fehlten die Lerngruppen und Beitritte des iPads, Kommentare erschienen dort als "Anonym", und das Abzeichen am
/// Menuepunkt Community zaehlte schon gesehene Hinweise erneut.
///
/// Ablage: die UserDefaults des Containers wie bisher und zusaetzlich der iCloud-Schluessel-Wert-Speicher (Berechtigung
/// `com.apple.developer.ubiquity-kvstore-identifier` ist in UniFlow.entitlements schon gesetzt; iPad und Mac teilen ihn,
/// weil Team und Bundle-ID gleich sind). Kein neuer CloudKit-Datensatztyp, also keine Schema-Aenderung in Production.
///
/// Regeln:
/// - Lesen: steht der Schluessel in iCloud, gilt dieser Wert (und wird lokal uebernommen, damit es ohne iCloud weitergeht);
///   sonst der lokale Wert, und ein vorhandener lokaler Wert wird einmal nach iCloud gespiegelt (Bestand von vor Build 29:
///   das iPad bringt seine Beitritte und Lerngruppen beim ersten Lesen mit).
/// - Schreiben: lokal und in iCloud; leere Listen werden als leere Liste geschrieben (nicht entfernt), damit ein Austritt
///   auf dem Mac auf dem iPad nicht aus dessen lokalem Stand zurueckkommt.
/// - Gleichzeitige Aenderungen auf zwei Geraeten: je Schluessel gewinnt der spaetere Schreiber (Regel des
///   Schluessel-Wert-Speichers). Fuer diese Listen selten und unkritisch (erneut beitreten genuegt).
/// - Ohne iCloud (`cloud == nil`: Tests, kein iCloud-Konto) genau das bisherige Verhalten.
public final class CommunitySharedState: @unchecked Sendable {
    /// Lokale Schluessel (UserDefaults, unveraendert) -> kurze Kennung im Schluessel-Wert-Speicher (hoechstens 64 Byte je Schluessel)
    public static let shortKeys: [String: String] = [
        "uniflow.community.joined": "j",
        "uniflow.community.groups": "g",
        "uniflow.community.blocked": "b",
        "uniflow.solution.displayName": "n",
        "uniflow.community.corrections.ignored": "ci",
        "uniflow.community.corrections.seen": "cs",
    ]
    /// Grenze des Schluessel-Wert-Speichers je Schluessel (Apple: 64 Byte UTF-8)
    public static let maxKeyBytes = 64
    /// so gross wird ein Wert hoechstens gespiegelt (Apple: 1 MB gesamt); groessere bleiben nur lokal
    public static let maxValueBytes = 64 * 1024

    private let defaults: UserDefaults?
    private let cloud: UbiquitousValueStore?
    private let scope: String
    private let lock = NSLock()

    /// `scope`: Kennung des Containers (`DataContainerKey.identifier`, aus Nutzer und Hochschule, auf iPad und Mac gleich)
    public init(defaults: UserDefaults?, cloud: UbiquitousValueStore?, scope: UUID) {
        self.defaults = defaults
        self.cloud = cloud
        self.scope = scope.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Schluessel im Schluessel-Wert-Speicher; nil fuer Schluessel, die nur lokal bleiben
    public func cloudKey(_ key: String) -> String? {
        Self.shortKeys[key].map { "cs1." + scope + "." + $0 }
    }

    public var isMirrored: Bool { cloud != nil }

    // MARK: Lesen und Schreiben

    public func object(forKey key: String) -> Any? {
        lock.withLock {
            let local = defaults?.object(forKey: key)
            guard let cloud, let ck = cloudKey(key) else { return local }
            if let remote = cloud.object(forKey: ck) {
                if !Self.same(remote, local) { defaults?.set(remote, forKey: key) }
                return remote
            }
            if let local, Self.fits(local) {                        // Bestand des Geraets einmal mitnehmen
                cloud.set(local, forKey: ck)
                cloud.synchronize()
            }
            return local
        }
    }

    public func set(_ value: Any?, forKey key: String) {
        lock.withLock {
            defaults?.set(value, forKey: key)
            guard let cloud, let ck = cloudKey(key) else { return }
            if let value, Self.fits(value) { cloud.set(value, forKey: ck) } else if value == nil { cloud.removeObject(forKey: ck) }
            cloud.synchronize()
        }
    }

    public func string(forKey key: String) -> String? { object(forKey: key) as? String }
    public func stringArray(forKey key: String) -> [String]? { (object(forKey: key) as? [Any])?.compactMap { $0 as? String } }
    public func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }

    // MARK: Hilfen

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x as NSObject, y as NSObject): return x.isEqual(y)
        default: return false
        }
    }

    static func fits(_ value: Any) -> Bool {
        guard PropertyListSerialization.propertyList(value, isValidFor: .binary),
              let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { return false }
        return data.count <= maxValueBytes
    }
}

/// Name und Kennung dieses Geraets beim StudiNow-Konto (Liste der Geraete in den Einstellungen und auf der Website).
/// Auf dem Mac meldet `UIDevice` dieselben Werte wie ein iPad ("iPad"): ohne Unterscheidung standen iPad und Mac des
/// Inhabers als zwei gleich benannte "iPad" in der Geraeteliste, und welches abzumelden ist, war nicht zu erkennen.
public enum AccountDevice {
    /// Anzeigename: auf dem Mac "Mac", wenn das System nur die Geraeteart nennt (ab iPadOS 16 ohne Berechtigung immer)
    public static func name(systemName: String, model: String, isMac: Bool) -> String {
        let raw = systemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMac else { return raw.isEmpty ? model : raw }
        let generic: Set<String> = ["", "ipad", "iphone", model.lowercased()]
        return generic.contains(raw.lowercased()) ? "Mac" : raw
    }

    /// Praefix neuer Geraete-Kennungen (vorhandene bleiben, wie sie sind)
    public static func idPrefix(isMac: Bool) -> String { isMac ? "mac-" : "ipad-" }

    /// Betriebssystem fuer Diagnose und Supportmail ("iPadOS 26.1" bzw. "macOS (App fuer iPad) 26.1")
    public static func systemLabel(version: String, isMac: Bool) -> String {
        isMac ? "macOS (App für iPad) \(version)" : "iPadOS \(version)"
    }
}
