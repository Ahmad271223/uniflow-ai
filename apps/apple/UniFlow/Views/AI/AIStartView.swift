import SwiftUI
import UniFlowCore

/// KI-Start (03.11.2026, Feinschliff 04.11.2026): Logo und die eine Frage "Was möchtest du heute lernen?" in der
/// Mitte, darunter die Aktionen als umrandete Pillen in ihren Farben (Fragen, Karteikarten, Erklären / PDF
/// analysieren, Wochentest, Hilfe) direkt ueber dem Frage-Feld, das der Mittelpunkt der Seite ist; dann die Antwort
/// bzw. die Hilfe ohne KI, "Zuletzt" und die Kostenzeile. Erreichbar aus "Tests & Wiederholung" und aus der KI-Hilfe
/// im Editor. Kontext ist das gewaehlte Modul und das angehaengte Dokument (Vorgabe: das zuletzt geoeffnete, als
/// Chip mit "Entfernen"; "Dokument anhängen" oeffnet die Dateien des Moduls); Fragen gehen an `POST /api/ai/tutor`
/// (die KI des Nutzers, `LocalContext.ai`) wie aus der KI-Hilfe im Editor (file_id, page, mode, history), nur nach
/// dem Antippen. "Hilfe" fragt keine KI (0 Credits). Ohne verbundene KI steht oben der Weg dorthin, die Aktionen
/// bleiben sichtbar.
struct AIStartView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufChatGPTLink) private var chatgpt
    @Environment(\.ufStudoraAccount) private var studoraAccount
    @Environment(\.ufWindowWidth) private var windowWidth
    @Environment(\.dynamicTypeSize) private var typeSize
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
    /// 429 `credits_exhausted` des Dienstes: unter der Meldung der Weg zum Tarif
    @State private var creditsExhausted = false
    @State private var answer: Answer?
    /// "Zuletzt benutzt" (`RecentCard`, GET /api/recent und die Gespraeche der KI-Hilfe)
    @State private var recentUsed: [RecentItem] = []
    @State private var help = false
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
    private var attachment: AIAttachment? { Self.attachment(fileID: fileID, documents: documents) }

    var body: some View {
        UFContent(maxWidth: 960) {
            head
            if !aiEnabled { connectCard.padding(.bottom, 16) }
            actions.padding(.bottom, 12)
            askBox
            if help {
                helpCard.padding(.top, 20)
            } else if let answer {
                answerCard(answer).padding(.top, 20)
            }
            if !recents.entries.isEmpty { recentRow.padding(.top, 24) }
            // "Zuletzt benutzt" (Weitermachen wie zuvor): Dokumente, KI-Gespraeche, Wochentests nach Zeit
            if !recentUsed.isEmpty { RecentCard(items: recentUsed).padding(.top, 24) }
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
            // Vorgabe nur beim ersten Laden: ein entferntes Dokument kommt beim Neuladen nicht zurueck
            if !loaded, fileID.isEmpty, let f = currentFile?.s("id") { fileID = f }
            loaded = true
        } catch { if !loaded { toast.show(error.localizedDescription) } }
        recentUsed = await RecentItem.load(api: api, conversations: .shared, limit: 15)
    }

    // MARK: Kopf: Logo und die eine Frage

    private var head: some View {
        VStack(spacing: 6) {
            HStack {
                UFButton("Tests", icon: "arrow-left", kind: .ghost, size: .small) { router.go(.exams) }.accessibilityIdentifier("ai.start.tests")
                Spacer(minLength: 0)
            }
            UFLogoMark(size: 44).padding(.bottom, 6)
            Text("Was möchtest du heute lernen?").ufFont(23.2, 650, lh: 1.25, em: -0.01).foregroundStyle(UF.text)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Frag die KI zu deinen Unterlagen, lass Karteikarten und Wochentests erstellen.")
                .ufFont(14.5).foregroundStyle(UF.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
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

    // MARK: Aktionen (direkt ueber dem Frage-Feld)

    private var actions: some View {
        let layout = Self.actionsLayout(width: windowWidth, typeSize: typeSize)
        return Group {
            if layout == .row {
                UFFlexWrap(gap: 10, rowGap: 10, justify: .center) { pills(compact: true) }
            } else {
                VStack(spacing: 10) { pills(compact: false) }
            }
        }
        .accessibilityIdentifier("ai.start.actions")
    }

    /// Reihenfolge und Farben der Aktionen: Fragen (Teal), Karteikarten (Orange), Erklaeren (Gruen), Wochentest
    /// (Blau), Hilfe (Violett) – Paarungen aus der Palette der Community
    @ViewBuilder private func pills(compact: Bool) -> some View {
        AIActionPill(title: "Fragen", sub: "Zur Seite, zur Aufgabe, zum Begriff", icon: "sparkles", pair: CommunityPalette.teal, compact: compact) {
            help = false
            askFocused = true
        }
        .accessibilityIdentifier("ai.start.pill.ask")
        AIActionPill(title: "Karteikarten", sub: "Aus einem Dokument, zum Durchsehen vor dem Speichern", icon: "cards",
                     pair: CommunityPalette.peach, compact: compact) { openFlashcards() }
            .accessibilityIdentifier("ai.start.pill.cards")
        AIActionPill(title: "Erklären / PDF analysieren", sub: "Zusammenfassung des Dokuments, dann weiter im Editor", icon: "book",
                     pair: CommunityPalette.mint, compact: compact) { Task { await explain() } }
            .accessibilityIdentifier("ai.start.pill.explain")
        AIActionPill(title: "Wochentest", sub: "15 Aufgaben zu einer Lehrwoche, gemeinsam je Modul", icon: "exam",
                     pair: CommunityPalette.sky, compact: compact) { openQuiz() }
            .accessibilityIdentifier("ai.start.pill.quiz")
        AIActionPill(title: "Hilfe", sub: "Was die KI-Hilfe kann und wie du anfängst, ohne KI", icon: "life-buoy",
                     pair: CommunityPalette.lavender, compact: compact) { showHelp() }
            .accessibilityIdentifier("ai.start.pill.help")
    }

    private func openFlashcards() {
        overlay.modal(wide: true) {
            FlashcardComposer(moduleID: module, fileID: currentFile?.s("id"), entitlements: ent)
        }
    }

    private func openQuiz() {
        overlay.modal { QuizComposer(moduleID: module != 0 ? module : modules.first?.i("id") ?? 0, entitlements: ent) }
    }

    private func showHelp() {
        answer = nil
        help = true
    }

    // MARK: Frag etwas …

    private var askBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Kontext: Modul und das angehaengte Dokument, zu dem die Frage gehoert
            UFFlexWrap(gap: 8, rowGap: 8) {
                UFSelect(options: [(0, "Alle Module")] + modules.compactMap { m in m.i("id").map { ($0, UFFmt.shortName(m.s("name"))) } },
                         selection: $module, small: true)
                    .accessibilityLabel("Modul")
                    .accessibilityIdentifier("ai.start.module")
                if let a = attachment {
                    attachmentChip(a)
                } else {
                    UFButton("Dokument anhängen", icon: "file-text", size: .small) { openPicker() }
                        .accessibilityIdentifier("ai.start.attach")
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
                if creditsExhausted {
                    UFButton("Tarif ansehen", icon: "star", size: .small) { router.go(.settings(tab: "account")) }
                        .accessibilityIdentifier("ai.start.plans")
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: UF.rLg).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.rLg).strokeBorder(askFocused ? UF.accent : UF.line, lineWidth: 1))
        .ufShadow(.md)
        .animation(UF.transition, value: askFocused)
    }

    /// Das angehaengte Dokument als Chip: Antippen waehlt ein anderes, das x entfernt es (die Frage geht dann ohne
    /// Dokument)
    private func attachmentChip(_ a: AIAttachment) -> some View {
        HStack(spacing: 4) {
            Button { openPicker() } label: {
                HStack(spacing: 4.8) {
                    UFIcon("file-text", size: 13)
                    Text(a.label).lineLimit(1)
                }
                .padding(.vertical, 4 + ufB).padding(.leading, 10.4 + ufB).padding(.trailing, 4)
                .contentShape(Rectangle())
                .ufHitArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Angehängt: \(a.label). Anderes Dokument wählen")
            .accessibilityIdentifier("ai.start.attach.chip")
            Button { fileID = "" } label: {
                UFIcon("x", size: 12).padding(.vertical, 6).padding(.horizontal, 6).contentShape(Rectangle()).ufHitArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dokument entfernen")
            .accessibilityIdentifier("ai.start.attach.remove")
            .padding(.trailing, 2)
        }
        .ufFont(12.8, 600)
        .foregroundStyle(UF.accentText)
        .background(Capsule().fill(UF.accentSoft))
    }

    private func openPicker() {
        let docs = documents
        overlay.modal {
            AIDocumentPicker(documents: docs, selected: fileID) { f in fileID = f.s("id") ?? "" }
        }
    }

    /// Mit Konto beim Dienst der echte Credits-Stand (`credits`), sonst der Weg der KI
    private var statusLine: String {
        AICost.status(chatgpt: aiEnabled, model: chatgpt?.status?.model, plan: ent.plan, requestsThisMonth: recents.requestsThisMonth,
                      credits: studoraAccount?.credits, charge: studoraAccount?.lastCharge, trial: studoraAccount?.planStatus?.trialActive ?? false)
    }

    // MARK: Hilfe ohne KI

    private var helpCard: some View {
        AIHelpCard(example: { text in
            question = text
            askFocused = true
        }, openSettings: { router.go(.settings(tab: "account")) }, close: { help = false })
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
            let grid = windowWidth <= 640 || typeSize.isAccessibilitySize ? UFGridLayout(columns: 1, spacing: 10) : UFGridLayout(columns: 3, spacing: 10)
            grid {
                ForEach(Array(recents.entries.enumerated()), id: \.element.id) { i, e in
                    Button {
                        help = false
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

    /// Eine Frage an `POST /api/ai/tutor` mit dem angehaengten Dokument (Seite 1) als Kontext, wie die KI-Hilfe im
    /// Editor (file_id, page, mode, history); die Antwort kommt in den Antwortbereich und nach "Zuletzt"
    private func send(mode: String, question q: String, label: String, busyLabel: String, history: JSONValue = .array([])) async {
        guard let api = session.api, !busy else { return }
        // Kontext: das angehaengte Dokument (Seite 1); ohne Dokument geht nur die Frage
        let f = fileID.isEmpty ? nil : currentFile
        var body: [String: JSONValue] = ["mode": .string(mode), "page": 1, "history": history]
        if let id = f?.s("id") { body["file_id"] = .string(id) }
        if !q.isEmpty { body["question"] = .string(q) }
        busy = true
        self.busyLabel = busyLabel
        error = nil
        creditsExhausted = false
        help = false
        defer { busy = false }
        do {
            let r = try await api.value("/api/ai/tutor", method: "POST", body: .object(body))
            studoraAccount?.noteAIResponse(r)   // Credits-Stand und `charged` fuer die Kostenzeile
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
            creditsExhausted = studoraAccount?.noteAIError(error) ?? StudoraCredits.isExhausted(error)
        }
    }
}
