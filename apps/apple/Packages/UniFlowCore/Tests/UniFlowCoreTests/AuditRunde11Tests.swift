import Foundation
import XCTest
@testable import UniFlowCore

// Externe Pruefpunkte 341-360 und 376/377 (docs/audit/RUNDE-11-331-380.md): Journal der Notizen (beschaedigte und
// nicht lesbare Dateien, Abbruch zwischen zwei Dateien, viele Seiten, Unicode-Namen, Bereinigung) und Abgleich (Loeschen
// gegen Bearbeiten, Wiederholungen nach dem Schliessen, wiederholte Konflikte, Konflikt ohne Ende). Erfundene Inhalte.

/// Speicher im Arbeitsspeicher mit gezielten Fehlern: Ordner nicht auflistbar, Datei nicht lesbar, ab einem Zeitpunkt
/// eingefroren (wie ein beendeter Prozess: nichts kommt mehr auf die Platte). Zaehlt Schreibzugriffe.
final class FaultyBlobStore: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var listFails: Set<String> = []
    private var readFails: Set<String> = []
    private var frozen = false
    private(set) var writes = 0
    /// nach jedem Schreiben oder Entfernen (Nummer des Zugriffs); laeuft ausserhalb der Sperre
    var onWrite: ((Int) -> Void)?

    init(files: [String: Data] = [:]) { self.files = files }

    func failList(_ dir: String, _ on: Bool = true) { locked { if on { listFails.insert(dir) } else { listFails.remove(dir) } } }
    func failRead(_ path: String, _ on: Bool = true) { locked { if on { readFails.insert(path) } else { readFails.remove(path) } } }
    func freeze() { locked { frozen = true } }
    var snapshot: [String: Data] { locked { files } }
    var paths: [String] { locked { files.keys.sorted() } }

    /// Sperre ohne `withLock` (unter Linux nicht ueberall mit `throws`)
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func read(_ path: String) throws -> Data? {
        try locked {
            if readFails.contains(path) { throw BlobStoreError(path: path, reason: "Lesen fehlgeschlagen") }
            return files[path]
        }
    }

    func write(_ data: Data, to path: String) throws {
        let n: Int = try locked {
            if frozen { throw BlobStoreError(path: path, reason: "Prozess beendet") }
            files[path] = data
            writes += 1
            return writes
        }
        onWrite?(n)
    }

    func remove(_ path: String) throws {
        let n: Int = try locked {
            if frozen { throw BlobStoreError(path: path, reason: "Prozess beendet") }
            files.removeValue(forKey: path)
            writes += 1
            return writes
        }
        onWrite?(n)
    }

    /// Eintraege direkt im Ordner, Dateien und Unterordner (wie das Dateisystem)
    func list(_ directory: String) throws -> [String] {
        try locked {
            if listFails.contains(directory) { throw BlobStoreError(path: directory, reason: "Ordner nicht lesbar") }
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            let names = files.keys.filter { $0.hasPrefix(prefix) }.compactMap { $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init) }
            return Array(Set(names)).sorted()
        }
    }

    func put(_ text: String, at path: String) { locked { files[path] = Data(text.utf8) } }
}

/// Server wie `MockServer`, nach einem "Absturz" des Geraets (`crashed`) aber fuer dieses Geraet nicht mehr erreichbar
final class CrashFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

struct CrashableTransport: AnnotationTransport {
    let server: MockServer
    let crashed: CrashFlag
    func fetch(documentID: String) async throws -> ServerSnapshot {
        if crashed.isSet { throw TestError.offline }
        return try await server.fetch(documentID: documentID)
    }
    func put(documentID: String, root: JSONValue, baseVersion: Int) async throws -> PutOutcome {
        if crashed.isSet { throw TestError.offline }
        return try await server.put(documentID: documentID, root: root, baseVersion: baseVersion)
    }
}

/// Zaehlt jeden Versuch (Abruf und Speichern), auch ohne Netz
actor CallCounter {
    private(set) var calls = 0
    func add() { calls += 1 }
}

struct CountingTransport: AnnotationTransport {
    let inner: AnnotationTransport
    let counter: CallCounter
    func fetch(documentID: String) async throws -> ServerSnapshot {
        await counter.add()
        return try await inner.fetch(documentID: documentID)
    }
    func put(documentID: String, root: JSONValue, baseVersion: Int) async throws -> PutOutcome {
        await counter.add()
        return try await inner.put(documentID: documentID, root: root, baseVersion: baseVersion)
    }
}

/// Ein anderes Geraet speichert vor jedem Speichern dieses Geraets (solange `churning`): immer 409
actor ChurningServer: AnnotationTransport {
    let server = MockServer()
    var churning = true
    private var n = 0
    func setChurning(_ on: Bool) { churning = on }
    func fetch(documentID: String) async throws -> ServerSnapshot { try await server.fetch(documentID: documentID) }
    func put(documentID: String, root: JSONValue, baseVersion: Int) async throws -> PutOutcome {
        if churning {
            n += 1
            let id = "web\(n)"
            await server.externalEdit { $0.pages["p9"] = page([id]) }
        }
        return try await server.put(documentID: documentID, root: root, baseVersion: baseVersion)
    }
}

