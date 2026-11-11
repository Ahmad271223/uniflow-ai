import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// "Stopp" in der KI-Hilfe (Meldung des Inhabers 11.11.2026: "wenn man auf Stopp klickt bei KI wird sie nicht
/// gestoppt"). Gegen einen langsamen Schein-Transport (kein Netz, keine KI), der wie URLSession beim Abbruch
/// `URLError(.cancelled)` wirft: Stopp bricht die laufende Anfrage ab, zeigt keinen weiteren Teil, holt keinen weiteren
/// Teil und ist sofort wieder bereit. Bis 11.11.2026 setzte `TutorDocRunner.cancel` nur eine Marke, die erst vor dem
/// naechsten Teil gelesen wurde.
@MainActor
final class TutorStopAppTests: XCTestCase {

    /// Antwortet erst nach `delay` Sekunden; ein Abbruch endet sofort mit URLError(.cancelled)
    final class SlowTransport: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var cancelled = 0
        let delay: Double
        init(delay: Double = 3) { self.delay = delay }

        var callCount: Int { lock.withLock { calls } }
        var cancelCount: Int { lock.withLock { cancelled } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { calls += 1 }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                lock.withLock { cancelled += 1 }
                throw URLError(.cancelled)
            }
            let body: JSONValue = ["blocks": [["title": "Teil", "from": 1, "to": 2, "text": "Erklärung", "kind": "lecture"]],
                                   "stored": ["stored": false]]
            return (body.serialized(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let plan: JSONValue = [
        "intent": true, "mode": "lecture", "scope": ["kind": "all"], "confirm": false, "enough": true,
        "steps": [["id": "1:lecture:1-2", "kind": "lecture", "from": 1, "to": 2, "title": "Seiten 1–2"],
                  ["id": "2:lecture:3-4", "kind": "lecture", "from": 3, "to": 4, "title": "Seiten 3–4"],
                  ["id": "3:overview:1-4", "kind": "overview", "from": 1, "to": 4, "title": "Überblick"]],
    ]

    /// Plan ohne Netz: ein eigener Transport fuer /plan, der sofort antwortet
    final class PlanTransport: APITransport, @unchecked Sendable {
        let plan: JSONValue
        init(_ plan: JSONValue) { self.plan = plan }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            (plan.serialized(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func preparedRunner() async throws -> TutorDocRunner {
        let runner = TutorDocRunner()
        let planAPI = APIClient(base: URL(string: "http://erfunden.test/")!, transport: PlanTransport(plan))
        _ = try await runner.prepare(api: planAPI, fileID: "f-1", page: 1, mode: "lecture", scope: ["kind": "all"], question: nil)
        XCTAssertEqual(runner.steps.count, 3)
        return runner
    }

    private func waitForFirstCall(_ t: SlowTransport) async throws {
        let until = Date().addingTimeInterval(2)
        while t.callCount == 0 && Date() < until { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(t.callCount, 1, "der erste Teil laeuft")
    }

    /// Stopp-Knopf (`runner.cancel`) waehrend der erste Teil laeuft: Anfrage abgebrochen, nichts mehr angezeigt, kein
    /// weiterer Teil, sofort wieder bereit
    func testStopButtonCancelsTheRunningPartImmediately() async throws {
        let runner = try await preparedRunner()
        let slow = SlowTransport()
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: slow)
        var updates = 0
        let job = Task { @MainActor in try await runner.run(api: api) { _, _, _ in updates += 1 } }
        try await waitForFirstCall(slow)
        XCTAssertEqual(runner.phase, .running)

        let stoppedAt = Date()
        runner.cancel()
        XCTAssertEqual(runner.phase, .idle, "sofort bereit, nicht erst nach der Antwort")
        XCTAssertEqual(runner.progress, "")
        do {
            try await job.value
            XCTFail("der Lauf endet mit einem Abbruch")
        } catch is CancellationError {
        } catch {
            XCTFail("Abbruch statt Fehler: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(stoppedAt), 1, "die laufende Anfrage wartet nicht bis zum Ende")
        XCTAssertEqual(slow.cancelCount, 1, "die Anfrage selbst wurde abgebrochen (Task-Abbruch bis in den Transport)")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(updates, 0, "kein Teil erscheint nach dem Stopp")
        XCTAssertEqual(slow.callCount, 1, "kein weiterer Teil wird geholt (keine Credits fuer Teile 2 und 3)")
        XCTAssertEqual(runner.phase, .idle)
    }

    /// Stopp ueber die Aufgabe (KI-Hilfe: `stopAI` bricht die Aufgabe ab): ebenso ein Abbruch, kein Fehler "nicht erreichbar"
    func testCancellingTheTaskEndsTheRunAsCancellation() async throws {
        let runner = try await preparedRunner()
        let slow = SlowTransport()
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: slow)
        var updates = 0
        let job = Task { @MainActor in try await runner.run(api: api) { _, _, _ in updates += 1 } }
        try await waitForFirstCall(slow)
        job.cancel()
        do {
            try await job.value
            XCTFail("abgebrochen")
        } catch is CancellationError {
        } catch {
            XCTFail("Abbruch statt Fehler: \(error)")
        }
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(slow.callCount, 1)
        XCTAssertEqual(runner.phase, .idle)
    }

    /// Ohne Stopp laeuft der Lauf wie bisher durch (alle Teile, Fortschritt danach leer)
    func testWithoutStopAllPartsArrive() async throws {
        let runner = try await preparedRunner()
        let fast = SlowTransport(delay: 0)
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: fast)
        var lastCount = 0
        try await runner.run(api: api) { blocks, _, total in
            lastCount = blocks.count
            XCTAssertEqual(total, 3)
        }
        XCTAssertEqual(fast.callCount, 3)
        XCTAssertEqual(lastCount, 3)
        XCTAssertEqual(runner.phase, .idle)
    }

    /// Ein gestoppter alter Lauf, der spaet zurueckkehrt, setzt einen neuen Lauf nicht auf "bereit"
    func testLateOldRunDoesNotEndTheNewRun() async throws {
        let runner = try await preparedRunner()
        let slow = SlowTransport()
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: slow)
        let old = Task { @MainActor in try await runner.run(api: api) { _, _, _ in } }
        try await waitForFirstCall(slow)
        runner.cancel()
        let second = SlowTransport()
        let api2 = APIClient(base: URL(string: "http://erfunden.test/")!, transport: second)
        let fresh = Task { @MainActor in try await runner.run(api: api2) { _, _, _ in } }
        try await waitForFirstCall(second)
        _ = try? await old.value
        XCTAssertEqual(runner.phase, .running, "der neue Lauf laeuft weiter")
        runner.cancel()
        _ = try? await fresh.value
        XCTAssertEqual(runner.phase, .idle)
    }
}
