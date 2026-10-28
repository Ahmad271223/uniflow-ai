import QuickLook
import SwiftUI
import UniFlowCore
import WebKit

/// Stud.IP direkt auf dem iPad: Anmeldung, Kursauswahl, Abgleich, heruntergeladene Dateien. Im UniFlow-Design
/// (Karten, Knoepfe, Icons wie die uebrigen Seiten), weil die leeren Zustaende ohne Server hierher fuehren.
struct StudIPView: View {
    @EnvironmentObject private var studip: StudIPSync
    @State private var showLogin = false
    @State private var preview: URL?
    @State private var confirmSignOut = false

    var body: some View {
        UFContent(maxWidth: 860) {
            UFPageHead("Stud.IP", sub: "Stud.IP der Leibniz Universität Hannover")
            VStack(alignment: .leading, spacing: 16) {
                accountCard
                if !studip.courses.isEmpty { coursesCard }
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { g in groupCard(g) }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview)
        .sheet(isPresented: $showLogin) {
            StudIPLoginView(base: StudIPSync.base, dataStore: studip.websiteDataStore) { cookies in
                showLogin = false
                studip.signedIn(cookies: cookies)
            }
        }
        .confirmationDialog("Von Stud.IP abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Abmelden", role: .destructive) { Task { @MainActor in await studip.signOut() } }
            Button("Abmelden und Dateien löschen", role: .destructive) {
                Task { @MainActor in await studip.signOut(); await studip.removeDownloads() }
            }
        } message: {
            Text(Self.signOutMessage)
        }
    }

    // MARK: Konto und Abgleich

    static let accountText = "Du meldest dich auf der Seite der Universität an und tippst selbst auf „Anmelden“. Studora speichert nur das Sitzungs-Cookie im Schlüsselbund dieses iPads (nicht in iCloud, nie auf einem Server), nie Benutzername oder Passwort – die merkt sich auf Wunsch iOS. Dateien werden nur auf diesem Gerät gespeichert und nicht weitergegeben. Abgleich beim Öffnen der App (höchstens alle 30 Minuten) und auf Knopfdruck."
    static let signOutMessage = "Das Sitzungs-Cookie und die Anmeldung in der Webansicht werden gelöscht. Ein Passwort, das iOS gesichert hat, bleibt unter „Passwörter“."

