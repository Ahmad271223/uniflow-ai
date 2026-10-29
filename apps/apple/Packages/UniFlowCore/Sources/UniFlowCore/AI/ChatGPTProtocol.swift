import Foundation

/// Sign in with ChatGPT wie app/chatgpt_login.py, soweit ohne Netz und ohne Plattform-Kryptografie (auch unter
/// Linux): PKCE, Autorisierungsadresse, Formulare am Token-Endpunkt, Zugangsdaten aus Token-Antworten, Anfrage an die
/// Responses API und ihr Text, Fehlercodes. Vertrag: packages/shared-contracts/ai/contract.json (`chatgpt`).
public enum ChatGPTProtocol {
    // MARK: PKCE

    /// base64url ohne "="
    public static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `code_challenge` (S256) zu einem Verifier
    public static func challenge(for verifier: String) -> String {
        base64URL(SolutionSHA256.hash(Data(verifier.utf8)))
    }

    /// Neuer Verifier: 96 Zeichen aus [A-Za-z0-9-_] wie `secrets.token_urlsafe(64)[:96]`
    public static func newVerifier<R: RandomNumberGenerator>(using rng: inout R) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<96).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }

    /// Zufaelliger Wert fuer `state` bzw. `nonce` (base64url aus `bytes` Zufallsbytes, wie `secrets.token_urlsafe`)
    public static func randomToken<R: RandomNumberGenerator>(bytes: Int, using rng: inout R) -> String {
        base64URL((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    // MARK: Adressen und Formulare

    /// `urllib.parse.urlencode(pairs)`
    static func urlencode(_ pairs: [(String, String)]) -> String {
        pairs.map { PyText.quote($0.0, safe: "", plus: true) + "=" + PyText.quote($0.1, safe: "", plus: true) }.joined(separator: "&")
    }

    /// `build_auth_url`: Erstregistrierung ohne eigene Client-ID (`dynamic_agent_client` + Name der App), sonst die
    /// ausgestellte ID (dann auf Wunsch mit `id_token_hint`)
    public static func authorizeURL(clientID: String?, host: String, redirectURI: String, state: String, nonce: String,
                                    challenge: String, idTokenHint: String? = nil) -> String {
        var q: [(String, String)] = [("client_id", clientID ?? ChatGPTConstants.firstClientID)]
        if clientID == nil { q.append(("agent_name_hint", ChatGPTConstants.agentName)) }
        q += [("ext_agent_host_id", host), ("response_type", "code"), ("redirect_uri", redirectURI), ("scope", ChatGPTConstants.scope),
              ("resource", ChatGPTConstants.resource), ("state", state), ("nonce", nonce), ("code_challenge", challenge),
              ("code_challenge_method", "S256")]
        if clientID != nil, let idTokenHint { q.append(("id_token_hint", idTokenHint)) }
        return ChatGPTConstants.authURL + "?" + urlencode(q)
    }

    /// Formular fuer den Tausch des Codes (`exchange_code`)
    public static func codeForm(clientID: String, code: String, verifier: String, redirectURI: String) -> String {
        urlencode([("grant_type", "authorization_code"), ("client_id", clientID), ("code", code), ("code_verifier", verifier),
                   ("redirect_uri", redirectURI), ("resource", ChatGPTConstants.resource)])
    }

    /// Formular fuer die Erneuerung (`refresh`)
    public static func refreshForm(refreshToken: String, clientID: String) -> String {
        urlencode([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID),
                   ("resource", ChatGPTConstants.resource)])
    }

    // MARK: Zugangsdaten

    public struct Credentials: Codable, Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var idToken: String?
        public var tokenType: String
        /// Sekunden seit 1970
        public var expiresAt: Double
        public var scopes: [String]

        /// Darf Studora das Abo nutzen? Nur, wenn OpenAI den Scope wirklich gewaehrt hat (`sharing`)
        public var sharing: Bool { scopes.contains(ChatGPTConstants.usageScope) }
    }

    /// `int(x or 3600)` mit Rueckfall 3600 bei unlesbarem Wert
    static func expiresIn(_ v: PyJSON?) -> Double {
        guard AIPrompts.truthy(v) else { return 3600 }
        switch v {
        case .some(.int(let d)): return Double(Int(d) ?? 3600)
        case .some(.float(let d)) where d.isFinite: return Double(Int(d.rounded(.towardZero)))
        case .some(.bool(let b)): return b ? 1 : 0
        case .some(.string(let s)): return Double(PyConvert.int(s) ?? 3600)
        default: return 3600
        }
    }

    /// `_credentials_from`: alles zusammen ersetzen (auch das rotierte Refresh-Token); ohne Zugriffstoken ein Fehler
    public static func credentials(from resp: PyJSON, previous: Credentials? = nil, now: Double) throws -> Credentials {
        guard case .string(let access)? = AIPrompts.get(resp, "access_token"), !access.isEmpty else {
            throw AIError("chatgpt_token_invalid", "Die Antwort von OpenAI enthaelt kein Zugriffstoken.")
        }
        let scopeText = AIPrompts.str(AIPrompts.or(AIPrompts.get(resp, "scope"), .string("")))
        var scopes = scopeText.split(whereSeparator: { PyText.isSpace($0.unicodeScalars.first!) }).map(String.init)
        if scopes.isEmpty { scopes = previous?.scopes ?? [] }
        func text(_ key: String) -> String? {
            guard AIPrompts.truthy(AIPrompts.get(resp, key)) else { return nil }
            return AIPrompts.str(AIPrompts.get(resp, key))
        }
        return Credentials(accessToken: access, refreshToken: text("refresh_token") ?? previous?.refreshToken,
                           idToken: text("id_token") ?? previous?.idToken, tokenType: text("token_type") ?? "Bearer",
                           expiresAt: now + expiresIn(AIPrompts.get(resp, "expires_in")), scopes: scopes)
    }

    // MARK: Responses API

    /// Anfrage an `POST /v1/responses` (`ChatGPTProvider.complete`)
    public static func responsesBody(model: String, system: String, prompt: String, schema: JSONValue? = nil) -> JSONValue {
        var body: [String: JSONValue] = ["model": .string(model), "instructions": .string(system), "input": .string(prompt)]
        if let schema {
            body["text"] = ["format": ["type": "json_schema", "name": "studora", "schema": schema, "strict": false]]
        }
        return .object(body)
    }

    /// Text der Antwort: alle `output_text` aller Nachrichten der Reihe nach
    public static func outputText(_ response: JSONValue) -> String {
        var out = ""
        for item in response["output"]?.array ?? [] where item["type"]?.string == "message" {
            for c in item["content"]?.array ?? [] where c["type"]?.string == "output_text" { out += c["text"]?.string ?? "" }
        }
        return out
    }

    /// Fehler der Responses API nach HTTP-Status (0 = nicht erreichbar)
    public static func error(status: Int, detail: String = "") -> AIError {
        switch status {
        case 0: return AIError("ai_provider_unreachable", "ChatGPT ist nicht erreichbar.")
        case 401: return AIError("chatgpt_login_needed", "Die Anmeldung bei ChatGPT ist abgelaufen – bitte in den Einstellungen neu verbinden.")
        case 402, 403, 429:
            return AIError("chatgpt_limit", "Dein ChatGPT-Kontingent ist aufgebraucht oder die Nutzung in Apps ist nicht "
                           + "freigegeben. In ChatGPT unter Einstellungen → Nutzung verwalten.")
        default: return AIError("ai_provider_error", "ChatGPT antwortete mit Fehler \(status): \(PyText.slice(detail, 0, 200))")
        }
    }
}
