import StoreKit
import SwiftUI

// Tarifwahl (docs/AUFTRAG-APPSTORE-V1.md, Abschnitt 2a Schritt 2, Abschnitt 4 und 5; docs/ABO-SYSTEM.md): Karten fuer
// die Tarife aus `UFPlanCatalog` – StudiNow Free, Plus und Pro AI (neues Tarifmodell des Inhabers vom 26.11.2026); die
// Pro-AI-Karte nur, wenn StoreKit das Produkt liefert, sonst ein nicht anklickbarer Hinweis ohne Preis. Inhalt der
// Karten aus `UFPlanCard`: nur, was auf dem iPad wirklich geht (auf dem Geraet oder mit StudiNow-Konto), nichts
// "in Vorbereitung"; Plus nennt die KI mit Credits, Pro AI die 120 Credits im Monat. Preise nur aus Product.displayPrice.
// Plus hat zwei Knoepfe: Monatsabo und 5 Jahre einmalig (`UFOffer`). Vor jedem Kauf steht der Hinweis zur
// Unabhaengigkeit von den Hochschulen (§ 327h BGB, `UFPurchaseNotice`): ohne Haken geht kein Kaufknopf.
// Kein Einfuehrungsangebot: die 7 Tage Probe laufen ohne Kauf auf dem iPad (LocalTrial.swift, alles wie Plus). Waehrend
// sie laeuft, steht oben "Probe aktiv: alle Funktionen von StudiNow Plus bis … (noch n Tage)", keine Karte traegt
// "Aktueller Tarif" (auch Free nicht, 07.11.2026), die Plus-Karte traegt "Probe". Sonst richtet sich "Aktueller Tarif"
// nach dem Kauf (`purchasedPlan`). Wechsel zwischen Abo-Tarifen regelt Apple in der Gruppe.
// Geschenkter Tarif (18.11.2026, `UFServiceGift`): oben "Geschenkt: alle Funktionen von StudiNow Pro AI, unbefristet"
// (bzw. "bis …"), seine Karte traegt "Aktueller Tarif" ohne "Abo verwalten", er und die Tarife darunter haben keinen
// Kaufknopf ("Im Geschenk enthalten"); ein hoeherer Tarif bleibt kaufbar.
// Dieselbe Ansicht dient beim ersten Start, in den Einstellungen ("Tarif wechseln", "Abo verwalten") und hinter
// gesperrten Funktionen (UFPlanSheet).
// Zahlweise (26.11.2026): Plus monatlich oder einmalig 5 Jahre, Pro AI jaehrlich (mit Monatsbetrag daraus, "entspricht
// 3,33 € im Monat"). Fruehere Produkte (Plus-Jahresabo 19,99 EUR, Pro-AI-Monatsabo) gelten weiter, ihre Karte zeigt
// "Abo verwalten".

struct PlanPickerView: View {
    enum Context: Equatable {
        /// erster Start: "StudiNow Free nutzen" bzw. erfolgreicher Kauf -> onDone
        case onboarding
        /// Einstellungen: aktueller Tarif, Abo verwalten
        case settings
        /// aus einer gesperrten Funktion heraus; Tarif, der sie freischaltet
        case upgrade(UFPlan?)
        /// nach dem Ende der Probe (TrialDecisionCover, Inhaber 07.11.2026): Free ("Bei Free bleiben"), Plus oder Pro AI
        /// waehlen; "Bei Free bleiben" bzw. ein Kauf -> onDone
        case trialOver
    }

    var context: Context = .onboarding
    let onDone: () -> Void

    @StateObject private var store: PurchaseStore
    @ObservedObject private var ent: Entitlements
    @State private var manage = false
    @State private var info: String?
    @Environment(\.openURL) private var openURL
    /// StudiNow-Konto (nil ohne Dienst): nach dem Kauf von Pro AI gleich zur Anmeldung bitten
    @Environment(\.ufStudoraAccount) private var studoraAccount
    @State private var signInAfterPurchase = false
    /// Hinweis vor dem Kauf bestaetigt (`UFPurchaseNotice`, einmal reicht)
    @State private var noticeConfirmed = UFPurchaseNotice.isConfirmed(in: UFPurchaseNotice.defaults)

    /// `entitlements: nil` = `Entitlements.shared` (erst im MainActor-Kontext aufgeloest, Swift 6)
    @MainActor
    init(context: Context = .onboarding, entitlements: Entitlements? = nil, onDone: @escaping () -> Void) {
        let ent = entitlements ?? .shared
        self.context = context
        self.onDone = onDone
        _store = StateObject(wrappedValue: PurchaseStore(entitlements: ent))
        _ent = ObservedObject(wrappedValue: ent)
    }

    /// Pflichtlinks der Tarifseite (Richtlinie 3.1.2): oeffentliche Seiten auf studinow.app (`UFLegalLinks`)
    enum LegalPage: String, Identifiable, CaseIterable {
        case terms = "Nutzungsbedingungen"
        case privacy = "Datenschutzerklärung"
        var id: String { rawValue }
        var url: URL { self == .terms ? UFLegalLinks.terms : UFLegalLinks.privacy }
    }

