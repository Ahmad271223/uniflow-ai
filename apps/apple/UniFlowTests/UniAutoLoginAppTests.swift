import Security
import SwiftUI
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Automatisch anmelden (Entscheidung des Inhabers 06.11.2026, docs/AUTOMATISCH-ANMELDEN-2026-11-06.md): Schluesselbund
/// nur dieses Geraets, Mitlesen nur auf dem echten Formular der eigenen Hochschule, Einfuellen nur dort, stille
/// Anmeldung "abgelaufen -> anmelden -> genau ein neuer Versuch", falsches Passwort -> "Anmeldung nötig", Loeschen.
/// Kein Netz: nachgebaute Seiten (packages/shared-contracts/fixtures/autologin) mit `loadHTMLString`, eine Inhaltsregel
/// blockiert jedes Nachladen, jedes Absenden wird abgefangen. Nur erfundene Zugangsdaten.
@MainActor
final class UniAutoLoginAppTests: XCTestCase {
    private let user = "testnutzer-erfunden"
    private let password = "Pw-Test-erfunden-123"
    private var services: [String] = []

    override func tearDown() async throws {
        UniAutoLogin.runnerOverride = nil
        UniAutoLogin.appActiveOverride = nil
        for s in services { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary) }
        services = []
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: ContainerTestBed.repoURL("packages/shared-contracts/fixtures/autologin/\(name)"), encoding: .utf8)
    }

    private func testVault() -> UniCredentialStore {
        let service = "de.uniflow.ai.uni-login.test.\(UUID().uuidString)"
        services.append(service)
        return UniCredentialStore(service: service, container: UUID())
    }

    /// Datenspeicher wie ein Container (angemeldet bei `UniAutoLogin`)
    private func attachedStore(_ uni: UniversityKey, defaults: UserDefaults? = nil) -> (WKWebsiteDataStore, UniCredentialStore, UserDefaults) {
        let store = WKWebsiteDataStore.nonPersistent()
        let d = defaults ?? UserDefaults(suiteName: "uniflow.tests.autologin.\(UUID().uuidString)")!
        let vault = testVault()
        UniAutoLogin.attach(store, university: uni, defaults: d, vault: vault)
        addTeardownBlock { @MainActor in UniAutoLogin.detach(store) }
        return (store, vault, d)
    }

    // MARK: Schluesselbund

    func testKeychainItemIsThisDeviceOnlyAndNeverSynchronized() throws {
        let vault = testVault()
        let c = UniCredential(username: user, password: password, savedAt: Date())
        try vault.save(c)
        XCTAssertEqual(vault.load(), c)
        let a = try XCTUnwrap(vault.attributes())
        XCTAssertEqual(a.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(a.synchronizable, false)
        // kein Eintrag, den die Aufraeumregel fuer alte App-Passwoerter loeschen wuerde, und eigener Dienst
        XCTAssertFalse(UniversityProfile.isRetiredLoginSecret(vault.account))
        XCTAssertTrue(vault.account.hasPrefix(UniCredentialStore.accountPrefix))
        XCTAssertNotEqual(UniCredentialStore.service, StudIPCookieStore.service)
        // ein synchronisierter Eintrag desselben Namens wird nie gelesen
        XCTAssertTrue(vault.clear())
        XCTAssertNil(vault.load())
        XCTAssertTrue(vault.clear(), "nichts da gilt als Erfolg")
    }

    // MARK: Mitlesen: nur Welt, Hauptrahmen, Formular-Rechner der eigenen Hochschule

    func testCaptureAcceptsOnlyTheOwnWorldMainFrameAndFormHost() {
        let qis = URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=0")!
        let body: [String: Any] = ["user": user, "pass": password, "form": "luh-qis"]
        func ok(world: Bool = true, main: Bool = true, scheme: String = "https", host: String = "qis.verwaltung.uni-hannover.de",
                port: Int = 0, url: URL? = qis, body: Any = body, uni: UniversityKey = .luh) -> Bool {
            UniCredentialCapture.accept(world: world, mainFrame: main, scheme: scheme, host: host, port: port, frameURL: url,
                                        body: body, university: uni) != nil
        }
        XCTAssertTrue(ok())
        XCTAssertFalse(ok(world: false), "Seitenwelt")
        XCTAssertFalse(ok(main: false), "eingebetteter Rahmen")
        XCTAssertFalse(ok(scheme: "http"))
        XCTAssertFalse(ok(port: 8443))
        XCTAssertFalse(ok(host: "phishing.example", url: URL(string: "https://phishing.example/qisserver/")!))
        XCTAssertFalse(ok(url: URL(string: "https://qis.verwaltung.uni-hannover.de/anderes/")!), "anderer Pfad")
        XCTAssertFalse(ok(url: URL(string: "https://studip.uni-hannover.de/dispatch.php/login")!), "Adresse passt nicht zur Herkunft")
        XCTAssertFalse(ok(uni: .hildesheim), "Formular einer anderen Hochschule")
        XCTAssertFalse(ok(body: "nur Text"))
    }

    // MARK: Echte Webansichten ohne Netz

    final class Harness: NSObject, WKNavigationDelegate {
        let webView: WKWebView
        private(set) var finished = 0
        private(set) var submissions = 0
        private var allowNext = false

        init(config: WKWebViewConfiguration, rules: WKContentRuleList) {
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
            if allowNext, navigationAction.navigationType == .other {
                allowNext = false
                decisionHandler(.allow)
            } else {
                if navigationAction.navigationType == .formSubmitted || navigationAction.navigationType == .formResubmitted { submissions += 1 }
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished += 1 }

        func js(_ script: String) async throws -> String {
            let v = try await webView.evaluateJavaScript(script)
            return v.map { "\($0)" } ?? ""
        }
    }

    private func harness(_ config: WKWebViewConfiguration) async throws -> Harness {
        let rules = #"[{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}]"#
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "uniflow.tests.blockall.autologin",
                                                                                      encodedContentRuleList: rules)
        let h = Harness(config: config, rules: try XCTUnwrap(list))
        // im Fenster (wie die unsichtbare Webansicht der App), damit Layout und Sichtbarkeit gelten
        if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.addSubview(h.webView)
            addTeardownBlock { @MainActor in h.webView.removeFromSuperview() }
        }
        return h
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Zeitueberschreitung: \(what)")
    }

    private func expectJS(_ h: Harness, _ script: String, _ expected: String, _ message: String = "",
                          file: StaticString = #filePath, line: UInt = #line) async throws {
        let v = try await h.js(script)
        XCTAssertEqual(v, expected, message, file: file, line: line)
    }

    private func loaded(_ h: Harness, _ html: String, _ url: URL) async throws {
        let before = h.finished
        h.load(html, at: url)
        try await waitUntil("Seite geladen") { h.finished > before }
    }

    /// Wie ein Mensch tippen und "Anmelden" tippen (Seitenwelt, nicht die App)
    private func typeAndSubmit(_ h: Harness) async throws {
        _ = try await h.js("""
        (function () {
          var inputs = document.querySelectorAll('input');
          for (var i = 0; i < inputs.length; i++) {
            var t = String(inputs[i].type || 'text').toLowerCase();
            if (t === 'password') inputs[i].value = '\(password)';
            else if (t === 'text' || t === 'email') inputs[i].value = '\(user)';
          }
          var b = document.querySelector('button[type=submit], input[type=submit]');
          if (b) b.click(); else document.forms[0].requestSubmit();
          return 'ok';
        })()
        """)
    }

    func testTypedLoginIsCapturedOnTheRealFormAndStoredOnlyAfterSuccess() async throws {
        let (store, vault, _) = attachedStore(.luh)
        let config = StudIPWebView.loginConfiguration(dataStore: store)
        XCTAssertTrue(UniCredentialCapture.install(in: config, dataStore: store))
        XCTAssertEqual(config.userContentController.userScripts.count, 1)
        XCTAssertTrue(config.userContentController.userScripts[0].isForMainFrameOnly)
        let h = try await harness(config)
        let qis = URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=0")!
        try await loaded(h, try fixture("luh-qis.html"), qis)
        let before = h.submissions
        try await typeAndSubmit(h)
        try await waitUntil("Absenden abgefangen") { h.submissions > before }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(vault.load(), "vor dem Erfolg nichts im Schluesselbund")
        // Seite und Kanal: die Seite sieht keinen Kanal der App
        try await expectJS(h, "String(!!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(UniAutoLogin.handlerName)))", "false")
        XCTAssertTrue(UniAutoLogin.signedIn(store), "Anmeldung gelungen: jetzt merken")
        XCTAssertEqual(vault.load()?.username, user)
        XCTAssertEqual(vault.load()?.password, password)
        XCTAssertEqual(UniAutoLogin.storedUsername(store), user)
    }

    func testNothingIsCapturedOnForeignHostsOrWithTheSwitchOff() async throws {
        let (store, vault, _) = attachedStore(.luh)
        let config = StudIPWebView.loginConfiguration(dataStore: store)
        UniCredentialCapture.install(in: config, dataStore: store)
        let h = try await harness(config)
        let html = try fixture("luh-qis.html")
        for url in [URL(string: "https://phishing.example/qisserver/rds")!, URL(string: "https://qis.verwaltung.uni-hannover.de.example.org/qisserver/")!,
                    URL(string: "https://www.uni-hildesheim.de/sso/login")!, URL(string: "https://studip.uni-hannover.de/dispatch.php/login")!] {
            try await loaded(h, html, url)
            let n = h.submissions
            try await typeAndSubmit(h)
            try await waitUntil("Absenden abgefangen") { h.submissions > n }
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertFalse(UniAutoLogin.signedIn(store), url.absoluteString)
        }
        // Schalter aus: auch auf dem echten Formular nichts
        UniAutoLogin.setEnabled(false, store: store)
        try await loaded(h, html, URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=0")!)
        let n = h.submissions
        try await typeAndSubmit(h)
        try await waitUntil("Absenden abgefangen") { h.submissions > n }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(UniAutoLogin.signedIn(store))
        XCTAssertNil(vault.load())
    }

    // MARK: Einfuellen nur auf dem Formular

    private func fillHarness() async throws -> Harness {
        try await harness(StudIPWebView.loginConfiguration(dataStore: .nonPersistent()))
    }

    func testFillPutsTheValuesIntoTheFormOfEachPortalAndSubmitsOnce() async throws {
        let cred = UniCredential(username: user, password: password, savedAt: Date())
        let cases: [(String, String, UniLoginForm, String, String)] = [
            ("luh-websso.html", "https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO?execution=e1s1", UniLoginForms.luhWebSSO, "loginname", "password"),
            ("luh-qis.html", "https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=0", UniLoginForms.luhQIS, "asdf", "fdsa"),
            ("hildesheim-cas.html", "https://www.uni-hildesheim.de/sso/login?service=x", UniLoginForms.hildesheimCAS, "username", "password"),
            ("hsh-moodle.html", "https://moodle.hs-hannover.de/login/index.php", UniLoginForms.hshMoodle, "username", "password"),
            ("hsh-idp.html", "https://idp.hs-hannover.de/simplesaml/module.php/core/loginuserpass.php?AuthState=x", UniLoginForms.hshIdP, "username", "password"),
            ("sogo.html", "https://kalender.uni-hannover.de/SOGo/", UniLoginForms.luhSOGo, "userName", "password"),
        ]
        let h = try await fillHarness()
        for (file, url, form, userName, passName) in cases {
            try await loaded(h, try fixture(file), URL(string: url)!)
            // Frameworks wie SOGo (Angular) hoeren auf "input": zaehlen
            _ = try await h.js("window.__inputs = 0; document.addEventListener('input', function () { window.__inputs++; }, true); 'ok'")
            let n = h.submissions
            let r = await UniAutoLoginWeb.fill(h.webView, form: form, credential: cred)
            XCTAssertEqual(r, "submitted", file)
            try await waitUntil("abgesendet (\(file))") { h.submissions > n }
            try await expectJS(h, "document.querySelector('[name=\"\(userName)\"]').value", user, file)
            try await expectJS(h, "document.querySelector('[name=\"\(passName)\"]').value", password, file)
            try await expectJS(h, "String(window.__inputs >= 2)", "true", "\(file): input-Ereignisse")
            if file == "luh-websso.html" {
                try await expectJS(h, "String(document.getElementById('donotcache').checked)", "false", "nicht speichern bleibt aus")
            }
            if file == "sogo.html" {
                try await expectJS(h, "String(document.querySelector('[name=rememberLogin]').checked)", "true")
            }
        }
    }

    func testFillRefusesForeignHostsAndHiddenDialogs() async throws {
        let cred = UniCredential(username: user, password: password, savedAt: Date())
        let h = try await fillHarness()
        try await loaded(h, try fixture("luh-qis.html"), URL(string: "https://phishing.example/qisserver/rds")!)
        do { let v = await UniAutoLoginWeb.fill(h.webView, form: UniLoginForms.luhQIS, credential: cred); XCTAssertEqual(v, "host") }
        try await expectJS(h, "document.getElementById('fdsa').value", "", "nichts eingefuellt")
        // HISinOne angemeldet: der versteckte Dialog "Sitzung abgelaufen" bekommt nie das Passwort
        try await loaded(h, try fixture("hisinone-angemeldet.html"), URL(string: "https://campusmanagement.hs-hannover.de/qisserver/pages/x.faces")!)
        do { let v = await UniAutoLoginWeb.fill(h.webView, form: UniLoginForms.hshCampus, credential: cred); XCTAssertEqual(v, "nofield") }
        try await expectJS(h, "document.getElementById('fdsa').value", "")
        XCTAssertEqual(h.submissions, 0)
        // Einstieg auf fremdem Rechner oder http: die unsichtbare Anmeldung beginnt gar nicht
        let (store, _, _) = attachedStore(.luh)
        for entry in ["https://phishing.example/idp/", "http://qis.verwaltung.uni-hannover.de/qisserver/"] {
            let r = UniAutoLoginRequest(portal: "qis", university: .luh, store: store, entry: URL(string: entry)!, credential: cred) { _, _ in false }
            do { let v = await UniAutoLoginWeb.attempt(r); XCTAssertEqual(v, .failed, entry) }
        }
    }

    // MARK: Stille Anmeldung an einer Verbindung (QIS), unsichtbare Webansicht ersetzt

    private func luhBed(_ name: String) throws -> (ContainerTestBed, ContainerManager, QISConnection, UniCredentialStore) {
        let bed = try ContainerTestBed(name: name, clock: .fixed(berlin: "2026-11-06T09:00:00")!)
        let m = bed.manager()
        let c = try bed.open(m, bed.account(.luh))
        services.append(m.credentialService)
        let qis = try XCTUnwrap(m.qis)
        qis.syncsAfterSignIn = false
        return (bed, m, qis, UniCredentialStore(service: m.credentialService, container: c.layout.identifier))
    }

    func testExpiryReloginRetryOnceAndNoLoop() async throws {
        let (bed, _, qis, vault) = try luhBed("autologin-qis")
        XCTAssertNotEqual(vault.store.service, UniCredentialStore.service, "Tests nie im echten Dienst")
        try vault.save(UniCredential(username: user, password: password, savedAt: Date()))
        UniAutoLogin.appActiveOverride = true
        var requests: [UniAutoLoginRequest] = []
        UniAutoLogin.runnerOverride = { r in requests.append(r); return .success }
        qis.signedIn()
        qis.certificatesExpired()                                  // Sitzung abgelaufen ("Anmeldung nötig")
        XCTAssertEqual(qis.state, .needsLogin)
        let ok = await qis.autoLogin()
        XCTAssertTrue(ok)
        XCTAssertEqual(qis.state, .connected, "still angemeldet, Abruf genau einmal")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.entry, QISClient.startURL)
        XCTAssertEqual(requests.first?.credential.username, user)
        XCTAssertTrue(UniAutoLoginFlow.allowed(requests.first?.entry, domains: UniWebSessions.domains(.luh)))
        // der eine neue Versuch ist wieder abgelaufen: keine zweite Runde
        qis.certificatesExpired()
        let again = await qis.autoLogin()
        XCTAssertFalse(again)
        XCTAssertEqual(qis.state, .needsLogin)
        for _ in 0..<5 { _ = await qis.autoLogin() }
        XCTAssertEqual(requests.count, 1, "keine Schleife")
        await bed.tearDown()
    }

    func testWrongPasswordShowsLoginNeededAndDeletesNothing() async throws {
        let (bed, _, qis, vault) = try luhBed("autologin-falsch")
        try vault.save(UniCredential(username: user, password: password, savedAt: Date()))
        UniAutoLogin.appActiveOverride = true
        var count = 0
        UniAutoLogin.runnerOverride = { _ in count += 1; return .wrongPassword }
        qis.signedIn()
        qis.certificatesExpired()
        let ok = await qis.autoLogin()
        XCTAssertFalse(ok)
        XCTAssertEqual(qis.state, .needsLogin, "Anmeldung nötig")
        XCTAssertNotNil(vault.load(), "nichts automatisch geloescht")
        XCTAssertTrue(UniAutoLogin.wasRejected(qis.websiteDataStore))
        _ = await qis.autoLogin(userAction: true)
        XCTAssertEqual(count, 1, "nie wieder mit dem abgelehnten Passwort")
        await bed.tearDown()
    }

    func testNoSilentLoginWithoutPasswordInBackgroundOrAfterSignOut() async throws {
        let (bed, _, qis, vault) = try luhBed("autologin-ohne")
        var count = 0
        UniAutoLogin.runnerOverride = { _ in count += 1; return .success }
        UniAutoLogin.appActiveOverride = true
        qis.signedIn()
        qis.certificatesExpired()
        _ = await qis.autoLogin()
        XCTAssertEqual(count, 0, "ohne gespeichertes Passwort nichts")
        try vault.save(UniCredential(username: user, password: password, savedAt: Date()))
        UniAutoLogin.appActiveOverride = false
        _ = await qis.autoLogin()
        XCTAssertEqual(count, 0, "im Hintergrund nie")
        UniAutoLogin.appActiveOverride = true
        await qis.signOut()
        XCTAssertNil(vault.load(), "Abmelden loescht das gemerkte Passwort")
        _ = await qis.autoLogin()
        XCTAssertEqual(count, 0, "abgemeldet: nichts")
        await bed.tearDown()
    }

    // MARK: Einstellungen und Loeschen

    func testSettingsSwitchDeleteAndUniversityDeletionRemoveTheItem() async throws {
        let (bed, m, qis, vault) = try luhBed("autologin-loeschen")
        let store = qis.websiteDataStore
        let c = UniCredential(username: user, password: password, savedAt: Date())
        try vault.save(c)
        XCTAssertTrue(UniAutoLogin.isEnabled(store), "Vorgabe an")
        XCTAssertEqual(UniAutoLogin.storedUsername(store), user)
        XCTAssertTrue(UniAutoLogin.forget(store), "Gespeichertes Passwort löschen")
        XCTAssertNil(vault.load())
        try vault.save(c)
        UniAutoLogin.setEnabled(false, store: store)
        XCTAssertNil(vault.load(), "Schalter aus: kein Passwort mehr auf dem Geraet")
        XCTAssertNil(UniAutoLogin.credential(store))
        UniAutoLogin.setEnabled(true, store: store)
        try vault.save(c)
        let problem = await m.deleteUniversityData(DataContainerKey(userID: bed.user, university: .luh))
        XCTAssertNil(problem)
        XCTAssertNil(vault.load(), "Daten dieser Hochschule löschen")
        try vault.save(c)
        _ = await m.deleteAllData(userID: bed.user)
        XCTAssertNil(vault.load(), "Konto löschen")
        XCTAssertEqual(UniAutoLoginCard.usernameText(user), "Gespeichert für: \(user)")
        XCTAssertTrue(UniAutoLoginCard.text(.luh).contains("nur auf diesem \(UFDevice.name)"))
        XCTAssertTrue(UniRememberPasswordToggle.title.hasPrefix("Passwort auf diesem \(UFDevice.name) merken"))
        XCTAssertEqual(UniRememberPasswordToggle.note, "Nur auf diesem Gerät im Schlüsselbund, nie auf unseren Servern")
        await bed.tearDown()
    }
}
