import Foundation
import XCTest
@testable import UniFlowCore

/// Automatisch anmelden (Entscheidung des Inhabers 06.11.2026, docs/AUTOMATISCH-ANMELDEN-2026-11-06.md): Formulare je
/// Hochschule und Rechner, die beiden Seitenskripte und der Ablauf "abgelaufen -> still anmelden -> genau ein neuer
/// Versuch". Nachgebaute Anmeldeseiten in packages/shared-contracts/fixtures/autologin (NACHGEBAUT), keine echten Daten.
final class UniAutoLoginTests: XCTestCase {
    private func fx(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/autologin/\(name)"), encoding: .utf8)
    }

    private func u(_ s: String) -> URL { URL(string: s)! }

    // MARK: Formulare je Rechner

    func testEveryPortalOfTheOwnerListHasItsForm() {
        let cases: [(String, UniversityKey, String)] = [
            ("https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO?execution=e1s1", .luh, "luh-websso"),
            ("https://qis.verwaltung.uni-hannover.de/qisserver/rds?state=user&type=0", .luh, "luh-qis"),
            ("https://kalender.uni-hannover.de/SOGo/", .luh, "luh-sogo"),
            ("https://www.uni-hildesheim.de/sso/login?service=x", .hildesheim, "hildesheim-cas"),
            ("https://uni-hildesheim.de/sso/login?service=x", .hildesheim, "hildesheim-cas-bare"),
            ("https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0", .hildesheim, "hildesheim-lsf"),
            ("https://plus.uni-hildesheim.de/qisserver/pages/cs/sys/portal/hisinoneStartPage.faces", .hildesheim, "hildesheim-plus"),
            ("https://webmail.uni-hildesheim.de/SOGo/", .hildesheim, "hildesheim-sogo"),
            ("https://moodle.hs-hannover.de/login/index.php", .hsh, "hsh-moodle"),
            ("https://idp.hs-hannover.de/simplesaml/module.php/core/loginuserpass.php?AuthState=x", .hsh, "hsh-idp"),
            ("https://campusmanagement.hs-hannover.de/qisserver/pages/cs/sys/portal/hisinoneStartPage.faces", .hsh, "hsh-campus"),
        ]
        for (url, uni, id) in cases {
            XCTAssertEqual(UniLoginForms.form(for: u(url), university: uni)?.id, id, url)
            // nie das Formular einer anderen Hochschule (eine Zugangskennung je Hochschule)
            for other in UniversityKey.allCases where other != uni {
                XCTAssertNil(UniLoginForms.form(for: u(url), university: other), "\(url) bei \(other)")
            }
        }
        XCTAssertEqual(Set(UniLoginForms.all.map(\.id)).count, UniLoginForms.all.count, "eindeutige Kennungen")
    }

    func testNoFormOnForeignHostsHttpOtherPortsOrLookalikes() {
        let bad = ["http://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO",
                   "https://sso.idm.uni-hannover.de:8443/idp/",
                   "https://sso.idm.uni-hannover.de.example.org/idp/",
                   "https://phishing.example/idp/",
                   "https://studip.uni-hannover.de/dispatch.php/login",          // Stud.IP selbst: nur ueber das WebSSO
                   "https://www.uni-hildesheim.de/learnweb2026/pluginfile.php/1/evil.html",
                   "https://qis.verwaltung.uni-hannover.de/other/",
                   "https://kalender.uni-hannover.de/other"]
        for url in bad {
            for uni in UniversityKey.allCases { XCTAssertNil(UniLoginForms.form(for: u(url), university: uni), url) }
        }
        XCTAssertTrue(UniLoginForms.allowsCapture(scheme: "https", host: "qis.verwaltung.uni-hannover.de", port: 0, path: "/qisserver/rds", university: .luh))
        XCTAssertFalse(UniLoginForms.allowsCapture(scheme: "https", host: "qis.verwaltung.uni-hannover.de", port: 0, path: "/qisserver/rds", university: .hsh))
        XCTAssertFalse(UniLoginForms.allowsCapture(scheme: "http", host: "qis.verwaltung.uni-hannover.de", port: 0, path: "/qisserver/rds", university: .luh))
        XCTAssertFalse(UniLoginForms.allowsCapture(scheme: "https", host: "evil.example", port: 0, path: "/qisserver/", university: .luh))
    }