final class AuditRunde11JournalTests: XCTestCase {

    private func engine(_ transport: AnnotationTransport, _ store: BlobStore, id: String = "doc1") -> SyncEngine {
        SyncEngine(documentID: id, transport: transport, journal: LocalJournal(store: store, documentID: id), uploadDelay: 0, sleeper: fastSleeper)
    }

    private func ids(_ doc: AnnotationDocument, _ key: String) -> [String] { doc.objects(page: key).compactMap { $0["id"]?.string } }

    /// Seitenliste mit eingefuegter Leerseite und Lesezeichen (Stand des Servers, den ein leeres meta.json ersetzen wuerde)
    private func richMeta(_ doc: AnnotationDocument) -> JSONValue {
        var meta = doc.rootMeta
        var order = doc.pageOrder
        order.insert(["key": "b1", "type": "blank", "template": "lined", "w": 595, "h": 842], at: 1)
        meta["pageOrder"] = .array(order)
        meta["bookmarks"] = [["key": "b1", "title": "Zusammenfassung"]]
        return meta
    }

    // MARK: 341 beschaedigte meta.json

    func testDamagedMetaKeepsThePagesAndTakesTheServerListBeforeUploading() async throws {
        let server = MockServer(), store = FaultyBlobStore()
        let a = engine(server, store)
        let opened = await a.open(pdfPageCount: 2)
        await a.updateRootMeta(richMeta(opened.document))
        await a.updatePage("p1", page(["s1"]))
        await a.updatePage("b1", page(["leer1"]))
        await a.syncNow()
        await server.setOnline(false)
        await a.updatePage("p2", page(["offline"]))                       // ungesendet
        await a.syncNow()
        await a.shutdown()
        store.put("{\"rootMeta\": {\"pageOrder\": [", at: "docs/doc1/meta.json")   // abgeschnitten

        await server.setOnline(true)
        let b = engine(server, store)
        let reopened = await b.open(pdfPageCount: 2)
        XCTAssertEqual(reopened.damagedFiles, ["meta.json"])
        XCTAssertEqual(reopened.restoredUnsentPages, 1)
        XCTAssertEqual(ids(reopened.document, "p2"), ["offline"], "ungesendete Seite bleibt")
        XCTAssertEqual(reopened.document.pageOrder.compactMap { $0["key"]?.string }, ["p1", "b1", "p2"], "Seitenliste vom Server")
        await b.syncNow()
        let onServer = AnnotationDocument(root: await server.root)
        XCTAssertEqual(onServer.pageOrder.compactMap { $0["key"]?.string }, ["p1", "b1", "p2"], "Leerseite nicht verloren")
        XCTAssertEqual(onServer.root["bookmarks"]?.array?.count, 1, "Lesezeichen nicht verloren")
        XCTAssertEqual(ids(onServer, "p2"), ["offline"])
        XCTAssertEqual(ids(onServer, "b1"), ["leer1"])
        let status = await b.status
        XCTAssertEqual(status, .saved)
        // meta.json wieder gueltig, die beschaedigte Fassung aufbewahrt
        let again = try XCTUnwrap(try LocalJournal(store: store, documentID: "doc1").load())
        XCTAssertEqual(again.damaged, [])
        XCTAssertEqual(store.snapshot["docs/doc1/damaged/meta.json"].map { String(decoding: $0, as: UTF8.self) }, "{\"rootMeta\": {\"pageOrder\": [")
    }

    /// Ohne Netz und mit beschaedigter meta.json: keine Aenderung der Seitenliste auf der leeren Vorgabe, kein Upload
    /// vor dem Serverstand; danach geht alles normal
    func testDamagedMetaWhileOfflineBlocksListChangesUntilTheServerAnswers() async throws {
        let server = MockServer(), store = FaultyBlobStore()
        let a = engine(server, store)
        let opened = await a.open(pdfPageCount: 2)
        await a.updateRootMeta(richMeta(opened.document))
        await a.syncNow()
        await a.shutdown()
        store.put("kaputt", at: "docs/doc1/meta.json")
        await server.setOnline(false)
        let b = engine(server, store)
        let offline = await b.open(pdfPageCount: 2)
        let known = await b.rootMetaKnown
        XCTAssertFalse(known)
        let accepted = await b.updateRootMeta(offline.document.rootMeta)
        XCTAssertFalse(accepted, "Seitenliste erst nach dem Serverstand aenderbar")
        await b.updatePage("p1", page(["strich"]))
        XCTAssertEqual(String(decoding: store.snapshot["docs/doc1/meta.json"] ?? Data(), as: UTF8.self), "kaputt",
                       "die leere Vorgabe ersetzt die Datei nicht")
        await server.setOnline(true)
        let saved = await waitUntil(timeout: 5) { await b.status == .saved }
        XCTAssertTrue(saved)
        let onServer = AnnotationDocument(root: await server.root)
        XCTAssertEqual(onServer.pageOrder.compactMap { $0["key"]?.string }, ["p1", "b1", "p2"])
        XCTAssertEqual(ids(onServer, "p1"), ["strich"])
        let nowKnown = await b.rootMetaKnown
        XCTAssertTrue(nowKnown)
        await b.shutdown()
    }

