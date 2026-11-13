import StoreKit
import SwiftUI

// Probe und Tarife (neuer Einstieg, vorletzter Schritt): oben auf der Buehne die laufende 7-Tage-Probe ("alles wie Pro AI,
// ohne Zahlungsdaten", `UFLocalTrial` startet sie mit der Anmeldung von selbst) und was sie freischaltet
// (`UFPlanCard.included`, nur was auf dem iPad wirklich geht). Darunter "Und nach der Probe?": Free, Plus, Pro AI als
// Kacheln, Preise nur aus StoreKit (`Product.displayPrice`, Jahresabo), Pro AI nur mit Produkt aus dem Store. Hauptknopf:
// mit Free/der Probe weiter oder das gewaehlte Abo kaufen. Darunter die Pflichtangaben (Richtlinie 3.1.2): Laufzeit,
// Verlaengerung, Kuendigung, Kaeufe wiederherstellen, Nutzungsbedingungen, Datenschutzerklaerung. "Alle Details
// vergleichen" oeffnet die bisherige Tarifseite (`PlanPickerView`). Keine erfundenen Preise oder Versprechen.

/// Texte der Seite
enum IntroPlanText {
    static let badge = "Probe aktiv"
    static func days(_ n: Int) -> String { "noch \(n) \(n == 1 ? "Tag" : "Tage")" }
    static func headline(proAI: Bool) -> String {
        proAI ? "7 Tage alles von \(UFPlan.proAI.name) – ohne Zahlungsdaten" : "7 Tage alles von StudiNow – ohne Zahlungsdaten"
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
    @State private var selected: UFPlan = .free
    @State private var details = false
    @State private var info: String?
    @Environment(\.openURL) private var openURL

    @MainActor
    init(entitlements: Entitlements? = nil, onDone: @escaping () -> Void) {
        let e = entitlements ?? .shared
        _store = StateObject(wrappedValue: PurchaseStore(entitlements: e))
        _ent = ObservedObject(wrappedValue: e)
        self.onDone = onDone
    }

    var body: some View {
        IntroPlanLayout(trialDays: ent.runningTrial?.daysLeft, proAIOffered: offered.contains(.proAI), plans: offered,
                        selected: $selected, price: price, loading: store.loadingProducts, busy: store.busy,
                        message: info ?? store.lastError, onPrimary: primary, onCompare: { details = true },
                        onRestore: { Task { await store.restore() } }, onLegal: { openURL($0) })
            .task {
                await store.loadProducts()
                await store.refreshEntitlements()
            }
            .sheet(isPresented: $details) {
                ScrollView { PlanPickerView(context: .onboarding, entitlements: ent) { details = false; onDone() } }
                    .background(UF.bg)
            }
    }

    /// Tarife zur Wahl: Free, Plus und Pro AI nur mit Produkt aus StoreKit
    private var offered: [UFPlan] { UFPlanCatalog.cards(current: ent.purchasedPlan, loaded: store.loadedProductIDs) }

    private func price(_ plan: UFPlan) -> IntroPlanPrice? {
        guard plan != .free, let p = store.product(for: plan) else { return nil }
        return IntroPlanPrice(display: p.displayPrice, per: UFOfferText.per(value: p.ufPeriod.0, unit: p.ufPeriod.1),
                              summary: UFOfferText.summary(price: p.displayPrice, period: p.ufPeriod),
                              button: UFOfferText.button(plan: plan, price: p.displayPrice, period: p.ufPeriod))
    }

    private func primary() {
        guard selected != .free, let p = store.product(for: selected) else { onDone(); return }
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
}

/// Aufbau der Seite (ohne StoreKit, fuer Bilder und Tests)
struct IntroPlanLayout: View {
    /// Resttage der laufenden Probe; nil = keine Probe (auf diesem iPad schon genutzt)
    let trialDays: Int?
    let proAIOffered: Bool
    let plans: [UFPlan]
    @Binding var selected: UFPlan
    let price: (UFPlan) -> IntroPlanPrice?
    var loading = false
    var busy = false
    var message: String?
    let onPrimary: () -> Void
    let onCompare: () -> Void
    let onRestore: () -> Void
    let onLegal: (URL) -> Void

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
                        IntroPlanTiles(plans: plans, selected: $selected, price: price, loading: loading, trial: trialDays != nil)
                        if let message {
                            Text(message).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(spacing: 10) {
                            IntroCTA(title: ctaTitle, icon: selected == .free ? "arrow-right" : nil, enabled: !busy, action: onPrimary)
                                .accessibilityIdentifier("intro.plan.primary")
                            if selected != .free, let p = price(selected) {
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
        if selected == .free { return trialDays == nil ? IntroPlanText.startFree : IntroPlanText.startTrial }
        return price(selected)?.button ?? "\(selected.name) wählen"
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

/// Free, Plus, Pro AI nebeneinander (schmal untereinander)
struct IntroPlanTiles: View {
    let plans: [UFPlan]
    @Binding var selected: UFPlan
    let price: (UFPlan) -> IntroPlanPrice?
    let loading: Bool
    let trial: Bool

    var body: some View {
        UFGridLayout(spacing: 12, minWidth: 220) {
            ForEach(plans, id: \.self) { p in
                IntroPlanTile(plan: p, selected: selected == p, price: price(p), loading: loading, trial: trial) {
                    selected = p
                }
            }
        }
        .environment(\.ufFillsCell, true)
    }
}

struct IntroPlanTile: View {
    let plan: UFPlan
    let selected: Bool
    let price: IntroPlanPrice?
    let loading: Bool
    let trial: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(plan.name).ufFont(16.5, 650).foregroundStyle(UF.text)
                    Spacer(minLength: 6)
                    Circle().strokeBorder(selected ? UF.accent : UF.lineStrong, lineWidth: selected ? 6.5 : 1.5)
                        .frame(width: 22, height: 22)
                }
                priceLine
                if let t = UFPlanCard.tagline(plan) {
                    Text(t).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if plan == .free && trial {
                    UFBadge("nach der Probe von selbst", tone: .neutral)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? UF.accentSoft.opacity(0.55) : UF.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? UF.accent : UF.line, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(UFPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("intro.plan.\(plan.rawValue)")
    }

    @ViewBuilder private var priceLine: some View {
        if plan == .free {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("0 €").ufFont(24, 700, em: -0.02).foregroundStyle(UF.text)
                Text("dauerhaft").ufFont(13.12).foregroundStyle(UF.muted)
            }
        } else if let price {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(price.display).ufFont(24, 700, em: -0.02).foregroundStyle(UF.text)
                Text(price.per).ufFont(13.12).foregroundStyle(UF.muted)
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
