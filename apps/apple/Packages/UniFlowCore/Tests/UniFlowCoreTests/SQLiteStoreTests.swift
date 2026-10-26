import Foundation
import XCTest
@testable import UniFlowCore

/// Lokale Datenbank: Verbindung, Typen, Transaktionen und Schema-Gleichheit mit app/db.py
/// (Fixtures aus tools/gen-schema-fixture.py).
final class SQLiteStoreTests: XCTestCase {

    private struct Boom: Error {}

    private let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!

    private func repoFile(_ relative: String) throws -> Data {
        // .../apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/SQLiteStoreTests.swift -> Repository-Wurzel
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private func fixture(_ name: String) throws -> JSONValue {
        try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/schema/\(name)"))
    }

    private func tempPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("lernapp.db").path
    }

    // MARK: - Schema-Beschreibung wie snapshot() in tools/gen-schema-fixture.py

    private func json(_ v: SQLiteValue?) -> JSONValue { v?.json ?? .null }

    private func snapshot(_ c: SQLiteConnection) throws -> JSONValue {
        var tables: [String: JSONValue] = [:]
        let names = try c.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .compactMap { $0[0].string }
        for name in names {
            let q = SQLiteConnection.quote(name)
            let columns: [JSONValue] = try c.query("PRAGMA table_info(\(q))").map { r in
                ["name": json(r["name"]), "type": json(r["type"]), "notnull": json(r["notnull"]),
                 "default": json(r["dflt_value"]), "pk": json(r["pk"])]
            }
            let fks: [JSONValue] = try c.query("PRAGMA foreign_key_list(\(q))").map { r -> JSONValue in
                ["table": json(r["table"]), "from": json(r["from"]), "to": json(r["to"]),
                 "on_update": json(r["on_update"]), "on_delete": json(r["on_delete"])]
            }.sorted { a, b in
                let ka = [a["from"]?.string ?? "", a["table"]?.string ?? "", a["to"]?.string ?? ""]
                let kb = [b["from"]?.string ?? "", b["table"]?.string ?? "", b["to"]?.string ?? ""]
                return ka.lexicographicallyPrecedes(kb)
            }
            var indexes: [JSONValue] = []
            for r in try c.query("PRAGMA index_list(\(q))") {
                let iname = r["name"]?.string ?? ""
                let cols = try c.query("PRAGMA index_info(\(SQLiteConnection.quote(iname)))").map { json($0["name"]) }
                indexes.append(["name": .string(iname), "unique": json(r["unique"]), "origin": json(r["origin"]),
                                "partial": json(r["partial"]), "columns": .array(cols)])
            }
            indexes.sort { ($0["name"]?.string ?? "") < ($1["name"]?.string ?? "") }
            tables[name] = ["columns": .array(columns), "foreign_keys": .array(fks), "indexes": .array(indexes)]
        }
        var indexSQL: [String: JSONValue] = [:]
        for r in try c.query("SELECT name, sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL ORDER BY name") {
            indexSQL[r[0].string ?? ""] = json(r[1])
        }
        return ["tables": .object(tables), "index_sql": .object(indexSQL), "user_version": json(try c.scalar("PRAGMA user_version"))]
    }

