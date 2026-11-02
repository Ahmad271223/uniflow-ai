import Foundation

// Semester und vorlesungsfreie Zeiten aus Stud.IP wie app/studip_terms.py (02.11.2026). Ergaenzt den Zeitplan der
// Hochschule (`Holidays.semesters`), statt ihn zu ersetzen: ein Stud.IP-Semester mit Vorlesungsbeginn und -ende gilt fuer
// das Semester gleichen Namens (Unterbrechungen des Zeitplans bleiben), unbekannte Semester kommen dazu; vorlesungsfreie
// Zeiten aus Stud.IP sind Unterbrechungen ("pause"). Planer und Kalender lesen beides ueber
// `Holidays.dayMarks(..., studip:)`. Lernplan (`lectureWeek`): an Tagen in Unterbrechungen und in der vorlesungsfreien
// Zeit der Stoff der letzten Vorlesungswoche davor. Nur lesend. Fixture tools/gen-studip-extras-fixture.py.

public enum StudIPTerms {

    /// Semester aus jsonapi.php/v1/semesters (Tage als "YYYY-MM-DD")
    public struct Period: Sendable, Equatable {
        public let id: String
        public let title: String
        public let start: String?
        public let end: String?
        public let lecturesStart: String?
        public let lecturesEnd: String?

        var json: JSONValue {
            func v(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
            return ["id": .string(id), "title": .string(title), "start": v(start), "end": v(end),
                    "lectures_start": v(lecturesStart), "lectures_end": v(lecturesEnd)]
        }
    }

    /// Vorlesungsfreie Zeit aus jsonapi.php/v1/holidays
    public struct Holiday: Sendable, Equatable {
        public let id: String
        public let title: String
        public let start: String
        public let end: String

        var json: JSONValue { ["id": .string(id), "title": .string(title), "start": .string(start), "end": .string(end)] }
    }

    /// Gespeicherte Zeiten (`load`): nie beides leer
    public struct Stored: Sendable, Equatable {
        public var semesters: [Period] = []
        public var holidays: [Holiday] = []

        public init(semesters: [Period] = [], holidays: [Holiday] = []) {
            self.semesters = semesters
            self.holidays = holidays
        }
    }

    static let table = """
        CREATE TABLE IF NOT EXISTS studip_periods (
            kind TEXT NOT NULL,                -- semester | holiday
            id TEXT NOT NULL,
            title TEXT,
            start TEXT,                        -- YYYY-MM-DD
            end TEXT,
            lectures_start TEXT,               -- nur Semester: Vorlesungsbeginn
            lectures_end TEXT,                 -- nur Semester: Vorlesungsende
            fetched_at TEXT,
            PRIMARY KEY (kind, id)
        )
        """

    /// Lehrwoche eines freien Tages: so weit zurueck wird hoechstens gesucht
    static let lookbackDays = 200
    static let freeKinds: Set<String> = ["pause", "vorlesungsfrei"]

    // MARK: Lesen

    /// `_day`: ISO-Datum (auch mit Uhrzeit und Versatz) -> "YYYY-MM-DD"; Zahlen und Unlesbares -> nil
    static func day(_ v: JSONValue?) -> String? {
        guard let s = v?.string, s.unicodeScalars.count >= 10 else { return nil }
        let head = PyText.slice(s, 0, 10)
        guard head.unicodeScalars.enumerated().allSatisfy({ i, c in (i == 4 || i == 7) ? c == "-" : ("0"..."9").contains(c) }),
              BerlinClock.parseISODate(head) != nil else { return nil }
        return head
    }

    static func text(_ v: JSONValue?) -> String { v?.string.map(PyText.strip) ?? "" }

    /// `_id`: Kennung als Text (Text oder ganze Zahl, nicht leer)
    static func id(_ x: JSONValue?) -> String? {
        guard let v = x?["id"] else { return nil }
        if let s = v.string { return s.isEmpty ? nil : s }
        if case .number(let n) = v, n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return nil
    }

    static func attrs(_ x: JSONValue?) -> JSONValue {
        if let a = x?["attributes"], a.object != nil { return a }
        return .object([:])
    }

    /// `parse_semesters(data)`. Annahme (Stud.IP 5, SemestersSchema): title, start, end, start-of-lectures,
    /// end-of-lectures als ISO-Zeit
    public static func parseSemesters(_ data: JSONValue?) -> [Period] {
        var out: [Period] = []
        for s in data?.array ?? [] {
            guard s.object != nil, let id = id(s) else { continue }
            let a = attrs(s)
            out.append(Period(id: id, title: text(a["title"]), start: day(a["start"]), end: day(a["end"]),
                              lecturesStart: day(a["start-of-lectures"]), lecturesEnd: day(a["end-of-lectures"])))
        }
        return LocalTimetable.stableSorted(out) { x, y in
            let (p, q) = (x.start ?? "", y.start ?? "")
            return p != q ? PyText.less(p, q) : PyText.less(x.id, y.id)
        }
    }

    /// `parse_holidays(data)`. Annahme (nicht an der LUH belegt): title (sonst name), start (sonst begin), end
    public static func parseHolidays(_ data: JSONValue?) -> [Holiday] {
        var out: [Holiday] = []
        for h in data?.array ?? [] {
            guard h.object != nil, let id = id(h) else { continue }
            let a = attrs(h)
            guard let start = day(a["start"]) ?? day(a["begin"]) else { continue }
            let end = day(a["end"]) ?? start
            if PyText.less(end, start) { continue }
            let t = [text(a["title"]), text(a["name"])].first { !$0.isEmpty } ?? "Vorlesungsfrei"
            out.append(Holiday(id: id, title: PyText.slice(t, 0, 80), start: start, end: end))
        }
        return LocalTimetable.stableSorted(out) { x, y in x.start != y.start ? PyText.less(x.start, y.start) : PyText.less(x.id, y.id) }
    }

