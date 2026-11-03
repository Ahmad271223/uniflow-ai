import PDFKit
import SwiftUI
import UIKit
import XCTest
@testable import UniFlow
import UniFlowCore

/// Korrekturen aus docs/AUDIT-ROBUSTHEIT-2026-11-03.md (App)
@MainActor
final class AuditRobustheit20261103AppTests: XCTestCase {
    /// Liefert fuer jede Datei dieselbe einseitige PDF und zaehlt die Anfragen
    final class PDFTransport: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let pdf: Data

        init() {
            pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
                ctx.beginPage()
                ("Blatt" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }

        var requests: Int { lock.withLock { count } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { count += 1 }
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/pdf"])!
            return (pdf, r)
        }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-robust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Vorschauen: eine abgebrochene Kachel (weggescrollt, Ansicht verlassen) laedt und zeichnet keine PDF mehr;
    /// eine gezeichnete Vorschau kommt danach aus dem Speicher (keine zweite Anfrage). Der Speicher hat eine Grenze.
    func testThumbnailsSkipCancelledTilesAndCacheWithLimit() async throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: DataContainerLayout.Folder.thumbs.url(in: root), withIntermediateDirectories: true)
        let thumbs = UFThumbnails(root: root)
        let t = PDFTransport()
        let api = APIClient(base: APIClient.localBase, transport: t)

        let cancelled = await Task { () -> UIImage? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await thumbs.image(fileID: "f1", version: "1", image: false, api: api)
        }.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(t.requests, 0, "abgebrochene Kachel: keine PDF geladen")

        let first = await thumbs.image(fileID: "f1", version: "1", image: false, api: api)
        XCTAssertNotNil(first)
        XCTAssertEqual(t.requests, 1)
        let again = await thumbs.image(fileID: "f1", version: "1", image: false, api: api)
        XCTAssertNotNil(again)
        XCTAssertEqual(t.requests, 1, "zweites Mal aus dem Speicher")