    var body: some View {
        UFContent(maxWidth: 1000) {
            UFPageHead(Self.title(context), sub: subtitle)
            if context == .trialOver { infoCard(UFTrialTexts.overText).padding(.bottom, 16) }
            if let t = ent.runningTrial { trialCard(t).padding(.bottom, 16) }
            if !ent.loading, let g = ent.carryingGift { giftCard(g).padding(.bottom, 16) }
            if !ent.loading, ent.ownedPlan == .free, ent.localTrial?.deviceUsed == true {
                infoCard(UFTrialTexts.usedOnDeviceTitle + ".").padding(.bottom, 16)
            }
            if let e = store.lastError { errorCard(e).padding(.bottom, 16) }
            if let info { infoCard(info).padding(.bottom, 16) }
            // vor jedem Kauf deutlich und gesondert (§ 327h BGB): der Hinweis mit Haken
            PurchaseNoticeCard(confirmed: Binding(get: { noticeConfirmed }, set: { on in
                noticeConfirmed = on
                UFPurchaseNotice.confirm(in: UFPurchaseNotice.defaults, on)
            }))
            .padding(.bottom, 16)
            // drei Bereiche (Inhaber 27.11.2026): Unser Special ganz oben ("Ja, nach oben"), dann Monatlich (Free, Plus, Pro AI), Jaehrlich (Pro AI)
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections) { sectionView($0) }
            }
            if Self.showsProAIMissingNote(loaded: store.loadedProductIDs, loading: store.loadingProducts, current: ent.ownedPlan) {
                // nur ein Hinweis: kein Preis, kein Knopf, nichts zum Antippen
                Text(UFPlanCatalog.proAIMissingNote).ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 12.8)
                    .accessibilityAddTraits(.isStaticText)
            }
            // Credit-Pakete (15.11.2026): Stand beider Toepfe und "Credits kaufen", nur auf der Tarifseite der Einstellungen
            if context == .settings, let studoraAccount { CreditShopCard(link: studoraAccount).padding(.top, 16) }
            // Probe und Abo je Apple-ID (12.11.2026)
            Text(UFTrialTexts.perAppleID).ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 12.8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("plans.perAppleID")
            footer.padding(.top, 22.4)
        }
        .task {
            await store.loadProducts()
            await store.refreshEntitlements()
        }
        .overlay {
            // nach dem Kauf von Pro AI ohne StudiNow-Konto: gleich zur Anmeldung bitten (Inhaber 10.11.2026)
            if signInAfterPurchase, let link = studoraAccount {
                ProAIAfterPurchasePrompt(link: link) { signInAfterPurchase = false; onDone() }
            }
        }
        .manageSubscriptionsSheet(isPresented: $manage)
        .onChange(of: manage) { _, open in
            // nach dem Verwalten (Kuendigen, Wechsel) den Tarif neu lesen
            if !open { Task { await store.refreshEntitlements() } }
        }
    }

    /// Hinweis "Pro AI folgt mit dem Dienst": wenn die Produkte geladen sind, kein Pro-AI-Produkt (monatlich oder
    /// jaehrlich) dabei ist und niemand es schon hat
    static func showsProAIMissingNote(loaded: Set<String>, loading: Bool, current: UFPlan) -> Bool {
        guard !loading, !loaded.isEmpty, current != .proAI else { return false }
        return !UFPlan.proAI.offers.contains { loaded.contains($0.productID) }
    }

    // MARK: Kopf

    static func title(_ context: Context) -> String {
        switch context {
        case .onboarding: return "Tarif wählen"
        case .settings: return "Tarif wechseln"
        case .upgrade(let p): return p.map { "Mehr mit \($0.name)" } ?? "Tarif wechseln"
        case .trialOver: return UFTrialTexts.overTitle
        }
    }

    private var proAIOffered: Bool { UFPlan.proAI.offers.contains { store.loadedProductIDs.contains($0.productID) } }

    private var subtitle: String { Self.subtitle(proAI: proAIOffered) }

    /// Untertitel: die angebotenen Tarife (Pro AI nur mit Produkt aus dem Store); die laufende Probe steht in eigener
    /// Zeile darunter (`trialStatus`)
    static func subtitle(proAI: Bool) -> String {
        var s = "Mit \(UFPlan.free.name) \(LearnCalendar.text("planst du dein Lernen", off: "siehst du deinen Stundenplan")), öffnest deine Dokumente und siehst deine Fächer geordnet – dauerhaft kostenlos. "
        s += UFEditorAvailability.available ? UFDevice.adapt("\(UFPlan.plus.name) hat alle Funktionen, vom Schreiben mit dem Apple Pencil bis zum Abgleich. ")
            : "\(UFPlan.plus.name) hat alle Funktionen, in der iPad-App auch das Schreiben mit dem Apple Pencil. "
        s += "Die StudiNow-KI nutzt du mit Credits. "
        s += proAI ? "\(UFPlan.proAI.name) bringt jeden Monat \(UFPlan.proAI.monthlyCredits) Credits mit. " : ""
        s += "Du kannst den Tarif jederzeit wechseln."
        return s
    }

    /// Stand der Probe auf dem iPad oben auf der Seite: bis wann alles frei ist und was danach gilt. Die StudiNow-KI
    /// laeuft auch in der Probe nur mit StudiNow-Konto; dessen Probe gibt dem neuen Konto 25 Credits (plans.TRIAL).
    /// Ohne Pro-AI-Produkt im Store (Build ohne Dienst) ohne Pro AI und ohne KI.
    static func trialStatus(_ t: UFLocalTrial.State, proAI: Bool) -> (title: String, note: String) {
        trialStatus(UFShownTrial(source: .device, daysLeft: t.daysLeft, endsAt: t.endsAt), proAI: proAI)
    }

    /// dasselbe fuer die angezeigte Probe (`Entitlements.runningTrial`: Probe des Kontos oder des iPads); `after`:
    /// gekaufter Tarif, der nach der Probe des Kontos weiter gilt
    static func trialStatus(_ t: UFShownTrial, proAI: Bool, after: UFPlan = .free) -> (title: String, note: String) {
        let until = t.endsAt.map {
            " bis " + $0.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(Locale(identifier: "de_DE")))
        } ?? ""
        let left = "noch \(t.daysLeft) \(t.daysLeft == 1 ? "Tag" : "Tage")"
        let title = proAI ? "Probe aktiv: alle Funktionen von \(UFLocalTrial.plan.name)\(until) (\(left))"
            : "Probe aktiv: alle Funktionen\(until) (\(left))"
        var note = ""
        if proAI && t.source == .service {
            note += "Die StudiNow-KI läuft über dein StudiNow-Konto, mit \(UFTrialTexts.credits) Credits zum Ausprobieren. "
        } else if proAI {
            note += "Für die StudiNow-KI brauchst du ein StudiNow-Konto (Anmelden mit Apple); neue Konten bekommen dort "
            note += "\(UFTrialTexts.credits) Credits zum Ausprobieren. "
        }
        if after != .free {
            note += "Danach gilt wieder \(after.name), deine Notizen bleiben erhalten."
        } else {
            note += "Danach gilt \(UFPlan.free.name), wenn du keinen Tarif wählst – ohne Zahlungsdaten, deine Notizen bleiben erhalten."
        }
        return (title, note)
    }

    /// Text der Geschenk-Karte oben: Titel und Zeile darunter, ohne Kauf-Druck
    static func giftStatus(_ g: UFServiceGift) -> (title: String, note: String) {
        let title = "Geschenkt: alle Funktionen von \(g.plan.name)" + (g.untilText.map { " " + $0 } ?? ", unbefristet")
        return (title, "Ohne Abo und ohne Zahlung – du musst hier nichts abschließen. Deine Notizen bleiben in jedem Fall erhalten.")
    }

    /// Deckt das Geschenk diesen Tarif ab (geschenkter Tarif oder darunter, ueber dem Kauf)? Dann kein Kaufknopf.
    static func coveredByGift(_ plan: UFPlan, gift: UFServiceGift?) -> Bool {
        guard let gift, plan != .free else { return false }
        return plan <= gift.plan
    }

    private func giftCard(_ g: UFServiceGift) -> some View {
        let s = Self.giftStatus(g)
        return UFCard(flat: true) {
            HStack(alignment: .top, spacing: 12) {
                UFIcon("star", size: 18).foregroundStyle(UF.ok).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.title).ufFont(14.5, 650).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    Text(s.note).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plans.gift")
    }

    private func trialCard(_ t: UFShownTrial) -> some View {
        let s = Self.trialStatus(t, proAI: proAIOffered, after: ent.purchasedPlan)
        return UFCard(flat: true) {
            HStack(alignment: .top, spacing: 12) {
                UFIcon("sparkles", size: 18).foregroundStyle(UF.info).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.title).ufFont(14.5, 650).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    Text(s.note).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plans.trial")
    }

    // MARK: Bereiche und Karten (27.11.2026: Monatlich, Jaehrlich, Unser Special)

    /// Bereiche der Seite mit ihren Karten (`UFPlanCatalog.sections`)
    private var sections: [UFPlanSection] {
        UFPlanCatalog.sections(current: ent.ownedPlan, owned: ent.purchasedOffer, loaded: store.loadedProductIDs)
    }

    private func sectionView(_ section: UFPlanSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.group.title).ufFont(13.12, 700, em: 0.04).foregroundStyle(UF.muted).textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("plans.section.\(section.group.rawValue)")
            if section.group == .monthly {
                UFGridLayout(spacing: 16, minWidth: 250) {
                    ForEach(section.cards) { offerCard($0) }
                }
                .environment(\.ufFillsCell, true)
            } else {
                ForEach(section.cards) { offerCard($0) }
            }
        }
    }

    /// Kennung des Kaufknopfs: Hauptprodukt wie bisher "plans.buy.plus" / "plans.buy.pro_ai", Pro AI monatlich
    /// "plans.buy.pro_ai.monthly"
    static func buyIdentifier(_ o: UFOffer) -> String {
        o.productID == o.plan.productID ? "plans.buy.\(o.plan.rawValue)" : "plans.buy.\(o.plan.rawValue).\(o.period ?? "once")"
    }

    /// Traegt diese Karte "Aktueller Tarif"? Wie `isCurrent(_:purchased:…)`, dazu das gekaufte Angebot (Pro AI monatlich
    /// oder jaehrlich); ohne Angebot (frueheres Produkt, Geschenk) die erste Karte des Tarifs
    static func isCurrent(_ card: UFPlanOfferCard, purchased: UFPlan, offer: UFOffer?, loading: Bool, trial: Bool) -> Bool {
        guard isCurrent(card.plan, purchased: purchased, loading: loading, trial: trial) else { return false }
        guard let o = card.offer else { return true }
        if let offer, offer.plan == purchased { return o == offer }
        return o == purchased.offers.first
    }

    private func offerCard(_ card: UFPlanOfferCard) -> some View {
        let plan = card.plan
        let trial = ent.runningTrial != nil
        let current = Self.isCurrent(card, purchased: ent.ownedPlan, offer: ent.purchasedOffer, loading: ent.loading, trial: trial)
        let showCurrent = current && context != .onboarding && context != .trialOver
        let special = card.offer?.highlight == true
        let content = VStack(alignment: .leading, spacing: 0) {
            cardHead(card, showCurrent: showCurrent, trial: trial)
            if let t = UFPlanCard.tagline(plan), !special {
                Text(t).ufFont(13.12).foregroundStyle(UF.text2).padding(.top, 3.2).fixedSize(horizontal: false, vertical: true)
            }
            if let s = UFPlanCatalog.serviceNote(plan) {
                Text(s).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true).padding(.top, 3.2)
            }
            priceBlock(card).padding(.top, 8)
            Rectangle().fill(special ? UF.accent.opacity(0.35) : UF.line).frame(height: 1).padding(.vertical, 14.4)
            PlanFeatureList(plan: plan, columns: card.offer?.group != .monthly)
            Spacer(minLength: 16)
            actionButton(card, current: current, trial: trial)
            if let n = buttonNote(card, current: current) {
                Text(n).ufFont(11.84).foregroundStyle(UF.muted).padding(.top, 6.4).fixedSize(horizontal: false, vertical: true)
            }
        }
        if special { return AnyView(PlanSpecialFrame(highlight: showCurrent) { content }) }
        return AnyView(PlanCardFrame(highlight: showCurrent) { content })
    }

    @ViewBuilder
    private func cardHead(_ card: UFPlanOfferCard, showCurrent: Bool, trial: Bool) -> some View {
        let plan = card.plan
        if let o = card.offer, o.highlight, let name = o.name {
            // Unser Special: Abzeichen, Name des Pakets, Inhalt
            UFFlexWrap(gap: 8) {
                PlanSpecialBadge(text: o.badge ?? UFOfferGroup.special.title)
                if showCurrent { UFBadge("Aktueller Tarif", tone: .ok, icon: "check") }
            }
            Text(name).ufFont(24, 750, lh: 1.2, em: -0.02).foregroundStyle(UF.text).padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(UFOfferText.packageContent(years: o.years ?? 5)).ufFont(15.2, 600).foregroundStyle(UF.accentText).padding(.top, 2)
        } else {
            HStack(spacing: 8) {
                Text(plan.name).ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text)
                Spacer(minLength: 0)
                if showCurrent {
                    UFBadge("Aktueller Tarif", tone: .ok, icon: "check")
                } else if trial && card == .offer(.plusMonthly) {
                    UFBadge("Probe", tone: .info, icon: "clock")
                } else if !ent.loading && ent.pendingPlan == plan && card.offer == plan.offers.first {
                    UFBadge("Vorgemerkt", tone: .info, icon: "clock")
                }
            }
        }
    }

    /// Traegt die Karte "Aktueller Tarif"? Der gekaufte Tarif bzw. Free ohne Kauf, waehrend der Probe ohne Kauf keiner
    static func isCurrent(_ plan: UFPlan, purchased: UFPlan, loading: Bool, trial: Bool) -> Bool {
        !loading && purchased == plan && !(trial && purchased == .free)
    }

    /// VoiceOver: Titel und Zusatz (die Ueberschrift steht weiter oben)
    static func accessibilityLabel(_ r: UFPlanCardRow) -> String {
        ([r.title] + (r.detail.map { [$0] } ?? [])).joined(separator: ", ")
    }

    @ViewBuilder
    private func priceBlock(_ card: UFPlanOfferCard) -> some View {
        if card == .free {
            VStack(alignment: .leading, spacing: 2) {
                Text("0 €").ufFont(26, 700, lh: 1.2, em: -0.02).foregroundStyle(UF.text)
                Text("dauerhaft kostenlos, ohne Abo").ufFont(13.12).foregroundStyle(UF.muted)
            }
        } else if let o = card.offer, let p = store.product(for: o) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3.2) {
                    Text(p.displayPrice).ufFont(o.highlight ? 34 : 26, 700, lh: 1.2, em: -0.02).foregroundStyle(UF.text)
                    Text(o.kind == .nonRenewing ? "einmalig" : UFOfferText.per(value: p.ufPeriod.0, unit: p.ufPeriod.1))
                        .ufFont(14.5).foregroundStyle(UF.muted)
                }
                if o.kind == .nonRenewing, let years = o.years {
                    Text(UFOfferText.onceSummary(price: p.displayPrice, years: years)).ufFont(13.12).foregroundStyle(UF.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(UFOfferText.summary(price: p.displayPrice, period: p.ufPeriod)).ufFont(13.12).foregroundStyle(UF.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let s = o.savings, UFOfferText.savingsApply(o, price: p.price, currency: p.priceFormatStyle.currencyCode,
                                                               comparePrice: o.compare.flatMap { store.product(for: $0)?.price }) {
                    PlanSavingsLine(savings: s, strong: o.highlight).padding(.top, 6)
                } else if o.kind == .autoRenewable, p.ufPeriod == (1, .year) {
                    // anderer Store-Preis: nur der Monatsbetrag aus dem Jahrespreis des Stores
                    Text(UFOfferText.yearlyNote(perMonth: p.priceFormatStyle.format(p.price / 12)))
                        .ufFont(13.12, 600).foregroundStyle(UF.text2)
                }
            }
        } else if store.loadingProducts {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preis wird geladen …").ufFont(13.12).foregroundStyle(UF.muted)
            }
            .frame(minHeight: 50, alignment: .leading)
        } else {
            // kein Preis aus dem Code (Richtlinie 3.1.2): ohne Produkt aus StoreKit kein Preis und kein Kaufknopf
            Text("Preis zurzeit nicht verfügbar").ufFont(13.12).foregroundStyle(UF.muted)
                .frame(minHeight: 50, alignment: .leading)
        }
    }

    /// laeuft gerade ein gekauftes Abo der Gruppe (nicht Free, nicht der einmalige Kauf)? Dann sind die anderen
    /// Abo-Tarife ein Wechsel in der Gruppe.
    private var hasSubscription: Bool { Self.hasSubscription(purchased: ent.purchasedPlan, offer: ent.purchasedOffer, loading: ent.loading) }

    /// Regel zu `hasSubscription` (testbar): gekauft, aber nicht einmalig ueber Jahre
    static func hasSubscription(purchased: UFPlan, offer: UFOffer?, loading: Bool) -> Bool {
        !loading && purchased != .free && offer?.kind != .nonRenewing
    }

    /// Kaufknopf antippbar? Nur mit bestaetigtem Hinweis (§ 327h BGB) und nicht waehrend eines Kaufs
    static func canTapBuy(confirmed: Bool, busy: Bool) -> Bool { UFPurchaseNotice.allowsPurchase(confirmed: confirmed) && !busy }

    /// Kaufknopf des Bachelor+Master-Pakets (5 Jahre Plus einmalig). Seit 27.11.2026 auch neben laufendem Pro AI (mit dem
    /// Hinweis, Pro AI danach zu kuendigen). Nicht, solange das Paket schon gilt (`ownsOnce`), nicht im Geschenk; ohne
    /// Produkt aus dem Store gar nicht.
    static func showsOnceButton(purchased: UFPlan, offer: UFOffer?, giftCovers: Bool, loaded: Bool, ownsOnce: Bool = false) -> Bool {
        loaded && !giftCovers && offer != .plusFiveYears && !ownsOnce
    }

    @ViewBuilder
    private func onceButton(_ o: UFOffer) -> some View {
        if !ent.loading, let p = store.product(for: o), let years = o.years,
           Self.showsOnceButton(purchased: ent.purchasedPlan, offer: ent.purchasedOffer,
                                giftCovers: Self.coveredByGift(.plus, gift: ent.carryingGift), loaded: true,
                                ownsOnce: ent.activeOffers.contains(o)) {
            fullButton(UFOfferText.onceButton(price: p.displayPrice, years: years), kind: .primary,
                       enabled: Self.canTapBuy(confirmed: noticeConfirmed, busy: store.busy)) {
                Task { await buy(p, offer: o) }
            }
            .accessibilityIdentifier("plans.plus.once")
        } else if !ent.loading, ent.activeOffers.contains(o) {
            fullButton("Aktueller Tarif", kind: .normal, enabled: false) {}
        } else if !ent.loading, Self.coveredByGift(.plus, gift: ent.carryingGift) {
            fullButton("Im Geschenk enthalten", kind: .normal, enabled: false) {}
        } else {
            fullButton("\(o.name ?? UFPlan.plus.name) wählen", kind: .primary, enabled: false) {}
        }
    }

    @ViewBuilder
    private func actionButton(_ card: UFPlanOfferCard, current: Bool, trial: Bool) -> some View {
        if let o = card.offer, o.kind == .nonRenewing, !current {
            onceButton(o)
        } else if let o = card.offer {
            offerButton(o, current: current)
        } else {
            freeButton(current: current, trial: trial)
        }
    }

    @ViewBuilder
    private func freeButton(current: Bool, trial: Bool) -> some View {
        if context == .settings && ent.carryingGift != nil && ent.purchasedPlan == .free {
            // geschenkter Tarif ohne Kauf: nichts zu kuendigen
            fullButton("Im Geschenk enthalten", kind: .normal, enabled: false) {}
        } else if context == .settings && trial {
            // Probe ohne Kauf: nichts zu kuendigen, Free gilt nach der Probe von selbst
            fullButton("Gilt nach der Probe", kind: .normal, enabled: false) {}
        } else if context == .settings && !current {
            // Wechsel auf Free = Abo bei Apple kuendigen; der Zugang endet mit dem laufenden Zeitraum
            fullButton("Zu \(UFPlan.free.name) wechseln", kind: .normal) { manage = true }
        } else if context == .settings {
            fullButton("Aktueller Tarif", kind: .normal, enabled: false) {}
        } else if context == .trialOver {
            fullButton(UFTrialTexts.stayFree, kind: .normal) { onDone() }
        } else {
            fullButton("\(UFPlan.free.name) nutzen", kind: .normal) { onDone() }
        }
    }

    @ViewBuilder
    private func offerButton(_ o: UFOffer, current: Bool) -> some View {
        let plan = o.plan
        if Self.coveredByGift(plan, gift: ent.carryingGift) {
            // geschenkter Tarif bzw. darunter: kein Kauf, nichts zu verwalten
            if current && context != .settings {
                fullButton("Weiter mit \(plan.name)", kind: .primary) { onDone() }
            } else {
                fullButton(current ? "Aktueller Tarif" : "Im Geschenk enthalten", kind: .normal, enabled: false) {}
            }
        } else if current {
            if context == .settings && ent.purchasedOffer?.kind == .nonRenewing {
                // einmal bezahlt (5 Jahre): kein Abo zu verwalten
                fullButton("Aktueller Tarif", kind: .normal, enabled: false) {}
            } else if context == .settings {
                fullButton("Abo verwalten", icon: "settings", kind: .normal) { manage = true }
            } else {
                fullButton("Weiter mit \(plan.name)", kind: .primary) { onDone() }
            }
        } else if !ent.loading && ent.pendingPlan == plan && o == plan.offers.first {
            // Downgrade schon vorgemerkt: kein zweiter Kauf; aendern geht ueber "Abo verwalten"
            fullButton("Vorgemerkt", icon: "clock", kind: .normal, enabled: false) {}
        } else if let p = store.product(for: o) {
            let label = hasSubscription
                ? UFOfferText.switchButton(to: o, from: ent.purchasedOffer)
                : UFOfferText.button(plan: plan, price: p.displayPrice, period: p.ufPeriod)
            fullButton(label, kind: .primary, enabled: Self.canTapBuy(confirmed: noticeConfirmed, busy: store.busy)) { Task { await buy(p, offer: o) } }
                .accessibilityIdentifier(Self.buyIdentifier(o))
        } else {
            fullButton("\(plan.name) wählen", kind: .primary, enabled: false) {}
        }
    }

    /// Hinweis "Plus aus dem Paket läuft weiter" an einem Pro-AI-Abo, solange das Bachelor+Master-Paket gilt
    static func showsBesidePackageNote(_ o: UFOffer, activeOffers: Set<UFOffer>) -> Bool {
        o.plan == .proAI && o.kind == .autoRenewable && activeOffers.contains(.plusFiveYears)
    }

    /// kleine Zeile unter dem Knopf: Kuendigung, vorgemerkter Wechsel, wann ein Wechsel gilt, Hinweis am Paket
    private func buttonNote(_ card: UFPlanOfferCard, current: Bool) -> String? {
        guard let o = card.offer, !ent.loading else { return nil }
        let plan = o.plan
        if Self.coveredByGift(plan, gift: ent.carryingGift) { return nil }      // Geschenk: keine Kuendigung, kein Wechsel
        // Paket aktiv (Inhaber 27.11.2026): Pro AI dazukaufen geht, Plus aus dem Paket laeuft weiter
        let besidePackage = Self.showsBesidePackageNote(o, activeOffers: ent.activeOffers)
        if current {
            if ent.purchasedOffer?.kind == .nonRenewing { return UFOfferText.onceNote(plan, until: ent.expiresAt) }
            if let next = ent.pendingPlan { return UFOfferText.pendingNote(next, at: ent.expiresAt) }
            if ent.willRenew == false {
                return UFOfferText.cancelledNote(plan, endsAt: ent.expiresAt) + (besidePackage ? " " + UFOfferText.proAIBesidePackageNote : "")
            }
            return besidePackage ? UFOfferText.proAIBesidePackageNote : nil
        }
        let loaded = store.product(for: o) != nil
        if besidePackage && loaded && !hasSubscription {
            return noticeConfirmed ? UFOfferText.proAIBesidePackageNote : UFPurchaseNotice.needsConfirm + " " + UFOfferText.proAIBesidePackageNote
        }
        if o.kind == .nonRenewing {
            if ent.activeOffers.contains(o) || !loaded { return nil }
            if hasSubscription, let n = UFOfferText.onceNote(subscribed: ent.purchasedPlan) { return n }
            return noticeConfirmed ? nil : UFPurchaseNotice.needsConfirm
        }
        if ent.pendingPlan == plan && o == plan.offers.first { return UFOfferText.pendingNote(plan, at: ent.expiresAt) }
        if hasSubscription && loaded {
            return UFOfferText.switchNote(to: o, from: ent.purchasedOffer, currentPlan: ent.purchasedPlan)
        }
        if loaded && !noticeConfirmed { return UFPurchaseNotice.needsConfirm }
        return nil
    }

    private func fullButton(_ title: String, icon: String? = nil, kind: UFButtonKind, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7.2) {
                if let icon { UFIcon(icon, size: 16) }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(UFButtonStyle(kind: kind))
        .disabled(!enabled)
    }

    private func buy(_ p: Product, offer: UFOffer) async {
        // nie ohne bestaetigten Hinweis (§ 327h BGB), auch wenn ein Knopf doch erreichbar war
        guard UFPurchaseNotice.allowsPurchase(confirmed: noticeConfirmed) else { info = UFPurchaseNotice.needsConfirm; return }
        info = nil
        let plan = offer.plan
        let before = ent.purchasedPlan
        let beforeOffer = ent.purchasedOffer
        switch await store.purchase(p) {
        case .success:
            if offer.kind == .autoRenewable, let b = beforeOffer, b.kind == .autoRenewable, b.plan == plan, b != offer,
               ent.purchasedOffer == b {
                // Wechsel monatlich <-> jaehrlich im selben Tarif: Apple stellt zur naechsten Verlaengerung um
                info = UFOfferText.crossgradeNote
            } else if ent.purchasedPlan != plan, ent.pendingPlan == plan {
                // Downgrade: Apple stellt erst zur naechsten Verlaengerung um, die Seite bleibt offen und sagt es
                info = UFOfferText.pendingNote(plan, at: ent.expiresAt) + " Bis dahin bleibt \(before.name)."
            } else if ProAISignInHint.asksAfterPurchase(plan: plan, serviceAvailable: studoraAccount != nil && StudoraAccountLink.available,
                                                        signedIn: studoraAccount?.user != nil, accountOpen: studoraAccount?.canSignIn == true) {
                signInAfterPurchase = true               // Karte "Dein Tarif ist aktiv" mit "Mit Apple anmelden"
            } else {
                onDone()
            }
        case .pending:
            info = "Der Kauf wartet auf Bestätigung (z. B. durch die Familienfreigabe). Sobald er bestätigt ist, wird der Tarif freigeschaltet."
        case .cancelled, .failed:
            break                                    // Seite bleibt; Fehler zeigt die Fehlerkarte
        }
    }

    // MARK: Hinweise

    private func errorCard(_ text: String) -> some View {
        UFCard(flat: true) {
            // iPhone: Knopf unter dem Text (daneben blieb fuer den Text nur ein schmaler Streifen)
            let layout = (UFCompact.phoneLayouts && hSize == .compact) ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                HStack(alignment: (UFCompact.phoneLayouts && hSize == .compact) ? .top : .center, spacing: 12) {
                    UFIcon("alert", size: 18).foregroundStyle(UF.bad)
                    Text(text).ufFont(14.5).foregroundStyle(UF.text)
                }
                Spacer(minLength: (UFCompact.phoneLayouts && hSize == .compact) ? 0 : 8)
                UFButton("Erneut versuchen", icon: "refresh", size: .small) { Task { await store.loadProducts() } }
                    .disabled(store.loadingProducts)
            }
        }
    }

    @Environment(\.horizontalSizeClass) private var hSize

    private func infoCard(_ text: String) -> some View {
        UFCard(flat: true) {
            HStack(spacing: 12) {
                UFIcon("info", size: 18).foregroundStyle(UF.info)
                Text(text).ufFont(14.5).foregroundStyle(UF.text)
                Spacer(minLength: 0)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12.8) {
            UFFlexWrap(gap: 8) {
                UFButton("Käufe wiederherstellen", icon: "refresh", kind: .normal, size: .small) {
                    Task { await store.restore() }
                }
                .disabled(store.busy)
                // nur mit gekauftem Abo (in der Probe gibt es nichts zu verwalten)
                if context != .settings && !ent.loading && ent.purchasedPlan != .free {
                    UFButton("Abo verwalten", icon: "settings", kind: .ghost, size: .small) { manage = true }
                }
                UFFlexSpacer()
                // oeffnen die Seiten auf studinow.app in Safari (Texte in docs/release, Website site/)
                ForEach(LegalPage.allCases) { page in
                    UFButton(page.rawValue, kind: .ghost, size: .small) { openURL(page.url) }
                }
            }
            Text(Self.legalText).ufFont(12.8).foregroundStyle(UF.muted)
        }
    }

    /// Pflichtangaben unter den Karten (Richtlinie 3.1.2)
    static var legalText: String {
        var s = "Die Zahlung läuft über deine Apple-ID. StudiNow Plus monatlich sowie StudiNow Pro AI monatlich und jährlich sind Abos mit automatischer Verlängerung: Sie verlängern sich um ihren Zeitraum, wenn sie nicht spätestens 24 Stunden vor Ablauf gekündigt werden. Kündigen kannst du jederzeit unter „Abo verwalten“ oder in den Einstellungen deiner Apple-ID; der Zugang bleibt bis zum Ende des bezahlten Zeitraums. "
        s += "Das Bachelor+Master-Paket (StudiNow Plus für 5 Jahre) bezahlst du einmal; es gilt 5 Jahre ab dem Kauf und verlängert sich nicht. "
        // Wechsel zwischen Abo-Tarifen gibt es erst, wenn mehr als ein Abo angeboten wird (ab V2)
        if UFPlanCatalog.sellable.filter({ $0.productID != nil }).count > 1 {
            s += "Die Abo-Tarife gehören zu einem Abo: Ein Wechsel zu einem höheren Tarif gilt sofort, zu einem kleineren ab der nächsten Verlängerung, zwischen monatlich und jährlich ab der nächsten Verlängerung. "
        }
        return s + "Die StudiNow-KI braucht Credits. Deine Notizen bleiben in jedem Tarif erhalten."
    }
}

