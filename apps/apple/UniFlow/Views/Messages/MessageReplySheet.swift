import SwiftUI
import UniFlowCore

/// Antwortfenster (docs/NACHRICHTEN-ANTWORTEN-2026-11-05.md 2.3): Empfaenger (Absender vorausgewaehlt, bei "Alle" die
/// weiteren), Betreff "RE: …", Text, Schalter "Original zitieren" (aus), Hinweis auf das Senden unter dem eigenen Namen,
/// "Senden". Entwurf bei jeder Aenderung gesichert; Fehler mit Ausweg "In Stud.IP antworten".
struct MessageReplySheet: View {
    @StateObject private var model: MessageReplyModel
    /// Anmeldung im Fenster (abgelaufen und still nicht zu erneuern); nil = keine Anmeldung moeglich (Tests)
    let login: ((@escaping () -> Void) -> AnyView)?
    @State private var showingLogin = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// iPhone-Fassung (docs/IPHONE-2026-11-04.md): Blatt von unten (halb/ganz), "Senden" in einer Leiste unten, die
    /// ueber der Tastatur steht; `\.ufCompact` reicht aus der Seite in das Blatt. Breit (iPad) wie bisher.
    @Environment(\.ufCompact) private var compact
    @State private var detent: PresentationDetent = .medium
    @FocusState private var focus: Field?

    enum Field: Hashable { case subject, text }

    static let notice = "Wird über Stud.IP unter deinem Namen gesendet. Die Empfänger sehen deinen Namen."
    static let fallbackTitle = "In Stud.IP antworten"
    static let hideKeyboard = "Tastatur ausblenden"
    /// Neue Nachricht an Lehrende (06.11.2026): Ausweg im Schreibfenster von Stud.IP
    static let directFallbackTitle = "In Stud.IP schreiben"

    /// Titel des Fensters: Antwort, Allen antworten oder neue Nachricht an Lehrende
    static func title(direct: StudIPPerson?, all: Bool) -> String {
        if let p = direct { return "Nachricht an \(p.name)" }
        return all ? "Allen antworten" : "Antworten"
    }

