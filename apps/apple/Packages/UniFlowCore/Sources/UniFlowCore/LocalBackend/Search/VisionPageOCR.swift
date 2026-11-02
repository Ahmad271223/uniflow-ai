#if canImport(Vision) && canImport(CoreGraphics)
import CoreGraphics
import Foundation
import Vision

/// Texterkennung mit Apples Vision (iPad und Mac, ohne Fremdbibliothek): Seite mit CoreGraphics in Graustufen rendern
/// (etwa doppelte Aufloesung, Obergrenze fuer sehr grosse Seiten), `VNRecognizeTextRequest` mit `.accurate`, Deutsch
/// und Englisch. Formeln erkennt Vision nicht zuverlaessig; das ist hier auch nicht verlangt (Suche, KI-Hilfe).
///
/// Jede Seite wird einzeln gerendert und ihr Bild gleich wieder freigegeben (`autoreleasepool`), damit bei vielen
/// Seiten nicht mehrere Bilder gleichzeitig im Speicher liegen.
public struct VisionPageOCR: PageOCR {
    /// Faktor zur PDF-Groesse in Punkten (72 dpi): 2 = 144 dpi, fuer Fliesstext und Folien genug
    public static let scale: CGFloat = 2
    /// laengste Bildseite in Pixeln (A4 bei 2x: 1684; ein Poster wird verkleinert statt Hunderte MB zu belegen)
    public static let maxPixels: CGFloat = 4000
    /// Sprachen in dieser Reihenfolge (Deutsch zuerst, Umlaute und ß)
    public static let languages = ["de-DE", "en-US"]

    public init() {}

    public func recognize(pdf url: URL, pages: [Int]) async throws -> [Int: String] {
        guard let doc = CGPDFDocument(url as CFURL), !doc.isEncrypted || doc.isUnlocked else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var out: [Int: String] = [:]
        for p in pages {
            try Task.checkCancellation()
            guard p >= 1, p <= doc.numberOfPages, let page = doc.page(at: p) else { continue }
            out[p] = try autoreleasepool { try Self.text(of: page) }
        }
        return out
    }

    /// Text einer Seite, Zeilen in der Reihenfolge von Vision (Textbloecke von oben nach unten)
    static func text(of page: CGPDFPage) throws -> String {
        guard let image = render(page) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Seite als Graustufenbild (weisser Grund, Drehung der Seite beachtet)
    static func render(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let factor = min(scale, maxPixels / max(size.width, size.height))
        let w = Int((size.width * factor).rounded()), h = Int((size.height * factor).rounded())
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceGray(),
                                                 bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: factor, y: factor)
        // Seite in das Rechteck einpassen (beruecksichtigt Drehung und Ursprung der Crop-Box)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }
}
#endif
