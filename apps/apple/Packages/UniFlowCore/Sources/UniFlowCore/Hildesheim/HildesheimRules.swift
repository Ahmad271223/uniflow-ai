import Foundation

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