    func testFixturesAreRecognisedAndFailurePagesTold() throws {
        let pairs: [(String, UniLoginForm)] = [("luh-websso.html", UniLoginForms.luhWebSSO), ("luh-qis.html", UniLoginForms.luhQIS),
                                               ("sogo.html", UniLoginForms.luhSOGo), ("hildesheim-cas.html", UniLoginForms.hildesheimCAS),
                                               ("hsh-moodle.html", UniLoginForms.hshMoodle), ("hsh-idp.html", UniLoginForms.hshIdP)]
        for (file, form) in pairs {
            let html = try fx(file)
            XCTAssertTrue(form.appears(in: html), file)
            XCTAssertFalse(form.showsFailure(in: html), "\(file): keine Fehlermeldung")
            // Feldnamen der Selektoren stehen wirklich in der nachgebauten Seite
            XCTAssertTrue(form.userFields.contains { sel in Self.attr(sel).map { html.contains($0) } ?? false }, "\(file): Benutzerfeld")
            XCTAssertTrue(form.passwordFields.contains { sel in Self.attr(sel).map { html.contains($0) } ?? false }, "\(file): Passwortfeld")
        }
        XCTAssertTrue(UniLoginForms.luhWebSSO.showsFailure(in: try fx("luh-websso-fehler.html")))
        XCTAssertTrue(UniLoginForms.hildesheimCAS.showsFailure(in: try fx("hildesheim-cas-fehler.html")))
        XCTAssertFalse(UniLoginForms.luhQIS.appears(in: "<html><a href=\"x\">Abmelden</a></html>"), "ohne Passwortfeld kein Formular")
    }

    /// `input[name="fdsa"]` -> `name="fdsa"`, `input#fdsa` -> `id="fdsa"`
    static func attr(_ selector: String) -> String? {
        if let r = selector.range(of: "[name=\"") {
            let rest = selector[r.upperBound...]
            return rest.firstIndex(of: "\"").map { "name=\"\(rest[..<$0])\"" }
        }
        if let r = selector.range(of: "#") { return "id=\"\(selector[r.upperBound...])\"" }
        if let r = selector.range(of: "[ng-model=\"") {
            let rest = selector[r.upperBound...]
            return rest.firstIndex(of: "\"").map { "ng-model=\"\(rest[..<$0])\"" }
        }
        return nil
    }

    func testRealFieldNamesFromTheExistingCode() {
        // app/studip_sync.py (loginname/password, _eventId_proceed), app/qis.py (asdf/fdsa), app/cas.py (username/password)
        XCTAssertEqual(UniLoginForms.luhWebSSO.userFields.first, "input[name=\"loginname\"]")
        XCTAssertTrue(UniLoginForms.luhWebSSO.submitButtons.contains("button[name=\"_eventId_proceed\"]"))
        XCTAssertEqual(UniLoginForms.luhQIS.userFields.first, "input[name=\"asdf\"]")
        XCTAssertEqual(UniLoginForms.luhQIS.passwordFields.first, "input[name=\"fdsa\"]")
        XCTAssertTrue(UniLoginForms.hildesheimCAS.passwordFields.contains("input[name=\"password\"]"))
        // HISinOne: der versteckte Dialog "Sitzung abgelaufen" auf jeder Seite zaehlt nie
        XCTAssertTrue(UniLoginForms.hshCampus.ignoredContainers.contains("#sessionTimeoutDialog"))
        XCTAssertTrue(UniLoginForms.hildesheimPLuS.ignoredContainers.contains("#sessionTimeoutDialog"))
    }

    // MARK: Seitenskripte

    func testCaptureScriptNamesOnlyTheOwnFormsAndPostsOnlyToTheHandler() {
        let s = UniLoginForms.captureScript(university: .luh, handler: "studinowCredential")
        XCTAssertTrue(s.contains("sso.idm.uni-hannover.de") && s.contains("qis.verwaltung.uni-hannover.de") && s.contains("kalender.uni-hannover.de"))
        XCTAssertFalse(s.contains("uni-hildesheim.de") || s.contains("hs-hannover.de"), "keine fremde Hochschule")
        XCTAssertTrue(s.contains("loc.protocol !== 'https:'"), "nur HTTPS")
        XCTAssertEqual(s.components(separatedBy: "postMessage(").count - 1, 1, "genau ein Kanal")
        XCTAssertTrue(s.contains("messageHandlers.studinowCredential.postMessage"))
        XCTAssertFalse(s.contains("fetch(") || s.contains("XMLHttpRequest") || s.contains("sendBeacon") || s.contains(".src ="), "nie ins Netz")
        XCTAssertFalse(s.contains(".value ="), "veraendert kein Feld")
    }

