import SwiftUI
import UniFlowCore

/// Countdown in "Heute an der Uni" (26.11.2026, Entscheidung des Inhabers; vorher "Bewusst nicht umgesetzt" in
/// docs/IPHONE-FEINSCHLIFF-2026-11-23.md). Keine neue Karte (Startseite seit 13.11.2026 ohne Termine-Block): der
/// laufende Termin bekommt "läuft · noch 35 Min", der naechste "in 25 Min"; nach dem letzten Termin des Tages steht
/// unten eine Zeile "Als Nächstes: morgen 8:15 · Analysis I". Zaehlt nur besuchte Termine (Ausfall, nicht besucht,
/// verlegt zaehlen nicht; Ausfaelle laut Stud.IP sind schon ausgeblendet), Raum aus dem Vorkommen (Raumaenderungen
/// stehen dort). Neu gezeichnet zu jeder Minute (`TimelineView(.everyMinute)`), ohne Neuladen. Uhrzeiten in Berlin.
enum TerminCountdown {
    /// nur Tests (Bilder mit fester Uhrzeit): statt der Uhr der TimelineView
    static var nowOverride: Date?
    struct Label: Equatable {
        /// sichtbar: "läuft · noch 35 Min", "in 25 Min", "beginnt jetzt"
        let text: String
        /// VoiceOver: "Läuft gerade, noch 35 Minuten"
        let spoken: String
        let running: Bool
    }

    /// Termin, der als naechster nach dem heutigen Tag kommt (aus der Woche ab morgen)
    struct Later: Equatable {
        let date: String
        let start: String
        let title: String
    }

    /// besucht und mit lesbarer Zeit
    static func interval(_ e: JSONValue, date: String) -> (start: Date, end: Date)? {
        guard (e.s("status") ?? "teilnahme") == "teilnahme", let s = e.s("start"), let st = HomeWidgetClock.date(day: e.s("date") ?? date, time: s) else { return nil }
        let en = e.s("end").flatMap { HomeWidgetClock.date(day: e.s("date") ?? date, time: $0) }.flatMap { $0 > st ? $0 : nil } ?? st.addingTimeInterval(90 * 60)
        return (st, en)
    }

    /// Markierung fuer den Termin `e` aus der Liste des Tages: laufend, der naechste (bei gleichem Beginn alle) oder nil
    static func label(for e: JSONValue, in evs: [JSONValue], date: String, now: Date) -> Label? {
        guard let me = interval(e, date: date) else { return nil }
        if me.start <= now, now < me.end {
            let m = minutes(me.end.timeIntervalSince(now))
            return Label(text: "läuft · noch \(duration(m, short: true))", spoken: "Läuft gerade, noch \(duration(m, short: false))", running: true)
        }
        guard me.start > now else { return nil }
        let next = evs.compactMap { interval($0, date: date)?.start }.filter { $0 > now }.min()
        guard let next, abs(next.timeIntervalSince(me.start)) < 1 else { return nil }
        let m = minutes(me.start.timeIntervalSince(now))
        if m == 0 { return Label(text: "beginnt jetzt", spoken: "Beginnt jetzt", running: false) }
        return Label(text: "in \(duration(m, short: true))", spoken: "Beginnt in \(duration(m, short: false))", running: false)
    }

    /// Ist heute nichts mehr offen (alles vorbei)? Dann die Zeile "Als Nächstes"; ohne besuchten Termin heute nil
    /// (dann gab es nichts herunterzuzaehlen)
    static func afterLast(_ evs: [JSONValue], date: String, now: Date, later: Later?) -> Label? {
        let ivs = evs.compactMap { interval($0, date: date) }
        guard !ivs.isEmpty, ivs.allSatisfy({ $0.end <= now }), let later, let at = HomeWidgetClock.date(day: later.date, time: later.start) else { return nil }
        let when = dayText(later.date, today: date)
        let time = clock(later.start)
        return Label(text: "Als Nächstes: \(when.short) \(time) · \(later.title)",
                     spoken: "Nächster Termin \(when.spoken) um \(time) Uhr: \(later.title)", running: at <= now)
    }

