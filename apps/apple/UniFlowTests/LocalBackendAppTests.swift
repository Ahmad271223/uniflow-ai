import XCTest
import UniFlowCore
@testable import UniFlow

/// Transport-Weiche: APIClient mit lokalem Backend (eigene Datenbank in einem Temp-Ordner), Sitzung im lokalen
/// Modus, Weiche der Seiten und Umzug der alten Journale.
@MainActor
final class LocalBackendAppTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func localAPI() throws -> (APIClient, LocalBackendHost) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-25T14:30:05")!)
        return (APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)), host)
    }

    // MARK: APIClient ueber das lokale Backend

    func testPublicSignaturesWorkLocally() async throws {
        let (api, host) = try localAPI()
        XCTAssertTrue(api.isLocal)
        XCTAssertEqual(api.namespace, .local)
        XCTAssertNil(api.pinValue)
        let s = try await api.value("/api/settings")
        XCTAssertEqual(s["minutes_per_day"], 240)
        let saved = try await api.value("/api/settings", method: "PUT", body: ["user_name": "Testperson", "hours_per_day": 5])
        XCTAssertEqual(saved["user_name"], "Testperson")
        XCTAssertEqual(saved["minutes_per_day"], 300)
        // json<T>: dieselbe Antwortform wie vom Server
        let lib = try await api.json("/api/library", as: LibraryResponse.self)
        XCTAssertTrue(lib.files.isEmpty && lib.modules.isEmpty)
        // Query und Datum aus der Uhr
        let cal = try await api.value("/api/calendar?start=2026-10-26&end=2026-10-27")
        XCTAssertEqual(cal["days"]?.array?.count, 2)
        let (d, http) = try await api.data("/api/terms")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.url?.absoluteString, "uniflow-local://device/api/terms")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try JSONValue.parse(d)["name"], "WiSe 2026/27")
        // Datenbank liegt im Ordner des Hosts, im Backup, mit Dateischutz (sofern das System ihn meldet)
        XCTAssertTrue(FileManager.default.fileExists(atPath: host.databaseURL.path))
        XCTAssertEqual(host.databaseURL.lastPathComponent, "uniflow.sqlite")
        let excluded = try host.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, false)
        if let p = try FileManager.default.attributesOfItem(atPath: host.directory.path)[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(p, .completeUntilFirstUserAuthentication)
        }
    }

    func testErrorsAreUnderstandableLikeFastAPI() async throws {
        let (api, _) = try localAPI()
        do {
            _ = try await api.value("/api/files/f1/content")
            XCTFail("404 erwartet")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 404)
            XCTAssertEqual(e.errorDescription, "Datei nicht lokal vorhanden")
        }
        do {
            _ = try await api.value("/api/packages", method: "POST", body: ["date": "2026-10-26"])
            XCTFail("409 erwartet")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 409)
            XCTAssertEqual(e.errorDescription, "Lernpakete anlegen geht auf diesem iPad noch nicht.")
            XCTAssertEqual(e.httpDetail, e.errorDescription)
        }
        do {
            _ = try await api.value("/api/ai/tutor", method: "POST", body: [:])
            XCTFail("404 erwartet")
        } catch let e as APIError {
            XCTAssertEqual(e.errorDescription, "KI-Funktionen gibt es in dieser Version nicht.")
        }
        // Formular (multipart) geht durch den Router, Anlegen ist noch nicht moeglich
        do {
            _ = try await api.upload("/api/notebooks", fields: ["kind": "pdf", "title": "Skript"], fileField: "upload",
                                     fileName: "skript.pdf", mimeType: "application/pdf", data: Data("%PDF-1.4".utf8))
            XCTFail("409 erwartet")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 409)
            XCTAssertEqual(e.errorDescription, "Dateien importieren geht auf diesem iPad noch nicht.")
        }
        // unbekannter Pfad: 404 wie FastAPI, kein Absturz
        let (_, http) = try await api.data("/api/gibt-es-nicht")
        XCTAssertEqual(http.statusCode, 404)
    }

    /// Seiten laden mehrere Pfade gemeinsam (async let); lokal scheitert keiner davon
    func testPagesThatLoadTogetherSucceed() async throws {
        let (api, _) = try localAPI()
        async let s = api.value("/api/settings")
        async let c = api.value("/api/courses")
        async let m = api.value("/api/modules")
        async let l = api.value("/api/sync/status")
        async let cr = api.value("/api/credentials")
        async let t = api.value("/api/terms")
        async let cal = api.value("/api/calendar?start=2026-10-26&end=2026-11-01")
        async let open = api.value("/api/tasks/open")
        async let tw = api.value("/api/timetable/week?start=2026-10-26")
        let all = try await [s, c, m, l, cr, t, cal, open, tw]
        XCTAssertEqual(all.count, 9)
        let dash = RemoteData(path: "/api/dashboard", api: api)
        await dash.load()
        XCTAssertEqual(dash.value?["today"]?["date"], "2026-10-25")
    }

    func testAnnotationsStayLocalUntilS3() async throws {
        let (api, _) = try localAPI()
        let transport = HTTPAnnotationTransport(api: api)
        let snap = try await transport.fetch(documentID: "f1")
        XCTAssertEqual(snap.version, 0)
        do {
            _ = try await transport.put(documentID: "f1", root: AnnotationDocument.emptyRoot, baseVersion: 0)
            XCTFail("kein Speichern lokal vor S3")
        } catch {
            // kein Konflikt (der wuerde endlos zusammengefuehrt), sondern "noch nicht moeglich" mit Meldung
            guard case .nichtVerfuegbar(let m) = SyncIssue.classify(error) else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("bleiben lokal gesichert"), m)
        }
    }

    // MARK: Sitzung

    func testSessionStartsLocalWithAPI() throws {
        let suite = "uniflow-tests-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let (api, _) = try localAPI()
        let session = Session(local: api, defaults: d)
        XCTAssertEqual(session.mode, .local)
        XCTAssertTrue(session.api === api, "im lokalen Modus immer gesetzt")
        XCTAssertFalse(session.isOwnServer)
        // ausdruecklich lokal gewaehlt: auch mit gespeicherter Adresse lokal
        d.set("http://10.0.0.2:8765", forKey: Session.urlKey)
        d.set(BackendMode.local.rawValue, forKey: Session.modeKey)
        XCTAssertEqual(Session(local: api, defaults: d).mode, .local)
        XCTAssertTrue(Session.ownServerAvailable, "Tests laufen im Debug-Build")
    }

    func testDisconnectReturnsToLocal() throws {
        let suite = "uniflow-tests-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let (api, _) = try localAPI()
        let session = Session(local: api, defaults: d)
        session.disconnect()
        XCTAssertEqual(session.mode, .local)
        XCTAssertTrue(session.api === api)
        XCTAssertEqual(d.string(forKey: Session.modeKey), "local")
    }

    // MARK: Weiche der Seiten

    func testDataModeLocal() throws {
        let (api, _) = try localAPI()
        let server = APIClient(base: URL(string: "http://127.0.0.1:8765")!, pin: nil)
        XCTAssertEqual(UFDataMode.resolve(api: api, studIP: .notConnected), .local(.notConnected))
        XCTAssertEqual(UFDataMode.resolve(api: server, studIP: .notConnected), .server)
        XCTAssertEqual(UFDataMode.resolve(api: nil, studIP: .notConnected), .connectStudIP)
        XCTAssertTrue(UFDataMode.local(.notConnected).showsConnectCard)
        XCTAssertTrue(UFDataMode.local(.expired).showsConnectCard)
        XCTAssertTrue(UFDataMode.local(.expired).studIPExpired)
        XCTAssertFalse(UFDataMode.local(.connected).showsConnectCard, "nach der Anmeldung weg")
        XCTAssertTrue(UFDataMode.local(.connected).loadsPages)
        XCTAssertTrue(UFDataMode.local(.connected).isOnDevice)
        XCTAssertFalse(UFDataMode.server.isOnDevice)
    }

    func testGateShowsRealPageWithConnectCardAbove() {
        typealias G = UFGatePresentation
        // lokal: echte Seite, Karte oberhalb solange Stud.IP fehlt
        XCTAssertEqual(G.resolve(spec: .plan, mode: .local(.notConnected)), .pageBelowConnectCard)
        XCTAssertEqual(G.resolve(spec: .library, mode: .local(.expired)), .pageBelowConnectCard)
        XCTAssertEqual(G.resolve(spec: .modules, mode: .local(.connected)), .page)
        // KI-Wochentests und QIS-Noten gibt es in V1 nicht: lokal der ehrliche leere Zustand
        XCTAssertEqual(G.resolve(spec: .exams, mode: .local(.connected)), .empty)
        XCTAssertEqual(G.resolve(spec: .services, mode: .local(.notConnected)), .empty)
        // eigener Server wie bisher, ohne Datenquelle der leere Zustand
        XCTAssertEqual(G.resolve(spec: .exams, mode: .server), .page)
        XCTAssertEqual(G.resolve(spec: .plan, mode: .connectStudIP), .empty)
    }

    // MARK: Umzug der alten Journale

    func testLegacyDataMovesToServerNamespace() throws {
        let support = try tempDir()
        let fm = FileManager.default
        let journal = support.appendingPathComponent("journal", isDirectory: true)
        let old = LocalJournal(store: FileBlobStore(root: journal), documentID: "f1")
        try old.writePage("p1", JournalPage(page: ["objects": []], localRev: 4))
        try old.writeAcks(serverVersion: 7, acked: ["p1": 3], metaAckedRev: 0)
        try fm.createDirectory(at: support.appendingPathComponent("pdf"), withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: support.appendingPathComponent("pdf/f1.pdf"))

        let result = try XCTUnwrap(DataSourceMigration.run(support: support, savedServerURL: "http://10.0.0.2:8765"))
        XCTAssertEqual(result.journal.moved, ["f1"])
        XCTAssertEqual(result.pdf.moved, ["f1.pdf"])
        let owner = DataSourceNamespace(base: URL(string: "http://10.0.0.2:8765")!)
        let moved = try XCTUnwrap(try LocalJournal(store: FileBlobStore(root: journal), documentID: "f1", namespace: owner).load())
        XCTAssertEqual(moved.serverVersion, 7)
        XCTAssertEqual(moved.pages["p1"]?.localRev, 4, "ungesendete Seite bleibt ungesendet")
        XCTAssertEqual(try Data(contentsOf: AppPaths.pdfDirectory(owner, root: support).appendingPathComponent("f1.pdf")), Data("%PDF".utf8))
        XCTAssertNil(try LocalJournal(store: FileBlobStore(root: journal), documentID: "f1", namespace: .local).load())
        // zweiter Start: nichts mehr zu tun
        let again = try XCTUnwrap(DataSourceMigration.run(support: support, savedServerURL: "http://10.0.0.2:8765"))
        XCTAssertEqual(again.journal.moved, [])
        XCTAssertEqual(again.pdf.moved, [])
    }

    func testLegacyOwner() {
        XCTAssertEqual(DataSourceMigration.legacyOwner(savedServerURL: "http://192.168.0.10:8765").id, "server-192.168.0.10-8765")
        XCTAssertEqual(DataSourceMigration.legacyOwner(savedServerURL: nil).id, "server")
        XCTAssertEqual(DataSourceMigration.legacyOwner(savedServerURL: "kaputt").id, "server")
    }

    func testPDFCacheSeparatedBySource() {
        let server = DataSourceNamespace(base: URL(string: "http://10.0.0.2:8765")!)
        XCTAssertNotEqual(AppPaths.pdf("f1", namespace: .local), AppPaths.pdf("f1", namespace: server))
        XCTAssertTrue(AppPaths.pdf("f1", namespace: .local).path.hasSuffix("sources/local/pdf/f1.pdf"))
    }
}
