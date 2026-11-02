import CryptoKit
import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// Gemeinsame Testvektoren der Loesungspakete (packages/shared-contracts/fixtures/solutions/vectors.json, erzeugt mit
/// tools/gen-solution-vectors.py aus app/solution_format.py) gegen die echte Verschluesselung des iPads
/// (`CryptoKitSolutionCipher`) und das Compression-Framework: Pakete der Formatversion 2 aus Python oeffnen (gepackt mit
/// zlib), alte Pakete der Version 1 weiter oeffnen, Schluessel, AAD und Klartext vor dem Packen wie Python, selbst
/// versiegeln und wieder oeffnen (die gepackten Bytes muessen nicht gleich sein); die Negativfaelle scheitern mit dem
/// genannten Fehler. Gleiche Faelle: tests/test_solution_vectors.py, tests/js/solutions.test.mjs.
final class SolutionVectorsAppTests: XCTestCase {

    private func vectors() throws -> JSONValue {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }          // .../apps/apple/UniFlowTests/<Datei> -> Repository
        return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/solutions/vectors.json")))
    }

    private func bytes(_ v: JSONValue?) throws -> Data { try XCTUnwrap(v?.string.flatMap { Data(base64Encoded: $0) }) }

    private func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined() }

    private func text(_ v: JSONValue?) -> String { String(decoding: (v ?? .null).serialized(sortedKeys: true), as: UTF8.self) }

    func testPythonPackagesOpenOldAndNewAndRoundTrip() throws {
        let v = try vectors()
        XCTAssertEqual(v["format"], "uniflow-solution")
        XCTAssertEqual(v["formatVersion"]?.int, SolutionPackage.formatVersion)
        let cases = try XCTUnwrap(v["cases"]?.array), legacy = try XCTUnwrap(v["legacy"]?.array)
        XCTAssertFalse(cases.isEmpty)
        XCTAssertFalse(legacy.isEmpty)
        let cipher = CryptoKitSolutionCipher()
        for c in cases + legacy {
            let name = c["name"]?.string ?? "?"
            let version = try XCTUnwrap(c["formatVersion"]?.int)
            let pdf = try bytes(c["pdf"])
            XCTAssertEqual(cipher.sha256Hex(pdf), c["sha256"]?.string, name)
            let salt = try bytes(c["salt"]), nonce = try bytes(c["nonce"])
            let info = Data(try XCTUnwrap(c["info"]?.string).utf8)
            XCTAssertEqual(SolutionPackage.keyInfo(solutionID: try XCTUnwrap(c["content"]?["solutionId"]?.string), version: version), info, name)
            XCTAssertEqual(hex(CryptoKitSolutionCipher.deriveKey(pdf, salt: salt, info: info)), c["key_hex"]?.string, "\(name): HKDF")

            let text = Data(try XCTUnwrap(c["package_text"]?.string).utf8)
            let package = try SolutionPackage.decode(text)
            XCTAssertEqual(package.formatVersion, version, name)
            XCTAssertEqual(package.encoded(), text, "\(name): Kopf byte-gleich gelesen und geschrieben")
            XCTAssertEqual(package.authenticatedHeader, Data(try XCTUnwrap(c["aad"]?.string).utf8), "\(name): AAD")
            let content = try package.open(originalPDF: pdf, cipher: cipher)
            XCTAssertEqual(self.text(content.json), self.text(c["opened"]), "\(name): Inhalt wie Python")

            guard version == 2 else {
                XCTAssertEqual(self.text(c["opened"]), self.text(c["content"]), "\(name): alte Pakete unveraendert")
                continue
            }
            let original = try SolutionContent(json: try XCTUnwrap(c["content"]))
            XCTAssertEqual(try SolutionWire.encodeContent(original.json).serialized(sortedKeys: true), Data(try XCTUnwrap(c["plaintext"]?.string).utf8),
                           "\(name): Klartext vor dem Packen byte-gleich wie Python")
            let resealed = try SolutionPackage.seal(original, originalPDF: pdf, cipher: cipher, salt: salt, nonce: nonce)
            XCTAssertEqual(resealed.formatVersion, 2)
            XCTAssertEqual(resealed.header.plaintextBytes, package.header.plaintextBytes, name)
            XCTAssertEqual(self.text(try SolutionPackage.decode(resealed.encoded()).open(originalPDF: pdf, cipher: cipher).json), self.text(c["opened"]),
                           "\(name): hin und zurueck")
        }
    }

    func testNegativeVectorsAreRejected() throws {
        let v = try vectors()
        let cases = try XCTUnwrap(v["cases"]?.array)
        let negative = try XCTUnwrap(v["negative"]?.array)
        XCTAssertEqual(negative.count, 9)
        let cipher = CryptoKitSolutionCipher()
        for n in negative {
            let name = n["name"]?.string ?? "?"
            let pdf = try bytes(cases[try XCTUnwrap(n["pdf_of"]?.int)]["pdf"])
            let raw = try XCTUnwrap(n["package"]).serialized(sortedKeys: true)
            XCTAssertThrowsError(try SolutionPackage.decode(raw).open(originalPDF: pdf, cipher: cipher), name) { error in
                let e = (error as? SolutionError)?.withoutPage
                let code: String
                switch e {
                case .tooLarge?: code = "tooLarge"
                case .decryptionFailed?: code = "decryptionFailed"
                case .fingerprintMismatch?: code = "fingerprintMismatch"
                case .invalidHeader?: code = "invalidHeader"
                case .invalidContent?: code = "invalidContent"
                default: code = "\(String(describing: e))"
                }
                XCTAssertEqual(code, n["error"]?.string, name)
            }
        }
    }

    func testCommunityPackageOpensWithTheSecret() throws {
        let c = try XCTUnwrap(try vectors()["community"])
        let cipher = CryptoKitSolutionCipher()
        let secret = CommunityKeys.secret(university: try XCTUnwrap(c["university"]?.string), courseID: try XCTUnwrap(c["course_id"]?.string))
        let package = try SolutionPackage.decode(Data(try XCTUnwrap(c["package_text"]?.string).utf8))
        XCTAssertEqual(text(try package.open(communitySecret: secret, cipher: cipher).json), text(c["opened"]))
        let own = try SolutionPackage.seal(try SolutionContent(json: try XCTUnwrap(c["content"])), communitySecret: secret, cipher: cipher)
        XCTAssertEqual(text(try own.open(communitySecret: secret, cipher: cipher).json), text(c["opened"]))
    }
}
