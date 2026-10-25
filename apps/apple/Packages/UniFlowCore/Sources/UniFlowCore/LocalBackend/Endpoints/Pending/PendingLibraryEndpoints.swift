import Foundation

/// Platzhalter: Seitentext und Skriptsuche (S7). Bibliothek, Ordner, Notizbuecher, Datei-Inhalt und Notizen sind seit
/// S3 echt (LibraryEndpoints, FilesEndpoints, AnnotationEndpoints).
enum PendingLibraryEndpoints: LocalEndpointModule {
    static let name = "Skriptsuche (Platzhalter)"

    static func register(on router: LocalRouter) {
        router.get("/api/files/{file_id}/pagetext", placeholder: true) { _, _ in throw LocalHTTPError.notFound() }

        // scriptsearch: noch ohne Seitentexte, also ohne Treffer
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
