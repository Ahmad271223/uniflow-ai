import Foundation

// Stundenplan aus Stud.IP direkt vom Geraet. users/{id}/schedule liefert die regelmaessigen Kurszeiten
// (seminar-cycle-dates) und die eigenen Eintraege (schedule-entries), users/{id}/courses Titel, Nummer und
// course-type (Aufbau: docs/QIS-STUDIP-STRUKTUR.md). Ergebnis in derselben Form wie auf dem PC-Server:
// app/timetable.py studip_entries/auto_import, /api/timetable/auto-status in app/server.py und die Tabellen
// course_events/event_exceptions in app/db.py. Anders als der PC, der die Serien aus Einzelterminen ableitet
// (merge_weekly), stehen Rhythmus, Zeitraum und Ausfaelle hier direkt in der Antwort.

/// Art einer Veranstaltung. Feiner als `kind` in course_events; `kind` folgt dem PC.
public enum StudIPScheduleArt: String, Sendable, Codable, CaseIterable {
    case vorlesung, uebung, hoersaaluebung, gruppenuebung, tutorium, labor, seminar, sonstiges

    /// Feld `kind` in course_events. Wie app/timetable.py studip_entries: "uebung", wenn der Kurs eine Uebung ist,
    /// sonst guess_kind(title); dort zaehlen Tutorium, Gruppen- und Hoersaaluebung ebenfalls als "uebung".
    public var kind: String {
        switch self {
        case .vorlesung: return "vorlesung"
        case .uebung, .hoersaaluebung, .gruppenuebung, .tutorium: return "uebung"
        case .labor: return "labor"
        case .seminar: return "seminar"
        case .sonstiges: return "sonstiges"
        }
    }

    /// Arten, bei denen schon zwei Kurszeiten parallele Gruppen sind (man besucht nur eine davon).
    var isGroupArt: Bool { self == .uebung || self == .gruppenuebung || self == .tutorium || self == .labor }
}

/// Kurs aus users/{id}/courses mit den Feldern, die der Stundenplan braucht.
public struct StudIPScheduleCourse: Sendable, Equatable {
    public let id: String
    public let title: String
    public let number: String?
    /// `course-type` (Zahl der Veranstaltungsart in Stud.IP), an der LUH gesehen: 1, 3, 7, 10, 35, 40.
    public let courseType: Int?

    public init(id: String, title: String, number: String? = nil, courseType: Int? = nil) {
        self.id = id
        self.title = title
        self.number = number
        self.courseType = courseType
    }
}

/// Semesterzeitraum (ISO-Daten) fuer Eintraege ohne eigenen Zeitraum, wie term() in app/timetable.py.
public struct StudIPTerm: Sendable, Equatable {
    public let start: String
    public let end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

/// Regelmaessiger Stundenplan-Eintrag: eine Kurszeit (seminar-cycle-date) oder ein eigener Eintrag.
public struct StudIPScheduleEntry: Sendable, Equatable {
    /// Stud.IP-ID der Kurszeit bzw. des eigenen Eintrags.
    public let id: String
    public let isPersonal: Bool
    public let courseID: String?
    public let courseNumber: String?
    public let title: String
    public let description: String
    public let art: StudIPScheduleArt
    /// Feld `kind` wie in course_events.
    public let kind: String
    /// 0 = Montag (wie course_events.weekday).
    public let weekday: Int
    /// "HH:MM"
    public let startTime: String
    public let endTime: String
    /// Rhythmus in Wochen: 1 woechentlich, 2 alle zwei Wochen.
    public let interval: Int
    /// erster und letzter Tag (ISO, Ortszeit Berlin); nil = ganzes Semester
    public let dateFrom: String?
    public let dateTo: String?
    /// Ausfaelle (EXDATES) als ISO-Daten.
    public let exdates: [String]
    public let locations: [String]
    /// Raum wie auf dem PC: erster Ort bis zum ersten Komma.
    public let room: String
    public let color: String?
    /// Anzahl der Kurszeiten gleicher Art im Kurs (`group_slots`).
    public internal(set) var groupSlots: Int
    /// eindeutig und automatisch uebernommen; false = parallele Gruppe, Auswahl noetig
    public internal(set) var selected: Bool
    public internal(set) var uncertain: Bool
    public internal(set) var hint: String?

    /// weekly | biweekly | once wie course_events.rrule. Andere Rhythmen bleiben "weekly", stehen aber in
    /// `interval` und werden als unsicher markiert.
    public var rrule: String {
        if let f = dateFrom, f == dateTo { return "once" }
        return interval == 2 ? "biweekly" : "weekly"
    }

