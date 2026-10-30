import Foundation

/// Antwort des Studora-Dienstes mit Kopfzeilen (fuer Retry-After)
public struct ServiceHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }
}

/// Transport zum Studora-Dienst (App: URLSession, Tests: Schein-Dienst); wirft nur, wenn der Dienst nicht erreichbar ist
public protocol ServiceHTTPTransport: Sendable {
    func send(_ request: AIHTTPRequest) async throws -> ServiceHTTPResponse
}

/// Ablage des Sitzungs-Tokens (App: Schluesselbund je Apple-Nutzer, nie synchronisiert)
public protocol AccountTokenStore: Sendable {
    func load() -> String?
    func save(_ token: String?) throws
}

/// Fehler des Dienstes mit stabilem Code und Text fuer den Nutzer (`{detail, code}`, Vertrag G1)
public struct AccountError: Error, Equatable, Sendable {
    public let status: Int
    public let code: String
    public let message: String
    /// Sekunden bis zum naechsten Versuch (`rate_limited`, `locked`: Retry-After)
    public let retryAfter: Int?
}

/// Studora-Konto (Vertrag G1, `packages/shared-contracts/fixtures/account/contract.json`; Referenz app/accounts.py,
/// app/account_api.py). Auf dem iPad in V1 nur Anmeldung und Kontoverwaltung, noch ohne Abgleich der Notizen (G2,
/// Stufe 2; Entscheidung des Inhabers vom 29.10.2026). Das Passwort geht nur an den Dienst und wird nie gespeichert;
/// gespeichert wird nur das Sitzungs-Token.
public actor StudoraAccount {
    public struct User: Equatable, Sendable {
        public var id: String
        public var email: String
        public var emailVerified: Bool
        public var university: String?
        public var plan: String
        public var role: String
    }

    public struct Session: Equatable, Sendable {
        public var id: Int
        public var deviceID: String?
        public var deviceName: String?
        public var lastSeen: String?
        public var current: Bool
    }

    /// Tarif beim Dienst mit Stand der 7-Tage-Probe (`GET /api/entitlements`, docs/ABO-SYSTEM.md Abschnitt 3a)
    public struct PlanStatus: Equatable, Sendable {
        public var plan: String
        public var trialActive: Bool
        public var trialDaysLeft: Int
        /// Plan der Probe (`plans.TRIAL`), solange sie laeuft
        public var trialPlan: String?
        public var needsPlanChoice: Bool

        public init(plan: String, trialActive: Bool = false, trialDaysLeft: Int = 0, trialPlan: String? = nil, needsPlanChoice: Bool = false) {
            self.plan = plan
            self.trialActive = trialActive
            self.trialDaysLeft = trialDaysLeft
            self.trialPlan = trialPlan
            self.needsPlanChoice = needsPlanChoice
        }
    }

    private let base: String
    private let http: ServiceHTTPTransport
    private let tokens: AccountTokenStore
    private let deviceID: String
    private let deviceName: String

    /// `base`: Adresse des Dienstes, z. B. https://app.example.de (ohne / am Ende)
    public init(base: String, http: ServiceHTTPTransport, tokens: AccountTokenStore, deviceID: String, deviceName: String) {
        self.base = base.hasSuffix("/") ? String(base.dropLast()) : base
        self.http = http
        self.tokens = tokens
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    public var isSignedIn: Bool { tokens.load() != nil }

    // MARK: Anfragen

    private func request(_ method: String, _ path: String, body: JSONValue? = nil, auth: Bool = true) async throws -> ServiceHTTPResponse {
        var headers = ["Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        if auth {
            guard let t = tokens.load() else { throw AccountError(status: 401, code: "unauthenticated", message: "Anmeldung erforderlich.", retryAfter: nil) }
            headers["Authorization"] = "Bearer \(t)"
        }
        let r: ServiceHTTPResponse
        do {
            r = try await http.send(AIHTTPRequest(method: method, url: base + path, headers: headers, body: body?.serialized()))
        } catch {
            throw AccountError(status: 0, code: "service_unreachable", message: "Der Studora-Dienst ist nicht erreichbar.", retryAfter: nil)
        }
        guard (200..<300).contains(r.status) else {
            let j = try? JSONValue.parse(r.body)
            // FastAPI: {"detail": "..."} oder {"detail": {"detail", "code"}}; der Dienst antwortet {"detail", "code"}
            let inner = j?["detail"]?.object != nil ? j?["detail"] : j
            let retry = r.headers.first { $0.key.lowercased() == "retry-after" }.flatMap { Int($0.value) }
            let code = inner?["code"]?.string ?? "http_\(r.status)"
            // nur eine beendete oder abgelaufene Sitzung meldet ab; ein falsches Passwort beim Loeschen nicht
            if r.status == 401, auth, code == "unauthenticated" { try? tokens.save(nil) }
            throw AccountError(status: r.status, code: code,
                               message: inner?["detail"]?.string ?? "Der Dienst antwortete mit Fehler \(r.status).", retryAfter: retry)
        }
        return r
    }

    private func json(_ r: ServiceHTTPResponse) -> JSONValue { (try? JSONValue.parse(r.body)) ?? .null }

    static func user(_ v: JSONValue?) -> User? {
        guard let v, let id = v["id"]?.string else { return nil }
        return User(id: id, email: v["email"]?.string ?? "", emailVerified: v["email_verified"]?.bool ?? false,
                    university: v["university"]?.string, plan: v["plan"]?.string ?? "free", role: v["role"]?.string ?? "user")
    }

    private func signedIn(_ r: ServiceHTTPResponse) throws -> User {
        let j = json(r)
        guard let token = j["token"]?.string, !token.isEmpty, let u = Self.user(j["user"]) else {
            throw AccountError(status: r.status, code: "bad_response", message: "Die Antwort des Dienstes ist unvollständig.", retryAfter: nil)
        }
        try tokens.save(token)
        return u
    }

    // MARK: Anmelden

    /// Mit E-Mail und Passwort (wer sich auf Windows oder im Web registriert hat)
    public func login(email: String, password: String) async throws -> User {
        try signedIn(try await request("POST", "/api/account/login", body: [
            "email": .string(email), "password": .string(password), "device_id": .string(deviceID), "device_name": .string(deviceName)], auth: false))
    }

    /// Mit Apple: das `identity_token` von "Mit Apple anmelden" (Konto ueber die Apple-Kennung, nie ueber die E-Mail)
    public func loginWithApple(identityToken: String, nonce: String? = nil) async throws -> (user: User, created: Bool) {
        var body: [String: JSONValue] = ["identity_token": .string(identityToken), "device_id": .string(deviceID), "device_name": .string(deviceName)]
        if let nonce { body["nonce"] = .string(nonce) }
        let r = try await request("POST", "/api/account/login/apple", body: .object(body), auth: false)
        let u = try signedIn(r)
        return (u, json(r)["created"]?.bool ?? false)
    }

    /// Apple mit dem angemeldeten Konto verknuepfen (danach reicht "Mit Apple anmelden")
    public func linkApple(identityToken: String) async throws {
        _ = try await request("POST", "/api/account/link/apple", body: ["identity_token": .string(identityToken)])
    }

    // MARK: Konto

    /// Konto und angemeldete Geraete
    public func me() async throws -> (user: User, sessions: [Session]) {
        let j = json(try await request("GET", "/api/account/me"))
        guard let u = Self.user(j["user"]) else {
            throw AccountError(status: 200, code: "bad_response", message: "Die Antwort des Dienstes ist unvollständig.", retryAfter: nil)
        }
        let sessions = (j["sessions"]?.array ?? []).compactMap { s -> Session? in
            guard let id = s["id"]?.double else { return nil }
            return Session(id: Int(id), deviceID: s["device_id"]?.string, deviceName: s["device_name"]?.string,
                           lastSeen: s["last_seen_at"]?.string ?? s["last_seen"]?.string, current: s["current"]?.bool ?? false)
        }
        return (u, sessions)
    }

    /// Tarif und Probe des Kontos
    public func planStatus() async throws -> PlanStatus {
        let j = json(try await request("GET", "/api/entitlements"))
        let t = j["trial"]
        let active = t?["active"]?.bool ?? false
        return PlanStatus(plan: j["plan"]?.string ?? "free", trialActive: active, trialDaysLeft: Int(t?["days_left"]?.double ?? 0),
                          trialPlan: active ? t?["plan"]?.string : nil, needsPlanChoice: j["needs_plan_choice"]?.bool ?? false)
    }

    /// "Bei Free bleiben" nach der Probe. Bezahlte Tarife waehlt das iPad nur im App Store (Antwort des Dienstes dazu
    /// ist eine Stripe-Adresse, die die App nie oeffnen darf).
    public func stayOnFree() async throws {
        _ = try await request("POST", "/api/billing/plan-choice", body: ["plan": .string("free")])
    }

    /// Ein anderes Geraet abmelden; die eigene Sitzung beendet diese Anmeldung
    public func revoke(session id: Int) async throws {
        _ = try await request("DELETE", "/api/account/sessions/\(id)")
    }

    /// Alle anderen Geraete abmelden; Rueckgabe: wie viele
    public func logoutOthers() async throws -> Int {
        Int(json(try await request("POST", "/api/account/logout-all"))["revoked"]?.double ?? 0)
    }

    /// Abmelden auf diesem Geraet (das Token ist danach auch lokal weg, selbst wenn der Dienst nicht erreichbar ist)
    public func logout() async {
        _ = try? await request("POST", "/api/account/logout")
        try? tokens.save(nil)
    }

    /// Alle Daten des Kontos als ZIP (DSGVO Art. 15 und 20)
    public func export() async throws -> Data {
        try await request("GET", "/api/account/export").body
    }

    /// Konto loeschen: sofort gesperrt, endgueltig nach 30 Tagen; Konten mit Passwort verlangen es
    public func delete(password: String?) async throws -> Int {
        let body: JSONValue = password.map { ["password": .string($0)] } ?? .object([:])
        let j = json(try await request("POST", "/api/account/delete", body: body))
        try? tokens.save(nil)
        return Int(j["purge_after_days"]?.double ?? 30)
    }
}
