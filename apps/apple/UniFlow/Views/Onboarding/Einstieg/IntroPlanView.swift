import StoreKit
import SwiftUI

// Probe und Tarife (neuer Einstieg, vorletzter Schritt): oben auf der Buehne die laufende 7-Tage-Probe ("alles wie Plus,
// ohne Zahlungsdaten", `UFLocalTrial` startet sie mit der Anmeldung von selbst) und was sie freischaltet
// (`UFPlanCard.included`, nur was auf dem iPad wirklich geht). Darunter "Und nach der Probe?" in drei Bereichen
// (Inhaber 27.11.2026): Monatlich Free, Plus 1,99, Pro AI 3,99; Jaehrlich Pro AI 39,99 mit Ersparnis; "Unser Special" das
// Bachelor+Master-Paket (Plus 5 Jahre einmalig) stark hervorgehoben. Jede Kachel mit der vollstaendigen Liste, was der
// Tarif kann (`PlanFeatureList`). Preise nur aus StoreKit (`Product.displayPrice`), Angebote nur mit Produkt aus dem Store. Hauptknopf: mit Free/der Probe
// weiter oder das gewaehlte Abo kaufen, vorher der Hinweis mit Haken (§ 327h BGB, `UFPurchaseNotice`; ohne Haken geht
// der Kauf nicht). Darunter die Pflichtangaben (Richtlinie 3.1.2): Laufzeit,
// Verlaengerung, Kuendigung, Kaeufe wiederherstellen, Nutzungsbedingungen, Datenschutzerklaerung. "Alle Details
// vergleichen" oeffnet die bisherige Tarifseite (`PlanPickerView`). Keine erfundenen Preise oder Versprechen.

/// Texte der Seite
enum IntroPlanText {
    static let badge = "Probe aktiv"
    static func days(_ n: Int) -> String { "noch \(n) \(n == 1 ? "Tag" : "Tage")" }
    static func headline(proAI: Bool) -> String {
        proAI ? "7 Tage alles von \(UFLocalTrial.plan.name) – ohne Zahlungsdaten" : "7 Tage alles von StudiNow – ohne Zahlungsdaten"
    }
    static let sub = "Danach gilt \(UFPlan.free.name), wenn du nichts wählst. Alles, was du anlegst, bleibt erhalten."
    static let usedHeadline = "Wähle, wie du StudiNow nutzt"
    static let nowTitle = "Das hast du jetzt"
    static let afterTitle = "Und nach der Probe?"
    static let compare = "Alle Details vergleichen"
    static let startTrial = "Mit der Probe loslegen"
    static let startFree = "Mit \(UFPlan.free.name) loslegen"
}

/// Tarif-Schritt am Kaufsystem; `onDone` nach "loslegen" oder einem Kauf
struct IntroPlanView: View {
    let onDone: () -> Void
    @StateObject private var store: PurchaseStore
    @ObservedObject private var ent: Entitlements
    /// gewaehltes Angebot; nil = Free bzw. die Probe
    @State private var selected: UFOffer?
    @State private var details = false
    @State private var info: String?
    @Environment(\.openURL) private var openURL
    /// Hinweis vor dem Kauf bestaetigt (einmal reicht, `UFPurchaseNotice`)
    @State private var noticeConfirmed = UFPurchaseNotice.isConfirmed(in: UFPurchaseNotice.defaults)

    @MainActor
    init(entitlements: Entitlements? = nil, onDone: @escaping () -> Void) {
        let e = entitlements ?? .shared
        _store = StateObject(wrappedValue: PurchaseStore(entitlements: e))
        _ent = ObservedObject(wrappedValue: e)
        self.onDone = onDone
    }

    var body: some View {
        IntroPlanLayout(trialDays: ent.runningTrial?.daysLeft, proAIOffered: offered.contains { $0.plan == .proAI }, offers: offered,
                        selected: $selected, price: price, loading: store.loadingProducts, busy: store.busy,
                        message: info ?? store.lastError, onPrimary: primary, onCompare: { details = true },
                        onRestore: { Task { await store.restore() } }, onLegal: { openURL($0) },
                        notice: Binding(get: { noticeConfirmed }, set: { on in
                            noticeConfirmed = on
                            UFPurchaseNotice.confirm(in: UFPurchaseNotice.defaults, on)
                        }))
            .task {
                await store.loadProducts()
                await store.refreshEntitlements()
            }
            .ufSheet(isPresented: $details) {
                ScrollView { PlanPickerView(context: .onboarding, entitlements: ent) { details = false; onDone() } }
                    .background(UF.bg)
            }
    }

