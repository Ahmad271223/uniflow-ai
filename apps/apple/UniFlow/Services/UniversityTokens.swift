import Foundation
import Security
import UniFlowCore

// Schluessel der Hochschuldienste je Apple-Nutzer und Hochschule im Schluesselbund, derzeit nur der Learnweb-Schluessel
// aus dem Moodle-SSO der Uni Hildesheim. Er ist die Verbindung selbst (wie ein Sitzungs-Cookie), kein Passwort.
//
// Hochschul-Passwoerter merkt sich nur das System, nie UniFlow (Entscheidung des Inhabers, 27.10.2026). Bis dahin
// merkte die App mit dem Schalter "Auf diesem iPad merken" Benutzername und Passwort selbst im Schluesselbund und
// fuellte sie per Skript vor; das gibt es nicht mehr. Die Anmeldeseiten laufen in einer WKWebView ohne eigene Skripte
// (`StudIPWebView.loginConfiguration`), dort bietet iOS sein Passwort-Autofill aus dem (iCloud-)Schluesselbund an.
// Bestandsnutzer: `UniversityPasswordCleanup` loescht die frueher gemerkten Eintraege einmal.
//
// Schluesselbund: eigener Dienst `DataContainerKey.keychainService` ("de.uniflow.ai.university"), Eintrag je Nutzer,
// Hochschule und Dienst ("<nutzer>.hildesheim.learnweb.token"); die Namen bildet nur der Kern
// (`UniversityProfile.tokenKeychainAccount`). kSecAttrAccessibleWhenUnlockedThisDeviceOnly, nicht synchronisiert (nicht
// in iCloud, nicht auf andere Geraete). Kein Rueckfall auf die andere Hochschule. Nach einer Neuinstallation (Merker in
// den UserDefaults fehlt) wird der ganze Dienst geleert, bevor etwas gelesen wird.
// Docs: docs/SICHERHEITSKONZEPT-KONTEN.md, Abschnitt 1a.

/// Schluesselbund-Zugriff; Tests verwenden einen eigenen Dienstnamen bzw. einen Speicher im Arbeitsspeicher.
protocol UniversitySecretStoring {
    func read(_ account: String) -> String?
    @discardableResult func write(_ value: String, account: String) -> Bool
    func remove(_ account: String)
    /// alle Eintraege dieses Dienstes (leer, wenn der Schluesselbund sie nicht nennen kann)
    func accounts() -> [String]
    /// alle Eintraege dieses Dienstes; nil, wenn der Schluesselbund sie gerade nicht nennen kann (z. B. gesperrt).
    /// Fuer Aufraeumen, das nur mit sicherem Stand als erledigt gelten darf.
    func readableAccounts() -> [String]?
    /// alle Eintraege dieses Dienstes entfernen (Neuinstallation); false, wenn das nicht sicher gelungen ist
    func removeAll() -> Bool
}

extension UniversitySecretStoring {
    func readableAccounts() -> [String]? { accounts() }

    func removeAll() -> Bool {
        accounts().forEach(remove)
        return accounts().isEmpty
    }
}

/// Schluessel im Schluesselbund (`KeychainStore`): eigener Dienst, nur dieses Geraet, nur entsperrt lesbar
/// (`WhenUnlockedThisDeviceOnly`), nicht synchronisiert.
struct UniversityKeychain: UniversitySecretStoring {
    static let defaultService = DataContainerKey.keychainService
    let store: KeychainStore
    var service: String { store.service }

