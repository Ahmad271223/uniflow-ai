import UIKit
import UniFlowCore

/// Tabelle ("Excel", 26.11.2026) zeichnen: derselbe Code fuer die Seite, den PDF-Export, geteilte Loesungen und das
/// Gitter der grossen Ansicht (`SheetEditor.swift`). Gezeichnet wird in Tabellen-Punkten; der Kasten auf der Seite
/// skaliert mit `SheetObject.scale`. Diagramme zeichnet `SheetChartRender` - kein Fremdbaustein.
enum SheetRender {
    static let gridColor = UIColor(hex: "#d5d9e0") ?? .lightGray
    static let frameColor = UIColor(hex: "#8f96a3") ?? .gray
    static let headerFill = UIColor(hex: "#f1f3f6") ?? .systemGray6
    static let borderColor = UIColor(hex: "#1d2130") ?? .black
    static let textColor = UIColor(hex: "#1d2130") ?? .black
    static let errorColor = UIColor(hex: "#d7263d") ?? .red

    /// Lage der Zeilen und Spalten in Tabellen-Punkten (gefilterte Zeilen haben die Hoehe 0)
    struct Grid {
        let colX: [CGFloat]
        let rowY: [CGFloat]

        init(_ s: Sheet, hidden: Set<Int>) {
            var x: [CGFloat] = [0], y: [CGFloat] = [0]
            x.reserveCapacity(s.cols + 1)
            y.reserveCapacity(s.rows + 1)
            for c in 0..<s.cols { x.append(x[c] + CGFloat(s.width(c))) }
            for r in 0..<s.rows { y.append(y[r] + (hidden.contains(r) ? 0 : CGFloat(s.height(r)))) }
            colX = x
            rowY = y
        }

        var size: CGSize { CGSize(width: colX.last ?? 0, height: rowY.last ?? 0) }
        var cols: Int { colX.count - 1 }
        var rows: Int { rowY.count - 1 }

        func rect(_ r: SheetRef) -> CGRect {
            guard r.col >= 0, r.row >= 0, r.col < cols, r.row < rows else { return .null }
            return CGRect(x: colX[r.col], y: rowY[r.row], width: colX[r.col + 1] - colX[r.col], height: rowY[r.row + 1] - rowY[r.row])
        }

        func rect(_ g: SheetRange) -> CGRect { rect(g.from).union(rect(g.to)) }

        private static func index(_ edges: [CGFloat], at v: CGFloat) -> Int? {
            guard edges.count > 1, v >= 0, v < edges[edges.count - 1] else { return nil }
            var lo = 0, hi = edges.count - 2
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if edges[mid] <= v { lo = mid } else { hi = mid - 1 }
            }
            // gefilterte Zeilen (Hoehe 0) ueberspringen: die letzte Kante <= v gehoert zur sichtbaren Zeile
            return lo
        }

        func col(at x: CGFloat) -> Int? { Grid.index(colX, at: x) }
        func row(at y: CGFloat) -> Int? { Grid.index(rowY, at: y) }

        /// Zelle unter einem Punkt; ausserhalb: die naechste am Rand
        func nearest(_ p: CGPoint) -> SheetRef {
            let x = min(max(0, p.x), max(0, size.width - 0.01)), y = min(max(0, p.y), max(0, size.height - 0.01))
            return SheetRef(col: col(at: x) ?? 0, row: row(at: y) ?? 0)
        }

