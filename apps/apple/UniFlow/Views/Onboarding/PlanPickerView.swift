import StoreKit
import SwiftUI

// Tarifwahl (docs/AUFTRAG-APPSTORE-V1.md, Abschnitt 2a Schritt 2, Abschnitt 4 und 5): drei Karten Free / Plus / Pro.
// Preise nur aus Product.displayPrice; "1 Woche gratis" nur bei Anspruch auf das Einfuehrungsangebot.
// Dieselbe Ansicht dient beim ersten Start, in den Einstellungen ("Tarif wechseln", "Abo verwalten") und hinter
// gesperrten Funktionen (UFPlanSheet).

struct PlanPickerView: View {
    enum Context {
        /// erster Start: "Free nutzen" bzw. erfolgreicher Kauf -> onDone
        case onboarding
        /// Einstellungen: aktueller Tarif, Abo verwalten
        case settings
        /// aus einer gesperrten Funktion heraus
        case upgrade
    }

    var context: Context = .onboarding
    let onDone: () -> Void

    @StateObject private var store: PurchaseStore
    @ObservedObject private var ent: Entitlements
    @State private var manage = false
    @State private var legal: LegalPage?
    @State private var info: String?

    /// `entitlements: nil` = `Entitlements.shared` (erst im MainActor-Kontext aufgeloest, Swift 6)
    @MainActor
    init(context: Context = .onboarding, entitlements: Entitlements? = nil, onDone: @escaping () -> Void) {
        let ent = entitlements ?? .shared
        self.context = context
        self.onDone = onDone
        _store = StateObject(wrappedValue: PurchaseStore(entitlements: ent))
        _ent = ObservedObject(wrappedValue: ent)
    }

    enum LegalPage: String, Identifiable {
        case terms = "Nutzungsbedingungen"
        case privacy = "Datenschutzerklärung"
        var id: String { rawValue }
    }

    var body: some View {
        UFContent(maxWidth: 1180) {
            UFPageHead(title, sub: subtitle)
            if let e = store.lastError { errorCard(e).padding(.bottom, 16) }
            if let info { infoCard(info).padding(.bottom, 16) }
            UFGridLayout(spacing: 16, minWidth: 280) {
                planCard(.free)
                planCard(.plus)
                planCard(.pro)
            }
            .environment(\.ufFillsCell, true)
            if !UFFeatureMatrix.aiServiceAvailable { aiNote.padding(.top, 16) }
            footer.padding(.top, 22.4)
        }
        .task {
            await store.loadProducts()
            await store.refreshEntitlements()
        }
        .manageSubscriptionsSheet(isPresented: $manage)
        .onChange(of: manage) { _, open in
            // nach dem Verwalten (Kuendigen, Wechsel) den Tarif neu lesen
            if !open { Task { await store.refreshEntitlements(); await store.refreshEligibility() } }
        }
        // Anspruch auf die Probewoche gilt je Abo-Gruppe: nach jedem Tarifwechsel und jeder neuen Transaktion
        // (Kauf auf dieser Seite, Wiederherstellen, Transaction.updates) fuer alle Tarife neu lesen
        .onChange(of: ent.plan) { _, _ in Task { await store.refreshEligibility() } }
        .onChange(of: ent.transactionCount) { _, _ in Task { await store.refreshEligibility() } }
        .ufModal(isPresented: Binding(get: { legal != nil }, set: { if !$0 { legal = nil } })) {
            if let legal { legalDialog(legal) }
        }
    }

    // MARK: Kopf

    private var title: String {
        switch context {
        case .onboarding: return "Tarif wählen"
        case .settings: return "Tarif"
        case .upgrade: return "Mehr mit Plus und Pro"
        }
    }

    private var subtitle: String {
        let trial = UFPlan.allCases.contains { p in
            guard let pr = store.product(for: p) else { return false }
            return store.introEligible[pr.id] == true && pr.ufFreeTrial != nil
        }
        let base = "Free bleibt dauerhaft kostenlos."
        if trial { return base + " Plus und Pro kannst du zuerst eine Woche gratis nutzen." }
        return base + " Du kannst den Tarif jederzeit wechseln."
    }

    // MARK: Karten

