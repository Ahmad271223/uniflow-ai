import Foundation

/// Pruefungsanmeldung (nur lokal, `ExamRegistrationAPI`, docs/PRUEFUNGSANMELDUNG-2026-11-05.md):
/// - `GET /api/exam-registration`: Meldezeitraum des Studiengangs, Vorschlaege aus dem Studienverlauf mit Termin und
///   Grund, abgehakte Anmeldungen (Notenspiegel "AN" und "Info über angemeldete Prüfungen"), Warnungen, QIS-Adresse.
///   Die App meldet nie selbst an; den Abruf der Info-Seite macht die App ueber die QIS-Verbindung.
public enum ExamRegistrationEndpoints: LocalEndpointModule {
    public static let name = "Prüfungsanmeldung"

    public static func register(on router: LocalRouter) {
        router.get("/api/exam-registration") { _, ctx in
            let today = ctx.clock.today
            return .json(try await ctx.database.withConnection { try ExamRegistrationAPI.response($0, today: today) })
        }
    }
}
