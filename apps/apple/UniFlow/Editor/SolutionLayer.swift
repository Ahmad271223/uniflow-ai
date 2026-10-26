import ImageIO
import PDFKit
import PencilKit
import UIKit
import UniFlowCore

/// Fremde Loesung im Editor: nur Anzeige, nie bearbeitbar und nie im eigenen Notizmodell gespeichert.
/// Zuordnung ueber den 1-basierten PDF-Seitenindex; eigene Leerseiten des Absenders gibt es im Dokument des
/// Betrachters nicht, sie sind nur in der Vorschau sichtbar.
struct ForeignSolutionLayer: Identifiable {
    /// Loesungs-ID
    let id: String
    /// Leer = anonym
    let displayName: String
    let createdAt: String
    var visible: Bool
    /// alle geteilten Seiten in der Reihenfolge des Absenders (fuer die Vorschau)
    let pages: [SolutionPage]
    let images: [String: UIImage]
    let missingImages: Int

    /// PDF-Seite (1-basiert) -> geteilte Seite
    var byPDFIndex: [Int: SolutionPage] {
        var out: [Int: SolutionPage] = [:]
        for p in pages { if let i = p.pdfIndex { out[i] = p } }
        return out
    }

    var blankPageCount: Int { pages.filter { $0.kind == .blank }.count }

    var label: String { Self.label(displayName: displayName, createdAt: createdAt) }

    /// "Lösung von <Name oder Anonym> (<Datum>)"
    static func label(displayName: String, createdAt: String) -> String {
        let name = displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "Anonym" : displayName
        return "Lösung von \(name) (\(date(createdAt)))"
    }

    static func date(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: "de_DE")
        out.dateFormat = "dd.MM.yyyy"
        return out.string(from: d)
    }

    /// Pixelmasse aus dem Bildkopf, ohne das Bild zu dekodieren; `nil` = kein lesbares Bild.
    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// Pixelmasse innerhalb der Grenzen (`SolutionLimits.maxImageSide`, `maxImagePixels`).
    static func fitsLimits(width: Int, height: Int) -> Bool {
        width <= SolutionLimits.maxImageSide && height <= SolutionLimits.maxImageSide
            && width.multipliedReportingOverflow(by: height).partialValue <= SolutionLimits.maxImagePixels
    }

    /// Eingebettete Bilder einer Loesung als `UIImage`. Vorher werden die Pixelmasse aus dem Bildkopf gelesen (ohne
    /// Dekodieren): ein kleines, stark komprimiertes PNG kann sonst beim Anzeigen viele Gigabyte belegen. Ist ein
    /// Bild zu gross oder unlesbar, wird die ganze Loesung abgewiesen (nie ein Teil gezeigt).
    static func uiImages(_ images: [String: SolutionImage]) throws -> [String: UIImage] {
        var out: [String: UIImage] = [:]
        for (src, img) in images {
            guard let size = pixelSize(img.data) else { throw SolutionError.invalidContent("Bilddaten") }
            guard fitsLimits(width: size.width, height: size.height) else { throw SolutionError.imageTooLarge }
            guard let ui = UIImage(data: img.data) else { throw SolutionError.invalidContent("Bilddaten") }
            out[src] = ui
        }
        return out
    }
}

/// Vorschau einer geteilten Seite OHNE Original: weisser Hintergrund, bei Leerseiten die Vorlage, darauf nur die
/// eigenen Objekte (gleiche Zeichenroutine wie PDF-Export und Miniaturen). Bekommt nie eine PDF-Seite.
enum SolutionPreview {
    static func image(_ page: SolutionPage, images: [String: UIImage], width: CGFloat, scale: CGFloat = 2) -> UIImage {
        let (w, h) = page.displaySize
        let size = CGSize(width: ForeignLayerView.pageSide(w), height: ForeignLayerView.pageSide(h))
        let s = width / size.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let out = CGSize(width: width, height: max(1, (size.height * s).rounded()))
        return UIGraphicsImageRenderer(size: out, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: out))
            ctx.cgContext.scaleBy(x: s, y: s)
            if page.kind == .blank { PageRenderer.drawTemplate(page.template, size: size, in: ctx.cgContext) }
            PageRenderer.drawObjects(page.objects, images: images, in: ctx.cgContext)
        }
    }
}

