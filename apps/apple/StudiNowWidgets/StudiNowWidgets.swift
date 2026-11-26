import SwiftUI
import WidgetKit

// Widgets von StudiNow (Zweig app/widgets, 23.11.2026): "Nächster Termin" (Home-Bildschirm klein/mittel/gross,
// Sperrbildschirm rechteckig/rund/Zeile) und "Mensa heute" (klein/mittel/gross, Sperrbildschirm rechteckig).
// Daten nur aus dem Schnappschuss der App (WidgetShared/HomeWidgetData.swift); das Widget selbst geht nie ins Netz.
// Antippen oeffnet die passende Seite der App ueber die Deep Links uniflow://#/timetable bzw. uniflow://#/mensa.

@main
struct StudiNowWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextEventWidget()
        MensaWidget()
        MessagesWidget()
    }
}

// MARK: - Zeitleisten und Konfiguration

struct NextEventProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextEventEntry { NextEventEntry(date: Date(), data: .sample(now: Date())) }

    func getSnapshot(in context: Context, completion: @escaping (NextEventEntry) -> Void) {
        let now = Date()
        let data = HomeWidgetStore.load()
        completion(NextEventEntry(date: now, data: context.isPreview && (data?.upcoming(at: now).isEmpty ?? true) ? .sample(now: now) : data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEventEntry>) -> Void) {
        let now = Date()
        guard let data = HomeWidgetStore.load() else {
            completion(Timeline(entries: [NextEventEntry(date: now, data: nil)], policy: .after(now.addingTimeInterval(3600))))
            return
        }
        // neuer Eintrag bei jedem Beginn und Ende (der Termin wechselt dann von "als Nächstes" zu "jetzt" bzw. zum
        // naechsten) und um Mitternacht (Tagesnamen); hoechstens 40 Wechsel, danach neu fragen
        let cal = HomeWidgetClock.calendar
        var changes = Set<Date>([now])
        for e in data.upcoming(at: now).prefix(20) {
            if e.start > now { changes.insert(e.start) }
            changes.insert(e.end)
        }
        if let midnight = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            changes.insert(midnight)
        }
        let dates = changes.sorted().prefix(40)
        let entries = dates.map { NextEventEntry(date: $0, data: data) }
        let last = dates.last ?? now
        completion(Timeline(entries: entries, policy: .after(min(max(last, now.addingTimeInterval(900)), data.eventsUntil))))
    }
}

struct NextEventWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HomeWidgetKind.next, provider: NextEventProvider()) { entry in
            NextEventView(entry: entry)
                .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("Nächster Termin")
        .description("Was gerade läuft und was als Nächstes kommt – aus deinem Stundenplan in StudiNow.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct MensaProvider: TimelineProvider {
    func placeholder(in context: Context) -> MensaEntry { MensaEntry(date: Date(), data: .sample(now: Date())) }

    func getSnapshot(in context: Context, completion: @escaping (MensaEntry) -> Void) {
        let now = Date()
        let data = HomeWidgetStore.load()
        completion(MensaEntry(date: now, data: context.isPreview && data?.mensaDay(at: now) == nil ? .sample(now: now) : data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MensaEntry>) -> Void) {
        let now = Date()
        let data = HomeWidgetStore.load()
        // Wechsel um 15 Uhr (dann zeigt das Widget den naechsten Tag) und um Mitternacht
        let cal = HomeWidgetClock.calendar
        var dates = [now]
        for h in [15, 0] {
            if let d = cal.nextDate(after: now, matching: DateComponents(hour: h, minute: 0), matchingPolicy: .nextTime) { dates.append(d) }
        }
        dates.sort()
        completion(Timeline(entries: dates.map { MensaEntry(date: $0, data: data) }, policy: .after(dates.last ?? now.addingTimeInterval(3600))))
    }
}

struct MensaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HomeWidgetKind.mensa, provider: MensaProvider()) { entry in
            MensaWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("Mensa heute")
        .description("Der Speiseplan deiner Mensa mit deinen Filtern und deinem Preis – ab 15 Uhr schon für morgen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}


/// Widget "Nachrichten" (26.11.2026): nur ein Eintrag; neu geladen, wenn die App einen geaenderten Schnappschuss
/// schreibt (nach jedem Abgleich, beim Oeffnen der Nachrichten, nach Uni-Mail)
struct MessagesProvider: TimelineProvider {
    func placeholder(in context: Context) -> MessagesEntry { MessagesEntry(date: Date(), data: .sampleMessages(now: Date())) }

    func getSnapshot(in context: Context, completion: @escaping (MessagesEntry) -> Void) {
        let now = Date()
        let data = HomeWidgetStore.load()
        completion(MessagesEntry(date: now, data: context.isPreview && data?.messages == nil ? .sampleMessages(now: now) : data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MessagesEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [MessagesEntry(date: now, data: HomeWidgetStore.load())], policy: .after(now.addingTimeInterval(6 * 3600))))
    }
}

struct MessagesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HomeWidgetKind.messages, provider: MessagesProvider()) { entry in
            MessagesWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("Nachrichten")
        .description("Wie viele Nachrichten ungelesen sind und von wem – aus Stud.IP und wahlweise Uni-Mail.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}