/// Oeffentliche Seiten von StudiNow auf der Website studinow.app (Stand 03.11.2026; Texte in docs/release, Seiten in
/// site/, Angaben des Inhabers in docs/release/angaben.json). Die Tarifseite verlinkt Nutzungsbedingungen und
/// Datenschutzerklaerung (Richtlinie 3.1.2), die Einstellungen alle Seiten und das Support-Postfach; dieselben Adressen
/// stehen in App Store Connect (Support-URL, Datenschutz-URL, docs/release/APP-STORE.md).
enum UFLegalLinks {
    static let site = URL(string: "https://studinow.app")!
    static let terms = URL(string: "https://studinow.app/nutzungsbedingungen")!
    static let privacy = URL(string: "https://studinow.app/datenschutz")!
    static let imprint = URL(string: "https://studinow.app/impressum")!
    static let support = URL(string: "https://studinow.app/support")!
    static let deleteAccount = URL(string: "https://studinow.app/konto-loeschen")!
    static let supportEmail = "support@studinow.app"
    static let supportMail = URL(string: "mailto:" + supportEmail)!
    static let all: [URL] = [site, terms, privacy, imprint, support, deleteAccount]
    /// Text der Karte "Rechtliches & Support" in den Einstellungen
    static let settingsIntro = "Fragen, Fehler und Wünsche an \(supportEmail). Nutzungsbedingungen, Datenschutzerklärung und Impressum stehen auf studinow.app."
}

