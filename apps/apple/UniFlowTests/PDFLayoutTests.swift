import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Merkt sich, fuer welche Seiten PDFKit ein Overlay anfordert.
final class RecordingOverlayProvider: NSObject, PDFPageOverlayViewProvider {
    var requested: [Int] = []

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let index = view.document?.index(for: page) ?? -1
        requested.append(index)
        return PageInkView(pageIndex: index, geometry: PageGeometry(boxSize: page.bounds(for: .cropBox).size, rotation: page.rotation))
    }
}

/// Seitenzuordnung und Koordinaten mit echten PDF-Seiten (im Simulator; Schreibgefuehl und Handballen nur am Geraet).
final class PDFLayoutTests: XCTestCase {

    /// PDF mit Seiten der angegebenen Groessen; die zweite Seite wird optional gedreht.
    private func makePDF(sizes: [CGSize], rotateSecond: Int = 0) -> PDFDocument {
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(origin: .zero, size: sizes[0]), nil)
        for s in sizes {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: s), nil)
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 10, y: 10, width: 20, height: 20))
        }
        UIGraphicsEndPDFContext()
        let doc = PDFDocument(data: data as Data)!
        if rotateSecond != 0, let p = doc.page(at: 1) { p.rotation = rotateSecond }
        return doc
    }

    func testPageGeometryFromRealPages() {
        let doc = makePDF(sizes: [CGSize(width: 595, height: 842), CGSize(width: 842, height: 595)], rotateSecond: 90)
        let g0 = PageGeometry(boxSize: doc.page(at: 0)!.bounds(for: .cropBox).size, rotation: doc.page(at: 0)!.rotation)
        XCTAssertEqual(g0.pageSize, CGSize(width: 595, height: 842))
        let g1 = PageGeometry(boxSize: doc.page(at: 1)!.bounds(for: .cropBox).size, rotation: doc.page(at: 1)!.rotation)
        XCTAssertEqual(g1.pageSize, CGSize(width: 595, height: 842), "Querformat um 90° gedreht")
    }

    func testOverlayCanvasUsesPagePoints() {
        let overlay = PageInkView(pageIndex: 0, geometry: PageGeometry(pageSize: CGSize(width: 600, height: 800)))
        overlay.frame = CGRect(x: 0, y: 0, width: 1200, height: 1600)     // PDFKit liefert das Overlay doppelt so gross
        overlay.layoutIfNeeded()
        XCTAssertEqual(overlay.canvas.bounds.size, CGSize(width: 600, height: 800))
        let p = overlay.canvas.convert(CGPoint(x: 300, y: 400), to: overlay)
        XCTAssertEqual(p.x, 600, accuracy: 0.01)
        XCTAssertEqual(p.y, 800, accuracy: 0.01)
        overlay.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        overlay.layoutIfNeeded()
        XCTAssertEqual(overlay.canvas.transform, .identity)
    }

    func testPageKeyMappingWithInsertedWebPage() throws {
        let text = #"{"version":2,"pages":{},"pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"bX","type":"blank"},{"key":"p2","type":"pdf","index":2}]}"#
        let doc = AnnotationDocument(root: try JSONValue.parse(text))
        XCTAssertEqual(doc.pageKey(forPDFIndex: 1), "p1")
        XCTAssertEqual(doc.pageKey(forPDFIndex: 2), "p2", "eingefuegte Browser-Seite verschiebt die PDF-Zuordnung nicht")
    }

    /// PDFKit ruft den Overlay-Lieferanten fuer sichtbare Seiten auf; Seitenindex und Geometrie stimmen.
    @MainActor
    func testPDFViewRequestsOverlaysForVisiblePages() throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1180))
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        let pdfView = PDFView(frame: window.bounds)
        let provider = RecordingOverlayProvider()
        pdfView.pageOverlayViewProvider = provider
        pdfView.isInMarkupMode = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.document = makePDF(sizes: Array(repeating: CGSize(width: 595, height: 842), count: 5))
        window.addSubview(pdfView)
        window.makeKeyAndVisible()
        let end = Date().addingTimeInterval(3)
        while provider.requested.isEmpty && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(provider.requested.contains(0), "Overlay fuer die erste Seite angefordert: \(provider.requested)")
        window.isHidden = true
    }
}
