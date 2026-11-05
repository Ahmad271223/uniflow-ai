import Foundation
import XCTest
@testable import UniFlowCore

// Auf Stud.IP-Nachrichten antworten (docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md): Koerper und Beziehungen von
// `POST messages`, Kopfzeilen, Betreff, Zitat, Suche im Posteingang ueber Seiten, Systemnachricht, Fehlerzuordnung, kein
// zweites POST, Entwurf, Verlauf, Empfaengerzahl beim Abgleich. Nur erfundene Daten, nichts geht ins Netz.

private func api(_ json: String, status: Int = 200) -> HTTPReply {
    HTTPReply(status: status, contentType: "application/vnd.api+json", body: Data(json.utf8))
}

private let base = URL(string: "https://studip.test")!
private let me = #"{"data":{"type":"users","id":"u-me","attributes":{"family-name":"Mustermann"}}}"#

/// Posteingang Seite 1: Systemnachricht und eine Nachricht an drei (mit mir); Seite 2: die gesuchte Rundnachricht
private let inbox1 = """
{"data":[
 {"type":"messages","id":"m-sys","attributes":{"subject":"Ihre Bescheinigung","message":"x","mkdate":"2026-11-02T08:00:00+01:00"},
  "relationships":{"sender":{"data":{"type":"users","id":"____%system%____"}}}},
 {"type":"messages","id":"m1","attributes":{"subject":"Tutorium &amp; Übung","message":"<p>Hallo</p>","mkdate":"2026-11-02T08:15:00+01:00"},
  "relationships":{"sender":{"data":{"type":"users","id":"u-doz"}},
                   "recipients":{"data":[{"type":"users","id":"u-me"},{"type":"users","id":"u-a"},{"type":"users","id":"u-b"}]}}}
],
"included":[{"type":"users","id":"u-doz","attributes":{"formatted-name":"Prof. Erika Test","permission":"dozent"}}],
"links":{"next":"/jsonapi.php/v1/users/u-me/inbox?page[offset]=50&page[limit]=50&include=sender"}}
"""

private let inbox2 = """
{"data":[
 {"type":"messages","id":"m-alt","attributes":{"subject":"RE: Frage","message":"y","mkdate":"2026-10-01T10:00:00+02:00"},
  "relationships":{"sender":{"data":{"type":"users","id":"u-tut"}}}}
],
"included":[{"type":"users","id":"u-tut","attributes":{"given-name":"Max","family-name":"Tutor"}}],
"links":{}}
"""

private let inboxPath = "/jsonapi.php/v1/users/u-me/inbox?page[limit]=50&include=sender"
private let inboxPage2 = "/jsonapi.php/v1/users/u-me/inbox?page[offset]=50&page[limit]=50&include=sender"

final class StudIPMessageReplyTests: XCTestCase {
    private func client(_ t: StudIPTransport) -> StudIPClient { StudIPClient(base: base, transport: t, pauseMillis: 0) }

