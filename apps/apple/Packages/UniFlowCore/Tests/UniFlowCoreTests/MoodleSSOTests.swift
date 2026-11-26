import Foundation
import XCTest
@testable import UniFlowCore

/// Moodle-SSO-Start (launch.php), oeffentliche Konfiguration und Zerlegen der Token-Antwort, ohne Netzwerk. Werte
/// erfunden. Die Python-Faelle (`moodle-launch` in expected.json) prueft HildesheimSyncTests.testMD5AndMoodleLaunch.
final class MoodleSSOTests: XCTestCase {
    private let wwwroot = "https://www.uni-hildesheim.de/learnweb2026"

    private func config(_ extra: String = "") throws -> MoodlePublicConfig {
        MoodlePublicConfig.parse(try JSONValue.parse("""
        {"wwwroot": "\(wwwroot)", "httpswwwroot": "\(wwwroot)", "sitename": "Learnweb", "typeoflogin": 1,
         "enablemobilewebservice": 1, "launchurl": "\(wwwroot)/admin/tool/mobile/launch.php",
         "identityproviders": [{"name": "CAS", "url": "\(wwwroot)/login/index.php?authCAS=CAS"}]\(extra)}
        """))
    }

    /// Antwort wie admin/tool/mobile/launch.php: base64(md5(wwwroot + passport) ":::" token [":::" privatetoken])
    private func redirect(scheme: String = "moodlemobile", site: String, passport: String, token: String, privateToken: String? = nil,
                          stripPadding: Bool = false) -> String {
        var plain = MD5.hex(site + passport) + ":::" + token
        if let privateToken { plain += ":::" + privateToken }
        var b64 = Data(plain.utf8).base64EncodedString()
        if stripPadding { b64 = b64.replacingOccurrences(of: "=", with: "") }
        return "\(scheme)://token=\(b64)"
    }

