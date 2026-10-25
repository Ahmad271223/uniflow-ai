import Foundation
import XCTest
@testable import UniFlowCore

/// Hochschul-Profile (wie app/universities.py), CAS-Regeln (wie app/cas.py und test_cas_urls) und die Hashwerte.
/// Ohne Netzwerk; die Adressen werden nur verglichen, nie aufgerufen.
final class UniversityProfileTests: XCTestCase {

    // MARK: Profile

    func testKeysLikePython() {
        XCTAssertEqual(UniversityKey.default, .luh)
        XCTAssertTrue(UniversityKey.valid("luh"))
        XCTAssertTrue(UniversityKey.valid("hildesheim"))
        XCTAssertFalse(UniversityKey.valid("tuebingen"))
        XCTAssertFalse(UniversityKey.valid(" Hildesheim "), "kein Raten aus Schreibweisen")
        XCTAssertFalse(UniversityKey.valid(nil))
        XCTAssertNil(UniversityProfile.profile(forKey: "../etc"), "unbekannt ergibt nie still die LUH")
        XCTAssertEqual(UniversityProfile.profile(forKey: "hildesheim")?.key, .hildesheim)
        XCTAssertEqual(Set(UniversityKey.allCases.map(\.rawValue)), LocalSettings.knownUniversities)
    }

    func testProfilesMatchUniversitiesPy() {
        let l = UniversityProfile.luh, h = UniversityProfile.hildesheim
        XCTAssertEqual([l.name, l.short, l.filesSource, l.gradesSource, l.login, l.userLabel],
                       ["Leibniz Universität Hannover", "LUH", "Stud.IP", "QIS", "WebSSO (LUH-ID)", "LUH-ID"])
        XCTAssertEqual([h.name, h.short, h.filesSource, h.gradesSource, h.login, h.userLabel],
                       ["Universität Hildesheim", "Uni Hildesheim", "Learnweb", "LSF", "UNI-Account (CAS)", "Zugangskennung (UNI-Account)"])
        XCTAssertEqual(h.casBase?.absoluteString, "https://www.uni-hildesheim.de/sso")
        XCTAssertEqual(h.learnwebBase?.absoluteString, "https://www.uni-hildesheim.de/learnweb2026")
        XCTAssertEqual(h.lsfBase?.absoluteString, "https://lsf.uni-hildesheim.de")
        XCTAssertEqual(l.studipBase?.absoluteString, "https://studip.uni-hannover.de")
        XCTAssertEqual(h.qisStart?.absoluteString, "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0")
        XCTAssertNil(l.casBase)
        XCTAssertNil(h.studipBase)
        XCTAssertEqual(l.gradeLayout, .luh)
        XCTAssertEqual(h.gradeLayout, .hildesheim)
        // HILDESHEIM_SERVICES
        XCTAssertEqual(h.services.map(\.key), ["learnweb", "lsf", "lsf-ausfall", "uni"])
        XCTAssertEqual(h.services[0].url, "https://www.uni-hildesheim.de/learnweb2026/my/courses.php")
        XCTAssertEqual(h.services[0].json["connected"], true)
        XCTAssertEqual(h.services[1].json["connector"], true)
        XCTAssertEqual(h.services[1].url, "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0")
        XCTAssertEqual(h.json["files_source"], "Learnweb")
        XCTAssertEqual(h.json["cas_base"], "https://www.uni-hildesheim.de/sso")
        XCTAssertNil(l.json["cas_base"])
    }

    func testEntryPagesLikePython() {
        let cas = UniversityProfile.hildesheim.loginService("cas")!
        // LEARNWEB_LOGIN (app/hildesheim.py) und SSO_ENTRY (app/lsf.py)
        XCTAssertEqual(cas.entryURLs.map(\.absoluteString), [
            "https://www.uni-hildesheim.de/learnweb2026/login/index.php?authCAS=CAS",
            "https://www.uni-hildesheim.de/sso/login?service=https%3A%2F%2Flsf.uni-hildesheim.de%2Fqisserver%2Frds%3Fstate%3Duser%26type%3D1",
        ])
        XCTAssertEqual(UniversityProfile.luh.loginService("studip")?.entryURLs.first?.absoluteString,
                       "https://studip.uni-hannover.de/dispatch.php/login")
    }

