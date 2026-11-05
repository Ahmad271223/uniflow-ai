import Foundation
import XCTest
@testable import UniFlowCore

/// Allgemeines Moodle (HsH und Learnweb Hildesheim): Nachrichten lesen und beantworten, Abgabe in einer Aufgabe, gegen
/// nachgebaute Antworten (packages/shared-contracts/fixtures/moodle, NACHGEBAUT). Kein echtes Netz.
final class MoodleTests: XCTestCase {
    let base = "https://moodle.hs-hannover.de"
    let noWait = UniRetry(attempts: 3, delayNanos: { _ in 0 })

    private func fx(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/moodle/\(name)"), encoding: .utf8)
    }

    private func json(_ name: String) throws -> JSONValue { try JSONValue.parse(Data(fx(name).utf8)) }

    private func ajaxOK(_ data: JSONValue) -> UniResponse { okJSON(.array([.object(["error": .bool(false), "data": data])])) }

    private func database() async throws -> SQLiteDatabase {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moodle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("db.sqlite").path)
        try await db.migrate(clock: .fixed(Date(timeIntervalSince1970: 1_793_000_000)), university: "hsh")
        return db
    }

    private func messageRoutes(_ t: FakeUniTransport) throws {
        t.on("\(base)/message/index.php", ok(#"<script>M.cfg = {"sesskey":"sk123"};</script><div data-region="message-drawer" data-userid="42"></div>"#))
        let svc = "\(base)/lib/ajax/service.php?sesskey=sk123&info="
        t.on(svc + "core_message_get_conversations", ajaxOK(try json("conversations.json")))
        let msgs = try json("conversation-messages.json")
        t.on(svc + "core_message_get_conversation_messages", body: "\"convid\":12", ajaxOK(msgs["12"] ?? .null))
        t.on(svc + "core_message_get_conversation_messages", body: "\"convid\":13", ajaxOK(msgs["13"] ?? .null))
        t.on(svc + "core_message_get_unread_conversations_count", ajaxOK(.number(1)))
    }

    // MARK: Nachrichten

    func testMessagesAreStoredWithoutNamesAndWithoutMarkingRead() async throws {
        let t = FakeUniTransport()
        try messageRoutes(t)
        let db = try await database()
        let r = await MoodleMessagesSync.run(db: db, web: MoodleWeb(base: base, transport: t, retry: noWait))
        XCTAssertEqual(r.count, 2, r.message)
        XCTAssertEqual(r.unread, 1)
        let list = try await db.withConnection { try StudIPExtras.messageList($0) }
        let msgs = list["messages"]?.array ?? []
        XCTAssertEqual(msgs.compactMap { $0["id"]?.string }, ["moodle-13-400", "moodle-12-345"], "neueste zuerst, eigene Nachricht nicht")
        XCTAssertEqual(msgs.last?["sender"]?.string, "Moodle")
        XCTAssertEqual(msgs.first?["sender"]?.string, "Programmieren 1 – Gruppe A")
        XCTAssertEqual(msgs.last?["text"]?.string?.contains("Bitte bis 12.11. abgeben."), true)
        XCTAssertEqual(msgs.last?["url"]?.string, "\(base)/message/index.php?convid=12")
        XCTAssertFalse(list.jsonString().contains("Erfunden Lehrperson"), "keine Personennamen gespeichert")
        XCTAssertFalse(t.requests.contains { $0.url.absoluteString.contains("mark") }, "nichts als gelesen markiert")
        XCTAssertEqual(MoodleMessages.conversationID("moodle-12-345"), 12)
        XCTAssertNil(MoodleMessages.conversationID("sp-msg-1"))
    }

    func testReplySendsOnceAndNamesAreReadLive() async throws {
        let t = FakeUniTransport()
        try messageRoutes(t)
        let svc = "\(base)/lib/ajax/service.php?sesskey=sk123&info=core_message_send_messages_to_conversation"
        t.on(svc, ajaxOK(.array([.object(["id": .number(346)])])))
        let web = MoodleWeb(base: base, transport: t, retry: noWait)
        let names = try await MoodleMessagesSync.memberNames(web: web, conversation: 12)
        XCTAssertEqual(names, ["Erfunden Lehrperson"])
        let id = try await MoodleMessagesSync.reply(web: web, conversation: 12, text: "Danke!\nBis Donnerstag.")
        XCTAssertEqual(id, 346)
        let sent = t.requests.filter { $0.url.absoluteString.hasPrefix(svc) }
        XCTAssertEqual(sent.count, 1)
        let body = try JSONValue.parse(sent[0].body ?? Data())
        XCTAssertEqual(body.array?.first?["args"]?["conversationid"]?.int, 12)
        XCTAssertEqual(body.array?.first?["args"]?["messages"]?.array?.first?["text"]?.string, "Danke!\nBis Donnerstag.")
        // Serverfehler: kein zweiter Versuch (sonst kaeme die Nachricht doppelt an)
        let t2 = FakeUniTransport()
        try messageRoutes(t2)
        t2.on(svc, UniResponse(status: 503))
        do {
            try await MoodleMessagesSync.reply(web: MoodleWeb(base: base, transport: t2, retry: noWait), conversation: 12, text: "x")
            XCTFail("Fehler erwartet")
        } catch {
            XCTAssertEqual(error as? MoodleError, .http(503))
        }
        XCTAssertEqual(t2.count(svc), 1)
    }

    func testExpiredSessionAsksForLogin() async throws {
        let t = FakeUniTransport()
        t.on("\(base)/message/index.php", ok("<html>Anmelden</html>", url: "\(base)/login/index.php"))
        let r = await MoodleMessagesSync.run(db: try await database(), web: MoodleWeb(base: base, transport: t, retry: noWait))
        XCTAssertTrue(r.needsLogin)
        XCTAssertNil(r.count)
    }

    // MARK: Abgabe

    func testAssignmentPagesAreRead() throws {
        XCTAssertEqual(MoodleAssign.status(html: try fx("assign-view-none.html")),
                       MoodleAssign.Status(state: .none, canEdit: true, canSubmit: false))
        XCTAssertEqual(MoodleAssign.status(html: try fx("assign-view-draft.html")).state, .draft)
        XCTAssertTrue(MoodleAssign.status(html: try fx("assign-view-draft.html")).canSubmit)
        XCTAssertEqual(MoodleAssign.status(html: try fx("assign-view-submitted.html")).state, .submitted)
        let f = try XCTUnwrap(MoodleAssign.editForm(html: fx("assign-edit.html")))
        XCTAssertEqual([f.draftItemID, f.repositoryID, f.contextID], ["555666", "5", "1234"])
        XCTAssertEqual(f.fields["action"], "savesubmission")
        let c = try XCTUnwrap(MoodleAssign.confirmForm(html: fx("assign-confirm.html")))
        XCTAssertEqual(c.statement, "Diese Arbeit ist meine eigene Leistung.")
        XCTAssertFalse(MoodleAssign.confirmFields(c, statementAccepted: false).contains { $0.0 == "submissionstatement" })
        XCTAssertTrue(MoodleAssign.confirmFields(c, statementAccepted: true).contains { $0 == ("submissionstatement", "1") })
        XCTAssertEqual(MoodleAssign.cmid(fromURL: "\(base)/mod/assign/view.php?id=7001"), 7001)
    }

    private func assignRoutes(_ t: FakeUniTransport) throws {
        t.on("\(base)/message/index.php", ok(#"<script>M.cfg = {"sesskey":"sk123"};</script><div data-userid="42"></div>"#))
        t.on("\(base)/mod/assign/view.php?id=7001&action=editsubmission", ok(try fx("assign-edit.html")))
        t.on("\(base)/repository/repository_ajax.php?action=upload", okJSON(try json("upload-ok.json")))
        t.on("\(base)/mod/assign/view.php", body: "action=savesubmission", ok(try fx("assign-view-draft.html")))
        t.on("\(base)/mod/assign/view.php?id=7001&action=submit", ok(try fx("assign-confirm.html")))
        t.on("\(base)/mod/assign/view.php", body: "action=confirmsubmit", ok(try fx("assign-view-submitted.html")))
    }

    func testDraftUploadThenExplicitSubmit() async throws {
        let t = FakeUniTransport()
        try assignRoutes(t)
        let web = MoodleWeb(base: base, transport: t, retry: noWait)
        let pdf = Data("%PDF-1.4 erfunden".utf8)
        let (st, name) = try await MoodleAssign.saveDraft(web: web, cmid: 7001, pdf: pdf, fileName: "Abgabe.pdf")
        XCTAssertEqual(st.state, .draft)
        XCTAssertEqual(name, "Abgabe.pdf")
        XCTAssertEqual(t.count("\(base)/repository/repository_ajax.php"), 1)
        let upload = try XCTUnwrap(t.requests.first { $0.url.absoluteString.contains("repository_ajax.php") })
        let uploadBody = String(decoding: upload.body ?? Data(), as: UTF8.self)
        for part in ["name=\"itemid\"\r\n\r\n555666", "name=\"repo_id\"\r\n\r\n5", "name=\"sesskey\"\r\n\r\nsk123", "%PDF-1.4 erfunden"] {
            XCTAssertTrue(uploadBody.contains(part), part)
        }
        let save = try XCTUnwrap(t.requests.first { String(decoding: $0.body ?? Data(), as: UTF8.self).contains("action=savesubmission") })
        XCTAssertTrue(String(decoding: save.body ?? Data(), as: UTF8.self).contains("files_filemanager=555666"))
        XCTAssertFalse(t.requests.contains { String(decoding: $0.body ?? Data(), as: UTF8.self).contains("confirmsubmit") },
                       "Entwurf ist noch keine Abgabe")
        // Erklaerung verlangt, aber nicht bestaetigt: nichts abgeschickt
        do {
            _ = try await MoodleAssign.submit(web: web, cmid: 7001, statementAccepted: false)
            XCTFail("ohne Bestaetigung nicht abgeben")
        } catch {
            XCTAssertEqual(error as? MoodleError, .refused("Erklärung nicht bestätigt"))
        }
        XCTAssertFalse(t.requests.contains { String(decoding: $0.body ?? Data(), as: UTF8.self).contains("confirmsubmit") })
        let done = try await MoodleAssign.submit(web: web, cmid: 7001, statementAccepted: true)
        XCTAssertEqual(done.state, .submitted)
        let confirm = t.requests.filter { String(decoding: $0.body ?? Data(), as: UTF8.self).contains("confirmsubmit") }
        XCTAssertEqual(confirm.count, 1)
        XCTAssertTrue(String(decoding: confirm[0].body ?? Data(), as: UTF8.self).contains("submissionstatement=1"))
    }

    func testAssignmentsComeFromMoodleDeadlines() async throws {
        let db = try await database()
        try await db.transaction { c in
            try c.execute("INSERT INTO courses(id, title, semester) VALUES ('lw-501', 'Programmieren 1', 'WiSe 2026/27')")
            try c.execute("""
                INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at)
                VALUES ('lw-ev-1','learnweb','lw-501','Übungsblatt 3','Übungsblatt 3','abgabe','assign','2026-11-12T23:59',
                        'https://moodle.hs-hannover.de/mod/assign/view.php?id=7001',0,'t'),
                       ('lw-ev-2','learnweb','lw-501','Test 1','Test 1','test_ende','quiz','2026-11-13T10:00',
                        'https://moodle.hs-hannover.de/mod/quiz/view.php?id=8001',0,'t')
                """)
        }
        let a = try await db.withConnection { try MoodleAssign.assignments($0) }
        XCTAssertEqual(a, [MoodleAssign.Assignment(cmid: 7001, title: "Übungsblatt 3", dueAt: "2026-11-12T23:59", course: "Programmieren 1")])
    }
}