    func testFillFunctionChecksTheHostItselfAndHasNoSecretInside() {
        let f = UniLoginForms.fillFunctionBody
        XCTAssertTrue(f.contains("host !== spec.host"))
        XCTAssertTrue(f.contains("loc.protocol !== 'https:'"))
        XCTAssertTrue(f.contains("setter.call(el, v)") && f.contains("new Event('input'"), "Frameworks (SOGo/Angular) sehen die Eingabe")
        XCTAssertFalse(f.contains("fetch(") || f.contains("XMLHttpRequest") || f.contains("postMessage"), "nie ins Netz, kein Kanal")
        XCTAssertTrue(f.contains("donotcache"), "Shibboleth 'Anmeldung nicht speichern' bleibt aus")
        // Beschreibung ohne Geheimnisse
        let spec = UniLoginForms.luhQIS.spec
        XCTAssertEqual(spec["host"] as? String, "qis.verwaltung.uni-hannover.de")
        XCTAssertNil(spec["pass"].flatMap { $0 as? String })
    }

    func testValueRules() {
        XCTAssertTrue(UniLoginForms.isAcceptableUsername("abc-123-sso"))
        XCTAssertFalse(UniLoginForms.isAcceptableUsername("mit leer"))
        XCTAssertFalse(UniLoginForms.isAcceptableUsername(""))
        XCTAssertFalse(UniLoginForms.isAcceptableUsername(String(repeating: "a", count: 129)))
        XCTAssertTrue(UniLoginForms.isAcceptablePassword("Pw mit Leerzeichen-erfunden"))
        XCTAssertFalse(UniLoginForms.isAcceptablePassword("a\u{0}b"))
        XCTAssertFalse(UniLoginForms.isAcceptablePassword(""))
        XCTAssertFalse(UniLoginForms.isAcceptablePassword(String(repeating: "a", count: 257)))
    }

    // MARK: Schritte der unsichtbaren Webansicht

    func testFlowFillsOnceDetectsRejectionAbortsOnForeignHosts() throws {
        let domains = ["uni-hannover.de"]
        let sso = u("https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO?execution=e1s1")
        let form = try fx("luh-websso.html")
        XCTAssertEqual(UniAutoLoginFlow.step(url: sso, html: form, university: .luh, domains: domains, submitted: [], isDone: false),
                       .fill(UniLoginForms.luhWebSSO))
        XCTAssertEqual(UniAutoLoginFlow.step(url: sso, html: try fx("luh-websso-fehler.html"), university: .luh, domains: domains,
                                             submitted: ["luh-websso"], isDone: false), .rejected, "Formular nach dem Absenden wieder da")
        XCTAssertEqual(UniAutoLoginFlow.step(url: u("https://studip.uni-hannover.de/dispatch.php/start"), html: "", university: .luh,
                                             domains: domains, submitted: ["luh-websso"], isDone: true), .done)
        XCTAssertEqual(UniAutoLoginFlow.step(url: u("https://studip.uni-hannover.de/Shibboleth.sso/SAML2/POST"), html: "", university: .luh,
                                             domains: domains, submitted: [], isDone: false), .wait)
        XCTAssertEqual(UniAutoLoginFlow.step(url: u("https://phishing.example/idp/"), html: form, university: .luh, domains: domains,
                                             submitted: [], isDone: false), .abort)
        XCTAssertEqual(UniAutoLoginFlow.step(url: u("http://sso.idm.uni-hannover.de/idp/"), html: form, university: .luh, domains: domains,
                                             submitted: [], isDone: false), .abort)
        XCTAssertEqual(UniAutoLoginFlow.step(url: u("https://sso.idm.uni-hannover.de/idp/"), html: form, university: .luh, domains: domains,
                                             submitted: ["a", "b", "c"], isDone: false), .rejected, "hoechstens drei Formulare")
        // HISinOne angemeldet mit verstecktem Dialog: Erfolg, nie ein Formular
        XCTAssertEqual(UniAutoLoginFlow.step(url: u("https://campusmanagement.hs-hannover.de/qisserver/pages/x.faces"),
                                             html: try fx("hisinone-angemeldet.html"), university: .hsh,
                                             domains: ["hs-hannover.de"], submitted: [], isDone: true), .done)
        XCTAssertTrue(UniAutoLoginFlow.allowed(URL(string: "about:blank"), domains: domains))
    }

