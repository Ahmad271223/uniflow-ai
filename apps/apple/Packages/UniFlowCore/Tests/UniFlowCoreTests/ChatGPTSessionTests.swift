#if canImport(Security) && canImport(CryptoKit)
import CryptoKit
import Foundation
import Security
import XCTest
@testable import UniFlowCore

// Sign in with ChatGPT auf dem Geraet wie app/chatgpt_login.py (tests/test_chatgpt_login.py): Anmeldung mit
// Erstregistrierung, ID-Token (Signatur, Aussteller, Empfaenger, Ablauf, Nonce), Erneuerung, Anfragen an die
// Responses API mit den Fehlerfaellen, Modelle, Trennen. Nur gegen einen Schein-Server, nie ins Netz.

/// Ablage im Speicher
final class MemoryChatGPTStore: ChatGPTStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChatGPTState?
    private(set) var saves = 0
    init(_ v: ChatGPTState? = nil) { value = v }
    func load() -> ChatGPTState? { lock.withLock { value } }
    func save(_ state: ChatGPTState) throws { lock.withLock { value = state; saves += 1 } }
}

/// Schein-OpenAI: Antworten je Adresse, merkt sich die Anfragen
actor FakeOpenAI: AIHTTPTransport {
    var handlers: [String: (AIHTTPRequest) -> (Int, Data)] = [:]
    var requests: [AIHTTPRequest] = []
    var offline = false

    func on(_ url: String, _ h: @escaping @Sendable (AIHTTPRequest) -> (Int, Data)) { handlers[url] = h }
    func setOffline(_ o: Bool) { offline = o }
    func count(_ url: String) -> Int { requests.filter { $0.url == url }.count }
    func last(_ url: String) -> AIHTTPRequest? { requests.last { $0.url == url } }

    func send(_ request: AIHTTPRequest) async throws -> (status: Int, body: Data) {
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        guard let h = handlers[request.url] else { return (404, Data()) }
        return h(request)
    }
}

private func json(_ v: JSONValue) -> Data { v.serialized() }
/// Ereignisstrom der Responses API (`stream: true`), wie OpenAI ihn sendet: `event:` und `data:` je Ereignis
private func sse(_ events: [JSONValue]) -> Data {
    Data(events.map { "event: \($0["type"]?.string ?? "")\ndata: \(String(decoding: $0.serialized(), as: UTF8.self))\n\n" }.joined().utf8)
}
/// Vollstaendiger Strom mit einer Antwort: ein Delta und `response.completed` mit dem Text
private func completedStream(_ text: String, model: String = "gpt-test") -> Data {
    sse([["type": "response.created", "response": ["id": "resp_1"]],
         ["type": "response.output_text.delta", "delta": .string(text)],
         ["type": "response.completed", "response": ["model": .string(model), "output": [["type": "message", "content": [["type": "output_text", "text": .string(text)]]]],
                                                     "usage": ["input_tokens": 5, "output_tokens": 1]]]])
}
/// Abfrage einer Adresse wie ein Formular ("+" = Leerzeichen, wie urlencode)
private func query(_ url: String) -> [String: String] {
    form(AIHTTPRequest(method: "GET", url: url, body: Data(url.split(separator: "?", maxSplits: 1).last.map(String.init)?.utf8 ?? "".utf8)))
}

private func form(_ r: AIHTTPRequest?) -> [String: String] {
    var out: [String: String] = [:]
    for pair in String(decoding: r?.body ?? Data(), as: UTF8.self).split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { PyText.unquotePlus(String($0)) }
        out[kv[0]] = kv.count > 1 ? kv[1] : ""
    }
    return out
}

final class ChatGPTSessionTests: XCTestCase {
    let es = P256.Signing.PrivateKey()
    var clock = 1_800_000_000.0

    private func b64(_ d: some DataProtocol) -> String { ChatGPTProtocol.base64URL(Array(d)) }

    private var esJWK: JSONValue {
        let raw = es.publicKey.rawRepresentation
        return ["kty": "EC", "crv": "P-256", "kid": "k1", "x": .string(b64(raw.prefix(32))), "y": .string(b64(raw.suffix(32)))]
    }

    /// ID-Token mit ES256 (kid k1)
    private func idToken(_ claims: [String: JSONValue], kid: String = "k1", key: P256.Signing.PrivateKey? = nil) -> String {
        let header = b64(JSONValue.object(["alg": "ES256", "kid": .string(kid), "typ": "JWT"]).serialized())
        let payload = b64(JSONValue.object(claims).serialized())
        let sig = try! (key ?? es).signature(for: Data("\(header).\(payload)".utf8)).rawRepresentation
        return "\(header).\(payload).\(b64(sig))"
    }

    private func claims(aud: String, nonce: String, exp: Double? = nil) -> [String: JSONValue] {
        ["iss": .string(ChatGPTConstants.issuer), "aud": .string(aud), "nonce": .string(nonce), "exp": .number(exp ?? clock + 3600),
         "sub": "user-1", "email": "test@example.invalid", "name": "Test Person"]
    }

    private func make(_ store: MemoryChatGPTStore = MemoryChatGPTStore()) async -> (ChatGPTSession, FakeOpenAI, MemoryChatGPTStore) {
        let fake = FakeOpenAI()
        let jwk = esJWK
        await fake.on(ChatGPTConstants.jwksURL) { _ in (200, json(["keys": [jwk]])) }
        let t = self
        return (ChatGPTSession(store: store, http: fake, signature: ChatGPTAppleSignature(), now: { t.clock }), fake, store)
    }

    /// Verbindet mit Erstregistrierung; Token-Antwort nach `tokenResponse(nonce)`
    private func connect(_ s: ChatGPTSession, _ fake: FakeOpenAI, scope: String = "openid email offline_access chatgpt.tokens.use.direct",
                         id: ((String) -> String?)? = nil) async throws -> ChatGPTLoginAttempt {
        let attempt = await s.beginLogin(redirectURI: "http://127.0.0.1:53682/auth/callback")
        let token = id?(attempt.nonce) ?? idToken(claims(aud: "oaiapp_new", nonce: attempt.nonce))
        await fake.on(ChatGPTConstants.tokenURL) { _ in
            (200, json(["access_token": "at-1", "refresh_token": "rt-1", "id_token": .string(token), "expires_in": 3600, "scope": .string(scope)]))
        }
        try await s.completeLogin(query: ["state": attempt.state, "code": "code-1", "client_id": "oaiapp_new"])
        return attempt
    }

