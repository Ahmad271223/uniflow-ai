import Foundation
import SwiftUI
import UniFlowCore

// Erinnerung vor der Vorlesung (Entscheidung des Inhabers 27.11.2026: „Ja, Schalter, aus“). Eine lokale Mitteilung
// z. B. 10 Minuten vor jedem besuchten Termin des Stundenplans: „In 10 Min: Analysis I“, darunter Zeit und Raum.
// Antippen oeffnet den Stundenplan am Tag. Schalter in der Karte „Mitteilungen“, Vorgabe aus; erst das Einschalten
// fragt iOS. Zeit waehlbar (5/10/15/30 Minuten).
//
// Regeln:
// - nur besuchte Termine (Ausfall, nicht besucht, verlegt zaehlen nicht; Ausfaelle laut Stud.IP sind ausgeblendet wie
//   ueberall in der App), Raum aus dem Vorkommen (Raumaenderungen stehen dort)
// - hoechstens `budget` Mitteilungen auf einmal, die fruehesten zuerst: iOS behaelt nur 64 je App, die Abgaben und
//   Pruefungen (`DueReminders`, sonst bis 60) ruecken dafuer um `budget` zusammen, solange der Schalter an ist
// - neu geplant beim Oeffnen, nach jedem Abgleich (auch im Hintergrund), beim Wechsel in den Hintergrund (eigene
//   Aenderungen im Stundenplan) und beim Wechsel des Containers; Demo und Tests planen nichts
// - Kennungen „de.uniflow.ai.lecture.<Container>.<Termin>.<Zeitpunkt>“, nur diese werden ersetzt oder zurueckgenommen
// - nichts geht an einen Server

/// Planung (rein, ohne iOS; Tests)
enum LectureReminders {
    static let prefix = "de.uniflow.ai.lecture."
    /// hoechstens so viele auf einmal (reicht bei 4-5 Terminen am Tag fuer zwei Tage; der naechste Abgleich plant nach)
    static let budget = 10
    static let leads = [5, 10, 15, 30]
    static let defaultLead = 10

    static func prefix(container: String) -> String { prefix + container + "." }

    /// Erinnerungen aus Wochen von GET /api/timetable/week (ab heute), ohne Ausfaelle laut Stud.IP
    static func plan(weeks: [JSONValue], cancelled: Set<String>, container: String, lead: Int, now: Date,
                     limit: Int = budget) -> [DueReminders.Reminder] {
        var out: [DueReminders.Reminder] = []
        var seen = Set<String>()
        for week in weeks {
            for day in week.list("days") {
                guard let date = day.s("date") else { continue }
                for e in StudIPCancellations.visible(day.list("events"), keys: cancelled) {
                    guard let iv = TerminCountdown.interval(e, date: date) else { continue }
                    let fire = iv.start.addingTimeInterval(TimeInterval(-lead * 60))
                    guard fire > now else { continue }
                    let key = CalendarExportPlan.key(occurrence: e)
                    let id = prefix(container: container) + safe(key) + "." + String(Int(fire.timeIntervalSince1970 / 60))
                    guard seen.insert(id).inserted else { continue }
                    out.append(reminder(e, date: date, id: id, fire: fire, lead: lead))
                }
            }
        }
        return Array(out.sorted { ($0.fireAt, $0.identifier) < ($1.fireAt, $1.identifier) }.prefix(max(0, limit)))
    }

