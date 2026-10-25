import Foundation
import XCTest
@testable import UniFlowCore

// Stundenplan gegen die Python-Referenz: timetable-logic.json (tools/gen-timetable-fixture.py) mit eingefrorener Uhr
// (Sonntag, 25.10.2026, 14:30:05 Europe/Berlin, Tag der Zeitumstellung) und erfundenen Daten.

private func fixture() throws -> JSONValue {
    // .../apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/LocalTimetableTests.swift -> Repository-Wurzel
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/timetable-logic.json")))
}

private let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!

/// Erste Abweichung zweier JSON-Werte mit Pfad (fuer lesbare Fehlermeldungen)
func jsonDiff(_ a: JSONValue?, _ b: JSONValue?, _ path: String = "$") -> String? {
    switch (a, b) {
    case (.object(let x)?, .object(let y)?):
        for k in Set(x.keys).union(y.keys).sorted() {
            if let d = jsonDiff(x[k], y[k], "\(path).\(k)") { return d }
        }
        return nil
    case (.array(let x)?, .array(let y)?):
        if x.count != y.count { return "\(path): \(x.count) statt \(y.count) Einträge" }
        for (i, (p, q)) in zip(x, y).enumerated() {
            if let d = jsonDiff(p, q, "\(path)[\(i)]") { return d }
        }
        return nil
    default:
        return a == b ? nil : "\(path): \(a?.jsonString() ?? "fehlt") statt \(b?.jsonString() ?? "fehlt")"
    }
}

final class LocalTimetableTests: XCTestCase {

