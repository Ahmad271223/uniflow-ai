import XCTest
@testable import UniFlowCore

/// Seitenwerkzeuge (Editor-Schritt 5, P1-1/P1-2) wie im Web-Editor: movePage, duplicatePage, clearPage, setTemplate,
/// setFormat, Leere Seite davor/am Ende, Gliederung. Jede Operation mit Gegenprobe (unbekannte Seite, nichts zu tun).
final class PageToolsTests: XCTestCase {

    private func doc() throws -> AnnotationDocument {
        AnnotationDocument(root: try JSONValue.parse(#"""
        {"version":2,"note":"n","outline":[{"key":"p2","title":"Kapitel 2"}],
         "pages":{"p1":{"objects":[{"id":"a","type":"stroke"},{"id":"b","type":"text","text":"T"}],"pkdrawing":{"data":"QUJD","objectsSig":"s"}},"p2":{"objects":[]},"bX":{"objects":[{"id":"c"}]}},
         "pageOrder":[{"key":"p1","type":"pdf","index":1,"rotation":90},{"key":"p2","type":"pdf","index":2},{"key":"bX","type":"blank","template":"lined","w":595,"h":842}]}
        """#))
    }

    private func keys(_ d: AnnotationDocument) -> [String] { d.pageOrder.compactMap { $0["key"]?.string } }

    func testMoveLikeWebMovePage() throws {
        var d = try doc()
        XCTAssertEqual(PageOrder.move(&d, key: "bX", to: 0), PageOrder.Change(focusKey: "bX", changedPageKeys: []))
        XCTAssertEqual(keys(d), ["bX", "p1", "p2"])
        PageOrder.move(&d, key: "bX", to: 2)
        XCTAssertEqual(keys(d), ["p1", "p2", "bX"])
        let before = d.root
        XCTAssertNil(PageOrder.move(&d, key: "bX", to: 2), "selber Platz")
        XCTAssertNil(PageOrder.move(&d, key: "bX", to: 3), "ausserhalb")
        XCTAssertNil(PageOrder.move(&d, key: "bX", to: -1))
        XCTAssertNil(PageOrder.move(&d, key: "fehlt", to: 0))
        XCTAssertEqual(d.root, before)
    }

    func testDuplicateCopiesEntryAndPageWithNewIDs() throws {
        var d = try doc()
        var n = 0
        let c = PageOrder.duplicate(&d, key: "p1", newID: { n += 1; return "neu\(n)" })
        let key = try XCTUnwrap(c?.focusKey)
        XCTAssertTrue(key.hasPrefix("p1c"), "Schluessel wie im Web: p<Index>c…")
        XCTAssertEqual(c?.changedPageKeys, [key])
        XCTAssertEqual(keys(d), ["p1", key, "p2", "bX"])
        XCTAssertEqual(d.pageOrder[1]["rotation"], 90, "Felder des Eintrags bleiben")
        XCTAssertEqual(d.pageOrder[1]["index"], 1)
        XCTAssertEqual(d.objects(page: key).compactMap { $0["id"]?.string }, ["neu1", "neu2"])
        XCTAssertEqual(d.objects(page: key)[1]["text"], "T")
        XCTAssertEqual(d.objects(page: "p1").compactMap { $0["id"]?.string }, ["a", "b"], "Original unveraendert")
        let blank = PageOrder.duplicate(&d, key: "bX")
        XCTAssertTrue(blank?.focusKey?.hasPrefix("b") == true)
        XCTAssertEqual(d.pageOrder.last?["template"], "lined")
        XCTAssertNil(PageOrder.duplicate(&d, key: "fehlt"))
        XCTAssertNil(PageOrder.duplicate(&d, key: "p2", newKey: "p1"), "Schluessel vergeben")
    }

    func testClearRemovesObjectsOnly() throws {
        var d = try doc()
        XCTAssertEqual(PageOrder.clear(&d, key: "p1"), PageOrder.Change(focusKey: "p1", changedPageKeys: ["p1"]))
        XCTAssertTrue(d.objects(page: "p1").isEmpty)
        XCTAssertEqual(d.page("p1")?["pkdrawing"]?["data"], "QUJD", "andere Felder bleiben (wie im Web)")
        XCTAssertNil(PageOrder.clear(&d, key: "p2"), "schon leer")
        XCTAssertNil(PageOrder.clear(&d, key: "fehlt"))
    }

    func testTemplateAndFormatOnlyForBlankPages() throws {
        var d = try doc()
        XCTAssertNotNil(PageOrder.setTemplate(&d, key: "bX", template: "grid"))
        XCTAssertEqual(d.pageOrder[2]["template"], "grid")
        XCTAssertNil(PageOrder.setTemplate(&d, key: "bX", template: "grid"), "schon so")
        PageOrder.setTemplate(&d, key: "bX", template: "unbekannt")
        XCTAssertEqual(d.pageOrder[2]["template"], "blank", "unbekannte Vorlage wie beim Einfuegen")
        XCTAssertNil(PageOrder.setTemplate(&d, key: "p1", template: "grid"), "PDF-Seite bleibt PDF-Seite")
        XCTAssertEqual(d.pageOrder[0]["type"], "pdf")

        let a5 = try XCTUnwrap(PageFormats.size("a5", .landscape))
        XCTAssertNotNil(PageOrder.setFormat(&d, key: "bX", width: Double(a5.width), height: Double(a5.height)))
        XCTAssertEqual(d.pageOrder[2]["w"]?.double, Double(a5.width))
        XCTAssertEqual(d.pageOrder[2]["h"]?.double, Double(a5.height))
        XCTAssertEqual(d.objects(page: "bX").first?["id"], "c", "Objekte bleiben")
        XCTAssertNil(PageOrder.setFormat(&d, key: "p1", width: Double(a5.width), height: Double(a5.height)))
        XCTAssertNil(PageOrder.setFormat(&d, key: "bX", width: 10, height: 10), "ungueltige Groesse")
    }

    func testInsertBeforeAndAtEnd() throws {
        var d = try doc()
        PageOrder.insertBlank(&d, before: "p2", template: "grid", key: "bVor")
        XCTAssertEqual(keys(d), ["p1", "bVor", "p2", "bX"])
        PageOrder.insertBlank(&d, before: "p1", template: "grid", key: "bAnfang")
        XCTAssertEqual(keys(d).first, "bAnfang")
        PageOrder.insertBlank(&d, after: nil, template: "dotted", key: "bEnde")
        XCTAssertEqual(keys(d).last, "bEnde")
        XCTAssertNil(PageOrder.insertBlank(&d, before: "p1", template: "grid", key: "bEnde"), "Schluessel vergeben")
    }

    func testOutlineAddAndRemove() throws {
        var d = try doc()
        XCTAssertEqual(PageOrder.outline(d).map(\.title), ["Kapitel 2"])
        XCTAssertNotNil(PageOrder.addOutline(&d, key: "bX", title: "  Uebung  "))
        XCTAssertEqual(PageOrder.outline(d).map(\.key), ["p2", "bX"])
        XCTAssertEqual(PageOrder.outline(d).last?.title, "Uebung")
        XCTAssertNil(PageOrder.addOutline(&d, key: "bX", title: "   "))
        XCTAssertNil(PageOrder.addOutline(&d, key: "fehlt", title: "x"))
        XCTAssertNotNil(PageOrder.removeOutline(&d, at: 0))
        XCTAssertEqual(PageOrder.outline(d).map(\.key), ["bX"])
        XCTAssertNil(PageOrder.removeOutline(&d, at: 5))
        XCTAssertEqual(d.rootMeta["outline"]?.array?.count, 1, "Gliederung gehoert zur Wurzel (wird mit der Seitenliste gespeichert)")
    }

    // MARK: Gemischte Formate (M6)

    /// Eine A0-Seite unter A4-Seiten: eingepasst wird auf A4 (Median), herauszoomen geht bis zur ganzen A0-Seite.
    /// Gegenprobe: gleich breite Seiten -> Faktor 1, Grenzen wie bisher.
    func testMixedFormatsFitTheTypicalPageNotTheWidest() {
        let a4: CGFloat = 595, a0: CGFloat = 3370
        let factor = ZoomPolicy.mixedFormatFactor(widths: [a4, a4, a0, a4, a4])
        XCTAssertEqual(factor, a0 / a4, accuracy: 1e-9)
        let widestFit: CGFloat = 0.247
        let fit = widestFit * factor
        XCTAssertEqual(fit, 1.399, accuracy: 0.01, "A4 wieder etwa 830 pt breit statt 147 pt")
        let range = ZoomPolicy.limits(fitScale: fit, widestFit: widestFit)
        XCTAssertEqual(range.lowerBound, widestFit, accuracy: 1e-9, "heraus bis zur ganzen A0-Seite")
        XCTAssertEqual(range.upperBound, fit * ZoomPolicy.maxFactor, accuracy: 1e-9)

        XCTAssertEqual(ZoomPolicy.mixedFormatFactor(widths: [a4, a4, a4]), 1)
        XCTAssertEqual(ZoomPolicy.mixedFormatFactor(widths: []), 1)
        XCTAssertEqual(ZoomPolicy.mixedFormatFactor(widths: [0, .nan, a4]), 1, "unbrauchbare Breiten zaehlen nicht")
        XCTAssertEqual(ZoomPolicy.limits(fitScale: 1, widestFit: 1), 0.5...6, "ohne gemischte Formate wie bisher")
        XCTAssertEqual(ZoomPolicy.limits(fitScale: 1), 0.5...6)
    }
}
