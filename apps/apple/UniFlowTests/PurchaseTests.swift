import StoreKit
import StoreKitTest
import XCTest
@testable import UniFlow

/// Abo-Kauf nur in der lokalen StoreKit-Testsitzung (keine echten Produkte, keine Abrechnung). Drei Produkte in einer
/// Abo-Gruppe (Studora Plus, Pro Connect, Pro AI); Wechsel zwischen ihnen regelt StoreKit wie der App Store.
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

    /// V1 ohne Konto beim Dienst: kein gueltiger Kauf traegt einen appAccountToken (BillingServiceLink.swift)
    private func assertNoAccountToken(file: StaticString = #filePath, line: UInt = #line) async {
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = result { XCTAssertNil(t.appAccountToken, t.productID, file: file, line: line) }
        }
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
        // drei Abo-Tarife (Entscheidung 27.10.2026), nach Preis sortiert wie die Karten; das fruehere Pro gibt es nicht
        XCTAssertEqual(store.products.map(\.id), ["de.uniflow.plus.monthly", "de.uniflow.proconnect.monthly", "de.uniflow.proai.monthly"])
        XCTAssertEqual(ent.plan, .free)
        // jeder Tarif: 1 Woche gratis, monatlich, eine Abo-Gruppe
        for plan in UFPlan.paid {
            let q = try XCTUnwrap(store.product(for: plan), plan.rawValue)
            XCTAssertEqual(q.ufFreeTrial?.0, 1, plan.rawValue)
            XCTAssertEqual(q.ufFreeTrial?.1, .week, plan.rawValue)
            XCTAssertEqual(q.ufPeriod.0, 1, plan.rawValue)
            XCTAssertEqual(q.ufPeriod.1, .month, plan.rawValue)
            XCTAssertEqual(q.subscription?.subscriptionGroupID, store.products.first?.subscription?.subscriptionGroupID)
            XCTAssertEqual(q.displayName, plan.name)
        }
        XCTAssertEqual(store.products.map(\.price), store.products.map(\.price).sorted())
        let p = try XCTUnwrap(store.product(for: .plus))
        let eligibleNow = store.introEligible[p.id] == true
        let trial = try XCTUnwrap(p.ufFreeTrial)
        XCTAssertEqual(trial.0, 1)
        XCTAssertEqual(trial.1, .week)
        XCTAssertEqual(p.ufPeriod.1, .month)
        XCTAssertEqual(UFOfferText.button(plan: .plus, price: p.displayPrice, period: p.ufPeriod, freeTrial: trial, eligible: true),
                       "Studora Plus – 1 Woche gratis")
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
        // der Anspruch gilt je Abo-Gruppe: auch Pro Connect und Pro AI zeigen danach keine Gratiswoche mehr
        XCTAssertEqual(store.introEligible["de.uniflow.proconnect.monthly"], false)
        XCTAssertEqual(store.introEligible["de.uniflow.proai.monthly"], false)
        XCTAssertEqual(UFOfferText.button(plan: .plus, price: p.displayPrice, period: p.ufPeriod, freeTrial: p.ufFreeTrial,
                                          eligible: false), "Studora Plus für \(p.displayPrice)/Monat")
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
        // Uni & Noten (QIS bzw. LSF auf dem Geraet) gehoert zu Free; Community (Loesung als Datei teilen und ansehen) zu Plus
        XCTAssertEqual(ent.access(.uniGrades), .allowed)
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

    // MARK: Vier Tarife

    /// Kauf je Tarif: jeder Abo-Tarif schaltet sich selbst frei, mit allem aus Plus und Gratiswoche; nie mit
    /// appAccountToken (V1 ohne Konto beim Dienst)
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
            for f: UFFeature in [.pencilWriting, .community, .splitView, .flashcards, .studyPlanning, .readDocuments] {
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
