import PDFKit
import PencilKit
import SwiftUI
import XCTest
import UniFlowCore
@testable import UniFlow

/// S7 im lokalen Modus (ohne PC): neue Original-Fassung aus Stud.IP mit erhaltenen Notizen und Suche offline. Stud.IP
/// antwortet mit festen, erfundenen Daten (kein Netz); die Seitentexte liest PDFKit aus selbst erzeugten PDFs.
@MainActor
final class NewVersionSearchAppTests: XCTestCase {

    // MARK: Umgebung

    /// Container (erfundener Apple-Nutzer, LUH) wie in der App (`ContainerManager`): Datenbank, Stud.IP-Dateien, alte
    /// Fassungen und Editor-Zwischenspeicher liegen darin
    private struct Device {
        let layout: DataContainerLayout
        let host: LocalBackendHost
        let api: APIClient
        var studipRoot: URL { layout.studip }
        var support: URL { layout.root }
    }

    private static let clock = UniFlowClock.fixed(berlin: "2026-10-26T09:30:00")!

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-s7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func device() throws -> Device {
        let layout = DataContainerLayout(base: try tempDir(), key: DataContainerKey(userID: "001234.erfunden.s7", university: .luh))
        try layout.prepare(clock: Self.clock)
        let host = LocalBackendHost(directory: layout.databaseDirectory, clock: Self.clock, files: .container(layout), university: .luh)
        return Device(layout: layout, host: host, api: APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)))
    }

    /// Stud.IP-Abgleich in den Container des Geraets wie in der App
    private func studip(_ dev: Device) throws -> StudIPSync {
        StudIPSync(root: dev.studipRoot, host: dev.host, clock: Self.clock, defaults: try defaults(), support: dev.support, container: dev.layout)
    }

    private func defaults() throws -> UserDefaults {
        let suite = "uniflow-s7-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// PDF mit einer Textzeile je Seite (PDFKit liest sie als Seitentext)
    private func makePDF(_ pages: [String]) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for text in pages {
                ctx.beginPage()
                (text as NSString).draw(in: CGRect(x: 60, y: 80, width: 480, height: 600), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
    }

    /// Stud.IP mit einem erfundenen Kurs und einer Datei d1, Inhalt und Aenderungszeit austauschbar
    private final class FakeStudIP: StudIPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: HTTPReply] = [:]
        private var log: [String] = []

        var downloads: [String] { lock.withLock { log.filter { $0.hasSuffix("/content") } } }

        func set(_ path: String, _ reply: HTTPReply) { lock.withLock { routes[path] = reply } }

        func json(_ path: String, _ text: String) {
            set(path, HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(text.utf8)))
        }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            let key = url.absoluteString.replacingOccurrences(of: StudIPSync.base.absoluteString, with: "")
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            return lock.withLock {
                log.append(key)
                return routes[key] ?? HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
            }
        }

        /// Kurs "Testkurs Lineare Algebra" mit der Datei d1 "VL03 Eigenwerte.pdf" (eine Vorlesung)
        func file(_ pdf: Data, changed: String) {
            json("/jsonapi.php/v1/users/me", #"{"data":{"id":"u1","type":"users"}}"#)
            json("/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester", #"""
                {"data":[{"id":"c1","type":"courses","attributes":{"title":"Testkurs Lineare Algebra","course-number":"T-LA"},
                  "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}}],
                 "included":[{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}]}
                """#)
            json("/jsonapi.php/v1/courses/c1/folders?page[limit]=200", #"{"data":[{"id":"r1","attributes":{"folder-type":"RootFolder","name":""}}]}"#)
            json("/jsonapi.php/v1/folders/r1/file-refs?page[limit]=500", #"""
                {"data":[{"id":"d1","attributes":{"name":"VL03 Eigenwerte.pdf","filesize":\#(pdf.count),"mime-type":"application/pdf","chdate":"\#(changed)","is-downloadable":true}}]}
                """#)
            json("/jsonapi.php/v1/folders/r1/folders?page[limit]=200", #"{"data":[]}"#)
            set("/jsonapi.php/v1/file-refs/d1/content", HTTPReply(status: 200, contentType: "application/pdf", body: pdf))
        }
    }

    private func client(_ t: FakeStudIP) -> StudIPClient {
        StudIPClient(base: StudIPSync.base, transport: t, pauseMillis: 0, retry: UniRetry(attempts: 3, delayNanos: { _ in 0 }))
    }

    private func drawing(y: CGFloat) -> PKDrawing {
        let pts = (0..<12).map { i in
            PKStrokePoint(location: CGPoint(x: 100 + CGFloat(i) * 20, y: y), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))])
    }

    private func waitUntil(_ timeout: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private func libraryFile(_ api: APIClient, _ id: String) async throws -> LibFile {
        let lib = try await api.json("/api/library", as: LibraryResponse.self)
        return try XCTUnwrap(lib.files.first { $0.id == id }, "Datei \(id) in der Bibliothek")
    }

    private func strokeCount(_ api: APIClient, page key: String) async throws -> Int {
        let v = try await api.value("/api/files/d1/annotations")
        return (v["data"]?["pages"]?[key]?["objects"]?.array ?? []).filter { $0["type"]?.string == "stroke" }.count
    }

    private let v1Pages = ["Kapitel Eins: Vektorräume und Basis", "Kapitel Zwei: Eigenwerte und Eigenvektoren",
                           "Kapitel Drei: Determinanten"]
    private let v2Pages = ["Kapitel Eins: Vektorräume und Basis", "Neu eingefügt: Wiederholung Matrizen",
                           "Kapitel Zwei: Eigenwerte und Eigenvektoren", "Kapitel Drei: Determinanten nach Laplace"]

    // MARK: Abnahme S7: Notizen ueberleben eine neue PDF

    /// Datei mit Notizen bekommt in Stud.IP eine neue Fassung (Folie eingefuegt, letzte Seite geaendert): die Notizen
    /// stehen danach auf den passenden Seiten der neuen Fassung, der Editor zeigt die neue PDF mit dem Hinweis "Neue
    /// Fassung aus Stud.IP – Notizen übernommen (1 Seite prüfen)", die alte Fassung oeffnet sich mit ihren Notizen und
    /// eine geteilte Loesung zur alten Fassung erscheint dort (nicht auf der neuen)
    func testFileWithNotesGetsNewVersionNotesOnMatchingPagesOldVersionOpens() async throws {
        let dev = try device()
        let v1 = makePDF(v1Pages), v2 = makePDF(v2Pages)
        let stud = FakeStudIP()
        stud.file(v1, changed: "2026-10-19T10:00:00+02:00")
        let sync = try studip(dev)
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")

        // Notizen auf Seite 2 und 3 der alten Fassung
        let file = try await libraryFile(dev.api, "d1")
        let store = DocumentStore(file: file, api: dev.api, root: dev.support)
        await store.load()
        XCTAssertEqual(store.pdf?.pageCount, 3)
        XCTAssertNil(store.versionNotice)
        store.canvasChanged(pageKey: "p2", drawing: drawing(y: 300))
        store.canvasChanged(pageKey: "p3", drawing: drawing(y: 500))
        await store.flush()
        let saved = await waitUntil {
            let two = (try? await self.strokeCount(dev.api, page: "p2")) ?? 0
            let three = (try? await self.strokeCount(dev.api, page: "p3")) ?? 0
            return two == 1 && three == 1
        }
        XCTAssertTrue(saved, "Striche in der lokalen Datenbank")
        await store.close()

        // neue Fassung in Stud.IP
        stud.file(v2, changed: "2026-10-26T08:00:00+02:00")
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        XCTAssertEqual(stud.downloads.count, 2)

        // Notizen auf den passenden Seiten der neuen Fassung
        let data = try await dev.api.value("/api/files/d1/annotations")["data"]
        let doc = AnnotationDocument(root: try XCTUnwrap(data))
        XCTAssertEqual(doc.pdfIndex(forPageKey: "p2"), 3, "Eigenwerte stehen jetzt auf Seite 3")
        XCTAssertEqual(doc.pdfIndex(forPageKey: "p3"), 4)
        XCTAssertEqual(doc.objects(page: "p2").count, 1)
        XCTAssertEqual(doc.objects(page: "p3").count, 1)
        XCTAssertEqual(doc.root["origin"]?["sha256"]?.string, SolutionSHA256.hex(v2))

        // Editor: neue PDF (Zwischenspeicher erneuert), Notiz auf der richtigen Seite, Hinweis mit Weg zur alten Fassung
        let current = try await libraryFile(dev.api, "d1")
        let reopened = DocumentStore(file: current, api: dev.api, root: dev.support)
        await reopened.load()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.pdf?.pageCount, 4)
        XCTAssertEqual(try reopened.originalPDFData(), v2)
        XCTAssertFalse(reopened.outdatedByNewVersion)
        XCTAssertEqual(reopened.entry(forKey: "p2")?.pdfIndex, 3)
        XCTAssertEqual(reopened.entry(forPageIndex: 1)?.pdfIndex, 2, "neue Seite ohne Notizen")
        let notesOnThree = await reopened.objects(forPageKey: "p2")
        XCTAssertEqual(notesOnThree.count, 1)
        let notice = try XCTUnwrap(reopened.versionNotice)
        XCTAssertEqual(notice.noticeTitle, "Neue Fassung aus Stud.IP – Notizen übernommen (1 Seite prüfen)")
        XCTAssertEqual(notice.noticeDetail, "Geänderte Seite 4")
        XCTAssertTrue(notice.available)
        XCTAssertEqual(reopened.versions.map(\.version), [1])
        // alte PDF im Container (Stud.IP-Ordner, ohne Backup), nicht im Ordner der Downloads
        let keptRow = try await dev.host.backend().context.database.scalar("SELECT local_path FROM file_versions WHERE file_id='d1'")?.string
        let keptPath = try XCTUnwrap(keptRow)
        XCTAssertTrue(keptPath.hasPrefix("StudIP/Fassungen/"), keptPath)
        XCTAssertEqual(try Data(contentsOf: dev.layout.root.appendingPathComponent(keptPath)), v1)

        // alte Fassung: alte PDF mit den Notizen von damals, nur zum Ansehen
        let old = DocumentStore(file: reopened.oldVersionFile(notice), api: dev.api, root: dev.support)
        await old.load()
        XCTAssertNil(old.errorMessage)
        XCTAssertEqual(old.pdf?.pageCount, 3)
        XCTAssertEqual(try old.originalPDFData(), v1)
        XCTAssertEqual(old.entry(forKey: "p2")?.pdfIndex, 2)
        let oldNotes = await old.objects(forPageKey: "p2")
        XCTAssertEqual(oldNotes.count, 1)
        XCTAssertTrue(old.isOldVersion)

        // geteilte Loesung zur alten Fassung: dort zuordenbar (gleicher Fingerabdruck), nicht auf der neuen
        let cipher = CryptoKitSolutionCipher()
        let oldPrint = await old.originalFingerprint()
        XCTAssertEqual(oldPrint, SolutionSHA256.hex(v1))
        let classmate = AnnotationDocument(root: ["version": 2, "pageOrder": [["key": "p2", "type": "pdf", "index": 2]],
                                                  "pages": ["p2": ["objects": [["id": "m1", "type": "stroke", "points": [10, 10, 50, 50], "color": "#000000", "width": 2]]]]])
        let content = try SolutionSharing.content(SolutionSource(document: classmate, originalPDF: v1, pdf: PDFDocument(data: v1)!,
                                                                 fingerprint: cipher.sha256Hex(v1), images: [:], title: "VL03"),
                                                  keys: ["p2"], displayName: "Lea")
        let package = try SolutionSharing.package(content, originalPDF: v1)
        let library = SolutionLibrary(root: try tempDir())
        _ = try library.importPackage(package.encoded())
        let onOld = SolutionSharing.loadLayers(library: library, originalPDF: try old.originalPDFData(), fingerprint: try XCTUnwrap(oldPrint),
                                               pdf: try XCTUnwrap(old.originalPDF))
        XCTAssertEqual(onOld.layers.count, 1, onOld.problems.map(\.text).joined())
        let newPrint = await reopened.originalFingerprint()
        let onNew = SolutionSharing.loadLayers(library: library, originalPDF: try reopened.originalPDFData(), fingerprint: try XCTUnwrap(newPrint),
                                               pdf: try XCTUnwrap(reopened.originalPDF))
        XCTAssertEqual(onNew.layers.count, 0)
        await old.close()

        // Hinweis gesehen: kommt nicht wieder, die alte Fassung bleibt erreichbar
        await reopened.dismissVersionNotice()
        await reopened.close()
        let latest = try await libraryFile(dev.api, "d1")
        let third = DocumentStore(file: latest, api: dev.api, root: dev.support)
        await third.load()
        XCTAssertNil(third.versionNotice)
        XCTAssertEqual(third.versions.count, 1)
        await third.close()

        // "Abmelden und Dateien löschen": die alte Fassung bleibt (laesst sich aus Stud.IP nicht mehr laden)
        await sync.removeDownloads()
        let kept = try await dev.api.data("/api/files/d1/versions/1/content")
        XCTAssertEqual(kept.1.statusCode, 200)
        XCTAssertEqual(kept.0, v1)
    }

    /// Ohne Notizen: die neue Fassung ersetzt die alte wie bisher, keine alte Fassung, kein Hinweis; der Editor zeigt
    /// die neue PDF mit allen Seiten (Zwischenspeicher erneuert)
    func testFileWithoutNotesIsSimplyReplaced() async throws {
        let dev = try device()
        let v1 = makePDF(v1Pages), v2 = makePDF(v2Pages)
        let stud = FakeStudIP()
        stud.file(v1, changed: "2026-10-19T10:00:00+02:00")
        let sync = try studip(dev)
        await sync.run(client: client(stud))
        let first = try await libraryFile(dev.api, "d1")
        let store = DocumentStore(file: first, api: dev.api, root: dev.support)
        await store.load()
        XCTAssertEqual(store.pdf?.pageCount, 3)
        await store.close()
        stud.file(v2, changed: "2026-10-26T08:00:00+02:00")
        await sync.run(client: client(stud))
        let versions = try await dev.api.value("/api/files/d1/versions")
        XCTAssertEqual(versions["versions"], [])
        let second = try await libraryFile(dev.api, "d1")
        let again = DocumentStore(file: second, api: dev.api, root: dev.support)
        await again.load()
        XCTAssertEqual(again.pdf?.pageCount, 4)
        XCTAssertNil(again.versionNotice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dev.studipRoot.appendingPathComponent("Fassungen").path))
        await again.close()
    }

    /// Neue Fassung, waehrend das Dokument offen ist (Seite 2 entfaellt): nach dem Zusammenfuehren bleibt die Anzeige
    /// der alten PDF, wie sie war (vorher lag die neue Seitenliste auf der alten PDF: Notizen auf falschen Folien),
    /// nur noch ansehen; ein Strich, der noch auf die entfallene Seite ging, steht in der alten Fassung (vorher auf
    /// einer Seite ohne Eintrag in der Seitenliste, nirgends sichtbar). Neu geoeffnet: neue PDF, Hinweis.
    func testNewVersionWhileOpenKeepsDisplayAndLateStrokesReachOldVersion() async throws {
        let dev = try device()
        let v1 = makePDF(v1Pages), v2 = makePDF([v1Pages[0], v1Pages[2]])
        let stud = FakeStudIP()
        stud.file(v1, changed: "2026-10-19T10:00:00+02:00")
        let sync = try studip(dev)
        await sync.run(client: client(stud))
        let store = DocumentStore(file: try await libraryFile(dev.api, "d1"), api: dev.api, root: dev.support)
        await store.load()
        store.canvasChanged(pageKey: "p2", drawing: drawing(y: 300))
        store.canvasChanged(pageKey: "p3", drawing: drawing(y: 500))
        await store.flush()
        let saved = await waitUntil {
            let two = (try? await self.strokeCount(dev.api, page: "p2")) ?? 0
            let three = (try? await self.strokeCount(dev.api, page: "p3")) ?? 0
            return two == 1 && three == 1
        }
        XCTAssertTrue(saved)

        // neue Fassung, das Dokument bleibt offen; danach noch ein Strich auf Seite 2
        stud.file(v2, changed: "2026-10-26T08:00:00+02:00")
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle, "\(sync.phase)")
        store.canvasChanged(pageKey: "p2", drawing: PKDrawing(strokes: drawing(y: 300).strokes + drawing(y: 700).strokes))
        await store.flush()
        let outdated = await waitUntil { store.outdatedByNewVersion }
        XCTAssertTrue(outdated)
        XCTAssertFalse(store.isWritable)
        XCTAssertEqual(store.pdf?.pageCount, 3, "angezeigt bleibt die alte PDF")
        XCTAssertEqual(store.entry(forKey: "p3")?.pdfIndex, 3, "Notizen bleiben auf ihrer Folie")
        XCTAssertEqual(store.entry(forKey: "p2")?.pdfIndex, 2)
        let late = await waitUntil {
            let old = try? await dev.api.value("/api/files/d1/versions/1/annotations")
            return (old?["data"]?["pages"]?["p2"]?["objects"]?.array ?? []).filter { $0["type"]?.string == "stroke" }.count == 2
        }
        XCTAssertTrue(late, "spaeter Strich in der alten Fassung")
        await store.close()

        let reopened = DocumentStore(file: try await libraryFile(dev.api, "d1"), api: dev.api, root: dev.support)
        await reopened.load()
        XCTAssertEqual(reopened.pdf?.pageCount, 2)
        XCTAssertFalse(reopened.outdatedByNewVersion)
        XCTAssertEqual(reopened.entry(forKey: "p3")?.pdfIndex, 2)
        XCTAssertNil(reopened.entry(forKey: "p2"))
        XCTAssertEqual(reopened.versionNotice?.noticeDetail, "Nur in der alten Fassung: Seite 2")
        await reopened.close()
    }

    /// Hinweis nennt geaenderte Seiten getrennt von unsicher zugeordneten (gleicher Text mehrfach, ohne Text)
    func testNoticeSeparatesChangedFromUnsurePages() throws {
        let v = try XCTUnwrap(FileVersionInfo(["version": 1, "document_id": "d1/versions/1", "source": "Stud.IP",
                                              "check": [["old": 3, "new": 4, "kind": "aehnlich"], ["old": 2, "new": 2, "kind": "wiederholt"],
                                                        ["old": 6, "new": 6, "kind": "position"]],
                                              "removed": [7]]))
        XCTAssertEqual(v.noticeTitle, "Neue Fassung aus Stud.IP – Notizen übernommen (4 Seiten prüfen)")
        XCTAssertEqual(v.noticeDetail, "Geänderte Seite 4 · Unsicher zugeordnet: Seiten 2, 6 · Nur in der alten Fassung: Seite 7")
        let legacy = try XCTUnwrap(FileVersionInfo(["version": 1, "document_id": "d1/versions/1", "check": [["old": 3, "new": 4]]]))
        XCTAssertEqual(legacy.noticeDetail, "Geänderte Seite 4", "ohne Art wie bisher")
    }

    // MARK: Hinweis im Dokument (Fenster, Bedienungshilfen-Baum)

    private func awaiting<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = expectation(description: "async")
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        return try XCTUnwrap(result).get()
    }

    /// SwiftUI baut den Bedienungshilfen-Baum nur, wenn ein Hilfsmittel aktiv ist (wie bei UI-Tests)
    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func window<V: View>(_ view: V) -> UIWindow {
        let frame = CGRect(x: 0, y: 0, width: 1180, height: 1400)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = UIHostingController(rootView: NavigationStack { view })
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return window
    }

    @discardableResult
    private func pump(timeout: Double = 15, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    /// Elemente des Bedienungshilfen-Baums (auch vorgestellter Ansichten im Fenster); die PDF-Seiten selbst (PDFKit,
    /// PencilKit) bleiben aussen vor, ihr Baum ist gross und hier ohne Belang
    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 60 else { return }
            if element is PDFView || element is PKCanvasView { return }
            if let o = element as? NSObject, NSStringFromClass(type(of: o)).hasPrefix("PDF") { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false || o.accessibilityValue?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    private func texts(_ view: UIView) -> [String] {
        elements(in: view).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ view: UIView, _ text: String) -> Bool { texts(view).contains { $0.contains(text) } }

    private func tap(_ label: String, in view: UIView) -> Bool {
        for e in elements(in: view) where e.accessibilityLabel == label && e.accessibilityTraits.contains(.button) {
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    /// Im Editor nach der neuen Fassung: Hinweis "Neue Fassung aus Stud.IP – Notizen übernommen (1 Seite prüfen)" mit
    /// der geaenderten Seite ueber der Seite, "Alte Fassung" oeffnet die alte PDF (3 Seiten, nur ansehen), "OK" blendet
    /// den Hinweis dauerhaft aus
    func testDocumentShowsNoticeAndOpensOldVersion() throws {
        let (dev, file, sync) = try awaiting { () -> (Device, LibFile, StudIPSync) in
            let dev = try self.device()
            let stud = FakeStudIP()
            stud.file(self.makePDF(self.v1Pages), changed: "2026-10-19T10:00:00+02:00")
            let sync = try self.studip(dev)
            await sync.run(client: self.client(stud))
            let notes: JSONValue = ["version": 2, "pageOrder": [["key": "p1", "type": "pdf", "index": 1], ["key": "p2", "type": "pdf", "index": 2],
                                                                ["key": "p3", "type": "pdf", "index": 3]],
                                    "pages": ["p1": ["objects": []], "p2": ["objects": [["id": "a", "type": "stroke", "points": [10, 10, 90, 90], "color": "#000000", "width": 2]]],
                                              "p3": ["objects": [["id": "b", "type": "stroke", "points": [10, 10, 90, 90], "color": "#000000", "width": 2]]]]]
            _ = try await dev.api.value("/api/files/d1/annotations?base_version=0", method: "PUT", body: notes)
            stud.file(self.makePDF(self.v2Pages), changed: "2026-10-26T08:00:00+02:00")
            await sync.run(client: self.client(stud))
            return (dev, try await self.libraryFile(dev.api, "d1"), sync)
        }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        // StudIPSync wie in der App ueber der Seite (das Dokument fragt dessen Aufzeichnungen nach einem Vorschlag)
        let win = window(DocumentView(file: file, api: dev.api).environmentObject(sync))
        let title = "Neue Fassung aus Stud.IP – Notizen übernommen (1 Seite prüfen)"
        XCTAssertTrue(pump { self.shows(win, title) }, texts(win).joined(separator: "\n"))
        XCTAssertTrue(shows(win, "Geänderte Seite 4"))
        XCTAssertTrue(pump { self.shows(win, "Seite 1 / 4") }, texts(win).joined(separator: "\n"))

        XCTAssertTrue(tap("Alte Fassung", in: win), texts(win).joined(separator: "\n"))
        XCTAssertTrue(pump { self.shows(win, "Alte Fassung – nur ansehen") && self.shows(win, "Seite 1 / 3") }, texts(win).joined(separator: "\n"))
        XCTAssertTrue(tap("Schließen", in: win), texts(win).joined(separator: "\n"))
        XCTAssertTrue(pump { !self.shows(win, "Alte Fassung – nur ansehen") })

        XCTAssertTrue(tap("OK", in: win), texts(win).joined(separator: "\n"))
        XCTAssertTrue(pump { !self.shows(win, title) })
        let after = try awaiting { try await dev.api.value("/api/files/d1/versions") }
        XCTAssertEqual(after["notice"], .null)
        XCTAssertEqual(after["versions"]?.array?.count, 1)
    }

    // MARK: Abnahme S7: Suche offline

    /// Suche findet Text aus einer PDF ohne Netz: der Abgleich liest die Seitentexte mit PDFKit, `GET /api/search`
    /// liefert die Seite mit Ausschnitt, die Suche der Kopfzeile zeigt sie und fuehrt zum Dokument an dieser Seite
    func testSearchFindsTextFromPDFOffline() async throws {
        let dev = try device()
        let pdf = makePDF(["Organisatorisches zur Vorlesung", "Heute: Quantenchromodynamik und Gluonen im Überblick"])
        let stud = FakeStudIP()
        stud.file(pdf, changed: "2026-10-19T10:00:00+02:00")
        let sync = try studip(dev)
        await sync.run(client: client(stud))
        XCTAssertEqual(sync.phase, .idle)
        let before = stud.downloads.count

        let r = try await dev.api.value("/api/search?q=quantenchromo")
        let pages = r["pages"]?.array ?? []
        XCTAssertEqual(pages.map { $0["file_id"] }, ["d1"])
        XCTAssertEqual(pages.first?["page"], 2)
        XCTAssertTrue(pages.first?["snippet"]?.string?.contains("Quantenchromodynamik") ?? false, "\(pages)")
        // Dateiname und Modul weiter wie am PC
        let byName = try await dev.api.value("/api/search?q=eigenwerte")
        XCTAssertEqual(byName["files"]?.array?.compactMap { $0["id"]?.string }, ["d1"])
        let byModule = try await dev.api.value("/api/search?q=lineare")
        XCTAssertEqual(byModule["modules"]?.array?.compactMap { $0["name"]?.string }, ["Testkurs Lineare Algebra"])
        // Seitentext und Skriptsuche antworten (ohne Treffer, aber ohne Fehler)
        let text = try await dev.api.value("/api/files/d1/pagetext?page=2")
        XCTAssertTrue(text["text"]?.string?.contains("Gluonen") ?? false)
        XCTAssertEqual(text["pages"], 2)

        // Kopfzeile: Treffer mit Weg zur Seite
        let shell = ShellState()
        shell.api = dev.api
        shell.search("Quantenchromo")
        let found = await waitUntil { shell.searchHits.contains { $0.id == "pd1-2" } }
        XCTAssertTrue(found, "\(shell.searchHits.map(\.title))")
        let hit = try XCTUnwrap(shell.searchHits.first { $0.id == "pd1-2" })
        XCTAssertEqual(hit.title, "VL03 Eigenwerte.pdf · Seite 2")
        XCTAssertEqual(hit.route, .doc("d1", page: 2))
        XCTAssertEqual(stud.downloads.count, before, "Suche ohne Netz")

        // Aufgabe des Lernplans: in der Suche mit Weg zur Tagesansicht
        _ = try await dev.api.value("/api/packages", method: "POST",
                                    body: ["date": "2026-10-27", "title": "Lernen", "tasks": [["type": "frei", "title": "Quantenchromodynamik wiederholen", "est_minutes": 30]]])
        shell.search("Quantenchromo")
        let task = await waitUntil { shell.searchHits.contains { $0.route == .plan(view: "day", date: "2026-10-27") } }
        XCTAssertTrue(task, "\(shell.searchHits.map(\.title))")
    }

    /// Suchtext mit "+", "&" und "=" kommt unverfaelscht im lokalen Backend an (wie `encodeURIComponent` im Web).
    /// Vorher kodierte die Kopfzeile mit `.urlQueryAllowed`: aus "C++" wurde "C  " (zu kurz, keine Treffer), und
    /// "Signale & Systeme" kam als "Signale " an. Dazu Namen mit grossem Umlaut (Suchform statt SQLite lower()).
    func testHeaderSearchEncodesPlusAmpersandAndFindsCapitalUmlauts() async throws {
        XCTAssertEqual(APIClient.queryValue("C++ & a=b #1/ü"), "C%2B%2B%20%26%20a%3Db%20%231%2F%C3%BC")
        XCTAssertEqual(APIClient.queryValue("A-z_0.9~!*'()"), "A-z_0.9~!*'()")
        let dev = try device()
        _ = try await dev.api.value("/api/packages", method: "POST", body: ["date": "2026-10-27", "title": "Lernen", "tasks": [
            ["type": "frei", "title": "C++ Zeiger wiederholen", "est_minutes": 30],
            ["type": "frei", "title": "Signale & Systeme Blatt 2", "est_minutes": 30],
            ["type": "frei", "title": "Übungsblatt a=b lösen", "est_minutes": 30],
        ]])
        let shell = ShellState()
        shell.api = dev.api
        for (query, title) in [("C++", "C++ Zeiger wiederholen"), ("Signale & Systeme", "Signale & Systeme Blatt 2"),
                               ("a=b", "Übungsblatt a=b lösen"), ("übungsblatt", "Übungsblatt a=b lösen")] {
            shell.search(query)
            let found = await waitUntil { shell.searchHits.map(\.title) == [title] }
            XCTAssertTrue(found, "\(query): \(shell.searchHits.map(\.title))")
        }
    }
}
