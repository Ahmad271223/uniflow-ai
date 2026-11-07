import SwiftUI
import UniFlowCore

/// "Karteikarten aus Dokument" (03.11.2026): Modul und Dokument waehlen, Seiten und Zahl der Karten, optional ein
/// Schwerpunkt; `POST /api/ai/flashcards` schlaegt Karten vor (KI des Nutzers, Schema `AIPrompts.flashcardsSchema`),
/// die Vorschau laesst jede Karte aendern oder streichen, "Übernehmen" speichert mit `POST /api/flashcards`
/// (source = Dokument, Fach aus dessen Kurs). Die Karten landen in einem Stapel (04.11.2026): ein vorhandener Stapel
/// des Moduls oder ein neuer mit Namen, Vorgabe "Neuer Stapel …" mit dem Titel des Dokuments (`stack_name`; der
/// Server nimmt einen gleichnamigen Stapel des Fachs, sonst legt er ihn mit dem Dokument als Quelle an). Ohne PC nur
/// mit Plus (Sperrkarte wie die Karteikarten-Seite), ohne verbundene KI der Weg dorthin. Gesendet wird nur nach dem Antippen.
struct FlashcardComposer: View {
    let initialModuleID: Int
    let initialFileID: String?
    @ObservedObject private var ent: Entitlements
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufAIAccess) private var aiAccess
    @Environment(\.ufChatGPTLink) private var chatgpt
    @Environment(\.ufWindowWidth) private var windowWidth
    @State private var modules: [JSONValue] = []
    @State private var files: [JSONValue] = []
    @State private var loaded = false
    @State private var module = 0
    @State private var fileID = ""
    @State private var pageFrom = 1
    @State private var pageTo = 10
    @State private var count = 10
    @State private var topic = ""
    @State private var generating = false
    @State private var saving = false
    @State private var error: String?
    @State private var cards: [Card] = []
    @State private var editing: String?
    /// Stapel (GET /api/flashcard-stacks; ohne Antwort leer: dann nur "Neuer Stapel …")
    @State private var stacks: [JSONValue] = []
    @State private var stack = FlashcardDeck.newStack
    @State private var stackName = ""
    /// Name selbst geaendert: die Vorgabe (Titel des Dokuments) ueberschreibt ihn nicht mehr
    @State private var stackNameEdited = false

    /// Vorgeschlagene Karte in der Vorschau
    struct Card: Identifiable, Equatable {
        let id: String
        var question: String
        var answer: String
    }

    static let counts = [5, 10, 15, 20]
    /// hoechstens so viele Seiten je Anfrage (wie `AIEndpoints.flashcardPagesMax`)
    static let pagesMax = 20

    /// `entitlements: nil` = `Entitlements.shared`
    @MainActor
    init(moduleID: Int, fileID: String?, entitlements: Entitlements? = nil) {
        initialModuleID = moduleID
        initialFileID = fileID
        _ent = ObservedObject(wrappedValue: entitlements ?? .shared)
        _module = State(initialValue: moduleID)
        _fileID = State(initialValue: fileID ?? "")
    }

    /// Ohne PC (lokales Backend) nur mit Plus; am eigenen Server (Entwicklung) ohne Tarif
    private var needsPlus: Bool { session.api?.isLocal != false }
    private var allowed: Bool { !needsPlus || ent.allows(.flashcards) }

    private var documents: [JSONValue] { AIStartView.documents(files, module: module) }
    private var file: JSONValue? { documents.first { $0.s("id") == fileID } }
    private var pageCount: Int? { file?.i("page_count").flatMap { $0 > 0 ? $0 : nil } }

    /// Seiten der Anfrage: von…bis (vertauscht ist egal), ab 1, hoechstens bis zur letzten Seite, hoechstens `pagesMax`
    static func pages(from: Int, to: Int, pageCount: Int?) -> [Int] {
        let lo = min(from, to), hi = max(from, to)
        let last = max(1, pageCount.map { min($0, hi) } ?? hi)
        let first = max(1, min(lo, last))
        return Array(first...last).prefix(pagesMax).map { $0 }
    }

    var pages: [Int] { Self.pages(from: pageFrom, to: pageTo, pageCount: pageCount) }
    var canGenerate: Bool { allowed && aiEnabled && !generating && !saving && file != nil }
    var canSave: Bool {
        allowed && !saving && !generating && cards.contains { !$0.question.isEmpty && !$0.answer.isEmpty }
            && (stack != FlashcardDeck.newStack || !stackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Fach des gewaehlten Moduls (Name), 0 = alle Module -> Fach des Dokuments ueber sein Modul
    private var subject: String? {
        let mid = module != 0 ? module : file?.i("module_id")
        return modules.first { $0.i("id") == mid }?.s("name")
    }

    /// Stapel des Fachs zur Auswahl (zuletzt geuebte zuerst) plus "Neuer Stapel …"
    static func stackOptions(_ stacks: [JSONValue], subject: String?) -> [(Int, String)] {
        let mine = stacks.filter { ($0.s("subject") ?? "") == (subject ?? "") }
            .sorted { ($0.s("last_practised") ?? "", $0.i("id") ?? 0) > ($1.s("last_practised") ?? "", $1.i("id") ?? 0) }
        return [(FlashcardDeck.newStack, "Neuer Stapel …")] + mine.compactMap { s in s.i("id").map { ($0, s.s("name") ?? "") } }
    }

    var body: some View {
        UFDialog("Karteikarten aus Dokument", icon: "cards") {
            if !allowed {
                UFLockedCard(.flashcards, entitlements: ent).padding(.vertical, 4)
            } else if !aiEnabled {
                connect
            } else if windowWidth >= 760 {
                HStack(alignment: .top, spacing: 20) {
                    source.frame(maxWidth: .infinity, alignment: .topLeading)
                    preview.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                source
                preview.padding(.top, 12)
            }
        } foot: {
            UFButton("Abbrechen") { close() }.accessibilityIdentifier("cards.composer.cancel")
            if allowed && aiEnabled {
                UFButton(saving ? "Wird gespeichert …" : "Übernehmen" + (cards.isEmpty ? "" : " (\(usableCards.count))"), icon: "check", kind: .primary) {
                    Task { await save() }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("cards.composer.save")
            }
        }
        .task { await load() }
        .onChange(of: module) { _, _ in
            if !fileID.isEmpty, !documents.contains(where: { $0.s("id") == fileID }) { fileID = documents.first?.s("id") ?? "" }
            resetStack()
        }
        .onChange(of: fileID) { _, _ in
            clampPages()
            resetStack()
        }
    }

    @ViewBuilder private var connect: some View {
        if let chatgpt {
            TutorConnectState(link: chatgpt) { close(); router.go(.settings(tab: ChatGPTLink.settingsTab)) }.padding(-16)
        } else {
            TutorConnectState.Content(reason: TutorConnectState.reason(nil, access: aiAccess), message: nil, busy: false, fix: nil) { close(); router.go(.settings(tab: ChatGPTLink.settingsTab)) }
                .padding(-16)
        }
    }

    // MARK: Quelle

    private var source: some View {
        VStack(alignment: .leading, spacing: 4) {
            UFField("Modul") {
                UFSelect(options: [(0, "Alle Module")] + modules.compactMap { m in m.i("id").map { ($0, UFFmt.shortName(m.s("name"))) } },
                         selection: $module, fill: true)
                    .accessibilityIdentifier("cards.composer.module")
            }
            UFField("Dokument") {
                if documents.isEmpty {
                    Text(loaded ? "Kein geladenes PDF in diesem Modul." : "Dokumente werden geladen …").ufFont(13.12).foregroundStyle(UF.muted)
                        .accessibilityIdentifier("cards.composer.noFile")
                } else {
                    UFSelect(options: (fileID.isEmpty ? [("", "– Dokument wählen –")] : []) + documents.prefix(60).compactMap { f in
                        f.s("id").map { ($0, AIStartView.title(f)) }
                    }, selection: $fileID, fill: true)
                    .accessibilityIdentifier("cards.composer.file")
                }
            }
            UFField(pageCount.map { "Seiten (von \($0))" } ?? "Seiten") {
                VStack(alignment: .leading, spacing: 6) {
                    UFFlexWrap(gap: 6, rowGap: 6) {
                        ForEach(pagePresets, id: \.label) { p in
                            AIChoiceChip(text: p.label, on: pageFrom == p.from && pageTo == p.to) { pageFrom = p.from; pageTo = p.to }
                        }
                    }
                    HStack(spacing: 8) {
                        Text("von").ufFont(13.12).foregroundStyle(UF.muted)
                        UFNumberField(value: $pageFrom).frame(width: 72).accessibilityLabel("Von Seite").accessibilityIdentifier("cards.composer.from")
                        Text("bis").ufFont(13.12).foregroundStyle(UF.muted)
                        UFNumberField(value: $pageTo).frame(width: 72).accessibilityLabel("Bis Seite").accessibilityIdentifier("cards.composer.to")
                        Text("höchstens \(Self.pagesMax) Seiten").ufFont(12.8).foregroundStyle(UF.muted)
                    }
                }
            }
            UFField("Zahl der Karten") {
                UFFlexWrap(gap: 6, rowGap: 6) {
                    ForEach(Self.counts, id: \.self) { n in
                        AIChoiceChip(text: "\(n)", on: count == n) { count = n }.accessibilityIdentifier("cards.composer.count.\(n)")
                    }
                }
            }
            UFField("Schwerpunkt (optional)") {
                UFTextInput("z. B. nur Definitionen, nur Rechenwege", text: $topic).accessibilityIdentifier("cards.composer.topic")
            }
            UFField("Stapel") {
                UFSelect(options: Self.stackOptions(stacks, subject: subject), selection: $stack, fill: true)
                    .accessibilityIdentifier("cards.composer.stack")
            }
            if stack == FlashcardDeck.newStack {
                UFField("Name des neuen Stapels") {
                    UFTextInput("z. B. Kapitel 3", text: Binding(get: { stackName }, set: { stackName = $0; stackNameEdited = true }))
                        .accessibilityIdentifier("cards.composer.stackName")
                }
            }
            HStack(spacing: 8) {
                UFIcon("sparkles", size: 14).foregroundStyle(UF.accent)
                Text(AICost.line(chatgpt: aiEnabled, plan: ent.plan, credits: 5)).ufFont(12.8).foregroundStyle(UF.muted)
                    .accessibilityIdentifier("cards.composer.cost")
            }
            .padding(.top, 4)
            UFButton(generating ? "Die KI liest die Seiten …" : (cards.isEmpty ? "Karten erstellen" : "Neu erstellen"),
                     icon: generating ? nil : "sparkles", kind: cards.isEmpty ? .primary : .normal) { Task { await generate() } }
                .disabled(!canGenerate)
                .accessibilityIdentifier("cards.composer.generate")
                .padding(.top, 8)
            if let error {
                Text(error).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cards.composer.error")
            }
        }
    }

    private var pagePresets: [(label: String, from: Int, to: Int)] {
        let n = pageCount ?? Self.pagesMax
        var out: [(String, Int, Int)] = []
        if n >= 5 { out.append(("Seite 1–5", 1, 5)) }
        if n >= 10 { out.append(("Seite 1–10", 1, 10)) }
        out.append((n <= Self.pagesMax ? "Alle (\(min(n, Self.pagesMax)))" : "Erste \(Self.pagesMax)", 1, min(n, Self.pagesMax)))
        if let c = pageCount, c > Self.pagesMax { out.append(("Letzte \(Self.pagesMax)", c - Self.pagesMax + 1, c)) }
        return out.map { (label: $0.0, from: $0.1, to: $0.2) }
    }

    /// Stapelvorgabe nach Modul- oder Dokumentwechsel: Stapel eines anderen Fachs passt nicht mehr, der Name des neuen
    /// Stapels ist der Titel des Dokuments (solange er nicht selbst geaendert wurde)
    private func resetStack() {
        if stack != FlashcardDeck.newStack, !Self.stackOptions(stacks, subject: subject).contains(where: { $0.0 == stack }) { stack = FlashcardDeck.newStack }
        if !stackNameEdited { stackName = file.map(AIStartView.title) ?? "" }
    }

    private func clampPages() {
        if let c = pageCount {
            pageTo = min(pageTo, c)
            pageFrom = min(pageFrom, pageTo)
            if pageTo < 1 { pageTo = min(c, 10) }
        }
        if pageFrom < 1 { pageFrom = 1 }
    }

    // MARK: Vorschau

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Vorschau").ufFont(13.6).foregroundStyle(UF.text2)
                Spacer()
                if !cards.isEmpty { Text("\(usableCards.count) Karten").ufFont(12.8).foregroundStyle(UF.muted) }
            }
            if generating {
                ForEach(0..<min(count, 4), id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        UFSkeleton().frame(height: 14).frame(maxWidth: 220)
                        UFSkeleton().frame(height: 12)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface2))
                    .ufAppear("cards.composer.skeleton", index: i)
                }
                HStack(spacing: 8) { ProgressView().controlSize(.small); UFShimmerText("\(count) Karten werden erstellt …") }
                    .accessibilityIdentifier("cards.composer.generating")
            } else if cards.isEmpty {
                UFEmpty(icon: "cards", text: "Wähle ein Dokument und Seiten, dann schlägt die KI Karten vor. Du siehst jede Karte, bevor sie gespeichert wird.", small: true)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface2))
            } else {
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                    cardRow(c, index: i)
                }
            }
        }
    }

    private func cardRow(_ c: Card, index: Int) -> some View {
        let binding = Binding(get: { cards.first { $0.id == c.id } ?? c }, set: { new in if let i = cards.firstIndex(where: { $0.id == c.id }) { cards[i] = new } })
        return VStack(alignment: .leading, spacing: 6) {
            if editing == c.id {
                UFField("Frage") { UFTextArea(placeholder: "Vorderseite", text: binding.question, minHeight: 48) }
                UFField("Antwort") { UFTextArea(placeholder: "Rückseite", text: binding.answer, minHeight: 48) }
                HStack { Spacer(); UFButton("Fertig", icon: "check", size: .small) { editing = nil } }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)").ufFont(12.8, 650).foregroundStyle(UF.accentText).monospacedDigit().frame(minWidth: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FormulaText.attributed(c.question, size: 13.76, weight: 650)).ufFont(13.76, 650).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                        Text(FormulaText.attributed(c.answer, size: 13.12)).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        UFButton(icon: "pen", kind: .ghost, size: .small) { editing = c.id }
                            .ufHitSlop(trailing: 1).accessibilityLabel("Karte bearbeiten: \(c.question)")
                            .accessibilityIdentifier("cards.composer.edit.\(index)")
                        UFButton(icon: "trash", kind: .ghost, size: .small) { cards.removeAll { $0.id == c.id } }
                            .ufHitSlop(leading: 1).accessibilityLabel("Karte streichen: \(c.question)")
                            .accessibilityIdentifier("cards.composer.delete.\(index)")
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
        .ufAppear("cards.composer.cards", index: index)
    }

    private var usableCards: [Card] {
        cards.map { Card(id: $0.id, question: $0.question.trimmingCharacters(in: .whitespacesAndNewlines), answer: $0.answer.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.question.isEmpty && !$0.answer.isEmpty }
    }

    // MARK: Laden, Erstellen, Speichern

    private func load() async {
        guard let api = session.api else { return }
        do {
            async let m = api.value("/api/modules")
            async let l = api.value("/api/library")
            let (mv, lv) = try await (m, l)
            modules = mv.items
            files = lv.list("files")
            // Stapel: ohne Endpunkt (aelterer Server) bleibt nur "Neuer Stapel …"
            stacks = (try? await api.value("/api/flashcard-stacks"))?.items ?? []
            if let id = initialFileID, let f = files.first(where: { $0.s("id") == id }), module == 0 || f.i("module_id") == module {
                fileID = id
            } else if fileID.isEmpty || !documents.contains(where: { $0.s("id") == fileID }) {
                fileID = documents.first?.s("id") ?? ""
            }
            loaded = true
            clampPages()
            resetStack()
        } catch { self.error = error.localizedDescription }
    }

    private func generate() async {
        guard let api = session.api, canGenerate, let id = file?.s("id") else { return }
        generating = true
        error = nil
        editing = nil
        defer { generating = false }
        var body: [String: JSONValue] = ["file_id": .string(id), "pages": .array(pages.map { .number(Double($0)) }), "count": .number(Double(count))]
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { body["topic"] = .string(t) }
        do {
            let r = try await api.value("/api/ai/flashcards", method: "POST", body: .object(body))
            cards = r.list("cards").enumerated().map { i, c in Card(id: "\(i)-\(UUID().uuidString)", question: c.s("question") ?? "", answer: c.s("answer") ?? "") }
            AIRecents.shared.count()
            if cards.isEmpty { error = "Die KI hat keine Karten geliefert. Versuche andere Seiten." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let api = session.api, canSave, let id = file?.s("id") else { return }
        // lokal nur mit Plus: Tarif inzwischen abgelaufen, waehrend der Dialog offen war
        if needsPlus && !ent.allows(.flashcards) { toast.show("Eigene Karteikarten gibt es ab \(UFPlan.plus.name)."); return }
        saving = true
        defer { saving = false }
        let payload = usableCards
        do {
            var body: [String: JSONValue] = ["file_id": .string(id), "cards": .array(payload.map { ["question": .string($0.question), "answer": .string($0.answer)] })]
            if stack != FlashcardDeck.newStack { body["stack_id"] = .number(Double(stack)) } else { body["stack_name"] = .string(stackName.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let r = try await api.value("/api/flashcards", method: "POST", body: .object(body))
            let n = r.i("count") ?? payload.count
            let into = stack != FlashcardDeck.newStack ? (stacks.first { $0.i("id") == stack }?.s("name") ?? "") : stackName.trimmingCharacters(in: .whitespacesAndNewlines)
            toast.show((n == 1 ? "1 Karte gespeichert" : "\(n) Karten gespeichert") + (into.isEmpty ? "" : " in „\(into)“"))
            close()
            router.reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
