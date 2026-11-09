import StoreKit
import StoreKitTest
import UniFlowCore
import XCTest
@testable import UniFlow

/// Audit-Paket 78 (09.11.2026, docs/audit/AUDIT-2026-11-09-PAKET-67-69-75-78-79-86.md), P78-F1/P78-01/P78-02:
/// `Entitlements.handle` ruft `transaction.finish()` auch dann, wenn die Meldung an den Dienst scheitert. Das ist nach
/// Apples Regeln richtig: `finish()` bestaetigt nur, dass die App den Kauf auf dem Geraet zugestellt hat; ein Abo bleibt
/// in `Transaction.currentEntitlements` (auch abgeschlossen) und wird beim naechsten `StudoraAccountLink.refresh()`
/// (jeder Start, jeder Wechsel in den Vordergrund) erneut an `POST /api/billing/apple/verify` gemeldet (P36-02).
/// Hier Ende-zu-Ende mit StoreKitTest (echter Kauf in der Testsitzung, echte JWS) und Schein-Dienst, nie ins Netz:
/// Kauf Pro AI, Dienst antwortet 503 bzw. Zeitueberschreitung -> iPad hat Pro AI, Dienst noch Free; danach ist der Dienst
/// wieder da -> naechster Vordergrund bzw. Neustart meldet denselben Kauf erneut, Dienst-Tarif Pro AI, 100 Credits.
@MainActor
final class PurchaseServiceRetryP78Tests: StoreKitSessionTestCase {
    /// Schein-Dienst: Konto A; `/api/billing/apple/verify` je nach `mode`, `/api/entitlements` je nach `paid`
    final class Service: ServiceHTTPTransport, @unchecked Sendable {
        enum Mode { case unavailable, timeout, ok }
        private let lock = NSLock()
        private var _mode: Mode = .unavailable
        private var _paid = false
        private var _verified: [String] = []
        var mode: Mode {
            get { lock.withLock { _mode } }
            set { lock.withLock { _mode = newValue } }
        }
        /// Kauf beim Dienst angekommen? Erst nach einer erfolgreichen Pruefung meldet der Dienst Pro AI.
        var paid: Bool { lock.withLock { _paid } }
        /// alle gemeldeten JWS (auch die gescheiterten)
        var verified: [String] { lock.withLock { _verified } }

        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            let path = String(r.url.dropFirst("https://dienst.example".count))
            switch (r.method, path) {
            case ("GET", "/api/account/me"):
                return Self.reply(200, ["user": ["id": .string(PurchaseAccountLinkP36Tests.userA), "email": "a@beispiel.de",
                                                 "email_verified": true, "university": "luh", "plan": "free", "role": "user"],
                                        "sessions": []])
            case ("GET", "/api/entitlements"):
                let paid = self.paid
                return Self.reply(200, ["plan": .string(paid ? "pro_ai" : "free"),
                                        "apple_account_token": .string(PurchaseAccountLinkP36Tests.tokenA),
                                        "credits": ["period": "2026-11", "allowance": .number(paid ? 100 : 0), "used": 0,
                                                    "reserved": 0, "remaining": .number(paid ? 100 : 0)]])
            case ("POST", "/api/billing/apple/verify"):
                let body = (try? JSONValue.parse(r.body ?? Data())) ?? .null
                let jws = body["signed_transaction"]?.string ?? ""
                let mode = lock.withLock { () -> Mode in _verified.append(jws); return _mode }
                switch mode {
                case .timeout: throw URLError(.timedOut)
                case .unavailable:
                    return Self.reply(503, ["detail": "Apple-Pruefung nicht eingerichtet", "code": "apple_not_configured"])
                case .ok:
                    lock.withLock { _paid = true }
                    return Self.reply(200, ["plan": "pro_ai"])
                }
            default:
                return ServiceHTTPResponse(status: 404, body: Data())
            }
        }

