import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// KI-Start, Feinschliff 04.11.2026: die Hilfe ohne KI (fester Inhalt, 0 Credits, Beispiel-Fragen ins Feld), das
/// angehaengte Dokument (Vorgabe als Chip, Entfernen, Waehler der Moduldateien, file_id in der Anfrage) und die
/// Anordnung der Aktionen (Reihe bzw. Spalte). Gegen einen Schein-Transport; kein Netz, keine KI.
@MainActor
final class AIStartPolishAppTests: XCTestCase {

    final class Transport: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var canned: [String: JSONValue] = [:]
        private var log: [(method: String, path: String, body: JSONValue?)] = []

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
            let answer: JSONValue? = lock.withLock {
                log.append((request.httpMethod ?? "GET", path, body))
                return canned[path]
            }
            let data = (answer ?? ["detail": .string("Testfehler")]).serialized()
            return (data, HTTPURLResponse(url: request.url!, statusCode: answer == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }

        func answer(_ path: String, _ v: JSONValue) { lock.withLock { canned[path] = v } }
        func count(_ method: String, _ path: String) -> Int { lock.withLock { log.filter { $0.method == method && $0.path == path }.count } }
        func bodies(_ path: String) -> [JSONValue] { lock.withLock { log.filter { $0.path == path }.compactMap(\.body) } }
    }

    private let modules: JSONValue = [["id": 1, "name": "Testmathematik I", "color": "#4f5bd5"], ["id": 2, "name": "Testphysik", "color": "#1f9d5b"]]
    private let files: [JSONValue] = [
        ["id": "f-1", "name": "VL01.pdf", "title": "VL01.pdf", "ai_title": "Folgen und Grenzwerte", "module_id": 1, "downloaded_at": "2026-10-20T10:00:00",
         "kind": "pdf", "last_opened": "2026-10-30T10:00:00", "page_count": 12, "chdate": 1_761_000_000, "doc_type": "vorlesung"],
        ["id": "f-2", "name": "Blatt01.pdf", "title": "Blatt01.pdf", "module_id": 1, "downloaded_at": "2026-10-21T10:00:00", "kind": "pdf",
         "page_count": 3, "chdate": 1_761_100_000, "doc_type": "uebung"],
        ["id": "f-3", "name": "nicht-geladen.pdf", "module_id": 1, "kind": "pdf", "chdate": 1_761_200_000],
        ["id": "f-4", "name": "Physik.pdf", "module_id": 2, "downloaded_at": "2026-10-22T10:00:00", "kind": "pdf", "page_count": 1, "chdate": 1_761_300_000],
    ]

    private func transport() -> Transport {
        let t = Transport()
        t.answer("/api/modules", modules)
        t.answer("/api/library", ["files": .array(files), "modules": [], "folders": [], "trash": []])
        t.answer("/api/ai/tutor", ["answer": "Eine **Folge** ist eine Abbildung von ℕ nach ℝ.", "cards": .null, "sources": []])
        return t
    }

    private func api(_ t: Transport) -> APIClient { APIClient(base: URL(string: "http://erfunden.test/")!, transport: t) }

    private func suite() throws -> UserDefaults {
        let name = "uniflow.tests.aistart.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func start(_ t: Transport) throws -> HostedEnvironment {
        let view = AIStartView(entitlements: Entitlements(observe: false, plan: .plus), recents: AIRecents(defaults: try suite(), scope: "p"))
            .environment(\.ufAIEnabled, true)
        return try hostWithEnvironment(view, api: api(t))
    }

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    // MARK: Elemente (wie AIViewsAppTests)

    private func elements(in view: UIView) -> [NSObject] {
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

    private func texts(_ view: UIView) -> [String] {
        elements(in: view).flatMap { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 } }.filter { !$0.isEmpty }
    }

    private func shows(_ view: UIView, _ text: String) -> Bool { texts(view).contains { $0.contains(text) } }

    private func button(_ label: String, in view: UIView, exact: Bool = true) -> NSObject? {
        elements(in: view).first { e in
            guard e.accessibilityTraits.contains(.button), let l = e.accessibilityLabel else { return false }
            return exact ? l == label : l.hasPrefix(label)
        }
    }

