import CryptoKit
import Security
import UniFlowCore
import WebKit
import XCTest
@testable import UniFlow

/// Feste Antworten fuer URLSession (nur in den Konfigurationen dieser Tests eingetragen): beantwortet jede Anfrage
/// selbst, nichts geht ins Netz (unbekannt = 404). Weiterleitungen meldet er wie HTTP (`wasRedirectedTo`), 307/308 mit
/// Methode und Koerper. Zeichnet Adresse, Methode, Kopfzeilen und Koerper jeder Anfrage auf.
final class UniStubProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()

        static func text(_ s: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers, body: Data(s.utf8))
        }
        static func redirect(_ status: Int, to location: String, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers.merging(["Location": location]) { a, _ in a })
        }
    }

    struct Seen {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
        var bodyText: String { String(decoding: body, as: UTF8.self) }
        var cookie: String { headers.first { $0.key.lowercased() == "cookie" }?.value ?? "" }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (Seen) -> Reply)?
    nonisolated(unsafe) private static var log: [Seen] = []

    static func install(_ h: @escaping @Sendable (Seen) -> Reply) { lock.withLock { handler = h; log = [] } }
    static func reset() { lock.withLock { handler = nil; log = [] } }
    static var requests: [Seen] { lock.withLock { log } }

    /// fluechtige Konfiguration, in der nur dieser Stub antwortet
    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [UniStubProtocol.self]
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let seen = Seen(url: url, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:], body: body)
        // Antwort ausserhalb der Sperre: ein Test darf eine Antwort zurueckhalten (laufender Download)
        let handler = Self.lock.withLock { () -> (@Sendable (Seen) -> Reply)? in
            Self.log.append(seen)
            return Self.handler
        }
        let reply = handler?(seen) ?? Reply(status: 404)
        let http = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if (300..<400).contains(reply.status), let loc = reply.headers["Location"], let to = URL(string: loc, relativeTo: url)?.absoluteURL {
            var next = URLRequest(url: to)
            if reply.status == 307 || reply.status == 308 {
                next.httpMethod = seen.method
                next.httpBody = body.isEmpty ? nil : body
            }
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: http)
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

/// Haelt eine Antwort von `UniStubProtocol` zurueck, bis der Test sie freigibt (ein Download "laeuft" noch). Wartet
/// hoechstens 10 s; nach der Freigabe wartet niemand mehr.
final class StubGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var reached = false
    private var open = false

    /// Eine Antwort wartet gerade bzw. hat gewartet
    var wasReached: Bool { lock.withLock { reached } }

    /// Im Stub (Lade-Thread von URLSession, nie der Hauptthread): bis zur Freigabe warten
    func pass() {
        let wait = lock.withLock { () -> Bool in
            reached = true
            return !open
        }
        if wait { _ = semaphore.wait(timeout: .now() + 10) }
    }

    func release() {
        lock.withLock { open = true }
        for _ in 0..<4 { semaphore.signal() }
    }
}

/// Uni Hildesheim in der App (docs/AUFTRAG-HILDESHEIM-IPAD.md, duenne Schicht): Transport mit den Cookies des
/// Containers, Abfangen des Learnweb-Schluessels in der Webansicht, Abgleich bis in Dokumente, Stundenplan und Noten,
/// LUH unveraendert. Kein Netz: URLSession nur mit `UniStubProtocol`, Webansicht mit lokaler Seite und Inhaltsregel,
/// die jedes Nachladen sperrt. Erfundene Nutzer, Cookies, Schluessel, Kurse und Leistungen; eigene Schluesselbund-
/// Dienste und UserDefaults-Suiten.
@MainActor
final class HildesheimAppTests: XCTestCase {

    private final class MemorySecrets: AccountSecretStore {
        var values: [String: String] = [:]
        func get(_ key: String) -> String? { values[key] }
        func set(_ value: String, for key: String) { values[key] = value }
        func delete(_ key: String) { values[key] = nil }
    }

    private struct Authorized: AppleCredentialChecking {
        func state(forUserID id: String) async -> AppleCredentialState { .authorized }
    }

    private var appSupport: URL!
    private var keychain: UniversityKeychain!
    private var cookieService = ""
    private var suite = ""
    private var defaults: UserDefaults!
    private var websiteStores: [UUID] = []
    private let user = "001234.erfunden-hilde.\(UUID().uuidString.prefix(8))"
    /// Montag, 26.10.2026, 10:00 in Berlin (WiSe 2026/27 -> learnweb2026)
    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T10:00:00")!
    private let base = "https://www.uni-hildesheim.de/learnweb2026"
    private let lsf = "https://lsf.uni-hildesheim.de"
    private let token = "TestSchluessel0123456789abcdef"

    override func setUp() async throws {
        try await super.setUp()
        appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-hildesheim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        keychain = UniversityKeychain(service: "de.uniflow.ai.university.test.\(UUID().uuidString)")
        cookieService = "de.uniflow.ai.studip.test.\(UUID().uuidString)"
        suite = "uniflow.tests.hildesheim.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        UniStubProtocol.reset()
    }

