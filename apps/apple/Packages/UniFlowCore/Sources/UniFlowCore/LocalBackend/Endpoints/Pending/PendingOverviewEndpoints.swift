import Foundation

/// Platzhalter: Hintergrundaufgabe, Abgleich ueber den PC. Die Uebersicht (`/api/dashboard`) ist seit S6 echt
/// (StudyEndpoints), die Suche seit S7 (SearchEndpoints).
enum PendingOverviewEndpoints: LocalEndpointModule {
    static let name = "Hintergrund (Platzhalter)"

    static func register(on router: LocalRouter) {
        router.get("/api/bg", placeholder: true) { _, _ in .json(LocalPending.bg) }

        // Abgleich mit Stud.IP laeuft auf dem iPad direkt (StudIPSync), nicht ueber diesen Pfad
        router.post("/api/sync", placeholder: true) { _, _ in
            throw LocalHTTPError(status: 409, message: "Auf diesem iPad gleicht UniFlow Stud.IP direkt ab.")
        }
    }
}
