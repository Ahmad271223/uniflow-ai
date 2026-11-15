import Foundation
import UniFlowCore

/// Merker der Geraete-Regel (Auftrag des Inhabers vom 14.11.2026, `DeviceRule`) je Apple-Nutzer auf diesem Geraet:
/// die letzte ausdrueckliche Auskunft des StudiNow-Dienstes, damit der Hinweis-Bildschirm beim naechsten Start sofort
/// da ist, und ob der einmalige Plus-Hinweis schon gezeigt wurde. Nur UserDefaults dieser App: keine Zugangsdaten,
/// nichts geht an iCloud. Uni-Daten bleiben unberuehrt.
struct DeviceRuleMemory {
    var defaults: UserDefaults = .standard

    static func statusKey(_ scope: String) -> String { "uniflow.deviceRule.status." + scope }
    static func plusHintKey(_ scope: String) -> String { "uniflow.deviceRule.plusHintSeen." + scope }

    /// zuletzt gemerkte Auskunft; nil ohne Merker (dann sperrt beim Start nichts)
    func load(scope: String) -> DeviceRule.Status? {
        guard let data = defaults.data(forKey: Self.statusKey(scope)) else { return nil }
        return try? JSONDecoder().decode(DeviceRule.Status.self, from: data)
    }

    /// Auskunft merken. Gemerkt wird nur `blocked` (der Hinweis-Bildschirm soll beim naechsten Start sofort da sein);
    /// alles andere loescht den Merker. Der Plus-Hinweis erscheint nur nach einer frischen Antwort des Dienstes.
    func save(_ status: DeviceRule.Status?, scope: String) {
        guard let status, status.state == .blocked, let data = try? JSONEncoder().encode(status) else {
            defaults.removeObject(forKey: Self.statusKey(scope))
            return
        }
        defaults.set(data, forKey: Self.statusKey(scope))
    }

    func plusHintSeen(scope: String) -> Bool { defaults.bool(forKey: Self.plusHintKey(scope)) }

    func markPlusHintSeen(scope: String) { defaults.set(true, forKey: Self.plusHintKey(scope)) }

    /// alles zu diesem Apple-Nutzer vergessen (Konto geloescht)
    func forget(scope: String) {
        defaults.removeObject(forKey: Self.statusKey(scope))
        defaults.removeObject(forKey: Self.plusHintKey(scope))
    }
}
