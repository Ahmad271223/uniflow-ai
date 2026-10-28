import StoreKit
import StoreKitTest
import XCTest
@testable import UniFlow

/// Wechsel zwischen den Abo-Tarifen als Logik (ab V2, wenn die Pro-Tarife mit dem Studora-Dienst kommen). V1 bietet
/// sie nicht an (`UFPlanCatalog.sellable`, Entscheidung des Inhabers vom 28.10.2026); darum laeuft diese Klasse mit der
/// eigenen Testkonfiguration `UniFlowAlleTarife.storekit` (drei Produkte in einer Gruppe, Stufe 1 = Pro AI), nicht mit
/// der der App. Geprueft wird, was `Entitlements` und `PurchaseStore` daraus machen: Kauf je Tarif, hoechster Tarif,
/// Upgrade sofort, Downgrade zur Verlaengerung, Ablauf, Kaufanfrage, Wiederherstellen.
/// Der Name sortiert hinter `PurchaseTests`, damit dort test0 der erste Kauf im Testprozess bleibt.
@MainActor
final class PurchaseV2PlanSwitchTests: StoreKitSessionTestCase {
    override class var configuration: String { "UniFlowAlleTarife" }
    override class var productIDs: [String] { UFPlan.paid.compactMap(\.productID) }

    /// Die Testkonfiguration hat alle Abo-Tarife, die App bietet davon nur die kaufbaren an
    func testAllPlansConfigurationOffersEveryPaidPlan() async throws {
        let (store, ent) = await makeStore()
        XCTAssertEqual(store.products.map(\.id), ["de.uniflow.plus.monthly", "de.uniflow.proconnect.monthly", "de.uniflow.proai.monthly"])
        XCTAssertEqual(ent.plan, .free)
        for plan in UFPlan.paid {
            let q = try XCTUnwrap(store.product(for: plan), plan.rawValue)
            XCTAssertEqual(q.ufFreeTrial?.0, 1, plan.rawValue)
            XCTAssertEqual(q.ufFreeTrial?.1, .week, plan.rawValue)
            XCTAssertEqual(q.ufPeriod.1, .month, plan.rawValue)
            XCTAssertEqual(q.subscription?.subscriptionGroupID, store.products.first?.subscription?.subscriptionGroupID)
            XCTAssertEqual(q.displayName, plan.name)
        }
        XCTAssertEqual(store.products.map(\.price), store.products.map(\.price).sorted())
        // die App selbst laedt auch hier nur, was V1 verkauft
        let app = PurchaseStore(entitlements: ent)
        await app.loadProducts()
        XCTAssertEqual(app.products.map(\.id), UFPlanCatalog.sellableProductIDs)
    }

    /// Kauf je Tarif: jeder Abo-Tarif schaltet sich selbst frei, mit allem aus Plus und Gratiswoche; nie mit
    /// appAccountToken (ohne Konto beim Dienst)
    func testPurchaseOfEachPlanUnlocksItWithEverythingFromPlus() async throws {
        let (store, ent) = await makeStore()
        for plan in UFPlan.paid {
            session.clearTransactions()
            await waitForPlan(ent, .free)
            XCTAssertEqual(ent.plan, .free, "Ausgangslage vor \(plan.rawValue)")
            let product = try XCTUnwrap(store.product(for: plan), plan.rawValue)
            let outcome = await store.purchase(product)
            XCTAssertEqual(outcome, .success, "\(plan.rawValue): \(store.lastError ?? "")")
            XCTAssertEqual(ent.plan, plan)
            XCTAssertTrue(ent.inIntroOffer, "\(plan.rawValue) beginnt mit der Gratiswoche")
            XCTAssertNotNil(ent.expiresAt, plan.rawValue)
            XCTAssertEqual(ent.willRenew, true, plan.rawValue)
            XCTAssertNil(ent.pendingPlan, plan.rawValue)
            for f: UFFeature in [.pencilWriting, .shareSolutions, .communityRead, .splitView, .flashcards, .studyPlanning, .readDocuments] {
                XCTAssertTrue(ent.allows(f), "\(plan.rawValue): \(f.rawValue)")
            }
            XCTAssertEqual(ent.notes, UFNoteAccess(canView: true, canExport: true, canEdit: true))
            await assertNoAccountToken()
        }
    }

