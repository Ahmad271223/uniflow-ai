import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// KI-Hilfe fuer das ganze Dokument (05.11.2026, docs/KI-GANZES-DOKUMENT-2026-11-05.md): Umfang "Diese Seite | Ganzes
/// Dokument | Seiten …", die Schnellknoepfe "Ganze Vorlesung erklären" und "Alle Aufgaben erklären", die Rueckfrage zu
/// den Kosten und der Lauf Teil fuer Teil gegen einen Schein-Transport (kein Netz, keine KI); die Bloecke tragen ihre
/// Seiten und bleiben im gemerkten Gespraech erhalten.
@MainActor
final class TutorDocumentAppTests: XCTestCase {

    final class Transport: APITransport, @unchecked Sendable {
        private let lock = NSLock()
        private var canned: [String: [JSONValue]] = [:]
        private var log: [(path: String, body: JSONValue?)] = []

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
            let answer: JSONValue? = lock.withLock {
                log.append((path, body))
                guard var list = canned[path], !list.isEmpty else { return nil }
                let first = list.removeFirst()
                canned[path] = list.isEmpty ? [first] : list
                return first
            }
            let data = (answer ?? ["detail": .string("Testfehler")]).serialized()
            return (data, HTTPURLResponse(url: request.url!, statusCode: answer == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }

        func answer(_ path: String, _ v: JSONValue...) { lock.withLock { canned[path] = v } }
        func bodies(_ path: String) -> [JSONValue] { lock.withLock { log.filter { $0.path == path }.compactMap(\.body) } }
    }

    private func api(_ t: Transport) -> APIClient { APIClient(base: URL(string: "http://erfunden.test/")!, transport: t) }

    private let plan: JSONValue = [
        "intent": true, "mode": "lecture", "scope": ["kind": "all", "from": 1, "to": 40, "label": "Ganzes Dokument (Seiten 1–40)"],
        "title": "Ganze Vorlesung erklären · Ganzes Dokument (Seiten 1–40)",
        "steps": [["id": "1:lecture:1-15", "kind": "lecture", "from": 1, "to": 15, "title": "Seiten 1–15", "tasks": [], "cached": true],
                  ["id": "2:lecture:16-40", "kind": "lecture", "from": 16, "to": 40, "title": "Seiten 16–40", "tasks": [], "cached": false],
                  ["id": "3:overview:1-40", "kind": "overview", "from": 1, "to": 40, "title": "Überblick und Prüfungsrelevantes", "tasks": [], "cached": false]],
        "calls": 2, "cached": 1, "estimate": ["way": "credits", "credits": 6, "calls": 2], "confirm": true, "enough": true,
        "message": "Kostet etwa 6 Credits, du hast 74. 1 von 3 Teilen ist schon erklärt (0 Credits).",
    ]

    // MARK: Umfang und Schnellknoepfe

    func testScopeControlAndChips() {
        XCTAssertEqual(TutorDocScope.allCases.map(\.title), ["Diese Seite", "Ganzes Dokument", "Seiten …"])
        XCTAssertEqual(TutorDocRun.chips.map(\.label), ["Ganze Vorlesung erklären", "Alle Aufgaben erklären"])
        XCTAssertEqual(TutorDocRun.chips.map(\.mode), ["lecture", "tasks"])
        XCTAssertEqual(TutorDocRun.scopeJSON(.page, from: 3, to: 9), ["kind": "page"])
        XCTAssertEqual(TutorDocRun.scopeJSON(.document, from: 3, to: 9), ["kind": "all"])
        XCTAssertEqual(TutorDocRun.scopeJSON(.range, from: 12, to: 5), ["kind": "range", "from": 5, "to": 12], "vertauschte Grenzen")
        // Knoepfe des Reiters "Erklären": bei "Diese Seite" wie bisher, sonst ein Lauf
        XCTAssertNil(TutorDocRun.docMode(forTutorMode: "explain", scope: .page))
        XCTAssertEqual(TutorDocRun.docMode(forTutorMode: "summary", scope: .document), "lecture")
        XCTAssertEqual(TutorDocRun.docMode(forTutorMode: "steps", scope: .range), "tasks")
        XCTAssertEqual(TutorDocRun.docMode(forTutorMode: "hints", scope: .document), "tasks")
        XCTAssertNil(TutorDocRun.docMode(forTutorMode: "flashcards", scope: .document))
        for key in TutorPanel.Tab.explain.modes {
            XCTAssertNotNil(TutorDocRun.docMode(forTutorMode: key, scope: .document), "jeder Knopf des Reiters kennt das ganze Dokument: \(key)")
        }
        XCTAssertEqual(TutorDocRun.userLabel(mode: "tasks", scope: .range, from: 9, to: 4), "Alle Aufgaben erklären · Seiten 4–9")
        XCTAssertEqual(TutorDocRun.userLabel(mode: "lecture", scope: .document, from: 1, to: 1), "Ganze Vorlesung erklären · ganzes Dokument")
        // natuerliche Sprache im Eingabefeld (dieselben Regeln wie der Dienst)
        XCTAssertEqual(DocExplain.parseIntent("nimm dem dokument erkläre ganze vorlesung")?.mode, "lecture")
        XCTAssertEqual(DocExplain.parseIntent("erkläre alle aufgaben")?.mode, "tasks")
        XCTAssertNil(DocExplain.parseIntent("Was ist ein Eigenwert?"))
    }

