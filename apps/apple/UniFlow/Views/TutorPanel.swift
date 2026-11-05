import SwiftUI
import UniFlowCore

/// KI-Hilfe im Editor als Seitenleiste neben der PDF (`POST /api/ai/tutor`): ein Gespraech zur offenen Seite mit freier
/// Frage und den Modi aus `ai.TUTOR_MODES`. Neugestaltung 04.11.2026 (Vorbild-Vergleich): oben drei farbige Reiter
/// "Erklären" (gruen), "Karteikarten" (orange), "Test" (blau), darunter die Aktionen des Reiters (`Tab.modes`); Antworten
/// als Markdown mit grossen Abschnittstiteln, Fragen als Blasen rechts; das Eingabefeld unten fest, die Kostenzeile klein
/// darunter. Rueckfragen schicken die letzten Beitraege als `history` mit, markierter PDF-Text geht als `selection` mit.
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
    /// Modul des Dokuments fuer "Wochentest erstellen" im Reiter Test (nil: der Dialog fragt nach dem Modul)
    var moduleID: Int? = nil
    /// Kompakt (iPhone): die Leiste liegt als Blatt von unten ueber dem Dokument. Wege aus der Leiste (KI-Start,
    /// Einstellungen, Tarif) und der Dialog "Wochentest erstellen" schliessen das Blatt zuerst; sonst laege der Dialog
    /// unter dem Blatt bzw. ein zweites Blatt kaeme nicht
    var inSheet = false
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufChatGPTLink) private var chatgpt
    @Environment(\.ufStudoraAccount) private var studoraAccount
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

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
    @State private var creditsExhausted = false
    @State private var tab: Tab = .explain
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if aiEnabled {
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
        .onChange(of: fileID) { _, _ in messages = []; error = nil; restoreConversation() }
        .task(id: request.wrappedValue?.id) {
            guard aiEnabled, let r = request.wrappedValue else { return }
            request.wrappedValue = nil
            await send(mode: r.mode, selection: r.selection)
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

    /// Drei Reiter in einer Reihe (zu schmal: ohne Symbole, bei sehr grosser Schrift untereinander), darunter die
    /// Aktionen des gewaehlten Reiters
    private var tabBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                AISpreadRow(spacing: 6) { tabButtons(icons: true) }
                AISpreadRow(spacing: 6) { tabButtons(icons: false) }
                VStack(spacing: 6) { tabButtons(icons: true) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Bereiche der KI-Hilfe")
            .accessibilityIdentifier("tutor.tabs")
            tabActions
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 12)
        .background(UF.surface)
        .ufBorderBottom()
    }

    @ViewBuilder private func tabButtons(icons: Bool) -> some View {
        ForEach(Tab.allCases) { t in
            AITabButton(title: t.title, icon: icons ? t.icon : nil, pair: t.pair, selected: tab == t) {
                withAnimation(UF.transition) { tab = t }
            }
            .accessibilityIdentifier("tutor.tab.\(t.rawValue)")
        }
    }

    @ViewBuilder private var tabActions: some View {
        switch tab {
        case .explain:
            if typeSize.isAccessibilitySize {
                // sehr grosse Schrift: eine Reihe zum seitlichen Schieben, damit das Gespraech Platz behaelt
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Tab.explain.modes, id: \.self) { key in modeChip(key, icon: key == "explain" ? "sparkles" : nil) }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    ForEach(Tab.explain.modes, id: \.self) { key in modeChip(key, icon: key == "explain" ? "sparkles" : nil) }
                }
            }
        case .cards:
            VStack(alignment: .leading, spacing: 8) {
                Text("Karten aus der offenen Seite – du siehst jede Karte, bevor sie gespeichert wird.")
                    .ufFont(12.8, lh: 1.4).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                AIModeChip(text: "Karteikarten zur Seite erstellen", icon: "cards", pair: Tab.cards.pair) { Task { await send(mode: "flashcards") } }
                    .disabled(busy)
                    .accessibilityIdentifier("tutor.mode.flashcards")
            }
        case .test:
            UFFlexWrap(gap: 6, rowGap: 6) {
                modeChip("similar", icon: "refresh")
                modeChip("check", icon: "check")
                AIModeChip(text: "Wochentest erstellen", icon: "exam", pair: Tab.test.pair) {
                    afterSheet { overlay.modal { QuizComposer(moduleID: moduleID ?? 0) } }
                }
                .accessibilityIdentifier("tutor.weeklyTest")
            }
        }
    }

    /// Knopf eines Modus: sendet sofort; "Lösung prüfen" schaltet stattdessen das Eingabefeld um
    private func modeChip(_ key: String, icon: String?) -> some View {
        let label = Self.modes.first { $0.key == key }?.label ?? key
        return AIModeChip(text: label, icon: icon, pair: (Tab.tab(for: key) ?? .explain).pair, on: key == "check" && checking) {
            if key == "check" {
                checking.toggle()
                if checking { inputFocused = true }
            } else {
                Task { await send(mode: key) }
            }
        }
        .disabled(busy)
        .accessibilityIdentifier("tutor.mode.\(key)")
    }

    /// Ohne KI: der Weg zur Verbindung - und darueber, was die Bibliothek zur offenen Seite schon weiss (lesen darf
    /// jeder, 0 Credits; die Karte bleibt leer, wenn der Index die Seite nicht kennt)
    @ViewBuilder private var notConnected: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) { DocIndexPageCard(fileID: fileID, page: page, open: open) }
                .padding(.horizontal, 14).padding(.top, 14)
            if let chatgpt {
                TutorConnectState(link: chatgpt) { leave(.settings(tab: "advanced")) }
            } else {
                TutorConnectState.Content(reason: .notConnected, message: nil, busy: false, fix: nil) { leave(.settings(tab: "advanced")) }
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
                        if busy {
                            HStack(spacing: 8) { ProgressView(); UFShimmerText("Die KI liest die Seite …") }   // dezenter Schimmer (text-shimmer)
                                .id("busy")
                        }
                        if let error {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(error).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("tutor.error")
                                if creditsExhausted {
                                    UFButton("Tarif ansehen", icon: "star", size: .small) { leave(.settings(tab: "account")) }
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
            AIComposer(placeholder: checking ? "Deine Lösung oder deinen Rechenweg eintragen" : "Frag etwas zur Seite …",
                       text: $input, focused: $inputFocused,
                       canSend: !busy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       sendLabel: checking ? "Lösung prüfen" : "Senden", inputID: "tutor.input", sendID: "tutor.ask",
                       send: { Task { await send(mode: checking ? "check" : "ask") } }) {
                if checking {
                    Button { checking = false } label: {
                        AIComposerPill(icon: "check", text: "Lösung prüfen", tint: Tab.test.pair.fg, fill: Tab.test.pair.bg)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Lösung prüfen beenden")
                    .accessibilityIdentifier("tutor.check.off")
                }
            }
            Text(Self.footer(page: page(), model: chatgpt?.status?.model, credits: studoraAccount?.credits, charge: studoraAccount?.lastCharge,
                             adopted: Self.storedLabel(messages.last?.explain) != nil, trial: studoraAccount?.planStatus?.trialActive ?? false))
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
    static func footer(page: Int, model: String?, credits: StudoraCredits? = nil, charge: StudoraCredits.Charge? = nil,
                       adopted: Bool = false, trial: Bool = false) -> String {
        let m = (model ?? "").trimmingCharacters(in: .whitespaces)
        let way = credits != nil
            ? AICost.creditsLine(credits: credits, chatgpt: charge == nil && !adopted, adopted: adopted, charge: charge, trial: trial) ?? "über dein ChatGPT"
            : "über dein ChatGPT"
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
                            Text(msg.cards[i].s("question") ?? "").ufFont(14.5, 650, lh: 1.4).foregroundStyle(UF.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(msg.cards[i].s("answer") ?? "").ufFont(13.76, lh: 1.5).foregroundStyle(UF.text2)
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
                    AIMarkdownText(msg.text, size: 14.5).accessibilityIdentifier("tutor.answer")
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
                    // zwei bis drei Anschlussfragen je nach Modus (lokal; Antippen fragt im selben Gespraech nach)
                    let followUps = Self.showsFollowUps(at: index, in: messages) ? AIFollowUps.suggest(after: msg.mode) : []
                    if !followUps.isEmpty {
                        UFFlexWrap(gap: 6, rowGap: 6) {
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

    /// `force` ("Neu erklaeren lassen"): am Erklaerungsspeicher vorbei live fragen; die Antwort belegt den naechsten
    /// freien Platz oder bleibt lokal
    private func send(mode: String, selection given: String? = nil, force: Bool = false) async {
        guard let api = session.api, !busy else { return }
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = page(), selection = given ?? selection()
        var body: [String: JSONValue] = ["file_id": .string(fileID), "page": .number(Double(page)), "mode": .string(mode),
                                         "history": Self.history(messages)]
        if mode == "check" { body["own_solution"] = .string(typed) } else if !typed.isEmpty { body["question"] = .string(typed) }
        if !selection.isEmpty { body["selection"] = .string(selection) }
        if force { body["force"] = true }
        if let t = Tab.tab(for: mode), t != tab, mode != "check" { tab = t }
        messages.append(Message(fromUser: true, text: Self.label(mode: mode, input: typed, force: force)
                                + (given.map { "\n„\(String($0.prefix(160)))\($0.count > 160 ? " …" : "")“" } ?? "")))
        input = ""
        if mode == "check" { checking = false }
        busy = true
        error = nil
        creditsExhausted = false
        defer { busy = false }
        do {
            let r = try await api.value("/api/ai/tutor", method: "POST", body: .object(body))
            studoraAccount?.noteAIResponse(r)   // Credits-Stand und `charged` fuer die Fusszeile
            messages.append(Message(fromUser: false, text: r.s("answer") ?? "", cards: mode == "flashcards" ? r["cards"]?.array ?? [] : [],
                                    sources: r["sources"]?.array ?? [], mode: mode, explain: r["explain"].flatMap { $0.isNull ? nil : $0 }))
            // fuer "Zuletzt" auf KI-Start (lokal, je Container)
            if mode != "flashcards" { AIRecents.shared.record(question: Self.label(mode: mode, input: typed), answer: r.s("answer") ?? "", fileID: fileID) }
            persistConversation()
        } catch {
            // Frage ohne Antwort nicht im Verlauf lassen (ginge sonst doppelt mit), Eingabe zurueck ins Feld
            if messages.last?.fromUser == true { messages.removeLast() }
            input = typed
            if mode == "check" { checking = true }
            self.error = error.localizedDescription
            creditsExhausted = studoraAccount?.noteAIError(error) ?? StudoraCredits.isExhausted(error)
        }
        // die Sitzung kann waehrend der Anfrage das Modell gewechselt haben: Stand neu laden, die Fusszeile nennt es
        await chatgpt?.refresh()
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

/// Warum die KI-Hilfe noch nicht fragen kann, mit dem passenden Knopf direkt in der Leiste. "Verbunden" allein reicht
/// nicht: Freigabe, Schalter "KI-Anfragen", ein Modell und eine gueltige Anmeldung gehoeren dazu (`enabledForAI`).
struct TutorConnectState: View {
    @ObservedObject var link: ChatGPTLink
    let openSettings: () -> Void
    @State private var busy = false

    enum Reason: Equatable { case notConnected, reauth, noSharing, switchedOff, noModel, ready }

    static func reason(_ s: ChatGPTSession.Status?) -> Reason {
        guard let s, s.connected else { return .notConnected }
        if s.needsReauth { return .reauth }
        if !s.sharing { return .noSharing }
        if !s.useForAI { return .switchedOff }
        if s.model.isEmpty { return .noModel }
        return .ready
    }

    var body: some View {
        let reason = Self.reason(link.status)
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
        case .notConnected, .ready: return nil
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
            case .notConnected: return ("Verbinde dein ChatGPT, dann kannst du hier Fragen zur Seite stellen, Aufgaben lösen lassen, Hinweise bekommen und deine Lösung prüfen.", nil)
            case .reauth: return ("Die Anmeldung bei ChatGPT ist abgelaufen.", "Neu verbinden")
            case .noSharing: return ("ChatGPT ist verbunden, aber die Freigabe für dein Abo fehlt. Ohne sie laufen keine Anfragen.", "Freigabe nachholen")
            case .switchedOff: return ("ChatGPT ist verbunden, aber „KI-Anfragen über mein ChatGPT“ ist ausgeschaltet.", "Einschalten")
            case .noModel: return ("ChatGPT ist verbunden, StudiNow richtet es gerade ein.", "Erneut versuchen")
            case .ready: return ("ChatGPT ist bereit.", nil)
            }
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
                UFButton(reason == .notConnected ? "ChatGPT verbinden" : "Einstellungen öffnen", icon: "settings",
                         kind: reason == .notConnected ? .primary : .normal) { openSettings() }
                    .accessibilityIdentifier("tutor.connect")
                Spacer()
            }
            .padding(16)
        }
    }
}
