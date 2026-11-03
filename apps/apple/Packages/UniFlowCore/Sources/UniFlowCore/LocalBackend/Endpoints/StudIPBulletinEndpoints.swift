import Foundation

/// Schwarzes Brett aus Stud.IP (`StudIPBulletin`, nur Geraet, keine Python-Entsprechung): `GET /api/studip/bulletin?topic=`
/// (Themen mit Anzahl, Anzeigen neueste zuerst, `available` nach der Hochschule) und `GET /api/studip/bulletin/{id}`
/// (eine Anzeige zum Lesen, 404 unbekannt). Nur lesend; ohne Tabelle (noch kein Abgleich) leer.
enum StudIPBulletinEndpoints: LocalEndpointModule {
    static let name = "Schwarzes Brett aus Stud.IP"

    static func register(on router: LocalRouter) {
        router.get("/api/studip/bulletin") { req, ctx in
            let topic = req.query("topic")
            let today = BerlinClock.parseISODate(ctx.clock.today) ?? 0
            return .json(try await ctx.database.withConnection { try StudIPBulletin.overview($0, topic: topic, today: today) })
        }

        router.get("/api/studip/bulletin/{entry_id}") { req, ctx in
            let id = req.param("entry_id")
            guard let d = try await ctx.database.withConnection({ try StudIPBulletin.item($0, id: id) }) else {
                throw LocalHTTPError.notFound("Anzeige nicht gefunden")
            }
            return .json(d)
        }
    }
}
