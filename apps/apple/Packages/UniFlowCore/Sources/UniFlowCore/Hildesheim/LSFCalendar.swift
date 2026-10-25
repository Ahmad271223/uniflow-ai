import Foundation

/// LSF der Uni Hildesheim: iCal-Export des persoenlichen Stundenplans (`app/lsf.py`, `timetable.parse_ics`).
///
/// Eigenheiten des LSF-Exports: DTSTART ist der Semesterbeginn (Montag), der echte Wochentag steht nur in BYDAY
/// (auch mehrere Tage); vorlesungsfreie Tage stehen als EXDATE (mehrere Zeilen, Komma-Listen).
public enum LSFCalendar {

    /// Eine Serie wie in `course_events` (weekday 0 = Montag, Zeiten "HH:MM", Daten "YYYY-MM-DD").
    public struct Entry: Sendable, Equatable {
        public var title: String
        public var number: String?
        public var lecturer: String
        public var weekday: Int
        public var startTime: String
        public var endTime: String
        public var room: String
        public var rrule: String            // weekly | biweekly | once
        public var dateFrom: String
        public var dateTo: String?
        public var exdates: [String]        // Ausfall (vorlesungsfrei), nur Tage dieses Wochentags
        public var uid: String?
    }

    static let icsDays = ["MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6]
    private static let intervalRE = HText.regex("INTERVAL=(\\d+)")
    private static let untilRE = HText.regex("UNTIL=(\\d{8})")
    private static let bydayRE = HText.regex("BYDAY=([A-Z,0-9+-]+)")
    private static let summaryRE = HText.regex("^\\s*(\\d{3,5})\\s*-\\s*(.+?)\\s*$")
    private static let lecturerRE = HText.regex("\\s*\\(([A-ZÄÖÜ][\\wäöüß\\-]+(?:\\s*[,/]\\s*[A-ZÄÖÜ][\\wäöüß\\-]+)*)\\)\\s*$")
    private static let planLinkRE = HText.regex("href=\"([^\"]*moduleCall=iCalendarPlan[^\"]*)\"")

    /// Datum/Zeit eines ICS-Werts (ohne Zeitzonen-Umrechnung, wie in Python)
    struct DT { var y, m, d, hh, mm: Int }

    static func parseDT(_ v: String) -> DT? {
        let s = v.trimmingCharacters(in: .whitespaces)
        let digits = Array(s)
        func num(_ a: Int, _ n: Int) -> Int? {
            guard digits.count >= a + n else { return nil }
            return Int(String(digits[a..<(a + n)]))
        }
        guard let y = num(0, 4), let m = num(4, 2), let d = num(6, 2), (1...12).contains(m), (1...31).contains(d) else { return nil }
        if s.contains("T") {
            guard digits.count >= 15, digits[8] == "T", let hh = num(9, 2), let mm = num(11, 2), num(13, 2) != nil else { return nil }
            return DT(y: y, m: m, d: d, hh: hh, mm: mm)
        }
        return DT(y: y, m: m, d: d, hh: 0, mm: 0)
    }

    static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func date(_ dt: DT) -> Date {
        gregorian.date(from: DateComponents(year: dt.y, month: dt.m, day: dt.d, hour: dt.hh, minute: dt.mm))!
    }

    /// 0 = Montag
    static func weekday(_ d: Date) -> Int { (gregorian.component(.weekday, from: d) + 5) % 7 }

    static func iso(_ d: Date) -> String {
        let c = gregorian.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func hm(_ d: Date) -> String {
        let c = gregorian.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    /// Minimaler ICS-Parser (VEVENT mit DTSTART/DTEND/SUMMARY/LOCATION/RRULE/EXDATE/UID)
    public static func parseICS(_ text: String) -> [Entry] {
        var lines: [String] = []
        for ln in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (ln.hasPrefix(" ") || ln.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += String(ln.dropFirst())
            } else {
                lines.append(ln)
            }
        }
        var events: [[String: String]] = [], exdates: [[String]] = []
        var cur: [String: String]?, curEx: [String] = []
        for ln in lines {
            if ln.hasPrefix("BEGIN:VEVENT") {
                cur = [:]; curEx = []
            } else if ln.hasPrefix("END:VEVENT"), let c = cur {
                events.append(c); exdates.append(curEx); cur = nil
            } else if cur != nil, let colon = ln.firstIndex(of: ":") {
                let k = String(ln[..<colon]), v = String(ln[ln.index(after: colon)...])
                let key = (k.split(separator: ";", maxSplits: 1).first.map(String.init) ?? k).uppercased()
                if key == "EXDATE" {
                    curEx += v.trimmingCharacters(in: .whitespaces).split(separator: ",").map(String.init).filter { !$0.isEmpty }
                    continue
                }
                cur?[key] = v.trimmingCharacters(in: .whitespaces)
            }
        }
        var out: [Entry] = []
        for (ev, exd) in zip(events, exdates) {
            guard let stDT = parseDT(ev["DTSTART"] ?? "") else { continue }
            let st = date(stDT)
            let en: Date
            if let e = ev["DTEND"] {
                guard let enDT = parseDT(e) else { continue }
                en = date(enDT)
            } else {
                en = st.addingTimeInterval(90 * 60)
            }
            let rr = ev["RRULE"] ?? ""
            let weekly = rr.contains("FREQ=WEEKLY")
            let interval = HText.match(intervalRE, rr)?.groups[1] ?? nil
            let until = HText.match(untilRE, rr)?.groups[1] ?? nil
            let title = (ev["SUMMARY"] ?? "Veranstaltung").replacingOccurrences(of: "\\,", with: ",")
            var days: [Int] = []
            if weekly, let by = HText.match(bydayRE, rr)?.groups[1] ?? nil {
                days = by.split(separator: ",").compactMap { icsDays[String($0.suffix(2))] }
            }
            let exDays = Set(exd.compactMap(parseDT).map { date(DT(y: $0.y, m: $0.m, d: $0.d, hh: 0, mm: 0)) })
            let stWD = weekday(st)
            for wd in days.isEmpty ? [stWD] : days {
                let first = gregorian.date(byAdding: .day, value: ((wd - stWD) % 7 + 7) % 7, to: st)!
                out.append(Entry(
                    title: title, number: nil, lecturer: "", weekday: wd, startTime: hm(st), endTime: hm(en),
                    room: (ev["LOCATION"] ?? "").replacingOccurrences(of: "\\,", with: ","),
                    rrule: weekly ? (interval == "2" ? "biweekly" : "weekly") : "once",
                    dateFrom: iso(first),
                    dateTo: until.map { "\($0.prefix(4))-\($0.dropFirst(4).prefix(2))-\($0.dropFirst(6).prefix(2))" },
                    exdates: exDays.filter { weekday($0) == wd }.map(iso).sorted(),
                    uid: ev["UID"]))
            }
        }
        return out
    }

    public struct Summary: Sendable, Equatable {
        public let number: String?
        public let title: String
        public let lecturer: String
    }

    /// "0449 - Titel (Lehrperson)" -> Nummer, Titel, Lehrperson
    public static func splitSummary(_ summary: String) -> Summary {
        var s = summary.replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var num: String?
        if let m = HText.match(summaryRE, s), let n = m.groups[1], let rest = m.groups[2] {
            num = n; s = rest
        }
        var lecturer = ""
        if let m = HText.match(lecturerRE, s), let l = m.groups[1] {
            lecturer = l
            s = String(s[..<m.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Summary(number: num, title: s.isEmpty ? summary : s, lecturer: lecturer)
    }

    /// Serien des persoenlichen Plans mit Nummer, Titel und Lehrperson
    public static func planEntries(_ ics: String) -> [Entry] {
        parseICS(ics).map { e in
            var e = e
            let p = splitSummary(e.title)
            e.title = p.title; e.number = p.number; e.lecturer = p.lecturer
            return e
        }
    }

    /// iCal-Link des ganzen Stundenplans aus der Stundenplan-Seite
    /// (`/qisserver/rds?state=wplan&act=show&show=plan&P.subc=plan&week=-2`)
    public static func planICSLink(html: String) -> String? {
        guard let raw = HText.match(planLinkRE, html)?.groups[1] ?? nil else { return nil }
        let href = raw.replacingOccurrences(of: "&amp;", with: "&")
        if href.hasPrefix("http") { return href }
        return "\(HildesheimCAS.lsfBase)/qisserver/" + String(href.drop(while: { $0 == "/" }))
    }
}
