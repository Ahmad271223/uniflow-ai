import XCTest
@testable import UniFlowCore

final class SyncEngineTests: XCTestCase {

    // MARK: Grundablauf

    func testEditIsSavedLocallyThenUploaded() async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: 3)
        await engine.updatePage("p1", page(["a"]))
        await engine.syncNow()
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["a"])
        let status = await engine.status
        XCTAssertEqual(status, .saved)
        let order = await AnnotationDocument(root: server.root).pageOrder.count
        XCTAssertEqual(order, 3, "Seitenliste wird mitgesendet")
    }

    // MARK: Viele Striche

    func test1000Strokes() async { await runManyStrokes(1000, pages: 4) }

    func test5000Strokes() async { await runManyStrokes(5000, pages: 10) }

    private func runManyStrokes(_ total: Int, pages pageCount: Int) async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: pageCount)
        let start = Date()
        var perPage: [String: [String]] = [:]
        for i in 0..<total {
            let key = "p\(i % pageCount + 1)"
            perPage[key, default: []].append("s\(i)")
            // wie der Editor: nach jedem Strich neuer Seitenstand, aber nur alle 25 Striche (Entprellung)
            if i % 25 == 24 || i == total - 1 { await engine.updatePage(key, page(perPage[key]!)) }
        }
        for (key, ids) in perPage { await engine.updatePage(key, page(ids)) }
        await engine.syncNow()
        let seconds = Date().timeIntervalSince(start)
        let all = await server.allObjectIDs()
        XCTAssertEqual(all.count, total)
        XCTAssertEqual(Set(all).count, total, "keine doppelten IDs")
        let status = await engine.status
        XCTAssertEqual(status, .saved)
        XCTAssertLessThan(seconds, 60)
        print("\(total) Striche lokal sichern + hochladen: \(String(format: "%.2f", seconds)) s")
    }

    // MARK: Schreiben waehrend des Uploads

    func testStrokesWrittenDuringUploadStayUnsent() async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: 2)
        await engine.updatePage("p1", page(["a"]))
        await server.holdNext()
        let upload = Task { await engine.syncNow() }
        let held = await waitUntil { await server.isHoldingPut }
        XCTAssertTrue(held)
        await engine.updatePage("p1", page(["a", "b"]))           // waehrend der Upload laeuft
        await server.releaseHeldPut()
        await upload.value
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["a", "b"], "der waehrend des Uploads geschriebene Strich wurde nachgesendet")
        let status = await engine.status
        XCTAssertEqual(status, .saved)
    }

    func testCrashRightAfterAckKeepsLaterStrokesUnsent() async {
        let server = MockServer(), store = MemoryBlobStore()
        let first = makeEngine(server, store)
        _ = await first.open(pdfPageCount: 1)
        await first.updatePage("p1", page(["a"]))
        await server.holdNext()
        let upload = Task { await first.syncNow() }
        _ = await waitUntil { await server.isHoldingPut }
        await first.updatePage("p1", page(["a", "b"]))
        await server.setOnline(false)                              // zweite Runde scheitert, App "stuerzt ab"
        await server.releaseHeldPut()                              // erste Runde wird noch gespeichert
        await upload.value
        await first.shutdown()
        // Neustart mit demselben Speicher
        await server.setOnline(true)
        let second = makeEngine(server, store)
        let opened = await second.open(pdfPageCount: 1)
        XCTAssertEqual(opened.restoredUnsentPages, 1)
        await second.syncNow()
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testParallelWritingAndSyncingUsesOneUploadAtATime() async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: 3)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var ids: [String] = []
                for i in 0..<150 {
                    ids.append("w\(i)")
                    await engine.updatePage("p\(i % 3 + 1)", page(ids.enumerated().filter { $0.offset % 3 == i % 3 }.map { $0.element }))
                    if i % 10 == 0 { await Task.yield() }
                }
            }
            for _ in 0..<20 {
                group.addTask { await engine.requestUpload() }
                group.addTask { await engine.syncNow() }
            }
        }
        await engine.syncNow()
        let all = await server.allObjectIDs()
        XCTAssertEqual(Set(all).count, 150)
        let maxParallel = await server.maxConcurrentPuts
        XCTAssertEqual(maxParallel, 1, "Uploads duerfen sich nie ueberlappen")
    }

    // MARK: Netzwerk

    func testNetworkFailureKeepsChangesAndRetries() async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: 1)
        await server.setOnline(false)
        await engine.updatePage("p1", page(["offline1"]))
        await engine.syncNow()
        let offline = await engine.status
        XCTAssertEqual(offline, .offline(pages: 1))
        XCTAssertTrue(offline.isSafeLocally)
        await server.setOnline(true)
        let saved = await waitUntil(timeout: 5) { await engine.status == .saved }
        XCTAssertTrue(saved, "automatische Wiederholung nach Netzrueckkehr")
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["offline1"])
    }

    func testOpenOfflineWithoutLocalDataGivesEmptyDocument() async {
        let server = MockServer(), store = MemoryBlobStore()
        await server.setOnline(false)
        let engine = makeEngine(server, store)
        let r = await engine.open(pdfPageCount: 2)
        XCTAssertFalse(r.serverReachable)
        XCTAssertEqual(r.document.pageKey(forPDFIndex: 2), "p2")
    }

    // MARK: Absturz und Neustart

    func testAppCrashBeforeUploadRestoresFromJournal() async {
        let server = MockServer(), store = MemoryBlobStore()
        await server.setOnline(false)
        let crashed = makeEngine(server, store)
        _ = await crashed.open(pdfPageCount: 2)
        await crashed.updatePage("p1", page(["vor-absturz-1"]))
        await crashed.updatePage("p2", page(["vor-absturz-2"]))
        // kein Upload; Instanz wird verworfen
        await crashed.shutdown()
        await server.setOnline(true)
        let restarted = makeEngine(server, store)
        let opened = await restarted.open(pdfPageCount: 2)
        XCTAssertEqual(opened.restoredUnsentPages, 2)
        XCTAssertEqual(opened.document.objects(page: "p1").first?["id"]?.string, "vor-absturz-1")
        await restarted.syncNow()
        let all = await server.allObjectIDs().sorted()
        XCTAssertEqual(all, ["vor-absturz-1", "vor-absturz-2"])
    }

    func testRestartAfterLostAckDoesNotDuplicate() async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: 1)
        store.setFailWrites(prefix: "docs/doc1/acks.json", true)   // Server speichert, Bestaetigung geht lokal verloren
        await engine.updatePage("p1", page(["a", "b"]))
        await engine.syncNow()
        let failed = await engine.status
        if case .localSaveFailed = failed {} else { XCTFail("Status muss den Schreibfehler zeigen, war \(failed)") }
        store.setFailWrites(prefix: "docs/doc1/acks.json", false)
        let restarted = makeEngine(server, store)
        _ = await restarted.open(pdfPageCount: 1)
        await restarted.syncNow()
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["a", "b"], "keine doppelten Striche")
        let status = await restarted.status
        XCTAssertEqual(status, .saved)
    }

    // MARK: Fehlgeschlagenes lokales Speichern

    func testFailedLocalSaveIsNeverShownAsSaved() async {
        let server = MockServer(), store = MemoryBlobStore()
        await server.setOnline(false)
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: 1)
        store.setFailAllWrites(true)
        await engine.updatePage("p1", page(["a"]))
        let st = await engine.status
        guard case .localSaveFailed = st else { return XCTFail("erwartet localSaveFailed, war \(st)") }
        XCTAssertFalse(st.isSafeLocally)
        // Speicher wieder frei: naechste Aenderung sichert alles nach
        store.setFailAllWrites(false)
        await engine.updatePage("p1", page(["a", "b"]))
        let after = await engine.status
        if case .localSaveFailed = after { XCTFail("nach erfolgreichem Schreiben kein Fehler mehr") }
        XCTAssertTrue(after.isSafeLocally)
        XCTAssertNotEqual(after, .saved, "Server war nie erreichbar")
        await engine.shutdown()
        let restarted = makeEngine(server, store)
        let opened = await restarted.open(pdfPageCount: 1)
        XCTAssertEqual(opened.document.objects(page: "p1").count, 2)
    }

    // MARK: Konflikte zwischen Geraeten

    func testVersionConflictOnDifferentPagesMergesBoth() async {
        let server = MockServer()
        let ipad = makeEngine(server, MemoryBlobStore())
        _ = await ipad.open(pdfPageCount: 2)
        await server.externalEdit { $0.pages["p2"] = page(["browser"]) }     // Browser speichert zuerst
        await ipad.updatePage("p1", page(["ipad"]))
        await ipad.syncNow()
        let p1 = await server.objectIDs(page: "p1"), p2 = await server.objectIDs(page: "p2")
        XCTAssertEqual(p1, ["ipad"])
        XCTAssertEqual(p2, ["browser"])
        let conflicts = await ipad.stats.conflicts
        XCTAssertEqual(conflicts, 1)
    }

    func testSimultaneousEditsOnSamePageKeepBothDevices() async {
        let server = MockServer()
        let a = makeEngine(server, MemoryBlobStore(), id: "doc1")
        let b = makeEngine(server, MemoryBlobStore(), id: "doc1")
        _ = await a.open(pdfPageCount: 1)
        await a.updatePage("p1", page(["gemeinsam"]))
        await a.syncNow()
        _ = await b.open(pdfPageCount: 1)                          // beide kennen jetzt "gemeinsam"
        await a.updatePage("p1", page(["gemeinsam", "von-a"]))
        await b.updatePage("p1", page(["gemeinsam", "von-b"]))
        await a.syncNow()
        await b.syncNow()                                          // 409 -> objektweise zusammenfuehren
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(Set(ids), ["gemeinsam", "von-a", "von-b"])
        // a bekommt den Stand von b beim naechsten Oeffnen
        let a2 = makeEngine(server, MemoryBlobStore(), id: "doc1")
        let opened = await a2.open(pdfPageCount: 1)
        XCTAssertEqual(Set(opened.document.objects(page: "p1").compactMap { $0["id"]?.string }), ["gemeinsam", "von-a", "von-b"])
    }

    func testDeleteOnOneDeviceIsNotUndoneByOther() async {
        let server = MockServer()
        let a = makeEngine(server, MemoryBlobStore())
        let b = makeEngine(server, MemoryBlobStore())
        _ = await a.open(pdfPageCount: 1)
        await a.updatePage("p1", page(["x", "y"]))
        await a.syncNow()
        _ = await b.open(pdfPageCount: 1)
        await a.updatePage("p1", page(["y"]))                     // a radiert x
        await a.syncNow()
        await b.updatePage("p1", page(["x", "y", "z"]))           // b kennt x noch, ergaenzt z
        await b.syncNow()
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["y", "z"], "geloeschtes x kommt nicht zurueck")
    }

    func testRemoteChangeIsReportedForDisplayedPage() async {
        let server = MockServer()
        let engine = makeEngine(server, MemoryBlobStore())
        _ = await engine.open(pdfPageCount: 2)
        let box = ChangedBox()
        await engine.setHandlers(onStatus: nil, onRemoteChange: { keys in box.add(keys) })
        await server.externalEdit { $0.pages["p2"] = page(["browser"]) }
        await engine.updatePage("p1", page(["ipad"]))
        await engine.syncNow()
        XCTAssertEqual(box.keys, ["p2"])
    }
}

final class ChangedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ k: [String]) { lock.lock(); stored += k; lock.unlock() }
    var keys: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
