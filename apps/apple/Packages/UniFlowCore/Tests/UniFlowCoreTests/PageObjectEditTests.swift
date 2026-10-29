import XCTest
@testable import UniFlowCore

/// Objekt-Werkzeuge (Editor-Schritt 6) in den Feldern des Web-Editors: Text, Haftnotiz, Formen, Textmarker an Zeilen,
/// Verschieben, Groesse, Loeschen, Treffer und Lasso. Striche werden nie ausgewaehlt (die bearbeitet PencilKit).
final class PageObjectEditTests: XCTestCase {

    private let fixedHeight: (JSONValue) -> Double = { _ in 20 }

    func testTextAndStickyLikeCreateTextAndCreateSticky() {
        let t = PageObjectEdit.text(id: "t1", x: 40.004, y: 60, text: "Hallo")
        XCTAssertEqual(t["type"], "text")
        XCTAssertEqual(t["x"]?.double, 40)
        XCTAssertEqual(t["fontFamily"], "Arial")
        XCTAssertEqual(t["fontSize"], 14)
        XCTAssertEqual(t["width"], 220)
        XCTAssertEqual(t["bg"], "")
        XCTAssertEqual(t["source"], "ipad")
        let s = PageObjectEdit.sticky(id: "n1", x: 100, y: 100)
        XCTAssertEqual(s["x"]?.double, 90, "10 pt links oberhalb wie im Web")
        XCTAssertEqual(s["y"]?.double, 90)
        XCTAssertEqual(s["bg"]?.string, PageObjectEdit.stickyColor)
        XCTAssertEqual(s["width"], 170)
        XCTAssertEqual(s["fontSize"], 13)
    }

    func testShapesLikeShapeObj() throws {
        let r = try XCTUnwrap(PageObjectEdit.shape(id: "r", kind: "rect", from: (200, 150), to: (100, 50), color: "#e5322d", width: 2))
        XCTAssertEqual(r["x"]?.double, 100)
        XCTAssertEqual(r["y"]?.double, 50)
        XCTAssertEqual(r["width"]?.double, 100)
        XCTAssertEqual(r["height"]?.double, 100)
        XCTAssertNil(r["points"])
        let a = try XCTUnwrap(PageObjectEdit.shape(id: "a", kind: "arrow", from: (10, 10), to: (40, 50), color: "#000000", width: 3))
        XCTAssertEqual(a["points"], [10, 10, 40, 50])
        XCTAssertEqual(a["width"]?.double, 70, "Breite wie im Web: |dx| + |dy|")
        XCTAssertEqual(a["x"], 0)
        XCTAssertNil(PageObjectEdit.shape(id: "x", kind: "stern", from: (0, 0), to: (1, 1), color: "#000", width: 1))
    }

    /// Zeile 100..300 x 50..62, Text waagerecht: Markieren = Rechteck; Unterstreichen knapp unter der Grundlinie,
    /// Durchstreichen bei 55 % der Hoehe; Gelb wird bei Linien zu Rot (wie `addMarkup`)
    func testMarkupLikeAddMarkup() {
        var n = 0
        let line = PageObjectEdit.Line(text: "Satz", x0: 100, y0: 50, x1: 300, y1: 62)
        let hl = PageObjectEdit.markup(.highlight, lines: [line], color: "#f5d90a") { n += 1; return "m\(n)" }
        XCTAssertEqual(hl.first?["shape"], "rect")
        XCTAssertEqual(hl.first?["markup"], "highlight")
        XCTAssertEqual(hl.first?["width"]?.double, 200)
        XCTAssertEqual(hl.first?["height"]?.double, 12)
        XCTAssertEqual(hl.first?["opacity"]?.double, 0.35)
        XCTAssertEqual(hl.first?["text"], "Satz")
        let ul = PageObjectEdit.markup(.underline, lines: [line], color: "#f5d90a") { "u" }
        XCTAssertEqual(ul.first?["points"], [100, 62.96, 300, 62.96], "y1 + 0,08 x Hoehe")
        XCTAssertEqual(ul.first?["stroke"], "#e5322d")
        XCTAssertEqual(ul.first?["strokeWidth"]?.double, 1, "mindestens 1")
        let st = PageObjectEdit.markup(.strike, lines: [line], color: "#7cc4ff") { "s" }
        XCTAssertEqual(st.first?["points"], [100, 56.6, 300, 56.6], "y0 + 0,55 x Hoehe")
        XCTAssertEqual(st.first?["stroke"], "#7cc4ff")
        // senkrechter Text (Seite gedreht): Linie senkrecht
        let v = PageObjectEdit.Line(text: "V", x0: 50, y0: 100, x1: 62, y1: 300, up: (1, 0))
        let vu = PageObjectEdit.markup(.underline, lines: [v], color: "#7ee081") { "v" }
        XCTAssertEqual(vu.first?["points"], [49.04, 100, 49.04, 300])
    }