/// Eine fremde Loesungsseite in der eigenen Schicht des Seiten-Overlays (ueber der PDF, unter den eigenen Notizen).
/// Die Objekte stehen in Punkten der Seite, wie der Absender sie gedreht hatte; `mapping` bildet sie auf die
/// angezeigte Seite des Betrachters ab (`SolutionGeometry.transform`). Zoom ist reine Anzeige (Skalierung des
/// Overlays), die Koordinaten bleiben unveraendert.
/// Striche zeichnet PencilKit wie auf der Canvas des Absenders (gleiche Umwandlung `StrokeConverter.stroke(from:)`,
/// gleiche Tinte): PencilKit zeichnet einen Strich nicht in der gespeicherten Punktgroesse (im Simulator gemessen:
/// Stift 3 pt -> 2 pt, 8 pt -> 12 pt), eine CAShapeLayer mit der gespeicherten Breite erschien beim Empfaenger
/// deshalb sichtbar anders als beim Absender (ForeignInkWidthTests).
final class ForeignLayerView: UIView {
    let solutionID: String
    /// Absender-Seite -> angezeigte Seite des Betrachters
    let mapping: CGAffineTransform
    private let content = UIView()
    private let objectsView: PageObjectsView
    /// Striche der fremden Seite, nur Anzeige (keine Eingabe, kein Werkzeug)
    let ink = PKCanvasView()

    /// Seitenlaenge fuer die Anzeige: endlich, 1...`SolutionLimits.maxPageSide` (geprueft ist das schon beim
    /// Oeffnen; hier zusaetzlich, damit keine Ebene mit NaN oder Unendlich entstehen kann).
    static func pageSide(_ v: Double) -> Double {
        v.isFinite ? min(SolutionLimits.maxPageSide, max(1, v)) : 1
    }

    /// - Parameter targetRotation: Drehung der angezeigten Seite beim Betrachter (`/Rotate` + eigene Drehung).
    init(solutionID: String, page: SolutionPage, images: [String: UIImage], targetRotation: Int, label: String) {
        self.solutionID = solutionID
        let pw = Self.pageSide(page.width), ph = Self.pageSide(page.height)
        let (sw, sh) = SolutionGeometry.displaySize(width: pw, height: ph, rotation: page.rotation)
        let (tw, th) = SolutionGeometry.displaySize(width: pw, height: ph, rotation: targetRotation)
        let source = CGRect(x: 0, y: 0, width: sw, height: sh)
        let t = SolutionGeometry.transform(width: pw, height: ph, from: page.rotation, to: targetRotation)
        mapping = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
        objectsView = PageObjectsView(frame: source)
        super.init(frame: CGRect(x: 0, y: 0, width: tw, height: th))
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        overrideUserInterfaceStyle = .light            // wie die eigene Canvas: Tinte im Dunkelmodus nicht umkehren
        content.isUserInteractionEnabled = false
        content.layer.anchorPoint = .zero
        content.bounds = source
        content.layer.position = .zero
        content.transform = mapping
        content.addSubview(objectsView)
        objectsView.show(template: nil, placeholder: nil, objects: page.objects, images: images)
        ink.frame = source
        ink.backgroundColor = .clear
        ink.isOpaque = false
        ink.isUserInteractionEnabled = false
        ink.drawingGestureRecognizer.isEnabled = false
        ink.isScrollEnabled = false
        ink.minimumZoomScale = 1
        ink.maximumZoomScale = 1
        ink.contentInsetAdjustmentBehavior = .never
        ink.showsVerticalScrollIndicator = false
        ink.showsHorizontalScrollIndicator = false
        ink.drawing = Self.drawing(page.objects)
        content.addSubview(ink)
        addSubview(content)
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    /// Striche der Seite wie auf der Canvas des Absenders; Erstellzeiten nur zur Unterscheidung
    static func drawing(_ objects: [JSONValue]) -> PKDrawing {
        let start = Date(timeIntervalSince1970: 0)
        let strokes = objects.filter { $0["type"]?.string == "stroke" }.enumerated().compactMap { i, o in
            StrokeConverter.stroke(from: o, created: start.addingTimeInterval(TimeInterval(i)))
        }
        return PKDrawing(strokes: strokes)
    }

    /// Anzahl gezeichneter Striche (Tests).
    var strokeCount: Int { ink.drawing.strokes.count }
}
