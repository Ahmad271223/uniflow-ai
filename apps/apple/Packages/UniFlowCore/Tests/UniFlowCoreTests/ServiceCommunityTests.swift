import Foundation
import XCTest
@testable import UniFlowCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let pdfA = String(repeating: "a", count: 64), pdfB = String(repeating: "b", count: 64)

private func package(_ fingerprint: String, name: String = "Mira") throws -> SolutionPackage {
    let ct = Data(repeating: 7, count: 48)
    let j: JSONValue = .object([
        "format": .string("uniflow-solution"), "formatVersion": .number(1), "ciphertext": .string(ct.base64EncodedString()),
        "header": .object([
            "solutionId": .string(UUID().uuidString.lowercased()), "createdAt": .string("2026-10-26T10:00:00Z"), "displayName": .string(name),
            "document": .object(["sha256": .string(fingerprint), "pageCount": .number(12)]),
            "contents": .object(["pages": .number(2), "images": .number(0), "missingImages": .number(0)]),
            "encryption": .object(["cipher": .string("AES-256-GCM"), "kdf": .string("HKDF-SHA256"), "keyMaterial": .string("original-pdf-bytes"),
                                   "salt": .string(Data(repeating: 1, count: 32).base64EncodedString()),
                                   "nonce": .string(Data(repeating: 2, count: 12).base64EncodedString()), "plaintextBytes": .number(32)]),
        ]),
    ])
    return try SolutionPackage.decode(j.serialized())
}

/// Schein-Dienst: Antworten je Aufruf, merkt die Aufrufe
private final class FakeTransport: CommunityTransport, @unchecked Sendable {
    let lock = NSLock()
    var calls: [String] = []
    let reply: @Sendable (String, Int) throws -> JSONValue

    init(reply: @escaping @Sendable (String, Int) throws -> JSONValue) { self.reply = reply }

    func community(_ method: String, _ path: String, body: JSONValue?) async throws -> JSONValue {
        let key = method + " " + path
        let n: Int = lock.withLock { calls.append(key); return calls.filter { $0 == key }.count }
        return try reply(key, n)
    }
}

private func service(_ t: CommunityTransport, local: [String] = [pdfA], course: [String] = []) -> ServiceCommunityService {
    ServiceCommunityService(transport: t, localFingerprints: { local }, courseFingerprints: { _ in course })
}

private let notOwned = AccountError(status: 403, code: "file_not_owned", message: "Diese PDF stammt nicht aus deinem Hochschul-Abgleich.", retryAfter: nil)

final class ServiceCommunityTests: XCTestCase {
    func testStudyGroupsNeverPublishForEveryone() async throws {
        let t = FakeTransport { _, _ in .null }
        let s = service(t)
        for v in [CommunityVisibility.studyGroup, .anonymous] {
            do {
                _ = try await s.publish(try package(pdfA), options: CommunityPublishOptions(visibility: v, groupKey: "g"))
                XCTFail("durfte nicht veroeffentlichen")
            } catch { XCTAssertEqual(error as? CommunityServiceError, .visibilityUnsupported) }
        }
        XCTAssertEqual(t.calls, [])
        let groups = try await s.studyGroups()
        XCTAssertEqual(groups, [])
    }

    func testUnknownPDFClaimsOnceAndRetries() async throws {
        let t = FakeTransport { key, n in
            if key.hasPrefix("GET"), n == 1 { throw notOwned }
            return .object(["solutions": .array([])])
        }
        let list = try await service(t).findMatching(fingerprint: pdfA.uppercased())
        XCTAssertEqual(list, [])
        XCTAssertEqual(t.calls, ["GET /solutions?fingerprint=\(pdfA)", "POST /claims", "GET /solutions?fingerprint=\(pdfA)"])
    }

    func testStillUnknownOrNothingToClaimIsAnError() async throws {
        let t = FakeTransport { key, _ in
            if key.hasPrefix("GET") { throw notOwned }
            return .null
        }
        do { _ = try await service(t).findMatching(fingerprint: pdfA); XCTFail() } catch {
            XCTAssertEqual(error as? CommunityServiceError, .fileNotOwned)
        }
        XCTAssertEqual(t.calls.count, 3)
        let empty = FakeTransport { _, _ in throw notOwned }
        do { _ = try await service(empty, local: []).findMatching(fingerprint: pdfA); XCTFail() } catch {
            XCTAssertEqual(error as? CommunityServiceError, .fileNotOwned)
        }
        XCTAssertEqual(empty.calls.count, 1)
    }

    func testErrorsAreMapped() {
        func map(_ status: Int, _ code: String) -> CommunityServiceError? {
            ServiceCommunityService.serviceError(AccountError(status: status, code: code, message: "M", retryAfter: nil)) as? CommunityServiceError
        }
        XCTAssertEqual(map(0, "service_unreachable"), .offline)
        XCTAssertEqual(map(401, "unauthenticated"), .accountRequired)
        XCTAssertEqual(map(404, "not_found"), .notFound)
        XCTAssertEqual(map(403, "not_owner"), .notOwner)
        XCTAssertEqual(map(403, "plan_required"), .server("M"))
    }