    /// Angebote zur Wahl (neben Free): Plus monatlich immer, die anderen nur mit Produkt aus StoreKit
    private var offered: [UFOffer] {
        UFOffer.allCases.filter { $0 == .plusMonthly || store.loadedProductIDs.contains($0.productID) }
    }

    private func price(_ o: UFOffer) -> IntroPlanPrice? {
        guard let p = store.product(for: o) else { return nil }
        let savings = o.savings.flatMap {
            UFOfferText.savingsApply(o, price: p.price, currency: p.priceFormatStyle.currencyCode,
                                     comparePrice: o.compare.flatMap { store.product(for: $0)?.price }) ? $0 : nil
        }
        if o.kind == .nonRenewing, let years = o.years {
            return IntroPlanPrice(display: p.displayPrice, per: "einmalig", summary: UFOfferText.onceSummary(price: p.displayPrice, years: years),
                                  button: UFOfferText.onceButton(price: p.displayPrice, years: years), savings: savings)
        }
        return IntroPlanPrice(display: p.displayPrice, per: UFOfferText.per(value: p.ufPeriod.0, unit: p.ufPeriod.1),
                              summary: UFOfferText.summary(price: p.displayPrice, period: p.ufPeriod),
                              button: UFOfferText.button(plan: o.plan, price: p.displayPrice, period: p.ufPeriod), savings: savings)
    }

    private func primary() {
        guard let selected, let p = store.product(for: selected) else { onDone(); return }
        // nie ohne bestaetigten Hinweis (§ 327h BGB)
        guard UFPurchaseNotice.allowsPurchase(confirmed: noticeConfirmed) else { info = UFPurchaseNotice.needsConfirm; return }
        Task {
            info = nil
            switch await store.purchase(p) {
            case .success: onDone()
            case .pending: info = "Der Kauf wartet auf Bestätigung (z. B. durch die Familienfreigabe). Sobald er bestätigt ist, wird der Tarif freigeschaltet."
            case .cancelled, .failed: break
            }
        }
    }
}

/// Preis eines Abos aus StoreKit, fertig formatiert
struct IntroPlanPrice: Equatable {
    let display: String
    let per: String
    let summary: String
    let button: String
    /// Ersparnis aus dem Vertrag, nur wenn die Store-Preise dazu passen (`UFOfferText.savingsApply`)
    var savings: UFOfferSavings? = nil
}

/// Aufbau der Seite (ohne StoreKit, fuer Bilder und Tests)
struct IntroPlanLayout: View {
    /// Resttage der laufenden Probe; nil = keine Probe (auf diesem iPad schon genutzt)
    let trialDays: Int?
    let proAIOffered: Bool
    /// Angebote neben Free (UFOffer-Reihenfolge)
    let offers: [UFOffer]
    /// nil = Free bzw. die Probe
    @Binding var selected: UFOffer?
    let price: (UFOffer) -> IntroPlanPrice?
    var loading = false
    var busy = false
    var message: String?
    let onPrimary: () -> Void
    let onCompare: () -> Void
    let onRestore: () -> Void
    let onLegal: (URL) -> Void
    /// Hinweis vor dem Kauf (§ 327h BGB); nil nur in Bildern ohne Kauf
    var notice: Binding<Bool>? = nil

    /// Hauptknopf antippbar? Free bzw. die Probe immer, ein Kauf erst mit bestaetigtem Hinweis
    static func primaryEnabled(selected: UFOffer?, busy: Bool, confirmed: Bool?) -> Bool {
        !busy && (selected == nil || confirmed != false)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    IntroPlanHero(trialDays: trialDays, proAI: proAIOffered, wide: geo.size.width >= 900)
                        .padding(16)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(trialDays == nil ? "Tarif wählen" : IntroPlanText.afterTitle)
                            .ufFont(22, 700, em: -0.01).foregroundStyle(UF.text)
                            .accessibilityAddTraits(.isHeader)
                        IntroPlanTiles(offers: offers, selected: $selected, price: price, loading: loading, trial: trialDays != nil)
                        if let message {
                            Text(message).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        if selected != nil, let notice {
                            PurchaseNoticeCard(confirmed: notice)
                        }
                        VStack(spacing: 10) {
                            IntroCTA(title: ctaTitle, icon: selected == nil ? "arrow-right" : nil,
                                     enabled: Self.primaryEnabled(selected: selected, busy: busy, confirmed: notice?.wrappedValue), action: onPrimary)
                                .accessibilityIdentifier("intro.plan.primary")
                            if let selected, let p = price(selected) {
                                Text(p.summary).ufFont(12.8).foregroundStyle(UF.muted).multilineTextAlignment(.center)
                            }
                            Button(IntroPlanText.compare, action: onCompare)
                                .ufFont(14, 600).foregroundStyle(UF.accentText).buttonStyle(.plain).ufHitArea()
                                .accessibilityIdentifier("intro.plan.compare")
                        }
                        .frame(maxWidth: .infinity)
                        IntroPlanLegal(onRestore: onRestore, onLegal: onLegal)
                    }
                    .frame(maxWidth: 860)
                    .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(UF.bg.ignoresSafeArea())
    }

