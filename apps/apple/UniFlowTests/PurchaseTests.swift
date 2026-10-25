import StoreKit
import StoreKitTest
import XCTest
@testable import UniFlow

/// Abo-Kauf nur in der lokalen StoreKit-Testsitzung (keine echten Produkte, keine Abrechnung).
@MainActor
final class PurchaseTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "UniFlow")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
    }

    /// Bedingung wiederholt pruefen (StoreKit-Testsitzung arbeitet asynchron), hoechstens `seconds`
    private func eventually(_ seconds: Double = 8, _ check: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await check() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return await check()
    }

    private func waitForPlan(_ ent: Entitlements, _ plan: UFPlan) async {
        _ = await eventually { await ent.refresh(); return ent.plan == plan }
    }

    /// eigener Tarif ohne Beobachter, damit sich die Tests nicht gegenseitig beeinflussen
    private func makeStore() async -> (PurchaseStore, Entitlements) {
        let ent = Entitlements(observe: false)
        let store = PurchaseStore(entitlements: ent)
        await store.loadProducts()
        await ent.refresh()
        return (store, ent)
    }

    /// Laeuft als erster Test der Klasse (Name): clearTransactions() setzt den Anspruch auf die Probewoche
    /// innerhalb eines Testlaufs nicht zurueck, erst ein neuer Prozess startet wieder mit Anspruch.
    func test1ProductsCarryOneFreeWeek() async throws {
        let (store, ent) = await makeStore()
        XCTAssertEqual(store.products.map(\.id).sorted(), PurchaseStore.productIDs.sorted())
        XCTAssertEqual(ent.plan, .free)
        for plan in [UFPlan.plus, .pro] {
            let p = try XCTUnwrap(store.product(for: plan))
            let trial = try XCTUnwrap(p.ufFreeTrial)
            XCTAssertEqual(trial.0, 1)
            XCTAssertEqual(trial.1, .week)
            XCTAssertEqual(p.ufPeriod.1, .month)
            XCTAssertEqual(store.introEligible[p.id], true)
            XCTAssertEqual(UFOfferText.button(plan: plan, price: p.displayPrice, period: p.ufPeriod, freeTrial: trial, eligible: true),
                           "\(plan.title) – 1 Woche gratis")
            XCTAssertTrue(UFOfferText.summary(price: p.displayPrice, period: p.ufPeriod, freeTrial: trial, eligible: true)
                .hasPrefix("1 Woche gratis, danach \(p.displayPrice)/Monat"))
        }
    }

    func testPlusPurchaseStartsFreeWeekAndUsesUpEligibility() async throws {
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        let outcome = await store.purchase(plus)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        XCTAssertEqual(ent.plan, .plus)
        XCTAssertEqual(store.activePlan, "plus")
        XCTAssertTrue(ent.inIntroOffer, "Während der Gratiswoche gilt Plus mit Einführungsangebot")
        XCTAssertTrue(ent.allows(.pencilWriting))
        XCTAssertFalse(ent.allows(.uniGrades))
        // Probewoche ist je Abo-Gruppe verbraucht: auch Pro zeigt danach den normalen Preis
        await store.loadProducts()
        XCTAssertEqual(store.introEligible["de.uniflow.plus.monthly"], false)
        XCTAssertEqual(store.introEligible["de.uniflow.pro.monthly"], false)
    }

    func testExpiryFallsBackToFree() async throws {
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        _ = await store.purchase(plus)
        XCTAssertEqual(ent.plan, .plus)
        // gekuendigt (keine Verlaengerung), dann laeuft der Zeitraum ab
        let t = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == plus.id })
        try session.disableAutoRenewForTransaction(identifier: t.identifier)
        try session.expireSubscription(productIdentifier: plus.id)
        await waitForPlan(ent, .free)
        XCTAssertEqual(ent.plan, .free)
        XCTAssertFalse(ent.allows(.pencilWriting))
        // Herabstufen: Notizen bleiben lesbar und exportierbar
        XCTAssertEqual(ent.notes, UFNoteAccess(canView: true, canExport: true, canEdit: false))
    }

    func testRefundRevokesPlan() async throws {
        let (store, ent) = await makeStore()
        let pro = try XCTUnwrap(store.product(for: .pro))
        _ = await store.purchase(pro)
        XCTAssertEqual(ent.plan, .pro)
        let t = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == pro.id })
        try session.refundTransaction(identifier: t.identifier)
        await waitForPlan(ent, .free)
        XCTAssertEqual(ent.plan, .free)
    }

    func testUpgradePlusToPro() async throws {
        let (store, ent) = await makeStore()
        _ = await store.purchase(try XCTUnwrap(store.product(for: .plus)))
        XCTAssertEqual(ent.plan, .plus)
        _ = await store.purchase(try XCTUnwrap(store.product(for: .pro)))
        XCTAssertEqual(ent.plan, .pro)
        XCTAssertTrue(ent.allows(.uniGrades))
    }

    func testRestoreOnNewInstall() async throws {
        let (store, ent) = await makeStore()
        _ = await store.purchase(try XCTUnwrap(store.product(for: .plus)))
        XCTAssertEqual(ent.plan, .plus)
        // neue Instanz wie nach Neuinstallation: Wiederherstellen liefert den Tarif aus dem Store
        let (fresh, freshEnt) = await makeStore()
        await fresh.restore()
        XCTAssertNil(fresh.lastError)
        XCTAssertEqual(freshEnt.plan, .plus)
    }
}
