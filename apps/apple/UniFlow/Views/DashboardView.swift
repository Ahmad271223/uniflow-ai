import SwiftUI
import UniFlowCore

/// Übersicht: Tag, Lernfortschritt, anstehende Termine, offene Aufgaben, neue Dateien.
struct DashboardView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var data: RemoteData
    @StateObject private var tasks: RemoteData

    init(api: APIClient?) {
        _data = StateObject(wrappedValue: RemoteData(path: "/api/dashboard", api: api))
        _tasks = StateObject(wrappedValue: RemoteData(path: "/api/tasks/open", api: api))
    }

    var body: some View {
        NavigationStack {
            RemoteContent(data: data) { d in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                        todayCard(d["today"] ?? .null, name: d["settings"]?.s("user_name"))
                        weekCard(d["week"] ?? .null, backlog: d.i("backlog") ?? 0)
                        upcomingCard(d.list("upcoming"))
                        openTasksCard(tasks.value?.items ?? [])
                        modulesCard(d.list("modules"))
                        newFilesCard(d.list("new_files"), total: d.i("new_total") ?? 0)
                    }
                    .padding(16)
                    if let sync = d["last_sync"], let at = sync.s("finished_at") ?? sync.s("started_at") {
                        Text("Letzter Stud.IP-Abgleich: \(Fmt.day(at, style: "d.M. HH:mm")) – \(sync.s("message") ?? "")")
                            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 16)
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Übersicht")
            .refreshable { await reload() }
            .task { await reload() }
        }
    }

    private func reload() async {
        async let a: Void = data.load()
        async let b: Void = tasks.load()
        _ = await (a, b)
    }

    private func todayCard(_ t: JSONValue, name: String?) -> some View {
        Card(title: name.map { $0.isEmpty ? "Heute" : "Hallo \($0)" } ?? "Heute", systemImage: "sun.max") {
            Text(Fmt.day(t.s("date"))).font(.subheadline).foregroundStyle(.secondary)
            let total = t.n("tasks_total") ?? 0, done = t.n("tasks_done") ?? 0
            ProgressBar(value: total > 0 ? done / total : 0)
            Text("\(Int(done)) von \(Int(total)) Aufgaben · geplant \(Fmt.minutes(t.n("minutes")))").font(.caption)
            ForEach(Row.rows(t.list("events"), key: "event_id")) { r in
                HStack {
                    ModuleDot(hex: r.value.s("color"))
                    Text("\(r.value.s("start") ?? "") \(r.value.s("title") ?? "")").lineLimit(1)
                    Spacer()
                    Text(r.value.s("room") ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            if t.list("events").isEmpty && t.list("packages").isEmpty {
                Text("Heute ist nichts geplant.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func weekCard(_ w: JSONValue, backlog: Int) -> some View {
        Card(title: "Lernfortschritt der Woche", systemImage: "chart.bar") {
            let total = w.n("total") ?? 0, done = w.n("done") ?? 0
            ProgressBar(value: total > 0 ? done / total : 0)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Row.rows(w.list("days"), key: "date")) { r in
                    let m = r.value.n("minutes") ?? 0
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4).fill(statusColor(r.value.s("status")))
                            .frame(width: 22, height: max(6, min(80, m / 3)))
                        Text(Fmt.day(r.value.s("date"), style: "EE")).font(.caption2)
                    }
                }
            }
            if backlog > 0 { Label("\(backlog) Aufgabe(n) nachzuholen", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
        }
    }

    private func upcomingCard(_ list: [JSONValue]) -> some View {
        Card(title: "Anstehend", systemImage: "calendar") {
            if list.isEmpty { Text("Keine anstehenden Termine.").foregroundStyle(.secondary) }
            ForEach(Row.rows(Array(list.prefix(6)), key: "title")) { r in
                HStack {
                    ModuleDot(hex: r.value.s("color"))
                    VStack(alignment: .leading) {
                        Text(r.value.s("title") ?? "").lineLimit(1)
                        Text(Fmt.day(r.value.s("date"), style: "EEE d.M.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func openTasksCard(_ list: [JSONValue]) -> some View {
        Card(title: "Offene Aufgaben", systemImage: "checklist") {
            if list.isEmpty { Text("Alles erledigt.").foregroundStyle(.secondary) }
            ForEach(Row.rows(Array(list.prefix(8)))) { r in
                HStack(alignment: .top) {
                    ModuleDot(hex: r.value.s("color")).padding(.top, 5)
                    VStack(alignment: .leading) {
                        Text(r.value.s("title") ?? "").lineLimit(2)
                        Text("\(r.value.s("subject") ?? "") · \(Fmt.day(r.value.s("date"), style: "EEE d.M.")) · \(Fmt.minutes(r.value.n("est_minutes")))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func modulesCard(_ list: [JSONValue]) -> some View {
        Card(title: "Module", systemImage: "books.vertical") {
            ForEach(Row.rows(list)) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        ModuleDot(hex: r.value.s("color"))
                        Text(r.value.s("name") ?? "").lineLimit(1)
                        Spacer()
                        if let n = r.value.i("new_count"), n > 0 { Text("\(n) neu").font(.caption).foregroundStyle(Color.accentColor) }
                    }
                    ProgressBar(value: r.value.n("progress") ?? 0, color: Color(hex: r.value.s("color")))
                }
            }
        }
    }

    private func newFilesCard(_ list: [JSONValue], total: Int) -> some View {
        Card(title: "Neue Dateien (\(total))", systemImage: "doc.badge.plus") {
            if list.isEmpty { Text("Keine neuen Dateien.").foregroundStyle(.secondary) }
            ForEach(Row.rows(Array(list.prefix(6)))) { r in
                VStack(alignment: .leading) {
                    Text(r.value.s("ai_title") ?? r.value.s("name") ?? "").lineLimit(1)
                    Text(r.value.s("subject") ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusColor(_ s: String?) -> Color {
        switch s {
        case "done": return .green
        case "partial": return .orange
        case "missed": return .red
        default: return .accentColor.opacity(0.35)
        }
    }
}