    /// Vergleich je Tabelle, damit eine Abweichung lesbar gemeldet wird.
    private func assertSchema(_ actual: JSONValue, _ expected: JSONValue?, file: StaticString = #filePath, line: UInt = #line) {
        guard let expected else { return XCTFail("Fixture ohne schema", file: file, line: line) }
        let a = actual["tables"]?.object ?? [:], e = expected["tables"]?.object ?? [:]
        XCTAssertEqual(a.keys.sorted(), e.keys.sorted(), "Tabellen", file: file, line: line)
        for (name, table) in e where a[name] != nil {
            for part in ["columns", "foreign_keys", "indexes"] {
                XCTAssertEqual(a[name]?[part], table[part], "\(name).\(part)", file: file, line: line)
            }
        }
        XCTAssertEqual(actual["index_sql"], expected["index_sql"], "index_sql", file: file, line: line)
        XCTAssertEqual(actual["user_version"], expected["user_version"], "user_version", file: file, line: line)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func tableRows(_ c: SQLiteConnection, _ table: String) throws -> [JSONValue] {
        try c.rows("SELECT * FROM \(SQLiteConnection.quote(table)) ORDER BY rowid").map { .object($0) }
    }

    // MARK: - Schema und Migrationen

    /// Schema der Fixtures mit der user_version, die die Geraete-Schritte setzen (Python kennt sie nicht: 0)
    private func onDevice(_ schema: JSONValue?) -> JSONValue {
        var s = schema?.object ?? [:]
        s["user_version"] = .number(Double(Migrations.deviceSteps.map(\.version).max() ?? 0))
        return .object(s)
    }

    func testFreshDatabaseMatchesPythonInitDB() throws {
        let fx = try fixture("schema.json")
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try Migrations.migrate(c, clock: clock, deviceSteps: [])          // genau wie init_db

        assertSchema(try snapshot(c), fx["schema"])
        let settings: [JSONValue] = try c.query("SELECT key, value FROM settings ORDER BY rowid").map { [json($0[0]), json($0[1])] }
        XCTAssertEqual(settings, fx["settings"]?.array)
        XCTAssertEqual(Migrations.defaultSettings.count + 1, fx["settings"]?.array?.count, "Standardwerte und Hochschule")

        var courses = try c.rows("SELECT * FROM courses ORDER BY rowid")
        XCTAssertEqual(courses.first?["created_at"], "2026-10-25T14:30:05", "now_iso() aus der Uhr")
        for i in courses.indices { courses[i]["created_at"] = nil }
        XCTAssertEqual(courses.map { JSONValue.object($0) }, fx["courses"]?.array)
        XCTAssertEqual(try tableRows(c, "terms"), fx["terms"]?.array)

        // auf dem Geraet (mit den Geraete-Schritten): dieselben Tabellen und Einstellungen, nur user_version gesetzt
        let device = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try Migrations.migrate(device, clock: clock)
        assertSchema(try snapshot(device), onDevice(fx["schema"]))
        XCTAssertEqual(try device.query("SELECT key, value FROM settings ORDER BY rowid").map { [json($0[0]), json($0[1])] }, fx["settings"]?.array)
    }

    /// Geraete-Schritt 1: eine Datenbank aus einem Build vor S6 (tests_per_subject '1', Standard damals) plant auf
    /// dem iPad ohne Wochentests; der Schritt laeuft nur einmal, eine spaetere Wahl bleibt
    func testDeviceStepResetsWeeklyTestsOnce() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try Migrations.migrate(c, clock: clock, deviceSteps: [])          // Stand vor S6: ohne Geraete-Schritt
        try c.execute("UPDATE settings SET value='1' WHERE key='tests_per_subject'")
        try Migrations.migrate(c, clock: clock)
        XCTAssertEqual(try c.scalar("SELECT value FROM settings WHERE key='tests_per_subject'")?.string, "0")
        XCTAssertEqual(try c.scalar("PRAGMA user_version")?.int, 1)
        try c.execute("UPDATE settings SET value='2' WHERE key='tests_per_subject'")
        try Migrations.migrate(c, clock: clock)
        XCTAssertEqual(try c.scalar("SELECT value FROM settings WHERE key='tests_per_subject'")?.string, "2", "nur einmal")
    }

    func testMigrationsAreIdempotent() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try Migrations.migrate(c, clock: clock)
        try c.execute("UPDATE settings SET value='6' WHERE key='hours_per_day'")
        try c.execute("INSERT INTO files(id, course_id, name, kind) VALUES ('n1', '__user__', 'Notizbuch', 'notebook')")
        let before = try snapshot(c)