        func range(in rect: CGRect) -> SheetRange? {
            let r = rect.intersection(CGRect(origin: .zero, size: size))
            guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
            return SheetRange(nearest(CGPoint(x: r.minX, y: r.minY)), nearest(CGPoint(x: r.maxX - 0.01, y: r.maxY - 0.01)))
        }
    }

    /// Gemerkte Texte je Zelle (das Gitter der grossen Ansicht zeichnet bei jedem Rollen neu)
    final class Cache {
        var texts: [SheetRef: (text: NSAttributedString, size: CGSize)] = [:]
    }

    static func font(_ st: SheetStyle, header: Bool) -> UIFont {
        let size = CGFloat(Sheet.fontSize)
        let base = UIFont.systemFont(ofSize: size, weight: st.bold || header ? .semibold : .regular)
        guard st.italic, let d = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return base }
        return UIFont(descriptor: d, size: size)
    }

    static func attributed(_ text: String, _ s: Sheet, _ r: SheetRef, isError: Bool) -> NSAttributedString {
        let st = s.style(r)
        let color = isError && st.color == nil ? errorColor : (st.color.flatMap { UIColor(hex: $0) } ?? textColor)
        return NSAttributedString(string: text, attributes: [.font: font(st, header: s.header && r.row == 0), .foregroundColor: color])
    }

    /// Zellen im Ausschnitt `clip` zeichnen (Ursprung der Tabelle = Ursprung des Kontexts). `editing`: Diese Zelle zeigt
    /// den Text, der gerade getippt wird.
    static func drawCells(_ s: Sheet, _ calc: SheetCalc, _ grid: Grid, hidden: Set<Int>, clip: CGRect, cache: Cache? = nil,
                          editing: (ref: SheetRef, text: String)? = nil, in ctx: CGContext) {
        let table = CGRect(origin: .zero, size: grid.size)
        guard let visible = grid.range(in: clip) else { return }
        ctx.saveGState()
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(table.intersection(clip.insetBy(dx: -1, dy: -1)))
        let rows = visible.rows.filter { !hidden.contains($0) }
        // Zellfarben
        for row in rows {
            for col in visible.cols {
                let r = SheetRef(col: col, row: row)
                if let fill = s.styles[r]?.fill.flatMap({ UIColor(hex: $0) }) {
                    ctx.setFillColor(fill.cgColor)
                    ctx.fill(grid.rect(r))
                } else if s.header, row == 0 {
                    ctx.setFillColor(headerFill.cgColor)
                    ctx.fill(grid.rect(r))
                }
            }
        }
        // Gitter
        ctx.setStrokeColor(gridColor.cgColor)
        ctx.setLineWidth(0.5)
        let top = grid.rowY[visible.from.row], bottom = grid.rowY[visible.to.row + 1]
        let left = grid.colX[visible.from.col], right = grid.colX[visible.to.col + 1]
        for col in visible.from.col...(visible.to.col + 1) {
            ctx.move(to: CGPoint(x: grid.colX[col], y: top)); ctx.addLine(to: CGPoint(x: grid.colX[col], y: bottom))
        }
        for row in rows {
            ctx.move(to: CGPoint(x: left, y: grid.rowY[row])); ctx.addLine(to: CGPoint(x: right, y: grid.rowY[row]))
        }
        ctx.move(to: CGPoint(x: left, y: bottom)); ctx.addLine(to: CGPoint(x: right, y: bottom))
        ctx.strokePath()
        // Text
        UIGraphicsPushContext(ctx)
        let pad = CGFloat(Sheet.cellPadding)
        for row in rows {
            for col in visible.cols {
                let r = SheetRef(col: col, row: row)
                let cell = grid.rect(r)
                let typed = editing?.ref == r ? editing?.text : nil
                guard typed != nil || s.cells[r] != nil else { continue }
                let entry: (text: NSAttributedString, size: CGSize)
                if let typed {
                    let a = NSAttributedString(string: typed, attributes: [.font: font(s.style(r), header: false), .foregroundColor: textColor])
                    entry = (a, a.size())
                } else if let hit = cache?.texts[r] {
                    entry = hit
                } else {
                    let v = calc.value(r)
                    let a = attributed(s.display(r, calc), s, r, isError: v.error != nil)
                    entry = (a, a.size())
                    cache?.texts[r] = entry
                }
                guard entry.text.length > 0 else { continue }
                let inner = cell.insetBy(dx: pad, dy: 0)
                guard inner.width > 2 else { continue }
                var x = inner.minX
                switch typed == nil ? s.alignment(r, calc) : "l" {
                case "r": x = max(inner.minX, inner.maxX - entry.size.width)
                case "c": x = max(inner.minX, inner.midX - entry.size.width / 2)
                default: break
                }
                ctx.saveGState()
                ctx.clip(to: cell.insetBy(dx: 1, dy: 0.5))
                entry.text.draw(at: CGPoint(x: x, y: cell.midY - entry.size.height / 2))
                ctx.restoreGState()
            }
        }
        UIGraphicsPopContext()
        // Rahmen der Zellen
        ctx.setStrokeColor(borderColor.cgColor)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.square)
        var any = false
        for row in rows {
            for col in visible.cols {
                guard let b = s.styles[SheetRef(col: col, row: row)]?.border, b != 0 else { continue }
                let c = grid.rect(SheetRef(col: col, row: row))
                if b & 1 != 0 { ctx.move(to: CGPoint(x: c.minX, y: c.minY)); ctx.addLine(to: CGPoint(x: c.maxX, y: c.minY)) }
                if b & 2 != 0 { ctx.move(to: CGPoint(x: c.maxX, y: c.minY)); ctx.addLine(to: CGPoint(x: c.maxX, y: c.maxY)) }
                if b & 4 != 0 { ctx.move(to: CGPoint(x: c.minX, y: c.maxY)); ctx.addLine(to: CGPoint(x: c.maxX, y: c.maxY)) }
                if b & 8 != 0 { ctx.move(to: CGPoint(x: c.minX, y: c.minY)); ctx.addLine(to: CGPoint(x: c.minX, y: c.maxY)) }
                any = true
            }
        }
        if any { ctx.strokePath() }
        // Rand der Tabelle
        ctx.setStrokeColor(frameColor.cgColor)
        ctx.setLineWidth(0.8)
        ctx.stroke(table.insetBy(dx: 0.4, dy: 0.4))
        ctx.restoreGState()
    }

    // MARK: Kasten auf der Seite

    /// Alles, was zum Zeichnen eines Kastens gebraucht wird (einmal gerechnet)
    struct Prepared {
        let sheet: Sheet
        let calc: SheetCalc
        let layout: SheetObject.Layout
        let scale: CGFloat
        let grid: Grid

        init?(_ o: JSONValue) {
            guard let s = SheetObject.sheet(o) else { return nil }
            sheet = s
            calc = s.calc()
            layout = SheetObject.layout(s, calc)
            scale = CGFloat(SheetObject.scale(o, layout))
            grid = Grid(s, hidden: layout.hidden)
        }

        /// Groesse auf der Seite
        var size: CGSize { CGSize(width: CGFloat(layout.width) * scale, height: CGFloat(layout.height) * scale) }

        /// Zeichnen mit Ursprung links oben am Objekt; `clip` in Punkten des Objekts (nil: alles)
        func draw(in ctx: CGContext, clip: CGRect? = nil) {
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            let all = CGRect(x: 0, y: 0, width: CGFloat(layout.width), height: CGFloat(layout.height))
            let area = clip.map { CGRect(x: $0.minX / scale, y: $0.minY / scale, width: $0.width / scale, height: $0.height / scale).intersection(all) } ?? all
            var y: CGFloat = 0
            if layout.showsTable {
                SheetRender.drawCells(sheet, calc, grid, hidden: layout.hidden, clip: area, in: ctx)
                y = CGFloat(layout.tableHeight)
            }
            for chart in layout.charts {
                if y > 0 { y += CGFloat(Sheet.gap) }
                let rect = CGRect(x: 0, y: y, width: CGFloat(layout.width), height: CGFloat(SheetChart.height))
                if rect.intersects(area) { SheetChartRender.draw(chart, chart.content(sheet, calc), in: rect, ctx: ctx) }
                y += CGFloat(SheetChart.height)
            }
            ctx.restoreGState()
        }
    }

    private static let lock = NSLock()
    private static var sizes: [JSONValue: CGSize] = [:]

    /// Groesse des Kastens auf der Seite. Gemerkt je Inhalt: Die Frage kommt bei jedem Antippen fuer jedes Textobjekt.
    static func size(_ o: JSONValue) -> CGSize {
        let key: JSONValue = .array([o["sheet"] ?? .null, o["width"] ?? .null])
        lock.lock()
        let hit = sizes[key]
        lock.unlock()
        if let hit { return hit }
        let size = Prepared(o)?.size ?? CGSize(width: 1, height: 1)
        lock.lock()
        if sizes.count > 48 { sizes.removeAll() }
        sizes[key] = size
        lock.unlock()
        return size
    }

    static func draw(_ o: JSONValue, in ctx: CGContext) { Prepared(o)?.draw(in: ctx) }

    /// Kleines Bild einer Tabelle (Werkzeug, Tests)
    static func image(_ o: JSONValue, scale: CGFloat = 2) -> UIImage? {
        guard let p = Prepared(o), p.size.width >= 1, p.size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: p.size, format: format).image { p.draw(in: $0.cgContext) }
    }
}

