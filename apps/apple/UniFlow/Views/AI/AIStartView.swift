import SwiftUI
import UniFlowCore

/// KI-Start (03.11.2026, Feinschliff und Neugestaltung 04.11.2026 nach Vorbild-Vergleich). Zwei Zustaende
/// (`PageLayout`):
/// - Start: ruhig in der Mitte das Logo und die eine Frage "Was möchtest du heute lernen?", darunter die Aktionen als
///   umrandete Pillen in ihren Farben (Fragen, Karteikarten, Erklären / PDF analysieren, Wochentest, Hilfe) und EIN
///   grosses, rundes Frage-Feld. Modul und Dokument sind kleine Knoepfe unten links im Feld, Senden unten rechts, die
///   Kostenzeile klein darunter; darunter "Zuletzt" und "Zuletzt benutzt".
/// - Gespraech (nach der ersten Frage): Verlauf mit Fragen als Blasen rechts und Antworten als Markdown links,
///   Anschlussfragen unter der letzten Antwort; Aktionen und Frage-Feld unten fest, "Neues Gespräch" oben rechts.
/// Kontext ist das gewaehlte Modul und das angehaengte Dokument (Vorgabe: das zuletzt geoeffnete, als Chip mit
/// "Entfernen"; "Dokument anhängen" oeffnet die Dateien des Moduls); Fragen gehen an `POST /api/ai/tutor` (die KI des
/// Nutzers, `LocalContext.ai`) wie aus der KI-Hilfe im Editor (file_id, page, mode, history), nur nach dem Antippen.
/// "Hilfe" fragt keine KI (0 Credits). Ohne verbundene KI steht oben der Weg dorthin, die Aktionen bleiben sichtbar.
struct AIStartView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufAIAccess) private var aiAccess
    @Environment(\.ufStudiNowAI) private var studinowAI
    @Environment(\.ufChatGPTLink) private var chatgpt
    @Environment(\.ufStudoraAccount) private var studoraAccount
    @Environment(\.ufWindowWidth) private var windowWidth
    @Environment(\.dynamicTypeSize) private var typeSize
    /// schmal (iPhone, schmales Split View): Feld unten ueber der Tastatur, Aktionen als seitlich scrollende Reihe
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// kompakt laut Huelle (auch iPhone quer, `UFLayout.isCompact`)
    @Environment(\.ufCompact) private var shellCompact
    @StateObject private var learnSheets = UFLearnSheets()
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
    @State private var errorAction: StudiNowAIAction?
    /// Das Gespraech auf dieser Seite (frisch oder aus "Zuletzt" geoeffnet), aelteste zuerst
    @State private var turns: [Answer] = []
    /// Frage, deren Antwort gerade laeuft (steht schon als Blase im Verlauf)
    @State private var pending: String?
    /// "Zuletzt benutzt" (`RecentCard`, GET /api/recent und die Gespraeche der KI-Hilfe)
    @State private var recentUsed: [RecentItem] = []
    @State private var help = false
    @FocusState private var askFocused: Bool
    @ScaledMetric(relativeTo: .body) private var chipIcon: CGFloat = 14

    /// Ein Beitrag des Gespraechs: Frage (bzw. Beschriftung der Aktion) und Antwort
    struct Answer: Equatable, Identifiable {
        var question: String
        var text: String
        var mode: String
        var fileID: String?
        var fileName: String?
        var id = UUID()
    }

    /// Zustand der Seite: Start (Mitte, Pillen, Feld, Zuletzt) oder Gespraech (Verlauf, Feld unten fest)
    enum PageLayout: Equatable {
        case start
        case chat
    }

    /// Gespraech, sobald es einen Beitrag gibt oder die erste Frage unterwegs ist
    static func layout(turns: Int, pending: Bool) -> PageLayout { turns > 0 || pending ? .chat : .start }

    /// "Zuletzt" und "Zuletzt benutzt" stehen nur ohne offenes Gespraech unter dem Feld
    static func showsRecents(_ layout: PageLayout) -> Bool { layout == .start }

    /// Verlauf fuer `history` (wie die KI-Hilfe im Editor: die letzten `AIPrompts.tutorHistoryTurns` Beitraege)
    static func history(_ turns: [Answer]) -> JSONValue {
        .array(turns.flatMap { t -> [JSONValue] in
            [["role": "user", "text": .string(t.question)], ["role": "assistant", "text": .string(t.text)]]
        }.suffix(AIPrompts.tutorHistoryTurns))
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
    private var layout: PageLayout { Self.layout(turns: turns.count, pending: pending != nil) }
    /// Breite der Spalte (Feld, Verlauf): ruhig lesbar, auf dem iPad quer nicht ueber die ganze Breite
    private let column: CGFloat = 820
    private var compact: Bool { UFCompactLearn.isCompact(sizeClass, shell: shellCompact) }
    /// Dialoge schmal als Blatt von unten, breit mittig
    private var sheets: UFLearnSheets? { compact ? learnSheets : nil }
    /// Seitenrand: schmal 16 pt, breit 24 pt
    private var gutter: CGFloat { compact ? UFCompactLearn.gutter : 24 }

    var body: some View {
        Group {
            if layout == .chat { chatPage } else if compact { compactStartPage } else { startPage }
        }
        .background(UF.bg)
        .ufLearnSheetHost(learnSheets)
        .task(id: session.api.map(ObjectIdentifier.init)) { await load() }
        // StudiNow-KI: Credits-Stand frisch vom Dienst (GET /api/entitlements), danach nach jeder Antwort
        .task(id: studinowAI) { if studinowAI { await studoraAccount?.refreshCredits() } }
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

    // MARK: - Start: Logo, Frage, Pillen, Feld

    private var startPage: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    topBar
                    VStack(spacing: 0) {
                        head
                        if !aiEnabled { connectCard.padding(.bottom, 20) }
                        actions.padding(.bottom, 16)
                        composer(large: true)
                        statusBlock.padding(.top, 8)
                        if help { helpCard.padding(.top, 20) }
                    }
                    .frame(minHeight: max(0, geo.size.height * 0.74 - 60), alignment: .center)
                    if Self.showsRecents(layout) {
                        if !recents.entries.isEmpty { recentRow.padding(.top, 28) }
                        // "Zuletzt benutzt" (Weitermachen wie zuvor): Dokumente, KI-Gespraeche, Wochentests nach Zeit
                        if !recentUsed.isEmpty { RecentCard(items: recentUsed).padding(.top, 24) }
                    }
                }
                .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 48)
                .frame(maxWidth: column)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// Start schmal: oben Logo, Frage und die Aktionen als seitlich scrollende Reihe, Hilfe und "Zuletzt" darunter;
    /// das Frage-Feld steht unten fest und rutscht mit der Tastatur hoch
    private var compactStartPage: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    topBar
                    VStack(spacing: 0) {
                        head
                        if !aiEnabled { connectCard.padding(.bottom, 16) }
                        compactActions.padding(.bottom, 8)
                    }
                    .frame(minHeight: max(0, geo.size.height * 0.5), alignment: .center)
                    if help { helpCard.padding(.top, 12) }
                    if Self.showsRecents(layout) {
                        if !recents.entries.isEmpty { recentRow.padding(.top, 24) }
                        if !recentUsed.isEmpty { RecentCard(items: recentUsed).padding(.top, 20) }
                    }
                }
                .padding(.horizontal, gutter).padding(.top, 10).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            UFCompactBottomBar {
                composer(large: false)
                statusBlock
            }
            .accessibilityIdentifier("ai.start.bottom")
        }
    }

    /// Aktionen schmal: eine Reihe kompakter Pillen, die seitlich scrollt (nichts gekuerzt, nichts umgebrochen)
    private var compactActions: some View {
        UFCompactScrollRow(spacing: 8, inset: gutter) { pills(compact: true) }
            .accessibilityIdentifier("ai.start.actions")
    }

    /// Oben: zurueck zu den Tests; im Gespraech rechts "Neues Gespräch"
    private var topBar: some View {
        HStack(spacing: 8) {
            UFButton("Tests", icon: "arrow-left", kind: .ghost, size: .small) { router.go(.exams) }.accessibilityIdentifier("ai.start.tests")
            Spacer(minLength: 0)
            if layout == .chat {
                UFButton("Neues Gespräch", icon: "plus", size: .small) { newConversation() }
                    .disabled(busy)
                    .accessibilityIdentifier("ai.start.new")
            }
        }
    }

    private var head: some View {
        VStack(spacing: 14) {
            UFLogoMark(size: 52)
            Text("Was möchtest du heute lernen?").ufFont(26, 700, lh: 1.2, em: -0.015).foregroundStyle(UF.text)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }

    // MARK: Verbinden

    @ViewBuilder private var connectCard: some View {
        UFCard {
            UFCardHead(ChatGPTLink.isEnabled ? "KI verbinden" : "KI-Hilfe", icon: "sparkles")
            if let chatgpt {
                TutorConnectState(link: chatgpt) { router.go(.settings(tab: ChatGPTLink.settingsTab)) }.padding(-16).padding(.top, 8)
            } else {
                TutorConnectState.Content(reason: TutorConnectState.reason(nil, access: aiAccess), message: nil, busy: false, fix: nil) { router.go(.settings(tab: ChatGPTLink.settingsTab)) }
                    .padding(-16).padding(.top, 8)
            }
        }
    }

    // MARK: Aktionen

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

    /// Aktionen im Gespraech: eine Reihe ueber dem Feld; passt sie nicht, laesst sie sich seitlich schieben (nichts
    /// wird gekuerzt)
    private var chatActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { pills(compact: true, dense: true) }.frame(maxWidth: .infinity)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { pills(compact: true, dense: true) }.padding(.vertical, 2).padding(.horizontal, 1)
            }
        }
        .accessibilityIdentifier("ai.start.actions")
    }

    /// Reihenfolge und Farben der Aktionen: Fragen (Teal), Karteikarten (Orange), Erklaeren (Gruen), Wochentest
    /// (Blau), Hilfe (Violett) – Paarungen aus der Palette der Community
    @ViewBuilder private func pills(compact: Bool, dense: Bool = false) -> some View {
        AIActionPill(title: "Fragen", sub: "Zur Seite, zur Aufgabe, zum Begriff", icon: "sparkles", pair: CommunityPalette.teal, compact: compact, dense: dense) {
            help = false
            askFocused = true
        }
        .accessibilityIdentifier("ai.start.pill.ask")
        AIActionPill(title: "Karteikarten", sub: "Aus einem Dokument, zum Durchsehen vor dem Speichern", icon: "cards",
                     pair: CommunityPalette.peach, compact: compact, dense: dense) { openFlashcards() }
            .accessibilityIdentifier("ai.start.pill.cards")
        AIActionPill(title: "Erklären / PDF analysieren", sub: "Zusammenfassung des Dokuments, dann weiter im Editor", icon: "book",
                     pair: CommunityPalette.mint, compact: compact, dense: dense) { Task { await explain() } }
            .accessibilityIdentifier("ai.start.pill.explain")
        AIActionPill(title: "Wochentest", sub: "15 Aufgaben zu einer Lehrwoche, gemeinsam je Modul", icon: "exam",
                     pair: CommunityPalette.sky, compact: compact, dense: dense) { openQuiz() }
            .accessibilityIdentifier("ai.start.pill.quiz")
        AIActionPill(title: "Hilfe", sub: "Was die KI-Hilfe kann und wie du anfängst, ohne KI", icon: "life-buoy",
                     pair: CommunityPalette.lavender, compact: compact, dense: dense) { showHelp() }
            .accessibilityIdentifier("ai.start.pill.help")
    }

    private func openFlashcards() {
        overlay.learnModal(sheets, wide: true, large: true) {
            FlashcardComposer(moduleID: module, fileID: currentFile?.s("id"), entitlements: ent)
        }
    }

    private func openQuiz() {
        overlay.learnModal(sheets, large: true) { QuizComposer(moduleID: module != 0 ? module : modules.first?.i("id") ?? 0, entitlements: ent) }
    }

    private func showHelp() {
        help = true
    }

    private func newConversation() {
        turns = []
        help = false
        error = nil
        errorAction = nil
    }

    // MARK: Frage-Feld

    private func composer(large: Bool) -> some View {
        AIComposer(placeholder: "Frag etwas … z. B. Erkläre mir den Satz von Bolzano", text: $question, focused: $askFocused, large: large,
                   canSend: aiEnabled && !busy && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   sendLabel: "Frage senden", placeholderOneLine: compact, inputID: "ai.start.input", sendID: "ai.start.ask",
                   send: { Task { await ask() } }) {
            moduleMenu
            if let a = attachment {
                attachmentChip(a)
            } else {
                Button { openPicker() } label: { AIComposerPill(icon: "file-text") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dokument anhängen")
                    .accessibilityIdentifier("ai.start.attach")
            }
        }
    }

    private var moduleOptions: [(value: Int, label: String)] {
        [(0, "Alle Module")] + modules.compactMap { m in m.i("id").map { ($0, UFFmt.shortName(m.s("name"))) } }
    }

    private var moduleName: String { moduleOptions.first { $0.value == module }?.label ?? "Alle Module" }

    /// Modul als kleines Menue im Feld: zeigt den Namen des gewaehlten Moduls
    private var moduleMenu: some View {
        Menu {
            Picker("Modul", selection: $module) {
                ForEach(moduleOptions.indices, id: \.self) { i in Text(moduleOptions[i].label).tag(moduleOptions[i].value) }
            }
        } label: {
            AIComposerPill(icon: "layers", text: moduleName, oneLine: compact)
                .frame(maxWidth: compact ? 150 : nil, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Modul: \(moduleName)")
        .accessibilityIdentifier("ai.start.module")
    }

    /// Das angehaengte Dokument als Chip: Antippen waehlt ein anderes, das x entfernt es (die Frage geht dann ohne
    /// Dokument)
    private func attachmentChip(_ a: AIAttachment) -> some View {
        HStack(spacing: 2) {
            Button { openPicker() } label: {
                HStack(spacing: 6) {
                    UFIcon("file-text", size: min(chipIcon, 26))
                    // schmal eine Zeile (der ganze Name steht in der Beschriftung fuer VoiceOver)
                    Text(compact ? a.title : a.label).ufFont(12.8, 550, lh: 1.3).multilineTextAlignment(.leading)
                        .lineLimit(compact ? 1 : nil)
                        .fixedSize(horizontal: false, vertical: !compact)
                }
                .padding(.vertical, 6).padding(.leading, 10).padding(.trailing, 2)
                .contentShape(Rectangle())
                .ufHitArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Angehängt: \(a.label). Anderes Dokument wählen")
            .accessibilityIdentifier("ai.start.attach.chip")
            Button { fileID = "" } label: {
                UFIcon("x", size: min(chipIcon - 2, 22)).padding(.vertical, 6).padding(.horizontal, 7).contentShape(Rectangle()).ufHitArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dokument entfernen")
            .accessibilityIdentifier("ai.start.attach.remove")
            .padding(.trailing, 2)
        }
        .foregroundStyle(UF.accentText)
        .frame(minHeight: 30)
        .background(Capsule().fill(UF.accentSoft))
    }

    private func openPicker() {
        let docs = documents
        overlay.learnModal(sheets) {
            AIDocumentPicker(documents: docs, selected: fileID) { f in fileID = f.s("id") ?? "" }
        }
    }

    /// Kostenzeile klein unter dem Feld; darunter ein Fehler mit dem Weg zum Tarif
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusLine).ufFont(12, lh: 1.35).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("ai.start.status")
            if let error {
                Text(error).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ai.start.error")
                if let errorAction {
                    // Tarif (Recht, Kontingent, Credits) bzw. Anmeldung beim StudiNow-Konto
                    UFButton(StudoraAccountLink.errorButton(errorAction), icon: errorAction == .signIn ? "user" : "star", size: .small) {
                        router.go(.settings(tab: "account"))
                    }
                        .accessibilityIdentifier("ai.start.plans")
                }
            }
        }
        .padding(.horizontal, 8)
    }

    /// Mit Konto beim Dienst der echte Credits-Stand (`credits`), sonst der Weg der KI
    private var statusLine: String {
        // ueber die StudiNow-KI nie "über dein ChatGPT": dann der Credits-Stand bzw. "StudiNow-KI (Pro AI)"
        AICost.status(chatgpt: aiEnabled && !studinowAI, model: chatgpt?.status?.model, plan: studinowAI ? .proAI : ent.plan,
                      requestsThisMonth: recents.requestsThisMonth,
                      credits: studoraAccount?.credits, charge: studoraAccount?.lastCharge, trial: studoraAccount?.planStatus?.trialActive ?? false)
    }

    // MARK: Hilfe ohne KI

    private var helpCard: some View {
        AIHelpCard(example: { text in
            question = text
            askFocused = true
        }, openSettings: { router.go(.settings(tab: "account")) }, close: { help = false })
    }

    // MARK: - Gespraech

    private var chatPage: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, gutter).padding(.top, compact ? 10 : 14).padding(.bottom, 6)
                .frame(maxWidth: column).frame(maxWidth: .infinity)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(turns) { t in
                            VStack(alignment: .leading, spacing: 16) {
                                AIUserBubble(text: t.question, size: 15.2)
                                answerBlock(t, last: t.id == turns.last?.id && pending == nil)
                            }
                            .id(t.id)
                        }
                        if let pending {
                            VStack(alignment: .leading, spacing: 16) {
                                AIUserBubble(text: pending, size: 15.2)
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    UFShimmerText(busyLabel.isEmpty ? "Die KI denkt nach …" : busyLabel, size: 13.6)
                                }
                            }
                            .id("pending")
                        }
                        if help { helpCard.id("help") }
                    }
                    .padding(.horizontal, gutter).padding(.top, 12).padding(.bottom, 24)
                    .frame(maxWidth: column)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    let target: AnyHashable? = pending != nil ? AnyHashable("pending") : turns.last.map { AnyHashable($0.id) }
                    if let target { proxy.scrollTo(target, anchor: .top) }
                }
                .onChange(of: pending) { _, p in
                    if p != nil { withAnimation(UF.transition) { proxy.scrollTo("pending", anchor: .bottom) } }
                }
                .onChange(of: turns.count) { _, _ in
                    // neue Antwort: ihr Anfang (die Frage) oben, damit man von vorn liest
                    if let id = turns.last?.id { withAnimation(UF.transition) { proxy.scrollTo(id, anchor: .top) } }
                }
                .onChange(of: help) { _, on in
                    if on { withAnimation(UF.transition) { proxy.scrollTo("help", anchor: .top) } }
                }
            }
            if compact {
                // schmal: Aktionen, Feld und Kostenzeile unten fest ueber der Tastatur
                UFCompactBottomBar {
                    UFCompactScrollRow(spacing: 8, inset: gutter) { pills(compact: true, dense: true) }
                        .accessibilityIdentifier("ai.start.actions")
                    composer(large: false)
                    statusBlock
                }
                .accessibilityIdentifier("ai.start.bottom")
            } else {
                VStack(spacing: 10) {
                    chatActions
                    composer(large: false)
                    statusBlock
                }
                .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14)
                .frame(maxWidth: column)
                .frame(maxWidth: .infinity)
                .background(UF.bg)
            }
        }
    }

    /// Antwort links als Lesetext: kleine Kopfzeile (KI, Dokument), Markdown, unter der letzten Antwort die
    /// Anschlussfragen und der Weg ins Dokument
    private func answerBlock(_ a: Answer, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                UFIcon("sparkles", size: 14).foregroundStyle(UF.accent)
                Text(a.fileName.map { "KI-Antwort · \($0)" } ?? "KI-Antwort").ufFont(12.8, 550, lh: 1.3).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            AIMarkdownText(a.text, size: 15.2).accessibilityIdentifier("ai.start.answer")
            let followUps = last ? AIFollowUps.suggest(after: a.mode).filter { $0.mode != "flashcards" } : []
            if !followUps.isEmpty || (last && a.fileID != nil) {
                UFFlexWrap(gap: 8, rowGap: 8) {
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
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Zuletzt").ufFont(15.2, 650, em: -0.01).foregroundStyle(UF.text)
                Spacer()
                UFButton("Leeren", kind: .ghost, size: .small) { recents.clear() }.accessibilityIdentifier("ai.start.recent.clear")
            }
            let grid = compact || windowWidth <= 640 || typeSize.isAccessibilitySize ? UFGridLayout(columns: 1, spacing: 10) : UFGridLayout(columns: 3, spacing: 10)
            grid {
                ForEach(Array(recents.entries.enumerated()), id: \.element.id) { i, e in
                    Button {
                        help = false
                        turns = [Answer(question: e.question, text: e.answer, mode: "ask", fileID: e.fileID, fileName: e.fileName)]
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.question).ufFont(13.6, 650, lh: 1.3).foregroundStyle(UF.text).lineLimit(2)
                            Text(Self.plain(e.answer)).ufFont(12.8, lh: 1.35).foregroundStyle(UF.muted).lineLimit(3)
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

    /// Vorschau einer Antwort ohne Markdown-Zeichen (`**`, `#`, `- `) fuer die Karten unter "Zuletzt"
    static func plain(_ markdown: String) -> String {
        AIMarkdown.blocks(markdown).map { b -> String in
            switch b {
            case .heading(_, let t), .paragraph(let t): return String(AIMarkdown.inline(t).characters)
            case .bullets(let items), .numbered(let items): return items.map { String(AIMarkdown.inline($0).characters) }.joined(separator: " · ")
            case .code(let c): return c
            }
        }.joined(separator: " ")
    }

    // MARK: Senden

    private func ask() async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        await send(mode: "ask", question: q, label: q, busyLabel: "Die KI liest deine Unterlagen …")
    }

    private func explain() async {
        guard let f = currentFile else { toast.show("Wähle zuerst ein Dokument."); return }
        guard aiEnabled else { router.go(.settings(tab: ChatGPTLink.settingsTab)); return }
        fileID = f.s("id") ?? fileID
        await send(mode: "summary", question: "", label: "Zusammenfassung: \(Self.title(f))", busyLabel: "Die KI liest \(Self.title(f)) …")
    }

    private func followUp(_ s: AIFollowUps.Suggestion, after a: Answer) async {
        if let id = a.fileID, id != fileID { fileID = id }
        await send(mode: s.mode, question: s.question, label: s.question.isEmpty ? s.label : s.question, busyLabel: "Die KI antwortet …")
    }

    /// Eine Frage an `POST /api/ai/tutor` mit dem angehaengten Dokument (Seite 1) als Kontext und dem bisherigen
    /// Gespraech als `history`, wie die KI-Hilfe im Editor (file_id, page, mode, history); die Antwort kommt in den
    /// Verlauf und nach "Zuletzt"
    private func send(mode: String, question q: String, label: String, busyLabel: String) async {
        guard let api = session.api, !busy else { return }
        // Kontext: das angehaengte Dokument (Seite 1); ohne Dokument geht nur die Frage
        let f = fileID.isEmpty ? nil : currentFile
        var body: [String: JSONValue] = ["mode": .string(mode), "page": 1, "history": Self.history(turns)]
        if let id = f?.s("id") { body["file_id"] = .string(id) }
        if !q.isEmpty { body["question"] = .string(q) }
        busy = true
        self.busyLabel = busyLabel
        pending = label
        error = nil
        errorAction = nil
        help = false
        if mode == "ask" { question = "" }
        defer { busy = false; pending = nil }
        do {
            let r = try await api.value("/api/ai/tutor", method: "POST", body: .object(body))
            studoraAccount?.noteAIResponse(r)   // Credits-Stand und `charged` fuer die Kostenzeile
            var text = r.s("answer") ?? ""
            if mode == "flashcards", let cards = r["cards"]?.array, !cards.isEmpty {
                text = cards.map { "- **\($0.s("question") ?? "")** – \($0.s("answer") ?? "")" }.joined(separator: "\n")
            }
            let a = Answer(question: label, text: text, mode: mode, fileID: f?.s("id"), fileName: f.map(Self.title))
            turns.append(a)
            recents.record(question: label, answer: text, fileID: a.fileID, fileName: a.fileName)
        } catch {
            // Frage zurueck ins Feld (sie steht nicht im Verlauf), Meldung unter dem Feld
            if mode == "ask", question.isEmpty { question = q }
            self.error = error.localizedDescription
            errorAction = StudoraAccountLink.errorAction(error, account: studoraAccount)
        }
    }
}