    // MARK: 342 beschaedigte acks.json

    func testDamagedAcksDoNotBringBackStrokesDeletedInTheBrowser() async throws {
        let server = MockServer(), store = FaultyBlobStore()
        let a = engine(server, store)
        _ = await a.open(pdfPageCount: 2)
        await a.updatePage("p1", page(["x", "y"]))
        await a.updatePage("p2", page(["a"]))
        await a.syncNow()
        await server.setOnline(false)
        await a.updatePage("p2", page(["a", "b"]))                        // ungesendet, Basis [a]
        await a.syncNow()
        await a.shutdown()
        await server.setOnline(true)
        await server.externalEdit { $0.pages["p1"] = page(["y"]) }          // Browser loescht x
        store.put("{\"serverVersion\": 1, \"acked\": {", at: "docs/doc1/acks.json")

        let b = engine(server, store)
        let reopened = await b.open(pdfPageCount: 2)
        XCTAssertEqual(reopened.damagedFiles, ["acks.json"])
        await b.syncNow()
        let p1 = await server.objectIDs(page: "p1"), p2 = await server.objectIDs(page: "p2")
        XCTAssertEqual(p1, ["y"], "im Browser geloeschtes x kommt nicht zurueck")
        XCTAssertEqual(p2, ["a", "b"], "ungesendetes b kommt an, a genau einmal")
        let local = await b.page("p1")?["objects"]?.array?.compactMap { $0["id"]?.string }
        XCTAssertEqual(local, ["y"])
        let status = await b.status
        XCTAssertEqual(status, .saved)
        let again = try XCTUnwrap(try LocalJournal(store: store, documentID: "doc1").load())
        XCTAssertEqual(again.damaged, [], "acks.json neu geschrieben")
        XCTAssertGreaterThan(again.serverVersion, 0)
    }

    // MARK: 343 einzelne beschaedigte Seitendatei

    func testDamagedPageFileIsTakenFromTheServerAndNeverUploadedEmpty() async throws {
        let server = MockServer(), store = FaultyBlobStore()
        let a = engine(server, store)
        _ = await a.open(pdfPageCount: 3)
        await a.updatePage("p1", page(["s1", "s2"]))
        await a.updatePage("p2", page(["t1"]))
        await a.syncNow()
        await server.setOnline(false)
        await a.updatePage("p2", page(["t1", "t2"]))
        await a.syncNow()
        await a.shutdown()
        await server.setOnline(true)
        store.put("{\"key\":\"p1\",\"localRev\":1,\"page\":{\"objects\":[{\"id\":\"s1\"", at: "docs/doc1/pages/p1.json")

        let b = engine(server, store)
        let reopened = await b.open(pdfPageCount: 3)
        XCTAssertEqual(reopened.damagedFiles, ["pages/p1.json"])
        XCTAssertEqual(ids(reopened.document, "p1"), ["s1", "s2"], "Seite aus dem Serverstand")
        XCTAssertEqual(ids(reopened.document, "p2"), ["t1", "t2"], "die anderen Seiten unberuehrt")
        await b.syncNow()
        let p1 = await server.objectIDs(page: "p1"), p2 = await server.objectIDs(page: "p2")
        XCTAssertEqual(p1, ["s1", "s2"], "nicht als leere Seite hochgeladen")
        XCTAssertEqual(p2, ["t1", "t2"])
        XCTAssertNotNil(store.snapshot["docs/doc1/damaged/pages_p1.json"], "beschaedigte Fassung aufbewahrt")
        let again = try XCTUnwrap(try LocalJournal(store: store, documentID: "doc1").load())
        XCTAssertEqual(again.damaged, [])
        XCTAssertEqual(again.pages["p1"]?.page["objects"]?.array?.count, 2)
    }

    /// Auf der beschaedigten Seite wird ohne Netz geschrieben: beim naechsten Abgleich bleiben die Striche des
    /// Servers und die neuen
    func testWritingOnADamagedPageOfflineKeepsServerAndNewStrokes() async throws {
        let server = MockServer(), store = FaultyBlobStore()
        let a = engine(server, store)
        _ = await a.open(pdfPageCount: 1)
        await a.updatePage("p1", page(["s1", "s2"]))
        await a.syncNow()
        await a.shutdown()
        store.put("{", at: "docs/doc1/pages/p1.json")
        await server.setOnline(false)
        let b = engine(server, store)
        let offline = await b.open(pdfPageCount: 1)
        XCTAssertEqual(ids(offline.document, "p1"), [], "Stand unbekannt, nichts erfunden")
        await b.updatePage("p1", page(["neu"]))
        await server.setOnline(true)
        let saved = await waitUntil(timeout: 5) { await b.status == .saved }
        XCTAssertTrue(saved)
        let p1 = await server.objectIDs(page: "p1")
        XCTAssertEqual(Set(p1), ["s1", "s2", "neu"])
        XCTAssertEqual(p1.count, 3)
        await b.shutdown()
    }

