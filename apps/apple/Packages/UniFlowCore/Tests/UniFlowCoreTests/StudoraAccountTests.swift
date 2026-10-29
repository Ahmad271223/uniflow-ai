import Foundation
import XCTest
@testable import UniFlowCore

// Studora-Konto auf dem iPad gegen den Vertrag G1 (packages/shared-contracts/fixtures/account/contract.json): die
// Antworten der Ablaeufe kommen unveraendert aus dem Vertrag, der Client muss sie lesen und dieselben Anfragen senden.

private func contract() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/account/contract.json")))
}

final class MemoryTokenStore: AccountTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ t: String? = nil) { token = t }
    func load() -> String? { lock.withLock { token } }
    func save(_ t: String?) throws { lock.withLock { token = t } }
}

/// Schein-Dienst: je Methode + Pfad die naechste Antwort aus einer Liste
actor FakeService: ServiceHTTPTransport {
    var replies: [String: [ServiceHTTPResponse]] = [:]
    var requests: [AIHTTPRequest] = []
    var offline = false
    func on(_ method: String, _ path: String, _ status: Int, _ body: JSONValue?, headers: [String: String] = [:]) {
        replies["\(method) \(path)", default: []].append(ServiceHTTPResponse(status: status, headers: headers, body: body?.serialized() ?? Data()))
    }
    func setOffline(_ o: Bool) { offline = o }
    func last(_ path: String) -> AIHTTPRequest? { requests.last { $0.url.hasSuffix(path) } }
    func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
        requests.append(r)
        if offline { throw URLError(.notConnectedToInternet) }
        let path = String(r.url.dropFirst("https://dienst.example".count))
        let key = "\(r.method) \(path)"
        guard var list = replies[key], !list.isEmpty else { return ServiceHTTPResponse(status: 404, body: Data()) }
        let next = list.removeFirst()
        replies[key] = list
        return next
    }
}

final class StudoraAccountTests: XCTestCase {
    private func flow(_ step: String) throws -> JSONValue {
        try XCTUnwrap(try contract()["flows"]?.array?.first { $0["step"]?.string == step }, step)
    }

    private func make(_ token: String? = nil) -> (StudoraAccount, FakeService, MemoryTokenStore) {
        let fake = FakeService(), store = MemoryTokenStore(token)
        return (StudoraAccount(base: "https://dienst.example/", http: fake, tokens: store, deviceID: "ipad-test", deviceName: "iPad"), fake, store)
    }

    private func answer(_ fake: FakeService, _ f: JSONValue, headers: [String: String] = [:]) async {
        let path = f["path"]?.string ?? ""
        await fake.on(f["method"]?.string ?? "", path, Int(f["status"]?.double ?? 0), f["response"], headers: headers)
    }

    func testEmailLoginStoresOnlyTheTokenAndReadsTheUser() async throws {
        let (acc, fake, store) = make()
        let f = try flow("Anmelden auf zweitem Geraet")
        await answer(fake, f)
        let u = try await acc.login(email: "erika@beispiel.de", password: "sehr-geheim-123")
        XCTAssertEqual(u.email, "erika@beispiel.de")
        XCTAssertEqual(u.university, "hildesheim")
        XCTAssertEqual(u.plan, "free")
        XCTAssertEqual(store.load(), f["response"]?["token"]?.string)
        let r1 = await fake.last("/api/account/login")
        let sent = try XCTUnwrap(r1)
        let body = try JSONValue.parse(sent.body ?? Data())
        XCTAssertEqual(body, ["email": "erika@beispiel.de", "password": "sehr-geheim-123", "device_id": "ipad-test", "device_name": "iPad"])
        XCTAssertNil(sent.headers["Authorization"], "Anmelden ohne Token")
        XCTAssertEqual(sent.url, "https://dienst.example/api/account/login", "ohne doppeltes /")
    }

