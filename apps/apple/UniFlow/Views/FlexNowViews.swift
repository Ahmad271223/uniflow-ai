import SwiftUI
import UniFlowCore
import WebKit

// Uni Goettingen, FlexNow 2 (27.11.2026, docs/GOETTINGEN-FLEXNOW-2026-11-27.md): Anmeldung in der Webansicht des
// Containers und Karte "Prüfungen (FlexNow)" unter "Uni & Noten" mit den angemeldeten Pruefungen und ihrer
// Abmeldefrist. Nur lesend: an- und abmelden tut der Mensch selbst in FlexNow; Noten liest StudiNow dort noch nicht.

private struct FlexNowConnectionKey: EnvironmentKey {
    static let defaultValue: FlexNowConnection? = nil
}

extension EnvironmentValues {
    /// FlexNow-Verbindung des offenen Goettinger Containers (`ContainerManager.flexnow`); sonst nil
    var flexnow: FlexNowConnection? {
        get { self[FlexNowConnectionKey.self] }
        set { self[FlexNowConnectionKey.self] = newValue }
    }
}

/// Texte (rein, testbar)
enum FlexNowText {
    static let title = "Prüfungen (FlexNow)"
    static let readOnly = "StudiNow liest in FlexNow nur „Aktuelles → Aktuelle Prüfungen“: was du angemeldet hast und bis wann du dich abmelden kannst. An- und abmelden tust du selbst in FlexNow. Noten liest StudiNow aus FlexNow noch nicht."
    static let reminderTitle = "An das Ende der Abmeldefrist erinnern"
    static let reminderNote = "7 und 2 Tage vor dem Ende der Abmeldefrist um 9:00 Uhr."
    static let uniPageHint = "Landest du nach der Anmeldung wieder auf der Seite der Universität, tippe auf „FlexNow neu öffnen“."

    /// Zeile zur Frist: "Abmeldung bis Do, 10.12.2026, 23:59 Uhr · noch 13 Tage" und ihr Ton (bald: warnen, vorbei: leise)
    static func withdrawLine(_ r: ExamRegistrationState.Registered, today: String) -> (text: String, tone: UFTone)? {
        guard let iso = r.withdrawUntil, let end = Fmt.date(iso), let now = Fmt.date(today) else {
            return r.withdrawText.map { ("Abmeldung bis \($0)", .neutral) }
        }
        let time = r.withdrawTime.map { ", \($0) Uhr" } ?? ""
        let date = "\(UFFmt.weekdayShort(iso)), \(UFFmt.date(iso))\(time)"
        let left = Fmt.calendar.dateComponents([.day], from: now, to: end).day ?? 0
        switch left {
        case ..<0: return ("Abmeldefrist vorbei (\(UFFmt.date(iso)))", .neutral)
        case 0: return ("Abmeldung nur noch heute bis \(r.withdrawTime.map { "\($0) Uhr" } ?? "Fristende")", .bad)
        case 1: return ("Abmeldung bis morgen, \(date)", .warn)
        case 2...3: return ("Abmeldung bis \(date) · noch \(left) Tage", .warn)
        default: return ("Abmeldung bis \(date) · noch \(left) Tage", .neutral)
        }
    }

    /// Text ohne Zeilen, ehrlich je nach Stand
    static func emptyText(_ state: FlexNowConnection.State, checked: Bool) -> String {
        switch state {
        case .notConnected: return "Melde dich einmal bei FlexNow an, dann zeigt StudiNow hier deine angemeldeten Prüfungen mit Abmeldefrist."
        case .needsLogin: return "Die FlexNow-Anmeldung ist abgelaufen. Melde dich erneut an, dann liest StudiNow deine angemeldeten Prüfungen."
        case .running: return "Die angemeldeten Prüfungen werden gerade gelesen …"
        case .connected, .ok, .failed:
            return checked ? "In FlexNow sind gerade keine Prüfungen angemeldet." : "Noch nicht gelesen. Tippe auf „Angemeldete Prüfungen lesen“."
        }
    }

