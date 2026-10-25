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
}
