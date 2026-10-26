import Foundation

/// Platzhalter: Uni & Noten (QIS auf dem Geraet folgt, F4; die Leistungen selbst liefert `GradesEndpoints`) und
/// Karteikarten (Plus, eigenes Anlegen ohne KI).
enum PendingServicesEndpoints: LocalEndpointModule {
    static let name = "Uni & Noten, Karteikarten (Platzhalter)"

    /// `config.service_status` ohne gespeicherten Zugang
    private static let noCredential: JSONValue = ["own": false, "same_as": .null, "user": .null, "configured": false]

    static func register(on router: LocalRouter) {
        // /api/services: Dienste und Hochschule wie api_services am PC. Zugaenge ueber diese Schnittstelle gibt es
        // auf dem iPad nicht: Benutzername und Passwort merkt sich die App (auf Wunsch) im Schluesselbund dieses
        // iPads und fuellt sie nur auf der Anmeldeseite der Hochschule vor (UniversityCredentialStore); der letzte
        // QIS-Abruf kommt mit QIS auf dem Geraet (F4)
        router.get("/api/services", placeholder: true) { _, ctx in
            var creds: [String: JSONValue] = [:]
            for k in ["studip", "qis", "idm", "ilias", "mail", "matrix", "luhki", "gitlab"] { creds[k] = noCredential }
            // Dienste der Hochschule dieser Datenbank wie api_services (HILDESHEIM_SERVICES bzw. SERVICES, eine Quelle:
            // UniversityProfile); ohne gueltige Einstellung die der LUH wie am PC
            let uni = try await ctx.database.withConnection { try $0.scalar("SELECT value FROM settings WHERE key='university'")?.string }
            let profile = UniversityProfile.profile(forKey: uni) ?? UniversityKey.default.profile
            return .json(["services": .array(profile.services.map(\.json)), "credentials": .object(creds),
                          "university": profile.json,
                          "universities": .array(UniversityProfile.all.map { ["key": .string($0.key.rawValue), "name": .string($0.name)] }),
                          "qis": ["configured": false, "same_as_studip": true, "last_run": .null],
                          "studip": ["configured": false]])
        }
        // Nur am eigenen Server: Notenabruf aus QIS und Bescheinigungen. GET /api/grades liest die Tabelle grades
        // (GradesEndpoints); den Abruf auf dem Geraet macht an der Uni Hildesheim der Abgleich der App
        // (HildesheimSync), an der LUH folgt QIS (F4)
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

/// Bewusst entfallen in V1 (Entscheidung des Inhabers vom 25.10.2026): KI, Wochentests mit KI und das Speichern von
/// Zugangsdaten ueber die Schnittstelle (nur am eigenen Server; die App merkt sie sich selbst im Schluesselbund).
/// Listen antworten leer, alles andere mit 404 und klarer Meldung – nichts wird vorgetaeuscht.
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
            throw LocalHTTPError.notFound("Zugangsdaten merkt sich die App nur im Schlüsselbund dieses iPads, auf der Anmeldeseite der Hochschule.")
        }
    }
}
