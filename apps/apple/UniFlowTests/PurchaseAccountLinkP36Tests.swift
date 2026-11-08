import StoreKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Audit-Paket 36 (08.11.2026, docs/audit/AUDIT-2026-11-08-PAKET-36.md): Kauf und StudiNow-Konto. Der Kauf bekommt mit
/// Anmeldung immer das `appAccountToken` des Kontos (auch ohne Antwort von `GET /api/entitlements`), und eine spaete
/// Antwort des Dienstes zu einem Kauf landet nach einem Kontowechsel nicht beim neuen Konto. Schein-Dienst, nie ins Netz.
@MainActor
final class PurchaseAccountLinkP36Tests: XCTestCase {
    /// Schein-Dienst: je Methode + Pfad eine feste Antwort (wiederholt); `/api/billing/apple/verify` antwortet verzoegert
    final class SlowStub: ServiceHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: (Int, JSONValue)] = [:]
        let verifyDelay: UInt64
        init(verifyDelay: UInt64 = 0) { self.verifyDelay = verifyDelay }
        func on(_ method: String, _ path: String, _ status: Int, _ body: JSONValue) {
            lock.withLock { replies["\(method) \(path)"] = (status, body) }
        }
        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            let path = String(r.url.dropFirst("https://dienst.example".count))
            if path == "/api/billing/apple/verify", verifyDelay > 0 { try await Task.sleep(nanoseconds: verifyDelay) }
            return lock.withLock {
                guard let (status, body) = replies["\(r.method) \(path)"] else { return ServiceHTTPResponse(status: 404, body: Data()) }
                return ServiceHTTPResponse(status: status, body: body.serialized())
            }
        }
    }

    final class MemoryTokens: AccountTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        init(_ t: String?) { token = t }
        func load() -> String? { lock.withLock { token } }
        func save(_ t: String?) throws { lock.withLock { token = t } }
    }

    static let userA = "0123456789abcdef0123456789abcdef"
    static let tokenA = "01234567-89AB-CDEF-0123-456789ABCDEF"

    private func link(_ stub: SlowStub) -> StudoraAccountLink {
        stub.on("GET", "/api/account/me", 200, ["user": ["id": .string(Self.userA), "email": "a@beispiel.de", "email_verified": true,
                                                          "university": "luh", "plan": "pro_ai", "role": "user"],
                                                 "sessions": []])
        let l = StudoraAccountLink(entitlements: Entitlements(observe: false))
        l.attachForTesting(account: StudoraAccount(base: "https://dienst.example", http: stub, tokens: MemoryTokens("tok"),
                                                   deviceID: "ipad-test", deviceName: "iPad"),
                           scope: "p36-a-\(UUID().uuidString)")
        return l
    }

    override func tearDown() async throws {
        UFBillingServiceLink.accountToken = nil
        Entitlements.shared.useServiceTrial(nil)
        try await super.tearDown()
    }

    /// P36-04: Token = gemeldetes `apple_account_token`, sonst die UniFlow-ID als UUID; ohne Konto keins
    func testAccountTokenRule() {
        XCTAssertEqual(UFBillingServiceLink.accountToken(service: nil, userID: Self.userA), Self.tokenA)
        XCTAssertEqual(UFBillingServiceLink.accountToken(service: nil, userID: Self.userA.uppercased()), Self.tokenA)
        let other = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        XCTAssertEqual(UFBillingServiceLink.accountToken(service: other, userID: Self.userA), other, "der Dienst hat Vorrang")
        XCTAssertEqual(UFBillingServiceLink.accountToken(service: "keine-uuid", userID: Self.userA), Self.tokenA)
        XCTAssertNil(UFBillingServiceLink.accountToken(service: nil, userID: nil), "ohne Konto kein Token")
        XCTAssertNil(UFBillingServiceLink.accountToken(service: nil, userID: "kein-hex"))
        XCTAssertEqual(UFBillingServiceLink.purchaseOptions(accountToken: UFBillingServiceLink.accountToken(service: nil, userID: Self.userA), enabled: true),
                       [.appAccountToken(try! XCTUnwrap(UUID(uuidString: Self.tokenA)))])
    }

    /// P36-04: Angemeldet, aber `GET /api/entitlements` antwortet nicht: der naechste Kauf traegt trotzdem das Konto
    /// (vorher ohne appAccountToken, der Kauf gehoerte dann dem Konto, das ihn zuerst meldet). Abmelden entfernt es.
    func testPurchaseCarriesAccountTokenEvenWithoutEntitlementsAnswer() async {
        let stub = SlowStub()
        stub.on("GET", "/api/entitlements", 503, ["detail": "Wartung", "code": "unavailable"])
        let l = link(stub)
        await l.refresh()
        XCTAssertEqual(l.user?.id, Self.userA)
        XCTAssertNil(l.planStatus)
        XCTAssertEqual(UFBillingServiceLink.accountToken, Self.tokenA)
        await l.logout()
        XCTAssertNil(UFBillingServiceLink.accountToken, "nach dem Abmelden kein Token mehr")
    }

    /// P36-03: Kontowechsel, waehrend die Pruefung eines Kaufs beim Dienst laeuft: Tarif, Probe und appAccountToken des
    /// alten Kontos duerfen danach nicht beim neuen Konto stehen.
    func testLateVerifyAnswerAfterAccountSwitchIsDiscarded() async throws {
        let stub = SlowStub(verifyDelay: 600_000_000)
        stub.on("GET", "/api/entitlements", 200, ["plan": "pro_ai", "apple_account_token": .string(Self.tokenA),
                                                  "trial": ["active": true, "days_left": 3, "plan": "pro_ai"]])
        let l = link(stub)
        await l.refresh()
        XCTAssertEqual(l.planStatus?.plan, "pro_ai")
        stub.on("POST", "/api/billing/apple/verify", 200, ["plan": "pro_ai"])
        let report = Task { await l.reportTransaction("jws-konto-a") }
        try await Task.sleep(nanoseconds: 150_000_000)
        l.use(userScope: "p36-b-\(UUID().uuidString)")          // anderer Apple-Nutzer auf diesem iPad
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(l.planStatus)
        await report.value
        XCTAssertNil(l.user)
        XCTAssertNil(l.planStatus, "Stand von Konto A darf nicht beim neuen Konto stehen")
        XCTAssertNil(UFBillingServiceLink.accountToken, "kein Token von Konto A fuer den naechsten Kauf")
        l.use(userScope: nil)
    }
}
