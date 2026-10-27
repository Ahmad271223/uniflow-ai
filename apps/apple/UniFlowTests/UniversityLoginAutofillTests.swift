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

    /// Meldet die Navigationen wie `StudIPWebView.Coordinator` an den Helfer (`autofill`).
    final class Harness: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        let autofill: UniversityLoginAutofill?
        private(set) var blocked: [WKNavigationType] = []
        private(set) var finished = 0
        private(set) var responses = 0
        private var allowNext = false

        init(autofill: UniversityLoginAutofill?, rules: WKContentRuleList) {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.add(rules)
            autofill?.install(into: config.userContentController)
            self.autofill = autofill
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
            autofill?.navigationStarts(navigationAction)
            // nur das eigene loadHTMLString; Absenden, Links, Weiterleitungen: abbrechen (nie ins Netz)
            if allowNext, navigationAction.navigationType == .other {
                allowNext = false
                decisionHandler(.allow)
            } else {
                blocked.append(navigationAction.navigationType)
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame { responses += 1 }
            autofill?.navigationResponds(navigationResponse)
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { autofill?.navigationCommitted(in: webView) }

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
        // CAS-Seite mit dem LUH-Helfer: nicht seine Seite (und danach ist die Webansicht keine Anmeldeansicht mehr)
        try await loaded(h, Self.casPage, Self.casURL)
        try await settle()
        let v11 = try await h.js("document.querySelector('#username').value")
        XCTAssertEqual(v11, "")
        XCTAssertEqual(log.events.filter { $0 == .ready }.count, 1)
        XCTAssertTrue(log.events.contains(.disarmed))

        // LUH merkt sich eigenes (neue Anmeldeansicht), Hildesheim bleibt unveraendert
        let (luh2, log2) = try autofill(.luh, "studip")
        let h2 = try await harness(luh2)
        try await loaded(h2, Self.luhPage, Self.luhSSOURL)
        try await waitUntil("ready 2") { log2.events.contains(.ready) }
        try await h2.typeAndTapLogin(user: "ab1-xyz", password: "Luh-Test-1", userField: "#loginname", passwordField: "#password",
                                     button: "button[name=_eventId_proceed]")
        try await waitUntil("saved") { log2.events.contains(.saved) }
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

    // MARK: Nur das Dokument der letzten echten Navigation

    /// Erfundene Seite auf demselben Rechner wie das CAS (z. B. eine als Learnweb-Material hochgeladene HTML-Datei,
    /// die pluginfile.php direkt ausliefert): schreibt ihre Adresse ohne Navigation auf den Anmeldepfad um.
    static func spoofPage(_ history: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><script>history.\(history)(null, '', '/sso/login?service=x');</script></head><body>
        <form id="fm1" method="post" action="login"><input id="username" name="username" type="text">
        <input id="password" name="password" type="password"><button name="submit" type="submit">Anmelden</button></form>
        </body></html>
        """
    }

    static let learnwebFileURL = URL(string: "https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/1/mod_resource/content/1/evil.html")!

    func testSameOriginPageRewritingItsAddressGetsNothing() async throws {
        store.save(typed, .hildesheim, service: "cas")
        let (a, log) = try autofill(.hildesheim, "cas")
        let h = try await harness(a)
        for history in ["replaceState", "pushState"] {
            let before = log.events.count
            try await loaded(h, Self.spoofPage(history), Self.learnwebFileURL)
            try await waitUntil("Nachricht des Erfassungsskripts (\(history))") { log.events.count > before }
            try await settle()
            XCTAssertEqual(h.webView.url?.path, "/sso/login", "\(history): Adresse ohne Navigation umgeschrieben")
            // loadHTMLString liefert keine Server-Antwort: hier gilt die Adresse beim Uebernehmen (vor jedem Seitenskript);
            // den Weg ueber die Antwort-Adresse prueft testDocumentAddressComesFromTheRealNavigation
            XCTAssertEqual(h.responses, 0)
            XCTAssertEqual(a.documentURL, Self.learnwebFileURL)
            let user = try await h.js("document.getElementById('username').value")
            let pw = try await h.js("document.getElementById('password').value")
            XCTAssertEqual(user, "", history)
            XCTAssertEqual(pw, "", "\(history): Passwort nie in eine fremde Seite desselben Ursprungs")
            XCTAssertEqual(Array(log.events[before...]), [.rejected], "\(history): 'ready' verworfen")

            // die Seite schickt selbst ab (requestSubmit) und will fremde Werte als gemerkte Daten unterschieben
            let n = log.events.count
            let blockedBefore = h.blocked.count
            _ = try await h.js("""
            (function () {
              document.getElementById('username').value = 'fremd';
              document.getElementById('password').value = 'fremd-pw';
              document.getElementById('fm1').requestSubmit();
              return 'ok';
            })()
            """)
            try await waitUntil("Absenden abgefangen") { h.blocked.count > blockedBefore }
            try await settle()
            XCTAssertFalse(log.events[n...].contains(.saved), history)
            XCTAssertFalse(log.events[n...].contains(.notSaved), "\(history): Nachricht gar nicht angenommen")
            XCTAssertEqual(store.credential(.hildesheim, service: "cas"), typed, "\(history): nichts ueberschrieben")
        }
        XCTAssertFalse(log.events.contains(.filled))
        XCTAssertFalse(log.events.contains(.ready))

        // die echte Anmeldeseite in derselben Webansicht wird weiter vorausgefuellt
        try await loaded(h, Self.casPage, Self.casURL)
        try await waitUntil("filled") { log.events.contains(.filled) }
        let v = try await h.js("document.querySelector('#password').value")
        XCTAssertEqual(v, "Pw-Test-123")
    }

    /// Weg der App (StudIPWebView laedt aus dem Netz): die Meldungen des WKNavigationDelegate nachgestellt.
    func testDocumentAddressComesFromTheRealNavigation() throws {
        let (a, log) = try autofill(.hildesheim, "cas")
        a.navigationStarts(mainFrame: false, backForward: false)                       // Unterrahmen: zaehlt nicht
        a.navigationCommitted(shownURL: Self.casURL)
        XCTAssertNil(a.documentURL, "Uebernahme ohne gemeldeten Beginn: kein Vertrauen")
        a.navigationStarts(mainFrame: true, backForward: false)
        a.navigationResponds(mainFrame: true, url: Self.casURL)
        a.navigationResponds(mainFrame: false, url: Self.learnwebFileURL)              // Antwort eines Unterrahmens
        a.navigationCommitted(shownURL: Self.casURL)
        XCTAssertEqual(a.documentURL, Self.casURL, "Antwort-Adresse des Hauptrahmens")
        a.navigationStarts(mainFrame: true, backForward: false)
        XCTAssertNil(a.documentURL, "neue Navigation entzieht das Vertrauen sofort")
        a.navigationResponds(mainFrame: true, url: Self.casURL)
        a.navigationCommitted(shownURL: URL(string: Self.casURL.absoluteString + "#form")!)
        XCTAssertEqual(a.documentURL, Self.casURL, "Anker zaehlt nicht")
        XCTAssertTrue(a.isArmed)
        // Zurueck aus dem Zwischenspeicher (keine Antwort): kein Vertrauen, und die Anmeldeseiten gelten als verlassen
        a.navigationStarts(mainFrame: true, backForward: true)
        a.navigationCommitted(shownURL: Self.casURL)
        XCTAssertNil(a.documentURL)
        XCTAssertFalse(a.isArmed)
        XCTAssertEqual(log.events, [.disarmed])

        // Antwort von einer anderen Seite als angezeigt (z. B. Learnweb-Datei, Anzeige schon umgeschrieben): nichts
        let (b, _) = try autofill(.hildesheim, "cas")
        b.navigationStarts(mainFrame: true, backForward: false)
        b.navigationResponds(mainFrame: true, url: Self.learnwebFileURL)
        b.navigationCommitted(shownURL: Self.casURL)
        XCTAssertNil(b.documentURL)
        XCTAssertTrue(b.isArmed, "nie auf einer Anmeldeseite gewesen: nichts zu entschaerfen")
        // Zurueck/Vor mit echter Antwort (neu aus dem Netz geladen) zaehlt wieder
        b.navigationStarts(mainFrame: true, backForward: true)
        b.navigationResponds(mainFrame: true, url: Self.casURL)
        b.navigationCommitted(shownURL: Self.casURL)
        XCTAssertEqual(b.documentURL, Self.casURL)
    }

    func testFillOnlyIntoTheDocumentThatReportedReady() async throws {
        let (a, log) = try autofill(.hildesheim, "cas")
        let h = try await harness(a)
        try await loaded(h, Self.casPage, Self.casURL)
        try await waitUntil("ready") { log.events.contains(.ready) }
        // Kennung des Dokuments liegt nur in der Inhaltswelt der App, nicht im Seitenskript
        let pageSees = try await h.js("String(window.__uniflowLoginDoc)")
        XCTAssertEqual(pageSees, "undefined")
        let doc = try await h.webView.evaluateJavaScript("window.__uniflowLoginDoc", in: nil, contentWorld: UniversityLoginAutofill.world) as? String
        XCTAssertEqual(doc?.count, 32)
        func fill(_ d: String) async throws -> Bool {
            let service = try XCTUnwrap(UniversityProfile.hildesheim.loginService("cas"))
            let args: [String: Any] = ["user": "testnutzer", "password": "Pw-Test-123", "host": "www.uni-hildesheim.de", "path": "/sso/login",
                                       "doc": d, "userSelectors": service.userSelectors, "passwordSelectors": service.passwordSelectors]
            let r = try await h.webView.callAsyncJavaScript(UniversityLoginAutofill.fillScript, arguments: args, in: nil,
                                                             contentWorld: UniversityLoginAutofill.world)
            return (r as? Bool) == true
        }
        let wrong = try await fill(String(repeating: "0", count: 32))
        XCTAssertFalse(wrong, "anderes Dokument: nichts")
        let empty = try await h.js("document.querySelector('#password').value")
        XCTAssertEqual(empty, "")
        let right = try await fill(try XCTUnwrap(doc))
        XCTAssertTrue(right)
        let v = try await h.js("document.querySelector('#password').value")
        XCTAssertEqual(v, "Pw-Test-123")
    }

    func testLeavingTheLoginPageRemovesScriptAndHandler() async throws {
        store.save(typed, .hildesheim, service: "cas")
        let (a, log) = try autofill(.hildesheim, "cas")
        let h = try await harness(a)
        XCTAssertFalse(h.webView.configuration.userContentController.userScripts.isEmpty)
        try await loaded(h, Self.casPage, Self.casURL)
        try await waitUntil("filled") { log.events.contains(.filled) }
        // nach der Anmeldung zurueck ins Learnweb (Inhalte der Hochschule)
        try await loaded(h, "<!doctype html><html><body><p>Meine Kurse</p></body></html>",
                         URL(string: "https://www.uni-hildesheim.de/learnweb2026/my/courses.php")!)
        try await waitUntil("disarmed") { log.events.contains(.disarmed) }
        XCTAssertFalse(a.isArmed)
        XCTAssertTrue(h.webView.configuration.userContentController.userScripts.isEmpty, "Skript entfernt")
        // dieselbe Webansicht zeigt wieder eine Anmeldeseite: nichts vorausgefuellt, nichts gemerkt
        let n = log.events.count
        try await loaded(h, Self.casPage, Self.casURL)
        try await settle()
        let v = try await h.js("document.querySelector('#password').value")
        XCTAssertEqual(v, "")
        try await h.typeAndTapLogin(user: "fremd", password: "fremd-pw", userField: "#username", passwordField: "#password",
                                    button: "button[name=submit]")
        try await settle()
        XCTAssertEqual(Array(log.events[n...]), [], "keine Nachrichten mehr")
        XCTAssertEqual(store.credential(.hildesheim, service: "cas"), typed)
        // eine neue Anmeldeansicht baut neu ein
        let (b, log2) = try autofill(.hildesheim, "cas")
        let h2 = try await harness(b)
        try await loaded(h2, Self.casPage, Self.casURL)
        try await waitUntil("filled neu") { log2.events.contains(.filled) }
    }

    // MARK: 231–235 Manipulierte und weitergeleitete Anmeldeseiten

    /// Formular im eingebetteten Rahmen: ueber das DOM des leeren Rahmens (about:blank) gebaut, ohne Navigation – die
    /// Testumgebung bricht jede weitere Navigation ab (auch srcdoc), es soll nie etwas aus dem Netz kommen
    static func frameScript(action: String) -> String {
        """
        <iframe id="fremd"></iframe>
        <script>
        (function () {
          var d = document.getElementById('fremd').contentDocument;
          d.body.innerHTML = '<form id="fm1" method="post" action="\(action)">'
            + '<input id="username" name="username" type="text"><input id="password" name="password" type="password">'
            + '<button name="submit" type="submit">Anmelden</button></form>';
        })();
        </script>
        """
    }

    /// Echte Anmeldeseite mit eingebettetem Fremdformular (iframe, gleiche Feldnamen, Ziel auf fremdem Rechner):
    /// nur das Formular des Hauptrahmens wird vorausgefuellt, das eingebettete bleibt leer; die Seite selbst sieht den
    /// Kanal der App nicht.
    static let framedPage = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <form id="fm1" method="post" action="login" onsubmit="window.__submitted = (window.__submitted || 0) + 1;">
    <input id="username" name="username" type="text"><input id="password" name="password" type="password">
    <button name="submit" type="submit">Anmelden</button></form>
    \(frameScript(action: "https://phishing.example/steal"))
    </body></html>
    """

    /// Seite auf dem Anmeldepfad, deren Formular nur in einem eingebetteten Rahmen steckt
    static let onlyFramedPage = """
    <!doctype html><html><head><meta charset="utf-8"></head><body><p>Bitte anmelden</p>
    \(frameScript(action: "login"))
    </body></html>
    """

    private func frameHasPasswordField(_ h: Harness) async throws -> Bool {
        try await h.js("String(!!(document.getElementById('fremd').contentDocument && document.getElementById('fremd').contentDocument.querySelector('#password')))") == "true"
    }

    func testEmbeddedForeignFormIsNeverFilled() async throws {
        store.save(typed, .hildesheim, service: "cas")
        let (a, log) = try autofill(.hildesheim, "cas")
        let h = try await harness(a)
        try await loaded(h, Self.framedPage, Self.casURL)
        try await waitUntil("filled") { log.events.contains(.filled) }
        try await waitUntil("eingebetteter Rahmen steht") { try await self.frameHasPasswordField(h) }
        try await settle()
        let main = try await h.js("document.getElementById('password').value")
        XCTAssertEqual(main, "Pw-Test-123", "Hauptrahmen: vorausgefuellt")
        let frameUser = try await h.js("document.getElementById('fremd').contentDocument.querySelector('#username').value")
        let framePw = try await h.js("document.getElementById('fremd').contentDocument.querySelector('#password').value")
        XCTAssertEqual(frameUser, "")
        XCTAssertEqual(framePw, "", "nie in ein eingebettetes Formular")
        // der Kanal zur App liegt in einer eigenen Inhaltswelt: fuer Seite und Rahmen unsichtbar
        let channel = try await h.js("String(typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.uniflowLogin))")
        XCTAssertEqual(channel, "undefined")
        let frameChannel = try await h.js("String(typeof (document.getElementById('fremd').contentWindow.webkit && document.getElementById('fremd').contentWindow.webkit.messageHandlers && document.getElementById('fremd').contentWindow.webkit.messageHandlers.uniflowLogin))")
        XCTAssertEqual(frameChannel, "undefined")
        XCTAssertFalse(log.events.contains(.rejected))
        XCTAssertFalse(h.blocked.contains(.formSubmitted), "nichts abgeschickt")
        let submitted = try await h.js("String(window.__submitted || 0)")
        XCTAssertEqual(submitted, "0")

        // nur ein eingebettetes Formular: kein "ready", nichts vorausgefuellt, nichts gemerkt
        let n = log.events.count
        try await loaded(h, Self.onlyFramedPage, Self.casURL)
        try await waitUntil("eingebetteter Rahmen steht") { try await self.frameHasPasswordField(h) }
        try await settle()
        let onlyPw = try await h.js("document.getElementById('fremd').contentDocument.querySelector('#password').value")
        XCTAssertEqual(onlyPw, "")
        XCTAssertEqual(Array(log.events[n...]), [], "Unterrahmen loesen keine Nachricht aus")
        _ = try await h.js("""
        (function () { var d = document.getElementById('fremd').contentDocument;
          d.querySelector('#username').value = 'fremd'; d.querySelector('#password').value = 'fremd-pw';
          d.getElementById('fm1').requestSubmit(); return 'ok'; })()
        """)
        try await settle()
        XCTAssertEqual(Array(log.events[n...]), [])
        XCTAssertEqual(store.credential(.hildesheim, service: "cas"), typed, "nichts ueberschrieben")
    }

    /// 232: geaenderte Seite – ein Passwortfeld, das keins ist (type=text), oder gar keins: kein "ready", nichts
    /// vorausgefuellt; das Textfeld vor einem echten Passwortfeld zaehlt auch ohne die Selektoren des Profils
    /// (testUserFieldBeforePasswordIsFound)
    func testChangedFormWithoutRealPasswordFieldGetsNothing() async throws {
        store.save(typed, .hildesheim, service: "cas")
        let (a, log) = try autofill(.hildesheim, "cas")
        let h = try await harness(a)
        let textPassword = Self.casPage.replacingOccurrences(of: #"name="password" type="password""#, with: #"name="password" type="text""#)
        try await loaded(h, textPassword, Self.casURL)
        try await settle()
        let v = try await h.js("document.querySelector('#password').value")
        XCTAssertEqual(v, "", "sichtbares Textfeld wird nie mit dem Passwort befuellt")
        let u = try await h.js("document.querySelector('#username').value")
        XCTAssertEqual(u, "")
        XCTAssertTrue(log.events.isEmpty, "\(log.events)")
        let noForm = "<!doctype html><html><body><p>Anmeldung zurzeit nicht möglich</p></body></html>"
        try await loaded(h, noForm, Self.casURL)
        try await settle()
        XCTAssertTrue(log.events.isEmpty)
        // die unveraenderte Seite danach: weiterhin vorausgefuellt
        try await loaded(h, Self.casPage, Self.casURL)
        try await waitUntil("filled") { log.events.contains(.filled) }
    }

    /// 233/234: Weiterleitungen, wie der WKNavigationDelegate der Anmeldeansicht sie meldet. Zwischen den Anmeldezielen
    /// eines Dienstes (Stud.IP-Login -> WebSSO) bleibt die Ansicht scharf; die Weiterleitung nach der Anmeldung in den
    /// Dienst entschaerft sie; eine offene Weiterleitung auf einen fremden Rechner mit demselben Pfad ist nie ein Ziel.
    func testRedirectsBetweenLoginTargetsStayArmedAndLeavingDisarms() throws {
        let (a, log) = try autofill(.luh, "studip")
        a.navigationStarts(mainFrame: true, backForward: false)
        a.navigationResponds(mainFrame: true, url: Self.luhSSOURL)                  // 302 vom Stud.IP-Login zum WebSSO
        a.navigationCommitted(shownURL: Self.luhSSOURL)
        XCTAssertEqual(a.documentURL, Self.luhSSOURL)
        XCTAssertTrue(a.isArmed)
        XCTAssertTrue(a.service.allows(a.documentURL))
        // zurueck zum Stud.IP-Login (zweites Ziel desselben Dienstes)
        a.navigationStarts(mainFrame: true, backForward: false)
        a.navigationResponds(mainFrame: true, url: Self.studipLoginURL)
        a.navigationCommitted(shownURL: Self.studipLoginURL)
        XCTAssertEqual(a.documentURL, Self.studipLoginURL)
        XCTAssertTrue(a.isArmed)
        XCTAssertTrue(log.events.isEmpty)
        // nach der Anmeldung: Stud.IP-Startseite (kein Anmeldeziel) -> entschaerft, fuer den Rest der Ansicht
        let start = URL(string: "https://studip.uni-hannover.de/dispatch.php/start")!
        a.navigationStarts(mainFrame: true, backForward: false)
        a.navigationResponds(mainFrame: true, url: start)
        a.navigationCommitted(shownURL: start)
        XCTAssertNil(a.documentURL)
        XCTAssertFalse(a.isArmed)
        XCTAssertEqual(log.events, [.disarmed])
        a.navigationStarts(mainFrame: true, backForward: false)
        a.navigationResponds(mainFrame: true, url: Self.studipLoginURL)
        a.navigationCommitted(shownURL: Self.studipLoginURL)
        XCTAssertFalse(a.isArmed, "einmal verlassen bleibt verlassen")

        // offene Weiterleitung des CAS auf einen fremden Rechner, gleicher Pfad: kein Ziel, nichts entschaerft (nie dort)
        let (b, log2) = try autofill(.hildesheim, "cas")
        let foreign = URL(string: "https://phishing.example/sso/login?service=x")!
        b.navigationStarts(mainFrame: true, backForward: false)
        b.navigationResponds(mainFrame: true, url: foreign)
        b.navigationCommitted(shownURL: foreign)
        XCTAssertEqual(b.documentURL, foreign)
        XCTAssertFalse(b.service.allows(b.documentURL))
        XCTAssertTrue(log2.events.isEmpty)
        // Weiterleitung vom Anmeldepfad auf http (Herabstufung): kein Ziel
        let http = URL(string: "http://www.uni-hildesheim.de/sso/login")!
        b.navigationStarts(mainFrame: true, backForward: false)
        b.navigationResponds(mainFrame: true, url: http)
        b.navigationCommitted(shownURL: http)
        XCTAssertFalse(b.service.allows(b.documentURL))
        // Anmeldeseite, danach per Skript auf den Anmeldepfad eines anderen Dienstes derselben Hochschule gewechselt
        // (QIS der LUH): die Ansicht gehoert zum Dienst, das Ziel nicht
        let (c, _) = try autofill(.luh, "studip")
        c.navigationStarts(mainFrame: true, backForward: false)
        c.navigationResponds(mainFrame: true, url: Self.qisURL)
        c.navigationCommitted(shownURL: Self.qisURL)
        XCTAssertFalse(c.service.allows(c.documentURL), "QIS ist kein Ziel des Stud.IP-Dienstes")
    }

    // MARK: QIS der LUH mit der LUH-ID aus Stud.IP (wie am PC)

    static let qisURL = URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=0")!
    /// Aufbau wie das HIS-QIS (Felder asdf/fdsa, app/qis.py)
    static let qisPage = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <form method="post" action="/qisserver/rds?state=user&amp;type=1" onsubmit="window.__submitted = (window.__submitted || 0) + 1;">
    <input type="text" name="asdf" id="asdf"><input type="password" name="fdsa" id="fdsa">
    <input type="submit" name="submit" value="Anmelden"></form></body></html>
    """

    func testQISPrefillsTheLuhIDFromStudIPWithoutCopyingIt() async throws {
        let luhID = UniversityCredential(user: "ab1-xyz", password: "Luh-Test-3")
        store.save(luhID, .luh, service: "studip")
        store.save(typed, .hildesheim, service: "cas")
        let (a, log) = try autofill(.luh, "qis")
        XCTAssertEqual(a.fallbackLoginName, "Stud.IP")
        let h = try await harness(a)
        try await loaded(h, Self.qisPage, Self.qisURL)
        try await waitUntil("filled") { log.events.contains(.filled) }
        let u1 = try await h.js("document.querySelector('#asdf').value")
        XCTAssertEqual(u1, "ab1-xyz")
        let p1 = try await h.js("document.querySelector('#fdsa').value")
        XCTAssertEqual(p1, "Luh-Test-3")
        XCTAssertNil(store.credential(.luh, service: "qis"), "nichts kopiert")
        try await settle()
        let s1 = try await h.js("String(window.__submitted || 0)")
        XCTAssertEqual(s1, "0", "nur vorausgefuellt")

        // Schalter fuer QIS aus: auch der Rueckfall fuellt nichts vor
        a.remember = false
        try await loaded(h, Self.qisPage, Self.qisURL)
        try await waitUntil("ready 2") { log.events.filter { $0 == .ready }.count >= 2 }
        try await settle()
        XCTAssertEqual(log.events.filter { $0 == .filled }.count, 1)
        let u2 = try await h.js("document.querySelector('#asdf').value")
        XCTAssertEqual(u2, "")
        XCTAssertEqual(store.credential(.luh, service: "studip"), luhID, "Stud.IP-Daten bleiben")

        // eigene QIS-Daten gehen vor und werden unter luh.qis gemerkt
        a.remember = true
        try await loaded(h, Self.qisPage, Self.qisURL)
        try await waitUntil("filled 2") { log.events.filter { $0 == .filled }.count >= 2 }
        _ = try await h.js("(function () { document.querySelector('#asdf').value = ''; document.querySelector('#fdsa').value = ''; return 'ok'; })()")
        try await h.typeAndTapLogin(user: "ab1-xyz", password: "Qis-Eigen-1", userField: "#asdf", passwordField: "#fdsa",
                                    button: "input[type=submit]")
        try await waitUntil("saved") { log.events.contains(.saved) }
        XCTAssertEqual(store.credential(.luh, service: "qis"), UniversityCredential(user: "ab1-xyz", password: "Qis-Eigen-1"))
        XCTAssertEqual(store.credential(.luh, service: "studip"), luhID)
        try await loaded(h, Self.qisPage, Self.qisURL)
        try await waitUntil("filled 3") { log.events.filter { $0 == .filled }.count >= 3 }
        let p3 = try await h.js("document.querySelector('#fdsa').value")
        XCTAssertEqual(p3, "Qis-Eigen-1")
        // nie Daten der anderen Hochschule
        XCTAssertNil(store.prefillCredential(.hildesheim, service: "studip"))
        store.deleteAll(for: .luh)
        XCTAssertNil(store.prefillCredential(.luh, service: "qis"))
        XCTAssertEqual(store.prefillCredential(.hildesheim, service: "cas"), typed)
    }

    func testStudIPLoginHasProfile() {
        XCTAssertNotNil(UniversityLoginAutofill(university: .luh, serviceKey: "studip"))
        XCTAssertNil(UniversityLoginAutofill(university: .luh, serviceKey: "cas"), "kein Dienst der anderen Uni")
    }
}
