import Foundation

/// Lokale Tabellen des Modulkatalogs in der Datenbank des Containers, gleich wie in app/study_catalog.py (`SCHEMA`).
/// Erst bei Bedarf angelegt (wie `due_hits`): das Schema der Python-Referenz (app/db.py, Schema-Fixture) bleibt
/// unveraendert, jede Funktion legt die Tabellen selbst an bzw. liest ohne sie nichts.
/// - `study_catalogs`: je Bibliotheksschluessel die geteilten Fakten (`payload`, study-catalog.schema.json), Herkunft
///   (download | seed | library | fixture), Quelle. Liest der Plan (LocalBackend/StudyPlan, app/study_plan.py).
/// - `study_module_texts`: Inhalt, Lernziele, Literatur je Modul - nur auf dem Geraet, nie in der Bibliothek.
/// - `study_catalog_state`: Stand der Suche (`status`), Fehlversuche je Schluessel (`attempt:<key>`), ETag je URL
///   (`http:<url>`), fehlende Semester (`missing:<url>`).
public enum StudyCatalogStore {
    public static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS study_catalogs (
            catalog_key TEXT PRIMARY KEY,          -- sha256("luh|TIBSc22|WS 2025/26")
            university TEXT NOT NULL,
            code TEXT NOT NULL,
            catalog_term TEXT NOT NULL,
            program TEXT,
            po TEXT,
            payload TEXT NOT NULL,                 -- geteilte Fakten (study-catalog.schema.json)
            origin TEXT NOT NULL,                  -- download | seed | library | fixture
            source_url TEXT,
            sha256 TEXT,
            fetched_at TEXT,
            stored_at TEXT
        );
        CREATE TABLE IF NOT EXISTS study_module_texts (
            catalog_key TEXT NOT NULL,
            module_id TEXT NOT NULL,
            content TEXT,
            goals TEXT,
            literature TEXT,
            PRIMARY KEY (catalog_key, module_id)
        );
        CREATE TABLE IF NOT EXISTS study_catalog_state (key TEXT PRIMARY KEY, value TEXT);
        """

    public static func ensureTables(_ c: SQLiteConnection) throws { try c.executeScript(schemaSQL) }

    static func hasTables(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='study_catalogs'") != nil
    }

    /// Schluessel eines Katalogs (aus university, code, catalog_term)
    public static func key(of catalog: JSONValue) -> String {
        StudyCatalogText.libraryKey(university: catalog["university"]?.string ?? "", code: catalog["code"]?.string ?? "",
                                    term: catalog["catalog_term"]?.string ?? "")
    }

    /// Katalog speichern (gleicher Schluessel: ersetzt; Texte nur, wenn welche mitkommen). `payload` ist der Text der
    /// geteilten Fakten, so wie er gespeichert wird.
    @discardableResult
    public static func store(_ c: SQLiteConnection, payload: String, texts: JSONValue?, origin: String, now: String) throws -> String {
        try ensureTables(c)
        let catalog = try JSONValue.parse(payload)
        let key = key(of: catalog)
        func t(_ v: JSONValue?) -> SQLiteValue { v?.string.map { .text($0) } ?? .null }
        let src = catalog["source"]
        try c.execute("""
            INSERT OR REPLACE INTO study_catalogs(catalog_key, university, code, catalog_term, program, po, payload, origin, source_url,
            sha256, fetched_at, stored_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(key), t(catalog["university"]), .text(catalog["code"]?.string ?? ""), t(catalog["catalog_term"]), t(catalog["program"]),
                  t(catalog["po"]), .text(payload), .text(origin), t(src?["url"]), t(src?["sha256"]), t(src?["fetched_at"]), .text(now)])
        if let texts = texts?.object, !texts.isEmpty {
            try c.execute("DELETE FROM study_module_texts WHERE catalog_key=?", [.text(key)])
            for (id, v) in texts.sorted(by: { $0.key < $1.key }) {
                try c.execute("INSERT INTO study_module_texts(catalog_key, module_id, content, goals, literature) VALUES (?,?,?,?,?)",
                              [.text(key), .text(id), t(v["content"]), t(v["goals"]), t(v["literature"])])
            }
        }
        return key
    }

    /// Gespeicherter Katalog zum Schluessel
    public static func catalog(_ c: SQLiteConnection, key: String) throws -> JSONValue? {
        guard try hasTables(c), let r = try c.queryOne("SELECT payload FROM study_catalogs WHERE catalog_key=?", [.text(key)]),
              let p = r["payload"]?.string else { return nil }
        return try? JSONValue.parse(p)
    }

    /// Gespeicherter Text der Fakten und Herkunft zum Schluessel (zum Ergaenzen um den Studienverlaufsplan)
    public static func payload(_ c: SQLiteConnection, key: String) throws -> (payload: String, origin: String)? {
        guard try hasTables(c), let r = try c.queryOne("SELECT payload, origin FROM study_catalogs WHERE catalog_key=?", [.text(key)]),
              let p = r["payload"]?.string else { return nil }
        return (p, r["origin"]?.string ?? "download")
    }

    /// Modultexte eines gespeicherten Katalogs ablegen (ersetzt die bisherigen), ohne die Fakten anzufassen
    public static func storeTexts(_ c: SQLiteConnection, key: String, texts: [String: JSONValue]) throws {
        try ensureTables(c)
        func t(_ v: JSONValue?) -> SQLiteValue { v?.string.map { .text($0) } ?? .null }
        try c.execute("DELETE FROM study_module_texts WHERE catalog_key=?", [.text(key)])
        for (id, v) in texts.sorted(by: { $0.key < $1.key }) {
            try c.execute("INSERT INTO study_module_texts(catalog_key, module_id, content, goals, literature) VALUES (?,?,?,?,?)",
                          [.text(key), .text(id), t(v["content"]), t(v["goals"]), t(v["literature"])])
        }
    }

    /// Zahl der lokalen Modultexte eines Katalogs
    public static func textCount(_ c: SQLiteConnection, key: String) throws -> Int {
        guard try hasTables(c) else { return 0 }
        return try c.queryOne("SELECT COUNT(*) AS n FROM study_module_texts WHERE catalog_key=?", [.text(key)])?["n"]?.int ?? 0
    }

    /// Lokaler Text eines Moduls
    public static func moduleText(_ c: SQLiteConnection, key: String, moduleID: String) throws -> JSONValue? {
        guard try hasTables(c),
              let r = try c.queryOne("SELECT content, goals, literature FROM study_module_texts WHERE catalog_key=? AND module_id=?",
                                     [.text(key), .text(moduleID)]) else { return nil }
        return .object(["content": r["content"]?.json ?? .null, "goals": r["goals"]?.json ?? .null, "literature": r["literature"]?.json ?? .null])
    }

    public static func state(_ c: SQLiteConnection, _ key: String) throws -> JSONValue? {
        guard try hasTables(c), let r = try c.queryOne("SELECT value FROM study_catalog_state WHERE key=?", [.text(key)]),
              let v = r["value"]?.string else { return nil }
        return try? JSONValue.parse(v)
    }

    public static func setState(_ c: SQLiteConnection, _ key: String, _ value: JSONValue) throws {
        try ensureTables(c)
        try c.execute("INSERT OR REPLACE INTO study_catalog_state(key, value) VALUES (?, ?)", [.text(key), .text(value.jsonString(sortedKeys: true))])
    }

    /// GET /api/study-catalog/status: letzter Stand; ohne Lauf "idle" oder "ready", wenn schon ein Katalog da ist
    public static func status(_ c: SQLiteConnection) throws -> JSONValue {
        if let s = try state(c, "status"), s.object != nil { return s }
        if try hasTables(c), try c.queryOne("SELECT 1 FROM study_catalogs LIMIT 1") != nil {
            return ["state": "ready", "origin": "local", "message": .string(StudyCatalogPipeline.messages["ready"]!)]
        }
        return ["state": "idle", "message": "Der Modulkatalog wurde noch nicht gesucht."]
    }
}

