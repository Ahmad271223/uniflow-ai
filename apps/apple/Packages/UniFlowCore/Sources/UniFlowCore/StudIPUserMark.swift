import CryptoKit
import Foundation

/// Datentrennung je Stud.IP-Benutzer (12.11.2026): Der Datenbereich einer Hochschule gehoert genau einem Stud.IP-Benutzer.
/// Beim ersten erfolgreichen `users/me` merkt sich der Datenbereich einen Hash der Stud.IP-Kennung (nie die Kennung
/// selbst) in `settings` (`key`); meldet sich spaeter ein anderer Benutzer an, haelt der Abgleich an, bevor er etwas
/// schreibt (`StudIPSync`, Dialog "Anderer Stud.IP-Benutzer"). Der Geraete-Abgleich schickt denselben Hash mit
/// (`DeviceSync`, Dienst: 409 `studip_user_mismatch`), damit zwei Geraete mit verschiedenen Stud.IP-Benutzern unter
/// einem StudiNow-Konto sich nicht gegenseitig Module und Stundenplan ueberschreiben. Bestandsdaten ohne Hash
/// uebernehmen beim naechsten Abgleich still den aktuellen Benutzer.
public enum StudIPUserMark {
    /// Schluessel in `settings`; bleibt auf dem Geraet (`DeviceSyncCore.localSettings`, Dienst: `PRIVATE_SETTINGS`)
    public static let key = "studip_user_hash"
    /// 409 des Dienstes, wenn das Konto schon einen anderen Stud.IP-Benutzer abgleicht (app/sync.py)
    public static let mismatchCode = "studip_user_mismatch"

    /// SHA-256 (hex, klein) der Stud.IP-Kennung mit festem Praefix
    public static func hash(userID: String) -> String {
        SHA256.hash(data: Data(("studip-user:" + userID).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func stored(_ c: SQLiteConnection) throws -> String? {
        guard let v = try c.scalar("SELECT value FROM settings WHERE key=?", [.text(key)])?.string, !v.isEmpty else { return nil }
        return v
    }

    public static func store(_ c: SQLiteConnection, _ hash: String) throws {
        try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", [.text(key), .text(hash)])
    }

    public enum Outcome: Equatable, Sendable {
        /// noch kein Benutzer gemerkt (neu oder Bestandsdaten): jetzt gemerkt
        case adopted
        /// derselbe Benutzer wie bisher
        case same
        /// ein anderer Benutzer: nichts schreiben, fragen
        case other
    }

    /// Vergleichen und beim ersten Mal merken (in derselben Transaktion wie der Aufruf)
    public static func check(_ c: SQLiteConnection, userID: String) throws -> Outcome {
        let h = hash(userID: userID)
        guard let old = try stored(c) else {
            try store(c, h)
            return .adopted
        }
        return old == h ? .same : .other
    }
}
