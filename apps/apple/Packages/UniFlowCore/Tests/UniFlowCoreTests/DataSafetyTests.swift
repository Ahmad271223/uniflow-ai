import XCTest
@testable import UniFlowCore

/// Datenverlust-Risiken zwischen iPad und Browser: native Zeichnung (v2), Loeschungen bei gleichzeitigem Schreiben,
/// Fehlerzustaende beim Hochladen.
final class StoredDrawingV2Tests: XCTestCase {

    func testV2RoundTripKeepsStrokeSignatures() {
        let sd = StoredDrawing(data: "QUJD", signature: "sig", strokeIDs: [["a"], ["b1", "b2"]], strokeSignatures: ["s1", "s2"])
        XCTAssertEqual(sd.json["format"], "pkdrawing-v2")
        var p = page(["a"])
        p["pkdrawing"] = sd.json
        let back = StoredDrawing(page: p)
        XCTAssertEqual(back, sd)
        XCTAssertEqual(back?.isPerStroke, true)
        XCTAssertTrue(StoredDrawing.isPerStroke(p["pkdrawing"]))
    }

    func testV1IsStillReadAndWrittenAsV1() {
        let v1: JSONValue = ["data": "AAEC", "objectsSig": "0000", "format": "pkdrawing-v1", "strokeIds": [["x"]]]
        let sd = StoredDrawing(json: v1)
        XCTAssertNotNil(sd)
        XCTAssertNil(sd?.strokeSignatures)
        XCTAssertEqual(sd?.strokeIDs, [["x"]])
        XCTAssertEqual(sd?.json["format"], "pkdrawing-v1")
        XCTAssertFalse(StoredDrawing.isPerStroke(v1))
        // ohne Formatangabe (sehr alte Staende) ebenfalls v1
        XCTAssertNotNil(StoredDrawing(json: ["data": "AA", "objectsSig": "1"]))
    }

    func testMergeKeepsPerStrokeDrawingWhenObjectsDiffer() {
        var local = page(["a", "ipad"])
        local["pkdrawing"] = StoredDrawing(data: "QQ", signature: "x", strokeIDs: [["a"], ["ipad"]], strokeSignatures: ["1", "2"]).json
        let server = page(["a", "web"])
        let r = AnnotationMerge.mergePage(base: page(["a"]), local: local, server: server)
        XCTAssertEqual(r.page?["objects"]?.array?.compactMap { $0["id"]?.string }, ["a", "web", "ipad"])
        XCTAssertEqual(r.page?["pkdrawing"], local["pkdrawing"], "v2 prueft je Strich selbst und bleibt erhalten")
    }

    func testMergeTakesServerPerStrokeDrawingIfLocalHasNone() {
        var server = page(["a", "web"])
        server["pkdrawing"] = StoredDrawing(data: "QQ", signature: "x", strokeIDs: [["a"]], strokeSignatures: ["1"]).json
        let r = AnnotationMerge.mergePage(base: page(["a"]), local: page(["a", "ipad"]), server: server)
        XCTAssertEqual(r.page?["pkdrawing"], server["pkdrawing"])
    }

    func testMergeStillDropsStaleV1Drawing() {
        var local = page(["a", "ipad"])
        local["pkdrawing"] = StoredDrawing(data: "QQ", signature: "x", strokeIDs: [["a"], ["ipad"]]).json
        let r = AnnotationMerge.mergePage(base: page(["a"]), local: local, server: page(["a", "web"]))
        XCTAssertNil(r.page?["pkdrawing"])
    }
}

final class DeletionWinsTests: XCTestCase {

