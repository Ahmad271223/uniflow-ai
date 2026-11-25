import Combine
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
    /// Loesung zu einer anderen Fassung derselben PDF (23.11.2026, `SolutionVersions`): Lage jeder PDF-Seite beim
    /// Betrachter (eigene Seite, Seite der aufbewahrten Fassung oder "geaendert"); leer = dieselbe PDF, jede Seite auf
    /// ihrer eigenen
    var placements: [String: SolutionVersions.Placement] = [:]
    /// aufbewahrte Fassung des Absenders auf dem Geraet (Seiten `.oldVersion`)
    var oldVersionURL: URL?
    /// gehoert zu einer anderen Fassung (Fingerabdruck anders als die eigene PDF)
    var otherVersion = false

    /// Lage einer geteilten PDF-Seite beim Betrachter (nil fuer eigene Blaetter des Absenders)
    func placement(_ p: SolutionPage) -> SolutionVersions.Placement? {
        guard p.kind == .pdf, let i = p.pdfIndex else { return nil }
        return placements.isEmpty ? .own(i) : placements[p.key] ?? .changed
    }

    /// Eigene PDF-Seite (1-basiert) -> geteilte Seite; bei einer anderen Fassung nur die gleich gebliebenen Seiten
    var byPDFIndex: [Int: SolutionPage] {
        var out: [Int: SolutionPage] = [:]
        for p in pages { if case .own(let j)? = placement(p) { out[j] = p } }
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
    /// Breite und Bildschirmfaktor der Vorschau: endlich und begrenzt (Pruefbericht 518; heute uebergibt die App eine
    /// feste Breite, ein Wert wie unendlich oder 1e9 haette sonst ein riesiges Bild angefordert)
    static let widthRange: ClosedRange<CGFloat> = 1...2_048
    static let scaleRange: ClosedRange<CGFloat> = 1...3

    /// - Parameter pdfPage: eigene PDF-Seite als Hintergrund ("Daneben ansehen"), sonst weiss (Vorschau ohne Original)
    static func image(_ page: SolutionPage, images: [String: UIImage], width requested: CGFloat, scale requestedScale: CGFloat = 2,
                      pdfPage: PDFPage? = nil) -> UIImage {
        let width = requested.isFinite ? min(widthRange.upperBound, max(widthRange.lowerBound, requested)) : widthRange.lowerBound
        let scale = requestedScale.isFinite ? min(scaleRange.upperBound, max(scaleRange.lowerBound, requestedScale)) : 2
        let (w, h) = page.displaySize
        let size = CGSize(width: ForeignLayerView.pageSide(w), height: ForeignLayerView.pageSide(h))
        let s = width / size.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        // sehr schmale, hohe Seiten: hoechstens 4 Bildbreiten hoch (der Rest der Seite liegt ausserhalb der Vorschau)
        let out = CGSize(width: width, height: min(4 * widthRange.upperBound, max(1, (size.height * s).rounded())))
        return UIGraphicsImageRenderer(size: out, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: out))
            if let pdfPage, page.kind == .pdf {
                // PDF in voller Aufloesung des Bildes (Thumbnail beachtet die Drehung der Seite wie displaySize)
                pdfPage.thumbnail(of: CGSize(width: out.width * scale, height: out.height * scale), for: .cropBox)
                    .draw(in: CGRect(origin: .zero, size: out))
            }
            ctx.cgContext.scaleBy(x: s, y: s)
            if page.kind == .blank { PageRenderer.drawTemplate(page.template, size: size, in: ctx.cgContext) }
            // Text, Bilder und Formen mit der gemeinsamen Zeichenroutine; die Handschrift zeichnet PencilKit wie auf der
            // Canvas des Absenders und in der Spalte daneben. Bis 22.11.2026 kam sie aus der Vektor-Routine des
            // PDF-Exports in der gespeicherten Breite: ein 3-pt-Stift ist bei PencilKit rund 2 pt breit, die Schrift
            // sah in der Vorschau (Kommentare der Community) darum fetter aus als im Dokument (Meldung des Inhabers).
            PageRenderer.drawObjects(page.objects.filter { $0["type"]?.string != "stroke" && !FlipCover.isCover($0) }, images: images, in: ctx.cgContext)
            // Klappkarten liegen ueber der Handschrift (unten, nach den Strichen)
            let covers = page.objects.filter(FlipCover.isCover)
            defer { if !covers.isEmpty { PageRenderer.drawObjects(covers, images: images, in: ctx.cgContext) } }
            let ink = Self.ink(page.objects)
            if !ink.strokes.isEmpty {
                let area = CGRect(x: 0, y: 0, width: size.width, height: min(size.height, out.height / s))
                var picture: UIImage?
                // helle Darstellung wie die Canvas (im Dunkelmodus kehrt PencilKit die Tinte sonst um)
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    picture = ink.image(from: area, scale: min(inkScaleMax, max(1, s * scale)))
                }
                picture?.draw(in: area)
            }
        }
    }

    /// Bildpunkte je Seitenpunkt fuer die Handschrift der Vorschau (hoechstens; eine A4-Seite sind dann 2380 x 3368)
    static let inkScaleMax: CGFloat = 4

    /// Striche einer Seite als PencilKit-Zeichnung (gleiche Umwandlung wie im Editor); Erstellzeiten nur zur
    /// Unterscheidung
    static func ink(_ objects: [JSONValue]) -> PKDrawing {
        let start = Date(timeIntervalSince1970: 0)
        let strokes = objects.filter { $0["type"]?.string == "stroke" }.enumerated().compactMap { i, o in
            StrokeConverter.stroke(from: o, created: start.addingTimeInterval(TimeInterval(i)))
        }
        return PKDrawing(strokes: strokes)
    }
}

