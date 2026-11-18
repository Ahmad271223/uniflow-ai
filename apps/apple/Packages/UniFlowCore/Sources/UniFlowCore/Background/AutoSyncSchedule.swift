import Foundation

// Abgleich von selbst (Auftrag des Inhabers 17.11.2026, docs/ABGLEICH-8-BIS-18-2026-11-17.md): Zwischen 8 und 18 Uhr
// Ortszeit des Geraets gleicht die App Stud.IP, QIS, Learnweb, LSF, Moodle, Campusmanagement und die Uni-Mail von selbst
// ab, alle 30 Minuten; ausserhalb nur, wenn der Mensch auf "Sync" tippt. "Sync" fragt immer sofort ab und kennt weder
// Fenster noch Abstand - er benutzt diese Regel gar nicht.
//
// Hier steht nur die Rechnung, ohne Uhr des Systems und ohne Netz (alles pruefbar mit erfundenen Zeiten):
// - `AutoSyncSchedule`: Fenster und Abstand an EINER Stelle (`standard`); spaeter liesse sich daraus eine Einstellung
//   machen, ohne dass sich ein Aufrufer aendert.
// - `AutoSyncLedger`: je Portal der letzte Versuch von selbst und eine laengere Pause nach "ueberlastet" (429/503),
//   in den Einstellungen des Containers (uebersteht den Neustart der App durch iOS).
//
// Grenzen des Fensters: 08:00:00 gehoert dazu, 18:00:00 nicht mehr (halboffen). So ergeben 30 Minuten genau 20
// Abgleiche am Tag (08:00, 08:30 … 17:30); ein Lauf um Punkt 18:00 waere der 21. und laege schon "nach 18 Uhr".
// Der Abstand zaehlt in echter Zeit (Sekunden), das Fenster in Ortszeit: bei der Zeitumstellung (nachts, ausserhalb des
// Fensters) aendert sich nichts, auf Reisen gilt die Uhr des Ortes, an dem das Geraet ist.

/// Fenster und Abstand des Abgleichs von selbst
public struct AutoSyncSchedule: Sendable, Equatable {
    /// erste Stunde des Fensters (einschliesslich), Ortszeit
    public var startHour: Int
    /// Stunde, mit der das Fenster endet (ausschliesslich), Ortszeit
    public var endHour: Int
    /// Abstand zwischen zwei Abgleichen von selbst je Portal
    public var interval: TimeInterval

    public init(startHour: Int, endHour: Int, interval: TimeInterval) {
        self.startHour = min(max(startHour, 0), 23)
        self.endHour = min(max(endHour, 1), 24)
        self.interval = max(interval, 60)
    }

    /// Auftrag des Inhabers: 8 bis 18 Uhr, alle 30 Minuten - die eine Stelle fuer diese drei Zahlen
    public static let standard = AutoSyncSchedule(startHour: 8, endHour: 18, interval: 30 * 60)

    /// Abgleiche von selbst an einem Tag, wenn die App durchgehend offen ist (8-18 Uhr, 30 Minuten: 20)
    public var runsPerDay: Int {
        guard endHour > startHour else { return 0 }
        return Int((Double(endHour - startHour) * 3600 / interval).rounded(.up))
    }

    private func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// Liegt `now` im Fenster? Gerechnet mit der Stunde der Ortszeit: `startHour` <= Stunde < `endHour`.
    public func isInWindow(_ now: Date, timeZone: TimeZone) -> Bool {
        let hour = calendar(timeZone).component(.hour, from: now)
        return hour >= startHour && hour < endHour
    }

