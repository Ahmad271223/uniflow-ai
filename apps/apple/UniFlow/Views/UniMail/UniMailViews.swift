import Combine
import SwiftUI
import UniFlowCore
import UniformTypeIdentifiers
import WebKit

// Uni-Mail und Uni-Kalender (SOGo der LUH bzw. der Uni Hildesheim, `SOGoSite`), docs/UNI-MAIL-2026-11-05.md: Anmeldung auf der echten Seite in der
// Webansicht des Containers, Seite "Uni-Mail" (Ordner, Liste mit Seiten, Suche, Lesen, Antworten, Weiterleiten, Neue
// E-Mail, Markieren, Papierkorb mit "Rückgängig"), Uni-Kalender in den Lernkalender, Karte in den Einstellungen.
// Gesendet wird nur ueber den Knopf "Senden" und dessen Rueckfrage.

private struct UniMailKey: EnvironmentKey {
    static let defaultValue: UniMailConnection? = nil
}

extension EnvironmentValues {
    /// Uni-Mail des offenen Containers der LUH oder der Uni Hildesheim (`ContainerManager.uniMail`); sonst nil
    var uniMail: UniMailConnection? {
        get { self[UniMailKey.self] }
        set { self[UniMailKey.self] = newValue }
    }
}

/// Zahl der ungelesenen am Menuepunkt "Uni-Mail"
struct UniMailBadgeHost: ViewModifier {
    @EnvironmentObject private var router: UFRouter
    @Environment(\.uniMail) private var uniMail

    func body(content: Content) -> some View {
        content
            .onAppear { router.setBadge(uniMail?.unseen ?? 0, for: "unimail") }
            .onChange(of: uniMail == nil) { _, _ in router.setBadge(uniMail?.unseen ?? 0, for: "unimail") }
            .onReceive(uniMail?.$unseen.eraseToAnyPublisher() ?? Just(0).eraseToAnyPublisher()) { n in
                router.setBadge(uniMail?.isConnected == true ? n : 0, for: "unimail")
            }
    }
}

// MARK: - Anmeldung

/// Anmeldung auf der echten SOGo-Seite (eigenes Formular, kein WebSSO-Skript). Fertig, sobald die Webansicht eine
/// Adresse /SOGo/so/<benutzer>/... zeigt. Benutzername und Passwort tippt der Mensch; iOS darf das Passwort einsetzen.
struct UniMailLoginPane<Bottom: View>: View {
    @ObservedObject var connection: UniMailConnection
    let onSignedIn: () -> Void
    @ViewBuilder let bottom: Bottom
    @StateObject private var load = UFWebLoadState()
    @State private var done = false

    init(connection: UniMailConnection, onSignedIn: @escaping () -> Void, @ViewBuilder bottom: () -> Bottom) {
        self.connection = connection
        self.onSignedIn = onSignedIn
        self.bottom = bottom()
    }

    var body: some View {
        StudIPWebView(url: DebugUniStub.loginPage("sogo", real: connection.site.loginURL), dataStore: connection.websiteDataStore,
                      load: load, loginHelper: false) { webView in pageLoaded(webView) }
            .ufWebLoadFailure(load)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    UniversityLoginHint()
                    UniRememberPasswordToggle(dataStore: connection.websiteDataStore)
                    bottom
                }
            }
    }

    /// Konto aus der Adresse der Webansicht (nur HTTPS auf dem Rechner von SOGo dieser Hochschule); Nachbildung im
    /// Debug-Stub (erfundenes Konto je Hochschule)
    static func signedInUser(_ url: URL?, site: SOGoSite) -> String? {
        if DebugUniStub.isSignedIn(url, service: "sogo") { return site == .luh ? "erika.muster@stud.uni-hannover.de" : "muster" }
        return SOGo.user(fromURL: url, site: site)
    }

    private func pageLoaded(_ webView: WKWebView) {
        guard !done, let user = Self.signedInUser(webView.url, site: connection.site) else { return }
        done = true
        connection.signedIn(user: user)
        onSignedIn()
    }
}

struct UniMailLoginView: View {
    @ObservedObject var connection: UniMailConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            UniMailLoginPane(connection: connection, onSignedIn: { dismiss() }) { EmptyView() }
                .navigationTitle("Uni-Mail-Anmeldung")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}

/// Karte "Uni-Mail & Uni-Kalender" (Einstellungen): Stand, Anmelden/Erneut anmelden, Mitteilungen, Abmelden
struct UniMailSourcesCard: View {
    @Environment(\.uniMail) private var uniMail

    var body: some View {
        if let uniMail { Panel(connection: uniMail) }
    }

