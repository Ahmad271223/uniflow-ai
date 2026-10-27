import SwiftUI
import UniFlowCore
import WebKit

// Oberflaeche der Universitaet Hildesheim (docs/AUFTRAG-HILDESHEIM-IPAD.md, duenne Schicht Punkt 4): statt
// "Stud.IP verbinden" die Karten "Learnweb verbinden" und "LSF verbinden", danach die Statusleiste mit dem Stand je
// Quelle und den Meldungen des letzten Abgleichs; Anmeldung in der Webansicht des Containers (HildesheimLogin);
// Karte "Learnweb & LSF" in den Einstellungen und unter Uni & Noten.

private struct HildesheimConnectionKey: EnvironmentKey {
    static let defaultValue: HildesheimConnection? = nil
}

extension EnvironmentValues {
    /// Verbindung der Uni Hildesheim des offenen Containers (`ContainerManager.hildesheim`); nil an der LUH, ohne
    /// Container und in Ansichten, die sie nicht gesetzt bekommen (dann zeigen die Hildesheimer Teile nichts)
    var hildesheim: HildesheimConnection? {
        get { self[HildesheimConnectionKey.self] }
        set { self[HildesheimConnectionKey.self] = newValue }
    }
}

/// Oberhalb der Seiten (ConnectStudIPCard fuer Hochschulen mit eigenen Quellen): Karten fuer nicht verbundene oder
/// abgelaufene Quellen, darunter die Statusleiste, sobald eine Quelle verbunden ist
struct HildesheimSourcesBar: View {
    @Environment(\.hildesheim) private var hildesheim

    var body: some View {
        if let hildesheim { Panel(connection: hildesheim) }
    }

    private struct Panel: View {
        @ObservedObject var connection: HildesheimConnection
        @State private var login: HildesheimConnection.Source?

        var body: some View {
            let open = HildesheimConnection.Source.allCases.filter { connection.needsAttention($0) }
            VStack(alignment: .leading, spacing: 12.8) {
                if !open.isEmpty {
                    UFGridLayout(spacing: 16, minWidth: 300) {
                        ForEach(open) { s in HildesheimConnectCard(source: s, state: connection.state(s)) { login = s } }
                    }
                }
                if connection.anyConnected { HildesheimStatusLine(connection: connection) }
            }
            .sheet(item: $login) { s in HildesheimLoginView(target: s, connection: connection) }
        }
    }
}

/// Karte "Learnweb verbinden" / "LSF verbinden" bzw. "… Anmeldung abgelaufen"
struct HildesheimConnectCard: View {
    let source: HildesheimConnection.Source
    let state: HildesheimConnection.State
    let connect: () -> Void

    var body: some View {
        let expired = state == .needsLogin
        UFCard {
            UFCardHead(Self.title(source, expired: expired), icon: source == .learnweb ? "book" : "clock")
            Text(Self.text(source, expired: expired))
                .ufFont(14.5).foregroundStyle(UF.text2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Dein Passwort gibst du nur auf der Seite der Universität ein.")
                .ufFont(13.12).foregroundStyle(UF.muted)
                .padding(.top, 4)
            UFButton(expired ? "Erneut anmelden" : "\(source.rawValue) verbinden", icon: "arrow-right", kind: .primary) { connect() }
                .padding(.top, 12.8)
                .accessibilityIdentifier("hildesheim.connect.\(source.rawValue.lowercased())")
        }
    }

    static func title(_ s: HildesheimConnection.Source, expired: Bool) -> String {
        expired ? "\(s.rawValue)-Anmeldung abgelaufen" : "\(s.rawValue) verbinden"
    }

    static func text(_ s: HildesheimConnection.Source, expired: Bool) -> String {
        switch (s, expired) {
        case (.learnweb, false):
            return "Melde dich mit deinem UNI-Account an, damit UniFlow deine Learnweb-Kurse und -Dateien auf dieses iPad holt."
        case (.learnweb, true):
            return "Melde dich erneut beim Learnweb an, damit UniFlow deine Kurse und Dateien weiter abgleicht."
        case (.lsf, false):
            return "Melde dich im LSF an, damit UniFlow deinen Stundenplan und deinen Notenspiegel auf dieses iPad holt."
        case (.lsf, true):
            return "Melde dich erneut im LSF an, damit Stundenplan und Notenspiegel aktuell bleiben."
        }
    }
}

/// Statusleiste: Stand je verbundener Quelle ("Learnweb: 16:30 ok", "LSF: Anmeldung nötig"), Meldungen des letzten
/// Abgleichs, "Jetzt abgleichen" bzw. "Erneut versuchen"
struct HildesheimStatusLine: View {
    @ObservedObject var connection: HildesheimConnection

