import Foundation
@testable import UniFlowCore

enum TestError: Error { case offline }

/// Antwort mit HTTP-Status wie `APIError` der App.
struct TestHTTPError: HTTPStatusError { let httpStatus: Int }

/// Server wie `PUT /api/files/{id}/annotations?base_version=` in app/server.py: 409 mit neuerem Stand, wenn
/// `base_version` nicht der aktuellen Version entspricht.
actor MockServer: AnnotationTransport {
    private(set) var version = 0
    private(set) var root: JSONValue = AnnotationDocument.emptyRoot
    private(set) var putCount = 0
    private(set) var maxConcurrentPuts = 0
    private var concurrentPuts = 0
    var online = true
    /// Statt zu speichern mit diesem HTTP-Status antworten (401, 403, 503 ...).
    private(set) var failStatus: Int?
    /// Zeitpunkte aller Speicherversuche (auch fehlgeschlagener).
    private(set) var putTimes: [Date] = []
    private var holdNextPut = false
    private var heldPut: CheckedContinuation<Void, Never>?
    private(set) var isHoldingPut = false

    func setOnline(_ on: Bool) { online = on }
    func setFailStatus(_ status: Int?) { failStatus = status }
    func holdNext() { holdNextPut = true }

    func releaseHeldPut() {
        heldPut?.resume()
        heldPut = nil
        isHoldingPut = false
    }

    func fetch(documentID: String) async throws -> ServerSnapshot {
        guard online else { throw TestError.offline }
        if let failStatus { throw TestHTTPError(httpStatus: failStatus) }
        return ServerSnapshot(version: version, root: root)
    }

    func put(documentID: String, root newRoot: JSONValue, baseVersion: Int) async throws -> PutOutcome {
        guard online else { throw TestError.offline }
        putTimes.append(Date())
        if let failStatus { throw TestHTTPError(httpStatus: failStatus) }
        putCount += 1
        concurrentPuts += 1
        maxConcurrentPuts = max(maxConcurrentPuts, concurrentPuts)
        defer { concurrentPuts -= 1 }
        if holdNextPut {
            holdNextPut = false
            isHoldingPut = true
            await withCheckedContinuation { heldPut = $0 }      // laeuft danach weiter, auch wenn inzwischen offline
        }
        if version > 0 && baseVersion != version {
            return .conflict(ServerSnapshot(version: version, root: root))
        }
        version += 1
        root = newRoot
        return .saved(version: version)
    }

    /// Ein anderes Geraet (z. B. der Browser) speichert direkt.
    func externalEdit(_ edit: (inout AnnotationDocument) -> Void) {
        var doc = AnnotationDocument(root: root)
        edit(&doc)
        root = doc.root
        version += 1
    }

    func objectIDs(page key: String) -> [String] {
        AnnotationDocument(root: root).objects(page: key).compactMap { $0["id"]?.string }
    }

    func allObjectIDs() -> [String] {
        AnnotationDocument(root: root).pages.values.flatMap { ($0["objects"]?.array ?? []).compactMap { $0["id"]?.string } }
    }
}

func stroke(_ id: String, points: Int = 12, x: Double = 10) -> JSONValue {
    var pts: [JSONValue] = []
    pts.reserveCapacity(points * 2)
    for i in 0..<points {
        pts.append(.number(x + Double(i) * 1.25))
        pts.append(.number(20 + Double(i % 5) * 0.75))
    }
    return .object([
        "id": .string(id), "type": "stroke", "tool": "pen", "color": "#1f2937", "width": 2.2, "opacity": 1,
        "points": .array(pts), "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1,
    ])
}

func page(_ ids: [String]) -> JSONValue {
    .object(["objects": .array(ids.map { stroke($0) })])
}

func pageWith(_ objects: [JSONValue]) -> JSONValue { .object(["objects": .array(objects)]) }

/// Wiederholungsabstaende in Tests: 1 % der echten Zeit (2 s -> 20 ms).
let fastSleeper: SyncEngine.Sleeper = { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0.001, seconds * 0.01) * 1_000_000_000)) }

func makeEngine(_ server: MockServer, _ store: BlobStore, id: String = "doc1") -> SyncEngine {
    SyncEngine(documentID: id, transport: server, journal: LocalJournal(store: store, documentID: id), uploadDelay: 0, sleeper: fastSleeper)
}

/// Wartet, bis die Bedingung erfuellt ist (hoechstens `timeout` Sekunden).
func waitUntil(timeout: Double = 3, _ condition: @Sendable () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}
