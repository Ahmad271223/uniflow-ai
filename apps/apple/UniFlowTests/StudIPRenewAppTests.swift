import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Stud.IP-Anmeldung erneuern (2.11.2026): direkter WebSSO-Einstieg wie am PC und Cookies nur der Stud.IP-Adresse
@MainActor
final class StudIPRenewAppTests: XCTestCase {
    func testSSOLoginURLMatchesThePC() {
        // app/studip_sync.py SHIB_LOGIN_URL
        XCTAssertEqual(StudIPSync.ssoLoginURL(base: URL(string: "https://studip.uni-hannover.de")!).absoluteString,
                       "https://studip.uni-hannover.de/Shibboleth.sso/Login?target=https%3A%2F%2Fstudip.uni-hannover.de%2Fdispatch.php%2Flogin%3Fsso%3Dshib%26again%3Dyes%26cancel_login%3D1&entityID=https%3A%2F%2Fsso.idm.uni-hannover.de%2Fidp%2Fshibboleth")
        XCTAssertEqual(StudIPSync.ssoLoginURL(base: URL(string: "https://studip.uni-hannover.de/")!), StudIPSync.ssoLoginURL(base: URL(string: "https://studip.uni-hannover.de")!))
    }

    func testOnlyStudIPCookiesAreKept() {
        func c(_ domain: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: "/", .name: "n", .value: "v"])!
        }
        let kept = StudIPSync.ownCookies([c("studip.uni-hannover.de"), c(".uni-hannover.de"), c("sso.idm.uni-hannover.de"), c("example.org")],
                                         host: "studip.uni-hannover.de")
        XCTAssertEqual(kept.map(\.domain), ["studip.uni-hannover.de", ".uni-hannover.de"], "die Uni-Anmeldung selbst bleibt in der Webansicht")
    }
}

/// Uni-Anmeldung ueber App-Neustarts (3.11.2026): Sitzungs-Cookies der Hochschul-Rechner (WebSSO, CAS, LSF) aus dem
/// Datenspeicher der Webansicht in den Schluesselbund und zurueck; nie fremde Cookies; Abmelden und Loeschen der
/// Hochschuldaten vergessen sie
@MainActor
final class UniWebSessionsAppTests: XCTestCase {
    private var service = ""
    private var bed: ContainerTestBed?

    override func setUp() async throws {
        service = "de.uniflow.ai.studip.test.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        await bed?.tearDown()
        bed = nil
    }

