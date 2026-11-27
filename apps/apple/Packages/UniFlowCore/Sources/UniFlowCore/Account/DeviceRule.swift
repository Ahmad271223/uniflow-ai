import Foundation

/// Geraete-Regel fuer StudiNow-Konten (Auftrag des Inhabers vom 14.11.2026; Dienst: app/device_limit.py, Vertrag
/// `packages/shared-contracts/fixtures/device-limit/contract.json`).
///
/// 1. Free: ein Konto gilt fuer EIN Geraet. Auf einem zweiten Geraet (iPhone, iPad, Mac) zeigt die App statt der
///    Oberflaeche einen Hinweis-Bildschirm (`blocked`).
/// 2. Plus: laeuft auf jedem Geraet, aber ohne Abgleich. Auf dem zweiten Geraet einmal ein Hinweis (`hintPlus`). Plus
///    wird nie gesperrt (App-Review-Richtlinie 3.1.2: ein gekauftes Abo gilt auf allen Geraeten derselben Apple-ID).
/// 3. Pro AI und die laufende Probe: keine Einschraenkung.
///
/// Seit 26.11.2026 (neues Tarifmodell, app/plans.py) hat Plus den Notizen-Abgleich (`can_sync_annotations` ab Plus):
/// der Dienst meldet Plus dann `ok` (app/device_limit.py `evaluate`), und die App zeigt mit Plus nichts mehr. Der Hinweis
/// fuer Free nennt Plus (der kleinste Tarif mit Abgleich).
///
/// Die App meldet dem Dienst die Faehigkeit `device_limit` in der Kopfzeile `X-StudiNow-Caps`; nur dann schickt der
/// Dienst die Auskunft `device`. Gesperrt wird nur nach einer ausdruecklichen Antwort des Dienstes, nie ohne Netz und
/// nie bei einer unbekannten Antwort.
public enum DeviceRule {
    /// Kopfzeile, mit der die App ihre Faehigkeiten meldet (`device_limit.CAPS_HEADER`)
    public static let capabilityHeader = "X-StudiNow-Caps"
    /// Faehigkeit "kennt die Geraete-Regel" (`device_limit.CAP`)
    public static let capability = "device_limit"

    /// Zustand dieses Geraets (`device.state`)
    public enum State: String, Codable, Sendable, Equatable {
        case ok
        case blocked
        case hintPlus = "hint_plus"
    }

    /// Auskunft des Dienstes zu diesem Geraet (`device` in `GET /api/entitlements`, in der Anmelde-Antwort und in der
    /// Antwort von `POST /api/account/device/primary`)
    public struct Status: Codable, Sendable, Equatable {
        public var state: State
        /// dieses Geraet ist das eine Geraet des Kontos
        public var isPrimary: Bool
        /// Name des einen Geraets ("iPad", "iPhone", "Mac"); nil, wenn der Dienst keinen kennt
        public var primaryName: String?
        /// Listenpreis des genannten Tarifs in Cent je `period` (seit 26.11.2026 Plus, 199 je Monat; nur Rueckfall, wenn
        /// StoreKit keinen Preis liefert)
        public var priceCents: Int?
        public var currency: String?
        public var period: String?

        public init(state: State, isPrimary: Bool = false, primaryName: String? = nil, priceCents: Int? = nil,
                    currency: String? = nil, period: String? = nil) {
            self.state = state
            self.isPrimary = isPrimary
            self.primaryName = primaryName
            self.priceCents = priceCents
            self.currency = currency
            self.period = period
        }

        /// `device` aus einer Antwort des Dienstes. nil, wenn das Feld fehlt (aelterer Dienst) oder kein Objekt ist.
        /// Ein unbekannter Zustand gilt als `ok`: die App sperrt nie wegen einer Antwort, die sie nicht versteht.
        public static func parse(_ v: JSONValue?) -> Status? {
            guard let v, v.object != nil else { return nil }
            let state = v["state"]?.string.flatMap(State.init(rawValue:)) ?? .ok
            let name = v["primary_name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Status(state: state, isPrimary: v["is_primary"]?.bool ?? false, primaryName: (name?.isEmpty ?? true) ? nil : name,
                          priceCents: v["price_cents"]?.double.map { Int($0) }, currency: v["currency"]?.string, period: v["period"]?.string)
        }
    }

    /// Was das Geraet zeigt: Auskunft des Dienstes und der Tarif auf dem Geraet (Kauf im App Store, laufende Probe;
    /// Schluessel wie in plans.json: free, plus, pro_ai). Ein Kauf auf dem Geraet geht vor: mit einem Tarif mit Abgleich
    /// (seit 26.11.2026 Plus und Pro AI) nie ein Hinweis (er verschwindet sofort nach dem Kauf, auch bevor der Dienst ihn
    /// kennt). Ohne Auskunft: `ok`. Wie `device_limit.shown_state` (Vertrag `client_cases`).
    public static func shown(server: State?, localPlan: String) -> State {
        guard let server else { return .ok }
        switch localPlan {
        case "plus", "pro_ai", "pro_connect": return .ok
        default: return server
        }
    }
}

