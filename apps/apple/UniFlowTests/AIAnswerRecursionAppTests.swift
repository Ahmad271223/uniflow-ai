import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Absturz am iPad Air 4 (18.11.2026, Build 45): eine lange Rechen-Antwort der KI-Hilfe (Brueche, Kaesten, Merke)
/// liess den Stapel des Hauptfadens ueberlaufen (EXC_BAD_ACCESS in `ModifiedContent._viewListCount`, 511 Rahmen
/// nur SwiftUI). Ursache: `MathNodeView` und `AIMarkdownBlocks` enthielten sich selbst im eigenen Typ; SwiftUI zaehlt
/// die Teile mancher Container ueber den Typ und lief endlos. Diese Tests legen die Antwort in die Container der App
/// (Stapel, faule Liste, Liste, ViewThatFits) und rechnen das Layout; erfundene Inhalte, kein Netz.
@MainActor
final class AIAnswerRecursionAppTests: XCTestCase {
    /// Antwort im Stil der KI-Hilfe: Ueberschrift, Schritte, Block-Formeln mit Bruch in Bruch, Wurzel, Hochzahl,
    /// Klammern, Ergebnis-Kasten, Merke-Kasten mit Formel darin, Tabelle
    static let answer = """
    ## Aufgabe 1: Bruch vereinfachen

    **Schritt 1:** Zähler und Nenner getrennt ausrechnen.

    $$\\frac{\\frac{3+4i}{1-2i}}{\\sqrt{x^2+1}} = \\left(\\frac{a_1^{2}}{b_{k+1}}\\right)^{n}$$

    **Schritt 2:** Ergebnis.

    $$\\boxed{z = \\frac{-1+2i}{\\sqrt[3]{5}}}$$

    > **Merke:** Mit dem konjugierten Nenner erweitern:
    >
    > $$\\frac{a+bi}{c+di} = \\frac{(a+bi)(c-di)}{c^2+d^2}$$

    | Größe | Wert |
    |---|---|
    | $|z|$ | $\\sqrt{5}$ |

    ---

    Fertig.
    """

    private func layout<V: View>(_ v: V, width: CGFloat = 400) -> CGSize {
        let host = UIHostingController(rootView: AnyView(v.frame(width: width)))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 2400)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: width, height: 20_000))
    }

    private static var text: some View { AIMarkdownText(answer, size: TutorPanel.answerSize) }

    func testAnswerInPlainStack() {
        let size = layout(VStack(alignment: .leading, spacing: 18) { ForEach(0..<2, id: \.self) { _ in Self.text } })
        XCTAssertGreaterThan(size.height, 300)
    }

    func testAnswerInLazyStack() {
        let size = layout(ScrollView { LazyVStack(alignment: .leading, spacing: 18) { ForEach(0..<3, id: \.self) { _ in Self.text } } })
        XCTAssertGreaterThan(size.height, 0)
    }

    func testAnswerInList() {
        let size = layout(List { ForEach(0..<2, id: \.self) { _ in Self.text } }.frame(height: 900))
        XCTAssertGreaterThan(size.height, 0)
    }

    func testAnswerInViewThatFitsAndGroup() {
        let size = layout(ViewThatFits(in: .vertical) { Group { Self.text; Self.text } ; Self.text })
        XCTAssertGreaterThan(size.height, 0)
    }

    func testFormulaDirectlyInContainers() {
        let tex = "\\boxed{\\frac{\\sqrt{x^{2}}}{\\left(1+\\frac{1}{n}\\right)^{n}}}"
        XCTAssertGreaterThan(layout(LazyVStack { MathFormulaView(latex: tex); MathFormulaView(latex: tex) }).height, 0)
        XCTAssertGreaterThan(layout(HStack { MathFormulaView(latex: tex) }).height, 0)
        XCTAssertGreaterThan(layout(ViewThatFits { MathFormulaView(latex: tex); Text("x") }).height, 0)
    }

    /// Sehr tief verschachteltes LaTeX: kein Stapelueberlauf, der Text bleibt lesbar (Rueckfall statt gesetzter Formel)
    func testVeryDeepFormulaFallsBackToText() {
        var tex = "x"
        for _ in 0..<40 { tex = "\\frac{1}{1+\(tex)}" }
        let lines = MathLayout.parse(tex)
        XCTAssertNotNil(lines)
        XCTAssertGreaterThan(lines?.map(\.depth).max() ?? 0, MathNodeView.maxDepth)
        XCTAssertGreaterThan(layout(LazyVStack { MathFormulaView(latex: tex) }).height, 0)
    }

    /// flache Formel: Tiefe wie gedacht (Zeile + Bruch + Teile)
    func testDepthOfSimpleFormula() {
        let lines = MathLayout.parse("\\frac{a}{b}")
        XCTAssertNotNil(lines)
        XCTAssertLessThanOrEqual(lines?.map(\.depth).max() ?? 99, 4)
    }
}
