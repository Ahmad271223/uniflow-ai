import SwiftUI
import UniFlowCore

/// Lernkalender und Stundenplan: Tag, 3 Tage, Woche. Termine (Stud.IP/Stundenplan), Lernpakete mit Aufgaben,
/// freie Zeitfenster. Daten aus `/api/timetable/week` (Termine, Pakete, freie Zeit) und `/api/calendar` (Aufgaben).
struct CalendarView: View {
    enum Mode: String, CaseIterable, Identifiable { case day = "Tag", three = "3 Tage", week = "Woche"; var id: String { rawValue } }

    let api: APIClient?
    @State private var mode: Mode = .three
    @State private var anchor = Calendar(identifier: .iso8601).startOfDay(for: Date())
    @StateObject private var week: RemoteData
    @StateObject private var plan: RemoteData

    init(api: APIClient?) {
        self.api = api
        let start = CalendarView.monday(of: Date())
        _week = StateObject(wrappedValue: RemoteData(path: CalendarView.weekPath(start), api: api))
        _plan = StateObject(wrappedValue: RemoteData(path: CalendarView.planPath(start), api: api))
    }

    static func monday(of d: Date) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: d)?.start ?? d
    }

    static func weekPath(_ start: Date) -> String { "/api/timetable/week?start=\(Fmt.isoDay(start))" }
    static func planPath(_ start: Date) -> String {
        "/api/calendar?start=\(Fmt.isoDay(start))&end=\(Fmt.isoDay(start.addingTimeInterval(6 * 86_400)))"
    }

    private var visibleDays: [String] {
        let cal = Calendar(identifier: .iso8601)
        let start: Date
        let count: Int
        switch mode {
        case .day: start = anchor; count = 1
        case .three: start = anchor; count = 3
        case .week: start = CalendarView.monday(of: anchor); count = 7
        }
        return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: start) }.map(Fmt.isoDay)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Picker("Ansicht", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(maxWidth: 320)
                    Spacer()
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Zurück")
                    Button("Heute") { anchor = Calendar(identifier: .iso8601).startOfDay(for: Date()); Task { await reload() } }
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Weiter")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                RemoteContent(data: week) { w in
                    ScrollView {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(visibleDays, id: \.self) { day in
                                DayColumn(date: day, timetable: dayJSON(w, day), plan: plan.value.map { dayJSON($0, day) } ?? .null)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(Fmt.day(visibleDays.first, style: "MMMM yyyy"))
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private func dayJSON(_ v: JSONValue, _ day: String) -> JSONValue {
        v.list("days").first { $0.s("date") == day } ?? .null
    }

    private func shift(_ direction: Int) {
        let step = mode == .week ? 7 : (mode == .three ? 3 : 1)
        anchor = Calendar(identifier: .iso8601).date(byAdding: .day, value: direction * step, to: anchor) ?? anchor
        Task { await reload() }
    }

    /// Sieben Tage ab dem ersten sichtbaren Tag laden (deckt Tag, 3 Tage und Woche ab, auch ueber Wochengrenzen).
    private func reload() async {
        guard let first = visibleDays.first.flatMap({ Fmt.date($0) }) else { return }
        await week.reload(path: CalendarView.weekPath(first))
        await plan.reload(path: CalendarView.planPath(first))
    }
}

private struct DayColumn: View {
    let date: String
    let timetable: JSONValue
    let plan: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Fmt.day(date, style: "EEE d.M.")).font(.headline)
                .foregroundStyle(date == Fmt.isoDay(Date()) ? Color.accentColor : .primary)
            ForEach(Row.rows(timetable.list("events"), key: "event_id")) { r in
                entry(color: r.value.s("color"), time: "\(r.value.s("start") ?? "")–\(r.value.s("end") ?? "")",
                      title: r.value.s("title") ?? "", detail: r.value.s("room"), icon: "person.3")
                    .opacity(r.value.s("status") == "skip" ? 0.45 : 1)
            }
            ForEach(Row.rows(plan.list("packages"))) { r in
                VStack(alignment: .leading, spacing: 4) {
                    entry(color: r.value.s("color"), time: [r.value.s("start_time"), r.value.s("end_time")].compactMap { $0 }.joined(separator: "–"),
                          title: r.value.s("title") ?? r.value.s("subject") ?? "", detail: Fmt.minutes(r.value.n("planned_minutes")), icon: "book")
                    ForEach(Row.rows(r.value.list("tasks"))) { t in
                        Label(t.value.s("title") ?? "", systemImage: t.value.s("status") == "erledigt" ? "checkmark.circle.fill" : "circle")
                            .font(.caption).lineLimit(2).padding(.leading, 14)
                    }
                }
            }
            ForEach(Row.rows(timetable.list("free"), key: "start_hm")) { r in
                Text("Frei \(r.value.s("start_hm") ?? "")–\(r.value.s("end_hm") ?? "") · \(Fmt.minutes(r.value.n("minutes")))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(.secondary.opacity(0.4)))
            }
            if timetable.list("events").isEmpty && plan.list("packages").isEmpty {
                Text("Nichts geplant").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func entry(color: String?, time: String, title: String, detail: String?, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: color)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Label(title, systemImage: icon).font(.callout).lineLimit(3)
                if let detail, !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: color).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
