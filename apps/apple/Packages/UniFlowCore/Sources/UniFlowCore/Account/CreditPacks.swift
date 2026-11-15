import Foundation

/// KI-Credits zum Nachkaufen (Auftrag des Inhabers vom 15.11.2026; Dienst: app/credits.py, app/plans.py `CREDIT_PACKS`,
/// app/apple_store.py; Vertrag `packages/shared-contracts/fixtures/credit-packs/contract.json`,
/// docs/KI-CREDITS-2026-11-15.md).
///
/// Zwei Toepfe je Konto: Monats-Credits (jeden Monat neu bis zum Rahmen des Tarifs, der Rest verfaellt) und gekaufte
/// Credits (verfallen nie). Verbraucht werden zuerst die Monats-Credits. Gekauft wird als Verbrauchskauf im App Store;
/// die App schickt die signierte Transaktion an den Dienst und schliesst sie erst ab, wenn der Dienst sie verbucht hat.
/// Wie viele Credits ein Paket hat, sagt der Dienst (`credit_packs.packs`), den Preis der Store. Wer kaufen darf, sagt
/// der Dienst (`credits.can_buy`); die App fragt nur dieses Feld.
///
/// Wofuer gekaufte Credits gelten, haengt am Tarif (Entscheidung des Inhabers 15.11.2026, `purchased_scope`): mit Pro AI
/// und in der Probe fuer alles, mit Plus nur fuer den KI-Chat (die freie Frage an die KI), mit Free ruhen sie.
public enum CreditPacks {
    /// Der Dienst verbucht ein Paket (`POST`, Rumpf `{signed_transaction}`)
    public static let purchasePath = "/api/billing/credits/apple"

    /// Ein Paket: Produkt im App Store und wie viele Credits es bringt
    public struct Pack: Equatable, Sendable, Identifiable {
        public var productID: String
        public var credits: Int
        public var id: String { productID }

        public init(productID: String, credits: Int) {
            self.productID = productID
            self.credits = credits
        }
    }

    /// Pakete aus dem Vertrag (plans.json `credit_packs.packs`): Rueckfall, bis der Dienst geantwortet hat. Die
    /// Produkt-IDs tragen keine Zahl; die Groesse stellt der Dienst ein.
    public static let defaultPacks = [Pack(productID: "de.uniflow.credits.klein", credits: 100),
                                      Pack(productID: "de.uniflow.credits.gross", credits: 200)]

    /// Apple-Produkte der Pakete (StoreKit laedt genau diese)
    public static var productIDs: [String] { defaultPacks.map(\.productID) }

    /// Ist dieses Apple-Produkt ein Credit-Paket (und kein Abo)?
    public static func isPack(_ productID: String) -> Bool { productIDs.contains(productID) }

    /// Pakete aus `credit_packs` von `GET /api/entitlements`, in der Reihenfolge des Dienstes; nur Produkte, die diese
    /// App kennt. Fehlt das Feld (aelterer Dienst) oder ist es leer, gelten die Pakete aus dem Vertrag.
    public static func packs(from creditPacks: JSONValue?) -> [Pack] {
        let sent = (creditPacks?["packs"]?.array ?? []).compactMap { p -> Pack? in
            guard let id = p["product_id"]?.string, isPack(id), let n = p["credits"]?.double, n >= 1 else { return nil }
            return Pack(productID: id, credits: Int(n))
        }
        return sent.isEmpty ? defaultPacks : sent
    }

    /// Wofuer gekaufte Credits mit dem Tarif des Kontos gelten (`purchased_scope`)
    public enum Scope: String, Sendable, Equatable {
        /// KI-Lernhilfe im Tarif (Pro AI, Probe): fuer alles
        case all
        /// Plus: nur der KI-Chat (die freie Frage, Aufgabe `tutor:ask`)
        case chat
        /// Free: sie ruhen beim Konto
        case none
    }

    /// Aufgaben der StudiNow-KI, die der KI-Chat sind (plans.json `credit_packs.chat_purposes`)
    public static let chatTasks: Set<String> = ["tutor:ask"]

