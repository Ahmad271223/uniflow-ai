import Darwin
import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Haertetests fuer "PDF exportieren (privat)": alle Objektarten, Transform-Felder, gedrehte und gemischte Seiten,
/// Leerseiten mit allen Vorlagen, Papierkorb, Umfang, lange Dokumente, leeres Dokument, Abbruch, Schreibfehler und
/// Export direkt nach dem Schreiben. Geprueft wird der Inhalt der erzeugten PDF selbst: Seitenzahl, Seitengroesse
/// und Bildpunkte, gerastert mit CoreGraphics (`CGPDFPage`, unabhaengig von der Zeichenroutine des Exports).
/// Alle Testdaten sind selbst erzeugt (PDFs, Bilder, Notizen), Zufall nur mit festem Startwert.
@MainActor
final class HardeningExportTests: XCTestCase {

    // MARK: Test-PDFs

    /// Eine Seite der Test-PDF. `crop` in PDF-Koordinaten (Ursprung unten links), `rotate` = `/Rotate`.
    private struct PageSpec {
        var size: CGSize
        var rotate = 0
        var fill: UIColor?
        var crop: CGRect?
    }

    private static let a4 = CGSize(width: 595, height: 842)
    private static let a4Landscape = CGSize(width: 842, height: 595)
    private static let letter = CGSize(width: 612, height: 792)
    private static let slide = CGSize(width: 960, height: 540)