    /// Erster besuchter Termin ab morgen aus GET /api/timetable/week?start=<morgen> (ohne Ausfaelle laut Stud.IP)
    static func later(week: JSONValue?, cancelled: Set<String>) -> Later? {
        for day in week?.list("days") ?? [] {
            guard let date = day.s("date") else { continue }
            let evs = StudIPCancellations.visible(day.list("events"), keys: cancelled)
                .filter { interval($0, date: date) != nil }
                .sorted { (interval($0, date: date)?.start ?? .distantFuture) < (interval($1, date: date)?.start ?? .distantFuture) }
            if let e = evs.first, let s = e.s("start") {
                let t = (e.s("title") ?? e.s("module_name") ?? "Termin").trimmingCharacters(in: .whitespacesAndNewlines)
                return Later(date: date, start: s, title: t.isEmpty ? "Termin" : t)
            }
        }
        return nil
    }

    /// aufgerundete Minuten (um 10:14:00 bis 10:15 ist es "in 1 Min")
    static func minutes(_ seconds: TimeInterval) -> Int { max(0, Int((seconds / 60).rounded(.up))) }

    /// "35 Min", "1 Std 5 Min", "2 Std" bzw. ausgeschrieben fuer VoiceOver
    static func duration(_ m: Int, short: Bool) -> String {
        let h = m / 60, r = m % 60
        if short {
            if h == 0 { return "\(r) Min" }
            return r == 0 ? "\(h) Std" : "\(h) Std \(r) Min"
        }
        func mins(_ n: Int) -> String { n == 1 ? "1 Minute" : "\(n) Minuten" }
        if h == 0 { return mins(r) }
        let hs = h == 1 ? "1 Stunde" : "\(h) Stunden"
        return r == 0 ? hs : "\(hs) \(mins(r))"
    }

    /// "8:15" aus "08:15"
    static func clock(_ hhmm: String) -> String {
        hhmm.hasPrefix("0") && hhmm.count == 5 ? String(hhmm.dropFirst()) : hhmm
    }

    /// "morgen", "Mo.", sonst "27.11."
    static func dayText(_ iso: String, today: String) -> (short: String, spoken: String) {
        if iso == Mensa.addDays(today, 1) { return ("morgen", "morgen") }
        if let d = HomeWidgetClock.date(day: iso, time: "12:00"), iso <= Mensa.addDays(today, 6) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "de_DE")
            f.timeZone = HomeWidgetClock.timeZone
            f.dateFormat = "EE"
            let short = f.string(from: d)
            f.dateFormat = "EEEE"
            return (short, "am \(f.string(from: d))")
        }
        let p = iso.split(separator: "-")
        let text = p.count == 3 ? "\(p[2]).\(p[1])." : iso
        return (text, "am \(text)")
    }
}

/// Die Markierung als kleines Feld (iPad, Mac) bzw. als Zeile unter dem Raum (iPhone); zu jeder Minute neu
struct TerminCountdownMark: View {
    let event: JSONValue
    let events: [JSONValue]
    let date: String
    var compact = false

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            if let l = TerminCountdown.label(for: event, in: events, date: date, now: TerminCountdown.nowOverride ?? ctx.date) {
                Text(l.text)
                    .ufFont(compact ? 12.5 : 11.52, 700)
                    .monospacedDigit()
                    .foregroundStyle(UF.accentText)
                    .lineLimit(1)
                    .padding(.horizontal, compact ? 0 : 7)
                    .padding(.vertical, compact ? 0 : 2)
                    .background {
                        if !compact { Capsule().fill(UF.accent.opacity(0.12)) }
                    }
                    .fixedSize(horizontal: !compact, vertical: true)
                    .accessibilityLabel(l.spoken)
                    .accessibilityIdentifier("dashboard.countdown")
            }
        }
    }
}

/// Zeile "Als Nächstes: morgen 8:15 · …" unten in "Heute an der Uni", sobald der letzte Termin des Tages vorbei ist
struct TerminCountdownLater: View {
    let events: [JSONValue]
    let date: String
    let later: TerminCountdown.Later?

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            if let l = TerminCountdown.afterLast(events, date: date, now: TerminCountdown.nowOverride ?? ctx.date, later: later) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    UFIcon("clock", size: 13).foregroundStyle(UF.accentText)
                    Text(l.text).ufFont(13.12, 600).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(l.spoken)
                .accessibilityIdentifier("dashboard.countdownLater")
            }
        }
    }
}