    /// Sitzungs-Cookie (ohne Ablauf) wie `shib_idp_session` oder `TGC`
    private func session(_ name: String, _ value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE",
                                HTTPCookiePropertyKey("HttpOnly"): "TRUE"])!
    }

    func testDomainsPerUniversity() {
        XCTAssertEqual(UniWebSessions.domains(.luh), ["uni-hannover.de"])
        XCTAssertEqual(UniWebSessions.domains(.hildesheim), ["uni-hildesheim.de"])
    }

    func testSessionCookiesOfTheUniversitySurviveARestart() async throws {
        let vault = UniWebSessions.vault(service: service, container: UUID())
        let domains = UniWebSessions.domains(.luh)
        let before = WKWebsiteDataStore.nonPersistent()
        await before.httpCookieStore.setCookie(session("shib_idp_session", "idp", domain: "sso.idm.uni-hannover.de"))
        await before.httpCookieStore.setCookie(session("Seminar_Session", "s", domain: "studip.uni-hannover.de"))
        await before.httpCookieStore.setCookie(session("fremd", "x", domain: "example.org"))
        await before.httpCookieStore.setCookie(HTTPCookie(properties: [.name: "dauerhaft", .value: "d", .domain: "sso.idm.uni-hannover.de",
                                                                       .path: "/", .expires: Date().addingTimeInterval(3600)])!)
        let saved = await UniWebSessions.save(before, to: vault, domains: domains)
        XCTAssertEqual(saved, 2, "nur Sitzungs-Cookies der Hochschule; dauerhafte behaelt WebKit selbst")

        // Neustart: WebKit hat die Sitzungs-Cookies verloren
        let after = WKWebsiteDataStore.nonPersistent()
        let restored = await UniWebSessions.restore(into: after, from: vault, domains: domains)
        XCTAssertEqual(restored, 2)
        let cookies = await after.httpCookieStore.allCookies()
        XCTAssertEqual(Set(cookies.map(\.name)), ["shib_idp_session", "Seminar_Session"])
        let idp = try XCTUnwrap(cookies.first { $0.name == "shib_idp_session" })
        XCTAssertEqual(idp.value, "idp")
        XCTAssertEqual(idp.domain, "sso.idm.uni-hannover.de")
        XCTAssertTrue(idp.isSecure)
        XCTAssertTrue(idp.isHTTPOnly)
        XCTAssertTrue(idp.isSessionOnly)

        // eine neuere Anmeldung im Datenspeicher wird nie ueberschrieben
        await after.httpCookieStore.setCookie(session("shib_idp_session", "neu", domain: "sso.idm.uni-hannover.de"))
        let again = await UniWebSessions.restore(into: after, from: vault, domains: domains)
        XCTAssertEqual(again, 0)
        let now = await after.httpCookieStore.allCookies()
        XCTAssertEqual(now.first { $0.name == "shib_idp_session" }?.value, "neu")

        // keine Sitzungs-Cookies mehr: Eintrag weg
        let empty = WKWebsiteDataStore.nonPersistent()
        _ = await UniWebSessions.save(empty, to: vault, domains: domains)
        XCTAssertNil(vault.loadRaw())
    }

    /// Container wie in der App: Datenspeicher oeffnen setzt die gemerkte Anmeldung zurueck; Stud.IP abmelden und
    /// "Daten dieser Hochschule löschen" vergessen sie
    func testContainerRestoresAndSignOutForgets() async throws {
        let bed = try ContainerTestBed(name: "websessions", clock: UniFlowClock.fixed(Date(timeIntervalSince1970: 1_793_700_000)))
        self.bed = bed
        let a = bed.account(.luh)
        let m1 = bed.manager()
        let c1 = try bed.open(m1, a)
        let vault = UniWebSessions.vault(service: bed.cookieService, container: c1.layout.identifier)
        let store1 = m1.websiteDataStore(for: c1)
        await UniWebSessions.ready(store1)
        await store1.httpCookieStore.setCookie(session("shib_idp_session", "idp", domain: "sso.idm.uni-hannover.de"))
        await m1.saveWebSessions()
        XCTAssertNotNil(vault.loadRaw(), "Uni-Anmeldung gemerkt")

        // Neustart: Sitzungs-Cookies sind weg, ein neuer Datenspeicher bekommt sie zurueck
        await store1.httpCookieStore.deleteCookie(session("shib_idp_session", "idp", domain: "sso.idm.uni-hannover.de"))
        UniWebSessions.detach(store1)          // neuer Prozess (WebKit liefert im selben Prozess dasselbe Objekt)
        let m2 = bed.manager()
        let c2 = try bed.open(m2, a)
        let store2 = m2.websiteDataStore(for: c2)
        await UniWebSessions.ready(store2)
        let restored = await store2.httpCookieStore.allCookies()
        XCTAssertEqual(restored.first { $0.name == "shib_idp_session" }?.value, "idp", "ohne neue Anmeldung wieder da")

        // Abmelden von Stud.IP: gemerkte Anmeldung weg, Webdaten weg
        await m2.studip.signOut()
        XCTAssertNil(vault.loadRaw(), "abgemeldet: nie wiederverwenden")
        let left = await store2.httpCookieStore.allCookies()
        XCTAssertTrue(left.isEmpty)

        // erneut gemerkt, dann "Daten dieser Hochschule löschen"
        await store2.httpCookieStore.setCookie(session("shib_idp_session", "zwei", domain: "sso.idm.uni-hannover.de"))
        await m2.saveWebSessions()
        XCTAssertNotNil(vault.loadRaw())
        let problem = await m2.deleteUniversityData(c2.key)
        XCTAssertNil(problem)
        XCTAssertNil(vault.loadRaw(), "Loeschen der Hochschuldaten nimmt die gemerkte Anmeldung mit")
    }

    /// Hildesheim: Abmelden von Learnweb und LSF vergisst die gemerkte CAS-Anmeldung
    func testHildesheimSignOutForgetsTheCASLogin() async throws {
        let bed = try ContainerTestBed(name: "websessions-hi", clock: UniFlowClock.fixed(Date(timeIntervalSince1970: 1_793_700_000)))
        self.bed = bed
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.hildesheim))
        let h = try XCTUnwrap(m.hildesheim)
        h.syncsAfterSignIn = false
        let vault = UniWebSessions.vault(service: bed.cookieService, container: c.layout.identifier)
        let store = m.websiteDataStore(for: c)
        await UniWebSessions.ready(store)
        await store.httpCookieStore.setCookie(session("TGC", "cas", domain: "www.uni-hildesheim.de"))
        h.lsfSignedIn()
        try await bed.waitUntil("CAS-Anmeldung gemerkt") { vault.loadRaw() != nil }
        let problem = await h.signOut()
        XCTAssertNil(problem)
        XCTAssertNil(vault.loadRaw())
    }

    /// Bitte um neue Anmeldung nur bei wirklich abgelaufener Anmeldung (Stud.IP: abgelaufen gemerkt)
    func testStudIPReportsLoginNeededOnlyWhenExpired() async throws {
        let bed = try ContainerTestBed(name: "websessions-need", clock: UniFlowClock.fixed(Date(timeIntervalSince1970: 1_793_700_000)))
        self.bed = bed
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        try c.cookies.save([session("Seminar_Session", "s", domain: "studip.uni-hannover.de")])
        XCTAssertEqual(m.studip.loginNeededSources, [])
        c.defaults.set(true, forKey: StudIPSync.Keys.sessionExpired)
        XCTAssertEqual(m.studip.loginNeededSources, ["Stud.IP"])
    }
}
