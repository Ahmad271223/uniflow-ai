import Foundation

/// `GET /api/grades` wie `api_grades` in app/server.py (`qis.summary`): die Leistungen der Tabelle `grades`, Durchschnitt
/// nach Credits, Summe der Credits und Zahl der bestandenen Leistungen (eine Rechnung fuer beide Wege:
/// `QISParser.summary`), dazu der letzte Abruf (`qis_runs`) und die Bescheinigungen (`qis_documents`).
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

    /// `qis.summary(conn)`: Zeilen wie `SELECT * FROM grades ORDER BY semester DESC, text`
    static func summary(_ c: SQLiteConnection) throws -> JSONValue {
        let rows = try c.rows("SELECT * FROM grades ORDER BY semester DESC, text")
        let grades = rows.map { r in
            QISGrade(pruefungsnr: r["pruefungsnr"]?.string, text: r["text"]?.string ?? "", semester: r["semester"]?.string,
                     note: r["note"]?.string, status: r["status"]?.string, credits: r["credits"]?.string,
                     versuch: r["versuch"]?.string, datum: r["datum"]?.string, abschluss: r["abschluss"]?.string,
                     raw: r["raw"]?.string ?? "")
        }
        let s = QISParser.summary(grades)
        let last = try c.queryOne("SELECT * FROM qis_runs ORDER BY id DESC LIMIT 1")
        let documents = try c.rows("SELECT * FROM qis_documents ORDER BY id DESC")
        return ["grades": .array(rows.map(JSONValue.object)), "average": s.average.map(JSONValue.number) ?? .null,
                "credits": .number(s.credits), "passed": .number(Double(s.passed)),
                "last_run": last.map { .object($0.json) } ?? .null, "documents": .array(documents.map(JSONValue.object))]
    }
}
