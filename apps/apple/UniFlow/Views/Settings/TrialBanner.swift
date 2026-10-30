import SwiftUI
import UniFlowCore

/// Texte wie im Web (`app/static/views-abo.js`); der App-Store-Hinweis ersetzt den Stripe-Abschluss
enum UFTrialTexts {
    static func running(_ days: Int) -> String { "Probe: noch \(days) \(days == 1 ? "Tag" : "Tage") alles frei" }
    static let runningText = "Danach wählst du einen Tarif oder bleibst bei Free. Deine Notizen bleiben in jedem Fall erhalten."
    static let overTitle = "Deine Probe ist vorbei"
    static let overText = "Sieben Tage lang war alles frei. Wähle jetzt einen Tarif oder bleib bei Free. Deine Notizen bleiben in jedem Fall erhalten und lesbar."
    static let plans = "Tarife ansehen"
    static let stayFree = "Bei Free bleiben"
}

/// Probe des Studora-Kontos auf der Uebersicht: laufend mit Resttagen, danach die Aufforderung zur Tarifwahl. Ohne
/// Dienst-Adresse oder Konto nichts. Bezahlt wird auf dem iPad nur im App Store.
struct TrialBanner: View {
    @ObservedObject var link: StudoraAccountLink
    @Environment(\.ufSwitchPlan) private var switchPlan

    var body: some View {
        if let s = link.planStatus, s.trialActive || s.needsPlanChoice {
            UFCard(flat: true) {
                HStack(alignment: .center, spacing: 11.2) {
                    UFIcon(s.trialActive ? "sparkles" : "alert", size: 20).foregroundStyle(s.trialActive ? UF.accent : UF.warn)
                    VStack(alignment: .leading, spacing: 2.4) {
                        Text(s.trialActive ? UFTrialTexts.running(s.trialDaysLeft) : UFTrialTexts.overTitle)
                            .ufFont(14.5, 650).foregroundStyle(UF.text)
                        Text(s.trialActive ? UFTrialTexts.runningText : UFTrialTexts.overText)
                            .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    UFButton(UFTrialTexts.plans, size: .small) { switchPlan?() }
                        .accessibilityIdentifier("trial.plans")
                    if !s.trialActive {
                        UFButton(UFTrialTexts.stayFree, size: .small) { Task { await link.stayOnFree() } }
                            .disabled(link.busy)
                            .accessibilityIdentifier("trial.free")
                    }
                }
            }
            .accessibilityIdentifier("trial.banner")
        }
    }
}
