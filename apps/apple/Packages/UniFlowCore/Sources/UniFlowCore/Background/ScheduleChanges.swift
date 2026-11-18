import Foundation

// Mitteilung "Ausfall, Raumänderung oder Verlegung heute oder morgen" (Auftrag des Inhabers 17.11.2026,
// docs/ABGLEICH-8-BIS-18-2026-11-17.md): der Hintergrundlauf liest vor und nach dem Abgleich die Termine von heute und
// morgen (`LocalTimetable.occurrences`, dieselbe Rechnung wie Stundenplan und Woche) und meldet, was sich an einem
// besuchten Termin geaendert hat. Neu aufgetauchte Termine (erster Abgleich, neuer Kurs) und Ausfaelle in der
// vorlesungsfreien Zeit sind keine Neuigkeit. Nur die Rechnung, ohne Mitteilungen und ohne Netz.

/// Ein besuchter Termin von heute oder morgen, wie ihn der Stundenplan zeigt
public struct ScheduleEntry: Equatable, Sendable {
    /// Termin und Tag ("<event_id>|<YYYY-MM-DD>")
    public let key: String
    public let title: String
    /// Tag (YYYY-MM-DD, Berlin)
    public let date: String
    public let start: String
    public let room: String
    /// "teilnahme", "ausfall", "verschoben"
    public let status: String
    /// Ausnahme der Quelle ("cancelled", "moved", "vorlesungsfrei" …)
    public let exception: String
    /// verlegt auf diesen Tag (YYYY-MM-DD), sonst leer
    public let movedTo: String

    public init(key: String, title: String, date: String, start: String, room: String, status: String, exception: String = "",
                movedTo: String = "") {
        self.key = key
        self.title = title
        self.date = date
        self.start = start
        self.room = room
        self.status = status
        self.exception = exception
        self.movedTo = movedTo
    }
}

/// Eine Aenderung, die eine Mitteilung wert ist
public struct ScheduleChange: Equatable, Sendable {
    public enum Kind: String, Sendable { case cancelled, room, moved }
    public let kind: Kind
    public let entry: ScheduleEntry
    /// heute (sonst morgen)
    public let today: Bool
    /// Raum vorher (nur bei `room`)
    public let oldRoom: String

    /// feste Kennung fuer die Mitteilung (gleiche Aenderung ersetzt die alte, nie doppelt)
    public var id: String { "\(kind.rawValue)|\(entry.key)|\(entry.room)|\(entry.start)|\(entry.movedTo)" }
}

/// Termine von heute und morgen zu einem Zeitpunkt
public struct ScheduleSnapshot: Equatable, Sendable {
    public var today: String
    public var entries: [String: ScheduleEntry]

    public init(today: String, entries: [String: ScheduleEntry]) {
        self.today = today
        self.entries = entries
    }

    /// Liest heute und morgen (Berliner Tage, wie der Stundenplan); nur besuchte Termine. nil, wenn der Stundenplan nicht
    /// lesbar ist (dann meldet der Lauf nichts).
    public static func read(_ c: SQLiteConnection, clock: UniFlowClock) -> ScheduleSnapshot? {
        let day = LocalTimetable.today(clock)
        guard day > 0, let occ = try? LocalTimetable.occurrences(c, from: day, to: day + 1, includeSkipped: false) else { return nil }
        var out: [String: ScheduleEntry] = [:]
        for o in occ {
            guard let date = o["date"]?.string, o["status"]?.string != "nicht_teilnahme" else { continue }
            let id: String
            switch o["event_id"] {
            case .string(let s)?: id = s
            case .number(let d)?: id = String(Int(d))
            default: id = (o["title"]?.string ?? "") + "@" + (o["start"]?.string ?? "")
            }
            let key = id + "|" + date
            out[key] = ScheduleEntry(key: key, title: o["title"]?.string ?? "", date: date, start: o["start"]?.string ?? "",
                                     room: (o["room"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                     status: o["status"]?.string ?? "", exception: o["exception"]?.string ?? "",
                                     movedTo: o["moved_to"]?.string ?? "")
        }
        return ScheduleSnapshot(today: LocalTimetable.iso(day), entries: out)
    }

    /// Was sich zwischen `before` und `after` an schon bekannten Terminen geaendert hat: Ausfall (nicht wegen
    /// vorlesungsfreier Zeit), Verlegung (anderer Tag oder andere Zeit), Raumaenderung (beide Raeume bekannt). Ohne
    /// Stand vorher (erster Abgleich) nichts.
    public static func changes(before: ScheduleSnapshot?, after: ScheduleSnapshot?) -> [ScheduleChange] {
        guard let before, let after, !before.entries.isEmpty else { return [] }
        var out: [ScheduleChange] = []
        for key in after.entries.keys.sorted() {
            guard let a = after.entries[key], let b = before.entries[key] else { continue }
            let today = a.date == after.today
            if a.status == "ausfall", b.status != "ausfall", a.exception != "vorlesungsfrei" {
                out.append(ScheduleChange(kind: .cancelled, entry: a, today: today, oldRoom: b.room))
            } else if a.status != "ausfall", (a.movedTo != b.movedTo && !a.movedTo.isEmpty) || (!b.start.isEmpty && a.start != b.start) {
                out.append(ScheduleChange(kind: .moved, entry: a, today: today, oldRoom: b.room))
            } else if a.status != "ausfall", !a.room.isEmpty, !b.room.isEmpty, a.room != b.room {
                out.append(ScheduleChange(kind: .room, entry: a, today: today, oldRoom: b.room))
            }
        }
        return out
    }
}
