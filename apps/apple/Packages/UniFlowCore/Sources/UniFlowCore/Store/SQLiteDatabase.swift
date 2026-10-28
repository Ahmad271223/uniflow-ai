import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// Lokale Datenbank des Geraets: dieselbe SQLite-Datei wie app/db.py auf dem PC, nur ohne Server.
// Drei Schichten: `SQLiteStatement` (vorbereiten, binden, schrittweise lesen), `SQLiteConnection` (eine Verbindung,
// synchron, nicht threadsicher) und der Actor `SQLiteDatabase`, der genau eine Verbindung besitzt und alle Zugriffe
// nacheinander ausfuehrt.

// MARK: - Werte und Zeilen

/// Ein Wert, wie SQLite ihn speichert (Speicherklassen INTEGER, REAL, TEXT, BLOB, NULL).
public enum SQLiteValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var int64: Int64? { if case .integer(let i) = self { return i }; return nil }
    public var int: Int? { int64.map { Int($0) } }
    /// REAL und INTEGER als Double (wie Python bei Rechnungen)
    public var double: Double? {
        switch self {
        case .real(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }
    public var string: String? { if case .text(let s) = self { return s }; return nil }
    public var data: Data? { if case .blob(let d) = self { return d }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Fuer die JSON-Antworten der /api/-Pfade: INTEGER -> ganze Zahl, REAL -> Zahl, TEXT, NULL. BLOB hat keine
    /// JSON-Form (nil) und steht getrennt in `SQLiteRow.blobs`.
    ///
    /// `JSONValue` speichert Zahlen als Double: ganze Zahlen ueber 2^53 waeren ungenau. Die Spalten von app/db.py
    /// (IDs, Unix-Zeiten, Minuten) bleiben weit darunter; wer exakt rechnen muss, liest `int64`.
    public var json: JSONValue? {
        switch self {
        case .null: return .null
        case .integer(let i): return .number(Double(i))
        case .real(let d): return .number(d)
        case .text(let s): return .string(s)
        case .blob: return nil
        }
    }

    /// Wert aus JSON zum Binden, wie Pythons sqlite3: Bool -> 1/0, ganze Zahl -> INTEGER, sonst REAL.
    /// Listen und Objekte haben keine SQLite-Form (nil); sie werden vorher als JSON-Text gespeichert.
    public init?(json: JSONValue) {
        switch json {
        case .null: self = .null
        case .bool(let b): self = .integer(b ? 1 : 0)
        case .number(let d):
            if d == d.rounded(), abs(d) < 9.0e15 { self = .integer(Int64(d)) } else { self = .real(d) }
        case .string(let s): self = .text(s)
        case .array, .object: return nil
        }
    }
}

extension SQLiteValue: ExpressibleByNilLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                       ExpressibleByStringLiteral, ExpressibleByBooleanLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .real(value) }
    public init(stringLiteral value: String) { self = .text(value) }
    public init(booleanLiteral value: Bool) { self = .integer(value ? 1 : 0) }
}

/// Bequemes Binden: `[.text(id), 3]` oder `SQLiteValue(optional)`.
extension SQLiteValue {
    public init(_ v: Int?) { self = v.map { .integer(Int64($0)) } ?? .null }
    public init(_ v: Int64?) { self = v.map { .integer($0) } ?? .null }
    public init(_ v: Double?) { self = v.map { .real($0) } ?? .null }
    public init(_ v: String?) { self = v.map { .text($0) } ?? .null }
    public init(_ v: Bool?) { self = v.map { .integer($0 ? 1 : 0) } ?? .null }
    public init(_ v: Data?) { self = v.map { .blob($0) } ?? .null }
}

/// Eine Ergebniszeile in Spaltenreihenfolge.
public struct SQLiteRow: Sendable, Equatable {
    public let columns: [String]
    public let values: [SQLiteValue]

    public init(columns: [String], values: [SQLiteValue]) {
        self.columns = columns
        self.values = values
    }

