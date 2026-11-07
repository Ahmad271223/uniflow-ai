import XCTest
@testable import UniFlowCore

/// Mathematik in KI-Texten (07.11.2026): Beispiele vom echten iPad und LaTeX-Fragmente -> Unicode
final class MathTextTests: XCTestCase {
    private func p(_ s: String) -> String { MathText.plain(s) }
    private func r(_ s: String) -> String { MathText.render(s) }
    private let S = String(MathText.supOpen), B = String(MathText.subOpen), E = String(MathText.close)

    func testBeispieleVomIPad() {
        // x(t) = e^(-2t)u(t): Exponent hochgestellt, Malpunkt vor u(t)
        XCTAssertEqual(r("x(t) = e^(-2t)u(t)"), "x(t) = e\(S)−2t\(E)·u(t)")
        // Integral in Worten -> ∫ mit Grenzen
        XCTAssertEqual(r("E = integral von -unendlich bis unendlich von |x(t)|^2 dt"), "E = ∫\(B)−∞\(E)\(S)∞\(E) |x(t)|² dt")
        XCTAssertEqual(r("Mit der Epsilon-Definition prüfen"), "Mit der ε-Definition prüfen")
        XCTAssertEqual(r("y[n] = x[n] * h[n]"), "y[n] = x[n] ∗ h[n]")
        XCTAssertEqual(r("cos(4πt)"), "cos(4πt)")
        XCTAssertEqual(r("x^2"), "x²")
        XCTAssertEqual(r("10^-3"), "10⁻³")
        XCTAssertEqual(r("a_n"), "aₙ")
        XCTAssertEqual(r("sqrt(x)"), "√x")
        XCTAssertEqual(r("sqrt(x+1)"), "√(x+1)")
        XCTAssertEqual(r("a <= b, c >= d, e != f, x -> 0"), "a ≤ b, c ≥ d, e ≠ f, x → 0")
        XCTAssertEqual(r("für alle epsilon > 0 gibt es ein delta"), "für alle ε > 0 gibt es ein δ")
        XCTAssertEqual(r("alpha, lambda, sigma, omega, pi"), "α, λ, σ, ω, π")
        XCTAssertEqual(r("2 * 3 = 6"), "2 · 3 = 6")
    }

    func testLaTeX() {
        XCTAssertEqual(r("$E = \\int_{-\\infty}^{\\infty} |x(t)|^2 \\, dt$"), "E = ∫\(B)−∞\(E)\(S)∞\(E) |x(t)|² dt")
        XCTAssertEqual(r("Es gilt $\\frac{1}{2} + \\frac{a}{b+1}$."), "Es gilt ½ + a/(b+1).")
        XCTAssertEqual(r("\\(\\sqrt{x^2+1}\\)"), "√(x²+1)")
        XCTAssertEqual(r("$$\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}$$"), "∑\(B)k=1\(E)ⁿ k = n(n+1)/2")
        XCTAssertEqual(r("\\[ \\lim_{x \\to 0} \\frac{\\sin x}{x} = 1 \\]"), "lim\(B)x → 0\(E) (sin x)/x = 1")
        XCTAssertEqual(r("$\\alpha \\leq \\beta$ und $\\varepsilon > 0$"), "α ≤ β und ε > 0")
        XCTAssertEqual(r("$x \\in \\mathbb{R}$"), "x ∈ ℝ")
        XCTAssertEqual(r("$a_{i+1} = a_i^2$"), "aᵢ₊₁ = aᵢ²")
        XCTAssertEqual(r("$e^{j\\omega t}$"), "e\(S)jω t\(E)")
        XCTAssertEqual(r("Ohne Formelgrenzen: \\alpha + \\beta"), "Ohne Formelgrenzen: α + β")
    }

    func testJSONOhneDoppeltenBackslash() {
        // "\frac" in JSON = Seitenvorschub + "rac", "\theta" = Tab + "heta", "\beta" = Rueckschritt + "eta"
        XCTAssertEqual(r("$\u{0C}rac{1}{2}$"), "½")
        XCTAssertEqual(r("\theta und \u{08}eta"), "θ und β")
    }

    func testBleibtUnveraendert() {
        for s in ["Die Alpha-Version kommt am Pi-Day.", "Beta-Test läuft", "Preis: 5 $ und 10 $", "is_int und list_items",
                  "Ein _kursives_ Wort", "Datei vl02.pdf, Seite 3", "Gamma-Verteilung", "Omega-3-Fettsäuren",
                  "Siehe https://example.org/a_b^c?x=1", "Code `x_1 = y^2` bleibt", "Ein Delta im Fluss",
                  "C++-Code", "<!-- Kommentar -->", "a --> b", "Typ alphanumerisch"] {
            XCTAssertEqual(r(s), s, s)
        }
        let fence = "```\nfor i in range(n): x_i = a^2\n```"
        XCTAssertEqual(r(fence), fence)
    }

    func testIdempotent() {
        for s in ["x(t) = e^(-2t)u(t)", "$\\int_0^\\infty e^{-x^2} dx$", "Epsilon-Delta-Kriterium", "a_k^2 + b_k",
                  "E = integral von 0 bis 1 von x dx", "$\\frac{a}{b}$", "sqrt(x) <= 2"] {
            let once = r(s)
            XCTAssertEqual(r(once), once, s)
        }
    }

    func testPlainOhneMarkierungen() {
        XCTAssertEqual(p("$e^{j\\omega t}$"), "e^(jω t)")
        XCTAssertEqual(p("x_k"), "x_k")
        XCTAssertEqual(p("x^2"), "x²")
        XCTAssertEqual(r("Epsilon-Delta-Kriterium"), "ε-δ-Kriterium")
    }
}
