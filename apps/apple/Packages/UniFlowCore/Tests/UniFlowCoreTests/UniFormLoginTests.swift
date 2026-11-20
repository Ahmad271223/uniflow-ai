import Foundation
import XCTest
@testable import UniFlowCore

/// Anmeldung im Hintergrund ohne Webansicht (`UniFormLogin`, docs/HINTERGRUND-ANMELDUNG-2026-11-20.md): feste Antworten,
/// kein Netz, erfundene Zugangsdaten. Gepruefte Zusagen: Passwort hoechstens einmal und nur per POST an das Formular der
/// Hochschule; nie Abmelden, Pruefungsan-/abmeldung oder ein fremder Rechner; abgelehnt nur mit Fehlertext; still ueber
/// SSO-Weiterleitungsformulare ohne Passwort; Abbruch ist kein Urteil.
final class UniFormLoginTests: XCTestCase {
    /// Antworten nach Adresse; schreibt jede Anfrage mit
    final class Scripted: UniTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [UniRequest] = []
        let reply: @Sendable (UniRequest) -> UniResponse
        init(_ reply: @escaping @Sendable (UniRequest) -> UniResponse) { self.reply = reply }
        var requests: [UniRequest] { lock.withLock { seen } }
        func send(_ request: UniRequest) async throws -> UniResponse {
            lock.withLock { seen.append(request) }
            if Task.isCancelled { throw CancellationError() }
            return reply(request)
        }
        func download(_ request: UniRequest, to destination: URL) async throws -> UniResponse { throw CancellationError() }
    }

    static func page(_ html: String, _ url: URL, status: Int = 200, headers: [String: String] = [:]) -> UniResponse {
        UniResponse(status: status, headers: headers, finalURL: url, body: Data(html.utf8))
    }

    static func redirect(_ from: URL, to: String, cookie: String? = nil) -> UniResponse {
        var h = ["Location": to]
        if let cookie { h["Set-Cookie"] = cookie }
        return UniResponse(status: 302, headers: h, finalURL: from)
    }

    static let qisStart = QISClient.startURL
    static let qisLogin = """
        <html><head><meta charset="utf-8"></head><body><a href="/qisserver/rds?state=user&amp;type=4&amp;category=auth.logout">Abmelden?</a>
        <form name="loginform" method="post" action="/qisserver/rds?state=user&amp;type=1&amp;category=auth.login&amp;startpage=portal.vm">
        <input type="text" id="asdf" name="asdf"><input type="password" id="fdsa" name="fdsa">
        <input type="submit" class="submit" name="submit" value="Anmelden"></form>
        <a href="/qisserver/rds?state=prfAnmStudent">Prüfungsanmeldung</a></body></html>
        """
    static let qisPortal = """
        <html><body><h1>Meine Funktionen</h1><a href="https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&amp;type=4&amp;category=auth.logout">Abmelden</a></body></html>
        """
    static let credential = (username: "testnutzer-erfunden", password: "Pw-Test-erfunden-123")
    static let luh = UniversityProfile.luh
    static let luhDomains = ["uni-hannover.de"]

    static func qisDone(_ url: URL, _ html: String) -> Bool {
        let p = QISPage.parse(html: html, url: url)
        return url.host == "qis.verwaltung.uni-hannover.de" && p.isLoggedIn && !p.hasLoginForm
    }

    private func run(_ t: Scripted, entry: URL = qisStart, university: UniversityKey = .luh, domains: [String] = luhDomains,
                     credential: (username: String, password: String)? = credential,
                     isDone: @escaping (URL, String) -> Bool = qisDone) async -> UniFormLogin.Result {
        await UniFormLogin.run(transport: t, entry: entry, university: university, domains: domains, credential: credential,
                               deadline: Date().addingTimeInterval(30)) { u, h in isDone(u, h) }
    }

    private func forbiddenRequested(_ t: Scripted) -> [String] {
        t.requests.map { $0.url.absoluteString }.filter { s in
            let l = s.lowercased()
            return ["logout", "prfanm", "type=4", "abmeld"].contains { l.contains($0) }
        }
    }

    // MARK: QIS

    func testQISSignsInWithOneFormPostAndNeverTouchesLogoutOrExamRegistration() async throws {
        let posted = URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=1&category=auth.login&startpage=portal.vm")!
        let t = Scripted { r in
            if r.method == "POST" {
                return Self.redirect(r.url, to: "/qisserver/rds?state=user&type=0", cookie: "JSESSIONID=neu; Path=/; Secure")
            }
            if r.url.absoluteString.contains("type=0"), r.url != Self.qisStart { return Self.page(Self.qisPortal, r.url) }
            return Self.page(Self.qisLogin, r.url)
        }
        let result = await run(t)
        XCTAssertEqual(result, .done(passwordSent: true))
        let posts = t.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 1, "genau ein POST mit dem Passwort")
        XCTAssertEqual(posts.first?.url, posted)
        let body = String(decoding: posts.first?.body ?? Data(), as: UTF8.self)
        XCTAssertEqual(body, "asdf=testnutzer-erfunden&fdsa=Pw-Test-erfunden-123&submit=Anmelden")
        XCTAssertEqual(posts.first?.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(forbiddenRequested(t), [], "nie Abmelden oder Pruefungsanmeldung")
        XCTAssertTrue(t.requests.allSatisfy { !$0.followRedirects }, "jede Weiterleitung prueft der Ablauf selbst")
    }

    func testAlreadySignedInNeedsNoPassword() async {
        let t = Scripted { r in Self.page(Self.qisPortal, r.url) }
        let result = await run(t)
        XCTAssertEqual(result, .done(passwordSent: false))
        XCTAssertTrue(t.requests.allSatisfy { $0.method == "GET" })
    }

    func testRejectedPasswordOnlyWithErrorTextAndNeverASecondPost() async {
        let failed = Self.qisLogin.replacingOccurrences(of: "<form", with: "<p class=\"error\">Benutzername oder Passwort falsch</p><form")
        let t = Scripted { r in Self.page(r.method == "POST" ? failed : Self.qisLogin, r.url) }
        let result = await run(t)
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(t.requests.filter { $0.method == "POST" }.count, 1)
    }

    func testFormAgainWithoutErrorTextIsAFailureNotARejection() async {
        let t = Scripted { r in Self.page(Self.qisLogin, r.url) }
        let result = await run(t)
        XCTAssertEqual(result, .failed(passwordSent: true), "ohne Fehlertext nichts vergessen")
        XCTAssertEqual(t.requests.filter { $0.method == "POST" }.count, 1)
    }

    func testRedirectToLogoutOrExamRegistrationIsNeverFollowed() async {
        for target in ["/qisserver/rds?state=user&type=4&category=auth.logout", "/qisserver/rds?state=prfAnmStudent&next=x",
                       "/qisserver/rds?state=verpublish&publishContainer=x"] {
            let t = Scripted { r in
                r.method == "POST" ? Self.redirect(r.url, to: target) : Self.page(Self.qisLogin, r.url)
            }
            let result = await run(t)
            XCTAssertEqual(result, .blocked, target)
            XCTAssertEqual(forbiddenRequested(t), [], target)
            XCTAssertFalse(t.requests.contains { $0.url.absoluteString.contains("verpublish") })
        }
    }

    func testForeignHostAndHttpAreBlocked() async {
        for target in ["https://example.org/phish", "http://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=0"] {
            let t = Scripted { r in r.method == "POST" ? Self.redirect(r.url, to: target) : Self.page(Self.qisLogin, r.url) }
            let result = await run(t)
            XCTAssertEqual(result, .blocked, target)
            XCTAssertFalse(t.requests.contains { $0.url.absoluteString == target })
        }
    }

    func testCaptchaOrExtraFieldIsLeftToTheHuman() async {
        let captcha = Self.qisLogin.replacingOccurrences(of: "<input type=\"submit\"", with: "<input type=\"text\" name=\"captcha\"><input type=\"submit\"")
        let t = Scripted { r in Self.page(captcha, r.url) }
        let result = await run(t)
        XCTAssertEqual(result, .failed(passwordSent: false))
        XCTAssertTrue(t.requests.allSatisfy { $0.method == "GET" }, "kein Passwort gesendet")
    }

    func testSecondFactorPageAfterPasswordIsAFailure() async {
        let t = Scripted { r in
            r.method == "POST" ? Self.page("<html><body><form method=\"post\"><input name=\"otp\" type=\"text\"></form></body></html>", r.url)
                : Self.page(Self.qisLogin, r.url)
        }
        let result = await run(t)
        XCTAssertEqual(result, .failed(passwordSent: true))
    }

    func testWithoutCredentialNothingIsSent() async {
        let t = Scripted { r in Self.page(Self.qisLogin, r.url) }
        let result = await run(t, credential: nil)
        XCTAssertEqual(result, .needsPassword)
        XCTAssertTrue(t.requests.allSatisfy { $0.method == "GET" })
    }

    func testCancelledIsNoVerdict() async {
        let t = Scripted { r in Self.page(Self.qisLogin, r.url) }
        let task = Task { await self.run(t) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled(passwordSent: false))
        XCTAssertTrue(t.requests.allSatisfy { $0.method == "GET" })
    }

    func testDeadlineEndsTheAttempt() async {
        let t = Scripted { r in Self.page(Self.qisLogin, r.url) }
        let result = await UniFormLogin.run(transport: t, entry: Self.qisStart, university: .luh, domains: Self.luhDomains,
                                            credential: Self.credential, deadline: Date().addingTimeInterval(-1)) { _, _ in false }
        XCTAssertEqual(result, .failed(passwordSent: false))
        XCTAssertTrue(t.requests.isEmpty)
    }

    func testUmlautPasswordOnlyOnUTF8Pages() async {
        let latin = Self.qisLogin.replacingOccurrences(of: "<meta charset=\"utf-8\">", with: "")
        let t = Scripted { r in Self.page(latin, r.url, headers: ["Content-Type": "text/html; charset=ISO-8859-1"]) }
        let result = await run(t, credential: (username: "testnutzer", password: "Pässwort-erfunden"))
        XCTAssertEqual(result, .unsupported, "lieber die Webansicht als ein falsch kodiertes Passwort")
        XCTAssertTrue(t.requests.allSatisfy { $0.method == "GET" })
    }

    func testUnknownPageWithoutFormIsUnsupported() async {
        let t = Scripted { r in Self.page("<html><body>Wartung</body></html>", r.url) }
        let result = await run(t)
        XCTAssertEqual(result, .unsupported)
    }

    // MARK: WebSSO der LUH (Stud.IP), still ueber die noch gueltige Uni-Anmeldung

    static let studip = URL(string: "https://studip.uni-hannover.de/Shibboleth.sso/Login?target=x")!
    static let idp = "https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO"

    static func studipDone(_ url: URL, _ html: String) -> Bool {
        url.host == "studip.uni-hannover.de" && !url.path.contains("Shibboleth.sso")
    }

    func testStudIPSilentlyThroughIdPCheckPageAndSAMLResponse() async {
        let ls = """
            <html><body><form method="post" action="/idp/profile/SAML2/Redirect/SSO?execution=e1s1">
            <input type="hidden" name="shib_idp_ls_exception.shib_idp_session_ss" value="">
            <input type="hidden" name="shib_idp_ls_success.shib_idp_session_ss" value="false">
            <input type="hidden" name="_eventId_proceed" value=""></form></body></html>
            """
        let saml = """
            <html><body onload="document.forms[0].submit()"><form action="https://studip.uni-hannover.de/Shibboleth.sso/SAML2/POST" method="post">
            <input type="hidden" name="RelayState" value="ss:mem:1"><input type="hidden" name="SAMLResponse" value="PHNhbWw+"/>
            <noscript><input type="submit" value="Continue"/></noscript></form></body></html>
            """
        let t = Scripted { r in
            let s = r.url.absoluteString
            if s.hasPrefix("https://studip.uni-hannover.de/Shibboleth.sso/Login") { return Self.redirect(r.url, to: Self.idp + "?SAMLRequest=abc") }
            if s.hasPrefix(Self.idp), r.method == "GET" { return Self.page(ls, r.url) }
            if s.hasPrefix(Self.idp), r.method == "POST" { return Self.page(saml, r.url) }
            if s.hasSuffix("/Shibboleth.sso/SAML2/POST") {
                return Self.redirect(r.url, to: "https://studip.uni-hannover.de/dispatch.php/login?sso=shib", cookie: "_shibsession_1=x; Path=/; Secure")
            }
            if s.contains("dispatch.php/login") { return Self.redirect(r.url, to: "/dispatch.php/start", cookie: "Seminar_Session=neu; Path=/; Secure") }
            return Self.page("<html><body>Start</body></html>", r.url)
        }
        let result = await run(t, entry: Self.studip, credential: nil, isDone: Self.studipDone)
        XCTAssertEqual(result, .done(passwordSent: false))
        let posts = t.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 2, "Pruefseite und SAML-Antwort, kein Passwort")
        XCTAssertTrue(String(decoding: posts[1].body ?? Data(), as: UTF8.self).contains("SAMLResponse=PHNhbWw%2B"))
        XCTAssertFalse(posts.contains { String(decoding: $0.body ?? Data(), as: UTF8.self).contains("password") })
    }

    func testStudIPPasswordFormOncePerAttempt() async throws {
        let html = try String(contentsOf: Self.fixture("luh-websso.html"), encoding: .utf8)
        let t = Scripted { r in
            let s = r.url.absoluteString
            if s.hasPrefix("https://studip.uni-hannover.de/Shibboleth.sso/Login") { return Self.redirect(r.url, to: Self.idp + "?SAMLRequest=abc") }
            if s.hasPrefix(Self.idp), r.method == "GET" { return Self.page(html, r.url) }
            if s.hasPrefix(Self.idp), r.method == "POST" { return Self.redirect(r.url, to: "https://studip.uni-hannover.de/dispatch.php/start") }
            return Self.page("<html><body>Start</body></html>", r.url)
        }
        let silent = await run(t, entry: Self.studip, credential: nil, isDone: Self.studipDone)
        XCTAssertEqual(silent, .needsPassword)
        let result = await run(t, entry: Self.studip, isDone: Self.studipDone)
        XCTAssertEqual(result, .done(passwordSent: true))
        let posts = t.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 1)
        let body = String(decoding: posts[0].body ?? Data(), as: UTF8.self)
        XCTAssertEqual(body, "loginname=testnutzer-erfunden&password=Pw-Test-erfunden-123&_eventId_proceed=", "nie \"donotcache\" angehakt")
        XCTAssertEqual(posts[0].url.absoluteString, Self.idp + "?execution=e1s1")
    }

    func testConsentPageIsNeverSubmitted() async {
        let consent = """
            <html><body><form method="post" action="/idp/profile/SAML2/Redirect/SSO?execution=e1s3">
            <input type="checkbox" name="_shib_idp_consentIds" value="mail" checked>
            <input type="hidden" name="_shib_idp_consentOptions" value="_shib_idp_rememberConsent">
            <input type="submit" name="_eventId_proceed" value="Akzeptieren"></form></body></html>
            """
        let t = Scripted { r in
            r.url.absoluteString.hasPrefix("https://studip.uni-hannover.de/Shibboleth.sso/Login")
                ? Self.redirect(r.url, to: Self.idp + "?SAMLRequest=abc") : Self.page(consent, r.url)
        }
        let result = await run(t, entry: Self.studip, credential: nil, isDone: Self.studipDone)
        XCTAssertEqual(result, .unsupported)
        XCTAssertTrue(t.requests.allSatisfy { $0.method == "GET" }, "eine Zustimmung gibt nur der Mensch")
    }

    // MARK: CAS der Uni Hildesheim

    func testHildesheimCASFormPostAndTicketBackToLSF() async throws {
        let html = try String(contentsOf: Self.fixture("hildesheim-cas.html"), encoding: .utf8)
        let entry = URL(string: HildesheimCAS.lsfLoginURL)!
        let t = Scripted { r in
            let s = r.url.absoluteString
            if s.hasPrefix("https://www.uni-hildesheim.de/sso/login"), r.method == "GET" { return Self.page(html, r.url) }
            if s.hasPrefix("https://www.uni-hildesheim.de/sso/login") {
                return Self.redirect(r.url, to: "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=1&ticket=ST-1", cookie: "TGC=neu; Path=/sso; Secure")
            }
            return Self.page("<html><body><a href=\"rds?state=user&type=4&category=auth.logout\">Abmelden</a></body></html>", r.url)
        }
        let result = await run(t, entry: entry, university: .hildesheim, domains: ["uni-hildesheim.de"]) { u, h in
            LSFClient.isLoggedIn(html: h, url: u)
        }
        XCTAssertEqual(result, .done(passwordSent: true))
        let posts = t.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(String(decoding: posts[0].body ?? Data(), as: UTF8.self),
                       "username=testnutzer-erfunden&password=Pw-Test-erfunden-123&execution=e1s1&_eventId=submit&submit=Anmelden")
        XCTAssertEqual(forbiddenRequested(t), [])
    }

    func testHildesheimCASRejectedWithErrorPanel() async throws {
        let html = try String(contentsOf: Self.fixture("hildesheim-cas.html"), encoding: .utf8)
        let failed = try String(contentsOf: Self.fixture("hildesheim-cas-fehler.html"), encoding: .utf8)
        let entry = URL(string: HildesheimCAS.lsfLoginURL)!
        let t = Scripted { r in Self.page(r.method == "POST" ? failed : html, r.url) }
        let result = await run(t, entry: entry, university: .hildesheim, domains: ["uni-hildesheim.de"]) { _, _ in false }
        XCTAssertEqual(result, .rejected)
    }

    // MARK: Bausteine

    func testCancelledAttemptIsNeitherAFailureNorARejection() {
        var s = UniAutoLoginState()
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false, now: Date()), .relogin)
        XCTAssertEqual(UniAutoLoginMachine.finished(&s, .cancelled), .nothing)
        XCTAssertEqual(s.failures, 0)
        XCTAssertFalse(s.rejected)
        XCTAssertNil(s.lastAttempt)
    }

    func testFormEncodingAndScanner() {
        XCTAssertEqual(UniFormLogin.encode([("a b", "x&y=z+ü")]), "a+b=x%26y%3Dz%2B%C3%BC")
        let forms = UniFormScanner.forms("<form action=\"/a?x=1&amp;y=2\" method=POST><input name=h type=hidden value=1><select name=s><option value=o1>1<option value=o2 selected>2</select><button>Go</button></form>")
        XCTAssertEqual(forms.count, 1)
        XCTAssertEqual(forms[0].action, "/a?x=1&y=2")
        XCTAssertEqual(forms[0].method, "post")
        XCTAssertEqual(forms[0].fields.map(\.name), ["h", "s"])
        XCTAssertEqual(forms[0].fields.last?.value, "o2")
        XCTAssertEqual(forms[0].submits.count, 1)
        XCTAssertTrue(UniFormLogin.forbidden(URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=4")!))
        XCTAssertFalse(UniFormLogin.forbidden(QISClient.startURL))
        XCTAssertFalse(UniFormLogin.forbidden(URL(string: HildesheimCAS.lsfLoginURL)!))
    }

    static func fixture(_ name: String) -> URL {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("packages/shared-contracts").path) {
            u.deleteLastPathComponent()
        }
        return u.appendingPathComponent("packages/shared-contracts/fixtures/autologin/\(name)")
    }
}
