import SwiftUI
import UniFlowCore
import WebKit

// Hochschule Hannover (docs/HSH-2026-11-05.md): Anmeldung bei Moodle und im Campusmanagement in der Webansicht des
// Containers, Karte "Moodle & Campusmanagement" in den Einstellungen und auf der Dienste-Seite.

private struct HsHConnectionKey: EnvironmentKey {
    static let defaultValue: HsHConnection? = nil
}

extension EnvironmentValues {
    /// Verbindung der Hochschule Hannover des offenen Containers (`ContainerManager.hsh`); nil an anderen Hochschulen
    var hsh: HsHConnection? {
        get { self[HsHConnectionKey.self] }
        set { self[HsHConnectionKey.self] = newValue }
    }
}

/// Anmeldung auf der echten Seite (Moodle-Formular bzw. Startseite des Campusmanagements mit eigenem Formular; dort
/// bleibt "Anmelden mit SSO Hochschule Hannover" als zweiter Weg, seit 07.11.2026 nicht mehr der erste). Fertig,
/// sobald eine angemeldete Seite erscheint (`HsHConnection.isSignedIn`); dann `signedIn` (gleicht gleich ab). Die App
/// fuellt kein Passwort ein und speichert keins; ein gespeichertes setzt hoechstens iOS ein.
struct HsHLoginPane<Bottom: View>: View {
    let source: HsHConnection.Source
    @ObservedObject var connection: HsHConnection
    let onSignedIn: () -> Void
    @ViewBuilder let bottom: Bottom
    @StateObject private var load = UFWebLoadState()
    @State private var done = false
    /// Wie oft der IdP in diesem Blatt seine Fehlerseite zeigte (beim ersten Mal still einmal neu beim Dienst)
    @State private var idpErrors = 0
    @State private var showsIdPError = false

    init(source: HsHConnection.Source, connection: HsHConnection, onSignedIn: @escaping () -> Void, @ViewBuilder bottom: () -> Bottom) {
        self.source = source
        self.connection = connection
        self.onSignedIn = onSignedIn
        self.bottom = bottom()
    }

    static func entry(_ s: HsHConnection.Source) -> URL {
        UniversityProfile.hsh.loginService(s.loginService)?.entryURLs.first ?? UniversityProfile.hshMoodle
    }

    /// Campus: erst nach `HsHConnection.resetCampusLogin` laden (frische Sitzung, nie ein alter IdP-Zustand), ohne Cache
    @State private var ready = false

    var body: some View {
        Group {
            if source == .moodle || ready {
                StudIPWebView(url: DebugUniStub.loginPage("hsh-\(source.loginService)", real: Self.entry(source)),
                              dataStore: connection.websiteDataStore, load: load,
                              cachePolicy: source == .campus ? .reloadIgnoringLocalAndRemoteCacheData : .useProtocolCachePolicy) { webView in pageLoaded(webView) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
            .task {
                guard source == .campus, !ready else { return }
                await HsHConnection.resetCampusLogin(connection.websiteDataStore)
                ready = true
            }
            .ufWebLoadFailure(load)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if showsIdPError {
                        HsHIdPErrorHint(ownLogin: { restart(HISinOne.ownLoginURL) },
                                        retrySSO: { restart(UniversityProfile.hshCampusLogin) })
                    }
                    UniversityLoginHint()
                    UniRememberPasswordToggle(dataStore: connection.websiteDataStore)
                    bottom
                }
            }
    }

    private func pageLoaded(_ webView: WKWebView) {
        guard !done else { return }
        if DebugUniStub.isSignedIn(webView.url, service: "hsh-\(source.loginService)") {
            finish()
            return
        }
        guard let url = webView.url, HsHConnection.domains.contains(url.host?.lowercased() ?? "") else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML", in: nil, in: .defaultClient) { result in
            let html = (try? result.get()) as? String ?? ""
            if HsHConnection.isSignedIn(source, html: html, url: url) {
                finish()
            } else if source == .campus, HISinOne.isIdPErrorPage(html: html, url: url) {
                idpErrorShown()
            }
        }
    }

    /// Fehlerseite des SSO ("SSO Login – Ein Fehler ist aufgetreten … TrackID"): unten im Blatt der Hinweis
    /// `HsHIdPErrorHint` (direkt in HISinOne anmelden); beim ersten Mal zusaetzlich still einmal neu bei der
    /// SP-Login-URL mit frischer IdP-Sitzung (gleiches IdP-Cookie = gleiche TrackID, nie im alten Zustand bleiben)
    private func idpErrorShown() {
        idpErrors += 1
        if idpErrors == 1 { restart(UniversityProfile.hshCampusLogin, hint: true) } else { showsIdPError = true }
    }

