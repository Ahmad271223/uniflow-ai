import Foundation

/// Einladungen ("Freunde einladen", docs/EINLADUNGEN.md, Entscheidung des Inhabers 04.11.2026): Stufen der Belohnung
/// wie in app/invites.py (`reward_tier`), geprueft gegen packages/shared-contracts/fixtures/invites/cases.json in
/// beiden Welten. Belohnungen sind Angebotscodes aus App Store Connect, eingeloest in Apples Dialog; die App schaltet
/// nie selbst einen Tarif frei.
public enum InviteRewards {
    /// Wahl der Belohnung je Stufe: `plus` (Plus-Monate gratis) oder `proai` (Pro AI zum Plus-Preis, nur Stufe 20)
    public enum Choice: String, CaseIterable, Sendable {
        case plus
        case proai
    }

    public struct Tier: Equatable, Sendable {
        public let count: Int
        public let choices: [Choice]
        public let rewards: [Choice: String]
        public init(count: Int, choices: [Choice], rewards: [Choice: String]) {
            self.count = count
            self.choices = choices
            self.rewards = rewards
        }
    }

    public static let maxLinks = 20
    public static let linkDays = 30
    public static let createDays = 7
    public static let linkBase = "https://studinow.app/i/"

    /// Die Tabelle (aufsteigend); Texte wie in app/invites.py REWARD_LABELS
    public static let tiers: [Tier] = [
        Tier(count: 5, choices: [.plus], rewards: [.plus: "1 Monat StudiNow Plus gratis"]),
        Tier(count: 10, choices: [.plus], rewards: [.plus: "3 Monate StudiNow Plus gratis"]),
        Tier(count: 20, choices: [.plus, .proai], rewards: [.plus: "12 Monate StudiNow Plus gratis",
                                                            .proai: "12 Monate StudiNow Pro AI zum Plus-Preis (19,99 € statt 39,99 €)"]),
    ]

    /// Hoechste erreichte Stufe (5, 10, 20) fuer so viele angekommene Personen; nil unter der ersten Stufe
    public static func tier(count: Int) -> Int? {
        var reached: Int?
        for t in tiers where count >= t.count { reached = t.count }
        return reached
    }

    /// Alle erreichten Stufen, aufsteigend
    public static func reached(count: Int) -> [Int] { tiers.filter { count >= $0.count }.map(\.count) }

    public static func tier(_ count: Int) -> Tier? { tiers.first { $0.count == count } }

    /// Die naechste noch nicht erreichte Stufe (nil: alle erreicht)
    public static func next(after count: Int) -> Tier? { tiers.first { count < $0.count } }

    /// "7 von 20 angekommen"
    public static func counterText(arrived: Int, max: Int = 20) -> String { "\(arrived) von \(max) angekommen" }

    /// Apples Einloese-Dialog fuer einen Angebotscode (wie app/invites.py redeem_url); nil ohne Apple-ID der App
    public static func redeemURL(appID: String?, code: String) -> URL? {
        guard let appID, !appID.isEmpty, !code.isEmpty else { return nil }
        return URL(string: "https://apps.apple.com/redeem?ctx=offercodes&id=\(appID)&code=\(code)")
    }
}

/// Einladungslinks: `https://studinow.app/i/<CODE>` (Universal Link, Associated Domain applinks:studinow.app) und als
/// Ersatz fuer den QR-Code `uniflow://invite/<CODE>`. Der Code hat 10 Zeichen ohne 0/O, 1/I/L (app/invites.py).
public enum InviteLink {
    public static let host = "studinow.app"
    public static let codeLength = 10
    public static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    public static func url(code: String) -> URL { URL(string: InviteRewards.linkBase + code)! }
    public static func schemeURL(code: String) -> URL { URL(string: "uniflow://invite/\(code)")! }