    func testKeychainPrefixPerUniversityWithoutFallback() {
        let l = UniversityProfile.luh, h = UniversityProfile.hildesheim
        XCTAssertEqual(h.keychainAccount(service: "cas", field: "user"), "hildesheim.cas.user")
        XCTAssertEqual(h.keychainAccount(service: "cas", field: "password"), "hildesheim.cas.password")
        XCTAssertEqual(l.keychainAccount(service: "studip", field: "user"), "luh.studip.user")
        XCTAssertEqual(l.keychainAccount(service: "qis", field: "password"), "luh.qis.password")
        // Dienst der anderen Hochschule: kein Eintrag, kein Rueckfall
        XCTAssertNil(h.keychainAccount(service: "studip", field: "user"))
        XCTAssertNil(l.keychainAccount(service: "cas", field: "user"))
        XCTAssertNil(h.keychainAccount(service: "cas", field: "x"))
        XCTAssertTrue(h.ownsKeychainAccount("hildesheim.cas.user"))
        XCTAssertFalse(l.ownsKeychainAccount("hildesheim.cas.user"))
        XCTAssertFalse(l.ownsKeychainAccount("luhx.cas.user"))
        XCTAssertNotEqual(l.keychainPrefix, h.keychainPrefix)
    }

    func testLoginTargetsOnlyKnownHttpsPages() {
        let cas = UniversityProfile.hildesheim.loginService("cas")!
        func u(_ s: String) -> URL { URL(string: s)! }
        XCTAssertTrue(cas.allows(u("https://www.uni-hildesheim.de/sso/login?service=https%3A%2F%2Fx")))
        XCTAssertTrue(cas.allows(u("https://WWW.Uni-Hildesheim.DE/sso/login")))
        XCTAssertTrue(cas.allows(u("https://uni-hildesheim.de/sso/login")))
        XCTAssertTrue(cas.allows(u("https://www.uni-hildesheim.de:443/sso/login")))
        XCTAssertFalse(cas.allows(u("http://www.uni-hildesheim.de/sso/login")), "nur HTTPS")
        XCTAssertFalse(cas.allows(u("https://www.uni-hildesheim.de:8443/sso/login")))
        XCTAssertFalse(cas.allows(u("https://www.uni-hildesheim.de/learnweb2026/login/index.php")), "Learnweb selbst ist keine Anmeldeseite")
        XCTAssertFalse(cas.allows(u("https://lsf.uni-hildesheim.de/sso/login")))
        XCTAssertFalse(cas.allows(u("https://www.uni-hildesheim.de.example.org/sso/login")))
        XCTAssertFalse(cas.allows(u("https://example.org/sso/login?www.uni-hildesheim.de")))
        XCTAssertFalse(cas.allows(nil))

        let studip = UniversityProfile.luh.loginService("studip")!
        XCTAssertTrue(studip.allows(u("https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO?execution=e1s1")))
        XCTAssertTrue(studip.allows(u("https://studip.uni-hannover.de/dispatch.php/login")))
        XCTAssertFalse(studip.allows(u("https://studip.uni-hannover.de/dispatch.php/my_courses")))
        XCTAssertFalse(studip.allows(u("https://www.uni-hildesheim.de/sso/login")), "keine Anmeldeseite der anderen Uni")
        XCTAssertFalse(cas.allows(u("https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO")))
        let qis = UniversityProfile.luh.loginService("qis")!
        XCTAssertTrue(qis.allows(UniversityProfile.luhQISStart))
        XCTAssertEqual(qis.userSelectors.first, "input[name='asdf']")
        XCTAssertEqual(cas.userSelectors.first, "#username")
        XCTAssertEqual(cas.passwordSelectors.first, "#password")
    }

    // MARK: CAS

    let casBase = URL(string: "https://www.uni-hildesheim.de/sso")!

    func testCasUrlsLikePython() {
        XCTAssertEqual(CASLogin.loginURL(casBase: casBase, service: "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=1").absoluteString,
                       "https://www.uni-hildesheim.de/sso/login?service=https%3A%2F%2Flsf.uni-hildesheim.de%2Fqisserver%2Frds%3Fstate%3Duser%26type%3D1")
        XCTAssertEqual(CASLogin.quoteAll("ä b~_.-"), "%C3%A4%20b~_.-")
        XCTAssertTrue(CASLogin.isLoginPage(URL(string: "https://www.uni-hildesheim.de/sso/login?service=x"), casBase: casBase))
        XCTAssertTrue(CASLogin.isLoginPage(URL(string: "https://uni-hildesheim.de/sso/login"), casBase: casBase))
        XCTAssertFalse(CASLogin.isLoginPage(URL(string: "https://www.uni-hildesheim.de/learnweb2026/my/"), casBase: casBase))
        XCTAssertFalse(CASLogin.isLoginPage(URL(string: "https://lsf.uni-hildesheim.de/sso/login"), casBase: casBase))
        XCTAssertTrue(CASLogin.isSessionExpired(finalURL: URL(string: "https://www.uni-hildesheim.de/sso/login?service=abc"), casBase: casBase))
        XCTAssertFalse(CASLogin.isSessionExpired(finalURL: nil, casBase: casBase))
    }