    private struct Panel: View {
        @ObservedObject var connection: UniMailConnection
        @Environment(\.backgroundSync) private var background
        @State private var login = false
        @State private var confirmSignOut = false
        @State private var notifyNote: String?

        var body: some View {
            UFCard {
                UFCardHead("\(connection.site.name) & Uni-Kalender", icon: "mail") {
                    UFBadge(UniMailConnection.statusText(connection.state), tone: Self.tone(connection.state)).fixedSize()
                }
                Text(connection.hint).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                if let u = connection.user, connection.isConnected {
                    Text("Konto: \(u)").ufFont(12.8).foregroundStyle(UF.text2).padding(.top, 4)
                }
                if connection.isConnected {
                    Toggle(isOn: Binding(get: { connection.notify }, set: { on in
                        Task {
                            let ok = await (background?.setMailNotify(on) ?? !on)
                            connection.notify = on && ok
                            notifyNote = on && !ok ? "Mitteilungen sind in den iPad-Einstellungen für StudiNow aus." : nil
                        }
                    })) {
                        Text("Bei neuen Uni-Mails benachrichtigen").ufFont(13.5)
                    }
                    .accessibilityIdentifier("unimail.notify")
                    .padding(.top, 6)
                    if let notifyNote { Text(notifyNote).ufFont(12.5).foregroundStyle(UF.warnText) }
                }
                UFFlexWrap(gap: 9.6) {
                    if connection.needsAttention {
                        UFButton(connection.state == .needsLogin ? "Erneut anmelden" : "Bei Uni-Mail anmelden", icon: "arrow-right", kind: .primary, size: .small) {
                            login = true
                        }
                        .accessibilityIdentifier("unimail.connect")
                    }
                    if connection.isConnected {
                        UFButton("Abmelden", icon: "log-out", kind: .danger, size: .small) { confirmSignOut = true }
                    }
                }
                .padding(.top, 9.6)
            }
            .accessibilityIdentifier("unimail.card")
            .sheet(isPresented: $login) { UniMailLoginView(connection: connection) }
            .confirmationDialog("Von Uni-Mail abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) { Task { await connection.signOut() } }
            } message: { Text(UniMailConnection.signOutMessage) }
        }

        static func tone(_ s: UniMailConnection.State) -> UFTone {
            switch s {
            case .ok: return .ok
            case .needsLogin: return .warn
            case .failed: return .bad
            case .running: return .info
            case .connected, .notConnected: return .neutral
            }
        }
    }
}

// MARK: - Seite

/// Eintrag der Liste (Identifiable fuer Blaetter)
struct UniMailRef: Identifiable, Equatable {
    let folder: String
    let uid: Int
    var id: String { "\(folder)#\(uid)" }
}

/// Was das Schreib-Blatt anlegt
struct UniMailComposeRequest: Identifiable {
    let id = UUID()
    var action = "compose"
    var folder = "INBOX"
    var uid: Int?
    /// schon vorhandene Datei (PDF aus einem Dokument), wird nach dem Anlegen des Entwurfs hochgeladen
    var attachment: (name: String, data: Data, mime: String)?
    /// vorbelegter Empfaenger und Betreff (Lehrende, 06.11.2026: Antippen der E-Mail-Adresse)
    var to: String?
    var subject: String?
}

struct UniMailPage: View {
    @Environment(\.uniMail) private var uniMail

    var body: some View {
        if let uniMail {
            UniMailMain(connection: uniMail)
        } else {
            UFContent(maxWidth: 900) {
                UFPageHead("Uni-Mail", sub: "E-Mails und Kalender deiner Hochschule")
                UFCard { UFEmpty(icon: "mail", text: "Uni-Mail gibt es für Studierende der Leibniz Universität Hannover und der Universität Hildesheim auf dem iPad.") }
            }
        }
    }
}

