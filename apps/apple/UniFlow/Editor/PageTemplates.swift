import UIKit
import UniFlowCore

/// Bildschirmvorlagen fuer Notizseiten, wie `renderTemplate` in app/static/editor.js. Abstaende, Farben und
/// Strichstaerken kommen aus `TemplateGeometry` (Kern, dort gegen die Web-Werte getestet), in Seitenpunkten.
/// Liegt in `PageObjectsView` ganz unten, also unter Text, Formen und der Tinte.
/// Der PDF-Export nutzt weiter `ObjectGeometry.templatePath` (entspricht `drawTemplatePdf` im Web).
enum PaperTemplate {
    /// Auswahl beim Einfuegen (gleiche Schluessel und Namen wie TEMPLATES im Web-Editor).
    static let choices: [(id: String, name: String)] = [
        ("blank", "Leer"), ("lined", "Liniert"), ("grid", "Kariert"),
        ("dotted", "Gepunktet"), ("mm", "Millimeter"), ("cornell", "Cornell"),
    ]

    static func isKnown(_ template: String) -> Bool { PageOrder.templates.contains(template) }

    static let lineColor = color(TemplateGeometry.lineColor)
    static let dotColor = color(TemplateGeometry.dotColor)
    static let cornellRuleColor = color(TemplateGeometry.cornellRuleColor)
    static let cornellLabelColor = color(TemplateGeometry.cornellLabelColor)
    static let cornellPaper = color(TemplateGeometry.cornellPaper)

    /// Ebenen der Vorlage fuer eine Seite der Groesse `size` (Ursprung oben links). Leer bei `blank`/`nil`.
    static func layers(for template: String?, size: CGSize) -> [CALayer] {
        let g = TemplateGeometry.make(template, width: Double(size.width), height: Double(size.height))
        guard !g.isEmpty else { return [] }
        let W = size.width, H = size.height
        let cornell = g.cornellFooterY != nil
        var out: [CALayer] = []

        if cornell {
            let paper = CALayer()
            paper.frame = CGRect(origin: .zero, size: size)
            paper.backgroundColor = cornellPaper.cgColor
            out.append(paper)
        }
        if !g.horizontal.isEmpty, g.vertical.isEmpty {
            // liniert und Cornell
            let p = CGMutablePath()
            for y in g.horizontal { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: W, y: y)) }
            out.append(stroke(p, color: lineColor, width: TemplateGeometry.lineWidth))
        }
        if !g.vertical.isEmpty {
            // Raster und Millimeterpapier (jede zehnte Linie kraeftiger)
            let thin = CGMutablePath(), bold = CGMutablePath()
            for (i, x) in g.vertical.enumerated() {
                let p = g.isBold(i) ? bold : thin
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: H))
            }
            for (i, y) in g.horizontal.enumerated() {
                let p = g.isBold(i) ? bold : thin
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: W, y: y))
            }
            out.append(stroke(thin, color: lineColor, width: TemplateGeometry.gridWidth))
            if !bold.isEmpty { out.append(stroke(bold, color: lineColor, width: TemplateGeometry.gridBoldWidth)) }
        }
        if !g.dotColumns.isEmpty {
            let p = CGMutablePath()
            let r = TemplateGeometry.dotRadius
            for x in g.dotColumns {
                for y in g.dotRows { p.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
            }
            let dots = CAShapeLayer()
            dots.path = p
            dots.fillColor = dotColor.cgColor
            dots.strokeColor = nil
            out.append(dots)
        }
        if let footer = g.cornellFooterY {
            let p = CGMutablePath()
            let x = TemplateGeometry.cornellDividerX
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: footer))
            p.move(to: CGPoint(x: 0, y: footer)); p.addLine(to: CGPoint(x: W, y: footer))
            out.append(stroke(p, color: cornellRuleColor, width: TemplateGeometry.cornellRuleWidth))
            for l in TemplateGeometry.cornellLabels {
                out.append(label(l.text, baseline: CGPoint(x: l.x, y: l.fromBottom ? Double(H) - l.y : l.y)))
            }
        }
        return out
    }

    /// "#rrggbb" -> UIColor (nur die festen Vorlagenfarben).
    private static func color(_ hex: String) -> UIColor {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    private static func stroke(_ path: CGPath, color: UIColor, width: CGFloat) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.path = path
        l.strokeColor = color.cgColor
        l.fillColor = nil
        l.lineWidth = width
        return l
    }

    /// Beschriftung wie `fillText` im Web (Punkt = Grundlinie links), 11 pt serifenlos.
    private static func label(_ text: String, baseline: CGPoint) -> CATextLayer {
        let font = UIFont.systemFont(ofSize: 11)
        let l = CATextLayer()
        l.string = text
        l.font = font
        l.fontSize = 11
        l.foregroundColor = cornellLabelColor.cgColor
        l.contentsScale = UIScreen.main.scale * 2          // bleibt beim Zoomen lesbar
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        l.frame = CGRect(x: baseline.x, y: baseline.y - font.ascender, width: width, height: ceil(font.lineHeight))
        return l
    }
}
