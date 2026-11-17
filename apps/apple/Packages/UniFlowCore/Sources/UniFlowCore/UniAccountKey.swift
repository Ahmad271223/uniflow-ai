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
/// Regel je Hochschule (Entscheidung des Inhabers vom 14.11.2026):
/// - Hochschule mit sicherer Kennung (LUH, Stud.IP): Abgleich nur mit dem Schluessel des Uni-Kontos. Vor dem ersten
///   Stud.IP-Abgleich gibt es ihn nicht, dann gleicht die App nicht zwischen Geraeten ab (`requireUniAccount`).
/// - Hochschule ohne sichere Kennung (Hildesheim: die Learnweb-Nutzer-ID gilt nur fuer die Instanz eines Semesters;
///   HsH: nur aus der Seite gelesen): der Abgleich laeuft wie in 1.0.4 weiter, auch fuer Notizen. Die App schickt
///   einen Schluessel nur aus StudiNow-Konto und Hochschule (`universityOnly`); alle Geraete dieser Hochschule
///   teilen damit einen Raum, und der Dienst behandelt ihn wie bisher (`sync.Rooms`, `plain`). Ein LUH-Geraet und
///   ein Hildesheim-Geraet unter demselben StudiNow-Konto bleiben so sicher getrennt. Verbleibende Luecke: zwei
///   verschiedene Hildesheimer Uni-Konten unter einem StudiNow-Konto teilen weiter (wie in 1.0.4).
public enum UniAccountKey {
    /// Faehigkeit in `X-StudiNow-Caps`: diese App kennt die Raeume (`foreign`, `other_room`)
    public static let capability = "uni_room"
    /// Zuletzt gemeldeter Schluessel in `sync_link_state`; aendert er sich, ruft der Abgleich einmal alles neu ab
    static let stateKey = "uni_key"
    /// Platzhalter statt einer Kennung: Schluessel nur aus StudiNow-Konto und Hochschule (`sync.UNIVERSITY_ONLY`)
    public static let universityOnly = "ohne-kennung"

    /// SHA-256 (hex, klein); gleich in `app/sync_client.py::uni_key` (Windows). Ueber `SolutionSHA256` statt CryptoKit,
    /// damit der Kern auch unter Linux baut (GitHub-Lauf "Apple"); `LinuxHashTests` haelt den Wert fest.
    public static func key(account: String, university: String, identity: String) -> String {
        SolutionSHA256.hex(Data("studinow-uni-konto|\(account)|\(university)|\(identity)".utf8))
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

    /// Schluessel dieses Datenbereichs fuer `account`. Mit Kennung der des Uni-Kontos; ohne Kennung an einer Hochschule,
    /// die keine sichere liefert, der Schluessel nur aus Konto und Hochschule; sonst nil (LUH vor dem ersten
    /// Stud.IP-Abgleich: noch kein Abgleich zwischen Geraeten)
    public static func current(_ c: SQLiteConnection, account: String, university: String? = nil) throws -> String? {
        guard !account.isEmpty else { return nil }
        let uni = try university ?? Self.university(c)
        if let id = try identity(c) { return key(account: account, university: uni, identity: id) }
        return available(university: uni) ? nil : key(account: account, university: uni, identity: universityOnly)
    }

    // MARK: Texte (Einstellungen → Konto)

    /// Ein zweites Uni-Konto haengt am selben StudiNow-Konto
    public static let otherAccountText = "Unter deinem StudiNow-Konto ist auf einem anderen Gerät ein anderes Uni-Konto verbunden. Fächer und Pläne werden nur zwischen Geräten mit demselben Uni-Konto geteilt."
    /// Noch keine Uni-Anmeldung auf diesem Geraet (nur Hochschulen mit sicherer Kennung)
    public static let signInFirstText = "Fächer und Pläne werden mit deinen anderen Geräten geteilt, sobald du dich hier bei deiner Hochschule angemeldet hast."

    /// Hochschulen, bei denen die Uni-Anmeldung eine sichere Kennung liefert: die mit Stud.IP (`users/me`)
    public static func available(university: String?) -> Bool {
        UniversityProfile.profile(forKey: university ?? Migrations.defaultUniversity)?.studipBase != nil
    }

    /// Hinweis fuer die Konto-Einstellungen aus dem letzten Abgleich; nil, wenn nichts zu sagen ist. An Hochschulen
    /// ohne sichere Kennung gibt es keinen Hinweis: dort laeuft der Abgleich wie bisher.
    public static func hint(_ r: DeviceSyncResult?, university: String?) -> String? {
        guard let r, available(university: university) else { return nil }
        if r.noUniAccount { return signInFirstText }
        return r.otherUniAccount ? otherAccountText : nil
    }
}
