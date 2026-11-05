import Foundation
import XCTest
@testable import UniFlowCore

/// Learnweb-Nachrichten der Uni Hildesheim (LearnwebMessages.swift) und LSF-Wartungshinweis gegen
/// die gemeinsamen Faelle aus Python (packages/shared-contracts/fixtures/learnweb/messages-cases.json,
/// tools/gen-learnweb-messages-fixture.py). Alle Daten erfunden, kein Netz.
final class LearnwebMessagesTests: XCTestCase {
    private let base = "https://www.uni-hildesheim.de/learnweb2026"
    private let token = LearnwebToken("TOKEN123abcdef0123456789")!
    private let noWait = UniRetry(attempts: 3, delayNanos: { _ in 0 })
    private let clock = UniFlowClock.fixed(Date(timeIntervalSince1970: 1_793_880_000))

    private func fixture() throws -> JSONValue {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/learnweb/messages-cases.json")))
    }

    private func today() -> Int { BerlinClock.parseISODate("2026-11-05")! }

    // MARK: Gemeinsame Faelle

    func testConversationsLikePython() throws {
        let fx = try fixture()
        let me = try XCTUnwrap(fx["me"]?.int)
        let got = LearnwebMessages.parseConversations(fx["conversations"]?["input"], me: me, base: base, today: today())
        let want = fx["conversations"]?["expected"]?.array ?? []
        XCTAssertEqual(got.count, want.count)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.id, w["id"]?.string)
            XCTAssertEqual(g.sender, w["sender"]?.string)
            XCTAssertEqual(g.subject, w["subject"]?.string)
            XCTAssertEqual(g.preview, w["preview"]?.string)
            XCTAssertEqual(g.sentAt, w["sent_at"]?.string)
            XCTAssertEqual(g.url, w["url"]?.string)
            XCTAssertEqual(JSONValue.array(g.dates), w["dates"])
        }
        XCTAssertFalse(got.map { $0.json.jsonString() }.joined().contains("Erika"), "keine Personennamen gespeichert")
    }

    func testContextsPagesIDsArgsAndErrorsLikePython() throws {
        let fx = try fixture()
        let me = try XCTUnwrap(fx["me"]?.int)
        for c in fx["contexts"]?.array ?? [] {
            let name = c["name"]?.string ?? ""
            let e = try XCTUnwrap(c["expected"])
            let got = try LearnwebMessages.context(c["input"], me: me)
            XCTAssertEqual(got.conversationID, e["conversation_id"]?.int, name)
            XCTAssertEqual(got.group, e["group"]?.bool, name)
            XCTAssertEqual(got.name, e["name"]?.string, name)
            XCTAssertEqual(got.replyable, e["replyable"]?.bool, name)
            XCTAssertEqual(got.reason, e["reason"]?.string, name)
            XCTAssertEqual(got.recipients.map(\.id), (e["recipients"]?.array ?? []).compactMap { $0["id"]?.int.map(String.init) }, name)
            if name != "selbst" { XCTAssertEqual(got.memberCount, e["member_count"]?.int, name) }
        }
        XCTAssertThrowsError(try LearnwebMessages.context(.object([:]), me: me))
        for p in fx["pages"]?.array ?? [] {
            XCTAssertEqual(LearnwebMessages.userID(fromPage: p["html"]?.string ?? ""), p["user"]?.int, p["name"]?.string ?? "")
            XCTAssertEqual(Learnweb.sesskey(fromPage: p["html"]?.string ?? ""), p["sesskey"]?.string, p["name"]?.string ?? "")
        }
        for x in fx["local_ids"]?.array ?? [] {
            XCTAssertEqual(LearnwebMessages.conversation(of: x["id"]?.string ?? ""), x["conversation"]?.int)
        }
        let flat = LearnwebMessages.flatten(LearnwebMessages.sendArgs(conversation: 12, text: "Danke!\nBis dann"))
        XCTAssertEqual(flat, (fx["send_args"]?["flat"]?.object ?? [:]).mapValues { $0.string ?? "" })
        for e in fx["errors"]?.array ?? [] {
            XCTAssertEqual(LearnwebMessages.error(code: e["code"]?.string).code, e["expected"]?.string)
        }
    }

    // MARK: Ablauf mit nachgebildetem Learnweb

    private func ajax(_ data: JSONValue) -> UniResponse { okJSON(.array([.object(["error": .bool(false), "data": data])])) }

    private func payload(_ r: UniRequest) -> JSONValue? { r.body.flatMap { try? JSONValue.parse($0) }?.array?.first }

    func testSessionReadsConversationsAndSendsExactlyOnce() async throws {
        let fx = try fixture()
        var sends = 0
        let page = #"<html><body class="path-my"><script>M.cfg = {"sesskey":"abcSESS1","userId":4711};</script></body></html>"#
        let net = FakeUniTransport { req in
            if req.url.path.hasSuffix("/my/courses.php") { return ok(page) }
            let p = self.payload(req)
            switch p?["methodname"]?.string {
            case "core_message_get_conversations":
                XCTAssertEqual(p?["args"]?["userid"]?.int, 4711)
                return self.ajax(fx["conversations"]?["input"] ?? .null)
            case "core_message_get_conversation": return self.ajax(fx["contexts"]?.array?.first?["input"] ?? .null)
            case "core_message_send_messages_to_conversation":
                sends += 1
                return UniResponse(status: 503)
            default: return UniResponse(status: 404)
            }
        }
        let api = LearnwebAPI(base: base, mode: .session, transport: net, retry: noWait)
        let msgs = try await api.messages(today: today())
        XCTAssertEqual(msgs.map(\.id), ["lw-msg-13-399", "lw-msg-12-345"])
        let ctx = try await api.messageContext(conversation: 12)
        XCTAssertEqual(ctx.recipients.map(\.name), ["Erika Beispiel (erfunden)"])
        do {
            _ = try await api.sendMessage(conversation: 12, text: "Danke")
            XCTFail("503 ist ein Fehler")
        } catch {}
        XCTAssertEqual(sends, 1, "Senden wird nie wiederholt (auch nicht bei 503)")
        XCTAssertFalse(net.requests.contains { ($0.body.map { String(decoding: $0, as: UTF8.self) } ?? "").contains("mark_all") },
                       "nichts als gelesen markiert")
    }

    func testTokenErrorsAndNotAllowed() async throws {
        let net = FakeUniTransport { req in
            let body = String(decoding: req.body ?? Data(), as: UTF8.self)
            if body.contains("core_webservice_get_site_info") { return ok(#"{"userid": 4711}"#) }
            if body.contains("send_messages_to_conversation") {
                XCTAssertTrue(body.contains("messages%5B0%5D%5Btext%5D=Hallo") || body.contains("messages[0][text]=Hallo"), body)
                return ok(#"{"exception": "moodle_exception", "errorcode": "usercantbemessaged"}"#)
            }
            return ok(#"{"exception": "x", "errorcode": "invalidtoken"}"#)
        }
        let api = LearnwebAPI(base: base, mode: .token(token), transport: net, retry: noWait)
        do { _ = try await api.sendMessage(conversation: 12, text: "Hallo"); XCTFail() } catch {
            XCTAssertEqual(error as? LearnwebMessageError, .notAllowed)
        }
        do { _ = try await api.messages(today: today()); XCTFail() } catch {
            XCTAssertEqual(error as? LearnwebMessageError, .login)
        }
        XCTAssertFalse(net.requests.contains { $0.url.absoluteString.contains("TOKEN123") }, "Schluessel nie in einer Adresse")
    }

    func testSyncStoresLearnwebMessagesInTheMessageList() async throws {
        let fx = try fixture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lwm-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let layout = DataContainerLayout(base: dir, key: DataContainerKey(userID: "001234.erfunden.0001", university: .hildesheim))
        try layout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: layout.databaseURL.path)
        try await db.migrate(clock: clock, university: "hildesheim")
        let net = FakeUniTransport { req in
            let body = String(decoding: req.body ?? Data(), as: UTF8.self)
            if body.contains("core_webservice_get_site_info") { return ok(#"{"userid": 4711}"#) }
            if body.contains("core_enrol_get_users_courses") { return ok("[]") }
            if body.contains("core_message_get_conversations") { return okJSON(fx["conversations"]?["input"] ?? .null) }
            return ok(#"{"events": []}"#)
        }
        let report = await HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .token(token), transport: net, retry: noWait),
                                          lsf: nil, transport: net, clock: clock, retry: noWait).run()
        XCTAssertEqual(report.learnwebMessages, 2, "\(report.messages)")
        let list = try await db.withConnection { try StudIPExtras.messageList($0) }
        XCTAssertEqual(list["messages"]?.array?.compactMap { $0["id"]?.string }, ["lw-msg-13-399", "lw-msg-12-345"])
        XCTAssertFalse(report.messages.contains { $0.contains("Nachrichten") }, "Erfolg ohne eigene Zeile: \(report.messages)")
    }

    // MARK: LSF-Wartungshinweis (Struktur der echten Seiten 05.11.2026, Text erfunden wie in tests/test_learnweb_messages.py)

    func testLSFMaintenanceNoticeLikePython() {
        let page = #"<div class="hidden">Wenn Sie diesen Text sehen, ist noch nicht das neue Layout geladen</div><div id="kopf"><b>+++ Wegen Wartungsarbeiten steht PLuS/LSF/POS am Montag, 09.11.2026 voraussichtlich erst ab 09.30 zur Verf&uuml;gung +++</b></div><a href="rds?state=user&type=4&category=auth.logout">Abmelden</a>"#
        XCTAssertEqual(LSFClient.maintenanceNotice(html: page),
                       "Wegen Wartungsarbeiten steht PLuS/LSF/POS am Montag, 09.11.2026 voraussichtlich erst ab 09.30 zur Verfügung")
        XCTAssertNil(LSFClient.maintenanceNotice(html: "<p>Wenn Sie diesen Text sehen, ist noch nicht das neue Layout geladen</p>"))
        XCTAssertNil(LSFClient.maintenanceNotice(html: "<p>C++ und C+++ sind keine Hinweise</p>"))
    }
}