    init(service: String = UniversityKeychain.defaultService) {
        store = KeychainStore(service: service, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    func read(_ account: String) -> String? { store.string(account) }

    @discardableResult
    func write(_ value: String, account: String) -> Bool { (try? store.write(value, account: account)) != nil }

    func remove(_ account: String) { store.remove(account) }

    /// Ein Aufruf fuer den ganzen Dienst; "nichts da" gilt als Erfolg, ein gesperrter Schluesselbund nicht.
    func removeAll() -> Bool { store.removeAll() }

    func accounts() -> [String] { store.accounts() }

    func readableAccounts() -> [String]? { store.accountList() }

    /// Schutzklasse und Synchronisation eines Eintrags (fuer Tests)
    func attributes(_ account: String) -> (accessible: String?, synchronizable: Bool?)? { store.attributes(account) }
}

/// Schluessel je (Apple-Nutzer, Hochschule, Dienst). Ein Dienst ohne Schluessel oder einer anderen Hochschule hat nie
/// einen. Jeder Eintrag beginnt mit `userScope` (Kurzkennung des Apple-Nutzers, `DataContainerKey.userScope`): ein
/// anderes Konto auf demselben iPad sieht nichts davon. Benutzername und Passwort nimmt dieser Speicher nicht an.
final class UniversityTokenStore {
    private let secrets: UniversitySecretStoring
    private let defaults: UserDefaults
    /// Kurzkennung des Apple-Nutzers
    let userScope: String
    /// Speicher eines Containers: nur diese Hochschule (eine andere liest nichts, speichert nichts, loescht nichts)
    let onlyUniversity: UniversityKey?

    init(secrets: UniversitySecretStoring = UniversityKeychain(), defaults: UserDefaults = .standard, userScope: String,
         onlyUniversity: UniversityKey? = nil) {
        self.secrets = secrets
        self.defaults = defaults
        self.userScope = userScope
        self.onlyUniversity = onlyUniversity
        removeLeftoversOfEarlierInstallation()
    }

    /// gehoert die Hochschule zu diesem Speicher?
    private func allows(_ uni: UniversityKey) -> Bool { onlyUniversity == nil || onlyUniversity == uni }

    /// Teil nach dem Nutzer-Praefix; nil, wenn der Eintrag nicht zu diesem Nutzer gehoert
    private func unscoped(_ account: String) -> String? {
        let prefix = userScope + "."
        return account.hasPrefix(prefix) ? String(account.dropFirst(prefix.count)) : nil
    }

    /// Merker dieser Installation (UserDefaults verschwinden mit der App, der Schluesselbund nicht)
    static let installedKey = "uniflow.login.installed"

    /// Neuinstallation: Eintraege einer geloeschten App (womoeglich einer anderen Person auf demselben iPad) nie
    /// verwenden. Ohne Merker dieser Installation wird der ganze Dienst geleert, bevor irgendetwas gelesen wird; der
    /// Merker wird erst gesetzt, wenn das gelungen ist (gesperrter Schluesselbund: beim naechsten Mal erneut).
    @discardableResult
    private func removeLeftoversOfEarlierInstallation() -> Bool {
        guard !defaults.bool(forKey: Self.installedKey) else { return true }
        guard secrets.removeAll() else { return false }
        defaults.set(true, forKey: Self.installedKey)
        return true
    }

    /// Eintrag eines Schluessels (`UniversityProfile.tokenServices`, Hildesheim: "learnweb" ->
    /// "<nutzer>.hildesheim.learnweb.token"); nil fuer Dienste ohne Schluessel und fuer eine andere Hochschule
    private func tokenAccount(_ uni: UniversityKey, _ service: String) -> String? {
        guard allows(uni) else { return nil }
        return uni.profile.tokenKeychainAccount(service: service, userScope: userScope)
    }

    /// Schluessel eines Dienstes. Nie in Protokollen, Meldungen oder Adressen. "Daten dieser Hochschule löschen",
    /// Abmelden und `deleteAll(for:)` entfernen ihn. Nichts lesen, solange Reste einer frueheren Installation nicht
    /// entfernt werden konnten.
    func token(_ uni: UniversityKey, service: String) -> String? {
        guard removeLeftoversOfEarlierInstallation(), let a = tokenAccount(uni, service) else { return nil }
        return secrets.read(a)
    }

    @discardableResult
    func saveToken(_ value: String, _ uni: UniversityKey, service: String) -> Bool {
        guard !value.isEmpty, removeLeftoversOfEarlierInstallation(), let a = tokenAccount(uni, service) else { return false }
        return secrets.write(value, account: a)
    }

    func deleteToken(_ uni: UniversityKey, service: String) {
        guard let a = tokenAccount(uni, service) else { return }
        secrets.remove(a)
    }

    /// Abmelden (Uni Hildesheim), "Daten dieser Hochschule löschen": alles dieses Nutzers mit dem Praefix dieser
    /// Hochschule (auch kuenftige Eintraege); die andere Hochschule bleibt unberuehrt.
    func deleteAll(for uni: UniversityKey) {
        guard allows(uni) else { return }
        let p = uni.profile
        for account in secrets.accounts() where unscoped(account).map(p.ownsKeychainAccount) == true { secrets.remove(account) }
    }

    /// Konto loeschen: alle Eintraege dieses Nutzers (der Speicher eines Containers nur die seiner Hochschule).
    func deleteAll() {
        if let onlyUniversity { return deleteAll(for: onlyUniversity) }
        for account in secrets.accounts() where unscoped(account) != nil { secrets.remove(account) }
    }
}

/// Einmalig beim ersten Start dieser Fassung (Bestandsnutzer, Entscheidung des Inhabers vom 27.10.2026): alle
/// Benutzernamen und Passwoerter, die die App frueher mit "Auf diesem iPad merken" selbst gemerkt hat, aus dem
/// Schluesselbund entfernen - fuer alle Nutzer und Hochschulen dieses iPads, auch Eintraege ohne Nutzer aus der Zeit
/// vor den Containern (`UniversityProfile.isRetiredLoginSecret`). Learnweb-Schluessel ("….learnweb.token"),
/// Stud.IP-Sitzungen (eigener Dienst) und die Webdaten der Anmeldeansichten bleiben. Dazu die Schalter
/// "uniflow.login.remember.…". Erledigt erst, wenn der Schluesselbund danach sicher keinen solchen Eintrag mehr nennt;
/// sonst (z. B. gesperrt beim Start im Hintergrund) beim Wechsel in den Vordergrund, beim Oeffnen eines Containers
/// bzw. beim naechsten Start erneut (`ContainerManager.removeRememberedPasswords`).
enum UniversityPasswordCleanup {
    /// Merker in den UserDefaults der App: erledigt
    static let doneKey = "uniflow.login.passwords.removed"
    /// Schalter "Auf diesem iPad merken" je Hochschule und Dienst (mit und ohne Nutzer)
    static let rememberPrefix = "uniflow.login.remember."

    @discardableResult
    static func run(secrets: UniversitySecretStoring, defaults: UserDefaults) -> Bool {
        if defaults.bool(forKey: doneKey) { return true }
        guard let before = secrets.readableAccounts() else { return false }
        before.filter(UniversityProfile.isRetiredLoginSecret).forEach(secrets.remove)
        guard let after = secrets.readableAccounts(), !after.contains(where: UniversityProfile.isRetiredLoginSecret) else { return false }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(rememberPrefix) { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: doneKey)
        return true
    }
}
