import Foundation

/// Seminare und Blockveranstaltungen mit wenigen Terminwochen (14.11.2026, erstes echtes Hildesheim-Konto: ein
/// Seminar "Nachhaltigkeit(sbildung) trifft Diversity" stand im Moduldetail in 15 Wochen).
///
/// Bisher: Eine Nummer im Dateinamen ("Sitzung 3", "VL 3", "Teil 3") wird zur Lehrwoche 3 (`LectureWeeks`, Regel 2).
/// Das passt zu einer Vorlesung jede Woche. Ein Blockseminar mit drei Terminwochenenden und "Sitzung 1" bis
/// "Sitzung 15" stand so ueber die ganze Vorlesungszeit verteilt, obwohl es nur in drei Wochen Termine gibt.
///
/// Jetzt: Hat ein Modul laut Stundenplan (LSF, Stud.IP, eigener Termin) Termine in hoechstens der Haelfte der
/// Lehrwochen, kommt eine nummerierte Datei in die Woche des passenden Termins: Sitzung n in die Woche des n-ten
/// Termins, bei mehr Nummern als Terminwochen anteilig ("Sitzung 1-5" in die erste Terminwoche usw.). Zuordnungen
/// ueber ein Datum, einen Wochen- oder Kalenderwochen-Abschnitt und die eigene Ordnung des Nutzers bleiben, wie sie sind;
/// gespeichert wird nichts (die Woche ergibt sich bei jedem Lesen aus Zuordnung und Stundenplan).
struct SessionWeeks: Sendable, Equatable {
    /// Wochen (wie `LectureWeeks.displayWeek`) mit mindestens einem Termin, aufsteigend
    let weeks: [Int]
    /// hoechste Nummer der nummerierten Dateien des Moduls
    let top: Int

    /// Woche einer nummerierten Datei; nil, wenn die Zuordnung keine Nummer ist
    func week(for s: LectureWeeks.Stored, displayWeek w: Int, term: LectureWeeks.Term) -> Int? {
        guard let n = Self.number(s, term: term), !weeks.isEmpty, top > 0 else { return nil }
        let idx = top <= weeks.count ? n : Int((Double(n * weeks.count) / Double(top)).rounded(.up))
        return weeks[min(max(idx, 1), weeks.count) - 1]
    }

    /// Lehrwoche einer Zuordnung ueber eine Nummer im Namen (nicht "KW n", nicht "Woche n"), sonst nil
    static func number(_ s: LectureWeeks.Stored, term: LectureWeeks.Term) -> Int? {
        guard s.rule == LectureWeeks.Rule.name.rawValue, let d = s.detail, let m = s.monday else { return nil }
        let kind = d.split(separator: " ").first.map(String.init) ?? ""
        guard kind != LectureWeeks.NumberKind.calendarWeek.rawValue, kind != LectureWeeks.NumberKind.week.rawValue else { return nil }
        return term.lectureWeek(ofMonday: m)
    }

    /// Module mit wenigen Terminwochen (hoechstens die Haelfte der Lehrwochen) und nummerierten Dateien
    static func load(_ c: SQLiteConnection, term: LectureWeeks.Term, start: Int,
                     stored: [String: LectureWeeks.Stored]) throws -> [Int64: SessionWeeks] {
        let count = term.lectureMondays.count
        guard count > 1 else { return [:] }
        var byModule: [Int64: Set<Int>] = [:]
        for e in try c.rows("SELECT e.weekday, e.rrule, e.date_from, e.date_to, e.attend, \(LocalTimetable.eventModuleSQL) AS module_ref FROM course_events e") {
            guard (e["attend"]?.int ?? 1) != 0, let m = e["module_ref"]?.int.map(Int64.init) else { continue }
            for day in days(e, term: term) {
                guard let mon = term.weekMonday(forDay: day) else { continue }
                let w = BerlinClock.floorDiv(mon - start, 7) + 1
                if w >= 1 { byModule[m, default: []].insert(w) }
            }
        }
        let few = byModule.filter { !$0.value.isEmpty && $0.value.count * 2 <= count }
        guard !few.isEmpty else { return [:] }
        var top: [Int64: Int] = [:]
        for r in try c.rows("SELECT f.id, co.module_id FROM files f JOIN courses co ON co.id = f.course_id WHERE co.module_id IS NOT NULL") {
            guard let id = r["id"]?.string, let m = r["module_id"]?.int.map(Int64.init), few[m] != nil, let s = stored[id],
                  let n = number(s, term: term) else { continue }
            top[m] = max(top[m] ?? 0, n)
        }
        var out: [Int64: SessionWeeks] = [:]
        for (m, ws) in few { if let t = top[m] { out[m] = SessionWeeks(weeks: ws.sorted(), top: t) } }
        return out
    }

    /// Tage eines Termins in der Vorlesungszeit (einmalig, woechentlich, 14-taeglich; ohne Ausnahmen)
    static func days(_ e: [String: JSONValue], term: LectureWeeks.Term) -> [Int] {
        let from = e["date_from"]?.string.flatMap(BerlinClock.parseISODate)
        if e["rrule"]?.string == "once" {
            guard let d = from, d >= term.start - 7, d <= term.end else { return [] }
            return [d]
        }
        let step = e["rrule"]?.string == "biweekly" ? 14 : 7
        let first = max(from ?? term.start, term.start - 7)
        let last = min(e["date_to"]?.string.flatMap(BerlinClock.parseISODate) ?? term.end, term.end)
        guard first <= last, let wd = e["weekday"]?.int else { return [] }
        // erster passender Wochentag ab `first` (0 = Montag); 14-taeglich ab dem ersten Termin
        var d = first + ((wd - (first - StudyWeeks.monday(first))) % 7 + 7) % 7
        var out: [Int] = []
        while d <= last && out.count < 60 {
            out.append(d)
            d += step
        }
        return out
    }
}
