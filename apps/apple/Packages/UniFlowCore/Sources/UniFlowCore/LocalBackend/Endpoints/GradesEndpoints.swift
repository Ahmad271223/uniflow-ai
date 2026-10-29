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
    }

    /// `qis.summary(conn)`: Zeilen wie `SELECT * FROM grades ORDER BY id`
    static func summary(_ c: SQLiteConnection) throws -> JSONValue {
        var out = GradesModel.summary(try c.rows("SELECT * FROM grades ORDER BY id"))
        out["last_run"] = try c.queryOne("SELECT * FROM qis_runs ORDER BY id DESC LIMIT 1").map { .object($0.json) } ?? .null
        out["documents"] = .array(try c.rows("SELECT * FROM qis_documents ORDER BY id DESC").map(JSONValue.object))
        return .object(out)
    }
}