/// `GET /api/study-catalog/status` (gleich app/study_catalog.py): Stand der Katalogsuche fuer die Seite Studienverlauf
/// {state: idle|searching|downloading|parsing|ready|seed|library|not_found|error, message, program, po, code, catalog_term,
/// origin, modules, needs_confirmation, suggested_po, retry_at, error}
public enum StudyCatalogEndpoints: LocalEndpointModule {
    public static let name = "Modulkatalog"

    public static func register(on router: LocalRouter) {
        router.get("/api/study-catalog/status") { _, ctx in
            let (status, inputs, hasRun) = try await ctx.database.transaction { c in
                (try StudyCatalogStore.status(c), try StudyCatalogPipeline.inputs(c), try StudyCatalogStore.state(c, "status") != nil)
            }
            // noch nie gesucht oder Eingaben geaendert (QIS, PO, eigener Link): Suche im Hintergrund anstossen
            // (ein Zwischenstand aelter als 10 Minuten gilt als abgebrochen, etwa wenn die App beendet wurde)
            let started = StudyCatalogPipeline.date(status["checked_at"]?.string)
            let busy = ["searching", "downloading", "parsing"].contains(status["state"]?.string ?? "")
                && (started.map { ctx.clock.now.timeIntervalSince($0) < 600 } ?? false)
            let settled = ["ready", "library", "seed", "error", "not_found", "idle"].contains(status["state"]?.string ?? "")
            let retryDue = status["state"]?.string == "error"
                && (StudyCatalogPipeline.date(status["retry_at"]?.string).map { $0 <= ctx.clock.now } ?? false)
            if !busy, !hasRun || !settled || retryDue || status["inputs"]?.string != inputs, StudyCatalogTriggers.fire(databasePath: ctx.database.path) {
                var s = status.object ?? [:]
                s["state"] = "searching"
                s["message"] = .string(StudyCatalogPipeline.messages["searching"]!)
                return .json(.object(s))
            }
            return .json(status)
        }
    }
}
