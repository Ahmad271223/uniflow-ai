import Foundation
import XCTest
@testable import UniFlowCore

// Lernlogik (S6) gegen die Python-Referenz: study-plan.json (tools/gen-study-fixture.py) mit eingefrorener Uhr
// (Freitag, 23.10.2026, 09:15 Europe/Berlin; der Plan laeuft ueber die Zeitumstellung am Sonntag; spaeter Mittwoch,
// 28.10.) und erfundenen Daten: Module, Stud.IP-Dateien, Analysen, Stundenplan, vergangene Lernpakete.

private func fixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/study-plan.json")))
}

/// Uhr, die der Test weiterstellen kann (Schritte mit "now" im Fixture)
private final class Now: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ local: String) { date = UniFlowClock.fixed(berlin: local)!.now }

    func set(_ local: String) { lock.withLock { date = UniFlowClock.fixed(berlin: local)!.now } }

    var clock: UniFlowClock { UniFlowClock { [self] in lock.withLock { date } } }
}

final class LocalStudyPlanTests: XCTestCase {

    private func params(_ v: JSONValue?) -> [SQLiteValue] { (v?.array ?? []).map { SQLiteValue(json: $0) ?? .null } }

    /// Lokales Backend mit denselben Seed-Daten wie der Generator
    private func seeded(_ fx: JSONValue, now: Now) async throws -> LocalBackend {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: now.clock)
        let seed = fx["seed"]?.array ?? []
        try await backend.context.database.transaction { c in
            for s in seed { try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null }) }
        }
        return backend
    }

    private func request(_ s: JSONValue) -> LocalRequest {
        let url = URL(string: "uniflow-local://device" + (s["path"]?.string ?? ""))!
        let body = s["body"].map { $0.serialized() }
        return LocalRequest(method: s["method"]?.string ?? "GET", url: url, headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body)
    }

    private func tables(_ backend: LocalBackend) async throws -> JSONValue {
        try await backend.context.database.withConnection { c -> JSONValue in
            var out: [String: JSONValue] = [:]
            for t in ["study_packages", "study_tasks", "task_history", "modules"] {
                out[t] = .array(try c.rows("SELECT * FROM \(t) ORDER BY id").map(JSONValue.object))
            }
            out["files"] = .array(try c.rows("SELECT id, status, seen_by_user FROM files ORDER BY id").map(JSONValue.object))
            return .object(out)
        }
    }

    /// Dieselben Anfragen in derselben Reihenfolge wie gegen app/server.py: Status und Antwort exakt gleich (Planen,
    /// Zeitslots neben Terminen, Uhrzeit von Hand, Abhaken, Verschieben, Woche retten, Machbarkeit, Uebersicht),
    /// danach dieselben Zeilen in study_packages, study_tasks, task_history, modules und files
    func testStepsMatchPythonServer() async throws {
        let fx = try fixture()
        let now = Now(try XCTUnwrap(fx["now"]?.string))
        let backend = try await seeded(fx, now: now)
        let steps = fx["steps"]?.array ?? []
        XCTAssertGreaterThanOrEqual(steps.count, 70)
        let problems = try await replay(steps, on: backend, now: now)
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        let t = try await tables(backend)
        XCTAssertNil(jsonDiff(t, fx["tables_after"]), jsonDiff(t, fx["tables_after"]) ?? "")
    }

    /// Korrekturen nach der Pruefung von S6 (Szenario "nachgebessert", eigene Datenbank mit demselben Seed, Mittwoch
    /// 28.10.): freies Fenster plant genau dort, Plan ab Montag ohne vergangene Tage, Uhrzeit von Hand endet nie vor
    /// der letzten Aufgabe, Verschieben mit freiem Fenster, "Uhrzeiten vergeben" behaelt Uhrzeiten von Hand, leere
    /// Pakete ohne Uhrzeit, Ersetzen nur automatischer, nicht begonnener und leerer Pakete
    func testFixScenarioMatchesPythonServer() async throws {
        let fx = try fixture()
        let scenario = try XCTUnwrap(fx["scenarios"]?.array?.first { $0["name"] == "nachgebessert" })
        let now = Now(try XCTUnwrap(scenario["now"]?.string))
        let backend = try await seeded(fx, now: now)
        let steps = scenario["steps"]?.array ?? []
        XCTAssertGreaterThanOrEqual(steps.count, 35)
        let problems = try await replay(steps, on: backend, now: now)
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        let t = try await tables(backend)
        XCTAssertNil(jsonDiff(t, scenario["tables_after"]), jsonDiff(t, scenario["tables_after"]) ?? "")
    }

    /// Regel des Inhabers vom 30.10.2026 (Szenario "lehrwoche", Mittwoch 28.10. = Lehrwoche 3): je Tag nur der Stoff
    /// seiner Lehrwoche, davor der Rest eines Skripts nach dem Marker der Vorwoche (eigene Marker, nicht geloescht,
    /// nicht zu pruefen, nur mit Marker in der Vorwoche), derselbe Rest je Lehrwoche einmal; `StudyPlan.autoPlanWeek`
    /// nach einem Abgleich ("auto"-Schritte)
    func testWeekRuleScenarioMatchesPythonServer() async throws {
        let fx = try fixture()
        let scenario = try XCTUnwrap(fx["scenarios"]?.array?.first { $0["name"] == "lehrwoche" })
        let now = Now(try XCTUnwrap(scenario["now"]?.string))
        let backend = try await seeded(fx, now: now)
        let steps = scenario["steps"]?.array ?? []
        XCTAssertGreaterThanOrEqual(steps.count, 14)
        XCTAssertGreaterThanOrEqual(steps.filter { $0["auto"] != nil }.count, 4)
        let problems = try await replay(steps, on: backend, now: now)
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        let t = try await tables(backend)
        XCTAssertNil(jsonDiff(t, scenario["tables_after"]), jsonDiff(t, scenario["tables_after"]) ?? "")
    }

    /// Schritte nacheinander an das lokale Backend; liefert die Abweichungen von Status und Antwort. "auto"-Schritte
    /// planen wie nach einem Abgleich (`StudyAutoPlan.afterSync`, am PC `study.auto_plan_week`).
    private func replay(_ steps: [JSONValue], on backend: LocalBackend, now: Now) async throws -> [String] {
        var problems: [String] = []
        for (i, s) in steps.enumerated() {
            if let n = s["auto"]?.int {
                let r = try await StudyAutoPlan.afterSync(backend, newFiles: n) ?? .null
                if let d = jsonDiff(r, s["result"] ?? .null) { problems.append("\(i) auto \(n): \(d)") }
                continue
            }
            if let t = s["now"]?.string {
                now.set(t)
                let sql = s["sql"]?.array ?? []
                try await backend.context.database.transaction { c in
                    for q in sql { try c.execute(q["sql"]?.string ?? "", (q["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null }) }
                }
                continue
            }
            let label = "\(i) \(s["method"]?.string ?? "") \(s["path"]?.string ?? "")"
            let r = await backend.handle(request(s))
            if r.status != s["status"]?.int {
                problems.append("\(label): Status \(r.status) statt \(s["status"]?.int ?? 0) – \(String(decoding: r.body.prefix(300), as: UTF8.self))")
                continue
            }
            if let d = jsonDiff(r.json, s["response"]) { problems.append("\(label): \(d)") }
        }
        return problems
    }

    /// `_derive_status` fuer alle Kombinationen der Aufgabenstatus, vergangen und nicht
    func testDeriveStatusMatchesPython() throws {
        let cases = try fixture()["derive_status"]?.array ?? []
        XCTAssertEqual(cases.count, 128)
        for c in cases {
            let statuses = (c["statuses"]?.array ?? []).map(\.string)
            let past = c["past"]?.bool ?? false
            XCTAssertEqual(StudyPlan.deriveStatus(statuses, past: past), c["status"]?.string, "\(statuses) \(past)")
        }
    }

    /// Abnahme S6 im Kern: "Plan erstellen" legt die Lernpakete in die freien Fenster neben die Termine des
    /// Stundenplans (Vorlesung, Sperrzeit, Fahrtzeit), nie in einen Termin. Mit den Unterlagen der Lehrwoche 3 (der
    /// Plan nimmt je Tag nur den Stoff seiner Lehrwoche, Regel vom 30.10.2026).
    func testPlanFillsFreeWindowsNextToEvents() async throws {
        let fx = try fixture()
        let now = Now(try XCTUnwrap(fx["now"]?.string))
        let backend = try await seeded(fx, now: now)
        let week3 = try XCTUnwrap(fx["steps"]?.array?.first { $0["now"]?.string == "2026-10-28T07:45:00" }?["sql"]?.array)
        try await backend.context.database.transaction { c in
            for q in week3 { try c.execute(q["sql"]?.string ?? "", (q["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null }) }
        }
        let gen = await backend.handle(LocalRequest(method: "POST", path: "/api/calendar/generate", body: Data(#"{"start": "2026-10-26", "days": 5}"#.utf8)))
        XCTAssertEqual(gen.status, 200)
        XCTAssertGreaterThan(gen.json?["created"]?.int ?? 0, 0)
        var checked = 0
        for day in ["2026-10-26", "2026-10-28", "2026-10-29", "2026-10-30"] {
            let r = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/day", query: [.init("date", day)]))
            let d = try XCTUnwrap(r.json)
            // Termine, dazu 20 Minuten Fahrt vor dem ersten und nach dem letzten (wie free_windows)
            var busy = try (d["events"]?.array ?? []).filter { $0["status"] == "teilnahme" }
                .map { (try LocalFreeWindows.hm($0["start"], key: "s"), try LocalFreeWindows.hm($0["end"], key: "e")) }.sorted { $0.0 < $1.0 }
            if let f = busy.first, let l = busy.last { busy += [(f.0 - 20, f.0), (l.1, l.1 + 20)] }
            for p in d["packages"]?.array ?? [] {
                guard let ps = p["start_time"]?.string, let pe = p["end_time"]?.string else { continue }
                let a = try LocalFreeWindows.hm(.string(ps), key: "s"), b = try LocalFreeWindows.hm(.string(pe), key: "e")
                for (es, ee) in busy { XCTAssertFalse(a < ee && b > es, "\(day): Paket \(ps)–\(pe) in einem Termin") }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 2)
        let conflicts = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/conflicts"))
        XCTAssertEqual(conflicts.json, [])
    }

    /// Alle Pfade der Lernlogik sind echte Endpunkte (keine Platzhalter mehr)
    func testStudyPathsAreRealEndpoints() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!)
        let real: [(String, String)] = [
            ("GET", "/api/calendar"), ("POST", "/api/calendar/generate"), ("GET", "/api/calendar/feasibility"), ("POST", "/api/calendar/suggest"),
            ("POST", "/api/calendar/apply"), ("GET", "/api/tasks/open"), ("POST", "/api/tasks/skip"), ("GET", "/api/tasks/history"),
            ("POST", "/api/tasks/1/status"), ("PATCH", "/api/tasks/1"), ("DELETE", "/api/tasks/1"), ("POST", "/api/packages"),
            ("GET", "/api/packages/1"), ("PATCH", "/api/packages/1"), ("DELETE", "/api/packages/1"), ("POST", "/api/packages/1/tasks"),
            ("POST", "/api/timetable/reslot"), ("GET", "/api/dashboard"),
        ]
        for (m, p) in real {
            let route = try XCTUnwrap(backend.route(method: m, path: p), "\(m) \(p)")
            XCTAssertFalse(route.placeholder, "\(m) \(p)")
            XCTAssertEqual(route.module, StudyEndpoints.name, "\(m) \(p)")
        }
        // Wochentests mit der KI des Nutzers (ChatGPT); ohne KI antwortet der Pfad weiter 404 (TestEndpointsTests)
        XCTAssertEqual(backend.route(method: "POST", path: "/api/tasks/1/start-test")?.module, TestEndpoints.name, "Wochentests mit KI")
    }

    /// Bewusste Abweichungen: falsche Datumsangaben 422 statt 500, Zeitraeume hoechstens 3660 Tage; eine fehlerhafte
    /// Anfrage aendert nichts (Transaktion)
    func testInvalidInputIs422AndChangesNothing() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!)
        func send(_ method: String, _ path: String, _ body: String? = nil, query: [LocalRequest.QueryItem] = []) async -> LocalResponse {
            await backend.handle(LocalRequest(method: method, path: path, query: query, body: body.map { Data($0.utf8) } ?? Data()))
        }
        let badDate = await send("POST", "/api/packages", #"{"date": "morgen"}"#)
        XCTAssertEqual(badDate.status, 422)
        let noDate = await send("POST", "/api/packages", #"{"title": "x"}"#)
        XCTAssertEqual(noDate.status, 422)
        let longCal = await send("GET", "/api/calendar", query: [.init("start", "2026-01-01"), .init("end", "2040-01-01")])
        XCTAssertEqual(longCal.status, 422)
        let longPlan = await send("POST", "/api/calendar/generate", #"{"days": 100000}"#)
        XCTAssertEqual(longPlan.status, 422)
        let badReslot = await send("POST", "/api/timetable/reslot", #"{"dates": ["kaputt"]}"#)
        XCTAssertEqual(badReslot.status, 422)
        let textReslot = await send("POST", "/api/timetable/reslot", #"{"dates": "2026-10-26"}"#)
        XCTAssertEqual(textReslot.status, 422)
        let badLimit = await send("GET", "/api/tasks/history", query: [.init("limit", "viele")])
        XCTAssertEqual(badLimit.status, 422)
        // ungueltige Uhrzeit: 400, der Titel aus derselben Anfrage bleibt ungespeichert
        let created = await send("POST", "/api/packages", #"{"date": "2026-10-26", "title": "Kapitel 1", "minutes": 30}"#)
        let id = try XCTUnwrap(created.json?["id"]?.int)
        let badTime = await send("PATCH", "/api/packages/\(id)", #"{"title": "neu", "start_time": "25:99"}"#)
        XCTAssertEqual(badTime.status, 400)
        XCTAssertEqual(badTime.json?["detail"], "Ungültige Uhrzeit: 25:99")
        let p = await send("GET", "/api/packages/\(id)")
        XCTAssertEqual(p.json?["title"], "Kapitel 1")
        XCTAssertEqual(p.json?["generated"], 0)
        XCTAssertEqual(p.json?["tasks"]?.array?.first?["type"], "frei")
        // Woche retten ohne Nachzuholendes, leere Planung
        let rescue = await send("POST", "/api/calendar/suggest", #"{"rescue": true}"#)
        XCTAssertEqual(rescue.json, ["moves": [], "message": "Keine offenen Aufgaben."])
        let plan = await send("POST", "/api/calendar/generate", "")
        XCTAssertEqual(plan.json?["message"], "Keine offenen Vorlesungen oder Übungen für diese Woche.")
    }

    /// Ohne Testaufgaben als Standard (Entscheidung 2): neue Datenbank mit tests_per_subject 0
    func testNewDatabasePlansWithoutTests() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!)
        let s = await backend.handle(LocalRequest(method: "GET", path: "/api/settings"))
        XCTAssertEqual(s.json?["tests_per_subject"], 0)
        let raw = try await backend.context.database.scalar("SELECT value FROM settings WHERE key='tests_per_subject'")
        XCTAssertEqual(raw, .text("0"))
    }
}
