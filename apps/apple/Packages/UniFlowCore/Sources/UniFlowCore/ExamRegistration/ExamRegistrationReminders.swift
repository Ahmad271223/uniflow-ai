import Foundation

/// Erinnerungen an den Meldezeitraum (lokale Mitteilungen, reine Funktion; docs/PRUEFUNGSANMELDUNG-2026-11-05.md): am
/// ersten Tag, 7 Tage und 2 Tage vor dem Ende jeweils um 9:00 (Berlin), fuer das Fenster "alle anderen
/// Prüfungsformen" und - wenn noch VbP fehlen - fuer VbP. Nur kuenftige Zeitpunkte, nur mit sicher bekanntem Zeitraum.
/// Kennungen "de.uniflow.ai.examreg.<Container>.<Semester>.<Art><n>.<Zeitpunkt>"; eigener Anfang, damit der Schalter
/// fuer Abgaben und Pruefungen (`DueReminders`) und dieser sich nicht gegenseitig zuruecknehmen.
public enum ExamRegistrationReminders {
    public static let prefix = "de.uniflow.ai.examreg."
    /// Uhrzeit (Minuten nach Mitternacht)
    static let at = 9 * 60
    /// Ziel beim Antippen: Studienverlauf mit dem Abschnitt Pruefungsanmeldung
    public static let route = "#/studyplan"

    public static func prefix(container: String) -> String { prefix + container + "." }

    static func when(_ iso: String) -> String {
        guard let d = BerlinClock.parseISODate(iso) else { return iso }
        return DueReminders.when(d, nil)
    }

    public static func plan(_ response: JSONValue, container: String, now: Date) -> [DueReminders.Reminder] {
        guard response["supported"]?.bool == true else { return [] }
        let suggestions = response["suggestions"]?.array ?? []
        func open(_ period: String) -> Int {
            suggestions.filter { $0["registered"]?.bool != true && ($0["period"]?.string ?? "meldung") == period }.count
        }
        var out: [DueReminders.Reminder] = []
        for (key, period) in [("window", "meldung"), ("vbp_window", "vbp")] {
            let w = response[key] ?? .null
            guard let start = w["start"]?.string.flatMap(BerlinClock.parseISODate), let end = w["end"]?.string.flatMap(BerlinClock.parseISODate),
                  let term = w["term"]?.string else { continue }
            let missing = open(period)
            if period == "vbp" && missing == 0 { continue }                     // VbP nur, wenn dort etwas fehlt
            let what = period == "vbp" ? "Prüfungsanmeldung (VbP)" : "Prüfungsanmeldung"
            let count = missing == 0 ? "" : (missing == 1 ? " · 1 Prüfung laut Plan noch nicht angemeldet" : " · \(missing) Prüfungen laut Plan noch nicht angemeldet")
            let body = "\(term): bis \(when(w["end"]?.string ?? ""))" + count
            var slots: [(tag: String, day: Int, title: String)] = [("start", start, "\(what) beginnt heute")]
            if end - 7 > start { slots.append(("d7", end - 7, "\(what): noch 7 Tage")) }
            if end - 2 > start { slots.append(("d2", end - 2, "\(what) endet übermorgen")) }
            let base = prefix(container: container) + ExamRegistrationPeriods.slugify(term) + "." + (period == "vbp" ? "vbp" : "meldung")
                + String(w["n"]?.int ?? 1) + "."
            for s in slots {
                let fire = DueReminders.date(day: s.day, minutes: at)
                guard fire > now else { continue }
                out.append(DueReminders.Reminder(identifier: base + s.tag, fireAt: fire, title: s.title, body: body, route: route,
                                                 itemID: "examreg-\(period)"))
            }
        }
        return out.sorted { $0.fireAt != $1.fireAt ? $0.fireAt < $1.fireAt : $0.identifier < $1.identifier }
    }

    /// Abgleich mit den geplanten Mitteilungen: nur eigene Kennungen (`prefix`) zuruecknehmen
    public static func diff(pending: [String], planned: [DueReminders.Reminder]) -> (remove: [String], add: [DueReminders.Reminder]) {
        let keep = Set(planned.map(\.identifier))
        return (Array(Set(pending.filter { $0.hasPrefix(prefix) && !keep.contains($0) })).sorted(), planned)
    }
}