    /// Eintrag in der Form von app/timetable.py studip_entries (Felder von course_events, dazu uncertain,
    /// selected, group_slots, hint, personal). Ergaenzt um studip_id, art, interval, exdates, locations und
    /// course_number; module_id bleibt leer (die Modulzuordnung, guess_module, macht der Empfaenger).
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "title": .string(title), "kind": .string(kind), "weekday": .number(Double(weekday)),
            "start_time": .string(startTime), "end_time": .string(endTime), "room": .string(room), "lecturer": "",
            "rrule": .string(rrule), "date_from": Self.optional(dateFrom), "date_to": Self.optional(dateTo),
            "module_id": .null, "course_id": Self.optional(courseID), "color": Self.optional(color),
            "uncertain": .bool(uncertain), "selected": .bool(selected), "group_slots": .number(Double(groupSlots)),
            "studip_id": .string(id), "art": .string(art.rawValue), "interval": .number(Double(interval)),
            "exdates": .array(exdates.map(JSONValue.string)), "locations": .array(locations.map(JSONValue.string)),
            "course_number": Self.optional(courseNumber),
        ]
        if let hint { o["hint"] = .string(hint) }
        if isPersonal { o["personal"] = true }
        return .object(o)
    }

    /// Ausfaelle als Zeilen von event_exceptions (ohne event_id, die vergibt der Server beim Import).
    public var exceptionsJSON: [JSONValue] {
        exdates.map { d -> JSONValue in
            ["date": .string(d), "type": "cancelled", "new_date": .null, "new_start": .null, "new_end": .null,
             "note": "Ausfall laut Stud.IP"]
        }
    }

    static func optional(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }

    // MARK: Einzeltermine

    /// Konkrete Termine zwischen `from` und `to` (ISO-Daten, beide eingeschlossen), Ortszeit Europe/Berlin.
    /// Regeln wie _matches in app/timetable.py: Zeitraum (sonst Semester), Wochentag, Rhythmus gezaehlt ab dem
    /// ersten Tag. Ausfaelle fehlen, mit `includeCancelled` kommen sie mit `cancelled = true`.
    public func occurrences(from: String, to: String, term: StudIPTerm? = nil, includeCancelled: Bool = false) -> [StudIPOccurrence] {
        guard let lo0 = BerlinClock.parseISODate(from), let hi0 = BerlinClock.parseISODate(to), lo0 <= hi0,
              let startMin = StudIPSchedule.minutes(startTime), let endMin = StudIPSchedule.minutes(endTime) else { return [] }
        let first = dateFrom.flatMap(BerlinClock.parseISODate) ?? term.flatMap { BerlinClock.parseISODate($0.start) }
        let last = dateTo.flatMap(BerlinClock.parseISODate) ?? term.flatMap { BerlinClock.parseISODate($0.end) }
        let lo = max(lo0, first ?? lo0), hi = min(hi0, last ?? hi0)
        guard lo <= hi else { return [] }
        var days: [Int] = []
        if rrule == "once" {
            if let f = first, f >= lo, f <= hi { days = [f] }
        } else {
            var d = lo + (weekday - BerlinClock.weekday(lo) + 7) % 7
            while d <= hi {
                if interval <= 1 || first.map({ BerlinClock.floorDiv(d - $0, 7) % interval == 0 }) ?? true { days.append(d) }
                d += 7
            }
        }
        let skip = Set(exdates)
        var out: [StudIPOccurrence] = []
        for d in days {
            let iso = BerlinClock.isoDate(d)
            let cancelled = skip.contains(iso)
            if cancelled && !includeCancelled { continue }
            let s = BerlinClock.utcSeconds(day: d, minutes: startMin)
            let e = BerlinClock.utcSeconds(day: endMin > startMin ? d : d + 1, minutes: endMin)
            out.append(StudIPOccurrence(entry: self, date: iso, start: Date(timeIntervalSince1970: TimeInterval(s)),
                                        end: Date(timeIntervalSince1970: TimeInterval(e)), cancelled: cancelled))
        }
        return out
    }

    /// Termine, die das Zeitintervall beruehren (Beginn vor dessen Ende, Ende nach dessen Beginn).
    public func occurrences(in interval: DateInterval, term: StudIPTerm? = nil, includeCancelled: Bool = false) -> [StudIPOccurrence] {
        let lo = BerlinClock.local(utc: Int(interval.start.timeIntervalSince1970.rounded(.down))).day - 1
        let hi = BerlinClock.local(utc: Int(interval.end.timeIntervalSince1970.rounded(.up))).day
        return occurrences(from: BerlinClock.isoDate(lo), to: BerlinClock.isoDate(hi), term: term, includeCancelled: includeCancelled)
            .filter { $0.start < interval.end && $0.end > interval.start }
    }
}