/// Karte wie .card (UFCard), aber so hoch wie die Rasterzeile, damit die Knoepfe aller Tarife unten auf einer Linie
/// stehen (UFCard nimmt immer die natuerliche Hoehe). Aktueller Tarif: Rand in --accent.
private struct PlanCardFrame<Content: View>: View {
    var highlight = false
    @ViewBuilder let content: Content

    init(highlight: Bool = false, @ViewBuilder content: () -> Content) {
        self.highlight = highlight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, 17.6 + ufB)
            .padding(.horizontal, 19.2 + ufB)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(highlight ? UF.accent : UF.line, lineWidth: highlight ? 2 : 1))
            .ufShadow(.sm)
    }
}

/// Karte "Unser Special" (Bachelor+Master-Paket, Inhaber 27.11.2026): eigene, auffaellige Karte im StudiNow-Design –
/// Flaeche im weichen Akzent, kraeftiger Akzentrand, groesserer Schatten. So hoch wie ihr Inhalt.
struct PlanSpecialFrame<Content: View>: View {
    var highlight = false
    @ViewBuilder let content: Content

    init(highlight: Bool = false, @ViewBuilder content: () -> Content) {
        self.highlight = highlight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, 22 + ufB)
            .padding(.horizontal, 22 + ufB)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: UF.r + 6, style: .continuous)
                    .fill(LinearGradient(colors: [UF.accentSoft, UF.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: UF.r + 6, style: .continuous).strokeBorder(UF.accent, lineWidth: highlight ? 3 : 2.5))
            .ufShadow(.lg)
    }
}

