import Foundation
import UniFlowCore
import SwiftUI
import WidgetKit

/// Schnappschuss fuer die Widgets (WidgetShared/HomeWidgetData.swift) aus der lokalen Datenquelle schreiben: naechste
/// 14 Tage Stundenplan (wie die Wochenansicht, ohne Ausfaelle laut Stud.IP und ohne "nicht besucht") und der Speiseplan
/// von heute und morgen der gewaehlten Mensa mit den Filtern und der Preisgruppe der Mensa-Seite (`MensaPrefs`).
/// Wann: nach jedem Abgleich (`StudIPSync.finishedRuns`), nach dem Hintergrundlauf und beim Wechsel in den Hintergrund.
/// Ohne Container (abgemeldet, Hochschule gewechselt) wird der Schnappschuss geloescht. Demo-Inhalte erscheinen wie
/// echte (erfundene Daten, kein Konto; so sieht auch die App-Pruefung die Widgets); beim Verlassen der Demo neu geschrieben.
@MainActor
enum HomeWidgetSync {
    /// so viele Tage Stundenplan ab heute
    static let days = 14
    /// so viele Gerichte je Tag (das grosse Widget zeigt hoechstens fuenf)
    static let mealsPerDay = 6

    private static var running = false
    private static var again = false

    /// Schnappschuss neu schreiben bzw. loeschen; laeuft schon einer, folgt genau ein weiterer danach
    static func refresh(api: APIClient?, now: Date = Date()) async {
        guard !StudIPSync.isUnderTest() else { return }
        if running { again = true; return }
        running = true
        defer { running = false }
        repeat {
            again = false
            await refreshOnce(api: api, now: now)
        } while again
    }

    private static func refreshOnce(api: APIClient?, now: Date) async {
        guard let api else {
            if HomeWidgetStore.clear() { WidgetCenter.shared.reloadAllTimelines() }
            return
        }
        guard let data = await build(api: api, now: now) else { return }   // Fehler: alten Stand behalten
        if HomeWidgetStore.save(data) { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Schnappschuss aus der Datenquelle; nil, wenn der Stundenplan nicht lesbar war
    static func build(api: APIClient, now: Date, prefs: MensaPrefs = .load()) async -> HomeWidgetData? {
        let today = HomeWidgetClock.isoDay(now)
        let lastDay = Mensa.addDays(today, days - 1)
        var week: [JSONValue] = []
        var start = today
        while start <= lastDay {
            guard let w = try? await api.value("/api/timetable/week?start=\(start)") else { return nil }
            week.append(w)
            start = Mensa.addDays(start, 7)
        }
        let cancelled = await StudIPCancelled.keys(api, from: today, to: lastDay)
        let events = Self.events(weeks: week, cancelled: cancelled, from: today, to: lastDay)
        let until = HomeWidgetClock.date(day: Mensa.addDays(lastDay, 1), time: "00:00") ?? now.addingTimeInterval(Double(days) * 86_400)
        let mensa = await Self.mensa(api: api, today: today, prefs: prefs)
        return HomeWidgetData(createdAt: now, events: events, eventsUntil: until, mensa: mensa)
    }

    /// Termine aus Antworten von GET /api/timetable/week: nur "teilnahme" (Ausfall, verschoben, nicht besucht fallen
    /// weg), ohne Ausfaelle laut Stud.IP, nach Beginn sortiert, doppelte (gleicher Titel, gleiche Zeit) einmal
    static func events(weeks: [JSONValue], cancelled: Set<String>, from: String, to: String) -> [HomeWidgetData.Event] {
        var out: [HomeWidgetData.Event] = []
        var seen = Set<String>()
        for w in weeks {
            for day in w.list("days") {
                guard let date = day.s("date"), date >= from, date <= to else { continue }
                let visible = StudIPCancellations.visible(day.list("events"), keys: cancelled)
                for e in visible where (e.s("status") ?? "teilnahme") == "teilnahme" {
                    guard let s = e.s("start"), let st = HomeWidgetClock.date(day: date, time: s) else { continue }
                    let en = e.s("end").flatMap { HomeWidgetClock.date(day: date, time: $0) }.flatMap { $0 > st ? $0 : nil }
                        ?? st.addingTimeInterval(90 * 60)
                    let title = (e.s("title") ?? e.s("module_name") ?? "Termin").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard seen.insert("\(title)|\(st.timeIntervalSince1970)").inserted else { continue }
                    let room = e.s("room")?.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(.init(title: title.isEmpty ? "Termin" : title, room: room?.isEmpty == false ? room : nil,
                                     start: st, end: en, color: e.s("color"), kind: e.s("kind")))
                }
            }
        }
        return out.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// Speiseplan heute und morgen; nil ohne Mensa (Hochschule ohne Speiseplan) oder bei Fehler
    static func mensa(api: APIClient, today: String, prefs: MensaPrefs) async -> HomeWidgetData.Mensa? {
        guard let list = try? await api.value("/api/mensa/canteens"), !list.list("canteens").isEmpty else { return nil }
        let id = prefs.chosen(in: list)
        guard let menu = try? await api.value("/api/mensa/menu?canteen=\(id)&date=\(today)&days=2") else { return nil }
        let name = list.list("canteens").first { $0.s("id") == id }?.s("name") ?? menu["canteen"]?.s("name") ?? "Mensa"
        return mensa(menu: menu, name: name, prefs: prefs)
    }

    static func mensa(menu: JSONValue, name: String, prefs: MensaPrefs) -> HomeWidgetData.Mensa {
        let days = menu.list("days").compactMap { d -> HomeWidgetData.Day? in
            guard let date = d.s("date") else { return nil }
            let meals = Mensa.sort(Mensa.filter(d.list("meals"), prefs.filter), by: prefs.sort, role: prefs.role)
                .prefix(mealsPerDay)
                .compactMap { m -> HomeWidgetData.Meal? in
                    guard let n = m.s("name")?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
                    let labels = Mensa.labels(m)
                    return .init(name: n, category: m.s("category"), price: Mensa.price(m, role: prefs.role).map { MensaUI.price($0) },
                                 vegan: labels.contains("vegan"), vegetarian: labels.contains("vegetarisch") || labels.contains("vegan"))
                }
            return .init(date: date, status: d.s("status") ?? "unknown", meals: Array(meals))
        }
        return .init(canteen: name, days: days)
    }
}

/// Unsichtbar unter jedem Fenster: schreibt den Widget-Schnappschuss nach jedem Stud.IP-Abgleich (`finishedRuns`),
/// beim Wechsel des Containers (Abmelden, andere Hochschule: `generation`) und beim Ein-/Ausschalten der Demo neu.
/// Mehrere Fenster loesen hoechstens einen weiteren Lauf aus (`HomeWidgetSync.refresh`).
struct HomeWidgetRefresher: View {
    @ObservedObject var containers: ContainerManager
    @ObservedObject var studip: StudIPSync

    private struct Trigger: Equatable {
        let runs: Int
        let generation: Int
        let demo: Bool
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: Trigger(runs: studip.finishedRuns, generation: containers.generation, demo: containers.demoActive), initial: true) { _, _ in
                Task { await HomeWidgetSync.refresh(api: containers.active?.api) }
            }
    }
}
