import Foundation

/// Kommende Klausuren (`Exams`, wie app/exams.py):
/// - `GET /api/exams/upcoming[?module_id=]`: `{items, today, filled}`; je Eintrag Tag, Uhrzeit, Raum, Modul, Kurs,
///   `in_days`, Quellen (`sources`, `source_label`: "aus Stud.IP-Terminen", "aus Ankündigung vom …", "selbst
///   eingetragen" …) und `user_set`. Fuellt vorher leere Klausurtermine der Module (`filled`), nie einen eigenen.
public enum ExamsEndpoints: LocalEndpointModule {
    public static let name = "Klausuren"

    public static func register(on router: LocalRouter) {
        router.get("/api/exams/upcoming") { req, ctx in
            var module: Int?
            if let raw = req.query("module_id") {
                guard let v = Int(raw) else {
                    throw LocalHTTPError.validation(type: "int_parsing", loc: ["query", "module_id"],
                                                    msg: "Input should be a valid integer, unable to parse string as an integer", input: .string(raw))
                }
                module = v
            }
            let t = LocalTimetable.today(ctx.clock), moduleID = module
            let v = try await ctx.database.transaction { try Exams.response($0, today: t, moduleID: moduleID) }
            return .json(v)
        }
    }
}