/// Abzeichen "Unser Special": gefuellt in der Akzentfarbe mit Stern
struct PlanSpecialBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            UFIcon("star", size: 13)
            Text(text).ufFont(13.12, 750, em: 0.02)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 6).padding(.horizontal, 12)
        .background(Capsule().fill(UF.accentFill))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plans.special.badge")
    }
}

/// Ersparnis gegenueber dem Monatsabo (`UFOffer.savings` aus plans.json): "Du sparst …" und "nur … im Monat"
struct PlanSavingsLine: View {
    let savings: UFOfferSavings
    /// im Special groesser und in der Akzentfarbe hinterlegt
    var strong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                UFIcon("check", size: 15).foregroundStyle(strong ? UF.accentText : UF.ok).padding(.top, 1.5)
                Text(savings.text).ufFont(strong ? 15.2 : 13.6, 650).foregroundStyle(strong ? UF.accentText : UF.ok)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(savings.perMonthText).ufFont(strong ? 14.5 : 13.12, 600).foregroundStyle(UF.text2).padding(.leading, 23)
        }
        .padding(.vertical, strong ? 10 : 0).padding(.horizontal, strong ? 12 : 0)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(strong ? UF.surface.opacity(0.85) : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plans.savings")
    }
}

/// Was ein Tarif kann (Inhaber 27.11.2026: bei jedem Tarif die vollstaendige Liste): Ueberschrift ("Alles für den
/// Uni-Alltag:", "Alles aus StudiNow Free, dazu:", "Alles aus StudiNow Plus, dazu:") und alle Zeilen aus `UFPlanCard.rows`
/// – nur, was auf dem Geraet wirklich geht. `columns`: auf breiten Karten zweispaltig.
struct PlanFeatureList: View {
    let plan: UFPlan
    var columns = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(UFPlanCard.intro(plan)).ufFont(13.12, 600).foregroundStyle(UF.text2).padding(.bottom, 6.4)
            if columns {
                UFGridLayout(spacing: 8, minWidth: 260) {
                    ForEach(UFPlanCard.rows(plan), id: \.title) { PlanFeatureRow(row: $0) }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(UFPlanCard.rows(plan), id: \.title) { PlanFeatureRow(row: $0) }
                }
            }
        }
    }
}