    /// Selbst erzeugte PDF: je Seite optional eine Flaechenfarbe und immer ein schwarzes Quadrat oben links
    /// (20...80 in Seitenpunkten der UNGEDREHTEN Seite, Ursprung oben links). Daran laesst sich die Drehung ablesen.
    /// Rueckgabe: Dateibytes (mit `/Rotate` und CropBox, falls angegeben).
    /// Geschrieben mit CoreGraphics und MediaBox je Seite: UIKit (`UIGraphicsBeginPDFPageWithInfo`,
    /// `UIGraphicsPDFRenderer`) ersetzt eine Seite von genau 612 x 792 (US Letter) durch die Standardgroesse des
    /// Kontexts, damit liessen sich keine echten Letter-Seiten erzeugen.
    private func makePDFData(_ specs: [PageSpec], extra: ((Int, CGSize) -> Void)? = nil) -> Data {
        let raw = NSMutableData()
        var first = CGRect(origin: .zero, size: specs.first?.size ?? Self.a4)
        let ctx = CGContext(consumer: CGDataConsumer(data: raw as CFMutableData)!, mediaBox: &first, nil)!
        for (i, s) in specs.enumerated() {
            var box = CGRect(origin: .zero, size: s.size)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.translateBy(x: 0, y: s.size.height)                    // Ursprung oben links wie UIKit
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            if let fill = s.fill {
                fill.setFill()
                UIRectFill(CGRect(origin: .zero, size: s.size))
            }
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 20, y: 20, width: 60, height: 60))
            extra?(i, s.size)
            UIGraphicsPopContext()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard specs.contains(where: { $0.rotate != 0 || $0.crop != nil }) else { return raw as Data }
        let doc = PDFDocument(data: raw as Data)!
        for (i, s) in specs.enumerated() {
            let p = doc.page(at: i)!
            p.rotation = s.rotate
            if let c = s.crop {
                p.setBounds(c, for: .cropBox)
            }
        }
        return doc.dataRepresentation()!
    }

    private func layout(pdf: Data, order: String) throws -> DisplayLayout {
        let doc = AnnotationDocument(root: try JSONValue.parse(#"{"version":2,"pages":{},"pageOrder":"# + order + "}"))
        return DisplayLayout.build(original: try XCTUnwrap(PDFDocument(data: pdf)), document: doc)
    }

    /// Nur Leerseiten (die Original-PDF wird nicht angezeigt).
    private func blankLayout(templates: [String], size: CGSize = a4) throws -> DisplayLayout {
        let entries = templates.enumerated().map { i, t in
            ##"{"key":"b\##(i)","type":"blank","template":"\##(t)","w":\##(size.width),"h":\##(size.height)}"##
        }
        return try layout(pdf: makePDFData([PageSpec(size: Self.a4)]), order: "[" + entries.joined(separator: ",") + "]")
    }

    // MARK: Notizobjekte

    private func obj(_ json: String) throws -> JSONValue { try JSONValue.parse(json) }

    private func pen(_ pts: [Double], width: Double = 8, color: String = "#000000", tool: String = "pen",
                     opacity: Double = 1, extra: String = "") throws -> JSONValue {
        let p = pts.map { String($0) }.joined(separator: ",")
        return try obj(##"{"id":"s\##(UUID().uuidString.prefix(6))","type":"stroke","tool":"\##(tool)","color":"\##(color)","width":\##(width),"opacity":\##(opacity),"points":[\##(p)],"x":0,"y":0,"rotation":0,"scaleX":1,"scaleY":1\##(extra)}"##)
    }

    private func pages(_ map: [String: [JSONValue]]) -> [String: JSONValue] {
        map.mapValues { .object(["objects": .array($0)]) }
    }

    private func solidImage(_ color: UIColor, size: CGSize = CGSize(width: 20, height: 20)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: Rastern (unabhaengig vom Export)

    /// RGBA-Bild einer PDF-Seite, Ursprung oben links, `scale` Bildpunkte je PDF-Punkt.
    private struct Raster {
        let width: Int
        let height: Int
        let scale: CGFloat
        let bytes: [UInt8]
        let size: CGSize

        func rgb(_ x: CGFloat, _ y: CGFloat) -> (r: Double, g: Double, b: Double) {
            let px = min(width - 1, max(0, Int(x * scale))), py = min(height - 1, max(0, Int(y * scale)))
            let i = (py * width + px) * 4
            return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
        }

        func brightness(_ x: CGFloat, _ y: CGFloat) -> Double {
            let c = rgb(x, y)
            return (c.r + c.g + c.b) / 3
        }

        /// Dunkelster Bildpunkt in einem Rechteck (Seitenpunkte).
        func darkest(_ r: CGRect) -> Double {
            var m = 1.0
            let x0 = max(0, Int(r.minX * scale)), x1 = min(width - 1, Int(r.maxX * scale))
            let y0 = max(0, Int(r.minY * scale)), y1 = min(height - 1, Int(r.maxY * scale))
            guard x0 <= x1, y0 <= y1 else { return 1 }
            for y in y0...y1 {
                for x in x0...x1 {
                    let i = (y * width + x) * 4
                    m = min(m, (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 765)
                }
            }
            return m
        }

        /// Anteil der Bildpunkte, die `match` erfuellen (ganze Seite).
        func fraction(_ match: (Double, Double, Double) -> Bool) -> Double {
            var n = 0
            var i = 0
            while i < bytes.count {
                if match(Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255) { n += 1 }
                i += 4
            }
            return Double(n) / Double(max(1, width * height))
        }
    }

    /// Rastert die Seite so, wie ein PDF-Betrachter sie zeigt (CropBox, `/Rotate`).
    private func raster(_ page: CGPDFPage, scale: CGFloat = 1) -> Raster {
        let box = page.getBoxRect(.cropBox)
        let rot = ((Int(page.rotationAngle) % 360) + 360) % 360
        let size = (rot == 90 || rot == 270) ? CGSize(width: box.height, height: box.width) : box.size
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.clip(to: CGRect(origin: .zero, size: size))
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0,
                                                     preserveAspectRatio: true))
            ctx.drawPDFPage(page)
        }
        return Raster(width: w, height: h, scale: scale, bytes: bytes, size: size)
    }

    private func cgDocument(_ data: Data) throws -> CGPDFDocument {
        try XCTUnwrap(CGDataProvider(data: data as CFData).flatMap { CGPDFDocument($0) }, "PDF nicht lesbar")
    }

    /// Exportierte Seite `i` (0-basiert) gerastert; Groesse = Seitengroesse wie angezeigt.
    private func exportedRaster(_ data: Data, _ i: Int, scale: CGFloat = 1) throws -> Raster {
        let doc = try cgDocument(data)
        return raster(try XCTUnwrap(doc.page(at: i + 1), "Seite \(i + 1) fehlt"), scale: scale)
    }

    private func isDark(_ v: Double) -> Bool { v < 0.35 }

    // MARK: Alle Objektarten

    /// Stift, Fueller (Breite je Punkt), Bleistift (gestrichelt), Textmarker mit Deckkraft, Text mit Schrift und
    /// Hintergrund, Haftnotiz, Formen mit und ohne Fuellung, Pfeil mit Spitze, Polygon, vorhandenes und fehlendes
    /// Bild: jedes Objekt erscheint an seiner Stelle, daneben bleibt die Seite weiss.
    func testEveryObjectKindAppearsAtItsPlace() async throws {
        let layout = try blankLayout(templates: ["blank"])
        let objects: [JSONValue] = [
            try pen([50, 50, 150, 50, 250, 50]),
            try pen([50, 90, 100, 90, 150, 90, 200, 90, 250, 90], tool: "fountain", extra: #","widths":[2,4,6,8,10]"#),
            try pen([50, 130, 250, 130], width: 5, tool: "pencil"),
            try pen([50, 180, 250, 180], width: 24, color: "#ffd400", tool: "marker", opacity: 0.5),
            try obj(##"{"type":"text","text":"Hallo Welt","x":300,"y":40,"width":220,"fontSize":24,"fontFamily":"Times New Roman","bold":true,"italic":false,"underline":true,"fill":"#000000","bg":"#9fd3ff","align":"left","lineHeight":1.25,"opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##),
            try obj(##"{"type":"text","text":"Haftnotiz: nicht vergessen","x":300,"y":120,"width":170,"fontSize":13,"fontFamily":"Arial","fill":"#1d2130","bg":"#fff7a8","opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##),
            try obj(##"{"type":"shape","shape":"rect","x":50,"y":300,"width":100,"height":60,"stroke":"#0000ff","strokeWidth":6,"fill":"#ff0000","opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##),
            try obj(##"{"type":"shape","shape":"ellipse","x":200,"y":300,"width":100,"height":60,"stroke":"","strokeWidth":2,"fill":"#00c000","opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##),
            try obj(##"{"type":"shape","shape":"triangle","x":350,"y":300,"width":100,"height":80,"stroke":"#000000","strokeWidth":2,"fill":"#0000ff","opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##),
            try obj(##"{"type":"shape","shape":"polygon","x":0,"y":0,"width":1,"height":1,"points":[50,450,150,450,100,530],"stroke":"#000000","strokeWidth":2,"fill":"#ff00ff","opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##),
            try obj(##"{"type":"shape","shape":"arrow","x":0,"y":0,"points":[200,480,400,480],"stroke":"#000000","strokeWidth":4,"fill":"","opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##),
            try obj(##"{"type":"shape","shape":"line","x":0,"y":0,"points":[450,430,550,530],"stroke":"#000000","strokeWidth":4,"fill":"#ff0000","opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##),
            try obj(##"{"type":"shape","shape":"rect","x":450,"y":300,"width":100,"height":60,"stroke":"","strokeWidth":0,"fill":"#000000","opacity":0.5,"rotation":0,"scaleX":1,"scaleY":1}"##),
            try obj(##"{"type":"image","src":"/img/rot","x":300,"y":600,"width":100,"height":100,"opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##),
            try obj(##"{"type":"image","src":"/img/fehlt","x":450,"y":600,"width":100,"height":100,"opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##),
        ]
        let red = solidImage(.red)
        let payload = try await ShareExport.make(layout: layout, scope: .document, objects: { _ in objects }, images: [:],
                                                 title: "Objekte", fileID: "f", moduleID: nil, module: nil, timeout: 5) { src in
            src == "/img/rot" ? red : nil
        }
        XCTAssertEqual(payload.missingImages, 1, "fehlendes Bild wird gemeldet")
        XCTAssertEqual(payload.missingImagesNotice, "1 Bild nicht enthalten")
        let r = try exportedRaster(payload.pdf, 0, scale: 2)
        XCTAssertEqual(r.size, Self.a4)

        // Handschrift
        XCTAssertTrue(isDark(r.darkest(CGRect(x: 145, y: 48, width: 10, height: 4))), "Stift")
        XCTAssertTrue(isDark(r.darkest(CGRect(x: 195, y: 88, width: 10, height: 4))), "Fueller")
        XCTAssertTrue(isDark(r.darkest(CGRect(x: 100, y: 128, width: 20, height: 4))), "Bleistift (gestrichelt)")
        let marker = r.rgb(150, 180)
        XCTAssertGreaterThan(marker.r, 0.85, "Marker gelb: \(marker)")
        XCTAssertLessThan(marker.b, 0.75, "Marker gelb: \(marker)")
        XCTAssertGreaterThan(marker.b, 0.2, "Marker halbtransparent, nicht deckend: \(marker)")
        XCTAssertGreaterThan(r.brightness(150, 70), 0.97, "zwischen den Strichen weiss")

        // Text mit Hintergrund und Haftnotiz
        let textBG = r.rgb(310, 44)
        XCTAssertLessThan(textBG.r, 0.75, "Texthintergrund blau: \(textBG)")
        XCTAssertGreaterThan(textBG.b, 0.9)
        XCTAssertTrue(isDark(r.darkest(CGRect(x: 304, y: 44, width: 150, height: 26))), "Text sichtbar")
        let note = r.rgb(460, 123)
        XCTAssertGreaterThan(note.r, 0.95, "Haftnotiz gelb: \(note)")
        XCTAssertLessThan(note.b, 0.8, "Haftnotiz gelb: \(note)")
        XCTAssertTrue(isDark(r.darkest(CGRect(x: 304, y: 124, width: 160, height: 16))), "Haftnotiz-Text sichtbar")

        // Formen
        let rectFill = r.rgb(100, 330), rectEdge = r.rgb(50, 330)
        XCTAssertTrue(rectFill.r > 0.9 && rectFill.g < 0.2, "Rechteck rot gefuellt: \(rectFill)")
        XCTAssertTrue(rectEdge.b > 0.8 && rectEdge.r < 0.3, "Rechteck blauer Rand: \(rectEdge)")
        let ellipse = r.rgb(250, 330)
        XCTAssertTrue(ellipse.g > 0.6 && ellipse.r < 0.2, "Ellipse gruen: \(ellipse)")
        XCTAssertGreaterThan(r.brightness(203, 303), 0.97, "Ecke ausserhalb der Ellipse weiss")
        let triangle = r.rgb(400, 365)
        XCTAssertTrue(triangle.b > 0.8 && triangle.r < 0.2, "Dreieck blau: \(triangle)")
        XCTAssertGreaterThan(r.brightness(356, 306), 0.97, "Ecke ausserhalb des Dreiecks weiss")
        let polygon = r.rgb(100, 475)
        XCTAssertTrue(polygon.r > 0.8 && polygon.b > 0.8 && polygon.g < 0.4, "Polygon magenta: \(polygon)")
        XCTAssertTrue(isDark(r.darkest(CGRect(x: 300, y: 479, width: 4, height: 2))), "Pfeil-Linie")
        XCTAssertTrue(isDark(r.darkest(CGRect(x: 389, y: 484.5, width: 2, height: 1))), "Pfeilspitze breiter als die Linie")
        XCTAssertGreaterThan(r.brightness(300, 486), 0.97, "neben der Pfeil-Linie weiss")
        XCTAssertTrue(isDark(r.darkest(CGRect(x: 498, y: 478, width: 4, height: 4))), "Linie")
        XCTAssertGreaterThan(r.rgb(520, 470).g, 0.97, "offene Linie wird nicht gefuellt")
        let half = r.brightness(500, 330)
        XCTAssertTrue(half > 0.35 && half < 0.65, "Deckkraft 0,5 ergibt Grau: \(half)")

        // Bilder
        let img = r.rgb(350, 650)
        XCTAssertTrue(img.r > 0.9 && img.g < 0.2, "vorhandenes Bild an seiner Stelle: \(img)")
        XCTAssertGreaterThan(r.darkest(CGRect(x: 455, y: 605, width: 90, height: 90)), 0.97, "fehlendes Bild: nichts gezeichnet")
    }

    /// Alle Schriften des Web-Editors (auch solche, die es auf dem iPad nicht gibt) mit Fett/Kursiv/Unterstrichen:
    /// jede Zeile wird lesbar gezeichnet, keine faellt still weg.
    func testAllEditorFontsAreDrawn() throws {
        let fonts = ["Arial", "Helvetica", "Segoe UI", "Verdana", "Georgia", "Times New Roman", "Courier New",
                     "Comic Sans MS", "Cambria Math"]
        let objects = try fonts.enumerated().map { i, f in
            try obj(##"{"type":"text","text":"Wxyz \##(f)","x":40,"y":\##(40 + i * 60),"width":400,"fontSize":22,"fontFamily":"\##(f)","bold":\##(i % 2 == 0),"italic":\##(i % 3 == 0),"underline":\##(i % 4 == 0),"fill":"#000000","bg":"","opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##)
        }
        let layout = try blankLayout(templates: ["blank"])
        let data = PDFExporter.render(layout: layout, pages: pages(["b0": objects]), images: [:])
        let r = try exportedRaster(data, 0, scale: 2)
        for (i, f) in fonts.enumerated() {
            let y = CGFloat(40 + i * 60)
            XCTAssertTrue(isDark(r.darkest(CGRect(x: 44, y: y + 4, width: 200, height: 30))), "Schrift \(f) fehlt im Export")
        }
    }

    // MARK: Transform-Felder

    /// x, y, rotation (Grad, im Uhrzeigersinn), scaleX/scaleY fuer Form, Strich, Text und Bild: verschieben ->
    /// drehen -> skalieren wie Konva. Geprueft an Stellen, an denen ohne Drehung bzw. Skalierung nichts laege.
    func testTransformFieldsForEveryKind() throws {
        let layout = try blankLayout(templates: ["blank"])
        let objects: [JSONValue] = [
            // Rechteck 100 x 50 bei (100,100), 90 Grad, doppelt: liegt bei x 0...100, y 100...300
            try obj(##"{"type":"shape","shape":"rect","x":100,"y":100,"width":100,"height":50,"stroke":"","fill":"#ff0000","opacity":1,"rotation":90,"scaleX":2,"scaleY":2}"##),
            // Strich (0,0)-(50,0) bei (300,100), 90 Grad, doppelt: von (300,100) nach (300,200)
            try obj(##"{"type":"stroke","tool":"pen","color":"#000000","width":4,"opacity":1,"points":[0,0,50,0],"x":300,"y":100,"rotation":90,"scaleX":2,"scaleY":2}"##),
            // Text mit schwarzem Hintergrund, 180 Grad um (500,300): Kasten liegt links oberhalb des Ankers
            try obj(##"{"type":"text","text":"MMMM","x":500,"y":300,"width":100,"fontSize":14,"fontFamily":"Arial","fill":"#ffffff","bg":"#000000","opacity":1,"rotation":180,"scaleX":1,"scaleY":1}"##),
            // Bild 50 x 100 bei (100,500), scaleX 2, scaleY 0,5: x 100...200, y 500...550
            try obj(##"{"type":"image","src":"/b","x":100,"y":500,"width":50,"height":100,"opacity":1,"rotation":0,"scaleX":2,"scaleY":0.5}"##),
            // gespiegelter Strich (scaleX -1): (0,0)-(80,0) bei (500,600) -> von 500 nach 420
            try obj(##"{"type":"stroke","tool":"pen","color":"#000000","width":6,"opacity":1,"points":[0,0,80,0],"x":500,"y":600,"rotation":0,"scaleX":-1,"scaleY":1}"##),
        ]
        let data = PDFExporter.render(layout: layout, pages: pages(["b0": objects]), images: ["/b": solidImage(.red)])
        let r = try exportedRaster(data, 0, scale: 2)
        let rect = r.rgb(50, 200)
        XCTAssertTrue(rect.r > 0.9 && rect.g < 0.2, "gedrehtes, skaliertes Rechteck: \(rect)")
        XCTAssertGreaterThan(r.brightness(150, 125), 0.97, "ungedrehte Lage bleibt leer")
        XCTAssertTrue(isDark(r.darkest(CGRect(x: 298, y: 190, width: 4, height: 4))), "gedrehter Strich reicht bis y=200")
        XCTAssertGreaterThan(r.darkest(CGRect(x: 330, y: 96, width: 60, height: 8)), 0.97, "ungedrehter Strich laege hier")
        XCTAssertTrue(isDark(r.darkest(CGRect(x: 440, y: 290, width: 4, height: 4))), "Text-Kasten um 180 Grad gedreht")
        XCTAssertGreaterThan(r.darkest(CGRect(x: 510, y: 305, width: 60, height: 10)), 0.97, "ungedreht laege er hier")
        let img = r.rgb(180, 520)
        XCTAssertTrue(img.r > 0.9 && img.g < 0.2, "skaliertes Bild: \(img)")
        XCTAssertGreaterThan(r.brightness(120, 580), 0.97, "scaleY 0,5: unterer Teil leer")
        XCTAssertTrue(isDark(r.darkest(CGRect(x: 440, y: 598, width: 4, height: 4))), "gespiegelter Strich nach links")
        XCTAssertGreaterThan(r.darkest(CGRect(x: 520, y: 596, width: 40, height: 8)), 0.97)
    }

    // MARK: Gedrehte Seiten

    /// `/Rotate` 0/90/180/270 der Original-PDF und zusaetzliche Drehung aus `pageOrder`: Seitengroesse wie
    /// angezeigt, Original-Inhalt so gedreht wie im Editor (schwarzes Quadrat), Notizen in Anzeige-Koordinaten.
    func testRotatedPagesExportAsDisplayed() throws {
        let pdf = makePDFData([PageSpec(size: Self.a4), PageSpec(size: Self.a4, rotate: 90),
                               PageSpec(size: Self.a4, rotate: 180), PageSpec(size: Self.a4, rotate: 270),
                               PageSpec(size: Self.a4, rotate: 90)])
        let lay = try layout(pdf: pdf, order: #"""
        [{"key":"p1","type":"pdf","index":1,"rotation":90},{"key":"p2","type":"pdf","index":2},
         {"key":"p3","type":"pdf","index":3},{"key":"p4","type":"pdf","index":4},
         {"key":"p5","type":"pdf","index":5,"rotation":270}]
        """#)
        // angezeigte Drehung je Seite und erwartete Lage des Quadrats (Mitte) in Anzeige-Koordinaten
        let shown = [90, 90, 180, 270, 0]
        func squareCenter(_ rot: Int) -> CGPoint {
            switch rot {
            case 90: return CGPoint(x: 842 - 50, y: 50)        // oben rechts
            case 180: return CGPoint(x: 595 - 50, y: 842 - 50) // unten rechts
            case 270: return CGPoint(x: 50, y: 595 - 50)       // unten links
            default: return CGPoint(x: 50, y: 50)
            }
        }
        var notes: [String: [JSONValue]] = [:]
        for (i, rot) in shown.enumerated() {
            let size = rot % 180 == 0 ? Self.a4 : Self.a4Landscape
            // Strich unten rechts (Anzeige-Koordinaten), dort liegt bei keiner Drehung das Quadrat
            notes["p\(i + 1)"] = [try pen([Double(size.width) - 160, Double(size.height) - 120,
                                           Double(size.width) - 120, Double(size.height) - 120])]
        }
        let data = PDFExporter.render(layout: lay, pages: pages(notes), images: [:])
        XCTAssertEqual(try cgDocument(data).numberOfPages, 5)
        for (i, rot) in shown.enumerated() {
            let r = try exportedRaster(data, i)
            let size = rot % 180 == 0 ? Self.a4 : Self.a4Landscape
            XCTAssertEqual(r.size, size, "Seite \(i + 1): Groesse wie angezeigt")
            let c = squareCenter(rot)
            XCTAssertLessThan(r.brightness(c.x, c.y), 0.1, "Seite \(i + 1) (\(rot) Grad): Original-Inhalt gedreht wie angezeigt")
            for other in [0, 90, 180, 270] where squareCenter(other) != c {
                let o = squareCenter(other)
                if o.x < size.width, o.y < size.height {
                    XCTAssertGreaterThan(r.brightness(o.x, o.y), 0.9, "Seite \(i + 1): Quadrat nicht bei \(other) Grad")
                }
            }
            XCTAssertTrue(isDark(r.darkest(CGRect(x: size.width - 142, y: size.height - 122, width: 4, height: 4))),
                          "Seite \(i + 1): Strich an seiner Stelle")
        }
    }

    // MARK: Gemischte Seitengroessen

    /// A4 hoch und quer, Letter, Folie 16:9 und eine Folie mit verschobener CropBox: jede Seite behaelt ihre
    /// angezeigte Groesse, Original und Notizen liegen deckungsgleich.
    func testMixedPageSizesKeepSizeAndPosition() throws {
        let crop = CGRect(x: 40, y: 30, width: 880, height: 480)
        let pdf = makePDFData([PageSpec(size: Self.a4), PageSpec(size: Self.a4Landscape), PageSpec(size: Self.letter),
                               PageSpec(size: Self.slide), PageSpec(size: Self.slide, crop: crop)])
        let lay = try layout(pdf: pdf, order: "[]")
        let sizes = [Self.a4, Self.a4Landscape, Self.letter, Self.slide, crop.size]
        var notes: [String: [JSONValue]] = [:]
        for (i, s) in sizes.enumerated() {
            // Strich bei 90 % Breite / 90 % Hoehe
            notes["p\(i + 1)"] = [try pen([Double(s.width) * 0.9 - 20, Double(s.height) * 0.9, Double(s.width) * 0.9 + 20,
                                           Double(s.height) * 0.9])]
        }
        let data = PDFExporter.render(layout: lay, pages: pages(notes), images: [:])
        let doc = try cgDocument(data)
        XCTAssertEqual(doc.numberOfPages, 5)
        for (i, s) in sizes.enumerated() {
            let r = try exportedRaster(data, i)
            XCTAssertEqual(r.size.width, s.width, accuracy: 0.5, "Seite \(i + 1) Breite")
            XCTAssertEqual(r.size.height, s.height, accuracy: 0.5, "Seite \(i + 1) Hoehe")
            XCTAssertTrue(isDark(r.darkest(CGRect(x: s.width * 0.9 - 2, y: s.height * 0.9 - 2, width: 4, height: 4))),
                          "Seite \(i + 1): Strich bei 90 %")
            if i < 4 {
                XCTAssertLessThan(r.brightness(50, 50), 0.1, "Seite \(i + 1): Original oben links")
            }
        }
        // CropBox (40,30) verschoben: das Quadrat (PDF x 20...80, y 460...520) ist nur zum Teil sichtbar, oben links
        let cropped = try exportedRaster(data, 4)
        XCTAssertLessThan(cropped.brightness(20, 25), 0.1, "sichtbarer Teil des Quadrats an der Ecke der CropBox")
        XCTAssertGreaterThan(cropped.brightness(60, 25), 0.9, "rechts davon weiss (Quadrat endet bei x = 40)")
        XCTAssertGreaterThan(cropped.brightness(20, 70), 0.9, "darunter weiss (Quadrat endet bei y = 50)")
    }

    // MARK: Leerseiten mit allen Vorlagen

    /// Alle Vorlagen (leer, liniert, kariert, gepunktet, Millimeter, Cornell) als eingefuegte Leerseiten:
    /// weisse Seite mit den Linien an den Stellen von drawTemplatePdf, Notizen darauf sichtbar.
    func testBlankPagesWithAllTemplates() throws {
        XCTAssertEqual(PageOrder.templates, ["blank", "lined", "grid", "dotted", "mm", "cornell"])
        let lay = try blankLayout(templates: PageOrder.templates)
        var notes: [String: [JSONValue]] = [:]
        for i in PageOrder.templates.indices { notes["b\(i)"] = [try pen([400, 700, 500, 700])] }
        let data = PDFExporter.render(layout: lay, pages: pages(notes), images: [:])
        XCTAssertEqual(try cgDocument(data).numberOfPages, 6)
        let rs = try (0..<6).map { try exportedRaster(data, $0, scale: 4) }
        for (i, r) in rs.enumerated() {
            XCTAssertEqual(r.size, Self.a4)
            XCTAssertTrue(isDark(r.darkest(CGRect(x: 448, y: 698, width: 4, height: 4))), "Vorlage \(PageOrder.templates[i]): Strich")
            XCTAssertGreaterThan(r.fraction { $0 > 0.97 && $1 > 0.97 && $2 > 0.97 }, 0.5, "Seite bleibt ueberwiegend weiss")
        }
        let line = 0.97
        // leer: nur der Strich
        XCTAssertGreaterThan(rs[0].darkest(CGRect(x: 0, y: 0, width: 595, height: 680)), 0.99, "leer")
        // liniert: Linie bei y = 60, dazwischen weiss
        XCTAssertLessThan(rs[1].darkest(CGRect(x: 290, y: 59.8, width: 20, height: 0.4)), line, "liniert: Linie bei 60")
        XCTAssertGreaterThan(rs[1].darkest(CGRect(x: 290, y: 66, width: 20, height: 12)), 0.99, "liniert: zwischen den Linien")
        XCTAssertGreaterThan(rs[1].darkest(CGRect(x: 290, y: 10, width: 20, height: 40)), 0.99, "liniert: Rand oben frei")
        // kariert: senkrechte Linie bei 2 * 14,17
        XCTAssertLessThan(rs[2].darkest(CGRect(x: 28.2, y: 102, width: 0.3, height: 8)), line, "kariert: senkrechte Linie")
        XCTAssertGreaterThan(rs[2].darkest(CGRect(x: 31, y: 102, width: 8, height: 8)), 0.99, "kariert: Kaestchen frei")
        // gepunktet: Punkt bei (3 * 14,17, 3 * 14,17), dazwischen frei
        XCTAssertLessThan(rs[3].darkest(CGRect(x: 42.3, y: 42.3, width: 0.4, height: 0.4)), line, "gepunktet: Punkt")
        XCTAssertGreaterThan(rs[3].darkest(CGRect(x: 46, y: 46, width: 6, height: 6)), 0.99, "gepunktet: zwischen den Punkten")
        // Millimeter: Linie bei 10 * 2,835
        XCTAssertLessThan(rs[4].darkest(CGRect(x: 28.25, y: 300, width: 0.2, height: 0.2)), line, "Millimeter: Linie")
        // Cornell: Trennlinie bei x = 150 und Fusszeile bei H - 150
        XCTAssertLessThan(rs[5].darkest(CGRect(x: 149.8, y: 100, width: 0.4, height: 5)), line, "Cornell: Trennlinie")
        XCTAssertLessThan(rs[5].darkest(CGRect(x: 300, y: 691.8, width: 5, height: 0.4)), line, "Cornell: Fusszeile")
        XCTAssertGreaterThan(rs[5].darkest(CGRect(x: 160, y: 10, width: 40, height: 40)), 0.99, "Cornell: oben frei")
    }

    // MARK: Papierkorb und Umfang (ueber den echten DocumentStore)

    /// Eigenes Dokument im lokalen Backend (Temp-Ordner) mit selbst erzeugter Original-PDF.
    private func makeStore(pdf: Data, pageCount: Int) async throws -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("haerte-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-25T14:30:05")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "export-test-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdfDirectory(api.namespace, root: root).appendingPathComponent(fileID + ".pdf")
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Blatt.pdf", title: "Blatt", kind: "pdf", module_id: nil, subject: "Analysis",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-10-25", has_notes: nil,
                           page_count: pageCount, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        return store
    }

    /// Zeichnung wie von der PencilKit-Canvas: waagrechte Striche in Seitenpunkten.
    private func drawing(_ lines: [(x0: CGFloat, x1: CGFloat, y: CGFloat)], width: CGFloat = 8) -> PKDrawing {
        let strokes = lines.map { l -> PKStroke in
            let n = 12
            let pts = (0..<n).map { i in
                PKStrokePoint(location: CGPoint(x: l.x0 + (l.x1 - l.x0) * CGFloat(i) / CGFloat(n - 1), y: l.y),
                              timeOffset: Double(i) * 0.01, size: CGSize(width: width, height: width), opacity: 1, force: 1,
                              azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
        }
        return PKDrawing(strokes: strokes)
    }

    private func pastel(_ i: Int) -> UIColor {
        [UIColor(red: 1, green: 0.8, blue: 0.8, alpha: 1), UIColor(red: 0.8, green: 1, blue: 0.8, alpha: 1),
         UIColor(red: 0.8, green: 0.8, blue: 1, alpha: 1)][i % 3]
    }

    /// Welche Original-Seite ist das? (Flaechenfarbe in der Seitenmitte: 0 rot, 1 gruen, 2 blau, nil weiss)
    private func pageColor(_ r: Raster) -> Int? {
        let c = r.rgb(r.size.width / 2, r.size.height / 2 + 80)
        if c.r > 0.97, c.g > 0.97, c.b > 0.97 { return nil }
        if c.r > c.g + 0.1, c.r > c.b + 0.1 { return 0 }
        if c.g > c.r + 0.1, c.g > c.b + 0.1 { return 1 }
        if c.b > c.r + 0.1, c.b > c.g + 0.1 { return 2 }
        return -1
    }

    /// Papierkorb-Seiten (PDF- und Leerseite) fehlen im Export samt ihren Notizen; eingefuegte Leerseiten mit
    /// Vorlage sind dabei. "Ganzes Dokument" und "Diese Seite" zaehlen nach der angezeigten Reihenfolge.
    func testTrashedPagesAreNotExportedAndScopeFollowsDisplayOrder() async throws {
        let pdf = makePDFData((0..<3).map { PageSpec(size: Self.a4, fill: pastel($0)) })
        let store = try await makeStore(pdf: pdf, pageCount: 3)
        await store.addBlankPage(afterKey: "p1", template: "lined")
        await store.addBlankPage(afterKey: "p3", template: "grid")
        let keys = try XCTUnwrap(store.layout?.entries.map(\.key))
        XCTAssertEqual(keys.count, 5)
        let blankA = keys[1], blankB = keys[4]
        XCTAssertEqual(keys[0], "p1")
        XCTAssertEqual(keys[2], "p2")
        // Striche: auf jeder Seite an eigener Hoehe, damit man sie unterscheiden kann
        for (i, key) in keys.enumerated() {
            store.canvasChanged(pageKey: key, drawing: drawing([(100, 300, CGFloat(200 + i * 40))]))
        }
        await store.flush()
        // PDF-Seite 2 und die zweite Leerseite in den Papierkorb
        for key in ["p2", blankB] {
            let change = await store.applyPageStructure { doc in PageOrder.trash(&doc, key: key) }
            XCTAssertNotNil(change, "Papierkorb \(key)")
        }
        XCTAssertEqual(store.layout?.entries.map(\.key), ["p1", blankA, "p3"])

        let all = try await store.sharePayload(.document, loadImage: nil)
        XCTAssertEqual(all.pageRange, 1...3)
        let doc = try cgDocument(all.pdf)
        XCTAssertEqual(doc.numberOfPages, 3, "Papierkorb-Seiten nicht im Export")
        let rs = try (0..<3).map { try exportedRaster(all.pdf, $0) }
        XCTAssertEqual(rs.map { pageColor($0) }, [0, nil, 2], "Reihenfolge p1, Leerseite, p3 (ohne p2)")
        // Striche: p1 bei y 200, Leerseite bei 240, p3 bei 320; die der Papierkorb-Seiten (280, 360) nirgends
        let expectedY: [CGFloat] = [200, 240, 320]
        for (i, r) in rs.enumerated() {
            XCTAssertTrue(isDark(r.darkest(CGRect(x: 198, y: expectedY[i] - 2, width: 4, height: 4))), "Seite \(i + 1): eigener Strich")
            for y in [CGFloat(280), 360] {
                XCTAssertGreaterThan(r.darkest(CGRect(x: 150, y: y - 3, width: 100, height: 6)), 0.5,
                                     "Seite \(i + 1): Strich einer Papierkorb-Seite (y \(y)) darf nicht erscheinen")
            }
        }
        XCTAssertLessThan(rs[1].darkest(CGRect(x: 400, y: 59.5, width: 20, height: 1)), 0.97, "Leerseite liniert")

        // Diese Seite: angezeigte Seite 2 ist die Leerseite, angezeigte Seite 3 ist PDF-Seite 3
        let blank = try await store.sharePayload(.page(1), loadImage: nil)
        XCTAssertEqual(blank.pageRange, 2...2)
        XCTAssertEqual(try cgDocument(blank.pdf).numberOfPages, 1)
        let br = try exportedRaster(blank.pdf, 0)
        XCTAssertNil(pageColor(br), "Leerseite weiss")
        XCTAssertTrue(isDark(br.darkest(CGRect(x: 198, y: 238, width: 4, height: 4))))
        let third = try await store.sharePayload(.page(2), loadImage: nil)
        XCTAssertEqual(third.pageRange, 3...3)
        XCTAssertEqual(pageColor(try exportedRaster(third.pdf, 0)), 2, "PDF-Seite 3")
        do {
            _ = try await store.sharePayload(.page(3), loadImage: nil)
            XCTFail("Seite 4 gibt es nach dem Papierkorb nicht mehr")
        } catch {
            XCTAssertEqual(error as? ShareExportError, .pageOutOfRange(3))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        await store.close()
    }

    /// "Diese Seite" fuer jede Seite eines gemischten Dokuments: genau eine Seite, Groesse und Inhalt dieser Seite,
    /// keine Notizen anderer Seiten.
    func testThisPageForEveryPageOfMixedDocument() throws {
        let pdf = makePDFData([PageSpec(size: Self.a4), PageSpec(size: Self.slide, rotate: 90), PageSpec(size: Self.letter)])
        let lay = try layout(pdf: pdf, order: #"""
        [{"key":"p1","type":"pdf","index":1},{"key":"bX","type":"blank","template":"dotted","w":842,"h":595},
         {"key":"p2","type":"pdf","index":2},{"key":"p3","type":"pdf","index":3,"rotation":180}]
        """#)
        let expected = [Self.a4, Self.a4Landscape, CGSize(width: 540, height: 960), Self.letter]
        var notes: [String: [JSONValue]] = [:]
        for (i, key) in ["p1", "bX", "p2", "p3"].enumerated() {
            notes[key] = [try pen([100, Double(150 + i * 50), 200, Double(150 + i * 50)])]
        }
        for i in 0..<4 {
            let p = try ShareExport.payload(layout: lay, pages: pages(notes), images: [:], title: "Mix", fileID: "f",
                                            moduleID: nil, module: nil, scope: .page(i))
            XCTAssertEqual(p.pageRange, (i + 1)...(i + 1))
            XCTAssertEqual(try cgDocument(p.pdf).numberOfPages, 1)
            let r = try exportedRaster(p.pdf, 0)
            XCTAssertEqual(r.size, expected[i], "Seite \(i + 1): Groesse")
            for j in 0..<4 {
                let dark = isDark(r.darkest(CGRect(x: 148, y: CGFloat(148 + j * 50), width: 4, height: 4)))
                XCTAssertEqual(dark, i == j, "Seite \(i + 1): Strich der Seite \(j + 1) \(i == j ? "fehlt" : "falsch enthalten")")
            }
        }
        let whole = try ShareExport.payload(layout: lay, pages: pages(notes), images: [:], title: "Mix", fileID: "f",
                                            moduleID: nil, module: nil, scope: .document)
        let doc = try cgDocument(whole.pdf)
        XCTAssertEqual(doc.numberOfPages, 4)
        XCTAssertEqual(whole.pageRange, 1...4)
        for i in 0..<4 {
            XCTAssertEqual(try exportedRaster(whole.pdf, i).size, expected[i], "Ganzes Dokument, Seite \(i + 1)")
        }
    }

    // MARK: Lange Dokumente

    private final class PeakMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var running = true

        static func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return kr == KERN_SUCCESS ? info.phys_footprint : 0
        }

        func start() {
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock()
                    let go = running
                    peak = max(peak, Self.footprint())
                    lock.unlock()
                    if !go { return }
                    usleep(5_000)
                }
            }
        }

        func stop() -> UInt64 {
            lock.lock()
            running = false
            peak = max(peak, Self.footprint())
            defer { lock.unlock() }
            return peak
        }
    }

    /// Deterministischer Zufall (SplitMix64) fuer Stichproben.
    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 150 Seiten mit Handschrift (Breite je Punkt), Text und alle 10 Seiten ein Textmarker: Export in kurzer Zeit,
    /// ohne Seitenbilder (nur Vektoren), Spitzenspeicher begrenzt, Stichproben an der richtigen Stelle.
    func testLongDocument150PagesTimeMemoryAndContent() async throws {
        let n = 150
        let pdf = makePDFData((0..<n).map { PageSpec(size: $0 % 7 == 3 ? Self.a4Landscape : Self.a4) }) { i, size in
            let text = "Vorlesung Seite \(i + 1) – Satz \(i * 7 % 13)" as NSString
            text.draw(at: CGPoint(x: 100, y: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            UIColor(white: 0.85, alpha: 1).setFill()
            UIRectFill(CGRect(x: 100, y: size.height - 200, width: 200, height: 40))
        }
        let lay = try layout(pdf: pdf, order: "[]")
        XCTAssertEqual(lay.entries.count, n)
        var notes: [String: [JSONValue]] = [:]
        for i in 0..<n {
            let y = Double(300 + (i % 20) * 10)
            var list: [JSONValue] = []
            var pts: [Double] = []
            for k in 0..<40 {
                let dy: Double = k % 2 == 0 ? 0 : 3
                pts.append(100 + Double(k) * 8)
                pts.append(y + dy)
            }
            let widths = (0..<40).map { String(2 + Double($0 % 5)) }.joined(separator: ",")
            list.append(try pen(pts, width: 4, extra: #","widths":[\#(widths)]"#))
            list.append(try obj(##"{"type":"text","text":"Notiz \##(i + 1)","x":350,"y":60,"width":200,"fontSize":14,"fontFamily":"Arial","fill":"#1d2130","bg":"","opacity":1,"rotation":0,"scaleX":1,"scaleY":1}"##))
            if i % 10 == 0 { list.append(try pen([100, 250, 400, 250], width: 20, color: "#ffd400", tool: "marker", opacity: 0.4)) }
            notes["p\(i + 1)"] = list
        }
        let objects = notes
        let before = PeakMemory.footprint()
        let peak = PeakMemory()
        peak.start()
        let start = Date()
        let payload = try await ShareExport.make(layout: lay, scope: .document, objects: { objects[$0] ?? [] }, images: [:],
                                                 title: "Langes Skript", fileID: "f", moduleID: nil, module: nil,
                                                 timeout: 1, loadImage: nil)
        let seconds = Date().timeIntervalSince(start)
        let top = peak.stop()
        let growthMB = Double(top > before ? top - before : 0) / 1_048_576
        print("150 Seiten: \(String(format: "%.2f", seconds)) s, PDF \(payload.pdf.count / 1024) KB, Spitzenzuwachs \(String(format: "%.1f", growthMB)) MB")
        XCTAssertLessThan(seconds, 15, "Export von 150 Seiten dauert zu lange")
        XCTAssertLessThan(growthMB, 250, "Spitzenspeicher waehrend des Exports zu hoch")
        XCTAssertLessThan(payload.pdf.count, 30 * 1_048_576, "PDF unverhaeltnismaessig gross")
        XCTAssertEqual(payload.pageRange, 1...n)
        let doc = try cgDocument(payload.pdf)
        XCTAssertEqual(doc.numberOfPages, n)
        // keine Seitenbilder: weder auf der Seite noch in Formularen (Transparenzgruppen)
        for i in [0, 3, 10, 77, 149] {
            XCTAssertEqual(imageXObjects(try XCTUnwrap(doc.page(at: i + 1))), 0, "Seite \(i + 1) enthaelt ein Bild")
        }
        var rng = SeededRandom(state: 42)
        for _ in 0..<6 {
            let i = Int.random(in: 0..<n, using: &rng)
            let r = raster(try XCTUnwrap(doc.page(at: i + 1)))
            let size = i % 7 == 3 ? Self.a4Landscape : Self.a4
            XCTAssertEqual(r.size, size, "Seite \(i + 1)")
            let y = CGFloat(300 + (i % 20) * 10)
            XCTAssertTrue(isDark(r.darkest(CGRect(x: 200, y: y - 2, width: 8, height: 7))), "Seite \(i + 1): Strich")
            XCTAssertLessThan(r.brightness(50, 50), 0.1, "Seite \(i + 1): Original")
        }
    }

    /// Anzahl der Bild-XObjects einer Seite, auch in eingebundenen Formularen.
    private func imageXObjects(_ page: CGPDFPage) -> Int {
        final class Box { var n = 0 }
        let box = Box()
        func scan(_ res: CGPDFDictionaryRef?, depth: Int) {
            guard let res, depth < 4 else { return }
            var xo: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(res, "XObject", &xo), let xo else { return }
            var streams: [CGPDFStreamRef] = []
            withUnsafeMutablePointer(to: &streams) { ptr in
                CGPDFDictionaryApplyFunction(xo, { _, obj, info in
                    var st: CGPDFStreamRef?
                    if CGPDFObjectGetValue(obj, .stream, &st), let st {
                        info!.assumingMemoryBound(to: [CGPDFStreamRef].self).pointee.append(st)
                    }
                }, ptr)
            }
            for st in streams {
                guard let d = CGPDFStreamGetDictionary(st) else { continue }
                var name: UnsafePointer<CChar>?
                CGPDFDictionaryGetName(d, "Subtype", &name)
                let subtype = name.map { String(cString: $0) } ?? ""
                if subtype == "Image" { box.n += 1 }
                if subtype == "Form" {
                    var formRes: CGPDFDictionaryRef?
                    CGPDFDictionaryGetDictionary(d, "Resources", &formRes)
                    scan(formRes, depth: depth + 1)
                }
            }
        }
        var res: CGPDFDictionaryRef?
        if let dict = page.dictionary, CGPDFDictionaryGetDictionary(dict, "Resources", &res) { scan(res, depth: 0) }
        return box.n
    }

    // MARK: Leeres Dokument

    /// Dokument ohne eigene Notizen: der Export ist die Original-PDF (alle Seiten, gleiche Groesse und Inhalt).
    /// Ein Seitenaufbau ohne Seiten liefert eine klare Meldung statt einer leeren oder kaputten Datei.
    func testDocumentWithoutNotesAndEmptyLayout() throws {
        let pdf = makePDFData([PageSpec(size: Self.a4, fill: pastel(1)), PageSpec(size: Self.slide)])
        let lay = try layout(pdf: pdf, order: "[]")
        let p = try ShareExport.payload(layout: lay, pages: [:], images: [:], title: "Ohne Notizen", fileID: "f",
                                        moduleID: nil, module: nil, scope: .document)
        XCTAssertEqual(try cgDocument(p.pdf).numberOfPages, 2)
        let r0 = try exportedRaster(p.pdf, 0), r1 = try exportedRaster(p.pdf, 1)
        XCTAssertEqual(r0.size, Self.a4)
        XCTAssertEqual(r1.size, Self.slide)
        XCTAssertEqual(pageColor(r0), 1)
        XCTAssertLessThan(r1.brightness(50, 50), 0.1)
        XCTAssertGreaterThan(r1.darkest(CGRect(x: 100, y: 100, width: 800, height: 400)), 0.99, "keine fremden Striche")

        let empty = DisplayLayout(pdf: PDFDocument(), entries: [])
        XCTAssertThrowsError(try ShareExport.payload(layout: empty, pages: [:], images: [:], title: "Leer", fileID: "f",
                                                     moduleID: nil, module: nil, scope: .document)) { error in
            XCTAssertNotNil(error as? ShareExportError)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertThrowsError(try ShareExport.payload(layout: empty, pages: [:], images: [:], title: "Leer", fileID: "f",
                                                     moduleID: nil, module: nil, scope: .page(0)))
    }

    // MARK: Abbruch

    /// Wird der Export abgebrochen, waehrend Bilder nachgeladen werden, endet er sofort (nicht erst nach dem
    /// Zeitlimit) und meldet entweder den Abbruch oder ehrlich das fehlende Bild.
    func testCancelledExportEndsPromptlyAndHonestly() async throws {
        let lay = try blankLayout(templates: ["lined", "grid"])
        let image = try obj(##"{"type":"image","src":"/img/langsam","x":10,"y":10,"width":50,"height":50,"rotation":0,"scaleX":1,"scaleY":1}"##)
        let task = Task { @MainActor in
            try await ShareExport.make(layout: lay, scope: .document, objects: { _ in [image] }, images: [:], title: "Abbruch",
                                       fileID: "f", moduleID: nil, module: nil, timeout: 20) { _ in
                try? await Task.sleep(nanoseconds: 30_000_000_000)          // endet beim Abbruch sofort
                return nil
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let start = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "Abbruch wartet nicht auf das Zeitlimit")
        switch result {
        case .success(let payload):
            XCTAssertEqual(payload.missingImages, 1, "nicht geladenes Bild wird nicht als vorhanden ausgegeben")
            XCTAssertEqual(try cgDocument(payload.pdf).numberOfPages, 2)
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "unerwarteter Fehler: \(error)")
        }
    }

    // MARK: Schreibfehler

    private func setPermissions(_ url: URL, _ mode: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func files(under url: URL) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { ($0 as? URL)?.path }.filter { !$0.hasSuffix("/alt") && !$0.hasSuffix("/alt/alte.pdf") }
    }

    /// Schreibgeschuetzter Teilen-Ordner: klare Meldung (kein roher Fehlercode), keine halbe Datei.
    func testWriteFileIntoReadOnlyFolderFailsCleanly() throws {
        let lay = try blankLayout(templates: ["lined"])
        let p = try ShareExport.payload(layout: lay, pages: [:], images: [:], title: "Schreibschutz", fileID: "f",
                                        moduleID: nil, module: nil, scope: .document)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? fm.removeItem(at: root)
        let old = root.appendingPathComponent("alt", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("%PDF-alt".utf8).write(to: old.appendingPathComponent("alte.pdf"))
        setPermissions(old, 0o555)
        setPermissions(root, 0o555)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertThrowsError(try ShareExport.writeFile(p)) { error in
            let text = error.localizedDescription
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("Domain="), "roher Fehlertext: \(text)")
            XCTAssertFalse(text.contains("error 513"), "roher Fehlertext: \(text)")
        }
        XCTAssertEqual(files(under: root), [], "keine neue (halbe) Datei")

        // danach wieder beschreibbar: Export klappt erneut
        setPermissions(root, 0o755)
        setPermissions(old, 0o755)
        let url = try ShareExport.writeFile(p)
        XCTAssertEqual(try Data(contentsOf: url), p.pdf)
    }

    /// `PDFExporter.export`: Ziel nicht beschreibbar (an Stelle der Datei liegt ein Ordner) -> Fehler, keine
    /// Reste im Ordner.
    func testExporterWriteFailureLeavesNoPartialFile() throws {
        let lay = try blankLayout(templates: ["grid"])
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        let title = "Kollision-\(UUID().uuidString.prefix(6))"
        let target = dir.appendingPathComponent(PDFExporter.safeFileName(title) + " – Notizen.pdf", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: target.appendingPathComponent("inhalt"))
        addTeardownBlock { try? FileManager.default.removeItem(at: target) }
        let before = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        XCTAssertThrowsError(try PDFExporter.export(layout: lay, pages: [:], images: [:], title: title)) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        let after = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        XCTAssertEqual(after, before, "keine halben oder temporaeren Dateien")
    }

    /// Lange Titel mit Zeichen ausserhalb von ASCII (mathematische Buchstaben, Emoji, auch aus mehreren Zeichen
    /// zusammengesetzte wie "Technikerin", zerlegte Umlaute): Teilen und Export muessen trotzdem eine Datei
    /// schreiben. Der Dateiname wird nach Zeichen (Graphemen) gekuerzt; massgeblich fuer das Dateisystem ist aber
    /// seine Laenge in Einheiten (APFS: 255 UTF-16-Einheiten, viele andere Ziele: 255 Byte).
    func testLongUnicodeTitleStillProducesAFile() throws {
        let lay = try blankLayout(templates: ["blank"])
        let umlaute = String(repeating: "U\u{308}bung A\u{308}rger O\u{308}l ", count: 8)        // zerlegt (NFD)
        let titles = [String(repeating: "\u{1D544}", count: 90) + " Skript",                     // mathematisches M
                      "Übung " + String(repeating: "\u{1F9EE}", count: 85),                     // Abakus
                      String(repeating: "線形代数", count: 25),
                      umlaute,
                      "Informatik " + String(repeating: "\u{1F469}\u{200D}\u{1F4BB}", count: 80)] // Technikerin (ZWJ)
        for (n, title) in titles.enumerated() {
            let p = try ShareExport.payload(layout: lay, pages: [:], images: [:], title: title, fileID: "f",
                                            moduleID: nil, module: nil, scope: .document)
            let units = p.fileName.utf16.count
            XCTAssertNoThrow(try ShareExport.writeFile(p), "Titel \(n + 1): Teilen scheitert am Dateinamen (\(units) UTF-16-Einheiten)")
            XCTAssertNoThrow(try PDFExporter.export(layout: lay, pages: [:], images: [:], title: title),
                             "Titel \(n + 1): Export scheitert am Dateinamen")
        }
    }

    // MARK: Export direkt nach dem Schreiben (Flush)

    /// Strich gerade beendet (Canvas-Aenderung noch in der 0,25-s-Pause) und sofort exportiert: der Strich ist drin.
    func testLastStrokeIncludedWhenExportingImmediately() async throws {
        let pdf = makePDFData([PageSpec(size: Self.a4), PageSpec(size: Self.a4)])
        let store = try await makeStore(pdf: pdf, pageCount: 2)
        store.canvasChanged(pageKey: "p2", drawing: drawing([(100, 400, 500)]))
        let one = try await store.sharePayload(.page(1), loadImage: nil)
        XCTAssertTrue(isDark(try exportedRaster(one.pdf, 0).darkest(CGRect(x: 248, y: 498, width: 4, height: 4))),
                      "letzter Strich fehlt im Export (Diese Seite)")
        store.canvasChanged(pageKey: "p1", drawing: drawing([(100, 400, 600)]))
        let all = try await store.sharePayload(.document, loadImage: nil)
        XCTAssertTrue(isDark(try exportedRaster(all.pdf, 0).darkest(CGRect(x: 248, y: 598, width: 4, height: 4))),
                      "letzter Strich fehlt im Export (Ganzes Dokument)")
        XCTAssertTrue(isDark(try exportedRaster(all.pdf, 1).darkest(CGRect(x: 248, y: 498, width: 4, height: 4))))
        await store.close()
    }

    /// Export, waehrend die Umrechnung einer grossen Seite noch laeuft (die 0,25-s-Pause ist vorbei), und gleich
    /// danach ein weiterer Strich: beide muessen im Export sein. `flush()` darf nicht zurueckkehren, solange eine
    /// laufende Verarbeitung noch nicht gesichert hat.
    func testExportWaitsForRunningInkConversion() async throws {
        let pdf = makePDFData([PageSpec(size: Self.a4), PageSpec(size: Self.a4)])
        let store = try await makeStore(pdf: pdf, pageCount: 2)
        // viele Striche auf Seite 1: die Umrechnung dauert merklich
        var lines: [(x0: CGFloat, x1: CGFloat, y: CGFloat)] = []
        for i in 0..<2500 {
            let x0 = CGFloat(60 + (i % 7) * 10)
            let y = CGFloat(700 + (i % 50))
            lines.append((x0, x0 + 60, y))
        }
        lines.append((100, 400, 300))                                    // gut sichtbarer Strich
        store.canvasChanged(pageKey: "p1", drawing: drawing(lines, width: 2))
        let started = Date()
        let background = Task { @MainActor in await store.flush() }       // wie die Verarbeitung nach der Pause
        try await Task.sleep(nanoseconds: 30_000_000)
        store.canvasChanged(pageKey: "p2", drawing: drawing([(100, 400, 500)]))   // letzter Strich
        let payload = try await store.sharePayload(.document, loadImage: nil)
        await background.value
        print("Umrechnung bis Ende: \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        let r1 = try exportedRaster(payload.pdf, 0), r2 = try exportedRaster(payload.pdf, 1)
        XCTAssertTrue(isDark(r1.darkest(CGRect(x: 248, y: 298, width: 4, height: 4))),
                      "Striche der gerade umgerechneten Seite fehlen im Export")
        XCTAssertTrue(isDark(r2.darkest(CGRect(x: 248, y: 498, width: 4, height: 4))), "letzter Strich fehlt im Export")
        // nichts verloren: gespeichert ist beides
        _ = await store.pageStructureDocument()
        let p1 = await store.objects(forPageKey: "p1"), p2 = await store.objects(forPageKey: "p2")
        XCTAssertEqual(p1.count, lines.count)
        XCTAssertEqual(p2.count, 1)
        await store.close()
    }
}
