import XCTest
@testable import UniFlowCore

/// Seitenoperationen wie im Web-Editor (addBlankPage, deletePage, restorePage).
final class PageOrderTests: XCTestCase {

    private func doc(_ text: String) throws -> AnnotationDocument { AnnotationDocument(root: try JSONValue.parse(text)) }

    private func threePages() throws -> AnnotationDocument {
        try doc(#"""
        {"version":2,"note":"x","pages":{"p1":{"objects":[]},"p2":{"objects":[{"id":"s1","type":"stroke"}],"pkdrawing":{"data":"QUJD","objectsSig":"sig"}},"p3":{"objects":[]}},
         "pageOrder":[{"key":"p1","type":"pdf","index":1},{"key":"p2","type":"pdf","index":2,"rotation":90},{"key":"p3","type":"pdf","index":3}]}
        """#)
    }

    private func keys(_ d: AnnotationDocument) -> [String] { d.pageOrder.compactMap { $0["key"]?.string } }

    // MARK: Einfuegen

    func testInsertBlankAfterPageWithTemplateAndSize() throws {
        var d = try threePages()
        let c = PageOrder.insertBlank(&d, after: "p1", template: "lined", width: 600, height: 800, key: "bNeu")
        XCTAssertEqual(keys(d), ["p1", "bNeu", "p2", "p3"])
        XCTAssertEqual(c, PageOrder.Change(focusKey: "bNeu", changedPageKeys: ["bNeu"]))
        let e = d.pageOrder[1]
        XCTAssertEqual(e["type"]?.string, "blank")
        XCTAssertEqual(e["template"]?.string, "lined")
        XCTAssertEqual(e["w"]?.double, 600)
        XCTAssertEqual(e["h"]?.double, 800)
        XCTAssertEqual(d.page("bNeu"), ["objects": []])
        XCTAssertEqual(d.root["note"]?.string, "x", "andere Felder bleiben")
    }

    func testInsertWithoutOrUnknownKeyAppendsAndUnknownTemplateIsBlank() throws {
        var d = try threePages()
        PageOrder.insertBlank(&d, after: nil, template: "grid", key: "bA")
        PageOrder.insertBlank(&d, after: "gibtsnicht", template: "wellen", key: "bB")
        XCTAssertEqual(keys(d), ["p1", "p2", "p3", "bA", "bB"])
        XCTAssertEqual(d.pageOrder[4]["template"]?.string, "blank")
        XCTAssertEqual(d.pageOrder[3]["w"]?.double, 595, "Standardgroesse A4 wie im Web")
    }

    func testInsertRefusesTakenKeyAndKeepsExistingPage() throws {
        var d = try threePages()
        XCTAssertNil(PageOrder.insertBlank(&d, after: "p1", template: "blank", key: "p2"))
        d.pages["bAlt"] = ["objects": [["id": "t", "type": "text"]]]
        let c = PageOrder.insertBlank(&d, after: "p3", template: "dotted", key: "bAlt")
        XCTAssertEqual(c?.changedPageKeys, [], "vorhandene Seite wird nicht ueberschrieben")
        XCTAssertEqual(d.objects(page: "bAlt").count, 1)
    }

    func testNewBlankKeyLooksLikeWebKey() throws {
        let k = PageOrder.newBlankKey()
        XCTAssertTrue(k.hasPrefix("b"))
        XCTAssertEqual(k.count, 13)
        XCTAssertTrue(k.dropFirst().allSatisfy { $0.isNumber || ("a"..."z").contains($0) })
        XCTAssertNotEqual(PageOrder.newBlankKey(), PageOrder.newBlankKey())
        var d = try threePages()
        let c = PageOrder.insertBlank(&d, after: "p2", template: "mm")
        XCTAssertEqual(keys(d)[2], c?.focusKey)
    }

    // MARK: Papierkorb

    func testTrashMovesEntryWithObjectsIntoDeletedPages() throws {
        var d = try threePages()
        let now = Date(timeIntervalSince1970: 1_700_000_000.5)
        let c = PageOrder.trash(&d, key: "p2", now: now)
        XCTAssertEqual(keys(d), ["p1", "p3"])
        XCTAssertEqual(c, PageOrder.Change(focusKey: "p3", changedPageKeys: []))
        let del = try XCTUnwrap(d.root["deletedPages"]?.array?.first)
        XCTAssertEqual(del["entry"], ["key": "p2", "type": "pdf", "index": 2, "rotation": 90])
        XCTAssertEqual(del["objects"]?.array?.count, 1)
        XCTAssertEqual(del["pos"]?.int, 1)
        XCTAssertEqual(del["at"]?.double, 1_700_000_000_500)
        XCTAssertNotNil(d.page("p2"), "Seite bleibt in pages wie im Web-Editor")
        let list = PageOrder.trashedPages(d)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].key, "p2")
        XCTAssertEqual(list[0].pdfIndex, 2)
        XCTAssertEqual(list[0].position, 1)
        XCTAssertEqual(list[0].objectCount, 1)
        XCTAssertEqual(list[0].deletedAt, now)
    }

    func testTrashLastPageFocusesPreviousAndKeepsOnePage() throws {
        var d = try threePages()
        XCTAssertEqual(PageOrder.trash(&d, key: "p3")?.focusKey, "p2")
        XCTAssertEqual(PageOrder.trash(&d, key: "p1")?.focusKey, "p2")
        XCTAssertNil(PageOrder.trash(&d, key: "p2"), "letzte Seite bleibt")
        XCTAssertNil(PageOrder.trash(&d, key: "gibtsnicht"))
        XCTAssertEqual(keys(d), ["p2"])
        XCTAssertEqual(PageOrder.trashedPages(d).map(\.key), ["p3", "p1"])
    }

    func testRestorePutsPageBackAtOldPosition() throws {
        var d = try threePages()
        let original = d
        PageOrder.trash(&d, key: "p2")
        let c = PageOrder.restore(&d, key: "p2")
        XCTAssertEqual(c?.focusKey, "p2")
        XCTAssertEqual(c?.changedPageKeys, [], "Objekte unveraendert: Seite muss nicht hochgeladen werden")
        XCTAssertEqual(d.pageOrder, original.pageOrder)
        XCTAssertEqual(d.root["deletedPages"], [])
        XCTAssertEqual(d.page("p2")?["pkdrawing"]?["data"]?.string, "QUJD", "native Zeichnung bleibt")
    }

    func testRestoreClampsPositionAndBringsObjectsBack() throws {
        var d = try threePages()
        PageOrder.trash(&d, key: "p3")
        PageOrder.trash(&d, key: "p2")
        let c = PageOrder.restore(&d, trashIndex: 0)            // p3, frueher an Platz 2, jetzt nur noch 1 Seite
        XCTAssertEqual(keys(d), ["p1", "p3"])
        XCTAssertEqual(c?.changedPageKeys, [])
        PageOrder.restore(&d, key: "p2")
        XCTAssertEqual(keys(d), ["p1", "p2", "p3"])
        XCTAssertNil(PageOrder.restore(&d, key: "p2"), "nichts mehr im Papierkorb")
        XCTAssertNil(PageOrder.restore(&d, trashIndex: 5))
    }

    func testRestoreWritesTrashedObjectsIntoPage() throws {
        var d = try threePages()
        PageOrder.trash(&d, key: "p2")
        d.pages["p2"] = ["objects": [], "extra": true]
        let c = PageOrder.restore(&d, key: "p2")
        XCTAssertEqual(c?.changedPageKeys, ["p2"])
        XCTAssertEqual(d.objects(page: "p2").first?["id"]?.string, "s1")
        XCTAssertEqual(d.page("p2")?["extra"], true, "unbekannte Felder bleiben")
    }

    func testRestoreDoesNotDuplicatePageAlreadyInOrder() throws {
        var d = try threePages()
        PageOrder.trash(&d, key: "p1")
        var order = d.pageOrder
        order.insert(["key": "p1", "type": "pdf", "index": 1], at: 0)   // Zusammenfuehrung brachte p1 zurueck
        d.root["pageOrder"] = .array(order)
        PageOrder.restore(&d, key: "p1")
        XCTAssertEqual(keys(d), ["p1", "p2", "p3"])
        XCTAssertEqual(d.root["deletedPages"], [])
    }

    func testRestoreKeepsObjectsAddedAfterTrashWhenPageAlreadyInOrder() throws {
        var d = try threePages()
        d.pages["p1"] = ["objects": [["id": "alt", "type": "stroke"]]]
        PageOrder.trash(&d, key: "p1")
        var order = d.pageOrder
        order.insert(["key": "p1", "type": "pdf", "index": 1], at: 0)   // Zusammenfuehrung brachte p1 zurueck
        d.root["pageOrder"] = .array(order)
        d.pages["p1"] = ["objects": [["id": "alt", "type": "stroke"], ["id": "neu", "type": "stroke"]]]
        let c = PageOrder.restore(&d, key: "p1")
        XCTAssertEqual(c, PageOrder.Change(focusKey: "p1", changedPageKeys: []))
        XCTAssertEqual(d.objects(page: "p1").compactMap { $0["id"]?.string }, ["alt", "neu"],
                       "Objekte nach dem Loeschen bleiben erhalten")
        XCTAssertEqual(keys(d), ["p1", "p2", "p3"])
        XCTAssertEqual(d.root["deletedPages"], [])
    }

    func testRestoresWebEditorTrashEntry() throws {
        var d = try doc(#"""
        {"version":2,"pages":{"p1":{"objects":[]}},"pageOrder":[{"key":"p1","type":"pdf","index":1}],
         "deletedPages":[{"entry":{"key":"bk2","type":"blank","template":"cornell","w":595,"h":842},"objects":[{"id":"t1","type":"text","text":"Hallo"}],"at":1761300000000,"pos":0}]}
        """#)
        let t = try XCTUnwrap(PageOrder.trashedPages(d).first)
        XCTAssertEqual(t.type, "blank")
        XCTAssertEqual(t.template, "cornell")
        XCTAssertNil(t.pdfIndex)
        let c = PageOrder.restore(&d, key: "bk2")
        XCTAssertEqual(c?.changedPageKeys, ["bk2"], "Seite fehlte in pages und wird angelegt")
        XCTAssertEqual(keys(d), ["bk2", "p1"])
        XCTAssertEqual(d.objects(page: "bk2").first?["text"]?.string, "Hallo")
    }

    // MARK: Groesse und Vorlagen

    func testBaseSizeIgnoresExtraRotationLikeWebBaseSize() {
        XCTAssertTrue(PageOrder.baseSize(shownWidth: 595, shownHeight: 842, extraRotation: 0) == (595, 842))
        XCTAssertTrue(PageOrder.baseSize(shownWidth: 842, shownHeight: 595, extraRotation: 90) == (595, 842))
        XCTAssertTrue(PageOrder.baseSize(shownWidth: 595, shownHeight: 842, extraRotation: 180) == (595, 842))
        XCTAssertTrue(PageOrder.baseSize(shownWidth: 842, shownHeight: 595, extraRotation: 270) == (595, 842))
        XCTAssertTrue(PageOrder.baseSize(shownWidth: 842, shownHeight: 595, extraRotation: -90) == (595, 842))
    }

    func testTemplateStepsAndColorsMatchRenderTemplate() {
        XCTAssertEqual(TemplateGeometry.step("lined"), 24)
        XCTAssertEqual(TemplateGeometry.step("cornell"), 24)
        XCTAssertEqual(TemplateGeometry.step("grid"), 14.17)
        XCTAssertEqual(TemplateGeometry.step("dotted"), 14.17)
        XCTAssertEqual(TemplateGeometry.step("mm"), 2.835)
        XCTAssertEqual(TemplateGeometry.lineColor, "#d9dde8")
        XCTAssertEqual(TemplateGeometry.dotColor, "#c9ced9")
        XCTAssertEqual(TemplateGeometry.cornellRuleColor, "#b9c2d6")
        XCTAssertEqual(TemplateGeometry.cornellLabelColor, "#9aa0ae")
        XCTAssertEqual(TemplateGeometry.cornellPaper, "#fffdf7")
    }

    func testBlankOrUnknownTemplateHasNoGeometry() {
        XCTAssertTrue(TemplateGeometry.make(nil, width: 595, height: 842).isEmpty)
        XCTAssertTrue(TemplateGeometry.make("blank", width: 595, height: 842).isEmpty)
        XCTAssertTrue(TemplateGeometry.make("wellen", width: 595, height: 842).isEmpty)
        XCTAssertTrue(TemplateGeometry.make("lined", width: 0, height: 842).isEmpty)
    }

    func testLinedStartsAt60Every24() {
        let g = TemplateGeometry.make("lined", width: 595, height: 842)
        XCTAssertEqual(g.horizontal.first, 60)
        XCTAssertEqual(g.horizontal[1], 84)
        XCTAssertEqual(g.horizontal.count, 33, "60 + 32 * 24 = 828 < 842, 852 nicht mehr")
        XCTAssertEqual(g.horizontal.last, 828)
        XCTAssertTrue(g.vertical.isEmpty)
        XCTAssertNil(g.cornellFooterY)
        XCTAssertFalse(g.isBold(0))
    }

    func testGridAndMillimeterStartAtZeroAndMmIsBoldEveryTenth() {
        let grid = TemplateGeometry.make("grid", width: 100, height: 50)
        XCTAssertEqual(grid.vertical.count, 8, "0 ... 7 * 14,17 = 99,19")
        XCTAssertEqual(grid.horizontal.count, 4, "0 ... 3 * 14,17 = 42,51")
        XCTAssertEqual(grid.vertical.first, 0)
        XCTAssertFalse(grid.isBold(0))
        let mm = TemplateGeometry.make("mm", width: 595, height: 842)
        XCTAssertEqual(mm.vertical.count, 210, "210 mm Breite (A4)")
        XCTAssertEqual(mm.vertical[10], 28.35, accuracy: 1e-9, "Vielfache, nicht aufsummiert")
        XCTAssertTrue(mm.isBold(0))
        XCTAssertTrue(mm.isBold(20))
        XCTAssertFalse(mm.isBold(5))
    }

    func testDottedStartsOneStepIn() {
        let g = TemplateGeometry.make("dotted", width: 60, height: 30)
        XCTAssertEqual(g.dotColumns, [14.17, 28.34, 14.17 * 3, 14.17 * 4])
        XCTAssertEqual(g.dotRows, [14.17, 28.34])
        XCTAssertTrue(g.horizontal.isEmpty)
        XCTAssertEqual(TemplateGeometry.dotRadius, 0.9)
    }

    func testCornellHasRowsDividerFooterAndLabels() {
        let g = TemplateGeometry.make("cornell", width: 595, height: 842)
        XCTAssertEqual(g.horizontal.first, 60)
        XCTAssertEqual(g.cornellFooterY, 692)
        XCTAssertEqual(TemplateGeometry.cornellDividerX, 150)
        XCTAssertEqual(TemplateGeometry.cornellLabels.map(\.text), ["Stichworte", "Notizen", "Zusammenfassung"])
        XCTAssertEqual(TemplateGeometry.cornellLabels.map(\.x), [12, 162, 12])
        XCTAssertEqual(TemplateGeometry.cornellLabels[2].y, 128)
        XCTAssertTrue(TemplateGeometry.cornellLabels[2].fromBottom)
    }
}
