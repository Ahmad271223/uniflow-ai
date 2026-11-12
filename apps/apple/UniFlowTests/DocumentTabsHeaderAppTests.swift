import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Eine Kopfzeile und Reiter im Editor (Auftrag des Inhabers 12.11.2026: "Die Palette mehr nach oben, ich will maximale
/// Schreibflaeche. Und Dateien oben ansammeln (wie Reiter)").
///
/// Vorher (develop 580072ea, iPad quer und hoch gemessen): die PDF begann 171 pt unter dem Fensterrand (32 pt Statusleiste,
/// Navigationsleiste, Reiterstreifen der Bibliothek, Werkzeugleiste). Jetzt: Statusleiste + eine Zeile (44 pt).
/// Bildschirmfotos mit `TEST_RUNNER_UF_TABS_SHOTS=<Ordner>`.
@MainActor
final class DocumentTabsHeaderAppTests: XCTestCase {
    /// PDF-Anfang vorher (gemessen auf develop 580072ea, 1180 x 820 und 820 x 1180)
    static let pdfTopBefore: CGFloat = 171

    override func setUp() async throws {
        UserDefaults.standard.set(EditorToolbarPlacement.top.rawValue, forKey: EditorToolbarPlacement.key)
        Entitlements.shared.setPlanForTesting(.plus)
    }

    override func tearDown() async throws {
        Entitlements.shared.setPlanForTesting(.free)
        UserDefaults.standard.removeObject(forKey: EditorToolbarPlacement.key)
    }

    // MARK: Liste (ohne Ansicht)

    func testTabListOpensSwitchesClosesAndRemembersPerDevice() throws {
        let suite = "uniflow.tests.tabs.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        var clock = 1000.0
        let tabs = DocumentTabList(defaults: d)
        tabs.now = { clock += 1; return Date(timeIntervalSince1970: clock) }
        tabs.sceneID = { "fenster-1" }
        tabs.reloadForTesting()

        tabs.open("a", title: "Analysis Blatt 3")
        tabs.open("b", title: "Lineare Algebra Skript")
        XCTAssertEqual(tabs.ids, ["a", "b"])
        tabs.open("a", title: nil)                                  // vorhandener Reiter: nur aktiv
        XCTAssertEqual(tabs.ids, ["a", "b"])
        XCTAssertEqual(tabs.activeID, "a")
        tabs.open("c", title: "Physik")                             // neu: rechts neben dem aktiven
        XCTAssertEqual(tabs.ids, ["a", "c", "b"])
        XCTAssertEqual(tabs.neighbor(step: 1), "b")
        XCTAssertEqual(tabs.neighbor(step: -1), "a")
        XCTAssertEqual(DocumentTabList.successor(closing: "c", in: tabs.ids), "a", "links daneben")
        XCTAssertEqual(DocumentTabList.successor(closing: "a", in: tabs.ids), "c", "ganz links: der rechts daneben")
        XCTAssertNil(DocumentTabList.successor(closing: "a", in: ["a"]))

        // Stelle je Reiter, ueber Neustart gemerkt (je Geraet, in den Einstellungen)
        let spot = DocumentViewSpot(pageKey: "p3", pdfPage: 3, x: 12, y: 700, zoom: 1.5)
        tabs.setSpot(spot, for: "a")
        let restarted = DocumentTabList(defaults: d)
        restarted.sceneID = { "fenster-1" }
        restarted.reloadForTesting()
        XCTAssertEqual(restarted.ids, ["a", "c", "b"])
        XCTAssertEqual(restarted.activeID, "c")
        XCTAssertEqual(restarted.entry("a")?.spot, spot)
        XCTAssertEqual(restarted.entry("b")?.title, "Lineare Algebra Skript")

        // hoechstens 10: der am laengsten nicht gezeigte faellt heraus, nie der aktive, nie einer mit Ungesichertem
        tabs.setUnsaved(true, for: "b")
        for i in 0..<12 { tabs.open("x\(i)", title: "Dokument \(i)") }
        XCTAssertEqual(tabs.entries.count, DocumentTabList.limit)
        XCTAssertTrue(tabs.ids.contains("b"), "ungesichert bleibt")
        XCTAssertFalse(tabs.ids.contains("a"), "aeltester faellt heraus")
        XCTAssertEqual(tabs.activeID, "x11")

        // Titel gekuerzt, nie umbrochen
        XCTAssertEqual(DocumentTabStrip.shortTitle("Kurz", active: false), "Kurz")
        let long = DocumentTabStrip.shortTitle("Übungsblatt 7 – Mehrdimensionale Integration", active: false)
        XCTAssertLessThanOrEqual(long.count, 18)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertGreaterThan(DocumentTabStrip.shortTitle("Übungsblatt 7 – Mehrdimensionale Integration", active: true).count, long.count)
        // Reiter passen immer ganz: volle Titel, kurze Titel, sonst ein Knopf mit Liste (nie halb abgeschnitten)
        XCTAssertEqual(DocumentTabStrip.fit(full: 300, short: 200, max: 354), .full)
        XCTAssertEqual(DocumentTabStrip.fit(full: 430, short: 330, max: 354), .short)
        XCTAssertEqual(DocumentTabStrip.fit(full: 430, short: 330, max: 164), .menu)
    }

    func testHeaderLayoutNeverWrapsOnlyMovesIntoMenus() {
        XCTAssertFalse(EditorHeaderLayout(width: 1180).compactActions, "quer: Knoepfe einzeln")
        XCTAssertTrue(EditorHeaderLayout(width: 820).compactActions, "hoch: Seiten, Daneben, Teilen im Menue Mehr")
        XCTAssertFalse(EditorHeaderLayout(width: 820).tabsAsMenu)
        XCTAssertTrue(EditorHeaderLayout(width: 500).tabsAsMenu, "sehr schmal: Reiter als ein Knopf")
        XCTAssertEqual(EditorHeaderLayout.height, 44)
        XCTAssertLessThan(EditorHeaderLayout(width: 1180).tabMaxWidth, 1180 / 2)
    }

    // MARK: Im Editor

    private struct Harness: View {
        @EnvironmentObject var router: UFRouter
        var body: some View {
            switch router.route {
            case .doc(let id, let task, let page): LibraryView(openFile: id, openPage: page, openTask: task).id(id)
            default: Text("Übersicht")
            }
        }
    }

    private struct Docs {
        let env: HostedEnvironment
        let ids: [String]
    }

    private func host(_ titles: [String], size: CGSize = CGSize(width: 1180, height: 820)) throws -> Docs {
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        addTeardownBlock { @MainActor in HostedEnvironment.accessibilityAutomation(false) }
        let t = AIViewsAppTests.Transport()
        var ids: [String] = []
        var metas: [JSONValue] = []
        for (n, title) in titles.enumerated() {
            let id = "f-reiter-\(n)-\(UUID().uuidString.prefix(6))"
            ids.append(id)
            t.answer("/api/files/\(id)/content", data: Self.makePDF(title: title, pages: 3), type: "application/pdf")
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
        return Docs(env: env, ids: ids)
    }

    private func editor(_ env: HostedEnvironment) -> PDFEditorController? {
        EditorToolbarTests.pdfViews(in: env.view).first.flatMap(EditorToolbarTests.editor(of:))
    }

    private func frame(_ id: String, _ env: HostedEnvironment) -> CGRect? {
        LockVisibilityAppTests.element(id, in: env.view)?.accessibilityFrame
    }

    private func pdfFrame(_ env: HostedEnvironment) -> CGRect? {
        EditorToolbarTests.pdfViews(in: env.view).first.map { $0.convert($0.bounds, to: env.window) }
    }

    /// Dokument `id` ist offen und geladen (PDFView mit Editor dieses Dokuments)
    private func waitShown(_ env: HostedEnvironment, _ id: String, timeout: Double = 20) -> Bool {
        env.wait(timeout: timeout) {
            guard let e = self.editor(env), e.store.file.id == id, e.pdfView.document != nil else { return false }
            return EditorToolbarTests.pdfViews(in: env.view).count == 1 && self.frame("editor.header", env) != nil
        }
    }

    private func activate(_ id: String, _ env: HostedEnvironment) throws {
        let el = try XCTUnwrap(LockVisibilityAppTests.element(id, in: env.view), "\(id) fehlt: \(EditorToolbarTests.identifiers(in: env.view).sorted())")
        XCTAssertTrue(el.accessibilityActivate(), id)
    }

    /// Drei Dokumente als Reiter: eine Zeile, nur das aktive geladen, Wechsel per Antippen, Stelle und Zoom je Reiter,
    /// Striche bleiben, kein Wechsel waehrend einer Geste, Schliessen
    func testThreeTabsInOneHeaderRowSwitchKeepSpotAndStrokes() throws {
        let docs = try host(["Analysis Übungsblatt 3", "Lineare Algebra Skript", "Physik Protokoll"])
        let env = docs.env
        let (a, b, c) = (docs.ids[0], docs.ids[1], docs.ids[2])
        for id in [a, b, c] {
            env.router.go(.doc(id))
            XCTAssertTrue(waitShown(env, id), "\(id) offen\n" + env.labels().joined(separator: "\n"))
        }
        XCTAssertEqual(env.router.tabs.ids, [a, b, c])
        env.pump(1.0)

        // eine Zeile: Zurueck, Reiter, Werkzeuge, Knoepfe auf einer Hoehe; darunter sofort die PDF
        let header = try XCTUnwrap(frame("editor.header", env))
        XCTAssertEqual(header.height, EditorHeaderLayout.height, accuracy: 0.5, "Kopfzeile eine Zeile, 44 pt")
        let pdf = try XCTUnwrap(pdfFrame(env))
        XCTAssertEqual(pdf.minY, header.maxY, accuracy: 1, "unter der Zeile nur das Dokument")
        for id in ["doc.tab.\(a)", "doc.tab.\(c)", "toolbar.tool.pen", "toolbar.redo", "toolbar.askAI.locked", "doc.more", "doc.pages",
                   "editor.header.hide"] {
            let f = try XCTUnwrap(frame(id, env), id)
            XCTAssertEqual(f.midY, header.midY, accuracy: 1, "\(id) in derselben Zeile")
            XCTAssertGreaterThanOrEqual(f.height, 43.5, "\(id): Trefferflaeche")
        }
        XCTAssertNil(frame("editor.toolbar.locked", env))
        let gained = Self.pdfTopBefore - pdf.minY
        print("REITER Schreibflaeche quer: PDF beginnt bei \(pdf.minY) pt (vorher \(Self.pdfTopBefore)), gewonnen \(gained) pt")
        XCTAssertGreaterThanOrEqual(gained, 90, "mindestens Navigationsleiste und Reiterstreifen gewonnen")
        XCTAssertTrue(env.labels().contains("Seiten") && env.labels().contains("Mehr"))
        try shoot(env, "reiter-quer-3")

        // Speicher: nur das aktive Dokument ist geladen (eine PDFView); die anderen sind leichte Eintraege
        XCTAssertEqual(EditorToolbarTests.pdfViews(in: env.view).count, 1)

        // Stelle und Zoom von C merken lassen
        var ec: PDFEditorController! = try XCTUnwrap(editor(env))
        ec.goToPage(2)
        env.pump(0.3)
        ec.pdfView.scaleFactor = ec.pdfView.scaleFactor * 1.5
        env.pump(0.5)
        let spotC = try XCTUnwrap(ec.currentSpot())
        XCTAssertEqual(spotC.pageKey, "p3")
        XCTAssertEqual(spotC.zoom, 1.5, accuracy: 0.05)

        // Striche kurz vor dem Wechsel (noch nicht verarbeitet): der Wechsel sichert sie
        let stroke = PKDrawing(strokes: [EditorVerbesserungTests.line(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 260, y: 220))])
        ec.store.canvasChanged(pageKey: "p1", drawing: stroke)

        // kein Tausch, solange der Finger scrollt: der Wechsel wartet auf das Gestenende
        ec.scrollGestureOverrideForTesting = true
        try activate("doc.tab.\(a)", env)
        env.pump(0.6)
        XCTAssertEqual(env.router.route, .doc(c), "waehrend der Geste bleibt das Dokument")
        XCTAssertTrue(editor(env) === ec)
        ec.scrollGestureOverrideForTesting = nil
        ec = nil                                                    // der Test haelt das Dokument nicht fest
        XCTAssertTrue(waitShown(env, a), "nach dem Gestenende gewechselt")
        XCTAssertEqual(env.router.tabs.activeID, a)
        XCTAssertEqual(EditorToolbarTests.pdfViews(in: env.view).count, 1, "nur das aktive Dokument geladen")
        XCTAssertTrue(editor(env)?.store.file.id == a)
        XCTAssertEqual(env.router.tabs.entry(c)?.spot?.pageKey, "p3")

        // Stift liegt auf: ebenso warten
        let ea = try XCTUnwrap(editor(env))
        XCTAssertTrue(env.wait { ea.overlayForTesting(at: 0)?.loaded == true })
        ea.overlayForTesting(at: 0)?.isDrawing = true
        XCTAssertFalse(ea.readyToLeave)
        try activate("doc.tab.\(c)", env)
        env.pump(0.6)
        XCTAssertEqual(env.router.route, .doc(a), "waehrend des Strichs bleibt das Dokument")
        ea.overlayForTesting(at: 0)?.isDrawing = false

        // zurueck bei C: Seite 3, Zoom 150 %, der Strich ist da
        XCTAssertTrue(waitShown(env, c))
        let back = try XCTUnwrap(editor(env))
        XCTAssertTrue(env.wait(timeout: 5) { back.currentSpot()?.pageKey == "p3" }, "\(String(describing: back.currentSpot()))")
        XCTAssertEqual(try XCTUnwrap(back.currentSpot()).zoom, 1.5, accuracy: 0.08, "Zoom je Reiter")
        XCTAssertTrue(env.wait(timeout: 10) { back.overlayForTesting(at: 0)?.canvas.drawing.strokes.count == 1 },
                      "Strich vor dem Wechsel gesichert")

        // "×" am aktiven Reiter: der links daneben kommt
        try activate("doc.tab.close.\(c)", env)
        XCTAssertTrue(waitShown(env, b), "Nachbar nach dem Schliessen")
        XCTAssertEqual(env.router.tabs.ids, [a, b])

        // Andere schliessen
        env.router.tabs.closeOthers(keeping: b, router: env.router)
        XCTAssertEqual(env.router.tabs.ids, [b])
        env.window.isHidden = true
    }

    /// Hochkant und sehr schmal: eine Zeile, nichts umgebrochen (Knoepfe im Menue Mehr, Reiter als ein Knopf)
    func testNarrowWidthsKeepOneRow() throws {
        let docs = try host(["Analysis Übungsblatt 3", "Lineare Algebra Skript", "Physik Protokoll"], size: CGSize(width: 820, height: 1180))
        let env = docs.env
        for id in docs.ids {
            env.router.go(.doc(id))
            XCTAssertTrue(waitShown(env, id))
        }
        env.pump(1.0)
        func checkOneRow(_ what: String, ids: [String]) throws {
            let header = try XCTUnwrap(frame("editor.header", env), what)
            XCTAssertEqual(header.height, EditorHeaderLayout.height, accuracy: 0.5, what)
            let pdf = try XCTUnwrap(pdfFrame(env), what)
            XCTAssertEqual(pdf.minY, header.maxY, accuracy: 1, "\(what): PDF direkt unter der Zeile")
            for id in ids {
                let f = try XCTUnwrap(frame(id, env), "\(what): \(id)")
                XCTAssertEqual(f.midY, header.midY, accuracy: 1, "\(what): \(id) in derselben Zeile")
                XCTAssertLessThanOrEqual(f.maxX, env.window.bounds.width + 0.5, "\(what): \(id) im Fenster")
            }
            print("REITER Schreibflaeche \(what): PDF beginnt bei \(pdf.minY) pt (vorher \(Self.pdfTopBefore))")
        }
        try checkOneRow("hoch", ids: ["doc.tabs.menu", "toolbar.tool.pen", "toolbar.redo", "toolbar.askAI.locked", "doc.more"])
        XCTAssertNil(frame("doc.pages", env), "hoch: Seiten im Menue Mehr")
        try shoot(env, "reiter-hoch-3")

        // geteilte Ansicht, ein Drittel
        env.window.frame = CGRect(origin: .zero, size: CGSize(width: 500, height: 1180))
        env.view.frame = env.window.bounds
        env.pump(1.5)
        try checkOneRow("schmal", ids: ["doc.tabs.menu", "toolbar.tool.pen", "toolbar.redo", "doc.more"])
        try shoot(env, "reiter-schmal")
        env.window.isHidden = true
    }

    /// Vollbild-Schreiben: Zeile aus, PDF ab dem oberen Rand, kleiner Griff holt sie zurueck
    func testFullScreenWritingHidesTheHeaderAndComesBack() throws {
        let docs = try host(["Analysis Übungsblatt 3", "Lineare Algebra Skript", "Physik Protokoll"])
        let env = docs.env
        for id in docs.ids {
            env.router.go(.doc(id))
            XCTAssertTrue(waitShown(env, id))
        }
        env.pump(0.8)
        try activate("editor.header.hide", env)
        XCTAssertTrue(env.wait(timeout: 5) { self.frame("editor.header", env) == nil }, "Zeile aus")
        XCTAssertTrue(env.wait(timeout: 5) { (self.pdfFrame(env)?.minY ?? 999) <= env.window.safeAreaInsets.top + 1 }, "PDF ab oben")
        let handle = try XCTUnwrap(frame("editor.header.show", env))
        XCTAssertGreaterThanOrEqual(handle.height, 43.5)
        print("REITER Vollbild-Schreiben: PDF beginnt bei \(pdfFrame(env)?.minY ?? -1) pt")
        try shoot(env, "reiter-vollbild")
        try activate("editor.header.show", env)
        XCTAssertTrue(env.wait(timeout: 5) { self.frame("editor.header", env) != nil }, "Zeile zurueck")
        env.window.isHidden = true
    }

    // MARK: Hilfen

    private func shoot(_ env: HostedEnvironment, _ name: String) throws {
        env.pump(0.4)
        let w = env.window
        let img = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
        let a = XCTAttachment(image: img)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["UF_TABS_SHOTS"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
            try XCTUnwrap(img.pngData()).write(to: url)
            print("REITER Bild: \(url.path)")
        }
    }

    static func makePDF(title: String, pages: Int) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "\(title)".draw(at: CGPoint(x: 72, y: 80), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24)])
            "Seite \(i) – Aufgabe \(i): Bestimmen Sie den Grenzwert.".draw(at: CGPoint(x: 72, y: 130),
                                                                          withAttributes: [.font: UIFont.systemFont(ofSize: 15)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }
}
