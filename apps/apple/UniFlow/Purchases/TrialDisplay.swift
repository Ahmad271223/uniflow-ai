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

    /// Reihenfolge wie `UFPlanPrecedence.effective`: laufende Probe des Kontos (Resttage und Ende laut Dienst) > Kauf
    /// (keine Probe zu zeigen, ausser der des Kontos) > laufende iPad-Probe > keine. Gilt die Probe des Kontos, zeigt
    /// die App nie die Tage der iPad-Probe, auch wenn der Dienst keine Resttage meldet.
    static func make(service: UFPlan?, serviceDaysLeft: Int, serviceEndsAt: Date?, local: UFLocalTrial.State?,
                     purchased: UFPlan) -> UFShownTrial? {
        if let service, service != .free {
            return serviceDaysLeft > 0 ? UFShownTrial(source: .service, daysLeft: serviceDaysLeft, endsAt: serviceEndsAt) : nil
        }
        guard purchased == .free, let local, local.isActive else { return nil }
        return UFShownTrial(source: .device, daysLeft: local.daysLeft, endsAt: local.endsAt)
    }
}

extension UFTrialBannerContent {
    /// Probe-Karte: laeuft die angezeigte Probe (`shown`), deren Resttage; sonst nur noch der Hinweis nach der Probe
    /// (Konto bzw. iPad, wie bisher `make(service:local:purchased:choiceMade:)`), nie eine andere laufende Probe
    static func make(shown: UFShownTrial?, service: StudoraAccount.PlanStatus?, local: UFLocalTrial.State?, purchased: UFPlan,
                     choiceMade: Bool) -> UFTrialBannerContent? {
        if let shown { return .running(daysLeft: shown.daysLeft, source: shown.source == .service ? .service : .device) }
        let c = make(service: service, local: local, purchased: purchased, choiceMade: choiceMade)
        return c?.isRunning == true ? nil : c
    }
}
