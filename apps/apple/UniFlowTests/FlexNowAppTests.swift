import Security
import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Uni Goettingen, FlexNow 2 in der App (27.11.2026, docs/GOETTINGEN-FLEXNOW-2026-11-27.md): Verbindung je Container,
/// Lesen der Seite "Aktuelles -> Aktuelle Prüfungen" (die unsichtbare Webansicht ist durch die Nachbildung
/// apps/apple/DebugStub/goettingen-flexnow ersetzt), stille Neuanmeldung genau einmal, Abmelden, Karte unter "Uni & Noten"
/// auf iPad und iPhone, Texte und Erinnerungen. Nie ein Netz, nie ein echtes Passwort.
@MainActor
final class FlexNowAppTests: XCTestCase {
    private var bed: ContainerTestBed!
    private var services: [String] = []
    /// Freitag, 27.11.2026, 10:00 in Berlin
    private let clock = UniFlowClock.fixed(berlin: "2026-11-27T10:00:00")!
    private let user = "testnutzer-erfunden"
    private let password = "Pw-Test-erfunden-123"

    private static func page(_ name: String) throws -> String {
        try String(contentsOf: ContainerTestBed.repoURL("apps/apple/DebugStub/goettingen-flexnow/\(name)"), encoding: .utf8)
    }

    /// Ersatz der unsichtbaren Webansicht: gibt nacheinander diese Seiten zurueck (die letzte bleibt)
    private final class Pages {
        var pages: [String]
        var reads = 0
        init(_ pages: [String]) { self.pages = pages }
        func next() -> FlexNowPageRead {
            reads += 1
            return .page(pages.count > 1 ? pages.removeFirst() : pages[0])
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        bed = try ContainerTestBed(name: "flexnow", clock: clock)
        UniAutoLogin.appActiveOverride = true
    }

    override func tearDown() async throws {
        FlexNowConnection.readerOverride = nil
        UniAutoLogin.runnerOverride = nil
        UniAutoLogin.appActiveOverride = nil
        for s in services { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary) }
        services = []
        await bed.tearDown()
        try await super.tearDown()
    }