    // MARK: Anmeldung

    func testFirstLoginRegistersVerifiesAndStores() async throws {
        let (s, fake, store) = await make()
        let attempt = try await connect(s, fake)
        let q = query(attempt.url)
        XCTAssertEqual(q["client_id"], "dynamic_agent_client")
        XCTAssertEqual(q["agent_name_hint"], "StudiNow")
        XCTAssertEqual(q["code_challenge"], ChatGPTProtocol.challenge(for: attempt.verifier))
        XCTAssertEqual(q["scope"], ChatGPTConstants.scope)
        let f = form(await fake.last(ChatGPTConstants.tokenURL))
        XCTAssertEqual(f["grant_type"], "authorization_code")
        XCTAssertEqual(f["client_id"], "oaiapp_new", "die ausgestellte ID tauscht den Code")
        XCTAssertEqual(f["code_verifier"], attempt.verifier)
        XCTAssertEqual(f["redirect_uri"], "http://127.0.0.1:53682/auth/callback")
        let st = await s.status
        XCTAssertTrue(st.connected && st.sharing && st.registered)
        XCTAssertEqual(st.email, "test@example.invalid")
        XCTAssertFalse(st.enabledForAI, "ohne Modell keine Anfragen")
        XCTAssertEqual(store.load()?.clientID, "oaiapp_new")
        XCTAssertEqual(store.load()?.credentials?.refreshToken, "rt-1")

        // zweite Anmeldung: die ausgestellte ID, mit login_hint (E-Mail, kein Token), ohne Namen der App
        let again = await s.beginLogin(redirectURI: "http://127.0.0.1:1/auth/callback")
        let q2 = query(again.url)
        XCTAssertEqual(q2["client_id"], "oaiapp_new")
        XCTAssertNil(q2["agent_name_hint"])
        XCTAssertEqual(q2["login_hint"], "test@example.invalid")
        XCTAssertNil(q2["id_token_hint"], "gespeicherte Tokens gehoeren nicht in die Browser-Adresse")
        XCTAssertNil(q2["prompt"])
        XCTAssertNotEqual(again.state, attempt.state)
        XCTAssertNil(query(attempt.url)["login_hint"], "bei der Erstregistrierung gibt es kein Profil")
    }

    func testReconsentAndNewAccount() async throws {
        let (s, fake, store) = await make()
        _ = try await connect(s, fake)
        let consent = try await s.beginLogin(redirectURI: "r", reconsent: true)
        let q = query(consent.url)
        XCTAssertEqual(q["prompt"], "consent")
        XCTAssertEqual(q["login_hint"], "test@example.invalid")
        XCTAssertEqual(q["client_id"], "oaiapp_new")
        let host = store.load()?.hostID
        try await s.setModel("gpt-test")
        let fresh = try await s.beginLogin(redirectURI: "r", newAccount: true)
        let q2 = query(fresh.url)
        XCTAssertEqual(q2["client_id"], "dynamic_agent_client")
        XCTAssertEqual(q2["agent_name_hint"], "StudiNow")
        XCTAssertNil(q2["login_hint"])
        XCTAssertNil(fresh.clientID)
        let saved = try XCTUnwrap(store.load())
        XCTAssertNil(saved.clientID)
        XCTAssertNil(saved.credentials)
        XCTAssertNil(saved.profile)
        XCTAssertFalse(saved.needsReauth)
        XCTAssertNil(saved.lastError)
        XCTAssertEqual(saved.hostID, host, "Geraetekennung bleibt")
        XCTAssertEqual(saved.model, "gpt-test", "Einstellungen bleiben")
        let st = await s.status
        XCTAssertFalse(st.connected || st.registered)
        // die neue Registrierung laeuft wie die erste, mit anderem Konto
        let token = idToken(claims(aud: "oaiapp_other", nonce: fresh.nonce).merging(["sub": "user-2", "email": "zwei@example.invalid"]) { $1 })
        await fake.on(ChatGPTConstants.tokenURL) { _ in
            (200, json(["access_token": "at-9", "refresh_token": "rt-9", "id_token": .string(token), "expires_in": 3600, "scope": "openid"]))
        }
        try await s.completeLogin(query: ["state": fresh.state, "code": "code-9", "client_id": "oaiapp_other"])
        XCTAssertEqual(store.load()?.clientID, "oaiapp_other")
        XCTAssertEqual(store.load()?.profile?.sub, "user-2")
    }

    func testReloginWithAnotherAccountIsRejected() async throws {
        let (s, fake, store) = await make()
        _ = try await connect(s, fake)
        let saves = store.saves
        let again = await s.beginLogin(redirectURI: "r")
        let other = idToken(claims(aud: "oaiapp_new", nonce: again.nonce, exp: clock + 100_000)
                                .merging(["sub": "user-2", "email": "zwei@example.invalid"]) { $1 })
        await fake.on(ChatGPTConstants.tokenURL) { _ in
            (200, json(["access_token": "at-2", "refresh_token": "rt-2", "id_token": .string(other), "expires_in": 3600, "scope": "openid"]))
        }
        await assertError(try await s.completeLogin(query: ["state": again.state, "code": "c", "client_id": "oaiapp_new"]),
                          code: "chatgpt_account_mismatch", contains: "anderen ChatGPT-Konto")
        XCTAssertEqual(store.saves, saves, "nichts gespeichert")
        XCTAssertEqual(store.load()?.credentials?.accessToken, "at-1", "nichts ueberschrieben")
        XCTAssertEqual(store.load()?.profile?.sub, "user-1")
        let st = await s.status
        XCTAssertTrue(st.connected && !st.needsReauth)
        // Erneuerung mit rotiertem ID-Token eines anderen Kontos: neu anmelden
        clock += 4000
        await assertError(try await s.accessToken(), code: "chatgpt_login_needed", contains: "passt nicht zu diesem Konto")
        let st2 = await s.status
        XCTAssertTrue(st2.needsReauth)
        XCTAssertEqual(store.load()?.credentials?.accessToken, "at-1", "die fremden Zugangsdaten werden nicht uebernommen")
        // Erneuerung ohne ID-Token oder mit demselben Konto geht wie bisher
        let (s2, fake2, store2) = await make()
        _ = try await connect(s2, fake2)
        await fake2.on(ChatGPTConstants.tokenURL) { _ in (200, json(["access_token": "at-3", "expires_in": 60])) }
        clock += 4000
        let plain = try await s2.accessToken()
        XCTAssertEqual(plain, "at-3")
        let same = idToken(claims(aud: "oaiapp_new", nonce: "egal"))
        await fake2.on(ChatGPTConstants.tokenURL) { _ in
            (200, json(["access_token": "at-4", "refresh_token": "rt-4", "id_token": .string(same), "expires_in": 3600]))
        }
        clock += 100
        let rotated = try await s2.accessToken()
        XCTAssertEqual(rotated, "at-4")
        XCTAssertEqual(store2.load()?.credentials?.refreshToken, "rt-4")
        let st3 = await s2.status
        XCTAssertFalse(st3.needsReauth)
    }

