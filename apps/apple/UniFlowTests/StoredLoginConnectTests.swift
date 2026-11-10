import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Uni-Zugang einmal speichern (Vorgabe des Inhabers 10.11.2026, docs/AUTOMATISCH-ANMELDEN-2026-11-06.md Abschnitt
/// 1.0.2): `ContainerManager.connectWithStoredLogin` verbindet Stud.IP, QIS und Uni-Mail mit dem gespeicherten Zugang
/// selbst - auch zum ersten Mal -, gemeinsam oder je Portal ("Benutzername und Passwort sind überall gleich").
/// Abgelehnte Passwoerter werden nie ein zweites Mal gesendet; nach bewusstem Abmelden kein stilles Wiederverbinden.
/// Kein Netz: die unsichtbare Webansicht ist ersetzt (`UniAutoLogin.runnerOverride`), die Pruefung der Stud.IP-Sitzung
/// auch (`StudIPSync.storedLoginSessionCheck`). Nur erfundene Zugangsdaten.
@MainActor
final class StoredLoginConnectTests: XCTestCase {
    private let user = "testnutzer-erfunden"
    private let password = "Pw-Test-erfunden-123"
    private var services: [String] = []
    private var suite = ""

    /// eine Anfrage an die (ersetzte) unsichtbare Webansicht
    struct Call: Equatable {
        let portal: String
        let username: String
        let password: String
    }

    final class Recorder {
        var calls: [Call] = []
        var outcomes: [String: UniAutoLoginOutcome] = [:]
        var portals: [String] { calls.map(\.portal) }
    }

    override func setUp() async throws {
        suite = "uniflow.tests.unilogin.\(UUID().uuidString)"
        UniAutoLogin.settingsDefaultsOverride = UserDefaults(suiteName: suite)
        UniAutoLogin.appActiveOverride = true
        StudIPSync.storedLoginSessionCheck = { !$0.isEmpty }
    }

    override func tearDown() async throws {
        UniAutoLogin.runnerOverride = nil
        UniAutoLogin.appActiveOverride = nil
        UniAutoLogin.settingsDefaultsOverride = nil
        UserDefaults().removePersistentDomain(forName: suite)
        StudIPSync.storedLoginSessionCheck = { await StudIPSync.sessionIsValid($0) }
        for s in services { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary) }
        services = []
    }

    @MainActor private struct Bed {
        let bed: ContainerTestBed
        let m: ContainerManager
        let qis: QISConnection
        let mail: UniMailConnection
        let vault: UniCredentialStore
        var store: WKWebsiteDataStore { m.studip.websiteDataStore }
    }

    private func luh(_ name: String) throws -> Bed {
        let bed = try ContainerTestBed(name: name, clock: .fixed(berlin: "2026-11-10T09:00:00")!)
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        services.append(m.credentialService)
        let qis = try XCTUnwrap(m.qis)
        qis.syncsAfterSignIn = false
        let mail = try XCTUnwrap(m.uniMail)
        mail.refreshesAfterSignIn = false
        return Bed(bed: bed, m: m, qis: qis, mail: mail, vault: UniCredentialStore(service: m.credentialService, container: c.layout.identifier))
    }

    /// Ersatz der unsichtbaren Webansicht: merkt Dienst und Zugangsdaten, setzt bei Erfolg, was die echte Seite setzen
    /// wuerde (Stud.IP-Cookie im Datenspeicher, SOGo-Adresse mit dem Konto)
    private func install(_ rec: Recorder, mailHost: String) {
        UniAutoLogin.runnerOverride = { r in
            rec.calls.append(Call(portal: r.portal, username: r.credential.username, password: r.credential.password))
            let outcome = rec.outcomes[r.portal] ?? .success
            guard outcome == .success else { return outcome }
            switch r.portal {
            case "studip":
                let cookie = HTTPCookie(properties: [.domain: StudIPSync.base.host ?? "", .path: "/", .name: "Seminar_Session",
                                                     .value: "erfunden-\(UUID().uuidString)", .secure: "TRUE"])!
                await r.store.httpCookieStore.setCookie(cookie)
                _ = await r.isDone(URL(string: "https://\(StudIPSync.base.host ?? "")/dispatch.php/start")!, "")
            case "sogo":
                let done = await r.isDone(URL(string: "https://\(mailHost)/SOGo/so/\(r.credential.username)/Mail/view")!, "")
                if !done { return .failed }
            default:
                break
            }
            return .success
        }
    }

    // MARK: Gemeinsam

    func testSharedLoginConnectsStudIPThenQISThenMailFirstTime() async throws {
        let b = try luh("unilogin-gemeinsam")
        let rec = Recorder()
        install(rec, mailHost: b.mail.site.host)
        XCTAssertTrue(UniAutoLogin.sameEverywhere, "Vorgabe: überall gleich")
        XCTAssertFalse(b.m.hasStoredLogin)
        let none = await b.m.connectWithStoredLogin()
        XCTAssertTrue(none.noCredential)
        XCTAssertTrue(rec.calls.isEmpty)

        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, store: b.store), .saved)
        XCTAssertTrue(b.m.hasStoredLogin)
        let r = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(r.connected, ["Stud.IP", "QIS", "Uni-Mail"])
        XCTAssertEqual(r.needsLogin, [])
        XCTAssertFalse(r.rejected)
        XCTAssertEqual(r.rejectedPortals, [])
        XCTAssertEqual(rec.portals, ["studip", "qis", "sogo"], "Reihenfolge Stud.IP, QIS, Uni-Mail")
        XCTAssertTrue(rec.calls.allSatisfy { $0.username == user && $0.password == password })
        XCTAssertTrue(b.m.studip.hasStoredSession, "Stud.IP verbunden")
        XCTAssertTrue(b.qis.isConnected)
        XCTAssertTrue(b.mail.isConnected)
        XCTAssertEqual(b.mail.user, user, "Konto aus der SOGo-Adresse")
        // schon verbunden: kein weiterer Versuch
        let again = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(again.connected, ["Stud.IP", "QIS", "Uni-Mail"])
        XCTAssertEqual(rec.calls.count, 3)
        await b.bed.tearDown()
    }

    // MARK: Getrennt

    func testSeparateLoginsUseTheOwnEntryOfEachPortal() async throws {
        let b = try luh("unilogin-getrennt")
        let rec = Recorder()
        install(rec, mailHost: b.mail.site.host)
        UniAutoLogin.sameEverywhere = false
        for p in UniAutoLogin.Portal.allCases {
            XCTAssertEqual(UniAutoLogin.saveTyped(username: "\(p.rawValue)-\(user)", password: "\(password)-\(p.rawValue)", portal: p, store: b.store), .saved)
        }
        XCTAssertNil(b.vault.load(), "kein gemeinsamer Eintrag")
        XCTAssertEqual(UniAutoLogin.storedUsername(portal: .qis, store: b.store), "qis-\(user)")
        XCTAssertTrue(UniAutoLogin.hasPassword(portal: .sogo, store: b.store))
        XCTAssertFalse(UniAutoLogin.hasPassword(portal: nil, store: b.store))
        XCTAssertEqual(UniAutoLogin.credential(for: .studip, store: b.store)?.username, "studip-\(user)")
        let a = try XCTUnwrap(b.vault.portal(.qis).attributes())
        XCTAssertEqual(a.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, "je Portal ebenfalls nur dieses Geraet")
        XCTAssertEqual(a.synchronizable, false)
        let r = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(r.connected, ["Stud.IP", "QIS", "Uni-Mail"])
        XCTAssertEqual(rec.calls, UniAutoLogin.Portal.allCases.map {
            Call(portal: $0.rawValue, username: "\($0.rawValue)-\(user)", password: "\(password)-\($0.rawValue)")
        })
        // Schalter wieder an: gemeinsamer Zugang gilt (hier keiner)
        UniAutoLogin.sameEverywhere = true
        XCTAssertNil(UniAutoLogin.credential(for: .qis, store: b.store))
        await b.bed.tearDown()
    }

    func testSeparateFallsBackToTheSharedEntry() async throws {
        let b = try luh("unilogin-rueckfall")
        let rec = Recorder()
        install(rec, mailHost: b.mail.site.host)
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, store: b.store), .saved)
        UniAutoLogin.sameEverywhere = false
        XCTAssertEqual(UniAutoLogin.saveTyped(username: "qis-\(user)", password: "\(password)-qis", portal: .qis, store: b.store), .saved)
        XCTAssertEqual(UniAutoLogin.credential(for: .studip, store: b.store)?.username, user, "ohne eigenen Eintrag: der gemeinsame")
        XCTAssertEqual(UniAutoLogin.credential(for: .qis, store: b.store)?.username, "qis-\(user)")
        let r = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(r.connected, ["Stud.IP", "QIS", "Uni-Mail"])
        XCTAssertEqual(rec.calls, [Call(portal: "studip", username: user, password: password),
                                   Call(portal: "qis", username: "qis-\(user)", password: "\(password)-qis"),
                                   Call(portal: "sogo", username: user, password: password)])
        await b.bed.tearDown()
    }

    // MARK: Abgelehnt

    func testRejectionWithTheSharedLoginStopsAllPortalsAndIsNeverSentAgain() async throws {
        let b = try luh("unilogin-abgelehnt-alle")
        let rec = Recorder()
        rec.outcomes["studip"] = .wrongPassword
        install(rec, mailHost: b.mail.site.host)
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, store: b.store), .saved)
        let r = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(rec.portals, ["studip"], "nach der Ablehnung kein Versuch bei QIS oder Uni-Mail")
        XCTAssertTrue(r.rejected)
        XCTAssertEqual(r.rejectedPortals, ["Stud.IP", "QIS", "Uni-Mail"], "der gemeinsame Zugang gilt fuer alle")
        XCTAssertEqual(r.connected, [])
        XCTAssertEqual(r.needsLogin, ["Stud.IP", "QIS", "Uni-Mail"])
        XCTAssertNil(b.vault.load(), "der abgelehnte Eintrag ist vergessen")
        XCTAssertFalse(b.m.hasStoredLogin)
        XCTAssertTrue(UniAutoLogin.isRejected(portal: nil, store: b.store))
        XCTAssertFalse(b.qis.isConnected)
        // auch auf Knopfdruck nie wieder
        let again = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertTrue(again.noCredential && again.rejected)
        XCTAssertEqual(rec.calls.count, 1, "kein zweites Senden")
        await b.bed.tearDown()
    }

    func testRejectionWithSeparateLoginsStopsOnlyThatPortal() async throws {
        let b = try luh("unilogin-abgelehnt-eines")
        let rec = Recorder()
        rec.outcomes["qis"] = .wrongPassword
        install(rec, mailHost: b.mail.site.host)
        UniAutoLogin.sameEverywhere = false
        for p in UniAutoLogin.Portal.allCases {
            XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: "\(password)-\(p.rawValue)", portal: p, store: b.store), .saved)
        }
        let r = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(rec.portals, ["studip", "qis", "sogo"])
        XCTAssertEqual(r.connected, ["Stud.IP", "Uni-Mail"])
        XCTAssertEqual(r.needsLogin, ["QIS"])
        XCTAssertEqual(r.rejectedPortals, ["QIS"])
        XCTAssertTrue(r.rejected)
        XCTAssertNil(b.vault.portal(.qis).load(), "nur der abgelehnte Eintrag ist vergessen")
        XCTAssertNotNil(b.vault.portal(.studip).load())
        XCTAssertNotNil(b.vault.portal(.sogo).load())
        XCTAssertTrue(UniAutoLogin.isRejected(portal: .qis, store: b.store))
        XCTAssertFalse(UniAutoLogin.isRejected(portal: .studip, store: b.store))
        let again = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(rec.portals.filter { $0 == "qis" }.count, 1, "QIS nie ein zweites Mal")
        XCTAssertEqual(again.rejectedPortals, ["QIS"])
        // neues Passwort fuer QIS: Merker weg, QIS verbindet
        rec.outcomes["qis"] = nil
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: "\(password)-neu", portal: .qis, store: b.store), .saved)
        XCTAssertFalse(UniAutoLogin.isRejected(portal: .qis, store: b.store))
        let fixed = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(fixed.connected, ["Stud.IP", "QIS", "Uni-Mail"])
        await b.bed.tearDown()
    }

    func testARejectedPasswordIsNeverSentToAnotherPortal() async throws {
        let b = try luh("unilogin-abgelehnt-gleich")
        let rec = Recorder()
        rec.outcomes["studip"] = .wrongPassword
        install(rec, mailHost: b.mail.site.host)
        UniAutoLogin.sameEverywhere = false
        // Stud.IP und QIS mit genau demselben Zugang, Uni-Mail mit einem anderen
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, portal: .studip, store: b.store), .saved)
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, portal: .qis, store: b.store), .saved)
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: "\(password)-mail", portal: .sogo, store: b.store), .saved)
        let r = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(rec.portals, ["studip", "sogo"], "das bei Stud.IP abgelehnte Passwort geht nie an QIS")
        XCTAssertEqual(r.rejectedPortals, ["Stud.IP", "QIS"])
        XCTAssertEqual(r.connected, ["Uni-Mail"])
        XCTAssertNil(b.vault.portal(.qis).load())
        await b.bed.tearDown()
    }

    // MARK: Abmelden, Hintergrund

    func testNoSilentReconnectAfterDeliberateSignOut() async throws {
        let b = try luh("unilogin-abmelden")
        let rec = Recorder()
        install(rec, mailHost: b.mail.site.host)
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, store: b.store), .saved)
        _ = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertTrue(b.qis.isConnected)
        await b.qis.signOut()
        XCTAssertNil(b.vault.load(), "Abmelden loescht das gespeicherte Passwort")
        XCTAssertTrue(UniAutoLogin.signedOut(.qis, store: b.store))
        // ein Passwort kommt auf anderem Weg wieder (Anmeldung von Hand bei Stud.IP, mitgelesen): QIS bleibt abgemeldet
        try b.vault.save(UniCredential(username: user, password: password, savedAt: Date()))
        let before = rec.calls.count
        let r = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(rec.calls.count, before, "kein stilles Wiederverbinden")
        XCTAssertFalse(b.qis.isConnected)
        XCTAssertFalse(r.connected.contains("QIS") || r.needsLogin.contains("QIS"))
        XCTAssertEqual(r.connected, ["Stud.IP", "Uni-Mail"])
        // im Hintergrund nie, auch nicht nach neuem Speichern
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, store: b.store), .saved)
        XCTAssertFalse(UniAutoLogin.signedOut(.qis, store: b.store), "Speichern in den Einstellungen hebt die Sperre auf")
        UniAutoLogin.appActiveOverride = false
        _ = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(rec.calls.count, before, "im Hintergrund nichts")
        UniAutoLogin.appActiveOverride = true
        let back = await b.m.connectWithStoredLogin(userAction: true)
        XCTAssertEqual(back.connected, ["Stud.IP", "QIS", "Uni-Mail"])
        XCTAssertEqual(rec.portals.last, "qis")
        await b.bed.tearDown()
    }

    func testDeletingTheUniversityDataRemovesThePortalEntries() async throws {
        let b = try luh("unilogin-loeschen")
        UniAutoLogin.sameEverywhere = false
        for p in UniAutoLogin.Portal.allCases {
            XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, portal: p, store: b.store), .saved)
        }
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, store: b.store), .saved)
        UniAutoLogin.forget(portal: .qis, store: b.store)
        XCTAssertNil(b.vault.portal(.qis).load(), "Entfernen: nur dieser Eintrag")
        XCTAssertNotNil(b.vault.portal(.studip).load())
        XCTAssertNotNil(b.vault.load())
        let problem = await b.m.deleteUniversityData(DataContainerKey(userID: b.bed.user, university: .luh))
        XCTAssertNil(problem)
        XCTAssertFalse(b.vault.hasAny(), "Daten dieser Hochschule löschen: alle Eintraege weg")
        await b.bed.tearDown()
    }
}