        XCTAssertLessThanOrEqual(UFThumbnails.memoryCountLimit, 500)
        XCTAssertLessThanOrEqual(UFThumbnails.memoryCostLimit, 128 * 1024 * 1024)
        let img = try XCTUnwrap(first)
        XCTAssertEqual(UFThumbnails.cost(img), Int(img.size.width * img.scale * img.size.height * img.scale * 4))
    }

    /// Konto-Export (ZIP mit allen Kontodaten) liegt im Teilen-Ordner des Containers, nicht im gemeinsamen tmp-Ordner:
    /// "Daten dieser Hochschule löschen" und der naechste Start entfernen ihn
    func testAccountExportLivesInContainerTempFolder() throws {
        let container = UUID()
        let url = try StudoraAccountLink.exportFileURL(container: container)
        XCTAssertEqual(url.lastPathComponent, "studinow-export.zip")
        XCTAssertTrue(url.path.hasPrefix(AppTemp.folder(container: container).path + "/"), url.path)
        try Data("zip".utf8).write(to: url)
        AppTemp.remove(container: container)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "mit dem Container geloescht")
    }

    // MARK: P2-1 Bibliothek mit Hunderten Dateien

    /// Lokales Backend mit `count` erfundenen, geladenen PDFs (alle "neu" wie nach dem ersten Abgleich); zaehlt die
    /// Vorschau-Anfragen (`/api/files/<id>/content`)
    final class LibraryTransport: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var contentRequests = 0
        private var libraryRequests = 0
        let library: Data
        let pdf: Data

        init(count: Int, prefix: String) {
            let files: [JSONValue] = (0..<count).map { i in
                ["id": .string("\(prefix)-\(i)"), "title": .string("Übungsblatt \(i)"), "name": .string("Blatt \(i).pdf"), "kind": "pdf",
                 "doc_type": "uebung", "status": "neu", "downloaded_at": "2026-11-01T10:00:00", "chdate": .number(Double(1_790_000_000 + i)),
                 "course_id": "k1", "subject": "Testanalysis", "seen_by_user": 0]
            }
            let lib: JSONValue = ["files": .array(files), "folders": [], "modules": [], "trash": []]
            library = lib.serialized()
            pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in ctx.beginPage() }
        }

        var thumbnails: Int { lock.withLock { contentRequests } }
        var libraryLoaded: Bool { lock.withLock { libraryRequests > 0 } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            func reply(_ data: Data, _ type: String = "application/json") -> (Data, HTTPURLResponse) {
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!)
            }
            switch path {
            case "/api/library":
                lock.withLock { libraryRequests += 1 }
                return reply(library)
            case "/api/courses": return reply(Data("[]".utf8))
            case "/api/older-semesters": return reply(Data(#"{"semesters":[]}"#.utf8))
            default:
                if path.hasSuffix("/content") {
                    lock.withLock { contentRequests += 1 }
                    return reply(pdf, "application/pdf")
                }
                return (Data(#"{"detail":"Not Found"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    /// Bereich "Neu" mit 500 Dateien (erster Abgleich), als Kacheln und als Liste: es laden nur die Vorschauen der
    /// sichtbaren (und gleich folgenden) Eintraege, nicht 500 (vorher `UFGridLayout`/`VStack`: jede Kachel startete
    /// sofort ihr `.task`, jede lud die ganze PDF und zeichnete Seite 1)
    func testLibraryWith500FilesLoadsOnlyVisibleThumbnails() throws {
        let saved = UserDefaults.standard.string(forKey: "lib-mode")
        defer { UserDefaults.standard.set(saved, forKey: "lib-mode") }
        for mode in ["grid", "list"] {
            UserDefaults.standard.set(mode, forKey: "lib-mode")
            let t = LibraryTransport(count: 500, prefix: "lazy-\(mode)-\(UUID().uuidString.prefix(8))")
            let api = APIClient(base: APIClient.localBase, transport: t)
            let hosted = try hostWithEnvironment(LibraryPage(section: "new", path: nil, q: nil), api: api)
            XCTAssertTrue(hosted.wait { t.libraryLoaded && t.thumbnails > 0 }, "\(mode): Seite geladen, erste Vorschauen")
            // bis sich nichts mehr tut (jede Vorschau eine Anfrage)
            var last = -1
            let end = Date().addingTimeInterval(8)
            while t.thumbnails != last && Date() < end { last = t.thumbnails; hosted.pump(0.7) }
            print("Bibliothek \(mode), 500 Dateien: \(t.thumbnails) Vorschauen geladen")
            XCTAssertGreaterThan(t.thumbnails, 0, mode)
            XCTAssertLessThanOrEqual(t.thumbnails, 120, "\(mode): nur sichtbare Eintraege laden ihre Vorschau, nicht alle 500")
            hosted.window.isHidden = true
        }
    }

    private struct CellFrames: PreferenceKey {
        static var defaultValue: [Int: CGRect] = [:]
        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { $1 } }
    }

    /// Die lazy Kacheln stehen genau wie mit dem bisherigen Raster (`UFGridLayout(spacing: 16, minWidth: 150)`): gleiche
    /// Spaltenzahl und -breite, gleiche Zeilenhoehe (hoechste Zelle), Zellen oben buendig, bei mehreren Breiten
    func testLazyGridPlacesTilesLikeTheOldGrid() throws {
        final class Box { var frames: [Int: CGRect] = [:] }
        func cell(_ i: Int) -> some View {
            VStack(spacing: 6.4) {
                Color.gray.frame(width: 112, height: 86)
                Text(i % 3 == 0 ? "Kachel \(i) mit langem Namen über zwei Zeilen" : "Kachel \(i)").lineLimit(2).frame(maxWidth: 150)
            }
            .frame(maxWidth: .infinity)
            .background(GeometryReader { g in Color.clear.preference(key: CellFrames.self, value: [i: g.frame(in: .named("raster"))]) })
        }
        for width in [700.0, 900.0, 1128.8] {
            var result: [[Int: CGRect]] = []
            for lazy in [false, true] {
                let box = Box()
                let grid = VStack(alignment: .leading, spacing: 0) {
                    if lazy {
                        LazyVGrid(columns: LibraryPage.gridColumns, alignment: .leading, spacing: 16) { ForEach(0..<14) { cell($0) } }
                    } else {
                        UFGridLayout(spacing: 16, minWidth: 150) { ForEach(0..<14) { cell($0) } }
                    }
                }
                .frame(width: width)
                .coordinateSpace(name: "raster")
                .onPreferenceChange(CellFrames.self) { box.frames = $0 }
                let hosted = try hostWithEnvironment(ScrollView { grid }, size: CGSize(width: 1180, height: 1400))
                XCTAssertTrue(hosted.wait { box.frames.count == 14 }, "\(lazy ? "lazy" : "alt") \(width): \(box.frames.count) Zellen")
                result.append(box.frames)
                hosted.window.isHidden = true
            }
            for i in 0..<14 {
                let a = try XCTUnwrap(result[0][i]), b = try XCTUnwrap(result[1][i])
                XCTAssertEqual(a.minX, b.minX, accuracy: 0.5, "Zelle \(i) bei \(width)")
                XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, "Zelle \(i) bei \(width)")
                XCTAssertEqual(a.width, b.width, accuracy: 0.5, "Zelle \(i) bei \(width)")
            }
        }
    }

    // MARK: P3-5 Lange Stud.IP-Texte

    /// Ein Text mit 50 000 Zeichen wird in Abschnitten gesetzt (keiner ueber dem Doppelten der Zielgroesse, getrennt nur
    /// an Zeilenenden, bevorzugt vor Leerzeilen); zusammengesetzt wieder genau der Text. Kurze Texte bleiben ein `Text`.
    func testLongTextIsSplitAtLineEndsOnly() {
        let short = "Einleitung.\n\nZweiter Absatz."
        XCTAssertEqual(UFLongText.chunks(short), [short])
        let paragraph = (1...40).map { "Satz \($0) des Absatzes über Eigenwerte." }.joined(separator: " ")
        let long = (1...40).map { "Absatz \($0)\n" + paragraph }.joined(separator: "\n\n")
        XCTAssertGreaterThan(long.count, 50_000)
        let parts = UFLongText.chunks(long)
        XCTAssertGreaterThan(parts.count, 10)
        XCTAssertEqual(parts.joined(separator: "\n"), long, "nichts verloren, nichts dazu")
        XCTAssertTrue(parts.allSatisfy { $0.count <= 2 * UFLongText.chunkTarget + paragraph.count + 20 }, "\(parts.map(\.count))")
        XCTAssertTrue(parts.dropFirst().allSatisfy { $0.hasPrefix("\nAbsatz") }, "Trennung vor einer Leerzeile")
        // ein Absatz ohne Leerzeilen: Trennung an Zeilenenden
        let lines = (1...3000).map { "Zeile \($0) mit Text" }.joined(separator: "\n")
        let lineParts = UFLongText.chunks(lines)
        XCTAssertGreaterThan(lineParts.count, 5)
        XCTAssertEqual(lineParts.joined(separator: "\n"), lines)
        XCTAssertTrue(lineParts.allSatisfy { $0.count <= 2 * UFLongText.chunkTarget + 30 })
    }

    /// Leser einer Anzeige mit 50 000 Zeichen: der Anfang steht sofort in Abschnitten in den Bedienungshilfen, in der
    /// Reihenfolge des Texts, ohne "…"; weiter unten liegende Abschnitte entstehen erst beim Scrollen (LazyVStack)
    func testReaderShowsVeryLongTextInParagraphsInOrder() throws {
        let paragraph = (1...40).map { "Satz \($0) der Anzeige." }.joined(separator: " ")
        let text = (1...70).map { "Abschnitt \($0)\n" + paragraph }.joined(separator: "\n\n")
        XCTAssertGreaterThan(text.count, 50_000)
        let parts = UFLongText.chunks(text)
        final class One: APITransport, @unchecked Sendable {
            let body: Data
            init(_ text: String) { body = (["id": "sb-lang", "title": "Lange Anzeige", "topic": "Wohnliches", "text": .string(text)] as JSONValue).serialized() }
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
        }
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let hosted = try hostWithEnvironment(BulletinReader(id: "sb-lang").frame(width: 640),
                                             api: APIClient(base: APIClient.localBase, transport: One(text)), size: CGSize(width: 700, height: 900))
        var labels: [String] = []
        XCTAssertTrue(hosted.wait { labels = hosted.labels(); return labels.contains(parts[0]) }, "erster Abschnitt: \(labels.prefix(5))")
        let shown = labels.filter { l in parts.contains(l) }
        XCTAssertEqual(shown, Array(parts.prefix(shown.count)), "Abschnitte in der Reihenfolge des Texts")
        XCTAssertLessThan(shown.count, parts.count, "spaetere Abschnitte erst beim Scrollen")
        XCTAssertFalse(labels.contains { $0.contains("…") })
        XCTAssertFalse(labels.contains(text), "nicht mehr ein einziger Text")
    }

    // MARK: P3-3 Mehrere Fenster

    /// Jedes Fenster hat eigene Navigation, Seitenleiste, Meldungen und Dialoge (`SceneObjects`); die App kennt alle
    /// offenen Fenster und das zuletzt aktive (`SceneRegistry`) fuer app-weite Fragen und das Neuladen
    func testEachWindowHasItsOwnNavigationToastsAndDialogs() throws {
        final class Seen {
            var objects: [(router: UFRouter, shell: ShellState, toast: UFToastCenter, overlay: UFOverlay)] = []
        }
        let registry = SceneRegistry()
        let seen = Seen()
        func window() throws -> HostedEnvironment {
            try hostWithEnvironment(SceneObjects(scenes: registry) { router, shell, toast, overlay in
                Color.clear.onAppear { seen.objects.append((router, shell, toast, overlay)) }
            }, size: CGSize(width: 600, height: 400))
        }
        let first = try window()
        XCTAssertTrue(first.wait { seen.objects.count == 1 })
        let second = try window()
        XCTAssertTrue(second.wait { seen.objects.count == 2 })
        let a = seen.objects[0], b = seen.objects[1]
        XCTAssertFalse(a.router === b.router)
        XCTAssertFalse(a.shell === b.shell)
        XCTAssertFalse(a.toast === b.toast)
        XCTAssertFalse(a.overlay === b.overlay)
        XCTAssertEqual(registry.routers.count, 2)
        XCTAssertNotNil(registry.active)

        a.router.go(.files())
        XCTAssertEqual(a.router.route, .files())
        XCTAssertEqual(b.router.route, .dashboard, "das andere Fenster bleibt, wo es ist")
        a.toast.show("Nur hier")
        XCTAssertEqual(a.toast.message, "Nur hier")
        XCTAssertNil(b.toast.message)

        registry.activate(router: b.router, overlay: b.overlay)
        XCTAssertTrue(registry.active?.router === b.router)
        XCTAssertTrue(registry.active?.overlay === b.overlay)
        registry.activate(router: a.router, overlay: a.overlay)
        XCTAssertTrue(registry.active?.router === a.router, "das zuletzt aktive Fenster bekommt app-weite Fragen")
        XCTAssertEqual(registry.routers.count, 2, "kein Fenster doppelt")
        XCTAssertTrue(registry.claimLaunchSetup())
        XCTAssertFalse(registry.claimLaunchSetup(), "Startparameter nur fuer das erste Fenster")
    }
}
