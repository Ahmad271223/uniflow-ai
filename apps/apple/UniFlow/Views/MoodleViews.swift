import SwiftUI
import UniFlowCore

// Moodle-Nachrichten beantworten und in einer Moodle-Aufgabe abgeben (Hochschule Hannover; allgemein fuer jedes Moodle
// mit Sitzung, z. B. Learnweb der Uni Hildesheim). Kern: `MoodleWeb`, `MoodleMessagesSync`, `MoodleAssign`
// (docs/HSH-2026-11-05.md). Gesendet bzw. abgegeben wird nur auf Knopfdruck, genau ein Versuch.

/// Zugang zu einem Moodle mit der Sitzung der Webansicht (nil: nicht verbunden)
typealias MoodleWebProvider = @MainActor () async -> MoodleWeb?

enum MoodleTexts {
    static let reply = "Antworten"
    static let open = "In Moodle öffnen"
    static let replyNotice = "Wird über Moodle unter deinem Namen in diese Unterhaltung gesendet."
    static let submitTitle = "In Moodle abgeben"
    static let submitNotice = "Erst „Als Entwurf hochladen“ legt die PDF in deiner Abgabe ab. Abgegeben ist sie erst mit „Jetzt abgeben“ – das lässt sich in Moodle oft nicht zurücknehmen."
    static let notTested = "Mit einem echten Moodle-Konto noch nicht geprüft. Kontrolliere die Abgabe danach in Moodle."

    static func error(_ e: Error) -> String {
        (e as? MoodleError)?.description ?? (e as NSError).localizedDescription
    }
}

/// Antwort auf eine Moodle-Nachricht (Unterhaltung); Empfaenger live aus Moodle, nie gespeichert
struct MoodleReplySheet: View {
    let conversation: Int
    let subject: String
    let web: MoodleWebProvider
    var onExpired: () -> Void = {}
    /// Hinweis unter dem Text (Uni Hildesheim: "… über das Learnweb …", `LearnwebMessages.notice`)
    var notice: String = MoodleTexts.replyNotice
    @State private var names: [String] = []
    @State private var text = ""
    @State private var phase: Phase = .editing
    @Environment(\.dismiss) private var dismiss
    /// iPhone: Blatt von unten, startet ganz (Tastatur), laesst sich auf halb ziehen (Unterhaltung darunter lesen)
    @Environment(\.ufCompact) private var compact
    @State private var detent: PresentationDetent = .large

    enum Phase: Equatable { case editing, sending, sent(Date), failed(String) }

    var body: some View {
        NavigationStack {
            Form {
                Section("An") {
                    Text(names.isEmpty ? subject : names.joined(separator: ", ")).accessibilityIdentifier("moodle.reply.to")
                }
                Section("Text") {
                    TextEditor(text: $text).frame(minHeight: 160).accessibilityIdentifier("moodle.reply.text")
                }
                Section {
                    Text(notice).font(.footnote).foregroundStyle(UF.muted)
                    switch phase {
                    case .sent(let d):
                        Label("Gesendet \(d.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                            .foregroundStyle(UF.ok).accessibilityIdentifier("moodle.reply.sent")
                    case .failed(let m):
                        Text(m).foregroundStyle(UF.bad).accessibilityIdentifier("moodle.reply.error")
                    default:
                        EmptyView()
                    }
                }
            }
            .navigationTitle("Antworten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(isSent ? "Fertig" : "Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Senden") { Task { await send() } }
                        .disabled(isSent || phase == .sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("moodle.reply.send")
                }
            }
            .task { await loadNames() }
        }
        .modifier(MoodleCompactSheet(compact: compact, detent: $detent))
    }

    private var isSent: Bool { if case .sent = phase { return true }; return false }

    private func loadNames() async {
        guard let w = await web() else { return }
        names = (try? await MoodleMessagesSync.memberNames(web: w, conversation: conversation)) ?? []
    }

    private func send() async {
        guard let w = await web() else { phase = .failed("Moodle ist nicht verbunden."); return }
        phase = .sending
        do {
            try await MoodleMessagesSync.reply(web: w, conversation: conversation, text: text)
            phase = .sent(Date())
        } catch {
            if (error as? MoodleError) == .sessionExpired { onExpired() }
            // nie still wiederholen: die Nachricht koennte sonst doppelt ankommen
            phase = .failed(MoodleTexts.error(error) + " Die Nachricht wurde vermutlich nicht gesendet; antworte sonst in Moodle.")
        }
    }
}

/// Abgabe-Blatt: Aufgabe waehlen (aus den Moodle-Fristen), Stand lesen, PDF als Entwurf hochladen, ausdruecklich abgeben
@MainActor
final class MoodleSubmitModel: ObservableObject {
    enum Phase: Equatable { case loading, choose, working(String), saved(MoodleAssign.Status, String), failed(String) }

