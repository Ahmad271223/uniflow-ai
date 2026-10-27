import Foundation

/// Feiertage und vorlesungsfreie Zeit fuer die Kalender wie app/holidays.py (gruen markiert).
///
/// Weder Stud.IP noch Learnweb/LSF liefern eine Ferienliste. Deshalb: gesetzliche Feiertage in Niedersachsen werden
/// berechnet; Vorlesungszeiten und Unterbrechungen stammen aus den offiziellen Zeitplaenen der Hochschulen (Quellen
/// in app/holidays.py; neue Semester zuerst dort nachtragen, dann hier). Vorlesungsfreie Zeit = vom Tag nach dem Ende
/// der Vorlesungen bis zum Tag vor dem Beginn der naechsten (wie bei der LUH). Tage sind ISO-Texte "YYYY-MM-DD",
/// intern Tagesnummern wie in `BerlinClock`.
public enum Holidays {

    public struct Semester: Sendable, Equatable {
        public let name: String
        public let start: String
        public let end: String
        /// (von, bis, Bezeichnung)
        public let breaks: [(from: String, to: String, label: String)]

        public static func == (a: Semester, b: Semester) -> Bool {
            a.name == b.name && a.start == b.start && a.end == b.end
                && a.breaks.map { [$0.from, $0.to, $0.label] } == b.breaks.map { [$0.from, $0.to, $0.label] }
        }
    }

    /// `holidays.SEMESTERS`: (Semester, Beginn der Vorlesungen, Ende der Vorlesungen, Unterbrechungen) je Hochschule
    public static let semesters: [String: [Semester]] = [
        "luh": [
            Semester(name: "SoSe 2026", start: "2026-04-07", end: "2026-07-18", breaks: [("2026-05-26", "2026-05-30", "Exkursionswoche")]),
            Semester(name: "WiSe 2026/27", start: "2026-10-12", end: "2027-01-30", breaks: [("2026-12-23", "2027-01-05", "Weihnachtspause")]),
            Semester(name: "SoSe 2027", start: "2027-04-05", end: "2027-07-17", breaks: [("2027-05-18", "2027-05-23", "Exkursionswoche")]),
            Semester(name: "WiSe 2027/28", start: "2027-10-11", end: "2028-01-29", breaks: [("2027-12-24", "2028-01-08", "Weihnachtspause")]),
            Semester(name: "SoSe 2028", start: "2028-04-18", end: "2028-07-29", breaks: [("2028-06-06", "2028-06-10", "Exkursionswoche")]),
            Semester(name: "WiSe 2028/29", start: "2028-10-09", end: "2029-01-27", breaks: [("2028-12-25", "2029-01-06", "Weihnachtspause")]),
        ],
        "hildesheim": [
            Semester(name: "SoSe 2026", start: "2026-04-07", end: "2026-07-17", breaks: [("2026-05-26", "2026-05-29", "Exkursions- und Projektwoche")]),
            Semester(name: "WiSe 2026/27", start: "2026-10-19", end: "2027-02-05", breaks: [("2026-12-23", "2027-01-01", "Weihnachtspause")]),
            Semester(name: "SoSe 2027", start: "2027-04-05", end: "2027-07-16", breaks: [("2027-05-18", "2027-05-21", "Exkursions- und Projektwoche")]),
            Semester(name: "WiSe 2027/28", start: "2027-10-11", end: "2028-02-04", breaks: [("2027-12-23", "2028-01-03", "Weihnachtspause")]),
            Semester(name: "SoSe 2028", start: "2028-04-18", end: "2028-07-28", breaks: [("2028-06-06", "2028-06-09", "Exkursions- und Projektwoche")]),
            Semester(name: "WiSe 2028/29", start: "2028-10-09", end: "2029-02-02", breaks: [("2028-12-23", "2029-01-05", "Weihnachtspause")]),
            Semester(name: "SoSe 2029", start: "2029-04-09", end: "2029-07-20", breaks: [("2029-05-22", "2029-05-25", "Exkursions- und Projektwoche")]),
            Semester(name: "WiSe 2029/30", start: "2029-10-08", end: "2030-02-01", breaks: [("2029-12-21", "2030-01-04", "Weihnachtspause")]),
            Semester(name: "SoSe 2030", start: "2030-04-15", end: "2030-07-26", breaks: [("2030-06-11", "2030-06-14", "Exkursions- und Projektwoche")]),
        ],
    ]

    /// `DEADLINE_LABELS`
    public static let deadlineLabels: [String: String] = ["abgabe": "Abgabe", "test_ende": "Test endet", "test_beginn": "Test beginnt",
                                                          "frist": "Frist", "termin": "Termin"]

    /// `easter(year)`: Ostersonntag (gregorianisch, Algorithmus nach Meeus/Jones/Butcher) als Tagesnummer
    public static func easter(year: Int) -> Int {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31, day = (h + l - 7 * m + 114) % 31
        return BerlinClock.dayNumber(year: year, month: month, day: day + 1)
    }

    /// `public_holidays(year)`: gesetzliche Feiertage in Niedersachsen (Reformationstag seit 2018), nach Datum
    public static func publicHolidays(year: Int) -> [(date: String, name: String)] {
        let e = easter(year: year)
        var days: [(Int, String)] = [
            (BerlinClock.dayNumber(year: year, month: 1, day: 1), "Neujahr"), (e - 2, "Karfreitag"), (e + 1, "Ostermontag"),
            (BerlinClock.dayNumber(year: year, month: 5, day: 1), "Tag der Arbeit"), (e + 39, "Christi Himmelfahrt"),
            (e + 50, "Pfingstmontag"), (BerlinClock.dayNumber(year: year, month: 10, day: 3), "Tag der Deutschen Einheit"),
            (BerlinClock.dayNumber(year: year, month: 12, day: 25), "1. Weihnachtstag"),
            (BerlinClock.dayNumber(year: year, month: 12, day: 26), "2. Weihnachtstag"),
        ]
        if year >= 2018 { days.append((BerlinClock.dayNumber(year: year, month: 10, day: 31), "Reformationstag")) }
        return days.sorted { $0.0 < $1.0 }.map { (BerlinClock.isoDate($0.0), $0.1) }
    }

