import SwiftUI
import UniFlowCore
import WebKit

// Noten aus dem QIS der LUH auf dem iPad (F4): Anmeldung in der Webansicht des Containers (nur vorausgefuellt),
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
/// und `onSignedIn`. Ohne eigene QIS-Zugangsdaten fuellt die App die LUH-ID aus Stud.IP vor (`prefillFallback`);
/// "Anmelden" tippt der Mensch. `bottom` steht unter dem Schalter "Auf diesem iPad merken" (erster Start:
/// "Später anmelden"). Nur Debug mit -UFLoginStub: lokale Nachbildung statt der QIS-Seite (DebugUniStub).
struct QISLoginPane<Bottom: View>: View {
    @ObservedObject var connection: QISConnection
    let onSignedIn: () -> Void
    @ViewBuilder let bottom: Bottom
    @StateObject private var autofill: UniversityLoginAutofill
    @StateObject private var load = UFWebLoadState()
    @State private var done = false

    init(connection: QISConnection, onSignedIn: @escaping () -> Void, @ViewBuilder bottom: () -> Bottom) {
        self.connection = connection
        self.onSignedIn = onSignedIn
        self.bottom = bottom()
        _autofill = StateObject(wrappedValue: UniversityLoginAutofill(university: .luh, serviceKey: "qis", store: connection.credentials)!)
    }

    var body: some View {
        StudIPWebView(url: DebugUniStub.loginPage("qis", real: QISClient.startURL), dataStore: connection.websiteDataStore,
                      autofill: autofill, load: load) { webView in pageLoaded(webView) }
            .ufWebLoadFailure(load)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    UniversityRememberBar(autofill: autofill)
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
            Text("Die Noten liest UniFlow mit deiner QIS-Anmeldung aus dem Notenspiegel (Prüfungsverwaltung → Notenspiegel; nur die Leistungstabelle, keine persönlichen Daten) und speichert sie nur auf diesem iPad. Prüfungsanmeldungen und Bescheinigungen bleiben im QIS selbst.")
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
            Text("Stud.IP (Kurse, Dateien, Stundenplan, Aufzeichnungen) und QIS (Notenspiegel) der Leibniz Universität Hannover. Du meldest dich auf den Seiten der Universität mit deiner LUH-ID an und tippst selbst auf „Anmelden“; Dateien und Noten bleiben nur auf diesem iPad.")
                .ufFont(13.12).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9.6) {
                    Text("Stud.IP (Dateien, Stundenplan)").ufFont(13.12).foregroundStyle(UF.text)
                    Spacer(minLength: 0)
                    UFBadge(Self.studipText(studip.phase), tone: Self.studipTone(studip.phase))
                    UFButton(studip.phase == .signedOut ? "Verbinden" : "Öffnen", icon: "arrow-right",
                             kind: studip.phase == .signedOut || studip.phase == .needsLogin ? .primary : .normal, size: .small) { studipSheet = true }
                        .accessibilityIdentifier("luh.settings.studip")
                }
                .padding(.vertical, 5.6)
                .ufBorderBottom()
                if let qis { QISRow(connection: qis) }
            }
            .padding(.top, 8)
        }
        .sheet(isPresented: $studipSheet) { NavigationStack { StudIPView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { studipSheet = false } } } } }
    }

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
            HStack(spacing: 9.6) {
                Text("QIS (Noten)").ufFont(13.12).foregroundStyle(UF.text)
                Spacer(minLength: 0)
                UFBadge(QISConnection.statusText(connection.state), tone: Self.tone(connection.state))
                if connection.needsAttention {
                    UFButton(connection.state == .needsLogin ? "Erneut anmelden" : "Verbinden", icon: "arrow-right", kind: .primary, size: .small) { login = true }
                        .accessibilityIdentifier("luh.settings.qis")
                } else {
                    UFButton("Noten abrufen", icon: "sync", size: .small) { Task { await connection.run(force: true) } }
                        .disabled(connection.isRunning)
                    UFButton("Abmelden", icon: "log-out", kind: .danger, size: .small) { confirmSignOut = true }
                        .disabled(connection.isRunning)
                }
            }
            .padding(.vertical, 5.6)
            .ufBorderBottom()
            .sheet(isPresented: $login) { QISLoginView(connection: connection) }
            .confirmationDialog("Vom QIS abmelden?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) { Task { await connection.signOut() } }
            } message: {
                Text("Die QIS-Anmeldung in der Webansicht und die auf diesem iPad gemerkten QIS-Zugangsdaten werden gelöscht. Die geladenen Noten bleiben; Stud.IP bleibt angemeldet.")
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
