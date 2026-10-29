import Foundation
import XCTest
@testable import UniFlowCore

/// Gemeinsame Testfaelle aus packages/shared-contracts (gleiche Erwartungen wie im Web-Editor).
final class SharedFixtureTests: XCTestCase {

    private func repoFile(_ relative: String) throws -> Data {
        // .../apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/SharedFixtureTests.swift -> Repository-Wurzel
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    func testMergeCasesMatchWebEditor() throws {
        let fixture = try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/merge/cases.json"))
        let cases = fixture["cases"]?.array ?? []
        XCTAssertGreaterThan(cases.count, 5)
        func page(_ v: JSONValue?) -> JSONValue? { (v == nil || v == .null) ? nil : v }
        for c in cases {
            let name = c["name"]?.string ?? "?"
            let r = AnnotationMerge.mergePage(base: page(c["base"]), local: page(c["local"]), server: page(c["server"]))
            if c["expectIds"] == .null {
                XCTAssertNil(r.page, name)
            } else {
                let ids: [JSONValue] = (r.page?["objects"]?.array ?? []).map { $0["id"] ?? .null }
                XCTAssertEqual(ids, c["expectIds"]?.array ?? [], name)
            }
            XCTAssertEqual(r.conflicts, c["expectConflicts"]?.int, name)
            if let f = c["expectField"], let i = f["index"]?.int, let k = f["key"]?.string {
                XCTAssertEqual(r.page?["objects"]?.array?[i][k], f["value"], name)
            }
            if let f = c["expectPageField"], let k = f["key"]?.string {
                XCTAssertEqual(r.page?[k], f["value"], name)
            }
        }
    }

    /// Drehen ohne Verrutschen (P0-7): dieselben Faelle wie app/static/pagerotate.js (tests/js/rotate.test.mjs)
    func testRotateCasesMatchWebEditor() throws {
        let fixture = try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/rotate/cases.json"))
        let cases = fixture["cases"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 7)
        for c in cases {
            let got = PageRotation.rotate(c["objects"]?.array ?? [], width: c["width"]?.double ?? 0,
                                          height: c["height"]?.double ?? 0, degrees: c["deg"]?.int ?? 0)
            XCTAssertEqual(got, c["expect"]?.array ?? [], c["name"]?.string ?? "?")
        }
        // Die Abbildung fuer die native Zeichnung passt zu den Objekten: Ursprung (0, 0) landet wie x/y
        let t = PageRotation.transform(width: 595, height: 842, degrees: 270)
        let p = t.apply(x: 0, y: 0)
        XCTAssertEqual(p.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p.y, 595, accuracy: 1e-9)
        let q = PageRotation.transform(width: 595, height: 842).apply(x: 40.5, y: 120.25)
        XCTAssertEqual(q.x, 721.75, accuracy: 1e-9)
        XCTAssertEqual(q.y, 40.5, accuracy: 1e-9)
    }

    /// `documentCases`: dieselben 18 Faelle wie Web (tests/test_merge_contract.py) und Kotlin
    /// (SharedFixtureTest.documentCasesMatchOtherPlatforms) fuer `mergeDocument`
    func testDocumentCasesMatchOtherPlatforms() throws {
        let fixture = try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/merge/cases.json"))
        let cases = fixture["documentCases"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        XCTAssertTrue(cases.contains { $0["expectOrderConflict"] == true }, "mindestens ein sichtbarer Reihenfolge-Konflikt")
        func doc(_ v: JSONValue?) -> JSONValue? { (v == nil || v == .null) ? nil : v }
        for c in cases {
            let name = c["name"]?.string ?? "?"
            let r = AnnotationMerge.mergeDocument(base: doc(c["base"]), local: doc(c["local"]), server: doc(c["server"]))
            let order = r.doc["pageOrder"]?.array?.compactMap(AnnotationMerge.keyOf) ?? []
            XCTAssertEqual(order, c["expectOrder"]?.array?.compactMap(\.string) ?? [], name)
            XCTAssertEqual(r.doc["deletedPages"]?.array?.compactMap(AnnotationMerge.keyOf) ?? [], c["expectTrash"]?.array?.compactMap(\.string) ?? [], name)
            XCTAssertEqual(r.conflicts, c["expectConflicts"]?.int, name)
            XCTAssertEqual(r.orderConflict, c["expectOrderConflict"]?.bool, name)
            let pages = r.doc["pages"]?.object ?? [:]
            XCTAssertTrue(order.allSatisfy { pages[$0] != nil }, "\(name): jede Seite der Reihenfolge hat Inhalt")
            for (k, ids) in c["expectPageIds"]?.object ?? [:] {
                XCTAssertEqual(pages[k]?["objects"]?.array?.map { $0["id"] ?? .null }, ids.array, "\(name): \(k)")
            }
            if let e = c["expectEntry"], let key = e["key"]?.string, let field = e["field"]?.string {
                let entry = r.doc["pageOrder"]?.array?.first { AnnotationMerge.keyOf($0) == key }
                XCTAssertEqual(entry?[field], e["value"], name)
            }
            if let note = c["expectNote"] { XCTAssertEqual(r.doc["note"], note, name) }
            if let bm = c["expectBookmarks"] { XCTAssertEqual(r.doc["bookmarks"], bm, name) }
        }
    }

    func testWebEditorDocumentFixture() throws {
        let doc = AnnotationDocument(root: try JSONValue.parse(repoFile("packages/shared-contracts/fixtures/documents/web-editor.json")))
        XCTAssertEqual(doc.pageKey(forPDFIndex: 1), "p1")
        XCTAssertEqual(doc.insertedPageCount, 1)
        XCTAssertEqual(doc.objects(page: "p1").count, 3)
        // verlustfrei: einlesen und wieder schreiben ergibt denselben Inhalt
        let again = try JSONValue.parse(doc.root.serialized())
        XCTAssertEqual(again, doc.root)
    }
}
