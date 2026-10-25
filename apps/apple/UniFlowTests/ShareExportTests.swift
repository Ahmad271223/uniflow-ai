import PDFKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Zaehlt die Zeichenoperatoren im Inhaltsstrom einer PDF-Seite (ohne eingebettete Formulare).
private final class OperatorCounter {
    var counts: [String: Int] = [:]

    static func bump(_ info: UnsafeMutableRawPointer?, _ op: String) {
        guard let info else { return }
        Unmanaged<OperatorCounter>.fromOpaque(info).takeUnretainedValue().counts[op, default: 0] += 1
    }

    static func count(_ page: CGPDFPage) -> [String: Int] {
        let counter = OperatorCounter()
        guard let table = CGPDFOperatorTableCreate() else { return [:] }
        // C-Rueckrufe duerfen nichts einfangen, daher je Operator ein eigener Block
        CGPDFOperatorTableSetCallback(table, "m") { _, i in OperatorCounter.bump(i, "m") }
        CGPDFOperatorTableSetCallback(table, "l") { _, i in OperatorCounter.bump(i, "l") }
        CGPDFOperatorTableSetCallback(table, "c") { _, i in OperatorCounter.bump(i, "c") }
        CGPDFOperatorTableSetCallback(table, "S") { _, i in OperatorCounter.bump(i, "S") }
        CGPDFOperatorTableSetCallback(table, "w") { _, i in OperatorCounter.bump(i, "w") }
        CGPDFOperatorTableSetCallback(table, "d") { _, i in OperatorCounter.bump(i, "d") }
        CGPDFOperatorTableSetCallback(table, "gs") { _, i in OperatorCounter.bump(i, "gs") }
        CGPDFOperatorTableSetCallback(table, "Do") { _, i in OperatorCounter.bump(i, "Do") }
        CGPDFOperatorTableSetCallback(table, "BI") { _, i in OperatorCounter.bump(i, "BI") }
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(counter).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
        return counter.counts
    }
}

/// Teilen & Export: Handschrift als Vektoren wie im Web-Editor, Datensatz fuer die Community, Miniaturen.
final class ShareExportTests: XCTestCase {

