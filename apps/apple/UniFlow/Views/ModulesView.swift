import SwiftUI
import UniFlowCore

/// Modulliste mit Fortschritt, Suche und Detailansicht (Lehrwochen mit Vorlesungen, Übungen, Lösungen, Skripten).
struct ModulesView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var data: RemoteData
    @State private var query = ""

    init(api: APIClient?) {
        _data = StateObject(wrappedValue: RemoteData(path: "/api/modules", api: api))
    }

    var body: some View {
        NavigationStack {
            RemoteContent(data: data, emptyTitle: "Noch keine Module", isEmpty: { $0.items.isEmpty }) { v in
                List(filtered(v.items)) { r in
                    NavigationLink(value: r.id) { moduleRow(r.value) }
                }
                .searchable(text: $query, prompt: "Module suchen")
            }
            .navigationTitle("Module")
            .navigationDestination(for: String.self) { id in ModuleDetailView(moduleID: id, api: session.api) }
            .refreshable { await data.load() }
            .task { await data.load() }
        }
    }

    private func filtered(_ list: [JSONValue]) -> [Row] {
        let q = query.lowercased()
        let rows = Row.rows(list)
        guard !q.isEmpty else { return rows }
        return rows.filter { (($0.value.s("name") ?? "") + " " + $0.value.list("topics").compactMap { $0.string }.joined(separator: " ")).lowercased().contains(q) }
    }

    private func moduleRow(_ m: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ModuleDot(hex: m.s("color"))
                Text(m.s("name") ?? "").font(.headline)
                Spacer()
                if let n = m.i("new_count"), n > 0 { Text("\(n) neu").font(.caption).padding(4).background(.tint.opacity(0.15), in: Capsule()) }
            }
            ProgressBar(value: m.n("progress") ?? 0, color: Color(hex: m.s("color")))
            HStack(spacing: 12) {
                Label("\(m.i("file_count") ?? 0)", systemImage: "doc")
                Label("\(m.i("open_tasks") ?? 0)", systemImage: "checklist")
                Label("\(m.i("test_count") ?? 0)", systemImage: "graduationcap")
                if let e = m["next_event"], let t = e.s("title") {
                    Text("Nächster Termin: \(Fmt.day(e.s("date"), style: "EEE d.M.")) \(e.s("start") ?? "") \(t)").lineLimit(1)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ModuleDetailView: View {
    @StateObject private var data: RemoteData
    @EnvironmentObject private var session: Session
    @State private var openFile: LibFile?

    init(moduleID: String, api: APIClient?) {
        _data = StateObject(wrappedValue: RemoteData(path: "/api/modules/\(moduleID)", api: api))
    }

    private struct FileGroup: Identifiable { let id: String; let title: String }
    private let groups = [
        FileGroup(id: "vorlesungen", title: "Vorlesungen"), FileGroup(id: "uebungen", title: "Übungen"),
        FileGroup(id: "loesungen", title: "Lösungen"), FileGroup(id: "skripte", title: "Skripte"),
        FileGroup(id: "klausuren", title: "Klausuren"), FileGroup(id: "sonstiges", title: "Sonstiges"),
    ]

    var body: some View {
        RemoteContent(data: data) { d in
            List {
                Section {
                    ProgressBar(value: d.n("progress") ?? 0, color: Color(hex: d["module"]?.s("color")))
                    if let p = d["next_package"], let t = p.s("title") {
                        LabeledContent("Nächstes Lernpaket", value: "\(Fmt.day(p.s("date"), style: "EEE d.M.")) · \(t)")
                    }
                    LabeledContent("Offene Aufgaben", value: "\(d.i("open_tasks") ?? 0)")
                }
                ForEach(Row.rows(d.list("weeks"), key: "week")) { w in
                    Section {
                        ForEach(groups) { g in
                            let files = w.value.list(g.id)
                            if !files.isEmpty {
                                Text(g.title).font(.caption).foregroundStyle(.secondary)
                                ForEach(Row.rows(files)) { f in fileRow(f.value) }
                            }
                        }
                    } header: {
                        Text([w.value.s("label"), w.value.s("topic")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                }
            }
        }
        .navigationTitle(data.value?["module"]?.s("name") ?? "Modul")
        .refreshable { await data.load() }
        .task { await data.load() }
        .sheet(item: $openFile) { f in
            if let api = session.api {
                NavigationStack {
                    DocumentView(file: f, api: api)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { openFile = nil } } }
                }
            }
        }
    }

    private func fileRow(_ f: JSONValue) -> some View {
        Button {
            openFile = LibFile(json: f)
        } label: {
            HStack {
                Image(systemName: f.n("has_notes").map { $0 > 0 } == true ? "pencil.and.outline" : "doc.richtext")
                VStack(alignment: .leading) {
                    Text(f.s("ai_title") ?? f.s("name") ?? "").lineLimit(2)
                    Text([f.s("sub_label"), f.s("status")].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!(f.s("name") ?? "").lowercased().hasSuffix(".pdf"))
    }
}

extension LibFile {
    /// Aus einer Zeile von `/api/modules/{id}` (gleiche Felder wie die Bibliothek).
    init(json f: JSONValue) {
        self.init(id: f.s("id") ?? "", name: f.s("name") ?? "", title: f.s("title"), kind: f.s("kind"), module_id: f.i("module_id"),
                  subject: f.s("subject"), doc_type: f.s("doc_type"), ai_title: f.s("ai_title"), sub_label: f.s("sub_label"),
                  downloaded_at: f.s("downloaded_at") ?? "unbekannt", has_notes: f.i("has_notes"), page_count: f.i("page_count"),
                  studip_folder: f.s("studip_folder"))
    }
}