    // MARK: Wann still angemeldet wird

    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func testExpiryReloginRetryOnceThenSuccessResets() {
        var s = UniAutoLoginState()
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false, now: t0), .relogin)
        XCTAssertEqual(UniAutoLoginMachine.finished(&s, .success), .retryOnce)
        XCTAssertTrue(s.awaitingRetry)
        UniAutoLoginMachine.succeeded(&s)
        XCTAssertEqual(s.failures, 0)
        XCTAssertFalse(s.awaitingRetry)
        // naechster Ablauf nach der Mindestpause: wieder still
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                                   now: t0.addingTimeInterval(61)), .relogin)
    }

    func testRetryExpiringAgainStopsNoLoop() {
        var s = UniAutoLoginState()
        _ = UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false, now: t0)
        _ = UniAutoLoginMachine.finished(&s, .success)
        // der eine neue Versuch ist wieder abgelaufen: Schluss
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                                   now: t0.addingTimeInterval(5)), .needsUser)
        // und gleich danach keine neue Runde (Ruecknahme)
        if case .wait = UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                                    now: t0.addingTimeInterval(10)) {} else { XCTFail("Ruecknahme erwartet") }
        // hundert Ablaeufe in einer Minute: hoechstens die eine stille Anmeldung vom Anfang
        var t = UniAutoLoginState()
        var relogins = 0
        for i in 0..<100 {
            if UniAutoLoginMachine.expired(&t, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                           now: t0.addingTimeInterval(Double(i) * 0.5)) == .relogin {
                relogins += 1
                _ = UniAutoLoginMachine.finished(&t, .success)
            }
        }
        XCTAssertEqual(relogins, 1)
        // am naechsten Tag ist ein Ablauf nach einer stillen Anmeldung ein neuer Ablauf, kein gescheiterter Versuch
        var d = UniAutoLoginState()
        _ = UniAutoLoginMachine.expired(&d, enabled: true, hasCredential: true, appActive: true, signingOut: false, now: t0)
        _ = UniAutoLoginMachine.finished(&d, .success)
        XCTAssertEqual(UniAutoLoginMachine.expired(&d, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                                   now: t0.addingTimeInterval(86_400)), .relogin)
    }

    func testWrongPasswordNeedsTheUserUntilANewSignIn() {
        var s = UniAutoLoginState()
        _ = UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false, now: t0)
        XCTAssertEqual(UniAutoLoginMachine.finished(&s, .wrongPassword), .needsUser)
        XCTAssertTrue(s.rejected)
        // auch Stunden spaeter und auf Knopfdruck nie mit dem abgelehnten Passwort
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                                   userAction: true, now: t0.addingTimeInterval(86_400)), .needsUser)
        UniAutoLoginMachine.reset(&s)                     // neue Anmeldung, neues Passwort mitgelesen
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                                   now: t0.addingTimeInterval(86_401)), .relogin)
    }

    func testNeverWhileSigningOutInBackgroundWithoutPasswordOrSwitchedOff() {
        var s = UniAutoLoginState()
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: true, now: t0), .nothing)
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: false, signingOut: false, now: t0), .nothing)
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: false, hasCredential: true, appActive: true, signingOut: false, now: t0), .needsUser)
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: false, appActive: true, signingOut: false, now: t0), .needsUser)
        XCTAssertNil(s.lastAttempt, "kein Versuch gezaehlt")
        _ = UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false, now: t0)
        XCTAssertEqual(UniAutoLoginMachine.finished(&s, .success, signingOut: true), .nothing, "Abmelden waehrend der Anmeldung: kein neuer Versuch")
    }

    func testFailuresBackOffAndUserActionSkipsTheWait() {
        var s = UniAutoLoginState()
        _ = UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false, now: t0)
        XCTAssertEqual(UniAutoLoginMachine.finished(&s, .failed), .needsUser)
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                                   now: t0.addingTimeInterval(60)), .wait(until: t0.addingTimeInterval(300)))
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                                   userAction: true, now: t0.addingTimeInterval(60)), .relogin)
        _ = UniAutoLoginMachine.finished(&s, .blocked)
        XCTAssertEqual(UniAutoLoginMachine.backoff(failures: 2), 600)
        // drei Fehlschlaege in Folge: nur noch auf Knopfdruck (nie eine Kontosperre durch Fehlversuche)
        _ = UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                        userAction: true, now: t0.addingTimeInterval(120))
        _ = UniAutoLoginMachine.finished(&s, .failed)
        XCTAssertEqual(s.failures, 3)
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                                   now: t0.addingTimeInterval(86_400)), .needsUser)
        XCTAssertEqual(UniAutoLoginMachine.expired(&s, enabled: true, hasCredential: true, appActive: true, signingOut: false,
                                                   userAction: true, now: t0.addingTimeInterval(86_400)), .relogin)
        XCTAssertEqual(UniAutoLoginMachine.backoff(failures: 20), UniAutoLoginMachine.maxBackoff)
    }
}
