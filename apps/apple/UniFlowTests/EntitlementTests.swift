import StoreKit
import XCTest
@testable import UniFlow

/// Zuordnung Produkt -> Tarif -> Funktion (Abschnitt 4), Herabstufen und Angebotstexte (Abschnitt 5) ohne StoreKit.
final class EntitlementTests: XCTestCase {

    func testProductToPlan() {
        // drei Tarife (Entscheidung 04.11.2026, plans.json), Rohwerte wie im Vertrag; Pro Connect gilt wie Pro AI
        XCTAssertEqual(UFPlan.allCases, [.free, .plus, .proAI])
        XCTAssertEqual(UFPlan.allCases.map(\.rawValue), ["free", "plus", "pro_ai"])
        XCTAssertEqual(UFPlan(productID: "de.uniflow.plus.monthly"), .plus)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.proconnect.monthly"), .proAI, "altes Pro-Connect-Produkt gilt wie Pro AI")
        XCTAssertEqual(UFPlan(productID: "de.uniflow.proai.monthly"), .proAI)
        XCTAssertEqual(UFPlan(rawValue: "pro_connect"), .proAI, "alter Schluessel gilt wie Pro AI")
        XCTAssertNil(UFPlan(rawValue: "pro"))
        // das fruehere Pro-Produkt (bis 25.10.2026) gibt keinen Tarif
        XCTAssertNil(UFPlan(productID: "de.uniflow.pro.monthly"))
        XCTAssertNil(UFPlan(productID: "fremd"))
        XCTAssertNil(UFPlan.free.productID)
        // das iPad bietet Plus und Pro AI an (UFPlanCatalog.sellable, Entscheidung 04.11.2026), seit 09.11.2026 nur als
        // Jahresabo; die frueheren Monatsprodukte oben gelten weiter wie ihr Tarif
        XCTAssertEqual(PurchaseStore.productIDs, ["de.uniflow.plus.yearly", "de.uniflow.proai.yearly"])
        XCTAssertEqual(UFPlan.paid, [.plus, .proAI])
        XCTAssertLessThan(UFPlan.free, .plus)
        XCTAssertLessThan(UFPlan.plus, .proAI)
        XCTAssertEqual(UFPlan.allCases.map(\.lower), [nil, .free, .plus])
        XCTAssertEqual(UFPlan.allCases.map(\.name), ["StudiNow Free", "StudiNow Plus", "StudiNow Pro AI"])
    }

