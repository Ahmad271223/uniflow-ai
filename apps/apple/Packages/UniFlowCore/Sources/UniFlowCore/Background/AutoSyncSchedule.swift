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
// Mit dem Versatz eines Geraets (`offset`, seit 26.11.2026) beginnt das Fenster spaeter, z. B. 08:17:00, die Laeufe
// liegen dann um 08:17, 08:47 … 17:47 - weiter hoechstens 20 am Tag, das Ende bleibt 18:00.
// Der Abstand zaehlt in echter Zeit (Sekunden), das Fenster in Ortszeit: bei der Zeitumstellung (nachts, ausserhalb des
// Fensters) aendert sich nichts, auf Reisen gilt die Uhr des Ortes, an dem das Geraet ist.
//
// Seit 27.11.2026 (Auftrag des Inhabers, docs/ABRUF-ZWEIMAL-TAEGLICH-2026-11-27.md): Die Hochschul-Portale (Stud.IP, QIS,
// Learnweb, LSF, Moodle, Campusmanagement …) gleicht die App von selbst nur noch ZWEIMAL am Tag ab - in zwei festen
// Zeitfenstern (`slotHours`, Plan `twiceDaily`: ab 8 und ab 14 Uhr, je Geraet um 0 bis 59 Minuten versetzt). Ein
// Fenster gilt als erledigt, sobald nach seinem Beginn ein Abgleich lief (von selbst oder mit "Sync"); verpasst die App
// ein Fenster (zu, iOS weckt nicht), holt sie es beim naechsten Oeffnen bis 18 Uhr nach - aber nie zwei Abgleiche von
// selbst naeher als `interval` (2 Stunden) beieinander. Die Uni-Mail behaelt ihren Takt (`standard`, alle 30 Minuten).

/// Fenster und Abstand des Abgleichs von selbst
public struct AutoSyncSchedule: Sendable, Equatable {
    /// erste Stunde des Fensters (einschliesslich), Ortszeit
    public var startHour: Int
    /// Stunde, mit der das Fenster endet (ausschliesslich), Ortszeit
    public var endHour: Int
    /// Abstand zwischen zwei Abgleichen von selbst je Portal
    public var interval: TimeInterval
    /// Fester Versatz dieses Geraets (0 bis unter `interval`, ganze Sekunden): das Fenster beginnt erst um
    /// `startHour`:00 + `offset`, das Ende bleibt `endHour`:00 (26.11.2026, "Abruf schonen": sonst fragen alle Geraete,
    /// die um 8 Uhr offen sind oder von iOS geweckt werden, zur selben Sekunde bei der Hochschule an). Standard 0.
    public var offset: TimeInterval
    /// Feste Zeitfenster je Tag (volle Stunden Ortszeit, aufsteigend, im Fenster; 27.11.2026): je Fenster hoechstens ein
    /// Abgleich von selbst, ab `Stunde`:00 + `offset`. `interval` ist dann der Mindestabstand zweier Abgleiche von selbst.
    /// Leer: alle `interval` ein Abgleich (bisherige Regel, die Uni-Mail).
    public var slotHours: [Int]

    public init(startHour: Int, endHour: Int, interval: TimeInterval, offset: TimeInterval = 0, slotHours: [Int] = []) {
        self.startHour = min(max(startHour, 0), 23)
        self.endHour = min(max(endHour, 1), 24)
        self.interval = max(interval, 60)
        self.offset = min(max(offset, 0), self.interval - 1).rounded(.down)
        let lo = self.startHour, hi = self.endHour
        self.slotHours = Array(Set(slotHours.filter { $0 >= lo && $0 < hi })).sorted()
    }

    /// Auftrag des Inhabers: 8 bis 18 Uhr, alle 30 Minuten - die eine Stelle fuer diese drei Zahlen. Seit 27.11.2026
    /// nur noch der Takt der Uni-Mail ("Mail immer, nicht nur 2-mal").
    public static let standard = AutoSyncSchedule(startHour: 8, endHour: 18, interval: 30 * 60)

    /// Auftrag des Inhabers 27.11.2026: alle Hochschul-Portale ausser der Uni-Mail von selbst nur zweimal am Tag - ab
    /// 8 Uhr und ab 14 Uhr (je Geraet versetzt, `slotSpread`), nachgeholt bis 18 Uhr, mindestens 2 Stunden Abstand
    public static let twiceDaily = AutoSyncSchedule(startHour: 8, endHour: 18, interval: 2 * 3600, slotHours: [8, 14])

    /// Spanne des Versatzes je Geraet fuer die festen Fenster: 0 bis 59 Minuten
    public static let slotSpread: TimeInterval = 3600

