import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Uni-Mail und Uni-Kalender der LUH und der Uni Hildesheim (SOGo, docs/UNI-MAIL-2026-11-05.md) in der App: Menuepunkt, Anmeldung erkennen,
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
            await URLSessionUniTransport.make(dataStore: store, allowedDomains: SOGoSite.all.map(\.host), configuration: UniStubProtocol.configuration())
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
            // leere Ordner (Spam: 204 ohne Inhalt, Vorlagen: 200 mit leerem Koerper), wie SOGo am 07.11.2026
            if path.hasSuffix("/folderJunk/view") || path.hasSuffix("/folderJunk/headers") { return UniStubProtocol.Reply(status: 204, headers: [:], body: Data()) }
            if path.hasSuffix("/folderTemplates/view") { return UniStubProtocol.Reply(status: 200, headers: json, body: Data()) }
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
        XCTAssertEqual(UniMailLoginPane<EmptyView>.signedInUser(URL(string: "https://kalender.uni-hannover.de/SOGo/so/\(user)/Calendar/view"), site: .luh), user)
        XCTAssertNil(UniMailLoginPane<EmptyView>.signedInUser(URL(string: "https://kalender.uni-hannover.de/SOGo/"), site: .luh))
        XCTAssertNil(UniMailLoginPane<EmptyView>.signedInUser(URL(string: "https://evil.example/SOGo/so/x/Mail"), site: .luh))
        XCTAssertNil(UniMailLoginPane<EmptyView>.signedInUser(URL(string: "http://kalender.uni-hannover.de/SOGo/so/x/Mail"), site: .luh))
        XCTAssertNil(UniMailLoginPane<EmptyView>.signedInUser(URL(string: "https://webmail.uni-hildesheim.de/SOGo/so/x/Mail/view"), site: .luh))
        let m = manager()
        _ = try bed.open(m, bed.account(.luh))
        XCTAssertNotNil(m.uniMail)
        XCTAssertEqual(m.uniMail?.state, .notConnected)
        let h = manager()
        _ = try bed.open(h, bed.account(.hsh))
        XCTAssertNil(h.uniMail, "HsH ohne SOGo")
        XCTAssertEqual(m.uniMail?.site, .luh)
        XCTAssertEqual(m.uniMail?.domains, ["kalender.uni-hannover.de"])
    }

    // MARK: Uni Hildesheim (06.11.2026)

    private let hiUser = "muster"
    private let hiHost = "webmail.uni-hildesheim.de"

    /// Hildesheimer Container mit angemeldetem Uni-Mail (erfundene Cookies auf webmail.uni-hildesheim.de)
    private func connectedHildesheim() async throws -> (ContainerManager, ActiveContainer, UniMailConnection) {
        let m = manager()
        let c = try bed.open(m, bed.account(.hildesheim))
        let mail = try XCTUnwrap(m.uniMail, "Uni Hildesheim hat Uni-Mail")
        mail.refreshesAfterSignIn = false
        let store = mail.websiteDataStore.httpCookieStore
        await store.setCookie(bed.cookie("0xHIGHFLYxSOGo", "hi-sitzung", domain: hiHost, path: "/SOGo"))
        await store.setCookie(bed.cookie("XSRF-TOKEN", "hi%2B2", domain: hiHost, path: "/SOGo"))
        mail.signedIn(user: hiUser)
        return (m, c, mail)
    }

    func testHildesheimSignInOnlyOnItsHost() throws {
        let p = UniMailLoginPane<EmptyView>.self
        XCTAssertEqual(p.signedInUser(URL(string: "https://webmail.uni-hildesheim.de/SOGo/so/muster/Mail/view#!/Mail/0/INBOX"), site: .hildesheim), "muster")
        XCTAssertEqual(p.signedInUser(URL(string: "https://webmail.uni-hildesheim.de/SOGo/so/erika.muster%40uni-hildesheim.de/Mail/view"), site: .hildesheim),
                       "erika.muster@uni-hildesheim.de", "Form des Namens wie in der Adresse")
        XCTAssertNil(p.signedInUser(URL(string: "https://kalender.uni-hannover.de/SOGo/so/\(user)/Mail/view"), site: .hildesheim), "LUH-Adresse zaehlt nicht")
        XCTAssertNil(p.signedInUser(URL(string: "https://www.uni-hildesheim.de/SOGo/so/muster/Mail/view"), site: .hildesheim))
        XCTAssertNil(p.signedInUser(URL(string: "https://webmail.uni-hildesheim.de/SOGo/"), site: .hildesheim))
        let m = manager()
        _ = try bed.open(m, bed.account(.hildesheim))
        let mail = try XCTUnwrap(m.uniMail)
        XCTAssertEqual(mail.site, .hildesheim)
        XCTAssertEqual(mail.domains, [hiHost])
        XCTAssertEqual(mail.site.loginURL.absoluteString, "https://webmail.uni-hildesheim.de/SOGo/")
        XCTAssertEqual(mail.site.name, "Uni-Mail (Uni Hildesheim)")
        XCTAssertFalse(mail.site.roomLinks, "Raumfinder nur LUH")
        XCTAssertTrue(mail.hint.contains("Universität Hildesheim") && !mail.hint.contains("Hannover"))
        XCTAssertTrue(UFNavItem.visible(local: true, gradesOnDevice: true, community: false, uniMail: m.uniMail != nil).map(\.id).contains("unimail"),
                      "Menuepunkt an der Uni Hildesheim")
    }

    /// Debug-Stub (`-UFLoginStub`): Anmeldeseite und angemeldete Seite der Nachbildung fuer Hildesheim
    func testHildesheimDebugStubLogin() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sogo-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<a href='sogo-angemeldet.html'>Anmelden</a>".utf8).write(to: dir.appendingPathComponent("sogo.html"))
        UserDefaults.standard.set(dir.path, forKey: "UFLoginStub")
        defer {
            UserDefaults.standard.removeObject(forKey: "UFLoginStub")
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertEqual(DebugUniStub.loginPage("sogo", real: SOGoSite.hildesheim.loginURL).lastPathComponent, "sogo.html")
        let signed = dir.appendingPathComponent("sogo-angemeldet.html")
        XCTAssertEqual(UniMailLoginPane<EmptyView>.signedInUser(signed, site: .hildesheim), "muster")
        XCTAssertEqual(UniMailLoginPane<EmptyView>.signedInUser(signed, site: .luh), user)
    }

    func testHildesheimReadsSendsAndImportsOnlyAtItsHost() async throws {
        try install()
        let (m, c, mail) = try await connectedHildesheim()
        let r = await mail.refreshInbox()
        XCTAssertEqual(r.unseen, 2)
        let msg = try await mail.read(folder: "INBOX", uid: 128, wasUnread: true)
        XCTAssertEqual(msg["attachments"]?.array?.compactMap { $0["name"]?.string }, ["Blatt3.pdf", "Anhang"], "Anhang mit LUH-Adresse faellt weg")
        let file = try await mail.download(msg["attachments"]?.array?.first ?? .null)
        XCTAssertEqual(file.lastPathComponent, "Blatt3.pdf")
        let d = try await mail.newDraft("reply", folder: "INBOX", uid: 128)
        let body = SOGo.payload(d, to: .text("tutor@example.uni-hildesheim.de"), cc: .text(""), bcc: .text(""), subject: "Re", text: "Danke")
        XCTAssertTrue(sends.isEmpty)
        _ = try await mail.send(d, body: body)
        XCTAssertEqual(sends.map(\.url.absoluteString), ["https://webmail.uni-hildesheim.de/SOGo/so/muster/Mail/0/folderDrafts/newDraft1730800001-1/send"])
        let msgText = await mail.importCalendar(days: 7)
        XCTAssertTrue(msgText.contains("übernommen"), msgText)
        let db = try await c.host.backend().context.database
        let day = SOGo.berlinDay(bed.clock)
        let occ = try await db.withConnection { try SOGoCalendar.occurrences($0, from: day, to: day + 6) }
        XCTAssertEqual(occ.first?["source"]?.string, "uni-kalender")
        XCTAssertFalse(UniStubProtocol.requests.isEmpty)
        for s in UniStubProtocol.requests {
            XCTAssertEqual(s.url.host, hiHost, s.url.absoluteString)
            // relative downloadURL der Nachbildung (Konto der LUH im Pfad) laeuft auf demselben Rechner
            if !s.url.path.contains("/asAttachment/") { XCTAssertTrue(s.url.path.hasPrefix("/SOGo/so/muster/"), s.url.path) }
            XCTAssertTrue(s.cookie.contains("0xHIGHFLYxSOGo=hi-sitzung"))
            XCTAssertEqual(s.headers["X-XSRF-TOKEN"], "hi+2")
        }
        // Hintergrund mit Mitteilung folgt der Verbindung des Hildesheimer Containers
        let a = bed.account(.hildesheim)
        a.markLoginDone()
        let n = Notifier()
        let b = BackgroundSyncController(containers: m, account: a, settings: BackgroundSyncSettings(defaults: bed.defaults), scheduler: Scheduler(), notifier: n)
        b.allowed = { true }
        mail.defaultsForTests.set(120, forKey: UniMailConnection.Keys.lastUID)
        mail.notify = true
        let bg = await b.runUniMail(c, kind: .refresh)
        XCTAssertEqual(bg?.newMessages, 8)
        XCTAssertEqual(n.posts.map(\.body), ["8 neue E-Mails im Uni-Postfach"])
        XCTAssertEqual(UniStubProtocol.requests.last?.url.host, hiHost)
        // Abmelden loescht nur die Cookies dieses Rechners
        await mail.websiteDataStore.httpCookieStore.setCookie(bed.cookie("learnweb", "bleibt", domain: "www.uni-hildesheim.de", path: "/"))
        await mail.signOut()
        let left = await mail.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertFalse(left.contains { $0.domain.contains("webmail") })
        XCTAssertTrue(left.contains { $0.name == "learnweb" }, "andere Cookies der Hochschule bleiben")
    }

    func testHildesheimSessionExpiredByRedirectToOtherHost() async throws {
        try install(login: true)
        let (_, _, mail) = try await connectedHildesheim()
        let r = await mail.refreshInbox()
        XCTAssertTrue(r.needsLogin)
        XCTAssertEqual(mail.state, .needsLogin)
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

    /// Echtes iPad 07.11.2026: Ordner Spam/Vorlagen zeigten "Uni-Mail antwortet mit Fehler 204" und die Liste des
    /// Posteingangs blieb stehen. Jetzt: 0 Mails, Ordner der Antwort = der angefragte, Posteingang-Stand unberuehrt.
    func testEmptyFolderIsZeroMailsAndNeverShowsInboxMessages() async throws {
        try install()
        let (_, _, mail) = try await connected()
        let inbox = try await mail.listing(folder: "INBOX")
        XCTAssertEqual(inbox["total"]?.int, 64)
        let boxes = try await mail.mailboxes()
        let junk = SOGo.folder(ofType: "junk", in: boxes, fallback: "?"), templates = SOGo.folder(ofType: "templates", in: boxes, fallback: "?")
        XCTAssertEqual(junk, "Junk")
        XCTAssertEqual(templates, "Templates")
        let spam = try await mail.listing(folder: junk)
        XCTAssertEqual(spam["folder"]?.string, "Junk")
        XCTAssertEqual(spam["total"]?.int, 0)
        XCTAssertEqual(spam["messages"]?.array?.count, 0, "nie die Mails des Posteingangs")
        let page = try await mail.page(folder: junk, uids: [5], page: 0)
        XCTAssertTrue(page.isEmpty)
        let tpl = try await mail.listing(folder: templates)
        XCTAssertEqual(tpl["total"]?.int, 0)
        if case .ok = mail.state {} else { XCTFail("kein Fehler: \(mail.state)") }
        XCTAssertEqual(mail.unseen, 2, "Zaehler des Posteingangs bleibt")
        let cached = await mail.cachedInbox()
        XCTAssertEqual(cached?["total"]?.int, 64, "Zwischenspeicher nur fuer den Posteingang")
        XCTAssertTrue(sends.isEmpty)
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

    // MARK: Abgleich beim Oeffnen und "Neue Mails prüfen" (07.11.2026, statt eines Takts alle 20 Minuten)

    func testOpenSyncPolicyFifteenMinutes() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(OpenSyncPolicy.staleAfter, 15 * 60)
        XCTAssertTrue(OpenSyncPolicy.due(last: nil, now: t0), "Oeffnen der App / neuer Container: immer")
        XCTAssertFalse(OpenSyncPolicy.due(last: t0, now: t0.addingTimeInterval(5 * 60)))
        XCTAssertFalse(OpenSyncPolicy.due(last: t0, now: t0.addingTimeInterval(15 * 60)))
        XCTAssertTrue(OpenSyncPolicy.due(last: t0, now: t0.addingTimeInterval(15 * 60 + 1)))
        XCTAssertTrue(OpenSyncPolicy.due(last: t0.addingTimeInterval(600), now: t0), "Uhr verstellt")
        XCTAssertEqual(UniMailMain.checkTitle(checking: false), "Neue Mails prüfen")
        XCTAssertEqual(UniMailMain.checkTitle(checking: true), "Prüfe …")
    }

    private var inboxReads: Int { UniStubProtocol.requests.filter { $0.url.path.hasSuffix("/Mail/0/folderINBOX/view") }.count }

    func testSyncAllOnOpenOnceThenOnlyAfterFifteenMinutes() async throws {
        try install()
        let (m, c, _) = try await connected()
        try await Task.sleep(nanoseconds: 100_000_000)          // Start-Aufgaben des Containers vorbei
        let wasAllowed = OpenSync.allowed
        OpenSync.allowed = { true }
        OpenSync.last = [:]
        defer {
            OpenSync.allowed = wasAllowed
            OpenSync.last = [:]
            OpenSync.running = []
        }
        let t0 = bed.clock.now
        XCTAssertEqual(inboxReads, 0)
        // Oeffnen: einmal alles, Posteingang zuerst
        XCTAssertTrue(m.syncAllOnOpen(now: t0))
        try await bed.waitUntil("Posteingang beim Oeffnen") { self.inboxReads == 1 }
        XCTAssertEqual(UniStubProtocol.requests.first?.url.path, "/SOGo/so/\(user)/Mail/0/folderINBOX/view")
        XCTAssertEqual(OpenSync.last[c.key], t0)
        // kurz im Hintergrund (5 min, genau 15 min): kein neuer Gesamt-Abgleich
        XCTAssertFalse(m.syncAllOnOpen(now: t0.addingTimeInterval(5 * 60)))
        XCTAssertFalse(m.syncAllOnOpen(now: t0.addingTimeInterval(15 * 60)))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(inboxReads, 1, "nicht doppelt")
        // LUH: der Abgleich aller Portale (10.11.2026) ist erst fertig, wenn alle Portale durch sind
        try await bed.waitUntil("Abgleich beim Oeffnen fertig") { OpenSync.running.isEmpty }
        // mehr als 15 min: wieder einmal alles
        XCTAssertTrue(m.syncAllOnOpen(now: t0.addingTimeInterval(16 * 60)))
        try await bed.waitUntil("Posteingang nach 16 min") { self.inboxReads == 2 }
        XCTAssertTrue(sends.isEmpty, "nur lesend")
        // nicht erlaubt (XCTest-Vorgabe, Bildvergleiche): nichts
        OpenSync.allowed = { false }
        XCTAssertFalse(m.syncAllOnOpen(now: t0.addingTimeInterval(60 * 60)))
    }
}
