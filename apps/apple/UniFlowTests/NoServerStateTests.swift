import XCTest
@testable import UniFlow

/// V1 ohne PC-Server: welcher Zustand eine Seite zeigt (eigener Server / lokales Backend mit Stud.IP-Stand) und was
/// der leere Zustand einer Seite zeigt, die es in V1 nicht gibt. Eine Datenquelle gibt es immer (`Session.api`).
@MainActor
final class NoServerStateTests: XCTestCase {

    func testServerOnlyWithOwnServer() {
        // Entwicklungsmodus des Inhabers: mit Server bleibt alles wie bisher, egal wie Stud.IP steht
        let server = APIClient(base: URL(string: "http://127.0.0.1:8765")!, pin: nil)
        for link in [StudIPLink.notConnected, .expired, .connected] {
            XCTAssertEqual(UFDataMode.resolve(api: server, studIP: link), .server)
        }
        XCTAssertFalse(UFDataMode.server.showsConnectCard)
        XCTAssertEqual(UFDataMode.resolve(api: nil, studIP: .expired), .local(.expired), "ohne Server immer das Geraet")
    }

    /// Die Weiche, die UFServerGate, Uebersicht und Community wirklich aufrufen
    func testCurrentUsesSessionServer() {
        let studip = StudIPSync()
        let api = APIClient(base: URL(string: "http://127.0.0.1:8765")!, pin: nil)
        XCTAssertEqual(UFDataMode.current(api: api, studip: studip), .server)
        XCTAssertEqual(UFDataMode.current(api: .local(), studip: studip),
                       .local(StudIPLink(studip.phase, hasSession: studip.hasStoredSession)))
    }

    func testConnectCardOnlyWhileStudIPMissing() {
        XCTAssertTrue(UFDataMode.local(.notConnected).showsConnectCard)
        XCTAssertTrue(UFDataMode.local(.expired).showsConnectCard)
        XCTAssertTrue(UFDataMode.local(.otherSources).showsConnectCard, "Karten der eigenen Quellen")
        XCTAssertFalse(UFDataMode.local(.connected).showsConnectCard)    // nach erfolgreicher Verbindung weg
    }

    func testLinkFromSyncPhase() {
        XCTAssertEqual(StudIPLink(.signedOut, hasSession: true), .notConnected)
        XCTAssertEqual(StudIPLink(.needsLogin, hasSession: true), .expired)
        XCTAssertEqual(StudIPLink(.idle, hasSession: true), .connected)
        XCTAssertEqual(StudIPLink(.running("Kurse werden geladen …"), hasSession: true), .connected)
        // Abgleichfehler (z. B. offline) mit gespeicherter Sitzung heisst nicht abgemeldet
        XCTAssertEqual(StudIPLink(.failed("offline"), hasSession: true), .connected)
        // Schluesselbundfehler nach der Anmeldung: keine Sitzung, die Karte "Stud.IP verbinden" bleibt
        XCTAssertEqual(StudIPLink(.failed("Schlüsselbund-Fehler -25299"), hasSession: false), .notConnected)
    }

    func testSessionOnlyAskedOnFailure() {
        var asked = false
        func ask() -> Bool { asked = true; return true }
        _ = StudIPLink(.idle, hasSession: ask())
        XCTAssertFalse(asked)
        _ = StudIPLink(.failed("x"), hasSession: ask())
        XCTAssertTrue(asked)
    }

    // MARK: Leerer Zustand

    private func content(_ kind: UFNoServerPage.Kind, _ mode: UFDataMode, _ phase: StudIPSync.Phase = .idle) -> UFNoServerContent {
        UFNoServerContent.resolve(kind: kind, mode: mode, phase: phase)
    }

    func testNotConnectedShowsCardAndPlainText() {
        let c = content(.exams, .local(.notConnected), .signedOut)
        XCTAssertTrue(c.showsConnectCard)
        XCTAssertNil(c.status)
        XCTAssertEqual(c.text, "Noch keine Tests.")
    }

    func testSyncStatusWhileConnected() {
        let connected = UFDataMode.local(.connected)
        XCTAssertEqual(content(.plan, connected, .running("Kurse werden geladen …")).status, .syncing("Kurse werden geladen …"))
        XCTAssertEqual(content(.plan, connected, .failed("offline")).status, .failed("offline"))
        XCTAssertNil(content(.plan, connected, .idle).status)
        XCTAssertFalse(content(.plan, connected, .running("x")).showsConnectCard)
        XCTAssertNil(content(.plan, .local(.notConnected), .failed("x")).status, "nicht verbunden: Karte statt Stand")
        XCTAssertNil(content(.plan, .server, .running("x")).status)
    }

    func testNoPromisesForWeeklyTestsAndNoSoonBadges() {
        for mode in [UFDataMode.local(.notConnected), .local(.connected)] {
            // Noten aus QIS gibt es auf dem Geraet (F4): kein "bald", kein "spaetere Version"
            let services = content(.services, mode)
            XCTAssertEqual(services.text, "Noch keine Noten.")
            XCTAssertFalse(services.soon)
            // keine KI in V1: Wochentests werden weder angeboten noch angekuendigt
            let exams = content(.exams, mode)
            XCTAssertEqual(exams.text, "Noch keine Tests.")
            XCTAssertFalse(exams.soon)
        }
        XCTAssertFalse(content(.library, .local(.connected)).soon)
        XCTAssertTrue(UFNoServerPage.Spec.services.local, "Uni & Noten lokal an beiden Hochschulen")
    }
}
