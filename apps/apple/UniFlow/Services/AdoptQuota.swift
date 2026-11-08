import Foundation
import UniFlowCore

/// iCloud-Schluessel-Wert-Speicher des Apple-Kontos (NSUbiquitousKeyValueStore), fuer Tests austauschbar
protocol UFAdoptCloudStore: AnyObject {
    func array(forKey key: String) -> [Any]?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    var dictionaryRepresentation: [String: Any] { get }
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UFAdoptCloudStore {}

/// Zaehlung im StudiNow-Dienst (angemeldetes Konto, `StudoraAccount`)
protocol UFAdoptQuotaService: Sendable {
    func adoptQuotaStatus() async throws -> StudoraAccount.AdoptQuota
    func countAdoptedStack(ref: String) async throws -> StudoraAccount.AdoptQuota
}

extension StudoraAccount: UFAdoptQuotaService {}

/// Karteikarten-Stapel von StudiNow uebernehmen (Entscheidung 05.11.2026, Kontingent `card_stacks_adopted` in
/// plans.json): fertige Wochenstapel aus dem Pool und geteilte Stapel der Modul-Community, Plus 4 je Kalendermonat, Pro AI
/// (und die Probe) unbegrenzt. Derselbe Stapel zaehlt im Monat nur einmal; selbst erzeugte Stapel (eigenes ChatGPT)
/// zaehlen nicht.
///
/// Je Konto statt je Geraet (Entscheidung des Inhabers 08.11.2026, Audit P43-06):
/// - mit StudiNow-Konto (`service`) zaehlt der Dienst im vorhandenen Kontingent des Kontos, ueber alle Geraete und
///   Windows/Web; er gilt, wenn er dieselbe Grenze kennt wie der Tarif auf dem iPad (sonst kennt er den Kauf nicht);
/// - immer zusaetzlich das Apple-Konto: iCloud-Schluessel-Wert-Speicher, je Geraet ein eigener Schluessel je Monat (kein
///   Ueberschreiben zwischen Geraeten), gelesen wird die Vereinigung;
/// - und die lokale Sicherung in den UserDefaults dieses Geraets (gleicher Schluessel wie bisher). Ist iCloud nicht
///   erreichbar, zaehlt sie allein: nie mehr als je Geraet bisher.
/// Erlaubt ist ein Stapel nur, wenn Apple-Konto/Geraet ihn erlauben UND (falls er gilt) der Dienst.
/// Monat: Kalendermonat in Europe/Berlin (wie die Credits und der Dienst), nicht der Kalender des Geraets.
struct UFAdoptQuota {
    static let feature = "card_stacks_adopted"
    static let label = "Karteikarten-Stapel von StudiNow"

    var defaults: UserDefaults = .standard
    var now: () -> Date = Date.init
    /// Apple-Konto; nil = ohne iCloud (nur dieses Geraet)
    var cloud: (any UFAdoptCloudStore)? = NSUbiquitousKeyValueStore.default
    /// StudiNow-Dienst des angemeldeten Kontos; nil ohne Anmeldung
    var service: (any UFAdoptQuotaService)?

    /// Grenze je Monat; nil = unbegrenzt (Pro AI, Fair Use nur im Dienst)
    static func limit(_ plan: UFPlan) -> Int? {
        switch plan {
        case .free: return 0
        case .plus: return 4
        case .proAI: return nil
        }
    }

    static func exhaustedMessage(limit: Int) -> String {
        "\(label): Kontingent für diesen Monat aufgebraucht (\(limit) von \(limit))."
    }

