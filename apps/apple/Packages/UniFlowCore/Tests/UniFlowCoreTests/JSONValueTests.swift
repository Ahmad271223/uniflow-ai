import XCTest
@testable import UniFlowCore

final class JSONValueTests: XCTestCase {

    func testParsesWebEditorDocument() throws {
        let text = #"{"version":2,"zoom":1.2,"pages":{"p1":{"objects":[{"id":"a1","type":"stroke","points":[643.73,111.74,648.52,108.54],"widths":[2.05,2.27],"opacity":1,"bold":false,"text":null}]}},"pageOrder":[{"key":"p1","type":"pdf","index":1}]}"#
        let v = try JSONValue.parse(text)
        let o = v["pages"]?["p1"]?["objects"]?.array?.first
        XCTAssertEqual(o?["id"]?.string, "a1")
        XCTAssertEqual(o?["points"]?.array?.first?.double, 643.73)
        XCTAssertEqual(o?["bold"], .bool(false))
        XCTAssertEqual(o?["text"], .null)
        XCTAssertEqual(v["pageOrder"]?.array?.first?["index"]?.int, 1)
    }

    func testRoundTripKeepsValues() throws {
        let original: JSONValue = [
            "a": [1, 2.5, -3.25e-7, 1e21, 0], "b": "Grüße \"zitiert\" \\ / \n\t\u{1}", "c": true, "d": ["x": [:]],
            "e": "😀 emoji", "f": [],
        ]
        let back = try JSONValue.parse(original.serialized())
        XCTAssertEqual(back, original)
        XCTAssertEqual(original.jsonString(sortedKeys: true), back.jsonString(sortedKeys: true))
    }

    func testIntegersWithoutFraction() {
        XCTAssertEqual(JSONValue.number(2).jsonString(), "2")
        XCTAssertEqual(JSONValue.number(-0.0).jsonString(), "0")
        XCTAssertEqual(JSONValue.number(643.73).jsonString(), "643.73")
        XCTAssertEqual(JSONValue.number(.nan).jsonString(), "null")
    }

    func testUnicodeEscapesAndSurrogates() throws {
        let v = try JSONValue.parse(#""üß 😀 €""#)
        XCTAssertEqual(v.string, "üß 😀 €")
        let broken = try JSONValue.parse(#""\ud83d x""#)
        XCTAssertEqual(broken.string, "\u{FFFD} x")
    }

    func testRejectsInvalidInput() {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "01x", "\"abc", "1.", "{\"a\":1}x", "\"a\u{1}\""] {
            XCTAssertThrowsError(try JSONValue.parse(bad), bad)
        }
    }

    func testSortedOutputIsDeterministic() {
        let a: JSONValue = ["z": 1, "a": ["m": 2, "b": 3]]
        XCTAssertEqual(a.jsonString(sortedKeys: true), #"{"a":{"b":3,"m":2},"z":1}"#)
    }

    func testLargeDocumentSpeed() throws {
        let objects = (0..<5000).map { stroke("s\($0)", points: 20) }
        let doc: JSONValue = ["pages": ["p1": ["objects": .array(objects)]]]
        let start = Date()
        let data = doc.serialized()
        let back = try JSONValue.parse(data)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(back["pages"]?["p1"]?["objects"]?.array?.count, 5000)
        // grosszuegige Grenze, damit langsame CI-Rechner (Debug-Build) nicht faelschlich scheitern
        XCTAssertLessThan(seconds, 20, "5000 Striche schreiben + lesen dauerte \(seconds) s")
        print("JSON 5000 Striche (\(data.count / 1024) KB): \(String(format: "%.3f", seconds)) s")
    }
}
