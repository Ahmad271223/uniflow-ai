import SwiftUI
import UniFlowCore

/// Gesetzte Block-Formel (18.11.2026, Antwortstil wie ChatGPT): zeichnet `MathLayout` nativ mit SwiftUI - Brueche
/// uebereinander mit Bruchstrich, Hoch-/Tiefstellung, Wurzel, Kasten fuer Ergebnisse (`\boxed`), Klammern in
/// Formelhoehe; Schrift: System-Serif (New York) wie gedruckte Mathematik, Variablen kursiv. Keine Web-Ansicht, kein
/// Skript, kein Netz; laeuft auf iPad, iPhone und Mac gleich. Zentriert; ist die Formel breiter als die Spalte, laesst
/// sie sich seitlich wischen statt abgeschnitten zu werden. Unbrauchbares LaTeX zeigt den lesbaren Text (`MathText`).
struct MathFormulaView: View {
    let latex: String
    var size: CGFloat = 17

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let s = UFScaledFont.scaled(size, typeSize)
        Group {
            if let lines = MathLayout.cachedParse(latex) {
                let formula = VStack(spacing: s * 0.45) {
                    ForEach(lines.indices, id: \.self) { i in MathNodeView(node: lines[i], size: s) }
                }
                .fixedSize()
                .padding(.vertical, s * 0.15)
                ViewThatFits(in: .horizontal) {
                    formula.frame(maxWidth: .infinity)
                    ScrollView(.horizontal, showsIndicators: false) { formula.padding(.horizontal, 2) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(lines.map(\.plain).joined(separator: ", "))
            } else {
                Text(FormulaText.attributed(latex.isEmpty ? "" : "$" + latex + "$", size: s)).ufFont(size, lh: 1.5)
                    .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(UF.text)
        .accessibilityIdentifier("ai.math")
    }
}

extension VerticalAlignment {
    /// Mathematische Achse: Mitte der Zeile bzw. Bruchstrich; daran richten sich die Teile einer Formel aus. Die
    /// Bausteine unten (`MathRowLayout`, `MathFractionLayout`, `MathScriptLayout`) melden sie selbst; einfacher Text
    /// nimmt seine Mitte.
    enum MathAxis: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let mathAxis = VerticalAlignment(MathAxis.self)
}

/// Teile nebeneinander, alle an der mathematischen Achse ausgerichtet; meldet die Achse nach aussen
struct MathRowLayout: Layout {
    var spacing: CGFloat = 0

    private func measure(_ subviews: Subviews) -> (width: CGFloat, above: CGFloat, below: CGFloat) {
        var width: CGFloat = 0, above: CGFloat = 0, below: CGFloat = 0
        for s in subviews {
            let d = s.dimensions(in: .unspecified)
            let axis = d[.mathAxis]
            above = max(above, axis)
            below = max(below, d.height - axis)
            width += d.width
        }
        return (width + spacing * CGFloat(max(0, subviews.count - 1)), above, below)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let m = measure(subviews)
        return CGSize(width: m.width, height: m.above + m.below)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = measure(subviews)
        var x = bounds.minX
        for s in subviews {
            let d = s.dimensions(in: .unspecified)
            s.place(at: CGPoint(x: x, y: bounds.minY + m.above - d[.mathAxis]), anchor: .topLeading, proposal: .unspecified)
            x += d.width + spacing
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        guide == .mathAxis ? bounds.minY + measure(subviews).above : nil
    }
}

/// Bruch: Zaehler, Bruchstrich (so breit wie der breitere Teil), Nenner; die Achse liegt auf dem Bruchstrich
struct MathFractionLayout: Layout {
    let gap: CGFloat
    let thickness: CGFloat

    private func parts(_ subviews: Subviews) -> (num: CGSize, den: CGSize, width: CGFloat) {
        let num = subviews[0].sizeThatFits(.unspecified), den = subviews[2].sizeThatFits(.unspecified)
        return (num, den, max(num.width, den.width))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let p = parts(subviews)
        return CGSize(width: p.width, height: p.num.height + gap + thickness + gap + p.den.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = parts(subviews)
        subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + p.num.height + gap), anchor: .topLeading,
                          proposal: ProposedViewSize(width: p.width, height: thickness))
        subviews[2].place(at: CGPoint(x: bounds.midX, y: bounds.minY + p.num.height + gap + thickness + gap), anchor: .top,
                          proposal: .unspecified)
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        guide == .mathAxis ? bounds.minY + parts(subviews).num.height + gap + thickness / 2 : nil
    }
}

/// Basis mit Hochzahl und/oder Index: die Hochzahl sitzt oben rechts (Unterkante `supDrop` unter der Oberkante der
/// Basis), der Index unten rechts (Oberkante `subRaise` ueber der Unterkante); die Achse ist die der Basis
struct MathScriptLayout: Layout {
    let hasSup: Bool
    let hasSub: Bool
    let supDrop: CGFloat
    let subRaise: CGFloat
    let gap: CGFloat

    private struct Frame { var base: CGPoint; var sup: CGPoint; var sub: CGPoint; var size: CGSize; var axis: CGFloat }

    private func frame(_ subviews: Subviews) -> Frame {
        let base = subviews[0].dimensions(in: .unspecified)
        let sup = hasSup ? subviews[1].sizeThatFits(.unspecified) : .zero
        let sub = hasSub ? subviews[hasSup ? 2 : 1].sizeThatFits(.unspecified) : .zero
        let top = hasSup ? max(0, sup.height - supDrop) : 0                      // so weit ragt die Hochzahl ueber die Basis
        let baseY = top
        let supY = baseY + supDrop - sup.height
        let subY = baseY + base.height - subRaise
        let height = max(baseY + base.height, hasSub ? subY + sub.height : 0)
        let x = base.width + gap
        return Frame(base: CGPoint(x: 0, y: baseY), sup: CGPoint(x: x, y: supY), sub: CGPoint(x: x, y: subY),
                     size: CGSize(width: x + max(sup.width, sub.width), height: height), axis: baseY + base[.mathAxis])
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { frame(subviews).size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let f = frame(subviews)
        func at(_ p: CGPoint) -> CGPoint { CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y) }
        subviews[0].place(at: at(f.base), anchor: .topLeading, proposal: .unspecified)
        if hasSup { subviews[1].place(at: at(f.sup), anchor: .topLeading, proposal: .unspecified) }
        if hasSub { subviews[hasSup ? 2 : 1].place(at: at(f.sub), anchor: .topLeading, proposal: .unspecified) }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        guide == .mathAxis ? bounds.minY + frame(subviews).axis : nil
    }
}

/// Ein Teil einer Formel (rekursiv); `size` ist die Schriftgroesse dieses Teils
struct MathNodeView: View {
    let node: MathNode
    let size: CGFloat
    /// in Bruechen und Hochzahlen kleiner (wie gedruckt), aber nie unter 9 pt
    private var smaller: CGFloat { max(9, size * 0.72) }
    private var line: CGFloat { max(1, size * 0.055) }

    var body: some View { content }

    private func serif(_ s: String, italic: Bool = false) -> some View {
        Text(s).font(.system(size: size, weight: .regular, design: .serif)).italic(italic).fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch node {
        case .row(let xs):
            MathRowLayout {
                ForEach(xs.indices, id: \.self) { i in MathNodeView(node: xs[i], size: size) }
            }
        case .ident(let s):
            serif(s, italic: true)
        case .number(let s), .symbol(let s):
            serif(s)
        case .text(let s):
            serif(s).padding(.horizontal, s.count > 1 && s.trimmingCharacters(in: .whitespaces) == s ? size * 0.08 : 0)
        case .op(let s):
            serif(s).padding(.horizontal, size * (s == "," ? 0.05 : 0.24))
        case .space(let em):
            Color.clear.frame(width: max(0, CGFloat(em) * size), height: 1)
        case .frac(let a, let b):
            let inner = node.isNestedFraction ? smaller : max(smaller, size * 0.9)
            MathFractionLayout(gap: size * 0.12, thickness: line) {
                MathNodeView(node: a, size: inner).padding(.horizontal, size * 0.12)
                Rectangle()
                MathNodeView(node: b, size: inner).padding(.horizontal, size * 0.12)
            }
            .padding(.horizontal, size * 0.06)
        case .scripts(let base, let sup, let sub):
            MathScriptLayout(hasSup: sup != nil, hasSub: sub != nil, supDrop: size * 0.68, subRaise: size * 0.4, gap: size * 0.04) {
                MathNodeView(node: base, size: size)
                if let sup { MathNodeView(node: sup, size: smaller) }
                if let sub { MathNodeView(node: sub, size: smaller) }
            }
        case .sqrt(let body, let index):
            MathRowLayout {
                if let index { MathNodeView(node: index, size: max(8, smaller * 0.8)).padding(.bottom, size * 0.6) }
                MathNodeView(node: body, size: size)
                    .padding(.top, size * 0.18).padding(.horizontal, size * 0.06)
                    .overlay(alignment: .top) { Rectangle().frame(height: line) }
                    .padding(.leading, size * 0.55)
                    .overlay(alignment: .leading) {
                        RadicalShape().stroke(style: StrokeStyle(lineWidth: line, lineJoin: .round)).frame(width: size * 0.55)
                    }
            }
        case .boxed(let body):
            MathNodeView(node: body, size: size)
                .padding(.horizontal, size * 0.45).padding(.vertical, size * 0.28)
                .overlay(Rectangle().strokeBorder(UF.text.opacity(0.85), lineWidth: max(1, line)))
                .padding(.horizontal, size * 0.1)
        case .fenced(let open, let body, let close):
            if body.isTall {
                // Klammern so hoch wie der Inhalt: als Linien neben dem Inhalt gezeichnet
                MathNodeView(node: body, size: size)
                    .padding(.horizontal, size * 0.06)
                    .padding(.leading, open.isEmpty ? 0 : size * 0.38).padding(.trailing, close.isEmpty ? 0 : size * 0.38)
                    .overlay(alignment: .leading) {
                        if !open.isEmpty { DelimiterShape(kind: open).stroke(lineWidth: line * 1.1).frame(width: size * 0.38) }
                    }
                    .overlay(alignment: .trailing) {
                        if !close.isEmpty { DelimiterShape(kind: close).stroke(lineWidth: line * 1.1).frame(width: size * 0.38) }
                    }
            } else {
                MathRowLayout {
                    if !open.isEmpty { serif(open) }
                    MathNodeView(node: body, size: size)
                    if !close.isEmpty { serif(close) }
                }
            }
        }
    }
}

private extension MathNode {
    /// Bruch, in dessen Zaehler oder Nenner wieder ein Bruch steht: der innere wird kleiner gesetzt
    var isNestedFraction: Bool {
        guard case .frac(let a, let b) = self else { return false }
        return a.isTall || b.isTall
    }
}

/// Wurzelzeichen: kurzer Haken, langer Strich nach oben rechts
struct RadicalShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY - r.height * 0.38))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.25, y: r.maxY - r.height * 0.45))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.55, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// Klammer in Formelhoehe: ( ) [ ] { } | ‖
struct DelimiterShape: Shape {
    let kind: String

