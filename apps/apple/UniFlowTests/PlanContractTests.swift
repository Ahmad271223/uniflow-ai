import StoreKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Swift-Tabelle der Studora-Tarife (Plans.swift) gegen den gemeinsamen Vertrag
/// packages/shared-contracts/fixtures/plans/plans.json (aus app/plans.py, tools/gen-plans-fixture.py): Namen, Preise,
/// Produkte, Rechte je Tarif und Stand. Dazu die Regel des Inhabers vom 27.10.2026: als enthalten zeigt das iPad nur,
/// was im Vertrag `available` ist und auf dem Geraet wirklich geht; alles, was den Dienst braucht, steht unter
/// "in Vorbereitung".
final class PlanContractTests: XCTestCase {
    private static let path = "packages/shared-contracts/fixtures/plans/plans.json"

    private func text() throws -> String {
        try String(contentsOf: ContainerTestBed.repoURL(Self.path), encoding: .utf8)
    }

    private func contract() throws -> JSONValue {
        try JSONValue.parse(text())
    }

    private func int(_ v: JSONValue?) -> Int? { v?.double.map { Int($0) } }

    // MARK: Vertrag

    func testPlansMatchContract() throws {
        let c = try contract()
        XCTAssertEqual(int(c["version"]), 1, "neue Fassung des Vertrags: Tabelle und Tests pruefen")
        XCTAssertEqual(c["order"]?.array?.compactMap(\.string), UFPlan.allCases.map(\.rawValue))
        let plans = try XCTUnwrap(c["plans"]?.object)
        XCTAssertEqual(Set(plans.keys), Set(UFPlan.allCases.map(\.rawValue)))
        for plan in UFPlan.allCases {
            let p = try XCTUnwrap(plans[plan.rawValue], plan.rawValue)
            XCTAssertEqual(int(p["rank"]), plan.rank, plan.rawValue)
            XCTAssertEqual(p["name"]?.string, plan.name, plan.rawValue)
            XCTAssertEqual(int(p["price_cents"]), plan.priceCents, plan.rawValue)
            XCTAssertEqual(p["currency"]?.string, "EUR", plan.rawValue)
            XCTAssertEqual(p["period"]?.string, "month", plan.rawValue)
            if plan == .free {
                XCTAssertEqual(p["apple_product_id"]?.isNull, true)
            }
            XCTAssertEqual(p["apple_product_id"]?.string, plan.productID, plan.rawValue)
            XCTAssertEqual(p["tagline"]?.string, plan.tagline, plan.rawValue)
        }
        // Reihenfolge = Rang, jeder hoehere Tarif kostet mehr
        XCTAssertEqual(UFPlan.allCases.map(\.rank), [0, 1, 2, 3])
        XCTAssertEqual(UFPlan.allCases.map(\.priceCents), UFPlan.allCases.map(\.priceCents).sorted())
    }

    func testEntitlementsMatchContract() throws {
        let c = try contract()
        let rights = try XCTUnwrap(c["entitlements"]?.object)
        XCTAssertEqual(Set(rights.keys), Set(UFEntitlement.allCases.map(\.rawValue)))
        for e in UFEntitlement.allCases {
            let r = try XCTUnwrap(rights[e.rawValue], e.rawValue)
            XCTAssertEqual(r["from"]?.string, e.from.rawValue, e.rawValue)
            XCTAssertEqual(r["label"]?.string, e.label, e.rawValue)
            XCTAssertEqual(r["status"]?.string, e.status.rawValue, e.rawValue)
        }
        // Rechte je Tarif (plans.<tarif>.entitlements), so wie der Dienst sie ausliefert
        for plan in UFPlan.allCases {
            let table = try XCTUnwrap(c["plans"]?[plan.rawValue]?["entitlements"]?.object, plan.rawValue)
            XCTAssertEqual(Set(table.keys), Set(UFEntitlement.allCases.map(\.rawValue)), plan.rawValue)
            for e in UFEntitlement.allCases {
                XCTAssertEqual(table[e.rawValue]?.bool, e.included(in: plan), "\(plan.rawValue).\(e.rawValue)")
            }
        }
        // jeder Tarif enthaelt alle Rechte der niedrigeren
        for e in UFEntitlement.allCases {
            let has = UFPlan.allCases.map { e.included(in: $0) }
            XCTAssertEqual(has, has.sorted { !$0 && $1 }, e.rawValue)
        }
        // ChatGPT: Integration aus, keine Kopplung an einen Tarif (ABO-SYSTEM.md, Abschnitt 4)
        XCTAssertEqual(c["integrations"]?["chatgpt"]?["status"]?.string, "disabled")
        XCTAssertEqual(c["integrations"]?["chatgpt"]?["plan_gating_allowed"]?.bool, false)
        XCTAssertEqual(UFEntitlement.chatgptConnectionPremium.status, .disabled)
    }