    /// Im Browser geloescht, auf dem iPad gleichzeitig auf derselben Seite geschrieben: Loeschung gewinnt.
    func testBrowserDeleteWhileIPadWritesOnSamePage() async {
        let server = MockServer()
        let ipad = makeEngine(server, MemoryBlobStore())
        _ = await ipad.open(pdfPageCount: 1)
        await ipad.updatePage("p1", page(["a", "b"]))
        await ipad.syncNow()
        await server.externalEdit { $0.pages["p1"] = page(["b"]) }          // Browser loescht a
        await ipad.updatePage("p1", page(["a", "b", "c"]))                  // iPad schreibt c, kennt a noch
        await ipad.syncNow()
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["b", "c"], "im Browser geloeschtes a taucht nicht wieder auf")
        let local = await ipad.page("p1")?["objects"]?.array?.compactMap { $0["id"]?.string }
        XCTAssertEqual(local, ["b", "c"])
    }

    /// Dasselbe ueber einen Neustart der App hinweg (Basis kommt aus dem Journal).
    func testBrowserDeleteSurvivesAppRestartWithUnsentStrokes() async {
        let server = MockServer(), store = MemoryBlobStore()
        let first = makeEngine(server, store)
        _ = await first.open(pdfPageCount: 1)
        await first.updatePage("p1", page(["a", "b"]))
        await first.syncNow()
        await server.setOnline(false)
        await first.updatePage("p1", page(["a", "b", "offline-c"]))
        await first.syncNow()
        await first.shutdown()
        await server.setOnline(true)
        await server.externalEdit { $0.pages["p1"] = page(["b"]) }
        let second = makeEngine(server, store)
        _ = await second.open(pdfPageCount: 1)
        await second.syncNow()
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["b", "offline-c"])
    }

    /// Der Editor rechnet aus einem aelteren Stand um, waehrend eine Zusammenfuehrung die Seite aendert: der
    /// neuere Stand wird nicht ueberschrieben.
    func testUpdateDerivedFromOlderPageMergesInsteadOfOverwriting() async {
        let server = MockServer()
        let ipad = makeEngine(server, MemoryBlobStore())
        _ = await ipad.open(pdfPageCount: 1)
        await ipad.updatePage("p1", page(["a", "b"]))
        await ipad.syncNow()
        let previous = await ipad.page("p1")                                // Editor liest diesen Stand ...
        await server.externalEdit { $0.pages["p1"] = page(["b", "web"]) }   // ... Browser loescht a, ergaenzt web
        await ipad.updatePage("p2", page(["anderswo"]))
        await ipad.syncNow()                                                // 409 -> p1 kommt vom Server
        let computed = page(["a", "b", "ipad-neu"])                         // Ergebnis der Umrechnung
        let changed = await ipad.updatePage("p1", computed, derivedFrom: previous)
        XCTAssertTrue(changed, "Anzeige muss neu geladen werden")
        let ids = await ipad.page("p1")?["objects"]?.array?.compactMap { $0["id"]?.string }
        XCTAssertEqual(ids, ["b", "web", "ipad-neu"])
        await ipad.syncNow()
        let onServer = await server.objectIDs(page: "p1")
        XCTAssertEqual(onServer, ["b", "web", "ipad-neu"])
    }

    func testUpdateDerivedFromCurrentPageIsPlainUpdate() async {
        let engine = makeEngine(MockServer(), MemoryBlobStore())
        _ = await engine.open(pdfPageCount: 1)
        await engine.updatePage("p1", page(["a"]))
        let previous = await engine.page("p1")
        let changed = await engine.updatePage("p1", page(["a", "b"]), derivedFrom: previous)
        XCTAssertFalse(changed)
        let ids = await engine.page("p1")?["objects"]?.array?.compactMap { $0["id"]?.string }
        XCTAssertEqual(ids, ["a", "b"])
    }
}

final class SyncIssueTests: XCTestCase {

    func testClassification() {
        XCTAssertEqual(SyncIssue.classify(TestHTTPError(httpStatus: 401)), .pinFehlt)
        XCTAssertEqual(SyncIssue.classify(TestHTTPError(httpStatus: 403)), .zugriffVerweigert)
        XCTAssertEqual(SyncIssue.classify(TestHTTPError(httpStatus: 503)), .serverfehler(503))
        XCTAssertEqual(SyncIssue.classify(TestHTTPError(httpStatus: -1)), .offline, "keine HTTP-Antwort")
        XCTAssertEqual(SyncIssue.classify(TestError.offline), .offline)
        XCTAssertEqual(SyncIssue.classify(URLError(.notConnectedToInternet)), .offline)
    }

    func testUnauthorizedIsNotOfflineAndNotRetriedEndlessly() async {
        await checkBlocked(status: 401, expected: .pinFehlt)
    }

    func testForbiddenIsNotOfflineAndNotRetriedEndlessly() async {
        await checkBlocked(status: 403, expected: .zugriffVerweigert)
    }