struct UniMailMain: View {
    @ObservedObject var connection: UniMailConnection
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufWindowWidth) private var windowWidth
    @State private var boxes: [JSONValue] = []
    @State private var folder = "INBOX"
    @State private var query = ""
    @State private var listing: JSONValue?
    @State private var messages: [JSONValue] = []
    @State private var page = 0
    @State private var loading = false
    /// Suchtext, zu dem die gezeigte Liste gehoert
    @State private var shownQuery = ""
    /// "Neue Mails prüfen" laeuft (Lade-Anzeige, Knopf gesperrt)
    @State private var checking = false
    @State private var error: String?
    @State private var selected: UniMailRef?
    @State private var compose: UniMailComposeRequest?
    @State private var login = false
    @State private var pendingTrash: (ref: UniMailRef, unread: Bool, task: Task<Void, Never>)?

    private var wide: Bool { windowWidth >= 1000 }

    var body: some View {
        UFContent(maxWidth: 1200) {
            UFPageHead(connection.site.name, sub: "E-Mails und Kalender der \(connection.site.universityName) (SOGo)") {
                if connection.isConnected { checkButton }
                // Lehrende der eigenen Kurse mit E-Mail aus Stud.IP (06.11.2026, Views/Lecturers); Stud.IP nur an der LUH
                if connection.site.university == .luh {
                    UFButton(LecturersText.title, icon: "users", size: .small) { router.go(.lecturers) }
                        .accessibilityHint("Lehrende deiner Kurse mit E-Mail-Adresse und Sprechstunde")
                        .accessibilityIdentifier("unimail.lecturers")
                }
            }
            if !connection.isConnected {
                connectCard
            } else {
                if connection.state == .needsLogin { loginBanner }
                toolbar
                if let error { Text(error).ufFont(13).foregroundStyle(UF.bad).padding(.bottom, 8).accessibilityIdentifier("unimail.error") }
                if pendingTrash != nil { undoBar }
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        list.frame(width: 420)
                        Group {
                            if let s = selected {
                                UniMailReader(connection: connection, ref: s, boxes: boxes, onAction: handle).id(s.id)
                            } else {
                                UFCard { UFEmpty(icon: "mail", text: "Wähle links eine E-Mail aus.") }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    list
                }
                UniCalendarCard(connection: connection).padding(.top, 18)
            }
        }
        .task(id: connection.isConnected) { await start() }
        .sheet(item: Binding(get: { wide ? nil : selected }, set: { selected = $0 })) { s in
            NavigationStack {
                ScrollView { UniMailReader(connection: connection, ref: s, boxes: boxes, onAction: handle).padding(16) }
                    .navigationTitle("E-Mail").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { selected = nil } } }
            }
        }
        .sheet(item: $compose) { r in UniMailComposeSheet(connection: connection, request: r) { sent in if sent { toast.show("Gesendet.") } } }
        .sheet(isPresented: $login) { UniMailLoginView(connection: connection) }
        .accessibilityIdentifier("unimail.page")
    }

    private var connectCard: some View {
        UFCard {
            UFCardHead("Uni-Mail verbinden", icon: "mail")
            Text(connection.hint).ufFont(13.5).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            UFButton("Bei Uni-Mail anmelden", icon: "arrow-right", kind: .primary) { login = true }
                .padding(.top, 10)
                .accessibilityIdentifier("unimail.connect")
        }
    }

    private var loginBanner: some View {
        HStack(spacing: 10) {
            UFIcon("alert", size: 16).foregroundStyle(UF.warnText)
            Text("Die Anmeldung bei Uni-Mail ist abgelaufen. Melde dich erneut an; dein Passwort setzt höchstens iOS ein.")
                .ufFont(13).foregroundStyle(UF.warnText).fixedSize(horizontal: false, vertical: true)
            Spacer()
            UFButton("Erneut anmelden", icon: "arrow-right", kind: .primary, size: .small) { login = true }
                .accessibilityIdentifier("unimail.relogin")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.warnSoft))
        .padding(.bottom, 10)
    }

    private var toolbar: some View {
        UFFlexWrap(gap: 8) {
            Menu {
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, b in
                    Button(String(repeating: "   ", count: b.i("level") ?? 0) + (b.s("name") ?? "")) {
                        folder = b.s("path") ?? "INBOX"
                        Task { await reload() }
                    }
                }
            } label: {
                Label(folderName, systemImage: "tray").ufFont(13.5, 600)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
            }
            .accessibilityIdentifier("unimail.folders")
            UFInputBox(focused: false) {
                TextField("Suchen (Betreff, Absender)", text: $query)
                    .submitLabel(.search).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onSubmit { Task { await reload() } }
                    .accessibilityIdentifier("unimail.search")
            }
            .frame(maxWidth: 320)
            UFButton("Neue E-Mail", icon: "pen", kind: .primary, size: .small) { compose = UniMailComposeRequest() }
                .accessibilityIdentifier("unimail.new")
        }
        .padding(.bottom, 12)
    }

    /// "Neue Mails prüfen" (Entscheidung des Inhabers 07.11.2026, statt eines Takts): oben gut sichtbar, laedt sofort
    /// den Posteingang (erste Seite, ungelesene); waehrend des Ladens Anzeige und gesperrt, also nie doppelt
    private var checkButton: some View {
        HStack(spacing: 8) {
            if checking {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Prüfe neue Mails")
                    .accessibilityIdentifier("unimail.checking")
            }
            UFButton(UniMailMain.checkTitle(checking: checking), icon: "refresh", kind: .primary, size: .small) {
                Task { await checkNewMail() }
            }
            .disabled(checking || loading)
            .accessibilityIdentifier("unimail.refresh")
        }
    }

    static func checkTitle(checking: Bool) -> String { checking ? "Prüfe …" : "Neue Mails prüfen" }

    private func checkNewMail() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        folder = "INBOX"
        query = ""
        await reload()
    }

    private var folderName: String {
        boxes.first { $0.s("path") == folder }?.s("name") ?? (folder == "INBOX" ? "Posteingang" : folder)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let l = listing {
                let total = l.i("total") ?? 0
                Text(total == 0 ? (query.isEmpty ? "Keine E-Mails in diesem Ordner." : "Keine Treffer.") : "\(total) \(total == 1 ? "E-Mail" : "E-Mails")"
                     + (l["stale"]?.bool == true ? " · ohne Netz (zuletzt gelesen)" : ""))
                    .ufFont(12.5, 600).foregroundStyle(UF.muted).padding(.bottom, 6)
                    .accessibilityIdentifier("unimail.count")
            } else if loading {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            }
            ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                let ref = UniMailRef(folder: folder, uid: m.i("uid") ?? 0)
                if pendingTrash?.ref != ref {
                    Button { open(m) } label: { UniMailRow(message: m, active: selected == ref) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("unimail.row")
                    Divider()
                }
            }
            if let l = listing, messages.count < (l.i("total") ?? 0), l["stale"]?.bool != true {
                UFButton("Weitere laden", icon: "chevron-down", size: .small) { Task { await more() } }
                    .padding(.top, 10)
                    .disabled(loading)
                    .accessibilityIdentifier("unimail.more")
            }
        }
    }

    private var undoBar: some View {
        HStack {
            Text("In den Papierkorb verschoben.").ufFont(13.5).foregroundStyle(UF.text)
            Spacer()
            Button("Rückgängig") {
                pendingTrash?.task.cancel()
                pendingTrash = nil
            }
            .ufFont(13.5, 650)
            .accessibilityIdentifier("unimail.undo")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
        .padding(.bottom, 10)
    }

    // MARK: Ablauf

    private func start() async {
        guard connection.isConnected else { return }
        if listing == nil, folder == "INBOX", let c = await connection.cachedInbox() {
            listing = c
            messages = c.list("messages")
        }
        if boxes.isEmpty { boxes = (try? await connection.mailboxes()) ?? [] }
        await reload()
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        let target = folder, q = query
        // anderer Ordner oder andere Suche: die alte Liste sofort weg, nie die Mails eines anderen Ordners zeigen
        // (echtes iPad 07.11.2026: im leeren Ordner Spam standen die 599 Mails des Posteingangs)
        if listing?.s("folder") != target || shownQuery != q {
            listing = nil
            messages = []
            page = 0
        }
        shownQuery = q
        do {
            let l = try await connection.listing(folder: target, query: q)
            guard folder == target, query == q else { return }   // inzwischen weitergeklickt: Antwort verwerfen
            listing = l
            messages = l.list("messages")
            page = 0
            error = nil
        } catch {
            guard folder == target else { return }
            self.error = UniMailConnection.message(error)
        }
    }

    private func more() async {
        guard let l = listing else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await connection.page(folder: folder, uids: SOGo.flattenUIDs(l["uids"]), page: page + 1)
            messages += next
            page += 1
        } catch {
            self.error = UniMailConnection.message(error)
        }
    }

    private func open(_ m: JSONValue) {
        let uid = m.i("uid") ?? 0
        selected = UniMailRef(folder: folder, uid: uid)
        // SOGo markiert beim Lesen als gelesen: in der Liste gleich so zeigen
        if let i = messages.firstIndex(where: { $0.i("uid") == uid }), m["read"]?.bool != true {
            messages[i]["read"] = true
        }
    }

    private func handle(_ a: UniMailReader.Action) {
        switch a {
        case .reply(let r): compose = UniMailComposeRequest(action: "reply", folder: r.folder, uid: r.uid)
        case .replyAll(let r): compose = UniMailComposeRequest(action: "replyall", folder: r.folder, uid: r.uid)
        case .forward(let r): compose = UniMailComposeRequest(action: "forward", folder: r.folder, uid: r.uid)
        case .changed(let r, let read, let flagged):
            if let i = messages.firstIndex(where: { $0.i("uid") == r.uid }) {
                if let read { messages[i]["read"] = .bool(read) }
                if let flagged { messages[i]["flagged"] = .bool(flagged) }
            }
        case .trash(let r):
            // erst nach 5 Sekunden ohne "Rückgängig" in den Papierkorb (nie endgueltig loeschen)
            pendingTrash?.task.cancel()
            let unread = messages.first { $0.i("uid") == r.uid }?["read"]?.bool == false
            selected = nil
            let conn = connection
            let task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                do {
                    try await conn.trash(folder: r.folder, uids: [r.uid], unread: unread ? 1 : 0)
                    messages.removeAll { $0.i("uid") == r.uid }
                    if var l = listing { l["total"] = .number(Double(max(0, (l.i("total") ?? 1) - 1))); listing = l }
                } catch {
                    self.error = UniMailConnection.message(error)
                }
                pendingTrash = nil
            }
            pendingTrash = (r, unread, task)
        case .restored(let r):
            messages.removeAll { $0.i("uid") == r.uid }
            selected = nil
            toast.show("In den Posteingang verschoben.")
        }
    }
}

