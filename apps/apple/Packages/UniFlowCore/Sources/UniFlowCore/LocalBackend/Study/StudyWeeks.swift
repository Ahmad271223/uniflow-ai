import Foundation

/// Semesterwochen wie app/study.py (`semester_cut`, `semester_start`, `week_index`, `week_label`). Tage sind Tage
/// seit 1970-01-01 in Berliner Ortszeit (`BerlinClock`), wie `date` und `datetime.fromtimestamp` auf dem PC-Server.
/// Stichtag und Woche 0 vor dem Vorlesungsbeginn: Korrektur vom 25.10.2026, zuerst in Python
/// (tests/test_study_weeks.py), dann hierher portiert.
public enum StudyWeeks {
    /// `monday(d)`
    static func monday(_ day: Int) -> Int { day - BerlinClock.weekday(day) }

    /// `semester_cut(t)`: der letzte 1.10. bzw. 1.3., der nicht nach `today` liegt
    public static func semesterCut(today: Int) -> Int {
        let t = BerlinClock.civil(today)
        if t.month >= 10 { return BerlinClock.dayNumber(year: t.year, month: 10, day: 1) }
        if t.month >= 3 { return BerlinClock.dayNumber(year: t.year, month: 3, day: 1) }
        return BerlinClock.dayNumber(year: t.year - 1, month: 10, day: 1)
    }

    /// `datetime.fromtimestamp(chdate).date()` fuer gespeicherte Unix-Zeiten. Text und Zeiten jenseits des Jahres
    /// 9999 scheitern wie in Python (dort 500).
    static func localDay(chdate v: SQLiteValue) throws -> Int {
        let invalid = LocalHTTPError(status: 500, message: "Ungültiges Änderungsdatum einer Datei")
        let seconds: Int
        switch v {
        case .integer(let i): seconds = Int(i)
        case .real(let d):
            guard d.isFinite, abs(d) < 1e12 else { throw invalid }
            seconds = Int(d.rounded(.down))
        case .null, .text, .blob: throw invalid
        }
        guard abs(seconds) < 253_402_300_000 else { throw invalid }
        return BerlinClock.local(utc: seconds).day
    }

    /// `not chdate` in Python
    static func isEmpty(chdate v: SQLiteValue) -> Bool {
        switch v {
        case .null: return true
        case .integer(let i): return i == 0
        case .real(let d): return d == 0
        case .text(let s): return s.isEmpty
        case .blob(let b): return b.isEmpty
        }
    }

    /// `semester_start(conn)`: Montag der ersten Woche, in der >= 5 Kurse Dateien hochgeladen haben (sonst >= 3,
    /// sonst die erste); ohne Dateien seit dem Stichtag der Montag dieser Woche.
    public static func semesterStart(_ c: SQLiteConnection, today: Int) throws -> Int {
        let cut = semesterCut(today: today)
        var per: [Int: Set<SQLiteValue>] = [:]
        for r in try c.query("SELECT course_id, chdate FROM files WHERE chdate >= ?", [.integer(Int64(BerlinClock.utcSeconds(day: cut, minutes: 0)))]) {
            per[monday(try localDay(chdate: r[1])), default: []].insert(r[0])
        }
        let mondays = per.keys.sorted()
        for mn in [5, 3, 1] {
            if let m = mondays.first(where: { per[$0]!.count >= mn }) { return m }
        }
        return monday(today)
    }

    /// `day_week(start, d)`: Semesterwoche eines Tages, -1 vor dem Stichtag (aelteres Semester), 0 nach dem
    /// Stichtag, aber vor dem Vorlesungsbeginn, sonst ab 1. Dieselbe Regel fuer Dateien (`weekIndex`) und Termine
    /// (`LocalModules.eventMaterials`), damit eine Datei und ein Termin am selben Tag in derselben Woche liegen.
    public static func dayWeek(start: Int, day d: Int, today: Int) -> Int {
        if d < semesterCut(today: today) { return -1 }
        return max(0, BerlinClock.floorDiv(monday(d) - start, 7) + 1)
    }

    /// `week_index(start, chdate)`: 0 ohne Datum, sonst `dayWeek` des Tages der Aenderung
    public static func weekIndex(start: Int, chdate: SQLiteValue, today: Int) throws -> Int {
        if isEmpty(chdate: chdate) { return 0 }
        return dayWeek(start: start, day: try localDay(chdate: chdate), today: today)
    }

    /// `week_label(start, w)`
    public static func weekLabel(start: Int, week w: Int) -> String {
        if w == -2 { return "Klausuren & Altklausuren" }
        if w == -1 { return "Ältere Unterlagen" }
        if w < 1 { return "Vor Vorlesungsbeginn" }
        let s = start + 7 * (w - 1)
        return "Woche \(w) · \(dayMonth(s)) – \(dayMonth(s + 6))"
    }

    /// `strftime('%d.%m.')`
    static func dayMonth(_ day: Int) -> String {
        let c = BerlinClock.civil(day)
        return BerlinClock.pad(c.day, 2) + "." + BerlinClock.pad(c.month, 2) + "."
    }
}
