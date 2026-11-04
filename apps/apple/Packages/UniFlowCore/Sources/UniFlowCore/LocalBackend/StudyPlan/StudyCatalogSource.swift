import Foundation

/// Woher der Studienverlauf seine Kataloge liest. Im Geraet die lokalen Tabellen des Katalog-Abrufs
/// (`DatabaseStudyCatalogSource`), in Tests ein Katalog aus dem Speicher (`MemoryStudyCatalogSource`).
/// Gleiche Regeln wie `MemoryCatalogSource`/`DbCatalogSource` in app/study_plan.py.
public protocol StudyCatalogSource {
    /// Alle gueltigen Kataloge (JSON wie study-catalog.schema.json), in der Reihenfolge der Ablage
    func catalogs() throws -> [JSONValue]
    /// Lokaler Modultext `{content, goals, literature}` oder nil
    func moduleText(catalog: JSONValue, moduleID: String) throws -> JSONValue?
}

/// Kataloge und Modultexte aus dem Speicher (Tests, Fixtures)
public struct MemoryStudyCatalogSource: StudyCatalogSource {
    public var items: [JSONValue]
    /// {Bibliotheksschluessel: {Modul-id: {content, goals, literature}}}
    public var texts: [String: [String: JSONValue]]

    public init(catalogs: [JSONValue], texts: [String: [String: JSONValue]] = [:]) {
        self.items = catalogs
        self.texts = texts
    }

    public func catalogs() throws -> [JSONValue] { items.filter(StudyPlanEngine.validCatalog) }

    public func moduleText(catalog: JSONValue, moduleID: String) throws -> JSONValue? {
        texts[StudyPlanEngine.catalogKey(catalog)]?[moduleID]
    }
}

/// Kataloge aus den lokalen Tabellen `study_catalogs` und `study_module_texts`. Die Spalten werden gelesen, nicht
/// vorausgesetzt: Katalog-JSON in `payload` (sonst catalog/json/data), Texte je `module_id`, wenn vorhanden mit
/// `catalog_key` (sonst `code`). Ohne Tabelle: keine Kataloge.
public struct DatabaseStudyCatalogSource: StudyCatalogSource {
    let connection: SQLiteConnection
    static let payloadColumns = ["payload", "catalog", "json", "data"]

    public init(_ connection: SQLiteConnection) { self.connection = connection }

    private func columns(_ table: String) throws -> [String] {
        guard try connection.queryOne("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [.text(table)]) != nil else { return [] }
        return try connection.rows("PRAGMA table_info(\(table))").compactMap { $0["name"]?.string }
    }

    public func catalogs() throws -> [JSONValue] {
        let cols = try columns("study_catalogs")
        guard let col = Self.payloadColumns.first(where: cols.contains) else { return [] }
        var out: [JSONValue] = []
        for r in try connection.rows("SELECT \(col) AS p FROM study_catalogs ORDER BY rowid") {
            guard let p = r["p"]?.string, let c = try? JSONValue.parse(Data(p.utf8)), StudyPlanEngine.validCatalog(c) else { continue }
            out.append(c)
        }
        return out
    }

    public func moduleText(catalog: JSONValue, moduleID: String) throws -> JSONValue? {
        let cols = try columns("study_module_texts")
        guard cols.contains("module_id") else { return nil }
        var sql = "SELECT * FROM study_module_texts WHERE module_id=?"
        var params: [SQLiteValue] = [.text(moduleID)]
        if cols.contains("catalog_key") {
            sql += " AND catalog_key=?"
            params.append(.text(StudyPlanEngine.catalogKey(catalog)))
        } else if cols.contains("code") {
            sql += " AND code=?"
            params.append(.text(StudyPlanEngine.textOf(catalog["code"])))
        }
        guard let r = try connection.rows(sql + " ORDER BY rowid DESC LIMIT 1", params).first else { return nil }
        var o: [String: JSONValue] = [:]
        for k in ["content", "goals", "literature"] { o[k] = r[k]?.string.map(JSONValue.string) ?? .null }
        return .object(o)
    }
}
