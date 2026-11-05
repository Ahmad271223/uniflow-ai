import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// KI-Bereich (03.11.2026): KI-Start (Pillen, Frage, Zuletzt, Kostenzeile), Dialog "Wochentest erstellen" (Pruefung,
/// Anfrage mit genau den Parametern des Backends, Platzhalter waehrend der Erstellung), "Karteikarten aus Dokument"
/// (Vorschau, Aendern, Streichen, Uebernehmen ueber POST /api/flashcards), Testlauf (Fortschritt, zwei grosse
/// Antworten, Ergebnisseite) und die Bausteine (Markdown, Anschlussfragen, letzte Antworten). Alles gegen einen
/// Schein-Transport mit erfundenen Antworten; kein Netz, keine KI. Mit UF_SCREENSHOT_DIR schreibt der letzte Test
/// Bilder der Ansichten in hell und dunkel.
@MainActor
final class AIViewsAppTests: XCTestCase {

    /// Schein-Transport: feste Antworten je Pfad, merkt sich Pfade und Rumpf jeder Anfrage
    final class Transport: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var canned: [String: JSONValue] = [:]
        private var status: [String: Int] = [:]
        /// Rohdaten statt JSON (Inhalt einer PDF fuer den Editor)
        private var raw: [String: (data: Data, type: String)] = [:]
        private var log: [(method: String, path: String, body: JSONValue?)] = []

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
            let (answer, code, bytes): (JSONValue?, Int, (data: Data, type: String)?) = lock.withLock {
                log.append((request.httpMethod ?? "GET", path, body))
                return (canned[path], status[path] ?? 200, raw[path])
            }
            if let bytes {
                return (bytes.data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": bytes.type])!)
            }
            let data = (answer ?? ["detail": .string("Testfehler \(code)")]).serialized()
            return (data, HTTPURLResponse(url: request.url!, statusCode: answer == nil ? 404 : code, httpVersion: nil, headerFields: nil)!)
        }

