import Foundation

// Lehrwoche einer Aufzeichnung ohne KI, passend zu den Wochenbloecken im Moduldetail (study.week_index und
// week_label in app/study.py: Woche 1 = Woche des Semesterbeginns, Montag bis Sonntag).
// Reihenfolge: (a) ausdrueckliche Woche im Titel/in der Beschreibung ("02. Vorlesungswoche", "Woche 3"; "KW 44" und
// "Kalenderwoche" sind keine Lehrwochen), (b) Nummer der Veranstaltung im Titel ("3. Vorlesung", "VL 04",
// "Zentraluebung 02", "Uebung 5"), (c) Datum im Titel ("vom 06.11.2026"), sonst das Erstelldatum – aber nicht bei
// Videos aus einem frueheren Semester ("(2023)", "SoSe 21", erstellt vor Semesterbeginn): dann unbekannt.

/// Lehrwoche einer Aufzeichnung mit Herkunft.
public struct LectureWeekGuess: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Codable {
        /// ausdrueckliche Woche oder Nummer der Veranstaltung im Titel
        case title
        /// Datum im Titel bzw. Erstelldatum relativ zum Semesterbeginn
        case date
        case unknown
    }

    public let week: Int?
    public let source: Source

    public init(week: Int?, source: Source) {
        self.week = source == .unknown ? nil : week
        self.source = week == nil ? .unknown : source
    }

    public static let unknown = LectureWeekGuess(week: nil, source: .unknown)
}

