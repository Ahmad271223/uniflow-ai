import PDFKit
import UIKit
import UniFlowCore

/// PDF-Export mit Notizen (Seiten in der Reihenfolge des Notizmodells, wie im Web-Editor).
/// Handschrift, Formen und Vorlagen landen als Vektoren in der PDF (kein Rasterbild ueber der Seite).
enum PDFExporter {

    /// Schreibt die PDF in einen temporaeren Ordner und gibt die Datei zurueck.
    static func export(layout: DisplayLayout, pages: [String: JSONValue], images: [String: UIImage], title: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safeFileName(title) + " – Notizen.pdf")
        let data = render(layout: layout, pages: pages, images: images, title: title)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// - Parameters:
    ///   - pageIndices: angezeigte Seiten (0-basiert, Reihenfolge des Notizmodells); `nil` = alle.
    ///   - title: Titel in den PDF-Metadaten.
    static func render(layout: DisplayLayout, pages: [String: JSONValue], images: [String: UIImage],
                       pageIndices: [Int]? = nil, title: String? = nil) -> Data {
        let count = layout.pdf.pageCount
        let indices = (pageIndices ?? Array(0..<count)).filter { $0 >= 0 && $0 < count }
        let format = UIGraphicsPDFRendererFormat()
        var info: [String: Any] = [kCGPDFContextCreator as String: "UniFlow"]
        if let title { info[kCGPDFContextTitle as String] = title }
        format.documentInfo = info
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842), format: format)
        return renderer.pdfData { ctx in
            for i in indices {
                guard let page = layout.pdf.page(at: i), let entry = layout.entry(at: i) else { continue }
                ctx.beginPage(withBounds: CGRect(origin: .zero, size: PageRenderer.size(of: page)), pageInfo: [:])
                PageRenderer.draw(page: page, entry: entry, objects: pages[entry.key]?["objects"]?.array ?? [],
                                  images: images, in: ctx.cgContext)
            }
        }
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Dokument" : String(cleaned.prefix(80))
    }
}

/// Eine angezeigte Seite zeichnen: Original-PDF-Seite bzw. weisse Leerseite, Vorlage, danach Text, Formen, Bilder
/// und Handschrift in der Reihenfolge der Objekte (wie die Konva-Ebene im Web-Editor).
/// Koordinaten: Seitenpunkte der angezeigten (gedrehten) Seite, Ursprung oben links.
/// Gemeinsam genutzt vom PDF-Export und von den Seitenminiaturen.
enum PageRenderer {

    /// Groesse der angezeigten Seite (CropBox inklusive Drehung).
    static func size(of page: PDFPage) -> CGSize {
        PageGeometry(boxSize: page.bounds(for: .cropBox).size, rotation: page.rotation).pageSize
    }

    static func draw(page: PDFPage, entry: DisplayLayout.Entry, objects: [JSONValue], images: [String: UIImage], in cg: CGContext) {
        let rect = CGRect(origin: .zero, size: size(of: page))
        if entry.kind == "pdf" {
            // PDF-Seite: PDFKit zeichnet mit Ursprung unten links und beruecksichtigt die Drehung
            cg.saveGState()
            cg.translateBy(x: 0, y: rect.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .cropBox, to: cg)
            cg.restoreGState()
        } else {
            // eingefuegte Leerseite (bzw. Platzhalter fuer Bild-/PDF-Seiten aus dem Browser)
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(rect)
        }

        drawTemplate(entry.template, size: rect.size, in: cg)
        drawObjects(objects, images: images, in: cg)
    }

    /// Vorlage (liniert, kariert ...) in Seitenpunkten.
    static func drawTemplate(_ template: String?, size: CGSize, in cg: CGContext) {
        let (lines, dots) = ObjectGeometry.templatePath(template, size: size)
        if let lines {
            cg.addPath(lines)
            cg.setStrokeColor(ObjectGeometry.templateColor.cgColor)
            cg.setLineWidth(template == "cornell" ? 1 : 0.5)
            cg.strokePath()
        }
        if let dots {
            cg.addPath(dots)
            cg.setFillColor(ObjectGeometry.templateColor.cgColor)
            cg.fillPath()
        }
    }

    /// Notizobjekte als eigene Gruppe (wie die Konva-Ebene auf eigenem Canvas ueber pdf.js): der Textmarker
    /// multipliziert nur mit den Objekten darunter, die Gruppe liegt normal ueber Seite und Vorlage.
    /// Ohne Textmarker ergibt die Gruppe dasselbe Bild, daher nur dann (kleinere PDF, keine Formular-Objekte).
    /// Auch fuer die Vorschau geteilter Loesungen (ohne PDF-Seite, siehe `SolutionPreview`).
    static func drawObjects(_ objects: [JSONValue], images: [String: UIImage], in cg: CGContext) {
        let group = objects.contains { InkRenderer.isMarker($0) }
        if group { cg.beginTransparencyLayer(auxiliaryInfo: nil) }
        for o in objects {
            if o["type"]?.string == "stroke" {
                InkRenderer.draw(o, in: cg)
            } else {
                ObjectGeometry.draw(objects: [o], images: images, in: cg)
            }
        }
        if group { cg.endTransparencyLayer() }
    }

    /// Miniatur einer Seite in der angegebenen Breite (Punkte), weisser Hintergrund.
    static func thumbnail(page: PDFPage, entry: DisplayLayout.Entry, objects: [JSONValue], images: [String: UIImage],
                          width: CGFloat, scale: CGFloat = 2) -> UIImage {
        let size = size(of: page)
        let s = width / max(1, size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let out = CGSize(width: width, height: (size.height * s).rounded())
        return UIGraphicsImageRenderer(size: out, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: out))
            ctx.cgContext.scaleBy(x: s, y: s)
            draw(page: page, entry: entry, objects: objects, images: images, in: ctx.cgContext)
        }
    }
}

