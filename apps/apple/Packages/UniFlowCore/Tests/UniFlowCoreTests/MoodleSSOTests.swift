import Foundation
import XCTest
@testable import UniFlowCore

/// Moodle-SSO-Start (launch.php) und Zerlegen der Token-Antwort, ohne Netzwerk. Werte erfunden.
final class MoodleSSOTests: XCTestCase {
    private let base = URL(string: "https://www.uni-hildesheim.de/learnweb2026")!
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
                          stripPadding: Bool = false) -> URL {
        var plain = InsecureHash.md5Hex(site + passport) + ":::" + token
        if let privateToken { plain += ":::" + privateToken }
        var b64 = Data(plain.utf8).base64EncodedString()
        if stripPadding { b64 = b64.replacingOccurrences(of: "=", with: "") }
        return URL(string: "\(scheme)://token=\(b64)")!
    }

    func testPublicConfigAndLaunchURL() throws {
        let c = try config()
        XCTAssertTrue(c.ssoAvailable)
        XCTAssertEqual(c.typeOfLogin, 1)
        XCTAssertEqual(c.identityProviders, ["CAS"])
        XCTAssertEqual(c.urlScheme, "moodlemobile", "Standard ohne forcedurlscheme")
        let passport = MoodleSSO.newPassport()
        XCTAssertEqual(passport.count, 32)
        XCTAssertNotEqual(passport, MoodleSSO.newPassport())
        let url = try MoodleSSO.launchURL(config: c, base: base, passport: passport)
        XCTAssertEqual(url.absoluteString,
                       "\(wwwroot)/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=\(passport)&urlscheme=moodlemobile")

        let forced = try config(#", "forcedurlscheme": "UniSchema""#)
        XCTAssertEqual(forced.urlScheme, "unischema", "Uni gibt das Schema vor")
        XCTAssertTrue(try MoodleSSO.launchURL(config: forced, base: base, passport: passport).absoluteString.hasSuffix("urlscheme=unischema"))
        XCTAssertEqual(try config(#", "forcedurlscheme": "https""#).urlScheme, "moodlemobile", "http(s) ist nie ein Token-Schema")

        // ohne launchurl, Webservice aus oder fremder Rechner: kein SSO
        let off = try config(#", "enablemobilewebservice": 0"#)
        XCTAssertFalse(off.ssoAvailable)
        XCTAssertThrowsError(try MoodleSSO.launchURL(config: off, base: base, passport: passport))
        let none = MoodlePublicConfig.parse(try JSONValue.parse(#"{"wwwroot": "x"}"#))
        XCTAssertFalse(none.ssoAvailable)
        let foreign = MoodlePublicConfig.parse(try JSONValue.parse(#"{"launchurl": "https://evil.example/admin/tool/mobile/launch.php"}"#))
        XCTAssertThrowsError(try MoodleSSO.launchURL(config: foreign, base: base, passport: passport))
    }

    func testTokenRedirectIsCheckedWithPassport() throws {
        let passport = "0123456789abcdef0123456789abcdef"
        let tok = "abcdef0123456789abcdef0123456789"
        let ok = redirect(site: wwwroot, passport: passport, token: tok, privateToken: "PRIV0123456789")
        XCTAssertTrue(MoodleSSO.isTokenRedirect(ok, scheme: "moodlemobile"))
        XCTAssertFalse(MoodleSSO.isTokenRedirect(ok, scheme: "anderes"))
        XCTAssertFalse(MoodleSSO.isTokenRedirect(URL(string: "https://www.uni-hildesheim.de/learnweb2026/my/"), scheme: "moodlemobile"))
        let t = try MoodleSSO.token(fromRedirect: ok, scheme: "moodlemobile", passport: passport, siteURLs: [wwwroot])
        XCTAssertEqual(t.keychainValue, tok)
        XCTAssertEqual(t.privateToken, "PRIV0123456789")
        XCTAssertFalse(String(describing: t).contains(tok))

        // Moodle-App-Regeln: "/" am Ende und http statt https zaehlen; fehlende Auffuellung ist ok
        let slash = redirect(site: wwwroot + "/", passport: passport, token: tok, stripPadding: true)
        XCTAssertEqual(try MoodleSSO.token(fromRedirect: slash, scheme: "moodlemobile", passport: passport, siteURLs: [wwwroot]).keychainValue, tok)
        let http = redirect(site: "http://www.uni-hildesheim.de/learnweb2026", passport: passport, token: tok)
        XCTAssertNoThrow(try MoodleSSO.token(fromRedirect: http, scheme: "moodlemobile", passport: passport, siteURLs: [wwwroot]))

        // anderer passport (Antwort gehoert zu einem anderen Start), andere Seite, falsches Schema: verworfen
        let other = redirect(site: wwwroot, passport: "ffffffffffffffffffffffffffffffff", token: tok)
        XCTAssertThrowsError(try MoodleSSO.token(fromRedirect: other, scheme: "moodlemobile", passport: passport, siteURLs: [wwwroot])) {
            guard case .ssoRejected? = $0 as? LearnwebError else { return XCTFail("\($0)") }
            XCTAssertFalse(String(describing: $0).contains(tok), "Token nie in Fehlermeldungen")
        }
        let evil = redirect(site: "https://evil.example/moodle", passport: passport, token: tok)
        XCTAssertThrowsError(try MoodleSSO.token(fromRedirect: evil, scheme: "moodlemobile", passport: passport, siteURLs: [wwwroot]))
        XCTAssertThrowsError(try MoodleSSO.token(fromRedirect: ok, scheme: "unischema", passport: passport, siteURLs: [wwwroot]))
        XCTAssertThrowsError(try MoodleSSO.token(fromRedirect: URL(string: "moodlemobile://token=bm9wZQ")!, scheme: "moodlemobile",
                                                 passport: passport, siteURLs: [wwwroot]))
        let bad = redirect(site: wwwroot, passport: passport, token: "nicht alnum!")
        XCTAssertThrowsError(try MoodleSSO.token(fromRedirect: bad, scheme: "moodlemobile", passport: passport, siteURLs: [wwwroot]))
    }

    func testFetchPublicConfigOverTransport() async throws {
        let body = #"[{"error": false, "data": {"wwwroot": "https://www.uni-hildesheim.de/learnweb2026", "launchurl": "https://www.uni-hildesheim.de/learnweb2026/admin/tool/mobile/launch.php", "enablemobilewebservice": true, "typeoflogin": 1}}]"#
        var n = 0
        let net = FakeLearnweb { _ in
            n += 1
            if n == 1 { throw URLError(.networkConnectionLost) }
            return .json(body)
        }
        let c = try await MoodleSSO.fetchPublicConfig(base: base, transport: net, retry: LearnwebRetry(attempts: 3, baseDelayMillis: 1, sleep: { _ in }))
        XCTAssertTrue(c.ssoAvailable)
        let r = net.requests[0]
        XCTAssertEqual(r.method, .post)
        XCTAssertEqual(r.url.absoluteString, "\(wwwroot)/lib/ajax/service-nologin.php?info=tool_mobile_get_public_config")
        XCTAssertEqual(try JSONValue.parse(r.body ?? Data()).array?.first?["methodname"], "tool_mobile_get_public_config")
        XCTAssertEqual(net.requests.count, 2, "einmal wiederholt")

        let failing = FakeLearnweb { _ in .json(#"[{"error": true, "exception": {"errorcode": "servicenotavailable"}}]"#) }
        do { _ = try await MoodleSSO.fetchPublicConfig(base: base, transport: failing); XCTFail() } catch {
            XCTAssertEqual(error as? LearnwebError, .ssoUnavailable("servicenotavailable"))
        }
    }
}
