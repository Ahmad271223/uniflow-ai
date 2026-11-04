import Foundation

/// Studienverlauf (docs/STUDIENVERLAUF-2026-11-04.md, wie die Routen in app/study_plan.py):
/// - `GET /api/study-plan`: Semester mit Modulen, LP, Hinweise; `available=false` mit `reason` ohne Katalog
/// - `GET /api/study-plan/module/{id}`: Fakten, lokaler Text, eigener Stand, Kurse/Dateien der App, Quelle mit Seite;
///   fehlen die Texte eines Katalogs aus Grundstock oder Bibliothek, laedt die App sie im Hintergrund nach
///   (`texts_loading: true`, StudyCatalogTriggers.fireTexts)
/// - `GET/POST /api/study-plan/settings`: `{po, start_term, electives}` je Container in `settings.study_plan`
/// Kataloge aus den lokalen Tabellen des Katalog-Abrufs (`DatabaseStudyCatalogSource`).
public enum StudyPlanEndpoints: LocalEndpointModule {
    public static let name = "Studienverlauf"

    public static func register(on router: LocalRouter) {
        router.get("/api/study-plan") { _, ctx in
            let today = ctx.clock.today
            return .json(try await ctx.database.withConnection { try StudyPlanAPI.plan($0, today: today) })
        }
        router.get("/api/study-plan/module/{module_id}") { req, ctx in
            let today = ctx.clock.today, id = req.param("module_id"), now = ctx.clock.now
            let (out, textsKey) = try await ctx.database.withConnection { c -> (JSONValue, String?) in
                let v = try StudyPlanAPI.module(c, id: id, today: today)
                guard v["available"]?.bool == true, v["texts"] == nil || v["texts"] == .null else { return (v, nil) }
                // Katalog aus Grundstock oder Bibliothek ohne lokale Texte: Texte im Hintergrund nachladen (einmal je Katalog)
                let cat = try DatabaseStudyCatalogSource(c).catalogs().first {
                    $0["program"] == v["program"] && $0["po"] == v["po"] && $0["catalog_term"] == v["catalog_term"]
                }
                let key = cat.map(StudyPlanEngine.catalogKey)
                return (v, try key.flatMap { try StudyCatalogPipeline.textsWanted(c, key: $0, now: now) ? $0 : nil })
            }
            if let textsKey, var o = out.object, StudyCatalogTriggers.fireTexts(databasePath: ctx.database.path, key: textsKey) {
                o["texts_loading"] = true
                return .json(.object(o))
            }
            return .json(out)
        }
        router.get("/api/study-plan/settings") { _, ctx in
            let today = ctx.clock.today
            return .json(try await ctx.database.withConnection { try StudyPlanAPI.settings($0, today: today) })
        }
        router.post("/api/study-plan/settings") { req, ctx in
            let body = try req.objectBody(), today = ctx.clock.today
            return .json(try await ctx.database.transaction { try StudyPlanAPI.save($0, body: body, today: today) })
        }
    }
}