    /// Eine Datei laesst sich nicht lesen (Lesefehler statt kaputtem Inhalt): nur diese Seite ist betroffen
    func testUnreadablePageFileOnlyAffectsThatPage() async throws {
        let server = MockServer(), store = FaultyBlobStore()
        let a = engine(server, store)
        _ = await a.open(pdfPageCount: 2)
        await a.updatePage("p1", page(["s1"]))
        await a.updatePage("p2", page(["t1"]))
        await a.syncNow()
        await a.shutdown()
        store.failRead("docs/doc1/pages/p1.json")
        let snap = try XCTUnwrap(try LocalJournal(store: store, documentID: "doc1").load())
        XCTAssertEqual(snap.damaged, ["pages/p1.json"])
        XCTAssertEqual(snap.damagedPageKeys, ["p1"])
        XCTAssertEqual(snap.pages["p2"]?.page["objects"]?.array?.count, 1, "uebrige Seiten gelesen")
        let b = engine(server, store)
        let reopened = await b.open(pdfPageCount: 2)
        XCTAssertEqual(ids(reopened.document, "p1"), ["s1"], "aus dem Serverstand")
        await b.shutdown()
    }

    // MARK: 344/345/357/360 Abbruch an jeder Stelle

    /// Jeder Schreibzugriff eines Ablaufs kann der letzte sein (Absturz, Akku leer): danach ist auf der Platte je Datei
    /// der alte oder der neue Stand. Fuer jeden Zeitpunkt: Neustart, Abgleich. Ergebnis: alles, was auf dem Server
    /// oder lokal gesichert war, genau einmal; das im Browser geloeschte w0 kommt nie zurueck; Lesezeichen bleiben.
    func testCrashAfterEveryWriteKeepsEverythingExactlyOnce() async throws {
        func scenario(crashAt: Int?) async throws -> (store: FaultyBlobStore, server: MockServer, writes: Int) {
            let server = MockServer(), store = FaultyBlobStore(), crashed = CrashFlag()
            await server.externalEdit { $0.pages["p1"] = page(["w0"]) }
            store.onWrite = { n in
                guard n == crashAt else { return }
                store.freeze()
                crashed.set()
            }
            let e = engine(CrashableTransport(server: server, crashed: crashed), store)
            let opened = await e.open(pdfPageCount: 3)
            await e.updatePage("p1", page(["w0", "a"]))
            await e.syncNow()
            // Browser: loescht w0, ergaenzt w1
            await server.externalEdit { $0.pages["p1"] = page(["a", "w1"]) }
            await e.updatePage("p1", page(["w0", "a", "b"]))
            await e.updatePage("p2", page(["c"]))
            await e.syncNow()                                                 // 409, Zusammenfuehrung, Speichern
            var meta = opened.document.rootMeta
            meta["bookmarks"] = [["key": "p2", "title": "Merken"]]
            await e.updateRootMeta(meta)
            await e.updatePage("p3", page(["d"]))
            await e.syncNow()
            await e.shutdown()
            return (store, server, store.writes)
        }
        let total = try await scenario(crashAt: nil).writes
        XCTAssertGreaterThan(total, 10)
        for k in 1...total {
            let (frozen, server, _) = try await scenario(crashAt: k)
            // erwartet: Serverstand beim Absturz und lokal Gesichertes, ohne w0
            let local = try LocalJournal(store: frozen, documentID: "doc1").load()
            var expected = Set(await server.allObjectIDs())
            let localPages: [JournalPage] = local.map { Array($0.pages.values) } ?? []
            for p in localPages {
                let objects: [JSONValue] = p.page["objects"]?.array ?? []
                expected.formUnion(objects.compactMap { $0["id"]?.string })
            }
            expected.remove("w0")
            let serverRoot = await server.root
            let localBookmark = local?.rootMeta["bookmarks"]?.array?.isEmpty == false
            let hadBookmark = localBookmark || AnnotationDocument(root: serverRoot).root["bookmarks"]?.array?.isEmpty == false

            let restarted = engine(server, FaultyBlobStore(files: frozen.snapshot))
            _ = await restarted.open(pdfPageCount: 3)
            await restarted.syncNow()
            let all = await server.allObjectIDs()
            XCTAssertEqual(all.count, Set(all).count, "Absturz nach Zugriff \(k): doppelte Objekte \(all.sorted())")
            XCTAssertEqual(Set(all), expected, "Absturz nach Zugriff \(k)")
            XCTAssertFalse(all.contains("w0"), "Absturz nach Zugriff \(k): geloeschtes w0 zurueck")
            let bookmarks = AnnotationDocument(root: await server.root).root["bookmarks"]?.array ?? []
            XCTAssertEqual(!bookmarks.isEmpty, hadBookmark, "Absturz nach Zugriff \(k): Lesezeichen")
            let status = await restarted.status
            XCTAssertEqual(status, .saved, "Absturz nach Zugriff \(k)")
            await restarted.shutdown()
        }
    }

