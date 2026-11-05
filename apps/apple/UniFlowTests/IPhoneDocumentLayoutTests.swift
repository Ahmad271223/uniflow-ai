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
            let (answer, bytes) = lock.withLock { (canned[path + query] ?? canned[path], raw[path]) }
            if let bytes {
                return (bytes.data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": bytes.type])!)
            }
            let data = (answer ?? ["detail": "Testfehler"]).serialized()
            return (data, HTTPURLResponse(url: request.url!, statusCode: answer == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }

        func answer(_ path: String, _ v: JSONValue) { lock.withLock { canned[path] = v } }
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
    private func host(compact: Bool, phone: Bool? = nil, size: CGSize? = nil) throws -> (HostedEnvironment, Transport) {
        let (t, file) = try document()
        UFCompact.phoneOverride = phone ?? compact
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: file, api: api(t)) }.environment(\.ufAIEnabled, true),
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
        askAI()
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
}
