import StoreKit
import SwiftUI
import UniFlowCore

// Geraete-Regel (Auftrag des Inhabers vom 14.11.2026; `DeviceRule` im Kern, Dienst app/device_limit.py):
// - Free gilt fuer ein Geraet. Auf einem zweiten Geraet zeigt die App statt der Oberflaeche den Hinweis-Bildschirm
//   (`DeviceLimitScreen`) mit "Plus ansehen", "Dieses Gerät stattdessen nutzen" und "Abmelden".
// - Plus und Pro AI (seit 26.11.2026 beide mit Abgleich) und die laufende Probe: nichts. Den einmaligen Plus-Hinweis
//   (`DevicePlusHint`) zeigt die App nur noch, wenn ein Dienst von vor dem 26.11.2026 ihn fuer ein Free-Geraet meldet.
// Gesperrt wird nur nach einer ausdruecklichen Antwort des StudiNow-Dienstes (`StudoraAccountLink.deviceStatus`), nie
// ohne Netz. Der letzte Stand ist gemerkt, damit der Hinweis beim naechsten Start sofort da ist. Lokale Uni-Daten
// bleiben unberuehrt. Preise aus StoreKit (`Product.displayPrice`), sonst der Listenpreis des Dienstes.

/// Was die Wurzel der App zeigt
enum DeviceRuleScreen: Equatable {
    /// die App wie immer
    case app
    /// gemerkter Hinweis, aber der Kauf auf diesem Geraet ist noch nicht gelesen: kurz warten statt jemandem mit
    /// Pro AI den Hinweis zu zeigen
    case waiting
    /// Hinweis-Bildschirm statt der App
    case blocked

    /// `signedIn`: bei Apple angemeldet (sonst zeigt die App die Begruessung); `canSwitch`: Anschluss zum Dienst da
    /// (ohne ihn gaebe es keinen Ausweg, dann nie sperren)
    static func decide(server: DeviceRule.State?, plan: UFPlan, entitlementsLoading: Bool, signedIn: Bool, canSwitch: Bool) -> DeviceRuleScreen {
        guard signedIn, canSwitch, server == .blocked else { return .app }
        if entitlementsLoading { return .waiting }
        return DeviceRule.shown(server: server, localPlan: plan.rawValue) == .blocked ? .blocked : .app
    }

    /// Ist der einmalige Plus-Hinweis jetzt faellig? Erst wenn die Oberflaeche steht (`ready`), nie zweimal (`seen`)
    static func plusHintDue(server: DeviceRule.State?, plan: UFPlan, entitlementsLoading: Bool, signedIn: Bool, canSwitch: Bool,
                            ready: Bool, seen: Bool) -> Bool {
        guard signedIn, canSwitch, ready, !seen, !entitlementsLoading else { return false }
        return DeviceRule.shown(server: server, localPlan: plan.rawValue) == .hintPlus
    }
}

/// Preis von Plus im Monat fuer die Hinweise (seit 26.11.2026 der kleinste Tarif mit Abgleich): aus StoreKit, sonst der
/// Listenpreis des Dienstes (nur wenn er einen Monatspreis meldet; ein aelterer Dienst nennt Pro AI im Jahr) bzw. 1,99 €
enum DeviceRulePrice {
    static func text(store: String?, status: DeviceRule.Status?) -> String {
        if let store, !store.isEmpty { return store }
        guard status?.period == "month" else { return DeviceRuleTexts.fallbackPrice() }
        return DeviceRuleTexts.fallbackPrice(cents: status?.priceCents, currency: status?.currency)
    }
}

/// Wurzel: Hinweis-Bildschirm statt der App (Free auf einem zweiten Geraet), sonst die App mit dem einmaligen
/// Plus-Hinweis. `signedIn`: bei Apple angemeldet; `ready`: die Oberflaeche steht (erster Start vorbei).
struct DeviceRuleGate<Content: View>: View {
    @ObservedObject var link: StudoraAccountLink
    @ObservedObject var entitlements: Entitlements
    let signedIn: Bool
    let ready: Bool
    @ViewBuilder let content: () -> Content

    private var screen: DeviceRuleScreen {
        DeviceRuleScreen.decide(server: link.deviceStatus?.state, plan: entitlements.plan, entitlementsLoading: entitlements.loading,
                                signedIn: signedIn, canSwitch: link.canSignIn)
    }

