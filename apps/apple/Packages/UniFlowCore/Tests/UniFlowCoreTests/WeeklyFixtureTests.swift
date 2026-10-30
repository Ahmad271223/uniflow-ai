import Foundation
import XCTest
@testable import UniFlowCore

/// Vorlesungs-Seitenmarker und gemeinsame Wochentests wie app/weekly.py: derselbe Ablauf wie
/// packages/shared-contracts/fixtures/local-backend/weekly.json (tools/gen-weekly-fixture.py) mit derselben Uhr und
/// derselben simulierten KI. Geprueft werden jede Antwort, jeder Prompt an die KI (byte-gleich) und am Ende die
/// Tabellen der Wochentests (JSON-Texte byte-gleich).
final class WeeklyFixtureTests: XCTestCase {

    private func fixtureData() throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/weekly.json"))
    }

    private func fixture() throws -> JSONValue { try JSONValue.parse(fixtureData()) }

    /// Anfragetexte in der Reihenfolge der Referenz (JSONValue kennt keine Reihenfolge der Schluessel)
    private func orderedBodies() throws -> [PyJSON?] {
        guard case .object(let root) = try PyJSON.parse(fixtureData()),
              case .array(let steps)? = root.first(where: { $0.key == "steps" })?.value else { return [] }
        return steps.map { s -> PyJSON? in
            guard case .object(let m) = s, let b = m.first(where: { $0.key == "body" })?.value, b != .null else { return nil }
            return b
        }
    }

    /// Uhr, die der Ablauf weiterstellt (Ortszeit Berlin wie die naive Zeit der Python-Referenz)
    final class Ticker: @unchecked Sendable {
        private let lock = NSLock()
        private var local = "2026-10-19T12:00:00"
        func set(_ s: String) { lock.withLock { local = s } }
        var clock: UniFlowClock {
            UniFlowClock { [self] in Date(timeIntervalSince1970: TimeInterval(BerlinClock.utcSeconds(localISO: lock.withLock { local })!)) }
        }
    }

    /// Die aufgezeichnete KI: jeder Aufruf muss genau den Prompt der Referenz senden
    final class RecordedAI: AIProvider, @unchecked Sendable {
        let calls: [JSONValue]
        private let lock = NSLock()
        private(set) var index = 0
        var mismatches: [String] = []
        init(_ calls: [JSONValue]) { self.calls = calls }
        func answer(system: String, prompt: String) async throws -> String {
            let i = lock.withLock { () -> Int in let i = index; index += 1; return i }
            guard i < calls.count else { lock.withLock { mismatches.append("Aufruf \(i + 1) zu viel: \(prompt.prefix(60))") }; throw AIError("test", "zu viele Aufrufe") }
            let c = calls[i]
            if c["prompt"]?.string != prompt { lock.withLock { mismatches.append("Prompt \(i + 1) weicht ab:\n\(diff(c["prompt"]?.string ?? "", prompt))") } }
            if c["system"]?.string != system { lock.withLock { mismatches.append("System \(i + 1) weicht ab") } }
            return c["answer"]?.string ?? ""
        }
        func diff(_ a: String, _ b: String) -> String {
            let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
            for k in 0..<max(x.count, y.count) where (k < x.count ? x[k] : nil) != (k < y.count ? y[k] : nil) {
                return "Zeile \(k + 1)\n  Python: \(k < x.count ? x[k] : "–")\n  Swift:  \(k < y.count ? y[k] : "–")"
            }
            return "Laenge \(a.count) gegen \(b.count)"
        }
    }

    private func sql(_ v: JSONValue) -> SQLiteValue {
        switch v {
        case .null: return .null
        case .string(let s): return .text(s)
        case .number(let d): return d == d.rounded() ? .integer(Int64(d)) : .real(d)
        case .bool(let b): return .integer(b ? 1 : 0)
        default: return .null
        }
    }

    private func run(_ b: LocalBackend, _ statements: [JSONValue]) async throws {
        try await b.context.database.transaction { c in
            for s in statements {
                guard let a = s.array, let q = a.first?.string else { continue }
                try c.execute(q, (a.dropFirst().first?.array ?? []).map(sql))
            }
        }
    }

    private func request(_ method: String, _ full: String, _ body: PyJSON?) -> LocalRequest {
        let parts = full.split(separator: "?", maxSplits: 1).map(String.init)
        let query: [LocalRequest.QueryItem] = parts.count > 1 ? parts[1].split(separator: "&").map { kv in
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
            return .init(PyText.unquotePlus(p[0]), PyText.unquotePlus(p.count > 1 ? p[1] : ""))
        } : []
        let data = body.map { Data($0.dumps(ensureASCII: false).utf8) } ?? Data()
        return LocalRequest(method: method, path: parts[0], query: query, body: data)
    }

    /// Fehlerantworten: gleiche Meldung (FastAPI `detail`)
    private func comparable(_ v: JSONValue?) -> JSONValue { v ?? .null }

    func testFlowMatchesPythonServer() async throws {
        let fx = try fixture()
        let ticker = Ticker()
        ticker.set(fx["start"]?.string ?? "2026-10-19T12:00:00")
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: ticker.clock)
        let ai = RecordedAI(fx["ai"]?.array ?? [])
        b.context.ai.set(ai)
        try await run(b, fx["seed"]?.array ?? [])
        let bodies = try orderedBodies()
        for (n, step) in (fx["steps"]?.array ?? []).enumerated() {
            let now = step["now"]?.string ?? ""
            ticker.set(now)
            let label = "Schritt \(n + 1) \(step["op"]?.string ?? "") \(step["method"]?.string ?? "") \(step["path"]?.string ?? "")"
            switch step["op"]?.string {
            case "http":
                let r = await b.handle(request(step["method"]?.string ?? "GET", step["path"]?.string ?? "", n < bodies.count ? bodies[n] : nil))
                XCTAssertEqual(r.status, step["status"]?.int, label + " " + (r.json?.jsonString() ?? ""))
                XCTAssertEqual(comparable(r.json), comparable(step["response"]), label)
            case "tick":
                let res = try await Weekly.tick(b.context, now: Weekly.seconds(now))
                XCTAssertEqual(res, step["result"], label)
            case "sql":
                try await run(b, step["sql"]?.array ?? [])
            case "mock":
                let res = try await Weekly.createMockExam(b.context, moduleID: step["module_id"]?.int ?? 0, full: step["full"]?.bool ?? false,
                                                          now: Weekly.seconds(now))
                let want = step["result"]
                XCTAssertEqual(res["test_id"], want?["test_id"], label)
                XCTAssertEqual(res["blueprint"], want?["blueprint"], label)
                XCTAssertEqual(res["reused"], want?["reused"], label)
                XCTAssertEqual(res["def"]?["id"], want?["def_id"], label)
            default:
                XCTFail("unbekannter Schritt \(label)")
            }
            // Hintergrundauftraege (Abgabe) abwarten
            while (await b.context.jobs.state["running"]?.bool) == true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertEqual(ai.index, fx["ai"]?.array?.count, "gleich viele KI-Aufrufe")
        XCTAssertTrue(ai.mismatches.isEmpty, ai.mismatches.joined(separator: "\n\n"))
        for (table, rows) in fx["tables"]?.object ?? [:] {
            let order = ["lecture_markers": "id", "doc_index": "file_id", "task_index": "file_id, nr", "wt_plans": "id", "wt_defs": "id", "tests": "id"][table] ?? "rowid"
            var mine = try await b.context.database.rows("SELECT * FROM \(table) ORDER BY \(order)")
            let want = rows.array ?? []
            let cols = Set(want.first?.object?.keys.map { $0 } ?? [])
            mine = mine.map { r in r.filter { cols.contains($0.key) } }
            XCTAssertEqual(mine.count, want.count, "Zeilen in \(table)")
            for (i, (a, w)) in zip(mine, want).enumerated() {
                for k in cols.sorted() where a[k] ?? .null != w[k] ?? .null {
                    XCTFail("\(table)[\(i)].\(k):\n  Python: \((w[k] ?? .null).jsonString().prefix(400))\n  Swift:  \((a[k] ?? .null).jsonString().prefix(400))")
                }
            }
        }
    }

    /// `task_scope`: nur Vorlesungsseiten mit mindestens 60 % der besten Trefferguete muessen behandelt sein; eine
    /// schwach passende spaetere Seite (55 %) sperrt die Aufgabe nicht, eine stark passende (65 %) schon
    func testTaskScopeStrongThreshold() {
        let covered: Set<Weekly.PageKey> = [.init(file: "f", page: 1)]
        func task(_ second: Double) -> [String: JSONValue] {
            ["lecture_refs": .string(#"[{"file_id": "f", "page": 1, "score": 10.0}, {"file_id": "f", "page": 50, "score": \#(second)}]"#)]
        }
        let weak = Weekly.taskScope(task(5.5), covered: covered, newPages: covered, twin: nil)
        XCTAssertTrue(weak.ok)
        XCTAssertTrue(weak.new)
        let strong = Weekly.taskScope(task(6.5), covered: covered, newPages: covered, twin: nil)
        XCTAssertFalse(strong.ok)
        XCTAssertEqual(strong.reason, "braucht noch nicht behandelte Seite(n) 50")
        let twin = Weekly.taskScope(task(6.5), covered: covered, newPages: covered) { _ in .init(file: "g", page: 3) }
        XCTAssertTrue(twin.ok, "nahezu gleiche behandelte Seite (anderes Semester) zaehlt")
        XCTAssertEqual(Weekly.taskScope(["lecture_refs": "[]"], covered: covered, newPages: covered, twin: nil).reason,
                       "kein sicherer Bezug zu Vorlesungsseiten")
    }

    func testSHA1LikePython() {
        XCTAssertEqual(WeeklySHA1.hex(Data()), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(WeeklySHA1.hex("Grüße"), "f649751d6e1bb46f8c86a8e0300237c33df07074")
        XCTAssertEqual(WeeklySHA1.hex(String(repeating: "a", count: 1000)), "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    func testISOWeekAndRounding() {
        let d = BerlinClock.parseISODate("2026-10-19")!
        XCTAssertEqual(Weekly.isoWeekText(d), "2026-W43")
        XCTAssertEqual(Weekly.isoWeekText(BerlinClock.parseISODate("2027-01-01")!), "2026-W53")
        XCTAssertEqual(Weekly.isoWeekText(BerlinClock.parseISODate("2024-12-30")!), "2025-W01")
        XCTAssertEqual(Weekly.round2(2.675), 2.67, "wie Python round(2.675, 2)")
        XCTAssertEqual(Weekly.iso(Weekly.seconds("2026-10-20T11:30:00")! + 86_400), "2026-10-21T11:30:00")
    }
}

/// Takt auf dem iPad (`WeeklyAutoTick`) wie `_weekly_loop` am PC: aus mit `auto_tests` = 0, ohne KI kein Lauf (kein
/// verbrauchter Versuch), nicht neben einem anderen Hintergrundauftrag
final class WeeklyAutoTickTests: XCTestCase {
    struct NoAnswer: AIProvider {
        func answer(system: String, prompt: String) async throws -> String { throw AIError("test", "keine Antwort") }
    }

    private func backend() async throws -> LocalBackend {
        let ticker = WeeklyFixtureTests.Ticker()
        ticker.set("2026-10-21T12:00:00")
        return try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: ticker.clock)
    }

    func testOffWithoutAutoTests() async throws {
        let b = try await backend()
        b.context.ai.set(NoAnswer())
        _ = try await b.context.database.execute("INSERT OR REPLACE INTO settings(key, value) VALUES('auto_tests', '0')")
        let r = await WeeklyAutoTick.run(b.context)
        XCTAssertEqual(r, .off)
    }

    func testNoAIKeepsAttempts() async throws {
        let b = try await backend()
        _ = try await b.context.database.execute("""
            INSERT INTO wt_plans(module_id, week_no, scope, scope_key, coverage, lecture_end, publish_at, deadline_at, attempts)
            VALUES(1, 1, 'personal', 'k', '{}', '2026-10-20T10:00:00', '2026-10-20T11:00:00', '2026-10-22T11:00:00', 0)
            """)
        let r = await WeeklyAutoTick.run(b.context)
        XCTAssertEqual(r, .noAI)
        let attempts = try await b.context.database.rows("SELECT attempts FROM wt_plans").first?["attempts"]
        XCTAssertEqual(attempts, .number(0))
    }

    func testBusyWhileAnotherJobRuns() async throws {
        let b = try await backend()
        b.context.ai.set(NoAnswer())
        _ = try await b.context.jobs.start("Test erstellen") { try await Task.sleep(nanoseconds: 400_000_000); return nil }
        let busy = await WeeklyAutoTick.run(b.context)
        XCTAssertEqual(busy, .busy)
        while (await b.context.jobs.state["running"]?.bool) == true { try await Task.sleep(nanoseconds: 20_000_000) }
        let ran = await WeeklyAutoTick.run(b.context)
        XCTAssertEqual(ran, .ran("0 veröffentlicht, 0 wartend, 0 fehlgeschlagen, 0 Nachträge", changed: false))
    }
}
