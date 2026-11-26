import XCTest
@testable import UniFlowCore

/// Klappkarten zum Abfragen (25.11.2026): Format als Form mit Zusatzfeld, Groessen, Treffer, Reihenfolge - und dass
/// aeltere Apps und die Community sie als gewoehnliche Form behandeln.
final class FlipCoverTests: XCTestCase {

    func testKarteIstEineFormDesGemeinsamenFormats() {
        let c = FlipCover.Choice(color: "#2e9e5b", pattern: "dots", size: "m")
        let o = FlipCover.cover(id: "k", x: 100.004, y: 200, width: 180, height: 40, choice: c)
        XCTAssertEqual(o["type"], "shape", "kein neuer Objekttyp")
        XCTAssertEqual(o["shape"], "rect")
        XCTAssertEqual(o["fill"], "#2e9e5b", "aeltere Apps zeigen das farbige Rechteck")
        XCTAssertEqual(o["opacity"], 1)
        XCTAssertEqual(o["cover"], ["pattern": "dots"])
        XCTAssertEqual(o["x"]?.double, 100)
        XCTAssertEqual(o["width"], 180)
        XCTAssertTrue(FlipCover.isCover(o))
        XCTAssertFalse(FlipCover.isCover(PageObjectEdit.shape(id: "r", kind: "rect", from: (0, 0), to: (10, 10), color: "#000000", width: 1)!))
        XCTAssertFalse(FlipCover.isCover(PageObjectEdit.text(id: "t", x: 0, y: 0)))
        XCTAssertNoThrow(try SolutionValidator.validateObject(o), "geht mit geteilten Loesungen mit")
        // die Regeln fuer Formen gelten weiter: verschieben, treffen, Lasso
        let moved = PageObjectEdit.move([o], ids: ["k"], dx: 10, dy: 5)[0]
        XCTAssertEqual(moved["cover"], o["cover"])
        XCTAssertEqual(PageObjectEdit.hit([moved], x: 150, y: 220, textHeight: { _ in 0 }), "k")
    }

    func testGroessenBeimAntippenUndKleinsteKarte() {
        let m = FlipCover.cover(id: "k", centerX: 300, centerY: 400, choice: FlipCover.Choice(size: "m"), page: (595, 842))
        XCTAssertEqual(m["width"], 260)
        XCTAssertEqual(m["height"], 34)
        XCTAssertEqual(m["x"]?.double, 170)
        XCTAssertEqual(m["y"]?.double, 383)
        let edge = FlipCover.cover(id: "k", centerX: 590, centerY: 840, choice: FlipCover.Choice(size: "l"), page: (595, 842))
        XCTAssertEqual(edge["x"]?.double, 595 - 380, "bleibt auf der Seite")
        XCTAssertEqual(edge["y"]?.double, 842 - 120)
        let tiny = FlipCover.cover(id: "k", x: 10, y: 10, width: 3, height: 2)
        XCTAssertEqual(tiny["width"]?.double, FlipCover.minimum.width)
        XCTAssertEqual(tiny["height"]?.double, FlipCover.minimum.height)
        let odd = FlipCover.cover(id: "k", x: 0, y: 0, width: 100, height: 30, choice: FlipCover.Choice(color: "", pattern: "glitzer"))
        XCTAssertEqual(FlipCover.pattern(odd), "plain")
        XCTAssertEqual(odd["fill"]?.string, FlipCover.colors[0].hex)
    }

    func testGroesseAendernHaeltDasMusterFein() {
        let o = FlipCover.cover(id: "k", x: 100, y: 100, width: 200, height: 40)
        let half = PageObjectEdit.scale([o], ids: ["k"], factorX: 0.5, factorY: 0.5)[0]
        XCTAssertEqual(half["width"], 100)
        XCTAssertEqual(half["height"], 20)
        XCTAssertEqual(half["scaleX"], 1, "Breite und Hoehe statt Massstab")
        let tiny = PageObjectEdit.scale([o], ids: ["k"], factorX: 0.01, factorY: 0.01)[0]
        XCTAssertEqual(tiny["width"]?.double, FlipCover.minimum.width)
        // gewoehnliche Formen skalieren wie bisher
        let rect = PageObjectEdit.shape(id: "r", kind: "rect", from: (0, 0), to: (10, 10), color: "#000000", width: 1)!
        XCTAssertEqual(PageObjectEdit.scale([rect], ids: ["r"], factorX: 2, factorY: 2)[0]["scaleX"], 2)
    }

    func testUmgestalten() {
        let o = FlipCover.cover(id: "k", x: 100, y: 100, width: 260, height: 34, choice: FlipCover.Choice(pattern: "plain"))
        let rect = PageObjectEdit.shape(id: "r", kind: "rect", from: (0, 0), to: (10, 10), color: "#000000", width: 1)!
        let out = FlipCover.restyling([o, rect], ids: ["k", "r"]) { $0.pattern = "question"; $0.color = "#e0568a" }
        XCTAssertEqual(out[1], rect, "andere Formen bleiben")
        XCTAssertEqual(FlipCover.pattern(out[0]), "question")
        XCTAssertEqual(out[0]["fill"], "#e0568a")
        XCTAssertEqual(out[0]["width"], 260, "Groesse unveraendert, wenn sie nicht gewaehlt wurde")
        let big = FlipCover.restyling(out, ids: ["k"]) { $0.size = "l" }[0]
        XCTAssertEqual(big["width"], 380)
        XCTAssertEqual(big["height"], 120)
        XCTAssertEqual(big["x"], 100)
        XCTAssertEqual(FlipCover.choice(big), FlipCover.Choice(color: "#e0568a", pattern: "question", size: "l"))
    }

    func testKartenLiegenUeberAllemUndTrefferNurAufDerKarte() {
        let text = TextBlock.block(id: "t", x: 100, y: 100, template: "blank")
        let k1 = FlipCover.cover(id: "k1", x: 100, y: 100, width: 200, height: 40)
        let stroke: JSONValue = ["id": "s", "type": "stroke", "points": [0, 0, 10, 10]]
        let k2 = FlipCover.cover(id: "k2", x: 150, y: 110, width: 200, height: 40)
        let list = [k1, text, stroke, k2]
        XCTAssertEqual(FlipCover.coversLast(list).compactMap { $0["id"]?.string }, ["t", "s", "k1", "k2"])
        XCTAssertEqual(FlipCover.coversLast([text, stroke]), [text, stroke])
        XCTAssertEqual(FlipCover.hit(list, x: 160, y: 120), "k2", "die obere Karte")
        XCTAssertEqual(FlipCover.hit(list, x: 110, y: 105), "k1")
        XCTAssertNil(FlipCover.hit(list, x: 99, y: 105), "ohne Spielraum: daneben schreibt man")
        XCTAssertNil(FlipCover.hit([text, stroke], x: 110, y: 105))
    }
}
