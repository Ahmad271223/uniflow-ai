import Foundation
import XCTest
@testable import UniFlowCore

/// Versionsverlauf der Notizen (Editor-Schritt 4, P0-9) wie tests/test_annotation_versions.py: hoechstens eine Version
/// je 5 Minuten; mit `snapshot=true` (Schliessen, nach Konflikt) und beim Wiederherstellen dazu der ersetzte und der
/// neue Stand; der Stand selbst wird immer gespeichert.
final class AnnotationVersionTests: XCTestCase {

    /// Uhr, die der Test weiterstellt
    final class Ticker: @unchecked Sendable {
        private let lock = NSLock()
        private var local = "2026-10-29T10:00:00"
        func set(_ s: String) { lock.withLock { local = s } }
        var clock: UniFlowClock {
            UniFlowClock { [self] in
                let s = lock.withLock { local }
                return Date(timeIntervalSince1970: TimeInterval(BerlinClock.utcSeconds(localISO: s)!))
            }
        }
    }

    private func backend(_ t: Ticker) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: t.clock)
        try await b.context.database.execute("INSERT INTO courses(id, title) VALUES ('k1', 'Testkurs')")
        try await b.context.database.execute("INSERT INTO files(id, course_id, name) VALUES ('d1', 'k1', 'Blatt.pdf')")
        return b
    }

    private func doc(_ n: Int) -> Data {
        Data(("{\"version\": 2, \"pages\": {\"p1\": {\"objects\": [" + (0..<n).map { "{\"id\": \"s\($0)\"}" }.joined(separator: ", ") + "]}}}").utf8)
    }

    @discardableResult
    private func put(_ b: LocalBackend, base: Int, n: Int, snapshot: String? = nil) async -> LocalResponse {
        var q: [LocalRequest.QueryItem] = [.init("base_version", String(base))]
        if let snapshot { q.append(.init("snapshot", snapshot)) }
        return await b.handle(LocalRequest(method: "PUT", path: "/api/files/d1/annotations", query: q, body: doc(n)))
    }

    private func versions(_ b: LocalBackend) async -> [Int] {
        let r = await b.handle(LocalRequest(method: "GET", path: "/api/files/d1/annotations/versions"))
        return (r.json?.array ?? []).compactMap { $0["version"]?.int }
    }

    func testVersionsAtMostEveryFiveMinutesAndOnSnapshot() async throws {
        let t = Ticker()
        let b = try await backend(t)
        for (i, at) in ["10:00:00", "10:00:02", "10:04:59", "10:05:00", "10:05:01"].enumerated() {
            t.set("2026-10-29T" + at)
            let r = await put(b, base: i, n: i + 1)
            XCTAssertEqual(r.json?["version"]?.int, i + 1)
        }
        t.set("2026-10-29T10:05:02")
        await put(b, base: 5, n: 6, snapshot: "true")
        let listed = await versions(b)
        XCTAssertEqual(listed, [6, 5, 4, 1], "Snapshot: der ersetzte Stand (5) und der neue (6)")
        let get = await b.handle(LocalRequest(method: "GET", path: "/api/files/d1/annotations"))
        XCTAssertEqual(get.json?["version"], 6)
        XCTAssertEqual(get.json?["data"]?["pages"]?["p1"]?["objects"]?.array?.count, 6, "der Stand wird immer gespeichert")
    }

    func testClockSetBackStillRecordsAndBadSnapshotIs422() async throws {
        let t = Ticker()
        let b = try await backend(t)
        await put(b, base: 0, n: 1)
        t.set("2026-10-29T09:00:00")
        await put(b, base: 1, n: 2)
        let listed = await versions(b)
        XCTAssertEqual(listed, [2, 1])
        let bad = await put(b, base: 2, n: 1, snapshot: "vielleicht")
        XCTAssertEqual(bad.status, 422)
        XCTAssertEqual(bad.json?["detail"]?.array?.first?["type"], "bool_parsing")
    }

    func testRestoreKeepsTheStateBeforeAndRecordsAVersion() async throws {
        let t = Ticker()
        let b = try await backend(t)
        await put(b, base: 0, n: 1)
        t.set("2026-10-29T10:00:05")
        await put(b, base: 1, n: 2)                                          // ohne Version
        t.set("2026-10-29T10:00:06")
        let r = await b.handle(LocalRequest(method: "POST", path: "/api/files/d1/annotations/restore/1"))
        XCTAssertEqual(r.json?["version"], 3)
        let listed = await versions(b)
        XCTAssertEqual(listed, [3, 2, 1], "Stand vor dem Wiederherstellen (2) bleibt im Verlauf")
        let back = await b.handle(LocalRequest(method: "POST", path: "/api/files/d1/annotations/restore/2"))
        XCTAssertEqual(back.status, 200)
        let get = await b.handle(LocalRequest(method: "GET", path: "/api/files/d1/annotations"))
        XCTAssertEqual(get.json?["data"]?["pages"]?["p1"]?["objects"]?.array?.count, 2)
    }

    /// Kein Objekt als Inhalt: dieselbe 422 wie FastAPI, auch wenn nur noch einmal gelesen wird
    func testNonObjectBodyStill422() async throws {
        let b = try await backend(Ticker())
        for body in ["[1, 2]", "kein json", "\"text\""] {
            let r = await b.handle(LocalRequest(method: "PUT", path: "/api/files/d1/annotations", query: [.init("base_version", "0")],
                                                body: Data(body.utf8)))
            XCTAssertEqual(r.status, 422, body)
        }
        let n = try await b.context.database.scalar("SELECT COUNT(*) FROM annotations")?.int
        XCTAssertEqual(n, 0)
    }

    func testNaiveSecondsLikePythonFromIsoformat() {
        XCTAssertEqual(AnnotationEndpoints.naiveSeconds("1970-01-01T00:00:00"), 0)
        XCTAssertEqual(AnnotationEndpoints.naiveSeconds("2026-10-29T10:05:00")! - AnnotationEndpoints.naiveSeconds("2026-10-29T10:00:00")!, 300)
        XCTAssertEqual(AnnotationEndpoints.naiveSeconds("2026-03-01T00:00:00")! - AnnotationEndpoints.naiveSeconds("2026-02-28T00:00:00")!, 86_400)
        XCTAssertEqual(AnnotationEndpoints.naiveSeconds("2024-03-01 00:00")! - AnnotationEndpoints.naiveSeconds("2024-02-28T00:00:00")!, 2 * 86_400, "Schaltjahr")
        XCTAssertNil(AnnotationEndpoints.naiveSeconds("gestern"))
        XCTAssertNil(AnnotationEndpoints.naiveSeconds("2026-13-01T00:00:00"))
    }
}
