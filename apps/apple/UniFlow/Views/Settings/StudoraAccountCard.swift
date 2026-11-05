import AuthenticationServices
import SwiftUI
import UniFlowCore

/// Einstellungen → Zugang & Darstellung → "StudiNow-Konto": dasselbe Konto wie auf Windows und im Web (Vertrag G1).
/// Sichtbar erst mit Dienst-Adresse (`StudoraAccountLink.available`). Das Passwort geht nur an den Dienst, gemerkt wird
/// es nur von iOS (Passwort-AutoFill), nie von StudiNow.
struct StudoraAccountCard: View {
    @ObservedObject var link: StudoraAccountLink
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.colorScheme) private var scheme
    /// iPhone: Anmelden und "Mit Apple anmelden" in voller Breite, Abgleich unter dem Stand
    @Environment(\.ufCompact) private var compact
    @State private var email = ""
    @State private var password = ""
    @State private var deletePassword = ""
    @State private var exportURL: URL?

    var body: some View {
        UFCard {
            UFCardHead("StudiNow-Konto", icon: "user") {
                UFBadge(link.user == nil ? "nicht angemeldet" : "angemeldet", tone: link.user == nil ? .neutral : .ok)
            }
            Text("Dasselbe Konto wie auf Windows und im Web. Module, Stundenplan, Lernplan, Karteikarten und Einstellungen gleichen sich zwischen deinen Geräten ab; Notizen ab Plus. Hochschuldateien lädt jedes Gerät selbst. Mit StudiNow Pro AI antwortet über das Konto die StudiNow-KI.")
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            if let line = Self.aiLine(link.aiAccess, credits: link.credits, trial: link.planStatus?.trialActive ?? false) {
                Text(line).ufFont(13.12, 600).foregroundStyle(link.aiAccess == .ready ? UF.text2 : UF.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.ai")
            }
            if let u = link.user { signedIn(u) } else { signIn }
            if let m = link.message {
                Text(m).ufFont(13.12).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.message")
                // Handlung zum Fehlercode (ServiceErrorText.action); der Link steht unten schon, wenn unbestaetigt
                if link.messageAction == .verifyEmail, link.user?.emailVerified != false { resendButton }
            }
            if let n = link.notice {
                Text(n).ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.notice")
            }
        }
        .task { await link.refresh() }
        .sheet(item: Binding(get: { exportURL.map(ExportItem.init) }, set: { exportURL = $0?.url })) { item in ActivityView(items: [item.url]) }
    }

    /// Zeile zur StudiNow-KI: bereit mit Credits-Stand, bzw. was fehlt (Anmeldung); nil ohne Pro AI und ohne Probe
    static func aiLine(_ access: StudiNowAIAccess, credits: StudoraCredits?, trial: Bool) -> String? {
        switch access {
        case .ready:
            return "StudiNow-KI bereit" + (AICost.balanceLine(credits, trial: trial, labelled: false).map { " · \($0)" } ?? "")
        case .signInRequired:
            return "Du hast StudiNow Pro AI: melde dich hier an, dann antwortet die StudiNow-KI."
        case .planRequired, .unavailable:
            return nil
        }
    }

    /// Stand des Geraete-Abgleichs in einem Satz
    static func syncText(_ r: DeviceSyncResult?) -> String {
        guard let r else { return "Noch nicht abgeglichen" }
        guard r.ok else { return r.error ?? "Abgleich fehlgeschlagen" }
        var s = "Abgeglichen: \(r.applied) geholt, \(r.pushed) gesendet"
        if r.pending > 0 { s += ", \(r.pending) warten auf ihre Datei" }
        if r.planRequired { s += ". Notizen bleiben im Tarif Free auf diesem Gerät" }
        if let e = r.errors.first { s += ". \(e)" }
        return s
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 9.6) {
            // Felder im Stil der App mit Beschriftung darueber (vorher Systemrahmen, Platzhalter als einzige Beschriftung)
            UFField("E-Mail") {
                UFTextField("name@beispiel.de", text: $email)
                    .textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            UFField("Passwort") {
                UFTextField("Passwort", text: $password, secure: true).textContentType(.password)
            }
            Group {
                if compact {
                    UFWideButton(link.busy ? "Melde an …" : "Anmelden", icon: "log-out", kind: .primary) { login() }
                } else {
                    UFFlexWrap(gap: 9.6) {
                        UFButton(link.busy ? "Melde an …" : "Anmelden", icon: "log-out", kind: .primary, size: .small) { login() }
                    }
                }
            }
            .disabled(link.busy || email.isEmpty || password.isEmpty)
            .accessibilityIdentifier("account.login")
            // "Mit Apple anmelden": Token-Tausch beim Dienst; ein neues Konto bekommt die Hochschule dieses iPads
            SignInWithAppleButton(.signIn, onRequest: { link.prepareAppleRequest($0) }, onCompletion: { result in
                Task { await link.handleAppleSignIn(result) }
            })
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(maxWidth: compact ? .infinity : 320, minHeight: 44, maxHeight: 44)
            .disabled(link.busy)
            .accessibilityIdentifier("account.apple")
            Text("Noch kein Konto? „Mit Apple anmelden“ legt es an (7 Tage Probe mit 25 Credits für die StudiNow-KI). Registrieren mit E-Mail, E-Mail bestätigen und Passwort zurücksetzen auf der Webseite von StudiNow.")
                .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func login() {
        Task {
            await link.login(email: email, password: password)
            password = ""                                            // nie im Speicher behalten
        }
    }

    @ViewBuilder private func signedIn(_ u: StudoraAccount.User) -> some View {
        VStack(alignment: .leading, spacing: 9.6) {
            SettingsValue(label: "Angemeldet als", value: u.email)
            if !u.emailVerified {
                Text("E-Mail noch nicht bestätigt: bitte den Link in der Willkommensmail öffnen. Ohne Bestätigung gehen StudiNow-KI und Schreiben in der Community nicht.")
                    .ufFont(12.8).foregroundStyle(UF.warn).fixedSize(horizontal: false, vertical: true)
                resendButton
            }
            SettingsDivider()
            let syncLayout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 9.6))
            syncLayout {
                Text(Self.syncText(link.lastSync)).ufFont(12.8).foregroundStyle(link.lastSync?.ok == false ? UF.bad : UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.sync")
                if !compact { Spacer() }
                UFButton(link.syncing ? "Gleiche ab …" : "Jetzt abgleichen", icon: "sync", size: .small) { Task { await link.syncNow(force: true) } }
                    .disabled(link.syncing)
                    .accessibilityIdentifier("account.syncNow")
            }
            SettingsDivider()
            Text("Angemeldete Geräte").ufFont(13.12, 600).foregroundStyle(UF.text2)
                .accessibilityAddTraits(.isHeader)
            // Geraete als Liste mit Linien; dieses Geraet mit Haken statt Klammerzusatz am Ende
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(link.sessions.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { SettingsDivider() }
                    HStack(spacing: 9.6) {
                        Text((s.deviceName ?? "Gerät") + (s.current ? " (dieses Gerät)" : "")).ufFont(14.5).foregroundStyle(UF.text)
                        Spacer()
                        if s.current {
                            UFIcon("check", size: 16).foregroundStyle(UF.ok)
                        } else {
                            UFButton("Abmelden", size: .small) { Task { await link.revoke(s.id) } }
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
            UFFlexWrap(gap: 9.6) {
                if link.sessions.count > 1 {
                    UFButton("Andere Geräte abmelden", size: .small) { Task { await link.logoutOthers() } }
                }
                UFButton("Daten exportieren", icon: "download", size: .small) { Task { exportURL = await link.export() } }
                UFButton("Abmelden", icon: "log-out", size: .small) { Task { await link.logout() } }
                    .accessibilityIdentifier("account.logout")
            }
            // Loeschen abgesetzt am Kartenende, das Passwortfeld direkt ueber dem Knopf, zu dem es gehoert
            SettingsDangerZone {
                UFField("Passwort (zum Löschen, falls das Konto eins hat)") {
                    UFTextField("Passwort", text: $deletePassword, secure: true).textContentType(.password)
                }
                UFButton("Konto löschen", icon: "trash", kind: .danger, size: .small) {
                    Task {
                        guard await overlay.confirm("StudiNow-Konto löschen? Es wird sofort gesperrt und nach 30 Tagen endgültig gelöscht – auch auf Windows und im Web. Die Daten auf diesem \(UFDevice.name) bleiben.") else { return }
                        _ = await link.delete(password: deletePassword.isEmpty ? nil : deletePassword)
                        deletePassword = ""
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var resendButton: some View {
        UFButton("Bestätigungslink erneut senden", icon: "refresh", size: .small) { Task { await link.resendVerification() } }
            .disabled(link.busy)
            .accessibilityIdentifier("account.resendVerification")
    }

    private struct ExportItem: Identifiable {
        let url: URL
        var id: String { url.path }
    }
}
