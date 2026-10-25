import Foundation
import XCTest
@testable import UniFlowCore

/// Namensraum je Datenquelle und der einmalige Umzug der alten Journale.
final class JournalNamespaceTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-ns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testNamespaceFromBaseURL() {
        XCTAssertEqual(DataSourceNamespace(base: URL(string: "uniflow-local://device/")!), .local)
        XCTAssertEqual(DataSourceNamespace(base: URL(string: "http://192.168.0.10:8765")!).id, "server-192.168.0.10-8765")
        XCTAssertEqual(DataSourceNamespace(base: URL(string: "http://Mein-PC.fritz.box:8765/")!).id, "server-mein-pc.fritz.box-8765")
        XCTAssertEqual(DataSourceNamespace(base: URL(string: "http://[fe80::1]:8765")!).id, "server-fe80__1-8765", "nur sichere Zeichen")
        XCTAssertEqual(DataSourceNamespace.server(host: nil, port: nil).id, "server")
        XCTAssertNotEqual(DataSourceNamespace(base: URL(string: "http://10.0.0.2:8765")!), DataSourceNamespace(base: URL(string: "http://10.0.0.3:8765")!))
    }

    func testJournalsOfDifferentSourcesStaySeparate() throws {
        let store = MemoryBlobStore()
        let server = DataSourceNamespace(base: URL(string: "http://10.0.0.2:8765")!)
        let a = LocalJournal(store: store, documentID: "f1", namespace: .local)
        let b = LocalJournal(store: store, documentID: "f1", namespace: server)
        try a.writePage("p1", JournalPage(page: page(["lokal"]), localRev: 1))
        try b.writePage("p1", JournalPage(page: page(["server"]), localRev: 3))
        try b.writeBase("p1", page(["basis"]))
        XCTAssertEqual(try a.load()?.pages["p1"]?.page, page(["lokal"]))
        XCTAssertNil(try a.load()?.bases["p1"], "Basisversion des Servers gilt nicht fuer lokal")
        XCTAssertEqual(try b.load()?.pages["p1"]?.localRev, 3)
        XCTAssertTrue(store.paths.allSatisfy { $0.hasPrefix("spaces/local/docs/f1/") || $0.hasPrefix("spaces/server-10.0.0.2-8765/docs/f1/") }, "\(store.paths)")
        XCTAssertEqual(LocalJournal.documentsDirectory(.local), "spaces/local/docs")
        XCTAssertEqual(LocalJournal.documentsDirectory(nil), "docs")
    }

    func testDocumentIDFromDirectoryName() {
        XCTAssertEqual(LocalJournal.documentID(forDirectory: LocalJournal.safeName("f1")), "f1")
        XCTAssertEqual(LocalJournal.documentID(forDirectory: LocalJournal.safeName("a/b c")), "a/b c")
    }

    /// Alte Journale (vor S2) gehoeren zum Server und ziehen ohne Verlust um, auch ungesendete Seiten.
    func testLegacyJournalsMoveToServerNamespaceWithoutLoss() async throws {
        let root = try tempDir()
        let store = FileBlobStore(root: root)
        let server = MockServer()
        // alter Stand: ein Dokument mit ungesendeter Seite und Basis, eines vollstaendig gesendet
        let old = SyncEngine(documentID: "f1", transport: server, journal: LocalJournal(store: store, documentID: "f1"), uploadDelay: 0, sleeper: fastSleeper)
        _ = await old.open(pdfPageCount: 2)
        await old.updatePage("p1", page(["a"]))
        await old.syncNow()
        await server.setOnline(false)
        await old.updatePage("p1", page(["a", "b"]))
        await old.updatePage("p2", page(["c"]))
        await old.shutdown()
        try LocalJournal(store: store, documentID: "x/2").writePage("p1", JournalPage(page: page(["z"]), localRev: 1))
        let before = try XCTUnwrap(try LocalJournal(store: store, documentID: "f1").load())
        XCTAssertEqual(before.pages.filter { $0.value.localRev > (before.acked[$0.key] ?? 0) }.count, 2)

        let owner = DataSourceNamespace(base: URL(string: "http://10.0.0.2:8765")!)
        let report = try JournalNamespaceMigration.run(root: root, owner: owner)
        XCTAssertEqual(Set(report.moved), [LocalJournal.safeName("f1"), LocalJournal.safeName("x/2")])
        XCTAssertEqual(report.kept, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("docs").path), "alter Ordner leer und entfernt")
        XCTAssertNil(try LocalJournal(store: store, documentID: "f1").load())

        // am neuen Ort: alles identisch, ungesendete Seiten bleiben ungesendet
        let after = try XCTUnwrap(try LocalJournal(store: store, documentID: "f1", namespace: owner).load())
        XCTAssertEqual(after, before)
        XCTAssertEqual(try LocalJournal(store: store, documentID: "x/2", namespace: owner).load()?.pages["p1"]?.page, page(["z"]))
        XCTAssertNil(try LocalJournal(store: store, documentID: "f1", namespace: .local).load(), "lokal faengt leer an")

        // der Server bekommt die Aenderungen nach dem Umzug wie vorher
        await server.setOnline(true)
        let reopened = SyncEngine(documentID: "f1", transport: server, journal: LocalJournal(store: store, documentID: "f1", namespace: owner),
                                  uploadDelay: 0, sleeper: fastSleeper)
        let opened = await reopened.open(pdfPageCount: 2)
        XCTAssertEqual(opened.restoredUnsentPages, 2)
        await reopened.syncNow()
        let p1 = await server.objectIDs(page: "p1")
        let p2 = await server.objectIDs(page: "p2")
        XCTAssertEqual(p1, ["a", "b"])
        XCTAssertEqual(p2, ["c"])

        // zweiter Lauf: nichts zu tun
        XCTAssertEqual(try JournalNamespaceMigration.run(root: root, owner: owner), JournalNamespaceMigration.Report())
    }

    func testExistingTargetIsNeverOverwritten() throws {
        let root = try tempDir()
        let store = FileBlobStore(root: root)
        let owner = DataSourceNamespace.server(host: "pc", port: 8765)
        try LocalJournal(store: store, documentID: "f1").writePage("p1", JournalPage(page: page(["alt"]), localRev: 2))
        try LocalJournal(store: store, documentID: "f2").writePage("p1", JournalPage(page: page(["zwei"]), localRev: 1))
        try LocalJournal(store: store, documentID: "f1", namespace: owner).writePage("p1", JournalPage(page: page(["neu"]), localRev: 1))
        let report = try JournalNamespaceMigration.run(root: root, owner: owner)
        XCTAssertEqual(report.moved, ["f2"])
        XCTAssertEqual(report.kept, ["f1"])
        XCTAssertEqual(try LocalJournal(store: store, documentID: "f1").load()?.pages["p1"]?.page, page(["alt"]), "alter Stand bleibt liegen")
        XCTAssertEqual(try LocalJournal(store: store, documentID: "f1", namespace: owner).load()?.pages["p1"]?.page, page(["neu"]))
        XCTAssertEqual(try LocalJournal(store: store, documentID: "f2", namespace: owner).load()?.pages["p1"]?.page, page(["zwei"]))
    }

    func testMoveEntriesWithoutSourceDoesNothing() throws {
        let root = try tempDir()
        XCTAssertEqual(try JournalNamespaceMigration.moveEntries(from: root.appendingPathComponent("gibt-es-nicht"), to: root.appendingPathComponent("ziel")),
                       JournalNamespaceMigration.Report())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ziel").path))
    }
}