    func testClientIDIsKeptEvenIfTheExchangeFails() async throws {
        let (s, fake, store) = await make()
        let attempt = await s.beginLogin(redirectURI: "http://127.0.0.1:2/auth/callback")
        await fake.on(ChatGPTConstants.tokenURL) { _ in (400, json(["error": "invalid_grant", "error_description": "Code abgelaufen"])) }
        do {
            try await s.completeLogin(query: ["state": attempt.state, "code": "c", "client_id": "oaiapp_kept"])
            XCTFail("Tausch muss scheitern")
        } catch let e as AIError {
            XCTAssertEqual(e.code, "chatgpt_http_error")
            XCTAssertTrue(e.message.contains("Code abgelaufen"), e.message)
        }
        XCTAssertEqual(store.load()?.clientID, "oaiapp_kept", "vor dem Tausch gemerkt")
        let st = await s.status
        XCTAssertFalse(st.connected)
    }

    func testWrongStateAbortAndMissingParts() async throws {
        let (s, _, _) = await make()
        let attempt = await s.beginLogin(redirectURI: "r")
        await assertError(try await s.completeLogin(query: ["state": "fremd", "code": "c", "client_id": "x"]), contains: "(state)")
        await assertError(try await s.completeLogin(query: ["state": attempt.state]), contains: "keinen Code")
        await assertError(try await s.completeLogin(query: ["state": attempt.state, "code": "c"]), contains: "keine Client-ID")
        let again = await s.beginLogin(redirectURI: "r")
        await assertError(try await s.completeLogin(query: ["state": again.state, "error": "access_denied"]), contains: "Anmeldung abgebrochen.")
        await assertError(try await s.completeLogin(query: ["state": again.state, "code": "c"]), contains: "schon abgeschlossen")
    }

    func testLoginTimesOutAfterTenMinutes() async throws {
        let (s, _, _) = await make()
        let attempt = await s.beginLogin(redirectURI: "r")
        clock += 601
        await assertError(try await s.completeLogin(query: ["state": attempt.state, "code": "c", "client_id": "x"]), contains: "zu lange")
    }

    // MARK: ID-Token

    func testIDTokenIsRejectedForEveryWrongPart() async throws {
        let other = P256.Signing.PrivateKey()
        let cases: [(String, (String) -> String)] = [
            ("Nonce", { _ in self.idToken(self.claims(aud: "oaiapp_new", nonce: "andere")) }),
            ("nicht fuer diese App", { n in self.idToken(self.claims(aud: "oaiapp_fremd", nonce: n)) }),
            ("abgelaufen", { n in self.idToken(self.claims(aud: "oaiapp_new", nonce: n, exp: self.clock - 61)) }),
            ("Aussteller", { n in var c = self.claims(aud: "oaiapp_new", nonce: n); c["iss"] = "https://boese.example"; return self.idToken(c) }),
            ("Signatur", { n in self.idToken(self.claims(aud: "oaiapp_new", nonce: n), key: other) }),
            ("nicht bekannt", { n in self.idToken(self.claims(aud: "oaiapp_new", nonce: n), kid: "k9") }),
        ]
        for (why, token) in cases {
            let (s, fake, _) = await make()
            do {
                _ = try await connect(s, fake, id: token)
                XCTFail("\(why): angenommen")
            } catch let e as AIError {
                XCTAssertEqual(e.code, "chatgpt_token_invalid", why)
                XCTAssertTrue(e.message.contains(why), "\(why): \(e.message)")
            }
            let st = await s.status
            XCTAssertFalse(st.connected, why)
            if why == "nicht bekannt" {
                let fetches = await fake.count(ChatGPTConstants.jwksURL)
                XCTAssertEqual(fetches, 2, "unbekannter kid: Schluesselliste einmal neu laden")
            }
        }
        // Gegenprobe: 60 s Kulanz beim Ablauf
        let (s, fake, _) = await make()
        _ = try await connect(s, fake, id: { n in self.idToken(self.claims(aud: "oaiapp_new", nonce: n, exp: self.clock - 59)) })
        let st = await s.status
        XCTAssertTrue(st.connected)
    }

