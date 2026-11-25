import PDFKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Notizzettel wie echte Klebezettel (Auftrag des Inhabers 25.11.2026): Aussehen, Groessen, liniertes Zettelpapier,
/// Anlegen mit dem Werkzeug "Haftnotiz", Umgestalten, Tarif (ab Pro AI; Plus behaelt die gelbe Haftnotiz).
@MainActor
final class StickyNoteAppTests: XCTestCase {

    private func note(_ c: StickyNote.Choice, text: String = "Klausur am 12.02.\nRaum F102") -> JSONValue {
        let o = StickyNote.note(id: "n", x: 200, y: 120, choice: c)
        return TextBlock.setting([TextBlock.Run(text: text, style: TextBlock.baseStyle(o))], in: o)
    }

    /// Zettel sind mindestens so hoch wie breit, wachsen mit dem Text, und auf liniertem Zettelpapier sitzt jede Zeile
    /// auf einer Linie des Zettels.
    func testGroesseUndLinien() {
        for s in StickyNote.sizes {
            let o = note(StickyNote.Choice(size: s.id))
            let size = TextBlockRender.size(o)
            XCTAssertEqual(Double(size.width), s.side)
            XCTAssertEqual(Double(size.height), s.side, accuracy: 0.01, "\(s.title): quadratisch mit wenig Text")
        }
        let long = note(StickyNote.Choice(size: "s"), text: String(repeating: "Viel Text auf einem kleinen Zettel. ", count: 12))
        XCTAssertGreaterThan(TextBlockRender.size(long).height, 121, "waechst mit dem Text")

        let lined = note(StickyNote.Choice(paper: "lined", size: "l"), text: "eins\nzwei\ndrei und noch so viel Text, dass die Zeile umbricht")
        let l = TextBlockRender.layout(lined)
        XCTAssertEqual(l.step, CGFloat(StickyNote.lineStep))
        let baselines = l.baselines.map(Double.init)
        XCTAssertGreaterThanOrEqual(baselines.count, 4)
        for (i, b) in baselines.enumerated() {
            // Linie k des Zettels: k * 22 - 4.8 (vom Textanfang)
            let k = (b + TextBlock.baselineDrop) / StickyNote.lineStep
            XCTAssertEqual(k, k.rounded(), accuracy: 0.002, "Zeile \(i + 1) sitzt auf einer Linie des Zettels")
        }
        XCTAssertNil(TextBlockRender.layout(note(StickyNote.Choice(paper: "grid"))).step, "kariert: frei gesetzt")
    }

