import Foundation

/// Platzhalter: Module und Kurse (S3, S4).
enum PendingModulesEndpoints: LocalEndpointModule {
    static let name = "Module (Platzhalter)"

    static func register(on router: LocalRouter) {
        router.get("/api/modules", placeholder: true) { _, _ in .json([]) }
        router.get("/api/modules/{module_id:int}", placeholder: true) { _, _ in throw LocalHTTPError.notFound() }
        router.post("/api/modules", placeholder: true) { req, _ in
            let name = try req.objectBody()["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty { throw LocalHTTPError(status: 400, message: "Name fehlt") }
            throw LocalPending.notYet("Module anlegen")
        }
        router.patch("/api/modules/{module_id:int}", placeholder: true) { req, _ in
            _ = try req.objectBody()
            return .json(.null)
        }
        // keine Kurse ohne Modul: nichts zuzuordnen
        router.post("/api/modules/auto-assign", placeholder: true) { _, _ in .json(["assigned": 0, "uncertain": []]) }

        router.get("/api/courses", placeholder: true) { _, _ in .json([]) }
        router.patch("/api/courses/{course_id}", placeholder: true) { req, _ in
            _ = try req.objectBody()
            return .json(.null)
        }
        router.post("/api/courses/{course_id}/module", placeholder: true) { req, _ in
            let body = try req.objectBody()
            if !(body["module_id"].map(LocalPending.truthy) ?? false) { return .ok }
            throw LocalHTTPError.notFound("Modul nicht gefunden")
        }
    }
}