    /// Monat "YYYY-MM" in Europe/Berlin
    static func period(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    private var period: String { Self.period(now()) }

    /// Schluessel in den UserDefaults (Format wie vor dem 08.11.2026, die Zaehlung des laufenden Monats bleibt)
    private var key: String { "uf.quota.\(Self.feature).\(period)" }

    /// Schluessel im Apple-Konto: `uf.adopt.<Monat>.<Geraet>` (hoechstens 64 Byte)
    private static let cloudPrefix = "uf.adopt."
    private var cloudKey: String { Self.cloudPrefix + period + "." + deviceToken }

    /// zufaellige Kennung dieses Geraets (nur fuer den eigenen Schluessel im Apple-Konto)
    private var deviceToken: String {
        let k = "uf.quota.\(Self.feature).device"
        if let t = defaults.string(forKey: k), !t.isEmpty { return t }
        let t = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        defaults.set(t, forKey: k)
        return t
    }

    /// in diesem Monat schon gezaehlte Stapel: dieses Geraet und alle Geraete des Apple-Kontos
    var used: [String] {
        var out = defaults.stringArray(forKey: key) ?? []
        if let cloud {
            let prefix = Self.cloudPrefix + period + "."
            for k in cloud.dictionaryRepresentation.keys.sorted() where k.hasPrefix(prefix) {
                for id in (cloud.array(forKey: k) as? [String]) ?? [] where !out.contains(id) { out.append(id) }
            }
        }
        return out
    }

    /// Darf dieser Stapel im Tarif noch uebernommen werden? (Apple-Konto und Geraet; schon gezaehlt = ja)
    func allows(_ id: String, plan: UFPlan) -> Bool {
        guard let limit = Self.limit(plan) else { return true }
        let ids = used
        return ids.contains(id) || ids.count < limit
    }

    /// Antwort des Dienstes, wenn sie fuer diesen Tarif gilt (gleiche Grenze); sonst nil (nicht angemeldet, nicht
    /// erreichbar, Kauf dort unbekannt)
    private func valid(_ answer: StudoraAccount.AdoptQuota?, limit: Int) -> StudoraAccount.AdoptQuota? {
        guard let answer, answer.limit == limit else { return nil }
        return answer
    }

    /// Vor dem Uebernehmen eines geteilten Stapels: erlaubt? Mit Konto zaehlt der Dienst dabei schon (einmal je Stapel
    /// und Monat; scheitert danach das Uebernehmen, zaehlt ein neuer Versuch nicht erneut)
    func reserve(_ id: String, plan: UFPlan) async -> Bool {
        guard let limit = Self.limit(plan) else { return true }
        guard allows(id, plan: plan) else { return false }
        guard let service, let answer = valid(try? await service.countAdoptedStack(ref: id), limit: limit) else { return true }
        return answer.ok
    }

    /// Vor "Karten fuer Woche n holen" (ob uebernommen oder selbst erzeugt wird, zeigt erst die Antwort): erlaubt?
    /// Zaehlt nichts; mit Konto nach dem Stand des Kontos
    func check(_ id: String, plan: UFPlan) async -> Bool {
        guard let limit = Self.limit(plan) else { return true }
        guard allows(id, plan: plan) else { return false }
        if used.contains(id) { return true }
        guard let service, let status = valid(try? await service.adoptQuotaStatus(), limit: limit) else { return true }
        return status.used < limit
    }

    /// Wochenstapel aus dem Pool uebernommen: zaehlen (Apple-Konto, Geraet und mit Konto im Dienst)
    func recordAdopted(_ id: String) async {
        record(id)
        if let service { _ = try? await service.countAdoptedStack(ref: id) }
    }

    /// Fehler fuer die Meldung, wenn `allows` bzw. `reserve` nein sagt
    func error(plan: UFPlan) -> APIError {
        var e = APIError(status: 429, message: "", text: Self.exhaustedMessage(limit: Self.limit(plan) ?? 0))
        e.code = "quota_exhausted"
        return e
    }

    /// Uebernahme zaehlen (einmal je Stapel und Monat) auf dem Geraet und im Apple-Konto; alte Monate verlassen das
    /// Apple-Konto dabei
    func record(_ id: String) {
        var ids = defaults.stringArray(forKey: key) ?? []
        if !ids.contains(id) {
            ids.append(id)
            defaults.set(ids, forKey: key)
        }
        guard let cloud else { return }
        let own = cloudKey
        var mine = (cloud.array(forKey: own) as? [String]) ?? []
        if !mine.contains(id) {
            mine.append(id)
            cloud.set(mine, forKey: own)
        }
        let current = Self.cloudPrefix + period + "."
        for k in cloud.dictionaryRepresentation.keys where k.hasPrefix(Self.cloudPrefix) && !k.hasPrefix(current) {
            cloud.removeObject(forKey: k)
        }
        cloud.synchronize()
    }
}
