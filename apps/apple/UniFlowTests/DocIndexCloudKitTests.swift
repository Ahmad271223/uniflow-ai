import Foundation
import UniFlowCore
import XCTest
@testable import UniFlow

/// Dokument-Index ueber CloudKit (DocIndexCloudKit.swift) gegen das nachgebildete CloudKit der Wochentests: speichern,
/// nach Datei-Schluessel lesen, fremde Datensaetze nie ueberschreiben, fremde Formen verwerfen. Kein Netz.
final class DocIndexCloudKitTests: XCTestCase {
    typealias Fake = WeeklyTestCloudKitTests.FakeWeeklyCloud

    func testSaveReadAndNeverOverwriteForeignRecords() async throws {
        let store = WeeklyTestCloudKitTests.Store()
        let a = CloudKitDocIndex(cloud: Fake(store: store, user: "_a")), b = CloudKitDocIndex(cloud: Fake(store: store, user: "_b"))
        let key = String(repeating: "ab", count: 32)
        try await a.save(DocIndexRecord(fileKey: key, page: 0, payload: "c3VtbWFyeQ==", createdAt: "2026-11-04T08:00:00Z"))
        try await a.save(DocIndexRecord(fileKey: key, page: 1, payload: "cGFnZTE=", createdAt: "2026-11-04T08:00:01Z"))
        let read = try await b.records(fileKey: key)
        XCTAssertEqual(read.map(\.page), [0, 1])
        XCTAssertEqual(read.first?.ownerRecordName, "_a")
        XCTAssertEqual(read.first?.version, DocIndexSchema.version)
        // b speichert dieselbe Seite: der Datensatz von a bleibt
        try await b.save(DocIndexRecord(fileKey: key, page: 1, payload: "ZnJlbWQ=", createdAt: "2026-11-04T09:00:00Z"))
        let page1 = try await b.record(fileKey: key, page: 1)
        XCTAssertEqual(page1?.payload, "cGFnZTE=")
        let none = try await b.records(fileKey: String(repeating: "cd", count: 32))
        XCTAssertEqual(none, [])
    }

    /// Verschluesselung mit CryptoKit (wie in der App, `SolutionSharing.cipher`): Rundlauf; eine andere Datei, eine andere
    /// Seite oder ein veraendertes Chiffrat lassen sich nicht lesen; der Klartext steht nirgends im Datensatz
    func testCryptoKitRoundTripAndWrongFileCannotDecrypt() throws {
        let cipher = CryptoKitSolutionCipher()
        let sha = String(repeating: "7", count: 64), other = String(repeating: "8", count: 64)
        let key = try XCTUnwrap(DocIndexFingerprint.fileKey(fileSHA: sha)), otherKey = try XCTUnwrap(DocIndexFingerprint.fileKey(fileSHA: other))
        let hash = DocIndexFingerprint.pageHash(text: "Konvergenz von Folgen und Reihen, Grenzwertsaetze und Beispiele", fileSHA: sha, page: 4)
        let content: JSONValue = ["summary": "Konvergenz.", "terms": ["Grenzwert"], "elements": [], "tasks": []]
        let payload = try DocIndexCrypto.seal(content, fileSHA: sha, pageHash: hash, fileKey: key, page: 4, cipher: cipher)
        XCTAssertEqual(try DocIndexCrypto.open(payload, fileSHA: sha, pageHash: hash, fileKey: key, page: 4, cipher: cipher), content)
        XCTAssertFalse(payload.contains("Konvergenz") || payload.contains("Grenzwert"))
        XCTAssertThrowsError(try DocIndexCrypto.open(payload, fileSHA: other, pageHash: hash, fileKey: otherKey, page: 4, cipher: cipher), "andere Datei")
        XCTAssertThrowsError(try DocIndexCrypto.open(payload, fileSHA: sha, pageHash: hash, fileKey: key, page: 5, cipher: cipher), "andere Seite")
        var raw = try XCTUnwrap(Data(base64Encoded: payload))
        raw[raw.count - 3] ^= 0x01
        XCTAssertThrowsError(try DocIndexCrypto.open(raw.base64EncodedString(), fileSHA: sha, pageHash: hash, fileKey: key, page: 4, cipher: cipher), "veraendert")
        // zweites Versiegeln: neues Salz und neue Nonce, gleicher Inhalt
        let again = try DocIndexCrypto.seal(content, fileSHA: sha, pageHash: hash, fileKey: key, page: 4, cipher: cipher)
        XCTAssertNotEqual(again, payload)
        XCTAssertEqual(try DocIndexCrypto.open(again, fileSHA: sha, pageHash: hash, fileKey: key, page: 4, cipher: cipher), content)
    }

    func testForeignShapeIsIgnored() {
        var r = CommunityRecord(type: DocIndexCloudRecord.type, name: "falsch#3")
        r[DocIndexCloudRecord.Field.fileKey] = .string("k")
        r[DocIndexCloudRecord.Field.page] = .int(1)
        r[DocIndexCloudRecord.Field.payload] = .string("eA==")
        XCTAssertNil(CloudKitDocIndex.record(r), "Name passt nicht zu Schluessel und Seite")
        var ok = CommunityRecord(type: DocIndexCloudRecord.type, name: "k#1")
        ok[DocIndexCloudRecord.Field.fileKey] = .string("k")
        ok[DocIndexCloudRecord.Field.page] = .int(1)
        ok[DocIndexCloudRecord.Field.payload] = .string("")
        XCTAssertNil(CloudKitDocIndex.record(ok), "leeres Chiffrat")
    }
}
