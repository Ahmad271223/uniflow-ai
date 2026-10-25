import Foundation

/// Platzhalter: Uni & Noten (QIS auf dem Geraet folgt, F4) und Karteikarten (Plus, eigenes Anlegen ohne KI).
enum PendingServicesEndpoints: LocalEndpointModule {
    static let name = "Uni & Noten, Karteikarten (Platzhalter)"

    /// `config.service_status` ohne gespeicherten Zugang
    private static let noCredential: JSONValue = ["own": false, "same_as": .null, "user": .null, "configured": false]

    static func register(on router: LocalRouter) {
        // Form von /api/services; auf dem iPad gibt es keine gespeicherten Zugaenge (keine Passwoerter in der App)
        router.get("/api/services", placeholder: true) { _, _ in
            var creds: [String: JSONValue] = [:]
            for k in ["studip", "qis", "idm", "ilias", "mail", "matrix", "luhki", "gitlab"] { creds[k] = noCredential }
            return .json(["services": [], "credentials": .object(creds),
                          "qis": ["configured": false, "same_as_studip": true, "last_run": .null],
                          "studip": ["configured": false]])
        }
        router.get("/api/grades", placeholder: true) { _, _ in
            .json(["grades": [], "average": .null, "credits": 0, "passed": 0, "last_run": .null, "documents": []])
        }
        router.post("/api/grades/sync", placeholder: true) { _, _ in
            throw LocalHTTPError.notFound("Noten aus QIS kommen in einer späteren Version.")
        }
        router.get("/api/qis/documents/{doc_id:int}", placeholder: true) { _, _ in throw LocalHTTPError.notFound() }

        router.get("/api/flashcards", placeholder: true) { req, _ in
            _ = try req.boolQuery("due")
            return .json([])
        }
        router.post("/api/flashcards/{card_id:int}/review", placeholder: true) { req, _ in
            _ = try req.objectBody()
            throw LocalHTTPError.notFound()
        }
        router.delete("/api/flashcards/{card_id:int}", placeholder: true) { _, _ in .ok }
    }
}

/// Bewusst entfallen in V1 (Entscheidung des Inhabers vom 25.10.2026): KI, Wochentests mit KI, gespeicherte
/// Zugangsdaten. Listen antworten leer, alles andere mit 404 und klarer Meldung – nichts wird vorgetaeuscht.
enum DroppedEndpoints: LocalEndpointModule {
    static let name = "Entfallen (KI, Tests, Zugänge)"

    static let noAI = "KI-Funktionen gibt es in dieser Version nicht."
    static let noTests = "Wochentests gibt es in dieser Version nicht."

    static func register(on router: LocalRouter) {
        router.post("/api/ai/tutor") { _, _ in throw LocalHTTPError.notFound(noAI) }

        router.get("/api/tests") { _, _ in .json([]) }
        router.get("/api/tests/{test_id:int}") { _, _ in throw LocalHTTPError.notFound(noTests) }
        router.post("/api/tests/generate") { _, _ in throw LocalHTTPError.notFound(noTests) }
        router.post("/api/tests/generate-week") { _, _ in throw LocalHTTPError.notFound(noTests) }
        router.post("/api/tests/{test_id:int}/submit") { _, _ in throw LocalHTTPError.notFound(noTests) }
        router.delete("/api/tests/{test_id:int}") { _, _ in .ok }
        router.post("/api/tasks/{task_id:int}/start-test") { _, _ in throw LocalHTTPError.notFound(noTests) }

        router.get("/api/credentials") { _, _ in .json(["user": .null, "password_set": false]) }
        router.put("/api/credentials/{service}") { _, _ in
            throw LocalHTTPError.notFound("Auf dem iPad werden keine Zugangsdaten gespeichert.")
        }
    }
}