    func testWrongPasswordAndLockKeepTheServiceTextAndRetryAfter() async throws {
        let (acc, fake, store) = make()
        await answer(fake, try flow("Anmelden: falsches Passwort"))
        do { _ = try await acc.login(email: "erika@beispiel.de", password: "falsch"); XCTFail() } catch let e as AccountError {
            XCTAssertEqual(e.code, "credentials_invalid")
            XCTAssertEqual(e.message, "E-Mail-Adresse oder Passwort stimmt nicht.")
        }
        await answer(fake, try flow("Nach 8 Fehlversuchen gesperrt"), headers: ["Retry-After": "600"])
        do { _ = try await acc.login(email: "sperre@beispiel.de", password: "egal"); XCTFail() } catch let e as AccountError {
            XCTAssertEqual(e.code, "locked")
            XCTAssertEqual(e.retryAfter, 600)
        }
        XCTAssertNil(store.load())
        await fake.setOffline(true)
        do { _ = try await acc.login(email: "a@b.de", password: "x"); XCTFail() } catch let e as AccountError {
            XCTAssertEqual(e.code, "service_unreachable")
        }
    }

    func testAppleLoginMeSessionsAndEndedSession() async throws {
        let (acc, fake, store) = make()
        await answer(fake, try flow("Anmelden mit Apple (bekannte Kennung)"))
        let r = try await acc.loginWithApple(identityToken: "apple-token")
        XCTAssertFalse(r.created)
        XCTAssertTrue(r.user.emailVerified)
        let r2 = await fake.last("/api/account/login/apple")
        let body = try JSONValue.parse(try XCTUnwrap(r2).body ?? Data())
        XCTAssertEqual(body["identity_token"], "apple-token")
        XCTAssertEqual(body["device_id"], "ipad-test")
        await answer(fake, try flow("Sitzungen des Kontos"))
        let me = try await acc.me()
        XCTAssertEqual(me.user.university, "hildesheim")
        XCTAssertFalse(me.sessions.isEmpty)
        let r3 = await fake.last("/api/account/me")
        XCTAssertEqual(try XCTUnwrap(r3).headers["Authorization"], "Bearer \(store.load() ?? "")")
        await answer(fake, try flow("Beendete Sitzung"))
        do { _ = try await acc.me(); XCTFail() } catch let e as AccountError { XCTAssertEqual(e.code, "unauthenticated") }
        XCTAssertNil(store.load(), "beendete Sitzung: Token weg, neu anmelden")
        let signed = await acc.isSignedIn
        XCTAssertFalse(signed)
    }

    func testDevicesLinkExportLogoutAndDelete() async throws {
        let (acc, fake, store) = make("tok")
        await answer(fake, try flow("Andere Sitzungen beenden"))
        let revoked = try await acc.logoutOthers()
        XCTAssertEqual(revoked, 1)
        await fake.on("DELETE", "/api/account/sessions/2", 200, ["revoked": true])
        try await acc.revoke(session: 2)
        await answer(fake, try flow("Apple verknuepfen"))
        try await acc.linkApple(identityToken: "apple-token")
        await answer(fake, try flow("Apple verknuepfen: Token ungueltig"))
        do { try await acc.linkApple(identityToken: "kaputt"); XCTFail() } catch let e as AccountError { XCTAssertEqual(e.code, "identity_invalid") }
        await fake.on("GET", "/api/account/export", 200, nil)
        _ = try await acc.export()
        await answer(fake, try flow("Konto loeschen: Passwort fehlt"))
        do { _ = try await acc.delete(password: nil); XCTFail() } catch let e as AccountError {
            XCTAssertEqual(e.message, "Zum Löschen bitte das Passwort angeben.")
        }
        XCTAssertEqual(store.load(), "tok", "falsches oder fehlendes Passwort meldet nicht ab")
        await answer(fake, try flow("Konto loeschen"))
        let days = try await acc.delete(password: "noch-geheimer-456")
        XCTAssertEqual(days, 30)
        XCTAssertNil(store.load())
        try store.save("tok2")
        await fake.setOffline(true)
        await acc.logout()
        XCTAssertNil(store.load(), "Abmelden loescht das Token auch ohne Netz")
    }
}