/// Texte der Geraete-Regel (einfaches Deutsch, Auftrag des Inhabers vom 14.11.2026). Der Preis kommt aus StoreKit
/// (`Product.displayPrice`); `fallbackPrice` nur, wenn der Store keinen liefert.
public enum DeviceRuleTexts {
    // Hinweis-Bildschirm (Free auf einem zweiten Geraet)
    public static let blockedTitle = "StudiNow Free gilt für ein Gerät"
    public static let showPlans = "Plus ansehen"
    public static let useThisDevice = "Dieses Gerät stattdessen nutzen"
    public static let signOut = "Abmelden"
    public static let dataStays = "Deine Daten auf diesem Gerät bleiben erhalten."

    /// Rueckfrage vor dem Wechsel
    public static let confirmTitle = "Dieses Gerät stattdessen nutzen?"
    public static let confirmButton = "Dieses Gerät nutzen"
    public static let cancel = "Abbrechen"
    public static let switchFailed = "Das hat gerade nicht geklappt. Prüfe die Internetverbindung und versuche es noch einmal."

    // einmaliger Hinweis (Plus auf einem zweiten Geraet)
    public static let plusTitle = "Plus läuft auf jedem Gerät für sich"
    public static let plusClose = "Verstanden"

    /// "iPhone und iPad" bzw. am Mac "iPhone, iPad und Mac"
    public static func devices(mac: Bool) -> String { mac ? "iPhone, iPad und Mac" : "iPhone und iPad" }

    /// "39,99 € im Jahr" mit dem Preis aus StoreKit
    public static func yearly(_ price: String) -> String { "\(price) im Jahr" }

    /// "1,99 € im Monat" bzw. "39,99 € im Jahr" (`period` wie in plans.json: month, year; sonst Monat)
    public static func perPeriod(_ price: String, period: String?) -> String {
        period == "year" ? yearly(price) : "\(price) im Monat"
    }

    /// Rueckfall ohne Preis aus dem Store: Listenpreis des Dienstes, sonst der Preis von Plus aus plans.json (1,99 €)
    public static func fallbackPrice(cents: Int? = nil, currency: String? = nil) -> String {
        let c = (cents ?? 0) > 0 ? cents! : 199
        let amount = "\(c / 100),\(String(format: "%02d", c % 100))"
        let cur = (currency ?? "EUR").uppercased()
        return cur == "EUR" ? "\(amount) €" : "\(amount) \(cur)"
    }

    /// erster Satz des Hinweis-Bildschirms: wo das Konto schon laeuft
    public static func blockedWhere(primaryName: String?) -> String {
        guard let n = primaryName, !n.isEmpty else { return "Dein Konto läuft schon auf einem anderen Gerät." }
        return "Dein Konto läuft schon auf einem anderen Gerät (\(n))."
    }

    /// zweiter Satz: das Angebot (seit 26.11.2026 Plus). `price`: "1,99 €", `period` wie in plans.json
    public static func blockedOffer(price: String, mac: Bool = false, period: String? = "month") -> String {
        "Mit Plus nutzt du StudiNow auf \(devices(mac: mac)) – mit Abgleich. Ab \(perPeriod(price, period: period))."
    }

    /// ganzer Text fuer VoiceOver und Tests
    public static func blockedText(primaryName: String?, price: String, mac: Bool = false, period: String? = "month") -> String {
        "\(blockedWhere(primaryName: primaryName)) \(blockedOffer(price: price, mac: mac, period: period))"
    }

    public static func confirmText(primaryName: String?) -> String {
        let other = (primaryName?.isEmpty ?? true) ? "Auf dem anderen Gerät" : "Auf dem anderen Gerät (\(primaryName!))"
        return "StudiNow Free läuft dann auf diesem Gerät. \(other) erscheint beim nächsten Öffnen dieser Hinweis. Deine Daten bleiben auf beiden Geräten erhalten."
    }

    /// Nur noch fuer einen Dienst vor dem 26.11.2026, der Plus `hint_plus` meldet (seit dann hat Plus den Abgleich und
    /// die App zeigt den Hinweis mit Plus nicht mehr, `shown`). Der Text nennt darum keinen hoeheren Tarif.
    public static func plusText(price: String, mac: Bool = false) -> String {
        "Mit Plus gleicht StudiNow deine Notizen zwischen \(devices(mac: mac)) ab."
    }
}
