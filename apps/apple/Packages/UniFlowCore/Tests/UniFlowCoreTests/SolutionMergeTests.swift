import Foundation
import XCTest
@testable import UniFlowCore

/// Zusammenfuehren beim erneuten Teilen zu derselben PDF (03.11.2026): `SolutionBuilder.merge` gegen die gemeinsamen
/// Faelle (packages/shared-contracts/fixtures/solutions/merge-cases.json, Python-Referenz und Browser rechnen sie
/// ebenso nach), dazu die Regeln einzeln und der Weg ueber den StudiNow-Dienst (409, /mine, PUT).
final class SolutionMergeTests: XCTestCase {
    private static let fp = String(repeating: "a", count: 64)
    private static let prevID = "6f1c1c0e-0000-4000-8000-0000000000a1"

    private func cases() throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../../packages/shared-contracts/fixtures/solutions/merge-cases.json")
        return try XCTUnwrap(try JSONValue.parse(Data(contentsOf: url))["cases"]?.array)
    }

    func testSharedCasesMatchThePythonReference() throws {
        let all = try cases()
        XCTAssertGreaterThanOrEqual(all.count, 8)
        for c in all {
            let name = c["name"]?.string ?? "?"
            let previous = try SolutionContent(json: try XCTUnwrap(c["previous"]))
            let new = try SolutionContent(json: try XCTUnwrap(c["new"]))
            if let error = c["error"]?.string {
                XCTAssertEqual(error, "fingerprintMismatch", name)
                XCTAssertThrowsError(try SolutionBuilder.merge(previous: previous, new: new), name) {
                    XCTAssertEqual($0 as? SolutionError, .fingerprintMismatch, name)
                }
                continue
            }
            let merged = try SolutionBuilder.merge(previous: previous, new: new)
            XCTAssertEqual(merged.pages.map(\.key), c["keys"]?.array?.compactMap(\.string), name)
            XCTAssertEqual(merged, try SolutionContent(json: try XCTUnwrap(c["merged"])), name)
        }
    }

    // MARK: Regeln einzeln

    private func stroke(_ id: String) -> JSONValue { .object(["id": .string(id), "type": "stroke", "points": .array([1, 2, 3, 4])]) }

    private func pdf(_ key: String, _ index: Int, _ id: String? = nil) -> SolutionPage {
        SolutionPage(key: key, kind: .pdf, pdfIndex: index, width: 595, height: 842, rotation: 0, objects: [stroke(id ?? key)])
    }

    private func blank(_ key: String, _ id: String? = nil) -> SolutionPage {
        SolutionPage(key: key, kind: .blank, pdfIndex: nil, width: 595, height: 842, rotation: 0, template: "lined", objects: [stroke(id ?? key)])
    }

    private func content(_ pages: [SolutionPage], id: String = prevID, created: String = "2026-10-30T09:00:00Z", title: String = "Blatt 3") -> SolutionContent {
        SolutionContent(solutionID: id, createdAt: created, title: title, displayName: "Lea", fingerprint: Self.fp, pdfPageCount: 12, pages: pages)
    }

    func testNewPageIsAddedAndSamePageReplaced() throws {
        let prev = content([pdf("p1", 1), pdf("p2", 2, "alt")])
        let new = content([pdf("p2", 2, "neu"), pdf("p7", 7)], id: UUID().uuidString.lowercased(), created: "2026-11-03T12:00:00Z", title: "Neu")
        let m = try SolutionBuilder.merge(previous: prev, new: new)
        XCTAssertEqual(m.pages.map(\.key), ["p1", "p2", "p7"])
        XCTAssertEqual(m.pages[1].objects, [stroke("neu")], "dieselbe Seite: die neue Fassung")
        XCTAssertEqual(m.solutionID, Self.prevID, "ID bleibt (Likes, Kommentare)")
        XCTAssertEqual(m.createdAt, "2026-10-30T09:00:00Z")
        XCTAssertEqual(m.title, "Neu")
    }

    func testOrderFollowsThePDFAndBlankPagesStayWithTheirSlide() throws {
        let prev = content([blank("b0"), pdf("p3", 3), blank("b3"), pdf("p8", 8), blank("nb-1")])
        let new = content([pdf("p1", 1), pdf("p5", 5), blank("b5"), blank("b3", "neu")], id: UUID().uuidString.lowercased())
        let m = try SolutionBuilder.merge(previous: prev, new: new)
        // b3 kommt aus der neuen Fassung (gleicher Schluessel) und steht dort hinter Folie 5
        XCTAssertEqual(m.pages.map(\.key), ["b0", "p1", "p3", "p5", "b5", "b3", "p8", "nb-1"])
        XCTAssertEqual(m.pages.first { $0.key == "b3" }?.objects, [stroke("neu")])
    }

    func testSameKeyWithAnotherPDFPageReplacesToo() throws {
        let m = try SolutionBuilder.merge(previous: content([pdf("p1", 1), pdf("p2", 2)]), new: content([pdf("p2", 4)], id: UUID().uuidString.lowercased()))
        XCTAssertEqual(m.pages.map(\.key), ["p1", "p2"])
        XCTAssertEqual(m.pages[1].pdfIndex, 4)
    }

    func testMergeKeepsTheLimits() throws {
        let prev = content((1...1_500).map { pdf("p\($0)", $0) })
        var big = content((1_501...2_001).map { pdf("q\($0)", $0) }, id: UUID().uuidString.lowercased())
        big.pdfPageCount = 3_000
        var prev2 = prev
        prev2.pdfPageCount = 3_000
        XCTAssertThrowsError(try SolutionBuilder.merge(previous: prev2, new: big)) { XCTAssertEqual($0 as? SolutionError, .tooLarge) }
    }
}