struct UniMailRow: View {
    let message: JSONValue
    var active = false

    var body: some View {
        let unread = message["read"]?.bool == false
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(unread ? UF.accent : Color.clear).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(message.s("sender").flatMap { $0.isEmpty ? nil : $0 } ?? "(ohne Absender)").ufFont(14, unread ? 700 : 500)
                        .foregroundStyle(UF.text).lineLimit(1)
                    Spacer()
                    if message["attachment"]?.bool == true { UFIcon("file", size: 13).foregroundStyle(UF.muted) }
                    if message["flagged"]?.bool == true { UFIcon("flag", size: 13).foregroundStyle(UF.bad) }
                    Text(message.s("date") ?? "").ufFont(12).foregroundStyle(UF.muted)
                }
                Text(message.s("subject").flatMap { $0.isEmpty ? nil : $0 } ?? "(ohne Betreff)").ufFont(13.5, unread ? 650 : 400)
                    .foregroundStyle(UF.text2).lineLimit(2)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(active ? UF.accentSoft : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(unread ? "Ungelesen, " : "")\(message.s("sender") ?? ""), \(message.s("subject") ?? "")")
    }
}

// MARK: - Lesen

struct UniMailReader: View {
    enum Action {
        case reply(UniMailRef), replyAll(UniMailRef), forward(UniMailRef)
        case changed(UniMailRef, read: Bool?, flagged: Bool?)
        case trash(UniMailRef), restored(UniMailRef)
    }

