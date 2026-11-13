import Foundation
import XCTest
@testable import UniFlowCore

/// Abgleich nach Aenderungen buendeln (`DeviceSyncKicker`, Plan "Ein Konto, alle Geraete" Schritt 1). Die Uhr stellt
/// der Test; jedes Warten bleibt haengen, bis der Test es freigibt.
final class DeviceSyncKickTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 0
        private var waiting: [(TimeInterval, CheckedContinuation<Void, Error>)] = []
        private(set) var runs: [TimeInterval] = []

        var time: TimeInterval {
            get { lock.withLock { t } }
            set { lock.withLock { t = newValue } }
        }
        var now: Date { Date(timeIntervalSince1970: time) }
        var sleeps: [TimeInterval] { lock.withLock { waiting.map(\.0) } }
        func add(_ d: TimeInterval, _ c: CheckedContinuation<Void, Error>) { lock.withLock { waiting.append((d, c)) } }
        func ran() { lock.withLock { runs.append(t) } }
        /// alle Wartenden aufwecken
        func fire() { let w = lock.withLock { let w = waiting; waiting = []; return w }; w.forEach { $0.1.resume() } }
    }

    private func make(_ clock: Clock, during: (@Sendable () async -> Void)? = nil) -> DeviceSyncKicker {
        DeviceSyncKicker(quiet: 5, maxWait: 30, sleep: { d in try await withCheckedThrowingContinuation { clock.add(d, $0) } },
                         now: { clock.now }, run: { clock.ran(); await during?() })
    }

    /// wartet, bis `ok` gilt (andere Aufgaben laufen dazwischen weiter)
    private func until(_ what: String, _ ok: () -> Bool) async throws {
        for _ in 0..<2000 where !ok() { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(ok(), what)
    }

    func testSeveralChangesGiveOneRun() async throws {
        let clock = Clock(), k = make(clock)
        await k.kick(); await k.kick(); await k.kick()
        try await until("wartet") { clock.sleeps == [5] }
        clock.time = 5
        clock.fire()
        try await until("ein Lauf") { clock.runs == [5] }
        let pending = await k.pending
        XCTAssertFalse(pending)
    }

    func testAnotherChangeExtendsTheQuietTime() async throws {
        let clock = Clock(), k = make(clock)
        await k.kick()
        try await until("wartet") { clock.sleeps == [5] }
        clock.time = 3
        await k.kick()
        clock.time = 5
        clock.fire()
        try await until("wartet weiter bis 8") { clock.sleeps == [3] }
        XCTAssertEqual(clock.runs, [])
        clock.time = 8
        clock.fire()
        try await until("Lauf bei 8") { clock.runs == [8] }
    }

    func testContinuousWritingStillSyncsAfterMaxWait() async throws {
        let clock = Clock(), k = make(clock)
        await k.kick()
        var t: TimeInterval = 0
        while clock.runs.isEmpty && t < 40 {
            try await until("wartet bei \(t)") { !clock.sleeps.isEmpty || !clock.runs.isEmpty }
            t += 4
            clock.time = t
            await k.kick()                                          // alle 4 s eine weitere Aenderung
            clock.fire()
        }
        try await until("Lauf") { !clock.runs.isEmpty }
        XCTAssertEqual(clock.runs.first, 32, "spaetestens beim ersten Blick nach 30 s")
    }

    func testFlushSendsAtOnceAndChangesDuringARunGiveAnother() async throws {
        let clock = Clock()
        let box = KickerBox()
        let k = make(clock) { if clock.runs.count == 1 { await box.kicker?.kick() } }   // Aenderung waehrend des ersten Laufs
        box.kicker = k
        await k.kick()
        try await until("wartet") { clock.sleeps == [5] }
        await k.flush()
        XCTAssertEqual(clock.runs, [0], "sofort, ohne die Ruhezeit")
        try await until("zweiter Lauf wartet") { !clock.sleeps.isEmpty }
        clock.time = 5
        clock.fire()
        try await until("zweiter Lauf") { clock.runs.count == 2 }
        await k.flush()
        XCTAssertEqual(clock.runs.count, 2, "nichts mehr offen")
    }

    func testCancelDropsPendingChanges() async throws {
        let clock = Clock(), k = make(clock)
        await k.kick()
        await k.cancel()
        await k.flush()
        XCTAssertEqual(clock.runs, [])
    }

    func testWhichRequestsCount() {
        XCTAssertTrue(DeviceSyncKicker.isAccountChange(method: "PUT", path: "/api/files/x/annotations", status: 200))
        XCTAssertTrue(DeviceSyncKicker.isAccountChange(method: "post", path: "/api/packages", status: 201))
        XCTAssertTrue(DeviceSyncKicker.isAccountChange(method: "DELETE", path: "/api/flashcards/3", status: 200))
        XCTAssertFalse(DeviceSyncKicker.isAccountChange(method: "GET", path: "/api/packages", status: 200))
        XCTAssertFalse(DeviceSyncKicker.isAccountChange(method: "POST", path: "/api/packages", status: 422))
        XCTAssertFalse(DeviceSyncKicker.isAccountChange(method: "POST", path: "/api/sync", status: 200), "Hochschul-Abgleich")
        XCTAssertFalse(DeviceSyncKicker.isAccountChange(method: "POST", path: "/api/community/solutions", status: 201))
        XCTAssertFalse(DeviceSyncKicker.isAccountChange(method: "POST", path: "/api/ai/explain", status: 200))
        XCTAssertFalse(DeviceSyncKicker.isAccountChange(method: "POST", path: "/konto/rueckkehr", status: 200))
    }
}

private final class KickerBox: @unchecked Sendable {
    var kicker: DeviceSyncKicker?
}
