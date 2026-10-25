import PDFKit
import PencilKit
import UIKit
import UniFlowCore

/// PDF-Export mit Notizen (Seiten in der Reihenfolge des Notizmodells, wie im Web-Editor).
enum PDFExporter {

    /// Schreibt die PDF in einen temporaeren Ordner und gibt die Datei zurueck.
    static func export(layout: DisplayLayout, pages: [String: JSONValue], images: [String: UIImage], title: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safeFileName(title) + " – Notizen.pdf")
        let data = render(layout: layout, pages: pages, images: images)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func render(layout: DisplayLayout, pages: [String: JSONValue], images: [String: UIImage]) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        return renderer.pdfData { ctx in
            for i in 0..<layout.pdf.pageCount {
                guard let page = layout.pdf.page(at: i), let entry = layout.entry(at: i) else { continue }
                let geometry = PageGeometry(boxSize: page.bounds(for: .cropBox).size, rotation: page.rotation)
                let rect = CGRect(origin: .zero, size: geometry.pageSize)
                ctx.beginPage(withBounds: rect, pageInfo: [:])
                let cg = ctx.cgContext

                // PDF-Seite: PDFKit zeichnet mit Ursprung unten links und beruecksichtigt die Drehung
                cg.saveGState()
                cg.translateBy(x: 0, y: rect.height)
                cg.scaleBy(x: 1, y: -1)
                page.draw(with: .cropBox, to: cg)
                cg.restoreGState()

                // Vorlage (liniert, kariert ...)
                let (lines, dots) = ObjectGeometry.templatePath(entry.template, size: rect.size)
                if let lines {
                    cg.addPath(lines)
                    cg.setStrokeColor(ObjectGeometry.templateColor.cgColor)
                    cg.setLineWidth(entry.template == "cornell" ? 1 : 0.5)
                    cg.strokePath()
                }
                if let dots {
                    cg.addPath(dots)
                    cg.setFillColor(ObjectGeometry.templateColor.cgColor)
                    cg.fillPath()
                }

                // Text, Formen, Bilder
                let pageJSON = pages[entry.key]
                ObjectGeometry.draw(objects: pageJSON?["objects"]?.array ?? [], images: images, in: cg)

                // Handschrift (immer im hellen Erscheinungsbild, sonst kaeme sie im Dunkelmodus invertiert)
                let (drawing, _) = StrokeConverter.drawing(fromPage: pageJSON)
                if !drawing.strokes.isEmpty {
                    var image = UIImage()
                    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                        image = drawing.image(from: rect, scale: 3)
                    }
                    image.draw(in: rect)
                }
            }
        }
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Dokument" : String(cleaned.prefix(80))
    }
}
