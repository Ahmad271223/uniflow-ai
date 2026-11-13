import Foundation
import XCTest
@testable import UniFlowCore

/// Haken "erledigt" je Datei und ganze Woche im Moduldetail (Auftrag 13.11.2026, `ModuleDone`). Derselbe Ablauf wie
/// `tests/test_module_done.py` am PC-Server: gleicher Stand wie die Lernpakete, nur Dateien des Moduls.
final class ModuleDoneTests: XCTestCase {

    private let clock = UniFlowClock.fixed(berlin: "2026-11-13T10:00:00")!

    /// Modul 1 mit drei Dateien (neu, gelesen, erledigt), Modul 2 mit einer fremden Datei; heutiges Lernpaket mit je
    /// einer Aufgabe zu d-0 (geplant), d-1 (uebersprungen), d-2 (erledigt)
    private func backend() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Analysis', '#175ee8', 0), (2, 'Physik', '#16a34a', 1)")
            try c.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES ('c1', 'Analysis', 'Analysis', 'vorlesung', 1, 1, 't'), ('c2', 'Physik', 'Physik', 'vorlesung', 1, 2, 't')")
            for (id, course, status) in [("d-0", "c1", "neu"), ("d-1", "c1", "gelesen"), ("d-2", "c1", "erledigt"), ("fremd", "c2", "neu")] {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, status) VALUES (?,?,?,?,?)",
                              [.text(id), .text(course), .text("\(id).pdf"), .integer(1_792_000_000), .text(status)])
            }
            try c.execute("INSERT INTO study_packages(id, date, module_id, title, status, created_at) VALUES (1, '2026-11-13', 1, 'Analysis', 'geplant', 't')")
            for (id, file, status) in [(1, "d-0", "geplant"), (2, "d-1", "uebersprungen"), (3, "d-2", "erledigt"), (4, "fremd", "geplant")] {
                try c.execute("INSERT INTO study_tasks(id, package_id, type, file_id, title, status) VALUES (?,1,'vorlesung',?,?,?)",
                              [.integer(Int64(id)), .text(file), .text(file), .text(status)])
            }
        }
        return b
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ body: String? = nil, status: Int = 200) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!, body: Data((body ?? "").utf8)))
        XCTAssertEqual(r.status, status, "\(method) \(path): \(String(decoding: r.body.prefix(300), as: UTF8.self))")
        return r.json ?? .null
    }

    private func state(_ b: LocalBackend) async throws -> (files: [String], tasks: [String]) {
        try await b.context.database.withConnection { c in
            (try c.query("SELECT id, status FROM files ORDER BY id").map { "\($0["id"]?.string ?? "")=\($0["status"]?.string ?? "")" },
             try c.query("SELECT id, status FROM study_tasks ORDER BY id").map { "\($0["id"]?.int ?? 0)=\($0["status"]?.string ?? "")" })
        }
    }

    func testTickAndUntickShareStateWithStudyTasks() async throws {
        let b = try await backend()
        var r = try await call(b, "POST", "/api/modules/1/done", #"{"file_ids": ["d-0", "d-1", "fremd"], "done": true}"#)
        XCTAssertEqual(r["changed"]?.array?.compactMap(\.string), ["d-0", "d-1"], "fremde Datei bleibt")
        XCTAssertEqual(r["tasks"]?.int, 1, "nur die offene Aufgabe zu d-0")
        var s = try await state(b)
        XCTAssertEqual(s.files, ["d-0=erledigt", "d-1=erledigt", "d-2=erledigt", "fremd=neu"])
        XCTAssertEqual(s.tasks, ["1=erledigt", "2=uebersprungen", "3=erledigt", "4=geplant"])
        // Moduldetail zeigt den Stand je Datei
        let d = try await call(b, "GET", "/api/modules/1")
        XCTAssertEqual(Set((d["files"]?.array ?? []).filter { $0["status"]?.string == "erledigt" }.compactMap { $0["id"]?.string }), ["d-0", "d-1", "d-2"])

        // ganze Woche wieder auf: alle Haken weg, erledigte Aufgaben wieder offen
        r = try await call(b, "POST", "/api/modules/1/done", #"{"file_ids": ["d-0", "d-1", "d-2"], "done": false}"#)
        XCTAssertEqual(r["changed"]?.array?.compactMap(\.string), ["d-0", "d-1", "d-2"])
        XCTAssertEqual(r["tasks"]?.int, 2)
        s = try await state(b)
        XCTAssertEqual(s.files, ["d-0=gelesen", "d-1=gelesen", "d-2=gelesen", "fremd=neu"])
        XCTAssertEqual(s.tasks, ["1=geplant", "2=uebersprungen", "3=geplant", "4=geplant"])
        let hist = try await b.context.database.withConnection { c in
            try c.query("SELECT note FROM task_history ORDER BY id").compactMap { $0["note"]?.string }
        }
        XCTAssertEqual(hist, ["Im Modul abgehakt", "Haken im Modul entfernt", "Haken im Modul entfernt"])
    }

    func testRejectsBadInput() async throws {
        let b = try await backend()
        _ = try await call(b, "POST", "/api/modules/1/done", #"{"file_ids": ["d-0"]}"#, status: 400)
        _ = try await call(b, "POST", "/api/modules/1/done", #"{"file_ids": [], "done": true}"#, status: 400)
        _ = try await call(b, "POST", "/api/modules/99/done", #"{"file_ids": ["d-0"], "done": true}"#, status: 404)
        let s = try await state(b)
        XCTAssertEqual(s.files, ["d-0=neu", "d-1=gelesen", "d-2=erledigt", "fremd=neu"])
    }
}