    override func tearDown() async throws {
        UniStubProtocol.reset()
        keychain.accounts().forEach(keychain.remove)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: cookieService] as CFDictionary)
        defaults.removePersistentDomain(forName: suite)
        for layout in DataContainerLayout.all(base: containers, userID: user) {
            let s = ActiveContainer.defaultsSuite(layout.identifier)
            UserDefaults(suiteName: s)?.removePersistentDomain(forName: s)
            websiteStores.append(layout.identifier)
        }
        for id in Set(websiteStores) {
            await WKWebsiteDataStore(forIdentifier: id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
        try? FileManager.default.removeItem(at: appSupport)
        try await super.tearDown()
    }

    private var containers: URL { appSupport.appendingPathComponent("UniFlowContainers", isDirectory: true) }

    /// Container-Verwaltung wie in der App, Hildesheimer Transport: URLSession mit den Cookies des Containers, aber
    /// mit dem Stub statt des Netzes
    private func manager() -> ContainerManager {
        ContainerManager(base: containers,
                         legacy: LegacyDataMigration.Sources(support: appSupport.appendingPathComponent("UniFlow", isDirectory: true),
                                                             studip: appSupport.appendingPathComponent("StudIP", isDirectory: true)),
                         keychain: keychain, cookieService: cookieService, defaults: defaults, clock: clock, publishesCurrent: false,
                         hildesheimTransport: { store in await URLSessionUniTransport.make(dataStore: store, configuration: UniStubProtocol.configuration()) })
    }

    private func account(_ uni: UniversityKey) -> AccountStore {
        let a = AccountStore(secrets: MemorySecrets(), defaults: defaults, checker: Authorized(), observeRevocation: false)
        a.signIn(userID: user, name: nil, email: nil)
        a.markPlanShown()
        a.chooseUniversity(uni)
        return a
    }

    private func hildesheim(_ m: ContainerManager, _ a: AccountStore) throws -> (ActiveContainer, HildesheimConnection) {
        m.sync(account: a)
        let c = try XCTUnwrap(m.active, m.problem ?? "kein Container")
        websiteStores.append(c.websiteDataStoreID)
        let h = try XCTUnwrap(m.hildesheim, "Verbindung der Uni Hildesheim fehlt")
        h.syncsAfterSignIn = false
        return (c, h)
    }

    private func cookie(_ name: String, _ value: String, domain: String, path: String = "/") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE",
                                .expires: Date().addingTimeInterval(3600)])!
    }

    private func repo(_ relative: String) throws -> Data {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return try Data(contentsOf: url.appendingPathComponent(relative))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Zeitueberschreitung: \(what)")
    }

    // MARK: Transport

    private func transport(_ cookies: [HTTPCookie]) -> URLSessionUniTransport {
        URLSessionUniTransport(cookies: cookies, allowedDomains: ["hochschule.test"], configuration: UniStubProtocol.configuration())
    }

    func testTransportSendsOnlyTheCookiesOfItsContainer() async throws {
        UniStubProtocol.install { _ in .text("ok") }
        // zwei Container: je ein eigener Datenspeicher der Webansicht
        let a = WKWebsiteDataStore.nonPersistent(), b = WKWebsiteDataStore.nonPersistent()
        await a.httpCookieStore.setCookie(cookie("MoodleSession", "sitzung-a", domain: "learnweb.hochschule.test"))
        await a.httpCookieStore.setCookie(cookie("JSESSIONID", "nur-lsf", domain: "lsf.hochschule.test"))
        await b.httpCookieStore.setCookie(cookie("MoodleSession", "sitzung-b", domain: "learnweb.hochschule.test"))
        let ta = await URLSessionUniTransport.make(dataStore: a, allowedDomains: ["hochschule.test"], configuration: UniStubProtocol.configuration())
        let tb = await URLSessionUniTransport.make(dataStore: b, allowedDomains: ["hochschule.test"], configuration: UniStubProtocol.configuration())
        let url = URL(string: "https://learnweb.hochschule.test/my/courses.php")!
        _ = try await ta.send(UniRequest(url: url))
        _ = try await tb.send(UniRequest(url: url))
        _ = try await ta.send(UniRequest(url: URL(string: "https://lsf.hochschule.test/qisserver/rds")!, headers: ["Cookie": "fremd=1"]))
        let seen = UniStubProtocol.requests
        XCTAssertEqual(seen.map(\.cookie), ["MoodleSession=sitzung-a", "MoodleSession=sitzung-b", "JSESSIONID=nur-lsf"],
                       "je Container nur seine Cookies, je Rechner nur die passenden, keine fremde Cookie-Kopfzeile")
    }

    /// Gemeinsamer Vertrag learnweb/launch.json, "cookie_header": nur Cookies, deren Domain zum Rechner passt und
    /// die nicht abgelaufen sind; ein fremder Rechner bekommt keine (das iPad fragt ihn gar nicht an). Die Ablaufzeiten
    /// der Fixture gelten zu ihrem "now" und werden auf die Uhr verschoben. Die Reihenfolge der Cookies in der Kopfzeile
    /// bestimmt `HTTPCookieStorage` (fuer Server ohne Bedeutung, RFC 6265 5.4); verglichen wird die Menge.
    func testCookieHeaderLikeLaunchFixture() async throws {
        UniStubProtocol.install { _ in .text("ok") }
        let fx = try JSONValue.parse(repo("packages/shared-contracts/fixtures/learnweb/launch.json"))["cookie_header"]
        let shift = Date().timeIntervalSince1970 - (fx?["now"]?.double ?? 0)
        let cookies = (fx?["cookies"]?.array ?? []).compactMap { c -> HTTPCookie? in
            var p: [HTTPCookiePropertyKey: Any] = [.name: c["name"]?.string ?? "", .value: c["value"]?.string ?? "",
                                                   .domain: c["domain"]?.string ?? "", .path: c["path"]?.string ?? "/"]
            if let e = c["expires"]?.double, e >= 0 { p[.expires] = Date(timeIntervalSince1970: e + shift) }
            return HTTPCookie(properties: p)
        }
        XCTAssertEqual(cookies.count, 4)
        let t = URLSessionUniTransport(cookies: cookies, allowedDomains: ["uni-hannover.de", "uni-hildesheim.de"],
                                       configuration: UniStubProtocol.configuration())
        let cases = fx?["cases"]?.array ?? []
        XCTAssertEqual(cases.count, 3)
        for c in cases {
            let url = try XCTUnwrap(URL(string: c["url"]?.string ?? ""))
            let expected = Set((c["header"]?.string ?? "").components(separatedBy: "; ").filter { !$0.isEmpty })
            guard t.allows(url) else {
                XCTAssertEqual(expected, [], "fremder Rechner \(url): keine Anfrage, also keine Cookies")
                continue
            }
            _ = try await t.send(UniRequest(url: url))
            let sent = Set((UniStubProtocol.requests.last?.cookie ?? "").components(separatedBy: "; ").filter { !$0.isEmpty })
            XCTAssertEqual(sent, expected, url.absoluteString)
        }
    }

    func testRedirectsCanBeSwitchedOffAndKeepCookiesPerTarget() async throws {
        let t = transport([cookie("MoodleSession", "s1", domain: "learnweb.hochschule.test")])
        UniStubProtocol.install { r in
            switch r.url.path {
            case "/mod/resource/view.php":
                return .redirect(303, to: "https://learnweb.hochschule.test/pluginfile.php/5/mod_resource/content/4/Folien.pdf",
                                 headers: ["Set-Cookie": "Neu=n1; Path=/; Secure"])
            case "/pluginfile.php/5/mod_resource/content/4/Folien.pdf": return .text("%PDF-1.7 Folien")
            case "/sprung": return .redirect(302, to: "https://lsf.hochschule.test/ziel")
            case "/ziel": return .text("ziel")
            default: return .text("nicht da", status: 404)
            }
        }
        let view = URL(string: "https://learnweb.hochschule.test/mod/resource/view.php?id=7&redirect=1")!
        let off = try await t.send(UniRequest(url: view, followRedirects: false))
        XCTAssertEqual(off.status, 303)
        XCTAssertEqual(off.headers["location"], "https://learnweb.hochschule.test/pluginfile.php/5/mod_resource/content/4/Folien.pdf")
        XCTAssertEqual(UniStubProtocol.requests.count, 1, "Ziel der Weiterleitung nicht abgerufen")

        let on = try await t.send(UniRequest(url: view))
        XCTAssertEqual(on.status, 200)
        XCTAssertEqual(on.text, "%PDF-1.7 Folien")
        XCTAssertEqual(on.finalURL?.path, "/pluginfile.php/5/mod_resource/content/4/Folien.pdf")
        let target = try XCTUnwrap(UniStubProtocol.requests.last)
        XCTAssertTrue(target.cookie.contains("MoodleSession=s1") && target.cookie.contains("Neu=n1"), target.cookie)

        // Weiterleitung auf einen anderen Rechner: dessen Cookies (keine), nicht die der Learnweb-Sitzung
        _ = try await t.send(UniRequest(url: URL(string: "https://learnweb.hochschule.test/sprung")!))
        XCTAssertEqual(UniStubProtocol.requests.last?.url.host, "lsf.hochschule.test")
        XCTAssertEqual(UniStubProtocol.requests.last?.cookie, "")
    }

    func testBodyNeverLeavesTheHostAndOnlyHTTPSOfTheUniversity() async throws {
        let t = transport([])
        UniStubProtocol.install { r in
            switch r.url.host {
            case "learnweb.hochschule.test" where r.url.path == "/fremd": return .redirect(307, to: "https://fremd.example/dl")
            // anderer Rechner derselben Hochschule: GET folgen, Koerper (307) nie mitnehmen
            case "learnweb.hochschule.test" where r.url.path == "/nebenan": return .redirect(307, to: "https://lsf.hochschule.test/dl")
            case "learnweb.hochschule.test" where r.url.path == "/unsicher": return .redirect(302, to: "http://learnweb.hochschule.test/x")
            default: return .text("darf nie ankommen")
            }
        }
        let r = try await t.send(UniRequest(url: URL(string: "https://learnweb.hochschule.test/fremd")!, method: "POST",
                                            body: Data("token=GEHEIM".utf8)))
        XCTAssertEqual(r.status, 307, "Weiterleitung auf fremden Rechner nicht verfolgt")
        let r1 = try await t.send(UniRequest(url: URL(string: "https://learnweb.hochschule.test/nebenan")!, method: "POST",
                                             body: Data("token=GEHEIM".utf8)))
        XCTAssertEqual(r1.status, 307, "Schluessel im Koerper geht nicht an einen anderen Rechner der Hochschule")
        let r2 = try await t.send(UniRequest(url: URL(string: "https://learnweb.hochschule.test/unsicher")!))
        XCTAssertEqual(r2.status, 302, "nie auf http")
        for bad in ["https://example.com/x", "http://learnweb.hochschule.test/x", "https://learnweb.hochschule.test:8443/x",
                    "https://nichthochschule.test/x"] {
            do {
                _ = try await t.send(UniRequest(url: URL(string: bad)!))
                XCTFail("\(bad) haette abgelehnt werden muessen")
            } catch {
                XCTAssertFalse("\(error)".contains("example.com"), "Meldung ohne Adresse")
            }
        }
        XCTAssertEqual(UniStubProtocol.requests.map { $0.url.host ?? "" }, ["learnweb.hochschule.test", "learnweb.hochschule.test", "learnweb.hochschule.test"],
                       "nichts an fremde Rechner, der Schluessel im Koerper blieb beim Learnweb")
        XCTAssertEqual(URLSessionUniTransport.hildesheimDomains, ["lsf.uni-hildesheim.de", "uni-hildesheim.de"])
    }

    func testDownloadGoesIntoTheFileAndReplacesAnOldOne() async throws {
        let t = transport([])
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        UniStubProtocol.install { _ in UniStubProtocol.Reply(status: 200, headers: ["Content-Type": "application/pdf"], body: payload) }
        let dest = appSupport.appendingPathComponent("datei.part")
        try Data("alt".utf8).write(to: dest)
        let r = try await t.download(UniRequest(url: URL(string: "https://learnweb.hochschule.test/webservice/pluginfile.php/6/a.pdf")!,
                                                method: "POST", body: Data("token=T".utf8)), to: dest)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["content-type"], "application/pdf")
        XCTAssertTrue(r.body.isEmpty, "Inhalt nur in der Datei")
        XCTAssertEqual(try Data(contentsOf: dest), payload)
        XCTAssertEqual(UniStubProtocol.requests.first?.bodyText, "token=T")
        XCTAssertEqual(UniStubProtocol.requests.first?.method, "POST")
    }

    // MARK: Learnweb-Schluessel aus dem Moodle-SSO

    /// Antwort von tool_mobile_get_public_config einer Learnweb-Instanz (laeuft im Stub, nicht auf dem MainActor)
    nonisolated private static func publicConfig(base: String, siteName: String = "Learnweb SoSe 2026 - WiSe 2026/27") -> UniStubProtocol.Reply {
        let data: JSONValue = ["sitename": .string(siteName), "wwwroot": .string(base), "httpswwwroot": .string(base),
                               "launchurl": .string(base + "/admin/tool/mobile/launch.php"), "enablemobilewebservice": 1,
                               "typeoflogin": 1, "identityproviders": [["name": "CAS"]]]
        return UniStubProtocol.Reply(status: 200, headers: ["Content-Type": "application/json"],
                                     body: JSONValue.array([["error": false, "data": data]]).serialized())
    }

    /// `<schema>://token=` + base64(md5(wwwroot + passport) ":::" token ":::" privatetoken), MD5 hier mit CryptoKit
    private func tokenRedirect(passport: String, site: String? = nil, token: String) -> String {
        let md5 = Insecure.MD5.hash(data: Data(((site ?? base) + passport).utf8)).map { String(format: "%02x", $0) }.joined()
        return "moodlemobile://token=" + Data("\(md5):::\(token):::Privat987".utf8).base64EncodedString()
    }

    private func blockAll() async throws -> WKContentRuleList {
        let rules = #"[{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}]"#
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "uniflow.tests.blockall.hi",
                                                                                      encodedContentRuleList: rules)
        return try XCTUnwrap(list)
    }

    func testLearnwebTokenIsCaughtInTheWebViewAndStoredInTheKeychain() async throws {
        let m = manager()
        let (c, h) = try hildesheim(m, account(.hildesheim))
        UniStubProtocol.install { [base] r in
            r.url.absoluteString.hasPrefix(base + "/lib/ajax/service-nologin.php") ? Self.publicConfig(base: base) : .text("", status: 404)
        }
        let login = HildesheimLogin(target: .learnweb, connection: h)
        await login.prepare()
        guard case .page(let launch) = login.stage else { return XCTFail("keine Startseite: \(login.stage)") }
        XCTAssertTrue(login.viaToken, "SSO moeglich: Schluessel statt Sitzung")
        XCTAssertTrue(launch.absoluteString.hasPrefix(base + "/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport="), launch.absoluteString)
        XCTAssertTrue(launch.absoluteString.hasSuffix("&urlscheme=moodlemobile"))
        let passport = try XCTUnwrap(URLComponents(url: launch, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "passport" }?.value)
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.url.path.contains("launch.php") }, "die Startseite oeffnet nur die Webansicht")

        // Webansicht wie die Anmeldeansicht (Coordinator mit intercept), lokale Seite statt Moodle, kein Nachladen
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(try await blockAll())
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let coordinator = StudIPWebView.Coordinator(onPageLoaded: { _ in }, autofill: nil, intercept: { login.intercept($0) })
        web.navigationDelegate = coordinator
        let redirect = tokenRedirect(passport: passport, token: token)
        web.loadHTMLString("<!doctype html><html><body><p>Learnweb (Test)</p><script>setTimeout(function () { location.href = '\(redirect)'; }, 100);</script></body></html>",
                           baseURL: launch)
        try await waitUntil("Schluessel abgefangen") { login.stage == .done }
        XCTAssertEqual(web.url, launch, "Weiterleitung abgebrochen, nicht an das System gegeben")
        let account = try XCTUnwrap(c.key.university.profile.keychainAccount(service: "learnweb", field: "token", userScope: c.key.userScope))
        XCTAssertEqual(account, "\(c.key.userScope).hildesheim.learnweb.token")
        XCTAssertEqual(keychain.read(account), token, "Schluessel im Schluesselbund unter dem Namen aus dem Kern")
        XCTAssertEqual(h.learnwebMode, .token)
        XCTAssertEqual(h.learnweb, .connected)
        XCTAssertFalse(h.needsAttention(.learnweb), "Karte Learnweb verbinden verschwindet")
        XCTAssertTrue(h.needsAttention(.lsf))
        XCTAssertTrue(login.intercept(URL(string: redirect)!), "zweite Antwort mit demselben Passport: abgefangen, nicht noch einmal gespeichert")
        XCTAssertEqual(login.stage, .done)

        // fremder Passport bzw. fremde Learnweb-Adresse: nichts gespeichert, Meldung
        let other = HildesheimLogin(target: .learnweb, connection: h)
        await other.prepare()
        guard case .page = other.stage else { return XCTFail("keine Startseite") }
        XCTAssertTrue(other.intercept(URL(string: tokenRedirect(passport: passport, token: "Anderer1"))!), "abgefangen, auch wenn falsch")
        guard case .failed = other.stage else { return XCTFail("falscher Passport angenommen: \(other.stage)") }
        XCTAssertEqual(keychain.read(account), token)
        // andere Schemata nie an das System, http(s) laedt normal
        XCTAssertTrue(other.intercept(URL(string: "mailto:test@example.org")!))
        XCTAssertFalse(other.intercept(URL(string: base + "/login/index.php")!))
    }

    func testWithoutAppSchemeTheSessionPathIsUsed() async throws {
        let m = manager()
        let (_, h) = try hildesheim(m, account(.hildesheim))
        UniStubProtocol.install { [base] r in
            guard r.url.absoluteString.hasPrefix(base + "/lib/ajax/service-nologin.php") else { return .text("", status: 404) }
            // Mobile-Webservice aus
            let data: JSONValue = ["sitename": "Learnweb SoSe 2026 - WiSe 2026/27", "enablemobilewebservice": 0]
            return UniStubProtocol.Reply(status: 200, body: JSONValue.array([["error": false, "data": data]]).serialized())
        }
        let login = HildesheimLogin(target: .learnweb, connection: h)
        await login.prepare()
        XCTAssertEqual(login.stage, .page(URL(string: HildesheimCAS.learnwebLoginURL(base: base))!))
        XCTAssertFalse(login.viaToken)
        // angemeldete Learnweb-Seite (sesskey, ohne notloggedin) beendet die Anmeldung
        login.pageLoaded(url: URL(string: base + "/my/"), html: #"<body class="notloggedin"><script>M.cfg={"sesskey":"abc"}</script></body>"#)
        XCTAssertEqual(h.learnwebMode, nil, "Anmeldeseite mit sesskey zaehlt nicht")
        login.pageLoaded(url: URL(string: "https://www.uni-hildesheim.de/sso/login?service=x"),
                         html: #"<div id="loginErrorsPanel">Ungültige Anmeldedaten</div>"#)
        XCTAssertEqual(login.casError, "Ungültige Anmeldedaten")
        login.pageLoaded(url: URL(string: base + "/my/"), html: #"<body class="pagelayout-mydashboard"><script>M.cfg={"sesskey":"abc"}</script></body>"#)
        XCTAssertEqual(login.stage, .done)
        XCTAssertEqual(h.learnwebMode, .session)

        // LSF: fertig erst auf lsf.uni-hildesheim.de mit "Abmelden"
        let lsfLogin = HildesheimLogin(target: .lsf, connection: h)
        await lsfLogin.prepare()
        XCTAssertEqual(lsfLogin.stage, .page(URL(string: HildesheimCAS.lsfLoginURL)!))
        lsfLogin.pageLoaded(url: URL(string: "https://www.uni-hildesheim.de/sso/login?service=x"), html: "Abmelden")
        XCTAssertFalse(h.lsfConnected)
        lsfLogin.pageLoaded(url: URL(string: lsf + "/qisserver/rds?state=user&type=0"), html: "<a>Anmelden</a>")
        XCTAssertFalse(h.lsfConnected)
        lsfLogin.pageLoaded(url: URL(string: lsf + "/qisserver/rds?state=user&type=0"), html: #"<a href="x">Abmelden</a>"#)
        XCTAssertEqual(lsfLogin.stage, .done)
        XCTAssertTrue(h.lsfConnected)
    }

    // MARK: Abgleich bis in die Seiten

    /// Learnweb (REST mit Schluessel) und LSF (Sitzung) wie die Uni, Inhalte aus packages/shared-contracts/fixtures/hildesheim
    /// (auch fuer DataSeparationAppTests)
    nonisolated static func uniHildesheim(base: String, lsf: String, token: String, ics: Data,
                                          contents: Data) -> @Sendable (UniStubProtocol.Seen) -> UniStubProtocol.Reply {
        let gradePage = """
            <html><body><a href="rds?state=user&amp;type=4">Abmelden</a>
            <table summary="Angaben zur Person"><tr><td>Name</td><td>Testperson Muster</td></tr><tr><td>Matrikelnummer</td><td>990001</td></tr></table>
            <table><tr><td colspan="5">Abschluss: [82] Bachelor Studiengang: [052] B.A. Testfach PO-Version: 2022</td></tr>
            <tr><th>Prüfungsnr.</th><th>Bezeichnung der Leistung / der Lehrveranstaltung</th><th>Note</th><th>Status</th><th>Bonus</th></tr>
            <tr><td>5010</td><td>Modul 1</td><td></td><td></td><td>12</td></tr>
            <tr><td>5011</td><td>TM 1: Grundlagen</td><td>1,7</td><td>bestanden</td><td>6</td></tr>
            <tr><td>5012</td><td>TM 2: Wohnen</td><td>2,3</td><td>bestanden</td><td>4</td></tr></table></body></html>
            """
        return { r in
            let u = r.url.absoluteString
            if u.hasPrefix(base + "/lib/ajax/service-nologin.php") { return publicConfig(base: base) }
            if u.hasPrefix(base + "/webservice/rest/server.php") {
                let form = r.bodyText
                guard form.contains("wstoken=\(token)") else { return .text(#"{"exception":"x","errorcode":"invalidtoken"}"#) }
                if form.contains("wsfunction=core_webservice_get_site_info") { return .text(#"{"userid": 42}"#) }
                if form.contains("wsfunction=core_enrol_get_users_courses") {
                    return .text(#"[{"id": 35, "fullname": "WiSe 2026/27: 9072 Das Testzimmer", "hidden": 0}]"#)
                }
                if form.contains("courseid=35") { return UniStubProtocol.Reply(status: 200, body: contents) }
                return .text("[]")
            }
            if u.hasPrefix(base + "/webservice/pluginfile.php/") {
                guard r.method == "POST", r.bodyText == "token=\(token)" else { return .text(#"{"error":"x","errorcode":"invalidtoken"}"#) }
                return .text(u.contains("/pluginfile.php/5/") ? "%PDF-1.7 plan" : "%PDF-1.7 einfuehrung")
            }
            if u.hasPrefix(lsf + "/qisserver/rds") {
                // LSF nur mit der Sitzung aus der Webansicht des Containers, sonst zurueck zum CAS
                guard r.cookie.contains("JSESSIONID=lsf-sitzung-test") else {
                    return .redirect(302, to: "https://www.uni-hildesheim.de/sso/login?service=lsf")
                }
                let q = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                switch q.first(where: { $0.name == "state" })?.value {
                case "wplan":
                    return .text(#"<a href="x">Abmelden</a><a href="\#(lsf)/qisserver/rds?state=verpublish&amp;status=transform&amp;moduleCall=iCalendarPlan&amp;termine=1">iCal</a>"#)
                case "verpublish": return UniStubProtocol.Reply(status: 200, headers: ["Content-Type": "text/calendar"], body: ics)
                case "user": return .text(#"<a href="x">Abmelden</a><a href="rds?state=notenspiegelStudent&amp;nodeID=a">Studien-/Prüfungsleistungen (Notenspiegel)</a>"#)
                case "notenspiegelStudent": return .text(gradePage)
                default: return .text("", status: 404)
                }
            }
            if u.hasPrefix("https://www.uni-hildesheim.de/sso/login") { return .text("<html>CAS-Anmeldung (Test)</html>") }
            return .text("", status: 404)
        }
    }

    private func day(_ c: ActiveContainer, _ date: String, start: String) async throws -> [String?] {
        let d = try await c.api.value("/api/timetable/day?date=\(date)")
        return (d["events"]?.array ?? []).filter { $0["start"]?.string == start }.map { $0["status"]?.string }
    }

    func testHildesheimChosenSyncFillsDocumentsTimetableAndGradesAndLUHStaysAsItWas() async throws {
        let ics = try repo("packages/shared-contracts/fixtures/hildesheim/lsf-course.ics")
        let contents = try repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json")
        let m = manager()
        let a = account(.hildesheim)
        let (c, h) = try hildesheim(m, a)
        XCTAssertEqual(UFDataMode.current(api: c.api, studip: m.studip), .local(.otherSources))
        XCTAssertTrue(h.needsAttention(.learnweb) && h.needsAttention(.lsf), "zuerst die Karten Learnweb/LSF verbinden")
        let nothing = await h.run()
        XCTAssertNil(nothing, "ohne Verbindung kein Abgleich")

        // nach den Anmeldungen: Schluessel aus dem SSO, LSF-Sitzung im Datenspeicher der Webansicht des Containers
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(cookie("JSESSIONID", "lsf-sitzung-test", domain: "lsf.uni-hildesheim.de"))
        XCTAssertTrue(h.learnwebSignedIn(token: try XCTUnwrap(LearnwebToken(token)), base: base))
        h.lsfSignedIn()
        UniStubProtocol.install(Self.uniHildesheim(base: base, lsf: lsf, token: token, ics: ics, contents: contents))

        let runs = h.finishedRuns
        let report = try unwrap(await h.run())
        XCTAssertTrue(report.ok, report.messages.joined(separator: "; "))
        XCTAssertEqual(report.completed, ["Learnweb", "LSF-Stundenplan", "Notenspiegel"])
        XCTAssertEqual(report.newFiles.count, 2)
        XCTAssertEqual(h.finishedRuns, runs + 1, "Seiten laden danach neu (ufReload)")
        XCTAssertEqual(h.learnweb, .ok(clock.now))
        XCTAssertEqual(h.lsf, .ok(clock.now))
        XCTAssertEqual(HildesheimConnection.statusText(.learnweb, h.learnweb, now: clock.now), "Learnweb: 10:00 ok")
        XCTAssertEqual(h.messages.first, "2 neue/geänderte Dateien aus 1 Learnweb-Kursen")

        // Netz: Schluessel nie in einer Adresse, Downloads per POST an die eigene Pluginfile-Adresse, LSF mit der
        // Sitzung des Containers, die LSF-Sitzung nie beim Learnweb
        let seen = UniStubProtocol.requests
        XCTAssertFalse(seen.contains { $0.url.absoluteString.contains(token) })
        let downloads = seen.filter { $0.url.path.contains("/webservice/pluginfile.php/") }
        XCTAssertEqual(downloads.count, 2)
        XCTAssertTrue(downloads.allSatisfy { $0.method == "POST" && $0.bodyText == "token=\(token)" })
        XCTAssertTrue(seen.filter { $0.url.host == "lsf.uni-hildesheim.de" }.allSatisfy { $0.cookie.contains("JSESSIONID=lsf-sitzung-test") })
        XCTAssertFalse(seen.filter { $0.url.host == "www.uni-hildesheim.de" }.contains { $0.cookie.contains("JSESSIONID") })

        // Dokumente & Notizen und Module: dieselben Endpunkte wie fuer Stud.IP, Pfade relativ zum Container
        let db = try await c.host.backend().context.database
        let files = try await db.rows("SELECT id, name, local_path FROM files WHERE course_id='lw-35' ORDER BY name")
        XCTAssertEqual(files.compactMap { $0["name"]?.string }, ["Einführung.pdf", "plan.pdf"])
        for f in files {
            let path = f["local_path"]?.string ?? ""
            XCTAssertTrue(path.hasPrefix("Learnweb/files/lw-"), path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: c.layout.root.appendingPathComponent(path).path))
        }
        let einf = try XCTUnwrap(files.first?["id"]?.string)
        let (pdf, http) = try await c.api.data("/api/files/\(einf)/content")
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(decoding: pdf, as: UTF8.self), "%PDF-1.7 einfuehrung")
        let library = try await c.api.value("/api/library").jsonString()
        XCTAssertTrue(library.contains("plan.pdf") && library.contains(einf), "Dateien in Dokumente & Notizen")
        // "__user__" ist der Kurs der eigenen Dokumente (legt die Bibliothek an)
        let courses = (try await c.api.value("/api/courses").array ?? []).filter { $0["id"]?.string != "__user__" }
        XCTAssertEqual(courses.compactMap { $0["id"]?.string }, ["lw-35"])
        XCTAssertEqual(courses.first?["subject"]?.string, "Das Testzimmer")
        XCTAssertEqual(courses.first?["file_count"]?.int, 2)
        let modules = try await c.api.value("/api/modules").jsonString()
        XCTAssertTrue(modules.contains("Das Testzimmer"), "Modul aus dem Learnweb-Kurs")
        let sha = try await db.scalar("SELECT content_sha256 FROM files WHERE id=?", [.text(einf)])?.string
        XCTAssertEqual(sha, SolutionSHA256.hex(Data("%PDF-1.7 einfuehrung".utf8)), "Inhalts-Hash aus dem Kern (ContentHash.file)")

        // Stundenplan: LSF-Serie am Donnerstag (DTSTART ist der Montag), Ausfall an Heiligabend
        let thursday = try await day(c, "2026-10-29", start: "16:00")
        XCTAssertEqual(thursday, ["teilnahme"])
        let monday = try await day(c, "2026-10-26", start: "16:00")
        XCTAssertEqual(monday, [], "nicht am Montag aus DTSTART")
        let christmasEve = try await day(c, "2026-12-24", start: "16:00")
        XCTAssertEqual(christmasEve, ["ausfall"])

        // Uni & Noten: nur die Leistungstabelle, keine Stammdaten
        let grades = try await c.api.value("/api/grades")
        XCTAssertEqual(grades["grades"]?.array?.compactMap { $0["text"]?.string }.sorted(), ["TM 1: Grundlagen", "TM 2: Wohnen"])
        XCTAssertEqual(grades["average"], 1.94)
        XCTAssertEqual(grades["passed"], 2)
        XCTAssertEqual(grades["last_run"]?["ok"], 1)
        let all = try await db.rows("SELECT * FROM grades")
        XCTAssertFalse(JSONValue.array(all.map(JSONValue.object)).jsonString().contains("Muster"), "Stammdaten nie gespeichert")
        XCTAssertFalse(JSONValue.array(all.map(JSONValue.object)).jsonString().contains("990001"))
        XCTAssertEqual(UFGatePresentation.resolve(spec: .services, mode: .local(.otherSources), phase: m.studip.phase),
                       .pageBelowConnectCard, "Uni & Noten gibt es in Hildesheim lokal")

        // zweiter Lauf: nichts neu geladen, Noten erst nach 20 Stunden wieder
        let before = UniStubProtocol.requests.count
        let again = try unwrap(await h.run())
        XCTAssertEqual(again.newFiles, [])
        XCTAssertNil(again.grades, "Noten hoechstens alle 20 Stunden")
        XCTAssertEqual(again.plan?.new, 0)
        XCTAssertEqual(again.plan?.kept, 1)
        XCTAssertEqual(again.plan?.removed, 0)
        XCTAssertFalse(UniStubProtocol.requests[before...].contains { $0.url.path.contains("pluginfile") || $0.url.query?.contains("notenspiegel") == true })
        XCTAssertEqual(h.lsf, .ok(clock.now), "ohne Notenabruf trotzdem ok")
        let forced = try unwrap(await h.run(forceGrades: true))
        XCTAssertEqual(forced.grades, 2, "Noten abrufen auf Knopfdruck")

        // LUH: eigener Container, nichts aus Hildesheim, Stud.IP-Ablauf wie bisher
        a.chooseUniversity(.luh)
        m.sync(account: a)
        let luh = try XCTUnwrap(m.active)
        websiteStores.append(luh.websiteDataStoreID)
        XCTAssertNil(m.hildesheim, "keine Hildesheimer Verbindung an der LUH")
        XCTAssertTrue(m.studip.offersStudIP)
        XCTAssertEqual(UFDataMode.current(api: luh.api, studip: m.studip), .local(.notConnected), "Karte Stud.IP verbinden")
        let luhGrades = try await luh.api.value("/api/grades")
        XCTAssertEqual(luhGrades["grades"], [])
        let luhLibrary = try await luh.api.value("/api/library").jsonString()
        XCTAssertFalse(luhLibrary.contains("plan.pdf"))
        let luhDay = try await day(luh, "2026-10-29", start: "16:00")
        XCTAssertEqual(luhDay, [])
        let luhCookies = await m.websiteDataStore(for: luh).httpCookieStore.allCookies()
        XCTAssertTrue(luhCookies.isEmpty, "keine Hildesheimer Sitzung in der Webansicht der LUH")
        XCTAssertNil(luh.credentials.token(.hildesheim, service: "learnweb"), "kein Rueckfall auf den Hildesheimer Schluessel")
        XCTAssertEqual(UFGatePresentation.resolve(spec: .services, mode: .local(.notConnected), phase: m.studip.phase),
                       .pageBelowConnectCard, "Uni & Noten der LUH: Notenspiegel aus dem QIS auf dem Geraet")
        XCTAssertNotNil(m.qis, "QIS-Verbindung des LUH-Containers")
        XCTAssertFalse(m.qis?.isConnected ?? true, "nichts aus Hildesheim")

        // zurueck nach Hildesheim: Stand und Daten noch da
        a.chooseUniversity(.hildesheim)
        let (back, h2) = try hildesheim(m, a)
        XCTAssertEqual(back.layout.root, c.layout.root)
        XCTAssertEqual(h2.learnweb, .ok(clock.now), "Stand je Quelle aus den Einstellungen des Containers")
        XCTAssertEqual(h2.messages, h.messages)
        let backGrades = try await back.api.value("/api/grades")
        XCTAssertEqual(backGrades["grades"]?.array?.count, 2)
    }

    func testExpiredSessionsAskForLoginAndSignOutKeepsTheData() async throws {
        let ics = try repo("packages/shared-contracts/fixtures/hildesheim/lsf-course.ics")
        let contents = try repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json")
        let m = manager()
        let (c, h) = try hildesheim(m, account(.hildesheim))
        XCTAssertTrue(h.learnwebSignedIn(token: try XCTUnwrap(LearnwebToken(token)), base: base))
        h.lsfSignedIn()
        UniStubProtocol.install(Self.uniHildesheim(base: base, lsf: lsf, token: token, ics: ics, contents: contents))
        // ohne LSF-Sitzung im Datenspeicher: Weiterleitung zum CAS -> LSF neu anmelden, Learnweb laeuft trotzdem
        let r = try unwrap(await h.run())
        XCTAssertEqual(r.needsLogin, ["LSF"])
        XCTAssertEqual(h.lsf, .needsLogin)
        XCTAssertEqual(h.learnweb, .ok(clock.now))
        XCTAssertTrue(h.needsAttention(.lsf), "Karte LSF-Anmeldung abgelaufen")
        XCTAssertEqual(HildesheimConnectCard.title(.lsf, expired: true), "LSF-Anmeldung abgelaufen")
        XCTAssertEqual(HildesheimConnection.statusText(.lsf, h.lsf), "LSF: Anmeldung nötig")
        XCTAssertTrue(h.messages.contains { $0.hasPrefix("LSF-Stundenplan: Anmeldung bei LSF abgelaufen") }, h.messages.joined(separator: "; "))

        // Learnweb-Schluessel zurueckgezogen: neu verbinden, Dateien bleiben
        UniStubProtocol.install { [base] req in
            req.url.absoluteString.hasPrefix(base + "/lib/ajax/service-nologin.php") ? Self.publicConfig(base: base)
                : .text(#"{"exception":"moodle_exception","errorcode":"invalidtoken"}"#)
        }
        _ = await h.run()
        XCTAssertEqual(h.learnweb, .needsLogin)
        let kept = try await c.host.backend().context.database.scalar("SELECT COUNT(*) FROM files WHERE local_path IS NOT NULL")?.int
        XCTAssertEqual(kept, 2, "nichts geloescht")

        // neues Semester-Learnweb (learnweb2027): Schluessel von 2026 wird dort nicht verwendet
        UniStubProtocol.install { r in
            r.url.absoluteString.hasPrefix("https://www.uni-hildesheim.de/learnweb2027/lib/ajax/service-nologin.php")
                ? Self.publicConfig(base: "https://www.uni-hildesheim.de/learnweb2027", siteName: "Learnweb WiSe 2026/27 - SoSe 2027")
                : .text("", status: 404)
        }
        XCTAssertTrue(h.learnwebSignedIn(token: try XCTUnwrap(LearnwebToken(token)), base: base))
        _ = await h.run()
        XCTAssertEqual(h.learnweb, .needsLogin)
        XCTAssertFalse(UniStubProtocol.requests.contains { $0.url.path.contains("learnweb2027/webservice") }, "kein Schluessel an die neue Instanz")

        // Abmelden: Schluessel, Verbindungen und Webdaten weg; Dateien, Stundenplan und Noten bleiben
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(cookie("TGC", "cas-test", domain: "www.uni-hildesheim.de"))
        await h.signOut()
        XCTAssertNil(keychain.read(try XCTUnwrap(c.key.university.profile.keychainAccount(service: "learnweb", field: "token", userScope: c.key.userScope))))
        XCTAssertFalse(h.anyConnected)
        XCTAssertEqual(h.learnweb, .notConnected)
        XCTAssertEqual(h.lsf, .notConnected)
        let web = await m.websiteDataStore(for: c).httpCookieStore.allCookies()
        XCTAssertTrue(web.isEmpty)
        let still = try await c.host.backend().context.database.scalar("SELECT COUNT(*) FROM files WHERE local_path IS NOT NULL")?.int
        XCTAssertEqual(still, 2)
    }

    /// Der uebliche Weg: Learnweb verbunden, der Abgleich laeuft (Downloads), dann LSF verbinden. LSF bleibt
    /// "verbunden" statt "Fehler" (der laufende Lauf bewertet nur seine Quellen) und bekommt direkt danach einen eigenen
    /// Lauf mit Stundenplan und Noten.
    func testSourceConnectedDuringARunGetsItsOwnRunInsteadOfAnError() async throws {
        let ics = try repo("packages/shared-contracts/fixtures/hildesheim/lsf-course.ics")
        let contents = try repo("packages/shared-contracts/fixtures/hildesheim/learnweb-course-contents.json")
        let m = manager()
        let (c, h) = try hildesheim(m, account(.hildesheim))
        XCTAssertTrue(h.learnwebSignedIn(token: try XCTUnwrap(LearnwebToken(token)), base: base))
        let gate = StubGate()
        let uni = Self.uniHildesheim(base: base, lsf: lsf, token: token, ics: ics, contents: contents)
        UniStubProtocol.install { r in
            if r.url.path.contains("/webservice/pluginfile.php/") { gate.pass() }
            return uni(r)
        }
        let first = Task { await h.run() }
        try await waitUntil("Learnweb-Download laeuft") { gate.wasReached }
        XCTAssertTrue(h.isRunning)
        XCTAssertEqual(h.lsf, .notConnected)

        // LSF in der Webansicht verbunden, waehrend der Learnweb-Abgleich noch laedt
        await m.websiteDataStore(for: c).httpCookieStore.setCookie(cookie("JSESSIONID", "lsf-sitzung-test", domain: "lsf.uni-hildesheim.de"))
        h.syncsAfterSignIn = true
        h.lsfSignedIn()
        XCTAssertEqual(h.lsf, .connected, "weder laufend noch Fehler")
        gate.release()
        let report = try unwrap(await first.value)
        XCTAssertEqual(report.completed, ["Learnweb"], "der erste Lauf kannte LSF noch nicht")
        // der Folgelauf startet direkt am Ende des ersten und kann schon laufen, bevor dieser Test weitermacht (dann
        // "gleicht ab …"); vorher stand hier nur .ok, das scheiterte je nach Reihenfolge auf dem MainActor
        XCTAssertTrue(h.learnweb == .ok(clock.now) || h.learnweb == .running, "\(h.learnweb)")
        if case .failed = h.lsf { XCTFail("LSF faelschlich als Fehler: \(h.messages)") }

        try await waitUntil("Folgelauf mit LSF") { h.lsf == .ok(clock.now) && !h.isRunning }
        XCTAssertEqual(h.lastReport?.completed, ["Learnweb", "LSF-Stundenplan", "Notenspiegel"])
        let thursday = try await day(c, "2026-10-29", start: "16:00")
        XCTAssertEqual(thursday, ["teilnahme"], "Stundenplan aus dem Folgelauf")
        let grades = try await c.api.value("/api/grades")
        XCTAssertEqual(grades["grades"]?.array?.count, 2)
        XCTAssertEqual(h.learnweb, .ok(clock.now))
    }

    func testStatusTexts() {
        let now = UniFlowClock.fixed(berlin: "2026-10-26T16:30:00")!.now
        let earlier = UniFlowClock.fixed(berlin: "2026-10-25T09:05:00")!.now
        XCTAssertEqual(HildesheimConnection.statusText(.learnweb, .ok(now), now: now), "Learnweb: 16:30 ok")
        XCTAssertEqual(HildesheimConnection.statusText(.learnweb, .ok(earlier), now: now), "Learnweb: 25.10. 09:05 ok")
        XCTAssertEqual(HildesheimConnection.statusText(.lsf, .needsLogin), "LSF: Anmeldung nötig")
        XCTAssertEqual(HildesheimConnection.statusText(.lsf, .notConnected), "LSF: nicht verbunden")
        XCTAssertEqual(HildesheimConnection.statusText(.learnweb, .failed("x")), "Learnweb: Fehler")
        XCTAssertEqual(HildesheimConnectCard.title(.learnweb, expired: false), "Learnweb verbinden")
        XCTAssertEqual(HildesheimConnectCard.title(.lsf, expired: false), "LSF verbinden")
        XCTAssertTrue(UFDataMode.local(.otherSources).showsConnectCard, "statt Stud.IP die Karten von Learnweb und LSF")
        XCTAssertFalse(UFDataMode.local(.otherSources).studIPExpired)
        XCTAssertEqual(UFGatePresentation.resolve(spec: .exams, mode: .local(.otherSources), phase: .signedOut), .empty)
        XCTAssertEqual(UFGatePresentation.resolve(spec: .library, mode: .local(.otherSources), phase: .signedOut),
                       .pageBelowConnectCard)
        XCTAssertEqual(UFGatePresentation.resolve(spec: .document, mode: .local(.otherSources), phase: .signedOut),
                       .page, "im Editor keine Leiste")
    }
}

/// XCTUnwrap fuer einen schon erwarteten Wert (await ausserhalb des Autoclosure)
private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
