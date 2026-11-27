import EventKit
import Foundation
import SwiftUI
import UniFlowCore

// Termine in den Kalender des Geraets (26.11.2026, docs/KALENDER-COUNTDOWN-NACHRICHTEN-2026-11-26.md). Auftrag des
// Inhabers nach dem Vergleich mit einer freien Stud.IP-App: dort ein eigener Kalender mit den naechsten 8 Wochen, einmal
// am Tag neu. Hier genauer:
//  - Quelle ist der Stundenplan, wie er in der App steht (GET /api/timetable/week: Stud.IP, LSF, Campusmanagement, eigene
//    Termine, Aenderungen, Ausfaelle, Verlegungen, vorlesungsfreie Tage, Feiertage), dazu wahlweise Abgaben (Feld
//    `deadlines` derselben Antwort) und Pruefungen (GET /api/exams/upcoming).
//  - Abgleich statt Neuanlage: jedes Ereignis traegt eine feste Kennung in seiner Adresse (uniflow://…&sn=<Kennung>).
//    Geaendertes wird geaendert, Entfallenes entfernt, Doppeltes geloescht. Ereignisse ohne diese Kennung und alles
//    ausserhalb des eigenen Kalenders fasst die App nie an. Vergangenes bleibt stehen.
//  - Wann: nach jedem Abgleich, beim Oeffnen (hoechstens alle 10 Minuten), beim Wechsel in den Hintergrund (eigene
//    Aenderungen am Stundenplan), beim Wechsel des Containers und wenn sich eine Einstellung aendert.
//  - Nur EventKit auf dem Geraet, nichts an einen Server von StudiNow. Der Kalender entsteht dort, wo iOS neue Termine
//    anlegt (meist iCloud: dann sehen ihn auch Mac und Watch; mehrere Geraete teilen ihn, gleiche Kennungen = nichts
//    doppelt), sonst "Auf meinem iPad". Abschalten entfernt den Kalender.
//  - Erlaubnis erst beim Einschalten (Vollzugriff: nur damit laesst sich ein eigener Kalender anlegen und abgleichen).

/// Einstellungen des Kalender-Abgleichs (Geraet, `UserDefaults.standard`): Vorgabe aus
struct CalendarExportSettings: Equatable {
    enum Range: String, CaseIterable, Identifiable {
        case weeks2, weeks4, weeks8, term
        var id: String { rawValue }
        var label: String {
            switch self {
            case .weeks2: return "2 Wochen"
            case .weeks4: return "4 Wochen"
            case .weeks8: return "8 Wochen"
            case .term: return "Ganzes Semester"
            }
        }
    }

    var enabled = false
    var range: Range = .term
    /// Abgaben, Tests und Fristen
    var deadlines = true
    /// Klausuren und Pruefungen
    var exams = true
    /// Ausfaelle, die die App durchgestrichen zeigt, als "Fällt aus: …" stehen lassen (sonst entfernt). Ausfaelle laut
    /// Stud.IP blendet die App aus, sie fehlen also immer.
    var cancelled = true
    /// Feiertage, Unterbrechungen und vorlesungsfreie Zeit als ganztaegige Eintraege
    var holidays = true

    enum Keys {
        static let enabled = "uniflow.calendarExport.enabled"
        static let range = "uniflow.calendarExport.range"
        static let deadlines = "uniflow.calendarExport.deadlines"
        static let exams = "uniflow.calendarExport.exams"
        static let cancelled = "uniflow.calendarExport.cancelled"
        static let holidays = "uniflow.calendarExport.holidays"
        static let calendarID = "uniflow.calendarExport.calendarID"
        static let lastRun = "uniflow.calendarExport.lastRun"
        static let lastCount = "uniflow.calendarExport.lastCount"
    }

    static func load(_ d: UserDefaults = .standard) -> CalendarExportSettings {
        var s = CalendarExportSettings()
        s.enabled = d.bool(forKey: Keys.enabled)
        s.range = d.string(forKey: Keys.range).flatMap(Range.init(rawValue:)) ?? .term
        for (key, path) in [(Keys.deadlines, \CalendarExportSettings.deadlines), (Keys.exams, \.exams), (Keys.cancelled, \.cancelled),
                            (Keys.holidays, \.holidays)] where d.object(forKey: key) != nil {
            s[keyPath: path] = d.bool(forKey: key)
        }
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(enabled, forKey: Keys.enabled)
        d.set(range.rawValue, forKey: Keys.range)
        d.set(deadlines, forKey: Keys.deadlines)
        d.set(exams, forKey: Keys.exams)
        d.set(cancelled, forKey: Keys.cancelled)
        d.set(holidays, forKey: Keys.holidays)
    }
}

/// Ein Eintrag, wie er im Kalender stehen soll (und wie ein vorhandener gelesen wird)
struct CalendarItem: Equatable {
    var key: String
    var title: String
    var start: Date
    /// bei ganztaegigen der Beginn des letzten Tages
    var end: Date
    var allDay = false
    var location: String?
    var notes: String
    var url: URL?
    /// als "frei" eintragen (Ausfall, Abgabe, Feiertag): blockiert in anderen Kalendern keine Zeit
    var free = false

