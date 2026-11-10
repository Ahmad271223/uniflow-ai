import StoreKit
import SwiftUI

// Tarifwahl (docs/AUFTRAG-APPSTORE-V1.md, Abschnitt 2a Schritt 2, Abschnitt 4 und 5; docs/ABO-SYSTEM.md): Karten fuer
// die Tarife aus `UFPlanCatalog` – StudiNow Free, Plus und Pro AI (Entscheidung des Inhabers vom 04.11.2026); die
// Pro-AI-Karte nur, wenn StoreKit das Produkt liefert, sonst ein nicht anklickbarer Hinweis ohne Preis. Inhalt der
// Karten aus `UFPlanCard`: nur, was auf dem iPad wirklich geht (auf dem Geraet oder mit StudiNow-Konto), nichts
// "in Vorbereitung"; die Pro-AI-Karte nennt das StudiNow-Konto und die Credits. Preise nur aus Product.displayPrice.
// Kein Einfuehrungsangebot: die 7 Tage Probe laufen ohne Kauf auf dem iPad (LocalTrial.swift, alles wie Pro AI). Waehrend
// sie laeuft, steht oben "Probe aktiv: alle Funktionen von StudiNow Pro AI bis … (noch n Tage)", keine Karte traegt
// "Aktueller Tarif" (auch Free nicht, 07.11.2026), die Pro-AI-Karte traegt "Probe". Sonst richtet sich "Aktueller Tarif"
// nach dem Kauf (`purchasedPlan`). Wechsel zwischen Abo-Tarifen regelt Apple in der Gruppe.
// Dieselbe Ansicht dient beim ersten Start, in den Einstellungen ("Tarif wechseln", "Abo verwalten") und hinter
// gesperrten Funktionen (UFPlanSheet).
// Zahlweise (Entscheidung des Inhabers vom 09.11.2026, ersetzt "monatlich oder jaehrlich" vom 07.11.2026): nur noch das
// Jahresabo, kein Umschalter; die Karte zeigt den Jahrespreis und den Monatsbetrag daraus ("entspricht 1,67 € im Monat"),
// beides aus Product.price. Laeuft noch ein frueheres Monatsabo (nur Sandbox/Test), bietet die Karte des Tarifs den
// Wechsel zum Jahresabo an (Apple: ab der naechsten Verlaengerung).

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
        UFContent(maxWidth: 860) {
            UFPageHead(Self.title(context), sub: subtitle)
            if context == .trialOver { infoCard(UFTrialTexts.overText).padding(.bottom, 16) }
            if let t = ent.runningTrial { trialCard(t).padding(.bottom, 16) }
            if !ent.loading, ent.purchasedPlan == .free, ent.localTrial?.deviceUsed == true {
                infoCard(UFTrialTexts.usedOnDeviceTitle + ".").padding(.bottom, 16)
            }
            if let e = store.lastError { errorCard(e).padding(.bottom, 16) }
            if let info { infoCard(info).padding(.bottom, 16) }
            UFGridLayout(spacing: 16, minWidth: 280) {
                ForEach(UFPlanCatalog.cards(current: ent.purchasedPlan, loaded: store.loadedProductIDs)) { planCard($0) }
            }
            .environment(\.ufFillsCell, true)
            if Self.showsProAIMissingNote(loaded: store.loadedProductIDs, loading: store.loadingProducts, current: ent.purchasedPlan) {
                // nur ein Hinweis: kein Preis, kein Knopf, nichts zum Antippen
                Text(UFPlanCatalog.proAIMissingNote).ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 12.8)
                    .accessibilityAddTraits(.isStaticText)
            }
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

    /// Hinweis "Pro AI folgt mit dem Dienst": wenn die Produkte geladen sind, Pro AI fehlt und niemand es schon hat
    static func showsProAIMissingNote(loaded: Set<String>, loading: Bool, current: UFPlan) -> Bool {
        guard !loading, !loaded.isEmpty, current != .proAI else { return false }
        return !loaded.contains(UFPlan.proAI.productID ?? "")
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

    private var proAIOffered: Bool { UFPlan.proAI.productID.map(store.loadedProductIDs.contains) == true }

    /// laeuft noch ein frueheres Monatsabo (nur Sandbox/Test)? Dann bietet die Karte des Tarifs das Jahresabo an
    private var onOldBilling: Bool { !ent.loading && ent.purchasedBilling.map { $0 != UFBilling.offered } == true }

    private var subtitle: String { Self.subtitle(proAI: proAIOffered) }

    /// Untertitel: die angebotenen Tarife (Pro AI nur mit Produkt aus dem Store); die laufende Probe steht in eigener
    /// Zeile darunter (`trialStatus`)
    static func subtitle(proAI: Bool) -> String {
        var s = "Mit \(UFPlan.free.name) planst du dein Lernen, öffnest deine Dokumente und siehst deine Fächer geordnet – dauerhaft kostenlos. "
        s += "\(UFPlan.plus.name) fügt das Schreiben mit Apple Pencil hinzu"
        s += proAI ? ", \(UFPlan.proAI.name) die KI von StudiNow über den StudiNow-Dienst. " : ". "
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
        let title = proAI ? "Probe aktiv: alle Funktionen von \(UFPlan.proAI.name)\(until) (\(left))"
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

    // MARK: Karten

    private func planCard(_ plan: UFPlan) -> some View {
        // "Aktueller Tarif" ist der gekaufte (bzw. Free ohne Kauf); waehrend der Probe ohne Kauf keiner, die Karte des
        // Probe-Tarifs (Pro AI) traegt "Probe"
        let trial = ent.runningTrial != nil
        let current = Self.isCurrent(plan, purchased: ent.purchasedPlan, loading: ent.loading, trial: trial)
        let showCurrent = current && context != .onboarding && context != .trialOver
        let included = UFPlanCard.included(plan)
        return PlanCardFrame(highlight: showCurrent) {
            HStack(spacing: 8) {
                Text(plan.name).ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text)
                Spacer(minLength: 0)
                if showCurrent {
                    UFBadge("Aktueller Tarif", tone: .ok, icon: "check")
                } else if trial && plan == UFLocalTrial.plan {
                    UFBadge("Probe", tone: .info, icon: "clock")
                } else if !ent.loading && ent.pendingPlan == plan {
                    UFBadge("Vorgemerkt", tone: .info, icon: "clock")
                }
            }
            if let t = UFPlanCard.tagline(plan) {
                Text(t).ufFont(13.12).foregroundStyle(UF.text2).padding(.top, 3.2)
            }
            if let s = UFPlanCatalog.serviceNote(plan) {
                // Pro AI: StudiNow-Konto und Credits
                Text(s).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true).padding(.top, 3.2)
            }
            priceBlock(plan).padding(.top, 6.4)
            Rectangle().fill(UF.line).frame(height: 1).padding(.vertical, 14.4)
            Text(UFPlanCard.intro(plan)).ufFont(13.12, 600).foregroundStyle(UF.text2).padding(.bottom, 6.4)
            if !included.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(included, id: \.title) { featureRow($0) }
                }
            }
            Spacer(minLength: 16)
            actionButton(plan, current: current, trial: trial)
            if let n = buttonNote(plan, current: current) {
                Text(n).ufFont(11.84).foregroundStyle(UF.muted).padding(.top, 6.4)
            }
        }
    }

    private func featureRow(_ r: UFPlanCardRow) -> some View {
        HStack(alignment: .top, spacing: 8.8) {
            UFIcon("check", size: 16).foregroundStyle(UF.ok).padding(.top, 2)
            VStack(alignment: .leading, spacing: 1.6) {
                Text(r.title).ufFont(14.5, 500).foregroundStyle(UF.text)
                if let d = r.detail { Text(d).ufFont(12.8).foregroundStyle(UF.muted) }
            }
            // immer umbrechen statt kuerzen: die Karte ist so hoch wie die hoechste der Zeile (ufFillsCell), lange
            // Zeilen wie die KI-Hilfe mit ihrem Zusatz wurden sonst mit "…" abgeschnitten
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(r))
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
    private func priceBlock(_ plan: UFPlan) -> some View {
        if plan == .free {
            VStack(alignment: .leading, spacing: 2) {
                Text("0 €").ufFont(26, 700, lh: 1.2, em: -0.02).foregroundStyle(UF.text)
                Text("dauerhaft kostenlos, ohne Abo").ufFont(13.12).foregroundStyle(UF.muted)
            }
        } else if let p = store.product(for: plan) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3.2) {
                    Text(p.displayPrice).ufFont(26, 700, lh: 1.2, em: -0.02).foregroundStyle(UF.text)
                    Text(UFOfferText.per(value: p.ufPeriod.0, unit: p.ufPeriod.1)).ufFont(14.5).foregroundStyle(UF.muted)
                }
                if p.ufPeriod == (1, .year) {
                    // Monatsbetrag aus dem Jahrespreis des Stores (kein Vergleich mit einem Monatsabo)
                    Text(UFOfferText.yearlyNote(perMonth: p.priceFormatStyle.format(p.price / 12)))
                        .ufFont(13.12, 600).foregroundStyle(UF.text2)
                }
                Text(UFOfferText.summary(price: p.displayPrice, period: p.ufPeriod)).ufFont(13.12).foregroundStyle(UF.muted)
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

    /// laeuft gerade ein gekauftes Abo (nicht Free)? Dann sind die anderen Abo-Tarife ein Wechsel in der Gruppe.
    private var hasSubscription: Bool { !ent.loading && ent.purchasedPlan != .free }

    @ViewBuilder
    private func actionButton(_ plan: UFPlan, current: Bool, trial: Bool) -> some View {
        if plan == .free {
            if context == .settings && trial {
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
        } else if current, onOldBilling, let p = store.product(for: plan) {
            // laufender Tarif mit frueherem Monatsabo (nur Sandbox/Test): Wechsel zum Jahresabo (Apple: ab der naechsten
            // Verlaengerung)
            fullButton(UFOfferText.billingSwitchButton, kind: .primary, enabled: !store.busy) {
                Task { await buy(p, plan: plan) }
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
                : UFOfferText.button(plan: plan, price: p.displayPrice, period: p.ufPeriod)
            fullButton(label, kind: .primary, enabled: !store.busy) { Task { await buy(p, plan: plan) } }
        } else {
            fullButton("\(plan.name) wählen", kind: .primary, enabled: false) {}
        }
    }

    /// kleine Zeile unter dem Knopf: Kuendigung, vorgemerkter Wechsel, wann ein Wechsel gilt
    private func buttonNote(_ plan: UFPlan, current: Bool) -> String? {
        guard plan != .free, !ent.loading else { return nil }
        if current {
            if onOldBilling, store.product(for: plan) != nil { return UFOfferText.billingSwitchNote }
            if let next = ent.pendingPlan { return UFOfferText.pendingNote(next, at: ent.expiresAt) }
            if ent.willRenew == false { return UFOfferText.cancelledNote(plan, endsAt: ent.expiresAt) }
            return nil
        }
        if ent.pendingPlan == plan { return UFOfferText.pendingNote(plan, at: ent.expiresAt) }
        if hasSubscription && store.product(for: plan) != nil { return UFOfferText.switchNote(to: plan, from: ent.purchasedPlan) }
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
        let before = ent.purchasedPlan
        let beforeBilling = ent.purchasedBilling
        switch await store.purchase(p) {
        case .success:
            if before == plan, let b = beforeBilling, UFBilling(productID: p.id) != b {
                // nur die Zahlweise gewechselt: Apple stellt zur naechsten Verlaengerung um
                info = UFOfferText.billingSwitchNote
            } else if ent.purchasedPlan != plan, ent.pendingPlan == plan {
                // Downgrade: Apple stellt erst zur naechsten Verlaengerung um, die Seite bleibt offen und sagt es
                info = UFOfferText.pendingNote(plan, at: ent.expiresAt) + " Bis dahin bleibt \(before.name)."
            } else if ProAISignInHint.asksAfterPurchase(plan: plan, serviceAvailable: studoraAccount != nil && StudoraAccountLink.available,
                                                        signedIn: studoraAccount?.user != nil) {
                signInAfterPurchase = true               // Karte "Pro AI ist aktiv" mit "Mit Apple anmelden"
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
        var s = "Die Zahlung läuft über deine Apple-ID. Die Abos sind Jahresabos und verlängern sich automatisch um ein Jahr, wenn sie nicht spätestens 24 Stunden vor Ablauf gekündigt werden. Kündigen kannst du jederzeit unter „Abo verwalten“ oder in den Einstellungen deiner Apple-ID; der Zugang bleibt bis zum Ende des bezahlten Jahres. "
        // Wechsel zwischen Abo-Tarifen gibt es erst, wenn mehr als ein Abo angeboten wird (ab V2)
        if UFPlanCatalog.sellable.filter({ $0.productID != nil }).count > 1 {
            s += "Die Abo-Tarife gehören zu einem Abo: Ein Wechsel zu einem höheren Tarif gilt sofort, zu einem kleineren ab der nächsten Verlängerung. "
        }
        return s + "Deine Notizen bleiben in jedem Tarif erhalten."
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