    /// 345: Seite gesichert, meta.json scheitert, die Bestaetigung nicht; danach Neustart. Die alte meta.json ist aelter
    /// als ihre Bestaetigung: der Serverstand gilt, die neue Seitenliste geht nicht verloren.
    func testPageSavedButMetaWriteFailedStaysConsistentAfterRestart() async throws {
        let server = MockServer(), store = MemoryBlobStore()
        let a = makeEngine(server, store)
        let opened = await a.open(pdfPageCount: 2)
        await a.syncNow()
        store.setFailWrites(prefix: "docs/doc1/meta.json", true)
        await a.updatePage("b1", page(["leer"]))
        await a.updateRootMeta(richMeta(opened.document))
        let failed = await a.status
        guard case .localSaveFailed = failed else { return XCTFail("Schreibfehler muss sichtbar sein, war \(failed)") }
        await a.syncNow()                                                     // Server hat die neue Liste
        let still = await a.status
        guard case .localSaveFailed = still else { return XCTFail("nie \"Gespeichert\" mit Schreibfehler, war \(still)") }
        await a.shutdown()
        store.setFailWrites(prefix: "docs/doc1/meta.json", false)

        let b = makeEngine(server, store)
        let reopened = await b.open(pdfPageCount: 2)
        XCTAssertEqual(reopened.document.pageOrder.compactMap { $0["key"]?.string }, ["p1", "b1", "p2"])
        await b.updatePage("p1", page(["spaeter"]))
        await b.syncNow()
        let onServer = AnnotationDocument(root: await server.root)
        XCTAssertEqual(onServer.pageOrder.compactMap { $0["key"]?.string }, ["p1", "b1", "p2"], "Leerseite bleibt in der Liste")
        XCTAssertEqual(onServer.root["bookmarks"]?.array?.count, 1)
        XCTAssertEqual(ids(onServer, "b1"), ["leer"])
        XCTAssertEqual(ids(onServer, "p1"), ["spaeter"])
    }

    // MARK: 346 Journal nicht lesbar

    func testUnreadableJournalIsNeverOverwrittenAndStaysViewOnly() async throws {
        let server = MockServer(), store = FaultyBlobStore()
        let a = engine(server, store)
        _ = await a.open(pdfPageCount: 2)
        await a.updatePage("p1", page(["synced"]))
        await a.syncNow()
        await server.setOnline(false)
        await a.updatePage("p2", page(["nur-lokal"]))                    // ungesendet
        await a.syncNow()
        await a.shutdown()
        await server.setOnline(true)
        await server.externalEdit { $0.pages["p2"] = page(["web"]) }

        store.failList("docs/doc1/pages")
        let writesBefore = store.writes
        let b = engine(server, store)
        let opened = await b.open(pdfPageCount: 2)
        XCTAssertTrue(opened.journalUnreadable)
        XCTAssertEqual(ids(opened.document, "p2"), ["web"], "Serverstand zum Ansehen")
        let status = await b.status
        guard case .localSaveFailed(let m) = status else { return XCTFail("sichtbar, war \(status)") }
        XCTAssertTrue(m.contains("erneut öffnen"), m)
        await b.updatePage("p1", page(["verworfen"]))
        await b.syncNow()
        XCTAssertEqual(store.writes, writesBefore, "nichts ins Journal geschrieben")
        let puts = await server.putCount
        XCTAssertEqual(puts, 1, "nichts hochgeladen (nur der erste Abgleich)")
        await b.shutdown()

        // Ordner wieder lesbar: erneut oeffnen, die ungesendete Seite ist da und wird mit dem Browser zusammengefuehrt
        store.failList("docs/doc1/pages", false)
        let c = engine(server, store)
        let again = await c.open(pdfPageCount: 2)
        XCTAssertFalse(again.journalUnreadable)
        await c.syncNow()
        let p2 = await server.objectIDs(page: "p2")
        XCTAssertEqual(Set(p2), ["nur-lokal", "web"])
    }

    // MARK: 347 viele Seiten

