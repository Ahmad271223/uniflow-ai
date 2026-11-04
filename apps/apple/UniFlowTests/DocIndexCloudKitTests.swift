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
