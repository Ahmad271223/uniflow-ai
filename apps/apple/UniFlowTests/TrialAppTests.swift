import XCTest
@testable import UniFlow

/// Probe des Studora-Kontos (docs/ABO-SYSTEM.md 3a): Texte wie im Web, die Probe hebt den Tarif nur solange sie laeuft
@MainActor
final class TrialAppTests: XCTestCase {
    func testTexts() {
        XCTAssertEqual(UFTrialTexts.running(1), "Probe: noch 1 Tag alles frei")
        XCTAssertEqual(UFTrialTexts.running(7), "Probe: noch 7 Tage alles frei")
    }

    func testServiceTrialRaisesThePlanOnlyWhileItRuns() {
        let e = Entitlements.shared
        defer { e.useServiceTrial(nil) }
        let before = e.plan
        e.useServiceTrial(.proAI)
        XCTAssertEqual(e.plan, .proAI)
        e.useServiceTrial(nil)
        XCTAssertEqual(e.plan, before, "Ende der Probe: zurueck zum Stand des App Store")
    }
}
