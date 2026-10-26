import Security
import UniFlowCore
import XCTest
@testable import UniFlow

/// Gemerkte Zugangsdaten je Hochschule im Schluesselbund (eigener Test-Dienstname, erfundene Werte).
final class UniversityCredentialTests: XCTestCase {
    private var service = ""
    private var suite = ""
    private var keychain: UniversityKeychain!
    private var defaults: UserDefaults!
    private var store: UniversityCredentialStore!

    override func setUp() {
        super.setUp()
        service = "de.uniflow.ai.university.test.\(UUID().uuidString)"
        suite = "uniflow.tests.unicreds.\(UUID().uuidString)"
        keychain = UniversityKeychain(service: service)
        defaults = UserDefaults(suiteName: suite)
        store = UniversityCredentialStore(secrets: keychain, defaults: defaults)
    }

    override func tearDown() {
        keychain.accounts().forEach(keychain.remove)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private let luhUser = UniversityCredential(user: "ab1-xyz", password: "Test-Passwort 1")
    private let hiUser = UniversityCredential(user: "testnutzer", password: "pw#2 äöü")

    func testPerUniversityAndServiceWithoutFallback() {
        XCTAssertTrue(store.save(luhUser, .luh, service: "studip"))
        XCTAssertTrue(store.save(hiUser, .hildesheim, service: "cas"))
        XCTAssertEqual(store.credential(.luh, service: "studip"), luhUser)
        XCTAssertEqual(store.credential(.hildesheim, service: "cas"), hiUser)
        XCTAssertNil(store.credential(.luh, service: "qis"), "anderer Dienst derselben Uni: nichts")
        XCTAssertEqual(store.prefillCredential(.luh, service: "qis"), luhUser, "nur zum Vorausfuellen: QIS mit der LUH-ID aus Stud.IP")
        XCTAssertNil(store.prefillCredential(.hildesheim, service: "studip"))
        XCTAssertNil(store.credential(.luh, service: "cas"), "Dienst der anderen Uni: kein Rueckfall")
        XCTAssertNil(store.credential(.hildesheim, service: "studip"))
        XCTAssertFalse(store.save(hiUser, .luh, service: "cas"), "fremder Dienst wird nicht gespeichert")
        XCTAssertEqual(Set(keychain.accounts()), ["luh.studip.user", "luh.studip.password", "hildesheim.cas.user", "hildesheim.cas.password"])
        XCTAssertEqual(keychain.read("hildesheim.cas.password"), "pw#2 äöü")
    }

    func testKeychainOnlyThisDeviceWhenUnlockedNotSynced() throws {
        XCTAssertTrue(store.save(hiUser, .hildesheim, service: "cas"), "Schluesselbund nicht beschreibbar – App mit Signatur bauen (CODE_SIGN_IDENTITY=-)")
        for account in ["hildesheim.cas.user", "hildesheim.cas.password"] {
            let a = try XCTUnwrap(keychain.attributes(account))
            XCTAssertEqual(a.accessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String, account)
            XCTAssertNotEqual(a.synchronizable, true, account)
        }
    }

    func testDeleteOnlyOneUniversity() {
        store.save(luhUser, .luh, service: "studip")
        store.save(luhUser, .luh, service: "qis")
        store.save(hiUser, .hildesheim, service: "cas")
        keychain.write("token-wert-erfunden", account: "hildesheim.learnweb.token")      // kuenftiger Eintrag mit Praefix
        store.deleteAll(for: .luh)
        XCTAssertNil(store.credential(.luh, service: "studip"))
        XCTAssertNil(store.credential(.luh, service: "qis"))
        XCTAssertEqual(store.credential(.hildesheim, service: "cas"), hiUser, "andere Uni bleibt")
        store.deleteAll(for: .hildesheim)
        XCTAssertNil(store.credential(.hildesheim, service: "cas"))
        XCTAssertNil(keychain.read("hildesheim.learnweb.token"), "alles mit dem Praefix der Uni")

        store.save(luhUser, .luh, service: "studip")
        store.save(hiUser, .hildesheim, service: "cas")
        store.deleteAll()                                                                // Konto loeschen
        XCTAssertTrue(keychain.accounts().isEmpty)
    }

    func testRememberSwitchDefaultsOnAndOffDeletes() {
        XCTAssertTrue(store.remember(.hildesheim, service: "cas"), "Standard: an")
        store.save(hiUser, .hildesheim, service: "cas")
        store.save(luhUser, .luh, service: "studip")
        store.setRemember(false, .hildesheim, service: "cas")
        XCTAssertFalse(store.remember(.hildesheim, service: "cas"))
        XCTAssertNil(store.credential(.hildesheim, service: "cas"), "aus = sofort entfernt")
        XCTAssertEqual(store.credential(.luh, service: "studip"), luhUser)
        XCTAssertTrue(store.remember(.luh, service: "studip"))
        store.setRemember(true, .hildesheim, service: "cas")
        XCTAssertTrue(store.remember(.hildesheim, service: "cas"))
    }

    func testNothingHalfStoredAndEmptyNeverStored() {
        final class FailingPassword: UniversitySecretStoring {
            var values: [String: String] = [:]
            func read(_ account: String) -> String? { values[account] }
            func write(_ value: String, account: String) -> Bool {
                guard !account.hasSuffix(".password") else { return false }
                values[account] = value
                return true
            }
            func remove(_ account: String) { values[account] = nil }
            func accounts() -> [String] { Array(values.keys) }
        }
        let failing = FailingPassword()
        let s = UniversityCredentialStore(secrets: failing, defaults: defaults)
        XCTAssertFalse(s.save(hiUser, .hildesheim, service: "cas"))
        XCTAssertTrue(failing.values.isEmpty, "kein Benutzername ohne Passwort")
        XCTAssertFalse(store.save(UniversityCredential(user: "", password: "x"), .luh, service: "studip"))
        XCTAssertFalse(store.save(UniversityCredential(user: "x", password: ""), .luh, service: "studip"))
        XCTAssertTrue(keychain.accounts().isEmpty)
    }

    /// 236: Teilfehler beim Ueberschreiben: das alte Paar kommt zurueck; laesst sich auch das nicht vollstaendig
    /// schreiben, bleibt nichts (nie Benutzername neu mit Passwort alt)
    func testPartialFailureRollsBackToThePreviousPair() {
        final class Flaky: UniversitySecretStoring {
            var values: [String: String] = [:]
            /// Werte, deren Schreiben scheitert
            var rejects: Set<String> = []
            var writes: [String] = []
            func read(_ account: String) -> String? { values[account] }
            func write(_ value: String, account: String) -> Bool {
                writes.append(account)
                guard !rejects.contains(value) else { return false }
                values[account] = value
                return true
            }
            func remove(_ account: String) { values[account] = nil }
            func accounts() -> [String] { Array(values.keys) }
        }
        let flaky = Flaky()
        let s = UniversityCredentialStore(secrets: flaky, defaults: defaults)
        XCTAssertTrue(s.save(hiUser, .hildesheim, service: "cas"))
        let newer = UniversityCredential(user: "testnutzer-neu", password: "Neu-Pw-9")
        flaky.rejects = ["Neu-Pw-9"]                                   // Benutzername geht, Passwort scheitert
        XCTAssertFalse(s.save(newer, .hildesheim, service: "cas"))
        XCTAssertEqual(s.credential(.hildesheim, service: "cas"), hiUser, "altes Paar zurueck")
        flaky.rejects = ["testnutzer-neu"]                              // schon der Benutzername scheitert
        XCTAssertFalse(s.save(newer, .hildesheim, service: "cas"))
        XCTAssertEqual(s.credential(.hildesheim, service: "cas"), hiUser)
        // Rueckschreiben scheitert ebenfalls (Schluesselbund waehrenddessen gesperrt): nichts Halbes bleibt liegen
        flaky.rejects = ["Neu-Pw-9", hiUser.password]
        XCTAssertFalse(s.save(newer, .hildesheim, service: "cas"))
        XCTAssertNil(s.credential(.hildesheim, service: "cas"))
        XCTAssertNil(flaky.values["hildesheim.cas.user"], "kein Benutzername ohne Passwort")
        XCTAssertNil(flaky.values["hildesheim.cas.password"])
        // ohne vorheriges Paar: wie bisher nichts
        flaky.rejects = ["Neu-Pw-9"]
        XCTAssertFalse(s.save(newer, .luh, service: "studip"))
        XCTAssertNil(flaky.values["luh.studip.user"])
    }

    func testCredentialNeverInDescriptions() {
        for text in [String(describing: hiUser), String(reflecting: hiUser), "\(hiUser)"] {
            XCTAssertFalse(text.contains("testnutzer") || text.contains("pw#2"), text)
        }
        XCTAssertTrue(Mirror(reflecting: hiUser).children.isEmpty)
    }

    func testRememberTextIsHonest() {
        let on = UniversityRememberBar.explanation(remember: true, login: "Stud.IP · LUH")
        XCTAssertTrue(on.contains("nur im Schlüsselbund dieses iPads"))
        XCTAssertTrue(on.contains("nie auf einem Server"))
        XCTAssertTrue(on.contains("anmelden tippst du selbst"))
        XCTAssertTrue(UniversityRememberBar.explanation(remember: false, login: "Stud.IP · LUH").contains("entfernt"))
        let qis = UniversityRememberBar.explanation(remember: true, login: "QIS · LUH", fallback: "Stud.IP")
        XCTAssertTrue(qis.contains("Stud.IP-Anmeldung vor"), "Rueckfall wird genannt")
        let off = UniversityRememberBar.explanation(remember: false, login: "QIS · LUH", fallback: "Stud.IP")
        XCTAssertFalse(off.contains("Stud.IP"), "Schalter aus: auch kein Rueckfall")
        XCTAssertTrue(off.contains("füllt nichts vor"))
    }

    // MARK: Neuinstallation

    func testReinstallRemovesRememberedCredentials() {
        XCTAssertTrue(store.save(luhUser, .luh, service: "studip"))
        XCTAssertTrue(store.save(hiUser, .hildesheim, service: "cas"))
        keychain.write("token-wert-erfunden", account: "hildesheim.learnweb.token")
        XCTAssertTrue(defaults.bool(forKey: UniversityCredentialStore.installedKey))
        XCTAssertEqual(UniversityCredentialStore(secrets: keychain, defaults: defaults).credential(.luh, service: "studip"), luhUser,
                       "normaler Neustart: alles bleibt")

        // App geloescht und neu installiert (auch von einer anderen Person): UserDefaults leer, Schluesselbund noch da
        let freshSuite = "\(suite).neu"
        let fresh = UserDefaults(suiteName: freshSuite)!
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        let again = UniversityCredentialStore(secrets: keychain, defaults: fresh)
        XCTAssertTrue(again.remember(.luh, service: "studip"), "Schalter wieder Standard an")
        XCTAssertNil(again.credential(.luh, service: "studip"), "nichts von der alten Installation vorausfuellen")
        XCTAssertNil(again.prefillCredential(.luh, service: "qis"))
        XCTAssertNil(again.credential(.hildesheim, service: "cas"))
        XCTAssertTrue(keychain.accounts().isEmpty, "ganzer Dienst geleert, auch unbekannte Eintraege")
        XCTAssertTrue(fresh.bool(forKey: UniversityCredentialStore.installedKey))

        // danach ein normaler Start: Neues bleibt
        XCTAssertTrue(again.save(luhUser, .luh, service: "studip"))
        XCTAssertEqual(UniversityCredentialStore(secrets: keychain, defaults: fresh).credential(.luh, service: "studip"), luhUser)
    }

    func testLeftoversAreNeverReadWhileTheyCannotBeRemoved() {
        // z. B. Schluesselbund noch gesperrt: nichts lesen, nichts speichern, Merker erst nach dem Leeren
        final class Locked: UniversitySecretStoring {
            var values = ["luh.studip.user": "alt-nutzer", "luh.studip.password": "alt-passwort"]
            var locked = true
            func read(_ account: String) -> String? { values[account] }
            func write(_ value: String, account: String) -> Bool { values[account] = value; return true }
            func remove(_ account: String) { if !locked { values[account] = nil } }
            func accounts() -> [String] { Array(values.keys) }
            func removeAll() -> Bool {
                guard !locked else { return false }
                values.removeAll()
                return true
            }
        }
        let secrets = Locked()
        let freshSuite = "\(suite).gesperrt"
        let fresh = UserDefaults(suiteName: freshSuite)!
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        let s = UniversityCredentialStore(secrets: secrets, defaults: fresh)
        XCTAssertNil(s.credential(.luh, service: "studip"))
        XCTAssertFalse(s.save(luhUser, .luh, service: "qis"))
        XCTAssertFalse(fresh.bool(forKey: UniversityCredentialStore.installedKey))
        secrets.locked = false
        XCTAssertNil(s.credential(.luh, service: "studip"), "beim naechsten Zugriff geleert, nicht gelesen")
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertTrue(fresh.bool(forKey: UniversityCredentialStore.installedKey))
    }
}
