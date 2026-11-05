import PDFKit
import PencilKit
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// iPhone-Fassung des Dokuments (docs/IPHONE-2026-11-04.md, Teil B): kompakt bei 402x874 (iPhone 17) die PDF
/// bildschirmfuellend, oben Zurueck, Titel und das Menue "…", unten die Leiste mit Seiten, "Blättern / Zeichnen",
/// Werkzeugen und KI-Hilfe; Seiten und KI-Hilfe als Blatt von unten (halb/ganz). "Zeichnen" stellt die Eingabeart der
/// Zeichenflaechen auf `.anyInput` (ein Finger schreibt), "Blättern" zurueck auf `.pencilOnly`. Das iPad (regulaer,
/// 1180x820) bleibt wie es war: "Nur Stift", Seitenleiste als Spalte, kein Blatt.
///
/// Die Groessenklassen und das Geraet werden fest gesetzt (`traitOverrides`, `UFCompact.phoneOverride`), damit die
/// Tests auf dem iPhone- und dem iPad-Simulator dasselbe pruefen. Alles gegen einen Schein-Transport, kein Netz.
/// Mit UF_SCREENSHOT_DIR (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt `testScreenshots` Bilder hell und dunkel.
@MainActor
final class IPhoneDocumentLayoutTests: XCTestCase {

    static let phone = CGSize(width: 402, height: 874)
    static let pad = CGSize(width: 1180, height: 820)

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        // erster Test des Laufs: die Abfrage des App Store beim Start setzte den Tarif sonst spaeter auf Free zurueck
        for _ in 0..<200 where await MainActor.run(body: { Entitlements.shared.loading }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await MainActor.run {
            let before = Entitlements.shared.plan
            Entitlements.shared.setPlanForTesting(.plus)
            addTeardownBlock { @MainActor in
                Entitlements.shared.setPlanForTesting(before)
                UFCompact.phoneOverride = nil
            }
        }
    }

    // MARK: Schein-Transport und Dokument

