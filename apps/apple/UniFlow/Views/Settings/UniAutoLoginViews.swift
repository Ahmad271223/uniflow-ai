import SwiftUI
import UniFlowCore
import WebKit

// Automatisch anmelden (Entscheidung des Inhabers 06.11.2026, docs/AUTOMATISCH-ANMELDEN-2026-11-06.md): der Schalter
// unter jeder Anmeldeseite (erster Start und Anmeldeblaetter) und die Karte in den Einstellungen.

/// Schalter unter der Anmeldeseite: "Passwort auf diesem iPad merken" (Vorgabe an). Nur fuer Webansichten eines
/// Containers (`UniAutoLogin.attach`); sonst nichts. Aus loescht ein schon gemerktes Passwort dieser Hochschule.
struct UniRememberPasswordToggle: View {
    let dataStore: WKWebsiteDataStore
    @State private var on: Bool?

    static let title = "Passwort auf diesem iPad merken – du wirst nicht erneut gefragt"
    static let note = "Nur auf diesem Gerät im Schlüsselbund, nie auf unseren Servern"

    var body: some View {
        if UniAutoLogin.entry(dataStore) != nil {
            Toggle(isOn: Binding(get: { on ?? UniAutoLogin.isEnabled(dataStore) }, set: { v in
                on = v
                UniAutoLogin.setEnabled(v, store: dataStore)
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title).ufFont(13.12, 600).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.note).ufFont(12.16).foregroundStyle(UF.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(UF.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UF.surface)
            .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
            .accessibilityIdentifier("login.autologin")
        }
    }
}

/// Karte "Automatisch anmelden" (Einstellungen, Studium): Schalter, gemerkter Benutzername, "Gespeichertes Passwort
/// löschen". Gilt fuer alle Dienste der Hochschule des offenen Containers (eine Zugangskennung).
struct UniAutoLoginCard: View {
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var toast: UFToastCenter
    @State private var revision = 0

    static func text(_ u: UniversityKey) -> String {
        "Nach der ersten Anmeldung meldet StudiNow dich bei \(services(u)) selbst wieder an, wenn die Sitzung abläuft. "
            + "Dein Passwort liegt dafür nur auf diesem iPad im Schlüsselbund (nicht in iCloud, nicht auf StudiNow-Servern) "
            + "und wird nur auf den Anmeldeseiten der \(u.profile.name) eingesetzt."
    }

    static func services(_ u: UniversityKey) -> String {
        switch u {
        case .luh: return "Stud.IP, QIS und Uni-Mail"
        case .hildesheim: return "Learnweb, LSF, PLuS und Uni-Mail"
        case .hsh: return "Moodle und im Campusmanagement"
        }
    }

    static func usernameText(_ name: String?) -> String {
        name.map { "Gespeichert für: \($0)" } ?? "Noch kein Passwort gespeichert. Es wird bei der nächsten Anmeldung gemerkt."
    }

    static let rejectedText = "Die Hochschule hat das gespeicherte Passwort abgelehnt. Melde dich einmal neu an, dann merkt StudiNow das neue."
    static let deletedText = "Das gespeicherte Passwort wurde von diesem iPad gelöscht."

    var body: some View {
        if let c = containers.active {
            let store = containers.studip.websiteDataStore
            let enabled = UniAutoLogin.isEnabled(c.defaults)
            let name = UniAutoLogin.storedUsername(store)
            UFCard {
                UFCardHead("Automatisch anmelden", icon: "user") {
                    UFBadge(enabled ? "an" : "aus", tone: enabled ? .ok : .neutral)
                }
                Toggle(isOn: Binding(get: { enabled }, set: { v in
                    UniAutoLogin.setEnabled(v, store: store)
                    revision += 1
                })) {
                    Text("Automatisch anmelden").ufFont(14.5, 550).foregroundStyle(UF.text)
                }
                .tint(UF.accent)
                .accessibilityIdentifier("settings.autologin.enabled")
                Text(Self.text(c.key.university))
                    .ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                SettingsDivider().padding(.vertical, 12)
                Text(Self.usernameText(name))
                    .ufFont(13.12, 600).foregroundStyle(UF.text2)
                    .accessibilityIdentifier("settings.autologin.username")
                if UniAutoLogin.wasRejected(store) {
                    Text(Self.rejectedText).ufFont(12.8, 600).foregroundStyle(UF.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                if name != nil {
                    UFButton("Gespeichertes Passwort löschen", icon: "trash", kind: .danger, size: .small) {
                        UniAutoLogin.forget(store)
                        revision += 1
                        toast.show(Self.deletedText, seconds: 3)
                    }
                    .accessibilityIdentifier("settings.autologin.delete")
                    .padding(.top, 9.6)
                }
            }
            .id(revision)
        }
    }
}
