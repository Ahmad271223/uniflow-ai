import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Stille Neuanmeldung im Hintergrund fuer alle Portale (Auftrag des Inhabers 17.11.2026, docs/ABGLEICH-8-BIS-18-
/// 2026-11-17.md): Learnweb und LSF (Uni Hildesheim, CAS) sowie Moodle und Campusmanagement (HsH) wie bisher Stud.IP,
/// QIS und Uni-Mail. Je Sicherung ein Test auf dem Hintergrund-Weg. Keine echte Webansicht (`UniAutoLogin.runnerOverride`,
/// `HildesheimConnection.backgroundServiceLogin`), kein Netz, erfundene Zugangsdaten.
@MainActor
final class BackgroundReloginAppTests: XCTestCase {
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

    /// Abgleich ohne Netz (der Hintergrundlauf soll hier nur die Neuanmeldung zeigen)
    private final class QuietSync: BackgroundSyncable {
        var fileSource = "Learnweb"
        var usableSources: [String] = []
        var isRunning = false
        var autoPortals: [String] = []
        private(set) var runs = 0
        func runInBackground(_ kind: BackgroundSyncKind) async -> BackgroundSyncReport { runs += 1; return BackgroundSyncReport() }
    }

    private let clock = UniFlowClock.fixed(berlin: "2026-11-11T10:00:00")!
    /// 11.11.2026, 10:00 Berlin
    private let now = Date(timeIntervalSince1970: 1_794_387_600)
    private var bed: ContainerTestBed!
    private var services: [String] = []
    private var requests: [UniAutoLoginRequest] = []

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "neuanmeldung", clock: clock)
        requests = []
        UniAutoLogin.appActiveOverride = false                   // iOS hat die App im Hintergrund gestartet
    }

    override func tearDown() async throws {
        UniAutoLogin.runnerOverride = nil
        UniAutoLogin.appActiveOverride = nil
        HildesheimConnection.backgroundServiceLogin = nil
        for s in services { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary) }
        await bed.tearDown()
        try await super.tearDown()
    }

    private func ready(_ uni: UniversityKey) throws -> (ContainerManager, AccountStore, ActiveContainer) {
        let m = bed.manager()
        let a = bed.account(uni)
        a.markLoginDone()
        let c = try bed.open(m, a)
        services.append(m.credentialService)
        return (m, a, c)
    }

    private func vault(_ m: ContainerManager, _ c: ActiveContainer) -> UniCredentialStore {
        UniCredentialStore(service: m.credentialService, container: c.layout.identifier)
    }

    private func saveLogin(_ m: ContainerManager, _ c: ActiveContainer) throws {
        try vault(m, c).save(UniCredential(username: "testnutzer-erfunden", password: "Pw-Test-erfunden-123", savedAt: Date()))
    }

    /// Hildesheim mit verbundenem Learnweb und LSF, beide abgelaufen; die Dienst-Anmeldung gelingt nur mit gueltiger
    /// CAS-Sitzung (die der Runner "herstellt")
    private func hildesheim() throws -> (ContainerManager, AccountStore, ActiveContainer, HildesheimConnection) {
        let (m, a, c) = try ready(.hildesheim)
        let h = try XCTUnwrap(m.hildesheim)
        h.syncsAfterSignIn = false
        XCTAssertTrue(h.learnwebSignedIn(token: nil, base: "https://www.uni-hildesheim.de/learnweb2026"))
        h.lsfSignedIn()
        h.syncsAfterSignIn = true
        h.learnwebExpired()
        var casValid = false
        UniAutoLogin.runnerOverride = { [unowned self] r in
            self.requests.append(r)
            casValid = true
            return .success
        }
        HildesheimConnection.backgroundServiceLogin = { s, conn in
            guard casValid else { return false }
            if s == .learnweb { _ = conn.learnwebSignedIn(token: nil, base: "https://www.uni-hildesheim.de/learnweb2026") } else { conn.lsfSignedIn() }
            return true
        }
        return (m, a, c, h)
    }

    private func controller(_ m: ContainerManager, _ a: AccountStore) -> (BackgroundSyncController, FakeNotifier) {
        let n = FakeNotifier()
        let b = BackgroundSyncController(containers: m, account: a, settings: BackgroundSyncSettings(defaults: bed.defaults),
                                         scheduler: FakeScheduler(), notifier: n)
        b.allowed = { true }
        b.now = { self.now }
        b.timeZone = { TimeZone(identifier: "Europe/Berlin")! }
        b.weeklyTick = { _ in .off }
        b.gradesStep = { _ in }
        b.autoDue = { _, _, _, _ in BackgroundSyncAppTests.allPortals }
        b.timeLeft = { 0 }
        let quiet = QuietSync()
        b.target = { _ in quiet }
        return (b, n)
    }

    // MARK: Hildesheim (Learnweb, LSF ueber das CAS)

    func testHildesheimReloginInBackgroundWithoutWindowAndWithoutStartingASync() async throws {
        let (m, _, c, h) = try hildesheim()
        try saveLogin(m, c)
        let ok = await h.reloginInBackground(.learnweb)
        XCTAssertTrue(ok)
        XCTAssertEqual(requests.count, 1, "genau ein Versuch mit dem gespeicherten Zugang")
        XCTAssertEqual(requests.first?.background, true, "Webansicht ohne Fenster")
        XCTAssertEqual(requests.first?.entry.absoluteString, HildesheimCAS.lsfLoginURL)
        XCTAssertEqual(requests.first?.portal, "cas")
        XCTAssertNotEqual(h.state(.learnweb), .needsLogin)
        XCTAssertFalse(h.isRunning, "gleicht nicht selbst ab (das macht der Hintergrundlauf in seinem Zeitlimit)")
        XCTAssertTrue(h.syncsAfterSignIn, "Schalter danach wieder wie vorher")
    }

    func testSafeguardNoStoredLoginNoAttempt() async throws {
        let (_, _, _, h) = try hildesheim()
        let ok = await h.reloginInBackground(.learnweb)
        XCTAssertFalse(ok)
        XCTAssertEqual(requests.count, 0, "ohne gespeicherten Uni-Zugang nie ein Passwort")
        XCTAssertEqual(h.state(.learnweb), .needsLogin)
    }

    func testSafeguardRejectedPasswordIsForgottenAndNeverSentASecondTime() async throws {
        let (m, a, c, h) = try hildesheim()
        try saveLogin(m, c)
        h.syncsAfterSignIn = false
        h.lsfSignedIn()
        h.syncsAfterSignIn = true
        // LSF ebenfalls abgelaufen (wie nach einem Lauf mit toter Sitzung)
        UniAutoLogin.runnerOverride = { [unowned self] r in self.requests.append(r); return .wrongPassword }
        let first = await h.reloginInBackground(.learnweb)
        XCTAssertFalse(first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(vault(m, c).load(), "abgelehntes Passwort sofort vergessen")
        XCTAssertTrue(UniAutoLogin.wasRejected(h.websiteDataStore))
        // derselbe Lauf, anderes Portal desselben CAS: nicht noch einmal
        h.learnwebExpired()
        _ = await h.reloginInBackground(.lsf)
        // naechster Hintergrundlauf (alle Portale faellig, Stunden spaeter): nicht noch einmal
        let (b, _) = controller(m, a)
        b.now = { self.now.addingTimeInterval(25 * 3600) }
        b.relogin = { c2, portal in await m.hildesheim?.reloginInBackground(HildesheimConnection.Source(rawValue: portal)!) ?? false }
        _ = c
        await b.perform(.processing)
        XCTAssertEqual(requests.count, 1, "ein abgelehntes Passwort wird nie ein zweites Mal gesendet")
    }

    func testSafeguardNeverAfterSigningOut() async throws {
        let (m, _, c, h) = try hildesheim()
        try saveLogin(m, c)
        _ = await h.signOut()
        let ok = await h.reloginInBackground(.learnweb)
        XCTAssertFalse(ok)
        XCTAssertEqual(requests.count, 0, "bewusst abgemeldet: nie still wieder verbinden")
    }

    func testSafeguardAutomaticSignInSwitchOff() async throws {
        let (m, _, c, h) = try hildesheim()
        try saveLogin(m, c)
        UniAutoLogin.setEnabled(false, store: h.websiteDataStore)
        let ok = await h.reloginInBackground(.learnweb)
        XCTAssertFalse(ok)
        XCTAssertEqual(requests.count, 0, "\"Automatisch anmelden\" aus: kein Passwort")
        XCTAssertNil(vault(m, c).load(), "aus heisst: kein Passwort auf dem Geraet")
    }

    // MARK: Hintergrundlauf (BackgroundSyncController)

    func testBackgroundRunReloginsLearnwebOnlyWithSwitchStoredLoginAndInTheWindow() async throws {
        let (m, a, c, h) = try hildesheim()
        let (b, _) = controller(m, a)
        // ohne gespeicherten Zugang: nichts
        await b.perform(.processing)
        XCTAssertEqual(requests.count, 0)
        try saveLogin(m, c)
        // Schalter "Im Hintergrund neu anmelden" aus: nichts
        BackgroundNewsSettings(defaults: bed.defaults).relogin = false
        await b.perform(.processing)
        XCTAssertEqual(requests.count, 0)
        BackgroundNewsSettings(defaults: bed.defaults).relogin = true
        // ausserhalb von 8 bis 18 Uhr (echte Regel): nichts
        b.autoDue = { c2, t, tz, kind in m.autoSyncDue(now: t, timeZone: tz, continueAtOnce: kind == .processing) }
        b.now = { self.now.addingTimeInterval(9 * 3600) }        // 19:00
        await b.perform(.processing)
        XCTAssertEqual(requests.count, 0, "ausserhalb des Fensters keine Neuanmeldung")
        // kurzer Lauf mit zu wenig Zeit (iOS): nichts. Am Mac gibt es diese Zeitgrenze nicht: der Takt der laufenden App
        // meldet sich dort auch im kurzen Lauf neu an (`reloginInShortRun`, Vorgabe `MacBackgroundTicker.isMac`; geprueft
        // in BackgroundNewsAppTests). Hier gilt fest die Regel von iPad und iPhone, auf jedem Geraet.
        XCTAssertEqual(b.reloginInShortRun, ProcessInfo.processInfo.isiOSAppOnMac, "nur am Mac ohne iOS-Zeitgrenze")
        b.reloginInShortRun = false
        b.autoDue = { _, _, _, _ in BackgroundSyncAppTests.allPortals }
        b.now = { self.now }
        await b.perform(.refresh)
        XCTAssertEqual(requests.count, 0, "zu wenig Zeit fuer eine Anmeldung")
        // kurzer Lauf mit genug Zeit (z. B. nach einem Weck-Signal): ein Versuch, Learnweb wieder da
        b.timeLeft = { 29 }
        await b.perform(.refresh)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNotEqual(h.state(.learnweb), .needsLogin)
        _ = c
    }

    /// seit 20.11.2026: nach einem Fehlschlag kein Versuch mehr im Hintergrund, bis die Anmeldung im Vordergrund gelang
    func testSafeguardFailureStopsBackgroundAttemptsUntilForeground() async throws {
        let (m, a, c, h) = try hildesheim()
        try saveLogin(m, c)
        UniAutoLogin.runnerOverride = { [unowned self] r in self.requests.append(r); return .failed }
        let (b, _) = controller(m, a)
        await b.perform(.processing)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(h.state(.learnweb), .needsLogin)
        XCTAssertNotNil(vault(m, c).load(), "ohne Fehlertext der Seite nichts geloescht")
        b.now = { self.now.addingTimeInterval(23 * 3600) }
        await b.perform(.processing)
        XCTAssertEqual(requests.count, 1, "nach einem Fehlschlag kein weiterer Versuch")
        b.now = { self.now.addingTimeInterval(49 * 3600) }
        await b.perform(.processing)
        XCTAssertEqual(requests.count, 1, "auch nach zwei Tagen nicht (frueher nach 24 Stunden)")
    }

    // MARK: HsH (Moodle, Campusmanagement)

    func testHsHReloginInBackgroundWithoutWindowAndWithoutStartingASync() async throws {
        let (m, _, c) = try ready(.hsh)
        let hsh = try XCTUnwrap(m.hsh)
        hsh.syncsAfterSignIn = false
        hsh.signedIn(.moodle)
        hsh.syncsAfterSignIn = true
        hsh.moodleExpired()
        UniAutoLogin.runnerOverride = { [unowned self] r in self.requests.append(r); return .success }
        // ohne gespeicherten Zugang: nichts
        let none = await hsh.autoLogin(.moodle, background: true)
        XCTAssertFalse(none)
        XCTAssertEqual(requests.count, 0)
        try saveLogin(m, c)
        // der Weg im Vordergrund bleibt im Hintergrund wirkungslos (nie ohne ausdrueckliche Hintergrund-Anmeldung)
        _ = await hsh.autoLogin(.moodle)
        XCTAssertEqual(requests.count, 0)
        let ok = await hsh.autoLogin(.moodle, background: true)
        XCTAssertTrue(ok)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.background, true)
        XCTAssertEqual(hsh.state(.moodle), .connected)
        XCTAssertFalse(hsh.isRunning, "kein Abgleich von selbst nach der Anmeldung im Hintergrund")
        XCTAssertTrue(hsh.syncsAfterSignIn)
    }

    func testHsHRejectedPasswordInTheBackgroundIsForgottenAndNeverSentAgain() async throws {
        let (m, _, c) = try ready(.hsh)
        let hsh = try XCTUnwrap(m.hsh)
        hsh.syncsAfterSignIn = false
        hsh.signedIn(.moodle)
        hsh.signedIn(.campus)
        hsh.moodleExpired()
        hsh.certificatesExpired()                                // Campusmanagement ebenfalls abgelaufen
        try saveLogin(m, c)
        UniAutoLogin.runnerOverride = { [unowned self] r in self.requests.append(r); return .wrongPassword }
        let first = await hsh.autoLogin(.moodle, background: true)
        XCTAssertFalse(first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(vault(m, c).load(), "abgelehnt: sofort vergessen")
        let second = await hsh.autoLogin(.campus, background: true)
        XCTAssertFalse(second)
        XCTAssertEqual(requests.count, 1, "auch das zweite Portal sendet es nicht noch einmal")
        XCTAssertEqual(hsh.state(.moodle), .needsLogin)
    }

    func testBackgroundControllerMapsAllPortalNames() async throws {
        let (m, a, c) = try ready(.hsh)
        let hsh = try XCTUnwrap(m.hsh)
        hsh.syncsAfterSignIn = false
        hsh.signedIn(.moodle)
        hsh.moodleExpired()
        let (b, _) = controller(m, a)
        XCTAssertEqual(b.expiredPortals(c), ["Moodle"])
        UniAutoLogin.runnerOverride = { [unowned self] r in self.requests.append(r); return .success }
        try saveLogin(m, c)
        await b.perform(.processing)
        XCTAssertEqual(requests.map(\.portal), [HsHConnection.Source.moodle.loginService])
        XCTAssertEqual(hsh.state(.moodle), .connected)
    }
}