/// Fremde Loesung als Ebene UEBER der eigenen Seite einblenden. Inhaber 22.11.2026: "nur noch daneben anzeigen ...
/// ohne Ebene mehr erstmal jetzt" - eine Loesung oeffnet sich nur noch neben dem eigenen Dokument (nur ansehen, die
/// eigene PDF-Seite bzw. das Blatt darunter, 1 zu 1 wie beim Absender). Der Code der Einblendung bleibt (der
/// Korrektur-Modus zeigt die korrigierte Loesung weiter unter den eigenen Strichen); der Schalter ist fuer Tests und
/// fuer den Fall, dass die Einblendung zurueckkommen soll.
enum SolutionOverlay {
    static var enabled = false
    /// Satz an Knopf und Menuepunkt (Wunsch des Inhabers: genau so lesbar)
    static let openBeside = "Lösung neben deinem Dokument öffnen"
    /// Erklaerung vor dem Laden: was passiert, und dass nur im eigenen Dokument geschrieben wird
    static let besideExplain = "Die Lösung öffnet sich neben deinem Dokument – genau so, wie sie geschrieben wurde, auf dem Blatt bzw. auf deiner PDF. Sie lässt sich nur ansehen; in deinem eigenen Dokument daneben schreibst du normal weiter."
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
    /// Klappkarten der fremden Seite, ueber ihrer Handschrift (Antippen deckt auf, `CoverTapper`)
    let coversView: PageObjectsView
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
        coversView = PageObjectsView(frame: source, kind: .covers)
        coversView.isUserInteractionEnabled = false         // die Ebene nimmt keine Eingabe an; getippt wird ueber `CoverTapper`
        objectsView.top = coversView
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
        content.addSubview(coversView)
        addSubview(content)
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    /// Striche dieser Ebene in Koordinaten der angezeigten Seite (fuer die gemeinsame Canvas aller Ebenen einer Seite)
    var mappedDrawing: PKDrawing { ink.drawing.transformed(using: mapping) }

    /// Eigene Canvas aus der Anzeige nehmen: die Seite zeigt die Striche aller Ebenen in einer gemeinsamen Canvas
    /// (`PageInkView.setForeign`). Je Ebene eine gezoomte Canvas kostete auf dem iPad gut 100 MB (gemessen 3.11.2026:
    /// 5 Ebenen 1178 MB statt 201 MB).
    func detachInk() { ink.removeFromSuperview() }

    /// Wie `PageInkView.setRenderScale`: PencilKit rendert fertige Striche nur nach dem eigenen Zoom der Canvas. Die
    /// Canvas der fremden Ebene zoomt darum selbst und wird per Transform wieder auf Seitengroesse gebracht; Text und
    /// Formen bekommen die Aufloesung der Anzeige. Sonst wirkt eine importierte Loesung beim Hineinzoomen grob.
    func setRenderScale(_ scale: CGFloat, zoom: CGFloat) {
        objectsView.setRenderScale(scale)
        guard ink.superview != nil else { return }               // Striche liegen in der gemeinsamen Canvas der Seite
        let z = max(1, zoom)
        guard abs(z - ink.zoomScale) > 0.001 else { return }
        let size = content.bounds.size
        ink.transform = .identity
        ink.minimumZoomScale = min(z, ink.zoomScale)
        ink.maximumZoomScale = max(z, ink.zoomScale)
        ink.bounds = CGRect(x: 0, y: 0, width: size.width * z, height: size.height * z)
        ink.center = CGPoint(x: size.width / 2, y: size.height / 2)
        ink.zoomScale = z
        ink.minimumZoomScale = z
        ink.maximumZoomScale = z
        ink.contentSize = ink.bounds.size
        ink.contentOffset = .zero
        ink.transform = CGAffineTransform(scaleX: 1 / z, y: 1 / z)
    }

    /// Striche der Seite wie auf der Canvas des Absenders; Erstellzeiten nur zur Unterscheidung
    static func drawing(_ objects: [JSONValue]) -> PKDrawing { SolutionPreview.ink(objects) }

    /// Anzahl gezeichneter Striche (Tests).
    var strokeCount: Int { ink.drawing.strokes.count }
}

/// Bitte "diese Loesung neben dem Dokument oeffnen", gestellt ausserhalb des Dokuments (Leser der Community): Datei-ID
/// -> Loesung. Das Dokument holt sie nach dem Laden ab (`DocumentView.takeBesideRequest`), wie `CorrectionLaunch`.
@MainActor
final class SolutionBesideLaunch: ObservableObject {
    static let shared = SolutionBesideLaunch()

    @Published private(set) var pending: [String: String] = [:]

    func request(solutionID: String, fileID: String) { pending[fileID] = solutionID }

    func take(fileID: String) -> String? { pending.removeValue(forKey: fileID) }
}

