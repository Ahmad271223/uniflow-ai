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
        store.universityChanged(from: .hildesheim, to: .luh)
        XCTAssertNil(store.credential(.hildesheim, service: "cas"))
        XCTAssertNil(keychain.read("hildesheim.learnweb.token"), "alles mit dem Praefix der Uni")

        store.save(luhUser, .luh, service: "studip")
        store.save(hiUser, .hildesheim, service: "cas")
        store.universityChanged(from: .luh, to: .luh)
        XCTAssertNotNil(store.credential(.luh, service: "studip"), "kein Wechsel, nichts geloescht")
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
    }
}
