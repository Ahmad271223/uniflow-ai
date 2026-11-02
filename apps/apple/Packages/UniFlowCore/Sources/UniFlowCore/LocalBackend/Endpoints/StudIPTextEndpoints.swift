import Foundation

/// Lernstoff aus Stud.IP (Courseware, Wiki, Forum; `StudIPTexts`) wie app/server.py: `GET /api/modules/{id}/studip`
/// (Bereich "Aus Stud.IP" der Modulansicht: je Art Anzahl, letzte Aenderung, Eintraege) und `GET /api/studip-texts/{id}`
/// (ein Text zum Lesen, 404 unbekannt). Nur lesend; ohne Tabelle (noch kein Abgleich) leer.
enum StudIPTextEndpoints: LocalEndpointModule {
    static let name = "Lernstoff aus Stud.IP"

    static func register(on router: LocalRouter) {
        router.get("/api/modules/{module_id:int}/studip") { req, ctx in
            let id = SQLiteValue.integer(Int64(req.intParam("module_id")))
            return .json(try await ctx.database.withConnection { try StudIPTexts.overview($0, moduleID: id) })
        }

        router.get("/api/studip-texts/{text_id}") { req, ctx in
            let id = req.param("text_id")
            guard let d = try await ctx.database.withConnection({ try StudIPTexts.item($0, id: id) }) else {
                throw LocalHTTPError.notFound("Text nicht gefunden")
            }
            return .json(d)
        }
    }
}
