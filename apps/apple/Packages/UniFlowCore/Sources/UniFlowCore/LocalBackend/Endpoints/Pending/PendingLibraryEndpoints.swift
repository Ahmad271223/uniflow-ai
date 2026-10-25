import Foundation

/// Platzhalter: Bibliothek, Ordner, Notizbuecher, Datei-Inhalt, Notizen, Skriptsuche (S3, S7).
///
/// Notizen: `GET .../annotations` liefert ein leeres gueltiges Dokument, `PUT` antwortet mit 409 und Meldung, aber
/// ohne `version`/`data` – die App wertet das nicht als Konflikt, sondern als "noch nicht moeglich"; die Notizen
/// bleiben im lokalen Journal und gehen nicht verloren.
enum PendingLibraryEndpoints: LocalEndpointModule {
    static let name = "Bibliothek (Platzhalter)"

    static func register(on router: LocalRouter) {
        router.get("/api/library", placeholder: true) { _, _ in
            .json(["folders": [], "files": [], "modules": [], "trash": []])
        }

        router.post("/api/folders", placeholder: true) { req, _ in
            _ = try req.objectBody()
            throw LocalPending.notYet("Ordner anlegen")
        }
        router.patch("/api/folders/{folder_id:int}", placeholder: true) { req, _ in
            _ = try req.objectBody()
            return .json(.null)                                                // Ordner gibt es nicht: Zeile None
        }
        router.delete("/api/folders/{folder_id:int}", placeholder: true) { _, _ in .ok }

        router.post("/api/notebooks", placeholder: true) { req, _ in
            let form = try req.multipart()
            let kind = form.fields["kind"] ?? "notebook"
            throw LocalPending.notYet(kind == "pdf" || kind == "image" ? "Dateien importieren" : "Eigene Notizbücher anlegen")
        }

        router.patch("/api/library/files/{file_id}", placeholder: true) { req, _ in
            let body = try req.objectBody()
            if body["duplicate"].map(LocalPending.truthy) == true { throw LocalHTTPError.notFound("Dokument nicht gefunden") }
            return .ok
        }
        router.post("/api/files/{file_id}/favorite", placeholder: true) { req, _ in
            _ = try req.objectBody()
            return .ok
        }

        router.get("/api/files/{file_id}/content", placeholder: true) { _, _ in
            throw LocalHTTPError.notFound("Datei nicht lokal vorhanden")
        }
        router.get("/api/files/{file_id}/pagetext", placeholder: true) { _, _ in throw LocalHTTPError.notFound() }
        router.get("/api/assets/{file_id}/{name}", placeholder: true) { _, _ in throw LocalHTTPError.notFound() }

        router.get("/api/files/{file_id}/annotations", placeholder: true) { _, _ in .json(LocalPending.emptyAnnotations) }
        router.put("/api/files/{file_id}/annotations", placeholder: true) { req, _ in
            _ = try req.objectBody()
            throw LocalHTTPError(status: 409, message: "Notizen werden auf diesem iPad noch nicht gespeichert. Deine Änderungen bleiben lokal gesichert.")
        }

        // scriptsearch: Dokument ohne Modul (es gibt noch keine Dateien)
        router.post("/api/related", placeholder: true) { req, _ in
            _ = try req.objectBody()
            return .json(["terms": [], "results": [], "note": "Dokument gehoert zu keinem Modul"])
        }
    }
}

extension LocalPending {
    /// Wahrheitswert wie Pythons `if body.get(...)`
    static func truthy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }
}
