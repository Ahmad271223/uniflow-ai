import Foundation
import XCTest
@testable import UniFlowCore

/// Hochschul-Profile (wie app/universities.py), CAS-Regeln (`HildesheimCAS` wie app/cas.py und test_cas_urls) und
/// MD5. Ohne Netzwerk; die Adressen werden nur verglichen, nie aufgerufen.
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
        XCTAssertEqual(Migrations.defaultUniversity, UniversityKey.default.rawValue, "eine Quelle fuer die Schluessel")
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
        XCTAssertEqual(UniversityProfile.hildesheimLSFStart.absoluteString, "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0")
        XCTAssertNil(l.casBase)
        XCTAssertNil(h.studipBase)
        XCTAssertEqual(l.gradeLayout, .luh)
        XCTAssertEqual(h.gradeLayout, .hildesheim)
        // dieselben Adressen wie der Abgleich (HildesheimCAS, LSFClient)
        XCTAssertEqual(HildesheimCAS.casBase, h.casBase?.absoluteString)
        XCTAssertEqual(HildesheimCAS.lsfBase, h.lsfBase?.absoluteString)
        XCTAssertTrue(LSFClient.startURL.hasPrefix(h.lsfBase!.absoluteString))
        XCTAssertEqual(h.learnwebBase?.absoluteString.hasPrefix(Learnweb.root), true)
        // HILDESHEIM_SERVICES und SERVICES (app/server.py)
        XCTAssertEqual(h.services.map(\.key), ["learnweb", "lsf", "lsf-ausfall", "uni"])
        XCTAssertEqual(l.services.map(\.key), ["studip", "ilias", "qis", "idm", "mail", "matrix", "luhki", "gitlab", "tib", "mensa",
                                               "servicecenter", "luis"])
        XCTAssertEqual(l.services[0].json["connected"], true)
        XCTAssertEqual(l.services[2].json["connector"], true)
        XCTAssertNil(l.services[1].json["connected"])
        XCTAssertEqual(h.services[0].url, "https://www.uni-hildesheim.de/learnweb2026/my/courses.php")
        XCTAssertEqual(h.services[0].json["connected"], true)
        XCTAssertEqual(h.services[1].json["connector"], true)
        XCTAssertEqual(h.services[1].url, "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0")
        XCTAssertEqual(h.json["files_source"], "Learnweb")
        // "university" in /api/services wie api_services: genau diese sieben Felder
        XCTAssertEqual(Set(h.json.object?.keys.map { $0 } ?? []), ["key", "name", "short", "files_source", "grades_source", "login", "user_label"])
        XCTAssertEqual(l.json["user_label"], "LUH-ID")
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
        // Learnweb-Schluessel: nur als Schluessel, nur in Hildesheim
        XCTAssertEqual(h.tokenKeychainAccount(service: "learnweb"), "hildesheim.learnweb.token")
        XCTAssertNil(h.tokenKeychainAccount(service: "cas"), "Anmeldedienst hat keinen Schluessel")
        XCTAssertNil(l.tokenKeychainAccount(service: "learnweb"), "kein Rueckfall auf die andere Hochschule")
        XCTAssertNil(l.tokenKeychainAccount(service: "studip"))
        XCTAssertNil(l.tokenKeychainAccount(service: "qis"))
        // mit Nutzer-Praefix (eine Funktion fuer alle Namen, App und Kern)
        XCTAssertEqual(h.tokenKeychainAccount(service: "learnweb", userScope: "u0123456789abcdef"), "u0123456789abcdef.hildesheim.learnweb.token")
        XCTAssertTrue(h.ownsKeychainAccount("hildesheim.learnweb.token"))
        XCTAssertFalse(l.ownsKeychainAccount("hildesheim.learnweb.token"))
        XCTAssertFalse(l.ownsKeychainAccount("luhx.cas.user"))
        XCTAssertNotEqual(l.keychainPrefix, h.keychainPrefix)
    }

    /// Entscheidung des Inhabers (27.10.2026): Hochschul-Passwoerter merkt nur das System. Die Eintraege, in denen die
    /// App sie bis dahin selbst merkte, erkennt der Kern fuer die einmalige Loeschung bei Bestandsnutzern.
    func testRetiredLoginSecretsAreRecognisedAndTokensAreNot() {
        for retired in ["u0123456789abcdef.luh.studip.user", "u0123456789abcdef.luh.studip.password", "u0123456789abcdef.luh.qis.user",
                        "u0123456789abcdef.luh.qis.password", "ufedcba9876543210.hildesheim.cas.user", "ufedcba9876543210.hildesheim.cas.password",
                        "luh.studip.user", "luh.qis.password", "hildesheim.cas.password",      // vor den Containern ohne Nutzer
                        "u-ohne-anmeldung.luh.studip.password"] {                                // ohne offenen Container gemerkt
            XCTAssertTrue(UniversityProfile.isRetiredLoginSecret(retired), retired)
        }
        for kept in ["u0123456789abcdef.hildesheim.learnweb.token", "hildesheim.learnweb.token", "u0123456789abcdef.luh.studip.token",
                     "u0123456789abcdef.luhx.studip.password", "u0123456789abcdef.luh..password", "password", "luh.password",
                     "u0123456789abcdef.luh.studip.password.alt", "session-cookies.0000", "u0123456789abcdef.luh.studip.User", ""] {
            XCTAssertFalse(UniversityProfile.isRetiredLoginSecret(kept), kept)
        }
        XCTAssertEqual(UniversityProfile.retiredLoginFields, ["user", "password"])
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
    }

    // MARK: CAS

    let casBase = "https://www.uni-hildesheim.de/sso"

    func testCasUrlsLikePython() {
        XCTAssertEqual(HildesheimCAS.loginURL(casBase: casBase, service: "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=1"),
                       "https://www.uni-hildesheim.de/sso/login?service=https%3A%2F%2Flsf.uni-hildesheim.de%2Fqisserver%2Frds%3Fstate%3Duser%26type%3D1")
        XCTAssertEqual(PyText.quote("ä b~_.-", safe: ""), "%C3%A4%20b~_.-")
        XCTAssertTrue(HildesheimCAS.isCASPage("https://www.uni-hildesheim.de/sso/login?service=x", casBase: casBase))
        XCTAssertTrue(HildesheimCAS.isCASPage("https://uni-hildesheim.de/sso/login"))
        XCTAssertFalse(HildesheimCAS.isCASPage("https://www.uni-hildesheim.de/learnweb2026/my/"))
        XCTAssertFalse(HildesheimCAS.isCASPage("https://lsf.uni-hildesheim.de/sso/login"))
        XCTAssertTrue(HildesheimCAS.isCASPage("https://www.uni-hildesheim.de/sso/login?service=abc"), "abgelaufene Sitzung")
        XCTAssertFalse(HildesheimCAS.isCASPage(""))
        XCTAssertEqual(HildesheimCAS.learnwebLoginURL(base: "https://www.uni-hildesheim.de/learnweb2027"),
                       "https://www.uni-hildesheim.de/learnweb2027/login/index.php?authCAS=CAS")
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

    /// Fehlertext des CAS nach falscher Eingabe (zeigt die Anmeldeansicht der App); ob die Anmeldung fertig ist,
    /// entscheidet der Dienst (`LSFClient.isLoggedIn`, `Learnweb.isLoggedIn`)
    func testCasErrorTextAndLoginRules() {
        let failed = casForm.replacingOccurrences(of: "<form", with: """
        <div id="loginErrorsPanel" class="banner banner-danger"><p><span>Ung&uuml;ltige</span> Anmeldedaten.</p>
        <div><b>Bitte</b> erneut versuchen</div></div><form
        """)
        XCTAssertEqual(HildesheimCAS.errorText(html: failed), "Ungültige Anmeldedaten. Bitte erneut versuchen")
        XCTAssertNil(HildesheimCAS.errorText(html: casForm))
        // LSF angemeldet = Seite des LSF ueber HTTPS mit "Abmelden" (lsf.is_logged_in)
        let page = #"<a href="rds?state=user&amp;type=4">Abmelden</a>"#
        XCTAssertTrue(LSFClient.isLoggedIn(html: page, url: URL(string: "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=0")))
        XCTAssertTrue(LSFClient.isLoggedIn(html: page, url: URL(string: "https://LSF.uni-hildesheim.de/qisserver/rds")))
        XCTAssertFalse(LSFClient.isLoggedIn(html: "<a>Anmelden</a>", url: URL(string: "https://lsf.uni-hildesheim.de/qisserver/rds")))
        XCTAssertFalse(LSFClient.isLoggedIn(html: page, url: URL(string: "http://lsf.uni-hildesheim.de/qisserver/rds")), "nur HTTPS")
        XCTAssertFalse(LSFClient.isLoggedIn(html: page, url: URL(string: "https://www.uni-hildesheim.de/sso/login?service=x")), "CAS ist nicht das LSF")
        XCTAssertFalse(LSFClient.isLoggedIn(html: page, url: URL(string: "https://lsf.uni-hildesheim.de.example.org/qisserver")))
        XCTAssertFalse(LSFClient.isLoggedIn(html: page, url: nil))
        // Schreibweise des Links egal (Playwright has-text), Abmelde-Link auch ohne Wort; die abgemeldete Startseite
        // hat nur auth.login
        let lsf = URL(string: "https://lsf.uni-hildesheim.de/qisserver/rds?state=user&type=1")
        XCTAssertTrue(LSFClient.isLoggedIn(html: "<a>ABMELDEN</a>", url: lsf))
        XCTAssertTrue(LSFClient.isLoggedIn(html: #"<a href="rds?state=user&amp;type=4&amp;category=auth.logout"><img alt=""></a>"#, url: lsf))
        XCTAssertFalse(LSFClient.isLoggedIn(html: #"<a href="rds?state=user&amp;type=1&amp;category=auth.login">Anmelden</a>"#, url: lsf))
        XCTAssertTrue(LSFClient.isLoggedIn(html: "<a href=\"x\">\n<span>Abmelden</span></a>", url: lsf))
        XCTAssertFalse(LSFClient.isLoggedIn(html: "<p>Bitte nach der Pr&uuml;fung abmelden.</p><a>Anmelden</a>", url: lsf),
                       "das Wort im Fliesstext ist kein Abmelde-Link")
    }

    func testErrorTextIsShortAndHasNoTags() {
        let long = "<div id='loginErrorsPanel'>" + String(repeating: "Fehler ", count: 80) + "<script>x</script></div>"
        let t = HildesheimCAS.errorText(html: long)!
        XCTAssertLessThanOrEqual(t.count, 200)
        XCTAssertFalse(t.contains("<"))
        XCTAssertNil(HildesheimCAS.errorText(html: "<div id=\"loginErrorsPanelX\">x</div>"))
        // ueber HTMLTokenizer: Inhalt von script und style ist kein Text (vorher per Regex mitgelesen)
        XCTAssertEqual(HildesheimCAS.errorText(html: "<div id='\(HildesheimCAS.errorPanelID)'>Falsch<script>var a = 1</script>"
                                               + "<style>.x{color:red}</style><div>!</div></div><p>danach</p>"), "Falsch !")
    }

    /// LSF-Links: wurzelrelativ gegen die Basis (vorher "…/qisserver/qisserver/rds?…"), relativ zu /qisserver/, http(s)
    /// bleibt; dieselben Faelle wie `lsf.absolute` (expected.json)
    func testLSFAbsoluteLinks() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let expected = try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/hildesheim/expected.json")))
        let cases = expected["lsf-absolute"]?.array ?? []
        XCTAssertEqual(cases.count, 4)
        for c in cases { XCTAssertEqual(HildesheimCAS.lsfAbsolute(c["href"]?.string ?? ""), c["url"]?.string) }
        XCTAssertEqual(HildesheimCAS.lsfAbsolute("/qisserver/rds?a=1"), "https://lsf.uni-hildesheim.de/qisserver/rds?a=1")
    }

    // MARK: Hashwerte

    func testMD5Vectors() {
        // RFC 1321 und Moodle-Signatur; SHA-1 gibt es nicht mehr (Datei-IDs mit SHA-256 wie app/learnweb.py)
        XCTAssertEqual(MD5.hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hex("The quick brown fox jumps over the lazy dog"), "9e107d9d372bb6826bd81d3542a419d6")
        XCTAssertEqual(MD5.hex("12345678901234567890123456789012345678901234567890123456789012345678901234567890"),
                       "57edf4a22be3c955ac49da2e2107b67a")
        XCTAssertEqual(MD5.hex("ä"), "8419b71c87a225a2c70b50486fbee545")
        XCTAssertEqual(MD5.hex(String(repeating: "a", count: 55)), "ef1772b6dff9a122358552954ad0df65", "Grenze der Auffuellung")
        XCTAssertEqual(MD5.hex(String(repeating: "a", count: 56)), "3b0c8ac703f828b04c6c197006d17218")
    }
}
