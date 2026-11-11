import SwiftUI
import UniFlowCore
import WebKit

// Noten aus dem QIS der LUH auf dem iPad (F4): Anmeldung in der Webansicht des Containers (Passwort nur von iOS gemerkt),
// Karte "Notenspiegel (QIS)" unter Uni & Noten mit Notenschnitt und Liste wie beim LSF der Uni Hildesheim, Karte
// "Stud.IP & QIS" in den Einstellungen und unter Uni & Noten. Leer ist kein Fehler ("Im QIS sind noch keine Noten
// veröffentlicht."); eine abgelaufene Sitzung bietet die Anmeldung an.

private struct QISConnectionKey: EnvironmentKey {
    static let defaultValue: QISConnection? = nil
}

extension EnvironmentValues {
    /// QIS-Verbindung des offenen LUH-Containers (`ContainerManager.qis`); nil an der Uni Hildesheim und ohne Container
    var qis: QISConnection? {
        get { self[QISConnectionKey.self] }
        set { self[QISConnectionKey.self] = newValue }
    }
}

/// Anmeldung beim QIS als Blatt (Uni & Noten, Einstellungen): die Anmeldeansicht `QISLoginPane` mit Titel und "Abbrechen"
struct QISLoginView: View {
    @ObservedObject var connection: QISConnection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QISLoginPane(connection: connection, onSignedIn: { dismiss() }) { EmptyView() }
                .navigationTitle("QIS-Anmeldung")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
    }
}

/// Anmeldung auf der echten QIS-Seite in der Webansicht des Containers. Fertig, sobald eine Seite des QIS angemeldet
/// ist (`QISPage.isLoggedIn`: Abmelden-Link, kein Anmeldeformular); dann `QISConnection.signedIn()` (ruft gleich ab)
/// und `onSignedIn`. Benutzername und Passwort tippt der Mensch selbst und tippt selbst auf "Anmelden"; die App fuellt
/// nichts vor (auch nicht die LUH-ID aus Stud.IP) und speichert nichts davon, ein gespeichertes Passwort setzt
/// hoechstens iOS ein. `bottom` steht unter dem Hinweis `UniversityLoginHint` (erster Start: "Später anmelden"). Nur
/// Debug mit -UFLoginStub: lokale Nachbildung statt der QIS-Seite (DebugUniStub).
struct QISLoginPane<Bottom: View>: View {
    @ObservedObject var connection: QISConnection
    let onSignedIn: () -> Void
    @ViewBuilder let bottom: Bottom
    @StateObject private var load = UFWebLoadState()
    @State private var done = false

    init(connection: QISConnection, onSignedIn: @escaping () -> Void, @ViewBuilder bottom: () -> Bottom) {
        self.connection = connection
        self.onSignedIn = onSignedIn
        self.bottom = bottom()
    }

    var body: some View {
        // QIS hat ein eigenes Formular (kein WebSSO): kein Skript, auch nicht die Hilfe fuer den Benutzernamen
        StudIPWebView(url: DebugUniStub.loginPage("qis", real: QISClient.startURL), dataStore: connection.websiteDataStore,
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

    /// Angemeldete QIS-Seite (nur vom Rechner des QIS): Abmelden-Link vorhanden, kein Anmeldeformular
    static func isSignedIn(html: String, url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), QISConnection.qisDomains.contains(host) else { return false }
        let page = QISPage.parse(html: html, url: url)
        return page.isLoggedIn && !page.hasLoginForm
    }

    private func pageLoaded(_ webView: WKWebView) {
        guard !done else { return }
        if DebugUniStub.isSignedIn(webView.url, service: "qis") {
            finish()
            return
        }
        guard let url = webView.url, QISConnection.qisDomains.contains(url.host?.lowercased() ?? "") else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML", in: nil, in: .defaultClient) { result in
            let html = (try? result.get()) as? String ?? ""
            if Self.isSignedIn(html: html, url: url) { finish() }
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        connection.signedIn()
        onSignedIn()
    }
}

/// Notenspiegel aus dem QIS der LUH (Uni & Noten): nur die Leistungstabelle (Stammdaten liest und speichert UniFlow
/// nie), abgerufen hoechstens alle 20 Stunden von selbst, mit "Noten abrufen" sofort
struct QISGradesCard: View {
    @ObservedObject var connection: QISConnection
    let rows: [JSONValue]
    let last: JSONValue?
    let lastOK: Bool
    @State private var login = false