    @ObservedObject var connection: UniMailConnection
    let ref: UniMailRef
    let boxes: [JSONValue]
    let onAction: (Action) -> Void
    @State private var message: JSONValue?
    @State private var error: String?
    @State private var showHTML = true
    @State private var flagged = false
    @State private var shareItem: UniMailShareItem?
    @State private var busy = false

    struct UniMailShareItem: Identifiable { let url: URL; var id: String { url.absoluteString } }

    private var inTrash: Bool { SOGo.folder(ofType: "trash", in: boxes, fallback: "Trash") == ref.folder }

    var body: some View {
        UFCard {
            if let m = message {
                Text(m.s("subject").flatMap { $0.isEmpty ? nil : $0 } ?? "(ohne Betreff)").ufFont(18, 700).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unimail.subject")
                VStack(alignment: .leading, spacing: 3) {
                    line("Von", m.list("from"))
                    line("An", m.list("to"))
                    if !m.list("cc").isEmpty { line("Cc", m.list("cc")) }
                    if let d = m.s("date"), !d.isEmpty { Text(d).ufFont(12.5).foregroundStyle(UF.muted) }
                }
                .padding(.vertical, 6)
                actions
                if !m.list("attachments").isEmpty { attachments(m.list("attachments")) }
                Divider().padding(.vertical, 6)
                if m["remote_blocked"]?.bool == true, showHTML {
                    Text("Bilder aus dem Internet werden nicht geladen (Schutz vor Zählpixeln).").ufFont(12).foregroundStyle(UF.muted)
                }
                if showHTML, let html = m.s("html"), !html.isEmpty {
                    UniMailHTMLView(html: html).frame(minHeight: 320)
                        .accessibilityIdentifier("unimail.html")
                } else {
                    Text(m.s("text") ?? "").ufFont(14.5).foregroundStyle(UF.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("unimail.text")
                }
                if let html = m.s("html"), !html.isEmpty {
                    Button(showHTML ? "Als reinen Text zeigen" : "Formatiert zeigen") { showHTML.toggle() }.ufFont(12.5).padding(.top, 6)
                }
            } else if let error {
                UFEmpty(icon: "alert", text: error) { UFButton("Erneut versuchen", icon: "refresh") { Task { await load() } } }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            }
        }
        .task { await load() }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
        .accessibilityIdentifier("unimail.reader")
    }

    private func line(_ label: String, _ list: [JSONValue]) -> some View {
        Text("\(label): ").font(.uf(13, 600)).foregroundColor(UF.text2)
            + Text(list.map { a in
                let n = a.s("name") ?? "", e = a.s("email") ?? ""
                return n.isEmpty ? e : "\(n) <\(e)>"
            }.joined(separator: ", ")).font(.uf(13)).foregroundColor(UF.text2)
    }

    private var actions: some View {
        UFFlexWrap(gap: 8) {
            UFButton("Antworten", icon: "reply", kind: .primary, size: .small) { onAction(.reply(ref)) }
                .accessibilityIdentifier("unimail.reply")
            UFButton("Allen antworten", icon: "reply", size: .small) { onAction(.replyAll(ref)) }
                .accessibilityIdentifier("unimail.replyAll")
            UFButton("Weiterleiten", icon: "arrow-right", size: .small) { onAction(.forward(ref)) }
                .accessibilityIdentifier("unimail.forward")
            UFButton("Als ungelesen", icon: "mail", size: .small) {
                Task { await run { try await connection.setRead(folder: ref.folder, uid: ref.uid, read: false); onAction(.changed(ref, read: false, flagged: nil)) } }
            }
            .accessibilityIdentifier("unimail.unread")
            UFButton(flagged ? "Markierung entfernen" : "Markieren", icon: "flag", size: .small) {
                let next = !flagged
                Task { await run { try await connection.setFlag(folder: ref.folder, uid: ref.uid, flagged: next); flagged = next; onAction(.changed(ref, read: nil, flagged: next)) } }
            }
            .accessibilityIdentifier("unimail.flag")
            if inTrash {
                UFButton("Wiederherstellen", icon: "undo", size: .small) {
                    Task { await run { try await connection.restore(uids: [ref.uid], boxes: boxes); onAction(.restored(ref)) } }
                }
                .accessibilityIdentifier("unimail.restore")
            } else {
                UFButton("In den Papierkorb", icon: "trash", kind: .danger, size: .small) { onAction(.trash(ref)) }
                    .accessibilityIdentifier("unimail.trash")
            }
        }
        .disabled(busy)
    }

    private func attachments(_ list: [JSONValue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Anhänge").ufFont(12.5, 650).foregroundStyle(UF.muted)
            ForEach(Array(list.enumerated()), id: \.offset) { _, a in
                Button {
                    Task { await run { shareItem = UniMailShareItem(url: try await connection.download(a)) } }
                } label: {
                    HStack(spacing: 8) {
                        UFIcon("file", size: 15)
                        Text(a.s("name") ?? "Anhang").ufFont(13.5, 600).lineLimit(1)
                        if let s = a.s("size"), !s.isEmpty { Text(s).ufFont(12).foregroundStyle(UF.muted) }
                        Spacer()
                        UFIcon("share", size: 14)
                    }
                    .foregroundStyle(UF.accentText)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Anhang \(a.s("name") ?? "") öffnen oder teilen")
                .accessibilityIdentifier("unimail.attachment")
            }
        }
        .padding(.vertical, 6)
    }

    private func run(_ body: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await body(); error = nil } catch { self.error = UniMailConnection.message(error) }
    }

    private func load() async {
        do {
            let m = try await connection.read(folder: ref.folder, uid: ref.uid, wasUnread: true)
            message = m
            error = nil
        } catch {
            self.error = UniMailConnection.message(error)
        }
    }
}

/// HTML einer Mail: bereinigt (`SOGo.sanitize`), ohne JavaScript, ohne Netz (Content-Security-Policy), eigener
/// fluechtiger Datenspeicher; angetippte Links oeffnen ausserhalb (nur http, https, mailto)
struct UniMailHTMLView: UIViewRepresentable {
    let html: String

