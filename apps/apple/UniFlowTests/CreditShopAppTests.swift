import StoreKit
import StoreKitTest
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// KI-Credits zum Nachkaufen in der App (Auftrag des Inhabers vom 15.11.2026, docs/KI-CREDITS-2026-11-15.md).
/// Ende-zu-Ende mit StoreKitTest (echter Verbrauchskauf in der Testsitzung, echte JWS; Konfiguration `UniFlow.storekit`
/// mit den zwei Paketen) und Schein-Dienst, nie ins Netz:
/// - der Kauf geht an den Dienst und wird erst danach abgeschlossen; ohne Antwort bleibt er offen und wird beim
///   naechsten Start nachgeholt, verbucht wird genau einmal
/// - `Entitlements.handle` (Transaction.updates) schliesst ein Paket nie selbst ab
/// - das Blatt "Deine Credits sind aufgebraucht" mit beiden Paketen (Preis aus dem Store), dem Satz zu den gekauften
///   Credits und "Nicht jetzt", am iPad und am iPhone ohne gequetschte Beschriftungen
/// - der Stand beider Toepfe in den Einstellungen und an den KI-Stellen
@MainActor
final class CreditShopAppTests: StoreKitSessionTestCase {
    /// Schein-Dienst: Konto A mit Pro AI; verbucht jede Transaktion genau einmal wie app/credits.py
    final class Service: ServiceHTTPTransport, @unchecked Sendable {
        enum Mode { case unavailable, timeout, ok }
        private let lock = NSLock()
        private var _mode: Mode = .ok
        private var _reported: [JSONValue] = []
        private var granted: [String: Int] = [:]
        private var refunded: Set<String> = []
        private var _canBuy = true
        private var _monthLeft = 0

        var mode: Mode {
            get { lock.withLock { _mode } }
            set { lock.withLock { _mode = newValue } }
        }
        var canBuy: Bool {
            get { lock.withLock { _canBuy } }
            set { lock.withLock { _canBuy = newValue } }
        }
        var monthLeft: Int {
            get { lock.withLock { _monthLeft } }
            set { lock.withLock { _monthLeft = newValue } }
        }
        /// Nutzdaten aller gemeldeten Transaktionen (auch der gescheiterten Meldungen)
        var reported: [JSONValue] { lock.withLock { _reported } }
        /// gekaufte Credits des Kontos
        var purchased: Int { lock.withLock { granted.filter { !refunded.contains($0.key) }.values.reduce(0, +) } }
        /// wie oft gutgeschrieben wurde (je Transaktion hoechstens einmal)
        var grants: Int { lock.withLock { granted.count } }