// MARK: - StudiNow-Dienst: 409, eigene Loesung, PUT

/// Schein-Dienst mit Antwort je "METHODE pfad"; merkt Aufrufe und Inhalte
private final class RecordingTransport: CommunityTransport, @unchecked Sendable {
    let lock = NSLock()
    var calls: [(String, JSONValue?)] = []
    let reply: @Sendable (String, JSONValue?) throws -> JSONValue

    init(reply: @escaping @Sendable (String, JSONValue?) throws -> JSONValue) { self.reply = reply }

    func community(_ method: String, _ path: String, body: JSONValue?) async throws -> JSONValue {
        lock.withLock { calls.append((method + " " + path, body)) }
        return try reply(method + " " + path, body)
    }
}

private final class NoGroups: CommunityGroupStore, @unchecked Sendable {
    func groups() -> [CommunityStudyGroup] { [] }
    func add(_ group: CommunityStudyGroup) {}
    func remove(code: String) {}
}

final class ServiceCommunityUpdateTests: XCTestCase {
    private let fp = String(repeating: "a", count: 64)
    private let key = String(repeating: "1", count: 64)

    private func service(_ t: CommunityTransport) -> ServiceCommunityService {
        ServiceCommunityService(transport: t, university: "luh", membership: NoGroups(), localFingerprints: { [] }, localCourses: { [] })
    }

