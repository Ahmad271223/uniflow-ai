import UIKit
import UniFlowCore

/// Bildschirmvorlagen fuer Notizseiten, wie `renderTemplate` in app/static/editor.js: gleiche Abstaende (Linien ab
/// 60 pt alle 24 pt, Raster und Punkte alle 14,17 pt = 5 mm, Millimeter 2,835 pt), Farben und Strichstaerken, in
/// Seitenpunkten. Liegt in `PageObjectsView` ganz unten, also unter Text, Formen und der Tinte.
/// Der PDF-Export nutzt weiter `ObjectGeometry.templatePath` (entspricht `drawTemplatePdf` im Web).
enum PaperTemplate {
    /// Auswahl beim Einfuegen (gleiche Schluessel und Namen wie TEMPLATES im Web-Editor).
    static let choices: [(id: String, name: String)] = [
        ("blank", "Leer"), ("lined", "Liniert"), ("grid", "Kariert"),
        ("dotted", "Gepunktet"), ("mm", "Millimeter"), ("cornell", "Cornell"),
    ]

    static func isKnown(_ template: String) -> Bool { PageOrder.templates.contains(template) }

    // Farben wie im Web (#d9dde8 Linien, #c9ced9 Punkte, Cornell: #b9c2d6 Trennlinien, #9aa0ae Beschriftung, #fffdf7 Papier)
    static let lineColor = UIColor(red: 217 / 255, green: 221 / 255, blue: 232 / 255, alpha: 1)
    static let dotColor = UIColor(red: 201 / 255, green: 206 / 255, blue: 217 / 255, alpha: 1)
    static let cornellRuleColor = UIColor(red: 185 / 255, green: 194 / 255, blue: 214 / 255, alpha: 1)
    static let cornellLabelColor = UIColor(red: 154 / 255, green: 160 / 255, blue: 174 / 255, alpha: 1)
    static let cornellPaper = UIColor(red: 1, green: 253 / 255, blue: 247 / 255, alpha: 1)

    static func step(_ template: String) -> CGFloat {
        template == "mm" ? 2.835 : (template == "grid" || template == "dotted") ? 14.17 : 24
    }

    /// Ebenen der Vorlage fuer eine Seite der Groesse `size` (Ursprung oben links). Leer bei `blank`/`nil`.
    static func layers(for template: String?, size: CGSize) -> [CALayer] {
        guard let t = template, t != "blank", size.width > 0, size.height > 0 else { return [] }
        let W = size.width, H = size.height, step = step(t)
        var out: [CALayer] = []

        if t == "cornell" {
            let paper = CALayer()
            paper.frame = CGRect(origin: .zero, size: size)
            paper.backgroundColor = cornellPaper.cgColor
            out.append(paper)
        }
        if t == "lined" || t == "cornell" {
            let p = CGMutablePath()
            var y: CGFloat = 60
            while y < H { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: W, y: y)); y += step }
            out.append(stroke(p, color: lineColor, width: 0.6))
        }
        if t == "grid" || t == "mm" {
            // Millimeterpapier: jede zehnte Linie (1 cm) kraeftiger
            let thin = CGMutablePath(), bold = CGMutablePath()
            var i = 0
            var x: CGFloat = 0
            while x < W {
                let p = t == "mm" && i % 10 == 0 ? bold : thin
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: H))
                i += 1; x = CGFloat(i) * step
            }
            i = 0
            var y: CGFloat = 0
            while y < H {
                let p = t == "mm" && i % 10 == 0 ? bold : thin
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: W, y: y))
                i += 1; y = CGFloat(i) * step
            }
            out.append(stroke(thin, color: lineColor, width: 0.5))
            if !bold.isEmpty { out.append(stroke(bold, color: lineColor, width: 1.2)) }
        }
        if t == "dotted" {
            let p = CGMutablePath()
            var x = step
            while x < W {
                var y = step
                while y < H { p.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)); y += step }
                x += step
            }
            let dots = CAShapeLayer()
            dots.path = p
            dots.fillColor = dotColor.cgColor
            dots.strokeColor = nil
            out.append(dots)
        }
        if t == "cornell" {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 150, y: 0)); p.addLine(to: CGPoint(x: 150, y: H - 150))
            p.move(to: CGPoint(x: 0, y: H - 150)); p.addLine(to: CGPoint(x: W, y: H - 150))
            out.append(stroke(p, color: cornellRuleColor, width: 1.4))
            out.append(label("Stichworte", baseline: CGPoint(x: 12, y: 22)))
            out.append(label("Notizen", baseline: CGPoint(x: 162, y: 22)))
            out.append(label("Zusammenfassung", baseline: CGPoint(x: 12, y: H - 128)))
        }
        return out
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
