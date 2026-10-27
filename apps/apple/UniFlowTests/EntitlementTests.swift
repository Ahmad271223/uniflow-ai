import StoreKit
import XCTest
@testable import UniFlow

/// Zuordnung Produkt -> Tarif -> Funktion (Abschnitt 4), Herabstufen und Angebotstexte (Abschnitt 5) ohne StoreKit.
final class EntitlementTests: XCTestCase {

    func testProductToPlan() {
        // vier Tarife (Entscheidung 27.10.2026, plans.json), Rohwerte wie im Vertrag
        XCTAssertEqual(UFPlan.allCases, [.free, .plus, .proConnect, .proAI])
        XCTAssertEqual(UFPlan.allCases.map(\.rawValue), ["free", "plus", "pro_connect", "pro_ai"])
        XCTAssertEqual(UFPlan(productID: "de.uniflow.plus.monthly"), .plus)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.proconnect.monthly"), .proConnect)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.proai.monthly"), .proAI)
        // das fruehere Pro-Produkt (bis 25.10.2026) gibt keinen Tarif
        XCTAssertNil(UFPlan(productID: "de.uniflow.pro.monthly"))
        XCTAssertNil(UFPlan(productID: "fremd"))
        XCTAssertNil(UFPlan.free.productID)
        XCTAssertEqual(PurchaseStore.productIDs, ["de.uniflow.plus.monthly", "de.uniflow.proconnect.monthly", "de.uniflow.proai.monthly"])
        XCTAssertEqual(UFPlan.paid, [.plus, .proConnect, .proAI])
        XCTAssertLessThan(UFPlan.free, .plus)
        XCTAssertLessThan(UFPlan.plus, .proConnect)
        XCTAssertLessThan(UFPlan.proConnect, .proAI)
        XCTAssertEqual(UFPlan.allCases.map(\.lower), [nil, .free, .plus, .proConnect])
        XCTAssertEqual(UFPlan.allCases.map(\.name), ["Studora Free", "Studora Plus", "Studora Pro Connect", "Studora Pro AI"])
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
        XCTAssertEqual(UFFeatureMatrix.access(.community, plan: .free), .locked(.plus), "Lösung teilen: Schloss mit Weg zur Abo-Seite")
        // Uni & Noten liegt ausserhalb der Tarife: sobald nativ vorhanden, gleich in Free
        XCTAssertEqual(UFFeatureMatrix.access(.uniGrades, plan: .free, uniGrades: true), .allowed)
    }

    func testMatrixPlus() {
        for f: UFFeature in [.pencilWriting, .splitView, .studyPlanning, .readDocuments] {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .plus), .allowed, f.rawValue)
        }
        XCTAssertEqual(UFFeatureMatrix.access(.community, plan: .plus, community: true), .allowed)
        // Plus-Karte fuehrt Karteikarten als enthalten, ohne "bald" (Anlegen, Wiederholen und Loeschen auf dem Geraet)
        XCTAssertTrue(UFFeatureMatrix.flashcardsOnDevice)
        XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: .plus), .allowed)
        XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: .plus, flashcards: false), .comingSoon)
        XCTAssertFalse(UFFeatureMatrix.added(in: .plus).contains { !$0.isV2 && UFFeatureMatrix.access($0, plan: .plus) == .comingSoon },
                       "keine Zeile der Plus-Karte traegt \"bald\"")
        XCTAssertEqual(UFFeature.flashcards.detail, "Selbst angelegt, Wiederholung nach dem Leitner-System")
    }

    /// Uni & Noten ist auf dem Geraet da (QIS der LUH, LSF der Uni Hildesheim) und gehoert zu Free. Community laeuft
    /// auf dem Geraet (Loesung als Datei teilen und im Editor ansehen) und gehoert zu Plus; nur die Online-Community
    /// fehlt noch.
    @MainActor
    func testUniGradesInFreeCommunityInPlus() {
        XCTAssertTrue(UFFeatureMatrix.uniGradesOnDevice)
        XCTAssertTrue(UFFeatureMatrix.communityAvailable)
        for p in UFPlan.allCases {
            XCTAssertEqual(UFFeatureMatrix.access(.uniGrades, plan: p), .allowed, p.rawValue)
            XCTAssertEqual(UFFeatureMatrix.access(.uniflowEditor, plan: p), .comingSoon)
            XCTAssertEqual(UFFeatureMatrix.access(.deviceSync, plan: p), .comingSoon)
        }
        // ohne Geraete-Funktion wieder "bald" (Schalter bleibt pruefbar)
        XCTAssertEqual(UFFeatureMatrix.access(.uniGrades, plan: .free, uniGrades: false), .comingSoon)
        XCTAssertEqual(UFFeatureMatrix.access(.community, plan: .free), .locked(.plus))
        XCTAssertEqual(UFFeatureMatrix.access(.community, plan: .plus), .allowed)
        // ohne Geraete-Funktion wieder "bald" (Schalter bleibt pruefbar)
        XCTAssertEqual(UFFeatureMatrix.access(.community, plan: .plus, community: false), .comingSoon)
        XCTAssertTrue(Entitlements(observe: false, plan: .plus).allows(.uniGrades))
        XCTAssertTrue(Entitlements(observe: false, plan: .free).allows(.uniGrades))
        XCTAssertTrue(Entitlements(observe: false, plan: .plus).allows(.community))
        XCTAssertFalse(Entitlements(observe: false, plan: .free).allows(.community))
        XCTAssertTrue(UFFeature.community.detail?.contains("in der Community veröffentlichen") == true)
    }

    /// Plus bietet schon heute mehr als Free (Schreiben, Uebung und Skript, Loesung als Datei teilen); Pro Connect und
    /// Pro AI noch nicht mehr als Plus (ihre Funktionen brauchen den Dienst, die Karte sagt es offen)
    func testPlusHasExtras() {
        XCTAssertTrue(UFFeatureMatrix.hasAvailableExtras(in: .free))
        XCTAssertTrue(UFFeatureMatrix.hasAvailableExtras(in: .plus))
        XCTAssertFalse(UFFeatureMatrix.hasAvailableExtras(in: .proConnect))
        XCTAssertFalse(UFFeatureMatrix.hasAvailableExtras(in: .proAI))
    }

    func testDowngradeKeepsNotesReadableAndExportable() {
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .free), UFNoteAccess(canView: true, canExport: true, canEdit: false))
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .plus), UFNoteAccess(canView: true, canExport: true, canEdit: true))
    }

    /// Geraete-Funktionen der Tarifkarten (Abschnitt 4): keine davon ist KI (die Studora-KI braucht den Dienst und
    /// steht nur unter "in Vorbereitung", PlanContractTests)
    func testPlanCards() {
        XCTAssertEqual(UFFeatureMatrix.added(in: .free),
                       [.studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .studyPlanning, .timer, .viewNotes, .uniGrades])
        XCTAssertEqual(UFFeatureMatrix.added(in: .plus).filter { !$0.isV2 }, [.pencilWriting, .community, .splitView, .flashcards])
        XCTAssertEqual(UFFeatureMatrix.added(in: .proConnect), [])
        XCTAssertEqual(UFFeatureMatrix.added(in: .proAI), [])
        for f in UFFeature.allCases {
            XCTAssertFalse(f.title.contains("KI"), f.rawValue)
            XCTAssertFalse((f.detail ?? "").contains("KI"), f.rawValue)
        }
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
        // abgelaufenes Pro AI, gueltiges Pro Connect -> Pro Connect; durch Upgrade ersetztes Plus zaehlt nicht
        XCTAssertEqual(UFEntitlementResolver.plan(from: [
            .init(productID: "de.uniflow.proai.monthly", expirationDate: earlier),
            .init(productID: "de.uniflow.proconnect.monthly", expirationDate: later),
        ], now: now), .proConnect)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [
            .init(productID: "de.uniflow.plus.monthly", expirationDate: later, isUpgraded: true),
            .init(productID: "de.uniflow.proconnect.monthly", expirationDate: later),
        ], now: now), .proConnect)
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

    func testTrialEndsAfterWeek() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(7 * 86_400)
        let trial = UFEntitlementEntry(productID: "de.uniflow.plus.monthly", expirationDate: end, isIntroOffer: true)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [trial], now: start), .plus)
        XCTAssertTrue(UFEntitlementResolver.inIntroOffer([trial], plan: .plus, now: start))
        // gekuendigt: Zugang endet mit der Woche, danach Free
        XCTAssertEqual(UFEntitlementResolver.plan(from: [trial], now: end), .free)
        XCTAssertFalse(UFEntitlementResolver.inIntroOffer([trial], plan: .free, now: end))
    }

    @MainActor
    func testEntitlementsObjectUsesMatrix() {
        let ent = Entitlements(observe: false, plan: .free)
        XCTAssertFalse(ent.loading)
        XCTAssertEqual(ent.access(.splitView), .locked(.plus))
        XCTAssertEqual(ent.access(.flashcards), .locked(.plus))
        XCTAssertTrue(UFLockedCard.message(.flashcards, access: ent.access(.flashcards)).contains("Enthalten ab Studora Plus."))
        XCTAssertFalse(UFLockedCard.message(.flashcards, access: ent.access(.flashcards)).contains("Bald"))
        XCTAssertTrue(ent.allows(.studyPlanning), "Lernplanung gehoert zu Free")
        ent.setPlanForTesting(.plus)
        XCTAssertTrue(ent.allows(.splitView))
        XCTAssertTrue(ent.allows(.flashcards), "mit Plus frei")
        XCTAssertTrue(UFLockedCard.message(.flashcards, access: .comingSoon).contains("Bald verfügbar"), "Sperrkarte kennt \"bald\" weiter")
        let locked = UFLockedCard.message(.pencilWriting, access: .locked(.plus))
        XCTAssertTrue(locked.contains("Enthalten ab Studora Plus."))
        XCTAssertFalse(locked.contains("Pro"))
        XCTAssertEqual(ent.access(.pencilWriting).requiredPlan, nil, "mit Plus frei")
        XCTAssertEqual(UFAccess.locked(.plus).requiredPlan, .plus)
        // Pro Connect und Pro AI: alles aus Plus frei
        ent.setPlanForTesting(.proAI)
        XCTAssertTrue(ent.allows(.pencilWriting))
        XCTAssertTrue(ent.allows(.flashcards))
        ent.setPlanForTesting(.proConnect)
        XCTAssertTrue(ent.allows(.community))
        XCTAssertTrue(ent.allows(.splitView))
        // Uni & Noten ist da (QIS bzw. LSF auf dem Geraet) und in jedem Tarif frei; die Sperrkarte kennt "bald" weiter
        XCTAssertEqual(ent.access(.uniGrades), .allowed)
        let soon = UFLockedCard.message(.uniGrades, access: .comingSoon)
        XCTAssertFalse(soon.contains("Enthalten in"))
        XCTAssertTrue(soon.contains("Bald verfügbar"))
        // Community in Free: Schloss, "Enthalten ab Studora Plus"
        let free = Entitlements(observe: false, plan: .free)
        XCTAssertTrue(UFLockedCard.message(.community, access: free.access(.community)).contains("Enthalten ab Studora Plus."))
        XCTAssertEqual(free.access(.community).requiredPlan, .plus)
    }

    // MARK: Angebotstexte (Richtlinie 3.1.2)

    func testOfferTexts() {
        let month = (1, Product.SubscriptionPeriod.Unit.month)
        let week = (1, Product.SubscriptionPeriod.Unit.week)
        XCTAssertEqual(UFOfferText.summary(price: "1,99 €", period: month, freeTrial: week, eligible: true),
                       "1 Woche gratis, danach 1,99 €/Monat, monatlich kündbar")
        XCTAssertEqual(UFOfferText.summary(price: "1,99 €", period: month, freeTrial: week, eligible: false),
                       "1,99 €/Monat, monatlich kündbar")
        XCTAssertEqual(UFOfferText.summary(price: "1,99 €", period: month, freeTrial: nil, eligible: true),
                       "1,99 €/Monat, monatlich kündbar")
        XCTAssertEqual(UFOfferText.button(plan: .plus, price: "1,99 €", period: month, freeTrial: week, eligible: true), "Studora Plus – 1 Woche gratis")
        XCTAssertEqual(UFOfferText.button(plan: .plus, price: "1,99 €", period: month, freeTrial: week, eligible: false), "Studora Plus für 1,99 €/Monat")
        XCTAssertEqual(UFOfferText.button(plan: .proAI, price: "3,99 €", period: month, freeTrial: week, eligible: true), "Studora Pro AI – 1 Woche gratis")
        XCTAssertEqual(UFOfferText.button(plan: .proConnect, price: "2,99 €", period: month, freeTrial: week, eligible: false),
                       "Studora Pro Connect für 2,99 €/Monat")
        // Wechsel in der Abo-Gruppe: hoeher sofort, kleiner ab der naechsten Verlaengerung (regelt Apple)
        XCTAssertEqual(UFOfferText.switchButton(to: .proAI), "Zu Studora Pro AI wechseln")
        XCTAssertEqual(UFOfferText.switchNote(to: .proAI, from: .plus), "Gilt sofort. Apple verrechnet den bisherigen Tarif anteilig.")
        XCTAssertEqual(UFOfferText.switchNote(to: .plus, from: .proAI), "Gilt ab der nächsten Verlängerung, bis dahin bleibt Studora Pro AI.")
        let nov27 = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "Europe/Berlin"),
                                   year: 2026, month: 11, day: 27, hour: 12).date!
        XCTAssertEqual(UFOfferText.pendingNote(.plus, at: nov27), "Wechsel zu Studora Plus vorgemerkt ab 27. November.")
        XCTAssertEqual(UFOfferText.pendingNote(.plus, at: nil), "Wechsel zu Studora Plus zur nächsten Verlängerung vorgemerkt.")
        XCTAssertEqual(UFOfferText.cancelledNote(.proConnect, endsAt: nov27),
                       "Gekündigt – Studora Pro Connect endet am 27. November, danach gilt Studora Free.")
        XCTAssertEqual(UFOfferText.period(value: 2, unit: .week), "2 Wochen")
        XCTAssertEqual(UFOfferText.per(value: 1, unit: .year), "/Jahr")
        XCTAssertEqual(UFOfferText.per(value: 3, unit: .month), "/3 Monate")
        XCTAssertEqual(UFOfferText.cancelNote(value: 1, unit: .year), "jährlich kündbar")
    }
}