    /// Neu laden (SP-Login-URL bzw. Startseite mit eigenem Formular), ohne Cache und mit frischer IdP-/Campus-Sitzung;
    /// Moodle bleibt
    private func restart(_ url: URL, hint: Bool = false) {
        showsIdPError = hint
        let store = connection.websiteDataStore
        Task { @MainActor in
            await HsHConnection.resetCampusLogin(store)
            load.failure = nil
            load.webView?.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        connection.signedIn(source)
        onSignedIn()
    }
}

/// Hinweis unten im Anmeldeblatt, wenn der IdP der HsH auf die Anfrage des Campusmanagements nur seine Fehlerseite
/// zeigt (07.11.2026: auch ohne App; fuer andere Dienste der HsH kam das Formular). Kein Passwortfehler, kein Fehler
/// der App. Erster Knopf: Startseite des Campusmanagements mit eigenem Formular (derselbe SSO-Account, ohne IdP).
struct HsHIdPErrorHint: View {
    let ownLogin: () -> Void
    let retrySSO: () -> Void

    static let title = "SSO der Hochschule gestört – direkt in HISinOne anmelden"
    static let text = "Die SSO-Seite der Hochschule Hannover meldet „Ein Fehler ist aufgetreten“. Das liegt an der Hochschule, nicht an deinem Passwort. Melde dich stattdessen direkt im Campusmanagement mit deinem SSO-Account an (Benutzerkennung und Passwort, ggf. erst „Zur Anmeldung“ tippen)."
    static let ownLoginTitle = "Direkt in HISinOne anmelden"
    static let retryTitle = "SSO erneut versuchen"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                UFIcon("alert", size: 15).foregroundStyle(UF.bad).padding(.top, 1.6)
                VStack(alignment: .leading, spacing: 2.4) {
                    Text(Self.title).ufFont(13.6, 650).foregroundStyle(UF.text)
                    Text(Self.text).ufFont(12.8).foregroundStyle(UF.text2)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            UFFlexWrap(gap: 9.6) {
                UFButton(Self.ownLoginTitle, icon: "arrow-right", kind: .primary, size: .small, action: ownLogin)
                    .accessibilityIdentifier("hsh.idpError.ownLogin")
                UFButton(Self.retryTitle, icon: "refresh", size: .small, action: retrySSO)
                    .accessibilityIdentifier("hsh.idpError.retry")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UF.bg)
        .accessibilityIdentifier("hsh.idpError")
    }
}

/// Anmeldung als Blatt (Einstellungen, Dienste)
struct HsHLoginView: View {
    let source: HsHConnection.Source
    @ObservedObject var connection: HsHConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HsHLoginPane(source: source, connection: connection, onSignedIn: { dismiss() }) { EmptyView() }
                .navigationTitle(source == .moodle ? "Moodle-Anmeldung" : "Campusmanagement-Anmeldung")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}

/// Karte "Moodle & Campusmanagement": Stand je Quelle, Verbinden/Erneut anmelden, Jetzt abgleichen, Abmelden
struct HsHSourcesCard: View {
    @Environment(\.hsh) private var hsh

    static let text = UFDevice.adapt("Moodle (Kurse, Dateien, Fristen) und Campusmanagement (Stundenplan, Leistungen, angemeldete Prüfungen) der Hochschule Hannover. Du meldest dich zweimal mit deinem SSO-Account an (Moodle und Campusmanagement haben keine gemeinsame Anmeldung) und tippst selbst auf „Anmelden“; dein Passwort merkt StudiNow nur, wenn du es zulässt, und nur auf diesem iPad (dann meldet StudiNow dich selbst wieder an). Daten bleiben nur auf diesem iPad.")

    var body: some View {
        if let hsh { Panel(connection: hsh) }
    }

    private struct Panel: View {
        @ObservedObject var connection: HsHConnection
        /// iPhone: Studienservice als eigener Kasten, Knoepfe in voller Breite
        @Environment(\.ufCompact) private var compact
        @State private var login: HsHConnection.Source?
        @State private var confirmSignOut = false