/// Lokales Backend als Notiz-Transport (wie HTTPAnnotationTransport der App): solange es nicht speichern kann,
/// bleibt alles im Journal, ohne endlose Wiederholung.
final class LocalAnnotationPlaceholderTests: XCTestCase {

    private struct DetailError: HTTPStatusError {
        let httpStatus: Int
        let httpDetail: String?
    }

    /// Zuordnung wie HTTPAnnotationTransport: 409 mit `version` ist ein Konflikt, ohne ist es ein Fehler
    private struct BackendTransport: AnnotationTransport {
        let backend: LocalBackend
        let gets = Counter(), puts = Counter()

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }

        func fetch(documentID: String) async throws -> ServerSnapshot {
            gets.bump()
            let r = await backend.handle(LocalRequest(method: "GET", path: "/api/files/\(documentID)/annotations"))
            guard r.isSuccess, let v = r.json else { throw DetailError(httpStatus: r.status, httpDetail: r.json?["detail"]?.string) }
            return ServerSnapshot(version: v["version"]?.int ?? 0, root: v["data"] ?? AnnotationDocument.emptyRoot)
        }

        func put(documentID: String, root: JSONValue, baseVersion: Int) async throws -> PutOutcome {
            puts.bump()
            let r = await backend.handle(LocalRequest(method: "PUT", path: "/api/files/\(documentID)/annotations",
                                                      query: [.init("base_version", "\(baseVersion)")], body: root.serialized()))
            if r.status == 409, let v = r.json, v["version"] != nil {
                return .conflict(ServerSnapshot(version: v["version"]?.int ?? 0, root: v["data"] ?? AnnotationDocument.emptyRoot))
            }
            guard r.isSuccess else { throw DetailError(httpStatus: r.status, httpDetail: r.json?["detail"]?.string) }
            return .saved(version: r.json?["version"]?.int ?? baseVersion + 1)
        }
    }

    func testNotesStayInJournalWhileLocalSavingIsNotAvailable() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory)
        let transport = BackendTransport(backend: backend)
        let store = MemoryBlobStore()
        let engine = SyncEngine(documentID: "f1", transport: transport, journal: LocalJournal(store: store, documentID: "f1", namespace: .local),
                                uploadDelay: 0, sleeper: fastSleeper)
        let opened = await engine.open(pdfPageCount: 2)
        XCTAssertTrue(opened.serverReachable, "leeres gueltiges Dokument")
        await engine.updatePage("p1", page(["a"]))
        await engine.syncNow()
        let issue = await engine.issue
        guard case .nichtVerfuegbar(let message)? = issue else { return XCTFail("\(String(describing: issue))") }
        XCTAssertTrue(message.contains("noch nicht gespeichert"), message)
        XCTAssertTrue(issue?.needsUserAction == true)
        let status = await engine.status
        XCTAssertEqual(status, .pending(pages: 1))
        XCTAssertTrue(status.isSafeLocally)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.puts.value, 1, "keine endlose Wiederholung")
        await engine.updatePage("p1", page(["a", "b"]))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.puts.value, 1)
        await engine.shutdown()
        // nichts verloren: das Journal hat alles, beim naechsten Oeffnen wiederhergestellt
        let snap = try XCTUnwrap(try LocalJournal(store: store, documentID: "f1", namespace: .local).load())
        XCTAssertEqual(snap.pages["p1"]?.page, page(["a", "b"]))
        let again = SyncEngine(documentID: "f1", transport: transport, journal: LocalJournal(store: store, documentID: "f1", namespace: .local),
                               uploadDelay: 0, sleeper: fastSleeper)
        let reopened = await again.open(pdfPageCount: 2)
        XCTAssertEqual(reopened.restoredUnsentPages, 1)
        XCTAssertEqual(reopened.document.page("p1"), page(["a", "b"]))
        await again.shutdown()
    }

    func testClassification() {
        XCTAssertEqual(SyncIssue.classify(DetailError(httpStatus: 409, httpDetail: "geht noch nicht")), .nichtVerfuegbar("geht noch nicht"))
        XCTAssertEqual(SyncIssue.classify(TestHTTPError(httpStatus: 409)), .nichtVerfuegbar("Speichern ist hier noch nicht möglich"))
        XCTAssertEqual(SyncIssue.nichtVerfuegbar("x").label, "x")
    }
}
