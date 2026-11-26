import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Regel des Inhabers (26.11.2026): "Lösungen, die man ansehen will, werden IMMER neben seinem eigenen Dokument
/// geöffnet, und Hintergrund original, Schrift original, alles 1 zu 1 – man soll immer den richtigen Hintergrund der PDF
/// oder des Blattes sehen."
/// - Seite der Community -> Person, breit (iPad, Mac), eigenes Dokument vorhanden: oben "Lösung neben deinem Dokument
///   öffnen"; der Tipp fuehrt ins eigene Dokument, die Spalte daneben zeigt genau diese Loesung auf der eigenen PDF.
///   Kommentare, "Gefällt mir" und "Mehr" bleiben im Leser.
/// - Eigenes Dokument fehlt: Leser und Hinweis wie bisher, kein Knopf. Steht die PDF im eigenen Kurs und ist nur noch
///   nicht geladen: "PDF jetzt laden".
/// - Schmal (iPhone): alles wie bisher.
/// - Laesst sich eine PDF-Seite nicht oeffnen, steht dort ein Hinweis – nie die Striche auf einer weissen Seite.
///   Eigene Blaetter des Absenders (liniert ...) erscheinen weiter auf ihrem Papier.
/// Nur erfundene Daten, kein Netz: Schein-Dienst mit einem Paket, Datei wie aus dem Abgleich in einer eigenen Datenbank.
@MainActor
final class LoesungImmerDanebenAppTests: XCTestCase {
    private static let course = SolutionVersionsAppTests.course, university = SolutionVersionsAppTests.university
    private var windows: [UIWindow] = []
    private var fileIDs: [String] = []

    override func setUp() {
        super.setUp()
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        HostedEnvironment.accessibilityAutomation(true)
        addTeardownBlock { @MainActor in
            Entitlements.shared.setPlanForTesting(before)
            HostedEnvironment.accessibilityAutomation(false)
        }
    }

    override func tearDown() {
        CommunityLocalContext.override = nil
        fileIDs.forEach { _ = SolutionBesideLaunch.shared.take(fileID: $0) }
        fileIDs = []
        windows.forEach { $0.isHidden = true }
        windows = []
        super.tearDown()
    }

