import SwiftUI
import UniFlowCore

/// KI-Hilfe im Editor als Seitenleiste neben der PDF (`POST /api/ai/tutor`): ein Gespraech zur offenen Seite mit freier
/// Frage und Schnellknoepfen fuer die Modi aus `ai.TUTOR_MODES` (Aufgabe loesen, Hinweise, Loesung pruefen ...).
/// Rueckfragen schicken die letzten Beitraege als `history` mit, markierter PDF-Text geht als `selection` mit. Antworten
/// mit Quellen aus den eigenen Unterlagen ([n] -> Seite). Laeuft ueber das ChatGPT-Abo des Nutzers (lokales Backend,
/// `LocalContext.ai`); gesendet wird nur nach dem Antippen. Ohne verbundene KI erklaert die Leiste den Weg dorthin.
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
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufChatGPTLink) private var chatgpt
    @Environment(\.ufStudoraAccount) private var studoraAccount
    @Environment(\.openURL) private var openURL

    /// Alle Modi in der Reihenfolge von `ai.TUTOR_MODES`; "ask" ist das Eingabefeld, die anderen sind Schnellknoepfe
    static let modes: [(key: String, label: String)] = [
        ("ask", "Frage"), ("explain", "Erklären"), ("explain_simple", "Einfach erklären"), ("summary", "Zusammenfassen"),
        ("steps", "Aufgabe lösen"), ("hints", "Nur Hinweise"), ("check", "Lösung prüfen"), ("similar", "Ähnliche Aufgabe"),
        ("terms", "Fachbegriffe"), ("flashcards", "Karteikarten"),
    ]

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

    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var checking = false
    @State private var busy = false
    @State private var error: String?
    /// 429 `credits_exhausted` des Dienstes: unter der Meldung der Weg zum Tarif
    @State private var creditsExhausted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if aiEnabled { conversation } else { notConnected }
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

    /// Kopf wie die anderen Spalten neben der PDF (UFPaneHeader); "Neu" als ruhiger Textknopf
    private var header: some View {
        UFPaneHeader("KI-Hilfe", icon: "sparkles", closeLabel: "KI-Hilfe schließen", closeID: "tutor.close", close: close) {
            // KI-Start (03.11.2026): Fragen, Karteikarten, Erklären, Wochentest auf einer Seite
            UFButton(icon: "grid", kind: .ghost, size: .small) { router.go(.aiStart) }
                .accessibilityLabel("KI-Start öffnen").accessibilityIdentifier("tutor.aiStart")
            if !messages.isEmpty {
                UFButton("Neu", kind: .ghost, size: .small) { messages = []; error = nil; persistConversation() }
                    .disabled(busy).accessibilityIdentifier("tutor.reset")
            }
        }
    }

    /// Ohne KI: der Weg zur Verbindung - und darueber, was die Bibliothek zur offenen Seite schon weiss (lesen darf
    /// jeder, 0 Credits; die Karte bleibt leer, wenn der Index die Seite nicht kennt)
    @ViewBuilder private var notConnected: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) { DocIndexPageCard(fileID: fileID, page: page, open: open) }
                .padding(.horizontal, 14).padding(.top, 14)
            if let chatgpt {
                TutorConnectState(link: chatgpt) { router.go(.settings(tab: "advanced")) }
            } else {
                TutorConnectState.Content(reason: .notConnected, message: nil, busy: false, fix: nil) { router.go(.settings(tab: "advanced")) }
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Dokument-Index: schon erklaerte Seite sofort, 0 Credits (DocIndexPageCard)
                        DocIndexPageCard(fileID: fileID, page: page, open: open)
                        if messages.isEmpty {
                            // Leerzustand als Einladung: was die Leiste kann, in der Schrift des Gespraechs
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Frag etwas zur offenen Seite").ufFont(14.5, 650).foregroundStyle(UF.text)
                                Text("Oder tipp unten auf eine Aktion. Markierter Text wird mitgeschickt.")
                                    .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        ForEach($messages) { $m in bubble($m).id(m.id) }
                        if busy {
                            HStack(spacing: 8) { ProgressView(); UFShimmerText("Die KI liest die Seite …") }   // dezenter Schimmer (text-shimmer)
                                .id("busy")
                        }
                        if let error {
                            Text(error).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("tutor.error")
                            if creditsExhausted {
                                UFButton("Tarif ansehen", icon: "star", size: .small) { router.go(.settings(tab: "account")) }
                                    .accessibilityIdentifier("tutor.plans")
                            }
                        }
                    }
                    .padding(14)
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(busy ? "busy" : messages.last?.id as AnyHashable?, anchor: .bottom) }
                }
                .onChange(of: busy) { _, now in
                    if now { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } }
                }
            }
            Rectangle().fill(UF.line).frame(height: 1)
            composer
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.modes.filter { $0.key != "ask" }, id: \.key) { m in
                        UFChip(text: m.label, on: m.key == "check" && checking) {
                            if m.key == "check" { checking.toggle() } else { Task { await send(mode: m.key) } }
                        }
                        .disabled(busy)
                        .accessibilityIdentifier("tutor.mode.\(m.key)")
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                UFTextArea(placeholder: checking ? "Deine Lösung oder deinen Rechenweg eintragen" : "Frage stellen, z. B. Wie löse ich Aufgabe 2?",
                           text: $input, minHeight: 44)
                    .accessibilityIdentifier("tutor.input")
                UFButton(nil, icon: "arrow-right", kind: .primary) { Task { await send(mode: checking ? "check" : "ask") } }
                    .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(checking ? "Lösung prüfen" : "Senden")
                    .accessibilityIdentifier("tutor.ask")
            }
            Text(Self.footer(page: page(), model: chatgpt?.status?.model, credits: studoraAccount?.credits, charge: studoraAccount?.lastCharge,
                             adopted: Self.storedLabel(messages.last?.explain) != nil, trial: studoraAccount?.planStatus?.trialActive ?? false))
                .ufFont(11.5).foregroundStyle(UF.muted)
                .accessibilityIdentifier("tutor.footer")
        }
        .padding(12)
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

    @ViewBuilder private func bubble(_ m: Binding<Message>) -> some View {
        let msg = m.wrappedValue
        if msg.fromUser {
            HStack {
                Spacer(minLength: 30)
                Text(msg.text).ufFont(13.76).foregroundStyle(UF.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(UF.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !msg.cards.isEmpty {
                    ForEach(msg.cards.indices, id: \.self) { i in
                        UFCard {
                            Text(msg.cards[i].s("question") ?? "").ufFont(13.76, 650).foregroundStyle(UF.text)
                            Text(msg.cards[i].s("answer") ?? "").ufFont(13.12).foregroundStyle(UF.text2)
                        }
                    }
                    UFButton(msg.saved ? "In Karteikarten gespeichert" : "Als Karteikarten speichern", icon: "cards", size: .small) {
                        Task { await saveCards(m) }
                    }
                    .disabled(msg.saved)
                } else {
                    // Markdown (Ueberschriften, Aufzaehlungen, Fett) in den Schriften des Designsystems
                    AIMarkdownText(msg.text).accessibilityIdentifier("tutor.answer")
                    // gespeicherte Antwort (Erklaerungsspeicher): Herkunft und der Weg zu einer frischen Antwort
                    if let stored = Self.storedLabel(msg.explain) {
                        HStack(spacing: 6) {
                            UFIcon("check", size: 13).foregroundStyle(UF.ok)
                            Text(stored).ufFont(12).foregroundStyle(UF.muted)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("tutor.stored")
                        UFButton("Neu erklären lassen", icon: "refresh", kind: .ghost, size: .small) { Task { await send(mode: msg.mode, force: true) } }
                            .disabled(busy)
                            .accessibilityIdentifier("tutor.rebuild")
                    }
                    // zwei bis drei Anschlussfragen je nach Modus (lokal; Antippen fragt im selben Gespraech nach)
                    let followUps = AIFollowUps.suggest(after: msg.mode)
                    if !followUps.isEmpty {
                        UFFlexWrap(gap: 6, rowGap: 6) {
                            ForEach(followUps) { s in
                                UFChip(text: s.label, icon: "sparkles") { input = s.question; Task { await send(mode: s.mode) } }
                                    .disabled(busy)
                                    .accessibilityIdentifier("tutor.followUp.\(s.mode)")
                            }
                        }
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
