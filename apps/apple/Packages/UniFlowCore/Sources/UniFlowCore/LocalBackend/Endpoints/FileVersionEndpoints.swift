import Foundation

/// Alte Original-Fassungen von Dateien mit Notizen (S7, nur auf dem Geraet; `FileVersions`, `FileVersionKeeper`):
/// - `GET /api/files/{id}/versions`: alte Fassungen, neueste zuerst (`notice`: die neueste, solange ihr Hinweis
///   nicht gesehen ist)
/// - `POST /api/files/{id}/versions/seen`: Hinweis gesehen
/// - `GET /api/files/{id}/versions/{n}/content` und `GET .../annotations`: die alte Fassung mit ihren Notizen, wie
///   `/content` und `/annotations` einer Datei; der Editor oeffnet sie unter `FileVersions.documentID`
/// - `PUT .../annotations`: 409 ohne `version` (alte Fassungen sind nur zum Ansehen; die App behaelt Ungesendetes im
///   Journal wie bei einem Dokument, das es nicht gibt)
/// Am PC gibt es diese Pfade nicht (404, die App zeigt dann nichts an).
public enum FileVersionEndpoints: LocalEndpointModule {
    public static let name = "Alte Fassungen"

    public static func register(on router: LocalRouter) {
        router.get("/api/files/{file_id}/versions") { req, ctx in
            let id = req.param("file_id"), files = ctx.files
            let list = try await ctx.database.withConnection { try FileVersions.list($0, fileID: id, files: files) }
            let notice = list.first.flatMap { $0["seen"]?.bool == false ? $0 : nil } ?? .null
            return .json(["versions": .array(list), "notice": notice])
        }

        router.post("/api/files/{file_id}/versions/seen") { req, ctx in
            let id = req.param("file_id")
            try await ctx.database.transaction { c in
                if try FileVersions.hasTable(c) { try c.execute("UPDATE file_versions SET seen=1 WHERE file_id=?", [.text(id)]) }
            }
            return .ok
        }

        router.get("/api/files/{file_id}/versions/{version:int}/content") { req, ctx in
            let id = req.param("file_id"), n = req.intParam("version")
            let r = try await ctx.database.withConnection { try FileVersions.row($0, fileID: id, version: n) }
            guard let r, let path = r["local_path"]?.string, let files = ctx.files, files.exists(stored: path),
                  let url = files.url(stored: path) else { throw LocalHTTPError.notFound("Alte Fassung nicht vorhanden") }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return LocalFileResponse.response(data, mediaType: "application/pdf", filename: r["name"]?.string, disposition: "inline")
        }

        router.get("/api/files/{file_id}/versions/{version:int}/annotations") { req, ctx in
            let id = req.param("file_id"), n = req.intParam("version")
            let r = try await ctx.database.withConnection { try FileVersions.row($0, fileID: id, version: n) }
            guard let r else { throw LocalHTTPError.notFound("Alte Fassung nicht vorhanden") }
            return .json(["data": try AnnotationEndpoints.parseStored(r["annotations"]), "updated_at": r["replaced_at"]?.json ?? .null,
                          "version": 1])
        }

        router.put("/api/files/{file_id}/versions/{version:int}/annotations") { _, _ in
            throw LocalHTTPError(status: 409, message: "Alte Fassungen sind nur zum Ansehen.")
        }
    }
}
