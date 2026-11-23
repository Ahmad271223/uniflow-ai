import Foundation

// Daten fuer die Widgets auf Home- und Sperrbildschirm (Zweig app/widgets, 23.11.2026). Gehoert zu App UND
// Widget-Erweiterung (project.yml: beide Ziele binden diese Datei ein). Die App schreibt einen kleinen Schnappschuss
// (naechste Termine, Mensa heute/morgen) als JSON in den gemeinsamen App-Group-Ordner; das Widget liest nur.
// Kein Server, kein Netz im Widget: was die App nicht abgeglichen hat, zeigt das Widget nicht.
// Beim Abmelden und Containerwechsel leert die App den Schnappschuss (er koennte Termine eines anderen
// Kontos tragen).

/// Kennung der App-Gruppe (Entitlements von App und Widget, im Apple-Konto fuer de.uniflow.ai und de.uniflow.ai.widgets)
enum HomeWidgetGroup {
    static let id = "group.de.uniflow.ai"
    static let fileName = "home-widget.json"

    /// nil ohne App-Group-Berechtigung (Build ohne Team): dann schreibt die App nichts und das Widget zeigt den Hinweis
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)?.appendingPathComponent(fileName)
    }
}

/// Art der Widgets (`WidgetCenter.reloadTimelines(ofKind:)`)
enum HomeWidgetKind {
    static let next = "de.uniflow.ai.widget.next"
    static let mensa = "de.uniflow.ai.widget.mensa"
}

struct HomeWidgetData: Codable, Equatable {
    static let currentVersion = 1

    var version = HomeWidgetData.currentVersion
    var createdAt: Date
    /// sichtbare Termine ab heute (ohne Ausfaelle, ohne "nicht besucht"), nach Beginn sortiert
    var events: [Event]
    /// so weit reichen die Termine (Ende des letzten abgefragten Tages); danach weiss das Widget nichts mehr
    var eventsUntil: Date
    var mensa: Mensa?

    struct Event: Codable, Equatable, Hashable {
        var title: String
        var room: String?
        var start: Date
        var end: Date
        /// "#rrggbb" (Kurs- bzw. Modulfarbe wie im Stundenplan)
        var color: String?
        /// vorlesung, uebung, tutorium … (`LocalTimetable.eventKinds`)
        var kind: String?
    }

    struct Mensa: Codable, Equatable {
        var canteen: String
        var days: [Day]
    }

    struct Day: Codable, Equatable {
        /// ISO-Tag (Berlin), z. B. "2026-11-23"
        var date: String
        /// open, closed, unknown … (`Mensa.dayStatus`)
        var status: String
        var meals: [Meal]
    }

    struct Meal: Codable, Equatable, Hashable {
        var name: String
        var category: String?
        /// fertig formatiert fuer die gewaehlte Preisgruppe ("3,20 €"), nil ohne Preis
        var price: String?
        var vegan: Bool
        var vegetarian: Bool
    }
}

extension HomeWidgetData {
    /// Termine, die zu `now` laufen oder danach beginnen
    func upcoming(at now: Date) -> [Event] { events.filter { $0.end > now } }

    /// Speiseplan, den das Widget zu `now` zeigt: heute, ab 15 Uhr (Mensa zu) der naechste Tag, falls vorhanden
    func mensaDay(at now: Date) -> (day: Day, isToday: Bool)? {
        guard let m = mensa else { return nil }
        let today = HomeWidgetClock.isoDay(now)
        let hour = HomeWidgetClock.calendar.component(.hour, from: now)
        if hour >= 15, let next = m.days.first(where: { $0.date > today }) { return (next, false) }
        if let d = m.days.first(where: { $0.date == today }) { return (d, true) }
        return nil
    }
}

/// Uhr der Hochschule: Stundenplan und Mensa rechnen in Europe/Berlin (wie `BerlinClock` im Kern)
enum HomeWidgetClock {
    static let timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "de_DE")
        return c
    }

    static func isoDay(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "2026-11-23" + "10:15" -> Zeitpunkt in Berlin; nil bei unlesbaren Angaben
    static func date(day: String, time: String) -> Date? {
        let d = day.prefix(10).split(separator: "-").compactMap { Int($0) }
        let t = time.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count >= 2, (0...24).contains(t[0]), (0...59).contains(t[1]) else { return nil }
        return calendar.date(from: DateComponents(timeZone: timeZone, year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1]))
    }
}

/// Lesen und Schreiben des Schnappschusses (atomar; das Widget liest nie halbe Dateien)
enum HomeWidgetStore {
    static func load(from url: URL? = HomeWidgetGroup.fileURL) -> HomeWidgetData? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let v = try? dec.decode(HomeWidgetData.self, from: data), v.version == HomeWidgetData.currentVersion else { return nil }
        return v
    }

    /// true, wenn sich der Inhalt geaendert hat (dann lohnt das Neuladen der Widgets)
    @discardableResult
    static func save(_ value: HomeWidgetData, to url: URL? = HomeWidgetGroup.fileURL) -> Bool {
        guard let url else { return false }
        if var old = load(from: url) {
            old.createdAt = value.createdAt
            if old == value { return false }
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(value) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    }

    /// true, wenn es etwas zu loeschen gab
    @discardableResult
    static func clear(at url: URL? = HomeWidgetGroup.fileURL) -> Bool {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
