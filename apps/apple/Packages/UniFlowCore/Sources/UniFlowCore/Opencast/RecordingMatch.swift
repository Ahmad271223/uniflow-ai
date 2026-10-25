import Foundation

// Aufzeichnungen nach Fach ordnen und zu einer erkannten Aufgabe ein passendes Video vorschlagen. Alles ohne KI:
// Fach aus dem Kurstitel wie classify() in app/studip_sync.py, Lehrwoche des Blatts wie study.week_hint,
// Stichwoerter wie scriptsearch.tokens (gleiche Stoppwoerter und Wortstamm-Kuerzung). Lieber kein Vorschlag als
// ein falscher: nur im selben Modul und nur ueber einer festen Schwelle.

// MARK: - Fach aus dem Kurstitel

public enum StudIPSubject {
    /// classify() in app/studip_sync.py: (Fach, Art). Art: vorlesung | gruppenuebung | hoersaaluebung | uebung |
    /// tutorium | sonstiges
    public static func classify(_ title: String) -> (subject: String, kind: String) {
        func has(_ p: String) -> Bool { title.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
        var kind = "vorlesung"
        if has("Gruppenübung|Gruppenuebung") { kind = "gruppenuebung" }
        else if has("Hörsaalübung|Hoersaaluebung|Zentralübung") { kind = "hoersaaluebung" }
        else if has(#"\b(Übung|Uebung|Fragestunde)"#) { kind = "uebung" }
        else if has("Tutorium") { kind = "tutorium" }
        if has("Begrüßung|Studiengänge|Einführungsveranstaltung|Erstsemester") { kind = "sonstiges" }
        var s = title
        func sub(_ p: String, _ with: String = "") {
            s = s.replacingOccurrences(of: p, with: with, options: [.regularExpression, .caseInsensitive])
        }
        sub(#"^\d+\s+"#)
        sub(#"^(Gruppenübung|Übung|Uebung|Tutorium)\s*(zu|zur|:)?\s*"#)
        sub(#"\s*[-–]\s*(Fragestunden|Tutorium).*$"#)
        sub(#"\s*\((Tranche[^)]*|für [^)]*|Elektrotechnische Grundlagen der Informationstechnik)\)"#)
        sub(#",?\s*Tranche\s*\w+.*$"#)
        sub(#"\s+"#, " ")
        return (s.trimmingCharacters(in: CharacterSet(charactersIn: " -:,(")), kind)
    }

    /// Vergleichsform eines Fach- oder Modulnamens: klein, Leerraum zusammengefasst
    public static func key(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Kurs -> Modul

/// Kurs, wie ihn die App kennt (`/api/courses`, `courses` im Moduldetail).
public struct RecordingCourseRef: Sendable, Equatable {
    public let id: String
    public let moduleID: Int?
    public let subject: String?

    public init(id: String, moduleID: Int?, subject: String? = nil) {
        self.id = id
        self.moduleID = moduleID
        self.subject = subject
    }
}

public struct RecordingModuleRef: Sendable, Equatable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public enum RecordingAssignment {
    /// Modul eines Kurses: zuerst die Zuordnung der App (Kurs -> Modul), sonst das Fach (gespeichert oder aus dem
    /// Kurstitel) gleich dem Modulnamen (wie ensure_modules). Kennt die App den Kurs mit einem Modul, gilt nur das.
    public static func moduleID(courseID: String, courseTitle: String, courses: [RecordingCourseRef],
                                modules: [RecordingModuleRef]) -> Int? {
        let known = courses.filter { $0.id == courseID }
        if let m = known.compactMap(\.moduleID).first { return m }
        guard let subject = subject(courseTitle: courseTitle, stored: known.compactMap(\.subject).first) else { return nil }
        let k = StudIPSubject.key(subject)
        return modules.first { StudIPSubject.key($0.name) == k }?.id
    }

    /// Fach eines Kurses fuer die Ordnung ohne Modul; nil fuer Begruessung/Einfuehrung (Art "sonstiges")
    public static func subject(courseTitle: String, stored: String? = nil) -> String? {
        if let s = stored?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return s }
        let c = StudIPSubject.classify(courseTitle)
        return c.kind == "sonstiges" || c.subject.isEmpty ? nil : c.subject
    }

    /// Aufzeichnungen nach Modul; ohne Modul nach Fach (Kurstitel), Kurse ohne Fach unter "Sonstiges".
    public static func group(_ index: RecordingsIndex, courses: [RecordingCourseRef], modules: [RecordingModuleRef])
        -> (byModule: [Int: [RecordingCourse]], bySubject: [(subject: String, courses: [RecordingCourse])]) {
        var byModule: [Int: [RecordingCourse]] = [:]
        var bySubject: [String: (name: String, list: [RecordingCourse])] = [:]
        for c in index.courses where !c.videos.isEmpty {
            if let m = moduleID(courseID: c.courseID, courseTitle: c.courseTitle, courses: courses, modules: modules) {
                byModule[m, default: []].append(c)
            } else {
                let s = subject(courseTitle: c.courseTitle, stored: courses.first { $0.id == c.courseID }?.subject) ?? "Sonstiges"
                bySubject[StudIPSubject.key(s), default: (s, [])].list.append(c)
            }
        }
        let subjects = bySubject.values.map { (subject: $0.name, courses: $0.list) }
            .sorted { $0.subject.localizedStandardCompare($1.subject) == .orderedAscending }
        return (byModule, subjects)
    }
}

// MARK: - Lehrwoche eines Blatts (study.week_hint)

public enum StudIPWeekHint {
    /// Wochennummer aus Dateiname/Ordner: "Blatt 3", "ueb2", "GU01", "02A", "VL03", "Woche 4". nil, wenn unklar.
    public static func weekHint(name: String, folder: String?) -> Int? {
        let stem = name.lowercased().replacingOccurrences(of: #"\.[a-z0-9]+$"#, with: "", options: .regularExpression)
        let lastFolder = (folder ?? "").lowercased().split(separator: "/").last.map(String.init) ?? ""
        let p = #"(?:woche|kw|blatt|(?:ü|ue|u)bung|ueb|aufgabenblatt|serie|vl|vorlesung|folien|kapitel|kap|gu|g(?:ü|ue)|z(?:ü|ue)|h(?:ü|ue)|hu|tut)[ _\-]*0?(\d{1,2})(?!\d)"#
        for src in [stem, lastFolder] {
            if let n = LectureWeek.firstNumber(src, p), (1...16).contains(n) { return n }
        }
        if let n = LectureWeek.firstNumber(stem, #"^0?(\d{1,2})[a-z]?$"#), (1...16).contains(n) { return n }
        if let n = LectureWeek.firstNumber(stem, #"(?<!\d)0(\d)(?!\d)"#), (1...9).contains(n) { return n }
        return nil
    }
}

// MARK: - Stichwoerter (scriptsearch.tokens)

public enum ScriptSearchText {
    /// STOP in app/scriptsearch.py
    public static let stopWords: Set<String> = Set("""
    aber alle allem allen aller alles also als am an andere anderen auch auf aus bei beide beiden beim bereits bestimmen
    bestimmt berechnen berechne bis bitte da dabei damit dann das dass dem den denen der deren des dessen die dies diese
    diesem diesen dieser dieses doch dort du durch ein eine einem einen einer eines einige er es etwa euch falls fuer für
    gegeben gegebene gegebenen gilt gibt habe haben hat hier ihr ihre im in ins ist ja je jede jedem jeden jeder jedes
    kann koennen können man mit muss nach neben nicht noch nun nur ob oder ohne sei seien sein seine sich sie sind so
    sodass soll sollen sowie ueber über um und uns unter vom von vor wann war was weil welche welchem welchen welcher
    wenn wer werden wie wieder wir wird wo zeigen zeige zu zum zur zwei drei vier fünf funf aufgabe aufgaben teilaufgabe
    blatt übung uebung übungsblatt hinweis lösung loesung punkte punkt folgende folgenden folgendes beweisen begründen
    geben gib skizzieren betrachten betrachte seite folie vorlesung kapitel definition satz beispiel bemerkung lemma relevant relevanter klausur klausurrelevant stoff tranche
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// normalize(): zerlegte Umlaute aus PDF-Text ("Unabh¨ angigkeit", "a" + Trema) zusammensetzen
    public static func normalize(_ text: String) -> String {
        var t = text
        for (base, uml) in [("a", "ä"), ("o", "ö"), ("u", "ü"), ("A", "Ä"), ("O", "Ö"), ("U", "Ü")] {
            t = t.replacingOccurrences(of: "¨\\s*" + base, with: uml, options: .regularExpression)
            t = t.replacingOccurrences(of: base + "\u{0308}", with: uml)
        }
        return t
    }

    /// tokens(): Woerter ab 3 Buchstaben ohne Stoppwoerter, einfache Wortstamm-Kuerzung
    public static func tokens(_ text: String) -> [String] { tokensWithWords(text).map(\.token) }

    /// wie `tokens`, dazu das Wort, aus dem das Stichwort entstand (fuer den Grund "passt zu: Grenzwerte")
    public static func tokensWithWords(_ text: String) -> [(token: String, word: String)] {
        let norm = normalize(text)
        var out: [(String, String)] = []
        guard let re = try? NSRegularExpression(pattern: "[a-zäöüß]{3,}", options: [.caseInsensitive]) else { return [] }
        let ns = norm as NSString
        for m in re.matches(in: norm, range: NSRange(location: 0, length: ns.length)) {
            let original = ns.substring(with: m.range)
            var w = original.lowercased()
            if stopWords.contains(w) { continue }
            for suf in ["ungen", "ung", "en", "er", "es", "em", "e", "n", "s"] where w.count > 5 && w.hasSuffix(suf) {
                w = String(w.dropLast(suf.count))
                break
            }
            if w.count >= 3, !stopWords.contains(w) { out.append((w, original)) }
        }
        return out
    }
}

// MARK: - Passendes Video zur Aufgabe

/// Erkannte Aufgabe im Dokument: Modul und Lehrwoche des Blatts, Text der Seite.
public struct RecordingTaskContext: Sendable, Equatable {
    public let moduleID: Int?
    public let sheetWeek: Int?
    public let text: String

    public init(moduleID: Int?, sheetWeek: Int?, text: String) {
        self.moduleID = moduleID
        self.sheetWeek = sheetWeek
        self.text = text
    }
}

/// Ein Video mit seinem Modul und seiner Lehrwoche.
public struct RecordingCandidate: Sendable, Equatable {
    public let courseID: String
    public let video: OpencastVideo
    public let moduleID: Int?
    public let week: Int?

    public init(courseID: String, video: OpencastVideo, moduleID: Int?, week: Int?) {
        self.courseID = courseID
        self.video = video
        self.moduleID = moduleID
        self.week = week
    }
}

public struct RecordingSuggestion: Sendable, Equatable {
    public let courseID: String
    public let video: OpencastVideo
    public let score: Double
    /// z. B. "Vorlesung derselben Woche" oder "passt zu: Grenzwerte"
    public let reason: String
    /// gemeinsame Woerter in der Schreibweise des Videos
    public let terms: [String]
}

public enum RecordingSuggester {
    /// Mindestwert fuer einen Vorschlag
    public static let threshold = 1.5
    /// Stichwoerter allein muessen mindestens so viel ergeben (z. B. ein langes Fachwort wie "Grenzwerte")
    public static let keywordOnly = 1.5

    /// Woerter in Videotiteln, die nichts ueber den Inhalt sagen
    static let videoStopWords: Set<String> = ["vorlesungswoche", "woche", "zentralübung", "zentraluebung", "hörsaalübung",
                                              "teil", "video", "videos", "aufzeichnung", "vorlesungsaufzeichnung", "ergänzung",
                                              "besprechung", "korrektur", "fortsetzung", "wiederholung", "sitzung", "termin",
                                              "übungsblatt", "übungsblatts", "aufgabenblatt", "vorlesungen", "lösungen"]

    /// Bestes Video oder nil, wenn nichts sicher passt. Nie bei unbekanntem Modul, nie aus einem anderen Modul.
    public static func best(for task: RecordingTaskContext, among candidates: [RecordingCandidate]) -> RecordingSuggestion? {
        guard let module = task.moduleID else { return nil }
        let taskTokens = Set(ScriptSearchText.tokens(task.text))
        let scored = candidates.filter { $0.moduleID == module }.compactMap { score($0, task: task, taskTokens: taskTokens) }
        return scored.max { a, b in
            (a.score, a.video.created ?? .distantPast, a.video.id) < (b.score, b.video.created ?? .distantPast, b.video.id)
        }
    }

    /// Bewertung eines Videos: Woche (gleiche 2,0; Woche davor 1,5; beide bekannt, aber weiter weg -1,0) plus
    /// Stichwoerter (je gemeinsamem Stamm 0,5 / 1,0 / 1,5 nach Laenge). nil unter der Schwelle.
    static func score(_ c: RecordingCandidate, task: RecordingTaskContext, taskTokens: Set<String>) -> RecordingSuggestion? {
        var weekScore = 0.0
        var weekReason: String?
        let kind = c.video.title.range(of: #"(ü|ue)bung"#, options: [.regularExpression, .caseInsensitive]) != nil ? "Übung" : "Vorlesung"
        if let s = task.sheetWeek, let w = c.week {
            if w == s { weekScore = 2.0; weekReason = "\(kind) derselben Woche" }
            else if w == s - 1 { weekScore = 1.5; weekReason = "\(kind) der Woche davor" }
            else { weekScore = -1.0 }
        }
        var shared: [(token: String, word: String)] = []
        for t in ScriptSearchText.tokensWithWords(c.video.title + "\n" + (c.video.description ?? ""))
        where taskTokens.contains(t.token) && !videoStopWords.contains(t.word.lowercased()) && !shared.contains(where: { $0.token == t.token }) {
            shared.append(t)
        }
        let keywordScore = shared.reduce(0.0) { acc, t in acc + (t.token.count >= 8 ? 1.5 : t.token.count >= 6 ? 1.0 : 0.5) }
        let total = weekScore + keywordScore
        guard total >= threshold, weekScore > 0 || keywordScore >= keywordOnly else { return nil }
        // laengste (spezifischste) Woerter zuerst
        let words = shared.sorted { ($0.token.count, $1.word) > ($1.token.count, $0.word) }.map(\.word)
        var parts: [String] = []
        if let weekReason { parts.append(weekReason) }
        if !words.isEmpty { parts.append("passt zu: " + words.prefix(3).joined(separator: ", ")) }
        return RecordingSuggestion(courseID: c.courseID, video: c.video, score: total, reason: parts.joined(separator: " · "), terms: words)
    }
}
