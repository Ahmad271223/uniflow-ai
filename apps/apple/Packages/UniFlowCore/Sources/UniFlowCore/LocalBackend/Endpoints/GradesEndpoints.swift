import Foundation

/// `GET /api/grades` wie `api_grades` in app/server.py (`qis.summary`, seit 28.10.2026 mit app/grades_model.py): die
/// bereinigten Leistungen der Tabelle `grades` mit Ebene (Bereich, Modul, Pruefung), aktueller Schnitt (abgeschnitten
/// und genau), LP, Bereiche und nicht bestandene Versuche (`GradesModel`), dazu der letzte Abruf (`qis_runs`) und die
/// Bescheinigungen (`qis_documents`).
///
/// Auf dem iPad fuellt die Tabelle der LSF-Notenspiegel der Uni Hildesheim (`HildesheimSync`, nur die
/// Leistungstabelle; Stammdaten stehen nie in der Datenbank). An der LUH bleibt sie leer, bis QIS auf dem Geraet kommt
/// (Abruf `POST /api/grades/sync` weiter als Platzhalter in `PendingServicesEndpoints`).
enum GradesEndpoints: LocalEndpointModule {
    static let name = "Noten"

    static func register(on router: LocalRouter) {
        router.get("/api/grades") { _, ctx in
            .json(try await ctx.database.withConnection { try summary($0) })
        }
        // Selbst eingetragene Leistungen (20.11.2026, `GradesManual`, wie app/server.py): abhaken und Note eintragen,
        // wenn QIS ein Modul nicht als bestanden meldet; nur auf dem Geraet
        router.get("/api/grades/manual") { _, ctx in
            .json(try await ctx.database.withConnection { c in
                let entries = GradesManual.resolve(try StudyPlanAPI.gradeRows(c), try GradesManual.load(c))
                let lp = entries.filter { $0["counted"]?.bool == true }.reduce(0.0) { $0 + ($1["lp"]?.double ?? 0) }
                return ["entries": .array(entries.map(JSONValue.object)), "credits_manual": .number(GradesModel.round1(lp))]
            })
        }
        router.post("/api/grades/manual") { req, ctx in
            let body = try req.objectBody(), now = ctx.clock.nowISO
            return .json(try await ctx.database.transaction { c in
                let e = try GradesManual.save(c, body: body, now: now)
                let entry = GradesManual.resolve(try StudyPlanAPI.gradeRows(c), [e])[0]
                return ["ok": true, "entry": .object(entry)]
            })
        }
        router.delete("/api/grades/manual/{entry_id:int}") { req, ctx in
            let id = req.intParam("entry_id")
            let gone = try await ctx.database.transaction { try GradesManual.delete($0, id: id) }
            if !gone { throw LocalHTTPError.notFound("Eintrag unbekannt.") }
            return .ok
        }
    }

    /// `qis.summary(conn)`: Zeilen wie `SELECT * FROM grades ORDER BY id`
    static func summary(_ c: SQLiteConnection) throws -> JSONValue {
        // selbst eingetragene Leistungen (20.11.2026) zaehlen mit, QIS geht vor (`GradesManual`)
        var out = GradesModel.summary(try c.rows("SELECT * FROM grades ORDER BY id"), manual: try GradesManual.load(c))
        out["last_run"] = try c.queryOne("SELECT * FROM qis_runs ORDER BY id DESC LIMIT 1").map { .object($0.json) } ?? .null
        out["documents"] = .array(try c.rows("SELECT * FROM qis_documents ORDER BY id DESC").map(JSONValue.object))
        return .object(out)
    }
}