        var body: some View {
            UFCard {
                UFCardHead("Moodle & Campusmanagement", icon: "graduation") {
                    if HsHConnection.Source.allCases.allSatisfy(connection.isConnected) {
                        UFBadge("verbunden", tone: .ok)
                    } else if let missing = HsHConnection.Source.allCases.first(where: { !connection.isConnected($0) }), connection.anyConnected {
                        UFBadge("\(missing.rawValue) fehlt", tone: .warn)
                    } else {
                        UFBadge("nicht verbunden", tone: .warn)
                    }
                }
                Text(HsHSourcesCard.text).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(HsHConnection.Source.allCases) { s in
                        let st = connection.state(s)
                        UFSourceRow(s.rawValue, s == .moodle ? "Dateien, Fristen" : "Stundenplan, Leistungen, Prüfungen") {
                            UFBadge(HsHConnection.statusText(s, st), tone: Self.tone(st)).fixedSize()
                        } actions: {
                            if connection.needsAttention(s) {
                                UFButton(st == .needsLogin ? "Erneut anmelden" : "Verbinden", icon: "arrow-right", kind: .primary, size: .small) {
                                    login = s
                                }
                                .fixedSize()
                                .accessibilityIdentifier("hsh.connect.\(s.loginService)")
                            }
                        }
                        // der Grund eines Fehlers steht dabei (vorher nur das Abzeichen "Fehler")
                        if let why = connection.failureReason(s) {
                            Text(why).ufFont(12.8).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 6)
                                .accessibilityIdentifier("hsh.failure.\(s.loginService)")
                        }
                    }
                }
                .padding(.top, 8)
                // Stand der Moodle-Dateien in einer klaren Zeile (07.11.2026: "0 Dateien" ohne Grund am Geraet)
                if let files = connection.filesStatus {
                    Text(files).ufFont(12.8).foregroundStyle(files.contains("nicht lesbar") || files.contains("abgelaufen") ? UF.bad : UF.text2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                        .accessibilityIdentifier("hsh.files")
                }
                if !connection.messages.isEmpty {
                    HsHMessagesDisclosure(messages: connection.messages)
                }
                if let note = connection.registrationsMessage {
                    Text(note).ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 6).modifier(UFPhoneWrap())
                }
                if let note = connection.messagesNote {
                    Text(note).ufFont(12.8).foregroundStyle(UF.muted).modifier(UFPhoneWrap())
                }
                if let ss = connection.studyService {
                    // Studienservice (nur lesen): Rueckmeldung, offene Zahlungen (Semesterbeitrag), Bescheide
                    VStack(alignment: .leading, spacing: 4) {
                        if compact {
                            Text("Studienservice").ufFont(13.6, 650).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
                        }
                        if let r = ss["reregistration"]?.string { UFBadge(r, tone: r.lowercased().hasPrefix("nicht") ? .warn : .ok, icon: "check") }
                        if let n = ss["open_payments"]?.int {
                            Text(n == 0 ? "Semesterbeitrag: keine offenen Zahlungen" : "Semesterbeitrag: \(n) offene \(n == 1 ? "Zahlung" : "Zahlungen") – im Campusmanagement ansehen")
                                .ufFont(12.8).foregroundStyle(n == 0 ? UF.muted : UF.bad)
                                .modifier(UFPhoneWrap())
                        }
                        if let d = ss["documents"]?.int {
                            Text(d == 0 ? "Bescheide und Bescheinigungen: keine vorhanden" : "Bescheide und Bescheinigungen: \(d) im Campusmanagement")
                                .ufFont(12.8).foregroundStyle(UF.muted)
                                .modifier(UFPhoneWrap())
                        }
                        Link("Studienservice öffnen", destination: HISinOneStudyService.url).ufFont(12.8)
                            .frame(minHeight: compact ? 44 : nil)
                            .accessibilityIdentifier("hsh.studyService.open")
                    }
                    .padding(compact ? 12 : 0)
                    .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(compact ? UF.surface2 : Color.clear))
                    .padding(.top, 6)
                    .accessibilityIdentifier("hsh.studyService")
                }
                if connection.anyConnected {
                    UFFlexWrap(gap: 9.6) {
                        UFButton("Jetzt abgleichen", icon: "sync", size: .small) { Task { await connection.run(forceGrades: true) } }
                            .disabled(connection.isRunning)
                            .accessibilityIdentifier("hsh.sync")
                        UFButton("Abmelden", icon: "log-out", kind: .danger, size: .small) { confirmSignOut = true }
                            .disabled(connection.isRunning)
                    }
                    .padding(.top, 9.6)
                }
            }
            .accessibilityIdentifier("hsh.card")
            .sheet(item: $login) { s in HsHLoginView(source: s, connection: connection) }
            .confirmationDialog("Von Moodle und Campusmanagement abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) { Task { await connection.signOut() } }
            } message: {
                Text(HsHConnection.signOutMessage)
            }
        }

        static func tone(_ s: HsHConnection.State) -> UFTone {
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

/// Meldungen des letzten Abgleichs ("0 neue/geänderte Dateien aus 7 Moodle-Kursen", "Stundenplan: …"), eingeklappt
/// hinter einer Zeile wie bei der Uni Hildesheim (`HildesheimStatusLine`)
struct HsHMessagesDisclosure: View {
    let messages: [String]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { UFMotion.toggle { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(open ? "Meldungen des letzten Abgleichs" : messages.joined(separator: " · "))
                        .ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    UFIcon("chevron-down", size: 14).foregroundStyle(UF.muted).rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Meldungen des letzten Abgleichs")
            .accessibilityHint(open ? "Zuklappen" : "Aufklappen")
            .accessibilityIdentifier("hsh.messages")
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(messages.indices, id: \.self) { i in
                        Text(messages[i]).ufFont(12.8).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 12)
                .ufReveal()
            }
        }
        .padding(.top, 6)
    }
}