    func testManyPagesLoadQuicklyAndTheJournalDoesNotGrowWithEdits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-journal-last-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileBlobStore(root: dir)
        let server = MockServer()
        await server.setOnline(false)
        let e = engine(server, store)
        _ = await e.open(pdfPageCount: 120)
        let start = Date()
        for p in 1...120 { await e.updatePage("p\(p)", page((0..<60).map { "p\(p)-s\($0)" })) }
        let writeSeconds = Date().timeIntervalSince(start)
        let size1 = folderBytes(dir)
        // 300 Aenderungen derselben Seite: je Seite eine Datei mit dem letzten Stand (kein Anhaengen)
        var ids = (0..<60).map { "p1-s\($0)" }
        for i in 0..<300 {
            ids.append("neu\(i)")
            await e.updatePage("p1", page(ids))
        }
        await e.shutdown()
        let files = try FileManager.default.subpathsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.filter { $0.contains("/pages/") }.count, 120)
        let size2 = folderBytes(dir)
        let loadStart = Date()
        let snap = try XCTUnwrap(try LocalJournal(store: store, documentID: "doc1").load())
        let loadSeconds = Date().timeIntervalSince(loadStart)
        XCTAssertEqual(snap.pages.count, 120)
        XCTAssertEqual(snap.pages["p1"]?.page["objects"]?.array?.count, 360)
        XCTAssertEqual(snap.damaged, [])
        print("Journal 120 Seiten x 60 Striche: \(size1 / 1024) KB, schreiben \(String(format: "%.2f", writeSeconds)) s; "
              + "nach 300 Aenderungen \(size2 / 1024) KB, laden \(String(format: "%.2f", loadSeconds)) s")
        // die Seite p1 waechst um 300 Striche (auf das Sechsfache einer Seite), nicht um 300 Fassungen
        XCTAssertLessThan(size2, size1 * 2)
        XCTAssertLessThan(loadSeconds, 10)
    }

    private func folderBytes(_ url: URL) -> Int {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let f = e?.nextObject() as? URL { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }

    // MARK: 348 Unicode und lange Schluessel

    func testUnicodeAndLongNamesSurviveWritingAndReading() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-journal-namen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileBlobStore(root: dir)
        let keys = ["p1", "Übung 3 – Lösung", "e\u{301}cole", "\u{e9}cole-nfc", "📝 Notiz", "a/b", "..", "~x", "",
                    String(repeating: "x", count: 130), String(repeating: "ü", count: 70), String(repeating: "ab", count: 300)]
        let docIDs = ["Skript Übung 1.pdf", String(repeating: "ä", count: 200), "doc/../ok"]
        for id in docIDs {
            let j = LocalJournal(store: store, documentID: id, namespace: .local)
            for (i, k) in keys.enumerated() {
                try j.writePage(k, JournalPage(page: page(["s\(i)"]), localRev: i + 1))
                try j.writeBase(k, page(["b\(i)"]))
            }
            try j.writeMeta(rootMeta: ["pageOrder": []], metaRev: 1, baseRootMeta: nil)
            let snap = try XCTUnwrap(try j.load(), id)
            XCTAssertEqual(snap.damaged, [], id)
            // Schluessel byte-genau (NFC und NFD bleiben verschieden geschrieben)
            for (i, k) in keys.enumerated() {
                let found = snap.pages.first { Array($0.key.utf8) == Array(k.utf8) }
                XCTAssertEqual(found?.value.localRev, i + 1, "\(id) / \(k)")
                XCTAssertNotNil(snap.bases.first { Array($0.key.utf8) == Array(k.utf8) }, "Basis \(k)")
            }
        }
        // jeder Dateiname bleibt unter der Grenze des Dateisystems, kurze bleiben umkehrbar
        for k in keys + docIDs {
            XCTAssertLessThanOrEqual(Array((LocalJournal.safeName(k) + ".json").utf8).count, 255, k)
            if Array(k.utf8).count <= LocalJournal.maxHexKeyBytes {
                XCTAssertEqual(LocalJournal.unsafeName(LocalJournal.safeName(k) + ".json").map { Array($0.utf8) }, Array(k.utf8), k)
            }
        }
        // Ordner der Dokumente: Kennungen aus dem Namen zurueck (Diagnose)
        let dirs = try store.list(LocalJournal.documentsDirectory(.local))
        XCTAssertTrue(dirs.contains { LocalJournal.documentID(forDirectory: $0) == "Skript Übung 1.pdf" })
    }

    // MARK: 349 Schreibfehler nie "Gespeichert"

    func testFailedBaseMetaOrAckWritesNeverShowSaved() async throws {
        for failing in ["docs/doc1/base", "docs/doc1/meta.json", "docs/doc1/acks.json"] {
            let server = MockServer(), store = MemoryBlobStore()
            let e = makeEngine(server, store)
            let opened = await e.open(pdfPageCount: 1)
            await e.syncNow()
            store.setFailWrites(prefix: failing, true)
            // Upload (uploadDelay 0) anhalten, bis der Status geprueft ist: sonst kann die Bestaetigung vorher
            // ankommen, die Basis ist dann nicht mehr noetig und der Status zu Recht "wird hochgeladen"
            await server.holdNext()
            await e.updatePage("p1", page(["a"]))
            var meta = opened.document.rootMeta
            meta["bookmarks"] = [["key": "p1", "title": "x"]]
            await e.updateRootMeta(meta)
            let held = await waitUntil { await server.isHoldingPut }
            XCTAssertTrue(held, "\(failing): Upload startet nach der Aenderung")
            if failing != "docs/doc1/acks.json" {
                let before = await e.status
                if case .localSaveFailed = before {} else { XCTFail("\(failing) vor dem Upload: \(before)") }
            }
            await server.releaseHeldPut()
            await e.syncNow()
            let s = await e.status
            if failing == "docs/doc1/base" {
                // nach der Bestaetigung braucht die Seite keine Basis mehr: alles ist gesichert, "Gespeichert" stimmt
                XCTAssertEqual(s, .saved, failing)
                XCTAssertNotNil(store.paths.first { $0 == "docs/doc1/pages/p1.json" })
            } else {
                if case .localSaveFailed = s {} else { XCTFail("\(failing): \(s)") }
                XCTAssertNotEqual(s, .saved, failing)
            }
            store.setFailWrites(prefix: failing, false)
            await e.updatePage("p1", page(["a", "b"]))
            await e.syncNow()
            let after = await e.status
            XCTAssertEqual(after, .saved, "\(failing): nach erfolgreichem Schreiben")
            await e.shutdown()
        }
    }

    // MARK: 350 Bereinigung

    /// Die Basis einer Seite geht erst mit der Bestaetigung; auf dem Server geloeschte Seite mit ungesendeten
    /// Strichen bleibt
    func testCleanupNeverDropsUnconfirmedChanges() async throws {
        let server = MockServer(), store = MemoryBlobStore()
        let e = makeEngine(server, store)
        _ = await e.open(pdfPageCount: 2)
        await e.updatePage("p1", page(["a"]))
        await e.syncNow()
        await server.holdNext()
        await e.updatePage("p1", page(["a", "b"]))
        let upload = Task { await e.syncNow() }
        _ = await waitUntil { await server.isHoldingPut }
        XCTAssertTrue(store.paths.contains("docs/doc1/base/p1.json"), "Basis bleibt, solange nicht bestaetigt")
        await server.releaseHeldPut()
        await upload.value
        XCTAssertFalse(store.paths.contains("docs/doc1/base/p1.json"), "nach der Bestaetigung weg")

        // fehlgeschlagener Upload: Basis und Seite bleiben
        await server.setFailStatus(503)
        await e.updatePage("p1", page(["a", "b", "c"]))
        await e.syncNow()
        XCTAssertTrue(store.paths.contains("docs/doc1/base/p1.json"))
        await e.shutdown()
        await server.setFailStatus(nil)

        // anderswo geloeschte Seite, hier ungesendet beschrieben: bleibt und kommt hoch
        await server.externalEdit { $0.pages["p1"] = nil }
        let again = makeEngine(server, store)
        _ = await again.open(pdfPageCount: 2)
        await again.syncNow()
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["a", "b", "c"])
    }

    // MARK: 376/377 Diagnose

    func testDiagnosisReportsUnreadableJournalsInsteadOfSkippingThem() async throws {
        let store = FaultyBlobStore()
        let server = MockServer()
        await server.setOnline(false)
        for id in ["ok", "kaputt", "unlesbar"] {
            let e = SyncEngine(documentID: id, transport: server, journal: LocalJournal(store: store, documentID: id, namespace: .local),
                               uploadDelay: 0, sleeper: fastSleeper)
            _ = await e.open(pdfPageCount: 1)
            await e.updatePage("p1", page(["s"]))
            await e.shutdown()
        }
        store.put("{", at: "spaces/local/docs/kaputt/pages/p1.json")
        store.failList("spaces/local/docs/unlesbar/pages")
        let scan = JournalScan.scan(store: store)
        XCTAssertEqual(scan.unreadable, ["local/unlesbar"], "vorher stillschweigend uebersprungen")
        XCTAssertEqual(scan.damaged, ["local/kaputt/pages/p1.json"])
        XCTAssertEqual(scan.documentsWithUnsent, 1)
        XCTAssertEqual(scan.unsentPages, 1)
        store.failList("spaces/local/docs")
        XCTAssertEqual(JournalScan.scan(store: store).unreadable, ["local/docs"])
    }

    /// Diagnose, waehrend gerade geschrieben wird: je Datei der alte oder der neue Stand, nie eine halbe Datei
    func testDiagnosisWhileWritingNeverSeesHalfFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-diagnose-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileBlobStore(root: dir)
        let server = MockServer()
        await server.setOnline(false)
        let e = SyncEngine(documentID: "d", transport: server, journal: LocalJournal(store: store, documentID: "d", namespace: .local),
                           uploadDelay: 0, sleeper: fastSleeper)
        _ = await e.open(pdfPageCount: 4)
        let done = CrashFlag()
        let writer = Task {
            var ids: [String] = []
            for i in 0..<160 {
                ids.append("s\(i)")
                await e.updatePage("p\(i % 4 + 1)", page(Array(ids.suffix(80))))
            }
            done.set()
        }
        var scans = 0
        while !done.isSet, scans < 300 {
            let scan = JournalScan.scan(store: store)
            XCTAssertEqual(scan.damaged, [])
            XCTAssertEqual(scan.unreadable, [])
            scans += 1
            if scans % 10 == 0 { await Task.yield() }
        }
        await writer.value
        XCTAssertGreaterThan(scans, 5, "Diagnose lief waehrend des Schreibens")
        await e.shutdown()
        XCTAssertEqual(JournalScan.scan(store: store).unsentPages, 4)
    }
}

