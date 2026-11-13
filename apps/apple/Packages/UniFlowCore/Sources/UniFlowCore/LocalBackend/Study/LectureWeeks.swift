import Foundation

/// Lehrwochen fuer Moodle-Dateien selbst bestimmen (HsH-Moodle, Learnweb Hildesheim; 07.11.2026).
///
/// Anlass: Moodle-Kurse der Hochschule Hannover haben oft keine Wochen-Abschnitte (Themenformat oder ein grosser
/// Abschnitt), und ueber die Sitzung liefert Moodle keine Aenderungszeit. Jede Datei bekam darum den Zeitpunkt des
/// ersten Abgleichs (`UniStore.versionStamp`), und alle Unterlagen lagen in einer einzigen Woche.
///
/// Regeln, je Datei in dieser Reihenfolge (die erste, die etwas ergibt, gilt):
/// 1. Abschnitt: Wochen-Abschnitt in Moodle ("Woche 3", "3. Woche", "KW 46", Wochenformat "21. September -
///    27. September" bzw. "21.09. - 27.09.").
/// 2. Name: Nummer mit Schluesselwort im Dateinamen, im Namen der Moodle-Ressource oder in einem Ordner (tiefster
///    zuerst): "VL 3", "Vorlesung_03", "V03", "Folien 3", "Sitzung 3", "Übung 2", "Übungsblatt 02", "Blatt 4", "Ü3",
///    "Tutorium 5", "Lösung 2", "Skript Teil 4", "Kapitel 3", "Woche 5", "KW 46" (Kalenderwoche -> Lehrwoche).
///    Eine nackte Nummer am Anfang ("7_Literaturempfehlungen", "01 Einleitung") zaehlt NICHT: An der HsH ist das die
///    Laufnummer der Moodle-Ressourcen (Reihenfolge im Kurs), keine Lehrwoche (Befund vom echten iPad, 07.11.2026).
///    Allgemein-Material (Literatur, Errata, Hinweise, Organisatorisches, Modulbeschreibung, Formelsammlung,
///    `generalWords`) und Klausuren bleiben ohne Woche, auch mit Nummer davor; nur ein Schluesselwort mit Nummer im
///    Namen ("Hinweise zu Blatt 3") geht vor.
///    Zuordnung: Vorlesung/Kapitel/Teil n -> Lehrwoche n; Übungsblatt/Übung/Tutorium n -> Lehrwoche n (ein Blatt
///    wird meist in der Woche der passenden Vorlesung herausgegeben); Lösung n -> Lehrwoche n + 1 (die Lösung kommt
///    eine Woche nach dem Blatt). Beginnt eine Reihe eines Kurses mit 0 ("Blatt 0"), zaehlt sie ab Woche 1. Hat eine
///    Reihe mehr Nummern als das Semester Lehrwochen (zwei Vorlesungen je Woche), wird sie gestaucht:
///    Lehrwoche = aufgerundet n * Wochen / hoechste Nummer.
/// 3. Datum: ein Datum im Namen ("VL_2026-10-12", "12.10.2026"), sonst das der Datei (Moodle `timemodified` ueber den
///    Schluessel, ueber die Sitzung der `Last-Modified`-Kopf des Downloads), sonst der Tag, an dem die Datei in einem
///    schon bekannten Kurs neu auftauchte. Das Datum wird zur Lehrwoche ab Vorlesungsbeginn; Tage in der
///    vorlesungsfreien Zeit (Weihnachtspause) zaehlen zur letzten Lehrwoche davor, bis 7 Tage vor Beginn zu Woche 1.
///    Fruehere und spaetere Daten (kopierte Kurse, alte Folien) sagen nichts ueber die Woche.
/// 4. Sonst "Allgemein" (keine Lehrwoche; nicht alles in Woche 1).
///
/// Lehrwoche heisst: Wochen ab Vorlesungsbeginn ohne Pausenwochen (eine Woche, deren Montag bis Freitag ganz in einer
/// Unterbrechung liegen). Vorlesungsbeginn und Unterbrechungen kommen aus der Tabelle `Holidays.semesters`
/// (offizielle Semestertermine, Quellen dort und in app/holidays.py); fehlt das Semester dort: aus den Terminen im
/// Stundenplan, sonst ab der fruehesten Datei des Kurses, sonst eine Schaetzung nach dem Semesternamen.
///
/// Einmal berechnen und merken: Semester je Kurs (`lecture_course_terms`) und Woche/Art je Datei-ID
/// (`lecture_file_weeks`) werden dauerhaft gespeichert; spaetere Abgleiche ordnen nur neue Dateien zu, nichts springt.
/// Gespeichert wird der Montag der Lehrwoche, angezeigt die Woche ab dem Vorlesungsbeginn des laufenden Semesters
/// (`LocalModules.Dates`). Beide Tabellen gibt es nur auf dem Geraet und erst bei Bedarf (wie `file_versions`). Ohne
/// gespeicherte Zuordnung (Stud.IP der LUH) bleibt alles wie bisher (Aenderungszeit und `StudyClassify.weekHint`).
/// Eine KI braucht es nicht; eine Einordnung durch die KI (Pro AI) waere hoechstens ein spaeterer letzter Schritt fuer
/// Dateien in "Allgemein".
public enum LectureWeeks {

