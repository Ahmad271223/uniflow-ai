import PencilKit
import StoreKitTest
import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// App-Store-Bildschirmfotos fuer das iPad Pro 13" (2064 x 2752 hoch, 2752 x 2064 quer): die echten Ansichten der App
/// in einem Fenster von 1032 x 1376 Punkten bei Massstab 2, mit den Demo-Inhalten (`DemoContent`: erfundenes Modul
/// "Demo: Grundlagen der Informatik", kein echter Name, keine Note, kein Hochschul-Logo). Mit UF_SCREENSHOT_DIR
/// (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt der Test die PNGs dorthin, je Ansicht hell und dunkel, hoch und
/// quer: der Grundsatz ohne KI direkt in den Ordner, die KI-Bilder (KI-Start, KI-Hilfe, Wochentest; offene
/// Entscheidung A/B/C in docs/release/APP-STORE.md) getrennt unter `ki/`. Reihenfolge, Dateinamen und
/// Bildunterschriften: docs/release/SCREENSHOTS.md. Ohne UF_SCREENSHOT_DIR prueft der Test nur, dass jede Ansicht mit
/// den Demo-Inhalten erscheint.
///
/// Kein Netz: UniStubProtocol zaehlt jede Anfrage an eine Hochschule (es darf keine geben), die KI antwortet aus einem
/// Schein-Transport vor dem lokalen Backend, die Community aus einer leeren Wolke im Speicher (so erscheint die Seite
/// wie im Build mit iCloud-Container, mit den Communities der Demo-Kurse). Tarif Plus ueber `setPlanForTesting`, damit
/// Notizen und Karteikarten frei sind; die Tarifseite zeigt Free als gekauften Stand.
@MainActor
final class StoreScreenshotTests: XCTestCase {

    /// iPad Pro 13" in Punkten (x2 = 2064 x 2752 bzw. 2752 x 2064 Pixel)
    private static let portrait = CGSize(width: 1032, height: 1376)
    private static let landscape = CGSize(width: 1376, height: 1032)