    /// Stand beider Toepfe (`credits` aus `GET /api/entitlements`, aus KI-Antworten und aus der Antwort auf einen Kauf)
    public struct Balance: Equatable, Sendable {
        /// "2026-11"
        public var period: String
        /// Monats-Credits des Tarifs (Pro AI 100, Probe 25, sonst 0)
        public var allowance: Int
        public var used: Int
        /// Rest der Monats-Credits
        public var remaining: Int
        /// gekaufte Credits, noch nicht verbraucht
        public var purchased: Int
        /// gekaufte Credits sind jetzt nutzbar (Pro AI, Probe, Plus); sonst ruhen sie beim Konto
        public var purchasedUsable: Bool
        /// wofuer sie gelten: alles, nur der KI-Chat (Plus) oder nichts
        public var purchasedScope: Scope
        /// das Konto darf Pakete kaufen (Regel des Dienstes)
        public var canBuy: Bool
        /// Beginn des naechsten Monats (ISO mit Versatz, Europe/Berlin): ab dann gibt es neue Monats-Credits
        public var resetsAt: String?
        public var plan: String?

        public init(period: String = "", allowance: Int, used: Int = 0, remaining: Int, purchased: Int = 0, purchasedUsable: Bool = false,
                    purchasedScope: Scope? = nil, canBuy: Bool = false, resetsAt: String? = nil, plan: String? = nil) {
            self.period = period
            self.allowance = allowance
            self.used = used
            self.remaining = remaining
            self.purchased = purchased
            self.purchasedUsable = purchasedUsable
            self.purchasedScope = purchasedScope ?? (purchasedUsable ? .all : .none)
            self.canBuy = canBuy
            self.resetsAt = resetsAt
            self.plan = plan
        }

        /// Was jetzt fuer die KI da ist: Rest des Monats plus nutzbare gekaufte Credits
        public var available: Int { remaining + (purchasedUsable ? purchased : 0) }

        /// `credits` einer Antwort; nil, wenn es fehlt oder null ist (eigener PC, kein Konto). Ein Stand ohne die Felder
        /// des gekauften Topfs (aelterer Dienst) hat 0 gekaufte Credits und darf nicht kaufen.
        public static func parse(_ v: JSONValue?) -> Balance? {
            guard let v, let allowance = v["allowance"]?.double else { return nil }
            let used = Int(v["used"]?.double ?? 0)
            let reserved = Int(v["reserved"]?.double ?? 0)
            let remaining = v["remaining"]?.double.map { Int($0) } ?? max(0, Int(allowance) - used - reserved)
            // `purchased_scope` fehlt bei einem Stand ohne das Feld: dann aus `purchased_usable`; unbekannte Werte ebenso
            return Balance(period: v["period"]?.string ?? "", allowance: max(0, Int(allowance)), used: max(0, used), remaining: max(0, remaining),
                           purchased: max(0, Int(v["purchased"]?.double ?? 0)), purchasedUsable: v["purchased_usable"]?.bool ?? false,
                           purchasedScope: v["purchased_scope"]?.string.flatMap(Scope.init(rawValue:)),
                           canBuy: v["can_buy"]?.bool ?? false, resetsAt: v["resets_at"]?.string, plan: v["plan"]?.string)
        }
    }

    /// Antwort des Dienstes auf einen gemeldeten Kauf
    public struct PurchaseResult: Equatable, Sendable {
        public enum Status: String, Sendable {
            /// jetzt gutgeschrieben
            case granted
            /// war schon verbucht (Wiederholung): nichts doppelt
            case alreadyGranted = "already_granted"
            /// erstattet: nichts gutgeschrieben bzw. der Rest dieses Kaufs abgezogen
            case refunded
            case alreadyRefunded = "already_refunded"
        }

        public var status: Status
        public var creditsAdded: Int
        public var creditsRemoved: Int
        public var productID: String?
        public var transactionID: String?
        /// der Kauf gehoert zu einem anderen StudiNow-Konto und steht dort
        public var otherAccount: Bool
        /// Kauf aus der Testumgebung ueber der Grenze: weniger oder nichts gutgeschrieben
        public var sandboxLimited: Bool
        /// Stand dieses Kontos danach
        public var balance: Balance?

