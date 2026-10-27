import Foundation
import XCTest
@testable import UniFlowCore

/// Seitenformate wie app/static/formats.js (Stand 7bcdfe5): Tabellen aus dem Quelltext gelesen und verglichen, dazu
/// dieselben Faelle wie tests/test_page_formats.py::test_formats_js_rules.
final class PageFormatsTests: XCTestCase {
    private func formatsJS() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("app/static/formats.js"), encoding: .utf8)
    }

    /// Eintraege `key: { name: "...", w: n, h: n[, hint: "..."] }` eines Objekts (`export const NAME = { ... };`)
    private func entries(_ js: String, _ object: String) throws -> [PageFormats.Format] {
        let start = try XCTUnwrap(js.range(of: "export const \(object) = {"))
        let end = try XCTUnwrap(js.range(of: "};", range: start.upperBound..<js.endIndex))
        let block = String(js[start.upperBound..<end.lowerBound])
        let re = try NSRegularExpression(pattern: #"(\w+): \{ name: "([^"]+)", w: (\d+), h: (\d+)(?:, hint: "([^"]*)")? \}"#)
        let ns = block as NSString
        return re.matches(in: block, range: NSRange(location: 0, length: ns.length)).map { m in
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            return PageFormats.Format(key: g(1)!, name: g(2)!, width: Int(g(3)!)!, height: Int(g(4)!)!, hint: g(5))
        }
    }

    func testTablesMatchFormatsJS() throws {
        let js = try formatsJS()
        XCTAssertEqual(try entries(js, "FORMATS"), PageFormats.paper)
        XCTAssertEqual(try entries(js, "WHITEBOARDS"), PageFormats.whiteboards)
        XCTAssertTrue(js.contains("export const MIN_SIDE = \(PageFormats.minSide), MAX_SIDE = \(PageFormats.maxSide);"))
        XCTAssertEqual(LibraryEndpoints.pageMinPT, PageFormats.minSide, "eine Quelle fuer die Grenzen")
        XCTAssertEqual(LibraryEndpoints.pageMaxPT, PageFormats.maxSide)
    }

    func testRulesLikeFormatsJS() {
        XCTAssertTrue(PageFormats.size("a4")! == (595, 842))
        XCTAssertTrue(PageFormats.size("a4", .landscape)! == (842, 595))
        XCTAssertTrue(PageFormats.size("a6")! == (298, 420))
        XCTAssertTrue(PageFormats.size("a2")! == (1191, 1684))
        XCTAssertTrue(PageFormats.size("wb_a0")! == (3370, 2384))
        XCTAssertTrue(PageFormats.size("wb_a0", .portrait)! == (3370, 2384), "Whiteboards immer quer")
        XCTAssertNil(PageFormats.size("b5"))
        let of = PageFormats.format(width: 842, height: 1191)
        XCTAssertEqual(of?.key, "a3")
        XCTAssertEqual(of?.orientation, .portrait)
        XCTAssertEqual(PageFormats.format(width: 1191, height: 842)?.name, "A3 quer")
        XCTAssertEqual(PageFormats.format(width: 2384, height: 1684)?.key, "wb_a1")
        XCTAssertNil(PageFormats.format(width: 612, height: 792), "US Letter ist kein Format der Liste")
        XCTAssertEqual(PageFormats.format(width: 596.5, height: 840)?.key, "a4", "+- 2 pt")
        XCTAssertEqual([PageFormats.validSize(298, 420), PageFormats.validSize(3370, 2384), PageFormats.validSize(99, 400),
                        PageFormats.validSize(595.5, 842), PageFormats.validSize(3401, 100)], [true, true, false, false, false])
        XCTAssertFalse(PageFormats.validSize(.nan, 400))
        XCTAssertEqual(PageFormats.label(width: 612, height: 792), "22 × 28 cm")
        XCTAssertEqual(PageFormats.label(width: 842, height: 595), "A4 quer")
        XCTAssertEqual(PageFormats.paper.map(\.key), ["a6", "a5", "a4", "a3", "a2"])
        XCTAssertEqual(PageFormats.whiteboards.map(\.key), ["wb_a4", "wb_a3", "wb_a1", "wb_a0"])
        XCTAssertTrue(PageFormats.whiteboards.allSatisfy { $0.width <= PageFormats.maxSide && $0.height <= PageFormats.maxSide && $0.width > $0.height })
        XCTAssertTrue((PageFormats.paper + PageFormats.whiteboards).allSatisfy { PageFormats.validSize(Double($0.width), Double($0.height)) })
    }
}