        func credits() -> JSONValue {
            let bought = purchased, left = monthLeft
            return ["period": "2026-11", "allowance": 100, "used": .number(Double(100 - left)), "reserved": 0, "remaining": .number(Double(left)),
                    "plan": "pro_ai", "resets_at": "2026-12-01T00:00:00+01:00", "credit_eur": 0.0065, "purchased": .number(Double(bought)),
                    "purchased_usable": true, "available": .number(Double(left + bought)), "can_buy": .bool(canBuy)]
        }

        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            let path = String(r.url.dropFirst("https://dienst.example".count))
            switch (r.method, path) {
            case ("GET", "/api/account/me"):
                return Self.reply(200, ["user": ["id": .string(PurchaseAccountLinkP36Tests.userA), "email": "a@beispiel.de",
                                                 "email_verified": true, "university": "luh", "plan": "pro_ai", "role": "user"],
                                        "sessions": []])
            case ("GET", "/api/entitlements"):
                return Self.reply(200, ["plan": "pro_ai", "paid_plan": "pro_ai", "apple_account_token": .string(PurchaseAccountLinkP36Tests.tokenA),
                                        "credits": credits(),
                                        "credit_packs": ["packs": [["product_id": "de.uniflow.credits.klein", "credits": 100],
                                                                   ["product_id": "de.uniflow.credits.gross", "credits": 200]]]])
            case ("POST", CreditPacks.purchasePath):
                let body = (try? JSONValue.parse(r.body ?? Data())) ?? .null
                let tx = Self.payload(body["signed_transaction"]?.string ?? "") ?? .null
                let mode = lock.withLock { () -> Mode in _reported.append(tx); return _mode }
                switch mode {
                case .timeout: throw URLError(.timedOut)
                case .unavailable:
                    return Self.reply(503, ["detail": "Apple-Pruefung nicht eingerichtet", "code": "apple_not_configured"])
                case .ok:
                    // StoreKitTest schreibt die Kennung als Zahl oder Text
                    let id = tx["transactionId"]?.string ?? tx["transactionId"]?.double.map { String(Int($0)) } ?? ""
                    let product = tx["productId"]?.string ?? ""
                    let size = product.hasSuffix(".gross") ? 200 : 100
                    let (status, added, removed): (String, Int, Int) = lock.withLock {
                        if tx["revocationDate"] != nil, tx["revocationDate"]?.isNull == false {
                            let had = granted[id] != nil && !refunded.contains(id)
                            refunded.insert(id)
                            return (had ? "refunded" : "already_refunded", 0, had ? size : 0)
                        }
                        if refunded.contains(id) { return ("refunded", 0, 0) }
                        if granted[id] != nil { return ("already_granted", 0, 0) }
                        granted[id] = size
                        return ("granted", size, 0)
                    }
                    return Self.reply(200, ["status": .string(status), "credits_added": .number(Double(added)), "credits_removed": .number(Double(removed)),
                                            "product_id": .string(product), "transaction_id": .string(id), "environment": "Xcode",
                                            "other_account": false, "sandbox_limited": false, "credits": credits()])
                }
            default:
                return ServiceHTTPResponse(status: 404, body: Data())
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

        private static func reply(_ status: Int, _ body: JSONValue) -> ServiceHTTPResponse {
            ServiceHTTPResponse(status: status, body: body.serialized())
        }
    }

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    override func tearDown() async throws {
        UFBillingServiceLink.accountToken = nil
        Entitlements.shared.useServiceTrial(nil)
        UFCompact.phoneOverride = UniFlowTestsPrincipal.deviceDefault
        try await super.tearDown()
    }

    /// Konto-Anschluss wie in der App nach dem Start: eigener Tarif, eigener Laden fuer Credit-Pakete
    private func start(_ service: Service, tokens: PurchaseAccountLinkP36Tests.MemoryTokens = .init("tok")) async -> (StudoraAccountLink, Entitlements, CreditStore) {
        let ent = Entitlements(observe: false, plan: .proAI)
        let l = StudoraAccountLink(entitlements: ent)
        let store = CreditStore()
        l.creditStore = store
        l.attachForTesting(account: StudoraAccount(base: "https://dienst.example", http: service, tokens: tokens,
                                                   deviceID: "ipad-test", deviceName: "iPad"),
                           scope: "credits-\(UUID().uuidString)")
        l.attach(creditsClient: StudoraCredits.Client(base: "https://dienst.example", http: service, tokens: tokens))
        await l.refresh()
        await store.loadProducts()
        return (l, ent, store)
    }

    /// Dasselbe fuer Ansichtstests: sie laufen synchron und lassen die Hauptschleife laufen (`HostedEnvironment.wait`),
    /// damit Aufgaben aus Knoepfen und `.task` weiterkommen - in einer async-Testfunktion bleiben sie stehen
    private func startForViews(_ service: Service) -> (StudoraAccountLink, Entitlements, CreditStore) {
        var out: (StudoraAccountLink, Entitlements, CreditStore)?
        Task { @MainActor in out = await self.start(service) }
        let end = Date().addingTimeInterval(20)
        while out == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return out ?? (StudoraAccountLink(entitlements: Entitlements(observe: false)), Entitlements(observe: false), CreditStore())
    }