    /// Erster Beginn eines Fensters, der nicht vor `date` liegt (heute, morgen oder uebermorgen `startHour`:00 Ortszeit)
    public func windowStart(onOrAfter date: Date, timeZone: TimeZone) -> Date {
        let cal = calendar(timeZone)
        let today = cal.startOfDay(for: date)
        for offset in 0...2 {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: day)
            c.hour = startHour
            c.minute = 0
            c.second = 0
            if let d = cal.date(from: c), d >= date { return d }
        }
        return date.addingTimeInterval(24 * 3600)              // nur bei einer kaputten Zeitzone
    }

    /// Ist jetzt ein Abgleich von selbst faellig? Nur im Fenster; ohne bisherigen Lauf sofort, sonst `interval` nach
    /// `last` (dem letzten gelungenen Abgleich oder dem letzten Versuch von selbst). Liegt `last` in der Zukunft (Uhr
    /// zurueckgestellt, Datum gesprungen), gilt es als faellig - der Lauf setzt `last` dann neu, es bleibt bei einem.
    public func isDue(last: Date?, now: Date, timeZone: TimeZone) -> Bool {
        guard isInWindow(now, timeZone: timeZone) else { return false }
        guard let last else { return true }
        let age = now.timeIntervalSince(last)
        return age < 0 || age >= interval
    }

    /// Fruehester Zeitpunkt des naechsten Abgleichs von selbst, nie vor `now`: im Fenster `last` + `interval` (ohne
    /// `last` oder ueberfaellig: jetzt); faellt das hinter das Ende des Fensters oder ist es gerade zu, der naechste
    /// Beginn (`startHour`:00). Fuer den Zeitgeber bei offener App und den Wunschtermin an iOS.
    public func nextRun(last: Date?, now: Date, timeZone: TimeZone) -> Date {
        var candidate = now
        if let last, last <= now { candidate = max(now, last.addingTimeInterval(interval)) }
        if isInWindow(candidate, timeZone: timeZone) { return candidate }
        return windowStart(onOrAfter: candidate, timeZone: timeZone)
    }
}

/// Laengere Pause nach einer ueberlasteten Hochschule (HTTP 429 "zu viele Anfragen", 503 "nicht verfuegbar"): der
/// Abgleich von selbst fragt dieses Portal dann eine Weile nicht mehr - nur der Knopf "Sync".
public enum AutoSyncOverload {
    /// so lange ruht der Abgleich von selbst fuer dieses Portal
    public static let pause: TimeInterval = 2 * 3600
    public static let statuses: Set<Int> = [429, 503]

    public static func isOverload(status: Int) -> Bool { statuses.contains(status) }

    /// Nennt eine Fehlermeldung eines Abgleichs einen dieser Status? Die Abgleiche reichen den Status nur als Text weiter
    /// ("Stud.IP antwortet mit HTTP 429 (…)", "HTTP 503 bei https://…"); gesucht wird genau "HTTP 429" bzw. "HTTP 503"
    /// als eigene Zahl (nicht "HTTP 4290").
    public static func mentionsOverload(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        for status in statuses {
            var search = message.startIndex..<message.endIndex
            while let r = message.range(of: "HTTP \(status)", range: search) {
                if r.upperBound == message.endIndex || !message[r.upperBound].isNumber { return true }
                search = r.upperBound..<message.endIndex
            }
        }
        return false
    }
}

/// Stand des Abgleichs von selbst je Portal in den Einstellungen des Containers (getrennt je Nutzer und Hochschule; geht
/// mit "Daten dieser Hochschule löschen"). Keine Geheimnisse, nur Zeitpunkte.
public struct AutoSyncLedger {
    public static let prefix = "uniflow.autosync."
    /// Mindestabstand zwischen zwei Versuchen von selbst, wenn Arbeit wartet (`isDue(pending:)`)
    public static let retryGap: TimeInterval = 5 * 60

    public let defaults: UserDefaults
    public var schedule: AutoSyncSchedule

    public init(defaults: UserDefaults, schedule: AutoSyncSchedule = .standard) {
        self.defaults = defaults
        self.schedule = schedule
    }