    /// Gleich genug, um nichts zu schreiben (Text ohne Raender, ganztaegige nach Tagen). `availability: false`: der
    /// Kalender kennt "frei/beschäftigt" nicht (lokale Kalender, Befund im Simulator 26.11.2026: liest immer "beschäftigt"
    /// zurueck), dann zaehlt es nicht – sonst schriebe jeder Abgleich dieselben Eintraege neu.
    func sameContent(as o: CalendarItem, availability: Bool = true, calendar cal: Calendar = .current) -> Bool {
        func t(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard title == o.title, allDay == o.allDay, t(location) == t(o.location), t(notes) == t(o.notes),
              url?.absoluteString == o.url?.absoluteString, !availability || free == o.free else { return false }
        if allDay {
            return cal.isDate(start, inSameDayAs: o.start) && cal.isDate(end, inSameDayAs: o.end)
        }
        return abs(start.timeIntervalSince(o.start)) < 1 && abs(end.timeIntervalSince(o.end)) < 1
    }
}

/// Ein Ereignis im eigenen Kalender
struct StoredCalendarEvent: Equatable {
    /// Kennung von EventKit (`eventIdentifier`)
    var id: String
    /// Kennung von StudiNow aus der Adresse; nil = nicht von StudiNow (wird nie angefasst)
    var key: String?
    var item: CalendarItem
}

/// Was der Abgleich tun soll
struct CalendarExportChanges: Equatable {
    var create: [CalendarItem] = []
    /// (Kennung von EventKit, neuer Inhalt)
    var update: [(id: String, item: CalendarItem)] = []
    var remove: [String] = []

    var isEmpty: Bool { create.isEmpty && update.isEmpty && remove.isEmpty }

    static func == (a: Self, b: Self) -> Bool {
        a.create == b.create && a.remove == b.remove && a.update.map(\.id) == b.update.map(\.id) && a.update.map(\.item) == b.update.map(\.item)
    }
}

/// Reine Regeln: Eintraege aus den Antworten der Datenquelle und der Abgleich mit dem Kalender (CalendarExportAppTests)
enum CalendarExportPlan {
    static let scheme = "uniflow"
    static let keyParam = "sn"
    /// laenger als ein Semester wird nie eingetragen
    static let maxDays = 200
    /// Abgaben mit Uhrzeit: so lang ist der Eintrag, er endet zur Frist
    static let deadlineMinutes = 15
    static let footer = "Aus StudiNow · wird automatisch abgeglichen. Änderungen hier überschreibt der nächste Abgleich."

    static let kindLabels: [String: String] = [
        "vorlesung": "Vorlesung", "uebung": "Übung", "tutorium": "Tutorium", "seminar": "Seminar", "praktikum": "Praktikum",
        "labor": "Labor", "sprechstunde": "Sprechstunde", "pruefung": "Prüfung", "klausur": "Klausur", "eigener": "Eigener Termin",
    ]

    // MARK: Zeitraum

    /// Letzter Tag (ISO) ab `today` fuer die Einstellung; "Ganzes Semester" bis zum Semesterende, mindestens 2 Wochen,
    /// hoechstens `maxDays`; ohne lesbares Semesterende 8 Wochen
    static func lastDay(today: String, range: CalendarExportSettings.Range, termEnd: String?) -> String {
        switch range {
        case .weeks2: return Mensa.addDays(today, 13)
        case .weeks4: return Mensa.addDays(today, 27)
        case .weeks8: return Mensa.addDays(today, 55)
        case .term:
            guard let end = termEnd.map({ String($0.prefix(10)) }), end.count == 10, HomeWidgetClock.date(day: end, time: "00:00") != nil else {
                return Mensa.addDays(today, 55)
            }
            let minEnd = Mensa.addDays(today, 13), maxEnd = Mensa.addDays(today, maxDays - 1)
            return min(max(end, minEnd), maxEnd)
        }
    }

    // MARK: Kennung und Adresse

    /// Feste Kennung eines Vorkommens: Serie + Tag (verlegte behalten die Kennung ihres urspruenglichen Tages, so wird
    /// der Eintrag verschoben statt neu angelegt), Einzeltermin der Quelle, sonst Quelle + Tag + Beginn + Titel
    static func key(occurrence e: JSONValue) -> String {
        let date = e.s("date") ?? ""
        if let id = e["event_id"]?.int ?? e["event_id"]?.string.flatMap(Int.init) {
            if e.s("exception") == "moved_here", let from = e.s("moved_from"), !from.isEmpty { return "e\(id)@\(from)" }
            return "e\(id)@\(date)"
        }
        if let sid = e.s("studip_id") ?? e["studip_id"]?.int.map(String.init), !sid.isEmpty {
            return "s\(e.s("source") ?? "")|\(sid)"
        }
        return "t\(e.s("source") ?? "")|\(date)|\(e.s("start") ?? "")|\(e.s("title") ?? "")"
    }

    /// uniflow://#/timetable?date=…&sn=<Kennung> (oeffnet den Tag im Stundenplan; die Kennung liest nur der Abgleich)
    static func url(route: String, date: String?, key: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let d = date.map { "date=\($0)&" } ?? ""
        return URL(string: "\(scheme)://#/\(route)?\(d)\(keyParam)=\(k)")
    }

