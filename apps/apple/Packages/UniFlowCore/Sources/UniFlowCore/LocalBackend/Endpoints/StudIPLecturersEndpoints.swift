import Foundation

/// Lehrende und Kontakte (LUH, Stud.IP, `StudIPLecturers`), wie app/studip_lecturers_api.py:
/// `GET /api/lecturers[?course_id=|module_id=][&q=]` – Lehrende eines Kurses, eines Moduls oder aller aktiven Kurse.
/// Nur an Hochschulen mit Stud.IP (`available`); ohne Abgleich leer mit Hinweis. Nur lesend, alles auf dem Geraet.
/// Die Nachricht ueber Stud.IP schickt die App selbst (`MessageReplyModel`, schreibender Transport), nicht dieser Router.
enum StudIPLecturersEndpoints: LocalEndpointModule {
    static let name = "Lehrende und Kontakte"

    static func register(on router: LocalRouter) {
        router.get("/api/lecturers") { req, ctx in
            let course = req.query("course_id").flatMap { $0.isEmpty ? nil : $0 }
            let module = req.query("module_id").flatMap { Int($0) }
            let q = req.query("q")
            return .json(try await ctx.database.withConnection { c in
                let uni = try Holidays.university(c)
                let base = UniversityProfile.profile(forKey: uni)?.studipBase?.absoluteString ?? ""
                return try StudIPLecturers.overview(c, university: uni, base: base, courseID: course, moduleID: module, q: q)
            })
        }
    }
}
