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
        XCTAssertTrue(env.wait { self.button("Neues Gespräch", in: env.view) != nil }, "Gespraech statt Antwortkarte (vorher: Antwort schließen)")
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

    // MARK: - Neugestaltung 04.11.2026: Reiter der KI-Hilfe, Gespraech auf KI-Start

    /// Jeder Modus ausser der freien Frage liegt in genau einem Reiter; Farben und Reihenfolge wie besprochen
    func testTutorTabsMapEveryModeExactlyOnce() {
        XCTAssertEqual(TutorPanel.Tab.allCases.map(\.title), ["Erklären", "Karteikarten", "Test"])
        XCTAssertEqual(TutorPanel.Tab.explain.pair, CommunityPalette.mint, "Erklären gruen")
        XCTAssertEqual(TutorPanel.Tab.cards.pair, CommunityPalette.peach, "Karteikarten orange")
        XCTAssertEqual(TutorPanel.Tab.test.pair, CommunityPalette.sky, "Test blau")
        let inTabs = TutorPanel.Tab.allCases.flatMap(\.modes)
        XCTAssertEqual(inTabs.count, Set(inTabs).count, "kein Modus doppelt")
        XCTAssertEqual(Set(inTabs), Set(TutorPanel.modes.map(\.key).filter { $0 != "ask" }), "alle Modi erreichbar")
        XCTAssertEqual(TutorPanel.Tab.explain.modes, ["explain", "explain_simple", "summary", "terms", "steps", "hints"])
        XCTAssertEqual(TutorPanel.Tab.tab(for: "explain"), .explain)
        XCTAssertEqual(TutorPanel.Tab.tab(for: "hints"), .explain)
        XCTAssertEqual(TutorPanel.Tab.tab(for: "flashcards"), .cards)
        XCTAssertEqual(TutorPanel.Tab.tab(for: "similar"), .test)
        XCTAssertEqual(TutorPanel.Tab.tab(for: "check"), .test)
        XCTAssertNil(TutorPanel.Tab.tab(for: "ask"), "freie Frage: kein Reiter")
        // Anschlussfragen nur unter der letzten Antwort
        let ms = [TutorPanel.Message(fromUser: true, text: "F1"), TutorPanel.Message(fromUser: false, text: "A1"),
                  TutorPanel.Message(fromUser: true, text: "F2"), TutorPanel.Message(fromUser: false, text: "A2")]
        XCTAssertFalse(TutorPanel.showsFollowUps(at: 1, in: ms))
        XCTAssertTrue(TutorPanel.showsFollowUps(at: 3, in: ms))
        XCTAssertFalse(TutorPanel.showsFollowUps(at: 2, in: ms), "keine unter einer Frage")
        XCTAssertFalse(TutorPanel.showsFollowUps(at: 9, in: ms))
        // Abschnittstitel in den UF-Groessen (h2/h3/h4), nie kleiner als der Lesetext
        XCTAssertEqual(AIMarkdownText.headingSize(level: 2, body: 13.76), 17.6)
        XCTAssertEqual(AIMarkdownText.headingSize(level: 3, body: 13.76), 15.2)
        XCTAssertEqual(AIMarkdownText.headingSize(level: 4, body: 13.76), 13.76)
        XCTAssertEqual(AIMarkdownText.headingSize(level: 2, body: 17), 19)
    }

    /// Start oder Gespraech, "Zuletzt" nur ohne Gespraech, Verlauf als history (hoechstens die letzten Beitraege)
    func testChatLayoutStateAndHistory() {
        XCTAssertEqual(AIStartView.layout(turns: 0, pending: false), .start)
        XCTAssertEqual(AIStartView.layout(turns: 0, pending: true), .chat, "die erste Frage ist unterwegs: schon Gespraech")
        XCTAssertEqual(AIStartView.layout(turns: 2, pending: false), .chat)
        XCTAssertTrue(AIStartView.showsRecents(.start))
        XCTAssertFalse(AIStartView.showsRecents(.chat))
        XCTAssertEqual(AIStartView.history([]), .array([]))
        let one = [AIStartView.Answer(question: "Was ist eine Folge?", text: "Eine Abbildung.", mode: "ask")]
        XCTAssertEqual(AIStartView.history(one).array?.count, 2)
        XCTAssertEqual(AIStartView.history(one).array?.first?["role"], "user")
        XCTAssertEqual(AIStartView.history(one).array?.last?["text"], "Eine Abbildung.")
        let many = (1...5).map { AIStartView.Answer(question: "F\($0)", text: "A\($0)", mode: "ask") }
        let h = AIStartView.history(many).array ?? []
        XCTAssertEqual(h.count, AIPrompts.tutorHistoryTurns)
        XCTAssertEqual(h.last?["text"], "A5", "die neuesten Beitraege")
        XCTAssertEqual(AIStartView.plain("## Kurz\n- **fett** und `x`\n- zwei"), "Kurz fett und x · zwei")
    }

    /// Nach der ersten Frage wird die Seite ein Gespraech (Frage als Blase, Antwort, Feld unten), "Zuletzt" weicht;
    /// die zweite Frage schickt den Verlauf mit; "Neues Gespräch" fuehrt zurueck zum Start mit "Zuletzt"
    func testStartPageBecomesChatAndNewConversationReturns() throws {
        let t = transport()
        let recents = AIRecents(defaults: try suite(), scope: "chat")
        recents.record(question: "Alte Frage", answer: "Alte Antwort")
        let env = try hostWithEnvironment(AIStartView(entitlements: Entitlements(observe: false, plan: .plus), recents: recents)
                                              .environment(\.ufAIEnabled, true), api: api(t))
        XCTAssertTrue(env.wait { self.button("Angehängt:", in: env.view, exact: false) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertNotNil(button("Zuletzt: Alte Frage", in: env.view), "Start: Zuletzt unter dem Feld")
        XCTAssertNil(button("Neues Gespräch", in: env.view), "Start: kein Neues Gespräch")
        XCTAssertTrue(shows(env.view, "Modul: Alle Module"), "Modul als kleines Menue im Feld")
        XCTAssertTrue(tap("Hilfe.", in: env.view, exact: false))
        XCTAssertTrue(env.wait { self.button("Beispiel: \(AIHelpContent.examples[1])", in: env.view) != nil })
        XCTAssertTrue(tap("Beispiel: \(AIHelpContent.examples[1])", in: env.view))
        XCTAssertTrue(env.wait { self.enabledState("Frage senden", env) == true })
        XCTAssertTrue(tap("Frage senden", in: env.view))
        XCTAssertTrue(env.wait { self.shows(env.view, "Abbildung von ℕ nach ℝ") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Du: \(AIHelpContent.examples[1])"), "Frage als Blase")
        XCTAssertNotNil(button("Neues Gespräch", in: env.view))
        XCTAssertNil(button("Zuletzt: Alte Frage", in: env.view), "im Gespraech kein Zuletzt")
        XCTAssertNotNil(button("Wochentest.", in: env.view, exact: false), "Aktionen bleiben ueber dem Feld")
        XCTAssertNotNil(button("Frage senden", in: env.view), "Feld unten")
        both(env, "ki-start-gespraech")
        // zweite Frage ueber eine Anschlussfrage: der Verlauf geht mit
        XCTAssertTrue(tap("Einfacher erklären", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/tutor") == 2 })
        XCTAssertEqual(t.bodies("/api/ai/tutor").last?["history"]?.array?.count, 2)
        XCTAssertEqual(t.bodies("/api/ai/tutor").last?["mode"], "explain_simple")
        XCTAssertTrue(env.wait { self.shows(env.view, "Du: Einfacher erklären") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(env.wait { !self.busyShown(env) }, "zweite Antwort da")
        both(env, "ki-start-gespraech-2")
        XCTAssertTrue(tap("Neues Gespräch", in: env.view))
        XCTAssertTrue(env.wait { self.button("Zuletzt: Alte Frage", in: env.view) != nil }, "zurueck zum Start")
        XCTAssertNil(button("Neues Gespräch", in: env.view))
        XCTAssertTrue(shows(env.view, "Was möchtest du heute lernen?"))
    }

    /// KI-Hilfe im Editor: Reiter oben, Aktionen des Reiters darunter, Antwort als Markdown, Frage rechts; der Reiter
    /// folgt dem Modus einer Anschlussfrage
    func testTutorPanelTabsSendTheirModes() throws {
        let t = AIViewsAppTests.Transport()
        t.answer("/api/index/file/f-1/page/2", ["file_id": "f-1", "page": 2, "status": "none", "can_build": false])
        t.answer("/api/ai/tutor", ["answer": "## Kurz gesagt\nEine Folge heißt **konvergent**, wenn sie einen Grenzwert hat.\n\n### Woran du es erkennst\n- Ab einem Index liegen alle Glieder nah am Grenzwert\n- Beschränkt allein reicht nicht\n\n1. Grenzwert raten\n2. Mit der Epsilon-Definition prüfen",
                                   "cards": .null, "sources": []])
        let tutorAPI = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        let panel = TutorPanel(fileID: "f-1", page: { 2 }, selection: { "" }, open: { _, _ in }, close: {}).environment(\.ufAIEnabled, true)
        let env = try hostWithEnvironment(panel.frame(width: 377), api: tutorAPI, size: CGSize(width: 377, height: 1000))
        XCTAssertTrue(env.wait { self.button("Bereich Erklären", in: env.view) != nil }, texts(env.view).joined(separator: "\n"))
        XCTAssertNotNil(button("Bereich Karteikarten", in: env.view))
        XCTAssertNotNil(button("Bereich Test", in: env.view))
        for label in ["Erklären", "Einfach erklären", "Zusammenfassen", "Fachbegriffe", "Aufgabe lösen", "Nur Hinweise"] {
            XCTAssertNotNil(button(label, in: env.view), label)
        }
        XCTAssertNil(button("Ähnliche Aufgabe", in: env.view), "liegt im Reiter Test")
        both(env, "ki-hilfe-leer")
        XCTAssertTrue(tap("Bereich Test", in: env.view))
        XCTAssertTrue(env.wait { self.button("Ähnliche Aufgabe", in: env.view) != nil })
        XCTAssertNotNil(button("Lösung prüfen", in: env.view))
        XCTAssertNotNil(button("Wochentest erstellen", in: env.view))
        XCTAssertNil(button("Nur Hinweise", in: env.view))
        XCTAssertTrue(tap("Bereich Karteikarten", in: env.view))
        XCTAssertTrue(env.wait { self.button("Karteikarten zur Seite erstellen", in: env.view) != nil })
        XCTAssertTrue(tap("Bereich Erklären", in: env.view))
        XCTAssertTrue(env.wait { self.button("Zusammenfassen", in: env.view) != nil })
        XCTAssertTrue(tap("Zusammenfassen", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/tutor") == 1 })
        XCTAssertEqual(t.bodies("/api/ai/tutor").first?["mode"], "summary")
        XCTAssertTrue(env.wait { self.shows(env.view, "Woran du es erkennst") }, texts(env.view).joined(separator: "\n"))
        XCTAssertTrue(shows(env.view, "Du: Zusammenfassen"), "Frage als Blase rechts")
        XCTAssertTrue(shows(env.view, "Seite 2 · über dein ChatGPT"), "Kostenzeile unter dem Feld")
        both(env, "ki-hilfe-antwort")
        // Anschlussfrage "Ähnliche Aufgabe": der Reiter Test ist danach offen
        XCTAssertTrue(tap("Ähnliche Aufgabe", in: env.view))
        XCTAssertTrue(env.wait { t.count("POST", "/api/ai/tutor") == 2 })
        XCTAssertEqual(t.bodies("/api/ai/tutor").last?["mode"], "similar")
        XCTAssertTrue(env.wait { self.button("Lösung prüfen", in: env.view) != nil }, "Reiter Test offen")
        // Loesung pruefen: das Feld wechselt, Senden heisst so
        XCTAssertTrue(tap("Lösung prüfen", in: env.view))
        XCTAssertTrue(env.wait { self.button("Lösung prüfen beenden", in: env.view) != nil })
        XCTAssertTrue(tap("Lösung prüfen beenden", in: env.view))
        XCTAssertTrue(env.wait { self.button("Lösung prüfen beenden", in: env.view) == nil })
        // Hochformat: schmale Leiste
        let narrow = try hostWithEnvironment(TutorPanel(fileID: "f-1", page: { 2 }, selection: { "" }, open: { _, _ in }, close: {})
                                                 .environment(\.ufAIEnabled, true).frame(width: 300), api: tutorAPI, size: CGSize(width: 300, height: 1000))
        XCTAssertTrue(narrow.wait { self.button("Bereich Test", in: narrow.view) != nil })
        both(narrow, "ki-hilfe-schmal")
        // sehr grosse Schrift: Reiter untereinander, alles erreichbar
        let big = try hostWithEnvironment(TutorPanel(fileID: "f-1", page: { 2 }, selection: { "" }, open: { _, _ in }, close: {})
                                              .environment(\.ufAIEnabled, true).environment(\.dynamicTypeSize, .accessibility3).frame(width: 377),
                                          api: tutorAPI, size: CGSize(width: 377, height: 1000))
        XCTAssertTrue(big.wait { self.button("Bereich Test", in: big.view) != nil })
        XCTAssertNotNil(button("Nur Hinweise", in: big.view))
        both(big, "ki-hilfe-grosse-schrift")
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

    private func busyShown(_ env: HostedEnvironment) -> Bool { shows(env.view, "Die KI antwortet") }

    private func enabledState(_ label: String, _ env: HostedEnvironment) -> Bool? {
        button(label, in: env.view).map { !$0.accessibilityTraits.contains(.notEnabled) }
    }
}