    private var plusHintDue: Bool {
        DeviceRuleScreen.plusHintDue(server: link.deviceStatus?.state, plan: entitlements.plan, entitlementsLoading: entitlements.loading,
                                     signedIn: signedIn, canSwitch: link.canSignIn, ready: ready, seen: link.plusHintSeen)
    }

    var body: some View {
        switch screen {
        case .app:
            content().modifier(DevicePlusHintHost(link: link, entitlements: entitlements, due: plusHintDue))
        case .waiting:
            DeviceRuleWaiting()
        case .blocked:
            DeviceLimitScreen(link: link, entitlements: entitlements)
        }
    }
}

/// kurzer Moment beim Start, bis der Kauf auf diesem Geraet gelesen ist
struct DeviceRuleWaiting: View {
    var body: some View {
        ZStack {
            UF.bg.ignoresSafeArea()
            ProgressView().accessibilityLabel("StudiNow startet")
        }
    }
}

// MARK: - Hinweis-Bildschirm (Free auf einem zweiten Geraet)

/// Hinweis-Bildschirm mit seinen drei Wegen: Pro AI (vorhandene Tarifseite, Kauf im App Store), dieses Geraet
/// stattdessen nutzen (nach Rueckfrage), abmelden. Nach einem Kauf von Pro AI verschwindet er sofort (`DeviceRuleGate`).
struct DeviceLimitScreen: View {
    @ObservedObject var link: StudoraAccountLink
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var overlay: UFOverlay
    @StateObject private var store: PurchaseStore
    @State private var showPlans = false
    @State private var busy = false
    @State private var problem: String?

    @MainActor
    init(link: StudoraAccountLink, entitlements: Entitlements) {
        _link = ObservedObject(wrappedValue: link)
        _store = StateObject(wrappedValue: PurchaseStore(entitlements: entitlements))
    }

    var body: some View {
        DeviceLimitLayout(primaryName: link.deviceStatus?.primaryName,
                          price: DeviceRulePrice.text(store: store.product(for: .plus)?.displayPrice, status: link.deviceStatus),
                          busy: busy, problem: problem,
                          onPlans: { showPlans = true }, onUseThis: useThis, onSignOut: signOut)
            .ufCompactLayout()
            .ufSheet(isPresented: $showPlans) { UFPlanSheet(required: .plus, close: { showPlans = false }) }
            // Preis aus dem Store; nie unter XCTest (Tests geben den Preis vor)
            .task { if !StudIPSync.isUnderTest() { await store.loadProducts() } }
    }

    /// Rueckfrage, dann wird dieses Geraet das eine Geraet des Kontos; ohne Netz bleibt alles, wie es war
    private func useThis() {
        guard !busy else { return }
        let name = link.deviceStatus?.primaryName
        Task {
            guard await overlay.confirm(DeviceRuleTexts.confirmTitle + "\n\n" + DeviceRuleTexts.confirmText(primaryName: name)) else { return }
            busy = true
            problem = nil
            let ok = await link.useThisDevice()
            busy = false
            if !ok { problem = DeviceRuleTexts.switchFailed }
        }
    }

    /// Abmelden: Sitzung beim Dienst beenden, dann zurueck zur Begruessung. Die Daten auf dem Geraet bleiben.
    private func signOut() {
        guard !busy else { return }
        busy = true
        Task {
            await link.logout()
            account.signOut()
            busy = false
        }
    }
}

/// Aussehen des Hinweis-Bildschirms (ohne Zustand; iPad, iPhone und Mac, hell und dunkel ueber die Farben von `UF`)
struct DeviceLimitLayout: View {
    let primaryName: String?
    /// "39,99 €"
    let price: String
    var busy = false
    var problem: String?
    let onPlans: () -> Void
    let onUseThis: () -> Void
    let onSignOut: () -> Void
    @Environment(\.ufCompact) private var compact