    private func open(_ pages: Pages) throws -> (ContainerManager, ActiveContainer, FlexNowConnection) {
        FlexNowConnection.readerOverride = { _ in pages.next() }
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.goettingen))
        services.append(m.credentialService)
        let f = try XCTUnwrap(m.flexnow, "Göttingen hat eine FlexNow-Verbindung")
        f.readsAfterSignIn = false
        return (m, c, f)
    }

    // MARK: Verbindung

    func testOnlyGoettingenHasFlexNow() throws {
        let m = bed.manager()
        _ = try bed.open(m, bed.account(.luh))
        XCTAssertNil(m.flexnow, "LUH: kein FlexNow")
        XCTAssertNotNil(m.qis)
    }

    func testSignInReadsRegisteredExamsIntoTheApp() async throws {
        let pages = Pages([try Self.page("flexnow-angemeldet.html")])
        let (_, c, f) = try open(pages)
        XCTAssertEqual(f.state, .notConnected)
        let none = await f.run(force: true)
        XCTAssertNil(none, "ohne Anmeldung wird nichts gelesen")
        XCTAssertEqual(pages.reads, 0)

        f.signedIn(read: false)
        XCTAssertTrue(f.isConnected)
        let first = await f.run(force: true)
        let r = try XCTUnwrap(first)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(f.lastMessage, "2 angemeldete Prüfungen aus FlexNow gelesen.")
        guard case .ok = f.state else { return XCTFail("\(f.state)") }
        XCTAssertEqual(f.finishedRuns, 1)
        let v = try await c.api.value("/api/exam-registration")
        XCTAssertEqual(v.list("registered").compactMap { $0.s("text") },
                       ["Mathematik für Wirtschaftswissenschaften", "Einführung in die Volkswirtschaftslehre"])
        let st = ExamRegistrationState(v)
        XCTAssertEqual(st.system, "FlexNow")
        XCTAssertEqual(st.registered.first?.module, "B.WIWI-QMW.0001: Mathematik für Wirtschaftswissenschaften")
        XCTAssertEqual(st.registered.first?.form, "Prüfungsvorleistung")
        XCTAssertEqual(st.registered.first?.withdrawUntil, "2026-12-10")
        XCTAssertEqual(st.registered.first?.withdrawTime, "23:59")
        XCTAssertFalse(st.showCard, "keine Karte „Prüfungsanmeldung“ auf der Übersicht")
        XCTAssertTrue(st.suggestions.isEmpty, "kein Block „Prüfung anmelden“ in Modulen")
        XCTAssertEqual(st.guideTargets(), [], "kein Weg im QIS")
        // von selbst erst nach `interval`
        f.runIfDue()
        XCTAssertEqual(pages.reads, 1)
    }

    /// Abgelaufen: genau eine stille Anmeldung mit dem gemerkten Uni-Zugang, dann genau ein neues Lesen
    func testExpiredSessionRenewsOnceThenReads() async throws {
        let pages = Pages([try Self.page("flexnow.html"), try Self.page("flexnow-angemeldet.html")])
        let (_, _, f) = try open(pages)
        final class Log { var portals: [String] = [] }
        let log = Log()
        UniAutoLogin.runnerOverride = { r in
            log.portals.append(r.portal)
            XCTAssertEqual(r.entry, FlexNowPage.entry)
            XCTAssertEqual(r.credential.username, "testnutzer-erfunden")
            let done = await r.isDone(FlexNowPage.start, try! FlexNowAppTests.page("flexnow-angemeldet.html"))
            return done ? .success : .failed
        }
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, store: f.websiteDataStore), .saved)
        f.signedIn(read: false)
        let renewed = await f.run(force: true)
        let r = try XCTUnwrap(renewed)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(log.portals, ["flexnow"])
        XCTAssertEqual(pages.reads, 2)
        guard case .ok = f.state else { return XCTFail("\(f.state)") }
    }

    /// Abgelehnt: "Anmeldung nötig", die gelesenen Pruefungen bleiben, kein zweiter Versuch mit demselben Passwort
    func testRejectedPasswordKeepsRowsAndAsksForLogin() async throws {
        let pages = Pages([try Self.page("flexnow-angemeldet.html"), try Self.page("flexnow.html")])
        let (_, c, f) = try open(pages)
        final class Count { var n = 0 }
        let attempts = Count()
        UniAutoLogin.runnerOverride = { _ in attempts.n += 1; return .wrongPassword }
        XCTAssertEqual(UniAutoLogin.saveTyped(username: user, password: password, store: f.websiteDataStore), .saved)
        f.signedIn(read: false)
        _ = await f.run(force: true)
        let second = await f.run(force: true)
        let r = try XCTUnwrap(second)
        XCTAssertTrue(r.needsLogin)
        XCTAssertEqual(f.state, .needsLogin)
        XCTAssertEqual(attempts.n, 1)
        let kept = try await c.api.value("/api/exam-registration")
        XCTAssertEqual(kept.list("registered").count, 2, "nichts gelöscht")
        _ = await f.run(force: true)
        XCTAssertEqual(attempts.n, 1, "ein abgelehntes Passwort wird nie ein zweites Mal gesendet")
    }

    func testSignOutKeepsRowsAndNeverRenewsSilently() async throws {
        let pages = Pages([try Self.page("flexnow-angemeldet.html")])
        let (_, c, f) = try open(pages)
        f.signedIn(read: false)
        _ = await f.run(force: true)
        let cookie = bed.cookie("JSESSIONID", "erfunden", domain: FlexNowPage.host)
        let other = bed.cookie("Studip_Session", "s1", domain: "studip.uni-goettingen.de")
        await f.websiteDataStore.httpCookieStore.setCookie(cookie)
        await f.websiteDataStore.httpCookieStore.setCookie(other)
        await f.signOut()
        XCTAssertFalse(f.isConnected)
        XCTAssertTrue(f.signedOutOnPurpose)
        XCTAssertEqual(f.state, .notConnected)
        let names = (await f.websiteDataStore.httpCookieStore.allCookies()).map(\.name)
        XCTAssertFalse(names.contains("JSESSIONID"), "FlexNow-Cookie weg")
        XCTAssertTrue(names.contains("Studip_Session"), "Stud.IP bleibt angemeldet")
        let after = try await c.api.value("/api/exam-registration")
        XCTAssertEqual(after.list("registered").count, 2, "gelesene Prüfungen bleiben")
        let blocked = await f.run(force: true)
        XCTAssertNil(blocked, "abgemeldet: nichts lesen")
        f.signedIn(read: false)
        XCTAssertFalse(f.signedOutOnPurpose, "neue Anmeldung hebt die Sperre auf")
    }

    // MARK: Karte unter "Uni & Noten" (iPad und iPhone)

    /// Warten in einem async-Test: `env.wait` dreht die Hauptschleife, laesst aber keine Aufgaben des Hauptakteurs (`.task`
    /// der Ansicht) laufen, solange der Test selbst auf ihm laeuft; `Task.sleep` gibt ihn frei
    private func settle(_ env: HostedEnvironment, timeout: Double = 10, until condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end {
            try? await Task.sleep(nanoseconds: 50_000_000)
            env.pump(0.02)
        }
        return condition()
    }

    private func hostCard(_ c: ActiveContainer, _ f: FlexNowConnection, compact: Bool) throws -> HostedEnvironment {
        let size = compact ? CGSize(width: 390, height: 1400) : CGSize(width: 1180, height: 1100)
        let view = ScrollView { FlexNowCard(connection: f, api: c.api).padding(16) }
            .environment(\.ufCompact, compact)
            .environment(\.flexnow, f)
        return try hostWithEnvironment(view, api: c.api, size: size)
    }

    func testCardShowsExamsWithWithdrawalOnIPadAndIPhone() async throws {
        guard HostedEnvironment.accessibilityAutomation(true) else { throw XCTSkip("Bedienungshilfen-Baum nicht verfügbar") }
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let pages = Pages([try Self.page("flexnow-angemeldet.html")])
        let (_, c, f) = try open(pages)
        // nicht verbunden: Verbinden-Knopf und ehrlicher Text
        let empty = try hostCard(c, f, compact: false)
        let shown = await settle(empty) { empty.labels().contains("FlexNow verbinden") }
        XCTAssertTrue(shown, empty.labels().joined(separator: "\n"))
        XCTAssertTrue(empty.labels().contains { $0.contains("Melde dich einmal bei FlexNow an") }, empty.labels().joined(separator: "\n"))
        XCTAssertTrue(empty.labels().contains { $0.contains("Noten liest StudiNow aus FlexNow noch nicht") })
        empty.window.isHidden = true

        f.signedIn(read: false)
        let read = await f.run(force: true)
        XCTAssertEqual(read?.count, 2, "\(String(describing: read)) \(f.state)")
        let loaded = await ExamRegistrationState.load(c.api)
        XCTAssertEqual(loaded?.registered.count, 2)
        for compact in [false, true] {
            let env = try hostCard(c, f, compact: compact)
            let ok = await settle(env) { env.labels().contains { $0.contains("Mathematik für Wirtschaftswissenschaften") } }
            XCTAssertTrue(ok, env.labels().joined(separator: "\n"))
            let all = env.labels().joined(separator: "\n")
            XCTAssertTrue(all.contains("Abmeldung bis Do, 10.12.2026, 23:59 Uhr · noch 13 Tage"), all)
            XCTAssertTrue(all.contains("Modul B.WIWI-OPH.0004: Einführung in die Volkswirtschaftslehre"), all)
            XCTAssertTrue(all.contains("Prüfungsvorleistung"), all)
            XCTAssertTrue(all.contains("Angemeldete Prüfungen lesen"), all)
            XCTAssertTrue(all.contains(FlexNowText.reminderTitle), all)
            XCTAssertTrue(all.contains("Zuletzt gelesen"), all)
            XCTAssertFalse(all.contains("Prüfer") || all.contains("Erika Beispiel"), "kein Name der Prüfenden in der Karte")
            for bad in ["Im FlexNow zur Prüfung anmelden", "Prüfung anmelden", "QIS"] {
                XCTAssertFalse(all.contains(bad), "\(bad): StudiNow meldet nie an")
            }
            // nichts ragt aus der Breite
            let fits = UIHostingController(rootView: FlexNowCard(connection: f, api: c.api).environment(\.ufCompact, compact))
                .sizeThatFits(in: CGSize(width: compact ? 358 : 560, height: 4000))
            XCTAssertLessThanOrEqual(fits.width, compact ? 358 : 560)
            env.window.isHidden = true
        }
    }

    // MARK: Texte

    func testTexts() {
        func reg(_ iso: String?, time: String? = "23:59", text: String? = nil) -> ExamRegistrationState.Registered {
            ExamRegistrationState.Registered(id: 0, text: "X", date: nil, dateText: nil, time: nil, registered: true, withdrawUntil: iso,
                                             withdrawText: text, withdrawTime: time)
        }
        XCTAssertEqual(FlexNowText.withdrawLine(reg("2026-12-10"), today: "2026-11-27")?.text, "Abmeldung bis Do, 10.12.2026, 23:59 Uhr · noch 13 Tage")
        XCTAssertEqual(FlexNowText.withdrawLine(reg("2026-12-10"), today: "2026-11-27")?.tone, .neutral)
        XCTAssertEqual(FlexNowText.withdrawLine(reg("2026-12-10"), today: "2026-12-07")?.tone, .warn)
        XCTAssertEqual(FlexNowText.withdrawLine(reg("2026-12-10"), today: "2026-12-09")?.text, "Abmeldung bis morgen, Do, 10.12.2026, 23:59 Uhr")
        XCTAssertEqual(FlexNowText.withdrawLine(reg("2026-12-10"), today: "2026-12-10")?.text, "Abmeldung nur noch heute bis 23:59 Uhr")
        XCTAssertEqual(FlexNowText.withdrawLine(reg("2026-12-10"), today: "2026-12-10")?.tone, .bad)
        XCTAssertEqual(FlexNowText.withdrawLine(reg("2026-12-10"), today: "2026-12-11")?.text, "Abmeldefrist vorbei (10.12.2026)")
        XCTAssertEqual(FlexNowText.withdrawLine(reg(nil, text: "irgendwann"), today: "2026-12-11")?.text, "Abmeldung bis irgendwann")
        XCTAssertNil(FlexNowText.withdrawLine(reg(nil), today: "2026-12-11"))
        XCTAssertTrue(FlexNowText.emptyText(.notConnected, checked: false).contains("anmelden") || FlexNowText.emptyText(.notConnected, checked: false).contains("an, dann"))
        XCTAssertEqual(FlexNowText.emptyText(.ok(Date()), checked: true), "In FlexNow sind gerade keine Prüfungen angemeldet.")
        XCTAssertEqual(FlexNowConnection.statusText(.needsLogin), "FlexNow: Anmeldung nötig")
        // Hinweis "neu in StudiNow": FlexNow-Anmeldungen schon dabei, Noten weiter nicht
        let n = UFUniversityScope.newNotice(.goettingen)
        XCTAssertTrue(n?.have.contains("Aus FlexNow liest StudiNow deine angemeldeten Prüfungen mit Abmeldefrist.") == true, n?.have ?? "")
        XCTAssertTrue(n?.missing.contains("Noten (FlexNow)") == true, n?.missing ?? "")
        XCTAssertFalse(n?.missing.contains("Prüfungsanmeldung") == true, "die angemeldeten Prüfungen sind jetzt dabei")
        XCTAssertTrue(UniversityOption.services(.goettingen).contains("angemeldeten Prüfungen mit Abmeldefrist"))
        XCTAssertTrue(UFUniversityScope.servicesSub(.goettingen).contains("angemeldete Prüfungen aus FlexNow"))
        XCTAssertTrue(UFUniversityScope.gradesText(.goettingen).contains("die Noten noch nicht"))
    }

    // MARK: Anmeldefenster und Nachbildung

    func testLoginPageRulesAndStub() throws {
        // Mitlesen nur auf dem FlexNow-Formular der eigenen Hochschule
        let body: [String: Any] = ["user": "erika.muster", "pass": "geheim"]
        XCTAssertNotNil(UniCredentialCapture.accept(world: true, mainFrame: true, scheme: "https", host: FlexNowPage.host, port: 0,
                                                    frameURL: URL(string: "https://flexnow2.uni-goettingen.de/FN2AUTH/login.jsp"), body: body,
                                                    university: .goettingen))
        XCTAssertNil(UniCredentialCapture.accept(world: true, mainFrame: true, scheme: "https", host: "www.uni-goettingen.de", port: 0,
                                                 frameURL: URL(string: "https://www.uni-goettingen.de/de/45574.html"), body: body,
                                                 university: .goettingen), "Kasten auf der Uni-Seite: nie mitlesen")
        XCTAssertNil(UniCredentialCapture.accept(world: true, mainFrame: true, scheme: "https", host: FlexNowPage.host, port: 0,
                                                 frameURL: URL(string: "https://flexnow2.uni-goettingen.de/FN2SSS/"), body: body,
                                                 university: .goettingen))
        XCTAssertNil(UniCredentialCapture.accept(world: true, mainFrame: true, scheme: "https", host: FlexNowPage.host, port: 0,
                                                 frameURL: URL(string: "https://flexnow2.uni-goettingen.de/FN2AUTH/login.jsp"), body: body,
                                                 university: .luh))
        // die unsichtbare Webansicht laedt nur HTTPS auf Rechnern der Uni Goettingen
        XCTAssertTrue(FlexNowWebReader.allows(FlexNowPage.start))
        XCTAssertTrue(FlexNowWebReader.allows(URL(string: "https://www.uni-goettingen.de/de/45574.html")))
        XCTAssertFalse(FlexNowWebReader.allows(URL(string: "http://flexnow2.uni-goettingen.de/FN2SSS/")))
        XCTAssertFalse(FlexNowWebReader.allows(URL(string: "https://flexnow2.uni-goettingen.de.example.com/")))
        XCTAssertFalse(FlexNowWebReader.allows(URL(string: "https://evil-uni-goettingen.de/")))
        // Nachbildung fuer den Simulator: dieselben Seiten liegen auch im Ordner der Stud.IP-Nachbildung
        for name in ["flexnow.html", "flexnow-angemeldet.html"] {
            let a = try Self.page(name)
            let b = try String(contentsOf: ContainerTestBed.repoURL("apps/apple/DebugStub/goettingen/\(name)"), encoding: .utf8)
            XCTAssertEqual(a, b, "\(name): tools/build-goettingen-stub.py ausführen")
        }
        // Erinnerungen tragen den Weg zu "Uni & Noten"
        XCTAssertEqual(ExamRegistrationReminders.withdrawRoute, UFRoute.services.hash)
    }
}
