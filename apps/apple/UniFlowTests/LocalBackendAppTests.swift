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
        let container = try tempDir()
        let host = LocalBackendHost(directory: container.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-25T14:30:05")!,
                                    files: LocalFiles(container: container, dataDirectory: "Library/Application Support/UniFlow",
                                                      tools: AppDocumentTools()))
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
            // unbekannte Datei (leere Datenbank): eigene Meldung wie file_content seit b718cfb
            XCTAssertEqual(e.errorDescription, "Datei nicht gefunden")
        }
        // seit S6 legt das iPad Lernpakete selbst an; was es nicht gibt (Wochentests mit KI), meldet es klar
        do {
            _ = try await api.value("/api/tasks/1/start-test", method: "POST")
            XCTFail("404 erwartet")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 404)
            XCTAssertEqual(e.errorDescription, "Wochentests gibt es in dieser Version nicht.")
            XCTAssertEqual(e.httpDetail, e.errorDescription)
        }
        do {
            _ = try await api.value("/api/packages", method: "POST", body: ["date": "morgen"])
            XCTFail("422 erwartet")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 422)
            XCTAssertEqual(e.errorDescription, "Ungültiges Datum in date: morgen")
        }
        do {
            _ = try await api.value("/api/ai/tutor", method: "POST", body: [:])
            XCTFail("404 erwartet")
        } catch let e as APIError {
            XCTAssertEqual(e.errorDescription, "KI-Funktionen gibt es in dieser Version nicht.")
        }
        // Formular (multipart) geht durch den Router: keine PDF -> 400 mit Meldung wie app/server.py
        do {
            _ = try await api.upload("/api/notebooks", fields: ["kind": "pdf", "title": "Skript"], fileField: "upload",
                                     fileName: "skript.pdf", mimeType: "application/pdf", data: Data("kein PDF".utf8))
            XCTFail("400 erwartet")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 400)
            XCTAssertEqual(e.errorDescription, "Die Datei ist keine PDF")
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

    /// S3: Notizen werden im lokalen Backend gespeichert (mit Versionen und Konflikt wie am PC)
    func testAnnotationsSaveLocally() async throws {
        let (api, _) = try localAPI()
        // eigenes Dokument (PDF-Import) und Notizen dazu
        let created = try await api.upload("/api/notebooks", fields: ["kind": "pdf", "title": "Skript"], fileField: "upload",
                                           fileName: "skript.pdf", mimeType: "application/pdf", data: Data("%PDF-1.4 Test".utf8))
        let id = try XCTUnwrap(created["id"]?.string)
        XCTAssertEqual(created["local_path"]?.string, "Library/Application Support/UniFlow/files/Eigene Dokumente/\(id).pdf",
                       "relativ zum App-Container")
        let transport = HTTPAnnotationTransport(api: api)
        let snap = try await transport.fetch(documentID: id)
        XCTAssertEqual(snap.version, 0)
        let root: JSONValue = ["version": 2, "pages": ["p1": ["objects": [["id": "s1", "type": "stroke"]]]]]
        let saved = try await transport.put(documentID: id, root: root, baseVersion: 0)
        XCTAssertEqual(saved, .saved(version: 1))
        let stale = try await transport.put(documentID: id, root: AnnotationDocument.emptyRoot, baseVersion: 0)
        guard case .conflict(let current) = stale else { return XCTFail("\(stale)") }
        XCTAssertEqual(current.version, 1)
        XCTAssertEqual(current.root["pages"]?["p1"]?["objects"]?.array?.count, 1)
        let (pdf, http) = try await api.data("/api/files/\(id)/content")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(pdf, Data("%PDF-1.4 Test".utf8))
        // Dokument fehlt in der Datenbank: kein Konflikt (der wuerde endlos zusammengefuehrt), sondern Meldung
        do {
            _ = try await transport.put(documentID: "fremd", root: AnnotationDocument.emptyRoot, baseVersion: 0)
            XCTFail("unbekanntes Dokument")
        } catch {
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
        XCTAssertTrue(UFDataMode.local(.notConnected).showsConnectCard)
        XCTAssertTrue(UFDataMode.local(.expired).showsConnectCard)
        XCTAssertTrue(UFDataMode.local(.expired).studIPExpired)
        XCTAssertFalse(UFDataMode.local(.connected).showsConnectCard, "nach der Anmeldung weg")
        XCTAssertTrue(UFDataMode.local(.connected).isOnDevice)
        XCTAssertFalse(UFDataMode.server.isOnDevice)
    }

    private func gate(_ spec: UFNoServerPage.Spec, _ mode: UFDataMode, _ phase: StudIPSync.Phase = .idle) -> UFGatePresentation {
        UFGatePresentation.resolve(spec: spec, mode: mode, phase: phase)
    }

    func testGateShowsRealPageWithConnectCardAbove() {
        // lokal: echte Seite, Karte oberhalb solange Stud.IP fehlt (auch mit Dateien eines frueheren Abgleichs)
        XCTAssertEqual(gate(.plan, .local(.notConnected), .signedOut), .pageBelowConnectCard)
        XCTAssertEqual(gate(.library, .local(.expired), .needsLogin), .pageBelowConnectCard)
        XCTAssertEqual(gate(.modules, .local(.connected)), .page)
        // im Editor keine Karte und keine Statusleiste oberhalb, die Seite bekommt die ganze Hoehe
        XCTAssertEqual(gate(.document, .local(.notConnected), .signedOut), .page)
        XCTAssertEqual(gate(.document, .local(.connected), .running("Lade 1 von 3")), .page)
        // KI-Wochentests gibt es in V1 nicht: lokal der ehrliche leere Zustand
        XCTAssertEqual(gate(.exams, .local(.connected)), .empty)
        // Uni & Noten an der LUH: Notenspiegel aus dem QIS auf dem Geraet, die echte Seite (Karte oberhalb, solange
        // Stud.IP fehlt)
        XCTAssertEqual(gate(.services, .local(.notConnected)), .pageBelowConnectCard)
        XCTAssertEqual(gate(.services, .local(.connected)), .page)
        // eigener Server wie bisher
        XCTAssertEqual(gate(.exams, .server, .running("x")), .page)
        // Uni & Noten an der Uni Hildesheim: Notenspiegel aus dem LSF, die echte Seite
        XCTAssertEqual(gate(.services, .local(.otherSources)), .pageBelowConnectCard)
    }

    /// Lokal zeigen die Seiten die abgeglichenen Dateien seit S3 selbst: oberhalb der Seite stehen nur noch
    /// Abgleichstand und Fehler
    func testGateShowsStudIPStatusWhileConnectedLocally() {
        let connected = UFDataMode.local(.connected)
        XCTAssertEqual(gate(.library, connected, .running("Dateien werden geladen …")), .pageBelowStudIPStatus)
        XCTAssertEqual(gate(.plan, connected, .failed("offline")), .pageBelowStudIPStatus)
        XCTAssertEqual(gate(.modules, connected, .idle), .page, "Dateien stehen in der Seite")
        XCTAssertEqual(gate(.timetable, connected, .idle), .page, "nichts abgeglichen, kein Fehler: keine Leiste")

        let running = UFNoServerContent.resolve(kind: .library, mode: connected, phase: .running("Kurse werden geladen …"))
        XCTAssertEqual(running.status, .syncing("Kurse werden geladen …"))
        XCTAssertTrue(running.showsStatusBar)
        let failed = UFNoServerContent.resolve(kind: .dashboard, mode: connected, phase: .failed("offline"))
        XCTAssertEqual(failed.status, .failed("offline"))
        XCTAssertFalse(failed.showsConnectCard)
        XCTAssertFalse(UFNoServerContent.resolve(kind: .modules, mode: connected, phase: .idle).showsStatusBar)
        // nicht verbunden bzw. eigener Server: keine Leiste
        XCTAssertFalse(UFNoServerContent.resolve(kind: .library, mode: .local(.notConnected), phase: .failed("x")).showsStatusBar)
        XCTAssertFalse(UFNoServerContent.resolve(kind: .dashboard, mode: .server, phase: .running("x")).showsStatusBar)
        // Wochentests/Noten zeigen lokal den leeren Zustand, jetzt ebenfalls mit Abgleichstand
        XCTAssertEqual(UFNoServerContent.resolve(kind: .exams, mode: connected, phase: .failed("offline")).status, .failed("offline"))
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
        XCTAssertEqual(try Data(contentsOf: AppPaths.pdf("f1", namespace: owner, root: support)), Data("%PDF".utf8))
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