    func testCourseAsksEachFingerprintSkipsForeignPDFButShowsRealErrors() async throws {
        func row(_ id: String, _ at: String) -> JSONValue {
            .object(["solution_id": .string(id), "fingerprint": .string(pdfA), "created_at": .string(at), "pseudonym": .string("p"), "mine": .bool(false)])
        }
        let ok = FakeTransport { key, _ in
            if key.contains(pdfB) { throw AccountError(status: 403, code: "file_not_owned", message: "", retryAfter: nil) }
            return .object(["solutions": .array([row("1", "2026-10-01"), row("2", "2026-10-02")])])
        }
        let list = try await service(ok, local: [], course: [pdfA, pdfB, pdfA.uppercased()]).findForCourse(courseKey: "k")
        XCTAssertEqual(list.map(\.solutionID), ["2", "1"])
        XCTAssertEqual(ok.calls.count, 2)
        let bad = FakeTransport { _, _ in throw AccountError(status: 500, code: "http_500", message: "kaputt", retryAfter: nil) }
        do { _ = try await service(bad, course: [pdfA]).findForCourse(courseKey: "k"); XCTFail() } catch {
            XCTAssertEqual(error as? CommunityServiceError, .server("kaputt"))
        }
    }

    func testBlockNeedsASeenSolution() async {
        let s = service(FakeTransport { _, _ in .null })
        do { try await s.block(owner: "unbekannt"); XCTFail() } catch { XCTAssertEqual(error as? CommunityServiceError, .notFound) }
    }
}

// Gegen den echten Dienst (tools/g2-testdienst.py); ohne G2_TEST_SERVICE uebersprungen.

private struct LiveHTTP: ServiceHTTPTransport {
    func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
        var q = URLRequest(url: URL(string: r.url)!)
        q.httpMethod = r.method
        q.httpBody = r.body
        for (k, v) in r.headers { q.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await URLSession.shared.data(for: q)
        return ServiceHTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: d)
    }
}

private final class MemoryTokens: AccountTokenStore, @unchecked Sendable {
    var token: String?
    init(_ t: String?) { token = t }
    func load() -> String? { token }
    func save(_ token: String?) throws { self.token = token }
}

final class ServiceCommunityLiveTests: XCTestCase {
    private func member(plan: String = "plus", pdfs: [String]) async throws -> ServiceCommunityService {
        guard let base = ProcessInfo.processInfo.environment["G2_TEST_SERVICE"] else { throw XCTSkip("G2_TEST_SERVICE fehlt") }
        let r = try await LiveHTTP().send(AIHTTPRequest(method: "POST", url: base + "/__test/account", headers: ["Content-Type": "application/json"],
                                                        body: JSONValue.object(["plan": .string(plan)]).serialized()))
        let token = try XCTUnwrap(try JSONValue.parse(r.body)["token"]?.string)
        let account = StudoraAccount(base: base, http: LiveHTTP(), tokens: MemoryTokens(token), deviceID: "ipad-" + UUID().uuidString, deviceName: "Test")
        return service(account, local: pdfs, course: pdfs)
    }

    private func randomPDF() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().padding(toLength: 64, withPad: "0", startingAt: 0) }

    func testPublishFindDownloadReportBlockWithdraw() async throws {
        let pdf = randomPDF()
        let author = try await member(pdfs: [pdf]), reader = try await member(plan: "free", pdfs: [pdf])
        let p = try package(pdf)
        let pub = try await author.publish(p, options: CommunityPublishOptions(title: "Blatt 1"))
        XCTAssertEqual(pub.solutionID, p.header.solutionID)

        let found = try await reader.findMatching(fingerprint: pdf)
        let hit = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(hit.title, "Blatt 1")
        XCTAssertEqual(hit.displayName, "Mira")
        XCTAssertFalse(hit.isOwn)
        let own = try await author.findMatching(fingerprint: pdf)
        XCTAssertEqual(own.first?.isOwn, true)
        let loaded = try await reader.download(solutionID: pub.solutionID)
        XCTAssertEqual(loaded, p)

        do { try await reader.withdraw(solutionID: pub.solutionID); XCTFail() } catch { XCTAssertEqual(error as? CommunityServiceError, .notOwner) }
        try await reader.report(solutionID: pub.solutionID, reason: .spam, note: "Test")

        try await reader.block(owner: hit.ownerRecordName)
        let blocked = try await reader.blockedOwners()
        XCTAssertEqual(blocked, [hit.ownerRecordName])
        let hidden = try await reader.findMatching(fingerprint: pdf)
        XCTAssertEqual(hidden, [])
        try await reader.unblock(owner: hit.ownerRecordName)
        let course = try await reader.findForCourse(courseKey: "k")
        XCTAssertEqual(course.map(\.solutionID), [pub.solutionID])

        try await author.withdraw(solutionID: pub.solutionID)
        let gone = try await reader.findMatching(fingerprint: pdf)
        XCTAssertEqual(gone, [])
        do { _ = try await reader.download(solutionID: pub.solutionID); XCTFail() } catch { XCTAssertEqual(error as? CommunityServiceError, .notFound) }
    }

    func testFreeCannotPublishAndForeignPDFStaysClosed() async throws {
        let pdf = randomPDF()
        let free = try await member(plan: "free", pdfs: [pdf])
        do {
            _ = try await free.publish(try package(pdf), options: CommunityPublishOptions())
            XCTFail()
        } catch { guard case .server = error as? CommunityServiceError else { return XCTFail("\(error)") } }
        do { _ = try await free.findMatching(fingerprint: randomPDF()); XCTFail() } catch {
            XCTAssertEqual(error as? CommunityServiceError, .fileNotOwned)
        }
    }
}
