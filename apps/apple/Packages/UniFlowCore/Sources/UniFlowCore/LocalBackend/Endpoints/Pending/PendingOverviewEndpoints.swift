import Foundation

/// Platzhalter: Uebersicht, Hintergrundaufgabe, Sync-Status, Suche (S3, S6, S7).
enum PendingOverviewEndpoints: LocalEndpointModule {
    static let name = "Übersicht (Platzhalter)"

    static func register(on router: LocalRouter) {
        // study.dashboard bei leerer Datenbank: heute, Woche ab Montag, keine Pakete, Termine, Dateien; freie
        // Fenster von heute schon aus den Einstellungen
        router.get("/api/dashboard", placeholder: true) { _, ctx in
            let s = try await LocalPending.settings(ctx)
            let t = LocalPending.today(ctx)
            var today = LocalPending.calendarDay(t, settings: s)
            today["free"] = .array(try LocalFreeWindows.compute(day: t, settings: s))
            let monday = t - LocalPending.weekday(t)
            let days: [JSONValue] = (0..<7).map { i in
                ["date": .string(LocalPending.iso(monday + i)), "status": .string(LocalPending.emptyStatus(monday + i, settings: s)), "minutes": 0]
            }
            return .json(["today": today, "modules": [], "new_files": [], "new_total": 0,
                          "week": ["start": .string(LocalPending.iso(monday)), "done": 0, "total": 0, "days": .array(days)],
                          "backlog": 0, "upcoming": [], "last_sync": .null,
                          "settings": .object(LocalSettings.publicSettings(s)), "bg": LocalPending.bg])
        }

        router.get("/api/bg", placeholder: true) { _, _ in .json(LocalPending.bg) }

        router.get("/api/sync/status", placeholder: true) { _, _ in .json(["bg": LocalPending.bg, "log": []]) }

        // Abgleich mit Stud.IP laeuft auf dem iPad direkt (StudIPSync), nicht ueber diesen Pfad
        router.post("/api/sync", placeholder: true) { _, _ in
            throw LocalHTTPError(status: 409, message: "Auf diesem iPad gleicht UniFlow Stud.IP direkt ab.")
        }

        router.get("/api/search", placeholder: true) { req, _ in
            _ = try req.requiredQuery("q")
            return .json(["files": [], "modules": []])
        }

        router.post("/api/files/mark-seen", placeholder: true) { _, _ in .ok }
    }
}
