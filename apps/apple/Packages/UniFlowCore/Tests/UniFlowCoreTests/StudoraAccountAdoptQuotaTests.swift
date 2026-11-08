import Foundation
import XCTest
@testable import UniFlowCore

/// P43-06 (Entscheidung des Inhabers 08.11.2026): Mit StudiNow-Konto zaehlt der Dienst das Kontingent
/// `card_stacks_adopted` je Konto ueber alle Geraete (app/community_cards_api.py `count_adopt_quota_from_app`,
/// Stand aus GET /api/entitlements).
final class StudoraAccountAdoptQuotaTests: XCTestCase {
    private func make(_ token: String? = "token") -> (StudoraAccount, FakeService) {
        let fake = FakeService()
        return (StudoraAccount(base: "https://dienst.example", http: fake, tokens: MemoryTokenStore(token), deviceID: "ipad-test", deviceName: "iPad"), fake)
    }

    func testCountSendsTheRefAndReadsOkUsedLimit() async throws {
        let (acc, fake) = make()
        await fake.on("POST", "/api/community/card-stacks/adopt-quota", 200, ["ok": true, "counted": true, "used": 2, "limit": 4])
        await fake.on("POST", "/api/community/card-stacks/adopt-quota", 200, ["ok": false, "counted": false, "used": 4, "limit": 4])
        let first = try await acc.countAdoptedStack(ref: "community:abc")
        XCTAssertEqual(first, StudoraAccount.AdoptQuota(ok: true, counted: true, used: 2, limit: 4))
        let sent = await fake.last("/adopt-quota")
        XCTAssertEqual(try JSONValue.parse(try XCTUnwrap(sent?.body))["ref"]?.string, "community:abc")
        XCTAssertEqual(sent?.headers["Authorization"], "Bearer token")
        let second = try await acc.countAdoptedStack(ref: "community:def")
        XCTAssertEqual(second, StudoraAccount.AdoptQuota(ok: false, counted: false, used: 4, limit: 4))
    }

    func testStatusReadsTheQuotaFromEntitlements() async throws {
        let (acc, fake) = make()
        await fake.on("GET", "/api/entitlements", 200, ["plan": "plus", "quotas": ["card_stacks_adopted": ["used": 3, "limit": 4, "unlimited": false, "period": "2026-11"]]])
        await fake.on("GET", "/api/entitlements", 200, ["plan": "pro_ai", "quotas": ["card_stacks_adopted": ["used": 9, "limit": 300, "unlimited": true, "period": "2026-11"]]])
        let plus = try await acc.adoptQuotaStatus()
        XCTAssertEqual(plus, StudoraAccount.AdoptQuota(ok: true, counted: false, used: 3, limit: 4))
        let pro = try await acc.adoptQuotaStatus()
        XCTAssertNil(pro.limit, "unbegrenzt (Fair Use nur im Dienst)")
        XCTAssertTrue(pro.ok)
    }

    func testOfflineAndSignedOutAreErrors() async throws {
        let (acc, fake) = make()
        await fake.setOffline(true)
        do { _ = try await acc.countAdoptedStack(ref: "community:x"); XCTFail("offline") } catch let e as AccountError {
            XCTAssertEqual(e.code, "service_unreachable")
        }
        let (out, _) = make(nil)
        do { _ = try await out.adoptQuotaStatus(); XCTFail("abgemeldet") } catch let e as AccountError { XCTAssertEqual(e.code, "unauthenticated") }
    }
}
