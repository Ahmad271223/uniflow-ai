import Foundation

/// Smart Planner 2.0 wie app/smart_goals.py: `/api/goals*` (Lernziele, Plan, Bloecke) und `/api/sessions*`
/// (Lernzeit). Jede Anfrage ist eine Transaktion (BEGIN IMMEDIATE, nacheinander): eine doppelt gestartete Neuplanung
/// findet beim zweiten Lauf die Pruefsumme schon vor und aendert nichts. Ohne KI.
public enum SmartGoalsEndpoints: LocalEndpointModule {
    public static let name = "Lernziele"

    /// Tarifpruefung der App: automatisch umplanen erst ab Plus (`UFFeature.autoPlan`); ohne App (Kern-Tests, PC) erlaubt
    @MainActor public static var autoAllowed: () -> Bool = { true }

    static func uid(_ req: LocalRequest) -> String { req.param("uid") }

    public static func register(on router: LocalRouter) {
        router.get("/api/goals") { _, ctx in
            let auto = await MainActor.run(body: { autoAllowed() })
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.overview($0, auto: auto, clock: clock) })
        }
        router.get("/api/goals/settings") { _, ctx in
            .json(try await ctx.database.transaction { SmartGoals.publicSettings(try SmartGoals.settings($0)) })
        }
        router.put("/api/goals/settings") { req, ctx in
            let b = try req.objectBody()
            return .json(try await ctx.database.transaction { SmartGoals.publicSettings(try SmartGoals.saveSettings($0, b)) })
        }
        router.post("/api/goals/plan") { req, ctx in
            let b = try req.objectBody(orEmpty: true)
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.planNow($0, b, clock: clock) })
        }
        router.post("/api/goals/plan/keep") { _, ctx in
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.keepPlan($0, clock: clock) })
        }
        router.put("/api/goals/{module_id:int}") { req, ctx in
            let b = try req.objectBody()
            let id = req.intParam("module_id"), clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.saveGoal($0, moduleID: id, b, clock: clock) })
        }
        router.delete("/api/goals/{module_id:int}") { req, ctx in
            let id = req.intParam("module_id"), clock = ctx.clock
            try await ctx.database.transaction { try SmartGoals.deleteGoal($0, moduleID: id, clock: clock) }
            return .json(["ok": true])
        }
        router.post("/api/goals/blocks/{package_id:int}/done") { req, ctx in
            let b = try req.objectBody(orEmpty: true)
            let id = req.intParam("package_id"), clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.blockDone($0, packageID: id, b, clock: clock) })
        }
        router.post("/api/goals/blocks/{package_id:int}/undone") { req, ctx in
            let id = req.intParam("package_id"), clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.blockUndone($0, packageID: id, clock: clock) })
        }
        router.patch("/api/goals/blocks/{package_id:int}") { req, ctx in
            let b = try req.objectBody()
            let id = req.intParam("package_id")
            return .json(try await ctx.database.transaction { try SmartGoals.setLocked($0, packageID: id, b) })
        }
        router.post("/api/goals/blocks/{package_id:int}/check") { req, ctx in
            let b = try req.objectBody(orEmpty: true)
            let id = req.intParam("package_id")
            return .json(try await ctx.database.transaction { try SmartGoals.checkSlot($0, packageID: id, b) })
        }

        router.get("/api/sessions") { req, ctx in
            let module = try req.query("module_id").map { v -> Int in
                guard let i = Int(v) else { throw LocalHTTPError(status: 422, message: "module_id ist keine Zahl") }
                return i
            }
            let start = try SmartGoals.checkDate(req.query("start").map(JSONValue.string), "start")
            let end = try SmartGoals.checkDate(req.query("end").map(JSONValue.string), "end")
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.listSessions($0, moduleID: module, start: start, end: end, clock: clock) })
        }
        router.post("/api/sessions") { req, ctx in
            let b = try req.objectBody()
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.addSession($0, b, clock: clock) })
        }
        router.post("/api/sessions/start") { req, ctx in
            let b = try req.objectBody()
            let clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.startSession($0, b, clock: clock) })
        }
        router.post("/api/sessions/{uid}/pause") { req, ctx in
            let u = uid(req), clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.pauseSession($0, u, clock: clock) })
        }
        router.post("/api/sessions/{uid}/resume") { req, ctx in
            let u = uid(req), clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.resumeSession($0, u, clock: clock) })
        }
        router.post("/api/sessions/{uid}/stop") { req, ctx in
            let u = uid(req), clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.stopSession($0, u, clock: clock) })
        }
        router.patch("/api/sessions/{uid}") { req, ctx in
            let b = try req.objectBody()
            let u = uid(req), clock = ctx.clock
            return .json(try await ctx.database.transaction { try SmartGoals.correctSession($0, u, b, clock: clock) })
        }
        router.delete("/api/sessions/{uid}") { req, ctx in
            let u = uid(req), clock = ctx.clock
            try await ctx.database.transaction { try SmartGoals.deleteSession($0, u, clock: clock) }
            return .json(["ok": true])
        }
    }
}