    /// Reihenfolge der Rechte wie im Vertrag (Reihenfolge der Zeilen auf den Tarifkarten). JSONValue kennt keine
    /// Reihenfolge der Schluessel, darum aus dem Text des Blocks "entitlements" (Form aus tools/gen-plans-fixture.py).
    func testEntitlementOrderMatchesContract() throws {
        let t = try text()
        let start = try XCTUnwrap(t.range(of: "\n \"entitlements\": {\n"))
        let end = try XCTUnwrap(t.range(of: "\n }", range: start.upperBound..<t.endIndex))
        let block = String(t[start.upperBound..<end.lowerBound])
        let keys = try NSRegularExpression(pattern: "^  \"([a-z_]+)\": \\{", options: .anchorsMatchLines)
            .matches(in: block, range: NSRange(block.startIndex..., in: block))
            .compactMap { Range($0.range(at: 1), in: block).map { String(block[$0]) } }
        XCTAssertEqual(keys, UFEntitlement.allCases.map(\.rawValue))
    }

    /// Apple-Produkte der StoreKit-Testkonfiguration = Produkte des Vertrags, eine Abo-Gruppe, Stufen nach Rang
    /// (Stufe 1 = hoechster Tarif), je 1 Woche gratis, monatlich
    func testStoreKitConfigurationMatchesContract() throws {
        let url = ContainerTestBed.repoURL("apps/apple/UniFlowTests/UniFlow.storekit")
        let sk = try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
        let groups = try XCTUnwrap(sk["subscriptionGroups"]?.array)
        XCTAssertEqual(groups.count, 1, "eine Abo-Gruppe, damit Apple Upgrade, Downgrade und Doppel-Abos regelt")
        let subs = try XCTUnwrap(groups.first?["subscriptions"]?.array)
        XCTAssertEqual(subs.compactMap { $0["productID"]?.string }, UFPlan.paid.compactMap(\.productID))
        XCTAssertEqual(PurchaseStore.productIDs, UFPlan.paid.compactMap(\.productID))
        for (plan, s) in zip(UFPlan.paid, subs) {
            XCTAssertEqual(s["displayPrice"]?.string, String(format: "%.2f", Double(plan.priceCents) / 100), plan.rawValue)
            XCTAssertEqual(int(s["groupNumber"]), UFPlan.allCases.count - plan.rank, "Stufe in der Gruppe: \(plan.rawValue)")
            XCTAssertEqual(s["recurringSubscriptionPeriod"]?.string, "P1M")
            XCTAssertEqual(s["introductoryOffer"]?["paymentMode"]?.string, "free")
            XCTAssertEqual(s["introductoryOffer"]?["subscriptionPeriod"]?.string, "P1W")
            XCTAssertEqual(s["localizations"]?.array?.first?["displayName"]?.string, plan.name)
            XCTAssertEqual(s["subscriptionGroupID"]?.string, groups.first?["id"]?.string)
        }
    }

    // MARK: Umsetzung auf dem iPad

