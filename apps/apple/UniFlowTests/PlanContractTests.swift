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

    /// StoreKit-Konfigurationen: `UniFlow.storekit` (App, V1) hat genau die kaufbaren Abo-Tarife; die Testkonfiguration
    /// `UniFlowAlleTarife.storekit` (Wechsel-Logik, ab V2) alle Abo-Tarife des Vertrags in einer Gruppe, Stufen nach
    /// Rang (Stufe 1 = hoechster Tarif). Je 1 Woche gratis, monatlich, Gruppe "Studora", Namen wie im Vertrag.
    func testStoreKitConfigurationsMatchContract() throws {
        let v1 = UFPlanCatalog.sellable.filter { $0.productID != nil }
        XCTAssertEqual(v1, [.plus], "V1 verkauft nur Studora Plus (Entscheidung 28.10.2026)")
        XCTAssertEqual(PurchaseStore.productIDs, v1.compactMap(\.productID))
        for (file, plans) in [("UniFlow", v1), ("UniFlowAlleTarife", UFPlan.paid)] {
            let url = ContainerTestBed.repoURL("apps/apple/UniFlowTests/\(file).storekit")
            let sk = try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
            let groups = try XCTUnwrap(sk["subscriptionGroups"]?.array, file)
            XCTAssertEqual(groups.count, 1, "eine Abo-Gruppe, damit Apple Upgrade, Downgrade und Doppel-Abos regelt: \(file)")
            XCTAssertEqual(groups.first?["name"]?.string, "Studora", file)
            XCTAssertEqual(sk["products"]?.array?.count, 0, file)
            let subs = try XCTUnwrap(groups.first?["subscriptions"]?.array, file)
            XCTAssertEqual(subs.compactMap { $0["productID"]?.string }, plans.compactMap(\.productID), file)
            let topRank = plans.map(\.rank).max() ?? 0
            for (plan, s) in zip(plans, subs) {
                let tag = "\(file): \(plan.rawValue)"
                XCTAssertEqual(s["displayPrice"]?.string, String(format: "%.2f", Double(plan.priceCents) / 100), tag)
                XCTAssertEqual(int(s["groupNumber"]), topRank - plan.rank + 1, "Stufe in der Gruppe: \(tag)")
                XCTAssertEqual(s["recurringSubscriptionPeriod"]?.string, "P1M", tag)
                XCTAssertEqual(s["introductoryOffer"]?["paymentMode"]?.string, "free", tag)
                XCTAssertEqual(s["introductoryOffer"]?["subscriptionPeriod"]?.string, "P1W", tag)
                XCTAssertEqual(s["localizations"]?.array?.first?["displayName"]?.string, plan.name, tag)
                // Grenzen von App Store Connect: Anzeigename 30, Beschreibung 45 Zeichen (docs/release/APP-STORE.md)
                XCTAssertLessThanOrEqual(plan.name.count, 30, tag)
                XCTAssertLessThanOrEqual(s["localizations"]?.array?.first?["description"]?.string?.count ?? 99, 45, tag)
                XCTAssertEqual(s["subscriptionGroupID"]?.string, groups.first?["id"]?.string, tag)
            }
        }
    }

    /// Was V1 anbietet (Entscheidung des Inhabers vom 28.10.2026): Studora Free und Plus. Pro Connect und Pro AI
    /// erscheinen nur als Satz ohne Preis; ein laufender Tarif, der nicht angeboten wird, behaelt seine Karte.
    func testV1SellsOnlyFreeAndPlus() {
        XCTAssertEqual(UFPlanCatalog.sellable, [.free, .plus])
        XCTAssertEqual(UFPlanCatalog.sellableProductIDs, ["de.uniflow.plus.monthly"])
        XCTAssertEqual(UFPlanCatalog.upcoming, [.proConnect, .proAI])
        XCTAssertEqual(UFPlanCatalog.upcomingNote, "Pro-Tarife folgen mit dem Studora-Dienst.")
        XCTAssertNil(UFPlanCatalog.upcomingNote.range(of: #"\d|€"#, options: .regularExpression), "kein Preis im Hinweis")
        XCTAssertEqual(UFPlanCatalog.cards(current: .free), [.free, .plus])
        XCTAssertEqual(UFPlanCatalog.cards(current: .plus), [.free, .plus])
        XCTAssertEqual(UFPlanCatalog.cards(current: .proAI), [.free, .plus, .proAI])
        // Tabelle und Produkt-IDs bleiben fuer V2 im Code
        XCTAssertEqual(UFPlan.allCases.count, 4)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.proai.monthly"), .proAI)
        // Texte der Seite nennen nur, was verkauft wird
        let sub = PlanPickerView.subtitle(trial: "1 Woche")
        XCTAssertTrue(sub.contains(UFPlan.free.name) && sub.contains(UFPlan.plus.name))
        XCTAssertFalse(sub.contains("Pro"))
        XCTAssertFalse(PlanPickerView.legalText.contains("höheren Tarif"), "kein Tarifwechsel zwischen Abos in V1")
        XCTAssertTrue(PlanPickerView.legalText.contains("24 Stunden"))
    }

    // MARK: Umsetzung auf dem iPad

    /// Jedes Recht ist entweder auf dem Geraet umgesetzt, und zwar ab genau dem Tarif aus dem Vertrag (keine
    /// Abweichung des iPads, Entscheidung 28.10.2026), oder braucht den Dienst. Was der Inhaber als Dienst-Funktion
    /// nennt, ist nie "enthalten".
    func testEveryContractRightIsOnDeviceOrPreparing() {
        XCTAssertEqual(UFEntitlement.canReadCommunity.onDevice, .onDevice([.communityRead]))
        XCTAssertEqual(UFEntitlement.canShareSolutions.onDevice, .onDevice([.shareSolutions]))
        for e in UFEntitlement.allCases {
            switch e.onDevice {
            case .onDevice(let features):
                XCTAssertFalse(features.isEmpty, e.rawValue)
                XCTAssertEqual(e.status, .available, "umgesetzt, aber im Vertrag nicht available: \(e.rawValue)")
                XCTAssertTrue(e.availableOnDevice, e.rawValue)
                let iPadFrom = features.map(\.minimumPlan).max()
                XCTAssertEqual(iPadFrom, e.from, e.rawValue)
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
        for f: UFFeature in [.pencilWriting, .shareSolutions, .splitView, .flashcards] {
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
                        .viewNotes, .uniGrades, .communityRead].map(\.title))
        XCTAssertEqual(UFPlanCard.included(.plus).map(\.title),
                       [UFFeature.pencilWriting, .shareSolutions, .splitView, .flashcards].map(\.title))
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
            for e in UFEntitlement.allCases where e.from == plan {
                if e.availableOnDevice, case .onDevice(let fs) = e.onDevice {
                    for f in fs { XCTAssertTrue(UFPlanCard.included(plan).contains { $0.title == f.title }, "\(e.rawValue): \(f.rawValue)") }
                } else {
                    XCTAssertTrue(UFPlanCard.preparing(plan).contains { $0.title == e.cardLabel }, e.rawValue)
                }
            }
        }
    }

    func testPlanCardTextsAreHonest() throws {
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
        // Seitenkopf: Probewoche nur mit Anspruch
        XCTAssertTrue(PlanPickerView.subtitle(trial: "1 Woche").contains("1 Woche gratis zum Start"))
        XCTAssertFalse(PlanPickerView.subtitle(trial: nil).contains("gratis"))
        XCTAssertEqual(PlanPickerView.title(.onboarding), "Tarif wählen")
        XCTAssertEqual(PlanPickerView.title(.settings), "Tarif wechseln")
        XCTAssertEqual(PlanPickerView.title(.upgrade(.plus)), "Mehr mit Studora Plus")
        XCTAssertEqual(PlanPickerView.title(.upgrade(nil)), "Tarif wechseln")
        // VoiceOver liest Zusatz und Marke mit
        XCTAssertEqual(PlanPickerView.accessibilityLabel(UFPlanCardRow(title: "Uni & Noten", detail: "Notenspiegel", icon: "check")),
                       "Uni & Noten, Notenspiegel")
        XCTAssertEqual(PlanPickerView.accessibilityLabel(try XCTUnwrap(UFPlanCard.preparing(.proAI).first)),
                       "KI-Erklärungen zu Aufgaben, in Vorbereitung")

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