final class AuditRunde11SyncTests: XCTestCase {

    // MARK: 352 Loeschen auf A, Bearbeiten auf B

    func testDeletedOnOneDeviceEditedOnTheOtherIsKeptAndShownAsConflict() async throws {
        let server = MockServer()
        let a = makeEngine(server, MemoryBlobStore()), b = makeEngine(server, MemoryBlobStore())
        _ = await a.open(pdfPageCount: 2)
        await a.updatePage("p2", page(["x", "y"]))
        await a.syncNow()
        _ = await b.open(pdfPageCount: 2)
        await a.updatePage("p2", page(["y"]))                              // A loescht x
        await a.syncNow()
        var moved = stroke("x"); moved["x"] = 40                             // B verschiebt x
        await b.updatePage("p2", pageWith([moved, stroke("y")]))
        await b.syncNow()
        let ids = await server.objectIDs(page: "p2")
        XCTAssertEqual(Set(ids), ["x", "y"], "die Aenderung verschwindet nicht unbemerkt")
        let onServer = AnnotationDocument(root: await server.root).objects(page: "p2").first { $0["id"]?.string == "x" }
        XCTAssertEqual(onServer?["x"], 40)
        let issue = await b.issue
        XCTAssertEqual(issue, .konflikteZusammengefuehrt(1))
        let pages = await b.conflictPageKeys
        XCTAssertEqual(pages, ["p2"], "welche Seite betroffen ist")
        await b.acknowledgeMergedConflicts()
        let cleared = await b.conflictPageKeys
        XCTAssertEqual(cleared, [])
    }