    /// `day_marks(start, end, university)`: Markierungen je Tag im Zeitraum: feiertag | pause (Weihnachtspause,
    /// Exkursionswoche) | vorlesungsfrei. Nur Tage mit Markierung stehen im Ergebnis; Feiertage zuerst.
    public static func dayMarks(from start: Int, to end: Int, university: String) -> [String: [JSONValue]] {
        guard start <= end else { return [:] }
        var out: [String: [JSONValue]] = [:]
        func add(_ day: Int, _ kind: String, _ label: String) {
            guard day >= start, day <= end else { return }
            out[BerlinClock.isoDate(day), default: []].append(["kind": .string(kind), "label": .string(label)])
        }
        let (y0, y1) = (BerlinClock.civil(start).year, BerlinClock.civil(end).year)
        for y in y0...y1 {
            for (day, name) in publicHolidays(year: y) {
                if let d = BerlinClock.parseISODate(day) { add(d, "feiertag", name) }
            }
        }
        let sems = semesters[university] ?? []
        for s in sems {
            for b in s.breaks {
                guard let a = BerlinClock.parseISODate(b.from), let z = BerlinClock.parseISODate(b.to), a <= z else { continue }
                for d in a...z { add(d, "pause", b.label) }
            }
        }
        for (prev, next) in zip(sems, sems.dropFirst()) {
            guard let a = BerlinClock.parseISODate(prev.end), let z = BerlinClock.parseISODate(next.start), a + 1 <= z - 1 else { continue }
            for d in (a + 1)...(z - 1) { add(d, "vorlesungsfrei", "Vorlesungsfreie Zeit") }
        }
        return out
    }

    /// `default_term(university, today)`: Vorlesungszeit des laufenden oder naechsten Semesters laut Zeitplan
    /// (Vorgabe fuer den Stundenplan); nil, wenn der Zeitplan nichts (mehr) kennt
    public static func defaultTerm(university: String, today: String) -> Semester? {
        semesters[university]?.first { !PyText.less($0.end, today) }
    }

    /// `lecture_free(day, university)`: Feiertag, Unterbrechung oder vorlesungsfreie Zeit
    public static func lectureFree(day: Int, university: String) -> Bool {
        !dayMarks(from: day, to: day, university: university).isEmpty
    }

    /// Hochschule der Datenbank (`config.university()` am PC): `settings.university`, sonst die Vorgabe
    static func university(_ c: SQLiteConnection) throws -> String {
        let stored = try c.scalar("SELECT value FROM settings WHERE key='university'")?.string
        return stored.flatMap { UniversityKey.valid($0) ? $0 : nil } ?? Migrations.defaultUniversity
    }

    /// `calendar_extras(conn, start, end, university)`: (Markierungen je Tag, Learnweb-Fristen je Tag) fuer
    /// Lernkalender und Stundenplan
    static func calendarExtras(_ c: SQLiteConnection, from start: Int, to end: Int,
                               university: String? = nil) throws -> (marks: [String: [JSONValue]], deadlines: [String: [JSONValue]]) {
        let marks = dayMarks(from: start, to: end, university: try university ?? Self.university(c))
        var byDay: [String: [JSONValue]] = [:]
        for r in try c.rows("""
            SELECT d.id, d.title, d.full_title, d.kind, d.due_at, d.url, d.overdue, c.title AS course_title, m.color
                                          FROM deadlines d LEFT JOIN courses c ON c.id=d.course_id LEFT JOIN modules m ON m.id=c.module_id
                                          WHERE d.due_at >= ? AND d.due_at < ? ORDER BY d.due_at
            """, [.text(BerlinClock.isoDate(start)), .text(BerlinClock.isoDate(end + 1))]) {
            guard let due = r["due_at"]?.string else { throw LocalHTTPError(status: 500, message: "due_at ist kein Text") }
            let kind = r["kind"]?.string ?? ""
            let overdue = LocalModules.truthy(r["overdue"])
            byDay[PyText.slice(due, 0, 10), default: []].append([
                "id": r["id"] ?? .null, "title": r["title"] ?? .null, "full_title": LocalTimetable.or(r["full_title"], r["title"] ?? .null),
                "kind": r["kind"] ?? .null,
                "kind_label": .string((deadlineLabels[kind] ?? "Frist") + (overdue ? " (überfällig)" : "")),
                "time": .string(PyText.slice(due, 11, 16)), "url": r["url"] ?? .null, "overdue": .bool(overdue),
                "course_title": r["course_title"] ?? .null, "color": r["color"] ?? .null,
            ])
        }
        // Geraet: erkannte Abgaben, Tests und Pruefungen aus Dokumenten und Ankuendigungen (DueStore; am PC keine),
        // mit den Learnweb-Fristen nach Uhrzeit (ohne Uhrzeit zuerst)
        for (day, list) in try DueStore.calendarDays(c, from: start, to: end) {
            byDay[day] = LocalTimetable.stableSorted((byDay[day] ?? []) + list) { a, b in
                PyText.less(LocalTimetable.or(a["time"], "").string ?? "", LocalTimetable.or(b["time"], "").string ?? "")
            }
        }
        return (marks, byDay)
    }
}
