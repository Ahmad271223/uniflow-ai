import Foundation
import Security
import UniFlowCore

// Gemerkte Zugangsdaten je Apple-Nutzer, Hochschule und Dienst (Entscheidung des Inhabers, 25.10.2026): Nach der Wahl der
// Hochschule oeffnet die App deren Anmeldeseiten; wer den Schalter "Auf diesem iPad merken" an laesst, dessen
// Benutzername und Passwort legt die App beim Tippen auf "Anmelden" im Schluesselbund ab und fuellt sie beim
// naechsten Mal vor. Angemeldet wird nie automatisch.
//
// Schluesselbund: eigener Dienst "de.uniflow.ai.university", Eintrag je Nutzer, Hochschule und Dienst mit Praefix
// ("<nutzer>.luh.studip.user", "<nutzer>.hildesheim.cas.password"), kSecAttrAccessibleWhenUnlockedThisDeviceOnly, nicht
// synchronisiert (nicht in iCloud, nicht auf andere Geraete). Kein Rueckfall auf die andere Hochschule; innerhalb
// der LUH fuellt QIS ohne eigene Daten die LUH-ID aus Stud.IP vor (wie am PC, `prefillCredential`).
// Nach einer Neuinstallation (Merker in den UserDefaults fehlt) wird der ganze Dienst geleert, bevor etwas gelesen wird.
// Docs: docs/SICHERHEITSKONZEPT-KONTEN.md, Abschnitt "Gemerkte Hochschul-Zugangsdaten".

