import Foundation
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// StudiNow-Wissensbank in der App (20.11.2026, app/wissensbank.py): Die App schickt die Angaben zur Stelle nur, solange
/// der Dienst die Funktion fuer dieses Konto meldet (`wissensbank: true` in GET /api/entitlements); unter der Antwort
/// steht das Abzeichen bzw. nach einer Wiederholung die Ja/Nein-Frage. Schein-Dienst, nie ins Netz.
@MainActor
final class WissensbankAppTests: XCTestCase {
    // In 1.0.7 aus (Entscheidung des Inhabers 24.11.2026); die Tests pruefen die Funktion weiter mit Schalter an
    override func setUp() { super.setUp(); Wissensbank.shippedInApp = true }
    override func tearDown() { Wissensbank.shippedInApp = false; super.tearDown() }

    func testAnnouncementSwitchesTheStelleOnAndLogoutOff() async throws {
        let link = StudoraAccountLink()
        link.use(userScope: "test-wissensbank-\(UUID().uuidString)")
        let stub = InviteAppTests.StubTransport()
        let tokens = InviteAppTests.MemoryTokens("tok")
        link.attachAI(base: "https://dienst.example", http: stub, tokens: tokens)
        link.attach(creditsClient: StudoraCredits.Client(base: "https://dienst.example", http: stub, tokens: tokens))
        let ai = try XCTUnwrap(link.studinowAI)
        XCTAssertFalse(ai.wissensbankEnabled, "ohne Meldung aus")

        stub.on("GET", "/api/entitlements", 200, ["plan": "pro_ai", "wissensbank": true])
        await link.refreshCredits()
        XCTAssertTrue(ai.wissensbankEnabled, "Dienst meldet die Wissensbank (Pro AI, LUH, Schalter an)")

        stub.on("GET", "/api/entitlements", 200, ["plan": "pro_ai"])
        await link.refreshCredits()
        XCTAssertFalse(ai.wissensbankEnabled, "alter Dienst oder Schalter aus: wieder aus")

        stub.on("GET", "/api/entitlements", 200, ["plan": "pro_ai", "wissensbank": true])
        await link.refreshCredits()
        stub.on("GET", "/api/entitlements", 500, ["detail": "Kaputt"])
        await link.refreshCredits()
        XCTAssertTrue(ai.wissensbankEnabled, "ein Fehler laesst den letzten Stand stehen")

        await link.logout()
        XCTAssertFalse(ai.wissensbankEnabled, "abgemeldet: nichts mehr mitschicken")
    }

    func testLineShowsBadgeOrQuestionAndNothingWithoutFields() {
        let badge: JSONValue = ["source": "wissensbank", "wissensbank_key": "k",
                                "wissensbank": ["badge": "Aus der StudiNow-Wissensbank", "status": "geprüft", "hinweise": []]]
        let question: JSONValue = ["source": "ki", "wissensbank_key": "k", "feedback_token": "abc"]
        XCTAssertTrue(Wissensbank.isFromWissensbank(badge))
        XCTAssertEqual(Wissensbank.detail(badge), "geprüft")
        XCTAssertNil(Wissensbank.feedbackToken(badge))
        XCTAssertEqual(Wissensbank.feedbackToken(question), "abc")
        // jede Form rendert ohne Absturz (auch ohne Felder: leer)
        for (info, answered) in [(badge, nil), (question, nil), (question, true), (question, false), (JSONValue.object([:]), nil)] as [(JSONValue, Bool?)] {
            let view = TutorWissensbankLine(info: info, answered: answered, busy: false) { _ in }
            let host = UIHostingController(rootView: view)
            host.view.frame = CGRect(x: 0, y: 0, width: 360, height: 120)
            host.view.layoutIfNeeded()
        }
        let message = TutorPanel.Message(fromUser: false, text: "Antwort", wissensbank: question)
        XCTAssertNil(message.feedback, "die Frage ist offen, bis Ja oder Nein getippt ist")
    }
}