    func testMoveScaleDeleteAndSet() {
        let objs: [JSONValue] = [
            ["id": "s", "type": "stroke", "x": 0, "y": 0],
            PageObjectEdit.text(id: "t", x: 10, y: 10),
            PageObjectEdit.shape(id: "r", kind: "rect", from: (0, 0), to: (10, 10), color: "#000", width: 1)!,
        ]
        let moved = PageObjectEdit.move(objs, ids: ["t", "r"], dx: 5.555, dy: -2)
        XCTAssertEqual(moved[1]["x"]?.double, 15.56)
        XCTAssertEqual(moved[1]["y"]?.double, 8)
        XCTAssertEqual(moved[2]["x"]?.double, 5.56)
        XCTAssertEqual(moved[0], objs[0], "nicht ausgewaehlt: unveraendert")
        let scaled = PageObjectEdit.scale(moved, ids: ["t", "r"], factorX: 2, factorY: 1.5)
        XCTAssertEqual(scaled[1]["width"]?.double, 440, "Text: Breite")
        XCTAssertEqual(scaled[1]["scaleX"]?.double, 1)
        XCTAssertEqual(scaled[2]["scaleX"]?.double, 2)
        XCTAssertEqual(scaled[2]["scaleY"]?.double, 1.5)
        XCTAssertEqual(PageObjectEdit.scale(moved, ids: ["r"], factorX: 0, factorY: 1), moved, "ungueltig: nichts")
        let set = PageObjectEdit.set(scaled, ids: ["t"], "text", "neu")
        XCTAssertEqual(set[1]["text"], "neu")
        XCTAssertEqual(PageObjectEdit.delete(set, ids: ["t"]).compactMap { $0["id"]?.string }, ["s", "r"])
    }

    func testBoundsHitAndLassoSkipStrokes() {
        let objs: [JSONValue] = [
            ["id": "s", "type": "stroke", "points": [0, 0, 500, 500]],
            PageObjectEdit.text(id: "t", x: 100, y: 100),
            PageObjectEdit.shape(id: "r", kind: "rect", from: (300, 300), to: (400, 350), color: "#000", width: 1)!,
            ["id": "g", "type": "shape", "shape": "rect", "x": 600, "y": 100, "width": 100, "height": 50, "rotation": 90, "scaleX": 1, "scaleY": 1],
        ]
        let tb = PageObjectEdit.bounds(objs[1], textHeight: fixedHeight)
        XCTAssertEqual(tb?.maxX, 320)
        XCTAssertEqual(tb?.maxY, 120)
        let gb = PageObjectEdit.bounds(objs[3], textHeight: fixedHeight)
        XCTAssertEqual(gb?.minX ?? 0, 550, accuracy: 1e-9, "um 90 Grad gedreht: nach links unten")
        XCTAssertEqual(gb?.maxY ?? 0, 200, accuracy: 1e-9)
        XCTAssertNil(PageObjectEdit.bounds(objs[0], textHeight: fixedHeight))
        XCTAssertEqual(PageObjectEdit.hit(objs, x: 350, y: 320, textHeight: fixedHeight), "r")
        XCTAssertEqual(PageObjectEdit.hit(objs, x: 150, y: 110, textHeight: fixedHeight), "t")
        XCTAssertNil(PageObjectEdit.hit(objs, x: 250, y: 250, textHeight: fixedHeight), "Strich darunter wird nicht getroffen")
        let lasso = PageObjectEdit.inLasso(objs, polygon: [(50, 50), (450, 50), (450, 450), (50, 450)], textHeight: fixedHeight)
        XCTAssertEqual(lasso, ["t", "r"])
        XCTAssertTrue(PageObjectEdit.inLasso(objs, polygon: [(0, 0), (1, 1)], textHeight: fixedHeight).isEmpty)
    }
}
