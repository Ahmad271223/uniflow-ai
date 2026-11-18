import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Bildtest der KI-Antwort "Erklären" (18.11.2026, Auftrag des Inhabers: "genau so wie ChatGPT"): eine feste,
/// ChatGPT-aehnliche Antwort zu Aufgabe 5.1 (GU05, Brueche komplexer Zahlen) und die alte, flache Antwort, gezeichnet in
/// der Breite der KI-Leiste auf dem iPad (400 pt) und auf dem iPhone (393 pt). Bilder nach UF_SCREENSHOT_DIR (wenn gesetzt).
@MainActor
final class KIErklaerenBildAppTests: XCTestCase {

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../packages/shared-contracts/fixtures/ai-tutor").standardized

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    /// Antwort wie in der KI-Leiste (Lesegroesse 15 pt)
    /// Quelle der Antwort: die offene Seite 1 des Uebungsblatts (die KI nennt sie als [1])
    static let sources: [JSONValue] = [["n": 1, "page": 1, "title": "GU05", "file_id": "f-gu05", "current": true, "cited": true]]

    /// Antwort wie in der KI-Leiste: Text ohne Quellenmarke, darunter "Quelle: Seite 1"
    private func answer(_ text: String) -> some View {
        let m = TutorPanel.Message(fromUser: false, text: text, sources: Self.sources, mode: "explain")
        return VStack(alignment: .leading, spacing: 10) {
            AIMarkdownText(TutorPanel.shownText(m), size: TutorPanel.answerSize)
            TutorSourceLine(cited: m.sources, fileID: "f-gu05", open: { _, _ in })
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .background(UF.surface)
    }

    /// Ganze Hoehe zeichnen (ImageRenderer: auch sehr hohe Antworten, ohne Fenster); liefert die Hoehe (pt)
    @discardableResult
    private func render(_ view: some View, width: CGFloat, name: String, style: ColorScheme = .light) -> CGFloat {
        let content = view.frame(width: width).environment(\.colorScheme, style)
        let host = UIHostingController(rootView: AnyView(content))
        let height = host.sizeThatFits(in: CGSize(width: width, height: 20_000)).height
        guard let dir = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !dir.isEmpty else { return height }
        let renderer = ImageRenderer(content: content.frame(height: height))
        renderer.scale = 2
        var png = renderer.uiImage?.pngData()
        if png == nil {
            // ImageRenderer zeichnet keine Ansichten mit UIKit darunter (seitlich wischbare Formeln): dann die Ebenen
            // des gehosteten Fensters zeichnen
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
            window.overrideUserInterfaceStyle = style == .dark ? .dark : .light
            window.rootViewController = host
            window.isHidden = false
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            png = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).pngData { ctx in
                host.view.layer.render(in: ctx.cgContext)
            }
            window.isHidden = true
        }
        if let png {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
        return height
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }
    private var width: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 400 : 393 }

    // MARK: Bloecke, Kopieren, Quellen