    // MARK: 356 nach dem Schliessen keine Wiederholungen

    func testRetriesStopReliablyAfterClosing() async throws {
        for failure in [503, nil] as [Int?] {
            let server = MockServer(), counter = CallCounter()
            let e = SyncEngine(documentID: "doc1", transport: CountingTransport(inner: server, counter: counter),
                               journal: LocalJournal(store: MemoryBlobStore(), documentID: "doc1"), uploadDelay: 0, sleeper: fastSleeper)
            _ = await e.open(pdfPageCount: 1)
            if let failure { await server.setFailStatus(failure) } else { await server.setOnline(false) }
            await e.updatePage("p1", page(["a"]))
            await e.syncNow()
            let opened = await counter.calls
            let retried = await waitUntil(timeout: 5) { await counter.calls >= opened + 2 }
            XCTAssertTrue(retried, "wird wiederholt, solange offen")
            await e.shutdown()
            try await Task.sleep(nanoseconds: 50_000_000)                   // ein schon laufender Versuch endet
            let before = await counter.calls
            try await Task.sleep(nanoseconds: 400_000_000)                  // entspricht 40 s Wiederholungszeit
            let after = await counter.calls
            XCTAssertEqual(after, before, "keine Wiederholung nach dem Schliessen (\(failure.map(String.init) ?? "offline"))")
            await e.updatePage("p1", page(["a", "b"]))                       // spaete Umrechnung nach dem Schliessen
            try await Task.sleep(nanoseconds: 100_000_000)
            let late = await counter.calls
            XCTAssertEqual(late, before, "auch eine spaete Aenderung startet keinen Upload")
            let local = await e.page("p1")?["objects"]?.array?.count
            XCTAssertEqual(local, 2, "lokal gesichert, geht beim naechsten Oeffnen hoch")
        }
    }

    // MARK: 358 Konflikt ohne Ende

    func testEndlessConflictIsShownAndRetriedLaterWithoutANewEdit() async throws {
        let churn = ChurningServer()
        let e = SyncEngine(documentID: "doc1", transport: churn, journal: LocalJournal(store: MemoryBlobStore(), documentID: "doc1"),
                           uploadDelay: 0, sleeper: fastSleeper)
        _ = await e.open(pdfPageCount: 1)
        await e.updatePage("p1", page(["ipad"]))
        await e.syncNow()
        let status = await e.status
        guard case .conflictUnresolved(let m) = status else { return XCTFail("war \(status)") }
        XCTAssertTrue(m.contains("lokal gesichert"), m)
        await churn.setChurning(false)
        let saved = await waitUntil(timeout: 5) { await e.status == .saved }
        XCTAssertTrue(saved, "ohne neuen Strich spaeter erneut versucht")
        let ids = await churn.server.objectIDs(page: "p1")
        XCTAssertEqual(ids, ["ipad"])
        await e.shutdown()
    }

    // MARK: 359 wiederholte Konflikte

    func testRepeatedConflictsNeverDuplicateObjects() async throws {
        let server = MockServer()
        let a = makeEngine(server, MemoryBlobStore()), b = makeEngine(server, MemoryBlobStore())
        _ = await a.open(pdfPageCount: 1)
        _ = await b.open(pdfPageCount: 1)
        var aIDs: [String] = [], bIDs: [String] = []
        for round in 0..<12 {
            aIDs.append("a\(round)")
            bIDs.append("b\(round)")
            // beide schreiben auf derselben Seite, dazu wird ein gemeinsames Objekt auf beiden verschieden geaendert
            var sharedA = stroke("gemeinsam"); sharedA["color"] = .string("#a\(round % 10)0000")
            var sharedB = stroke("gemeinsam"); sharedB["color"] = .string("#00b\(round % 10)00")
            let aPage = await a.page("p1")?["objects"]?.array ?? []
            let bPage = await b.page("p1")?["objects"]?.array ?? []
            await a.updatePage("p1", pageWith(aPage.filter { $0["id"]?.string != "gemeinsam" } + [sharedA, stroke("a\(round)")]))
            await b.updatePage("p1", pageWith(bPage.filter { $0["id"]?.string != "gemeinsam" } + [sharedB, stroke("b\(round)")]))
            await a.syncNow()
            await b.syncNow()
        }
        await a.syncNow()
        let ids = await server.objectIDs(page: "p1")
        XCTAssertEqual(ids.count, Set(ids).count, "keine doppelten Objekte: \(ids)")
        XCTAssertEqual(Set(ids), Set(aIDs + bIDs + ["gemeinsam"]))
        let localA = await a.page("p1")?["objects"]?.array?.compactMap { $0["id"]?.string } ?? []
        XCTAssertEqual(localA.count, Set(localA).count)
        let conflicts = await b.stats.mergedConflicts
        XCTAssertGreaterThan(conflicts, 0)
    }
}