    /// Echtes Learnweb Hildesheim (`typeoflogin` 1): launch.php gibt es, nimmt den Aufruf aber nur unmittelbar nach
    /// einer Anmeldung an. Die App erkennt das (`browserLogin`), oeffnet die Anmeldeseite und erkennt Moodles Pruefseite
    /// nach der Anmeldung (`isSessionTest`); steht der Schluessel als Link auf einer Seite, findet ihn `tokenLink`.
    func testLoginInAppGoesThroughTheLoginPage() throws {
        let appOnly = try config()
        XCTAssertEqual(appOnly.typeOfLogin, 1)
        XCTAssertTrue(appOnly.ssoAvailable, "launch.php gibt es, nur nicht als Startseite")
        XCTAssertFalse(appOnly.browserLogin)
        func parsed(_ json: String) throws -> MoodlePublicConfig { MoodlePublicConfig.parse(try JSONValue.parse(json)) }
        XCTAssertTrue(try parsed(#"{"launchurl": "x", "typeoflogin": 2}"#).browserLogin)
        XCTAssertTrue(try parsed(#"{"launchurl": "x", "typeoflogin": 3}"#).browserLogin)
        XCTAssertFalse(try parsed(#"{"launchurl": "x", "typeoflogin": 7}"#).browserLogin)
        XCTAssertFalse(try parsed(#"{"launchurl": "x"}"#).browserLogin, "ohne Angabe: ueber die Anmeldeseite, nie die Fehlerseite")

        XCTAssertEqual(MoodleSSO.loginPageURL(base: wwwroot + "/"), wwwroot + "/login/index.php")
        XCTAssertTrue(MoodleSSO.isSessionTest(wwwroot + "/login/index.php?testsession=4711", base: wwwroot))
        XCTAssertTrue(MoodleSSO.isSessionTest(wwwroot + "/login/index.php?lang=de&testsession=3", base: wwwroot + "/"))
        for other in [wwwroot + "/login/index.php", wwwroot + "/login/index.php?authCAS=CAS", wwwroot + "/login/index.php?ticket=ST-1",
                      wwwroot + "/login/index.php?testsession=", wwwroot + "/login/index.php?testsession=abc", wwwroot + "/my/?testsession=5",
                      "https://www.uni-hildesheim.de/learnweb2027/login/index.php?testsession=5",
                      "https://evil.example/learnweb2026/login/index.php?testsession=5"] {
            XCTAssertFalse(MoodleSSO.isSessionTest(other, base: wwwroot), other)
        }

        let link = redirect(site: wwwroot, passport: "passport12345678", token: "Abc123Token", privateToken: "Privat987")
        let page = #"<html><body><a id="launchapp" href="\#(link)">Hier klicken, um die App zu starten</a></body></html>"#
        XCTAssertEqual(MoodleSSO.tokenLink(html: page, scheme: "moodlemobile"), link)
        XCTAssertEqual(MoodleSSO.parseLaunchToken(try XCTUnwrap(MoodleSSO.tokenLink(html: page, scheme: "MoodleMobile")), base: wwwroot,
                                                  passport: "passport12345678", scheme: "moodlemobile")?.token, "Abc123Token")
        XCTAssertNil(MoodleSSO.tokenLink(html: page, scheme: "unischema"), "nur das erwartete Schema")
        XCTAssertNil(MoodleSSO.tokenLink(html: "<p>moodlemobile und token= stehen nur im Text</p>", scheme: "moodlemobile"))
    }

    func testPublicConfigAndLaunchURL() throws {
        let c = try config()
        XCTAssertTrue(c.ssoAvailable)
        XCTAssertEqual(c.typeOfLogin, 1)
        XCTAssertEqual(c.identityProviders, ["CAS"])
        XCTAssertEqual(c.siteName, "Learnweb")
        XCTAssertEqual(c.urlScheme, "moodlemobile", "Standard ohne forcedurlscheme")
        let passport = MoodleSSO.newPassport()
        XCTAssertEqual(passport.count, 24)
        XCTAssertTrue(LearnwebToken.isAlnum(passport, 24...24))
        XCTAssertNotEqual(passport, MoodleSSO.newPassport())
        let url = try MoodleSSO.launchURL(config: c, base: wwwroot, passport: passport)
        XCTAssertEqual(url, "\(wwwroot)/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=\(passport)&urlscheme=moodlemobile")
        XCTAssertEqual(url, MoodleSSO.launchURL(base: wwwroot + "/", passport: passport), "eine Fassung der Start-Adresse")

        let forced = try config(#", "forcedurlscheme": "UniSchema""#)
        XCTAssertEqual(forced.urlScheme, "unischema", "Uni gibt das Schema vor")
        XCTAssertTrue(try MoodleSSO.launchURL(config: forced, base: wwwroot, passport: passport).hasSuffix("urlscheme=unischema"))
        XCTAssertEqual(try config(#", "forcedurlscheme": "https""#).urlScheme, "moodlemobile", "http(s) ist nie ein Token-Schema")
        XCTAssertEqual(try config(#", "forcedurlscheme": "javascript""#).urlScheme, "moodlemobile")

        // ohne launchurl, Webservice aus, fremder Rechner, http oder ungueltiger passport: kein SSO
        let off = try config(#", "enablemobilewebservice": 0"#)
        XCTAssertFalse(off.ssoAvailable)
        XCTAssertThrowsError(try MoodleSSO.launchURL(config: off, base: wwwroot, passport: passport))
        let none = MoodlePublicConfig.parse(try JSONValue.parse(#"{"wwwroot": "x"}"#))
        XCTAssertFalse(none.ssoAvailable)
        for bad in ["https://evil.example/admin/tool/mobile/launch.php", "http://www.uni-hildesheim.de/learnweb2026/admin/tool/mobile/launch.php"] {
            let foreign = MoodlePublicConfig.parse(try JSONValue.parse(#"{"launchurl": "\#(bad)"}"#))
            XCTAssertThrowsError(try MoodleSSO.launchURL(config: foreign, base: wwwroot, passport: passport), bad) {
                guard case .ssoUnavailable? = $0 as? HildesheimError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try MoodleSSO.launchURL(config: c, base: wwwroot, passport: "kurz"))
        XCTAssertThrowsError(try MoodleSSO.launchURL(config: c, base: wwwroot, passport: "mit&zeichen0123"))
    }

    func testTokenRedirectIsCheckedWithPassport() throws {
        let passport = "0123456789abcdef0123456789abcdef"
        let tok = "abcdef0123456789abcdef0123456789"
        let ok = redirect(site: wwwroot, passport: passport, token: tok, privateToken: "PRIV0123456789")
        XCTAssertTrue(MoodleSSO.isTokenRedirect(ok, scheme: "moodlemobile"))
        XCTAssertFalse(MoodleSSO.isTokenRedirect(ok, scheme: "anderes"))
        XCTAssertFalse(MoodleSSO.isTokenRedirect("https://www.uni-hildesheim.de/learnweb2026/my/", scheme: "moodlemobile"))
        XCTAssertFalse(MoodleSSO.isTokenRedirect(nil, scheme: "moodlemobile"))
        let t = try XCTUnwrap(MoodleSSO.parseLaunchToken(ok, base: wwwroot, passport: passport, scheme: "moodlemobile"))
        XCTAssertEqual(t.keychainValue, tok)
        XCTAssertEqual(t.privateToken, "PRIV0123456789")
        XCTAssertFalse(String(describing: t).contains(tok))

        // Moodle-App-Regeln: "/" am Ende und http statt https zaehlen; fehlende Auffuellung und %-kodierte Zeichen sind ok
        let slash = redirect(site: wwwroot + "/", passport: passport, token: tok, stripPadding: true)
        XCTAssertEqual(MoodleSSO.parseLaunchToken(slash, base: wwwroot, passport: passport)?.keychainValue, tok)
        let http = redirect(site: "http://www.uni-hildesheim.de/learnweb2026", passport: passport, token: tok)
        XCTAssertNotNil(MoodleSSO.parseLaunchToken(http, base: wwwroot, passport: passport))
        let encoded = ok.replacingOccurrences(of: "=", with: "%3D").replacingOccurrences(of: "token%3D", with: "token=")
        XCTAssertEqual(MoodleSSO.parseLaunchToken(encoded, base: wwwroot, passport: passport)?.keychainValue, tok)
        // wwwroot aus der Konfiguration, wenn die eigene Adresse anders geschrieben ist
        let other = redirect(site: "https://lw.example.org/moodle", passport: passport, token: tok)
        XCTAssertNil(MoodleSSO.parseLaunchToken(other, base: wwwroot, passport: passport))
        XCTAssertNotNil(MoodleSSO.parseLaunchToken(other, base: wwwroot, passport: passport, siteURLs: ["https://lw.example.org/moodle/"]))

        // anderer passport (Antwort gehoert zu einem anderen Start), andere Seite, falsches Schema: verworfen
        XCTAssertNil(MoodleSSO.parseLaunchToken(redirect(site: wwwroot, passport: "ffffffffffffffffffffffffffffffff", token: tok),
                                                base: wwwroot, passport: passport))
        XCTAssertNil(MoodleSSO.parseLaunchToken(redirect(site: "https://evil.example/moodle", passport: passport, token: tok),
                                                base: wwwroot, passport: passport))
        XCTAssertNil(MoodleSSO.parseLaunchToken(ok, base: wwwroot, passport: passport, scheme: "unischema"))
        XCTAssertNil(MoodleSSO.parseLaunchToken("moodlemobile://token=bm9wZQ", base: wwwroot, passport: passport))
        XCTAssertNil(MoodleSSO.parseLaunchToken(redirect(site: wwwroot, passport: passport, token: "nicht alnum!"), base: wwwroot, passport: passport),
                     "nur alphanumerische Schluessel")
    }

    func testFetchPublicConfigOverTransport() async throws {
        let body = #"[{"error": false, "data": {"wwwroot": "https://www.uni-hildesheim.de/learnweb2026", "sitename": "Learnweb SoSe 2026", "launchurl": "https://www.uni-hildesheim.de/learnweb2026/admin/tool/mobile/launch.php", "enablemobilewebservice": true, "typeoflogin": 1}}]"#
        var n = 0
        let net = FakeUniTransport { _ in
            n += 1
            if n == 1 { throw URLError(.networkConnectionLost) }
            return UniResponse(status: 200, body: Data(body.utf8))
        }
        let c = try await MoodleSSO.publicConfig(base: wwwroot + "/", transport: net, retry: UniRetry(attempts: 3, delayNanos: { _ in 0 }))
        XCTAssertTrue(c.ssoAvailable)
        let r = net.requests[0]
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "\(wwwroot)/lib/ajax/service-nologin.php?info=tool_mobile_get_public_config")
        XCTAssertEqual(try JSONValue.parse(r.body ?? Data()).array?.first?["methodname"], "tool_mobile_get_public_config")
        XCTAssertEqual(net.requests.count, 2, "einmal wiederholt")
        // dieselbe Abfrage liefert den Namen fuer die Suche nach der Instanz des Semesters
        let name = await Learnweb.publicSitename(base: wwwroot, transport: FakeUniTransport { _ in UniResponse(status: 200, body: Data(body.utf8)) })
        XCTAssertEqual(name, "Learnweb SoSe 2026")

        let failing = FakeUniTransport { _ in UniResponse(status: 200, body: Data(#"[{"error": true, "exception": {"errorcode": "servicenotavailable"}}]"#.utf8)) }
        do { _ = try await MoodleSSO.publicConfig(base: wwwroot, transport: failing); XCTFail() } catch {
            XCTAssertEqual(error as? HildesheimError, .ssoUnavailable("servicenotavailable"))
        }
        let missing = await Learnweb.publicSitename(base: wwwroot, transport: failing)
        XCTAssertNil(missing, "Fehler oder 404: keine Instanz")
    }
}