    func testRS256SignatureWithAnRSAKey() throws {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let priv = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, nil))
        let pub = try XCTUnwrap(SecKeyCopyPublicKey(priv))
        let der = [UInt8](try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, nil)) as Data)
        // PKCS#1: SEQUENCE { INTEGER n, INTEGER e } -> n und e fuer das JWK
        var i = 1
        func len() -> Int { let b = Int(der[i]); i += 1; if b < 0x80 { return b }; var n = 0; for _ in 0..<(b & 0x7F) { n = n << 8 | Int(der[i]); i += 1 }; return n }
        _ = len()
        i += 1; let nl = len(); let n = Array(der[i..<(i + nl)]); i += nl
        i += 1; let el = len(); let e = Array(der[i..<(i + el)])
        XCTAssertEqual(ChatGPTAppleSignature.rsaPublicKeyDER(n: n, e: e), der, "DER wie das System")
        let input = Data("kopf.inhalt".utf8)
        let sig = [UInt8](try XCTUnwrap(SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, nil)) as Data)
        let jwk: JSONValue = ["kty": "RSA", "n": .string(b64(n)), "e": .string(b64(e))]
        let check = ChatGPTAppleSignature()
        XCTAssertTrue(check.verify(jwk: jwk, alg: "RS256", signingInput: input, signature: sig))
        XCTAssertFalse(check.verify(jwk: jwk, alg: "RS256", signingInput: Data("kopf.anders".utf8), signature: sig))
        XCTAssertFalse(check.verify(jwk: jwk, alg: "ES256", signingInput: input, signature: sig), "Algorithmus passt nicht zum Schluessel")
    }

    // MARK: Token erneuern

    func testRefreshSixtySecondsBeforeExpiryRotatesTheRefreshToken() async throws {
        let (s, fake, store) = await make()
        _ = try await connect(s, fake)
        let first = try await s.accessToken()
        XCTAssertEqual(first, "at-1")
        var count = await fake.count(ChatGPTConstants.tokenURL)
        XCTAssertEqual(count, 1, "noch gueltig: keine Erneuerung")
        await fake.on(ChatGPTConstants.tokenURL) { _ in (200, json(["access_token": "at-2", "refresh_token": "rt-2", "expires_in": 3600])) }
        clock += 3600 - 59
        let second = try await s.accessToken()
        XCTAssertEqual(second, "at-2")
        let f = form(await fake.last(ChatGPTConstants.tokenURL))
        XCTAssertEqual(f["grant_type"], "refresh_token")
        XCTAssertEqual(f["refresh_token"], "rt-1")
        XCTAssertEqual(f["client_id"], "oaiapp_new")
        XCTAssertEqual(store.load()?.credentials?.refreshToken, "rt-2", "rotiert und ersetzt")
        XCTAssertTrue(store.load()?.credentials?.sharing == true, "Scopes der vorigen Anmeldung bleiben")
        count = await fake.count(ChatGPTConstants.tokenURL)
        XCTAssertEqual(count, 2)
    }

    /// Zwei KI-Anfragen zugleich kurz vor Ablauf: eine Erneuerung, beide bekommen das neue Token. Vorher erneuerten
    /// beide mit demselben Refresh-Token; OpenAI rotiert es, die zweite bekam invalid_grant und die Verbindung galt
    /// als abgelaufen (Audit Robustheit 03.11.2026)
    func testConcurrentAccessTokenRefreshesOnce() async throws {
        let (s, fake, store) = await make()
        _ = try await connect(s, fake)
        final class Used: @unchecked Sendable { let lock = NSLock(); var tokens: Set<String> = [] }
        let used = Used()
        await fake.on(ChatGPTConstants.tokenURL) { r in
            let rt = form(r)["refresh_token"] ?? ""
            used.lock.lock(); defer { used.lock.unlock() }
            guard used.tokens.insert(rt).inserted else { return (400, json(["error": "invalid_grant"])) }
            return (200, json(["access_token": "at-2", "refresh_token": "rt-2", "expires_in": 3600]))
        }
        clock += 3600 - 59
        async let a = s.accessToken()
        async let b = s.accessToken()
        let (ta, tb) = try await (a, b)
        XCTAssertEqual(ta, "at-2")
        XCTAssertEqual(tb, "at-2")
        let calls = await fake.count(ChatGPTConstants.tokenURL)
        XCTAssertEqual(calls, 2, "Anmeldung plus genau eine Erneuerung")
        let st = await s.status
        XCTAssertFalse(st.needsReauth)
        XCTAssertEqual(store.load()?.credentials?.refreshToken, "rt-2")
    }

    /// Getrennt, waehrend die Erneuerung unterwegs ist: die Antwort holt die Zugangsdaten nicht zurueck, kein Absturz
    func testDisconnectDuringRefreshDoesNotRestoreCredentials() async throws {
        let (s, fake, store) = await make()
        _ = try await connect(s, fake)
        await fake.on(ChatGPTConstants.tokenURL) { _ in (200, json(["access_token": "at-2", "refresh_token": "rt-2", "expires_in": 3600])) }
        clock += 3600 - 59
        async let token = s.accessToken()
        try await s.disconnect()
        do {
            let t = try await token
            // die Erneuerung war schon fertig, bevor getrennt wurde: dann gilt das Trennen danach
            XCTAssertEqual(t, "at-2")
        } catch {
            XCTAssertEqual((error as? AIError)?.code, "chatgpt_login_needed")
        }
        XCTAssertNil(store.load()?.credentials, "Trennen bleibt bestehen")
        let st = await s.status
        XCTAssertFalse(st.connected)
    }

    func testEarliestRefreshAtDelaysTheRefresh() async throws {
        let (s, fake, store) = await make()
        _ = try await connect(s, fake)
        await fake.on(ChatGPTConstants.tokenURL) { _ in (200, json(["access_token": "at-neu", "expires_in": 3600])) }
        var d = try XCTUnwrap(store.load())
        // kurz vor Ablauf, Erneuerung noch nicht erlaubt: das alte Token bleibt gueltig und wird genutzt
        d.credentials?.expiresAt = clock + 30
        d.credentials?.earliestRefreshAt = clock + 600
        try store.save(d)
        let t = self
        let s1 = ChatGPTSession(store: store, http: fake, signature: ChatGPTAppleSignature(), now: { t.clock })
        let still = try await s1.accessToken()
        XCTAssertEqual(still, "at-1")
        var calls = await fake.count(ChatGPTConstants.tokenURL)
        XCTAssertEqual(calls, 1, "keine Erneuerung vor earliest_refresh_at")
        // abgelaufen und Erneuerung noch nicht erlaubt: klare Meldung, kein Aufruf
        clock += 31
        await assertError(try await s1.accessToken(), code: "chatgpt_refresh_not_ready")
        calls = await fake.count(ChatGPTConstants.tokenURL)
        XCTAssertEqual(calls, 1)
        let st = await s1.status
        XCTAssertFalse(st.needsReauth, "kein Abmelden")
        // Sperre vorbei: erneuern
        clock += 600
        let renewed = try await s1.accessToken()
        XCTAssertEqual(renewed, "at-neu")
        let f = form(await fake.last(ChatGPTConstants.tokenURL))
        XCTAssertEqual(f["grant_type"], "refresh_token")
        XCTAssertNil(store.load()?.credentials?.earliestRefreshAt, "die neue Antwort nennt keine Sperre")
    }

    func testRejectedRefreshNeedsANewLoginAndStopsCalling() async throws {
        let (s, fake, _) = await make()
        _ = try await connect(s, fake)
        await fake.on(ChatGPTConstants.tokenURL) { _ in (400, json(["error": "invalid_grant"])) }
        clock += 4000
        await assertError(try await s.accessToken(), code: "chatgpt_login_needed")
        let st = await s.status
        XCTAssertTrue(st.needsReauth)
        let before = await fake.count(ChatGPTConstants.tokenURL)
        await assertError(try await s.accessToken(), code: "chatgpt_login_needed")
        let after = await fake.count(ChatGPTConstants.tokenURL)
        XCTAssertEqual(before, after, "nach der Ablehnung nicht weiter versuchen")
        // Netzfehler bei der Erneuerung ist kein Abmelden
        let (s2, fake2, _) = await make()
        _ = try await connect(s2, fake2)
        clock += 4000
        await fake2.setOffline(true)
        await assertError(try await s2.accessToken(), code: "chatgpt_unreachable")
        let st2 = await s2.status
        XCTAssertFalse(st2.needsReauth)
    }

    // MARK: Anfragen

    func testCompleteSendsOnlyWhatIsGivenAndMapsErrors() async throws {
        let (s, fake, _) = await make()
        await assertError(try await s.complete(system: "S", prompt: "P"), code: "chatgpt_not_enabled")
        _ = try await connect(s, fake)
        await assertError(try await s.complete(system: "S", prompt: "P"), code: "chatgpt_not_enabled")
        try await s.setModel("gpt-test")
        await fake.on(ChatGPTConstants.responsesURL) { _ in (200, completedStream("Antwort")) }
        let text = try await s.complete(system: "SYS", prompt: "Frage")
        XCTAssertEqual(text, "Antwort")
        let lastRequest = await fake.last(ChatGPTConstants.responsesURL)
        let req = try XCTUnwrap(lastRequest)
        XCTAssertEqual(req.url, "https://api.openai.com/v1/responses", "die oeffentliche Responses API, nicht ChatGPTs backend-api")
        XCTAssertEqual(req.headers["Authorization"], "Bearer at-1")
        XCTAssertEqual(req.headers["Accept"], "text/event-stream")
        XCTAssertEqual(req.headers["originator"], "StudiNow")
        XCTAssertNil(req.headers["chatgpt-account-id"], "kein JWT, keine Kontokennung")
        // Pflicht mit dem Token des Abos: store false, stream true, input als Liste, Anweisung in instructions
        XCTAssertEqual(try JSONValue.parse(req.body ?? Data()),
                       ["model": "gpt-test", "instructions": "SYS", "input": [["role": "user", "content": "Frage"]], "store": false, "stream": true])
        // eine Antwort ohne Strom (JSON) wird weiter gelesen
        await fake.on(ChatGPTConstants.responsesURL) { _ in
            (200, json(["output": [["type": "message", "content": [["type": "output_text", "text": "ohne Strom"]]]]]))
        }
        let plain = try await s.complete(system: "SYS", prompt: "Frage")
        XCTAssertEqual(plain, "ohne Strom")
        for (status, code) in [(429, "chatgpt_limit"), (402, "chatgpt_limit"), (403, "chatgpt_limit"), (500, "ai_provider_error")] {
            await fake.on(ChatGPTConstants.responsesURL) { _ in (status, Data("{}".utf8)) }
            await assertError(try await s.complete(system: "", prompt: "x"), code: code)
        }
        // 400 ohne Modellbezug: die Meldung der Zulassung (`detail`), nicht der rohe Text
        await fake.on(ChatGPTConstants.responsesURL) { _ in (400, Data(#"{"detail":"Nur Text","error":{"code":"x"}}"#.utf8)) }
        await assertError(try await s.complete(system: "", prompt: "x"), code: "ai_provider_error", contains: "Fehler 400: Nur Text")
        // Fehler nach Beginn des Stroms: Kontingent, sonst Abbruch
        await fake.on(ChatGPTConstants.responsesURL) { _ in
            (200, sse([["type": "response.output_text.delta", "delta": "x"],
                       ["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "limit"]]]]))
        }
        await assertError(try await s.complete(system: "", prompt: "x"), code: "chatgpt_limit")
        await fake.on(ChatGPTConstants.responsesURL) { _ in (200, sse([["type": "response.output_text.delta", "delta": "abgebrochen"]])) }
        await assertError(try await s.complete(system: "", prompt: "x"), code: "ai_provider_error", contains: "nicht beendet")
        await fake.setOffline(true)
        await assertError(try await s.complete(system: "", prompt: "x"), code: "ai_provider_unreachable")
        await fake.setOffline(false)
        await fake.on(ChatGPTConstants.responsesURL) { _ in (401, Data()) }
        await assertError(try await s.complete(system: "", prompt: "x"), code: "chatgpt_login_needed")
        let st = await s.status
        XCTAssertTrue(st.needsReauth && !st.enabledForAI, "401: neu verbinden")
    }

    /// iPad 2./3.11.2026: "The 'gpt-5' model is not supported when using Codex with a ChatGPT account" (400): die
    /// Sitzung merkt sich das Modell, probiert die naechsten Kandidaten und bleibt beim ersten, das antwortet
    func testRejectedModelIsRememberedAndTheNextCandidateIsTried() async throws {
        let (s, fake, store) = await make()
        _ = try await connect(s, fake)
        try await s.setModel("gpt-5")
        await fake.on(ChatGPTConstants.modelsURL) { _ in (403, Data("{}".utf8)) }        // Liste nicht lesbar: feste Kandidaten
        await fake.on(ChatGPTConstants.responsesURL) { req in
            let model = (try? JSONValue.parse(req.body ?? Data()))?["model"]?.string ?? ""
            if model == "gpt-6.1-sol" { return (200, completedStream("OK von \(model)", model: model)) }
            return (400, Data(#"{"detail":"The '\#(model)' model is not supported when using Codex with a ChatGPT account.","error":{"type":"invalid_request_error","code":"model_not_found"}}"#.utf8))
        }
        let answer = try await s.complete(system: "S", prompt: "P")
        XCTAssertEqual(answer, "OK von gpt-6.1-sol")
        let st = await s.status
        XCTAssertEqual(st.model, "gpt-6.1-sol", "das erste Modell des Codex-Katalogs")
        let rejected = await s.rejectedModels
        XCTAssertEqual(rejected, ["gpt-5"])
        let persisted = store.load()
        XCTAssertEqual(persisted?.rejectedModels, ["gpt-5"], "abgelehnt bleibt gemerkt")
        XCTAssertEqual(persisted?.rejectedModelsVersion, ChatGPTSession.requestVersion)
        // naechste Anfrage geht direkt an das funktionierende Modell
        _ = try await s.complete(system: "S", prompt: "P2")
        let req = await fake.last(ChatGPTConstants.responsesURL)
        let sent = try JSONValue.parse(req?.body ?? Data())
        XCTAssertEqual(sent["model"], "gpt-6.1-sol")
    }

    /// Liefert das Konto seinen Katalog (`{"models": [...]}`), gilt dessen Reihenfolge – nicht die feste Liste; versteckte
    /// Modelle (`visibility: "hide"`) werden nie gewaehlt
    func testCatalogOrderDecidesTheNextCandidate() async throws {
        let (s, fake, _) = await make()
        _ = try await connect(s, fake)
        try await s.setModel("gpt-5")
        await fake.on(ChatGPTConstants.modelsURL) { _ in
            (200, json(["models": [["slug": "gpt-6-luna", "display_name": "GPT-6-Luna", "visibility": "list", "priority": 4],
                                   ["slug": "gpt-daybreak-red-latest", "visibility": "hide", "priority": 12],
                                   ["slug": "gpt-6.1-sol", "display_name": "GPT-6.1-Sol", "visibility": "list", "priority": 1]]]))
        }
        await fake.on(ChatGPTConstants.responsesURL) { req in
            let model = (try? JSONValue.parse(req.body ?? Data()))?["model"]?.string ?? ""
            if model == "gpt-6-luna" { return (200, completedStream("OK", model: model)) }
            return (400, Data(#"{"detail":"The '\#(model)' model is not supported when using Codex with a ChatGPT account.","error":{"code":"model_not_found"}}"#.utf8))
        }
        let answer = try await s.complete(system: "S", prompt: "P")
        XCTAssertEqual(answer, "OK")
        let st = await s.status
        XCTAssertEqual(st.model, "gpt-6-luna", "Reihenfolge des Katalogs, nicht der festen Liste")
        let fromCatalog = await s.modelsFromCatalog
        XCTAssertTrue(fromCatalog)
        let listed = try await s.models()
        XCTAssertEqual(listed, ["gpt-6-luna", "gpt-6.1-sol"], "nur sichtbare, in Reihenfolge des Servers")
        let req = await fake.last(ChatGPTConstants.modelsURL)
        XCTAssertEqual(req?.headers["Authorization"], "Bearer at-1")
        XCTAssertEqual(req?.url, "https://api.openai.com/v1/models")
    }

    /// Kopfzeilen mit dem Zugriffstoken: `chatgpt-account-id` nur, wenn das JWT die Kennung des Kontos nennt
    /// (Codex-Client), sonst nicht; das Token selbst nur als Bearer
    func testRequestHeadersCarryTheAccountIDFromTheToken() {
        func jwt(_ claims: JSONValue) -> String { b64(Data(#"{"alg":"none"}"#.utf8)) + "." + b64(claims.serialized()) + ".sig" }
        let with = ChatGPTProtocol.requestHeaders(token: jwt(["sub": "s", "https://api.openai.com/auth": ["chatgpt_account_id": "acct_1", "chatgpt_plan_type": "plus"]]))
        XCTAssertEqual(with["chatgpt-account-id"], "acct_1")
        XCTAssertEqual(with["originator"], ChatGPTConstants.agentName)
        XCTAssertEqual(with["Accept"], "text/event-stream")
        XCTAssertEqual(with["Content-Type"], "application/json")
        XCTAssertTrue(with["Authorization"]?.hasPrefix("Bearer eyJ") ?? false)
        XCTAssertEqual(with.count, 5)
        let without = ChatGPTProtocol.requestHeaders(token: jwt(["sub": "s", "https://api.openai.com/auth": ["per_user_salt": "x", "encrypted_auth_metadata": "y"]]))
        XCTAssertNil(without["chatgpt-account-id"], "Sign in with ChatGPT nennt keine Kontokennung")
        XCTAssertNil(ChatGPTProtocol.requestHeaders(token: jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "  "]]))["chatgpt-account-id"])
        let plain = ChatGPTProtocol.requestHeaders(token: "at-1")
        XCTAssertEqual(plain["Authorization"], "Bearer at-1")
        XCTAssertNil(plain["chatgpt-account-id"])
        XCTAssertNil(ChatGPTProtocol.accountID(fromToken: "a.b"))
        XCTAssertNil(ChatGPTProtocol.accountID(fromToken: String(repeating: "a", count: 70_000)))
        XCTAssertEqual(ChatGPTIDToken.unverifiedClaims(jwt(["exp": 5]))?["exp"]?.int, 5)
    }

    /// Ereignisstrom (aufgezeichnete Form der Responses API): fertig erst mit `response.completed`; mehrzeilige
    /// `data:`, CRLF, `[DONE]`; Fehler nach Code
    func testStreamedTextIsCollectedUntilCompleted() throws {
        let full = completedStream("Hallo Welt", model: "gpt-6.1-sol") + Data("data: [DONE]\n\n".utf8)
        let got = try ChatGPTProtocol.streamedText(full)
        XCTAssertEqual(got.text, "Hallo Welt")
        XCTAssertEqual(got.model, "gpt-6.1-sol")
        XCTAssertEqual(got.response?["usage"]?["output_tokens"]?.int, 1)
        // ohne Text in der fertigen Antwort zaehlen die Deltas
        let deltas = sse([["type": "response.output_text.delta", "delta": "nur "], ["type": "response.output_text.delta", "delta": "Deltas"],
                          ["type": "response.completed", "response": ["output": []]]])
        XCTAssertEqual(try ChatGPTProtocol.streamedText(deltas).text, "nur Deltas")
        let crlf = Data("data: {\"type\": \"response.output_text.delta\",\r\ndata: \"delta\": \"CR\"}\r\n\r\n: Kommentar\r\ndata: {\"type\": \"response.completed\", \"response\": {\"output\": []}}\r\n\r\n".utf8)
        XCTAssertEqual(try ChatGPTProtocol.streamedText(crlf).text, "CR")
        XCTAssertEqual(ChatGPTProtocol.sseEvents("data: a\ndata: b\n\nevent: x\ndata: c\n\ndata: [DONE]\n\n"), ["a\nb", "c"])
        func failure(_ body: Data) -> AIError? { do { _ = try ChatGPTProtocol.streamedText(body); return nil } catch { return error as? AIError } }
        let limit = sse([["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "limit"]]]])
        XCTAssertEqual(failure(limit)?.code, "chatgpt_limit")
        XCTAssertEqual(failure(sse([["type": "response.failed", "response": ["error": ["code": "subscription_sharing_invalid_user"]]]]))?.code, "chatgpt_login_needed")
        XCTAssertEqual(failure(sse([["type": "error", "code": "server_error", "message": "kaputt"]]))?.message, "ChatGPT antwortete mit Fehler server_error: kaputt")
        XCTAssertEqual(failure(sse([["type": "response.incomplete", "response": ["incomplete_details": ["reason": "max_output_tokens"]]]]))?.message,
                       "ChatGPT hat die Antwort nicht beendet (max_output_tokens).")
        XCTAssertEqual(failure(sse([["type": "response.output_text.delta", "delta": "x"]]))?.message, "ChatGPT hat die Antwort nicht beendet (kein response.completed).")
        XCTAssertEqual(failure(Data())?.message, "ChatGPT antwortete unlesbar.")
        XCTAssertEqual(failure(Data("<html>".utf8))?.code, "ai_provider_error")
        XCTAssertEqual(failure(json(["error": ["code": "model_not_found", "message": "kein Modell"]]))?.message, "ChatGPT antwortete mit Fehler model_not_found: kein Modell")
    }

    /// Aendert sich die Anfrage (Fassung 2 am 3.11.2026), gelten alte Ablehnungen nicht mehr; ein zurueckgezogenes
    /// Modell wird durch den ersten heutigen Kandidaten ersetzt, ein selbst gewaehltes bleibt
    func testOldRejectionsAreForgottenWhenTheRequestChanges() async throws {
        var old = ChatGPTState.new()
        old.rejectedModelsVersion = nil                      // Stand bis 3.11.2026
        old.rejectedModels = ["gpt-5.5", "gpt-5.4", "gpt-5.2", "gpt-5.1"]
        old.model = "gpt-5.5-codex"
        let store = MemoryChatGPTStore(old)
        let (s, _, _) = await make(store)
        let st = await s.status
        XCTAssertEqual(st.model, "gpt-6.1-sol")
        let rejected = await s.rejectedModels
        XCTAssertEqual(rejected, [])
        XCTAssertEqual(store.load()?.rejectedModelsVersion, ChatGPTSession.requestVersion)
        XCTAssertEqual(store.saves, 1, "einmal gespeichert")
        // aktuelle Fassung: nichts angefasst, auch nicht gespeichert
        var cur = ChatGPTState.new()
        cur.rejectedModels = ["gpt-6-astra"]
        cur.model = "gpt-5.5"
        let store2 = MemoryChatGPTStore(cur)
        let (s2, _, _) = await make(store2)
        let rejected2 = await s2.rejectedModels
        XCTAssertEqual(rejected2, ["gpt-6-astra"])
        XCTAssertEqual(store2.saves, 0)
        // alte Fassung mit einem Modell, das es noch gibt: Ablehnungen weg, Modell bleibt
        var keep = ChatGPTState.new()
        keep.rejectedModelsVersion = 1
        keep.rejectedModels = ["gpt-5"]
        keep.model = "gpt-5.5"
        let store3 = MemoryChatGPTStore(keep)
        let (s3, _, _) = await make(store3)
        let st3 = await s3.status
        XCTAssertEqual(st3.model, "gpt-5.5")
        let rejected3 = await s3.rejectedModels
        XCTAssertEqual(rejected3, [])
        // ohne gespeicherten Stand wird nichts in den Schluesselbund geschrieben
        let empty = MemoryChatGPTStore()
        _ = await make(empty)
        XCTAssertEqual(empty.saves, 0)
        XCTAssertEqual(ChatGPTState.new().rejectedModelsVersion, ChatGPTSession.requestVersion)
    }

    func testWithoutUsageScopeNoRequests() async throws {
        let (s, fake, _) = await make()
        _ = try await connect(s, fake, scope: "openid email offline_access")
        try await s.setModel("gpt-test")
        let st = await s.status
        XCTAssertTrue(st.connected && !st.sharing && !st.enabledForAI)
        await assertError(try await s.complete(system: "", prompt: "x"), code: "chatgpt_not_enabled")
        let calls = await fake.count(ChatGPTConstants.responsesURL)
        XCTAssertEqual(calls, 0)
    }

    func testModelsSettingsAndDisconnect() async throws {
        let (s, fake, store) = await make()
        _ = try await connect(s, fake)
        await fake.on(ChatGPTConstants.modelsURL) { _ in (200, json(["data": [["id": "gpt-b"], ["slug": "gpt-a"], ["id": "gpt-b"], ["x": 1]]])) }
        let models = try await s.models()
        XCTAssertEqual(models, ["gpt-a", "gpt-b"])
        _ = try await s.models()
        let calls = await fake.count(ChatGPTConstants.modelsURL)
        XCTAssertEqual(calls, 1, "10 Minuten gemerkt")
        for bad in ["", "  ", "gpt test", String(repeating: "x", count: 101)] {
            XCTAssertThrowsError(try awaitSync { try await s.setModel(bad) }, bad)
        }
        try await s.setModel("  gpt-a  ")
        try await s.setUseForAI(false)
        var st = await s.status
        XCTAssertEqual(st.model, "gpt-a")
        XCTAssertFalse(st.enabledForAI, "Schalter aus")
        let host = store.load()?.hostID
        try await s.disconnect()
        st = await s.status
        XCTAssertFalse(st.connected)
        XCTAssertNil(st.email)
        XCTAssertNil(store.load()?.credentials)
        XCTAssertEqual(store.load()?.hostID, host, "Geraetekennung bleibt")
        XCTAssertEqual(store.load()?.clientID, "oaiapp_new", "ausgestellte ID bleibt")
    }

    // MARK: Hilfen

    private func awaitSync(_ f: @escaping () async throws -> Void) throws {
        let exp = expectation(description: "async")
        var failure: Error?
        Task { do { try await f() } catch { failure = error }; exp.fulfill() }
        wait(for: [exp], timeout: 5)
        if let failure { throw failure }
    }

    private func assertError(_ f: @autoclosure () async throws -> some Any, code: String? = nil, contains: String? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await f()
            XCTFail("kein Fehler", file: file, line: line)
        } catch let e as AIError {
            if let code { XCTAssertEqual(e.code, code, e.message, file: file, line: line) }
            if let contains { XCTAssertTrue(e.message.contains(contains), e.message, file: file, line: line) }
        } catch {
            XCTFail("anderer Fehler \(error)", file: file, line: line)
        }
    }
}
#endif

/// Kein Modell waehlen muessen (2.11.2026): StudiNow nimmt das Hauptmodell des Abos
final class ChatGPTPreferredModelTests: XCTestCase {
    func testPicksTheMainChatModel() {
        XCTAssertEqual(ChatGPTSession.preferredModel(["babbage-002", "gpt-4o-mini", "gpt-5", "gpt-5-2025-08-07", "gpt-4.1", "o3", "gpt-image-1",
                                                      "gpt-4o-realtime-preview", "text-embedding-3-large"]), "gpt-5")
        XCTAssertEqual(ChatGPTSession.preferredModel(["gpt-4.1", "gpt-4o", "gpt-10"]), "gpt-10", "Versionen numerisch, nicht alphabetisch")
        XCTAssertEqual(ChatGPTSession.preferredModel(["o3", "o4-mini", "whisper-1"]), "o3")
        XCTAssertEqual(ChatGPTSession.preferredModel(["eigenes-modell"]), "eigenes-modell")
        XCTAssertNil(ChatGPTSession.preferredModel([]))
        XCTAssertFalse(ChatGPTSession.fallbackModel.isEmpty)
        // Reihenfolge der Versuche: Hauptmodell, dann Codex-Fassungen, dann feste Kandidaten; abgelehnte nie wieder
        let c = ChatGPTSession.modelCandidates(listed: ["gpt-5", "gpt-5-codex", "gpt-4.1", "whisper-1"], excluding: ["gpt-5"])
        XCTAssertEqual(c.first, "gpt-4.1")
        XCTAssertTrue(c.contains("gpt-5-codex") && c.contains("gpt-5.5") && !c.contains("gpt-5") && !c.contains("whisper-1"))
        XCTAssertEqual(Set(c).count, c.count, "keine Doppelten")
        XCTAssertEqual(ChatGPTSession.modelCandidates(listed: [], excluding: []).first, "gpt-6.1-sol", "ohne Liste die festen Kandidaten")
        XCTAssertEqual(ChatGPTSession.fallbackModels, ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-6.1-terra",
                                                        "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"], "Codex-Katalog vom 3.11.2026 in Rangfolge")
        XCTAssertTrue(Set(ChatGPTSession.retiredModels).isDisjoint(with: ChatGPTSession.fallbackModels))
        XCTAssertTrue(ChatGPTSession.retiredModels.contains("gpt-5.5-codex"))
        // Katalog des Abos: dessen Reihenfolge zuerst, dann die festen Kandidaten, abgelehnte nie
        let k = ChatGPTSession.modelCandidates(listed: ["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra"], catalogOrder: true, excluding: ["gpt-6-luna"])
        XCTAssertEqual(Array(k.prefix(3)), ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol"])
        XCTAssertFalse(k.contains("gpt-6-luna"))
        XCTAssertEqual(Set(k).count, k.count)
        XCTAssertTrue(ChatGPTSession.isModelRejection(status: 404, body: Data(#"{"error":{"message":"The model `gpt-5` does not exist","code":"model_not_found"}}"#.utf8)))
        XCTAssertTrue(ChatGPTSession.isModelRejection(status: 400, body: Data(#"{"detail":"The 'gpt-5.5-codex' model is not supported when using Codex with a ChatGPT account.","error":{"type":"invalid_request_error","code":"model_not_found"}}"#.utf8)))
        XCTAssertTrue(ChatGPTSession.isModelRejection(status: 400, body: Data(#"{"error":{"code":"subscription_sharing_unsupported_capability","param":"model","message":"x"}}"#.utf8)))
        XCTAssertFalse(ChatGPTSession.isModelRejection(status: 400, body: Data(#"{"error":{"code":"subscription_sharing_unsupported_capability","param":"tools","message":"x"}}"#.utf8)))
        XCTAssertFalse(ChatGPTSession.isModelRejection(status: 503, body: Data("model".utf8)), "Ausfall bei OpenAI ist kein Modellproblem")
        XCTAssertFalse(ChatGPTSession.isModelRejection(status: 400, body: Data(#"{"error":"input too long"}"#.utf8)))
        XCTAssertEqual(ChatGPTSession.errorText(#"{"detail":"The 'x' model is not supported.","error":{"type":"invalid_request_error","code":"model_not_found"}}"#),
                       "The 'x' model is not supported.")
        XCTAssertEqual(ChatGPTSession.errorText(#"{"error":{"code":"nur_code"}}"#), "nur_code")
    }
}
