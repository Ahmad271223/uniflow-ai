import StoreKit
import SwiftUI

// Tarifwahl (docs/AUFTRAG-APPSTORE-V1.md, Abschnitt 2a Schritt 2, Abschnitt 4 und 5; docs/ABO-SYSTEM.md): vier Karten
// Studora Free, Plus, Pro Connect, Pro AI (Entscheidung des Inhabers vom 27.10.2026). Inhalt der Karten aus
// `UFPlanCard`: enthalten ist nur, was auf dem iPad wirklich geht; was den Online-Dienst braucht, steht unter
// "in Vorbereitung". Preise nur aus Product.displayPrice; "1 Woche gratis" nur bei Anspruch auf das
// Einfuehrungsangebot (Apple fuehrt ihn je Abo-Gruppe). Wechsel zwischen den Abo-Tarifen regelt Apple in der Gruppe.
// Dieselbe Ansicht dient beim ersten Start, in den Einstellungen ("Tarif wechseln", "Abo verwalten") und hinter
// gesperrten Funktionen (UFPlanSheet).

struct PlanPickerView: View {
    enum Context: Equatable {
        /// erster Start: "Studora Free nutzen" bzw. erfolgreicher Kauf -> onDone
        case onboarding
        /// Einstellungen: aktueller Tarif, Abo verwalten
        case settings
        /// aus einer gesperrten Funktion heraus; Tarif, der sie freischaltet
        case upgrade(UFPlan?)
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
        UFContent(maxWidth: 860) {
            UFPageHead(Self.title(context), sub: subtitle)
            if let e = store.lastError { errorCard(e).padding(.bottom, 16) }
            if let info { infoCard(info).padding(.bottom, 16) }
            UFGridLayout(spacing: 16, minWidth: 280) {
                ForEach(UFPlan.allCases) { planCard($0) }
            }
            .environment(\.ufFillsCell, true)
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

    static func title(_ context: Context) -> String {
        switch context {
        case .onboarding: return "Tarif wählen"
        case .settings: return "Tarif wechseln"
        case .upgrade(let p): return p.map { "Mehr mit \($0.name)" } ?? "Tarif wechseln"
        }
    }

    private var subtitle: String {
        // Dauer des Angebots aus dem Produkt, nicht fest im Code; der Anspruch gilt fuer die ganze Abo-Gruppe
        let plus = store.product(for: .plus)
        let trial = plus.flatMap { p in store.introEligible[p.id] == true ? p.ufFreeTrial : nil }
        return Self.subtitle(trial: trial.map { UFOfferText.period(value: $0.0, unit: $0.1) })
    }

    /// Untertitel; `trial` z. B. "1 Woche", wenn der Anspruch auf das Einfuehrungsangebot besteht
    static func subtitle(trial: String?) -> String {
        var s = "Mit \(UFPlan.free.name) planst du dein Lernen, öffnest deine Dokumente und siehst deine Fächer geordnet – dauerhaft kostenlos. "
        s += "\(UFPlan.plus.name) fügt das Schreiben mit Apple Pencil hinzu"
        s += trial.map { "; \($0) gratis zum Start. " } ?? ". "
        s += "\(UFPlan.proConnect.name) und \(UFPlan.proAI.name) enthalten alles aus \(UFPlan.plus.name); ihre weiteren Funktionen sind in Vorbereitung. "
        s += "Du kannst den Tarif jederzeit wechseln."
        return s
    }

    // MARK: Karten

    private func planCard(_ plan: UFPlan) -> some View {
        let current = !ent.loading && ent.plan == plan
        let showCurrent = current && context != .onboarding
        let included = UFPlanCard.included(plan)
        let preparing = UFPlanCard.preparing(plan)
        return PlanCardFrame(highlight: showCurrent) {
            HStack(spacing: 8) {
                Text(plan.name).ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text)
                Spacer(minLength: 0)
                if showCurrent {
                    UFBadge("Aktueller Tarif", tone: .ok, icon: "check")
                } else if !ent.loading && ent.pendingPlan == plan {
                    UFBadge("Vorgemerkt", tone: .info, icon: "clock")
                }
            }
            if let t = UFPlanCard.tagline(plan) {
                Text(t).ufFont(13.12).foregroundStyle(UF.text2).padding(.top, 3.2)
            }
            priceBlock(plan).padding(.top, 6.4)
            Rectangle().fill(UF.line).frame(height: 1).padding(.vertical, 14.4)
            Text(UFPlanCard.intro(plan)).ufFont(13.12, 600).foregroundStyle(UF.text2).padding(.bottom, 6.4)
            if !included.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(included, id: \.title) { featureRow($0) }
                }
            }
            if !preparing.isEmpty {
                UFBadge("in Vorbereitung", tone: .neutral, icon: "clock")
                    .padding(.top, included.isEmpty ? 2 : 14.4).padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(preparing, id: \.title) { featureRow($0) }
                }
            }
            if let note = UFPlanCard.note(plan) {
                Text(note).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 9.6)
            }
            Spacer(minLength: 16)
            actionButton(plan, current: current)
            if let n = buttonNote(plan, current: current) {
                Text(n).ufFont(11.84).foregroundStyle(UF.muted).padding(.top, 6.4)
            }
        }
    }

    private func featureRow(_ r: UFPlanCardRow) -> some View {
        HStack(alignment: .top, spacing: 8.8) {
            UFIcon(r.preparing ? "clock" : "check", size: 16).foregroundStyle(r.preparing ? UF.muted : UF.ok).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1.6) {
                Text(r.title).ufFont(14.5, r.preparing ? 400 : 500).foregroundStyle(r.preparing ? UF.text2 : UF.text)
                if let d = r.detail { Text(d).ufFont(12.8).foregroundStyle(UF.muted) }
            }
            // immer umbrechen statt kuerzen: die Karte ist so hoch wie die hoechste der Zeile (ufFillsCell), lange
            // Zeilen wie "Intelligente Lernplanung (Empfehlungen fuer die Woche)" wurden sonst mit "…" abgeschnitten
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(r))
    }

    /// VoiceOver: Titel, Zusatz und bei Zeilen in Vorbereitung die Marke (die Ueberschrift steht weiter oben)
    static func accessibilityLabel(_ r: UFPlanCardRow) -> String {
        ([r.title] + (r.detail.map { [$0] } ?? []) + (r.preparing ? ["in Vorbereitung"] : [])).joined(separator: ", ")
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
            // kein Preis aus dem Code (Richtlinie 3.1.2): ohne Produkt aus StoreKit kein Preis und kein Kaufknopf
            Text("Preis zurzeit nicht verfügbar").ufFont(13.12).foregroundStyle(UF.muted)
                .frame(minHeight: 50, alignment: .leading)
        }
    }

    /// laeuft gerade ein Abo (nicht Free)? Dann sind die anderen Abo-Tarife ein Wechsel in der Gruppe.
    private var hasSubscription: Bool { !ent.loading && ent.plan != .free }

    @ViewBuilder
    private func actionButton(_ plan: UFPlan, current: Bool) -> some View {
        if plan == .free {
            if context == .settings && !current {
                // Wechsel auf Free = Abo bei Apple kuendigen; der Zugang endet mit dem laufenden Zeitraum
                fullButton("Zu \(UFPlan.free.name) wechseln", kind: .normal) { manage = true }
            } else if context == .settings {
                fullButton("Aktueller Tarif", kind: .normal, enabled: false) {}
            } else {
                fullButton("\(UFPlan.free.name) nutzen", kind: .normal) { onDone() }
            }
        } else if current {
            if context == .settings {
                fullButton("Abo verwalten", icon: "settings", kind: .normal) { manage = true }
            } else {
                fullButton("Weiter mit \(plan.name)", kind: .primary) { onDone() }
            }
        } else if !ent.loading && ent.pendingPlan == plan {
            // Downgrade schon vorgemerkt: kein zweiter Kauf; aendern geht ueber "Abo verwalten"
            fullButton("Vorgemerkt", icon: "clock", kind: .normal, enabled: false) {}
        } else if let p = store.product(for: plan) {
            let label = hasSubscription
                ? UFOfferText.switchButton(to: plan)
                : UFOfferText.button(plan: plan, price: p.displayPrice, period: p.ufPeriod, freeTrial: p.ufFreeTrial,
                                     eligible: store.introEligible[p.id] == true)
            fullButton(label, kind: .primary, enabled: !store.busy) { Task { await buy(p, plan: plan) } }
        } else {
            fullButton("\(plan.name) wählen", kind: .primary, enabled: false) {}
        }
    }

    /// kleine Zeile unter dem Knopf: Gratiswoche, Kuendigung, vorgemerkter Wechsel, wann ein Wechsel gilt
    private func buttonNote(_ plan: UFPlan, current: Bool) -> String? {
        guard plan != .free, !ent.loading else { return nil }
        if current {
            if let next = ent.pendingPlan { return UFOfferText.pendingNote(next, at: ent.expiresAt) }
            if ent.willRenew == false { return UFOfferText.cancelledNote(plan, endsAt: ent.expiresAt) }
            if context == .settings && ent.inIntroOffer { return trialEndText }
            return nil
        }
        if ent.pendingPlan == plan { return UFOfferText.pendingNote(plan, at: ent.expiresAt) }
        if hasSubscription && store.product(for: plan) != nil { return UFOfferText.switchNote(to: plan, from: ent.plan) }
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

    private func buy(_ p: Product, plan: UFPlan) async {
        info = nil
        let before = ent.plan
        switch await store.purchase(p) {
        case .success:
            if ent.plan != plan, ent.pendingPlan == plan {
                // Downgrade: Apple stellt erst zur naechsten Verlaengerung um, die Seite bleibt offen und sagt es
                info = UFOfferText.pendingNote(plan, at: ent.expiresAt) + " Bis dahin bleibt \(before.name)."
            } else {
                onDone()
            }
        case .pending:
            info = "Der Kauf wartet auf Bestätigung (z. B. durch die Familienfreigabe). Sobald er bestätigt ist, wird der Tarif freigeschaltet."
        case .cancelled, .failed:
            break                                    // Seite bleibt; Fehler zeigt die Fehlerkarte
        }
    }

    private var trialEndText: String {
        guard let d = ent.expiresAt else { return "Gratiswoche läuft." }
        return "Gratiswoche bis \(UFOfferText.day(d)). Danach verlängert sich das Abo, wenn du nicht kündigst."
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
            Text(Self.legalText).ufFont(12.8).foregroundStyle(UF.muted)
        }
    }

    /// Pflichtangaben unter den Karten (Richtlinie 3.1.2)
    static let legalText = "Die Zahlung läuft über deine Apple-ID. Abos verlängern sich automatisch, wenn sie nicht spätestens 24 Stunden vor Ablauf gekündigt werden. Kündigen kannst du jederzeit unter „Abo verwalten“ oder in den Einstellungen deiner Apple-ID. Die Abo-Tarife gehören zu einem Abo: Ein Wechsel zu einem höheren Tarif gilt sofort, zu einem kleineren ab der nächsten Verlängerung. Deine Notizen bleiben in jedem Tarif erhalten."

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
