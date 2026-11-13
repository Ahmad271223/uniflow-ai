import Foundation
import XCTest
@testable import UniFlowCore

/// Datentrennung je Stud.IP-Benutzer im Geraete-Abgleich (12.11.2026, `StudIPUserMark`): der Hash des Stud.IP-Benutzers
/// geht bei jedem Abruf und jeder Sendung mit; meldet der Dienst 409 `studip_user_mismatch`, haelt der Abgleich an und
/// aendert hier nichts. Der Hash selbst gleicht nie als Einstellung ab. Schein-Dienst, kein Netz.
final class DeviceSyncStudIPUserTests: XCTestCase {

    private actor FakeService: DeviceSyncTransport {
        var queries: [String] = []
        var pushes: [JSONValue] = []
        let mismatch: Bool
        let changes: JSONValue

        init(mismatch: Bool, changes: JSONValue = ["cursor": "2026-11-12T10:00:00.000000Z", "changes": .object([:]), "tombstones": .array([]), "has_more": false]) {
            self.mismatch = mismatch
            self.changes = changes
        }

        func syncChanges(query: String) async throws -> JSONValue {
            queries.append(query)
            if mismatch { throw AccountError(status: 409, code: StudIPUserMark.mismatchCode, message: "anderer Benutzer", retryAfter: nil) }
            return changes
        }

        func syncPush(_ body: JSONValue) async throws -> JSONValue {
            pushes.append(body)
            if mismatch { throw AccountError(status: 409, code: StudIPUserMark.mismatchCode, message: "anderer Benutzer", retryAfter: nil) }
            return ["results": .array([]), "conflicts": .array([])]
        }
    }

    private func database(hashOf user: String?) async throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0) }
        if let user { try await db.transaction { try StudIPUserMark.store($0, StudIPUserMark.hash(userID: user)) } }
        try await db.transaction { try $0.execute("INSERT INTO modules(name) VALUES ('Analysis A')") }
        return db
    }

    func testMarkAdoptsOnceThenComparesAndStoresOnlyTheHash() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { try Migrations.migrate($0) }
        let outcomes = try await db.transaction { c -> [StudIPUserMark.Outcome] in
            [try StudIPUserMark.check(c, userID: "ada-123"), try StudIPUserMark.check(c, userID: "ada-123"),
             try StudIPUserMark.check(c, userID: "bob-456")]
        }
        XCTAssertEqual(outcomes, [.adopted, .same, .other])
        let stored = try await db.withConnection { try StudIPUserMark.stored($0) }
        XCTAssertEqual(stored, StudIPUserMark.hash(userID: "ada-123"))
        XCTAssertFalse(stored?.contains("ada") ?? true, "nur der Hash, nie die Kennung")
        XCTAssertEqual(stored?.count, 64)
    }

    func testHashGoesWithEveryRequestButNeverAsSetting() async throws {
        let db = try await database(hashOf: "ada-123")
        let service = FakeService(mismatch: false)
        let r = await DeviceSync(database: db, transport: service, device: "ipad-1").run(account: "konto-1")
        XCTAssertTrue(r.ok, r.error ?? "")
        let hash = StudIPUserMark.hash(userID: "ada-123")
        let queries = await service.queries
        XCTAssertFalse(queries.isEmpty)
        XCTAssertTrue(queries.allSatisfy { $0.contains("studip_user=\(hash)") }, queries.description)
        let pushes = await service.pushes
        XCTAssertEqual(pushes.first?["studip_user"]?.string, hash)
        let sentSettings = (pushes.first?["items"]?.array ?? []).filter { $0["entity"]?.string == "settings" }
        XCTAssertFalse(sentSettings.contains { $0["id"]?.string == StudIPUserMark.key || $0["data"]?["key"]?.string == StudIPUserMark.key },
                       "der Hash gleicht nicht als Einstellung ab")
        XCTAssertTrue(DeviceSyncCore.settingIsLocal(StudIPUserMark.key))
    }

    func testWithoutStudIPUserNothingIsSent() async throws {
        let db = try await database(hashOf: nil)
        let service = FakeService(mismatch: false)
        _ = await DeviceSync(database: db, transport: service, device: "ipad-1").run(account: "konto-1")
        let queries = await service.queries
        XCTAssertFalse(queries.contains { $0.contains("studip_user") }, "Bestandsdaten ohne Hash: wie bisher")
        let pushes = await service.pushes
        XCTAssertNil(pushes.first?["studip_user"])
    }

    func testOtherStudIPUserAtTheServiceStopsTheSyncWithoutChanges() async throws {
        let db = try await database(hashOf: "bob-456")
        let service = FakeService(mismatch: true)
        let r = await DeviceSync(database: db, transport: service, device: "ipad-1").run(account: "konto-1")
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.studipUserMismatch)
        XCTAssertEqual(r.error, DeviceSync.mismatchText)
        XCTAssertEqual(r.applied + r.pushed + r.deleted, 0)
        let pushes = await service.pushes
        XCTAssertTrue(pushes.isEmpty, "nach dem 409 beim Abruf wird nichts gesendet")
        let modules = try await db.withConnection { try $0.rows("SELECT name FROM modules").compactMap { $0["name"]?.string } }
        XCTAssertEqual(modules, ["Analysis A"], "lokale Daten bleiben unveraendert")
    }
}
