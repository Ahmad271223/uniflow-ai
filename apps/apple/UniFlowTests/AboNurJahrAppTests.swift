import StoreKit
import SwiftUI
import XCTest
@testable import UniFlow

/// Nur noch Jahresabos (Entscheidung des Inhabers vom 09.11.2026, abends: "Monatliche Abos komplett entfernen. Nur 19,99
/// und 39,99."). Das iPad laedt, zeigt und kauft nur de.uniflow.plus.yearly (19,99 €) und de.uniflow.proai.yearly
/// (39,99 €); kein Umschalter "Monatlich · Jährlich", kein "günstiger als monatlich". Die frueheren Monatsprodukte
/// gelten weiter als gueltiger Kauf ihres Tarifs (z. B. ein alter Sandbox-Kauf), werden aber nie angeboten.
/// Bericht: docs/release/ABO-NUR-JAHR-2026-11-09.md.
@MainActor
final class AboNurJahrAppTests: StoreKitSessionTestCase {
    func testOnlyYearlyProductsAreOffered() {
        XCTAssertEqual(UFPlanCatalog.sellableProductIDs, ["de.uniflow.plus.yearly", "de.uniflow.proai.yearly"])
        XCTAssertEqual(PurchaseStore.productIDs, UFPlanCatalog.sellableProductIDs)
        XCTAssertEqual(UFPlan.plus.productID, "de.uniflow.plus.yearly")
        XCTAssertEqual(UFPlan.proAI.productID, "de.uniflow.proai.yearly")
        XCTAssertNil(UFPlan.free.productID)
        XCTAssertEqual(UFBilling.offered, .yearly)
        // ein geliefertes Monatsprodukt bringt keine Karte (es wird nie angeboten)
        XCTAssertEqual(UFPlanCatalog.cards(current: .free, loaded: ["de.uniflow.plus.yearly", "de.uniflow.proai.monthly"]),
                       [.free, .plus])
        XCTAssertTrue(PlanPickerView.showsProAIMissingNote(loaded: ["de.uniflow.plus.yearly", "de.uniflow.proai.monthly"],
                                                           loading: false, current: .free))
        XCTAssertEqual(UFPlanCatalog.cards(current: .free, loaded: ["de.uniflow.plus.yearly", "de.uniflow.proai.yearly"]),
                       [.free, .plus, .proAI])
    }

    /// alte Monatsprodukte: gueltiger Kauf des Tarifs (Entitlements, Dienst), Zahlweise monatlich erkannt
    func testOldMonthlyProductsStillUnlockTheirPlan() {
        XCTAssertEqual(UFPlan(productID: "de.uniflow.plus.monthly"), .plus)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.proai.monthly"), .proAI)
        XCTAssertEqual(UFBilling(productID: "de.uniflow.plus.monthly"), .monthly)
        XCTAssertEqual(UFBilling(productID: "de.uniflow.proai.yearly"), .yearly)
        let later = Date().addingTimeInterval(86_400)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [.init(productID: "de.uniflow.proai.monthly", expirationDate: later)],
                                                  now: Date()), .proAI)
    }

    func testOfferTextsNameTheYearlyPriceOnly() {
        let year = (1, Product.SubscriptionPeriod.Unit.year)
        XCTAssertEqual(UFOfferText.button(plan: .plus, price: "19,99 €", period: year), "StudiNow Plus für 19,99 €/Jahr")
        XCTAssertEqual(UFOfferText.button(plan: .proAI, price: "39,99 €", period: year), "StudiNow Pro AI für 39,99 €/Jahr")
        XCTAssertEqual(UFOfferText.summary(price: "19,99 €", period: year),
                       "19,99 €/Jahr, verlängert sich jährlich, jederzeit zum Laufzeitende kündbar")
        XCTAssertEqual(UFOfferText.yearlyNote(perMonth: "1,67 €"), "entspricht 1,67 € im Monat")
        XCTAssertTrue(PlanPickerView.legalText.contains("verlängern sich automatisch um ein Jahr"), PlanPickerView.legalText)
        XCTAssertTrue(PlanPickerView.legalText.contains("24 Stunden vor Ablauf"))
        for s in [PlanPickerView.legalText, UFOfferText.summary(price: "19,99 €", period: year), UFOfferText.yearlyNote(perMonth: "1,67 €")] {
            XCTAssertFalse(s.contains("monatlich"), s)
            XCTAssertFalse(s.contains("günstiger"), s)
        }
    }

    /// StoreKit-Konfiguration der App: nur die zwei Jahresabos, 19,99 € und 39,99 €, ohne Einfuehrungsangebot
    func testStoreLoadsOnlyTheTwoYearlyProducts() async throws {
        let (store, _) = await makeStore()
        XCTAssertEqual(store.products.map(\.id), ["de.uniflow.plus.yearly", "de.uniflow.proai.yearly"])
        XCTAssertEqual(store.products.map(\.price), [Decimal(string: "19.99")!, Decimal(string: "39.99")!])
        for plan in [UFPlan.plus, .proAI] {
            let p = try XCTUnwrap(store.product(for: plan), plan.rawValue)
            XCTAssertEqual(p.ufPeriod.0, 1)
            XCTAssertEqual(p.ufPeriod.1, .year)
            XCTAssertNil(p.subscription?.introductoryOffer, plan.rawValue)
        }
        let monthly = try await Product.products(for: ["de.uniflow.plus.monthly", "de.uniflow.proai.monthly"])
        XCTAssertEqual(monthly.map(\.id), [], "keine Monatsabos in der Konfiguration der App")
    }

    /// Kauf des Jahresabos schaltet den Tarif frei, Zahlweise jaehrlich
    func testYearlyPlusPurchaseUnlocksPlus() async throws {
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        let outcome = await store.purchase(plus)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        XCTAssertEqual(ent.purchasedPlan, .plus)
        XCTAssertEqual(ent.purchasedBilling, .yearly)
    }

    /// Tarifseite: Jahrespreise, Monatsbetrag aus dem Jahrespreis, kein Umschalter und nichts "monatlich"
    func testPlanPageShowsYearlyPricesWithoutBillingSwitch() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let ent = Entitlements(observe: false)
        let frame = CGRect(x: 0, y: 0, width: 1180, height: 2400)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: PlanPickerView(context: .settings, entitlements: ent) {})
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func texts() -> [String] {
            LayoutWidthAuditTests.elements(in: hosting.view)
                .flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
        }
        let end = Date().addingTimeInterval(20)
        while Date() < end, !texts().contains(where: { $0.contains("StudiNow Pro AI für 39,99") }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // Der Waehrungsformatierer setzt geschuetzte Leerzeichen vor das Euro-Zeichen; fuer den Vergleich normalisieren
        let all = texts().joined(separator: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertTrue(all.contains("StudiNow Plus für 19,99"), all)
        XCTAssertTrue(all.contains("StudiNow Pro AI für 39,99"), all)
        XCTAssertTrue(all.contains("/Jahr"), all)
        XCTAssertTrue(all.contains("entspricht 1,66 € im Monat") || all.contains("entspricht 1,67 € im Monat"), all)
        XCTAssertTrue(all.contains("entspricht 3,33 € im Monat"), all)
        XCTAssertFalse(all.contains("Monatlich"), all)
        XCTAssertFalse(all.contains("monatlich"), all)
        XCTAssertFalse(all.contains("günstiger"), all)
        XCTAssertFalse(all.contains("1,99 €/Monat"), all)
    }

    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }
}
