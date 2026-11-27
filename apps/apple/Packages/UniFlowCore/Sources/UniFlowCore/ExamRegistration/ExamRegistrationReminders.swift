import Foundation

/// Erinnerungen an den Meldezeitraum (lokale Mitteilungen, reine Funktion; docs/PRUEFUNGSANMELDUNG-2026-11-05.md): am
/// ersten Tag, 7 Tage und 2 Tage vor dem Ende jeweils um 9:00 (Berlin), fuer das Fenster "alle anderen
/// Prüfungsformen" und - wenn noch VbP fehlen - fuer VbP. Nur kuenftige Zeitpunkte, nur mit sicher bekanntem Zeitraum.
/// Fenster ohne Ende (`open_end`, Uni Hildesheim: Fristen je Pruefung im LSF) nur am ersten Tag.
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
            let openEnd = w["open_end"]?.bool ?? false
            let system = response["system"]?.string ?? "QIS"
            let body = (openEnd ? "\(term): Anmeldung im \(system) freigeschaltet, Fristen je Prüfung" : "\(term): bis \(when(w["end"]?.string ?? ""))")
                + count
            var slots: [(tag: String, day: Int, title: String)] = [("start", start, "\(what) beginnt heute")]
            if !openEnd, end - 7 > start { slots.append(("d7", end - 7, "\(what): noch 7 Tage")) }
            if !openEnd, end - 2 > start { slots.append(("d2", end - 2, "\(what) endet übermorgen")) }
            let base = prefix(container: container) + ExamRegistrationPeriods.slugify(term) + "." + (period == "vbp" ? "vbp" : "meldung")
                + String(w["n"]?.int ?? 1) + "."
            for s in slots {
                let fire = DueReminders.date(day: s.day, minutes: at)
                guard fire > now else { continue }
                out.append(DueReminders.Reminder(identifier: base + s.tag, fireAt: fire, title: s.title, body: body, route: route,
                                                 itemID: "examreg-\(period)"))
            }
        }
        out += planWithdraw(response, container: container, now: now)
        return out.sorted { $0.fireAt != $1.fireAt ? $0.fireAt < $1.fireAt : $0.identifier < $1.identifier }
    }

    /// Ziel beim Antippen einer Erinnerung an die Abmeldefrist: "Uni & Noten" (Karte "Prüfungen (FlexNow)")
    public static let withdrawRoute = "#/services"

    /// Uni Goettingen (FlexNow, 27.11.2026; nur mit `withdraw_reminders` in der Antwort, also nicht an LUH oder
    /// Hildesheim): 7 und 2 Tage vor dem Ende der Abmeldefrist einer angemeldeten Pruefung um 9:00 (Berlin), je Tag
    /// eine Mitteilung fuer alle Pruefungen mit derselben Frist. Kennungen "<prefix><Container>.abmeldung.<Tag>.d7|d2".
    public static func planWithdraw(_ response: JSONValue, container: String, now: Date) -> [DueReminders.Reminder] {
        guard response["supported"]?.bool == true, response["withdraw_reminders"]?.bool == true else { return [] }
        let system = response["system"]?.string ?? "FlexNow"
        var byDay: [String: [(title: String, time: String?)]] = [:]
        for r in response["registered"]?.array ?? [] where r["registered"]?.bool != false {
            guard let day = r["withdraw_until"]?.string, BerlinClock.parseISODate(day) != nil, let title = r["text"]?.string else { continue }
            byDay[day, default: []].append((title, r["withdraw_time"]?.string))
        }
        var out: [DueReminders.Reminder] = []
        for (iso, items) in byDay {
            guard let end = BerlinClock.parseISODate(iso) else { continue }
            let time = items.compactMap(\.time).first.map { ", \($0) Uhr" } ?? ""
            let names = items.map(\.title)
            let what = names.count == 1 ? names[0] : "\(names.count) angemeldete Prüfungen (\(names.prefix(3).joined(separator: ", "))\(names.count > 3 ? " …" : ""))"
            let body = "\(what): Abmeldung in \(system) möglich bis \(when(iso))\(time)."
            let base = prefix(container: container) + "abmeldung." + iso + "."
            for (tag, day, title) in [("d7", end - 7, "Abmeldefrist: noch 7 Tage"), ("d2", end - 2, "Abmeldefrist endet übermorgen")] {
                let fire = DueReminders.date(day: day, minutes: at)
                guard fire > now else { continue }
                out.append(DueReminders.Reminder(identifier: base + tag, fireAt: fire, title: title, body: body, route: withdrawRoute,
                                                 itemID: "examreg-abmeldung"))
            }
        }
        return out
    }

    /// Abgleich mit den geplanten Mitteilungen: nur eigene Kennungen (`prefix`) zuruecknehmen
    public static func diff(pending: [String], planned: [DueReminders.Reminder]) -> (remove: [String], add: [DueReminders.Reminder]) {
        let keep = Set(planned.map(\.identifier))
        return (Array(Set(pending.filter { $0.hasPrefix(prefix) && !keep.contains($0) })).sorted(), planned)
    }
}
