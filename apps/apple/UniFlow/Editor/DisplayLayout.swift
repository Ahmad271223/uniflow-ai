import PDFKit
import UIKit
import UniFlowCore

/// Anzeige-PDF in der Seitenreihenfolge des Notizmodells (`pageOrder`), wie im Web-Editor:
/// - PDF-Seiten mit zusaetzlicher Drehung aus dem Web-Editor (`pageOrder[i].rotation`),
/// - eingefuegte Leerseiten mit Vorlage (liniert, kariert ...),
/// - Platzhalter fuer eingefuegte Bild- oder PDF-Seiten (Striche darauf werden normal gespeichert),
/// - im Browser oder hier entfernte Seiten (Papierkorb `deletedPages`, siehe `PageOrder`) fehlen auch hier.
struct DisplayLayout {
    struct Entry: Equatable {
        let key: String
        let kind: String            // pdf | blank | asset
        let template: String?
        let pdfIndex: Int?          // 1-basiert, nur pdf
        var rotation: Int = 0       // zusaetzliche Drehung aus pageOrder
    }

    let pdf: PDFDocument
    let entries: [Entry]

    func key(at index: Int) -> String? { entries.indices.contains(index) ? entries[index].key : nil }
    func index(ofKey key: String) -> Int? { entries.firstIndex { $0.key == key } }
    func entry(at index: Int) -> Entry? { entries.indices.contains(index) ? entries[index] : nil }

    /// Seitengroesse ohne die zusaetzliche Drehung aus `pageOrder` (wie `baseW`/`baseH` im Web-Editor).
    /// Groesse neuer Leerseiten nach dieser Seite.
    func baseSize(at index: Int) -> CGSize? {
        guard let entry = entry(at: index), let page = pdf.page(at: index) else { return nil }
        let shown = PageGeometry(boxSize: page.bounds(for: .cropBox).size, rotation: page.rotation).pageSize
        return entry.rotation % 180 == 0 ? shown : CGSize(width: shown.height, height: shown.width)
    }

    /// Signatur der Struktur: aendert sie sich, muss die Anzeige neu aufgebaut werden.
    static func structureSignature(_ doc: AnnotationDocument) -> String {
        JSONValue.array(doc.pageOrder).jsonString(sortedKeys: true)
    }

    static func build(original: PDFDocument, document: AnnotationDocument) -> DisplayLayout {
        var doc = document
        doc.ensurePDFPages(count: original.pageCount)
        let out = PDFDocument()
        var entries: [Entry] = []
        for p in doc.pageOrder {
            guard let key = p["key"]?.string, !entries.contains(where: { $0.key == key }) else { continue }
            let type = p["type"]?.string ?? "pdf"
            let extra = p["rotation"]?.int ?? 0
            let page: PDFPage
            var pdfIndex: Int?
            if type == "pdf" {
                guard let i = p["index"]?.int, let src = original.page(at: i - 1), let copy = src.copy() as? PDFPage else { continue }
                copy.rotation = normalized(src.rotation + extra)
                page = copy
                pdfIndex = i
            } else {
                let w = p["w"]?.double ?? 595, h = p["h"]?.double ?? 842
                let blank = PDFPage()
                let rect = CGRect(x: 0, y: 0, width: w, height: h)
                blank.setBounds(rect, for: .mediaBox)
                blank.setBounds(rect, for: .cropBox)
                blank.rotation = normalized(extra)
                page = blank
            }
            out.insert(page, at: out.pageCount)
            let template = p["template"]?.string ?? doc.page(key)?["template"]?.string
            entries.append(Entry(key: key, kind: type, template: template, pdfIndex: pdfIndex, rotation: normalized(extra)))
        }
        return DisplayLayout(pdf: out, entries: entries)
    }

    static func normalized(_ degrees: Int) -> Int { ((degrees / 90 * 90) % 360 + 360) % 360 }
}
