import Foundation

/// Abgaben, Tests und Pruefungstermine in Texten erkennen (Seitentexte der PDFs, Dateinamen, Ankuendigungen), ohne KI
/// und nur auf dem Geraet; am PC gibt es das nicht. Reine Funktion: Text und Rahmen hinein, Treffer heraus. Den Lauf
/// ueber die Datenbank macht `DueStore`.
///
/// Regeln (lieber weniger, dafuer richtige Treffer):
/// - Ein Treffer braucht ein Schluesselwort (Abgabe, Testat, Kurzklausur, Anmeldung ... deutsch und englisch) und ein
///   Datum nah beieinander: gleicher Satz bzw. gleiche Tabellenzeile, hoechstens sechs Woerter dazwischen. Ueber einen
///   Zeilenumbruch nur, wenn der Satz erkennbar weiterlaeuft ("... Zwischentest am" / "16.11.2026 im Hörsaal") oder
///   Datum und Schluesselwort je allein am Zeilenende bzw. -anfang stehen (Tabellenzelle je Zeile).
/// - Jedes Datum gehoert hoechstens zu einem Schluesselwort (das naechste gewinnt), jedes Schluesselwort zu einem
///   Datum, ausser bei Datumslisten ("am 02.11., 16.11. und 30.11.").
/// - Daten: 02.11.2026, 02.11.26, 02.11., 2.11., 2. November (2026), Mo, 16.11., Fr, 11.12.2026, ISO, englisch mit
///   Jahr; Bereiche (02.11.–06.11.); Uhrzeit direkt danach (bis 23:59 Uhr, 12:00, 10 Uhr, 11:59 PM).
/// - Jahr ohne Angabe: das Jahr, in dem der Tag im erlaubten Zeitraum liegt (laufendes Semester plus Pruefungszeit,
///   `Window`) und nah am Bezugstag (Aenderung der Datei, Tag der Ankuendigung); passt ein genannter Wochentag nicht,
///   gilt das Datum nicht. Daten ausserhalb des Zeitraums fallen weg (alte Semester).
/// - Kein Datum: "Aufgabe 2.1.", "Kapitel 3.11.", "Folien vom 02.11.", "Stand: 01.10.2026". Kein Termin: Loesungen,
///   Ergebnisse, Rueckgabe oder Einsicht zu einem Test.
/// - Ueberschrift: eine Zeile nur aus Aufzaehlungszeichen und Schluesselwort ("◼ Kurzklausurtermin") bekommt das erste
///   Datum ihrer Unterpunkte bis zum naechsten Hauptpunkt, eines nach "Datum:"/"Termin:" zuerst (`headingDate`).
/// - Semesterplan mit Spalte "Testate": "T1: ... 16.11 bis 19.11." ist ein Testat am ersten Tag, das Ende steht in der
///   Bezeichnung; das Datum der Vorlesung davor gehoert nicht dazu (`testatTables`).
/// - Englisch klein "test"/"tests" nur mit Pruefungsbezug ("test on <Datum>", "test: <Datum>", exam/quiz/midterm im
///   Satz), nicht in Wortgruppen ("unit tests", "tests for") und nicht in einer Aufzaehlung in Klammern.
/// - Bereich direkt nach "Klausuren"/"Pruefungen" ist kein Klausurtag, nach "Pruefungszeitraum" nie ein Termin; ist in
///   den zwei Saetzen davor von der Anmeldung die Rede (ohne eigenes Datum), ist er die Anmeldung (Ende zaehlt).
///
/// `Announcements.extractDates` (app/announcements.py) ist dafuer nur teilweise wiederverwendbar: Monatsnamen und Text
/// aus HTML kommen von dort; die Art bestimmt es aus dem ganzen Satz, ohne Abstand zum Schluesselwort, und das Jahr nur
/// aus dem Tag der Ankuendigung. Dessen Ergebnis (`announcements.dates`, Hinweise im Kalender) bleibt unveraendert.
public enum DueDetection {

    /// Art eines erkannten Termins
    public enum Kind: String, Sendable, CaseIterable {
        case abgabe, test, klausur, anmeldung, sonstiges

        /// Vorrang bei gleichem Abstand
        var rank: Int {
            switch self {
            case .klausur: return 0
            case .test: return 1
            case .abgabe: return 2
            case .anmeldung: return 3
            case .sonstiges: return 4
            }
        }

        /// Bezeichnung, wenn das Schluesselwort selbst keine bessere hergibt
        public var label: String {
            switch self {
            case .abgabe: return "Abgabe"
            case .test: return "Test"
            case .klausur: return "Klausur"
            case .anmeldung: return "Anmeldung"
            case .sonstiges: return "Frist"
            }
        }
    }

    /// Ein erkannter Termin in einem Text
    public struct Hit: Sendable, Equatable {
        /// "YYYY-MM-DD"
        public var date: String
        /// "HH:MM" oder nil
        public var time: String?
        public var kind: Kind
        /// z. B. "Kurzklausur", "Kurztestat 2", "Abgabe Blatt 3"
        public var label: String
        /// Zeile bzw. Satz um den Treffer (hoechstens 160 Zeichen)
        public var snippet: String

        public init(date: String, time: String?, kind: Kind, label: String, snippet: String) {
            self.date = date
            self.time = time
            self.kind = kind
            self.label = label
            self.snippet = snippet
        }
    }

    /// Semester als (Winter?, Jahr des Beginns): "WiSe 2026/27" -> (true, 2026), "SoSe 2027" -> (false, 2027)
    public struct SemesterKey: Hashable, Sendable, CustomStringConvertible {
        public let winter: Bool
        public let year: Int

        public init(winter: Bool, year: Int) {
            self.winter = winter
            self.year = year
        }

        public var description: String { winter ? "WiSe \(year)/\(String(format: "%02d", (year + 1) % 100))" : "SoSe \(year)" }
    }

    /// Erlaubter Zeitraum: laufendes Semester (Vorlesungszeit) plus Pruefungszeit bis zum Beginn des naechsten;
    /// Tagesnummern wie `BerlinClock`
    public struct Window: Sendable, Equatable {
        public let from: Int
        public let to: Int
        /// heute (fuer die Wahl des Jahres, wenn zwei passen)
        public let today: Int
        /// laufende Semester (am Uebergang zwei): der Kopf eines Dokuments muss eines davon nennen, wenn er eines nennt
        public let semesters: Set<SemesterKey>

        public init(from: Int, to: Int, today: Int, semesters: Set<SemesterKey>) {
            self.from = from
            self.to = to
            self.today = today
            self.semesters = semesters
        }

        /// Tage vor Vorlesungsbeginn, die schon zum Semester gehoeren (Anmeldungen, erste Abgaben)
        static let lead = 21
        /// Pruefungszeit nach dem letzten bekannten Semester (ohne Folgesemester im Zeitplan)
        static let examTail = 70

        /// Laufende Semester laut Zeitplan der Hochschule (`Holidays.semesters`) und aktivem Semester der App
        /// (`terms`): je Semester von 21 Tagen vor Vorlesungsbeginn bis zum Tag vor dem Beginn des naechsten. Am
        /// Uebergang gelten beide. nil, wenn nichts bekannt ist.
        public static func current(university: String, today: Int, term: (name: String, start: String, end: String)? = nil) -> Window? {
            var spans: [(from: Int, to: Int, key: SemesterKey?)] = []
            let sems = Holidays.semesters[university] ?? []
            for (i, s) in sems.enumerated() {
                guard let a = BerlinClock.parseISODate(s.start), let e = BerlinClock.parseISODate(s.end) else { continue }
                let next = i + 1 < sems.count ? BerlinClock.parseISODate(sems[i + 1].start) : nil
                spans.append((a - lead, next.map { $0 - 1 } ?? e + examTail, DueDetection.semesters(in: s.name).first))
            }
            if let term, let a = BerlinClock.parseISODate(term.start), let e = BerlinClock.parseISODate(term.end), a <= e {
                spans.append((a - lead, e + examTail, DueDetection.semesters(in: term.name).first))
            }
            var hits = spans.filter { $0.from <= today && today <= $0.to }
            // vor dem ersten bekannten Semester: das naechste
            if hits.isEmpty, let next = spans.filter({ $0.from > today }).min(by: { $0.from < $1.from }), next.from - today <= 60 {
                hits = [next]
            }
            guard !hits.isEmpty else { return nil }
            return Window(from: hits.map(\.from).min() ?? today, to: hits.map(\.to).max() ?? today, today: today,
                          semesters: Set(hits.compactMap(\.key)))
        }

        func contains(_ day: Int) -> Bool { from <= day && day <= to }
    }

    /// Rahmen fuer einen Text
    public struct Context: Sendable {
        public var window: Window
        /// Bezugstag (Aenderung der Datei, Tag der Ankuendigung): ein Datum ohne Jahr liegt hoechstens 45 Tage davor
        /// und 300 Tage danach. nil: nur der Zeitraum zaehlt.
        public var reference: Int?
        /// Dateiname (fuer "Abgabe Blatt 3", wenn der Text selbst kein Blatt nennt)
        public var name: String?
        /// Kopf des Dokuments (erste Zeilen der ersten Seite, z. B. "Übungsblatt 6"), ebenso fuer die Bezeichnung
        public var head: String?
        /// Daten ohne Jahr gelten (nein bei Loesungen und Altklausuren)
        public var allowYearless: Bool
        /// Tests und Klausuren gelten (nein bei Loesungen und Altklausuren: dort stehen alte Termine)
        public var allowExams: Bool

