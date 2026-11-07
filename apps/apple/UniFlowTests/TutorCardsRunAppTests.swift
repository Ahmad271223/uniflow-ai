import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Karteikarten aus dem ganzen Dokument in der KI-Hilfe (07.11.2026, Fehler vom iPad: der Reiter "Karteikarten" nahm
/// immer nur die offene Seite). Regeln des Laufs (`TutorCardsRun`) ohne Netz und der Lauf in der Leiste gegen einen
/// Schein-Transport mit einem Dokument aus 45 Seiten (keine KI: `POST /api/ai/flashcards` antwortet aus der Dose,
/// Teil fuer Teil); die Karten aller Teile landen in einer Antwort, "Als Karteikarten speichern" schickt alle.
@MainActor
final class TutorCardsRunAppTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    // MARK: Regeln

    func testStepsCountsAndLabels() {
        XCTAssertEqual(TutorCardsRun.steps(from: 1, to: 45).map { [$0.lowerBound, $0.upperBound] }, [[1, 20], [21, 40], [41, 45]])
        XCTAssertEqual(TutorCardsRun.steps(from: 25, to: 3).map { [$0.lowerBound, $0.upperBound] }, [[3, 22], [23, 25]], "vertauschte Grenzen")
        XCTAssertEqual(TutorCardsRun.steps(from: 7, to: 7).map { [$0.lowerBound, $0.upperBound] }, [[7, 7]])
        XCTAssertEqual(TutorCardsRun.steps(from: 0, to: 0).map { [$0.lowerBound, $0.upperBound] }, [[1, 1]], "ab Seite 1")
        XCTAssertEqual(TutorCardsRun.pagesPerStep, FlashcardComposer.pagesMax, "so viele Seiten nimmt das Backend je Anfrage (FLASHCARD_PAGES_MAX)")
        // etwa zwei Karten je Seite, 8 bis 30
        XCTAssertEqual(TutorCardsRun.count(pages: 45), 30)
        XCTAssertEqual(TutorCardsRun.count(pages: 10), 20)
        XCTAssertEqual(TutorCardsRun.count(pages: 2), 8)
        XCTAssertLessThanOrEqual(TutorCardsRun.maxCards, AIPrompts.flashcardsMax)
        XCTAssertEqual(TutorCardsRun.counts(total: 30, steps: 3), [10, 10, 10])
        XCTAssertEqual(TutorCardsRun.counts(total: 20, steps: 3), [7, 7, 6])
        XCTAssertEqual(TutorCardsRun.counts(total: 8, steps: 1), [8])
        XCTAssertEqual(TutorCardsRun.counts(total: 4, steps: 2), [3, 3], "je Teil wenigstens 3")
        XCTAssertEqual(TutorCardsRun.counts(total: 9, steps: 0), [])
        // Umfang -> Bereich
        XCTAssertNil(TutorCardsRun.range(scope: .page, from: 1, to: 9, pageCount: 40), "Diese Seite: kein Lauf")
        XCTAssertEqual(TutorCardsRun.range(scope: .document, from: 1, to: 1, pageCount: 40), 1...40)
        XCTAssertEqual(TutorCardsRun.range(scope: .document, from: 1, to: 1, pageCount: nil), 1...TutorCardsRun.pagesMax, "ohne Seitenzahl bis zum erkannten Ende")
        XCTAssertEqual(TutorCardsRun.range(scope: .range, from: 12, to: 5, pageCount: 40), 5...12)
        // Ende des Dokuments an den gelieferten Seiten erkennen
        XCTAssertTrue(TutorCardsRun.accepted([21, 22, 23], requested: 21...40))
        XCTAssertFalse(TutorCardsRun.accepted([1, 2, 3], requested: 41...60), "Backend fiel auf die ersten Seiten zurueck: nicht doppelt")
        XCTAssertFalse(TutorCardsRun.accepted([], requested: 41...60))
        XCTAssertTrue(TutorCardsRun.continues(after: Array(1...20), requested: 1...20))
        XCTAssertFalse(TutorCardsRun.continues(after: Array(21...33), requested: 21...40), "Dokument hat 33 Seiten: Schluss")
        // Beschriftungen
        XCTAssertEqual(TutorCardsRun.chipLabel(scope: .page, from: 1, to: 1), "Karteikarten zur Seite erstellen")
        XCTAssertEqual(TutorCardsRun.chipLabel(scope: .document, from: 1, to: 1), "Karteikarten zum ganzen Dokument erstellen")
        XCTAssertEqual(TutorCardsRun.chipLabel(scope: .range, from: 12, to: 5), "Karteikarten zu Seiten 5–12 erstellen")
        XCTAssertEqual(TutorCardsRun.userLabel(scope: .document, from: 1, to: 1), "Karteikarten · ganzes Dokument")
        XCTAssertEqual(TutorCardsRun.userLabel(scope: .range, from: 5, to: 12), "Karteikarten · Seiten 5–12")
        XCTAssertEqual(TutorCardsRun.progress(step: 1, total: 3, pages: 21...40), "Karteikarten, Teil 2 von 3 · Seiten 21–40 …")
        XCTAssertEqual(TutorCardsRun.answerText(cards: 5, pages: [1, 2, 20, 21, 45]), "5 Karteikarten zu Seiten 1–45")
        XCTAssertEqual(TutorCardsRun.body(fileID: "f-1", pages: 41...45, count: 10),
                       ["file_id": "f-1", "pages": [41, 42, 43, 44, 45], "count": 10])
        XCTAssertEqual(TutorCardsRun.pages(in: ["pages": [3, 4, "x"]]), [3, 4])
    }

    // MARK: Elemente

    private func elements(in view: UIView) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                if o.accessibilityLabel?.isEmpty == false { out.append(o) }
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

    private func labels(_ view: UIView) -> [String] { elements(in: view).compactMap(\.accessibilityLabel) }
    private func shows(_ view: UIView, _ text: String) -> Bool { labels(view).contains { $0.contains(text) } }

    private func button(_ label: String, in view: UIView) -> NSObject? {
        elements(in: view).first { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label }
    }

    private func tap(_ label: String, in view: UIView) -> Bool {
        button(label, in: view)?.accessibilityActivate() ?? false
    }

    private func card(_ q: String, _ a: String) -> JSONValue { ["question": .string(q), "answer": .string(a)] }

    /// Dokument aus 45 Seiten in der Bibliothek; der Karten-Weg antwortet je Teil mit den angefragten Seiten
    private func transport(pageCount: JSONValue, parts: [JSONValue]) -> TutorDocumentAppTests.Transport {
        let t = TutorDocumentAppTests.Transport()
        t.answer("/api/library", ["files": [["id": "f-1", "name": "VL.pdf", "title": "VL.pdf", "module_id": 1, "kind": "pdf", "page_count": pageCount,
                                             "downloaded_at": "2026-10-20T10:00:00"]], "modules": [], "folders": [], "trash": []])
        t.answer("/api/index/file/f-1/page/2", ["file_id": "f-1", "page": 2, "status": "none", "can_build": false])
        t.answer("/api/flashcards", ["count": 5])
        var all: [JSONValue] = []
        for p in parts { all.append(p) }
        // Transport.answer nimmt Varargs: nacheinander
        switch all.count {
        case 1: t.answer("/api/ai/flashcards", all[0])
        case 2: t.answer("/api/ai/flashcards", all[0], all[1])
        default: t.answer("/api/ai/flashcards", all[0], all[1], all[2])
        }
        return t
    }

    private func host(_ t: TutorDocumentAppTests.Transport) throws -> HostedEnvironment {
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        let panel = TutorPanel(fileID: "f-1", page: { 2 }, selection: { "" }, open: { _, _ in }, close: {}).environment(\.ufAIEnabled, true)
        return try hostWithEnvironment(panel.frame(width: 640), api: api, size: CGSize(width: 640, height: 900))
    }

    /// Umfang "Ganzes Dokument" im Reiter Karteikarten: drei Teile (1–20, 21–40, 41–45) mit je 10 Karten angefragt,
    /// alle Karten in einer Antwort, speichern schickt alle fuenf; die Umfang-Auswahl ist im Reiter da und bedienbar
    func testWholeDocumentCardsRunInParts() throws {
        let t = transport(pageCount: 45, parts: [
            ["cards": [card("F1", "A1"), card("F2", "A2")], "pages": .array((1...20).map { .number(Double($0)) }), "count": 10],
            ["cards": [card("F3", "A3"), card("F4", "A4")], "pages": .array((21...40).map { .number(Double($0)) }), "count": 10],
            ["cards": [card("F5", "A5")], "pages": .array((41...45).map { .number(Double($0)) }), "count": 10],
        ])
        let env = try host(t)
        XCTAssertTrue(env.wait { self.button("Bereich Karteikarten", in: env.view) != nil }, labels(env.view).joined(separator: "\n"))
        XCTAssertTrue(tap("Bereich Karteikarten", in: env.view))
        XCTAssertTrue(env.wait { self.button("Karteikarten zur Seite erstellen", in: env.view) != nil }, labels(env.view).joined(separator: "\n"))
        XCTAssertTrue(env.wait { self.button("Ganzes Dokument", in: env.view) != nil }, "Umfang im Reiter Karteikarten:\n" + labels(env.view).joined(separator: "\n"))
        XCTAssertTrue(tap("Ganzes Dokument", in: env.view))
        XCTAssertTrue(env.wait { self.button("Karteikarten zum ganzen Dokument erstellen", in: env.view) != nil }, labels(env.view).joined(separator: "\n"))
        XCTAssertTrue(tap("Karteikarten zum ganzen Dokument erstellen", in: env.view))
        XCTAssertTrue(env.wait(timeout: 15) { t.bodies("/api/ai/flashcards").count == 3 }, "drei Teile")
        let bodies = t.bodies("/api/ai/flashcards")
        XCTAssertEqual(bodies.map { $0["pages"]?.array?.count }, [20, 20, 5])
        XCTAssertEqual(bodies.map { $0["pages"]?.array?.first }, [1, 21, 41])
        XCTAssertEqual(bodies.map { $0["count"] }, [10, 10, 10])
        XCTAssertEqual(bodies.first?["file_id"], "f-1")
        XCTAssertTrue(t.bodies("/api/ai/tutor").isEmpty, "nicht der Weg zur Seite")
        XCTAssertTrue(env.wait { self.button("Als Karteikarten speichern", in: env.view) != nil }, labels(env.view).joined(separator: "\n"))
        for q in ["F1", "F3", "F5"] { XCTAssertTrue(shows(env.view, q), q) }
        XCTAssertTrue(shows(env.view, "Du: Karteikarten · ganzes Dokument"))
        XCTAssertTrue(tap("Als Karteikarten speichern", in: env.view))
        XCTAssertTrue(env.wait { t.bodies("/api/flashcards").count == 1 })
        XCTAssertEqual(t.bodies("/api/flashcards").first?["cards"]?.array?.count, 5, "alle Karten der drei Teile")
        XCTAssertEqual(t.bodies("/api/flashcards").first?["file_id"], "f-1")
        XCTAssertTrue(env.wait { self.button("In Karteikarten gespeichert", in: env.view) != nil })
    }

    /// Ohne Seitenzahl in der Bibliothek: der Lauf erkennt das Ende an den gelieferten Seiten (33 Seiten: zwei Teile,
    /// kein dritter)
    func testWholeDocumentWithoutPageCountStopsAtTheEnd() throws {
        let t = transport(pageCount: .null, parts: [
            ["cards": [card("F1", "A1")], "pages": .array((1...20).map { .number(Double($0)) }), "count": 10],
            ["cards": [card("F2", "A2")], "pages": .array((21...33).map { .number(Double($0)) }), "count": 10],
            ["cards": [card("Falsch", "zu viel")], "pages": .array((1...20).map { .number(Double($0)) }), "count": 10],
        ])
        let env = try host(t)
        XCTAssertTrue(env.wait { self.button("Bereich Karteikarten", in: env.view) != nil })
        XCTAssertTrue(tap("Bereich Karteikarten", in: env.view))
        XCTAssertTrue(env.wait { self.button("Ganzes Dokument", in: env.view) != nil })
        XCTAssertTrue(tap("Ganzes Dokument", in: env.view))
        XCTAssertTrue(env.wait { self.button("Karteikarten zum ganzen Dokument erstellen", in: env.view) != nil })
        XCTAssertTrue(tap("Karteikarten zum ganzen Dokument erstellen", in: env.view))
        XCTAssertTrue(env.wait(timeout: 15) { self.button("Als Karteikarten speichern", in: env.view) != nil }, labels(env.view).joined(separator: "\n"))
        XCTAssertEqual(t.bodies("/api/ai/flashcards").count, 2, "nach Seite 33 ist Schluss")
        XCTAssertTrue(shows(env.view, "F2"))
        XCTAssertFalse(shows(env.view, "Falsch"))
    }

    /// Umfang "Diese Seite": wie bisher der Tutor-Weg zur Seite (Modus flashcards)
    func testPageScopeStillAsksTheTutor() throws {
        let t = transport(pageCount: 45, parts: [["cards": [], "pages": [], "count": 10]])
        t.answer("/api/ai/tutor", ["answer": "[]", "cards": [card("S1", "A")], "sources": []])
        let env = try host(t)
        XCTAssertTrue(env.wait { self.button("Bereich Karteikarten", in: env.view) != nil })
        XCTAssertTrue(tap("Bereich Karteikarten", in: env.view))
        XCTAssertTrue(env.wait { self.button("Karteikarten zur Seite erstellen", in: env.view) != nil })
        XCTAssertTrue(tap("Karteikarten zur Seite erstellen", in: env.view))
        XCTAssertTrue(env.wait { t.bodies("/api/ai/tutor").count == 1 })
        XCTAssertEqual(t.bodies("/api/ai/tutor").first?["mode"], "flashcards")
        XCTAssertEqual(t.bodies("/api/ai/tutor").first?["page"], 2)
        XCTAssertTrue(t.bodies("/api/ai/flashcards").isEmpty)
    }
}
