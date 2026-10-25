import Foundation

/// Moodle-Anmeldung fuer Apps (`learnweb.launch_url`, `learnweb.parse_launch_token`).
///
/// Ablauf in der App: `launchURL` im WKWebView oeffnen (Datenspeicher der Hochschule), dort meldet sich der Nutzer
/// beim CAS an. Danach leitet Moodle auf `<scheme>://token=<base64>` weiter; die Webansicht faengt diese Adresse in
/// `decidePolicyFor navigationAction` ab (nicht an das System weitergeben) und gibt sie an `parseLaunchToken`.
/// Der Schluessel gilt fuer den REST-Weg: Dateien ohne Browser, Moodle verbucht keine Aufrufe.
public enum MoodleSSO {
    public struct Token: Sendable, Equatable {
        public let token: String
        public let privateToken: String?
    }

    public static func launchURL(base: String, passport: String, scheme: String = "moodlemobile") -> String {
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        return "\(b)/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=\(HText.quoteAll(passport))&urlscheme=\(HText.quoteAll(scheme))"
    }

    /// Zufaelliger Passport fuer einen Anmeldevorgang (merken, bis die Weiterleitung kommt)
    public static func newPassport() -> String {
        String((0..<24).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    private static let tokenRE = HText.regex("token=([A-Za-z0-9+/=_-]+)")

    /// Prueft die Signatur md5(wwwroot + passport); bei fremder Adresse oder fremdem Passport nil.
    public static func parseLaunchToken(_ redirectURL: String, base: String, passport: String) -> Token? {
        guard let raw0 = HText.match(tokenRE, redirectURL)?.groups[1] ?? nil else { return nil }
        var raw = raw0.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while raw.count % 4 != 0 { raw += "=" }
        guard let data = Data(base64Encoded: raw), let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: ":::")
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        guard parts[0] == MD5.hex(b + passport) else { return nil }
        return Token(token: parts[1], privateToken: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil)
    }
}

/// Einordnung wie in Python (`studip_sync.classify`, `studip_sync.file_kind`, `timetable.guess_kind`).
public enum UniRules {
    private static let gruppenRE = HText.regex("Gruppenübung|Gruppenuebung", [.caseInsensitive])
    private static let hoersaalRE = HText.regex("Hörsaalübung|Hoersaaluebung|Zentralübung", [.caseInsensitive])
    private static let uebungRE = HText.regex("\\b(Übung|Uebung|Fragestunde)", [.caseInsensitive])
    private static let tutoriumRE = HText.regex("Tutorium", [.caseInsensitive])
    private static let sonstigesRE = HText.regex("Begrüßung|Studiengänge|Einführungsveranstaltung|Erstsemester", [.caseInsensitive])
    private static let subjectSteps: [(NSRegularExpression, String)] = [
        (HText.regex("^\\d+\\s+"), ""),
        (HText.regex("^(Gruppenübung|Übung|Uebung|Tutorium)\\s*(zu|zur|:)?\\s*", [.caseInsensitive]), ""),
        (HText.regex("\\s*[-–]\\s*(Fragestunden|Tutorium).*$", [.caseInsensitive]), ""),
        (HText.regex("\\s*\\((Tranche[^)]*|für [^)]*|Elektrotechnische Grundlagen der Informationstechnik)\\)", [.caseInsensitive]), ""),
        (HText.regex(",?\\s*Tranche\\s*\\w+.*$", [.caseInsensitive]), ""),
    ]

    /// (Fach, Art) aus dem Kurstitel
    public static func classify(_ title: String) -> (subject: String, kind: String) {
        var kind = "vorlesung"
        if HText.match(gruppenRE, title) != nil { kind = "gruppenuebung" }
        else if HText.match(hoersaalRE, title) != nil { kind = "hoersaaluebung" }
        else if HText.match(uebungRE, title) != nil { kind = "uebung" }
        else if HText.match(tutoriumRE, title) != nil { kind = "tutorium" }
        if HText.match(sonstigesRE, title) != nil { kind = "sonstiges" }
        var s = title
        for (re, rep) in subjectSteps { s = HText.replace(re, in: s, with: rep) }
        s = HText.strip(HText.replace(HText.whitespace, in: s, with: " "), " -:,(")
        return (s, kind)
    }

    /// pdf | image | file (nur echte PDFs gehen in den Editor)
    public static func fileKind(name: String, mime: String?) -> String {
        let n = name.lowercased(), m = (mime ?? "").lowercased()
        if n.hasSuffix(".pdf") || m == "application/pdf" { return "pdf" }
        if [".png", ".jpg", ".jpeg", ".gif", ".webp"].contains(where: { n.hasSuffix($0) }) || m.hasPrefix("image/") { return "image" }
        return "file"
    }

    private static let kindWords: [(String, [String])] = [
        ("uebung", ["übung", "uebung", "ü:", "exercise", "tutorium", "gruppenübung", "zentralübung"]),
        ("labor", ["labor", "praktikum", "lab"]), ("seminar", ["seminar"]),
    ]

    /// Art eines Termins im Stundenplan
    public static func eventKind(_ title: String) -> String {
        let t = title.lowercased()
        return kindWords.first { $0.1.contains { t.contains($0) } }?.0 ?? "vorlesung"
    }
}

/// Getrennte Ablage je (Apple-Nutzer, Hochschule): Datenbank, Dateien, Schluesselbund, Cookies.
/// Nie zwischen Hochschulen teilen; kein Rueckfall auf Zugaenge einer anderen Hochschule.
public enum UniversityStorage {
    public static let known = ["luh", "hildesheim"]

    /// Nur bekannte Schluessel (kein Pfad aus Eingaben)
    public static func validUniversity(_ key: String) -> String? { known.contains(key) ? key : nil }

    /// Ordner relativ zum App-Datenordner: users/<16 Hexzeichen aus SHA-256 der Apple-ID>/<uni>
    public static func containerPath(appleUserID: String, university: String) -> String? {
        guard let uni = validUniversity(university), !appleUserID.isEmpty else { return nil }
        return "users/\(HText.sha256Hex("uniflow-user:" + appleUserID).prefix(16))/\(uni)"
    }

    /// Schluesselbund-Dienst je Hochschule und Zweck, z. B. "de.uniflow.ai.hildesheim.learnweb-token"
    public static func keychainService(university: String, purpose: String) -> String? {
        guard let uni = validUniversity(university) else { return nil }
        let p = purpose.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return p.isEmpty ? nil : "de.uniflow.ai.\(uni).\(p)"
    }

    /// Feste Kennung fuer `WKWebsiteDataStore(forIdentifier:)` je (Nutzer, Hochschule): eigene Cookies je Uni
    public static func websiteDataStoreID(appleUserID: String, university: String) -> UUID? {
        guard let uni = validUniversity(university), !appleUserID.isEmpty else { return nil }
        var b = SolutionSHA256.hash(Data("uniflow-web:\(appleUserID):\(uni)".utf8))
        b[6] = (b[6] & 0x0F) | 0x50           // Version 5 (namensbasiert)
        b[8] = (b[8] & 0x3F) | 0x80           // Variante RFC 4122
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