    /// Free: planen (Lernplanung), Dokumente oeffnen, Faecher geordnet sehen und der Rest des Uni-Alltags
    func testMatrixFree() {
        for f: UFFeature in [.studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .studyPlanning, .timer, .viewNotes] {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .free), .allowed, f.rawValue)
        }
        for f: UFFeature in [.pencilWriting, .splitView] {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .free), .locked(.plus), f.rawValue)
        }
        // eigene Karteikarten gibt es auf dem Geraet (M8): Plus, in Free das Schloss mit Weg zur Abo-Seite
        XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: .free), .locked(.plus))
        XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: .free, flashcards: false), .comingSoon, "Schalter bleibt pruefbar")
        XCTAssertEqual(UFFeatureMatrix.access(.shareSolutions, plan: .free), .locked(.plus), "Lösung teilen: Schloss mit Weg zur Abo-Seite")
        XCTAssertEqual(UFFeatureMatrix.access(.communityRead, plan: .free), .locked(.plus), "Community ab Plus (05.11.2026)")
        // Uni & Noten liegt ausserhalb der Tarife: sobald nativ vorhanden, gleich in Free
        XCTAssertEqual(UFFeatureMatrix.access(.uniGrades, plan: .free, uniGrades: true), .allowed)
    }

    func testMatrixPlus() {
        for f: UFFeature in [.pencilWriting, .splitView, .studyPlanning, .readDocuments] {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .plus), .allowed, f.rawValue)
        }
        XCTAssertEqual(UFFeatureMatrix.access(.shareSolutions, plan: .plus, community: true), .allowed)
        XCTAssertEqual(UFFeatureMatrix.access(.communityRead, plan: .plus, community: true), .allowed)
        // Plus-Karte fuehrt Karteikarten als enthalten, ohne "bald" (Anlegen, Wiederholen und Loeschen auf dem Geraet)
        XCTAssertTrue(UFFeatureMatrix.flashcardsOnDevice)
        XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: .plus), .allowed)
        XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: .plus, flashcards: false), .comingSoon)
        XCTAssertFalse(UFFeatureMatrix.added(in: .plus).contains { !$0.isV2 && UFFeatureMatrix.access($0, plan: .plus) == .comingSoon },
                       "keine Zeile der Plus-Karte traegt \"bald\"")
        XCTAssertEqual(UFFeature.flashcards.detail, "Selbst angelegt, Wiederholung nach dem Leitner-System")
    }

    /// Uni & Noten ist auf dem Geraet da (QIS der LUH, LSF der Uni Hildesheim) und gehoert zu Free. Community lesen
    /// (finden, laden, ansehen, melden, blockieren, beitreten) gehoert seit 05.11.2026 zu Plus wie can_read_community
    /// (vorher Free, Entscheidung 28.10.2026), eigene Loesungen teilen zu Plus wie can_share_solutions.
    @MainActor
    func testUniGradesInFreeCommunityInPlus() {
        XCTAssertTrue(UFFeatureMatrix.uniGradesOnDevice)
        XCTAssertTrue(UFFeatureMatrix.communityAvailable)
        for p in UFPlan.allCases {
            XCTAssertEqual(UFFeatureMatrix.access(.uniGrades, plan: p), .allowed, p.rawValue)
            XCTAssertEqual(UFFeatureMatrix.access(.uniflowEditor, plan: p), .comingSoon)
            // Notizen-Abgleich: mit StudiNow-Konto ab Pro AI (07.11.2026, vorher "bald")
            XCTAssertEqual(UFFeatureMatrix.access(.deviceSync, plan: p), p == .proAI ? .allowed : .locked(.proAI))
        }
        // ohne Geraete-Funktion wieder "bald" (Schalter bleibt pruefbar)
        XCTAssertEqual(UFFeatureMatrix.access(.uniGrades, plan: .free, uniGrades: false), .comingSoon)
        XCTAssertEqual(UFFeatureMatrix.access(.shareSolutions, plan: .free), .locked(.plus))
        XCTAssertEqual(UFFeatureMatrix.access(.shareSolutions, plan: .plus), .allowed)
        XCTAssertEqual(UFFeatureMatrix.access(.communityRead, plan: .free), .locked(.plus))
        for p: UFPlan in [.plus, .proAI] { XCTAssertEqual(UFFeatureMatrix.access(.communityRead, plan: p), .allowed, p.rawValue) }
        XCTAssertEqual(UFFeature.communityRead.minimumPlan, .plus)
        XCTAssertEqual(UFEntitlement.canReadCommunity.from, .plus)
        // ohne Geraete-Funktion beides wieder "bald" (Schalter bleibt pruefbar)
        XCTAssertEqual(UFFeatureMatrix.access(.shareSolutions, plan: .plus, community: false), .comingSoon)
        XCTAssertEqual(UFFeatureMatrix.access(.communityRead, plan: .free, community: false), .comingSoon)
        XCTAssertTrue(Entitlements(observe: false, plan: .plus).allows(.uniGrades))
        XCTAssertTrue(Entitlements(observe: false, plan: .free).allows(.uniGrades))
        XCTAssertTrue(Entitlements(observe: false, plan: .plus).allows(.shareSolutions))
        XCTAssertFalse(Entitlements(observe: false, plan: .free).allows(.shareSolutions))
        XCTAssertFalse(Entitlements(observe: false, plan: .free).allows(.communityRead))
        XCTAssertTrue(Entitlements(observe: false, plan: .plus).allows(.communityRead))
        XCTAssertTrue(UFFeature.shareSolutions.detail?.contains("in der Community veröffentlichen") == true)
        XCTAssertTrue(UFFeature.communityRead.detail?.contains("melden und blockieren") == true)
        XCTAssertTrue(SolutionShareSheet.showsCommunityPublish(plan: .plus))
        XCTAssertFalse(SolutionShareSheet.showsCommunityPublish(plan: .free))
    }

    /// Plus bietet mehr als Free (Schreiben, Uebung und Skript, Loesung teilen), Pro AI mehr als Plus (StudiNow-KI und
    /// Notizen-Abgleich mit StudiNow-Konto, 07.11.2026)
    func testEveryPlanHasExtras() {
        XCTAssertTrue(UFFeatureMatrix.hasAvailableExtras(in: .free))
        XCTAssertTrue(UFFeatureMatrix.hasAvailableExtras(in: .plus))
        XCTAssertTrue(UFFeatureMatrix.hasAvailableExtras(in: .proAI))
    }

    func testDowngradeKeepsNotesReadableAndExportable() {
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .free), UFNoteAccess(canView: true, canExport: true, canEdit: false))
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .plus), UFNoteAccess(canView: true, canExport: true, canEdit: true))
    }

    /// Funktionen der Tarifkarten (Abschnitt 4): KI nur bei Pro AI (StudiNow-KI mit Konto, PlanContractTests)
    func testPlanCards() {
        XCTAssertEqual(UFFeatureMatrix.added(in: .free),
                       [.studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .studyPlanning, .viewNotes, .uniGrades, .ownChatGPT])
                       // Zeitmesser ausgeblendet (StudyTimer.isEnabled, 05.11.2026); Community ab Plus (05.11.2026);
                       // eigenes ChatGPT ueber den eigenen OpenAI-Schluessel in jedem Tarif (07.11.2026)
        XCTAssertEqual(UFFeatureMatrix.added(in: .plus).filter { !$0.isV2 },
                       [.pencilWriting, .communityRead, .shareSolutions, .splitView, .flashcards, .dueReminders, .autoPlan])
                       // Erinnerungen an Abgaben und Klausuren ab Plus (Entscheidung 11.11.2026)
        XCTAssertEqual(UFFeatureMatrix.added(in: .proAI), [.aiHelp, .aiFlashcards, .weeklyTests, .deviceSync])
        for f in UFFeature.allCases where f.minimumPlan < .proAI {
            XCTAssertFalse(f.title.contains("KI"), f.rawValue)
            XCTAssertFalse((f.detail ?? "").contains("KI"), f.rawValue)
        }
        for f in UFFeature.allCases where f != .ownChatGPT {
            XCTAssertFalse(f.title.contains("ChatGPT") || (f.detail ?? "").contains("ChatGPT"), f.rawValue)
        }
        XCTAssertEqual(UFFeature.ownChatGPT.title, "Eigenes ChatGPT verbinden")
    }

    // MARK: Tarif aus Transaktionen

    func testResolverPicksHighestActive() {
        let now = Date()
        let later = now.addingTimeInterval(3600), earlier = now.addingTimeInterval(-3600)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [], now: now), .free)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [.init(productID: "de.uniflow.plus.monthly", expirationDate: later)], now: now), .plus)
        // abgelaufen, erstattet, ersetzt oder fremd (auch das fruehere Pro) -> zaehlt nicht
        XCTAssertEqual(UFEntitlementResolver.plan(from: [
            .init(productID: "de.uniflow.plus.monthly", expirationDate: earlier),
            .init(productID: "de.uniflow.plus.monthly", expirationDate: later, revocationDate: earlier),
            .init(productID: "de.uniflow.plus.monthly", expirationDate: later, isUpgraded: true),
            .init(productID: "de.uniflow.pro.monthly", expirationDate: later),
            .init(productID: "fremd", expirationDate: later),
        ], now: now), .free)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [
            .init(productID: "de.uniflow.plus.monthly", expirationDate: earlier),
            .init(productID: "de.uniflow.plus.monthly", expirationDate: later),
        ], now: now), .plus)
        // hoechster gueltiger Tarif gilt, gleich in welcher Reihenfolge
        XCTAssertEqual(UFEntitlementResolver.plan(from: [
            .init(productID: "de.uniflow.proai.monthly", expirationDate: later),
            .init(productID: "de.uniflow.plus.monthly", expirationDate: later),
            .init(productID: "de.uniflow.proconnect.monthly", expirationDate: later),
        ], now: now), .proAI)
        // abgelaufenes Pro AI, gueltiges altes Pro Connect -> Pro AI (alter Tarif gilt wie Pro AI); durch Upgrade
        // ersetztes Plus zaehlt nicht
        XCTAssertEqual(UFEntitlementResolver.plan(from: [
            .init(productID: "de.uniflow.proai.monthly", expirationDate: earlier),
            .init(productID: "de.uniflow.proconnect.monthly", expirationDate: later),
        ], now: now), .proAI)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [
            .init(productID: "de.uniflow.plus.monthly", expirationDate: later, isUpgraded: true),
            .init(productID: "de.uniflow.proai.monthly", expirationDate: later),
        ], now: now), .proAI)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [
            .init(productID: "de.uniflow.proai.monthly", expirationDate: later, revocationDate: earlier),
            .init(productID: "de.uniflow.plus.monthly", expirationDate: later),
        ], now: now), .plus, "erstattetes Pro AI faellt auf das gueltige Plus zurueck")
    }

    /// Vorgemerkter Wechsel aus der RenewalInfo: nur ein anderes, bekanntes Produkt, das sich verlaengert
    func testPendingPlanFromRenewalInfo() {
        XCTAssertEqual(UFEntitlementResolver.pendingPlan(current: .proAI, willAutoRenew: true, autoRenewProductID: "de.uniflow.plus.monthly"), .plus)
        XCTAssertNil(UFEntitlementResolver.pendingPlan(current: .proAI, willAutoRenew: true, autoRenewProductID: "de.uniflow.proai.monthly"))
        XCTAssertNil(UFEntitlementResolver.pendingPlan(current: .proAI, willAutoRenew: false, autoRenewProductID: "de.uniflow.plus.monthly"),
                     "gekuendigt: kein Wechsel, der Tarif endet")
        XCTAssertNil(UFEntitlementResolver.pendingPlan(current: .plus, willAutoRenew: true, autoRenewProductID: "de.uniflow.pro.monthly"))
        XCTAssertNil(UFEntitlementResolver.pendingPlan(current: .plus, willAutoRenew: true, autoRenewProductID: nil))
        XCTAssertNil(UFEntitlementResolver.pendingPlan(current: .free, willAutoRenew: true, autoRenewProductID: "de.uniflow.plus.monthly"))
    }

    /// gekuendigtes Abo: Zugang endet mit dem Zeitraum, danach Free (kein Einfuehrungsangebot mehr, 04.11.2026)
    func testSubscriptionEndsWithItsPeriod() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(30 * 86_400)
        let sub = UFEntitlementEntry(productID: "de.uniflow.plus.monthly", expirationDate: end)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [sub], now: start), .plus)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [sub], now: end), .free)
    }

    @MainActor
    func testEntitlementsObjectUsesMatrix() {
        let ent = Entitlements(observe: false, plan: .free)
        XCTAssertFalse(ent.loading)
        XCTAssertEqual(ent.access(.splitView), .locked(.plus))
        XCTAssertEqual(ent.access(.flashcards), .locked(.plus))
        XCTAssertEqual(ent.access(.weeklyTests), .locked(.proAI), "Wochentest erstellen ohne PC: braucht die StudiNow-KI (Pro AI)")
        XCTAssertTrue(UFLockedCard.message(.flashcards, access: ent.access(.flashcards)).contains("Enthalten ab StudiNow Plus."))
        XCTAssertFalse(UFLockedCard.message(.flashcards, access: ent.access(.flashcards)).contains("Bald"))
        XCTAssertTrue(ent.allows(.studyPlanning), "Lernplanung gehoert zu Free")
        ent.setPlanForTesting(.plus)
        XCTAssertTrue(ent.allows(.splitView))
        XCTAssertTrue(ent.allows(.flashcards), "mit Plus frei")
        XCTAssertTrue(UFLockedCard.message(.flashcards, access: .comingSoon).contains("Bald verfügbar"), "Sperrkarte kennt \"bald\" weiter")
        let locked = UFLockedCard.message(.pencilWriting, access: .locked(.plus))
        XCTAssertTrue(locked.contains("Enthalten ab StudiNow Plus."))
        XCTAssertFalse(locked.contains("Pro"))
        XCTAssertEqual(ent.access(.pencilWriting).requiredPlan, nil, "mit Plus frei")
        XCTAssertEqual(UFAccess.locked(.plus).requiredPlan, .plus)
        // Pro AI: alles aus Plus frei
        ent.setPlanForTesting(.proAI)
        XCTAssertTrue(ent.allows(.pencilWriting))
        XCTAssertTrue(ent.allows(.flashcards))
        XCTAssertTrue(ent.allows(.weeklyTests))
        XCTAssertTrue(ent.allows(.shareSolutions))
        XCTAssertTrue(ent.allows(.splitView))
        // Uni & Noten ist da (QIS bzw. LSF auf dem Geraet) und in jedem Tarif frei; die Sperrkarte kennt "bald" weiter
        XCTAssertEqual(ent.access(.uniGrades), .allowed)
        let soon = UFLockedCard.message(.uniGrades, access: .comingSoon)
        XCTAssertFalse(soon.contains("Enthalten in"))
        XCTAssertTrue(soon.contains("Bald verfügbar"))
        // Teilen und Lesen in Free: Schloss, "Enthalten ab StudiNow Plus" bzw. "Community ab StudiNow Plus"
        let free = Entitlements(observe: false, plan: .free)
        XCTAssertTrue(UFLockedCard.message(.shareSolutions, access: free.access(.shareSolutions)).contains("Enthalten ab StudiNow Plus."))
        XCTAssertEqual(free.access(.shareSolutions).requiredPlan, .plus)
        XCTAssertEqual(free.access(.communityRead).requiredPlan, .plus)
        let teaser = UFLockedCard.message(.communityRead, access: free.access(.communityRead))
        XCTAssertTrue(teaser.hasPrefix("Community ab StudiNow Plus:"), teaser)
        XCTAssertTrue(teaser.contains("jederzeit zurückziehen"), "eigene Beitraege bleiben zurueckziehbar")
        XCTAssertTrue(UFLockedCard.message(.communityRead, access: .comingSoon).contains("die Community folgt mit einem Update"))
        // Menuepunkte gesperrter Funktionen im Editor
        XCTAssertEqual(DocumentView.lockedLabel("Lösung teilen …", .locked(.plus)), "Lösung teilen … (StudiNow Plus)")
        XCTAssertEqual(DocumentView.lockedLabel("Lösungen anderer ansehen", .comingSoon), "Lösungen anderer ansehen (bald)")
        XCTAssertEqual(DocumentView.lockedLabel("Lösung teilen …", .allowed), "Lösung teilen …")
    }

    // MARK: Angebotstexte (Richtlinie 3.1.2)

    func testOfferTexts() {
        let year = (1, Product.SubscriptionPeriod.Unit.year)
        // kein "1 Woche gratis, danach …" mehr (Entscheidung 04.11.2026): nur Preis, Zeitraum, Kuendigung; nur
        // Jahresabos (09.11.2026)
        XCTAssertEqual(UFOfferText.summary(price: "19,99 €", period: year),
                       "19,99 €/Jahr, verlängert sich jährlich, jederzeit zum Laufzeitende kündbar")
        XCTAssertEqual(UFOfferText.button(plan: .plus, price: "19,99 €", period: year), "StudiNow Plus für 19,99 €/Jahr")
        XCTAssertEqual(UFOfferText.button(plan: .proAI, price: "39,99 €", period: year), "StudiNow Pro AI für 39,99 €/Jahr")
        XCTAssertFalse(UFOfferText.summary(price: "19,99 €", period: year).contains("gratis"))
        XCTAssertEqual(UFTrialTexts.offer, "7 Tage Probe mit allem, danach Free – ohne Zahlungsdaten")
        XCTAssertEqual(UFTrialTexts.offerProAI, "7 Tage Probe: alles wie StudiNow Pro AI, mit 25 Credits für die StudiNow-KI, danach Free – ohne Zahlungsdaten")
        // Wechsel in der Abo-Gruppe: hoeher sofort, kleiner ab der naechsten Verlaengerung (regelt Apple)
        XCTAssertEqual(UFOfferText.switchButton(to: .proAI), "Zu StudiNow Pro AI wechseln")
        XCTAssertEqual(UFOfferText.switchNote(to: .proAI, from: .plus), "Gilt sofort. Apple verrechnet den bisherigen Tarif anteilig.")
        XCTAssertEqual(UFOfferText.switchNote(to: .plus, from: .proAI), "Gilt ab der nächsten Verlängerung, bis dahin bleibt StudiNow Pro AI.")
        let nov27 = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "Europe/Berlin"),
                                   year: 2026, month: 11, day: 27, hour: 12).date!
        XCTAssertEqual(UFOfferText.pendingNote(.plus, at: nov27), "Wechsel zu StudiNow Plus vorgemerkt ab 27. November.")
        XCTAssertEqual(UFOfferText.pendingNote(.plus, at: nil), "Wechsel zu StudiNow Plus zur nächsten Verlängerung vorgemerkt.")
        XCTAssertEqual(UFOfferText.cancelledNote(.proAI, endsAt: nov27),
                       "Gekündigt – StudiNow Pro AI endet am 27. November, danach gilt StudiNow Free.")
        XCTAssertEqual(UFOfferText.period(value: 2, unit: .week), "2 Wochen")
        XCTAssertEqual(UFOfferText.per(value: 1, unit: .year), "/Jahr")
        XCTAssertEqual(UFOfferText.per(value: 3, unit: .month), "/3 Monate")
        XCTAssertEqual(UFOfferText.cancelNote(value: 1, unit: .year), "verlängert sich jährlich, jederzeit zum Laufzeitende kündbar")
    }
}
