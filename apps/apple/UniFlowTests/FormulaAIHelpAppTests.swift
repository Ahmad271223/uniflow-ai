import SwiftUI
import XCTest
@testable import UniFlow

/// Formeln in der KI-Hilfe lesbar (07.11.2026, Wunsch des Inhabers: "statt epsilon wirklich ε, kein ^2, sondern das
/// richtige hoch 2"): `FormulaText.render(_:rich:)` fuer Antworten in `AIMarkdownText` und echte Hoch-/Tiefstellung
/// ueber `AIMarkdown.styled`. Die Faelle stimmen mit dem Python-Nachbau ueberein, mit dem die Regeln entworfen wurden.
/// Klartext (Wochentest, Karteikarten) prueft `QuizOptionsAppTests.testFormulasBecomeReadableText`.
@MainActor
final class FormulaAIHelpAppTests: XCTestCase {
    /// rich mit sichtbaren Marken: ^[...] = echt hochgestellt, _[...] = echt tiefgestellt
    private func rich(_ s: String) -> String {
        String(FormulaText.render(s, rich: true).map { c -> String in
            c == FormulaText.supOpen ? "^[" : c == FormulaText.subOpen ? "_[" : c == FormulaText.scriptClose ? "]" : String(c)
        }.joined())
    }

    func testFormulasInAnswersReadLikeATextbook() {
        XCTAssertEqual(rich("Für jedes $\\epsilon > 0$ gibt es ein $N$ mit $|a_n - a| < \\epsilon$ für alle $n \\geq N$."), "Für jedes ε > 0 gibt es ein N mit |aₙ - a| < ε für alle n ≥ N.")
        XCTAssertEqual(rich("Für jedes epsilon > 0 gibt es ein delta > 0"), "Für jedes ε > 0 gibt es ein δ > 0")
        XCTAssertEqual(rich("Die epsilon-Umgebung und das Epsilon"), "Die ε-Umgebung und das Epsilon")
        XCTAssertEqual(rich("x^2 + 2x + 1 = (x+1)^2"), "x² + 2x + 1 = (x+1)²")
        XCTAssertEqual(rich("$e^{-x^2/2}$"), "e^[-x²/2]")
        XCTAssertEqual(rich("$\\lim_{n \\to \\infty} \\frac{1}{n} = 0$"), "lim_[n → ∞] 1/n = 0")
        XCTAssertEqual(rich("$\\int_0^1 x^2 \\, dx = \\frac{1}{3}$"), "∫₀¹ x² dx = ⅓")
        XCTAssertEqual(rich("$\\sum_{i=1}^{n} i$"), "Σ_[i=1]ⁿ i")
        XCTAssertEqual(rich("$\\sqrt{2}$ und $\\sqrt{x+1}$ und $\\sqrt[3]{8} = 2$"), "√2 und √(x+1) und ³√8 = 2")
        XCTAssertEqual(rich("$x_1x_2$ und $x_{i+1}$"), "x₁x₂ und xᵢ₊₁")
        XCTAssertEqual(rich("e^(-x/2) und 2^(n+1) und f^(n)"), "e^[-x/2] und 2ⁿ⁺¹ und f⁽ⁿ⁾")
        XCTAssertEqual(rich("$A^T$ und $A^{-1}$"), "A^[T] und A⁻¹")
        XCTAssertEqual(rich("Winkel $90^\\circ$"), "Winkel 90°")
        XCTAssertEqual(rich("a <= b, a >= b, a != b, A => B, A <=> B, x -> 0"), "a ≤ b, a ≥ b, a ≠ b, A ⇒ B, A ⇔ B, x → 0")
        XCTAssertEqual(rich("Code `x_1 = a^2` bleibt"), "Code `x_1 = a^2` bleibt")
        XCTAssertEqual(rich("[Link](https://ex.org/a_b) und https://ex.org/x_y"), "[Link](https://ex.org/a_b) und https://ex.org/x_y")
        XCTAssertEqual(rich("Pfad C:\\Users\\name und \\n bleibt"), "Pfad C:\\Users\\name und \\n bleibt")
        XCTAssertEqual(rich("Kosten 5$ und 10$"), "Kosten 5$ und 10$")
        XCTAssertEqual(rich("$\\mathbb{R}^n$, $\\mathcal{O}(n^2)$"), "ℝⁿ, 𝒪(n²)")
        XCTAssertEqual(rich("$\\binom{n}{k}$"), "(n über k)")
        XCTAssertEqual(rich("$\\bar{x}$ und $\\hat{p}$ und $\\vec{v}$"), "x̄ und p̂ und v⃗")
        XCTAssertEqual(rich("$\\{1, 2\\}$"), "{1, 2}")
        XCTAssertEqual(rich("$$\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}$$"), " a = b \n c = d ")
        XCTAssertEqual(rich("$f'(x) = \\lim_{h \\to 0} \\frac{f(x+h) - f(x)}{h}$"), "f'(x) = lim_[h → 0] (f(x+h) - f(x))/h")
        XCTAssertEqual(rich("\\(a^2 + b^2 = c^2\\)"), "a² + b² = c²")
        XCTAssertEqual(rich("\\[ \\Delta = b^2 - 4ac \\]"), " Δ = b² - 4ac ")
        XCTAssertEqual(rich("alpha_1 und lambda und pi r^2"), "α₁ und λ und π r²")
        XCTAssertEqual(rich("Alphabet, Betafunktion, Mutter, Pizza, Delta, api, Tau, Chips"), "Alphabet, Betafunktion, Mutter, Pizza, Delta, api, Tau, Chips")
        XCTAssertEqual(rich("30 psi und im nu"), "30 psi und im nu")
        XCTAssertEqual(rich("$\\operatorname{rank}(A)$ und $\\mathfrak{g}$ und $\\foo$"), "rank(A) und g und foo")
        XCTAssertEqual(rich("Funktion_(siehe oben)"), "Funktion_(siehe oben)")
        XCTAssertEqual(rich("_kursiv_ und **fett**"), "_kursiv_ und **fett**")
        XCTAssertEqual(rich("snake_case und max_iter"), "snake_case und max_iter")
        XCTAssertEqual(rich("$x^{y^2}$"), "x^[y²]")
        XCTAssertEqual(rich("$\\frac{x^2}{2}$"), "x²/2")
        XCTAssertEqual(rich("$O(n \\log n)$ und $\\sin^2 x + \\cos^2 x = 1$"), "O(n log n) und sin² x + cos² x = 1")
        XCTAssertEqual(rich("sqrt(x) und sqrt(x+1)"), "√x und √(x+1)")
        XCTAssertEqual(rich("Δx^2"), "Δx²")
        XCTAssertEqual(rich("$a \\cdot b \\times c$"), "a · b × c")
        XCTAssertEqual(rich("$\\forall \\varepsilon > 0 \\, \\exists \\delta > 0$"), "∀ ε > 0 ∃ δ > 0")
        XCTAssertEqual(rich("2pi r und 3alpha"), "2π r und 3α")
        XCTAssertEqual(rich("a\\_b und $x \\_ y$"), "a\\_b und x \\_ y")
        XCTAssertEqual(rich("x^2 im **Fett** und *kursiv*"), "x² im **Fett** und *kursiv*")
    }

