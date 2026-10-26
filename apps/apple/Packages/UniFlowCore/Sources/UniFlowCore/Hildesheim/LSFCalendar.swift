import Foundation

/// LSF der Uni Hildesheim: iCal-Export des persoenlichen Stundenplans (`app/lsf.py`, `timetable.parse_ics`).
///
/// Eigenheiten des LSF-Exports: DTSTART ist der Semesterbeginn (Montag), der echte Wochentag steht nur in BYDAY
/// (auch mehrere Tage); vorlesungsfreie Tage stehen als EXDATE (mehrere Zeilen, Komma-Listen). Gelesen wird die Datei
/// mit demselben Port von `timetable.parse_ics` wie jeder Kalender-Import (`LocalTimetableImport.parseICS`, mit
/// UTC/TZID, UNTIL mit Uhrzeit); hier steht nur, was das LSF eigen ist (Titel "9449 - Titel (Lehrperson)", Link).
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
        public var description: String = ""

        /// Eintrag von `parse_ics` (`LocalTimetableImport.parseICS`)
        init(ics e: [String: JSONValue]) {
            title = e["title"]?.string ?? "Veranstaltung"
            number = nil
            lecturer = ""
            weekday = e["weekday"]?.int ?? 0
            startTime = e["start_time"]?.string ?? ""
            endTime = e["end_time"]?.string ?? ""
            room = e["room"]?.string ?? ""
            rrule = e["rrule"]?.string ?? "weekly"
            dateFrom = e["date_from"]?.string ?? ""
            dateTo = e["date_to"]?.string
            exdates = e["exdates"]?.array?.compactMap(\.string) ?? []
            uid = e["uid"]?.string
            description = e["description"]?.string ?? ""
        }

        /// Eintrag in der Form von `lsf.plan_entries` (Art aus dem Titel wie `guess_kind`), fuer `UniStore.importPlan`
        var json: [String: JSONValue] {
            ["title": .string(title), "kind": .string(UniRules.eventKind(title)), "weekday": .number(Double(weekday)),
             "start_time": .string(startTime), "end_time": .string(endTime), "room": .string(room), "rrule": .string(rrule),
             "date_from": .string(dateFrom), "date_to": dateTo.map(JSONValue.string) ?? .null, "uncertain": false,
             "exdates": .array(exdates.map(JSONValue.string)), "uid": uid.map(JSONValue.string) ?? .null,
             "description": .string(description), "number": number.map(JSONValue.string) ?? .null, "lecturer": .string(lecturer)]
        }
    }

    private static let summaryRE = HText.regex("^\\s*(\\d{3,5})\\s*-\\s*(.+?)\\s*$")
    private static let lecturerRE = HText.regex("\\s*\\(([A-ZÄÖÜ][\\wäöüß\\-]+(?:\\s*[,/]\\s*[A-ZÄÖÜ][\\wäöüß\\-]+)*)\\)\\s*$")
    private static let planLinkRE = HText.regex("href=\"([^\"]*moduleCall=iCalendarPlan[^\"]*)\"")

    /// `timetable.parse_ics`: VEVENT mit DTSTART/DTEND/SUMMARY/LOCATION/RRULE (BYDAY)/EXDATE/UID
    public static func parseICS(_ text: String) -> [Entry] {
        LocalTimetableImport.parseICS(text).map(Entry.init(ics:))
    }

    public struct Summary: Sendable, Equatable {
        public let number: String?
        public let title: String
        public let lecturer: String
    }

    /// "9449 - Titel (Lehrperson)" -> Nummer, Titel, Lehrperson
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
