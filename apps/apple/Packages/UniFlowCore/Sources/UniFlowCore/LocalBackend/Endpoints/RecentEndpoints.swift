import Foundation

/// `GET /api/recent?limit=15` - "Zuletzt benutzt" (iPad, 04.11.2026): Dokumente, die geoeffnet wurden
/// (`files.last_opened`, dazu `last_page` und `opened_count`), und Wochentests, die begonnen oder abgegeben wurden,
/// in einer Liste nach Zeit, neuestes zuerst. KI-Gespraeche fuegt die App hinzu (sie liegen nicht in der Datenbank).
/// Nur im lokalen Backend: das Web hat keine solche Liste (docs/paritaet/ipad-app.md).
public enum RecentEndpoints: LocalEndpointModule {
    public static let name = "recent"
    public static let defaultLimit = 15
    public static let maxLimit = 50

    public static func register(on router: LocalRouter) {
        router.get("/api/recent") { req, ctx in
            let limit = min(maxLimit, max(1, req.query("limit").flatMap(Int.init) ?? defaultLimit))
            let docs = try await ctx.database.rows("""
                SELECT f.id, COALESCE(a.title, f.title, f.name) AS title, c.subject AS sub, f.last_opened AS at,
                       f.last_page AS page, COALESCE(f.opened_count, 0) AS opened_count
                FROM files f LEFT JOIN courses c ON c.id=f.course_id LEFT JOIN analysis a ON a.file_id=f.id
                WHERE f.last_opened IS NOT NULL AND f.last_opened != ''
                ORDER BY f.last_opened DESC LIMIT ?
                """, [.integer(Int64(limit))])
            let tests = try await ctx.database.rows("""
                SELECT id, COALESCE(title, subject) AS title, subject AS sub, COALESCE(submitted_at, started_at) AS at,
                       score, max_score, submitted_at
                FROM tests WHERE COALESCE(user_id,'local')='local' AND COALESCE(submitted_at, started_at) IS NOT NULL
                ORDER BY COALESCE(submitted_at, started_at) DESC LIMIT ?
                """, [.integer(Int64(limit))])
            var items: [JSONValue] = docs.map { r in
                var o = r
                o["kind"] = "document"
                return .object(o)
            }
            items += tests.map { r in
                var o = r
                o["kind"] = "test"
                o["id"] = .string(JSONValue.format(r["id"]?.double ?? 0))
                o["done"] = .bool(!(r["submitted_at"]?.isNull ?? true))
                o.removeValue(forKey: "submitted_at")
                return .object(o)
            }
            items.sort { ($0["at"]?.string ?? "") > ($1["at"]?.string ?? "") }
            return .json(["items": .array(Array(items.prefix(limit)))])
        }
    }
}