    /// offene (nicht abgeschlossene) Kaeufe von Credit-Paketen
    private func openPacks() async -> [StoreKit.Transaction] {
        var out: [StoreKit.Transaction] = []
        for await r in StoreKit.Transaction.unfinished {
            if case .verified(let t) = r, CreditPacks.isPack(t.productID) { out.append(t) }
        }
        return out
    }

    private func texts(_ view: UIView) -> [String] { LayoutWidthAuditTests.texts(view) }
    private func shows(_ view: UIView, _ text: String) -> Bool { texts(view).contains { $0.contains(text) } }
    private func button(_ label: String, in view: UIView) -> NSObject? {
        LayoutWidthAuditTests.elements(in: view).first { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label }
    }

    // MARK: Kauf

    /// Der Laden hat beide Pakete; Preise kommen aus StoreKit, die Zahl der Credits vom Dienst
    func testStoreOffersBothPacksWithPricesFromStoreKit() async throws {
        let service = Service()
        let (l, _, store) = await start(service)
        XCTAssertEqual(store.products.map(\.id), CreditPacks.productIDs)
        XCTAssertEqual(store.products.map(\.type), [.consumable, .consumable], "Verbrauchskaeufe, kein Abo")
        XCTAssertEqual(l.creditPacks, CreditPacks.defaultPacks)
        let small = try XCTUnwrap(store.product(for: l.creditPacks[0]))
        let big = try XCTUnwrap(store.product(for: l.creditPacks[1]))
        XCTAssertEqual(small.price, Decimal(string: "1.99"))
        XCTAssertEqual(big.price, Decimal(string: "3.99"))
        XCTAssertTrue(small.displayPrice.contains("1,99") && big.displayPrice.contains("3,99"), "\(small.displayPrice) / \(big.displayPrice)")
        // die Abos bleiben, wie sie sind: die Pakete stehen nicht im Laden der Tarife
        XCTAssertTrue(Set(PurchaseStore.productIDs).isDisjoint(with: CreditPacks.productIDs))
        XCTAssertNil(UFPlan.allCases.first { $0.productIDs.contains(where: CreditPacks.isPack) })
    }

    /// Kauf -> Dienst verbucht -> erst dann abgeschlossen; der Stand ist sofort da
    func testPurchaseIsBookedByTheServiceAndOnlyThenFinished() async throws {
        try requireVisibleTestPurchases()
        let service = Service()
        let (l, ent, store) = await start(service)
        XCTAssertEqual(l.credits?.purchased, 0)
        XCTAssertEqual(l.credits?.canBuy, true)
        let small = try XCTUnwrap(store.product(for: l.creditPacks[0]))
        let outcome = await store.purchase(small)
        guard case .booked(let result) = outcome else { return XCTFail("erwartet: verbucht, war \(outcome)") }
        XCTAssertEqual(result.status, .granted)
        XCTAssertEqual(result.creditsAdded, 100)
        XCTAssertEqual(store.notice, "100 Credits gutgeschrieben.")
        XCTAssertNil(store.message)
        XCTAssertEqual(l.credits?.purchased, 100, "der neue Stand gilt sofort")
        XCTAssertEqual(l.credits?.available, 100)
        // gemeldet wurde genau dieser Kauf, mit dem Konto
        XCTAssertEqual(service.reported.count, 1)
        let tx = try XCTUnwrap(service.reported.first)
        XCTAssertEqual(tx["productId"]?.string, "de.uniflow.credits.klein")
        XCTAssertEqual(tx["appAccountToken"]?.string?.uppercased(), PurchaseAccountLinkP36Tests.tokenA, "der Kauf traegt das Konto")
        let open = await openPacks()
        XCTAssertTrue(open.isEmpty, "nach der Antwort des Dienstes abgeschlossen")
        XCTAssertEqual(ent.plan, .proAI, "ein Paket aendert den Tarif nicht")
        XCTAssertEqual(ent.purchasedPlan, .free)

        // zweites, grosses Paket: 200 dazu
        let big = try XCTUnwrap(store.product(for: l.creditPacks[1]))
        guard case .booked(let second) = await store.purchase(big) else { return XCTFail("zweiter Kauf") }
        XCTAssertEqual(second.creditsAdded, 200)
        XCTAssertEqual(l.credits?.purchased, 300)
        XCTAssertEqual(service.grants, 2)
    }