    /// Jedes Recht ist entweder auf dem Geraet umgesetzt (ab demselben Tarif wie im Vertrag, ausser den benannten
    /// Abweichungen) oder braucht den Dienst. Was der Inhaber als Dienst-Funktion nennt, ist nie "enthalten".
    func testEveryContractRightIsOnDeviceOrPreparing() {
        XCTAssertEqual(UFEntitlement.iPadDeviations, [.canReadCommunity: .plus], "nur die bekannte Abweichung")
        for e in UFEntitlement.allCases {
            switch e.onDevice {
            case .onDevice(let features):
                XCTAssertFalse(features.isEmpty, e.rawValue)
                XCTAssertEqual(e.status, .available, "umgesetzt, aber im Vertrag nicht available: \(e.rawValue)")
                XCTAssertTrue(e.availableOnDevice, e.rawValue)
                let iPadFrom = features.map(\.minimumPlan).max()
                XCTAssertEqual(iPadFrom, UFEntitlement.iPadDeviations[e] ?? e.from, e.rawValue)
                for f in features {
                    XCTAssertFalse(f.isV2, "\(e.rawValue): \(f.rawValue)")
                    XCTAssertEqual(UFFeatureMatrix.access(f, plan: .proAI), .allowed, "\(e.rawValue): \(f.rawValue)")
                }
            case .needsService:
                XCTAssertFalse(e.availableOnDevice, e.rawValue)
            }
        }
        // Dienst-Funktionen laut Auftrag: Studora-KI, gemeinsame Testbibliothek, Lernstatistik/Empfehlungen,
        // Geraete-Abgleich, ChatGPT
        let service: [UFEntitlement] = [.canUseAIExplanations, .canUseAISummaries, .canUseAIGeneratedQuestions,
                                        .canUseAIRecommendations, .canGenerateStudoraAITests, .canAccessSharedTests,
                                        .canUseAdvancedAnalytics, .canUseAdvancedPlanner, .canGetRecommendations,
                                        .canReviewWrongAnswers, .canUseExtendedTestHistory, .canSyncAnnotations,
                                        .chatgptConnectionPremium]
        for e in service { XCTAssertEqual(e.onDevice, .needsService, e.rawValue) }
        // nicht im Vertrag available -> nie auf dem Geraet umgesetzt
        XCTAssertEqual(UFEntitlement.canWriteCommunityComments.status, .comingSoon)
        XCTAssertFalse(UFEntitlement.canWriteCommunityComments.availableOnDevice)
    }

