import PDFKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Obere Leisten im Dokument flacher (Auftrag des Inhabers 17.11.2026: "oben Leiste dünner machen, damit man mehr Platz
/// zum Schreiben hat"). Sein Foto zeigt die Lage "Unten fest": oben die Navigationsleiste des Systems (runde Knoepfe in
/// Kapseln) und darunter der Streifen mit den offenen Dokumenten.
///
/// Gemessen wird, wo das Dokument beginnt (oberer Rand der PDF-Ansicht) und wo die erste Seite - iPad quer und hoch, in
/// den Lagen "Unten fest" und "Schwebend". Zeilen "[Oben]" im Testprotokoll; Bilder mit
/// `TEST_RUNNER_UF_OBEN_SHOTS=<Ordner>`.
@MainActor
final class EditorObenFlachTests: XCTestCase {
    /// Stand bis 17.11.2026 (fix/stift-absetzen edd29b88, mit diesem Test gemessen, iPad 11 Zoll, quer wie hoch): Unter
    /// der Statuszeile (32 pt) lagen in "Unten fest" und "Schwebend" 99 pt Leisten - Navigationsleiste 55 pt und
    /// Streifen der offenen Dokumente 44 pt, auch wenn nur ein Dokument offen war. Das Dokument begann bei 131 pt.
    static let barsBefore: CGFloat = 99
    /// Obergrenze jetzt (ohne Statuszeile): eine flache Zeile mit ihrer Linie
    static let barsLimit: CGFloat = 41

    override func setUp() async throws {
        Entitlements.shared.setPlanForTesting(.plus)
    }

    override func tearDown() async throws {
        Entitlements.shared.setPlanForTesting(.free)
        UserDefaults.standard.removeObject(forKey: EditorToolbarPlacement.key)
    }

    private struct Harness: View {
        @EnvironmentObject var router: UFRouter
        var body: some View {
            switch router.route {
            case .doc(let id, let task, let page): LibraryView(openFile: id, openPage: page, openTask: task).id(id)
            default: Text("Übersicht")
            }
        }
    }

    struct Messung {
        var statusBar: CGFloat = 0
        var documentTop: CGFloat = 0
        var pageTop: CGFloat = 0
        var toolbar: CGRect?
        var header: CGRect?
        var window: CGSize = .zero
        var scale: CGFloat = 0
        var pageWidth: CGFloat = 0
        var margins: UIEdgeInsets = .zero
        /// Oberkante der ersten Seite in PDFKits Dokumentansicht (Seitenpunkte): so viel Rand legt PDFKit selbst davor
        var pdfKitTop: CGFloat?
    }

    private func host(_ titles: [String], size: CGSize) throws -> (env: HostedEnvironment, ids: [String]) {
        Entitlements.shared.setPlanForTesting(.plus)
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        addTeardownBlock { @MainActor in HostedEnvironment.accessibilityAutomation(false) }
        let t = AIViewsAppTests.Transport()
        var ids: [String] = []
        var metas: [JSONValue] = []
        for (n, title) in titles.enumerated() {
            let id = "f-oben-\(n)-\(UUID().uuidString.prefix(6))"
            ids.append(id)
            t.answer("/api/files/\(id)/content", data: DocumentTabsHeaderAppTests.makePDF(title: title, pages: 3), type: "application/pdf")
            t.answer("/api/files/\(id)/annotations", ["data": AnnotationDocument.emptyRoot, "version": 0, "updated_at": .null])
            let meta: JSONValue = ["id": .string(id), "name": .string(title + ".pdf"), "title": .string(title), "kind": "pdf",
                                   "module_id": 1, "downloaded_at": "2026-11-12T09:00:00", "page_count": 3, "doc_type": "uebung"]
            t.answer("/api/files/\(id)", meta)
            metas.append(meta)
        }
        t.answer("/api/related", ["results": []])
        t.answer("/api/library", ["files": .array(metas), "modules": []])
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        let env = try hostWithEnvironment(Harness(), api: api, size: size)
        env.window.overrideUserInterfaceStyle = .light
        env.pump(0.8)
        Entitlements.shared.setPlanForTesting(.plus)                  // der erste Stand des Tarifs kommt nach dem Start
        return (env, ids)
    }

    private func editor(_ env: HostedEnvironment) -> PDFEditorController? {
        EditorToolbarTests.pdfViews(in: env.view).first.flatMap(EditorToolbarTests.editor(of:))
    }

    private func frame(_ id: String, _ env: HostedEnvironment) -> CGRect? {
        LockVisibilityAppTests.element(id, in: env.view)?.accessibilityFrame
    }

    private func open(_ env: HostedEnvironment, _ ids: [String]) {
        for id in ids {
            env.router.go(.doc(id))
            XCTAssertTrue(env.wait(timeout: 20) {
                guard let e = self.editor(env), e.store.file.id == id, e.pdfView.document != nil else { return false }
                return EditorToolbarTests.pdfViews(in: env.view).count == 1
            }, "\(id) offen")
        }
        Entitlements.shared.setPlanForTesting(.plus)
        env.pump(1.2)
    }

    private func messe(_ env: HostedEnvironment) throws -> Messung {
        let e = try XCTUnwrap(editor(env))
        let pdf = e.pdfView
        var m = Messung()
        m.window = env.window.bounds.size
        m.statusBar = env.window.safeAreaInsets.top
        m.documentTop = pdf.convert(pdf.bounds, to: env.window).minY
        let page = try XCTUnwrap(pdf.document?.page(at: 0))
        let pageRect = pdf.convert(pdf.convert(page.bounds(for: pdf.displayBox), from: page), to: env.window)
        m.pageTop = pageRect.minY
        m.pageWidth = pageRect.width
        m.scale = pdf.scaleFactor
        m.margins = pdf.pageBreakMargins
        m.toolbar = frame("editor.toolbar", env)
        m.header = frame("editor.header", env)
        // wo PDFKit die erste Seite in seine eigene Ansicht legt (Seitenpunkte, ohne Zoom und ohne Verschiebung)
        if let doc = pdf.documentView {
            m.pdfKitTop = pdf.convert(pdf.convert(page.bounds(for: pdf.displayBox), from: page), to: doc).minY
        }
        return m
    }

    private func zeile(_ what: String, _ m: Messung) -> String {
        String(format: "[Oben] %@ (%.0f x %.0f): Statuszeile %.0f pt, Dokument beginnt bei %.0f pt, erste Seite bei %.2f pt; Leisten ohne Statuszeile %.0f pt%@; Seite %.0f pt breit, Massstab %.3f, Seitenrand oben %.2f (gemeldet), %@ (von PDFKit gelegt); iOS %@",
               what, m.window.width, m.window.height, m.statusBar, m.documentTop, m.pageTop, m.documentTop - m.statusBar,
               m.header.map { String(format: "; Kopfzeile %.0f pt hoch", $0.height) } ?? "", m.pageWidth, m.scale, m.margins.top,
               m.pdfKitTop.map { String(format: "%.2f", $0) } ?? "-", UIDevice.current.systemVersion)
    }

    private func shoot(_ env: HostedEnvironment, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["UF_OBEN_SHOTS"], !dir.isEmpty else { return }
        env.pump(0.4)
        let w = env.window
        let img = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        try XCTUnwrap(img.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    /// Messung und Bilder: drei offene Dokumente und eines allein, quer und hoch, hell und dunkel, "Unten fest" und
    /// "Schwebend". Lief auch auf dem Stand davor (Zahlen "vorher": `barsBefore`). Jetzt: eine flache Zeile, darunter
    /// sofort das Dokument; jeder Knopf steht in der Zeile, ist mindestens 44 pt breit und liegt ganz im Fenster.
    func testObenEineFlacheZeileInJederLage() throws {
        var lines: [String] = []
        for placement in [EditorToolbarPlacement.bottom, .floating] {
            UserDefaults.standard.set(placement.rawValue, forKey: EditorToolbarPlacement.key)
            // Am Mac gibt es "Schwebend" nicht (Apples Palette erscheint dort nicht; die Einstellung bietet nur "Oben fest"
            // und "Unten fest"): ein gespeichertes "Schwebend" gilt dort als "Oben fest" (`EditorToolbarPlacement.resolve`).
            // Dann stehen die Werkzeuge in der Zeile, und sie ist so hoch wie die Werkzeugleiste (44 pt Trefferflaeche,
            // wie "Oben fest" auf dem iPad); Suchen, Finger/Stift und Ebenen stehen im Menue "Mehr" (Suchen auch mit Cmd-F,
            // Menue "Dokument", `EditorCommands`).
            let withTools = EditorToolbarPlacement.resolve(placement.rawValue, isMac: PDFEditorController.isMac) == .top
            XCTAssertEqual(withTools, PDFEditorController.isMac && placement == .floating, "nur am Mac wird Schwebend zu Oben fest")
            let rowHeight = withTools ? EditorHeaderLayout.height : EditorHeaderLayout.flatHeight
            let barsLimit = withTools ? EditorHeaderLayout.height + 1 : Self.barsLimit
            for (lage, size) in [("quer", CGSize(width: 1180, height: 820)), ("hoch", CGSize(width: 820, height: 1180))] {
                for count in [3, 1] {
                    let titles = Array(["SigSys_Aufgaben", "Analysis Übungsblatt 3", "Physik Protokoll"].prefix(count))
                    let (env, ids) = try host(titles, size: size)
                    open(env, ids)
                    let m = try messe(env)
                    let name = "\(placement.rawValue)-\(lage)-\(count)"
                    let what = "\(placement.title)\(withTools ? " (am Mac: Oben fest)" : ""), \(lage), \(count) Dokument(e)"
                    lines.append(zeile(what, m))
                    print(lines.last!)
                    let bars = m.documentTop - m.statusBar
                    XCTAssertLessThanOrEqual(bars, barsLimit, "\(what): Leisten ueber dem Dokument")
                    XCTAssertLessThanOrEqual(bars, Self.barsBefore * 2 / 3, "\(what): mindestens ein Drittel flacher als vorher")
                    let header = try XCTUnwrap(m.header, "\(what): Kopfzeile")
                    XCTAssertEqual(header.height, rowHeight, accuracy: 0.5, what)
                    XCTAssertEqual(m.documentTop, header.maxY, accuracy: 1, "\(what): unter der Zeile sofort das Dokument")
                    // bis zur ersten Seite nur PDFKits Seitenrand (Seiten-pt mal Massstab), kein leerer Streifen. Die App setzt
                    // keinen eigenen Rand. `pageBreakMargins.top` meldet ueberall 4,75; wohin PDFKit die erste Seite legt,
                    // haengt aber vom System ab (gemessen 19.11.2026, Lage der Seite in PDFKits Dokumentansicht): iPadOS
                    // 27.2 bei 4,75 (quer 4,75 x 1,957 = 9,30 pt, hoch 6,46 pt), iPadOS 26.2 und Mac bei 5,25 (quer
                    // 10,27 pt, hoch 7,14 pt) - ein halber Seitenpunkt grauer Rand mehr, von PDFKit, kein Fehler der App.
                    // Darum gilt der Rand, den PDFKit selbst legt (hoechstens einen halben Seitenpunkt mehr als gemeldet).
                    let pageGap = m.pageTop - m.documentTop
                    let pdfKitTop = try XCTUnwrap(m.pdfKitTop, "\(what): Lage der Seite in PDFKits Dokumentansicht")
                    XCTAssertGreaterThanOrEqual(pdfKitTop, m.margins.top - 0.01, "\(what): PDFKit legt mindestens den gemeldeten Rand")
                    XCTAssertLessThanOrEqual(pdfKitTop, m.margins.top + 0.5 + 0.01, "\(what): PDFKit legt hoechstens einen halben Seitenpunkt mehr")
                    XCTAssertLessThanOrEqual(pageGap, pdfKitTop * m.scale + 0.5, "\(what): kein leerer Streifen bis zur Seite")
                    XCTAssertLessThanOrEqual(pageGap, 11, "\(what): kein leerer Streifen bis zur Seite")
                    // keine Funktion fehlt: alles, was die Navigationsleiste trug, steht einzeln in der Zeile
                    var wanted = ["doc.pages", "doc.search", "toolbar.askAI.locked", "doc.split", "doc.pencilOnly", "doc.layers", "doc.share",
                               "doc.more", "editor.header.hide", "doc.tab.\(ids[count - 1])"]       // der aktive Reiter ist in Sicht
                    if withTools {
                        // mit Werkzeugen in der Zeile ("Oben fest"): Suchen, Finger/Stift, Ebenen im Menue "Mehr"; schmal
                        // (hoch) auch Seiten, Daneben, Teilen und "Leiste ausblenden" (`EditorHeaderLayout.compactActions`)
                        let layout = EditorHeaderLayout(width: header.width, hasTools: true)
                        XCTAssertFalse(layout.showsAllActions, what)
                        wanted = ["toolbar.askAI.locked", "doc.more", "doc.tab.\(ids[count - 1])"]
                        if !layout.compactActions { wanted += ["doc.pages", "doc.split", "doc.share", "editor.header.hide"] }
                        let present = EditorToolbarTests.identifiers(in: env.view)
                        for inMore in ["doc.search", "doc.pencilOnly", "doc.layers"] {
                            XCTAssertFalse(present.contains(inMore), "\(what): \(inMore) steht im Menue Mehr, nicht doppelt in der Zeile")
                        }
                    }
                    if count > 1 { wanted.append("doc.tab.close.\(ids[count - 1])") }
                    for id in wanted {
                        let f = try XCTUnwrap(frame(id, env), "\(what): \(id) fehlt: \(EditorToolbarTests.identifiers(in: env.view).sorted())")
                        XCTAssertEqual(f.midY, header.midY, accuracy: 1.5, "\(what): \(id) in der Zeile")
                        XCTAssertGreaterThanOrEqual(f.minX, -0.5, "\(what): \(id) im Fenster")
                        XCTAssertLessThanOrEqual(f.maxX, m.window.width + 0.5, "\(what): \(id) im Fenster")
                        if id.hasPrefix("doc.tab.close") {
                            XCTAssertGreaterThanOrEqual(f.width, 27.5, "\(what): \(id)")
                        } else {
                            XCTAssertGreaterThanOrEqual(f.width, 43.5, "\(what): \(id) mindestens 44 pt breit")
                        }
                        XCTAssertGreaterThanOrEqual(f.height, EditorHeaderLayout.flatHeight - 0.5, "\(what): \(id) so hoch wie die Zeile")
                    }
                    // die Werkzeuge bleiben, wo sie waren (unten bzw. Apples Palette), nicht in der Zeile; am Mac bei
                    // "Schwebend" (= "Oben fest") stehen sie in der Zeile
                    if withTools {
                        let bar = try XCTUnwrap(m.toolbar, "\(what): Werkzeuge in der Zeile")
                        XCTAssertEqual(bar.midY, header.midY, accuracy: 1.5, "\(what): Werkzeuge in der Zeile")
                    } else if placement == .bottom {
                        let bar = try XCTUnwrap(m.toolbar, "\(what): Werkzeugleiste unten")
                        XCTAssertGreaterThan(bar.minY, m.window.height / 2, what)
                    }
                    try shoot(env, name + "-hell")
                    env.window.overrideUserInterfaceStyle = .dark
                    env.pump(0.6)
                    try shoot(env, name + "-dunkel")
                    env.window.isHidden = true
                    env.window.rootViewController = nil
                    env.pump(0.3)
                }
            }
        }
        print(lines.joined(separator: "\n"))
    }
}