    /// Asynchrones im Test abwarten, waehrend die Hauptschleife weiterlaeuft (gehostete Ansichten laden in `.task`;
    /// aus einem `async`-Test heraus liefe die Hauptschleife nicht weiter)
    @discardableResult
    private func run<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(90)
        while result == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return try XCTUnwrap(result, "Zeitlimit").get()
    }

    // MARK: Testdaten

    /// Schein-Dienst: das eine Paket, die eine Community, Kommentare moeglich (leer)
    private struct OnePackageService: CommunityService {
        let package: SolutionPackage
        var isConnected: Bool { true }
        var supportsDiscussion: Bool { true }
        func communities() async throws -> [CommunitySpace] {
            [CommunitySpace(key: String(repeating: "9", count: 64), kind: .course, name: "Analysis", joined: true, secret: SolutionVersionsAppTests.secret)]
        }
        func comments(solutionID: String) async throws -> [CommunityComment] { [] }
        func publish(_ package: SolutionPackage, options: CommunityPublishOptions) async throws -> CommunityPublication { throw CommunityServiceError.notConnected }
        func findMatching(fingerprint: String) async throws -> [CommunitySolutionSummary] { [] }
        func download(solutionID: String) async throws -> SolutionPackage { package }
        func withdraw(solutionID: String) async throws {}
        func report(solutionID: String, reason: CommunityReportReason, note: String?) async throws {}
    }

    /// Wie die PDF beim Betrachter steht
    private enum Own {
        /// aus dem Abgleich geladen (dieselbe PDF wie beim Absender)
        case loaded
        /// im Kurs gelistet, aber noch nicht auf dem Geraet
        case listed
        /// die App kennt die Datei nicht
        case unknown
    }

    private struct Fixture {
        let root: URL
        let host: LocalBackendHost
        let api: APIClient
        let fileID: String
        let file: LibFile
        let package: SolutionPackage
        let summary: CommunitySolutionSummary
        var service: OnePackageService { OnePackageService(package: package) }
    }

    /// Konto des Betrachters mit eigener Datenbank; Loesung des Absenders zu Fassung 1 (zwei PDF-Seiten mit Strichen und
    /// ein liniertes Blatt), versiegelt mit dem Schluessel der Community wie beim Dienst
    private func fixture(_ own: Own) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("immer-daneben-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("StudIP", isDirectory: true), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-26T10:00:00")!,
                                    files: LocalFiles(container: root, dataDirectory: ""))
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "0123456789abcdef0123456789abcd" + String(UUID().uuidString.prefix(2)).lowercased()
        fileIDs.append(fileID)
        let pdf = SolutionVersionsAppTests.v1Data, sha = SolutionSHA256.hex(pdf)
        let url = "https://studip.example/jsonapi.php/v1/file-refs/\(fileID)/content"
        let course = Self.course
        try run { try await host.backend().context.database.withConnection { c in
            try c.execute("INSERT INTO courses(id, title, semester) VALUES (?, 'Analysis I', 'WiSe 26/27')", [.text(course)])
            switch own {
            case .loaded:
                try pdf.write(to: root.appendingPathComponent("StudIP/blatt3.pdf"))
                try c.execute("""
                    INSERT INTO files(id, course_id, name, mime, status, download_url, local_path, downloaded_at, content_sha256)
                    VALUES (?, ?, 'Blatt3.pdf', 'application/pdf', 'neu', ?, 'StudIP/blatt3.pdf', '2026-11-26T09:00:00', ?)
                    """, [.text(fileID), .text(course), .text(url), .text(sha)])
            case .listed:
                try c.execute("INSERT INTO files(id, course_id, name, mime, status, download_url) VALUES (?, ?, 'Blatt3.pdf', 'application/pdf', 'neu', ?)",
                              [.text(fileID), .text(course), .text(url)])
            case .unknown: break
            }
        } }
        CommunityLocalContext.override = CommunityLocalContext(host: host, university: Self.university, spaces: {
            [CommunitySpace(key: String(repeating: "9", count: 64), kind: .course, name: "Analysis", joined: true, secret: SolutionVersionsAppTests.secret)]
        })
        let file = LibFile(id: fileID, name: "Blatt3.pdf", title: "Blatt 3", kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: own == .loaded ? "2026-11-26T09:00:00" : nil, has_notes: nil,
                           page_count: nil, studip_folder: nil)
        let content = SolutionVersionsAppTests.solution(versionPages: nil, fingerprint: sha, id: UUID().uuidString.lowercased())
        let package = try SolutionPackage.seal(content, communitySecret: SolutionVersionsAppTests.secret, cipher: SolutionSharing.cipher)
        var summary = CommunitySolutionSummary(solutionID: content.solutionID, fingerprint: sha, displayName: "Mira", createdAt: content.createdAt,
                                               pageCount: content.pages.count, title: "Blatt 3", week: 3, ownerRecordName: "owner-mira", isOwn: false)
        summary.family = CommunityKeys.familyKey(university: Self.university, courseID: Self.course, fileID: fileID)
        return Fixture(root: root, host: host, api: api, fileID: fileID, file: file, package: package, summary: summary)
    }

    /// Leser einer Person wie auf der Seite der Community (ganze Seite, breit); `left` zaehlt, wie oft er verlassen wurde
    private func reader(_ f: Fixture, compact: Bool = false, left: @escaping () -> Void = {}) throws -> HostedEnvironment {
        let view = NavigationStack {
            CommunityPeopleReader(title: "Blatt 3", people: [f.summary], start: 0, service: f.service, wide: true,
                                  localFile: { _ in nil }, leave: left, removed: { _, _ in })
        }
        .environment(\.ufLearnCompact, compact)
        return try hostWithEnvironment(view, api: f.api)
    }

    private func find(_ id: String, in v: UIView) -> UIView? {
        if v.accessibilityIdentifier == id { return v }
        for s in v.subviews { if let f = find(id, in: s) { return f } }
        return nil
    }

    /// Spalte "Lösung daneben" in einer gehosteten Ansicht (ueber ihre PDFView)
    private func sideController(in root: UIView) -> SolutionSideController? {
        var r: UIResponder? = find("solution.side.pdf", in: root)
        while let n = r {
            if let c = n as? SolutionSideController { return c }
            r = n.next
        }
        return nil
    }

    private func shows(_ env: HostedEnvironment, _ text: String) -> Bool { env.labels().contains { $0.contains(text) } }

    private func hasButton(_ env: HostedEnvironment, _ label: String) -> Bool { env.accessibleButton { $0.accessibilityLabel == label } != nil }

    // MARK: A – Seite der Community, eigenes Dokument vorhanden

    func testPersonsSolutionOpensBesideTheOwnDocument() throws {
        let f = try fixture(.loaded)
        var left = 0
        let env = try reader(f) { left += 1 }
        XCTAssertTrue(env.wait(timeout: 15) { self.hasButton(env, SolutionOverlay.openBeside) }, "Knopf oben im Leser: \(env.labels())")
        XCTAssertTrue(shows(env, CommunityTexts.ownPDFNotice), "\(env.labels())")
        // der Leser bleibt, weil nur er das hat: Kommentare, "Gefällt mir", "Mehr" (Melden, Blockieren)
        XCTAssertTrue(hasButton(env, "Kommentar"), "\(env.labels())")
        XCTAssertTrue(hasButton(env, "Gefällt mir · 0"), "\(env.labels())")
        XCTAssertTrue(shows(env, "Mehr"))
        XCTAssertFalse(hasButton(env, CommunityTexts.loadPDFNow), "die PDF ist schon da")
        XCTAssertNil(SolutionBesideLaunch.shared.pending[f.fileID], "nichts oeffnet sich von selbst")

        // Tipp: Bitte hinterlegt, Leser verlassen, eigenes Dokument geoeffnet
        XCTAssertTrue(env.activate(SolutionOverlay.openBeside))
        XCTAssertEqual(SolutionBesideLaunch.shared.pending[f.fileID], f.summary.solutionID)
        XCTAssertEqual(left, 1, "Leser verlassen")
        XCTAssertEqual(env.router.route, .doc(f.fileID, task: nil, page: nil))

        // Die Loesung liegt schon beim Dokument (derselbe Weg wie "Laden", `importFromCommunity`; der Dienst der App
        // laesst sich im Test nicht austauschen, das Laden selbst prueft `SolutionVersionsAppTests`)
        let imported: SolutionImportResult = try run {
            let store = DocumentStore(file: f.file, api: f.api)
            await store.load()
            XCTAssertNil(store.errorMessage)
            let result = try await store.importFromCommunity(f.summary.solutionID, service: f.service)
            await store.close()
            return result
        }
        guard case .shown(let entry) = imported else { return XCTFail("Loesung nicht angenommen: \(imported)") }
        addTeardownBlock { @MainActor in try? SolutionSharing.library.remove(entry.solutionID) }

        // das Dokument holt die Bitte ab: Spalte daneben mit genau dieser Loesung, auf der eigenen PDF-Seite
        let doc = try hostWithEnvironment(NavigationStack { DocumentView(file: f.file, api: f.api) }, api: f.api)
        let start = Date()
        XCTAssertTrue(doc.wait(timeout: 60) { self.sideController(in: doc.window) != nil }, "Spalte daneben offen: \(doc.labels())")
        print("MESSUNG Spalte daneben offen nach \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        let side = try XCTUnwrap(sideController(in: doc.window))
        XCTAssertEqual(side.layer.id.lowercased(), f.summary.solutionID.lowercased(), "genau die gewaehlte Loesung")
        XCTAssertNil(SolutionBesideLaunch.shared.pending[f.fileID], "Bitte abgeholt")
        XCTAssertTrue(doc.wait { self.shows(doc, "nur ansehen") }, "\(doc.labels())")
        let first = try XCTUnwrap(side.pdfView.document?.page(at: 0))
        XCTAssertNotNil(first.pageRef, "Hintergrund ist die eigene PDF-Seite")
        XCTAssertTrue((first.string ?? "").contains("Aufgabe 1"), "Seite 1 der eigenen PDF: \(first.string ?? "")")
        let overlay = try XCTUnwrap(side.pdfView(side.pdfView, overlayViewFor: first) as? PageInkView)
        XCTAssertEqual(overlay.foreignInk?.drawing.strokes.count, 1, "Schrift des Absenders in der Spalte")
        XCTAssertNil(find("solution.side.needsPDF", in: overlay))
    }

    // MARK: A – eigenes Dokument fehlt, E – schmal wie bisher

    func testWithoutOwnDocumentTheReaderStaysAsBefore() throws {
        let f = try fixture(.unknown)
        let env = try reader(f)
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, CommunityTexts.noPDFNotice) }, "Hinweis wie bisher: \(env.labels())")
        XCTAssertTrue(shows(env, CommunityTexts.pageNeedsPDF), "PDF-Seiten als Hinweis, nie Striche auf Weiss")
        XCTAssertFalse(hasButton(env, SolutionOverlay.openBeside), "\(env.labels())")
        XCTAssertFalse(hasButton(env, CommunityTexts.loadPDFNow), "die App kennt die Datei nicht: kein Knopf")
        XCTAssertTrue(hasButton(env, "Kommentar"))
        XCTAssertNil(SolutionBesideLaunch.shared.pending[f.fileID])
        XCTAssertEqual(env.router.route, .dashboard, "nichts oeffnet sich")
    }

    func testCompactLayoutIsUnchanged() throws {
        XCTAssertTrue(CommunityPersonPane.offersBeside(compact: false, editor: true))
        XCTAssertFalse(CommunityPersonPane.offersBeside(compact: true, editor: true), "schmal: wie bisher")
        XCTAssertFalse(CommunityPersonPane.offersBeside(compact: false, editor: false), "ohne Editor (iPhone): wie bisher")

        // eigenes Dokument vorhanden, aber schmal: kein Knopf, die Seiten wie bisher
        let f = try fixture(.loaded)
        let env = try reader(f, compact: true)
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, "Seite mit 1 Notizobjekten") }, "Seiten wie bisher: \(env.labels())")
        XCTAssertFalse(hasButton(env, SolutionOverlay.openBeside), "\(env.labels())")
        XCTAssertFalse(shows(env, CommunityTexts.ownPDFNotice))

        // PDF nur gelistet, schmal: Hinweis wie bisher, kein "PDF jetzt laden"
        let g = try fixture(.listed)
        let narrow = try reader(g, compact: true)
        XCTAssertTrue(narrow.wait(timeout: 15) { self.shows(narrow, CommunityTexts.noPDFNotice) }, "\(narrow.labels())")
        XCTAssertFalse(hasButton(narrow, CommunityTexts.loadPDFNow), "\(narrow.labels())")
    }

    // MARK: F – PDF bekannt, aber noch nicht geladen

    func testKnownButUnloadedPDFOffersLoadNow() throws {
        let f = try fixture(.listed)
        let university = Self.university
        let known = try run { await CommunityCourses.knownUnloadedFile(family: f.summary.family, host: f.host, university: university) }
        XCTAssertEqual(known, f.fileID, "im Kurs gelistet, nicht geladen")
        let other = try run { await CommunityCourses.knownUnloadedFile(family: String(repeating: "a", count: 64), host: f.host, university: university) }
        XCTAssertNil(other, "andere Datei-Familie")
        let none = try run { await CommunityCourses.knownUnloadedFile(family: nil, host: f.host, university: university) }
        XCTAssertNil(none, "Loesung ohne Datei-Familie")

        var left = 0
        let env = try reader(f) { left += 1 }
        XCTAssertTrue(env.wait(timeout: 15) { self.hasButton(env, CommunityTexts.loadPDFNow) }, "\(env.labels())")
        XCTAssertTrue(shows(env, CommunityTexts.noPDFNotice), "neben dem vorhandenen Hinweis")
        XCTAssertFalse(hasButton(env, SolutionOverlay.openBeside))
        XCTAssertNil(SolutionBesideLaunch.shared.pending[f.fileID], "geladen wird erst nach dem Tipp")
        // Tipp: die Datei oeffnet sich (dort laedt sie `FileLoadPanel`), die Loesung wartet auf das Dokument
        XCTAssertTrue(env.activate(CommunityTexts.loadPDFNow))
        XCTAssertEqual(SolutionBesideLaunch.shared.pending[f.fileID], f.summary.solutionID)
        XCTAssertEqual(env.router.route, .doc(f.fileID, task: nil, page: nil))
        XCTAssertEqual(left, 1)

        // schon geladen: keine "nicht geladene" Datei mehr
        let loaded = try fixture(.loaded)
        let present = try run { await CommunityCourses.knownUnloadedFile(family: loaded.summary.family, host: loaded.host, university: university) }
        XCTAssertNil(present)
    }

    // MARK: C – nie Striche auf einer weissen Seite

    func testNoStrokesOnAWhitePageWhenThePDFPageIsUnavailable() async throws {
        let onPDF = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0,
                                 objects: [SolutionVersionsAppTests.stroke("s1", y: 300)])
        let lined = SolutionPage(key: "b1", kind: .blank, pdfIndex: nil, width: 595, height: 842, rotation: 0, template: "lined",
                                 objects: [SolutionVersionsAppTests.stroke("s2", y: 200)])
        let layer = ForeignSolutionLayer(id: "l1", displayName: "Mira", createdAt: "2026-11-26T10:00:00Z", visible: true,
                                         pages: [onPDF, lined], images: [:], missingImages: 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("immer-daneben-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("fehlt.pdf")
        let real = dir.appendingPathComponent("blatt.pdf")
        try SolutionVersionsAppTests.v1Data.write(to: real)

        // Spalte daneben, die PDF laesst sich nicht oeffnen: Hinweis statt Strichen; das linierte Blatt wie bisher
        let c = SolutionSideController(layer: layer, pdfURL: missing)
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 520, height: 900))
        w.rootViewController = c
        w.isHidden = false
        windows.append(w)
        c.view.layoutIfNeeded()
        let p0 = try XCTUnwrap(c.pdfView.document?.page(at: 0)), p1 = try XCTUnwrap(c.pdfView.document?.page(at: 1))
        XCTAssertTrue(SolutionSideController.missingPDFPage(onPDF, page: p0))
        XCTAssertFalse(SolutionSideController.missingPDFPage(lined, page: p1), "eigenes Blatt braucht keine PDF")
        let o0 = try XCTUnwrap(c.pdfView(c.pdfView, overlayViewFor: p0) as? PageInkView)
        let notice = try XCTUnwrap(find("solution.side.needsPDF", in: o0), "Hinweis an Stelle der Seite")
        XCTAssertEqual(notice.accessibilityLabel, CommunityTexts.pageNotShown)
        XCTAssertTrue(o0.foreignLayerViews.isEmpty, "keine fremde Ebene")
        XCTAssertNil(o0.foreignInk, "keine Striche auf der weissen Seite")
        let o1 = try XCTUnwrap(c.pdfView(c.pdfView, overlayViewFor: p1) as? PageInkView)
        XCTAssertNil(find("solution.side.needsPDF", in: o1))
        XCTAssertEqual(o1.foreignInk?.drawing.strokes.count, 1, "Schrift auf dem Blatt wie bisher")
        XCTAssertFalse(o1.objectsView.isHidden, "Papier des Blatts")
        XCTAssertGreaterThan(o1.objectsView.layer.sublayers?.count ?? 0, 0, "Linien gezeichnet")

        // mit der PDF: Seite und Striche wie bisher
        let ok = SolutionSideController.page(onPDF, pdf: PDFDocument(url: real))
        XCTAssertFalse(SolutionSideController.missingPDFPage(onPDF, page: ok))
        let withPDF = SolutionSideController.overlay(for: onPDF, page: ok, index: 0, layer: layer)
        XCTAssertNil(find("solution.side.needsPDF", in: withPDF))
        XCTAssertEqual(withPDF.foreignLayerViews.count, 1)
        // Seite der aufbewahrten alten Fassung, die sich nicht oeffnen laesst: derselbe Satz wie ohne diese Fassung
        var other = layer
        other.placements = ["p1": .oldVersion(1)]
        let old = SolutionSideController.page(onPDF, pdf: PDFDocument(url: real), old: nil, placement: .oldVersion(1))
        let changed = SolutionSideController.overlay(for: onPDF, page: old, index: 0, layer: other)
        XCTAssertNotNil(find("solution.side.changed", in: changed))
        XCTAssertTrue(changed.foreignLayerViews.isEmpty)

        // Bild im Leser der Community: ohne PDF-Seite kein Bild (der Leser zeigt den Hinweis), Blatt auf seinem Papier
        let gone = await OffscreenPDF(url: missing).solutionPreview(onPDF, images: [:], width: 300, scale: 1)
        XCTAssertNil(gone, "Datei fehlt: kein Bild mit Strichen auf Weiss")
        let beyond = SolutionPage(key: "p9", kind: .pdf, pdfIndex: 9, width: 595, height: 842, rotation: 0, objects: onPDF.objects)
        let noPage = await OffscreenPDF(url: real).solutionPreview(beyond, images: [:], width: 300, scale: 1)
        XCTAssertNil(noPage, "Seite gibt es nicht: kein Bild")
        let drawn = await OffscreenPDF(url: real).solutionPreview(onPDF, images: [:], width: 300, scale: 1)
        XCTAssertNotNil(drawn, "mit der PDF-Seite wie bisher")
        let paper = await OffscreenPDF(url: missing).solutionPreview(lined, images: [:], width: 300, scale: 1)
        let sheet = try XCTUnwrap(paper, "eigenes Blatt auch ohne PDF")
        XCTAssertEqual(sheet.pngData(), SolutionPreview.image(lined, images: [:], width: 300, scale: 1).pngData(), "Blatt genau wie bisher")
        XCTAssertFalse(CommunityTexts.pageNotShown.isEmpty)
    }

    // MARK: D – Meldung nach dem Empfang einer Loesungsdatei

    func testReceivedMessageSaysBesideTheDocument() {
        let text = SolutionSharing.receivedMessage(label: "Lösung von Mira", canView: true)
        XCTAssertEqual(text, "Lösung von Mira gespeichert – öffne die passende PDF, dort öffnest du sie neben deinem Dokument.")
        XCTAssertFalse(text.contains("Ebenen"), "Loesungen liegen nicht mehr unter „Ebenen“ ueber der Seite")
        XCTAssertFalse(SolutionSharing.receivedMessage(label: "Lösung", canView: false).contains("neben"), "ohne Recht nichts versprechen")
    }
}