    @Published var phase: Phase = .loading
    @Published var assignments: [MoodleAssign.Assignment] = []
    @Published var selected: MoodleAssign.Assignment?
    @Published var status: MoodleAssign.Status?
    @Published var withNotes = true
    @Published var confirm: MoodleAssign.ConfirmForm?
    @Published var statementAccepted = false

    let web: MoodleWebProvider
    let loadAssignments: () async -> [MoodleAssign.Assignment]
    let pdf: (Bool) async throws -> Data
    let fileName: String
    var onExpired: () -> Void = {}

    init(web: @escaping MoodleWebProvider, fileName: String, loadAssignments: @escaping () async -> [MoodleAssign.Assignment],
         pdf: @escaping (Bool) async throws -> Data) {
        self.web = web
        self.fileName = fileName
        self.loadAssignments = loadAssignments
        self.pdf = pdf
    }

    func start() async {
        assignments = await loadAssignments()
        phase = .choose
    }

    func choose(_ a: MoodleAssign.Assignment) async {
        selected = a
        status = nil
        confirm = nil
        guard let w = await web() else { phase = .failed("Moodle ist nicht verbunden."); return }
        do { status = try await MoodleAssign.fetchStatus(web: w, cmid: a.cmid) } catch { fail(error) }
    }

    /// "Als Entwurf hochladen"
    func uploadDraft() async {
        guard let a = selected, let w = await web() else { return }
        phase = .working("PDF wird erstellt und hochgeladen …")
        do {
            let data = try await pdf(withNotes)
            let r = try await MoodleAssign.saveDraft(web: w, cmid: a.cmid, pdf: data, fileName: fileName)
            status = r.status
            phase = .saved(r.status, r.savedName)
            if r.status.canSubmit { confirm = try? await MoodleAssign.fetchConfirm(web: w, cmid: a.cmid) }
        } catch { fail(error) }
    }

    /// "Jetzt abgeben" (nur auf ausdruecklichen Knopfdruck)
    func submitNow() async {
        guard let a = selected, let w = await web() else { return }
        phase = .working("Wird abgegeben …")
        do {
            let s = try await MoodleAssign.submit(web: w, cmid: a.cmid, statementAccepted: statementAccepted)
            status = s
            phase = .saved(s, "")
            confirm = nil
        } catch { fail(error) }
    }

    private func fail(_ e: Error) {
        if (e as? MoodleError) == .sessionExpired { onExpired() }
        phase = .failed(MoodleTexts.error(e))
    }
}

/// iPhone: Blatt von unten mit "halb" und "ganz" (Griff sichtbar), Hintergrund gesperrt; iPad unveraendert
struct MoodleCompactSheet: ViewModifier {
    let compact: Bool
    @Binding var detent: PresentationDetent

    func body(content: Content) -> some View {
        if compact {
            content
                .presentationDetents([.medium, .large], selection: $detent)
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.resizes)
        } else {
            content
        }
    }
}