    /// Woche "Allgemein" im Moduldetail (keine Lehrwoche; -2 Klausuren, -1 aeltere Unterlagen, 0 vor Beginn)
    public static let generalWeek = -3

    // MARK: Semester

    public struct Term: Sendable, Equatable {
        public let semester: String
        /// erster und letzter Vorlesungstag (Tagesnummern wie `BerlinClock`)
        public let start: Int
        public let end: Int
        /// Unterbrechungen (erster bis letzter freier Tag)
        public let breaks: [ClosedRange<Int>]
        /// tabelle | stundenplan | kurs | schaetzung
        public let source: String

        public init(semester: String, start: Int, end: Int, breaks: [ClosedRange<Int>] = [], source: String) {
            self.semester = semester; self.start = start; self.end = max(start, end); self.breaks = breaks; self.source = source
        }

        public var firstMonday: Int { StudyWeeks.monday(start) }

        /// Pausenwoche: Montag bis Freitag liegen ganz in Unterbrechungen
        public func isBreakWeek(monday m: Int) -> Bool {
            (m...(m + 4)).allSatisfy { d in breaks.contains { $0.contains(d) } }
        }

        /// Montage der Lehrwochen (ohne Pausenwochen) vom Beginn bis zum Ende der Vorlesungszeit
        public var lectureMondays: [Int] {
            stride(from: firstMonday, through: StudyWeeks.monday(end), by: 7).filter { !isBreakWeek(monday: $0) }
        }

        /// Montag der Lehrwoche n (ab 1), nil ausserhalb
        public func monday(ofLectureWeek n: Int) -> Int? {
            let all = lectureMondays
            return n >= 1 && n <= all.count ? all[n - 1] : nil
        }

        /// Nummer der Lehrwoche eines Montags (Pausenwochen: die letzte davor), nil vor Beginn
        public func lectureWeek(ofMonday m: Int) -> Int? {
            let n = lectureMondays.filter { $0 <= m }.count
            return n >= 1 ? n : nil
        }

        /// Montag der Lehrwoche eines Tages: in Pausenwochen die letzte Lehrwoche davor, bis 7 Tage vor Beginn
        /// Woche 1; frueher oder nach dem Ende der Vorlesungszeit nil
        public func weekMonday(forDay d: Int) -> Int? {
            if d < firstMonday - 7 || d > end { return nil }
            if d < firstMonday { return firstMonday }
            let m = StudyWeeks.monday(d)
            return lectureMondays.last { $0 <= m }
        }

        /// Montag der Kalenderwoche k (ISO 8601) im Semester (Jahr des Beginns oder das folgende), nil ausserhalb
        public func monday(ofCalendarWeek k: Int) -> Int? {
            guard (1...53).contains(k) else { return nil }
            let y0 = BerlinClock.civil(start).year
            for y in [y0, y0 + 1] {
                let m = StudyWeeks.monday(BerlinClock.dayNumber(year: y, month: 1, day: 4)) + 7 * (k - 1)
                if m >= firstMonday - 7, m <= end, let w = weekMonday(forDay: m) { return w }
            }
            return nil
        }
    }

    /// "WiSe 2026/27", "WS 26/27", "Wintersemester 2026/2027" -> "w2026"; "SoSe 2027", "SS 27" -> "s2027"
    public static func semesterKey(_ s: String?) -> String? {
        let t = UniStore.normSemester(s)
        guard let m = HText.match(semesterRE, t), let kind = m.groups[1], let ys = m.groups[2], var y = Int(ys) else { return nil }
        if ys.count == 2 { y += 2000 }
        return (kind.hasPrefix("w") ? "w" : "s") + String(y)
    }

