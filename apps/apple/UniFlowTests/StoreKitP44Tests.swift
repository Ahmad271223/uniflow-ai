import StoreKit
import StoreKitTest
import XCTest
import UniFlowCore
@testable import UniFlow

/// Audit 08.11.2026, Paket 44 (Apple StoreKit, Abos, Probe, Tarifrechte): Ablauf bei offener App, Uhr verstellt,
/// Kulanzfrist (Billing Grace Period), Tarif-Matrix Free/Probe/Plus/Pro AI/Probe+Plus. Nur erfundene Apple-IDs,
/// Ablage der Probe im Speicher, Kaeufe in der lokalen StoreKit-Testsitzung (keine Abrechnung).
@MainActor
final class LocalTrialP44Tests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }
    private func newID() -> String { "001234.p44.\(UUID().uuidString.prefix(8))" }

    // MARK: P44-11 Ablauf der Probe bei offener App

    /// Die App bleibt im Vordergrund (kein Wechsel der scenePhase), die 7 Tage enden: der Tarif faellt von selbst auf
    /// Free, ohne dass ein Aufrufer `refreshLocalTrial` ruft (vorher erst beim naechsten Wechsel in den Vordergrund)
    func testLocalTrialEndsWhileTheAppStaysOpen() async {
        let e = Entitlements(observe: false)
        // Beginn knapp 7 Tage zurueck (Schluesselbund)
        let start = Date().addingTimeInterval(-UFLocalTrial.length + 1.5)
        let r = UFMemoryTrialRecords()
        let id = newID()
        r.records[UFLocalTrial.scope(userID: id)] = UFTrialRecords(keychain: start, cloud: nil)
        e.beginLocalTrial(userID: id, records: r, now: Date())
        XCTAssertEqual(e.plan, .proAI, "Probe laeuft noch gut eine Sekunde")
        XCTAssertEqual(e.localTrial?.daysLeft, 1)
        let end = Date().addingTimeInterval(6)
        while Date() < end, e.plan != .free { try? await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertEqual(e.plan, .free, "Ende der Probe bei offener App: Free ohne Vordergrundwechsel")
        XCTAssertEqual(e.localTrial?.isExpired, true)
        XCTAssertEqual(e.access(.pencilWriting), .locked(.plus))
        XCTAssertEqual(UFTrialDecision.required(local: e.localTrial, purchased: e.purchasedPlan, effective: e.plan,
                                                choiceMade: e.localTrialChoiceMade), true,
                       "Entscheidungs-Bildschirm erscheint sofort")
        e.useLocalTrial(startedAt: nil)
    }

    /// naechster Zeitpunkt ohne Ereignis: Tageswechsel der Resttage, Ende der Probe, Ende des Abos (bzw. der Kulanzfrist)
    func testNextExpiryCheck() {
        let running = UFLocalTrial.state(startedAt: t0, now: day(2.5))             // 5 Tage uebrig
        XCTAssertEqual(running.daysLeft, 5)
        XCTAssertEqual(UFPlanExpiry.next(localTrial: running, rightsEnd: nil, now: day(2.5)), day(3), "Resttage 5 -> 4")
        let last = UFLocalTrial.state(startedAt: t0, now: day(6.5))
        XCTAssertEqual(UFPlanExpiry.next(localTrial: last, rightsEnd: nil, now: day(6.5)), day(7), "Ende der Probe")
        XCTAssertEqual(UFPlanExpiry.next(localTrial: last, rightsEnd: day(6.6), now: day(6.5)), day(6.6), "Abo endet frueher")
        XCTAssertEqual(UFPlanExpiry.next(localTrial: nil, rightsEnd: day(40), now: day(6.5)), day(40))
        XCTAssertNil(UFPlanExpiry.next(localTrial: nil, rightsEnd: day(6), now: day(6.5)), "schon vorbei: kein Wecker")
        let over = UFLocalTrial.state(startedAt: t0, now: day(8))
        XCTAssertNil(UFPlanExpiry.next(localTrial: over, rightsEnd: nil, now: day(8)))
        XCTAssertNil(UFPlanExpiry.next(localTrial: .usedOnDevice(since: t0), rightsEnd: nil, now: day(1)))
    }

    // MARK: P44-12 Uhr verstellt

    /// Uhr beim ersten Start vorgestellt (z. B. ein Jahr), danach richtig: vorher lief die Probe ein Jahr und sieben
    /// Tage ("noch 372 Tage"). Jetzt zaehlt ein Beginn in der Zukunft ab dem Moment, in dem die App ihn sieht.
    func testStartInTheFutureCountsFromNow() {
        let records = UFMemoryTrialRecords()
        let id = newID()
        let scope = UFLocalTrial.scope(userID: id)
        XCTAssertEqual(UFLocalTrial.begin(userID: id, records: records, now: day(365)).daysLeft, 7)
        let corrected = UFLocalTrial.begin(userID: id, records: records, now: t0)
        XCTAssertEqual(corrected.daysLeft, 7, "nie mehr als 7 Tage")
        XCTAssertEqual(corrected.startedAt, t0)
        XCTAssertEqual(records.load(scope).keychain, t0, "Beginn auf jetzt zurueckgesetzt und gespeichert")
        XCTAssertEqual(records.load(scope).cloud, t0)
        XCTAssertTrue(UFLocalTrial.begin(userID: id, records: records, now: day(7)).isExpired)
        // reine Rechnung: Beginn in der Zukunft zeigt hoechstens 7 Resttage
        XCTAssertLessThanOrEqual(UFLocalTrial.state(startedAt: day(30), now: t0).daysLeft, UFLocalTrial.days)
    }

    /// Probe vorbei, dann die Uhr zurueckgestellt: vorher lief die Probe wieder ("noch 5 Tage"). Ein einmal gesehenes
    /// Ende bleibt (Schluesselbund, ueberlebt die Neuinstallation)
    func testClockSetBackDoesNotReviveAnEndedTrial() {
        let records = UFMemoryTrialRecords()
        let id = newID()
        XCTAssertEqual(UFLocalTrial.begin(userID: id, records: records, now: t0).daysLeft, 7)
        XCTAssertTrue(UFLocalTrial.begin(userID: id, records: records, now: day(8)).isExpired)
        XCTAssertTrue(records.load(UFLocalTrial.scope(userID: id)).endedSeen)
        let back = UFLocalTrial.begin(userID: id, records: records, now: day(2))
        XCTAssertTrue(back.isExpired, "Uhr zurueck holt die Probe nicht zurueck")
        XCTAssertEqual(back.daysLeft, 0)
        // auch im laufenden Prozess (Vordergrund nach dem Verstellen)
        let e = Entitlements(observe: false)
        let r2 = UFMemoryTrialRecords()
        let id2 = newID()
        e.beginLocalTrial(userID: id2, records: r2, now: t0)
        XCTAssertEqual(e.plan, .proAI)
        e.refreshLocalTrial(now: day(8))
        XCTAssertEqual(e.plan, .free)
        e.refreshLocalTrial(now: day(3))
        XCTAssertEqual(e.plan, .free, "Uhr zurueck im laufenden Prozess: bleibt Free")
        XCTAssertEqual(e.localTrial?.daysLeft, 0)
        XCTAssertTrue(r2.load(UFLocalTrial.scope(userID: id2)).endedSeen)
        e.useLocalTrial(startedAt: nil)
    }

    /// Uhr waehrend der Probe zurueckgestellt (Ende noch nicht gesehen): die Probe laeuft nach der Uhr des Geraets
    /// weiter, hoechstens 7 Resttage. Produktentscheidung (Bericht P44-12): ohne Dienst gibt es keine verlaessliche Uhr;
    /// wer die Uhr dauerhaft falsch laesst, verlaengert die Probe auf diesem iPad
    func testClockSetBackDuringTheTrialNeverShowsMoreThanSevenDays() {
        let records = UFMemoryTrialRecords()
        let id = newID()
        _ = UFLocalTrial.begin(userID: id, records: records, now: t0)
        XCTAssertEqual(UFLocalTrial.begin(userID: id, records: records, now: day(5)).daysLeft, 2)
        let back = UFLocalTrial.begin(userID: id, records: records, now: day(-3))
        XCTAssertEqual(back.daysLeft, 7, "Beginn rueckt auf die neue Uhr, nie mehr als 7 Tage")
        XCTAssertEqual(records.load(UFLocalTrial.scope(userID: id)).keychain, day(-3))
    }

    /// Neuinstallation nach dem Ende: die Marke "Ende gesehen" liegt im Schluesselbund (echter Schluesselbund, eigener
    /// Dienst, danach aufgeraeumt)
    func testEndedMarkLivesInTheKeychain() throws {
        let store = UFTrialRecordStore(keychain: KeychainStore(service: "de.uniflow.ai.trial.p44.\(UUID().uuidString)"),
                                       cloud: nil, defaults: UserDefaults(suiteName: "uniflow.tests.p44.\(UUID().uuidString)")!)
        let scope = UFLocalTrial.scope(userID: newID())
        addTeardownBlock { store.remove(scope); store.keychain.removeAll(); store.removeDeviceMark() }
        XCTAssertFalse(store.load(scope).endedSeen)
        store.markEnded(scope)
        XCTAssertTrue(store.load(scope).endedSeen)
        let reinstalled = UFTrialRecordStore(keychain: store.keychain, cloud: nil,
                                             defaults: UserDefaults(suiteName: "uniflow.tests.p44.\(UUID().uuidString)")!)
        XCTAssertTrue(reinstalled.load(scope).endedSeen, "ueberlebt die Neuinstallation (UserDefaults leer)")
        let attrs = try XCTUnwrap(store.keychain.attributes(UFTrialRecordStore.endedAccount(scope)))
        XCTAssertEqual(attrs.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(attrs.synchronizable, false)
    }

    // MARK: P44-13 Tarif-Matrix

    /// Was jeder Stand zeigt und freischaltet (Free, Probe, Plus, Pro AI, Probe+Plus, Probe des Kontos). KI nur ueber
    /// den Dienst: Plus nie, Pro AI und Probe nur angemeldet (Credits beim Dienst: Probe 25, Plus 0, Pro AI 100,
    /// Probe+Plus 25 bis Probeende, AUDIT-2026-11-08-PAKET-21-22.md)
    func testPlanMatrixPerState() {
        let running = UFLocalTrial.state(startedAt: t0, now: day(1))
        let over = UFLocalTrial.state(startedAt: t0, now: day(8))
        struct Row { let name: String; let service: UFPlan?; let purchased: UFPlan; let local: UFLocalTrial.State?
                     let servicePlan: String?; let serviceTrial: Bool; let plan: UFPlan; let ai: StudiNowAIAccess }
        let rows: [Row] = [
            Row(name: "Free", service: nil, purchased: .free, local: over, servicePlan: "free", serviceTrial: false, plan: .free, ai: .planRequired),
            Row(name: "Probe iPad", service: nil, purchased: .free, local: running, servicePlan: nil, serviceTrial: false, plan: .proAI, ai: .ready),
            Row(name: "Plus", service: nil, purchased: .plus, local: over, servicePlan: "plus", serviceTrial: false, plan: .plus, ai: .planRequired),
            Row(name: "Pro AI", service: nil, purchased: .proAI, local: over, servicePlan: "pro_ai", serviceTrial: false, plan: .proAI, ai: .ready),
            Row(name: "Probe iPad + Plus", service: nil, purchased: .plus, local: running, servicePlan: "plus", serviceTrial: false, plan: .plus, ai: .planRequired),
            Row(name: "Probe Konto", service: .proAI, purchased: .free, local: over, servicePlan: "pro_ai", serviceTrial: true, plan: .proAI, ai: .ready),
            Row(name: "Probe Konto + Plus", service: .proAI, purchased: .plus, local: over, servicePlan: "pro_ai", serviceTrial: true, plan: .proAI, ai: .ready),
        ]
        for r in rows {
            let plan = UFPlanPrecedence.effective(service: r.service, purchased: r.purchased, localTrial: r.local)
            XCTAssertEqual(plan, r.plan, r.name)
            XCTAssertEqual(UFFeatureMatrix.access(.pencilWriting, plan: plan).isAllowed, plan >= .plus, r.name)
            XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: plan).isAllowed, plan >= .plus, r.name)
            XCTAssertEqual(UFFeatureMatrix.access(.aiHelp, plan: plan).isAllowed, plan == .proAI, r.name)
            XCTAssertEqual(StudiNowAIAccess.decide(serviceConfigured: true, signedIn: true, localPlan: plan.rawValue,
                                                   servicePlan: r.servicePlan, serviceTrialActive: r.serviceTrial), r.ai, r.name)
        }
        // Plus ohne Probe: nie KI, auch nicht ohne Antwort des Dienstes
        XCTAssertEqual(StudiNowAIAccess.decide(serviceConfigured: true, signedIn: true, localPlan: "plus", servicePlan: nil,
                                               serviceTrialActive: false), .planRequired)
        XCTAssertEqual(StudiNowAIAccess.decide(serviceConfigured: true, signedIn: false, localPlan: "plus", servicePlan: nil,
                                               serviceTrialActive: false), .planRequired)
        // Pro AI ohne Anmeldung: Hinweis zur Anmeldung, nichts geht an den Dienst
        XCTAssertEqual(StudiNowAIAccess.decide(serviceConfigured: true, signedIn: false, localPlan: "pro_ai", servicePlan: nil,
                                               serviceTrialActive: false), .signInRequired)
    }

    /// Beschriftung in den Einstellungen und der Seitenleiste je Stand (iPad ohne Kauf; Kaeufe in PurchaseTests)
    func testStatusLabelPerState() {
        let e = Entitlements(observe: false)
        XCTAssertEqual(e.statusLabel, "StudiNow Free")
        e.useLocalTrial(startedAt: t0, now: day(1))
        XCTAssertEqual(e.statusLabel, "Probe: noch 6 Tage alles frei")
        XCTAssertEqual(UFSidebarProfile.make(e).planLabel, "Probe · noch 6 Tage")
        // Probe des Kontos (Dienst): deren Resttage ueberall, auch in Einstellungen und Seitenleiste (Entscheidung des
        // Inhabers 09.11.2026, TrialDisplayAppTests); ohne gemeldete Resttage der Tarif
        e.useServiceTrial(.proAI, daysLeft: 2)
        XCTAssertEqual(e.statusLabel, "Probe: noch 2 Tage alles frei")
        XCTAssertEqual(UFSidebarProfile.make(e).planLabel, "Probe · noch 2 Tage")
        e.useServiceTrial(.proAI)
        XCTAssertEqual(e.statusLabel, "StudiNow Pro AI")
        e.useServiceTrial(nil)
        e.useLocalTrial(startedAt: nil)
    }
}