    private var bed: ContainerTestBed!
    private var manager: ContainerManager!
    private var account: AccountStore!
    private var container: ActiveContainer!
    /// Zielordner aus UF_SCREENSHOT_DIR; nil = nur pruefen, keine Bilder
    private var outDir: URL?

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = true
        bed = try ContainerTestBed(name: "shots", clock: .system)
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 404) }          // jede Anfrage an eine Hochschule zaehlt
        // wie die App: der aktive Container wird veroeffentlicht, so liegen Notizen und PDF-Zwischenspeicher des
        // Editors im Container (ActiveContainer.current) und verschwinden mit dem Temp-Ordner des Tests
        manager = ContainerManager(
            base: bed.containers,
            legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
            keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock, publishesCurrent: true)
        account = bed.account(.luh)
        container = try bed.open(manager, account)
        account.markLoginDone()
        _ = try await manager.setDemo(true)
        XCTAssertTrue(manager.demoActive)
        Entitlements.shared.setPlanForTesting(.plus)
        let host = container.host
        CommunityRoute.shared.service = CloudKitCommunityService(
            cloud: EmptyCloud(), university: .luh, membership: CommunityMembership(defaults: container.defaults),
            courseKeys: { [] }, courses: { await CommunityCourses.spaces(host: host, university: UniversityKey.luh.rawValue) })
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        if let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("ki", isDirectory: true), withIntermediateDirectories: true)
            outDir = url
        }
    }

    override func tearDown() async throws {
        HostedEnvironment.accessibilityAutomation(false)
        CommunityRoute.shared.service = nil
        Entitlements.shared.setPlanForTesting(.free)
        XCTAssertEqual(UniStubProtocol.requests.count, 0, "keine Anfrage an eine Hochschule")
        manager.deactivate()
        await bed.tearDown()
        try await super.tearDown()
    }

    // MARK: - Schein-Dienste

    /// Leere Wolke im Speicher: die Community gilt als verbunden (Communities aus den Demo-Kursen), ohne iCloud
    private final class EmptyCloud: CommunityCloud, @unchecked Sendable {
        func accountStatus() async throws -> CommunityAccountStatus { .available }
        func userRecordName() async throws -> String { "_demo" }
        func save(_ record: CommunityRecord, in scope: CommunityScope) async throws -> CommunityRecord { record }
        func fetch(name: String, type: String, in scope: CommunityScope) async throws -> CommunityRecord? { nil }
        func query(_ q: CommunityQuery, in scope: CommunityScope) async throws -> [CommunityRecord] { [] }
        func delete(name: String, type: String, in scope: CommunityScope) async throws {}
    }

    /// Feste Antworten fuer einzelne Pfade (KI, Wochentest), alles andere beantwortet das lokale Backend des Containers
    private final class Intercept: APITransport, @unchecked Sendable {
        private let inner: LocalTransport
        private let lock = NSLock()
        private var canned: [String: JSONValue] = [:]
        private var hits: [String] = []

        init(_ host: LocalBackendHost) { inner = LocalTransport(host: host) }

        func answer(_ path: String, _ v: JSONValue) { lock.withLock { canned[path] = v } }
        func count(_ path: String) -> Int { lock.withLock { hits.filter { $0 == path }.count } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let v: JSONValue? = lock.withLock {
                guard let v = canned[path] else { return nil }
                hits.append(path)
                return v
            }
            guard let v else { return try await inner.send(request) }
            return (v.serialized(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                    headerFields: ["Content-Type": "application/json"])!)
        }
    }

    /// Antwort der KI-Hilfe zur Demo-Seite (erfunden, Markdown wie vom Dienst)
    private static let tutorAnswer: JSONValue = [
        "answer": """
        **Zahlensysteme in Kürze**

        Jede Zahl ist eine Summe von Potenzen ihrer Basis: dezimal Basis 10, dual Basis 2, hexadezimal Basis 16.

        - **13 dezimal** = 8 + 4 + 1 = **1101 dual** = **D hexadezimal**
        - Dezimal → dual: fortgesetzt durch 2 teilen, die Reste von unten nach oben lesen
        - Dual → dezimal: die Stellenwerte 1, 2, 4, 8 … der Einsen addieren

        **Probier es mit 42:** 42 = 32 + 8 + 2, also 101010.
        """,
        "cards": .null, "sources": [], "explain": .null,
    ]

    /// Abgegebener Wochentest zum Demo-Modul mit Auswertung und Erklaerungen (erfunden)
    private static var demoTest: JSONValue {
        let day = UFFmt.todayISO()
        return ["id": 18, "subject": .string(DemoContent.subject), "title": "Wochentest Grundlagen der Informatik – Zahlensysteme",
                "duration_min": 15, "started_at": .string(day + "T09:48:00"), "submitted_at": .string(day + "T10:02:00"),
                "week_no": 1, "auto": 0,
                "answers": ["1": "1101", "2": "Wahr", "3": "invertiert", "4": "-128 bis 127"],
                "feedback": ["total": 60, "max": 80,
                             "summary": "Drei von vier Aufgaben richtig. Das Zweierkomplement sitzt; die Umrechnung ins Hexadezimalsystem lohnt eine Wiederholung.",
                             "weak_topics": ["Hexadezimalsystem"],
                             "per_question": [["nr": 1, "points": 20, "max": 20, "feedback": "Richtig: 13 = 8 + 4 + 1."],
                                              ["nr": 2, "points": 0, "max": 20, "feedback": "255 ist hexadezimal FF, nicht F0: 15 · 16 + 15."],
                                              ["nr": 3, "points": 20, "max": 20, "feedback": "Richtig."],
                                              ["nr": 4, "points": 20, "max": 20, "feedback": "Genau, mit 8 Bit."]]],
                "questions": [
                    ["nr": 1, "type": "mc", "difficulty": "leicht", "question": "Wie lautet die Dezimalzahl 13 im Dualsystem?",
                     "options": ["1011", "1101", "1110", "1001"], "answer": "1101", "explanation": "13 = 8 + 4 + 1, also 1101.", "points": 20],
                    ["nr": 2, "type": "tf", "difficulty": "leicht", "question": "Die Dezimalzahl 255 ist hexadezimal F0.",
                     "options": ["Wahr", "Falsch"], "answer": "Falsch", "explanation": "255 = 15 · 16 + 15, also FF.", "points": 20],
                    ["nr": 3, "type": "cloze", "difficulty": "mittel", "question": "Für das Zweierkomplement werden alle Bits ___ und anschließend wird 1 addiert.",
                     "answer": "invertiert", "blank": "invertiert", "explanation": "Bits invertieren und 1 addieren.", "points": 20],
                    ["nr": 4, "type": "short", "difficulty": "mittel", "question": "Welcher Wertebereich lässt sich mit 8 Bit im Zweierkomplement darstellen?",
                     "answer": "-128 bis 127", "explanation": "2⁷ negative Zahlen, 2⁷ − 1 positive Zahlen und die Null.", "points": 20]]]
    }

    private func aiTransport() -> Intercept {
        let t = Intercept(container.host)
        t.answer("/api/ai/tutor", Self.tutorAnswer)
        t.answer("/api/tests/18", Self.demoTest)
        return t
    }

    private func aiAPI(_ t: Intercept) -> APIClient { APIClient(base: APIClient.localBase, transport: t) }

    // MARK: - Hosten und Fotografieren

    /// Die ganze App-Huelle (Seitenleiste, Kopfzeile, Seite) mit Demo-Inhalten; `ai`: KI verbunden (nur KI-Bilder).
    /// Die Demo-Leiste ("Demo-Inhalte – erfunden, ohne Hochschule", nur fuer Pruefer) ist in den Store-Bildern aus
    /// (`\.ufDemoBarHidden`, nur im Test).
    private func host<V: View>(_ view: V, api: APIClient? = nil, ai: Bool = false) throws -> HostedEnvironment {
        let root = view
            .environment(\.ufDemoActive, true)
            .environment(\.ufDemoBarHidden, true)
            .environment(\.ufAIEnabled, ai)
            .environmentObject(manager!)
            .environmentObject(account!)
        return try hostWithEnvironment(root, api: api ?? container.api, size: Self.portrait, studip: manager.studip)
    }

    /// Hell und dunkel, hoch und quer (Fensterrahmen umstellen, Hauptschleife laufen lassen); Pixelgroessen geprueft.
    /// `ink`: Zeichnungen der PencilKit-Canvas nachzeichnen (`drawHierarchy` nimmt ihre Kacheln nicht mit).
    private func shoot(_ env: HostedEnvironment, _ name: String, ki: Bool = false, ink: Bool = false, settle: Double = 1.0) {
        guard let outDir else { return }
        let folder = ki ? outDir.appendingPathComponent("ki", isDirectory: true) : outDir
        for (size, orientation) in [(Self.portrait, "portrait"), (Self.landscape, "landscape")] {
            env.window.frame = CGRect(origin: .zero, size: size)
            env.view.frame = env.window.bounds
            env.pump(settle)
            for (style, tone) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
                env.window.overrideUserInterfaceStyle = style
                env.pump(settle)
                let data = png(env.view, ink: ink)
                let file = folder.appendingPathComponent("\(name)-\(tone)-\(orientation).png")
                do { try data.write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
                if let cg = UIImage(data: data)?.cgImage {
                    XCTAssertEqual(CGSize(width: cg.width, height: cg.height), CGSize(width: size.width * 2, height: size.height * 2), file.lastPathComponent)
                } else {
                    XCTFail("\(file.lastPathComponent): kein Bild")
                }
            }
            env.window.overrideUserInterfaceStyle = .unspecified
        }
        env.window.frame = CGRect(origin: .zero, size: Self.portrait)
        env.view.frame = env.window.bounds
        env.pump(0.2)
    }

    private func png(_ view: UIView, ink: Bool) -> Data {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { ctx in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            if ink { for canvas in Self.canvases(in: view) { Self.drawInk(canvas, of: view, scale: 2, in: ctx.cgContext) } }
        }
    }

    private static func canvases(in view: UIView) -> [PKCanvasView] {
        guard !view.isHidden, view.alpha > 0 else { return [] }
        return (view as? PKCanvasView).map { [$0] } ?? view.subviews.flatMap(canvases)
    }

    /// Wie InkSnapshot: die Zeichnung der Canvas an ihre Stelle im Fenster, ueber alle Transformationen dazwischen
    private static func drawInk(_ canvas: PKCanvasView, of root: UIView, scale: CGFloat, in cg: CGContext) {
        let page = canvas.superview ?? canvas
        let o = page.convert(CGPoint.zero, to: root)
        let x = page.convert(CGPoint(x: 1, y: 0), to: root), y = page.convert(CGPoint(x: 0, y: 1), to: root)
        let t = CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
        let zoom = sqrt(abs(t.a * t.d - t.b * t.c))
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = canvas.drawing.image(from: page.bounds, scale: max(1, scale * zoom))
        }
        cg.saveGState()
        cg.concatenate(t)
        image.draw(in: page.bounds, blendMode: .multiply, alpha: 1)      // Marker lässt den Text durch, wie auf der Canvas
        cg.restoreGState()
    }

    // MARK: - Bedienungshilfen (wie AIStartPolishAppTests)

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
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

    private func texts(_ env: HostedEnvironment) -> [String] {
        elements(in: env.view).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ env: HostedEnvironment, _ text: String) -> Bool { texts(env).contains { $0.contains(text) } }

    private func dump(_ env: HostedEnvironment) -> String { texts(env).joined(separator: "\n") }

    @discardableResult
    private func tap(_ label: String, in env: HostedEnvironment, exact: Bool = true) -> Bool {
        for e in elements(in: env.view) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, exact ? l == label : l.hasPrefix(label) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    /// Wartet auf `text` (bis `timeout`), meldet den Baum beim Scheitern; dann die Zeit fuer Erscheinen-Animationen
    @discardableResult
    private func expect(_ env: HostedEnvironment, _ text: String, timeout: Double = 15, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let ok = env.wait(timeout: timeout) { self.shows(env, text) }
        XCTAssertTrue(ok, "„\(text)“ fehlt:\n" + dump(env), file: file, line: line)
        return ok
    }

    // MARK: - Handschrift auf der Demo-PDF

    /// Notizen anlegen und dabei die Hauptschleife laufen lassen. Die Tests bleiben synchron: aus einer async-Testmethode
    /// heraus treibt das verschachtelte Pumpen die `.task`-Ladevorgaenge der Ansichten nicht an (Lauf 1: die Bibliothek
    /// blieb beim Laden stehen, "Dokument wählen" statt Editor).
    private func seedNotesPumping() {
        var done = false
        var failure: String?
        Task { @MainActor in
            do { try await self.seedNotes() } catch { failure = "\(error)" }
            done = true
        }
        let end = Date().addingTimeInterval(30)
        while !done && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(done, "Notizen nicht angelegt")
        XCTAssertNil(failure, failure ?? "")
    }

    /// Notizen auf Seite 1 des Demo-Skripts, ueber denselben DocumentStore wie der Editor (Journal im Container), vor
    /// dem Oeffnen geschlossen (sonst "anderswo geoeffnet")
    private func seedNotes() async throws {
        let file = LibFile(id: "demo-skript", name: "Skript Kapitel 1 – Zahlensysteme.pdf", title: "Skript Kapitel 1 – Zahlensysteme",
                           kind: "pdf", module_id: nil, subject: DemoContent.subject, doc_type: "vorlesung", ai_title: nil, sub_label: nil,
                           downloaded_at: nil, has_notes: nil, page_count: 3, studip_folder: nil)
        let store = DocumentStore(file: file, api: container.api)
        store.saveTiming = SaveTiming(pause: 0.05, maxDelay: 0.5)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        let key = try XCTUnwrap(store.pageKey(forPageIndex: 0), "Seite 1 des Demo-Skripts")
        store.canvasChanged(pageKey: key, drawing: Self.handwriting())
        await store.flush()
        await store.close()
    }

    /// Striche in Seitenpunkten (A4 595 x 842, Ursprung oben links): Titelzeile bei y 72, Zeilen bei 112, 134, 156
    /// (`DemoContent.pdfBytes`). Marker ueber Zeile 1, Unterstreichung des Titels, Kreis um das Beispiel, Pfeil und Haken.
    private static func handwriting() -> PKDrawing {
        let pen = PKInk(.pen, color: UIColor(red: 0.13, green: 0.33, blue: 0.86, alpha: 1))
        let marker = PKInk(.marker, color: UIColor(red: 1.0, green: 0.88, blue: 0.25, alpha: 0.6))
        func line(_ from: CGPoint, _ to: CGPoint, _ n: Int = 24, wobble: CGFloat = 0) -> [CGPoint] {
            (0...n).map { i in
                let f = CGFloat(i) / CGFloat(n)
                return CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f + sin(f * 7) * wobble)
            }
        }
        func ellipse(center c: CGPoint, rx: CGFloat, ry: CGFloat) -> [CGPoint] {
            (0...48).map { i in
                let a = CGFloat(i) / 48 * 2 * .pi * 1.04 - 0.4
                return CGPoint(x: c.x + cos(a) * rx + sin(a * 3) * 1.2, y: c.y + sin(a) * ry)
            }
        }
        let strokes: [PKStroke] = [
            stroke(line(CGPoint(x: 56, y: 108), CGPoint(x: 296, y: 107)), ink: marker, width: 16, t: 790_000_000),
            stroke(line(CGPoint(x: 58, y: 80), CGPoint(x: 332, y: 82), 40, wobble: 1.4), ink: pen, width: 3, t: 790_000_010),
            stroke(ellipse(center: CGPoint(x: 178, y: 151), rx: 128, ry: 13), ink: pen, width: 2.6, t: 790_000_020),
            stroke(line(CGPoint(x: 430, y: 118), CGPoint(x: 322, y: 148), 30, wobble: 1), ink: pen, width: 2.8, t: 790_000_030),
            stroke(line(CGPoint(x: 322, y: 148), CGPoint(x: 336, y: 134), 8), ink: pen, width: 2.8, t: 790_000_031),
            stroke(line(CGPoint(x: 322, y: 148), CGPoint(x: 341, y: 150), 8), ink: pen, width: 2.8, t: 790_000_032),
            stroke(line(CGPoint(x: 28, y: 132), CGPoint(x: 37, y: 142), 8) + line(CGPoint(x: 37, y: 142), CGPoint(x: 52, y: 122), 10),
                   ink: pen, width: 3, t: 790_000_040),
        ]
        return PKDrawing(strokes: strokes)
    }

    private static func stroke(_ points: [CGPoint], ink: PKInk, width: CGFloat, t: Double) -> PKStroke {
        let pts = points.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.012, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSinceReferenceDate: t)))
    }

    /// Wartet, bis der Editor die Notizen auf einer Canvas zeigt, dann Zeit fuer die PDF-Kacheln
    private func waitForInk(_ env: HostedEnvironment, file: StaticString = #filePath, line: UInt = #line) {
        let ok = env.wait(timeout: 25) { Self.canvases(in: env.view).contains { !$0.drawing.strokes.isEmpty } }
        XCTAssertTrue(ok, "Editor zeigt die Notizen nicht:\n" + dump(env), file: file, line: line)
        env.pump(2.0)
    }

    // MARK: - Grundsatz (ohne KI)

    func test01Uebersicht() throws {
        let env = try host(MainView())
        expect(env, "Grundlagen der Informatik")
        XCTAssertFalse(shows(env, "Stud.IP verbinden"), "Demo: keine Karte zum Verbinden")
        XCTAssertFalse(shows(env, DemoTexts.barTitle), "Store-Bild ohne Demo-Leiste")
        XCTAssertFalse(shows(env, DemoTexts.barEnd), "Store-Bild ohne „Beenden“")
        shoot(env, "01-uebersicht")
    }

    /// Ordneransicht fuer den Store (ohne Hochschulname); das Regal daneben als Variante: es nennt die Hochschule des
    /// Containers ("Mein Regal · Leibniz Universität Hannover") und einen KI-Hinweis, beides nur mit Freigabe des Inhabers
    func test02Bibliothek() throws {
        let env = try host(MainView())
        // Bereich "Neue Dateien": die drei Demo-Dokumente als Karten (die Ordnerwurzel zeigt nur den Modulordner)
        env.router.go(.files(section: "new", path: nil, q: nil))
        expect(env, "Zahlensysteme")
        shoot(env, "02-bibliothek")
        env.router.go(.files(section: "shelf", path: nil, q: nil))
        expect(env, "Mein Regal")
        expect(env, "Zahlensysteme")
        shoot(env, "02b-regal")
    }

    func test03Editor() throws {
        seedNotesPumping()
        let env = try host(MainView())
        env.router.go(.doc("demo-skript"))
        waitForInk(env)
        shoot(env, "03-editor", ink: true)
    }

    func test04Lernkalender() throws {
        let env = try host(MainView())
        env.router.go(.plan())
        expect(env, "Lernkalender")
        expect(env, "Übungsblatt 1")
        shoot(env, "04-lernkalender")
    }

    func test05Stundenplan() throws {
        let env = try host(MainView())
        env.router.go(.timetable())
        expect(env, "Stundenplan")
        expect(env, "Grundlagen der Informatik")
        shoot(env, "05-stundenplan")
    }

    func test06Karteikarten() throws {
        let env = try host(MainView())
        env.router.go(.cards)
        expect(env, "heute fällig")
        expect(env, "Stapel öffnen: Skript Kapitel 1 – Zahlensysteme")       // Stapel je Demo-Datei unter "Demo Informatik"
        shoot(env, "06-karteikarten")
    }

    func test07Community() throws {
        let env = try host(MainView())
        env.router.go(.community)
        expect(env, "Deine Communities")
        expect(env, "Grundlagen der Informatik")
        shoot(env, "07-community")
    }

    /// Tarifseite wie das Blatt "Tarif wechseln" aus den Einstellungen (UniFlowApp): Free als Stand, Plus daneben.
    /// Store-Stand zum Start: Pro AI kommt erst mit dem Dienst in den Store (docs/release/APP-STORE.md), darum eine
    /// StoreKit-Sitzung aus `UniFlow.storekit` ohne das Pro-AI-Produkt - die Seite zeigt dann Free, Plus und den Hinweis.
    func test08Tarife() throws {
        let bundled = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "UniFlow", withExtension: "storekit"))
        var config = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: bundled)) as? [String: Any])
        config["subscriptionGroups"] = (config["subscriptionGroups"] as? [[String: Any]] ?? []).map { group -> [String: Any] in
            var g = group
            g["subscriptions"] = (group["subscriptions"] as? [[String: Any]] ?? []).filter { ($0["productID"] as? String) != UFPlan.proAI.productID }
            return g
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString).storekit")
        try JSONSerialization.data(withJSONObject: config).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.resetToDefaultState()
        storeSession = session

        let page = ZStack { UF.bg.ignoresSafeArea(); PlanPickerView(context: .settings, entitlements: Entitlements.shared) {} }
        let env = try host(page)
        expect(env, UFPlan.plus.name)
        expect(env, UFPlan.free.name)
        expect(env, "1,99", timeout: 10)                                      // Preis aus der StoreKit-Sitzung
        expect(env, UFPlanCatalog.proAIMissingNote)
        XCTAssertFalse(shows(env, UFPlanCatalog.proAIServiceNote), "keine Pro-AI-Karte ohne Produkt im Store")
        shoot(env, "08-tarife")
    }

    /// StoreKit-Sitzung der Tarifseite (bleibt bis zum Ende des Tests)
    private var storeSession: SKTestSession?

    func test09Einstellungen() throws {
        let env = try host(MainView())
        env.router.go(.settings(tab: "account"))
        expect(env, "Zugang & Darstellung")
        shoot(env, "09-einstellungen")
    }

    // MARK: - KI (getrennt, offene Entscheidung)

    func test11KIStart() throws {
        let t = aiTransport()
        let env = try host(MainView(), api: aiAPI(t), ai: true)
        env.router.go(.aiStart)
        XCTAssertTrue(env.wait { self.elements(in: env.view).contains { $0.accessibilityLabel?.hasPrefix("Hilfe.") == true } }, dump(env))
        XCTAssertTrue(tap("Hilfe.", in: env, exact: false))
        expect(env, AIHelpContent.title)
        // Beispielfrage ins Feld und senden: Antwort aus dem Schein-Transport
        let example = AIHelpContent.examples[0]
        if tap("Beispiel: \(example)", in: env) {
            _ = env.wait(timeout: 5) { self.elements(in: env.view).contains { $0.accessibilityLabel == "Frage senden" && !$0.accessibilityTraits.contains(.notEnabled) } }
            XCTAssertTrue(tap("Frage senden", in: env))
            XCTAssertTrue(env.wait { t.count("/api/ai/tutor") == 1 })
            expect(env, "Zahlensysteme in Kürze")
        }
        shoot(env, "11-ki-start", ki: true)
    }

    func test12KIHilfe() throws {
        seedNotesPumping()
        let t = aiTransport()
        let env = try host(MainView(), api: aiAPI(t), ai: true)
        env.router.tutorOpenRequest = "demo-skript"                       // wie "Im Dokument mit KI-Hilfe öffnen"
        env.router.go(.doc("demo-skript"))
        waitForInk(env)
        XCTAssertTrue(env.wait { self.elements(in: env.view).contains { $0.accessibilityLabel == "KI-Hilfe schließen" } }, dump(env))
        XCTAssertTrue(tap("Erklären", in: env), dump(env))
        XCTAssertTrue(env.wait { t.count("/api/ai/tutor") == 1 })
        expect(env, "Zahlensysteme in Kürze")
        env.pump(1.0)
        shoot(env, "12-ki-hilfe", ki: true, ink: true)
    }

    func test13Wochentest() throws {
        let t = aiTransport()
        let env = try host(MainView(), api: aiAPI(t), ai: true)
        env.router.go(.exam(18, task: nil))
        expect(env, "Punkte")
        expect(env, "Hexadezimalsystem")
        shoot(env, "13-wochentest", ki: true)
    }
}