public enum LectureWeek {
    /// Kalender fuer Datumsangaben der LUH (Wochenbeginn Montag)
    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin") ?? TimeZone(secondsFromGMT: 3600)!
        c.firstWeekday = 2
        c.locale = Locale(identifier: "de_DE")
        return c
    }()

    /// groesste plausible Lehrwoche (Vorlesungszeit plus Pruefungswochen)
    public static let maxWeek = 20

    public static func guess(title: String, description: String? = nil, created: Date?, semesterStart: Date?,
                             calendar: Calendar = LectureWeek.calendar) -> LectureWeekGuess {
        let desc = description ?? ""
        if let w = explicitWeek(title) ?? explicitWeek(desc) { return LectureWeekGuess(week: w, source: .title) }
        if let w = numberedSession(title) { return LectureWeekGuess(week: w, source: .title) }
        guard let start = semesterStart.map({ monday($0, calendar: calendar) }) else { return .unknown }
        if fromEarlierSemester(title + " " + desc, semesterStart: start, calendar: calendar) { return .unknown }
        var date = created
        if let t = dateInText(title, near: start, calendar: calendar) {
            if calendar.startOfDay(for: t.date) >= start { date = t.date }
            // "vom 06.11.2023": volle Jahreszahl vor Semesterbeginn = frueheres Semester; sonst (zweistelliges oder
            // fehlendes Jahr) war es wohl kein Datum – dann gilt das Erstelldatum
            else if t.fullYear { return .unknown }
        }
        guard let d = date, calendar.startOfDay(for: d) >= start else { return .unknown }   // vor Semesterbeginn
        let w = weekIndex(start: start, date: d, calendar: calendar)
        return (1...maxWeek).contains(w) ? LectureWeekGuess(week: w, source: .date) : .unknown
    }

    // MARK: Regeln

    /// (a) "02. Vorlesungswoche", "3. Woche", "Woche 3", "Lehrwoche 04", "VL-Woche 2"; nie "KW"/"Kalenderwoche"
    static func explicitWeek(_ s: String) -> Int? {
        let patterns = [
            #"(?<![\d.])(\d{1,2})\s*\.\s*(?:Vorlesungs|Lehr|Semester)?woche\b"#,
            #"\b(?:Vorlesungs|Lehr|Semester)?woche\s*(?:Nr\.?\s*)?0?(\d{1,2})(?!\d)(?![.:/]\d)"#,
        ]
        for p in patterns { if let n = firstNumber(s, p), (1...maxWeek).contains(n) { return n } }
        return nil
    }

    /// (b) "3. Vorlesung", "Vorlesung 3", "VL03", "Zentralübung 02", "2. Übung", "Hörsaalübung Nr. 4"
    static func numberedSession(_ s: String) -> Int? {
        let kinds = #"(?:Vorlesung|VL|Zentral(?:ü|ue)bung|H(?:ö|oe)rsaal(?:ü|ue)bung|(?:Ü|Ue)bung)"#
        let patterns = [
            #"(?<![\d.])(\d{1,2})\s*\.\s*"# + kinds + #"(?![\p{L}])"#,
            #"(?<![\p{L}])"# + kinds + #"\s*(?:Nr\.?\s*|#\s*)?0?(\d{1,2})(?!\d)(?![.:/,]\d)"#,
        ]
        for p in patterns { if let n = firstNumber(s, p), (1...maxWeek).contains(n) { return n } }
        return nil
    }

    /// (c) Datum im Text: "06.11.2026", "6.11.26", "06.11." (Jahr passend zum Semester), "2026-11-06".
    /// Zweistellige Jahre nur nach "vom"/"am" oder nahe am Semesterjahr (sonst waere "Kapitel 1.2.10" der 01.02.2010).
    /// `fullYear`: Jahr vierstellig angegeben (dann ist ein Datum vor Semesterbeginn ein frueheres Semester).
    static func dateInText(_ s: String, near start: Date, calendar: Calendar) -> (date: Date, fullYear: Bool)? {
        if let m = groups(s, #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#), let y = Int(m[0]), let mo = Int(m[1]), let d = Int(m[2]),
           let date = day(y, mo, d, calendar) {
            return (date, true)
        }
        let y0 = calendar.component(.year, from: start)
        for m in allGroups(s, #"(?:\b(vom|am)\s+)?(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})(?![\d])"#) {
            guard let d = Int(m[1]), let mo = Int(m[2]), var y = Int(m[3]) else { continue }
            let full = m[3].count == 4
            if !full {
                y += 2000
                guard !m[0].isEmpty || (y0 - 1...y0 + 1).contains(y) else { continue }
            }
            if let date = day(y, mo, d, calendar) { return (date, full) }
        }
        // ohne Jahr nur nach "vom"/"am" (sonst waere "Kapitel 2.1." ein Datum); das Jahr, in dem das Datum am
        // naechsten am Semester liegt (Wintersemester ueber Neujahr)
        guard let m = groups(s, #"\b(?:vom|am)\s+(\d{1,2})\.(\d{1,2})\.(?!\d)"#), let d = Int(m[0]), let mo = Int(m[1]) else { return nil }
        return [y0 - 1, y0, y0 + 1].compactMap { day($0, mo, d, calendar) }
            .min { abs($0.timeIntervalSince(start) - 60 * 86400) < abs($1.timeIntervalSince(start) - 60 * 86400) }
            .map { ($0, false) }
    }

    /// Offensichtlich frueheres Semester: Jahreszahl vor dem Semesterjahr ("(2023)") oder Semesterangabe
    /// ("SoSe 21", "WS 22/23", "Sommersemester 2021"), die mehr als drei Monate vor dem Semesterbeginn liegt.
    static func fromEarlierSemester(_ s: String, semesterStart start: Date, calendar: Calendar) -> Bool {
        let year = calendar.component(.year, from: start)
        let sem = #"(?<![\p{L}])(SoSe|SS|Sommersemester|WiSe|WS|Wintersemester)\s*'?(\d{4}|\d{2})(?!\d)"#
        for m in allGroups(s, sem) {
            guard var y = Int(m[1]) else { continue }
            if y < 100 { y += 2000 }
            let summer = ["sose", "ss", "sommersemester"].contains(m[0].lowercased())
            guard let begin = day(y, summer ? 4 : 10, 1, calendar) else { continue }
            if begin < start.addingTimeInterval(-90 * 86400) { return true }
        }
        // einzelne Jahreszahl, nicht Teil eines Datums wie 06.11.2026 oder 2026-11-06
        for m in allGroups(s, #"(?<![\d.\-/])((?:19|20)\d{2})(?![\d.\-])"#) {
            if let y = Int(m[0]), y < year { return true }
        }
        return false
    }

    // MARK: Wochen

    /// Montag der Woche (00:00)
    public static func monday(_ d: Date, calendar: Calendar = LectureWeek.calendar) -> Date {
        let day = calendar.startOfDay(for: d)
        let wd = calendar.component(.weekday, from: day)           // 1 = Sonntag, 2 = Montag
        return calendar.date(byAdding: .day, value: -((wd + 5) % 7), to: day) ?? day
    }

    /// study.week_index: (Montag(d) - Beginn) / 7 + 1
    public static func weekIndex(start: Date, date: Date, calendar: Calendar = LectureWeek.calendar) -> Int {
        let days = calendar.dateComponents([.day], from: monday(start, calendar: calendar), to: monday(date, calendar: calendar)).day ?? 0
        return Int((Double(days) / 7).rounded(.down)) + 1
    }

    /// Montag der Woche `week` (1 = Semesterbeginn)
    public static func weekStart(_ week: Int, semesterStart: Date, calendar: Calendar = LectureWeek.calendar) -> Date {
        calendar.date(byAdding: .day, value: 7 * (week - 1), to: monday(semesterStart, calendar: calendar)) ?? semesterStart
    }

    /// Semesterbeginn aus den Wochenbloecken des Moduldetails ("Woche 3 · 02.11. – 08.11."); Jahr nach `reference`.
    public static func semesterStart(fromWeekLabels labels: [(week: Int, label: String)], reference: Date,
                                     calendar: Calendar = LectureWeek.calendar) -> Date? {
        for (w, label) in labels where w >= 1 {
            guard let m = groups(label, #"(\d{1,2})\.(\d{1,2})\."#), let d = Int(m[0]), let mo = Int(m[1]) else { continue }
            let y0 = calendar.component(.year, from: reference)
            guard let first = [y0 - 1, y0, y0 + 1].compactMap({ day($0, mo, d, calendar) })
                .min(by: { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }) else { continue }
            return calendar.date(byAdding: .day, value: -7 * (w - 1), to: monday(first, calendar: calendar))
        }
        return nil
    }

    /// ISO-Tag ("2026-10-12", auch mit Uhrzeit) -> Montag dieser Woche
    public static func semesterStart(isoDay: String?, calendar: Calendar = LectureWeek.calendar) -> Date? {
        guard let s = isoDay, let m = groups(s, #"^(\d{4})-(\d{2})-(\d{2})"#),
              let y = Int(m[0]), let mo = Int(m[1]), let d = Int(m[2]), let date = day(y, mo, d, calendar) else { return nil }
        return monday(date, calendar: calendar)
    }

    /// Beschriftung wie week_label: "Woche 3 · 02.11. – 08.11."
    public static func label(_ week: Int, semesterStart: Date?, calendar: Calendar = LectureWeek.calendar) -> String {
        guard let start = semesterStart else { return "Woche \(week)" }
        let s = weekStart(week, semesterStart: start, calendar: calendar)
        let e = calendar.date(byAdding: .day, value: 6, to: s) ?? s
        func f(_ d: Date) -> String {
            let c = calendar.dateComponents([.day, .month], from: d)
            return String(format: "%02d.%02d.", c.day ?? 0, c.month ?? 0)
        }
        return "Woche \(week) · \(f(s)) – \(f(e))"
    }

    // MARK: Hilfen

    static func day(_ y: Int, _ m: Int, _ d: Int, _ calendar: Calendar) -> Date? {
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        let c = DateComponents(year: y, month: m, day: d)
        guard let date = calendar.date(from: c), calendar.component(.day, from: date) == d else { return nil }
        return date
    }

    static func firstNumber(_ s: String, _ pattern: String) -> Int? {
        groups(s, pattern).flatMap { $0.first }.flatMap { Int($0) }
    }

    /// Gruppen des ersten Treffers (leere Zeichenkette fuer nicht beteiligte Gruppen)
    static func groups(_ s: String, _ pattern: String) -> [String]? { allGroups(s, pattern).first }

    static func allGroups(_ s: String, _ pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<max(m.numberOfRanges, 1)).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }
}