    /// Wert der ersten Spalte mit diesem Namen (wie `sqlite3.Row` in Python); nil, wenn es sie nicht gibt.
    public subscript(_ name: String) -> SQLiteValue? {
        columns.firstIndex(of: name).map { values[$0] }
    }

    public subscript(_ index: Int) -> SQLiteValue { values[index] }

    /// Zeile als JSON-Objekt wie `dict(row)` in app/db.py `rows()`; BLOB-Spalten fehlen hier (siehe `blobs`).
    /// Bei doppelten Spaltennamen gilt wie in Python die erste.
    public var json: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (i, name) in columns.enumerated() where out[name] == nil {
            if let v = values[i].json { out[name] = v }
        }
        return out
    }

    /// BLOB-Spalten getrennt als Data.
    public var blobs: [String: Data] {
        var out: [String: Data] = [:]
        for (i, name) in columns.enumerated() where out[name] == nil {
            if case .blob(let d) = values[i] { out[name] = d }
        }
        return out
    }
}

// MARK: - Fehler

/// Fehler mit Code und Meldung von SQLite (`sqlite3_errmsg`).
public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public enum Stage: String, Sendable {
        case open, prepare, bind, step, exec, transaction, closed
    }

    public let stage: Stage
    /// Primaerer Ergebniscode (SQLITE_CONSTRAINT = 19, SQLITE_BUSY = 5 ...)
    public let code: Int32
    /// Erweiterter Code (z. B. SQLITE_CONSTRAINT_UNIQUE = 2067)
    public let extendedCode: Int32
    public let message: String
    public let sql: String?

    public init(stage: Stage, code: Int32, extendedCode: Int32? = nil, message: String, sql: String? = nil) {
        self.stage = stage
        self.code = code & 0xFF
        self.extendedCode = extendedCode ?? code
        self.message = message
        self.sql = sql
    }

    public var isConstraint: Bool { code == SQLITE_CONSTRAINT }

    public var description: String {
        "SQLite-Fehler \(extendedCode) (\(stage.rawValue)): \(message)" + (sql.map { " – \($0.prefix(200))" } ?? "")
    }
}

/// SQLITE_TRANSIENT: SQLite kopiert gebundene Texte/BLOBs sofort (das Makro ist in Swift nicht verfuegbar).
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Anweisung

/// Vorbereitete Anweisung. Haelt ihre Verbindung; nach deren `close()` wirft jeder Aufruf.
public final class SQLiteStatement {
    private var handle: OpaquePointer?
    private let connection: SQLiteConnection
    public let sql: String
    /// Spaltennamen des Ergebnisses
    public let columns: [String]

