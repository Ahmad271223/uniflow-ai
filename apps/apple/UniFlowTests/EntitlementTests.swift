import StoreKit
import XCTest
@testable import UniFlow

/// Zuordnung Produkt -> Tarif -> Funktion (Abschnitt 4), Herabstufen und Angebotstexte (Abschnitt 5) ohne StoreKit.
final class EntitlementTests: XCTestCase {

    func testProductToPlan() {
        XCTAssertEqual(UFPlan.allCases, [.free, .plus])
        XCTAssertEqual(UFPlan(productID: "de.uniflow.plus.monthly"), .plus)
        // Pro wird vorerst nicht angeboten (Entscheidung 25.10.2026): das fruehere Produkt gibt keinen Tarif
        XCTAssertNil(UFPlan(productID: "de.uniflow.pro.monthly"))
        XCTAssertNil(UFPlan(productID: "fremd"))
        XCTAssertNil(UFPlan.free.productID)
        XCTAssertEqual(PurchaseStore.productIDs, ["de.uniflow.plus.monthly"])
        XCTAssertLessThan(UFPlan.free, .plus)
    }

    /// Free: planen (Lernplanung), Dokumente oeffnen, Faecher geordnet sehen und der Rest des Uni-Alltags
    func testMatrixFree() {
        for f: UFFeature in [.studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .studyPlanning, .timer, .viewNotes] {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .free), .allowed, f.rawValue)
        }
        for f: UFFeature in [.pencilWriting, .splitView] {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .free), .locked(.plus), f.rawValue)
        }
        // Karteikarten gibt es ohne PC noch nicht: "bald", sobald vorhanden Plus
        XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: .free), .comingSoon)
        XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: .free, flashcards: true), .locked(.plus))
        XCTAssertEqual(UFFeatureMatrix.access(.community, plan: .free), .locked(.plus), "Lösung teilen: Schloss mit Weg zur Abo-Seite")
        // Uni & Noten liegt ausserhalb der Tarife: sobald nativ vorhanden, gleich in Free
        XCTAssertEqual(UFFeatureMatrix.access(.uniGrades, plan: .free, uniGrades: true), .allowed)
    }

    func testMatrixPlus() {
        for f: UFFeature in [.pencilWriting, .splitView, .studyPlanning, .readDocuments] {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .plus), .allowed, f.rawValue)
        }
        XCTAssertEqual(UFFeatureMatrix.access(.community, plan: .plus, community: true), .allowed)
        // Plus-Karte fuehrt Karteikarten als "bald", nicht als enthalten (Anlegen und Wiederholen fehlen ohne PC)
        XCTAssertFalse(UFFeatureMatrix.flashcardsOnDevice)
        XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: .plus), .comingSoon)
        XCTAssertEqual(UFFeatureMatrix.access(.flashcards, plan: .plus, flashcards: true), .allowed)
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

    /// Plus bietet schon heute mehr als Free (Schreiben, Uebung und Skript, Loesung als Datei teilen)
    func testPlusHasExtras() {
        XCTAssertTrue(UFFeatureMatrix.hasAvailableExtras(in: .free))
        XCTAssertTrue(UFFeatureMatrix.hasAvailableExtras(in: .plus))
    }

    func testDowngradeKeepsNotesReadableAndExportable() {
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .free), UFNoteAccess(canView: true, canExport: true, canEdit: false))
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .plus), UFNoteAccess(canView: true, canExport: true, canEdit: true))
    }

    /// Inhalt der zwei Tarifkarten (Abschnitt 4), ohne KI-Zeilen
    func testPlanCards() {
        XCTAssertEqual(UFFeatureMatrix.added(in: .free),
                       [.studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .studyPlanning, .timer, .viewNotes, .uniGrades])
        XCTAssertEqual(UFFeatureMatrix.added(in: .plus).filter { !$0.isV2 }, [.pencilWriting, .community, .splitView, .flashcards])
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
        XCTAssertEqual(ent.access(.flashcards), .comingSoon)
        XCTAssertTrue(ent.allows(.studyPlanning), "Lernplanung gehoert zu Free")
        ent.setPlanForTesting(.plus)
        XCTAssertTrue(ent.allows(.splitView))
        XCTAssertFalse(ent.allows(.flashcards), "auch mit Plus bald")
        XCTAssertTrue(UFLockedCard.message(.flashcards, access: ent.access(.flashcards)).contains("Bald verfügbar"))
        let locked = UFLockedCard.message(.pencilWriting, access: .locked(.plus))
        XCTAssertTrue(locked.contains("Enthalten in Plus."))
        XCTAssertFalse(locked.contains("Pro"))
        // Uni & Noten ist da (QIS bzw. LSF auf dem Geraet) und in jedem Tarif frei; die Sperrkarte kennt "bald" weiter
        XCTAssertEqual(ent.access(.uniGrades), .allowed)
        let soon = UFLockedCard.message(.uniGrades, access: .comingSoon)
        XCTAssertFalse(soon.contains("Enthalten in"))
        XCTAssertTrue(soon.contains("Bald verfügbar"))
        // Community in Free: Schloss, "Enthalten in Plus"
        let free = Entitlements(observe: false, plan: .free)
        XCTAssertTrue(UFLockedCard.message(.community, access: free.access(.community)).contains("Enthalten in Plus."))
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
        XCTAssertEqual(UFOfferText.button(plan: .plus, price: "1,99 €", period: month, freeTrial: week, eligible: true), "Plus – 1 Woche gratis")
        XCTAssertEqual(UFOfferText.button(plan: .plus, price: "1,99 €", period: month, freeTrial: week, eligible: false), "Plus für 1,99 €/Monat")
        XCTAssertEqual(UFOfferText.period(value: 2, unit: .week), "2 Wochen")
        XCTAssertEqual(UFOfferText.per(value: 1, unit: .year), "/Jahr")
        XCTAssertEqual(UFOfferText.per(value: 3, unit: .month), "/3 Monate")
        XCTAssertEqual(UFOfferText.cancelNote(value: 1, unit: .year), "jährlich kündbar")
    }
}
