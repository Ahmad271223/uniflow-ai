import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Seitentexte einer Katalog-PDF mit PDFKit (iOS/macOS; unter Linux nil). Die Zeilen werden danach wie am PC
/// normalisiert (`StudyCatalogText.normalizeLines`); auf der Fixture liefern PDFKit und pypdf dieselben Zeilen.
public enum StudyCatalogPDF {
    public static func pages(_ data: Data) -> [String]? {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return nil }
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        #else
        return nil
        #endif
    }

    /// Textstuecke mit Lage je Seite fuer den Studienverlaufsplan (`StudyPlanSheet.parse`): Zeichen fuer Zeichen aus
    /// PDFKit (Rahmen im Seitenraum, dann gedreht wie /Rotate), zu Stuecken verbunden, solange sie auf einer Zeile
    /// liegen und die Luecke kleiner als eine Zeichenhoehe ist. PDFKits eigene Zeilen verbinden sonst Kaesten, die weit
    /// auseinander auf derselben Grundlinie stehen. x = linke Kante, y = senkrechte Mitte (wie `pdf_items` in Python).
    public static func planItems(_ data: Data) -> [[StudyPlanTextItem]]? {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return nil }
        return (0..<doc.pageCount).map { i in
            guard let page = doc.page(at: i) else { return [] }
            return items(page)
        }
        #else
        return nil
        #endif
    }

    #if canImport(PDFKit)
    static func items(_ page: PDFPage) -> [StudyPlanTextItem] {
        let box = page.bounds(for: .mediaBox)
        let rot = ((page.rotation % 360) + 360) % 360
        // Rahmen im Seitenraum -> (linke Kante, senkrechte Mitte, Breite, Hoehe) in Leserichtung
        func display(_ r: CGRect) -> (x: Double, y: Double, w: Double, h: Double) {
            switch rot {
            case 90: return (Double(r.minY - box.minY), Double(r.midX - box.minX), Double(r.height), Double(r.width))
            case 180: return (Double(box.maxX - r.maxX), Double(r.midY - box.minY), Double(r.width), Double(r.height))
            case 270: return (Double(box.maxY - r.maxY), Double(box.maxX - r.midX), Double(r.height), Double(r.width))
            default: return (Double(r.minX - box.minX), Double(box.maxY - r.midY), Double(r.width), Double(r.height))
            }
        }
        func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        let s = (page.string ?? "") as NSString
        var out: [StudyPlanTextItem] = []
        var cur = "", cx = 0.0, cy = 0.0, right = 0.0, ch = 0.0
        func flush() {
            let t = StudyCatalogText.normalizeLines(cur).joined(separator: " ")
            if !t.isEmpty { out.append(StudyPlanTextItem(x: round1(cx), y: round1(cy), text: t)) }
            cur = ""
        }
        var i = 0
        while i < s.length {
            let r = s.rangeOfComposedCharacterSequence(at: i)
            let c = s.substring(with: r)
            i = r.location + max(r.length, 1)
            if c.unicodeScalars.contains(where: { StudyCatalogText.breaks.contains($0.value) }) {
                flush()
                continue
            }
            let b = page.selection(for: r)?.bounds(for: page) ?? .zero
            if c.trimmingCharacters(in: .whitespaces).isEmpty || b.width <= 0 || b.height <= 0 {
                if !cur.isEmpty { cur += " " }
                continue
            }
            let d = display(b)
            let h = max(ch, d.h)
            if cur.isEmpty || abs(d.y - cy) > 0.5 * h || d.x - right > h || d.x < right - 2 * h {
                flush()
                cx = d.x
                cy = d.y
                ch = d.h
            }
            cur += c
            right = d.x + d.w
        }
        flush()
        return out
    }
    #endif
}