// MARK: - Diagramme

enum SheetChartRender {
    static func color(_ i: Int) -> UIColor { UIColor(hex: SheetChart.palette[i % SheetChart.palette.count]) ?? .systemBlue }

    private static func text(_ s: String, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor = SheetRender.textColor,
                             in rect: CGRect, align: NSTextAlignment = .left) {
        guard rect.width > 2, rect.height > 2 else { return }
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byTruncatingTail
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p], context: nil)
    }

    private static func width(_ s: String, size: CGFloat) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size)]).width
    }

    /// Diagramm in `rect` (Tabellen-Punkte)
    static func draw(_ chart: SheetChart, _ content: SheetChart.Content, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext(); ctx.restoreGState() }
        let frame = rect.insetBy(dx: 0.4, dy: 0.4)
        let box = UIBezierPath(roundedRect: frame, cornerRadius: 6)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.addPath(box.cgPath); ctx.fillPath()
        ctx.setStrokeColor(SheetRender.gridColor.cgColor)
        ctx.setLineWidth(0.8)
        ctx.addPath(box.cgPath); ctx.strokePath()
        var area = rect.insetBy(dx: 10, dy: 8)
        if !chart.title.isEmpty {
            text(chart.title, size: 12, weight: .semibold, in: CGRect(x: area.minX, y: area.minY, width: area.width, height: 16), align: .center)
            area = CGRect(x: area.minX, y: area.minY + 20, width: area.width, height: area.height - 20)
        }
        guard !content.isEmpty, area.width > 40, area.height > 40 else {
            text("Keine Zahlen im Bereich \(chart.range.name)", size: 11, color: .gray, in: CGRect(x: area.minX, y: area.midY - 8, width: area.width, height: 16), align: .center)
            return
        }
        if chart.kind == "pie" { pie(content, in: area, ctx: ctx); return }
        // Legende unten, wenn es mehrere Reihen gibt
        if content.series.count > 1 {
            var x = area.minX
            let y = area.maxY - 12
            for (i, s) in content.series.enumerated() {
                let w = min(width(s.name, size: 9.5) + 2, 110)
                guard x + 12 + w <= area.maxX else { break }
                ctx.setFillColor(color(i).cgColor)
                ctx.fill(CGRect(x: x, y: y + 2, width: 8, height: 8))
                text(s.name, size: 9.5, in: CGRect(x: x + 11, y: y, width: w, height: 12))
                x += 11 + w + 10
            }
            area.size.height -= 16
        }
        let bounds = content.bounds
        let axis = SheetChart.axis(min: bounds.min, max: bounds.max)
        let labels = stride(from: axis.low, through: axis.high + axis.step * 0.001, by: axis.step).map { ($0, SheetText.general(abs($0) < axis.step * 1e-9 ? 0 : ($0 * 1e9).rounded() / 1e9)) }
        let leftPad = min(60, (labels.map { width($0.1, size: 9) }.max() ?? 20) + 6)
        let plot = CGRect(x: area.minX + leftPad, y: area.minY + 4, width: area.width - leftPad - 2, height: area.height - 4 - 16)
        guard plot.width > 20, plot.height > 20 else { return }
        func y(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - axis.low) / (axis.high - axis.low)) * plot.height }
        ctx.setLineWidth(0.5)
        for (v, label) in labels {
            let yy = y(v)
            ctx.setStrokeColor((abs(v) < axis.step * 1e-9 ? SheetRender.frameColor : SheetRender.gridColor).cgColor)
            ctx.move(to: CGPoint(x: plot.minX, y: yy)); ctx.addLine(to: CGPoint(x: plot.maxX, y: yy)); ctx.strokePath()
            text(label, size: 9, color: .darkGray, in: CGRect(x: area.minX, y: yy - 6, width: leftPad - 4, height: 12), align: .right)
        }
        let n = content.categories.count
        guard n > 0 else { return }
        let slot = plot.width / CGFloat(n)
        // Beschriftung unten: so viele, wie nebeneinander passen
        let widest = min(90, content.categories.map { width($0, size: 9) }.max() ?? 10) + 6
        let every = max(1, Int((widest / slot).rounded(.up)))
        for (i, c) in content.categories.enumerated() where i % every == 0 {
            let w = slot * CGFloat(every)
            text(c, size: 9, color: .darkGray, in: CGRect(x: plot.minX + slot * CGFloat(i) + (every == 1 ? 0 : slot / 2 - w / 2), y: plot.maxY + 3, width: w, height: 12), align: .center)
        }
        if chart.kind == "line" {
            for (si, s) in content.series.enumerated() {
                ctx.setStrokeColor(color(si).cgColor)
                ctx.setFillColor(color(si).cgColor)
                ctx.setLineWidth(1.6)
                ctx.setLineJoin(.round)
                var open = false
                for (i, v) in s.values.enumerated() {
                    guard let v else { open = false; continue }
                    let p = CGPoint(x: plot.minX + slot * (CGFloat(i) + 0.5), y: y(v))
                    if open { ctx.addLine(to: p) } else { ctx.move(to: p); open = true }
                }
                ctx.strokePath()
                for (i, v) in s.values.enumerated() {
                    guard let v else { continue }
                    ctx.fillEllipse(in: CGRect(x: plot.minX + slot * (CGFloat(i) + 0.5) - 2.2, y: y(v) - 2.2, width: 4.4, height: 4.4))
                }
            }
        } else {
            let k = CGFloat(content.series.count)
            let group = slot * 0.72, bar = group / k
            for (si, s) in content.series.enumerated() {
                ctx.setFillColor(color(si).cgColor)
                for (i, v) in s.values.enumerated() {
                    guard let v else { continue }
                    let x = plot.minX + slot * CGFloat(i) + (slot - group) / 2 + bar * CGFloat(si)
                    let y0 = y(0), y1 = y(v)
                    ctx.fill(CGRect(x: x + 0.5, y: min(y0, y1), width: max(1, bar - 1), height: max(0.5, abs(y1 - y0))))
                }
            }
        }
    }

    /// Kreis aus der ersten Reihe (nur Werte ueber 0), Legende rechts
    private static func pie(_ content: SheetChart.Content, in area: CGRect, ctx: CGContext) {
        guard let series = content.series.first else { return }
        let parts = zip(content.categories, series.values).compactMap { c, v -> (String, Double)? in v.flatMap { $0 > 0 ? (c, $0) : nil } }
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else {
            text("Für den Kreis braucht es Zahlen über 0", size: 11, color: .gray, in: CGRect(x: area.minX, y: area.midY - 8, width: area.width, height: 16), align: .center)
            return
        }
        let d = min(area.height, area.width * 0.5)
        let center = CGPoint(x: area.minX + d / 2 + 4, y: area.midY)
        var start = -CGFloat.pi / 2
        for (i, p) in parts.enumerated() {
            let end = start + CGFloat(p.1 / total) * 2 * .pi
            ctx.move(to: center)
            ctx.addArc(center: center, radius: d / 2 - 2, startAngle: start, endAngle: end, clockwise: false)
            ctx.closePath()
            ctx.setFillColor(color(i).cgColor)
            ctx.fillPath()
            start = end
        }
        // weisse Trennlinien
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1)
        start = -CGFloat.pi / 2
        if parts.count > 1 {
            for p in parts {
                ctx.move(to: center)
                ctx.addLine(to: CGPoint(x: center.x + cos(start) * (d / 2 - 2), y: center.y + sin(start) * (d / 2 - 2)))
                start += CGFloat(p.1 / total) * 2 * .pi
            }
            ctx.strokePath()
        }
        let legendX = area.minX + d + 16
        let rowsFit = max(1, Int(area.height / 14))
        var y = area.midY - CGFloat(min(rowsFit, parts.count)) * 7
        for (i, p) in parts.prefix(rowsFit).enumerated() {
            ctx.setFillColor(color(i).cgColor)
            ctx.fill(CGRect(x: legendX, y: y + 3, width: 8, height: 8))
            let share = SheetText.fixed(p.1 / total * 100, decimals: 0) + " %"
            text("\(p.0) · \(share)", size: 9.5, in: CGRect(x: legendX + 12, y: y, width: area.maxX - legendX - 12, height: 13))
            y += 14
        }
    }
}

// MARK: - Ansicht auf der Seite

/// Tabelle als Kasten auf der Seite (`PageObjectsView`). Zeichnet nur den sichtbaren Ausschnitt; die Aufloesung ist
/// begrenzt, damit eine grosse Tabelle beim Hineinzoomen keinen riesigen Speicher belegt (Vorgabe: Editor bleibt fluessig).
final class SheetBoxView: UIView {
    /// Hoechstens so viele Bildpunkte fuer einen Kasten (rund 32 MB)
    static let pixelBudget: CGFloat = 8_000_000
    private var prepared: SheetRender.Prepared?

    init(object: JSONValue) {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        show(object)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht genutzt") }

    func show(_ o: JSONValue) {
        prepared = SheetRender.Prepared(o)
        bounds = CGRect(origin: .zero, size: prepared?.size ?? CGSize(width: 1, height: 1))
        setNeedsDisplay()
    }

    override var contentScaleFactor: CGFloat {
        get { super.contentScaleFactor }
        set {
            let area = max(1, bounds.width * bounds.height)
            super.contentScaleFactor = max(1, min(newValue, (SheetBoxView.pixelBudget / area).squareRoot()))
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        prepared?.draw(in: ctx, clip: rect)
    }
}