    var body: some View {
        let sources = HildesheimConnection.Source.allCases.filter { connection.isConnected($0) }
        let failed = sources.contains { if case .failed = connection.state($0) { return true }; return false }
        UFCard(flat: true) {
            HStack(alignment: .top, spacing: 9.6) {
                if connection.isRunning {
                    ProgressView().tint(UF.accent)
                } else {
                    UFIcon(failed ? "alert" : "check", size: 18).foregroundStyle(failed ? UF.warn : UF.ok)
                }
                VStack(alignment: .leading, spacing: 4.8) {
                    UFFlexWrap(gap: 6.4) {
                        ForEach(sources) { s in
                            UFBadge(HildesheimConnection.statusText(s, connection.state(s)), tone: Self.tone(connection.state(s)))
                        }
                    }
                    if !connection.messages.isEmpty {
                        Text(connection.messages.joined(separator: " · "))
                            .ufFont(13.12).foregroundStyle(UF.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                UFButton(failed ? "Erneut versuchen" : "Jetzt abgleichen", icon: failed ? "refresh" : "sync", size: .small) {
                    Task { await connection.run() }
                }
                .disabled(connection.isRunning)
            }
        }
        .accessibilityIdentifier("hildesheim.status")
    }

    static func tone(_ s: HildesheimConnection.State) -> UFTone {
        switch s {
        case .ok: return .ok
        case .needsLogin: return .warn
        case .failed: return .bad
        case .running: return .info
        case .connected, .notConnected: return .neutral
        }
    }
}

/// Karte "Learnweb & LSF" (Einstellungen, Uni & Noten): Stand je Quelle, verbinden bzw. erneut anmelden, abgleichen,
/// abmelden
struct HildesheimSourcesCard: View {
    @Environment(\.hildesheim) private var hildesheim

    var body: some View {
        if let hildesheim { Panel(connection: hildesheim) }
    }

    private struct Panel: View {
        @ObservedObject var connection: HildesheimConnection
        @State private var login: HildesheimConnection.Source?
        @State private var confirmSignOut = false

        var body: some View {
            UFCard {
                UFCardHead("Learnweb & LSF", icon: "graduation") {
                    // "verbunden" nur, wenn beide Quellen verbunden sind; sonst nennt der Kopf die fehlende
                    if HildesheimConnection.Source.allCases.allSatisfy(connection.isConnected) {
                        UFBadge("verbunden", tone: .ok)
                    } else if let missing = HildesheimConnection.Source.allCases.first(where: { !connection.isConnected($0) }),
                              connection.anyConnected {
                        UFBadge("\(missing == .lsf ? "LSF" : "Learnweb") fehlt", tone: .warn)
                    } else {
                        UFBadge("nicht verbunden", tone: .warn)
                    }
                }
                Text("Learnweb (Kurse, Dateien) und LSF (Stundenplan, Notenspiegel) der Universität Hildesheim. Du meldest dich auf den Seiten der Universität mit deinem UNI-Account an und tippst selbst auf „Anmelden“; Dateien und Noten bleiben nur auf diesem iPad.")
                    .ufFont(13.12).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(HildesheimConnection.Source.allCases) { s in
                        let st = connection.state(s)
                        HStack(spacing: 9.6) {
                            Text(s == .learnweb ? "Learnweb (Dateien)" : "LSF (Stundenplan, Noten)").ufFont(13.12).foregroundStyle(UF.text)
                            Spacer(minLength: 0)
                            UFBadge(HildesheimConnection.statusText(s, st), tone: HildesheimStatusLine.tone(st))
                            if connection.needsAttention(s) {
                                UFButton(st == .needsLogin ? "Erneut anmelden" : "Verbinden", icon: "arrow-right", kind: .primary, size: .small) {
                                    login = s
                                }
                                .accessibilityIdentifier("hildesheim.settings.connect.\(s.rawValue.lowercased())")
                            }
                        }
                        .padding(.vertical, 5.6)
                        .ufBorderBottom()
                    }
                }
                .padding(.top, 8)
                if connection.anyConnected {
                    UFFlexWrap(gap: 9.6) {
                        UFButton("Jetzt abgleichen", icon: "sync", size: .small) { Task { await connection.run() } }
                            .disabled(connection.isRunning)
                        UFButton("Abmelden", icon: "log-out", kind: .danger, size: .small) { confirmSignOut = true }
                            .disabled(connection.isRunning)
                    }
                    .padding(.top, 9.6)
                }
            }
            .sheet(item: $login) { s in HildesheimLoginView(target: s, connection: connection) }
            .confirmationDialog("Von Learnweb und LSF abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) { Task { await connection.signOut() } }
            } message: {
                Text("Der Learnweb-Schlüssel, die Anmeldung in der Webansicht und die auf diesem iPad gemerkten Zugangsdaten der Universität Hildesheim werden gelöscht. Dateien, Stundenplan und Noten bleiben.")
            }
        }
    }
}

/// Anmeldung bei Learnweb oder LSF auf der echten Seite der Universitaet (CAS) als Blatt: die Anmeldeansicht
/// `HildesheimLoginPane` mit Titel und "Abbrechen". Beim ersten Start steht dieselbe Anmeldeansicht im FirstLoginFlow.
struct HildesheimLoginView: View {
    @StateObject private var login: HildesheimLogin
    @Environment(\.dismiss) private var dismiss

    init(target: HildesheimConnection.Source, connection: HildesheimConnection) {
        _login = StateObject(wrappedValue: HildesheimLogin(target: target, connection: connection))
    }

    var body: some View {
        NavigationStack {
            HildesheimLoginPane(login: login) { EmptyView() }
                .navigationTitle("\(login.target.rawValue)-Anmeldung")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        .onChange(of: login.stage) { _, stage in if stage == .done { dismiss() } }
    }
}

/// Anmeldung bei Learnweb oder LSF in der Webansicht des Containers (CAS der Uni). Mit dem Schalter "Auf diesem iPad
/// merken" fuellt die App Benutzername und Passwort beim naechsten Mal vor; abgeschickt wird nie automatisch.
/// `bottom` steht unter dem Schalter (erster Start: "Später anmelden"). Nur Debug mit -UFLoginStub: lokale
/// Nachbildung statt der Seite der Universitaet; "<learnweb|lsf>-angemeldet.html" gilt als angemeldet (DebugUniStub).
struct HildesheimLoginPane<Bottom: View>: View {
    @ObservedObject var login: HildesheimLogin
    @ViewBuilder let bottom: Bottom
    @StateObject private var autofill: UniversityLoginAutofill
    /// Ladefehler der Seite (kein Netz, LSF/CAS nicht erreichbar): Karte mit "Erneut versuchen"
    @StateObject private var load = UFWebLoadState()

    init(login: HildesheimLogin, @ViewBuilder bottom: () -> Bottom) {
        self.login = login
        self.bottom = bottom()
        _autofill = StateObject(wrappedValue: UniversityLoginAutofill(university: .hildesheim, serviceKey: "cas", store: login.connection.credentials)!)
    }

    private var service: String { login.target == .learnweb ? "learnweb" : "lsf" }

    var body: some View {
        content.task { if login.stage == .preparing { await login.prepare() } }
    }

    @ViewBuilder private var content: some View {
        switch login.stage {
        case .preparing, .done:
            ProgressView().tint(UF.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(UF.bg)
        case .page(let url):
            StudIPWebView(url: DebugUniStub.loginPage(service, real: url), dataStore: login.connection.websiteDataStore, autofill: autofill,
                          interceptNavigation: { login.intercept($0) }, load: load) { webView in
                if DebugUniStub.isSignedIn(webView.url, service: service) {
                    login.stubSignedIn()
                    return
                }
                webView.evaluateJavaScript("document.documentElement.outerHTML", in: nil, in: .defaultClient) { result in
                    login.pageLoaded(url: webView.url, html: (try? result.get()) as? String ?? "")
                }
            }
            .ufWebLoadFailure(load)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let error = login.casError {
                        HStack(alignment: .top, spacing: 6) {
                            UFIcon("alert", size: 14).padding(.top, 2)
                            Text(error).fixedSize(horizontal: false, vertical: true)
                        }
                        .ufFont(13.12).foregroundStyle(UF.bad)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(UF.badSoft)
                    }
                    UniversityRememberBar(autofill: autofill)
                    bottom
                }
            }
        case .failed(let message):
            VStack {
                UFCard {
                    UFCardHead("Anmeldung nicht möglich", icon: "alert")
                    Text(message).ufFont(14.5).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    UFButton("Erneut versuchen", icon: "refresh", kind: .primary) { Task { await login.prepare() } }
                        .padding(.top, 12.8)
                }
                .frame(maxWidth: 560)
                Spacer()
            }
            .padding(25.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UF.bg)
        }
    }
}
