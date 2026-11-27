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
        XCTAssertEqual(PurchaseStore.productIDs, ["de.uniflow.plus.monthly", "de.uniflow.proai.monthly", "de.uniflow.proai.yearly",
                                                  "de.uniflow.plus.fuenfjahre"])
        XCTAssertEqual(UFPlan.plus.productID, "de.uniflow.plus.monthly")
        XCTAssertEqual(UFPlan.proAI.productID, "de.uniflow.proai.yearly")
        XCTAssertNil(UFPlan.free.productID)
        XCTAssertEqual(UFOffer.plusFiveYears.plan, .plus)
        XCTAssertEqual(UFOffer.plusFiveYears.years, 5)
        XCTAssertNil(UFOffer.plusFiveYears.period)
        // nicht mehr verkauft, ein frueherer Kauf gilt weiter: Plus-Jahresabo als Plus; Pro AI monatlich ist wieder ein
        // Angebot (27.11.2026) und gilt als Pro AI
        let later = Date().addingTimeInterval(86_400)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [.init(productID: "de.uniflow.plus.yearly", expirationDate: later)], now: Date()), .plus)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [.init(productID: "de.uniflow.proai.monthly", expirationDate: later)], now: Date()), .proAI)
        XCTAssertFalse(PurchaseStore.productIDs.contains("de.uniflow.plus.yearly"))
        XCTAssertTrue(PurchaseStore.productIDs.contains("de.uniflow.proai.monthly"))
        XCTAssertNil(UFPlan.legacyProductIDs["de.uniflow.proai.monthly"], "kein Altprodukt mehr")
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
        // Pro AI monatlich (27.11.2026): Auto-Abo 3,99 € je Monat, dieselbe Gruppe wie Pro AI jaehrlich
        let proMonthly = try XCTUnwrap(store.product(for: .proAIMonthly))
        XCTAssertEqual(proMonthly.price, Decimal(string: "3.99"))
        XCTAssertEqual(proMonthly.type, .autoRenewable)
        XCTAssertEqual(proMonthly.ufPeriod.0, 1)
        XCTAssertEqual(proMonthly.ufPeriod.1, .month)
        XCTAssertEqual(proMonthly.displayName, UFPlan.proAI.name)
        XCTAssertEqual(proMonthly.subscription?.subscriptionGroupID, pro.subscription?.subscriptionGroupID)
        XCTAssertEqual(proMonthly.subscription?.subscriptionGroupID, monthly.subscription?.subscriptionGroupID)
        XCTAssertEqual(store.product(for: .proAI)?.id, pro.id, "Hauptprodukt von Pro AI bleibt das Jahresabo")
        XCTAssertEqual(store.product(for: .plus)?.id, monthly.id, "Hauptprodukt von Plus ist das Monatsabo")
        // Texte vor dem Kauf
        XCTAssertEqual(UFOfferText.onceSummary(price: "39,99 €", years: 5), "39,99 € einmalig, gilt 5 Jahre ab dem Kauf, verlängert sich nicht")
        XCTAssertEqual(UFOfferText.onceButton(price: "39,99 €", years: 5), "5 Jahre für 39,99 € einmalig")
        XCTAssertEqual(UFOfferText.summary(price: "1,99 €", period: (1, .month)), "1,99 €/Monat, verlängert sich monatlich, jederzeit zum Laufzeitende kündbar")
        XCTAssertTrue(PlanPickerView.legalText.contains("5 Jahre ab dem Kauf und verlängert sich nicht"), PlanPickerView.legalText)
        // Pflichttext (27.11.2026): Plus monatlich, Pro AI monatlich und jaehrlich verlaengern sich, das Paket nicht
        XCTAssertTrue(PlanPickerView.legalText.contains("StudiNow Plus monatlich sowie StudiNow Pro AI monatlich und jährlich sind Abos mit automatischer Verlängerung"),
                      PlanPickerView.legalText)
        XCTAssertTrue(PlanPickerView.legalText.contains("Das Bachelor+Master-Paket (StudiNow Plus für 5 Jahre) bezahlst du einmal"), PlanPickerView.legalText)
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
        XCTAssertTrue(ent.activeOffers.contains(.plusFiveYears))
        XCTAssertTrue(UFOfferText.onceNote(.plus, until: expires).hasPrefix("Einmal bezahlt – StudiNow Plus gilt bis "))
    }

    // MARK: Pro AI monatlich (27.11.2026)

    /// Pro AI monatlich ist Pro AI: 3,99 € im Monat, 120 Credits wie jaehrlich, Bereich "Monatlich"
    func testProAIMonthlyIsProAIWith120Credits() {
        let o = UFOffer.proAIMonthly
        XCTAssertEqual(o.productID, "de.uniflow.proai.monthly")
        XCTAssertEqual(o.plan, .proAI)
        XCTAssertEqual(o.kind, .autoRenewable)
        XCTAssertEqual(o.priceCents, 399)
        XCTAssertEqual(o.period, "month")
        XCTAssertEqual(o.label, "3,99 € im Monat")
        XCTAssertEqual(o.group, .monthly)
        XCTAssertNil(o.savings)
        XCTAssertEqual(UFPlan(productID: o.productID), .proAI)
        let later = Date().addingTimeInterval(20 * 86_400)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [.init(productID: o.productID, expirationDate: later)], now: Date()), .proAI)
        let ent = Entitlements(observe: false, plan: .free)
        ent.setPurchasedForTesting(.proAI, offer: .proAIMonthly)
        XCTAssertEqual(ent.plan, .proAI)
        XCTAssertEqual(ent.plan.monthlyCredits, 120, "120 Credits im Monat wie Pro AI jaehrlich")
        XCTAssertTrue(ent.canBuyCredits)
        XCTAssertTrue(UFRichNotes.allowed(plan: ent.plan))
        // Wechsel monatlich <-> jaehrlich: gleicher Tarif, eigene Texte
        XCTAssertEqual(UFOfferText.switchButton(to: .proAIYearly, from: .proAIMonthly), "Zu jährlich wechseln")
        XCTAssertEqual(UFOfferText.switchButton(to: .proAIMonthly, from: .proAIYearly), "Zu monatlich wechseln")
        XCTAssertEqual(UFOfferText.switchButton(to: .proAIMonthly, from: .plusMonthly), "Zu StudiNow Pro AI wechseln")
        XCTAssertEqual(UFOfferText.switchNote(to: .proAIYearly, from: .proAIMonthly, currentPlan: .proAI), UFOfferText.crossgradeNote)
        XCTAssertEqual(UFOfferText.switchNote(to: .plusMonthly, from: .proAIMonthly, currentPlan: .proAI),
                       "Gilt ab der nächsten Verlängerung, bis dahin bleibt StudiNow Pro AI.")
        // "Aktueller Tarif" auf der Karte des gekauften Angebots
        XCTAssertTrue(PlanPickerView.isCurrent(.offer(.proAIMonthly), purchased: .proAI, offer: .proAIMonthly, loading: false, trial: false))
        XCTAssertFalse(PlanPickerView.isCurrent(.offer(.proAIYearly), purchased: .proAI, offer: .proAIMonthly, loading: false, trial: false))
        XCTAssertFalse(PlanPickerView.isCurrent(.offer(.plusMonthly), purchased: .proAI, offer: .proAIMonthly, loading: false, trial: false))
        XCTAssertEqual(PlanPickerView.buyIdentifier(.proAIMonthly), "plans.buy.pro_ai.month")
        XCTAssertEqual(PlanPickerView.buyIdentifier(.proAIYearly), "plans.buy.pro_ai")
        XCTAssertEqual(PlanPickerView.buyIdentifier(.plusMonthly), "plans.buy.plus")
        // Hinweise ausserhalb der Tarifseite
        XCTAssertEqual(UFPlanCatalog.proAIFrom, "ab 3,99 € im Monat")
        XCTAssertEqual(UFPlanCatalog.proAIWithPrice, "StudiNow Pro AI (ab 3,99 € im Monat)")
        // Pro-AI-Karte: Credits jeden Monat und weitere dazukaufen
        XCTAssertEqual(UFPlanCard.rows(.proAI).map(\.title), ["120 Credits für die StudiNow-KI – jeden Monat", "Weitere Credits jederzeit dazukaufen"])
        XCTAssertEqual(UFPlanCard.intro(.proAI), "Alles aus StudiNow Plus, dazu:")
        XCTAssertEqual(UFPlanCard.intro(.plus), "Alles aus StudiNow Free, dazu:")
        XCTAssertTrue(UFPlanCard.rows(.plus).contains { $0.title == UFFeature.aiChat.title }, "Plus: KI mit gekauften Credits")
    }

    /// Kauf von Pro AI monatlich in der StoreKit-Testsitzung: Pro AI, Angebot monatlich, verlaengert sich
    func testProAIMonthlyPurchaseInTheStore() async throws {
        try requireVisibleTestPurchases()
        let (store, ent) = await makeStore()
        let p = try XCTUnwrap(store.product(for: .proAIMonthly))
        let outcome = await store.purchase(p)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        await waitForPlan(ent, .proAI)
        XCTAssertEqual(ent.purchasedPlan, .proAI)
        XCTAssertEqual(ent.purchasedOffer, .proAIMonthly)
        XCTAssertEqual(ent.plan.monthlyCredits, 120)
        XCTAssertTrue(PlanPickerView.hasSubscription(purchased: ent.purchasedPlan, offer: ent.purchasedOffer, loading: false))
        // das Paket bleibt daneben kaufbar, mit dem Hinweis zum Kuendigen
        XCTAssertTrue(PlanPickerView.showsOnceButton(purchased: ent.purchasedPlan, offer: ent.purchasedOffer, giftCovers: false, loaded: true,
                                                     ownsOnce: ent.activeOffers.contains(.plusFiveYears)))
        XCTAssertEqual(UFOfferText.onceNote(subscribed: ent.purchasedPlan), UFOfferText.onceWithProAINote)
    }

    // MARK: Drei Bereiche, Reihenfolge, Ersparnis (27.11.2026)

    func testSectionsInOrderMonthlyYearlySpecial() {
        let all = Set(UFOffer.allCases.map(\.productID))
        let s = UFPlanCatalog.sections(current: .free, loaded: all)
        XCTAssertEqual(s.map(\.group), [.special, .monthly, .yearly], "Special zuerst (Inhaber 27.11.2026)")
        XCTAssertEqual(s.map(\.group.title), ["Unser Special", "Monatlich", "Jährlich"])
        XCTAssertEqual(s[0].cards, [.offer(.plusFiveYears)])
        XCTAssertEqual(s[1].cards, [.free, .offer(.plusMonthly), .offer(.proAIMonthly)], "Free, dann Plus 1,99, dann Pro AI 3,99")
        XCTAssertEqual(s[2].cards, [.offer(.proAIYearly)])
        XCTAssertEqual(UFOfferGroup.monthly.offers, [.plusMonthly, .proAIMonthly])
        XCTAssertEqual(UFOfferGroup.yearly.offers, [.proAIYearly])
        XCTAssertEqual(UFOfferGroup.special.offers, [.plusFiveYears])
        // Paket: Name, Abzeichen, Hervorhebung
        XCTAssertEqual(UFOffer.plusFiveYears.name, "Bachelor+Master-Paket")
        XCTAssertEqual(UFOffer.plusFiveYears.badge, "Unser Special")
        XCTAssertTrue(UFOffer.plusFiveYears.highlight)
        XCTAssertEqual(UFOffer.allCases.filter(\.highlight), [.plusFiveYears], "nur das Paket ist hervorgehoben")
        XCTAssertEqual(UFOfferText.packageContent(years: 5), "StudiNow Plus für 5 Jahre")
        // ohne Produkte: Free und Plus (ohne Preis), keine leeren Bereiche
        XCTAssertEqual(UFPlanCatalog.sections(current: .free, loaded: []), [UFPlanSection(group: .monthly, cards: [.free, .offer(.plusMonthly)])])
        // nur Pro AI jaehrlich im Store: Monatlich ohne Pro AI
        let yearlyOnly = UFPlanCatalog.sections(current: .free, loaded: ["de.uniflow.plus.monthly", "de.uniflow.proai.yearly"])
        XCTAssertEqual(yearlyOnly.map(\.group), [.monthly, .yearly])
        XCTAssertEqual(yearlyOnly[0].cards, [.free, .offer(.plusMonthly)])
        // wer Pro AI monatlich hat, sieht seine Karte auch ohne Produkt aus dem Store
        let owned = UFPlanCatalog.sections(current: .proAI, owned: .proAIMonthly, loaded: [])
        XCTAssertEqual(owned.first?.cards, [.free, .offer(.plusMonthly), .offer(.proAIMonthly)])
        // ein frueheres Pro-Produkt ohne Angebot (Pro Connect): die erste Pro-AI-Karte
        XCTAssertEqual(UFPlanCatalog.sections(current: .proAI, owned: nil, loaded: []).first?.cards, [.free, .offer(.plusMonthly), .offer(.proAIMonthly)])
    }

    /// Ersparnis-Texte aus plans.json (`offers[].savings`): genau dieselben Texte, gerechnet aus den Preisen des Vertrags
    func testSavingsTextsMatchTheFixture() throws {
        let url = ContainerTestBed.repoURL("packages/shared-contracts/fixtures/plans/plans.json")
        let c = try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
        let offers = try XCTUnwrap(c["offers"]?.array)
        func cents(_ v: JSONValue?) -> Int? { v?.double.map { Int($0) } }
        XCTAssertEqual(offers.compactMap { $0["product_id"]?.string }, UFOffer.allCases.map(\.productID))
        for (o, offer) in zip(offers, UFOffer.allCases) {
            XCTAssertEqual(o["group"]?.string, offer.group.rawValue, offer.productID)
            guard let s = offer.savings else {
                XCTAssertNil(o["savings"]?.object, offer.productID)
                continue
            }
            XCTAssertEqual(o["savings"]?["text"]?.string, s.text, offer.productID)
            XCTAssertEqual(o["savings"]?["per_month_text"]?.string, s.perMonthText, offer.productID)
            XCTAssertEqual(cents(o["savings"]?["saved_cents"]), s.savedCents, offer.productID)
            // nachgerechnet: Monate x Vergleichspreis, minus Preis, Prozent gerundet
            let compare = try XCTUnwrap(offer.compare, offer.productID)
            XCTAssertEqual(s.regularCents, s.months * compare.priceCents, offer.productID)
            XCTAssertEqual(s.savedCents, s.regularCents - offer.priceCents, offer.productID)
            XCTAssertEqual(s.savedPercent, Int((Double(s.savedCents) * 100 / Double(s.regularCents)).rounded()), offer.productID)
            XCTAssertEqual(s.perMonthCents, Int((Double(offer.priceCents) / Double(s.months)).rounded()), offer.productID)
        }
        XCTAssertEqual(UFOffer.proAIYearly.savings?.text, "Du sparst 7,89 € (16 %) gegenüber 12 × 3,99 € = 47,88 €")
        XCTAssertEqual(UFOffer.plusFiveYears.savings?.text, "Du sparst 79,41 € (67 %) gegenüber 60 × 1,99 € = 119,40 €")
        XCTAssertEqual(UFOffer.plusFiveYears.savings?.perMonthText, "nur 0,67 € im Monat")
        // gezeigt nur mit passenden Store-Preisen in Euro
        XCTAssertTrue(UFOfferText.savingsApply(.plusFiveYears, price: Decimal(string: "39.99")!, currency: "EUR", comparePrice: Decimal(string: "1.99")!))
        XCTAssertTrue(UFOfferText.savingsApply(.proAIYearly, price: Decimal(string: "39.99")!, currency: "EUR", comparePrice: nil))
        XCTAssertFalse(UFOfferText.savingsApply(.proAIYearly, price: Decimal(string: "39.99")!, currency: "USD", comparePrice: nil), "anderes Land")
        XCTAssertFalse(UFOfferText.savingsApply(.proAIYearly, price: Decimal(string: "44.99")!, currency: "EUR", comparePrice: nil), "anderer Preis")
        XCTAssertFalse(UFOfferText.savingsApply(.proAIYearly, price: Decimal(string: "39.99")!, currency: "EUR", comparePrice: Decimal(string: "4.99")!))
        XCTAssertFalse(UFOfferText.savingsApply(.plusMonthly, price: Decimal(string: "1.99")!, currency: "EUR", comparePrice: nil), "keine Ersparnis")
    }

    /// Plus jaehrlich (19,99 €, bis 26.11.2026) gilt weiter als Plus, wird aber nicht angeboten; die Plus-Karte traegt
    /// "Aktueller Tarif"
    func testPlusYearlyStillCountsAsPlus() {
        XCTAssertEqual(UFPlan(productID: "de.uniflow.plus.yearly"), .plus)
        XCTAssertNil(UFOffer(productID: "de.uniflow.plus.yearly"))
        XCTAssertFalse(UFPlanCatalog.sellableProductIDs.contains("de.uniflow.plus.yearly"))
        let later = Date().addingTimeInterval(200 * 86_400)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [.init(productID: "de.uniflow.plus.yearly", expirationDate: later)], now: Date()), .plus)
        XCTAssertTrue(PlanPickerView.isCurrent(.offer(.plusMonthly), purchased: .plus, offer: nil, loading: false, trial: false))
        XCTAssertFalse(PlanPickerView.isCurrent(.offer(.plusFiveYears), purchased: .plus, offer: nil, loading: false, trial: false))
        XCTAssertTrue(PlanPickerView.hasSubscription(purchased: .plus, offer: nil, loading: false))
    }

    /// Das Paket neben laufendem Pro AI (Inhaber 27.11.2026): angeboten, mit dem Hinweis, Pro AI unter "Abo verwalten" zu
    /// kuendigen; ohne Pro AI gibt es dann keine Monats-Credits mehr
    func testPackageIsOfferedBesideProAIWithNote() throws {
        XCTAssertTrue(PlanPickerView.showsOnceButton(purchased: .proAI, offer: .proAIYearly, giftCovers: false, loaded: true))
        XCTAssertTrue(PlanPickerView.showsOnceButton(purchased: .proAI, offer: .proAIMonthly, giftCovers: false, loaded: true))
        XCTAssertFalse(PlanPickerView.showsOnceButton(purchased: .proAI, offer: .proAIYearly, giftCovers: false, loaded: true, ownsOnce: true),
                       "Paket schon gekauft: kein zweiter Kauf")
        XCTAssertFalse(PlanPickerView.showsOnceButton(purchased: .plus, offer: .plusFiveYears, giftCovers: false, loaded: true))
        XCTAssertFalse(PlanPickerView.showsOnceButton(purchased: .free, offer: nil, giftCovers: true, loaded: true))
        XCTAssertFalse(PlanPickerView.showsOnceButton(purchased: .free, offer: nil, giftCovers: false, loaded: false))
        let note = try XCTUnwrap(UFOfferText.onceNote(subscribed: .proAI))
        XCTAssertTrue(note.contains("Kündige es danach unter „Abo verwalten“"), note)
        XCTAssertTrue(note.contains("mit dem Paket allein gibt es keine Monats-Credits mehr"), note)
        XCTAssertEqual(UFOfferText.onceNote(subscribed: .plus), UFOfferText.onceWithSubscriptionNote)
        XCTAssertNil(UFOfferText.onceNote(subscribed: .free))
        XCTAssertNil(UFOfferText.onceNote(subscribed: nil))
        // auf der Seite: Pro AI gekauft, Knopf des Pakets und der Hinweis stehen da
        let ent = Entitlements(observe: false)
        ent.setPurchasedForTesting(.proAI, offer: .proAIYearly)
        let page = try hostPlanPage(ent)
        defer { page.close() }
        // die Seite liest beim Oeffnen StoreKit neu (ohne Kauf in der Testsitzung): danach den Testkauf wieder setzen
        settleThenSet(page) { ent.setPurchasedForTesting(.proAI, offer: .proAIYearly) }
        XCTAssertTrue(page.wait(20) { page.element("plans.plus.once") != nil && page.texts().contains(UFOfferText.onceWithProAINote) }, page.texts())
        XCTAssertTrue(page.texts().contains("Aktueller Tarif"), page.texts())
    }

    /// Paket aktiv, Pro AI dazukaufen (Inhaber 27.11.2026): Pro AI gilt, solange es laeuft; endet es (oder ist es
    /// gekuendigt und abgelaufen), gilt Plus aus dem Paket bis Kauf + 5 Jahre. Der Tarif ist immer der hoechste Kauf.
    func testPackagePlusProAIGivesProAIAndAfterwardsPlus() throws {
        let bought = try date("2026-11-27T10:00:00Z")
        let pkg = UFEntitlementEntry(productID: UFOffer.plusFiveYears.productID, purchaseDate: bought)
        let pkgEnd = try XCTUnwrap(UFOffer.plusFiveYears.end(purchasedAt: bought))
        for (offer, days) in [(UFOffer.proAIMonthly, 30.0), (.proAIYearly, 365.0)] {
            let pro = UFEntitlementEntry(productID: offer.productID, expirationDate: bought.addingTimeInterval(days * 86_400))
            XCTAssertEqual(UFEntitlementResolver.plan(from: [pkg, pro], now: bought.addingTimeInterval(86_400)), .proAI, offer.productID)
            XCTAssertEqual(UFEntitlementResolver.carrying(.proAI, in: [pkg, pro], now: bought)?.productID, offer.productID)
            // Pro AI abgelaufen (z. B. gekuendigt): das Paket gilt weiter als Plus
            let after = bought.addingTimeInterval((days + 1) * 86_400)
            XCTAssertEqual(UFEntitlementResolver.plan(from: [pkg, pro], now: after), .plus, offer.productID)
            XCTAssertEqual(UFEntitlementResolver.carrying(.plus, in: [pkg, pro], now: after)?.productID, UFOffer.plusFiveYears.productID)
            // bis Kauf + 5 Jahre, danach Free
            XCTAssertEqual(UFEntitlementResolver.plan(from: [pkg, pro], now: pkgEnd.addingTimeInterval(-60)), .plus)
            XCTAssertEqual(UFEntitlementResolver.plan(from: [pkg, pro], now: pkgEnd), .free)
            // erstattetes Pro AI: sofort wieder Plus
            var refunded = pro
            refunded.revocationDate = bought.addingTimeInterval(2 * 86_400)
            XCTAssertEqual(UFEntitlementResolver.plan(from: [pkg, refunded], now: bought.addingTimeInterval(3 * 86_400)), .plus)
        }
        // Hinweis an den Pro-AI-Knoepfen nur mit Paket
        XCTAssertTrue(PlanPickerView.showsBesidePackageNote(.proAIMonthly, activeOffers: [.plusFiveYears]))
        XCTAssertTrue(PlanPickerView.showsBesidePackageNote(.proAIYearly, activeOffers: [.plusFiveYears, .proAIYearly]))
        XCTAssertFalse(PlanPickerView.showsBesidePackageNote(.proAIYearly, activeOffers: []))
        XCTAssertFalse(PlanPickerView.showsBesidePackageNote(.plusMonthly, activeOffers: [.plusFiveYears]))
        XCTAssertTrue(UFOfferText.proAIBesidePackageNote.contains("Plus aus deinem Bachelor+Master-Paket läuft weiter"))
        // mit Paket ist Pro AI ein Kauf, kein Wechsel in der Gruppe
        XCTAssertFalse(PlanPickerView.hasSubscription(purchased: .plus, offer: .plusFiveYears, loading: false))
    }

    /// Auf der Seite: mit Paket sind beide Pro-AI-Knoepfe nach dem Haken antippbar, mit dem Hinweis; das Paket selbst
    /// hat keinen zweiten Kaufknopf
    func testPlanPageWithPackageOffersProAI() throws {
        let ent = Entitlements(observe: false)
        ent.setPurchasedForTesting(.plus, offer: .plusFiveYears, expiresAt: Date().addingTimeInterval(4 * 365 * 86_400), willRenew: false)
        let page = try hostPlanPage(ent)
        defer { page.close() }
        settleThenSet(page) {
            ent.setPurchasedForTesting(.plus, offer: .plusFiveYears, expiresAt: Date().addingTimeInterval(4 * 365 * 86_400), willRenew: false)
        }
        XCTAssertTrue(page.wait(20) {
            page.element("plans.buy.pro_ai.month") != nil && page.element("plans.buy.pro_ai") != nil
                && page.texts().contains(UFOfferText.proAIBesidePackageNote)
        }, page.texts())
        XCTAssertTrue(page.texts().contains("StudiNow Pro AI für 3,99 €/Monat"), page.texts())
        XCTAssertTrue(page.texts().contains("StudiNow Pro AI für 39,99 €/Jahr"), page.texts())
        XCTAssertTrue(page.texts().contains(UFOfferText.proAIBesidePackageNote), page.texts())
        XCTAssertNil(page.element("plans.plus.once"), "Paket gilt schon: kein zweiter Kauf")
        let check = try XCTUnwrap(page.element("plans.notice.confirm"))
        XCTAssertTrue(check.accessibilityActivate())
        XCTAssertTrue(page.wait(5) {
            page.element("plans.buy.pro_ai.month")?.accessibilityTraits.contains(.notEnabled) == false
                && page.element("plans.buy.pro_ai")?.accessibilityTraits.contains(.notEnabled) == false
        }, "Pro AI dazukaufen nicht gesperrt")
    }

    /// Kaufseite: drei Bereiche in dieser Reihenfolge, Preise, Ersparnis, Special mit Abzeichen
    func testPlanPageShowsTheThreeSectionsWithSavings() throws {
        let page = try hostPlanPage(Entitlements(observe: false))
        defer { page.close() }
        XCTAssertTrue(page.wait(20) { page.texts().contains("StudiNow Pro AI für 3,99 €/Monat") }, page.texts())
        let t = page.texts()
        for part in ["Monatlich", "Jährlich", "Unser Special", "Bachelor+Master-Paket", "StudiNow Plus für 5 Jahre",
                     "Du sparst 7,89 € (16 %) gegenüber 12 × 3,99 € = 47,88 €", "nur 3,33 € im Monat",
                     "Du sparst 79,41 € (67 %) gegenüber 60 × 1,99 € = 119,40 €", "nur 0,67 € im Monat",
                     "StudiNow Plus für 1,99 €/Monat", "StudiNow Pro AI für 39,99 €/Jahr", "5 Jahre für 39,99 € einmalig",
                     "Alles aus StudiNow Free, dazu:", "Alles aus StudiNow Plus, dazu:", "Weitere Credits jederzeit dazukaufen",
                     "120 Credits für die StudiNow-KI – jeden Monat", UFPurchaseNotice.title] {
            XCTAssertTrue(t.contains(part), "fehlt: \(part)\n\(t)")
        }
        XCTAssertNotNil(page.element("plans.special.badge"))
        // Reihenfolge von oben nach unten (Inhaber 27.11.2026 "Ja, nach oben"): Unser Special, Monatlich, Jaehrlich
        let ys = ["plans.section.special", "plans.section.monthly", "plans.section.yearly"].compactMap { id in
            page.element(id).map { $0.accessibilityFrame.minY }
        }
        XCTAssertEqual(ys.count, 3, t)
        XCTAssertEqual(ys, ys.sorted(), "Reihenfolge der Bereiche")
        // Monatlich: Free vor Plus vor Pro AI (Knoepfe nebeneinander bzw. untereinander)
        let order = ["plans.buy.plus", "plans.buy.pro_ai.month"].compactMap { page.element($0)?.accessibilityFrame }
        XCTAssertEqual(order.count, 2)
        if order.count == 2 { XCTAssertTrue(order[0].minX < order[1].minX || order[0].minY < order[1].minY, "\(order)") }
        // alle Kaufknoepfe ohne Haken gesperrt
        for id in ["plans.buy.plus", "plans.buy.pro_ai.month", "plans.buy.pro_ai", "plans.plus.once"] {
            let e = try XCTUnwrap(page.element(id), id)
            XCTAssertTrue(e.accessibilityTraits.contains(.notEnabled), "\(id) ohne Haken gesperrt")
        }
    }

    /// Bilder der Kaufseite (nur mit TEST_RUNNER_UF_SCREENSHOT_DIR): Bildschirmgroesse des Geraets, oben und weiter
    /// gescrollt bis zum Special, hell und dunkel; dazu die ganze Seite in einem Bild
    func testPlanPageScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        // Groessen der App-Store-Bildschirmfotos: iPad 13" 2064 x 2752 (1032 x 1376 pt, 2x), iPhone 6,9" 1320 x 2868 (440 x 956 pt, 3x)
        let size = phone ? CGSize(width: 440, height: 956) : CGSize(width: 1032, height: 1376)
        let scale: CGFloat = phone ? 3 : 2
        let device = phone ? "iphone-1320x2868" : "ipad-2064x2752"
        UFPurchaseNotice.confirm(in: UFPurchaseNotice.defaults, false)
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        let hosting = UIHostingController(rootView: PlanPickerView(context: .onboarding, entitlements: Entitlements(observe: false)) {}
            .background(UF.bg))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func scrollView(_ v: UIView) -> UIScrollView? {
            if let s = v as? UIScrollView, s.contentSize.height > s.bounds.height { return s }
            for c in v.subviews { if let s = scrollView(c) { return s } }
            return nil
        }
        func snap(_ name: String) throws {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            let png = UIGraphicsImageRenderer(bounds: hosting.view.bounds, format: format).pngData { _ in
                _ = hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            }
            try png.write(to: dir.appendingPathComponent("\(device)-\(name).png"))
        }
        let end = Date().addingTimeInterval(20)
        while Date() < end, !(LayoutWidthAuditTests.elements(in: hosting.view).contains { ($0.accessibilityLabel ?? "").contains("3,99") }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        for (style, tone) in [(UIUserInterfaceStyle.light, "hell"), (.dark, "dunkel")] {
            window.overrideUserInterfaceStyle = style
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            let sv = try XCTUnwrap(scrollView(hosting.view), "keine scrollbare Seite")
            let maxY = max(0, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
            var y: CGFloat = 0
            var i = 1
            while true {
                sv.setContentOffset(CGPoint(x: 0, y: min(y, maxY) - sv.adjustedContentInset.top), animated: false)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                try snap("kaufseite-\(tone)-\(i)")
                if y >= maxY { break }
                y += sv.bounds.height * 0.8
                i += 1
            }
            // ein Bild, das oben mit der Karte "Unser Special" beginnt (Bereichsueberschrift darueber)
            sv.setContentOffset(.zero, animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let head = try XCTUnwrap(LayoutWidthAuditTests.elements(in: hosting.view)
                .first { EditorToolbarTests.identifier($0) == "plans.section.special" }, "Bereich Unser Special fehlt")
            let top = head.accessibilityFrame.minY - window.frame.minY - 24
            sv.setContentOffset(CGPoint(x: 0, y: min(maxY, max(0, top)) - sv.adjustedContentInset.top), animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            try snap("kaufseite-\(tone)-special")
            sv.setContentOffset(.zero, animated: false)
        }
    }

    @MainActor
    private struct HostedPage {
        let window: UIWindow
        let hosting: UIViewController
        func elements() -> [NSObject] { LayoutWidthAuditTests.elements(in: hosting.view) }
        func element(_ id: String) -> NSObject? { elements().first { EditorToolbarTests.identifier($0) == id } }
        func texts() -> String {
            elements().flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.joined(separator: "\n")
                .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        }
        func wait(_ seconds: Double = 20, _ check: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !check() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            return check()
        }
        func close() {
            window.isHidden = true
            _ = Self.automation(false)
        }
        static func automation(_ on: Bool) -> Bool { TarifeNeuAppTests.accessibilityAutomation(on) }
    }

    /// Wartet, bis die Seite Produkte geladen und StoreKit neu gelesen hat (`.task`), dann setzt `set` den Testkauf erneut
    private func settleThenSet(_ page: HostedPage, _ set: () -> Void) {
        _ = page.wait(20) { page.texts().contains("3,99") }
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        set()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }

    private func hostPlanPage(_ ent: Entitlements) throws -> HostedPage {
        UFPurchaseNotice.confirm(in: UFPurchaseNotice.defaults, false)
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        let frame = CGRect(x: 0, y: 0, width: 1180, height: 6000)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: PlanPickerView(context: .settings, entitlements: ent) {})
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        return HostedPage(window: window, hosting: hosting)
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
        let frame = CGRect(x: 0, y: 0, width: 1180, height: 6000)
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
    fileprivate static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }
}
