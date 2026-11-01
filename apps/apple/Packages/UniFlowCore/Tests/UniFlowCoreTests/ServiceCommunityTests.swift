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

private final class MemoryGroups: CommunityGroupStore, @unchecked Sendable {
    var list: [CommunityStudyGroup] = []
    func groups() -> [CommunityStudyGroup] { list }
    func add(_ group: CommunityStudyGroup) { list.append(group) }
    func remove(code: String) { list.removeAll { $0.code == code } }
}

private func service(_ t: CommunityTransport, local: [String] = [pdfA], courses: [CommunitySpace] = []) -> ServiceCommunityService {
    ServiceCommunityService(transport: t, university: "luh", membership: MemoryGroups(), localFingerprints: { local }, localCourses: { courses })
}

final class ServiceCommunityTests: XCTestCase {
    func testNothingIsPublishedWithoutACommunityPackage() async throws {
        let t = FakeTransport { _, _ in .null }
        do {
            _ = try await service(t).publish(try package(pdfA), options: CommunityPublishOptions(communityKey: "k"))
            XCTFail("an die PDF gebundenes Paket darf nicht in die Community")
        } catch { XCTAssertEqual(error as? CommunityServiceError, .visibilityUnsupported) }
        XCTAssertEqual(t.calls, [])
    }

    func testCommunitiesClaimCoursesAndMergeTheServiceState() async throws {
        let course = CommunitySpace.course(university: "luh", id: "kurs-1", title: "Analysis")
        let t = FakeTransport { key, _ in
            guard key == "GET /communities" else { return .null }
            return .object(["communities": .array([.object(["community_key": .string(course.key), "joined": .bool(true), "members": 3, "solutions": 2])])])
        }
        let list = try await service(t, courses: [course]).communities()
        XCTAssertEqual(t.calls, ["POST /claims", "GET /communities"])
        XCTAssertEqual(list.map(\.name), ["Analysis"])
        XCTAssertEqual(list.first?.joined, true)
        XCTAssertEqual(list.first?.members, 3)
        XCTAssertEqual(list.first?.secret, CommunityKeys.secret(university: "luh", courseID: "kurs-1"))
    }

    func testNoCommunityYetFindsNothingInsteadOfFailing() async throws {
        let t = FakeTransport { _, _ in throw AccountError(status: 403, code: "file_not_owned", message: "x", retryAfter: nil) }
        let list = try await service(t).findMatching(fingerprint: pdfA)
        XCTAssertEqual(list, [])
    }

    func testErrorsAreMapped() {
        func map(_ status: Int, _ code: String) -> CommunityServiceError? {
            ServiceCommunityService.serviceError(AccountError(status: status, code: code, message: "M", retryAfter: nil)) as? CommunityServiceError
        }
        XCTAssertEqual(map(0, "service_unreachable"), .offline)
        XCTAssertEqual(map(401, "unauthenticated"), .accountRequired)
        XCTAssertEqual(map(404, "not_found"), .notFound)
        XCTAssertEqual(map(404, "group_not_found"), .groupNotFound)
        XCTAssertEqual(map(403, "not_owner"), .notOwner)
        XCTAssertEqual(map(403, "not_a_member"), .notAMember)
        XCTAssertEqual(map(403, "plan_required"), .server("M"))
    }

    func testBlockNeedsASeenSolution() async {
        let s = service(FakeTransport { _, _ in .null })
        do { try await s.block(owner: "unbekannt"); XCTFail() } catch { XCTAssertEqual(error as? CommunityServiceError, .notFound) }
    }