        try Migrations.migrate(c, clock: .fixed(berlin: "2027-01-01T08:00")!)
        try Migrations.migrate(c, clock: .fixed(berlin: "2027-01-02T08:00")!)
        assertSchema(try snapshot(c), before)
        XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM settings")?.int, Migrations.defaultSettings.count + 1, "Standardwerte und Hochschule")
        XCTAssertEqual(try c.scalar("SELECT value FROM settings WHERE key='hours_per_day'")?.string, "6", "Nutzerwert bleibt")
        XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM terms")?.int, 1)
        XCTAssertEqual(try c.scalar("SELECT created_at FROM courses WHERE id='__user__'")?.string, "2026-10-25T14:30:05")
        XCTAssertEqual(try c.scalar("SELECT kind FROM files WHERE id='n1'")?.string, "notebook")
        XCTAssertFalse(c.isInTransaction)
    }

    func testLegacyDatabaseMigratesLikePython() async throws {
        let fx = try fixture("legacy.json")
        let setup = (fx["setup_sql"]?.array ?? []).compactMap(\.string).joined(separator: "\n")
        XCTAssertFalse(setup.isEmpty)
        let path = try tempPath()
        do {
            let old = try SQLiteConnection(path: path)
            try old.executeScript(setup)
            XCTAssertFalse(try old.columnNames("files").contains("kind"), "Fixture ist wirklich der alte Stand")
            old.close()
        }
        let db = try SQLiteDatabase(path: path)
        try await db.migrate(clock: clock)

        let c = try SQLiteConnection(path: path)
        assertSchema(try snapshot(c), onDevice(fx["schema"]))
        assertSchema(try snapshot(c), onDevice(try fixture("schema.json")["schema"]))      // alt migriert == neu angelegt
        for (table, rows) in fx["rows"]?.object ?? [:] {
            XCTAssertEqual(try tableRows(c, table), rows.array, table)
        }
        XCTAssertEqual(try c.scalar("PRAGMA integrity_check")?.string, "ok")
        XCTAssertNil(try c.queryOne("PRAGMA foreign_key_check"))
    }

    /// wie init_db: die Datenbank merkt sich ihre Hochschule; eine andere Uni oeffnet sie nicht und aendert nichts
    func testDatabaseBelongsToOneUniversity() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try Migrations.migrate(c, clock: clock)
        XCTAssertEqual(try c.scalar("SELECT value FROM settings WHERE key='university'")?.string, "luh")
        let before = try snapshot(c)
        XCTAssertThrowsError(try Migrations.migrate(c, clock: clock, university: "hildesheim")) { error in
            XCTAssertEqual(error as? UniversityMismatch, UniversityMismatch(stored: "luh", expected: "hildesheim"))
            XCTAssertTrue("\(error)".contains("keine Daten gemischt"))
        }
        assertSchema(try snapshot(c), before)
        XCTAssertEqual(try c.scalar("SELECT value FROM settings WHERE key='university'")?.string, "luh")
        XCTAssertFalse(c.isInTransaction)
        try Migrations.migrate(c, clock: clock)                     // dieselbe Uni oeffnet weiter
        // eine Datenbank, die schon einer anderen Uni gehoert, oeffnet die LUH-App nicht
        let other = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try Migrations.migrate(other, clock: clock, university: "hildesheim")
        XCTAssertThrowsError(try Migrations.migrate(other, clock: clock)) {
            XCTAssertEqual($0 as? UniversityMismatch, UniversityMismatch(stored: "hildesheim", expected: "luh"))
        }
    }

    func testFailedMigrationLeavesDatabaseUntouched() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        let failing = Migrations.DeviceStep(version: 1) { _ in throw Boom() }
        XCTAssertThrowsError(try Migrations.migrate(c, clock: clock, deviceSteps: [failing])) { XCTAssertTrue($0 is Boom) }
        XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM sqlite_master")?.int, 0, "alles zurueckgerollt")
        XCTAssertFalse(c.isInTransaction)
        try Migrations.migrate(c, clock: clock)
        XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM settings")?.int, Migrations.defaultSettings.count + 1, "Standardwerte und Hochschule")
    }

    func testDeviceStepsRunOnceByUserVersion() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        let v1 = Migrations.DeviceStep(version: 1) { try $0.execute("CREATE TABLE device_only (n INTEGER)") }
        let v2 = Migrations.DeviceStep(version: 2) { try $0.execute("INSERT INTO device_only VALUES (1)") }
        try Migrations.migrate(c, clock: clock, deviceSteps: [v2, v1])
        XCTAssertEqual(try c.scalar("PRAGMA user_version")?.int, 2)
        try Migrations.migrate(c, clock: clock, deviceSteps: [v1, v2])
        XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM device_only")?.int, 1, "v2 lief nur einmal")
        let v3 = Migrations.DeviceStep(version: 3) { try $0.execute("INSERT INTO device_only VALUES (3)") }
        try Migrations.migrate(c, clock: clock, deviceSteps: [v1, v2, v3])
        XCTAssertEqual(try c.query("SELECT n FROM device_only ORDER BY n").map { $0[0] }, [1, 3])
        XCTAssertEqual(try c.scalar("PRAGMA user_version")?.int, 3)
        // ohne Geraete-Schritte bleibt user_version 0 (wie eine Datenbank vom PC)
        let fresh = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try Migrations.migrate(fresh, clock: clock, deviceSteps: [])
        XCTAssertEqual(try fresh.scalar("PRAGMA user_version")?.int, 0)
    }

    func testSchemaConstantIsVerbatimPython() {
        XCTAssertTrue(SchemaSQL.schema.hasPrefix("\nCREATE TABLE IF NOT EXISTS courses ("))
        XCTAssertTrue(SchemaSQL.schema.hasSuffix("    message TEXT\n);\n"))
        XCTAssertTrue(SchemaSQL.pageTexts.contains("PRIMARY KEY (file_id, page)"))
    }

    // MARK: - Verbindung

    func testPragmasLikePythonConnect() async throws {
        let path = try tempPath()
        let db = try SQLiteDatabase(path: path)
        let mode = try await db.scalar("PRAGMA journal_mode")
        XCTAssertEqual(mode, .text("wal"))
        let fk = try await db.scalar("PRAGMA foreign_keys")
        XCTAssertEqual(fk, .integer(1))
        let mem = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        let memMode = try await mem.scalar("PRAGMA journal_mode")
        XCTAssertEqual(memMode, .text("memory"))
    }

    func testForeignKeysAreEnforced() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try Migrations.migrate(c, clock: clock)
        XCTAssertThrowsError(try c.execute("INSERT INTO files(id, course_id, name) VALUES ('x', 'gibt-es-nicht', 'a.pdf')")) { e in
            let err = e as? SQLiteError
            XCTAssertEqual(err?.isConstraint, true)
            XCTAssertEqual(err?.message, "FOREIGN KEY constraint failed")
        }
        // ON DELETE CASCADE wie in Python
        try c.execute("INSERT INTO study_packages(date) VALUES ('2026-10-26')")
        let pkg = c.lastInsertRowID
        try c.execute("INSERT INTO study_tasks(package_id, type, title) VALUES (?, 'frei', 'Lesen')", [.integer(pkg)])
        try c.execute("DELETE FROM study_packages WHERE id=?", [.integer(pkg)])
        XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM study_tasks")?.int, 0)
    }

    func testFileDatabasePersists() async throws {
        let path = try tempPath()
        do {
            let db = try SQLiteDatabase(path: path)
            try await db.migrate(clock: clock)
            try await db.execute("UPDATE settings SET value=? WHERE key='user_name'", ["Testperson"])
        }
        let again = try SQLiteDatabase(path: path)
        let name = try await again.scalar("SELECT value FROM settings WHERE key='user_name'")
        XCTAssertEqual(name, "Testperson")
        XCTAssertEqual(again.path, path)
    }

    func testValueTypesRoundTrip() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try c.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, x)")
        let text = "Grüße – 学习 🎓 mit \u{0} Nullzeichen"
        let blob = Data([0, 1, 2, 254, 255])
        try c.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?)", [.integer(Int64.max), .real(2.5), .text(text), .blob(blob), .null])
        try c.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?)", [.integer(-42), .real(-0.125), .text(""), .blob(Data()), true])
        // Typ-Affinitaet wie in Python: 3.0 in einer INTEGER-Spalte wird 3, 7 in einer REAL-Spalte 7.0
        try c.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?)", [.real(3.0), .integer(7), .integer(5), nil, .real(1.5)])

        let rows = try c.query("SELECT * FROM t ORDER BY rowid")
        XCTAssertEqual(rows.map(\.values), [
            [.integer(Int64.max), .real(2.5), .text(text), .blob(blob), .null],
            [.integer(-42), .real(-0.125), .text(""), .blob(Data()), .integer(1)],
            [.integer(3), .real(7), .text("5"), .null, .real(1.5)],
        ])
        XCTAssertEqual(rows[0].columns, ["i", "r", "s", "b", "x"])
        XCTAssertEqual(try c.query("SELECT typeof(s), typeof(b) FROM t WHERE rowid=2").first?.values, ["text", "blob"],
                       "leerer Text und leerer BLOB bleiben, statt NULL zu werden")

        // JSON-Form wie dict(row): ganze Zahlen ohne Nachkommastellen, BLOB getrennt
        let j = rows[1].json
        XCTAssertEqual(j, ["i": -42, "r": -0.125, "s": "", "x": 1])
        XCTAssertEqual(JSONValue.object(j).jsonString(sortedKeys: true), #"{"i":-42,"r":-0.125,"s":"","x":1}"#)
        XCTAssertEqual(rows[0].blobs, ["b": blob])
        XCTAssertNil(rows[0].json["b"])
        XCTAssertEqual(rows[2].json["b"], .null, "NULL in einer BLOB-Spalte ist JSON null")
        XCTAssertEqual(rows[0]["s"]?.string, text)
        XCTAssertNil(rows[0]["gibt-es-nicht"])
        XCTAssertEqual(rows[0]["i"]?.int64, Int64.max, "exakt ueber int64")
    }

    func testDuplicateColumnNamesFirstWins() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        let row = try c.queryOne("SELECT 1 AS a, 2 AS a")
        XCTAssertEqual(row?["a"], .integer(1))
        XCTAssertEqual(row?.json, ["a": 1])
    }

    func testBindingFromJSON() {
        XCTAssertEqual(SQLiteValue(json: true), .integer(1))
        XCTAssertEqual(SQLiteValue(json: 12), .integer(12))
        XCTAssertEqual(SQLiteValue(json: 1.5), .real(1.5))
        XCTAssertEqual(SQLiteValue(json: "x"), .text("x"))
        XCTAssertEqual(SQLiteValue(json: .null), .null)
        XCTAssertNil(SQLiteValue(json: [1, 2]))
        XCTAssertNil(SQLiteValue(json: ["a": 1]))
        XCTAssertEqual(SQLiteValue(Int?.none), .null)
        XCTAssertEqual(SQLiteValue("a" as String?), .text("a"))
        XCTAssertEqual(SQLiteValue.integer(3).double, 3)
    }

    func testStatementStepwise() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        try c.execute("CREATE TABLE n (v INTEGER, name TEXT)")
        let insert = try c.prepare("INSERT INTO n VALUES (?, ?)")
        for i in 1...5 { try insert.bind([.integer(Int64(i)), .text("z\(i)")]).run() }

        let select = try c.prepare("SELECT v, name FROM n WHERE v > ? ORDER BY v")
        XCTAssertEqual(select.columns, ["v", "name"])
        try select.bind([3])
        XCTAssertEqual(try select.next()?["name"], "z4")
        XCTAssertEqual(try select.next()?["v"], .integer(5))
        XCTAssertNil(try select.next())
        try select.bind([4])                                    // neu binden setzt zurueck
        XCTAssertEqual(try select.all().map { $0[0] }, [5])
        select.reset()
        XCTAssertEqual(try select.all().count, 1, "reset: gleiche Werte noch einmal")
        XCTAssertEqual(try c.scalar("SELECT COUNT(*) FROM n WHERE name LIKE ?", ["z%"]), .integer(5))
        XCTAssertNil(try c.queryOne("SELECT * FROM n WHERE v = ?", [99]))
    }

    func testErrorsCarrySQLiteMessage() throws {
        let c = try SQLiteConnection(path: SQLiteDatabase.inMemory)
        XCTAssertThrowsError(try c.execute("SELEC 1")) { e in
            let err = e as? SQLiteError
            XCTAssertEqual(err?.stage, .prepare)
            XCTAssertEqual(err?.code, 1)
            XCTAssertTrue(err?.message.contains("syntax error") ?? false, err?.message ?? "")
            XCTAssertEqual(err?.sql, "SELEC 1")
        }
        try c.execute("CREATE TABLE u (id TEXT PRIMARY KEY)")
        try c.execute("INSERT INTO u VALUES ('a')")
        XCTAssertThrowsError(try c.execute("INSERT INTO u VALUES ('a')")) { e in
            let err = e as? SQLiteError
            XCTAssertEqual(err?.stage, .step)
            XCTAssertEqual(err?.code, 19)                       // SQLITE_CONSTRAINT
            XCTAssertEqual(err?.extendedCode, 1555)             // SQLITE_CONSTRAINT_PRIMARYKEY
            XCTAssertEqual(err?.message, "UNIQUE constraint failed: u.id")
            XCTAssertTrue(err?.description.contains("UNIQUE constraint failed") ?? false)
        }
        XCTAssertThrowsError(try c.execute("INSERT INTO u VALUES (?)", [])) { XCTAssertEqual(($0 as? SQLiteError)?.stage, .bind) }
        XCTAssertThrowsError(try c.execute("SELECT 1; SELECT 2")) { XCTAssertEqual(($0 as? SQLiteError)?.stage, .prepare) }
        XCTAssertNoThrow(try c.execute("SELECT 1; -- Kommentar\n ;  /* noch einer */"))
        XCTAssertThrowsError(try c.execute("   ")) { XCTAssertEqual(($0 as? SQLiteError)?.stage, .prepare) }
        XCTAssertThrowsError(try c.executeScript("CREATE TABLE ok1 (a); CREATE TABEL kaputt (a);")) { e in
            XCTAssertEqual((e as? SQLiteError)?.stage, .exec)
            XCTAssertTrue((e as? SQLiteError)?.message.contains("syntax error") ?? false)
        }
        XCTAssertThrowsError(try SQLiteConnection(path: "/gibt/es/nicht/x.db")) { XCTAssertEqual(($0 as? SQLiteError)?.stage, .open) }
        let pending = try c.prepare("SELECT id FROM u")
        c.close()
        XCTAssertThrowsError(try c.execute("SELECT 1")) { XCTAssertEqual(($0 as? SQLiteError)?.stage, .closed) }
        XCTAssertThrowsError(try pending.next()) { XCTAssertEqual(($0 as? SQLiteError)?.stage, .closed) }
    }

    // MARK: - Transaktionen

    func testTransactionCommitsAndRollsBack() async throws {
        let db = try SQLiteDatabase(path: try tempPath())
        try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")

        let id = try await db.transaction { c -> Int64 in
            try c.execute("INSERT INTO t(v) VALUES ('a')")
            XCTAssertTrue(c.isInTransaction)
            return c.lastInsertRowID
        }
        XCTAssertEqual(id, 1)

        do {
            try await db.transaction { c in
                try c.execute("INSERT INTO t(v) VALUES ('b')")
                throw Boom()
            }
            XCTFail("Fehler erwartet")
        } catch is Boom {}

        // SQLite-Fehler mitten in der Transaktion: auch das erste INSERT wird zurueckgerollt
        do {
            try await db.transaction { c in
                try c.execute("INSERT INTO t(v) VALUES ('c')")
                try c.execute("INSERT INTO t(id, v) VALUES (1, 'doppelt')")
            }
            XCTFail("Fehler erwartet")
        } catch let e as SQLiteError {
            XCTAssertTrue(e.isConstraint)
        }

        let values = try await db.query("SELECT v FROM t ORDER BY id").map { $0[0] }
        XCTAssertEqual(values, ["a"])
        let open = try await db.withConnection { $0.isInTransaction }
        XCTAssertFalse(open)
    }

    func testNestedTransactionIsRejected() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.execute("CREATE TABLE t (v INTEGER)")
        do {
            try await db.transaction { c in
                try c.execute("INSERT INTO t VALUES (1)")
                try c.transaction { try $0.execute("INSERT INTO t VALUES (2)") }
            }
            XCTFail("Fehler erwartet")
        } catch let e as SQLiteError {
            XCTAssertEqual(e.stage, .transaction)
        }
        let count = try await db.scalar("SELECT COUNT(*) FROM t")
        XCTAssertEqual(count, .integer(0), "aeussere Transaktion ebenfalls zurueckgerollt")
    }

    func testConcurrentTransactionsAreSerialized() async throws {
        let db = try SQLiteDatabase(path: try tempPath())
        try await db.execute("CREATE TABLE n (v INTEGER)")
        try await db.execute("INSERT INTO n VALUES (0)")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    // lesen, dann schreiben: ohne Serialisierung gingen Erhoehungen verloren
                    try await db.transaction { c in
                        let v = try c.scalar("SELECT v FROM n")?.int64 ?? -1
                        try c.execute("UPDATE n SET v = ?", [.integer(v + 1)])
                    }
                }
                group.addTask { _ = try await db.query("SELECT v FROM n") }
            }
            try await group.waitForAll()
        }
        let v = try await db.scalar("SELECT v FROM n")
        XCTAssertEqual(v, .integer(40))
    }
}