        public init(window: Window, reference: Int? = nil, name: String? = nil, head: String? = nil, allowYearless: Bool = true,
                    allowExams: Bool = true) {
            self.window = window
            self.reference = reference
            self.name = name
            self.head = head
            self.allowYearless = allowYearless
            self.allowExams = allowExams
        }
    }

    // MARK: - Semester im Text

    private static let semesterRE = HText.regex(
        #"(?<![\p{L}])(wintersemester|winter\s+semester|winter\s+term|wise|ws|sommersemester|summer\s+semester|summer\s+term|sose|ss)\s*\.?\s*(20\d{2}|\d{2})(?:\s*/\s*(20\d{2}|\d{2}))?(?![\d])"#,
        [.caseInsensitive])

    /// Genannte Semester in Reihenfolge ("Wintersemester 2020/21", "WS 20/21", "WiSe 2026/27", "SoSe 2022", "SS22")
    public static func semesters(in text: String) -> [SemesterKey] {
        let ns = text as NSString
        var out: [SemesterKey] = []
        for m in semesterRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1)).lowercased()
            let y = ns.substring(with: m.range(at: 2))
            guard var year = Int(y) else { continue }
            if y.count == 2 {
                guard (10...60).contains(year) else { continue }
                year += 2000
            }
            let winter = word.hasPrefix("w")
            // "WS 2026/27": zweites Jahr muss das folgende sein, sonst ist es keine Semesterangabe
            if m.range(at: 3).location != NSNotFound, let second = Int(ns.substring(with: m.range(at: 3))) {
                guard winter, second % 100 == (year + 1) % 100 else { continue }
            }
            let key = SemesterKey(winter: winter, year: year)
            if !out.contains(key) { out.append(key) }
        }
        return out
    }

    /// Erste zwei Zeilen eines Texts (Kopf einer Seite), hoechstens 120 Zeichen
    public static func headLines(_ text: String?) -> String? {
        guard let t = text else { return nil }
        return String(t.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: true).prefix(2).joined(separator: "\n").prefix(120))
    }

    /// Semester im Kopf eines Dokuments (erste 600 Zeichen der ersten Seite) bzw. im Dateinamen
    public static func headSemester(firstPage: String?, name: String?) -> SemesterKey? {
        if let p = firstPage, let s = semesters(in: String(p.prefix(600))).first { return s }
        if let n = name, let s = semesters(in: n.replacingOccurrences(of: "_", with: " ")).first { return s }
        return nil
    }

    // MARK: - Text vorbereiten

    private static let softHyphenLowerRE = HText.regex(#"(\p{L})-[ \t]*\n[ \t]*(\p{Ll})"#)
    private static let hyphenUpperRE = HText.regex(#"(\p{L})-[ \t]*\n[ \t]*(\p{Lu})"#)
    private static let spacesRE = HText.regex(#"[ \t\x{A0}\x{2007}\x{202F}\x{2009}]+"#)

    /// Zerlegte Umlaute (pypdf/PDFKit), Ligaturen, Trennstriche am Zeilenende ("Abga-\nbe" -> "Abgabe",
    /// "Probe-\nKurztest" -> "Probe-Kurztest"), Seitenumbruch als Absatz, Leerraum zusammengezogen
    static func prepare(_ raw: String) -> String {
        var t = ScriptSearch.normalize(raw).precomposedStringWithCompatibilityMapping
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{C}", with: "\n\n").replacingOccurrences(of: "\u{AD}", with: "")
        t = HText.replace(softHyphenLowerRE, in: t, with: "$1$2")
        t = HText.replace(hyphenUpperRE, in: t, with: "$1-$2")
        return HText.replace(spacesRE, in: t, with: " ")
    }

    // MARK: - Daten

    /// Tag, Monat, Jahr (falls genannt), Wochentag (0 = Montag, falls genannt)
    struct Parts: Equatable {
        var day: Int
        var month: Int
        var year: Int?
        var weekday: Int?
    }

    struct DateToken {
        /// ganze Angabe: Wochentag, Datum bzw. Bereich, Uhrzeit
        var range: NSRange
        /// Beginn des eigentlichen Datums (ohne Wochentag) fuer den Kontext davor
        var coreStart: Int
        var start: Parts
        var end: Parts?
        var time: String?
    }

    private static let numericRE = HText.regex(#"(?<![\p{L}\p{N}./])(\d{1,2})\.\s?(\d{1,2})\.(?:\s?(20\d{2})(?![\d])|(\d{2})(?![\d.:]))?(?![\d])"#)
    /// "16.11" direkt vor "bis 19.11." bzw. "- 19.11." (Semesterplaene)
    private static let openStartRE = HText.regex(
        #"(?<![\p{L}\p{N}./])(\d{1,2})\.(\d{1,2})(?=\s*(?:-|–|—|bis)\s*(?:\p{L}{2,10}\.?,?\s*)?\d{1,2}\.\s?\d{1,2}\.)"#, [.caseInsensitive])
    private static let isoRE = HText.regex(#"(?<![\d\-./])(20\d{2})-(\d{2})-(\d{2})(?![\d\-])(?:[T ](\d{2}):(\d{2}))?"#)
    private static let germanMonthRE: NSRegularExpression = {
        let names = Announcements.months.map(\.0).sorted { $0.count > $1.count }.joined(separator: "|")
        return HText.regex(#"(?<![\p{L}\p{N}.])(\d{1,2})\.\s?("# + names + #")\.?(?:\s+(20\d{2})(?![\d]))?(?![\p{L}])"#, [.caseInsensitive])
    }()
    static let englishMonths: [(String, Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("may", 5), ("june", 6), ("july", 7), ("august", 8),
        ("september", 9), ("october", 10), ("november", 11), ("december", 12), ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4),
        ("jun", 6), ("jul", 7), ("aug", 8), ("sept", 9), ("sep", 9), ("oct", 10), ("nov", 11), ("dec", 12),
    ]
    private static let englishNames = englishMonths.map(\.0).sorted { $0.count > $1.count }.joined(separator: "|")
    private static let englishDayMonthRE = HText.regex(#"(?<![\p{L}\p{N}.])(\d{1,2})(?:st|nd|rd|th)?\s+("# + englishNames + #")\.?,?\s+(20\d{2})(?![\d])"#, [.caseInsensitive])
    private static let englishMonthDayRE = HText.regex(#"(?<![\p{L}])("# + englishNames + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(20\d{2})(?![\d])"#, [.caseInsensitive])

    private static let weekdayLongRE = HText.regex(#"(?<![\p{L}])(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonnabend|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\.?,?\s*(?:(?:den|dem|the)\s+)?$"#, [.caseInsensitive])
    private static let weekdayShortRE = HText.regex(#"(?<![\p{L}])(Mo|Di|Mi|Do|Fr|Sa|So|Mon|Tue|Tues|Wed|Thu|Thur|Thurs|Fri|Sat|Sun|MO|DI|MI|DO|FR|SA|SO)\.?,?\s*(?:(?:den|dem|the)\s+)?$"#)
    static let weekdays: [String: Int] = [
        "montag": 0, "dienstag": 1, "mittwoch": 2, "donnerstag": 3, "freitag": 4, "samstag": 5, "sonnabend": 5, "sonntag": 6,
        "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3, "friday": 4, "saturday": 5, "sunday": 6,
        "mo": 0, "di": 1, "mi": 2, "do": 3, "fr": 4, "sa": 5, "so": 6,
        "mon": 0, "tue": 1, "tues": 1, "wed": 2, "thu": 3, "thur": 3, "thurs": 3, "fri": 4, "sat": 5, "sun": 6,
    ]

    /// Woerter direkt vor "2.1." usw., nach denen eine Nummer und kein Datum steht
    private static let numberingRE = HText.regex(
        #"(?<![\p{L}])(?:aufgabe|aufg|teilaufgabe|kapitel|kap|abschnitt|satz|lemma|definition|def|abbildung|abb|tabelle|tab|folie|seite|s|nr|no|gleichung|gl|beispiel|bsp|theorem|korollar|proposition|bemerkung|exercise|problem|section|chapter|(?:ü|ue)bung|blatt|teil|version|v|§)\s*\.?\s*$"#,
        [.caseInsensitive])
    private static let rangeGapRE = HText.regex(#"^\s*(?:-|–|—|bis(?:\s+(?:zum|einschlie(?:ß|ss)lich|einschl\.))?|to|until|till)\s*$"#, [.caseInsensitive])
    private static let timeRE = HText.regex(
        #"^\s*(?:[,(]|–|-)?\s*(?:(?:um|bis|ab|gegen|at|by|until)\s+)?(?:sp(?:ä|ae)testens\s+)?(\d{1,2})(?::(\d{2})|\.(\d{2})(?=\s*(?:Uhr|h\b))|(?=\s*(?:Uhr|h\b|[-–]\s*\d{1,2}(?:[:.]\d{2})?\s*Uhr)))\s*(?:Uhr|h\b)?\s*\)?\s*(a\.?m\.?|p\.?m\.?)?"#,
        [.caseInsensitive])

    static func valid(_ p: Parts, year: Int) -> Int? {
        guard (1...12).contains(p.month), p.day >= 1, p.day <= BerlinClock.daysInMonth(year: year, month: p.month) else { return nil }
        return BerlinClock.dayNumber(year: year, month: p.month, day: p.day)
    }

    /// Alle Datumsangaben eines Texts, nach Position, ohne Ueberlappungen; mit Wochentag davor, Bereich und Uhrzeit
    static func findDates(_ text: String) -> [DateToken] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        var found: [(range: NSRange, parts: Parts, time: String?)] = []
        var numberingEnd = -1                                // Ende der letzten Nummer ("Aufgabe 3.11. und 3.12.")
        // Beginn eines Bereichs ohne Punkt nach dem Monat ("16.11 bis 19.11."): gilt nur, wenn daraus ein Bereich wird
        var openStarts = Set<Int>()
        let numeric = (numericRE.matches(in: text, range: full).map { ($0, false) } + openStartRE.matches(in: text, range: full).map { ($0, true) })
            .sorted { $0.0.range.location < $1.0.range.location }
        for (m, open) in numeric {
            guard let d = group(m, 1).flatMap(Int.init), let mo = group(m, 2).flatMap(Int.init) else { continue }
            if open { openStarts.insert(m.range.location) }
            var year: Int?
            if !open, let y = group(m, 3) { year = Int(y) } else if !open, let y = group(m, 4), let n = Int(y) { year = 2000 + n }
            if year == nil {
                // "2.1." ohne Jahr: fast immer eine Nummer (Aufgabe 2.1.); ebenso nach "Aufgabe", "Kapitel" ... und in
                // einer Aufzaehlung direkt dahinter
                var numbering = group(m, 1)!.count == 1 && group(m, 2)!.count == 1
                let lo = max(0, m.range.location - 16)
                let before = ns.substring(with: NSRange(location: lo, length: m.range.location - lo))
                if numberingRE.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil { numbering = true }
                if numberingEnd >= 0, m.range.location - numberingEnd <= 12,
                   has(listGapRE, ns.substring(with: NSRange(location: numberingEnd, length: m.range.location - numberingEnd))) { numbering = true }
                if numbering {
                    numberingEnd = NSMaxRange(m.range)
                    continue
                }
            }
            found.append((m.range, Parts(day: d, month: mo, year: year), nil))
        }
        for m in isoRE.matches(in: text, range: full) {
            guard let y = group(m, 1).flatMap(Int.init), let mo = group(m, 2).flatMap(Int.init), let d = group(m, 3).flatMap(Int.init) else { continue }
            var time: String?
            if let h = group(m, 4).flatMap(Int.init), let mi = group(m, 5).flatMap(Int.init), (0...23).contains(h), (0...59).contains(mi) {
                time = String(format: "%02d:%02d", h, mi)
            }
            found.append((m.range, Parts(day: d, month: mo, year: y), time))
        }
        for m in germanMonthRE.matches(in: text, range: full) {
            guard let d = group(m, 1).flatMap(Int.init), let name = group(m, 2), let mo = Announcements.monthByName[name.lowercased()] else { continue }
            found.append((m.range, Parts(day: d, month: mo, year: group(m, 3).flatMap(Int.init)), nil))
        }
        let english = Dictionary(englishMonths, uniquingKeysWith: { a, _ in a })
        for m in englishDayMonthRE.matches(in: text, range: full) {
            guard let d = group(m, 1).flatMap(Int.init), let mo = group(m, 2).flatMap({ english[$0.lowercased()] }) else { continue }
            found.append((m.range, Parts(day: d, month: mo, year: group(m, 3).flatMap(Int.init)), nil))
        }
        for m in englishMonthDayRE.matches(in: text, range: full) {
            guard let mo = group(m, 1).flatMap({ english[$0.lowercased()] }), let d = group(m, 2).flatMap(Int.init) else { continue }
            found.append((m.range, Parts(day: d, month: mo, year: group(m, 3).flatMap(Int.init)), nil))
        }
        // Ueberlappungen: der fruehere, bei gleichem Beginn der laengere
        found.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        var tokens: [DateToken] = []
        var lastEnd = -1
        for f in found where f.range.location >= lastEnd {
            var t = DateToken(range: f.range, coreStart: f.range.location, start: f.parts, end: nil, time: f.time)
            // Wochentag davor ("Fr, 11.12.2026", "Montag, den 2. November")
            let lo = max(0, f.range.location - 18), before = ns.substring(with: NSRange(location: lo, length: f.range.location - lo))
            let bns = before as NSString
            for re in [weekdayLongRE, weekdayShortRE] {
                if let w = re.firstMatch(in: before, range: NSRange(location: 0, length: bns.length)),
                   let wd = weekdays[bns.substring(with: w.range(at: 1)).lowercased()] {
                    t.start.weekday = wd
                    let shift = bns.length - w.range.location
                    t.range = NSRange(location: f.range.location - shift, length: f.range.length + shift)
                    break
                }
            }
            tokens.append(t)
            lastEnd = NSMaxRange(f.range)
        }
        // Bereiche: "02.11.–06.11.", "vom 02.11. bis 06.11.2026"
        var merged: [DateToken] = []
        for t in tokens {
            if var prev = merged.last, prev.end == nil, prev.time == nil {
                let gapStart = NSMaxRange(prev.range), gapLen = t.range.location - gapStart
                if gapLen >= 0, gapLen <= 16 {
                    let gap = ns.substring(with: NSRange(location: gapStart, length: gapLen))
                    if rangeGapRE.firstMatch(in: gap, range: NSRange(location: 0, length: (gap as NSString).length)) != nil {
                        prev.end = t.start
                        if prev.start.year == nil, let y = t.start.year {
                            // "28.12.–08.01.2027": Beginn im Vorjahr, wenn sein Monat spaeter liegt
                            prev.start.year = prev.start.month > t.start.month ? y - 1 : y
                        }
                        prev.range = NSRange(location: prev.range.location, length: NSMaxRange(t.range) - prev.range.location)
                        prev.time = t.time
                        merged[merged.count - 1] = prev
                        continue
                    }
                }
            }
            merged.append(t)
        }
        merged.removeAll { $0.end == nil && openStarts.contains($0.coreStart) }
        // Uhrzeit direkt danach
        for i in merged.indices where merged[i].time == nil {
            let a = NSMaxRange(merged[i].range), len = min(34, ns.length - a)
            guard len > 0 else { continue }
            let tail = ns.substring(with: NSRange(location: a, length: len))
            let tns = tail as NSString
            guard let m = timeRE.firstMatch(in: tail, options: [.anchored], range: NSRange(location: 0, length: tns.length)),
                  var h = Int(tns.substring(with: m.range(at: 1))) else { continue }
            var mi = 0
            for g in [2, 3] where m.range(at: g).location != NSNotFound { mi = Int(tns.substring(with: m.range(at: g))) ?? 99 }
            if m.range(at: 4).location != NSNotFound {
                let ap = tns.substring(with: m.range(at: 4)).lowercased()
                if ap.hasPrefix("p"), h < 12 { h += 12 }
                if ap.hasPrefix("a"), h == 12 { h = 0 }
            }
            if h == 24, mi == 0 { h = 23; mi = 59 }
            guard (0...23).contains(h), (0...59).contains(mi) else { continue }
            // eine folgende Datumsangabe ist keine Uhrzeit ("02.11., 16.11.")
            let consumed = m.range.length
            if merged.indices.contains(i + 1), merged[i + 1].range.location < a + consumed { continue }
            merged[i].time = String(format: "%02d:%02d", h, mi)
            merged[i].range.length += consumed
        }
        return merged
    }

    // MARK: - Schluesselwoerter

    /// Wo das Datum stehen darf
    enum Direction: Sendable {
        /// vor oder nach dem Schluesselwort
        case both
        /// nur danach: mehrdeutige Woerter ("Prüfung von Invarianten", "Test-Driven Development" hinter einem Datum)
        case dateAfter
        /// Hauptwort der Anmeldung: vor dem Wort nur ohne Komma dazwischen und nicht "Anmeldung über ..."
        case restrictedBefore
    }

    struct KeywordSpec {
        let pattern: String
        let kind: Kind
        let label: String
        let direction: Direction
        /// englisch klein ("test", "tests"): nur mit klarem Pruefungsbezug (`Keyword.weak`)
        let weakLowercase: Bool
        /// Zeitraum statt Termin ("Pruefungszeitraum"): nimmt nur Bereiche und ergibt selbst keinen Treffer
        let periodOnly: Bool

        init(pattern: String, kind: Kind, label: String, nounAfterRestricted: Bool, direction: Direction? = nil,
             weakLowercase: Bool = false, periodOnly: Bool = false) {
            self.pattern = pattern
            self.kind = kind
            self.label = label
            self.direction = direction ?? (nounAfterRestricted ? .restrictedBefore : .both)
            self.weakLowercase = weakLowercase
            self.periodOnly = periodOnly
        }
    }

    static let keywordSpecs: [KeywordSpec] = [
        KeywordSpec(pattern: #"(?:pr(?:ü|ue)fungs|klausur|test|testat)anmeldung(?:en)?"#, kind: .anmeldung, label: "Anmeldung", nounAfterRestricted: true),
        KeywordSpec(pattern: #"anmeldeschluss|anmeldefrist(?:en)?|anmeldezeitraum|anmeldephase"#, kind: .anmeldung, label: "Anmeldeschluss", nounAfterRestricted: false),
        KeywordSpec(pattern: #"abmeldefrist(?:en)?|abmeldeschluss|r(?:ü|ue)cktrittsfrist"#, kind: .anmeldung, label: "Abmeldefrist", nounAfterRestricted: false),
        KeywordSpec(pattern: #"anmeldung(?:en)?|registration(?:\s+deadline)?"#, kind: .anmeldung, label: "Anmeldung", nounAfterRestricted: true),
        KeywordSpec(pattern: #"anzumelden|anmelden"#, kind: .anmeldung, label: "Anmeldung", nounAfterRestricted: false),
        KeywordSpec(pattern: #"probe-?kurzklausur(?:en|termin(?:e)?)?"#, kind: .klausur, label: "Probe-Kurzklausur", nounAfterRestricted: false),
        KeywordSpec(pattern: #"kurzklausur(?:en|termin|termine)?"#, kind: .klausur, label: "Kurzklausur", nounAfterRestricted: false),
        KeywordSpec(pattern: #"probeklausur(?:en|termin(?:e)?)?"#, kind: .klausur, label: "Probeklausur", nounAfterRestricted: false),
        KeywordSpec(pattern: #"nachklausur(?:en|termin(?:e)?)?|wiederholungsklausur(?:en|termin(?:e)?)?"#, kind: .klausur, label: "Nachklausur", nounAfterRestricted: false),
        KeywordSpec(pattern: #"pr(?:ü|ue)fungs(?:zeitr(?:aum|(?:ä|ae)ume)|phase)|klausur(?:en)?(?:zeitr(?:aum|(?:ä|ae)ume)|phase)"#, kind: .klausur,
                    label: "Prüfungszeitraum", nounAfterRestricted: false, direction: .dateAfter, periodOnly: true),
        KeywordSpec(pattern: #"klausurtermin(?:e)?|klausurdatum|klausur(?:en)?"#, kind: .klausur, label: "Klausur", nounAfterRestricted: false),
        KeywordSpec(pattern: #"pr(?:ü|ue)fungstermin(?:e)?|pr(?:ü|ue)fungsdatum|(?:m(?:ü|ue)ndliche|schriftliche)\s+pr(?:ü|ue)fung(?:en)?"#, kind: .klausur, label: "Prüfung", nounAfterRestricted: false),
        KeywordSpec(pattern: #"pr(?:ü|ue)fung(?:en)?"#, kind: .klausur, label: "Prüfung", nounAfterRestricted: false, direction: .dateAfter),
        KeywordSpec(pattern: #"(?:final\s+|midterm\s+)?exam(?:s|ination)?|midterm"#, kind: .klausur, label: "Prüfung", nounAfterRestricted: false, direction: .dateAfter),
        KeywordSpec(pattern: #"probe-?kurztest(?:s|e|termin(?:e)?)?"#, kind: .test, label: "Probe-Kurztest", nounAfterRestricted: false),
        KeywordSpec(pattern: #"kurztestat(?:e|en|s|termin(?:e)?)?"#, kind: .test, label: "Kurztestat", nounAfterRestricted: false),
        KeywordSpec(pattern: #"kurztest(?:s|e|termin(?:e)?)?"#, kind: .test, label: "Kurztest", nounAfterRestricted: false),
        KeywordSpec(pattern: #"probetestat(?:e|en)?|testat(?:e|en|s|termin(?:e)?)?"#, kind: .test, label: "Testat", nounAfterRestricted: false),
        KeywordSpec(pattern: #"zwischentest(?:s|e|termin(?:e)?)?"#, kind: .test, label: "Zwischentest", nounAfterRestricted: false),
        KeywordSpec(pattern: #"online-?test(?:s)?|e-?test(?:s)?"#, kind: .test, label: "Online-Test", nounAfterRestricted: false),
        KeywordSpec(pattern: #"quiz(?:ze|zes)?"#, kind: .test, label: "Quiz", nounAfterRestricted: false, direction: .dateAfter),
        KeywordSpec(pattern: #"test(?:s|termin(?:e)?)?"#, kind: .test, label: "Test", nounAfterRestricted: false, direction: .dateAfter,
                    weakLowercase: true),
        KeywordSpec(pattern: #"(?:(?:ü|ue)bungsblatt|blatt)-?abgabe"#, kind: .abgabe, label: "Abgabe", nounAfterRestricted: false),
        KeywordSpec(pattern: #"abgabe(?:termin(?:e)?|frist(?:en)?|schluss|datum)|abgaben?"#, kind: .abgabe, label: "Abgabe", nounAfterRestricted: false),
        KeywordSpec(pattern: #"abzugeben|abgeben|abgegeben"#, kind: .abgabe, label: "Abgabe", nounAfterRestricted: false),
        KeywordSpec(pattern: #"einzureichen|einreichen|eingereicht|einreichungsfrist|einreichung(?:en)?"#, kind: .abgabe, label: "Abgabe", nounAfterRestricted: false),
        KeywordSpec(pattern: #"einsendeschluss"#, kind: .abgabe, label: "Einsendeschluss", nounAfterRestricted: false),
        KeywordSpec(pattern: #"deadlines?"#, kind: .abgabe, label: "Deadline", nounAfterRestricted: false),
        KeywordSpec(pattern: #"due(?:\s+date)?(?!\s+to\b)"#, kind: .abgabe, label: "Abgabe", nounAfterRestricted: false),
        KeywordSpec(pattern: #"submissions?(?:\s+deadline)?|submit(?:ted)?"#, kind: .abgabe, label: "Abgabe", nounAfterRestricted: false),
        KeywordSpec(pattern: #"assignments?"#, kind: .abgabe, label: "Assignment", nounAfterRestricted: false),
        KeywordSpec(pattern: #"hausaufgaben?|homework"#, kind: .abgabe, label: "Hausaufgabe", nounAfterRestricted: false),
        KeywordSpec(pattern: #"hausarbeit(?:en)?"#, kind: .abgabe, label: "Hausarbeit", nounAfterRestricted: false),
        KeywordSpec(pattern: #"fristende|fristen|frist|stichtag"#, kind: .sonstiges, label: "Frist", nounAfterRestricted: false, direction: .dateAfter),
    ]

    private static let keywordRE: NSRegularExpression = {
        HText.regex(#"(?<![\p{L}\p{N}])(?:"# + keywordSpecs.map { "(" + $0.pattern + ")" }.joined(separator: "|") + #")(?![\p{L}\p{N}])"#,
                    [.caseInsensitive])
    }()

    /// Teile des Musters fuer die Vorauswahl in SQL (Suchform: klein, Umlaute zusammengesetzt)
    static let likeTerms = ["abgabe", "abgeben", "abzugeben", "abgegeben", "einreich", "einzureich", "eingereicht", "einsendeschluss",
                            "deadline", "due", "submi", "assignment", "hausaufgabe", "hausarbeit", "homework", "testat", "test", "quiz",
                            "klausur", "prüfung", "pruefung", "exam", "midterm", "anmeld", "anzumelden", "registration",
                            "abmeldefrist", "rücktrittsfrist", "frist", "stichtag"]

    struct Keyword {
        var range: NSRange
        var kind: Kind
        var label: String
        var direction: Direction
        /// englisch klein "test"/"tests": zaehlt nur mit "on"/":" vor dem Datum oder einem Pruefungswort im Satz
        var weak = false
        /// Zeitraum ("Pruefungszeitraum"): nimmt nur Bereiche, ergibt keinen Treffer
        var periodOnly = false
    }

    /// Vor "test"/"tests": Wortgruppen wie "unit tests", "t-test", "write tests"
    private static let weakBeforeRE = HText.regex(
        #"(?<![\p{L}])(?:unit|integration|regression|smoke|acceptance|system|end-to-end|e2e|load|stress|performance|usability|property(?:-based)?|automated|automatic|statistical|hypothesis|significance|t|z|f|chi(?:-squared?)?|write|writing|run|running|pass|passing|failing|failed)[\s-]+$"#,
        [.caseInsensitive])
    /// Nach "test"/"tests": "tests for", "test cases", "test suite" ...
    private static let weakAfterRE = HText.regex(
        #"^\s+(?:for|of|cases?|suites?|data|coverage|driven|runs?|results?|files?|methods?|classes?|code|framework|harness|statistics?)(?![\p{L}])"#,
        [.caseInsensitive])
    /// zwischen "test" und Datum: "test on <Datum>", "test: <Datum>"
    private static let weakGapRE = HText.regex(
        #"^\s*(?::\s*|(?:(?:is|will\s+be|takes\s+place|is\s+held|will\s+be\s+held|will\s+take\s+place)\s+)?on\s+)(?:the\s+)?$"#,
        [.caseInsensitive])
    /// Pruefungswort im Satz vor "test"
    private static let examContextRE = HText.regex(#"(?<![\p{L}])(?:exams?|examinations?|quiz(?:zes)?|midterms?)(?![\p{L}])"#, [.caseInsensitive])

    /// Wort in einer Aufzaehlung in Klammern ("(Variablen, Funktionen, tests)"): offene Klammer davor (hoechstens 200
    /// Zeichen, auch ueber einen Zeilenumbruch, nicht ueber einen Absatz) und Komma, Semikolon oder "und"/"and" darin
    static func inParenList(_ ns: NSString, _ r: NSRange) -> Bool {
        var i = r.location - 1, open = -1
        while i >= 0, r.location - i <= 200 {
            let c = ns.character(at: i)
            if c == 41 || (c == 10 && i > 0 && ns.character(at: i - 1) == 10) { break }   // ")" oder Leerzeile
            if c == 40 { open = i; break }                                              // "("
            i -= 1
        }
        guard open >= 0 else { return false }
        var j = NSMaxRange(r)
        while j < ns.length, j - NSMaxRange(r) <= 200 {
            let c = ns.character(at: j)
            if c == 41 || c == 40 || (c == 10 && j + 1 < ns.length && ns.character(at: j + 1) == 10) { break }
            j += 1
        }
        let inner = ns.substring(with: NSRange(location: open + 1, length: j - open - 1))
        return inner.contains(",") || inner.contains(";") || has(parenAndRE, inner)
    }
    private static let parenAndRE = HText.regex(#"(?<![\p{L}])(?:und|and|sowie|or|oder)(?![\p{L}])"#, [.caseInsensitive])

    private static let headConnectorRE = HText.regex(#"^\s*(?:zur|zum|zu|f(?:ü|ue)r|der|des|von|for|of|to)(?:\s+(?:der|die|das|den|dem|the))?\s*$"#, [.caseInsensitive])
    private static let compoundRE = HText.regex(#"^\s*[-/]\s*$"#)
    private static let adjacentRE = HText.regex(#"^\s*$"#)

    /// Bindestrich-Woerter mit anderem Grundwort ("Klausur-Vorbereitung", "Test-Driven") sind kein Termin; erlaubt sind
    /// Woerter, die den Termin selbst meinen ("Kurztestat-Termin") und weitere Schluesselwoerter ("Klausur-Anmeldung")
    private static let compoundTailRE = HText.regex(#"^\s*-\s*(\p{L}+)"#)
    private static let dateTails: Set<String> = ["termin", "termine", "datum", "tag", "tage", "woche", "frist", "zeit", "zeitraum", "date", "deadline"]

    static func findKeywords(_ text: String) -> [Keyword] {
        let ns = text as NSString
        var out: [Keyword] = []
        let all = keywordRE.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for (n, m) in all.enumerated() {
            let a = NSMaxRange(m.range)
            let tail = ns.substring(with: NSRange(location: a, length: min(24, ns.length - a)))
            if let t = compoundTailRE.firstMatch(in: tail, options: [.anchored], range: NSRange(location: 0, length: (tail as NSString).length)) {
                let word = (tail as NSString).substring(with: t.range(at: 1)).lowercased()
                let nextIsKeyword = n + 1 < all.count && all[n + 1].range.location <= a + t.range(at: 1).location
                if !dateTails.contains(word) && !nextIsKeyword { continue }
            }
            for (i, spec) in keywordSpecs.enumerated() where m.range(at: i + 1).location != NSNotFound {
                var weak = false
                if spec.weakLowercase {
                    let word = ns.substring(with: m.range)
                    if word == "test" || word == "tests" {
                        // englisch klein: nicht in Wortgruppen ("unit tests", "tests for") und nicht in einer Aufzaehlung
                        // in Klammern ("(Schleifen, Felder, tests)")
                        let lo = max(0, m.range.location - 24)
                        let before = ns.substring(with: NSRange(location: lo, length: m.range.location - lo))
                        if has(weakBeforeRE, before) || has(weakAfterRE, tail) { break }
                        if !tail.drop(while: { $0 == " " }).hasPrefix(":"), inParenList(ns, m.range) { break }
                        weak = true
                    }
                }
                out.append(Keyword(range: m.range, kind: spec.kind, label: spec.label, direction: spec.direction, weak: weak,
                                   periodOnly: spec.periodOnly))
                break
            }
        }
        // Wortgruppen: "Anmeldung zur Klausur" -> Anmeldung, "Klausur-Anmeldung" -> Anmeldung, "Abgabe der Hausaufgabe" -> Abgabe
        var merged: [Keyword] = []
        for k in out {
            if var prev = merged.last {
                let gs = NSMaxRange(prev.range), gl = k.range.location - gs
                if gl >= 0, gl <= 16 {
                    let gap = ns.substring(with: NSRange(location: gs, length: gl)), gr = NSRange(location: 0, length: (gap as NSString).length)
                    var head: Keyword?
                    if headConnectorRE.firstMatch(in: gap, range: gr) != nil {
                        head = prev
                    } else if compoundRE.firstMatch(in: gap, range: gr) != nil {
                        head = k
                    } else if adjacentRE.firstMatch(in: gap, range: gr) != nil {
                        head = k.kind == .anmeldung ? k : prev
                    }
                    if let head {
                        // schwach nur, wenn beide Teile schwach sind ("exam/test" zaehlt)
                        prev = Keyword(range: NSRange(location: prev.range.location, length: NSMaxRange(k.range) - prev.range.location),
                                       kind: head.kind, label: head.label, direction: head.direction, weak: prev.weak && k.weak,
                                       periodOnly: head.periodOnly)
                        merged[merged.count - 1] = prev
                        continue
                    }
                }
            }
            merged.append(k)
        }
        return merged
    }

    // MARK: - Paare aus Schluesselwort und Datum

    private static let wordRE = HText.regex(#"[\p{L}\p{N}]+"#)
    private static let sentenceBreakRE = HText.regex(#"[!?;]|[)"“”»]\.(?=\s)|\n[ \t]*\n"#)
    /// Wort mit Punkt danach: Satzende, wenn das Wort lang ist oder ein Grossbuchstabe folgt (ausser Abkuerzungen)
    private static let wordDotRE = HText.regex(#"(\p{L}+)\.(?=\s|$)(\s+\p{Lu})?"#)
    static let abbreviations: Set<String> = ["bzw", "ca", "vgl", "inkl", "evtl", "ggf", "usw", "etc", "nr", "no", "dr", "prof", "abs", "kap",
                                             "bsp", "max", "min", "std", "tel", "str", "hr", "fr", "frau", "jan", "feb", "mär", "apr",
                                             "jun", "jul", "aug", "sep", "sept", "okt", "oct", "nov", "dez", "dec", "hrsg", "ws", "ss",
                                             "wise", "sose", "mo", "di", "mi", "do", "sa", "so", "abb", "tab", "aufg", "bzgl", "z", "b",
                                             "u", "a", "s", "d", "h", "o", "e", "i", "v", "ff", "f", "geb", "raum"]

    /// Satzenden in einem Text (Stelle direkt dahinter), ungeordnet; Regeln wie `sentenceBreak`
    static func sentenceEnds(_ s: String) -> [Int] {
        let ns = s as NSString, r = NSRange(location: 0, length: ns.length)
        return sentenceBreakRE.matches(in: s, range: r).map { NSMaxRange($0.range) }
            + wordDotRE.matches(in: s, range: r).filter { m in
                let w = ns.substring(with: m.range(at: 1)).lowercased()
                return !abbreviations.contains(w) && (w.count >= 4 || m.range(at: 2).location != NSNotFound)
            }.map { $0.range(at: 1).location + $0.range(at: 1).length + 1 }
    }

    /// Satzgrenze zwischen Schluesselwort und Datum ("... fällt aus. Die Abgabe ..."); Punkte von Abkuerzungen
    /// ("bzw.", "Nr.", "Prof.") und Datumsangaben zaehlen nicht
    static func sentenceBreak(_ gap: String) -> Bool {
        if has(sentenceBreakRE, gap) { return true }
        let ns = gap as NSString
        for m in wordDotRE.matches(in: gap, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1)).lowercased()
            if abbreviations.contains(word) { continue }
            if word.count >= 4 || m.range(at: 2).location != NSNotFound { return true }
        }
        return false
    }
    private static let commaRE = HText.regex(#","#)
    private static let connectorEndRE = HText.regex(#"(?:\b(?:am|bis|zum|vom|ab|ist|sind|on|by|until|at|due|den|sp(?:ä|ae)testens|termin|datum|date)|[:–\-])\s*$"#, [.caseInsensitive])
    private static let restrictedFollowRE = HText.regex(#"^\s*(?:(?:ü|ue)ber|via|unter|per|im|in|bei|beim|auf|online|through)\b"#, [.caseInsensitive])
    private static let blockedBeforeDateRE = HText.regex(
        #"(?:(?:folien?|foliensatz|vorlesung(?:en)?|skript|mitschrift|aufzeichnung|(?:(?:ü|ue)bungs)?blatt|kapitel|(?:ü|ue)bung|sitzung|stunde|tutorium)\s+(?:vom|von)|(?:stand|version|aktualisiert|erstellt|updated?|druckdatum|gedruckt|ver(?:ö|oe)ffentlicht|published)\b[^\p{L}]*(?:am|vom|on)?)\s*$"#,
        [.caseInsensitive])
    private static let examBlockRE = HText.regex(
        #"l(?:ö|oe)sung|musterl|solution|ergebnis|\bnoten\b|bewert|korrektur|korrigiert|r(?:ü|ue)ckgabe|zur(?:ü|ue)ckgegeben|einsicht|besprechung|altklausur|alte\s+klausur|klausur\s+aus\s+(?:dem|der)"#,
        [.caseInsensitive])
    private static let submissionBlockRE = HText.regex(#"r(?:ü|ue)ckgabe|zur(?:ü|ue)ckgegeben|korrigiert|bewertet|besprechung"#, [.caseInsensitive])
    private static let listGapRE = HText.regex(#"^\s*(?:,|;|/|&|\+|und|sowie|bzw\.?|oder|and|or)?\s*(?:(?:und|sowie|and)\s+)?$"#, [.caseInsensitive])
    private static let numberAfterRE = HText.regex(#"^\s*(?:Nr\.?\s*|No\.?\s*|#\s*)?(\d{1,2})(?![\d.,:/])"#, [.caseInsensitive])
    private static let sheetRE = HText.regex(
        #"(?<![\p{L}])(?:((?:(?:ü|ue)bungs)?blatt|sheet|(?:ü|ue)bung)|(assignment|hausaufgabe|homework))\s*(?:nr\.?\s*)?0*(\d{1,2})(?![\d.])"#,
        [.caseInsensitive])

    private static let hausarbeitRE = HText.regex(#"(?<![\p{L}])hausarbeit(?:en)?(?![\p{L}])"#, [.caseInsensitive])

    static func words(_ s: String) -> Int { wordRE.numberOfMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) }

    static func has(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Abstand eines Paars (kleiner ist besser); nil, wenn Schluesselwort und Datum nicht zusammengehoeren
    static func score(_ k: Keyword, _ d: DateToken, _ ns: NSString) -> Int? {
        let keywordFirst = k.range.location < d.range.location
        let gs = keywordFirst ? NSMaxRange(k.range) : NSMaxRange(d.range)
        let ge = keywordFirst ? d.range.location : k.range.location
        guard ge >= gs, ge - gs <= 160 else { return nil }
        let gap = ns.substring(with: NSRange(location: gs, length: ge - gs))
        if sentenceBreak(gap) { return nil }
        let lines = gap.components(separatedBy: "\n")
        guard lines.count <= 2 else { return nil }
        let n = words(gap)
        let comma = has(commaRE, gap)
        if !keywordFirst && k.direction == .dateAfter { return nil }
        // "Pruefungszeitraum" nimmt nur Bereiche ("Klausur in der Pruefungsphase am 03.02." bleibt der Klausur)
        if k.periodOnly && d.end == nil { return nil }
        if k.weak, !has(weakGapRE, gap) {
            // englisch klein: sonst nur mit Pruefungswort im selben Satz davor
            let lo = max(0, k.range.location - 100)
            var lead = ns.substring(with: NSRange(location: lo, length: k.range.location - lo))
            if let b = sentenceEnds(lead).max() { lead = String((lead as NSString).substring(from: b)) }
            guard has(examContextRE, lead) || has(examContextRE, gap) else { return nil }
        }
        if !keywordFirst && k.direction == .restrictedBefore {
            // "Fr, 11.12.2026, Anmeldung über Stud.IP": Hinweis zur Anmeldung, kein Anmeldeschluss
            if comma { return nil }
            let after = ns.substring(with: NSRange(location: NSMaxRange(k.range), length: min(24, ns.length - NSMaxRange(k.range))))
            if has(restrictedFollowRE, after) { return nil }
        }
        if lines.count == 2 {
            guard n <= 3 else { return nil }
            if keywordFirst {
                // Satz laeuft ueber die Zeile weiter ("... Zwischentest am" / "16.11.2026 im Hörsaal")
                guard words(lines[0]) <= 3, has(connectorEndRE, ns.substring(with: NSRange(location: k.range.location, length: k.range.length)) + lines[0]),
                      words(lines[1]) <= 1 else { return nil }
            } else {
                // Tabellenzelle je Zeile: Datum am Zeilenende, Schluesselwort am Anfang der naechsten
                guard words(lines[0]) == 0, words(lines[1]) <= 1 else { return nil }
            }
        }
        guard n <= 6 else { return nil }
        if keywordFirst, has(blockedBeforeDateRE, ns.substring(with: NSRange(location: gs, length: d.coreStart - gs))) { return nil }
        return n + (comma ? 2 : 0) + (lines.count == 2 ? 2 : 0) + (keywordFirst ? 0 : 1)
    }

    /// Tag eines Datums im Rahmen; nil, wenn es keinen passenden gibt
    static func resolve(_ p: Parts, _ ctx: Context) -> Int? {
        let w = ctx.window
        if let y = p.year {
            guard let n = valid(p, year: y), w.contains(n) else { return nil }
            if let wd = p.weekday, BerlinClock.weekday(n) != wd { return nil }
            return n
        }
        guard ctx.allowYearless else { return nil }
        let y0 = BerlinClock.civil(w.from).year, y1 = BerlinClock.civil(w.to).year
        var candidates: [Int] = []
        for y in y0...max(y0, y1) {
            guard let n = valid(p, year: y), w.contains(n) else { continue }
            if let wd = p.weekday, BerlinClock.weekday(n) != wd { continue }
            if let r = ctx.reference, n < r - 45 || n > r + 300 { continue }
            candidates.append(n)
        }
        let anchor = ctx.reference ?? w.today
        return candidates.min { abs($0 - anchor) < abs($1 - anchor) }
    }

    /// Zeile(n) um den Treffer, Leerraum zusammengezogen, hoechstens 160 Zeichen
    static func snippet(_ ns: NSString, from a: Int, to b: Int) -> String {
        var s = a, e = b
        while s > 0, ns.character(at: s - 1) != 10 { s -= 1 }
        while e < ns.length, ns.character(at: e) != 10 { e += 1 }
        let line = ns.substring(with: NSRange(location: s, length: e - s)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard line.count > 160 else { return line }
        // um die Fundstelle herum kuerzen
        let offset = ns.substring(with: NSRange(location: s, length: a - s)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").count
        let start = max(0, min(offset - 40, line.count - 158))
        let lo = line.index(line.startIndex, offsetBy: start), hi = line.index(lo, offsetBy: min(158, line.count - start))
        return (start > 0 ? "…" : "") + line[lo..<hi] + (hi < line.endIndex ? "…" : "")
    }

    /// Bezeichnung: Schluesselwort mit Nummer ("Kurztestat 2"); Abgaben mit Blatt aus der Zeile oder dem Dateinamen
    static func label(_ k: Keyword, _ ns: NSString, line: String, head: String, docHead: String?, name: String?) -> String {
        let a = NSMaxRange(k.range)
        let tail = ns.substring(with: NSRange(location: a, length: min(12, ns.length - a)))
        let tns = tail as NSString
        if k.kind != .abgabe || k.label != "Abgabe",
           let m = numberAfterRE.firstMatch(in: tail, options: [.anchored], range: NSRange(location: 0, length: tns.length)) {
            return k.label + " " + String(Int(tns.substring(with: m.range(at: 1))) ?? 0)
        }
        if k.label == "Abgabe", has(hausarbeitRE, line) { return "Hausarbeit" }
        if k.label == "Abgabe" {
            // Blatt aus der Zeile, dem Kopf der Seite oder dem Dateinamen ("Übungsblatt 3", "Assignment 4")
            for source in [line, head, docHead ?? "", (name ?? "").replacingOccurrences(of: "_", with: " ")] {
                let sns = source as NSString
                if let m = sheetRE.firstMatch(in: source, range: NSRange(location: 0, length: sns.length)) {
                    let n = String(Int(sns.substring(with: m.range(at: 3))) ?? 0)
                    if m.range(at: 2).location != NSNotFound {
                        let w = sns.substring(with: m.range(at: 2)).lowercased()
                        return (w == "assignment" ? "Assignment " : "Hausaufgabe ") + n
                    }
                    return "Abgabe Blatt " + n
                }
            }
        }
        return k.label
    }

    // MARK: - Ueberschriften mit Unterpunkten

    /// Hauptpunkte: beenden die Unterpunkte einer Ueberschrift ("◼", "●", "■")
    static let mainBullets: Set<unichar> = [0x25FC, 0x25CF, 0x25A0, 0x25FE, 0x2B1B, 0x26AB, 0x2B24]
    /// weitere Aufzaehlungszeichen ("❑", "-", "•", "◦", "▪", "–", "*", "➢" ...); dazu Zeichen aus dem privaten Bereich
    /// (Symbolschriften in PDFs)
    static let subBullets: Set<unichar> = [0x2751, 0x2752, 0x25A1, 0x25AA, 0x25AB, 0x25E6, 0x25CB, 0x2022, 0x2023, 0x2043, 0x2D, 0x2013,
                                           0x2014, 0x2A, 0xB7, 0x2713, 0x2714, 0x27A2, 0x27A4, 0x25BA, 0x25B8, 0x25B6, 0x25C7, 0x25C6,
                                           0x2756, 0x2192]

    static func isBullet(_ c: unichar) -> Bool { mainBullets.contains(c) || subBullets.contains(c) || (0xE000...0xF8FF).contains(c) }

    /// Beginn und Ende (ohne Zeilenumbruch) der Zeile um `pos`
    static func lineBounds(_ ns: NSString, _ pos: Int) -> (start: Int, end: Int) {
        var s = min(pos, ns.length), e = min(pos, ns.length)
        while s > 0, ns.character(at: s - 1) != 10 { s -= 1 }
        while e < ns.length, ns.character(at: e) != 10 { e += 1 }
        return (s, e)
    }

    /// Erstes Zeichen einer Zeile nach Leerraum; nil bei leerer Zeile
    static func firstVisible(_ ns: NSString, _ start: Int, _ end: Int) -> Int? {
        var i = start
        while i < end, ns.character(at: i) == 32 || ns.character(at: i) == 9 { i += 1 }
        return i < end ? i : nil
    }

    /// Rest einer Ueberschrift hinter dem Schluesselwort: hoechstens eine Nummer ("Kurztestat 2", "Abgabe Blatt 3") und ":"
    private static let headingTailRE = HText.regex(#"^\s*(?:(?:nr\.?|no\.?|#)?\s*\d{1,2}|(?:(?:ü|ue)bungs)?blatt\s*\d{1,2})?\s*:?\s*$"#, [.caseInsensitive])
    /// vor dem Datum eines Unterpunkts: "Datum:", "Termin:" (geht dem ersten Datum vor)
    private static let dateLabelRE = HText.regex(#"(?<![\p{L}])(?:datum|termin|zeitpunkt|wann|date|when)\s*:?\s*$"#, [.caseInsensitive])
    /// Unterpunkt, der mit einem anderen Ereignis beginnt ("❑ Vorlesung am 02.11. entfaellt", "◦ Ausgabe am 05.11.")
    private static let otherEventRE = HText.regex(
        #"^[^\p{L}\p{N}]*(?:(?:die|der|das|the)\s+)?(?:(?:erste|letzte|n(?:ä|ae)chste|first|last|next)\s+)?(?:vorlesung(?:en)?|(?:ü|ue)bung(?:en)?|tutori(?:um|en)|sprechstunde|sitzung|ausgabe|lecture|tutorial)(?![\p{L}])"#,
        [.caseInsensitive])
    /// Unterpunkt laeuft auf der naechsten Zeile weiter ("❑ Termin:" / "17.11.2026 ...")
    private static let continuedRE = HText.regex(#"(?:[:,]|(?<![\p{L}])(?:am|bis|vom|ab|den|on|by|until))\s*$"#, [.caseInsensitive])

    /// Ueberschrift aus Aufzaehlungszeichen und Schluesselwort ("◼ Kurzklausurtermin", auch ohne Zeichen, wenn die
    /// Unterpunkte welche haben), darunter Unterpunkte ("❑", "-", "•", "◦", Einrueckung) bis zum naechsten Hauptpunkt
    /// ("◼", "●"), zum naechsten Punkt mit dem Zeichen der Ueberschrift oder zur ersten Zeile, die kein Unterpunkt ist.
    /// nil: keine solche Ueberschrift. Sonst das Datum der Unterpunkte (.some(nil): keins): eines hinter "Datum:" oder
    /// "Termin:" geht vor, sonst das erste; eines, das in seiner Zeile ein eigenes Schluesselwort hat
    /// ("❑ Probeklausur am 26.11."), gehoert diesem.
    static func headingDate(_ ki: Int, _ keywords: [Keyword], _ dates: [DateToken], _ ns: NSString) -> Int?? {
        let k = keywords[ki]
        guard !k.weak, !k.periodOnly else { return nil }
        // vor dem Schluesselwort nur Aufzaehlungszeichen und Leerraum (rueckwaerts: bricht meist sofort ab)
        var headBullet: unichar?
        var i = k.range.location - 1
        while i >= 0, ns.character(at: i) != 10 {
            let c = ns.character(at: i)
            if c != 32 && c != 9 {
                guard isBullet(c) else { return nil }
                headBullet = c
            }
            i -= 1
        }
        let ls = i + 1
        let a = NSMaxRange(k.range)
        let le = lineBounds(ns, a).end
        guard has(headingTailRE, ns.substring(with: NSRange(location: a, length: le - a))) else { return nil }
        let headIndented = ls < ns.length && (ns.character(at: ls) == 32 || ns.character(at: ls) == 9)
        var lines: [(start: Int, end: Int)] = []
        var bulleted = false, continues = false
        var pos = le + 1
        while pos < ns.length, lines.count < 8 {
            let e = lineBounds(ns, pos).end
            guard let f = firstVisible(ns, pos, e) else { break }               // Leerzeile
            let c = ns.character(at: f)
            if mainBullets.contains(c) { break }                                 // naechster Hauptpunkt
            if let h = headBullet, c == h { break }                              // Nachbar der Ueberschrift
            if isBullet(c) {
                bulleted = true
            } else if !(f > pos && !headIndented) && !(continues && !lines.isEmpty) {
                break                                                            // weder eingerueckt noch Fortsetzung
            }
            lines.append((pos, e))
            continues = has(continuedRE, ns.substring(with: NSRange(location: pos, length: e - pos)))
            pos = e + 1
        }
        guard let lo = lines.first?.start, let hi = lines.last?.end, headBullet != nil || bulleted else { return nil }
        var first: Int?, labelled: Int?
        for (di, d) in dates.enumerated() where d.range.location >= lo && d.range.location < hi {
            let (s, e) = lineBounds(ns, d.range.location)
            let owned = keywords.indices.contains { j in
                j != ki && keywords[j].range.location >= s && keywords[j].range.location < e && score(keywords[j], d, ns) != nil
            }
            if owned { continue }
            // "Folien vom 02.11.", "Stand: ..." und Unterpunkte zu etwas anderem ("❑ Vorlesung am 02.11. entfaellt")
            let before = ns.substring(with: NSRange(location: s, length: d.coreStart - s))
            if has(blockedBeforeDateRE, before) || has(otherEventRE, before) { continue }
            if first == nil { first = di }
            let from = max(lo, d.range.location - 40)
            if labelled == nil, has(dateLabelRE, ns.substring(with: NSRange(location: from, length: d.range.location - from))) { labelled = di }
        }
        return .some(labelled ?? first)
    }

    // MARK: - Testate im Semesterplan

    /// Spaltenkoepfe einer Tabelle
    private static let tableColumnRE = HText.regex(
        #"(?<![\p{L}])(?:datum|termine?|themen?|inhalte?|woche|kw|vorlesung(?:en)?|vl|(?:gruppen)?(?:ü|ue)bung(?:en)?|tutorium|tutorien|date|topics?|week|lecture)(?![\p{L}])|(?:^|\s)#(?:\s|$)"#,
        [.caseInsensitive])
    private static let testatMarkerRE = HText.regex(#"(?<![\p{L}\p{N}])T ?(\d{1,2})(?=\s*:)"#)
    /// Zeile beginnt eine neue Tabellenzeile ("5 20.11. ...", "Mo 20.11. ...")
    private static let rowStartRE = HText.regex(#"^\s*(?:\d{1,2}\s+)?(?:\p{L}{2,3}\.?,?\s*)?\d{1,2}\.\s?\d{1,2}\."#)

    /// Tabellen, deren Kopfzeile Testate nennt ("Nr Datum Thema Tutorien & Testate"; ohne Datum, hoechstens 14 Woerter,
    /// mit einem weiteren Spaltenkopf): darunter, bis zur Leerzeile, ist "T1:" ein Testat. Sein Datum ist das erste
    /// danach in derselben Zeile ("T1: Kontrollfluss (VL 1-3) - 16.11 bis 19.11."), sonst das erste der Folgezeile, wenn
    /// sie keine neue Tabellenzeile beginnt; nie das Datum der Vorlesung davor. Ergebnis: Kopfwoerter (kein Termin) und
    /// Testate mit Datum (nil: keins).
    static func testatTables(_ text: String, _ keywords: [Keyword], _ dates: [DateToken], _ ns: NSString)
        -> (headers: [Int], markers: [(keyword: Keyword, date: Int?)]) {
        var headers: [Int] = [], markers: [(keyword: Keyword, date: Int?)] = []
        var seen = Set<Int>(), markersByLine: [Int: Bool] = [:]
        for (ki, k) in keywords.enumerated() where k.kind == .test && (k.label == "Testat" || k.label == "Kurztestat") {
            let (ls, le) = lineBounds(ns, k.range.location)
            let line = ns.substring(with: NSRange(location: ls, length: le - ls))
            // Kopf: kein Datum, kein ":" am Ende ("Termine der Testate:" leitet eine Liste ein), weitere Spalte
            guard !line.trimmingCharacters(in: .whitespaces).hasSuffix(":"),
                  !dates.contains(where: { $0.range.location < le && NSMaxRange($0.range) > ls }),
                  words(line) <= 14, has(tableColumnRE, line) else { continue }
            if !seen.insert(ls).inserted {
                if markersByLine[ls] ?? false { headers.append(ki) }
                continue
            }
            var rows: [(start: Int, end: Int)] = []
            var pos = le + 1
            while pos < ns.length, rows.count < 80 {
                let e = lineBounds(ns, pos).end
                guard firstVisible(ns, pos, e) != nil else { break }
                rows.append((pos, e))
                pos = e + 1
            }
            let before = markers.count
            for (n, row) in rows.enumerated() {
                let found = testatMarkerRE.matches(in: text, range: NSRange(location: row.start, length: row.end - row.start))
                for (j, m) in found.enumerated() {
                    let a = NSMaxRange(m.range)
                    let stop = j + 1 < found.count ? found[j + 1].range.location : row.end
                    var d = dates.firstIndex { $0.range.location >= a && $0.range.location < stop }
                    if d == nil, j + 1 == found.count, n + 1 < rows.count {
                        let next = rows[n + 1]
                        let nextText = ns.substring(with: NSRange(location: next.start, length: next.end - next.start))
                        if !has(rowStartRE, nextText), !has(testatMarkerRE, nextText) {
                            d = dates.firstIndex { $0.range.location >= next.start && $0.range.location < next.end }
                        }
                    }
                    let number = Int(ns.substring(with: m.range(at: 1))) ?? 0
                    markers.append((Keyword(range: m.range, kind: .test, label: "Testat T\(number)", direction: .dateAfter), d))
                }
            }
            // nur mit "T1:" darunter ist es eine Testat-Tabelle (und ihr Kopf kein Termin)
            markersByLine[ls] = markers.count > before
            if markers.count > before { headers.append(ki) }
        }
        return (headers, markers)
    }

    // MARK: - Zeitraum nach "Klausuren", "Pruefungen"

    /// "Klausuren", "Pruefungen" (Mehrzahl) als Ende des Schluesselworts
    private static let pluralExamRE = HText.regex(#"(?<![\p{L}])(?:klausuren|pr(?:ü|ue)fungen)$"#, [.caseInsensitive])
    /// direkt davor: nur Klammer, Doppelpunkt, Strich, "vom"/"von"/"zwischen"
    private static let directGapRE = HText.regex(#"^\s*(?:[(:–\-]\s*)?(?:(?:vom|von|zwischen)\s+)?$"#, [.caseInsensitive])
    /// Rede von der Anmeldung: "Anmeldung", "anzumelden", "angemeldet", "Pruefungsanmeldung", "Melde-", "Meldezeitraum"
    private static let registrationRE = HText.regex(
        #"(?<![\p{L}])(?:\p{L}*an(?:zu|ge)?meld\p{L}*|\p{L}*melde(?:-|zeitr|frist|phase|schluss)\p{L}*|registration|register)"#, [.caseInsensitive])

    /// Bereich direkt nach "Klausuren"/"Pruefungen" ("Klausuren (16.11.-27.11.)"): kein Klausurtag
    static func isPeriodAfterPlural(_ k: Keyword, _ t: DateToken, _ ns: NSString) -> Bool {
        guard k.kind == .klausur, t.end != nil, NSMaxRange(k.range) <= t.range.location,
              has(pluralExamRE, ns.substring(with: k.range)) else { return false }
        return has(directGapRE, ns.substring(with: NSRange(location: NSMaxRange(k.range), length: t.range.location - NSMaxRange(k.range))))
    }

    /// Im Satz bis `pos` oder in den zwei Saetzen davor ist von der Anmeldung die Rede, und sie hat dort kein eigenes
    /// Datum ("Pruefungsanmeldung: 16.11.–27.11. ... Klausuren: 01.02.–12.02." meint mit dem zweiten die Pruefungszeit)
    static func registrationBefore(_ pos: Int, _ ns: NSString, _ dates: [DateToken]) -> Bool {
        let lo = max(0, pos - 400)
        let lead = ns.substring(with: NSRange(location: lo, length: pos - lo))
        let ends = sentenceEnds(lead).sorted()
        let from = ends.count >= 3 ? ends[ends.count - 3] : 0
        let scope = (lead as NSString).substring(from: from)
        guard let m = registrationRE.matches(in: scope, range: NSRange(location: 0, length: (scope as NSString).length)).last else { return false }
        let after = lo + from + NSMaxRange(m.range)
        return !dates.contains { $0.range.location >= after && $0.range.location < pos }
    }

    // MARK: - Erkennen

    /// Termine in einem Text (Seite, Dateiname, Ankuendigung), nach Datum; gleiche Art am gleichen Tag nur einmal
    public static func detect(_ raw: String, context ctx: Context) -> [Hit] {
        let text = prepare(raw)
        let ns = text as NSString
        // erst die Daten (schneller; die meisten Seiten haben keins), dann die Schluesselwoerter
        let dates = findDates(text)
        guard !dates.isEmpty else { return [] }
        var keywords = findKeywords(text)
        guard !keywords.isEmpty else { return [] }

        // feste Paare vor allen anderen: Testate in Tabellen mit Kopf "Testate" (der Kopf selbst ist kein Termin),
        // Ueberschriften mit Unterpunkten (ohne Datum darunter: kein Termin)
        var forced: [(k: Int, d: Int?)] = []
        let tables = testatTables(text, keywords, dates, ns)
        let plain = keywords.count
        for h in tables.headers { forced.append((h, nil)) }
        for m in tables.markers {
            keywords.append(m.keyword)
            forced.append((keywords.count - 1, m.date))
        }
        let headerKeys = Set(tables.headers)
        for ki in 0..<plain where !headerKeys.contains(ki) {
            if let d = headingDate(ki, keywords, dates, ns) { forced.append((ki, d)) }
        }
        let forcedKeys = Set(forced.map(\.k))

        struct Pair { let k: Int; let d: Int; let score: Int; let keywordFirst: Bool }
        var pairs: [Pair] = forced.compactMap { f in f.d.map { Pair(k: f.k, d: $0, score: -1, keywordFirst: true) } }
        for (ki, k) in keywords.enumerated() where !forcedKeys.contains(ki) {
            let before = dates.lastIndex { NSMaxRange($0.range) <= k.range.location }
            let after = dates.firstIndex { $0.range.location >= NSMaxRange(k.range) }
            for di in [before, after].compactMap({ $0 }) {
                if let s = score(k, dates[di], ns) { pairs.append(Pair(k: ki, d: di, score: s, keywordFirst: k.range.location < dates[di].range.location)) }
            }
        }
        pairs.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            if a.keywordFirst != b.keywordFirst { return a.keywordFirst }
            if keywords[a.k].kind.rank != keywords[b.k].kind.rank { return keywords[a.k].kind.rank < keywords[b.k].kind.rank }
            return dates[a.d].range.location < dates[b.d].range.location
        }
        var dateTaken = Set<Int>(), keyTaken = Set(forced.filter { $0.d == nil }.map(\.k))
        var accepted: [(k: Int, d: Int)] = []
        for p in pairs where !dateTaken.contains(p.d) && !keyTaken.contains(p.k) {
            dateTaken.insert(p.d)
            keyTaken.insert(p.k)
            accepted.append((p.k, p.d))
            // Datumsliste hinter dem Schluesselwort: "Kurztestate am 02.11., 16.11. und 30.11." (bei festen Paaren nur in
            // derselben Zeile, Testate in Tabellen ohne)
            guard p.keywordFirst, p.k < plain else { continue }
            var j = p.d + 1
            while j < dates.count, !dateTaken.contains(j) {
                let gs = NSMaxRange(dates[j - 1].range), gl = dates[j].range.location - gs
                guard gl >= 0, gl <= 12 else { break }
                let gap = ns.substring(with: NSRange(location: gs, length: gl))
                guard has(listGapRE, gap), !(forcedKeys.contains(p.k) && gap.contains("\n")) else { break }
                dateTaken.insert(j)
                accepted.append((p.k, j))
                j += 1
            }
        }

        var hits: [Hit] = []
        for (ki, di) in accepted {
            var k = keywords[ki]
            let t = dates[di]
            // "Pruefungszeitraum": nur Zeitraum, kein Termin
            if k.periodOnly { continue }
            // Zeitraum direkt nach "Klausuren"/"Pruefungen": kein Klausurtag; ist kurz davor von der Anmeldung die Rede
            // (ohne eigenes Datum), ist er die Anmeldung, sonst kein Termin
            if isPeriodAfterPlural(k, t, ns) {
                guard registrationBefore(k.range.location, ns, dates) else { continue }
                k = Keyword(range: k.range, kind: .anmeldung, label: "Anmeldung", direction: k.direction)
            }
            if !ctx.allowExams, k.kind == .test || k.kind == .klausur { continue }
            let hi = max(NSMaxRange(k.range), NSMaxRange(t.range))
            let around: String
            if forcedKeys.contains(ki) {
                // feste Paare: Schluesselwort und die Zeile des Datums (Unterpunkt, Tabellenzeile ab "T1:")
                let from = max(lineBounds(ns, t.range.location).start, NSMaxRange(k.range))
                around = ns.substring(with: k.range) + " " + ns.substring(with: NSRange(location: from, length: NSMaxRange(t.range) - from))
            } else {
                // Kontext vom Satzanfang (hoechstens 50 Zeichen vor dem Schluesselwort) bis zum Datum
                let first = min(k.range.location, t.range.location)
                var lo = max(0, first - 50)
                if let b = sentenceEnds(ns.substring(with: NSRange(location: lo, length: first - lo))).max() { lo += b }   // nur der eigene Satz
                around = ns.substring(with: NSRange(location: lo, length: hi - lo))
            }
            if (k.kind == .test || k.kind == .klausur), has(examBlockRE, around) { continue }
            if k.kind == .abgabe, has(submissionBlockRE, around) { continue }
            // Bereich: Abgaben und Anmeldungen enden am letzten Tag, Tests beginnen am ersten
            let usesEnd = t.end != nil && (k.kind == .abgabe || k.kind == .anmeldung || k.kind == .sonstiges)
            guard let day = resolve(usesEnd ? t.end! : t.start, ctx) else { continue }
            let time = (t.end == nil || usesEnd) ? t.time : nil
            let snip = snippet(ns, from: min(k.range.location, t.range.location), to: hi)
            let head = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: true).prefix(2).joined(separator: "\n")
            var lab = label(k, ns, line: snip, head: String(head.prefix(120)), docHead: ctx.head, name: ctx.name)
            // Testat aus der Tabelle mit Zeitraum: das Datenmodell kennt nur einen Tag, das Ende steht in der Bezeichnung
            if ki >= plain, let end = t.end, let last = resolve(end, ctx), last > day {
                let c = BerlinClock.civil(last)
                lab += " (bis \(BerlinClock.pad(c.day, 2)).\(BerlinClock.pad(c.month, 2)).)"
            }
            let iso = BerlinClock.isoDate(day)
            if let i = hits.firstIndex(where: { $0.date == iso && $0.kind == k.kind }) {
                if hits[i].time == nil, let time { hits[i].time = time }
                if !hits[i].label.contains(where: \.isNumber), lab.contains(where: \.isNumber) { hits[i].label = lab }
                continue
            }
            hits.append(Hit(date: iso, time: time, kind: k.kind, label: lab, snippet: snip))
        }
        return hits.sorted { a, b in
            a.date != b.date ? a.date < b.date : (a.time ?? "") != (b.time ?? "") ? (a.time ?? "") < (b.time ?? "") : a.kind.rank < b.kind.rank
        }
    }

    /// Dateiname als Text: ohne Endung, Unterstriche als Leerzeichen ("Blatt_3_Abgabe_05.11.pdf" -> "Blatt 3 Abgabe 05.11.")
    public static func nameText(_ name: String) -> String {
        var n = name
        // nur die Endung, der Punkt bleibt ("05.11.pdf" -> "05.11.": Punkt nach dem Monat)
        if let dot = n.lastIndex(of: "."), n.distance(from: dot, to: n.endIndex) <= 6, n[n.index(after: dot)...].allSatisfy({ $0.isLetter }) {
            n = String(n[...dot])
        }
        return n.replacingOccurrences(of: "_", with: " ")
    }
}