    private var spoken: String { DeviceRuleTexts.blockedText(primaryName: primaryName, price: price, mac: UFDevice.isMac) }

    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: 0) {
                IntroBuddy(size: 52).accessibilityHidden(true)
                Text(DeviceRuleTexts.blockedTitle).ufFont(28.8, 700, lh: 1.2, em: -0.02).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 19.2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("device.blocked.title")
                VStack(alignment: .leading, spacing: 9.6) {
                    Text(DeviceRuleTexts.blockedWhere(primaryName: primaryName)).ufFont(16).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(DeviceRuleTexts.blockedOffer(price: price, mac: UFDevice.isMac)).ufFont(16, 600).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 9.6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityIdentifier("device.blocked.text")
                if let problem {
                    Text(problem).ufFont(13.12).foregroundStyle(UF.badText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12.8)
                        .accessibilityIdentifier("device.blocked.problem")
                }
                VStack(spacing: 9.6) {
                    UFWideButton(DeviceRuleTexts.showPlans, icon: "sparkles", kind: .primary, action: onPlans)
                        .accessibilityIdentifier("device.blocked.plans")
                    UFWideButton(DeviceRuleTexts.useThisDevice, action: onUseThis)
                        .disabled(busy)
                        .accessibilityIdentifier("device.blocked.useThis")
                    UFWideButton(DeviceRuleTexts.signOut, icon: "log-out", kind: .ghost, action: onSignOut)
                        .disabled(busy)
                        .accessibilityIdentifier("device.blocked.signOut")
                }
                .frame(maxWidth: compact ? .infinity : 380)
                .padding(.top, 22.4)
                Text(DeviceRuleTexts.dataStays).ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            }
        }
    }
}

// MARK: - Einmaliger Hinweis (Plus auf einem zweiten Geraet)

/// Oeffnet den Plus-Hinweis einmal als Blatt, sobald er faellig ist; nach dem Schliessen gilt er als gezeigt. "Plus
/// ansehen" oeffnet danach die vorhandene Tarifseite.
struct DevicePlusHintHost: ViewModifier {
    @ObservedObject var link: StudoraAccountLink
    let entitlements: Entitlements
    let due: Bool
    @State private var shown = false
    @State private var plansNext = false
    @State private var showPlans = false

    func body(content: Content) -> some View {
        content
            .onChange(of: due, initial: true) { _, due in if due { shown = true } }
            .ufSheet(isPresented: $shown, onDismiss: dismissed) {
                DevicePlusHintSheet(status: link.deviceStatus, entitlements: entitlements,
                                    onPlans: { plansNext = true; shown = false }, onClose: { shown = false })
            }
            .ufSheet(isPresented: $showPlans) { UFPlanSheet(required: .plus, close: { showPlans = false }) }
    }

    private func dismissed() {
        link.markPlusHintSeen()
        if plansNext { plansNext = false; showPlans = true }
    }
}

/// Blatt des Plus-Hinweises mit dem Preis aus dem Store
struct DevicePlusHintSheet: View {
    let status: DeviceRule.Status?
    let onPlans: () -> Void
    let onClose: () -> Void
    @StateObject private var store: PurchaseStore

    @MainActor
    init(status: DeviceRule.Status?, entitlements: Entitlements, onPlans: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.status = status
        self.onPlans = onPlans
        self.onClose = onClose
        _store = StateObject(wrappedValue: PurchaseStore(entitlements: entitlements))
    }

    var body: some View {
        DevicePlusHint(price: DeviceRulePrice.text(store: store.product(for: .plus)?.displayPrice, status: status),
                       onPlans: onPlans, onClose: onClose)
            .ufSheetPresentation()
            .task { if !StudIPSync.isUnderTest() { await store.loadProducts() } }
    }
}

/// Aussehen des Plus-Hinweises (ohne Zustand)
struct DevicePlusHint: View {
    /// "39,99 €"
    let price: String
    let onPlans: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(DeviceRuleTexts.plusTitle).ufFont(20.8, 700, lh: 1.25, em: -0.01).foregroundStyle(UF.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("device.plus.title")
            Text(DeviceRuleTexts.plusText(price: price, mac: UFDevice.isMac)).ufFont(15.2).foregroundStyle(UF.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .accessibilityIdentifier("device.plus.text")
            VStack(spacing: 9.6) {
                UFWideButton(DeviceRuleTexts.showPlans, icon: "sparkles", kind: .primary, action: onPlans)
                    .accessibilityIdentifier("device.plus.plans")
                UFWideButton(DeviceRuleTexts.plusClose, action: onClose)
                    .accessibilityIdentifier("device.plus.close")
            }
            .padding(.top, 20.8)
        }
        .padding(.horizontal, 22.4)
        .padding(.top, 28.8)
        .padding(.bottom, 22.4)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
