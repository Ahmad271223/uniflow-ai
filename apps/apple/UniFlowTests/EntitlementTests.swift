import StoreKit
import XCTest
@testable import UniFlow

/// Zuordnung Produkt -> Tarif -> Funktion (Abschnitt 4), Herabstufen und Angebotstexte (Abschnitt 5) ohne StoreKit.
final class EntitlementTests: XCTestCase {

    func testProductToPlan() {
        XCTAssertEqual(UFPlan(productID: "de.uniflow.plus.monthly"), .plus)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.pro.monthly"), .pro)
        XCTAssertNil(UFPlan(productID: "fremd"))
        XCTAssertNil(UFPlan.free.productID)
        XCTAssertEqual(PurchaseStore.productIDs, ["de.uniflow.plus.monthly", "de.uniflow.pro.monthly"])
        XCTAssertLessThan(UFPlan.free, .plus)
        XCTAssertLessThan(UFPlan.plus, .pro)
    }

    func testMatrixFree() {
        for f: UFFeature in [.studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .timer, .viewNotes] {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .free), .allowed, f.rawValue)
        }
        for f: UFFeature in [.pencilWriting, .splitView, .studyPlanning, .flashcards] {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .free), .locked(.plus), f.rawValue)
        }
        XCTAssertEqual(UFFeatureMatrix.access(.uniGrades, plan: .free), .locked(.pro))
    }

    func testMatrixPlusAndPro() {
        for f: UFFeature in [.pencilWriting, .splitView, .studyPlanning, .flashcards, .readDocuments] {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .plus), .allowed, f.rawValue)
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .pro), .allowed, f.rawValue)
        }
        XCTAssertEqual(UFFeatureMatrix.access(.uniGrades, plan: .plus), .locked(.pro))
        XCTAssertEqual(UFFeatureMatrix.access(.uniGrades, plan: .pro), .allowed)
    }

    func testAIAndV2AreComingSoonWithoutService() {
        XCTAssertFalse(UFFeatureMatrix.aiServiceAvailable)
        for p in UFPlan.allCases {
            XCTAssertEqual(UFFeatureMatrix.access(.aiTests, plan: p), .comingSoon)
            XCTAssertEqual(UFFeatureMatrix.access(.aiTutor, plan: p), .comingSoon)
            XCTAssertEqual(UFFeatureMatrix.access(.uniflowEditor, plan: p), .comingSoon)
            XCTAssertEqual(UFFeatureMatrix.access(.deviceSync, plan: p), .comingSoon)
            XCTAssertFalse(UFFeatureMatrix.canStartAITest(plan: p, usedThisMonth: 0))
        }
    }

    func testAIQuotaWithService() {
        XCTAssertEqual(UFPlan.allCases.map(\.aiTestQuota), [1, 6, 40])
        XCTAssertTrue(UFFeatureMatrix.canStartAITest(plan: .free, usedThisMonth: 0, aiService: true))
        XCTAssertFalse(UFFeatureMatrix.canStartAITest(plan: .free, usedThisMonth: 1, aiService: true))
        XCTAssertTrue(UFFeatureMatrix.canStartAITest(plan: .plus, usedThisMonth: 5, aiService: true))
        XCTAssertFalse(UFFeatureMatrix.canStartAITest(plan: .plus, usedThisMonth: 6, aiService: true))
        XCTAssertTrue(UFFeatureMatrix.canStartAITest(plan: .pro, usedThisMonth: 39, aiService: true))
        XCTAssertEqual(UFFeatureMatrix.access(.aiTutor, plan: .plus, aiService: true), .locked(.pro))
        XCTAssertEqual(UFFeatureMatrix.access(.aiTutor, plan: .pro, aiService: true), .allowed)
    }

    func testDowngradeKeepsNotesReadableAndExportable() {
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .free), UFNoteAccess(canView: true, canExport: true, canEdit: false))
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .plus), UFNoteAccess(canView: true, canExport: true, canEdit: true))
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .pro), UFNoteAccess(canView: true, canExport: true, canEdit: true))
    }

    func testPlanCardsWithoutAIRows() {
        XCTAssertEqual(UFFeatureMatrix.added(in: .plus).filter { !$0.isV2 }, [.pencilWriting, .splitView, .studyPlanning, .flashcards])
        XCTAssertEqual(UFFeatureMatrix.added(in: .pro), [.uniGrades])
        XCTAssertFalse(UFFeatureMatrix.added(in: .free).contains(.aiTests))
    }

    // MARK: Tarif aus Transaktionen

    func testResolverPicksHighestActive() {
        let now = Date()
        let later = now.addingTimeInterval(3600), earlier = now.addingTimeInterval(-3600)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [], now: now), .free)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [.init(productID: "de.uniflow.plus.monthly", expirationDate: later)], now: now), .plus)
        XCTAssertEqual(UFEntitlementResolver.plan(from: [
            .init(productID: "de.uniflow.plus.monthly", expirationDate: later),
            .init(productID: "de.uniflow.pro.monthly", expirationDate: later),
        ], now: now), .pro)
        // abgelaufen, erstattet, ersetzt oder fremd -> zaehlt nicht
        XCTAssertEqual(UFEntitlementResolver.plan(from: [
            .init(productID: "de.uniflow.pro.monthly", expirationDate: earlier),
            .init(productID: "de.uniflow.pro.monthly", expirationDate: later, revocationDate: earlier),
            .init(productID: "de.uniflow.pro.monthly", expirationDate: later, isUpgraded: true),
            .init(productID: "fremd", expirationDate: later),
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
        XCTAssertEqual(ent.access(.flashcards), .locked(.plus))
        ent.setPlanForTesting(.plus)
        XCTAssertTrue(ent.allows(.flashcards))
        XCTAssertEqual(UFLockedCard.message(.uniGrades, access: .locked(.pro)).contains("Enthalten in Pro"), true)
    }

    // MARK: Angebotstexte (Richtlinie 3.1.2)

    func testOfferTexts() {
        let month = (1, Product.SubscriptionPeriod.Unit.month)
        let week = (1, Product.SubscriptionPeriod.Unit.week)
        XCTAssertEqual(UFOfferText.summary(price: "1,99 €", period: month, freeTrial: week, eligible: true),
                       "1 Woche gratis, danach 1,99 €/Monat, monatlich kündbar")
        XCTAssertEqual(UFOfferText.summary(price: "4,99 €", period: month, freeTrial: week, eligible: false),
                       "4,99 €/Monat, monatlich kündbar")
        XCTAssertEqual(UFOfferText.summary(price: "4,99 €", period: month, freeTrial: nil, eligible: true),
                       "4,99 €/Monat, monatlich kündbar")
        XCTAssertEqual(UFOfferText.button(plan: .plus, price: "1,99 €", period: month, freeTrial: week, eligible: true), "Plus – 1 Woche gratis")
        XCTAssertEqual(UFOfferText.button(plan: .pro, price: "4,99 €", period: month, freeTrial: week, eligible: false), "Pro für 4,99 €/Monat")
        XCTAssertEqual(UFOfferText.period(value: 2, unit: .week), "2 Wochen")
        XCTAssertEqual(UFOfferText.per(value: 1, unit: .year), "/Jahr")
        XCTAssertEqual(UFOfferText.per(value: 3, unit: .month), "/3 Monate")
        XCTAssertEqual(UFOfferText.cancelNote(value: 1, unit: .year), "jährlich kündbar")
    }
}
