import Foundation

/// Zwischenspeicher des Erklaerungsspeichers im Container (`page_explain`, nur auf dem Geraet, erst bei Bedarf angelegt
/// wie `page_index`): je Datei-SHA, Seite, Modus und Variante der Text der Antwort. Variante 0 = nur lokal (kein Platz
/// frei oder kein Dienst). Nie Seitentext, nie Namen.
enum PageExplainStore {
    static let tableSQL = """
        CREATE TABLE IF NOT EXISTS page_explain (
            file_sha TEXT NOT NULL,
            page INTEGER NOT NULL,
            mode TEXT NOT NULL,
            variant INTEGER NOT NULL,          -- 1..3 beim Dienst, 0 = nur lokal
            text TEXT NOT NULL,
            source TEXT NOT NULL,              -- ai (selbst gefragt) | cloud (uebernommen)
            shared INTEGER NOT NULL DEFAULT 0, -- 1 = beim Dienst gespeichert
            model TEXT,
            created_at TEXT NOT NULL,
            PRIMARY KEY (file_sha, page, mode, variant))
        """

    struct Row: Equatable, Sendable {
        var fileSHA: String
        var page: Int
        var mode: String
        var variant: Int
        var text: String
        var source: String
        var shared: Bool
        var model: String?
        var createdAt: String

        var entry: PageExplain.LocalEntry { PageExplain.LocalEntry(variant: variant, source: source, createdAt: createdAt) }
    }

    static func ensureTable(_ c: SQLiteConnection) throws { try c.executeScript(tableSQL) }

    static func hasTable(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='page_explain'") != nil
    }

    private static func row(_ r: SQLiteRow) -> Row {
        Row(fileSHA: r["file_sha"]?.string ?? "", page: r["page"]?.int ?? 0, mode: r["mode"]?.string ?? "", variant: r["variant"]?.int ?? 0,
            text: r["text"]?.string ?? "", source: r["source"]?.string ?? "", shared: (r["shared"]?.int ?? 0) != 0, model: r["model"]?.string,
            createdAt: r["created_at"]?.string ?? "")
    }

    /// Antworten einer Seite in einem Modus, zuletzt gespeicherte zuerst (fuer `PageExplain.choose`)
    static func rows(_ c: SQLiteConnection, fileSHA: String, page: Int, mode: String) throws -> [Row] {
        guard try hasTable(c) else { return [] }
        return try c.query("SELECT * FROM page_explain WHERE file_sha=? AND page=? AND mode=? ORDER BY rowid DESC",
                           [.text(fileSHA), .integer(Int64(page)), .text(mode)]).map(row)
    }

    /// Alle (Seite, Modus) einer Datei mit Antwort (fuer den Plan des Vorwaermens)
    static func have(_ c: SQLiteConnection, fileSHA: String) throws -> Set<PageExplain.PlanItem> {
        guard try hasTable(c) else { return [] }
        return Set(try c.query("SELECT DISTINCT page, mode FROM page_explain WHERE file_sha=?", [.text(fileSHA)]).map {
            PageExplain.PlanItem(page: $0["page"]?.int ?? 0, mode: $0["mode"]?.string ?? "")
        })
    }

    static func store(_ c: SQLiteConnection, fileSHA: String, page: Int, mode: String, variant: Int, text: String, source: String, shared: Bool,
                      model: String?, now: String) throws {
        try ensureTable(c)
        try c.execute("""
            INSERT OR REPLACE INTO page_explain(file_sha, page, mode, variant, text, source, shared, model, created_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            """, [.text(fileSHA), .integer(Int64(page)), .text(mode), .integer(Int64(variant)), .text(text), .text(source),
                  .integer(shared ? 1 : 0), model.map(SQLiteValue.text) ?? .null, .text(now)])
    }

    /// Zahlen fuer `GET /api/index/status`: Antworten insgesamt, davon beim Dienst
    static func counts(_ c: SQLiteConnection) throws -> (answers: Int, shared: Int) {
        guard try hasTable(c) else { return (0, 0) }
        return (try c.scalar("SELECT COUNT(*) FROM page_explain")?.int ?? 0,
                try c.scalar("SELECT COUNT(*) FROM page_explain WHERE shared=1")?.int ?? 0)
    }
}
