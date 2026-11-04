import Foundation
import XCTest
@testable import UniFlowCore

/// Einladungen (docs/EINLADUNGEN.md): Stufen gegen die gemeinsame Fixture packages/shared-contracts/fixtures/invites/cases.json
/// (dieselben prueft tests/test_invites.py fuer app/invites.py), Links und Codes, die Endpunkte ueber den Schein-Dienst.
final class InviteRewardsTests: XCTestCase {
    private func fixture() throws -> JSONValue {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/invites/cases.json")))
    }

    func testTierMatchesTheSharedFixture() throws {
        let fx = try fixture()
        let cases = fx["cases"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for c in cases {
            let count = try XCTUnwrap(c["count"]?.int)
            XCTAssertEqual(InviteRewards.tier(count: count), c["tier"]?.int, "count \(count)")
            XCTAssertEqual(InviteRewards.reached(count: count), (c["reached"]?.array ?? []).compactMap(\.int), "count \(count)")
        }
        // die Tabelle selbst wie in app/invites.py (Fixture-Abschnitt "tiers")
        let tiers = fx["tiers"]?.array ?? []
        XCTAssertEqual(tiers.count, InviteRewards.tiers.count)
        for (expect, got) in zip(tiers, InviteRewards.tiers) {
            XCTAssertEqual(got.count, expect["count"]?.int)
            XCTAssertEqual(got.choices.map(\.rawValue), (expect["choices"]?.array ?? []).compactMap(\.string))
            for (k, v) in expect["rewards"]?.object ?? [:] {
                XCTAssertEqual(got.rewards[try XCTUnwrap(InviteRewards.Choice(rawValue: k))], v.string, "\(got.count) \(k)")
            }
        }
        XCTAssertEqual(InviteRewards.maxLinks, fx["max_links"]?.int)
        XCTAssertEqual(InviteRewards.linkDays, fx["link_days"]?.int)
        XCTAssertEqual(InviteRewards.createDays, fx["create_days"]?.int)
        XCTAssertEqual(InviteRewards.linkBase, fx["link_base"]?.string)
        XCTAssertEqual(InviteRewards.next(after: 7)?.count, 10)
        XCTAssertNil(InviteRewards.next(after: 20))
        XCTAssertEqual(InviteRewards.counterText(arrived: 7), "7 von 20 angekommen")
    }

    func testRedeemURLNeedsTheAppleAppID() {
        XCTAssertEqual(InviteRewards.redeemURL(appID: "6741234567", code: "ABC-1")?.absoluteString,
                       "https://apps.apple.com/redeem?ctx=offercodes&id=6741234567&code=ABC-1")
        XCTAssertNil(InviteRewards.redeemURL(appID: nil, code: "ABC-1"))
        XCTAssertNil(InviteRewards.redeemURL(appID: "", code: "ABC-1"))
    }

    func testLinksAndCodes() throws {
        XCTAssertEqual(InviteLink.url(code: "AB2CD3EFGH").absoluteString, "https://studinow.app/i/AB2CD3EFGH")
        XCTAssertEqual(InviteLink.schemeURL(code: "AB2CD3EFGH").absoluteString, "uniflow://invite/AB2CD3EFGH")
        XCTAssertEqual(InviteLink.code(from: try XCTUnwrap(URL(string: "https://studinow.app/i/AB2CD3EFGH"))), "AB2CD3EFGH")
        XCTAssertEqual(InviteLink.code(from: try XCTUnwrap(URL(string: "https://www.studinow.app/i/ab2cd-3efgh/"))), "AB2CD3EFGH")
        XCTAssertEqual(InviteLink.code(from: try XCTUnwrap(URL(string: "uniflow://invite/AB2CD3EFGH"))), "AB2CD3EFGH")
        XCTAssertNil(InviteLink.code(from: try XCTUnwrap(URL(string: "https://studinow.app/i/"))), "ohne Code")
        XCTAssertNil(InviteLink.code(from: try XCTUnwrap(URL(string: "https://studinow.app/support"))))
        XCTAssertNil(InviteLink.code(from: try XCTUnwrap(URL(string: "https://beispiel.de/i/AB2CD3EFGH"))), "fremder Host")
        XCTAssertNil(InviteLink.code(from: try XCTUnwrap(URL(string: "uniflow://community/join/AB2CD3EFGH"))), "Lerngruppe, keine Einladung")
        XCTAssertNil(InviteLink.code(from: try XCTUnwrap(URL(string: "https://studinow.app/i/AB2CD3EFG0"))), "0 ist nicht im Alphabet")
        XCTAssertNil(InviteLink.code(from: try XCTUnwrap(URL(string: "https://studinow.app/i/<script>"))))
        XCTAssertEqual(InviteLink.normalized(" https://studinow.app/i/ab2cd3efgh "), "AB2CD3EFGH")
        XCTAssertNil(InviteLink.normalized("zu kurz"))
    }

    func testEndpointsReadTheOverviewCreateRedeemAndClaim() async throws {
        let fake = FakeService(), store = MemoryTokenStore("token")
        let acc = StudoraAccount(base: "https://dienst.example", http: fake, tokens: store, deviceID: "ipad-test", deviceName: "iPad")
        let overview: JSONValue = [
            "codes": [["code": "AB2CD3EFGH", "url": "https://studinow.app/i/AB2CD3EFGH", "created_at": "2026-11-04T09:00:00+00:00",
                       "expires_at": "2026-12-04T09:00:00+00:00", "redemptions": 7, "expired": false]],
            "arrived": 7, "max_links": 20, "remaining_links": 19, "can_create": true, "create_until": "2026-11-11T09:00:00+00:00",
            "tier": 5, "apple_app_id": "6741234567",
            "tiers": [
                ["count": 5, "choices": ["plus"], "rewards": ["plus": "1 Monat StudiNow Plus gratis"], "reached": true, "claimable": false,
                 "claimed": ["tier": 5, "choice": "plus", "offer_code": "PLUS5-A", "claimed_at": "2026-11-05T09:00:00+00:00",
                             "redeem_url": "https://apps.apple.com/redeem?ctx=offercodes&id=6741234567&code=PLUS5-A"]],
                ["count": 10, "choices": ["plus"], "rewards": ["plus": "3 Monate StudiNow Plus gratis"], "reached": false, "claimable": false, "claimed": .null],
                ["count": 20, "choices": ["plus", "proai"], "rewards": ["plus": "12 Monate StudiNow Plus gratis", "proai": "12 Monate StudiNow Pro AI zum Plus-Preis (1,99 € statt 3,99 €)"],
                 "reached": false, "claimable": false, "claimed": .null],
            ],
        ]
        await fake.on("GET", "/api/invites", 200, overview)
        let o = try await acc.invites()
        XCTAssertEqual(o.links, [.init(code: "AB2CD3EFGH", url: "https://studinow.app/i/AB2CD3EFGH", createdAt: "2026-11-04T09:00:00+00:00",
                                       expiresAt: "2026-12-04T09:00:00+00:00", redemptions: 7, expired: false)])
        XCTAssertEqual(o.arrived, 7)
        XCTAssertEqual(o.maxLinks, 20)
        XCTAssertEqual(o.remainingLinks, 19)
        XCTAssertTrue(o.canCreate)
        XCTAssertEqual(o.tier, 5)
        XCTAssertEqual(o.appleAppID, "6741234567")
        XCTAssertEqual(o.tiers.map(\.count), [5, 10, 20])
        XCTAssertEqual(o.tiers[0].claimed, .init(choice: .plus, offerCode: "PLUS5-A", claimedAt: "2026-11-05T09:00:00+00:00",
                                                 redeemURL: URL(string: "https://apps.apple.com/redeem?ctx=offercodes&id=6741234567&code=PLUS5-A")))
        XCTAssertEqual(o.tiers[2].choices, [.plus, .proai])
        XCTAssertEqual(o.tiers[2].rewards[.proai], "12 Monate StudiNow Pro AI zum Plus-Preis (1,99 € statt 3,99 €)")
        XCTAssertNil(o.tiers[1].claimed)

        await fake.on("POST", "/api/invites", 201, overview)
        let created = try await acc.createInvite()
        XCTAssertEqual(created.links.count, 1)
        let createReq = await fake.last("/api/invites")
        XCTAssertEqual(createReq?.method, "POST")

        await fake.on("POST", "/api/invites/redeem", 200, ["redeemed": true, "already": false, "code": "AB2CD3EFGH"])
        let already = try await acc.redeemInvite(code: "AB2CD3EFGH")
        XCTAssertFalse(already)
        let sent = await fake.last("/api/invites/redeem")
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(sent?.body))["code"]?.string, "AB2CD3EFGH")
        XCTAssertEqual(sent?.headers["Authorization"], "Bearer token", "nur mit Sitzung")