        private static func reply(_ status: Int, _ body: JSONValue) -> ServiceHTTPResponse {
            ServiceHTTPResponse(status: status, body: body.serialized())
        }
    }

    /// Nutzdaten einer JWS (mittlerer Teil, base64url) als JSON
    static func payload(_ jws: String) -> JSONValue? {
        let parts = jws.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b).flatMap { try? JSONValue.parse($0) }
    }

    /// Konto-Anschluss wie in der App nach dem Start (ein Prozess = ein `StudoraAccountLink` + eigenes `Entitlements`)
    private func start(_ service: Service, tokens: PurchaseAccountLinkP36Tests.MemoryTokens) async -> (StudoraAccountLink, Entitlements) {
        let ent = Entitlements(observe: false)
        let l = StudoraAccountLink(entitlements: ent)
        l.attachForTesting(account: StudoraAccount(base: "https://dienst.example", http: service, tokens: tokens,
                                                   deviceID: "ipad-test", deviceName: "iPad"),
                           scope: "p78-\(UUID().uuidString)")
        l.attach(creditsClient: StudoraCredits.Client(base: "https://dienst.example", http: service, tokens: tokens))
        await ent.refresh()
        await l.refresh()
        return (l, ent)
    }

    override func tearDown() async throws {
        UFBillingServiceLink.accountToken = nil
        Entitlements.shared.useServiceTrial(nil)
        try await super.tearDown()
    }

    /// Kauf Pro AI, waehrend die Meldung an den Dienst scheitert. Rueckgabe: Anschluss, Tarif und Nutzdaten der ersten JWS.
    private func buyWhileTheServiceFails(_ service: Service, tokens: PurchaseAccountLinkP36Tests.MemoryTokens)
        async throws -> (StudoraAccountLink, Entitlements, JSONValue) {
        let (l, ent) = await start(service, tokens: tokens)
        XCTAssertEqual(l.user?.id, PurchaseAccountLinkP36Tests.userA)
        XCTAssertEqual(l.planStatus?.plan, "free")
        XCTAssertEqual(service.verified.count, 0, "vor dem Kauf nichts zu melden")
        XCTAssertNotNil(ent.verifyOnServer, "angemeldet: Kauf geht an den Dienst")

        let store = PurchaseStore(entitlements: ent, productIDs: Self.productIDs)
        await store.loadProducts()
        let pro = try XCTUnwrap(store.product(for: .proAI))
        let outcome = await store.purchase(pro)
        XCTAssertEqual(outcome, .success, "ein Fehler des Dienstes sperrt den Kauf nie (P36-01)")
        XCTAssertNil(store.lastError)
        XCTAssertEqual(ent.plan, .proAI, "auf dem iPad gilt der Kauf sofort")
        XCTAssertEqual(service.verified.count, 1, "der Kauf wurde gemeldet")
        let first = try XCTUnwrap(Self.payload(service.verified.first ?? ""))
        XCTAssertEqual(first["productId"]?.string, UFPlan.proAI.productID)
        XCTAssertEqual(first["appAccountToken"]?.string?.uppercased(), PurchaseAccountLinkP36Tests.tokenA,
                       "der Kauf traegt das Konto (P36-04)")
        XCTAssertEqual(l.planStatus?.plan, "free", "der Dienst kennt den Kauf noch nicht")
        XCTAssertEqual(l.credits?.allowance, 0)

        // `Entitlements.handle` hat die Transaktion schon abgeschlossen (`finish()` laeuft immer, Entitlements.swift).
        // `Transaction.unfinished` ist in der StoreKit-Testsitzung dafuer kein verlaesslicher Zeuge (meldet die
        // abgeschlossene Transaktion manchmal noch Sekunden spaeter), darum hier nicht geprueft. Entscheidend:
        // das Abo steht weiter in currentEntitlements, daraus kommt die Nachmeldung
        var listed: [String] = []
        for await r in StoreKit.Transaction.currentEntitlements { if case .verified(let t) = r { listed.append(t.productID) } }
        XCTAssertEqual(listed, [UFPlan.proAI.productID!])

        // Dienst weiter gestoert: der naechste Vordergrund versucht es erneut, der Kauf bleibt
        await l.refresh()
        XCTAssertEqual(service.verified.count, 2, "naechster Vordergrund meldet erneut")
        XCTAssertEqual(ent.plan, .proAI)
        XCTAssertEqual(l.planStatus?.plan, "free")
        return (l, ent, first)
    }

    /// P78-01: Dienst antwortet 503 (`apple_not_configured`); nach einem Neustart der App (neuer Prozess) mit
    /// erreichbarem Dienst sind Tarif und Credits beim Dienst nachgetragen
    func testPurchaseAfterServiceUnavailableIsCaughtUpAfterRestart() async throws {
        let service = Service()
        service.mode = .unavailable
        let tokens = PurchaseAccountLinkP36Tests.MemoryTokens("tok")
        let (_, _, first) = try await buyWhileTheServiceFails(service, tokens: tokens)

        service.mode = .ok
        let (l, ent) = await start(service, tokens: tokens)          // Neustart: neuer Anschluss, neues Entitlements
        XCTAssertEqual(service.verified.count, 3, "der Start meldet den Kauf erneut")
        XCTAssertEqual(Self.payload(service.verified.dropFirst(2).first ?? "")?["originalTransactionId"], first["originalTransactionId"],
                       "dieselbe Transaktion")
        XCTAssertEqual(ent.plan, .proAI)
        XCTAssertEqual(l.planStatus?.plan, "pro_ai", "Dienst-Tarif nachgeholt")
        XCTAssertEqual(l.credits?.allowance, 100, "Credits von Pro AI")
        XCTAssertEqual(l.credits?.remaining, 100)
    }

    /// P78-02: Zeitueberschreitung bei der Pruefung; der naechste Vordergrund (gleicher Prozess) holt nach, danach keine
    /// weitere Meldung in diesem Prozess (der Dienst ist ohnehin idempotent, P36-02/P44-09)
    func testPurchaseAfterServiceTimeoutIsCaughtUpOnTheNextForeground() async throws {
        let service = Service()
        service.mode = .timeout
        let tokens = PurchaseAccountLinkP36Tests.MemoryTokens("tok")
        let (l, ent, first) = try await buyWhileTheServiceFails(service, tokens: tokens)

        service.mode = .ok
        await l.refresh()                                           // Wechsel in den Vordergrund (UniFlowApp, scenePhase)
        XCTAssertEqual(service.verified.count, 3)
        XCTAssertEqual(Self.payload(service.verified.dropFirst(2).first ?? "")?["originalTransactionId"], first["originalTransactionId"])
        XCTAssertEqual(ent.plan, .proAI)
        XCTAssertEqual(l.planStatus?.plan, "pro_ai", "Dienst-Tarif nachgeholt")
        XCTAssertEqual(l.credits?.allowance, 100, "Credits von Pro AI")

        await l.refresh()
        XCTAssertEqual(service.verified.count, 3, "nach Erfolg nicht bei jedem Vordergrund erneut")
    }
}
