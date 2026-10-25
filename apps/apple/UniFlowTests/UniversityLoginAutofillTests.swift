import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Merken und Vorausfuellen in einer echten WKWebView mit erfundenen, lokalen Seiten (kein Netz):
/// `loadHTMLString` mit der Adresse der Anmeldeseite als Basis, eine Inhaltsregel blockiert jedes Nachladen und
/// jede weitere Navigation (auch das Absenden) wird abgebrochen. Zugangsdaten sind erfunden; der Schluesselbund
/// laeuft unter einem eigenen Test-Dienstnamen.
@MainActor
final class UniversityLoginAutofillTests: XCTestCase {
    private var keychain: UniversityKeychain!
    private var defaults: UserDefaults!
    private var suite = ""
    private var store: UniversityCredentialStore!

    override func setUp() async throws {
        keychain = UniversityKeychain(service: "de.uniflow.ai.university.test.\(UUID().uuidString)")
        suite = "uniflow.tests.autofill.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = UniversityCredentialStore(secrets: keychain, defaults: defaults)
    }

    override func tearDown() async throws {
        keychain.accounts().forEach(keychain.remove)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Erfundene Anmeldeseiten

    static let casURL = URL(string: "https://www.uni-hildesheim.de/sso/login?service=https%3A%2F%2Flsf.uni-hildesheim.de%2Fqisserver%2Frds%3Fstate%3Duser%26type%3D1")!
    static let luhSSOURL = URL(string: "https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO?execution=e1s1")!
    static let studipLoginURL = URL(string: "https://studip.uni-hannover.de/dispatch.php/login")!

    /// Aufbau wie das CAS der Uni Hildesheim (#username, #password, Knopf name=submit)
    static let casPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Anmeldung (Test)</title></head><body>
    <form id="fm1" method="post" action="login" onsubmit="window.__submitted = (window.__submitted || 0) + 1;">
    <input id="username" name="username" type="text" autocomplete="username" value="">
    <input id="password" name="password" type="password" autocomplete="off">
    <input type="hidden" name="execution" value="e1s1">
    <button name="submit" type="submit" value="Anmelden">Anmelden</button>
    </form></body></html>
    """

    /// Aufbau wie das WebSSO der LUH (loginname, password, _eventId_proceed)
    static let luhPage = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <form method="post" action="/idp/profile/SAML2/Redirect/SSO?execution=e1s1" onsubmit="window.__submitted = (window.__submitted || 0) + 1;">
    <input id="loginname" name="loginname" type="text"><input id="password" name="password" type="password">
    <button type="submit" name="_eventId_proceed">Anmelden</button></form></body></html>
    """

    /// unbekannter Name des Benutzerfelds: das Textfeld vor dem Passwortfeld zaehlt
    static let genericPage = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <form method="post" action="/dispatch.php/login" onsubmit="window.__submitted = (window.__submitted || 0) + 1;">
    <input type="search" name="suche"><input type="text" name="kennung" id="kennung"><input type="hidden" name="x" value="1">
    <input type="password" name="geheim" id="geheim"><input type="submit" value="Anmelden"></form></body></html>
    """

    // MARK: Webansicht ohne Netz

    final class Harness: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        private(set) var blocked: [WKNavigationType] = []
        private(set) var finished = 0
        private var allowNext = false

        init(autofill: UniversityLoginAutofill?, rules: WKContentRuleList) {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(rules)
            autofill?.install(into: config.userContentController)
            webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            super.init()
            webView.navigationDelegate = self
        }

        func load(_ html: String, at url: URL) {
            allowNext = true
            webView.loadHTMLString(html, baseURL: url)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // nur das eigene loadHTMLString; Absenden, Links, Weiterleitungen: abbrechen (nie ins Netz)
            if allowNext, navigationAction.navigationType == .other {
                allowNext = false
                decisionHandler(.allow)
            } else {
                blocked.append(navigationAction.navigationType)
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished += 1 }

        func js(_ script: String) async throws -> String {
            let v = try await webView.evaluateJavaScript(script)
            return v.map { "\($0)" } ?? ""
        }

        /// Wie ein Mensch: tippen und auf den Absende-Knopf tippen (im Seitenkontext, nicht durch die App)
        func typeAndTapLogin(user: String, password: String, userField: String, passwordField: String, button: String) async throws {
            _ = try await js("""
            (function () {
              document.querySelector('\(userField)').value = '\(user)';
              document.querySelector('\(passwordField)').value = '\(password)';
              document.querySelector('\(button)').click();
              return 'ok';
            })()
            """)
        }
    }

    private func blockAll() async throws -> WKContentRuleList {
        let rules = #"[{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}]"#
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "uniflow.tests.blockall",
                                                                                      encodedContentRuleList: rules)
        return try XCTUnwrap(list)
    }

    private func harness(_ autofill: UniversityLoginAutofill?) async throws -> Harness {
        Harness(autofill: autofill, rules: try await blockAll())
    }

    private func autofill(_ uni: UniversityKey, _ service: String) throws -> (UniversityLoginAutofill, EventLog) {
        let a = try XCTUnwrap(UniversityLoginAutofill(university: uni, serviceKey: service, store: store))
        let log = EventLog()
        a.onEvent = { log.events.append($0) }
        return (a, log)
    }

    final class EventLog { var events: [UniversityLoginAutofill.Event] = [] }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Zeitueberschreitung: \(what)")
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 700_000_000) }

    private func loaded(_ h: Harness, _ html: String, _ url: URL) async throws {
        let before = h.finished
        h.load(html, at: url)
        try await waitUntil("Seite geladen") { h.finished > before }
    }

    private let typed = UniversityCredential(user: "testnutzer", password: "Pw-Test-123")

    // MARK: Merken nur mit Zustimmung

    func testSavesOnlyWithConsent() async throws {
        store.setRemember(false, .hildesheim, service: "cas")
        let (a, log) = try autofill(.hildesheim, "cas")
        XCTAssertFalse(a.remember, "Schalter aus")
        let h = try await harness(a)
        try await loaded(h, Self.casPage, Self.casURL)
        try await waitUntil("ready") { log.events.contains(.ready) }
        try await h.typeAndTapLogin(user: typed.user, password: typed.password, userField: "#username", passwordField: "#password",
                                    button: "button[name=submit]")
        try await waitUntil("notSaved") { log.events.contains(.notSaved) }
        XCTAssertNil(store.credential(.hildesheim, service: "cas"), "ohne Zustimmung nichts gemerkt")
        XCTAssertTrue(keychain.accounts().isEmpty)
        // das Absenden durch den "Menschen" (Test) kommt als Navigation an und wird abgebrochen: nie ins Netz
        try await waitUntil("Absenden abgefangen") { h.blocked.contains(.formSubmitted) }

        a.remember = true
        XCTAssertTrue(store.remember(.hildesheim, service: "cas"))
        try await loaded(h, Self.casPage, Self.casURL)
        try await waitUntil("ready 2") { log.events.filter { $0 == .ready }.count >= 2 }
        try await h.typeAndTapLogin(user: typed.user, password: typed.password, userField: "#username", passwordField: "#password",
                                    button: "button[name=submit]")
        try await waitUntil("saved") { log.events.contains(.saved) }
        XCTAssertEqual(store.credential(.hildesheim, service: "cas"), typed)
        XCTAssertNil(store.credential(.luh, service: "studip"), "andere Uni bekommt nichts")
        XCTAssertFalse(log.events.contains(.rejected))

        // Schalter wieder aus: sofort entfernt
        a.remember = false
        XCTAssertNil(store.credential(.hildesheim, service: "cas"))
    }

    // MARK: Vorausfuellen ohne Absenden

    func testPrefillsAndNeverSubmits() async throws {
        store.save(typed, .hildesheim, service: "cas")
        let (a, log) = try autofill(.hildesheim, "cas")
        let h = try await harness(a)
        try await loaded(h, Self.casPage, Self.casURL)
        try await waitUntil("filled") { log.events.contains(.filled) }
        let v1 = try await h.js("document.querySelector('#username').value")
        XCTAssertEqual(v1, "testnutzer")
        let v2 = try await h.js("document.querySelector('#password').value")
        XCTAssertEqual(v2, "Pw-Test-123")
        try await settle()
        let v3 = try await h.js("String(window.__submitted || 0)")
        XCTAssertEqual(v3, "0", "Formular nicht abgeschickt")
        XCTAssertTrue(h.blocked.isEmpty, "keine Navigation (kein Absenden, kein Klick)")
        XCTAssertEqual(h.webView.url, Self.casURL)
        XCTAssertFalse(log.events.contains(.saved), "Vorausfuellen speichert nichts neu")

        // schon Eingetipptes bleibt stehen
        let pretyped = Self.casPage.replacingOccurrences(of: #"autocomplete="username" value="""#, with: #"autocomplete="username" value="selbst""#)
        try await loaded(h, pretyped, Self.casURL)
        try await waitUntil("filled 2") { log.events.filter { $0 == .filled }.count >= 2 }
        let v4 = try await h.js("document.querySelector('#username').value")
        XCTAssertEqual(v4, "selbst")
        let v5 = try await h.js("document.querySelector('#password').value")
        XCTAssertEqual(v5, "Pw-Test-123")
        try await settle()
        let v6 = try await h.js("String(window.__submitted || 0)")
        XCTAssertEqual(v6, "0")
        XCTAssertTrue(h.blocked.isEmpty)
    }

