import UIKit
import UniFlowCore

/// Satz der Textbloecke (`TextBlock` im Kern, Auftrag 25.11.2026 "wie Word"): EIN Zeilensatz fuer Anzeige, Bearbeiten,
/// Export und Messen. Auf linierten Seiten (`snap: "lines"`) hat jede Zeile genau den Zeilenabstand der Vorlage und
/// ihre Grundlinie sitzt auf der Linie - auch bei gemischten Schriftgroessen (eine grosse Zeile nimmt zwei Linien).
///
/// Einfache Textfelder aus dem Web und Haftnotizen laufen weiter ueber `ObjectGeometry.attributedText` und `UILabel`
/// wie bisher; nur Objekte, die `TextBlock.isBlock` meldet, kommen hier an.
enum TextBlockRender {

    // MARK: Schrift

    /// Schrift einer Familie mit fett/kursiv; unbekannte Familien fallen auf Arial bzw. die Systemschrift zurueck
    static func font(_ s: TextBlock.Style) -> UIFont {
        let size = CGFloat(ObjectGeometry.clamped(s.fontSize, 14, in: ObjectGeometry.fontSizeRange))
        var base = UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: s.fontFamily]), size: size)
        if base.familyName.caseInsensitiveCompare(s.fontFamily) != .orderedSame {
            base = UIFont(name: s.fontFamily, size: size) ?? UIFont(name: "Arial", size: size) ?? .systemFont(ofSize: size)
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if s.bold { traits.insert(.traitBold) }
        if s.italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        if let d = base.fontDescriptor.withSymbolicTraits(traits) { return UIFont(descriptor: d, size: size) }
        // Familie ohne diesen Schnitt (z. B. Filzstift kursiv): wenigstens das, was es gibt
        if s.bold, let d = base.fontDescriptor.withSymbolicTraits(.traitBold) { return UIFont(descriptor: d, size: size) }
        if s.italic, let d = base.fontDescriptor.withSymbolicTraits(.traitItalic) { return UIFont(descriptor: d, size: size) }
        return base
    }

    /// Deckkraft der Markierung hinter dem Text (wie der Textmarker: die Schrift bleibt gut lesbar)
    static let markAlpha: CGFloat = 0.55

    /// Eigene Kennzeichen am Text: so kommt aus dem bearbeiteten Text wieder genau die Formatierung des Kerns heraus
    /// (die Schrift allein sagt nicht sicher, ob "fett" gewollt war, wenn die Familie keinen fetten Schnitt hat)
    static let styleKey = NSAttributedString.Key("de.studinow.textblock.style")

    static func paragraphStyle(_ o: JSONValue) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        switch o["align"]?.string {
        case "center": p.alignment = .center
        case "right": p.alignment = .right
        default: p.alignment = .left
        }
        // eingerastet setzt `Layout` die Zeilenhoehe selbst; sonst das Vielfache aus dem Objekt
        if !TextBlock.isSnapped(o) {
            p.lineHeightMultiple = CGFloat(ObjectGeometry.number(o["lineHeight"], 1.3, in: ObjectGeometry.lineHeightRange))
        }
        return p
    }

    static func attributes(_ s: TextBlock.Style, paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [
            .font: font(s), .paragraphStyle: paragraph,
            .foregroundColor: UIColor(hex: s.fill) ?? UIColor(hex: "#1d2130") ?? .black,
            styleKey: StyleBox(s),
        ]
        if s.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if s.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if !s.mark.isEmpty, let c = UIColor(hex: s.mark) { a[.backgroundColor] = c.withAlphaComponent(markAlpha) }
        return a
    }

    /// Formatierung als Objekt am Text (NSAttributedString braucht Objekte mit Gleichheit)
    final class StyleBox: NSObject {
        let style: TextBlock.Style
        init(_ s: TextBlock.Style) { style = s }
        override func isEqual(_ object: Any?) -> Bool { (object as? StyleBox)?.style == style }
        override var hash: Int { style.hashValue }
    }

    /// Text des Blocks mit allen Abschnitten
    static func attributed(_ o: JSONValue) -> NSAttributedString {
        let para = paragraphStyle(o)
        let out = NSMutableAttributedString()
        for r in TextBlock.runs(o) { out.append(NSAttributedString(string: r.text, attributes: attributes(r.style, paragraph: para))) }
        return out
    }

    /// Formatierung fuer neu getippten Text in einem leeren Block
    static func baseAttributes(_ o: JSONValue) -> [NSAttributedString.Key: Any] {
        attributes(TextBlock.baseStyle(o), paragraph: paragraphStyle(o))
    }

    /// Abschnitte aus bearbeitetem Text (Textansicht). Zeichen ohne unser Kennzeichen (eingefuegt aus einer anderen
    /// App, Diktat) bekommen die Grundformatierung `fallback`.
    static func runs(from text: NSAttributedString, fallback: TextBlock.Style) -> [TextBlock.Run] {
        var out: [TextBlock.Run] = []
        let whole = text.string as NSString
        text.enumerateAttribute(styleKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            out.append(TextBlock.Run(text: whole.substring(with: range), style: (value as? StyleBox)?.style ?? fallback))
        }
        return TextBlock.merged(out)
    }

    /// Formatierung an einer Stelle des bearbeiteten Texts
    static func style(in text: NSAttributedString, at index: Int, fallback: TextBlock.Style) -> TextBlock.Style {
        guard text.length > 0 else { return fallback }
        let i = min(max(0, index), text.length - 1)
        return (text.attribute(styleKey, at: i, effectiveRange: nil) as? StyleBox)?.style ?? fallback
    }

    /// Aenderung auf einen Bereich des bearbeiteten Texts anwenden (Schrift, Farben, Kennzeichen zusammen)
    static func apply(_ change: TextBlock.Change, to storage: NSMutableAttributedString, range: NSRange, fallback: TextBlock.Style,
                      paragraph: NSParagraphStyle) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        var pieces: [(NSRange, TextBlock.Style)] = []
        storage.enumerateAttribute(styleKey, in: range) { value, r, _ in
            pieces.append((r, change.applied(to: (value as? StyleBox)?.style ?? fallback)))
        }
        storage.beginEditing()
        for (r, s) in pieces {
            // alte Kennzeichen des Bereichs weg (Unterstreichung, Markierung), dann die neuen setzen
            for k in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .backgroundColor] { storage.removeAttribute(k, range: r) }
            storage.addAttributes(attributes(s, paragraph: paragraph), range: r)
        }
        storage.endEditing()
    }

    // MARK: Zeilensatz

    /// TextKit-Satz eines Blocks: Speicher, Zeilensatz und Behaelter. Dieselbe Klasse setzt die Zeilen der Textansicht
    /// beim Bearbeiten (als `delegate` ihres Zeilensatzes).
    final class Layout: NSObject, NSLayoutManagerDelegate {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container: NSTextContainer
        /// Zeilenabstand der Linien; nil = frei gesetzt (blanko, PDF-Seite)
        let step: CGFloat?

        init(text: NSAttributedString, innerWidth: CGFloat, snapped: Bool) {
            storage = NSTextStorage(attributedString: text)
            container = NSTextContainer(size: CGSize(width: max(1, innerWidth), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            step = snapped ? CGFloat(TextBlock.lineStep) : nil
            super.init()
            manager.delegate = self
            manager.usesFontLeading = false
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        /// Zeile auf dem Linienraster: so hoch wie ein Zeilenabstand (grosse Schrift: so viele wie noetig), Grundlinie
        /// `TextBlock.baselineDrop` ueber dem unteren Rand - der untere Rand liegt damit immer gleich weit unter einer Linie.
        func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
                           lineFragmentUsedRect: UnsafeMutablePointer<CGRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                           in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
            guard let step else { return false }
            let rows = Layout.rows(ascent: baselineOffset.pointee, step: step)
            let height = rows * step
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = height - CGFloat(TextBlock.baselineDrop)
            return true
        }

        /// Zeilenabstaende, die eine Zeile mit dieser Oberlaenge braucht (2 pt duerfen ueber die Linie darueber ragen)
        static func rows(ascent: CGFloat, step: CGFloat) -> CGFloat {
            guard ascent.isFinite, step > 0 else { return 1 }
            return min(40, max(1, ((ascent + CGFloat(TextBlock.baselineDrop) - 2) / step).rounded(.up)))
        }

        /// Hoehe des gesetzten Texts (ohne Innenabstand). Leerer Text und eine leere letzte Zeile zaehlen als eine Zeile.
        var height: CGFloat {
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            var h = used.maxY
            if let step {
                let extra = manager.extraLineFragmentRect
                if storage.length == 0 { h = step }
                else if extra.height > 0 {
                    // die leere Zeile nach einem Zeilenumbruch setzt TextKit ohne uns zu fragen: auf einen Zeilenabstand bringen
                    h = extra.minY + step
                }
                h = (h / step).rounded(.up) * step
            }
            return h.isFinite ? min(CGFloat(ObjectGeometry.maxCoordinate), max(0, ceil(h * 100) / 100)) : 0
        }

        /// Grundlinien aller Zeilen von der Oberkante des Texts (ohne Innenabstand), fuer Tests und Abnahme
        var baselines: [CGFloat] {
            manager.ensureLayout(for: container)
            var out: [CGFloat] = []
            let glyphs = manager.glyphRange(for: container)
            manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
                out.append(rect.minY + self.manager.location(forGlyphAt: range.location).y)
            }
            return out
        }

        func draw(at origin: CGPoint) {
            let glyphs = manager.glyphRange(for: container)
            manager.drawBackground(forGlyphRange: glyphs, at: origin)
            manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
    }

    static func layout(_ o: JSONValue, text: NSAttributedString? = nil) -> Layout {
        let width = CGFloat(ObjectGeometry.number(o["width"], 220, in: 0...ObjectGeometry.maxCoordinate))
        return Layout(text: text ?? attributed(o), innerWidth: width - 2 * ObjectGeometry.textPadding, snapped: TextBlock.isSnapped(o))
    }

    /// Groesse des Blocks (Breite aus dem Objekt, Hoehe aus dem Satz), mit Innenabstand
    static func size(_ o: JSONValue, text: NSAttributedString? = nil) -> CGSize {
        let width = CGFloat(ObjectGeometry.number(o["width"], 220, in: 0...ObjectGeometry.maxCoordinate))
        let l = layout(o, text: text)
        var h = l.height
        // leerer, frei gesetzter Block: eine Zeile in der Grundschrift
        if l.storage.length == 0, l.step == nil { h = ceil(font(TextBlock.baseStyle(o)).lineHeight) }
        return CGSize(width: width, height: h + 2 * ObjectGeometry.textPadding)
    }

    /// Block in einen Grafikkontext zeichnen (Ursprung = linke obere Ecke des Objekts): PDF-Export, Drucken, Vorschau
    static func draw(_ o: JSONValue, in ctx: CGContext) {
        let l = layout(o)
        let size = CGSize(width: l.container.size.width + 2 * ObjectGeometry.textPadding, height: l.height + 2 * ObjectGeometry.textPadding)
        if let bg = ObjectGeometry.color(o["bg"]) {
            ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.setFillColor(bg.cgColor)
            ctx.fillPath()
        }
        UIGraphicsPushContext(ctx)
        l.draw(at: CGPoint(x: ObjectGeometry.textPadding, y: ObjectGeometry.textPadding))
        UIGraphicsPopContext()
    }
}

/// Anzeige eines Textblocks auf der Seite (in `PageObjectsView`, ohne Eingabe): zeichnet den Satz selbst und bleibt beim
/// Zoomen scharf (`contentScaleFactor`).
final class TextBlockView: UIView {
    private(set) var object: JSONValue
    private var layout: TextBlockRender.Layout

    init(object: JSONValue) {
        self.object = object
        layout = TextBlockRender.layout(object)
        super.init(frame: CGRect(origin: .zero, size: TextBlockRender.size(object)))
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = object["text"]?.string
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    /// Anderen Stand zeigen (Vorschau beim Aendern der Breite): neu umbrechen, Groesse folgt dem Satz
    func show(_ o: JSONValue) {
        object = o
        layout = TextBlockRender.layout(o)
        bounds = CGRect(origin: .zero, size: TextBlockRender.size(o))
        setNeedsDisplay()
    }

    /// Grundlinien der Zeilen in Seitenpunkten (ohne Drehung), fuer Tests
    var baselinesOnPage: [CGFloat] {
        let y = CGFloat(object["y"]?.double ?? 0) + ObjectGeometry.textPadding
        return layout.baselines.map { y + $0 }
    }

    override var contentScaleFactor: CGFloat {
        didSet { if contentScaleFactor != oldValue { setNeedsDisplay() } }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if let bg = ObjectGeometry.color(object["bg"]) {
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.setFillColor(bg.cgColor)
            ctx.fillPath()
        }
        // immer wie auf weissem Papier (helle Darstellung, wie die uebrigen Objekte der Seite)
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            layout.draw(at: CGPoint(x: ObjectGeometry.textPadding, y: ObjectGeometry.textPadding))
        }
    }
}
