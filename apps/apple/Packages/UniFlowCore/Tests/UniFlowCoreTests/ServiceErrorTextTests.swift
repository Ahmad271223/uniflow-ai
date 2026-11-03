import Foundation
import XCTest
@testable import UniFlowCore

// Fehlercodes des StudiNow-Dienstes -> Text fuer die Oberflaeche (docs/SICHERHEITSKORREKTUREN-2026-11-02.md).
// Eine Stelle: ServiceErrorText; Konto (AccountError.userMessage), Community und APIError lesen sie.

private func contract(_ name: String) throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/\(name)/contract.json")))
}

final class ServiceErrorTextTests: XCTestCase {
    private func err(_ status: Int, _ code: String, _ message: String = "Meldung des Dienstes", retry: Int? = nil) -> AccountError {
        AccountError(status: status, code: code, message: message, retryAfter: retry)
    }

    func testEveryNewCodeHasItsOwnGermanText() {
        let expected: [(Int, String, String)] = [
            (403, "email_unverified", "Bestätige zuerst deine E-Mail-Adresse"),
            (409, "duplicate_request", "schon verarbeitet"),
            (429, "ai_trial_budget_exhausted", "Probekonten"),
            (503, "ai_not_configured_prices", "noch nicht freigeschaltet"),
            (409, "email_taken", "gibt es schon ein StudiNow-Konto"),
            (409, "last_login_method", "einzige Anmeldeweg"),
            (403, "cross_site", "Sicherheitsgründen"),
        ]
        for (status, code, part) in expected {
            let e = err(status, code)
            XCTAssertTrue(e.userMessage.contains(part), "\(code): \(e.userMessage)")
            XCTAssertFalse(e.userMessage.contains("Meldung des Dienstes"), "\(code): eigener Text statt Dienst-Text")
            XCTAssertEqual(ServiceErrorText.known(code: code), e.userMessage, code)
        }
    }

    func testUnknownCodeKeepsTheServiceMessage() {
        XCTAssertNil(ServiceErrorText.known(code: "voellig_neu"))
        XCTAssertEqual(err(400, "voellig_neu", "Text vom Dienst").userMessage, "Text vom Dienst")
        XCTAssertNil(err(400, "voellig_neu").action)
    }

    func testRetryAfterIsAppended() {
        XCTAssertEqual(err(429, "rate_limited", "Zu viele Versuche.", retry: 600).userMessage, "Zu viele Versuche. (in 10 min erneut versuchen)")
        XCTAssertEqual(err(429, "rate_limited", "Zu viele Versuche.", retry: 20).userMessage, "Zu viele Versuche. (in 1 min erneut versuchen)")
        XCTAssertEqual(err(429, "rate_limited", "x", retry: 86_400).userMessage, "x (in etwa 24 Std. erneut versuchen)")
        XCTAssertTrue(err(429, "ai_trial_budget_exhausted", retry: 60).userMessage.hasSuffix("(in 1 min erneut versuchen)"))
        XCTAssertEqual(err(429, "rate_limited", "x", retry: 0).userMessage, "x")
    }

    func testActions() {
        XCTAssertEqual(err(403, "email_unverified").action, .verifyEmail)
        XCTAssertEqual(err(409, "last_login_method").action, .accountSettings)
        XCTAssertEqual(err(409, "email_taken").action, .accountSettings)
        for code in ["duplicate_request", "ai_trial_budget_exhausted", "ai_not_configured_prices", "cross_site", "rate_limited"] {
            XCTAssertNil(err(400, code).action, code)
        }
    }

    func testReportLimitMatchesTheContract() throws {
        let limit = try XCTUnwrap(contract("account")["rules"]?["limits"]?["report_user"]?["count"]?.double)
        XCTAssertEqual(ServiceErrorText.reportsPerDay, Int(limit))
        XCTAssertTrue(ServiceErrorText.reportLimit(retryAfter: nil).contains("\(Int(limit)) Meldungen"))
    }

    /// Nur Codes, die es gibt: die im Vertrag genannten muessen dort stehen
    func testContractCodesExist() throws {
        let account = try String(data: contract("account").serialized(), encoding: .utf8) ?? ""
        for code in ["email_unverified", "email_taken", "report_user"] { XCTAssertTrue(account.contains(code), code) }
        let taken = try contract("account")["errors"]?["email_taken"]
        XCTAssertEqual(taken?["status"]?.double, 409)
    }

    func testCommunityUsesTheSameTexts() {
        func map(_ e: AccountError, report: Bool = false) -> CommunityServiceError? {
            ServiceCommunityService.serviceError(e, report: report) as? CommunityServiceError
        }
        let unverified = map(err(403, "email_unverified"))
        XCTAssertEqual(unverified, .emailUnverified)
        XCTAssertEqual(unverified?.localizedDescription, ServiceErrorText.known(code: "email_unverified"))
        XCTAssertEqual(unverified?.action, .verifyEmail)
        // Melden: 429 rate_limited ist die Grenze report_user
        let report = map(err(429, "rate_limited", "Zu viele Versuche.", retry: 3_600), report: true)
        XCTAssertEqual(report, .service(ServiceErrorText.reportLimit(retryAfter: 3_600)))
        XCTAssertTrue(report?.localizedDescription.contains("10 Meldungen") == true)
        // andere Grenzen behalten den Text des Dienstes, mit Wartezeit
        XCTAssertEqual(map(err(429, "rate_limited", "Zu viele Versuche.", retry: 120)), .service("Zu viele Versuche. (in 2 min erneut versuchen)"))
        XCTAssertEqual(map(err(409, "duplicate_request")), .service(ServiceErrorText.known(code: "duplicate_request")!))
        XCTAssertEqual(map(err(403, "plan_required", "M")), .server("M"), "unbekannt: Meldung des Dienstes")
    }

    func testResendVerification() async throws {
        let fake = FakeService()
        let acc = StudoraAccount(base: "https://dienst.example", http: fake, tokens: MemoryTokenStore("t"), deviceID: "d", deviceName: "iPad")
        await fake.on("POST", "/api/account/verify-email/resend", 200, ["ok": true, "already": false, "message": "Wir haben dir einen neuen Bestätigungslink geschickt."])
        let sent = try await acc.resendVerification()
        XCTAssertEqual(sent, "Wir haben dir einen neuen Bestätigungslink geschickt.")
        await fake.on("POST", "/api/account/verify-email/resend", 200, ["ok": true, "already": true])
        let already = try await acc.resendVerification()
        XCTAssertEqual(already, "Deine E-Mail-Adresse ist schon bestätigt.")
        await fake.on("POST", "/api/account/verify-email/resend", 429, ["detail": "Zu viele Versuche.", "code": "rate_limited"], headers: ["Retry-After": "1800"])
        do { _ = try await acc.resendVerification(); XCTFail() } catch let e as AccountError {
            XCTAssertEqual(e.userMessage, "Zu viele Versuche. (in 30 min erneut versuchen)")
        }
        let last = await fake.last("/api/account/verify-email/resend")
        XCTAssertEqual(last?.headers["Authorization"], "Bearer t")
    }
}