        func answer(_ path: String, _ v: JSONValue) { lock.withLock { canned[path] = v } }
        func answer(_ path: String, data: Data, type: String) { lock.withLock { raw[path] = (data, type) } }
        func fail(_ path: String, _ code: Int, _ v: JSONValue) { lock.withLock { canned[path] = v; status[path] = code } }
        func count(_ method: String, _ path: String) -> Int { lock.withLock { log.filter { $0.method == method && $0.path == path }.count } }
        func bodies(_ path: String) -> [JSONValue] { lock.withLock { log.filter { $0.path == path }.compactMap(\.body) } }
    }

    private let modules: JSONValue = [["id": 1, "name": "Testmathematik I", "color": "#4f5bd5"], ["id": 2, "name": "Testphysik", "color": "#1f9d5b"]]
    private let library: JSONValue = ["files": [
        ["id": "f-1", "name": "VL01.pdf", "title": "VL01.pdf", "ai_title": "Folgen und Grenzwerte", "module_id": 1, "downloaded_at": "2026-10-20T10:00:00",
         "kind": "pdf", "last_opened": "2026-10-30T10:00:00", "page_count": 12, "chdate": 1_761_000_000, "doc_type": "vorlesung"],
        ["id": "f-2", "name": "Blatt01.pdf", "title": "Blatt01.pdf", "module_id": 1, "downloaded_at": "2026-10-21T10:00:00", "kind": "pdf",
         "page_count": 3, "chdate": 1_761_100_000, "doc_type": "uebung"],
        ["id": "f-3", "name": "nicht-geladen.pdf", "module_id": 1, "kind": "pdf", "chdate": 1_761_200_000],
        ["id": "f-4", "name": "Physik.pdf", "module_id": 2, "downloaded_at": "2026-10-22T10:00:00", "kind": "pdf", "page_count": 40, "chdate": 1_761_300_000],
    ], "modules": [], "folders": [], "trash": []]

    private func transport() -> Transport {
        let t = Transport()
        t.answer("/api/modules", modules)
        t.answer("/api/library", library)
        t.answer("/api/flashcards", [])
        t.answer("/api/tests", [])
        t.answer("/api/bg", ["running": false, "task": .null, "message": ""])
        return t
    }

    private func api(_ t: Transport) -> APIClient { APIClient(base: URL(string: "http://erfunden.test/")!, transport: t) }

    private func suite() throws -> UserDefaults {
        let name = "uniflow.tests.ai.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func plan(_ p: UFPlan) -> Entitlements { Entitlements(observe: false, plan: p) }

    /// Bedienungshilfen-Automation einmal fuer alle Tests der Klasse (ein Umschalten je Test liess spaetere Baeume leer)
    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    // MARK: Elemente

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
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

    /// Knopf mit dieser Beschriftung (`exact: false`: Anfang der Beschriftung)
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

    /// Knopf vorhanden und nicht gesperrt (nil: kein solcher Knopf)
    private func enabled(_ label: String, in view: UIView, exact: Bool = true) -> Bool? {
        button(label, in: view, exact: exact).map { !$0.accessibilityTraits.contains(.notEnabled) }
    }

    /// Bildschirmfoto nach UF_SCREENSHOT_DIR (wenn gesetzt); scheitert nie
    private func screenshot(_ env: HostedEnvironment, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        env.pump(0.4)
        let view = env.view
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let png = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    private func both(_ env: HostedEnvironment, _ name: String) {
        env.window.overrideUserInterfaceStyle = .light
        screenshot(env, name + "-hell")
        env.window.overrideUserInterfaceStyle = .dark
        screenshot(env, name + "-dunkel")
        env.window.overrideUserInterfaceStyle = .unspecified
    }

    // MARK: - Bausteine

    func testMarkdownBlocksAndInlineStyles() {
        let text = "## Kurz gesagt\nEine Folge ist **konvergent**, wenn …\n\n- Punkt eins\n- Punkt zwei\n  mit Fortsetzung\n1. Erster Schritt\n2) Zweiter Schritt\n```\nx = 2\n```\nSchluss."
        let b = AIMarkdown.blocks(text)
        XCTAssertEqual(b, [.heading(level: 2, text: "Kurz gesagt"), .paragraph("Eine Folge ist **konvergent**, wenn …"),
                           .bullets(["Punkt eins", "Punkt zwei mit Fortsetzung"]), .numbered(["Erster Schritt", "Zweiter Schritt"]),
                           .code("x = 2"), .paragraph("Schluss.")])
        XCTAssertEqual(AIMarkdown.blocks(""), [])
        XCTAssertEqual(AIMarkdown.blocks("nur Text\nzweite Zeile"), [.paragraph("nur Text zweite Zeile")])
        XCTAssertEqual(AIMarkdown.blocks("#ohne Leerzeichen"), [.paragraph("#ohne Leerzeichen")], "kein Titel ohne Leerzeichen")
        XCTAssertEqual(AIMarkdown.blocks("* a\n\n* b"), [.bullets(["a"]), .bullets(["b"])])
        XCTAssertEqual(String(AIMarkdown.inline("**fett** und `code`").characters), "fett und code")
        // Antwortkarte zeigt die Bloecke
        let host = try? hostWithEnvironment(AIMarkdownText(text).padding())
        XCTAssertNotNil(host)
        host?.pump(0.3)
        XCTAssertTrue(shows(host!.view, "Kurz gesagt"))
        XCTAssertTrue(shows(host!.view, "Punkt zwei mit Fortsetzung"))
    }

    func testFollowUpsCostAndRecents() throws {
        XCTAssertEqual(AIFollowUps.suggest(after: "explain").map(\.label), ["Einfacher erklären", "Ein Beispiel dazu", "Fachbegriffe"])
        XCTAssertEqual(AIFollowUps.suggest(after: "flashcards"), [])
        XCTAssertTrue((2...3).contains(AIFollowUps.suggest(after: "irgendwas").count))
        for mode in AIPrompts.tutorModeKeys where mode != "flashcards" {
            let s = AIFollowUps.suggest(after: mode)
            XCTAssertTrue((2...3).contains(s.count), mode)
            for x in s { XCTAssertTrue(AIPrompts.tutorModeKeys.contains(x.mode), "\(mode): \(x.mode) ist kein Modus von app/ai.py") }
        }
        XCTAssertEqual(AICost.line(chatgpt: true, plan: .free, credits: 10), "1 Anfrage über dein ChatGPT")
        XCTAssertEqual(AICost.line(chatgpt: true, plan: .free, credits: 10, calls: 2), "2 Anfragen über dein ChatGPT")
        XCTAssertEqual(AICost.line(chatgpt: false, plan: .proAI, credits: 10), "≈ 10 Credits")
        XCTAssertEqual(AICost.line(chatgpt: true, plan: .proAI, credits: 10, adopted: true), "0 Credits (gemeinsamer Test)")
        XCTAssertEqual(AICost.line(chatgpt: false, plan: .plus, credits: 10), "Kommt mit StudiNow Pro AI", "ChatGPT ausgeschaltet")
        XCTAssertEqual(AICost.status(chatgpt: true, model: "gpt-x", plan: .plus, requestsThisMonth: 1), "1 Anfrage diesen Monat · über dein ChatGPT · gpt-x")
        // ChatGPT ausgeschaltet (`ChatGPTLink.isEnabled`, 05.11.2026): kein "Noch kein ChatGPT verbunden", der Tarif-Hinweis
        XCTAssertEqual(AICost.status(chatgpt: false, model: nil, plan: .plus, requestsThisMonth: 0), "KI kommt mit StudiNow Pro AI · 0 Anfragen diesen Monat")
        XCTAssertEqual(AICost.status(chatgpt: true, model: nil, plan: .proAI, requestsThisMonth: 3, usage: (87, 100)), "87 von 100 Credits")
        // Zuletzt: hoechstens drei, neueste zuerst, je Container, Anfragen des Monats gezaehlt
        let d = try suite()
        let r = AIRecents(defaults: d, scope: "t")
        XCTAssertEqual(r.entries, [])
        for i in 1...4 { r.record(question: "F\(i)", answer: "A\(i)", fileID: "f-\(i)") }
        XCTAssertEqual(r.entries.map(\.question), ["F4", "F3", "F2"])
        XCTAssertEqual(r.requestsThisMonth, 4)
        r.record(question: "leer", answer: "  ")
        XCTAssertEqual(r.entries.count, 3, "ohne Antwort nichts")
        r.count()
        XCTAssertEqual(r.requestsThisMonth, 5)
        let again = AIRecents(defaults: d, scope: "t")
        XCTAssertEqual(again.entries.map(\.question), ["F4", "F3", "F2"], "gespeichert")
        XCTAssertEqual(again.requestsThisMonth, 5)
        XCTAssertEqual(AIRecents(defaults: d, scope: "anderer").entries, [], "anderer Container sieht nichts")
        XCTAssertNil(UserDefaults.standard.data(forKey: AIRecents.recentKey + ":t"), "nichts in den gemeinsamen UserDefaults")
        again.clear()
        XCTAssertEqual(AIRecents(defaults: d, scope: "t").entries, [])
        XCTAssertEqual(AIRecents.month(Date(timeIntervalSince1970: 1_793_750_000)), "2026-11")
    }

    func testRouteHelpersAndLabels() {
        XCTAssertEqual(UFRoute(hash: "#/ki"), .aiStart)
        XCTAssertEqual(UFRoute.aiStart.hash, "#/ki")
        XCTAssertEqual(UFRoute.aiStart.navKey, "exams")
        XCTAssertEqual(UFRoute(hash: UFRoute.aiStart.hash), .aiStart)
        let router = UFRouter()
        router.tutorOpenRequest = "f-1"
        XCTAssertFalse(router.takeTutorOpenRequest(for: "f-2"))
        XCTAssertTrue(router.takeTutorOpenRequest(for: "f-1"))
        XCTAssertFalse(router.takeTutorOpenRequest(for: "f-1"), "einmalig")
        // gemeinsamer Test: nur wenn das Feld da ist
        XCTAssertNil(ExamsPage.sharedLabel(["id": 1]))
        XCTAssertNil(ExamsPage.sharedLabel(["id": 1, "shared": .null]))
        XCTAssertEqual(ExamsPage.sharedLabel(["shared": ["variant": 2, "of": 3, "adopted": true]]), "Gemeinsamer Test · Variante 2 von 3")
        XCTAssertEqual(ExamsPage.sharedLabel(["shared": ["adopted": false]]), "Gemeinsamer Test")
        // Phasen aus /api/bg
        XCTAssertEqual(TestGenerationState.Phase(backend: "shared_lookup"), .searching)
        XCTAssertEqual(TestGenerationState.Phase(backend: "shared_wait"), .waiting)
        XCTAssertEqual(TestGenerationState.Phase(backend: "generate"), .generating)
        XCTAssertEqual(TestGenerationState.Phase(backend: "shared_adopted"), .adopted)
        XCTAssertNil(TestGenerationState.Phase(backend: ""))
        XCTAssertEqual(TestGeneratingCard.chip(.generating, seconds: 65), "KI arbeitet · 1:05")
        XCTAssertEqual(TestGeneratingCard.chip(.adopted, seconds: 3), "0 Credits")
        // Musterloesung zu Option
        XCTAssertTrue(ExamQuestionCard.matches(option: "B) Zwei", model: "B"))
        XCTAssertTrue(ExamQuestionCard.matches(option: "Zwei", model: "zwei"))
        XCTAssertFalse(ExamQuestionCard.matches(option: "A) Eins", model: "B"))
        XCTAssertTrue(ExamQuestionCard.isTwoWay(["Wahr", "Falsch"]))
        XCTAssertFalse(ExamQuestionCard.isTwoWay(["A", "B", "C"]))
        // Seiten der Karteikarten-Anfrage
        XCTAssertEqual(FlashcardComposer.pages(from: 1, to: 10, pageCount: 12), Array(1...10))
        XCTAssertEqual(FlashcardComposer.pages(from: 8, to: 3, pageCount: 5), [3, 4, 5], "vertauscht und begrenzt")
        XCTAssertEqual(FlashcardComposer.pages(from: 1, to: 40, pageCount: nil).count, FlashcardComposer.pagesMax)
        XCTAssertEqual(FlashcardComposer.pages(from: 0, to: 0, pageCount: 3), [1])
        // Dokumente: nur geladene PDFs, zuletzt geoeffnete zuerst
        let docs = AIStartView.documents(library.list("files"), module: 1).compactMap { $0.s("id") }
        XCTAssertEqual(docs, ["f-1", "f-2"])
        XCTAssertEqual(AIStartView.documents(library.list("files"), module: 0).first?.s("id"), "f-1")
        XCTAssertEqual(AIStartView.title(library.list("files")[0]), "Folgen und Grenzwerte")
    }

    // MARK: - Dokument-Index in der KI-Hilfe

    /// Ohne verbundene KI zeigt die KI-Hilfe trotzdem, was die Bibliothek zur Seite weiss (lesen darf jeder, 0 Credits),
    /// mit dem Platz im Regal; der Weg zur Verbindung bleibt, "Neu erklaeren lassen" gibt es ohne KI nicht
    func testTutorPanelShowsKnownPageWithoutAI() throws {
        let t = transport()
        t.answer("/api/index/file/f-1/page/3", ["file_id": "f-1", "page": 3, "status": "ready", "known": true, "source": "cloud", "can_build": false,
                                                "shelf_path": ["Leibniz Universität Hannover", "Allgemein", "WiSe 2026/27", "Testmathematik I", "Woche 3 (26.10.–01.11.)", "Vorlesung"],
                                                "entry": ["summary": "Konvergenz von Folgen.", "terms": [],
                                                          "elements": [["order": 1, "type": "definition", "title": "Konvergente Folge",
                                                                        "explanation": "Grenzwert a mit |a_n − a| < ε.", "position": "oben", "uncertain": false]],
                                                          "tasks": []],
                                                "cross_refs": [], "own_notes": []])
        let env = try hostWithEnvironment(TutorPanel(fileID: "f-1", page: { 3 }, selection: { "" }, open: { _, _ in }, close: {}), api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, "Schon erklärt") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Konvergente Folge"))
        XCTAssertTrue(shows(env.view, "Im Regal: Leibniz Universität Hannover › Allgemein › WiSe 2026/27 › Testmathematik I › Woche 3 (26.10.–01.11.) › Vorlesung"),
                      texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Die KI-Hilfe kommt mit der StudiNow-KI"), "der Weg zur KI bleibt (Tarif-Hinweis)")
        XCTAssertNil(button("ChatGPT verbinden", in: env.view), "keine Anmeldung bei ChatGPT angeboten")
        XCTAssertFalse(shows(env.view, "Neu erklären lassen"), "ohne KI kein Neubau")
        XCTAssertEqual(t.count("POST", "/api/index/file/f-1/page/3"), 0, "lesen kostet nichts und fragt keine KI")
    }

    func testDocIndexCardShowsKnownPageWithReferencesNotesAndRebuild() throws {
        let t = transport()
        let ready: JSONValue = ["file_id": "f-1", "page": 2, "status": "ready", "known": true, "source": "cloud", "can_build": true,
                                "entry": ["summary": "Eigenwerte und das charakteristische Polynom.", "terms": ["Eigenwert"],
                                          "elements": [["order": 1, "type": "formel", "title": "Charakteristisches Polynom",
                                                        "explanation": "det(A − λI) = 0 liefert die Eigenwerte.", "position": "oben", "uncertain": false]],
                                          "tasks": [["label": "Aufgabe 1", "asks": "Eigenwerte einer 2×2-Matrix bestimmen"]]],
                                "cross_refs": [["order": 1, "file_id": "f-0", "page": 12, "text": "auch in Vorlesung 2, Seite 12"]],
                                "own_notes": [["page": 5, "date": "2026-10-31", "label": "31.10.", "current": false]]]
        t.answer("/api/index/file/f-1/page/2", ready)
        var opened: [(String, Int)] = []
        let env = try hostWithEnvironment(DocIndexPageCard(fileID: "f-1", page: { 2 }, open: { opened.append(($0, $1)) }).padding(), api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, "Schon erklärt") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "aus der Bibliothek · 0 Credits"))
        XCTAssertTrue(shows(env.view, "Charakteristisches Polynom"))
        XCTAssertTrue(shows(env.view, "Aufgabe 1: Eigenwerte einer 2×2-Matrix bestimmen"))
        XCTAssertTrue(shows(env.view, "auch in Vorlesung 2, Seite 12"))
        XCTAssertTrue(tap("Deine Notizen dazu vom 31.10. auf Seite 5", in: env.view, exact: false))
        XCTAssertEqual(opened.last?.0, "f-1")
        XCTAssertEqual(opened.last?.1, 5)
        XCTAssertTrue(tap("Neu erklären lassen", in: env.view, exact: false))
        XCTAssertTrue(env.wait { t.count("POST", "/api/index/file/f-1/page/2") == 1 })
        XCTAssertEqual(t.bodies("/api/index/file/f-1/page/2").last?["force"], true)
    }

    func testDocIndexCardStaysQuietWithoutIndexOrAI() throws {
        let t = transport()
        t.answer("/api/index/file/f-1/page/1", ["file_id": "f-1", "page": 1, "status": "none", "can_build": false])
        let env = try hostWithEnvironment(DocIndexPageCard(fileID: "f-1", page: { 1 }, open: { _, _ in }).padding(), api: api(t))
        XCTAssertTrue(env.wait { t.count("GET", "/api/index/file/f-1/page/1") >= 1 })
        XCTAssertFalse(shows(env.view, "Schon erklärt"))
        XCTAssertNil(button("Seite einordnen", in: env.view, exact: false), "ohne KI kein Knopf")
        XCTAssertEqual(DocIndexPageCard.noteLine(["page": 3, "label": "02.11.", "current": true]), "Deine Notizen auf dieser Seite vom 02.11.")
    }

    // MARK: - KI-Start

    func testStartPageShowsPillsAsksWithTheDocumentAndKeepsRecents() throws {
        let t = transport()
        t.answer("/api/ai/tutor", ["answer": "## Kurz\n- Die Folge konvergiert\n- Grenzwert **2**", "cards": .null, "sources": []])
        let recents = AIRecents(defaults: try suite(), scope: "t")
        let env = try hostWithEnvironment(AIStartView(entitlements: plan(.plus), recents: recents).environment(\.ufAIEnabled, true), api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, "Was möchtest du heute lernen?") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(env.wait { self.button("Wochentest.", in: env.view, exact: false) != nil })
        // vier Pillen in der Reihenfolge Fragen, Karteikarten, Erklären, Wochentest
        // der Baum nennt Elemente mehrfach (verschachtelte Container): jede Pille einmal, in der Reihenfolge des Baums
        var seen = Set<String>()
        let pills = texts(env.view).filter { t in ["Fragen.", "Karteikarten.", "Erklären / PDF analysieren.", "Wochentest."].contains { t.hasPrefix($0) } }
            .map { String($0.prefix(while: { $0 != "." })) }.filter { seen.insert($0).inserted }
        XCTAssertEqual(pills, ["Fragen", "Karteikarten", "Erklären / PDF analysieren", "Wochentest"], "Reihenfolge der Pillen")
        XCTAssertTrue(shows(env.view, "Fragen. Zur Seite"))
        XCTAssertTrue(shows(env.view, "Karteikarten. Aus einem Dokument"))
        XCTAssertTrue(shows(env.view, "Erklären / PDF analysieren"))
        XCTAssertTrue(shows(env.view, "Wochentest. 15 Aufgaben"))
        XCTAssertTrue(shows(env.view, "0 Anfragen diesen Monat · über dein ChatGPT"), "Kostenzeile ohne Credits: ueber das eigene ChatGPT")
        XCTAssertFalse(shows(env.view, "Zuletzt"), "ohne Antworten keine Zeile Zuletzt")
        // "Erklären / PDF analysieren": Zusammenfassung des zuletzt geoeffneten Dokuments
        XCTAssertTrue(tap("Erklären / PDF analysieren.", in: env.view, exact: false))
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/tutor") == 1 })
        let body = try XCTUnwrap(t.bodies("/api/ai/tutor").first)
        XCTAssertEqual(body["mode"], "summary")
        XCTAssertEqual(body["file_id"], "f-1", "das zuletzt geoeffnete Dokument des Moduls")
        XCTAssertEqual(body["page"], 1)
        XCTAssertNil(body["question"])
        XCTAssertTrue(env.wait { self.shows(env.view, "Die Folge konvergiert") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Zusammenfassung: Folgen und Grenzwerte"))
        XCTAssertTrue(shows(env.view, "Was muss ich können?"), "Anschlussfragen unter der Antwort")
        XCTAssertNotNil(button("Im Dokument mit KI-Hilfe öffnen", in: env.view))
        XCTAssertEqual(recents.entries.count, 1)
        XCTAssertEqual(recents.entries.first?.fileID, "f-1")
        XCTAssertTrue(env.wait { self.shows(env.view, "1 Anfrage diesen Monat") })
        // Gespraech offen (Neugestaltung 04.11.2026): "Zuletzt" steht erst nach "Neues Gespräch" wieder unter dem Feld
        XCTAssertEqual(recents.entries.first?.question, "Zusammenfassung: Folgen und Grenzwerte")
        XCTAssertFalse(shows(env.view, "Zuletzt: Zusammenfassung"), "im Gespraech kein Zuletzt")
        // Anschlussfrage: dieselbe Datei, mit Verlauf
        XCTAssertTrue(tap("Was muss ich können?", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/tutor") == 2 })
        let second = try XCTUnwrap(t.bodies("/api/ai/tutor").last)
        XCTAssertEqual(second["mode"], "ask")
        XCTAssertEqual(second["file_id"], "f-1")
        XCTAssertEqual(second["history"]?.array?.count, 2, "Frage und Antwort als Verlauf")
        XCTAssertTrue((second["question"]?.string ?? "").contains("können"))
        XCTAssertTrue(env.wait { recents.entries.count == 2 }, "zweite Antwort unter Zuletzt")
        // "Im Dokument mit KI-Hilfe öffnen": Route zum Dokument, Wunsch fuer den Editor gemerkt
        XCTAssertTrue(tap("Im Dokument mit KI-Hilfe öffnen", in: env.view))
        XCTAssertTrue(env.wait { env.router.route == .doc("f-1") })
        XCTAssertEqual(env.router.tutorOpenRequest, "f-1")
    }

    /// KI-Start oder Editor, je nach Route (wie MainView): "Im Dokument mit KI-Hilfe öffnen" fuehrt in den Editor
    private struct StartThenDocument: View {
        let file: LibFile
        let start: AIStartView
        @EnvironmentObject private var router: UFRouter
        @EnvironmentObject private var session: Session

        var body: some View {
            if case .doc(let id, _, _) = router.route, id == file.id, let api = session.api {
                NavigationStack { DocumentView(file: file, api: api) }
            } else {
                start
            }
        }
    }

    /// Zweiseitige PDF fuer den Editor
    private func makePDF() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for i in 1...2 {
                ctx.beginPage()
                ("Folgen Seite \(i)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
    }

    /// Geladene PDF `id` im Schein-Transport (Inhalt, leere Notizen) und als Datei der Bibliothek
    private func document(_ t: Transport, id: String) throws -> LibFile {
        t.answer("/api/files/\(id)/content", data: makePDF(), type: "application/pdf")
        t.answer("/api/files/\(id)/annotations", ["data": AnnotationDocument.emptyRoot, "version": 0, "updated_at": .null])
        let meta: JSONValue = ["id": .string(id), "name": "VL01.pdf", "title": "VL01.pdf", "kind": "pdf", "module_id": 1,
                               "downloaded_at": "2026-10-20T10:00:00", "page_count": 2, "doc_type": "vorlesung"]
        return try JSONDecoder().decode(LibFile.self, from: meta.serialized())
    }

    /// KI-Start -> "Im Dokument mit KI-Hilfe öffnen": der Editor nimmt den Wunsch nach dem Laden (`takeTutorOpenRequest`)
    /// und zeigt die KI-Hilfe gleich offen; der Wunsch ist danach verbraucht
    func testTutorOpensInDocumentFromStartPage() throws {
        let t = transport()
        let id = "f-tutor-\(UUID().uuidString.prefix(8))"
        let file = try document(t, id: id)
        let recents = AIRecents(defaults: try suite(), scope: "t")
        recents.record(question: "Was ist eine Folge?", answer: "Eine Abbildung von ℕ nach ℝ.", fileID: id, fileName: "VL01.pdf")
        let start = AIStartView(entitlements: plan(.plus), recents: recents)
        let env = try hostWithEnvironment(StartThenDocument(file: file, start: start).environment(\.ufAIEnabled, true), api: api(t))
        XCTAssertTrue(env.wait { self.button("Zuletzt: Was ist eine Folge?", in: env.view) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(tap("Zuletzt: Was ist eine Folge?", in: env.view))
        XCTAssertTrue(env.wait { self.button("Im Dokument mit KI-Hilfe öffnen", in: env.view) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(tap("Im Dokument mit KI-Hilfe öffnen", in: env.view))
        XCTAssertTrue(env.wait { env.router.route == .doc(id) })
        XCTAssertTrue(env.wait(timeout: 20) { self.button("KI-Start öffnen", in: env.view) != nil }, "KI-Hilfe offen\n" + texts(env.view).joined(separator: "\n"))
        XCTAssertNotNil(button("KI-Hilfe schließen", in: env.view), "Kopf der KI-Hilfe")
        XCTAssertNil(env.router.tutorOpenRequest, "der Editor hat den Wunsch genommen")
        XCTAssertEqual(t.count("GET", "/api/files/\(id)/content"), 1)
    }

    /// Editor des gehosteten Dokuments (fuer "Bereich an KI" ohne Gesten)
    private func editor(in env: HostedEnvironment) -> PDFEditorController? {
        func find(_ vc: UIViewController?) -> PDFEditorController? {
            guard let vc else { return nil }
            if let e = vc as? PDFEditorController { return e }
            for c in vc.children { if let e = find(c) { return e } }
            return find(vc.presentedViewController)
        }
        return find(env.window.rootViewController)
    }

    /// "Bereich an KI" (05.11.2026): Ausschnitt der Seite -> KI-Hilfe geht auf, Bild und erkannter Text stehen als Anhang
    /// im Eingabefeld (mit Seite), "Senden" ohne Frage erklaert ihn, die Anfrage traegt `image` (JPEG, Base64) und
    /// `selection`; danach ist der Anhang weg
    func testAreaLandsInTheTutorAndTheRequestCarriesTheImage() throws {
        let t = transport()
        let id = "f-area-\(UUID().uuidString.prefix(8))"
        let file = try document(t, id: id)
        t.answer("/api/ai/tutor", ["answer": "Das ist die Überschrift der Seite.", "cards": .null, "sources": [], "explain": .null])
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: file, api: api(t)) }.environment(\.ufAIEnabled, true), api: api(t))
        XCTAssertTrue(env.wait(timeout: 20) { self.shows(env.view, "Seite 1 / 2") }, texts(env.view).joined(separator: "\n"))
        let vc = try XCTUnwrap(editor(in: env))
        XCTAssertNil(button("KI-Hilfe schließen", in: env.view), "KI-Hilfe noch zu")
        vc.sendArea(pageIndex: 0, rect: CGRect(x: 60, y: 60, width: 300, height: 50))
        XCTAssertTrue(env.wait(timeout: 20) { self.button("Anhang entfernen", in: env.view) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertNotNil(button("KI-Hilfe schließen", in: env.view), "KI-Hilfe von selbst offen")
        XCTAssertTrue(shows(env.view, "Bereich · Seite 1"))
        XCTAssertTrue(shows(env.view, "Vorschau des Bereichs"))
        XCTAssertEqual(enabled("Senden", in: env.view), true, "mit Anhang sofort sendbar")
        XCTAssertTrue(tap("Senden", in: env.view))
        XCTAssertTrue(env.wait(timeout: 10) { t.count("POST", "/api/ai/tutor") == 1 })
        let body = try XCTUnwrap(t.bodies("/api/ai/tutor").last)
        XCTAssertEqual(body.s("mode"), "explain")
        XCTAssertEqual(body["page"]?.double, 1)
        let image = try XCTUnwrap(body.s("image").flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(Array(image.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG")
        let ui = try XCTUnwrap(UIImage(data: image))
        XCTAssertEqual(ui.size.width * ui.scale, 1200, accuracy: 1, "300 pt mal 4")
        XCTAssertTrue((body.s("selection") ?? "").contains("Folgen"), "erkannter Text geht als Markierung mit: \(body.s("selection") ?? "-")")
        XCTAssertTrue(env.wait { self.shows(env.view, "Das ist die Überschrift der Seite.") })
        XCTAssertNil(button("Anhang entfernen", in: env.view), "Anhang ist mit der Frage weg")
    }

    /// Ohne KI (ChatGPT ausgeschaltet, kein Pro AI): der markierte Text landet trotzdem sichtbar in der KI-Hilfe, darunter
    /// der Tarif-Hinweis statt "ChatGPT verbinden"; nichts geht an den Server
    func testAttachmentWithoutAIShowsTextAndPlanHint() throws {
        let t = transport()
        let id = "f-noai-\(UUID().uuidString.prefix(8))"
        let file = try document(t, id: id)
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: file, api: api(t)) }, api: api(t))
        XCTAssertTrue(env.wait(timeout: 20) { self.shows(env.view, "Seite 1 / 2") }, texts(env.view).joined(separator: "\n"))
        let vc = try XCTUnwrap(editor(in: env))
        vc.onAskAI?(TutorAttachment(kind: .selection, text: "Konvergenz einer Folge", page: 2))
        XCTAssertTrue(env.wait(timeout: 10) { self.shows(env.view, "Markierter Text · Seite 2") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Konvergenz einer Folge"))
        XCTAssertTrue(shows(env.view, "Die KI-Hilfe kommt mit der StudiNow-KI"))
        XCTAssertNil(button("ChatGPT verbinden", in: env.view))
        XCTAssertEqual(t.count("POST", "/api/ai/tutor"), 0)
    }

    /// Ein Wunsch fuer eine andere Datei oeffnet die KI-Hilfe nicht und bleibt fuer jene Datei stehen
    func testTutorStaysClosedForAnotherFile() throws {
        let t = transport()
        let id = "f-plain-\(UUID().uuidString.prefix(8))"
        let file = try document(t, id: id)
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: file, api: api(t)) }.environment(\.ufAIEnabled, true), api: api(t))
        env.router.tutorOpenRequest = "f-anders"
        XCTAssertTrue(env.wait(timeout: 20) { self.shows(env.view, "Seite 1 / 2") }, texts(env.view).joined(separator: "\n"))
        env.pump(0.5)
        XCTAssertNil(button("KI-Start öffnen", in: env.view), "KI-Hilfe bleibt zu")
        XCTAssertEqual(env.router.tutorOpenRequest, "f-anders")
    }

    func testStartPageWithoutAIShowsTheWayAndDisablesAsking() throws {
        let t = transport()
        let env = try hostWithEnvironment(AIStartView(entitlements: plan(.free), recents: AIRecents(defaults: try suite(), scope: "x")), api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, "Die KI-Hilfe kommt mit der StudiNow-KI") }, texts(env.view).joined(separator: "\n"))
        XCTAssertNotNil(button("Tarife ansehen", in: env.view), "statt ChatGPT verbinden")
        XCTAssertNil(button("ChatGPT verbinden", in: env.view))
        XCTAssertTrue(shows(env.view, "KI kommt mit StudiNow Pro AI"))
        XCTAssertEqual(enabled("Frage senden", in: env.view), false, "Senden ohne KI gesperrt")
        XCTAssertNotNil(button("Karteikarten.", in: env.view, exact: false), "die Aktionen bleiben sichtbar")
        // Wochentest-Pille oeffnet den Dialog, der ebenfalls den Weg zur KI zeigt
        XCTAssertTrue(tap("Wochentest.", in: env.view, exact: false))
        XCTAssertTrue(env.wait { self.shows(env.view, "Wochentest erstellen") })
        XCTAssertEqual(enabled("Test erstellen", in: env.view), false)
        XCTAssertEqual(t.count("POST", "/api/tests/generate"), 0)
    }

    // MARK: - Wochentest erstellen

    private let moduleDetail: JSONValue = ["id": 1, "name": "Testmathematik I", "weeks": [
        ["week": 3, "label": "Lehrwoche 3 (27.10.–02.11.)", "topic": "Folgen und Grenzwerte", "count": 2,
         "vorlesungen": [["id": "f-1", "name": "VL03.pdf", "ai_title": "Folgen und Grenzwerte", "doc_type": "vorlesung"]],
         "uebungen": [["id": "f-2", "name": "Blatt03.pdf", "doc_type": "uebung"]], "loesungen": [], "skripte": [], "klausuren": [], "sonstiges": []],
        ["week": 2, "label": "Lehrwoche 2", "topic": "Mengen", "count": 1,
         "vorlesungen": [["id": "f-0", "name": "VL02.pdf", "doc_type": "vorlesung"]], "uebungen": [], "loesungen": [], "skripte": [], "klausuren": [], "sonstiges": []],
        ["week": -2, "label": "Klausuren", "topic": "", "count": 1, "vorlesungen": [], "uebungen": [], "loesungen": [], "skripte": [],
         "klausuren": [["id": "k", "name": "Klausur.pdf", "doc_type": "klausur"]], "sonstiges": []],
    ]]

    func testQuizComposerValidatesAndSendsOnlyBackendParameters() throws {
        XCTAssertEqual(QuizComposer.weeks(moduleDetail).compactMap { $0.i("week") }, [3, 2], "nur Lehrwochen mit Unterlagen, neueste zuerst")
        XCTAssertEqual(QuizComposer.materials(QuizComposer.weeks(moduleDetail)[0]).compactMap { $0.s("name") }, ["VL03.pdf", "Blatt03.pdf"])
        let t = transport()
        t.answer("/api/modules/1", moduleDetail)
        t.answer("/api/tests/generate", ["started": "Test"])
        let generation = TestGenerationState()
        let env = try hostWithEnvironment(QuizComposer(moduleID: 1, entitlements: plan(.plus), generation: generation).environment(\.ufAIEnabled, true), api: api(t))
        env.pump(0.8)                                                        // Module und Lehrwochen laden, Baum aufbauen
        // Unterlagen mit KI-Titel erscheinen unter dem Titel ("Folgen und Grenzwerte" statt VL03.pdf)
        XCTAssertTrue(env.wait { self.shows(env.view, "Blatt03.pdf") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Folgen und Grenzwerte"))
        XCTAssertFalse(shows(env.view, "Klausur.pdf"), "Klausuren sind keine Lehrwoche")
        XCTAssertTrue(shows(env.view, "15 Aufgaben"))
        XCTAssertTrue(shows(env.view, "4 leicht · 6 mittel · 5 schwer"))
        XCTAssertTrue(shows(env.view, "Multiple Choice"))
        XCTAssertTrue(shows(env.view, "Lückentext"), "Aufgabenarten als Schalter (04.11.2026)")
        XCTAssertTrue(shows(env.view, "Gemeinsamer Test möglich"), "Standardeinstellung")
        XCTAssertTrue(shows(env.view, "1 Anfrage über dein ChatGPT · bei gemeinsamem Test 0 Credits"))
        XCTAssertEqual(enabled("Test erstellen", in: env.view), true)
        XCTAssertTrue(tap("45 min", in: env.view))
        XCTAssertTrue(tap("Test erstellen", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/tests/generate") == 1 })
        let body = try XCTUnwrap(t.bodies("/api/tests/generate").first)
        XCTAssertEqual(body, ["module_id": 1, "duration_min": 45, "week_no": 3, "count": 15, "difficulty": "beliebig",
                              "types": ["mc", "tf", "cloze", "short", "calc"], "topic": ""], "genau die Parameter des Backends")
        XCTAssertTrue(env.wait { env.router.route == .exams })
        // der Auftrag laeuft ("Gemeinsamer Test wird gesucht …"), bis /api/bg ihn beendet
        XCTAssertTrue(generation.job?.subject == "Testmathematik I" || env.wait(timeout: 10) { generation.job == nil })
    }

    func testQuizComposerWithoutModulesCannotStart() throws {
        let t = transport()
        t.answer("/api/modules", [])
        let env = try hostWithEnvironment(QuizComposer(moduleID: 0, entitlements: plan(.plus), generation: TestGenerationState()).environment(\.ufAIEnabled, true), api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, "Noch keine Module") }, texts(env.view).joined(separator: "\n"))
        XCTAssertEqual(enabled("Test erstellen", in: env.view), false)
        XCTAssertEqual(t.count("POST", "/api/tests/generate"), 0)
    }

    func testExamsPageShowsGeneratingStateAndSharedVariant() throws {
        let t = transport()
        t.answer("/api/tests", [["id": 9, "subject": "Testmathematik I", "title": "Lehrwoche 3: Folgen", "duration_min": 30, "question_count": 15,
                                 "module_id": 1, "week_no": 3, "auto": 1, "created_at": "2026-11-03T09:00:00", "week_start": "2026-11-02",
                                 "shared": ["variant": 2, "of": 3, "adopted": true]]])
        let generation = TestGenerationState()
        let env = try hostWithEnvironment(ExamsPage(generation: generation).environment(\.ufAIEnabled, true), api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, "Gemeinsamer Test · Variante 2 von 3") }, texts(env.view).joined(separator: "\n"))
        XCTAssertNotNil(button("Wochentest erstellen", in: env.view))
        XCTAssertNotNil(button("KI-Start", in: env.view))
        XCTAssertFalse(shows(env.view, "wird erstellt …"))
        generation.start(subject: "Testmathematik I", weekNo: 3)
        XCTAssertTrue(env.wait { self.shows(env.view, "Gemeinsamer Test wird gesucht") })
        XCTAssertTrue(shows(env.view, "Aufgabe 1"))
        XCTAssertTrue(shows(env.view, "Aufgabe 15"))
        XCTAssertEqual(enabled("Wochentest erstellen", in: env.view), false, "waehrend der Erstellung kein zweiter Start")
        generation.advance()
        XCTAssertTrue(env.wait { self.shows(env.view, "Aufgaben werden erstellt … 0/15") })
        XCTAssertTrue(shows(env.view, "KI arbeitet"))
        // Stand des Backends (/api/bg phase) geht vor der Schaetzung
        generation.apply(backendPhase: "shared_wait")
        XCTAssertTrue(env.wait { self.shows(env.view, "kurz warten") })
        generation.apply(backendPhase: "shared_adopted")
        XCTAssertTrue(env.wait { self.shows(env.view, "Gemeinsamer Test gefunden") })
        XCTAssertTrue(shows(env.view, "0 Credits"))
        generation.apply(backendPhase: "unbekannt")
        XCTAssertEqual(generation.job?.phase, .adopted, "Unbekanntes aendert nichts")
        generation.advance()
        XCTAssertEqual(generation.job?.phase, .adopted, "nach einem Stand vom Backend keine Schaetzung mehr")
        generation.finish()
        XCTAssertTrue(env.wait { !self.shows(env.view, "wird erstellt …") })
        XCTAssertEqual(enabled("Wochentest erstellen", in: env.view), true)
        // "Wochentest erstellen" oeffnet den Dialog
        XCTAssertTrue(tap("Wochentest erstellen", in: env.view))
        XCTAssertTrue(env.wait { self.button("Test erstellen", in: env.view) != nil })
    }

    /// KI-Hilfe im Editor, Reiter Test: "Wochentest erstellen" waehlt das Modul des offenen Dokuments vor (04.11.2026)
    func testTutorPanelWeeklyTestPreselectsTheDocumentsModule() throws {
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(before) }
        let t = transport()
        t.answer("/api/modules/2", ["id": 2, "name": "Testphysik", "weeks": [
            ["week": 1, "label": "Lehrwoche 1", "topic": "Kinematik", "count": 1,
             "vorlesungen": [["id": "f-4", "name": "Physik.pdf", "doc_type": "vorlesung"]], "uebungen": [], "loesungen": [], "skripte": [], "klausuren": [], "sonstiges": []],
        ]])
        t.answer("/api/index/file/f-4/page/1", ["file_id": "f-4", "page": 1, "status": "none", "can_build": false])
        let panel = TutorPanel(fileID: "f-4", fileName: "Physik.pdf", page: { 1 }, selection: { "" }, open: { _, _ in }, close: {}, moduleID: 2)
            .environment(\.ufAIEnabled, true)
        let env = try hostWithEnvironment(panel, api: api(t))
        XCTAssertTrue(env.wait { self.button("Bereich Test", in: env.view) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(tap("Bereich Test", in: env.view))
        XCTAssertTrue(env.wait { self.button("Wochentest erstellen", in: env.view) != nil })
        XCTAssertTrue(tap("Wochentest erstellen", in: env.view))
        XCTAssertTrue(env.wait { self.button("Test erstellen", in: env.view) != nil }, texts(env.view).joined(separator: "\n"))
        // ohne Vorwahl (zwei Module) laedt der Dialog keine Lehrwochen; mit Vorwahl die des Dokuments-Moduls
        XCTAssertTrue(env.wait { t.count("GET", "/api/modules/2") >= 1 }, "Lehrwochen des vorgewaehlten Moduls geladen")
        XCTAssertEqual(t.count("GET", "/api/modules/1"), 0)
    }

    /// "Frag die KI zu Aufgabe n" im Ergebnis: das Gespraech liegt in `TutorConversations`, steht unter "Zuletzt benutzt"
    /// (KI-Gespräch, "Aufgabe n – <Testtitel>", fuehrt zum Test) und ist beim naechsten Oeffnen wieder da; der 429 der
    /// Credits zeigt "Tarif ansehen" wie die KI-Hilfe im Editor
    func testExamAskStoresConversationForRecentAndReopens() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exam-ask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = TutorConversations(fileURL: dir.appendingPathComponent(TutorConversations.fileName))
        var context = ExamAskContext(nr: "2", kind: "Kurzantwort", question: "Was ist 0xFF dezimal?", given: "240", correct: "255", explanation: "F steht für 15.")
        context.testID = 8
        context.testTitle = "Lehrwoche 3: Zahlensysteme"
        let t = transport()
        t.answer("/api/ai/tutor", ["answer": "255 = 15 · 16 + 15.", "cards": .null, "sources": []])
        let env = try hostWithEnvironment(ExamAskPanel(context: context, close: {}, conversations: store).environment(\.ufAIEnabled, true), api: api(t),
                                          size: CGSize(width: 380, height: 800))
        XCTAssertTrue(env.wait { self.button(context.title, in: env.view) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Aufgabe 2 · über dein ChatGPT"), "Kostenzeile wie in der KI-Hilfe")
        XCTAssertEqual(ExamAskPanel.footer(nr: "2", model: "gpt-x"), "Aufgabe 2 · über dein ChatGPT · gpt-x")
        XCTAssertTrue(tap(context.title, in: env.view))
        XCTAssertTrue(env.wait { self.shows(env.view, "255 = 15 · 16 + 15.") }, texts(env.view).joined(separator: "\n"))
        XCTAssertEqual(t.bodies("/api/ai/tutor").first?["question"]?.string, context.prompt, "erste Frage mit dem ganzen Kontext")
        // gemerkt unter "exam:8:2" mit dem Titel fuer "Zuletzt benutzt"
        XCTAssertEqual(store.recent().first?.fileID, "exam:8:2")
        XCTAssertEqual(store.messages(for: "exam:8:2").map(\.text), [context.title, "255 = 15 · 16 + 15."])
        let recent = RecentItem.merge(backend: nil, conversations: store.recent(), aiRecents: [], limit: 15)
        XCTAssertEqual(recent.first?.title, "Aufgabe 2 – Lehrwoche 3: Zahlensysteme")
        XCTAssertEqual(recent.first?.kindLabel, "KI-Gespräch")
        XCTAssertEqual(recent.first.map(RecentCard.route(for:)), .exam(8), "fuehrt zum Ergebnis des Tests")
        XCTAssertNil(recent.first?.fileID)
        env.window.isHidden = true
        // wieder oeffnen: das Gespraech ist da, ohne neue Anfrage; die Anschlussfrage traegt den Verlauf mit dem Kontext
        let again = try hostWithEnvironment(ExamAskPanel(context: context, close: {}, conversations: store).environment(\.ufAIEnabled, true), api: api(t),
                                            size: CGSize(width: 380, height: 800))
        XCTAssertTrue(again.wait { self.shows(again.view, "255 = 15 · 16 + 15.") }, texts(again.view).joined(separator: "\n"))
        XCTAssertEqual(t.count("POST", "/api/ai/tutor"), 1)
        XCTAssertNil(button(context.title, in: again.view), "statt der Startfrage die Anschlussfragen")
        // 429: Frage faellt aus dem Verlauf, "Tarif ansehen" erscheint, nichts Neues gemerkt
        t.fail("/api/ai/tutor", 429, ["detail": "Credits für diesen Monat aufgebraucht – am 1. gibt es neue.", "code": "credits_exhausted"])
        XCTAssertTrue(again.wait { self.button(ExamAskContext.followUps[0], in: again.view) != nil })
        XCTAssertTrue(tap(ExamAskContext.followUps[0], in: again.view))
        XCTAssertTrue(again.wait { self.button("Tarif ansehen", in: again.view) != nil }, texts(again.view).joined(separator: "\n"))
        let sent = t.bodies("/api/ai/tutor").last
        XCTAssertEqual(sent?["history"]?.array?.first?["text"]?.string, context.prompt, "Verlauf beginnt mit dem ganzen Kontext")
        XCTAssertEqual(store.messages(for: "exam:8:2").count, 2, "ohne Antwort nichts gemerkt")
        again.window.isHidden = true
    }

    // MARK: - Karteikarten aus Dokument

    func testFlashcardComposerPreviewEditDeleteAndSave() throws {
        let t = transport()
        t.answer("/api/ai/flashcards", ["cards": [["question": "Was ist eine Folge?", "answer": "Eine Abbildung von N nach R."],
                                                   ["question": "Was heißt konvergent?", "answer": "Es gibt einen Grenzwert."],
                                                   ["question": "Was ist eine Cauchy-Folge?", "answer": "Glieder kommen sich beliebig nahe."]],
                                        "pages": [1, 2, 3], "count": 3])
        t.answer("/api/flashcards", ["ok": true, "count": 2])
        let env = try hostWithEnvironment(FlashcardComposer(moduleID: 1, fileID: "f-1", entitlements: plan(.plus)).environment(\.ufAIEnabled, true), api: api(t))
        XCTAssertTrue(env.wait { self.button("Karten erstellen", in: env.view) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(env.wait { self.shows(env.view, "Seiten (von 12)") })
        XCTAssertTrue(shows(env.view, "1 Anfrage über dein ChatGPT"))
        XCTAssertEqual(enabled("Übernehmen", in: env.view, exact: false), false, "ohne Vorschau nichts zu uebernehmen")
        XCTAssertTrue(tap("15", in: env.view))
        XCTAssertTrue(tap("Karten erstellen", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/flashcards") == 1 })
        let body = try XCTUnwrap(t.bodies("/api/ai/flashcards").first)
        XCTAssertEqual(body["file_id"], "f-1")
        XCTAssertEqual(body["count"], 15)
        XCTAssertEqual(body["pages"]?.array?.count, 10, "Vorgabe: die ersten zehn Seiten")
        XCTAssertNil(body["topic"], "leerer Schwerpunkt geht nicht mit")
        XCTAssertTrue(env.wait { self.shows(env.view, "Was heißt konvergent?") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "3 Karten"))
        XCTAssertEqual(t.count("POST", "/api/flashcards"), 0, "Vorschau speichert nichts")
        // eine Karte streichen, dann uebernehmen
        XCTAssertTrue(tap("Karte streichen: Was heißt konvergent?", in: env.view))
        XCTAssertTrue(env.wait { !self.shows(env.view, "Was heißt konvergent?") })
        XCTAssertTrue(shows(env.view, "2 Karten"))
        XCTAssertEqual(enabled("Übernehmen (2)", in: env.view), true)
        XCTAssertTrue(tap("Übernehmen (2)", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/flashcards") == 1 })
        let saved = try XCTUnwrap(t.bodies("/api/flashcards").first)
        XCTAssertEqual(saved["file_id"], "f-1", "Quelle = Dokument")
        XCTAssertEqual(saved["cards"]?.array?.compactMap { $0["question"]?.string }, ["Was ist eine Folge?", "Was ist eine Cauchy-Folge?"])
        XCTAssertEqual(saved["cards"]?.array?.first?["answer"], "Eine Abbildung von N nach R.")
        XCTAssertTrue(env.wait { self.shows(env.view, "2 Karten gespeichert") })
    }

    func testFlashcardComposerIsLockedWithoutPlusAndNeedsAI() throws {
        let t = transport()
        // ohne PC (lokales Backend) gilt der Tarif; am eigenen Server (Entwicklung) nicht
        let local = APIClient(base: APIClient.localBase, transport: t)
        let locked = try hostWithEnvironment(FlashcardComposer(moduleID: 1, fileID: "f-1", entitlements: plan(.free)).environment(\.ufAIEnabled, true), api: local)
        XCTAssertTrue(locked.wait { self.shows(locked.view, "Enthalten ab StudiNow Plus") }, texts(locked.view).joined(separator: "\n"))
        XCTAssertNil(button("Karten erstellen", in: locked.view))
        XCTAssertNil(button("Übernehmen", in: locked.view, exact: false))
        let noAI = try hostWithEnvironment(FlashcardComposer(moduleID: 1, fileID: "f-1", entitlements: plan(.plus)), api: api(t))
        XCTAssertTrue(noAI.wait { self.shows(noAI.view, "Die KI-Hilfe kommt mit der StudiNow-KI") })
        XCTAssertNil(button("Karten erstellen", in: noAI.view))
        XCTAssertEqual(t.count("POST", "/api/ai/flashcards"), 0)
    }

    // MARK: - Testlauf und Ergebnis

    private var openTest: JSONValue {
        ["id": 7, "subject": "Testmathematik I", "title": "Wochentest Testmathematik I – Folgen", "duration_min": 30, "started_at": .null, "submitted_at": .null,
         "answers": [:], "feedback": .null, "week_no": 3,
         "questions": [["nr": 1, "type": "mc", "difficulty": "leicht", "question": "Jede beschränkte Folge konvergiert.", "options": ["Wahr", "Falsch"], "points": 4],
                       ["nr": 2, "type": "mc", "difficulty": "mittel", "question": "Welche Reihe konvergiert?", "options": ["A) Summe 1/n", "B) Summe 1/n^2", "C) Summe n", "D) Summe 1"], "points": 6],
                       ["nr": 3, "type": "calc", "difficulty": "schwer", "question": "Berechne den Grenzwert von (2n+1)/n.", "points": 8]]]
    }

    private var submittedTest: JSONValue {
        var t = openTest.object ?? [:]
        t["id"] = 8
        t["submitted_at"] = "2026-11-03T10:00:00"
        t["started_at"] = "2026-11-03T09:30:00"
        t["answers"] = ["1": "Wahr", "2": "B) Summe 1/n^2", "3": ""]
        t["feedback"] = ["total": 7, "max": 18, "summary": "Grundlagen sitzen, Reihen nochmal anschauen.", "weak_topics": ["Reihen", "Grenzwerte"],
                         "per_question": [["nr": 1, "points": 0, "max": 4, "feedback": "Beschränkt heißt nicht konvergent, Gegenbeispiel (-1)^n."],
                                          ["nr": 2, "points": 6, "max": 6, "feedback": "Richtig, die Reihe über 1/n^2 konvergiert."],
                                          ["nr": 3, "points": 1, "max": 8, "feedback": "Keine Antwort."]]]
        var qs = t["questions"]?.array ?? []
        qs[0] = qs[0].merging(["answer": "Falsch"])
        qs[1] = qs[1].merging(["answer": "B"])
        qs[2] = qs[2].merging(["answer": "2"])
        t["questions"] = .array(qs)
        return .object(t)
    }

    func testExamRunShowsProgressAndTwoBigOptionsAndRecordsAnswers() throws {
        let t = transport()
        t.answer("/api/tests/7", openTest)
        let draftKey = "exam-draft:http://erfunden.test/:7"
        let draftStore = ActiveContainer.current?.defaults ?? .standard
        draftStore.removeObject(forKey: draftKey)
        addTeardownBlock { draftStore.removeObject(forKey: draftKey) }
        let env = try hostWithEnvironment(ExamRunPage(id: 7, task: nil), api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, "Fortschritt 0 von 3 beantwortet") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Jede beschränkte Folge konvergiert."))
        XCTAssertTrue(shows(env.view, "Berechne den Grenzwert"), "alle Aufgaben untereinander")
        XCTAssertTrue(shows(env.view, "Aufgabe 1 von 3 · Multiple Choice"))
        XCTAssertTrue(shows(env.view, "Aufgabe 3 von 3 · Rechnen / Programmieren"))
        XCTAssertNotNil(button("Abgeben & bewerten", in: env.view))
        // zwei Optionen: zwei grosse Flaechen, Auswahl markiert
        XCTAssertTrue(tap("Wahr", in: env.view))
        XCTAssertTrue(env.wait { self.shows(env.view, "Fortschritt 1 von 3 beantwortet") })
        let selected = elements(in: env.view).first { $0.accessibilityLabel == "Wahr" && $0.accessibilityTraits.contains(.button) }
        XCTAssertEqual(selected?.accessibilityTraits.contains(.selected), true)
        XCTAssertTrue(tap("B) Summe 1/n²", in: env.view, exact: false), "Formel lesbar (FormulaText), Antwort bleibt der Rohtext")
        XCTAssertTrue(env.wait { self.shows(env.view, "2 von 3 beantwortet") })
        XCTAssertEqual(draftStore.dictionary(forKey: draftKey) as? [String: String], ["1": "Wahr", "2": "B) Summe 1/n^2"], "Entwurf gespeichert")
        XCTAssertEqual(env.router.examFocus, true)
    }

    func testExamResultShowsScoreBarRightAnswersAndExplanations() throws {
        let t = transport()
        t.answer("/api/tests/8", submittedTest)
        let env = try hostWithEnvironment(ExamRunPage(id: 8, task: nil), api: api(t))
        XCTAssertTrue(env.wait { self.shows(env.view, "39 %") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "7 / 18 Punkte"))
        XCTAssertTrue(shows(env.view, "1/3 richtig"))
        XCTAssertTrue(shows(env.view, "Nochmal üben"))
        XCTAssertTrue(shows(env.view, "Reihen"))
        XCTAssertTrue(shows(env.view, "Deine Antwort: Wahr, falsch"), "falsche Antwort markiert")
        XCTAssertTrue(shows(env.view, "Deine Antwort: B) Summe 1/n^2, richtig"))
        XCTAssertTrue(shows(env.view, "Richtige Antwort"), "Richtige Antwort je Aufgabe")
        XCTAssertTrue(shows(env.view, "Erklärung"), "Erklärung je Aufgabe")
        XCTAssertTrue(shows(env.view, "Falsch"), "Musterloesung der ersten Aufgabe")
        XCTAssertTrue(shows(env.view, "Gegenbeispiel (-1)ⁿ"), "Formel lesbar")
        XCTAssertTrue(shows(env.view, "[keine Antwort]"))
        XCTAssertNil(button("Abgeben & bewerten", in: env.view))
        XCTAssertEqual(env.router.examFocus, false)
    }

    // MARK: - Bilder

    func testScreenshotsOfTheAIViews() throws {
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { throw XCTSkip("UF_SCREENSHOT_DIR nicht gesetzt") }
        let t = transport()
        t.answer("/api/ai/tutor", ["answer": "## Kurz gesagt\nEine Folge heißt **konvergent**, wenn sie einen Grenzwert hat.\n\n- Ab einem Index liegen alle Glieder in jeder Epsilon-Umgebung\n- Beschränkt allein reicht nicht, Gegenbeispiel (-1)^n\n\n1. Grenzwert raten\n2. Mit der Epsilon-Definition prüfen", "cards": .null, "sources": []])
        t.answer("/api/modules/1", moduleDetail)
        t.answer("/api/ai/flashcards", ["cards": [["question": "Was ist eine Folge?", "answer": "Eine Abbildung von N nach R."],
                                                   ["question": "Was heißt konvergent?", "answer": "Es gibt einen Grenzwert, dem sich die Glieder beliebig nähern."],
                                                   ["question": "Was ist eine Cauchy-Folge?", "answer": "Glieder kommen sich beliebig nahe."]], "pages": [1, 2, 3], "count": 3])
        t.answer("/api/tests/7", openTest)
        t.answer("/api/tests/8", submittedTest)
        let recents = AIRecents(defaults: try suite(), scope: "shots")
        recents.record(question: "Warum darf ich hier kürzen?", answer: "Weil der Faktor nicht null ist. Kürzen heißt, Zähler und Nenner durch denselben Faktor zu teilen.", fileID: "f-2", fileName: "Blatt01.pdf")
        recents.record(question: "Fachbegriffe", answer: "Folge: Abbildung von N nach R. Grenzwert: Wert, dem sich die Glieder nähern.", fileID: "f-1", fileName: "Folgen und Grenzwerte")

        let start = try hostWithEnvironment(AIStartView(entitlements: plan(.plus), recents: recents).environment(\.ufAIEnabled, true), api: api(t))
        start.pump(0.8)
        XCTAssertTrue(start.wait { self.button("Wochentest.", in: start.view, exact: false) != nil })
        XCTAssertTrue(tap("Erklären / PDF analysieren.", in: start.view, exact: false))
        XCTAssertTrue(start.wait { self.shows(start.view, "Kurz gesagt") }, texts(start.view).joined(separator: "\n"))
        both(start, "ki-start")

        let quiz = try hostWithEnvironment(dialogFrame(QuizComposer(moduleID: 1, entitlements: plan(.plus), generation: TestGenerationState())).environment(\.ufAIEnabled, true), api: api(t))
        quiz.pump(0.8)
        XCTAssertTrue(quiz.wait { self.shows(quiz.view, "Blatt03.pdf") }, texts(quiz.view).joined(separator: "\n"))
        both(quiz, "wochentest-erstellen")

        let cards = try hostWithEnvironment(dialogFrame(FlashcardComposer(moduleID: 1, fileID: "f-1", entitlements: plan(.plus)), wide: true).environment(\.ufAIEnabled, true), api: api(t))
        cards.pump(0.8)
        XCTAssertTrue(cards.wait { self.button("Karten erstellen", in: cards.view) != nil }, texts(cards.view).joined(separator: "\n"))
        XCTAssertTrue(tap("Karten erstellen", in: cards.view))
        XCTAssertTrue(cards.wait { self.shows(cards.view, "Cauchy-Folge") }, texts(cards.view).joined(separator: "\n"))
        both(cards, "karteikarten-aus-dokument")

        let generation = TestGenerationState()
        let exams = try hostWithEnvironment(ExamsPage(generation: generation).environment(\.ufAIEnabled, true), api: api(t))
        XCTAssertTrue(exams.wait { self.button("Wochentest erstellen", in: exams.view) != nil })
        generation.start(subject: "Testmathematik I", weekNo: 3)
        generation.apply(backendPhase: "generate")
        XCTAssertTrue(exams.wait { self.shows(exams.view, "Aufgaben werden erstellt") })
        both(exams, "test-wird-erstellt")
        generation.finish()

        let run = try hostWithEnvironment(ExamRunPage(id: 7, task: nil), api: api(t))
        XCTAssertTrue(run.wait { self.shows(run.view, "Fortschritt 0 von 3") })
        tap("Wahr", in: run.view)
        run.pump(0.3)
        both(run, "test-laufend")
        (ActiveContainer.current?.defaults ?? .standard).removeObject(forKey: "exam-draft:http://erfunden.test/:7")

        let result = try hostWithEnvironment(ExamRunPage(id: 8, task: nil), api: api(t))
        XCTAssertTrue(result.wait { self.shows(result.view, "39 %") })
        both(result, "test-ergebnis")
    }

    /// Dialoginhalt so gerahmt wie im Modal (UFModalHost): Abdunkelung, Box bis 620 bzw. 900 pt
    private func dialogFrame<V: View>(_ content: V, wide: Bool = false) -> some View {
        ZStack {
            UF.bg.ignoresSafeArea()
            Color(red: 10 / 255, green: 12 / 255, blue: 24 / 255).opacity(0.45).ignoresSafeArea()
            ScrollView { content.frame(maxWidth: wide ? 900 : 620).padding(16) }
        }
    }
}

private extension JSONValue {
    /// Objekt mit weiteren Feldern
    func merging(_ more: [String: JSONValue]) -> JSONValue {
        var o = object ?? [:]
        for (k, v) in more { o[k] = v }
        return .object(o)
    }
}
