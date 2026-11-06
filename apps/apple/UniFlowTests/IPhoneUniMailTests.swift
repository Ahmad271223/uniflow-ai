import SwiftUI
import UIKit
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Uni-Mail auf dem iPhone (docs/IPHONE-2026-11-04.md, docs/UNI-MAIL-2026-11-05.md): Ordner als Zeile in voller Breite
/// -> Ordnerliste -> E-Mails -> E-Mail als Ebenen einer Seite (der Zurueck-Pfeil der Kopfzeile fuehrt eine Ebene
/// hoeher), Knoepfe in voller Breite, "Neue E-Mail" als ganzes Blatt ohne versehentliches Wegwischen; Uni-Kalender-
/// Termin im Lernkalender mit Quelle. Gegenprobe iPad: Liste und E-Mail nebeneinander, kein Zurueck innerhalb der Seite.
/// SOGo nachgebaut (fixtures/sogo/raw), nie ein Netz, nie ein Passwort, nichts wird gesendet.
final class IPhoneUniMailTests: IPhoneLearnTestCase {
    private var bed: ContainerTestBed!
    private var manager: ContainerManager?
    private let user = "erika.muster@stud.uni-hannover.de"

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "iphone-unimail", clock: .fixed(berlin: "2026-11-09T08:00:00")!)
    }

    override func tearDown() async throws {
        UniStubProtocol.reset()
        manager?.deactivate()
        manager = nil
        await bed.tearDown()
        bed = nil
        try await super.tearDown()
    }

    private func fx(_ name: String) throws -> Data {
        try Data(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/sogo/raw/\(name)"))
    }

    private func install() throws {
        let files: [(String, String, Int)] = [
            ("/Mail/0/view", "mailboxes.json", 200), ("/Mail/0/folderINBOX/view", "folder-inbox.json", 200),
            ("/Mail/0/folderINBOX/headers", "headers-page2.json", 200), ("/Mail/0/folderINBOX/128/view", "message-html.json", 200),
            ("/Mail/0/compose", "created-compose.json", 201), ("/newDraft1730800002-2/edit", "edit-compose.json", 200),
            ("/Mail/unseenCount", "unseen.json", 200),
        ]
        var answers: [String: (Data, Int)] = [:]
        for (p, f, s) in files { answers[p] = (try fx(f), s) }
        let json = ["Content-Type": "application/json"]
        UniStubProtocol.install { seen in
            let path = seen.url.absoluteString.components(separatedBy: "?")[0]
            if ["/markMessageRead", "/markMessageUnread", "/markMessageFlagged"].contains(where: path.hasSuffix) { return .text("{}", headers: json) }
            if let (d, s) = answers.first(where: { path.hasSuffix($0.key) })?.value { return UniStubProtocol.Reply(status: s, headers: json, body: d) }
            return UniStubProtocol.Reply(status: 404, headers: json, body: Data("{}".utf8))
        }
    }

    private func connected() throws -> UniMailConnection {
        try install()
        let stub: @MainActor (WKWebsiteDataStore) async -> UniTransport = { store in
            await URLSessionUniTransport.make(dataStore: store, allowedDomains: UniMailConnection.domains, configuration: UniStubProtocol.configuration())
        }
        let m = ContainerManager(base: bed.containers,
                                 legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                     studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                 keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock,
                                 publishesCurrent: false, uniMailTransport: stub)
        manager = m
        _ = try bed.open(m, bed.account(.luh))
        let mail = try XCTUnwrap(m.uniMail)
        mail.refreshesAfterSignIn = false
        let bed = self.bed!
        try awaiting {
            let store = mail.websiteDataStore.httpCookieStore
            await store.setCookie(bed.cookie("0xHIGHFLYxSOGo", "erfundene-sitzung", domain: "kalender.uni-hannover.de", path: "/SOGo"))
            await store.setCookie(bed.cookie("XSRF-TOKEN", "tok%2B1", domain: "kalender.uni-hannover.de", path: "/SOGo"))
        }
        mail.signedIn(user: user)
        return mail
    }

    private var sends: Int { UniStubProtocol.requests.filter { $0.url.path.hasSuffix("/send") }.count }

    private func rows(_ env: HostedEnvironment) -> [NSObject] { elements(env).filter { identifier($0) == "unimail.row" } }

    /// Ordner -> Liste -> E-Mail auf dem iPhone, jeweils eine Ebene mit genau einem Zurueck (Pfeil der Kopfzeile)
    func testFoldersListAndMessageAsLevelsWithWideButtons() throws {
        let mail = try connected()
        let env = try hostPhone(UniMailMain(connection: mail), api: local(Canned()))
        XCTAssertTrue(env.wait(timeout: 20) { !self.rows(env).isEmpty }, dump(env))
        let width = env.window.bounds.width
        XCTAssertGreaterThan(frame(element(env, id: "unimail.folders")).width, width * 0.8, "Ordner als Zeile in voller Breite")
        XCTAssertGreaterThan(frame(element(env, id: "unimail.new")).width, width * 0.6, "Neue E-Mail breit")
        XCTAssertGreaterThan(frame(element(env, id: "unimail.search")).width, width * 0.7, "Suche breit")
        XCTAssertGreaterThan(frame(element(env, id: "unimail.calendar.7")).width, width * 0.3)
        XCTAssertFalse(env.router.hasLocalBack, "Liste: der Pfeil fuehrt aus der Seite")
        assertFitsOnAllPhones(env, "Uni-Mail Liste")
        shoot(env, "iphone-unimail-liste")

        // Ordnerliste
        XCTAssertTrue(element(env, id: "unimail.folders")?.accessibilityActivate() == true)
        XCTAssertTrue(env.wait { self.button(env, "Archiv 2026") != nil }, dump(env))
        XCTAssertTrue(env.router.hasLocalBack, "Ordnerliste: der Pfeil fuehrt zur Liste zurueck")
        XCTAssertGreaterThanOrEqual(frame(button(env, "Archiv 2026")).height, 44)
        assertFits(env, "Uni-Mail Ordner")
        env.router.goBack()
        XCTAssertTrue(env.wait { self.element(env, id: "unimail.folders") != nil && !self.rows(env).isEmpty }, dump(env))
        XCTAssertFalse(env.router.hasLocalBack)

        // E-Mail als Ebene der Seite, kein Blatt
        XCTAssertTrue(rows(env).first?.accessibilityActivate() == true)
        XCTAssertTrue(env.wait(timeout: 15) { self.button(env, "Antworten") != nil }, dump(env))
        XCTAssertFalse(sheetOpen(env), "iPhone: E-Mail in der Seite statt als Blatt")
        XCTAssertTrue(env.router.hasLocalBack)
        let reply = frame(button(env, "Antworten"))
        XCTAssertGreaterThan(reply.width, width * 0.7, "Antworten in voller Breite: \(reply)")
        let all = frame(button(env, "Allen antworten")), fwd = frame(button(env, "Weiterleiten"))
        XCTAssertEqual(all.midY, fwd.midY, accuracy: 2, "Allen antworten und Weiterleiten nebeneinander")
        XCTAssertGreaterThan(all.minY, reply.maxY - 1)
        XCTAssertNotNil(button(env, "In den Papierkorb"))
        XCTAssertTrue(env.wait { self.button(env, "Anhang Blatt3.pdf öffnen oder teilen") != nil }, "Anhang: \(dump(env))")
        XCTAssertGreaterThanOrEqual(frame(button(env, "Anhang Blatt3.pdf öffnen oder teilen")).height, 43.5, "Anhang 44 pt hoch")
        assertFits(env, "Uni-Mail E-Mail")
        shoot(env, "iphone-unimail-mail")
        env.router.goBack()
        XCTAssertTrue(env.wait { !self.rows(env).isEmpty && self.button(env, "Antworten") == nil }, dump(env))
        XCTAssertEqual(sends, 0, "nichts gesendet")
    }

    /// "Neue E-Mail": ganzes Blatt (nur die volle Hoehe, Wischen schliesst nicht), Knoepfe breit, gesendet wird nichts
    func testComposeIsFullSheet() throws {
        let mail = try connected()
        let env = try hostPhone(UniMailMain(connection: mail), api: local(Canned()))
        XCTAssertTrue(env.wait(timeout: 20) { self.element(env, id: "unimail.new") != nil && !self.rows(env).isEmpty }, dump(env))
        XCTAssertTrue(element(env, id: "unimail.new")?.accessibilityActivate() == true)
        XCTAssertTrue(env.wait(timeout: 15) { self.sheetOpen(env) && self.element(env, id: "unimail.to") != nil }, dump(env))
        let sheet = try XCTUnwrap(env.hosting.presentedViewController)
        XCTAssertEqual(sheet.sheetPresentationController?.detents.map(\.identifier), [.large], "ganzes Blatt")
        XCTAssertTrue(sheet.isModalInPresentation, "Entwurf geht nicht durch Wischen verloren")
        let attach = frame(element(env, id: "unimail.attach")), save = frame(element(env, id: "unimail.save"))
        XCTAssertEqual(attach.midY, save.midY, accuracy: 2)
        XCTAssertGreaterThan(attach.width + save.width, env.window.bounds.width * 0.75, "zusammen volle Breite")
        assertFits(env, "Neue E-Mail")
        shoot(env, "iphone-unimail-neu")
        dismissSheet(env)
        XCTAssertEqual(sends, 0)
    }

    /// iPad: Liste und E-Mail nebeneinander, Ordner als Menue, kein Zurueck innerhalb der Seite, kein Blatt
    func testPadKeepsSplitLayout() throws {
        let mail = try connected()
        let env = try hostPad(UniMailMain(connection: mail), api: local(Canned()))
        XCTAssertTrue(env.wait(timeout: 20) { !self.rows(env).isEmpty }, dump(env))
        XCTAssertTrue(shows(env, "Wähle links eine E-Mail aus."))
        XCTAssertNil(element(env, id: "unimail.folderList"))
        XCTAssertTrue(rows(env).first?.accessibilityActivate() == true)
        XCTAssertTrue(env.wait(timeout: 15) { self.button(env, "Antworten") != nil }, dump(env))
        XCTAssertFalse(sheetOpen(env))
        XCTAssertFalse(env.router.hasLocalBack, "iPad: Liste bleibt sichtbar, der Pfeil verlaesst die Seite")
        XCTAssertGreaterThan(frame(button(env, "Antworten")).minX, frame(rows(env).first).maxX - 1, "E-Mail rechts der Liste")
        XCTAssertLessThan(frame(button(env, "Antworten")).width, 200, "iPad: kleine Knoepfe wie bisher")
    }

    /// Uni-Kalender-Termin im Lernkalender (iPhone: Blatt mit Quelle "Uni-Kalender", "Schließen" in voller Breite)
    func testUniCalendarEventDialogOnPhone() throws {
        let e: JSONValue = ["title": "Tutorium Analysis", "start": "10:00", "end": "11:30", "room": "1101 - F102", "source": .string(SOGo.source)]
        let env = try hostPhone(DatedEventDialog(e: e, date: "2026-11-09").padding(16), api: remote(Canned()))
        XCTAssertTrue(env.wait { self.element(env, id: "event.source") != nil }, dump(env))
        XCTAssertEqual(element(env, id: "event.source")?.accessibilityLabel, "Uni-Kalender")
        XCTAssertTrue(shows(env, "Termin aus deinem Uni-Kalender"))
        XCTAssertTrue(shows(env, "Raum 1101 - F102"), "Raum antippbar")
        XCTAssertGreaterThan(frame(button(env, "Schließen")).width, env.window.bounds.width * 0.5, "Schließen breit")
        assertFitsOnAllPhones(env, "Uni-Kalender-Termin")
        let pad = try hostPad(DatedEventDialog(e: e, date: "2026-11-09").padding(16), api: remote(Canned()))
        XCTAssertTrue(pad.wait { self.shows(pad, "Termin aus deinem Uni-Kalender") })
        XCTAssertNil(element(pad, id: "event.source"), "iPad unveraendert")
    }
}
