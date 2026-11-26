import os
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Weck-Signal, Teil der App (Auftrag des Inhabers 17.11.2026, docs/WECK-SIGNAL-2026-11-17.md): Registrierung, Meldung
/// an den Dienst (nur Token, Plattform, Version, Zeitzone, Umgebung), Zuruecknehmen bei "Im Hintergrund abgleichen" aus,
/// Empfang nur einer reinen Weck-Nachricht, Lauf nach der Regel im Zeitlimit. Kein Netz, kein Apple, erfundene Tokens.
@MainActor
final class WakePushAppTests: XCTestCase {
    /// Dienst-Attrappe: schreibt jede Anfrage mit
    private final class FakeService: ServiceHTTPTransport, @unchecked Sendable {
        let seen = OSAllocatedUnfairLock(initialState: [AIHTTPRequest]())
        var status = 200
        func send(_ request: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            seen.withLock { $0.append(request) }
            return ServiceHTTPResponse(status: status, body: Data(#"{"ok":true}"#.utf8))
        }
        var requests: [AIHTTPRequest] { seen.withLock { $0 } }
    }

    private struct FixedToken: AccountTokenStore {
        let token: String?
        func load() -> String? { token }
        func save(_ token: String?) throws {}
    }

    private let apnsToken = Data((0..<32).map { UInt8($0) })
    private var hexToken: String { WakePush.hex(apnsToken) }
    private var suite: String!
    private var service: FakeService!
    private var push: WakePush!
    private var appleRegistrations = 0
    private var appleUnregistrations = 0
    private var enabled = true

    override func setUp() async throws {
        try await super.setUp()
        suite = "uniflow.tests.wakepush.\(UUID().uuidString)"
        service = FakeService()
        push = WakePush()
        push.defaults = UserDefaults(suiteName: suite)!
        push.allowed = { true }
        push.enabled = { [unowned self] in self.enabled }
        push.client = { [unowned self] in WakePushClient(base: "https://dienst.example.invalid", http: self.service, tokens: FixedToken(token: "sitzung-erfunden")) }
        push.registerWithApple = { [unowned self] in self.appleRegistrations += 1 }
        push.unregisterWithApple = { [unowned self] in self.appleUnregistrations += 1 }
        push.timeZone = { TimeZone(identifier: "Europe/Berlin")! }
        appleRegistrations = 0
        appleUnregistrations = 0
        enabled = true
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func json(_ r: AIHTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.body)) as? [String: Any])
    }

