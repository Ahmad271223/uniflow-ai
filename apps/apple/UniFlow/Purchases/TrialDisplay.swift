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
    /// Seit 13.11.2026 (Inhaber: "Ja, ausblenden"): deckt ein Kauf die Probe ab (gekauft auf diesem iPad oder laut
    /// Dienst `servicePaid`, mindestens der Tarif der Probe, also Pro AI), zeigt die App keine Probe mehr - die Karte
    /// "Probe: noch 2 Tage … 25 Credits" war fuer Pro-AI-Kunden mit 100 Credits irrefuehrend. Probe + Plus zeigt die
    /// Probe weiter (sie bringt bis zum Ende noch die KI). Nur Anzeige, Freischaltung und Credits bleiben.
    static func make(service: UFPlan?, serviceDaysLeft: Int, serviceEndsAt: Date?, local: UFLocalTrial.State?,
                     purchased: UFPlan, servicePaid: UFPlan? = nil) -> UFShownTrial? {
        let paid = max(purchased, servicePaid ?? .free)
        if paid != .free, paid >= (service ?? .proAI) { return nil }
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
