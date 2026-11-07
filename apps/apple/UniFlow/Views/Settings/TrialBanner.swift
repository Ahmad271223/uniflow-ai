import SwiftUI
import UniFlowCore

/// Texte wie im Web (`app/static/views-abo.js`); der App-Store-Hinweis ersetzt den Stripe-Abschluss. Dieselben Texte
/// fuer die Probe des StudiNow-Kontos und die Probe auf dem iPad ohne Dienst (LocalTrial.swift).
enum UFTrialTexts {
    /// Credits der Probe fuer die StudiNow-KI (plans.json `trial.credits`, app/credits.py); nur mit StudiNow-Dienst,
    /// ohne ihn laeuft die KI auf dem iPad ueber das eigene ChatGPT und Pro AI wird nicht genannt (UFPlanCatalog)
    static let credits = 25
    static func running(_ days: Int) -> String { "Probe: noch \(days) \(days == 1 ? "Tag" : "Tage") alles frei" }
    static let runningText = "Danach wählst du einen Tarif oder bleibst bei Free. Deine Notizen bleiben in jedem Fall erhalten."
    /// Probe des StudiNow-Kontos (Dienst): alles wie Pro AI mit 25 Credits (Entscheidung 04.11.2026)
    static let runningTextService = "Alles wie StudiNow Pro AI, mit \(credits) Credits für die StudiNow-KI. " + runningText
    static let overTitle = "Deine Probe ist vorbei"
    static let overText = "Sieben Tage lang war alles frei. Wähle jetzt einen Tarif oder bleib bei Free. Deine Notizen bleiben in jedem Fall erhalten und lesbar."
    /// weitere Apple-ID auf einem iPad, auf dem schon eine Probe lief (LocalTrial.swift, Geraete-Marke)
    static let usedOnDeviceTitle = "Auf diesem iPad wurde die Probe schon genutzt"
    static let usedOnDeviceText = "Die 7 Tage Probe gibt es einmal je iPad. Wähle einen Tarif oder bleib bei Free. Deine Notizen bleiben in jedem Fall erhalten."
    static let plans = "Tarife ansehen"
    static let stayFree = "Bei Free bleiben"
    /// Angebotssatz auf der Tarifseite (ersetzt "1 Woche gratis, danach …" des Einfuehrungsangebots, 04.11.2026)
    static let offer = "7 Tage Probe mit allem, danach Free – ohne Zahlungsdaten"
    /// dasselbe, sobald der Store Pro AI anbietet (StudiNow-Dienst): "Probe: alles wie Pro AI, 25 Credits"
    static let offerProAI = "7 Tage Probe: alles wie StudiNow Pro AI, mit \(credits) Credits für die StudiNow-KI, danach Free – ohne Zahlungsdaten"
}

/// Probe auf der Uebersicht: laufend mit Resttagen, danach die Aufforderung zur Tarifwahl (Free bleibt nutzbar).
/// Mit StudiNow-Konto zaehlt dessen Probe (Dienst hat Vorrang), sonst die Probe auf dem iPad aus `Entitlements`
/// (`UFTrialBannerContent`). Bezahlt wird auf dem iPad nur im App Store.
struct TrialBanner: View {
    var link: StudoraAccountLink?
    private let ent: Entitlements

    /// `entitlements: nil` = `Entitlements.shared`
    @MainActor
    init(link: StudoraAccountLink? = nil, entitlements: Entitlements? = nil) {
        self.link = link
        ent = entitlements ?? .shared
    }

    var body: some View {
        if let link {
            ServiceTrialBanner(link: link, ent: ent)
        } else {
            LocalTrialBanner(ent: ent)
        }
    }
}

/// mit Konto-Anschluss: dessen Stand beobachten, die iPad-Probe als Rueckfall
private struct ServiceTrialBanner: View {
    @ObservedObject var link: StudoraAccountLink
    @ObservedObject var ent: Entitlements

    var body: some View {
        TrialBannerCard(content: UFTrialBannerContent.make(service: link.planStatus, local: ent.localTrial,
                                                           purchased: ent.purchasedPlan, choiceMade: ent.localTrialChoiceMade),
                        busy: link.busy) { source in
            if source == .service { Task { await link.stayOnFree() } } else { ent.stayOnFreeAfterLocalTrial() }
        }
    }
}

/// ohne Konto-Anschluss: nur die Probe auf dem iPad
private struct LocalTrialBanner: View {
    @ObservedObject var ent: Entitlements

    var body: some View {
        TrialBannerCard(content: UFTrialBannerContent.make(service: nil, local: ent.localTrial, purchased: ent.purchasedPlan,
                                                           choiceMade: ent.localTrialChoiceMade),
                        busy: false) { _ in ent.stayOnFreeAfterLocalTrial() }
    }
}

/// die Karte selbst; ohne Inhalt nichts
private struct TrialBannerCard: View {
    let content: UFTrialBannerContent?
    let busy: Bool
    let stayFree: (UFTrialBannerContent.Source) -> Void
    @Environment(\.ufSwitchPlan) private var switchPlan

    var body: some View {
        if let c = content {
            UFCard(flat: true) {
                HStack(alignment: .center, spacing: 11.2) {
                    UFIcon(c.isRunning ? "sparkles" : "alert", size: 20).foregroundStyle(c.isRunning ? UF.accent : UF.warn)
                    VStack(alignment: .leading, spacing: 2.4) {
                        Text(c.title).ufFont(14.5, 650).foregroundStyle(UF.text)
                        Text(c.text).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    UFButton(UFTrialTexts.plans, size: .small) { switchPlan?() }
                        .accessibilityIdentifier("trial.plans")
                    if case .over(let source) = c {
                        UFButton(UFTrialTexts.stayFree, size: .small) { stayFree(source) }
                            .disabled(busy)
                            .accessibilityIdentifier("trial.free")
                    } else if c == .usedOnDevice {
                        UFButton(UFTrialTexts.stayFree, size: .small) { stayFree(.device) }
                            .accessibilityIdentifier("trial.free")
                    }
                }
            }
            .accessibilityIdentifier("trial.banner")
        }
    }
}
