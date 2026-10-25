import XCTest
@testable import UniFlow

/// V1 ohne PC-Server: welcher Zustand eine Seite zeigt (Server / kein Server / Stud.IP verbunden).
@MainActor
final class NoServerStateTests: XCTestCase {

    func testServerWinsAlways() {
        // Entwicklungsmodus des Inhabers: mit Server bleibt alles wie bisher, egal wie Stud.IP steht
        for link in [StudIPLink.notConnected, .expired, .connected] {
            XCTAssertEqual(UFDataMode.resolve(hasServer: true, studIP: link), .server)
        }
        XCTAssertFalse(UFDataMode.server.showsConnectCard)
    }

    func testWithoutServer() {
        XCTAssertEqual(UFDataMode.resolve(hasServer: false, studIP: .notConnected), .connectStudIP)
        XCTAssertEqual(UFDataMode.resolve(hasServer: false, studIP: .expired), .reconnectStudIP)
        XCTAssertEqual(UFDataMode.resolve(hasServer: false, studIP: .connected), .empty)
    }

    func testConnectCardOnlyWhileStudIPMissing() {
        XCTAssertTrue(UFDataMode.connectStudIP.showsConnectCard)
        XCTAssertTrue(UFDataMode.reconnectStudIP.showsConnectCard)
        XCTAssertFalse(UFDataMode.empty.showsConnectCard)                // nach erfolgreicher Verbindung weg
    }

    func testLinkFromSyncPhase() {
        XCTAssertEqual(StudIPLink(.signedOut), .notConnected)
        XCTAssertEqual(StudIPLink(.needsLogin), .expired)
        XCTAssertEqual(StudIPLink(.idle), .connected)
        XCTAssertEqual(StudIPLink(.running("Kurse werden geladen …")), .connected)
        // Abgleichfehler (z. B. offline) heisst nicht abgemeldet: keine Karte "Stud.IP verbinden"
        XCTAssertEqual(StudIPLink(.failed("offline")), .connected)
    }
}