/// Ein konkreter Termin eines Stundenplan-Eintrags.
public struct StudIPOccurrence: Sendable, Equatable {
    public let entryID: String
    /// ISO-Datum (Ortszeit Berlin)
    public let date: String
    public let startTime: String
    public let endTime: String
    public let start: Date
    public let end: Date
    public let cancelled: Bool
    let title: String
    let kind: String
    let color: String?
    let room: String
    let courseID: String?

    init(entry e: StudIPScheduleEntry, date: String, start: Date, end: Date, cancelled: Bool) {
        entryID = e.id
        self.date = date
        startTime = e.startTime
        endTime = e.endTime
        self.start = start
        self.end = end
        self.cancelled = cancelled
        title = e.title
        kind = e.kind
        color = e.color
        room = e.room
        courseID = e.courseID
    }

    /// Form von occurrences() in app/timetable.py; event_id ist hier die Stud.IP-ID, Ausfall = status "ausfall".
    public var json: JSONValue {
        [
            "event_id": .string(entryID), "date": .string(date), "start": .string(startTime), "end": .string(endTime),
            "title": .string(title), "kind": .string(kind), "module_id": .null, "module_name": .null,
            "color": .string(color ?? "#4f5bd5"), "room": .string(room), "lecturer": "",
            "course_id": StudIPScheduleEntry.optional(courseID), "status": cancelled ? "ausfall" : "teilnahme",
            "permanent_skip": false, "exception": cancelled ? "cancelled" : .null,
        ]
    }
}

/// Parallele Uebungsgruppen eines Kurses: der Nutzer waehlt seine Gruppe.
public struct StudIPGroupChoice: Sendable, Equatable {
    public let courseID: String?
    public let title: String
    public let art: StudIPScheduleArt
    public let options: [StudIPScheduleEntry]
}

/// Ergebnis des Stundenplan-Abrufs.
public struct StudIPTimetable: Sendable, Equatable {
    /// nach Wochentag und Beginn sortiert (wie studip_entries)
    public let entries: [StudIPScheduleEntry]
    /// Kurse der Art "sonstiges" (Begruessung, Erstsemester ...), wie auf dem PC nicht im Stundenplan.
    public let skippedCourseIDs: [String]

    public var selected: [StudIPScheduleEntry] { entries.filter(\.selected) }
    public var pending: [StudIPScheduleEntry] { entries.filter { !$0.selected } }
    public var personal: [StudIPScheduleEntry] { entries.filter(\.isPersonal) }

    /// Offene Gruppen je Kurs und Art, nach Titel sortiert.
    public var groups: [StudIPGroupChoice] {
        var order: [String] = []
        var byKey: [String: [StudIPScheduleEntry]] = [:]
        for e in pending {
            let k = StudIPSchedule.groupKey(e)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(e)
        }
        return order.compactMap { k in
            guard let opts = byKey[k], let f = opts.first else { return nil }
            return StudIPGroupChoice(courseID: f.courseID, title: f.title, art: f.art, options: opts)
        }.sorted { ($0.title, $0.art.rawValue) < ($1.title, $1.art.rawValue) }
    }

    /// Alle Eintraege als Liste in der Form von studip_entries.
    public var entriesJSON: JSONValue { .array(entries.map(\.json)) }

    /// Form von GET /api/timetable/auto-status (app/server.py): Zahl der offenen Eintraege, deren Kurstitel,
    /// eigene Eintraege.
    public var autoStatusJSON: JSONValue {
        let p = pending
        return [
            "pending_groups": .number(Double(p.count)),
            "courses": .array(Set(p.map(\.title)).sorted().map(JSONValue.string)),
            "personal": .array(personal.map(\.json)),
        ]
    }

    /// Eintraege fuer den Import (wie auto_import: alle eindeutigen) plus die gewaehlten Gruppen (`chosen` sind
    /// Stud.IP-IDs). Gewaehlte Gruppen gelten danach als ausgewaehlt und sicher.
    public func importEntries(choosing chosen: Set<String> = []) -> [StudIPScheduleEntry] {
        entries.compactMap { e in
            if e.selected { return e }
            guard chosen.contains(e.id) else { return nil }
            var c = e
            c.selected = true
            c.uncertain = false
            c.hint = nil
            return c
        }
    }
}

