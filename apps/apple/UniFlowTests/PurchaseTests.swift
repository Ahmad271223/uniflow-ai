import StoreKit
import StoreKitTest
import XCTest
@testable import UniFlow

/// Gemeinsamer Rahmen der Kauf-Tests: lokale StoreKit-Testsitzung (keine echten Produkte, keine Abrechnung) mit der
/// Konfiguration `configuration` und den Produkten `productIDs`.
@MainActor
class StoreKitSessionTestCase: XCTestCase {
    var session: SKTestSession!
    /// Gab es in diesem Testprozess schon einen Kauf? Dann meldet StoreKit keinen Anspruch mehr (siehe test0…).
    static var processHadPurchase = false

    /// StoreKit-Konfiguration im Testbundle
    class var configuration: String { "UniFlow" }
    /// Produkte, die der Laden der Tests anbietet
    class var productIDs: [String] { PurchaseStore.productIDs }

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: Self.configuration)
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
    func eventually(_ seconds: Double = 8, _ check: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await check() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return await check()
    }

    func waitForPlan(_ ent: Entitlements, _ plan: UFPlan, seconds: Double = 8) async {
        _ = await eventually(seconds) { await ent.refresh(); return ent.plan == plan }
    }

    /// V1 ohne Konto beim Dienst: kein gueltiger Kauf traegt einen appAccountToken (BillingServiceLink.swift)
    func assertNoAccountToken(file: StaticString = #filePath, line: UInt = #line) async {
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = result { XCTAssertNil(t.appAccountToken, t.productID, file: file, line: line) }
        }
    }

    /// Steht eine Transaktion, die die Testsitzung noch als ausstehende Kaufanfrage fuehrt, in currentEntitlements?
    static func entitlementsListPendingAskToBuy(_ session: SKTestSession) async -> Bool {
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
    func makeStore() async -> (PurchaseStore, Entitlements) {
        let ent = Entitlements(observe: false)
        let store = PurchaseStore(entitlements: ent, productIDs: Self.productIDs)
        await store.loadProducts()
        await waitForPlan(ent, .free)
        XCTAssertEqual(ent.plan, .free, "Ausgangslage: kein Kauf aus einem vorigen Test mehr gueltig")
        return (store, ent)
    }
}

/// Abo-Kauf (Entscheidung des Inhabers vom 04.11.2026): StudiNow Plus und Pro AI, kein Einfuehrungsangebot; die Probe
/// laeuft auf dem iPad ohne Kauf (LocalTrialTests). Konfiguration `UniFlow.storekit` wie in der App (Schema "Run").
@MainActor
final class PurchaseTests: StoreKitSessionTestCase {
    /// Der Laden hat Plus und Pro AI, kein Produkt traegt ein Einfuehrungsangebot, die Texte nennen nur den Preis aus
    /// dem Produkt. Pro Connect und das fruehere Pro gibt es nicht, auch nicht auf Nachfrage.
    func test0ProductsCarryNoIntroductoryOffer() async throws {
        let (store, ent) = await makeStore()
        // nur die Jahresabos (Entscheidung des Inhabers vom 09.11.2026), nach Preis
        XCTAssertEqual(store.products.map(\.id), ["de.uniflow.plus.yearly", "de.uniflow.proai.yearly"])
        let other = try await Product.products(for: ["de.uniflow.proconnect.monthly", "de.uniflow.pro.monthly",
                                                     "de.uniflow.plus.monthly", "de.uniflow.proai.monthly"])
        XCTAssertEqual(other.map(\.id), [], "kein Monatsabo, kein Pro Connect und kein frueheres Pro in der Konfiguration der App")
        XCTAssertEqual(ent.plan, .free)
        for plan in [UFPlan.plus, .proAI] {
            let p = try XCTUnwrap(store.product(for: plan), plan.rawValue)
            XCTAssertEqual(p.displayName, plan.name)
            XCTAssertNil(p.subscription?.introductoryOffer, "kein Apple-Einführungsangebot: \(plan.rawValue)")
            XCTAssertEqual(p.ufPeriod.1, .year)
            XCTAssertEqual(UFOfferText.button(plan: plan, price: p.displayPrice, period: p.ufPeriod),
                           "\(plan.name) für \(p.displayPrice)/Jahr")
            XCTAssertEqual(UFOfferText.summary(price: p.displayPrice, period: p.ufPeriod),
                           "\(p.displayPrice)/Jahr, verlängert sich jährlich, jederzeit zum Laufzeitende kündbar")
        }
        // Tarifkarten: mit Pro-AI-Produkt drei Karten, ohne (vor dem Dienst) nur Free und Plus
        XCTAssertEqual(UFPlanCatalog.cards(current: ent.purchasedPlan, loaded: store.loadedProductIDs), [.free, .plus, .proAI])
        XCTAssertFalse(PlanPickerView.showsProAIMissingNote(loaded: store.loadedProductIDs, loading: false, current: .free))
        let plusOnly = PurchaseStore(entitlements: ent, productIDs: ["de.uniflow.plus.yearly"])
        await plusOnly.loadProducts()
        XCTAssertNil(plusOnly.lastError)
        XCTAssertEqual(UFPlanCatalog.cards(current: .free, loaded: plusOnly.loadedProductIDs), [.free, .plus])
        XCTAssertTrue(PlanPickerView.showsProAIMissingNote(loaded: plusOnly.loadedProductIDs, loading: false, current: .free))
    }