    func path(in r: CGRect) -> Path {
        var p = Path()
        let left = ["(", "[", "{", "⟨"].contains(kind)
        let inner = left ? r.maxX - r.width * 0.15 : r.minX + r.width * 0.15
        let outer = left ? r.minX + r.width * 0.2 : r.maxX - r.width * 0.2
        switch kind {
        case "(", ")":
            p.move(to: CGPoint(x: inner, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: inner, y: r.maxY), control: CGPoint(x: outer - (inner - outer) * 0.6, y: r.midY))
        case "[", "]":
            p.move(to: CGPoint(x: inner, y: r.minY))
            p.addLine(to: CGPoint(x: outer, y: r.minY))
            p.addLine(to: CGPoint(x: outer, y: r.maxY))
            p.addLine(to: CGPoint(x: inner, y: r.maxY))
        case "{", "}":
            let mid = (inner + outer) / 2
            p.move(to: CGPoint(x: inner, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: mid, y: r.minY + r.height * 0.12), control: CGPoint(x: mid, y: r.minY))
            p.addLine(to: CGPoint(x: mid, y: r.midY - r.height * 0.08))
            p.addQuadCurve(to: CGPoint(x: outer, y: r.midY), control: CGPoint(x: mid, y: r.midY))
            p.addQuadCurve(to: CGPoint(x: mid, y: r.midY + r.height * 0.08), control: CGPoint(x: mid, y: r.midY))
            p.addLine(to: CGPoint(x: mid, y: r.maxY - r.height * 0.12))
            p.addQuadCurve(to: CGPoint(x: inner, y: r.maxY), control: CGPoint(x: mid, y: r.maxY))
        case "‖":
            for x in [r.midX - r.width * 0.15, r.midX + r.width * 0.15] {
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
            }
        default:                                             // | und Unbekanntes: ein Strich
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        }
        return p
    }
}
