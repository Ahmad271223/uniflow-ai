import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Einladungen in der App (docs/EINLADUNGEN.md): Zustaende der Seite (ohne Konto / mit Links / Stufe erreicht und
/// eingeloest, leerer Vorrat) ueber einen Schein-Dienst, gemerkter Code bis zum Konto, Links und QR. Nie ins Netz.
@MainActor
final class InviteAppTests: XCTestCase {
    /// Schein-Dienst wie `FakeService` im Kern: je Methode + Pfad die naechste Antwort
    final class StubTransport: ServiceHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: [(Int, JSONValue)]] = [:]
        private(set) var requests: [AIHTTPRequest] = []
        func on(_ method: String, _ path: String, _ status: Int, _ body: JSONValue) {
            lock.withLock { replies["\(method) \(path)", default: []].append((status, body)) }
        }
        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            lock.withLock {
                requests.append(r)
                let key = "\(r.method) " + String(r.url.dropFirst("https://dienst.example".count))
                guard var list = replies[key], !list.isEmpty else { return ServiceHTTPResponse(status: 404, body: Data()) }
                let (status, body) = list.removeFirst()
                replies[key] = list
                return ServiceHTTPResponse(status: status, body: body.serialized())
            }
        }
        func count(_ method: String, _ path: String) -> Int { lock.withLock { requests.filter { $0.method == method && $0.url.hasSuffix(path) }.count } }
    }

    final class MemoryTokens: AccountTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        init(_ t: String?) { token = t }
        func load() -> String? { lock.withLock { token } }
        func save(_ t: String?) throws { lock.withLock { token = t } }
    }

    private func account(_ stub: StubTransport, token: String? = "tok") -> StudoraAccount {
        StudoraAccount(base: "https://dienst.example", http: stub, tokens: MemoryTokens(token), deviceID: "ipad-test", deviceName: "iPad")
    }

    private func overview(arrived: Int, links: [JSONValue] = [], canCreate: Bool = true, claimed5: Bool = false) -> JSONValue {
        let tier5: JSONValue = claimed5
            ? ["count": 5, "choices": ["plus"], "rewards": ["plus": "1 Monat StudiNow Plus gratis"], "reached": true, "claimable": false,
               "claimed": ["tier": 5, "choice": "plus", "offer_code": "PLUS5-A", "claimed_at": "2026-11-05T09:00:00+00:00",
                           "redeem_url": "https://apps.apple.com/redeem?ctx=offercodes&id=6741234567&code=PLUS5-A"]]
            : ["count": 5, "choices": ["plus"], "rewards": ["plus": "1 Monat StudiNow Plus gratis"], "reached": .bool(arrived >= 5),
               "claimable": .bool(arrived >= 5), "claimed": .null]
        return ["codes": .array(links), "arrived": .number(Double(arrived)), "max_links": 20, "remaining_links": .number(Double(20 - links.count)),
                "can_create": .bool(canCreate), "create_until": "2026-11-11T09:00:00+00:00", "tier": arrived >= 5 ? 5 : .null,
                "apple_app_id": "6741234567",
                "tiers": [tier5,
                          ["count": 10, "choices": ["plus"], "rewards": ["plus": "3 Monate StudiNow Plus gratis"], "reached": false, "claimable": false, "claimed": .null],
                          ["count": 20, "choices": ["plus", "proai"], "rewards": ["plus": "12 Monate StudiNow Plus gratis",
                                                                                  "proai": "12 Monate StudiNow Pro AI zum Plus-Preis (1,99 € statt 3,99 €)"],
                           "reached": false, "claimable": false, "claimed": .null]]]
    }

    private let link1: JSONValue = ["code": "AB2CD3EFGH", "url": "https://studinow.app/i/AB2CD3EFGH", "created_at": "2026-11-04T09:00:00+00:00",
                                    "expires_at": "2026-12-04T09:00:00+00:00", "redemptions": 7, "expired": false]

    // MARK: Zustaende der Seite

    func testWithoutAccountTheHintIsHonestAndNothingIsCalled() async {
        let stub = StubTransport()
        let m = InviteModel(service: account(stub), signedIn: false)
        XCTAssertEqual(m.state, .noAccount)
        await m.load()
        XCTAssertEqual(m.state, .noAccount)
        XCTAssertEqual(stub.requests.count, 0, "ohne Konto kein Aufruf")
        XCTAssertEqual(InviteTexts.noAccount, "Einladungen brauchen dein StudiNow-Konto")
        let none = InviteModel(service: nil, signedIn: true)
        XCTAssertEqual(none.state, .noAccount)
        // die Karte in den Einstellungen zeigt denselben Hinweis, wenn der Anschluss kein Konto hat
        let link = StudoraAccountLink()
        XCTAssertNil(link.user)
        _ = UIHostingController(rootView: InviteCard(link: link).frame(width: 420)).view
    }

    func testWithLinksTheCounterAndShareTargetsAppear() async throws {
        let stub = StubTransport()
        stub.on("GET", "/api/invites", 200, overview(arrived: 7, links: [link1]))
        let m = InviteModel(service: account(stub), signedIn: true)
        XCTAssertEqual(m.state, .loading)
        await m.load()
        let o = try XCTUnwrap(m.overview)
        XCTAssertEqual(o.links.map(\.code), ["AB2CD3EFGH"])
        XCTAssertEqual(InviteTexts.counter(o), "7 von 20 angekommen")
        XCTAssertEqual(InviteTexts.nextTier(o), "Noch 3 Personen bis 10: 3 Monate StudiNow Plus gratis")
        XCTAssertEqual(InviteTexts.redemptions(7), "7 angekommen")
        XCTAssertTrue(o.canCreate)
        // neuer Link: der Dienst liefert den neuen Stand
        stub.on("POST", "/api/invites", 201, overview(arrived: 7, links: [link1, ["code": "ZZ2CD3EFGH", "url": "https://studinow.app/i/ZZ2CD3EFGH"]]))
        await m.createLink()
        XCTAssertEqual(m.overview?.links.count, 2)
        XCTAssertNil(m.message)
        // Fenster zu: 403 des Dienstes als Text, Links bleiben
        stub.on("POST", "/api/invites", 403, ["detail": "Einladungslinks gibt es nur in der Probewoche. Deine bestehenden Links gelten weiter.", "code": "invite_window_closed"])
        await m.createLink()
        XCTAssertEqual(m.message, "Einladungslinks gibt es nur in der Probewoche. Deine bestehenden Links gelten weiter.")
        XCTAssertEqual(m.overview?.links.count, 2)
        // die Seite laesst sich mit diesem Stand aufbauen (Teilen, QR je Link)
        let env = try hostWithEnvironment(InviteView(model: m), size: CGSize(width: 700, height: 900))
        env.pump(0.3)
    }

    func testReachedTierClaimsOnceAndShowsAppleRedeemLink() async throws {
        let stub = StubTransport()
        stub.on("GET", "/api/invites", 200, overview(arrived: 5, links: [link1]))
        let m = InviteModel(service: account(stub), signedIn: true)
        await m.load()
        let before = try XCTUnwrap(m.overview)
        XCTAssertEqual(before.tier, 5)
        XCTAssertEqual(before.tiers.map(\.claimable), [true, false, false])
        stub.on("POST", "/api/invites/claim", 200, ["tier": 5, "choice": "plus", "offer_code": "PLUS5-A", "already": false, "reward": "1 Monat StudiNow Plus gratis",
                                                    "redeem_url": "https://apps.apple.com/redeem?ctx=offercodes&id=6741234567&code=PLUS5-A"])
        stub.on("GET", "/api/invites", 200, overview(arrived: 5, links: [link1], claimed5: true))
        let claimed = await m.claim(tier: 5, choice: .plus)
        let c = try XCTUnwrap(claimed)
        XCTAssertEqual(c.offerCode, "PLUS5-A")
        XCTAssertEqual(c.redeemURL?.absoluteString, "https://apps.apple.com/redeem?ctx=offercodes&id=6741234567&code=PLUS5-A")
        XCTAssertEqual(m.lastClaim, c, "Blatt mit Code und Apple-Link")
        let after = try XCTUnwrap(m.overview)
        XCTAssertEqual(after.tiers[0].claimed?.offerCode, "PLUS5-A")
        XCTAssertFalse(after.tiers[0].claimable, "jede Stufe einmal")
        XCTAssertEqual(stub.count("POST", "/api/invites/claim"), 1)
        // leerer Vorrat: deutscher Text des Dienstes, Stufe bleibt einloesbar
        stub.on("POST", "/api/invites/claim", 409, ["detail": "Für diese Belohnung sind gerade keine Codes hinterlegt – bitte später noch einmal versuchen.",
                                                    "code": "offer_codes_exhausted"])
        let none = await m.claim(tier: 10, choice: .plus)
        XCTAssertNil(none)
        XCTAssertEqual(m.message, "Für diese Belohnung sind gerade keine Codes hinterlegt – bitte später noch einmal versuchen.")
        XCTAssertTrue(SafeLinks.allows(try XCTUnwrap(c.redeemURL)), "Apples Einloese-Dialog ist ein https-Link und darf ins System")
    }

    // MARK: gemerkter Code bis zum Konto

    func testPendingInviteWaitsForTheAccountAndRedeemsOnce() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "invite-test-\(UUID().uuidString)"))
        defer { PendingInvite.clear(defaults: defaults) }
        let stub = StubTransport()
        let acc = account(stub)
        let r1 = await PendingInvite.redeem(using: acc, signedIn: true, defaults: defaults)
        XCTAssertEqual(r1, .none, "nichts gemerkt")
        PendingInvite.store("AB2CD3EFGH", defaults: defaults)
        let r2 = await PendingInvite.redeem(using: acc, signedIn: false, defaults: defaults)
        XCTAssertEqual(r2, .none, "noch kein Konto: liegen lassen")
        XCTAssertEqual(PendingInvite.current(defaults: defaults), "AB2CD3EFGH")
        XCTAssertEqual(stub.requests.count, 0)
        // Dienst nicht erreichbar: liegen lassen
        let offline = account(StubTransport(), token: nil)        // ohne Token: 401 unauthenticated vor jedem Aufruf
        let r3 = await PendingInvite.redeem(using: offline, signedIn: true, defaults: defaults)
        XCTAssertEqual(r3, .retryLater)
        XCTAssertEqual(PendingInvite.current(defaults: defaults), "AB2CD3EFGH")
        // mit Konto: einmal einloesen, dann weg
        stub.on("POST", "/api/invites/redeem", 200, ["redeemed": true, "already": false, "code": "AB2CD3EFGH"])
        let r4 = await PendingInvite.redeem(using: acc, signedIn: true, defaults: defaults)
        XCTAssertEqual(r4, .accepted)
        XCTAssertNil(PendingInvite.current(defaults: defaults))
        let r5 = await PendingInvite.redeem(using: acc, signedIn: true, defaults: defaults)
        XCTAssertEqual(r5, .none)
        XCTAssertEqual(stub.count("POST", "/api/invites/redeem"), 1)
        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(sent.body))["code"]?.string, "AB2CD3EFGH")
        // endgueltige Absage (eigener Link): Code weg, Text fuer die Meldung
        PendingInvite.store("AB2CD3EFGH", defaults: defaults)
        stub.on("POST", "/api/invites/redeem", 400, ["detail": "Den eigenen Einladungslink kannst du nicht einlösen.", "code": "invite_self"])
        let r6 = await PendingInvite.redeem(using: acc, signedIn: true, defaults: defaults)
        XCTAssertEqual(r6, .rejected("Den eigenen Einladungslink kannst du nicht einlösen."))
        XCTAssertNil(PendingInvite.current(defaults: defaults))
        XCTAssertEqual(PendingInvite.toast(.none), InviteTexts.received)
        XCTAssertEqual(PendingInvite.toast(.accepted), InviteTexts.accepted)
        XCTAssertNil(PendingInvite.toast(.retryLater))
    }

    func testOpenedLinksAreInvitesOnlyForTheSiteOrTheInviteScheme() throws {
        XCTAssertEqual(InviteLink.code(from: try XCTUnwrap(URL(string: "https://studinow.app/i/AB2CD3EFGH"))), "AB2CD3EFGH")
        XCTAssertEqual(InviteLink.code(from: try XCTUnwrap(URL(string: "uniflow://invite/AB2CD3EFGH"))), "AB2CD3EFGH")
        // Hash-Routen und Lerngruppen bleiben, was sie sind
        XCTAssertNil(InviteLink.code(from: try XCTUnwrap(URL(string: "uniflow://#/plan?view=week"))))
        XCTAssertNil(InviteLink.code(from: try XCTUnwrap(URL(string: "uniflow://community/join/ABCDEFGH"))))
        XCTAssertNotNil(CommunityJoinLink.code(from: try XCTUnwrap(URL(string: "uniflow://community/join/ABCDEFGH"))))
        XCTAssertEqual(UFRoute.hash(fromDeepLink: try XCTUnwrap(URL(string: "uniflow://#/plan?view=week"))), "#/plan?view=week")
    }

    func testQRCodeIsGeneratedOnDevice() {
        let img = InviteQR.image("https://studinow.app/i/AB2CD3EFGH")
        XCTAssertNotNil(img)
        XCTAssertGreaterThan(img?.size.width ?? 0, 200)
        XCTAssertNotNil(InviteQR.image(InviteLink.schemeURL(code: "AB2CD3EFGH").absoluteString))
    }
}
