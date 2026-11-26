import SwiftUI
import UIKit
import UniFlowCore

/// Aussehen der Notizzettel (`StickyNote` im Kern, Auftrag 25.11.2026: "wie echte Notizzettel"): Papier mit leichtem
/// Verlauf und Schatten, oben Klebestreifen, Tesafilm oder Pinnnadel, oder eine geknickte Ecke; blanko, liniert,
/// kariert oder gepunktet. Eine Zeichenroutine fuer Anzeige, Tippen und Export.
enum StickyNoteRender {

    static func darker(_ c: UIColor, by f: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return c }
        return UIColor(red: r * (1 - f), green: g * (1 - f), blue: b * (1 - f), alpha: a)
    }

    /// Kante der geknickten Ecke unten rechts (0 ohne)
    static func fold(_ o: JSONValue, size: CGSize) -> CGFloat {
        StickyNote.look(o) == "fold" ? min(24, min(size.width, size.height) * 0.2) : 0
    }

    /// Umriss des Zettels (unten rechts abgeschnitten, wenn die Ecke geknickt ist)
    static func outline(_ o: JSONValue, size: CGSize) -> CGPath {
        let f = fold(o, size: size)
        let p = CGMutablePath()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: size.width, y: 0))
        p.addLine(to: CGPoint(x: size.width, y: size.height - f))
        p.addLine(to: CGPoint(x: size.width - f, y: size.height))
        p.addLine(to: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }

    /// Zettel ohne Text zeichnen (Ursprung = linke obere Ecke). `shadow`: Schatten mitzeichnen (Export; auf dem
    /// Bildschirm wirft ihn die Ebene der Ansicht, sonst wuerde er an ihrem Rand abgeschnitten).
    static func draw(_ o: JSONValue, size: CGSize, in ctx: CGContext, shadow: Bool) {
        guard size.width > 1, size.height > 1 else { return }
        let base = ObjectGeometry.color(o["bg"]) ?? UIColor(hex: PageObjectEdit.stickyColor) ?? .yellow
        let look = StickyNote.look(o), paper = StickyNote.paper(o)
        let body = outline(o, size: size)
        let ink = UIColor.black

        ctx.saveGState()
        if shadow { ctx.setShadow(offset: CGSize(width: 0, height: 2.5), blur: 6, color: ink.withAlphaComponent(0.22).cgColor) }
        ctx.addPath(body)
        ctx.setFillColor(base.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        // Papier: oben etwas heller, unten etwas dunkler (der Zettel woelbt sich leicht)
        let colors = [UIColor.white.withAlphaComponent(0.22).cgColor, UIColor.white.withAlphaComponent(0).cgColor,
                      ink.withAlphaComponent(0.07).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        let top = CGFloat(StickyNote.padding.top)
        switch paper {
        case "lined":
            // Linien dort, wo die Grundlinien des Texts sitzen (`TextBlockRender.Layout`)
            let step = CGFloat(StickyNote.lineStep), drop = CGFloat(TextBlock.baselineDrop)
            ctx.setStrokeColor(ink.withAlphaComponent(0.16).cgColor)
            ctx.setLineWidth(0.6)
            var y = top + step - drop
            while y < size.height - 5 {
                ctx.move(to: CGPoint(x: 8, y: y)); ctx.addLine(to: CGPoint(x: size.width - 8, y: y))
                y += step
            }
            ctx.strokePath()
        case "grid":
            let step = CGFloat(StickyNote.gridStep)
            ctx.setStrokeColor(ink.withAlphaComponent(0.09).cgColor)
            ctx.setLineWidth(0.5)
            var x = step
            while x < size.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y = step
            while y < size.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.strokePath()
        case "dots":
            let step = CGFloat(StickyNote.gridStep)
            ctx.setFillColor(ink.withAlphaComponent(0.24).cgColor)
            var x = step
            while x < size.width - 2 {
                var y = step
                while y < size.height - 2 { ctx.fillEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)); y += step }
                x += step
            }
        default:
            break
        }
        switch look {
        case "tape":
            // Tesafilm oben in der Mitte: halb durchsichtig, mit heller Kante
            let w = max(40, size.width * 0.42)
            let tape = CGRect(x: (size.width - w) / 2, y: 2.5, width: w, height: 13)
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.55).cgColor)
            ctx.fill(tape)
            ctx.setFillColor(ink.withAlphaComponent(0.05).cgColor)
            ctx.fill(tape)
            ctx.setStrokeColor(ink.withAlphaComponent(0.12).cgColor)
            ctx.setLineWidth(0.5)
            ctx.stroke(tape)
        case "pin":
            let c = CGPoint(x: size.width / 2, y: 11), r: CGFloat = 6
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 1.5, height: 2.5), blur: 2.5, color: ink.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(UIColor(red: 0.86, green: 0.16, blue: 0.16, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.restoreGState()
            ctx.setFillColor(UIColor(red: 0.62, green: 0.08, blue: 0.1, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 2.6, y: c.y - 2.2, width: 5.2, height: 5.2))
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.75).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 3.6, y: c.y - 4, width: 2.6, height: 2.2))
        case "fold":
            break
        default:
            // Klebestreifen: der obere Rand liegt an und ist eine Spur dunkler
            ctx.setFillColor(ink.withAlphaComponent(0.05).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 17))
        }
        ctx.restoreGState()

        let f = fold(o, size: size)
        if f > 0 {
            // umgeschlagene Ecke: dunklere Unterseite mit kleinem Schatten
            let flap = CGMutablePath()
            flap.move(to: CGPoint(x: size.width - f, y: size.height))
            flap.addLine(to: CGPoint(x: size.width, y: size.height - f))
            flap.addLine(to: CGPoint(x: size.width - f, y: size.height - f))
            flap.closeSubpath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: -1, height: -1), blur: 2.5, color: ink.withAlphaComponent(0.25).cgColor)
            ctx.addPath(flap)
            ctx.setFillColor(darker(base, by: 0.14).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// Kleines Bild eines Zettels fuer die Auswahl (Werkzeug-Einstellungen, Menue)
    static func swatch(_ choice: StickyNote.Choice, side: CGFloat = 44) -> UIImage {
        let o = StickyNote.note(id: "muster", x: 0, y: 0, choice: choice)
        let pad: CGFloat = 5
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { r in
            let ctx = r.cgContext
            ctx.translateBy(x: pad, y: pad - 1)
            let inner = side - 2 * pad
            // verkleinert zeichnen, damit Klebestreifen und Linien wie am grossen Zettel wirken
            let scale = inner / 88
            ctx.scaleBy(x: scale, y: scale)
            draw(o, size: CGSize(width: 88, height: 88), in: ctx, shadow: true)
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// Hintergrund des Zettels unter der Textansicht beim Tippen (waechst mit dem Text)
final class StickyNoteBackdrop: UIView {
    var object: JSONValue { didSet { setNeedsDisplay() } }

    init(object: JSONValue, frame: CGRect) {
        self.object = object
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        applyShadow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyShadow()
    }

    private func applyShadow() { StickyNoteBackdrop.shadow(layer, object, size: bounds.size) }

    /// Schatten des Zettels an einer Ebene (folgt dem Umriss)
    static func shadow(_ layer: CALayer, _ o: JSONValue, size: CGSize) {
        layer.shadowPath = StickyNoteRender.outline(o, size: size)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        StickyNoteRender.draw(object, size: bounds.size, in: ctx, shadow: false)
    }
}

/// Auswahl fuer neue Zettel (zweites Tippen auf das Werkzeug "Haftnotiz"): Farbe, Aussehen, Papier, Groesse. Gemerkt
/// je Geraet (`EditorPalette.stickyChoice`). Ohne Pro AI: gesperrt mit Schloss, es bleibt die gelbe Haftnotiz.
struct StickyNoteOptions: View {
    @State private var choice = EditorPalette.stickyChoice
    @ObservedObject private var entitlements = Entitlements.shared
    var onChange: (StickyNote.Choice) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let plan = UFRichNotes.lockedPlan(plan: entitlements.plan) {
                UFLockedButton(plan: plan, title: "Notizzettel in Farben und Mustern", identifier: "sticky.locked") {
                    HStack(spacing: 8) {
                        Image(uiImage: StickyNoteRender.swatch(StickyNote.Choice(color: StickyNote.colors[1].hex, look: "tape", paper: "lined"), side: 36))
                        Text("Notizzettel in Farben und Mustern").ufFont(13.6, 600).foregroundStyle(UF.text)
                    }
                }
            } else {
                row("Farbe") {
                    ForEach(StickyNote.colors, id: \.hex) { c in
                        pick(StickyNote.Choice(color: c.hex, look: choice.look, paper: choice.paper, size: choice.size), c.title, on: choice.color == c.hex)
                    }
                }
                row("Aussehen") {
                    ForEach(StickyNote.looks, id: \.id) { l in
                        pick(StickyNote.Choice(color: choice.color, look: l.id, paper: choice.paper, size: choice.size), l.title, on: choice.look == l.id)
                    }
                }
                row("Papier") {
                    ForEach(StickyNote.papers, id: \.id) { p in
                        pick(StickyNote.Choice(color: choice.color, look: choice.look, paper: p.id, size: choice.size), p.title, on: choice.paper == p.id)
                    }
                }
                Picker("Größe", selection: Binding(get: { choice.size }, set: { set(StickyNote.Choice(color: choice.color, look: choice.look, paper: choice.paper, size: $0)) })) {
                    ForEach(StickyNote.sizes, id: \.id) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("sticky.size")
            }
        }
        .frame(minWidth: 300)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("sticky.options")
    }

    private func set(_ c: StickyNote.Choice) {
        choice = c
        EditorPalette.stickyChoice = c
        onChange(c)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).ufFont(12, 600).foregroundStyle(UF.muted)
            HStack(spacing: 6) { content() }
        }
    }

    private func pick(_ c: StickyNote.Choice, _ title: String, on: Bool) -> some View {
        Button { set(c) } label: {
            Image(uiImage: StickyNoteRender.swatch(c))
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).stroke(on ? UF.accentText : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
