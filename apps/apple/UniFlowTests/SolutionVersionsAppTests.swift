import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Loesungen fuer alle Fassungen einer PDF (Freigabe des Inhabers 23.11.2026), mit erfundenen PDFs:
/// Fassung 1 = [gleiche Seite, alte Aufgabe 2], Fassung 2 = [gleiche Seite, geaenderte Aufgabe 2, neue Seite 3].
/// - Eine Loesung zu Fassung 1 wird im Dokument mit Fassung 2 ueber die Datei-Familie geladen und neben dem Dokument
///   geoeffnet: die gleiche Seite steht 1:1 auf der eigenen Seite, die geaenderte zeigt den Satz – bzw. mit aufbewahrter
///   Fassung 1 (S7) die alte Seite mit den Strichen; nie Striche auf Weiss.
/// - Eine Loesung zur selben PDF (alte Clients, ohne Familie) laeuft wie bisher.
/// - Beim Teilen gehen die Seitenkennzeichen mit.
@MainActor
final class SolutionVersionsAppTests: XCTestCase {
    static let v1 = ["Übungsblatt 3 Aufgabe 1: Zeigen Sie, dass die Folge konvergiert. Seite 1 von 2",
                     "Aufgabe 2: Berechnen Sie das Integral von 0 bis 1. Seite 2 von 2"]
    static let v2 = ["Übungsblatt 3 Aufgabe 1: Zeigen Sie, dass die Folge konvergiert. Seite 1 von 3",
                     "Aufgabe 2: Berechnen Sie das Integral von 0 bis 2 und skizzieren Sie den Graphen. Seite 2 von 3",
                     "Aufgabe 3 (neu): Beweisen Sie die Ungleichung. Seite 3 von 3"]
    /// je Fassung EINE Datei (der Renderer schreibt Datum und Kennung in die PDF: neu erzeugt waere es ein anderer Fingerabdruck)
    static let v1Data = pdf(v1), v2Data = pdf(v2)
    static let course = "kurs-4711", university = "luh"
    static let secret = CommunityKeys.secret(university: "luh", moduleName: "Analysis")
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        CommunityLocalContext.override = nil
        windows.forEach { $0.isHidden = true }
        windows = []
    }

    // MARK: Testdaten

    /// PDF mit einer Textzeile je Seite (A4), Text fuer PDFKit lesbar
    static func pdf(_ texts: [String]) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for t in texts {
                ctx.beginPage()
                (t as NSString).draw(in: CGRect(x: 40, y: 60, width: 515, height: 400),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.black])
            }
        }
    }

    static func stroke(_ id: String, y: Double) -> JSONValue {
        let pts = stride(from: 80.0, through: 480.0, by: 20.0).flatMap { [JSONValue.number($0), .number(y)] }
        return .object(["type": "stroke", "id": .string(id), "tool": "pen", "color": "#1d4ed8", "width": 3, "points": .array(pts)])
    }

    /// Loesung des Absenders zu Fassung 1: Striche auf PDF-Seite 1 und 2, dazu ein eigenes liniertes Blatt
    static func solution(versionPages: [String]?, fingerprint: String, id: String = "6f1c1c0e-0000-4000-8000-0000000000a1") -> SolutionContent {
        SolutionContent(solutionID: id, createdAt: "2026-11-23T10:00:00Z", title: "Blatt 3", displayName: "Mira",
                        fingerprint: fingerprint, pdfPageCount: 2,
                        pages: [SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0, objects: [stroke("s1", y: 300)]),
                                SolutionPage(key: "p2", kind: .pdf, pdfIndex: 2, width: 595, height: 842, rotation: 0, objects: [stroke("s2", y: 500)]),
                                SolutionPage(key: "b1", kind: .blank, pdfIndex: nil, width: 595, height: 842, rotation: 0, template: "lined",
                                             objects: [stroke("s3", y: 200)])],
                        versionPages: versionPages)
    }

    /// Schein-Dienst: liefert das eine Paket und die eine Community
    private struct OnePackageService: CommunityService {
        let package: SolutionPackage
        var isConnected: Bool { true }
        func communities() async throws -> [CommunitySpace] {
            [CommunitySpace(key: String(repeating: "9", count: 64), kind: .course, name: "Analysis", joined: true, secret: SolutionVersionsAppTests.secret)]
        }
        func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication { throw CommunityServiceError.notConnected }
        func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary] { [] }
        func download(solutionID: String) async throws -> SolutionPackage { package }
        func withdraw(solutionID: String) async throws {}
        func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws {}
    }

    private struct Fixture {
        let root: URL
        let host: LocalBackendHost
        let api: APIClient
        let library: SolutionLibrary
        let fileID: String
        let file: LibFile
    }

    /// Konto des Betrachters: Datei aus dem Stud.IP-Abgleich (Kurs `course`) mit `current` als aktueller Fassung,
    /// optional die aufbewahrte Fassung `kept` (S7, Tabelle `file_versions`)
    private func fixture(current: Data, kept: Data? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fassungen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("StudIP/Fassungen", isDirectory: true), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-23T10:00:00")!,
                                    files: LocalFiles(container: root, dataDirectory: ""))
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "0123456789abcdef0123456789abcd" + String(UUID().uuidString.prefix(2)).lowercased()
        try current.write(to: root.appendingPathComponent("StudIP/blatt3.pdf"))
        if let kept { try kept.write(to: root.appendingPathComponent("StudIP/Fassungen/blatt3-v1.pdf")) }
        let sha = SolutionSHA256.hex(current), keptSHA = kept.map(SolutionSHA256.hex)
        try await host.backend().context.database.withConnection { c in
            try c.execute("INSERT INTO courses(id, title, semester) VALUES (?, 'Analysis I', 'WiSe 26/27')", [.text(Self.course)])
            try c.execute("""
                INSERT INTO files(id, course_id, name, mime, status, download_url, local_path, downloaded_at, content_sha256)
                VALUES (?, ?, 'Blatt3.pdf', 'application/pdf', 'neu', ?, 'StudIP/blatt3.pdf', '2026-11-23T09:00:00', ?)
                """, [.text(fileID), .text(Self.course), .text("https://studip.example/jsonapi.php/v1/file-refs/\(fileID)/content"), .text(sha)])
            if let keptSHA {
                try c.execute("""
                    CREATE TABLE IF NOT EXISTS file_versions (file_id TEXT NOT NULL, version INTEGER NOT NULL, name TEXT, size INTEGER, mime TEXT,
                        chdate INTEGER, content_sha256 TEXT, local_path TEXT, page_count INTEGER, annotations TEXT, mapping TEXT, source TEXT,
                        replaced_at TEXT, seen INTEGER DEFAULT 0, PRIMARY KEY (file_id, version))
                    """)
                try c.execute("INSERT INTO file_versions(file_id, version, content_sha256, local_path, page_count, source) VALUES (?, 1, ?, 'StudIP/Fassungen/blatt3-v1.pdf', 2, 'Stud.IP')",
                              [.text(fileID), .text(keptSHA)])
            }
        }
        CommunityLocalContext.override = CommunityLocalContext(host: host, university: Self.university, spaces: {
            [CommunitySpace(key: String(repeating: "9", count: 64), kind: .course, name: "Analysis", joined: true, secret: SolutionVersionsAppTests.secret)]
        })
        let file = LibFile(id: fileID, name: "Blatt3.pdf", title: "Blatt 3", kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: "2026-11-23T09:00:00", has_notes: nil, page_count: nil,
                           studip_folder: nil)
        return Fixture(root: root, host: host, api: api, library: SolutionLibrary(root: root.appendingPathComponent("solutions", isDirectory: true)),
                       fileID: fileID, file: file)
    }

    private func store(_ f: Fixture) async throws -> DocumentStore {
        let s = DocumentStore(file: f.file, api: f.api, root: f.root.appendingPathComponent("cache", isDirectory: true))
        await s.load()
        XCTAssertNil(s.errorMessage)
        XCTAssertNotNil(s.originalPDF)
        return s
    }

    /// Paket des Absenders (mit dem Schluessel der Community versiegelt, wie es beim Dienst liegt)
    private func authorPackage(versionPages: Bool = true) async throws -> SolutionPackage {
        let v1 = Self.v1Data
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absender-\(UUID().uuidString).pdf")
        try v1.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let read = await SolutionPDFFacts.read(url)
        let facts = try XCTUnwrap(read)
        XCTAssertEqual(facts.pageCount, 2)
        let c = Self.solution(versionPages: versionPages ? facts.keys : nil, fingerprint: SolutionSHA256.hex(v1))
        return try SolutionPackage.seal(c, communitySecret: Self.secret, cipher: SolutionSharing.cipher)
    }

    /// Spalte daneben in einem Fenster; Seiten und Overlays wie PDFKit sie zeigt
    private func side(_ layer: ForeignSolutionLayer, pdfURL: URL) -> SolutionSideController {
        let c = SolutionSideController(layer: layer, pdfURL: pdfURL)
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 520, height: 900))
        w.rootViewController = c
        w.isHidden = false
        windows.append(w)
        c.view.layoutIfNeeded()
        return c
    }

    private func overlay(_ c: SolutionSideController, _ i: Int) throws -> PageInkView {
        let page = try XCTUnwrap(c.pdfView.document?.page(at: i))
        return try XCTUnwrap(c.pdfView(c.pdfView, overlayViewFor: page) as? PageInkView)
    }

    private func find(_ id: String, in v: UIView) -> UIView? {
        if v.accessibilityIdentifier == id { return v }
        for s in v.subviews { if let f = find(id, in: s) { return f } }
        return nil
    }

    private func text(_ c: SolutionSideController, _ i: Int) -> String {
        (c.pdfView.document?.page(at: i)?.string ?? "").replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Tests

    func testSolutionToVersion1IsShownBesideVersion2SamePageOnOwnPageChangedPageAsSentence() async throws {
        let f = try await fixture(current: Self.v2Data)
        let s = try await store(f)
        let family = CommunityKeys.familyKey(university: Self.university, courseID: Self.course, fileID: f.fileID)
        let familyOfStore = await s.communityFamily()
        XCTAssertEqual(familyOfStore, family, "Familie aus Kurs-ID und Datei-ID des Abgleichs")
        let pkg = try await authorPackage()
        await s.addText("Meine eigene Notiz", pageKey: "p1")
        await s.flush()
        let before = (await s.pageStructureDocument()).root.serialized(sortedKeys: true)

        // "Lösung neben deinem Dokument öffnen" laedt ueber denselben Weg wie bisher
        guard case .shown(let entry) = try await s.importFromCommunity(pkg.header.solutionID, service: OnePackageService(package: pkg), library: f.library) else {
            return XCTFail("Loesung zu Fassung 1 nicht angenommen")
        }
        XCTAssertEqual(entry.family, family)
        XCTAssertEqual(entry.fingerprint, pkg.header.fingerprint, "abgelegt unter ihrem eigenen Fingerabdruck")
        let load = await s.solutionLayers(library: f.library)
        XCTAssertEqual(load.problems.map(\.message), [])
        let layer = try XCTUnwrap(load.layers.first)
        XCTAssertTrue(layer.otherVersion)
        XCTAssertEqual(layer.placements, ["p1": .own(1), "p2": .changed])
        XCTAssertEqual(Array(layer.byPDFIndex.keys), [1], "ueber der eigenen Seite (Korrektur) nur die gleiche Seite")

        let c = side(layer, pdfURL: s.originalPDFURL)
        XCTAssertEqual(c.pdfView.document?.pageCount, 3)
        // 1: gleiche Seite auf der eigenen PDF-Seite 1 (Fassung 2), mit den Strichen 1:1
        XCTAssertTrue(text(c, 0).contains("Folge konvergiert") && text(c, 0).contains("von 3"), text(c, 0))
        let o1 = try overlay(c, 0)
        XCTAssertEqual(o1.foreignInk?.drawing.strokes.count, 1)
        XCTAssertNil(find("solution.side.changed", in: o1))
        // 2: geaendert, Fassung 1 liegt nicht auf dem Geraet: nur der Satz, keine Striche, keine falsche Folie darunter
        XCTAssertEqual(text(c, 1).trimmingCharacters(in: .whitespaces), "", "keine Seite der eigenen Fassung unter fremden Notizen")
        let o2 = try overlay(c, 1)
        let notice = try XCTUnwrap(find("solution.side.changed", in: o2))
        XCTAssertEqual(notice.accessibilityLabel, "Diese Seite hat sich in deiner Fassung geändert")
        XCTAssertNil(o2.foreignInk, "nie nur Striche auf Weiss")
        XCTAssertEqual(o2.foreignView.subviews.count, 0)
        // 3: eigenes Blatt des Absenders auf seinem Papier
        XCTAssertEqual(try overlay(c, 2).foreignInk?.drawing.strokes.count, 1)
        XCTAssertEqual(SolutionSidePane.caption(layer, at: 0), "PDF-Seite 1 · gleich in deiner Fassung · 1 von 3")
        XCTAssertEqual(SolutionSidePane.caption(layer, at: 1), "PDF-Seite 2 · in deiner Fassung geändert · 2 von 3")

        // eigene Notizen unveraendert
        await s.flush()
        let after = (await s.pageStructureDocument()).root.serialized(sortedKeys: true)
        XCTAssertEqual(before, after)
        await s.close()
    }

    func testChangedPageStandsOnTheKeptOldVersionAsWritten() async throws {
        let f = try await fixture(current: Self.v2Data, kept: Self.v1Data)
        let s = try await store(f)
        let pkg = try await authorPackage()
        guard case .shown = try await s.importFromCommunity(pkg.header.solutionID, service: OnePackageService(package: pkg), library: f.library) else {
            return XCTFail("nicht angenommen")
        }
        let loaded = await s.solutionLayers(library: f.library)
        let layer = try XCTUnwrap(loaded.layers.first)
        XCTAssertEqual(layer.placements, ["p1": .own(1), "p2": .oldVersion(2)])
        XCTAssertNotNil(layer.oldVersionURL)
        let c = side(layer, pdfURL: s.originalPDFURL)
        XCTAssertTrue(text(c, 0).contains("von 3"), "Seite 1 aus der eigenen Fassung 2")
        XCTAssertTrue(text(c, 1).contains("von 0 bis 1"), "Seite 2 aus der aufbewahrten Fassung 1: \(text(c, 1))")
        let o2 = try overlay(c, 1)
        XCTAssertEqual(o2.foreignInk?.drawing.strokes.count, 1, "die Striche stehen auf der alten Seite, wie geschrieben")
        XCTAssertNil(find("solution.side.changed", in: o2))
        XCTAssertEqual(SolutionSidePane.caption(layer, at: 1), "PDF-Seite 2 · auf der alten Fassung · 2 von 3")
        await s.close()
    }

    func testOldSolutionWithoutKeysUsesTheKeptVersionOrShowsTheSentence() async throws {
        // Absender mit einer aelteren App: kein Seitenkennzeichen im Paket
        let pkg = try await authorPackage(versionPages: false)
        let f = try await fixture(current: Self.v2Data)
        let s = try await store(f)
        _ = try await s.importFromCommunity(pkg.header.solutionID, service: OnePackageService(package: pkg), library: f.library)
        let loaded = await s.solutionLayers(library: f.library)
        let layer = try XCTUnwrap(loaded.layers.first)
        XCTAssertEqual(layer.placements, ["p1": .changed, "p2": .changed], "ohne Kennzeichen gilt keine Seite als gleich")
        await s.close()
    }

    func testSamePDFStillOpensLikeBeforeAndWithoutFamily() async throws {
        // Fassung 1 auf dem Geraet (gleicher Fingerabdruck wie die Loesung): der bisherige Weg, an die eigene PDF gebunden
        let f = try await fixture(current: Self.v1Data)
        let s = try await store(f)
        let pkg = try await authorPackage()
        guard case .shown(let entry) = try await s.importFromCommunity(pkg.header.solutionID, service: OnePackageService(package: pkg), library: f.library) else {
            return XCTFail("nicht angenommen")
        }
        XCTAssertNil(entry.family, "an die eigene PDF gebunden wie bisher")
        XCTAssertFalse(try f.library.package(entry.solutionID).header.isCommunityPackage)
        let loaded = await s.solutionLayers(library: f.library)
        let layer = try XCTUnwrap(loaded.layers.first)
        XCTAssertFalse(layer.otherVersion)
        XCTAssertEqual(layer.placements, [:])
        let c = side(layer, pdfURL: s.originalPDFURL)
        XCTAssertTrue(text(c, 1).contains("von 0 bis 1"))
        XCTAssertEqual(try overlay(c, 1).foreignInk?.drawing.strokes.count, 1)
        await s.close()
    }

    func testReaderPlacesPagesTheSameWay() async throws {
        let f = try await fixture(current: Self.v2Data)
        let pkg = try await authorPackage()
        let content = try pkg.open(communitySecret: Self.secret, cipher: SolutionSharing.cipher)
        let family = CommunityKeys.familyKey(university: Self.university, courseID: Self.course, fileID: f.fileID)
        let found = await CommunityCourses.localFile(family: family, host: f.host, university: Self.university)
        XCTAssertEqual(found?.id, f.fileID, "eigene Datei derselben Familie")
        let view = await CommunityCourses.view(for: content, family: family, host: f.host, university: Self.university)
        XCTAssertTrue(view.isOtherVersion)
        XCTAssertNotNil(view.own)
        XCTAssertNil(view.old)
        XCTAssertEqual(view.fileID, f.fileID)
        XCTAssertEqual(view.placement(content.pages[0]), .own(1))
        XCTAssertEqual(view.placement(content.pages[1]), .changed)
        XCTAssertNil(view.placement(content.pages[2]))
        // ohne Familie (alter Eintrag, alter Dienst): keine eigene PDF, die Seiten verlangen die PDF wie bisher
        let none = await CommunityCourses.view(for: content, family: nil, host: f.host, university: Self.university)
        XCTAssertNil(none.own)
        XCTAssertNil(none.placement(content.pages[0]))
        XCTAssertTrue(CommunityReaderPage.needsPDF(content.pages[0], source: none.own))
        // Leser: Seite 1 als Bild auf der eigenen Seite, Seite 2 als Satz (kein Bild mit Strichen), eigenes Blatt auf Papier
        XCTAssertEqual(CommunityReaderPage.display(content.pages[0], source: view.own, placement: view.placement(content.pages[0]), old: view.old), .page)
        XCTAssertEqual(CommunityReaderPage.display(content.pages[1], source: view.own, placement: view.placement(content.pages[1]), old: view.old), .changed)
        XCTAssertEqual(CommunityReaderPage.display(content.pages[2], source: view.own, placement: view.placement(content.pages[2]), old: view.old), .page)
        XCTAssertEqual(CommunityReaderPage.display(content.pages[0], source: nil, placement: nil, old: nil), .needsPDF, "ohne PDF wie bisher")
        // mit aufbewahrter Fassung steht die geaenderte Seite als Bild auf der alten Seite
        let k = try await fixture(current: Self.v2Data, kept: Self.v1Data)
        let kept = await CommunityCourses.view(for: content, family: CommunityKeys.familyKey(university: Self.university, courseID: Self.course,
                                                                                              fileID: k.fileID), host: k.host, university: Self.university)
        XCTAssertEqual(kept.placement(content.pages[1]), .oldVersion(2))
        XCTAssertNotNil(kept.old)
        XCTAssertEqual(CommunityReaderPage.display(content.pages[1], source: kept.own, placement: kept.placement(content.pages[1]), old: kept.old), .page)
        let picture = await kept.old?.solutionPreview(content.pages[1], images: [:], width: 300, scale: 1, pdfIndex: 2)
        XCTAssertNotNil(picture)
        let oldPDF = try XCTUnwrap(kept.old)
        let drawn = await oldPDF.pdfPagesDrawn
        XCTAssertEqual(drawn, 1, "die alte PDF-Seite liegt unter den Strichen")
    }

    private func labels(in root: Any) -> [String] {
        var out: [String] = []
        func visit(_ e: Any, _ depth: Int) {
            guard depth < 60 else { return }
            if let o = e as? NSObject {
                if let l = o.accessibilityLabel, !l.isEmpty { out.append(l) }
                for x in o.accessibilityElements ?? [] { visit(x, depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let x = o.accessibilityElement(at: i) { visit(x, depth + 1) } } }
            }
            if let v = e as? UIView { for s in v.subviews { visit(s, depth + 1) } }
        }
        visit(root, 0)
        return out
    }

    func testSharingCarriesThePageKeysOfTheOwnPDF() async throws {
        let f = try await fixture(current: Self.v2Data)
        let s = try await store(f)
        s.canvasChanged(pageKey: "p1", drawing: PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .blue), path: PKStrokePath(
            controlPoints: (0..<10).map { PKStrokePoint(location: CGPoint(x: 100 + Double($0) * 20, y: 300), timeOffset: Double($0) * 0.01,
                                                        size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) },
            creationDate: Date()))]))
        await s.flush()
        let source = try await s.solutionSource(loadImage: nil)
        XCTAssertEqual(source.pageKeys?.count, 3)
        XCTAssertEqual(source.pageKeys?[0], SolutionVersions.pageKey(Self.v1[0]), "gleiche Seite, gleiches Kennzeichen")
        let content = try SolutionSharing.content(source, keys: ["p1"], displayName: "")
        XCTAssertEqual(content.versionPages, source.pageKeys)
        let sealed = try SolutionPackage.seal(content, communitySecret: Self.secret, cipher: SolutionSharing.cipher)
        XCTAssertEqual(try sealed.open(communitySecret: Self.secret, cipher: SolutionSharing.cipher).versionPages, source.pageKeys)
        await s.close()
    }
}
