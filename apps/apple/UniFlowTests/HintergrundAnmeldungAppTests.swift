import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Anmeldung im Hintergrund wie bei Studo (Entscheidung des Inhabers 20.11.2026, docs/HINTERGRUND-ANMELDUNG-2026-11-20.md):
/// abgelaufene Sitzung -> genau eine stille Anmeldung ohne Webansicht (Formular per POST ueber die URLSession) -> der Abgleich
/// geht weiter. Sicherungen: abgelehntes Passwort nie wieder, kein weiterer Hintergrund-Versuch bis zur gelungenen
/// Anmeldung im Vordergrund, ausserhalb 8–18 Uhr nichts, Abbruch durch iOS ist kein Fehlschlag, QIS nie Abmelden oder
/// Pruefungsan-/abmeldung. Alles ueber `UniStubProtocol` (kein Netz), erfundene Zugangsdaten, keine echte Webansicht.
@MainActor
final class HintergrundAnmeldungAppTests: XCTestCase {
    private final class FakeScheduler: BackgroundTaskScheduling {
        func pending() async -> [BackgroundSyncKind: Date?] { [:] }
        func submit(_ kind: BackgroundSyncKind, earliest: Date) throws {}
        func cancel(_ kind: BackgroundSyncKind) {}
    }

    private final class FakeNotifier: BackgroundNotifying {
        private(set) var posts: [BackgroundNotice.Content] = []
        func requestPermission() async -> Bool { true }
        func isAllowed() async -> Bool { true }
        func post(_ content: BackgroundNotice.Content, id: String, thread: String) async { posts.append(content) }
        func schedule(_ content: BackgroundNotice.Content, id: String, thread: String, at date: Date) async {}
        func cancel(id: String) {}
    }

    /// Abgleich ohne Netz (hier zaehlen Anmeldung und Noten)
    private final class QuietSync: BackgroundSyncable {
        var fileSource = "Stud.IP"
        var usableSources: [String] = []
        var isRunning = false
        var autoPortals: [String] = []
        func runInBackground(_ kind: BackgroundSyncKind) async -> BackgroundSyncReport { BackgroundSyncReport() }
    }

