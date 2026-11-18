import Foundation
import UniFlowCore

// Geschenkter Tarif des StudiNow-Kontos (Auftrag des Inhabers 18.11.2026, Dienst: Quelle `gift`, app/tarif_schenken.py).
// Der Betrieb schenkt einem Konto Plus oder Pro AI - ohne Abo, ohne Zahlung, unbefristet oder bis zu einem Tag. Die App
// uebernimmt diesen Tarif wie die Probe des Dienstes (`UFPlanPrecedence`: hoechster aus Dienst und Kauf), zeigt ihn als
// Tarif ("StudiNow Pro AI", befristet "… bis 31.12.2027"), nie als Probe und ohne Kauf-Druck. Andere Tarife, die der
// Dienst meldet (Stripe im Web), uebernimmt die App bewusst nicht: das waere eine eigene Entscheidung (App-Store-Regeln).
//
// Ohne Netz (Neustart ohne Verbindung, Dienst nicht erreichbar) gilt der zuletzt bestaetigte Stand weiter
// (`UFGiftMemory`), hoechstens `offlineDays` nach der letzten Antwort des Dienstes und nie ueber das Ende des Geschenks.
// Begruendung: Ein Geschenk schuetzt keine Zahlung; das einzige Risiko ist, dass ein zurueckgenommenes Geschenk auf einem
// Geraet, das den Dienst nie erreicht, noch bis zu 30 Tage gilt. Dagegen soll der Stift in der Vorlesung oder auf Reisen
// ohne WLAN nicht ploetzlich gesperrt sein (Semesterferien, Auslandsreise dauern leicht laenger als die 7 Tage der
// Windows-Kulanz). Die Probe des Dienstes kennt heute keinen Merker: nach einem Neustart ohne Netz gilt dort die Probe
// auf dem iPad bzw. Free, bis der Dienst antwortet. Jede Antwort des Dienstes ersetzt den Merker (auch "kein Geschenk"),
// Abmelden, abgelaufene Sitzung und Konto loeschen vergessen ihn.

/// ein geschenkter Tarif: Plus oder Pro AI, `endsAt` nil = unbefristet
struct UFServiceGift: Equatable {
    let plan: UFPlan
    let endsAt: Date?

    init?(plan: UFPlan?, endsAt: Date?) {
        guard let plan, plan != .free else { return nil }
        self.plan = plan
        self.endsAt = endsAt
    }

    /// Geschenk aus dem Konto-Stand des Dienstes (`PlanStatus.giftPlan`/`giftEndsAt`); nil ohne Geschenk
    init?(status: StudoraAccount.PlanStatus?) {
        self.init(plan: status?.giftPlan.flatMap(UFPlan.init(rawValue:)), endsAt: status?.giftEndsAt)
    }

    func isActive(now: Date = Date()) -> Bool { endsAt.map { $0 > now } ?? true }

    /// "bis 31.12.2027" fuer ein befristetes Geschenk, nil fuer ein unbefristetes
    var untilText: String? {
        endsAt.map { "bis " + $0.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(Locale(identifier: "de_DE"))) }
    }

    /// Beschriftung des Tarifs: "StudiNow Pro AI" bzw. "StudiNow Pro AI bis 31.12.2027" - nie "Probe", nie "läuft ab"
    var label: String { plan.name + (untilText.map { " " + $0 } ?? "") }
}

/// Merker des zuletzt bestaetigten Geschenks je Apple-Nutzer (UserDefaults, wie `DeviceRuleMemory`): nur Tarif, Ende und
/// Zeitpunkt der Bestaetigung, keine Adresse, kein Token
struct UFGiftMemory {
    /// so lange gilt ein bestaetigtes Geschenk ohne Antwort des Dienstes weiter (Begruendung oben)
    static let offlineDays = 30
    /// Uhr des Geraets darf so weit vor der Bestaetigung stehen (Zeitzone, kleine Abweichung); weiter zurueck gestellt:
    /// der Merker gilt nicht (sonst verlaengerte eine zurueckgestellte Uhr das Geschenk)
    static let clockSkew: TimeInterval = 86_400

    var defaults: UserDefaults = .standard

    struct Entry: Codable, Equatable {
        var plan: String
        var endsAt: Date?
        var confirmedAt: Date
    }

    static func key(_ scope: String) -> String { "uniflow.serviceGift." + scope }

    /// Antwort des Dienstes merken: ein Geschenk mit Zeitpunkt, "kein Geschenk" loescht den Merker
    func save(_ gift: UFServiceGift?, scope: String, now: Date = Date()) {
        guard let gift, let data = try? JSONEncoder().encode(Entry(plan: gift.plan.rawValue, endsAt: gift.endsAt, confirmedAt: now)) else {
            defaults.removeObject(forKey: Self.key(scope))
            return
        }
        defaults.set(data, forKey: Self.key(scope))
    }

    func entry(scope: String) -> Entry? {
        guard let data = defaults.data(forKey: Self.key(scope)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    /// gemerktes Geschenk, solange es ohne Dienst gelten darf; sonst nil
    func load(scope: String, now: Date = Date()) -> UFServiceGift? {
        guard let e = entry(scope: scope), Self.usable(e, now: now) else { return nil }
        return UFServiceGift(plan: UFPlan(rawValue: e.plan), endsAt: e.endsAt)
    }

    static func usable(_ e: Entry, now: Date) -> Bool {
        guard now >= e.confirmedAt.addingTimeInterval(-clockSkew),
              now < e.confirmedAt.addingTimeInterval(Double(offlineDays) * 86_400) else { return false }
        return e.endsAt.map { $0 > now } ?? true
    }

    func forget(scope: String) { defaults.removeObject(forKey: Self.key(scope)) }
}
