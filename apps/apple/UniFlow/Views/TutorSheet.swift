import SwiftUI
import UniFlowCore

/// KI im Editor wie die Seitenleiste "KI" der Web-App (`POST /api/ai/tutor`): Modi wie `ai.TUTOR_MODES`, eigene Frage,
/// eigene Lösung zum Prüfen; Antwort mit Quellen aus den eigenen Unterlagen ([n] → Seite). Läuft über das
/// ChatGPT-Abo des Nutzers (lokales Backend, `LocalContext.ai`); gesendet wird nur nach dem Antippen.
struct TutorSheet: View {
    let fileID: String
    /// Seite der PDF (1 = erste), wie `page_texts`
    let page: Int
    /// Sprung zu einer Seite dieses Dokuments (1 = erste); Quellen aus anderen Dokumenten stehen als Text da
    let open: (_ fileID: String, _ page: Int) -> Void
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    static let modes: [(key: String, label: String)] = [
        ("explain", "Erklären"), ("explain_simple", "Einfach erklären"), ("summary", "Zusammenfassen"), ("steps", "Schritt für Schritt"),
        ("hints", "Nur Hinweise"), ("check", "Lösung prüfen"), ("similar", "Ähnliche Aufgabe"), ("terms", "Fachbegriffe"),
        ("flashcards", "Karteikarten"),
    ]

    @State private var mode = "explain"
    @State private var question = ""
    @State private var solution = ""
    @State private var busy = false
    @State private var answer: String?
    @State private var cards: [JSONValue] = []
    @State private var sources: [JSONValue] = []
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Seite \(page) · über dein ChatGPT").ufFont(12.8).foregroundStyle(UF.muted)
                    UFFlexWrap(gap: 6.4) {
                        ForEach(Self.modes, id: \.key) { m in
                            UFChip(text: m.label, on: mode == m.key) { mode = m.key }
                                .accessibilityIdentifier("tutor.mode.\(m.key)")
                        }
                    }
                    if mode == "check" {
                        UFField("Meine Lösung") { UFTextArea(placeholder: "Deinen Rechenweg oder deine Antwort eintragen", text: $solution) }
                    }
                    UFField("Meine Frage (optional)") { UFTextInput("z. B. Warum gilt hier das Quotientenkriterium?", text: $question) }
                    UFButton(busy ? "Die KI liest die Seite …" : "Fragen", icon: "sparkles", kind: .primary) { Task { await ask() } }
                        .disabled(busy || (mode == "check" && solution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("tutor.ask")
                    if let error {
                        Text(error).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("tutor.error")
                    }
                    if let answer { result(answer) }
                }
                .padding(20)
            }
            .navigationTitle("KI")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
        }
    }

    @ViewBuilder private func result(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == "flashcards", !cards.isEmpty {
                ForEach(cards.indices, id: \.self) { i in
                    UFCard {
                        Text(cards[i].s("question") ?? "").ufFont(14.5, 650).foregroundStyle(UF.text)
                        Text(cards[i].s("answer") ?? "").ufFont(13.76).foregroundStyle(UF.text2)
                    }
                }
                UFButton(saved ? "In Karteikarten gespeichert" : "Als Karteikarten speichern", icon: "cards", size: .small) {
                    Task { await saveCards() }
                }
                .disabled(saved)
            } else {
                Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                    .ufFont(14.5).foregroundStyle(UF.text).textSelection(.enabled)
                    .accessibilityIdentifier("tutor.answer")
            }
            let cited = sources.filter { $0["cited"]?.bool == true }
            if !cited.isEmpty {
                Text("Quellen").ufFont(12.8, 700).foregroundStyle(UF.muted).padding(.top, 4)
                ForEach(cited.indices, id: \.self) { i in
                    let s = cited[i]
                    let p = Int(s["page"]?.double ?? 1)
                    let label = "[\(Int(s["n"]?.double ?? 0))] \(s.s("title") ?? s.s("name") ?? ""), Seite \(p)"
                    if (s.s("file_id") ?? fileID) == fileID {
                        Button { open(fileID, p); dismiss() } label: { Text(label).ufFont(13.12).foregroundStyle(UF.accentText) }
                            .buttonStyle(.plain)
                    } else {
                        Text(label).ufFont(13.12).foregroundStyle(UF.text2)
                    }
                }
            }
        }
    }

    private func ask() async {
        guard let api = session.api else { return }
        busy = true
        error = nil
        saved = false
        defer { busy = false }
        do {
            var body: [String: JSONValue] = ["file_id": .string(fileID), "page": .number(Double(page)), "mode": .string(mode)]
            if !question.isEmpty { body["question"] = .string(question) }
            if mode == "check" { body["own_solution"] = .string(solution) }
            let r = try await api.value("/api/ai/tutor", method: "POST", body: .object(body))
            answer = r.s("answer") ?? ""
            cards = r["cards"]?.array ?? []
            sources = r["sources"]?.array ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveCards() async {
        guard let api = session.api, !cards.isEmpty else { return }
        do {
            _ = try await api.value("/api/flashcards", method: "POST", body: ["file_id": .string(fileID), "cards": .array(cards)])
            saved = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
