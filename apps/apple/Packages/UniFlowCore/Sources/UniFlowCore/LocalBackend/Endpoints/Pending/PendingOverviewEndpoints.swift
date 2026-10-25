import Foundation

/// Platzhalter: Uebersicht, Hintergrundaufgabe, Suche (S6, S7). Neue Dateien und letzter Abgleich in der Uebersicht
/// sind seit S3 echt.
enum PendingOverviewEndpoints: LocalEndpointModule {
    static let name = "Übersicht (Platzhalter)"

    static func register(on router: LocalRouter) {
        // study.dashboard ohne Lernpakete, Termine und Module (S6): heute, Woche ab Montag; freie Fenster von heute
        // aus den Einstellungen; neue Dateien und letzter Abgleich schon aus der Datenbank (S3)
        router.get("/api/dashboard", placeholder: true) { _, ctx in
            let s = try await LocalPending.settings(ctx)
            let t = LocalPending.today(ctx)
            var today = LocalPending.calendarDay(t, settings: s)
            today["free"] = .array(try LocalFreeWindows.compute(day: t, settings: s))
            let monday = t - LocalPending.weekday(t)
            let days: [JSONValue] = (0..<7).map { i in
                ["date": .string(LocalPending.iso(monday + i)), "status": .string(LocalPending.emptyStatus(monday + i, settings: s)), "minutes": 0]
            }
            // wie study.dashboard zuerst ensure_modules (Modul der neuen Dateien), darum in einer Transaktion
            let clock = ctx.clock
            let (newFiles, lastSync) = try await ctx.database.transaction { c in
                try LocalModules.ensureModules(c, clock: clock)
                return (try LocalLibrary.newFiles(c), try LocalLibrary.lastSync(c))
            }
            return .json(["today": today, "modules": [], "new_files": .array(Array(newFiles.prefix(50))), "new_total": .number(Double(newFiles.count)),
                          "week": ["start": .string(LocalPending.iso(monday)), "done": 0, "total": 0, "days": .array(days)],
                          "backlog": 0, "upcoming": [], "last_sync": lastSync,
                          "settings": .object(LocalSettings.publicSettings(s)), "bg": LocalPending.bg])
        }

        router.get("/api/bg", placeholder: true) { _, _ in .json(LocalPending.bg) }

        // Abgleich mit Stud.IP laeuft auf dem iPad direkt (StudIPSync), nicht ueber diesen Pfad
        router.post("/api/sync", placeholder: true) { _, _ in
            throw LocalHTTPError(status: 409, message: "Auf diesem iPad gleicht UniFlow Stud.IP direkt ab.")
        }

        router.get("/api/search", placeholder: true) { req, _ in
            _ = try req.requiredQuery("q")
            return .json(["files": [], "modules": []])
        }
    }
}
