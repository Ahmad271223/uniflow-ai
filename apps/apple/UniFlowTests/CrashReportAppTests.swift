import os
import UniFlowCore
import XCTest
@testable import UniFlow

/// Absturzmeldung, Teil der App (25.11.2026, docs/ABSTURZMELDUNG-2026-11-25.md): Schalter, Anmeldung bei MetricKit,
/// Empfang -> Warteschlange -> Dienst, und dass ohne Erlaubnis nichts gemerkt und nichts geschickt wird.
/// Kein Netz, kein echter Absturz: Apples Daten sind die erfundenen aus
/// packages/shared-contracts/fixtures/crash-report/ (MetricKit liefert im Simulator nie etwas).
final class CrashReportAppTests: XCTestCase {
    /// Dienst-Attrappe: schreibt jede Anfrage mit
    private final class FakeService: ServiceHTTPTransport, @unchecked Sendable {
        let seen = OSAllocatedUnfairLock(initialState: [AIHTTPRequest]())
        let status = OSAllocatedUnfairLock(initialState: 200)
        func send(_ request: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            seen.withLock { $0.append(request) }
            return ServiceHTTPResponse(status: status.withLock { $0 }, body: Data(#"{"ok":true}"#.utf8))
        }
        var requests: [AIHTTPRequest] { seen.withLock { $0 } }
    }

    private var suite: String!
    private var defaults: UserDefaults!
    private var service: FakeService!
    private var reporter: CrashReporter!
    private var file: URL!
    private let subscriptions = OSAllocatedUnfairLock(initialState: [String]())

    override func setUp() async throws {
        try await super.setUp()
        suite = "uniflow.tests.crashreports.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        service = FakeService()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("crash-app-\(UUID().uuidString)/absturzmeldungen.json")
        subscriptions.withLock { $0 = [] }
        let r = CrashReporter()
        r.defaults = defaults
        r.allowed = { true }
        r.client = { [service] in CrashReportClient(base: "https://dienst.example.invalid", http: service!) }
        r.outbox = CrashReportOutbox(file: file)
        r.subscribe = { [subscriptions] _ in subscriptions.withLock { $0.append("an") } }
        r.unsubscribe = { [subscriptions] _ in subscriptions.withLock { $0.append("ab") } }
        r.context = MetricKitReports.Context(appVersion: "1.0.7", appBuild: "49", deviceClass: "ipad", channel: "store", appBinaries: ["UniFlow"])
        reporter = r
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try await super.tearDown()
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/crash-report/\(name)"))
    }

    private func body(_ r: AIHTTPRequest) throws -> JSONValue { try JSONValue.parse(try XCTUnwrap(r.body)) }

    private func wait(_ what: String, timeout: TimeInterval = 5, _ done: @escaping () async -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await done() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Zeit abgelaufen: \(what)")
    }

    // MARK: Schalter

    func testSwitchIsOnUntilSwitchedOffAndForgetsTheInstallID() async {
        let accountDevice = await MainActor.run { StudoraAccountLink.deviceID }
        XCTAssertTrue(CrashReportSetting.onByDefault, "Entscheidung des Inhabers 25.11.2026: von selbst an (docs/ABSTURZMELDUNG-2026-11-25.md)")
        XCTAssertTrue(CrashReportSetting.isOn(defaults))
        let id = CrashReportSetting.installID(defaults)
        XCTAssertEqual(id.count, 32)
        XCTAssertNotNil(id.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertEqual(CrashReportSetting.installID(defaults), id, "bleibt, solange der Schalter an ist")
        // nicht die Geraete-Kennung des Kontos: sonst liesse sich die Meldung beim Dienst einem Konto zuordnen
        XCTAssertFalse(accountDevice.lowercased().replacingOccurrences(of: "-", with: "").contains(id))
        CrashReportSetting.set(false, defaults)
        XCTAssertFalse(CrashReportSetting.isOn(defaults))
        XCTAssertNil(defaults.string(forKey: CrashReportSetting.installKey), "aus: Kennung weg")
        CrashReportSetting.set(true, defaults)
        XCTAssertNotEqual(CrashReportSetting.installID(defaults), id, "wieder an: neue Kennung")
        // der Satz am Schalter nennt, was geht, und keine Beträge
        for word in ["App-Version", "Gerätemodell", "Systemversion", "Zeitpunkt", "Ohne deinen Namen", "ohne dein Konto", "Ausschalten"] {
            XCTAssertTrue(CrashReportSetting.short.contains(word), word)
        }
    }

    // MARK: Empfang -> Warteschlange -> Dienst

    func testDiagnosticsFromAppleReachTheServiceAsAgreed() async throws {
        let at = Date().addingTimeInterval(-3600)
        await reporter.take(diagnostics: [(try fixture("metrickit-diagnostic.json"), at)])
        await reporter.take(metrics: [(try fixture("metrickit-metric.json"), at)])
        XCTAssertEqual(service.requests.count, 2, "nach jedem Empfang gleich geschickt")
        let first = try body(service.requests[0]), second = try body(service.requests[1])
        XCTAssertEqual(service.requests[0].url, "https://dienst.example.invalid/api/diagnose/crashes")
        XCTAssertNil(service.requests[0].headers["Authorization"], "ohne Konto")
        XCTAssertEqual(first["install"]?.string, CrashReportSetting.installID(defaults))
        XCTAssertEqual(first["reports"]?.array?.compactMap { $0["kind"]?.string }, ["crash", "crash", "hang"])
        XCTAssertEqual(second["reports"]?.array?.compactMap { $0["reason"]?.string }, ["memory_limit", "bad_access"])
        // bis auf Kennung und Zeitpunkt genau die Meldungen des Vertrags (upload.json)
        let expected = try JSONValue.parse(try fixture("upload.json"))["reports"]?.array ?? []
        let sent = (first["reports"]?.array ?? []) + (second["reports"]?.array ?? [])
        func bare(_ r: JSONValue) -> JSONValue { var o = r; o["id"] = nil; o["at"] = nil; return o }
        XCTAssertEqual(sent.map(bare), expected.map(bare))
        XCTAssertEqual(sent.first?["at"]?.string, CrashReport.timestamp(at))
        let text = service.requests.compactMap { $0.body.map { String(decoding: $0, as: UTF8.self) } }.joined()
        let accountDevice = await MainActor.run { StudoraAccountLink.deviceID }
        for secret in ["Müller", "Klausur", "de.uniflow.ai", "not in any region", accountDevice] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        let rest = await reporter.outbox.pending()
        XCTAssertTrue(rest.isEmpty, "angenommen: Warteschlange leer")
    }

    func testReportsWaitUntilTheServiceIsReachable() async throws {
        service.status.withLock { $0 = 503 }
        await reporter.take(diagnostics: [(try fixture("metrickit-diagnostic.json"), Date())])
        var waiting = await reporter.outbox.pending().count
        XCTAssertEqual(waiting, 3, "Dienst nicht erreichbar: Meldungen bleiben liegen")
        // "naechster Start": ein neuer Melder mit derselben Datei schickt sie
        service.status.withLock { $0 = 200 }
        let next = CrashReporter()
        next.defaults = defaults
        next.allowed = { true }
        next.client = reporter.client
        next.outbox = CrashReportOutbox(file: file)
        next.subscribe = reporter.subscribe
        next.context = reporter.context
        await MainActor.run { next.refresh() }
        await wait("Warteschlange leer") { await next.outbox.pending().isEmpty }
        waiting = await next.outbox.pending().count
        XCTAssertEqual(waiting, 0)
        XCTAssertEqual(try body(try XCTUnwrap(service.requests.last))["reports"]?.array?.count, 3)
        XCTAssertEqual(subscriptions.withLock { $0 }, ["an"], "beim Start bei MetricKit angemeldet")
    }

    // MARK: ohne Erlaubnis nichts

    func testSwitchedOffNothingIsKeptAndNothingIsSent() async throws {
        await MainActor.run { reporter.refresh() }
        XCTAssertEqual(subscriptions.withLock { $0 }, ["an"])
        await MainActor.run { reporter.refresh() }
        XCTAssertEqual(subscriptions.withLock { $0 }, ["an"], "nur einmal angemeldet")
        // etwas wartet (Dienst nicht erreichbar), dann schaltet der Nutzer aus
        service.status.withLock { $0 = 503 }
        await reporter.take(diagnostics: [(try fixture("metrickit-diagnostic.json"), Date())])
        let before = service.requests.count
        _ = CrashReportSetting.installID(defaults)
        CrashReportSetting.set(false, defaults)
        await MainActor.run { reporter.refresh() }
        await wait("Warteschlange geloescht") { await self.reporter.outbox.pending().isEmpty }
        XCTAssertEqual(subscriptions.withLock { $0 }, ["an", "ab"], "bei MetricKit abgemeldet")
        XCTAssertNil(defaults.string(forKey: CrashReportSetting.installKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Datei der Warteschlange weg")
        // kommt danach noch etwas von iOS: nicht merken, nicht schicken
        service.status.withLock { $0 = 200 }
        await reporter.take(diagnostics: [(try fixture("metrickit-diagnostic.json"), Date())])
        await reporter.take(metrics: [(try fixture("metrickit-metric.json"), Date())])
        let sent = await reporter.flush()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(service.requests.count, before)
        let rest = await reporter.outbox.pending()
        XCTAssertTrue(rest.isEmpty)
    }

    func testDebugBuildsAndTestsNeverSend() async throws {
        // so laeuft die App im Simulator und unter XCTest wirklich: `allowed` ist dort aus
        XCTAssertFalse(CrashReporter.shared.allowed(), "Debug-Build bzw. XCTest: nie")
        XCTAssertFalse(CrashReporter.buildSends, "Tests laufen im Debug-Build")
        reporter.allowed = { false }
        await MainActor.run { reporter.refresh() }
        await reporter.take(diagnostics: [(try fixture("metrickit-diagnostic.json"), Date())])
        let sent = await reporter.flush()
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(service.requests.isEmpty)
        XCTAssertTrue(subscriptions.withLock { $0 }.isEmpty)
        let rest = await reporter.outbox.pending()
        XCTAssertTrue(rest.isEmpty)
        XCTAssertFalse(CrashReporter.shared.isSubscribed)
    }

    // MARK: Angaben der App

    func testSourceAndDeviceClass() async {
        XCTAssertEqual(CrashReporter.channel(debug: false, receiptName: "receipt", hasProvisioningProfile: false), "store")
        XCTAssertEqual(CrashReporter.channel(debug: false, receiptName: "sandboxReceipt", hasProvisioningProfile: false), "test", "TestFlight")
        XCTAssertEqual(CrashReporter.channel(debug: false, receiptName: "receipt", hasProvisioningProfile: true), "test", "Kabel-Fassung")
        XCTAssertEqual(CrashReporter.channel(debug: true, receiptName: "receipt", hasProvisioningProfile: false), "test", "Xcode")
        XCTAssertEqual(CrashReporter.channel(debug: false, receiptName: nil, hasProvisioningProfile: false), "store")
        XCTAssertEqual(CrashReporter.deviceClass(isMac: true, idiom: .pad), "mac")
        XCTAssertEqual(CrashReporter.deviceClass(isMac: false, idiom: .pad), "ipad")
        XCTAssertEqual(CrashReporter.deviceClass(isMac: false, idiom: .phone), "iphone")
        let c = await MainActor.run { CrashReporter.currentContext() }
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(c.appVersion, info["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(c.appBuild, info["CFBundleVersion"] as? String)
        XCTAssertEqual(c.channel, "test", "Simulator")
        XCTAssertEqual(c.appBinaries, ["UniFlow"], "Name der Programmdatei, wie ihn der Dienst kennt (APP_BINARIES)")
        XCTAssertTrue(["ipad", "iphone"].contains(c.deviceClass))
    }

    /// Die Verbindung der Meldungen traegt nie ein Cookie: der Dienst setzt bei der Anmeldung des Kontos eins, und mit
    /// der gemeinsamen Verbindung der App ginge es bei jeder Meldung mit.
    func testConnectionCarriesNoCookiesAndNoStoredLogins() {
        let c = CrashReporter.sessionConfiguration()
        XCTAssertNil(c.httpCookieStorage)
        XCTAssertFalse(c.httpShouldSetCookies)
        XCTAssertNil(c.urlCredentialStorage)
        XCTAssertNil(c.urlCache)
        XCTAssertNil(CrashReporter.session.configuration.httpCookieStorage)
        XCTAssertFalse(CrashReporter.session === URLSession.shared)
    }

    /// Zeitstempel eines Pakets: ein fehlender Wert ergibt "jetzt" statt eines Absturzes
    func testMissingTimestampDoesNotCrash() {
        final class Paket: NSObject {
            @objc var timeStampEnd: Date? = Date(timeIntervalSince1970: 1_795_508_100)
            @objc var timeStampBegin: Date?
        }
        XCTAssertEqual(CrashReporter.date(Paket(), "timeStampEnd"), Date(timeIntervalSince1970: 1_795_508_100))
        XCTAssertLessThan(abs(CrashReporter.date(Paket(), "timeStampBegin").timeIntervalSinceNow), 5)
    }

    // Die echten Klassen von Apple (MXDiagnosticPayload, MXMetricPayload) lassen sich in Tests nicht fuellen, und ein
    // leer erzeugtes Paket bringt den Prozess zum Absturz (25.11.2026 im Simulator probiert). Darum nimmt
    // `take(diagnostics:)` Apples JSON entgegen: `didReceive` reicht nur `jsonRepresentation()` (das ruft `HaengerSpur`
    // seit Wochen auf echten Geraeten) und den Zeitstempel des Pakets weiter.
}
