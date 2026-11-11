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
    /// einzeilige Leiste statt der Karten (alle Seiten ausser der Uebersicht, `ConnectStudIPCard.compact`)
    var compact = false
    @Environment(\.hildesheim) private var hildesheim

    var body: some View {
        if let hildesheim { Panel(connection: hildesheim, compact: compact) }
    }

    /// Stand der Leiste: "Learnweb und LSF nicht verbunden", "LSF-Anmeldung abgelaufen" (reine Funktion, Tests)
    static func compactTitle(_ open: [(HildesheimConnection.Source, HildesheimConnection.State)]) -> String {
        let expired = open.filter { $0.1 == .needsLogin }.map(\.0.rawValue)
        let missing = open.filter { $0.1 != .needsLogin }.map(\.0.rawValue)
        var parts: [String] = []
        if !missing.isEmpty { parts.append("\(missing.joined(separator: " und ")) nicht verbunden") }
        if !expired.isEmpty { parts.append("\(expired.joined(separator: " und "))-Anmeldung abgelaufen") }
        return parts.joined(separator: " · ")
    }

    private struct Panel: View {
        @ObservedObject var connection: HildesheimConnection
        let compact: Bool
        @State private var login: HildesheimConnection.Source?

        var body: some View {
            let open = HildesheimConnection.Source.allCases.filter { connection.needsAttention($0) }
            VStack(alignment: .leading, spacing: 12.8) {
                if !open.isEmpty && compact {
                    UFConnectBar(title: HildesheimSourcesBar.compactTitle(open.map { ($0, connection.state($0)) }),
                                 text: "Kurse, Dateien und Stundenplan kommen nach der Anmeldung.") {
                        ForEach(open) { s in
                            UFButton(connection.state(s) == .needsLogin ? "\(s.rawValue) erneut anmelden" : "\(s.rawValue) verbinden",
                                     icon: "arrow-right", kind: .primary, size: .small) { login = s }
                                .fixedSize()
                                .accessibilityIdentifier("connectBar.\(s.rawValue.lowercased())")
                        }
                    }
                } else if !open.isEmpty {
                    UFGridLayout(spacing: 16, minWidth: 300) {
                        ForEach(open) { s in HildesheimConnectCard(source: s, state: connection.state(s)) { login = s } }
                    }
                }
                if connection.anyConnected && HildesheimStatusLine.shows(connection) { HildesheimStatusLine(connection: connection) }
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
            return UFDevice.adapt("Melde dich mit deinem UNI-Account an, damit StudiNow deine Learnweb-Kurse und -Dateien auf dieses iPad holt.")
        case (.learnweb, true):
            return "Melde dich erneut beim Learnweb an, damit StudiNow deine Kurse und Dateien weiter abgleicht."
        case (.lsf, false):
            return UFDevice.adapt("Melde dich im LSF an, damit StudiNow deinen Stundenplan und deinen Notenspiegel auf dieses iPad holt.")
        case (.lsf, true):
            return "Melde dich erneut im LSF an, damit Stundenplan und Notenspiegel aktuell bleiben."
        }
    }
}

/// Statusleiste: Stand je verbundener Quelle ("Learnweb: 16:30 ok", "LSF: Anmeldung nötig") und "Jetzt abgleichen"
/// bzw. "Erneut versuchen" in einer Zeile; die Meldungen des letzten Abgleichs ("0 neue/geänderte Dateien …") stehen
/// eingeklappt dahinter und klappen auf Tippen auf (Wunsch des Inhabers 03.11.2026: keine grosse Karte ueber dem Kalender)
struct HildesheimStatusLine: View {
    @ObservedObject var connection: HildesheimConnection
    @State private var open = false