    private var accountCard: some View {
        UFCard {
            UFCardHead("Verbindung", icon: "graduation") { badge }
            status
            UFFlexWrap(gap: 9.6) {
                if studip.phase == .signedOut || studip.phase == .needsLogin {
                    UFButton("Bei Stud.IP anmelden", icon: "arrow-right", kind: .primary) { showLogin = true }
                } else {
                    UFButton("Jetzt abgleichen", icon: "sync", kind: .primary) { Task { @MainActor in await studip.run() } }
                        .disabled(studip.isRunning)
                    UFButton("Abmelden", icon: "log-out", kind: .danger) { confirmSignOut = true }
                        .disabled(studip.isRunning)
                }
            }
            .padding(.top, 12.8)
            Text(Self.accountText)
                .ufFont(13.12).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12.8)
        }
    }

    @ViewBuilder private var badge: some View {
        switch studip.phase {
        case .signedOut: UFBadge("nicht angemeldet", tone: .neutral)
        case .needsLogin: UFBadge("Anmeldung abgelaufen", tone: .warn, icon: "alert")
        case .running: UFBadge("gleicht ab", tone: .info, icon: "sync")
        case .failed: UFBadge("Fehler", tone: .bad, icon: "alert")
        case .idle: UFBadge("verbunden", tone: .ok, icon: "check")
        }
    }

    @ViewBuilder private var status: some View {
        switch studip.phase {
        case .signedOut:
            Text("Nicht angemeldet.").ufFont(14.5).foregroundStyle(UF.text2)
        case .needsLogin:
            Text("Die Anmeldung ist abgelaufen – bitte neu anmelden.").ufFont(14.5).foregroundStyle(UF.warn)
        case .running(let text):
            HStack(spacing: 9.6) {
                ProgressView().tint(UF.accent)
                Text(text).ufFont(14.5).foregroundStyle(UF.text2).lineLimit(2)
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 6) {
                UFIcon("alert", size: 16).padding(.top, 2)
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .ufFont(14.5).foregroundStyle(UF.bad)
        case .idle:
            if let last = studip.lastRun {
                VStack(alignment: .leading, spacing: 2.4) {
                    Text("Zuletzt abgeglichen: \(last.formatted(date: .abbreviated, time: .shortened))")
                        .ufFont(14.5).foregroundStyle(UF.text2)
                    if let s = studip.lastSummary { Text(s).ufFont(13.12).foregroundStyle(UF.muted) }
                }
            } else {
                Text("Angemeldet.").ufFont(14.5).foregroundStyle(UF.text2)
            }
        }
    }

    // MARK: Kurse

    private var coursesCard: some View {
        UFCard {
            UFCardHead("Kurse", icon: "book") { UFBadge("\(studip.selectedCourses.count) von \(studip.courses.count)", tone: .neutral) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(studip.courses, id: \.id) { c in
                    CourseRow(title: c.title, semester: c.semesterTitle, isOn: Binding(
                        get: { studip.selectedCourses.contains(c.id) },
                        set: { on in if on { studip.selectedCourses.insert(c.id) } else { studip.selectedCourses.remove(c.id) } }))
                        .disabled(studip.isRunning)
                }
            }
            Text("Beim ersten Abgleich sind die Kurse des aktuellen Semesters ausgewählt.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 8)
        }
    }

    /// Kurs mit Haken (wie .check im Web): Kaestchen in --accent, Titel und Semester
    private struct CourseRow: View {
        let title: String
        let semester: String?
        @Binding var isOn: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button { isOn.toggle() } label: {
                HStack(alignment: .top, spacing: 9.6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4).fill(isOn ? UF.accent : UF.surface)
                        RoundedRectangle(cornerRadius: 4).strokeBorder(isOn ? UF.accent : UF.lineStrong, lineWidth: 1)
                        if isOn { UFIcon("check", size: 12).foregroundStyle(.white) }
                    }
                    .frame(width: 18, height: 18)
                    .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).ufFont(14.5, 550).foregroundStyle(UF.text).multilineTextAlignment(.leading)
                        if let semester { Text(semester).ufFont(12.8).foregroundStyle(UF.muted) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7.2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.55)
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }

    // MARK: Dateien

    private struct EntryGroup: Identifiable {
        let id: String
        let entries: [StudIPLibrary.DownloadedFile]
    }

    private var groups: [EntryGroup] {
        let byCourse = Dictionary(grouping: studip.entries, by: { $0.courseTitle })
        return byCourse.keys.sorted().map { EntryGroup(id: $0, entries: byCourse[$0] ?? []) }
    }

    private func groupCard(_ g: EntryGroup) -> some View {
        UFCard {
            UFCardHead(g.id, icon: "folder") { UFBadge("\(g.entries.count)", tone: .neutral) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(g.entries, id: \.id) { e in
                    Button { preview = studip.fileURL(e) } label: {
                        UFItemRow(e.name, sub: e.folder.isEmpty ? nil : e.folder) {
                            UFIcon(e.mime == "application/pdf" || e.name.lowercased().hasSuffix(".pdf") ? "file-text" : "file", size: 18)
                                .foregroundStyle(UF.muted)
                        } trailing: {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))
                                .ufFont(12.8).foregroundStyle(UF.muted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Anmeldung auf der echten Stud.IP-Seite als Blatt (Stud.IP-Seite, Karte "Stud.IP verbinden"): die Anmeldeansicht
/// `StudIPLoginPane` mit Titel und "Abbrechen". Beim ersten Start steht dieselbe Anmeldeansicht im FirstLoginFlow.
struct StudIPLoginView: View {
    let base: URL
    /// Datenspeicher des Containers (Apple-Nutzer, Hochschule), nie `.default()`
    let dataStore: WKWebsiteDataStore
    let onSignedIn: ([HTTPCookie]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            StudIPLoginPane(base: base, dataStore: dataStore, onSignedIn: onSignedIn) { EmptyView() }
                .navigationTitle("Stud.IP-Anmeldung")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}

/// Anmeldung auf der echten Stud.IP-Seite. Sobald Stud.IP die Sitzung bestaetigt (users/me), werden die Cookies
/// an `onSignedIn` uebergeben. Benutzername und Passwort tippt der Mensch auf den Seiten der LUH (Stud.IP-Login,
/// WebSSO) selbst; die App liest und speichert sie nicht, ein gespeichertes Passwort setzt hoechstens iOS ein
/// (`UniversityLoginHint` darunter). `bottom` steht unter dem Hinweis (erster Start: "Später anmelden"). Nur Debug
/// mit -UFLoginStub: lokale Nachbildung statt der Stud.IP-Seite (DebugUniStub).
struct StudIPLoginPane<Bottom: View>: View {
    let base: URL
    let dataStore: WKWebsiteDataStore
    let onSignedIn: ([HTTPCookie]) -> Void
    @ViewBuilder let bottom: Bottom
    @State private var checking = false
    @State private var done = false
    /// Sitzungspruefung scheiterte (z. B. Stud.IP kurz nicht erreichbar): Knopf "Anmeldung prüfen"
    @State private var checkFailed = false
    @StateObject private var load = UFWebLoadState()

    init(base: URL, dataStore: WKWebsiteDataStore, onSignedIn: @escaping ([HTTPCookie]) -> Void, @ViewBuilder bottom: () -> Bottom) {
        self.base = base
        self.dataStore = dataStore
        self.onSignedIn = onSignedIn
        self.bottom = bottom()
    }

    var body: some View {
        StudIPWebView(url: DebugUniStub.loginPage("studip", real: base.appendingPathComponent("dispatch.php/login")), dataStore: dataStore,
                      load: load) { webView in check(webView) }
            .ufWebLoadFailure(load)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if checking {
                        HStack(spacing: 9.6) {
                            ProgressView().controlSize(.small)
                            Text("Anmeldung wird geprüft …").ufFont(13.12).foregroundStyle(UF.text2)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(UF.surface)
                    }
                    if checkFailed {
                        HStack(spacing: 9.6) {
                            Text("Die Anmeldung ließ sich nicht bestätigen.").ufFont(13.12).foregroundStyle(UF.text2)
                            Spacer()
                            UFButton("Anmeldung prüfen", icon: "refresh", size: .small) { if let w = load.webView { check(w, force: true) } }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(UF.warnSoft)
                    }
                    UniversityLoginHint()
                    bottom
                }
            }
    }

    /// Nach jedem geladenen Stud.IP-Seitenaufruf ausserhalb der Anmeldeseite pruefen, ob die Sitzung gilt. Scheitert die
    /// Pruefung, wird sie nach einer kurzen Pause einmal wiederholt; danach "Anmeldung prüfen" (vorher geschah nichts
    /// Sichtbares).
    private func check(_ webView: WKWebView, force: Bool = false) {
        guard !done else { return }
        if DebugUniStub.isSignedIn(webView.url, service: "studip") {
            done = true
            onSignedIn(DebugUniStub.studipCookies())
            return
        }
        guard !checking, let url = webView.url, url.host == base.host, force || !url.path.contains("/dispatch.php/login") else { return }
        checking = true
        checkFailed = false
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let host = base.host ?? ""
            let mine = cookies.filter { host.hasSuffix($0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain) }
            Task { @MainActor in
                var ok = await StudIPSync.sessionIsValid(mine)
                if !ok {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    ok = await StudIPSync.sessionIsValid(mine)
                }
                checking = false
                if ok, !done { done = true; onSignedIn(mine) } else if !ok { checkFailed = true }
            }
        }
    }
}

/// Ladezustand einer Anmelde-Webansicht: Fehler beim Laden (kein Netz, Zeitueberschreitung, Hochschulseite nicht
/// erreichbar) und die Webansicht fuer "Erneut versuchen". Vorher blieb die Seite dann leer oder stehen.
@MainActor
final class UFWebLoadState: ObservableObject {
    @Published var failure: String?
    weak var webView: WKWebView?
    /// zuletzt angeforderte Seite (bei einem Fehler vor dem ersten Laden hat die Webansicht noch keine Adresse)
    var lastURL: URL?

    /// Fehler einer Navigation; Abbrueche (eigene, Moodle-Antwort) sind keiner
    func failed(_ error: Error) {
        guard let text = Self.message(for: error) else { return }
        failure = text
    }

    func retry() {
        failure = nil
        guard let webView else { return }
        if webView.url != nil { webView.reload() } else if let lastURL { webView.load(URLRequest(url: lastURL)) }
    }

    /// Verstaendliche Meldung oder nil, wenn es kein Fehler ist (abgebrochen, von der App selbst angehalten)
    nonisolated static func message(for error: Error) -> String? {
        let e = error as NSError
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return nil }
        // WebKitErrorFrameLoadInterruptedByPolicyChange: Navigation von der App angehalten (z. B. Moodle-Antwort)
        if e.domain == "WebKitErrorDomain", e.code == 102 { return nil }
        if e.domain == NSURLErrorDomain, [NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorNetworkConnectionLost].contains(e.code) {
            return "Keine Internetverbindung. Prüfe WLAN oder mobile Daten und versuche es erneut."
        }
        return "Die Seite der Universität ist gerade nicht erreichbar. Prüfe die Verbindung und versuche es erneut."
    }
}

extension View {
    /// Karte "Seite der Universität nicht erreichbar" mit "Erneut versuchen" ueber einer Anmelde-Webansicht
    func ufWebLoadFailure(_ load: UFWebLoadState) -> some View {
        modifier(UFWebLoadFailureCard(load: load))
    }
}

private struct UFWebLoadFailureCard: ViewModifier {
    @ObservedObject var load: UFWebLoadState

    func body(content: Content) -> some View {
        content.overlay {
            if let failure = load.failure {
                VStack {
                    UFCard {
                        UFCardHead("Seite nicht erreichbar", icon: "alert")
                        Text(failure).ufFont(14.5).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                        UFButton("Erneut versuchen", icon: "refresh", kind: .primary) { load.retry() }
                            .padding(.top, 12.8)
                    }
                    .frame(maxWidth: 560)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(UF.bg)
            }
        }
    }
}

/// Eingebettete Webansicht fuer die Anmeldung aller Hochschulen (Stud.IP der LUH, CAS fuer Learnweb und LSF der Uni
/// Hildesheim). Eigener, dauerhafter Datenspeicher je Container (Apple-Nutzer, Hochschule;
/// `WKWebsiteDataStore(forIdentifier:)`, nicht Safari, nicht `.default()`): die Hochschul-Anmeldung bleibt erhalten,
/// sodass eine erneute Anmeldung oft ohne Passwort gelingt, und eine andere Hochschule oder ein anderes Konto sieht
/// keines ihrer Cookies.
///
/// Passwoerter (Entscheidung des Inhabers, 27.10.2026): merken darf sie nur iOS, nie die App. Die Webansicht hat
/// deshalb keine eigenen Skripte, keinen Nachrichtenkanal zur Seite und greift nicht in Formulare oder `autocomplete`
/// ein (`loginConfiguration`: nur der Datenspeicher, sonst der Standard von WebKit). Das Anmeldeformular ist genau die
/// Seite der Hochschule; iOS bietet dort sein Passwort-Autofill aus dem (iCloud-)Schluesselbund an (Schluessel-Symbol
/// ueber der Tastatur). Nach dem Laden liest eine Ansicht hoechstens den Seiteninhalt, um eine angemeldete Seite oder
/// den Fehlertext des CAS zu erkennen (`outerHTML` enthaelt eingetippte Werte nicht).
///
/// `interceptNavigation` sieht jede Navigation vor dem Laden und bricht sie mit `true` ab (Moodle-SSO:
/// `moodlemobile://token=…` nie an das System). Der Hauptrahmen laedt nur HTTPS (und about:blank): eine auf http
/// herabgestufte Anmeldeseite wird nie angezeigt, auch nicht im Debug-Build mit ATS-Ausnahme fuer das lokale Netz.
/// Ladefehler meldet `load` (Karte mit "Erneut versuchen"). Nur fuer die Anmeldung verwenden, nie fuer Inhalte.
struct StudIPWebView: UIViewRepresentable {
    let url: URL
    let dataStore: WKWebsiteDataStore
    var interceptNavigation: (@MainActor (URL) -> Bool)? = nil
    var load: UFWebLoadState? = nil
    let onPageLoaded: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageLoaded: onPageLoaded, intercept: interceptNavigation, load: load)
    }

    /// Konfiguration jeder Anmelde-Webansicht: nur der Datenspeicher des Containers, sonst der Standard von WebKit (kein
    /// Benutzerskript, kein Nachrichtenkanal, nichts, was das Passwort-Autofill von iOS behindert)
    static func loginConfiguration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        return config
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: Self.loginConfiguration(dataStore: dataStore))
        view.navigationDelegate = context.coordinator
        load?.webView = view
        load?.lastURL = url
        // nur Debug mit -UFLoginStub: lokale Nachbildung der Anmeldeseite (DebugUniStub), Lesezugriff auf ihren Ordner
        if url.isFileURL { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) } else { view.load(URLRequest(url: url)) }
        return view
    }

    /// Hauptrahmen nur ueber HTTPS oder about:blank; andere Schemata (Moodle-Antwort) entscheidet `intercept`
    nonisolated static func blocksMainFrame(_ url: URL) -> Bool { url.scheme?.lowercased() == "http" }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onPageLoaded: (WKWebView) -> Void
        let intercept: (@MainActor (URL) -> Bool)?
        let load: UFWebLoadState?
        init(onPageLoaded: @escaping (WKWebView) -> Void, intercept: (@MainActor (URL) -> Bool)? = nil, load: UFWebLoadState? = nil) {
            self.onPageLoaded = onPageLoaded
            self.intercept = intercept
            self.load = load
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                if intercept?(url) == true || (navigationAction.targetFrame?.isMainFrame != false && StudIPWebView.blocksMainFrame(url)) {
                    decisionHandler(.cancel)
                    return
                }
                if navigationAction.targetFrame?.isMainFrame != false { load?.lastURL = url }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            load?.failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { load?.failed(error) }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onPageLoaded(webView) }
    }
}