/// Abo-Ablauf bei offener App und Kulanzfrist in der StoreKit-Testsitzung
@MainActor
final class PurchaseP44Tests: StoreKitSessionTestCase {
    /// P44-11: gekuendigtes Abo laeuft bei offener App ab. Apple schickt dafuer keine neue Transaktion
    /// (Transaction.updates bleibt still); vorher blieb Plus bis zum naechsten Kauf, Neustart oder Wiederherstellen
    func testCancelledSubscriptionEndsWhileTheAppStaysOpen() async throws {
        session.timeRate = .oneRenewalEveryTenSeconds
        defer { session.timeRate = .realTime }
        let (_, quiet) = await makeStore()
        _ = quiet
        // wie in der App: Entitlements beobachtet Transaction.updates
        let ent = Entitlements(observe: true)
        let store = PurchaseStore(entitlements: ent, productIDs: Self.productIDs)
        await store.loadProducts()
        await waitForPlan(ent, .free)
        let plus = try XCTUnwrap(store.product(for: .plus))
        let outcome = await store.purchase(plus)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        XCTAssertEqual(ent.plan, .plus)
        for t in session.allTransactions() where t.productIdentifier == plus.id {
            try session.disableAutoRenewForTransaction(identifier: t.identifier)
        }
        _ = await eventually(5) { await ent.refresh(); return ent.willRenew == false }
        XCTAssertEqual(ent.willRenew, false, "gekuendigt")
        let expires = try XCTUnwrap(ent.expiresAt)
        // kein Aufruf von refresh() mehr: die App bleibt offen
        let deadline = max(expires, Date()).addingTimeInterval(15)
        while Date() < deadline, ent.plan != .free { try? await Task.sleep(nanoseconds: 300_000_000) }
        XCTAssertEqual(ent.plan, .free, "Ablauf bei offener App: Free ohne Neustart (Ablauf \(expires))")
        XCTAssertFalse(ent.allows(.pencilWriting))
        XCTAssertEqual(ent.notes, UFNoteAccess(canView: true, canExport: true, canEdit: false), "nichts wird geloescht")
    }