    /// Dienst nicht erreichbar: bezahlt, aber nicht verbucht -> der Kauf bleibt offen und wird beim naechsten Start
    /// nachgeholt; gutgeschrieben wird genau einmal
    func testPaidButUnbookedPurchaseStaysOpenAndIsBookedOnceOnTheNextStart() async throws {
        try requireVisibleTestPurchases()
        for mode in [Service.Mode.unavailable, .timeout] {
            session.clearTransactions()
            let service = Service()
            service.mode = mode
            let tokens = PurchaseAccountLinkP36Tests.MemoryTokens("tok")
            let (l, _, store) = await start(service, tokens: tokens)
            let small = try XCTUnwrap(store.product(for: l.creditPacks[0]))
            let outcome = await store.purchase(small)
            XCTAssertEqual(outcome, .waiting, "\(mode)")
            XCTAssertEqual(store.notice, CreditText.pendingNotice, "ehrlich: bezahlt, wird nachgetragen")
            XCTAssertEqual(l.credits?.purchased, 0)
            XCTAssertEqual(service.grants, 0)
            var open = await openPacks()
            XCTAssertEqual(open.count, 1, "nicht abgeschlossen, solange der Dienst nicht verbucht hat (\(mode))")
            let id = try XCTUnwrap(open.first?.id)

            // Dienst immer noch weg: ein weiterer Versuch aendert nichts
            let none = await store.processUnfinished()
            XCTAssertEqual(none, 0)
            open = await openPacks()
            XCTAssertEqual(open.count, 1)

            // naechster Start, der Dienst ist wieder da: der offene Kauf wird nachgeholt
            service.mode = .ok
            let (next, _, _) = await start(service, tokens: tokens)
            XCTAssertEqual(next.credits?.purchased, 100, "nachgeholt (\(mode))")
            XCTAssertEqual(service.grants, 1)
            open = await openPacks()
            XCTAssertTrue(open.isEmpty, "jetzt abgeschlossen")
            XCTAssertTrue(service.reported.count >= 2, "derselbe Kauf wurde erneut gemeldet")
            let ids = Set(service.reported.compactMap { $0["transactionId"]?.string ?? $0["transactionId"]?.double.map { String(Int($0)) } })
            XCTAssertEqual(ids, [String(id)], "immer dieselbe Transaktion")
            // noch ein Start: nichts mehr offen, nichts doppelt
            let (again, _, _) = await start(service, tokens: tokens)
            XCTAssertEqual(again.credits?.purchased, 100)
            XCTAssertEqual(service.grants, 1)
        }
    }

