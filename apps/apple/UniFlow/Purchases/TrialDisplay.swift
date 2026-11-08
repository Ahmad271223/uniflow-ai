import Foundation
import UniFlowCore

// Welche Probe die App anzeigt (Entscheidung des Inhabers vom 09.11.2026, Audit Paket 44, Produktentscheidung 1):
// ueberall dieselbe, die auch freischaltet (`UFPlanPrecedence`). Gilt die Probe des StudiNow-Kontos, zeigen
// Seitenleiste (Kontokarte), Einstellungen, Probe-Karte (TrialBanner) und Tarifseite bzw. Entscheidungs-Bildschirm
// (PlanPickerView) deren Resttage und Ende; sonst die der Probe auf dem iPad (nur ohne Kauf, wie beim Freischalten).
// Nur Anzeige: Freischaltung und Credits bleiben, wie sie sind.

/// die angezeigte Probe: Quelle, Resttage, Ende
struct UFShownTrial: Equatable {
    enum Source: Equatable { case service, device }
    let source: Source
    let daysLeft: Int
    /// Ende der Probe; nil, wenn der Dienst es nicht meldet
    let endsAt: Date?

    /// GERUEST (altes Verhalten): nur die iPad-Probe, ohne Dienst-Probe und ohne Kauf
    static func make(service: UFPlan?, serviceDaysLeft: Int, serviceEndsAt: Date?, local: UFLocalTrial.State?,
                     purchased: UFPlan) -> UFShownTrial? {
        guard service == nil, purchased == .free, let local, local.isActive else { return nil }
        return UFShownTrial(source: .device, daysLeft: local.daysLeft, endsAt: local.endsAt)
    }
}

extension UFTrialBannerContent {
    /// GERUEST (altes Verhalten): wie bisher allein aus dem Stand des Kontos und der iPad-Probe
    static func make(shown: UFShownTrial?, service: StudoraAccount.PlanStatus?, local: UFLocalTrial.State?, purchased: UFPlan,
                     choiceMade: Bool) -> UFTrialBannerContent? {
        make(service: service, local: local, purchased: purchased, choiceMade: choiceMade)
    }
}