    /// P44-14: Zahlung bei der Verlaengerung scheitert, Kulanzfrist (Billing Grace Period) laeuft: Apple zaehlt das Abo
    /// weiter (currentEntitlements, Status inGracePeriod), die App auch. Im App Store bleibt dabei `expiresDate` der
    /// Transaktion das Ende des bezahlten Zeitraums (vorbei, Ende der Frist in `gracePeriodExpirationDate`); vorher
    /// nahm die App deshalb Free an. Die StoreKit-Testsitzung verschiebt das Ablaufdatum in der Frist (gemessen
    /// 08.11.2026; mit schneller Zeit meldet sie gar keine Frist), darum ist die Regel selbst rot/gruen in
    /// `testResolverHonoursGracePeriod`, hier nur der Weg ueber StoreKit
    func testBillingGracePeriodKeepsThePlan() async throws {
        session.billingGracePeriodIsEnabled = true
        session.shouldEnterBillingRetryOnRenewal = true
        defer { session.billingGracePeriodIsEnabled = false; session.shouldEnterBillingRetryOnRenewal = false }
        let (store, ent) = await makeStore()
        let plus = try XCTUnwrap(store.product(for: .plus))
        let outcome = await store.purchase(plus)
        XCTAssertEqual(outcome, .success, store.lastError ?? "")
        try session.forceRenewalOfSubscription(productIdentifier: plus.id)
        let inGrace = await eventually(20) {
            guard let s = try? await plus.subscription?.status.first else { return false }
            return s.state == .inGracePeriod
        }
        XCTAssertTrue(inGrace, "Apple meldet die Kulanzfrist")
        await ent.refresh()
        XCTAssertEqual(ent.plan, .plus, "Kulanzfrist: Plus bleibt")
        XCTAssertTrue(ent.allows(.pencilWriting))
    }

    /// reine Regel: abgelaufenes Ablaufdatum gilt nur mit laufender Kulanzfrist; Erstattung und Upgrade nie
    func testResolverHonoursGracePeriod() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var e = UFEntitlementEntry(productID: "de.uniflow.plus.monthly", expirationDate: now.addingTimeInterval(-60))
        XCTAssertEqual(UFEntitlementResolver.plan(from: [e], now: now), .free)
        e.graceUntil = now.addingTimeInterval(86_400)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [e], now: now), .plus)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [e], now: now.addingTimeInterval(86_400)), .free, "Kulanzfrist vorbei")
        var refunded = e
        refunded.revocationDate = now
        XCTAssertEqual(UFEntitlementResolver.plan(from: [refunded], now: now), .free)
        var upgraded = e
        upgraded.isUpgraded = true
        XCTAssertEqual(UFEntitlementResolver.plan(from: [upgraded], now: now), .free)
        XCTAssertEqual(UFEntitlementResolver.rightsEnd(e), e.graceUntil)
        XCTAssertEqual(UFEntitlementResolver.rightsEnd(UFEntitlementEntry(productID: "x", expirationDate: now)), now)
    }
}
