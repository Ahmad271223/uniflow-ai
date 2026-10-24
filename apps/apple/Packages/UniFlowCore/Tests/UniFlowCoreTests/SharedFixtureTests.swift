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