    /// Upgrade in der Gruppe gilt sofort: Plus -> Pro Connect -> Pro AI; der ersetzte Kauf zaehlt nicht mehr, es gilt
    /// der hoechste Tarif
    func testUpgradeTakesEffectImmediatelyAndHighestPlanWins() async throws {
        let (store, ent) = await makeStore()
        _ = await store.purchase(try XCTUnwrap(store.product(for: .plus)))
        XCTAssertEqual(ent.plan, .plus)
        let up = await store.purchase(try XCTUnwrap(store.product(for: .proConnect)))
        XCTAssertEqual(up, .success, store.lastError ?? "")
        XCTAssertEqual(ent.plan, .proConnect, "Upgrade gilt sofort")
        XCTAssertNil(ent.pendingPlan)
        let top = await store.purchase(try XCTUnwrap(store.product(for: .proAI)))
        XCTAssertEqual(top, .success, store.lastError ?? "")
        XCTAssertEqual(ent.plan, .proAI)
        XCTAssertTrue(ent.allows(.pencilWriting))
        // nach dem Upgrade fuehrt StoreKit fuer die Gruppe nur noch den hoechsten Tarif als gueltig
        var active: [String] = []
        for await r in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = r, UFEntitlementResolver.isActive(UFEntitlementEntry(t), now: Date()) { active.append(t.productID) }
        }
        XCTAssertEqual(active, ["de.uniflow.proai.monthly"])
        // neue Instanz (wie nach einem Neustart) kommt zum selben Ergebnis
        let fresh = Entitlements(observe: false)
        await fresh.refresh()
        XCTAssertEqual(fresh.plan, .proAI)
    }

    /// Downgrade in der Gruppe gilt erst zur naechsten Verlaengerung: bis dahin bleibt Pro AI, der Wechsel ist
    /// vorgemerkt; nach der Verlaengerung gilt Plus
    func testDowngradeWaitsForNextRenewal() async throws {
        let (store, ent) = await makeStore()
        let proAI = try XCTUnwrap(store.product(for: .proAI))
        _ = await store.purchase(proAI)
        XCTAssertEqual(ent.plan, .proAI)
        let down = await store.purchase(try XCTUnwrap(store.product(for: .plus)))
        XCTAssertEqual(down, .success, store.lastError ?? "")
        await ent.refresh()
        XCTAssertEqual(ent.plan, .proAI, "Downgrade gilt erst ab der nächsten Verlängerung")
        XCTAssertEqual(ent.pendingPlan, .plus)
        XCTAssertEqual(ent.willRenew, true)
        try session.forceRenewalOfSubscription(productIdentifier: proAI.id)
        let switched = await eventually { await ent.refresh(); return ent.plan == .plus }
        XCTAssertTrue(switched, "nach der Verlängerung gilt Plus")
        XCTAssertNil(ent.pendingPlan)
        XCTAssertTrue(ent.allows(.pencilWriting), "Plus-Rechte bleiben")
    }

    /// Ablauf eines Pro-Tarifs (gekuendigt, Zeitraum vorbei): zurueck auf Free, Notizen bleiben lesbar
    func testExpiryOfProPlanFallsBackToFree() async throws {
        let (store, ent) = await makeStore()
        let proConnect = try XCTUnwrap(store.product(for: .proConnect))
        _ = await store.purchase(proConnect)
        XCTAssertEqual(ent.plan, .proConnect)
        let bought = session.allTransactions().filter { $0.productIdentifier == proConnect.id }
        XCTAssertFalse(bought.isEmpty)
        for t in bought { try session.disableAutoRenewForTransaction(identifier: t.identifier) }
        // gekuendigt: laeuft bis zum Ende des Zeitraums weiter, die Karte sagt es
        let cancelled = await eventually { await ent.refresh(); return ent.willRenew == false }
        XCTAssertTrue(cancelled, "Kündigung kommt in der RenewalInfo an")
        XCTAssertEqual(ent.plan, .proConnect)
        XCTAssertNil(ent.pendingPlan)
        try session.expireSubscription(productIdentifier: proConnect.id)
        // Eigenheit der Testsitzung (Xcode 27.1, gemessen): nach einer erzwungenen Verlaengerung in einem frueheren
        // Test desselben Laufs (testDowngradeWaitsForNextRenewal) meldet currentEntitlements den Ablauf eines Pro-Abos
        // erst nach etwa 15 Sekunden, allein nach unter einer. Die Testsitzung hat ihn sofort. Darum bis zu 30 Sekunden;
        // kommt Free gar nicht, bleibt der Test rot.
        let expired = await eventually(30) { await ent.refresh(); return ent.plan == .free }
        XCTAssertTrue(expired, "Ablauf kam nicht an")
        XCTAssertEqual(ent.plan, .free)
        XCTAssertNil(ent.willRenew)
        XCTAssertFalse(ent.allows(.pencilWriting))
        XCTAssertEqual(ent.notes, UFNoteAccess(canView: true, canExport: true, canEdit: false))
    }

    /// Kaufanfrage fuer Pro AI: erst ausstehend und weiter Free, nach Freigabe Pro AI
    func testAskToBuyForProAIIsPendingUntilApproved() async throws {
        session.askToBuyEnabled = true
        let (store, ent) = await makeStore()
        let proAI = try XCTUnwrap(store.product(for: .proAI))
        let outcome = await store.purchase(proAI)
        XCTAssertEqual(outcome, .pending, store.lastError ?? "")
        XCTAssertNil(store.lastError)
        await ent.refresh()
        // Eigenheit der Testsitzung wie in testAskToBuyIsPendingUntilApproved
        let stillFree = {
            XCTAssertEqual(ent.plan, .free)
            XCTAssertFalse(ent.allows(.pencilWriting))
        }
        if await Self.entitlementsListPendingAskToBuy(session) {
            XCTExpectFailure("StoreKit-Testsitzung meldet die ausstehende Kaufanfrage schon als Anspruch", strict: false,
                             failingBlock: stillFree)
        } else {
            stillFree()
        }
        let t = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == proAI.id })
        try session.approveAskToBuyTransaction(identifier: t.identifier)
        await waitForPlan(ent, .proAI)
        XCTAssertEqual(ent.plan, .proAI)
        XCTAssertTrue(ent.allows(.pencilWriting))
    }

    /// Wiederherstellen eines Pro-Tarifs auf einer neuen Installation
    func testRestoreOfProPlanOnNewInstall() async throws {
        let (store, ent) = await makeStore()
        _ = await store.purchase(try XCTUnwrap(store.product(for: .proAI)))
        XCTAssertEqual(ent.plan, .proAI)
        let freshEnt = Entitlements(observe: false)
        let fresh = PurchaseStore(entitlements: freshEnt)
        await fresh.loadProducts()
        XCTAssertEqual(freshEnt.plan, .free)
        await fresh.restore()
        XCTAssertNil(fresh.lastError)
        XCTAssertEqual(freshEnt.plan, .proAI)
    }
}