    /// Lokales Backend mit denselben Seed-Daten wie der Generator
    private func seeded(_ fx: JSONValue) async throws -> LocalBackend {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let seed = fx["seed"]?.array ?? []
        try await backend.context.database.transaction { c in
            for s in seed {
                try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null })
            }
        }
        return backend
    }

    /// Anfrage wie im Generator: JSON-Rumpf, Formularfelder (sortiert) und eine Datei
    private func request(_ s: JSONValue) -> LocalRequest {
        let method = s["method"]?.string ?? "GET"
        let url = URL(string: "uniflow-local://device" + (s["path"]?.string ?? ""))!
        if s["form"] != nil || s["file"] != nil {
            let b = "uniflow-fixture"
            var body = ""
            let form = s["form"]?.object ?? [:]
            for k in form.keys.sorted() { body += "--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(form[k]?.string ?? "")\r\n" }
            if let f = s["file"] {
                body += "--\(b)\r\nContent-Disposition: form-data; name=\"\(f["field"]?.string ?? "")\"; filename=\"\(f["filename"]?.string ?? "")\"\r\n"
                body += "Content-Type: \(f["content_type"]?.string ?? "")\r\n\r\n\(f["text"]?.string ?? "")\r\n"
            }
            body += "--\(b)--\r\n"
            return LocalRequest(method: method, url: url, headers: ["Content-Type": "multipart/form-data; boundary=\(b)"], body: Data(body.utf8))
        }
        let body = s["body"].map { $0.serialized() }
        return LocalRequest(method: method, url: url, headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body)
    }

    private func tables(_ backend: LocalBackend) async throws -> JSONValue {
        try await backend.context.database.withConnection { c -> JSONValue in
            var out: [String: JSONValue] = [:]
            for t in ["course_events", "event_exceptions", "schedule_imports"] {
                out[t] = .array(try c.rows("SELECT * FROM \(t) ORDER BY id").map { r -> JSONValue in
                    var r = r
                    if t == "schedule_imports", let p = r["parsed"]?.string, !p.isEmpty { r["parsed"] = try JSONValue.parse(p) }
                    return .object(r)
                })
            }
            return .object(out)
        }
    }

    /// Dieselben Anfragen in derselben Reihenfolge wie gegen app/server.py: Status und Antwort exakt gleich, danach
    /// dieselben Zeilen in course_events, event_exceptions und schedule_imports
    func testStepsMatchPythonServer() async throws {
        let fx = try fixture()
        let backend = try await seeded(fx)
        let steps = fx["steps"]?.array ?? []
        XCTAssertGreaterThanOrEqual(steps.count, 40)
        var problems: [String] = []
        for (i, s) in steps.enumerated() {
            let label = "\(i) \(s["method"]?.string ?? "") \(s["path"]?.string ?? "")"
            let r = await backend.handle(request(s))
            if r.status != s["status"]?.int {
                problems.append("\(label): Status \(r.status) statt \(s["status"]?.int ?? 0) – \(String(decoding: r.body.prefix(300), as: UTF8.self))")
                continue
            }
            if let d = jsonDiff(r.json, s["response"]) { problems.append("\(label): \(d)") }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        let t = try await tables(backend)
        XCTAssertNil(jsonDiff(t, fx["tables_after"]), jsonDiff(t, fx["tables_after"]) ?? "")
    }

    /// Uebersicht: Termine und freie Fenster von heute wie study.dashboard
    func testDashboardTodayMatchesPython() async throws {
        let fx = try fixture()
        let backend = try await seeded(fx)
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/dashboard"))
        let today = try XCTUnwrap(r.json?["today"])
        XCTAssertNil(jsonDiff(today["events"], fx["dashboard_today"]?["events"]), jsonDiff(today["events"], fx["dashboard_today"]?["events"]) ?? "")
        XCTAssertNil(jsonDiff(today["free"], fx["dashboard_today"]?["free"]), jsonDiff(today["free"], fx["dashboard_today"]?["free"]) ?? "")
        XCTAssertEqual(today["events"]?.array?.count, 1, "Sonntagstermin am Tag der Zeitumstellung")
    }

    /// Kalenderdateien: UTC, TZID (Berlin, UTC, Windows-Name, New York, unbekannt), RRULE mit UNTIL/INTERVAL,
    /// EXDATE, ganztags, gefaltete Zeilen, kaputte Termine
    func testICSMatchesPython() throws {
        let cases = try fixture()["ics"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        for c in cases {
            let name = c["name"]?.string ?? ""
            if name == "tzid-newyork" || name == "exdate", TimeZone(identifier: "America/New_York") == nil { continue }  // Linux ohne Zonen
            let got: JSONValue = .array(LocalTimetableImport.parseICS(c["text"]?.string ?? "").map(JSONValue.object))
            XCTAssertNil(jsonDiff(got, c["entries"]), "\(name): \(jsonDiff(got, c["entries"]) ?? "")")
        }
    }

    /// Derselbe difflib-Port wie fuer die Module (`SequenceMatcher` in ModuleGuess.swift, auch gegen
    /// study-modules.json geprueft)
    func testSequenceMatcherMatchesPython() throws {
        let cases = try fixture()["matcher"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for c in cases {
            let a = c["a"]?.string ?? "", b = c["b"]?.string ?? ""
            XCTAssertEqual(SequenceMatcher(a, b).ratio(), c["ratio"]?.double, "\(a.prefix(20)) / \(b.prefix(20))")
        }
    }

    /// LSF-Export der Uni Hildesheim (packages/shared-contracts/fixtures/hildesheim, Erwartungen aus Python): der
    /// Wochentag kommt aus BYDAY, mehrere BYDAY werden mehrere Serien mit ihren Ausfaellen. Verglichen werden die
    /// Felder von `parse_ics`; Nummer, Titel und Lehrende trennt erst `lsf.split_summary` (nicht portiert).
    func testHildesheimLSFExportMatchesPython() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("packages/shared-contracts/fixtures/hildesheim")
        let expected = try JSONValue.parse(Data(contentsOf: dir.appendingPathComponent("expected.json")))
        let keys = ["weekday", "start_time", "end_time", "rrule", "date_from", "date_to", "exdates"]
        for name in ["lsf-course.ics", "lsf-plan.ics"] {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            let got: [JSONValue] = LocalTimetableImport.parseICS(text).map { e in .object(e.filter { keys.contains($0.key) }) }
            let want: [JSONValue] = (expected[name]?.array ?? []).map { e in .object((e.object ?? [:]).filter { keys.contains($0.key) }) }
            XCTAssertFalse(want.isEmpty, name)
            XCTAssertNil(jsonDiff(.array(got), .array(want)), "\(name): \(jsonDiff(.array(got), .array(want)) ?? "")")
        }
    }

    func testGuessModuleMatchesPython() async throws {
        let fx = try fixture()
        let backend = try await seeded(fx)
        for c in fx["guess_module"]?.array ?? [] {
            let title = c["title"]?.string ?? ""
            let got = try await backend.context.database.withConnection { try LocalTimetableImport.guessModule($0, title: title) }
            XCTAssertEqual(got, c["module_id"], title)
        }
    }

    func testMergeWeeklyMatchesPython() throws {
        for c in try fixture()["merge_weekly"]?.array ?? [] {
            let entries = (c["entries"]?.array ?? []).compactMap(\.object)
            let got: JSONValue = .array(try LocalTimetableImport.mergeWeekly(entries).map(JSONValue.object))
            XCTAssertNil(jsonDiff(got, c["merged"]), jsonDiff(got, c["merged"]) ?? "")
        }
    }

    /// auto_import wie nach dem Stud.IP-Abgleich: eindeutige Termine uebernehmen, parallele Gruppen bleiben offen;
    /// ein zweiter Lauf legt nichts doppelt an. Ein eben gespeicherter Kurs mit Fach (extra_seed) bekommt vorher sein
    /// Modul (ensure_modules), seine Termine damit auch.
    func testAutoImportMatchesPython() async throws {
        let fx = try fixture()
        let backend = try await seeded(fx)
        let expect = fx["auto_import"] ?? .null
        let extra = expect["extra_seed"]?.array ?? []
        XCTAssertFalse(extra.isEmpty)
        let (first, second, modules) = try await backend.context.database.transaction { c -> (JSONValue, JSONValue, JSONValue) in
            try c.execute("DELETE FROM course_events")
            for s in extra {
                try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null })
            }
            let a = try LocalTimetableImport.autoImport(c, clock: clock), b = try LocalTimetableImport.autoImport(c, clock: clock)
            return (a, b, .array(try c.rows("SELECT * FROM modules ORDER BY id").map(JSONValue.object)))
        }
        XCTAssertEqual(first, expect["first"])
        XCTAssertEqual(second, expect["second"])
        let t = try await tables(backend)
        XCTAssertNil(jsonDiff(t, expect["tables"]), jsonDiff(t, expect["tables"]) ?? "")
        XCTAssertNil(jsonDiff(modules, expect["modules"]), jsonDiff(modules, expect["modules"]) ?? "")
        let neu = t["course_events"]?.array?.filter { $0["course_id"] == "k-neu" } ?? []
        XCTAssertEqual(neu.count, 1)
        XCTAssertEqual(neu.first?["module_id"], 4, "Modul des neuen Fachs")
    }

    // MARK: nur auf dem Geraet

    /// Import aus Text, PDF und Bild braucht KI: Antwort wie die anderen KI-Pfade, nichts wird gespeichert
    func testAIImportSourcesAnswerLikeDroppedAI() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        func form(_ fields: [String: String], file: (String, String)? = nil) -> LocalRequest {
            let b = "x-test"
            var body = ""
            for (k, v) in fields.sorted(by: { $0.key < $1.key }) { body += "--\(b)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n" }
            if let (name, content) = file {
                body += "--\(b)\r\nContent-Disposition: form-data; name=\"upload\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n\(content)\r\n"
            }
            body += "--\(b)--\r\n"
            return LocalRequest(method: "POST", path: "/api/timetable/import/preview", headers: ["Content-Type": "multipart/form-data; boundary=\(b)"], body: Data(body.utf8))
        }
        let cases: [(LocalRequest, Int, String)] = [
            (form(["source": "text", "text": "Montag 08:00 Mathe"]), 404, DroppedEndpoints.noAI),
            (form(["source": "pdf"]), 400, "PDF fehlt"),
            (form(["source": "pdf"], file: ("plan.pdf", "%PDF-1.4")), 404, DroppedEndpoints.noAI),
            (form(["source": "image"]), 400, "Bild fehlt"),
            (form(["source": "image"], file: ("plan.exe", "MZ")), 400, "Nur Bilddateien"),
            (form(["source": "image"], file: ("Plan.JPG", "x")), 404, DroppedEndpoints.noAI),
            (form(["source": "image"], file: ("plan", "x")), 404, DroppedEndpoints.noAI),
        ]
        for (req, status, message) in cases {
            let r = await backend.handle(req)
            XCTAssertEqual(r.status, status, message)
            XCTAssertEqual(r.json?["detail"]?.string, message)
        }
        let n = try await backend.context.database.scalar("SELECT COUNT(*) FROM schedule_imports")
        XCTAssertEqual(n, .integer(0))
    }

    func testConflictsValidateDays() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let bad = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/conflicts", query: [.init("days", "x")]))
        XCTAssertEqual(bad.status, 422)
        let huge = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/conflicts", query: [.init("days", "1000000")]))
        XCTAssertEqual(huge.status, 422)
        let none = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/conflicts", query: [.init("days", "-3")]))
        XCTAssertEqual(none.json, [])
    }

    func testOnlyReslotStaysPlaceholder() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let timetable = backend.router.allRoutes.filter { $0.pattern.template.hasPrefix("/api/timetable/") }
        XCTAssertEqual(Set(timetable.filter(\.placeholder).map(\.pattern.template)), ["/api/timetable/reslot"])
        XCTAssertGreaterThanOrEqual(timetable.filter { !$0.placeholder }.count, 14)
    }
}
