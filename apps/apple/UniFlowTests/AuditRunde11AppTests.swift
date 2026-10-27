import PDFKit
import PencilKit
import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Externe Pruefpunkte 333, 346, 358 und 361-379 in der App (docs/AUFTRAG und docs/audit/RUNDE-11-331-380.md):
/// Editor (nicht darstellbare Striche, nicht lesbares Journal, Konfliktseiten), Uni Hildesheim (paralleler Abgleich,
/// Abmelden waehrend des Abgleichs, Hochschulwechsel waehrend des Downloads, Teilerfolg, erneute Anmeldung,
/// unterbrochenes Abmelden), Container (Loeschfehler, spaete Schreibzugriffe, mehrfacher Wechsel) und Diagnose. Kein
/// Netz (URLSession nur mit `UniStubProtocol`), nur Temp-Ordner, eigene Schluesselbund-Dienste und Einstellungs-Suiten,
/// erfundene Nutzer, Cookies, Schluessel und Inhalte.
@MainActor
final class AuditRunde11AppTests: XCTestCase {

    private final class MemorySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { values[key] = value }
        func delete(_ key: String) { values[key] = nil }
    }

    private struct Authorized: AppleCredentialChecking {
        func state(forUserID id: String) async -> AppleCredentialState { .authorized }
    }

    /// Schluesselbund, der Eintraege nicht mehr hergibt (Entfernen wirkungslos, wie bei einem Fehler)
    private final class StuckSecrets: UniversitySecretStoring {
        var values: [String: String] = [:]
        func read(_ account: String) -> String? { values[account] }
        func write(_ value: String, account: String) -> Bool { values[account] = value; return true }
        func remove(_ account: String) {}
        func accounts() -> [String] { Array(values.keys) }
        func removeAll() -> Bool { values.isEmpty }
    }

    private var appSupport: URL!
    private var keychain: UniversityKeychain!
    private var cookieService = ""
    private var suite = ""
    private var defaults: UserDefaults!
    private var websiteStores: [UUID] = []
    private let user = "001234.erfunden-runde11.\(UUID().uuidString.prefix(8))"
    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T10:00:00")!
    private let lw = "https://www.uni-hildesheim.de/learnweb2026"
    private let lsf = "https://lsf.uni-hildesheim.de"
    private let token = "TestSchluessel0123456789abcdef"

    override func setUp() async throws {
        try await super.setUp()
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-runde11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        keychain = UniversityKeychain(service: "de.uniflow.ai.university.test.\(UUID().uuidString)")
        cookieService = "de.uniflow.ai.studip.test.\(UUID().uuidString)"
        suite = "uniflow.tests.runde11.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        UniStubProtocol.reset()
    }

    override func tearDown() async throws {
        UniStubProtocol.reset()
        keychain.accounts().forEach(keychain.remove)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: cookieService] as CFDictionary)
        defaults.removePersistentDomain(forName: suite)
        for layout in DataContainerLayout.all(base: containers, userID: user) {
            let s = ActiveContainer.defaultsSuite(layout.identifier)
            UserDefaults(suiteName: s)?.removePersistentDomain(forName: s)
            websiteStores.append(layout.identifier)
        }
        for id in Set(websiteStores) {
            await WKWebsiteDataStore(forIdentifier: id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: containers.path)
        try? FileManager.default.removeItem(at: appSupport)
        try await super.tearDown()
    }

    private var containers: URL { appSupport.appendingPathComponent("UniFlowContainers", isDirectory: true) }

    private func manager(keychain: UniversitySecretStoring? = nil) -> ContainerManager {
        ContainerManager(base: containers,
                         legacy: LegacyDataMigration.Sources(support: appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                             studip: appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                         keychain: keychain ?? self.keychain, cookieService: cookieService, defaults: defaults, clock: clock,
                         publishesCurrent: false,
                         hildesheimTransport: { store in await URLSessionUniTransport.make(dataStore: store, configuration: UniStubProtocol.configuration()) })
    }

    private func account(_ uni: UniversityKey) -> AccountStore {
        let a = AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: Authorized(), observeRevocation: false)
        a.signIn(userID: user, name: nil, email: nil)
        a.markPlanShown()
        a.chooseUniversity(uni)
        return a
    }

    private func open(_ m: ContainerManager, _ a: AccountStore) throws -> ActiveContainer {
        m.sync(account: a)
        let c = try XCTUnwrap(m.active, m.problem ?? "kein Container")
        websiteStores.append(c.websiteDataStoreID)
        m.hildesheim?.syncsAfterSignIn = false
        return c
    }

    private func repo(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("Zeitueberschreitung: \(what)")
    }

    private func cookie(_ name: String, _ value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE",
                                .expires: Date().addingTimeInterval(3600)])!
    }

    /// Uni Hildesheim wie die Uni (Fixtures), Downloads warten an `gate`
    private func installUni(gate: StubGate? = nil, learnwebFails: Bool = false) throws {
        let ics = try repo("packages/shared-contracts/fixtures/hildesheim/lsf-course.ics")
        let contents = try repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json")
        let uni = HildesheimAppTests.uniHildesheim(base: lw, lsf: lsf, token: token, ics: ics, contents: contents)
        let lw = self.lw
        UniStubProtocol.install { r in
            if learnwebFails, r.url.absoluteString.hasPrefix(lw + "/webservice/") { return .text("", status: 500) }
            if r.url.path.contains("/webservice/pluginfile.php/") { gate?.pass() }
            return uni(r)
        }
    }

    /// Hildesheimer Container mit verbundenem Learnweb (Schluessel) und LSF (Sitzung im Datenspeicher)
    private func connectedHildesheim(_ m: ContainerManager, _ a: AccountStore, lsfToo: Bool = true) async throws -> (ActiveContainer, HildesheimConnection) {
        let c = try open(m, a)
        let h = try XCTUnwrap(m.hildesheim)
        XCTAssertTrue(h.learnwebSignedIn(token: try XCTUnwrap(LearnwebToken(token)), base: lw))
        if lsfToo {
            await m.websiteDataStore(for: c).httpCookieStore.setCookie(cookie("JSESSIONID", "lsf-sitzung-test", domain: "lsf.uni-hildesheim.de"))
            h.lsfSignedIn()
        }
        return (c, h)
    }

    private func learnwebFiles(_ c: ActiveContainer) async throws -> Int {
        try await c.host.backend().context.database.scalar("SELECT COUNT(*) FROM files WHERE local_path IS NOT NULL AND course_id LIKE 'lw-%'")?.int ?? -1
    }

    // MARK: 361 mehrfach gestarteter Abgleich

    func testSecondRunWhileOneIsRunningStartsNothing() async throws {
        let m = manager()
        let (_, h) = try await connectedHildesheim(m, account(.hildesheim), lsfToo: false)
        let gate = StubGate()
        try installUni(gate: gate)
        let first = Task { await h.run() }
        try await waitUntil("Download laeuft") { gate.wasReached }
        let siteInfos = UniStubProtocol.requests.filter { $0.bodyText.contains("core_webservice_get_site_info") }.count
        let second = await h.run()
        XCTAssertNil(second, "zweiter Lauf beginnt nicht")
        let forced = await h.run(forceGrades: true)
        XCTAssertNil(forced)
        h.runIfDue()
        await Task.yield()
        gate.release()
        let firstReport = await first.value
        let report = try XCTUnwrap(firstReport)
        XCTAssertTrue(report.ok, report.messages.joined(separator: "; "))
        XCTAssertEqual(UniStubProtocol.requests.filter { $0.bodyText.contains("core_webservice_get_site_info") }.count, siteInfos,
                       "kein zweiter Lauf hat Learnweb gefragt")
        XCTAssertFalse(h.isRunning)
    }

    // MARK: 362 Abmelden waehrend des Abgleichs

    func testSignOutDuringARunningSyncStopsItFirst() async throws {
        let m = manager()
        let (c, h) = try await connectedHildesheim(m, account(.hildesheim))
        let gate = StubGate()
        try installUni(gate: gate)
        let run = Task { await h.run() }
        try await waitUntil("Download laeuft") { gate.wasReached }
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(cookie("TGC", "cas-test", domain: "www.uni-hildesheim.de"))
        let signOut = Task { await h.signOut() }
        try await Task.sleep(nanoseconds: 200_000_000)
        gate.release()
        let problem = await signOut.value
        XCTAssertNil(problem)
        XCTAssertFalse(h.isRunning, "Abgleich beendet, bevor Abmelden zurueckkehrt")
        let report = await run.value
        XCTAssertEqual(report?.cancelled, true, "angehalten statt zu Ende gelaufen")
        let requestsAfter = UniStubProtocol.requests.count
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(UniStubProtocol.requests.count, requestsAfter, "nach dem Abmelden keine Anfrage mehr")
        XCTAssertEqual(h.learnweb, .notConnected)
        XCTAssertEqual(h.lsf, .notConnected)
        XCTAssertTrue(h.messages.isEmpty)
        XCTAssertNil(c.tokens.token(.hildesheim, service: "learnweb"))
        let web = await m.websiteDataStore(for: c).httpCookieStore.allCookies()
        XCTAssertTrue(web.isEmpty)
        XCTAssertFalse(c.defaults.bool(forKey: HildesheimConnection.Keys.signOutPending))
        let again = await h.run()
        XCTAssertNil(again, "abgemeldet: kein Lauf")
    }

    /// Dasselbe fuer Stud.IP der LUH: nach dem Abmelden steht "abgemeldet", nicht "verbunden"
    func testStudIPSignOutDuringARunStopsItAndStaysSignedOut() async throws {
        let m = manager()
        let c = try open(m, account(.luh))
        try c.cookies.save([cookie("Seminar_Session", "sitzung-test", domain: "studip.uni-hannover.de")])
        let stud = WaitingStudIP()
        let sync = m.studip
        let run = Task { await sync.run(client: StudIPClient(base: StudIPSync.base, transport: stud, pauseMillis: 0)) }
        try await waitUntil("Stud.IP-Download laeuft") { stud.gate.wasReached }
        let signOut = Task { await sync.signOut() }
        try await Task.sleep(nanoseconds: 200_000_000)
        stud.gate.release()
        await signOut.value
        XCTAssertFalse(sync.isRunning)
        XCTAssertEqual(sync.phase, .signedOut, "vorher stand nach dem Lauf wieder \"verbunden\"")
        let end = await run.value
        XCTAssertEqual(end, .cancelled)
        XCTAssertTrue(c.cookies.load().isEmpty)
    }

    /// 362, Luecke beim Start: Abmelden, waehrend ein Lauf noch die Demo-Pruefung abwartet (noch ohne laufende Aufgabe,
    /// das Abmelden kann ihn nicht anhalten). Vorher begann er danach mit dem Client der alten Sitzung, fragte Stud.IP
    /// und stand am Ende wieder auf "verbunden".
    func testStudIPSignOutWhileARunIsStillStartingKeepsItFromStarting() async throws {
        let m = manager()
        let c = try open(m, account(.luh))
        try c.cookies.save([cookie("Seminar_Session", "sitzung-test", domain: "studip.uni-hannover.de")])
        let stud = WaitingStudIP()
        let sync = m.studip
        let run = Task { await sync.run(client: StudIPClient(base: StudIPSync.base, transport: stud, pauseMillis: 0)) }
        await Task.yield()                                   // der Lauf wartet jetzt in der Demo-Pruefung
        XCTAssertFalse(sync.isRunning)
        await sync.signOut()
        stud.gate.release()
        let end = await run.value
        XCTAssertNil(end, "nach dem Abmelden beginnt der Lauf nicht mehr")
        XCTAssertEqual(stud.requests, 0, "keine Anfrage mit der alten Sitzung")
        XCTAssertEqual(sync.phase, .signedOut)
        XCTAssertFalse(sync.isRunning)
        XCTAssertTrue(c.cookies.load().isEmpty)
    }

    /// Dasselbe fuer die Uni Hildesheim: der wartende Lauf beginnt nicht, zaehlt nicht als Lauf, fragt niemanden
    func testHildesheimSignOutWhileARunIsStillStartingStartsNothing() async throws {
        let m = manager()
        let (c, h) = try await connectedHildesheim(m, account(.hildesheim))
        try installUni()
        let runsBefore = h.finishedRuns
        let lastRunBefore = h.lastRun
        let run = Task { await h.run() }
        await Task.yield()                                   // der Lauf wartet jetzt in der Demo-Pruefung
        XCTAssertFalse(h.isRunning)
        let problem = await h.signOut()
        XCTAssertNil(problem)
        let report = await run.value
        XCTAssertNil(report, "nach dem Abmelden beginnt der Lauf nicht mehr")
        XCTAssertEqual(h.finishedRuns, runsBefore)
        XCTAssertEqual(h.lastRun, lastRunBefore)
        XCTAssertTrue(UniStubProtocol.requests.isEmpty, UniStubProtocol.requests.map(\.url.absoluteString).joined(separator: ", "))
        XCTAssertEqual(h.learnweb, .notConnected)
        XCTAssertEqual(h.lsf, .notConnected)
        XCTAssertNil(c.tokens.token(.hildesheim, service: "learnweb"))
    }

    // MARK: 363/372 Hochschulwechsel waehrend des Learnweb-Downloads

    func testSwitchingUniversityDuringALearnwebDownloadKeepsFilesInTheirContainer() async throws {
        let m = manager()
        let a = account(.hildesheim)
        let (hi, h) = try await connectedHildesheim(m, a, lsfToo: false)
        let gate = StubGate()
        try installUni(gate: gate)
        let run = Task { await h.run() }
        try await waitUntil("Download laeuft") { gate.wasReached }
        a.chooseUniversity(.luh)
        let luh = try open(m, a)
        XCTAssertNotEqual(luh.layout.root, hi.layout.root)
        gate.release()
        let runReport = await run.value
        let report = try XCTUnwrap(runReport)
        XCTAssertEqual(report.newFiles.count, 2)
        let inHi = try await learnwebFiles(hi)
        XCTAssertEqual(inHi, 2, "Dateien im Container der Uni Hildesheim")
        let inLUH = try await learnwebFiles(luh)
        XCTAssertEqual(inLUH, 0, "nichts im LUH-Container")
        XCTAssertFalse(FileManager.default.fileExists(atPath: luh.layout.learnweb.path), "kein Learnweb-Ordner bei der LUH")
        let luhLibrary = try await luh.api.value("/api/library").jsonString()
        XCTAssertFalse(luhLibrary.contains("plan.pdf"))
    }

    // MARK: 366 LSF geht, Learnweb nicht

    func testLearnwebFailingWhileLSFWorksKeepsTheFilesAndShowsBoth() async throws {
        let m = manager()
        let (c, h) = try await connectedHildesheim(m, account(.hildesheim))
        try installUni()
        let okReport = await h.run()
        let ok = try XCTUnwrap(okReport)
        XCTAssertTrue(ok.ok, ok.messages.joined(separator: "; "))
        let before = try await learnwebFiles(c)
        XCTAssertEqual(before, 2)
        try installUni(learnwebFails: true)
        _ = await h.run(forceGrades: true)
        guard case .failed = h.learnweb else { return XCTFail("Learnweb: \(h.learnweb)") }
        XCTAssertEqual(h.lsf, .ok(clock.now), "Teilerfolg sichtbar")
        let after = try await learnwebFiles(c)
        XCTAssertEqual(after, 2, "Kursunterlagen bleiben")
        XCTAssertTrue(h.messages.contains { $0.hasPrefix("Learnweb") }, h.messages.joined(separator: "; "))
        XCTAssertEqual(HildesheimConnection.statusText(.learnweb, h.learnweb), "Learnweb: Fehler")
    }

    // MARK: 367 unterbrochene Anmeldung

    nonisolated private static func learnwebConfig(base: String) -> UniStubProtocol.Reply {
        let data: JSONValue = ["sitename": "Learnweb SoSe 2026 - WiSe 2026/27", "wwwroot": .string(base), "httpswwwroot": .string(base),
                               "launchurl": .string(base + "/admin/tool/mobile/launch.php"), "enablemobilewebservice": 1,
                               "typeoflogin": 1, "identityproviders": [["name": "CAS"]]]
        return UniStubProtocol.Reply(status: 200, headers: ["Content-Type": "application/json"],
                                     body: JSONValue.array([["error": false, "data": data]]).serialized())
    }

    func testFailedOrInterruptedLoginCanStartAgainWithoutRestart() async throws {
        let m = manager()
        _ = try open(m, account(.hildesheim))
        let h = try XCTUnwrap(m.hildesheim)
        UniStubProtocol.install { _ in .text("", status: 503) }              // Learnweb nicht erreichbar
        let login = HildesheimLogin(target: .learnweb, connection: h)
        await login.prepare()
        guard case .failed(let message) = login.stage else { return XCTFail("\(login.stage)") }
        XCTAssertTrue(message.contains("erneut"), message)
        // wieder erreichbar: dieselbe Anmeldung startet neu ("Erneut versuchen"), ohne App-Neustart
        let lw = self.lw
        UniStubProtocol.install { r in r.url.absoluteString.hasPrefix(lw + "/lib/ajax/service-nologin.php") ? Self.learnwebConfig(base: lw) : .text("", status: 404) }
        await login.prepare()
        guard case .page = login.stage else { return XCTFail("\(login.stage)") }
        // CAS meldet einen Fehler, danach klappt es auf derselben Seite
        let lsfLogin = HildesheimLogin(target: .lsf, connection: h)
        await lsfLogin.prepare()
        lsfLogin.pageLoaded(url: URL(string: "https://www.uni-hildesheim.de/sso/login?service=x"), html: #"<div id="loginErrorsPanel">Ungültige Anmeldedaten</div>"#)
        XCTAssertEqual(lsfLogin.casError, "Ungültige Anmeldedaten")
        lsfLogin.pageLoaded(url: URL(string: lsf + "/qisserver/rds?state=user&type=0"), html: #"<a href="x">Abmelden</a>"#)
        XCTAssertEqual(lsfLogin.stage, .done)
        XCTAssertNil(lsfLogin.casError)
        XCTAssertTrue(h.lsfConnected)
    }

    // MARK: 369/370 unterbrochenes Abmelden, keine alte Sitzung

    func testInterruptedSignOutIsFinishedBeforeTheNextLoginAndOnNextStart() async throws {
        let m = manager()
        let a = account(.hildesheim)
        let (c, h) = try await connectedHildesheim(m, a)
        let store = m.websiteDataStore(for: c)
        await store.httpCookieStore.setCookie(cookie("TGC", "alte-cas-sitzung", domain: "www.uni-hildesheim.de"))
        // wie nach einem Ende der App mitten im Abmelden: Merker steht, Schluessel und Cookies noch da
        c.defaults.set(true, forKey: HildesheimConnection.Keys.signOutPending)
        for k in [HildesheimConnection.Keys.learnwebMode, HildesheimConnection.Keys.lsfConnected] { c.defaults.removeObject(forKey: k) }
        XCTAssertNotNil(c.tokens.token(.hildesheim, service: "learnweb"))

        // naechste Anmeldung: vor der Anmeldeseite ist die alte Sitzung weg
        UniStubProtocol.install { _ in .text("", status: 404) }
        let login = HildesheimLogin(target: .lsf, connection: h)
        await login.prepare()
        let cookies = await store.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.isEmpty, "keine alte Sitzung fuer die neue Anmeldung: \(cookies.map(\.name))")
        XCTAssertNil(c.tokens.token(.hildesheim, service: "learnweb"))
        XCTAssertFalse(c.defaults.bool(forKey: HildesheimConnection.Keys.signOutPending))

        // naechster Start mit stehendem Merker: die neue Verbindung raeumt von selbst auf
        await store.httpCookieStore.setCookie(cookie("TGC", "noch-eine", domain: "www.uni-hildesheim.de"))
        c.defaults.set(true, forKey: HildesheimConnection.Keys.signOutPending)
        let restarted = manager()
        let c2 = try open(restarted, a)
        XCTAssertEqual(c2.layout.root, c.layout.root)
        try await waitUntil("Abmelden nachgeholt") { !c2.defaults.bool(forKey: HildesheimConnection.Keys.signOutPending) }
        let left = await restarted.websiteDataStore(for: c2).httpCookieStore.allCookies()
        XCTAssertTrue(left.isEmpty)
    }

    // MARK: 373 Loeschfehler sichtbar

    func testFailedDeletionIsReportedInsteadOfClaimingSuccess() async throws {
        let m = manager()
        let a = account(.luh)
        let c = try open(m, a)
        try Data("Notiz".utf8).write(to: c.layout.root.appendingPathComponent("probe.txt"))
        // Ordner der Container schreibgeschuetzt: der Container laesst sich nicht wegbewegen
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: containers.path)
        let problem = await m.deleteUniversityData(c.key)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: containers.path)
        let text = try XCTUnwrap(problem, "Fehler muss gemeldet werden")
        XCTAssertTrue(text.contains(ContainerManager.leftFiles), text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.layout.root.appendingPathComponent("probe.txt").path), "es ist wirklich noch da")
        // danach gelingt es und meldet nichts
        let second = await m.deleteUniversityData(c.key)
        XCTAssertNil(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.layout.root.appendingPathComponent("probe.txt").path))

        // Learnweb-Schluessel laesst sich nicht entfernen: gesagt, nicht verschwiegen
        let stuck = StuckSecrets()
        let m2 = manager(keychain: stuck)
        let (hi, _) = try await connectedHildesheim(m2, account(.hildesheim), lsfToo: false)
        let keyProblem = await m2.deleteUniversityData(hi.key)
        XCTAssertTrue(keyProblem?.contains(ContainerManager.leftKey) == true, keyProblem ?? "-")
        XCTAssertEqual(ContainerManager.deletionProblem([]), nil)
    }

    // MARK: 374 spaete Schreibzugriffe nach dem Loeschen

    /// 374, Luecke beim Start: "Daten dieser Hochschule loeschen", waehrend ein Lauf noch die Demo-Pruefung abwartet
    /// (noch ohne laufende Aufgabe, `stop` findet nichts zum Anhalten). Die Sperre wird nach der Pruefung erneut gelesen:
    /// der Lauf beginnt nicht, fragt niemanden, und im neu geoeffneten Container entsteht nichts.
    func testDeletingWhileARunIsStillStartingStartsNothing() async throws {
        let m = manager()
        let c = try open(m, account(.luh))
        try c.cookies.save([cookie("Seminar_Session", "sitzung-test", domain: "studip.uni-hannover.de")])
        let stud = WaitingStudIP()
        let sync = m.studip
        let run = Task { await sync.run(client: StudIPClient(base: StudIPSync.base, transport: stud, pauseMillis: 0)) }
        await Task.yield()                                   // der Lauf wartet jetzt in der Demo-Pruefung
        XCTAssertFalse(sync.isRunning)
        let problem = await m.deleteUniversityData(c.key)
        XCTAssertNil(problem)
        stud.gate.release()
        let end = await run.value
        XCTAssertNil(end, "nach dem Loeschen beginnt der Lauf nicht mehr")
        XCTAssertEqual(stud.requests, 0)
        XCTAssertTrue(sync.stopped)
        let fresh = try XCTUnwrap(m.active)
        XCTAssertEqual(fresh.layout.root, c.layout.root, "derselbe Container, neu und leer")
        let downloads = DataContainerLayout.Folder.studip.url(in: fresh.layout.root).appendingPathComponent("files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.path), "keine Downloads im neuen Container")
        let library = try await fresh.api.value("/api/library").jsonString()
        XCTAssertFalse(library.contains("Blatt 3"), "nichts aus dem alten Lauf im neuen Container")
    }

    /// Ein Dokument sichert nach "Daten dieser Hochschule loeschen" noch (Schliessen, Upload): es schreibt nichts mehr,
    /// weder in den geloeschten noch in den leer neu geoeffneten Container mit derselben Kennung
    func testDocumentStillSavingAfterDeletionWritesNothingIntoTheNewContainer() async throws {
        let m = manager()
        let c = try open(m, account(.luh))
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { ctx in ctx.beginPage() }
        let created = try await c.api.upload("/api/notebooks", fields: ["kind": "pdf", "title": "Skript"], fileField: "upload",
                                             fileName: "skript.pdf", mimeType: "application/pdf", data: pdf)
        let id = try XCTUnwrap(created["id"]?.string)
        let lib = try await c.api.json("/api/library", as: LibraryResponse.self)
        let file = try XCTUnwrap(lib.files.first { $0.id == id })
        let store = DocumentStore(file: file, api: c.api, root: c.layout.root, lease: c.lease)
        await store.load()
        XCTAssertNil(store.errorMessage)
        store.canvasChanged(pageKey: "p1", drawing: stroke(y: 50))
        await store.flush()
        XCTAssertNotNil(try LocalJournal(store: FileBlobStore(root: c.layout.journal), documentID: id, namespace: .local).load())

        await m.deleteUniversityData(c.key)
        XCTAssertFalse(c.lease.isValid)
        let fresh = try XCTUnwrap(m.active)
        XCTAssertEqual(fresh.layout.root, c.layout.root, "gleiche Kennung, leer neu angelegt")
        XCTAssertTrue(fresh.lease.isValid)
        // das alte Dokument rechnet noch einen Strich um und laedt hoch (spaete Umrechnung, Schliessen)
        store.canvasChanged(pageKey: "p1", drawing: stroke(y: 50, extra: true))
        await store.flush()
        await store.close()
        XCTAssertNil(try LocalJournal(store: FileBlobStore(root: fresh.layout.journal), documentID: id, namespace: .local).load(),
                     "keine Notizen des geloeschten Containers im neuen")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.layout.journal.path))
    }

    private func stroke(y: CGFloat, extra: Bool = false) -> PKDrawing {
        func one(_ y: CGFloat, _ t: Double) -> PKStroke {
            let pts = (0..<10).map { i in
                PKStrokePoint(location: CGPoint(x: 20 + CGFloat(i) * 8, y: y), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSinceReferenceDate: t)))
        }
        return PKDrawing(strokes: [one(y, 800_000_000)] + (extra ? [one(y + 30, 800_000_100)] : []))
    }

    // MARK: 375 mehrfaches Wechseln

    func testRepeatedSwitchTapsOpenEachContainerOnceAndNeverMix() async throws {
        let m = manager()
        let a = account(.luh)
        let luh = try open(m, a)
        _ = try await luh.api.value("/api/settings", method: "PUT", body: ["user_name": "Nur-LUH"])
        let g0 = m.generation
        // doppelt getippt: derselbe Wechsel zweimal hintereinander
        a.chooseUniversity(.hildesheim)
        m.sync(account: a)
        let hi = try XCTUnwrap(m.active)
        a.chooseUniversity(.hildesheim)
        m.sync(account: a)
        XCTAssertTrue(m.active === hi, "zweiter Aufruf oeffnet nichts neu")
        XCTAssertEqual(m.generation, g0 + 1)
        // schnell hin und her
        for uni in [UniversityKey.luh, .hildesheim, .luh, .luh] {
            a.chooseUniversity(uni)
            m.sync(account: a)
        }
        XCTAssertEqual(m.generation, g0 + 4)
        let last = try XCTUnwrap(m.active)
        websiteStores.append(last.websiteDataStoreID)
        XCTAssertEqual(last.key.university, .luh)
        XCTAssertEqual(last.layout.root, luh.layout.root)
        let s = try await last.api.value("/api/settings")
        XCTAssertEqual(s["user_name"]?.string, "Nur-LUH")
        let hiSettings = try await hi.api.value("/api/settings")
        XCTAssertEqual(hiSettings["user_name"]?.string, "", "nichts gemischt")
        XCTAssertNil(m.hildesheim)
    }

    // MARK: 333 nicht darstellbare Striche im Editor

    func testEditorSaysWhenStrokesCannotBeShownAndKeepsThem() async throws {
        let m = manager()
        let c = try open(m, account(.luh))
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { ctx in ctx.beginPage() }
        let created = try await c.api.upload("/api/notebooks", fields: ["kind": "pdf", "title": "Skript"], fileField: "upload",
                                             fileName: "skript.pdf", mimeType: "application/pdf", data: pdf)
        let id = try XCTUnwrap(created["id"]?.string)
        var doc = AnnotationDocument.empty()
        doc.ensurePDFPages(count: 1)
        let broken: [JSONValue] = [["id": "kaputt1", "type": "stroke", "points": [1, 1]],
                                   ["id": "kaputt2", "type": "stroke", "points": [0, 0, 1e300, 1e300]]]
        doc.pages["p1"] = .object(["objects": .array(broken + [["id": "gut", "type": "stroke", "tool": "pen", "color": "#000000",
                                                              "width": 2, "opacity": 1, "points": [10, 10, 60, 60]]])])
        _ = try await HTTPAnnotationTransport(api: c.api).put(documentID: id, root: doc.root, baseVersion: 0)
        let lib = try await c.api.json("/api/library", as: LibraryResponse.self)
        let store = DocumentStore(file: try XCTUnwrap(lib.files.first { $0.id == id }), api: c.api, root: c.layout.root, lease: c.lease)
        await store.load()
        let drawing = await store.drawing(forPageKey: "p1")
        XCTAssertEqual(drawing.strokes.count, 1)
        XCTAssertEqual(store.inkNotice, "2 Striche lassen sich hier nicht anzeigen – sie bleiben unverändert gespeichert.")
        var next = drawing
        next.strokes.append(stroke(y: 200).strokes[0])
        store.canvasChanged(pageKey: "p1", drawing: next)
        await store.close()                                                   // sichert und laedt hoch
        let saved = try await c.api.value("/api/files/\(id)/annotations")
        let ids = (saved["data"]?["pages"]?["p1"]?["objects"]?.array ?? []).compactMap { $0["id"]?.string }
        XCTAssertTrue(ids.contains("kaputt1") && ids.contains("kaputt2"), "\(ids)")
        XCTAssertEqual(ids.count, 4)
    }

    // MARK: 346 nicht lesbares Journal im Editor

    func testUnreadableJournalOpensViewOnlyAndKeepsItsFiles() async throws {
        let m = manager()
        let c = try open(m, account(.luh))
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { ctx in ctx.beginPage() }
        let created = try await c.api.upload("/api/notebooks", fields: ["kind": "pdf", "title": "Skript"], fileField: "upload",
                                             fileName: "skript.pdf", mimeType: "application/pdf", data: pdf)
        let id = try XCTUnwrap(created["id"]?.string)
        let lib = try await c.api.json("/api/library", as: LibraryResponse.self)
        let file = try XCTUnwrap(lib.files.first { $0.id == id })
        let first = DocumentStore(file: file, api: c.api, root: c.layout.root, lease: c.lease)
        await first.load()
        first.canvasChanged(pageKey: "p1", drawing: stroke(y: 40))
        await first.flush()
        await first.close()
        let pages = c.layout.journal.appendingPathComponent(LocalJournal.directory(documentID: id, namespace: .local) + "/pages")
        let before = try FileManager.default.contentsOfDirectory(atPath: pages.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: pages.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pages.path) }

        let store = DocumentStore(file: file, api: c.api, root: c.layout.root, lease: c.lease)
        await store.load()
        XCTAssertTrue(store.journalUnreadable)
        XCTAssertFalse(store.isWritable, "nur ansehen")
        XCTAssertTrue(store.notice?.contains("erneut") == true, store.notice ?? "-")
        guard case .localSaveFailed = store.status else { return XCTFail("\(store.status)") }
        store.canvasChanged(pageKey: "p1", drawing: stroke(y: 40, extra: true))
        await store.flush()
        await store.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pages.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pages.path), before, "Journal unberuehrt")
        let reopened = DocumentStore(file: file, api: c.api, root: c.layout.root, lease: c.lease)
        await reopened.load()
        XCTAssertFalse(reopened.journalUnreadable)
        XCTAssertTrue(reopened.isWritable)
        await reopened.close()
    }

    // MARK: 358 betroffene Seiten

    func testConflictNoticeNamesTheAffectedPages() {
        XCTAssertEqual(SyncIssueBadge.text(.konflikteZusammengefuehrt(1), pages: [3]), "1 Konflikt zusammengeführt – Seite 3")
        XCTAssertEqual(SyncIssueBadge.text(.konflikteZusammengefuehrt(3), pages: [2, 5]), "3 Konflikte zusammengeführt – Seiten 2, 5")
        XCTAssertEqual(SyncIssueBadge.text(.konflikteZusammengefuehrt(2), pages: []), "2 Konflikte zusammengeführt")
        XCTAssertEqual(SyncIssueBadge.text(.offline, pages: [1]), SyncIssue.offline.label)
        XCTAssertEqual(SyncIssueBadge.text(.konflikteZusammengefuehrt(9), pages: Array(1...9)), "9 Konflikte zusammengeführt – Seiten 1, 2, 3, 4, 5, 6 …")
    }

    // MARK: 376-379 Diagnose

    func testDiagnosisReportsUnreadableFoldersAndContainsNoSecretsOrNotes() async throws {
        let journal = appSupport.appendingPathComponent("journal", isDirectory: true)
        let cache = appSupport.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = FileBlobStore(root: journal)
        for id in ["lesbar", "gesperrt"] {
            let j = LocalJournal(store: store, documentID: id, namespace: .local)
            try j.writePage("p1", JournalPage(page: ["objects": [["id": "t", "type": "text", "text": "GEHEIME NOTIZ"]]], localRev: 1))
            try j.writeMeta(rootMeta: ["pageOrder": []], metaRev: 0, baseRootMeta: nil)
        }
        let locked = journal.appendingPathComponent(LocalJournal.directory(documentID: "gesperrt", namespace: .local) + "/pages")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let d = Diagnostics.collect(journal: journal, cache: cache, appVersion: "1.0 (1)", osVersion: "26.0")
        XCTAssertEqual(d.unreadable, ["local/gesperrt"], "nicht still uebersprungen")
        XCTAssertEqual(d.unsentPages, 1)
        let report = d.reportLines.joined(separator: "\n")
        XCTAssertTrue(report.contains("Nicht lesbare lokale Ordner: local/gesperrt"), report)
        XCTAssertTrue(report.contains("Momentaufnahme"), report)
        XCTAssertFalse(report.contains("GEHEIME NOTIZ"), "keine Inhalte")
        // Adresse ohne Zugangsdaten, Pfad oder Abfrage
        XCTAssertEqual(Diagnostics.address(URL(string: "https://nutzer:passwort@uniflow.example:8443/pfad?pin=1234")),
                       "https://uniflow.example:8443")
        XCTAssertEqual(Diagnostics.address(APIClient.localBase), "uniflow-local://device")
        XCTAssertEqual(Diagnostics.address(nil), "–")
    }

    /// Stud.IP mit festen Antworten (ein Kurs, eine Datei, erfunden); der Download wartet, bis der Test ihn freigibt
    private final class WaitingStudIP: StudIPTransport, @unchecked Sendable {
        let gate = StubGate()
        private let lock = NSLock()
        private var count = 0
        /// Zahl der Anfragen (Listen und Downloads)
        var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
        private func counted() { lock.lock(); count += 1; lock.unlock() }

        func get(_ url: URL, accept: String?) async throws -> HTTPReply {
            counted()
            let path = (url.path + (url.query.map { "?" + $0 } ?? ""))
                .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
            let json: String
            switch path {
            case "/jsonapi.php/v1/users/me": json = #"{"data":{"id":"u1","type":"users"}}"#
            case "/jsonapi.php/v1/users/u1/courses?page[limit]=100&include=start-semester":
                json = #"""
                    {"data":[{"id":"c1","type":"courses","attributes":{"title":"Testkurs Numerik","course-number":"T-42"},
                      "relationships":{"start-semester":{"data":{"type":"semesters","id":"s1"}}}}],
                     "included":[{"id":"s1","type":"semesters","attributes":{"title":"WiSe 2026/27","start":"2026-10-01T00:00:00+02:00"}}]}
                    """#
            case "/jsonapi.php/v1/courses/c1/folders?page[limit]=200": json = #"{"data":[{"id":"r1","attributes":{"folder-type":"RootFolder","name":""}}]}"#
            case "/jsonapi.php/v1/folders/r1/file-refs?page[limit]=500":
                json = #"{"data":[{"id":"d1","attributes":{"name":"Blatt 3.pdf","filesize":12,"mime-type":"application/pdf","chdate":"2026-10-19T10:00:00+02:00","is-downloadable":true}}]}"#
            case "/jsonapi.php/v1/folders/r1/folders?page[limit]=200": json = #"{"data":[]}"#
            default: return HTTPReply(status: 404, contentType: "application/vnd.api+json", body: Data(#"{"errors":[]}"#.utf8))
            }
            return HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(json.utf8))
        }

        func download(_ url: URL, to file: URL) async throws -> HTTPReply {
            counted()
            let gate = self.gate
            await Task.detached { gate.pass() }.value
            try Task.checkCancellation()
            try Data("%PDF-1.7 LUH".utf8).write(to: file)
            return HTTPReply(status: 200, contentType: "application/pdf")
        }
    }
}