    init(model: @autoclosure @escaping () -> MessageReplyModel, login: ((@escaping () -> Void) -> AnyView)? = nil) {
        _model = StateObject(wrappedValue: model())
        self.login = login
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Self.title(direct: model.original.directTo, all: model.mode == .all))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isSent ? "Fertig" : "Schließen") { dismiss() }
                            .disabled(model.phase == .sending)
                            .accessibilityIdentifier("reply.close")
                    }
                }
        }
        .modifier(CompactSheet(compact: compact, detent: $detent))
        // kompakt: wer schreibt, bekommt das ganze Blatt (die Tastatur nimmt sonst den Platz des Textes)
        .onChange(of: focus) { _, f in if compact, f != nil { detent = .large } }
        .interactiveDismissDisabled(model.phase == .sending)
        .task { await model.start() }
        .sheet(isPresented: $showingLogin) {
            if let login {
                login {
                    showingLogin = false
                    Task { await model.signedIn() }
                }
            }
        }
    }

    private var isSent: Bool { if case .sent = model.phase { return true }; return false }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Stud.IP wird geprüft …")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("reply.loading")
        case .notConnected:
            message(icon: "link.badge.plus", title: "Stud.IP ist nicht verbunden",
                    text: "Melde dich in den Einstellungen unter Stud.IP an. Danach kannst du hier antworten.", id: "reply.notConnected")
        case .needsLogin:
            VStack(spacing: 16) {
                message(icon: "person.badge.key", title: "Bitte bei Stud.IP anmelden",
                        text: "Deine Stud.IP-Anmeldung ist abgelaufen und ließ sich nicht still erneuern. Dein Text bleibt als Entwurf erhalten.",
                        id: "reply.needsLogin")
                if login != nil {
                    Button("Bei Stud.IP anmelden") { showingLogin = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("reply.login")
                }
            }
        case .unavailable(let text):
            VStack(spacing: 16) {
                message(icon: "exclamationmark.bubble", title: model.original.isDirect ? "Senden nicht möglich" : "Antworten nicht möglich",
                        text: text, id: "reply.unavailable")
                if model.offersWebFallback { fallbackButton }
                if model.original.isDirect || StudIPMessageReply.isReplyable(senderLabel: model.original.senderLabel) {
                    Button("Erneut versuchen") { Task { await model.start() } }
                        .accessibilityIdentifier("reply.retry")
                }
            }
        case .sent(let record):
            sentView(record)
        case .ready, .sending:
            form
        }
    }

    private func message(icon: String, title: String, text: String, id: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(UF.accent)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(UF.muted).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private var fallbackButton: some View {
        Button { openURL(model.replyWebURL) } label: {
            Label(model.original.isDirect ? Self.directFallbackTitle : Self.fallbackTitle, systemImage: "arrow.up.right.square")
        }
        .accessibilityHint(model.original.isDirect ? "Öffnet das Schreibfenster von Stud.IP im angemeldeten Browser"
                                                   : "Öffnet das Antwortfenster von Stud.IP im angemeldeten Browser")
        .accessibilityIdentifier("reply.openInStudIP")
    }

    // MARK: Formular

    private var form: some View {
        Form {
            Section("An") {
                if let c = model.context, c.allowsReplyAll {
                    Picker("Empfänger", selection: $model.mode) {
                        Text("Nur Absender").tag(StudIPReplyMode.sender)
                        Text("Alle (\(c.otherRecipientIDs.count + 1))").tag(StudIPReplyMode.all)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("reply.mode")
                }
                ForEach(model.recipients) { p in
                    Label(p.name, systemImage: "person.crop.circle")
                        .accessibilityLabel("An \(p.name)")
                }
                if model.loadingOthers {
                    ProgressView("Weitere Empfänger werden geladen …")
                }
                if let c = model.context, c.isCircular {
                    Text("Rundnachricht an \(c.otherRecipientIDs.count + 1) Personen – die Antwort geht nur an den Absender.")
                        .font(.footnote).foregroundStyle(UF.muted)
                        .accessibilityIdentifier("reply.circular")
                }
            }
            .accessibilityIdentifier("reply.to")

            Section("Betreff") {
                TextField("Betreff", text: $model.subject)
                    .focused($focus, equals: .subject)
                    .submitLabel(.next)
                    .onSubmit { focus = .text }
                    .accessibilityLabel("Betreff")
                    .accessibilityIdentifier("reply.subject")
            }

            Section {
                TextEditor(text: $model.text)
                    .focused($focus, equals: .text)
                    .frame(minHeight: compact ? 140 : 180)
                    .accessibilityLabel(model.original.isDirect ? "Deine Nachricht" : "Deine Antwort")
                    .accessibilityIdentifier("reply.text")
                if !model.original.isDirect {
                    Toggle("Original zitieren", isOn: $model.quote)
                        .accessibilityIdentifier("reply.quote")
                }
                if let q = model.quoteText {
                    Text(q)
                        .font(.callout)
                        .foregroundStyle(UF.muted)
                        .textSelection(.enabled)
                        .accessibilityLabel("Zitat: \(q)")
                        .accessibilityIdentifier("reply.quotePreview")
                }
            } header: {
                Text("Nachricht")
            } footer: {
                if let at = model.restoredDraftAt {
                    HStack {
                        Text("Entwurf vom \(Self.draftDate(at)) wiederhergestellt")
                            .accessibilityIdentifier("reply.draftRestored")
                        Spacer()
                        Button("Entwurf verwerfen", role: .destructive) { model.discardDraft() }
                            .font(.footnote)
                            .accessibilityIdentifier("reply.discard")
                    }
                }
            }

            Section {
                Label {
                    Text(Self.notice)
                } icon: { Image(systemName: "paperplane").foregroundStyle(UF.accent) }
                .font(.callout)
                .accessibilityIdentifier("reply.notice")
                if let e = model.errorMessage {
                    Label {
                        Text(e)
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(UF.warn) }
                    .font(.callout)
                    .accessibilityIdentifier("reply.error")
                }
                if model.offersWebFallback { fallbackButton }
                if !compact { sendButton }
            }
        }
        // "Tastatur ausblenden" steht in der Leiste, nicht als Leiste ueber der Tastatur: deren Hoehe rechnet das Blatt
        // nicht aus dem sicheren Bereich heraus, sie verdeckte sonst "Senden" (gemessen auf dem iPhone 17)
        .modifier(CompactSendBar(compact: compact) {
            HStack(spacing: 10) {
                if focus != nil {
                    Button { focus = nil } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(UF.accentText)
                    .accessibilityLabel(Self.hideKeyboard)
                    .accessibilityIdentifier("reply.hideKeyboard")
                }
                sendButton.controlSize(.large)
            }
        })
        .scrollDismissesKeyboard(compact ? .interactively : .automatic)
    }

    private var sendButton: some View {
        Button {
            focus = nil
            Task { await model.send() }
        } label: {
            HStack {
                Spacer()
                if model.phase == .sending { ProgressView().padding(.trailing, 6) }
                Text(model.phase == .sending ? "Wird gesendet …" : "Senden").bold()
                Spacer()
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSend)
        .accessibilityIdentifier("reply.send")
    }

    /// Kompakt: Hoehen halb und ganz mit Griff, ohne bedienbaren Hintergrund (eigener Abschluss "Senden")
    private struct CompactSheet: ViewModifier {
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

    /// Kompakt: "Senden" in einer Leiste am unteren Rand des Blatts; sie liegt im sicheren Bereich und steigt mit der
    /// Tastatur, bleibt also bei jeder Hoehe und waehrend des Schreibens erreichbar
    private struct CompactSendBar<Bar: View>: ViewModifier {
        let compact: Bool
        @ViewBuilder let bar: () -> Bar

        func body(content: Content) -> some View {
            if compact {
                content.safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        bar()
                            .padding(.horizontal, UFCompactLearn.gutter)
                            .padding(.vertical, 10)
                    }
                    .background(.bar)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("reply.sendBar")
                }
            } else {
                content
            }
        }
    }

    private func sentView(_ record: StudIPReplyRecord) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(UF.ok)
            Text("Gesendet").font(.title2.bold())
            Text("An \(model.recipients.map(\.name).joined(separator: ", ")) · \(record.line())")
                .font(.callout).foregroundStyle(UF.muted).multilineTextAlignment(.center)
            Text(model.original.isDirect ? "Die Nachricht liegt in Stud.IP unter Nachrichten → Gesendet."
                                         : "Die Antwort liegt in Stud.IP unter Nachrichten → Gesendet.")
                .font(.footnote).foregroundStyle(UF.muted).multilineTextAlignment(.center)
            Button("Fertig") { dismiss() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reply.done")
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reply.sent")
    }

    private static let draftF: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM., HH:mm"
        return f
    }()

    static func draftDate(_ d: Date) -> String { draftF.string(from: d) }
}

/// Fenster mit den Abhaengigkeiten der App (Sitzung des Containers, Anmeldung wie in den Einstellungen)
struct MessageReplyEntry: View {
    let original: MessageReplyOriginal
    let mode: StudIPReplyMode
    @EnvironmentObject private var studip: StudIPSync

    var body: some View {
        let studip = self.studip
        MessageReplySheet(
            model: MessageReplyModel(original: original, mode: mode,
                                     dependencies: .live(studip: studip, defaults: ActiveContainer.current?.defaults ?? .standard)),
            login: { done in
                AnyView(StudIPLoginView(base: StudIPSync.base, dataStore: studip.websiteDataStore) { cookies in
                    studip.signedIn(cookies: cookies)
                    done()
                })
            })
    }
}
