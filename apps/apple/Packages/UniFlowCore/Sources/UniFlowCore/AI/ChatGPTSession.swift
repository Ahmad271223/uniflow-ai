import Foundation

// MARK: - Transport und Ablage

/// Eine HTTP-Anfrage an OpenAI (Token-Endpunkt, JWKS, Responses API, Modelle)
public struct AIHTTPRequest: Equatable, Sendable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: Data?
    public init(method: String, url: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
    }
}

/// Transport fuer die KI: die App nimmt URLSession, Tests feste Antworten. Wirft nur, wenn OpenAI nicht erreichbar
/// ist; jede HTTP-Antwort (auch 4xx/5xx) kommt mit Status zurueck.
public protocol AIHTTPTransport: Sendable {
    func send(_ request: AIHTTPRequest) async throws -> (status: Int, body: Data)
}

/// Was Studora sich zur Verbindung merkt (`chatgpt-auth.json` am PC). Auf dem iPad nur im Schluesselbund dieses
/// Geraets je Apple-Nutzer; nie beim Dienst, nie im Geraete-Abgleich.
public struct ChatGPTState: Codable, Equatable, Sendable {
    public struct Profile: Codable, Equatable, Sendable {
        public var sub: String?
        public var email: String?
        public var name: String?
    }

    /// `ext_agent_host_id`: einmal erzeugt und behalten
    public var hostID: String
    /// Von OpenAI ausgestellte `oaiapp_…`-ID (bleibt nach dem Trennen fuer die Neuanmeldung)
    public var clientID: String?
    public var credentials: ChatGPTProtocol.Credentials?
    public var profile: Profile?
    public var model: String = ""
    public var useForAI: Bool = true
    public var needsReauth: Bool = false
    public var lastError: String?

    public init(hostID: String) { self.hostID = hostID }
    public static func new() -> ChatGPTState { ChatGPTState(hostID: "urn:uuid:\(UUID().uuidString.lowercased())") }
}

/// Ablage des Zustands (App: Schluesselbund; Tests: Speicher)
public protocol ChatGPTStateStore: Sendable {
    func load() -> ChatGPTState?
    func save(_ state: ChatGPTState) throws
}

// MARK: - ID-Token

/// Zerlegt und prueft ein ID-Token von OpenAI wie `chatgpt_login.verify_id_token`. Die Signaturpruefung selbst
/// braucht Plattform-Kryptografie (`ChatGPTSignature`, nur Apple-Systeme); alles andere laeuft ueberall.
public enum ChatGPTIDToken {
    public static let leeway: Double = 60
    public static let algorithms: Set<String> = ["RS256", "ES256"]

    public struct Parts: Sendable {
        public let header: JSONValue
        public let payload: JSONValue
        public let signature: [UInt8]
        public let signingInput: Data
    }

    static func base64URLDecode(_ s: Substring) -> [UInt8]? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map { [UInt8]($0) }
    }

    public static func decode(_ token: String) throws -> Parts {
        let p = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 8192, p.count == 3, let h = base64URLDecode(p[0]), let b = base64URLDecode(p[1]),
              let sig = base64URLDecode(p[2]), let header = try? JSONValue.parse(Data(h)), let payload = try? JSONValue.parse(Data(b)) else {
            throw AIError("chatgpt_token_invalid", "ID-Token abgelehnt: Das Token ist unlesbar.")
        }
        return Parts(header: header, payload: payload, signature: sig, signingInput: Data("\(p[0]).\(p[1])".utf8))
    }

    /// `social_login._nonce_ok`: gleich oder SHA-256-Hex der erwarteten Nonce
    static func nonceOK(_ expected: String?, _ claim: JSONValue?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        guard let c = claim?.string, !c.isEmpty else { return false }
        return c == expected || c == SolutionSHA256.hexString(SolutionSHA256.hash(Data(expected.utf8)))
    }

    /// Angaben im Token: Aussteller, Empfaenger (= Client-ID), Ablauf (+60 s Kulanz), Nonce. Liefert die Angaben.
    public static func checkClaims(_ payload: JSONValue, clientID: String, nonce: String?, now: Double) throws -> JSONValue {
        func reject(_ why: String) -> AIError { AIError("chatgpt_token_invalid", "ID-Token abgelehnt: \(why)") }
        guard payload["iss"]?.string == ChatGPTConstants.issuer else { throw reject("Der Aussteller des Tokens passt nicht.") }
        let aud = payload["aud"]
        let auds = aud?.array?.compactMap(\.string) ?? (aud?.string).map { [$0] } ?? []
        guard auds.contains(clientID) else { throw reject("Das Token ist nicht fuer diese App ausgestellt.") }
        guard let exp = payload["exp"]?.double, exp + leeway >= now else { throw reject("Das Token ist abgelaufen.") }
        guard nonceOK(nonce, payload["nonce"]) else { throw reject("Die Nonce des Tokens stimmt nicht.") }
        return payload
    }
}

