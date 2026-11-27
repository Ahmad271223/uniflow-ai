import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Uni-Mail der Uni Goettingen in der App (27.11.2026, docs/GOETTINGEN-MAIL-2026-11-27.md): Exchange der GWDG ueber
/// IMAP/SMTP statt SOGo. Anmeldung im eigenen Formular (ein Versuch, Passwort erst nach Erfolg in den Schluesselbund),
/// gespeicherter Uni-Zugang, abgelehntes Passwort nie ein zweites Mal, Liste/Lesen/Antworten/Senden ueber dieselbe
/// Verbindung wie bei SOGo, kein Uni-Kalender, Abmelden. Gegen die Nachbildung (IMAPFakeServer.swift), nie ein Netz.
@MainActor
final class GoettingenMailAppTests: XCTestCase {
    private var bed: ContainerTestBed!
    private var fake: IMAPFake!
    private let address = "erika.muster@stud.uni-goettingen.de"

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "goemail", clock: .fixed(berlin: "2026-11-27T10:00:00")!)
        fake = IMAPFake.goettingen()
        fake.add("INBOX", FakeMails.lecture)
        fake.add("INBOX", FakeMails.group(1), flags: ["\\Seen"])
    }

    override func tearDown() async throws {
        await bed.tearDown()
        bed = nil
        fake = nil
        try await super.tearDown()
    }

    private func manager() -> ContainerManager {
        let f = fake!
        return ContainerManager(base: bed.containers,
                                legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                    studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock,
                                publishesCurrent: false, uniMailOpener: { _ in f })
    }

    private func open() throws -> (ContainerManager, UniMailConnection) {
        let m = manager()
        _ = try bed.open(m, bed.account(.goettingen))
        let mail = try XCTUnwrap(m.uniMail)
        mail.refreshesAfterSignIn = false
        return (m, mail)
    }

    // MARK: Eingeblendet, ohne Kalender

    func testShownForGoettingenWithoutCalendar() async throws {
        let (_, mail) = try open()
        XCTAssertEqual(mail.site, .goettingen)
        XCTAssertTrue(mail.site.isIMAP)
        XCTAssertFalse(mail.isConnected)
        XCTAssertTrue(mail.hint.contains("Exchange der GWDG"))
        XCTAssertFalse(mail.hint.contains("SOGo") || mail.hint.contains("Kalender"), "kein SOGo, kein Uni-Kalender")
        XCTAssertTrue(mail.signOutText.contains("Stud.IP"), "ehrlich: der gemeinsame Uni-Zugang wird mit gelöscht")
        XCTAssertEqual(UniMailMain.pageSub(.goettingen, compact: false), "E-Mails der Universität Göttingen (Exchange der GWDG)")
        XCTAssertEqual(UniMailMain.pageSub(.luh, compact: true), "Leibniz Universität Hannover (SOGo)", "LUH unverändert")
        XCTAssertTrue(UFNavItem.visible(local: true, gradesOnDevice: false, community: false, uniMail: true).map(\.id).contains("unimail"))
        let report = await mail.importCalendar(days: 7)
        XCTAssertEqual(report, "")
        XCTAssertFalse(mail.calendarDue)
        XCTAssertTrue(fake.opened.isEmpty, "ohne Anmeldung keine Verbindung")
        let auto = await mail.autoLogin()
        XCTAssertFalse(auto, "keine unsichtbare Webansicht für IMAP")
        let adopted = await mail.adoptExistingSession(userAction: true)
        XCTAssertFalse(adopted)
    }

    // MARK: Anmelden

    func testWrongThenRightPasswordInForm() async throws {
        let (_, mail) = try open()
        let wrong = await mail.signInIMAP(username: "erika.muster", password: "falsch", remember: true)
        XCTAssertNotNil(wrong)
        XCTAssertTrue(wrong?.contains("abgelehnt") == true)
        XCTAssertFalse(wrong?.contains("falsch") == true, "Passwort nie in der Meldung")
        XCTAssertFalse(mail.isConnected)
        XCTAssertNil(UniAutoLogin.storedUsername(mail.websiteDataStore), "abgelehnt: nichts gespeichert")
        XCTAssertEqual(fake.logins, 1, "genau ein Versuch")

        let ok = await mail.signInIMAP(username: "Erika.Muster", password: "richtig-geheim", remember: true)
        XCTAssertNil(ok)
        XCTAssertTrue(mail.isConnected)
        XCTAssertEqual(mail.user, address)
        XCTAssertEqual(UniAutoLogin.storedUsername(mail.websiteDataStore), "erika.muster", "Uni-Zugang im Schlüsselbund (wie Stud.IP)")
        let attrs = try XCTUnwrap(UniAutoLogin.entry(mail.websiteDataStore)?.vault.attributes())
        XCTAssertEqual(attrs.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, "nur dieses Gerät")
        XCTAssertEqual(attrs.synchronizable, false, "nie iCloud")
        XCTAssertEqual(Set(fake.opened.map(\.host)), ["email.gwdg.de"])
        XCTAssertNil(fake.wire.range(of: Data("richtig-geheim".utf8)), "nie im Klartext")
    }

    func testRememberOffKeepsPasswordOnlyInMemory() async throws {
        let (_, mail) = try open()
        let err = await mail.signInIMAP(username: "erika.muster", password: "richtig-geheim", remember: false)
        XCTAssertNil(err)
        XCTAssertTrue(mail.isConnected)
        XCTAssertNil(UniAutoLogin.storedUsername(mail.websiteDataStore), "nichts im Schlüsselbund")
        let r = await mail.refreshInbox()
        XCTAssertEqual(r.unseen, 1)
        XCTAssertEqual(mail.unseen, 1)
    }

    // MARK: Gespeicherter Uni-Zugang

    func testStoredLoginConnectsAndRejectedIsNeverSentAgain() async throws {
        let (_, mail) = try open()
        XCTAssertEqual(UniAutoLogin.saveTyped(username: "erika.muster", password: "veraltet", store: mail.websiteDataStore), .saved)
        XCTAssertTrue(mail.hasUsableStoredLogin)
        let first = await mail.connectWithStoredLogin()
        XCTAssertFalse(first)
        XCTAssertEqual(fake.logins, 1)
        XCTAssertTrue(mail.autoConnectFailed)
        XCTAssertFalse(mail.hasUsableStoredLogin, "abgelehnt: nicht mehr anbieten")
        let again = await mail.connectWithStoredLogin()
        XCTAssertFalse(again)
        XCTAssertEqual(fake.logins, 1, "abgelehntes Passwort nie ein zweites Mal an den Mail-Rechner")
        XCTAssertEqual(UniAutoLogin.storedUsername(mail.websiteDataStore), "erika.muster", "der Eintrag bleibt für Stud.IP")
        // neues Passwort gespeichert (Einstellungen): wieder erlaubt
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(UniAutoLogin.saveTyped(username: "erika.muster", password: "richtig-geheim", store: mail.websiteDataStore), .saved)
        let ok = await mail.connectWithStoredLogin()
        XCTAssertTrue(ok)
        XCTAssertTrue(mail.isConnected)
        XCTAssertEqual(fake.logins, 2)
    }

    // MARK: Lesen, Antworten, Senden

    func testInboxReadReplySendThroughConnection() async throws {
        let (_, mail) = try open()
        let err = await mail.signInIMAP(username: "erika.muster", password: "richtig-geheim", remember: true)
        XCTAssertNil(err)
        let boxes = try await mail.mailboxes()
        XCTAssertEqual(boxes.first?["name"]?.string, "Posteingang")
        XCTAssertTrue(boxes.contains { $0["type"]?.string == "trash" })
        let l = try await mail.listing(folder: "INBOX")
        XCTAssertEqual(l["total"]?.int, 2)
        XCTAssertEqual(mail.unseen, 1)
        let cached = await mail.cachedInbox()
        XCTAssertEqual(cached?["messages"]?.array?.count, 2, "erste Seite für die Anzeige ohne Netz")
        XCTAssertEqual(SOGo.flattenUIDs(l["uids"]), [2, 1], "neueste zuerst")
        let uid = 1                                                       // Übungsblatt 3 (ungelesen, mit Anhang)
        let m = try await mail.read(folder: "INBOX", uid: uid, wasUnread: true)
        XCTAssertEqual(m["subject"]?.string, "Übungsblatt 3 – Abgabe verschoben")
        XCTAssertEqual(mail.unseen, 0)
        let file = try await mail.download(try XCTUnwrap(m["attachments"]?.array?.first))
        XCTAssertEqual(String(decoding: try Data(contentsOf: file).prefix(8), as: UTF8.self), "%PDF-1.4")
        let d = try await mail.newDraft("reply", folder: "INBOX", uid: uid)
        XCTAssertTrue(fake.deliveries.isEmpty)
        let body = SOGo.payload(d, to: .list(d.list("to").compactMap(\.string)), cc: .text(""), bcc: .text(""), subject: d.s("subject") ?? "", text: "Danke!")
        try await mail.save(d, body: body)
        XCTAssertEqual(fake.box("Entw&APw-rfe")?.messages.count, 1)
        XCTAssertTrue(fake.deliveries.isEmpty, "Speichern sendet nie")
        let r = try await mail.send(d, body: body)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(mail.sendCount, 1)
        XCTAssertEqual(fake.deliveries.count, 1)
        XCTAssertEqual(fake.deliveries[0].recipients, ["max.mueller@uni-goettingen.de"])
        XCTAssertEqual(fake.box("Gesendete Elemente")?.messages.count, 1)
        // Papierkorb und zurueck
        try await mail.trash(folder: "INBOX", uids: [uid])
        XCTAssertEqual(fake.box("Gel&APY-schte Elemente")?.messages.count, 1)
        let moved = try XCTUnwrap(fake.box("Gel&APY-schte Elemente")?.messages.first?.uid)
        try await mail.restore(uids: [moved], boxes: boxes)
        XCTAssertEqual(fake.box("INBOX")?.messages.count, 2)
        XCTAssertFalse(fake.log.contains { $0.hasPrefix("VERBOTEN") }, "nie endgültig löschen")
        if case .ok = mail.state {} else { XCTFail("Stand ok: \(mail.state)") }
    }

    func testPasswordChangedLaterSetsNeedsLogin() async throws {
        let (_, mail) = try open()
        let err = await mail.signInIMAP(username: "erika.muster", password: "richtig-geheim", remember: true)
        XCTAssertNil(err)
        // Passwort an der Uni geaendert, naechste Verbindung: abgelehnt -> "Anmeldung nötig", nie ein zweiter Versuch
        fake.password = "neu-an-der-uni"
        do {
            _ = try await mail.listing(folder: "INBOX")
            XCTFail("abgelehnt")
        } catch {
            XCTAssertEqual(error as? SOGoError, .needsLogin)
        }
        XCTAssertEqual(mail.state, .needsLogin)
        let logins = fake.logins
        let r = await mail.refreshInbox()
        XCTAssertTrue(r.needsLogin)
        XCTAssertEqual(fake.logins, logins, "kein zweites Mal")
        XCTAssertEqual(UniMailConnection.statusText(mail.state), "Uni-Mail: Anmeldung nötig")
    }

    func testSignOutClosesAndForgets() async throws {
        let (_, mail) = try open()
        let err = await mail.signInIMAP(username: "erika.muster", password: "richtig-geheim", remember: true)
        XCTAssertNil(err)
        _ = await mail.refreshInbox()
        await mail.signOut()
        XCTAssertFalse(mail.isConnected)
        XCTAssertNil(mail.user)
        XCTAssertEqual(mail.unseen, 0)
        XCTAssertNil(UniAutoLogin.storedUsername(mail.websiteDataStore), "gemerktes Passwort gelöscht")
        let cached = await mail.cachedInbox()
        XCTAssertNil(cached?["messages"]?.array?.first)
        do {
            _ = try await mail.listing(folder: "INBOX")
            XCTFail("abgemeldet")
        } catch {
            XCTAssertEqual(error as? SOGoError, .needsLogin)
        }
        let stored = await mail.connectWithStoredLogin()
        XCTAssertFalse(stored, "nach bewusstem Abmelden nie still wieder verbinden")
        XCTAssertEqual(fake.box("INBOX")?.messages.count, 2, "Mails bleiben im Postfach")
    }

    // MARK: Ansicht (iPad und iPhone)

    func testLoginFormRendersOnPadAndPhoneWidths() throws {
        let (_, mail) = try open()
        for (width, compact) in [(820.0, false), (390.0, true)] {
            let v = UniMailIMAPLoginForm(connection: mail) {}.environment(\.ufCompact, compact)
            let h = UIHostingController(rootView: v).sizeThatFits(in: CGSize(width: width, height: 3000)).height
            XCTAssertGreaterThan(h, 300, "Formular mit Text, Feldern, Knopf (Breite \(width))")
        }
        XCTAssertTrue(UniMailIMAPLoginForm.intro.contains("email.gwdg.de"))
        XCTAssertFalse(UniMailIMAPLoginForm.intro.contains("iPad"), "auf allen Geräten gleich")
    }
}