    private final class FakeTask: BackgroundTaskHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (() -> Void)?
        private var done: [Bool] = []
        var expirationHandler: (() -> Void)? {
            get { lock.withLock { handler } }
            set { lock.withLock { handler = newValue } }
        }
        func setTaskCompleted(success: Bool) { lock.withLock { done.append(success) } }
        var completions: [Bool] { lock.withLock { done } }
        func expire() { expirationHandler?() }
    }

    /// Verhalten des nachgebauten QIS (aus dem Stub-Thread gelesen)
    private final class QIS: @unchecked Sendable {
        enum Login { case accepts, rejects, logoutRedirect, expiresTask }
        private let lock = NSLock()
        private var _valid = "qis-neu"
        private var _login = Login.accepts
        var task: FakeTask?
        var valid: String { get { lock.withLock { _valid } } set { lock.withLock { _valid = newValue } } }
        var login: Login { get { lock.withLock { _login } } set { lock.withLock { _login = newValue } } }
    }

    private let clock = UniFlowClock.fixed(berlin: "2026-11-20T10:00:00")!
    private var bed: ContainerTestBed!
    private var services: [String] = []
    private var webAttempts = 0
    private let qis = QIS()
    private let host = "qis.verwaltung.uni-hannover.de"
    private var now: Date { clock.now }

    static let loginPage = """
        <html><head><meta charset="utf-8"></head><body><h1>Anmeldung</h1>
        <form name="loginform" method="post" action="/qisserver/rds?state=user&amp;type=1&amp;category=auth.login&amp;startpage=portal.vm">
        <input type="text" id="asdf" name="asdf"><input type="password" id="fdsa" name="fdsa">
        <input type="submit" class="submit" name="submit" value="Anmelden"></form>
        <a href="/qisserver/rds?state=prfAnmStudent">Prüfungsanmeldung</a></body></html>
        """

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "hintergrund-anmeldung", clock: clock)
        webAttempts = 0
        UniAutoLogin.appActiveOverride = false                   // iOS hat die App im Hintergrund gestartet
        UniDirectLogin.configurationOverride = UniStubProtocol.configuration()
        // die unsichtbare Webansicht darf hier nie gebraucht werden: mitzaehlen
        UniAutoLogin.runnerOverride = { [unowned self] _ in self.webAttempts += 1; return .failed }
    }

    override func tearDown() async throws {
        UniAutoLogin.runnerOverride = nil
        UniAutoLogin.appActiveOverride = nil
        UniDirectLogin.configurationOverride = nil
        StudIPSync.storedLoginSessionCheck = { await StudIPSync.sessionIsValid($0) }
        UniStubProtocol.reset()
        for s in services { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary) }
        await bed.tearDown()
        try await super.tearDown()
    }

    // MARK: Aufbau

    private func luh() throws -> (ContainerManager, AccountStore, ActiveContainer, QISConnection) {
        let m = bed.manager()
        let a = bed.account(.luh)
        a.markLoginDone()
        let c = try bed.open(m, a)
        services.append(m.credentialService)
        let q = try XCTUnwrap(m.qis)
        q.syncsAfterSignIn = false
        return (m, a, c, q)
    }

    private func vault(_ m: ContainerManager, _ c: ActiveContainer) -> UniCredentialStore {
        UniCredentialStore(service: m.credentialService, container: c.layout.identifier)
    }

    private func saveLogin(_ m: ContainerManager, _ c: ActiveContainer) throws {
        try vault(m, c).save(UniCredential(username: "testnutzer-erfunden", password: "Pw-Test-erfunden-123", savedAt: Date()))
    }

    /// QIS-Nachbildung: angemeldet nur mit dem gueltigen Sitzungs-Cookie; das Formular antwortet nach `qis.login`
    private func installQIS() {
        let dir = ContainerTestBed.stubDirectory
        let state = qis
        let start = QISClient.startURL.absoluteString
        UniStubProtocol.install { r in
            let s = r.url.absoluteString
            if r.method == "POST", s.contains("category=auth.login") {
                switch state.login {
                case .accepts:
                    let fresh = "qis-neu-\(UUID().uuidString.prefix(4))"
                    state.valid = fresh
                    return .redirect(302, to: start, headers: ["Set-Cookie": "JSESSIONID=\(fresh); Path=/; Secure"])
                case .rejects:
                    return .text(Self.loginPage.replacingOccurrences(of: "<form", with: "<p>Benutzername oder Passwort falsch</p><form"))
                case .logoutRedirect:
                    return .redirect(302, to: "https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=4&category=auth.logout")
                case .expiresTask:
                    state.task?.expire()                         // iOS beendet die Zeit, waehrend die Anmeldung laeuft
                    return .redirect(302, to: start, headers: ["Set-Cookie": "JSESSIONID=qis-zu-spaet; Path=/; Secure"])
                }
            }
            guard r.cookie.contains("JSESSIONID=\(state.valid)") else { return .text(Self.loginPage) }
            let reply = DebugStubTransport(directory: dir).reply(r.url, body: r.body)
            return UniStubProtocol.Reply(status: reply.status, headers: reply.headers, body: reply.body)
        }
    }

    /// QIS verbunden mit einer Sitzung, die das QIS nicht mehr kennt (abgelaufen, aber noch nicht bemerkt)
    private func connectedWithDeadSession(_ m: ContainerManager, _ c: ActiveContainer, _ q: QISConnection) async {
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(bed.cookie("JSESSIONID", "qis-alt", domain: host))
        q.signedIn(fetch: false)
        qis.valid = "qis-neu"
    }

    private func controller(_ m: ContainerManager, _ a: AccountStore) -> (BackgroundSyncController, FakeNotifier) {
        let n = FakeNotifier()
        let b = BackgroundSyncController(containers: m, account: a, settings: BackgroundSyncSettings(defaults: bed.defaults),
                                         scheduler: FakeScheduler(), notifier: n)
        b.allowed = { true }
        b.now = { self.now }
        b.timeZone = { TimeZone(identifier: "Europe/Berlin")! }
        b.weeklyTick = { _ in .off }
        b.autoDue = { _, _, _, _ in ["QIS"] }
        b.timeLeft = { 0 }
        b.graceNanos = 3_000_000_000
        let quiet = QuietSync()
        b.target = { _ in quiet }
        return (b, n)
    }

    private var posts: [UniStubProtocol.Seen] { UniStubProtocol.requests.filter { $0.method == "POST" } }

    /// Adressen, die nie aufgerufen werden duerfen (Abmelden, Pruefungsan-/abmeldung, Ruecktritt, Bescheinigungen)
    private var forbiddenRequests: [String] {
        UniStubProtocol.requests.map { $0.url.absoluteString }.filter { s in
            let l = s.lowercased()
            return ["logout", "type=4", "prfanm", "abmeld", "ruecktritt", "verpublish"].contains { l.contains($0) }
        }
    }

    private func ledger(_ c: ActiveContainer) -> BackgroundReloginLedger { BackgroundReloginLedger(defaults: c.defaults) }

    // MARK: QIS

    func testExpiredSessionOneBackgroundLoginThenGradesArrive() async throws {
        let (m, a, c, q) = try luh()
        installQIS()
        try saveLogin(m, c)
        await connectedWithDeadSession(m, c, q)
        let (b, _) = controller(m, a)
        await b.perform(.processing)
        XCTAssertEqual(posts.count, 1, "genau eine Anmeldung")
        let body = posts.first?.bodyText ?? ""
        XCTAssertTrue(body.contains("asdf=testnutzer-erfunden") && body.contains("fdsa=Pw-Test-erfunden-123"))
        XCTAssertEqual(posts.first?.url.host, host, "Passwort nur an das QIS")
        XCTAssertEqual(webAttempts, 0, "ohne unsichtbare Webansicht")
        XCTAssertEqual(UniDirectLogin.last, .done(passwordSent: true))
        XCTAssertEqual(b.lastRelogin?.succeeded, ["QIS"])
        XCTAssertEqual(q.lastCount, 3, "der Abgleich ging nach der Anmeldung weiter: Notenspiegel da")
        XCTAssertEqual(q.state, .ok(clock.now))
        XCTAssertEqual(forbiddenRequests, [], "nie Abmelden, nie Pruefungsanmeldung")
        XCTAssertFalse(ledger(c).blocked("QIS"))
        // die neue Sitzung steht im Datenspeicher der Webansichten (fuer jeden weiteren Abgleich)
        let cookies = await m.websiteDataStore(for: c).httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == "JSESSIONID" && $0.value == qis.valid })
    }

    func testKnownExpiredSessionLogsInBeforeTheRunAndOnlyOncePerRun() async throws {
        let (m, a, c, q) = try luh()
        installQIS()
        try saveLogin(m, c)
        await connectedWithDeadSession(m, c, q)
        _ = await q.run(force: true, renewsSession: false)
        XCTAssertEqual(q.state, .needsLogin)
        qis.login = .rejects
        // Passwort "abgelehnt" ohne Fehlertext waere `.failed`; hier mit Fehlertext. Zwei Gelegenheiten im selben Lauf
        // (vor dem Abgleich und nach dem Notenabruf): trotzdem nur EIN POST
        let (b, _) = controller(m, a)
        await b.perform(.processing)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(b.lastRelogin?.tried, ["QIS"])
    }

    func testRejectedPasswordNoRetryUntilForegroundSuccess() async throws {
        let (m, a, c, q) = try luh()
        installQIS()
        try saveLogin(m, c)
        await connectedWithDeadSession(m, c, q)
        _ = await q.run(force: true, renewsSession: false)
        qis.login = .rejects
        let (b, n) = controller(m, a)
        await b.perform(.processing)
        XCTAssertEqual(posts.count, 1)
        XCTAssertNil(vault(m, c).load(), "abgelehntes Passwort sofort vergessen")
        XCTAssertTrue(UniAutoLogin.wasRejected(q.websiteDataStore))
        XCTAssertTrue(ledger(c).blocked("QIS"))
        XCTAssertEqual(q.state, .needsLogin)
        _ = n
        // der Mensch speichert in den Einstellungen ein neues Passwort, oeffnet die App aber nicht: der Hintergrund
        // versucht es trotzdem nicht (Stunden spaeter, alle Bedingungen sonst erfuellt)
        XCTAssertEqual(UniAutoLogin.saveTyped(username: "testnutzer-erfunden", password: "Pw-Neu-erfunden-456", store: q.websiteDataStore), .saved)
        qis.login = .accepts
        b.now = { self.now.addingTimeInterval(3 * 3600) }
        await b.perform(.processing)
        XCTAssertEqual(posts.count, 1, "kein weiterer Versuch im Hintergrund bis zur Anmeldung im Vordergrund")
        // Vordergrund: die App ist offen, die Anmeldung gelingt (hier: angemeldete QIS-Seite erkannt)
        UniAutoLogin.appActiveOverride = true
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(bed.cookie("JSESSIONID", "qis-vorne", domain: host))
        qis.valid = "qis-vorne"
        q.signedIn(fetch: false)
        XCTAssertFalse(ledger(c).blocked("QIS"), "Vordergrund-Erfolg hebt die Sperre auf")
        // wieder im Hintergrund, die Sitzung laeuft erneut ab: jetzt darf es wieder einmal versuchen
        UniAutoLogin.appActiveOverride = false
        qis.valid = "qis-ganz-neu"
        _ = await q.run(force: true, renewsSession: false)
        XCTAssertEqual(q.state, .needsLogin)
        b.now = { self.now.addingTimeInterval(4 * 3600) }
        await b.perform(.processing)
        XCTAssertEqual(posts.count, 2)
        XCTAssertNotEqual(q.state, .needsLogin)
        XCTAssertEqual(webAttempts, 0)
    }

    func testFailureWithoutRejectionAlsoBlocksUntilForeground() async throws {
        let (m, a, c, q) = try luh()
        installQIS()
        try saveLogin(m, c)
        await connectedWithDeadSession(m, c, q)
        _ = await q.run(force: true, renewsSession: false)
        qis.login = .logoutRedirect
        let (b, _) = controller(m, a)
        await b.perform(.processing)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(UniDirectLogin.last, .blocked)
        XCTAssertEqual(forbiddenRequests, [], "die Weiterleitung zum Abmelden wird nie aufgerufen")
        XCTAssertNotNil(vault(m, c).load(), "ohne Fehlertext nichts vergessen")
        XCTAssertTrue(ledger(c).blocked("QIS"))
        b.now = { self.now.addingTimeInterval(30 * 3600) }
        await b.perform(.processing)
        XCTAssertEqual(posts.count, 1, "auch einen Tag spaeter nicht (frueher: nach 24 Stunden wieder)")
    }

    func testNoAttemptOutsideTheWindowOrWithoutRememberedPassword() async throws {
        let (m, a, c, q) = try luh()
        installQIS()
        await connectedWithDeadSession(m, c, q)
        _ = await q.run(force: true, renewsSession: false)
        let before = UniStubProtocol.requests.count
        let (b, _) = controller(m, a)
        // ohne gespeichertes Passwort: nichts
        await b.perform(.processing)
        XCTAssertEqual(UniStubProtocol.requests.count, before)
        try saveLogin(m, c)
        // ausserhalb von 8 bis 18 Uhr (echte Regel): gar keine Anfrage an die Hochschule
        b.autoDue = { c2, t, tz, kind in m.autoSyncDue(now: t, timeZone: tz, continueAtOnce: kind == .processing) }
        for hour in [19.0, 23.5, 6.0] {
            b.now = { self.now.addingTimeInterval(hour * 3600 - 10 * 3600 + (hour < 10 ? 24 * 3600 : 0)) }
            await b.perform(.processing)
            XCTAssertEqual(UniStubProtocol.requests.count, before, "um \(hour) Uhr nichts")
            XCTAssertEqual(b.lastRelogin?.tried, [])
        }
        // "Passwort merken" aus: nichts (und das Passwort ist weg)
        b.autoDue = { _, _, _, _ in ["QIS"] }
        b.now = { self.now }
        UniAutoLogin.setEnabled(false, store: q.websiteDataStore)
        await b.perform(.processing)
        XCTAssertEqual(posts.count, 0)
        // Schalter "Im Hintergrund neu anmelden" aus: nichts
        UniAutoLogin.setEnabled(true, store: q.websiteDataStore)
        try saveLogin(m, c)
        BackgroundNewsSettings(defaults: bed.defaults).relogin = false
        await b.perform(.processing)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(webAttempts, 0)
    }

    func testExpirationDuringLoginAbortsWithoutRejectionOrBlock() async throws {
        let (m, a, c, q) = try luh()
        installQIS()
        try saveLogin(m, c)
        await connectedWithDeadSession(m, c, q)
        _ = await q.run(force: true, renewsSession: false)
        let (b, _) = controller(m, a)
        let task = FakeTask()
        qis.task = task
        qis.login = .expiresTask
        b.handle(task, kind: .processing)
        try await bed.waitUntil("Abschluss der Aufgabe", timeout: 20) { !task.completions.isEmpty }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(task.completions, [false], "abgebrochen")
        XCTAssertEqual(posts.count, 1)
        if case .cancelled = UniDirectLogin.last {} else { XCTFail("Anmeldung abgebrochen erwartet, war \(String(describing: UniDirectLogin.last))") }
        XCTAssertEqual(b.lastRelogin?.aborted, ["QIS"])
        XCTAssertNotNil(vault(m, c).load(), "nichts vergessen")
        XCTAssertFalse(UniAutoLogin.wasRejected(q.websiteDataStore), "nie als abgelehnt")
        XCTAssertFalse(ledger(c).blocked("QIS"), "kein Fehlschlag")
        XCTAssertEqual(c.defaults.integer(forKey: BackgroundReloginLedger.prefix + "QIS.aborts"), 1)
        XCTAssertEqual(q.state, .needsLogin)
        XCTAssertEqual(webAttempts, 0, "nach dem Abbruch kein zweiter Weg")
        // im selben halbstuendigen Takt nicht noch einmal; im naechsten Lauf (31 Minuten spaeter) schon
        qis.task = nil
        qis.login = .accepts
        b.now = { self.now.addingTimeInterval(10 * 60) }
        await b.perform(.processing)
        XCTAssertEqual(posts.count, 1)
        b.now = { self.now.addingTimeInterval(31 * 60) }
        await b.perform(.processing)
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(q.lastCount, 3)
        XCTAssertEqual(c.defaults.integer(forKey: BackgroundReloginLedger.prefix + "QIS.aborts"), 0)
    }

    func testRepeatedAbortsCountAsAFailureAfterThree() {
        let d = UserDefaults(suiteName: "uniflow.tests.abbruch.\(UUID().uuidString)")!
        let l = BackgroundReloginLedger(defaults: d)
        for i in 0..<2 {
            l.recordAborted("QIS", now: now.addingTimeInterval(Double(i) * 3600))
            XCTAssertFalse(l.blocked("QIS"))
        }
        l.recordAborted("QIS", now: now.addingTimeInterval(3 * 3600))
        XCTAssertTrue(l.blocked("QIS"), "ein abgebrochener Versuch kann das Passwort schon gesendet haben: nicht endlos")
        XCTAssertFalse(l.mayTry("QIS", now: now.addingTimeInterval(100 * 3600)))
        UniAutoLogin.appActiveOverride = false
        BackgroundReloginLedger.foregroundSuccess("QIS", defaults: d)
        XCTAssertTrue(l.blocked("QIS"), "aus dem Hintergrund hebt nichts die Sperre auf")
        UniAutoLogin.appActiveOverride = true
        BackgroundReloginLedger.foregroundSuccess("QIS", defaults: d)
        XCTAssertTrue(l.mayTry("QIS", now: now))
    }

    // MARK: Stud.IP (WebSSO der LUH)

    private static let idp = "https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO"

    /// WebSSO-Nachbildung: mit gueltigem IdP-Cookie still (Pruefseite und SAML-Antwort), sonst das Formular
    private func installSSO() throws {
        let form = try String(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/autologin/luh-websso.html"), encoding: .utf8)
        let saml = """
            <html><body><form action="https://studip.uni-hannover.de/Shibboleth.sso/SAML2/POST" method="post">
            <input type="hidden" name="RelayState" value="ss:mem:1"><input type="hidden" name="SAMLResponse" value="PHNhbWw+"/>
            <noscript><input type="submit" value="Continue"/></noscript></form></body></html>
            """
        let idp = Self.idp
        UniStubProtocol.install { r in
            let s = r.url.absoluteString
            if s.hasPrefix("https://studip.uni-hannover.de/Shibboleth.sso/Login") { return .redirect(302, to: idp + "?SAMLRequest=abc") }
            if s.hasPrefix(idp), r.method == "GET" { return .text(r.cookie.contains("shib_idp_session=gueltig") ? saml : form) }
            if s.hasPrefix(idp), r.method == "POST" {
                return .redirect(302, to: idp + "?SAMLRequest=abc", headers: ["Set-Cookie": "shib_idp_session=gueltig; Path=/idp; Secure"])
            }
            if s.hasSuffix("/Shibboleth.sso/SAML2/POST") {
                return .redirect(302, to: "https://studip.uni-hannover.de/dispatch.php/login?sso=shib",
                                 headers: ["Set-Cookie": "_shibsession_1=x; Path=/; Secure"])
            }
            if s.contains("dispatch.php/login") {
                return .redirect(302, to: "https://studip.uni-hannover.de/dispatch.php/start", headers: ["Set-Cookie": "Seminar_Session=neu; Path=/; Secure"])
            }
            return .text("<html><body>Stud.IP Start</body></html>")
        }
    }

    private func studipExpired(_ m: ContainerManager, _ c: ActiveContainer) throws {
        try c.cookies.save([bed.cookie("Seminar_Session", "alt", domain: "studip.uni-hannover.de")])
        c.defaults.set(true, forKey: StudIPSync.Keys.sessionExpired)
        StudIPSync.storedLoginSessionCheck = { $0.contains { $0.name == "Seminar_Session" && $0.value == "neu" } }
    }

    func testStudIPRenewsSilentlyThroughTheStillValidUniLoginWithoutPassword() async throws {
        let (m, _, c, _) = try luh()
        try installSSO()
        try saveLogin(m, c)
        try studipExpired(m, c)
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(bed.cookie("shib_idp_session", "gueltig", domain: "sso.idm.uni-hannover.de"))
        let ok = await m.studip.renewInBackground()
        XCTAssertTrue(ok)
        XCTAssertFalse(posts.contains { $0.bodyText.contains("password") }, "kein Passwort noetig")
        XCTAssertEqual(posts.count, 1, "nur die SAML-Antwort")
        XCTAssertFalse(m.studip.sessionKnownExpired)
        XCTAssertEqual(c.cookies.load().first { $0.name == "Seminar_Session" }?.value, "neu")
        XCTAssertEqual(webAttempts, 0)
    }

    func testStudIPSendsThePasswordOnceWhenTheIdPAsks() async throws {
        let (m, _, c, _) = try luh()
        try installSSO()
        try saveLogin(m, c)
        try studipExpired(m, c)
        let ok = await m.studip.renewInBackground()
        XCTAssertTrue(ok)
        let withPassword = posts.filter { $0.bodyText.contains("password=") }
        XCTAssertEqual(withPassword.count, 1)
        XCTAssertEqual(withPassword.first?.url.host, "sso.idm.uni-hannover.de", "Passwort nur an das WebSSO")
        XCTAssertTrue(withPassword.first?.bodyText.contains("loginname=testnutzer-erfunden") ?? false)
        XCTAssertFalse(withPassword.first?.bodyText.contains("donotcache") ?? true)
        XCTAssertFalse(m.studip.sessionKnownExpired)
        XCTAssertEqual(webAttempts, 0)
    }
}
