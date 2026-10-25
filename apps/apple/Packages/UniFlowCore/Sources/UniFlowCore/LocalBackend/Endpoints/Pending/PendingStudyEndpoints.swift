import Foundation

/// Platzhalter: Lernkalender, Lernpakete, Aufgaben (S6). Ohne Pakete und Aufgaben antworten die Pfade wie der
/// PC-Server bei leerer Datenbank; die Machbarkeit rechnet schon mit den echten Einstellungen.
enum PendingStudyEndpoints: LocalEndpointModule {
    static let name = "Lernkalender (Platzhalter)"

    static func register(on router: LocalRouter) {
        router.get("/api/calendar", placeholder: true) { req, ctx in
            let start = try LocalPending.day(req, "start")
            let end = try LocalPending.day(req, "end")
            let s = try await LocalPending.settings(ctx)
            let days = start <= end ? (start...end).map { LocalPending.calendarDay($0, settings: s) } : []
            return .json(["start": .string(LocalPending.iso(start)), "end": .string(LocalPending.iso(end)), "days": .array(days),
                          "settings": .object(LocalSettings.publicSettings(s))])
        }

        // study.feasibility ohne Module: offene Menge 0, verfuegbare Zeit und Bedarf aus den Einstellungen
        router.get("/api/calendar/feasibility", placeholder: true) { _, ctx in
            let s = try await LocalPending.settings(ctx)
            func n(_ k: String) -> Int { s[k]?.int ?? 0 }
            let learn = (s["learn_days"]?.array ?? []).compactMap(\.int)
            let t = LocalPending.today(ctx)
            let avail = (0..<28).filter { learn.contains(LocalPending.weekday(t + $0)) }.count * n("minutes_per_day")
            let need = n("subjects_per_day") * (n("parts_lecture") * 45 + n("parts_exercise") * 60 + n("tests_per_subject") * n("test_minutes"))
            let hint: JSONValue = need > n("minutes_per_day")
                ? .string("Deine Kombination braucht etwa \(need) Minuten pro Tag, verfügbar sind \(n("minutes_per_day")). Weniger Fächer pro Tag, kürzere Tests oder mehr Lernzeit wählen.")
                : .null
            return .json(["open_minutes": 0, "available_minutes_4w": .number(Double(avail)), "per_day_need": .number(Double(need)),
                          "per_day_available": .number(Double(n("minutes_per_day"))), "hint": hint])
        }

        router.post("/api/calendar/generate", placeholder: true) { req, _ in
            _ = try req.objectBody(orEmpty: true)
            return .json(["created": 0, "message": "Keine offenen Vorlesungen oder Übungen für die Planung."])
        }
        router.post("/api/calendar/suggest", placeholder: true) { req, _ in
            _ = try req.objectBody(orEmpty: true)
            return .json(["moves": [], "message": "Keine offenen Aufgaben."])
        }
        router.post("/api/calendar/apply", placeholder: true) { req, _ in
            _ = try req.objectBody()
            return .json(["moved": 0])
        }

        router.get("/api/tasks/open", placeholder: true) { _, _ in .json([]) }
        router.post("/api/tasks/skip", placeholder: true) { req, _ in
            _ = try req.objectBody()
            return .ok
        }
        router.post("/api/tasks/{task_id:int}/status", placeholder: true) { req, _ in
            let st = try req.objectBody()["status"]?.string ?? ""
            guard ["geplant", "in_bearbeitung", "erledigt", "nachholen", "uebersprungen"].contains(st) else {
                throw LocalHTTPError(status: 400, message: "Ungültiger Status")
            }
            throw LocalHTTPError.notFound("Aufgabe nicht gefunden")
        }
        router.patch("/api/tasks/{task_id:int}", placeholder: true) { req, _ in
            _ = try req.objectBody()
            return .json(.null)
        }
        router.delete("/api/tasks/{task_id:int}", placeholder: true) { _, _ in .ok }

        router.post("/api/packages", placeholder: true) { req, _ in
            _ = try req.objectBody()
            throw LocalPending.notYet("Lernpakete anlegen")
        }
        router.get("/api/packages/{package_id:int}", placeholder: true) { _, _ in throw LocalHTTPError.notFound() }
        // Python scheitert beim Verschieben eines fehlenden Pakets mit 500 (ValueError); hier 404 mit Meldung
        router.patch("/api/packages/{package_id:int}", placeholder: true) { req, _ in
            let body = try req.objectBody()
            if body["date"].map(LocalPending.truthy) == true { throw LocalHTTPError.notFound("Paket nicht gefunden") }
            return .json(.null)
        }
        router.delete("/api/packages/{package_id:int}", placeholder: true) { _, _ in .ok }
        router.post("/api/packages/{package_id:int}/tasks", placeholder: true) { req, _ in
            _ = try req.objectBody()
            throw LocalHTTPError.notFound()
        }
    }
}