public enum StudIPSchedule {

    /// Stud.IP-Standard fuer `course-type` (SEM_TYPE: 2 Seminar, 3 Uebung, 4 Praktikum). Gilt nur, wenn der Titel
    /// keine Art erkennen laesst; die LUH-eigenen Nummern (7, 10, 35, 40 ...) sind unbekannt und bleiben aussen vor.
    public static let standardCourseTypes: [Int: StudIPScheduleArt] = [2: .seminar, 3: .uebung, 4: .labor]

    /// Stundenplan aus den `data`-Listen von users/{id}/schedule und users/{id}/courses.
    public static func timetable(schedule: [JSONValue], courses: [JSONValue],
                                 courseTypes: [Int: StudIPScheduleArt] = standardCourseTypes) -> StudIPTimetable {
        var byID: [String: StudIPScheduleCourse] = [:]
        for c in parseCourses(courses) where byID[c.id] == nil { byID[c.id] = c }
        var cycles: [StudIPScheduleEntry] = [], personal: [StudIPScheduleEntry] = []
        var skipped = Set<String>()
        for r in schedule {
            switch r["type"]?.string {
            case "seminar-cycle-dates":
                guard let e = cycleEntry(r, courses: byID, courseTypes: courseTypes) else { continue }
                if e.art == .sonstiges { skipped.insert(e.courseID ?? e.id) } else { cycles.append(e) }
            case "schedule-entries":
                if let e = personalEntry(r) { personal.append(e) }
            default:
                continue
            }
        }
        // Parallele Gruppen: Kurszeiten eines Kurses gleicher Art. Wie studip_entries (per_course > 2) gelten mehr
        // als zwei als Gruppen; bei Uebung, Gruppenuebung, Tutorium und Labor schon zwei, da man nur eine besucht.
        var buckets: [String: [Int]] = [:]
        for (i, e) in cycles.enumerated() { buckets[groupKey(e), default: []].append(i) }
        for idx in buckets.values {
            let n = idx.count
            let art = cycles[idx[0]].art
            let parallel = n > 2 || (n >= 2 && art.isGroupArt)
            for i in idx {
                cycles[i].groupSlots = n
                guard parallel else { continue }
                cycles[i].selected = false
                cycles[i].uncertain = true
                cycles[i].hint = "\(n) parallele Gruppen – nur deine Gruppe auswählen"
            }
        }
        let all = (cycles + personal).sorted {
            ($0.weekday, $0.startTime, $0.title, $0.id) < ($1.weekday, $1.startTime, $1.title, $1.id)
        }
        return StudIPTimetable(entries: all, skippedCourseIDs: skipped.sorted())
    }

    /// Wie oben, mit den ganzen JSON:API-Antworten (Feld `data`).
    public static func timetable(scheduleDocument: JSONValue, coursesDocument: JSONValue,
                                 courseTypes: [Int: StudIPScheduleArt] = standardCourseTypes) -> StudIPTimetable {
        timetable(schedule: scheduleDocument["data"]?.array ?? [], courses: coursesDocument["data"]?.array ?? [],
                  courseTypes: courseTypes)
    }

    /// Alle Termine mehrerer Eintraege im Zeitraum, nach Datum und Beginn sortiert.
    public static func occurrences(of entries: [StudIPScheduleEntry], from: String, to: String, term: StudIPTerm? = nil,
                                   includeCancelled: Bool = false) -> [StudIPOccurrence] {
        entries.flatMap { $0.occurrences(from: from, to: to, term: term, includeCancelled: includeCancelled) }
            .sorted { ($0.date, $0.startTime, $0.title, $0.entryID) < ($1.date, $1.startTime, $1.title, $1.entryID) }
    }

    static func groupKey(_ e: StudIPScheduleEntry) -> String { "\(e.courseID ?? e.id)|\(e.art.rawValue)" }

    // MARK: Art