    /// Eingabe aus Link, QR oder Tastatur: gross, ohne Leerzeichen und Bindestriche; nil, wenn kein gueltiger Code
    public static func normalized(_ raw: String) -> String? {
        var s = raw.uppercased().filter { !" -_\t\r\n".contains($0) }
        let base = InviteRewards.linkBase.uppercased()
        if s.hasPrefix(base) { s = String(s.dropFirst(base.count)) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard s.count == codeLength, s.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return s
    }

    /// Code aus einem geoeffneten Link; nil fuer alles andere (auch fuer /i/ ohne Code)
    public static func code(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        if let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            guard (url.host ?? "").lowercased() == host || (url.host ?? "").lowercased() == "www." + host,
                  parts.count == 2, parts[0] == "i" else { return nil }
            return normalized(parts[1])
        }
        if url.scheme?.lowercased() == "uniflow", (url.host ?? "").lowercased() == "invite", parts.count == 1 {
            return normalized(parts[0])
        }
        return nil
    }
}

/// Stand der eigenen Einladungen (`GET /api/invites`)
public struct InviteOverview: Equatable, Sendable {
    public struct Link: Equatable, Sendable, Identifiable {
        public var code: String
        public var url: String
        public var createdAt: String
        public var expiresAt: String
        public var redemptions: Int
        public var expired: Bool
        public var id: String { code }
        public init(code: String, url: String, createdAt: String = "", expiresAt: String = "", redemptions: Int = 0, expired: Bool = false) {
            self.code = code; self.url = url; self.createdAt = createdAt; self.expiresAt = expiresAt; self.redemptions = redemptions; self.expired = expired
        }
    }

    public struct Claimed: Equatable, Sendable {
        public var choice: InviteRewards.Choice
        public var offerCode: String
        public var claimedAt: String
        public var redeemURL: URL?
        public init(choice: InviteRewards.Choice, offerCode: String, claimedAt: String = "", redeemURL: URL? = nil) {
            self.choice = choice; self.offerCode = offerCode; self.claimedAt = claimedAt; self.redeemURL = redeemURL
        }
    }

    public struct TierState: Equatable, Sendable, Identifiable {
        public var count: Int
        public var choices: [InviteRewards.Choice]
        public var rewards: [InviteRewards.Choice: String]
        public var reached: Bool
        public var claimable: Bool
        public var claimed: Claimed?
        public var id: Int { count }
        public init(count: Int, choices: [InviteRewards.Choice], rewards: [InviteRewards.Choice: String], reached: Bool = false,
                    claimable: Bool = false, claimed: Claimed? = nil) {
            self.count = count; self.choices = choices; self.rewards = rewards; self.reached = reached; self.claimable = claimable; self.claimed = claimed
        }
    }

    public var links: [Link]
    public var arrived: Int
    public var maxLinks: Int
    public var remainingLinks: Int
    public var canCreate: Bool
    public var createUntil: String?
    public var tier: Int?
    public var tiers: [TierState]
    public var appleAppID: String?

    public init(links: [Link] = [], arrived: Int = 0, maxLinks: Int = InviteRewards.maxLinks, remainingLinks: Int = InviteRewards.maxLinks,
                canCreate: Bool = false, createUntil: String? = nil, tier: Int? = nil, tiers: [TierState] = [], appleAppID: String? = nil) {
        self.links = links; self.arrived = arrived; self.maxLinks = maxLinks; self.remainingLinks = remainingLinks; self.canCreate = canCreate
        self.createUntil = createUntil; self.tier = tier; self.tiers = tiers; self.appleAppID = appleAppID
    }

