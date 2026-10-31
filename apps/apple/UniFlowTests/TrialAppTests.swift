import XCTest
import UniFlowCore
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

/// Geraete-Abgleich in der App: wann er laufen darf und was die Konto-Karte sagt
@MainActor
final class DeviceSyncAppTests: XCTestCase {
    private func user(_ uni: String?) -> StudoraAccount.User {
        StudoraAccount.User(id: "1", email: "a@b.de", emailVerified: true, university: uni, plan: "plus", role: "user")
    }

    func testRunsOnlySignedInOutsideTheDemoAndForTheAccountsUniversity() {
        XCTAssertFalse(StudoraAccountLink.canSync(user: nil, university: "luh", blocked: false))
        XCTAssertTrue(StudoraAccountLink.canSync(user: user("luh"), university: "luh", blocked: false))
        XCTAssertFalse(StudoraAccountLink.canSync(user: user("luh"), university: "luh", blocked: true), "Demo")
        XCTAssertFalse(StudoraAccountLink.canSync(user: user("hildesheim"), university: "luh", blocked: false), "andere Hochschule")
        XCTAssertTrue(StudoraAccountLink.canSync(user: user(nil), university: "luh", blocked: false))
    }

    func testCardTexts() {
        XCTAssertEqual(StudoraAccountCard.syncText(nil), "Noch nicht abgeglichen")
        var r = DeviceSyncResult()
        r.applied = 3
        r.pushed = 1
        r.pending = 2
        r.planRequired = true
        XCTAssertEqual(StudoraAccountCard.syncText(r), "Abgeglichen: 3 geholt, 1 gesendet, 2 warten auf ihre Datei. Notizen bleiben im Tarif Free auf diesem Gerät")
        r.ok = false
        r.error = "Der Studora-Dienst ist nicht erreichbar."
        XCTAssertEqual(StudoraAccountCard.syncText(r), "Der Studora-Dienst ist nicht erreichbar.")
    }
}
