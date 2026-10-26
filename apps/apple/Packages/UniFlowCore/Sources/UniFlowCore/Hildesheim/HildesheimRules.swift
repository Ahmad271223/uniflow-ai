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

/// Einordnung wie in Python (`studip_sync.classify`, `studip_sync.file_kind`, `timetable.guess_kind`). Eine Fassung
/// fuer alle Quellen (Stud.IP, Learnweb, LSF, Stundenplan, Module): `UniStore.upsertCourse` setzt damit Fach und Art,
/// `StudIPSchedule` die Art eines Termins, die Module (`LocalModules`) fassen Kurse eines Fachs zusammen.
/// `PyRegex` gibt den Mustern dieselbe Bedeutung wie Pythons `re` (z. B. "ß" passt mit re.I auf "ẞ", nie auf "ss").
/// Gegen Python geprueft mit fixtures/hildesheim/expected.json und fixtures/local-backend/study-modules.json.
public enum UniRules {
    private static let kindGroup = PyRegex("Gruppenübung|Gruppenuebung", ignoreCase: true)
    private static let kindLectureHall = PyRegex("Hörsaalübung|Hoersaaluebung|Zentralübung", ignoreCase: true)
    private static let kindExercise = PyRegex(#"\b(Übung|Uebung|Fragestunde)"#, ignoreCase: true)
    private static let kindTutorial = PyRegex("Tutorium", ignoreCase: true)
    private static let kindOther = PyRegex("Begrüßung|Studiengänge|Einführungsveranstaltung|Erstsemester", ignoreCase: true)
    private static let leadingNumber = PyRegex(#"^\d+\s+"#)
    private static let leadingKind = PyRegex(#"^(Gruppenübung|Übung|Uebung|Tutorium)\s*(zu|zur|:)?\s*"#, ignoreCase: true)
    private static let trailingQuestions = PyRegex(#"\s*[-–]\s*(Fragestunden|Tutorium).*$"#, ignoreCase: true)
    private static let bracketNote = PyRegex(#"\s*\((Tranche[^)]*|für [^)]*|Elektrotechnische Grundlagen der Informationstechnik)\)"#, ignoreCase: true)
    private static let trailingTranche = PyRegex(#",?\s*Tranche\s*\w+.*$"#, ignoreCase: true)
    private static let spaces = PyRegex(#"\s+"#)

    /// (Fach, Art) aus dem Kurstitel (`classify`); Art: vorlesung | gruppenuebung | hoersaaluebung | uebung | tutorium |
    /// sonstiges (Begruessung, Einfuehrung, Erstsemester). Vorlesung und Uebung eines Fachs ergeben dasselbe Fach.
    public static func classify(_ title: String) -> (subject: String, kind: String) {
        var kind = kindPattern(title)
        if kindOther.found(in: title) { kind = "sonstiges" }
        var s = title
        s = leadingNumber.sub(s)                                                  // Nummer vorne
        s = leadingKind.sub(s)
        s = trailingQuestions.sub(s)
        s = bracketNote.sub(s)
        s = trailingTranche.sub(s)
        s = PyText.strip(spaces.sub(s, " "), chars: " -:,(")
        return (s, kind)
    }

    /// Die Art-Muster von `classify` ohne "sonstiges" in derselben Reihenfolge: Gruppen-, Hoersaal-/Zentraluebung,
    /// Uebung/Fragestunde am Wortanfang, Tutorium; sonst "vorlesung". Auch fuer Freitext wie die Beschreibung einer
    /// Stud.IP-Kurszeit (`StudIPSchedule.classifyPatterns`).
    public static func kindPattern(_ s: String) -> String {
        if kindGroup.found(in: s) { return "gruppenuebung" }
        if kindLectureHall.found(in: s) { return "hoersaaluebung" }
        if kindExercise.found(in: s) { return "uebung" }
        if kindTutorial.found(in: s) { return "tutorium" }
        return "vorlesung"
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

    /// Art eines Termins im Stundenplan (`guess_kind`): vorlesung | uebung | labor | seminar, Teilwortsuche ohne
    /// Gross-/Kleinschreibung nach Codepunkten wie Pythons `in`; "lab" trifft wie dort auch Woerter wie "Kollaboration".
    public static func eventKind(_ title: String) -> String {
        let t = PyText.lower(title)
        return kindWords.first { $0.1.contains { PyText.contains(t, $0) } }?.0 ?? "vorlesung"
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