    /// Pro Connect und Pro AI enthalten alles aus Plus; die Rechte von Plus bleiben, wie sie waren
    func testProPlansContainEverythingFromPlus() {
        for f in UFFeature.allCases {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .proConnect), UFFeatureMatrix.access(f, plan: .plus), f.rawValue)
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .proAI), UFFeatureMatrix.access(f, plan: .plus), f.rawValue)
        }
        for f: UFFeature in [.pencilWriting, .community, .splitView, .flashcards] {
            XCTAssertEqual(f.minimumPlan, .plus, f.rawValue)
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .free), .locked(.plus), f.rawValue)
        }
        XCTAssertFalse(UFFeature.allCases.contains { $0.minimumPlan > .plus }, "keine Geraete-Funktion erst ab Pro")
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .proConnect), UFNoteAccess(canView: true, canExport: true, canEdit: true))
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .proAI), UFNoteAccess(canView: true, canExport: true, canEdit: true))
    }

    // MARK: Tarifkarten

    func testPlanCardsListOnlyWhatWorksAndMarkTheRest() {
        XCTAssertEqual(UFPlanCard.included(.free).map(\.title),
                       [UFFeature.studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .studyPlanning, .timer,
                        .viewNotes, .uniGrades].map(\.title))
        XCTAssertEqual(UFPlanCard.included(.plus).map(\.title),
                       [UFFeature.pencilWriting, .community, .splitView, .flashcards].map(\.title))
        XCTAssertEqual(UFPlanCard.included(.proConnect), [], "Pro Connect bietet auf dem iPad heute nichts Eigenes")
        XCTAssertEqual(UFPlanCard.included(.proAI), [], "Pro AI bietet auf dem iPad heute nichts Eigenes")

        XCTAssertEqual(UFPlanCard.preparing(.free), [])
        XCTAssertEqual(UFPlanCard.preparing(.plus).map(\.title),
                       ["Notizen auf allen Geräten", "Community-Kommentare schreiben", "Tests aus der Studora-Bibliothek",
                        "Neue KI-Tests von Studora"])
        XCTAssertEqual(UFPlanCard.preparing(.proConnect).map(\.title),
                       ["Erweiterte Lernstatistiken", "Intelligente Lernplanung (Empfehlungen für die Woche)",
                        "Automatische Wiederholung falscher Antworten", "Erweiterte Testhistorie",
                        "Personalisierte Lernempfehlungen", "Eigenes ChatGPT-Konto verbinden"])
        XCTAssertEqual(UFPlanCard.preparing(.proAI).map(\.title),
                       ["KI-Erklärungen zu Aufgaben", "Automatische Lernfragen und Wiederholungsaufgaben",
                        "KI-Zusammenfassungen", "KI-gestützte Lernempfehlungen"])

        for plan in UFPlan.allCases {
            for r in UFPlanCard.included(plan) {
                XCTAssertFalse(r.preparing, r.title)
                XCTAssertNil(r.title.range(of: #"\bKI\b|KI-|ChatGPT|Statistik|Bibliothek|allen Geräten"#, options: .regularExpression),
                             "enthalten, aber braucht den Dienst: \(r.title)")
            }
            for r in UFPlanCard.preparing(plan) {
                XCTAssertTrue(r.preparing, r.title)
                XCTAssertEqual(r.icon, "clock")
                XCTAssertFalse(r.title.contains("in Vorbereitung"), "Zusatz steht schon in der Marke: \(r.title)")
            }
            // jedes Recht ab diesem Tarif steht auf der Karte: als Geraete-Funktion oder unter "in Vorbereitung"
            for e in UFEntitlement.allCases where e.from == plan && UFEntitlement.iPadDeviations[e] == nil {
                if e.availableOnDevice, case .onDevice(let fs) = e.onDevice {
                    for f in fs { XCTAssertTrue(UFPlanCard.included(plan).contains { $0.title == f.title }, "\(e.rawValue): \(f.rawValue)") }
                } else {
                    XCTAssertTrue(UFPlanCard.preparing(plan).contains { $0.title == e.cardLabel }, e.rawValue)
                }
            }
        }
    }

    func testPlanCardTextsAreHonest() {
        XCTAssertEqual(UFPlanCard.sameScope(as: .free), .free)
        XCTAssertEqual(UFPlanCard.sameScope(as: .plus), .plus)
        XCTAssertEqual(UFPlanCard.sameScope(as: .proConnect), .plus)
        XCTAssertEqual(UFPlanCard.sameScope(as: .proAI), .plus)
        XCTAssertNil(UFPlanCard.note(.free))
        let base = "Was „in Vorbereitung“ steht, braucht den Online-Dienst von Studora und folgt mit einem Update."
        XCTAssertEqual(UFPlanCard.note(.plus), base)
        XCTAssertEqual(UFPlanCard.note(.proConnect), base + " Bis dahin bietet Studora Pro Connect denselben Umfang wie Studora Plus.")
        XCTAssertEqual(UFPlanCard.note(.proAI), base + " Bis dahin bietet Studora Pro AI denselben Umfang wie Studora Plus.")
        XCTAssertEqual(UFPlanCard.intro(.free), "Alles für den Uni-Alltag:")
        XCTAssertEqual(UFPlanCard.intro(.plus), "Alles aus Studora Free, dazu:")
        XCTAssertEqual(UFPlanCard.intro(.proConnect), "Alles aus Studora Plus.")
        XCTAssertEqual(UFPlanCard.intro(.proAI), "Alles aus Studora Pro Connect.")
        // Kurzbeschreibung nur, wenn sie stimmt ("KI von Studora inklusive" waere heute ein Versprechen)
        XCTAssertEqual(UFPlanCard.tagline(.free), UFPlan.free.tagline)
        XCTAssertEqual(UFPlanCard.tagline(.plus), UFPlan.plus.tagline)
        XCTAssertNil(UFPlanCard.tagline(.proConnect))
        XCTAssertNil(UFPlanCard.tagline(.proAI))
        // Seitenkopf: alle vier Namen, "in Vorbereitung", Probewoche nur mit Anspruch
        let sub = PlanPickerView.subtitle(trial: "1 Woche")
        for p in UFPlan.allCases { XCTAssertTrue(sub.contains(p.name), p.rawValue) }
        XCTAssertTrue(sub.contains("1 Woche gratis zum Start"))
        XCTAssertTrue(sub.contains("in Vorbereitung"))
        XCTAssertFalse(PlanPickerView.subtitle(trial: nil).contains("gratis"))
        XCTAssertEqual(PlanPickerView.title(.onboarding), "Tarif wählen")
        XCTAssertEqual(PlanPickerView.title(.settings), "Tarif wechseln")
        XCTAssertEqual(PlanPickerView.title(.upgrade(.plus)), "Mehr mit Studora Plus")
        XCTAssertEqual(PlanPickerView.title(.upgrade(nil)), "Tarif wechseln")
        XCTAssertTrue(PlanPickerView.legalText.contains("höheren Tarif gilt sofort"))
        XCTAssertTrue(PlanPickerView.legalText.contains("24 Stunden"))
    }

    // MARK: Verknuepfung mit dem Dienst (V2, abgeschaltet)

    /// V1 ruft den Dienst nicht auf: keine Kaufoption (kein appAccountToken), keine Anfrage an
    /// /api/billing/apple/verify, kein Pruef-Haken am gemeinsamen Tarif. Die Form fuer V2 steht fest.
    @MainActor
    func testServiceLinkIsPreparedButSwitchedOff() throws {
        XCTAssertFalse(UFBillingServiceLink.isEnabled)
        XCTAssertNil(Entitlements.shared.verifyOnServer)
        let token = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        XCTAssertTrue(UFBillingServiceLink.purchaseOptions(accountToken: token).isEmpty)
        XCTAssertNil(UFBillingServiceLink.verifyRequest(base: URL(string: "https://dienst.example")!, signedTransaction: "a.b.c"))

        // Form fuer V2 (nur mit enabled: true, wie app/billing_api.py sie erwartet)
        XCTAssertEqual(UFBillingServiceLink.purchaseOptions(accountToken: token, enabled: true),
                       [.appAccountToken(try XCTUnwrap(UUID(uuidString: token)))])
        XCTAssertTrue(UFBillingServiceLink.purchaseOptions(accountToken: "keine-uuid", enabled: true).isEmpty)
        XCTAssertTrue(UFBillingServiceLink.purchaseOptions(accountToken: nil, enabled: true).isEmpty)
        let r = try XCTUnwrap(UFBillingServiceLink.verifyRequest(base: URL(string: "https://dienst.example")!,
                                                                 signedTransaction: "a.b.c", signedRenewal: "d.e.f", enabled: true))
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://dienst.example/api/billing/apple/verify")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONValue.parse(try XCTUnwrap(r.httpBody))
        XCTAssertEqual(body["signed_transaction"]?.string, "a.b.c")
        XCTAssertEqual(body["signed_renewal"]?.string, "d.e.f")
        let noRenewal = try XCTUnwrap(UFBillingServiceLink.verifyRequest(base: URL(string: "https://dienst.example")!,
                                                                         signedTransaction: "a.b.c", enabled: true))
        XCTAssertNil(try JSONValue.parse(try XCTUnwrap(noRenewal.httpBody))["signed_renewal"])
        XCTAssertNil(UFBillingServiceLink.verifyRequest(base: URL(string: "https://dienst.example")!, signedTransaction: "",
                                                        enabled: true))
    }
}