struct MoodleSubmitSheet: View {
    @StateObject var model: MoodleSubmitModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(MoodleTexts.submitNotice).font(.footnote)
                    Text(MoodleTexts.notTested).font(.footnote).foregroundStyle(UF.muted)
                }
                Section("Aufgabe") {
                    if model.phase == .loading { ProgressView() }
                    if model.assignments.isEmpty, model.phase != .loading {
                        Text("Keine Moodle-Aufgabe mit Abgabe gefunden. Aufgaben kommen mit den Fristen beim Abgleich.")
                            .foregroundStyle(UF.muted).accessibilityIdentifier("moodle.submit.empty")
                    }
                    ForEach(model.assignments) { a in
                        Button { Task { await model.choose(a) } } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(a.title)
                                    Text([a.course, a.dueAt.replacingOccurrences(of: "T", with: " ")].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(UF.muted)
                                }
                                Spacer()
                                if model.selected == a { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityIdentifier("moodle.submit.assignment.\(a.cmid)")
                    }
                }
                if let s = model.status {
                    Section("Stand in Moodle") {
                        LabeledContent("Abgabestatus", value: s.state.rawValue).accessibilityIdentifier("moodle.submit.state")
                        if let g = s.grading { LabeledContent("Bewertungsstatus", value: g) }
                        if let a = s.attempt { LabeledContent("Versuch", value: a) }
                        if s.hasFeedback { Text("Feedback vorhanden – in Moodle ansehen.").font(.footnote) }
                    }
                    Section {
                        Toggle("Notizen und Blätter mitschicken", isOn: $model.withNotes)
                        Button("Als Entwurf hochladen") { Task { await model.uploadDraft() } }
                            .disabled(!s.canEdit || isWorking)
                            .accessibilityIdentifier("moodle.submit.draft")
                        if let c = model.confirm {
                            if let st = c.statement {
                                Toggle(st, isOn: $model.statementAccepted).accessibilityIdentifier("moodle.submit.statement")
                            }
                            Button("Jetzt abgeben", role: .destructive) { Task { await model.submitNow() } }
                                .disabled(isWorking || (c.statement != nil && !model.statementAccepted))
                                .accessibilityIdentifier("moodle.submit.now")
                        }
                    }
                }
                switch model.phase {
                case .working(let m): Section { ProgressView(m) }
                case .saved(let s, let name):
                    Section {
                        Label(s.state == .submitted ? "Abgegeben" : "Entwurf gespeichert", systemImage: "checkmark.circle")
                            .foregroundStyle(UF.ok).accessibilityIdentifier("moodle.submit.result")
                        if !name.isEmpty, s.state != .submitted { Text("Datei: \(name)").font(.footnote) }
                    }
                case .failed(let m): Section { Text(m).foregroundStyle(UF.bad).accessibilityIdentifier("moodle.submit.error") }
                default: EmptyView()
                }
            }
            .navigationTitle(MoodleTexts.submitTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() }.disabled(isWorking) } }
            .task { await model.start() }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private var isWorking: Bool { if case .working = model.phase { return true }; return false }
}

/// Einstieg aus dem Dokument (Teilen-Menue): an der HsH mit verbundenem Moodle
struct MoodleSubmitEntry: View {
    let store: DocumentStore
    let api: APIClient
    @Environment(\.hsh) private var hsh
    /// Uni Hildesheim: Learnweb-Aufgaben mit derselben Sitzung (05.11.2026)
    @Environment(\.hildesheim) private var hildesheim

    var body: some View {
        let store = self.store, api = self.api, hsh = self.hsh, hildesheim = self.hildesheim
        let learnweb = hsh?.isConnected(.moodle) != true && hildesheim?.isConnected(.learnweb) == true
        MoodleSubmitSheet(model: {
            let m = MoodleSubmitModel(
                web: { learnweb ? await hildesheim?.moodleWeb() : await hsh?.moodleWeb() },
                fileName: MoodleSubmitEntry.fileName(store.file.displayTitle),
                loadAssignments: {
                    guard let host = ActiveContainer.current?.host, let backend = try? await host.backend() else { return [] }
                    return (try? await backend.context.database.withConnection { try MoodleAssign.assignments($0) }) ?? []
                },
                pdf: { withNotes in
                    let r = try await NotesExport.pdf(for: store, api: api,
                                                      options: .init(includeSideNotes: withNotes, fileStem: "Abgabe", folder: "abgabe"))
                    return try Data(contentsOf: r.url)
                })
            m.onExpired = { learnweb ? hildesheim?.learnwebExpired() : hsh?.moodleExpired() }
            return m
        }())
    }

    /// Dateiname der Abgabe aus dem Dokumenttitel (nur Buchstaben, Ziffern, Bindestrich; .pdf)
    static func fileName(_ title: String) -> String {
        let base = title.replacingOccurrences(of: ".pdf", with: "", options: .caseInsensitive)
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        let s = String(base).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return (s.isEmpty ? "Abgabe" : String(s.prefix(80))) + ".pdf"
    }

    /// Angebot im Teilen-Menue: lokal, schreibbar, an der HsH mit verbundenem Moodle
    @MainActor static func offered(api: APIClient, readOnly: Bool, hsh: HsHConnection?) -> Bool {
        !readOnly && api.isLocal && hsh?.isConnected(.moodle) == true
    }

    /// Uni Hildesheim: lokal, schreibbar, mit verbundenem Learnweb ("Im Learnweb abgeben …")
    @MainActor static func offeredLearnweb(api: APIClient, readOnly: Bool, hildesheim: HildesheimConnection?) -> Bool {
        !readOnly && api.isLocal && hildesheim?.isConnected(.learnweb) == true
    }
}