    /// `Entitlements.handle` (Transaction.updates: Kaufanfrage freigegeben, Kauf auf diesem Geraet nachgeliefert) schliesst
    /// ein Paket nie selbst ab: ohne Abnehmer bleibt es offen, mit Abnehmer verbucht der Dienst und erst dann ist Schluss
    func testEntitlementsNeverFinishAPackThemselves() async throws {
        try requireVisibleTestPurchases()
        let service = Service()
        service.mode = .unavailable
        let (l, ent, store) = await start(service)
        let small = try XCTUnwrap(store.product(for: l.creditPacks[0]))
        let outcome = await store.purchase(small)
        XCTAssertEqual(outcome, .waiting)
        var pending: VerificationResult<StoreKit.Transaction>?
        for await r in StoreKit.Transaction.unfinished {
            if case .verified(let t) = r, CreditPacks.isPack(t.productID) { pending = r }
        }
        let result = try XCTUnwrap(pending)

        // ohne Abnehmer (z. B. vor der Anmeldung): nichts wird abgeschlossen, der Tarif zaehlt die Transaktion nicht
        let alone = Entitlements(observe: false)
        let handled = await alone.handle(result)
        XCTAssertTrue(handled)
        XCTAssertEqual(alone.transactionCount, 0)
        XCTAssertEqual(alone.plan, .free)
        var open = await openPacks()
        XCTAssertEqual(open.count, 1, "bleibt offen")

        // mit Abnehmer, Dienst wieder da: verbucht und abgeschlossen
        service.mode = .ok
        XCTAssertNotNil(ent.creditPurchase, "angemeldet: Pakete gehen an den Laden der Credits")
        _ = await ent.handle(result)
        open = await openPacks()
        XCTAssertTrue(open.isEmpty)
        XCTAssertEqual(l.credits?.purchased, 100)
        XCTAssertEqual(service.grants, 1)
        XCTAssertEqual(ent.transactionCount, 0, "kein Abo-Ereignis")
    }

    /// Ohne Anmeldung beim StudiNow-Konto wird nichts gekauft: die Credits gehoeren zum Konto
    func testWithoutAnAccountNothingIsBought() async throws {
        let store = CreditStore()
        await store.loadProducts()
        let small = try XCTUnwrap(store.products.first)
        UFBillingServiceLink.accountToken = nil
        let outcome = await store.purchase(small)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(store.message, CreditStore.signInFirst)
        XCTAssertTrue(session.allTransactions().isEmpty, "kein Kaufdialog, kein Kauf")
        let done = await store.processUnfinished()
        XCTAssertEqual(done, 0)
    }

    // MARK: Regeln und Texte der App

