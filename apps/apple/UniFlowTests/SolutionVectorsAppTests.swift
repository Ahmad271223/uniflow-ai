import CryptoKit
import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// Gemeinsame Testvektoren der Loesungspakete (packages/shared-contracts/fixtures/solutions/vectors.json, erzeugt mit
/// tools/gen-solution-vectors.py aus app/solution_format.py) gegen die echte Verschluesselung des iPads
/// (`CryptoKitSolutionCipher`): Pakete aus Python oeffnen, mit festem Salz und Nonce byte-gleich neu versiegeln,
/// Schluessel, AAD und Klartext wie Python; die Negativfaelle scheitern. Gleiche Faelle: tests/test_solution_vectors.py,
/// tests/js/solutions.test.mjs.
final class SolutionVectorsAppTests: XCTestCase {

    private func vectors() throws -> JSONValue {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }          // .../apps/apple/UniFlowTests/<Datei> -> Repository
        return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/solutions/vectors.json")))
    }

    private func bytes(_ v: JSONValue?) throws -> Data { try XCTUnwrap(v?.string.flatMap { Data(base64Encoded: $0) }) }

    private func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined() }

    func testPythonPackagesOpenAndResealByteForByte() throws {
        let v = try vectors()
        XCTAssertEqual(v["format"], "uniflow-solution")
        let cases = try XCTUnwrap(v["cases"]?.array)
        XCTAssertFalse(cases.isEmpty)
        let cipher = CryptoKitSolutionCipher()
        for c in cases {
            let name = c["name"]?.string ?? "?"
            let pdf = try bytes(c["pdf"])
            XCTAssertEqual(cipher.sha256Hex(pdf), c["sha256"]?.string, name)
            let salt = try bytes(c["salt"]), nonce = try bytes(c["nonce"])
            let info = Data(try XCTUnwrap(c["info"]?.string).utf8)
            XCTAssertEqual(hex(CryptoKitSolutionCipher.deriveKey(pdf, salt: salt, info: info)), c["key_hex"]?.string, "\(name): HKDF")

            let text = Data(try XCTUnwrap(c["package_text"]?.string).utf8)
            let package = try SolutionPackage.decode(text)
            XCTAssertEqual(package.authenticatedHeader, Data(try XCTUnwrap(c["aad"]?.string).utf8), "\(name): AAD")
            let content = try package.open(originalPDF: pdf, cipher: cipher)
            XCTAssertEqual(content.json, c["content"], "\(name): Inhalt wie Python")
            XCTAssertEqual(content.json.serialized(sortedKeys: true), Data(try XCTUnwrap(c["plaintext"]?.string).utf8), "\(name): Klartext")

            let resealed = try SolutionPackage.seal(try SolutionContent(json: try XCTUnwrap(c["content"])), originalPDF: pdf, cipher: cipher,
                                                    salt: salt, nonce: nonce)
            XCTAssertEqual(resealed.encoded(), text, "\(name): Paket byte-gleich wie Python")
        }
    }

    func testNegativeVectorsAreRejected() throws {
        let v = try vectors()
        let cases = try XCTUnwrap(v["cases"]?.array)
        let negative = try XCTUnwrap(v["negative"]?.array)
        XCTAssertEqual(negative.count, 4)
        let cipher = CryptoKitSolutionCipher()
        for n in negative {
            let name = n["name"]?.string ?? "?"
            let pdf = try bytes(cases[try XCTUnwrap(n["pdf_of"]?.int)]["pdf"])
            let raw = try XCTUnwrap(n["package"]).serialized(sortedKeys: true)
            XCTAssertThrowsError(try SolutionPackage.decode(raw).open(originalPDF: pdf, cipher: cipher), name)
        }
    }
}
