import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Phase 4: Seitenaufbau wie im Web-Editor, Web-Objekte, PDF-Export.
final class EditorFeatureTests: XCTestCase {

    private func makePDF(pages: Int, size: CGSize = CGSize(width: 595, height: 842)) -> PDFDocument {
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(origin: .zero, size: size), nil)
        for _ in 0..<pages { UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil) }
        UIGraphicsEndPDFContext()
        return PDFDocument(data: data as Data)!
    }

    func testLayoutFollowsWebPageOrder() throws {
        let original = makePDF(pages: 3)
        let doc = AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"pages":{},"pageOrder":[
          {"key":"p1","type":"pdf","index":1},
          {"key":"bA","type":"blank","template":"lined","w":400,"h":600},
          {"key":"p3","type":"pdf","index":3,"rotation":90},
          {"key":"bImg","type":"asset","w":500,"h":700}]}
        """#))
        let layout = DisplayLayout.build(original: original, document: doc)
        XCTAssertEqual(layout.entries.map(\.key), ["p1", "bA", "p3", "bImg"], "im Browser entfernte Seite 2 fehlt")
        XCTAssertEqual(layout.pdf.pageCount, 4)
        XCTAssertEqual(layout.entry(at: 1)?.template, "lined")
        XCTAssertEqual(layout.pdf.page(at: 1)?.bounds(for: .cropBox).size, CGSize(width: 400, height: 600))
        XCTAssertEqual(layout.pdf.page(at: 2)?.rotation, 90)
        XCTAssertEqual(layout.index(ofKey: "p3"), 2)
        XCTAssertEqual(layout.entry(at: 3)?.kind, "asset")
    }

    func testLayoutWithoutPageOrderUsesAllPDFPages() {
        let layout = DisplayLayout.build(original: makePDF(pages: 2), document: .empty())
        XCTAssertEqual(layout.entries.map(\.key), ["p1", "p2"])
    }

    func testShapeAndTextGeometry() throws {
        let rect = try JSONValue.parse(##"{"type":"shape","shape":"rect","x":30,"y":300,"width":120,"height":40,"stroke":"#e5322d","strokeWidth":2}"##)
        let r = try XCTUnwrap(ObjectGeometry.shapePath(rect))
        XCTAssertEqual(r.path.boundingBox, CGRect(x: 0, y: 0, width: 120, height: 40))
        XCTAssertEqual(CGPoint.zero.applying(ObjectGeometry.transform(rect)), CGPoint(x: 30, y: 300))
        let arrow = try JSONValue.parse(##"{"type":"shape","shape":"arrow","points":[0,0,100,0],"stroke":"#000000","strokeWidth":2}"##)
        XCTAssertNotNil(try XCTUnwrap(ObjectGeometry.shapePath(arrow)).arrowHead)
        let text = try JSONValue.parse(##"{"type":"text","text":"Skalarprodukt und Projektion auf eine Gerade","width":120,"fontSize":14}"##)
        let size = ObjectGeometry.textSize(text, ObjectGeometry.attributedText(text))
        XCTAssertEqual(size.width, 120)
        XCTAssertGreaterThan(size.height, 30, "laengerer Text bricht um")
    }

    func testTemplateLinesMatchWebSpacing() {
        let lined = ObjectGeometry.templatePath("lined", size: CGSize(width: 595, height: 842))
        XCTAssertNotNil(lined.lines)
        XCTAssertEqual(lined.lines?.boundingBox.minY ?? 0, 60, accuracy: 0.01, "erste Linie 60 pt unter dem Rand wie im Web-Editor")
        XCTAssertNil(ObjectGeometry.templatePath("blank", size: CGSize(width: 10, height: 10)).lines)
        XCTAssertNotNil(ObjectGeometry.templatePath("dotted", size: CGSize(width: 100, height: 100)).dots)
    }

    @MainActor
    func testObjectsViewShowsTemplateAndShapes() throws {
        let v = PageObjectsView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
        let rect = try JSONValue.parse(##"{"id":"r","type":"shape","shape":"rect","x":30,"y":30,"width":50,"height":50,"stroke":"#000000","strokeWidth":2}"##)
        let text = try JSONValue.parse(##"{"id":"t","type":"text","text":"Hallo","x":10,"y":10,"width":100}"##)
        v.show(template: "grid", placeholder: nil, objects: [rect, text], images: [:])
        XCTAssertEqual(v.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.count, 2, "Raster + Rechteck")
        XCTAssertEqual(v.subviews.count, 1, "ein Textfeld")
    }

    func testExportContainsPagesAndInk() throws {
        let original = makePDF(pages: 2)
        var doc = AnnotationDocument.empty()
        doc.ensurePDFPages(count: 2)
        let stroke = try JSONValue.parse(##"{"id":"s1","type":"stroke","tool":"pen","color":"#000000","width":6,"opacity":1,"points":[100,100,300,100,300,300],"x":0,"y":0,"rotation":0,"scaleX":1,"scaleY":1}"##)
        let layout = DisplayLayout.build(original: original, document: doc)
        let data = PDFExporter.render(layout: layout, pages: ["p1": .object(["objects": .array([stroke])])], images: [:])
        let exported = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(exported.pageCount, 2)
        XCTAssertEqual(exported.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 595, height: 842))
        // Handschrift ist im Export sichtbar: dunkles Pixel auf dem Strich, weisses daneben
        let thumb = try XCTUnwrap(exported.page(at: 0)?.thumbnail(of: CGSize(width: 595, height: 842), for: .mediaBox))
        XCTAssertLessThan(brightness(thumb, at: CGPoint(x: 200, y: 100)), 0.5)
        XCTAssertGreaterThan(brightness(thumb, at: CGPoint(x: 200, y: 500)), 0.9)
    }

    private func brightness(_ image: UIImage, at p: CGPoint) -> CGFloat {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let pixel = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            image.draw(at: CGPoint(x: -p.x * image.scale / image.scale, y: -p.y))
        }
        guard let cg = pixel.cgImage, let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return 1 }
        let bpp = cg.bitsPerPixel / 8
        let r = CGFloat(ptr[0]), g = CGFloat(ptr[min(1, bpp - 1)]), b = CGFloat(ptr[min(2, bpp - 1)])
        return (r + g + b) / (3 * 255)
    }
}