    /// Anzeige: Zettel in seiner Papierfarbe mit Schatten; Tesafilm, Pinnnadel, geknickte Ecke und Linien sind zu sehen.
    /// Gegenprobe: der einfache Klebezettel hat an diesen Stellen nur Papier.
    func testAussehen() throws {
        func image(_ c: StickyNote.Choice) -> UIImage {
            let o = note(c, text: "")
            let size = TextBlockRender.size(o)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            return UIGraphicsImageRenderer(size: size, format: format).image { TextBlockRender.drawBackground(o, size: size, in: $0.cgContext, shadow: false) }
        }
        let rosa = "#ffd3e0"
        let plain = image(StickyNote.Choice(color: rosa))
        let mid = try XCTUnwrap(plain.pixel(at: CGPoint(x: 82, y: 90)))
        XCTAssertTrue(mid.r > 0.9 && mid.g > 0.72 && mid.g < 0.9 && mid.b > 0.78, "rosa Papier: \(mid)")
        let corner = try XCTUnwrap(plain.pixel(at: CGPoint(x: 160, y: 160)))
        XCTAssertTrue(corner.r > 0.8, "Ecke ist Papier: \(corner)")

        let pin = try XCTUnwrap(image(StickyNote.Choice(color: rosa, look: "pin")).pixel(at: CGPoint(x: 86, y: 14)))
        XCTAssertTrue(pin.r > 0.6 && pin.g < 0.35 && pin.b < 0.35, "rote Pinnnadel oben in der Mitte: \(pin)")
        let noPin = try XCTUnwrap(plain.pixel(at: CGPoint(x: 86, y: 14)))
        XCTAssertTrue(noPin.g > 0.7, "ohne Nadel: Papier")

        let tape = try XCTUnwrap(image(StickyNote.Choice(color: rosa, look: "tape")).pixel(at: CGPoint(x: 82, y: 9)))
        XCTAssertTrue(tape.g > noPin.g + 0.02, "Tesafilm ist heller als das Papier: \(tape) / \(noPin)")

        // geknickte Ecke: ganz unten rechts kein Papier (durchsichtig -> schwarz im Bild ohne Hintergrund)
        let fold = image(StickyNote.Choice(color: rosa, look: "fold"))
        let cut = try XCTUnwrap(fold.pixel(at: CGPoint(x: 163, y: 163)))
        XCTAssertTrue(cut.r < 0.2, "Ecke abgeschnitten: \(cut)")
        let flap = try XCTUnwrap(fold.pixel(at: CGPoint(x: 150, y: 150)))
        XCTAssertTrue(flap.r < mid.r - 0.05, "umgeschlagene Ecke ist dunkler: \(flap)")

        // liniert: auf der ersten Linie dunkler als dazwischen
        let lined = image(StickyNote.Choice(color: rosa, paper: "lined"))
        let y = StickyNote.padding.top + StickyNote.lineStep - TextBlock.baselineDrop
        let onLine = try XCTUnwrap(lined.pixel(at: CGPoint(x: 80, y: y)))
        let between = try XCTUnwrap(lined.pixel(at: CGPoint(x: 80, y: y + 10)))
        XCTAssertTrue(onLine.g < between.g - 0.03, "Linie des Zettels: \(onLine) / \(between)")

        // Ansicht auf der Seite: Schatten ueber die Ebene
        let view = PageObjectsView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
        view.show(template: "blank", placeholder: nil, objects: [note(StickyNote.Choice(look: "tape")), PageObjectEdit.sticky(id: "alt", x: 400, y: 300, text: "alt")], images: [:])
        let shown = try XCTUnwrap(view.subviews.compactMap { $0 as? TextBlockView }.first)
        XCTAssertEqual(shown.layer.shadowOpacity, 0.22, accuracy: 0.001)
        XCTAssertNotNil(shown.layer.shadowPath)
        XCTAssertEqual(view.subviews.filter { $0.subviews.first is UILabel }.count, 1, "die alte gelbe Haftnotiz bleibt, wie sie ist")
    }

    /// Auswahl des Werkzeugs je Geraet gemerkt; Bildchen fuer alle Kombinationen lassen sich zeichnen
    func testAuswahlGemerktUndMuster() {
        let before = UserDefaults.standard.string(forKey: EditorPalette.stickyKey)
        defer { UserDefaults.standard.set(before, forKey: EditorPalette.stickyKey) }
        UserDefaults.standard.removeObject(forKey: EditorPalette.stickyKey)
        XCTAssertEqual(EditorPalette.stickyChoice, StickyNote.Choice(), "Vorgabe: gelber Klebezettel, mittel")
        let c = StickyNote.Choice(color: "#d6f5c8", look: "fold", paper: "dots", size: "s")
        EditorPalette.stickyChoice = c
        XCTAssertEqual(EditorPalette.stickyChoice, c)
        for color in StickyNote.colors { for look in StickyNote.looks { for paper in StickyNote.papers {
            let img = StickyNoteRender.swatch(StickyNote.Choice(color: color.hex, look: look.id, paper: paper.id))
            XCTAssertEqual(img.size, CGSize(width: 44, height: 44))
        } } }
    }

    /// Export zeichnet den Zettel mit Text (als Text in der PDF)
    func testExport() throws {
        let o = note(StickyNote.Choice(color: "#cfe8ff", look: "pin", paper: "lined"))
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(x: 0, y: 0, width: 595, height: 842), nil)
        UIGraphicsBeginPDFPage()
        ObjectGeometry.draw(objects: [o], images: [:], in: UIGraphicsGetCurrentContext()!)
        UIGraphicsEndPDFContext()
        let pdf = try XCTUnwrap(PDFDocument(data: data as Data))
        XCTAssertTrue((pdf.page(at: 0)?.string ?? "").contains("Klausur am 12.02."))
    }
}