    /// `merged_semesters(university, studip)`: Zeitplan mit den Vorlesungszeiten aus Stud.IP, nach Beginn
    public static func mergedSemesters(university: String, studip: Stored?) -> [Holidays.Semester] {
        let base = Holidays.semesters[university] ?? []
        guard let studip else { return base }
        var out = base
        var index: [String: Int] = [:]               // Semesters.Key als "Jahr-Haelfte"
        func key(_ k: Semesters.Key) -> String { "\(k.year)-\(k.half)" }
        for (i, s) in out.enumerated() { if let k = Semesters.key(s.name) { index[key(k)] = i } }
        for s in studip.semesters {
            guard let ls = s.lecturesStart, let le = s.lecturesEnd, !PyText.less(le, ls) else { continue }
            let k = Semesters.key(s.title)
            if let k, let i = index[key(k)] {
                out[i] = Holidays.Semester(name: out[i].name, start: ls, end: le, breaks: out[i].breaks)
            } else {
                let name = k.map(Semesters.label) ?? (s.title.isEmpty ? "Semester" : s.title)
                if let k { index[key(k)] = out.count }
                out.append(Holidays.Semester(name: name, start: ls, end: le, breaks: []))
            }
        }
        return LocalTimetable.stableSorted(out) { a, b in a.start != b.start ? PyText.less(a.start, b.start) : PyText.less(a.name, b.name) }
    }

    /// `holiday_breaks(studip)`
    static func holidayBreaks(_ studip: Stored?) -> [(from: String, to: String, label: String)] {
        (studip?.holidays ?? []).map { ($0.start, $0.end, $0.title) }
    }

    // MARK: Speicher

    /// `store(conn, kind, items, fetched_at)`: Semester bzw. vorlesungsfreie Zeiten ersetzen
    static func store(_ c: SQLiteConnection, semesters: [Period]? = nil, holidays: [Holiday]? = nil, fetchedAt: String) throws {
        guard semesters != nil || holidays != nil else { return }
        try c.executeScript(table)
        if let semesters {
            try c.execute("DELETE FROM studip_periods WHERE kind='semester'")
            for x in semesters {
                try c.execute("""
                    INSERT OR REPLACE INTO studip_periods(kind, id, title, start, end, lectures_start, lectures_end, fetched_at)
                    VALUES ('semester',?,?,?,?,?,?,?)
                    """, [.text(x.id), .text(x.title), SQLiteValue(x.start), SQLiteValue(x.end), SQLiteValue(x.lecturesStart),
                          SQLiteValue(x.lecturesEnd), .text(fetchedAt)])
            }
        }
        if let holidays {
            try c.execute("DELETE FROM studip_periods WHERE kind='holiday'")
            for x in holidays {
                try c.execute("""
                    INSERT OR REPLACE INTO studip_periods(kind, id, title, start, end, fetched_at) VALUES ('holiday',?,?,?,?,?)
                    """, [.text(x.id), .text(x.title), .text(x.start), .text(x.end), .text(fetchedAt)])
            }
        }
    }

    /// `load(conn)`: gespeicherte Zeiten; nil, solange nichts gespeichert ist
    public static func load(_ c: SQLiteConnection) throws -> Stored? {
        guard try c.queryOne("SELECT 1 FROM sqlite_master WHERE type='table' AND name='studip_periods'") != nil else { return nil }
        var out = Stored()
        for r in try c.rows("SELECT kind, id, title, start, end, lectures_start, lectures_end FROM studip_periods ORDER BY start, id") {
            let id = r["id"]?.string ?? ""
            let title = r["title"]?.string ?? ""
            switch r["kind"]?.string {
            case "semester":
                out.semesters.append(Period(id: id, title: title, start: r["start"]?.string, end: r["end"]?.string,
                                            lecturesStart: r["lectures_start"]?.string, lecturesEnd: r["lectures_end"]?.string))
            case "holiday":
                guard let s = r["start"]?.string, let e = r["end"]?.string, !s.isEmpty, !e.isEmpty else { continue }
                out.holidays.append(Holiday(id: id, title: title.isEmpty ? "Vorlesungsfrei" : title, start: s, end: e))
            default: continue
            }
        }
        return out.semesters.isEmpty && out.holidays.isEmpty ? nil : out
    }

    // MARK: Lernplan

    /// `free_days(start, end, university, studip)`: Tage in Unterbrechungen und vorlesungsfreier Zeit (ohne einzelne
    /// Feiertage), ab `lookbackDays` vor `start`
    static func freeDays(from start: Int, to end: Int, university: String, studip: Stored?) -> Set<Int> {
        var out = Set<Int>()
        for (day, marks) in Holidays.dayMarks(from: start - lookbackDays, to: end, university: university, studip: studip)
            where marks.contains(where: { freeKinds.contains($0["kind"]?.string ?? "") }) {
            if let d = BerlinClock.parseISODate(day) { out.insert(d) }
        }
        return out
    }

    /// `lecture_week(sem_start, d, free)`: an freien Tagen die Lehrwoche des letzten Tages davor, der nicht frei ist
    static func lectureWeek(semesterStart: Int, day d: Int, today: Int, free: Set<Int>) -> Int {
        var x = d, n = 0
        while free.contains(x) && n < lookbackDays { x -= 1; n += 1 }
        return StudyWeeks.dayWeek(start: semesterStart, day: x, today: today)
    }
}
