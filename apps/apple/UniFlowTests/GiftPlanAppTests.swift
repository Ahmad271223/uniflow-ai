import UniFlowCore
import XCTest
@testable import UniFlow

/// Geschenkter Tarif (Auftrag des Inhabers 18.11.2026, Dienst: Quelle `gift`, app/tarif_schenken.py): die Apple-App
/// uebernimmt einen geschenkten Tarif wie die Probe des Dienstes (hoechster aus Dienst und Kauf), zeigt ihn als Tarif
/// ohne "Probe" und ohne Kauf-Druck und haelt den zuletzt bestaetigten Stand ohne Netz bis zu 30 Tage. Stripe- oder
/// Web-Abos uebernimmt sie nicht. Schein-Dienst, nie ins Netz.
@MainActor
final class GiftPlanAppTests: XCTestCase {
    private typealias Status = StudoraAccount.PlanStatus

    override func tearDown() async throws {
        Entitlements.shared.useServiceStatus(nil, gift: nil)
        try await super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "gift-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private static func day(_ s: String) -> Date { StudoraAccount.serviceDate(s)! }

    // MARK: Vorrang

    func testPrecedenceHighestOfServiceAndPurchaseWins() {
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, gift: .proAI, purchased: .free, localTrial: nil), .proAI)
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, gift: .plus, purchased: .proAI, localTrial: nil), .proAI,
                       "gekauftes Pro AI bleibt neben geschenktem Plus")
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, gift: .proAI, purchased: .plus, localTrial: nil), .proAI,
                       "geschenktes Pro AI ueber gekauftem Plus; das Apple-Abo bleibt unberuehrt")
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, gift: .plus, purchased: .free, localTrial: nil), .plus)
        XCTAssertEqual(UFPlanPrecedence.effective(service: .proAI, gift: .plus, purchased: .free, localTrial: nil), .proAI)
        let running = UFLocalTrial.state(startedAt: Date(), now: Date())
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, gift: .plus, purchased: .free, localTrial: running), .plus,
                       "geschenktes Plus wie gekauftes Plus: die iPad-Probe zaehlt daneben nicht")
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, gift: nil, purchased: .free, localTrial: running), .plus, "Probe wie Plus (26.11.2026)")
    }

    // MARK: An und aus

    func testGiftOnAndOffWithFullProAIScope() {
        let e = Entitlements(observe: false)
        XCTAssertEqual(e.plan, .free)
        e.useServiceStatus(Status(plan: "pro_ai", paidPlan: "pro_ai", giftPlan: "pro_ai"))
        XCTAssertEqual(e.plan, .proAI)
        XCTAssertEqual(e.statusLabel, "StudiNow Pro AI", "ohne Probe, ohne Ablaufdatum")
        XCTAssertNil(e.shownTrial)
        XCTAssertEqual(e.ownedPlan, .proAI)
        XCTAssertEqual(e.carryingGift, UFServiceGift(plan: .proAI, endsAt: nil))
        for f in [UFFeature.pencilWriting, .flashcards, .communityRead, .aiHelp, .aiFlashcards, .weeklyTests, .deviceSync, .dueReminders] {
            XCTAssertTrue(e.allows(f), "\(f)")
        }
        XCTAssertEqual(DeviceRule.shown(server: .blocked, localPlan: e.plan.rawValue), .ok, "Geraete-Regel wie bei Pro AI")
        // zurueckgenommen: der Dienst meldet kein Geschenk mehr
        e.useServiceStatus(Status(plan: "free"))
        XCTAssertEqual(e.plan, .free)
        XCTAssertEqual(e.statusLabel, "StudiNow Free")
        XCTAssertNil(e.carryingGift)
        XCTAssertFalse(e.allows(.pencilWriting))
    }

    func testStripeOrWebPlanIsNotAdopted() {
        let e = Entitlements(observe: false)
        e.useServiceStatus(Status(plan: "pro_ai", paidPlan: "pro_ai"))
        XCTAssertEqual(e.plan, .free, "nur ein Geschenk, kein anderer Tarif des Dienstes")
    }

    func testDatedGiftShowsUntilAndEnds() {
        let e = Entitlements(observe: false)
        let end = Date().addingTimeInterval(3 * 86_400)
        e.useServiceStatus(Status(plan: "pro_ai", paidPlan: "pro_ai", giftPlan: "pro_ai", giftEndsAt: end))
        let shown = end.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(Locale(identifier: "de_DE")))
        XCTAssertEqual(e.statusLabel, "StudiNow Pro AI bis \(shown)")
        // vorbei (Wecker bzw. Vordergrund rechnen neu): wieder Free
        e.useServiceStatus(nil, gift: UFServiceGift(plan: .proAI, endsAt: Date().addingTimeInterval(-60)))
        XCTAssertEqual(e.plan, .free)
        XCTAssertNil(e.activeGift())
        XCTAssertEqual(UFPlanExpiry.next(localTrial: nil, rightsEnd: nil, giftEnd: end, now: Date()), end)
    }

    func testGiftHidesTheTrialDisplays() {
        let e = Entitlements(observe: false)
        let now = Date()
        e.useLocalTrial(startedAt: now.addingTimeInterval(-86_400), now: now)
        XCTAssertNotNil(e.shownTrial, "Probe auf dem iPad laeuft")
        e.useServiceStatus(Status(plan: "pro_ai", paidPlan: "pro_ai", giftPlan: "pro_ai"))
        XCTAssertNil(e.shownTrial, "Geschenk ersetzt die Probe-Anzeige")
        XCTAssertEqual(e.statusLabel, "StudiNow Pro AI")
        // Probe des Kontos laeuft noch, Pro AI geschenkt: keine Probe-Anzeige
        e.useServiceStatus(Status(plan: "pro_ai", trialActive: true, trialDaysLeft: 5, trialPlan: "pro_ai", paidPlan: "pro_ai", giftPlan: "pro_ai"))
        XCTAssertNil(e.shownTrial)
        // nach der iPad-Probe: kein Hinweis "Probe vorbei", das Geschenk gilt wie ein Kauf
        e.useLocalTrial(startedAt: now.addingTimeInterval(-30 * 86_400), now: now)
        e.useServiceStatus(nil, gift: UFServiceGift(plan: .proAI, endsAt: nil))
        XCTAssertNil(TrialBanner.content(ent: e, service: nil))
        XCTAssertFalse(UFTrialDecision.required(local: e.localTrial, purchased: e.purchasedPlan, effective: e.plan, choiceMade: false))
    }

    // MARK: Tarifseite

    func testPlanPageShowsTheGiftWithoutPurchasePressure() {
        let g = UFServiceGift(plan: .proAI, endsAt: nil)!
        XCTAssertEqual(PlanPickerView.giftStatus(g).title, "Geschenkt: alle Funktionen von StudiNow Pro AI, unbefristet")
        XCTAssertFalse(PlanPickerView.giftStatus(g).note.contains("Probe"))
        let dated = UFServiceGift(plan: .proAI, endsAt: Self.day("2027-12-31T12:00:00Z"))!
        XCTAssertEqual(PlanPickerView.giftStatus(dated).title, "Geschenkt: alle Funktionen von StudiNow Pro AI bis 31.12.2027")
        XCTAssertTrue(PlanPickerView.coveredByGift(.proAI, gift: g))
        XCTAssertTrue(PlanPickerView.coveredByGift(.plus, gift: g), "kein Kaufknopf unter dem Geschenk")
        XCTAssertFalse(PlanPickerView.coveredByGift(.free, gift: g))
        let plus = UFServiceGift(plan: .plus, endsAt: nil)!
        XCTAssertFalse(PlanPickerView.coveredByGift(.proAI, gift: plus), "ein hoeherer Tarif bleibt kaufbar")
        XCTAssertFalse(PlanPickerView.coveredByGift(.proAI, gift: nil))
        XCTAssertTrue(PlanPickerView.isCurrent(.proAI, purchased: .proAI, loading: false, trial: false), "Aktueller Tarif (ownedPlan)")
        let e = Entitlements(observe: false)
        e.useServiceStatus(Status(plan: "pro_ai", paidPlan: "pro_ai", giftPlan: "pro_ai"))
        XCTAssertTrue(UFPlanCatalog.cards(current: e.ownedPlan, loaded: []).contains(.proAI), "die Karte des Geschenks fehlt nie")
    }

    // MARK: Ohne Netz

    func testMemoryKeepsTheGiftThirtyDaysAndNeverPastItsEnd() {
        let m = UFGiftMemory(defaults: defaults())
        let t0 = Self.day("2026-11-18T10:00:00Z")
        m.save(UFServiceGift(plan: .proAI, endsAt: nil), scope: "s", now: t0)
        XCTAssertEqual(m.load(scope: "s", now: t0.addingTimeInterval(29 * 86_400))?.plan, .proAI)
        XCTAssertNil(m.load(scope: "s", now: t0.addingTimeInterval(31 * 86_400)), "nach 30 Tagen ohne Dienst nicht mehr")
        XCTAssertNil(m.load(scope: "s", now: t0.addingTimeInterval(-3 * 86_400)), "Uhr zurueckgestellt: gilt nicht")
        XCTAssertNil(m.load(scope: "anderer", now: t0), "je Apple-Nutzer")
        m.save(UFServiceGift(plan: .plus, endsAt: t0.addingTimeInterval(2 * 86_400)), scope: "s", now: t0)
        XCTAssertEqual(m.load(scope: "s", now: t0.addingTimeInterval(86_400))?.plan, .plus)
        XCTAssertNil(m.load(scope: "s", now: t0.addingTimeInterval(3 * 86_400)), "nie ueber das Ende des Geschenks")
        m.save(nil, scope: "s", now: t0)
        XCTAssertNil(m.entry(scope: "s"), "Antwort ohne Geschenk loescht den Merker")
    }

    /// Schein-Dienst: feste Antworten je Methode + Pfad oder ganz ohne Netz
    final class Stub: ServiceHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: (Int, JSONValue)] = [:]
        private var offline = false
        func on(_ method: String, _ path: String, _ status: Int, _ body: JSONValue) { lock.withLock { replies["\(method) \(path)"] = (status, body) } }
        func goOffline() { lock.withLock { offline = true } }
        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            let path = String(r.url.dropFirst("https://dienst.example".count))
            return try lock.withLock {
                if offline { throw URLError(.notConnectedToInternet) }
                guard let (status, body) = replies["\(r.method) \(path)"] else { return ServiceHTTPResponse(status: 404, body: Data()) }
                return ServiceHTTPResponse(status: status, body: body.serialized())
            }
        }
    }

    final class Tokens: AccountTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        init(_ t: String?) { token = t }
        func load() -> String? { lock.withLock { token } }
        func save(_ t: String?) throws { lock.withLock { token = t } }
    }

    private func link(_ stub: Stub, memory: UFGiftMemory, scope: String) -> StudoraAccountLink {
        let l = StudoraAccountLink(entitlements: Entitlements(observe: false))
        l.giftMemory = memory
        l.attachForTesting(account: StudoraAccount(base: "https://dienst.example", http: stub, tokens: Tokens("tok"),
                                                   deviceID: "ipad-gift", deviceName: "iPad"), scope: scope)
        return l
    }

    func testLinkAdoptsTheGiftAndKeepsItOfflineUntilSignOut() async throws {
        let memory = UFGiftMemory(defaults: defaults())
        let scope = "gift-\(UUID().uuidString)"
        let online = Stub()
        online.on("GET", "/api/account/me", 200, ["user": ["id": "0123456789abcdef0123456789abcdef", "email": "tester@beispiel.de",
                                                           "email_verified": true, "university": "luh", "plan": "free", "role": "user"],
                                                  "sessions": []])
        online.on("GET", "/api/entitlements", 200, ["plan": "pro_ai", "source": "gift", "expires_at": .null, "will_renew": false,
                                                    "paid_plan": "pro_ai", "trial": ["active": false],
                                                    "gift": ["active": true, "plan": "pro_ai", "ends_at": .null]])
        let a = link(online, memory: memory, scope: scope)
        await a.refresh()
        XCTAssertEqual(a.planStatus?.giftPlan, "pro_ai")
        XCTAssertEqual(Entitlements.shared.plan, .proAI)
        XCTAssertEqual(Entitlements.shared.statusLabel, "StudiNow Pro AI")
        XCTAssertEqual(memory.entry(scope: scope)?.plan, "pro_ai")

        // neuer Start ohne Netz: der gemerkte Stand gilt
        Entitlements.shared.useServiceStatus(nil, gift: nil)
        XCTAssertEqual(Entitlements.shared.plan, .free)
        let offline = Stub()
        offline.goOffline()
        let b = link(offline, memory: memory, scope: scope)
        b.clearPlanStatusForTesting()
        await b.refresh()
        XCTAssertNil(b.planStatus)
        XCTAssertEqual(Entitlements.shared.plan, .proAI, "ohne Netz bleibt das Geschenk")

        // Abmelden vergisst es
        await b.logout()
        XCTAssertNil(memory.entry(scope: scope))
        XCTAssertEqual(Entitlements.shared.plan, .free)
    }

    func testServiceAnswerWithoutGiftEndsItAtOnce() async throws {
        let memory = UFGiftMemory(defaults: defaults())
        let scope = "gift-\(UUID().uuidString)"
        memory.save(UFServiceGift(plan: .proAI, endsAt: nil), scope: scope)
        let s = Stub()
        s.on("GET", "/api/account/me", 200, ["user": ["id": "0123456789abcdef0123456789abcdef", "email": "tester@beispiel.de",
                                                      "email_verified": true, "university": "luh", "plan": "free", "role": "user"],
                                             "sessions": []])
        s.on("GET", "/api/entitlements", 200, ["plan": "free", "source": .null, "gift": .null, "trial": ["active": false]])
        let l = link(s, memory: memory, scope: scope)
        l.clearPlanStatusForTesting()
        XCTAssertEqual(Entitlements.shared.plan, .proAI, "bis zur Antwort der gemerkte Stand")
        await l.refresh()
        XCTAssertEqual(Entitlements.shared.plan, .free, "zurueckgenommen: die Antwort gilt sofort")
        XCTAssertNil(memory.entry(scope: scope))
    }
}
