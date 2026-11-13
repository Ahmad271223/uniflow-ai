import Security
import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// QIS im In-App-Browser (Meldung des Inhabers 13.11.2026): "Im QIS anmelden" mal angemeldet, mal abgemeldet; ueber ein
/// Modul ins QIS, danach ging nur dieses eine Modul. Ursache: Waehrend der Browser das QIS zeigte, las die App in
/// derselben Sitzung (Abruf beim Zurueckkehren in die App, Abgleich aller Portale) und meldete sich bei "abgelaufen" still
/// neu an; das neue Sitzungs-Cookie im gemeinsamen Datenspeicher machte die Seite im Browser ungueltig. Vor dem Oeffnen
/// wurde die Sitzung nie geprueft, und der Browser kannte weder die Autofill-Kennzeichnung noch das Merken des Passworts.
/// Dazu der Weg zum Modul (`QISRegistrationGuideRunner`). Erfundene Seiten und Zugangsdaten, kein Netz.
@MainActor
final class QISAnmeldungAppTests: XCTestCase {
    private let user = "testnutzer-erfunden"
    private let password = "Pw-Test-erfunden-123"
    private let host = "qis.verwaltung.uni-hannover.de"
    private var bed: ContainerTestBed!
    private var services: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "qis-anmeldung", clock: .fixed(berlin: "2026-11-13T10:00:00")!)
    }

    override func tearDown() async throws {
        UniAutoLogin.runnerOverride = nil
        UniAutoLogin.appActiveOverride = nil
        for s in services { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary) }
        services = []
        await bed.tearDown()
        try await super.tearDown()
    }

    private func luh() throws -> (ContainerManager, ActiveContainer, QISConnection) {
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        services.append(m.credentialService)
        let q = try XCTUnwrap(m.qis)
        q.syncsAfterSignIn = false
        return (m, c, q)
    }

    private func installQIS(loggedIn: Bool) {
        let login = #"<html><body><form action="x" method="post"><input name="asdf"><input type="password" name="fdsa"></form></body></html>"#
        UniStubProtocol.install { r in
            guard loggedIn, r.cookie.contains("JSESSIONID=qis-sitzung-test") else { return .text(login) }
            let reply = DebugStubTransport(directory: ContainerTestBed.stubDirectory).reply(r.url, body: r.body)
            return UniStubProtocol.Reply(status: reply.status, headers: reply.headers, body: reply.body)
        }
    }

    static func fixture(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/exam-registration/\(name)"), encoding: .utf8)
    }

    func testOpenBrowserKeepsTheAppOutOfTheQISSession() async throws {
        let (m, c, q) = try luh()
        installQIS(loggedIn: true)
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(bed.cookie("JSESSIONID", "qis-sitzung-test", domain: host))
        q.signedIn()
        q.beginBrowser()
        XCTAssertTrue(q.browserOpen)
        let before = UniStubProtocol.requests.count
        let run = await q.run(force: true)
        XCTAssertNil(run, "kein Abruf in derselben Sitzung, solange der Browser offen ist")
        let regs = await q.fetchRegistrations()
        XCTAssertNil(regs)
        let bg = await q.backgroundCheck()
        XCTAssertNil(bg)
        XCTAssertEqual(UniStubProtocol.requests.count, before)
        // abgelaufen: keine stille Neuanmeldung (neues Cookie im gemeinsamen Datenspeicher)
        try UniCredentialStore(service: m.credentialService, container: c.layout.identifier)
            .save(UniCredential(username: user, password: password, savedAt: Date()))
        UniAutoLogin.appActiveOverride = true
        var attempts = 0
        UniAutoLogin.runnerOverride = { _ in attempts += 1; return .success }
        q.certificatesExpired()
        let auto = await q.autoLogin(userAction: true)
        XCTAssertFalse(auto)
        let bgLogin = await q.reloginInBackground()
        XCTAssertFalse(bgLogin)
        XCTAssertEqual(attempts, 0)
        // geschlossen: wieder wie vorher
        q.endBrowser()
        XCTAssertFalse(q.browserOpen)
        let again = await q.autoLogin(userAction: true)
        XCTAssertTrue(again)
        XCTAssertEqual(attempts, 1)
    }

    func testBrowserSessionIsCheckedAndRenewedBeforeLoading() async throws {
        let (m, c, q) = try luh()
        try UniCredentialStore(service: m.credentialService, container: c.layout.identifier)
            .save(UniCredential(username: user, password: password, savedAt: Date()))
        UniAutoLogin.appActiveOverride = true
        var attempts = 0
        UniAutoLogin.runnerOverride = { r in attempts += 1; XCTAssertEqual(r.entry, QISClient.startURL); return .success }
        q.signedIn()
        q.beginBrowser()
        // Sitzung traegt: nichts tun
        let alive = await q.prepareBrowserSession { _ in true }
        XCTAssertTrue(alive)
        XCTAssertEqual(attempts, 0)
        // Netz unklar: nichts tun
        let unknown = await q.prepareBrowserSession { _ in nil }
        XCTAssertFalse(unknown)
        XCTAssertEqual(attempts, 0)
        // abgelaufen: still erneuern, dann ist der Browser angemeldet (vorher: Anmeldeseite)
        let renewed = await q.prepareBrowserSession { _ in false }
        XCTAssertTrue(renewed)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(q.state, .connected)
        XCTAssertTrue(q.browserOpen, "der Browser bleibt der einzige Nutzer der Sitzung")
        // bewusst abgemeldet: nie still verbinden
        q.endBrowser()
        await q.signOut()
        let out = await q.prepareBrowserSession { _ in false }
        XCTAssertFalse(out)
        XCTAssertEqual(attempts, 1)
    }

    func testSessionProbeReadsTheStartPage() async throws {
        let (m, c, q) = try luh()
        _ = q
        let store = m.websiteDataStore(for: c)
        await store.httpCookieStore.setCookie(bed.cookie("JSESSIONID", "qis-sitzung-test", domain: host))
        let transport = await URLSessionUniTransport.make(dataStore: store, allowedDomains: QISConnection.qisDomains,
                                                          configuration: UniStubProtocol.configuration())
        installQIS(loggedIn: true)
        let yes = await QISConnection.sessionAlive(transport)
        XCTAssertEqual(yes, true)
        installQIS(loggedIn: false)
        let no = await QISConnection.sessionAlive(transport)
        XCTAssertEqual(no, false)
    }

    func testBrowserSignInConnectsWithoutFetching() async throws {
        let (_, _, q) = try luh()
        XCTAssertFalse(q.isConnected)
        q.beginBrowser()
        q.browserSignedIn()
        XCTAssertTrue(q.isConnected)
        XCTAssertEqual(q.state, .connected)
        XCTAssertFalse(q.isRunning, "kein Abruf, solange der Browser offen ist")
        q.endBrowser()
    }

    func testInAppBrowserMarksQISFieldsForPasswordAutofill() throws {
        let (m, c, q) = try luh()
        let page = UniWebPage(dataStore: m.websiteDataStore(for: c), university: .luh, qis: q)
        let scripts = page.webView.configuration.userContentController.userScripts.map(\.source)
        XCTAssertTrue(scripts.contains { $0.contains("current-password") && $0.contains("fdsa") }, "Autofill-Kennzeichnung im Browser")
        XCTAssertTrue(UniWebPage.isQIS(URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/x")!))
        XCTAssertFalse(UniWebPage.isQIS(URL(string: "http://qis.verwaltung.uni-hannover.de/qisserver/x")!))
        XCTAssertFalse(UniWebPage.isQIS(URL(string: "https://studip.uni-hannover.de/")!))
    }

    func testGuideRequestOnlyForTheTappedAddressAndOnlyBriefly() {
        let url = URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/x?state=change&moduleParameter=studyPOSMenu")!
        let t = [QISRegistrationTarget(title: "Thermodynamik I / Chemie"), QISRegistrationTarget(title: "Technische Mechanik III")]
        let now = Date()
        QISGuideRequests.set(url: url, targets: t, first: 1, now: now)
        XCTAssertNil(QISGuideRequests.take(for: URL(string: "https://qis.verwaltung.uni-hannover.de/other")!, now: now))
        XCTAssertNil(QISGuideRequests.take(for: url, now: now), "einmal abgeholt bzw. verworfen")
        QISGuideRequests.set(url: url, targets: t, first: 1, now: now)
        XCTAssertNil(QISGuideRequests.take(for: url, now: now.addingTimeInterval(30)), "spaeter geoeffnete QIS-Links ohne Suche")
        QISGuideRequests.set(url: url, targets: t, first: 1, now: now)
        let r = QISGuideRequests.take(for: url, now: now.addingTimeInterval(1))
        XCTAssertEqual(r?.targets, t)
        XCTAssertEqual(r?.first, 1)
        QISGuideRequests.set(url: url, targets: [], now: now)
        XCTAssertNil(QISGuideRequests.take(for: url, now: now))
    }

    func testModuleButtonSearchesThatModuleFirstThenTheOtherOpenOnes() throws {
        let v: JSONValue = ["supported": true, "system": "QIS", "suggestions": [
            ["id": "tm3", "title": "Technische Mechanik III", "registered": false, "code": .null],
            ["id": "sg", "title": "Tutorien oder Studium Generale", "registered": true],
            ["id": "th", "title": "Thermodynamik I / Chemie", "registered": false, "code": "1300"],
        ]]
        let st = ExamRegistrationState(v)
        XCTAssertEqual(st.guideTargets().map(\.title), ["Technische Mechanik III", "Thermodynamik I / Chemie"], "nur offene")
        let th = try XCTUnwrap(st.suggestions.first { $0.id == "th" })
        XCTAssertEqual(st.guideTargets(first: th), [QISRegistrationTarget(title: "Thermodynamik I / Chemie", nr: "1300"),
                                                   QISRegistrationTarget(title: "Technische Mechanik III")])
        var lsf = v
        lsf["system"] = "LSF"
        XCTAssertTrue(ExamRegistrationState(lsf).guideTargets().isEmpty, "LSF: Startseite wie bisher")
    }

    func testRunnerWaitsForTheHumanAndStopsWhenTheHumanNavigates() throws {
        let entry = URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=change&type=1&moduleParameter=studyPOSMenu&next=menu.vm")!
        let g = QISRegistrationGuideRunner(targets: [QISRegistrationTarget(title: "Thermodynamik I / Chemie")], entry: entry)
        var loads: [URL] = []
        g.loader = { loads.append($0) }
        g.start()
        XCTAssertEqual(loads, [entry], "frisch ab Mein Studium")
        // abgelaufen: Anmeldeseite, der Mensch tippt das Passwort (Formular) - die Suche wartet und geht danach weiter
        g.pageFinished(url: entry, html: #"<form><input name="asdf"><input type="password" name="fdsa"></form>"#)
        XCTAssertEqual(g.status, .login)
        g.navigation(.formSubmitted)
        XCTAssertEqual(g.status, .login)
        g.pageFinished(url: entry, html: try Self.fixture("qis-echt-studium.html"))
        XCTAssertEqual(g.status, .searching)
        let next = try XCTUnwrap(loads.last)
        XCTAssertTrue(next.absoluteString.contains("state=info") && next.absoluteString.contains("prfAnmStudent"),
                      "Menuepunkt Prüfungsanmeldung/-abmeldung (Hinweise)")
        // der Mensch tippt selbst einen Link: Suche haelt an, spaetere Seiten aendern nichts
        g.navigation(.linkActivated)
        XCTAssertEqual(g.status, .paused)
        let count = loads.count
        g.pageFinished(url: next, html: try Self.fixture("qis-anm-hinweise-link.html"))
        XCTAssertEqual(loads.count, count)
        // "Neu suchen": wieder frisch ab Mein Studium
        g.start()
        XCTAssertEqual(loads.last, entry)
        XCTAssertEqual(g.status, .searching)
        XCTAssertTrue(QISRegistrationGuideRunner.text(.found("1300 Thermodynamik I"), title: "x").contains("selbst"))
    }
}
