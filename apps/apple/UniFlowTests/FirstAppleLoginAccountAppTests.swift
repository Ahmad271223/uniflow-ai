import UniFlowCore
import XCTest
@testable import UniFlow

/// Eine Apple-Anmeldung fuer alles (Entscheidung des Inhabers 12.11.2026) und "Konto löschen" mit dem Dienst-Konto.
/// Schein-Dienst ueber `accountFactory`, Token nur im Speicher, nie ins Netz, keine echte Apple-ID.
@MainActor
final class FirstAppleLoginAccountAppTests: XCTestCase {

    /// Schein-Dienst: neues Konto nur mit Hochschule (`university_unknown` sonst), bekannte Kennung sofort
    final class Service: ServiceHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(method: String, path: String, body: JSONValue)] = []
        var knownAccount = false
        var deleteStatus = 200
        var deleteBody: JSONValue = ["deleted": true, "purge_after_days": 30]

        var requests: [(method: String, path: String, body: JSONValue)] { lock.withLock { log } }
        func last(_ path: String) -> JSONValue? { requests.last { $0.path == path }?.body }

        static let user: JSONValue = ["user": ["id": "0123456789abcdef0123456789abcdef", "email": "relay@privaterelay.appleid.com",
                                                "email_verified": true, "university": "luh", "plan": "free", "role": "user"],
                                      "sessions": []]

        func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
            let path = String(r.url.dropFirst("https://dienst.example".count))
            let body = (try? JSONValue.parse(r.body ?? Data())) ?? .null
            lock.withLock { log.append((r.method, path, body)) }
            func reply(_ status: Int, _ j: JSONValue) -> ServiceHTTPResponse { ServiceHTTPResponse(status: status, body: j.serialized()) }
            switch (r.method, path) {
            case ("POST", "/api/account/login/apple"):
                let known = lock.withLock { knownAccount }
                if !known && body["university"]?.string == nil {
                    return reply(400, ["detail": ["detail": "Bitte die Hochschule angeben.", "code": "university_unknown"]])
                }
                lock.withLock { knownAccount = true }
                return reply(known ? 200 : 201, .object(["user": Self.user["user"] ?? .null, "token": "sitzung-1", "created": .bool(!known)]))
            case ("GET", "/api/account/me"):
                return reply(200, Self.user)
            case ("GET", "/api/entitlements"):
                return reply(200, ["plan": "free", "trial_active": false])
            case ("POST", "/api/account/delete"):
                return lock.withLock { reply(deleteStatus, deleteBody) }
            default:
                return reply(404, ["detail": "nicht da"])
            }
        }
    }

    final class MemoryTokens: AccountTokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        init(_ t: String? = nil) { token = t }
        func load() -> String? { lock.withLock { token } }
        func save(_ t: String?) throws { lock.withLock { token = t } }
    }

    private var tokens: [String: MemoryTokens] = [:]

    private func link(_ service: Service) -> StudoraAccountLink {
        let l = StudoraAccountLink(entitlements: Entitlements(observe: false))
        l.accountFactory = { [unowned self] scope in
            let t = self.tokens[scope] ?? MemoryTokens()
            self.tokens[scope] = t
            return StudoraAccount(base: "https://dienst.example", http: service, tokens: t, deviceID: "ipad-test", deviceName: "iPad")
        }
        return l
    }

    private let appleUser = "001234.erfunden-ada.\(UUID().uuidString.prefix(8))"
    private var scope: String { DataContainerKey.userScope(appleUser) }
    private func first(at: Date = Date()) -> StudoraAccountLink.FirstAppleLogin {
        StudoraAccountLink.FirstAppleLogin(userID: appleUser, identityToken: "erfundenes-id-token", nonce: "roh-nonce",
                                           authorizationCode: "einmal-code", email: nil, at: at)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Zeitueberschreitung: \(what)")
    }

    override func tearDown() async throws {
        UFBillingServiceLink.accountToken = nil
        Entitlements.shared.useServiceTrial(nil)
        try await super.tearDown()
    }

    // MARK: Punkt 1: nie mehr still

    /// Vorher: "Mit Apple anmelden" in der Karte "Pro AI ist aktiv" beim ersten Start (vor der Hochschulwahl, kein
    /// Datenbereich offen) brach in `run` still ab, die Karte schloss nie. Jetzt eine verstaendliche Meldung.
    func testSignInWithoutOpenDataAreaSaysWhyInsteadOfDoingNothing() async {
        let l = StudoraAccountLink(entitlements: Entitlements(observe: false))
        l.use(userScope: nil)
        XCTAssertFalse(l.canSignIn)
        await l.loginWithApple(identityToken: "erfundenes-token", nonce: "n", email: nil)
        XCTAssertNotNil(l.message, "nie mehr still")
        XCTAssertTrue([StudoraAccountLink.noAccountYet, StudoraAccountLink.noService].contains(l.message ?? ""), l.message ?? "")
        XCTAssertNil(l.user)
    }

    // MARK: Punkt 5: eine Anmeldung fuer alles

    /// Neue Apple-ID: der Dienst braucht die Hochschule. Das Token wartet im Speicher und wird direkt nach der
    /// Hochschulwahl (Datenbereich offen) mit Hochschule und einmaligem Code getauscht.
    func testNewAppleIDIsExchangedRightAfterTheUniversityChoice() async throws {
        let service = Service()
        let l = link(service)
        await l.adoptFirstLogin(first())
        XCTAssertNotNil(l.pendingFirstLogin, "neues Konto: wartet auf die Hochschule")
        XCTAssertNil(tokens[scope]?.load())
        XCTAssertNil(service.last("/api/account/login/apple")?["university"], "erster Versuch ohne Hochschule")

        l.use(userScope: scope, host: nil, university: "luh")
        try await waitUntil("angemeldet") { l.user != nil }
        XCTAssertNil(l.pendingFirstLogin)
        let body = try XCTUnwrap(service.last("/api/account/login/apple"))
        XCTAssertEqual(body["university"], "luh")
        XCTAssertEqual(body["nonce"], "roh-nonce")
        XCTAssertEqual(body["authorization_code"], "einmal-code", "Code fuer den Widerruf beim Loeschen")
        XCTAssertEqual(tokens[scope]?.load(), "sitzung-1")
        XCTAssertNil(l.message)
    }

    /// Dieselbe Apple-ID auf einem weiteren iPad: dieselbe Anmeldung fuehrt sofort in dasselbe Konto, schon vor der
    /// Hochschulwahl (gleiche Apple-Kennung → gleiches Konto beim Dienst)
    func testSameAppleIDOnAnotherDeviceSignsInImmediately() async throws {
        let service = Service()
        service.knownAccount = true
        let l = link(service)
        await l.adoptFirstLogin(first())
        XCTAssertNil(l.pendingFirstLogin)
        XCTAssertEqual(tokens[scope]?.load(), "sitzung-1", "Sitzung schon vor dem Oeffnen des Datenbereichs")
        let logins = service.requests.filter { $0.path == "/api/account/login/apple" }
        XCTAssertEqual(logins.count, 1)
        l.use(userScope: scope, host: nil, university: "luh")
        try await waitUntil("Konto geladen") { l.user != nil }
        XCTAssertEqual(service.requests.filter { $0.path == "/api/account/login/apple" }.count, 1, "kein zweiter Tausch")
    }

    /// Abgelaufenes Token (mehr als 9 Minuten bis zur Hochschulwahl): nichts senden, Rueckfall-Knopf bleibt
    func testExpiredFirstLoginSendsNothing() async throws {
        let service = Service()
        let l = link(service)
        l.use(userScope: scope, host: nil, university: "luh")
        let old = first(at: Date().addingTimeInterval(-StudoraAccountLink.firstLoginLifetime - 1))
        await l.completeFirstLogin(old)
        XCTAssertTrue(service.requests.filter { $0.path == "/api/account/login/apple" }.isEmpty)
        XCTAssertNil(l.user)
    }

    // MARK: Punkt 2/7: "Konto löschen" loescht das Konto beim Dienst mit

    private func signedInLink(_ service: Service) async throws -> StudoraAccountLink {
        service.knownAccount = true
        tokens[scope] = MemoryTokens("sitzung-1")
        let l = link(service)
        l.use(userScope: scope, host: nil, university: "luh")
        try await waitUntil("angemeldet") { l.user != nil }
        return l
    }

    func testDeleteAccountDeletesTheServiceAccountFirstThenTheDevice() async throws {
        let service = Service()
        let l = try await signedInLink(service)
        var localDeleted = false
        let out = await AccountDeletion.run(service: l, password: nil, onlyThisDevice: false) { localDeleted = true }
        XCTAssertEqual(out, .done)
        XCTAssertTrue(service.requests.contains { $0.method == "POST" && $0.path == "/api/account/delete" }, "Dienst-Loeschaufruf")
        XCTAssertTrue(localDeleted)
        XCTAssertNil(l.user)
        XCTAssertNil(tokens[scope]?.load())
    }

    func testServiceAccountWithPasswordKeepsEverythingAndAsksForIt() async throws {
        let service = Service()
        service.deleteStatus = 401
        service.deleteBody = ["detail": ["detail": "Zum Löschen bitte das Passwort angeben.", "code": "credentials_invalid"]]
        let l = try await signedInLink(service)
        var localDeleted = false
        let out = await AccountDeletion.run(service: l, password: nil, onlyThisDevice: false) { localDeleted = true }
        XCTAssertEqual(out, .serviceFailed(message: AccountDeletion.passwordMessage, needsPassword: true))
        XCTAssertFalse(localDeleted, "nichts auf dem Geraet geloescht, solange das Dienst-Konto steht")
        // bewusster Ausweg: nur auf diesem Geraet
        let only = await AccountDeletion.run(service: l, password: nil, onlyThisDevice: true) { localDeleted = true }
        XCTAssertEqual(only, .done)
        XCTAssertTrue(localDeleted)
        XCTAssertEqual(service.requests.filter { $0.path == "/api/account/delete" }.count, 1)
    }

    func testWithoutServiceSessionOnlyTheDeviceIsDeleted() async {
        let service = Service()
        let l = link(service)
        l.use(userScope: scope, host: nil, university: "luh")
        var localDeleted = false
        let out = await AccountDeletion.run(service: l, password: nil, onlyThisDevice: false) { localDeleted = true }
        XCTAssertEqual(out, .done)
        XCTAssertTrue(localDeleted)
        XCTAssertFalse(service.requests.contains { $0.path == "/api/account/delete" })
    }

    // MARK: Punkt 4: Texte

    func testTextsSayTrialAndPurchasePerAppleIDAndWhatTheServiceAccountIsFor() {
        XCTAssertTrue(UFTrialTexts.perAppleID.contains("Apple-ID"))
        XCTAssertTrue(UFTrialTexts.perAppleID.contains("einmal je Apple-ID"))
        XCTAssertTrue(UFTrialTexts.perAppleID.contains("dasselbe StudiNow-Konto"))
        for word in ["StudiNow-KI", "Credits", "Geräten"] {
            XCTAssertTrue(StudoraAccountCard.purpose.contains(word), word)
        }
        XCTAssertTrue(DeleteAccountText.service.contains("ebenfalls gelöscht"))
        XCTAssertFalse(WelcomeView.footnote.contains("nur auf diesem iPad.") && !WelcomeView.footnote.contains("StudiNow-Dienst"))
        XCTAssertTrue(WelcomeView.footnote.contains("StudiNow-Dienst"))
    }
}