    init(connection: SQLiteConnection, sql: String) throws {
        self.connection = connection
        self.sql = sql
        guard let db = connection.handle else { throw SQLiteError(stage: .closed, code: SQLITE_MISUSE, message: "Datenbank ist geschlossen", sql: sql) }
        var stmt: OpaquePointer?
        var restOffset = 0
        let rc: Int32 = sql.withCString { base in
            var tail: UnsafePointer<CChar>?
            let rc = sqlite3_prepare_v2(db, base, -1, &stmt, &tail)
            if let tail { restOffset = base.distance(to: tail) }        // Byte nach der ersten Anweisung
            return rc
        }
        guard rc == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw connection.error(.prepare, rc, sql: sql)
        }
        guard let stmt else {
            throw SQLiteError(stage: .prepare, code: SQLITE_MISUSE, message: "Leere Anweisung", sql: sql)
        }
        let bytes = Array(sql.utf8)
        if restOffset < bytes.count, SQLiteStatement.isStatement(String(decoding: bytes[restOffset...], as: UTF8.self)) {
            sqlite3_finalize(stmt)
            // wie Pythons execute(): mehrere Anweisungen nur ueber executeScript
            throw SQLiteError(stage: .prepare, code: SQLITE_MISUSE, message: "Nur eine Anweisung je Aufruf (mehrere: executeScript)", sql: sql)
        }
        handle = stmt
        columns = (0..<sqlite3_column_count(stmt)).map { String(cString: sqlite3_column_name(stmt, $0)) }
    }

    deinit { sqlite3_finalize(handle) }

    /// Enthaelt der Text mehr als Leerraum, Semikola und Kommentare?
    private static func isStatement(_ text: String) -> Bool {
        var rest = Substring(text)
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == ";" }
            if rest.hasPrefix("--") {
                rest = rest.drop { $0 != "\n" }
            } else if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return false }
                rest = rest[end.upperBound...]
            } else {
                return !rest.isEmpty
            }
        }
    }

    private var stmt: OpaquePointer {
        get throws {
            // nach close_v2 ist die Verbindung nur noch zum Aufraeumen da (SQLite: "zombie")
            guard let handle, connection.handle != nil else {
                throw SQLiteError(stage: .closed, code: SQLITE_MISUSE, message: "Datenbank ist geschlossen", sql: sql)
            }
            return handle
        }
    }

    /// Bindet die Werte an `?1 ... ?n` (vorher gebundene Werte werden geloescht).
    @discardableResult
    public func bind(_ values: [SQLiteValue]) throws -> SQLiteStatement {
        let stmt = try self.stmt
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        let expected = Int(sqlite3_bind_parameter_count(stmt))
        guard values.count == expected else {
            throw SQLiteError(stage: .bind, code: SQLITE_RANGE,
                              message: "\(expected) Parameter erwartet, \(values.count) übergeben", sql: sql)
        }
        for (i, v) in values.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch v {
            case .null: rc = sqlite3_bind_null(stmt, index)
            case .integer(let n): rc = sqlite3_bind_int64(stmt, index, n)
            case .real(let d): rc = sqlite3_bind_double(stmt, index, d)
            // Laengen als 64-Bit-Zahl (Pruefbericht 557): vorher `Int32(...)`, ab 2 GiB brach die App dort ab; jetzt
            // lehnt SQLite zu Grosses mit SQLITE_TOOBIG ab (Grenze SQLITE_LIMIT_LENGTH), der Fehler geht an den Aufrufer
            case .text(let s):
                // ausdrueckliche Laenge: auch Texte mit \0 bleiben vollstaendig, "" wird nicht zu NULL
                rc = s.withCString { sqlite3_bind_text64(stmt, index, $0, sqlite3_uint64(s.utf8.count), sqliteTransient, UInt8(SQLITE_UTF8)) }
            case .blob(let d):
                if d.isEmpty {
                    rc = sqlite3_bind_zeroblob(stmt, index, 0)     // leerer BLOB statt NULL
                } else {
                    rc = d.withUnsafeBytes { sqlite3_bind_blob64(stmt, index, $0.baseAddress, sqlite3_uint64($0.count), sqliteTransient) }
                }
            }
            guard rc == SQLITE_OK else { throw connection.error(.bind, rc, sql: sql) }
        }
        return self
    }

    /// Naechste Zeile oder nil, wenn die Anweisung fertig ist.
    public func next() throws -> SQLiteRow? {
        let stmt = try self.stmt
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:
            return SQLiteRow(columns: columns, values: (0..<Int32(columns.count)).map { SQLiteStatement.value(stmt, $0) })
        case SQLITE_DONE:
            return nil
        default:
            let err = connection.error(.step, rc, sql: sql)
            sqlite3_reset(stmt)
            throw err
        }
    }

    /// Fuehrt die Anweisung bis zum Ende aus (Zeilen werden verworfen).
    public func run() throws {
        while try next() != nil {}
    }

    /// Alle restlichen Zeilen
    public func all() throws -> [SQLiteRow] {
        var out: [SQLiteRow] = []
        while let r = try next() { out.append(r) }
        return out
    }

    /// Zuruecksetzen, damit die Anweisung mit denselben Werten erneut laeuft.
    public func reset() {
        if let handle { sqlite3_reset(handle) }
    }

    private static func value(_ stmt: OpaquePointer, _ i: Int32) -> SQLiteValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT:
            // erst der Zeiger, dann die Laenge (Reihenfolge laut SQLite-Doku)
            guard let p = sqlite3_column_text(stmt, i) else { return .text("") }
            let n = Int(sqlite3_column_bytes(stmt, i))
            return .text(String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self))
        case SQLITE_BLOB:
            let p = sqlite3_column_blob(stmt, i)
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard let p, n > 0 else { return .blob(Data()) }
            return .blob(Data(bytes: p, count: n))
        default:
            return .null
        }
    }
}

