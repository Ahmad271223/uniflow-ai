import XCTest
@testable import UniFlow

/// Die PIN liegt im Schluesselbund; ohne Signatur (CODE_SIGNING_ALLOWED=NO) fehlt die Berechtigung und sie geht verloren.
final class KeychainTests: XCTestCase {

    func testRoundTrip() {
        let key = "uniflow.test.\(UUID().uuidString)"
        Keychain.set("123456", for: key)
        defer { Keychain.delete(key) }
        XCTAssertEqual(Keychain.get(key), "123456", "Schluesselbund nicht beschreibbar – App mit Signatur bauen (CODE_SIGN_IDENTITY=-)")
        Keychain.delete(key)
        XCTAssertNil(Keychain.get(key))
    }
}