    /// Derselbe Plan mit dem festen Versatz eines Geraets (`AutoSyncStagger`)
    public func staggered(by offset: TimeInterval) -> AutoSyncSchedule {
        AutoSyncSchedule(startHour: startHour, endHour: endHour, interval: interval, offset: offset, slotHours: slotHours)
    }

    /// Plan mit festen Fenstern?
    public var hasSlots: Bool { !slotHours.isEmpty }

    /// Abgleiche von selbst an einem Tag, wenn die App durchgehend offen ist (8-18 Uhr, 30 Minuten: 20; zwei feste
    /// Fenster: 2)
    public var runsPerDay: Int {
        guard endHour > startHour else { return 0 }
        if hasSlots { return slotHours.count }
        return Int((Double(endHour - startHour) * 3600 / interval).rounded(.up))
    }

    private func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// Liegt `now` im Fenster? Gerechnet mit der Uhr der Ortszeit: `startHour`:00 + `offset` <= Uhrzeit < `endHour`:00.
    public func isInWindow(_ now: Date, timeZone: TimeZone) -> Bool {
        let c = calendar(timeZone).dateComponents([.hour, .minute, .second], from: now)
        let second = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
        return second >= startHour * 3600 + Int(offset) && second < endHour * 3600
    }

    /// Erster Beginn eines Fensters, der nicht vor `date` liegt (heute, morgen oder uebermorgen `startHour`:00 +
    /// `offset` Ortszeit)
    public func windowStart(onOrAfter date: Date, timeZone: TimeZone) -> Date {
        let cal = calendar(timeZone)
        let today = cal.startOfDay(for: date)
        for day in 0...2 {
            guard let d0 = cal.date(byAdding: .day, value: day, to: today) else { continue }
            var c = cal.dateComponents([.year, .month, .day], from: d0)
            c.hour = startHour
            c.minute = 0
            c.second = 0
            if let d = cal.date(from: c)?.addingTimeInterval(offset), d >= date { return d }
        }
        return date.addingTimeInterval(24 * 3600)              // nur bei einer kaputten Zeitzone
    }

