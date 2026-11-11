import SwiftUI
import UniFlowCore

/// KI-Hilfe im Editor als Seitenleiste neben der PDF (`POST /api/ai/tutor`): ein Gespraech zur offenen Seite mit freier
/// Frage und den Modi aus `ai.TUTOR_MODES`. Neugestaltung 04.11.2026 (Vorbild-Vergleich): oben drei farbige Reiter
/// "Erklären" (gruen), "Karteikarten" (orange), "Test" (blau), darunter die Aktionen des Reiters (`Tab.modes`) - seit
/// 07.11.2026 als flacher Kopf (`TutorPanelHead`) mit einer Reihe zum Wischen, damit die Antwort die Hoehe bekommt;
/// Antworten als Markdown (15 pt, `answerSize`) mit grossen Abschnittstiteln, Fragen als Blasen rechts; das Eingabefeld
/// unten fest, die Kostenzeile klein darunter. Rueckfragen schicken die letzten Beitraege als `history` mit,
/// markierter PDF-Text geht als `selection` mit.
/// Antworten mit Quellen aus den eigenen Unterlagen ([n] -> Seite). Laeuft ueber das ChatGPT-Abo des Nutzers (lokales
/// Backend, `LocalContext.ai`) bzw. den Dienst; gesendet wird nur nach dem Antippen. Ohne verbundene KI erklaert die
/// Leiste den Weg dorthin.
struct TutorPanel: View {
    let fileID: String
    /// Titel des Dokuments fuer "Zuletzt benutzt" (Gespraeche, `TutorConversations`)
    var fileName: String? = nil
    /// Seite der PDF beim Senden (1 = erste), wie `page_texts`
    let page: () -> Int
    /// Markierter PDF-Text beim Senden ("" ohne Markierung)
    let selection: () -> String
    /// Sprung zu einer Seite dieses Dokuments (1 = erste); Quellen aus anderen Dokumenten stehen als Text da
    let open: (_ fileID: String, _ page: Int) -> Void
    let close: () -> Void
    /// Frage aus "Text markieren" (markierter Text und Modus); wird gesendet und danach geleert
    var request: Binding<EditorBridge.TutorRequest?> = .constant(nil)
    /// Anhang aus dem Editor (markierter Text, Bereich als Bild); landet im Eingabefeld und wird danach geleert
    var attachment: Binding<TutorAttachment?> = .constant(nil)
    /// Modul des Dokuments fuer "Wochentest erstellen" im Reiter Test (nil: der Dialog fragt nach dem Modul)
    var moduleID: Int? = nil
    /// Seitennotizen und Blatt daneben der offenen Folie als Text (`AttachedNotes`, 05.11.2026); leer = keine
    var ownNotes: (@MainActor () async -> String)? = nil
    /// Kompakt (iPhone): die Leiste liegt als Blatt von unten ueber dem Dokument. Wege aus der Leiste (KI-Start,
    /// Einstellungen, Tarif) und der Dialog "Wochentest erstellen" schliessen das Blatt zuerst; sonst laege der Dialog
    /// unter dem Blatt bzw. ein zweites Blatt kaeme nicht
    var inSheet = false
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufAIAccess) private var aiAccess
    @Environment(\.ufStudiNowAI) private var studinowAI
    @Environment(\.ufChatGPTLink) private var chatgpt
    @Environment(\.ufStudoraAccount) private var studoraAccount
    @Environment(\.openURL) private var openURL

    /// Alle Modi in der Reihenfolge von `ai.TUTOR_MODES`; "ask" ist das Eingabefeld, die anderen liegen in den Reitern
    static let modes: [(key: String, label: String)] = [
        ("ask", "Frage"), ("explain", "Erklären"), ("explain_simple", "Einfach erklären"), ("summary", "Zusammenfassen"),
        ("steps", "Aufgabe lösen"), ("hints", "Nur Hinweise"), ("check", "Lösung prüfen"), ("similar", "Ähnliche Aufgabe"),
        ("terms", "Fachbegriffe"), ("flashcards", "Karteikarten"),
    ]

    /// Die drei Reiter oben in der Leiste und welche Modi darin liegen. Jeder Modus ausser "ask" gehoert genau einem
    /// Reiter (UniFlowTests/AIStartPolishAppTests.swift prueft das gegen `modes`).
    enum Tab: String, CaseIterable, Identifiable {
        case explain, cards, test

        var id: String { rawValue }

        var title: String {
            switch self {
            case .explain: return "Erklären"
            case .cards: return "Karteikarten"
            case .test: return "Test"
            }
        }

        var icon: String {
            switch self {
            case .explain: return "book"
            case .cards: return "cards"
            case .test: return "exam"
            }
        }

        /// Farben wie auf KI-Start: Erklaeren gruen, Karteikarten orange, Test blau
        var pair: CommunityPair {
            switch self {
            case .explain: return CommunityPalette.mint
            case .cards: return CommunityPalette.peach
            case .test: return CommunityPalette.sky
            }
        }

        /// Modi des Reiters in der Reihenfolge der Knoepfe ("check" schaltet das Feld auf "Lösung prüfen")
        var modes: [String] {
            switch self {
            case .explain: return ["explain", "explain_simple", "summary", "terms", "steps", "hints"]
            case .cards: return ["flashcards"]
            case .test: return ["similar", "check"]
            }
        }

        /// Reiter eines Modus (Anschlussfrage, "Text markieren"); nil fuer die freie Frage
        static func tab(for mode: String) -> Tab? { allCases.first { $0.modes.contains(mode) } }
    }

    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
        var cards: [JSONValue] = []
        var sources: [JSONValue] = []
        var saved = false
        /// Modus der Anfrage, zu der diese Antwort gehoert (Anschlussfragen, `AIFollowUps`)
        var mode: String = "ask"
        /// `explain` der Antwort (Erklaerungsspeicher): gespeicherte Antwort mit Quelle, oder null bei einer Live-Antwort
        var explain: JSONValue? = nil
    }

    /// Erklaerungsspeicher (04.11.2026): Beschriftung unter einer gespeicherten Antwort - ehrlich, woher sie kommt;
    /// nil bei einer Live-Antwort (nichts Besonderes zu zeigen)
    static func storedLabel(_ explain: JSONValue?) -> String? {
        guard let explain, explain["stored"]?.bool == true else { return nil }
        return explain["source"]?.string == "cloud" ? "Schon erklärt · sofort da · 0 Credits" : "Schon erklärt · 0 Credits"
    }

    /// "Neu erklaeren lassen" nur unter einer gespeicherten Antwort
    static func offersRebuild(_ explain: JSONValue?) -> Bool { storedLabel(explain) != nil }

    /// Anschlussfragen nur unter der letzten Antwort des Gespraechs (ruhiger Verlauf)
    static func showsFollowUps(at index: Int, in messages: [Message]) -> Bool {
        guard messages.indices.contains(index), !messages[index].fromUser else { return false }
        return index == messages.lastIndex { !$0.fromUser }
    }

    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var checking = false
    @State private var busy = false
    @State private var error: String?
    /// 429 `credits_exhausted` des Dienstes: unter der Meldung der Weg zum Tarif
    @State private var errorAction: StudiNowAIAction?
    @State private var tab: Tab = .explain
    /// Umfang und Lauf fuer das ganze Dokument (05.11.2026, TutorDocumentRun.swift): "Diese Seite | Ganzes Dokument |
    /// Seiten …", "Ganze Vorlesung erklären", "Alle Aufgaben erklären"
    @State private var docScope: TutorDocScope = .page
    @State private var docFrom = 1
    @State private var docTo = 1
    @StateObject private var docRunner = TutorDocRunner()
    /// Karten-Lauf fuers ganze Dokument (TutorCardsRun): welcher Teil gerade laeuft; nil = kein Lauf
    @State private var cardsProgress: String?
    @FocusState private var inputFocused: Bool
    /// Anhang im Eingabefeld (05.11.2026): geht mit der naechsten Frage bzw. dem naechsten Modus mit, danach weg
    @State private var attached: TutorAttachment?

    /// KI erreichbar (`ufAIEnabled`); sonst zeigt die Leiste den Anhang und den Tarif-Hinweis
    private var canAsk: Bool { aiEnabled }

    var body: some View {
        VStack(spacing: 0) {
            header
            if canAsk {
                tabBar
                conversation
            } else {
                notConnected
            }
        }
        .background(UF.surface)
        // Weitermachen wie zuvor (04.11.2026): das gemerkte Gespraech dieses Dokuments mit Antworten, Karten,
        // Anschlussfragen und "Schon erklärt" wieder zeigen (`TutorConversations`, bleibt auf dem Geraet)
        .onAppear { restoreConversation() }
        .task(id: studinowAI) { if studinowAI { await studoraAccount?.refreshCredits() } }
        .onChange(of: fileID) { _, _ in messages = []; error = nil; restoreConversation() }
        .task(id: request.wrappedValue?.id) {
            guard let r = request.wrappedValue else { return }
            request.wrappedValue = nil
            // ohne KI nicht still verwerfen: der Text steht dann als Anhang da, darunter der Hinweis
            guard canAsk else { attached = TutorAttachment(kind: .selection, text: r.selection, page: page()); return }
            await send(mode: r.mode, selection: r.selection)
        }
        .task(id: attachment.wrappedValue?.id) {
            guard let a = attachment.wrappedValue else { return }
            attachment.wrappedValue = nil
            attached = a
            if canAsk { inputFocused = true }
        }
    }

    /// Im Blatt: erst das Blatt schliessen, dann (nach dessen Animation) weiter; als Spalte sofort
    private func afterSheet(_ action: @escaping () -> Void) {
        guard inSheet else { action(); return }
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sheetDismissDelay, execute: action)
    }

    /// Zu einer anderen Seite der App (im Blatt: das Blatt zuerst schliessen)
    private func leave(_ route: UFRoute) {
        afterSheet { [router] in router.go(route) }
    }

    /// Zeit fuer das Wegschieben eines Blatts, bevor ein Dialog oder ein anderes Blatt erscheinen darf
    static let sheetDismissDelay: TimeInterval = 0.45

    /// Kopf wie die anderen Spalten neben der PDF (UFPaneHeader); "Neu" als ruhiger Textknopf
    private var header: some View {
        UFPaneHeader("KI-Hilfe", icon: "sparkles", closeLabel: "KI-Hilfe schließen", closeID: "tutor.close", close: close) {
            // KI-Start (03.11.2026): Fragen, Karteikarten, Erklären, Wochentest auf einer Seite
            UFButton(icon: "grid", kind: .ghost, size: .small) { leave(.aiStart) }
                .accessibilityLabel("KI-Start öffnen").accessibilityIdentifier("tutor.aiStart")
            if !messages.isEmpty {
                UFButton("Neu", kind: .ghost, size: .small) { messages = []; error = nil; persistConversation() }
                    .disabled(busy).accessibilityIdentifier("tutor.reset")
            }
        }
    }

    // MARK: Reiter

    /// Lesegroesse der Antworten (nie unter 15 pt, Entscheidung 07.11.2026); Titel darin sind groesser (`AIMarkdownText`)
    static let answerSize: CGFloat = 15

    /// Kopf der Leiste (`TutorPanelHead`): Reiter, Umfang und eine Reihe Aktionen zum seitlichen Wischen
    private var tabBar: some View {
        TutorPanelHead(tab: $tab, scope: $docScope, from: $docFrom, to: $docTo, busy: busy, checking: checking,
                       mode: { activate(mode: $0) },
                       doc: { mode in Task { await startDoc(mode: mode) } },
                       cards: { Task { await startCards() } },
                       weeklyTest: { overlay.modal { QuizComposer(moduleID: moduleID ?? 0) } })
    }

    /// Knopf eines Modus: sendet sofort; "Lösung prüfen" schaltet stattdessen das Eingabefeld um; bei Umfang "Ganzes
    /// Dokument"/"Seiten" laeuft ein Lauf statt der Frage zur Seite
    private func activate(mode key: String) {
        if key == "check" {
            checking.toggle()
            if checking { inputFocused = true }
        } else if let doc = TutorDocRun.docMode(forTutorMode: key, scope: docScope) {
            Task { await startDoc(mode: doc) }
        } else {
            Task { await send(mode: key) }
        }
    }

    /// Ohne KI: der Weg zur Verbindung - und darueber, was die Bibliothek zur offenen Seite schon weiss (lesen darf
    /// jeder, 0 Credits; die Karte bleibt leer, wenn der Index die Seite nicht kennt)
    @ViewBuilder private var notConnected: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                // der Anhang kam an (sichtbar), auch wenn die KI hier noch nicht antworten kann
                if let a = attached { TutorAttachmentCard(attachment: a, chip: inSheet) { attached = nil } }
                DocIndexPageCard(fileID: fileID, page: page, open: open)
            }
                .padding(.horizontal, 14).padding(.top, 14)
            if let chatgpt {
                TutorConnectState(link: chatgpt) { leave(.settings(tab: ChatGPTLink.settingsTab)) }
            } else {
                TutorConnectState.Content(reason: TutorConnectState.reason(nil, access: aiAccess), message: nil, busy: false, fix: nil) { leave(.settings(tab: ChatGPTLink.settingsTab)) }
            }
        }
    }

    // MARK: Gespraech

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Dokument-Index: schon erklaerte Seite sofort, 0 Credits (DocIndexPageCard)
                        DocIndexPageCard(fileID: fileID, page: page, open: open)
                        if messages.isEmpty { emptyState }
                        ForEach($messages) { $m in
                            bubble($m, index: messages.firstIndex { $0.id == m.id } ?? 0).id(m.id)
                        }
                        // ganzes Dokument: Rueckfrage zu den Kosten bzw. Fortschritt "Teil 2 von 4"
                        TutorDocRunCard(runner: docRunner) { Task { await runDoc() } }
                        if busy && docRunner.phase != .running {
                            // dezenter Schimmer (text-shimmer); beim Karten-Lauf der Teil ("Karteikarten, Teil 2 von 3 …")
                            HStack(spacing: 8) { ProgressView(); UFShimmerText(cardsProgress ?? "Die KI liest die Seite …") }
                                .id("busy")
                                .accessibilityIdentifier("tutor.busy")
                        }
                        if let error {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(error).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("tutor.error")
                                if let errorAction {
                                    // Tarif (Recht, Kontingent, Credits) bzw. Anmeldung beim StudiNow-Konto
                                    UFButton(StudoraAccountLink.errorButton(errorAction), icon: errorAction == .signIn ? "user" : "star", size: .small) {
                                        leave(.settings(tab: "account"))
                                    }
                                        .accessibilityIdentifier("tutor.plans")
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(busy ? "busy" : messages.last?.id as AnyHashable?, anchor: .bottom) }
                }
                .onChange(of: busy) { _, now in
                    if now { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } }
                }
            }
            composer
        }
    }

    /// Leerzustand als Einladung: was die Leiste kann, in der Schrift des Gespraechs
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                UFIcon("sparkles", size: 16).foregroundStyle(UF.accent)
                Text("Frag etwas zur offenen Seite").ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Oder wähle oben Erklären, Karteikarten oder Test. Markierter Text wird mitgeschickt.")
                .ufFont(13.12, lh: 1.45).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let a = attached {
                TutorAttachmentCard(attachment: a, chip: inSheet) { attached = nil }
            }
            AIComposer(placeholder: checking ? "Deine Lösung oder deinen Rechenweg eintragen"
                                             : (attached == nil ? "Frag etwas zur Seite …" : "Frag etwas dazu – oder gleich senden: „Erklär mir das“"),
                       text: $input, focused: $inputFocused,
                       canSend: Self.canSend(busy: busy, input: input, attached: attached != nil, checking: checking),
                       sendLabel: checking ? "Lösung prüfen" : "Senden", inputID: "tutor.input", sendID: "tutor.ask",
                       send: { Task { await send(mode: Self.composerMode(checking: checking, input: input, attached: attached != nil)) } }) {
                if checking {
                    Button { checking = false } label: {
                        AIComposerPill(icon: "check", text: "Lösung prüfen", tint: Tab.test.pair.fg, fill: Tab.test.pair.bg)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Lösung prüfen beenden")
                    .accessibilityIdentifier("tutor.check.off")
                }
            }
            Text(Self.footer(page: attached?.page ?? page(), model: chatgpt?.activeModel, credits: studoraAccount?.credits, charge: studoraAccount?.lastCharge,
                             adopted: Self.storedLabel(messages.last?.explain) != nil, trial: studoraAccount?.planStatus?.trialActive ?? false,
                             studinow: studinowAI))
                .ufFont(11.5, lh: 1.35).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .accessibilityIdentifier("tutor.footer")
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
        .background(UF.surface)
    }

    /// Fusszeile des Eingabefelds: Seite, Weg (dein ChatGPT) und das Modell, das zuletzt geantwortet hat (ChatGPT lehnt
    /// Modelle je Konto ab; die Sitzung wechselt dann, und hier steht, womit die Antwort wirklich kam). Mit Credits-Stand
    /// vom Dienst steht der Weg mit den Credits (`AICost.creditsLine`): "Dein ChatGPT – 0 Credits", nach einer
    /// gespeicherten Antwort "Schon erklärt · 0 Credits", nach einer berechneten "– 3 Credits (37 übrig)".
    /// `studinow`: Antworten kommen ueber die StudiNow-KI (Credits): "Seite 3 · StudiNow-KI · – 3 Credits (37 übrig)"
    static func footer(page: Int, model: String?, credits: StudoraCredits? = nil, charge: StudoraCredits.Charge? = nil,
                       adopted: Bool = false, trial: Bool = false, studinow: Bool = false) -> String {
        if studinow {
            let line = AICost.creditsLine(credits: credits, chatgpt: false, adopted: adopted, charge: charge, trial: trial)
            return "Seite \(page) · StudiNow-KI" + (line.map { " · \($0)" } ?? "")
        }
        let m = (model ?? "").trimmingCharacters(in: .whitespaces)
        let way = credits != nil
            ? AICost.creditsLine(credits: credits, chatgpt: charge == nil && !adopted, adopted: adopted, charge: charge, trial: trial) ?? AICost.ownWay
            : AICost.ownWay
        return "Seite \(page) · \(way)" + (m.isEmpty ? "" : " · \(m)")
    }

    @ViewBuilder private func bubble(_ m: Binding<Message>, index: Int) -> some View {
        let msg = m.wrappedValue
        if msg.fromUser {
            AIUserBubble(text: msg.text, size: 14.5)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !msg.cards.isEmpty {
                    ForEach(msg.cards.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(FormulaText.attributed(msg.cards[i].s("question") ?? "", size: 14.5, weight: 650)).ufFont(14.5, 650, lh: 1.4).foregroundStyle(UF.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(FormulaText.attributed(msg.cards[i].s("answer") ?? "", size: 13.76)).ufFont(13.76, lh: 1.5).foregroundStyle(UF.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: UF.r).fill(Tab.cards.pair.bg.opacity(0.55)))
                        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(Tab.cards.pair.solid.opacity(0.35), lineWidth: 1))
                        .accessibilityElement(children: .combine)
                    }
                    UFButton(msg.saved ? "In Karteikarten gespeichert" : "Als Karteikarten speichern", icon: "cards", size: .small) {
                        Task { await saveCards(m) }
                    }
                    .disabled(msg.saved)
                } else {
                    // Markdown (grosse Abschnittstitel, Aufzaehlungen, Fett) in den Schriften des Designsystems
                    if msg.mode.hasPrefix("doc_") {
                        // Lauf fuer das ganze Dokument: Bloecke mit Seiten als Knopf
                        TutorDocBlocks(text: msg.text, mode: msg.mode, explain: msg.explain) { open(fileID, $0) }
                    } else {
                        AIMarkdownText(msg.text, size: Self.answerSize).accessibilityIdentifier("tutor.answer")
                    }
                    // gespeicherte Antwort (Erklaerungsspeicher): Herkunft und der Weg zu einer frischen Antwort
                    if let stored = Self.storedLabel(msg.explain) {
                        UFFlexWrap(gap: 8, rowGap: 6) {
                            HStack(spacing: 6) {
                                UFIcon("check", size: 13).foregroundStyle(UF.ok)
                                Text(stored).ufFont(12, lh: 1.35).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("tutor.stored")
                            UFButton("Neu erklären lassen", icon: "refresh", kind: .ghost, size: .small) { Task { await send(mode: msg.mode, force: true) } }
                                .disabled(busy)
                                .accessibilityIdentifier("tutor.rebuild")
                        }
                    }
                    // zwei bis drei Anschlussfragen je nach Modus (lokal; Antippen fragt im selben Gespraech nach) in
                    // einer Reihe zum Wischen, damit sie der Antwort keine Zeilen nehmen
                    let followUps = Self.showsFollowUps(at: index, in: messages) ? AIFollowUps.suggest(after: msg.mode) : []
                    if !followUps.isEmpty {
                        AIChipRail {
                            ForEach(followUps) { s in
                                UFChip(text: s.label, icon: "sparkles") { input = s.question; Task { await send(mode: s.mode) } }
                                    .disabled(busy)
                                    .accessibilityIdentifier("tutor.followUp.\(s.mode)")
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                sourceLinks(msg.sources.filter { $0["cited"]?.bool == true })
            }
        }
    }

    @ViewBuilder private func sourceLinks(_ cited: [JSONValue]) -> some View {
        if !cited.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quellen").ufFont(12, 700).foregroundStyle(UF.muted)
                ForEach(cited.indices, id: \.self) { i in
                    let s = cited[i]
                    let p = Int(s["page"]?.double ?? 1)
                    // Lerntext aus Stud.IP (Courseware, Wiki, Forum): ohne Seite, Antippen oeffnet Stud.IP
                    let studip = s.s("studip_id") != nil
                    let label = "[\(Int(s["n"]?.double ?? 0))] \(s.s("title") ?? s.s("name") ?? "")" + (studip ? " (Stud.IP)" : ", Seite \(p)")
                    if studip {
                        if let u = s.s("url").flatMap(UFDayExtras.safeURL) {
                            Button { openURL(u) } label: { Text(label).ufFont(12.8).foregroundStyle(UF.accentText) }.buttonStyle(.plain)
                        } else {
                            Text(label).ufFont(12.8).foregroundStyle(UF.text2)
                        }
                    } else if (s.s("file_id") ?? fileID) == fileID {
                        Button { open(fileID, p) } label: { Text(label).ufFont(12.8).foregroundStyle(UF.accentText) }
                            .buttonStyle(.plain)
                    } else {
                        Text(label).ufFont(12.8).foregroundStyle(UF.text2)
                    }
                }
            }
        }
    }

    /// Bisheriges Gespraech fuer `history` (der Dienst nimmt die letzten Beitraege)
    static func history(_ messages: [Message]) -> JSONValue {
        .array(messages.suffix(AIPrompts.tutorHistoryTurns).map { m in
            ["role": .string(m.fromUser ? "user" : "assistant"),
             "text": .string(m.cards.isEmpty ? m.text : m.cards.map { "\($0.s("question") ?? "") – \($0.s("answer") ?? "")" }.joined(separator: "\n"))]
        })
    }

    /// Text, der im Verlauf fuer einen Schnellknopf steht; `force` = "Neu erklaeren lassen"
    static func label(mode: String, input: String, force: Bool = false) -> String {
        let name = modes.first { $0.key == mode }?.label ?? mode
        switch mode {
        case "ask": return input
        case "check": return "Lösung prüfen:\n" + input
        default: return input.isEmpty ? (force ? "\(name) (neu)" : name) : "\(name): \(input)"
        }
    }

    /// Senden moeglich: nichts laeuft und es gibt Text oder einen Anhang (beim Pruefen der Loesung immer Text)
    static func canSend(busy: Bool, input: String, attached: Bool, checking: Bool) -> Bool {
        let typed = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !busy && (typed || (attached && !checking))
    }

    /// Modus des Sendeknopfs: Loesung pruefen, freie Frage, oder mit Anhang ohne Frage "Erklären"
    static func composerMode(checking: Bool, input: String, attached: Bool) -> String {
        if checking { return "check" }
        return attached && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "explain" : "ask"
    }

    /// Rumpf von POST /api/ai/tutor: `selection` = markierter bzw. erkannter Text, `image` = Ausschnitt als JPEG
    /// (Base64, "Bereich an KI"; Vertrag wie app/server.py `ai.tutor_image`)
    static func requestBody(fileID: String, page: Int, mode: String, history: JSONValue, typed: String, selection: String,
                            image: Data?, force: Bool) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["file_id": .string(fileID), "page": .number(Double(page)), "mode": .string(mode), "history": history]
        if mode == "check" { body["own_solution"] = .string(typed) } else if !typed.isEmpty { body["question"] = .string(typed) }
        if !selection.isEmpty { body["selection"] = .string(String(selection.prefix(TutorAttachment.maxText))) }
        if let image, !image.isEmpty { body["image"] = .string(image.base64EncodedString()) }
        if force { body["force"] = true }
        return body
    }

    /// `force` ("Neu erklaeren lassen"): am Erklaerungsspeicher vorbei live fragen; die Antwort belegt den naechsten
    /// freien Platz oder bleibt lokal
    private func send(mode: String, selection given: String? = nil, force: Bool = false, docIntent: Bool = true) async {
        guard let api = session.api, !busy else { return }
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Wunsch fuers ganze Dokument im Eingabefeld ("Erkläre die ganze Vorlesung", "Löse alle Aufgaben", "Seiten 5 bis 12")
        if mode == "ask", docIntent, given == nil, attached == nil, DocExplain.parseIntent(typed) != nil {
            await startDoc(question: typed)
            return
        }
        // der Anhang (markierter Text, Bereich) geht mit, sofern kein Text aus "Text markieren" kommt
        let using = given == nil ? attached : nil
        let page = using?.page ?? page()
        var body = Self.requestBody(fileID: fileID, page: page, mode: mode, history: Self.history(messages), typed: typed,
                                    selection: given ?? using?.text ?? selection(), image: using?.image, force: force)
        if let t = Tab.tab(for: mode), t != tab, mode != "check" { tab = t }
        let quoted = given ?? using.flatMap { $0.text.isEmpty ? nil : $0.text }
        messages.append(Message(fromUser: true, text: Self.label(mode: mode, input: typed, force: force)
                                + (using?.image != nil ? "\n[\(using!.title) als Bild]" : "")
                                + (quoted.map { "\n„\(String($0.prefix(160)))\($0.count > 160 ? " …" : "")“" } ?? "")))
        input = ""
        if using != nil { attached = nil }
        if mode == "check" { checking = false }
        busy = true
        error = nil
        errorAction = nil
        defer { busy = false }
        do {
            // eigene Notizen zur Folie (Seitennotizen, Blatt daneben) als Kontext; der Dienst nutzt dann keinen
            // geteilten Erklaerungsspeicher
            if let ownNotes {
                let notes = await ownNotes()
                if !notes.isEmpty { body["own_notes"] = .string(notes) }
            }
            let r = try await api.value("/api/ai/tutor", method: "POST", body: .object(body))
            studoraAccount?.noteAIResponse(r)   // Credits-Stand und `charged` fuer die Fusszeile
            messages.append(Message(fromUser: false, text: r.s("answer") ?? "", cards: mode == "flashcards" ? r["cards"]?.array ?? [] : [],
                                    sources: r["sources"]?.array ?? [], mode: mode, explain: r["explain"].flatMap { $0.isNull ? nil : $0 }))
            // fuer "Zuletzt" auf KI-Start (lokal, je Container)
            if mode != "flashcards" { AIRecents.shared.record(question: Self.label(mode: mode, input: typed), answer: r.s("answer") ?? "", fileID: fileID) }
            persistConversation()
        } catch {
            // Frage ohne Antwort nicht im Verlauf lassen (ginge sonst doppelt mit), Eingabe und Anhang zurueck ins Feld
            if messages.last?.fromUser == true { messages.removeLast() }
            input = typed
            if let using { attached = using }
            if mode == "check" { checking = true }
            self.error = error.localizedDescription
            errorAction = StudoraAccountLink.errorAction(error, account: studoraAccount)
        }
        // die Sitzung kann waehrend der Anfrage das Modell gewechselt haben: Stand neu laden, die Fusszeile nennt es
        await chatgpt?.refresh()
    }

    // MARK: Ganzes Dokument

    /// Lauf vorbereiten: Plan holen (ohne KI); kostet er mehr als ein paar Credits bzw. Anfragen, fragt die Karte
    /// darunter vorher ("Kostet etwa 6 Credits, du hast 74"), sonst geht es gleich los
    private func startDoc(mode: String? = nil, question: String? = nil) async {
        guard let api = session.api, !busy, docRunner.phase != .running else { return }
        let scope = question == nil ? TutorDocRun.scopeJSON(docScope, from: docFrom, to: docTo) : nil
        if docRunner.phase == .confirm { docRunner.dismiss() }
        messages.append(Message(fromUser: true, text: question ?? TutorDocRun.userLabel(mode: mode ?? "lecture", scope: docScope, from: docFrom, to: docTo)))
        input = ""
        busy = true
        error = nil
        errorAction = nil
        do {
            let plan = try await docRunner.prepare(api: api, fileID: fileID, page: page(), mode: mode, scope: scope, question: question)
            busy = false
            guard plan != nil else {
                // keine Absicht erkannt: normale Frage zur Seite
                messages.removeLast()
                input = question ?? ""
                await send(mode: "ask", docIntent: false)
                return
            }
            if docRunner.phase == .confirm { return }
            await runDoc()
        } catch {
            busy = false
            if messages.last?.fromUser == true { messages.removeLast() }
            input = question ?? ""
            self.error = error.localizedDescription
            errorAction = StudoraAccountLink.errorAction(error, account: studoraAccount)
        }
    }

    /// Die Teile nacheinander holen; die Bloecke erscheinen nach und nach in einer Antwort des Gespraechs
    private func runDoc() async {
        guard let api = session.api, docRunner.plan != nil else { return }
        let mode = "doc_" + docRunner.mode
        let total = docRunner.steps.count
        messages.append(Message(fromUser: false, text: "", mode: mode, explain: TutorDocRun.marker(cached: 0, total: total)))
        var answerID = messages[messages.count - 1].id
        busy = true
        error = nil
        do {
            try await docRunner.run(api: api, note: { studoraAccount?.noteAIResponse($0) }) { blocks, cached, total in
                guard let i = messages.firstIndex(where: { $0.id == answerID }) else { return }
                messages[i] = Message(fromUser: false, text: TutorDocRun.markdown(blocks), mode: mode, explain: TutorDocRun.marker(cached: cached, total: total))
                answerID = messages[i].id
            }
        } catch {
            self.error = error.localizedDescription
            errorAction = StudoraAccountLink.errorAction(error, account: studoraAccount)
        }
        // nichts angekommen (Fehler im ersten Teil): keine leere Antwort stehen lassen
        if let i = messages.firstIndex(where: { $0.id == answerID }), messages[i].text.isEmpty { messages.remove(at: i) }
        busy = false
        persistConversation()
    }

    // MARK: Karteikarten nach Umfang

    /// Reiter "Karteikarten" (07.11.2026): "Diese Seite" fragt wie bisher zur Seite; "Ganzes Dokument" und "Seiten …"
    /// holen die Karten in Teilen ueber POST /api/ai/flashcards (`TutorCardsRun`), alle Karten in einer Antwort; der
    /// Nutzer sieht sie und speichert erst mit "Als Karteikarten speichern"
    private func startCards() async {
        guard let range0 = TutorCardsRun.range(scope: docScope, from: docFrom, to: docTo, pageCount: nil) else {
            await send(mode: "flashcards")
            return
        }
        guard let api = session.api, !busy, docRunner.phase != .running else { return }
        messages.append(Message(fromUser: true, text: TutorCardsRun.userLabel(scope: docScope, from: docFrom, to: docTo)))
        input = ""
        busy = true
        error = nil
        errorAction = nil
        defer { busy = false; cardsProgress = nil }
        // Seitenzahl aus der Bibliothek (ohne sie laufen die Teile bis zum erkannten Ende)
        let range = docScope == .document ? (TutorCardsRun.range(scope: .document, from: 1, to: 1, pageCount: await pageCount(api)) ?? range0) : range0
        let steps = TutorCardsRun.steps(from: range.lowerBound, to: range.upperBound)
        let counts = TutorCardsRun.counts(total: TutorCardsRun.count(pages: range.count), steps: steps.count)
        var cards: [JSONValue] = []
        var pages: [Int] = []
        var failure: Error?
        for (i, step) in steps.enumerated() {
            cardsProgress = TutorCardsRun.progress(step: i, total: steps.count, pages: step)
            do {
                let r = try await api.value("/api/ai/flashcards", method: "POST", body: TutorCardsRun.body(fileID: fileID, pages: step, count: counts[i]))
                studoraAccount?.noteAIResponse(r)
                let got = TutorCardsRun.pages(in: r)
                guard TutorCardsRun.accepted(got, requested: step) else { break }     // hinter dem Ende des Dokuments
                cards += r["cards"]?.array ?? []
                pages += got
                if !TutorCardsRun.continues(after: got, requested: step) { break }
            } catch {
                failure = error
                break
            }
        }
        if !cards.isEmpty {
            messages.append(Message(fromUser: false, text: TutorCardsRun.answerText(cards: cards.count, pages: pages), cards: cards, mode: "flashcards"))
            persistConversation()
        } else if messages.last?.fromUser == true {
            messages.removeLast()
        }
        if let failure {
            // Teile davor bleiben stehen; der Fehler steht darunter
            self.error = failure.localizedDescription
            errorAction = StudoraAccountLink.errorAction(failure, account: studoraAccount)
        } else if cards.isEmpty {
            self.error = "In diesem Bereich gibt es keine Seiten mit Text."
        }
        await chatgpt?.refresh()
    }

    /// Seitenzahl des Dokuments aus der Bibliothek (`page_count`); nil, wenn sie dort fehlt
    private func pageCount(_ api: APIClient) async -> Int? {
        guard let lib = try? await api.value("/api/library") else { return nil }
        let n = lib.list("files").first { $0.s("id") == fileID }?.i("page_count") ?? 0
        return n > 0 ? n : nil
    }

    /// Gemerktes Gespraech laden, solange hier noch keins laeuft
    private func restoreConversation() {
        guard messages.isEmpty else { return }
        messages = Self.restored(TutorConversations.shared.messages(for: fileID))
    }

    /// Stand nach jeder Antwort, "Neu" und gespeicherten Karten merken (leer = Gespraech entfernen)
    private func persistConversation() {
        TutorConversations.shared.save(fileID: fileID, fileName: fileName, messages: Self.stored(messages))
    }

    /// Beitraege fuer die Datei und zurueck (reine Umwandlung, UniFlowTests/TutorConversationsAppTests.swift)
    static func stored(_ ms: [Message]) -> [TutorConversations.Message] {
        ms.map { .init(fromUser: $0.fromUser, text: $0.text, cards: $0.cards, sources: $0.sources, saved: $0.saved, mode: $0.mode, explain: $0.explain) }
    }

    static func restored(_ ms: [TutorConversations.Message]) -> [Message] {
        ms.map { Message(fromUser: $0.fromUser, text: $0.text, cards: $0.cards, sources: $0.sources, saved: $0.saved, mode: $0.mode, explain: $0.explain) }
    }

    private func saveCards(_ m: Binding<Message>) async {
        guard let api = session.api, !m.wrappedValue.cards.isEmpty else { return }
        do {
            _ = try await api.value("/api/flashcards", method: "POST", body: ["file_id": .string(fileID), "cards": .array(m.wrappedValue.cards)])
            m.wrappedValue.saved = true
            persistConversation()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Kopf der KI-Hilfe (flach, 07.11.2026 nach dem Foto vom iPad: die Knoepfe stapelten sich ueber sechs Zeilen und die
/// Antwort blieb klein): die drei Reiter kompakt in einer Zeile (zu schmal: ohne Symbole, bei sehr grosser Schrift
/// untereinander), im Reiter Erklären darunter der Umfang als Segmente und EINE Reihe Aktionen zum seitlichen Wischen
/// (`AIChipRail`): vorn "Ganze Vorlesung erklären" und "Alle Aufgaben erklären", dann die Modi des Reiters. Eigener
/// Baustein, damit ein Test seine Hoehe misst (UniFlowTests/TutorHeadAppTests.swift: unter 260 pt bei 640 pt Breite).
/// Alle Kennungen (tutor.tabs, tutor.tab.*, tutor.scope, tutor.doc.*, tutor.mode.*, tutor.weeklyTest) wie zuvor.
struct TutorPanelHead: View {
    @Binding var tab: TutorPanel.Tab
    @Binding var scope: TutorDocScope
    @Binding var from: Int
    @Binding var to: Int
    let busy: Bool
    /// "Lösung prüfen" ist an: der Chip erscheint gefuellt
    let checking: Bool
    /// ein Modus wurde angetippt (explain, steps, check, flashcards, similar …); die Leiste entscheidet, was passiert
    let mode: (String) -> Void
    /// Lauf fuer das Dokument (lecture, tasks)
    let doc: (String) -> Void
    /// Karteikarten im gewaehlten Umfang (Seite, ganzes Dokument, Seiten …)
    let cards: () -> Void
    let weeklyTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                AISpreadRow(spacing: 6) { tabButtons(icons: true) }
                AISpreadRow(spacing: 6) { tabButtons(icons: false) }
                VStack(spacing: 6) { tabButtons(icons: true) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Bereiche der KI-Hilfe")
            .accessibilityIdentifier("tutor.tabs")
            actions
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
        .background(UF.surface)
        .ufBorderBottom()
    }

    @ViewBuilder private func tabButtons(icons: Bool) -> some View {
        ForEach(TutorPanel.Tab.allCases) { t in
            AITabButton(title: t.title, icon: icons ? t.icon : nil, pair: t.pair, selected: tab == t, compact: true) {
                withAnimation(UF.transition) { tab = t }
            }
            .accessibilityIdentifier("tutor.tab.\(t.rawValue)")
        }
    }

    @ViewBuilder private var actions: some View {
        switch tab {
        case .explain:
            TutorDocControls(scope: $scope, from: $from, to: $to)
            AIChipRail {
                TutorDocChips(busy: busy) { doc($0) }
                ForEach(TutorPanel.Tab.explain.modes, id: \.self) { key in modeChip(key, icon: key == "explain" ? "sparkles" : nil) }
            }
        case .cards:
            // derselbe Umfang wie beim Erklaeren (07.11.2026: vorher nahm der Reiter immer nur die offene Seite)
            TutorDocControls(scope: $scope, from: $from, to: $to)
            AIChipRail {
                AIModeChip(text: TutorCardsRun.chipLabel(scope: scope, from: from, to: to), icon: "cards", pair: TutorPanel.Tab.cards.pair) { cards() }
                    .disabled(busy)
                    .accessibilityIdentifier("tutor.mode.flashcards")
                Text("Du siehst jede Karte, bevor sie gespeichert wird.").ufFont(12, lh: 1.3).foregroundStyle(UF.muted)
            }
        case .test:
            AIChipRail {
                modeChip("similar", icon: "refresh")
                modeChip("check", icon: "check")
                AIModeChip(text: "Wochentest erstellen", icon: "exam", pair: TutorPanel.Tab.test.pair) { weeklyTest() }
                    .accessibilityIdentifier("tutor.weeklyTest")
            }
        }
    }

    private func modeChip(_ key: String, icon: String?) -> some View {
        let label = TutorPanel.modes.first { $0.key == key }?.label ?? key
        return AIModeChip(text: label, icon: icon, pair: (TutorPanel.Tab.tab(for: key) ?? .explain).pair, on: key == "check" && checking) { mode(key) }
            .disabled(busy)
            .accessibilityIdentifier("tutor.mode.\(key)")
    }
}

/// Warum die KI-Hilfe noch nicht fragen kann, mit dem passenden Knopf direkt in der Leiste. "Verbunden" allein reicht
/// nicht: Freigabe, Schalter "KI-Anfragen", ein Modell und eine gueltige Anmeldung gehoeren dazu (`enabledForAI`).
struct TutorConnectState: View {
    @ObservedObject var link: ChatGPTLink
    let openSettings: () -> Void
    @State private var busy = false
    @Environment(\.ufAIAccess) private var access

    /// `signIn`: Pro AI bzw. Probe, aber nicht beim StudiNow-Konto angemeldet (StudiNow-KI wartet auf die Anmeldung)
    enum Reason: Equatable { case notConnected, signIn, reauth, noSharing, switchedOff, noModel, ready }

    static func reason(_ s: ChatGPTSession.Status?, enabled: Bool = ChatGPTLink.isEnabled, access: StudiNowAIAccess = .planRequired) -> Reason {
        // ausgeschaltet (`ChatGPTLink.isEnabled`): auch eine alte Verbindung bietet kein "Neu verbinden" an
        guard enabled, let s, s.connected else { return access == .signInRequired ? .signIn : .notConnected }
        if s.needsReauth { return .reauth }
        if !s.sharing { return .noSharing }
        if !s.useForAI { return .switchedOff }
        if s.model.isEmpty { return .noModel }
        return .ready
    }

    var body: some View {
        let reason = Self.reason(link.status, access: access)
        Content(reason: reason, message: link.message, busy: busy || link.connecting, fix: fix(reason), openSettings: openSettings)
            .task {
                await link.refresh()
                if Self.reason(link.status) == .noModel { await link.loadModels() }   // waehlt das erste Modell
            }
    }

    private func fix(_ r: Reason) -> (() -> Void)? {
        let run: (@escaping () async -> Void) -> () -> Void = { work in
            { Task { busy = true; await work(); busy = false } }
        }
        switch r {
        case .reauth: return run { await link.connect() }
        case .noSharing: return run { await link.connect(reconsent: true) }
        case .switchedOff: return run { await link.setUseForAI(true) }
        case .noModel: return run { await link.loadModels() }
        case .notConnected, .signIn, .ready: return nil
        }
    }

    struct Content: View {
        let reason: Reason
        let message: String?
        let busy: Bool
        let fix: (() -> Void)?
        let openSettings: () -> Void

        static func text(_ r: Reason) -> (info: String, action: String?) {
            switch r {
            case .notConnected:
                // ohne Freigabe durch OpenAI kein "Verbinde dein ChatGPT" (die Anmeldung hinge), sondern der Tarif-Hinweis
                guard ChatGPTLink.isEnabled else { return (ChatGPTLink.planHint, nil) }
                return ("Verbinde dein ChatGPT, dann kannst du hier Fragen zur Seite stellen, Aufgaben lösen lassen, Hinweise bekommen und deine Lösung prüfen.", nil)
            case .signIn: return (StudoraAccountLink.aiSignInHint, nil)
            case .reauth: return ("Die Anmeldung bei ChatGPT ist abgelaufen.", "Neu verbinden")
            case .noSharing: return ("ChatGPT ist verbunden, aber die Freigabe für dein Abo fehlt. Ohne sie laufen keine Anfragen.", "Freigabe nachholen")
            case .switchedOff: return ("ChatGPT ist verbunden, aber „KI-Anfragen über mein ChatGPT“ ist ausgeschaltet.", "Einschalten")
            case .noModel: return ("ChatGPT ist verbunden, StudiNow richtet es gerade ein.", "Erneut versuchen")
            case .ready: return ("ChatGPT ist bereit.", nil)
            }
        }

        /// Knopf unter dem Hinweis: "ChatGPT verbinden" nur mit `ChatGPTLink.isEnabled`, sonst der Weg zu den Tarifen
        static func buttonTitle(_ r: Reason) -> String {
            if r == .signIn { return "Mit StudiNow-Konto anmelden" }
            guard r == .notConnected else { return "Einstellungen öffnen" }
            return ChatGPTLink.isEnabled ? "ChatGPT verbinden" : "Tarife ansehen"
        }

        var body: some View {
            let t = Self.text(reason)
            VStack(alignment: .leading, spacing: 12) {
                Text(t.info).ufFont(13.76).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tutor.state")
                if let action = t.action, let fix {
                    UFButton(busy ? "Einen Moment …" : action, icon: "sparkles", kind: .primary) { fix() }
                        .disabled(busy).accessibilityIdentifier("tutor.fix")
                }
                if let message {
                    Text(message).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                }
                UFButton(Self.buttonTitle(reason), icon: reason == .signIn ? "user" : reason == .notConnected && !ChatGPTLink.isEnabled ? "star" : "settings",
                         kind: reason == .notConnected || reason == .signIn ? .primary : .normal) { openSettings() }
                    .accessibilityIdentifier("tutor.connect")
                Spacer()
            }
            .padding(16)
        }
    }
}

/// Anhang im Eingabefeld der KI-Hilfe (05.11.2026): Bild des Bereichs als Vorschau, Titel mit Seite, Anfang des
/// (erkannten) Texts; entfernen, als Bild teilen, Bild oder Text kopieren (z. B. in eine Notiz einfuegen)
struct TutorAttachmentCard: View {
    let attachment: TutorAttachment
    /// iPhone (KI-Hilfe als Blatt von unten): flacher Chip mit kleinem Bild und einer Textzeile, damit Eingabefeld
    /// und Antwort im halben Blatt Platz behalten; Knoepfe 44 pt
    var chip = false
    let remove: () -> Void

    init(attachment: TutorAttachment, chip: Bool = false, remove: @escaping () -> Void) {
        self.attachment = attachment
        self.chip = chip
        self.remove = remove
    }

    private var image: UIImage? { attachment.image.flatMap(UIImage.init(data:)) }

    var body: some View {
        HStack(alignment: chip ? .center : .top, spacing: 10) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: chip ? 52 : 88, maxHeight: chip ? 40 : 66)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UF.lineStrong, lineWidth: 1))
                    .accessibilityLabel("Vorschau des Bereichs")
                    .accessibilityIdentifier("tutor.attachment.image")
            } else {
                UFIcon("text-select", size: 16).foregroundStyle(UF.accent).padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.title).ufFont(12.8, 650, lh: 1.3).foregroundStyle(UF.text)
                    .accessibilityIdentifier("tutor.attachment.title")
                Text(attachment.text.isEmpty ? "Kein Text erkannt – das Bild geht mit." : attachment.text)
                    .ufFont(12.16, lh: 1.4).foregroundStyle(UF.muted).lineLimit(chip ? 1 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tutor.attachment.text")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                if let image {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(attachment.title, image: Image(uiImage: image))) {
                        Label("Als Bild teilen", systemImage: "square.and.arrow.up")
                    }
                    Button { UIPasteboard.general.image = image } label: { Label("Bild kopieren (für eine Notiz)", systemImage: "doc.on.doc") }
                }
                if !attachment.text.isEmpty {
                    Button { UIPasteboard.general.string = attachment.text } label: { Label("Text kopieren", systemImage: "doc.on.clipboard") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17)).frame(width: chip ? 44 : 32, height: chip ? 44 : 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Mehr zum Anhang")
            .accessibilityIdentifier("tutor.attachment.more")
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(UF.muted)
                    .frame(width: chip ? 44 : 32, height: chip ? 44 : 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Anhang entfernen")
            .accessibilityIdentifier("tutor.attachment.remove")
        }
        .padding(chip ? 6 : 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(UF.surface2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tutor.attachment")
    }
}
