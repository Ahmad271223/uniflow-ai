import SwiftUI
import WidgetKit
#if UF_WIDGET_VIEWS_IN_TESTS
@testable import UniFlow                     // nur im Testbundle: Datenformat aus der App (WidgetShared)
#endif

// Ansichten der Widgets (Rahmen, Zeitleisten und Konfiguration: StudiNowWidgets.swift). Auch in den App-Tests
// eingebunden (project.yml, UniFlowTests): WidgetSnapshotAppTests zeichnet jede Groesse mit Beispieldaten als Bild.

// MARK: - Farben und Formate

enum WUI {
    static let accent = Color(wLight: 0x4f5bd5, wDark: 0x7b86f0)
    static let muted = Color(wLight: 0x666c84, wDark: 0x8a92a8)
    static let veg = Color(wLight: 0x2f8a4b, wDark: 0x5cc27a)

    static func color(_ hex: String?) -> Color {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return accent }
        h.removeFirst()
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return accent }
        return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = HomeWidgetClock.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func range(_ e: HomeWidgetData.Event) -> String { "\(time(e.start))–\(time(e.end))" }

    /// "Heute", "Morgen", "Mi., 26. Nov."
    static func dayLabel(_ d: Date, now: Date) -> String {
        let c = HomeWidgetClock.calendar
        if c.isDate(d, inSameDayAs: now) { return "Heute" }
        if let t = c.date(byAdding: .day, value: 1, to: now), c.isDate(d, inSameDayAs: t) { return "Morgen" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = HomeWidgetClock.timeZone
        f.dateFormat = "EE, d. MMM"
        return f.string(from: d)
    }

    static func isoDayLabel(_ iso: String, now: Date) -> String {
        HomeWidgetClock.date(day: iso, time: "12:00").map { dayLabel($0, now: now) } ?? iso
    }

    static func timetableURL(_ e: HomeWidgetData.Event?) -> URL? {
        URL(string: "uniflow://#/timetable" + (e.map { "?date=\(HomeWidgetClock.isoDay($0.start))" } ?? ""))
    }

    static let mensaURL = URL(string: "uniflow://#/mensa")
}