    /// 1.0.6: kein "remote-notification", solange Push in der App-ID aus ist (Weck-Signal kommt mit einem spaeteren Update)
    func testInfoPlistHasNoRemoteNotificationBackgroundModeYet() throws {
        let modes = try XCTUnwrap(Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String])
        XCTAssertFalse(modes.contains("remote-notification"))
    }

    func testOnlyAPureWakeMessageStartsARun() async {
        XCTAssertTrue(WakePush.isWake(["aps": ["content-available": 1]]))
        XCTAssertFalse(WakePush.isWake(["aps": ["content-available": 1, "alert": "Hallo"]]), "mit Text: keine Weck-Nachricht")
        XCTAssertFalse(WakePush.isWake(["aps": ["content-available": 1, "sound": "default"]]))
        XCTAssertFalse(WakePush.isWake(["aps": ["content-available": 0]]))
        XCTAssertFalse(WakePush.isWake([:]))
        var wakes = 0
        push.onWake = { wakes += 1; return .newData }
        let other = await push.handle(["aps": ["alert": "Werbung"]])
        XCTAssertEqual(other, .noData)
        XCTAssertEqual(wakes, 0)
        let wake = await push.handle(["aps": ["content-available": 1]])
        XCTAssertEqual(wake, .newData)
        XCTAssertEqual(wakes, 1)
    }

    func testRegistrationSendsOnlyTokenPlatformVersionTimeZoneEnvironment() async throws {
        push.refresh()
        XCTAssertEqual(appleRegistrations, 1, "bei Apple registrieren (stille Nachrichten brauchen keine Erlaubnis)")
        XCTAssertTrue(service.requests.isEmpty, "ohne Token noch nichts an den Dienst")
        await push.received(token: apnsToken)
        let r = try XCTUnwrap(service.requests.first)
        XCTAssertEqual(r.method, "PUT")
        XCTAssertEqual(r.url, "https://dienst.example.invalid/api/account/push-token")
        XCTAssertEqual(r.headers["Authorization"], "Bearer sitzung-erfunden")
        let body = try json(r)
        XCTAssertEqual(Set(body.keys), ["token", "platform", "app_version", "timezone", "environment"], "nur diese fuenf Angaben")
        XCTAssertEqual(body["token"] as? String, hexToken)
        XCTAssertEqual(body["token"] as? String, String(repeating: "", count: 0) + (0..<32).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(body["timezone"] as? String, "Europe/Berlin")
        XCTAssertTrue(["ios", "ipados", "macos"].contains(body["platform"] as? String ?? ""))
        XCTAssertEqual(body["environment"] as? String, "sandbox", "Testbuild aus Xcode: Sandbox")
        XCTAssertLessThanOrEqual((body["app_version"] as? String ?? "").count, 40)
        // dasselbe noch einmal: nicht doppelt; neue Zeitzone: neu melden
        await push.report()
        XCTAssertEqual(service.requests.count, 1)
        push.timeZone = { TimeZone(identifier: "America/New_York")! }
        await push.report()
        XCTAssertEqual(service.requests.count, 2)
        XCTAssertEqual(try json(service.requests[1])["timezone"] as? String, "America/New_York")
        // neues Token von Apple: gemeldet
        await push.received(token: Data(repeating: 0xab, count: 32))
        XCTAssertEqual(service.requests.count, 3)
        XCTAssertEqual(push.deviceToken, String(repeating: "ab", count: 32))
    }

    /// 26.11.2026 ("Abruf schonen"): der Dienst weckt je Konto nur das zuletzt benutzte Geraet. Darum meldet sich die App
    /// beim Oeffnen erneut, wenn die letzte Meldung mindestens eine Stunde her ist - oefter nicht.
    func testSameRegistrationIsRepeatedAfterAnHourSoTheServiceKnowsTheDeviceInUse() async throws {
        var clock = Date(timeIntervalSince1970: 1_795_000_000)
        push.now = { clock }
        await push.received(token: apnsToken)
        XCTAssertEqual(service.requests.count, 1)
        clock = clock.addingTimeInterval(WakePush.reportAgain - 1)
        await push.report()
        XCTAssertEqual(service.requests.count, 1, "innerhalb einer Stunde nicht noch einmal")
        clock = clock.addingTimeInterval(1)
        await push.report()
        XCTAssertEqual(service.requests.count, 2, "nach einer Stunde: erneut melden (zuletzt benutzt)")
        clock = clock.addingTimeInterval(-3 * 3600)
        await push.report()
        XCTAssertEqual(service.requests.count, 3, "Uhr zurueckgestellt: lieber einmal mehr melden")
        XCTAssertEqual(WakePush.reportAgain, 3600)
    }

    func testWithoutAccountNothingIsRegistered() async {
        push.client = { nil }
        push.refresh()
        XCTAssertEqual(appleRegistrations, 0, "ohne StudiNow-Konto kein Weck-Signal")
        await push.received(token: apnsToken)
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testSwitchOffDeletesTheTokenOnTheServerAndAtApple() async throws {
        push.refresh()
        await push.received(token: apnsToken)
        XCTAssertEqual(service.requests.count, 1)
        enabled = false
        let ok = await push.withdraw()
        XCTAssertTrue(ok)
        let r = try XCTUnwrap(service.requests.last)
        XCTAssertEqual(r.method, "DELETE")
        XCTAssertEqual(try json(r)["token"] as? String, hexToken)
        XCTAssertEqual(appleUnregistrations, 1)
        XCTAssertNil(push.deviceToken)
        // aus: auch ein neues Token wird nicht gemeldet
        await push.received(token: apnsToken)
        XCTAssertEqual(service.requests.count, 2)
    }

    func testNeverUnderTestUnlessAllowed() {
        push.allowed = { false }
        push.refresh()
        XCTAssertEqual(appleRegistrations, 0)
        XCTAssertEqual(appleUnregistrations, 0)
    }

    func testControllerSwitchTellsWakePush() async throws {
        let bed = try ContainerTestBed(name: "weck", clock: .fixed(berlin: "2026-11-11T10:00:00")!)
        let m = bed.manager()
        let a = bed.account(.luh)
        a.markLoginDone()
        _ = try bed.open(m, a)
        let b = BackgroundSyncController(containers: m, account: a, settings: BackgroundSyncSettings(defaults: bed.defaults))
        var told: [Bool] = []
        b.onEnabledChange = { told.append($0) }
        b.setEnabled(false)
        b.setEnabled(true)
        XCTAssertEqual(told, [false, true])
        await bed.tearDown()
    }
}
