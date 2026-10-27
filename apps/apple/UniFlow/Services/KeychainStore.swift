import Foundation
import Security

/// Die eine Umsetzung des Schluesselbunds der App (generic password): jeder Eintrag unter einem festen Dienst, mit
/// ausdruecklicher Schutzklasse, nur dieses Geraet, nie synchronisiert; Fehler beim Schreiben werden gemeldet.
/// Darauf bauen Konto und PIN (`Keychain`), das Stud.IP-Sitzungs-Cookie (`StudIPCookieStore`) und der
/// Learnweb-Schluessel (`UniversityKeychain`) auf (vorher drei eigene SecItem-Umsetzungen; Konto und PIN ohne Dienst und
/// mit Backup auf andere Geraete). Hochschul-Passwoerter legt die App nie ab (die merkt nur das System).
struct KeychainStore: Sendable {
    let service: String
    /// Schutzklasse (`kSecAttrAccessible…ThisDeviceOnly`), als Text fuer Sendable
    let accessible: String

    init(service: String, accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) {
        self.service = service
        self.accessible = accessible as String
    }

    struct Failure: LocalizedError, Equatable {
        let status: OSStatus
        var errorDescription: String? { "Schlüsselbund-Fehler \(status)" }
    }

    private func query(_ account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    func data(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func string(_ account: String) -> String? { data(account).flatMap { String(data: $0, encoding: .utf8) } }

    func write(_ data: Data, account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessible
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func write(_ value: String, account: String) throws { try write(Data(value.utf8), account: account) }

    func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }

    /// Ein Aufruf fuer den ganzen Dienst; "nichts da" gilt als Erfolg, ein gesperrter Schluesselbund nicht
    @discardableResult
    func removeAll() -> Bool {
        let status = SecItemDelete(query(nil) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func accounts() -> [String] { accountList() ?? [] }

    /// Namen aller Eintraege dieses Dienstes; "nichts da" ist eine leere Liste, nil heisst: der Schluesselbund kann sie
    /// gerade nicht nennen (z. B. gesperrt)
    func accountList() -> [String]? {
        var q = query(nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { return nil }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Schutzklasse und Synchronisation eines Eintrags (fuer Tests)
    func attributes(_ account: String) -> (accessible: String?, synchronizable: Bool?)? {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let a = out as? [String: Any] else { return nil }
        return (a[kSecAttrAccessible as String] as? String, (a[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue)
    }

    // MARK: Eintraege ohne Dienst (bis 26.10.2026: Konto und PIN)

    /// Alter Eintrag ohne Dienst (nur solche: ein Eintrag mit Dienst gehoert jemand anderem) und dessen Inhalt
    static func legacyData(account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecReturnAttributes as String: true, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return nil }
        return items.first { (($0[kSecAttrService as String] as? String) ?? "").isEmpty }?[kSecValueData as String] as? Data
    }

    /// Alten Eintrag ohne Dienst entfernen (nur diesen, nicht gleich benannte anderer Dienste)
    static func removeLegacy(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                kSecAttrService as String: ""]
        SecItemDelete(q as CFDictionary)
    }
}