    func testPlainTextKeepsItsFormsAndConvertsGreekNames() {
        XCTAssertEqual(FormulaText.render("a\\_b"), "a_b")
        XCTAssertEqual(FormulaText.render("Für jedes epsilon > 0"), "Für jedes ε > 0")
        XCTAssertEqual(FormulaText.render("x^{a+b} und a -> b"), "x^(a+b) und a -> b", "ohne rich: keine Marken, keine Pfeile")
        XCTAssertEqual(FormulaText.render("$\\frac{1}{2}$ und $\\sqrt{2}$"), "1/2 und √(2)")
    }

    /// Marken werden zu kleinerer, hoeher bzw. tiefer gestellter Schrift; im Text bleiben keine Marken
    func testStyledAnswerRaisesAndLowersScripts() {
        let a = AIMarkdown.styled("e^(-x/2) und **x^{a+b}** und $\\lim_{n \\to \\infty}$", size: 15)
        let text = String(a.characters)
        XCTAssertEqual(text, "e-x/2 und xa+b und limn → ∞")
        XCTAssertFalse(text.contains(FormulaText.supOpen) || text.contains(FormulaText.subOpen) || text.contains(FormulaText.scriptClose))
        var up: [String] = [], down: [String] = []
        for run in a.runs {
            let offset = run.attributes[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self] ?? 0
            if offset > 0 { up.append(String(a[run.range].characters)) }
            if offset < 0 { down.append(String(a[run.range].characters)) }
        }
        XCTAssertEqual(up, ["-x/2", "a+b"])
        XCTAssertEqual(down, ["n → ∞"])
        XCTAssertEqual(String(AIMarkdown.styled("Für jedes epsilon > 0 ist x^2 >= 0", size: 15).characters), "Für jedes ε > 0 ist x² ≥ 0")
        XCTAssertEqual(String(AIMarkdown.styled("`x_1` und x_1 und a\\_b", size: 15).characters), "x_1 und x₁ und a_b", "Code bleibt, \\_ bleibt _")
        XCTAssertEqual(String(AIMarkdown.styled("**fett** und `code`", size: 15).characters), "fett und code")
    }

    /// Vorschau unter "Zuletzt" ohne LaTeX
    func testRecentPreviewShowsReadableFormulas() {
        XCTAssertEqual(AIStartView.plain("## Grenzwert\n- $\\epsilon > 0$ und $a_n$"), "Grenzwert ε > 0 und aₙ")
    }
}
