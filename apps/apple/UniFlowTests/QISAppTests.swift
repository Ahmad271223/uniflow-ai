import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Noten aus dem QIS der LUH in der App (`QISConnection`, Views/QISViews.swift): Anmeldung erkannt, Abruf mit den
/// Cookies der Webansicht des Containers ueber den Stub (kein Netz), Leistungen in Uni & Noten, leer ist kein Fehler,
/// abgelaufene Sitzung bietet die Anmeldung an, Stammdaten und asi nie gespeichert, hoechstens alle 20 Stunden von
/// selbst, Abmelden raeumt nur das QIS. Erfundene Seiten (Person "Erika Beispiel", Sitzung "StubSitzung01").
@MainActor
final class QISAppTests: XCTestCase {
    private var bed: ContainerTestBed!
    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T10:00:00")!
    private let host = "qis.verwaltung.uni-hannover.de"

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "qis", clock: clock)
    }

    override func tearDown() async throws {
        await bed.tearDown()
        try await super.tearDown()
    }

    /// QIS aus dem Debug-Stub-Ordner, nur mit dem Sitzungs-Cookie aus der Webansicht; `list` ersetzt die Leistungsseite
    private func installQIS(list: String? = nil, loggedIn: Bool = true) {
        let dir = ContainerTestBed.stubDirectory
        let login = """
            <html><body><h1>Anmeldung</h1><form action="x" method="post"><input type="text" name="asdf">
            <input type="password" name="fdsa"><input type="submit" value="Anmelden"></form></body></html>
            """
        UniStubProtocol.install { r in
            guard loggedIn, r.cookie.contains("JSESSIONID=qis-sitzung-test") else { return .text(login) }
            if let list, r.url.absoluteString.contains("next=list.vm") { return .text(list) }
            let reply = DebugStubTransport(directory: dir).reply(r.url, body: r.body)
            return UniStubProtocol.Reply(status: reply.status, headers: reply.headers, body: reply.body)
        }
    }

    private func luh() throws -> (ContainerManager, ActiveContainer, QISConnection) {
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        let q = try XCTUnwrap(m.qis, "QIS-Verbindung des LUH-Containers")
        q.syncsAfterSignIn = false
        return (m, c, q)
    }

    private func signIn(_ m: ContainerManager, _ c: ActiveContainer, _ q: QISConnection) async {
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(bed.cookie("JSESSIONID", "qis-sitzung-test", domain: host))
        q.signedIn()
    }

    func testGradesArriveInUniUndNotenWithoutStammdatenOrASI() async throws {
        let (m, c, q) = try luh()
        XCTAssertEqual(q.state, .notConnected)
        XCTAssertTrue(q.needsAttention)
        let none = await q.run(force: true)
        XCTAssertNil(none, "ohne Verbindung kein Abruf")
        installQIS()
        await signIn(m, c, q)
        XCTAssertEqual(q.state, .connected)
        XCTAssertFalse(q.needsAttention)
        let runs = q.finishedRuns
        let ran = await q.run(force: true)
        let r = try XCTUnwrap(ran)
        XCTAssertEqual(r.grades, 3, r.message)
        XCTAssertEqual(q.state, .ok(clock.now))
        XCTAssertEqual(q.lastCount, 3)
        XCTAssertEqual(q.lastMessage, "3 Leistungen")
        XCTAssertEqual(q.finishedRuns, runs + 1, "Seiten laden danach neu")
        XCTAssertEqual(QISConnection.statusText(q.state, now: clock.now), "QIS: 10:00 ok")

        // Netz: nur das QIS, nur mit seiner Sitzung, nie eine Bescheinigung, nie abmelden
        let seen = UniStubProtocol.requests
        XCTAssertTrue(seen.allSatisfy { $0.url.host == host }, "\(seen.map(\.url))")
        XCTAssertTrue(seen.allSatisfy { $0.cookie.contains("JSESSIONID=qis-sitzung-test") })
        XCTAssertFalse(seen.contains { $0.url.absoluteString.contains("verpublish") || $0.url.absoluteString.contains("type=4") })

        // Uni & Noten liest GET /api/grades wie beim LSF
        let g = try await c.api.value("/api/grades")
        XCTAssertEqual(g["grades"]?.array?.compactMap { $0["text"]?.string }.sorted(), ["Grundlagen digitaler Systeme", "Mathematik für Ingenieure I", "Programmieren I"])
        XCTAssertEqual(g["passed"], 3)
        XCTAssertEqual(g["last_run"]?["ok"], 1)
        XCTAssertEqual(g["documents"], [], "keine Bescheinigungen auf dem Geraet")
        let db = try await c.host.backend().context.database
        let all = try await db.rows("SELECT * FROM grades")
        let runsRows = try await db.rows("SELECT * FROM qis_runs")
        let dump = JSONValue.array((all + runsRows).map(JSONValue.object)).jsonString()
        for secret in ["Erika", "Beispiel", "7654321", "StubSitzung01"] { XCTAssertFalse(dump.contains(secret), secret) }
        let suite = c.defaults.dictionaryRepresentation().description
        XCTAssertFalse(suite.contains("StubSitzung01"), "asi nie in den Einstellungen")
        XCTAssertEqual(UFDataMode.current(api: c.api, studip: m.studip), .local(.notConnected), "Stud.IP bleibt davon unberuehrt")

        // hoechstens alle 20 Stunden von selbst: direkt danach kein zweiter Abruf, auf Knopfdruck sofort
        let before = UniStubProtocol.requests.count
        let notDue = await q.run()
        XCTAssertNil(notDue, "nicht faellig")
        q.runIfDue()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(UniStubProtocol.requests.count, before)
        XCTAssertEqual(QISConnection.interval, 20 * 3600)
        let forcedRun = await q.run(force: true)
        let forced = try XCTUnwrap(forcedRun)
        XCTAssertEqual(forced.grades, 3)
        let count = try await db.scalar("SELECT COUNT(*) FROM grades")?.int
        XCTAssertEqual(count, 3, "aktualisiert statt doppelt")

        // Neustart der App: Stand aus den Einstellungen des Containers
        let again = QISConnection(container: c, websiteDataStore: m.websiteDataStore(for: c), clock: clock)
        XCTAssertEqual(again.state, .ok(clock.now))
        XCTAssertEqual(again.lastCount, 3)
        XCTAssertTrue(again.isConnected)
    }

    func testEmptyNotenspiegelIsHonestAndNotAnError() async throws {
        let (m, c, q) = try luh()
        installQIS(list: """
            <html><body><a href="rds?state=user&amp;type=4">Abmelden</a><table summary="Stammdaten"><tr><th>Name</th><td>Erika Beispiel</td></tr></table>
            <table><tr><th>Prüfungsnr</th><th>Prüfungstext</th><th>Semester</th><th>Note</th><th>Status</th><th>Credits</th><th>Versuch</th></tr></table></body></html>
            """)
        await signIn(m, c, q)
        let ran = await q.run(force: true)
        let r = try XCTUnwrap(ran)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(r.grades, 0)
        XCTAssertEqual(q.state, .ok(clock.now), "leer ist kein Fehler")
        XCTAssertEqual(q.lastCount, 0)
        let text = QISConnection.emptyText(q.state, lastCount: q.lastCount)
        XCTAssertTrue(text.hasPrefix("Im QIS sind noch keine Noten veröffentlicht."), text)
        let g = try await c.api.value("/api/grades")
        XCTAssertEqual(g["grades"], [])
        XCTAssertEqual(g["last_run"]?["ok"], 1)
        XCTAssertTrue(g["last_run"]?["message"]?.string?.hasPrefix("0 Leistungen") ?? false)
        // andere leere Zustaende ehrlich
        XCTAssertTrue(QISConnection.emptyText(.notConnected, lastCount: nil).contains("Verbinde QIS"))
        XCTAssertTrue(QISConnection.emptyText(.needsLogin, lastCount: 0).contains("abgelaufen"))
        XCTAssertTrue(QISConnection.emptyText(.connected, lastCount: nil).contains("Noch keine Leistungen geladen"))
    }

    func testExpiredSessionAsksForLoginAndKeepsGrades() async throws {
        let (m, c, q) = try luh()
        installQIS()
        await signIn(m, c, q)
        _ = await q.run(force: true)
        XCTAssertEqual(q.lastCount, 3)
        // Sitzung weg: das QIS zeigt das Anmeldeformular
        installQIS(loggedIn: false)
        let ran = await q.run(force: true)
        let r = try XCTUnwrap(ran)
        XCTAssertTrue(r.needsLogin)
        XCTAssertEqual(q.state, .needsLogin)
        XCTAssertTrue(q.needsAttention, "Karte: Erneut anmelden")
        XCTAssertEqual(QISConnection.statusText(q.state), "QIS: Anmeldung nötig")
        XCTAssertFalse(FirstLoginFlow.isConnected(.qis, studip: m.studip, qis: q, hildesheim: nil))
        let g = try await c.api.value("/api/grades")
        XCTAssertEqual(g["grades"]?.array?.count, 3, "alte Noten bleiben")
        XCTAssertEqual(g["last_run"]?["ok"], 0)
        XCTAssertTrue(g["last_run"]?["message"]?.string?.contains("abgelaufen") ?? false)
        // nicht von selbst erneut versuchen, bis neu angemeldet
        let before = UniStubProtocol.requests.count
        q.runIfDue()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(UniStubProtocol.requests.count, before)
        // erneut angemeldet: Stand "verbunden", Abruf gelingt wieder
        installQIS()
        q.signedIn()
        XCTAssertEqual(q.state, .connected)
        let back = await q.run(force: true)
        XCTAssertEqual(back?.grades, 3)
        XCTAssertEqual(q.state, .ok(clock.now))
    }

    func testSignOutRemovesOnlyTheQISSessionAndCredentials() async throws {
        let (m, c, q) = try luh()
        installQIS()
        let store = m.websiteDataStore(for: c).httpCookieStore
        await store.setCookie(bed.cookie("Seminar_Session", "studip-bleibt", domain: StudIPSync.base.host!))
        await signIn(m, c, q)
        _ = await q.run(force: true)
        c.credentials.save(UniversityCredential(user: "ab1-xyz", password: "Qis-Test-1"), .luh, service: "qis")
        c.credentials.save(UniversityCredential(user: "ab1-xyz", password: "Studip-Test-1"), .luh, service: "studip")
        await q.signOut()
        XCTAssertEqual(q.state, .notConnected)
        XCTAssertFalse(q.isConnected)
        XCTAssertNil(q.lastCount)
        let cookies = await store.allCookies()
        XCTAssertEqual(cookies.map(\.name), ["Seminar_Session"], "nur die QIS-Cookies weg, Stud.IP bleibt angemeldet")
        XCTAssertNil(c.credentials.credential(.luh, service: "qis"))
        XCTAssertNotNil(c.credentials.credential(.luh, service: "studip"))
        let g = try await c.api.value("/api/grades")
        XCTAssertEqual(g["grades"]?.array?.count, 3, "Noten bleiben")
        XCTAssertFalse(QISConnection(container: c, websiteDataStore: m.websiteDataStore(for: c), clock: clock).isConnected)
    }

    func testLoginDetectionOnlyOnAngemeldeteQISSeite() {
        let signedIn = #"<html><body><a href="rds?state=user&type=4&category=auth.logout">Abmelden</a><h1>Meine Funktionen</h1></body></html>"#
        let form = #"<html><body><form><input type="text" name="asdf"><input type="password" name="fdsa"></form></body></html>"#
        let qis = URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=0")!
        XCTAssertTrue(QISLoginPane<SwiftUI.EmptyView>.isSignedIn(html: signedIn, url: qis))
        XCTAssertFalse(QISLoginPane<SwiftUI.EmptyView>.isSignedIn(html: form, url: qis), "Anmeldeformular")
        XCTAssertFalse(QISLoginPane<SwiftUI.EmptyView>.isSignedIn(html: signedIn + form, url: qis), "Abmelden-Link neben einem Formular zaehlt nicht")
        XCTAssertFalse(QISLoginPane<SwiftUI.EmptyView>.isSignedIn(html: signedIn, url: URL(string: "https://studip.uni-hannover.de/x")!), "nur das QIS")
        XCTAssertFalse(QISLoginPane<SwiftUI.EmptyView>.isSignedIn(html: signedIn, url: URL(string: "http://qis.verwaltung.uni-hannover.de/x")!), "nur https")
        XCTAssertEqual(QISConnection.qisDomains, ["qis.verwaltung.uni-hannover.de"])
        XCTAssertNotNil(UniversityLoginAutofill(university: .luh, serviceKey: "qis"), "Vorausfuellen mit der LUH-ID aus Stud.IP")
    }

    func testStopEndsARunningFetchBeforeDeleting() async throws {
        let (m, c, q) = try luh()
        let gate = StubGate()
        let dir = ContainerTestBed.stubDirectory
        UniStubProtocol.install { r in
            guard r.cookie.contains("JSESSIONID=qis-sitzung-test") else { return .text("", status: 403) }
            if r.url.absoluteString.contains("next=list.vm") { gate.pass() }
            let reply = DebugStubTransport(directory: dir).reply(r.url, body: r.body)
            return UniStubProtocol.Reply(status: reply.status, headers: reply.headers, body: reply.body)
        }
        await signIn(m, c, q)
        let run = Task { await q.run(force: true) }
        try await bed.waitUntil("Abruf laeuft") { gate.wasReached }
        XCTAssertTrue(q.isRunning)
        await q.stop()
        gate.release()
        let report = await run.value
        XCTAssertTrue(report?.cancelled ?? true, "\(String(describing: report))")
        XCTAssertFalse(q.isRunning)
        XCTAssertNotEqual(q.state, .running)
        let after = await q.run(force: true)
        XCTAssertNil(after, "angehalten: kein weiterer Abruf")
    }

    func testUniversityPickerAndSidebarNoLongerPromiseQISForLater() {
        XCTAssertFalse(UniversityOption.services(.luh).contains("spätere"))
        XCTAssertTrue(UniversityOption.services(.luh).contains("QIS: Notenspiegel"))
        XCTAssertTrue(UFNavItem.visible(local: true, gradesOnDevice: true).contains { $0.id == "services" })
        XCTAssertEqual(UFGatePresentation.resolve(spec: .services, mode: .local(.connected), phase: .idle), .page)
        XCTAssertTrue(UFFeatureMatrix.uniGradesOnDevice)
        XCTAssertFalse(UFFeature.uniGrades.detail?.contains("Bescheinigungen") ?? true, "Bescheinigungen bleiben im QIS")
    }
}
