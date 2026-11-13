import Foundation
import XCTest
@testable import UniFlowCore

/// Haken "erledigt" je Datei: ein Stand (`files.status`), fuer den Geraete-Abgleich gespiegelt in `file_done:<ID>`
/// (Trigger im Schema), Lernstand in beide Richtungen, abgewaehlte Faecher (Auftrag 13.11.2026, Teil 2). Ohne Dienst;
/// zwei Geraete gegen den echten Dienst: `DeviceSyncFileDoneLiveTests`. Gleiche Faelle: tests/test_file_done_sync.py.
final class ModuleDoneSyncTests: XCTestCase {

    private let clock = UniFlowClock.fixed(berlin: "2026-11-13T10:00:00")!

    private func backend() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Mathematik I', '#175ee8', 0)")
            try c.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES ('k1', 'Mathematik I', 'Mathematik I', 'vorlesung', 1, 1, 't')")
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status) VALUES ('f1', 'k1', 'Blatt 1.pdf', 1792000000, 'gelesen')")
            try c.execute("INSERT INTO study_packages(id, date, module_id, title, status, created_at) VALUES (1, '2026-11-13', 1, 'Mathe', 'geplant', 't')")
            try c.execute("INSERT INTO study_tasks(id, package_id, type, file_id, title, status) VALUES (1, 1, 'uebung', 'f1', 'Blatt 1', 'geplant'), (2, 1, 'test', 'f1', 'Wochentest', 'geplant')")
        }
        return b
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ body: String? = nil, status: Int = 200) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!, body: Data((body ?? "").utf8)))
        XCTAssertEqual(r.status, status, "\(method) \(path): \(String(decoding: r.body.prefix(300), as: UTF8.self))")
        return r.json ?? .null
    }

    /// (Datei, Eintrag fuer den Abgleich, Aufgabe 1, Wochentest)
    private func state(_ b: LocalBackend, file: String = "f1") async throws -> [String?] {
        try await b.context.database.withConnection { c in
            [try c.queryOne("SELECT status FROM files WHERE id=?", [.text(file)])?["status"]?.string,
             try c.queryOne("SELECT value FROM settings WHERE key=?", [.text("file_done:" + file)])?["value"]?.string,
             try c.queryOne("SELECT status FROM study_tasks WHERE id=1")?["status"]?.string,
             try c.queryOne("SELECT status FROM study_tasks WHERE id=2")?["status"]?.string]
        }
    }

    func testTickWritesSyncEntryAndClosesTasksButNotTests() async throws {
        let b = try await backend()
        let r = try await call(b, "POST", "/api/modules/1/done", #"{"file_ids": ["f1"], "done": true}"#)
        XCTAssertEqual(r["tasks"]?.int, 1)
        var s = try await state(b)
        XCTAssertEqual(s, ["erledigt", "1", "erledigt", "geplant"], "Wochentest hat ein eigenes Ergebnis")
        // die Einstellungen der Oberflaeche zeigen die Haken nicht
        let settings = try await call(b, "GET", "/api/settings")
        XCTAssertNil(settings["file_done:f1"])
        _ = try await call(b, "POST", "/api/modules/1/done", #"{"file_ids": ["f1"], "done": false}"#)
        s = try await state(b)
        XCTAssertEqual(s, ["gelesen", "0", "geplant", "geplant"])
    }

    /// Lernstand: Aufgabe in "Heute für dich geplant" erledigt -> Haken; wieder geoeffnet -> Haken weg
    func testTaskStatusSetsAndClearsTheTick() async throws {
        let b = try await backend()
        _ = try await call(b, "POST", "/api/tasks/1/status", #"{"status": "erledigt"}"#)
        var s = try await state(b)
        XCTAssertEqual(Array(s.prefix(3)), ["erledigt", "1", "erledigt"])
        let d = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(d["files"]?.array?.first?["status"]?.string, "erledigt")
        _ = try await call(b, "POST", "/api/tasks/1/status", #"{"status": "geplant"}"#)
        s = try await state(b)
        XCTAssertEqual(Array(s.prefix(3)), ["gelesen", "0", "geplant"])
    }

    /// Status im Dokument (PC-Ansicht, PATCH /api/files): erledigt an/aus wie der Haken
    func testDocumentStatusUsesTheSameState() async throws {
        let b = try await backend()
        _ = try await call(b, "PATCH", "/api/files/f1", #"{"status": "erledigt"}"#)
        var s = try await state(b)
        XCTAssertEqual(Array(s.prefix(3)), ["erledigt", "1", "erledigt"])
        _ = try await call(b, "PATCH", "/api/files/f1", #"{"status": "neu"}"#)
        s = try await state(b)
        XCTAssertEqual(Array(s.prefix(3)), ["neu", "0", "geplant"])
    }

    /// plan_modules_off: Haken ja, Haken weg oeffnet keine Aufgaben wieder
    func testDeselectedSubjectTicksWithoutPlanning() async throws {
        let b = try await backend()
        try await b.context.database.withConnection { try StudyPlanModules.setPlanned($0, name: "Mathematik I", false) }
        var r = try await call(b, "POST", "/api/modules/1/done", #"{"file_ids": ["f1"], "done": true}"#)
        XCTAssertEqual(r["tasks"]?.int, 1)
        r = try await call(b, "POST", "/api/modules/1/done", #"{"file_ids": ["f1"], "done": false}"#)
        XCTAssertEqual(r["tasks"]?.int, 0)
        let s = try await state(b)
        XCTAssertEqual(Array(s.prefix(3)), ["gelesen", "0", "erledigt"])
    }

    /// Ein vom Abgleich angekommener Eintrag setzt die Datei, schliesst die offene Aufgabe und wird nicht
    /// zurueckgesendet; eine spaeter geladene Datei bekommt den Haken beim Laden
    func testAppliedEntryFromOtherDeviceSetsFileAndClosesTask() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try DeviceSyncSchema.ensure(c)
            let core = DeviceSyncCore(device: "ipad-1")
            core.clock = self.clock
            let page: JSONValue = ["changes": ["settings": [
                ["key": "file_done:f1", "value": "1", "sync_version": 3, "sync_updated_at": "2026-11-13T09:00:00.000Z", "sync_device": "mac-1"],
                ["key": "file_done:spaet", "value": "1", "sync_version": 1, "sync_updated_at": "2026-11-13T09:00:00.000Z", "sync_device": "mac-1"],
            ]], "tombstones": [], "cursor": "2026-11-13T09:00:00.000Z"]
            try core.applyPage(c, page, cursor: "2026-11-13T09:00:00.000Z")
            let (items, _) = try core.collect(c)
            XCTAssertFalse(items.contains { $0.local.hasPrefix("file_done:") }, "Angekommenes geht nicht zurueck")
            // Datei kommt spaeter mit dem naechsten Abgleich der Hochschule
            try c.execute("INSERT INTO files(id, course_id, name, status) VALUES ('spaet', 'k1', 'Spaet.pdf', 'neu')")
        }
        let s = try await state(b)
        XCTAssertEqual(Array(s.prefix(4)), ["erledigt", "1", "erledigt", "geplant"])
        let late = try await state(b, file: "spaet")
        XCTAssertEqual(late.first, "erledigt")
        let note = try await b.context.database.withConnection { c in
            try c.queryOne("SELECT note FROM task_history WHERE task_id=1 ORDER BY id DESC")?["note"]?.string
        }
        XCTAssertEqual(note, "Auf einem anderen Gerät abgehakt")
    }

    /// Hin und zurueck vor dem Abgleich zaehlt als Aenderung (der neuere Stand gewinnt im Dienst)
    func testToggleBackAndForthIsSentAsChange() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try DeviceSyncSchema.ensure(c)
            try c.execute("UPDATE files SET status='erledigt' WHERE id='f1'")
            try c.execute("INSERT INTO sync_link_map(entity, remote_id, local_id, remote_version, local_version, base) VALUES ('settings', 'file_done:f1', 'file_done:f1', 1, -1, '{\"value\": \"1\"}')")
            try c.execute("UPDATE files SET status='gelesen' WHERE id='f1'")
            try c.execute("UPDATE files SET status='erledigt' WHERE id='f1'")
            let (items, _) = try DeviceSyncCore(device: "ipad-1").collect(c)
            let it = try XCTUnwrap(items.first { $0.local == "file_done:f1" })
            XCTAssertEqual(it.body["changed"], ["value"])
            XCTAssertEqual(it.body["data"]?["value"], "1")
        }
        XCTAssertFalse(DeviceSyncCore.settingIsLocal("file_done:pin"), "Haken gleichen immer ab")
    }

    /// Bestehende Datenbank: schon erledigte Dateien bekommen ihren Eintrag beim Start
    func testBackfillForAlreadyDoneFiles() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { c in
            try Migrations.migrate(c)
            try c.execute("DROP TRIGGER trg_file_done_new_file")
            try c.execute("INSERT INTO files(id, course_id, name, status) VALUES ('alt', '__user__', 'Alt.pdf', 'erledigt')")
            XCTAssertNil(try c.queryOne("SELECT 1 FROM settings WHERE key='file_done:alt'"))
            try Migrations.migrate(c)
            XCTAssertEqual(try c.queryOne("SELECT value FROM settings WHERE key='file_done:alt'")?["value"]?.string, "1")
        }
    }
}
