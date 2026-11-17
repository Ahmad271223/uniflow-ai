import PDFKit
import PencilKit
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// iPhone ohne Editor (Vorgabe des Inhabers 11.11.2026): Dokumente nur ansehen (oeffnen, lesen, zoomen, suchen), auf dem
/// iPad geschriebene Notizen werden angezeigt, keine Stift-/Werkzeugleiste, kein Korrektur-Modus, keine Notizbuecher.
/// Die Leseansicht (`PhoneDocumentReader`) schreibt nichts an die Notizen. Gegenprobe: am iPad bleibt alles wie bisher.
@MainActor
final class IPhoneReaderTests: IPhoneLearnTestCase {

    override func setUp() async throws {
        try await super.setUp()
        UFEditorAvailability.forcedReaderOnlyForTesting = true
    }

    override func tearDown() async throws {
        UFEditorAvailability.forcedReaderOnlyForTesting = UniFlowTestsPrincipal.readerOnlyDefault
        try await super.tearDown()
    }

    // MARK: - Hilfen

    private func makePDF(pages: Int) -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(consumer: CGDataConsumer(data: out as CFMutableData)!, mediaBox: &box, nil)!
        for i in 0..<pages {
            ctx.beginPDFPage(nil)
            UIGraphicsPushContext(ctx)
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: 1, y: -1)
            ("Kapitel \(i + 1): Zahlensysteme und Rechenregeln" as NSString)
                .draw(at: CGPoint(x: 60, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            UIGraphicsPopContext()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    /// Notizen vom iPad: ein Strich (Handschrift) und ein Textfeld auf Seite 1
    private static let ipadNotes: JSONValue = [
        "version": 2,
        "pages": ["p1": ["objects": [
            ["id": "s1", "type": "stroke", "tool": "pen", "color": "#1f3fbf", "width": 4, "opacity": 1,
             "points": [80, 300, 200, 320, 320, 300, 440, 330], "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1],
            ["id": "t1", "type": "text", "text": "Am iPad notiert", "x": 80, "y": 360, "fontSize": 18, "color": "#000000",
             "rotation": 0, "scaleX": 1, "scaleY": 1],
        ]]],
    ]

    private func document(pages: Int = 3, notes: JSONValue = IPhoneReaderTests.ipadNotes)
        -> (file: LibFile, api: APIClient, transport: AIViewsAppTests.Transport) {
        let t = AIViewsAppTests.Transport()
        let id = "f-lesen-\(UUID().uuidString.prefix(8))"
        t.answer("/api/files/\(id)/content", data: makePDF(pages: pages), type: "application/pdf")
        t.answer("/api/files/\(id)", ["id": .string(id), "name": "Skript.pdf", "kind": "pdf"])
        t.answer("/api/files/\(id)/annotations", ["data": notes, "version": 3, "updated_at": "2026-11-10T10:00:00"])
        let meta: JSONValue = ["id": .string(id), "name": "Skript.pdf", "title": "Skript Kapitel 1", "kind": "pdf", "module_id": 1,
                               "subject": "Informatik", "downloaded_at": "2026-11-05T09:00:00", "page_count": .number(Double(pages)),
                               "doc_type": "vorlesung"]
        let file = try! JSONDecoder().decode(LibFile.self, from: meta.serialized())
        return (file, APIClient(base: URL(string: "http://erfunden.test/")!, transport: t), t)
    }

    private func pdfView(in root: UIView) -> PDFView? {
        if let p = root as? PDFView { return p }
        for s in root.subviews { if let p = pdfView(in: s) { return p } }
        return nil
    }

    private func overlay(_ pdf: PDFView, page: Int) -> PageInkView? {
        guard let p = pdf.document?.page(at: page) else { return nil }
        return pdf.pageOverlayViewProvider?.pdfView(pdf, overlayViewFor: p) as? PageInkView
    }

    private func openReader(size: CGSize = IPhoneLearnTestCase.phone, task: Int? = nil)
        throws -> (env: HostedEnvironment, pdf: PDFView, transport: AIViewsAppTests.Transport) {
        let d = document()
        let env = try hostPhone(NavigationStack { PhoneDocumentReader(file: d.file, api: d.api, task: task) }, api: d.api, size: size)
        var found: PDFView?
        XCTAssertTrue(env.wait(timeout: 15) {
            found = pdfView(in: env.window)
            return found?.document?.pageCount == 3
        }, "PDF nicht geladen: \(dump(env))")
        return (env, try XCTUnwrap(found), d.transport)
    }

    // MARK: - Leseansicht

    func testReaderShowsIPadNotesButNothingWrites() throws {
        let (env, pdf, transport) = try openReader()
        let ink = try XCTUnwrap(overlay(pdf, page: 0))
        XCTAssertTrue(env.wait(timeout: 10) { ink.loaded }, "Notizen nicht geladen")
        XCTAssertEqual(ink.canvas.drawing.strokes.count, 1, "Handschrift vom iPad erscheint")
        XCTAssertFalse(ink.objectsView.shownObjects.isEmpty, "Textfeld vom iPad erscheint")
        // keine Eingabe: weder die Seitenschicht noch die Zeichenflaeche nehmen Beruehrungen an
        XCTAssertFalse(ink.isUserInteractionEnabled)
        XCTAssertFalse(ink.canvas.isUserInteractionEnabled)
        XCTAssertFalse(ink.canvas.drawingGestureRecognizer.isEnabled)
        // Zoomen bleibt (PDFKit), Seite 2 hat keine Notizen
        XCTAssertGreaterThan(pdf.maxScaleFactor, pdf.minScaleFactor)
        let second = try XCTUnwrap(overlay(pdf, page: 1))
        XCTAssertTrue(env.wait(timeout: 10) { second.loaded })
        XCTAssertTrue(second.canvas.drawing.strokes.isEmpty)
        // kein Werkzeug des Editors in der Ansicht
        let ids = elements(env).compactMap(identifier)
        XCTAssertTrue(ids.contains("phoneReader.search"), ids.joined(separator: ", "))
        XCTAssertTrue(ids.contains("phoneReader.tutor"))
        XCTAssertTrue(ids.contains("phoneReader.page"))
        XCTAssertFalse(ids.contains { $0.hasPrefix("editor.") || $0.hasPrefix("palette") || $0.hasPrefix("doc.draw") || $0.hasPrefix("freeze") },
                       ids.joined(separator: ", "))
        XCTAssertTrue(shows(env, "Seite 1 von 3"), dump(env))
        XCTAssertTrue(shows(env, UFEditorAvailability.writeOnIPad), "Hinweis aufs iPad")
        shoot(env, "iphone-dokument-lesen")
        _ = transport
    }

    func testReaderSendsNoAnnotationWrites() throws {
        let d = document()
        let env = try hostPhone(NavigationStack { PhoneDocumentReader(file: d.file, api: d.api) }, api: d.api)
        XCTAssertTrue(env.wait(timeout: 15) { self.pdfView(in: env.window)?.document != nil })
        env.pump(1.5)
        env.window.rootViewController = nil
        env.pump(1)
        let path = "/api/files/\(d.file.id)/annotations"
        for m in ["PUT", "POST", "PATCH"] { XCTAssertEqual(d.transport.count(m, path), 0, "\(m) an die Notizen") }
    }

    func testGoToPageAndSearchJumps() throws {
        let (env, pdf, _) = try openReader()
        let reader = ReaderController()
        reader.pdfView = pdf
        reader.goToPage(2)
        env.pump(0.4)
        XCTAssertEqual(pdf.document?.index(for: try XCTUnwrap(pdf.currentPage)), 2)
        XCTAssertTrue(shows(env, "Seite 3 von 3"), dump(env))
        // Suche im PDF-Text (dieselbe wie am iPad, `DocumentStore.search`)
        let hits = try XCTUnwrap(pdf.document).findString("Kapitel 2", withOptions: .caseInsensitive)
        reader.show(try XCTUnwrap(hits.first))
        env.pump(0.4)
        XCTAssertEqual(pdf.document?.index(for: try XCTUnwrap(pdf.currentPage)), 1)
    }

    /// Kopf der Leseansicht flach (Auftrag des Inhabers 17.11.2026: "oben Leiste dünner", auch am iPhone): eine Zeile
    /// statt zwei, jeder Knopf 44 pt antippbar. Vorher (mit diesem Test gemessen, 390, 402 und 440 pt breit): 102 pt.
    static let headerBefore: CGFloat = 102
    func testHeaderIsOneFlatRowOnPhone() throws {
        hintSeenForTesting(true)
        var lines: [String] = []
        for (name, size) in [("klein", IPhoneLearnTestCase.phoneSmall), ("iPhone", IPhoneLearnTestCase.phone), ("gross", IPhoneLearnTestCase.phoneMax)] {
            let (env, pdf, _) = try openReader(size: size, task: 7)
            env.pump(0.6)
            let top = pdf.convert(pdf.bounds, to: env.window).minY
            let bars = top - env.window.safeAreaInsets.top
            lines.append(String(format: "[Oben] iPhone %@ (%.0f x %.0f): Statuszeile %.0f pt, Dokument beginnt bei %.0f pt, Kopf %.0f pt hoch",
                                name, size.width, size.height, env.window.safeAreaInsets.top, top, bars))
            XCTAssertLessThanOrEqual(bars, PhoneDocumentReader.flatHeaderHeight + 2, "\(name): eine flache Zeile")
            XCTAssertLessThanOrEqual(bars, Self.headerBefore * 2 / 3, "\(name): mindestens ein Drittel flacher als vorher")
            // nichts fehlt, nichts ragt hinaus, alles in einer Zeile
            var mids: [CGFloat] = []
            for id in ["phoneReader.page", "phoneReader.search", "phoneReader.share", "phoneReader.done", "phoneReader.tutor"] {
                let e = try XCTUnwrap(element(env, id: id), "\(name): \(id) fehlt: \(dump(env))")
                let f = frame(e)
                XCTAssertGreaterThanOrEqual(f.minX, -0.5, "\(name): \(id)")
                XCTAssertLessThanOrEqual(f.maxX, size.width + 0.5, "\(name): \(id) ragt ueber den Rand")
                XCTAssertGreaterThanOrEqual(f.minY, env.window.safeAreaInsets.top - 0.5, "\(name): \(id) unter der Statuszeile")
                XCTAssertLessThanOrEqual(f.maxY, top + 0.5, "\(name): \(id) im Kopf")
                if id == "phoneReader.page" {
                    XCTAssertGreaterThanOrEqual(f.height, 43.5, "\(name): Titel und Seite 44 pt antippbar")
                } else {
                    mids.append(f.midY)
                }
            }
            XCTAssertLessThanOrEqual((mids.max() ?? 0) - (mids.min() ?? 0), 1, "\(name): Knoepfe auf einer Hoehe")
            XCTAssertTrue(shows(env, "Seite 1 von 3"), dump(env))
            shoot(env, "iphone-kopf-\(name)")
            env.window.isHidden = true
        }
        print(lines.joined(separator: "\n"))
    }

    private func hintSeenForTesting(_ seen: Bool) {
        let before = UserDefaults.standard.object(forKey: "uniflow.phoneReader.hintSeen")
        UserDefaults.standard.set(seen, forKey: "uniflow.phoneReader.hintSeen")
        addTeardownBlock { UserDefaults.standard.set(before, forKey: "uniflow.phoneReader.hintSeen") }
    }

    /// Fueller, feiner Fineliner und durchscheinender Textmarker vom iPad (17.11.2026) erscheinen in der Leseansicht
    /// mit ihrer Tinte; eine Tintenart, die diese Fassung nicht kennt, als normaler Stift
    func testReaderShowsFountainFineAndMarkerStrokes() throws {
        func stroke(_ id: String, tool: String, pkInk: String?, width: Double, opacity: Double, y: Double) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "type": "stroke", "tool": .string(tool), "color": "#1d2130", "width": .number(width),
                                          "opacity": .number(opacity), "points": [80, .number(y), 200, .number(y + 6), 320, .number(y), 440, .number(y + 8)],
                                          "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1]
            if let pkInk { o["pkInk"] = .string(pkInk) }
            return .object(o)
        }
        let notes: JSONValue = ["version": 2, "pages": ["p1": ["objects": [
            stroke("fu", tool: "fountain", pkInk: PKInk.InkType.fountainPen.rawValue, width: 2.8, opacity: 1, y: 200),
            stroke("fi", tool: "pen", pkInk: PKInk.InkType.monoline.rawValue, width: 2.25, opacity: 1, y: 240),
            stroke("ma", tool: "marker", pkInk: PKInk.InkType.marker.rawValue, width: 10, opacity: 0.175, y: 280),
            stroke("un", tool: "kalligrafie", pkInk: "com.apple.ink.reedcalligraphy", width: 3, opacity: 1, y: 320),
        ]]]]
        let d = document(notes: notes)
        let env = try hostPhone(NavigationStack { PhoneDocumentReader(file: d.file, api: d.api) }, api: d.api, size: IPhoneLearnTestCase.phone)
        var found: PDFView?
        XCTAssertTrue(env.wait(timeout: 15) {
            found = self.pdfView(in: env.window)
            return found?.document?.pageCount == 3
        }, dump(env))
        let ink = try XCTUnwrap(overlay(try XCTUnwrap(found), page: 0))
        XCTAssertTrue(env.wait(timeout: 10) { ink.loaded }, "Notizen nicht geladen")
        XCTAssertEqual(ink.canvas.drawing.strokes.map { $0.ink.inkType }, [.fountainPen, .monoline, .marker, .pen])
        var alpha: CGFloat = 0
        ink.canvas.drawing.strokes[2].ink.color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        XCTAssertEqual(alpha, 0.5, accuracy: 0.02, "Textmarker mit 50 % bleibt durchscheinend")
        XCTAssertEqual(ink.canvas.drawing.strokes[1].path[0].size.width, 2.25, accuracy: 0.01, "feiner Fineliner bleibt fein")
        env.window.isHidden = true
    }

    func testReaderFitsAllPhoneSizesAndLargeType() throws {
        for size in [IPhoneLearnTestCase.phoneSmall, IPhoneLearnTestCase.phone, IPhoneLearnTestCase.phoneMax] {
            let (env, _, _) = try openReader(size: size)
            for e in elements(env) {
                let f = frame(e)
                guard !f.isNull, f.width > 0, let id = identifier(e), id.hasPrefix("phoneReader.") else { continue }
                XCTAssertLessThanOrEqual(f.maxX, size.width + 0.5, "\(id) ragt ueber den Rand bei \(size.width)")
                XCTAssertGreaterThanOrEqual(f.minX, -0.5, "\(id) bei \(size.width)")
            }
        }
        let d = document()
        let env = try hostPhone(NavigationStack { PhoneDocumentReader(file: d.file, api: d.api) }
                                    .environment(\.dynamicTypeSize, .accessibility3), api: d.api, size: IPhoneLearnTestCase.phoneSmall)
        XCTAssertTrue(env.wait(timeout: 15) { self.pdfView(in: env.window)?.document != nil })
        XCTAssertNotNil(element(env, id: "phoneReader.tutor"), "KI-Hilfe auch bei sehr grosser Schrift: \(dump(env))")
        shoot(env, "iphone-dokument-grosse-schrift")
    }

    /// Fertige Notizen vom iPad am iPhone teilen (Wunsch des Inhabers 11.11.2026): Knopf in der Leseansicht, Auswahl
    /// "Lösung teilen …" / "Meine geteilten Lösungen …" wie im Editor-Menü am iPad
    func testShareButtonOffersSolutionSharing() throws {
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        defer { Entitlements.shared.setPlanForTesting(before) }
        let (env, _, transport) = try openReader()
        let share = try XCTUnwrap(element(env, id: "phoneReader.share"), dump(env))
        XCTAssertEqual(share.accessibilityLabel, "Lösung teilen")
        XCTAssertTrue(share.accessibilityActivate())
        var sheet: UIAlertController?
        XCTAssertTrue(env.wait(timeout: 5) {
            var vc = env.hosting.presentedViewController
            while let p = vc?.presentedViewController { vc = p }
            sheet = vc as? UIAlertController
            return sheet != nil
        }, "Auswahl erscheint")
        let titles = sheet?.actions.compactMap(\.title) ?? []
        XCTAssertTrue(titles.contains("Lösung teilen …"), titles.joined(separator: ", "))
        XCTAssertTrue(titles.contains("Meine geteilten Lösungen …"), titles.joined(separator: ", "))
        XCTAssertEqual(sheet?.message, SolutionTexts.ownNotesOnly)
        sheet?.dismiss(animated: false)
        env.pump(0.5)
        _ = transport
    }

    /// Dialog "Lösung teilen" aus der Leseansicht: die Notizen vom iPad werden gelesen (Vorschau), "Als Datei teilen"
    /// und "In der Community veröffentlichen" stehen bereit, alles passt aufs iPhone; an die Notizen geht nichts
    func testShareSheetFromReaderShowsIPadNotes() throws {
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        defer { Entitlements.shared.setPlanForTesting(before) }
        let d = document()
        let store = DocumentStore(file: d.file, api: d.api)
        try awaiting { await store.load() }
        XCTAssertNotNil(store.pdf, "PDF geladen")
        let env = try hostPhone(SolutionShareSheet(store: store, api: d.api) {}, api: d.api)
        XCTAssertTrue(env.wait(timeout: 20) { self.shows(env, "Als Datei teilen") }, dump(env))
        XCTAssertFalse(shows(env, "Keine eigenen Notizen"), "Notizen vom iPad zählen als eigene Notizen: \(dump(env))")
        assertFitsOnAllPhones(env, "loesung-teilen")
        shoot(env, "iphone-loesung-teilen")
        let path = "/api/files/\(d.file.id)/annotations"
        for m in ["PUT", "POST", "PATCH"] { XCTAssertEqual(d.transport.count(m, path), 0, "\(m) an die Notizen") }
    }

    func testTaskDoneButtonOnlyFromStudyPlan() throws {
        let (env, _, _) = try openReader(task: 7)
        XCTAssertNotNil(element(env, id: "phoneReader.done"))
        let (plain, _, _) = try openReader()
        XCTAssertNil(element(plain, id: "phoneReader.done"))
    }

    // MARK: - Editor-Einstiege am iPhone

    func testEditorAvailabilityFollowsDevice() {
        UFEditorAvailability.forcedReaderOnlyForTesting = true
        XCTAssertTrue(UFEditorAvailability.readerOnly)
        XCTAssertFalse(UFEditorAvailability.available)
        UFEditorAvailability.forcedReaderOnlyForTesting = false
        XCTAssertFalse(UFEditorAvailability.readerOnly)
        XCTAssertTrue(UFEditorAvailability.available)
        UFEditorAvailability.forcedReaderOnlyForTesting = nil
        XCTAssertEqual(UFEditorAvailability.readerOnly, UFDevice.isPhone, "ohne Vorgabe nach Geraet")
    }

    func testLibraryNewOffersNoNotebookOnPhone() throws {
        let api = APIClient.local(.unavailable)
        let env = try hostPhone(LibraryNewDialog(lib: ["modules": [], "folders": []], path: "", current: (label: "", path: "")), api: api)
        XCTAssertNil(button(env, "Notizbuch"), dump(env))
        XCTAssertNil(button(env, "Whiteboard"), dump(env))
        XCTAssertNotNil(button(env, "PDF importieren"), dump(env))
        XCTAssertTrue(shows(env, UFEditorAvailability.notebookOnIPad), dump(env))
        // iPad: unveraendert
        UFEditorAvailability.forcedReaderOnlyForTesting = false
        let pad = try hostPad(LibraryNewDialog(lib: ["modules": [], "folders": []], path: "", current: (label: "", path: "")), api: api)
        XCTAssertNotNil(button(pad, "Notizbuch", prefix: true), dump(pad))
        XCTAssertFalse(shows(pad, UFEditorAvailability.notebookOnIPad))
    }

    func testTextsSpeakOfTheIPadForWriting() {
        UFEditorAvailability.forcedReaderOnlyForTesting = true
        XCTAssertFalse(LibraryEmptyCard.text(connected: false, source: "Stud.IP").contains("Notizbuch"))
        XCTAssertFalse(LibraryEmptyCard.text(connected: true, source: "Stud.IP").contains("Notizbüch"))
        XCTAssertTrue(UFFeature.pencilWriting.title.contains("iPad-App"))
        XCTAssertTrue(UFFeature.splitView.title.contains("iPad-App"))
        XCTAssertTrue(PlanPickerView.subtitle(proAI: true).contains("in der iPad-App"))
        XCTAssertFalse(AIHelpContent.start.items.joined().contains("Im Editor"))
        XCTAssertFalse(CommunityPage.howItWorks.map(\.text).joined().contains("im Editor"))
        UFEditorAvailability.forcedReaderOnlyForTesting = false
        // am Mac ("Designed for iPad") gibt es keinen Apple Pencil: "Schreiben mit Maus oder Trackpad" (`UFDevice.adapt`)
        XCTAssertEqual(UFFeature.pencilWriting.title,
                       ProcessInfo.processInfo.isiOSAppOnMac ? "Schreiben mit Maus oder Trackpad" : "Schreiben mit Apple Pencil")
        XCTAssertTrue(LibraryEmptyCard.text(connected: false, source: "Stud.IP").contains("Notizbuch"))
        XCTAssertTrue(AIHelpContent.start.items.joined().contains("Im Editor"))
    }

    func testDeviceWordingOnPhone() {
        XCTAssertEqual(UFDevice.adapt("Bleibt auf diesem iPad.", phone: true), "Bleibt auf diesem iPhone.")
        XCTAssertEqual(UFDevice.adapt("im Schlüsselbund dieses iPads", phone: true), "im Schlüsselbund dieses iPhones")
        XCTAssertEqual(UFDevice.adapt("verbindet dieses iPad", phone: true), "verbindet dieses iPhone")
        XCTAssertEqual(UFDevice.adapt("Notizen schreibst du am iPad", phone: true), "Notizen schreibst du am iPad", "das iPad selbst bleibt")
        XCTAssertEqual(UFDevice.adapt("Bleibt auf diesem iPad.", phone: false), "Bleibt auf diesem iPad.")
    }
}
