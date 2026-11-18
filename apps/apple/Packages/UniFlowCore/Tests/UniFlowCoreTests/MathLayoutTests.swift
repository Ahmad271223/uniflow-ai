import XCTest
@testable import UniFlowCore

/// Block-Formeln als Baum (MathLayout, 18.11.2026): genau die Formeln der ChatGPT-aehnlichen Antwort zu Aufgabe 5.1
/// (GU05) und typische Faelle aus Mathe/ET; Unbekanntes bleibt als Text, nichts geht verloren.
final class MathLayoutTests: XCTestCase {

    private func one(_ s: String) -> MathNode { MathLayout.parse(s)![0] }

    func testFractionOfComplexNumbers() {
        XCTAssertEqual(one(#"\frac{3+4i}{1-2i}"#),
                       .frac(.row([.number("3"), .op("+"), .number("4"), .ident("i")]),
                             .row([.number("1"), .op("−"), .number("2"), .ident("i")])))
        XCTAssertTrue(one(#"\frac{3+4i}{1-2i}"#).isTall)
        XCTAssertEqual(one(#"\frac{3+4i}{1-2i}"#).plain, "(3 + 4i)/(1 − 2i)")
    }

    func testBoxedResultAndSign() {
        XCTAssertEqual(one(#"\boxed{-1 + 2i}"#), .boxed(.row([.symbol("−"), .number("1"), .op("+"), .number("2"), .ident("i")])))
        XCTAssertEqual(one(#"\boxed{i}"#), .boxed(.ident("i")))
        XCTAssertEqual(one(#"\boxed{\frac{1}{2} + \frac{1}{2}i}"#).plain, "½ + ½i".replacingOccurrences(of: "½", with: "1/2"))
    }

    func testPowersProductsAndUnaryMinus() {
        XCTAssertEqual(one(#"= 3 + 6i + 4i + 8i^2"#),
                       .row([.op("="), .number("3"), .op("+"), .number("6"), .ident("i"), .op("+"), .number("4"), .ident("i"),
                             .op("+"), .number("8"), .scripts(.ident("i"), sup: .number("2"), sub: nil)]))
        XCTAssertEqual(one(#"8 \cdot (-1)"#), .row([.number("8"), .op("·"), .symbol("("), .symbol("−"), .number("1"), .symbol(")")]))
        XCTAssertEqual(one(#"(2i)^2"#), .row([.symbol("("), .number("2"), .ident("i"), .scripts(.symbol(")"), sup: .number("2"), sub: nil)]))
        XCTAssertEqual(one(#"x_1^2"#), .scripts(.ident("x"), sup: .number("2"), sub: .number("1")))
        XCTAssertEqual(one(#"e^{-2t}"#), .scripts(.ident("e"), sup: .row([.symbol("−"), .number("2"), .ident("t")]), sub: nil))
    }

    func testEveryFormulaOfTheGU05AnswerParsesWithoutLeftovers() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../../packages/shared-contracts/fixtures/ai-tutor/erklaeren-gu05-5-1.md").standardized
        let text = try String(contentsOf: url, encoding: .utf8)
        let blocks = text.components(separatedBy: "\n").filter { $0.hasPrefix("$$") && $0.hasSuffix("$$") && $0.count > 4 }
        XCTAssertGreaterThan(blocks.count, 25)
        for b in blocks {
            let tex = String(b.dropFirst(2).dropLast(2))
            let lines = try XCTUnwrap(MathLayout.parse(tex), tex)
            XCTAssertEqual(lines.count, 1, tex)
            let plain = lines[0].plain
            XCTAssertFalse(plain.contains("\\") || plain.contains("{") || plain.contains("frac") || plain.contains("boxed"), "\(tex) -> \(plain)")
        }
    }

    func testLeftRightSqrtTextGreekAndLines() {
        XCTAssertEqual(one(#"\left(\frac{a}{b}\right)^2"#),
                       .scripts(.fenced("(", .frac(.ident("a"), .ident("b")), ")"), sup: .number("2"), sub: nil))
        XCTAssertEqual(one(#"\sqrt{2}"#), .sqrt(.number("2"), index: nil))
        XCTAssertEqual(one(#"\sqrt[3]{x}"#), .sqrt(.ident("x"), index: .number("3")))
        XCTAssertEqual(one(#"\text{Realteil } x"#), .row([.text("Realteil "), .ident("x")]))
        XCTAssertEqual(one(#"\alpha \le \pi"#), .row([.ident("α"), .op("≤"), .ident("π")]))
        XCTAssertEqual(one(#"\sin x"#), .row([.text("sin"), .ident("x")]))
        XCTAssertEqual(one(#"\mathbb{R}"#), .symbol("ℝ"))
        XCTAssertEqual(one(#"0,5 + 1.25"#), .row([.number("0,5"), .op("+"), .number("1.25")]))
        XCTAssertEqual(MathLayout.parse(#"\begin{aligned} a &= b \\ &= c \end{aligned}"#)?.count, 2)
        XCTAssertNil(MathLayout.parse("   "))
        // unbekannte Befehle bleiben als Text, kaputte Klammern brechen nichts
        XCTAssertEqual(one(#"\foo{x}"#), .row([.text("foo"), .ident("x")]))
        XCTAssertNotNil(MathLayout.parse(#"\frac{1}{2"#))
        XCTAssertNotNil(MathLayout.parse(#"a } b \right) c"#))
        XCTAssertEqual(MathLayout.parse(#"a } b \right) c"#)?.count, 1)
    }

    func testMathTextKnowsBoxed() {
        XCTAssertEqual(MathText.plain(#"$\boxed{-1+2i}$"#), "-1+2i")
    }
}