    /// "Zuletzt gelesen 27.11.2026 10:00 Uhr: …" bzw. Stand vom anderen Geraet
    static func checked(_ st: ExamRegistrationState?) -> String? {
        guard let st else { return nil }
        if st.registrationsSyncedAt != nil || st.registrationsCheckedAt != nil {
            return ExamRegistrationText.checked(st).replacingOccurrences(of: "Zuletzt abgerufen", with: "Zuletzt gelesen")
        }
        return nil
    }
}

/// Anmeldung bei FlexNow als Blatt (Karte "Prüfungen (FlexNow)")
struct FlexNowLoginView: View {
    @ObservedObject var connection: FlexNowConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FlexNowLoginPane(connection: connection, onSignedIn: { dismiss() })
                .navigationTitle("FlexNow-Anmeldung")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}

/// Echte Anmeldeseite von FlexNow in der Webansicht des Containers. Benutzerkennung und Passwort tippt der Mensch selbst
/// und tippt selbst auf "Login"; die App fuellt nichts vor. Fertig, sobald die angemeldete Studentenschnittstelle
/// (`/FN2SSS/`) dasteht (`FlexNowPage.isSignedIn`). Debug mit -UFLoginStub: Nachbildung `flexnow.html`.
struct FlexNowLoginPane: View {
    @ObservedObject var connection: FlexNowConnection
    let onSignedIn: () -> Void
    @StateObject private var load = UFWebLoadState()
    @State private var done = false
    /// nach der Anmeldung auf der Seite der Universitaet gelandet (im Browser der Claude-App am 26.11.2026 gesehen)
    @State private var onUniPage = false

    var body: some View {
        StudIPWebView(url: DebugUniStub.loginPage("flexnow", real: FlexNowPage.entry), dataStore: connection.websiteDataStore,
                      load: load, loginHelper: false, opensNewWindowsInPlace: true) { webView in pageLoaded(webView) }
            .ufWebLoadFailure(load)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        UFIcon("info", size: 15).foregroundStyle(onUniPage ? UF.warnText : UF.muted).padding(.top, 1.6)
                        Text(FlexNowText.uniPageHint).ufFont(12.8, onUniPage ? 650 : 500).foregroundStyle(onUniPage ? UF.text : UF.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button { reopen() } label: {
                            Text("FlexNow neu öffnen").ufFont(12.8, 600).foregroundStyle(UF.accentText).ufHitArea()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("flexnow.login.reopen")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(UF.surface)
                    UniversityLoginHint()
                    UniRememberPasswordToggle(dataStore: connection.websiteDataStore)
                }
            }
    }

    private func reopen() {
        onUniPage = false
        let url = DebugUniStub.isActive ? DebugUniStub.loginPage("flexnow", real: FlexNowPage.entry) : FlexNowPage.start
        if url.isFileURL { load.webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) } else {
            load.webView?.load(URLRequest(url: url))
        }
    }

    private func pageLoaded(_ webView: WKWebView) {
        guard !done else { return }
        if DebugUniStub.isSignedIn(webView.url, service: "flexnow") {
            finish()
            return
        }
        guard let url = webView.url else { return }
        if url.host?.lowercased() == "www.uni-goettingen.de" { onUniPage = true }
        guard FlexNowPage.isFlexNow(url) else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML", in: nil, in: .defaultClient) { result in
            let html = (try? result.get()) as? String ?? ""
            if FlexNowPage.isSignedIn(url: url, html: html) { finish() }
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        connection.signedIn()                                    // liest gleich einmal (unsichtbare Webansicht)
        onSignedIn()
    }
}

/// Karte "Prüfungen (FlexNow)" unter "Uni & Noten" (nur Uni Goettingen, nur auf dem Geraet)
struct FlexNowCard: View {
    @ObservedObject var connection: FlexNowConnection
    let api: APIClient?
    @Environment(\.ufCompact) private var compact
    @Environment(\.openURL) private var openURL
    @State private var state: ExamRegistrationState?
    @State private var login = false
    @State private var confirmSignOut = false

    private var today: String { UniFlowClock.system.today }