    var body: some View {
        let sources = HildesheimConnection.Source.allCases.filter { connection.isConnected($0) }
        let failed = sources.contains { if case .failed = connection.state($0) { return true }; return false }
        let summary = connection.messages.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if connection.isRunning {
                    ProgressView().tint(UF.accent).controlSize(.small)
                } else {
                    UFIcon(failed ? "alert" : "check", size: 16).foregroundStyle(failed ? UF.warn : UF.ok)
                }
                ForEach(sources) { s in
                    UFBadge(HildesheimConnection.statusText(s, connection.state(s)), tone: Self.tone(connection.state(s)))
                        .fixedSize()
                }
                Button { if !summary.isEmpty { UFMotion.toggle { open.toggle() } } } label: {
                    HStack(spacing: 4) {
                        Text(summary).ufFont(13.12).foregroundStyle(UF.muted).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !summary.isEmpty {
                            UFIcon("chevron-down", size: 14).foregroundStyle(UF.muted).rotationEffect(.degrees(open ? 180 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(summary.isEmpty)
                .accessibilityLabel(summary.isEmpty ? "Abgleich" : "Meldungen des Abgleichs")
                .accessibilityHint(open ? "Zuklappen" : "Aufklappen")
                UFButton(failed ? "Erneut versuchen" : "Jetzt abgleichen", icon: failed ? "refresh" : "sync", size: .small) {
                    Task { await connection.run() }
                }
                .fixedSize()
                .disabled(connection.isRunning)
            }
            if open && !summary.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(connection.messages.indices, id: \.self) { i in
                        Text(connection.messages[i]).ufFont(13.12).foregroundStyle(UF.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 24)
                .ufReveal()                                                 // Aufklappen wie disclosure (UFMotion)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface2))
        .accessibilityIdentifier("hildesheim.status")
    }

    /// Nur sichtbar, wenn es etwas zu sagen gibt: Abgleich laeuft, eine Quelle braucht Anmeldung oder scheiterte,
    /// oder der letzte Abgleich brachte Neues (03.11.2026: "warum steht da oben immer abgehakt"); sonst reicht "Sync" oben
    static func shows(_ c: HildesheimConnection) -> Bool {
        if c.isRunning { return true }
        let sources = HildesheimConnection.Source.allCases.filter { c.isConnected($0) }
        let problem = sources.contains {
            switch c.state($0) { case .ok, .connected, .notConnected: return false; default: return true }
        }
        return problem || hasNews(c.messages)
    }

    /// Meldungen mit Aenderungen ("3 neue/geänderte Dateien", "Fristen: 4 (1 neu, 0 entfernt)") oder Fehlern;
    /// ruhig sind nur die bekannten Meldungen ohne Neues (Muster aus `HildesheimSync`)
    static let quiet = [
        #"^0 neue/geänderte Dateien aus \d+ Learnweb-Kursen(, \d+ Kurse? aus früheren Semestern ohne Dateien.*)?$"#,
        #"^Fristen: \d+ \(0 neu, 0 entfernt\)$"#,
        #"^Ankündigungen: 0 neu \(0 mit Termin\), 0 entfernt$"#,
        #"^Stundenplan: 0 neu, \d+ unverändert, 0 entfernt$"#,
        #"^Notenspiegel: \d+ Leistungen$"#,
    ]

    static func hasNews(_ messages: [String]) -> Bool {
        messages.contains { m in !quiet.contains { m.range(of: $0, options: .regularExpression) != nil } }
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

    static let text = UFDevice.adapt("Learnweb (Kurse, Dateien) und LSF (Stundenplan, Notenspiegel) der Universität Hildesheim. Du meldest dich auf den Seiten der Universität mit deinem UNI-Account an und tippst selbst auf „Anmelden“; dein Passwort merkt StudiNow nur, wenn du es zulässt, und nur auf diesem iPad (dann meldet StudiNow dich selbst wieder an). Dateien und Noten bleiben nur auf diesem iPad.")
    static let signOutMessage = "Der Learnweb-Schlüssel und die Anmeldung in der Webansicht der Universität Hildesheim werden gelöscht. Dateien, Stundenplan und Noten bleiben. Ein Passwort, das iOS gesichert hat, bleibt unter „Passwörter“."

    var body: some View {
        if let hildesheim { Panel(connection: hildesheim) }
    }

    private struct Panel: View {
        @ObservedObject var connection: HildesheimConnection
        @State private var login: HildesheimConnection.Source?
        @State private var confirmSignOut = false
        @EnvironmentObject private var toast: UFToastCenter

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
                Text(HildesheimSourcesCard.text)
                    .ufFont(13.12).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(HildesheimConnection.Source.allCases) { s in
                        let st = connection.state(s)
                        // Knopf rutscht in schmalen Spalten unter den Namen (`UFSourceRow`, Breiten-Audit 04.11.2026)
                        UFSourceRow(s == .learnweb ? "Learnweb" : "LSF", s == .learnweb ? "Dateien" : "Stundenplan, Noten") {
                            UFBadge(HildesheimConnection.statusText(s, st), tone: HildesheimStatusLine.tone(st)).fixedSize()
                        } actions: {
                            if connection.needsAttention(s) {
                                UFButton(st == .needsLogin ? "Erneut anmelden" : "Verbinden", icon: "arrow-right", kind: .primary, size: .small) {
                                    login = s
                                }
                                .fixedSize()
                                .accessibilityIdentifier("hildesheim.settings.connect.\(s.rawValue.lowercased())")
                            }
                        }
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
                Button("Abmelden", role: .destructive) {
                    Task {
                        if let problem = await connection.signOut() { toast.show(problem, seconds: 6) }
                    }
                }
            } message: {
                Text(HildesheimSourcesCard.signOutMessage)
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

/// Anmeldung bei Learnweb oder LSF in der Webansicht des Containers (CAS der Uni). Benutzername und Passwort tippt der
/// Mensch selbst; die App fuellt nichts vor und speichert nichts davon, ein gespeichertes Passwort setzt hoechstens iOS
/// ein. `bottom` steht unter dem Hinweis `UniversityLoginHint` (erster Start: "Später anmelden"). Nur Debug mit
/// -UFLoginStub: lokale Nachbildung statt der Seite der Universitaet; "<learnweb|lsf>-angemeldet.html" gilt als
/// angemeldet (DebugUniStub).
struct HildesheimLoginPane<Bottom: View>: View {
    @ObservedObject var login: HildesheimLogin
    @ViewBuilder let bottom: Bottom
    /// Ladefehler der Seite (kein Netz, LSF/CAS nicht erreichbar): Karte mit "Erneut versuchen"
    @StateObject private var load = UFWebLoadState()

    init(login: HildesheimLogin, @ViewBuilder bottom: () -> Bottom) {
        self.login = login
        self.bottom = bottom()
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
            StudIPWebView(url: DebugUniStub.loginPage(service, real: url), dataStore: login.connection.websiteDataStore,
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
                    UniversityLoginHint()
                    UniRememberPasswordToggle(dataStore: login.connection.websiteDataStore)
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