        /// Antwort lesen; nil, wenn der Zustand fehlt oder unbekannt ist (dann schliesst die App den Kauf nicht ab)
        public static func parse(_ v: JSONValue) -> PurchaseResult? {
            guard let status = v["status"]?.string.flatMap(Status.init(rawValue:)) else { return nil }
            return PurchaseResult(status: status, creditsAdded: Int(v["credits_added"]?.double ?? 0), creditsRemoved: Int(v["credits_removed"]?.double ?? 0),
                                  productID: v["product_id"]?.string, transactionID: v["transaction_id"]?.string,
                                  otherAccount: v["other_account"]?.bool ?? false, sandboxLimited: v["sandbox_limited"]?.bool ?? false,
                                  balance: Balance.parse(v["credits"]))
        }
    }

    /// Zeigt die App bei leeren Credits das Blatt mit den Paketen? Nur, wenn das Konto kaufen darf.
    public static func offersShop(_ b: Balance?) -> Bool { b?.canBuy ?? false }
}

/// Texte zu den zwei Toepfen, in einfachem Deutsch und ohne Preis (der Preis kommt immer aus dem Store). Referenz ist
/// app/credit_texts.py; `CreditPacksTests` prueft jede Zeile gegen den Vertrag.
public enum CreditText {
    public static let titleExhausted = "Deine Credits sind aufgebraucht"
    public static let titleShop = "Credits kaufen"
    public static let notNow = "Nicht jetzt"
    public static let keep = "Gekaufte Credits verfallen nicht."
    public static let buyNeedsProAI = "Credits kaufen kannst du mit StudiNow Plus oder Pro AI."
    /// Plus: was gekaufte Credits dort koennen (Blatt mit den Paketen)
    public static let chatOnly = "Mit Credits kannst du Fragen an die KI stellen. Erklärungen, Karteikarten und Tests gibt es mit Pro AI."
    /// Plus: Hinweis an den gesperrten Lernhilfe-Knoepfen der KI-Hilfe
    public static let chatLock = "Mit StudiNow Plus stellst du der KI Fragen. Erklären, Karteikarten und Tests gibt es mit StudiNow Pro AI."
    public static let webHint = "Credits kaufst du in der App für iPhone und iPad."
    public static let noCredits = "Keine Credits in deinem Tarif"

