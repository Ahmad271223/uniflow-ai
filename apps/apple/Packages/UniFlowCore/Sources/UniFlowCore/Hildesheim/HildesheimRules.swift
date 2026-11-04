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
    /// "Tutorien X" (Riesentest 03.11.2026)
    private static let kindTutorial = PyRegex("Tutori(?:um|en)", ignoreCase: true)
    /// "Vorlesung und Übung X", "Vorlesung + Übung X": ein Kurs mit Vorlesung, also vorlesung (Riesentest 03.11.2026)
    private static let kindCombined = PyRegex(#"Vorlesung\s*(?:und|\+|&|/)\s*(?:Übung|Uebung)"#, ignoreCase: true)
    private static let kindOther = PyRegex("Begrüßung|Studiengänge|Einführungsveranstaltung|Erstsemester", ignoreCase: true)
    private static let leadingNumber = PyRegex(#"^\d+\s+"#)
    // Riesentest 03.11.2026: "Vorlesung und Übung X" vorne, "Übung zur Vorlesung X" / "Fragestunde zur Vorlesung X" (die
    // Art-Angabe nimmt "Vorlesung" mit), "Übung X - Gruppe 7" und "X (Gruppe B)" hinten; dieselben Muster wie `classify`
    private static let leadingCombined = PyRegex(#"^Vorlesung\s*(?:und|\+|&|/)\s*(?:Übung|Uebung)(?:en)?\b\s*(?:zur|zu|:)?\s*"#, ignoreCase: true)
    private static let leadingKind = PyRegex(#"^(Vorlesung|Gruppenübung|Gruppenuebung|Hörsaalübung|Hoersaaluebung|Zentralübung|Übung|Uebung|Tutorien|Tutorium|Fragestunde)(?:en|n)?\b\s*(zur|zu|:)?\s*(?:Vorlesung\s+)?"#, ignoreCase: true)
    private static let trailingQuestions = PyRegex(#"\s*[-–]\s*(Fragestunden|Tutorium|Gruppenübung|Gruppenuebung|Hörsaalübung|Hoersaaluebung|Zentralübung|Übung|Uebung|Gruppe\s*\w+).*$"#, ignoreCase: true)
    private static let bracketNote = PyRegex(#"\s*\((Tranche[^)]*|für [^)]*|Elektrotechnische Grundlagen der Informationstechnik|Vorlesung[^)]*|Übung[^)]*|Uebung[^)]*|Tutorium[^)]*|Gruppe\s*\w+)\)"#, ignoreCase: true)
    private static let trailingTranche = PyRegex(#",?\s*Tranche\s*\w+.*$"#, ignoreCase: true)
    private static let spaces = PyRegex(#"\s+"#)

    /// (Fach, Art) aus dem Kurstitel (`classify`); Art: vorlesung | gruppenuebung | hoersaaluebung | uebung | tutorium |
    /// sonstiges (Begruessung, Einfuehrung, Erstsemester). Vorlesung und Uebung eines Fachs ergeben dasselbe Fach.
    public static func classify(_ title: String) -> (subject: String, kind: String) {
        var kind = kindPattern(title)
        if kindCombined.found(in: title) { kind = "vorlesung" }
        if kindOther.found(in: title) { kind = "sonstiges" }
        var s = title
        s = leadingNumber.sub(s)                                                  // Nummer vorne
        s = leadingCombined.sub(s)
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
