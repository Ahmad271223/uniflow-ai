import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Seite "Nachrichten" (04.11.2026): Menuepunkt direkt nach "Übersicht" (nur lokal, mit Stud.IP oder gespeicherten
/// Nachrichten), Abzeichen "neu seit dem letzten Oeffnen" je Container, GET /api/studip/messages ueber das lokale
/// Backend, Seite mit Liste, Leser, Suche und leerem Zustand. Mit UF_SCREENSHOT_DIR (xcodebuild:
/// TEST_RUNNER_UF_SCREENSHOT_DIR) schreibt `testScreenshots` Bilder hell/dunkel, quer/hochkant. Nur erfundene Daten,
/// keine Anfrage an eine Hochschule.
@MainActor
final class MessagesAppTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        suite = "uniflow.tests.messages.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        MessagesInbox.shared.defaultsOverride = defaults
    }

    override func tearDown() async throws {
        MessagesInbox.shared.defaultsOverride = nil
        await MessagesInbox.shared.refresh(api: nil)
        defaults.removePersistentDomain(forName: suite)
        HostedEnvironment.accessibilityAutomation(false)
        try await super.tearDown()
    }

    // MARK: Daten

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-messages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private static let inbox: JSONValue = ["data": [
        ["id": "m1", "type": "messages", "attributes": [
            "subject": "Tutorium entfällt am Donnerstag",
            "message": "<p>Liebe Studierende,</p><p>das Tutorium am 12.11. fällt aus. Die Abgabe von Blatt 4 ist bis 19.11. um 12 Uhr möglich.</p><p>Viele Grüße</p>",
            "mkdate": "2026-11-04T08:15:00+01:00"],
         "relationships": ["sender": ["data": ["type": "users", "id": "u-doz"]]]],
        ["id": "m2", "type": "messages", "attributes": ["subject": "Ihre Immatrikulationsbescheinigung",
                                                         "message": "Die Bescheinigung liegt im Prüfungsamt bereit.",
                                                         "mkdate": "2026-11-02T12:00:00+01:00"],
         "relationships": ["sender": ["data": ["type": "users", "id": "____%system%____"]]]],
        ["id": "m3", "type": "messages", "attributes": ["subject": "Raumänderung Übung", "message": "Die Übung findet ab sofort in Raum F 102 statt.",
                                                         "mkdate": "2026-10-28T09:00:00+01:00"],
         "relationships": ["sender": ["data": ["type": "users", "id": "u-tut"]]]],
    ], "included": [
        ["id": "u-doz", "type": "users", "attributes": ["formatted-name": "Prof. Erika Test", "permission": "dozent"]],
        ["id": "u-tut", "type": "users", "attributes": ["formatted-name": "Max Tutor", "permission": "tutor"]],
    ]]

    /// Lokales Backend mit den Nachrichten aus `inbox` (oder keinen)
    private func api(messages: Bool = true) throws -> (APIClient, LocalBackendHost) {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-04T10:30:00")!)
        if messages { try store(Self.inbox, in: host) }
        return (APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)), host)
    }

    private func store(_ inbox: JSONValue, in host: LocalBackendHost) throws {
        try pumping {
            let backend = try await host.backend()
            var d = StudIPExtras.Download()
            d.messages = StudIPExtras.parseMessages(inbox["data"], included: inbox["included"], base: "https://studip.example", today: 20761)
            let clock = backend.context.clock
            try await backend.context.database.transaction { try StudIPExtras.store(d, in: $0, clock: clock) }
        }
    }

    private func pumping<T>(_ work: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await work()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(30)
        while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // Zeitueberschreitung ist ein Fehler, kein Ueberspringen (Audit P48, 08.11.2026: ein Haenger blieb sonst gruen)
        guard let result else { XCTFail("Zeitueberschreitung"); throw CancellationError() }
        return try result.get()
    }

    private func element(_ prefix: String, in env: HostedEnvironment) -> NSObject? {
        var found: NSObject?
        func visit(_ e: Any, depth: Int) {
            guard found == nil, depth < 50 else { return }
            if let o = e as? NSObject {
                if let l = o.accessibilityLabel, l.hasPrefix(prefix) { found = o; return }
                for c in o.accessibilityElements ?? [] { visit(c, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let c = o.accessibilityElement(at: i) { visit(c, depth: depth + 1) } } }
            }
            if let v = e as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        env.view.layoutIfNeeded()
        visit(env.view, depth: 0)
        return found
    }

    // MARK: Menuepunkt

    func testNavItemSitsRightAfterOverviewInStudy() {
        let local = UFNavItem.visible(local: true, gradesOnDevice: true, community: true, flashcards: true, ai: false, messages: true)
        XCTAssertEqual(Array(local.map(\.id).prefix(3)), ["dashboard", "messages", "plan"])
        let item = try? XCTUnwrap(local.first { $0.id == "messages" })
        XCTAssertEqual(item?.title, "Nachrichten")
        XCTAssertEqual(item?.icon, "message")
        XCTAssertTrue(UFIconNames.all.contains("message"), "Symbol im Katalog")
        // eingeklappte Leiste: "Nachrichten" und "Uni-Mail" nie mit demselben Symbol
        XCTAssertNotEqual(UFNavItem.messages.icon, UFNavItem.uniMail.icon)
        let both = UFNavItem.visible(local: true, gradesOnDevice: true, community: true, messages: true, uniMail: true)
        XCTAssertEqual(Set(both.map(\.icon)).count, both.count, "jedes Symbol nur einmal: \(both.map(\.icon))")
        XCTAssertEqual(item?.route, .messages)
        let study = UFNavGroup.groups(local).first { $0.id == "study" }
        XCTAssertEqual(Array(study?.items.map(\.id).prefix(2) ?? []), ["dashboard", "messages"])
        // ohne Freigabe nie, auch nicht am eigenen Server (dort bleibt die Liste wie bisher)
        XCTAssertFalse(UFNavItem.visible(local: true, gradesOnDevice: true, community: true).contains { $0.id == "messages" })
        XCTAssertEqual(UFNavItem.visible(local: false, gradesOnDevice: false, community: false).map(\.id), UFNavItem.main.map(\.id))
        // jeder sichtbare Eintrag genau einmal in den Gruppen
        let grouped = UFNavGroup.groups(local).flatMap(\.items).map(\.id)
        XCTAssertEqual(grouped.sorted(), local.map(\.id).sorted())
        // markiert nur auf der eigenen Seite; Hash-Route hin und zurueck
        XCTAssertTrue(UFNavItem.active(UFNavItem.messages, in: local, route: .messages))
        XCTAssertFalse(UFNavItem.active(UFNavItem.messages, in: local, route: .dashboard))
        XCTAssertEqual(UFRoute.messages.hash, "#/messages")
        XCTAssertEqual(UFRoute(hash: "#/messages"), .messages)
        XCTAssertEqual(UFRoute(hash: "#/nachrichten"), .messages)
        // in der unteren Leiste unter "Mehr"
        XCTAssertTrue(UFNavItem.more(visible: local).contains { $0.id == "messages" })
    }

    func testVisibilityRule() throws {
        XCTAssertTrue(MessagesInbox.showsNavItem(local: true, studipConnected: true, stored: 0), "LUH verbunden, noch nichts geladen")
        XCTAssertTrue(MessagesInbox.showsNavItem(local: true, studipConnected: false, stored: 2), "abgemeldet, Nachrichten noch da")
        XCTAssertFalse(MessagesInbox.showsNavItem(local: true, studipConnected: false, stored: 0), "Hildesheim, Demo, nicht verbunden")
        XCTAssertFalse(MessagesInbox.showsNavItem(local: false, studipConnected: true, stored: 3), "eigener Server: kein Posteingang")
        // Hochschule ohne Stud.IP (Hildesheim) gilt nie als verbunden
        // vorher `try?` + `if let`: scheiterte das Hosting, fiel die Pruefung still weg (Audit P48)
        let hosted = try hostWithEnvironment(EmptyView())
        XCTAssertFalse(MessagesInbox.studipConnected(hosted.studip), "leerer Abgleich ohne Sitzung")
    }

    func testNewSinceLastVisitAndBadgeText() {
        let ms: [JSONValue] = [["sent_at": "2026-11-04T08:15:00+01:00"], ["sent_at": "2026-11-02T12:00:00+01:00"], ["sent_at": "2026-10-28T09:00:00+01:00"]]
        XCTAssertEqual(MessagesInbox.newCount(ms, since: nil), 3, "nie geoeffnet: alle neu")
        XCTAssertEqual(MessagesInbox.newCount(ms, since: "2026-11-02T12:00:00+01:00"), 1)
        XCTAssertEqual(MessagesInbox.newCount(ms, since: "2026-11-04T08:15:00+01:00"), 0)
        // gleicher Zeitpunkt mit anderem Versatz ist nicht neu, spaeterer schon
        XCTAssertFalse(MessagesInbox.isNew("2026-11-02T13:00:00+02:00", since: "2026-11-02T12:00:00+01:00"))
        XCTAssertTrue(MessagesInbox.isNew("2026-11-02T13:01:00+02:00", since: "2026-11-02T12:00:00+01:00"))
        XCTAssertEqual(MessagesInbox.newest(ms), "2026-11-04T08:15:00+01:00")
        XCTAssertEqual(UFNavItem.badgeText(key: "messages", count: 1), "1 neue Nachricht")
        XCTAssertEqual(UFNavItem.accessibilityLabel(title: "Nachrichten", key: "messages", badge: 2), "Nachrichten, 2 neue Nachrichten")
    }

    func testBadgeCountsNewSinceLastOpenPerContainer() throws {
        let (api, host) = try api()
        let router = UFRouter()
        let inbox = MessagesInbox.shared
        try pumping { inbox.attach(router, api: api); await inbox.refresh(api: api) }
        XCTAssertEqual(inbox.stored, 3)
        XCTAssertEqual(router.badge(for: "messages"), 3, "nie geoeffnet: alle neu")
        XCTAssertNil(inbox.markSeen(), "vorher keine Marke")
        XCTAssertEqual(router.badge(for: "messages"), 0)
        XCTAssertEqual(defaults.string(forKey: MessagesInbox.seenKey), "2026-11-04T08:15:00+01:00", "Marke im Container")
        // ein Abgleich bringt eine neuere und eine aeltere Nachricht: nur die neuere zaehlt
        var more = Self.inbox
        var data = more["data"]?.array ?? []
        data.append(["id": "m4", "type": "messages", "attributes": ["subject": "Neu", "message": "x", "mkdate": "2026-11-04T09:00:00+01:00"]])
        data.append(["id": "m5", "type": "messages", "attributes": ["subject": "Alt", "message": "y", "mkdate": "2026-10-01T09:00:00+02:00"]])
        more = ["data": .array(data), "included": more["included"] ?? .array([])]
        try store(more, in: host)
        try pumping { await inbox.refresh(api: api) }
        XCTAssertEqual(inbox.stored, 5)
        XCTAssertEqual(router.badge(for: "messages"), 1)
        // anderer Container (eigene Einstellungen): eigene Marke
        let other = try XCTUnwrap(UserDefaults(suiteName: suite + ".b"))
        defer { other.removePersistentDomain(forName: suite + ".b") }
        inbox.defaultsOverride = other
        try pumping { await inbox.refresh(api: api) }
        XCTAssertEqual(router.badge(for: "messages"), 5)
        inbox.defaultsOverride = defaults
        // eigener Server: nichts
        try pumping { await inbox.refresh(api: nil) }
        XCTAssertEqual(inbox.stored, 0)
        XCTAssertEqual(router.badge(for: "messages"), 0)
    }

    func testSidebarShowsItemWithBadgeAfterOverview() throws {
        let (api, _) = try api()
        try pumping { await MessagesInbox.shared.refresh(api: api) }
        let env = try hostWithEnvironment(UFSidebar(collapsed: false, allowCollapse: true).frame(width: UF.sidebar), api: api,
                                          size: CGSize(width: 400, height: 1000))
        env.router.setBadge(MessagesInbox.shared.newCount, for: "messages")
        XCTAssertTrue(env.wait { env.labels().contains("Nachrichten, 3 neue Nachrichten") }, env.labels().joined(separator: "\n"))
        let l = env.labels()
        let overview = try XCTUnwrap(l.firstIndex(of: "Übersicht"))
        let messages = try XCTUnwrap(l.firstIndex(of: "Nachrichten, 3 neue Nachrichten"))
        XCTAssertEqual(messages, overview + 1, "direkt nach Übersicht: \(l)")
        let row = try XCTUnwrap(element("Nachrichten, 3", in: env))
        XCTAssertTrue(row.accessibilityActivate())
        XCTAssertTrue(env.wait { env.router.route == .messages })
    }

    func testSidebarHidesItemWithoutStudIPAndMessages() throws {
        let (api, _) = try api(messages: false)
        try pumping { await MessagesInbox.shared.refresh(api: api) }
        let env = try hostWithEnvironment(UFSidebar(collapsed: false, allowCollapse: true).frame(width: UF.sidebar), api: api,
                                          size: CGSize(width: 400, height: 1000))
        XCTAssertTrue(env.wait { env.labels().contains("Übersicht") })
        XCTAssertFalse(env.labels().contains { $0.hasPrefix("Nachrichten") }, env.labels().joined(separator: "\n"))
    }

    // MARK: Endpunkt ueber die App

    func testEndpointThroughLocalTransport() throws {
        let (api, _) = try api()
        let all = try pumping { try await api.value("/api/studip/messages") }
        XCTAssertEqual(all.list("messages").compactMap { $0.s("id") }, ["sp-msg-m1", "sp-msg-m2", "sp-msg-m3"])
        XCTAssertEqual(all.i("total"), 3)
        XCTAssertEqual(all.list("messages").map { $0.s("sender") ?? "" }, ["Lehrende", "Stud.IP", "Tutor/in"])
        let hit = try pumping { try await api.value("/api/studip/messages?q=\(APIClient.queryValue("prüfungsamt"))") }
        XCTAssertEqual(hit.list("messages").compactMap { $0.s("id") }, ["sp-msg-m2"])
    }

    // MARK: Seite

    private func page(_ api: APIClient, split: Bool, query: String = "", size: CGSize = CGSize(width: 1100, height: 900)) throws -> HostedEnvironment {
        let env = try hostWithEnvironment(MessagesPage(today: "2026-11-04", splitOverride: split, initialQuery: query), api: api, size: size)
        env.router.go(.messages)
        return env
    }

    func testListAndReaderSideBySide() throws {
        let (api, _) = try api()
        let env = try page(api, split: true)
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Neu, Tutorium entfällt am Donnerstag, von Lehrende, 08:15") } },
                      env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.wait { env.labels().contains(MessagesText.open) && self.defaults.string(forKey: MessagesInbox.seenKey) != nil },
                      env.labels().joined(separator: "\n"))
        let l = env.labels()
        let day = NewsRow.time("2026-11-02T12:00:00+01:00", today: "2026-11-04")
        XCTAssertTrue(l.contains("Neu, Ihre Immatrikulationsbescheinigung, von Stud.IP, \(day)"), l.joined(separator: "\n"))
        XCTAssertTrue(l.contains { $0.hasPrefix("Neu, Raumänderung Übung, von Tutor/in") })
        // die erste Nachricht steht im Leser: ganzer Text, Termine, "In Stud.IP öffnen"
        XCTAssertTrue(l.contains { $0.contains("Blatt 4 ist bis 19.11. um 12 Uhr möglich") }, "ganzer Text")
        XCTAssertTrue(l.contains { $0.hasPrefix("Erkannte Termine:") && $0.contains("Ausfall? 12.11.") && $0.contains("Frist 19.11.") },
                      l.filter { $0.contains("Termine") }.joined(separator: " | "))
        XCTAssertTrue(l.contains(MessagesText.open))
        XCTAssertTrue(l.contains(MessagesText.privacy))
        XCTAssertFalse(l.contains { $0.contains("Erika") || $0.contains("Max Tutor") }, "keine Personennamen")
        // Seite offen: alles gesehen, die Punkte bleiben fuer diesen Besuch
        XCTAssertEqual(defaults.string(forKey: MessagesInbox.seenKey), "2026-11-04T08:15:00+01:00")
        // andere Nachricht waehlen
        let second = try XCTUnwrap(element("Neu, Ihre Immatrikulationsbescheinigung", in: env))
        XCTAssertTrue(second.accessibilityActivate())
        XCTAssertTrue(env.wait { env.labels().contains { $0.contains("liegt im Prüfungsamt bereit") } }, env.labels().joined(separator: "\n"))
    }

    /// Uni Hildesheim (05.11.2026): Learnweb-Unterhaltungen (erfunden, Moodle-Format) in derselben Liste, Leser mit
    /// "Im Learnweb öffnen", ohne Personennamen
    func testLearnwebMessagesOfHildesheim() throws {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-04T10:30:00")!)
        let convs: JSONValue = ["conversations": [
            ["id": 12, "type": 1, "name": "", "members": [["id": 815, "fullname": "Erika Beispiel"]],
             "messages": [["id": 345, "useridfrom": 815, "text": "<p>Die Sprechstunde am 12.11. um 14 Uhr fällt aus.</p>", "timecreated": 1_793_786_400]]],
            ["id": 13, "type": 2, "name": "Lerngruppe Statistik A",
             "messages": [["id": 399, "useridfrom": 900, "text": "Treffen Donnerstag?", "timecreated": 1_793_700_000]]],
        ]]
        try pumping {
            let backend = try await host.backend()
            let items = LearnwebMessages.parseConversations(convs, me: 4711, base: "https://www.uni-hildesheim.de/learnweb2026", today: 20761)
            var d = StudIPExtras.Download()
            d.messages = items
            let clock = backend.context.clock
            try await backend.context.database.transaction { try StudIPExtras.store(d, in: $0, clock: clock) }
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let env = try page(api, split: true)
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Neu, Nachricht im Learnweb, von Learnweb-Kontakt") } },
                      env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.wait { env.labels().contains(MessagesText.openLearnweb) }, env.labels().joined(separator: "\n"))
        let l = env.labels()
        XCTAssertTrue(l.contains { $0.hasPrefix("Neu, Lerngruppe Statistik A, von Learnweb-Gruppe") }, l.joined(separator: "\n"))
        XCTAssertTrue(l.contains { $0.contains("Sprechstunde am 12.11. um 14 Uhr fällt aus") })
        XCTAssertFalse(l.contains(MessagesText.open), "kein Stud.IP-Knopf")
        XCTAssertFalse(l.contains { $0.contains("Erika") }, "keine Personennamen")
    }

    func testSecondVisitShowsNoNewDots() throws {
        let (api, _) = try api()
        defaults.set("2026-11-02T12:00:00+01:00", forKey: MessagesInbox.seenKey)
        let env = try page(api, split: true)
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Neu, Tutorium entfällt") } }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains { $0.hasPrefix("Ihre Immatrikulationsbescheinigung, von Stud.IP") }, "vor der Marke: kein Punkt")
    }

    func testPortraitPushesReaderAndBack() throws {
        let (api, _) = try api()
        let env = try page(api, split: false, size: CGSize(width: 700, height: 1000))
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Neu, Tutorium entfällt") } }, env.labels().joined(separator: "\n"))
        XCTAssertFalse(env.labels().contains(MessagesText.open), "hochkant zuerst nur die Liste")
        let row = try XCTUnwrap(element("Neu, Raumänderung Übung", in: env))
        XCTAssertTrue(row.accessibilityActivate())
        XCTAssertTrue(env.wait { env.labels().contains { $0.contains("Raum F 102") } }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains(MessagesText.open))
        // Zurueck-Pfeil oben links (06.11.2026): schliesst erst die Nachricht, die Seite bleibt
        XCTAssertFalse(env.labels().contains("Zurück zu den Nachrichten"), "kein zweiter Pfeil in der Seite")
        let route = env.router.route
        env.router.goBack()
        XCTAssertTrue(env.wait { !env.labels().contains(MessagesText.open) && env.labels().contains { $0.hasPrefix("Neu, Tutorium") } })
        XCTAssertEqual(env.router.route, route)
    }

    func testSearchFiltersAndShowsNoHits() throws {
        let (api, _) = try api()
        var env = try page(api, split: true, query: "Raum")
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Neu, Raumänderung Übung") } }, env.labels().joined(separator: "\n"))
        XCTAssertFalse(env.labels().contains { $0.hasPrefix("Neu, Tutorium") }, "gefiltert")
        XCTAssertTrue(env.labels().contains(MessagesText.searchPrompt))
        XCTAssertTrue(env.labels().contains { $0.hasPrefix("3 Nachrichten") }, "Kopf zaehlt alle")
        env = try page(api, split: false, query: "gibtsnicht")
        XCTAssertTrue(env.wait { env.labels().contains(MessagesText.noHits("gibtsnicht")) }, env.labels().joined(separator: "\n"))
    }

    func testEmptyStateNamesLastSync() throws {
        let (api, _) = try api(messages: false)
        let env = try page(api, split: true)
        XCTAssertTrue(env.wait { env.labels().contains { $0.contains(MessagesText.empty) } }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains { $0.contains("Noch nicht mit Stud.IP abgeglichen") })
        XCTAssertFalse(env.labels().contains(MessagesText.searchPrompt), "ohne Nachrichten keine Suche")
        XCTAssertEqual(MessagesText.syncLine(Date(timeIntervalSince1970: 1_793_781_000)), "Zuletzt abgeglichen: 04.11.2026, 09:30 Uhr")
        XCTAssertEqual(MessagesText.fullDate("2026-11-02T08:15:00+01:00"), "Mo., 02.11.2026, 08:15 Uhr")
    }

    func testLargeTypeKeepsSubjectWhole() throws {
        let (api, _) = try api()
        let env = try hostWithEnvironment(MessagesPage(today: "2026-11-04", splitOverride: false)
            .environment(\.dynamicTypeSize, .accessibility3), api: api, size: CGSize(width: 700, height: 1000))
        XCTAssertTrue(env.wait { env.labels().contains { $0.hasPrefix("Neu, Ihre Immatrikulationsbescheinigung") } }, env.labels().joined(separator: "\n"))
    }

    // MARK: Bilder

    func testScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (api, _) = try api()
        defaults.set("2026-11-02T12:00:00+01:00", forKey: MessagesInbox.seenKey)          // eine neu, zwei schon gesehen
        let oldSidebar = UserDefaults.standard.string(forKey: "sidebar")
        UserDefaults.standard.set("full", forKey: "sidebar")
        defer { UserDefaults.standard.set(oldSidebar, forKey: "sidebar") }
        let env = try hostWithEnvironment(MainView(), api: api, size: CGSize(width: 1376, height: 1032))
        // Uebersicht mit Abzeichen an "Nachrichten"
        XCTAssertTrue(env.wait(timeout: 15) { env.labels().contains { $0 == "Nachrichten, 1 neue Nachricht" } }, env.labels().joined(separator: "\n"))
        shoot(env, "nachrichten-01-seitenleiste-abzeichen", to: dir, sizes: [(CGSize(width: 1376, height: 1032), "landscape")])
        env.router.go(.messages)
        _ = env.wait { env.labels().contains(MessagesText.open) }
        shoot(env, "nachrichten-02-seite", to: dir, sizes: [(CGSize(width: 1376, height: 1032), "landscape"), (CGSize(width: 834, height: 1194), "portrait")])
        // gross geschrieben, hochkant mit offenem Leser
        let (empty, _) = try self.api(messages: false)
        let e = try hostWithEnvironment(MainView(), api: empty, size: CGSize(width: 1376, height: 1032))
        e.router.go(.messages)
        _ = e.wait { e.labels().contains { $0.contains(MessagesText.empty) } }
        shoot(e, "nachrichten-03-leer", to: dir, sizes: [(CGSize(width: 1376, height: 1032), "landscape")])
        let r = try hostWithEnvironment(MessagesPage(today: "2026-11-04", splitOverride: false).environment(\.dynamicTypeSize, .accessibility2),
                                        api: api, size: CGSize(width: 834, height: 1194))
        _ = r.wait { r.labels().contains { $0.hasPrefix("Tutorium entfällt") } }                  // schon gesehen: ohne "Neu"
        r.pump(1.0)
        let row = try XCTUnwrap(element("Tutorium entfällt", in: r))
        XCTAssertTrue(row.accessibilityActivate())
        XCTAssertTrue(r.wait { r.labels().contains(MessagesText.open) })
        shoot(r, "nachrichten-04-leser-gross", to: dir, sizes: [(CGSize(width: 834, height: 1194), "portrait")])
    }

    private func png(_ view: UIView) -> Data {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    private func shoot(_ env: HostedEnvironment, _ name: String, to dir: URL, sizes: [(CGSize, String)]) {
        for (size, orientation) in sizes {
            env.window.frame = CGRect(origin: .zero, size: size)
            env.view.frame = env.window.bounds
            env.pump(1.0)
            for (style, tone) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
                env.window.overrideUserInterfaceStyle = style
                env.pump(0.8)
                let file = dir.appendingPathComponent("\(name)-\(tone)-\(orientation).png")
                do { try png(env.view).write(to: file) } catch { XCTFail("\(file.lastPathComponent): \(error)") }
            }
            env.window.overrideUserInterfaceStyle = .unspecified
        }
    }
}
