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
            // neues Tarifmodell (26.11.2026): Plus 1,99 € im Monat, Pro AI 39,99 € im Jahr, Free ohne Zeitraum
            XCTAssertEqual(p["period"]?.string, plan.period, plan.rawValue)
            if plan == .free {
                XCTAssertEqual(p["apple_product_id"]?.isNull, true)
            }
            XCTAssertEqual(p["apple_product_id"]?.string, plan.productID, plan.rawValue)
            XCTAssertNil(p["apple_product_id_yearly"], "kein eigenes Feld fuer das Jahresabo mehr: \(plan.rawValue)")
            XCTAssertNil(p["price_cents_yearly"], plan.rawValue)
            XCTAssertEqual(p["tagline"]?.string, plan.tagline, plan.rawValue)
            XCTAssertEqual(int(p["credits"]), plan.monthlyCredits, plan.rawValue)
            XCTAssertEqual(p["sellable"]?.bool, plan != .free, "verkauft werden Plus und Pro AI: \(plan.rawValue)")
        }
        XCTAssertEqual(int(c["credits"]?["pro_ai"]), UFPlan.proAI.monthlyCredits)
        XCTAssertEqual(UFPlan.proAI.monthlyCredits, 120, "Pro AI: 120 Credits je Monat (26.11.2026)")
        XCTAssertEqual(UFPlan.plus.monthlyCredits, 0)
        XCTAssertEqual(UFPlan.allCases.map(\.rank), [0, 1, 2])
        XCTAssertEqual(UFPlan.allCases.map(\.priceCents), [0, 199, 3999], "Plus 1,99 € im Monat, Pro AI 39,99 € im Jahr (26.11.2026)")
        XCTAssertEqual(UFPlan.allCases.map(\.period), [nil, "month", "year"])
    }

    /// Angebote je Apple-Produkt (plans.json `offers`, 26.11.2026): Reihenfolge, Tarif, Art, Preis, Zeitraum bzw. Jahre, Text
    func testOffersMatchContract() throws {
        let offers = try XCTUnwrap(contract()["offers"]?.array)
        XCTAssertEqual(offers.compactMap { $0["product_id"]?.string }, UFOffer.allCases.map(\.productID))
        XCTAssertEqual(UFOffer.allCases.map(\.productID), ["de.uniflow.plus.monthly", "de.uniflow.proai.monthly", "de.uniflow.proai.yearly",
                                                           "de.uniflow.plus.fuenfjahre"])
        for (o, offer) in zip(offers, UFOffer.allCases) {
            let tag = offer.productID
            XCTAssertEqual(o["plan"]?.string, offer.plan.rawValue, tag)
            XCTAssertEqual(o["kind"]?.string, offer.kind.rawValue, tag)
            XCTAssertEqual(int(o["price_cents"]), offer.priceCents, tag)
            XCTAssertEqual(o["period"]?.string, offer.period, tag)
            XCTAssertEqual(int(o["years"]), offer.years, tag)
            XCTAssertEqual(o["label"]?.string, offer.label, tag)
            XCTAssertEqual(UFPlan(productID: offer.productID), offer.plan, tag)
            // Bereich, Name, Abzeichen, Hervorhebung, Vergleich und Ersparnis (27.11.2026)
            XCTAssertEqual(o["group"]?.string, offer.group.rawValue, tag)
            XCTAssertEqual(o["name"]?.string, offer.name, tag)
            XCTAssertEqual(o["badge"]?.string, offer.badge, tag)
            XCTAssertEqual(o["highlight"]?.bool ?? false, offer.highlight, tag)
            XCTAssertEqual(o["compare"]?.string, offer.compare?.productID, tag)
            if let s = offer.savings {
                let c = try XCTUnwrap(o["savings"]?.object, tag)
                XCTAssertEqual(int(c["months"]), s.months, tag)
                XCTAssertEqual(int(c["regular_cents"]), s.regularCents, tag)
                XCTAssertEqual(int(c["saved_cents"]), s.savedCents, tag)
                XCTAssertEqual(int(c["saved_percent"]), s.savedPercent, tag)
                XCTAssertEqual(int(c["per_month_cents"]), s.perMonthCents, tag)
                XCTAssertEqual(c["text"]?.string, s.text, tag)
                XCTAssertEqual(c["per_month_text"]?.string, s.perMonthText, tag)
            } else {
                XCTAssertNil(o["savings"]?.object, tag)
            }
        }
        XCTAssertEqual(UFOffer.plusFiveYears.kind, .nonRenewing)
        XCTAssertEqual(UFPlan.plus.offers, [.plusMonthly, .plusFiveYears])
        XCTAssertEqual(UFPlan.proAI.offers, [.proAIMonthly, .proAIYearly])
        // Bereiche der Tarifseite wie `offer_groups`
        let groups = try XCTUnwrap(contract()["offer_groups"]?.array)
        XCTAssertEqual(groups.compactMap { $0["key"]?.string }, UFOfferGroup.allCases.map(\.rawValue))
        XCTAssertEqual(groups.compactMap { $0["title"]?.string }, UFOfferGroup.allCases.map(\.title))
    }

    func testEntitlementsMatchContract() throws {
        let c = try contract()
        let rights = try XCTUnwrap(c["entitlements"]?.object)
        XCTAssertEqual(Set(rights.keys), Set(UFEntitlement.allCases.map(\.rawValue)))
        for e in UFEntitlement.allCases {
            let r = try XCTUnwrap(rights[e.rawValue], e.rawValue)
            XCTAssertEqual(r["from"]?.string, e.from.rawValue, e.rawValue)
            // am Mac ("Designed for iPad") nennt die App Maus und Trackpad statt des Apple Pencil (`UFDevice.adapt`)
            XCTAssertEqual(r["label"]?.string.map { UFDevice.adapt($0) }, e.label, e.rawValue)
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

    /// StoreKit-Konfigurationen: `UniFlow.storekit` (App) hat genau die Abo-Tarife des iPads (Plus monatlich, Pro AI
    /// jaehrlich) in einer Gruppe und Plus 5 Jahre als nicht verlaengerndes Abo (26.11.2026); die Testkonfiguration
    /// `UniFlowAlleTarife.storekit` (Wechsel-Logik) dasselbe. Stufen nach Rang (Stufe 1 = hoechster Tarif: Pro AI 1,
    /// Plus 2), Gruppe "StudiNow", Namen wie im Vertrag, **kein Einfuehrungsangebot** (Probe auf dem iPad statt Apple-Angebot).
    func testStoreKitConfigurationsMatchContract() throws {
        let app = UFPlanCatalog.sellable.filter { $0.productID != nil }
        XCTAssertEqual(app, [.plus, .proAI], "das iPad verkauft StudiNow Plus und Pro AI (Entscheidung 04.11.2026)")
        XCTAssertEqual(PurchaseStore.productIDs, UFOffer.allCases.map(\.productID))
        for (file, plans) in [("UniFlow", app), ("UniFlowAlleTarife", UFPlan.paid)] {
            let url = ContainerTestBed.repoURL("apps/apple/UniFlowTests/\(file).storekit")
            let sk = try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
            let groups = try XCTUnwrap(sk["subscriptionGroups"]?.array, file)
            XCTAssertEqual(groups.count, 1, "eine Abo-Gruppe, damit Apple Upgrade, Downgrade und Doppel-Abos regelt: \(file)")
            XCTAssertEqual(groups.first?["name"]?.string, "StudiNow", file)
            // dazu die zwei Credit-Pakete als Verbrauchskaeufe (15.11.2026, `CreditPacks`): Produkt, Groesse und
            // Listenpreis wie im Vertrag (plans.json `credit_packs.packs`); die App zeigt den Preis aus dem Store
            let packs = try XCTUnwrap(sk["products"]?.array, file)
            let contractPacks = try XCTUnwrap(contract()["credit_packs"]?["packs"]?.array, file)
            XCTAssertEqual(packs.compactMap { $0["productID"]?.string }, CreditPacks.productIDs, file)
            XCTAssertEqual(contractPacks.compactMap { $0["product_id"]?.string }, CreditPacks.productIDs, file)
            for (p, c) in zip(packs, contractPacks) {
                let tag = "\(file): \(p["productID"]?.string ?? "?")"
                XCTAssertEqual(p["type"]?.string, "Consumable", tag)
                XCTAssertEqual(p["displayPrice"]?.string, String(format: "%.2f", (c["price_cents"]?.double ?? 0) / 100), tag)
                XCTAssertEqual(p["localizations"]?.array?.first?["displayName"]?.string, CreditText.packLabel(Int(c["credits"]?.double ?? 0)), tag)
                XCTAssertLessThanOrEqual(p["localizations"]?.array?.first?["description"]?.string?.count ?? 99, 45, tag)
                XCTAssertEqual(p["familyShareable"]?.bool, false, tag)
            }
            XCTAssertEqual(contractPacks.compactMap { $0["credits"]?.double.map { Int($0) } }, CreditPacks.defaultPacks.map(\.credits), file)
            let subs = try XCTUnwrap(groups.first?["subscriptions"]?.array, file)
            // die Abos der Gruppe: Plus monatlich, Pro AI monatlich und jaehrlich (27.11.2026)
            let autos = UFOffer.allCases.filter { $0.kind == .autoRenewable && plans.contains($0.plan) }
            XCTAssertEqual(subs.compactMap { $0["productID"]?.string }, autos.map(\.productID), file)
            // Plus 5 Jahre: nicht verlaengerndes Abo ausserhalb der Gruppe, Preis wie im Vertrag
            let once = try XCTUnwrap(sk["nonRenewingSubscriptions"]?.array, file)
            XCTAssertEqual(once.compactMap { $0["productID"]?.string }, [UFOffer.plusFiveYears.productID], file)
            XCTAssertEqual(once.first?["type"]?.string, "NonRenewingSubscription", file)
            XCTAssertEqual(once.first?["displayPrice"]?.string, String(format: "%.2f", Double(UFOffer.plusFiveYears.priceCents) / 100), file)
            XCTAssertLessThanOrEqual(once.first?["localizations"]?.array?.first?["description"]?.string?.count ?? 99, 45, file)
            XCTAssertLessThanOrEqual(once.first?["localizations"]?.array?.first?["displayName"]?.string?.count ?? 99, 30, file)
            // Stufe 1 = hoechster Tarif der Datei, dann absteigend (App: Pro AI 1, Plus 2)
            let levels = Dictionary(uniqueKeysWithValues: plans.sorted(by: >).enumerated().map { ($1, $0 + 1) })
            for (offer, s) in zip(autos, subs) {
                let plan = offer.plan
                let tag = "\(file): \(offer.productID)"
                XCTAssertEqual(s["displayPrice"]?.string, String(format: "%.2f", Double(offer.priceCents) / 100), tag)
                // Pro AI monatlich und jaehrlich auf derselben Stufe (Wechsel zwischen ihnen = gleicher Tarif)
                XCTAssertEqual(int(s["groupNumber"]), levels[plan], "Stufe in der Gruppe: \(tag)")
                XCTAssertEqual(s["recurringSubscriptionPeriod"]?.string, offer.period == "month" ? "P1M" : "P1Y", tag)
                XCTAssertNil(s["introductoryOffer"], "kein Apple-Einführungsangebot: \(tag)")
                XCTAssertEqual(s["localizations"]?.array?.first?["displayName"]?.string, plan.name, tag)
                // Grenzen von App Store Connect: Anzeigename 30, Beschreibung 45 Zeichen (docs/release/APP-STORE.md)
                XCTAssertLessThanOrEqual(plan.name.count, 30, tag)
                XCTAssertLessThanOrEqual(s["localizations"]?.array?.first?["description"]?.string?.count ?? 99, 45, tag)
                XCTAssertEqual(s["subscriptionGroupID"]?.string, groups.first?["id"]?.string, tag)
            }
        }
    }

    /// Was das iPad anbietet (Entscheidung des Inhabers vom 26.11.2026): StudiNow Free, Plus und Pro AI. Die Pro-AI-Karte
    /// nur mit Produkt aus dem Store (vor dem Dienst nur Free und Plus, darunter ein Satz ohne Preis); Pro Connect gibt
    /// es nicht mehr (alter Schluessel gilt wie Pro AI); ein laufender Tarif behaelt seine Karte.
    func testIPadSellsFreePlusAndProAI() {
        XCTAssertEqual(UFPlanCatalog.sellable, [.free, .plus, .proAI])
        XCTAssertEqual(UFPlanCatalog.sellableProductIDs, ["de.uniflow.plus.monthly", "de.uniflow.proai.monthly", "de.uniflow.proai.yearly",
                                                          "de.uniflow.plus.fuenfjahre"])
        XCTAssertEqual(UFPlanCatalog.needsProduct, [.proAI])
        XCTAssertEqual(UFPlanCatalog.proAIMissingNote, "StudiNow Pro AI konnte gerade nicht aus dem App Store geladen werden. Öffne die Seite später noch einmal.")
        for later in ["folgt", "kommt später", "bald", "in Vorbereitung"] {
            XCTAssertFalse(UFPlanCatalog.proAIMissingNote.contains(later), "Pro AI wird mit 1.0 verkauft: kein „\(later)“")
        }
        XCTAssertNil(UFPlanCatalog.proAIMissingNote.range(of: #"\d|€"#, options: .regularExpression), "kein Preis im Hinweis")
        let both: Set<String> = ["de.uniflow.plus.monthly", "de.uniflow.proai.yearly"]
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
        // Konto-Hinweis auf der Pro-AI-Karte mit den Credits wie im Vertrag; Plus: die KI mit gekauften Credits (26.11.2026)
        XCTAssertEqual(UFPlanCatalog.serviceNote(.proAI), UFPlanCatalog.proAIServiceNote)
        XCTAssertEqual(UFPlanCatalog.proAIServiceNote, "Braucht ein StudiNow-Konto (Anmelden mit Apple). 120 Credits im Monat, am 1. neu aufgeladen, weitere Credits zum Nachkaufen.")
        XCTAssertFalse(UFPlanCatalog.proAIServiceNote.contains("denselben Umfang"))
        XCTAssertEqual(UFPlanCatalog.serviceNote(.plus), UFPlanCatalog.plusServiceNote)
        XCTAssertTrue(UFPlanCatalog.plusServiceNote.contains("Credits"))
        XCTAssertNil(UFPlanCatalog.serviceNote(.free))
        // drei Tarife (Entscheidung 04.11.2026)
        XCTAssertEqual(UFPlan.allCases.count, 3)
        // fruehere Produkte gelten weiter wie ihr Tarif (plans.LEGACY_PRODUCTS): Plus-Jahresabo 19,99 € (bis 26.11.2026),
        // Pro Connect; angeboten werden sie nicht mehr. Pro AI monatlich ist seit 27.11.2026 wieder ein Angebot
        XCTAssertEqual(UFPlan(productID: "de.uniflow.proai.monthly"), .proAI)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.proai.yearly"), .proAI)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.plus.yearly"), .plus, "frueheres Jahres-Plus gilt weiter als Plus")
        XCTAssertEqual(UFPlan(productID: "de.uniflow.plus.monthly"), .plus)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.plus.fuenfjahre"), .plus)
        XCTAssertEqual(UFPlan(productID: "de.uniflow.proconnect.monthly"), .proAI)
        XCTAssertNil(UFOffer(productID: "de.uniflow.plus.yearly"), "nicht mehr angeboten")
        XCTAssertEqual(UFOffer(productID: "de.uniflow.proai.monthly"), .proAIMonthly, "wieder angeboten (27.11.2026)")
        XCTAssertFalse(UFPlanCatalog.sellableProductIDs.contains("de.uniflow.plus.yearly"))
        XCTAssertEqual(UFPlanCatalog.cards(current: .free, loaded: ["de.uniflow.proai.monthly"]), [.free, .plus, .proAI],
                       "Pro AI monatlich allein bringt die Pro-AI-Karte")
        XCTAssertEqual(UFOfferText.yearlyNote(perMonth: "3,33 €"), "entspricht 3,33 € im Monat")
        // Texte der Seite nennen Pro AI nur mit Produkt
        let withProAI = PlanPickerView.subtitle(proAI: true)
        XCTAssertTrue(withProAI.contains(UFPlan.free.name) && withProAI.contains(UFPlan.plus.name) && withProAI.contains(UFPlan.proAI.name))
        XCTAssertTrue(withProAI.contains("Die StudiNow-KI nutzt du mit Credits."))
        XCTAssertTrue(withProAI.contains("120 Credits"))
        XCTAssertFalse(PlanPickerView.subtitle(proAI: false).contains("Pro"))
        XCTAssertTrue(PlanPickerView.legalText.contains("höheren Tarif"), "zwei Abo-Tarife in einer Gruppe: Wechselregel steht dabei")
        XCTAssertTrue(PlanPickerView.legalText.contains("24 Stunden"))
    }

    /// Probe auf dem iPad wie `trial` im Vertrag (plans.TRIAL im Dienst): 7 Tage, Tarif Plus (26.11.2026; vorher Pro AI)
    func testLocalTrialMatchesContract() throws {
        let c = try contract()
        XCTAssertEqual(int(c["trial"]?["days"]), UFLocalTrial.days)
        XCTAssertEqual(c["trial"]?["plan"]?.string, UFLocalTrial.plan.rawValue)
        XCTAssertEqual(UFLocalTrial.length, 7 * 86_400)
        // "Probe: alles wie Plus, 25 Credits" (26.11.2026): Zahl wie im Vertrag
        XCTAssertEqual(int(c["trial"]?["credits"]), UFTrialTexts.credits)
        XCTAssertEqual(UFLocalTrial.plan, .plus)
        XCTAssertTrue(UFTrialTexts.offerProAI.contains("alles wie StudiNow Plus, mit \(UFTrialTexts.credits) Credits"))
        XCTAssertEqual(UFTrialBannerContent.running(daysLeft: 3, source: .service).text, UFTrialTexts.runningTextService)
        XCTAssertTrue(UFTrialTexts.runningTextService.hasPrefix("Alles wie StudiNow Plus, mit \(UFTrialTexts.credits) Credits"))
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
        // „Eigenes ChatGPT“ aus (OpenAIKeyLink.isOffered, Vorgabe 11.11.2026): auf keiner Karte, nicht freigeschaltet
        XCTAssertEqual(UFEntitlement.chatgptConnectionPremium.onDevice, .needsService)
        XCTAssertFalse(UFEntitlement.chatgptConnectionPremium.availableOnDevice)
        XCTAssertEqual(UFEntitlement.canShareSolutions.onDevice, .onDevice([.shareSolutions]))
        // eigene Karteikarten (04.11.2026): Recht des Vertrags ab Plus, auf dem iPad die Funktion `flashcards`
        XCTAssertEqual(UFEntitlement.canUseFlashcards.onDevice, .onDevice([.flashcards]))
        XCTAssertEqual(UFEntitlement.canUseFlashcards.from, .plus)
        XCTAssertEqual(UFEntitlement.canUseFlashcards.label, UFFeature.flashcards.title)
        // mit StudiNow-Konto (seit 26.11.2026 ab Plus): StudiNow-KI mit Credits und Notizen-Abgleich
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
                // mit Konto: StudiNow-KI (nur mit Credits) und Abgleich, seit 26.11.2026 alles ab Plus
                if case .withAccount = e.onDevice {
                    XCTAssertEqual(e.from, .plus, "mit Konto ab Plus: \(e.rawValue)")
                    XCTAssertEqual(e.needsCredits, e != .canSyncAnnotations, "KI braucht Credits, der Abgleich nicht: \(e.rawValue)")
                }
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

    /// Seit 26.11.2026 (neues Tarifmodell) hat Plus alle Funktionen, Pro AI genau dieselben (dazu nur die Monats-Credits).
    /// Vorher gehoerten KI-Hilfe, KI-Karteikarten, Wochentests, Abgleich und Erinnerungen zu Pro AI.
    func testPlusHasEverythingAndProAIAddsOnlyCredits() {
        for f in UFFeature.allCases {
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .proAI), UFFeatureMatrix.access(f, plan: .plus), f.rawValue)
        }
        XCTAssertTrue(UFFeature.allCases.filter { $0.minimumPlan == .proAI }.isEmpty, "keine Funktion nur in Pro AI")
        let formerlyPro: [UFFeature] = [.aiHelp, .aiFlashcards, .weeklyTests, .deviceSync, .dueReminders]
        for f: UFFeature in [.pencilWriting, .communityRead, .shareSolutions, .splitView, .flashcards, .autoPlan, .aiChat] + formerlyPro {
            XCTAssertEqual(f.minimumPlan, .plus, f.rawValue)
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .plus), .allowed, f.rawValue)
            XCTAssertEqual(UFFeatureMatrix.access(f, plan: .free), .locked(.plus), f.rawValue)
        }
        XCTAssertEqual(UFEntitlement.canUseDueReminders.onDevice, .onDevice([.dueReminders]))
        XCTAssertTrue(UFEntitlement.allCases.allSatisfy { $0.from <= .plus }, "jedes Recht ab Plus oder Free")
        XCTAssertEqual(UFFeatureMatrix.notes(plan: .plus), UFNoteAccess(canView: true, canExport: true, canEdit: true))
        // neue Schreibfunktionen (Textbloecke, Notizzettel, Klappkarten, Verweise, Tabelle) ab Plus
        XCTAssertEqual(UFRichNotes.minimumPlan, .plus)
        XCTAssertTrue(UFRichNotes.allowed(plan: .plus))
        XCTAssertFalse(UFRichNotes.allowed(plan: .free))
        // KI-Rechte nur mit Credits (plans.json `needs_credits`)
        let ai: Set<UFEntitlement> = [.canGenerateStudoraAITests, .canUseAIChat, .canUseAIExplanations, .canUseAIGeneratedQuestions,
                                      .canUseAISummaries, .canUseAIRecommendations, .canUsePreparedWeekSets]
        XCTAssertEqual(Set(UFEntitlement.allCases.filter(\.needsCredits)), ai)
    }

    func testNeedsCreditsMatchesContract() throws {
        let rights = try XCTUnwrap(contract()["entitlements"]?.object)
        for e in UFEntitlement.allCases {
            XCTAssertEqual(rights[e.rawValue]?["needs_credits"]?.bool ?? false, e.needsCredits, e.rawValue)
        }
    }

    // MARK: Tarifkarten

    /// Karten (App Review 07.11.2026): Free und Plus ohne KI, Pro AI mit den gebauten KI-Funktionen; das eigene ChatGPT
    /// (eigener OpenAI-Schluessel, 07.11.2026) steht ehrlich auf der Free-Karte ("in jedem Tarif"); nichts
    /// "in Vorbereitung", nichts, was es auf dem iPad nicht gibt
    func testPlanCardsListOnlyWhatWorks() {
        // Lernkalender ausgeblendet (`LearnCalendar`, 17.11.2026): die Karten nennen ihn nicht; die Rechte des Vertrags
        // (can_use_basic_planner) bleiben. Mit Schalter an stehen die Zeilen wieder da (unten).
        XCTAssertFalse(LearnCalendar.enabled)
        XCTAssertEqual(UFPlanCard.included(.free).map(\.title),
                       [UFFeature.studipSync, .readDocuments, .modulesTimetable, .viewNotes, .uniGrades].map(\.title))
        // seit 26.11.2026 alles auf der Plus-Karte, die KI-Zeilen mit dem Zusatz "mit Credits"
        let plusRows = ["Schreiben mit Apple Pencil", "Community lesen, beitreten und mitmachen", "Eigene Lösungen teilen",
                        "Übung und Skript nebeneinander", "Eigene Karteikarten mit Wiederholung"]
        let plusAI = ["KI-Chat mit Credits", "KI-Lernhilfe zu deinen Unterlagen", "Karteikarten aus deinen Unterlagen",
                      "Wochentests erstellen", "Notizen auf allen deinen Geräten", "Erinnerungen an Abgaben und Klausuren"]
        XCTAssertEqual(UFPlanCard.included(.plus).map(\.title), (plusRows + plusAI).map { UFDevice.adapt($0) })
        LearnCalendar.enabled = true
        defer { LearnCalendar.enabled = false }
        XCTAssertEqual(UFPlanCard.included(.free).map(\.title),
                       [UFFeature.studipSync, .readDocuments, .modulesTimetable, .studyCalendar, .studyPlanning,
                        .viewNotes, .uniGrades].map(\.title))             // ohne „Eigenes ChatGPT“ (aus seit 11.11.2026)
        XCTAssertEqual(UFPlanCard.included(.plus).map(\.title),
                       (plusRows + ["Lernplan automatisch erstellen"] + plusAI).map { UFDevice.adapt($0) })   // am Mac „Schreiben mit Maus oder Trackpad“
        // Free (07.11.2026): Lernkalender von Hand, der automatische Lernplan gehoert zu Plus
        XCTAssertFalse((UFPlanCard.included(.free).map { $0.title + " " + ($0.detail ?? "") }).joined().contains("automatisch"))
        XCTAssertEqual(UFPlanCard.included(.plus).first { $0.title == UFFeature.autoPlan.title }?.detail, "Lernslots in deinen freien Zeiten")
        // KI-Zeilen ehrlich: nur mit Credits
        for t in ["KI-Chat mit Credits", "KI-Lernhilfe zu deinen Unterlagen", "Karteikarten aus deinen Unterlagen", "Wochentests erstellen"] {
            XCTAssertTrue(UFPlanCard.included(.plus).first { $0.title == t }?.detail?.contains("Credits") == true, t)
        }
        // Pro AI: nur die Monats-Credits dazu
        XCTAssertEqual(UFPlanCard.included(.proAI).map(\.title), ["120 Credits für die StudiNow-KI – jeden Monat"])
        XCTAssertTrue(UFPlanCard.included(.proAI).first?.detail?.contains("Am 1. neu aufgeladen, der Rest verfällt") == true)
        let help = try? XCTUnwrap(UFPlanCard.included(.plus).first { $0.title == UFFeature.aiHelp.title })
        XCTAssertTrue(help?.detail?.contains("„Ganze Vorlesung erklären“") == true)
        XCTAssertTrue(help?.detail?.contains("„Alle Aufgaben erklären“") == true)
        XCTAssertFalse(UFPlanCard.included(.plus).contains { ($0.detail ?? "").contains("80 Credits") })
        XCTAssertFalse(UFPlanCard.included(.free).contains { $0.title.contains("Community") }, "Free ohne Community")

        // was es auf dem iPad nicht gibt, steht auf keiner Karte; "ChatGPT" nur in der Zeile des eigenen Schluessels
        let forbidden = #"Vorbereitung|Statistik|Bibliothek|Empfehlung|Lernplanung \(|Testliste|Vorlesungswoche|denselben Umfang"#
        for plan in UFPlan.allCases {
            for r in UFPlanCard.included(plan) {
                XCTAssertNil((r.title + " " + (r.detail ?? "")).range(of: forbidden, options: .regularExpression), r.title)
                if r.title != UFFeature.ownChatGPT.title { XCTAssertFalse((r.title + " " + (r.detail ?? "")).contains("ChatGPT"), r.title) }
                // Free nennt weder KI noch Abgleich (beides ab Plus)
                if plan == .free {
                    XCTAssertNil((r.title + " " + (r.detail ?? "")).range(of: #"\bKI\b|KI-|allen deinen Geräten"#, options: .regularExpression),
                                 "KI und Abgleich gehoeren zu Plus: \(r.title)")
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
        // Kurzbeschreibung der Karten wie im Vertrag (26.11.2026)
        XCTAssertEqual(UFPlanCard.tagline(.free), UFPlan.free.tagline)
        XCTAssertEqual(UFPlanCard.tagline(.plus), "Alle Funktionen ohne KI – KI mit Credits dazu")
        XCTAssertEqual(UFPlanCard.tagline(.proAI), "Alles aus Plus und 120 Credits für die StudiNow-KI – jeden Monat neu")
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

    /// Probe auf dem iPad: oben "Probe aktiv: alle Funktionen von StudiNow Plus bis … (noch n Tage)" (26.11.2026; vorher
    /// Pro AI), ehrlich zur KI (StudiNow-Konto, 25 Credits beim Dienst); keine Karte "Aktueller Tarif", auch Free nicht;
    /// die Probe schaltet alles wie Plus frei, danach Free
    func testTrialStatusOnPlanPage() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-07T10:00:00Z"))
        let t = UFLocalTrial.state(startedAt: start, now: start)
        let s = PlanPickerView.trialStatus(t, proAI: true)
        XCTAssertEqual(s.title, "Probe aktiv: alle Funktionen von StudiNow Plus bis 14.11.2026 (noch 7 Tage)")
        XCTAssertTrue(s.note.contains("StudiNow-Konto (Anmelden mit Apple)"), s.note)
        XCTAssertTrue(s.note.contains("25 Credits"), s.note)
        XCTAssertTrue(s.note.contains("Danach gilt StudiNow Free"), s.note)
        XCTAssertFalse(s.note.contains("ChatGPT") || s.note.contains("gratis"), s.note)
        let last = UFLocalTrial.state(startedAt: start, now: start.addingTimeInterval(6.5 * 86_400))
        XCTAssertEqual(PlanPickerView.trialStatus(last, proAI: true).title, "Probe aktiv: alle Funktionen von StudiNow Plus bis 14.11.2026 (noch 1 Tag)")
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
        // Probe = Plus: alle Funktionen des iPads frei, danach Free
        XCTAssertEqual(UFLocalTrial.plan, .plus)
        XCTAssertEqual(UFPlanPrecedence.effective(service: nil, purchased: .free, localTrial: t), .plus)
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
        XCTAssertEqual(ent.plan, .plus, "Probe: alles wie Plus (26.11.2026)")
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