    private var ctaTitle: String {
        guard let selected else { return trialDays == nil ? IntroPlanText.startFree : IntroPlanText.startTrial }
        return price(selected)?.button ?? "\(selected.name ?? selected.plan.name) wählen"
    }
}

/// Buehne oben: Stand der Probe und was sie freischaltet
struct IntroPlanHero: View {
    let trialDays: Int?
    let proAI: Bool
    let wide: Bool

    var body: some View {
        ZStack {
            IntroStage()
            Group {
                if wide {
                    HStack(alignment: .center, spacing: 40) {
                        IntroPlanHeroText(trialDays: trialDays, proAI: proAI).frame(maxWidth: .infinity, alignment: .leading)
                        IntroPlanNowList(proAI: proAI).frame(width: 380)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        IntroPlanHeroText(trialDays: trialDays, proAI: proAI)
                        IntroPlanNowList(proAI: proAI)
                    }
                }
            }
            .padding(wide ? 40 : 24)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct IntroPlanHeroText: View {
    let trialDays: Int?
    let proAI: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IntroBuddy(size: 40)
                if let trialDays {
                    HStack(spacing: 6) {
                        UFIcon("clock", size: 13)
                        Text("\(IntroPlanText.badge) · \(IntroPlanText.days(trialDays))")
                    }
                    .ufFont(13.12, 650).foregroundStyle(IntroStyle.onStage)
                    .padding(.vertical, 6).padding(.horizontal, 12)
                    .background(Capsule().fill(.white.opacity(0.16)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    .accessibilityIdentifier("intro.plan.trial")
                }
            }
            Text(trialDays == nil ? IntroPlanText.usedHeadline : IntroPlanText.headline(proAI: proAI))
                .ufFont(30, 700, em: -0.02).foregroundStyle(IntroStyle.onStage)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(trialDays == nil ? UFTrialTexts.usedOnDeviceText : IntroPlanText.sub)
                .ufFont(15.5).foregroundStyle(IntroStyle.onStage2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Das hast du jetzt": was Plus und Pro AI mehr bieten (nur Verfuegbares, `UFPlanCard.included`)
struct IntroPlanNowList: View {
    let proAI: Bool

    private var rows: [UFPlanCardRow] {
        Array((UFPlanCard.included(.plus) + (proAI ? UFPlanCard.included(.proAI) : [])).prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(IntroPlanText.nowTitle).ufFont(13.12, 700, em: 0.04).foregroundStyle(IntroStyle.onStage2)
                .textCase(.uppercase)
            ForEach(rows, id: \.title) { r in
                HStack(alignment: .top, spacing: 12) {
                    UFIcon(r.icon, size: 15).foregroundStyle(IntroStyle.onStage)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.14)))
                    Text(r.title).ufFont(14.5, 550).foregroundStyle(IntroStyle.onStage)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
}

/// Drei Bereiche (27.11.2026): Monatlich Free, Plus, Pro AI nebeneinander (schmal untereinander), Jaehrlich Pro AI,
/// "Unser Special" das Bachelor+Master-Paket
struct IntroPlanTiles: View {
    let offers: [UFOffer]
    @Binding var selected: UFOffer?
    let price: (UFOffer) -> IntroPlanPrice?
    let loading: Bool
    let trial: Bool

    private func cards(_ g: UFOfferGroup) -> [UFPlanOfferCard] {
        (g == .monthly ? [.free] : []) + g.offers.filter(offers.contains).map { .offer($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(UFOfferGroup.allCases) { g in
                if !cards(g).isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(g.title).ufFont(13.12, 700, em: 0.04).foregroundStyle(UF.muted).textCase(.uppercase)
                            .accessibilityAddTraits(.isHeader)
                        if g == .monthly {
                            UFGridLayout(spacing: 12, minWidth: 220) {
                                ForEach(cards(g)) { tile($0) }
                            }
                            .environment(\.ufFillsCell, true)
                        } else {
                            ForEach(cards(g)) { tile($0) }
                        }
                    }
                }
            }
        }
    }

    private func tile(_ c: UFPlanOfferCard) -> some View {
        IntroPlanTile(card: c, selected: selected == c.offer, price: c.offer.flatMap(price), loading: loading, trial: trial) {
            selected = c.offer
        }
    }
}

struct IntroPlanTile: View {
    let card: UFPlanOfferCard
    let selected: Bool
    let price: IntroPlanPrice?
    let loading: Bool
    let trial: Bool
    let action: () -> Void

    private var plan: UFPlan { card.plan }
    private var special: Bool { card.offer?.highlight == true }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: special ? 20 : 16, style: .continuous) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                head
                priceLine
                if let s = price?.savings {
                    PlanSavingsLine(savings: s, strong: special).padding(.top, 2)
                }
                if let t = UFPlanCard.tagline(plan), !special {
                    Text(t).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
                if plan == .plus { Text(UFPlanCatalog.plusServiceNote).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true) }
                Rectangle().fill(special ? UF.accent.opacity(0.35) : UF.line).frame(height: 1).padding(.vertical, 6)
                PlanFeatureList(plan: plan, columns: card.offer?.group == .special || card.offer?.group == .yearly)
                Spacer(minLength: 0)
                if plan == .free && trial {
                    UFBadge("nach der Probe von selbst", tone: .neutral)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(special ? 20 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(shape.fill(background))
            .overlay(shape.strokeBorder(selected || special ? UF.accent : UF.line, lineWidth: special ? (selected ? 3.5 : 2.5) : (selected ? 2 : 1)))
            .ufShadow(special ? .lg : .none)
            .contentShape(shape)
        }
        .buttonStyle(UFPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("intro.plan.\(card.offer.map { PlanPickerView.buyIdentifier($0).replacingOccurrences(of: "plans.buy.", with: "") } ?? "free")")
    }

    private var background: AnyShapeStyle {
        if special { return AnyShapeStyle(LinearGradient(colors: [UF.accentSoft, UF.surface], startPoint: .topLeading, endPoint: .bottomTrailing)) }
        return AnyShapeStyle(selected ? UF.accentSoft.opacity(0.55) : UF.surface)
    }

    @ViewBuilder private var head: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                if special, let o = card.offer {
                    PlanSpecialBadge(text: o.badge ?? UFOfferGroup.special.title)
                    Text(o.name ?? plan.name).ufFont(20.8, 750, em: -0.02).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(UFOfferText.packageContent(years: o.years ?? 5)).ufFont(14.5, 600).foregroundStyle(UF.accentText)
                } else {
                    Text(plan.name).ufFont(16.5, 650).foregroundStyle(UF.text)
                }
            }
            Spacer(minLength: 6)
            Circle().strokeBorder(selected ? UF.accent : UF.lineStrong, lineWidth: selected ? 6.5 : 1.5)
                .frame(width: 22, height: 22)
        }
    }

    @ViewBuilder private var priceLine: some View {
        if plan == .free && card.offer == nil {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("0 €").ufFont(24, 700, em: -0.02).foregroundStyle(UF.text)
                Text("dauerhaft").ufFont(13.12).foregroundStyle(UF.muted)
            }
        } else if let price {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(price.display).ufFont(special ? 30 : 24, 700, em: -0.02).foregroundStyle(UF.text)
                Text(price.per).ufFont(13.12).foregroundStyle(UF.muted)
            }
            if special {
                Text(price.summary).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(loading ? "Preis wird geladen …" : "Preis zurzeit nicht verfügbar").ufFont(13.12).foregroundStyle(UF.muted)
                .frame(minHeight: 32, alignment: .leading)
        }
    }
}

/// Pflichtangaben und Links (Richtlinie 3.1.2)
struct IntroPlanLegal: View {
    let onRestore: () -> Void
    let onLegal: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UFFlexWrap(gap: 8) {
                UFButton("Käufe wiederherstellen", icon: "refresh", kind: .ghost, size: .small, action: onRestore)
                UFFlexSpacer()
                ForEach(PlanPickerView.LegalPage.allCases) { page in
                    UFButton(page.rawValue, kind: .ghost, size: .small) { onLegal(page.url) }
                }
            }
            Text(PlanPickerView.legalText).ufFont(12.16).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            Text(UFTrialTexts.perAppleID).ufFont(12.16).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }
}
