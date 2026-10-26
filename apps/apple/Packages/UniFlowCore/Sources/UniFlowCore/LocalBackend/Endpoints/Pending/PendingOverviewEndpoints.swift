import Foundation

/// Platzhalter: Hintergrundaufgabe, Abgleich ueber den PC, Suche (S7). Die Uebersicht (`/api/dashboard`) ist seit S6
/// echt (StudyEndpoints).
enum PendingOverviewEndpoints: LocalEndpointModule {
    static let name = "Hintergrund, Suche (Platzhalter)"

    static func register(on router: LocalRouter) {
        router.get("/api/bg", placeholder: true) { _, _ in .json(LocalPending.bg) }

        // Abgleich mit Stud.IP laeuft auf dem iPad direkt (StudIPSync), nicht ueber diesen Pfad
        router.post("/api/sync", placeholder: true) { _, _ in
            throw LocalHTTPError(status: 409, message: "Auf diesem iPad gleicht UniFlow Stud.IP direkt ab.")
        }

        router.get("/api/search", placeholder: true) { req, _ in
            _ = try req.requiredQuery("q")
            return .json(["files": [], "modules": []])
        }
    }
}
