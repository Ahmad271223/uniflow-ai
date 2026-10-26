import StoreKit
import StoreKitTest
import XCTest
@testable import UniFlow

/// Abo-Kauf nur in der lokalen StoreKit-Testsitzung (keine echten Produkte, keine Abrechnung).
@MainActor
final class PurchaseTests: XCTestCase {
    private var session: SKTestSession!
    /// Gab es in diesem Testprozess schon einen Kauf? Dann meldet StoreKit keinen Anspruch mehr (siehe test0…).
    private static var processHadPurchase = false

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "UniFlow")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() async throws {
        if !session.allTransactions().isEmpty { Self.processHadPurchase = true }
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

    /// Steht eine Transaktion, die die Testsitzung noch als ausstehende Kaufanfrage fuehrt, in currentEntitlements?
    private static func entitlementsListPendingAskToBuy(_ session: SKTestSession) async -> Bool {
        let pending = Set(session.allTransactions().filter(\.pendingAskToBuyConfirmation).map { UInt64($0.identifier) })
        guard !pending.isEmpty else { return false }
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = result, pending.contains(t.id) { return true }
        }
        return false
    }

    /// eigener Tarif ohne Beobachter, damit sich die Tests nicht gegenseitig beeinflussen. Ausgangslage ist immer Free:
    /// Nach clearTransactions() meldet die Testsitzung den Kauf des vorigen Tests noch kurz in currentEntitlements,
    /// darum wird gewartet, bis er verschwunden ist (sonst startet z. B. die Kaufanfrage scheinbar schon mit Plus).
    private func makeStore() async -> (PurchaseStore, Entitlements) {
        let ent = Entitlements(observe: false)
        let store = PurchaseStore(entitlements: ent)
        await store.loadProducts()
        await waitForPlan(ent, .free)
        XCTAssertEqual(ent.plan, .free, "Ausgangslage: kein Kauf aus einem vorigen Test mehr gueltig")
        return (store, ent)
    }

    /// Verhalten der StoreKit-Testsitzung (mit Prueftests unter Xcode 27.1 ermittelt): Nach dem ersten Kauf liefert
    /// `isEligibleForIntroOffer` fuer die Gruppe false, auch nach clearTransactions() und resetToDefaultState() und
    /// auch in spaeteren Testlaeufen auf demselben Simulator. Ein neuer Kauf nach clearTransactions() bekommt die
    /// Gratiswoche dagegen wieder (testPurchaseAfterClearedTransactionsStartsFreeWeekAgain). Darum prueft dieser Test
    /// Angebot und Texte immer, den Anspruch selbst aber nur, solange StoreKit ihn noch meldet; sonst endet er mit
    /// einem Hinweis statt falsch rot. Er heisst "test0…", weil XCTest die Tests einer Klasse alphabetisch ausfuehrt.
    func test0ProductsCarryOneFreeWeekUntilFirstPurchase() async throws {
        let (store, ent) = await makeStore()
        // nur Plus wird angeboten (Entscheidung 25.10.2026), kein Pro-Produkt mehr
        XCTAssertEqual(store.products.map(\.id), ["de.uniflow.plus.monthly"])
        XCTAssertEqual(ent.plan, .free)
        let p = try XCTUnwrap(store.product(for: .plus))
        let eligibleNow = store.introEligible[p.id] == true
        let trial = try XCTUnwrap(p.ufFreeTrial)
        XCTAssertEqual(trial.0, 1)
        XCTAssertEqual(trial.1, .week)
        XCTAssertEqual(p.ufPeriod.1, .month)
        XCTAssertEqual(UFOfferText.button(plan: .plus, price: p.displayPrice, period: p.ufPeriod, freeTrial: trial, eligible: true),
                       "Plus – 1 Woche gratis")
        XCTAssertTrue(UFOfferText.summary(price: p.displayPrice, period: p.ufPeriod, freeTrial: trial, eligible: true)
            .hasPrefix("1 Woche gratis, danach \(p.displayPrice)/Monat"))
        guard eligibleNow, !Self.processHadPurchase else {
            throw XCTSkip("Die StoreKit-Testumgebung dieses Simulators hat die Probewoche schon verbraucht; Angebot und Texte sind geprüft, der Anspruch nicht (frischer Simulator nötig).")
        }
        // Kauf verbraucht den Anspruch: danach zeigt Plus den normalen Preis.
        // Ohne erneutes loadProducts(), so wie die Seite in den Einstellungen nach dem Kauf offen bleibt.
        let outcome = await store.purchase(p)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        XCTAssertEqual(store.introEligible[p.id], false)
        XCTAssertEqual(UFOfferText.button(plan: .plus, price: p.displayPrice, period: p.ufPeriod, freeTrial: p.ufFreeTrial,
                                          eligible: false), "Plus für \(p.displayPrice)/Monat")
        XCTAssertFalse(UFOfferText.summary(price: p.displayPrice, period: p.ufPeriod, freeTrial: p.ufFreeTrial,
                                           eligible: store.introEligible[p.id] == true).contains("gratis"))
    }

    func testPlusPurchaseStartsFreeWeekAndUsesUpEligibility() async throws {
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        let outcome = await store.purchase(plus)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        XCTAssertEqual(ent.plan, .plus)
        XCTAssertTrue(ent.inIntroOffer, "Während der Gratiswoche gilt Plus mit Einführungsangebot")
        XCTAssertTrue(ent.allows(.pencilWriting))
        XCTAssertTrue(ent.allows(.splitView))
        // Uni & Noten ist auch mit Plus "bald"; Community (Loesung als Datei teilen und ansehen) gehoert zu Plus
        XCTAssertEqual(ent.access(.uniGrades), .comingSoon)
        XCTAssertEqual(ent.access(.community), .allowed)
        XCTAssertEqual(ent.transactionCount, 1)
        XCTAssertEqual(store.introEligible["de.uniflow.plus.monthly"], false)
    }

    /// Beleg, dass die Kauf-Tests nicht von der Reihenfolge abhaengen: Nach clearTransactions() startet ein neuer
    /// Kauf wieder mit der Gratiswoche
    func testPurchaseAfterClearedTransactionsStartsFreeWeekAgain() async throws {
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        _ = await store.purchase(plus)
        XCTAssertTrue(ent.inIntroOffer)
        session.clearTransactions()
        await waitForPlan(ent, .free)
        XCTAssertEqual(ent.plan, .free)
        let again = await store.purchase(plus)
        XCTAssertEqual(again, .success, store.lastError ?? "")
        XCTAssertEqual(ent.plan, .plus)
        XCTAssertTrue(ent.inIntroOffer, "Nach gelöschten Transaktionen beginnt Plus wieder mit der Gratiswoche")
    }

    /// Verlaengerung nach der Gratiswoche: Tarif bleibt Plus, jetzt bezahlt (kein Einfuehrungsangebot mehr)
    func testRenewalAfterFreeWeekKeepsPlusWithoutIntroOffer() async throws {
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        let outcome = await store.purchase(plus)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        XCTAssertTrue(ent.inIntroOffer)
        let firstExpiry = try XCTUnwrap(ent.expiresAt)
        try session.forceRenewalOfSubscription(productIdentifier: plus.id)
        let renewed = await eventually { await ent.refresh(); return !ent.inIntroOffer }
        XCTAssertTrue(renewed, "Nach der Verlängerung läuft keine Gratiswoche mehr")
        XCTAssertEqual(ent.plan, .plus)
        XCTAssertTrue(ent.allows(.pencilWriting))
        XCTAssertGreaterThan(try XCTUnwrap(ent.expiresAt), firstExpiry)
        await store.refreshEligibility()
        XCTAssertEqual(store.introEligible[plus.id], false)
    }

    /// Kaufanfrage (Familienfreigabe, "Ask to Buy"): erst ausstehend und weiter Free, nach Freigabe Plus
    func testAskToBuyIsPendingUntilApproved() async throws {
        session.askToBuyEnabled = true
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        let outcome = await store.purchase(plus)
        XCTAssertEqual(outcome, .pending, store.lastError ?? "")
        XCTAssertNil(store.lastError)
        await ent.refresh()
        // Eigenheit der StoreKit-Testsitzung (Xcode 27.1, gemessen 4 von 8 Laeufen): die noch ausstehende Kaufanfrage
        // (Zustand "deferred", pendingAskToBuyConfirmation) steht manchmal schon in Transaction.currentEntitlements.
        // Im App Store entsteht vor der Freigabe keine Transaktion. Nur in genau diesem Fall darf Free hier fehlen;
        // vergibt die App Plus ohne einen solchen Eintrag, bleibt der Test rot.
        let stillFree = {
            XCTAssertEqual(ent.plan, .free)
            XCTAssertFalse(ent.allows(.pencilWriting))
        }
        if await Self.entitlementsListPendingAskToBuy(session) {
            // nur diese beiden Pruefungen, die Freigabe danach bleibt streng
            XCTExpectFailure("StoreKit-Testsitzung meldet die ausstehende Kaufanfrage schon als Anspruch", strict: false,
                             failingBlock: stillFree)
        } else {
            stillFree()
        }
        let t = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == plus.id })
        try session.approveAskToBuyTransaction(identifier: t.identifier)
        await waitForPlan(ent, .plus)
        XCTAssertEqual(ent.plan, .plus)
        XCTAssertTrue(ent.allows(.pencilWriting))
    }

    func testExpiryFallsBackToFree() async throws {
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        _ = await store.purchase(plus)
        XCTAssertEqual(ent.plan, .plus)
        // gekuendigt (keine Verlaengerung), dann laeuft der Zeitraum ab; alle Kaeufe des Produkts, sonst verlaengert
        // ein uebrig gebliebener aelterer Kauf das Abo und der Tarif bleibt Plus
        let bought = session.allTransactions().filter { $0.productIdentifier == plus.id }
        XCTAssertFalse(bought.isEmpty)
        for t in bought { try session.disableAutoRenewForTransaction(identifier: t.identifier) }
        try session.expireSubscription(productIdentifier: plus.id)
        await waitForPlan(ent, .free)
        XCTAssertEqual(ent.plan, .free)
        XCTAssertFalse(ent.allows(.pencilWriting))
        // Herabstufen: Notizen bleiben lesbar und exportierbar
        XCTAssertEqual(ent.notes, UFNoteAccess(canView: true, canExport: true, canEdit: false))
    }

    func testRefundRevokesPlan() async throws {
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        _ = await store.purchase(plus)
        XCTAssertEqual(ent.plan, .plus)
        let t = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == plus.id })
        try session.refundTransaction(identifier: t.identifier)
        await waitForPlan(ent, .free)
        XCTAssertEqual(ent.plan, .free)
        XCTAssertFalse(ent.allows(.pencilWriting))
        // Lernplanung bleibt in Free
        XCTAssertTrue(ent.allows(.studyPlanning))
    }

    func testRestoreOnNewInstall() async throws {
        let (store, ent) = await makeStore()
        _ = await store.purchase(try XCTUnwrap(store.product(for: .plus)))
        XCTAssertEqual(ent.plan, .plus)
        // neue Instanz wie nach Neuinstallation, ohne vorheriges refresh(): Tarif zuerst Free,
        // erst restore() liefert den Tarif aus dem Store
        let freshEnt = Entitlements(observe: false)
        let fresh = PurchaseStore(entitlements: freshEnt)
        await fresh.loadProducts()
        XCTAssertEqual(freshEnt.plan, .free)
        await fresh.restore()
        XCTAssertNil(fresh.lastError)
        XCTAssertEqual(freshEnt.plan, .plus)
        XCTAssertNotNil(freshEnt.expiresAt, "Ablauf des wiederhergestellten Abos fehlt")
    }
}