    func testScriptsContainNoSubmitPath() throws {
        let service = try XCTUnwrap(UniversityProfile.hildesheim.loginService("cas"))
        for source in [UniversityLoginAutofill.captureScript(for: service), UniversityLoginAutofill.fillScript] {
            for forbidden in [#"\.submit\s*\("#, #"requestSubmit"#, #"\.click\s*\("#, #"new\s+(Mouse|Keyboard|Pointer|Submit)Event"#,
                              #"Event\(\s*['"]submit"#, #"\.form\.action"#, #"location\s*=|location\.(href|assign|replace)"#] {
                XCTAssertNil(source.range(of: forbidden, options: .regularExpression), "\(forbidden) darf nicht vorkommen")
            }
        }
    }

    // MARK: Nur auf erlaubten Seiten

    func testOnlyOnAllowedHostAndPath() async throws {
        store.save(typed, .hildesheim, service: "cas")
        let (a, log) = try autofill(.hildesheim, "cas")
        let h = try await harness(a)
        let elsewhere = [URL(string: "https://phishing.example/sso/login?service=x")!,
                         URL(string: "http://www.uni-hildesheim.de/sso/login")!,
                         URL(string: "https://www.uni-hildesheim.de/learnweb2026/login/index.php")!,
                         URL(string: "https://www.uni-hildesheim.de.example.org/sso/login")!,
                         Self.luhSSOURL]
        for url in elsewhere {
            try await loaded(h, Self.casPage, url)
            try await settle()
            let v7 = try await h.js("document.querySelector('#username').value")
            XCTAssertEqual(v7, "", url.absoluteString)
            let v8 = try await h.js("document.querySelector('#password').value")
            XCTAssertEqual(v8, "", url.absoluteString)
            try await h.typeAndTapLogin(user: "fremd", password: "fremd-pw", userField: "#username", passwordField: "#password",
                                        button: "button[name=submit]")
            try await settle()
        }
        XCTAssertTrue(log.events.isEmpty, "keine Nachricht von fremden Seiten: \(log.events)")
        XCTAssertEqual(store.credential(.hildesheim, service: "cas"), typed, "nichts ueberschrieben")
    }