    private func planCard(_ plan: UFPlan) -> some View {
        let current = !ent.loading && ent.plan == plan
        return PlanCardFrame(highlight: current && context != .onboarding) {
            HStack(spacing: 8) {
                Text(plan.title).ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text)
                Spacer(minLength: 0)
                if current && context != .onboarding { UFBadge("Aktueller Tarif", tone: .ok, icon: "check") }
            }
            priceBlock(plan).padding(.top, 6.4)
            Rectangle().fill(UF.line).frame(height: 1).padding(.vertical, 14.4)
            Text(plan == .free ? "Alles für den Uni-Alltag:" : plan == .plus ? "Alles aus Free, dazu:" : "Alles aus Plus, dazu:")
                .ufFont(13.12, 600).foregroundStyle(UF.text2).padding(.bottom, 6.4)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows(plan), id: \.title) { r in featureRow(r) }
            }
            if !UFFeatureMatrix.hasAvailableExtras(in: plan) {
                // ehrlich sagen, dass der Tarif heute noch nicht mehr bietet (Abschnitt 2 Punkt 4: nichts vortaeuschen)
                Text("Diese Funktionen folgen mit einem Update. Bis dahin bietet \(plan.title) denselben Umfang wie \(plan == .pro ? "Plus" : "Free").")
                    .ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 9.6)
            }
            Spacer(minLength: 16)
            actionButton(plan, current: current)
            if current, context == .settings, plan != .free, ent.inIntroOffer {
                Text(trialEndText).ufFont(11.84).foregroundStyle(UF.muted).padding(.top, 6.4)
            }
        }
    }

    private struct Row {
        let title: String
        var detail: String?
        var icon: String
        var soon = false
    }

    /// Inhalte aus Abschnitt 4; KI-Zeilen nur mit freigegebenem KI-Dienst
    private func rows(_ plan: UFPlan) -> [Row] {
        var out = UFFeatureMatrix.added(in: plan).filter { !$0.isV2 }.map { f in
            Row(title: f.title, detail: f.detail, icon: f.icon, soon: UFFeatureMatrix.access(f, plan: plan) == .comingSoon)
        }
        if UFFeatureMatrix.aiServiceAvailable {
            out.append(Row(title: "\(plan.aiTestQuota) Wochentests mit KI im Monat", icon: UFFeature.aiTests.icon))
            if plan == .pro { out.append(Row(title: UFFeature.aiTutor.title, detail: UFFeature.aiTutor.detail, icon: UFFeature.aiTutor.icon)) }
        }
        return out
    }

    private func featureRow(_ r: Row) -> some View {
        HStack(alignment: .top, spacing: 8.8) {
            UFIcon("check", size: 16).foregroundStyle(UF.ok).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1.6) {
                HStack(spacing: 6.4) {
                    Text(r.title).ufFont(14.5, 500).foregroundStyle(UF.text)
                    if r.soon { UFBadge("bald", tone: .neutral) }
                }
                if let d = r.detail { Text(d).ufFont(12.8).foregroundStyle(UF.muted) }
            }
        }
    }

    @ViewBuilder
    private func priceBlock(_ plan: UFPlan) -> some View {
        if plan == .free {
            VStack(alignment: .leading, spacing: 2) {
                Text("0 €").ufFont(26, 700, lh: 1.2, em: -0.02).foregroundStyle(UF.text)
                Text("dauerhaft kostenlos, ohne Abo").ufFont(13.12).foregroundStyle(UF.muted)
            }
        } else if let p = store.product(for: plan) {
            let eligible = store.introEligible[p.id] == true
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3.2) {
                    Text(p.displayPrice).ufFont(26, 700, lh: 1.2, em: -0.02).foregroundStyle(UF.text)
                    Text(UFOfferText.per(value: p.ufPeriod.0, unit: p.ufPeriod.1)).ufFont(14.5).foregroundStyle(UF.muted)
                }
                Text(UFOfferText.summary(price: p.displayPrice, period: p.ufPeriod, freeTrial: p.ufFreeTrial, eligible: eligible))
                    .ufFont(13.12, eligible && p.ufFreeTrial != nil ? 600 : 400)
                    .foregroundStyle(eligible && p.ufFreeTrial != nil ? UF.accentText : UF.muted)
            }
        } else if store.loadingProducts {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preis wird geladen …").ufFont(13.12).foregroundStyle(UF.muted)
            }
            .frame(minHeight: 50, alignment: .leading)
        } else {
            Text("Preis zurzeit nicht verfügbar").ufFont(13.12).foregroundStyle(UF.muted)
                .frame(minHeight: 50, alignment: .leading)
        }
    }

    @ViewBuilder
    private func actionButton(_ plan: UFPlan, current: Bool) -> some View {
        if plan == .free {
            if context == .settings && !current {
                // Wechsel auf Free = Abo bei Apple kuendigen; der Zugang endet mit dem laufenden Zeitraum
                fullButton("Zu Free wechseln", kind: .normal) { manage = true }
            } else if context == .settings {
                fullButton("Aktueller Tarif", kind: .normal, enabled: false) {}
            } else {
                fullButton("Free nutzen", kind: .normal) { onDone() }
            }
        } else if current {
            if context == .settings {
                fullButton("Abo verwalten", icon: "settings", kind: .normal) { manage = true }
            } else {
                fullButton("Weiter mit \(plan.title)", kind: .primary) { onDone() }
            }
        } else if let p = store.product(for: plan) {
            let label = UFOfferText.button(plan: plan, price: p.displayPrice, period: p.ufPeriod, freeTrial: p.ufFreeTrial,
                                           eligible: store.introEligible[p.id] == true)
            fullButton(label, kind: .primary, enabled: !store.busy) { Task { await buy(p) } }
        } else {
            fullButton("\(plan.title) wählen", kind: .primary, enabled: false) {}
        }
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

    private func buy(_ p: Product) async {
        info = nil
        switch await store.purchase(p) {
        case .success:
            onDone()
        case .pending:
            info = "Der Kauf wartet auf Bestätigung (z. B. durch die Familienfreigabe). Sobald er bestätigt ist, wird der Tarif freigeschaltet."
        case .cancelled, .failed:
            break                                    // Seite bleibt; Fehler zeigt die Fehlerkarte
        }
    }

    private var trialEndText: String {
        guard let d = ent.expiresAt else { return "Gratiswoche läuft." }
        return "Gratiswoche bis \(d.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "de_DE")))). Danach verlängert sich das Abo, wenn du nicht kündigst."
    }

    // MARK: Hinweise

    private func errorCard(_ text: String) -> some View {
        UFCard(flat: true) {
            HStack(spacing: 12) {
                UFIcon("alert", size: 18).foregroundStyle(UF.bad)
                Text(text).ufFont(14.5).foregroundStyle(UF.text)
                Spacer(minLength: 8)
                UFButton("Erneut versuchen", icon: "refresh", size: .small) { Task { await store.loadProducts() } }
                    .disabled(store.loadingProducts)
            }
        }
    }

    private func infoCard(_ text: String) -> some View {
        UFCard(flat: true) {
            HStack(spacing: 12) {
                UFIcon("info", size: 18).foregroundStyle(UF.info)
                Text(text).ufFont(14.5).foregroundStyle(UF.text)
                Spacer(minLength: 0)
            }
        }
    }

    private var aiNote: some View {
        HStack(spacing: 10) {
            UFIcon("sparkles", size: 16).foregroundStyle(UF.muted)
            Text("KI-Funktionen wie Wochentests und Tutor sind noch nicht freigeschaltet und in keinem Tarif enthalten.")
                .ufFont(13.12).foregroundStyle(UF.muted)
            UFBadge("bald", tone: .neutral)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12.8) {
            UFFlexWrap(gap: 8) {
                UFButton("Käufe wiederherstellen", icon: "refresh", kind: .normal, size: .small) {
                    Task { await store.restore() }
                }
                .disabled(store.busy)
                if context != .settings && ent.plan != .free {
                    UFButton("Abo verwalten", icon: "settings", kind: .ghost, size: .small) { manage = true }
                }
                UFFlexSpacer()
                UFButton(LegalPage.terms.rawValue, kind: .ghost, size: .small) { legal = .terms }
                UFButton(LegalPage.privacy.rawValue, kind: .ghost, size: .small) { legal = .privacy }
            }
            Text("Die Zahlung läuft über deine Apple-ID. Abos verlängern sich automatisch, wenn sie nicht spätestens 24 Stunden vor Ablauf gekündigt werden. Kündigen kannst du jederzeit unter „Abo verwalten“ oder in den Einstellungen deiner Apple-ID. Deine Notizen bleiben in jedem Tarif erhalten.")
                .ufFont(12.8).foregroundStyle(UF.muted)
        }
    }

    /// Es gibt noch keine Rechtstexte (Entscheidung des Inhabers offen, Abschnitt 6): ehrliche Platzhalterseite
    private func legalDialog(_ page: LegalPage) -> some View {
        UFDialog(page.rawValue, icon: "file-text") {
            Text("Wird vor der Veröffentlichung ergänzt.").ufFont(14.5).foregroundStyle(UF.text2)
        } foot: {
            UFButton("Schließen", kind: .primary) { legal = nil }
        }
    }
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