    /// Art aus dem Kurstitel wie classify() in app/studip_sync.py (dieselben Muster in derselben Reihenfolge).
    static func courseArt(_ title: String) -> StudIPScheduleArt {
        func has(_ pattern: String) -> Bool { title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        var art = StudIPScheduleArt.vorlesung
        if has("Gruppenübung|Gruppenuebung") {
            art = .gruppenuebung
        } else if has("Hörsaalübung|Hoersaaluebung|Zentralübung") {
            art = .hoersaaluebung
        } else if has("\\b(Übung|Uebung|Fragestunde)") {
            art = .uebung
        } else if has("Tutorium") {
            art = .tutorium
        }
        if has("Begrüßung|Studiengänge|Einführungsveranstaltung|Erstsemester") { art = .sonstiges }
        return art
    }

    /// guess_kind() in app/timetable.py (KIND_WORDS, Teilwortsuche ohne Gross-/Kleinschreibung):
    /// vorlesung | uebung | labor | seminar. "lab" trifft wie dort auch Woerter wie "Kollaboration".
    static func guessKind(_ title: String) -> String {
        let t = title.lowercased()
        let words: [(String, [String])] = [
            ("uebung", ["übung", "uebung", "ü:", "exercise", "tutorium", "gruppenübung", "zentralübung"]),
            ("labor", ["labor", "praktikum", "lab"]),
            ("seminar", ["seminar"]),
        ]
        for (kind, list) in words where list.contains(where: { t.contains($0) }) { return kind }
        return "vorlesung"
    }

    /// Art eines Termins: zuerst der Kurstitel (classify, danach guess_kind fuer Labor/Seminar), dann die
    /// Beschreibung der Kurszeit (z. B. "Übung Gruppe 2" in einer Vorlesung), zuletzt `course-type`.
    public static func art(title: String, courseType: Int? = nil, detail: String? = nil,
                           courseTypes: [Int: StudIPScheduleArt] = standardCourseTypes) -> StudIPScheduleArt {
        var a = titleArt(title)
        if a == .vorlesung, let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            let da = titleArt(d)
            if da != .vorlesung && da != .sonstiges { a = da }
        }
        if a == .vorlesung, let t = courseType, let mapped = courseTypes[t] { a = mapped }
        return a
    }

    static func titleArt(_ title: String) -> StudIPScheduleArt {
        let a = courseArt(title)
        guard a == .vorlesung else { return a }
        switch guessKind(title) {
        case "uebung": return .uebung
        case "labor": return .labor
        case "seminar": return .seminar
        default: return .vorlesung
        }
    }

    // MARK: Lesen

    public static func parseCourses(_ data: [JSONValue]) -> [StudIPScheduleCourse] {
        data.compactMap { c in
            guard let id = c["id"]?.string else { return nil }
            let a = c["attributes"]
            let title = squash(a?["title"]?.string ?? "")
            let number = a?["course-number"]?.string?.trimmingCharacters(in: .whitespaces)
            return StudIPScheduleCourse(id: id, title: title.isEmpty ? "Kurs" : title,
                                        number: (number?.isEmpty ?? true) ? nil : number, courseType: integer(a?["course-type"]))
        }
    }

