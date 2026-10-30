import Foundation
import XCTest
@testable import UniFlowCore

/// Vorlesungs-Seitenmarker und gemeinsame Wochentests wie app/weekly.py: derselbe Ablauf wie
/// packages/shared-contracts/fixtures/local-backend/weekly.json (tools/gen-weekly-fixture.py) mit derselben Uhr und
/// derselben simulierten KI. Geprueft werden jede Antwort, jeder Prompt an die KI (byte-gleich) und am Ende die
/// Tabellen der Wochentests (JSON-Texte byte-gleich).
final class WeeklyFixtureTests: XCTestCase {

    fileprivate static func fixtureData() throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/weekly.json"))
    }

    fileprivate static func fixture() throws -> JSONValue { try JSONValue.parse(fixtureData()) }

    /// Anfragetexte in der Reihenfolge der Referenz (JSONValue kennt keine Reihenfolge der Schluessel)
    fileprivate static func orderedBodies() throws -> [PyJSON?] {
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

    private static func sql(_ v: JSONValue) -> SQLiteValue {
        switch v {
        case .null: return .null
        case .string(let s): return .text(s)
        case .number(let d): return d == d.rounded() ? .integer(Int64(d)) : .real(d)
        case .bool(let b): return .integer(b ? 1 : 0)
        default: return .null
        }
    }

    fileprivate static func run(_ b: LocalBackend, _ statements: [JSONValue]) async throws {
        try await b.context.database.transaction { c in
            for s in statements {
                guard let a = s.array, let q = a.first?.string else { continue }
                try c.execute(q, (a.dropFirst().first?.array ?? []).map(sql))
            }
        }
    }

    fileprivate static func request(_ method: String, _ full: String, _ body: PyJSON?) -> LocalRequest {
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

    /// Ablauf der Referenz bis einschliesslich Schritt `n` (ohne die reinen `background`-Pruefungen) mit der
    /// aufgezeichneten KI; die Uhr steht danach auf der Zeit des Schritts `n`. Fuer Tests, die mitten im Ablauf etwas
    /// anderes tun (Abbruch, Entscheidung fuer die App).
    fileprivate static func replay(throughStep n: Int) async throws -> (LocalBackend, Ticker) {
        let fx = try Self.fixture()
        let ticker = Ticker()
        ticker.set(fx["start"]?.string ?? "2026-10-19T12:00:00")
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: ticker.clock)
        b.context.ai.set(RecordedAI(fx["ai"]?.array ?? []))
        try await Self.run(b, fx["seed"]?.array ?? [])
        let bodies = try Self.orderedBodies()
        for (i, step) in (fx["steps"]?.array ?? []).prefix(n).enumerated() {
            let now = step["now"]?.string ?? ""
            ticker.set(now)
            switch step["op"]?.string {
            case "http":
                let r = await b.handle(Self.request(step["method"]?.string ?? "GET", step["path"]?.string ?? "", i < bodies.count ? bodies[i] : nil))
                XCTAssertEqual(r.status, step["status"]?.int, "Schritt \(i + 1)")
            case "tick": _ = try await Weekly.tick(b.context, now: Weekly.seconds(now))
            case "sql": try await Self.run(b, step["sql"]?.array ?? [])
            default: break
            }
            while (await b.context.jobs.state["running"]?.bool) == true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        return (b, ticker)
    }

    func testFlowMatchesPythonServer() async throws {
        let fx = try Self.fixture()
        let ticker = Ticker()
        ticker.set(fx["start"]?.string ?? "2026-10-19T12:00:00")
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: ticker.clock)
        let ai = RecordedAI(fx["ai"]?.array ?? [])
        b.context.ai.set(ai)
        try await Self.run(b, fx["seed"]?.array ?? [])
        let bodies = try Self.orderedBodies()
        for (n, step) in (fx["steps"]?.array ?? []).enumerated() {
            let now = step["now"]?.string ?? ""
            ticker.set(now)
            let label = "Schritt \(n + 1) \(step["op"]?.string ?? "") \(step["method"]?.string ?? "") \(step["path"]?.string ?? "")"
            switch step["op"]?.string {
            case "http":
                let r = await b.handle(Self.request(step["method"]?.string ?? "GET", step["path"]?.string ?? "", n < bodies.count ? bodies[n] : nil))
                XCTAssertEqual(r.status, step["status"]?.int, label + " " + (r.json?.jsonString() ?? ""))
                XCTAssertEqual(comparable(r.json), comparable(step["response"]), label)
            case "tick":
                let res = try await Weekly.tick(b.context, now: Weekly.seconds(now))
                XCTAssertEqual(res, step["result"], label)
            case "sql":
                try await Self.run(b, step["sql"]?.array ?? [])
            case "background":
                let nowSeconds = Weekly.seconds(now) ?? 0
                let snap = try await b.context.database.withConnection { c in try WeeklyBackground.snapshot(c, now: nowSeconds) }
                XCTAssertEqual(snap, step["snapshot"], label)
                let decision = WeeklyBackground.decide(snap, now: nowSeconds, ai: step["ai"]?.bool ?? true, busy: step["busy"]?.bool ?? false)
                XCTAssertEqual(decision, step["decision"], label)
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
            let order = ["lecture_markers": "id", "doc_index": "file_id", "task_index": "file_id, nr", "wt_plans": "id", "wt_defs": "id", "tests": "id", "study_tasks": "id"][table] ?? "rowid"
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

    /// `background_decision` wie Python fuer alle Faelle ohne Datenbank (Termingrenzen, Monats- und Jahreswechsel,
    /// Zeitumstellung, Sperre, Versuche, Tageslimit, aus/keine KI/beschaeftigt)
    func testBackgroundCasesMatchPython() throws {
        let cases = try Self.fixture()["background_cases"]?.array ?? []
        XCTAssertGreaterThan(cases.count, 0, "background_cases fehlen")
        for c in cases {
            let name = c["name"]?.string ?? "?"
            let now = try XCTUnwrap(Weekly.seconds(c["now"]?.string ?? ""), name)
            let got = WeeklyBackground.decide(c["snapshot"] ?? .null, now: now, ai: c["ai"]?.bool ?? true, busy: c["busy"]?.bool ?? false)
            XCTAssertEqual(got, c["decision"], "Fall \(name) (\(c["now"]?.string ?? ""), ai=\(c["ai"]?.bool ?? true), busy=\(c["busy"]?.bool ?? false))")
        }
    }

    /// `WeeklyBackground.nextSlot` (naive Ortszeit) trifft dieselbe Ortszeit wie `BackgroundSchedule.next` (Date mit
    /// Zeitzone Europe/Berlin), auch um die Zeitumstellung
    func testBackgroundSlotsMatchBackgroundSchedule() throws {
        guard let tz = TimeZone(identifier: "Europe/Berlin") else { throw XCTSkip("keine Zeitzonendatenbank") }
        let times = ["2026-10-20T07:59:59", "2026-10-20T08:00:00", "2026-10-20T14:59:59", "2026-10-20T15:00:00",
                     "2026-10-20T19:59:00", "2026-10-20T20:00:00", "2026-10-20T23:30:00", "2026-10-24T22:00:00",
                     "2026-10-25T01:30:00", "2026-10-25T03:30:00", "2026-03-28T23:00:00", "2026-03-29T01:59:00",
                     "2026-12-31T21:00:00", "2026-10-31T19:00:00"]
        for t in times {
            let naive = try XCTUnwrap(Weekly.seconds(t), t)
            let day = Weekly.today(naive), rest = naive - day * 86_400
            // BerlinClock rechnet in Minuten; die Sekunden kommen unveraendert dazu (keine Testzeit liegt in der doppelten
            // oder fehlenden Stunde)
            let utc = BerlinClock.utcSeconds(day: day, minutes: rest / 60) + rest % 60
            let next = BackgroundSchedule.next(after: Date(timeIntervalSince1970: TimeInterval(utc)), timeZone: tz)
            let l = BerlinClock.local(utc: Int(next.timeIntervalSince1970))
            XCTAssertEqual(Weekly.iso(WeeklyBackground.nextSlot(naive)), Weekly.iso(l.day * 86_400 + l.minutes * 60), "nach \(t)")
        }
        XCTAssertEqual(WeeklyBackground.hours, BackgroundSchedule.hours)
        XCTAssertEqual(Weekly.iso(WeeklyBackground.slot(atOrAfter: Weekly.seconds("2026-10-20T08:00:00")!)), "2026-10-20T08:00:00")
        XCTAssertEqual(Weekly.iso(WeeklyBackground.nextSlot(Weekly.seconds("2026-10-20T08:00:00")!)), "2026-10-20T15:00:00")
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

    /// KI, deren Anfrage abgebrochen wird (iOS beendet die Hintergrundzeit, `URLSession` wirft `cancelled`)
    struct Cancelled: AIProvider {
        var asURLError = false
        func answer(system: String, prompt: String) async throws -> String {
            if asURLError { throw URLError(.cancelled) }
            throw CancellationError()
        }
    }

    /// KI, die wie `ChatGPTSession.complete` jeden Transportfehler als `AIError` meldet und erst antwortet, wenn der
    /// Task abgebrochen ist
    final class WaitsForCancel: AIProvider, @unchecked Sendable {
        func answer(system: String, prompt: String) async throws -> String {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            throw AIError("chatgpt_network", "Keine Verbindung zu OpenAI.")
        }
    }

    private func plan1(_ b: LocalBackend) async throws -> [String: JSONValue] {
        let rows = try await b.context.database.rows("SELECT status, attempts, lock_until, lock_token, last_error FROM wt_plans WHERE id=1")
        return try XCTUnwrap(rows.first)
    }

    /// Abbruch durch iOS kostet keinen Versuch: Plan 1 der Referenz ist am 20.10. um 11:31 faellig (Schritt 17 wuerde
    /// ihn mit der KI erzeugen). Bricht die KI-Anfrage ab, bleiben Status, `attempts` und `last_error`, die Sperre ist
    /// geloest; ein echter Fehler zaehlt weiter einen Versuch.
    func testCancellationKeepsAttemptsAndReleasesTheLock() async throws {
        for provider in [Cancelled(), Cancelled(asURLError: true)] {
            let (b, _) = try await WeeklyFixtureTests.replay(throughStep: 16)
            let before = try await plan1(b)
            XCTAssertEqual(before["status"], "geplant")
            XCTAssertEqual(before["attempts"], .number(0))
            b.context.ai.set(provider)
            let r = await WeeklyAutoTick.run(b.context)
            XCTAssertEqual(r, .cancelled, "\(provider)")
            let after = try await plan1(b)
            XCTAssertEqual(after["status"], "geplant", "\(provider)")
            XCTAssertEqual(after["attempts"], .number(0), "\(provider)")
            XCTAssertEqual(after["lock_until"], .null, "Sperre geloest: \(provider)")
            XCTAssertEqual(after["lock_token"], .null, "\(provider)")
            XCTAssertEqual(after["last_error"], before["last_error"], "\(provider)")
            // `Weekly.tick` selbst wirft den Abbruch weiter (die Referenz kennt nur published/waiting/failed)
            do {
                _ = try await Weekly.tick(b.context)
                XCTFail("Abbruch muss weitergehen: \(provider)")
            } catch {
                XCTAssertTrue(Weekly.isCancellation(error), "\(error)")
            }
            let still = try await plan1(b)
            XCTAssertEqual(still["attempts"], .number(0))
            // ein echter Fehler der KI zaehlt wie bisher
            b.context.ai.set(NoAnswer())
            let failed = await WeeklyAutoTick.run(b.context)
            XCTAssertEqual(failed, .ran("0 veröffentlicht, 0 wartend, 1 fehlgeschlagen, 0 Nachträge", changed: false))
            let counted = try await plan1(b)
            XCTAssertEqual(counted["status"], "fehlgeschlagen")
            XCTAssertEqual(counted["attempts"], .number(1))
            XCTAssertEqual(counted["lock_until"], .null)
        }
    }

    /// Abbruch des Tasks (`BackgroundTaskRun.expire` -> `Task.cancel`), waehrend die Anbindung den Fehler als
    /// `AIError` verpackt: im abgebrochenen Task gilt er nicht als Fehler des Plans
    func testTaskCancellationDuringTheAIRequestKeepsAttempts() async throws {
        let (b, _) = try await WeeklyFixtureTests.replay(throughStep: 16)
        b.context.ai.set(WaitsForCancel())
        let ctx = b.context
        let run = Task { await WeeklyAutoTick.run(ctx) }
        // warten, bis der Plan belegt ist (die KI-Anfrage laeuft)
        var locked = false
        for _ in 0..<400 where !locked {
            try await Task.sleep(nanoseconds: 10_000_000)
            locked = try await plan1(b)["lock_token"] != .null
        }
        XCTAssertTrue(locked, "Plan 1 wurde belegt")
        run.cancel()
        let r = await run.value
        XCTAssertEqual(r, .cancelled)
        let after = try await plan1(b)
        XCTAssertEqual(after["status"], "geplant")
        XCTAssertEqual(after["attempts"], .number(0))
        XCTAssertEqual(after["lock_until"], .null)
        XCTAssertEqual(after["lock_token"], .null)
        // ein schon abgebrochener Task belegt gar nicht erst
        let early = Task { await WeeklyAutoTick.run(ctx) }
        early.cancel()
        let earlyOutcome = await early.value
        XCTAssertEqual(earlyOutcome, .cancelled)
        let untouched = try await plan1(b)
        XCTAssertEqual(untouched["attempts"], .number(0))
    }

    /// `WeeklyBackground.decision` und `date` fuer die App: dieselbe Antwort wie Schritt 15/16 der Referenz, `next_at`
    /// als Zeitpunkt (20.10.2026 15:00 Berlin = 13:00 UTC), `ai`/`busy` aus dem Kontext
    func testDecisionAndDateForTheApp() async throws {
        let (b, _) = try await WeeklyFixtureTests.replay(throughStep: 16)
        b.context.ai.set(nil)
        let noAI = try await WeeklyBackground.decision(b.context)
        XCTAssertEqual(noAI, WeeklyBackground.Decision(action: "no_ai", due: [1], nextAt: Date(timeIntervalSince1970: 1_792_501_200)))
        b.context.ai.set(NoAnswer())
        let run = try await WeeklyBackground.decision(b.context)
        XCTAssertEqual(run.action, "run")
        let busy = try await WeeklyBackground.decision(b.context, busy: true)
        XCTAssertEqual(busy.action, "busy")
        let forcedNoAI = try await WeeklyBackground.decision(b.context, ai: false)
        XCTAssertEqual(forcedNoAI.action, "no_ai")
        _ = try await b.context.database.execute("INSERT OR REPLACE INTO settings(key, value) VALUES('auto_tests', '0')")
        let off = try await WeeklyBackground.decision(b.context)
        XCTAssertEqual(off, WeeklyBackground.Decision(action: "off"))
        XCTAssertEqual(WeeklyBackground.date("2026-10-26T15:00:00"), Date(timeIntervalSince1970: 1_793_023_200), "Winterzeit")
        XCTAssertEqual(WeeklyBackground.date("2026-10-20T15:00:00"), Date(timeIntervalSince1970: 1_792_501_200), "Sommerzeit")
        XCTAssertNil(WeeklyBackground.date("bald"))
        XCTAssertEqual(BackgroundNotice.weeklyTest.title, "Neuer Wochentest verfügbar")
        XCTAssertFalse(BackgroundNotice.weeklyTest.body.contains("Prog"), "kein Fach, kein Inhalt")
    }
}