    private static let semesterRE = HText.regex(#"(wise|ws|winter|sose|ss|sommer)(?:semester)?(\d{4}|\d{2})(?!\d)"#)

    /// Semester aus der Tabelle der Hochschule (`Holidays.semesters`)
    public static func tableTerm(university: String, semester: String?) -> Term? {
        guard let key = semesterKey(semester) else { return nil }
        for s in Holidays.semesters[university] ?? [] where semesterKey(s.name) == key {
            guard let a = BerlinClock.parseISODate(s.start), let z = BerlinClock.parseISODate(s.end) else { continue }
            let breaks = s.breaks.compactMap { b -> ClosedRange<Int>? in
                guard let x = BerlinClock.parseISODate(b.from), let y = BerlinClock.parseISODate(b.to), x <= y else { return nil }
                return x...y
            }
            return Term(semester: s.name, start: a, end: z, breaks: breaks, source: "tabelle")
        }
        return nil
    }

    /// Schaetzung nach dem Namen, wenn sonst nichts bekannt ist: Wintersemester ab dem Montag nach dem 10.10. (16
    /// Wochen, Weihnachtspause 23.12. bis 3.1.), Sommersemester ab dem Montag nach dem 7.4. (15 Wochen)
    public static func estimatedTerm(semester: String?) -> Term? {
        guard let key = semesterKey(semester), let y = Int(key.dropFirst()) else { return nil }
        if key.hasPrefix("w") {
            let s = nextMonday(BerlinClock.dayNumber(year: y, month: 10, day: 10))
            let pause = BerlinClock.dayNumber(year: y, month: 12, day: 23)...BerlinClock.dayNumber(year: y + 1, month: 1, day: 3)
            return Term(semester: semester ?? "", start: s, end: s + 16 * 7 - 3, breaks: [pause], source: "schaetzung")
        }
        let s = nextMonday(BerlinClock.dayNumber(year: y, month: 4, day: 7))
        return Term(semester: semester ?? "", start: s, end: s + 15 * 7 - 3, source: "schaetzung")
    }

    static func nextMonday(_ d: Int) -> Int { BerlinClock.weekday(d) == 0 ? d : StudyWeeks.monday(d) + 7 }

    // MARK: Hinweise aus Abschnitt und Namen

    /// Art der Nummer im Namen
    public enum NumberKind: String, Sendable {
        case calendarWeek = "kw", week = "woche", solution = "loesung", sheet = "blatt", tutorial = "tutorium"
        case lecture = "vl", part = "teil", chapter = "kapitel"
    }

    /// Kennzeichen frueherer Zuordnungen ueber die nackte Nummer am Anfang (`detail` "nummer 7"); diese werden beim
    /// naechsten Abgleich einmal neu bewertet (`assignCourse`), alles andere bleibt
    static let legacyLeadingDetail = "nummer "

    public struct NameHint: Sendable, Equatable {
        public let kind: NumberKind
        public let number: Int
    }

    /// Text fuer die Muster: klein, NFC, ohne Endung, "_" und "-" als Leerzeichen
    static func normalized(_ s: String, stripExtension: Bool) -> String {
        var t = HText.nfc(s).lowercased()
        if stripExtension { t = HText.replace(extensionRE, in: t, with: "") }
        t = t.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return HText.collapse(t)
    }

    private static let extensionRE = HText.regex(#"\.[a-z0-9]{1,5}$"#)

    private static let numberPatterns: [(NumberKind, NSRegularExpression)] = [
        (.calendarWeek, HText.regex(#"\bkw\s?0?(\d{1,2})(?!\d)"#)),
        (.week, HText.regex(#"\b(?:lehr|vorlesungs)?(?:woche|week)\s?(?:nr\.?\s?)?0?(\d{1,2})(?!\d)"#)),
        (.week, HText.regex(#"(?<![\d.])0?(\d{1,2})\.\s?(?:lehr|vorlesungs)?woche\b"#)),
        (.solution, HText.regex(#"\b(?:muster)?(?:l(?:ö|oe)sung(?:en|s)?|lsg|solutions?)\s?(?:zu[mr]?\s?)?(?:(?:übungs|uebungs|aufgaben)?blatt|übung|uebung|ü|ue|sheet|aufgabe|serie)?\s?(?:nr\.?\s?)?0?(\d{1,2})(?!\d)"#)),
        (.sheet, HText.regex(#"\b(?:(?:übungs|uebungs|aufgaben)?blatt|haus(?:ü|ue)bung|(?:ü|ue)bungs?serie|(?:ü|ue)bung|ueb|serie|exercise|sheet|assignment)\s?(?:nr\.?\s?)?0?(\d{1,2})(?!\d)"#)),
        (.sheet, HText.regex(#"\b(?:ü|ue|ub)\s?0?(\d{1,2})(?!\d)"#)),
        (.tutorial, HText.regex(#"\b(?:tutorium|tut)\s?(?:nr\.?\s?)?0?(\d{1,2})(?!\d)"#)),
        (.lecture, HText.regex(#"\b(?:vorlesung|vl|vo|folien|slides|lecture|lec|sitzung|termin)\s?(?:nr\.?\s?)?0?(\d{1,2})(?!\d)"#)),
        (.lecture, HText.regex(#"\bv(\d{2})(?!\d)"#)),
        (.part, HText.regex(#"\b(?:teil|part)\s?0?(\d{1,2})(?!\d)"#)),
        (.chapter, HText.regex(#"\b(?:kapitel|kap\.?|chapter)\s?0?(\d{1,2})(?!\d)"#)),
    ]

    /// Allgemein-Material ohne Lehrwoche (Dateiname oder Name der Moodle-Ressource), Regel 2 und 3 entfallen
    static let generalWords = HText.regex(#"literatur|errat(?:a|um)|hinweis|organisat|modulbeschreibung|modulhandbuch|formelsammlung|merkblatt|ank(?:ü|ue)ndigung|\btermine\b|raumplan|lernziel|syllabus|leseliste|glossar|checkliste|\bfaq\b|ablaufplan|semesterplan|zeitplan"#)

    /// Allgemein-Material nach Name oder Ressource (`generalWords`)
    public static func isGeneral(_ f: Input) -> Bool {
        [f.name, f.moduleName ?? ""].contains { HText.match(generalWords, HText.nfc($0).lowercased()) != nil }
    }

    /// Wort fuer Loesung (fuer "Blatt 2 Lösung" / "Übung 3 (Musterlösung)")
    private static let solutionWordRE = HText.regex(#"l(?:ö|oe)sung|\blsg\b|solution"#)

    /// Nummer im Namen eines Dokuments, eines Ordners oder Abschnitts; nil ohne
    public static func nameHint(_ text: String, stripExtension: Bool = true) -> NameHint? {
        let raw = HText.nfc(text).lowercased()
        // Daten im Namen sind keine Nummern ("12.10.2026", "2026-10-12")
        let t = normalized(HText.replace(dateInNameRE, in: raw, with: " "), stripExtension: stripExtension)
        for (kind, re) in numberPatterns {
            guard let m = HText.match(re, t), let g = m.groups[1], let n = Int(g) else { continue }
            if kind == .calendarWeek, !(1...53).contains(n) { continue }
            if kind != .calendarWeek, !(0...40).contains(n) { continue }
            if kind == .sheet, HText.match(solutionWordRE, t) != nil { return NameHint(kind: .solution, number: n) }
            return NameHint(kind: kind, number: n)
        }
        return nil
    }

    private static let dateInNameRE = HText.regex(#"(?<!\d)(?:\d{1,2}\.\d{1,2}\.(?:\d{4}|\d{2})?|\d{4}[-_.]\d{2}[-_.]\d{2}|20\d{6})(?!\d)"#)

    /// Datum im Namen ("2026-10-12", "20261012", "12.10.2026", "12.10.26"), Tagesnummer oder nil
    public static func dateInName(_ text: String) -> Int? {
        let t = HText.nfc(text)
        if let m = HText.match(isoDateRE, t), let y = Int(m.groups[1] ?? ""), let mo = Int(m.groups[2] ?? ""), let d = Int(m.groups[3] ?? "") {
            return validDay(y, mo, d)
        }
        if let m = HText.match(germanDateRE, t), let d = Int(m.groups[1] ?? ""), let mo = Int(m.groups[2] ?? ""),
           let ys = m.groups[3], var y = Int(ys) {
            if ys.count == 2 { y += 2000 }
            return validDay(y, mo, d)
        }
        return nil
    }

    private static let isoDateRE = HText.regex(#"(?<!\d)(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?!\d)"#)
    private static let germanDateRE = HText.regex(#"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})(?!\d)"#)

    static func validDay(_ y: Int, _ m: Int, _ d: Int) -> Int? {
        guard (2000...2100).contains(y), (1...12).contains(m), d >= 1, d <= BerlinClock.daysInMonth(year: y, month: m) else { return nil }
        return BerlinClock.dayNumber(year: y, month: m, day: d)
    }

    static let months: [String: Int] = [
        "januar": 1, "jan": 1, "january": 1, "februar": 2, "feb": 2, "february": 2, "märz": 3, "maerz": 3, "mär": 3, "mrz": 3,
        "march": 3, "mar": 3, "april": 4, "apr": 4, "mai": 5, "may": 5, "juni": 6, "jun": 6, "june": 6, "juli": 7, "jul": 7,
        "july": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9, "oktober": 10, "okt": 10, "october": 10,
        "oct": 10, "november": 11, "nov": 11, "dezember": 12, "dez": 12, "december": 12, "dec": 12,
    ]

    private static let sectionWordDateRE = HText.regex(#"^(\d{1,2})\.?\s?([a-zäöü]{3,9})\.?(?:\s?(\d{4}))?\s?(?:-|–|bis)"#)
    private static let sectionNumDateRE = HText.regex(#"^(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?\s?(?:-|–|bis)"#)
    private static let sectionWeekRE = HText.regex(#"^(?:(?:lehr|vorlesungs)?woche|week)\s?0?(\d{1,2})\b|^0?(\d{1,2})\.\s?(?:lehr|vorlesungs)?woche\b"#)
    private static let sectionKWRE = HText.regex(#"^kw\s?0?(\d{1,2})\b"#)

    /// Regel 1: Montag der Lehrwoche eines Wochen-Abschnitts, nil fuer andere Abschnitte (Themen, "Allgemeines")
    public static func sectionWeek(_ section: String?, term: Term) -> (monday: Int, detail: String)? {
        let t = HText.collapse(HText.nfc(section ?? "").lowercased())
        guard !t.isEmpty else { return nil }
        if let m = HText.match(sectionWeekRE, t), let n = Int(m.groups[1] ?? m.groups[2] ?? ""),
           let mon = term.monday(ofLectureWeek: n) {
            return (mon, "Abschnitt Woche \(n)")
        }
        if let m = HText.match(sectionKWRE, t), let k = Int(m.groups[1] ?? ""), let mon = term.monday(ofCalendarWeek: k) {
            return (mon, "Abschnitt KW \(k)")
        }
        var dm: (Int, Int, Int?)?
        if let m = HText.match(sectionWordDateRE, t), let d = Int(m.groups[1] ?? ""), let mo = months[m.groups[2] ?? ""] {
            dm = (d, mo, m.groups[3].flatMap { Int($0) })
        } else if let m = HText.match(sectionNumDateRE, t), let d = Int(m.groups[1] ?? ""), let mo = Int(m.groups[2] ?? "") {
            dm = (d, mo, m.groups[3].flatMap { Int($0) }.map { $0 < 100 ? $0 + 2000 : $0 })
        }
        guard let (d, mo, year) = dm else { return nil }
        let y0 = BerlinClock.civil(term.start).year
        for y in year.map({ [$0] }) ?? [y0, y0 + 1] {
            guard let day = validDay(y, mo, d), let mon = term.weekMonday(forDay: day) else { continue }
            return (mon, "Abschnitt ab \(BerlinClock.pad(d, 2)).\(BerlinClock.pad(mo, 2)).")
        }
        return nil
    }

    // MARK: Zuordnung je Datei

    public enum Rule: String, Sendable {
        case section = "abschnitt", name = "name", date = "datum", general = "allgemein"
    }

    /// Eine Datei der Quelle. `date`: Unix-Zeit der Datei, falls bekannt (Moodle `timemodified`, `Last-Modified`
    /// des Downloads, Tag des ersten Auftauchens in einem schon bekannten Kurs). `final`: ohne Datum trotzdem
    /// zuordnen ("Allgemein"); false, solange ein Datum noch kommen kann (Datei noch nicht geladen).
    public struct Input: Sendable, Equatable {
        public let id: String
        public let name: String
        public let folder: String?
        public let section: String?
        public let moduleName: String?
        public var date: Int?
        public var final: Bool

        public init(id: String, name: String, folder: String? = nil, section: String? = nil, moduleName: String? = nil,
                    date: Int? = nil, final: Bool = true) {
            self.id = id; self.name = name; self.folder = folder; self.section = section; self.moduleName = moduleName
            self.date = date; self.final = final
        }
    }

    public struct Assignment: Sendable, Equatable {
        public let fileID: String
        /// Montag der Lehrwoche, nil = "Allgemein"
        public let monday: Int?
        /// Lehrwoche ab Vorlesungsbeginn ohne Pausenwochen, nil = "Allgemein"
        public let lectureWeek: Int?
        /// vorlesung | skript | uebung | loesung | klausur | sonstiges
        public let docType: String
        public let rule: Rule
        /// kurze Begruendung ("VL 3", "Blatt 2 +1", "Datum 14.10.")
        public let detail: String
    }

    /// Texte fuer Regel 2, wichtigster zuerst: Dateiname, Name der Moodle-Ressource, Ordner (tiefster zuerst)
    static func hintSources(_ f: Input) -> [(text: String, isFile: Bool)] {
        var out: [(String, Bool)] = [(f.name, true)]
        if let m = f.moduleName, !m.isEmpty { out.append((m, false)) }
        let parts = (f.folder ?? "").split(separator: "/").map(String.init).filter { !$0.isEmpty }
        for p in parts.reversed() where !out.contains(where: { $0.0 == p }) { out.append((p, false)) }
        return out
    }

    /// Erster Namenshinweis einer Datei
    public static func nameHint(of f: Input) -> NameHint? {
        for (text, isFile) in hintSources(f) {
            if let h = nameHint(text, stripExtension: isFile) { return h }
        }
        return nil
    }

    /// Hat die Datei einen Abschnitts- oder Namenshinweis oder ist sie Allgemein-Material (dann braucht sie kein Datum)?
    public static func hasHint(_ f: Input, term: Term?) -> Bool {
        if let term, sectionWeek(f.section, term: term) != nil { return true }
        if nameHint(of: f) != nil { return true }
        if isGeneral(f) { return true }
        return hintSources(f).contains { dateInName($0.text) != nil }
    }

    /// Art der Datei (Vorlesung, Skript, Übung, Lösung, Sonstiges; Klausur bleibt Klausur)
    static func docType(_ f: Input, hint: NameHint?, courseKind: String?) -> String {
        let folder = [f.folder, f.moduleName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        var t = StudyClassify.effectiveType(name: f.name, folder: folder, aiType: nil, courseKind: courseKind).type
        if t == "organisatorisch" { t = "sonstiges" }
        if t == "sonstiges", let h = hint {
            switch h.kind {
            case .solution: t = "loesung"
            case .sheet, .tutorial: t = "uebung"
            case .lecture: t = "vorlesung"
            case .part: t = "skript"
            default: break
            }
        }
        if hint?.kind == .solution, t == "uebung" { t = "loesung" }
        return t
    }

    /// Reihen eines Kurses je Art: (kleinste, groesste Nummer), fuer "Blatt 0" und gestauchte Reihen
    static func series(_ files: [Input]) -> [NumberKind: (min: Int, max: Int)] {
        var out: [NumberKind: (min: Int, max: Int)] = [:]
        for f in files {
            guard let h = nameHint(of: f), h.kind != .calendarWeek, h.kind != .week else { continue }
            let k = h.kind == .solution ? NumberKind.sheet : h.kind      // Loesungen zaehlen zur Reihe der Blaetter
            let cur = out[k] ?? (h.number, h.number)
            out[k] = (min(cur.min, h.number), max(cur.max, h.number))
        }
        return out
    }

    /// Regeln 1 bis 4 fuer alle Dateien eines Kurses (rein, ohne Datenbank). `all`: alle Dateien des Kurses (fuer die
    /// Reihen), `files`: die zuzuordnenden; Dateien ohne Hinweis und Datum, die nicht `final` sind, fehlen im Ergebnis.
    public static func assign(_ files: [Input], all: [Input]? = nil, term: Term, courseKind: String? = nil) -> [Assignment] {
        let rows = series(all ?? files)
        let count = term.lectureMondays.count
        var out: [Assignment] = []
        for f in files {
            let hint = nameHint(of: f)
            let type = docType(f, hint: hint, courseKind: courseKind)
            func make(_ monday: Int?, _ rule: Rule, _ detail: String) -> Assignment {
                Assignment(fileID: f.id, monday: monday, lectureWeek: monday.flatMap { term.lectureWeek(ofMonday: $0) }, docType: type,
                           rule: rule, detail: detail)
            }
            // 1. Wochen-Abschnitt
            if let s = sectionWeek(f.section, term: term) {
                out.append(make(s.monday, .section, s.detail))
                continue
            }
            // 2. Nummer im Namen
            if let h = hint {
                var monday: Int?
                var detail = "\(h.kind.rawValue) \(h.number)"
                switch h.kind {
                case .calendarWeek:
                    monday = term.monday(ofCalendarWeek: h.number)
                case .week:
                    monday = term.monday(ofLectureWeek: h.number)
                default:
                    let k = h.kind == .solution ? NumberKind.sheet : h.kind
                    var n = h.number + ((rows[k]?.min ?? 1) == 0 ? 1 : 0)
                    let top = (rows[k]?.max ?? h.number) + ((rows[k]?.min ?? 1) == 0 ? 1 : 0)
                    if top > count, count > 0, h.kind != .chapter {
                        n = Int((Double(n * count) / Double(top)).rounded(.up))     // zwei Vorlesungen je Woche
                        detail += " gestaucht"
                    }
                    if h.kind == .solution {
                        n = min(n + 1, max(count, 1))
                        detail += " +1"
                    }
                    monday = term.monday(ofLectureWeek: n)
                }
                if let monday {
                    out.append(make(monday, .name, detail))
                    continue
                }
            }
            // Klausuren und Allgemein-Material ohne Schluesselwort: keine Lehrwoche, auch nicht ueber das Datum
            if type == "klausur" {
                out.append(make(nil, .general, "Klausur"))
                continue
            }
            if isGeneral(f) {
                out.append(make(nil, .general, "Allgemein-Material"))
                continue
            }
            // 3. Datum: im Namen, sonst das der Datei
            if let d = hintSources(f).lazy.compactMap({ dateInName($0.text) }).first, let mon = term.weekMonday(forDay: d) {
                out.append(make(mon, .date, "Datum im Namen \(BerlinClock.isoDate(d))"))
                continue
            }
            if let t = f.date, t > 0 {
                let day = BerlinClock.local(utc: t).day
                if let mon = term.weekMonday(forDay: day) {
                    out.append(make(mon, .date, "Datum \(BerlinClock.isoDate(day))"))
                    continue
                }
                out.append(make(nil, .general, "Datum \(BerlinClock.isoDate(day)) ausserhalb der Vorlesungszeit"))
                continue
            }
            // 4. Allgemein, aber erst, wenn kein Datum mehr kommt
            if f.final { out.append(make(nil, .general, "ohne Hinweis")) }
        }
        return out
    }

    // MARK: Speicher

    static let tableSQL = """
        CREATE TABLE IF NOT EXISTS lecture_course_terms (
            course_id TEXT PRIMARY KEY,
            university TEXT,
            semester TEXT,
            lecture_start TEXT NOT NULL,
            lecture_end TEXT NOT NULL,
            breaks TEXT,
            source TEXT,
            computed_at TEXT);
        CREATE TABLE IF NOT EXISTS lecture_file_weeks (
            file_id TEXT PRIMARY KEY,
            course_id TEXT,
            week_monday TEXT,
            lecture_week INTEGER,
            doc_type TEXT,
            rule TEXT,
            detail TEXT,
            assigned_at TEXT);
        """

    static func ensureTables(_ c: SQLiteConnection) throws { try c.executeScript(tableSQL) }

    static func hasTables(_ c: SQLiteConnection) throws -> Bool {
        try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='lecture_file_weeks'") != nil
    }

    static func encodeBreaks(_ b: [ClosedRange<Int>]) -> String {
        b.map { "\(BerlinClock.isoDate($0.lowerBound))..\(BerlinClock.isoDate($0.upperBound))" }.joined(separator: ",")
    }

    static func decodeBreaks(_ s: String?) -> [ClosedRange<Int>] {
        (s ?? "").split(separator: ",").compactMap { p in
            let ab = p.components(separatedBy: "..")
            guard ab.count == 2, let a = BerlinClock.parseISODate(ab[0]), let z = BerlinClock.parseISODate(ab[1]), a <= z else { return nil }
            return a...z
        }
    }

    static func term(row r: SQLiteRow) -> Term? {
        guard let a = (r["lecture_start"]?.string).flatMap(BerlinClock.parseISODate),
              let z = (r["lecture_end"]?.string).flatMap(BerlinClock.parseISODate) else { return nil }
        return Term(semester: r["semester"]?.string ?? "", start: a, end: z, breaks: decodeBreaks(r["breaks"]?.string),
                    source: r["source"]?.string ?? "")
    }

    /// Gemerktes Semester eines Kurses
    public static func storedTerm(_ c: SQLiteConnection, courseID: String) throws -> Term? {
        guard try hasTables(c), let r = try c.queryOne("SELECT * FROM lecture_course_terms WHERE course_id=?", [.text(courseID)]) else { return nil }
        return term(row: r)
    }

    /// Semester aus den Terminen im Stundenplan (Kurs oder sein Modul): erster bis letzter Tag der Serien
    static func timetableTerm(_ c: SQLiteConnection, courseID: String, semester: String?) throws -> Term? {
        let r = try c.queryOne("""
            SELECT MIN(date_from) AS a, MAX(date_to) AS z FROM course_events
            WHERE COALESCE(date_from, '') <> '' AND (course_id=? OR (module_id IS NOT NULL AND module_id=(SELECT module_id FROM courses WHERE id=?)))
            """, [.text(courseID), .text(courseID)])
        guard let a = (r?["a"]?.string).flatMap({ BerlinClock.parseISODate(String($0.prefix(10))) }) else { return nil }
        let z = (r?["z"]?.string).flatMap { BerlinClock.parseISODate(String($0.prefix(10))) } ?? a + 15 * 7
        guard z >= a, z - a < 30 * 7 else { return nil }
        return Term(semester: semester ?? "", start: a, end: z, source: "stundenplan")
    }

    /// Semester eines Kurses: gemerkt, sonst Tabelle, Stundenplan, frueheste Datei (`earliestDay`), Schaetzung. Ein
    /// gemerktes Semester aus einer schwaecheren Quelle weicht der Tabelle, sobald sie es kennt; sonst bleibt es.
    public static func rememberTerm(_ c: SQLiteConnection, courseID: String, semester: String?, university: String,
                                    earliestDay: Int?, now: String) throws -> Term? {
        try ensureTables(c)
        let table = tableTerm(university: university, semester: semester)
        if let t = try storedTerm(c, courseID: courseID), table == nil || t.source == "tabelle" { return t }
        // Kurs ohne Semester im Titel: das Semester der Tabelle, das am Tag des Abgleichs laeuft oder als naechstes kommt
        let running = semesterKey(semester) == nil
            ? Holidays.defaultTerm(university: university, today: String(now.prefix(10))).flatMap { tableTerm(university: university, semester: $0.name) }
            : nil
        let found = try table ?? running ?? timetableTerm(c, courseID: courseID, semester: semester)
            ?? earliestDay.map { d in Term(semester: semester ?? "", start: StudyWeeks.monday(d), end: StudyWeeks.monday(d) + 15 * 7 - 3, source: "kurs") }
            ?? estimatedTerm(semester: semester)
        guard let t = found else { return nil }
        try c.execute("""
            INSERT OR REPLACE INTO lecture_course_terms(course_id, university, semester, lecture_start, lecture_end, breaks, source, computed_at)
            VALUES (?,?,?,?,?,?,?,?)
            """, [.text(courseID), .text(university), .text(t.semester), .text(BerlinClock.isoDate(t.start)), .text(BerlinClock.isoDate(t.end)),
                  .text(encodeBreaks(t.breaks)), .text(t.source), .text(now)])
        return t
    }

    /// IDs der Dateien, die schon eine Zuordnung haben
    public static func assignedIDs(_ c: SQLiteConnection, courseID: String) throws -> Set<String> {
        guard try hasTables(c) else { return [] }
        return Set(try c.query("SELECT file_id FROM lecture_file_weeks WHERE course_id=?", [.text(courseID)]).compactMap { $0["file_id"]?.string })
    }

    /// Einhaengepunkt des Moodle-Imports (HsH, Learnweb): Semester des Kurses merken und alle Dateien ohne Zuordnung
    /// zuordnen; vorhandene Zuordnungen bleiben unveraendert. Rueckgabe: neu gespeicherte Zuordnungen. Fehlt ein
    /// Datum, gilt der Tag des ersten Auftauchens, wenn die Datei spaeter als die ersten des Kurses kam.
    @discardableResult
    public static func assignCourse(_ c: SQLiteConnection, courseID: String, semester: String?, university: String,
                                    files: [Input], now: String) throws -> [Assignment] {
        try ensureTables(c)
        // einmal neu bewerten: fruehere Zuordnungen ueber die nackte Nummer am Anfang ("7_Literatur" -> Woche 7);
        // nur diese Zeilen (rule "name", detail "nummer N"), nie Abschnitt, Datum oder eine Wahl des Nutzers
        try c.execute("DELETE FROM lecture_file_weeks WHERE course_id=? AND rule='name' AND detail LIKE ?",
                      [.text(courseID), .text(legacyLeadingDetail + "%")])
        let done = try assignedIDs(c, courseID: courseID)
        var todo = files.filter { !done.contains($0.id) }
        guard !todo.isEmpty else { return [] }
        // erstes Auftauchen: nur aussagekraeftig, wenn die Datei nach dem ersten Abgleich des Kurses kam
        var seen: [String: String] = [:]
        for r in try c.query("SELECT id, first_seen FROM files WHERE course_id=?", [.text(courseID)]) {
            if let id = r["id"]?.string, let s = r["first_seen"]?.string { seen[id] = s }
        }
        let firstDay = seen.values.compactMap { BerlinClock.parseISODate(String($0.prefix(10))) }.min()
        for i in todo.indices where todo[i].date == nil {
            guard let s = seen[todo[i].id], let day = BerlinClock.parseISODate(String(s.prefix(10))), let first = firstDay, day > first + 1,
                  let t = BerlinClock.utcSeconds(localISO: s) else { continue }
            todo[i].date = t
        }
        let dated = (files.compactMap(\.date) + todo.compactMap(\.date)).filter { $0 > 0 }.map { BerlinClock.local(utc: $0).day }
        guard let term = try rememberTerm(c, courseID: courseID, semester: semester, university: university,
                                          earliestDay: dated.min(), now: now) else { return [] }
        let kind = try c.scalar("SELECT kind FROM courses WHERE id=?", [.text(courseID)])?.string
        let result = assign(todo, all: files, term: term, courseKind: kind)
        for a in result {
            try c.execute("""
                INSERT OR IGNORE INTO lecture_file_weeks(file_id, course_id, week_monday, lecture_week, doc_type, rule, detail, assigned_at)
                VALUES (?,?,?,?,?,?,?,?)
                """, [.text(a.fileID), .text(courseID), a.monday.map { .text(BerlinClock.isoDate($0)) } ?? .null,
                      a.lectureWeek.map { .integer(Int64($0)) } ?? .null, .text(a.docType), .text(a.rule.rawValue), .text(a.detail), .text(now)])
        }
        return result
    }

    // MARK: Anzeige

    /// Gespeicherte Zuordnung einer Datei fuer die Anzeige
    public struct Stored: Sendable, Equatable {
        public let monday: Int?
        public let docType: String?
        /// Ende der Vorlesungszeit des Kurses (aeltere Semester: "Ältere Unterlagen")
        public let termEnd: Int?
        /// Regel und Begruendung der Zuordnung (`Rule`, z. B. "allgemein" / "ohne Hinweis")
        public var rule: String? = nil
        public var detail: String? = nil

        /// Unsicher: keine Woche aus Abschnitt, Name oder Datum (ohne Hinweis, Datum ausserhalb der Vorlesungszeit) ->
        /// im Moduldetail "Nicht zugeordnet" (`ModuleLayout`), Allgemein-Material und Klausuren nicht
        public var unsure: Bool {
            guard monday == nil, rule == Rule.general.rawValue, let d = detail else { return false }
            return d == "ohne Hinweis" || d.hasPrefix("Datum ")
        }
    }

    /// Alle gespeicherten Zuordnungen (leer ohne Tabelle, z. B. Stud.IP der LUH)
    public static func stored(_ c: SQLiteConnection) throws -> [String: Stored] {
        guard try hasTables(c) else { return [:] }
        var out: [String: Stored] = [:]
        for r in try c.query("""
            SELECT w.file_id, w.week_monday, w.doc_type, w.rule, w.detail, t.lecture_end FROM lecture_file_weeks w
            LEFT JOIN lecture_course_terms t ON t.course_id=w.course_id
            """) {
            guard let id = r["file_id"]?.string else { continue }
            out[id] = Stored(monday: (r["week_monday"]?.string).flatMap(BerlinClock.parseISODate), docType: r["doc_type"]?.string,
                             termEnd: (r["lecture_end"]?.string).flatMap(BerlinClock.parseISODate),
                             rule: r["rule"]?.string, detail: r["detail"]?.string)
        }
        return out
    }

    /// Art aus der Zuordnung, wenn Name und Ordner allein nichts sagen (Moodle-Ressource "Übungsblatt 3" mit der
    /// Datei "aufgaben.pdf" -> sonst "Sonstiges"); eine Einschaetzung der KI geht vor
    static func withStoredType(_ f: [String: JSONValue], stored: [String: Stored]) -> [String: JSONValue] {
        guard f["doc_type"]?.string == "sonstiges", f["ai_doc_type"]?.string?.isEmpty ?? true, let id = f["id"]?.string,
              let t = stored[id]?.docType, StudyClassify.lectureWeekTypes.contains(t) else { return f }
        var out = f
        out["doc_type"] = .string(t)
        out["sub_label"] = .string(StudyClassify.typeLabels[t] ?? "Sonstiges")
        return out
    }

    /// Semester der aktiven Kurse (das haeufigste; bei Gleichstand das neueste), nil ohne gemerktes Semester
    public static func currentTerm(_ c: SQLiteConnection) throws -> Term? {
        guard try hasTables(c) else { return nil }
        guard let r = try c.queryOne("""
            SELECT t.semester, t.lecture_start, t.lecture_end, t.breaks, t.source, COUNT(*) AS n FROM lecture_course_terms t
            JOIN courses c ON c.id=t.course_id WHERE COALESCE(c.active, 1)=1
            GROUP BY t.lecture_start, t.lecture_end ORDER BY n DESC, t.lecture_start DESC LIMIT 1
            """) else { return nil }
        return term(row: r)
    }

    /// Woche im Moduldetail (Index ab `start` wie `StudyWeeks.dayWeek`): "Allgemein", "Ältere Unterlagen" fuer
    /// Kurse eines frueheren Semesters, sonst die Woche des gespeicherten Montags
    static func displayWeek(_ s: Stored, start: Int) -> Int {
        if let end = s.termEnd, end < start { return -1 }
        guard let m = s.monday else { return generalWeek }
        let w = BerlinClock.floorDiv(m - start, 7) + 1
        return w < 1 ? -1 : w
    }

    /// Bezeichnung einer Woche, wenn das Semester bekannt ist: Nummer der Lehrwoche ohne Pausenwochen
    /// ("Woche 14 · 04.01. – 10.01." statt Woche 16 nach der Weihnachtspause)
    public static func weekLabel(start: Int, week w: Int, term: Term?) -> String {
        guard let term, w >= 1 else { return StudyWeeks.weekLabel(start: start, week: w) }
        let m = start + 7 * (w - 1)
        let dates = "\(StudyWeeks.dayMonth(m)) – \(StudyWeeks.dayMonth(m + 6))"
        if term.isBreakWeek(monday: m) { return "Vorlesungsfrei · \(dates)" }
        guard m >= term.firstMonday, let n = term.lectureWeek(ofMonday: m) else { return StudyWeeks.weekLabel(start: start, week: w) }
        return "Woche \(n) · \(dates)"
    }

    /// `Last-Modified`/`Date` im HTTP-Format ("Wed, 21 Oct 2026 07:28:00 GMT") -> Unix-Zeit
    public static func parseHTTPDate(_ s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return Int(d.timeIntervalSince1970) }
        }
        return nil
    }
}