    func testBlocksOfTheChatGPTAnswer() throws {
        let b = AIMarkdown.blocks(try Self.fixture("erklaeren-gu05-5-1.md"))
        func count(_ f: (AIMarkdown.Block) -> Bool) -> Int { b.filter(f).count }
        XCTAssertEqual(count { $0 == .rule }, 5)
        XCTAssertEqual(b.compactMap { if case .heading(2, let t) = $0 { return t } else { return nil } },
                       ["1. Was ist überhaupt eine komplexe Zahl?", "2. Aufgabe (a)", "3. Aufgabe (b)", "4. Aufgabe (c)",
                        "5. Die wichtigste Regel für deine Klausur"])
        XCTAssertEqual(count { if case .heading(3, _) = $0 { return true } else { return false } }, 12)
        let formulas = b.compactMap { if case .math(let t) = $0 { return t } else { return nil } }
        XCTAssertGreaterThanOrEqual(formulas.count, 25)
        XCTAssertTrue(formulas.contains(#"\boxed{-1 + 2i}"#) && formulas.contains(#"\frac{3+4i}{1-2i}"#))
        for f in formulas { XCTAssertNotNil(MathLayout.parse(f), f) }
        guard case .quote(let merke)? = b.first(where: { if case .quote = $0 { return true } else { return false } }) else { return XCTFail("Merke-Kasten") }
        XCTAssertEqual(merke.first, .paragraph("**Merke: Komplexe Brüche lösen – immer gleich!**"))
        if case .numbered(let steps) = merke[1] { XCTAssertEqual(steps.count, 5) } else { XCTFail("fuenf Schritte") }
        guard case .table(let header, let rows)? = b.first(where: { if case .table = $0 { return true } else { return false } }) else { return XCTFail("Tabelle") }
        XCTAssertEqual(header, ["Aufgabe", "Normaldarstellung"])
        XCTAssertEqual(rows, [["(a)", "$-1 + 2i$"], ["(b)", "$i$"], ["(c)", #"$\frac{1}{2} + \frac{1}{2}i$"#]])
        // mehrzeilige Formel, \[ \], Formel allein im Absatz, Trennlinie mit Sternen, Betrag in der Tabelle
        XCTAssertEqual(AIMarkdown.blocks("$$\n\\frac{a}{b}\n= c\n$$\nweiter"), [.math("\\frac{a}{b}\n= c"), .paragraph("weiter")])
        XCTAssertEqual(AIMarkdown.blocks("\\[ x^2 \\]"), [.math("x^2")])
        XCTAssertEqual(AIMarkdown.blocks("$x + yi$"), [.math("x + yi")])
        XCTAssertEqual(AIMarkdown.blocks("Preis 5 $ und $x$"), [.paragraph("Preis 5 $ und $x$")])
        XCTAssertEqual(AIMarkdown.blocks("***"), [.rule])
        XCTAssertEqual(AIMarkdown.cells("| $|z|$ | b |"), ["$|z|$", "b"])
        // abgeschnittene Antwort (Formel ohne Ende) bricht nichts
        XCTAssertEqual(AIMarkdown.blocks("$$\n\\frac{1}{2"), [.math("\\frac{1}{2")])
    }

    func testSourceMarkMovesBelowAndCopyIsClean() throws {
        let old = try Self.fixture("erklaeren-gu05-5-1-alt.md")
        let m = TutorPanel.Message(fromUser: false, text: old, sources: Self.sources, mode: "explain")
        XCTAssertFalse(TutorPanel.shownText(m).contains("[1]"))
        XCTAssertTrue(TutorPanel.shownText(TutorPanel.Message(fromUser: false, text: "Intervall [1] bleibt")).contains("[1]"), "ohne Quellen bleibt der Text")
        XCTAssertEqual(TutorPanel.sourceLabel(Self.sources[0], fileID: "f-gu05"), "Seite 1")
        XCTAssertEqual(TutorPanel.sourceLabel(["n": 2, "page": 4, "title": "Skript", "file_id": "f-2"], fileID: "f-gu05"), "Skript, Seite 4")

        let copy = TutorPanel.copyText(for: TutorPanel.Message(fromUser: false, text: try Self.fixture("erklaeren-gu05-5-1.md"), sources: Self.sources))
        for bad in ["$", "\\frac", "\\boxed", "**", "## ", "> ", "|---", "---"] { XCTAssertFalse(copy.contains(bad), "Kopie enthaelt \(bad)") }
        for good in ["Aufgabe (a)", "Schritt 2: Zähler ausmultiplizieren", "(3 + 4i)/(1 − 2i)", "= 3 + 6i + 4i + 8i²", "−1 + 2i",
                     "Merke: Komplexe Brüche lösen – immer gleich!", "Aufgabe | Normaldarstellung", "(c) | ½ + ½i",
                     "Hast du verstanden, warum bei Aufgabe (a) aus 8i² plötzlich"] {
            XCTAssertTrue(copy.contains(good), "Kopie ohne \(good)")
        }
        XCTAssertFalse(copy.contains("\n\n\n"))
    }

    /// Lange Antwort: kein Ueberstand in der schmalsten Breite (Split View 300 pt), Formeln und Kaesten vorhanden,
    /// Zerlegen schnell (beim Scrollen oft neu gezeichnet)
    func testLongAnswerFitsAndIsQuick() throws {
        let text = try Self.fixture("erklaeren-gu05-5-1.md")
        let start = Date()
        for _ in 0..<20 { _ = AIMarkdown.blocks(text) }
        XCTAssertLessThan(Date().timeIntervalSince(start) / 20, 0.05, "Zerlegen unter 50 ms")
        for width: CGFloat in [300, 393, 400] {
            let host = UIHostingController(rootView: AIMarkdownText(text, size: TutorPanel.answerSize).frame(width: width))
            let size = host.sizeThatFits(in: CGSize(width: width, height: 20_000))
            XCTAssertLessThanOrEqual(size.width, width + 0.5, "kein Ueberstand bei \(width) pt")
            XCTAssertGreaterThan(size.height, 1500, "die ganze Antwort (\(width) pt): \(size.height)")
        }
    }

    func testRenderAnswersForGU05() throws {
        let chatgpt = try Self.fixture("erklaeren-gu05-5-1.md")
        let old = try Self.fixture("erklaeren-gu05-5-1-alt.md")
        let stage = ProcessInfo.processInfo.environment["UF_BILD_STUFE"] ?? "nachher"
        let hOld = render(answer(old), width: width, name: "\(stage)-\(device)-alte-antwort")
        let hNew = render(answer(chatgpt), width: width, name: "\(stage)-\(device)-chatgpt-stil")
        render(answer(chatgpt), width: width, name: "\(stage)-\(device)-chatgpt-stil-dunkel", style: .dark)
        XCTAssertGreaterThan(hOld, 60)
        XCTAssertGreaterThan(hNew, hOld * 4, "die lange Antwort ist deutlich hoeher als der eine Absatz")
    }
}