// MARK: - Verbindung

/// Eine SQLite-Verbindung mit synchronen Aufrufen. Nicht threadsicher und nicht `Sendable`: Zugriff nur ueber den
/// Actor `SQLiteDatabase` (oder in Tests direkt aus einem Thread).
public final class SQLiteConnection {
    fileprivate(set) var handle: OpaquePointer?
    public let path: String

    /// Datei (wird angelegt) oder ":memory:". Danach wie `app.db.connect()`: `journal_mode=WAL` und
    /// `foreign_keys=ON`; Wartezeit bei gesperrter Datei 5 s wie der Standard von Pythons `sqlite3.connect`.
    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Datenbank lässt sich nicht öffnen"
            sqlite3_close_v2(db)
            throw SQLiteError(stage: .open, code: rc, message: message, sql: path)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")       // bei ":memory:" bleibt es "memory"
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit { close() }

    public func close() {
        // close_v2: offene Anweisungen werden noch beendet, die Verbindung schliesst danach
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    func error(_ stage: SQLiteError.Stage, _ rc: Int32, sql: String?) -> SQLiteError {
        guard let handle else { return SQLiteError(stage: stage, code: rc, message: "Datenbank ist geschlossen", sql: sql) }
        return SQLiteError(stage: stage, code: rc, extendedCode: sqlite3_extended_errcode(handle),
                           message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(connection: self, sql: sql)
    }

    /// Eine Anweisung ausfuehren; Rueckgabe: Anzahl geaenderter Zeilen.
    @discardableResult
    public func execute(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        try prepare(sql).bind(params).run()
        return changes
    }

    /// Mehrere Anweisungen ohne Parameter (Schema), wie `executescript` in Python, aber ohne dessen COMMIT vorab:
    /// innerhalb einer Transaktion bleibt alles in ihr.
    public func executeScript(_ sql: String) throws {
        guard let handle else { throw SQLiteError(stage: .closed, code: SQLITE_MISUSE, message: "Datenbank ist geschlossen", sql: sql) }
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard rc == SQLITE_OK else {
            throw SQLiteError(stage: .exec, code: rc, extendedCode: sqlite3_extended_errcode(handle),
                              message: message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
    }

    public func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try prepare(sql).bind(params).all()
    }

    public func queryOne(_ sql: String, _ params: [SQLiteValue] = []) throws -> SQLiteRow? {
        try prepare(sql).bind(params).next()
    }

    /// Erste Spalte der ersten Zeile (nil ohne Ergebnis)
    public func scalar(_ sql: String, _ params: [SQLiteValue] = []) throws -> SQLiteValue? {
        try queryOne(sql, params)?.values.first
    }

    /// Zeilen als JSON-Objekte wie `db.rows()` in Python
    public func rows(_ sql: String, _ params: [SQLiteValue] = []) throws -> [[String: JSONValue]] {
        try query(sql, params).map(\.json)
    }

    public var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }
    public var changes: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }
    /// Laeuft gerade eine Transaktion (kein Autocommit)?
    public var isInTransaction: Bool { handle.map { sqlite3_get_autocommit($0) == 0 } ?? false }

    /// Spaltennamen einer Tabelle (`PRAGMA table_info`), leer, wenn es die Tabelle nicht gibt.
    public func columnNames(_ table: String) throws -> [String] {
        try query("PRAGMA table_info(\(SQLiteConnection.quote(table)))").compactMap { $0["name"]?.string }
    }

    /// Bezeichner in doppelten Anfuehrungszeichen (Tabellen-/Spaltennamen lassen sich nicht binden).
    public static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `BEGIN IMMEDIATE` ... `COMMIT`; wirft `body`, wird alles zurueckgerollt und der Fehler weitergegeben.
    /// Verschachteln ist nicht vorgesehen (Fehler), damit ein inneres COMMIT nie die aeussere Transaktion beendet.
    @discardableResult
    public func transaction<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        guard !isInTransaction else {
            throw SQLiteError(stage: .transaction, code: SQLITE_MISUSE, message: "Transaktion läuft bereits")
        }
        // IMMEDIATE: die Schreibsperre gleich zu Beginn holen, statt beim ersten Schreiben an SQLITE_BUSY zu scheitern
        try execute("BEGIN IMMEDIATE")
        let result: T
        do {
            result = try body(self)
        } catch {
            rollbackQuietly()
            throw error
        }
        do {
            try execute("COMMIT")
        } catch {
            rollbackQuietly()
            throw error
        }
        return result
    }