/// Prueft die Signatur eines ID-Tokens mit einem Schluessel aus der JWKS (RS256 oder ES256)
public protocol ChatGPTSignatureChecking: Sendable {
    func verify(jwk: JSONValue, alg: String, signingInput: Data, signature: [UInt8]) -> Bool
}

// MARK: - Anmeldung

/// Ein Anmeldeversuch (`chatgpt_login.Flow`): Rueckleitung, state, nonce, PKCE; nil-Client = Erstregistrierung
public struct ChatGPTLoginAttempt: Equatable, Sendable {
    public let url: String
    public let redirectURI: String
    public let state: String
    public let nonce: String
    public let verifier: String
    public let clientID: String?
    public let started: Double
}

// MARK: - Sitzung

/// Verbindung mit dem ChatGPT-Abo des Nutzers wie app/chatgpt_login.py und `ai_backend.ChatGPTProvider`:
/// Anmeldung (Code tauschen, ID-Token pruefen), Zugriffstoken 60 s vor Ablauf erneuern (rotierendes Refresh-Token),
/// Anfragen an die Responses API, Modelle, Trennen. Gesendet wird nur, was die App ausdruecklich uebergibt.
public actor ChatGPTSession {
    private let store: ChatGPTStateStore
    private let http: AIHTTPTransport
    private let signature: ChatGPTSignatureChecking?
    private let now: @Sendable () -> Double
    private var state: ChatGPTState
    private var pending: ChatGPTLoginAttempt?
    private var jwks: (at: Double, keys: [JSONValue])?
    private var modelsCache: (at: Double, ids: [String])?

    /// `signature`: nil nur in Tests ohne Plattform-Kryptografie (dann wird ein ID-Token abgelehnt)
    public init(store: ChatGPTStateStore, http: AIHTTPTransport, signature: ChatGPTSignatureChecking?,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = store
        self.http = http
        self.signature = signature
        self.now = now
        state = store.load() ?? .new()
    }

    // MARK: Stand

    public struct Status: Equatable, Sendable {
        public var connected: Bool
        public var sharing: Bool
        public var needsReauth: Bool
        public var email: String?
        public var name: String?
        public var model: String
        public var useForAI: Bool
        public var registered: Bool
        public var lastError: String?
        /// KI-Anfragen ueber ChatGPT moeglich (`enabled_for_ai`)
        public var enabledForAI: Bool { connected && sharing && useForAI && !model.isEmpty && !needsReauth }
    }

    public var status: Status {
        let c = state.credentials
        return Status(connected: c.map { !$0.accessToken.isEmpty && !($0.refreshToken ?? "").isEmpty } ?? false,
                      sharing: c?.sharing ?? false, needsReauth: state.needsReauth, email: state.profile?.email,
                      name: state.profile?.name, model: state.model, useForAI: state.useForAI,
                      registered: state.clientID != nil, lastError: state.lastError)
    }

    private func persist() throws { try store.save(state) }

    // MARK: Anmelden

    /// Neuer Anmeldeversuch (`start`); die App oeffnet `url` und leitet die Rueckleitung an `completeLogin` weiter.
    /// `newAccount`: anderes ChatGPT-Konto, also eine neue Registrierung (ausgestellte Client-ID, Profil und
    /// Zugangsdaten weg, die Geraetekennung bleibt). `reconsent`: Zustimmungsseite erzwingen, um die Nutzung des
    /// Abos freizugeben. `login_hint` ist die E-Mail des gespeicherten Profils, nur mit vorhandener Client-ID.
    public func beginLogin(redirectURI: String, newAccount: Bool = false, reconsent: Bool = false) throws -> ChatGPTLoginAttempt {
        if newAccount {
            state.clientID = nil
            state.credentials = nil
            state.profile = nil
            state.needsReauth = false
            state.lastError = nil
            modelsCache = nil
            try persist()
        }
        return newAttempt(redirectURI: redirectURI, reconsent: reconsent)
    }

    /// Wie `beginLogin(redirectURI:newAccount:reconsent:)` ohne Zuruecksetzen; kann nichts speichern, wirft nicht
    public func beginLogin(redirectURI: String) -> ChatGPTLoginAttempt {
        newAttempt(redirectURI: redirectURI, reconsent: false)
    }

    private func newAttempt(redirectURI: String, reconsent: Bool) -> ChatGPTLoginAttempt {
        var rng = SystemRandomNumberGenerator()
        let verifier = ChatGPTProtocol.newVerifier(using: &rng)
        let st = ChatGPTProtocol.randomToken(bytes: 32, using: &rng), nonce = ChatGPTProtocol.randomToken(bytes: 16, using: &rng)
        let hint = state.clientID != nil ? state.profile?.email : nil
        let url = ChatGPTProtocol.authorizeURL(clientID: state.clientID, host: state.hostID, redirectURI: redirectURI, state: st,
                                               nonce: nonce, challenge: ChatGPTProtocol.challenge(for: verifier),
                                               loginHint: hint, reconsent: reconsent)
        let attempt = ChatGPTLoginAttempt(url: url, redirectURI: redirectURI, state: st, nonce: nonce, verifier: verifier,
                                          clientID: state.clientID, started: now())
        pending = attempt
        return attempt
    }

    public func cancelLogin() { pending = nil }

    /// Von OpenAI vergebene Client-ID aus der Konfiguration der App (nach der Aufnahme, docs/KI-CHATGPT-PLAN.md §4):
    /// dann keine Erstregistrierung mit `dynamic_agent_client`. Eine schon ausgestellte ID bleibt.
    public func useConfiguredClientID(_ id: String?) throws {
        guard let id, !id.isEmpty, state.clientID == nil else { return }
        state.clientID = id
        try persist()
    }

    /// Rueckleitung auswerten (`handle_callback`): falscher state, Abbruch oder fehlender Code tauschen nichts; bei der
    /// Erstregistrierung wird die ausgestellte Client-ID VOR dem Tausch gemerkt.
    public func completeLogin(query: [String: String]) async throws {
        guard let flow = pending else { throw AIError("chatgpt_flow", "Diese Anmeldung ist schon abgeschlossen.") }
        guard now() - flow.started <= ChatGPTConstants.flowTimeout else {
            pending = nil
            throw AIError("chatgpt_flow", "Die Anmeldung hat zu lange gedauert. Bitte erneut „ChatGPT verbinden“.")
        }
        guard query["state"] == flow.state else {
            throw AIError("chatgpt_flow", "Die Antwort gehoert nicht zu dieser Anmeldung (state). Bitte in Studora erneut „ChatGPT verbinden“.")
        }
        if let err = query["error"] {
            pending = nil
            throw AIError("chatgpt_flow", err == "access_denied" ? "Anmeldung abgebrochen." : "OpenAI meldet: \(query["error_description"] ?? err)")
        }
        guard let code = query["code"], !code.isEmpty else { throw AIError("chatgpt_flow", "Die Antwort enthaelt keinen Code.") }
        pending = nil
        let issued = query["client_id"]
        let clientID: String
        if let known = flow.clientID {
            if let issued, issued != known {
                throw AIError("chatgpt_flow", "OpenAI nannte eine andere Client-ID als gespeichert – Antwort abgelehnt.")
            }
            clientID = known
        } else {
            guard let issued, !issued.isEmpty else {
                throw AIError("chatgpt_flow", "OpenAI hat keine Client-ID ausgestellt (Registrierung unvollstaendig).")
            }
            state.clientID = issued                       // vor dem Tausch merken: ein zweiter Versuch nutzt sie wieder
            try persist()
            clientID = issued
        }
        let resp: PyJSON
        do {
            resp = try await postForm(ChatGPTConstants.tokenURL,
                                      ChatGPTProtocol.codeForm(clientID: clientID, code: code, verifier: flow.verifier, redirectURI: flow.redirectURI))
        } catch let e as HTTPFailure {
            throw AIError("chatgpt_http_error", "Verbindung nicht abgeschlossen: \(e.message)")
        }
        let creds = try ChatGPTProtocol.credentials(from: resp, now: now())
        if let idToken = creds.idToken {
            let claims = try await verifyIDToken(idToken, clientID: clientID, nonce: flow.nonce)
            try sameAccount(claims)                       // vor dem Speichern: bei fremdem Konto bleibt alles wie es war
            state.profile = .init(sub: claims["sub"]?.string, email: claims["email"]?.string,
                                  name: claims["name"]?.string ?? claims["given_name"]?.string)
        }
        state.clientID = clientID
        state.credentials = creds
        state.needsReauth = false
        state.lastError = nil
        try persist()
    }

    /// `_same_account`: eine erneute Anmeldung mit der gespeicherten Client-ID muss dasselbe ChatGPT-Konto liefern
    /// (Devkit `account_mismatch`); ein anderes Konto gehoert zu einer neuen Registrierung (`beginLogin(newAccount:)`)
    private func sameAccount(_ claims: JSONValue) throws {
        guard let old = state.profile?.sub, !old.isEmpty, let new = claims["sub"]?.string, !new.isEmpty, new != old else { return }
        throw AIError("chatgpt_account_mismatch", "Diese Anmeldung gehört zu einem anderen ChatGPT-Konto. Bitte das "
                      + "ursprüngliche Konto wählen oder in Studora „Anderes Konto verbinden“.")
    }

    // MARK: Token

    /// Gueltiges Zugriffstoken (`access_token`): erneuert 60 s vor Ablauf, aber nicht vor `earliest_refresh_at`;
    /// ist das Token dann schon abgelaufen, `chatgpt_refresh_not_ready` (gleich noch einmal versuchen)
    public func accessToken() async throws -> String {
        guard status.connected, let c = state.credentials else { throw AIError("chatgpt_login_needed", "ChatGPT ist nicht verbunden.") }
        if state.needsReauth { throw AIError("chatgpt_login_needed", "Die Anmeldung bei ChatGPT ist abgelaufen – bitte neu verbinden.") }
        let t = now()
        if c.expiresAt - ChatGPTConstants.refreshMargin <= t {
            if let earliest = c.earliestRefreshAt, earliest > t {
                if c.expiresAt <= t {
                    throw AIError("chatgpt_refresh_not_ready", "Die ChatGPT-Verbindung kann noch nicht erneuert werden – "
                                  + "bitte gleich noch einmal versuchen.")
                }
            } else {
                try await refresh()
            }
        }
        return state.credentials!.accessToken
    }

    /// `refresh`: rotiertes Refresh-Token uebernehmen; ein mitgeliefertes ID-Token (Nonce entfaellt) muss zum
    /// gespeicherten Konto passen, sonst neu anmelden
    private func refresh() async throws {
        guard let c = state.credentials, let rt = c.refreshToken, !rt.isEmpty, let clientID = state.clientID else {
            throw AIError("chatgpt_login_needed", "Bitte ChatGPT neu verbinden.")
        }
        let resp: PyJSON
        do {
            resp = try await postForm(ChatGPTConstants.tokenURL, ChatGPTProtocol.refreshForm(refreshToken: rt, clientID: clientID))
        } catch let e as HTTPFailure where [400, 401, 403].contains(e.status) {
            try markReauth("Erneuerung abgelehnt: \(e.message)")
            throw AIError("chatgpt_login_needed", "Die Anmeldung bei ChatGPT ist abgelaufen – bitte neu verbinden.")
        }
        let new = try ChatGPTProtocol.credentials(from: resp, previous: c, now: now())
        if AIPrompts.truthy(AIPrompts.get(resp, "id_token")) {
            do {
                try sameAccount(try await verifyIDToken(AIPrompts.str(AIPrompts.get(resp, "id_token")), clientID: clientID, nonce: nil))
            } catch {                                 // wie `except ChatGPTError`: Pruefung oder Abruf der Schluessel
                guard error is AIError || error is HTTPFailure else { throw error }
                let why = (error as? AIError)?.message ?? (error as? HTTPFailure)?.message ?? ""
                try markReauth("Erneuerung: \(why)")
                throw AIError("chatgpt_login_needed", "Die erneuerte Anmeldung passt nicht zu diesem Konto – bitte neu verbinden.")
            }
        }
        state.credentials = new
        state.needsReauth = false
        try persist()
    }

    private func markReauth(_ why: String) throws {
        state.needsReauth = true
        state.lastError = PyText.slice(why, 0, 300)
        try persist()
    }

    // MARK: Anfragen

    /// Antworttext der Responses API (`ChatGPTProvider.complete`); 401 heisst "neu verbinden", 402/403/429
    /// "Kontingent aufgebraucht oder nicht freigegeben"
    public func complete(system: String, prompt: String, schema: JSONValue? = nil) async throws -> String {
        guard status.enabledForAI else {
            throw AIError("chatgpt_not_enabled", status.connected && status.model.isEmpty
                          ? "Bitte in den Einstellungen ein ChatGPT-Modell wählen." : "KI über ChatGPT ist nicht verbunden.")
        }
        let token = try await accessToken()
        let body = ChatGPTProtocol.responsesBody(model: state.model, system: system, prompt: prompt, schema: schema).serialized()
        let r: (status: Int, body: Data)
        do {
            r = try await http.send(AIHTTPRequest(method: "POST", url: ChatGPTConstants.responsesURL,
                                                  headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"], body: body))
        } catch {
            throw ChatGPTProtocol.error(status: 0)
        }
        guard (200..<300).contains(r.status) else {
            if r.status == 401 { try markReauth("Responses API 401") }
            throw ChatGPTProtocol.error(status: r.status, detail: String(decoding: r.body.prefix(400), as: UTF8.self))
        }
        guard let json = try? JSONValue.parse(r.body) else { throw AIError("ai_provider_error", "ChatGPT antwortete unlesbar.") }
        return ChatGPTProtocol.outputText(json)
    }

    /// Modelle des Abos (`GET /v1/models`), 10 Minuten gemerkt
    public func models(force: Bool = false) async throws -> [String] {
        if !force, let c = modelsCache, now() - c.at < 600 { return c.ids }
        let token = try await accessToken()
        let data: PyJSON
        do {
            data = try await getJSON(ChatGPTConstants.modelsURL, bearer: token)
        } catch let e as HTTPFailure where e.status == 401 {
            try markReauth(e.message)
            throw AIError("chatgpt_login_needed", "Die Anmeldung bei ChatGPT ist abgelaufen – bitte neu verbinden.")
        }
        var ids = Set<String>()
        if case .array(let items)? = AIPrompts.get(data, "data") {
            for m in items {
                let id = AIPrompts.or(AIPrompts.get(m, "id"), AIPrompts.get(m, "slug"))
                if AIPrompts.truthy(id) { ids.insert(AIPrompts.str(id)) }
            }
        }
        let sorted = ids.sorted(by: PyText.less)
        modelsCache = (now(), sorted)
        return sorted
    }

    /// `set_model`: nicht leer, hoechstens 100 Zeichen, ohne Leerraum
    public func setModel(_ slug: String) throws {
        let s = PyText.strip(slug)
        guard !s.isEmpty, PyText.length(s) <= 100, !s.unicodeScalars.contains(where: PyText.isSpace) else {
            throw AIError("chatgpt_model_invalid", "Ungueltiger Modellname.")
        }
        state.model = s
        try persist()
    }

    public func setUseForAI(_ on: Bool) throws {
        state.useForAI = on
        try persist()
    }

    /// Zugangsdaten und Profil loeschen; Geraetekennung und ausgestellte Client-ID bleiben fuer die Neuanmeldung
    public func disconnect() throws {
        state.credentials = nil
        state.profile = nil
        state.needsReauth = false
        state.lastError = nil
        modelsCache = nil
        pending = nil
        try persist()
    }

    // MARK: HTTP

    /// Fehlerhafte Antwort von OpenAI (`ChatGPTError("chatgpt_http_error", …)`)
    struct HTTPFailure: Error {
        let status: Int
        let message: String
    }

    private func decode(_ r: (status: Int, body: Data)) throws -> PyJSON {
        guard (200..<300).contains(r.status) else {
            let text = String(decoding: r.body.prefix(600), as: UTF8.self)
            let failure = HTTPFailure(status: r.status, message: "OpenAI antwortete mit Fehler \(r.status): \(Self.errorText(text))")
            if [400, 401, 403].contains(r.status) { throw failure }
            throw AIError("chatgpt_http_error", failure.message)
        }
        return (try? PyJSON.parse(r.body.isEmpty ? Data("{}".utf8) : r.body)) ?? .object([])
    }

    private func send(_ req: AIHTTPRequest) async throws -> (status: Int, body: Data) {
        do { return try await http.send(req) } catch {
            throw AIError("chatgpt_unreachable", "OpenAI ist nicht erreichbar.")
        }
    }

    private func postForm(_ url: String, _ form: String) async throws -> PyJSON {
        try decode(try await send(AIHTTPRequest(method: "POST", url: url, headers: [
            "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"], body: Data(form.utf8))))
    }

    private func getJSON(_ url: String, bearer: String?) async throws -> PyJSON {
        var headers = ["Accept": "application/json"]
        if let bearer { headers["Authorization"] = "Bearer \(bearer)" }
        return try decode(try await send(AIHTTPRequest(method: "GET", url: url, headers: headers)))
    }

    /// `_error_text`: Meldung aus `{"error": {"message"}}` oder `error_description`, sonst der Anfang des Texts
    static func errorText(_ body: String) -> String {
        if let j = try? JSONValue.parse(Data(body.utf8)) {
            if let err = j["error"], case .object = err {
                return PyText.slice(err["message"]?.string ?? err["code"]?.string ?? body, 0, 300)
            }
            if let d = j["error_description"]?.string { return PyText.slice(d, 0, 300) }
        }
        return PyText.slice(body, 0, 300)
    }

    // MARK: ID-Token pruefen

    private func keys(force: Bool) async throws -> [JSONValue] {
        if !force, let j = jwks, now() - j.at < 3600 { return j.keys }
        let data = try await getJSON(ChatGPTConstants.jwksURL, bearer: nil).json
        guard let keys = data["keys"]?.array else {
            throw AIError("chatgpt_token_invalid", "Die Schluesselliste von OpenAI ist unbrauchbar.")
        }
        jwks = (now(), keys)
        return keys
    }

    func verifyIDToken(_ token: String, clientID: String, nonce: String?) async throws -> JSONValue {
        let parts = try ChatGPTIDToken.decode(token)
        guard let alg = parts.header["alg"]?.string, ChatGPTIDToken.algorithms.contains(alg) else {
            throw AIError("chatgpt_token_invalid", "ID-Token abgelehnt: Algorithmus nicht erlaubt.")
        }
        let kid = parts.header["kid"]?.string
        var jwk: JSONValue?
        for force in [false, true] {
            let ks = try await keys(force: force)
            jwk = ks.first { $0["kid"]?.string == kid && kid != nil } ?? (kid == nil && ks.count == 1 ? ks.first : nil)
            if jwk != nil { break }
        }
        guard let jwk else { throw AIError("chatgpt_token_invalid", "ID-Token abgelehnt: Der Signaturschluessel des Tokens ist OpenAI nicht bekannt.") }
        guard let signature, signature.verify(jwk: jwk, alg: alg, signingInput: parts.signingInput, signature: parts.signature) else {
            throw AIError("chatgpt_token_invalid", "ID-Token abgelehnt: Signatur ungueltig.")
        }
        return try ChatGPTIDToken.checkClaims(parts.payload, clientID: clientID, nonce: nonce, now: now())
    }
}
