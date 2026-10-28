import XCTest
@testable import UniFlowCore

/// Haertungen des Editors, Schritt 2 (docs/PENCILKIT-ANALYSE-PLAN.md P0-3, P0-4, P0-6) im Kern:
/// - Obergrenze beim Sichern: Seiten, die der Editor waehrend des Schreibens sichert (`holdUpload`), gehen sofort ins
///   Journal, starten aber keine Upload-Runde; eine laufende Runde endet, ohne dass die naechste folgt.
/// - Formatschutz: Notizen mit `version` > 2 nur ansehen, nie speichern (packages/shared-contracts/README.md).
/// - Dasselbe Dokument in einem zweiten Fenster: Journal und Server lesen, nichts schreiben.
/// Jeder Test hat eine Gegenprobe im selben Ablauf (ohne Halten bzw. mit Format 2 laeuft der normale Weg).
final class SyncEngineHardeningTests: XCTestCase {

    // MARK: Obergrenze beim Sichern (P0-3)

    func testHeldPageIsJournaledButNotUploadedUntilReleased() async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: 2)
        await engine.updatePage("p1", page(["a"]), holdUpload: true)
        try? await Task.sleep(nanoseconds: 150_000_000)            // Upload-Pause ist 0 s: ohne Halten laengst gesendet
        let putsHeld = await server.putCount
        XCTAssertEqual(putsHeld, 0, "gehalten: keine Runde")
        // im Journal (so faende ein Neustart die Seite als ungesendet)
        let snapshot = try? LocalJournal(store: store, documentID: "doc1").load()
        XCTAssertEqual(snapshot?.pages["p1"]?.page, page(["a"]), "Seite ist lokal gesichert")

        await engine.releaseUploadHold()
        let sent = await waitUntil { await server.objectIDs(page: "p1") == ["a"] }
        XCTAssertTrue(sent, "nach der Schreibpause hochgeladen")

        // Gegenprobe: ohne Halten geht die Aenderung von selbst hoch
        await engine.updatePage("p2", page(["b"]))
        let normal = await waitUntil { await server.objectIDs(page: "p2") == ["b"] }
        XCTAssertTrue(normal)
    }

    /// Dauerschreiben waehrend einer langen Runde: die laufende Runde endet normal, die naechste beginnt erst nach der
    /// Schreibpause. Ohne Halten folgte sie sofort (Gegenprobe am Ende).
    func testRunningRoundIsNotFollowedByAnotherWhileWritingContinues() async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: 1)
        await engine.updatePage("p1", page(["a"]))
        await server.holdNext()
        let upload = Task { await engine.syncNow() }
        let held = await waitUntil { await server.isHoldingPut }
        XCTAssertTrue(held)
        await engine.updatePage("p1", page(["a", "b"]), holdUpload: true)     // Editor schreibt weiter
        await engine.updatePage("p1", page(["a", "b", "c"]), holdUpload: true)
        await server.releaseHeldPut()
        await upload.value
        try? await Task.sleep(nanoseconds: 150_000_000)
        let puts = await server.putCount
        XCTAssertEqual(puts, 1, "keine zweite Runde, solange geschrieben wird")
        let onServer = await server.objectIDs(page: "p1")
        XCTAssertEqual(onServer, ["a"])
        let status = await engine.status
        XCTAssertEqual(status, .pending(pages: 1), "lokal gesichert, wartet")

        await engine.releaseUploadHold()
        let sent = await waitUntil { await server.objectIDs(page: "p1") == ["a", "b", "c"] }
        XCTAssertTrue(sent)
        let total = await server.putCount
        XCTAssertEqual(total, 2)

        // Gegenprobe: ohne Halten folgt die zweite Runde direkt
        await server.holdNext()
        await engine.updatePage("p1", page(["a", "b", "c", "d"]))
        _ = await waitUntil { await server.isHoldingPut }
        await engine.updatePage("p1", page(["a", "b", "c", "d", "e"]))
        await server.releaseHeldPut()
        let followed = await waitUntil { await server.objectIDs(page: "p1").count == 5 }
        XCTAssertTrue(followed, "ohne Halten: naechste Runde sofort")
    }

    /// Export, Hintergrund und Schliessen (`requestUpload`, `syncNow`) heben das Halten auf.
    func testSyncNowAndRequestUploadEndTheHold() async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        _ = await engine.open(pdfPageCount: 1)
        await engine.updatePage("p1", page(["a"]), holdUpload: true)
        await engine.syncNow()
        let first = await server.objectIDs(page: "p1")
        XCTAssertEqual(first, ["a"])
        await engine.updatePage("p1", page(["a", "b"]), holdUpload: true)
        await engine.requestUpload()
        let second = await waitUntil { await server.objectIDs(page: "p1") == ["a", "b"] }
        XCTAssertTrue(second)
        let written = await engine.stats.pageWrites
        XCTAssertEqual(written, 2, "jede gehaltene Seite ging ins Journal")
    }

    // MARK: Formatschutz (P0-4)

    /// Serverstand in Version 3: nur ansehen. Kein Upload, kein Journal, Aenderungen werden nicht angenommen; der
    /// angezeigte Stand ist der des Servers. Gegenprobe: Version 2 oeffnet normal.
    func testNewerFormatOnServerOpensViewOnlyAndWritesNothing() async {
        let server = MockServer(), store = MemoryBlobStore()
        await server.externalEdit { doc in
            doc.root["version"] = 3
            doc.root["neuesFeld"] = "aus einer neueren App"
            doc.pages = ["p1": page(["neu"])]
        }
        let engine = makeEngine(server, store)
        let opened = await engine.open(pdfPageCount: 1)
        XCTAssertEqual(opened.viewOnly, .newerFormat(3))
        XCTAssertEqual(opened.document.objects(page: "p1").compactMap { $0["id"]?.string }, ["neu"], "Stand wird angezeigt")
        await engine.updatePage("p1", page(["hier"]))
        let meta = await engine.updateRootMeta(AnnotationDocument.empty().rootMeta)
        XCTAssertFalse(meta)
        await engine.syncNow()
        await engine.requestUpload()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let puts = await server.putCount, writes = store.writeCount
        XCTAssertEqual(puts, 0, "nie ueber eine neuere Version speichern")
        XCTAssertEqual(writes, 0, "nichts ins Journal")
        let root = await server.root
        XCTAssertEqual(root["neuesFeld"], "aus einer neueren App")
        let reason = await engine.viewOnlyReason
        XCTAssertEqual(reason, .newerFormat(3))

        // Gegenprobe: Version 2 normal
        let plain = MockServer()
        await plain.externalEdit { $0.pages = ["p1": page(["alt"])] }
        let normal = makeEngine(plain, MemoryBlobStore(), id: "doc2")
        let ok = await normal.open(pdfPageCount: 1)
        XCTAssertNil(ok.viewOnly)
        await normal.updatePage("p1", page(["alt", "neu"]))
        await normal.syncNow()
        let ids = await plain.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["alt", "neu"])
    }

    /// Neuere Version im Journal (z. B. App zurueckgespielt): nur ansehen, ungesendete Seiten bleiben im Journal und
    /// werden nicht hochgeladen.
    func testNewerFormatInJournalKeepsUnsentPagesAndUploadsNothing() async {
        let server = MockServer(), store = MemoryBlobStore()
        let first = makeEngine(server, store)
        _ = await first.open(pdfPageCount: 1)
        await server.setOnline(false)
        await first.updatePage("p1", page(["lokal"]))
        var meta = await first.currentDocument().rootMeta
        meta["version"] = 4
        _ = await first.updateRootMeta(meta)                       // wie eine neuere App es gesichert haette
        await first.syncNow()                                      // scheitert offline; danach laeuft nichts mehr
        await first.shutdown()
        await server.setOnline(true)

        let second = makeEngine(server, store)
        let opened = await second.open(pdfPageCount: 1)
        XCTAssertEqual(opened.viewOnly, .newerFormat(4))
        XCTAssertEqual(opened.document.objects(page: "p1").compactMap { $0["id"]?.string }, ["lokal"])
        await second.syncNow()
        let puts = await server.putCount
        XCTAssertEqual(puts, 0)
        let snapshot = try? LocalJournal(store: store, documentID: "doc1").load()
        XCTAssertEqual(snapshot?.pages["p1"]?.page["objects"]?.array?.count, 1, "ungesendete Seite bleibt im Journal")
    }

    /// Waehrend der Sitzung speichert ein anderes Geraet Version 3: der naechste Upload bekommt 409 mit dem neueren
    /// Stand. Nicht zusammenfuehren, nicht darueber speichern, Hinweis an den Editor; was schon geschrieben ist, bleibt
    /// im Journal.
    func testNewerFormatArrivingDuringTheSessionStopsUploadsAndKeepsTheJournal() async {
        let server = MockServer(), store = MemoryBlobStore()
        let engine = makeEngine(server, store)
        let reasons = ReasonBox()
        await engine.setViewOnlyHandler { reasons.add($0) }
        _ = await engine.open(pdfPageCount: 1)
        await server.externalEdit { doc in
            doc.root["version"] = 3
            doc.pages = ["p1": page(["anderes-geraet"])]
        }
        await engine.updatePage("p1", page(["hier"]))
        await engine.syncNow()
        let stopped = await waitUntil { reasons.all == [.newerFormatOnServer(3)] }
        XCTAssertTrue(stopped, "Editor erfaehrt es")
        let onServer = await server.objectIDs(page: "p1"), version = await server.root["version"]
        XCTAssertEqual(onServer, ["anderes-geraet"], "nichts ueberschrieben")
        XCTAssertEqual(version, 3)
        let puts = await server.putCount
        XCTAssertEqual(puts, 1, "nur der eine Versuch, der 409 bekam")
        await engine.updatePage("p1", page(["hier", "weiter"]))     // landet noch im Journal, geht aber nicht hoch
        await engine.syncNow()
        let after = await server.putCount
        XCTAssertEqual(after, 1)
        let snapshot = try? LocalJournal(store: store, documentID: "doc1").load()
        XCTAssertEqual(snapshot?.pages["p1"]?.page["objects"]?.array?.count, 2)
    }

    // MARK: Zweites Fenster (P0-6)

    /// Fenster A hat ungesendete Striche im Journal; Fenster B oeffnet dasselbe Dokument nur zum Ansehen: es zeigt den
    /// Stand aus dem Journal, schreibt nichts hinein und laedt nichts hoch, auch nicht nach einem neueren Serverstand.
    func testSecondWindowReadsJournalAndServerButWritesNothing() async {
        let server = MockServer(), store = MemoryBlobStore()
        let a = makeEngine(server, store)
        _ = await a.open(pdfPageCount: 2)
        await server.setOnline(false)
        await a.updatePage("p1", page(["a1"]))
        await a.shutdown()                                         // keine Wiederholungen von A waehrend der Pruefung
        await server.setOnline(true)
        await server.externalEdit { $0.pages = ["p2": page(["browser"])] }
        let writesBefore = store.writeCount

        let b = makeEngine(server, store)
        let opened = await b.open(pdfPageCount: 2, openElsewhere: true)
        XCTAssertEqual(opened.viewOnly, .openElsewhere)
        XCTAssertEqual(opened.document.objects(page: "p1").compactMap { $0["id"]?.string }, ["a1"], "ungesendeter Stand aus A")
        XCTAssertEqual(opened.document.objects(page: "p2").compactMap { $0["id"]?.string }, ["browser"], "Serverstand")
        await b.updatePage("p1", page(["b1"]))
        await b.syncNow()
        let bStats = await b.stats
        XCTAssertEqual(bStats.puts, 0)
        XCTAssertEqual(bStats.pageWrites, 0)
        XCTAssertEqual(store.writeCount, writesBefore, "B schreibt nichts ins Journal")

        // Gegenprobe: A schreibt und laedt weiter wie bisher
        await a.syncNow()
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["a1"])
    }
}

final class ReasonBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [NotesViewOnlyReason] = []
    func add(_ r: NotesViewOnlyReason) { lock.lock(); reasons.append(r); lock.unlock() }
    var all: [NotesViewOnlyReason] { lock.lock(); defer { lock.unlock() }; return reasons }
}