    private static let months = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober",
                                 "November", "Dezember"]

    /// "1. Dezember" aus `resets_at` (ISO, Beginn des naechsten Monats in Berlin); nil ohne lesbares Datum
    public static func resetDay(_ resetsAt: String?) -> String? {
        let s = Array(resetsAt ?? "")
        guard s.count >= 10, s[4] == "-", s[7] == "-", let month = Int(String(s[5..<7])), let day = Int(String(s[8..<10])),
              Int(String(s[0..<4])) != nil, (1...12).contains(month), (1...31).contains(day) else { return nil }
        return "\(day). \(months[month - 1])"
    }

    /// Beschriftung eines Pakets: "100 Credits"
    public static func packLabel(_ credits: Int) -> String { "\(max(0, credits)) Credits" }

    /// Stand beider Toepfe: "Diesen Monat: 37 von 100 · Gekauft: 80". Ohne Monats-Credits im Tarif steht nur der
    /// gekaufte Topf (ruht er, mit dem Weg dahin), ganz ohne Credits "Keine Credits in deinem Tarif"; nil ohne Stand.
    /// `monthNote`: Zusatz zum Monats-Topf in Klammern ("neu am 1. Dezember", in der Probe "Probe, neu am ..."), damit
    /// klar ist, dass nur der Monat neu kommt. `labelled`: mit "Credits" davor, wo die Zeile ohne Ueberschrift steht.
    public static func balanceLine(_ b: CreditPacks.Balance?, monthNote: String? = nil, labelled: Bool = false) -> String? {
        guard let b else { return nil }
        if b.allowance > 0 {
            let note = (monthNote ?? "").isEmpty ? "" : " (\(monthNote ?? ""))"
            return "\(labelled ? "Credits diesen Monat" : "Diesen Monat"): \(b.remaining) von \(b.allowance)\(note) · Gekauft: \(b.purchased)"
        }
        // ohne Monats-Credits nur der gekaufte Topf: bei Plus auch mit 0 ("Gekauft: 0"), ruhend mit dem Weg dahin
        let head = "\(labelled ? "Credits gekauft" : "Gekauft"): \(b.purchased)"
        if b.purchasedScope != .none { return head }
        if b.purchased > 0 { return "\(head) · nutzbar mit StudiNow Plus oder Pro AI" }
        return noCredits
    }

    /// Satz im Blatt: "Gekaufte Credits verfallen nicht. Deine 100 Monats-Credits gibt es am 1. Dezember wieder."
    /// Ohne Monats-Credits oder ohne Datum bleibt nur der erste Satz.
    public static func keepNote(_ b: CreditPacks.Balance?) -> String {
        guard let b, b.allowance > 0, let day = resetDay(b.resetsAt) else { return keep }
        return "\(keep) Deine \(b.allowance) Monats-Credits gibt es am \(day) wieder."
    }

    /// Ehrlicher Hinweis, wenn gekaufte Credits ruhen (Pro AI ist vorbei): sie bleiben beim Konto. nil sonst.
    public static func dormantNote(_ b: CreditPacks.Balance?) -> String? {
        guard let b, !b.purchasedUsable, b.purchased > 0 else { return nil }
        return "Du hast noch \(b.purchased) gekaufte Credits. Sie bleiben bei deinem Konto und sind wieder nutzbar, sobald StudiNow Plus oder Pro AI läuft."
    }

    /// Satz im Blatt mit den Paketen fuer Plus: was gekaufte Credits dort koennen; nil, wenn sie fuer alles gelten
    public static func scopeNote(_ b: CreditPacks.Balance?) -> String? {
        b?.purchasedScope == .chat ? chatOnly : nil
    }

    /// Nach einem Kauf: "100 Credits gutgeschrieben." bzw. was stattdessen geschah
    public static func purchaseNotice(_ r: CreditPacks.PurchaseResult) -> String {
        if r.otherAccount { return "Die Credits stehen bei dem StudiNow-Konto, mit dem du gekauft hast." }
        switch r.status {
        case .granted:
            return r.creditsAdded > 0 ? "\(r.creditsAdded) Credits gutgeschrieben." : "Der Kauf ist verbucht."
        case .alreadyGranted:
            return "Dieser Kauf ist schon gutgeschrieben."
        case .refunded, .alreadyRefunded:
            return "Dieser Kauf wurde erstattet."
        }
    }

    /// Kauf bezahlt, aber der Dienst hat noch nicht geantwortet: nichts geht verloren
    public static let pendingNotice = "Dein Kauf ist bezahlt. Die Credits werden gutgeschrieben, sobald der StudiNow-Dienst erreichbar ist – spätestens beim nächsten Start."
}

public extension StudoraAccount {
    /// Credit-Paket beim Dienst verbuchen (`POST /api/billing/credits/apple`): JWS der Transaktion. Kommt ein Ergebnis
    /// zurueck, hat der Dienst den Kauf verbucht (oder kannte ihn schon) und die App darf `finish()` rufen. Jeder Fehler
    /// (`AccountError`: kein Netz, 503 `apple_not_configured`, 400 ...) und eine unlesbare Antwort heissen: nicht
    /// abschliessen, beim naechsten Start erneut melden.
    func bookCreditPurchase(signedTransaction: String) async throws -> CreditPacks.PurchaseResult {
        let r = try await request("POST", CreditPacks.purchasePath, body: ["signed_transaction": .string(signedTransaction)])
        guard let j = try? JSONValue.parse(r.body), let result = CreditPacks.PurchaseResult.parse(j) else {
            throw AccountError(status: r.status, code: "bad_response", message: "Die Antwort des Dienstes ist unvollständig.", retryAfter: nil)
        }
        return result
    }

    /// Stand beider Toepfe und die Pakete des Dienstes (`GET /api/entitlements`: `credits`, `credit_packs`)
    func creditState() async throws -> (balance: CreditPacks.Balance?, packs: [CreditPacks.Pack]) {
        let r = try await request("GET", "/api/entitlements")
        let j = (try? JSONValue.parse(r.body)) ?? .null
        return (CreditPacks.Balance.parse(j["credits"]), CreditPacks.packs(from: j["credit_packs"]))
    }
}