    var body: some View {
        UFCard {
            UFCardHead("Notenspiegel (QIS)", icon: "exam", wrap: true) {
                if connection.isConnected && connection.state != .needsLogin {
                    UFButton("Noten abrufen", icon: "sync", kind: .primary, size: .small) { Task { await connection.run(force: true) } }
                        .disabled(connection.isRunning)
                        .accessibilityIdentifier("qis.fetch")
                } else {
                    UFButton(connection.isConnected ? "Erneut anmelden" : "QIS verbinden", icon: "arrow-right", kind: .primary, size: .small) { login = true }
                        .accessibilityIdentifier("qis.connect")
                }
            }
            if let last, !lastOK {
                HStack(alignment: .top, spacing: 4) {
                    UFIcon("alert", size: 14).padding(.top, 2)
                    Text(last.s("message") ?? "").ufFont(14.5, 700).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(UF.text)
                .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.badSoft))
                .padding(.bottom, 9.6)
            }
            if rows.isEmpty {
                UFEmpty(icon: "exam", text: QISConnection.emptyText(connection.state, lastCount: connection.lastCount), small: true)
                    .accessibilityIdentifier("qis.empty")
            } else {
                GradesTable(rows: rows)
            }
            Text(UFDevice.adapt("Die Noten liest StudiNow mit deiner QIS-Anmeldung aus dem Notenspiegel (Prüfungsverwaltung → Notenspiegel; nur die Leistungstabelle, keine persönlichen Daten) und speichert sie nur auf diesem iPad. Prüfungsanmeldungen bleiben im QIS selbst; Bescheinigungen lädt die Seite „Bescheinigungen“ auf Tippen."))
                .ufFont(11.84).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12.8).padding(.bottom, 5.6)
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $login) { QISLoginView(connection: connection) }
    }
}

