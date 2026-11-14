import CryptoKit
import Foundation

/// Raum je Uni-Konto im Geraete-Abgleich (14.11.2026, docs/ABGLEICH-UNI-KONTO-2026-11-14.md; Dienst: `sync.Rooms`).
///
/// Befund am echten iPhone: zwei Geraete mit demselben StudiNow-Konto (gleiche Apple-ID), aber verschiedenen
/// Uni-Zugaengen haben einander Faecher und Stundenplan geschickt. Seitdem meldet das Geraet dem Dienst bei jedem
/// Abruf und jeder Sendung einen Schluessel fuer sein Uni-Konto, und der Dienst teilt nur zwischen Geraeten mit
/// demselben Schluessel.
///
/// Der Schluessel ist ein SHA-256 ueber StudiNow-Konto, Hochschule und die Kennung des Uni-Kontos. Als Kennung dient,
/// was der Datenbereich schon hat: der Hash der Stud.IP-Nutzer-ID (`StudIPUserMark`, LUH). An den Dienst gehen nur
/// Hashes, nie die Kennung, kein Name, keine Matrikelnummer.
///
/// Hochschulen ohne sichere Kennung (Hildesheim: die Learnweb-Nutzer-ID gilt nur fuer die Instanz eines Semesters;
/// HsH: nur aus der Seite gelesen) haben keinen Schluessel. Dort gleicht die App nicht zwischen Geraeten ab
/// (`DeviceSync`, `requireUniAccount`): lieber nicht teilen als mischen.
public enum UniAccountKey {
    /// Faehigkeit in `X-StudiNow-Caps`: diese App kennt die Raeume (`foreign`, `other_room`)
    public static let capability = "uni_room"
    /// Zuletzt gemeldeter Schluessel in `sync_link_state`; aendert er sich, ruft der Abgleich einmal alles neu ab
    static let stateKey = "uni_key"

    /// SHA-256 (hex, klein); gleich in `app/sync_client.py::uni_key` (Windows)
    public static func key(account: String, university: String, identity: String) -> String {
        SHA256.hash(data: Data("studinow-uni-konto|\(account)|\(university)|\(identity)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Kennung des Uni-Kontos in diesem Datenbereich (schon ein Hash); nil vor der ersten Uni-Anmeldung und bei
    /// Hochschulen ohne sichere Kennung
    public static func identity(_ c: SQLiteConnection) throws -> String? {
        try StudIPUserMark.stored(c)
    }

    /// Hochschule des Datenbereichs (`settings.university`)
    static func university(_ c: SQLiteConnection) throws -> String {
        try c.scalar("SELECT value FROM settings WHERE key='university'")?.string ?? Migrations.defaultUniversity
    }

    /// Schluessel dieses Datenbereichs fuer `account`; nil ohne Kennung
    public static func current(_ c: SQLiteConnection, account: String, university: String? = nil) throws -> String? {
        guard !account.isEmpty, let id = try identity(c) else { return nil }
        return key(account: account, university: try university ?? Self.university(c), identity: id)
    }

    // MARK: Texte (Einstellungen → Konto)

    /// Ein zweites Uni-Konto haengt am selben StudiNow-Konto
    public static let otherAccountText = "Unter deinem StudiNow-Konto ist auf einem anderen Gerät ein anderes Uni-Konto verbunden. Fächer und Pläne werden nur zwischen Geräten mit demselben Uni-Konto geteilt."
    /// Noch keine Uni-Anmeldung auf diesem Geraet
    public static let signInFirstText = "Fächer und Pläne werden mit deinen anderen Geräten geteilt, sobald du dich hier bei deiner Hochschule angemeldet hast."
    /// Hochschule ohne sichere Kennung
    public static let notAvailableText = "Für deine Hochschule kann StudiNow noch nicht sicher erkennen, ob deine Geräte zum selben Uni-Konto gehören. Fächer und Pläne bleiben deshalb auf diesem Gerät."

    /// Hochschulen, bei denen die Uni-Anmeldung eine sichere Kennung liefert: die mit Stud.IP (`users/me`)
    public static func available(university: String?) -> Bool {
        UniversityProfile.profile(forKey: university ?? Migrations.defaultUniversity)?.studipBase != nil
    }

    /// Darf ein Geraet ohne Schluessel trotzdem abgleichen (wie vor dem 14.11.2026, alles mit allen Geraeten des
    /// Kontos)? Nein, fuer keine Hochschule: lieber nicht teilen als mischen. Die eine Stelle fuer diese Entscheidung
    /// des Inhabers (z. B. Hildesheim vorerst "wie bisher"); der Dienst behandelt solche Geraete wie aeltere Apps.
    public static func syncWithoutKey(university: String?) -> Bool { false }

    /// Hinweis fuer die Konto-Einstellungen aus dem letzten Abgleich; nil, wenn nichts zu sagen ist
    public static func hint(_ r: DeviceSyncResult?, university: String?) -> String? {
        guard let r else { return nil }
        if r.noUniAccount { return available(university: university) ? signInFirstText : notAvailableText }
        return r.otherUniAccount ? otherAccountText : nil
    }
}