    private func rollbackQuietly() {
        // SQLite kann eine Transaktion nach manchen Fehlern schon selbst beendet haben
        if isInTransaction { _ = try? execute("ROLLBACK") }
    }
}

// MARK: - Actor

/// Die lokale Datenbank: genau eine Verbindung, alle Zugriffe nacheinander.
///
/// Transaktionen nehmen bewusst eine **synchrone** Closure: Actors sind reentrant. Liefe zwischen `BEGIN IMMEDIATE`
/// und `COMMIT` ein `await`, gaebe der Actor die Verbindung frei, und ein anderer Aufruf (etwa ein `execute` aus
/// einer anderen Aufgabe) liefe mitten in dieser Transaktion – seine Aenderungen wuerden mit ihr bestaetigt oder
/// zurueckgerollt, oder sein eigenes BEGIN scheiterte. Ohne `await` laeuft die Transaktion am Stueck. Netzwerk und
/// Dateien werden darum vorher geladen und erst danach in einer Transaktion geschrieben.
public actor SQLiteDatabase {
    public static let inMemory = ":memory:"

    private let connection: SQLiteConnection
    public nonisolated let path: String

    /// Datei (wird angelegt) oder `SQLiteDatabase.inMemory`.
    public init(path: String) throws {
        connection = try SQLiteConnection(path: path)
        self.path = path
    }

    @discardableResult
    public func execute(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        try connection.execute(sql, params)
    }

    public func executeScript(_ sql: String) throws {
        try connection.executeScript(sql)
    }

    public func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try connection.query(sql, params)
    }

    public func queryOne(_ sql: String, _ params: [SQLiteValue] = []) throws -> SQLiteRow? {
        try connection.queryOne(sql, params)
    }

    public func scalar(_ sql: String, _ params: [SQLiteValue] = []) throws -> SQLiteValue? {
        try connection.scalar(sql, params)
    }

    public func rows(_ sql: String, _ params: [SQLiteValue] = []) throws -> [[String: JSONValue]] {
        try connection.rows(sql, params)
    }

    public var lastInsertRowID: Int64 { connection.lastInsertRowID }

    /// Schreibende Transaktion (BEGIN IMMEDIATE ... COMMIT, bei Fehler ROLLBACK). Synchron, siehe oben.
    /// Die Verbindung darf die Closure nicht verlassen.
    @discardableResult
    public func transaction<T: Sendable>(_ body: @Sendable (SQLiteConnection) throws -> T) throws -> T {
        try connection.transaction(body)
    }

    /// Mehrere Lesezugriffe am Stueck ohne Transaktion (z. B. schrittweise mit `prepare`/`next`).
    @discardableResult
    public func withConnection<T: Sendable>(_ body: @Sendable (SQLiteConnection) throws -> T) throws -> T {
        try body(connection)
    }
}