    /// Beginn der festen Fenster eines Tages (`Stunde`:00 + `offset` Ortszeit), aufsteigend
    public func slotStarts(onDayOf date: Date, timeZone: TimeZone) -> [Date] {
        let cal = calendar(timeZone)
        let day = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: date))
        return slotHours.compactMap { h -> Date? in
            var c = day
            c.hour = h
            c.minute = 0
            c.second = 0
            return cal.date(from: c)?.addingTimeInterval(offset)
        }
    }

    /// Beginn des festen Fensters, in dem `now` liegt: das letzte von heute, das schon begonnen hat (nil: vor dem
    /// ersten oder ohne feste Fenster)
    public func currentSlotStart(_ now: Date, timeZone: TimeZone) -> Date? {
        slotStarts(onDayOf: now, timeZone: timeZone).last { $0 <= now }
    }

    /// Ist jetzt ein Abgleich von selbst faellig? Nur im Fenster; ohne bisherigen Lauf sofort, sonst `interval` nach
    /// `last` (dem letzten gelungenen Abgleich oder dem letzten Versuch von selbst). Liegt `last` in der Zukunft (Uhr
    /// zurueckgestellt, Datum gesprungen), gilt es als faellig - der Lauf setzt `last` dann neu, es bleibt bei einem.
    /// Feste Fenster (`slotHours`): faellig, wenn das laufende Fenster seit seinem Beginn noch keinen Abgleich hatte
    /// (`last` davor) und `last` mindestens `interval` zurueckliegt.
    public func isDue(last: Date?, now: Date, timeZone: TimeZone) -> Bool {
        guard isInWindow(now, timeZone: timeZone) else { return false }
        if hasSlots {
            guard let slot = currentSlotStart(now, timeZone: timeZone) else { return false }
            guard let last else { return true }
            let age = now.timeIntervalSince(last)
            return age < 0 || (last < slot && age >= interval)
        }
        guard let last else { return true }
        let age = now.timeIntervalSince(last)
        return age < 0 || age >= interval
    }

    /// Fruehester Zeitpunkt des naechsten Abgleichs von selbst, nie vor `now`: im Fenster `last` + `interval` (ohne
    /// `last` oder ueberfaellig: jetzt); faellt das hinter das Ende des Fensters oder ist es gerade zu, der naechste
    /// Beginn (`startHour`:00). Fuer den Zeitgeber bei offener App und den Wunschtermin an iOS.
    public func nextRun(last: Date?, now: Date, timeZone: TimeZone) -> Date {
        if hasSlots { return nextSlotRun(last: last, now: now, timeZone: timeZone) }
        var candidate = now
        if let last, last <= now { candidate = max(now, last.addingTimeInterval(interval)) }
        if isInWindow(candidate, timeZone: timeZone) { return candidate }
        return windowStart(onOrAfter: candidate, timeZone: timeZone)
    }

    /// `nextRun` mit festen Fenstern: der frueheste Zeitpunkt ab `now`, an dem `isDue` gilt. Faellig werden kann es nur
    /// jetzt, am Beginn eines Fensters oder wenn der Mindestabstand nach `last` um ist.
    private func nextSlotRun(last: Date?, now: Date, timeZone: TimeZone) -> Date {
        if isDue(last: last, now: now, timeZone: timeZone) { return now }
        let cal = calendar(timeZone)
        var candidates: [Date] = []
        if let last, last <= now { candidates.append(last.addingTimeInterval(interval)) }
        for day in 0...2 {
            guard let d = cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: now)) else { continue }
            candidates += slotStarts(onDayOf: d, timeZone: timeZone)
        }
        for t in candidates.filter({ $0 > now }).sorted() where isDue(last: last, now: t, timeZone: timeZone) { return t }
        return now.addingTimeInterval(24 * 3600)               // nur bei einer kaputten Zeitzone
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

    /// Fortsetzungen wartender Arbeit (unterbrochen, Dateien noch nicht geladen) je festem Fenster und Portal
    /// hoechstens so oft (27.11.2026): sonst fragte ein haengender Download den ganzen Tag alle 5 Minuten an
    public static let maxContinuations = 3

    public let defaults: UserDefaults
    /// Plan aller Portale ohne eigenen Eintrag in `overrides`
    public var schedule: AutoSyncSchedule
    /// eigener Plan einzelner Portale (27.11.2026: die Uni-Mail alle 30 Minuten, alle anderen zweimal am Tag)
    public var overrides: [String: AutoSyncSchedule]

    public init(defaults: UserDefaults, schedule: AutoSyncSchedule = .standard, overrides: [String: AutoSyncSchedule] = [:]) {
        self.defaults = defaults
        self.schedule = schedule
        self.overrides = overrides
    }

    /// Plan dieses Portals
    public func schedule(for portal: String) -> AutoSyncSchedule { overrides[portal] ?? schedule }

    static func name(_ portal: String) -> String { portal.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func attemptKey(_ portal: String) -> String { prefix + "attempt." + name(portal) }
    static func pauseKey(_ portal: String) -> String { prefix + "pause." + name(portal) }
    static func continueKey(_ portal: String) -> String { prefix + "continue." + name(portal) }

    /// Letzter Versuch von selbst (gelungen oder nicht)
    public func lastAttempt(_ portal: String) -> Date? { defaults.object(forKey: Self.attemptKey(portal)) as? Date }

    /// Ein Abgleich von selbst beginnt: ab jetzt Ruhe fuer dieses Portal nach seinem Plan, auch wenn er scheitert.
    /// Feste Fenster: lag der letzte Versuch schon im selben Fenster, zaehlt dieser als Fortsetzung
    /// (`continuations`).
    public func recordAttempt(_ portal: String, at now: Date, timeZone: TimeZone = .current) {
        let s = schedule(for: portal)
        if s.hasSlots {
            let slot = s.currentSlotStart(now, timeZone: timeZone)
            if let slot, let prev = lastAttempt(portal), prev >= slot, prev <= now {
                defaults.set(continuations(portal, now: now, timeZone: timeZone) + 1, forKey: Self.continueKey(portal))
            } else if defaults.object(forKey: Self.continueKey(portal)) != nil {
                defaults.removeObject(forKey: Self.continueKey(portal))
            }
        }
        defaults.set(now, forKey: Self.attemptKey(portal))
    }

    /// Fortsetzungen in diesem festen Fenster bisher (0, wenn der letzte Versuch vor dem Fenster lag)
    public func continuations(_ portal: String, now: Date, timeZone: TimeZone) -> Int {
        let s = schedule(for: portal)
        guard s.hasSlots, let slot = s.currentSlotStart(now, timeZone: timeZone), let prev = lastAttempt(portal),
              prev >= slot, prev <= now else { return 0 }
        return defaults.integer(forKey: Self.continueKey(portal))
    }

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
    ///   - interval: eigener Abstand dieses Aufrufs (z. B. die Liste der Bescheinigungen seltener); nil: der des Plans.
    ///     Mit eigenem Abstand gilt der Takt ohne feste Fenster (nur innerhalb eines Abgleichs, der selbst schon dran ist)
    ///   - retryGap: Abstand fuer wartende Arbeit (Vorgabe `retryGap`; 0 im langen Hintergrundlauf, der die Dateien eines
    ///     eben gelaufenen kurzen Laufs laedt)
    /// Feste Fenster (27.11.2026): wartende Arbeit darf im selben Fenster hoechstens `maxContinuations`-mal weiter.
    public func isDue(_ portal: String, lastSuccess: Date?, pending: Bool = false, now: Date, timeZone: TimeZone,
                      interval: TimeInterval? = nil, retryGap: TimeInterval = AutoSyncLedger.retryGap) -> Bool {
        let s = plan(portal, interval: interval)
        guard s.isInWindow(now, timeZone: timeZone), pausedUntil(portal, now: now) == nil else { return false }
        if pending {
            if s.hasSlots, continuations(portal, now: now, timeZone: timeZone) >= Self.maxContinuations {
                return s.isDue(last: reference(portal, lastSuccess: lastSuccess), now: now, timeZone: timeZone)
            }
            guard let attempt = lastAttempt(portal) else { return true }
            let age = now.timeIntervalSince(attempt)
            return age < 0 || age >= retryGap
        }
        return s.isDue(last: reference(portal, lastSuccess: lastSuccess), now: now, timeZone: timeZone)
    }

    /// Fruehester naechster Abgleich von selbst fuer dieses Portal (nach einer Pause erst danach). `interval`: eigener
    /// Abstand dieses Portals (wie bei `isDue`); nil: der des Plans
    public func nextRun(_ portal: String, lastSuccess: Date?, now: Date, timeZone: TimeZone,
                        interval: TimeInterval? = nil) -> Date {
        let start = pausedUntil(portal, now: now) ?? now
        return plan(portal, interval: interval).nextRun(last: reference(portal, lastSuccess: lastSuccess), now: start, timeZone: timeZone)
    }

    /// Plan dieses Aufrufs: der des Portals; mit eigenem Abstand als Takt ohne feste Fenster
    private func plan(_ portal: String, interval: TimeInterval?) -> AutoSyncSchedule {
        var s = schedule(for: portal)
        if let interval {
            s.slotHours = []
            s.interval = interval
        }
        return s
    }
}

