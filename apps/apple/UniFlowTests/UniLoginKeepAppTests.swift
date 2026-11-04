import Security
import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Angemeldet bleiben und Hochschul-Links in der App (Wunsch des Inhabers 04.11.2026). Feste Entscheidung vom 03.11.2026:
/// nie ein Hochschul-Passwort in der App. Alles ohne Netz: reine Regeln, erfundene Seiten mit `loadHTMLString`, eine
/// Inhaltsregel blockiert jedes Nachladen, jede Navigation (auch das Absenden) wird abgebrochen; Stud.IP nur als Attrappe.
@MainActor
final class UniLoginKeepAppTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_700_000)

    // MARK: Links: Hochschule -> In-App-Browser, sonst System, kein http(s) -> verwerfen

    private func route(_ s: String, _ u: UniversityKey?) -> UniLinks.Route {
        UniLinks.route(URL(string: s)!, university: u)
    }

    func testLUHLinksOpenInTheAppOthersGoToTheSystem() {
        let inApp = [
            "https://studip.uni-hannover.de/dispatch.php/course/details?cid=abc",
            "https://studip.uni-hannover.de",
            "https://STUDIP.uni-hannover.de/dispatch.php/messages/overview",
            "https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO?execution=e1s1",
            "https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=0",
        ]
        for s in inApp { XCTAssertEqual(route(s, .luh), .inApp(URL(string: s)!), s) }
        // http zur Hochschule: im In-App-Browser ueber https
        XCTAssertEqual(route("http://studip.uni-hannover.de/dispatch.php/start", .luh),
                       .inApp(URL(string: "https://studip.uni-hannover.de/dispatch.php/start")!))
        let system = [
            "https://www.uni-hannover.de/", "https://ilias.uni-hannover.de/", "https://login.uni-hannover.de/",
            "https://sso.idm.uni-hannover.de/andere-seite", "https://example.org/studip.uni-hannover.de",
            "https://studip.uni-hannover.de.example.org/", "https://studip.uni-hannover.de:8443/",
            "https://nutzer:geheim@studip.uni-hannover.de/", "https://www.uni-hildesheim.de/learnweb2026/my/",
            "https://lsf.uni-hildesheim.de/qisserver/rds",
        ]
        for s in system { XCTAssertEqual(route(s, .luh), .system, s) }
        for s in ["uniflow://#/plan", "mailto:a@b.de", "javascript:alert(1)", "file:///etc/hosts", "tel:123"] {
            XCTAssertEqual(route(s, .luh), .discard, s)
        }
    }

    func testHildesheimLinksOpenInTheAppOthersGoToTheSystem() {
        let inApp = [
            "https://www.uni-hildesheim.de/learnweb2026/course/view.php?id=1",
            "https://www.uni-hildesheim.de/learnweb2027/my/courses.php",
            "https://uni-hildesheim.de/learnweb2026/",
            "https://www.uni-hildesheim.de/sso/login?service=https%3A%2F%2Flsf.uni-hildesheim.de",
            "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0",
        ]
        for s in inApp { XCTAssertEqual(route(s, .hildesheim), .inApp(URL(string: s)!), s) }
        for s in ["https://www.uni-hildesheim.de/", "https://www.uni-hildesheim.de/fb1/", "https://studip.uni-hannover.de/",
                  "https://sso.idm.uni-hannover.de/idp/x", "https://www.uni-hildesheim.de.example.org/learnweb2026/"] {
            XCTAssertEqual(route(s, .hildesheim), .system, s)
        }
        XCTAssertEqual(route("uniflow://invite/X", .hildesheim), .discard)
    }

    func testWithoutAnOpenUniversityEverythingStaysAsBefore() {
        XCTAssertEqual(route("https://studip.uni-hannover.de/", nil), .system)
        XCTAssertEqual(route("uniflow://x", nil), .discard)
        // dieselbe Regel wie SafeLinks fuer alles ausserhalb der Hochschule
        for s in ["https://example.org", "http://example.org/x", "ftp://example.org", "uniflow://x"] {
            let u = URL(string: s)!
            XCTAssertEqual(route(s, .luh) == .discard, !SafeLinks.allows(u), s)
        }
    }

    func testMainFrameDecisionsInsideTheBrowser() {
        XCTAssertEqual(UniLinks.mainFrame(URL(string: "about:blank")!, university: .luh), .load)
        XCTAssertEqual(UniLinks.mainFrame(URL(string: "https://studip.uni-hannover.de/x")!, university: .luh), .load)
        XCTAssertEqual(UniLinks.mainFrame(URL(string: "http://studip.uni-hannover.de/x")!, university: .luh),
                       .upgrade(URL(string: "https://studip.uni-hannover.de/x")!))
        XCTAssertEqual(UniLinks.mainFrame(URL(string: "https://www.youtube.com/watch?v=1")!, university: .luh),
                       .handOff(URL(string: "https://www.youtube.com/watch?v=1")!))
        XCTAssertEqual(UniLinks.mainFrame(URL(string: "uniflow://#/plan")!, university: .luh), .block)
        XCTAssertEqual(UniWebView.title(page: "  ", url: URL(string: "https://studip.uni-hannover.de/x")), "studip.uni-hannover.de")
        XCTAssertEqual(UniWebView.title(page: "Meine Kurse", url: nil), "Meine Kurse")
    }

    /// Ohne offenen Container oder Fenster gibt der Browser an das System zurueck (nie verschluckt)
    func testActionWithoutContainerGoesToTheSystem() async throws {
        let bed = try ContainerTestBed(name: "uniweb-ohne", clock: .fixed(now))
        let m = bed.manager()
        let r = UniWebBrowser.action(for: URL(string: "https://studip.uni-hannover.de/")!, containers: m)
        XCTAssertEqual(String(describing: r), String(describing: OpenURLAction.Result.systemAction))
        XCTAssertEqual(String(describing: UniWebBrowser.action(for: URL(string: "uniflow://x")!, containers: m)),
                       String(describing: OpenURLAction.Result.discarded))
        await bed.tearDown()
    }

    // MARK: Cookies: was gemerkt wird

    private func cookie(_ name: String, domain: String, expires: Date? = nil, value: String = "v") -> HTTPCookie {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"]
        if let expires { p[.expires] = expires }
        return HTTPCookie(properties: p)!
    }

    func testCookiePolicyKeepsIdentityProviderAndPersistentCookiesNeverForeignExpiredOrSecretNames() {
        let d = UniWebSessions.domains(.luh)
        let keep = [
            cookie("shib_idp_session", domain: "sso.idm.uni-hannover.de"),
            cookie("shib_idp_persistent_ss", domain: "sso.idm.uni-hannover.de", expires: now.addingTimeInterval(86_400 * 30)),
            cookie("Seminar_Session", domain: "studip.uni-hannover.de"),
            cookie("_shibsession_x", domain: ".uni-hannover.de"),
        ]
        for c in keep { XCTAssertTrue(UniCookiePolicy.keep(c, domains: d, now: now), c.name) }
        let drop = [
            cookie("alt", domain: "sso.idm.uni-hannover.de", expires: now.addingTimeInterval(-1)),
            cookie("fremd", domain: "example.org"),
            cookie("x", domain: "uni-hannover.de.example.org"),
            cookie("user_password", domain: "studip.uni-hannover.de"),
            cookie("Kennwort", domain: "sso.idm.uni-hannover.de"),
        ]
        for c in drop { XCTAssertFalse(UniCookiePolicy.keep(c, domains: d, now: now), c.name) }
        XCTAssertTrue(UniCookiePolicy.keep(cookie("TGC", domain: "www.uni-hildesheim.de"), domains: UniWebSessions.domains(.hildesheim), now: now))
    }

    func testMissingNeverOverwritesNewerAndSkipsExpired() {
        let present = [cookie("Seminar_Session", domain: "studip.uni-hannover.de", value: "neu")]
        let wanted = [cookie("Seminar_Session", domain: "studip.uni-hannover.de", value: "alt"),
                      cookie("shib_idp_session", domain: "sso.idm.uni-hannover.de"),
                      cookie("abgelaufen", domain: "sso.idm.uni-hannover.de", expires: now.addingTimeInterval(-5))]
        XCTAssertEqual(UniCookiePolicy.missing(wanted, in: present, now: now).map(\.name), ["shib_idp_session"])
        XCTAssertFalse(UniCookiePolicy.differs(present, present))
        XCTAssertTrue(UniCookiePolicy.differs(present, [wanted[0]]))
    }

    func testVaultStoresCookiesWithExpiryAndNoOtherFields() async throws {
        let service = "de.uniflow.ai.studip.test.\(UUID().uuidString)"
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
        let vault = UniWebSessions.vault(service: service, container: UUID())
        let store = WKWebsiteDataStore.nonPersistent()
        let expiry = Date().addingTimeInterval(3600 * 24 * 7)
        await store.httpCookieStore.setCookie(cookie("shib_idp_session", domain: "sso.idm.uni-hannover.de"))
        await store.httpCookieStore.setCookie(cookie("idp_remember", domain: "sso.idm.uni-hannover.de", expires: expiry))
        let saved = await UniWebSessions.save(store, to: vault, domains: UniWebSessions.domains(.luh))
        XCTAssertEqual(saved, 2)
        let raw = try XCTUnwrap(vault.loadRaw())
        let entries = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [[String: Any]])
        let fields = Set(entries.flatMap(\.keys))
        XCTAssertTrue(fields.isSubset(of: ["name", "value", "domain", "path", "expires", "secure", "httpOnly", "sameSite"]), "\(fields)")
        let back = vault.load()
        let remembered = try XCTUnwrap(back.first { $0.name == "idp_remember" })
        XCTAssertEqual(try XCTUnwrap(remembered.expiresDate).timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(try XCTUnwrap(back.first { $0.name == "shib_idp_session" }).isSessionOnly)
    }

    // MARK: Wann erneuert wird

    private func decide(_ t: UniRenewalTrigger, active: Bool = true, connected: Bool = true, expired: Bool = false,
                        _ state: UniRenewalState = UniRenewalState()) -> UniRenewalDecision {
        UniRenewalPolicy.decide(t, appActive: active, connected: connected, knownExpired: expired, state: state, now: now)
    }

    func testRenewalChecksOnForegroundAndBeforeSyncWithIntervals() {
        XCTAssertEqual(decide(.foreground, connected: false), .nothing)
        XCTAssertEqual(decide(.foreground, active: false), .nothing, "im Hintergrund nie pruefen oder erneuern")
        XCTAssertEqual(decide(.beforeSync, active: false, expired: true), .nothing)
        XCTAssertEqual(decide(.foreground), .check, "noch nie bestaetigt")
        var s = UniRenewalState()
        s.verified(at: now.addingTimeInterval(-10 * 60))
        XCTAssertEqual(decide(.foreground, s), .nothing, "vor 10 Minuten bestaetigt")
        XCTAssertEqual(decide(.beforeSync, s), .check, "vor dem Abgleich nach 5 Minuten wieder")
        s.verified(at: now.addingTimeInterval(-4 * 60))
        XCTAssertEqual(decide(.beforeSync, s), .nothing)
        s.verified(at: now.addingTimeInterval(-16 * 60))
        XCTAssertEqual(decide(.foreground, s), .check)
        XCTAssertEqual(decide(.userAction, s), .check)
        XCTAssertEqual(decide(.requestFailed, s), .renew, "eine Anfrage meldete abgelaufen")
    }

    func testRenewalBacksOffAfterFailedSilentAttempts() {
        XCTAssertEqual(decide(.foreground, expired: true), .renew, "abgelaufen: sofort still erneuern")
        XCTAssertEqual(decide(.beforeSync, expired: true), .renew)
        var s = UniRenewalState()
        s.attempted(at: now.addingTimeInterval(-5 * 60), ok: false)
        XCTAssertEqual(s.failures, 1)
        XCTAssertEqual(decide(.foreground, expired: true, s), .wait(until: now.addingTimeInterval(5 * 60)))
        XCTAssertEqual(decide(.userAction, expired: true, s), .renew, "nach einer Handlung des Menschen ohne Wartezeit")
        s.attempted(at: now.addingTimeInterval(-11 * 60), ok: false)        // zweiter Fehlschlag: 20 Minuten
        XCTAssertEqual(decide(.foreground, expired: true, s), .wait(until: now.addingTimeInterval(9 * 60)))
        XCTAssertEqual(UniRenewalPolicy.backoff(failures: 0), 0)
        XCTAssertEqual(UniRenewalPolicy.backoff(failures: 1), 600)
        XCTAssertEqual(UniRenewalPolicy.backoff(failures: 3), 2400)
        XCTAssertEqual(UniRenewalPolicy.backoff(failures: 50), 4 * 3600, "hoechstens 4 Stunden")
        s.attempted(at: now, ok: true)
        XCTAssertEqual(s.failures, 0)
        XCTAssertEqual(s.lastVerified, now)
    }

    /// Pruefung der Stud.IP-Sitzung: gueltig, abgelaufen (401, Anmeldeseite) oder nicht entscheidbar (kein Netz)
    func testSessionCheckTellsValidExpiredAndUnknownApart() async {
        struct Fake: StudIPTransport {
            let reply: @Sendable () throws -> HTTPReply
            func get(_ url: URL, accept: String?) async throws -> HTTPReply { try reply() }
        }
        let me = Data(#"{"data":{"type":"users","id":"u1","attributes":{}}}"#.utf8)
        let valid = await StudIPSync.sessionCheck([], transport: Fake { HTTPReply(status: 200, contentType: "application/vnd.api+json", body: me) })
        XCTAssertEqual(valid, .valid)
        let expired = await StudIPSync.sessionCheck([], transport: Fake { HTTPReply(status: 401, contentType: "application/json") })
        XCTAssertEqual(expired, .expired)
        let login = await StudIPSync.sessionCheck([], transport: Fake {
            HTTPReply(status: 200, contentType: "text/html", finalURL: URL(string: "https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO"),
                      body: Data("<html><form><input name=loginname></form></html>".utf8))
        })
        XCTAssertEqual(login, .expired)
        let offline = await StudIPSync.sessionCheck([], transport: Fake { throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(offline, .unknown)
    }

    // MARK: Benutzername (nie das Passwort)

    func testUsernameRules() {
        XCTAssertTrue(UniLoginHelper.isAcceptableUsername("ab1-cd2"))
        XCTAssertTrue(UniLoginHelper.isAcceptableUsername("vorname.nachname@stud.uni-hannover.de"))
        for bad in ["", "a b", "x\n", String(repeating: "a", count: 129), "tab\tx"] {
            XCTAssertFalse(UniLoginHelper.isAcceptableUsername(bad), bad)
        }
        XCTAssertEqual(UniLoginHelper.prefill(stored: "ab1", current: ""), "ab1")
        XCTAssertNil(UniLoginHelper.prefill(stored: "ab1", current: "selbst getippt"), "nie etwas Eingetipptes ersetzen")
        XCTAssertNil(UniLoginHelper.prefill(stored: nil, current: ""))
        XCTAssertNil(UniLoginHelper.prefill(stored: "a b", current: ""))
        let d = UserDefaults(suiteName: "uniflow.tests.username.\(UUID().uuidString)")!
        XCTAssertTrue(UniLoginHelper.remember("  ab1  ", defaults: d))
        XCTAssertEqual(UniLoginHelper.storedUsername(d), "ab1")
        XCTAssertFalse(UniLoginHelper.remember("zwei worte", defaults: d))
        XCTAssertEqual(UniLoginHelper.storedUsername(d), "ab1")
        UniLoginHelper.forget(defaults: d)
        XCTAssertNil(UniLoginHelper.storedUsername(d))
    }

    func testHelperOnlyOnIdentityProviderPages() {
        XCTAssertEqual(UniLoginHelper.idpTargets(.luh), [UniversityLoginTarget(host: "sso.idm.uni-hannover.de", pathPrefix: "/idp/")])
        XCTAssertEqual(Set(UniLoginHelper.idpTargets(.hildesheim).map(\.host)), ["www.uni-hildesheim.de", "uni-hildesheim.de"])
        XCTAssertTrue(UniLoginHelper.applies(to: UniversityLoginPolicyTests.luhSSOURL, university: .luh))
        XCTAssertTrue(UniLoginHelper.applies(to: UniversityLoginPolicyTests.casURL, university: .hildesheim))
        for (u, uni) in [(UniversityLoginPolicyTests.studipLoginURL, UniversityKey.luh), (UniversityLoginPolicyTests.qisURL, .luh),
                         (UniversityLoginPolicyTests.learnwebFileURL, .hildesheim), (UniversityLoginPolicyTests.casURL, .luh),
                         (URL(string: "http://sso.idm.uni-hannover.de/idp/x")!, .luh)] {
            XCTAssertFalse(UniLoginHelper.applies(to: u, university: uni), u.absoluteString)
        }
        for uni in UniversityKey.allCases {
            let script = UniLoginHelper.script(university: uni, username: "ab1").lowercased()
            XCTAssertFalse(script.contains("password") || script.contains("passwort") || script.contains("fdsa"), "das Skript kennt kein Passwortfeld")
            XCTAssertFalse(script.contains("setattribute(") || script.contains("autocomplete"), "autocomplete der Seite bleibt")
        }
        // Benutzername mit Anfuehrungszeichen kann das Skript nicht aufbrechen (JSON), Unbrauchbares wird nicht eingesetzt
        XCTAssertTrue(UniLoginHelper.script(university: .luh, username: "a\"b").contains(#"var known = "a\"b";"#))
        XCTAssertTrue(UniLoginHelper.script(university: .luh, username: "a b").contains("var known = null;"))
    }

    // MARK: Das Skript in einer echten Webansicht (ohne Netz)

    final class Harness: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        private(set) var finished = 0
        private(set) var submissions = 0
        private var allowNext = false

        init(rules: WKContentRuleList, helper: UniLoginHelper) {
            let config = StudIPWebView.loginConfiguration(dataStore: .nonPersistent())
            config.userContentController.add(rules)
            helper.install(in: config)
            webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            super.init()
            webView.navigationDelegate = self
        }

        func load(_ html: String, at url: URL) {
            allowNext = true
            webView.loadHTMLString(html, baseURL: url)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if allowNext, navigationAction.navigationType == .other {
                allowNext = false
                decisionHandler(.allow)
            } else {
                if navigationAction.navigationType == .formSubmitted { submissions += 1 }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished += 1 }

        func js(_ script: String) async throws -> String {
            let v = try await webView.evaluateJavaScript(script)
            return v.map { "\($0)" } ?? ""
        }
    }

    private func harness(_ uni: UniversityKey, defaults: UserDefaults) async throws -> Harness {
        let rules = #"[{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}]"#
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "uniflow.tests.blockall.keep",
                                                                                      encodedContentRuleList: rules)
        return Harness(rules: try XCTUnwrap(list), helper: UniLoginHelper(university: uni, defaults: defaults))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Zeitueberschreitung: \(what)")
    }

    private func loaded(_ h: Harness, _ html: String, _ url: URL) async throws {
        let before = h.finished
        h.load(html, at: url)
        try await waitUntil("Seite geladen") { h.finished > before }
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    /// WebSSO wie bei der LUH, dazu die Kaestchen des Shibboleth-IdP und ein "Angemeldet bleiben"
    static let luhPage = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <form id="fm1" method="post" action="/idp/profile/SAML2/Redirect/SSO?execution=e1s1">
    <input id="loginname" name="loginname" type="text"><input id="password" name="password" type="password" autocomplete="current-password">
    <input type="checkbox" id="donotcache" name="donotcache" value="1" checked><label for="donotcache">Anmeldung nicht speichern (Don't Remember Login)</label>
    <input type="checkbox" id="_shib_idp_revokeConsent" name="_shib_idp_revokeConsent" value="true"><label for="_shib_idp_revokeConsent">Einwilligung widerrufen</label>
    <label><input type="checkbox" id="stay" name="stay">Angemeldet bleiben</label>
    <input type="checkbox" id="news" name="news"><label for="news">Newsletter</label>
    <button type="submit" name="_eventId_proceed">Anmelden</button></form></body></html>
    """

    /// CAS wie in Hildesheim mit "Remember Me"
    static let casPage = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <form id="fm1" method="post" action="login">
    <input id="username" name="username" type="text" autocomplete="username" value="">
    <input id="password" name="password" type="password" autocomplete="off">
    <input type="checkbox" id="rememberMe" name="rememberMe" value="true"><label for="rememberMe">Angemeldet bleiben</label>
    <button name="submit" type="submit" value="Anmelden">Anmelden</button></form></body></html>
    """

    private static let state = """
    (function () {
      function v(id) { var e = document.getElementById(id); return e ? (e.type === 'checkbox' ? String(e.checked) : e.value) : '-'; }
      var u = document.querySelector('input[name=loginname]') || document.querySelector('input[name=username]');
      var mh = window.webkit && window.webkit.messageHandlers;
      return [u ? u.value : '-', v('password'), v('donotcache'), v('_shib_idp_revokeConsent'), v('stay'), v('news'), v('rememberMe'),
              (mh && mh.uniflowUsername) ? 'kanal-sichtbar' : 'kein-kanal'].join('|');
    })()
    """

    func testOnTheLUHWebSSOTheUsernameIsPrefilledRememberTickedPasswordUntouched() async throws {
        let d = UserDefaults(suiteName: "uniflow.tests.keep.\(UUID().uuidString)")!
        UniLoginHelper.remember("ab1-cd2", defaults: d)
        let h = try await harness(.luh, defaults: d)
        try await loaded(h, Self.luhPage, UniversityLoginPolicyTests.luhSSOURL)
        try await waitUntil("vorausgefuellt") { try await h.js("document.getElementById('loginname').value") == "ab1-cd2" }
        let s = try await h.js(Self.state)
        XCTAssertEqual(s, "ab1-cd2||false|false|true|false|-|kein-kanal",
                       "Benutzername da, Passwort leer, 'nicht speichern' aus, Einwilligung unberuehrt, 'Angemeldet bleiben' an, Seite sieht keinen Kanal")

        // der Mensch tippt einen anderen Namen und das Passwort (bzw. iOS setzt es ein) und meldet sich an
        _ = try await h.js("""
        (function () { document.getElementById('loginname').value = 'neu-name'; document.getElementById('password').value = 'Pw-Test-erfunden-123';
          document.querySelector('button[type=submit]').click(); return 'ok'; })()
        """)
        try await waitUntil("Absenden abgefangen") { h.submissions > 0 }
        try await waitUntil("Benutzername gemerkt") { UniLoginHelper.storedUsername(d) == "neu-name" }
        XCTAssertFalse(d.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("Pw-Test") == true }, "nie das Passwort")
    }

    func testOnTheHildesheimCASRememberMeIsTickedAndNothingIsFilledWithoutAName() async throws {
        let d = UserDefaults(suiteName: "uniflow.tests.keep.\(UUID().uuidString)")!
        let h = try await harness(.hildesheim, defaults: d)
        try await loaded(h, Self.casPage, UniversityLoginPolicyTests.casURL)
        try await waitUntil("Angemeldet bleiben") { try await h.js("String(document.getElementById('rememberMe').checked)") == "true" }
        let user = try await h.js("document.getElementById('username').value")
        let password = try await h.js("document.getElementById('password').value")
        XCTAssertEqual(user, "", "kein gemerkter Name: nichts eingesetzt")
        XCTAssertEqual(password, "")
    }

    /// Nicht auf Stud.IP, QIS, fremden oder aehnlichen Rechnern, nicht ueber http, nicht auf einer Seite desselben
    /// Rechners, die ihre Adresse nachtraeglich auf den Anmeldepfad umschreibt; dort meldet auch niemand einen Namen
    func testNothingHappensOutsideTheIdentityProvider() async throws {
        let d = UserDefaults(suiteName: "uniflow.tests.keep.\(UUID().uuidString)")!
        UniLoginHelper.remember("ab1-cd2", defaults: d)
        let spoof = """
        <!doctype html><html><head><meta charset="utf-8"><script>history.replaceState(null, '', '/sso/login?service=x');</script></head><body>
        \(Self.casPage.components(separatedBy: "<body>").last ?? "")
        """
        let cases: [(String, UniversityKey, String, URL)] = [
            ("Stud.IP-Login", .luh, Self.luhPage, UniversityLoginPolicyTests.studipLoginURL),
            ("QIS", .luh, UniversityLoginPolicyTests.qisPage, UniversityLoginPolicyTests.qisURL),
            ("fremder Rechner", .luh, Self.luhPage, URL(string: "https://phishing.example/idp/profile/SAML2/Redirect/SSO")!),
            ("aehnlicher Rechner", .hildesheim, Self.casPage, URL(string: "https://www.uni-hildesheim.de.example.org/sso/login")!),
            ("http", .hildesheim, Self.casPage, URL(string: "http://www.uni-hildesheim.de/sso/login")!),
            ("andere Hochschule", .luh, Self.casPage, UniversityLoginPolicyTests.casURL),
            ("replaceState", .hildesheim, spoof, UniversityLoginPolicyTests.learnwebFileURL),
        ]
        for (name, uni, html, url) in cases {
            let h = try await harness(uni, defaults: d)
            try await loaded(h, html, url)
            let filled = try await h.js("""
            (function () { var out = []; var all = document.querySelectorAll('input');
              for (var i = 0; i < all.length; i++) { var e = all[i];
                if ((e.type === 'text' || e.type === 'password') && e.value !== '') out.push(e.name);
                if (e.type === 'checkbox' && e.checked !== e.defaultChecked) out.push(e.name); }
              return out.join(','); })()
            """)
            XCTAssertEqual(filled, "", name)
            _ = try await h.js("(function () { var u = document.querySelector('input[type=text]'); if (u) u.value = 'fremd-name'; var b = document.querySelector('[type=submit]'); if (b) b.click(); return 'ok'; })()")
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(UniLoginHelper.storedUsername(d), "ab1-cd2", "\(name): kein Name gemeldet")
        }
    }

    // MARK: Abmelden vergisst den Benutzernamen; der Container kennt die Hilfe

    func testContainerKnowsTheHelperAndSignOutForgetsTheUsername() async throws {
        let bed = try ContainerTestBed(name: "keep-signout", clock: .fixed(now))
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        let store = m.websiteDataStore(for: c)
        let ctx = try XCTUnwrap(UniWebSessions.loginContext(store))
        XCTAssertEqual(ctx.university, .luh)
        XCTAssertNil(UniWebSessions.loginContext(.nonPersistent()), "fremde Datenspeicher bekommen kein Skript")
        let config = WKWebViewConfiguration()
        XCTAssertTrue(UniLoginHelper.install(in: config, dataStore: store))
        XCTAssertEqual(config.userContentController.userScripts.count, 1)
        XCTAssertTrue(config.userContentController.userScripts[0].isForMainFrameOnly)
        XCTAssertEqual(config.userContentController.userScripts[0].injectionTime, .atDocumentStart)

        UniLoginHelper.remember("ab1", defaults: c.defaults)
        try c.cookies.save([bed.cookie("Seminar_Session", "s", domain: "studip.uni-hannover.de")])
        await m.studip.signOut()
        XCTAssertNil(UniLoginHelper.storedUsername(c.defaults), "Abmelden vergisst den Namen")
        await bed.tearDown()
    }

    /// Der In-App-Browser setzt das Stud.IP-Cookie des Abgleichs in den Datenspeicher, ohne Neueres zu ueberschreiben
    func testBrowserSeedsTheSyncCookieIntoTheWebStore() async throws {
        let bed = try ContainerTestBed(name: "keep-seed", clock: .fixed(now))
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        let store = m.websiteDataStore(for: c)
        await UniWebSessions.ready(store)
        try c.cookies.save([bed.cookie("Seminar_Session", "abgleich", domain: "studip.uni-hannover.de")])
        await m.studip.seedWebSession()
        var all = await store.httpCookieStore.allCookies()
        XCTAssertEqual(all.first { $0.name == "Seminar_Session" }?.value, "abgleich")
        await store.httpCookieStore.setCookie(bed.cookie("Seminar_Session", "browser-neuer", domain: "studip.uni-hannover.de"))
        await m.studip.seedWebSession()
        all = await store.httpCookieStore.allCookies()
        XCTAssertEqual(all.filter { $0.name == "Seminar_Session" }.map(\.value), ["browser-neuer"])
        await bed.tearDown()
    }
}
