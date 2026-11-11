import SwiftUI
import XCTest
import UniFlowCore
@testable import UniFlow

/// Befund vom iPad (07.11.2026): eine Studiengruppe lud alle Dateien, die normalen Veranstaltungen standen mit
/// Download-Adresse in `files`, wurden aber nie geladen, auch nicht beim zweiten Abgleich. Ursache: der Abgleich liess
/// jede Datei mit "is-downloadable": false still weg; an der LUH melden normale Veranstaltungen ihre Dateien so, der
/// Inhalt kommt trotzdem ueber `file-refs/{id}/content` (wie am PC). Nachbau mit erfundenen Daten (example.org, keine
/// Anfrage an eine Hochschule): eine Studiengruppe (Dateien mit Flag true) und zwei Veranstaltungen (Flag false), davon
/// eine Datei, die Stud.IP wirklich verweigert (403).
@MainActor
final class StudIPDownloadGapAppTests: XCTestCase {
    private static let clock = UniFlowClock.fixed(berlin: "2026-11-07T21:59:00")!

    private struct Device {
        let host: LocalBackendHost
        let studipRoot: URL
    }

    private func device() throws -> Device {
        let c = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-gap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: c) }
        let host = LocalBackendHost(directory: c.appendingPathComponent("Library/Application Support/UniFlow/db", isDirectory: true),
                                    clock: Self.clock,
                                    files: LocalFiles(container: c, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        return Device(host: host, studipRoot: c.appendingPathComponent("Library/Application Support/StudIP", isDirectory: true))
    }

    private func defaults() throws -> UserDefaults {
        let suite = "uniflow-gap-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// Stud.IP mit festen Antworten (Pfad -> Antwort), zaehlt Abrufe
    final class Portal: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: HTTPReply] = [:]
        private var log: [String] = []
        var requested: [String] { lock.lock(); defer { lock.unlock() }; return log }
        func clear() { lock.lock(); log.removeAll(); lock.unlock() }
        func set(_ path: String, _ reply: HTTPReply) { lock.lock(); routes[path] = reply; lock.unlock() }
        func json(_ path: String, _ text: String) { set(path, HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(text.utf8))) }
        func status(_ path: String, _ code: Int) { set(path, HTTPReply(status: code, contentType: "text/plain", body: Data())) }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let key = url.absoluteString.replacingOccurrences(of: StudIPSync.base.absoluteString, with: "")
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            lock.lock()
            log.append(key)
            let r = routes[key]
            lock.unlock()
            return r ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
        }

        func contentRequests(_ id: String) -> Int { requested.filter { $0 == "/jsonapi.php/v1/file-refs/\(id)/content" }.count }
    }

    static func pdf(_ marker: String) -> Data { Data("%PDF-1.4\n% \(marker)\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n".utf8) }

    /// Kurse: Studiengruppe "sg" (ohne Nummer, ohne Endsemester), Veranstaltungen "v1" (Folien) und "v2" (Uebung, darin
    /// eine gesperrte Datei). Dateien je Kurs: (ID, Name, is-downloadable)
    static let files: [String: [(id: String, name: String, flag: Bool)]] = [
        "sg": [("sg1", "Lerngruppe Notizen 1.pdf", true), ("sg2", "Lerngruppe Notizen 2.pdf", true), ("sg3", "Lerngruppe Notizen 3.pdf", true)],
        "v1": [("v1a", "Beispiel_Kap_1.pdf", false), ("v1b", "Beispiel_Kap_2.pdf", false)],
        "v2": [("v2a", "Uebungsblatt 1.pdf", false), ("v2x", "Gesperrt.pdf", false)],
    ]

    func portal() -> Portal {
        let t = Portal()
        t.json("/jsonapi.php/v1/users/me", #"{"data":{"id":"u1","type":"users"}}"#)
        let sem = #"{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00","end":"2027-03-31T23:59:59+02:00"}}"#
        let lecture = { (id: String, title: String, number: String) in
            #"{"id":"\#(id)","type":"courses","attributes":{"title":"\#(title)","course-number":"\#(number)"},"relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}},"end-semester":{"data":{"type":"semesters","id":"s1"}}}}"#
        }
        let group = #"{"id":"sg","type":"courses","attributes":{"title":"Lerngruppe Beispiel"},"relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}}"#
        let courses = [lecture("v1", "Grundlagen Beispiel", "10001"), group, lecture("v2", "Übung Beispiel", "10002")].joined(separator: ",")
        t.json("/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester,end-semester", #"{"data":[\#(courses)],"included":[\#(sem)]}"#)
        t.json("/jsonapi.php/v1/users/u1/schedule", #"{"data":[],"links":{}}"#)
        for (course, list) in Self.files {
            t.json("/jsonapi.php/v1/courses/\(course)/folders?page[limit]=200",
                   #"{"data":[{"id":"r\#(course)","type":"folders","attributes":{"folder-type":"RootFolder","name":""}}]}"#)
            t.json("/jsonapi.php/v1/folders/r\(course)/folders?page[limit]=200", #"{"data":[]}"#)
            let refs = list.map { f in
                let size = Self.pdf(f.id).count
                return #"{"id":"\#(f.id)","type":"file-refs","attributes":{"name":"\#(f.name)","filesize":\#(size),"mime-type":"application/pdf","chdate":"2026-10-19T10:00:00+02:00","is-downloadable":\#(f.flag)}}"#
            }.joined(separator: ",")
            t.json("/jsonapi.php/v1/folders/r\(course)/file-refs?page[limit]=500", #"{"data":[\#(refs)]}"#)
            for f in list {
                t.set("/jsonapi.php/v1/file-refs/\(f.id)/content", HTTPReply(status: 200, contentType: "application/pdf", body: Self.pdf(f.id)))
            }
        }
        t.status("/jsonapi.php/v1/file-refs/v2x/content", 403)
        return t
    }

    func client(_ t: Portal) -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0, retry: UniRetry(attempts: 1, delayNanos: { _ in 0 }))
    }

    private func loaded(_ dev: Device) async throws -> [String: Bool] {
        let db = try await dev.host.backend().context.database
        return try await db.withConnection { c in
            var out: [String: Bool] = [:]
            for r in try c.query("SELECT id, local_path FROM files WHERE course_id <> '__user__'") {
                if let id = r["id"]?.string { out[id] = !(r["local_path"]?.string ?? "").isEmpty }
            }
            return out
        }
    }

    private func failure(_ dev: Device, _ id: String) async throws -> DownloadFailures.Entry? {
        let db = try await dev.host.backend().context.database
        return try await db.withConnection { try DownloadFailures.entry($0, fileID: id) }
    }

    // MARK: Fall "Liste da, Download fehlt"

    /// Erster Abgleich: Studiengruppe und normale Veranstaltungen laden (auch mit "is-downloadable": false); die
    /// wirklich gesperrte Datei steht mit Grund als "nicht geladen" da, nicht still
    func testLecturesWithDownloadableFalseAreLoadedLikeStudyGroups() async throws {
        let dev = try device()
        let stud = portal()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        let state = try await loaded(dev)
        for id in ["sg1", "sg2", "sg3", "v1a", "v1b", "v2a"] { XCTAssertEqual(state[id], true, "\(id) nicht geladen: \(state)") }
        XCTAssertEqual(state["v2x"], false)
        let gone = try await failure(dev, "v2x")
        XCTAssertEqual(gone?.status, 403)
        XCTAssertTrue(gone?.message.contains("403") == true, gone?.message ?? "")
        let f1 = try await failure(dev, "v1a")
        XCTAssertNil(f1)
        XCTAssertTrue(sync.lastSummary?.contains("1 nicht geladen") == true, sync.lastSummary ?? "")
        // Absage: kein sofortiger neuer Lauf beim Oeffnen deswegen
        XCTAssertFalse(sync.downloadsPending)
    }

    /// Altbestand vom iPad: Dateien stehen schon in `files` (Download-Adresse, kein Ablageort), weil ein frueherer
    /// Abgleich sie uebersprang. Der naechste Abgleich holt sie nach.
    func testListedButNeverLoadedFilesAreFetchedOnNextRun() async throws {
        let dev = try device()
        let stud = portal()
        let db = try await dev.host.backend().context.database
        // so stand es auf dem iPad: Kurs und Dateien eingetragen, nichts geladen, kein Fehler vermerkt
        let rows = Self.files["v1"]!.map { f in
            StudIPFile(id: f.id, courseID: "v1", name: f.name, size: Self.pdf(f.id).count, mimeType: "application/pdf",
                       changed: "2026-10-19T10:00:00+02:00", isDownloadable: false)
        }
        try await db.transaction { c in
            try StudIPLibrary.storeCourses(c, [StudIPCourse(id: "v1", title: "Grundlagen Beispiel", number: "10001", semesterTitle: "WiSe 2026/27",
                                                            semesterStart: "2026-10-01T00:00:00+02:00", semesterEnd: "WiSe 2026/27",
                                                            semesterEndsAt: "2027-03-31T23:59:59+02:00")],
                                           startedAt: "2026-11-07T21:59:08", today: "2026-11-07")
            _ = try StudIPLibrary.storeFiles(c, rows, startedAt: "2026-11-07T21:59:08", base: StudIPSync.base, localFiles: nil)
        }
        var before = try await loaded(dev)
        XCTAssertEqual(before["v1a"], false)
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        before = try await loaded(dev)
        XCTAssertEqual(before["v1a"], true, "\(before)")
        XCTAssertEqual(before["v1b"], true, "\(before)")
    }

    /// Nachholen unabhaengig von der Dateiliste (Befund iPad 08.11.2026): Dateien stehen im Register ohne Ablageort,
    /// die Liste dieses Laufs nennt sie aber nicht (mehr). Der volle Lauf laedt sie trotzdem.
    func testFullRunCatchesUpFilesMissingFromListing() async throws {
        let dev = try device()
        let stud = portal()
        let db = try await dev.host.backend().context.database
        let rows = Self.files["v1"]!.map { f in
            StudIPFile(id: f.id, courseID: "v1", name: f.name, size: Self.pdf(f.id).count, mimeType: "application/pdf",
                       changed: "2026-10-19T10:00:00+02:00", isDownloadable: false)
        }
        try await db.transaction { c in
            try StudIPLibrary.storeCourses(c, [StudIPCourse(id: "v1", title: "Grundlagen Beispiel", number: "10001", semesterTitle: "WiSe 2026/27",
                                                            semesterStart: "2026-10-01T00:00:00+02:00", semesterEnd: "WiSe 2026/27",
                                                            semesterEndsAt: "2027-03-31T23:59:59+02:00")],
                                           startedAt: "2026-11-07T21:59:08", today: "2026-11-07")
            _ = try StudIPLibrary.storeFiles(c, rows, startedAt: "2026-11-07T21:59:08", base: StudIPSync.base, localFiles: nil)
        }
        // die Liste des Kurses ist in diesem Lauf leer (Stud.IP zeigt die Dateien gerade nicht in der Ordnerliste)
        stud.json("/jsonapi.php/v1/folders/rv1/file-refs?page[limit]=500", #"{"data":[]}"#)
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        let after = try await loaded(dev)
        XCTAssertEqual(after["v1a"], true, "\(after)")
        XCTAssertEqual(after["v1b"], true, "\(after)")
        XCTAssertEqual(stud.contentRequests("v1a"), 1)
        // ein zweiter Lauf laedt nichts doppelt
        await sync.run(client: client(stud))
        XCTAssertEqual(stud.contentRequests("v1a"), 1)
    }

    /// Stufe d (nur fruehere Semester) zaehlt nicht als "letzter Abgleich": sonst war der volle Lauf beim Oeffnen nie
    /// faellig (30-Minuten-Regel), solange die alten Semester im Hintergrund nachluden (Befund iPad 08.11.2026)
    func testOlderOnlyRunDoesNotCountAsLastRun() async throws {
        let dev = try device()
        let stud = portal()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        let full = try XCTUnwrap(sync.lastRun)
        let fullSummary = sync.lastSummary
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = await sync.run(client: client(stud), scope: .full, olderOnly: true)
        XCTAssertEqual(sync.lastRun, full, "Stufe d aendert den letzten Abgleich nicht")
        XCTAssertEqual(sync.lastSummary, fullSummary)
        XCTAssertFalse(sync.runningOlderOnly)
    }

    // MARK: Fall "zweiter Abgleich holt nach"

    /// Erster Lauf: Stud.IP gestoert fuer die Veranstaltung (500). Die Dateien bleiben gelistet, der Fehler steht je
    /// Datei da, der Abgleich beim naechsten Oeffnen kommt sofort; der zweite Lauf laedt sie und loescht den Fehler.
    func testSecondRunCatchesUpAfterTransientFailure() async throws {
        let dev = try device()
        let stud = portal()
        stud.status("/jsonapi.php/v1/file-refs/v1a/content", 500)
        stud.status("/jsonapi.php/v1/file-refs/v1b/content", 500)
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        var state = try await loaded(dev)
        XCTAssertEqual(state["v1a"], false)
        let first = try await failure(dev, "v1a")
        XCTAssertEqual(first?.status, 500)
        XCTAssertEqual(first?.attempts, 1)
        XCTAssertTrue(sync.downloadsPending, "voruebergehender Fehler: beim naechsten Oeffnen sofort erneut")
        // Stud.IP wieder da
        for f in Self.files["v1"]! {
            stud.set("/jsonapi.php/v1/file-refs/\(f.id)/content", HTTPReply(status: 200, contentType: "application/pdf", body: Self.pdf(f.id)))
        }
        stud.clear()
        await sync.run(client: client(stud))
        state = try await loaded(dev)
        XCTAssertEqual(state["v1a"], true, "\(state)")
        XCTAssertEqual(state["v1b"], true, "\(state)")
        let f2 = try await failure(dev, "v1a")
        XCTAssertNil(f2)
        XCTAssertEqual(stud.contentRequests("sg1"), 0, "schon geladene Dateien nicht erneut")
        XCTAssertFalse(sync.downloadsPending)
    }

    /// 403: der automatische Abgleich fragt die Datei erst nach einer Wartezeit wieder, "Jetzt laden" sofort
    func testRefusedFileRestsInAutomaticRunsButLoadsOnRequest() async throws {
        let dev = try device()
        let stud = portal()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud))
        XCTAssertEqual(stud.contentRequests("v2x"), 1)
        stud.clear()
        await sync.run(client: client(stud))
        XCTAssertEqual(stud.contentRequests("v2x"), 0, "Absage: nicht in jedem Lauf erneut fragen")
        XCTAssertTrue(sync.lastSummary?.contains("von Stud.IP nicht freigegeben") == true, sync.lastSummary ?? "")
        // Lehrende geben die Datei frei: "Jetzt laden" holt sie sofort
        stud.set("/jsonapi.php/v1/file-refs/v2x/content", HTTPReply(status: 200, contentType: "application/pdf", body: Self.pdf("v2x")))
        let outcome = await sync.loadFile(id: "v2x", client: client(stud))
        XCTAssertEqual(outcome, .loaded)
        let state = try await loaded(dev)
        XCTAssertEqual(state["v2x"], true)
        let f3 = try await failure(dev, "v2x")
        XCTAssertNil(f3)
    }

    // MARK: Einzelne Datei ("Jetzt laden")

    func testLoadFileReportsFailureNeedsLoginAndSuccess() async throws {
        let dev = try device()
        let stud = portal()
        stud.status("/jsonapi.php/v1/file-refs/v1a/content", 500)
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        await sync.run(client: client(stud), scope: .lists)                 // nur Listen: nichts geladen
        var state = try await loaded(dev)
        XCTAssertEqual(state["v1a"], false)
        // Stud.IP gestoert: verstaendliche Meldung, Fehler je Datei
        let failed = await sync.loadFile(id: "v1a", client: client(stud))
        guard case .failed(let message) = failed else { return XCTFail("\(failed)") }
        XCTAssertTrue(message.contains("500"), message)
        let f4 = try await failure(dev, "v1a")
        XCTAssertEqual(f4?.message, message)
        let shown = await sync.downloadFailure(id: "v1a")
        XCTAssertEqual(shown?.message, message)
        // Anmeldung abgelaufen (401)
        stud.status("/jsonapi.php/v1/file-refs/v1a/content", 401)
        let login = await sync.loadFile(id: "v1a", client: client(stud))
        XCTAssertEqual(login, .needsLogin)
        // ohne gespeicherte Sitzung und ohne Client: Anmeldung noetig, keine Anfrage
        let none = await sync.loadFile(id: "v1a")
        XCTAssertEqual(none, .needsLogin)
        // wieder da
        stud.set("/jsonapi.php/v1/file-refs/v1a/content", HTTPReply(status: 200, contentType: "application/pdf", body: Self.pdf("v1a")))
        let ok = await sync.loadFile(id: "v1a", client: client(stud))
        XCTAssertEqual(ok, .loaded)
        state = try await loaded(dev)
        XCTAssertEqual(state["v1a"], true)
        let f5 = try await failure(dev, "v1a")
        XCTAssertNil(f5)
        XCTAssertTrue(sync.entries.contains { $0.id == "v1a" })
        // keine Stud.IP-Datei
        let other = await sync.loadFile(id: "gibt-es-nicht", client: client(stud))
        XCTAssertEqual(other, .notStudIP)
    }

    /// Kandidaten: Links und Videos nie, alles andere auch mit "is-downloadable": false
    func testDownloadCandidates() {
        let files = [
            StudIPFile(id: "a", courseID: "c", name: "Folien.pdf", size: 1, mimeType: "application/pdf", changed: "", isDownloadable: false),
            StudIPFile(id: "b", courseID: "c", name: "Link", size: 0, changed: "", isDownloadable: false, linkURL: "https://example.org/x"),
            StudIPFile(id: "c", courseID: "c", name: "Vorlesung.mp4", size: 9, mimeType: "video/mp4", changed: "", isDownloadable: false),
            StudIPFile(id: "d", courseID: "c", name: "Blatt.pdf", size: 1, changed: "", isDownloadable: true),
        ]
        XCTAssertEqual(StudIPSync.downloadCandidates(files).map(\.id), ["a", "d"])
    }

    // MARK: Ansicht

    func testLoadStateTextsPromiseOnlyWhatHappens() {
        XCTAssertFalse(DocumentOpenText.notLoaded.contains("Der nächste Abgleich lädt sie"))
        XCTAssertEqual(FileLoadState.idle.headline, UFDevice.adapt("Noch nicht auf diesem iPad"))
        XCTAssertTrue(FileLoadState.idle.canRetry)
        XCTAssertFalse(FileLoadState.loading.canRetry)
        XCTAssertTrue(FileLoadState.failed("Stud.IP hat die Datei nicht geliefert (Fehler 500).").detail.contains("Erneut versuchen"))
        XCTAssertTrue(FileLoadState.needsLogin.detail.contains("Stud.IP"))
        XCTAssertEqual(FileLoadState(.loaded), .loaded)
        XCTAssertEqual(FileLoadState(.notStudIP), .otherSource)
    }

    /// Ansicht einer nicht geladenen Datei: laedt beim Oeffnen selbst, danach `onLoaded`; bei einem Fehler Grund und
    /// "Erneut versuchen", das dann laedt
    func testPanelLoadsOnOpenAndRetries() throws {
        Self.accessibilityAutomation(true)
        addTeardownBlock { Self.accessibilityAutomation(false) }
        let dev = try device()
        let stud = portal()
        stud.status("/jsonapi.php/v1/file-refs/v1b/content", 500)
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        let listed = expectation(description: "Listen")
        Task { await sync.run(client: self.client(stud), scope: .lists); listed.fulfill() }
        wait(for: [listed], timeout: 20)
        sync.fileClientForTests = client(stud)
        var done = 0
        let file = LibFile(id: "v1b", name: "Beispiel_Kap_2.pdf", title: nil, kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: nil, has_notes: nil, page_count: nil, studip_folder: "")
        let root = host(FileLoadPanel(file: file) { done += 1 }.environment(\.studipFiles, sync))
        // erstes Bild: "Wird geladen", nie kurz "Noch nicht auf diesem iPad" mit "Jetzt laden" (Befund iPad 07.11., 23:35)
        let first = labels(root)
        XCTAssertFalse(first.contains(UFDevice.adapt("Noch nicht auf diesem iPad")), "\(first)")
        XCTAssertFalse(first.contains("Jetzt laden"), "\(first)")
        // beim Oeffnen sofort versucht: Stud.IP gestoert, Grund sichtbar
        XCTAssertNotNil(waitFor(root, label: "Nicht geladen"), "\(labels(root))")
        XCTAssertTrue(labels(root).contains { $0.contains("500") }, "\(labels(root))")
        XCTAssertEqual(stud.contentRequests("v1b"), 1)
        let retry = try XCTUnwrap(waitFor(root, label: "Erneut versuchen"), "\(labels(root))")
        stud.set("/jsonapi.php/v1/file-refs/v1b/content", HTTPReply(status: 200, contentType: "application/pdf", body: Self.pdf("v1b")))
        XCTAssertTrue(retry.accessibilityActivate())
        let end = Date().addingTimeInterval(8)
        while done == 0, Date() < end { pump(0.2) }
        XCTAssertEqual(done, 1)
        XCTAssertTrue(sync.entries.contains { $0.id == "v1b" })
    }

    /// Ganze Datei-Ansicht: nach dem Laden, waehrend die Bibliothek neu liest, erscheint nie die alte Meldung
    /// "noch nicht auf diesem iPad" (Befund iPad 08.11.2026: blitzte vor dem Dokument auf)
    func testOutsideEditorViewShowsNoStaleMessageAfterLoad() throws {
        Self.accessibilityAutomation(true)
        addTeardownBlock { Self.accessibilityAutomation(false) }
        let dev = try device()
        let stud = portal()
        stud.status("/jsonapi.php/v1/file-refs/v1b/content", 500)
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        let listed = expectation(description: "Listen")
        Task { await sync.run(client: self.client(stud), scope: .lists); listed.fulfill() }
        wait(for: [listed], timeout: 20)
        stud.set("/jsonapi.php/v1/file-refs/v1b/content", HTTPReply(status: 200, contentType: "application/pdf", body: Self.pdf("v1b")))
        sync.fileClientForTests = client(stud)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: dev.host))
        let file = LibFile(id: "v1b", name: "Beispiel_Kap_2.pdf", title: nil, kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: nil, has_notes: nil, page_count: nil, studip_folder: "")
        var reloaded = 0
        // die Bibliothek braucht fuer das Neulesen einen Moment (wie am iPad): solange darf nichts Altes erscheinen
        let started = Date()
        var finished: Date?
        let root = host(FileOutsideEditorView(file: file, api: api, onLoaded: {
            await withCheckedContinuation { c in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { c.resume() } }
            reloaded += 1; finished = Date()
        }).environment(\.studipFiles, sync))
        let end = Date().addingTimeInterval(8)
        var seen: [String] = []
        while reloaded == 0, Date() < end {
            pump(0.1)
            seen += labels(root)
        }
        XCTAssertEqual(reloaded, 1)
        XCTAssertGreaterThan((finished ?? started).timeIntervalSince(started), 1.4, "das Fenster vor dem Editorwechsel wurde beobachtet")
        XCTAssertFalse(seen.contains { $0.lowercased().contains("noch nicht auf diesem ipad") }, "\(Set(seen))")
        XCTAssertFalse(seen.contains { $0.contains("Jetzt laden") || $0.contains("nächste Abgleich") }, "\(Set(seen))")
    }

    /// Jeder Abgleich meldet sein Ende (`.uniflowSyncFinished`): die Bibliothek liest danach ihre Liste neu
    func testRunPostsSyncFinishedNotification() throws {
        let dev = try device()
        let stud = portal()
        let sync = StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults())
        let posted = expectation(forNotification: .uniflowSyncFinished, object: nil)
        let done = expectation(description: "Lauf")
        Task { await sync.run(client: self.client(stud), scope: .lists); done.fulfill() }
        wait(for: [posted, done], timeout: 20)
    }

    /// Mit UF_SCREENSHOT_DIR: die Zustaende als Bild (hell und dunkel)
    func testScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let states: [(String, FileLoadState)] = [
            ("bereit", .idle), ("laedt", .loading),
            ("fehler", .failed(DownloadFailures.describe(StudIPError.http(status: 403, path: "")).message)),
            ("anmeldung", .needsLogin),
        ]
        for (name, state) in states {
            let root = host(FileLoadPanelContent(title: "Beispiel_Kap_2.pdf", size: 400_261, state: state, retry: {}))
            for (style, tone) in [(UIUserInterfaceStyle.light, "hell"), (.dark, "dunkel")] {
                root.window?.overrideUserInterfaceStyle = style
                pump(0.6)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                let png = UIGraphicsImageRenderer(bounds: root.bounds, format: format).pngData { _ in
                    _ = root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
                }
                try png.write(to: dir.appendingPathComponent("datei-laden-\(name)-\(tone).png"))
            }
        }
    }

    // MARK: Hilfen

    /// Bedienungshilfen-Baum auch ohne VoiceOver (wie MessageReplyAppTests)
    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func host<V: View>(_ view: V) -> UIView {
        let frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return hosting.view
    }

    private func pump(_ seconds: Double = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func elements(_ root: UIView) -> [NSObject] {
        root.layoutIfNeeded()
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ e: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = e as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                let id = (o as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
                if o.accessibilityLabel?.isEmpty == false || !id.isEmpty { out.append(o) }
                for c in o.accessibilityElements ?? [] { visit(c, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 600) { if let c = o.accessibilityElement(at: i) { visit(c, depth: depth + 1) } } }
            }
            if let v = e as? UIView, !v.isHidden { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return out
    }

    private func labels(_ root: UIView) -> [String] { elements(root).compactMap(\.accessibilityLabel) }

    private func waitFor(_ root: UIView, label: String, seconds: Double = 8) -> NSObject? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let e = elements(root).first(where: { ($0.accessibilityLabel ?? "").hasPrefix(label) }) { return e }
            pump(0.2)
        }
        return nil
    }
}
