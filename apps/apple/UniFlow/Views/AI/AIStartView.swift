import SwiftUI
import UniFlowCore

/// KI-Start (03.11.2026): "Was möchtest du heute lernen?" mit dem Frage-Feld als Mittelpunkt, vier Aktionen (Fragen,
/// Karteikarten, Erklären / PDF analysieren, Wochentest), den letzten drei Antworten und der Kostenzeile. Erreichbar
/// aus "Tests & Wiederholung" und aus der KI-Hilfe im Editor. Kontext ist das gewaehlte Modul bzw. Dokument (Vorgabe:
/// das zuletzt geoeffnete); Fragen gehen an `POST /api/ai/tutor` (die KI des Nutzers, `LocalContext.ai`), nur nach dem
/// Antippen. Ohne verbundene KI steht oben der Weg dorthin, die Aktionen bleiben sichtbar.
struct AIStartView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufChatGPTLink) private var chatgpt
    @Environment(\.ufWindowWidth) private var windowWidth
    @ObservedObject private var recents: AIRecents
    @ObservedObject private var ent: Entitlements
    @State private var modules: [JSONValue] = []
    @State private var files: [JSONValue] = []
    @State private var loaded = false
    @State private var module = 0
    @State private var fileID = ""
    @State private var question = ""
    @State private var busy = false
    @State private var busyLabel = ""
    @State private var error: String?
    @State private var answer: Answer?
    @FocusState private var askFocused: Bool

    /// Eine Antwort im Antwortbereich (frisch oder aus "Zuletzt")
    struct Answer: Equatable {
        var question: String
        var text: String
        var mode: String
        var fileID: String?
        var fileName: String?
    }

    /// `entitlements: nil` = `Entitlements.shared`, `recents: nil` = `AIRecents.shared`
    @MainActor
    init(entitlements: Entitlements? = nil, recents: AIRecents? = nil) {
        _ent = ObservedObject(wrappedValue: entitlements ?? .shared)
        _recents = ObservedObject(wrappedValue: recents ?? .shared)
    }

    /// Dokumente des gewaehlten Moduls, die sich lesen lassen (geladen, mit Seiten), zuletzt geoeffnete zuerst
    static func documents(_ files: [JSONValue], module: Int) -> [JSONValue] {
        files.filter { f in
            (module == 0 || f.i("module_id") == module) && f.s("downloaded_at") != nil && (f.s("kind") ?? "pdf") == "pdf"
        }.sorted { a, b in
            let la = a.s("last_opened") ?? "", lb = b.s("last_opened") ?? ""
            if la != lb { return la > lb }
            return (a.n("chdate") ?? 0) > (b.n("chdate") ?? 0)
        }
    }

    /// Titel eines Dokuments wie in der Bibliothek
    static func title(_ f: JSONValue) -> String { f.s("ai_title") ?? f.s("title") ?? f.s("name") ?? "" }

    private var documents: [JSONValue] { Self.documents(files, module: module) }
    private var currentFile: JSONValue? { documents.first { $0.s("id") == fileID } ?? documents.first }

    var body: some View {
        UFContent(maxWidth: 960) {
            UFPageHead("Was möchtest du heute lernen?", sub: "Frag die KI zu deinen Unterlagen, lass Karteikarten und Wochentests erstellen.") {
                UFButton("Tests", icon: "arrow-left", size: .small) { router.go(.exams) }.accessibilityIdentifier("ai.start.tests")
            }
            if !aiEnabled { connectCard.padding(.bottom, 16) }
            askBox
            actions.padding(.top, 20)
            if let answer { answerCard(answer).padding(.top, 20) }
            if !recents.entries.isEmpty { recentRow.padding(.top, 24) }
        }
        .task(id: session.api.map(ObjectIdentifier.init)) { await load() }
        .ufReload { await load() }
        // anderes Modul: ein Dokument des anderen Moduls passt nicht mehr, das zuletzt geoeffnete des neuen ist dran
        .onChange(of: module) { _, _ in
            if !documents.contains(where: { $0.s("id") == fileID }) { fileID = documents.first?.s("id") ?? "" }
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        if let c = ActiveContainer.current { recents.attachActive(defaults: c.defaults, scope: api.namespace.id) }
        do {
            async let m = api.value("/api/modules")
            async let l = api.value("/api/library")
            let (mv, lv) = try await (m, l)
            modules = mv.items
            files = lv.list("files")
            if fileID.isEmpty, let f = currentFile?.s("id") { fileID = f }
            loaded = true
        } catch { if !loaded { toast.show(error.localizedDescription) } }
    }

    // MARK: Verbinden

    @ViewBuilder private var connectCard: some View {
        UFCard {
            UFCardHead("KI verbinden", icon: "sparkles")
            if let chatgpt {
                TutorConnectState(link: chatgpt) { router.go(.settings(tab: "advanced")) }.padding(-16).padding(.top, 8)
            } else {
                TutorConnectState.Content(reason: .notConnected, message: nil, busy: false, fix: nil) { router.go(.settings(tab: "advanced")) }
                    .padding(-16).padding(.top, 8)
            }
        }
    }

    // MARK: Frag etwas …

    private var askBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Kontext: Modul und Dokument, zu dem die Frage gehoert
            UFFlexWrap(gap: 8, rowGap: 8) {
                UFSelect(options: [(0, "Alle Module")] + modules.compactMap { m in m.i("id").map { ($0, UFFmt.shortName(m.s("name"))) } },
                         selection: $module, small: true)
                    .accessibilityLabel("Modul")
                    .accessibilityIdentifier("ai.start.module")
                UFSelect(options: [("", documents.isEmpty ? "Kein Dokument" : "– Dokument –")]
                         + documents.prefix(40).compactMap { f in f.s("id").map { ($0, Self.title(f)) } },
                         selection: $fileID, small: true)
                    .accessibilityLabel("Dokument")
                    .accessibilityIdentifier("ai.start.file")
                if let f = currentFile, f.s("id") == fileID {
                    UFBadge(f.s("last_opened") != nil ? "zuletzt geöffnet" : "neuestes Dokument", tone: .neutral)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                UFTextArea(placeholder: "Frag etwas … z. B. Erkläre mir den Satz von Bolzano", text: $question, minHeight: 72)
                    .focused($askFocused)
                    .accessibilityIdentifier("ai.start.input")
                UFButton(nil, icon: "arrow-right", kind: .primary) { Task { await ask() } }
                    .disabled(!aiEnabled || busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Frage senden")
                    .accessibilityIdentifier("ai.start.ask")
            }
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                    UFShimmerText(busyLabel.isEmpty ? "Die KI denkt nach …" : busyLabel, size: 12.8)
                } else {
                    Text(statusLine).ufFont(12.8).foregroundStyle(UF.muted).accessibilityIdentifier("ai.start.status")
                }
                Spacer(minLength: 0)
            }
            if let error {
                Text(error).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ai.start.error")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: UF.rLg).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.rLg).strokeBorder(askFocused ? UF.accent : UF.line, lineWidth: 1))
        .ufShadow(.md)
        .animation(UF.transition, value: askFocused)
    }

    private var statusLine: String {
        AICost.status(chatgpt: aiEnabled, model: chatgpt?.status?.model, plan: ent.plan, requestsThisMonth: recents.requestsThisMonth)
    }

    // MARK: Aktionen

    private var actions: some View {
        let grid = windowWidth <= 640 ? UFGridLayout(columns: 1, spacing: 10) : UFGridLayout(columns: 2, spacing: 10)
        return grid {
            AIActionPill(title: "Fragen", sub: "Zur Seite, zur Aufgabe, zum Begriff", icon: "sparkles", pair: CommunityPalette.sky) {
                askFocused = true
            }
            .accessibilityIdentifier("ai.start.pill.ask")
            AIActionPill(title: "Karteikarten", sub: "Aus einem Dokument, zum Durchsehen vor dem Speichern", icon: "cards",
                         pair: CommunityPalette.mint, strong: true) { openFlashcards() }
                .accessibilityIdentifier("ai.start.pill.cards")
            AIActionPill(title: "Erklären / PDF analysieren", sub: "Zusammenfassung des Dokuments, dann weiter im Editor", icon: "book",
                         pair: CommunityPalette.lavender) { Task { await explain() } }
                .accessibilityIdentifier("ai.start.pill.explain")
            AIActionPill(title: "Wochentest", sub: "15 Aufgaben zu einer Lehrwoche, gemeinsam je Modul", icon: "exam",
                         pair: CommunityPalette.peach) { openQuiz() }
                .accessibilityIdentifier("ai.start.pill.quiz")
        }
    }

    private func openFlashcards() {
        overlay.modal(wide: true) {
            FlashcardComposer(moduleID: module, fileID: currentFile?.s("id"), entitlements: ent)
        }
    }

    private func openQuiz() {
        overlay.modal { QuizComposer(moduleID: module != 0 ? module : modules.first?.i("id") ?? 0, entitlements: ent) }
    }

    // MARK: Antwort

    private func answerCard(_ a: Answer) -> some View {
        UFCard {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.question).ufFont(14.5, 650).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    if let name = a.fileName { Text(name).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
                UFButton(nil, icon: "x", kind: .ghost, size: .small) { answer = nil }.accessibilityLabel("Antwort schließen")
            }
            .padding(.bottom, 8)
            AIMarkdownText(a.text).accessibilityIdentifier("ai.start.answer")
            let followUps = AIFollowUps.suggest(after: a.mode).filter { $0.mode != "flashcards" }
            if !followUps.isEmpty || a.fileID != nil {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    ForEach(followUps) { s in
                        UFChip(text: s.label, icon: "sparkles") { Task { await followUp(s, after: a) } }.disabled(busy || !aiEnabled)
                    }
                    if let id = a.fileID {
                        UFChip(text: "Im Dokument mit KI-Hilfe öffnen", icon: "book") {
                            router.tutorOpenRequest = id
                            router.go(.doc(id))
                        }
                        .accessibilityIdentifier("ai.start.openDoc")
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Zuletzt").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
                Spacer()
                UFButton("Leeren", kind: .ghost, size: .small) { recents.clear() }.accessibilityIdentifier("ai.start.recent.clear")
            }
            let grid = windowWidth <= 640 ? UFGridLayout(columns: 1, spacing: 10) : UFGridLayout(columns: 3, spacing: 10)
            grid {
                ForEach(Array(recents.entries.enumerated()), id: \.element.id) { i, e in
                    Button {
                        answer = Answer(question: e.question, text: e.answer, mode: "ask", fileID: e.fileID, fileName: e.fileName)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.question).ufFont(13.6, 650, lh: 1.3).foregroundStyle(UF.text).lineLimit(2)
                            Text(e.answer).ufFont(12.8, lh: 1.35).foregroundStyle(UF.muted).lineLimit(3)
                            if let n = e.fileName { Text(n).ufFont(11.84).foregroundStyle(UF.accentText).lineLimit(1).padding(.top, 2) }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
                        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: UF.r))
                    }
                    .buttonStyle(UFPressStyle())
                    .accessibilityLabel("Zuletzt: \(e.question)")
                    .accessibilityIdentifier("ai.start.recent.\(i)")
                    .ufAppear("ai.start.recent", index: i)
                }
            }
            .environment(\.ufFillsCell, true)
        }
    }

    // MARK: Senden

    private func ask() async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        await send(mode: "ask", question: q, label: q, busyLabel: "Die KI liest deine Unterlagen …")
    }

    private func explain() async {
        guard let f = currentFile else { toast.show("Wähle zuerst ein Dokument."); return }
        guard aiEnabled else { router.go(.settings(tab: "advanced")); return }
        fileID = f.s("id") ?? fileID
        await send(mode: "summary", question: "", label: "Zusammenfassung: \(Self.title(f))", busyLabel: "Die KI liest \(Self.title(f)) …")
    }

    private func followUp(_ s: AIFollowUps.Suggestion, after a: Answer) async {
        if let id = a.fileID, id != fileID { fileID = id }
        let history: JSONValue = .array([["role": "user", "text": .string(a.question)], ["role": "assistant", "text": .string(a.text)]])
        await send(mode: s.mode, question: s.question, label: s.question.isEmpty ? s.label : s.question, busyLabel: "Die KI antwortet …", history: history)
    }

    /// Eine Frage an `POST /api/ai/tutor` mit dem gewaehlten Dokument (Seite 1) als Kontext; die Antwort kommt in den
    /// Antwortbereich und nach "Zuletzt"
    private func send(mode: String, question q: String, label: String, busyLabel: String, history: JSONValue = .array([])) async {
        guard let api = session.api, !busy else { return }
        // Kontext: das gewaehlte Dokument (Seite 1); ohne Dokument geht nur die Frage
        let f = fileID.isEmpty ? nil : currentFile
        var body: [String: JSONValue] = ["mode": .string(mode), "page": 1, "history": history]
        if let id = f?.s("id") { body["file_id"] = .string(id) }
        if !q.isEmpty { body["question"] = .string(q) }
        busy = true
        self.busyLabel = busyLabel
        error = nil
        defer { busy = false }
        do {
            let r = try await api.value("/api/ai/tutor", method: "POST", body: .object(body))
            var text = r.s("answer") ?? ""
            if mode == "flashcards", let cards = r["cards"]?.array, !cards.isEmpty {
                text = cards.map { "- **\($0.s("question") ?? "")** – \($0.s("answer") ?? "")" }.joined(separator: "\n")
            }
            let a = Answer(question: label, text: text, mode: mode, fileID: f?.s("id"), fileName: f.map(Self.title))
            answer = a
            recents.record(question: label, answer: text, fileID: a.fileID, fileName: a.fileName)
            if mode == "ask" { question = "" }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