    static func page(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:light dark}body{font:16px -apple-system,sans-serif;margin:0;word-wrap:break-word}
        img{max-width:100%;height:auto}blockquote{border-left:3px solid #9aa3c7;margin:0 0 0 4px;padding-left:10px}</style>
        </head><body>\(html)</body></html>
        """
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let v = WKWebView(frame: .zero, configuration: config)
        v.navigationDelegate = context.coordinator
        v.isOpaque = false
        v.backgroundColor = .clear
        v.loadHTMLString(Self.page(html), baseURL: nil)
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated {
                if let u = action.request.url, ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") {
                    await UIApplication.shared.open(u)
                }
                return .cancel
            }
            return action.request.url?.scheme == "about" || action.navigationType == .other ? .allow : .cancel
        }
    }
}

// MARK: - Schreiben

struct UniMailComposeSheet: View {
    @ObservedObject var connection: UniMailConnection
    let request: UniMailComposeRequest
    var onDone: (Bool) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var draft: JSONValue?
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var text = ""
    @State private var attachments: [JSONValue] = []
    @State private var error: String?
    @State private var info: String?
    @State private var busy = false
    @State private var confirmSend = false
    @State private var importing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if draft == nil && error == nil { ProgressView("Entwurf wird angelegt …").frame(maxWidth: .infinity).padding(30) }
                    if let error { Text(error).ufFont(13).foregroundStyle(UF.bad).accessibilityIdentifier("unimail.compose.error") }
                    if let info { Text(info).ufFont(13).foregroundStyle(UF.muted) }
                    if draft != nil {
                        if let from = draft?.s("from"), !from.isEmpty { Text("Von: \(from)").ufFont(12.5).foregroundStyle(UF.muted) }
                        field("An", $to, id: "unimail.to")
                        field("Cc", $cc, id: "unimail.cc")
                        field("Bcc", $bcc, id: "unimail.bcc")
                        field("Betreff", $subject, id: "unimail.subject.field")
                        UFTextArea(placeholder: "Text", text: $text, minHeight: 240).accessibilityIdentifier("unimail.body")
                        if !attachments.isEmpty {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { _, a in
                                Label("\(a.s("name") ?? "") \(a.s("size") ?? "")", systemImage: "paperclip").ufFont(13)
                            }
                        }
                        UFFlexWrap(gap: 8) {
                            UFButton("Datei anhängen", icon: "upload", size: .small) { importing = true }
                                .accessibilityIdentifier("unimail.attach")
                            UFButton("Als Entwurf speichern", icon: "file", size: .small) { Task { await saveDraft() } }
                                .accessibilityIdentifier("unimail.save")
                        }
                        Text("Gesendet wird erst mit „Senden“ und deiner Bestätigung. Die E-Mail geht direkt von deinem Uni-Postfach aus, nicht über StudiNow.")
                            .ufFont(12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .disabled(busy)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Senden") { askSend() }
                        .disabled(draft == nil || busy)
                        .accessibilityIdentifier("unimail.send")
                }
            }
            .confirmationDialog(sendQuestion, isPresented: $confirmSend, titleVisibility: .visible) {
                Button("Senden") { Task { await send() } }.accessibilityIdentifier("unimail.send.confirm")
                Button("Abbrechen", role: .cancel) {}
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { r in
                guard case .success(let urls) = r, let u = urls.first else { return }
                Task { await attachFile(u) }
            }
        }
        .task { await create() }
    }

    private var title: String {
        switch request.action {
        case "reply": return "Antworten"
        case "replyall": return "Allen antworten"
        case "forward": return "Weiterleiten"
        default: return "Neue E-Mail"
        }
    }

    private var body_: JSONValue {
        SOGo.payload(draft ?? .object([:]), to: .text(to), cc: .text(cc), bcc: .text(bcc), subject: subject, text: text)
    }

    private var sendQuestion: String {
        let n = ["to", "cc", "bcc"].reduce(0) { $0 + (body_[$1]?.array?.count ?? 0) }
        return n == 1 ? "E-Mail an 1 Empfänger senden?" : "E-Mail an \(n) Empfänger senden?"
    }

    private func field(_ label: String, _ v: Binding<String>, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).ufFont(13, 600).foregroundStyle(UF.text2).frame(width: 60, alignment: .leading)
            UFTextInput(label, text: v).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(id)
        }
    }

    private func create() async {
        guard draft == nil else { return }
        do {
            let d = try await connection.newDraft(request.action, folder: request.folder, uid: request.uid)
            draft = d
            to = (d["to"]?.array ?? []).compactMap(\.string).joined(separator: ", ")
            cc = (d["cc"]?.array ?? []).compactMap(\.string).joined(separator: ", ")
            bcc = (d["bcc"]?.array ?? []).compactMap(\.string).joined(separator: ", ")
            subject = d.s("subject") ?? ""
            text = d.s("text") ?? ""
            if let t = request.to, !t.isEmpty, to.isEmpty { to = t }
            if let s = request.subject, !s.isEmpty, subject.isEmpty { subject = s }
            attachments = d.list("attachments")
            if let a = request.attachment {
                attachments.append(try await connection.attach(d, name: a.name, data: a.data, mime: a.mime))
            }
        } catch {
            self.error = UniMailConnection.message(error)
        }
    }

    private func attachFile(_ u: URL) async {
        guard let d = draft else { return }
        busy = true
        defer { busy = false }
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: u)
            let mime = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            attachments.append(try await connection.attach(d, name: u.lastPathComponent, data: data, mime: mime))
            error = nil
        } catch {
            self.error = UniMailConnection.message(error)
        }
    }

    private func saveDraft() async {
        guard let d = draft else { return }
        busy = true
        defer { busy = false }
        do {
            try await connection.save(d, body: body_)
            info = "Als Entwurf gespeichert."
            error = nil
        } catch {
            self.error = UniMailConnection.message(error)
        }
    }

    /// Knopf "Senden": erst pruefen, dann fragen; gesendet wird nur aus der Rueckfrage
    private func askSend() {
        if let e = SOGo.checkSend(body_) { error = e; return }
        if subject.trimmingCharacters(in: .whitespaces).isEmpty { info = "Hinweis: Die E-Mail hat keinen Betreff." }
        confirmSend = true
    }

    private func send() async {
        guard let d = draft else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await connection.send(d, body: body_)
            if r.ok {
                onDone(true)
                dismiss()
            } else {
                error = r.message
            }
        } catch {
            self.error = UniMailConnection.message(error)
        }
    }
}

/// Aus dem Dokument: eigene Loesung als PDF (`NotesExport`, wie "PDF exportieren") an eine neue Uni-Mail haengen
struct UniMailDocumentEntry: View {
    let store: DocumentStore
    let api: APIClient
    @ObservedObject var connection: UniMailConnection
    @State private var request: UniMailComposeRequest?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    static func offered(api: APIClient, connection: UniMailConnection?) -> Bool { api.isLocal && connection?.isConnected == true }

    var body: some View {
        Group {
            if let request {
                UniMailComposeSheet(connection: connection, request: request)
            } else {
                VStack(spacing: 14) {
                    if let error { Text(error).foregroundStyle(UF.bad); Button("Schließen") { dismiss() } } else { ProgressView("PDF wird erstellt …") }
                }
                .padding(30)
            }
        }
        .task {
            guard request == nil else { return }
            do {
                let r = try await NotesExport.pdf(for: store, api: api, options: .init(includeSideNotes: true, folder: "uni-mail"))
                request = UniMailComposeRequest(attachment: (r.url.lastPathComponent, try Data(contentsOf: r.url), "application/pdf"))
            } catch {
                self.error = LocalBackendHost.message(for: error)
            }
        }
    }
}

// MARK: - Uni-Kalender

struct UniCalendarCard: View {
    @ObservedObject var connection: UniMailConnection
    @State private var events: [JSONValue] = []
    @State private var busy = false

    var body: some View {
        UFCard {
            UFCardHead("Uni-Kalender", icon: "calendar")
            Text("Termine aus deinem Uni-Kalender (SOGo) erscheinen im Lernkalender und im Stundenplan als „Uni-Kalender“ – nur lesend; ändern kannst du sie im Uni-Kalender. Ganztägige Termine stehen nur hier.")
                .ufFont(13).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            UFFlexWrap(gap: 8) {
                UFButton("Nächste 7 Tage übernehmen", icon: "sync", size: .small) { Task { await run(7) } }
                    .accessibilityIdentifier("unimail.calendar.7")
                UFButton("Nächste 30 Tage übernehmen", icon: "sync", size: .small) { Task { await run(30) } }
                    .accessibilityIdentifier("unimail.calendar.30")
            }
            .disabled(busy)
            .padding(.top, 8)
            if let m = connection.calendarMessage {
                Text(m).ufFont(12.8).foregroundStyle(UF.text2).accessibilityIdentifier("unimail.calendar.message")
            }
            ForEach(Array(events.prefix(30).enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.when(e)).ufFont(12.5, 600).foregroundStyle(UF.muted)
                    Text(e.s("title") ?? "Termin").ufFont(14, 600).foregroundStyle(e["cancelled"]?.bool == true ? UF.muted : UF.text)
                        .strikethrough(e["cancelled"]?.bool == true)
                    if let loc = e.s("location"), !loc.isEmpty {
                        // Raumfinder nur an der LUH; an der Uni Hildesheim bleibt der Ort Text
                        if connection.site.roomLinks { UFRoomLink(text: loc, size: 12.8) } else {
                            Text(loc).ufFont(12.8).foregroundStyle(UF.text2).accessibilityIdentifier("unimail.event.location")
                        }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("unimail.event")
            }
        }
        .task(id: connection.finishedRuns) { events = await connection.upcomingEvents() }
    }

    static func when(_ e: JSONValue) -> String {
        let st = e.s("start") ?? "", en = e.s("end") ?? ""
        let day = UFFmt.date(String(st.prefix(10)))
        if e["all_day"]?.bool == true {
            return st.prefix(10) == en.prefix(10) ? "\(day), ganztägig" : "\(day) – \(UFFmt.date(String(en.prefix(10)))), ganztägig"
        }
        return "\(day), \(st.dropFirst(11).prefix(5))–\(en.dropFirst(11).prefix(5))"
    }

    private func run(_ days: Int) async {
        busy = true
        defer { busy = false }
        await connection.importCalendar(days: days)
        events = await connection.upcomingEvents()
    }
}
