import Foundation
import XCTest
@testable import UniFlowCore

/// Uni-Mail und Uni-Kalender der LUH und der Uni Hildesheim (SOGo, docs/UNI-MAIL-2026-11-05.md): dieselben Faelle wie app/sogo.py
/// (packages/shared-contracts/fixtures/sogo/cases.json aus nachgebauten Antworten), Abruf gegen einen Transport mit
/// festen Antworten (nie ins Netz), Senden nur ueber `send`, Termine im Stundenplan.
final class SOGoTests: XCTestCase {

    private func repo(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private func raw(_ name: String) throws -> JSONValue { try JSONValue.parse(repo("packages/shared-contracts/fixtures/sogo/raw/\(name)")) }
    private func rawText(_ name: String) throws -> String { String(decoding: try repo("packages/shared-contracts/fixtures/sogo/raw/\(name)"), as: UTF8.self) }
    private func cases() throws -> JSONValue { try JSONValue.parse(repo("packages/shared-contracts/fixtures/sogo/cases.json")) }

    private func strings(_ v: JSONValue?) -> [String] { (v?.array ?? []).compactMap(\.string) }

    // MARK: Regeln wie Python

    func testPathsUserAndExpiry() throws {
        let c = try cases()
        for x in c["css"]?.array ?? [] {
            let s = x["in"]?.string ?? ""
            XCTAssertEqual(SOGo.cssIdentifier(s), x["css"]?.string, s)
            if !s.isEmpty {
                XCTAssertEqual(SOGo.folderPath(s), x["path"]?.string)
                XCTAssertEqual(SOGo.mailboxID(s), x["id"]?.string)
                XCTAssertEqual(SOGo.moveTarget(s), x["move"]?.string)
            }
        }
        for x in c["user_from_url"]?.array ?? [] {
            XCTAssertEqual(SOGo.user(fromURL: x["url"]?.string), x["user"]?.string, x["url"]?.string ?? "")
        }
        XCTAssertTrue(SOGo.looksLikeLogin(try rawText("login-page.html")))
        for x in c["expired"]?.array ?? [] {
            XCTAssertEqual(SOGo.expired(status: x["status"]?.int ?? 0, finalURL: x["final"]?.string, body: x["body"]?.string), x["expired"]?.bool,
                           "\(x)")
        }
        for x in c["truthy"]?.array ?? [] { XCTAssertEqual(SOGo.truthy(x["in"]), x["out"]?.bool, "\(x)") }
        for x in c["attachment_path"]?.array ?? [] { XCTAssertEqual(SOGo.attachmentPath(x["in"]), x["out"]?.string, "\(x)") }
        for x in c["quote_path"]?.array ?? [] { XCTAssertEqual(SOGo.quotePath(x["in"]?.string ?? ""), x["out"]?.string) }
    }

    func testRecipientsSanitizeAndText() throws {
        let c = try cases()
        for x in c["recipients"]?.array ?? [] {
            let r = SOGo.splitRecipients(x["in"]?.string ?? "")
            XCTAssertEqual(r.valid, strings(x["out"]?["valid"]), x["in"]?.string ?? "")
            XCTAssertEqual(r.invalid, strings(x["out"]?["invalid"]), x["in"]?.string ?? "")
            let parts = (x["in"]?.string ?? "").components(separatedBy: ",")
            XCTAssertEqual(parts.map { SOGo.emailOf($0).map(JSONValue.string) ?? .null }, x["email"]?.array)
        }
        for x in c["sanitize"]?.array ?? [] {
            let r = SOGo.sanitize(x["in"]?.string)
            XCTAssertEqual(r.html, x["out"]?["html"]?.string, x["in"]?.string ?? "")
            XCTAssertEqual(r.remoteBlocked, x["out"]?["remote_blocked"]?.bool, x["in"]?.string ?? "")
        }
        for x in c["text"]?.array ?? [] { XCTAssertEqual(SOGo.htmlToText(x["in"]?.string), x["out"]?.string, x["in"]?.string ?? "") }
    }

    func testMailParsersLikePython() throws {
        let c = try cases()
        let boxes = SOGo.mailboxes(try raw("mailboxes.json"))
        XCTAssertEqual(boxes, c["mailboxes"]?["out"]?.array)
        XCTAssertEqual(SOGo.folder(ofType: "trash", in: boxes, fallback: "Trash"), c["mailboxes"]?["trash"]?.string)
        XCTAssertEqual(SOGo.folder(ofType: "trash", in: [], fallback: "Trash"), c["mailboxes"]?["missing"]?.string)
        for x in c["folder_request"]?.array ?? [] { XCTAssertEqual(SOGo.folderRequest(query: x["q"]?.string ?? ""), x["body"]) }
        let listing = SOGo.folderListing(try raw("folder-inbox.json"), folder: "INBOX")
        XCTAssertEqual(listing, c["folder"]?["out"])
        let uids = SOGo.flattenUIDs(listing["uids"])
        XCTAssertEqual(SOGo.pageUIDs(uids, page: 1).map { JSONValue.number(Double($0)) }, c["folder"]?["page1"]?.array)
        XCTAssertEqual(SOGo.pageUIDs(uids, page: 9).map { JSONValue.number(Double($0)) }, c["folder"]?["page9"]?.array)
        XCTAssertEqual(SOGo.folderListing(.object([:]), folder: "Sent"), c["folder"]?["empty"])
        XCTAssertEqual(SOGo.ordered(SOGo.headers(try raw("headers-page2.json")), [79, 78, 77]), c["headers"]?["out"]?.array)
        for x in c["flatten"]?.array ?? [] { XCTAssertEqual(SOGo.flattenUIDs(x["in"]).map { JSONValue.number(Double($0)) }, x["out"]?.array, "\(x)") }
        XCTAssertEqual(SOGo.message(try raw("message-html.json"), folder: "INBOX", uid: 128), c["message_html"]?["out"])
        XCTAssertEqual(SOGo.message(try raw("message-text.json"), folder: "INBOX/Übungen", uid: 3), c["message_text"]?["out"])
        XCTAssertEqual(SOGo.unseen(try raw("unseen.json")), c["unseen"]?["inbox"]?.int)
        XCTAssertEqual(SOGo.unseen(try raw("unseen.json"), folder: "Sent"), c["unseen"]?["sent"]?.int)
        XCTAssertNil(SOGo.unseen(try raw("unseen.json"), folder: "Junk"))
        for x in c["new_since"]?.array ?? [] {
            XCTAssertEqual(SOGo.newSince(SOGo.flattenUIDs(x["uids"]), last: x["last"]?.int).map { JSONValue.number(Double($0)) }, x["out"]?.array)
        }
    }

    func testDraftsPayloadAndSendRules() throws {
        let c = try cases()
        XCTAssertThrowsError(try SOGo.created(try raw("created-bad.json")))
        XCTAssertEqual(c["created_bad"]?.string, "bad")
        let reply = SOGo.draft(created: try SOGo.created(try raw("created-reply.json")), edit: try raw("edit-reply-html.json"), action: "reply",
                               source: ["folder": "INBOX", "uid": 128])
        XCTAssertEqual(reply, c["draft_reply"]?["out"])
        let compose = SOGo.draft(created: try SOGo.created(try raw("created-compose.json")), edit: try raw("edit-compose.json"))
        XCTAssertEqual(compose, c["draft_compose"]?["out"])
        let forward = SOGo.draft(created: try SOGo.created(try raw("created-reply.json")), edit: try raw("edit-forward.json"), action: "forward",
                                 source: ["folder": "INBOX", "uid": 125])
        XCTAssertEqual(forward, c["draft_forward"]?["out"])
        let p = c["payload"]?.array ?? []
        XCTAssertEqual(SOGo.payload(reply, to: .text(p[0]["to"]?.string ?? ""), cc: .text(p[0]["cc"]?.string ?? ""), bcc: .text(""),
                                    subject: p[0]["subject"]?.string ?? "", text: p[0]["text"]?.string ?? ""), p[0]["out"])
        var withReplyTo = compose
        withReplyTo["reply_to"] = "antwort@example.uni-hannover.de"
        XCTAssertEqual(SOGo.payload(withReplyTo, to: .list(strings(p[1]["to"])), cc: .list([]), bcc: .list(strings(p[1]["bcc"])),
                                    subject: "Frage", text: "Hallo"), p[1]["out"])
        for x in c["check_send"]?.array ?? [] { XCTAssertEqual(SOGo.checkSend(x["in"] ?? .null), x["out"]?.string, "\(x)") }
        for x in c["send_result"]?.array ?? [] {
            let r = SOGo.sendResult(status: x["status"]?.int ?? 0, try x["raw"]?.string.map { try raw($0) })
            XCTAssertEqual(r.ok, x["out"]?["ok"]?.bool)
            XCTAssertEqual(r.message, x["out"]?["message"]?.string)
        }
        let m = c["multipart"]
        let mp = SOGo.multipart(name: m?["name"]?.string ?? "", data: Data((m?["data"]?.string ?? "").utf8), mime: m?["mime"]?.string ?? "")
        XCTAssertEqual(String(decoding: mp.body, as: UTF8.self), m?["out"]?.string)
        XCTAssertEqual(SOGo.multipart(name: "x", data: Data(), mime: "").contentType, m?["type"]?.string)
    }

    func testEventsCalendarsAndTimetableLikePython() async throws {
        let c = try cases()
        let events = SOGo.events(try raw("events.json"))
        XCTAssertEqual(events, c["events"]?["out"]?.array)
        XCTAssertEqual(SOGo.calendars(try raw("calendars.json")), c["calendars"]?["out"]?.array)
        for x in c["events_query"]?.array ?? [] {
            let day = BerlinClock.parseISODate(x["day"]?.string ?? "")!
            var o: [String: JSONValue] = [:]
            for (k, v) in SOGo.eventsQuery(day: day, days: x["days"]?.int ?? 0) { o[k] = .string(v) }
            XCTAssertEqual(JSONValue.object(o), x["out"])
        }
        let cal = c["calendar"]
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        let d9 = BerlinClock.parseISODate("2026-11-09")!, d11 = BerlinClock.parseISODate("2026-11-11")!
        let d15 = BerlinClock.parseISODate("2026-11-15")!, d20 = BerlinClock.parseISODate("2026-11-20")!, d30 = BerlinClock.parseISODate("2026-11-30")!
        let early = events.filter { PyText.less($0["start"]?.string ?? "", "2026-11-12") }
        let base: [JSONValue] = [
            ["event_id": 1, "date": "2026-11-09", "start": "08:15", "end": "09:45", "title": "Analysis", "status": "teilnahme"],
            ["event_id": 2, "date": "2026-11-09", "start": "10:15", "end": "11:45", "title": "tutorium  analysis", "status": "teilnahme"],
            ["event_id": 3, "date": "2026-11-10", "start": "16:00", "end": "17:00", "title": "Seminar", "status": "teilnahme"]]
        let (first, second, occ, merged, stored) = try await db.withConnection { conn -> (Int, Int, [JSONValue], [JSONValue], [JSONValue]) in
            let n = try SOGoCalendar.store(conn, events, first: d9, last: d20, fetchedAt: "2026-11-09T08:00:00")
            let m = try SOGoCalendar.store(conn, early, first: d9, last: d11, fetchedAt: "2026-11-09T09:00:00")
            let occ = try SOGoCalendar.occurrences(conn, from: d9, to: d15)
            let merged = try SOGoCalendar.withCalendar(conn, base, from: d9, to: d15)
            let stored = try SOGoCalendar.stored(conn, first: d9, last: d30)
            return (n, m, occ, merged, stored)
        }
        let empty = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        let noTable = try await empty.withConnection { try SOGoCalendar.withCalendar($0, base, from: d9, to: d15) }
        XCTAssertEqual(first, cal?["stored_first"]?.int)
        XCTAssertEqual(second, cal?["stored_second"]?.int)
        XCTAssertEqual(occ, cal?["occurrences"]?.array)
        XCTAssertEqual(merged, cal?["merged"]?.array)
        XCTAssertEqual(stored, cal?["stored"]?.array)
        XCTAssertEqual(noTable, cal?["no_table"]?.array)
    }

    // MARK: Abruf

    /// Feste Antworten je Pfad; merkt Methode, Pfad, Kopfzeilen und Koerper
    final class FakeSOGo: UniTransport, @unchecked Sendable {
        struct Seen { let method: String; let url: URL; let headers: [String: String]; let body: Data? }
        let lock = NSLock()
        var seen: [Seen] = []
        var login = false
        var sendStatus = 200
        let answers: [String: (Int, Data)]
        let base = "https://kalender.uni-hannover.de/SOGo/so/erika.muster@stud.uni-hannover.de"

        init(_ answers: [String: (Int, Data)]) { self.answers = answers }

        func send(_ r: UniRequest) async throws -> UniResponse {
            lock.withLock { seen.append(Seen(method: r.method, url: r.url, headers: r.headers, body: r.body)) }
            if login {
                return UniResponse(status: 200, headers: ["Content-Type": "text/html"], finalURL: URL(string: "https://kalender.uni-hannover.de/SOGo/"),
                                   body: Data(#"<form name="loginForm"></form>"#.utf8))
            }
            let path = r.url.absoluteString.components(separatedBy: "?")[0]
            if path.hasSuffix("/send") {
                return UniResponse(status: sendStatus, headers: ["Content-Type": "application/json"], finalURL: r.url,
                                   body: Data((sendStatus == 200 ? #"{"status":"success"}"# : #"{"status":"failure","message":"Zu viele Mails."}"#).utf8))
            }
            if let (st, body) = answers.first(where: { path.hasSuffix($0.key) })?.value {
                return UniResponse(status: st, headers: ["Content-Type": "application/json", "Set-Cookie": "XSRF-TOKEN=neu%2B2; Path=/SOGo"],
                                   finalURL: r.url, body: body)
            }
            return UniResponse(status: 404, headers: ["Content-Type": "application/json"], finalURL: r.url, body: Data("{}".utf8))
        }

        func download(_ r: UniRequest, to destination: URL) async throws -> UniResponse {
            lock.withLock { seen.append(Seen(method: r.method, url: r.url, headers: r.headers, body: nil)) }
            try Data("%PDF-1.4 erfunden".utf8).write(to: destination)
            return UniResponse(status: 200, headers: ["Content-Type": "application/pdf"], finalURL: r.url)
        }

        var paths: [String] { lock.withLock { seen.map { "\($0.method) \($0.url.path)" } } }
        func last(_ suffix: String) -> Seen? { lock.withLock { seen.last { $0.url.absoluteString.components(separatedBy: "?")[0].hasSuffix(suffix) } } }
    }

    private func fake() throws -> FakeSOGo {
        func f(_ n: String) throws -> Data { try repo("packages/shared-contracts/fixtures/sogo/raw/\(n)") }
        return FakeSOGo([
            "/Mail/0/view": (200, try f("mailboxes.json")), "/Mail/0/folderINBOX/view": (200, try f("folder-inbox.json")),
            "/Mail/0/folderINBOX/headers": (200, try f("headers-page2.json")), "/Mail/0/folderINBOX/128/view": (200, try f("message-html.json")),
            "/128/reply": (201, try f("created-reply.json")), "/Mail/0/compose": (201, try f("created-compose.json")),
            "/newDraft1730800001-1/edit": (200, try f("edit-reply-html.json")), "/newDraft1730800002-2/edit": (200, try f("edit-compose.json")),
            "/save": (200, Data(#"{"uid":40,"lastAttachmentAttrs":[{"filename":"Blatt3.pdf","size":"12 KB"}]}"#.utf8)),
            "/markMessageRead": (200, Data("{}".utf8)), "/markMessageUnread": (200, Data("{}".utf8)), "/markMessageFlagged": (200, Data("{}".utf8)),
            "/batchDelete": (200, Data("{}".utf8)), "/moveMessages": (200, Data("{}".utf8)), "/Mail/unseenCount": (200, try f("unseen.json")),
            "/Calendar/eventslist": (200, try f("events.json")),
            // leere Ordner: SOGo antwortet 204 ohne Inhalt (Spam) bzw. 200 mit leerem Koerper (Vorlagen)
            "/Mail/0/folderJunk/view": (204, Data()), "/Mail/0/folderJunk/headers": (204, Data()), "/Mail/0/folderTemplates/view": (200, Data()),
        ])
    }

    /// Echtes iPad 07.11.2026 (Uni Hildesheim): Spam und Vorlagen zeigten "Fehler 204". 204 und ein leerer Koerper sind
    /// kein Fehler, sondern ein leerer Ordner: 0 Mails, Ordner der Antwort = der angefragte.
    func testEmptyFolder204OrEmptyBodyIsZeroMailsNotAnError() async throws {
        let t = try fake()
        let s = client(t)
        let junk = try await s.folder("Junk")
        XCTAssertEqual(junk["folder"]?.string, "Junk")
        XCTAssertEqual(junk["total"]?.int, 0)
        XCTAssertEqual(junk["messages"]?.array?.count, 0)
        XCTAssertEqual(junk["unseen"], .null)
        let junkPage = try await s.headers("Junk", uids: [5])
        XCTAssertEqual(junkPage.count, 0)
        let tpl = try await s.folder("Templates")
        XCTAssertEqual(tpl["total"]?.int, 0)
        XCTAssertEqual(tpl["messages"]?.array?.count, 0)
        XCTAssertEqual(t.last("/view")?.url.path, "/SOGo/so/erika.muster@stud.uni-hannover.de/Mail/0/folderTemplates/view")
        // die Ordner Spam und Vorlagen aus Mail/0/view fuehren auf genau diese Pfade (type junk/templates, Pfad vom Server)
        let boxes = try await s.mailboxes()
        XCTAssertEqual(boxes.first { $0["name"]?.string == "Spam" }?["path"]?.string, "Junk")
        XCTAssertEqual(boxes.first { $0["name"]?.string == "Vorlagen" }?["path"]?.string, "Templates")
        XCTAssertEqual(SOGo.folderPath("Junk"), "folderJunk")
        XCTAssertEqual(SOGo.folderPath("Templates"), "folderTemplates")
    }

    private func client(_ t: FakeSOGo) -> SOGoClient {
        SOGoClient(user: "erika.muster@stud.uni-hannover.de", site: .luh, transport: t, xsrf: "tok%2B1", retry: .none)
    }

    // MARK: Hochschulen (Uni Hildesheim seit 06.11.2026)

    func testSitesFromSharedCases() throws {
        let c = try XCTUnwrap(try cases()["sites"])
        XCTAssertEqual(SOGoSite.all.map(\.host), (c["list"]?.array ?? []).compactMap { $0["host"]?.string })
        XCTAssertEqual(SOGoSite.all.map(\.name), (c["list"]?.array ?? []).compactMap { $0["name"]?.string })
        XCTAssertEqual(SOGoSite.all.map(\.roomLinks), (c["list"]?.array ?? []).compactMap { $0["room_links"]?.bool })
        XCTAssertEqual(SOGoSite.all.map(\.university.rawValue), (c["list"]?.array ?? []).compactMap { $0["key"]?.string })
        XCTAssertNil(SOGoSite.for(.hsh), "HsH ohne SOGo")
        XCTAssertNil(SOGoSite.for(university: "unbekannt"))
        XCTAssertEqual(SOGoSite.for(university: "hildesheim"), .hildesheim)
        XCTAssertEqual(SOGoSite.hildesheim.loginURL.absoluteString, "https://webmail.uni-hildesheim.de/SOGo/")
        let message = try XCTUnwrap(c["message"])
        for (key, chk) in c["checks"]?.object ?? [:] {
            let site = try XCTUnwrap(SOGoSite.for(university: key))
            XCTAssertEqual(site.base, chk["base"]?.string)
            XCTAssertEqual(SOGo.userBase("erika.muster@uni-hildesheim.de", site: site), chk["user_base"]?.string)
            for x in chk["user_from_url"]?.array ?? [] {
                XCTAssertEqual(SOGo.user(fromURL: x["url"]?.string, site: site), x["user"]?.string, "\(key) \(x["url"]?.string ?? "")")
            }
            for x in chk["expired"]?.array ?? [] {
                XCTAssertEqual(SOGo.expired(status: x["status"]?.int ?? 0, finalURL: x["final"]?.string, body: "{}", site: site), x["expired"]?.bool, "\(key) \(x)")
            }
            for x in chk["attachment_path"]?.array ?? [] { XCTAssertEqual(SOGo.attachmentPath(x["in"], site: site), x["out"]?.string, "\(key) \(x)") }
            XCTAssertEqual(SOGo.message(message, folder: "INBOX", uid: 7, site: site)["attachments"], chk["message_attachments"], key)
        }
    }

    func testHildesheimClientStaysOnItsHost() async throws {
        let t = try fake()
        let s = SOGoClient(user: "muster", site: .hildesheim, transport: t, xsrf: "hi%2B2", retry: .none)
        let boxes = try await s.mailboxes()
        XCTAssertEqual(boxes.first?["type"], "inbox")
        XCTAssertEqual(t.seen.first?.url.absoluteString, "https://webmail.uni-hildesheim.de/SOGo/so/muster/Mail/0/view")
        XCTAssertEqual(t.seen.first?.headers["X-XSRF-TOKEN"], "hi+2")
        let msg = try await s.message("INBOX", uid: 128)
        XCTAssertEqual(msg["attachments"]?.array?.map { $0["name"]?.string ?? "" }, ["Blatt3.pdf", "Anhang"], "Anhang mit Adresse der LUH faellt weg")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("sogo-hi-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: dest) }
        try await s.download(msg["attachments"]?.array?.first?["path"]?.string ?? "", to: dest)
        do {
            try await s.download("https://kalender.uni-hannover.de/SOGo/so/x/Mail/0/folderINBOX/1/2/asAttachment/a.pdf", to: dest)
            XCTFail("Rechner der LUH aus dem Hildesheimer Konto")
        } catch {}
        do {
            _ = try await s.json("GET", "https://kalender.uni-hannover.de/SOGo/so/x/Mail/0/view")
            XCTFail("fremder Rechner")
        } catch let e as SOGoError {
            if case .bad = e {} else { XCTFail("\(e)") }
        }
        for x in t.seen { XCTAssertEqual(x.url.host, "webmail.uni-hildesheim.de") }
        let cookies = [("kalender.uni-hannover.de", "luh"), ("webmail.uni-hildesheim.de", "hi%2B3"), (".uni-hildesheim.de", "breit")].compactMap {
            HTTPCookie(properties: [.name: "XSRF-TOKEN", .value: $0.1, .domain: $0.0, .path: "/SOGo"])
        }
        XCTAssertEqual(SOGoClient.xsrf(from: cookies, site: .hildesheim), "hi+3")
        XCTAssertEqual(SOGoClient.xsrf(from: cookies, site: .luh), "luh")
        XCTAssertNil(SOGoClient.xsrf(from: [cookies[0]], site: .hildesheim))
    }

    func testReadingWithXSRFAndPaging() async throws {
        let t = try fake()
        let s = client(t)
        let boxes = try await s.mailboxes()
        XCTAssertEqual(boxes.first?["type"], "inbox")
        XCTAssertEqual(t.seen.first?.headers["X-XSRF-TOKEN"], "tok+1")
        let listing = try await s.folder("INBOX")
        XCTAssertEqual(listing["total"]?.int, 64)
        XCTAssertEqual(try JSONValue.parse(t.last("/folderINBOX/view")?.body ?? Data()), ["sortingAttributes": ["sort": "arrival", "asc": 0]])
        XCTAssertEqual(s.xsrf, "neu+2", "neues Cookie XSRF-TOKEN gilt ab dann")
        let page = try await s.headers("INBOX", uids: [79, 78])
        XCTAssertEqual(page.map { $0["uid"]?.int }, [79, 78])
        XCTAssertEqual(t.last("/headers")?.headers["X-XSRF-TOKEN"], "neu+2")
        let msg = try await s.message("INBOX", uid: 128)
        XCTAssertEqual(msg["attachments"]?.array?.count, 3)
        let unseen = try await s.unseen()
        XCTAssertEqual(unseen, 7)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("sogo-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: dest) }
        try await s.download(msg["attachments"]?.array?.first?["path"]?.string ?? "", to: dest)
        XCTAssertEqual(try Data(contentsOf: dest).prefix(4), Data("%PDF".utf8))
        for x in t.seen { XCTAssertEqual(x.url.host, "kalender.uni-hannover.de") }
        do {
            try await s.download("https://evil.example/SOGo/so/x/a.pdf", to: dest)
            XCTFail("fremder Rechner")
        } catch {}
        t.login = true
        do {
            _ = try await s.folder("INBOX")
            XCTFail("abgelaufen")
        } catch let e as SOGoError {
            XCTAssertEqual(e, .needsLogin)
        }
    }

    func testReplySendsOnlyOnSendAndOnce() async throws {
        let t = try fake()
        let s = client(t)
        let d = try await s.newDraft("reply", folder: "INBOX", uid: 128)
        XCTAssertEqual(d["draft_id"], "newDraft1730800001-1")
        XCTAssertTrue(d["text"]?.string?.contains("> Liebe Studierende,") == true)
        XCTAssertNil(t.last("/send"), "Antwort anlegen sendet nichts")
        let body = SOGo.payload(d, to: .list(strings(d["to"])), cc: .list([]), bcc: .list([]), subject: d["subject"]?.string ?? "", text: "Danke!")
        let uid = try await s.save(d, body: body)
        XCTAssertEqual(uid, 40)
        let att = try await s.attach(d, name: "Blatt3.pdf", data: Data("%PDF".utf8), mime: "application/pdf")
        XCTAssertEqual(att["name"], "Blatt3.pdf")
        XCTAssertTrue(t.last("/save")?.headers["Content-Type"]?.hasPrefix("multipart/form-data") == true)
        XCTAssertNil(t.last("/send"), "Speichern und Anhang senden nichts")
        let r = try await s.send(d, body: body)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(t.paths.filter { $0.hasSuffix("/send") }, ["POST /SOGo/so/erika.muster@stud.uni-hannover.de/Mail/0/folderDrafts/newDraft1730800001-1/send"])
        let sent = try JSONValue.parse(t.last("/send")?.body ?? Data())
        XCTAssertEqual(sent["isHTML"], false)
        XCTAssertEqual(sent["text"], "Danke!")
        // ohne Empfaenger keine Anfrage
        var empty = body
        empty["to"] = .array([])
        do {
            _ = try await s.send(d, body: empty)
            XCTFail("ohne Empfaenger")
        } catch let e as SOGoError {
            if case .input = e {} else { XCTFail("\(e)") }
        }
        XCTAssertEqual(t.paths.filter { $0.hasSuffix("/send") }.count, 1)
        // Ablehnung: Meldung, kein zweiter Versuch
        t.sendStatus = 405
        let refused = try await s.send(d, body: body)
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.message, "Zu viele Mails.")
        XCTAssertEqual(t.paths.filter { $0.hasSuffix("/send") }.count, 2)
    }

    func testFlagsTrashAndRestoreNeverDeleteForGood() async throws {
        let t = try fake()
        let s = client(t)
        try await s.markRead("INBOX", uid: 128, read: false)
        try await s.flag("INBOX", uid: 128, flagged: true)
        try await s.trash("INBOX", uids: [128])
        try await s.move("Trash", uids: [5], to: "INBOX")
        XCTAssertEqual(t.paths.map { $0.components(separatedBy: "/Mail/0/").last ?? "" },
                       ["folderINBOX/128/markMessageUnread", "folderINBOX/128/markMessageFlagged", "folderINBOX/batchDelete", "folderTrash/moveMessages"])
        XCTAssertEqual(try JSONValue.parse(t.last("/batchDelete")?.body ?? Data()), ["uids": [128]])
        XCTAssertEqual(try JSONValue.parse(t.last("/moveMessages")?.body ?? Data()), ["uids": [5], "folder": "/0/folderINBOX"])
    }

    func testCalendarImportReachesTimetable() async throws {
        let t = try fake()
        let s = client(t)
        let day = BerlinClock.parseISODate("2026-11-09")!
        let events = try await s.events(day: day, days: 7)
        XCTAssertEqual(t.seen.last?.url.query, "asc=1&day=20261109&filterpopup=view_next7&search=title_Category_Location&sort=start&value=")
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: .fixed(berlin: "2026-11-09T08:00:00")!, university: "luh")
        let occ = try await db.withConnection { c -> [JSONValue] in
            try SOGoCalendar.store(c, events, first: day, last: day + 7, fetchedAt: "2026-11-09T08:00:00")
            return try LocalTimetable.occurrences(c, from: day, to: day + 6)
        }
        let mine = occ.filter { $0["source"] == "uni-kalender" }
        XCTAssertEqual(mine.first?["room"], "1101 - F102")
        XCTAssertEqual(mine.first?["start"], "10:15")
        XCTAssertFalse(mine.contains { $0["title"] == "Exkursion" }, "ganztaegige nicht im Stundenplan")
    }
}
