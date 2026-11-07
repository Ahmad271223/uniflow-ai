import SwiftUI
import UniFlowCore

/// "Schon erklärt" in der KI-Hilfe (Dokument-Index, docs/DOKUMENT-INDEX-2026-11-04.md): kennt der Index die offene
/// Seite (eigener Zwischenspeicher oder Bibliothek), stehen ihre Elemente sofort da - 0 Credits. Dazu Verweise auf
/// dieselben Elemente an anderer Stelle des Moduls und auf eigene Notizen derselben Datei (nur lokal). "Neu erklären
/// lassen" baut die Seite mit Bild in voller Aufloesung neu.
struct DocIndexPageCard: View {
    let fileID: String
    let page: () -> Int
    let open: (_ fileID: String, _ page: Int) -> Void

    @EnvironmentObject private var session: Session
    @State private var shownPage = 0
    @State private var view: JSONValue?
    @State private var busy = false
    @State private var error: String?
    @State private var expanded = true

    static let typeLabels: [String: String] = [
        "skizze": "Skizze", "diagramm": "Diagramm", "tabelle": "Tabelle", "formel": "Formel", "definition": "Definition",
        "satz": "Satz", "beispiel": "Beispiel", "aufgabe": "Aufgabe", "text": "Text",
    ]

    /// "Deine Notizen dazu vom 31.10. auf Seite 5"
    static func noteLine(_ n: JSONValue) -> String {
        let label = n.s("label") ?? ""
        let p = n.i("page") ?? 0
        let when = label.isEmpty ? "" : " vom \(label)"
        return n["current"]?.bool == true ? "Deine Notizen auf dieser Seite\(when)" : "Deine Notizen dazu\(when) auf Seite \(p)"
    }

    var body: some View {
        // ein echter Knoten (VStack), auch wenn noch nichts zu zeigen ist: an einer EmptyView in einem VStack liefe `.task`
        // nie an, die Karte fragte den Index nicht einmal (Befund 04.11.2026)
        VStack(alignment: .leading, spacing: 0) { content }
            .task(id: fileID) {
                // die Seite des Editors wechselt ohne Ereignis an die Leiste: kurz nachsehen, solange die Karte lebt
                while !Task.isCancelled {
                    let p = page()
                    if p != shownPage { shownPage = p; await load(page: p) }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
            }
    }

    @ViewBuilder private var content: some View {
        let status = view?.s("status") ?? ""
        if status == "ready", let entry = view?["entry"] {
            ready(entry)
        } else if status == "none" || status == "failed", view?["can_build"]?.bool == true {
            HStack(spacing: 8) {
                UFButton(busy ? "Seite wird eingeordnet …" : "Seite einordnen", icon: busy ? nil : "sparkles", kind: .ghost, size: .small) {
                    Task { await build(force: false) }
                }
                .disabled(busy)
                .accessibilityIdentifier("docIndex.build")
                Text(status == "failed" ? "Letzter Versuch gescheitert" : "Einmal für alle mit dieser Datei")
                    .ufFont(12).foregroundStyle(UF.muted)
            }
            errorLine
        }
    }

    @ViewBuilder private var errorLine: some View {
        if let error {
            Text(error).ufFont(12.5).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("docIndex.error")
        }
    }

    private func ready(_ entry: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    UFIcon("check", size: 14).foregroundStyle(UF.ok)
                    Text("Schon erklärt").ufFont(14, 650).foregroundStyle(UF.text)
                    Text(view?.s("source") == "cloud" ? "aus der Bibliothek · 0 Credits" : "0 Credits").ufFont(12).foregroundStyle(UF.muted)
                    Spacer(minLength: 0)
                    UFIcon("chevron-down", size: 12).rotationEffect(.degrees(expanded ? 180 : 0)).foregroundStyle(UF.muted)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("docIndex.ready")
            if expanded {
                if let summary = entry.s("summary"), !summary.isEmpty {
                    Text(FormulaText.attributed(summary, size: 13.12)).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                }
                // Platz im Regal (Hochschule › Studiengang › Semester › Modul › Woche › Art), aus den Kursdaten des Geraets
                if let path = view?["shelf_path"]?.array?.compactMap(\.string), !path.isEmpty {
                    Text("Im Regal: " + path.joined(separator: " › ")).ufFont(11.5).foregroundStyle(UF.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("docIndex.shelf")
                }
                let refs = view?["cross_refs"]?.array ?? []
                ForEach(Array((entry["elements"]?.array ?? []).enumerated()), id: \.offset) { _, e in
                    element(e, refs: refs.filter { $0.i("order") == e.i("order") })
                }
                let tasks = entry["tasks"]?.array ?? []
                if !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Aufgaben").ufFont(12, 700).foregroundStyle(UF.muted)
                        ForEach(Array(tasks.enumerated()), id: \.offset) { _, t in
                            Text(FormulaText.attributed("\(t.s("label") ?? ""): \(t.s("asks") ?? "")", size: 12.8)).ufFont(12.8).foregroundStyle(UF.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                ForEach(Array((view?["own_notes"]?.array ?? []).enumerated()), id: \.offset) { _, n in
                    Button { open(fileID, n.i("page") ?? shownPage) } label: {
                        Label { Text(Self.noteLine(n)).ufFont(12.8) } icon: { UFIcon("pen", size: 12) }
                            .foregroundStyle(UF.accentText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("docIndex.note")
                }
                if view?["can_build"]?.bool == true {
                    UFButton(busy ? "Wird neu erklärt …" : "Neu erklären lassen", icon: busy ? nil : "refresh", kind: .ghost, size: .small) {
                        Task { await build(force: true) }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("docIndex.rebuild")
                }
                errorLine
            }
        }
        .padding(12)
        .background(UF.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func element(_ e: JSONValue, refs: [JSONValue]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.typeLabels[e.s("type") ?? ""] ?? (e.s("type") ?? "")).ufFont(11.5, 700).foregroundStyle(UF.accentText)
                Text(FormulaText.attributed(e.s("title") ?? "", size: 13.12, weight: 600)).ufFont(13.12, 600).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                if e["uncertain"]?.bool == true { Text("unsicher").ufFont(11).foregroundStyle(UF.muted) }
            }
            if let x = e.s("explanation"), !x.isEmpty {
                Text(FormulaText.attributed(x, size: 12.8)).ufFont(12.8).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(refs.enumerated()), id: \.offset) { _, r in
                Button { open(r.s("file_id") ?? fileID, r.i("page") ?? 1) } label: {
                    Text(r.s("text") ?? "").ufFont(12).foregroundStyle(UF.accentText)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load(page p: Int) async {
        guard let api = session.api, p >= 1 else { return }
        error = nil
        view = try? await api.value("/api/index/file/\(fileID)/page/\(p)?lookup=1")
    }

    private func build(force: Bool) async {
        guard let api = session.api, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            view = try await api.value("/api/index/file/\(fileID)/page/\(shownPage)", method: "POST", body: ["force": .bool(force)])
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