        await fake.on("POST", "/api/invites/claim", 200, ["tier": 20, "choice": "proai", "offer_code": "PROAI20-A", "already": false,
                                                          "reward": "12 Monate StudiNow Pro AI zum Plus-Preis (1,99 € statt 3,99 €)",
                                                          "redeem_url": "https://apps.apple.com/redeem?ctx=offercodes&id=6741234567&code=PROAI20-A"])
        let c = try await acc.claimInvite(tier: 20, choice: .proai)
        XCTAssertEqual(c, InviteClaim(tier: 20, choice: .proai, offerCode: "PROAI20-A", reward: "12 Monate StudiNow Pro AI zum Plus-Preis (1,99 € statt 3,99 €)",
                                      redeemURL: URL(string: "https://apps.apple.com/redeem?ctx=offercodes&id=6741234567&code=PROAI20-A"), already: false))
        let claimReq = await fake.last("/api/invites/claim")
        let body = try JSONValue.parse(XCTUnwrap(claimReq?.body))
        XCTAssertEqual(body["tier"]?.int, 20)
        XCTAssertEqual(body["choice"]?.string, "proai")

        // leerer Vorrat: Fehlercode und deutscher Text des Dienstes
        await fake.on("POST", "/api/invites/claim", 409, ["detail": "Für diese Belohnung sind gerade keine Codes hinterlegt – bitte später noch einmal versuchen.",
                                                          "code": "offer_codes_exhausted"])
        do {
            _ = try await acc.claimInvite(tier: 10, choice: .plus)
            XCTFail("409 erwartet")
        } catch let e as AccountError {
            XCTAssertEqual(e.code, "offer_codes_exhausted")
            XCTAssertTrue(e.message.contains("keine Codes hinterlegt"))
        }
    }
}