    static func cycleEntry(_ r: JSONValue, courses: [String: StudIPScheduleCourse],
                           courseTypes: [Int: StudIPScheduleArt]) -> StudIPScheduleEntry? {
        guard let id = r["id"]?.string, let a = r["attributes"],
              let startMin = minutes(a["start"]?.string), let endMin = minutes(a["end"]?.string) else { return nil }
        let rec = recurrence(a["recurrence"])
        let from = moment(rec["DTSTART"]), until = moment(rec["UNTIL"])
        guard let weekday = studipWeekday(a["weekday"]) ?? from.map({ BerlinClock.weekday($0.day) }) else { return nil }
        let owner = r["relationships"]?["owner"]?["data"]
        let courseID = owner?["type"]?.string == "courses" ? owner?["id"]?.string : nil
        let course = courseID.flatMap { courses[$0] }
        let ownTitle = squash(a["title"]?.string ?? "")
        let title = course?.title ?? (ownTitle.isEmpty ? "Veranstaltung" : ownTitle)
        let description = (a["description"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let art = Self.art(title: title, courseType: course?.courseType, detail: description, courseTypes: courseTypes)
        let (interval, rhythmHint) = rhythm(rec)
        let locations = locationList(a["locations"])
        var e = StudIPScheduleEntry(
            id: id, isPersonal: false, courseID: courseID, courseNumber: course?.number, title: title, description: description,
            art: art, kind: art.kind, weekday: weekday, startTime: hhmm(startMin), endTime: hhmm(endMin), interval: interval,
            dateFrom: from.map { BerlinClock.isoDate($0.day) }, dateTo: until.map { lastDay($0, startMinutes: startMin) },
            exdates: exdates(rec["EXDATES"]), locations: locations, room: room(locations), color: a["color"]?.string,
            groupSlots: 1, selected: true, uncertain: false, hint: nil)
        if let rhythmHint {
            e.uncertain = true
            e.hint = rhythmHint
        }
        return e
    }

    /// Eigener Eintrag wie fetch_schedule_entries (app/studip_sync.py) und der Teil "Persoenliche Eintraege" in
    /// studip_entries (app/timetable.py): Art aus dem Titel, alle zwei Wochen nur laut Titel/Beschreibung.
    static func personalEntry(_ r: JSONValue) -> StudIPScheduleEntry? {
        guard let id = r["id"]?.string, let a = r["attributes"],
              let startMin = minutes(a["start"]?.string), let endMin = minutes(a["end"]?.string),
              let weekday = studipWeekday(a["weekday"]) else { return nil }
        let raw = squash(a["title"]?.string ?? "")
        let title = raw.isEmpty ? "Termin" : raw
        let description = a["description"]?.string ?? ""
        let rec = recurrence(a["recurrence"])
        let (ruleInterval, rhythmHint) = rhythm(rec)
        var interval = ruleInterval
        if rec["INTERVAL"] == nil,
           (title + " " + description).range(of: "alle 2 Wochen|zweiw[öo]chentlich|14-?t[äa]g",
                                              options: [.regularExpression, .caseInsensitive]) != nil {
            interval = 2
        }
        let from = moment(rec["DTSTART"]), until = moment(rec["UNTIL"])
        let locations = locationList(a["locations"])
        return StudIPScheduleEntry(
            id: id, isPersonal: true, courseID: nil, courseNumber: nil, title: title, description: description,
            art: art(title: title), kind: guessKind(title), weekday: weekday, startTime: hhmm(startMin), endTime: hhmm(endMin),
            interval: interval, dateFrom: from.map { BerlinClock.isoDate($0.day) },
            dateTo: until.map { lastDay($0, startMinutes: startMin) }, exdates: exdates(rec["EXDATES"]), locations: locations,
            room: room(locations), color: a["color"]?.string, groupSlots: 1, selected: true, uncertain: rhythmHint != nil,
            hint: rhythmHint ?? "persönlicher Eintrag aus deinem Stud.IP-Stundenplan")
    }

    /// Stud.IP zaehlt 1-5 = Mo-Fr (Python: weekday - 1), 6 = Sa, 0 oder 7 = So. Ergebnis 0 = Montag.
    static func studipWeekday(_ v: JSONValue?) -> Int? {
        guard let n = integer(v), (0...7).contains(n) else { return nil }
        return n == 0 || n == 7 ? 6 : n - 1
    }

    /// INTERVAL (1 woechentlich, 2 zweiwoechentlich); andere Rhythmen bleiben erhalten, aber mit Hinweis.
    static func rhythm(_ rec: [String: JSONValue]) -> (Int, String?) {
        let interval = max(1, integer(rec["INTERVAL"]) ?? 1)
        if let f = rec["FREQ"]?.string?.uppercased(), !f.isEmpty, f != "WEEKLY" {
            return (interval, "Rhythmus \(f) aus Stud.IP – bitte prüfen")
        }
        return (interval, interval > 2 ? "Rhythmus alle \(interval) Wochen – bitte prüfen" : nil)
    }

    /// Letzter Tag aus UNTIL: liegt UNTIL mit Uhrzeit vor dem Beginn des Termins (z. B. 23:59:59Z = 00:59 Uhr
    /// am Folgetag), zaehlt der Vortag; Mitternacht und reine Daten zaehlen als ganzer Tag.
    static func lastDay(_ u: StudIPMoment, startMinutes: Int) -> String {
        guard let m = u.minutes, m != 0, m < startMinutes else { return BerlinClock.isoDate(u.day) }
        return BerlinClock.isoDate(u.day - 1)
    }

    /// `recurrence` als Objekt ({"FREQ": ..., "INTERVAL": ...}) oder als Text "FREQ=WEEKLY;INTERVAL=2;...";
    /// Schluessel in Grossbuchstaben.
    static func recurrence(_ v: JSONValue?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let o = v?.object {
            for (k, x) in o { out[k.uppercased()] = x }
        } else if let s = v?.string {
            for part in s.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { out[kv[0].uppercased()] = .string(kv[1]) }
            }
        }
        return out
    }

    /// EXDATES als Liste oder durch Komma getrennt; jeder Wert ein Zeitpunkt oder Datum -> Tag in Berlin.
    static func exdates(_ v: JSONValue?) -> [String] {
        var values: [JSONValue] = []
        if let a = v?.array { values = a } else if let s = v?.string { values = s.split(separator: ",").map { .string(String($0)) } } else if let v, v.double != nil { values = [v] }
        return Set(values.compactMap { moment($0).map { BerlinClock.isoDate($0.day) } }).sorted()
    }

    /// `locations`: Liste von Texten (oder Objekten mit Namen), auch ein einzelner Text.
    static func locationList(_ v: JSONValue?) -> [String] {
        let items: [JSONValue] = v?.array ?? (v.map { [$0] } ?? [])
        return items.compactMap { x -> String? in
            let s = x.string ?? x["name"]?.string ?? x["title"]?.string ?? x["description"]?.string
            let t = squash(s ?? "")
            return t.isEmpty ? nil : t
        }
    }

    /// Raum wie fetch_events in app/studip_sync.py: Text bis zum ersten Komma.
    static func room(_ locations: [String]) -> String {
        guard let f = locations.first else { return "" }
        return (f.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? f)
            .trimmingCharacters(in: .whitespaces)
    }

    static func squash(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    static func integer(_ v: JSONValue?) -> Int? {
        if let n = v?.int { return n }
        if let s = v?.string?.trimmingCharacters(in: .whitespaces) { return Int(s) }
        return nil
    }

    /// "H:MM" oder "HH:MM:SS" -> Minuten seit Mitternacht (wie hm() in app/timetable.py).
    static func minutes(_ s: String?) -> Int? {
        guard let s else { return nil }
        let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard p.count >= 2, let h = Int(p[0]), let m = Int(p[1]), (0...24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Minuten -> "HH:MM" (mh() in app/timetable.py).
    static func hhmm(_ m: Int) -> String {
        let v = max(0, m)
        let h = v / 60, mi = v % 60
        return (h < 10 ? "0" : "") + String(h) + ":" + (mi < 10 ? "0" : "") + String(mi)
    }

    /// Zeitpunkt oder Datum aus Stud.IP: ISO 8601 ("2026-10-12", "2026-10-12T10:15:00+02:00"), iCalendar
    /// ("20261012", "20261012T081500Z") oder Unix-Sekunden. Ohne Zeitzone gilt Ortszeit Berlin.
    static func moment(_ v: JSONValue?) -> StudIPMoment? {
        guard let v else { return nil }
        if let d = v.double { return d.isFinite && abs(d) < 1e12 ? StudIPMoment(utc: Int(d)) : nil }
        guard let s = v.string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let b = Array(s.utf8)
        if b.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) && (9...11).contains(b.count) { return Int(s).map { StudIPMoment(utc: $0) } }
        var i = 0
        func num(_ n: Int) -> Int? {
            guard i + n <= b.count else { return nil }
            var v = 0
            for k in i..<(i + n) {
                guard b[k] >= 0x30 && b[k] <= 0x39 else { return nil }
                v = v * 10 + Int(b[k] - 0x30)
            }
            i += n
            return v
        }
        func skip(_ c: UInt8) -> Bool { if i < b.count && b[i] == c { i += 1; return true }; return false }
        guard let y = num(4) else { return nil }
        _ = skip(0x2D)
        guard let mo = num(2) else { return nil }
        _ = skip(0x2D)
        guard let d = num(2), (1...12).contains(mo), d >= 1, d <= BerlinClock.daysInMonth(year: y, month: mo) else { return nil }
        let day = BerlinClock.dayNumber(year: y, month: mo, day: d)
        if i == b.count { return StudIPMoment(day: day, minutes: nil) }
        guard skip(0x54) || skip(0x20), let h = num(2) else { return nil }               // T oder Leerzeichen
        _ = skip(0x3A)
        guard let mi = num(2), h <= 24, mi < 60 else { return nil }
        if skip(0x3A) { guard num(2) != nil else { return nil } } else if i < b.count, b[i] >= 0x30 && b[i] <= 0x39 { guard num(2) != nil else { return nil } }
        if skip(0x2E) || skip(0x2C) { while i < b.count, b[i] >= 0x30 && b[i] <= 0x39 { i += 1 } }   // Sekundenbruchteile
        while skip(0x20) {}
        let local = h * 60 + mi
        if i == b.count { return StudIPMoment(day: day, minutes: local) }
        var offset = 0
        if skip(0x5A) || skip(0x7A) {                                                    // Z
            offset = 0
        } else if i < b.count, b[i] == 0x2B || b[i] == 0x2D {                            // + oder -
            let sign = b[i] == 0x2D ? -1 : 1
            i += 1
            guard let oh = num(2) else { return nil }
            _ = skip(0x3A)
            let om = num(2) ?? 0
            offset = sign * (oh * 3600 + om * 60)
        } else {
            return nil
        }
        guard i == b.count else { return nil }
        return StudIPMoment(utc: day * 86400 + local * 60 - offset)
    }
}

/// Tag (Tage seit 1970-01-01) und Uhrzeit in Berlin; `minutes` fehlt bei reinen Daten.
struct StudIPMoment: Equatable {
    let day: Int
    let minutes: Int?

    init(day: Int, minutes: Int?) {
        self.day = day
        self.minutes = minutes
    }

    init(utc seconds: Int) {
        let l = BerlinClock.local(utc: seconds)
        self.init(day: l.day, minutes: l.minutes)
    }
}

/// Ortszeit Europe/Berlin ohne Zeitzonendatenbank (unter Linux fehlt sie oft): MEZ (UTC+1), Sommerzeit (UTC+2)
/// vom letzten Sonntag im Maerz bis zum letzten Sonntag im Oktober, jeweils 01:00 UTC (EU-Regel seit 1996).
enum BerlinClock {
    static func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }

    /// Tage seit 1970-01-01 (Verfahren von H. Hinnant, "days_from_civil").
    static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civil(_ n: Int) -> (year: Int, month: Int, day: Int) {
        let z = n + 719468
        let era = floorDiv(z, 146097)
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// 0 = Montag (1970-01-01 war ein Donnerstag).
    static func weekday(_ n: Int) -> Int { ((n % 7) + 7 + 3) % 7 }

    static func daysInMonth(year: Int, month: Int) -> Int {
        let next = month == 12 ? dayNumber(year: year + 1, month: 1, day: 1) : dayNumber(year: year, month: month + 1, day: 1)
        return next - dayNumber(year: year, month: month, day: 1)
    }

    static func isoDate(_ n: Int) -> String {
        let c = civil(n)
        func pad(_ v: Int, _ w: Int) -> String { let s = String(v); return String(repeating: "0", count: max(0, w - s.count)) + s }
        return "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2))"
    }

    /// Nur "YYYY-MM-DD".
    static func parseISODate(_ s: String) -> Int? {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), d >= 1, d <= daysInMonth(year: y, month: m) else { return nil }
        return dayNumber(year: y, month: m, day: d)
    }

    static func lastSunday(year: Int, month: Int) -> Int {
        let last = dayNumber(year: year, month: month, day: daysInMonth(year: year, month: month))
        return last - (weekday(last) - 6 + 7) % 7
    }

    static func isSummerTime(utc s: Int) -> Bool {
        let year = civil(floorDiv(s, 86400)).year
        let begin = lastSunday(year: year, month: 3) * 86400 + 3600
        let end = lastSunday(year: year, month: 10) * 86400 + 3600
        return s >= begin && s < end
    }

    static func offset(utc s: Int) -> Int { isSummerTime(utc: s) ? 7200 : 3600 }

    static func local(utc s: Int) -> (day: Int, minutes: Int) {
        let t = s + offset(utc: s)
        let day = floorDiv(t, 86400)
        return (day, (t - day * 86400) / 60)
    }

    /// Ortszeit -> UTC-Sekunden. In der doppelten Stunde im Oktober gilt die erste (Sommerzeit), die fehlende
    /// Stunde im Maerz wird nach vorn verschoben (02:30 -> 03:30 Uhr).
    static func utcSeconds(day: Int, minutes: Int) -> Int {
        let wall = day * 86400 + minutes * 60
        let summer = wall - 7200
        return isSummerTime(utc: summer) ? summer : wall - 3600
    }
}

extension StudIPClient {
    /// `data`-Listen von users/{id}/schedule (Kurszeiten und eigene Eintraege) und users/{id}/courses (mit
    /// course-type). Nur lesend, zwei Abrufe plus Folgeseiten.
    public func scheduleResources(userID: String) async throws -> (schedule: [JSONValue], courses: [JSONValue]) {
        let (schedule, _) = try await list("jsonapi.php/v1/users/\(userID)/schedule")
        let (courses, _) = try await list("jsonapi.php/v1/users/\(userID)/courses?page[limit]=100&include=start-semester")
        return (schedule, courses)
    }

    public func timetable(userID: String,
                          courseTypes: [Int: StudIPScheduleArt] = StudIPSchedule.standardCourseTypes) async throws -> StudIPTimetable {
        let r = try await scheduleResources(userID: userID)
        return StudIPSchedule.timetable(schedule: r.schedule, courses: r.courses, courseTypes: courseTypes)
    }
}
