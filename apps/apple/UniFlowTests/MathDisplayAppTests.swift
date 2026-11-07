import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Mathematik in KI-Texten in richtigen Zeichen (07.11.2026, Wunsch des Inhabers): Wochentest-Aufgabe mit Integral und
/// Antwortoptionen, Karteikarte mit x², KI-Antwort mit ε. Erfundene Inhalte, kein Netz. Mit UF_SCREENSHOT_DIR
/// (xcodebuild: TEST_RUNNER_UF_SCREENSHOT_DIR) entstehen Bilder der drei Ansichten.
@MainActor
final class MathDisplayAppTests: XCTestCase {

    private func shot(_ env: HostedEnvironment, _ name: String) {
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

    private func visible(_ env: HostedEnvironment) -> String {
        HostedEnvironment.accessibilityAutomation(true)
        defer { HostedEnvironment.accessibilityAutomation(false) }
        env.pump(0.3)
        return env.labels().joined(separator: "\n")
    }

    private func assertClean(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for bad in ["\\int", "\\frac", "$", "^2", "^(", "_{", "integral von", "Epsilon-", "\u{E000}", "\u{E001}", "\u{E002}"] {
            XCTAssertFalse(text.contains(bad), "\(bad) in \(text)", file: file, line: line)
        }
    }

    // MARK: - Bausteine

    func testAttributedHatEchteHochUndTiefstellung() {
        let a = FormulaText.attributed("E = $\\int_{-\\infty}^{\\infty} |x(t)|^2 \\, dt$", size: 16)
        let plain = String(a.characters)
        XCTAssertEqual(plain, "E = ∫−∞∞ |x(t)|² dt")
        let offsets = a.runs.compactMap { $0.baselineOffset }
        XCTAssertTrue(offsets.contains { $0 > 0 } && offsets.contains { $0 < 0 }, "Grenzen hoch- und tiefgestellt")
        XCTAssertEqual(String(FormulaText.attributed("x^2 + 10^-3 + a_n", size: 14).characters), "x² + 10⁻³ + aₙ")
        XCTAssertEqual(FormulaText.render("e^{j\\omega t}"), "e^(jω t)")
    }

    func testMarkdownAntwortMitEpsilon() {
        let a = AIMarkdown.styled("Mit der **Epsilon-Definition** prüfen: für alle epsilon > 0 gilt |a_n - a| < epsilon.", size: 15)
        let s = String(a.characters)
        XCTAssertEqual(s, "Mit der ε-Definition prüfen: für alle ε > 0 gilt |aₙ - a| < ε.")
        XCTAssertTrue(a.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Fett bleibt")
        // Code bleibt unveraendert
        XCTAssertEqual(String(AIMarkdown.styled("Code `x_1 = y^2`", size: 15).characters), "Code x_1 = y^2")
        // Vorschau unter "Zuletzt" ohne Markierungen
        XCTAssertEqual(AIStartView.plain("## Ergebnis\n$\\frac{1}{2} x^2$"), "Ergebnis ½ x²")
    }

    // MARK: - Ansichten

    func testWochentestAufgabeMitIntegral() throws {
        let q = JSONValue.object([
            "nr": .number(1), "type": .string("mc"), "difficulty": .string("mittel"), "points": .number(5),
            "question": .string("Berechne die Energie E = integral von -unendlich bis unendlich von |x(t)|^2 dt für x(t) = e^(-2t)u(t)."),
            "options": .array([.string("A $\\frac{1}{4}$"), .string("B $\\frac{1}{2}$"), .string("C sqrt(2)"), .string("D 10^-3")]),
            "answer": .string("A"),
        ])
        let env = try hostWithEnvironment(
            ScrollView { ExamQuestionCard(q: q, index: 0, count: 15, submitted: false, feedback: nil, answer: .constant("")).padding(24) }
                .background(UF.bg), size: CGSize(width: 834, height: 700))
        env.pump(0.5)
        let text = visible(env)
        XCTAssertTrue(text.contains("∫"), text)
        XCTAssertTrue(text.contains("|x(t)|² dt"), text)
        XCTAssertTrue(text.contains("¼") && text.contains("½") && text.contains("√2") && text.contains("10⁻³"), text)
        assertClean(text)
        shot(env, "mathe-wochentest-integral")
    }

    func testKarteikarteMitQuadrat() throws {
        let env = try hostWithEnvironment(
            VStack(spacing: 20) {
                FlashcardFace(label: "Frage", text: "Was ist die Ableitung von x^2 + sqrt(x)?")
                FlashcardFace(label: "Antwort", text: "$2x + \\frac{1}{2\\sqrt{x}}$", front: false, context: "Ableitung von x^2 + sqrt(x)")
            }.padding(24).background(UF.bg), size: CGSize(width: 834, height: 820))
        env.pump(0.5)
        let text = visible(env)
        XCTAssertTrue(text.contains("x² + √x"), text)
        XCTAssertTrue(text.contains("2x + 1/(2√x)"), text)
        assertClean(text)
        shot(env, "mathe-karteikarte")
    }

    func testKIAntwortMitEpsilon() throws {
        let answer = """
        ## Konvergenz prüfen [S. 3]
        Mit der Epsilon-Definition prüfen: Zu jedem epsilon > 0 gibt es ein $N \\in \\mathbb{N}$ mit $|a_n - a| < \\varepsilon$ für alle $n \\geq N$.

        - Signal: $x(t) = e^{-2t} u(t)$, Energie $E = \\int_{-\\infty}^{\\infty} |x(t)|^2 \\, dt = \\frac{1}{4}$
        - Faltung: y[n] = x[n] * h[n]
        - cos(4πt) bleibt, alpha -> 0
        """
        let env = try hostWithEnvironment(
            ScrollView { AIMarkdownText(answer, size: TutorPanel.answerSize).padding(24) }.background(UF.bg),
            size: CGSize(width: 834, height: 600))
        env.pump(0.5)
        let text = visible(env)
        XCTAssertTrue(text.contains("ε-Definition"), text)
        XCTAssertTrue(text.contains("ε > 0") && text.contains("N ∈ ℕ") && text.contains("|aₙ - a| < ε") && text.contains("n ≥ N"), text)
        XCTAssertTrue(text.contains("∫") && text.contains("|x(t)|² dt = ¼"), text)
        XCTAssertTrue(text.contains("y[n] = x[n] ∗ h[n]") && text.contains("cos(4πt)") && text.contains("α → 0"), text)
        assertClean(text)
        shot(env, "mathe-ki-antwort")
    }
}