    final class Transport: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var canned: [String: JSONValue] = [:]
        private var raw: [String: (data: Data, type: String)] = [:]

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let query = request.url?.query.map { "?" + $0 } ?? ""
            let (answer, bytes) = lock.withLock { () -> (JSONValue?, (data: Data, type: String)?) in
                counts[path, default: 0] += 1
                return (canned[path + query] ?? canned[path], raw[path])
            }
            if let bytes {
                return (bytes.data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": bytes.type])!)
            }
            let data = (answer ?? ["detail": "Testfehler"]).serialized()
            return (data, HTTPURLResponse(url: request.url!, statusCode: answer == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }

        private var counts: [String: Int] = [:]
        func answer(_ path: String, _ v: JSONValue) { lock.withLock { canned[path] = v } }
        func bodiesCount(_ path: String) -> Int { lock.withLock { counts[path] ?? 0 } }
        func answer(_ path: String, data: Data, type: String) { lock.withLock { raw[path] = (data, type) } }
    }

    private func api(_ t: Transport) -> APIClient { APIClient(base: URL(string: "http://erfunden.test/")!, transport: t) }

    private func makePDF(pages: Int = 3) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for i in 1...pages {
                ctx.beginPage()
                ("Folgen und Reihen – Seite \(i)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 26, weight: .semibold)])
                ("Definition: Eine Folge (a_n) heißt konvergent, wenn es ein a gibt mit |a_n − a| < ε für fast alle n." as NSString)
                    .draw(in: CGRect(x: 72, y: 130, width: 450, height: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
            }
        }
    }

    /// Transport mit geladener PDF `id` und leeren Notizen; dazu die Datei der Bibliothek
    private func document(id: String = "f-\(UUID().uuidString.prefix(8))") throws -> (Transport, LibFile) {
        let t = Transport()
        t.answer("/api/files/\(id)/content", data: makePDF(), type: "application/pdf")
        t.answer("/api/files/\(id)/annotations", ["data": AnnotationDocument.emptyRoot, "version": 0, "updated_at": .null])
        t.answer("/api/library", ["files": [], "modules": [], "folders": [], "trash": []])
        let meta: JSONValue = ["id": .string(id), "name": "VL03 Folgen und Reihen.pdf", "title": "VL03 Folgen und Reihen.pdf", "kind": "pdf",
                               "module_id": 1, "downloaded_at": "2026-10-20T10:00:00", "page_count": 3, "doc_type": "vorlesung"]
        return (t, try JSONDecoder().decode(LibFile.self, from: meta.serialized()))
    }

    /// Dokument gehostet; `compact`: Groessenklassen eines iPhones hochkant und Geraet iPhone
    private func host(compact: Bool, phone: Bool? = nil, size: CGSize? = nil,
                      typeSize: DynamicTypeSize = .large) throws -> (HostedEnvironment, Transport) {
        let (t, file) = try document()
        UFCompact.phoneOverride = phone ?? compact
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: file, api: api(t)) }.environment(\.ufAIEnabled, true)
                                            .environment(\.dynamicTypeSize, typeSize),
                                          api: api(t), size: size ?? (compact ? Self.phone : Self.pad))
        env.hosting.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
        env.hosting.traitOverrides.verticalSizeClass = .regular
        XCTAssertTrue(env.wait(timeout: 20) { self.editor(env)?.pdfView.document != nil }, "Editor geladen")
        env.pump(0.6)
        return (env, t)
    }

    // MARK: Hilfen

    /// Editor im Baum der Ansichtssteuerungen
    private func editor(_ env: HostedEnvironment) -> PDFEditorController? {
        func find(_ vc: UIViewController) -> PDFEditorController? {
            if let e = vc as? PDFEditorController { return e }
            for c in vc.children { if let e = find(c) { return e } }
            return nil
        }
        return find(env.hosting)
    }

    /// Oberstes vorgestelltes Blatt (nil: keins)
    private func presented(_ env: HostedEnvironment) -> UIViewController? {
        func top(_ vc: UIViewController) -> UIViewController? {
            if let p = vc.presentedViewController, !p.isBeingDismissed { return top(p) ?? p }
            for c in vc.children { if let p = top(c) { return p } }
            return nil
        }
        return top(env.hosting)
    }

    /// Kennung eines Elements; SwiftUI-Elemente melden sie ohne erklaerte Protokoll-Konformitaet
    static func ident(_ o: NSObject) -> String? {
        if let id = (o as? UIAccessibilityIdentification)?.accessibilityIdentifier { return id }
        let sel = NSSelectorFromString("accessibilityIdentifier")
        guard o.responds(to: sel) else { return nil }
        return o.perform(sel)?.takeUnretainedValue() as? String
    }

    private func elements(in root: UIView) -> [NSObject] {
        root.layoutIfNeeded()
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 45 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                if o.accessibilityLabel?.isEmpty == false || Self.ident(o)?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews where !s.isHidden { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return out
    }

    /// Alle Elemente im Fenster (auch in Blaettern)
    private func all(_ env: HostedEnvironment) -> [NSObject] { elements(in: env.window) }

    private func labels(_ env: HostedEnvironment) -> [String] { all(env).compactMap(\.accessibilityLabel) }

    private func element(_ env: HostedEnvironment, label: String? = nil, id: String? = nil) -> NSObject? {
        all(env).first { e in
            (label == nil || e.accessibilityLabel == label) && (id == nil || Self.ident(e) == id)
        }
    }

    /// Knopf antippen (Bedienungshilfe "aktivieren"); Knoepfe der Navigationsleiste tragen im Baum nicht immer die
    /// Eigenschaft "Taste", dann das erste passende Element, das sich aktivieren laesst
    @discardableResult
    private func tap(_ env: HostedEnvironment, label: String? = nil, id: String? = nil) -> Bool {
        let matches = all(env).filter { e in (label == nil || e.accessibilityLabel == label) && (id == nil || Self.ident(e) == id) }
        for e in matches where e.accessibilityTraits.contains(.button) { if e.accessibilityActivate() { return true } }
        for e in matches where !e.accessibilityTraits.contains(.button) { if e.accessibilityActivate() { return true } }
        // Knopf der Navigationsleiste (UIKit): Aktion direkt ausloesen
        if let c = matches.compactMap({ $0 as? UIControl }).first {
            c.sendActions(for: .touchUpInside)
            c.sendActions(for: .primaryActionTriggered)
            return true
        }
        return false
    }

    private func dump(_ env: HostedEnvironment) -> String {
        all(env).map { "\($0.accessibilityLabel ?? "-") [\(Self.ident($0) ?? "")]" }.joined(separator: "\n")
    }

    // MARK: - Kompakt (iPhone 17, 402x874)

    /// Oben Zurueck und "…", unten Seiten, "Blättern / Zeichnen" und KI-Hilfe; keine iPad-Knoepfe (Geteilt, Teilen,
    /// Ebenen, Nur Stift), keine Seitenspalte; nichts ragt ueber den Rand
    func testCompactToolbarAndBottomBar() throws {
        let (env, _) = try host(compact: true)
        XCTAssertTrue(env.wait { self.element(env, id: "doc.bottomBar") != nil }, dump(env))
        let l = labels(env)
        for needed in ["Zurück", "Mehr", "Seiten", "Blättern", "Zeichnen", "KI-Hilfe"] {
            XCTAssertTrue(l.contains(needed), "\(needed) fehlt\n" + dump(env))
        }
        for absent in ["Nur Stift", "Finger zeichnet", "Teilen", "Ebenen", "Suchen", "Vorlesung bis hier"] {
            XCTAssertFalse(l.contains(absent), "\(absent) gehoert kompakt ins Menue bzw. gibt es nicht")
        }
        XCTAssertFalse(l.contains { $0.hasPrefix("Geteilt") }, "kein Daneben öffnen auf dem iPhone")
        XCTAssertNil(element(env, id: "doc.pagesColumn"), "keine Seitenspalte")
        XCTAssertEqual(element(env, label: "Seiten")?.accessibilityValue, "Seite 1 von 3")
        XCTAssertNil(element(env, id: "doc.objectTools"), "Werkzeuge erst beim Zeichnen")
        // nichts ueber den Rand (Leiste unten, Knoepfe oben)
        let screen = env.window.bounds
        for e in all(env) where e.accessibilityTraits.contains(.button) {
            let f = env.window.convert(e.accessibilityFrame, from: nil)
            guard f.width > 0 else { continue }
            XCTAssertLessThanOrEqual(f.maxX, screen.maxX + 1, "\(e.accessibilityLabel ?? "?") ragt rechts heraus: \(f)")
            XCTAssertGreaterThanOrEqual(f.minX, -1, "\(e.accessibilityLabel ?? "?") ragt links heraus: \(f)")
        }
        // Leiste unten liegt unten im Bild
        let bar = try XCTUnwrap(element(env, id: "doc.bottomBar"))
        XCTAssertGreaterThan(env.window.convert(bar.accessibilityFrame, from: nil).minY, screen.height * 0.8)
        XCTAssertNil(presented(env))
    }

    /// "Zeichnen": ein Finger schreibt (`.anyInput`), Palette erlaubt, Werkzeuge in der Leiste; "Blättern": wieder
    /// `.pencilOnly` ohne Palette. Jedes Dokument beginnt mit "Blättern", der gemerkte iPad-Schalter bleibt unberuehrt.
    func testDrawToggleChangesDrawingPolicy() throws {
        let stored = UserDefaults.standard.object(forKey: "uniflow.pencilOnly")
        addTeardownBlock { UserDefaults.standard.set(stored, forKey: "uniflow.pencilOnly") }
        UserDefaults.standard.set(true, forKey: "uniflow.pencilOnly")
        let (env, _) = try host(compact: true)
        let vc = try XCTUnwrap(editor(env))
        XCTAssertTrue(env.wait { vc.overlayForTesting(at: 0) != nil })
        let overlay = try XCTUnwrap(vc.overlayForTesting(at: 0))
        XCTAssertEqual(vc.drawingPolicy, .pencilOnly, "Start: Blättern")
        XCTAssertTrue(vc.paletteSuppressed, "Blättern am iPhone: keine Palette")
        XCTAssertFalse(vc.pickerAllowed)
        XCTAssertTrue(element(env, id: "doc.mode.scroll")?.accessibilityTraits.contains(.selected) == true)

        XCTAssertTrue(tap(env, id: "doc.mode.draw"), dump(env))
        XCTAssertTrue(env.wait { vc.drawingPolicy == .anyInput }, "Zeichnen: Finger schreibt")
        XCTAssertEqual(overlay.canvas.drawingPolicy, .anyInput)
        XCTAssertFalse(vc.paletteSuppressed)
        XCTAssertTrue(vc.pickerAllowed, "Palette beim Zeichnen")
        XCTAssertFalse(vc.effectivePencilOnly, "zwei Finger blaettern")
        XCTAssertTrue(env.wait { self.element(env, id: "doc.objectTools") != nil }, "Werkzeuge beim Zeichnen\n" + dump(env))
        XCTAssertTrue(element(env, id: "doc.mode.draw")?.accessibilityTraits.contains(.selected) == true)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "uniflow.pencilOnly") as? Bool, true, "iPad-Schalter unberuehrt")

        XCTAssertTrue(tap(env, id: "doc.mode.scroll"))
        XCTAssertTrue(env.wait { vc.drawingPolicy == .pencilOnly })
        XCTAssertEqual(overlay.canvas.drawingPolicy, .pencilOnly)
        XCTAssertTrue(vc.paletteSuppressed)
        XCTAssertTrue(vc.effectivePencilOnly, "ein Finger blaettert")
        XCTAssertTrue(env.wait { self.element(env, id: "doc.objectTools") == nil })
    }

    /// Objektwerkzeug ueber die Leiste waehlen; "Blättern" beendet es wieder (sonst legte Antippen Text an)
    func testObjectToolFromBarEndsWhenScrolling() throws {
        let (env, _) = try host(compact: true)
        let vc = try XCTUnwrap(editor(env))
        XCTAssertTrue(tap(env, id: "doc.mode.draw"))
        XCTAssertTrue(env.wait { vc.drawingPolicy == .anyInput })
        vc.setObjectMode(true)
        vc.setObjectTool(.text)
        XCTAssertTrue(env.wait { vc.objects.isActive })
        XCTAssertTrue(tap(env, id: "doc.mode.scroll"))
        XCTAssertTrue(env.wait { !vc.objects.isActive || vc.objects.tool != .text }, "Objektwerkzeug beendet")
    }

    /// Ohne Plus: "Zeichnen" traegt das Schloss und oeffnet die Sperrkarte, die Eingabeart bleibt
    func testDrawWithoutPlusShowsLock() throws {
        Entitlements.shared.setPlanForTesting(.free)
        let (env, _) = try host(compact: true)
        let vc = try XCTUnwrap(editor(env))
        XCTAssertTrue(tap(env, id: "doc.mode.draw"), dump(env))
        XCTAssertTrue(env.wait { self.presented(env) != nil }, "Sperrkarte als Blatt")
        XCTAssertEqual(vc.drawingPolicy, .pencilOnly)
        XCTAssertNotNil(element(env, id: "doc.compact.lock"), "Hinweis ueber der Leiste\n" + dump(env))
    }

    /// Seiten als Blatt von unten (halb/ganz, Raster mit "+"), Miniatur antippen springt und schliesst; KI-Hilfe als
    /// Blatt mit Reitern, Eingabe und Kostenzeile; es ist hoechstens ein Blatt offen
    func testPagesAndTutorSheetsOpenAndClose() throws {
        let (env, _) = try host(compact: true)
        let vc = try XCTUnwrap(editor(env))

        XCTAssertTrue(tap(env, id: "doc.pages"), dump(env))
        XCTAssertTrue(env.wait { self.element(env, id: "doc.pagesSheet") != nil }, dump(env))
        let sheet = try XCTUnwrap(presented(env))
        let detents = sheet.sheetPresentationController?.detents.map(\.identifier) ?? []
        XCTAssertEqual(Set(detents), [.medium, .large], "halb und ganz")
        XCTAssertTrue(env.wait { self.element(env, label: "Seite anhängen") != nil }, "+-Kachel im Blatt")
        XCTAssertTrue(env.wait { self.element(env, label: "Seite 3") != nil }, dump(env))
        XCTAssertTrue(tap(env, label: "Seite 3"))
        XCTAssertTrue(env.wait { self.presented(env) == nil }, "Antippen schliesst das Blatt")
        XCTAssertTrue(env.wait { vc.currentPageIndex == 2 }, "zur Seite 3 gesprungen")

        XCTAssertTrue(tap(env, id: "doc.tutor"))
        XCTAssertTrue(env.wait { self.element(env, id: "tutor.tabs") != nil }, "KI-Hilfe im Blatt\n" + dump(env))
        let tutor = try XCTUnwrap(presented(env))
        XCTAssertEqual(Set(tutor.sheetPresentationController?.detents.map(\.identifier) ?? []), [.medium, .large])
        XCTAssertNotNil(element(env, id: "tutor.input"), "Eingabe")
        XCTAssertNotNil(element(env, id: "tutor.footer"), "Kostenzeile")
        for t in ["explain", "cards", "test"] { XCTAssertNotNil(element(env, id: "tutor.tab.\(t)"), t) }

        // Seiten aus der Leiste, waehrend die KI-Hilfe offen ist: die KI-Hilfe macht Platz
        XCTAssertTrue(tap(env, id: "doc.pages"))
        XCTAssertTrue(env.wait(timeout: 5) { self.element(env, id: "doc.pagesSheet") != nil && self.element(env, id: "tutor.tabs") == nil }, dump(env))
        XCTAssertTrue(tap(env, id: "sidebar.close"))
        XCTAssertTrue(env.wait { self.presented(env) == nil })

        // Schliessen ueber den Kopf der KI-Hilfe
        XCTAssertTrue(tap(env, id: "doc.tutor"))
        XCTAssertTrue(env.wait { self.element(env, id: "tutor.close") != nil })
        XCTAssertTrue(tap(env, id: "tutor.close"))
        XCTAssertTrue(env.wait { self.presented(env) == nil })
    }

    /// Markierter Text an die KI-Hilfe ("KI erklärt" in der Leiste "Text markieren"): oeffnet das Blatt, die PDF bleibt
    func testTutorRequestOpensSheet() throws {
        let (env, _) = try host(compact: true)
        let vc = try XCTUnwrap(editor(env))
        let page = try XCTUnwrap(vc.pdfView.document?.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: page.bounds(for: .cropBox)))
        vc.pdfView.setCurrentSelection(selection, animate: false)
        let askAI = try XCTUnwrap(vc.onAskAI, "KI fragen der Palette")
        askAI(vc.selectionAttachment())
        XCTAssertTrue(env.wait { self.element(env, id: "tutor.tabs") != nil }, "KI fragen oeffnet das Blatt\n" + dump(env))
        XCTAssertNotNil(vc.view.window, "PDF bleibt da")
    }

    /// Fenster von iPad-Breite auf iPhone-Breite (Split View, Breiten-Audit): die PDF passt sich ein, nichts ragt
    /// ueber den Rand (auch keine Kacheln von PDFKit oder Ebenen der Zeichenflaechen)
    func testResizeToPhoneWidthRefitsWithoutOverflow() throws {
        let (env, _) = try host(compact: false)
        let vc = try XCTUnwrap(editor(env))
        for width in [390.0, 402, 440] {
            env.hosting.traitOverrides.horizontalSizeClass = .compact
            env.window.frame = CGRect(x: 0, y: 0, width: width, height: 874)
            env.view.frame = env.window.bounds
            env.pump(1.2)
            XCTAssertEqual(vc.pdfView.scaleFactor, vc.pdfView.scaleFactorForSizeToFit, accuracy: 0.001, "eingepasst bei \(width)")
            let found = LayoutWidthAuditTests.overflows(in: env.window)
            XCTAssertTrue(found.isEmpty, "\(width): " + found.prefix(12).map(\.text).joined(separator: "\n"))
        }
    }

    // MARK: - iPad unveraendert (1180x820)

    func testIPadKeepsPencilOnlyAndToolbar() throws {
        let stored = UserDefaults.standard.object(forKey: "uniflow.pencilOnly")
        addTeardownBlock { UserDefaults.standard.set(stored, forKey: "uniflow.pencilOnly") }
        UserDefaults.standard.removeObject(forKey: "uniflow.pencilOnly")
        let (env, _) = try host(compact: false)
        let vc = try XCTUnwrap(editor(env))
        XCTAssertEqual(vc.drawingPolicy, .pencilOnly, "Standard am iPad: nur Stift")
        XCTAssertFalse(vc.paletteSuppressed, "iPad: Palette wie bisher")
        XCTAssertTrue(vc.pickerAllowed)
        let l = labels(env)
        for needed in ["Seiten", "Nur Stift", "Teilen", "Mehr", "Ebenen", "Suchen", "KI-Hilfe", "Vorlesung bis hier"] {
            XCTAssertTrue(l.contains(needed), "\(needed) fehlt\n" + dump(env))
        }
        XCTAssertTrue(l.contains { $0.hasPrefix("Geteilt") }, "Geteilt bleibt am iPad")
        XCTAssertTrue(l.contains { $0.hasPrefix("Seite 1 / 3") }, "Seitenanzeige unten wie bisher")
        for absent in ["Zurück", "Blättern", "Zeichnen"] { XCTAssertFalse(l.contains(absent), absent) }
        XCTAssertNil(element(env, id: "doc.bottomBar"))

        XCTAssertNil(element(env, id: "doc.pagesColumn"))

        // Schalter "Nur Stift / Finger zeichnet" (gemerkt) wirkt wie bisher auf die Zeichenflaechen
        UserDefaults.standard.set(false, forKey: "uniflow.pencilOnly")
        XCTAssertTrue(env.wait { vc.drawingPolicy == .anyInput })
        XCTAssertTrue(env.wait { self.labels(env).contains("Finger zeichnet") })
        UserDefaults.standard.set(true, forKey: "uniflow.pencilOnly")
        XCTAssertTrue(env.wait { vc.drawingPolicy == .pencilOnly })
    }

    /// iPad: Seiten und KI-Hilfe offen (wie nach "Seiten" bzw. "KI-Hilfe" in der Leiste) sind Spalten, kein Blatt;
    /// die Seitenleiste ist 200 pt breit
    func testIPadPagesAndTutorAreColumns() throws {
        UserDefaults.standard.set("pages", forKey: "UFDocPanel")
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "UFDocPanel") }
        let (env, _) = try host(compact: false)
        XCTAssertTrue(env.wait { self.element(env, id: "doc.pagesColumn") != nil }, dump(env))
        XCTAssertNil(presented(env), "Seitenleiste als Spalte, kein Blatt")
        let column = try XCTUnwrap(element(env, id: "doc.pagesColumn"))
        XCTAssertEqual(env.window.convert(column.accessibilityFrame, from: nil).width, 200, accuracy: 1)
        XCTAssertNil(element(env, id: "sidebar.close"), "kein Kopf wie im Blatt")

        UserDefaults.standard.set("tutor", forKey: "UFDocPanel")
        let (tutor, _) = try host(compact: false)
        XCTAssertTrue(tutor.wait { self.element(tutor, id: "tutor.tabs") != nil }, dump(tutor))
        XCTAssertNil(presented(tutor), "KI-Hilfe als Spalte")
        XCTAssertNotNil(element(tutor, label: "KI-Hilfe schließen"))
    }

    /// Kompaktes iPad (schmaler Split View): Leiste unten, der Schalter ist der gemerkte "Nur Stift"
    func testCompactIPadUsesStoredPencilSwitch() throws {
        let stored = UserDefaults.standard.object(forKey: "uniflow.pencilOnly")
        addTeardownBlock { UserDefaults.standard.set(stored, forKey: "uniflow.pencilOnly") }
        UserDefaults.standard.set(true, forKey: "uniflow.pencilOnly")
        let (env, _) = try host(compact: true, phone: false, size: CGSize(width: 375, height: 820))
        let vc = try XCTUnwrap(editor(env))
        XCTAssertTrue(tap(env, id: "doc.mode.draw"), dump(env))
        XCTAssertTrue(env.wait { vc.drawingPolicy == .anyInput })
        XCTAssertEqual(UserDefaults.standard.object(forKey: "uniflow.pencilOnly") as? Bool, false)
        XCTAssertFalse(vc.paletteSuppressed, "iPad mit Stift: Palette bleibt")
    }

    // MARK: - Formerkennung mit dem Finger

    /// Der Finger am iPhone darf beim Halten staerker zittern (Umkreis in Bildschirmpunkten); am iPad und mit "Blättern"
    /// bleibt der Umkreis des Stifts
    func testFingerHoldRadiusOnlyWhenFingerDraws() throws {
        let (env, _) = try host(compact: true)
        let vc = try XCTUnwrap(editor(env))
        XCTAssertEqual(vc.holdRadius, ShapeRecognizer.holdRadius, "Blättern")
        XCTAssertTrue(tap(env, id: "doc.mode.draw"))
        XCTAssertTrue(env.wait { vc.drawingPolicy == .anyInput })
        XCTAssertGreaterThanOrEqual(vc.holdRadius, ShapeRecognizer.fingerHoldRadius / max(0.1, vc.pdfView.scaleFactor) - 0.01)
        XCTAssertGreaterThan(vc.holdRadius, ShapeRecognizer.holdRadius, "kleinere Seite am iPhone: groesserer Umkreis in Seitenpunkten")

        // ein gezittertes Halten (Ausschlag bis 9 Seitenpunkte) zaehlt mit dem Finger-Umkreis, mit dem des Stifts nicht
        let now = Date()
        var points: [PKStrokePoint] = (0..<40).map { i in
            PKStrokePoint(location: CGPoint(x: 100 + Double(i) * 5, y: 200), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        for k in 0..<30 {
            let j = Double(k % 3) * 4.5
            points.append(PKStrokePoint(location: CGPoint(x: 295 + j, y: 200 + j), timeOffset: 0.4 + Double(k) * 0.03, size: CGSize(width: 3, height: 3),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: now)
        XCTAssertFalse(ShapeRecognizer.heldStill(path, minimum: 0.5, radius: ShapeRecognizer.holdRadius), "Stift-Umkreis: kein Halten erkannt")
        XCTAssertTrue(ShapeRecognizer.heldStill(path, minimum: 0.5, radius: 14), "Finger-Umkreis: Halten erkannt")
        let line = ShapeRecognizer.recognize(points.map(\.location), holdRadius: 14)
        if case .line = line {} else { XCTFail("Linie mit Finger-Zittern am Ende erkannt: \(String(describing: line))") }
    }
    // MARK: - Textdokumente (Word, PowerPoint, Transkript)

    private func textDocument(compact: Bool) throws -> HostedEnvironment {
        let t = Transport()
        t.answer("/api/files/w-1/pagetext?page=1", ["pages": 4, "text": "Kapitel 1: Grenzwerte\n\nEine Folge konvergiert, wenn ihre Glieder einem festen Wert beliebig nahe kommen."])
        t.answer("/api/files/w-1/pagetext?page=2", ["pages": 4, "text": "Kapitel 2: Reihen"])
        let meta: JSONValue = ["id": "w-1", "name": "Skript Analysis Woche 3.docx", "title": "Skript Analysis Woche 3.docx", "kind": "file",
                               "module_id": 1, "downloaded_at": "2026-10-20T10:00:00"]
        let file = try JSONDecoder().decode(LibFile.self, from: meta.serialized())
        XCTAssertEqual(file.sourceKind, "docx")
        UFCompact.phoneOverride = compact
        let env = try hostWithEnvironment(NavigationStack { TextDocumentView(file: file, api: api(t)) }.environment(\.ufAIEnabled, true),
                                          api: api(t), size: compact ? Self.phone : Self.pad)
        env.hosting.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
        env.hosting.traitOverrides.verticalSizeClass = .regular
        XCTAssertTrue(env.wait { self.element(env, id: "text.page") != nil }, dump(env))
        return env
    }

    /// Kompakt: Kopf in zwei Reihen ohne Ueberbreite, Blaettern geht, KI-Hilfe als Blatt
    func testTextDocumentCompactHeaderAndTutorSheet() throws {
        let env = try textDocument(compact: true)
        let screen = env.window.bounds
        for id in ["text.prev", "text.next", "text.original", "text.tutor"] {
            let e = try XCTUnwrap(element(env, id: id), id + "\n" + dump(env))
            let f = env.window.convert(e.accessibilityFrame, from: nil)
            XCTAssertLessThanOrEqual(f.maxX, screen.maxX + 1, "\(id) ragt heraus: \(f)")
        }
        XCTAssertEqual(element(env, id: "text.pageLabel")?.accessibilityLabel, "Seite 1 von 4")
        XCTAssertTrue(tap(env, id: "text.next"))
        XCTAssertTrue(env.wait { self.element(env, id: "text.pageLabel")?.accessibilityLabel == "Seite 2 von 4" })
        XCTAssertTrue(tap(env, id: "text.tutor"))
        XCTAssertTrue(env.wait { self.element(env, id: "tutor.tabs") != nil }, dump(env))
        XCTAssertNotNil(presented(env), "KI-Hilfe als Blatt")
        XCTAssertTrue(tap(env, id: "tutor.close"))
        XCTAssertTrue(env.wait { self.presented(env) == nil })
        if let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty {
            shot(env, "text-iphone", dir: dir)
        }
    }

    /// iPad: KI-Hilfe weiter als Spalte daneben
    func testTextDocumentRegularKeepsTutorColumn() throws {
        let env = try textDocument(compact: false)
        XCTAssertTrue(tap(env, id: "text.tutor"))
        XCTAssertTrue(env.wait { self.element(env, id: "tutor.tabs") != nil })
        XCTAssertNil(presented(env))
    }

    // MARK: - Neu aus develop (05.11.2026) auf schmaler Breite

    /// Die drei iPhones hochkant (17e, 17, 17 Pro Max)
    static let phones: [CGSize] = [CGSize(width: 390, height: 844), CGSize(width: 402, height: 874), CGSize(width: 440, height: 956)]

    /// Plan fuer "Ganze Vorlesung erklären" mit Rueckfrage zu den Kosten (zwei Teile), Antwort je Teil mit einem Block
    static let docPlan: JSONValue = [
        "intent": true, "mode": "lecture", "scope": ["kind": "all", "from": 1, "to": 3, "label": "Ganzes Dokument (Seiten 1–3)"],
        "title": "Ganze Vorlesung erklären · Ganzes Dokument (Seiten 1–3)",
        "steps": [["id": "1:lecture:1-2", "kind": "lecture", "from": 1, "to": 2, "title": "Seiten 1–2", "tasks": [], "cached": false],
                  ["id": "2:overview:1-3", "kind": "overview", "from": 1, "to": 3, "title": "Überblick und Prüfungsrelevantes", "tasks": [], "cached": false]],
        "calls": 2, "cached": 0, "estimate": ["way": "credits", "credits": 6, "calls": 2], "confirm": true, "enough": true,
        "message": "Kostet etwa 6 Credits, du hast 74. Die Teile kommen nacheinander, du kannst jederzeit stoppen.",
    ]
    static let docStep: JSONValue = [
        "step": "1:lecture:1-2",
        "blocks": [["kind": "section", "title": "Konvergenz von Folgen und die Epsilon-Definition im Detail", "from": 2, "to": 3,
                    "text": "Eine Folge konvergiert, wenn ihre Glieder dem Grenzwert beliebig nahe kommen.\n- Beispiel: $a_n = 1/n$"]],
        "stored": ["stored": false, "variant": 1, "shared": true],
    ]

    /// Segment des Umfangs waehlen ("Diese Seite | Ganzes Dokument | Seiten …"); nil = kein Segmentschalter da
    @discardableResult
    private func selectScope(_ env: HostedEnvironment, _ title: String) -> Bool {
        func find(_ v: UIView) -> UISegmentedControl? {
            if let s = v as? UISegmentedControl, (0..<s.numberOfSegments).contains(where: { s.titleForSegment(at: $0) == title }) { return s }
            for c in v.subviews { if let s = find(c) { return s } }
            return nil
        }
        guard let control = find(env.window),
              let i = (0..<control.numberOfSegments).first(where: { control.titleForSegment(at: $0) == title }) else { return false }
        control.selectedSegmentIndex = i
        control.sendActions(for: .valueChanged)
        env.pump(0.3)
        return true
    }

    private func segmented(_ env: HostedEnvironment) -> UISegmentedControl? {
        func find(_ v: UIView) -> UISegmentedControl? {
            if let s = v as? UISegmentedControl, (0..<s.numberOfSegments).contains(where: { s.titleForSegment(at: $0) == "Ganzes Dokument" }) { return s }
            for c in v.subviews where !c.isHidden { if let s = find(c) { return s } }
            return nil
        }
        return find(env.window)
    }

    /// Element liegt ganz im Bildschirm (waagerecht) und hat eine Flaeche
    private func assertInside(_ env: HostedEnvironment, id: String, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let e = element(env, id: id) else { return XCTFail("\(id) fehlt (\(context))\n" + dump(env), file: file, line: line) }
        let f = env.window.convert(e.accessibilityFrame, from: nil)
        XCTAssertGreaterThan(f.width, 1, "\(id) ohne Breite (\(context))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(f.minX, -1, "\(id) ragt links heraus (\(context)): \(f)", file: file, line: line)
        XCTAssertLessThanOrEqual(f.maxX, env.window.bounds.maxX + 1, "\(id) ragt rechts heraus (\(context)): \(f)", file: file, line: line)
    }

    private func assertNoOverflow(_ env: HostedEnvironment, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = LayoutWidthAuditTests.overflows(in: env.window)
        XCTAssertTrue(found.isEmpty, "\(context): " + found.prefix(12).map(\.text).joined(separator: "\n"), file: file, line: line)
    }

    /// KI-Hilfe als Blatt auf den drei iPhones: Umfang "Diese Seite | Ganzes Dokument | Seiten …" und die Schnellknoepfe
    /// im Blatt, "Seiten …" mit beiden Feldern, Rueckfrage zu den Kosten, Lauf mit Bloecken; der Seitenknopf eines Blocks
    /// springt zur Seite, das Blatt bleibt offen. Nichts ragt ueber den Rand.
    func testTutorSheetWholeDocumentOnPhones() throws {
        for size in Self.phones {
            let name = "\(Int(size.width))x\(Int(size.height))"
            let (env, t) = try host(compact: true, size: size)
            t.answer("/api/ai/document/plan", Self.docPlan)
            t.answer("/api/ai/document/step", Self.docStep)
            let vc = try XCTUnwrap(editor(env))
            XCTAssertTrue(tap(env, id: "doc.tutor"), dump(env))
            XCTAssertTrue(env.wait { self.segmented(env) != nil && self.element(env, id: "tutor.doc.lecture") != nil }, "Umfang im Blatt (\(name))\n" + dump(env))
            XCTAssertNotNil(presented(env), "KI-Hilfe als Blatt")
            let seg = try XCTUnwrap(segmented(env))
            XCTAssertEqual((0..<seg.numberOfSegments).map { seg.titleForSegment(at: $0) }, ["Diese Seite", "Ganzes Dokument", "Seiten …"])
            let segFrame = seg.convert(seg.bounds, to: env.window)
            XCTAssertLessThanOrEqual(segFrame.maxX, size.width + 1, "Umfang passt (\(name)): \(segFrame)")
            XCTAssertGreaterThanOrEqual(segFrame.minX, -1)
            for id in ["tutor.doc.lecture", "tutor.input"] { assertInside(env, id: id, name) }
            XCTAssertNotNil(element(env, id: "tutor.doc.tasks"), "zweiter Schnellknopf in der Reihe")
            // Blatt halb hoch: Umfang, je eine Reihe Schnellknoepfe und Knoepfe des Reiters, darunter Platz fuers Gespraech
            if let explain = element(env, id: "tutor.mode.explain"), let doc = element(env, id: "tutor.doc.lecture") {
                let a = env.window.convert(doc.accessibilityFrame, from: nil), b = env.window.convert(explain.accessibilityFrame, from: nil)
                XCTAssertLessThan(b.minY - a.maxY, 30, "Knoepfe des Reiters direkt unter den Schnellknoepfen (eine Reihe)")
                let summary = try XCTUnwrap(element(env, id: "tutor.mode.summary"))
                XCTAssertEqual(env.window.convert(summary.accessibilityFrame, from: nil).midY, b.midY, accuracy: 2, "Knoepfe des Reiters in einer Reihe")
            }
            let l = labels(env)
            XCTAssertTrue(l.contains("Ganze Vorlesung erklären") && l.contains("Alle Aufgaben erklären"), dump(env))
            assertNoOverflow(env, "KI-Hilfe \(name)")

            // "Seiten …": zwei Felder im Blatt
            XCTAssertTrue(selectScope(env, "Seiten …"))
            XCTAssertTrue(env.wait { self.element(env, id: "tutor.scope.to") != nil }, dump(env))
            for id in ["tutor.scope.from", "tutor.scope.to"] { assertInside(env, id: id, "Seiten \(name)") }
            assertNoOverflow(env, "Seiten … \(name)")
            XCTAssertTrue(selectScope(env, "Ganzes Dokument"))
            XCTAssertTrue(env.wait { self.element(env, id: "tutor.scope.to") == nil })

            // Rueckfrage zu den Kosten, dann der Lauf
            XCTAssertTrue(tap(env, id: "tutor.doc.lecture"))
            XCTAssertTrue(env.wait { self.element(env, id: "tutor.doc.start") != nil }, "Rueckfrage (\(name))\n" + dump(env))
            if let sheet = presented(env)?.sheetPresentationController {
                sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
                env.pump(0.6)
            }
            for id in ["tutor.doc.start", "tutor.doc.cancel"] { assertInside(env, id: id, "Rueckfrage \(name)") }
            XCTAssertTrue(labels(env).contains { $0.hasPrefix("Kostet etwa 6 Credits") }, dump(env))
            assertNoOverflow(env, "Rueckfrage \(name)")
            XCTAssertTrue(tap(env, id: "tutor.doc.start"))
            // die Kennung der Antwort (tutor.doc.answer) liegt ueber den Knoepfen: Seitenknopf ueber seinen Namen
            let pageButton = "Zu Seiten 2–3 springen"
            XCTAssertTrue(env.wait(timeout: 15) { self.element(env, label: pageButton) != nil && self.element(env, id: "tutor.doc.progress") == nil },
                          "Bloecke (\(name))\n" + dump(env))
            XCTAssertEqual(t.bodiesCount("/api/ai/document/step"), 2, "zwei Teile nacheinander")
            if let b = element(env, label: pageButton) {
                let f = env.window.convert(b.accessibilityFrame, from: nil)
                XCTAssertTrue(f.minX >= -1 && f.maxX <= size.width + 1, "Seitenknopf ragt heraus (\(name)): \(f)")
            }
            assertNoOverflow(env, "Bloecke \(name)")
            XCTAssertTrue(tap(env, label: pageButton))
            XCTAssertTrue(env.wait { vc.currentPageIndex == 1 }, "Seitenknopf springt zur Seite 2 (\(name))")
            XCTAssertNotNil(presented(env), "Blatt bleibt offen")
            XCTAssertTrue(tap(env, id: "tutor.close"))
            XCTAssertTrue(env.wait { self.presented(env) == nil })
            env.window.isHidden = true
        }
    }

    /// Sehr grosse Schrift (accessibility3) am iPhone: der Umfang ist ein Menue statt dreier abgeschnittener Segmente,
    /// die Schnellknoepfe bleiben im Bild; am iPad bleiben es Segmente
    func testTutorScopeIsMenuWithLargeTextOnPhone() throws {
        let (env, _) = try host(compact: true, typeSize: .accessibility3)
        env.window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge   // gilt auch im Blatt
        env.pump(0.3)
        XCTAssertTrue(tap(env, id: "doc.tutor"))
        XCTAssertTrue(env.wait { self.element(env, id: "tutor.doc.lecture") != nil }, dump(env))
        env.pump(0.4)
        XCTAssertNil(segmented(env), "kein Segmentschalter bei sehr grosser Schrift")
        XCTAssertTrue(labels(env).contains { $0.contains("Diese Seite") }, "Menue zeigt den Umfang\n" + dump(env))
        assertInside(env, id: "tutor.doc.lecture", "accessibility3")
        XCTAssertNotNil(element(env, id: "tutor.doc.tasks"))
        assertNoOverflow(env, "KI-Hilfe accessibility3")

        UserDefaults.standard.set("tutor", forKey: "UFDocPanel")
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "UFDocPanel") }
        let (pad, _) = try host(compact: false, typeSize: .accessibility3)
        pad.window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        XCTAssertTrue(pad.wait { self.segmented(pad) != nil }, "iPad: Segmente wie bisher\n" + dump(pad))
    }

    // MARK: Lösung teilen mit "Notizen und Blätter mitschicken"

    /// async-Arbeit mit laufender Hauptschleife
    private func pumping<T>(_ work: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await work()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(30)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return try XCTUnwrap(result, "Zeitueberschreitung").get()
    }

    /// Dokument im lokalen Backend mit einer beschriebenen Seitennotiz hinter Seite 1 (wie NotesExportAppTests)
    private func storeWithSideNote() throws -> (DocumentStore, APIClient) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-teilen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let backend = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-05T10:00:00")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: backend))
        let fileID = "folien-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePDF().write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Folgen und Reihen.pdf", title: "Folgen und Reihen", kind: "pdf", module_id: nil, subject: "Analysis",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-05", has_notes: nil, page_count: 3, studip_folder: nil)
        let store = try pumping { () -> DocumentStore in
            let store = DocumentStore(file: file, api: api, root: root)
            await store.load()
            await store.addBlankPage(afterKey: "p1", template: "lined")
            let keys = await store.pageStructureDocument().pageOrder.compactMap { $0["key"]?.string }
            let pts = (0..<12).map { i in
                PKStrokePoint(location: CGPoint(x: 60 + CGFloat(i) * 30, y: 200), timeOffset: Double(i) * 0.01, size: CGSize(width: 8, height: 8),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let ink = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))])
            store.canvasChanged(pageKey: keys[1], drawing: ink)
            await store.flush()
            return store
        }
        addTeardownBlock { @MainActor in await store.close() }
        return (store, api)
    }

    /// "Lösung teilen" auf den drei iPhones: Schalter "Notizen und Blätter mitschicken" im Bild, laesst sich umschalten,
    /// die Vorschau (Kacheln) und die Knoepfe ragen nicht ueber den Rand
    func testShareSheetNotesToggleOnPhones() throws {
        let (store, api) = try storeWithSideNote()
        for size in Self.phones {
            let name = "\(Int(size.width))x\(Int(size.height))"
            UFCompact.phoneOverride = true
            let env = try hostWithEnvironment(SolutionShareSheet(store: store, api: api, notebook: nil) {}, api: api, size: size)
            env.hosting.traitOverrides.horizontalSizeClass = .compact
            env.hosting.traitOverrides.verticalSizeClass = .regular
            XCTAssertTrue(env.wait(timeout: 20) {
                self.element(env, id: "share.includeNotes") != nil && self.labels(env).contains { $0.hasPrefix("Notiz zu Folie 1") }
            }, "Schalter (\(name))\n" + dump(env))
            let toggle = try XCTUnwrap(element(env, id: "share.includeNotes"), dump(env))
            XCTAssertTrue(toggle.accessibilityLabel?.hasPrefix(SolutionTexts.includeNotes) == true)
            XCTAssertTrue(labels(env).contains { $0.hasPrefix("Notiz zu Folie 1") }, "Seitennotiz in der Vorschau")
            let f = env.window.convert(toggle.accessibilityFrame, from: nil)
            XCTAssertLessThanOrEqual(f.maxX, size.width + 1, "Schalter ragt heraus (\(name)): \(f)")
            XCTAssertGreaterThanOrEqual(f.minX, -1)
            XCTAssertEqual(toggle.accessibilityValue, "1", "Standard an")
            XCTAssertTrue(toggle.accessibilityActivate())
            XCTAssertTrue(env.wait { toggle.accessibilityValue == "0" }, "umgeschaltet (\(name))")
            assertNoOverflow(env, "Lösung teilen \(name)")
            env.window.isHidden = true
        }
    }

    // MARK: In Stud.IP abgeben (Formular im Blatt)

    nonisolated private static let course = "0123456789abcdef0123456789abcdef"
    nonisolated private static let studipHost = UniversityKey.luh.profile.studipBase?.host ?? ""

    /// Erfundenes Stud.IP (UniStubProtocol, nichts geht ins Netz): Ordner mit Abgabeordner und Lizenzen
    nonisolated private static func installStudIP() {
        UniStubProtocol.install { seen in
            let p = seen.url.absoluteString.removingPercentEncoding ?? seen.url.absoluteString
            guard seen.method == "GET" else { return UniStubProtocol.Reply(status: 500) }
            if p.contains("/users/me") {
                return .text(#"{"data":{"type":"users","id":"u1","attributes":{"family-name":"Mustermann","given-name":"Erika"}}}"#,
                             headers: ["Content-Type": "application/vnd.api+json"])
            }
            if p.contains("/courses/\(course)/folders") {
                return .text("""
                {"data":[
                 {"type":"folders","id":"root","attributes":{"name":"Analysis I Übung","folder-type":"RootFolder","is-visible":true,"is-writable":false}},
                 {"type":"folders","id":"ue","attributes":{"name":"Übungen und Materialien zur Vorlesung","folder-type":"StandardFolder","is-visible":true,"is-writable":true},"relationships":{"parent":{"data":{"type":"folders","id":"root"}}}},
                 {"type":"folders","id":"hw3","attributes":{"name":"Abgabe Übungsblatt 3 (Gruppe Mittwoch)","folder-type":"HomeworkFolder","is-visible":true,"is-writable":true},"relationships":{"parent":{"data":{"type":"folders","id":"ue"}}}}
                ]}
                """, headers: ["Content-Type": "application/vnd.api+json"])
            }
            if p.contains("/terms-of-use") {
                return .text(#"{"data":[{"type":"terms-of-use","id":"SELFMADE_NONPUB","attributes":{"name":"Selbst verfasstes, nicht publiziertes Werk"}}]}"#,
                             headers: ["Content-Type": "application/vnd.api+json"])
            }
            return UniStubProtocol.Reply(status: 404)
        }
    }

    private func submitModel() throws -> StudIPSubmitModel {
        let suite = "uniflow-iphone-abgeben-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let cookie = HTTPCookie(properties: [.name: "Seminar_Session", .value: "erfunden", .domain: Self.studipHost, .path: "/", .secure: "TRUE"])!
        let deps = StudIPSubmitModel.Dependencies(
            connected: { true },
            ensureSession: { _ in .ready },
            client: {
                StudIPClient(base: StudIPSync.base, transport: URLSessionStudIPWriter(cookies: [cookie], host: Self.studipHost,
                                                                                     configuration: UniStubProtocol.configuration()),
                             pauseMillis: 0)
            },
            courses: { [.init(id: Self.course, title: "Analysis I für Ingenieurinnen und Ingenieure – Übung", moduleID: 7, kind: "uebung")] },
            makePDF: { _ in .init(data: Data("%PDF-1.4\nerfunden\n%%EOF".utf8), pages: 4) },
            defaults: defaults,
            now: { Date(timeIntervalSince1970: 1_793_890_000) })
        return StudIPSubmitModel(documentID: "doc1", documentTitle: "Übungsblatt 03", documentCourseID: Self.course, moduleID: 7, dependencies: deps)
    }

    /// Formular "In Stud.IP abgeben" auf den drei iPhones: Hinweis, Kurs, Abgabeordner, Dateiname, Schalter, Vorschau und
    /// "Jetzt abgeben" ohne Ueberbreite (lange Kurs- und Ordnernamen); es wird nichts hochgeladen
    func testStudIPSubmitFormOnPhones() throws {
        Self.installStudIP()
        addTeardownBlock { UniStubProtocol.reset() }
        for size in Self.phones {
            let name = "\(Int(size.width))x\(Int(size.height))"
            let model = try submitModel()
            let env = try hostWithEnvironment(StudIPSubmitSheet(model: model), size: size)
            env.hosting.traitOverrides.horizontalSizeClass = .compact
            env.hosting.traitOverrides.verticalSizeClass = .regular
            XCTAssertTrue(env.wait(timeout: 20) { self.labels(env).contains { $0.hasPrefix("Übungen und Materialien zur Vorlesung/Abgabe") } },
                          "Ordner (\(name))\n" + dump(env))
            env.pump(0.6)
            XCTAssertTrue(labels(env).contains { $0.hasPrefix("Die Datei wird an deine Hochschule hochgeladen") })
            assertNoOverflow(env, "Abgeben oben \(name)")
            // Formular ans Ende rollen (Listenzeilen entstehen erst im Bild)
            func scroller(_ v: UIView) -> UIScrollView? {
                if let s = v as? UIScrollView, s.contentSize.height > s.bounds.height { return s }
                for c in v.subviews { if let s = scroller(c) { return s } }
                return nil
            }
            if let list = scroller(env.window) {
                list.setContentOffset(CGPoint(x: 0, y: max(0, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)), animated: false)
                env.pump(0.6)
            }
            let l = labels(env)
            for needed in ["Notizen und Blätter mitschicken", "Jetzt abgeben"] { XCTAssertTrue(l.contains { $0.hasPrefix(needed) }, "\(needed) (\(name))\n" + dump(env)) }
            assertNoOverflow(env, "Abgeben unten \(name)")
            env.window.isHidden = true
        }
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.method != "GET" }, "nichts hochgeladen")
    }

    // MARK: - Bildschirmfotos (nur mit UF_SCREENSHOT_DIR)

    private func shot(_ env: HostedEnvironment, _ name: String, dir: String) {
        for (style, suffix) in [(UIUserInterfaceStyle.light, "hell"), (.dark, "dunkel")] {
            env.window.overrideUserInterfaceStyle = style
            env.pump(0.6)
            let w = env.window
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            let png = UIGraphicsImageRenderer(bounds: w.bounds, format: format).pngData { _ in
                _ = w.drawHierarchy(in: w.bounds, afterScreenUpdates: true)
            }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(suffix).png"))
        }
        env.window.overrideUserInterfaceStyle = .unspecified
    }

    func testScreenshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { throw XCTSkip("nur mit UF_SCREENSHOT_DIR") }
        let (env, _) = try host(compact: true)
        shot(env, "doc-iphone-1-blaettern", dir: dir)
        XCTAssertTrue(tap(env, id: "doc.mode.draw"))
        env.pump(0.5)
        shot(env, "doc-iphone-2-zeichnen", dir: dir)
        if let vc = editor(env) { vc.setObjectMode(true); vc.setObjectTool(.markup) }
        env.pump(0.5)
        shot(env, "doc-iphone-3-markieren", dir: dir)
        if let vc = editor(env) { vc.finishObjectTools() }
        XCTAssertTrue(tap(env, id: "doc.mode.scroll"))
        XCTAssertTrue(tap(env, id: "doc.pages"))
        XCTAssertTrue(env.wait { self.element(env, label: "Seite anhängen") != nil })
        env.pump(1.5)
        shot(env, "doc-iphone-4-seiten", dir: dir)
        XCTAssertTrue(tap(env, id: "sidebar.close"))
        XCTAssertTrue(env.wait { self.presented(env) == nil })
        XCTAssertTrue(tap(env, id: "doc.tutor"))
        XCTAssertTrue(env.wait { self.element(env, id: "tutor.tabs") != nil })
        env.pump(0.8)
        shot(env, "doc-iphone-5-ki-hilfe", dir: dir)
        if let tutor = presented(env)?.sheetPresentationController {
            tutor.animateChanges { tutor.selectedDetentIdentifier = .large }
        }
        env.pump(0.8)
        shot(env, "doc-iphone-6-ki-hilfe-gross", dir: dir)

        Entitlements.shared.setPlanForTesting(.free)
        let (free, _) = try host(compact: true)
        shot(free, "doc-iphone-7-free", dir: dir)

        Entitlements.shared.setPlanForTesting(.plus)
        let (pad, _) = try host(compact: false)
        shot(pad, "doc-ipad-regular", dir: dir)
    }

    // MARK: - Fixieren (iPhone, docs/FIXIEREN-ABPAUSEN-2026-11-05.md)

    /// Eintrag im Abschnitt "Bildschirm fixieren" des Menues "…"
    private func freezeAction(_ env: HostedEnvironment, _ title: String) -> UIAction? {
        guard let m = LayoutWidthAuditTests.menu(in: env.window, titled: FreezeTexts.introTitle) else { return nil }
        return LayoutWidthAuditTests.actions(in: m).first { $0.title == title }
    }

    private func introSeen(_ seen: Bool) {
        let before = UserDefaults.standard.object(forKey: EditorFreeze.introSeenKey)
        UserDefaults.standard.set(seen, forKey: EditorFreeze.introSeenKey)
        addTeardownBlock { UserDefaults.standard.set(before, forKey: EditorFreeze.introSeenKey) }
    }

    /// VoiceOver-Aktion eines Elements, dessen Name `label` enthaelt
    private func customAction(_ env: HostedEnvironment, label: String, action: String) -> UIAccessibilityCustomAction? {
        all(env).first { ($0.accessibilityLabel ?? "").contains(label) }?.accessibilityCustomActions?.first { $0.name == action }
    }

    /// "Ansicht fixieren" aus dem Menue "…": Zoom und Scrollen gesperrt, im Modus "Zeichnen" schreibt der Finger weiter
    /// (Eingabeart `.anyInput`, die Beruehrung trifft die Zeichenflaeche), die untere Leiste bleibt; "Lösen" gibt frei
    func testFreezeViewFromMenuKeepsFingerDrawing() throws {
        introSeen(true)
        let (env, _) = try host(compact: true)
        let vc = try XCTUnwrap(editor(env))
        XCTAssertTrue(env.wait(timeout: 10) { self.freezeAction(env, FreezeTexts.fixView) != nil }, LayoutWidthAuditTests.barDiagnose(env.window))
        XCTAssertNotNil(freezeAction(env, FreezeTexts.trace), "beide Stufen im Menü")
        XCTAssertTrue(tap(env, id: "doc.mode.draw"), dump(env))
        XCTAssertTrue(env.wait { vc.drawingPolicy == .anyInput })
        XCTAssertTrue(env.wait { vc.overlayForTesting(at: vc.currentPageIndex) != nil })
        let overlay = try XCTUnwrap(vc.overlayForTesting(at: vc.currentPageIndex))
        let scale = vc.pdfView.scaleFactor

        try XCTUnwrap(freezeAction(env, FreezeTexts.fixView)).ufRun()
        XCTAssertTrue(env.wait { vc.freezeMode == .view }, "fixiert")
        XCTAssertTrue(env.wait { self.labels(env).contains { $0.contains(FreezeTexts.badge) } }, dump(env))
        let scroll = try XCTUnwrap(vc.firstScrollView(in: vc.pdfView))
        XCTAssertFalse(scroll.isScrollEnabled, "kein Scrollen, auch nicht mit zwei Fingern")
        XCTAssertEqual(scroll.pinchGestureRecognizer?.isEnabled, false, "kein Zoom")
        // Finger zeichnet weiter
        XCTAssertEqual(vc.drawingPolicy, .anyInput)
        XCTAssertEqual(overlay.canvas.drawingPolicy, .anyInput)
        XCTAssertTrue(overlay.canvas.isUserInteractionEnabled)
        XCTAssertTrue(overlay.canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(vc.pdfView.isUserInteractionEnabled)
        XCTAssertTrue(vc.pickerAllowed, "Palette beim Zeichnen")
        let mid = overlay.canvas.convert(CGPoint(x: overlay.canvas.bounds.midX, y: overlay.canvas.bounds.midY), to: env.window)
        let visible = vc.pdfView.convert(vc.pdfView.bounds, to: env.window)
        let p = visible.contains(mid) ? mid : CGPoint(x: visible.midX, y: visible.midY)
        XCTAssertTrue(env.window.hitTest(p, with: nil)?.isDescendant(of: overlay.canvas) == true, "Finger trifft die Zeichenflaeche")
        XCTAssertNotNil(element(env, id: "doc.bottomBar"), "untere Leiste bleibt beim Fixieren")
        vc.pdfView.scaleFactor = scale * 1.6
        env.pump(0.3)
        XCTAssertEqual(vc.pdfView.scaleFactor, scale, accuracy: 0.001, "Zoom bleibt")
        let found = LayoutWidthAuditTests.overflows(in: env.window).map(\.text)
        XCTAssertTrue(found.isEmpty, found.prefix(10).joined(separator: "\n"))

        let release = try XCTUnwrap(customAction(env, label: FreezeTexts.badge, action: FreezeTexts.release), dump(env))
        _ = release.actionHandler?(release)
        XCTAssertTrue(env.wait { vc.freezeMode == .off })
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertEqual(vc.drawingPolicy, .anyInput, "Zeichnen bleibt gewählt")
    }

    /// "Zum Abpausen einfrieren": Kopfzeile und untere Leiste weg, keine Eingabe in der PDF, das Schloss liegt im
    /// Fenster (nicht in der Ecke unter der Kamera) und ist gross genug zum Halten; Entsperren bringt die Leisten zurueck
    func testTraceHidesBottomBarAndLockStaysReachable() throws {
        introSeen(true)
        let (env, _) = try host(compact: true)
        let vc = try XCTUnwrap(editor(env))
        XCTAssertTrue(env.wait(timeout: 10) { self.freezeAction(env, FreezeTexts.trace) != nil }, LayoutWidthAuditTests.barDiagnose(env.window))
        try XCTUnwrap(freezeAction(env, FreezeTexts.trace)).ufRun()
        XCTAssertTrue(env.wait { vc.freezeMode == .trace })
        XCTAssertTrue(env.wait { self.element(env, id: "doc.bottomBar") == nil }, "untere Leiste weg\n" + dump(env))
        XCTAssertFalse(labels(env).contains("Mehr"), "keine Kopfzeile")
        XCTAssertFalse(labels(env).contains("KI-Hilfe"))
        XCTAssertFalse(vc.pdfView.isUserInteractionEnabled, "keine Eingabe")
        XCTAssertFalse(vc.pickerAllowed, "keine Palette")
        let lock = try XCTUnwrap(element(env, label: FreezeTexts.lockLabel), dump(env))
        let f = env.window.convert(lock.accessibilityFrame, from: nil)
        let safe = env.window.bounds.inset(by: env.window.safeAreaInsets)
        XCTAssertTrue(safe.insetBy(dx: 4, dy: 4).contains(f), "Schloss im sicheren Bereich: \(f) in \(safe)")
        XCTAssertGreaterThanOrEqual(f.width, 44, "gross genug zum Halten")
        XCTAssertGreaterThanOrEqual(f.height, 44)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "Bildschirm bleibt an")

        let unlock = try XCTUnwrap(customAction(env, label: FreezeTexts.lockLabel, action: FreezeTexts.unlockAction))
        _ = unlock.actionHandler?(unlock)
        XCTAssertTrue(env.wait { vc.freezeMode == .off })
        XCTAssertTrue(env.wait { self.element(env, id: "doc.bottomBar") != nil }, "Leiste zurueck\n" + dump(env))
        XCTAssertTrue(vc.pdfView.isUserInteractionEnabled)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    /// Erklaerung beim ersten Mal als Blatt von unten: Texte ohne Stift und Tastatur, Knoepfe untereinander in voller
    /// Breite, nichts zu breit; "Zum Abpausen einfrieren" startet
    func testFreezeIntroOnPhone() throws {
        introSeen(false)
        let (env, _) = try host(compact: true)
        let vc = try XCTUnwrap(editor(env))
        XCTAssertTrue(env.wait(timeout: 10) { self.freezeAction(env, FreezeTexts.fixView) != nil })
        try XCTUnwrap(freezeAction(env, FreezeTexts.fixView)).ufRun()
        // Knoepfe im Blatt (die Kennung des Dialogs ueberdeckt die der Knoepfe)
        func introButton(_ title: String) -> NSObject? {
            guard let p = self.presented(env) else { return nil }
            return self.elements(in: p.view).first { $0.accessibilityLabel == title && $0.accessibilityTraits.contains(.button) }
        }
        XCTAssertTrue(env.wait(timeout: 10) { introButton(FreezeTexts.trace) != nil }, dump(env))
        env.pump(0.6)
        XCTAssertTrue(labels(env).contains { $0.contains("schreibt der Finger") }, dump(env))
        XCTAssertFalse(labels(env).contains { $0.contains("⌘L") || $0.contains("Apple Pencil") })
        let trace = try XCTUnwrap(introButton(FreezeTexts.trace))
        let view = try XCTUnwrap(introButton(FreezeTexts.fixView))
        XCTAssertGreaterThan(trace.accessibilityFrame.width, 280, "volle Breite")
        XCTAssertGreaterThan(view.accessibilityFrame.minY, trace.accessibilityFrame.maxY - 1, "untereinander")
        let found = LayoutWidthAuditTests.overflows(in: env.window).map(\.text).filter { !$0.contains("UIDimmingView") }
        XCTAssertTrue(found.isEmpty, found.prefix(10).joined(separator: "\n"))
        XCTAssertEqual(vc.freezeMode, .off, "erst nach der Wahl")
        XCTAssertTrue(trace.accessibilityActivate())
        XCTAssertTrue(env.wait { vc.freezeMode == .trace })
        XCTAssertTrue(UserDefaults.standard.bool(forKey: EditorFreeze.introSeenKey))
        let unlock = try XCTUnwrap(customAction(env, label: FreezeTexts.lockLabel, action: FreezeTexts.unlockAction))
        _ = unlock.actionHandler?(unlock)
        XCTAssertTrue(env.wait { vc.freezeMode == .off })
    }
}

private extension UIAction {
    /// Menueeintrag ausloesen wie ein Tippen (UIMenuLeaf performWithSender:target:)
    func ufRun() {
        _ = (self as NSObject).perform(NSSelectorFromString("performWithSender:target:"), with: nil, with: nil)
    }
}
