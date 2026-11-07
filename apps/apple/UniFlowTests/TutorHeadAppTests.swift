import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Flacher Kopf der KI-Hilfe (07.11.2026, Foto vom iPad: Reiter, Umfang, zwei Schnellknoepfe, sechs Modus-Chips ueber
/// drei Zeilen und die Anschlussfragen nahmen der Antwort fast den ganzen Platz). Jetzt: Reiter und Umfang kompakt,
/// alle Aktionen in EINER Reihe zum Wischen (`AIChipRail`), Anschlussfragen ebenso; der Kopf bleibt unter 260 pt bei
/// 640 pt Breite, alle Chips bleiben als Knoepfe mit ihren Kennungen da. Gegen einen Schein-Transport; kein Netz.
@MainActor
final class TutorHeadAppTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        HostedEnvironment.accessibilityAutomation(true)
    }

    override class func tearDown() {
        HostedEnvironment.accessibilityAutomation(false)
        super.tearDown()
    }

    /// Alle Chips des Reiters "Erklären" in der Reihenfolge der Reihe: erst das Dokument, dann die Modi
    static let explainChips = ["Ganze Vorlesung erklären", "Alle Aufgaben erklären", "Erklären", "Einfach erklären", "Zusammenfassen",
                               "Fachbegriffe", "Aufgabe lösen", "Nur Hinweise"]

    // MARK: Hoehe des Kopfs

    private func head(tab: TutorPanel.Tab = .explain, scope: TutorDocScope = .page) -> TutorPanelHead {
        TutorPanelHead(tab: .constant(tab), scope: .constant(scope), from: .constant(1), to: .constant(3), busy: false, checking: false,
                       mode: { _ in }, doc: { _ in }, cards: {}, weeklyTest: {})
    }

    private func height(_ view: some View, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: width))
        let size = host.sizeThatFits(in: CGSize(width: width, height: 2000))
        XCTAssertLessThanOrEqual(size.width, width + 1, "keine Ueberbreite bei \(width) pt")
        return size.height
    }

    /// Reiter + Umfang + eine Reihe Aktionen: weit unter 260 pt, bei breitem Panel (640), iPhone-Breite (377) und
    /// Split View (300); der Umfang "Seiten …" mit seinen Feldern bleibt ebenfalls flach
    func testHeadStaysFlat() {
        for width: CGFloat in [640, 377, 300] {
            let h = height(head(), width: width)
            XCTAssertLessThan(h, 260, "Kopf bei \(width) pt: \(h)")
            XCTAssertLessThan(h, 160, "Reiter (34) + Umfang (32) + eine Reihe Chips (36) + Abstaende bei \(width) pt: \(h)")
            XCTAssertGreaterThan(h, 90, "Reiter, Umfang und Aktionen sind da (\(width) pt): \(h)")
        }
        XCTAssertLessThan(height(head(scope: .range), width: 640), 200, "Seiten von–bis darunter")
        XCTAssertLessThan(height(head(tab: .test), width: 640), 120, "Reiter Test: eine Reihe")
        XCTAssertLessThan(height(head(tab: .cards), width: 640), 180, "Reiter Karteikarten: Umfang und eine Reihe")
        // sehr grosse Schrift: Reiter untereinander, die Reihe waechst mit - trotzdem keine drei Zeilen Chips
        XCTAssertLessThan(height(head().environment(\.dynamicTypeSize, .accessibility3), width: 377), 420)
    }

    /// Reihenfolge und Kennungen der Reihe sind fest (Tests tippen sie so an)
    func testChipOrderAndIdentifiers() {
        XCTAssertEqual(TutorDocRun.chips.map(\.label) + TutorPanel.Tab.explain.modes.map { k in TutorPanel.modes.first(where: { $0.key == k })!.label },
                       Self.explainChips)
        XCTAssertEqual(TutorPanel.answerSize, 15, "Antwort nie kleiner als 15 pt")
        XCTAssertGreaterThanOrEqual(AIMarkdownText.headingSize(level: 2, body: TutorPanel.answerSize), 17)
    }

    // MARK: In der Leiste

    private func elements(in view: UIView) -> [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = element as? NSObject {
                guard seen.insert(ObjectIdentifier(o)).inserted else { return }
                out.append(o)
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

    private func button(_ label: String, in view: UIView) -> NSObject? {
        elements(in: view).first { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label }
    }

    /// Alle Knoepfe mit dieser Beschriftung ("Fachbegriffe" gibt es oben in der Reihe und als Anschlussfrage)
    private func buttons(_ label: String, in view: UIView) -> [NSObject] {
        elements(in: view).filter { $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel == label }
    }

    private func labels(_ view: UIView) -> String {
        elements(in: view).compactMap(\.accessibilityLabel).joined(separator: "\n")
    }

    private func tap(_ label: String, in view: UIView) -> Bool {
        button(label, in: view)?.accessibilityActivate() ?? false
    }

    private func transport() -> AIStartPolishAppTests.Transport {
        let t = AIStartPolishAppTests.Transport()
        t.answer("/api/index/file/f-1/page/2", ["file_id": "f-1", "page": 2, "status": "none", "can_build": false])
        t.answer("/api/ai/tutor", ["answer": "## Kurz gesagt\nEine Folge heißt **konvergent**, wenn sie einen Grenzwert hat.", "cards": .null, "sources": []])
        return t
    }

    /// 640 pt breites Panel: alle acht Chips sind Knoepfe mit den alten Kennungen und stehen in EINER Zeile (gleiche
    /// Oberkante), die Zeile beginnt unter 200 pt vom Rand; nach einer Antwort stehen auch die Anschlussfragen in
    /// einer Zeile; bei 300 pt dasselbe Verhalten
    func testChipsStayInOneRowWideAndNarrow() throws {
        let t = transport()
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        for width: CGFloat in [640, 300] {
            let panel = TutorPanel(fileID: "f-1", page: { 2 }, selection: { "" }, open: { _, _ in }, close: {}).environment(\.ufAIEnabled, true)
            let env = try hostWithEnvironment(panel.frame(width: width), api: api, size: CGSize(width: width, height: 900))
            XCTAssertTrue(env.wait { self.button("Nur Hinweise", in: env.view) != nil }, labels(env.view))
            var tops: [CGFloat] = []
            for label in Self.explainChips {
                let b = try XCTUnwrap(button(label, in: env.view), "\(label) bei \(width) pt")
                tops.append(b.accessibilityFrame.minY)
            }
            XCTAssertLessThan(tops.max()! - tops.min()!, 2, "eine Zeile bei \(width) pt: \(tops)")
            XCTAssertLessThan(tops.min()! - env.window.frame.minY, 200, "die Reihe liegt im flachen Kopf (\(width) pt)")
            XCTAssertNotNil(elements(in: env.view).first { $0.accessibilityLabel == "Umfang" }, "Umfang-Segmente bei \(width) pt")
            // der Reiter Test: auch eine Reihe, mit Wochentest
            XCTAssertTrue(tap("Bereich Test", in: env.view))
            XCTAssertTrue(env.wait { self.button("Wochentest erstellen", in: env.view) != nil })
            let test = ["Ähnliche Aufgabe", "Lösung prüfen", "Wochentest erstellen"].compactMap { button($0, in: env.view)?.accessibilityFrame.minY }
            XCTAssertEqual(test.count, 3)
            XCTAssertLessThan(test.max()! - test.min()!, 2, "Reiter Test in einer Zeile (\(width) pt): \(test)")
            XCTAssertTrue(tap("Bereich Erklären", in: env.view))
            XCTAssertTrue(env.wait { self.button("Erklären", in: env.view) != nil })
            // Antwort und Anschlussfragen in einer Zeile
            XCTAssertTrue(tap("Erklären", in: env.view))
            XCTAssertTrue(env.wait { self.button("Ein Beispiel dazu", in: env.view) != nil }, labels(env.view))
            // "Fachbegriffe" gibt es auch oben in der Reihe: die Anschlussfrage ist die untere
            let terms = buttons("Fachbegriffe", in: env.view).map(\.accessibilityFrame.minY)
            XCTAssertEqual(terms.count, 2, labels(env.view))
            let follow = ["Einfacher erklären", "Ein Beispiel dazu"].compactMap { button($0, in: env.view)?.accessibilityFrame.minY } + [terms.max() ?? -1]
            XCTAssertEqual(follow.count, 3, labels(env.view))
            if let hi = follow.max(), let lo = follow.min() {
                XCTAssertLessThan(hi - lo, 2, "Anschlussfragen in einer Zeile (\(width) pt): \(follow)")
                XCTAssertGreaterThan(lo, tops.max()! + 40, "die Anschlussfragen stehen unter der Antwort, nicht im Kopf")
            }
            XCTAssertTrue(labels(env.view).contains("konvergent"), "die Antwort steht da")
        }
    }
}
