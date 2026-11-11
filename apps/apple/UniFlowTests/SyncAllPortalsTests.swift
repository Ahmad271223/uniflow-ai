import os
import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Uni-Zugang einmal speichern (Entscheidung des Inhabers 10.11.2026): ein Tipp auf "Sync" gleicht an der LUH ALLE
/// Portale ab - Uni-Mail (SOGo) zuerst, Stud.IP, QIS (Noten, angemeldete Pruefungen, Liste der Bescheinigungen, nur
/// lesend) -, nicht nur Stud.IP; beim Oeffnen ebenso, wenn faellig. Mit gespeichertem Uni-Zugang wird vorher verbunden
/// (`connectWithStoredLogin`: hier nachgebildet, beim Knopf als Handlung des Menschen, beim Oeffnen still). Portale ohne
/// Verbindung werden uebersprungen und genannt; ein Fehler eines Portals haelt die anderen nicht auf; nie zwei Laeufe.
/// QIS aus dem Debug-Stub, SOGo aus fixtures/sogo/raw ueber `UniStubProtocol`; kein Netz, keine echte Anmeldung,
/// Zugangsdaten erkennbar erfunden.
@MainActor
final class SyncAllPortalsTests: XCTestCase {
    private var bed: ContainerTestBed!
    private let qisHost = "qis.verwaltung.uni-hannover.de"
    private let mailHost = "kalender.uni-hannover.de"
    private let mailUser = "testnutzer-erfunden@stud.uni-hannover.de"
    /// QIS bzw. SOGo nehmen die Sitzung an (sonst die Anmeldeseite, wie abgelaufen)
    private let qisSession = OSAllocatedUnfairLock(initialState: true)
    private let mailSession = OSAllocatedUnfairLock(initialState: true)
    private var services: [String] = []
    private var savedConnect: (@MainActor (ContainerManager, Bool) async -> StoredLoginReport)!
    private var savedAllowed: (() -> Bool)!

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "syncall", clock: .fixed(berlin: "2026-11-10T10:00:00")!)
        savedConnect = OpenSync.storedLoginConnect
        savedAllowed = OpenSync.allowed
        OpenSync.last = [:]
        OpenSync.running = []
    }

    override func tearDown() async throws {
        OpenSync.storedLoginConnect = savedConnect
        OpenSync.allowed = savedAllowed
        OpenSync.last = [:]
        OpenSync.running = []
        UniAutoLogin.runnerOverride = nil
        UniAutoLogin.appActiveOverride = nil
        for s in services { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary) }
        services = []
        await bed.tearDown()
        bed = nil
        try await super.tearDown()
    }

    // MARK: Nachbildungen

    private func manager() -> ContainerManager {
        let stub: @MainActor (WKWebsiteDataStore) async -> UniTransport = { store in
            await URLSessionUniTransport.make(dataStore: store, allowedDomains: QISConnection.qisDomains + SOGoSite.all.map(\.host),
                                              configuration: UniStubProtocol.configuration())
        }
        return ContainerManager(base: bed.containers,
                                legacy: LegacyDataMigration.Sources(support: bed.appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                                    studip: bed.appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                                keychain: bed.keychain, cookieService: bed.cookieService, defaults: bed.defaults, clock: bed.clock,
                                publishesCurrent: false, qisTransport: stub, uniMailTransport: stub)
    }

    private func fx(_ name: String) throws -> Data {
        try Data(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/sogo/raw/\(name)"))
    }

    /// QIS (Debug-Stub, nur mit dem Sitzungs-Cookie der Webansicht) und SOGo (Posteingang) nachgebaut
    private func install() throws {
        let dir = ContainerTestBed.stubDirectory
        let inbox = try fx("folder-inbox.json"), unseen = try fx("unseen.json"), mailLogin = try fx("login-page.html")
        let qisLogin = #"<html><body><form action="x" method="post"><input type="text" name="asdf"><input type="password" name="fdsa"></form></body></html>"#
        let qisHost = qisHost, qisSession = qisSession, mailSession = mailSession
        UniStubProtocol.install { r in
            if r.url.host == qisHost {
                guard qisSession.withLock({ $0 }), r.cookie.contains("JSESSIONID=qis-sitzung-test") else { return .text(qisLogin) }
                let reply = DebugStubTransport(directory: dir).reply(r.url, body: r.body)
                return UniStubProtocol.Reply(status: reply.status, headers: reply.headers, body: reply.body)
            }
            guard mailSession.withLock({ $0 }) else {
                return UniStubProtocol.Reply(status: 200, headers: ["Content-Type": "text/html"], body: mailLogin)
            }
            let json = ["Content-Type": "application/json"]
            if r.url.path.hasSuffix("/Mail/0/folderINBOX/view") { return UniStubProtocol.Reply(status: 200, headers: json, body: inbox) }
            if r.url.path.hasSuffix("/Mail/unseenCount") { return UniStubProtocol.Reply(status: 200, headers: json, body: unseen) }
            return UniStubProtocol.Reply(status: 404, headers: json, body: Data("{}".utf8))
        }
    }

    private func signInQIS(_ m: ContainerManager, _ c: ActiveContainer, _ q: QISConnection) async {
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(bed.cookie("JSESSIONID", "qis-sitzung-test", domain: qisHost))
        q.signedIn()
    }

    private func signInMail(_ mail: UniMailConnection) async {
        let store = mail.websiteDataStore.httpCookieStore
        await store.setCookie(bed.cookie("0xHIGHFLYxSOGo", "erfundene-sitzung", domain: mailHost, path: "/SOGo"))
        await store.setCookie(bed.cookie("XSRF-TOKEN", "tok%2B1", domain: mailHost, path: "/SOGo"))
        mail.signedIn(user: mailUser)
    }

    /// LUH-Container; QIS und Uni-Mail wahlweise schon verbunden (Stud.IP ohne Sitzung: unter XCTest gleicht es nie ab)
    private func luh(qis qisOn: Bool = true, mail mailOn: Bool = true) async throws
        -> (ContainerManager, ActiveContainer, QISConnection, UniMailConnection) {
        let m = manager()
        let c = try bed.open(m, bed.account(.luh))
        let q = try XCTUnwrap(m.qis)
        q.syncsAfterSignIn = false
        let mail = try XCTUnwrap(m.uniMail)
        mail.refreshesAfterSignIn = false
        if qisOn { await signInQIS(m, c, q) }
        if mailOn { await signInMail(mail) }
        try await Task.sleep(nanoseconds: 100_000_000)          // Start-Aufgaben des Containers vorbei
        return (m, c, q, mail)
    }

    /// Uni-Zugang wie aus den Einstellungen (erfunden), im Test-Schluesselbund dieses Containers
    private func saveLogin(_ m: ContainerManager) {
        services.append(m.credentialService)
        XCTAssertNotEqual(m.credentialService, UniCredentialStore.service, "Tests nie im echten Dienst")
        XCTAssertEqual(UniAutoLogin.saveTyped(username: "testnutzer-erfunden", password: "Pw-Test-erfunden-123", store: m.studip.websiteDataStore), .saved)
        XCTAssertTrue(m.hasStoredLogin)
    }

    private func requests(_ host: String) -> [UniStubProtocol.Seen] { UniStubProtocol.requests.filter { $0.url.host == host } }
    private var inboxReads: Int { UniStubProtocol.requests.filter { $0.url.path.hasSuffix("/Mail/0/folderINBOX/view") }.count }

    /// nur lesend: nie ein Dokument erzeugt, nie zu einer Pruefung an- oder abgemeldet, nie eine Mail gesendet
    private func assertOnlyReading(file: StaticString = #filePath, line: UInt = #line) {
        let urls = UniStubProtocol.requests.map(\.url.absoluteString)
        XCTAssertFalse(urls.contains { $0.contains("verpublish") || $0.contains("prfAnm") || $0.contains("type=4") || $0.contains("hisreports") },
                       "\(urls)", file: file, line: line)
        XCTAssertFalse(urls.contains { $0.hasSuffix("/send") }, file: file, line: line)
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.bodyText.contains("Pw-Test-erfunden") }, "kein Passwort im Abgleich", file: file, line: line)
    }

    // MARK: Knopf "Sync"

    func testSyncButtonReachesQISWithCertificatesAndUniMailNotOnlyStudIP() async throws {
        let (m, c, q, mail) = try await luh()
        try install()
        var result: UniversitySyncReport?
        let start = m.startUniversitySync { result = $0 }
        XCTAssertEqual(start, .started("QIS und Uni-Mail werden abgeglichen …"), "Stud.IP ohne Sitzung wird nicht angekuendigt")
        // kein doppelter Lauf: zweiter Tipp und Oeffnen der App waehrend des Abgleichs
        XCTAssertEqual(m.startUniversitySync(), .alreadyRunning)
        OpenSync.allowed = { true }
        XCTAssertFalse(m.syncAllOnOpen(now: bed.clock.now))
        try await bed.waitUntil("Ergebnis des Abgleichs", timeout: 30) { result != nil }
        let r = try XCTUnwrap(result)

        XCTAssertEqual(r.synced, ["QIS", "Uni-Mail"])
        XCTAssertEqual(r.notes, ["Stud.IP: nicht verbunden"])
        XCTAssertFalse(r.rejected)
        XCTAssertEqual(r.info, ["Bescheinigungen: 1 verfügbar"])
        XCTAssertEqual(r.text, "Abgeglichen: QIS und Uni-Mail. Bescheinigungen: 1 verfügbar. Stud.IP: nicht verbunden.")
        XCTAssertTrue(OpenSync.running.isEmpty)
        // Uni-Mail zuerst, genau einmal
        XCTAssertEqual(inboxReads, 1)
        XCTAssertEqual(UniStubProtocol.requests.first?.url.path, "/SOGo/so/\(mailUser)/Mail/0/folderINBOX/view")
        if case .ok = mail.state {} else { XCTFail("Uni-Mail: \(mail.state)") }
        // QIS: Noten (Knopf: auch vor Ablauf der 20 Stunden) und die Liste der Bescheinigungen
        XCTAssertEqual(q.state, .ok(bed.clock.now))
        XCTAssertEqual(q.lastCount, 3)
        XCTAssertTrue(requests(qisHost).allSatisfy { $0.cookie.contains("JSESSIONID=qis-sitzung-test") })
        let list = try await c.api.value("/api/certificates")
        XCTAssertEqual(list["status"]?.string, "ok", "Liste der Bescheinigungen gelesen")
        XCTAssertEqual(list["offers"]?.array?.count, 1)
        assertOnlyReading()

        // danach wieder moeglich
        var again: UniversitySyncReport?
        XCTAssertEqual(m.startUniversitySync { again = $0 }, .started("QIS und Uni-Mail werden abgeglichen …"))
        try await bed.waitUntil("zweiter Abgleich", timeout: 30) { again != nil }
        XCTAssertEqual(inboxReads, 2)
        XCTAssertEqual(again?.synced, ["QIS", "Uni-Mail"])
    }

    func testPortalNeedingLoginIsSkippedAndNamedWhileTheOthersContinue() async throws {
        let (m, _, q, mail) = try await luh()
        try install()
        mailSession.withLock { $0 = false }                     // SOGo zeigt die Anmeldeseite (abgelaufen)
        var result: UniversitySyncReport?
        XCTAssertEqual(m.startUniversitySync { result = $0 }, .started("QIS und Uni-Mail werden abgeglichen …"))
        try await bed.waitUntil("Ergebnis", timeout: 30) { result != nil }
        let r = try XCTUnwrap(result)
        XCTAssertEqual(mail.state, .needsLogin)
        XCTAssertEqual(r.synced, ["QIS"], "der Fehler von Uni-Mail haelt QIS nicht auf")
        XCTAssertEqual(r.notes, ["Stud.IP: nicht verbunden", "Uni-Mail: Anmeldung nötig"])
        XCTAssertEqual(r.text, "Abgeglichen: QIS. Bescheinigungen: 1 verfügbar. Stud.IP: nicht verbunden. Uni-Mail: Anmeldung nötig.")
        XCTAssertEqual(q.lastCount, 3)

        // QIS jetzt auch abgelaufen: nichts mehr zu tun, kein Aufruf, Weg zum Uni-Zugang
        q.certificatesExpired()
        XCTAssertEqual(q.state, .needsLogin)
        let before = UniStubProtocol.requests.count
        let none = m.startUniversitySync()
        XCTAssertEqual(none, .notConnected("Zuerst den Uni-Zugang in den Einstellungen speichern"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(UniStubProtocol.requests.count, before, "abgelaufene Portale nicht angefragt")
        XCTAssertTrue(OpenSync.running.isEmpty)
        assertOnlyReading()
    }

    func testStoredLoginConnectsFirstOnTapAndQuietlyOnOpen() async throws {
        let (m, c, q, _) = try await luh(qis: false, mail: false)
        try install()
        saveLogin(m)
        var calls: [(userAction: Bool, requestsBefore: Int)] = []
        OpenSync.storedLoginConnect = { manager, userAction in
            calls.append((userAction, UniStubProtocol.requests.count))
            // nachgebildet: QIS verbunden, Stud.IP und Uni-Mail brauchen noch eine Anmeldung von Hand
            await self.signInQIS(manager, c, q)
            return StoredLoginReport(connected: ["QIS"], needsLogin: ["Stud.IP", "Uni-Mail"])
        }
        var result: UniversitySyncReport?
        let start = m.startUniversitySync { result = $0 }
        XCTAssertEqual(start, .started("Stud.IP, QIS und Uni-Mail werden abgeglichen …"), "mit gespeichertem Zugang alle Portale")
        try await bed.waitUntil("Ergebnis", timeout: 30) { result != nil }
        let r = try XCTUnwrap(result)
        XCTAssertEqual(calls.map(\.userAction), [true], "Knopf: Handlung des Menschen")
        XCTAssertEqual(calls.first?.requestsBefore, 0, "erst verbinden, dann abgleichen")
        XCTAssertEqual(r.synced, ["QIS"])
        XCTAssertEqual(r.notes, ["Stud.IP: nicht verbunden", "Uni-Mail: nicht verbunden"])
        XCTAssertEqual(q.lastCount, 3)
        XCTAssertEqual(inboxReads, 0, "Uni-Mail nicht verbunden: nicht angefragt")

        // Oeffnen der App: ebenso, aber still (keine Handlung des Menschen)
        OpenSync.allowed = { true }
        let t0 = bed.clock.now
        XCTAssertTrue(m.syncAllOnOpen(now: t0))
        try await bed.waitUntil("Abgleich beim Oeffnen", timeout: 30) { calls.count == 2 && OpenSync.running.isEmpty }
        XCTAssertEqual(calls.map(\.userAction), [true, false])
        XCTAssertFalse(m.syncAllOnOpen(now: t0.addingTimeInterval(5 * 60)), "nicht faellig")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(calls.count, 2)
        assertOnlyReading()
    }

    func testRejectedPasswordIsNamedAndPortalsWithASessionStillSync() async throws {
        let (m, _, q, _) = try await luh(qis: true, mail: false)
        try install()
        saveLogin(m)
        OpenSync.storedLoginConnect = { _, _ in StoredLoginReport(needsLogin: ["Stud.IP", "Uni-Mail"], rejected: true) }
        var result: UniversitySyncReport?
        XCTAssertEqual(m.startUniversitySync { result = $0 }, .started("Stud.IP, QIS und Uni-Mail werden abgeglichen …"))
        try await bed.waitUntil("Ergebnis", timeout: 30) { result != nil }
        let r = try XCTUnwrap(result)
        XCTAssertTrue(r.rejected)
        XCTAssertEqual(r.synced, ["QIS"], "QIS hat noch eine gueltige Sitzung")
        XCTAssertEqual(r.text, "Die Hochschule hat das gespeicherte Passwort abgelehnt. Abgeglichen: QIS. Bescheinigungen: 1 verfügbar. Stud.IP: nicht verbunden. Uni-Mail: nicht verbunden.")
        XCTAssertEqual(q.lastCount, 3)
        assertOnlyReading()
    }

    /// Befund 11.11.2026: QIS zeigte "verbunden", die Sitzung war aber abgelaufen. Der Sync endete mit "QIS: Anmeldung
    /// nötig", die stille Anmeldung lief losgeloest weiter, Noten kamen erst spaeter, Bescheinigungen nie. Jetzt wartet
    /// der Sync die Anmeldung ab (genau eine), liest Noten im selben Lauf neu und danach die Liste der Bescheinigungen.
    func testExpiredQISSessionIsRenewedWithinTheSyncAndCertificatesAreListed() async throws {
        let (m, c, q, _) = try await luh(qis: true, mail: false)
        try install()
        saveLogin(m)
        qisSession.withLock { $0 = false }                      // QIS-Sitzung abgelaufen, die App weiss es noch nicht
        XCTAssertNotEqual(q.state, .needsLogin)
        OpenSync.storedLoginConnect = { _, _ in StoredLoginReport(connected: ["QIS"], needsLogin: ["Stud.IP", "Uni-Mail"]) }
        UniAutoLogin.appActiveOverride = true
        var logins: [UniAutoLoginRequest] = []
        let session = qisSession
        UniAutoLogin.runnerOverride = { r in logins.append(r); session.withLock { $0 = true }; return .success }
        var result: UniversitySyncReport?
        XCTAssertEqual(m.startUniversitySync { result = $0 }, .started("Stud.IP, QIS und Uni-Mail werden abgeglichen …"))
        try await bed.waitUntil("Ergebnis", timeout: 30) { result != nil }
        let r = try XCTUnwrap(result)
        XCTAssertEqual(logins.count, 1, "genau eine stille Anmeldung, kein zweiter Lauf daneben")
        XCTAssertEqual(logins.first?.portal, "qis")
        XCTAssertEqual(r.synced, ["QIS"], "\(r.text)")
        XCTAssertEqual(q.state, .ok(bed.clock.now))
        XCTAssertEqual(q.lastCount, 3, "Noten im selben Sync")
        let list = try await c.api.value("/api/certificates")
        XCTAssertEqual(list["status"]?.string, "ok", "Liste der Bescheinigungen im selben Sync")
        XCTAssertEqual(r.info, ["Bescheinigungen: 1 verfügbar"])
        XCTAssertEqual(UniAutoLogin.state(portal: "qis", store: q.websiteDataStore)?.awaitingRetry, false,
                       "Abruf gelungen: die Zustandsmaschine weiss es")
        // kein losgeloester Abruf bzw. keine zweite Anmeldung danach
        let before = UniStubProtocol.requests.count
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(UniStubProtocol.requests.count, before)
        XCTAssertEqual(logins.count, 1)
        assertOnlyReading()
    }

    /// Beim Oeffnen (still) liest der Sync die Liste der Bescheinigungen IMMER (11.11.2026), nicht erst nach 7 Tagen
    func testOpenSyncAlwaysReadsTheCertificateList() async throws {
        let (m, c, q, _) = try await luh(qis: true, mail: false)
        try install()
        // Liste eben erst gelesen (frischer Stand), danach oeffnet die App
        let first = await CertificateCenter(portal: .qis(q)).refresh()
        XCTAssertEqual(first?.ok, true)
        let menuReads = { UniStubProtocol.requests.filter { $0.url.absoluteString.contains("moduleParameter=studentReportsMenu") }.count }
        XCTAssertEqual(menuReads(), 1)
        OpenSync.allowed = { true }
        XCTAssertTrue(m.syncAllOnOpen(now: bed.clock.now))
        try await bed.waitUntil("Abgleich beim Oeffnen", timeout: 30) { OpenSync.running.isEmpty }
        XCTAssertEqual(menuReads(), 2, "die Liste im Sync beim Oeffnen neu gelesen")
        let list = try await c.api.value("/api/certificates")
        XCTAssertEqual(list["status"]?.string, "ok")
        assertOnlyReading()
    }

    func testNothingConnectedAndNoStoredLoginAsksForTheUniAccess() async throws {
        let (m, _, _, _) = try await luh(qis: false, mail: false)
        try install()
        var called = false
        OpenSync.storedLoginConnect = { _, _ in called = true; return StoredLoginReport() }
        XCTAssertFalse(m.hasStoredLogin)
        XCTAssertEqual(m.startUniversitySync(), .notConnected("Zuerst den Uni-Zugang in den Einstellungen speichern"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(UniStubProtocol.requests.isEmpty)
        XCTAssertFalse(called, "ohne gespeicherten Zugang kein Verbinden")
        XCTAssertTrue(OpenSync.running.isEmpty)
    }

    // MARK: Texte

    func testStartedAndResultTexts() {
        XCTAssertEqual(UniversitySyncStart.startedText(["Stud.IP"]), "Stud.IP wird abgeglichen …")
        XCTAssertEqual(UniversitySyncStart.startedText(["Moodle", "Campusmanagement"]), "Moodle und Campusmanagement werden abgeglichen …")
        XCTAssertEqual(UniversitySyncStart.startedText(["Stud.IP", "QIS", "Uni-Mail"]), "Stud.IP, QIS und Uni-Mail werden abgeglichen …")
        XCTAssertEqual(UniversitySyncStart.connectHint(.luh), "Zuerst den Uni-Zugang in den Einstellungen speichern")
        XCTAssertEqual(UniversitySyncStart.connectHint(.hsh), "Zuerst Moodle oder Campusmanagement verbinden")
        XCTAssertEqual(UniversitySyncStart.alreadyRunning.text, "Der Abgleich läuft bereits …")
        XCTAssertEqual(UniversitySyncReport(synced: ["Stud.IP", "QIS", "Uni-Mail"]).text, "Abgeglichen: Stud.IP, QIS und Uni-Mail.")
        XCTAssertEqual(UniversitySyncReport(notes: ["QIS: Anmeldung nötig"]).text, "Nichts abgeglichen. QIS: Anmeldung nötig.")
        XCTAssertEqual(UniversitySyncReport(synced: ["QIS"], notes: ["Uni-Mail: Fehler"], info: ["Bescheinigungen: 2 verfügbar"]).text,
                       "Abgeglichen: QIS. Bescheinigungen: 2 verfügbar. Uni-Mail: Fehler.")
        XCTAssertEqual(ContainerManager.certificatesNote(2), "Bescheinigungen: 2 verfügbar")
        XCTAssertEqual(ContainerManager.certificatesNote(0), "Bescheinigungen: keine verfügbar")
        XCTAssertEqual(ContainerManager.studIPNote(.needsLogin), "Anmeldung nötig")
        XCTAssertEqual(ContainerManager.studIPNote(.failed("x")), "Fehler")
        XCTAssertNil(ContainerManager.studIPNote(.idle))
    }
}
