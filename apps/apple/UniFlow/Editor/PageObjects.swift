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
        // Tabelle (26.11.2026): zeichnet sich selbst (`SheetRender`), der Ersatztext wird nicht gesetzt
        if SheetObject.isSheet(o) { return NSAttributedString() }
        // Textbloecke (25.11.2026): gemischte Formatierung, eigener Zeilensatz (`TextBlockRender`)
        if TextBlock.isBlock(o) { return TextBlockRender.attributed(o) }
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
        if SheetObject.isSheet(o) { return SheetRender.size(o) }
        if TextBlock.isBlock(o) { return TextBlockRender.size(o) }
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
            if FlipCover.isCover(o) {
                // Klappkarte: exportiert und gedruckt wird sie verdeckt (so sieht die Seite aus)
                CoverRender.draw(o, size: CGSize(width: coordinate(o["width"], 0), height: coordinate(o["height"], 0)), in: ctx)
            } else if PageLink.isLink(o) {
                LinkRender.draw(o, size: CGSize(width: coordinate(o["width"], 0), height: coordinate(o["height"], 0)), in: ctx)
            } else if let s = shapePath(o) {
                let sw = CGFloat(lineWidth(o["strokeWidth"], 2))
                if s.closed, let fill = color(o["fill"]) { ctx.addPath(s.path); ctx.setFillColor(fill.cgColor); ctx.fillPath() }
                if let stroke = color(o["stroke"]) {
                    ctx.addPath(s.path); ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(sw)
                    ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
                    if let head = s.arrowHead { ctx.addPath(head); ctx.setFillColor(stroke.cgColor); ctx.fillPath() }
                }
            } else if type == "text", SheetObject.isSheet(o) {
                SheetRender.draw(o, in: ctx)
            } else if type == "text", TextBlock.isBlock(o) {
                TextBlockRender.draw(o, in: ctx)
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
    /// `.page`: Vorlage, Text, Formen, Bilder unter der Zeichenflaeche. `.covers`: nur die Klappkarten (`FlipCover`), in
    /// einer zweiten Schicht UEBER der Zeichenflaeche - sie verdecken auch die Handschrift.
    enum Kind { case page, covers }
    let kind: Kind
    /// Schicht mit den Klappkarten derselben Seite: bekommt denselben Inhalt und dieselben Vorschauen
    weak var top: PageObjectsView?
    /// Aufgedeckte Klappkarten (nur `.covers`); bleibt ueber einen Neuaufbau hinweg, wird nicht gespeichert
    private(set) var revealed: Set<String> = []

    private struct Placed {
        let view: UIView?
        let layer: CALayer?
        let base: CGAffineTransform
    }

    private var signature = ""
    /// Gezeigte Ansichten je Objekt-ID, fuer die Vorschau beim Ziehen
    private var placed: [String: [Placed]] = [:]
    /// Objekte, die gerade eine Vorschau mit anderer Groesse zeigen (`preview`)
    private var previewed: Set<String> = []
    /// Objekte, die gerade nicht gezeigt werden: ihr Text wird in einer Textansicht darueber bearbeitet (`setHidden`)
    private var hiddenIDs: Set<String> = []
    /// Aufloesung fuer Formen und Text (`PageInkView.setRenderScale`)
    private var renderScale: CGFloat = 0
    /// Zuletzt gezeigter Inhalt (fuer `update(images:)`)
    private var shown: (template: String?, placeholder: String?, objects: [JSONValue])?
    /// Zuletzt gezeigte Objekte (Treffer fuer das Kontextmenue, das nicht warten kann)
    var shownObjects: [JSONValue] { shown?.objects ?? [] }

    init(frame: CGRect, kind: Kind = .page) {
        self.kind = kind
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        // Karten nehmen die Beruehrung an (`point(inside:)`): Wer eine Karte antippt, schreibt nicht darunter
        isUserInteractionEnabled = kind == .covers
    }

    override convenience init(frame: CGRect) { self.init(frame: frame, kind: .page) }

    /// Nur auf einer Klappkarte "trifft" die Schicht; ueberall sonst geht die Beruehrung an die Zeichenflaeche darunter
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        kind == .covers && topObject(at: point) != nil
    }

    /// Klappkarte oder Verweis unter einem Punkt der Seite (oberstes zuerst). Geprueft wird nur die kurze Liste dieser
    /// Objekte (`tops`), nicht alle Objekte der Seite: die Frage kommt bei jeder Beruehrung, auch bei jedem Strich.
    func topObject(at point: CGPoint) -> JSONValue? {
        guard kind == .covers, !tops.isEmpty else { return nil }
        return TopObjects.hit(tops, x: Double(point.x), y: Double(point.y))
    }

    /// Klappkarten und Verweise dieser Schicht (nur `.covers`)
    private(set) var tops: [JSONValue] = []

    /// Klappkarte unter einem Punkt der Seite (oberste zuerst)
    func cover(at point: CGPoint) -> String? {
        guard kind == .covers, !tops.isEmpty else { return nil }
        return FlipCover.hit(tops, x: Double(point.x), y: Double(point.y))
    }

    /// Karte auf- bzw. zudecken; Rueckgabe: jetzt aufgedeckt
    @discardableResult
    func toggleCover(_ id: String, animated: Bool = true) -> Bool {
        let on = !revealed.contains(id)
        if on { revealed.insert(id) } else { revealed.remove(id) }
        for p in placed[id] ?? [] { (p.view as? CoverView)?.setRevealed(on, animated: animated) }
        return on
    }

    /// Alle Karten wieder verdecken
    func coverAll() {
        for id in revealed { for p in placed[id] ?? [] { (p.view as? CoverView)?.setRevealed(false, animated: false) } }
        revealed = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    /// Inhalt setzen. Baut nur neu auf, wenn sich etwas geaendert hat: Vorlage, Platzhalter, Objekte oder eines der
    /// Bilder, die die Objekte zeigen. Die Bilder zaehlen mit ihrer Identitaet, nicht nur mit dem Schluessel: ein unter
    /// demselben Schluessel ersetztes Bild wird gezeigt (Pruefbericht 501); Bilder anderer Seiten zaehlen nicht.
    func show(template: String?, placeholder: String?, objects: [JSONValue], images: [String: UIImage]) {
        shown = (template, placeholder, objects)
        // Klappkarten zeigt die Schicht ueber der Zeichenflaeche, alles andere die Schicht darunter
        top?.show(template: nil, placeholder: nil, objects: objects, images: images)
        let template = kind == .page ? template : nil, placeholder = kind == .page ? placeholder : nil
        let others = objects.filter { $0["type"]?.string != "stroke" && TopObjects.isTop($0) == (kind == .covers) }
        if kind == .covers {
            tops = others
            revealed.formIntersection(Set(others.compactMap { $0["id"]?.string }))
        }
        let sources = Set(others.compactMap { $0["type"]?.string == "image" ? $0["src"]?.string : nil }).sorted()
        let pictures = sources.map { src in images[src].map { "\(src)#\(ObjectIdentifier($0).hashValue)" } ?? src + "#-" }
        let sig = (template ?? "") + "|" + (placeholder ?? "") + "|" + JSONValue.array(others).jsonString(sortedKeys: true) + "|" + pictures.joined(separator: ",")
        guard sig != signature else { return }
        signature = sig
        // erst die Ansichten, dann die uebrigen Ebenen: vorher wurden zuerst alle Ebenen entfernt, auch die der
        // Ansichten; deren Entfernen lief danach ueber eine Ansicht ohne Ebene (Absturz in `removeFromSuperview`,
        // Fokus-System, gefunden 10.11.2026 beim Verschieben eines Textfelds mit Handschrift)
        subviews.forEach { $0.removeFromSuperview() }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        placed = [:]
        previewed = []

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
        for id in hiddenIDs { placed[id]?.forEach { $0.view?.isHidden = true; $0.layer?.isHidden = true } }
        applyRenderScale()
    }

    /// Bilder sind nachgeladen: den zuletzt gezeigten Inhalt mit ihnen zeigen (Pruefbericht 502; vorher zeichnete der
    /// Rueckruf den Stand von vor dem Laden und nahm eine inzwischen gezeigte Aenderung zurueck)
    func update(images: [String: UIImage]) {
        guard let s = shown else { return }
        show(template: s.template, placeholder: s.placeholder, objects: s.objects, images: images)
    }

    /// Formen und Text in der Aufloesung der Anzeige zeichnen, sonst werden sie beim Vergroessern unscharf
    func setRenderScale(_ scale: CGFloat) {
        top?.setRenderScale(scale)
        guard scale != renderScale else { return }
        renderScale = scale
        applyRenderScale()
    }

    private func applyRenderScale() {
        guard renderScale > 0 else { return }
        layer.sublayers?.forEach { $0.contentsScale = renderScale }
        func walk(_ v: UIView) {
            // Text nie unter dem festen Wert in `add`, sonst wird er beim Zoomen pixelig
            v.contentScaleFactor = max(renderScale, UIScreen.main.scale * 2)
            v.subviews.forEach(walk)
        }
        subviews.forEach(walk)
    }

    /// Vorschau beim Ziehen: Die gewaehlten Objekte folgen dem Finger, ohne dass das Modell geaendert wird
    func previewMove(ids: Set<String>, by d: CGPoint) {
        top?.previewMove(ids: ids, by: d)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in ids {
            for p in placed[id] ?? [] {
                let t = p.base.concatenating(CGAffineTransform(translationX: d.x, y: d.y))
                if let v = p.view { v.transform = t } else { p.layer?.setAffineTransform(t) }
            }
        }
        CATransaction.commit()
    }

    /// Vorschau beim Aendern der Groesse (Anfasser an der Ecke, zwei Finger): Die genannten Objekte erscheinen mit Lage,
    /// Massstab und - bei Text - Breite aus `objects`, ohne dass das Modell geaendert wird. Vorher zeigte nur der Rahmen
    /// die neue Groesse, das Bild sprang erst beim Loslassen. `nil` zeigt wieder den gespeicherten Stand.
    func preview(_ objects: [JSONValue]?) {
        top?.preview(objects)
        let list = objects ?? shownObjects.filter { ($0["id"]?.string).map(previewed.contains) == true }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for o in list {
            guard let id = o["id"]?.string, let parts = placed[id] else { continue }
            let t = ObjectGeometry.transform(o)
            for p in parts {
                guard let v = p.view else { p.layer?.setAffineTransform(t); continue }
                if let cover = v as? CoverView {
                    // Klappkarte: Breite und Hoehe, das Muster bleibt gleich fein
                    cover.bounds = CGRect(x: 0, y: 0, width: ObjectGeometry.coordinate(o["width"], 0), height: ObjectGeometry.coordinate(o["height"], 0))
                    cover.setNeedsDisplay()
                } else if let link = v as? LinkView {
                    link.bounds = CGRect(x: 0, y: 0, width: ObjectGeometry.coordinate(o["width"], 0), height: ObjectGeometry.coordinate(o["height"], 0))
                    link.setNeedsDisplay()
                } else if let sheet = v as? SheetBoxView {
                    sheet.show(o)                              // Tabelle: Breite = Massstab
                } else if let block = v as? TextBlockView {
                    block.show(o)                              // Textblock: neu umbrechen im eigenen Satz
                } else if o["type"]?.string == "text", let label = v.subviews.first as? UILabel {
                    // Text aendert die Breite, nicht den Massstab: neu umbrechen
                    v.bounds = CGRect(origin: .zero, size: ObjectGeometry.textSize(o, label.attributedText ?? NSAttributedString()))
                    label.frame = v.bounds.insetBy(dx: ObjectGeometry.textPadding, dy: ObjectGeometry.textPadding)
                }
                v.transform = t
            }
        }
        CATransaction.commit()
        previewed = objects == nil ? [] : previewed.union(list.compactMap { $0["id"]?.string })
    }

    /// Objekte ausblenden, solange ihr Text bearbeitet wird (die Textansicht zeigt denselben Satz an derselben Stelle),
    /// bzw. wieder zeigen. Bleibt ueber einen Neuaufbau hinweg bestehen (z. B. Abgleich waehrend des Tippens).
    func setHidden(_ ids: Set<String>, _ hidden: Bool) {
        top?.setHidden(ids, hidden)
        if hidden { hiddenIDs.formUnion(ids) } else { hiddenIDs.subtract(ids) }
        for id in ids {
            for p in placed[id] ?? [] {
                p.view?.isHidden = hidden
                p.layer?.isHidden = hidden
            }
        }
    }

    /// Objekte blass zeigen (ein Bild ist auf dem Weg ins andere Dokument, `ObjectTransfer.swift`) bzw. wieder wie
    /// gespeichert
    func setDimmed(_ ids: Set<String>, _ dimmed: Bool) {
        top?.setDimmed(ids, dimmed)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for o in shownObjects {
            guard let id = o["id"]?.string, ids.contains(id) else { continue }
            let alpha = ObjectGeometry.opacity(o) * (dimmed ? 0.35 : 1)
            for p in placed[id] ?? [] {
                p.view?.alpha = CGFloat(alpha)
                p.layer?.opacity = Float(alpha)
            }
        }
        CATransaction.commit()
    }

    private func add(_ o: JSONValue, images: [String: UIImage]) {
        let t = ObjectGeometry.transform(o)
        let id = o["id"]?.string ?? ""
        let alpha = Float(ObjectGeometry.opacity(o))
        if FlipCover.isCover(o) {
            let w = ObjectGeometry.coordinate(o["width"], 0), h = ObjectGeometry.coordinate(o["height"], 0)
            let view = CoverView(object: o, revealed: revealed.contains(id), frame: CGRect(x: 0, y: 0, width: w, height: h))
            view.layer.anchorPoint = .zero
            view.contentScaleFactor = UIScreen.main.scale * 2
            view.alpha = CGFloat(alpha)
            addSubview(view)
            view.frame = CGRect(x: 0, y: 0, width: w, height: h)
            view.transform = t
            placed[id, default: []].append(Placed(view: view, layer: nil, base: t))
            return
        }
        if PageLink.isLink(o) {
            let w = ObjectGeometry.coordinate(o["width"], 0), h = ObjectGeometry.coordinate(o["height"], 0)
            let view = LinkView(object: o, frame: CGRect(x: 0, y: 0, width: w, height: h))
            view.layer.anchorPoint = .zero
            view.contentScaleFactor = UIScreen.main.scale * 2
            view.alpha = CGFloat(alpha)
            addSubview(view)
            view.frame = CGRect(x: 0, y: 0, width: w, height: h)
            view.transform = t
            placed[id, default: []].append(Placed(view: view, layer: nil, base: t))
            return
        }
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
            placed[id, default: []].append(Placed(view: nil, layer: l, base: t))
            if let head = s.arrowHead {
                let h = CAShapeLayer()
                h.path = head
                h.anchorPoint = .zero
                h.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                h.setAffineTransform(t)
                h.fillColor = ObjectGeometry.color(o["stroke"])?.cgColor
                h.opacity = alpha
                layer.addSublayer(h)
                placed[id, default: []].append(Placed(view: nil, layer: h, base: t))
            }
            return
        }
        switch o["type"]?.string {
        case "text" where SheetObject.isSheet(o):
            let box = SheetBoxView(object: o)
            let size = box.bounds.size
            box.layer.anchorPoint = .zero
            box.alpha = CGFloat(alpha)
            addSubview(box)
            box.frame = CGRect(origin: .zero, size: size)
            box.contentScaleFactor = UIScreen.main.scale * 2
            box.transform = t
            placed[id, default: []].append(Placed(view: box, layer: nil, base: t))
        case "text" where TextBlock.isBlock(o):
            let box = TextBlockView(object: o)
            let size = box.bounds.size
            box.layer.anchorPoint = .zero
            box.contentScaleFactor = UIScreen.main.scale * 2      // bleibt beim Zoomen lesbar
            box.alpha = CGFloat(alpha)
            addSubview(box)
            box.frame = CGRect(origin: .zero, size: size)
            box.transform = t
            placed[id, default: []].append(Placed(view: box, layer: nil, base: t))
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
            placed[id, default: []].append(Placed(view: box, layer: nil, base: t))
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
            placed[id, default: []].append(Placed(view: view, layer: nil, base: t))
        default:
            break
        }
    }
}
