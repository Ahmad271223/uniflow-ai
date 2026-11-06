import Foundation

/// Bescheinigungen (docs/BESCHEINIGUNGEN-2026-11-06.md) wie in app/server.py:
/// - `GET /api/certificates`: Liste der Dokumente, die das Portal anbietet (aus `settings.certificates`), je Dokument
///   die gespeicherte Kopie mit Datum ("Stand"), dazu die ueblichen Arten mit "angeboten ja/nein" und ein Hinweis je
///   Hochschule (`CertificatesSync.summary`).
/// - `GET /api/certificates/{id}/file`: die gespeicherte PDF (nur aus dem Container).
/// Liste lesen und Herunterladen braucht die Sitzung der Webansicht und laeuft deshalb in der App
/// (`CertificateCenter` mit `CertificatesSync.refresh`/`download`), am PC ueber `POST /api/certificates/refresh` bzw.
/// `/api/certificates/{id}/download`.
enum CertificatesEndpoints: LocalEndpointModule {
    static let name = "Bescheinigungen"

    static func register(on router: LocalRouter) {
        router.get("/api/certificates") { _, ctx in
            let files = ctx.files
            return .json(try await ctx.database.withConnection { try CertificatesSync.summary($0, files: files) })
        }
        router.get("/api/certificates/{cert_id}/file") { req, ctx in
            let id = req.param("cert_id")
            let files = ctx.files
            guard let url = try await ctx.database.withConnection({ try CertificatesSync.fileURL($0, files: files, id: id) }) else {
                throw LocalHTTPError.notFound("Keine gespeicherte Bescheinigung")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return LocalFileResponse.response(data, mediaType: "application/pdf", filename: url.lastPathComponent, disposition: "inline")
        }
        // nur am eigenen Server (Playwright mit der Anmeldung am PC); auf dem iPad liest und laedt `CertificateCenter`
        router.post("/api/certificates/refresh") { _, _ in
            throw LocalHTTPError.notFound("Auf dem iPad liest StudiNow die Liste mit deiner Anmeldung in der App.")
        }
        router.post("/api/certificates/{cert_id}/download") { _, _ in
            throw LocalHTTPError.notFound("Auf dem iPad lädt StudiNow die Bescheinigung mit deiner Anmeldung in der App.")
        }
    }
}
