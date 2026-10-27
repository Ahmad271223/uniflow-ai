import Foundation

/// `GET/POST /api/demo` wie app/server.py (`demo_status`, `demo_toggle`): Demo-Inhalte fuer die App-Pruefung ohne
/// Hochschulkonto (`DemoContent`).
/// - `GET /api/demo`: `{enabled, files, events, packages, module}`
/// - `POST /api/demo` mit `{"enabled": true}` (Wahrheitswert wie Python, Rumpf wie `Body(default={})`): frisch anlegen,
///   Antwort wie GET; sonst alles entfernen, Antwort wie GET mit `removed: {files, events, packages}`.
/// Anlegen braucht die Dateiablage (sonst 503); Entfernen geht auch ohne (dann nur die Datenbank).
public enum DemoEndpoints: LocalEndpointModule {
    public static let name = "Demo-Inhalte"

    public static func register(on router: LocalRouter) {
        router.get("/api/demo") { _, ctx in
            .json(.object(try await ctx.database.withConnection { try DemoContent.status($0) }))
        }

        router.post("/api/demo") { req, ctx in
            let body = try req.objectBody(orEmpty: true)
            let clock = ctx.clock
            if LocalModules.truthy(body["enabled"]) {
                let files = try ctx.requireFiles()
                return .json(.object(try await ctx.database.transaction { try DemoContent.install($0, files: files, clock: clock) }))
            }
            let files = ctx.files
            let s = try await ctx.database.transaction { c -> [String: JSONValue] in
                let removed = try DemoContent.remove(c, files: files)          // erst entfernen, dann den Stand melden
                var s = try DemoContent.status(c)
                s["removed"] = removed.json
                return s
            }
            return .json(.object(s))
        }
    }
}