    /// Reichen die Credits nicht, fuehrt der Weg zum Blatt "Credits kaufen" - aber nur, wenn das Konto kaufen darf
    /// (Regel des Dienstes, `can_buy`); sonst wie bisher zum Tarif
    func testExhaustedErrorLeadsToTheShopOnlyWhenTheAccountMayBuy() {
        func error(canBuy: Bool?) -> APIError {
            var credits = #"{"period": "2026-11", "allowance": 100, "used": 100, "reserved": 0, "remaining": 0, "plan": "pro_ai", "resets_at": "2026-12-01T00:00:00+01:00", "needed": 3"#
            if let canBuy { credits += #", "purchased": 0, "purchased_usable": true, "available": 0, "can_buy": \#(canBuy)"# }
            return APIError(status: 429, body: Data((#"{"detail": "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.", "code": "credits_exhausted", "credits": "# + credits + "}}").utf8))
        }
        let link = StudoraAccountLink(entitlements: Entitlements(observe: false, plan: .proAI))
        XCTAssertEqual(StudoraAccountLink.errorAction(error(canBuy: true), account: link), .credits)
        XCTAssertEqual(link.credits?.canBuy, true)
        XCTAssertEqual(StudoraAccountLink.errorAction(error(canBuy: false), account: link), .plans, "Probe, Plus, Free: Weg zum Tarif")
        XCTAssertEqual(StudoraAccountLink.errorAction(error(canBuy: nil), account: link), .plans, "aelterer Dienst ohne das Feld")
        XCTAssertEqual(StudoraAccountLink.errorAction(error(canBuy: true), account: nil), .plans, "ohne Konto-Anschluss kein Kauf")
        XCTAssertEqual(StudoraAccountLink.errorButton(.credits), "Credits kaufen")
        XCTAssertEqual(StudoraAccountLink.errorButton(.plans), "Tarif ansehen")
        XCTAssertEqual(CreditShopSheet.title(.exhausted), "Deine Credits sind aufgebraucht")
        XCTAssertEqual(CreditShopSheet.title(.shop), "Credits kaufen")
        XCTAssertEqual(CreditShopSheet.packAccessibility(credits: 100, price: "1,99 €"), "100 Credits kaufen für 1,99 €")
        XCTAssertEqual(CreditShopSheet.packAccessibility(credits: 200, price: nil), "200 Credits, gerade nicht verfügbar")
        XCTAssertEqual(CreditShopSheet.packIdentifier("de.uniflow.credits.klein"), "credits.pack.klein")
        // die Karte auf der Tarifseite: mit Kaufrecht oder mit gekauften Credits (auch ruhenden), sonst nicht
        XCTAssertTrue(CreditShopCard.shows(CreditPacks.Balance(allowance: 100, remaining: 5, canBuy: true)))
        XCTAssertTrue(CreditShopCard.shows(CreditPacks.Balance(allowance: 0, remaining: 0, purchased: 60)))
        XCTAssertFalse(CreditShopCard.shows(CreditPacks.Balance(allowance: 0, remaining: 0)))
        XCTAssertFalse(CreditShopCard.shows(nil))
    }

    // MARK: Blatt und Anzeige (iPad und iPhone)

    private static let sizes: [(name: String, size: CGSize, phone: Bool)] = [
        ("iPad", CGSize(width: 1180, height: 820), false), ("iPhone 393", CGSize(width: 393, height: 852), true),
        ("iPhone 375", CGSize(width: 375, height: 812), true),
    ]

    /// Das Blatt: Titel, Stand beider Toepfe, beide Pakete mit Preis aus dem Store, der Satz zu den gekauften Credits,
    /// "Nicht jetzt"; nichts gequetscht; ein Kauf aus dem Blatt zeigt den neuen Stand
    func testSheetShowsBothPacksThePromiseAndNotNowOnIPadAndIPhone() throws {
        let service = Service()
        let (l, _, store) = startForViews(service)
        XCTAssertEqual(store.products.count, 2)
        for (name, size, phone) in Self.sizes {
            UFCompact.phoneOverride = phone
            var closed = false
            let sheet = CreditShopSheet(reason: .exhausted, link: l, store: store) { closed = true }
            let env = try hostWithEnvironment(sheet, size: size)
            if phone {
                env.hosting.traitOverrides.horizontalSizeClass = .compact
                env.hosting.traitOverrides.verticalSizeClass = .regular
            }
            XCTAssertTrue(env.wait { self.button("100 Credits kaufen für \(store.products.first?.displayPrice ?? "?")", in: env.view) != nil },
                          "\(name)\n" + texts(env.view).joined(separator: "\n"))
            let all = texts(env.view)
            XCTAssertTrue(all.contains("Deine Credits sind aufgebraucht"), name)
            XCTAssertTrue(all.contains("Diesen Monat: 0 von 100 (neu am 1. Dezember) · Gekauft: 0"), "\(name)\n" + all.joined(separator: "\n"))
            XCTAssertTrue(all.contains("Gekaufte Credits verfallen nicht. Deine 100 Monats-Credits gibt es am 1. Dezember wieder."), name)
            XCTAssertTrue(all.contains(CreditShopSheet.payNote), name)
            XCTAssertNotNil(button("200 Credits kaufen für \(store.products.last?.displayPrice ?? "?")", in: env.view), name)
            XCTAssertNotNil(button("Nicht jetzt", in: env.view), name)
            XCTAssertFalse(all.contains { $0.contains("0,65") || $0.contains("Cent") }, "kein Centwert fuer Nutzer: \(name)")
            // Preise stehen nirgends fest im Text, nur aus dem Store
            XCTAssertTrue(all.contains { $0.contains("1,99") } && all.contains { $0.contains("3,99") }, name)
            let squeezed = LayoutWidthAuditTests.squeezed(in: env.window)
            XCTAssertTrue(squeezed.isEmpty, "\(name): " + squeezed.map(\.text).joined(separator: "; "))
            XCTAssertTrue(button("Nicht jetzt", in: env.view)?.accessibilityActivate() ?? false, name)
            XCTAssertTrue(env.wait { closed }, name)
            env.window.isHidden = true
        }
    }

    /// Kauf aus dem Blatt: danach steht "100 Credits gutgeschrieben.", der Stand zeigt die gekauften, der Knopf heisst "Fertig"
    func testBuyingFromTheSheetShowsTheNewBalance() throws {
        try requireVisibleTestPurchases()
        let service = Service()
        let (l, _, store) = startForViews(service)
        let env = try hostWithEnvironment(CreditShopSheet(reason: .exhausted, link: l, store: store) {}, size: CGSize(width: 393, height: 852))
        let label = "100 Credits kaufen für \(store.products.first?.displayPrice ?? "?")"
        XCTAssertTrue(env.wait { self.button(label, in: env.view) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(button(label, in: env.view)?.accessibilityActivate() ?? false)
        XCTAssertTrue(env.wait(timeout: 20) { self.shows(env.view, "100 Credits gutgeschrieben.") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Diesen Monat: 0 von 100 (neu am 1. Dezember) · Gekauft: 100"), texts(env.view).joined(separator: "\n"))
        XCTAssertNotNil(button("Fertig", in: env.view))
        XCTAssertEqual(service.grants, 1)
    }

    /// Wer nicht kaufen darf, sieht keine Pakete, sondern ehrlich, was gilt; ruhende Credits bleiben beim Konto
    func testSheetWithoutBuyRightShowsNoPacks() throws {
        let service = Service()
        service.canBuy = false
        let (l, _, store) = startForViews(service)
        let env = try hostWithEnvironment(CreditShopSheet(reason: .shop, link: l, store: store) {}, size: CGSize(width: 393, height: 852))
        XCTAssertTrue(env.wait { self.shows(env.view, CreditText.buyNeedsProAI) }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Credits kaufen"))
        XCTAssertFalse(texts(env.view).contains { $0.contains("kaufen für") }, "keine Pakete, kein Preis")
        XCTAssertNotNil(button("Nicht jetzt", in: env.view))
        l.noteAIResponse(["credits": ["period": "2026-11", "allowance": 0, "used": 0, "remaining": 0, "plan": "plus",
                                      "purchased": 60, "purchased_usable": false, "available": 0, "can_buy": false]])
        XCTAssertEqual(CreditText.dormantNote(l.credits?.balance),
                       "Du hast noch 60 gekaufte Credits. Sie bleiben bei deinem Konto und sind wieder nutzbar, sobald StudiNow Pro AI läuft.")
    }

    /// KI-Hilfe: "Credits aufgebraucht" oeffnet das Blatt von selbst (statt einer Sackgasse) und bietet darunter
    /// "Credits kaufen"; am iPad und am iPhone
    func testExhaustedAnswerInTheTutorOpensTheSheet() throws {
        let service = Service()
        let (l, _, _) = startForViews(service)
        for (name, size, phone) in Self.sizes.prefix(2) {
            UFCompact.phoneOverride = phone
            let t = AIViewsAppTests.Transport()
            let id = "f-credits-\(UUID().uuidString.prefix(8))"
            t.answer("/api/index/file/\(id)/page/1", ["file_id": .string(id), "page": 1, "status": "none", "can_build": false])
            t.fail("/api/ai/tutor", 429, ["detail": "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.", "code": "credits_exhausted",
                                          "credits": service.credits()])
            let panel = TutorPanel(fileID: id, page: { 1 }, selection: { "" }, open: { _, _ in }, close: {})
                .environment(\.ufAIEnabled, true).environment(\.ufStudiNowAI, true).environment(\.ufAIAccess, .ready)
                .environment(\.ufStudoraAccount, l)
            let env = try hostWithEnvironment(panel, api: APIClient(base: URL(string: "http://erfunden.test/")!, transport: t),
                                              size: phone ? size : CGSize(width: 420, height: 820))
            XCTAssertTrue(env.wait { self.button("Zusammenfassen", in: env.view) != nil }, "\(name)\n" + texts(env.view).joined(separator: "\n"))
            XCTAssertNil(env.hosting.presentedViewController, name)
            XCTAssertTrue(button("Zusammenfassen", in: env.view)?.accessibilityActivate() ?? false, name)
            XCTAssertTrue(env.wait { self.shows(env.view, "Credits für diesen Monat aufgebraucht") }, "\(name)\n" + texts(env.view).joined(separator: "\n"))
            XCTAssertNotNil(button("Credits kaufen", in: env.view), "\(name): Knopf unter der Meldung")
            XCTAssertNil(button("Tarif ansehen", in: env.view), name)
            // das Blatt ist von selbst offen
            XCTAssertTrue(env.wait { env.hosting.presentedViewController != nil }, "\(name): Blatt offen")
            let sheet = try XCTUnwrap(env.hosting.presentedViewController)
            XCTAssertTrue(env.wait { self.shows(sheet.view, "Deine Credits sind aufgebraucht") }, "\(name)\n" + texts(sheet.view).joined(separator: "\n"))
            XCTAssertTrue(shows(sheet.view, "Gekaufte Credits verfallen nicht."), name)
            XCTAssertTrue(env.wait { self.texts(sheet.view).contains { $0.hasPrefix("100 Credits kaufen für") } }, "\(name)\n" + texts(sheet.view).joined(separator: "\n"))
            XCTAssertTrue(button("Nicht jetzt", in: sheet.view)?.accessibilityActivate() ?? false, name)
            XCTAssertTrue(env.wait { env.hosting.presentedViewController == nil }, "\(name): Blatt wieder zu")
            env.window.isHidden = true
        }
    }

    /// Einstellungen: Zeile "Credits" mit beiden Toepfen und dem Eintrag "Credits kaufen"; die Karte der Tarifseite
    func testSettingsRowAndPlanCardShowBothPots() throws {
        let service = Service()
        service.monthLeft = 37
        let (l, _, _) = startForViews(service)
        l.noteAIResponse(["credits": ["period": "2026-11", "allowance": 100, "used": 63, "remaining": 37, "plan": "pro_ai",
                                      "resets_at": "2026-12-01T00:00:00+01:00", "purchased": 80, "purchased_usable": true, "available": 117, "can_buy": true]])
        for (name, size, phone) in Self.sizes.prefix(2) {
            UFCompact.phoneOverride = phone
            let view = VStack(alignment: .leading, spacing: 12) {
                StudoraCreditsRow(link: l)
                CreditShopCard(link: l)
            }
            .padding(16).environment(\.ufStudoraAccount, l)
            let env = try hostWithEnvironment(view, size: size)
            XCTAssertTrue(env.wait { self.shows(env.view, "Diesen Monat: 37 von 100 (neu am 1. Dezember) · Gekauft: 80") },
                          "\(name)\n" + texts(env.view).joined(separator: "\n"))
            XCTAssertTrue(shows(env.view, "Gekaufte Credits verfallen nicht"), name)
            XCTAssertTrue(shows(env.view, CreditShopCard.title), name)
            XCTAssertNotNil(button("Credits kaufen", in: env.view), name)
            let squeezed = LayoutWidthAuditTests.squeezed(in: env.window).filter { !$0.text.hasPrefix("obere Haelfte") }
            XCTAssertTrue(squeezed.isEmpty, "\(name): " + squeezed.map(\.text).joined(separator: "; "))
            env.window.isHidden = true
        }
        XCTAssertEqual(StudoraAccountCard.aiLine(.ready, credits: l.credits, trial: false),
                       "StudiNow-KI bereit · Diesen Monat: 37 von 100 (neu am 1. Dezember) · Gekauft: 80")
        XCTAssertEqual(AICost.chargeLine(.init(credits: 3, replay: false), remaining: l.credits?.available), "– 3 Credits (117 übrig)")
    }
}