/// Benutzername und Passwort einer Anmeldeseite. In Beschreibungen geschwaerzt (nie im Protokoll).
struct UniversityCredential: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let user: String
    let password: String

    /// Grenzen gegen unsinnige Eingaben; leer wird nie gespeichert
    static let maxUser = 256
    static let maxPassword = 1024

    var isStorable: Bool {
        !user.isEmpty && !password.isEmpty && user.count <= Self.maxUser && password.count <= Self.maxPassword
    }

    var description: String { "UniversityCredential(user: ***, password: ***)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Schluesselbund-Zugriff; Tests verwenden einen eigenen Dienstnamen bzw. einen Speicher im Arbeitsspeicher.
protocol UniversitySecretStoring {
    func read(_ account: String) -> String?
    @discardableResult func write(_ value: String, account: String) -> Bool
    func remove(_ account: String)
    /// alle Eintraege dieses Dienstes (zum Loeschen je Hochschule)
    func accounts() -> [String]
    /// alle Eintraege dieses Dienstes entfernen (Neuinstallation); false, wenn das nicht sicher gelungen ist
    func removeAll() -> Bool
}

extension UniversitySecretStoring {
    func removeAll() -> Bool {
        accounts().forEach(remove)
        return accounts().isEmpty
    }
}

/// Generic-Password-Eintraege unter einem eigenen Dienst, nur dieses Geraet, nur entsperrt lesbar, nicht synchronisiert.
struct UniversityKeychain: UniversitySecretStoring {
    static let defaultService = "de.uniflow.ai.university"
    let service: String

    init(service: String = UniversityKeychain.defaultService) { self.service = service }

    private func query(_ account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func write(_ value: String, account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        var add = query(account)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }

    /// Ein Aufruf fuer den ganzen Dienst; "nichts da" gilt als Erfolg, ein gesperrter Schluesselbund nicht.
    func removeAll() -> Bool {
        let status = SecItemDelete(query(nil) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func accounts() -> [String] {
        var q = query(nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Schutzklasse und Synchronisation eines Eintrags (fuer Tests)
    func attributes(_ account: String) -> (accessible: String?, synchronizable: Bool?)? {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let a = out as? [String: Any] else { return nil }
        let sync = (a[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue
        return (a[kSecAttrAccessible as String] as? String, sync)
    }
}

/// Zugangsdaten je (Apple-Nutzer, Hochschule, Dienst). Ein Dienst, der nicht zur Hochschule gehoert, hat nie
/// Zugangsdaten. Mit `userScope` (Kurzkennung des Apple-Nutzers, `DataContainerKey.userScope`) beginnt jeder Eintrag
/// mit dieser Kennung ("u1a2b….luh.studip.user"): ein anderes Konto auf demselben iPad sieht nichts davon.
final class UniversityCredentialStore {
    /// Zugangsdaten des angemeldeten Nutzers (Container der gewaehlten Hochschule); ohne Anmeldung ein Speicher,
    /// der nichts findet und nichts behaelt, was jemandem gehoert
    static var standard: UniversityCredentialStore { ActiveContainer.current?.credentials ?? signedOut }
    private static let signedOut = UniversityCredentialStore(userScope: "u-ohne-anmeldung")

    private let secrets: UniversitySecretStoring
    private let defaults: UserDefaults
    /// Kurzkennung des Apple-Nutzers; nil nur fuer die alte Ablage ohne Nutzer (Umzug, Tests)
    let userScope: String?
    /// Speicher eines Containers: nur diese Hochschule (eine andere liest nichts, speichert nichts, loescht nichts)
    let onlyUniversity: UniversityKey?

    init(secrets: UniversitySecretStoring = UniversityKeychain(), defaults: UserDefaults = .standard, userScope: String? = nil,
         onlyUniversity: UniversityKey? = nil) {
        self.secrets = secrets
        self.defaults = defaults
        self.userScope = userScope
        self.onlyUniversity = onlyUniversity
        removeLeftoversOfEarlierInstallation()
    }

    /// gehoert die Hochschule zu diesem Speicher?
    private func allows(_ uni: UniversityKey) -> Bool { onlyUniversity == nil || onlyUniversity == uni }

    /// Eintrag im Schluesselbund: mit Nutzer-Praefix, sonst wie im Profil
    private func scoped(_ account: String) -> String { userScope.map { "\($0).\(account)" } ?? account }

    /// Teil nach dem Nutzer-Praefix; nil, wenn der Eintrag nicht zu diesem Nutzer gehoert
    private func unscoped(_ account: String) -> String? {
        guard let userScope else {
            // alte Ablage: nur Eintraege ohne Nutzer-Praefix (die beginnen mit dem Praefix einer Hochschule)
            return UniversityKey.allCases.contains { $0.profile.ownsKeychainAccount(account) } ? account : nil
        }
        let prefix = userScope + "."
        return account.hasPrefix(prefix) ? String(account.dropFirst(prefix.count)) : nil
    }

    /// Merker dieser Installation (UserDefaults verschwinden mit der App, der Schluesselbund nicht)
    static let installedKey = "uniflow.login.installed"

    /// Neuinstallation: Eintraege einer geloeschten App (womoeglich einer anderen Person auf demselben iPad) nie
    /// vorausfuellen. Ohne Merker dieser Installation wird der ganze Dienst geleert, bevor irgendetwas gelesen wird;
    /// der Merker wird erst gesetzt, wenn das gelungen ist (gesperrter Schluesselbund: beim naechsten Mal erneut).
    @discardableResult
    private func removeLeftoversOfEarlierInstallation() -> Bool {
        guard !defaults.bool(forKey: Self.installedKey) else { return true }
        guard secrets.removeAll() else { return false }
        defaults.set(true, forKey: Self.installedKey)
        return true
    }

    private func accounts(_ uni: UniversityKey, _ service: String) -> (user: String, password: String)? {
        guard allows(uni) else { return nil }
        let p = uni.profile
        guard let u = p.keychainAccount(service: service, field: "user"),
              let pw = p.keychainAccount(service: service, field: "password") else { return nil }
        return (scoped(u), scoped(pw))
    }

    /// Nichts lesen, solange Reste einer frueheren Installation nicht entfernt werden konnten.
    func credential(_ uni: UniversityKey, service: String) -> UniversityCredential? {
        guard removeLeftoversOfEarlierInstallation(), let a = accounts(uni, service), let user = secrets.read(a.user),
              let password = secrets.read(a.password) else { return nil }
        let c = UniversityCredential(user: user, password: password)
        return c.isStorable ? c : nil
    }

    func hasCredential(_ uni: UniversityKey, service: String) -> Bool { credential(uni, service: service) != nil }

    /// Zum Vorausfuellen: eigene Zugangsdaten des Dienstes, sonst die des Rueckfall-Dienstes derselben Hochschule
    /// (`UniversityLoginService.prefillFallback`, LUH: QIS -> Stud.IP wie `config.service_credentials` am PC), aber
    /// nur, solange "merken" fuer diesen Dienst an ist. Nie Daten einer anderen Hochschule.
    func prefillCredential(_ uni: UniversityKey, service: String) -> UniversityCredential? {
        if let own = credential(uni, service: service) { return own }
        guard remember(uni, service: service), let fallback = uni.profile.loginService(service)?.prefillFallback,
              fallback != service, uni.profile.loginService(fallback) != nil else { return nil }
        return credential(uni, service: fallback)
    }

    /// Speichert beide Felder; schlaegt ein Teil fehl, bleibt nichts Halbes liegen.
    @discardableResult
    func save(_ c: UniversityCredential, _ uni: UniversityKey, service: String) -> Bool {
        guard c.isStorable, removeLeftoversOfEarlierInstallation(), let a = accounts(uni, service) else { return false }
        guard secrets.write(c.user, account: a.user), secrets.write(c.password, account: a.password) else {
            delete(uni, service: service)
            return false
        }
        return true
    }

    func delete(_ uni: UniversityKey, service: String) {
        guard let a = accounts(uni, service) else { return }
        secrets.remove(a.user)
        secrets.remove(a.password)
    }

    /// Abmelden, Hochschule wechseln: alles mit dem Praefix dieser Hochschule (auch kuenftige Eintraege wie
    /// "hildesheim.learnweb.token"); die andere Hochschule bleibt unberuehrt.
    func deleteAll(for uni: UniversityKey) {
        guard allows(uni) else { return }
        let p = uni.profile
        for s in p.loginServices { delete(uni, service: s.key) }
        for account in secrets.accounts() where unscoped(account).map(p.ownsKeychainAccount) == true { secrets.remove(account) }
    }

    /// Gemerkte Zugangsdaten der bisherigen Hochschule entfernen. Der Wechsel in den Einstellungen ruft das nicht auf:
    /// Die Daten der anderen Hochschule (auch gemerkte Zugangsdaten) bleiben getrennt erhalten, bis "Daten dieser
    /// Hochschule löschen" sie entfernt (`ContainerManager.deleteUniversityData`).
    func universityChanged(from old: UniversityKey, to new: UniversityKey) {
        guard old != new else { return }
        deleteAll(for: old)
    }

    /// Konto loeschen: alle Hochschulen dieses Nutzers (mit Nutzer-Praefix auch kuenftige Eintraege), samt Schaltern.
    func deleteAll() {
        UniversityKey.allCases.forEach(deleteAll(for:))
        guard userScope != nil, onlyUniversity == nil else { return }
        for account in secrets.accounts() where unscoped(account) != nil { secrets.remove(account) }
        for uni in UniversityKey.allCases {
            for s in uni.profile.loginServices { defaults.removeObject(forKey: rememberKey(uni, s.key)) }
        }
    }

    /// Umzug aus der Zeit vor den Containern: Eintraege ohne Nutzer-Praefix ("luh.studip.user") und ihre Schalter
    /// gehoeren ab jetzt diesem Nutzer. Wiederholbar: was schon umgezogen ist, wird nicht ueberschrieben.
    func adoptEntriesWithoutUser() {
        guard userScope != nil, onlyUniversity == nil, removeLeftoversOfEarlierInstallation() else { return }
        let legacy = UniversityCredentialStore(secrets: secrets, defaults: defaults)
        for account in secrets.accounts() where legacy.unscoped(account) != nil {
            if secrets.read(scoped(account)) == nil, let value = secrets.read(account) {
                guard secrets.write(value, account: scoped(account)) else { continue }
            }
            secrets.remove(account)
        }
        for uni in UniversityKey.allCases {
            for s in uni.profile.loginServices {
                let old = Self.rememberKey(uni, s.key)
                guard let on = defaults.object(forKey: old) as? Bool else { continue }
                if defaults.object(forKey: rememberKey(uni, s.key)) == nil { defaults.set(on, forKey: rememberKey(uni, s.key)) }
                defaults.removeObject(forKey: old)
            }
        }
    }

    // MARK: Schalter "Auf diesem iPad merken" (Standard: an)

    /// Schalter ohne Nutzer (alte Ablage, Tests)
    static func rememberKey(_ uni: UniversityKey, _ service: String) -> String { "uniflow.login.remember.\(uni.rawValue).\(service)" }

    /// Schalter dieses Nutzers
    func rememberKey(_ uni: UniversityKey, _ service: String) -> String {
        userScope.map { "uniflow.login.remember.\($0).\(uni.rawValue).\(service)" } ?? Self.rememberKey(uni, service)
    }

    func remember(_ uni: UniversityKey, service: String) -> Bool {
        defaults.object(forKey: rememberKey(uni, service)) as? Bool ?? true
    }

    /// Aus: nichts mehr merken und die gespeicherten Zugangsdaten dieses Dienstes sofort entfernen.
    func setRemember(_ on: Bool, _ uni: UniversityKey, service: String) {
        guard allows(uni) else { return }
        defaults.set(on, forKey: rememberKey(uni, service))
        if !on { delete(uni, service: service) }
    }
}