    func testSecretMatchesTheSharedVectorAndOpensWithoutThePDF() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../../packages/shared-contracts/fixtures/solutions/vectors.json")
        let c = try XCTUnwrap(try JSONValue.parse(Data(contentsOf: url))["community"])
        let uni = try XCTUnwrap(c["university"]?.string)
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(CommunityKeys.secret(university: uni, courseID: try XCTUnwrap(c["course_id"]?.string))), c["secret_hex"]?.string)
        XCTAssertEqual(hex(CommunityKeys.secret(university: uni, groupCode: try XCTUnwrap(c["code"]?.string))), c["group_secret_hex"]?.string)

        let pack = try SolutionPackage.decode(try XCTUnwrap(c["package_text"]?.string).data(using: .utf8)!)
        XCTAssertTrue(pack.header.isCommunityPackage)
        XCTAssertEqual(String(decoding: pack.encoded(), as: UTF8.self), c["package_text"]?.string, "Kopf bleibt byte-gleich")

        let cipher = TestHMACCipher(), secret = CommunityKeys.secret(university: "luh", courseID: "kurs-1")
        let content = SolutionContent(solutionID: UUID().uuidString.lowercased(), createdAt: "2026-10-26T10:00:00Z", title: "Blatt", displayName: "",
                                      fingerprint: pdfA, pdfPageCount: 1,
                                      pages: [SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0, extraRotation: 0,
                                                           objects: [.object(["type": "stroke", "points": .array([1, 2, 3, 4])])])])
        let sealed = try SolutionPackage.seal(content, communitySecret: secret, cipher: cipher)
        XCTAssertEqual(try sealed.open(communitySecret: secret, cipher: cipher), content)
        XCTAssertThrowsError(try sealed.open(communitySecret: CommunityKeys.secret(university: "luh", courseID: "anderer"), cipher: cipher))
        XCTAssertThrowsError(try sealed.open(originalPDF: Data("x".utf8), cipher: cipher), "Community-Paket haengt nicht an der PDF")
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
    private func member(plan: String = "plus", course: CommunitySpace, pdfs: [String] = []) async throws -> ServiceCommunityService {
        guard let base = ProcessInfo.processInfo.environment["G2_TEST_SERVICE"] else { throw XCTSkip("G2_TEST_SERVICE fehlt") }
        let r = try await LiveHTTP().send(AIHTTPRequest(method: "POST", url: base + "/__test/account", headers: ["Content-Type": "application/json"],
                                                        body: JSONValue.object(["plan": .string(plan)]).serialized()))
        let token = try XCTUnwrap(try JSONValue.parse(r.body)["token"]?.string)
        let account = StudoraAccount(base: base, http: LiveHTTP(), tokens: MemoryTokens(token), deviceID: "ipad-" + UUID().uuidString, deviceName: "Test")
        return service(account, local: pdfs, courses: [course])
    }

    private func communityPackage(_ fp: String, secret: Data) throws -> SolutionPackage {
        let content = SolutionContent(solutionID: UUID().uuidString.lowercased(), createdAt: "2026-10-26T10:00:00Z", title: "Blatt", displayName: "Mira",
                                      fingerprint: fp, pdfPageCount: 1,
                                      pages: [SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0, extraRotation: 0,
                                                           objects: [.object(["type": "stroke", "points": .array([1, 2, 3, 4])])])])
        return try SolutionPackage.seal(content, communitySecret: secret, cipher: TestHMACCipher())
    }

    private func randomHex() -> String { (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().padding(toLength: 64, withPad: "0", startingAt: 0) }

    func testCourseCommunityFromJoiningToReadingWithoutThePDF() async throws {
        let id = UUID().uuidString, pdf = randomHex()
        let course = CommunitySpace.course(university: "luh", id: id, title: "Analysis")
        let author = try await member(course: course, pdfs: [pdf]), reader = try await member(plan: "free", course: course)
        let outsider = try await member(course: .course(university: "luh", id: UUID().uuidString, title: "Anderer"))

        var mine = try await XCTUnwrapAsync(await author.communities().first)
        XCTAssertFalse(mine.joined)
        do { _ = try await author.publish(try communityPackage(pdf, secret: try XCTUnwrap(course.secret)), options: CommunityPublishOptions(communityKey: course.key)); XCTFail() } catch {
            XCTAssertEqual(error as? CommunityServiceError, .notAMember)
        }
        try await author.join(mine)
        mine = try await XCTUnwrapAsync(await author.communities().first)
        XCTAssertEqual(mine.joined, true)
        let p = try communityPackage(pdf, secret: try XCTUnwrap(course.secret))
        let pub = try await author.publish(p, options: CommunityPublishOptions(title: "Blatt 1", communityKey: course.key))

        let seat = try await XCTUnwrapAsync(await reader.communities().first)
        try await reader.join(seat)
        let joined = try await XCTUnwrapAsync(await reader.communities().first)
        let hits = try await reader.solutions(in: joined)
        XCTAssertEqual(hits.map(\.solutionID), [pub.solutionID])
        XCTAssertEqual(hits.first?.communityKey, course.key)
        let loaded = try await reader.download(solutionID: pub.solutionID)
        XCTAssertEqual(try loaded.open(communitySecret: try XCTUnwrap(joined.secret), cipher: TestHMACCipher()).title, "Blatt", "Mitglied ohne PDF liest die Notizen")
        let byPDF = try await reader.findMatching(fingerprint: pdf)
        XCTAssertEqual(byPDF.count, 1)

        do { _ = try await outsider.download(solutionID: pub.solutionID); XCTFail() } catch { XCTAssertEqual(error as? CommunityServiceError, .notFound) }
        do { _ = try await outsider.solutions(in: course); XCTFail() } catch { XCTAssertEqual(error as? CommunityServiceError, .notAMember) }

        try await reader.report(solutionID: pub.solutionID, reason: .spam, note: "Test")
        try await reader.block(owner: try XCTUnwrap(hits.first?.ownerRecordName))
        let hidden = try await reader.solutions(in: joined)
        XCTAssertEqual(hidden, [])
        try await reader.unblock(owner: try XCTUnwrap(hits.first?.ownerRecordName))
        try await reader.leave(joined)
        do { _ = try await reader.download(solutionID: pub.solutionID); XCTFail() } catch { XCTAssertEqual(error as? CommunityServiceError, .notFound) }
        try await author.withdraw(solutionID: pub.solutionID)
    }

    func testCommentsAndLikesAcrossMembers() async throws {
        let course = CommunitySpace.course(university: "luh", id: UUID().uuidString, title: "Kurs")
        let author = try await member(course: course), reader = try await member(course: course)
        let free = try await member(plan: "free", course: course)
        let outsider = try await member(course: .course(university: "luh", id: UUID().uuidString, title: "Anderer"))
        for m in [author, reader, free] {
            let s = try await XCTUnwrapAsync(await m.communities().first)
            try await m.join(s)
        }
        let p = try communityPackage(randomHex(), secret: try XCTUnwrap(course.secret))
        let id = try await author.publish(p, options: CommunityPublishOptions(title: "Blatt", communityKey: course.key)).solutionID

        let c = try await reader.addComment(solutionID: id, text: "Schritt 2 fehlt", parentID: nil, pageKey: "p1", anchor: .init(x: 0.25, y: 0.5))
        XCTAssertEqual(c.anchor, .init(x: 0.25, y: 0.5))
        XCTAssertTrue(c.isMine)
        let r = try await author.addComment(solutionID: id, text: "Danke", parentID: c.id, pageKey: nil, anchor: nil)
        XCTAssertEqual(r.parentID, c.id)
        XCTAssertTrue(r.byAuthor)

        let seen = try await free.comments(solutionID: id)
        XCTAssertEqual(seen.map(\.text), ["Schritt 2 fehlt", "Danke"], "alle Mitglieder sehen sie, auch ohne Plus")
        XCTAssertEqual(seen.map(\.isMine), [false, false])
        do { _ = try await free.addComment(solutionID: id, text: "x", parentID: nil, pageKey: nil, anchor: nil); XCTFail() } catch {
            guard case .server = error as? CommunityServiceError else { return XCTFail("\(error)") }
        }
        do { _ = try await outsider.comments(solutionID: id); XCTFail() } catch { XCTAssertEqual(error as? CommunityServiceError, .notFound) }

        let edited = try await reader.editComment(id: c.id, text: "Schritt 2 fehlt noch")
        XCTAssertTrue(edited.edited)
        try await free.reportComment(id: c.id, reason: .spam)

        let liked = try await reader.setLiked(solutionID: id, true)
        XCTAssertEqual(liked, 1)
        let joined = try await XCTUnwrapAsync(await reader.communities().first)
        let row = try await XCTUnwrapAsync(await reader.solutions(in: joined).first)
        XCTAssertEqual(row.likes, 1)
        XCTAssertTrue(row.likedByMe)
        XCTAssertEqual(row.commentCount, 2)
        let unliked = try await reader.setLiked(solutionID: id, false)
        XCTAssertEqual(unliked, 0)
        do { _ = try await author.setLiked(solutionID: id, true); XCTFail() } catch {
            guard case .server = error as? CommunityServiceError else { return XCTFail("\(error)") }
        }

        try await author.deleteComment(id: r.id)
        let left = try await reader.comments(solutionID: id)
        XCTAssertEqual(left.map(\.id), [c.id])
    }

    func testStudyGroupWithCode() async throws {
        let course = CommunitySpace.course(university: "luh", id: UUID().uuidString, title: "Kurs")
        let a = try await member(course: course), b = try await member(plan: "free", course: course)
        let g = try await a.createStudyGroup(name: "Mathe-Runde")
        let joined = try await b.joinStudyGroup(code: g.code)
        XCTAssertEqual(joined.name, "Mathe-Runde")
        let spaces = try await b.communities()
        XCTAssertEqual(spaces.first { $0.kind == .group }?.members, 2)
        try await b.leaveStudyGroup(code: g.code)
        let after = try await b.communities()
        XCTAssertNil(after.first { $0.kind == .group })
    }
}

private func XCTUnwrapAsync<T>(_ v: @autoclosure () async throws -> T?) async throws -> T {
    let x = try await v()
    return try XCTUnwrap(x)
}
