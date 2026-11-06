import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Uni-Mail und Uni-Kalender der LUH (SOGo, docs/UNI-MAIL-2026-11-05.md) in der App: Menuepunkt, Anmeldung erkennen,
/// Liste mit Seiten, Lesen, Antworten (gesendet nur nach "Senden"), Papierkorb, abgelaufene Anmeldung, Kalender in den
/// Stundenplan, Hintergrund mit Mitteilung, Abmelden. Antworten aus nachgebauten Dateien (fixtures/sogo/raw) ueber
/// `UniStubProtocol`; nie ein echtes Netz, nie ein Passwort.
@MainActor
final class UniMailAppTests: XCTestCase {
    private var bed: ContainerTestBed!
    private let user = "erika.muster@stud.uni-hannover.de"
    private var base: String { "https://kalender.uni-hannover.de/SOGo/so/\(user)" }

    override func setUp() async throws {
        bed = try ContainerTestBed(name: "unimail", clock: .fixed(berlin: "2026-11-09T08:00:00")!)
    }

    override func tearDown() async throws {
        UniStubProtocol.reset()
        await bed.tearDown()
        bed = nil
    }

    private func fx(_ name: String) throws -> Data {
        try Data(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/sogo/raw/\(name)"))
    }

    private func manager() -> ContainerManager {
        let stub: @MainActor (WKWebsiteDataStore) async -> UniTransport = { store in
            await URLSessionUniTransport.make(dataStore: store, allowedDomains: UniMailConnection.domains, configuration: UniStubProtocol.configuration())
        }
        return ContainerManager(base: bed.containers,
                                legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                    studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock,
                                publishesCurrent: false, uniMailTransport: stub)
    }

    /// SOGo nachgebaut; `login`: jede Anfrage endet auf der Anmeldeseite
    private func install(login: Bool = false) throws {
        let files: [(String, String, Int)] = [
            ("/Mail/0/view", "mailboxes.json", 200), ("/Mail/0/folderINBOX/view", "folder-inbox.json", 200),
            ("/Mail/0/folderINBOX/headers", "headers-page2.json", 200), ("/Mail/0/folderINBOX/128/view", "message-html.json", 200),
            ("/128/reply", "created-reply.json", 201), ("/Mail/0/compose", "created-compose.json", 201),
            ("/newDraft1730800001-1/edit", "edit-reply-html.json", 200), ("/newDraft1730800002-2/edit", "edit-compose.json", 200),
            ("/send", "send-ok.json", 200), ("/Mail/unseenCount", "unseen.json", 200), ("/Calendar/eventslist", "events.json", 200),
        ]
        var answers: [String: (Data, Int)] = [:]
        for (p, f, s) in files { answers[p] = (try fx(f), s) }
        let page = try Data(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/sogo/raw/login-page.html"))
        let json = ["Content-Type": "application/json"]
        UniStubProtocol.install { seen in
            if login { return UniStubProtocol.Reply(status: 200, headers: ["Content-Type": "text/html"], body: page) }
            let path = seen.url.absoluteString.components(separatedBy: "?")[0]
            if path.contains("/asAttachment/") { return .text("%PDF-1.4 erfunden", headers: ["Content-Type": "application/pdf"]) }
            if path.hasSuffix("/save") { return .text(#"{"uid":40,"lastAttachmentAttrs":[{"filename":"Blatt.pdf","size":"1 KB"}]}"#, headers: json) }
            if ["/markMessageRead", "/markMessageUnread", "/markMessageFlagged", "/batchDelete", "/moveMessages"].contains(where: path.hasSuffix) {
                return .text("{}", headers: json)
            }
            if let (d, s) = answers.first(where: { path.hasSuffix($0.key) })?.value { return UniStubProtocol.Reply(status: s, headers: json, body: d) }
            return UniStubProtocol.Reply(status: 404, headers: json, body: Data("{}".utf8))
        }
    }

    /// LUH-Container mit angemeldetem Uni-Mail (Cookies wie nach der Anmeldung, erfunden)
    private func connected() async throws -> (ContainerManager, ActiveContainer, UniMailConnection) {
        let m = manager()
        let c = try bed.open(m, bed.account(.luh))
        let mail = try XCTUnwrap(m.uniMail)
        mail.refreshesAfterSignIn = false
        let store = mail.websiteDataStore.httpCookieStore
        await store.setCookie(bed.cookie("0xHIGHFLYxSOGo", "erfundene-sitzung", domain: "kalender.uni-hannover.de", path: "/SOGo"))
        await store.setCookie(bed.cookie("XSRF-TOKEN", "tok%2B1", domain: "kalender.uni-hannover.de", path: "/SOGo"))
        mail.signedIn(user: user)
        return (m, c, mail)
    }

    private var sends: [UniStubProtocol.Seen] { UniStubProtocol.requests.filter { $0.url.path.hasSuffix("/send") } }

    // MARK: Menue und Anmeldung

    func testNavItemRouteAndBadgeText() {
        XCTAssertEqual(UFRoute(hash: "#/unimail"), .uniMail)
        XCTAssertEqual(UFRoute.uniMail.hash, "#/unimail")
        let items = UFNavItem.visible(local: true, gradesOnDevice: true, community: false, messages: true, uniMail: true).map(\.id)
        XCTAssertEqual(Array(items.prefix(3)), ["dashboard", "messages", "unimail"])
        XCTAssertFalse(UFNavItem.visible(local: false, gradesOnDevice: true, community: false, uniMail: true).map(\.id).contains("unimail"),
                       "am eigenen Server nie")
        XCTAssertEqual(UFNavGroup.groups(UFNavItem.visible(local: true, gradesOnDevice: true, community: false, uniMail: true)).first?.items.map(\.id).prefix(2),
                       ["dashboard", "unimail"])
        XCTAssertEqual(UFNavItem.badgeText(key: "unimail", count: 3), "3 ungelesene E-Mails")
        XCTAssertEqual(BackgroundNotice.newUniMail(2)?.body, "2 neue E-Mails im Uni-Postfach")
    }

    func testSignInDetectionAndOnlyAtLUH() throws {
        XCTAssertEqual(UniMailLoginPane<EmptyView>.signedInUser(URL(string: "https://kalender.uni-hannover.de/SOGo/so/\(user)/Calendar/view")), user)
        XCTAssertNil(UniMailLoginPane<EmptyView>.signedInUser(URL(string: "https://kalender.uni-hannover.de/SOGo/")))
        XCTAssertNil(UniMailLoginPane<EmptyView>.signedInUser(URL(string: "https://evil.example/SOGo/so/x/Mail")))
        XCTAssertNil(UniMailLoginPane<EmptyView>.signedInUser(URL(string: "http://kalender.uni-hannover.de/SOGo/so/x/Mail")))
        let m = manager()
        _ = try bed.open(m, bed.account(.luh))
        XCTAssertNotNil(m.uniMail)
        XCTAssertEqual(m.uniMail?.state, .notConnected)
        let h = manager()
        _ = try bed.open(h, bed.account(.hsh))
        XCTAssertNil(h.uniMail, "nur an der LUH")
    }

    // MARK: Lesen

    func testListPagingReadAndCache() async throws {
        try install()
        let (_, _, mail) = try await connected()
        let r = await mail.refreshInbox()
        XCTAssertEqual(r.unseen, 2)
        XCTAssertEqual(mail.unseen, 2)
        if case .ok = mail.state {} else { XCTFail("\(mail.state)") }
        let cached = await mail.cachedInbox()
        XCTAssertEqual(cached?["total"]?.int, 64)
        XCTAssertEqual(cached?["stale"]?.bool, true)
        let listing = try await mail.listing(folder: "INBOX")
        let page = try await mail.page(folder: "INBOX", uids: SOGo.flattenUIDs(listing["uids"]), page: 1)
        XCTAssertEqual(page.map { $0["uid"]?.int }, [78])
        let headerBody = try JSONValue.parse(UniStubProtocol.requests.last { $0.url.path.hasSuffix("/headers") }?.body ?? Data())
        XCTAssertEqual(headerBody["uids"]?.array?.count, 14, "Seite 2 = UIDs 78 bis 65")
        let msg = try await mail.read(folder: "INBOX", uid: 128, wasUnread: true)
        XCTAssertEqual(msg["subject"]?.string, "Übungsblatt 3 – Abgabe verschoben")
        XCTAssertFalse(msg["html"]?.string?.contains("<script") ?? true)
        XCTAssertEqual(mail.unseen, 1)
        for s in UniStubProtocol.requests {
            XCTAssertEqual(s.url.host, "kalender.uni-hannover.de")
            XCTAssertTrue(s.cookie.contains("0xHIGHFLYxSOGo=erfundene-sitzung"))
            XCTAssertEqual(s.headers["X-XSRF-TOKEN"], "tok+1")
        }
        XCTAssertTrue(sends.isEmpty)
        let file = try await mail.download(msg["attachments"]?.array?.first ?? .null)
        XCTAssertEqual(file.lastPathComponent, "Blatt3.pdf")
    }

    // MARK: Schreiben

    func testReplyIsSentOnlyByTheSendButtonAndOnce() async throws {
        try install()
        let (_, _, mail) = try await connected()
        let d = try await mail.newDraft("reply", folder: "INBOX", uid: 128)
        XCTAssertEqual(d["to"]?.array?.first?.string, "Prof. Dr. Max Beispiel <max.beispiel@example.uni-hannover.de>")
        XCTAssertTrue(d["text"]?.string?.contains("> Liebe Studierende,") == true)
        let body = SOGo.payload(d, to: .text("Prof. Dr. Max Beispiel <max.beispiel@example.uni-hannover.de>"), cc: .text(""), bcc: .text(""),
                                subject: d["subject"]?.string ?? "", text: "Danke!\n\n" + (d["text"]?.string ?? ""))
        try await mail.save(d, body: body)
        _ = try await mail.attach(d, name: "Blatt.pdf", data: Data("%PDF-1.4".utf8), mime: "application/pdf")
        XCTAssertTrue(sends.isEmpty, "Anlegen, Speichern und Anhang senden nichts")
        XCTAssertEqual(mail.sendCount, 0)
        // ohne Empfaenger: keine Anfrage
        do {
            _ = try await mail.send(d, body: SOGo.payload(d, to: .text(""), cc: .text(""), bcc: .text(""), subject: "x", text: "y"))
            XCTFail("ohne Empfaenger")
        } catch {}
        XCTAssertTrue(sends.isEmpty)
        let r = try await mail.send(d, body: body)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.method, "POST")
        XCTAssertEqual(sends.first?.url.path, "/SOGo/so/\(user)/Mail/0/folderDrafts/newDraft1730800001-1/send")
        let sent = try JSONValue.parse(sends.first?.body ?? Data())
        XCTAssertEqual(sent["isHTML"], false)
        XCTAssertTrue(sent["text"]?.string?.hasPrefix("Danke!") == true)
    }

    func testFlagsTrashRestoreNeverDeleteForGood() async throws {
        try install()
        let (_, _, mail) = try await connected()
        let boxes = try await mail.mailboxes()
        try await mail.setRead(folder: "INBOX", uid: 128, read: false)
        try await mail.setFlag(folder: "INBOX", uid: 128, flagged: true)
        try await mail.trash(folder: "INBOX", uids: [128])
        try await mail.restore(uids: [7], boxes: boxes)
        let paths = UniStubProtocol.requests.map(\.url.path)
        XCTAssertTrue(paths.contains("/SOGo/so/\(user)/Mail/0/folderINBOX/batchDelete"))
        XCTAssertTrue(paths.contains("/SOGo/so/\(user)/Mail/0/folderTrash/moveMessages"))
        let trash = try JSONValue.parse(UniStubProtocol.requests.first { $0.url.path.hasSuffix("/batchDelete") }?.body ?? Data())
        XCTAssertEqual(trash, ["uids": [128]], "nie withoutTrash")
        XCTAssertFalse(paths.contains { $0.contains("expunge") || $0.contains("emptyTrash") })
    }

    func testExpiredSessionMeansLoginNeeded() async throws {
        try install(login: true)
        let (_, _, mail) = try await connected()
        let r = await mail.refreshInbox()
        XCTAssertTrue(r.needsLogin)
        XCTAssertEqual(mail.state, .needsLogin)
        XCTAssertEqual(UniMailConnection.statusText(mail.state), "Uni-Mail: Anmeldung nötig")
        // im Hintergrund danach kein Versuch mehr
        let before = UniStubProtocol.requests.count
        _ = await mail.refreshInbox(background: true)
        XCTAssertEqual(UniStubProtocol.requests.count, before)
    }

    // MARK: Kalender

    func testCalendarImportReachesTimetable() async throws {
        try install()
        let (_, c, mail) = try await connected()
        let msg = await mail.importCalendar(days: 30)
        XCTAssertEqual(msg, "8 Termine der nächsten 30 Tage übernommen (1 ganztägig, nur hier in der Liste).")
        XCTAssertTrue(UniStubProtocol.requests.last?.url.query?.contains("filterpopup=view_next31") == true)
        let events = await mail.upcomingEvents()
        XCTAssertTrue(events.contains { $0["title"]?.string == "Tutorium Analysis" })
        let db = try await c.host.backend().context.database
        let day = SOGo.berlinDay(bed.clock)
        let occ = try await db.withConnection { try SOGoCalendar.occurrences($0, from: day, to: day + 6) }
        XCTAssertEqual(occ.first?["source"]?.string, "uni-kalender")
        XCTAssertEqual(occ.first?["room"]?.string, "1101 - F102")
        let week = try await c.api.value("/api/timetable/week?start=2026-11-09")
        XCTAssertTrue(week.jsonString().contains("Tutorium Analysis"), "Termin im Stundenplan der Woche")
        XCTAssertTrue(DatedEventDialog.text("2026-11-09", source: "uni-kalender").contains("Uni-Kalender"))
    }

    // MARK: Hintergrund, Abmelden

    private final class Notifier: BackgroundNotifying {
        var posts: [BackgroundNotice.Content] = []
        func requestPermission() async -> Bool { true }
        func isAllowed() async -> Bool { true }
        func post(_ content: BackgroundNotice.Content, id: String, thread: String) async { posts.append(content) }
        func schedule(_ content: BackgroundNotice.Content, id: String, thread: String, at date: Date) async {}
        func cancel(id: String) {}
    }

    private final class Scheduler: BackgroundTaskScheduling {
        func pending() async -> [BackgroundSyncKind: Date?] { [:] }
        func submit(_ kind: BackgroundSyncKind, earliest: Date) throws {}
        func cancel(_ kind: BackgroundSyncKind) {}
    }

    func testBackgroundReadsInboxFirstAndNotifiesOnlyWhenOptedIn() async throws {
        try install()
        let m = manager()
        let a = bed.account(.luh)
        a.markLoginDone()
        let c = try bed.open(m, a)
        let mail = try XCTUnwrap(m.uniMail)
        mail.refreshesAfterSignIn = false
        await mail.websiteDataStore.httpCookieStore.setCookie(bed.cookie("0xHIGHFLYxSOGo", "s", domain: "kalender.uni-hannover.de", path: "/SOGo"))
        mail.signedIn(user: user)
        let n = Notifier()
        let b = BackgroundSyncController(containers: m, account: a, settings: BackgroundSyncSettings(defaults: bed.defaults), scheduler: Scheduler(), notifier: n)
        b.allowed = { true }
        // erster Blick: merkt die neueste UID, meldet nichts
        let first = await b.runUniMail(c, kind: .refresh)
        XCTAssertEqual(first?.newMessages, 0)
        XCTAssertEqual(UniStubProtocol.requests.first?.url.path, "/SOGo/so/\(user)/Mail/0/folderINBOX/view", "Posteingang zuerst")
        // neuere UID seit dem letzten Blick: ohne Schalter keine Mitteilung, mit Schalter eine ohne Absender/Betreff
        mail.defaultsForTests.set(120, forKey: UniMailConnection.Keys.lastUID)
        _ = await b.runUniMail(c, kind: .refresh)
        XCTAssertTrue(n.posts.isEmpty)
        mail.defaultsForTests.set(120, forKey: UniMailConnection.Keys.lastUID)
        mail.notify = true
        let r = await b.runUniMail(c, kind: .refresh)
        XCTAssertEqual(r?.newMessages, 8)
        XCTAssertEqual(n.posts.map(\.body), ["8 neue E-Mails im Uni-Postfach"])
        XCTAssertTrue(sends.isEmpty)
        // Abmelden: Stand, Cookies und Termine weg
        _ = await mail.importCalendar(days: 7)
        await mail.signOut()
        XCTAssertFalse(mail.isConnected)
        XCTAssertEqual(mail.unseen, 0)
        let left = await mail.websiteDataStore.httpCookieStore.allCookies().filter { $0.domain.contains("kalender") }
        XCTAssertTrue(left.isEmpty)
        let events = await mail.upcomingEvents()
        XCTAssertTrue(events.isEmpty)
        let after = await b.runUniMail(c, kind: .refresh)
        XCTAssertNil(after, "abgemeldet: kein Lauf")
    }
}
