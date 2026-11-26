import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// "Veraltete Anfrage" des WebSSO in der Anmelde-Webansicht (26.11.2026, LUH: Anmeldeseite eine halbe Stunde offen,
/// danach abgeschickt, die App blieb auf der Fehlerseite stehen). Die Seiten sind nachgebaut (`loadHTMLString` mit der
/// Adresse des IdP), es geht nichts ins Netz ausser dem Neustart der Anmeldung an eine Adresse, die es nicht gibt.
@MainActor
final class SSOStaleReloadAppTests: XCTestCase {
    private let idp = URL(string: "https://sso.idm.uni-hannover.de/idp/profile/SAML2/Redirect/SSO?execution=e1s2")!
    private let start = URL(string: "https://studip.example.invalid/Shibboleth.sso/Login")!

    private func until(_ timeout: TimeInterval = 8, _ done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func setUp(_ loaded: @escaping (URL?) -> Void) -> (WKWebView, StudIPWebView.Coordinator, UFWebLoadState) {
        let load = UFWebLoadState()
        let coordinator = StudIPWebView.Coordinator(onPageLoaded: { loaded($0.url) }, load: load, start: start)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480),
                            configuration: StudIPWebView.loginConfiguration(dataStore: .nonPersistent()))
        web.navigationDelegate = coordinator
        load.webView = web
        return (web, coordinator, load)
    }

    func testStalePageStartsTheLoginAgainWithAHint() async throws {
        var loaded: [URL?] = []
        let (web, coordinator, load) = setUp { loaded.append($0) }
        web.loadHTMLString("<html><body><main><h1>WebSSO Login Service - Veraltete Anfrage</h1><p>Die aufgerufene Seite ist abgelaufen.</p></main></body></html>",
                           baseURL: idp)
        try await until { load.notice != nil }
        XCTAssertEqual(load.notice, SSOStaleRequest.notice, "Hinweis, warum das Formular wieder leer ist")
        XCTAssertTrue(loaded.isEmpty, "die Fehlerseite geht nicht an die Anmeldeansicht")
        // die Anmeldung beginnt von vorn: die erste Seite wird angefordert (hier ohne Netz: Ladefehler statt Seite)
        try await until { load.failure != nil || web.url?.host == self.start.host }
        XCTAssertTrue(load.failure != nil || web.url?.host == start.host, "neu geladen wird die erste Seite der Anmeldung")
        withExtendedLifetime(coordinator) {}
    }

    func testOtherIdPPagesGoToTheLoginViewUnchanged() async throws {
        var loaded: [URL?] = []
        let (web, coordinator, load) = setUp { loaded.append($0) }
        web.loadHTMLString("<html><body><h1>Anmelden bei Stud.IP</h1><form><input name=\"j_username\"></form></body></html>", baseURL: idp)
        try await until { !loaded.isEmpty }
        XCTAssertEqual(loaded, [idp])
        XCTAssertNil(load.notice)
        // eine Seite ausserhalb eines IdP mit denselben Woertern ebenso
        let forum = URL(string: "https://studip.uni-hannover.de/dispatch.php/forum")!
        web.loadHTMLString("<html><body><h1>Veraltete Anfrage</h1></body></html>", baseURL: forum)
        try await until { loaded.count == 2 }
        XCTAssertEqual(loaded, [idp, forum])
        XCTAssertNil(load.notice)
        withExtendedLifetime(coordinator) {}
    }

    func testHintDisappearsAfterLeavingTheIdP() async throws {
        var loaded: [URL?] = []
        let (web, coordinator, load) = setUp { loaded.append($0) }
        load.notice = SSOStaleRequest.notice
        let studip = URL(string: "https://studip.uni-hannover.de/dispatch.php/start")!
        web.loadHTMLString("<html><body><h1>Meine Startseite</h1></body></html>", baseURL: studip)
        try await until { !loaded.isEmpty }
        XCTAssertNil(load.notice, "angemeldet: der Hinweis verschwindet")
        withExtendedLifetime(coordinator) {}
    }
}