    /// Kennung aus der Adresse eines Ereignisses; nil, wenn es nicht von StudiNow ist
    static func key(from url: URL?) -> String? {
        guard let url, url.scheme == scheme else { return nil }
        let s = url.absoluteString
        guard let q = s.range(of: "?") else { return nil }
        for part in s[q.upperBound...].split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == keyParam {
                let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    // MARK: Eintraege

    /// Alle Eintraege zwischen `from` und `to` (ISO-Tage, einschliesslich) aus den Wochen von GET /api/timetable/week,
    /// den Ausfaellen laut Stud.IP und den Pruefungen von GET /api/exams/upcoming
    static func items(weeks: [JSONValue], cancelled: Set<String>, exams: [JSONValue], settings: CalendarExportSettings,
                      from: String, to: String) -> [CalendarItem] {
        var out: [CalendarItem] = []
        var keys = Set<String>()
        var slots = Set<String>()
        func add(_ i: CalendarItem) { if keys.insert(i.key).inserted { out.append(i) } }

        var days: [JSONValue] = []
        for w in weeks { for d in w.list("days") { if let date = d.s("date"), date >= from, date <= to { days.append(d) } } }
        days.sort { ($0.s("date") ?? "") < ($1.s("date") ?? "") }

        // Pruefungstage (fuer erkannte Pruefungen in `deadlines`, die dann nicht doppelt stehen)
        let examDays = Set(exams.compactMap { $0.s("date") })

        for day in days {
            guard let date = day.s("date") else { continue }
            for e in day.list("events") {
                guard let i = occurrenceItem(e, date: date, cancelled: cancelled, settings: settings) else { continue }
                // dieselbe Veranstaltung aus zwei Quellen (gleicher Titel, gleiche Zeit): einmal
                let slot = "\(i.title)|\(i.start.timeIntervalSince1970)|\(i.end.timeIntervalSince1970)"
                guard slots.insert(slot).inserted else { continue }
                add(i)
            }
            for d in day.list("deadlines") {
                let kind = d.s("kind") ?? ""
                let isExam = ["pruefung", "klausur"].contains(kind)
                if isExam ? (!settings.exams || examDays.contains(date)) : !settings.deadlines { continue }
                if let i = deadlineItem(d, date: date) { add(i) }
            }
        }
        if settings.exams {
            for x in exams {
                guard let date = x.s("date"), date >= from, date <= to, let i = examItem(x) else { continue }
                add(i)
            }
        }
        if settings.holidays { for i in holidayItems(days) { add(i) } }
        return out.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
    }

    /// Ein Vorkommen des Stundenplans; nil, wenn es nicht in den Kalender gehoert (nicht besucht, verlegt – der
    /// verlegte Termin steht an seinem neuen Tag –, vorlesungsfrei, Ausfall ohne "Ausfälle zeigen")
    static func occurrenceItem(_ e: JSONValue, date: String, cancelled: Set<String>, settings: CalendarExportSettings) -> CalendarItem? {
        let status = e.s("status") ?? "teilnahme"
        // Ausfaelle laut Stud.IP blendet die App aus wie Stud.IP selbst (Entscheidung des Inhabers 28.10.2026,
        // `StudIPCancellations`): im Kalender also auch nicht; selbst markierte Ausfaelle stehen in der App
        // durchgestrichen da und hier als "Fällt aus: …"
        if StudIPCancellations.hides(e, keys: cancelled) { return nil }
        let isCancelled = status == "ausfall"
        if isCancelled {
            if e.s("exception") == "vorlesungsfrei" || !settings.cancelled { return nil }
        } else if status != "teilnahme" {
            return nil
        }
        guard let s = e.s("start"), let start = HomeWidgetClock.date(day: date, time: s) else { return nil }
        let end = e.s("end").flatMap { HomeWidgetClock.date(day: date, time: $0) }.flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(90 * 60)
        let raw = (e.s("title") ?? e.s("module_name") ?? "Termin").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = raw.isEmpty ? "Termin" : raw
        let key = key(occurrence: e)

        var notes: [String] = []
        if isCancelled {
            let why = e.s("note").flatMap { $0.isEmpty ? nil : $0 } ?? "von dir als Ausfall markiert"
            notes.append("Fällt aus (\(why)).")
        } else if e["cancel_hint"].map({ !$0.isNull }) == true {
            notes.append("Hinweis: Laut einer Ankündigung fällt dieser Termin vielleicht aus. Bitte in StudiNow prüfen.")
        }
        if e.s("exception") == "moved_here", let from = e.s("moved_from") {
            notes.append("Verlegt vom \(shortDay(from)).")
        }
        let kind = kindLabels[e.s("kind") ?? ""]
        let module = e.s("module_name").flatMap { $0.isEmpty || $0 == name ? nil : $0 }
        let head = [kind, module.map { "Modul \($0)" }].compactMap { $0 }.joined(separator: " · ")
        if !head.isEmpty { notes.append(head) }
        if let l = e.s("lecturer")?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty { notes.append("Lehrende: \(l)") }
        if let t = e.s("session_topic")?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { notes.append("Thema: \(t)") }
        if !isCancelled, let n = e.s("note")?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { notes.append("Notiz: \(n)") }
        notes.append(footer)
        let room = e.s("room")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarItem(key: key, title: isCancelled ? "Fällt aus: \(name)" : name, start: start, end: end,
                            location: room?.isEmpty == false ? room : nil, notes: notes.joined(separator: "\n"),
                            url: url(route: "timetable", date: date, key: key), free: isCancelled)
    }

    /// Abgabe, Test oder Frist: mit Uhrzeit ein kurzer Eintrag, der zur Frist endet; ohne Uhrzeit ganztaegig
    static func deadlineItem(_ d: JSONValue, date: String) -> CalendarItem? {
        let id = d.s("id") ?? d["id"]?.int.map(String.init) ?? ""
        let title = (d.s("title") ?? d.s("full_title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let label = (d.s("kind_label") ?? "Frist").replacingOccurrences(of: " (überfällig)", with: "")
        let key = "d\(id.isEmpty ? "\(date)|\(title)" : id)"
        var notes: [String] = []
        if let c = d.s("course_title"), !c.isEmpty { notes.append("Kurs: \(c)") }
        if let o = d.s("origin"), !o.isEmpty { notes.append("Gefunden in: \(o)") }
        notes.append(footer)
        let time = d.s("time").flatMap { $0.isEmpty ? nil : $0 }
        if let time, let due = HomeWidgetClock.date(day: date, time: time) {
            return CalendarItem(key: key, title: "\(label): \(title) (bis \(time))", start: due.addingTimeInterval(-Double(deadlineMinutes) * 60), end: due,
                                notes: notes.joined(separator: "\n"), url: url(route: "timetable", date: date, key: key), free: true)
        }
        guard let day = allDayDate(date) else { return nil }
        return CalendarItem(key: key, title: "\(label): \(title)", start: day, end: day, allDay: true,
                            notes: notes.joined(separator: "\n"), url: url(route: "timetable", date: date, key: key), free: true)
    }

    /// Klausur oder Pruefung (GET /api/exams/upcoming): mit Uhrzeit von–bis (ohne Ende 2 Stunden), sonst ganztaegig
    static func examItem(_ x: JSONValue) -> CalendarItem? {
        guard let date = x.s("date") else { return nil }
        let title = (x.s("title") ?? "Prüfung").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "x\(x.s("id") ?? "\(date)|\(title)")"
        var notes: [String] = []
        if let m = x.s("module_name"), !m.isEmpty, !title.contains(m) { notes.append("Modul \(m)") }
        if let s = x.s("source_label"), !s.isEmpty { notes.append("Quelle: \(s)") }
        notes.append(footer)
        let room = x.s("room").flatMap { $0.isEmpty ? nil : $0 }
        if let t = x.s("time"), !t.isEmpty, let start = HomeWidgetClock.date(day: date, time: t) {
            let end = x.s("end").flatMap { HomeWidgetClock.date(day: date, time: $0) }.flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(2 * 3600)
            return CalendarItem(key: key, title: title, start: start, end: end, location: room, notes: notes.joined(separator: "\n"),
                                url: url(route: "exams", date: nil, key: key))
        }
        guard let day = allDayDate(date) else { return nil }
        return CalendarItem(key: key, title: title, start: day, end: day, allDay: true, location: room, notes: notes.joined(separator: "\n"),
                            url: url(route: "exams", date: nil, key: key))
    }

    /// Feiertage, Unterbrechungen und vorlesungsfreie Zeit (Feld `marks`): aufeinanderfolgende Tage mit derselben
    /// Bezeichnung als ein ganztaegiger Eintrag. Kennung: Art + Bezeichnung + laufende Nummer im Zeitraum (bleibt
    /// stehen, wenn der Zeitraum weiterrueckt; der Eintrag wird dann nur kuerzer bzw. laenger)
    static func holidayItems(_ days: [JSONValue]) -> [CalendarItem] {
        struct Run { var kind: String; var label: String; var first: String; var last: String }
        var runs: [Run] = []
        var open: [String: Int] = [:]                       // kind|label -> Index des Laufs, der gestern noch lief
        var prevDate: String?
        for day in days {
            guard let date = day.s("date") else { continue }
            let continues = prevDate.map { Mensa.addDays($0, 1) == date } ?? false
            var seen = Set<String>()
            for m in day.list("marks") {
                guard let kind = m.s("kind"), let label = m.s("label"), !label.isEmpty else { continue }
                let id = "\(kind)|\(label)"
                guard seen.insert(id).inserted else { continue }
                if continues, let i = open[id], runs[i].last == prevDate { runs[i].last = date } else {
                    runs.append(Run(kind: kind, label: label, first: date, last: date))
                    open[id] = runs.count - 1
                }
            }
            prevDate = date
        }
        var count: [String: Int] = [:]
        return runs.compactMap { r in
            guard let a = allDayDate(r.first), let z = allDayDate(r.last) else { return nil }
            let id = "\(r.kind)|\(r.label)"
            let n = count[id, default: 0]
            count[id] = n + 1
            let key = "h\(id)|\(n)"
            let what = r.kind == "feiertag" ? "Feiertag – keine Lehrveranstaltungen." : "Keine Lehrveranstaltungen."
            return CalendarItem(key: key, title: r.label, start: a, end: z, allDay: true, notes: "\(what)\n\(footer)",
                                url: url(route: "timetable", date: r.first, key: key), free: true)
        }
    }

    /// Ganztaegig: Tagesbeginn im Kalender des Geraets (schwebend, ohne Zeitzone)
    static func allDayDate(_ iso: String, calendar: Calendar = .current) -> Date? {
        let p = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    static func shortDay(_ iso: String) -> String {
        let p = iso.prefix(10).split(separator: "-")
        guard p.count == 3 else { return iso }
        return "\(p[2]).\(p[1])."
    }

    // MARK: Abgleich

    /// Vergleich mit den Ereignissen des eigenen Kalenders im Zeitraum. Ereignisse ohne Kennung bleiben, wie sie
    /// sind; je Kennung bleibt eins (Doppelte weg), Geaendertes wird geaendert, Fehlendes angelegt, nicht mehr
    /// Gewuenschtes entfernt.
    /// `today`: ein ganztaegiger Eintrag, der schon vor heute begann (vorlesungsfreie Zeit), behaelt seinen Beginn.
    static func changes(existing: [StoredCalendarEvent], desired: [CalendarItem], today: Date? = nil, availability: Bool = true,
                        calendar: Calendar = .current) -> CalendarExportChanges {
        var out = CalendarExportChanges()
        var byKey: [String: StoredCalendarEvent] = [:]
        for e in existing {
            guard let k = e.key else { continue }
            if byKey[k] == nil { byKey[k] = e } else { out.remove.append(e.id) }
        }
        var wanted = Set<String>()
        for var d in desired {
            wanted.insert(d.key)
            if let e = byKey[d.key] {
                if d.allDay, e.item.allDay, let today, e.item.start < today, calendar.isDate(d.start, inSameDayAs: today) { d.start = e.item.start }
                if !e.item.sameContent(as: d, availability: availability, calendar: calendar) { out.update.append((e.id, d)) }
            } else {
                out.create.append(d)
            }
        }
        for (k, e) in byKey where !wanted.contains(k) { out.remove.append(e.id) }
        out.remove.sort()
        return out
    }
}

// MARK: - Kalender des Geraets

/// Zugriff auf den eigenen Kalender (EventKit; in Tests eine Attrappe)
@MainActor
protocol CalendarEventStoring: AnyObject {
    /// kennt der Kalender "frei/beschäftigt"?
    var supportsAvailability: Bool { get }
    /// Ereignisse des eigenen Kalenders, die in [from, to) liegen oder hineinreichen
    func events(from: Date, to: Date) throws -> [StoredCalendarEvent]
    func apply(_ changes: CalendarExportChanges) throws
}

/// EventKit-Anbindung: ein Kalender "StudiNow" in einer Quelle des Geraets
@MainActor
final class EventKitCalendarStore: CalendarEventStoring {
    static let calendarTitle = "StudiNow"
    let store: EKEventStore
    let calendar: EKCalendar
    private let timeZone = HomeWidgetClock.timeZone

    init(store: EKEventStore, calendar: EKCalendar) {
        self.store = store
        self.calendar = calendar
    }

    var supportsAvailability: Bool { !calendar.supportedEventAvailabilities.isEmpty }

    enum Problem: Error, Equatable {
        case noSource
        /// der gemerkte Kalender ist weg (in der Kalender-App geloescht)
        case calendarDeleted
    }

    /// Den eigenen Kalender finden oder anlegen. Gemerkte Kennung zuerst; ist sie weg, `calendarDeleted` (dann legt die
    /// App nicht ungefragt einen neuen an). Ohne gemerkte Kennung: ein vorhandener Kalender "StudiNow" der gewaehlten
    /// Quelle (nach Neuinstallation, mehrere Geraete in iCloud), sonst ein neuer.
    static func open(store: EKEventStore, defaults: UserDefaults = .standard, color: CGColor?) throws -> EventKitCalendarStore {
        let idKey = CalendarExportSettings.Keys.calendarID
        if let id = defaults.string(forKey: idKey) {
            if let c = store.calendar(withIdentifier: id) { return EventKitCalendarStore(store: store, calendar: c) }
            throw Problem.calendarDeleted
        }
        let sources = candidateSources(store)
        guard !sources.isEmpty else { throw Problem.noSource }
        let ids = Set(sources.map(\.sourceIdentifier))
        if let c = store.calendars(for: .event).first(where: { $0.title == calendarTitle && ids.contains($0.source.sourceIdentifier)
                                                                 && $0.allowsContentModifications }) {
            defaults.set(c.calendarIdentifier, forKey: idKey)
            return EventKitCalendarStore(store: store, calendar: c)
        }
        let c = EKCalendar(for: .event, eventStore: store)
        c.title = calendarTitle
        if let color { c.cgColor = color }
        var lastError: Error = Problem.noSource
        for source in sources {
            c.source = source
            do {
                try store.saveCalendar(c, commit: true)
                defaults.set(c.calendarIdentifier, forKey: idKey)
                return EventKitCalendarStore(store: store, calendar: c)
            } catch { lastError = error }
        }
        throw lastError
    }

    /// Wohin der Kalender darf, in dieser Reihenfolge: die Quelle, in der iOS neue Termine anlegt (meist iCloud), dann
    /// iCloud bzw. andere CalDAV-Konten, zuletzt "Auf meinem iPad/iPhone". Nicht zuerst lokal: ist der iCloud-Kalender an,
    /// zeigt die Kalender-App lokale Kalender oft gar nicht (Befund beim Vergleich mit dem Vorbild, 26.11.2026).
    /// Abonnierte Kalender, Geburtstage und Exchange (keine eigenen Kalender) scheiden aus.
    static func candidateSources(_ store: EKEventStore) -> [EKSource] {
        var out: [EKSource] = []
        if let d = store.defaultCalendarForNewEvents?.source, [.calDAV, .local].contains(d.sourceType) { out.append(d) }
        out += store.sources.filter { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") }
        out += store.sources.filter { $0.sourceType == .calDAV }
        out += store.sources.filter { $0.sourceType == .local }
        var seen = Set<String>()
        return out.filter { seen.insert($0.sourceIdentifier).inserted }
    }

    /// Eigenen Kalender samt Inhalt entfernen (Abschalten); ohne gemerkten Kalender nichts
    static func remove(store: EKEventStore, defaults: UserDefaults = .standard) throws {
        let idKey = CalendarExportSettings.Keys.calendarID
        defer { defaults.removeObject(forKey: idKey) }
        guard let id = defaults.string(forKey: idKey), let c = store.calendar(withIdentifier: id) else { return }
        try store.removeCalendar(c, commit: true)
    }

    func events(from: Date, to: Date) throws -> [StoredCalendarEvent] {
        // EventKit sucht hoechstens 4 Jahre auf einmal
        let pred = store.predicateForEvents(withStart: from, end: min(to, from.addingTimeInterval(4 * 365 * 86_400 - 86_400)), calendars: [calendar])
        return store.events(matching: pred).map { e in
            StoredCalendarEvent(id: e.eventIdentifier, key: CalendarExportPlan.key(from: e.url), item: Self.item(e))
        }
    }

    static func item(_ e: EKEvent, calendar cal: Calendar = .current) -> CalendarItem {
        let end: Date = e.isAllDay ? cal.startOfDay(for: e.endDate.addingTimeInterval(e.endDate > e.startDate ? -1 : 0)) : e.endDate
        return CalendarItem(key: CalendarExportPlan.key(from: e.url) ?? "", title: e.title ?? "", start: e.isAllDay ? cal.startOfDay(for: e.startDate) : e.startDate,
                            end: end, allDay: e.isAllDay, location: e.location, notes: e.notes ?? "", url: e.url, free: e.availability == .free)
    }

    func apply(_ changes: CalendarExportChanges) throws {
        guard !changes.isEmpty else { return }
        for id in changes.remove {
            if let e = store.event(withIdentifier: id), e.calendar.calendarIdentifier == calendar.calendarIdentifier {
                try store.remove(e, span: .thisEvent, commit: false)
            }
        }
        for (id, item) in changes.update {
            guard let e = store.event(withIdentifier: id), e.calendar.calendarIdentifier == calendar.calendarIdentifier else { continue }
            fill(e, item)
            try store.save(e, span: .thisEvent, commit: false)
        }
        for item in changes.create {
            let e = EKEvent(eventStore: store)
            e.calendar = calendar
            fill(e, item)
            try store.save(e, span: .thisEvent, commit: false)
        }
        try store.commit()
    }

    private func fill(_ e: EKEvent, _ i: CalendarItem) {
        e.title = i.title
        e.isAllDay = i.allDay
        e.timeZone = i.allDay ? nil : timeZone
        e.startDate = i.start
        e.endDate = i.end
        e.location = i.location
        e.notes = i.notes
        e.url = i.url
        if supportsAvailability { e.availability = i.free ? .free : .busy }
    }
}

// MARK: - Ablauf

/// Kalender-Abgleich der App (ein Objekt fuer alle Fenster)
@MainActor
final class CalendarExport: ObservableObject {
    static let shared = CalendarExport()

    enum Status: Equatable {
        case off
        /// Erlaubnis fehlt oder wurde abgelehnt bzw. nur "Nur hinzufügen" erlaubt
        case denied
        case writeOnly
        case running
        case ok(Date, count: Int)
        /// Kalender in der Kalender-App geloescht: Abgleich ausgeschaltet
        case calendarDeleted
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var settings: CalendarExportSettings
    /// zuletzt geschrieben: neu, geaendert, entfernt (fuer die Zeile in den Einstellungen)
    @Published private(set) var lastChanges: (created: Int, updated: Int, removed: Int) = (0, 0, 0)

    private let defaults: UserDefaults
    private var store: EKEventStore?
    private var running = false
    private var again = false
    private var lastRun: Date? { defaults.object(forKey: CalendarExportSettings.Keys.lastRun) as? Date }
    /// beim Oeffnen der App hoechstens so oft
    static let openInterval: TimeInterval = 10 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = CalendarExportSettings.load(defaults)
        if settings.enabled {
            let n = defaults.integer(forKey: CalendarExportSettings.Keys.lastCount)
            status = lastRun.map { .ok($0, count: n) } ?? .off
            if Self.authorization() != .fullAccess { status = Self.authorization() == .writeOnly ? .writeOnly : .denied }
        }
    }

    static func authorization() -> EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    private func eventStore() -> EKEventStore {
        if let store { return store }
        let s = EKEventStore()
        store = s
        return s
    }

    /// Einschalten fragt iOS nach der Erlaubnis (nur hier); ohne Vollzugriff bleibt der Schalter aus
    func setEnabled(_ on: Bool, api: APIClient?, demo: Bool) async {
        if !on {
            settings.enabled = false
            settings.save(defaults)
            if Self.authorization() == .fullAccess {
                do { try EventKitCalendarStore.remove(store: eventStore(), defaults: defaults) } catch { status = .failed(Self.message(error)); return }
            } else {
                defaults.removeObject(forKey: CalendarExportSettings.Keys.calendarID)
            }
            defaults.removeObject(forKey: CalendarExportSettings.Keys.lastRun)
            status = .off
            return
        }
        let granted: Bool
        do { granted = try await eventStore().requestFullAccessToEvents() } catch { granted = false }
        let auth = Self.authorization()
        guard granted, auth == .fullAccess else {
            status = auth == .writeOnly ? .writeOnly : .denied
            return
        }
        // neu anfordern: ein frischer Speicher sieht die eben erteilte Erlaubnis sicher
        store = EKEventStore()
        settings.enabled = true
        settings.save(defaults)
        await sync(api: api, demo: demo, force: true)
    }

    func update(_ change: (inout CalendarExportSettings) -> Void, api: APIClient?, demo: Bool) async {
        var s = settings
        change(&s)
        guard s != settings else { return }
        settings = s
        settings.save(defaults)
        await sync(api: api, demo: demo, force: true)
    }

    /// Abgleichen. `force: false` (Oeffnen der App) hoechstens alle `openInterval`. Ohne Datenquelle (abgemeldet)
    /// werden die kuenftigen Eintraege entfernt; mit Demo-Inhalten geschieht nichts (erfundene Termine gehoeren nicht
    /// in den echten Kalender).
    func sync(api: APIClient?, demo: Bool, force: Bool = true, now: Date = Date()) async {
        guard settings.enabled, !StudIPSync.isUnderTest(), !demo else { return }
        if !force, let l = lastRun, now.timeIntervalSince(l) < Self.openInterval { return }
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            await syncOnce(api: api, now: now)
        } while again
    }

    private func syncOnce(api: APIClient?, now: Date) async {
        guard Self.authorization() == .fullAccess else {
            status = Self.authorization() == .writeOnly ? .writeOnly : .denied
            return
        }
        let before = status
        status = .running
        do {
            let target = try EventKitCalendarStore.open(store: eventStore(), defaults: defaults, color: UIColor(UF.accent).cgColor)
            let desired: [CalendarItem]
            if let api {
                guard let d = await Self.desired(api: api, settings: settings, now: now) else {
                    status = before == .running ? .failed("Der Stundenplan ließ sich nicht lesen.") : before
                    return
                }
                desired = d
            } else {
                desired = []
            }
            let r = try Self.run(target: target, desired: desired, now: now)
            lastChanges = (r.create.count, r.update.count, r.remove.count)
            defaults.set(now, forKey: CalendarExportSettings.Keys.lastRun)
            defaults.set(desired.count, forKey: CalendarExportSettings.Keys.lastCount)
            status = .ok(now, count: desired.count)
        } catch EventKitCalendarStore.Problem.calendarDeleted {
            settings.enabled = false
            settings.save(defaults)
            defaults.removeObject(forKey: CalendarExportSettings.Keys.calendarID)
            status = .calendarDeleted
        } catch {
            status = .failed(Self.message(error))
        }
    }

    /// Gewuenschte Eintraege aus der Datenquelle; nil, wenn der Stundenplan nicht lesbar war (dann bleibt der Kalender)
    static func desired(api: APIClient, settings: CalendarExportSettings, now: Date) async -> [CalendarItem]? {
        let today = HomeWidgetClock.isoDay(now)
        guard let first = try? await api.value("/api/timetable/week?start=\(today)") else { return nil }
        let last = CalendarExportPlan.lastDay(today: today, range: settings.range, termEnd: first["term"]?.s("end"))
        var weeks = [first]
        var start = Mensa.addDays(today, 7)
        while start <= last {
            guard let w = try? await api.value("/api/timetable/week?start=\(start)") else { return nil }
            weeks.append(w)
            start = Mensa.addDays(start, 7)
        }
        let cancelled = await StudIPCancelled.keys(api, from: today, to: last)
        let exams = settings.exams ? ((try? await api.value("/api/exams/upcoming"))?.list("items") ?? []) : []
        return CalendarExportPlan.items(weeks: weeks, cancelled: cancelled, exams: exams, settings: settings, from: today, to: last)
    }

    /// Ein Abgleich gegen einen Kalender: Ereignisse ab heute lesen, vergleichen, schreiben
    @discardableResult
    static func run(target: CalendarEventStoring, desired: [CalendarItem], now: Date) throws -> CalendarExportChanges {
        let from = HomeWidgetClock.calendar.startOfDay(for: now)
        let existing = try target.events(from: from, to: from.addingTimeInterval(4 * 365 * 86_400))
            // laufende ganztaegige von gestern (Ende vor heute) und Vergangenes nie anfassen
            .filter { $0.item.allDay ? $0.item.end >= Calendar.current.startOfDay(for: now) : $0.item.end > from }
        let c = CalendarExportPlan.changes(existing: existing, desired: desired, today: Calendar.current.startOfDay(for: now),
                                           availability: target.supportsAvailability)
        try target.apply(c)
        return c
    }

    static func message(_ error: Error) -> String {
        if let p = error as? EventKitCalendarStore.Problem, p == .noSource {
            return "Auf diesem Gerät gibt es keinen Kalender, in den StudiNow schreiben darf."
        }
        return "Der Kalender ließ sich nicht abgleichen (\(error.localizedDescription))."
    }

    // MARK: Texte (Einstellungen)

    static let title = "Termine im Kalender"
    static let short = "StudiNow trägt deinen Stundenplan in einen eigenen Kalender „StudiNow“ in der Kalender-App ein und hält ihn aktuell."
    static let longText = "Eingetragen wird, was in StudiNow im Stundenplan steht – mit Raum, Lehrenden und einem Link zurück in die App: Stud.IP, eigene Termine, Verlegungen und Ausfälle, wahlweise auch Abgaben, Prüfungen, Feiertage und vorlesungsfreie Zeit. Nach jedem Abgleich und beim Öffnen gleicht StudiNow den Kalender genau ab: Geändertes wird geändert, Entfallenes entfernt, nichts doppelt. Andere Kalender und Termine fasst StudiNow nie an. Der Kalender entsteht dort, wo deine Kalender-App neue Termine anlegt – meist in iCloud, dann siehst du ihn auch auf deinen anderen Apple-Geräten. Nichts geht an einen Server von StudiNow. Ausschalten entfernt den Kalender „StudiNow“ wieder."
    static let deniedText = "StudiNow darf nicht auf den Kalender zugreifen. Erlaube es in den Einstellungen unter Datenschutz & Sicherheit → Kalender → StudiNow („Vollzugriff“) und schalte es danach hier erneut ein."
    static let writeOnlyText = "StudiNow darf Termine nur hinzufügen. Für einen eigenen, genau abgeglichenen Kalender braucht StudiNow „Vollzugriff“ (Einstellungen → Datenschutz & Sicherheit → Kalender → StudiNow)."
    static let deletedText = "Der Kalender „StudiNow“ wurde in der Kalender-App gelöscht. Der Abgleich ist deshalb aus; schalte ihn hier wieder ein, wenn du den Kalender zurückhaben willst."
    static let offConfirm = "Der Kalender „StudiNow“ wird mit allen seinen Einträgen aus der Kalender-App entfernt. Deine anderen Kalender bleiben, wie sie sind."

    func statusText(now: Date = Date()) -> String? {
        switch status {
        case .off: return nil
        case .denied: return Self.deniedText
        case .writeOnly: return Self.writeOnlyText
        case .running: return "Gleicht ab …"
        case .calendarDeleted: return Self.deletedText
        case .failed(let m): return m
        case .ok(let d, let n):
            let when = HildesheimConnection.time(d, now: now)
            let c = lastChanges
            let delta = c.created + c.updated + c.removed == 0 ? "" : " (\([c.created > 0 ? "\(c.created) neu" : nil, c.updated > 0 ? "\(c.updated) geändert" : nil, c.removed > 0 ? "\(c.removed) entfernt" : nil].compactMap { $0 }.joined(separator: ", ")))"
            return "Zuletzt abgeglichen: \(when) · \(n == 1 ? "1 Eintrag" : "\(n) Einträge")\(delta)"
        }
    }
}

/// Unsichtbar unter jedem Fenster: gleicht den Kalender nach jedem Abgleich, beim Wechsel des Containers und der Demo,
/// beim Oeffnen (hoechstens alle 10 Minuten) und beim Wechsel in den Hintergrund ab. Nur wenn eingeschaltet.
struct CalendarExportRefresher: View {
    @ObservedObject var containers: ContainerManager
    @ObservedObject var studip: StudIPSync
    @Environment(\.scenePhase) private var scenePhase

    private struct Trigger: Equatable {
        let runs: Int
        let generation: Int
        let demo: Bool
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: Trigger(runs: studip.finishedRuns, generation: containers.generation, demo: containers.demoActive), initial: true) { old, new in
                // erster Aufruf beim Start: wie "Oeffnen" (gedrosselt)
                let force = old != new
                Task {
                    await CalendarExport.shared.sync(api: containers.active?.api, demo: containers.demoActive, force: force)
                    await LectureReminderScheduler.shared.refresh(containers)          // Erinnerung vor der Vorlesung
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: Task {
                    await CalendarExport.shared.sync(api: containers.active?.api, demo: containers.demoActive, force: false)
                    await LectureReminderScheduler.shared.refresh(containers)
                }
                case .background: Task {
                    await CalendarExport.shared.sync(api: containers.active?.api, demo: containers.demoActive, force: true)
                    await LectureReminderScheduler.shared.refresh(containers)
                }
                default: break
                }
            }
    }
}
