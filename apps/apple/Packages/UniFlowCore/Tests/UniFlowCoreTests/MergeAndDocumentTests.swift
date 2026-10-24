import XCTest
@testable import UniFlowCore

final class MergeTests: XCTestCase {

    func testBothDevicesAddOnSamePage() {
        let base = page(["a"])
        let local = page(["a", "ipad1"])
        let server = page(["a", "web1"])
        let r = AnnotationMerge.mergePage(base: base, local: local, server: server)
        let ids = r.page?["objects"]?.array?.compactMap { $0["id"]?.string }
        XCTAssertEqual(ids, ["a", "web1", "ipad1"])
        XCTAssertEqual(r.conflicts, 0)
    }

    func testDeletionOnOneSideWins() {
        let r = AnnotationMerge.mergePage(base: page(["a", "b"]), local: page(["a", "b", "c"]), server: page(["b"]))
        XCTAssertEqual(r.page?["objects"]?.array?.compactMap { $0["id"]?.string }, ["b", "c"])
    }

    func testDeletedHereButChangedThereIsKept() {
        var moved = stroke("a")
        moved["x"] = 30
        let r = AnnotationMerge.mergePage(base: page(["a"]), local: page([]), server: pageWith([moved]))
        XCTAssertEqual(r.page?["objects"]?.array?.first?["x"], 30)
        XCTAssertEqual(r.conflicts, 1)
    }

    func testBothChangedSameObjectLocalWinsAndCounts() {
        var l = stroke("a"); l["color"] = "#ff0000"
        var s = stroke("a"); s["color"] = "#00ff00"
        let r = AnnotationMerge.mergePage(base: page(["a"]), local: pageWith([l]), server: pageWith([s]))
        XCTAssertEqual(r.page?["objects"]?.array?.first?["color"], "#ff0000")
        XCTAssertEqual(r.conflicts, 1)
    }

    func testUnknownFieldsArePreserved() {
        var server = page(["a"])
        server["template"] = "lined"
        server["pkdrawing"] = ["data": "AAA", "objectsSig": "x"]
        let local = page(["a", "b"])
        let r = AnnotationMerge.mergePage(base: page(["a"]), local: local, server: server)
        XCTAssertEqual(r.page?["template"], "lined")
        XCTAssertNil(r.page?["pkdrawing"], "veraltete native Zeichnung wird nicht uebernommen")
    }

    func testPageOrderKeepsLocallyAddedPage() {
        let base: JSONValue = ["pageOrder": [["key": "p1"], ["key": "p2"]]]
        let local: JSONValue = ["pageOrder": [["key": "p1"], ["key": "p2"], ["key": "bNew"]]]
        let server: JSONValue = ["pageOrder": [["key": "p2"], ["key": "p1"]], "bookmarks": [["key": "p1"]]]
        let (m, _) = AnnotationMerge.mergeRootMeta(base: base, local: local, server: server)
        XCTAssertEqual(m["pageOrder"]?.array?.compactMap { $0["key"]?.string }, ["p2", "p1", "bNew"])
        XCTAssertEqual(m["bookmarks"]?.array?.count, 1)
    }

    func testMerge5000ObjectsIsFast() {
        let base = (0..<5000).map { stroke("s\($0)", points: 6) }
        let local = base + [stroke("neu-ipad")]
        let server = Array(base.dropFirst(10)) + [stroke("neu-web")]
        let start = Date()
        let (merged, conflicts) = AnnotationMerge.mergeObjects(base: base, local: local, server: server)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(merged.count, 4992)
        XCTAssertEqual(conflicts, 0)
        XCTAssertLessThan(seconds, 20)
        print("Merge 5000 Objekte: \(String(format: "%.3f", seconds)) s")
    }
}

final class DocumentTests: XCTestCase {

    func testEnsurePDFPagesAndMapping() {
        var doc = AnnotationDocument.empty()
        XCTAssertTrue(doc.ensurePDFPages(count: 3))
        XCTAssertFalse(doc.ensurePDFPages(count: 3))
        XCTAssertEqual(doc.pageKey(forPDFIndex: 2), "p2")
        XCTAssertEqual(doc.pdfIndex(forPageKey: "p3"), 3)
    }

    func testInsertedAndRemovedPagesFromWebEditor() throws {
        let text = #"{"version":2,"pages":{},"pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"b9","type":"blank","template":"lined"},{"key":"p3","type":"pdf","index":3}]}"#
        let doc = AnnotationDocument(root: try JSONValue.parse(text))
        XCTAssertEqual(doc.insertedPageCount, 1)
        XCTAssertEqual(doc.pageKey(forPDFIndex: 3), "p3")
        XCTAssertNil(doc.pageKey(forPDFIndex: 2), "im Browser entfernte PDF-Seite")
        XCTAssertEqual(doc.removedPDFIndices(pdfPageCount: 3), [2])
        XCTAssertNil(doc.pdfIndex(forPageKey: "b9"))
    }

    func testStoredDrawingRoundTrip() {
        let sd = StoredDrawing(data: "QUJD", signature: "sig", strokeIDs: [["a"], ["b1", "b2"]])
        var p = page(["a"])
        p["pkdrawing"] = sd.json
        XCTAssertEqual(StoredDrawing(page: p), sd)
    }
}

final class GeometryTests: XCTestCase {

    func testRotatedPageSwapsSize() {
        XCTAssertEqual(PageGeometry(boxSize: CGSize(width: 595, height: 842), rotation: 90).pageSize, CGSize(width: 842, height: 595))
        XCTAssertEqual(PageGeometry(boxSize: CGSize(width: 595, height: 842), rotation: -90).pageSize, CGSize(width: 842, height: 595))
        XCTAssertEqual(PageGeometry(boxSize: CGSize(width: 595, height: 842), rotation: 180).pageSize, CGSize(width: 595, height: 842))
    }

    func testViewToPageAndBack() {
        let g = PageGeometry(pageSize: CGSize(width: 600, height: 800))
        let view = CGSize(width: 1200, height: 1600)
        let p = g.toPage(CGPoint(x: 300, y: 500), viewSize: view)
        XCTAssertEqual(p, CGPoint(x: 150, y: 250))
        XCTAssertEqual(g.toView(p, viewSize: view), CGPoint(x: 300, y: 500))
    }

    func testZoomKeptOnResizeWhenUserZoomed() {
        XCTAssertEqual(ZoomPolicy.scaleAfterResize(current: 2.0, oldFit: 1.0, newFit: 1.5, userZoomed: true), 3.0, accuracy: 1e-9)
        XCTAssertEqual(ZoomPolicy.scaleAfterResize(current: 2.0, oldFit: 1.0, newFit: 1.5, userZoomed: false), 1.5, accuracy: 1e-9)
        XCTAssertEqual(ZoomPolicy.scaleAfterResize(current: 50, oldFit: 1, newFit: 1, userZoomed: true), 6, accuracy: 1e-9)
        XCTAssertFalse(ZoomPolicy.isUserZoom(scale: 1.004, fitScale: 1))
        XCTAssertTrue(ZoomPolicy.isUserZoom(scale: 1.3, fitScale: 1))
    }
}
