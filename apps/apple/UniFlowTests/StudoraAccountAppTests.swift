import XCTest
import UniFlowCore
@testable import UniFlow

/// Studora-Konto in der App: ohne Dienst-Adresse unsichtbar, Token je Apple-Nutzer im Schluesselbund, "Konto löschen"
/// in der App entfernt die Anmeldung. Nie ins Netz.
@MainActor
final class StudoraAccountAppTests: XCTestCase {
    func testHiddenWithoutServiceAddress() {
        XCTAssertNil(StudoraAccountLink.serviceURL, "der Build hat noch keinen Server")
        XCTAssertFalse(StudoraAccountLink.available)
        let link = StudoraAccountLink()
        link.use(userScope: "test-\(UUID().uuidString)")
        XCTAssertNil(link.account, "ohne Dienst kein Konto")
    }

    func testTokenPerAppleUserAndRemovedWithTheAccount() async throws {
        let a = StudoraAccountKeychain(userScope: "test-a-\(UUID().uuidString)"), b = StudoraAccountKeychain(userScope: "test-b-\(UUID().uuidString)")
        defer { StudoraAccountKeychain.remove(userScope: a.userScope); StudoraAccountKeychain.remove(userScope: b.userScope) }
        try a.save("tok-a")
        XCTAssertEqual(a.load(), "tok-a")
        XCTAssertNil(b.load())
        try a.save(nil)
        XCTAssertNil(a.load())

        let bed = try ContainerTestBed(name: "konto", clock: .fixed(berlin: "2026-10-29T09:00:00")!)
        let store = StudoraAccountKeychain(userScope: DataContainerKey.userScope(bed.user))
        try store.save("tok")
        let m = bed.manager()
        _ = try bed.open(m, bed.account(.luh))
        let problem = await m.deleteAllData(userID: bed.user)
        XCTAssertNil(problem)
        XCTAssertNil(store.load(), "Konto löschen in der App entfernt die Studora-Anmeldung")
    }

    /// Antworten des Dienstes ueber APIClient (PC-Modus) zeigen dieselben Texte wie das Konto (ServiceErrorText)
    func testAPIErrorUsesTheServiceErrorTexts() {
        let codes = ["email_unverified", "duplicate_request", "ai_trial_budget_exhausted", "ai_not_configured_prices",
                     "email_taken", "last_login_method", "cross_site"]
        for code in codes {
            let flat = APIError(status: 403, body: Data(#"{"detail": "Dienst-Text", "code": "\#(code)"}"#.utf8))
            XCTAssertEqual(flat.code, code)
            XCTAssertEqual(flat.errorDescription, ServiceErrorText.known(code: code), code)
            // FastAPI HTTPException mit Objekt: {"detail": {"detail", "code"}}
            let nested = APIError(status: 403, body: Data(#"{"detail": {"detail": "Dienst-Text", "code": "\#(code)"}}"#.utf8))
            XCTAssertEqual(nested.errorDescription, ServiceErrorText.known(code: code), code)
        }
        let unknown = APIError(status: 400, body: Data(#"{"detail": "Dienst-Text", "code": "voellig_neu"}"#.utf8))
        XCTAssertEqual(unknown.errorDescription, "Dienst-Text", "unbekannter Code: Meldung des Dienstes")
        let own = APIError(status: 403, message: "", text: "Eigener Text")
        XCTAssertEqual(own.errorDescription, "Eigener Text", "eigene Meldung der App geht vor")
    }
}