    @discardableResult
    private func tap(_ label: String, in view: UIView, exact: Bool = true) -> Bool {
        for e in elements(in: view) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, exact ? l == label : l.contains(label) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    // MARK: - Reine Entscheidungen

    func testHelpContentIsStaticHonestAndGerman() {
        XCTAssertEqual(AIHelpContent.sections.map(\.title), ["Was die KI-Hilfe kann", "So fängst du an", "Ohne Unterlagen"])
        XCTAssertEqual(AIHelpContent.examples.count, 5)
        XCTAssertEqual(Set(AIHelpContent.examples).count, 5, "fuenf verschiedene Beispiele")
        XCTAssertEqual(AIHelpContent.costLine, "ohne KI · 0 Credits")
        // ein Punkt je Modus der KI-Hilfe: erklaeren, einfach, loesen, Hinweise, pruefen, Begriffe, Karteikarten, Wochentest
        let can = AIHelpContent.can.items.joined(separator: " ")
        for word in ["erklären", "einfach", "Schritt für Schritt", "Hinweise", "prüfen", "Fachbegriffe", "Karteikarten", "Wochentest"] {
            XCTAssertTrue(can.contains(word), word)
        }
        XCTAssertTrue(AIHelpContent.without.items.joined().contains("Stud.IP"))
        XCTAssertTrue(AIHelpContent.without.items.joined().contains("Learnweb"))
        // ehrlich: nichts, was die App nicht hat
        let all = AIHelpContent.allText.lowercased()
        for missing in ["aufnahme", "aufzeichn", "webseite", "website", "url", "youtube", "kamera", "foto"] {
            XCTAssertFalse(all.contains(missing), "verspricht \(missing)")
        }
        // deutsche Umlaute statt Umschrift
        for ascii in ["fuer", "koennen", "waehl", "erklaer", "pruef", "loes"] {
            XCTAssertFalse(all.contains(ascii), "Umschrift \(ascii) im sichtbaren Text")
        }
        for e in AIHelpContent.examples { XCTAssertTrue(e.hasSuffix(".") || e.hasSuffix("?"), e) }
    }

    func testActionsLayoutDecision() {
        XCTAssertEqual(AIStartView.actionsLayout(width: 1180, typeSize: .large), .row, "iPad quer: eine Reihe")
        XCTAssertEqual(AIStartView.actionsLayout(width: 834, typeSize: .large), .row, "iPad hoch: Reihe, bricht bei Bedarf um")
        XCTAssertEqual(AIStartView.actionsLayout(width: 834, typeSize: .xxxLarge), .row)
        XCTAssertEqual(AIStartView.actionsLayout(width: 500, typeSize: .large), .stack, "schmal: eine Spalte in voller Breite")
        XCTAssertEqual(AIStartView.actionsLayout(width: 1180, typeSize: .accessibility1), .stack, "sehr grosse Schrift: Spalte, nichts gekuerzt")
        XCTAssertEqual(AIStartView.actionsLayout(width: 1180, typeSize: .accessibility5), .stack)
    }

    func testAttachmentState() {
        let docs = AIStartView.documents(files, module: 1)
        XCTAssertEqual(docs.compactMap { $0.s("id") }, ["f-1", "f-2"])
        XCTAssertEqual(AIStartView.attachment(fileID: "f-1", documents: docs), AIAttachment(id: "f-1", title: "Folgen und Grenzwerte", hint: "zuletzt geöffnet"))
        XCTAssertEqual(AIStartView.attachment(fileID: "f-1", documents: docs)?.label, "Folgen und Grenzwerte · zuletzt geöffnet")
        XCTAssertEqual(AIStartView.attachment(fileID: "f-2", documents: docs), AIAttachment(id: "f-2", title: "Blatt01.pdf", hint: nil), "gewaehlt: kein Hinweis")
        XCTAssertNil(AIStartView.attachment(fileID: "", documents: docs), "entfernt")
        XCTAssertNil(AIStartView.attachment(fileID: "f-4", documents: docs), "Dokument eines anderen Moduls")
        XCTAssertNil(AIStartView.attachment(fileID: "f-1", documents: []))
        // ohne last_opened: das neueste Dokument des Moduls ist die Vorgabe
        let physik = AIStartView.documents(files, module: 2)
        XCTAssertEqual(AIStartView.attachment(fileID: "f-4", documents: physik)?.hint, "neuestes Dokument")
        XCTAssertEqual(AIDocumentPicker.subtitle(files[0]), "Vorlesungen · 12 Seiten · zuletzt geöffnet")
        XCTAssertEqual(AIDocumentPicker.subtitle(files[1]), "Übungen · 3 Seiten")
        XCTAssertEqual(AIDocumentPicker.subtitle(files[3]), "1 Seite")
        XCTAssertEqual(AIDocumentPicker.subtitle(["id": "x"]), "")
    }

    // MARK: - Ansicht

    /// "Hilfe": Karte ohne KI-Anfrage, Beispiel ins Feld, Senden schickt genau diesen Text mit dem angehaengten Dokument
    func testHelpPillShowsCardWithoutAIAndExampleFillsTheField() throws {
        let t = transport()
        let env = try start(t)
        XCTAssertTrue(env.wait { self.button("Hilfe.", in: env.view, exact: false) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertEqual(enabledState("Frage senden", env), false, "leeres Feld: Senden gesperrt")
        XCTAssertTrue(tap("Hilfe.", in: env.view, exact: false))
        XCTAssertTrue(env.wait { self.shows(env.view, AIHelpContent.title) }, texts(env.view).joined(separator: "\n"))
        both(env, "ki-start-hilfe")
        XCTAssertTrue(shows(env.view, "Was die KI-Hilfe kann"))
        XCTAssertTrue(shows(env.view, "So fängst du an"))
        XCTAssertTrue(shows(env.view, "Ohne Unterlagen"))
        XCTAssertTrue(shows(env.view, "ohne KI · 0 Credits"))
        XCTAssertNotNil(button("Einstellungen öffnen", in: env.view))
        XCTAssertEqual(t.count("POST", "/api/ai/tutor"), 0, "Hilfe fragt keine KI")
        let example = AIHelpContent.examples[2]
        XCTAssertTrue(tap("Beispiel: \(example)", in: env.view))
        XCTAssertTrue(env.wait { self.enabledState("Frage senden", env) == true }, "Beispiel steht im Feld")
        XCTAssertTrue(tap("Frage senden", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/tutor") == 1 })
        let body = try XCTUnwrap(t.bodies("/api/ai/tutor").first)
        XCTAssertEqual(body["question"], .string(example))
        XCTAssertEqual(body["mode"], "ask")
        XCTAssertEqual(body["file_id"], "f-1", "das zuletzt geoeffnete Dokument haengt an")
        XCTAssertEqual(body["page"], 1)
        XCTAssertTrue(env.wait { self.shows(env.view, "Abbildung von ℕ nach ℝ") }, texts(env.view).joined(separator: "\n"))
        XCTAssertFalse(shows(env.view, AIHelpContent.title), "die Antwort loest die Hilfe ab")
        both(env, "ki-start-antwort")
        // Hilfe erneut und schliessen
        XCTAssertTrue(tap("Hilfe.", in: env.view, exact: false))
        XCTAssertTrue(env.wait { self.button("Hilfe schließen", in: env.view) != nil })
        XCTAssertTrue(tap("Hilfe schließen", in: env.view))
        XCTAssertTrue(env.wait { !self.shows(env.view, AIHelpContent.title) })
        XCTAssertEqual(t.count("POST", "/api/ai/tutor"), 1)
    }

    /// Chip des angehaengten Dokuments: Entfernen schickt ohne file_id, "Dokument anhängen" listet die Dateien des
    /// Moduls, die Wahl steht im Chip und in der Anfrage
    func testAttachChipRemoveAndPickAnotherDocument() throws {
        let t = transport()
        let env = try start(t)
        XCTAssertTrue(env.wait { self.button("Angehängt: Folgen und Grenzwerte · zuletzt geöffnet", in: env.view, exact: false) != nil },
                      texts(env.view).joined(separator: "\n"))
        XCTAssertNil(button("Dokument anhängen", in: env.view))
        XCTAssertTrue(tap("Dokument entfernen", in: env.view))
        XCTAssertTrue(env.wait { self.button("Dokument anhängen", in: env.view) != nil })
        XCTAssertNil(button("Angehängt:", in: env.view, exact: false))
        // Frage ohne Dokument: ueber die Hilfe ins Feld, dann senden
        XCTAssertTrue(tap("Hilfe.", in: env.view, exact: false))
        XCTAssertTrue(env.wait { self.button("Beispiel: \(AIHelpContent.examples[0])", in: env.view) != nil })
        XCTAssertTrue(tap("Beispiel: \(AIHelpContent.examples[0])", in: env.view))
        XCTAssertTrue(env.wait { self.enabledState("Frage senden", env) == true })
        XCTAssertTrue(tap("Frage senden", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/tutor") == 1 })
        XCTAssertNil(t.bodies("/api/ai/tutor").first?["file_id"], "entfernt: keine Datei in der Anfrage")
        XCTAssertTrue(env.wait { self.button("Antwort schließen", in: env.view) != nil })
        // Waehler: nur die lesbaren Dokumente des Moduls, zuletzt geoeffnete zuerst
        XCTAssertTrue(tap("Dokument anhängen", in: env.view))
        XCTAssertTrue(env.wait { self.shows(env.view, "Blatt01.pdf. Übungen · 3 Seiten") }, texts(env.view).joined(separator: "\n"))
        both(env, "ki-start-waehler")
        XCTAssertTrue(shows(env.view, "Folgen und Grenzwerte. Vorlesungen · 12 Seiten · zuletzt geöffnet"))
        XCTAssertFalse(shows(env.view, "nicht-geladen.pdf"), "nicht geladene Dateien fehlen")
        XCTAssertTrue(shows(env.view, "Physik.pdf. 1 Seite"), "„Alle Module“: auch die Dateien der anderen Module")
        XCTAssertTrue(tap("Blatt01.pdf.", in: env.view, exact: false))
        XCTAssertTrue(env.wait { self.button("Angehängt: Blatt01.pdf.", in: env.view, exact: false) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(env.wait { !self.shows(env.view, "Die KI liest die erste Seite") }, "der Waehler ist zu")
        both(env, "ki-start-waehler-zu")
        // Anschlussfrage unter der Antwort nimmt die Datei der Antwort (ohne) - eine neue Frage das gewaehlte Blatt
        XCTAssertTrue(tap("Erklären / PDF analysieren.", in: env.view, exact: false))
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/tutor") == 2 })
        let second = try XCTUnwrap(t.bodies("/api/ai/tutor").last)
        XCTAssertEqual(second["file_id"], "f-2", "das gewaehlte Dokument")
        XCTAssertEqual(second["mode"], "summary")
    }

    /// Die fuenf Pillen in der Reihe; bei sehr grosser Schrift als Spalte mit Unterzeilen, nichts gekuerzt
    func testPillsRowAndAccessibilityStack() throws {
        let t = transport()
        let env = try start(t)
        XCTAssertTrue(env.wait { self.button("Angehängt:", in: env.view, exact: false) != nil }, texts(env.view).joined(separator: "\n"))
        both(env, "ki-start")
        var seen = Set<String>()
        let order = texts(env.view)
            .filter { s in ["Fragen.", "Karteikarten.", "Erklären / PDF analysieren.", "Wochentest.", "Hilfe."].contains { s.hasPrefix($0) } }
            .map { String($0.prefix(while: { $0 != "." })) }.filter { seen.insert($0).inserted }
        XCTAssertEqual(order, ["Fragen", "Karteikarten", "Erklären / PDF analysieren", "Wochentest", "Hilfe"])
        XCTAssertTrue(shows(env.view, "Hilfe. Was die KI-Hilfe kann"))
        XCTAssertNotNil(button("Tests", in: env.view), "der Weg zurueck bleibt")
        // sehr grosse Schrift: alle Pillen erreichbar, Frage-Feld und Senden da
        let big = AIStartView(entitlements: Entitlements(observe: false, plan: .plus), recents: AIRecents(defaults: try suite(), scope: "big"))
            .environment(\.ufAIEnabled, true).environment(\.dynamicTypeSize, .accessibility3)
        let envBig = try hostWithEnvironment(big, api: api(t), size: CGSize(width: 834, height: 1194))
        XCTAssertTrue(envBig.wait { self.button("Hilfe.", in: envBig.view, exact: false) != nil }, texts(envBig.view).joined(separator: "\n"))
        for p in ["Fragen.", "Karteikarten.", "Erklären / PDF analysieren.", "Wochentest."] { XCTAssertNotNil(button(p, in: envBig.view, exact: false), p) }
        XCTAssertNotNil(button("Frage senden", in: envBig.view))
        XCTAssertTrue(envBig.wait { self.button("Angehängt:", in: envBig.view, exact: false) != nil }, texts(envBig.view).joined(separator: "\n"))
        both(envBig, "ki-start-grosse-schrift")
        // Hochformat in Standardschrift: Reihe auf zwei Zeilen
        let portrait = AIStartView(entitlements: Entitlements(observe: false, plan: .plus), recents: AIRecents(defaults: try suite(), scope: "p2"))
            .environment(\.ufAIEnabled, true)
        let envP = try hostWithEnvironment(portrait, api: api(t), size: CGSize(width: 834, height: 1194))
        XCTAssertTrue(envP.wait { self.button("Angehängt:", in: envP.view, exact: false) != nil })
        both(envP, "ki-start-hochformat")
    }

    /// Bildschirmfoto nach UF_SCREENSHOT_DIR (wenn gesetzt), hell und dunkel; scheitert nie
    private func both(_ env: HostedEnvironment, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        for (style, suffix) in [(UIUserInterfaceStyle.light, "hell"), (.dark, "dunkel")] {
            env.window.overrideUserInterfaceStyle = style
            env.pump(0.4)
            let view = env.view
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let png = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
                _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + "-" + suffix + ".png"))
        }
        env.window.overrideUserInterfaceStyle = .unspecified
    }

    private func enabledState(_ label: String, _ env: HostedEnvironment) -> Bool? {
        button(label, in: env.view).map { !$0.accessibilityTraits.contains(.notEnabled) }
    }
}
