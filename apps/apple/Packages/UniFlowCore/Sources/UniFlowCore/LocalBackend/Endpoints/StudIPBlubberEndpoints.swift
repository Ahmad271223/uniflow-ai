import Foundation

/// Blubber aus Stud.IP (`StudIPBlubber`, nur Geraet, keine Python-Entsprechung): `GET /api/studip/blubber?course=&module=`
/// (Threads mit Anzahl, neuen Beitraegen und Vorschau, neuester zuerst) und `GET /api/studip/blubber/{thread_id}`
/// (Beitraege mit Rolle statt Name, aelteste zuerst, 404 unbekannt). Nur lesend; ohne Tabelle (noch kein Abgleich) leer.
enum StudIPBlubberEndpoints: LocalEndpointModule {
    static let name = "Blubber aus Stud.IP"

    static func register(on router: LocalRouter) {
        router.get("/api/studip/blubber") { req, ctx in
            let module: Int? = try {
                guard let raw = req.query("module"), !raw.isEmpty else { return nil }
                guard let n = Int(raw.trimmingCharacters(in: .whitespaces)) else {
                    throw LocalHTTPError.validation(type: "int_parsing", loc: ["query", "module"],
                                                    msg: "Input should be a valid integer, unable to parse string as an integer", input: .string(raw))
                }
                return n
            }()
            let course = req.query("course")
            let today = BerlinClock.parseISODate(ctx.clock.today) ?? 0
            return .json(try await ctx.database.withConnection {
                try StudIPBlubber.overview($0, courseID: course, moduleID: module, today: today)
            })
        }

        router.get("/api/studip/blubber/{thread_id}") { req, ctx in
            let id = req.param("thread_id")
            guard let d = try await ctx.database.withConnection({ try StudIPBlubber.thread($0, id: id) }) else {
                throw LocalHTTPError.notFound("Blubber nicht gefunden")
            }
            return .json(d)
        }
    }
}
