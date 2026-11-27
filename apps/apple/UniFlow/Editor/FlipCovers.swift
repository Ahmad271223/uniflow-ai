import PDFKit
import SwiftUI
import UIKit
import UniFlowCore

// Klappkarten zum Abfragen (`FlipCover` im Kern, Auftrag des Inhabers 25.11.2026): Abdeckungen UEBER allem auf der
// Seite - PDF, getippter Text, Handschrift. Antippen deckt auf, noch einmal antippen verdeckt wieder. Sie liegen in
// einer eigenen Schicht ueber der Zeichenflaeche (`PageObjectsView` der Art `.covers`); dieselbe Schicht haben die
// Leseansicht am iPhone und geteilte Loesungen daneben, damit Karten dort genauso aufklappen.

enum CoverRender {
    /// Karte zeichnen (Ursprung = linke obere Ecke). `revealed`: aufgedeckt - nur ein gestrichelter Rahmen und ein
    /// Hauch Farbe bleiben, damit man sieht, wo man zum Verdecken tippt.
    static func draw(_ o: JSONValue, size: CGSize, in ctx: CGContext, revealed: Bool = false) {
        guard size.width > 1, size.height > 1 else { return }
        let color = ObjectGeometry.color(o["fill"]) ?? UIColor(hex: FlipCover.colors[0].hex) ?? .darkGray
        let rect = CGRect(origin: .zero, size: size)
        let radius = min(7, min(size.width, size.height) / 4)
        let body = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
        if revealed {
            ctx.addPath(body)
            ctx.setFillColor(color.withAlphaComponent(0.07).cgColor)
            ctx.fillPath()
            ctx.addPath(body)
            ctx.setStrokeColor(color.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            return
        }
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
        let light = UIColor.white
        switch FlipCover.pattern(o) {
        case "stripes":
            ctx.setStrokeColor(light.withAlphaComponent(0.16).cgColor)
            ctx.setLineWidth(5)
            var x = -size.height
            while x < size.width + size.height {
                ctx.move(to: CGPoint(x: x, y: size.height)); ctx.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 14
            }
            ctx.strokePath()
        case "dots":
            ctx.setFillColor(light.withAlphaComponent(0.22).cgColor)
            var row = 0
            var y: CGFloat = 6
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 6 : 12
                while x < size.width { ctx.fillEllipse(in: CGRect(x: x - 1.8, y: y - 1.8, width: 3.6, height: 3.6)); x += 12 }
                y += 9
                row += 1
            }
        case "grid":
            ctx.setStrokeColor(light.withAlphaComponent(0.2).cgColor)
            ctx.setLineWidth(0.8)
            var x: CGFloat = 10
            while x < size.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: size.height)); x += 10 }
            var y: CGFloat = 10
            while y < size.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: size.width, y: y)); y += 10 }
            ctx.strokePath()
        case "question":
            let h = min(size.height * 0.78, 30)
            let font = UIFont.systemFont(ofSize: max(9, h), weight: .heavy)
            let mark = NSAttributedString(string: "?", attributes: [.font: font, .foregroundColor: light.withAlphaComponent(0.3)])
            let m = mark.size()
            UIGraphicsPushContext(ctx)
            var x = max(6, (size.width.truncatingRemainder(dividingBy: m.width + 14)) / 2)
            while x + m.width <= size.width - 2 {
                mark.draw(at: CGPoint(x: x, y: (size.height - m.height) / 2))
                x += m.width + 14
            }
            UIGraphicsPopContext()
        default:
            break
        }
        // oben ein Hauch Licht, unten etwas Schatten: die Karte liegt auf der Seite
        let colors = [light.withAlphaComponent(0.16).cgColor, light.withAlphaComponent(0).cgColor, UIColor.black.withAlphaComponent(0.12).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        ctx.restoreGState()
    }

    static func swatch(_ choice: FlipCover.Choice, size: CGSize = CGSize(width: 60, height: 30)) -> UIImage {
        let o = FlipCover.cover(id: "muster", x: 0, y: 0, width: size.width - 4, height: size.height - 4, choice: choice)
        return UIGraphicsImageRenderer(size: size).image { r in
            r.cgContext.translateBy(x: 2, y: 2)
            draw(o, size: CGSize(width: size.width - 4, height: size.height - 4), in: r.cgContext)
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// Eine Klappkarte auf der Seite (in der Schicht ueber der Handschrift)
final class CoverView: UIView {
    var object: JSONValue { didSet { setNeedsDisplay() } }
    private(set) var revealed: Bool

    init(object: JSONValue, revealed: Bool, frame: CGRect) {
        self.object = object
        self.revealed = revealed
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        describe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    private func describe() {
        accessibilityLabel = "Klappkarte"
        accessibilityValue = revealed ? "aufgedeckt" : "verdeckt"
        accessibilityHint = revealed ? "Antippen verdeckt wieder" : "Antippen deckt auf"
        accessibilityIdentifier = "cover.\(object["id"]?.string ?? "")"
    }

    /// Auf- bzw. zudecken, mit kurzem Umklappen
    func setRevealed(_ on: Bool, animated: Bool) {
        guard on != revealed else { return }
        revealed = on
        describe()
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else { setNeedsDisplay(); return }
        UIView.transition(with: self, duration: 0.22, options: [on ? .transitionFlipFromTop : .transitionFlipFromBottom, .allowUserInteraction]) {
            self.setNeedsDisplay()
            self.layer.displayIfNeeded()
        }
    }

    override var contentScaleFactor: CGFloat {
        didSet { if contentScaleFactor != oldValue { setNeedsDisplay() } }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        CoverRender.draw(object, size: bounds.size, in: ctx, revealed: revealed)
    }
}

/// Antippen einer Klappkarte deckt auf bzw. verdeckt wieder. Ein Erkenner an der Ansicht mit den Seiten (Editor,
/// Leseansicht am iPhone, geteilte Loesung daneben); er nimmt nur Beruehrungen an, die auf einer Karte liegen, und
/// stoert sonst nichts (Blaettern, Zoomen, Schreiben).
@MainActor
final class CoverTapper: NSObject, UIGestureRecognizerDelegate {
    private(set) lazy var tap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        g.delegate = self
        g.cancelsTouchesInView = false
        return g
    }()
    /// Darf gerade aufgeklappt werden? (Editor: nicht mit einem Objektwerkzeug - dort waehlt Antippen die Karte aus)
    var isEnabled: () -> Bool = { true }
    /// Schichten der gezeigten Seiten, wenn der Besitzer sie kennt (Editor, Leseansicht): spart das Durchsuchen aller
    /// Ansichten bei jeder Beruehrung. Ohne Angabe wird gesucht (`layers(in:)`).
    var layersProvider: (() -> [PageObjectsView])?
    /// Karte wurde auf- oder zugedeckt (fuer Tests und Hinweise)
    var onToggle: ((String, Bool) -> Void)?
    /// Ein Verweis wurde angetippt (`PageLinks.swift`)
    var onLink: ((PageLink.Target) -> Void)?

    func install(on view: UIView) {
        guard tap.view == nil else { return }
        view.addGestureRecognizer(tap)
    }

    /// Schichten mit Klappkarten unter einer Ansicht, die gerade gezeigt werden
    static func layers(in root: UIView) -> [PageObjectsView] {
        var out: [PageObjectsView] = []
        func walk(_ v: UIView) {
            if let p = v as? PageObjectsView {
                if p.kind == .covers, p.window != nil, !p.isHidden { out.append(p) }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    /// Klappkarte oder Verweis unter einem Punkt der Ansicht (oberste Schicht zuerst)
    func object(at point: CGPoint, in root: UIView) -> (layer: PageObjectsView, object: JSONValue)? {
        let layers = layersProvider?().filter { $0.window != nil && !$0.isHidden } ?? Self.layers(in: root)
        for layer in layers.reversed() where !layer.tops.isEmpty {
            let p = root.convert(point, to: layer)
            if let o = layer.topObject(at: p) { return (layer, o) }
        }
        return nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard isEnabled(), let root = g.view, let hit = object(at: touch.location(in: root), in: root) else { return false }
        // der Stift schreibt unter einer aufgedeckten Karte (`revealedLetPencilThrough`): Sein Aufsetzen klappt nicht zu
        if touch.type == .pencil, hit.layer.revealedLetPencilThrough, hit.layer.isRevealedCover(hit.object) { return false }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard isEnabled(), let root = g.view, let hit = object(at: g.location(in: root), in: root) else { return }
        if let target = PageLink.target(hit.object) {
            onLink?(target)
        } else if let id = hit.object["id"]?.string {
            let now = hit.layer.toggleCover(id)
            onToggle?(id, now)
        }
    }
}

/// Auswahl fuer neue Klappkarten (zweites Tippen auf das Werkzeug): Farbe, Muster, Groesse beim Antippen
struct CoverOptions: View {
    @State private var choice = EditorPalette.coverChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Über etwas ziehen verdeckt genau diese Stelle. Antippen legt eine Karte in der gewählten Größe an.")
                .ufFont(12.5, 500, lh: 1.35).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            row("Farbe") {
                ForEach(FlipCover.colors, id: \.hex) { c in
                    pick(FlipCover.Choice(color: c.hex, pattern: choice.pattern, size: choice.size), c.title, on: choice.color == c.hex,
                         size: CGSize(width: 40, height: 30))
                }
            }
            row("Muster") {
                ForEach(FlipCover.patterns, id: \.id) { p in
                    pick(FlipCover.Choice(color: choice.color, pattern: p.id, size: choice.size), p.title, on: choice.pattern == p.id,
                         size: CGSize(width: 52, height: 30))
                }
            }
            Picker("Größe", selection: Binding(get: { choice.size }, set: { set(FlipCover.Choice(color: choice.color, pattern: choice.pattern, size: $0)) })) {
                ForEach(FlipCover.sizes, id: \.id) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("cover.size")
        }
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("cover.options")
    }

    private func set(_ c: FlipCover.Choice) {
        choice = c
        EditorPalette.coverChoice = c
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).ufFont(12, 600).foregroundStyle(UF.muted)
            HStack(spacing: 4) { content() }
        }
    }

    private func pick(_ c: FlipCover.Choice, _ title: String, on: Bool, size: CGSize) -> some View {
        Button { set(c) } label: {
            Image(uiImage: CoverRender.swatch(c, size: size))
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).stroke(on ? UF.accentText : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension ObjectEditing {
    static let coverLockedHint = "Klappkarten zum Abfragen gibt es mit Plus."

    /// Neue Klappkarte: gezogenes Rechteck (`rect`) oder, beim Antippen, die gewaehlte Groesse um den Punkt
    func newCover(id: String, on overlay: PageInkView, rect: CGRect? = nil, at p: CGPoint) -> JSONValue {
        let choice = EditorPalette.coverChoice
        if let rect { return FlipCover.cover(id: id, x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height), choice: choice) }
        let page = (width: Double(overlay.geometry.pageSize.width), height: Double(overlay.geometry.pageSize.height))
        return FlipCover.cover(id: id, centerX: Double(p.x), centerY: Double(p.y), choice: choice, page: page)
    }

    /// Die Auswahl besteht nur aus Klappkarten (Objektleiste: Menue "Klappkarte"); ihre Art, sonst nil
    var selectedCovers: FlipCover.Choice? {
        guard let sel = selection, inkSelection == nil,
              let list = controller?.boundOverlay(forKey: sel.key)?.objectsView.shownObjects else { return nil }
        let chosen = list.filter { ($0["id"]?.string).map(sel.ids.contains) == true }
        guard let first = chosen.first, chosen.count == sel.ids.count, chosen.allSatisfy(FlipCover.isCover) else { return nil }
        return FlipCover.choice(first)
    }

    /// Gewaehlte Klappkarten umgestalten (Farbe, Muster, Groesse); ein Rueckgaengig-Schritt
    func restyleCovers(_ change: @escaping (inout FlipCover.Choice) -> Void) {
        guard richAllowed, let sel = selection else { return }
        inOrder { await $0.commit(sel.key) { FlipCover.restyling($0, ids: sel.ids, change) } }
    }
}