/// Karte "Stud.IP & QIS" (Einstellungen, Uni & Noten) der LUH: Stand je Quelle, verbinden bzw. erneut anmelden,
/// abgleichen, abmelden - das Gegenstueck zur Karte "Learnweb & LSF" der Uni Hildesheim
struct LUHSourcesCard: View {
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.qis) private var qis
    @State private var studipSheet = false

    var body: some View {
        UFCard {
            UFCardHead("Stud.IP & QIS", icon: "graduation") {
                studip.phase != .signedOut ? UFBadge("verbunden", tone: .ok) : UFBadge("nicht verbunden", tone: .warn)
            }
            Text(Self.text)
                .ufFont(13.12).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                // Abzeichen und Knopf behalten ihre Breite (in der halben Karte unter "Uni & Noten" wurden sie
                // zu "nicht verbu…" / "Verbin…" gekuerzt); reicht die Zeile nicht, rutscht der Knopf darunter
                UFSourceRow("Stud.IP", "Dateien, Stundenplan") {
                    UFBadge(Self.studipText(studip.phase), tone: Self.studipTone(studip.phase)).fixedSize()
                } actions: {
                    UFButton(studip.phase == .signedOut ? "Verbinden" : "Öffnen", icon: "arrow-right",
                             kind: studip.phase == .signedOut || studip.phase == .needsLogin ? .primary : .normal, size: .small) { studipSheet = true }
                        .fixedSize()
                        .accessibilityIdentifier("luh.settings.studip")
                }
                if let qis { QISRow(connection: qis) }
            }
            .padding(.top, 8)
        }
        .sheet(isPresented: $studipSheet) { NavigationStack { StudIPView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { studipSheet = false } } } } }
    }

    /// Quelle links in der Zeile: Name und darunter klein, was sie liefert (vorher "Stud.IP (Dateien, Stundenplan)" in
    /// einer Zeile, in der halben Karte unter "Uni & Noten" mitten im Wort umbrochen - Audit 03.11.2026)
    static func label(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).ufFont(13.12, 600).foregroundStyle(UF.text)
            Text(detail).ufFont(11.84).foregroundStyle(UF.muted)
        }
        .accessibilityElement(children: .combine)
    }

    static let text = UFDevice.adapt("Stud.IP (Kurse, Dateien, Stundenplan, Aufzeichnungen) und QIS (Notenspiegel) der Leibniz Universität Hannover. Du meldest dich auf den Seiten der Universität mit deiner LUH-ID an und tippst selbst auf „Anmelden“; dein Passwort merkt StudiNow nur, wenn du es zulässt, und nur auf diesem iPad (dann meldet StudiNow dich selbst wieder an). Dateien und Noten bleiben nur auf diesem iPad.")

    static func studipText(_ p: StudIPSync.Phase) -> String {
        switch p {
        case .signedOut: return "nicht verbunden"
        case .needsLogin: return "Anmeldung nötig"
        case .running: return "gleicht ab …"
        case .failed: return "Fehler"
        case .idle: return "verbunden"
        }
    }

    static func studipTone(_ p: StudIPSync.Phase) -> UFTone {
        switch p {
        case .signedOut: return .neutral
        case .needsLogin: return .warn
        case .running: return .info
        case .failed: return .bad
        case .idle: return .ok
        }
    }

    /// Zeile "QIS (Noten)" mit Stand, verbinden/erneut anmelden, Noten abrufen, abmelden
    private struct QISRow: View {
        @ObservedObject var connection: QISConnection
        @State private var login = false
        @State private var confirmSignOut = false

        var body: some View {
            UFSourceRow("QIS", "Noten") {
                UFBadge(QISConnection.statusText(connection.state), tone: Self.tone(connection.state)).fixedSize()
            } actions: {
                if connection.needsAttention {
                    UFButton(connection.state == .needsLogin ? "Erneut anmelden" : "Verbinden", icon: "arrow-right", kind: .primary, size: .small) { login = true }
                        .fixedSize()
                        .accessibilityIdentifier("luh.settings.qis")
                } else {
                    UFButton("Noten abrufen", icon: "sync", size: .small) { Task { await connection.run(force: true) } }
                        .fixedSize()
                        .disabled(connection.isRunning)
                    UFButton("Abmelden", icon: "log-out", kind: .danger, size: .small) { confirmSignOut = true }
                        .fixedSize()
                        .disabled(connection.isRunning)
                }
            }
            .sheet(isPresented: $login) { QISLoginView(connection: connection) }
            .confirmationDialog("Vom QIS abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) { Task { await connection.signOut() } }
            } message: {
                Text(QISConnection.signOutMessage)
            }
        }

        static func tone(_ s: QISConnection.State) -> UFTone {
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

/// Zeile einer Quelle in den Karten "Stud.IP & QIS" und "Learnweb & LSF": links Name und darunter klein, was sie
/// liefert, rechts Stand und Knoepfe. Passt das nicht in eine Zeile (Breiten-Audit 04.11.2026: im iPad (A16) quer ist
/// die rechte Spalte unter "Uni & Noten" nur rund 280 pt breit, "Noten abrufen" und "Abmelden" ragten ueber den
/// Bildschirm), steht der Stand neben dem Namen und die Knoepfe stehen in einer umbrechenden Zeile darunter; ganz
/// schmal steht alles untereinander. Abzeichen und Knoepfe werden nie gekuerzt.
struct UFSourceRow<Status: View, Actions: View>: View {
    let name: String
    let detail: String
    @ViewBuilder let status: Status
    @ViewBuilder let actions: Actions

    init(_ name: String, _ detail: String, @ViewBuilder status: () -> Status, @ViewBuilder actions: () -> Actions) {
        self.name = name
        self.detail = detail
        self.status = status()
        self.actions = actions()
    }

    private var label: some View { LUHSourcesCard.label(name, detail).fixedSize() }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9.6) {
                label
                Spacer(minLength: 0)
                status
                actions
            }
            VStack(alignment: .leading, spacing: 6.4) {
                HStack(spacing: 9.6) { label; Spacer(minLength: 0); status }
                UFFlexWrap(gap: 8) { actions }
            }
            VStack(alignment: .leading, spacing: 6.4) {
                LUHSourcesCard.label(name, detail)
                status
                UFFlexWrap(gap: 8) { actions }
            }
        }
        .padding(.vertical, 5.6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ufBorderBottom()
    }
}