/// Fester Versatz des Abgleichs von selbst je Geraet (26.11.2026, "Abruf schonen"): einmal zufaellig gewuerfelt, dann
/// dauerhaft in den Einstellungen des Geraets (nie in iCloud, nie beim Dienst). So verteilen sich die Geraete ueber die
/// ersten 30 Minuten des Fensters, statt um Punkt 8:00, 8:30 … gemeinsam anzufragen. Das Weck-Signal des Dienstes
/// staffelt genauso (app/wake_push.py `offset_minutes`); beide Versaetze sind unabhaengig, und das schadet nicht: der
/// Abgleich startet erst, wenn beide Regeln ihn erlauben, und bleibt je Portal bei hoechstens einem je Abstand.
public enum AutoSyncStagger {
    public static let key = "uniflow.autosync.staggerSeconds"

    /// Versatz in ganzen Sekunden, 0 bis unter `interval`. Steht schon einer da (und passt er), bleibt er; sonst wird
    /// einer gewuerfelt und gemerkt.
    /// Eigener Versatz der festen Fenster (27.11.2026, `AutoSyncSchedule.twiceDaily`): 0 bis 59 Minuten, unabhaengig vom
    /// Versatz der Uni-Mail (`key`, 0 bis 29 Minuten)
    public static let slotKey = "uniflow.autosync.slotStaggerSeconds"

    public static func offset(defaults: UserDefaults, interval: TimeInterval = AutoSyncSchedule.standard.interval,
                              key: String = AutoSyncStagger.key,
                              random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> TimeInterval {
        let range = max(Int(interval), 1)
        if let saved = defaults.object(forKey: key) as? Int, saved >= 0, saved < range { return TimeInterval(saved) }
        let value = min(max(random(range), 0), range - 1)
        defaults.set(value, forKey: key)
        return TimeInterval(value)
    }

    /// Versatz der festen Fenster dieses Geraets (0 bis unter `AutoSyncSchedule.slotSpread`)
    public static func slotOffset(defaults: UserDefaults, random: (Int) -> Int = { Int.random(in: 0..<$0) }) -> TimeInterval {
        offset(defaults: defaults, interval: AutoSyncSchedule.slotSpread, key: slotKey, random: random)
    }
}