extension Color {
    /// eigener Name: die App hat `Color(light:dark:)` (UFTheme), die Testbilder binden beide ein
    init(wLight light: UInt32, wDark dark: UInt32) {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

/// Hinweis ohne Daten (App nie geoeffnet, abgemeldet, Build ohne App-Gruppe)
struct WidgetEmpty: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.title3).foregroundStyle(WUI.accent).widgetAccentable()
            Spacer(minLength: 0)
            Text(title).font(.headline).lineLimit(2)
            Text(text).font(.caption).foregroundStyle(WUI.muted).lineLimit(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Nächster Termin

struct NextEventEntry: TimelineEntry {
    let date: Date
    let data: HomeWidgetData?
}

struct NextEventView: View {
    let entry: NextEventEntry
    /// nur fuer die Testbilder (WidgetSnapshotAppTests); im Widget gilt die Familie aus der Umgebung
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { familyOverride ?? envFamily }

    private var upcoming: [HomeWidgetData.Event] { entry.data?.upcoming(at: entry.date) ?? [] }

    var body: some View {
        Group {
            if entry.data == nil {
                empty(title: "StudiNow öffnen", text: "Nach dem Abgleich mit Stud.IP steht hier dein nächster Termin.")
            } else if upcoming.isEmpty {
                empty(title: "Keine Termine", text: "In den nächsten 14 Tagen steht nichts im Stundenplan.")
            } else {
                content
            }
        }
        .widgetURL(WUI.timetableURL(upcoming.first))
    }

    @ViewBuilder private func empty(title: String, text: String) -> some View {
        switch family {
        case .accessoryInline: Text(title)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "calendar").font(.title3)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text(title).font(.headline).widgetAccentable()
                Text(text).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default: WidgetEmpty(icon: "calendar", title: title, text: text)
        }
    }

    @ViewBuilder private var content: some View {
        let first = upcoming[0]
        switch family {
        case .accessoryInline:
            Text("\(WUI.time(first.start)) \(first.title)")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if first.start <= entry.date {
                    Gauge(value: progress(first)) { Text("") } currentValueLabel: { Text(WUI.time(first.end)).font(.system(size: 12, weight: .semibold)) }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .widgetAccentable()
                } else {
                    VStack(spacing: 0) {
                        Image(systemName: "graduationcap.fill").font(.system(size: 11)).widgetAccentable()
                        Text(WUI.time(first.start)).font(.system(size: 14, weight: .semibold)).minimumScaleFactor(0.7)
                    }
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Text([WUI.time(first.start), first.room].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).widgetAccentable()
                Text(first.title).font(.headline).lineLimit(1)
                when(first).font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                main(first)
                if upcoming.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Danach").font(.caption2.weight(.semibold)).foregroundStyle(WUI.muted).textCase(.uppercase)
                        ForEach(Array(upcoming.dropFirst().prefix(3)), id: \.self) { row($0, showDay: true) }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .systemLarge:
            large
        default:
            main(first)
        }
    }

    /// Hauptkarte: JETZT bzw. ALS NÄCHSTES, Titel, Zeit, Raum, Restzeit
    private func main(_ e: HomeWidgetData.Event) -> some View {
        let running = e.start <= entry.date
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(WUI.color(e.color)).frame(width: 4).widgetAccentable()
            VStack(alignment: .leading, spacing: 3) {
                Text(running ? "Jetzt" : (HomeWidgetClock.calendar.isDate(e.start, inSameDayAs: entry.date) ? "Als Nächstes" : WUI.dayLabel(e.start, now: entry.date)))
                    .font(.caption2.weight(.bold)).foregroundStyle(WUI.color(e.color)).textCase(.uppercase)
                Text(e.title).font(.headline).lineLimit(3).minimumScaleFactor(0.85)
                Text(WUI.range(e)).font(.subheadline).foregroundStyle(.secondary)
                if let r = e.room { Text(r).font(.caption).foregroundStyle(WUI.muted).lineLimit(1) }
                Spacer(minLength: 0)
                if running {
                    ProgressView(timerInterval: e.start...e.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .tint(WUI.color(e.color))
                } else {
                    when(e).font(.caption.weight(.medium)).foregroundStyle(WUI.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "in 25 Min." (zaehlt selbst herunter) bzw. "noch 40 Min."; weiter weg die Uhrzeit mit Tag
    private func when(_ e: HomeWidgetData.Event) -> Text {
        if e.start <= entry.date { return Text("noch ") + Text(e.end, style: .relative) }
        if e.start.timeIntervalSince(entry.date) < 3 * 3600 { return Text("in ") + Text(e.start, style: .relative) }
        return Text("\(WUI.dayLabel(e.start, now: entry.date)), \(WUI.time(e.start))")
    }

    private func progress(_ e: HomeWidgetData.Event) -> Double {
        let total = e.end.timeIntervalSince(e.start)
        return total > 0 ? min(1, max(0, entry.date.timeIntervalSince(e.start) / total)) : 0
    }

    private func row(_ e: HomeWidgetData.Event, showDay: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(WUI.color(e.color)).frame(width: 6, height: 6).widgetAccentable()
            VStack(alignment: .leading, spacing: 0) {
                Text(e.title).font(.caption.weight(.semibold)).lineLimit(1)
                let sameDay = HomeWidgetClock.calendar.isDate(e.start, inSameDayAs: entry.date)
                Text(showDay && !sameDay ? "\(WUI.dayLabel(e.start, now: entry.date)), \(WUI.time(e.start))" : WUI.range(e))
                    .font(.caption2).foregroundStyle(WUI.muted).lineLimit(1)
            }
        }
    }

    /// Gross: naechster Termin oben, darunter die folgenden nach Tagen gruppiert
    private var large: some View {
        let rest = Array(upcoming.dropFirst().prefix(7))
        let groups = Dictionary(grouping: rest) { HomeWidgetClock.isoDay($0.start) }.sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: 10) {
            main(upcoming[0]).frame(maxHeight: 130)
            if !rest.isEmpty { Divider() }
            ForEach(groups, id: \.key) { day, evs in
                VStack(alignment: .leading, spacing: 4) {
                    Text(WUI.isoDayLabel(day, now: entry.date)).font(.caption2.weight(.semibold)).foregroundStyle(WUI.muted).textCase(.uppercase)
                    ForEach(evs, id: \.self) { e in
                        HStack(spacing: 8) {
                            Text(WUI.time(e.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                            RoundedRectangle(cornerRadius: 1.5).fill(WUI.color(e.color)).frame(width: 3, height: 14).widgetAccentable()
                            Text(e.title).font(.caption.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            if let r = e.room { Text(r).font(.caption2).foregroundStyle(WUI.muted).lineLimit(1) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Mensa heute

struct MensaEntry: TimelineEntry {
    let date: Date
    let data: HomeWidgetData?
}

struct MensaWidgetView: View {
    let entry: MensaEntry
    /// nur fuer die Testbilder (WidgetSnapshotAppTests); im Widget gilt die Familie aus der Umgebung
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { familyOverride ?? envFamily }

    var body: some View {
        Group {
            if entry.data == nil {
                empty("StudiNow öffnen", "Wähle in der App deine Mensa, dann steht hier der Speiseplan.")
            } else if entry.data?.mensa == nil {
                empty("Kein Speiseplan", "Für deine Hochschule gibt es in StudiNow keinen Speiseplan.")
            } else if let (day, isToday) = entry.data?.mensaDay(at: entry.date) {
                if day.status != "open" || day.meals.isEmpty {
                    empty(isToday ? "Heute geschlossen" : "\(WUI.isoDayLabel(day.date, now: entry.date)) geschlossen",
                          day.status == "open" ? "Für deine Filter gibt es kein Gericht." : (entry.data?.mensa?.canteen ?? "Mensa"))
                } else {
                    content(day, isToday: isToday)
                }
            } else {
                empty("Kein Speiseplan", "Für heute liegt noch kein Plan vor. Öffne die Mensa in StudiNow.")
            }
        }
        .widgetURL(WUI.mensaURL)
    }

    @ViewBuilder private func empty(_ title: String, _ text: String) -> some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading) {
                Text(title).font(.headline).widgetAccentable()
                Text(text).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            WidgetEmpty(icon: "fork.knife", title: title, text: text)
        }
    }

    @ViewBuilder private func content(_ day: HomeWidgetData.Day, isToday: Bool) -> some View {
        let canteen = entry.data?.mensa?.canteen ?? "Mensa"
        let label = isToday ? "Heute" : WUI.isoDayLabel(day.date, now: entry.date)
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Label(label, systemImage: "fork.knife").font(.caption).widgetAccentable()
                ForEach(day.meals.prefix(2), id: \.self) { Text($0.name).font(.caption).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemSmall:
            VStack(alignment: .leading, spacing: 5) {
                header(canteen, label)
                ForEach(day.meals.prefix(3), id: \.self) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        dot(m)
                        Text(m.name).font(.caption.weight(.medium)).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            let n = family == .systemLarge ? 6 : 3
            VStack(alignment: .leading, spacing: family == .systemLarge ? 9 : 6) {
                header(canteen, label)
                ForEach(day.meals.prefix(n), id: \.self) { m in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        dot(m)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).font(.caption.weight(.semibold)).lineLimit(family == .systemLarge ? 2 : 1)
                            if family == .systemLarge, let c = m.category, !c.isEmpty {
                                Text(c).font(.caption2).foregroundStyle(WUI.muted).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        if let p = m.price { Text(p).font(.caption.monospacedDigit().weight(.semibold)) }
                    }
                }
                if day.meals.count > n {
                    Text("+ \(day.meals.count - n) weitere").font(.caption2).foregroundStyle(WUI.muted)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func header(_ canteen: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "fork.knife").font(.caption.weight(.semibold)).foregroundStyle(WUI.accent).widgetAccentable()
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(WUI.accent).textCase(.uppercase)
            Text(canteen).font(.caption2).foregroundStyle(WUI.muted).lineLimit(1)
        }
    }

    /// gruen fuer vegan/vegetarisch, sonst grau
    private func dot(_ m: HomeWidgetData.Meal) -> some View {
        Circle().fill(m.vegetarian ? WUI.veg : WUI.muted.opacity(0.5)).frame(width: 6, height: 6)
            .accessibilityLabel(m.vegan ? "vegan" : m.vegetarian ? "vegetarisch" : "")
    }
}

// MARK: - Beispiel (Widget-Galerie, bevor die App Daten geschrieben hat)

extension HomeWidgetData {
    static func sample(now: Date) -> HomeWidgetData {
        let cal = HomeWidgetClock.calendar
        let base = cal.date(bySetting: .minute, value: 0, of: now) ?? now
        func at(_ h: Double) -> Date { base.addingTimeInterval(h * 3600) }
        let today = HomeWidgetClock.isoDay(now)
        return HomeWidgetData(
            createdAt: now,
            events: [
                .init(title: "Analysis I", room: "F 102", start: at(0.25), end: at(1.75), color: "#4f5bd5", kind: "vorlesung"),
                .init(title: "Lineare Algebra – Übung", room: "B 305", start: at(2.25), end: at(3.75), color: "#d9822b", kind: "uebung"),
                .init(title: "Programmieren", room: "Audimax", start: at(24.25), end: at(25.75), color: "#2f8a4b", kind: "vorlesung"),
            ],
            eventsUntil: now.addingTimeInterval(14 * 86_400),
            mensa: .init(canteen: "Hauptmensa", days: [
                .init(date: today, status: "open", meals: [
                    .init(name: "Gemüsecurry mit Basmatireis", category: "Vegan", price: "2,90 €", vegan: true, vegetarian: true),
                    .init(name: "Hähnchenschnitzel mit Pommes", category: "Klassiker", price: "3,60 €", vegan: false, vegetarian: false),
                    .init(name: "Pasta Arrabbiata", category: "Pasta", price: "2,40 €", vegan: true, vegetarian: true),
                ]),
            ]))
    }
}