    private func checkBlocked(status code: Int, expected: SyncIssue) async {
        let server = MockServer()
        let engine = makeEngine(server, MemoryBlobStore())
        _ = await engine.open(pdfPageCount: 1)
        await server.setFailStatus(code)
        await engine.updatePage("p1", page(["a"]))
        await engine.syncNow()
        let issue = await engine.issue
        XCTAssertEqual(issue, expected)
        let status = await engine.status
        XCTAssertEqual(status, .pending(pages: 1), "nicht Offline, lokal gesichert")
        XCTAssertTrue(status.isSafeLocally)
        try? await Task.sleep(nanoseconds: 300_000_000)                 // entspricht 30 s Wiederholungszeit
        let attempts = await server.putTimes.count
        XCTAssertEqual(attempts, 1, "keine automatische Wiederholung")
        await engine.updatePage("p1", page(["a", "b"]))                // weitere Striche loesen keinen Versuch aus
        try? await Task.sleep(nanoseconds: 50_000_000)
        let afterEdit = await server.putTimes.count
        XCTAssertEqual(afterEdit, 1)
        // PIN wieder gueltig, ausdrueckliche Anfrage (z. B. App im Vordergrund): hochladen
        await server.setFailStatus(nil)
        await engine.requestUpload()
        let saved = await waitUntil { await engine.status == .saved }
        XCTAssertTrue(saved)
        let cleared = await engine.issue
        XCTAssertNil(cleared)
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testUnauthorizedOnOpenDoesNotUpload() async {
        let server = MockServer(), store = MemoryBlobStore()
        let first = makeEngine(server, store)
        _ = await first.open(pdfPageCount: 1)
        await server.setOnline(false)
        await first.updatePage("p1", page(["a"]))
        await first.shutdown()
        await server.setOnline(true)
        await server.setFailStatus(401)
        let second = makeEngine(server, store)
        let opened = await second.open(pdfPageCount: 1)
        XCTAssertFalse(opened.serverReachable)
        let issue = await second.issue
        XCTAssertEqual(issue, .pinFehlt)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let attempts = await server.putTimes.count
        XCTAssertEqual(attempts, 0)
    }

    func testServerErrorRetriesWithGrowingInterval() async {
        let server = MockServer()
        let engine = makeEngine(server, MemoryBlobStore())
        _ = await engine.open(pdfPageCount: 1)
        await server.setFailStatus(503)
        await engine.updatePage("p1", page(["a"]))
        await engine.syncNow()
        let issue = await engine.issue
        XCTAssertEqual(issue, .serverfehler(503))
        let status = await engine.status
        XCTAssertNotEqual(status, .offline(pages: 1), "Serverfehler ist nicht Offline")
        // Abstaende im Test 1 %: 20 ms, 40 ms, 80 ms, 160 ms ...
        let enough = await waitUntil(timeout: 5) { await server.putTimes.count >= 5 }
        XCTAssertTrue(enough)
        let times = await server.putTimes
        let gaps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
        XCTAssertGreaterThan(gaps[3], gaps[0] * 2, "Abstand waechst: \(gaps)")
        // weitere Striche verkuerzen den Abstand nicht
        let before = await server.putTimes.count
        await engine.updatePage("p1", page(["a", "b"]))
        try? await Task.sleep(nanoseconds: 30_000_000)
        let after = await server.putTimes.count
        XCTAssertLessThanOrEqual(after - before, 1)
        await server.setFailStatus(nil)
        let saved = await waitUntil(timeout: 10) { await engine.status == .saved }
        XCTAssertTrue(saved, "nach Behebung automatisch gespeichert")
        let cleared = await engine.issue
        XCTAssertNil(cleared)
        await engine.shutdown()
    }

    /// 5xx schon beim Oeffnen, nichts ungesendet: spaetere Striche werden trotzdem automatisch hochgeladen.
    func testServerErrorOnOpenThenEditUploads() async {
        let server = MockServer()
        await server.setFailStatus(503)
        let engine = makeEngine(server, MemoryBlobStore())
        _ = await engine.open(pdfPageCount: 1)
        let issue = await engine.issue
        XCTAssertEqual(issue, .serverfehler(503))
        await server.setFailStatus(nil)                                     // Server wieder in Ordnung
        await engine.updatePage("p1", page(["a"]))
        let saved = await waitUntil(timeout: 5) { await engine.status == .saved }
        let puts = await server.putTimes.count
        XCTAssertTrue(saved, "Aenderung nach 5xx beim Oeffnen hochgeladen (puts=\(puts))")
        let cleared = await engine.issue
        XCTAssertNil(cleared)
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["a"])
        await engine.shutdown()
    }

    /// 5xx beim Oeffnen, Server bleibt kaputt, dann wird geschrieben: Wiederholung mit wachsendem Abstand, bis es klappt.
    func testServerErrorOnOpenThenEditRetriesUntilServerRecovers() async {
        let server = MockServer()
        await server.setFailStatus(503)
        let engine = makeEngine(server, MemoryBlobStore())
        _ = await engine.open(pdfPageCount: 1)
        await engine.updatePage("p1", page(["a"]))
        let tried = await waitUntil(timeout: 5) { await server.putTimes.count >= 3 }
        XCTAssertTrue(tried, "wird wiederholt")
        let status = await engine.status
        XCTAssertTrue(status.isSafeLocally)
        await server.setFailStatus(nil)
        let saved = await waitUntil(timeout: 10) { await engine.status == .saved }
        XCTAssertTrue(saved)
        await engine.shutdown()
    }

