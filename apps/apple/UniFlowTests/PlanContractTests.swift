import StoreKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Swift-Tabelle der StudiNow-Tarife (Plans.swift) gegen den gemeinsamen Vertrag
/// packages/shared-contracts/fixtures/plans/plans.json (aus app/plans.py, tools/gen-plans-fixture.py): Namen, Preise,
/// Produkte, Rechte je Tarif und Stand. Dazu die Regel des Inhabers vom 27.10.2026: als enthalten zeigt das iPad nur,
/// was im Vertrag `available` ist und auf dem Geraet bzw. mit StudiNow-Konto wirklich geht; was es auf dem iPad nicht
/// gibt, steht auf keiner Karte (07.11.2026: kein "in Vorbereitung").
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
            // Jahresabo (07.11.2026): eigenes Produkt, Preis unter 12 Monatszahlungen
            XCTAssertEqual(p["apple_product_id_yearly"]?.string, plan.productID(.yearly), plan.rawValue)
            XCTAssertEqual(int(p["price_cents_yearly"]), plan.yearlyPriceCents, plan.rawValue)
            if let y = plan.yearlyPriceCents { XCTAssertLessThan(y, 12 * plan.priceCents, plan.rawValue) }
            XCTAssertEqual(p["tagline"]?.string, plan.tagline, plan.rawValue)
            XCTAssertEqual(int(p["credits"]), plan.monthlyCredits, plan.rawValue)
        }
        XCTAssertEqual(int(c["credits"]?["pro_ai"]), UFPlan.proAI.monthlyCredits)
        // Reihenfolge = Rang, jeder hoehere Tarif kostet mehr
        XCTAssertEqual(UFPlan.allCases.map(\.rank), [0, 1, 2])
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
        // ChatGPT: die offizielle Anmeldung aus, keine Kopplung an einen Tarif (ABO-SYSTEM.md, Abschnitt 4); das Recht
        // selbst seit 07.11.2026 available (iPad: eigener OpenAI-Schluessel, PC: Sign in with ChatGPT lokal)
        XCTAssertEqual(c["integrations"]?["chatgpt"]?["status"]?.string, "disabled")
        XCTAssertEqual(c["integrations"]?["chatgpt"]?["plan_gating_allowed"]?.bool, false)
        XCTAssertEqual(UFEntitlement.chatgptConnectionPremium.status, .available)
        XCTAssertFalse(UFEntitlement.chatgptConnectionPremium.label.contains("Vorbereitung"))
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

    /// StoreKit-Konfigurationen: `UniFlow.storekit` (App) hat genau die Abo-Tarife des iPads (Plus, Pro AI); die
    /// Testkonfiguration `UniFlowAlleTarife.storekit` (Wechsel-Logik) alle Abo-Tarife des Vertrags in einer Gruppe.
    /// Stufen nach Rang (Stufe 1 = hoechster Tarif: Pro AI 1, Plus 2 in der App), monatlich, Gruppe "StudiNow", Namen
    /// wie im Vertrag, **kein Einfuehrungsangebot** (Entscheidung 04.11.2026: Probe auf dem iPad statt Apple-Angebot).
    func testStoreKitConfigurationsMatchContract() throws {
        let app = UFPlanCatalog.sellable.filter { $0.productID != nil }
        XCTAssertEqual(app, [.plus, .proAI], "das iPad verkauft StudiNow Plus und Pro AI (Entscheidung 04.11.2026)")
        XCTAssertEqual(PurchaseStore.productIDs, app.flatMap(\.productIDs))
        for (file, plans) in [("UniFlow", app), ("UniFlowAlleTarife", UFPlan.paid)] {
            let url = ContainerTestBed.repoURL("apps/apple/UniFlowTests/\(file).storekit")
            let sk = try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
            let groups = try XCTUnwrap(sk["subscriptionGroups"]?.array, file)
            XCTAssertEqual(groups.count, 1, "eine Abo-Gruppe, damit Apple Upgrade, Downgrade und Doppel-Abos regelt: \(file)")
            XCTAssertEqual(groups.first?["name"]?.string, "StudiNow", file)
            XCTAssertEqual(sk["products"]?.array?.count, 0, file)
            let subs = try XCTUnwrap(groups.first?["subscriptions"]?.array, file)
            // erst alle Monatsabos, dann alle Jahresabos (07.11.2026)
            let entries = UFBilling.allCases.flatMap { b in plans.map { ($0, b) } }
            XCTAssertEqual(subs.compactMap { $0["productID"]?.string }, entries.compactMap { $0.0.productID($0.1) }, file)
            // Stufe 1 = hoechster Tarif der Datei, dann absteigend (App: Pro AI 1, Plus 2); monatlich und jaehrlich
            // eines Tarifs auf derselben Stufe (Wechsel der Zahlweise gilt ab der naechsten Verlaengerung)
            let levels = Dictionary(uniqueKeysWithValues: plans.sorted(by: >).enumerated().map { ($1, $0 + 1) })
            for ((plan, billing), s) in zip(entries, subs) {
                let tag = "\(file): \(plan.rawValue) \(billing.rawValue)"
                let cents = billing == .monthly ? plan.priceCents : (plan.yearlyPriceCents ?? -1)
                XCTAssertEqual(s["displayPrice"]?.string, String(format: "%.2f", Double(cents) / 100), tag)
                XCTAssertEqual(int(s["groupNumber"]), levels[plan], "Stufe in der Gruppe: \(tag)")
                XCTAssertEqual(s["recurringSubscriptionPeriod"]?.string, billing == .monthly ? "P1M" : "P1Y", tag)
                XCTAssertNil(s["introductoryOffer"], "kein Apple-Einführungsangebot: \(tag)")
                XCTAssertEqual(s["localizations"]?.array?.first?["displayName"]?.string, plan.name, tag)
                // Grenzen von App Store Connect: Anzeigename 30, Beschreibung 45 Zeichen (docs/release/APP-STORE.md)
                XCTAssertLessThanOrEqual(plan.name.count, 30, tag)
                XCTAssertLessThanOrEqual(s["localizations"]?.array?.first?["description"]?.string?.count ?? 99, 45, tag)
                XCTAssertEqual(s["subscriptionGroupID"]?.string, groups.first?["id"]?.string, tag)
            }
        }
    }

    /// Was das iPad anbietet (Entscheidung des Inhabers vom 04.11.2026): StudiNow Free, Plus und Pro AI. Die Pro-AI-Karte
    /// nur mit Produkt aus dem Store (vor dem Dienst nur Free und Plus, darunter ein Satz ohne Preis); Pro Connect gibt
    /// es nicht mehr (alter Schluessel gilt wie Pro AI); ein laufender Tarif behaelt seine Karte.
    func testIPadSellsFreePlusAndProAI() {
        XCTAssertEqual(UFPlanCatalog.sellable, [.free, .plus, .proAI])
        XCTAssertEqual(UFPlanCatalog.sellableProductIDs, ["de.uniflow.plus.monthly", "de.uniflow.plus.yearly",
                                                          "de.uniflow.proai.monthly", "de.uniflow.proai.yearly"])
        XCTAssertEqual(UFPlanCatalog.needsProduct, [.proAI])
        XCTAssertEqual(UFPlanCatalog.proAIMissingNote, "StudiNow Pro AI folgt mit dem StudiNow-Dienst.")
        XCTAssertNil(UFPlanCatalog.proAIMissingNote.range(of: #"\d|€"#, options: .regularExpression), "kein Preis im Hinweis")
        let both: Set<String> = ["de.uniflow.plus.monthly", "de.uniflow.proai.monthly"]
        let plusOnly: Set<String> = ["de.uniflow.plus.monthly"]
        XCTAssertEqual(UFPlanCatalog.cards(current: .free, loaded: both), [.free, .plus, .proAI])
        XCTAssertEqual(UFPlanCatalog.cards(current: .free, loaded: plusOnly), [.free, .plus], "ohne Produkt keine Pro-AI-Karte")
        XCTAssertEqual(UFPlanCatalog.cards(current: .free, loaded: []), [.free, .plus], "Store nicht erreichbar: Karten ohne Preis")
        XCTAssertEqual(UFPlanCatalog.cards(current: .plus, loaded: plusOnly), [.free, .plus])
        XCTAssertEqual(UFPlanCatalog.cards(current: .proAI, loaded: plusOnly), [.free, .plus, .proAI], "wer Pro AI hat, sieht seine Karte")
        // Hinweis unter den Karten nur, wenn die Produkte geladen sind und Pro AI fehlt
        XCTAssertTrue(PlanPickerView.showsProAIMissingNote(loaded: plusOnly, loading: false, current: .free))
        XCTAssertFalse(PlanPickerView.showsProAIMissingNote(loaded: both, loading: false, current: .free))
        XCTAssertFalse(PlanPickerView.showsProAIMissingNote(loaded: plusOnly, loading: true, current: .free))
        XCTAssertFalse(PlanPickerView.showsProAIMissingNote(loaded: [], loading: false, current: .free), "Fehlerkarte sagt es schon")
        XCTAssertFalse(PlanPickerView.showsProAIMissingNote(loaded: plusOnly, loading: false, current: .proAI))
        // Konto-Hinweis nur auf der Pro-AI-Karte (07.11.2026), Credits wie im Vertrag
        XCTAssertEqual(UFPlanCatalog.serviceNote(.proAI), UFPlanCatalog.proAIServiceNote)
        XCTAssertEqual(UFPlanCatalog.proAIServiceNote, "Braucht ein StudiNow-Konto (Anmelden mit Apple). 100 Credits im Monat.")
        XCTAssertFalse(UFPlanCatalog.proAIServiceNote.contains("denselben Umfang"))
        XCTAssertNil(UFPlanCatalog.serviceNote(.plus))
        XCTAssertNil(UFPlanCatalog.serviceNote(.free))
        // drei Tarife (Entscheidung 04.11.2026)
        XCTAssertEqual(UFPlan.allCases.count, 3)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.proai.monthly"), .proAI)
        // Jahresabos gelten wie der Monatstarif (07.11.2026)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.proai.yearly"), .proAI)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.plus.yearly"), .plus)
        XCTAssertEqual(UFBilling(productID: "de.uniflow.plus.yearly"), .yearly)
        XCTAssertEqual(UFBilling(productID: "de.uniflow.proai.monthly"), .monthly)
        XCTAssertNil(UFBilling(productID: "de.uniflow.proconnect.monthly"))
        XCTAssertEqual(UFPlanCatalog.cards(current: .free, loaded: ["de.uniflow.proai.yearly"]), [.free, .plus, .proAI],
                       "Pro-AI-Karte auch, wenn nur das Jahresabo geliefert wird")
        XCTAssertEqual(UFOfferText.yearlySavingPercent(monthly: Decimal(string: "1.99")!, yearly: Decimal(string: "21.99")!), 7)
        XCTAssertEqual(UFOfferText.yearlySavingPercent(monthly: Decimal(string: "3.99")!, yearly: Decimal(string: "41.99")!), 12)
        XCTAssertNil(UFOfferText.yearlySavingPercent(monthly: Decimal(string: "1.99")!, yearly: Decimal(string: "29.99")!))
        XCTAssertEqual(UFOfferText.yearlyNote(perMonth: "1,83 €", saving: 7), "entspricht 1,83 €/Monat, 7 % günstiger als monatlich")
        // Texte der Seite nennen Pro AI nur mit Produkt
        let withProAI = PlanPickerView.subtitle(proAI: true)
        XCTAssertTrue(withProAI.contains(UFPlan.free.name) && withProAI.contains(UFPlan.plus.name) && withProAI.contains(UFPlan.proAI.name))
        XCTAssertTrue(withProAI.contains("über den StudiNow-Dienst"))
        XCTAssertFalse(PlanPickerView.subtitle(proAI: false).contains("Pro"))
        XCTAssertTrue(PlanPickerView.legalText.contains("höheren Tarif"), "zwei Abo-Tarife in einer Gruppe: Wechselregel steht dabei")
        XCTAssertTrue(PlanPickerView.legalText.contains("24 Stunden"))
    }

    /// Probe auf dem iPad wie `trial` im Vertrag (plans.TRIAL im Dienst): 7 Tage, Tarif Pro AI
    func testLocalTrialMatchesContract() throws {
        let c = try contract()
        XCTAssertEqual(int(c["trial"]?["days"]), UFLocalTrial.days)
        XCTAssertEqual(c["trial"]?["plan"]?.string, UFLocalTrial.plan.rawValue)
        XCTAssertEqual(UFLocalTrial.length, 7 * 86_400)
        // "Probe: alles wie Pro AI, 25 Credits" (Entscheidung 04.11.2026): Zahl wie im Vertrag
        XCTAssertEqual(int(c["trial"]?["credits"]), UFTrialTexts.credits)
        XCTAssertTrue(UFTrialTexts.offerProAI.contains("alles wie StudiNow Pro AI, mit \(UFTrialTexts.credits) Credits"))
        XCTAssertEqual(UFTrialBannerContent.running(daysLeft: 3, source: .service).text, UFTrialTexts.runningTextService)
        XCTAssertTrue(UFTrialTexts.runningTextService.hasPrefix("Alles wie StudiNow Pro AI, mit \(UFTrialTexts.credits) Credits"))
        // ohne Dienst (kein Pro-AI-Produkt) nennt die Probe Pro AI und Credits nicht
        XCTAssertFalse(UFTrialTexts.offer.contains("Pro AI") || UFTrialTexts.runningText.contains("Credits"))
    }

    /// Pflichtlinks (Richtlinie 3.1.2) und Support: die Tarifseite und die Einstellungen oeffnen die oeffentlichen Seiten
    /// auf studinow.app (docs/release, site/), dieselben Adressen wie Support-URL und Datenschutz-URL in App Store
    /// Connect (docs/release/APP-STORE.md); nur https, Postfach support@studinow.app (Angaben des Inhabers, 03.11.2026).
    func testLegalLinksPointToTheStudiNowSite() {
        XCTAssertEqual(UFLegalLinks.site.absoluteString, "https://studinow.app")
        XCTAssertEqual(UFLegalLinks.terms.absoluteString, "https://studinow.app/nutzungsbedingungen")
        XCTAssertEqual(UFLegalLinks.privacy.absoluteString, "https://studinow.app/datenschutz")
        XCTAssertEqual(UFLegalLinks.imprint.absoluteString, "https://studinow.app/impressum")
        XCTAssertEqual(UFLegalLinks.support.absoluteString, "https://studinow.app/support")
        XCTAssertEqual(UFLegalLinks.deleteAccount.absoluteString, "https://studinow.app/konto-loeschen")
        XCTAssertEqual(UFLegalLinks.supportEmail, "support@studinow.app")
        XCTAssertEqual(UFLegalLinks.supportMail.absoluteString, "mailto:support@studinow.app")
        for url in UFLegalLinks.all {
            XCTAssertEqual(url.scheme, "https", url.absoluteString)
            XCTAssertEqual(url.host, "studinow.app", url.absoluteString)
        }
        // Tarifseite: beide Pflichtseiten, Texte und Ziele passen zusammen
        XCTAssertEqual(PlanPickerView.LegalPage.allCases.map(\.rawValue), ["Nutzungsbedingungen", "Datenschutzerklärung"])
        XCTAssertEqual(PlanPickerView.LegalPage.terms.url, UFLegalLinks.terms)
        XCTAssertEqual(PlanPickerView.LegalPage.privacy.url, UFLegalLinks.privacy)
        XCTAssertTrue(UFLegalLinks.settingsIntro.contains("support@studinow.app") && UFLegalLinks.settingsIntro.contains("studinow.app"))
    }

    // MARK: Umsetzung auf dem iPad

    /// Jedes Recht ist auf dem Geraet umgesetzt, mit StudiNow-Konto ueber den Dienst (StudiNow-KI, Notizen-Abgleich)
    /// oder auf dem iPad nicht gebaut; umgesetzt immer ab genau dem Tarif aus dem Vertrag (keine Abweichung des iPads,
    /// Entscheidung 28.10.2026).
    func testEveryContractRightIsOnDeviceWithAccountOrHidden() {
        XCTAssertEqual(UFEntitlement.canReadCommunity.onDevice, .onDevice([.communityRead]))
        // Entscheidung 05.11.2026: Community ab Plus, eigenes ChatGPT in jedem Tarif (07.11.2026: ueber den eigenen
        // OpenAI-Schluessel, `UFFeature.ownChatGPT`)
        XCTAssertEqual(UFEntitlement.canReadCommunity.from, .plus)
        XCTAssertEqual(UFFeature.communityRead.minimumPlan, .plus)
        XCTAssertEqual(UFEntitlement.chatgptConnectionPremium.from, .free)
        XCTAssertEqual(UFEntitlement.chatgptConnectionPremium.onDevice, .onDevice([.ownChatGPT]))
        XCTAssertTrue(UFEntitlement.chatgptConnectionPremium.availableOnDevice)
        XCTAssertEqual(UFEntitlement.canShareSolutions.onDevice, .onDevice([.shareSolutions]))
        // eigene Karteikarten (04.11.2026): Recht des Vertrags ab Plus, auf dem iPad die Funktion `flashcards`
        XCTAssertEqual(UFEntitlement.canUseFlashcards.onDevice, .onDevice([.flashcards]))
        XCTAssertEqual(UFEntitlement.canUseFlashcards.from, .plus)
        XCTAssertEqual(UFEntitlement.canUseFlashcards.label, UFFeature.flashcards.title)
        // Pro AI mit StudiNow-Konto (07.11.2026): StudiNow-KI und Notizen-Abgleich
        XCTAssertEqual(UFEntitlement.canUseAIExplanations.onDevice, .withAccount([.aiHelp]))
        XCTAssertEqual(UFEntitlement.canUseAISummaries.onDevice, .withAccount([.aiHelp]))
        XCTAssertEqual(UFEntitlement.canUseAIGeneratedQuestions.onDevice, .withAccount([.aiFlashcards, .weeklyTests]))
        XCTAssertEqual(UFEntitlement.canSyncAnnotations.onDevice, .withAccount([.deviceSync]))
        for e in UFEntitlement.allCases {
            switch e.onDevice {
            case .onDevice(let features), .withAccount(let features):
                XCTAssertFalse(features.isEmpty, e.rawValue)
                XCTAssertEqual(features, e.deviceFeatures, e.rawValue)
                XCTAssertEqual(e.status, .available, "umgesetzt, aber im Vertrag nicht available: \(e.rawValue)")
                XCTAssertTrue(e.availableOnDevice, e.rawValue)
                let iPadFrom = features.map(\.minimumPlan).max()
                XCTAssertEqual(iPadFrom, e.from, e.rawValue)
                for f in features {
                    XCTAssertFalse(f.isV2, "\(e.rawValue): \(f.rawValue)")
                    XCTAssertEqual(UFFeatureMatrix.access(f, plan: .proAI), .allowed, "\(e.rawValue): \(f.rawValue)")
                }
                if case .withAccount = e.onDevice { XCTAssertEqual(e.from, .proAI, "mit Konto nur die Pro-AI-Rechte: \(e.rawValue)") }
            case .needsService:
                XCTAssertFalse(e.availableOnDevice, e.rawValue)
                XCTAssertTrue(e.deviceFeatures.isEmpty, e.rawValue)
            }
        }
        // auf dem iPad nicht gebaut: Testbibliothek, KI-Tests von StudiNow, Lernstatistik/Empfehlungen, Testliste,
        // fertige Wochenfragen der Bibliothek, Kommentare ueber den Dienst
        let hidden: [UFEntitlement] = [.canUseAIRecommendations, .canGenerateStudoraAITests, .canAccessSharedTests,
                                       .canUseAdvancedAnalytics, .canUseAdvancedPlanner, .canGetRecommendations,
                                       .canReviewWrongAnswers, .canUseExtendedTestHistory,
                                       .canUsePreparedWeekSets, .canWriteCommunityComments]
        for e in hidden { XCTAssertEqual(e.onDevice, .needsService, e.rawValue) }
        // Kommentare sind im Vertrag seit PC d0d1c74 available, laufen aber ueber den Dienst (G4); das iPad V1 mit
        // CloudKit-Community gibt sie nicht als vorhanden aus (Umstellung D15)
        XCTAssertEqual(UFEntitlement.canWriteCommunityComments.status, .available)
        XCTAssertFalse(UFEntitlement.canWriteCommunityComments.availableOnDevice)
    }

    /// Pro AI enthaelt alles aus Plus; dazu kommen die StudiNow-KI (KI-Hilfe, KI-Karteikarten, Wochentests) und der
    /// Notizen-Abgleich (07.11.2026, Wochentests vorher Plus mit dem eigenen ChatGPT, das aus ist)
    func testProPlansContainEverythingFromPlus() {
        for f in UFFeature.allCases where f.minimumPlan <= .plus {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .proAI), UFFeatureMatrix.access(f, plan: .plus), f.rawValue)
        }
        for f: UFFeature in [.pencilWriting, .communityRead, .shareSolutions, .splitView, .flashcards, .autoPlan] {
            XCTAssertEqual(f.minimumPlan, .plus, f.rawValue)
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .free), .locked(.plus), f.rawValue)
        }
        let pro: [UFFeature] = [.aiHelp, .aiFlashcards, .weeklyTests, .deviceSync]
        XCTAssertEqual(UFFeature.allCases.filter { $0.minimumPlan == .proAI }, pro)
        for f in pro {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .proAI), .allowed, f.rawValue)
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .plus), .locked(.proAI), f.rawValue)
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .free), .locked(.proAI), f.rawValue)
        }
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .proAI), UFNoteAccess(canView: true, canExport: true, canEdit: true))
    }

    // MARK: Tarifkarten

    /// Karten (App Review 07.11.2026): Free und Plus ohne KI, Pro AI mit den gebauten KI-Funktionen; das eigene ChatGPT
    /// (eigener OpenAI-Schluessel, 07.11.2026) steht ehrlich auf der Free-Karte ("in jedem Tarif"); nichts
    /// "in Vorbereitung", nichts, was es auf dem iPad nicht gibt
    func testPlanCardsListOnlyWhatWorks() {
        XCTAssertEqual(UFPlanCard.included(.free).map(\.title),
                       [UFFeature.studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .studyPlanning,
                        .viewNotes, .uniGrades, .ownChatGPT].map(\.title))
        XCTAssertEqual(UFPlanCard.included(.plus).map(\.title),
                       ["Schreiben mit Apple Pencil", "Community lesen, beitreten und mitmachen", "Eigene Lösungen teilen",
                        "Übung und Skript nebeneinander", "Eigene Karteikarten mit Wiederholung", "Lernplan automatisch erstellen"])
        // Free (07.11.2026): Lernkalender von Hand, der automatische Lernplan gehoert zu Plus
        XCTAssertFalse((UFPlanCard.included(.free).map { $0.title + " " + ($0.detail ?? "") }).joined().contains("automatisch"))
        XCTAssertEqual(UFPlanCard.included(.plus).last?.detail, "Lernslots in deinen freien Zeiten")
        XCTAssertEqual(UFPlanCard.included(.proAI).map(\.title),
                       ["KI-Hilfe zu deinen Unterlagen", "Karteikarten aus deinen Unterlagen", "Wochentests erstellen",
                        "Notizen auf allen deinen Geräten"])
        let help = try? XCTUnwrap(UFPlanCard.included(.proAI).first)
        XCTAssertTrue(help?.detail?.contains("„Ganze Vorlesung erklären“") == true)
        XCTAssertTrue(help?.detail?.contains("„Alle Aufgaben erklären“") == true)
        XCTAssertFalse(UFPlanCard.included(.free).contains { $0.title.contains("Community") }, "Free ohne Community")

        // was es auf dem iPad nicht gibt, steht auf keiner Karte; "ChatGPT" nur in der Zeile des eigenen Schluessels
        let forbidden = #"Vorbereitung|Statistik|Bibliothek|Empfehlung|Lernplanung \(|Testliste|Vorlesungswoche|denselben Umfang"#
        for plan in UFPlan.allCases {
            for r in UFPlanCard.included(plan) {
                XCTAssertNil((r.title + " " + (r.detail ?? "")).range(of: forbidden, options: .regularExpression), r.title)
                if r.title != UFFeature.ownChatGPT.title { XCTAssertFalse((r.title + " " + (r.detail ?? "")).contains("ChatGPT"), r.title) }
                if plan != .proAI {
                    XCTAssertNil((r.title + " " + (r.detail ?? "")).range(of: #"\bKI\b|KI-|allen deinen Geräten"#, options: .regularExpression),
                                 "KI und Abgleich gehoeren zu Pro AI: \(r.title)")
                }
            }
            // jedes Recht ab diesem Tarif, das auf dem iPad geht, steht auf der Karte; die anderen nicht
            let titles = UFPlanCard.included(plan).map(\.title)
            for e in UFEntitlement.allCases where e.from == plan {
                for f in e.deviceFeatures { XCTAssertTrue(titles.contains(f.title), "\(e.rawValue): \(f.rawValue)") }
                if e.deviceFeatures.isEmpty { XCTAssertFalse(titles.contains(e.label), e.rawValue) }
            }
            for t in [UFPlanCard.tagline(plan), UFPlanCard.intro(plan), UFPlanCatalog.serviceNote(plan)].compactMap({ $0 }) {
                XCTAssertNil(t.range(of: forbidden, options: .regularExpression), t)
            }
        }
    }

    func testPlanCardTextsAreHonest() throws {
        XCTAssertEqual(UFPlanCard.intro(.free), "Alles für den Uni-Alltag:")
        XCTAssertEqual(UFPlanCard.intro(.plus), "Alles aus StudiNow Free, dazu:")
        XCTAssertEqual(UFPlanCard.intro(.proAI), "Alles aus StudiNow Plus, dazu:")
        // Kurzbeschreibung der Karten: Plus ohne Wochentests (gehoeren zu Pro AI), Pro AI ohne ChatGPT
        XCTAssertEqual(UFPlanCard.tagline(.free), UFPlan.free.tagline)
        XCTAssertEqual(UFPlanCard.tagline(.plus), "Mit Apple Pencil auf deinen Unterlagen schreiben, Karteikarten und Community")
        XCTAssertEqual(UFPlanCard.tagline(.proAI), "Die StudiNow-KI für deine Unterlagen inklusive")
        // Seitenkopf nie "gratis" (kein Einfuehrungsangebot); die Probe steht in eigener Zeile (testTrialStatusOnPlanPage)
        XCTAssertFalse(PlanPickerView.subtitle(proAI: true).contains("gratis"))
        XCTAssertFalse(PlanPickerView.subtitle(proAI: true).contains("Probe"))
        XCTAssertEqual(PlanPickerView.title(.onboarding), "Tarif wählen")
        XCTAssertEqual(PlanPickerView.title(.settings), "Tarif wechseln")
        XCTAssertEqual(PlanPickerView.title(.upgrade(.plus)), "Mehr mit StudiNow Plus")
        XCTAssertEqual(PlanPickerView.title(.upgrade(nil)), "Tarif wechseln")
        // VoiceOver liest den Zusatz mit
        XCTAssertEqual(PlanPickerView.accessibilityLabel(UFPlanCardRow(title: "Uni & Noten", detail: "Notenspiegel", icon: "check")),
                       "Uni & Noten, Notenspiegel")
        XCTAssertEqual(PlanPickerView.accessibilityLabel(UFPlanCardRow(title: "Stundenplan", icon: "check")), "Stundenplan")
    }

    /// Probe auf dem iPad (07.11.2026): oben "Probe aktiv: alle Funktionen von StudiNow Pro AI bis … (noch n Tage)",
    /// ehrlich zur KI (StudiNow-Konto, 25 Credits beim Dienst); keine Karte "Aktueller Tarif", auch Free nicht; die
    /// Probe schaltet alles wie Pro AI frei, danach Free
    func testTrialStatusOnPlanPage() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-07T10:00:00Z"))
        let t = UFLocalTrial.state(startedAt: start, now: start)
        let s = PlanPickerView.trialStatus(t, proAI: true)
        XCTAssertEqual(s.title, "Probe aktiv: alle Funktionen von StudiNow Pro AI bis 14.11.2026 (noch 7 Tage)")
        XCTAssertTrue(s.note.contains("StudiNow-Konto (Anmelden mit Apple)"), s.note)
        XCTAssertTrue(s.note.contains("25 Credits"), s.note)
        XCTAssertTrue(s.note.contains("Danach gilt StudiNow Free"), s.note)
        XCTAssertFalse(s.note.contains("ChatGPT") || s.note.contains("gratis"), s.note)
        let last = UFLocalTrial.state(startedAt: start, now: start.addingTimeInterval(6.5 * 86_400))
        XCTAssertEqual(PlanPickerView.trialStatus(last, proAI: true).title, "Probe aktiv: alle Funktionen von StudiNow Pro AI bis 14.11.2026 (noch 1 Tag)")
        // ohne Pro-AI-Produkt im Store weder Pro AI noch KI
        let plain = PlanPickerView.trialStatus(t, proAI: false)
        XCTAssertEqual(plain.title, "Probe aktiv: alle Funktionen bis 14.11.2026 (noch 7 Tage)")
        XCTAssertFalse(plain.note.contains("KI") || plain.note.contains("Pro AI"), plain.note)
        // "Aktueller Tarif": waehrend der Probe ohne Kauf keiner; mit Kauf der gekaufte
        for p in UFPlan.allCases {
            XCTAssertFalse(PlanPickerView.isCurrent(p, purchased: .free, loading: false, trial: true), p.rawValue)
        }
        XCTAssertTrue(PlanPickerView.isCurrent(.free, purchased: .free, loading: false, trial: false))
        XCTAssertTrue(PlanPickerView.isCurrent(.plus, purchased: .plus, loading: false, trial: true))
        XCTAssertFalse(PlanPickerView.isCurrent(.free, purchased: .free, loading: true, trial: false))
        // Probe = Pro AI: alle Funktionen des iPads frei, danach Free
        XCTAssertEqual(UFLocalTrial.plan, .proAI)
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .free, localTrial: t), .proAI)
        let over = UFLocalTrial.state(startedAt: start, now: start.addingTimeInterval(8 * 86_400))
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .free, localTrial: over), .free)
        for f in UFFeature.allCases where !f.isV2 && (f != .timer || StudyTimer.isEnabled) {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: UFLocalTrial.plan), .allowed, f.rawValue)
        }
    }

    @MainActor
    func testRunningLocalTrialOnlyWithoutPurchase() {
        let ent = Entitlements(observe: false, plan: .free)
        let now = Date()
        ent.useLocalTrial(startedAt: now, now: now)
        XCTAssertEqual(ent.plan, .proAI, "Probe: alles wie Pro AI")
        XCTAssertEqual(ent.runningLocalTrial?.daysLeft, 7)
        ent.useLocalTrial(startedAt: now.addingTimeInterval(-8 * 86_400), now: now)
        XCTAssertNil(ent.runningLocalTrial, "nach der Probe")
        XCTAssertEqual(ent.plan, .free)
        ent.useLocalTrial(startedAt: nil)
        XCTAssertNil(ent.runningLocalTrial)
    }

    // MARK: Verknuepfung mit dem Dienst

    /// Ohne angemeldetes StudiNow-Konto ruft die App den Dienst nicht auf: keine Kaufoption (kein appAccountToken), kein
    /// Pruef-Haken am gemeinsamen Tarif. Die Form der Anfrage an /api/billing/apple/verify steht fest.
    @MainActor
    func testServiceLinkIsOnButOnlyWithAnAccount() throws {
        // seit 05.11.2026 eingeschaltet (StudiNow-KI ueber Pro AI): Kaufoption nur mit Konto-Token, Meldung nur mit Anmeldung
        XCTAssertTrue(UFBillingServiceLink.isEnabled)
        XCTAssertNil(Entitlements.shared.verifyOnServer, "ohne angemeldetes Konto kein Pruef-Haken")
        let token = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        XCTAssertTrue(UFBillingServiceLink.purchaseOptions(accountToken: nil).isEmpty, "ohne Konto keine Kaufoption")
        XCTAssertTrue(UFBillingServiceLink.purchaseOptions(accountToken: token, enabled: false).isEmpty)
        XCTAssertNil(UFBillingServiceLink.verifyRequest(base: URL(string: "https://dienst.example")!, signedTransaction: "a.b.c", enabled: false))

        // Form (wie app/billing_api.py sie erwartet)
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