    func testControlsAndBlocksRender() {
        var scope = TutorDocScope.range, from = 5, to = 12
        var started: [String] = []
        let controls = TutorDocControls(scope: Binding(get: { scope }, set: { scope = $0 }), from: Binding(get: { from }, set: { from = $0 }),
                                        to: Binding(get: { to }, set: { to = $0 }))
        // die Schnellknoepfe stehen seit 07.11.2026 vorn in der Aktionsreihe (TutorHeadAppTests misst den Kopf)
        let chips = HStack { TutorDocChips(busy: false) { started.append($0) } }
        let blocks = TutorDocBlocks(text: "## Eigenwerte [S. 5–7]\nKernideen.\n\n## Überblick [S. 1–40]\nRote Linie.", mode: "doc_lecture",
                                    explain: TutorDocRun.marker(cached: 2, total: 2)) { _ in }
        for view in [AnyView(controls), AnyView(chips), AnyView(blocks)] {
            let host = UIHostingController(rootView: view.frame(width: 360))
            let size = host.sizeThatFits(in: CGSize(width: 360, height: 2000))
            XCTAssertGreaterThan(size.height, 40)
            XCTAssertLessThanOrEqual(size.width, 361, "keine Ueberbreite in der schmalen Leiste")
        }
        XCTAssertTrue(started.isEmpty)
    }

    func testMarkdownKeepsBlocksAndPagesForTheRememberedConversation() {
        let blocks = [DocExplain.Block(kind: "section", title: "Eigenwerte", from: 5, to: 7, text: "Kernideen.\n- $Ax = \\lambda x$"),
                      DocExplain.Block(kind: "overview", title: "Überblick", from: 1, to: 40, text: "Rote Linie."),
                      DocExplain.Block(kind: "section", title: "Eine Seite", from: 9, to: 9, text: "")]
        let md = TutorDocRun.markdown(blocks)
        XCTAssertTrue(md.hasPrefix("## Eigenwerte [S. 5–7]\nKernideen."))
        let back = TutorDocRun.blocks(fromMarkdown: md, mode: "doc_lecture")
        XCTAssertEqual(back.map(\.title), ["Eigenwerte", "Überblick", "Eine Seite"])
        XCTAssertEqual(back.map { [$0.from, $0.to] }, [[5, 7], [1, 40], [9, 9]])
        XCTAssertEqual(back.map(\.kind), ["section", "overview", "section"])
        let tasks = TutorDocRun.blocks(fromMarkdown: "## Aufgabe 2a [S. 3]\nLösungsweg", mode: "doc_tasks")
        XCTAssertEqual(tasks.first?.kind, "task")
        XCTAssertEqual(TutorDocRun.storedNote(cached: 3, total: 3), "Schon erklärt · 0 Credits")
        XCTAssertEqual(TutorDocRun.storedNote(cached: 1, total: 3), "1 von 3 Teilen schon erklärt · 0 Credits")
        XCTAssertNil(TutorDocRun.storedNote(cached: 0, total: 3))
        XCTAssertEqual(TutorDocRun.progress(done: 1, total: 3, title: "Seiten 16–40"), "Teil 2 von 3 · Seiten 16–40")
        // gemerkt wird die Antwort wie jede andere (Modus doc_lecture, Text mit Seiten)
        let stored = TutorPanel.stored([TutorPanel.Message(fromUser: false, text: md, mode: "doc_lecture", explain: TutorDocRun.marker(cached: 1, total: 3))])
        XCTAssertEqual(TutorPanel.restored(stored).first?.text, md)
        XCTAssertEqual(TutorPanel.restored(stored).first?.mode, "doc_lecture")
    }

