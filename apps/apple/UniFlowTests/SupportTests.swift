import PDFKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Hilfsbausteine der nativen Ansichten (Phase 5/6): Zwischenspeicher, Listenzeilen, Formatierung, Seitensprung.
final class SupportTests: XCTestCase {

    func testResponseCacheRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cache-test-\(UUID().uuidString)")
        let cache = ResponseCache(root: dir)
        XCTAssertNil(cache.load("/api/dashboard"))
        let value: JSONValue = ["today": ["date": "2026-10-25", "minutes": 90], "modules": []]
        cache.store(value, for: "/api/dashboard")
        let loaded = try XCTUnwrap(cache.load("/api/dashboard"))
        XCTAssertEqual(loaded.0, value)
        XCTAssertNil(cache.load("/api/modules"), "jeder Pfad hat seinen eigenen Eintrag")
        try? FileManager.default.removeItem(at: dir)
    }

    func testRowsGetUniqueIDs() {
        let rows = Row.rows([["id": 1], ["id": 1], ["name": "ohne id"]])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        XCTAssertEqual(rows.first?.id, "1")
    }

    func testFormatting() {
        XCTAssertEqual(UFFmt.min(90), "1 h 30 min")
        XCTAssertEqual(UFFmt.min(45), "45 min")
        XCTAssertNotNil(Fmt.date("2026-10-26T10:00:00"))
    }

    /// "Heute" und alle Tage der Oberflaeche in Berlin wie das lokale Backend (UniFlowClock), auch wenn das iPad in
    /// einer anderen Zeitzone steht: in London um 23:30 ist in Berlin schon der naechste Tag
    func testDaysUseBerlinTimeLikeTheBackend() throws {
        let saved = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        defer { NSTimeZone.default = saved }
        let lateInLondon = Date(timeIntervalSince1970: 1_793_057_400)          // 2026-10-26 23:30 London = 00:30 Berlin
        XCTAssertEqual(Fmt.isoDay(lateInLondon), "2026-10-27")
        XCTAssertEqual(Fmt.isoDay(lateInLondon), UniFlowClock.fixed(lateInLondon).today)
        let day = try XCTUnwrap(Fmt.date("2026-10-27"))
        XCTAssertEqual(Fmt.isoDay(day), "2026-10-27")
        XCTAssertEqual(UFFmt.weekdayShort("2026-10-27"), "Di")
        XCTAssertEqual(UFFmt.date("2026-10-27"), "27.10.2026")
        XCTAssertEqual(Fmt.isoDay(PlanData.monday(try XCTUnwrap(Fmt.date("2026-11-01")))), "2026-10-26")
        XCTAssertEqual(Fmt.isoDay(PlanData.add(day, 7)), "2026-11-03")
    }

    /// Die Skriptsuche liefert PDF-Seitennummern; der Editor springt zur passenden Anzeige-Seite,
    /// auch wenn im Browser Seiten eingefuegt oder entfernt wurden.
    func testPDFPageMapsToDisplayIndex() throws {
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(x: 0, y: 0, width: 595, height: 842), nil)
        for _ in 0..<4 { UIGraphicsBeginPDFPageWithInfo(CGRect(x: 0, y: 0, width: 595, height: 842), nil) }
        UIGraphicsEndPDFContext()
        let original = try XCTUnwrap(PDFDocument(data: data as Data))
        let doc = AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"pages":{},"pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"bX","type":"blank"},{"key":"p3","type":"pdf","index":3},{"key":"p4","type":"pdf","index":4}]}
        """#))
        let layout = DisplayLayout.build(original: original, document: doc)
        XCTAssertEqual(layout.entries.firstIndex { $0.pdfIndex == 3 }, 2)
        XCTAssertNil(layout.entries.firstIndex { $0.pdfIndex == 2 }, "im Browser entfernte Seite")
    }
}
