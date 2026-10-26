import Foundation

/// Platzhalter: Uni & Noten (QIS auf dem Geraet folgt, F4) und Karteikarten (Plus, eigenes Anlegen ohne KI).
enum PendingServicesEndpoints: LocalEndpointModule {
    static let name = "Uni & Noten, Karteikarten (Platzhalter)"

    /// `SERVICES` aus app/server.py: feste Liste der Uni-Dienste mit Links (ohne PC-Bezug, liest keine .env);
    /// gleich mit Python laut Fixture app-paths.json ("values")
    static let services: JSONValue = [
        ["key": "studip", "name": "Stud.IP", "url": "https://studip.uni-hannover.de/", "desc": "Kurse, Dateien, Termine, Ankündigungen", "login": "WebSSO (LUH-ID)", "icon": "book", "connected": true],
        ["key": "ilias", "name": "ILIAS", "url": "https://ilias.uni-hannover.de/", "desc": "Lernplattform: Kurse, Tests, Lernmodule", "login": "WebSSO (LUH-ID)", "icon": "layers"],
        ["key": "qis", "name": "QIS / LSF (Prüfungsverwaltung)", "url": "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=user&type=0&application=lsf", "desc": "Notenspiegel, Prüfungsanmeldung, Bescheinigungen", "login": "LUH-ID", "icon": "exam", "connector": true],
        ["key": "idm", "name": "IDM Account-Manager", "url": "https://login.uni-hannover.de/", "desc": "LUH-ID verwalten, Passwort ändern, WebSSO", "login": "LUH-ID", "icon": "user"],
        ["key": "mail", "name": "E-Mail (LUIS)", "url": "https://www.luis.uni-hannover.de/de/services/kommunikation/e-mail", "desc": "Studentisches E-Mail-Postfach und Webmail", "login": "LUH-ID", "icon": "bell"],
        ["key": "matrix", "name": "Matrix-Chat", "url": "https://www.luis.uni-hannover.de/de/services/kommunikation/messenger-chat-dienst-matrix", "desc": "Messenger der Uni, auch in Stud.IP-Kursen", "login": "LUH-ID", "icon": "users"],
        ["key": "luhki", "name": "LUHKI", "url": "https://www.luis.uni-hannover.de/de/services/anwendungen/luhki-2", "desc": "KI-Plattform der LUH", "login": "LUH-ID", "icon": "sparkles"],
        ["key": "gitlab", "name": "GitLab (LUIS)", "url": "https://www.luis.uni-hannover.de/de/services/anwendungen/versionsverwaltung-von-software-projekten-gitlab", "desc": "Versionsverwaltung für Programmieren-Projekte", "login": "LUH-ID", "icon": "file-text"],
        ["key": "tib", "name": "TIB Bibliothek", "url": "https://www.tib.eu/", "desc": "Literatur, Lernplätze, Ausleihe", "login": "Bibliotheksausweis", "icon": "book"],
        ["key": "mensa", "name": "Mensa (Studentenwerk)", "url": "https://www.studentenwerk-hannover.de/essen/speiseplaene", "desc": "Speisepläne der Mensen", "login": "–", "icon": "sun"],
        ["key": "servicecenter", "name": "ServiceCenter", "url": "https://www.uni-hannover.de/de/studium/beratung-hilfe/servicecenter", "desc": "Immatrikulation, Rückmeldung, Beratung", "login": "–", "icon": "info"],
        ["key": "luis", "name": "LUIS IT-Support", "url": "https://www.luis.uni-hannover.de/de/services/kurse-beratung-und-support/it-support", "desc": "WLAN, VPN, Software, Zugänge", "login": "–", "icon": "settings"],
    ]

    /// `config.service_status` ohne gespeicherten Zugang
    private static let noCredential: JSONValue = ["own": false, "same_as": .null, "user": .null, "configured": false]

    static func register(on router: LocalRouter) {
        // /api/services: Dienste wie am PC; auf dem iPad gibt es keine gespeicherten Zugaenge (keine Passwoerter in
        // der App), der letzte QIS-Abruf kommt mit QIS auf dem Geraet (F4)
        router.get("/api/services", placeholder: true) { _, ctx in
            var creds: [String: JSONValue] = [:]
            for k in ["studip", "qis", "idm", "ilias", "mail", "matrix", "luhki", "gitlab"] { creds[k] = noCredential }
            // Dienste der Hochschule dieser Datenbank wie api_services (HILDESHEIM_SERVICES bzw. SERVICES)
            let uni = try await ctx.database.withConnection { try $0.scalar("SELECT value FROM settings WHERE key='university'")?.string }
            let list: JSONValue = uni == UniversityKey.hildesheim.rawValue
                ? .array(UniversityProfile.hildesheim.services.map(\.json)) : services
            return .json(["services": list, "credentials": .object(creds),
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
