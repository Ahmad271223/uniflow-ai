import PDFKit
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

    static func uiImages(_ images: [String: SolutionImage]) -> [String: UIImage] {
        images.compactMapValues { UIImage(data: $0.data) }
    }
}

/// Vorschau einer geteilten Seite OHNE Original: weisser Hintergrund, bei Leerseiten die Vorlage, darauf nur die
/// eigenen Objekte (gleiche Zeichenroutine wie PDF-Export und Miniaturen). Bekommt nie eine PDF-Seite.
enum SolutionPreview {
    static func image(_ page: SolutionPage, images: [String: UIImage], width: CGFloat, scale: CGFloat = 2) -> UIImage {
        let (w, h) = page.displaySize
        let size = CGSize(width: max(1, w), height: max(1, h))
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

extension InkRenderer {
    /// Strich als Vektor-Ebenen (bleibt beim Zoomen scharf wie Vorlage und Formen), gleiche Regeln wie `draw`.
    static func shapeLayer(_ o: JSONValue) -> CALayer? {
        guard let plan = plan(o) else { return nil }
        let group = CALayer()
        group.anchorPoint = .zero
        group.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        group.setAffineTransform(plan.transform)
        group.opacity = Float(plan.alpha)
        if plan.multiply { group.compositingFilter = "multiplyBlendMode" }
        for piece in plan.pieces {
            let l = CAShapeLayer()
            l.path = piece.path
            l.lineWidth = piece.width
            l.strokeColor = plan.color.cgColor
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            if !plan.dash.isEmpty { l.lineDashPattern = plan.dash.map { NSNumber(value: Double($0)) } }
            group.addSublayer(l)
        }
        return group
    }
}

/// Eine fremde Loesungsseite in der eigenen Schicht des Seiten-Overlays (ueber der PDF, unter den eigenen Notizen).
/// Die Objekte stehen in Punkten der Seite, wie der Absender sie gedreht hatte; `mapping` bildet sie auf die
/// angezeigte Seite des Betrachters ab (`SolutionGeometry.transform`). Zoom ist reine Anzeige (Skalierung des
/// Overlays), die Koordinaten bleiben unveraendert.
final class ForeignLayerView: UIView {
    let solutionID: String
    /// Absender-Seite -> angezeigte Seite des Betrachters
    let mapping: CGAffineTransform
    private let content = UIView()
    private let objectsView: PageObjectsView
    private let strokes = CALayer()

    /// - Parameter targetRotation: Drehung der angezeigten Seite beim Betrachter (`/Rotate` + eigene Drehung).
    init(solutionID: String, page: SolutionPage, images: [String: UIImage], targetRotation: Int, label: String) {
        self.solutionID = solutionID
        let (sw, sh) = page.displaySize
        let (tw, th) = SolutionGeometry.displaySize(width: page.width, height: page.height, rotation: targetRotation)
        let source = CGRect(x: 0, y: 0, width: sw, height: sh)
        let t = SolutionGeometry.transform(width: page.width, height: page.height, from: page.rotation, to: targetRotation)
        mapping = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
        objectsView = PageObjectsView(frame: source)
        super.init(frame: CGRect(x: 0, y: 0, width: tw, height: th))
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        content.isUserInteractionEnabled = false
        content.layer.anchorPoint = .zero
        content.bounds = source
        content.layer.position = .zero
        content.transform = mapping
        content.addSubview(objectsView)
        objectsView.show(template: nil, placeholder: nil, objects: page.objects, images: images)
        strokes.frame = source
        for o in page.objects where o["type"]?.string == "stroke" {
            if let l = InkRenderer.shapeLayer(o) { strokes.addSublayer(l) }
        }
        content.layer.addSublayer(strokes)
        addSubview(content)
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    /// Anzahl gezeichneter Striche (Tests).
    var strokeLayerCount: Int { strokes.sublayers?.count ?? 0 }
}