    private func communityPackage(id: String = UUID().uuidString.lowercased()) throws -> SolutionPackage {
        let content = SolutionContent(solutionID: id, createdAt: "2026-10-26T10:00:00Z", title: "Blatt", displayName: "Mira", fingerprint: fp, pdfPageCount: 3,
                                      pages: [SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0,
                                                           objects: [.object(["type": "stroke", "points": .array([1, 2, 3, 4])])])])
        return try SolutionPackage.seal(content, communitySecret: CommunityKeys.secret(university: "luh", courseID: "kurs-1"), cipher: TestHMACCipher())
    }

    private static func mine(_ rows: [(String, String, String, String)]) -> JSONValue {
        .object(["solutions": .array(rows.map { id, fp, key, status in
            .object(["solution_id": .string(id), "fingerprint": .string(fp), "community_key": .string(key), "status": .string(status),
                     "published_at": "2026-11-01T10:00:00Z", "mine": true])
        })])
    }

    func testOwnSolutionFindsOnlyTheSamePDFInTheSameCommunity() async throws {
        let other = String(repeating: "2", count: 64)
        let t = RecordingTransport { [fp, key] k, _ in
            XCTAssertEqual(k, "GET /mine")
            return Self.mine([("zurueck", fp, key, "withdrawn"), ("andere-pdf", String(repeating: "e", count: 64), key, "active"),
                              ("andere-community", fp, other, "active"), ("treffer", fp, key, "active")])
        }
        let own = try await service(t).ownSolution(fingerprint: fp.uppercased(), communityKey: key)
        XCTAssertEqual(own?.solutionID, "treffer")
        let none = try await service(t).ownSolution(fingerprint: fp, communityKey: String(repeating: "3", count: 64))
        XCTAssertNil(none)
    }

    func testPublishTwiceThrowsAlreadyPublishedWithTheExistingID() async throws {
        let t = RecordingTransport { [fp, key] k, _ in
            switch k {
            case "POST /solutions": throw AccountError(status: 409, code: "already_published", message: CommunityServiceError.updateQuestion, retryAfter: nil)
            case "GET /mine": return Self.mine([("vorhanden", fp, key, "active")])
            default: return .null
            }
        }
        do {
            _ = try await service(t).publish(try communityPackage(), options: CommunityPublishOptions(communityKey: key))
            XCTFail("Doppel")
        } catch {
            XCTAssertEqual(error as? CommunityServiceError, .alreadyPublished("vorhanden"))
            XCTAssertEqual((error as? CommunityServiceError)?.errorDescription, "Du hast zu dieser PDF schon eine Lösung geteilt. Aktualisieren?")
        }
        XCTAssertEqual(t.calls.map(\.0), ["POST /solutions", "GET /mine"])
    }

    func testUpdateSendsThePackageWithPUTToTheOwnSolution() async throws {
        let id = UUID().uuidString.lowercased()
        let t = RecordingTransport { _, _ in .object(["solution_id": .string(id), "updated_at": "2026-11-03T12:00:00Z", "pages": 3]) }
        let p = try communityPackage(id: id)
        let r = try await service(t).update(solutionID: id, package: p, options: CommunityPublishOptions(title: "Blatt 3", communityKey: key))
        XCTAssertEqual(r.solutionID, id)
        XCTAssertEqual(SolutionPackage.timestamp(r.publishedAt), "2026-11-03T12:00:00Z")
        let (call, body) = try XCTUnwrap(t.calls.first)
        XCTAssertEqual(call.removingPercentEncoding, "PUT /solutions/" + id, "Pfad wie bei Laden und Zurueckziehen (Prozent-kodiert)")
        XCTAssertEqual(body?["community_key"]?.string, key)
        XCTAssertEqual(body?["title"]?.string, "Blatt 3")
        XCTAssertEqual(body?["package"]?["header"]?["solutionId"]?.string, id)
        // ohne Community-Paket nichts senden
        let t2 = RecordingTransport { _, _ in .null }
        do { _ = try await service(t2).update(solutionID: id, package: p, options: CommunityPublishOptions()); XCTFail() } catch {
            XCTAssertEqual(error as? CommunityServiceError, .visibilityUnsupported)
        }
        XCTAssertTrue(t2.calls.isEmpty)
    }

    func testNotConnectedServiceKnowsNoOwnSolution() async throws {
        let none = try await NotConnectedCommunityService().ownSolution(fingerprint: fp, communityKey: key)
        XCTAssertNil(none)
        do { _ = try await NotConnectedCommunityService().update(solutionID: "x", package: try communityPackage(), options: .init()); XCTFail() } catch {
            XCTAssertEqual(error as? CommunityServiceError, .notConnected)
        }
    }
}
