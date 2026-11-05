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

/// Anmeldung auf der echten Seite (Moodle-Formular bzw. "Anmelden mit SSO Hochschule Hannover" beim IdP). Fertig,
/// sobald eine angemeldete Seite erscheint (`HsHConnection.isSignedIn`); dann `signedIn` (gleicht gleich ab). Die App
/// fuellt kein Passwort ein und speichert keins; ein gespeichertes setzt hoechstens iOS ein.
struct HsHLoginPane<Bottom: View>: View {
    let source: HsHConnection.Source
    @ObservedObject var connection: HsHConnection
    let onSignedIn: () -> Void
    @ViewBuilder let bottom: Bottom
    @StateObject private var load = UFWebLoadState()
    @State private var done = false

    init(source: HsHConnection.Source, connection: HsHConnection, onSignedIn: @escaping () -> Void, @ViewBuilder bottom: () -> Bottom) {
        self.source = source
        self.connection = connection
        self.onSignedIn = onSignedIn
        self.bottom = bottom()
    }

    static func entry(_ s: HsHConnection.Source) -> URL {
        UniversityProfile.hsh.loginService(s.loginService)?.entryURLs.first ?? UniversityProfile.hshMoodle
    }

    var body: some View {
        StudIPWebView(url: DebugUniStub.loginPage("hsh-\(source.loginService)", real: Self.entry(source)),
                      dataStore: connection.websiteDataStore, load: load) { webView in pageLoaded(webView) }
            .ufWebLoadFailure(load)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    UniversityLoginHint()
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
            if HsHConnection.isSignedIn(source, html: html, url: url) { finish() }
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        connection.signedIn(source)
        onSignedIn()
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

    static let text = "Moodle (Kurse, Dateien, Fristen) und Campusmanagement (Stundenplan, Leistungen, angemeldete Prüfungen) der Hochschule Hannover. Du meldest dich zweimal mit deinem SSO-Account an (Moodle und Campusmanagement haben keine gemeinsame Anmeldung) und tippst selbst auf „Anmelden“; dein Passwort speichert StudiNow nicht (das kann iOS im Schlüsselbund übernehmen). Daten bleiben nur auf diesem iPad."

    var body: some View {
        if let hsh { Panel(connection: hsh) }
    }

    private struct Panel: View {
        @ObservedObject var connection: HsHConnection
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
                    }
                }
                .padding(.top, 8)
                if let note = connection.registrationsMessage {
                    Text(note).ufFont(12.8).foregroundStyle(UF.muted).padding(.top, 6)
                }
                if let note = connection.messagesNote {
                    Text(note).ufFont(12.8).foregroundStyle(UF.muted)
                }
                if let ss = connection.studyService {
                    // Studienservice (nur lesen): Rueckmeldung, offene Zahlungen (Semesterbeitrag), Bescheide
                    VStack(alignment: .leading, spacing: 4) {
                        if let r = ss["reregistration"]?.string { UFBadge(r, tone: r.lowercased().hasPrefix("nicht") ? .warn : .ok, icon: "check") }
                        if let n = ss["open_payments"]?.int {
                            Text(n == 0 ? "Semesterbeitrag: keine offenen Zahlungen" : "Semesterbeitrag: \(n) offene \(n == 1 ? "Zahlung" : "Zahlungen") – im Campusmanagement ansehen")
                                .ufFont(12.8).foregroundStyle(n == 0 ? UF.muted : UF.bad)
                        }
                        if let d = ss["documents"]?.int {
                            Text(d == 0 ? "Bescheide und Bescheinigungen: keine vorhanden" : "Bescheide und Bescheinigungen: \(d) im Campusmanagement")
                                .ufFont(12.8).foregroundStyle(UF.muted)
                        }
                        Link("Studienservice öffnen", destination: HISinOneStudyService.url).ufFont(12.8)
                    }
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
