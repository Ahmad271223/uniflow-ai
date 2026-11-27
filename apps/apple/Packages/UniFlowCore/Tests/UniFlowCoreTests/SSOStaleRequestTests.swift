import Foundation
import XCTest
@testable import UniFlowCore

/// "Veraltete Anfrage" des WebSSO der LUH (26.11.2026: Anmeldeseite eine halbe Stunde offen, danach abgeschickt). Aufbau
/// wie die echte Seite (oeffentlich, ohne Anmeldung abrufbar: Formular-Adresse ohne Sitzung), Text gekuerzt.
final class SSOStaleRequestTests: XCTestCase {
    private let idp = URL(string: "https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO?execution=e1s2")!

    private func page(_ heading: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="UTF-8" /><link rel="stylesheet" href="/idp/css/luh.css"></head>
        <body><main class="main"><header><img class="main-logo" src="/idp/images/luh_logo.svg" alt="Leibniz Universität Hannover" /></header>
        <section>
            <h1>\(heading)</h1>
            <p><p>Die aufgerufene Seite bzw. das aufgerufene Formular ist ungültig oder abgelaufen.</p></p>
        </section></main></body></html>
        """
    }

    func testStalePageOfTheLUHWebSSOIsRecognized() {
        XCTAssertTrue(SSOStaleRequest.isStale(url: idp, html: page("WebSSO Login Service - Veraltete Anfrage")))
        XCTAssertTrue(SSOStaleRequest.isStale(url: idp, html: page("WebSSO Login Service - Stale Request")), "englische Seite")
        XCTAssertTrue(SSOStaleRequest.isStale(url: idp, html: page("WebSSO Login Service -\n   <span>Veraltete   Anfrage</span>")),
                      "Zeilenumbruch und Auszeichnung in der Ueberschrift")
    }

    func testOtherPagesAreNotTouched() {
        // die normale Anmeldeseite und der Zwischenschritt des IdP
        XCTAssertFalse(SSOStaleRequest.isStale(url: idp, html: page("WebSSO Login Service - Loading Session Information")))
        XCTAssertFalse(SSOStaleRequest.isStale(url: idp, html: page("Anmelden bei Stud.IP")))
        // dieselben Woerter nur im Fliesstext, nicht in der Ueberschrift
        XCTAssertFalse(SSOStaleRequest.isStale(url: idp, html: "<h1>Hilfe</h1><p>Was heisst Veraltete Anfrage?</p>"))
        // dieselbe Ueberschrift ausserhalb eines IdP (Stud.IP, Forum, Learnweb) ist nie gemeint
        let studip = URL(string: "https://studip.uni-hannover.de/dispatch.php/forum")!
        XCTAssertFalse(SSOStaleRequest.isStale(url: studip, html: page("Veraltete Anfrage")))
        XCTAssertFalse(SSOStaleRequest.isStale(url: URL(string: "http://sso.idm.uni-hannover.de/idp/profile/x"), html: page("Veraltete Anfrage")),
                       "nur HTTPS")
        XCTAssertFalse(SSOStaleRequest.isStale(url: nil, html: page("Veraltete Anfrage")))
        XCTAssertTrue(SSOStaleRequest.mayBeStale(idp))
        XCTAssertFalse(SSOStaleRequest.mayBeStale(URL(string: "https://www.uni-hildesheim.de/cas/login")))
    }

    func testReloadsAreLimited() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(SSOStaleRequest.mayReload(past: [], now: now))
        XCTAssertTrue(SSOStaleRequest.mayReload(past: [now.addingTimeInterval(-30)], now: now))
        XCTAssertFalse(SSOStaleRequest.mayReload(past: [now.addingTimeInterval(-50), now.addingTimeInterval(-10)], now: now),
                       "zweimal in zwei Minuten: die Seite bleibt stehen, kein Kreislauf")
        XCTAssertTrue(SSOStaleRequest.mayReload(past: [now.addingTimeInterval(-600), now.addingTimeInterval(-300)], now: now),
                      "spaeter (Seite wieder lange offen) darf es wieder")
    }
}