    // MARK: Ablauf gegen den Schein-Transport

    func testPlanAsksFirstThenRunsPartByPart() async throws {
        let t = Transport()
        t.answer("/api/ai/document/plan", plan)
        t.answer("/api/ai/document/step",
                 ["step": "1:lecture:1-15", "blocks": [["kind": "section", "title": "Vektoren", "from": 1, "to": 6, "text": "A"]], "stored": ["stored": true, "source": "cloud", "variant": 1]],
                 ["step": "2:lecture:16-40", "blocks": [["kind": "section", "title": "Eigenwerte", "from": 16, "to": 30, "text": "B"]], "stored": ["stored": false, "variant": 1, "shared": true]],
                 ["step": "3:overview:1-40", "blocks": [["kind": "overview", "title": "Überblick", "from": 1, "to": 40, "text": "C"],
                                                        ["kind": "overview", "title": "Prüfungsrelevant", "from": 1, "to": 40, "text": "D"]],
                  "stored": ["stored": false, "variant": 1, "shared": true]])
        let runner = TutorDocRunner()
        let p = try await runner.prepare(api: api(t), fileID: "f-1", page: 3, mode: "lecture", scope: TutorDocRun.scopeJSON(.document, from: 1, to: 1), question: nil)
        XCTAssertNotNil(p)
        XCTAssertEqual(runner.phase, .confirm, "mehr als 3 Credits: erst fragen")
        XCTAssertEqual(runner.plan?["message"]?.string, "Kostet etwa 6 Credits, du hast 74. 1 von 3 Teilen ist schon erklärt (0 Credits).")
        XCTAssertEqual(t.bodies("/api/ai/document/plan").first?["scope"], ["kind": "all"])
        var seen: [(Int, Int)] = []
        var last: [DocExplain.Block] = []
        try await runner.run(api: api(t)) { blocks, cached, total in
            seen.append((blocks.count, cached))
            last = blocks
            XCTAssertEqual(total, 3)
        }
        XCTAssertEqual(seen.map(\.0), [1, 2, 4], "Bloecke kommen nach und nach")
        XCTAssertEqual(seen.map(\.1), [1, 1, 1])
        XCTAssertEqual(last.map(\.title), ["Vektoren", "Eigenwerte", "Überblick", "Prüfungsrelevant"])
        XCTAssertEqual(runner.phase, .idle)
        let steps = t.bodies("/api/ai/document/step")
        XCTAssertEqual(steps.compactMap { $0["step"]?.string }, ["1:lecture:1-15", "2:lecture:16-40", "3:overview:1-40"])
        XCTAssertEqual(Set(steps.compactMap { $0["request_id"]?.string }).count, 3, "eigene request_id je Teil")
        XCTAssertTrue(steps.allSatisfy { $0["scope"]?["kind"]?.string == "all" && $0["file_id"]?.string == "f-1" })
    }

    func testQuestionWithoutDocumentWishStaysWithThePage() async throws {
        let t = Transport()
        t.answer("/api/ai/document/plan", ["intent": false])
        let runner = TutorDocRunner()
        let p = try await runner.prepare(api: api(t), fileID: "f-1", page: 2, mode: nil, scope: nil, question: "Was ist ein Eigenwert?")
        XCTAssertNil(p)
        XCTAssertEqual(runner.phase, .idle)
        XCTAssertEqual(t.bodies("/api/ai/document/plan").first?["question"]?.string, "Was ist ein Eigenwert?")
        // wenig Kosten: keine Rueckfrage
        var cheap = plan
        cheap["confirm"] = false
        t.answer("/api/ai/document/plan", cheap)
        _ = try await runner.prepare(api: api(t), fileID: "f-1", page: 2, mode: "tasks", scope: ["kind": "page"], question: nil)
        XCTAssertEqual(runner.phase, .idle)
        // reicht nicht: Rueckfrage, Starten bleibt aus
        var poor = plan
        poor["confirm"] = false
        poor["enough"] = false
        t.answer("/api/ai/document/plan", poor)
        _ = try await runner.prepare(api: api(t), fileID: "f-1", page: 2, mode: "lecture", scope: ["kind": "all"], question: nil)
        XCTAssertEqual(runner.phase, .confirm)
        runner.dismiss()
        XCTAssertEqual(runner.phase, .idle)
        XCTAssertNil(runner.plan)
    }
}
