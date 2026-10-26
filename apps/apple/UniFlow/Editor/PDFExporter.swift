import PDFKit
import UIKit
import UniFlowCore

/// PDF-Export mit Notizen (Seiten in der Reihenfolge des Notizmodells, wie im Web-Editor).
/// Handschrift, Formen und Vorlagen landen als Vektoren in der PDF (kein Rasterbild ueber der Seite). Die Datei fuer
/// das Teilen-Menue schreibt `ShareExport.writeFile` (der einzige Weg).
enum PDFExporter {

    /// - Parameters:
    ///   - pageIndices: angezeigte Seiten (0-basiert, Reihenfolge des Notizmodells); `nil` = alle.
    ///   - title: Titel in den PDF-Metadaten.
    /// Geschrieben mit einem CoreGraphics-PDF-Kontext und eigener MediaBox je Seite: `UIGraphicsPDFRenderer`
    /// ersetzt eine Seite von genau 612 x 792 (US Letter) durch die Standardgroesse des Renderers, dann stimmten
    /// Groesse und Lage von Original und Notizen nicht mehr.
    static func render(layout: DisplayLayout, pages: [String: JSONValue], images: [String: UIImage],
                       pageIndices: [Int]? = nil, title: String? = nil) -> Data {
        let count = layout.pdf.pageCount
        let indices = (pageIndices ?? Array(0..<count)).filter { $0 >= 0 && $0 < count }
        var info: [String: Any] = [kCGPDFContextCreator as String: "UniFlow"]
        if let title { info[kCGPDFContextTitle as String] = title }
        let out = NSMutableData()
        var standard = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let cg = CGContext(consumer: consumer, mediaBox: &standard, info as CFDictionary) else { return Data() }
        for i in indices {
            guard let page = layout.pdf.page(at: i), let entry = layout.entry(at: i) else { continue }
            var box = CGRect(origin: .zero, size: PageRenderer.size(of: page))
            let pageInfo = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)]
            cg.beginPDFPage(pageInfo as CFDictionary)
            cg.saveGState()
            // Ursprung oben links wie UIKit (Seitenpunkte der angezeigten Seite)
            cg.translateBy(x: 0, y: box.height)
            cg.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(cg)
            PageRenderer.draw(page: page, entry: entry, objects: pages[entry.key]?["objects"]?.array ?? [],
                              images: images, in: cg)
            UIGraphicsPopContext()
            cg.restoreGState()
            cg.endPDFPage()
        }
        cg.closePDF()
        return out as Data
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Dokument" : String(cleaned.prefix(80))
    }

    /// Laengster Dateiname in UTF-8-Byte, unzerlegt (Grenze vieler Ziele beim Weitergeben, z. B. ext4).
    static let maxFileNameBytes = 255
    /// Laengster Dateiname in UTF-16-Einheiten nach der Zerlegung (APFS auf iPad und Mac, nachgemessen: der Name
    /// wird beim Schreiben kanonisch zerlegt, erlaubt sind danach 255 UTF-16-Einheiten). Kann enger sein als die
    /// Bytegrenze, z. B. "ǜ" (2 Byte, zerlegt 3 Einheiten) oder "ᾂ" (3 Byte, zerlegt 4 Einheiten).
    static let maxFileNameUnits = 255

    /// Laenge im Dateisystem in UTF-16-Einheiten: je Unicode-Skalar die groessere Zahl von unzerlegt und kanonisch
    /// zerlegt (NFD). Das Dateisystem zerlegt nicht alles (z. B. CJK-Kompatibilitaetszeichen U+2F800 ff. bleiben
    /// ganz), die groessere Zahl ist daher immer eine sichere Obergrenze.
    static func fileSystemUnits<S: StringProtocol>(_ s: S) -> Int {
        s.unicodeScalars.reduce(0) { n, scalar in
            let decomposed = String(scalar).decomposedStringWithCanonicalMapping.utf16.count
            return n + max(scalar.utf16.count, decomposed)
        }
    }

    /// Dateiname aus Titel und Endung (z. B. " – Notizen.pdf"): Titel wie `safeFileName`, der ganze Name hoechstens
    /// `maxFileNameBytes` UTF-8-Byte und `maxFileNameUnits` UTF-16-Einheiten nach der Zerlegung. Gekuerzt wird nur
    /// zwischen Zeichen (Graphemen), Emoji und Umlaute bleiben ganz; die Endung bleibt immer erhalten.
    static func fileName(_ title: String, suffix: String) -> String {
        let stem = safeFileName(title)
        let byteLimit = maxFileNameBytes - suffix.utf8.count
        let unitLimit = maxFileNameUnits - fileSystemUnits(suffix)
        var end = stem.startIndex
        var bytes = 0, units = 0
        for i in stem.indices {
            let c = String(stem[i])
            let b = c.utf8.count, u = fileSystemUnits(c)
            guard bytes + b <= byteLimit, units + u <= unitLimit else { break }
            bytes += b
            units += u
            end = stem.index(after: i)
        }
        guard end < stem.endIndex else { return stem + suffix }
        let kept = stem[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return (kept.isEmpty ? "Dokument" : kept) + suffix
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
        guard o["type"]?.string == "stroke", o["points"]?.array != nil else { return nil }
        // Zahlen endlich und begrenzt (siehe `ObjectGeometry.number`)
        let pts = ObjectGeometry.coordinates(o["points"]).map { CGFloat($0) }
        let n = pts.count / 2
        guard n >= 2 else { return nil }
        let tool = o["tool"]?.string ?? "pen"
        let given = CGFloat(ObjectGeometry.lineWidth(o["width"], 0))
        let width = given > 0 ? given : 2                                     // o.width || 2
        let opacity = CGFloat(ObjectGeometry.opacity(o))
        var plan = Plan(pieces: [], color: UIColor(hex: o["color"]?.string) ?? .black, alpha: opacity,
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
            return w.map { CGFloat(ObjectGeometry.clamped($0, 0, in: 0...ObjectGeometry.maxLineWidth)) }
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