    // MARK: Hochschulen getrennt

    func testOtherUniversitySeesNothing() async throws {
        store.save(typed, .hildesheim, service: "cas")
        let (luh, log) = try autofill(.luh, "studip")
        let h = try await harness(luh)
        // LUH-Seite: keine LUH-Daten, also leer (kein Rueckfall auf Hildesheim)
        try await loaded(h, Self.luhPage, Self.luhSSOURL)
        try await waitUntil("ready") { log.events.contains(.ready) }
        try await settle()
        let v9 = try await h.js("document.querySelector('#loginname').value")
        XCTAssertEqual(v9, "")
        let v10 = try await h.js("document.querySelector('#password').value")
        XCTAssertEqual(v10, "")
        // CAS-Seite mit dem LUH-Helfer: nicht seine Seite
        try await loaded(h, Self.casPage, Self.casURL)
        try await settle()
        let v11 = try await h.js("document.querySelector('#username').value")
        XCTAssertEqual(v11, "")
        XCTAssertEqual(log.events.filter { $0 == .ready }.count, 1)

        // LUH merkt sich eigenes, Hildesheim bleibt unveraendert
        try await loaded(h, Self.luhPage, Self.luhSSOURL)
        try await waitUntil("ready 2") { log.events.filter { $0 == .ready }.count >= 2 }
        try await h.typeAndTapLogin(user: "ab1-xyz", password: "Luh-Test-1", userField: "#loginname", passwordField: "#password",
                                    button: "button[name=_eventId_proceed]")
        try await waitUntil("saved") { log.events.contains(.saved) }
        XCTAssertEqual(store.credential(.luh, service: "studip"), UniversityCredential(user: "ab1-xyz", password: "Luh-Test-1"))
        XCTAssertEqual(store.credential(.hildesheim, service: "cas"), typed)
        XCTAssertNil(store.credential(.luh, service: "qis"))
    }