    // Erfundene CAS-Seite im Aufbau von Apereo CAS 7 (Felder wie im Live-Test)
    let casForm = """
    <html><body><form method="post" id="fm1" action="login">
    <section class="cas-field"><label for="username">Zugangskennung</label>
    <input class="form-control" id="username" size="25" type="text" accesskey="n" autocomplete="username" name="username" value=""></section>
    <section class="cas-field"><input class="form-control" type="password" id="password" name="password" autocomplete="off"></section>
    <input type="hidden" name="execution" value="abc"/><input type="hidden" name="_eventId" value="submit"/>
    <button class="mdc-button" name="submit" accesskey="l" type="submit" value="Anmelden">Anmelden</button>
    </form></body></html>
    """

    func testCasFormAndStates() {
        let f = CASLogin.form(html: casForm)
        XCTAssertTrue(f.hasUsername && f.hasPassword && f.hasSubmit && f.isComplete)
        XCTAssertFalse(CASLogin.form(html: "<html><body>Learnweb</body></html>").isComplete)
        let service = URL(string: "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=1")!
        let login = URL(string: "https://www.uni-hildesheim.de/sso/login?service=x")!
        XCTAssertEqual(CASLogin.state(url: login, html: casForm, service: service, casBase: casBase), .loginRequired)
        let failed = casForm.replacingOccurrences(of: "<form", with: """
        <div id="loginErrorsPanel" class="banner banner-danger"><p><span>Ung&uuml;ltige</span> Anmeldedaten.</p>
        <div><b>Bitte</b> erneut versuchen</div></div><form
        """)
        XCTAssertEqual(CASLogin.errorText(html: failed), "Ungültige Anmeldedaten. Bitte erneut versuchen")
        XCTAssertEqual(CASLogin.state(url: login, html: failed, service: service, casBase: casBase),
                       .failed("Ungültige Anmeldedaten. Bitte erneut versuchen"))
        XCTAssertNil(CASLogin.errorText(html: casForm))
        // Erfolg: Ruecksprung zur service-URL (mit ticket)
        let back = URL(string: "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=1&ticket=ST-1-abc")!
        XCTAssertEqual(CASLogin.state(url: back, html: nil, service: service, casBase: casBase), .returnedToService)
        XCTAssertEqual(CASLogin.state(url: URL(string: "https://www.uni-hildesheim.de/sso/logout"), html: nil, service: service,
                                      casBase: casBase), .elsewhere)
        XCTAssertFalse(CASLogin.returnedToService(URL(string: "http://lsf.uni-hildesheim.de/qisserver/rds"), service: service))
        XCTAssertFalse(CASLogin.returnedToService(URL(string: "https://lsf.uni-hildesheim.de/qisserverX"), service: service))
        let lw = URL(string: "https://www.uni-hildesheim.de/learnweb2026/login/index.php?authCAS=CAS")!
        XCTAssertTrue(CASLogin.returnedToService(URL(string: "https://www.uni-hildesheim.de/learnweb2026/login/index.php?ticket=ST-2"), service: lw))
    }

    func testErrorTextIsShortAndHasNoTags() {
        let long = "<div id='loginErrorsPanel'>" + String(repeating: "Fehler ", count: 80) + "<script>x</script></div>"
        let t = CASLogin.errorText(html: long)!
        XCTAssertLessThanOrEqual(t.count, 200)
        XCTAssertFalse(t.contains("<"))
        XCTAssertNil(CASLogin.errorText(html: "<div id=\"loginErrorsPanelX\">x</div>"))
    }

    // MARK: Hashwerte

    func testHashVectors() {
        XCTAssertEqual(InsecureHash.sha1Hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(InsecureHash.sha1Hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(InsecureHash.sha1Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        XCTAssertEqual(InsecureHash.sha1Hex(String(repeating: "a", count: 1000)), "291e9a6c66994949b57ba5e650361e98fc36b1ba")
        XCTAssertEqual(InsecureHash.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(InsecureHash.md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(InsecureHash.md5Hex("The quick brown fox jumps over the lazy dog"), "9e107d9d372bb6826bd81d3542a419d6")
        XCTAssertEqual(InsecureHash.md5Hex("12345678901234567890123456789012345678901234567890123456789012345678901234567890"),
                       "57edf4a22be3c955ac49da2e2107b67a")
        XCTAssertEqual(InsecureHash.md5Hex("ä"), "8419b71c87a225a2c70b50486fbee545")
    }
}
