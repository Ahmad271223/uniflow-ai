import UIKit
import UniFlowCore

/// Geometrie und Aussehen der Nicht-Strich-Objekte aus dem Web-Editor (Text, Formen, Bilder), gemeinsam genutzt
/// von der Bildschirmanzeige (`PageObjectsView`) und dem PDF-Export, dazu die Seitenvorlagen des Exports.
/// Gleiche Regeln wie `addNode` in app/static/editor.js (Konva): verschieben -> drehen -> skalieren.
enum ObjectGeometry {
    static let templateColor = UIColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1)

    // MARK: Zahlen sicher begrenzt
    //
    // Notizen liegen auf Seiten von hoechstens 14 400 Punkten (`SolutionLimits.maxPageSide`). Werte weit darueber
    // (1e300, groesste Gleitkommazahl) sind nie sichtbar, ergeben aber in Produkten Unendlich und daraus NaN in der
    // Ebenen-Geometrie: CALayer bricht dann mit einer Ausnahme ab. Fremde Loesungen kommen von anderen Geraeten;
    // deshalb wird jede Zahl vor dem Zeichnen und Anzeigen endlich und begrenzt gelesen. Uebliche Werte bleiben
    // unveraendert.

    /// Groesster Betrag fuer Lage, Groesse und Punkte (Seitenpunkte, rund das Siebenfache der groessten Seite).
    static let maxCoordinate: Double = 100_000
    /// Groesster Betrag fuer scaleX/scaleY.
    static let maxScale: Double = 100
    /// Groesste Linienbreite.
    static let maxLineWidth: Double = 10_000
    /// Schriftgroesse und Zeilenhoehe (Vielfaches) des Textes.
    static let fontSizeRange: ClosedRange<Double> = 1...1_600
    static let lineHeightRange: ClosedRange<Double> = 0.1...10

    /// Zahl eines Objektfelds, endlich und auf `range` begrenzt; fehlt sie oder ist sie nicht endlich, gilt
    /// `fallback`.
    static func number(_ v: JSONValue?, _ fallback: Double, in range: ClosedRange<Double>) -> Double {
        clamped(v?.double, fallback, in: range)
    }

    static func clamped(_ d: Double?, _ fallback: Double, in range: ClosedRange<Double>) -> Double {
        guard let d, d.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, d))
    }

    /// Lage, Groesse oder Punkt (Seitenpunkte), begrenzt auf +-`maxCoordinate`.
    static func coordinate(_ v: JSONValue?, _ fallback: Double) -> Double {
        number(v, fallback, in: -maxCoordinate...maxCoordinate)
    }

    /// Koordinaten einer Punktliste (x, y, x, y, ...), begrenzt; nicht endliche Werte werden 0.
    static func coordinates(_ v: JSONValue?) -> [Double] {
        (v?.array ?? []).compactMap { $0.double }.map { clamped($0, 0, in: -maxCoordinate...maxCoordinate) }
    }

    /// Deckkraft 0...1 (wie Konva).
    static func opacity(_ o: JSONValue) -> Double { number(o["opacity"], 1, in: 0...1) }

    static func transform(_ o: JSONValue) -> CGAffineTransform {
        let x = coordinate(o["x"], 0), y = coordinate(o["y"], 0)
        // Grad, auf eine Umdrehung zurueckgefuehrt (fmod ist exakt, auch bei sehr grossen Werten)
        let degrees = o["rotation"]?.double.flatMap { $0.isFinite ? $0.truncatingRemainder(dividingBy: 360) : nil } ?? 0
        let rot = degrees * .pi / 180
        let sx = number(o["scaleX"], 1, in: -maxScale...maxScale), sy = number(o["scaleY"], 1, in: -maxScale...maxScale)
        return CGAffineTransform(translationX: x, y: y).rotated(by: rot).scaledBy(x: sx, y: sy)
    }

    static func color(_ v: JSONValue?) -> UIColor? {
        guard let s = v?.string, !s.isEmpty else { return nil }
        return UIColor(hex: s)
    }

    /// Umriss einer Form in Objektkoordinaten. `closed` = darf gefuellt werden.
    static func shapePath(_ o: JSONValue) -> (path: CGPath, closed: Bool, arrowHead: CGPath?)? {
        guard o["type"]?.string == "shape" else { return nil }
        let w = coordinate(o["width"], 0), h = coordinate(o["height"], 0)
        let pts = coordinates(o["points"])
        func polyline(_ p: [Double], close: Bool) -> CGPath? {
            guard p.count >= 4 else { return nil }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: p[0], y: p[1]))
            var i = 2
            while i + 1 < p.count { path.addLine(to: CGPoint(x: p[i], y: p[i + 1])); i += 2 }
            if close { path.closeSubpath() }
            return path
        }
        switch o["shape"]?.string ?? "" {
        case "rect":
            return (CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), true, nil)
        case "ellipse":
            return (CGPath(ellipseIn: CGRect(x: 0, y: 0, width: w, height: h), transform: nil), true, nil)
        case "triangle":
            guard let p = polyline([w / 2, 0, w, h, 0, h], close: true) else { return nil }
            return (p, true, nil)
        case "polygon":
            guard let p = polyline(pts, close: true) else { return nil }
            return (p, true, nil)
        case "arrow":
            guard let p = polyline(pts, close: false), pts.count >= 4 else { return nil }
            let n = pts.count
            let tip = CGPoint(x: pts[n - 2], y: pts[n - 1]), from = CGPoint(x: pts[n - 4], y: pts[n - 3])
            let sw = CGFloat(lineWidth(o["strokeWidth"], 2))
            let len: CGFloat = max(8, sw * 3), half: CGFloat = max(8, sw * 3) / 2
            let angle: CGFloat = atan2(tip.y - from.y, tip.x - from.x)
            let back = CGPoint(x: tip.x - cos(angle) * len, y: tip.y - sin(angle) * len)
            let head = CGMutablePath()
            head.move(to: tip)
            head.addLine(to: CGPoint(x: back.x + sin(angle) * half, y: back.y - cos(angle) * half))
            head.addLine(to: CGPoint(x: back.x - sin(angle) * half, y: back.y + cos(angle) * half))
            head.closeSubpath()
            return (p, false, head)
        default:
            guard let p = polyline(pts, close: false) else { return nil }
            return (p, false, nil)
        }
    }

    /// Linienbreite einer Form (`strokeWidth`), 0...`maxLineWidth`.
    static func lineWidth(_ v: JSONValue?, _ fallback: Double) -> Double { number(v, fallback, in: 0...maxLineWidth) }

    /// Text wie Konva.Text: Breite inklusive 4 pt Innenabstand, Zeilenumbruch nach Woertern.
    static func attributedText(_ o: JSONValue) -> NSAttributedString {
        let size = CGFloat(number(o["fontSize"], 14, in: fontSizeRange))
        var font = UIFont(name: o["fontFamily"]?.string ?? "Arial", size: size) ?? .systemFont(ofSize: size)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if o["bold"]?.bool == true { traits.insert(.traitBold) }
        if o["italic"]?.bool == true { traits.insert(.traitItalic) }
        if !traits.isEmpty, let d = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: d, size: size) }
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = CGFloat(number(o["lineHeight"], 1.25, in: lineHeightRange))
        style.lineBreakMode = .byWordWrapping
        switch o["align"]?.string {
        case "center": style.alignment = .center
        case "right": style.alignment = .right
        default: style.alignment = .left
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: style, .foregroundColor: color(o["fill"]) ?? UIColor(hex: "#1d2130") ?? .black,
        ]
        if o["underline"]?.bool == true { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: o["text"]?.string ?? "", attributes: attrs)
    }

    static let textPadding: CGFloat = 4

    /// Groesse eines Textobjekts (Breite aus dem Objekt, Hoehe aus dem Inhalt), immer endlich.
    static func textSize(_ o: JSONValue, _ text: NSAttributedString) -> CGSize {
        let width = CGFloat(number(o["width"], 200, in: 0...maxCoordinate))
        let inner = max(1, width - 2 * textPadding)
        let r = text.boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let height = r.height.isFinite ? min(CGFloat(maxCoordinate), ceil(max(0, r.height))) : 0
        return CGSize(width: width, height: height + 2 * textPadding)
    }

    /// Linien der Seitenvorlage fuer den PDF-Export (wie drawTemplatePdf im Web-Editor), in Seitenpunkten mit Ursprung
    /// oben links. Die Bildschirmanzeige nutzt `PaperTemplate` (wie renderTemplate im Web).
    static func templatePath(_ template: String?, size: CGSize) -> (lines: CGPath?, dots: CGPath?) {
        guard let t = template, t != "blank" else { return (nil, nil) }
        let W = size.width, H = size.height
        let step: CGFloat = t == "mm" ? 2.835 : (t == "grid" || t == "dotted") ? 14.17 : 24
        let lines = CGMutablePath()
        let dots = CGMutablePath()
        if t == "lined" || t == "cornell" {
            var y: CGFloat = 60
            while y < H { lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: W, y: y)); y += step }
        }
        if t == "grid" || t == "mm" {
            var x: CGFloat = 0
            while x < W { lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: H)); x += step }
            var y: CGFloat = 0
            while y < H { lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: W, y: y)); y += step }
        }
        if t == "dotted" {
            var x = step
            while x < W {
                var y = step
                while y < H { dots.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)); y += step }
                x += step
            }
        }
        if t == "cornell" {
            lines.move(to: CGPoint(x: 150, y: 0)); lines.addLine(to: CGPoint(x: 150, y: H - 150))
            lines.move(to: CGPoint(x: 0, y: H - 150)); lines.addLine(to: CGPoint(x: W, y: H - 150))
        }
        return (lines.isEmpty ? nil : lines, dots.isEmpty ? nil : dots)
    }

    // MARK: Zeichnen in einen Grafikkontext (PDF-Export)

    static func draw(objects: [JSONValue], images: [String: UIImage], in ctx: CGContext) {
        for o in objects {
            let type = o["type"]?.string
            guard type == "shape" || type == "text" || type == "image" else { continue }
            ctx.saveGState()
            ctx.concatenate(transform(o))
            ctx.setAlpha(CGFloat(opacity(o)))
            if let s = shapePath(o) {
                let sw = CGFloat(lineWidth(o["strokeWidth"], 2))
                if s.closed, let fill = color(o["fill"]) { ctx.addPath(s.path); ctx.setFillColor(fill.cgColor); ctx.fillPath() }
                if let stroke = color(o["stroke"]) {
                    ctx.addPath(s.path); ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(sw)
                    ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
                    if let head = s.arrowHead { ctx.addPath(head); ctx.setFillColor(stroke.cgColor); ctx.fillPath() }
                }
            } else if type == "text" {
                let text = attributedText(o)
                let size = textSize(o, text)
                if let bg = color(o["bg"]) {
                    ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 3, cornerHeight: 3, transform: nil))
                    ctx.setFillColor(bg.cgColor); ctx.fillPath()
                }
                UIGraphicsPushContext(ctx)
                text.draw(with: CGRect(x: textPadding, y: textPadding, width: size.width - 2 * textPadding, height: size.height),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                UIGraphicsPopContext()
            } else if type == "image", let src = o["src"]?.string, let img = images[src] {
                let w = coordinate(o["width"], Double(img.size.width)), h = coordinate(o["height"], Double(img.size.height))
                UIGraphicsPushContext(ctx)
                img.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
                UIGraphicsPopContext()
            }
            ctx.restoreGState()
        }
    }
}

