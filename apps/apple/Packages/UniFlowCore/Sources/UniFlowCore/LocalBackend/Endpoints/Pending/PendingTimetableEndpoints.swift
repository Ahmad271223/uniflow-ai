import Foundation

/// Platzhalter: Stundenplan, Termine, Import, Konflikte (S5). Ohne Termine; freie Fenster folgen mit dem Port von
/// `timetable.free_windows`, Sperrzeiten kommen schon aus den Einstellungen.
enum PendingTimetableEndpoints: LocalEndpointModule {
    static let name = "Stundenplan (Platzhalter)"

    static func register(on router: LocalRouter) {
        router.get("/api/timetable/week", placeholder: true) { req, ctx in
            let start = try LocalPending.day(req, "start")
            let s = try await LocalPending.settings(ctx)
            let term = try await ctx.database.withConnection { try LocalTerms.current($0) }
            let days: [JSONValue] = (0..<7).map { i in
                let d = start + i
                return ["date": .string(LocalPending.iso(d)), "weekday": .number(Double(LocalPending.weekday(d))), "events": [], "packages": [],
                        "free": [], "blocked": LocalPending.blocked(d, settings: s)]
            }
            return .json(["start": .string(LocalPending.iso(start)), "end": .string(LocalPending.iso(start + 6)), "days": .array(days),
                          "learn_start": s["learn_start"] ?? .null, "learn_end": s["learn_end"] ?? .null, "term": term])
        }
        router.get("/api/timetable/day", placeholder: true) { req, ctx in
            let d = try LocalPending.day(req, "date")
            let s = try await LocalPending.settings(ctx)
            return .json(["date": .string(LocalPending.iso(d)), "events": [], "packages": [], "free": [],
                          "blocked": LocalPending.blocked(d, settings: s),
                          "learn_start": s["learn_start"] ?? .null, "learn_end": s["learn_end"] ?? .null])
        }

        router.get("/api/timetable/events", placeholder: true) { _, _ in .json([]) }
        router.post("/api/timetable/events", placeholder: true) { req, _ in
            _ = try req.objectBody()
            throw LocalPending.notYet("Termine anlegen")
        }
        router.patch("/api/timetable/events/{event_id:int}", placeholder: true) { req, _ in
            _ = try req.objectBody()
            throw LocalHTTPError.notFound()
        }
        router.delete("/api/timetable/events/{event_id:int}", placeholder: true) { _, _ in .ok }
        router.post("/api/timetable/attendance", placeholder: true) { req, _ in
            _ = try req.objectBody()
            throw LocalHTTPError.notFound()
        }
        router.get("/api/timetable/event-materials/{event_id:int}", placeholder: true) { req, _ in
            _ = try LocalPending.day(req, "date")
            throw LocalHTTPError.notFound()
        }
        router.get("/api/timetable/conflicts", placeholder: true) { _, _ in .json([]) }
        router.get("/api/timetable/auto-status", placeholder: true) { _, _ in
            .json(["pending_groups": 0, "courses": [], "personal": []])
        }

        // Lernslots der Tage neu legen: ohne Pakete gibt es nichts zu verschieben; Antwort wie Python
        router.post("/api/timetable/reslot", placeholder: true) { req, _ in
            let dates = try req.objectBody(orEmpty: true)["dates"]
            return .json(["reslotted": dates.map { LocalPending.truthy($0) ? $0 : [] } ?? []])
        }

        router.post("/api/timetable/import/preview", placeholder: true) { req, _ in
            let form = try req.multipart()
            guard form.fields["source"] != nil else {
                throw LocalHTTPError.validation(type: "missing", loc: ["body", "source"], msg: "Field required", input: .null)
            }
            throw LocalPending.notYet("Stundenplan importieren")
        }
        router.post("/api/timetable/import/confirm", placeholder: true) { req, _ in
            _ = try req.objectBody()
            throw LocalPending.notYet("Stundenplan importieren")
        }
    }
}
