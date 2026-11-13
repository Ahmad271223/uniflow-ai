import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Bilder fuer den Inhaber (13.11.2026): Nebenansicht mit mehreren Seiten, "Deine Blätter zu diesem Dokument",
/// Hinweis vor dem Drucken und eine fremde Loesung auf der eigenen PDF-Seite. Laeuft nur mit UF_SCREENSHOT_DIR
/// (sonst uebersprungen); prueft dabei auch, dass alles sichtbar ist.
@MainActor
final class NebenblattBilderAppTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        guard let d = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !d.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        dir = URL(fileURLWithPath: d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(before) }
        HostedEnvironment.accessibilityAutomation(true)
        addTeardownBlock { @MainActor in HostedEnvironment.accessibilityAutomation(false) }
    }

    // MARK: Daten

    private func folien(_ n: Int) -> Data {
        let raw = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 960, height: 540)
        let ctx = CGContext(consumer: CGDataConsumer(data: raw as CFMutableData)!, mediaBox: &box, nil)!
        for i in 0..<n {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(red: 0.93, green: 0.95, blue: 1, alpha: 1)
            ctx.fill(box)
            ctx.setFillColor(red: 0.2, green: 0.3, blue: 0.7, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 470, width: 960, height: 70))
            let title = NSAttributedString(string: "Übung \(i + 1): Eigenwerte", attributes: [.font: UIFont.boldSystemFont(ofSize: 34),
                                                                                          .foregroundColor: UIColor.white])
            let a = NSAttributedString(string: "Aufgabe: Bestimme die Eigenwerte von A = (2 1; 1 2).",
                                       attributes: [.font: UIFont.systemFont(ofSize: 26), .foregroundColor: UIColor.black])
            UIGraphicsPushContext(ctx)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: 540)
            ctx.scaleBy(x: 1, y: -1)
            title.draw(at: CGPoint(x: 30, y: 16))
            a.draw(at: CGPoint(x: 30, y: 120))
            ctx.restoreGState()
            UIGraphicsPopContext()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return raw as Data
    }

    private func ink(_ y: CGFloat, x: CGFloat = 60) -> PKDrawing {
        let pts = (0..<30).map { i -> PKStrokePoint in
            let t = CGFloat(i)
            return PKStrokePoint(location: CGPoint(x: x + t * 12, y: y + sin(t / 2.5) * 14), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .systemBlue), path: PKStrokePath(controlPoints: pts, creationDate: Date()))])
    }

    /// Uebungsblatt (PDF) und ein Blatt daneben mit zwei beschriebenen Seiten, verknuepft mit Folie 1
    private func scene() async throws -> (api: APIClient, host: LocalBackendHost, root: URL, main: LibFile, sheetID: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bilder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-13T10:00:00")!,
                                    files: LocalFiles(container: root, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let src = root.appendingPathComponent("Übungsblatt 4.pdf")
        try folien(3).write(to: src)
        let mainID = try await ExternalFileImport.create(try ExternalFileImport.stage(src, container: nil), api: api)
        let main = try await api.json("/api/files/\(mainID)", as: LibFile.self)

        let fields = NotebookDialog.fields(kind: "notebook", title: CompanionPicker.sheetTitle(for: main.displayTitle), template: "grid",
                                           format: PageFormats.defaultNotebook, orientation: .portrait)
        let created = try await api.form("/api/notebooks", fields: fields)
        let sheetID = try XCTUnwrap(created.s("id"))
        let sheetFile = try await api.json("/api/files/\(sheetID)", as: LibFile.self)
        let mainStore = DocumentStore(file: main, api: api)
        await mainStore.load()
        let sheet = DocumentStore(file: sheetFile, api: api)
        await sheet.load()
        let first = try XCTUnwrap(sheet.pageKey(forPageIndex: 0))
        await sheet.addBlankPage(afterKey: first, template: "grid")
        let second = try XCTUnwrap(sheet.pageKey(forPageIndex: 1))
        let bridge = EditorBridge()
        bridge.pageKey = mainStore.pageKey(forPageIndex: 0)
        DocumentView.linkSideSheet(sheet, shown: true, main: mainStore, bridge: bridge)
        sheet.canvasChanged(pageKey: first, drawing: ink(120))
        await sheet.addText("λ² − 4λ + 3 = 0  →  λ = 1, λ = 3", pageKey: first)
        sheet.canvasChanged(pageKey: second, drawing: ink(200))
        await sheet.flush()
        try await Task.sleep(nanoseconds: 300_000_000)
        DocumentView.linkSideSheet(sheet, shown: false, main: mainStore, bridge: bridge)
        await sheet.close()
        await mainStore.close()
        return (api, host, root, main, sheetID)
    }

    /// Asynchrone Vorbereitung aus einem synchronen Test (gehostete Ansichten brauchen die Hauptschleife frei)
    @discardableResult
    private func run<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(60)
        while result == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return try XCTUnwrap(result, "Zeitlimit").get()
    }

    // MARK: Bilder

    private func shot(_ view: UIView, _ name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let png = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
    }

    private func elements(in root: Any) -> [NSObject] {
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = element as? NSObject {
                out.append(o)
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return out
    }

    @discardableResult
    private func tap(containing text: String, in root: UIView) -> Bool {
        for e in elements(in: root) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, l.contains(text) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    private func shows(_ text: String, in root: UIView) -> Bool {
        elements(in: root).contains { ($0.accessibilityLabel ?? "").contains(text) }
    }

    /// 1. "Daneben öffnen" mit "Deine Blätter zu diesem Dokument", 2. geteilte Ansicht mit dem Blatt (2 Seiten, "+")
    func test1Nebenansicht() throws {
        let s = try run { try await self.scene() }
        let previous = UserDefaults.standard.object(forKey: "UFDocPanel")
        UserDefaults.standard.set("companion", forKey: "UFDocPanel")
        addTeardownBlock { @MainActor in UserDefaults.standard.set(previous, forKey: "UFDocPanel") }
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: s.main, api: s.api) }, api: s.api, size: CGSize(width: 1180, height: 820))
        // der gehostete Zugang setzt den Tarif beim Start zurueck: Plus fuer Schreiben und "+"
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.plus)
        env.wait(timeout: 15) { self.shows("Deine Blätter", in: env.window) }
        env.pump(1.0)
        shot(env.window, "1-daneben-oeffnen-deine-blaetter")
        XCTAssertTrue(tap(containing: "Notizen – Übungsblatt 4", in: env.window), "eigenes Blatt antippen")
        env.wait(timeout: 10) { self.shows("S. 1 / 2", in: env.window) }
        Entitlements.shared.setPlanForTesting(.plus)
        env.pump(2.0)
        shot(env.window, "2-nebenansicht-zwei-seiten")
        XCTAssertTrue(tap(containing: "Seite darunter einfügen", in: env.window), "„+“ im Kopf des Blatts")
        // erst das Papier waehlen (Wunsch des Inhabers 13.11.2026)
        XCTAssertTrue(env.wait(timeout: 5) { self.tap(containing: "Kariert", in: env.window) }, "Papier waehlen")
        env.wait(timeout: 10) { self.shows("S. 2 / 3", in: env.window) }
        env.pump(2.0)
        shot(env.window, "3-nebenansicht-seite-angefuegt")
        UserDefaults.standard.set(previous, forKey: "UFDocPanel")
    }

    /// Hinweis vor dem Drucken mit dem Blatt daneben (Name, Schalter)
    func test2DruckHinweis() throws {
        let s = try run { try await self.scene() }
        let store = DocumentStore(file: s.main, api: s.api)
        try run { await store.load() }
        let view = PDFExportNoticeWithSheets(store: store, api: s.api, open: nil, scope: .document, confirm: "Drucken",
                                             export: { _ in }, cancel: {})
            .frame(width: 520).padding(30).background(UF.bg)
        let env = try hostWithEnvironment(view, api: s.api, size: CGSize(width: 600, height: 520))
        XCTAssertTrue(env.wait(timeout: 10) { self.shows("Mit dabei: 1 Blatt daneben", in: env.window) })
        env.pump(0.5)
        shot(env.view, "4-drucken-hinweis-blaetter")
        try run { await store.close() }
    }

    /// Fremde Loesung: links mit eigener Kopie der PDF (gleicher Fingerabdruck), rechts ohne (leere Seite)
    func test3LoesungMitHintergrund() throws {
        let s = try run { try await self.scene() }
        let data = try Data(contentsOf: AppPaths.pdf(s.main.id, namespace: s.api.namespace))
        let sha = SolutionSHA256.hex(data)
        let found = try run { () async throws -> (id: String, url: URL)? in
            let backend = try await s.host.backend()
            try await backend.context.database.withConnection { try $0.execute("UPDATE files SET content_sha256=? WHERE id=?", [.text(sha), .text(s.main.id)]) }
            return await CommunityCourses.localPDF(fingerprint: sha, host: s.host)
        }
        let own = try XCTUnwrap(found)
        let pdf = OffscreenPDF(url: own.url)
        var objects: [JSONValue] = []
        for (i, y) in [250.0, 300, 350].enumerated() {
            let pts: [JSONValue] = (0..<20).flatMap { j -> [JSONValue] in [.number(60 + Double(j) * 14), .number(y + sin(Double(j + i) / 2) * 10)] }
            objects.append(["type": "stroke", "points": .array(pts), "color": "#c0262d", "width": 4])
        }
        objects.append(["type": "text", "text": "λ₁ = 1, λ₂ = 3 ✓", "x": 60, "y": 400, "fontSize": 30, "fill": "#c0262d", "width": 500])
        let page = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 960, height: 540, rotation: 0, objects: objects)
        let view = HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mit deiner PDF (gleicher Fingerabdruck)").ufFont(15, 650)
                Text(CommunityTexts.ownPDFNotice).ufFont(12.5).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                CommunityReaderPage(page: page, images: [:], source: pdf, title: "PDF-Seite 1")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Ohne die PDF").ufFont(15, 650)
                Text(CommunityTexts.noPDFNotice).ufFont(12.5).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                CommunityReaderPage(page: page, images: [:], source: nil, title: "PDF-Seite 1")
            }
        }
        .padding(24).frame(width: 1100).background(UF.bg)
        let env = try hostWithEnvironment(view, api: s.api, size: CGSize(width: 1100, height: 560))
        env.pump(2.0)
        shot(env.view, "5-loesung-auf-eigener-pdf")
    }
    /// Gleiches Dokument in einem anderen sichtbaren Fenster: hier "nur ansehen" mit "Hier bearbeiten"; antippen
    /// uebernimmt, die Ansicht oeffnet neu und schreibt
    func test4HierBearbeiten() throws {
        let s = try run { try await self.scene() }
        let other = DocumentStore(file: s.main, api: s.api)
        try run { await other.load() }
        let env = try hostWithEnvironment(ReopenHost(file: s.main, api: s.api), api: s.api, size: CGSize(width: 1180, height: 820))
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.plus)
        XCTAssertTrue(env.wait(timeout: 15) { self.hasButton("Hier bearbeiten", env.window) }, "Knopf „Hier bearbeiten“")
        env.pump(1.0)
        shot(env.window, "6-anderes-fenster-hier-bearbeiten")
        XCTAssertTrue(tap(containing: "Hier bearbeiten", in: env.window))
        XCTAssertTrue(env.wait(timeout: 15) { other.viewOnlyHere && !self.hasButton("Hier bearbeiten", env.window) }, "uebernommen")
        Entitlements.shared.setPlanForTesting(.plus)
        env.pump(1.5)
        shot(env.window, "7-hier-bearbeiten-uebernommen")
        try run { await other.close() }
    }

    /// Zweites "Leeres Blatt" zum selben Dokument: Seite unten in derselben Notiz
    func test5GleicheNotizWeiter() throws {
        let s = try run { try await self.scene() }
        let previous = UserDefaults.standard.object(forKey: "UFDocPanel")
        UserDefaults.standard.set("companion", forKey: "UFDocPanel")
        addTeardownBlock { @MainActor in UserDefaults.standard.set(previous, forKey: "UFDocPanel") }
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: s.main, api: s.api) }, api: s.api, size: CGSize(width: 1180, height: 820))
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.plus)
        env.wait(timeout: 15) { self.shows("Es gibt schon Notizen", in: env.window) }
        env.pump(1.0)
        shot(env.window, "8-leeres-blatt-gleiche-notiz")
        XCTAssertTrue(tap(containing: "Liniert", in: env.window), "Vorlage Liniert")
        env.wait(timeout: 15) { self.shows("S. 3 / 3", in: env.window) }
        env.pump(2.0)
        shot(env.window, "9-neue-seite-in-derselben-notiz")
        UserDefaults.standard.set(previous, forKey: "UFDocPanel")
    }


    /// Papierkorb im Kopf des Notizblatts daneben: Rueckfrage, danach Hinweis, wo es wiederherzustellen ist
    func test6Papierkorb() throws {
        let s = try run { try await self.scene() }
        let previous = UserDefaults.standard.object(forKey: "UFDocPanel")
        UserDefaults.standard.set("companion", forKey: "UFDocPanel")
        addTeardownBlock { @MainActor in UserDefaults.standard.set(previous, forKey: "UFDocPanel") }
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: s.main, api: s.api) }, api: s.api, size: CGSize(width: 1180, height: 820))
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.plus)
        env.wait(timeout: 15) { self.shows("Deine Blätter", in: env.window) }
        env.pump(1.0)
        XCTAssertTrue(env.wait(timeout: 10) { self.tap(containing: "Notizen – Übungsblatt 4", in: env.window) }, "eigenes Blatt")
        UserDefaults.standard.set(previous, forKey: "UFDocPanel")
        XCTAssertTrue(env.wait(timeout: 15) { self.hasButton("Seiten und Blatt", env.window) }, "Menue im Kopf")
        Entitlements.shared.setPlanForTesting(.plus)
        XCTAssertTrue(tap(containing: "Seiten und Blatt", in: env.window))
        env.wait(timeout: 5) { self.hasButton("Ganzes Blatt löschen", env.window) }
        env.pump(1.0)
        shot(env.window, "10-blatt-menue")
        XCTAssertTrue(tap(containing: "Ganzes Blatt löschen", in: env.window))
        env.wait(timeout: 5) { self.hasButton("Blatt in den Papierkorb", env.window) }
        env.pump(1.0)
        shot(env.window, "11-blatt-papierkorb-rueckfrage")
        XCTAssertTrue(env.wait(timeout: 5) { self.tap(containing: "Blatt in den Papierkorb", in: env.window) })
        env.wait(timeout: 10) { self.shows("liegt im Papierkorb", in: env.window) }
        env.pump(0.6)
        shot(env.window, "12-blatt-im-papierkorb-hinweis")
        let trashed = try run { try await s.api.value("/api/library") }
        XCTAssertTrue(trashed.list("trash").contains { $0.s("id") == s.sheetID }, "im Papierkorb")
    }

    private func hasButton(_ text: String, _ root: UIView) -> Bool {
        elements(in: root).contains { $0.accessibilityTraits.contains(.button) && ($0.accessibilityLabel ?? "").contains(text) }
    }
}

/// Dokumentansicht wie in der Bibliothek: neue Identitaet je `DocumentReopen`-Generation
private struct ReopenHost: View {
    let file: LibFile
    let api: APIClient
    @ObservedObject private var reopen = DocumentReopen.shared

    var body: some View {
        NavigationStack { DocumentView(file: file, api: api).id(reopen.generation(file.id)) }
    }
}