/// Bildschirmanzeige von Vorlage, Text, Formen und Bildern einer Seite (unter der PencilKit-Canvas, ohne Eingabe).
/// Vorlage und Formen sind Vektor-Ebenen und bleiben beim Zoomen scharf. Immer im hellen Erscheinungsbild
/// (siehe `PageInkView`), damit Farben auf dem weissen Papier wie im Web aussehen.
final class PageObjectsView: UIView {
    private var signature = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    /// Inhalt setzen. Baut nur neu auf, wenn sich etwas geaendert hat.
    func show(template: String?, placeholder: String?, objects: [JSONValue], images: [String: UIImage]) {
        let others = objects.filter { $0["type"]?.string != "stroke" }
        let sig = (template ?? "") + "|" + (placeholder ?? "") + "|" + JSONValue.array(others).jsonString(sortedKeys: true) + "|" + images.keys.sorted().joined(separator: ",")
        guard sig != signature else { return }
        signature = sig
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        subviews.forEach { $0.removeFromSuperview() }

        // Vorlage zuerst, damit sie hinter Text, Formen und der Tinte liegt (wie im Web)
        PaperTemplate.layers(for: template, size: bounds.size).forEach { layer.addSublayer($0) }
        if let placeholder {
            let label = UILabel(frame: bounds.insetBy(dx: 40, dy: 40))
            label.text = placeholder
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .body)
            addSubview(label)
        }
        for o in others { add(o, images: images) }
    }

    private func add(_ o: JSONValue, images: [String: UIImage]) {
        let t = ObjectGeometry.transform(o)
        let alpha = Float(ObjectGeometry.opacity(o))
        if let s = ObjectGeometry.shapePath(o) {
            let l = CAShapeLayer()
            l.path = s.path
            l.anchorPoint = .zero
            l.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            l.setAffineTransform(t)
            l.lineWidth = CGFloat(ObjectGeometry.lineWidth(o["strokeWidth"], 2))
            l.lineJoin = .round
            l.lineCap = .round
            l.strokeColor = ObjectGeometry.color(o["stroke"])?.cgColor
            l.fillColor = s.closed ? ObjectGeometry.color(o["fill"])?.cgColor : nil
            l.opacity = alpha
            layer.addSublayer(l)
            if let head = s.arrowHead {
                let h = CAShapeLayer()
                h.path = head
                h.anchorPoint = .zero
                h.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                h.setAffineTransform(t)
                h.fillColor = ObjectGeometry.color(o["stroke"])?.cgColor
                h.opacity = alpha
                layer.addSublayer(h)
            }
            return
        }
        switch o["type"]?.string {
        case "text":
            let text = ObjectGeometry.attributedText(o)
            let size = ObjectGeometry.textSize(o, text)
            let box = UIView(frame: CGRect(origin: .zero, size: size))
            box.layer.anchorPoint = .zero
            box.backgroundColor = ObjectGeometry.color(o["bg"])
            box.layer.cornerRadius = 3
            let label = UILabel(frame: box.bounds.insetBy(dx: ObjectGeometry.textPadding, dy: ObjectGeometry.textPadding))
            label.numberOfLines = 0
            label.attributedText = text
            label.contentScaleFactor = UIScreen.main.scale * 2      // bleibt beim Zoomen lesbar
            box.addSubview(label)
            box.alpha = CGFloat(alpha)
            addSubview(box)
            box.frame = CGRect(origin: .zero, size: size)
            box.transform = t
        case "image":
            guard let src = o["src"]?.string else { return }
            let w = ObjectGeometry.coordinate(o["width"], 100), h = ObjectGeometry.coordinate(o["height"], 100)
            let view = UIImageView(frame: CGRect(x: 0, y: 0, width: w, height: h))
            view.layer.anchorPoint = .zero
            view.contentMode = .scaleToFill
            view.image = images[src]
            view.backgroundColor = images[src] == nil ? UIColor.secondarySystemFill : .clear
            view.alpha = CGFloat(alpha)
            addSubview(view)
            view.frame = CGRect(x: 0, y: 0, width: w, height: h)
            view.transform = t
        default:
            break
        }
    }
}
