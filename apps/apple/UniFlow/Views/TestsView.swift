import SwiftUI
import UniFlowCore

/// KI-Tests: Übersicht, Test starten, Fragen beantworten, Ergebnis, Wiederholung.
/// Fragen kommen vom Server (`/api/tests/{id}`): `{nr, type: mc|short|calc, question, options?, points}`;
/// die Lösung ist erst nach der Abgabe sichtbar.
struct TestsView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var data: RemoteData

    init(api: APIClient?) {
        _data = StateObject(wrappedValue: RemoteData(path: "/api/tests", api: api))
    }

    var body: some View {
        NavigationStack {
            RemoteContent(data: data, emptyTitle: "Noch keine Tests", isEmpty: { $0.items.isEmpty }) { v in
                List {
                    let open = v.items.filter { $0["submitted_at"]?.isNull != false }
                    let done = v.items.filter { $0["submitted_at"]?.isNull == false }
                    if !open.isEmpty {
                        Section("Offen") { ForEach(Row.rows(open)) { r in testLink(r) } }
                    }
                    if !done.isEmpty {
                        Section("Abgegeben") { ForEach(Row.rows(done)) { r in testLink(r) } }
                    }
                }
            }
            .navigationTitle("KI-Tests")
            .navigationDestination(for: Int.self) { id in TestRunView(testID: id, api: session.api) }
            .refreshable { await data.load() }
            .task { await data.load() }
        }
    }

    private func testLink(_ r: Row) -> some View {
        NavigationLink(value: r.value.i("id") ?? 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(r.value.s("title") ?? r.value.s("subject") ?? "Test").font(.headline)
                HStack(spacing: 10) {
                    Text(r.value.s("subject") ?? "")
                    Text("\(r.value.i("question_count") ?? 0) Fragen")
                    Text("\(r.value.i("duration_min") ?? 0) min")
                    if let s = r.value.n("score"), let m = r.value.n("max_score"), m > 0 {
                        Text("\(JSONValue.format(s)) / \(JSONValue.format(m)) Punkte").bold()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TestRunView: View {
    let testID: Int
    let api: APIClient?
    @State private var test: JSONValue?
    @State private var answers: [String: String] = [:]
    @State private var result: JSONValue?
    @State private var error: String?
    @State private var busy = false
    @State private var repeatMessage: String?

    var body: some View {
        Group {
            if let test {
                Form {
                    if let r = result ?? submittedFeedback(test) { resultSection(r, test: test) }
                    ForEach(Row.rows(test.list("questions"), key: "nr")) { q in
                        questionSection(q.value, locked: isSubmitted(test))
                    }
                    if !isSubmitted(test) {
                        Section {
                            Button {
                                Task { await submit() }
                            } label: {
                                HStack { Spacer(); if busy { ProgressView() } else { Text("Abgeben und auswerten").bold() }; Spacer() }
                            }
                            .disabled(busy || answers.isEmpty)
                        } footer: { Text("Die KI bewertet die Antworten; das kann bis zu einer Minute dauern.") }
                    }
                }
            } else if let error {
                ContentUnavailableView("Test nicht geladen", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView("Lädt…")
            }
        }
        .navigationTitle(test?.s("title") ?? "Test")
        .task { await load() }
        .alert("Wiederholung", isPresented: Binding(get: { repeatMessage != nil }, set: { if !$0 { repeatMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(repeatMessage ?? "") }
    }

    private func isSubmitted(_ t: JSONValue) -> Bool { t["submitted_at"].map { !$0.isNull } ?? false }

    private func submittedFeedback(_ t: JSONValue) -> JSONValue? {
        guard isSubmitted(t), let f = t["feedback"], !f.isNull else { return nil }
        return f
    }

    private func load() async {
        guard let api else { error = "Nicht verbunden."; return }
        do {
            // Oeffnen startet den Test (Server merkt sich den Beginn)
            let t = try await api.value("/api/tests/\(testID)")
            test = t
            for (k, v) in t["answers"]?.object ?? [:] { if let s = v.string { answers[k] = s } }
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func submit() async {
        guard let api else { return }
        busy = true
        defer { busy = false }
        var a: [String: JSONValue] = [:]
        for (k, v) in answers { a[k] = .string(v) }
        do {
            result = try await api.value("/api/tests/\(testID)/submit", method: "POST", body: .object(["answers": .object(a)]))
            test = try await api.value("/api/tests/\(testID)")       // mit Musterloesungen
        } catch let e {
            error = "Abgabe fehlgeschlagen: \(e.localizedDescription)"
        }
    }

    @ViewBuilder
    private func questionSection(_ q: JSONValue, locked: Bool) -> some View {
        let nr = q.i("nr").map(String.init) ?? "?"
        Section {
            Text(q.s("question") ?? "").fixedSize(horizontal: false, vertical: true)
            if q.s("type") == "mc", !q.list("options").isEmpty {
                Picker("Antwort", selection: Binding(get: { answers[nr] ?? "" }, set: { answers[nr] = $0 })) {
                    Text("–").tag("")
                    ForEach(q.list("options").compactMap { $0.string }, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
                .disabled(locked)
            } else {
                TextField(q.s("type") == "calc" ? "Rechenweg und Ergebnis" : "Antwort", text: Binding(get: { answers[nr] ?? "" }, set: { answers[nr] = $0 }), axis: .vertical)
                    .lineLimit(2...8)
                    .disabled(locked)
            }
            if let a = q.s("answer"), locked {
                Label("Musterlösung: \(a)", systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Frage \(nr) · \(JSONValue.format(q.n("points") ?? 0)) Punkte")
        }
    }

    @ViewBuilder
    private func resultSection(_ r: JSONValue, test: JSONValue) -> some View {
        Section("Ergebnis") {
            let score = r.n("score") ?? test.n("score") ?? 0
            let max = r.n("max") ?? test.n("max_score") ?? 0
            LabeledContent("Punkte", value: "\(JSONValue.format(score)) / \(JSONValue.format(max))")
            if max > 0 { ProgressBar(value: score / max) }
            if let s = r.s("summary") { Text(s) }
            ForEach(Row.rows(r.list("per_question"), key: "nr")) { p in
                VStack(alignment: .leading) {
                    Text("Frage \(p.value.i("nr") ?? 0): \(JSONValue.format(p.value.n("points") ?? 0)) / \(JSONValue.format(p.value.n("max") ?? 0))").font(.caption).bold()
                    Text(p.value.s("feedback") ?? "").font(.caption)
                }
            }
            let weak = r.list("weak_topics").compactMap { $0.string }
            if !weak.isEmpty {
                Text("Nochmal anschauen: \(weak.joined(separator: ", "))").font(.callout)
                Button("Wiederholungstest erzeugen") { Task { await repeatTest(test) } }
            }
        }
    }

    /// Neuer Test zum selben Modul (die KI berücksichtigt den Stoff der Woche; erscheint nach dem Erzeugen in der Liste).
    private func repeatTest(_ t: JSONValue) async {
        guard let api else { return }
        var body: [String: JSONValue] = [:]
        if let m = t.i("module_id") { body["module_id"] = .number(Double(m)) } else if let s = t.s("subject") { body["subject"] = .string(s) }
        do {
            _ = try await api.value("/api/tests/generate", method: "POST", body: .object(body))
            repeatMessage = "Der Wiederholungstest wird im Hintergrund erzeugt und erscheint in ein bis zwei Minuten in der Liste."
        } catch let e {
            repeatMessage = "Nicht gestartet: \(e.localizedDescription)"
        }
    }
}
