import XCTest
@testable import UniFlowCore

/// Verweise auf Dokument + Seite (25.11.2026): Format als Form mit Zusatzfeld, Ziel lesen und begrenzen, Treffer.
final class PageLinkTests: XCTestCase {

    private let target = PageLink.Target(file: "f-skript", title: "Skript Kapitel 3", pageKey: "p12", pdfPage: 12, pageNumber: 12, x: 140.004, y: 310)

    func testVerweisIstEineFormDesGemeinsamenFormats() {
        let p = PageLink.point(id: "v", x: 200, y: 300, target: target)
        XCTAssertEqual(p["type"], "shape", "kein neuer Objekttyp")
        XCTAssertEqual(p["shape"], "rect")
        XCTAssertEqual(p["fill"], "")
        XCTAssertEqual(p["stroke"]?.string, PageLink.color)
        XCTAssertEqual(p["x"]?.double, 200 - 11)
        XCTAssertEqual(p["width"]?.double, 22)
        XCTAssertTrue(PageLink.isLink(p))
        XCTAssertTrue(PageLink.isPoint(p))
        XCTAssertEqual(PageLink.target(p), PageLink.Target(file: "f-skript", title: "Skript Kapitel 3", pageKey: "p12", pdfPage: 12, pageNumber: 12, x: 140, y: 310))
        XCTAssertEqual(PageLink.target(p)?.label, "Skript Kapitel 3, Seite 12")
        XCTAssertNoThrow(try SolutionValidator.validateObject(p), "geht mit geteilten Loesungen mit")
        let a = PageLink.area(id: "w", x: 100, y: 100, width: 60, height: 3, target: target)
        XCTAssertFalse(PageLink.isPoint(a))
        XCTAssertEqual(a["height"]?.double, PageLink.minimum.height, "bleibt antippbar")
        XCTAssertEqual(a["width"], 60)
        // die Regeln fuer Formen gelten weiter
        let moved = PageObjectEdit.move([a], ids: ["w"], dx: 5, dy: 5)[0]
        XCTAssertEqual(PageLink.target(moved), PageLink.target(a))
        XCTAssertFalse(PageLink.isLink(PageObjectEdit.shape(id: "r", kind: "rect", from: (0, 0), to: (10, 10), color: "#000000", width: 1)!))
        XCTAssertFalse(FlipCover.isCover(p))
    }

    func testNotizbuchSeiteOhnePDFSeiteUndBeschriftung() {
        let t = PageLink.Target(file: "nb1", title: "  ", pageKey: "b7a", pdfPage: nil, pageNumber: 0, x: 1, y: 2)
        let o = PageLink.point(id: "v", x: 10, y: 10, target: t)
        XCTAssertNil(o["link"]?["pdfPage"])
        XCTAssertEqual(PageLink.target(o)?.pageKey, "b7a")
        XCTAssertNil(PageLink.target(o)?.pdfPage)
        XCTAssertEqual(PageLink.target(o)?.label, "Dokument, Seite 1")
    }

    func testBeschaedigteZieleWerdenNichtGefolgt() {
        var o = PageLink.point(id: "v", x: 10, y: 10, target: target)
        o["link"] = ["file": "", "page": "p1"]
        XCTAssertNil(PageLink.target(o), "ohne Dokument kein Verweis")
        XCTAssertFalse(PageLink.isLink(o))
        o["link"] = ["file": "f", "x": .number(.infinity), "y": 3]
        XCTAssertNil(PageLink.target(o))
        o["link"] = ["file": "f", "x": 1e12, "y": -1e12, "pageNumber": -5, "pdfPage": 0, "title": .string(String(repeating: "x", count: 5_000))]
        let t = PageLink.target(o)
        XCTAssertEqual(t?.x, 100_000)
        XCTAssertEqual(t?.y, -100_000)
        XCTAssertEqual(t?.pageNumber, 1)
        XCTAssertNil(t?.pdfPage)
        XCTAssertEqual(t?.title.count, 200)
        o["link"] = "f"
        XCTAssertNil(PageLink.target(o))
        o["link"] = ["file": .string(String(repeating: "a", count: 201))]
        XCTAssertNil(PageLink.target(o))
    }

    func testZielAendernUndTreffer() {
        let p = PageLink.point(id: "v", x: 200, y: 300, target: target)
        let card = FlipCover.cover(id: "k", x: 100, y: 100, width: 200, height: 40)
        let text = TextBlock.block(id: "t", x: 100, y: 100, template: "blank")
        let other = PageLink.Target(file: "f2", title: "Übung 4", pageKey: "p2", pdfPage: 2, pageNumber: 2, x: 5, y: 6)
        let out = PageLink.retargeting([p, card], id: "v", to: other)
        XCTAssertEqual(PageLink.target(out[0]), other)
        XCTAssertTrue(PageLink.isPoint(out[0]))
        XCTAssertEqual(out[1], card)
        XCTAssertEqual(PageLink.retargeting([card], id: "k", to: other), [card], "Karten bekommen kein Ziel")
        // Schicht ueber der Handschrift: Karten und Verweise, zuletzt gezeichnet
        XCTAssertEqual(TopObjects.last([p, text, card]).compactMap { $0["id"]?.string }, ["t", "v", "k"])
        XCTAssertEqual(TopObjects.hit([text, p, card], x: 200, y: 300)?["id"], "v")
        XCTAssertEqual(TopObjects.hit([text, p, card], x: 214, y: 300)?["id"], "v", "kleiner Punkt: 5 pt Spielraum")
        XCTAssertNil(TopObjects.hit([text, p, card], x: 220, y: 300))
        XCTAssertEqual(TopObjects.hit([text, p, card], x: 150, y: 120)?["id"], "k")
        XCTAssertNil(TopObjects.hit([text], x: 110, y: 105))
    }
}
