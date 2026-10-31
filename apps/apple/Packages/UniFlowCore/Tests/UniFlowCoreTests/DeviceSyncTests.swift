import Foundation
import XCTest
@testable import UniFlowCore

/// Schema und Senden des Geraete-Abgleichs ohne Dienst; der Abgleich selbst: `DeviceSyncLiveTests`
final class DeviceSyncTests: XCTestCase {
    func testPrivateValuesNeverLeaveTheDevice() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0) }
        let items = try await db.transaction { c -> [DeviceSyncCore.PushItem] in
            try DeviceSyncSchema.ensure(c)
            for k in ["lan_pin", "university", "demo_content", "pen_input", "semester_rule_applied", "chatgpt_token", "my_secret", "uni_passwort", "backup_path", "cache_dir", "service_url"] {
                try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, 'x')", [.text(k)])
            }
            try c.execute("INSERT INTO modules(name) VALUES ('M')")
            let m = c.lastInsertRowID
            try c.execute("INSERT INTO study_packages(date, module_id, title) VALUES ('2026-11-02', ?, 'P')", [.integer(m)])
            try c.execute("INSERT INTO study_tasks(package_id, type, title, test_id) VALUES (?, 'test', 'T', 7)", [.integer(c.lastInsertRowID)])
            return try DeviceSyncCore(device: "ipad-1").collect(c).0
        }
        let keys = items.filter { $0.table == "settings" }.map(\.local)
        for k in ["lan_pin", "university", "demo_content", "pen_input", "semester_rule_applied", "chatgpt_token", "my_secret", "uni_passwort", "backup_path", "cache_dir", "service_url"] {
            XCTAssertFalse(keys.contains(k), k)
        }
        XCTAssertFalse(keys.isEmpty, "die uebrigen Einstellungen werden gesendet")
        let task = try XCTUnwrap(items.first { $0.table == "study_tasks" })
        XCTAssertNil(task.body["data"]?["test_id"], "Tests sind nicht im Abgleich")
    }

    func testTriggersCountChangesAndLeaveTombstones() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0) }
        try await db.transaction { c in
            try DeviceSyncSchema.ensure(c)
            try DeviceSyncSchema.ensure(c)                      // idempotent
            try c.execute("INSERT INTO modules(name) VALUES ('M')")
            let id = c.lastInsertRowID
            let first = try XCTUnwrap(c.rows("SELECT * FROM modules WHERE id=?", [.integer(id)]).first)
            XCTAssertEqual(first["sync_version"]?.int, 1)
            XCTAssertNotNil(first["sync_updated_at"]?.string)
            try c.execute("UPDATE modules SET name='N' WHERE id=?", [.integer(id)])
            XCTAssertEqual(try c.rows("SELECT sync_version v FROM modules WHERE id=?", [.integer(id)]).first?["v"]?.int, 2)
            try c.execute("DELETE FROM modules WHERE id=?", [.integer(id)])
            XCTAssertEqual(try c.rows("SELECT entity_id e FROM sync_tombstones WHERE entity='modules'").first?["e"]?.string, String(id))
        }
    }

    func testWithoutAccountTheDatabaseStaysAsItIs() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0) }
        let cols = try await db.withConnection { try $0.columnNames("modules") }
        XCTAssertFalse(cols.contains("sync_version"), "Spalten erst mit dem ersten Abgleich")
    }
}