    /// 5xx beim Oeffnen ohne Aenderungen: ein spaeterer Abruf holt den Serverstand, der Hinweis verschwindet.
    func testServerErrorOnOpenRecoversAndFetchesServerState() async {
        let server = MockServer()
        await server.externalEdit { $0.pages["p1"] = page(["web"]) }
        await server.setFailStatus(503)
        let engine = makeEngine(server, MemoryBlobStore())
        let changed = KeysBox()
        await engine.setHandlers(onStatus: nil, onRemoteChange: { changed.add($0) })
        _ = await engine.open(pdfPageCount: 1)
        await server.setFailStatus(nil)
        let cleared = await waitUntil(timeout: 5) { await engine.issue == nil }
        XCTAssertTrue(cleared, "Serverfehler bleibt nicht stehen")
        let ids = await engine.page("p1")?["objects"]?.array?.compactMap { $0["id"]?.string }
        XCTAssertEqual(ids, ["web"], "Serverstand nachgeholt")
        XCTAssertEqual(changed.keys, ["p1"], "Anzeige wird neu geladen")
        let puts = await server.putTimes.count
        XCTAssertEqual(puts, 0, "nichts zu senden")
        await engine.shutdown()
    }

    /// 401 ohne ungesendete Seiten: nach ausdruecklicher Anfrage mit gueltiger PIN ist der Hinweis weg, spaetere
    /// Striche gehen wieder automatisch hoch.
    func testExplicitRequestWithoutUnsentPagesClearsBlocked() async {
        let server = MockServer()
        await server.setFailStatus(401)
        let engine = makeEngine(server, MemoryBlobStore())
        _ = await engine.open(pdfPageCount: 1)
        let blocked = await engine.issue
        XCTAssertEqual(blocked, .pinFehlt)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let attempts = await server.putTimes.count
        XCTAssertEqual(attempts, 0, "kein automatischer Versuch")
        await server.setFailStatus(nil)
        await engine.requestUpload()
        let cleared = await waitUntil { await engine.issue == nil }
        XCTAssertTrue(cleared)
        await engine.updatePage("p1", page(["a"]))
        let saved = await waitUntil { await engine.status == .saved }
        XCTAssertTrue(saved, "ohne weitere Anfrage hochgeladen")
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["a"])
    }

    /// Ausdrueckliche Anfrage mit weiterhin falscher PIN: bleibt blockiert, keine Wiederholungen.
    func testExplicitRequestWithStillWrongPinStaysBlocked() async {
        let server = MockServer()
        await server.setFailStatus(401)
        let engine = makeEngine(server, MemoryBlobStore())
        _ = await engine.open(pdfPageCount: 1)
        await engine.syncNow()
        let issue = await engine.issue
        XCTAssertEqual(issue, .pinFehlt)
        await engine.updatePage("p1", page(["a"]))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let attempts = await server.putTimes.count
        XCTAssertEqual(attempts, 0)
    }

    func testNetworkErrorStaysOffline() async {
        let server = MockServer()
        let engine = makeEngine(server, MemoryBlobStore())
        _ = await engine.open(pdfPageCount: 1)
        await server.setOnline(false)
        await engine.updatePage("p1", page(["a"]))
        await engine.syncNow()
        let issue = await engine.issue
        XCTAssertEqual(issue, .offline)
        let status = await engine.status
        XCTAssertEqual(status, .offline(pages: 1))
        await engine.shutdown()
    }

    func testMergedConflictsAreReportedUntilAcknowledged() async {
        let server = MockServer()
        let ipad = makeEngine(server, MemoryBlobStore())
        let box = IssueBox()
        await ipad.setIssueHandler { box.set($0) }
        _ = await ipad.open(pdfPageCount: 1)
        await ipad.updatePage("p1", page(["a"]))
        await ipad.syncNow()
        var webVersion = stroke("a"); webVersion["color"] = "#00ff00"
        await server.externalEdit { $0.pages["p1"] = pageWith([webVersion]) }
        var ipadVersion = stroke("a"); ipadVersion["color"] = "#ff0000"
        await ipad.updatePage("p1", pageWith([ipadVersion]))
        await ipad.syncNow()
        let issue = await ipad.issue
        XCTAssertEqual(issue, .konflikteZusammengefuehrt(1))
        XCTAssertEqual(box.value, .konflikteZusammengefuehrt(1))
        await ipad.acknowledgeMergedConflicts()
        let cleared = await ipad.issue
        XCTAssertNil(cleared)
        XCTAssertNil(box.value)
    }

    func testLabels() {
        XCTAssertEqual(SyncIssue.konflikteZusammengefuehrt(2).label, "2 Konflikte zusammengeführt")
        XCTAssertTrue(SyncIssue.pinFehlt.needsUserAction)
        XCTAssertFalse(SyncIssue.serverfehler(500).needsUserAction)
    }
}

final class KeysBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ v: [String]) { lock.lock(); stored += v; lock.unlock() }
    var keys: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

final class IssueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SyncIssue?
    func set(_ v: SyncIssue?) { lock.lock(); stored = v; lock.unlock() }
    var value: SyncIssue? { lock.lock(); defer { lock.unlock() }; return stored }
}
