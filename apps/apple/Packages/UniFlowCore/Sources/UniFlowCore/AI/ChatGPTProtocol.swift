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
    /// ausgestellte ID. `loginHint` (E-Mail des gespeicherten Profils, nur mit Client-ID) statt eines ID-Tokens:
    /// gespeicherte Tokens gehoeren nicht in die Browser-Adresse (Devkit oauth.ts). `reconsent` erzwingt die
    /// Zustimmungsseite (`prompt=consent`), auch bei der Erstregistrierung.
    public static func authorizeURL(clientID: String?, host: String, redirectURI: String, state: String, nonce: String,
                                    challenge: String, loginHint: String? = nil, reconsent: Bool = false) -> String {
        var q: [(String, String)] = [("client_id", clientID ?? ChatGPTConstants.firstClientID)]
        if clientID == nil { q.append(("agent_name_hint", ChatGPTConstants.agentName)) }
        q += [("ext_agent_host_id", host), ("response_type", "code"), ("redirect_uri", redirectURI), ("scope", ChatGPTConstants.scope),
              ("resource", ChatGPTConstants.resource), ("state", state), ("nonce", nonce), ("code_challenge", challenge),
              ("code_challenge_method", "S256")]
        if clientID != nil, let loginHint, !loginHint.isEmpty { q.append(("login_hint", loginHint)) }
        if reconsent { q.append(("prompt", "consent")) }
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
        /// `earliest_refresh_at` der Token-Antwort (Sekunden seit 1970): vorher nicht erneuern (Devkit
        /// `refresh_not_ready`). Fehlt bei aelteren gespeicherten Zustaenden und ohne Angabe von OpenAI.
        public var earliestRefreshAt: Double? = nil

        public init(accessToken: String, refreshToken: String?, idToken: String?, tokenType: String, expiresAt: Double,
                    scopes: [String], earliestRefreshAt: Double? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.idToken = idToken
            self.tokenType = tokenType
            self.expiresAt = expiresAt
            self.scopes = scopes
            self.earliestRefreshAt = earliestRefreshAt
        }

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

    /// `_earliest_refresh`: Sekunden seit 1970 als Zahl, oder ISO-8601 wie `datetime.fromisoformat` (mit `Z`, mit
    /// Versatz, oder ohne Zone = UTC); Wahrheitswerte und Unlesbares ergeben nil. Ohne Zeitzonendatenbank gerechnet.
    static func earliestRefresh(_ v: PyJSON?) -> Double? {
        switch v {
        case .some(.int(let digits)): return Double(digits)
        case .some(.float(let d)): return d
        case .some(.string(let s)): return isoEpoch(PyText.strip(s))
        default: return nil
        }
    }

    /// `datetime.fromisoformat(s).timestamp()` fuer die erweiterte Schreibweise `YYYY-MM-DD[THH:MM[:SS[.f…]]][Zone]`,
    /// Zone `Z`, `±HH:MM`, `±HHMM` oder `±HH`; ohne Zone UTC. Andere Schreibweisen (Kalenderwoche, Grundformat) nicht.
    static func isoEpoch(_ s: String) -> Double? {
        let u = Array(s.utf8)
        var i = 0
        func digits(_ n: Int) -> Int? {
            guard i + n <= u.count else { return nil }
            var v = 0
            for k in i..<(i + n) {
                guard u[k] >= 48, u[k] <= 57 else { return nil }
                v = v * 10 + Int(u[k] - 48)
            }
            i += n
            return v
        }
        func eat(_ c: UInt8) -> Bool { if i < u.count, u[i] == c { i += 1; return true }; return false }
        guard let year = digits(4), eat(UInt8(ascii: "-")), let month = digits(2), eat(UInt8(ascii: "-")), let day = digits(2),
              (1...12).contains(month), day >= 1, day <= BerlinClock.daysInMonth(year: year, month: month) else { return nil }
        var hour = 0, minute = 0, second = 0, fraction = 0.0, offset = 0
        if i < u.count, u[i] != UInt8(ascii: "Z"), u[i] != UInt8(ascii: "+"), u[i] != UInt8(ascii: "-") {
            i += 1                                        // Trenner (T oder Leerzeichen, wie Python: ein beliebiges Zeichen)
            guard let h = digits(2), eat(UInt8(ascii: ":")), let m = digits(2), h <= 23, m <= 59 else { return nil }
            hour = h; minute = m
            if eat(UInt8(ascii: ":")) {
                guard let sec = digits(2), sec <= 59 else { return nil }
                second = sec
                if eat(UInt8(ascii: ".")) || eat(UInt8(ascii: ",")) {
                    var scale = 0.1, any = false
                    while i < u.count, u[i] >= 48, u[i] <= 57 { fraction += Double(u[i] - 48) * scale; scale /= 10; i += 1; any = true }
                    guard any else { return nil }
                }
            }
        }
        if i < u.count {
            if eat(UInt8(ascii: "Z")) {
                guard i == u.count else { return nil }
            } else {
                let sign = u[i] == UInt8(ascii: "-") ? -1 : (u[i] == UInt8(ascii: "+") ? 1 : 0)
                guard sign != 0 else { return nil }
                i += 1
                guard let oh = digits(2), oh <= 23 else { return nil }
                var om = 0
                if i < u.count {
                    _ = eat(UInt8(ascii: ":"))
                    guard let m = digits(2), m <= 59 else { return nil }
                    om = m
                }
                guard i == u.count else { return nil }
                offset = sign * (oh * 3600 + om * 60)
            }
        }
        let days = BerlinClock.dayNumber(year: year, month: month, day: day)
        return Double(days * 86400 + hour * 3600 + minute * 60 + second - offset) + fraction
    }

    /// `_credentials_from`: alles zusammen ersetzen (auch das rotierte Refresh-Token); ohne Zugriffstoken ein Fehler.
    /// Nennt OpenAI `earliest_refresh_at`, wird vorher nicht erneuert.
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
                           expiresAt: now + expiresIn(AIPrompts.get(resp, "expires_in")), scopes: scopes,
                           earliestRefreshAt: earliestRefresh(AIPrompts.get(resp, "earliest_refresh_at")))
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
