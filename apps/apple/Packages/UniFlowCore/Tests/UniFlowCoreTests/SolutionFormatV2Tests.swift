import Foundation
import XCTest
@testable import UniFlowCore

/// Formatversion 2 (docs/LOESUNGEN-TEILEN.md 3a): Striche als ganze Zahlen, raw DEFLATE mit harter Obergrenze,
/// alte Pakete (Version 1) bleiben lesbar. Gegen die gemeinsamen Testvektoren
/// (packages/shared-contracts/fixtures/solutions/vectors.json, Python-Referenz); die echte AES-Entschluesselung der
/// Python-Pakete prueft die App (UniFlowTests/SolutionVectorsAppTests.swift).
final class SolutionFormatV2Tests: XCTestCase {
    let cipher = TestHMACCipher()

    private func vectors() throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../../packages/shared-contracts/fixtures/solutions/vectors.json")
        return try JSONValue.parse(Data(contentsOf: url))
    }

    private func text(_ v: JSONValue) -> String { String(decoding: v.serialized(sortedKeys: true), as: UTF8.self) }

    private func assertThrows(_ expected: SolutionError, _ name: String = "", _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), name) { XCTAssertEqual($0 as? SolutionError, expected, name) }
    }

    func testVersionsAsInTheVectors() throws {
        let v = try vectors()
        XCTAssertEqual(v["formatVersion"]?.int, SolutionPackage.formatVersion)
        XCTAssertEqual(Set((v["readVersions"]?.array ?? []).compactMap(\.int)), SolutionPackage.readableVersions)
    }

    func testStrokesBecomeIntegersLikePython() throws {
        for c in try XCTUnwrap(try vectors()["stroke_cases"]?.array) {
            let o = try XCTUnwrap(c["object"])
            XCTAssertEqual(text(try SolutionWire.encodeObject(o)), text(try XCTUnwrap(c["wire"])), text(o))
            XCTAssertEqual(text(try SolutionWire.decodeObject(try XCTUnwrap(c["wire"]))), text(try XCTUnwrap(c["opened"])), text(o))
        }
        assertThrows(.invalidContent("reserviertes Feld")) { _ = try SolutionWire.encodeObject(["type": "stroke", "pointsDelta": [1]]) }
        assertThrows(.invalidContent("Strich")) { _ = try SolutionWire.decodeObject(["type": "stroke", "pointsDelta": [1.5]]) }
        assertThrows(.invalidContent("Strich")) { _ = try SolutionWire.decodeObject(["type": "stroke", "pointsDelta": [1e10, 0, 1]]) }
        assertThrows(.invalidContent("Strich")) { _ = try SolutionWire.decodeObject(["type": "stroke", "pointsDelta": [1e300]]) }
        assertThrows(.invalidContent("Strich")) { _ = try SolutionWire.decodeObject(["type": "stroke", "points": [1], "pointsDelta": [1]]) }
        assertThrows(.invalidContent("Strich")) { _ = try SolutionWire.decodeObject(["type": "stroke", "widthsDelta": "x"]) }
    }

    func testPlaintextByteForBytePythonAndInflate() throws {
        for c in try XCTUnwrap(try vectors()["cases"]?.array) {
            let name = c["name"]?.string ?? "?"
            let content = try SolutionContent(json: try XCTUnwrap(c["content"]))
            let plaintext = try SolutionWire.encodeContent(content.json).serialized(sortedKeys: true)
            XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), c["plaintext"]?.string, "\(name): Klartext vor dem Packen wie Python")
            XCTAssertEqual(text(try SolutionWire.normalized(content).json), text(try XCTUnwrap(c["opened"])), "\(name): geoeffnet wie Python")

            let packed = try XCTUnwrap(c["packed"]?.string.flatMap { Data(base64Encoded: $0) })
            XCTAssertEqual(try SolutionDeflate.inflate(packed, limit: plaintext.count), plaintext, "\(name): zlib aus Python entpacken")
            XCTAssertEqual(try SolutionDeflate.inflatePortable(packed, limit: plaintext.count), plaintext, "\(name): auch ohne Compression")
            assertThrows(.tooLarge, name) { _ = try SolutionDeflate.inflate(packed, limit: plaintext.count - 1) }
            assertThrows(.tooLarge, name) { _ = try SolutionDeflate.inflatePortable(packed, limit: plaintext.count - 1) }
        }
    }

    func testOwnDeflateRoundTripAndBrokenData() throws {
        var rng = SystemRandomNumberGenerator()
        var sample = Data(String(repeating: "{\"pointsDelta\":[1203,4410,12,-3,15,2,17,-1]},", count: 4000).utf8)
        sample += Data((0..<70_000).map { _ in UInt8.random(in: 0...255, using: &rng) })      // nicht packbar, ueber 64 KB
        for data in [Data(), Data("a".utf8), sample] {
            let packed = try SolutionDeflate.deflate(data)
            XCTAssertEqual(try SolutionDeflate.inflate(packed, limit: data.count), data)
            XCTAssertEqual(try SolutionDeflate.inflatePortable(packed, limit: data.count), data)
            let stored = SolutionDeflate.storedBlocks(data)
            XCTAssertEqual(try SolutionDeflate.inflate(stored, limit: data.count), data, "unkomprimierte Bloecke (Linux)")
            XCTAssertEqual(try SolutionDeflate.inflatePortable(stored, limit: data.count), data)
        }
        let packed = try SolutionDeflate.deflate(sample)
        XCTAssertLessThan(packed.count, sample.count)
        for broken in [packed.prefix(packed.count / 2), Data([0xFF, 0xFF, 0xFF])] {
            assertThrows(SolutionDeflate.corrupt) { _ = try SolutionDeflate.inflate(Data(broken), limit: sample.count) }
            assertThrows(SolutionDeflate.corrupt) { _ = try SolutionDeflate.inflatePortable(Data(broken), limit: sample.count) }
        }
        // Zusatzbytes nach dem Ende: wie Python und Browser abgewiesen (das Compression-Framework ignoriert sie, siehe
        // SolutionDeflate.process; der Inhalt ist authentifiziert)
        assertThrows(SolutionDeflate.corrupt) { _ = try SolutionDeflate.inflatePortable(packed + Data([1, 2, 3]), limit: sample.count) }
    }

    /// Zip-Bombe: wenige KB, entpackt ueber `maxPlaintextBytes`; das Entpacken bricht an der Grenze ab.
    func testZipBombStopsAtTheLimit() throws {
        let bomb = try SolutionDeflate.deflate(Data(repeating: 0x20, count: SolutionLimits.maxPlaintextBytes + 1))
        XCTAssertLessThan(bomb.count, 200_000)
        assertThrows(.tooLarge) { _ = try SolutionDeflate.inflate(bomb, limit: 4096) }
        assertThrows(.tooLarge) { _ = try SolutionDeflate.inflatePortable(bomb, limit: 4096) }
        assertThrows(.tooLarge) { _ = try SolutionDeflate.inflate(bomb, limit: SolutionLimits.maxPlaintextBytes) }

        // dasselbe als gueltig verschluesseltes Paket mit kleiner Groessenangabe im Kopf
        let pdf = Data("%PDF-1.7 Bombe".utf8)
        let package = try sealRaw(packed: bomb, plaintextBytes: 4096, pdf: pdf)
        assertThrows(.tooLarge) { _ = try SolutionPackage.decode(package).open(originalPDF: pdf, cipher: cipher) }
    }

    /// Paket der Version 2 mit beliebigem Inhalt (wie von einem fremden Programm erzeugt), mit dem Testverfahren.
    private func sealRaw(packed: Data, plaintextBytes: Int, pdf: Data, id: String = "6f1c1c0e-6a63-4c38-9a0b-6c0f0f7b9a11") throws -> Data {
        let header = SolutionHeader(solutionID: id, createdAt: "2026-10-25T10:00:00Z", displayName: "",
                                    fingerprint: SolutionSHA256.hex(pdf), pdfPageCount: 3, pageCount: 1, imageCount: 0,
                                    missingImageCount: 0, salt: Data(repeating: 1, count: 32), nonce: Data(repeating: 2, count: 12),
                                    plaintextBytes: plaintextBytes, compressedBytes: packed.count)
        var p = SolutionPackage(header: header, ciphertext: Data())
        XCTAssertEqual(p.formatVersion, 2)
        p.ciphertext = try cipher.seal(packed, keyMaterial: pdf, salt: header.salt, info: SolutionPackage.keyInfo(solutionID: id),
                                       nonce: header.nonce, aad: p.authenticatedHeader)
        return p.encoded()
    }

    private func sealRaw(wire: String, pdf: Data, plaintextBytes: Int? = nil) throws -> Data {
        let plain = Data(wire.utf8)
        return try sealRaw(packed: try SolutionDeflate.deflate(plain), plaintextBytes: plaintextBytes ?? plain.count, pdf: pdf)
    }

    private func wire(_ objects: String, version: Int = 2, pdf: Data) -> String {
        #"{"format":"uniflow-solution-content","formatVersion":\#(version),"solutionId":"6f1c1c0e-6a63-4c38-9a0b-6c0f0f7b9a11","createdAt":"2026-10-25T10:00:00Z","title":"T","displayName":"","document":{"sha256":"\#(SolutionSHA256.hex(pdf))","pageCount":3},"pages":[{"key":"p1","kind":"pdf","pdfIndex":1,"width":595,"height":842,"rotation":0,"extraRotation":0,"objects":\#(objects)}],"images":{},"missingImages":[]}"#
    }

    func testForeignVersion2PackagesAreCheckedStrictly() throws {
        let pdf = Data("%PDF-1.7 fremd".utf8)
        let ok = try SolutionPackage.decode(try sealRaw(wire: wire(#"[{"type":"stroke","pointsDelta":[100,200,5,-5],"widthsDelta":[150,10]}]"#, pdf: pdf), pdf: pdf))
            .open(originalPDF: pdf, cipher: cipher)
        XCTAssertEqual(ok.pages[0].objects[0], ["type": "stroke", "points": [10, 20, 10.5, 19.5], "widths": [1.5, 1.6]])

        func rejected(_ data: Data, _ expected: SolutionError, _ name: String) {
            assertThrows(expected, name) { _ = try SolutionPackage.decode(data).open(originalPDF: pdf, cipher: cipher) }
        }
        let text = wire(#"[{"type":"text","text":"hi"}]"#, pdf: pdf)
        rejected(try sealRaw(wire: text, pdf: pdf, plaintextBytes: text.utf8.count + 1), .invalidContent("Größe"), "entpackt kleiner als angegeben")
        rejected(try sealRaw(wire: text, pdf: pdf, plaintextBytes: text.utf8.count - 1), .tooLarge, "entpackt groesser als angegeben")
        rejected(try sealRaw(wire: wire(#"[{"type":"stroke","points":[1,2],"pointsDelta":[1,2]}]"#, pdf: pdf), pdf: pdf), .invalidContent("Strich"), "beides")
        rejected(try sealRaw(wire: wire("[]", version: 1, pdf: pdf), pdf: pdf), .unsupportedVersion(1), "Inhalt Version 1 im Paket Version 2")
        rejected(try sealRaw(wire: wire(#"[{"type":"stroke","pointsDelta":[1e999]}]"#, pdf: pdf), pdf: pdf), .invalidContent("Strich"), "unendlich")
        rejected(try sealRaw(packed: Data([0xFF, 0xFF]), plaintextBytes: 10, pdf: pdf), .invalidContent("Kompression"), "kein DEFLATE")
    }

    func testHeaderOfEachVersionIsExact() throws {
        let pdf = Data("%PDF-1.7 Kopf".utf8)
        let good = try SolutionPackage.decode(try sealRaw(wire: wire("[]", pdf: pdf), pdf: pdf))
        func mutated(_ change: (inout JSONValue) -> Void) throws -> Data {
            var root = try JSONValue.parse(good.encoded())
            change(&root)
            return root.serialized(sortedKeys: true)
        }
        func rejected(_ data: Data, _ expected: SolutionError) { assertThrows(expected) { _ = try SolutionPackage.decode(data) } }
        rejected(try mutated { $0["formatVersion"] = 3 }, .unsupportedVersion(3))
        rejected(try mutated { $0["header"]?["encryption"]?["compression"] = "zstd" }, .invalidHeader("Kompression"))
        rejected(try mutated { $0["header"]?["encryption"]?["compression"] = nil }, .invalidHeader("Kompression"))
        rejected(try mutated { $0["header"]?["encryption"]?["compressedBytes"] = .number(Double(good.header.compressedBytes! + 1)) }, .invalidHeader("Größe"))
        rejected(try mutated { $0["header"]?["encryption"]?["compressedBytes"] = 1e300 }, .invalidHeader("Größe"))
        rejected(try mutated { $0["header"]?["encryption"]?["plaintextBytes"] = .number(Double(SolutionLimits.maxPlaintextBytes + 1)) }, .invalidHeader("Größe"))
        // Version 1 mit Kompressionsangaben (oder Version 2 ohne): kein gueltiger Kopf
        rejected(try mutated { $0["formatVersion"] = 1 }, .invalidHeader("unbekannte Felder"))
    }

    func testSealWritesVersion2AndOpensToTheNormalizedContent() throws {
        let pdf = Data("%PDF-1.7 hin und zurueck".utf8)
        let points: [JSONValue] = (0..<400).map { .number(100 + 30 * sin(Double($0) / 9) + Double($0 % 7) * 0.013) }
        let content = SolutionContent(solutionID: "6f1c1c0e-6a63-4c38-9a0b-6c0f0f7b9a11", createdAt: "2026-11-02T10:00:00Z", title: "T",
                                      displayName: "", fingerprint: SolutionSHA256.hex(pdf), pdfPageCount: 1,
                                      pages: [SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0,
                                                           objects: [["id": "s", "type": "stroke", "points": .array(points),
                                                                      "widths": .array(points.prefix(200).map { .number($0.double! / 50) })]])])
        let sealed = try SolutionPackage.seal(content, originalPDF: pdf, cipher: cipher)
        XCTAssertEqual(sealed.formatVersion, 2)
        XCTAssertLessThan(try XCTUnwrap(sealed.header.compressedBytes), sealed.header.plaintextBytes)
        let text = String(decoding: sealed.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains(#""formatVersion":2"#) && text.contains(#""compression":"deflate-raw""#))
        let opened = try SolutionPackage.decode(sealed.encoded()).open(originalPDF: pdf, cipher: cipher)
        XCTAssertEqual(opened, try SolutionWire.normalized(content))
        let a = content.pages[0].objects[0]["points"]!.array!.map(\.double!), b = opened.pages[0].objects[0]["points"]!.array!.map(\.double!)
        XCTAssertEqual(a.count, b.count)
        XCTAssertLessThanOrEqual(zip(a, b).map { abs($0 - $1) }.max()!, 0.05 + 1e-9, "hoechstens 0,05 Punkt Abweichung")
        XCTAssertEqual(try SolutionPackage.seal(opened, originalPDF: pdf, cipher: cipher, salt: sealed.header.salt, nonce: sealed.header.nonce)
                        .open(originalPDF: pdf, cipher: cipher), opened, "zweimal teilen aendert nichts mehr")
    }

    func testVersion1PackagesStillOpen() throws {
        let legacy = try XCTUnwrap(try vectors()["legacy"]?.array?.first)
        let pdf = try XCTUnwrap(legacy["pdf"]?.string.flatMap { Data(base64Encoded: $0) })
        let plaintext = Data(try XCTUnwrap(legacy["plaintext"]?.string).utf8)
        // das Python-Paket hat einen Kopf der Version 1: genau so lesen und byte-gleich wieder schreiben
        let python = try SolutionPackage.decode(Data(try XCTUnwrap(legacy["package_text"]?.string).utf8))
        XCTAssertEqual(python.formatVersion, 1)
        XCTAssertNil(python.header.compressedBytes)
        XCTAssertEqual(String(decoding: python.encoded(), as: UTF8.self), legacy["package_text"]?.string)
        XCTAssertEqual(String(decoding: python.authenticatedHeader, as: UTF8.self), legacy["aad"]?.string)
        XCTAssertEqual(String(decoding: SolutionPackage.keyInfo(solutionID: python.header.solutionID, version: 1), as: UTF8.self), legacy["info"]?.string)
        // mit dem Testverfahren als Version 1 versiegelt: oeffnet unveraendert (Punkte nicht gerundet)
        var p = SolutionPackage(header: python.header, ciphertext: Data())
        p.ciphertext = try cipher.seal(plaintext, keyMaterial: pdf, salt: p.header.salt,
                                       info: SolutionPackage.keyInfo(solutionID: p.header.solutionID, version: 1), nonce: p.header.nonce,
                                       aad: p.authenticatedHeader)
        let opened = try SolutionPackage.decode(p.encoded()).open(originalPDF: pdf, cipher: cipher)
        XCTAssertEqual(text(opened.json), text(try XCTUnwrap(legacy["content"])))
    }
}