    var body: some View {
        UFCard {
            if compact {
                UFCardHead(FlexNowText.title, icon: "exam", wrap: true)
            } else {
                UFCardHead(FlexNowText.title, icon: "exam", wrap: true) { mainButton(wide: false) }
            }
            VStack(alignment: .leading, spacing: 10) {
                if case .failed(let m) = connection.state {
                    Text(m).ufFont(13.12, 600).foregroundStyle(UF.badText).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("flexnow.error")
                }
                if let line = FlexNowText.checked(state) {
                    Text(line).ufFont(12.48).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("flexnow.checked")
                }
                let regs = (state?.registered ?? []).filter(\.registered)
                if regs.isEmpty {
                    UFEmpty(icon: "exam", text: FlexNowText.emptyText(connection.state, checked: state?.registrationsCheckedAt != nil
                                                                      && state?.registrationsOK == true), small: true)
                        .accessibilityIdentifier("flexnow.empty")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(regs) { r in row(r) }
                    }
                }
                Text(FlexNowText.readOnly).ufFont(11.84).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                if compact { mainButton(wide: true) }
                if connection.isConnected { ExamRegistrationReminderToggle(title: FlexNowText.reminderTitle, note: FlexNowText.reminderNote) }
                UFFlexWrap(gap: 8) {
                    UFButton("FlexNow öffnen", icon: "arrow-right", kind: .ghost, size: .small) { openURL(FlexNowPage.entry) }
                        .fixedSize()
                        .accessibilityIdentifier("flexnow.open")
                    if connection.isConnected {
                        UFButton("Abmelden", icon: "log-out", kind: .ghost, size: .small) { confirmSignOut = true }
                            .fixedSize()
                            .accessibilityIdentifier("flexnow.signout")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("services.flexnow")
        .ufSheet(isPresented: $login) { FlexNowLoginView(connection: connection) }
        .confirmationDialog("Von FlexNow abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Abmelden", role: .destructive) { Task { await connection.signOut() } }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text(FlexNowConnection.signOutMessage) }
        .task {
            await reload()
            connection.runIfDue()
        }
        .onReceive(connection.$finishedRuns.dropFirst()) { _ in Task { await reload() } }
        .ufReload { await reload() }
    }

    private func reload() async {
        let s = await ExamRegistrationState.load(api)
        if s != state || s?.registered.map(\.text) != state?.registered.map(\.text) { state = s }
        if !StudIPSync.isUnderTest() { await ExamRegistrationReminderScheduler.shared.refresh() }
    }

    @ViewBuilder private func mainButton(wide: Bool) -> some View {
        let connected = connection.isConnected && connection.state != .needsLogin
        let title = connected ? (connection.isRunning ? "Liest …" : "Angemeldete Prüfungen lesen")
                              : (connection.isConnected ? "Erneut anmelden" : "FlexNow verbinden")
        let action: () -> Void = connected ? { Task { await connection.run(force: true) } } : { login = true }
        Group {
            if wide {
                UFWideButton(title, icon: connected ? "sync" : "arrow-right", kind: .primary, action: action)
            } else {
                UFButton(title, icon: connected ? "sync" : "arrow-right", kind: .primary, size: .small, action: action).fixedSize()
            }
        }
        .disabled(connection.isRunning)
        .accessibilityHint(connected ? "Liest die angemeldeten Prüfungen in FlexNow, nur lesend." : "Öffnet die Anmeldeseite von FlexNow.")
        .accessibilityIdentifier(connected ? "flexnow.fetch" : "flexnow.connect")
    }

    private func row(_ r: ExamRegistrationState.Registered) -> some View {
        let line = FlexNowText.withdrawLine(r, today: today)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            UFIcon("check", size: 14).foregroundStyle(UF.ok)
            VStack(alignment: .leading, spacing: 2) {
                UFFlexWrap(gap: 6, rowGap: 4) {
                    Text(r.text).ufFont(13.6, 650).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    if let f = r.form { UFBadge(f, tone: .neutral).fixedSize() }
                }
                if let m = r.module { Text("Modul \(m)").ufFont(12.48).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true) }
                if let line {
                    Text(line.text).ufFont(12.48, line.tone == .neutral ? 500 : 650).foregroundStyle(line.tone == .neutral ? UF.muted : line.tone.fg)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("flexnow.withdraw")
                }
                if let s = r.semester { Text("\(s) · angemeldet").ufFont(11.84).foregroundStyle(UF.muted) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.okSoft))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("flexnow.row")
    }
}