    static func parse(_ j: JSONValue) -> InviteOverview {
        let links = (j["codes"]?.array ?? []).compactMap { c -> Link? in
            guard let code = c["code"]?.string else { return nil }
            return Link(code: code, url: c["url"]?.string ?? InviteRewards.linkBase + code, createdAt: c["created_at"]?.string ?? "",
                        expiresAt: c["expires_at"]?.string ?? "", redemptions: c["redemptions"]?.int ?? 0, expired: c["expired"]?.bool ?? false)
        }
        let appID = j["apple_app_id"]?.string
        let tiers = (j["tiers"]?.array ?? []).compactMap { t -> TierState? in
            guard let count = t["count"]?.int else { return nil }
            let choices = (t["choices"]?.array ?? []).compactMap { $0.string.flatMap(InviteRewards.Choice.init(rawValue:)) }
            var rewards: [InviteRewards.Choice: String] = [:]
            for (k, v) in t["rewards"]?.object ?? [:] { if let c = InviteRewards.Choice(rawValue: k), let s = v.string { rewards[c] = s } }
            var claimed: Claimed?
            if let cl = t["claimed"], let code = cl["offer_code"]?.string {
                claimed = Claimed(choice: cl["choice"]?.string.flatMap(InviteRewards.Choice.init(rawValue:)) ?? .plus, offerCode: code,
                                  claimedAt: cl["claimed_at"]?.string ?? "",
                                  redeemURL: cl["redeem_url"]?.string.flatMap(URL.init(string:)) ?? InviteRewards.redeemURL(appID: appID, code: code))
            }
            return TierState(count: count, choices: choices, rewards: rewards, reached: t["reached"]?.bool ?? false,
                             claimable: t["claimable"]?.bool ?? false, claimed: claimed)
        }
        return InviteOverview(links: links, arrived: j["arrived"]?.int ?? 0, maxLinks: j["max_links"]?.int ?? InviteRewards.maxLinks,
                              remainingLinks: j["remaining_links"]?.int ?? 0, canCreate: j["can_create"]?.bool ?? false,
                              createUntil: j["create_until"]?.string, tier: j["tier"]?.int, tiers: tiers, appleAppID: appID)
    }
}

/// Ergebnis von `POST /api/invites/claim`: der Angebotscode und Apples Einloese-Adresse
public struct InviteClaim: Equatable, Sendable {
    public var tier: Int
    public var choice: InviteRewards.Choice
    public var offerCode: String
    public var reward: String
    public var redeemURL: URL?
    public var already: Bool
    public init(tier: Int, choice: InviteRewards.Choice, offerCode: String, reward: String, redeemURL: URL?, already: Bool) {
        self.tier = tier; self.choice = choice; self.offerCode = offerCode; self.reward = reward; self.redeemURL = redeemURL; self.already = already
    }
}

public extension StudoraAccount {
    /// Eigene Einladungen, Zaehler und Stufen
    func invites() async throws -> InviteOverview {
        InviteOverview.parse(try JSONValue.parse(try await request("GET", "/api/invites").body))
    }

    /// Neuen Einladungslink anlegen (nur in der Probewoche, hoechstens 20); liefert den neuen Stand
    func createInvite() async throws -> InviteOverview {
        InviteOverview.parse(try JSONValue.parse(try await request("POST", "/api/invites", body: .object([:])).body))
    }

    /// Einloesung durch dieses (neue) Konto; idempotent. Rueckgabe: war es schon eingeloest?
    @discardableResult
    func redeemInvite(code: String) async throws -> Bool {
        let j = try JSONValue.parse(try await request("POST", "/api/invites/redeem", body: ["code": .string(code)]).body)
        return j["already"]?.bool ?? false
    }

    /// Angebotscode fuer eine erreichte Stufe
    func claimInvite(tier: Int, choice: InviteRewards.Choice) async throws -> InviteClaim {
        let j = try JSONValue.parse(try await request("POST", "/api/invites/claim",
                                                      body: ["tier": .number(Double(tier)), "choice": .string(choice.rawValue)]).body)
        guard let code = j["offer_code"]?.string else {
            throw AccountError(status: 200, code: "bad_response", message: "Die Antwort des Dienstes ist unvollständig.", retryAfter: nil)
        }
        return InviteClaim(tier: j["tier"]?.int ?? tier, choice: j["choice"]?.string.flatMap(InviteRewards.Choice.init(rawValue:)) ?? choice,
                           offerCode: code, reward: j["reward"]?.string ?? "", redeemURL: j["redeem_url"]?.string.flatMap(URL.init(string:)),
                           already: j["already"]?.bool ?? false)
    }
}