/// Handschrift aus dem gemeinsamen Strichformat als Vektorpfade, mit denselben Regeln wie app/static/editor.js:
/// - Stift, Fueller, Bleistift (`makeInkShape`): Kurven durch die Mittelpunkte benachbarter Punkte. Mit Breite je
///   Punkt (`widths`) ein Teilstueck je Punktpaar mit der mittleren Breite der beiden Punkte; halbtransparent ein
///   einziger Pfad mit der Durchschnittsbreite (sonst ueberlagern sich die Teilstuecke zu dunklen Punkten).
/// - Bleistift gestrichelt (1,5 / 1,2).
/// - Textmarker (`Konva.Line`, tension 0): gerader Linienzug in Strichbreite, halbtransparent, Mischmodus
///   Multiplizieren (`globalCompositeOperation`). Wie im Web wirkt das nur innerhalb der Notizobjekte
///   (Transparenzgruppe in `PageRenderer.draw`), nicht mit der PDF-Seite darunter.
/// Transform wie bei allen Objekten: verschieben -> drehen -> skalieren; die Linienbreite skaliert mit (wie Konva).
enum InkRenderer {
    /// Teilpfade mit gemeinsamer Linienbreite (Objektkoordinaten).
    struct Piece {
        let path: CGPath
        let width: CGFloat
    }

    struct Plan {
        var pieces: [Piece]
        var color: UIColor
        var alpha: CGFloat
        var dash: [CGFloat]
        var multiply: Bool
        var transform: CGAffineTransform
    }

    static let pencilDash: [CGFloat] = [1.5, 1.2]

    static func isMarker(_ o: JSONValue) -> Bool { o["type"]?.string == "stroke" && o["tool"]?.string == "marker" }

    /// Teilstuecke, deren Breite sich weniger unterscheidet, landen in einem Pfad (kleinere PDF, gleiches Aussehen).
    static let widthTolerance: CGFloat = 0.05

    /// Zeichenplan eines Strichobjekts; `nil`, wenn nichts sichtbar waere (wie Konva bei weniger als zwei Punkten).
    static func plan(_ o: JSONValue) -> Plan? {
        guard o["type"]?.string == "stroke", let raw = o["points"]?.array else { return nil }
        let pts = raw.compactMap { $0.double }.map { CGFloat($0) }
        let n = pts.count / 2
        guard n >= 2 else { return nil }
        let tool = o["tool"]?.string ?? "pen"
        let given = CGFloat(o["width"]?.double ?? 0)
        let width = given > 0 ? given : 2                                     // o.width || 2
        let opacity = CGFloat(o["opacity"]?.double ?? 1)
        var plan = Plan(pieces: [], color: UIColor(hex: o["color"]?.string) ?? .black, alpha: min(1, max(0, opacity)),
                        dash: tool == "pencil" ? pencilDash : [], multiply: tool == "marker",
                        transform: ObjectGeometry.transform(o))
        func p(_ i: Int) -> CGPoint { CGPoint(x: pts[2 * i], y: pts[2 * i + 1]) }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

        if tool == "marker" {
            let path = CGMutablePath()
            path.move(to: p(0))
            for i in 1..<n { path.addLine(to: p(i)) }
            plan.pieces = [Piece(path: path, width: width)]
            return plan
        }

        let ws: [CGFloat]? = {
            guard let w = o["widths"]?.array?.compactMap({ $0.double }), w.count == n else { return nil }
            return w.map { CGFloat($0) }
        }()
        if ws == nil || opacity < 1 {
            let avg = ws.map { $0.reduce(0, +) / CGFloat($0.count) } ?? width
            let path = CGMutablePath()
            path.move(to: p(0))
            if n > 2 { for i in 1..<(n - 1) { path.addQuadCurve(to: mid(p(i), p(i + 1)), control: p(i)) } }
            path.addLine(to: p(n - 1))
            plan.pieces = [Piece(path: path, width: max(0.3, avg))]
            return plan
        }

        // Breite je Punkt: Teilstueck i von der Mitte (i-2, i-1) ueber den Kontrollpunkt i-1 zur Mitte (i-1, i)
        var pieces: [Piece] = []
        var current = CGMutablePath()
        var currentWidth: CGFloat = -1
        for i in 1..<n {
            let w = max(0.3, (ws![i - 1] + ws![i]) / 2)
            if currentWidth >= 0, abs(w - currentWidth) >= widthTolerance {
                pieces.append(Piece(path: current, width: currentWidth))
                current = CGMutablePath()
            }
            if current.isEmpty { currentWidth = w }
            current.move(to: i == 1 ? p(0) : mid(p(i - 1), p(i - 2)))
            if i == n - 1 {
                current.addLine(to: p(i))
            } else {
                current.addQuadCurve(to: mid(p(i - 1), p(i)), control: p(i - 1))
            }
        }
        if !current.isEmpty { pieces.append(Piece(path: current, width: currentWidth)) }
        plan.pieces = pieces
        return plan
    }

    static func draw(_ o: JSONValue, in ctx: CGContext) {
        guard let plan = plan(o) else { return }
        ctx.saveGState()
        ctx.concatenate(plan.transform)
        ctx.setAlpha(plan.alpha)
        if plan.multiply { ctx.setBlendMode(.multiply) }
        ctx.setStrokeColor(plan.color.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if !plan.dash.isEmpty { ctx.setLineDash(phase: 0, lengths: plan.dash) }
        for piece in plan.pieces {
            ctx.addPath(piece.path)
            ctx.setLineWidth(piece.width)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
