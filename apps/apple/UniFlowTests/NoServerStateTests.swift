import XCTest
@testable import UniFlow

/// V1 ohne PC-Server: welcher Zustand eine Seite zeigt (Server / kein Server / Stud.IP verbunden) und was der
/// leere Zustand dann anzeigt.
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

    /// Die Weiche, die UFServerGate, Uebersicht, UFRemote und Community wirklich aufrufen
    func testCurrentUsesSessionServer() {
        let studip = StudIPSync()
        let api = APIClient(base: URL(string: "http://127.0.0.1:8765")!, pin: nil)
        XCTAssertEqual(UFDataMode.current(api: api, studip: studip), .server)
        XCTAssertNotEqual(UFDataMode.current(api: nil, studip: studip), .server)
        XCTAssertEqual(UFDataMode.current(api: nil, studip: studip),
                       UFDataMode.resolve(hasServer: false, studIP: StudIPLink(studip.phase, hasSession: !StudIPKeychain.load().isEmpty)))
    }

    func testConnectCardOnlyWhileStudIPMissing() {
        XCTAssertTrue(UFDataMode.connectStudIP.showsConnectCard)
        XCTAssertTrue(UFDataMode.reconnectStudIP.showsConnectCard)
        XCTAssertFalse(UFDataMode.empty.showsConnectCard)                // nach erfolgreicher Verbindung weg
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

    private func content(_ kind: UFNoServerPage.Kind, _ mode: UFDataMode, _ phase: StudIPSync.Phase = .idle,
                         files: Int = 0, courses: Int = 0) -> UFNoServerContent {
        UFNoServerContent.resolve(kind: kind, mode: mode, phase: phase, files: files, courses: courses)
    }

    func testNotConnectedShowsCardAndPlainText() {
        let c = content(.library, .connectStudIP, .signedOut, files: 3)
        XCTAssertTrue(c.showsConnectCard)
        XCTAssertNil(c.status)
        XCTAssertNil(c.filesButton)                                      // ohne Verbindung keine Dateien zeigen
        XCTAssertEqual(c.text, "Noch keine Dokumente.")
    }

    func testSyncStatusWhileConnected() {
        XCTAssertEqual(content(.plan, .empty, .running("Kurse werden geladen …")).status, .syncing("Kurse werden geladen …"))
        XCTAssertEqual(content(.plan, .empty, .failed("offline")).status, .failed("offline"))
        XCTAssertNil(content(.plan, .empty, .idle).status)
        XCTAssertFalse(content(.plan, .empty, .running("x")).showsConnectCard)
    }

    func testLibraryAndModulesNameRealCounts() {
        let lib = content(.library, .empty, files: 12)
        XCTAssertEqual(lib.text, "12 Dateien aus Stud.IP liegen auf diesem iPad.")
        XCTAssertEqual(lib.filesButton, "Stud.IP-Dateien ansehen (12)")
        XCTAssertEqual(content(.library, .empty, files: 1).text, "1 Datei aus Stud.IP liegt auf diesem iPad.")
        XCTAssertEqual(content(.library, .empty).text, "Noch keine Dokumente.")
        XCTAssertNil(content(.library, .empty).filesButton)

        XCTAssertEqual(content(.modules, .empty, courses: 5).text, "5 Kurse aus Stud.IP sind abgeglichen.")
        XCTAssertEqual(content(.modules, .empty, courses: 5).filesButton, "Stud.IP-Kurse ansehen (5)")
        XCTAssertEqual(content(.modules, .empty, courses: 1).text, "1 Kurs aus Stud.IP ist abgeglichen.")
        XCTAssertEqual(content(.modules, .empty).text, "Noch keine Module.")
        XCTAssertFalse(content(.dashboard, .empty, files: 4).text.contains("noch ist nichts da"))
    }

    func testNoPromisesForGradesAndWeeklyTests() {
        for mode in [UFDataMode.connectStudIP, .empty] {
            let services = content(.services, mode, files: 2)
            XCTAssertEqual(services.text, "Noten aus QIS kommen in einer späteren Version.")
            XCTAssertTrue(services.soon)
            // keine KI in V1: Wochentests werden weder angeboten noch angekuendigt
            let exams = content(.exams, mode)
            XCTAssertEqual(exams.text, "Noch keine Tests.")
            XCTAssertFalse(exams.soon)
        }
        XCTAssertFalse(content(.library, .empty).soon)
        XCTAssertNil(UFNoServerPage.Spec.services.sub?.range(of: "Notenspiegel"))
    }
}