struct PlanFeatureRow: View {
    let row: UFPlanCardRow

    var body: some View {
        HStack(alignment: .top, spacing: 8.8) {
            UFIcon("check", size: 16).foregroundStyle(UF.ok).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1.6) {
                Text(row.title).ufFont(14.5, 500).foregroundStyle(UF.text)
                if let d = row.detail { Text(d).ufFont(12.8).foregroundStyle(UF.muted) }
            }
            // immer umbrechen statt kuerzen (lange Zeilen wie die KI-Hilfe wurden sonst mit "…" abgeschnitten)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PlanPickerView.accessibilityLabel(row))
    }
}

/// Hinweis vor dem Kauf (§ 327h BGB, `UFPurchaseNotice`): deutlich und gesondert ueber den Karten, mit Haken. Ohne Haken
/// gehen die Kaufknoepfe nicht; der Haken wird gemerkt (einmal bestaetigt reicht).
struct PurchaseNoticeCard: View {
    @Binding var confirmed: Bool

    var body: some View {
        UFCard(flat: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    UFIcon("info", size: 18).foregroundStyle(UF.warn).padding(.top, 1).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(UFPurchaseNotice.title).ufFont(14.5, 650).foregroundStyle(UF.text)
                            .accessibilityAddTraits(.isHeader)
                        Text(UFPurchaseNotice.text).ufFont(13.6).foregroundStyle(UF.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("plans.notice.text")
                    }
                }
                Button { confirmed.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: confirmed ? "checkmark.square.fill" : "square")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(confirmed ? UF.accentFill : UF.muted)
                        Text(UFPurchaseNotice.confirm).ufFont(14.5, 600).foregroundStyle(UF.text)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(UFPurchaseNotice.confirm)
                .accessibilityValue(confirmed ? "ausgewählt" : "nicht ausgewählt")
                .accessibilityAddTraits(confirmed ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("plans.notice.confirm")
            }
        }
    }
}