    private func makePDF(pages: Int, size: CGSize = CGSize(width: 595, height: 842)) -> PDFDocument {
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(origin: .zero, size: size), nil)
        for _ in 0..<pages { UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil) }
        UIGraphicsEndPDFContext()
        return PDFDocument(data: data as Data)!
    }

    /// Zwei PDF-Seiten und eine eingefuegte linierte Leerseite dazwischen.
    private func makeLayout() throws -> DisplayLayout {
        let doc = AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"pages":{},"pageOrder":[
          {"key":"p1","type":"pdf","index":1},
          {"key":"bA","type":"blank","template":"lined","w":595,"h":842},
          {"key":"p2","type":"pdf","index":2}]}
        """#))
        return DisplayLayout.build(original: makePDF(pages: 2), document: doc)
    }

    private func stroke(_ extra: String) throws -> JSONValue {
        try JSONValue.parse(##"{"id":"s","type":"stroke","color":"#1d2130","x":0,"y":0,"rotation":0,"scaleX":1,"scaleY":1,"##
                            + extra + "}")
    }

    // MARK: Zeichenplan (gleiche Regeln wie makeInkShape)

    func testPenWithWidthsDrawsOnePiecePerSegmentWidth() throws {
        let o = try stroke(##""tool":"pen","width":3,"opacity":1,"points":[0,0,10,0,20,0,30,0],"widths":[1,2,3,4]"##)
        let plan = try XCTUnwrap(InkRenderer.plan(o))
        XCTAssertEqual(plan.pieces.map(\.width), [1.5, 2.5, 3.5], "mittlere Breite je Punktpaar")
        XCTAssertEqual(plan.alpha, 1)
        XCTAssertFalse(plan.multiply)
        XCTAssertTrue(plan.dash.isEmpty)
    }

    func testEqualWidthsShareOnePath() throws {
        let o = try stroke(##""tool":"fountain","width":2,"opacity":1,"points":[0,0,10,0,20,0,30,0,40,0],"widths":[2,2,2,2,5]"##)
        let plan = try XCTUnwrap(InkRenderer.plan(o))
        XCTAssertEqual(plan.pieces.map(\.width), [2, 3.5], "gleiche Breite in einem Pfad")
    }

    func testTranslucentPenIsSinglePathWithAverageWidth() throws {
        let o = try stroke(##""tool":"pencil","width":2,"opacity":0.75,"points":[0,0,10,10,20,0],"widths":[1,2,3]"##)
        let plan = try XCTUnwrap(InkRenderer.plan(o))
        XCTAssertEqual(plan.pieces.count, 1)
        XCTAssertEqual(plan.pieces[0].width, 2, accuracy: 0.001)
        XCTAssertEqual(plan.alpha, 0.75, accuracy: 0.001)
        XCTAssertEqual(plan.dash, InkRenderer.pencilDash, "Bleistift gestrichelt")
        // Mittelpunkt-Kurve: endet im letzten Punkt, Kontrollpunkt (10,10) zieht die Kurve nach oben
        let box = plan.pieces[0].path.boundingBoxOfPath
        XCTAssertEqual(box.maxX, 20, accuracy: 0.001)
        XCTAssertGreaterThan(box.maxY, 4)
        XCTAssertLessThan(box.maxY, 10)
    }

    func testMarkerIsStraightMultiplyLine() throws {
        let o = try stroke(##""tool":"marker","width":16,"opacity":0.35,"points":[0,0,50,0,50,50]"##)
        let plan = try XCTUnwrap(InkRenderer.plan(o))
        XCTAssertTrue(plan.multiply)
        XCTAssertEqual(plan.alpha, 0.35, accuracy: 0.001)
        XCTAssertEqual(plan.pieces.map(\.width), [16])
        XCTAssertEqual(plan.pieces[0].path.boundingBoxOfPath, CGRect(x: 0, y: 0, width: 50, height: 50), "gerader Linienzug")
    }

    func testTransformAndInvisibleStrokes() throws {
        let o = try JSONValue.parse(##"{"type":"stroke","tool":"pen","color":"#000000","width":2,"points":[0,0,10,0],"x":100,"y":50,"rotation":90,"scaleX":2,"scaleY":2}"##)
        let plan = try XCTUnwrap(InkRenderer.plan(o))
        let end = CGPoint(x: 10, y: 0).applying(plan.transform)
        XCTAssertEqual(end.x, 100, accuracy: 0.001)
        XCTAssertEqual(end.y, 70, accuracy: 0.001, "verschieben, drehen, skalieren wie Konva")
        XCTAssertNil(InkRenderer.plan(try stroke(##""tool":"pen","points":[5,5]"##)), "ein Punkt: Konva zeichnet nichts")
        XCTAssertNil(InkRenderer.plan(try JSONValue.parse(##"{"type":"text","text":"x"}"##)))
    }

    // MARK: PDF-Export

    /// Auf der Leerseite (ohne Original-PDF) besteht der Inhalt nur aus Vorlage und Handschrift: Kurven und
    /// Linienbreiten als Pfad-Operatoren, kein Bild.
    func testExportDrawsInkAsVectorPaths() throws {
        let layout = try makeLayout()
        let pen = try stroke(##""tool":"pen","width":3,"opacity":1,"points":[100,100,150,120,200,100,250,140,300,100],"widths":[1,2,3,4,5]"##)
        let marker = try stroke(##""tool":"marker","width":16,"opacity":0.35,"points":[100,300,400,300]"##)
        let data = PDFExporter.render(layout: layout, pages: ["bA": .object(["objects": .array([pen, marker])])], images: [:])
        let exported = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(exported.pageCount, 3)
        let cg = try XCTUnwrap(exported.page(at: 1)?.pageRef)
        let ops = OperatorCounter.count(cg)
        XCTAssertGreaterThanOrEqual(ops["c", default: 0], 3, "Mittelpunkt-Kurven: \(ops)")
        XCTAssertGreaterThanOrEqual(ops["w", default: 0], 4, "Breite je Teilstueck: \(ops)")
        XCTAssertGreaterThanOrEqual(ops["S", default: 0], 5, "Vorlage + Teilstuecke + Marker: \(ops)")
        XCTAssertGreaterThanOrEqual(ops["gs", default: 0], 1, "Deckkraft/Multiplizieren ueber Grafikzustand: \(ops)")
        XCTAssertEqual(ops["Do", default: 0], 0, "kein eingebettetes Bild")
        XCTAssertEqual(ops["BI", default: 0], 0, "kein Inline-Bild")
    }

    /// Pixeltest: der Strich ist an der richtigen Stelle dunkel, daneben bleibt die Seite weiss.
    func testExportInkPixelsOnPDFPage() throws {
        let layout = try makeLayout()
        let pen = try stroke(##""tool":"pen","width":6,"opacity":1,"points":[100,400,300,400]"##)
        let data = PDFExporter.render(layout: layout, pages: ["p2": .object(["objects": .array([pen])])], images: [:],
                                      pageIndices: [2])
        let exported = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(exported.pageCount, 1, "nur die gewaehlte Seite")
        let img = try XCTUnwrap(exported.page(at: 0)?.thumbnail(of: CGSize(width: 595, height: 842), for: .mediaBox))
        XCTAssertLessThan(brightness(img, at: CGPoint(x: 200, y: 400)), 0.4)
        XCTAssertGreaterThan(brightness(img, at: CGPoint(x: 200, y: 450)), 0.9)
    }

    // MARK: Datensatz fuer das Teilen

    func testPayloadForDocumentAndPage() throws {
        let layout = try makeLayout()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let all = try ShareExport.payload(layout: layout, pages: [:], images: [:], title: "Analysis I: Blatt 3",
                                          fileID: "f1", moduleID: 7, module: "Analysis I", scope: .document, createdAt: date)
        XCTAssertEqual(all.pageRange, 1...3)
        XCTAssertEqual(all.pageCount, 3)
        XCTAssertEqual(PDFDocument(data: all.pdf)?.pageCount, 3)
        XCTAssertEqual(all.fileName, "Analysis I- Blatt 3.pdf")
        XCTAssertEqual(all.moduleID, 7)
        XCTAssertEqual(all.module, "Analysis I")
        XCTAssertEqual(all.createdAt, date)
        XCTAssertEqual(PDFDocument(data: all.pdf)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                       "Analysis I: Blatt 3")

        let one = try ShareExport.payload(layout: layout, pages: [:], images: [:], title: "Skript", fileID: "f1",
                                          moduleID: nil, module: nil, scope: .page(1))
        XCTAssertEqual(one.pageRange, 2...2)
        XCTAssertEqual(PDFDocument(data: one.pdf)?.pageCount, 1)
        XCTAssertThrowsError(try ShareExport.payload(layout: layout, pages: [:], images: [:], title: "x", fileID: "f1",
                                                     moduleID: nil, module: nil, scope: .page(3)))
    }

    func testWriteFileUsesTitleAsFileName() throws {
        let layout = try makeLayout()
        let p = try ShareExport.payload(layout: layout, pages: [:], images: [:], title: "Lineare Algebra", fileID: "f",
                                        moduleID: nil, module: nil, scope: .page(0))
        let url = try ShareExport.writeFile(p)
        XCTAssertEqual(url.lastPathComponent, "Lineare Algebra.pdf")
        XCTAssertEqual(try Data(contentsOf: url), p.pdf)
    }

    // MARK: Miniaturen

    func testThumbnailShowsInk() throws {
        let layout = try makeLayout()
        let pen = try stroke(##""tool":"pen","width":20,"opacity":1,"points":[100,421,495,421]"##)
        let page = try XCTUnwrap(layout.pdf.page(at: 0))
        let entry = try XCTUnwrap(layout.entry(at: 0))
        let img = PageRenderer.thumbnail(page: page, entry: entry, objects: [pen], images: [:], width: 140, scale: 1)
        XCTAssertEqual(img.size.width, 140)
        XCTAssertEqual(img.size.height, 198, accuracy: 1)
        XCTAssertLessThan(brightness(img, at: CGPoint(x: 70, y: 99)), 0.4, "Strich in der Mitte")
        XCTAssertGreaterThan(brightness(img, at: CGPoint(x: 70, y: 20)), 0.9)
    }

    private func brightness(_ image: UIImage, at p: CGPoint) -> CGFloat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            image.draw(at: CGPoint(x: -p.x, y: -p.y))
        }
        guard let cg = pixel.cgImage, let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return 1 }
        let bpp = cg.bitsPerPixel / 8
        let r = CGFloat(ptr[0]), g = CGFloat(ptr[min(1, bpp - 1)]), b = CGFloat(ptr[min(2, bpp - 1)])
        return (r + g + b) / (3 * 255)
    }
}