    private func stub(write: @escaping @Sendable (String, String, Data) -> HTTPReply = { _, _, _ in
        api(#"{"data":{"type":"messages","id":"neu1"}}"#, status: 201)
    }) -> WritingStub {
        WritingStub(["/jsonapi.php/v1/users/me": api(me), inboxPath: api(inbox1), inboxPage2: api(inbox2),
                     "/jsonapi.php/v1/users/u-a": api(#"{"data":{"type":"users","id":"u-a","attributes":{"formatted-name":"Anna A."}}}"#)],
                    write: write)
    }

    // MARK: Regeln

    func testSubjectGetsSingleREPrefix() {
        XCTAssertEqual(StudIPMessageReply.replySubject("Tutorium entfällt"), "RE: Tutorium entfällt")
        XCTAssertEqual(StudIPMessageReply.replySubject("RE: Tutorium"), "RE: Tutorium")
        XCTAssertEqual(StudIPMessageReply.replySubject("Re: Frage"), "Re: Frage")
        XCTAssertEqual(StudIPMessageReply.replySubject("AW: Frage"), "AW: Frage")
        XCTAssertEqual(StudIPMessageReply.replySubject("  Rechnung  "), "RE: Rechnung", "re ohne Doppelpunkt ist kein Praefix")
        XCTAssertEqual(StudIPMessageReply.replySubject("(ohne Betreff)"), "RE: ")
    }

    func testQuoteAndBody() {
        let q = StudIPMessageReply.quote("Hallo,\n\ndas Tutorium fällt aus.", senderName: "Prof. Erika Test", sentAt: "2026-11-02T08:15:00+01:00")
        XCTAssertEqual(q, "Am 02.11.2026 um 08:15 Prof. Erika Test schrieb:\n> Hallo,\n>\n> das Tutorium fällt aus.")
        XCTAssertEqual(StudIPMessageReply.quote("x", senderName: "", sentAt: nil), "Absender schrieb:\n> x")
        XCTAssertEqual(StudIPMessageReply.body(text: "  Danke!\n ", quote: nil), "Danke!")
        XCTAssertEqual(StudIPMessageReply.body(text: "Danke!", quote: "Z:\n> x"), "Danke!\n\nZ:\n> x")
    }

    func testPayloadHasJSONAPIShapeAndUniqueRecipients() throws {
        let p = StudIPMessageReply.payload(subject: "RE: A", text: "Zeile 1\nZeile 2", recipientIDs: ["u1", "u2", "u1", ""])
        XCTAssertEqual(p["data"]?["type"]?.string, "messages")
        XCTAssertEqual(p["data"]?["attributes"]?["subject"]?.string, "RE: A")
        XCTAssertEqual(p["data"]?["attributes"]?["message"]?.string, "Zeile 1\nZeile 2")
        XCTAssertEqual(p["data"]?["attributes"]?["priority"]?.string, "normal")
        let r = try XCTUnwrap(p["data"]?["relationships"]?["recipients"]?["data"]?.array)
        XCTAssertEqual(r.compactMap { $0["id"]?.string }, ["u1", "u2"])
        XCTAssertEqual(Set(r.compactMap { $0["type"]?.string }), ["users"])
    }

    func testErrorMapping() {
        XCTAssertNil(StudIPMessageReply.sendError(status: 201, body: Data()))
        XCTAssertNil(StudIPMessageReply.sendError(status: 204, body: Data()))
        XCTAssertEqual(StudIPMessageReply.sendError(status: 403, body: Data(#"{"errors":[{"detail":"Invalid CSRF token"}]}"#.utf8)), .securityToken)
        XCTAssertEqual(StudIPMessageReply.sendError(status: 403, body: Data("Sicherheitstoken fehlt".utf8)), .securityToken)
        XCTAssertEqual(StudIPMessageReply.sendError(status: 403, body: Data()), .forbidden)
        XCTAssertEqual(StudIPMessageReply.sendError(status: 422, body: Data()), .rejected(422))
        XCTAssertEqual(StudIPMessageReply.sendError(status: 500, body: Data()), .http(500))
        XCTAssertTrue(StudIPMessageError.securityToken.offersWebFallback)
        XCTAssertFalse(StudIPMessageError.unsupported.offersWebFallback)
        XCTAssertEqual(StudIPMessageReply.sentID(location: nil, body: Data(#"{"data":{"id":"abc"}}"#.utf8)), "abc")
        XCTAssertEqual(StudIPMessageReply.sentID(location: "https://studip.test/jsonapi.php/v1/messages/xyz", body: Data()), "xyz")
        XCTAssertNil(StudIPMessageReply.sentID(location: nil, body: Data()))
    }

    func testReplyAbilityAndLinks() {
        XCTAssertFalse(StudIPMessageReply.isReplyable(senderLabel: "Stud.IP"))
        XCTAssertFalse(StudIPMessageReply.isReplyable(senderLabel: ""))
        XCTAssertTrue(StudIPMessageReply.isReplyable(senderLabel: "Lehrende"))
        XCTAssertFalse(StudIPMessageReply.offersReplyAll(recipients: nil))
        XCTAssertFalse(StudIPMessageReply.offersReplyAll(recipients: 1))
        XCTAssertTrue(StudIPMessageReply.offersReplyAll(recipients: 2))
        XCTAssertTrue(StudIPMessageReply.offersReplyAll(recipients: 21))
        XCTAssertFalse(StudIPMessageReply.offersReplyAll(recipients: 22), "Rundnachricht")
        XCTAssertEqual(StudIPMessageReply.rawID("sp-msg-m1"), "m1")
        XCTAssertEqual(StudIPMessageReply.localID("m1"), "sp-msg-m1")
        XCTAssertEqual(StudIPMessageReply.replyWebURL(base: URL(string: "https://studip.test/")!, messageID: "m1").absoluteString,
                       "https://studip.test/dispatch.php/messages/write?answer_to=m1")
    }

    // MARK: Kontext

    func testContextFromInboxWithRecipientsExcludingMeAndSender() async throws {
        let s = stub()
        let c = try await client(s).replyContext(messageID: "m1")
        XCTAssertEqual(c.sender, StudIPPerson(id: "u-doz", name: "Prof. Erika Test"))
        XCTAssertEqual(c.subject, "Tutorium & Übung")
        XCTAssertEqual(c.otherRecipientIDs, ["u-a", "u-b"])
        XCTAssertTrue(c.recipientsKnown)
        XCTAssertTrue(c.allowsReplyAll)
        XCTAssertEqual(s.seen.map(\.path), ["/jsonapi.php/v1/users/me", inboxPath], "eine Seite reicht, keine Einzelansicht")
        XCTAssertFalse(s.seen.contains { $0.path.contains("/messages/") }, "nie GET messages/{id} (koennte als gelesen markieren)")
    }

    func testContextFollowsNextPageAndHandlesMissingRecipients() async throws {
        let s = stub()
        let c = try await client(s).replyContext(messageID: "m-alt")
        XCTAssertEqual(c.sender.name, "Max Tutor")
        XCTAssertEqual(c.otherRecipientIDs, [])
        XCTAssertFalse(c.recipientsKnown)
        XCTAssertFalse(c.allowsReplyAll)
        XCTAssertEqual(s.seen.filter { $0.path.contains("/inbox") }.count, 2)
    }

    func testSystemMessageAndNotFound() async throws {
        do { _ = try await client(stub()).replyContext(messageID: "m-sys"); XCTFail("Systemnachricht") } catch {
            XCTAssertEqual(error as? StudIPMessageError, .systemMessage)
        }
        do { _ = try await client(stub()).replyContext(messageID: "gibtsnicht"); XCTFail("nicht gefunden") } catch {
            XCTAssertEqual(error as? StudIPMessageError, .notFound)
        }
    }

    func testRecipientNamesFallBackForInvisibleUsers() async throws {
        let names = try await client(stub()).recipientNames(["u-a", "u-unsichtbar"])
        XCTAssertEqual(names, [StudIPPerson(id: "u-a", name: "Anna A."), StudIPPerson(id: "u-unsichtbar", name: "Stud.IP-Nutzer/in")])
    }

    func testCircularMessageDisablesReplyAll() throws {
        let ids = (0..<30).map { #"{"type":"users","id":"u\#($0)"}"# }.joined(separator: ",")
        let page = try JSONValue.parse(Data("""
        {"data":[{"type":"messages","id":"rund","attributes":{"subject":"Rundmail"},
          "relationships":{"sender":{"data":{"type":"users","id":"u-doz"}},"recipients":{"data":[\(ids)]}}}]}
        """.utf8))
        let c = try XCTUnwrap(try StudIPMessageReply.context(messageID: "rund", page: page, me: "u3"))
        XCTAssertEqual(c.otherRecipientIDs.count, 29)
        XCTAssertTrue(c.isCircular)
        XCTAssertFalse(c.allowsReplyAll)
        XCTAssertEqual(c.sender.name, "Absender", "ohne include kein Name")
    }

    // MARK: Senden

    func testSendPostsJSONAPIBodyWithHeaders() async throws {
        let s = stub()
        let id = try await client(s).sendMessage(subject: "RE: Tutorium", text: "Danke!\n\nGruß", recipientIDs: ["u-doz"])
        XCTAssertEqual(id, "neu1")
        let post = try XCTUnwrap(s.seen.first { $0.method == "POST" })
        XCTAssertEqual(post.path, "/jsonapi.php/v1/messages")
        XCTAssertEqual(post.headers["Content-Type"], "application/vnd.api+json")
        XCTAssertEqual(post.headers["Accept"], "application/vnd.api+json")
        XCTAssertEqual(post.headers["X-Requested-With"], "XMLHttpRequest")
        let j = try JSONValue.parse(post.body)
        XCTAssertEqual(j["data"]?["type"]?.string, "messages")
        XCTAssertEqual(j["data"]?["attributes"]?["subject"]?.string, "RE: Tutorium")
        XCTAssertEqual(j["data"]?["attributes"]?["message"]?.string, "Danke!\n\nGruß")
        XCTAssertEqual(j["data"]?["relationships"]?["recipients"]?["data"]?.array?.compactMap { $0["id"]?.string }, ["u-doz"])
        XCTAssertEqual(s.seen.count, 1, "nur das POST")
    }

    func testSendErrorsAreNeverRetried() async throws {
        for (status, body, expected) in [(500, "", StudIPMessageError.http(500)), (429, "", .http(429)),
                                         (403, "CSRF token mismatch", .securityToken), (422, "", .rejected(422))] {
            let s = stub { _, _, _ in api(body, status: status) }
            do { _ = try await client(s).sendMessage(subject: "a", text: "b", recipientIDs: ["u"]); XCTFail("\(status)") } catch {
                XCTAssertEqual(error as? StudIPMessageError, expected)
            }
            XCTAssertEqual(s.seen.filter { $0.method == "POST" }.count, 1, "kein zweites POST bei \(status)")
        }
    }

    func testExpiredSessionOnSend() async throws {
        let s401 = stub { _, _, _ in HTTPReply(status: 401) }
        do { _ = try await client(s401).sendMessage(subject: "a", text: "b", recipientIDs: ["u"]); XCTFail() } catch {
            XCTAssertEqual(error as? StudIPError, .sessionExpired)
        }
        let login = stub { _, _, _ in HTTPReply(status: 200, contentType: "text/html", body: Data("<form id=\"login\"><input name=\"j_username\"><input type=\"password\"></form>".utf8)) }
        do { _ = try await client(login).sendMessage(subject: "a", text: "b", recipientIDs: ["u"]); XCTFail() } catch {
            XCTAssertEqual(error as? StudIPError, .sessionExpired)
        }
        let readOnly = WritingStubReadOnly()
        do { _ = try await client(readOnly).sendMessage(subject: "a", text: "b", recipientIDs: ["u"]); XCTFail() } catch {
            XCTAssertEqual(error as? StudIPMessageError, .unsupported)
        }
    }

    // MARK: Entwurf und Verlauf

    func testDraftsKeepOnlyContentAndLimit() throws {
        var d = StudIPReplyDrafts()
        let t = Date(timeIntervalSince1970: 1_793_890_000)
        d.put(StudIPReplyDraft(messageID: "sp-msg-m1", mode: .sender, subject: "RE: A", text: "Hallo", quote: true, savedAt: t))
        d.put(StudIPReplyDraft(messageID: "sp-msg-m2", mode: .all, subject: "RE: B", text: "   ", quote: false, savedAt: t))
        XCTAssertEqual(d.drafts.map(\.messageID), ["sp-msg-m1"], "leerer Entwurf wird nicht aufgehoben")
        let back = StudIPReplyDrafts.decode(d.encoded())
        XCTAssertEqual(back.draft(for: "sp-msg-m1")?.text, "Hallo")
        XCTAssertEqual(back.draft(for: "sp-msg-m1")?.quote, true)
        d.put(StudIPReplyDraft(messageID: "sp-msg-m1", mode: .sender, subject: "RE: A", text: "", quote: true, savedAt: t))
        XCTAssertNil(d.draft(for: "sp-msg-m1"), "Text geloescht: Entwurf weg")
        for i in 0..<60 { d.put(StudIPReplyDraft(messageID: "m\(i)", mode: .sender, subject: "", text: "x", quote: false, savedAt: t)) }
        XCTAssertEqual(d.drafts.count, StudIPReplyDrafts.limit)
        XCTAssertEqual(d.drafts.first?.messageID, "m59")
        XCTAssertEqual(StudIPReplyDrafts.decode(Data("kaputt".utf8)), StudIPReplyDrafts())
    }

    func testLogLineAndAnswered() {
        var log = StudIPReplyLog()
        let r = StudIPReplyRecord(messageID: "sp-msg-m1", at: Date(timeIntervalSince1970: 1_793_890_000), subject: "RE: A", text: "Danke",
                                  quoted: false, mode: .sender, recipients: 1, sentID: "neu1")
        log.add(r)
        XCTAssertEqual(StudIPReplyLog.decode(log.encoded()).records(for: "sp-msg-m1"), [r])
        XCTAssertEqual(log.answered, ["sp-msg-m1"])
        XCTAssertEqual(r.line(timeZone: TimeZone(identifier: "Europe/Berlin")!), "Beantwortet am 05.11.2026, 15:46")
    }

    // MARK: Empfaengerzahl beim Abgleich

    func testMetaStoredAndListedWithoutNames() async throws {
        let clock = UniFlowClock.fixed(berlin: "2026-11-02T10:30:00")!
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let page = try JSONValue.parse(Data(inbox1.utf8))
        var d = StudIPExtras.Download()
        d.messages = StudIPExtras.parseMessages(page["data"], included: page["included"], base: "https://studip.test", today: 20759)
        d.messageMeta = StudIPExtras.parseMessageMeta(page["data"])
        XCTAssertEqual(d.messageMeta, ["sp-msg-m1": 3])
        try await backend.context.database.transaction { try StudIPExtras.store(d, in: $0, clock: clock) }
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/studip/messages"))
        let ms = try XCTUnwrap(r.json?["messages"]?.array)
        XCTAssertEqual(ms.first { $0["id"]?.string == "sp-msg-m1" }?["recipients"]?.int, 3)
        XCTAssertEqual(ms.first { $0["id"]?.string == "sp-msg-m-sys" }?["recipients"], .null)
        let rows = try await backend.context.database.withConnection { try $0.rows("SELECT * FROM studip_message_meta") }
        XCTAssertFalse(rows.description.contains("u-a"), "keine Kennungen gespeichert")
        XCTAssertFalse(rows.description.contains("Erika"), "keine Namen gespeichert")
    }
}

/// Nur lesender Transport (wie der Abgleich): kann nicht senden
private final class WritingStubReadOnly: StudIPTransport, @unchecked Sendable {
    func get(_ url: URL, accept: String?) async throws -> HTTPReply { HTTPReply(status: 404) }
}
