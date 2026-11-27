import StoreKit
import StoreKitTest
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Neues Tarifmodell (Entscheidung des Inhabers vom 26.11.2026, ersetzt "nur Jahresabos" vom 09.11.2026): StudiNow Free;
/// StudiNow Plus mit allen Funktionen fuer 1,99 € im Monat oder 39,99 € einmalig fuer 5 Jahre (nicht verlaengerndes Abo,
/// das Ende rechnet die App: Kauf + 5 Jahre, 29.02. -> 28.02.); StudiNow Pro AI fuer 39,99 € im Jahr = Plus + 120 Credits je
/// Monat. Die StudiNow-KI nur mit Credits, Credits kaufen nur Plus und Pro AI. Vor jedem Kauf der Hinweis zur
/// Unabhaengigkeit von den Hochschulen (§ 327h BGB) mit Haken. Konfiguration `UniFlow.storekit` wie in der App.
@MainActor
final class TarifeNeuAppTests: StoreKitSessionTestCase {
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ iso: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: iso), iso) }

    override func tearDown() async throws {
        UFPurchaseNotice.confirm(in: UFPurchaseNotice.defaults, false)
        try await super.tearDown()
    }

    // MARK: Angebote

    func testOffersAndFormerProducts() {
        XCTAssertEqual(PurchaseStore.productIDs, ["de.uniflow.plus.monthly", "de.uniflow.plus.fuenfjahre", "de.uniflow.proai.yearly"])
        XCTAssertEqual(UFPlan.plus.productID, "de.uniflow.plus.monthly")
        XCTAssertEqual(UFPlan.proAI.productID, "de.uniflow.proai.yearly")
        XCTAssertNil(UFPlan.free.productID)
        XCTAssertEqual(UFOffer.plusFiveYears.plan, .plus)
        XCTAssertEqual(UFOffer.plusFiveYears.years, 5)
        XCTAssertNil(UFOffer.plusFiveYears.period)
        // nicht mehr verkauft, ein frueherer Kauf gilt weiter: Plus-Jahresabo als Plus, Pro-AI-Monatsabo als Pro AI
        let later = Date().addingTimeInterval(86_400)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [.init(productID: "de.uniflow.plus.yearly", expirationDate: later)], now: Date()), .plus)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [.init(productID: "de.uniflow.proai.monthly", expirationDate: later)], now: Date()), .proAI)
        XCTAssertFalse(PurchaseStore.productIDs.contains("de.uniflow.plus.yearly"))
        XCTAssertFalse(PurchaseStore.productIDs.contains("de.uniflow.proai.monthly"))
        XCTAssertTrue(UFPlan.plus.productIDs.contains("de.uniflow.plus.yearly"), "frueheres Plus zaehlt als Kauf von Plus")
    }

    func testStoreLoadsTheThreeOffersWithTheirKinds() async throws {
        let (store, _) = await makeStore()
        XCTAssertEqual(Set(store.products.map(\.id)), Set(UFOffer.allCases.map(\.productID)))
        let monthly = try XCTUnwrap(store.product(for: .plusMonthly))
        XCTAssertEqual(monthly.price, Decimal(string: "1.99"))
        XCTAssertEqual(monthly.type, .autoRenewable)
        XCTAssertEqual(monthly.ufPeriod.0, 1)
        XCTAssertEqual(monthly.ufPeriod.1, .month)
        let once = try XCTUnwrap(store.product(for: .plusFiveYears))
        XCTAssertEqual(once.price, Decimal(string: "39.99"))
        XCTAssertEqual(once.type, .nonRenewable)
        let pro = try XCTUnwrap(store.product(for: .proAIYearly))
        XCTAssertEqual(pro.price, Decimal(string: "39.99"))
        XCTAssertEqual(pro.ufPeriod.1, .year)
        XCTAssertEqual(store.product(for: .plus)?.id, monthly.id, "Hauptprodukt von Plus ist das Monatsabo")
        // Texte vor dem Kauf
        XCTAssertEqual(UFOfferText.onceSummary(price: "39,99 €", years: 5), "39,99 € einmalig, gilt 5 Jahre ab dem Kauf, verlängert sich nicht")
        XCTAssertEqual(UFOfferText.onceButton(price: "39,99 €", years: 5), "5 Jahre für 39,99 € einmalig")
        XCTAssertEqual(UFOfferText.summary(price: "1,99 €", period: (1, .month)), "1,99 €/Monat, verlängert sich monatlich, jederzeit zum Laufzeitende kündbar")
        XCTAssertTrue(PlanPickerView.legalText.contains("5 Jahre ab dem Kauf und verlängert sich nicht"), PlanPickerView.legalText)
        XCTAssertTrue(PlanPickerView.legalText.contains("24 Stunden vor Ablauf"))
    }

    // MARK: 5 Jahre einmalig: gilt 5 Jahre und danach nicht mehr

    func testFiveYearPurchaseCountsFiveYearsAndThenNoMore() throws {
        let bought = try date("2026-11-26T10:00:00Z")
        let end = try XCTUnwrap(UFOffer.plusFiveYears.end(purchasedAt: bought))
        XCTAssertEqual(end, try date("2031-11-26T10:00:00Z"), "Kaufzeit + 5 Jahre")
        let e = UFEntitlementEntry(productID: UFOffer.plusFiveYears.productID, purchaseDate: bought)
        XCTAssertTrue(e.isNonRenewing)
        XCTAssertEqual(e.effectiveExpiration, end)
        XCTAssertEqual(UFEntitlementResolver.rightsEnd(e), end)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [e], now: bought), .plus)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [e], now: end.addingTimeInterval(-60)), .plus, "am letzten Tag noch Plus")
        XCTAssertEqual(UFEntitlementResolver.plan(from: [e], now: end), .free, "danach nicht mehr")
        XCTAssertEqual(UFEntitlementResolver.plan(from: [e], now: end.addingTimeInterval(365 * 86_400)), .free)
        // ohne Kaufzeit gilt der einmalige Kauf nie (Apple liefert ihn in currentEntitlements auch nach Jahren)
        XCTAssertFalse(UFEntitlementResolver.isActive(UFEntitlementEntry(productID: UFOffer.plusFiveYears.productID), now: bought))
        // erstattet: sofort nicht mehr
        var refunded = e
        refunded.revocationDate = bought.addingTimeInterval(86_400)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [refunded], now: bought.addingTimeInterval(2 * 86_400)), .free)
        // 29. Februar: 28. Februar im Jahr ohne Schalttag (wie plans.offer_end im Dienst)
        XCTAssertEqual(UFOffer.plusFiveYears.end(purchasedAt: try date("2028-02-29T08:30:00Z")), try date("2033-02-28T08:30:00Z"))
        XCTAssertEqual(UFOffer.plusFiveYears.end(purchasedAt: try date("2027-03-01T00:00:00Z")), try date("2032-03-01T00:00:00Z"))
        XCTAssertNil(UFOffer.plusMonthly.end(purchasedAt: bought), "Abos meldet Apple selbst")
        // neben einem Monatsabo traegt der Kauf, der am laengsten reicht
        let monthly = UFEntitlementEntry(productID: UFOffer.plusMonthly.productID, expirationDate: bought.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(UFEntitlementResolver.carrying(.plus, in: [monthly, e], now: bought)?.productID, UFOffer.plusFiveYears.productID)
        XCTAssertEqual(UFEntitlementResolver.carrying(.plus, in: [monthly, e], now: end.addingTimeInterval(1)), nil)
        // Pro AI neben 5 Jahren Plus: Pro AI, danach wieder Plus
        let pro = UFEntitlementEntry(productID: UFOffer.proAIYearly.productID, expirationDate: bought.addingTimeInterval(365 * 86_400))
        XCTAssertEqual(UFEntitlementResolver.plan(from: [pro, e], now: bought), .proAI)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [pro, e], now: bought.addingTimeInterval(400 * 86_400)), .plus)
    }

    /// Kauf in der StoreKit-Testsitzung: Plus fuer 5 Jahre, kein Abo der Gruppe, Ende = Kauf + 5 Jahre, keine Verlaengerung
    func testFiveYearPurchaseInTheStore() async throws {
        try requireVisibleTestPurchases()
        let (store, ent) = await makeStore()
        let once = try XCTUnwrap(store.product(for: .plusFiveYears))
        let before = Date()
        let outcome = await store.purchase(once)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        await waitForPlan(ent, .plus)
        XCTAssertEqual(ent.plan, .plus)
        XCTAssertEqual(ent.purchasedPlan, .plus)
        XCTAssertEqual(ent.purchasedOffer, .plusFiveYears)
        XCTAssertEqual(ent.willRenew, false, "verlaengert sich nicht")
        XCTAssertNil(ent.pendingPlan)
        let expires = try XCTUnwrap(ent.expiresAt, "Ende des einmaligen Kaufs bekannt")
        let expected = try XCTUnwrap(Self.utc.date(byAdding: .year, value: 5, to: before))
        XCTAssertEqual(expires.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 120)
        XCTAssertTrue(ent.allows(.pencilWriting))
        XCTAssertTrue(ent.allows(.deviceSync), "Plus hat den Abgleich")
        XCTAssertTrue(UFRichNotes.allowed(plan: ent.plan), "Plus hat die neuen Schreibfunktionen")
        XCTAssertFalse(PlanPickerView.hasSubscription(purchased: ent.purchasedPlan, offer: ent.purchasedOffer, loading: false),
                       "kein Abo der Gruppe: Pro AI ist ein Kauf, kein Wechsel")
        XCTAssertFalse(PlanPickerView.showsOnceButton(purchased: ent.purchasedPlan, offer: ent.purchasedOffer, giftCovers: false, loaded: true),
                       "solange die 5 Jahre gelten, kein zweiter 5-Jahres-Knopf")
        XCTAssertTrue(UFOfferText.onceNote(.plus, until: expires).hasPrefix("Einmal bezahlt – StudiNow Plus gilt bis "))
    }

    // MARK: Pro AI 120 Credits

    func testProAIHas120CreditsEveryMonth() {
        XCTAssertEqual(UFPlan.proAI.monthlyCredits, 120)
        XCTAssertEqual(UFPlan.plus.monthlyCredits, 0)
        XCTAssertEqual(UFPlan.free.monthlyCredits, 0)
        XCTAssertEqual(UFPlanCard.included(.proAI).map(\.title), ["120 Credits für die StudiNow-KI – jeden Monat"])
        XCTAssertTrue(UFPlanCatalog.proAIServiceNote.contains("120 Credits im Monat, am 1. neu aufgeladen"))
        XCTAssertTrue(StudoraCreditsRow.explanation.contains("Pro AI hat 120 im Monat"), StudoraCreditsRow.explanation)
        // die Probe zeigt sich neben gekauftem Plus weiter (sie bringt noch 25 Credits), neben Pro AI nicht
        let t = UFLocalTrial.state(startedAt: Date(), now: Date())
        XCTAssertNotNil(UFShownTrial.make(service: .plus, serviceDaysLeft: 3, serviceEndsAt: nil, local: t, purchased: .plus))
        XCTAssertNil(UFShownTrial.make(service: .plus, serviceDaysLeft: 3, serviceEndsAt: nil, local: t, purchased: .proAI))
    }

    // MARK: KI nur mit Credits

    private func exhausted(_ credits: String) -> APIError {
        APIError(status: 429, body: Data(#"{"detail": {"detail": "Für die StudiNow-KI brauchst du Credits.", "code": "credits_exhausted", "credits": \#(credits)}}"#.utf8))
    }

    /// Plus ohne Credits: die KI-Stelle zeigt die Credit-Pakete (nicht den Tarif); Plus mit gekauften Credits: die KI ist
    /// bereit und die Sperre laesst die Anfrage durch
    func testPlusWithoutCreditsGetsThePacksAndWithCreditsTheAI() throws {
        let ent = Entitlements(observe: false, plan: .plus)
        ent.setPurchasedForTesting(.plus, offer: .plusMonthly)
        let link = StudoraAccountLink(entitlements: ent)
        // Plus angemeldet: dieselbe KI wie Pro AI (kein Nur-Chat mehr)
        XCTAssertEqual(StudiNowAIAccess.decide(serviceConfigured: true, signedIn: true, localPlan: ent.plan.rawValue, servicePlan: "plus",
                                               serviceTrialActive: false), .ready)
        XCTAssertFalse(StudiNowAIAccess.chatOnly(serviceConfigured: true, signedIn: true, localPlan: "plus", servicePlan: "plus", serviceTrialActive: false))
        // ohne Credits: gesperrt, Weg zu den Paketen
        let empty = #"{"period": "2026-11", "allowance": 0, "used": 0, "remaining": 0, "plan": "plus", "purchased": 0, "purchased_usable": true, "purchased_scope": "all", "available": 0, "can_buy": true}"#
        link.noteAIResponse(["credits": try JSONValue.parse(Data(empty.utf8))])
        XCTAssertEqual(link.credits?.available, 0)
        XCTAssertTrue(StudiNowCreditGate(link.credits?.balance).blocks(now: try date("2026-11-20T10:00:00Z")))
        XCTAssertTrue(link.mayBuyCredits)
        XCTAssertEqual(StudoraAccountLink.errorAction(exhausted(empty), account: link), .credits, "statt der KI die Credit-Kaufseite")
        // mit gekauften Credits: frei
        let bought = #"{"period": "2026-11", "allowance": 0, "used": 0, "remaining": 0, "plan": "plus", "purchased": 80, "purchased_usable": true, "purchased_scope": "all", "available": 80, "can_buy": true}"#
        link.noteAIResponse(["credits": try JSONValue.parse(Data(bought.utf8))])
        XCTAssertEqual(link.credits?.available, 80)
        XCTAssertFalse(StudiNowCreditGate(link.credits?.balance).blocks(now: try date("2026-11-20T10:00:00Z")))
        // Free: keine KI-Stelle frei, das Schloss "ab Plus"
        XCTAssertEqual(UFLock.ai(.aiHelp, plan: .free, aiEnabled: false), .plus)
        XCTAssertEqual(UFLock.ai(.aiHelp, plan: .plus, aiEnabled: false), nil, "Plus: kein Tarif-Schloss, nur Credits")
        XCTAssertEqual(StudiNowAIAccess.decide(serviceConfigured: true, signedIn: true, localPlan: "free", servicePlan: "free",
                                               serviceTrialActive: false), .planRequired)
    }

    /// Free kann keine Credits kaufen, die Probe allein auch nicht; bezahltes Plus und Pro AI duerfen
    func testFreeAndTrialAloneCannotBuyCredits() throws {
        let canBuyBalance = CreditPacks.Balance(allowance: 0, remaining: 0, canBuy: true)
        let free = Entitlements(observe: false, plan: .free)
        XCTAssertFalse(free.canBuyCredits)
        XCTAssertFalse(StudoraAccountLink.mayBuyCredits(canBuyBalance, entitlements: free), "Free: nie Pakete, auch wenn ein Dienst es meldete")
        let free2 = StudoraAccountLink(entitlements: free)
        let freeState = #"{"allowance": 0, "remaining": 0, "purchased": 0, "purchased_usable": false, "purchased_scope": "none", "can_buy": false, "plan": "free"}"#
        free2.noteAIResponse(["credits": try JSONValue.parse(Data(freeState.utf8))])
        XCTAssertEqual(StudoraAccountLink.errorAction(exhausted(freeState), account: free2), .plans, "Free: der Weg zu Plus oder Pro AI")
        // Probe allein (ohne Kauf)
        let trial = Entitlements(observe: false, plan: .free)
        trial.useLocalTrial(startedAt: Date(), now: Date())
        XCTAssertEqual(trial.plan, .plus, "Probe wie Plus")
        XCTAssertFalse(trial.canBuyCredits, "die laufende Probe allein darf nicht kaufen")
        // bezahlt
        let plus = Entitlements(observe: false, plan: .free)
        plus.setPurchasedForTesting(.plus, offer: .plusFiveYears)
        XCTAssertTrue(plus.canBuyCredits)
        XCTAssertTrue(StudoraAccountLink.mayBuyCredits(canBuyBalance, entitlements: plus))
        XCTAssertFalse(StudoraAccountLink.mayBuyCredits(CreditPacks.Balance(allowance: 0, remaining: 0, canBuy: false), entitlements: plus),
                       "der Dienst muss es auch erlauben")
        let pro = Entitlements(observe: false, plan: .free)
        pro.setPurchasedForTesting(.proAI, offer: .proAIYearly)
        XCTAssertTrue(pro.canBuyCredits)
        // Probe und gekauftes Plus: kaufen ja (bezahlt)
        plus.useLocalTrial(startedAt: Date(), now: Date())
        XCTAssertTrue(plus.canBuyCredits)
    }

    /// Eigener OpenAI-Schluessel: in jedem Tarif und ohne Credits (die KI-Stelle gilt als verbunden, kein Schloss)
    func testOwnOpenAIKeyNeedsNoCredits() {
        XCTAssertNil(UFLock.ai(.aiHelp, plan: .free, aiEnabled: true), "eigener Schluessel: kein Schloss, auch in Free")
        let local = LocalAI()
        final class Key: AIProvider, @unchecked Sendable {
            func answer(system: String, prompt: String) async throws -> String { "eigener Schlüssel" }
        }
        let key = Key()
        local.setKey(key)
        XCTAssertTrue(local.provider is Key, "eigener Schluessel vor der StudiNow-KI")
        XCTAssertFalse(key.isMetered, "kostet StudiNow nichts, keine Credits")
        XCTAssertTrue(local.backgroundProvider is Key)
    }

    // MARK: Hinweis vor dem Kauf (§ 327h BGB)

    func testBuyButtonOnlyAfterTheCheckmark() throws {
        XCTAssertFalse(PlanPickerView.canTapBuy(confirmed: false, busy: false), "ohne Haken kein Kauf")
        XCTAssertTrue(PlanPickerView.canTapBuy(confirmed: true, busy: false))
        XCTAssertFalse(PlanPickerView.canTapBuy(confirmed: true, busy: true))
        for part in ["unabhängiges Angebot", "nicht mit der LUH oder einer anderen Hochschule zusammen", "Stud.IP, QIS",
                     "nicht zugesichert", "kann sie wegfallen", "kein Grund für eine Rückerstattung", "soweit das Gesetz nichts anderes vorschreibt"] {
            XCTAssertTrue(UFPurchaseNotice.text.contains(part), part)
        }
        // einmal bestaetigt reicht: gemerkt in den UserDefaults (Datenbereich bzw. App)
        let suite = "tarife-neu-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertFalse(UFPurchaseNotice.isConfirmed(in: d))
        UFPurchaseNotice.confirm(in: d)
        XCTAssertTrue(UFPurchaseNotice.isConfirmed(in: d))
        XCTAssertTrue(UFPurchaseNotice.isConfirmed(in: UserDefaults(suiteName: suite)!), "bleibt gemerkt")
    }

    /// Tarifseite: der Hinweis steht da, die Kaufknoepfe sind ohne Haken gesperrt und nach dem Haken antippbar; Plus hat
    /// den zweiten Knopf "5 Jahre für … einmalig"
    func testPlanPageLocksBuyButtonsUntilTheCheckmark() throws {
        UFPurchaseNotice.confirm(in: UFPurchaseNotice.defaults, false)
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let ent = Entitlements(observe: false)
        let frame = CGRect(x: 0, y: 0, width: 1180, height: 2600)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: PlanPickerView(context: .settings, entitlements: ent) {})
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func elements() -> [NSObject] { LayoutWidthAuditTests.elements(in: hosting.view) }
        func element(_ id: String) -> NSObject? {
            elements().first { EditorToolbarTests.identifier($0) == id }
        }
        func wait(_ seconds: Double = 20, _ check: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !check() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            return check()
        }
        func texts() -> String {
            elements().flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.joined(separator: "\n")
                .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertTrue(wait { texts().contains("StudiNow Plus für 1,99") && texts().contains("5 Jahre für 39,99") }, texts())
        XCTAssertNotNil(element("plans.buy.plus"), texts())
        XCTAssertNotNil(element("plans.plus.once"), texts())
        XCTAssertTrue(texts().contains(UFPurchaseNotice.title), texts())
        XCTAssertTrue(texts().contains("unabhängiges Angebot"), texts())
        let buy = try XCTUnwrap(element("plans.buy.plus"))
        XCTAssertTrue(buy.accessibilityTraits.contains(.notEnabled), "ohne Haken gesperrt")
        XCTAssertTrue(try XCTUnwrap(element("plans.plus.once")).accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(texts().contains("StudiNow Plus für 1,99 €/Monat"), texts())
        XCTAssertTrue(texts().contains("5 Jahre für 39,99 € einmalig"), texts())
        // Haken setzen
        let check = try XCTUnwrap(element("plans.notice.confirm"))
        XCTAssertEqual(check.accessibilityValue, "nicht ausgewählt")
        XCTAssertTrue(check.accessibilityActivate())
        XCTAssertTrue(wait(5) { element("plans.buy.plus")?.accessibilityTraits.contains(.notEnabled) == false }, "nach dem Haken antippbar")
        XCTAssertTrue(wait(5) { element("plans.plus.once")?.accessibilityTraits.contains(.notEnabled) == false })
        XCTAssertTrue(UFPurchaseNotice.isConfirmed(in: UFPurchaseNotice.defaults), "einmal bestaetigt, gemerkt")
        XCTAssertEqual(element("plans.notice.confirm")?.accessibilityValue, "ausgewählt")
    }

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }
}