    static func name(_ portal: String) -> String { portal.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func attemptKey(_ portal: String) -> String { prefix + "attempt." + name(portal) }
    static func pauseKey(_ portal: String) -> String { prefix + "pause." + name(portal) }

    /// Letzter Versuch von selbst (gelungen oder nicht)
    public func lastAttempt(_ portal: String) -> Date? { defaults.object(forKey: Self.attemptKey(portal)) as? Date }

    /// Ein Abgleich von selbst beginnt: ab jetzt `interval` Ruhe fuer dieses Portal, auch wenn er scheitert
    public func recordAttempt(_ portal: String, at now: Date) { defaults.set(now, forKey: Self.attemptKey(portal)) }

    /// Ende einer laufenden Pause nach "ueberlastet"; nil ohne Pause, nach ihrem Ende oder wenn sie unsinnig weit in der
    /// Zukunft liegt (Uhr inzwischen zurueckgestellt): eine Pause dauert nie laenger als `AutoSyncOverload.pause`
    public func pausedUntil(_ portal: String, now: Date) -> Date? {
        guard let until = defaults.object(forKey: Self.pauseKey(portal)) as? Date, until > now,
              until.timeIntervalSince(now) <= AutoSyncOverload.pause else { return nil }
        return until
    }

    /// Die Hochschule meldete "ueberlastet": Abgleich von selbst fuer dieses Portal ruhen lassen
    public func pause(_ portal: String, from now: Date) {
        defaults.set(now.addingTimeInterval(AutoSyncOverload.pause), forKey: Self.pauseKey(portal))
    }

    /// Ein Abgleich dieses Portals ist gelungen: Pause weg (nur schreiben, wenn es etwas zu loeschen gibt)
    public func clearPause(_ portal: String) {
        if defaults.object(forKey: Self.pauseKey(portal)) != nil { defaults.removeObject(forKey: Self.pauseKey(portal)) }
    }

    /// Bezugspunkt des Abstands: der spaetere aus letztem gelungenen Abgleich (auch einem von Hand) und letztem Versuch
    /// von selbst
    public func reference(_ portal: String, lastSuccess: Date?) -> Date? {
        [lastSuccess, lastAttempt(portal)].compactMap { $0 }.max()
    }

    /// Darf dieses Portal jetzt von selbst abgeglichen werden?
    /// - Parameters:
    ///   - lastSuccess: letzter gelungener Abgleich des Portals (auch von Hand); nil: noch keiner
    ///   - pending: ein begonnener Abgleich wartet auf seine Fortsetzung (unterbrochen, Dateien eines Laufs nur mit
    ///     Listen noch nicht geladen): dann ohne den Abstand des Plans, aber weiter nur im Fenster, nie in einer Pause
    ///     und fruehestens `retryGap` nach dem letzten Versuch von selbst (scheitert die Fortsetzung immer wieder,
    ///     fragt der Zeitgeber sonst im Minutentakt)
    ///   - interval: eigener Abstand dieses Aufrufs (z. B. die Liste der Bescheinigungen seltener); nil: der des Plans
    ///   - retryGap: Abstand fuer wartende Arbeit (Vorgabe `retryGap`; 0 im langen Hintergrundlauf, der die Dateien eines
    ///     eben gelaufenen kurzen Laufs laedt)
    public func isDue(_ portal: String, lastSuccess: Date?, pending: Bool = false, now: Date, timeZone: TimeZone,
                      interval: TimeInterval? = nil, retryGap: TimeInterval = AutoSyncLedger.retryGap) -> Bool {
        guard schedule.isInWindow(now, timeZone: timeZone), pausedUntil(portal, now: now) == nil else { return false }
        if pending {
            guard let attempt = lastAttempt(portal) else { return true }
            let age = now.timeIntervalSince(attempt)
            return age < 0 || age >= retryGap
        }
        var s = schedule
        if let interval { s.interval = interval }
        return s.isDue(last: reference(portal, lastSuccess: lastSuccess), now: now, timeZone: timeZone)
    }

    /// Fruehester naechster Abgleich von selbst fuer dieses Portal (nach einer Pause erst danach)
    public func nextRun(_ portal: String, lastSuccess: Date?, now: Date, timeZone: TimeZone) -> Date {
        let start = pausedUntil(portal, now: now) ?? now
        return schedule.nextRun(last: reference(portal, lastSuccess: lastSuccess), now: start, timeZone: timeZone)
    }
}
