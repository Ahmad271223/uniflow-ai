import Foundation
import XCTest
@testable import UniFlowCore

/// Audit P65-F7 (09.11.2026): System-Text der Wochentests nach der Hochschule der Datenbank wie `weekly.system_text`
/// (tests/test_audit_p58_87_ki.py). LUH bleibt byte-gleich (Store-Build 1.0, Fixture weekly.json), andere Hochschulen
/// ohne LUH und ohne fest vorgegebenes Fach.
final class WeeklySystemTextTests: XCTestCase {
    final class Recorder: AIProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        var systems: [String] { lock.withLock { seen } }
        func answer(system: String, prompt: String) async throws -> String {
            lock.withLock { seen.append(system) }
            return "{}"
        }
    }

    func testP65F7SystemTextPerUniversity() {
        XCTAssertEqual(Weekly.systemText(university: "luh"), Weekly.system)
        XCTAssertEqual(Weekly.systemText(university: nil), Weekly.system)
        XCTAssertEqual(Weekly.systemText(university: "gibtsnicht"), Weekly.system)
        XCTAssertTrue(Weekly.system.hasPrefix("Du erstellst Pruefungsaufgaben fuer ein Ingenieur-/Informatikstudium an der Leibniz Universitaet Hannover. Antworte ausschliesslich"))
        XCTAssertEqual(Weekly.systemText(university: "hildesheim"),
                       "Du erstellst Pruefungsaufgaben fuer ein Studium an der Universität Hildesheim. Das Fach ergibt sich aus Modul und Material. " + Weekly.systemRules)
        XCTAssertEqual(Weekly.systemText(university: " HSH "),
                       "Du erstellst Pruefungsaufgaben fuer ein Studium an der Hochschule Hannover. Das Fach ergibt sich aus Modul und Material. " + Weekly.systemRules)
    }

    func testP65F7AskUsesTheUniversityOfTheDatabase() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory)
        let ai = Recorder()
        b.context.ai.set(ai)
        _ = try await Weekly.ask(b.context, "P")
        _ = try await b.context.database.execute("UPDATE settings SET value='hildesheim' WHERE key='university'")
        _ = try await Weekly.ask(b.context, "P")
        XCTAssertEqual(ai.systems.first, Weekly.system)
        XCTAssertEqual(ai.systems.last, Weekly.systemText(university: "hildesheim"))
        XCTAssertFalse(ai.systems.last?.contains("Leibniz") ?? true)
    }
}

/// Audit P64-07 (09.11.2026) wie `test_p64_07_busy_ai_does_not_use_up_the_three_attempts`: "KI ausgelastet" der
/// StudiNow-KI (nichts berechnet) kostet keinen der drei Versuche; ein echter Fehler zaehlt weiter.
final class WeeklyBusyTests: XCTestCase {
    struct Busy: AIProvider {
        var code = "ai_provider_busy"
        func answer(system: String, prompt: String) async throws -> String {
            throw LocalHTTPError(status: 503, detail: ["detail": "Die KI ist gerade ausgelastet, bitte gleich noch einmal.", "code": .string(code)])
        }
    }

    struct Broken: AIProvider {
        func answer(system: String, prompt: String) async throws -> String { throw AIError("test", "keine Antwort") }
    }

    private func plan1(_ b: LocalBackend) async throws -> [String: JSONValue] {
        let rows = try await b.context.database.rows("SELECT status, attempts, lock_until, last_error FROM wt_plans WHERE id=1")
        return try XCTUnwrap(rows.first)
    }

    func testP64_07BusyKeepsAttemptsAndRetriesNextRun() async throws {
        let (b, _) = try await WeeklyFixtureTests.replay(throughStep: 16)
        for code in ["ai_provider_busy", "ai_overloaded", "ai_rate_limited", "duplicate_request", "ai_provider_busy"] {
            b.context.ai.set(Busy(code: code))
            let r = await WeeklyAutoTick.run(b.context)
            XCTAssertEqual(r, .ran("0 veröffentlicht, 1 wartend, 0 fehlgeschlagen, 0 Nachträge", changed: false), code)
        }
        let p = try await plan1(b)
        XCTAssertEqual(p["status"], "geplant")
        XCTAssertEqual(p["attempts"], .number(0))
        XCTAssertEqual(p["lock_until"], .null)
        XCTAssertTrue(p["last_error"]?.string?.contains("ausgelastet") == true, "\(p)")
        // Budget/Konfiguration und unbrauchbare Antworten bleiben echte Fehler
        b.context.ai.set(Busy(code: "ai_budget_exhausted"))
        _ = await WeeklyAutoTick.run(b.context)
        let budget = try await plan1(b)
        XCTAssertEqual(budget["attempts"], .number(1))
        b.context.ai.set(Broken())
        _ = await WeeklyAutoTick.run(b.context)
        let broken = try await plan1(b)
        XCTAssertEqual(broken["attempts"], .number(2))
    }
}

/// Audit P64-F7/P64-07 (09.11.2026): Wartezeit vor dem zweiten Versuch nach 503 "ausgelastet" mit Streuung (Jitter).
/// Vorher warteten alle abgewiesenen iPads genau Retry-After (3 bzw. 5 s) und kamen gleichzeitig wieder.
final class StudiNowAIBusyJitterTests: XCTestCase {
    func testWaitIsRetryAfterPlusUpToTheSameAgainAndBounded() {
        XCTAssertEqual(StudiNowAI.busyWait(retryAfter: 3, unit: 0), 3)
        XCTAssertEqual(StudiNowAI.busyWait(retryAfter: 3, unit: 1), 6)
        XCTAssertEqual(StudiNowAI.busyWait(retryAfter: 3, unit: 0.5), 4.5)
        XCTAssertEqual(StudiNowAI.busyWait(retryAfter: 5, unit: 1), StudiNowAI.busyRetryMaxSeconds)
        XCTAssertEqual(StudiNowAI.busyWait(retryAfter: nil, unit: 0), 2)
        XCTAssertEqual(StudiNowAI.busyWait(retryAfter: 0, unit: 1), 0, "Retry-After 0 (Tests): sofort")
        XCTAssertEqual(StudiNowAI.busyWait(retryAfter: 60, unit: 1), StudiNowAI.busyRetryMaxSeconds)
        let spread = Set((0..<200).map { _ in StudiNowAI.busyWait(retryAfter: 3) })
        XCTAssertGreaterThan(spread.count, 50, "gestreut, nicht alle gleich")
        XCTAssertTrue(spread.allSatisfy { (3...6).contains($0) })
    }
}