    func testPlusPurchaseUnlocksPlusWithoutIntroOffer() async throws {
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        let outcome = await store.purchase(plus)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        XCTAssertEqual(ent.plan, .plus)
        XCTAssertEqual(ent.purchasedPlan, .plus)
        XCTAssertEqual(ent.purchasedBilling, .yearly)
        XCTAssertTrue(ent.allows(.pencilWriting))
        XCTAssertTrue(ent.allows(.splitView))
        // Uni & Noten (QIS bzw. LSF auf dem Geraet) gehoert zu Free; eigene Loesungen teilen zu Plus
        XCTAssertEqual(ent.access(.uniGrades), .allowed)
        XCTAssertEqual(ent.access(.shareSolutions), .allowed)
        XCTAssertEqual(ent.transactionCount, 1)
        // Transaktion ohne Einfuehrungsangebot
        for await r in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = r, t.productID == plus.id { XCTAssertNotEqual(t.offerType, .introductory) }
        }
    }

    /// Jahresabo (seit 09.11.2026 das einzige Abo): Tarif, Zahlweise und Ablauf nach einem Jahr
    func testYearlyPurchaseUnlocksPlanWithYearlyBilling() async throws {
        let (store, ent) = await makeStore()
        let yearly = try XCTUnwrap(store.product(for: .proAI))
        let outcome = await store.purchase(yearly)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        XCTAssertEqual(ent.plan, .proAI)
        XCTAssertEqual(ent.purchasedPlan, .proAI)
        XCTAssertEqual(ent.purchasedBilling, .yearly)
        XCTAssertNotNil(ent.expiresAt, "Ablauf des Jahresabos bekannt")
        XCTAssertNil(ent.pendingPlan)
        XCTAssertEqual(ent.willRenew, true)
    }

    /// Pro AI kaufen gibt Pro AI (StoreKit-Berechtigung wie heute); auf dem iPad derselbe Umfang wie Plus
    func testProAIPurchaseUnlocksProAI() async throws {
        let (store, ent) = await makeStore()
        let proAI = try XCTUnwrap(store.product(for: .proAI))
        let outcome = await store.purchase(proAI)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        XCTAssertEqual(ent.plan, .proAI)
        XCTAssertEqual(ent.purchasedPlan, .proAI)
        XCTAssertTrue(ent.allows(.pencilWriting))
        XCTAssertEqual(ent.statusLabel, "StudiNow Pro AI")
        await assertNoAccountToken()
    }

    /// Verlaengerung: Tarif bleibt Plus, der Ablauf rueckt nach vorn
    func testRenewalKeepsPlus() async throws {
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        let outcome = await store.purchase(plus)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        let firstExpiry = try XCTUnwrap(ent.expiresAt)
        try session.forceRenewalOfSubscription(productIdentifier: plus.id)
        let renewed = await eventually { await ent.refresh(); return (ent.expiresAt ?? firstExpiry) > firstExpiry }
        XCTAssertTrue(renewed, "Verlängerung kam nicht an")
        XCTAssertEqual(ent.plan, .plus)
        XCTAssertTrue(ent.allows(.pencilWriting))
    }

    /// Vorrang: ein gekaufter Tarif gilt vor der Probe auf dem iPad; nach Ablauf des Abos faellt die App nur auf Free,
    /// wenn auch die Probe vorbei ist
    func testPurchasedPlanTakesPrecedenceOverLocalTrial() async throws {
        let (store, ent) = await makeStore()
        let now = Date()
        ent.useLocalTrial(startedAt: now, now: now)
        XCTAssertEqual(ent.plan, .proAI, "Probe: alles wie Pro AI")
        XCTAssertEqual(ent.purchasedPlan, .free)
        let plus = try XCTUnwrap(store.product(for: .plus))
        let bought = await store.purchase(plus)
        XCTAssertEqual(bought, .success, store.lastError ?? "")
        XCTAssertEqual(ent.plan, .plus, "gekauft ist gekauft: Plus, nicht die Probe")
        XCTAssertEqual(ent.purchasedPlan, .plus)
        // nach dem Ende der Probe bleibt Plus
        ent.refreshLocalTrial(now: now.addingTimeInterval(8 * 86_400))
        XCTAssertEqual(ent.plan, .plus)
        ent.useLocalTrial(startedAt: nil)
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
        // Ablauf kommt in der Testsitzung manchmal erst nach Sekunden an (PurchaseV2PlanSwitchTests)
        await waitForPlan(ent, .free, seconds: 30)
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
        // Ablauf kommt in der Testsitzung manchmal erst nach Sekunden an (PurchaseV2PlanSwitchTests)
        await waitForPlan(ent, .free, seconds: 30)
        XCTAssertEqual(ent.plan, .free)
        XCTAssertFalse(ent.allows(.pencilWriting))
        // Lernplanung bleibt in Free
        XCTAssertTrue(ent.allows(.studyPlanning))
    }

    /// 223: Der Beobachter von Transaction.updates (wie `Entitlements.shared` ab App-Start) schaltet eine spaeter
    /// freigegebene Kaufanfrage von selbst frei – ohne dass eine Ansicht refresh() aufruft
    func testTransactionUpdatesListenerUnlocksApprovedAskToBuyWithoutRefresh() async throws {
        session.askToBuyEnabled = true
        let ent = Entitlements(observe: true)
        _ = await eventually { !ent.loading }
        let store = PurchaseStore(entitlements: ent)
        await store.loadProducts()
        await waitForPlan(ent, .free)
        let plus = try XCTUnwrap(store.product(for: .plus))
        let outcome = await store.purchase(plus)
        XCTAssertEqual(outcome, .pending, store.lastError ?? "")
        let t = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == plus.id })
        try session.approveAskToBuyTransaction(identifier: t.identifier)
        // ab hier kein refresh(): nur der Beobachter darf den Tarif aendern
        let unlocked = await eventually(15) { ent.plan == .plus }
        XCTAssertTrue(unlocked, "Transaction.updates hat die Freigabe nicht verarbeitet")
        XCTAssertGreaterThanOrEqual(ent.transactionCount, 1)
        XCTAssertTrue(ent.allows(.pencilWriting))
    }

    /// 226: Abbruch im Kaufdialog ist kein Fehler (keine Meldung, Free bleibt); ein echter Fehler nennt den Grund und
    /// schaltet nichts frei. Den Abbruch durch den Menschen kann die Testsitzung nicht ausloesen (`failureError =
    /// .paymentCancelled` kommt als `StoreKitError.unknown` an, gemessen unter Xcode 27.1): darum die Zuordnung des
    /// Dialog-Ergebnisses direkt, den Fehlerweg ueber die Testsitzung.
    func testCancelledPurchaseIsNoErrorAndFailedPurchaseUnlocksNothing() async throws {
        XCTAssertEqual(PurchaseStore.outcome(of: .userCancelled), .cancelled)
        XCTAssertEqual(PurchaseStore.outcome(of: .pending), .pending)
        let thrownCancel = PurchaseStore.failure(StoreKitError.userCancelled)
        XCTAssertEqual(thrownCancel.outcome, .cancelled)
        XCTAssertNil(thrownCancel.message, "Abbruch ohne Fehlermeldung")
        let other = PurchaseStore.failure(StoreKitError.networkError(URLError(.notConnectedToInternet)))
        XCTAssertEqual(other.outcome, .failed)
        XCTAssertTrue(other.message?.hasPrefix("Kauf fehlgeschlagen: ") == true, other.message ?? "")

        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        session.failTransactionsEnabled = true
        defer { session.failTransactionsEnabled = false }
        session.failureError = .unknown
        let failed = await store.purchase(plus)
        XCTAssertEqual(failed, .failed)
        XCTAssertTrue(store.lastError?.hasPrefix("Kauf fehlgeschlagen") == true, store.lastError ?? "")
        XCTAssertEqual(ent.plan, .free)
        XCTAssertEqual(ent.transactionCount, 0)
        XCTAssertFalse(ent.allows(.pencilWriting))
    }

    /// 224: Lehnt die Pruefung eine Transaktion ab, erfaehrt der Nutzer den Grund (Fehlerkarte) und die Tarifwahl geht
    /// nicht weiter. Hier ueber die Server-Pruefung (V2-Haken); eine von StoreKit unverifizierte Transaktion geht
    /// denselben Weg (`Entitlements.handle` -> false).
    func testRejectedVerificationTellsTheUser() async throws {
        let (store, ent) = await makeStore()
        ent.verifyOnServer = { _ in false }
        let plus = try XCTUnwrap(store.product(for: .plus))
        let outcome = await store.purchase(plus)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(store.lastError, "Der Kauf konnte nicht bestätigt werden.")
    }

    /// 229: Store nicht erreichbar (hier: keine bekannten Produkte): verstaendliche Meldung mit "Erneut versuchen",
    /// der zuletzt bekannte Tarif und die Notizen bleiben
    func testUnreachableStoreKeepsPlanAndExplains() async throws {
        let (store, ent) = await makeStore()
        _ = await store.purchase(try XCTUnwrap(store.product(for: .plus)))
        XCTAssertEqual(ent.plan, .plus)
        let offline = PurchaseStore(entitlements: ent, productIDs: ["de.uniflow.nicht.vorhanden"])
        await offline.loadProducts()
        XCTAssertTrue(offline.products.isEmpty)
        XCTAssertEqual(offline.lastError, "Die Tarife konnten nicht geladen werden. Prüfe die Verbindung und versuche es erneut.")
        XCTAssertNil(offline.product(for: .plus), "kein Kaufknopf ohne Produkt")
        await offline.refreshEntitlements()
        XCTAssertEqual(ent.plan, .plus, "Tarif aus den gespeicherten Berechtigungen bleibt")
        XCTAssertEqual(ent.notes, UFNoteAccess(canView: true, canExport: true, canEdit: true))
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .free), UFNoteAccess(canView: true, canExport: true, canEdit: false),
                       "auch ohne Tarif bleiben Notizen lesbar und exportierbar")
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
