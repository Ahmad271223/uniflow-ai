import XCTest
@testable import UniFlow

/// Stud.IP-Anmeldung erneuern (2.11.2026): direkter WebSSO-Einstieg wie am PC und Cookies nur der Stud.IP-Adresse
@MainActor
final class StudIPRenewAppTests: XCTestCase {
    func testSSOLoginURLMatchesThePC() {
        // app/studip_sync.py SHIB_LOGIN_URL
        XCTAssertEqual(StudIPSync.ssoLoginURL(base: URL(string: "https://studip.uni-hannover.de")!).absoluteString,
                       "https://studip.uni-hannover.de/Shibboleth.sso/Login?target=https%3A%2F%2Fstudip.uni-hannover.de%2Fdispatch.php%2Flogin%3Fsso%3Dshib%26again%3Dyes%26cancel_login%3D1&entityID=https%3A%2F%2Fsso.idm.uni-hannover.de%2Fidp%2Fshibboleth")
        XCTAssertEqual(StudIPSync.ssoLoginURL(base: URL(string: "https://studip.uni-hannover.de/")!), StudIPSync.ssoLoginURL(base: URL(string: "https://studip.uni-hannover.de")!))
    }

    func testOnlyStudIPCookiesAreKept() {
        func c(_ domain: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: "/", .name: "n", .value: "v"])!
        }
        let kept = StudIPSync.ownCookies([c("studip.uni-hannover.de"), c(".uni-hannover.de"), c("sso.idm.uni-hannover.de"), c("example.org")],
                                         host: "studip.uni-hannover.de")
        XCTAssertEqual(kept.map(\.domain), ["studip.uni-hannover.de", ".uni-hannover.de"], "die Uni-Anmeldung selbst bleibt in der Webansicht")
    }
}