    static func reminder(_ e: JSONValue, date: String, id: String, fire: Date, lead: Int) -> DueReminders.Reminder {
        let raw = (e.s("title") ?? e.s("module_name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = raw.isEmpty ? "Termin" : raw
        let time = [e.s("start"), e.s("end")].compactMap { $0.map(TerminCountdown.clock) }.joined(separator: "–")
        let room = (e.s("room") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = room.isEmpty ? time : "\(time) · \(room)"
        return DueReminders.Reminder(identifier: id, fireAt: fire, title: "In \(TerminCountdown.duration(lead, short: true)): \(title)",
                                     body: body, route: "#/timetable?date=\(date)", itemID: id)
    }

    /// Kennungen ohne Punkte und Leerzeichen (der Schluessel kann Titel enthalten)
    static func safe(_ key: String) -> String {
        String(key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_@|".unicodeScalars.contains($0) ? Character($0) : "_" })
    }

    /// Abgleich mit den geplanten: nur eigene Kennungen
    static func diff(pending: [String], planned: [DueReminders.Reminder]) -> (remove: [String], add: [DueReminders.Reminder]) {
        let keep = Set(planned.map(\.identifier))
        let have = Set(pending)
        return (pending.filter { $0.hasPrefix(prefix) && !keep.contains($0) }, planned.filter { !have.contains($0.identifier) })
    }

    /// Texte der Einstellungen
    static let toggleTitle = "Vor jeder Vorlesung"
    static let leadTitle = "Wie lange vorher"
    static let short = "Kurz vor jedem Termin aus dem Stundenplan eine Mitteilung mit Zeit und Raum."
    static let longText = "Kurz vor jedem Termin, den du besuchst, kommt eine Mitteilung mit Zeit und Raum, z. B. „In 10 Min: Analysis I“. Ausgefallene und nicht besuchte Termine melden sich nicht. Antippen öffnet den Stundenplan an diesem Tag. Geplant wird auf deinem Gerät, nichts geht an einen Server."
}

/// Plant die Erinnerungen vor der Vorlesung (Geraet, fuer den offenen Container)
@MainActor
final class LectureReminderScheduler: ObservableObject {
    static let shared = LectureReminderScheduler()
    static let enabledKey = "uniflow.lecture.reminders"
    static let leadKey = "uniflow.lecture.reminders.lead"

    @Published private(set) var enabled: Bool
    @Published private(set) var lead: Int
    @Published private(set) var scheduled = 0

    let notifier: DueNotifying
    var now: () -> Date = { Date() }
    private let defaults: UserDefaults
    private var running = false
    private var again: (APIClient?, String?, Bool)?

    init(notifier: DueNotifying? = nil, defaults: UserDefaults = .standard) {
        self.notifier = notifier ?? SystemDueNotifier()
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        let l = defaults.integer(forKey: Self.leadKey)
        lead = LectureReminders.leads.contains(l) ? l : LectureReminders.defaultLead
    }

    /// Platz, den die Abgaben und Pruefungen frei lassen (`DueReminderScheduler`)
    nonisolated static func reserved(_ d: UserDefaults = .standard) -> Int {
        d.bool(forKey: enabledKey) ? LectureReminders.budget : 0
    }

    /// Neu planen. `api` nil (kein Container) oder Demo: alles zuruecknehmen
    func refresh(api: APIClient?, container: String?, demo: Bool) async {
        if running { again = (api, container, demo); return }
        running = true
        defer { running = false }
        await plan(api: api, container: container, demo: demo)
        while let (a, c, d) = again {
            again = nil
            await plan(api: a, container: c, demo: d)
        }
    }

    private func plan(api: APIClient?, container: String?, demo: Bool) async {
        guard enabled, !demo, let api, let container, await notifier.status() == .allowed else {
            await withdrawAll()
            return
        }
        let at = now()
        let today = HomeWidgetClock.isoDay(at)
        guard let first = try? await api.value("/api/timetable/week?start=\(today)") else { return }
        var weeks = [first]
        let probe = LectureReminders.plan(weeks: weeks, cancelled: [], container: container, lead: lead, now: at)
        if probe.count < LectureReminders.budget, let next = try? await api.value("/api/timetable/week?start=\(Mensa.addDays(today, 7))") {
            weeks.append(next)
        }
        let cancelled = await StudIPCancelled.keys(api, from: today, to: Mensa.addDays(today, 13))
        let planned = LectureReminders.plan(weeks: weeks, cancelled: cancelled, container: container, lead: lead, now: at)
        let d = LectureReminders.diff(pending: await notifier.pendingIdentifiers(), planned: planned)
        notifier.remove(d.remove)
        for r in d.add { await notifier.schedule(r) }
        scheduled = planned.count
    }

    func withdrawAll() async {
        notifier.remove((await notifier.pendingIdentifiers()).filter { $0.hasPrefix(LectureReminders.prefix) })
        scheduled = 0
    }

    /// Schalter: Einschalten fragt iOS (nur hier); abgelehnt: bleibt aus, Rueckgabe false
    @discardableResult
    func setEnabled(_ on: Bool, api: APIClient?, container: String?, demo: Bool) async -> Bool {
        guard on else {
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            await withdrawAll()
            DueReminderScheduler.shared.schedule(recompute: false)        // Platz fuer Abgaben wieder frei
            return true
        }
        let ok: Bool
        switch await notifier.status() {
        case .allowed: ok = true
        case .notDetermined: ok = await notifier.requestPermission()
        case .denied: ok = false
        }
        enabled = ok
        defaults.set(ok, forKey: Self.enabledKey)
        if ok {
            DueReminderScheduler.shared.schedule(recompute: false)        // Abgaben ruecken zusammen
            await refresh(api: api, container: container, demo: demo)
        }
        return ok
    }

    func setLead(_ minutes: Int, api: APIClient?, container: String?, demo: Bool) async {
        guard LectureReminders.leads.contains(minutes) else { return }
        lead = minutes
        defaults.set(minutes, forKey: Self.leadKey)
        await refresh(api: api, container: container, demo: demo)
    }

    /// aus dem offenen Container
    func refresh(_ containers: ContainerManager) async {
        guard !StudIPSync.isUnderTest() else { return }
        await refresh(api: containers.active?.api, container: containers.active?.layout.identifier.uuidString, demo: containers.demoActive)
    }
}

/// Schalter und Zeit in der Karte „Mitteilungen“
struct LectureReminderRows: View {
    @EnvironmentObject private var containers: ContainerManager
    @ObservedObject private var scheduler = LectureReminderScheduler.shared
    @State private var on = false
    @State private var asking = false
    @State private var hint: String?

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { v in set(v) })) {
            Text(LectureReminders.toggleTitle).ufFont(14.5, 550).foregroundStyle(UF.text)
        }
        .tint(UF.accent)
        .disabled(asking)
        .accessibilityIdentifier("lecture.reminders")
        if on {
            HStack {
                Text(LectureReminders.leadTitle).ufFont(13.6).foregroundStyle(UF.text2)
                Spacer()
                Picker(LectureReminders.leadTitle, selection: Binding(get: { scheduler.lead }, set: { m in
                    Task { await scheduler.setLead(m, api: containers.active?.api, container: containers.active?.layout.identifier.uuidString, demo: containers.demoActive) }
                })) {
                    ForEach(LectureReminders.leads, id: \.self) { m in Text("\(m) Min").tag(m) }
                }
                .pickerStyle(.menu)
                .tint(UF.accentText)
                .accessibilityIdentifier("lecture.reminders.lead")
            }
        }
        SettingsMore(summary: LectureReminders.short, text: LectureReminders.longText, identifier: "lecture.remindersText")
            .padding(.top, 4)
        if let hint {
            Text(hint).ufFont(12.8, 600).foregroundStyle(UF.warn)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityIdentifier("lecture.reminders.hint")
        }
        Color.clear.frame(height: 0).onAppear { on = scheduler.enabled }
    }

    private func set(_ v: Bool) {
        hint = nil
        on = v
        asking = v
        Task {
            let ok = await scheduler.setEnabled(v, api: containers.active?.api, container: containers.active?.layout.identifier.uuidString,
                                                demo: containers.demoActive)
            asking = false
            if v, !ok {
                on = false
                hint = BackgroundSyncCard.deniedText
            }
        }
    }
}
