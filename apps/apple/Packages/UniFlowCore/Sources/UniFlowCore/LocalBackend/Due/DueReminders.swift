import Foundation

/// Erinnerungsplan fuer Abgaben, Tests und Pruefungen (lokale Benachrichtigungen der App, reine Funktion): je Termin
/// 3 Tage vorher, 1 Tag vorher und am Morgen des Tages jeweils um 8:00 (Berlin), mit Uhrzeit zusaetzlich 2 Stunden
/// vorher; Klausuren und Pruefungen (Art "klausur", auch Kurz- und Probeklausuren) zusaetzlich 7 Tage vorher
/// (17.11.2026). Ein neu erkannter Klausur- oder Testtermin wird einmal sofort gemeldet (`newNotices`): das ist die
/// einzige Mitteilung, wenn alle Zeitpunkte schon vorbei sind (Termin erst am Tag selbst erkannt). Nur kuenftige Zeitpunkte, die fruehesten zuerst, hoechstens 60 (iOS behaelt 64 je App; der Rest bleibt
/// frei fuer andere Mitteilungen). Kennungen "de.uniflow.ai.due.<Container>.<Termin>.<Zeitpunkt>": eindeutig je
/// Container, sodass ein Wechsel der Hochschule oder des Kontos nichts vermischt (`diff` nimmt alle anderen zurueck).
/// Die App plant (`UniFlow/Services/DueReminders.swift`) und fragt die Erlaubnis erst beim Einschalten.
public enum DueReminders {
    /// gemeinsamer Anfang aller Kennungen dieser Erinnerungen (andere Mitteilungen der App bleiben unberuehrt)
    public static let prefix = "de.uniflow.ai.due."
    /// Obergrenze geplanter Erinnerungen (iOS: 64 je App)
    public static let limit = 60
    /// Uhrzeit der Tages-Erinnerungen (Minuten nach Mitternacht)
    static let morning = 8 * 60

    /// Ein Termin, an den erinnert wird (aus GET /api/due)
    public struct Item: Sendable, Equatable {
        public var id: String
        public var title: String
        /// "YYYY-MM-DD"
        public var date: String
        /// "HH:MM" oder nil
        public var time: String?
        public var course: String?
        public var origin: String?
        /// Ziel beim Antippen: Hash-Route ("#/doc/<id>?page=2") oder http(s)-Adresse
        public var route: String?
        /// Art (abgabe | test | klausur | anmeldung | sonstiges), nil unbekannt
        public var kind: String?
        /// neu erkannt und vom Nutzer noch nicht gesehen (`DueStore.seenState`)
        public var isNew: Bool
        /// Mitteilung "neu erkannt" schon entschieden
        public var notified: Bool

        public init(id: String, title: String, date: String, time: String? = nil, course: String? = nil, origin: String? = nil, route: String? = nil,
                    kind: String? = nil, isNew: Bool = false, notified: Bool = false) {
            self.id = id
            self.title = title
            self.date = date
            self.time = time
            self.course = course
            self.origin = origin
            self.route = route
            self.kind = kind
            self.isNew = isNew
            self.notified = notified
        }
    }

    /// Eine geplante Erinnerung
    public struct Reminder: Sendable, Equatable {
        public var identifier: String
        public var fireAt: Date
        public var title: String
        public var body: String
        public var route: String?
        public var itemID: String
    }

    /// Kennungen dieses Containers beginnen so
    public static func prefix(container: String) -> String { prefix + container + "." }

