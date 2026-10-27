import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Learnweb-Schluessel je Nutzer und Hochschule im Schluesselbund und die einmalige Loeschung der Benutzernamen und
/// Passwoerter, die fruehere Fassungen der App selbst gemerkt haben (Entscheidung des Inhabers, 27.10.2026: Passwoerter
/// merkt nur das System). Eigener Test-Dienstname, erfundene Werte.
final class UniversityTokenStoreTests: XCTestCase {
    private var service = ""
    private var suite = ""
    private var keychain: UniversityKeychain!
    private var defaults: UserDefaults!
    private let ada = DataContainerKey.userScope("001234.erfunden-ada")
    private let bob = DataContainerKey.userScope("009876.erfunden-bob")

    override func setUp() {
        super.setUp()
        service = "de.uniflow.ai.university.test.\(UUID().uuidString)"
        suite = "uniflow.tests.unitokens.\(UUID().uuidString)"
        keychain = UniversityKeychain(service: service)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        keychain.accounts().forEach(keychain.remove)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store(_ scope: String, _ uni: UniversityKey? = nil) -> UniversityTokenStore {
        UniversityTokenStore(secrets: keychain, defaults: defaults, userScope: scope, onlyUniversity: uni)
    }

    // MARK: Learnweb-Schluessel

    func testTokenPerUserAndUniversityWithoutFallback() {
        let s = store(ada)
        XCTAssertTrue(s.saveToken("Schluessel-erfunden-1", .hildesheim, service: "learnweb"),
                      "Schluesselbund nicht beschreibbar – App mit Signatur bauen (CODE_SIGN_IDENTITY=-)")
        XCTAssertEqual(s.token(.hildesheim, service: "learnweb"), "Schluessel-erfunden-1")
        XCTAssertEqual(keychain.accounts(), ["\(ada).hildesheim.learnweb.token"])
        XCTAssertFalse(s.saveToken("x", .luh, service: "learnweb"), "die LUH hat keinen Schluessel")
        XCTAssertFalse(s.saveToken("x", .hildesheim, service: "cas"), "Anmeldedienst: kein Eintrag, also auch kein Passwort")
        XCTAssertFalse(s.saveToken("x", .luh, service: "studip"))
        XCTAssertFalse(s.saveToken("", .hildesheim, service: "learnweb"), "leer wird nie gespeichert")
        XCTAssertNil(store(bob).token(.hildesheim, service: "learnweb"), "anderes Konto auf demselben iPad sieht nichts")
        let luh = store(ada, .luh)
        XCTAssertNil(luh.token(.hildesheim, service: "learnweb"), "LUH-Container liest Hildesheim nicht")
        XCTAssertFalse(luh.saveToken("x", .hildesheim, service: "learnweb"), "und schreibt dort nichts")
        luh.deleteAll()
        XCTAssertEqual(s.token(.hildesheim, service: "learnweb"), "Schluessel-erfunden-1", "und loescht dort nichts")
        s.deleteToken(.hildesheim, service: "learnweb")
        XCTAssertTrue(keychain.accounts().isEmpty)
    }

    func testTokenOnlyThisDeviceWhenUnlockedNotSynced() throws {
        XCTAssertTrue(store(ada).saveToken("Schluessel-erfunden-2", .hildesheim, service: "learnweb"),
                      "Schluesselbund nicht beschreibbar – App mit Signatur bauen (CODE_SIGN_IDENTITY=-)")
        let a = try XCTUnwrap(keychain.attributes("\(ada).hildesheim.learnweb.token"))
        XCTAssertEqual(a.accessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertNotEqual(a.synchronizable, true)
    }

    func testDeleteOnlyOneUniversityAndOnlyOneUser() {
        XCTAssertTrue(store(ada).saveToken("A", .hildesheim, service: "learnweb"))
        XCTAssertTrue(store(bob).saveToken("B", .hildesheim, service: "learnweb"))
        XCTAssertTrue(keychain.write("kuenftig", account: "\(ada).luh.kuenftig.token"))   // kuenftiger Eintrag mit Praefix der LUH
        store(ada).deleteAll(for: .luh)                                                   // "Daten dieser Hochschule löschen" (LUH)
        XCTAssertNil(keychain.read("\(ada).luh.kuenftig.token"))
        XCTAssertEqual(store(ada).token(.hildesheim, service: "learnweb"), "A", "andere Uni bleibt")
        store(ada, .hildesheim).deleteAll(for: .hildesheim)                               // Learnweb/LSF abmelden
        XCTAssertNil(store(ada).token(.hildesheim, service: "learnweb"))
        XCTAssertEqual(store(bob).token(.hildesheim, service: "learnweb"), "B", "anderes Konto bleibt")
        XCTAssertTrue(store(ada).saveToken("A2", .hildesheim, service: "learnweb"))
        store(ada).deleteAll()                                                            // Konto loeschen
        XCTAssertEqual(keychain.accounts(), ["\(bob).hildesheim.learnweb.token"])
    }

    // MARK: Neuinstallation

    func testReinstallRemovesLeftovers() {
        XCTAssertTrue(store(ada).saveToken("alt", .hildesheim, service: "learnweb"))
        XCTAssertTrue(defaults.bool(forKey: UniversityTokenStore.installedKey))
        XCTAssertEqual(store(ada).token(.hildesheim, service: "learnweb"), "alt", "normaler Neustart: alles bleibt")

        // App geloescht und neu installiert (auch von einer anderen Person): UserDefaults leer, Schluesselbund noch da
        let freshSuite = "\(suite).neu"
        let fresh = UserDefaults(suiteName: freshSuite)!
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        let again = UniversityTokenStore(secrets: keychain, defaults: fresh, userScope: ada)
        XCTAssertNil(again.token(.hildesheim, service: "learnweb"), "nichts von der alten Installation verwenden")
        XCTAssertTrue(keychain.accounts().isEmpty, "ganzer Dienst geleert, auch unbekannte Eintraege")
        XCTAssertTrue(fresh.bool(forKey: UniversityTokenStore.installedKey))
        XCTAssertTrue(again.saveToken("neu", .hildesheim, service: "learnweb"))
        XCTAssertEqual(UniversityTokenStore(secrets: keychain, defaults: fresh, userScope: ada).token(.hildesheim, service: "learnweb"), "neu")
    }

    func testLeftoversAreNeverReadWhileTheyCannotBeRemoved() {
        let secrets = LockedSecrets(["\(ada).hildesheim.learnweb.token": "alt-schluessel"])
        let freshSuite = "\(suite).gesperrt"
        let fresh = UserDefaults(suiteName: freshSuite)!
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        let s = UniversityTokenStore(secrets: secrets, defaults: fresh, userScope: ada)
        XCTAssertNil(s.token(.hildesheim, service: "learnweb"))
        XCTAssertFalse(s.saveToken("neu", .hildesheim, service: "learnweb"))
        XCTAssertFalse(fresh.bool(forKey: UniversityTokenStore.installedKey))
        secrets.locked = false
        XCTAssertNil(s.token(.hildesheim, service: "learnweb"), "beim naechsten Zugriff geleert, nicht gelesen")
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertTrue(fresh.bool(forKey: UniversityTokenStore.installedKey))
    }

    // MARK: Einmalige Loeschung der frueher von der App gemerkten Passwoerter (Bestandsnutzer)

    /// Schluesselbund und Schalter einer frueheren Fassung: zwei Konten, beide Hochschulen, Eintraege ohne Nutzer (vor
    /// den Containern) und ohne offenen Container, dazu die Learnweb-Schluessel
    private var earlierVersion: [String: String] {
        ["\(ada).luh.studip.user": "ab1-erfunden", "\(ada).luh.studip.password": "Pw-erfunden-1",
         "\(ada).luh.qis.user": "ab1-erfunden", "\(ada).luh.qis.password": "Pw-erfunden-2",
         "\(ada).hildesheim.cas.user": "testnutzer", "\(ada).hildesheim.cas.password": "Pw-erfunden-3",
         "\(bob).hildesheim.cas.user": "bob-erfunden", "\(bob).hildesheim.cas.password": "Pw-erfunden-4",
         "luh.studip.user": "alt", "luh.studip.password": "Pw-erfunden-alt",
         "u-ohne-anmeldung.luh.studip.password": "Pw-erfunden-ohne",
         "\(ada).hildesheim.learnweb.token": "Schluessel-ada", "\(bob).hildesheim.learnweb.token": "Schluessel-bob"]
    }

    private let rememberSwitches = ["uniflow.login.remember.u0123456789abcdef.luh.qis", "uniflow.login.remember.luh.studip",
                                    "uniflow.login.remember.hildesheim.cas"]

    private func seedEarlierVersion() {
        for (account, value) in earlierVersion {
            XCTAssertTrue(keychain.write(value, account: account), "Schluesselbund nicht beschreibbar – mit CODE_SIGN_IDENTITY=- bauen")
        }
        defaults.set(true, forKey: UniversityTokenStore.installedKey)                      // keine Neuinstallation
        for (i, key) in rememberSwitches.enumerated() { defaults.set(i % 2 == 0, forKey: key) }
        defaults.set("bleibt", forKey: "uniflow.login.rememberx")                           // anderer Schluessel, nur aehnlich
    }

    func testCleanupRemovesEveryRememberedPasswordAndKeepsTheLearnwebKeys() {
        seedEarlierVersion()
        XCTAssertTrue(UniversityPasswordCleanup.run(secrets: keychain, defaults: defaults))
        XCTAssertEqual(Set(keychain.accounts()), ["\(ada).hildesheim.learnweb.token", "\(bob).hildesheim.learnweb.token"],
                       "nur die Learnweb-Schluessel bleiben, fuer alle Konten")
        XCTAssertEqual(store(ada, .hildesheim).token(.hildesheim, service: "learnweb"), "Schluessel-ada")
        XCTAssertEqual(store(bob, .hildesheim).token(.hildesheim, service: "learnweb"), "Schluessel-bob")
        for key in rememberSwitches { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertEqual(defaults.string(forKey: "uniflow.login.rememberx"), "bleibt")
        XCTAssertTrue(defaults.bool(forKey: UniversityPasswordCleanup.doneKey))
        XCTAssertTrue(defaults.bool(forKey: UniversityTokenStore.installedKey), "keine Neuinstallation vorgetaeuscht")

        // einmalig: danach schaut die App nur noch auf den Merker (ein solcher Eintrag entsteht nie wieder)
        XCTAssertTrue(keychain.write("Pw-erfunden-spaeter", account: "\(ada).luh.studip.password"))
        XCTAssertTrue(UniversityPasswordCleanup.run(secrets: keychain, defaults: defaults))
        XCTAssertEqual(keychain.read("\(ada).luh.studip.password"), "Pw-erfunden-spaeter", "laeuft nur einmal")
    }

    func testCleanupOnAnEmptyKeychainIsDoneAtOnce() {
        XCTAssertEqual(keychain.readableAccounts(), [], "nichts da ist eine leere Liste, kein Fehler")
        XCTAssertTrue(UniversityPasswordCleanup.run(secrets: keychain, defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: UniversityPasswordCleanup.doneKey))
    }

    func testCleanupWaitsForAnUnlockedKeychain() {
        let secrets = LockedSecrets(["\(ada).luh.studip.password": "Pw-erfunden-1", "\(ada).hildesheim.learnweb.token": "k"])
        // gesperrt (z. B. Start im Hintergrund vor dem ersten Entsperren): nichts erledigt, nichts verloren
        XCTAssertFalse(UniversityPasswordCleanup.run(secrets: secrets, defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: UniversityPasswordCleanup.doneKey))
        XCTAssertEqual(secrets.values.count, 2)
        // Liste lesbar, Loeschen scheitert (waehrenddessen gesperrt): ebenfalls nicht erledigt
        secrets.locked = false
        secrets.removeFails = true
        XCTAssertFalse(UniversityPasswordCleanup.run(secrets: secrets, defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: UniversityPasswordCleanup.doneKey))
        // beim naechsten Versuch entsperrt
        secrets.removeFails = false
        XCTAssertTrue(UniversityPasswordCleanup.run(secrets: secrets, defaults: defaults))
        XCTAssertEqual(secrets.values, ["\(ada).hildesheim.learnweb.token": "k"])
        XCTAssertTrue(defaults.bool(forKey: UniversityPasswordCleanup.doneKey))
    }

    /// Erster Start der neuen Fassung: die Container-Verwaltung raeumt beim Anlegen auf, bevor ein Container offen ist;
    /// der Learnweb-Schluessel des Kontos gilt danach weiter.
    @MainActor
    func testFirstStartOfThisVersionCleansUpBeforeAnyContainerOpens() async throws {
        let bed = try ContainerTestBed(name: "passwoerter", clock: .fixed(berlin: "2026-10-27T09:00:00")!)
        addTeardownBlock { @MainActor in await bed.tearDown() }
        let me = DataContainerKey.userScope(bed.user)
        for (account, value) in ["\(me).luh.studip.user": "ab1-erfunden", "\(me).luh.studip.password": "Pw-erfunden-1",
                                 "\(me).hildesheim.cas.password": "Pw-erfunden-3", "luh.qis.password": "Pw-erfunden-alt",
                                 "\(me).hildesheim.learnweb.token": "Schluessel-erfunden"] {
            XCTAssertTrue(bed.keychain.write(value, account: account), "Schluesselbund nicht beschreibbar – mit CODE_SIGN_IDENTITY=- bauen")
        }
        bed.defaults.set(true, forKey: UniversityTokenStore.installedKey)
        bed.defaults.set(true, forKey: "uniflow.login.remember.\(me).hildesheim.cas")
        let m = bed.manager()
        XCTAssertNil(m.active)
        XCTAssertEqual(bed.keychain.accounts(), ["\(me).hildesheim.learnweb.token"])
        XCTAssertNil(bed.defaults.object(forKey: "uniflow.login.remember.\(me).hildesheim.cas"))
        XCTAssertTrue(bed.defaults.bool(forKey: UniversityPasswordCleanup.doneKey))
        let c = try bed.open(m, bed.account(.hildesheim))
        XCTAssertEqual(c.tokens.token(.hildesheim, service: "learnweb"), "Schluessel-erfunden", "Learnweb-Schluessel bleibt")
    }
}

/// Schluesselbund, der gesperrt sein kann (Liste nicht lesbar, Loeschen ohne Wirkung)
private final class LockedSecrets: UniversitySecretStoring {
    var values: [String: String]
    var locked = true
    var removeFails = false

    init(_ values: [String: String]) { self.values = values }

    func read(_ account: String) -> String? { locked ? nil : values[account] }
    func write(_ value: String, account: String) -> Bool {
        guard !locked else { return false }
        values[account] = value
        return true
    }
    func remove(_ account: String) { if !locked, !removeFails { values[account] = nil } }
    func accounts() -> [String] { locked ? [] : Array(values.keys) }
    func readableAccounts() -> [String]? { locked ? nil : Array(values.keys) }
    func removeAll() -> Bool {
        guard !locked, !removeFails else { return false }
        values.removeAll()
        return true
    }
}