    func testDeletePerUniversity() async throws {
        store.save(UniversityCredential(user: "ab1-xyz", password: "Luh-Test-1"), .luh, service: "studip")
        store.save(typed, .hildesheim, service: "cas")
        store.deleteAll(for: .luh)                                         // z. B. Stud.IP abmelden
        let (luh, luhLog) = try autofill(.luh, "studip")
        let h = try await harness(luh)
        try await loaded(h, Self.luhPage, Self.luhSSOURL)
        try await waitUntil("ready") { luhLog.events.contains(.ready) }
        try await settle()
        XCTAssertFalse(luhLog.events.contains(.filled))
        let v12 = try await h.js("document.querySelector('#loginname').value")
        XCTAssertEqual(v12, "")

        let (hi, hiLog) = try autofill(.hildesheim, "cas")
        let h2 = try await harness(hi)
        try await loaded(h2, Self.casPage, Self.casURL)
        try await waitUntil("filled") { hiLog.events.contains(.filled) }
        let v13 = try await h2.js("document.querySelector('#username').value")
        XCTAssertEqual(v13, "testnutzer", "andere Uni unberuehrt")
    }

    func testUserFieldBeforePasswordIsFound() async throws {
        let (a, log) = try autofill(.luh, "studip")
        let h = try await harness(a)
        try await loaded(h, Self.genericPage, Self.studipLoginURL)
        try await waitUntil("ready") { log.events.contains(.ready) }
        try await h.typeAndTapLogin(user: "ab1-xyz", password: "Luh-Test-2", userField: "#kennung", passwordField: "#geheim",
                                    button: "input[type=submit]")
        try await waitUntil("saved") { log.events.contains(.saved) }
        XCTAssertEqual(store.credential(.luh, service: "studip"), UniversityCredential(user: "ab1-xyz", password: "Luh-Test-2"))
        try await loaded(h, Self.genericPage, Self.studipLoginURL)
        try await waitUntil("filled") { log.events.contains(.filled) }
        let v14 = try await h.js("document.querySelector('#kennung').value")
        XCTAssertEqual(v14, "ab1-xyz")
        let v15 = try await h.js("document.querySelector('input[name=suche]').value")
        XCTAssertEqual(v15, "", "Suchfeld bleibt leer")
        let v16 = try await h.js("document.querySelector('#geheim').value")
        XCTAssertEqual(v16, "Luh-Test-2")
        try await settle()
        let v17 = try await h.js("String(window.__submitted || 0)")
        XCTAssertEqual(v17, "0", "nach dem Neuladen nichts abgeschickt")
    }

    func testStudIPLoginHasProfile() {
        XCTAssertNotNil(UniversityLoginAutofill(university: .luh, serviceKey: "studip"))
        XCTAssertNil(UniversityLoginAutofill(university: .luh, serviceKey: "cas"), "kein Dienst der anderen Uni")
    }
}