    /// Termine aus der Antwort von GET /api/due (ausgeblendete fehlen); Ziel: Dokumentseite, sonst Adresse
    public static func items(from response: JSONValue) -> [Item] {
        (response["items"]?.array ?? []).compactMap { x in
            guard let id = x["id"]?.string, let date = x["date"]?.string, x["hidden"]?.bool != true else { return nil }
            var route: String?
            if let f = x["file_id"]?.string, !f.isEmpty {
                let page = x["page"]?.int ?? 1
                route = "#/doc/\(f)" + (page > 1 ? "?page=\(page)" : "")
            } else if let u = x["url"]?.string, !u.isEmpty {
                route = u
            } else if let m = x["module_id"]?.int {
                route = "#/modules/\(m)"
            }
            let time = x["time"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return Item(id: id, title: x["title"]?.string ?? x["kind_label"]?.string ?? "Termin", date: date, time: time,
                        course: x["course_title"]?.string ?? x["module_name"]?.string, origin: x["origin"]?.string, route: route,
                        kind: x["kind"]?.string, isNew: x["is_new"]?.bool == true, notified: x["notified"]?.bool == true)
        }
    }

    static let weekdayShort = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    /// "Sa, 05.12." bzw. "Sa, 05.12. 23:59"
    static func when(_ day: Int, _ time: String?) -> String {
        let c = BerlinClock.civil(day)
        return "\(weekdayShort[BerlinClock.weekday(day)]), \(BerlinClock.pad(c.day, 2)).\(BerlinClock.pad(c.month, 2))." + (time.map { " \($0)" } ?? "")
    }

    static func minutes(_ time: String?) -> Int? {
        guard let t = time else { return nil }
        let p = t.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    static func date(day: Int, minutes: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(BerlinClock.utcSeconds(day: day, minutes: minutes)))
    }

    /// Erinnerungen fuer alle Termine eines Containers: kuenftige, frueheste zuerst, hoechstens `limit`
    public static func plan(_ items: [Item], container: String, now: Date, limit: Int = DueReminders.limit) -> [Reminder] {
        var out: [Reminder] = []
        let base = prefix(container: container)
        for item in items {
            guard let day = BerlinClock.parseISODate(item.date) else { continue }
            let due = minutes(item.time)
            let body = ([item.course, when(day, item.time), item.origin].compactMap { $0?.isEmpty == false ? $0 : nil }).joined(separator: " · ")
            var slots: [(tag: String, at: Date, title: String)] = [
                ("d3", date(day: day - 3, minutes: morning), "In 3 Tagen: \(item.title)"),
                ("d1", date(day: day - 1, minutes: morning), "Morgen: \(item.title)"),
            ]
            // Klausuren und Pruefungen: eine Woche vorher (Zeit zum Lernen)
            if item.kind == "klausur" { slots.insert(("d7", date(day: day - 7, minutes: morning), "In 7 Tagen: \(item.title)"), at: 0) }
            if let due {
                // am Morgen nur, wenn "2 Stunden vorher" spaeter kommt; "2 Stunden vorher" nicht in der Nacht (vor 6:00)
                let before = due - 120
                if before > morning { slots.append(("d0", date(day: day, minutes: morning), "Heute: \(item.title)")) }
                if before >= 6 * 60 { slots.append(("h2", date(day: day, minutes: before), "In 2 Stunden: \(item.title)")) }
            } else {
                slots.append(("d0", date(day: day, minutes: morning), "Heute: \(item.title)"))
            }
            for s in slots where s.at > now {
                out.append(Reminder(identifier: base + item.id + "." + s.tag, fireAt: s.at, title: s.title, body: body, route: item.route, itemID: item.id))
            }
        }
        var seen = Set<String>()
        out = out.filter { seen.insert($0.identifier).inserted }
        out.sort { $0.fireAt != $1.fireAt ? $0.fireAt < $1.fireAt : $0.identifier < $1.identifier }
        return Array(out.prefix(limit))
    }

    // MARK: Neu erkannt

    /// mehr einzelne Mitteilungen "neu erkannt" gibt es je Lauf nicht (sonst eine Zusammenfassung)
    public static let maxNewSingle = 3

    /// Kennung einer Mitteilung "neu erkannt" (nicht Teil des Plans: `diff` nimmt sie nicht zurueck, sie ist sofort zugestellt)
    public static func newIdentifier(container: String, _ id: String) -> String { prefix(container: container) + "new." + id }

    /// Termine, die einmal sofort gemeldet werden: neu erkannte Klausuren und Tests, noch nicht gemeldet
    public static func newItems(_ items: [Item]) -> [Item] {
        items.filter { $0.isNew && !$0.notified && ($0.kind == "klausur" || $0.kind == "test") }
    }

    /// Mitteilungen "Neuer Klausurtermin erkannt: … am …" (sofort). Mehr als `maxNewSingle`: eine Zusammenfassung mit dem
    /// naechsten Termin. Nichts Erkanntes gilt als sicher: der Text nennt die Quelle und bittet ums Pruefen.
    public static func newNotices(_ items: [Item], container: String, now: Date) -> [Reminder] {
        let fresh = newItems(items).sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
        guard let first = fresh.first else { return [] }
        let today = BerlinClock.local(utc: Int(now.timeIntervalSince1970)).day
        func whenText(_ item: Item) -> String {
            guard let day = BerlinClock.parseISODate(item.date) else { return item.date }
            let n = day - today
            let w = when(day, item.time)
            return n == 0 ? "heute (\(w))" : n == 1 ? "morgen (\(w))" : "am \(w)"
        }
        func body(_ item: Item) -> String {
            ([item.course, item.origin].compactMap { $0?.isEmpty == false ? $0 : nil } + ["Bitte prüfen."]).joined(separator: " · ")
        }
        if fresh.count > maxNewSingle {
            return [Reminder(identifier: newIdentifier(container: container, "summary"), fireAt: now,
                             title: "\(fresh.count) neue Klausur- und Testtermine erkannt",
                             body: "Der nächste: \(first.title) \(whenText(first)). " + body(first), route: first.route, itemID: first.id)]
        }
        return fresh.map { item in
            Reminder(identifier: newIdentifier(container: container, item.id), fireAt: now,
                     title: (item.kind == "test" ? "Neuer Testtermin erkannt: " : "Neuer Klausurtermin erkannt: ") + "\(item.title) \(whenText(item))",
                     body: body(item), route: item.route, itemID: item.id)
        }
    }

    /// Abgleich mit den geplanten Mitteilungen: alle eigenen Kennungen (`prefix`, auch anderer Container), die nicht
    /// mehr im Plan stehen, zuruecknehmen; alle geplanten (neu) eintragen. Gleiche Kennung ersetzt bei iOS die alte
    /// Mitteilung, so werden geaenderte Uhrzeiten und Titel ersetzt.
    public static func diff(pending: [String], planned: [Reminder]) -> (remove: [String], add: [Reminder]) {
        let keep = Set(planned.map(\.identifier))
        let remove = pending.filter { $0.hasPrefix(prefix) && !keep.contains($0) }
        return (Array(Set(remove)).sorted(), planned)
    }
}
