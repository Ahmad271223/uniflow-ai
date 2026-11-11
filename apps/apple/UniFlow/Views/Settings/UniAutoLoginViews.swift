import SwiftUI
import UniFlowCore
import WebKit

// Automatisch anmelden (Entscheidung des Inhabers 06.11.2026, docs/AUTOMATISCH-ANMELDEN-2026-11-06.md): der Schalter
// unter jeder Anmeldeseite (erster Start und Anmeldeblaetter) und die Karte in den Einstellungen. Seit 10.11.2026
// (Uni-Zugang einmal speichern, Abschnitt 1.0.2): Benutzername und Passwort direkt in der Karte, gemeinsam fuer alle
// Dienste ("Benutzername und Passwort sind überall gleich", Vorgabe an) oder je Portal; nach "Speichern" verbindet
// die App gleich (`ContainerManager.connectWithStoredLogin`) und zeigt das Ergebnis.

/// Schalter unter der Anmeldeseite: "Passwort auf diesem iPad merken" (Vorgabe an). Nur fuer Webansichten eines
/// Containers (`UniAutoLogin.attach`); sonst nichts. Aus loescht ein schon gemerktes Passwort dieser Hochschule.
struct UniRememberPasswordToggle: View {
    let dataStore: WKWebsiteDataStore
    @State private var on: Bool?

    static let title = UFDevice.adapt("Passwort auf diesem iPad merken – du wirst nicht erneut gefragt")
    static let note = "Nur auf diesem Gerät im Schlüsselbund, nie auf unseren Servern"
    static let phoneTitle = UFDevice.adapt("Passwort auf diesem iPad merken")

    var body: some View {
        if UniAutoLogin.entry(dataStore) != nil {
            Toggle(isOn: Binding(get: { on ?? UniAutoLogin.isEnabled(dataStore) }, set: { v in
                on = v
                UniAutoLogin.setEnabled(v, store: dataStore)
            })) {
                // iPhone (11.11.2026): eine Zeile, damit die Anmeldeseite darueber Platz hat; der ganze Satz steht im
                // Hinweis darueber unter "Mehr"
                if UFCompact.phoneLayouts {
                    Text(Self.phoneTitle).ufFont(13.12, 600).foregroundStyle(UF.text).lineLimit(2)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title).ufFont(13.12, 600).foregroundStyle(UF.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.note).ufFont(12.16).foregroundStyle(UF.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(UF.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, UFCompact.phoneLayouts ? 4 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UF.surface)
            .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
            .accessibilityIdentifier("login.autologin")
        }
    }
}

/// Karte "Uni-Zugang" (Einstellungen, Zugang & Darstellung, erste Karte unter Studium): Schalter "Benutzername und Passwort sind überall gleich"; an: ein
/// Formular fuer alle Dienste, aus: Stud.IP, QIS und Uni-Mail (SOGo) untereinander, jedes mit eigenem Formular,
/// Status und "Entfernen". Gilt fuer den offenen Container (Apple-Nutzer und Hochschule).
struct UniAutoLoginCard: View {
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var toast: UFToastCenter
    @State private var revision = 0
    @State private var same = UniAutoLogin.sameEverywhere
    @State private var busy = false
    @State private var result: String?

    /// Titel (der Sync-Knopf ohne Zugang sagt "Zuerst den Uni-Zugang in den Einstellungen speichern"; die Pruefhinweise
    /// in docs/release/APP-STORE.md nennen ihn)
    static let title = "Uni-Zugang"
    static let sameTitle = "Benutzername und Passwort sind überall gleich"
    static let note = UFDevice.adapt("Dein Passwort liegt nur im Schlüsselbund dieses iPads – nie auf unseren Servern.")
    static let connectingText = "Verbinde …"

    static func text(_ u: UniversityKey) -> String {
        "Einmal speichern – dann meldet StudiNow dich bei \(services(u)) selbst an und holt deine Daten. "
            + UFDevice.adapt("Dein Passwort liegt dafür nur auf diesem iPad im Schlüsselbund (nicht in iCloud, nicht auf StudiNow-Servern) ")
            + "und wird nur auf den Anmeldeseiten der \(u.profile.name) eingesetzt."
    }

    static func services(_ u: UniversityKey) -> String {
        switch u {
        case .luh: return "Stud.IP, QIS und Uni-Mail"
        case .hildesheim: return "Learnweb, LSF, PLuS und Uni-Mail"
        case .hsh: return "Moodle und im Campusmanagement"
        }
    }

    /// Formulare der Karte: eines fuer alle (nil = gemeinsamer Zugang) oder je Portal (nur an der LUH)
    static func slots(sameEverywhere: Bool, university: UniversityKey) -> [UniAutoLogin.Portal?] {
        guard university == .luh, !sameEverywhere else { return [nil] }
        return UniAutoLogin.Portal.allCases.map { Optional($0) }
    }

    /// Stand eines Eintrags
    enum SlotStatus: Equatable {
        case saved(String)
        case missing
        case rejected
    }

    static func status(_ slot: UniAutoLogin.Portal?, store: WKWebsiteDataStore) -> SlotStatus {
        if UniAutoLogin.hasPassword(portal: slot, store: store) {
            return .saved(UniAutoLogin.storedUsername(portal: slot, store: store) ?? "")
        }
        return UniAutoLogin.isRejected(portal: slot, store: store) ? .rejected : .missing
    }

    static func badge(_ s: SlotStatus) -> (text: String, tone: UFTone) {
        switch s {
        case .saved: return ("gespeichert", .ok)
        case .missing: return ("fehlt", .neutral)
        case .rejected: return ("abgelehnt", .warn)
        }
    }

    /// Zeile unter dem Titel eines Formulars; `shared`: Benutzername des gemeinsamen Zugangs (fuer ein Portal ohne eigenen)
    static func statusText(_ s: SlotStatus, portal: Bool, shared: String? = nil) -> String {
        switch s {
        case .saved(let name): return usernameText(name)
        case .rejected: return rejectedText
        case .missing:
            if portal, let shared { return "Kein eigenes Passwort – es gilt das gemeinsame (\(shared))." }
            return portal ? "Noch kein Passwort gespeichert." : usernameText(nil)
        }
    }

    static func usernameText(_ name: String?) -> String {
        name.map { "Gespeichert für: \($0)" } ?? "Noch kein Passwort gespeichert. Einmal eingeben, dann meldet StudiNow dich selbst an."
    }

    static let rejectedText = UFDevice.adapt("Die Hochschule hat das Passwort abgelehnt. Es ist von diesem iPad gelöscht. Bitte gib das aktuelle ein.")
    static let deletedText = UFDevice.adapt("Das gespeicherte Passwort wurde von diesem iPad gelöscht.")

    /// Meldung nach "Speichern" (nil: gespeichert)
    static func saveMessage(_ r: UniAutoLogin.TypedSave) -> String? {
        switch r {
        case .saved: return nil
        case .unavailable: return "Melde dich zuerst an und wähle deine Hochschule."
        case .badUsername: return "Bitte gib deinen Benutzernamen ohne Leerzeichen ein."
        case .badPassword: return "Bitte gib dein Passwort ein."
        case .failed: return "Der Schlüsselbund hat nicht gespeichert. Bitte versuche es erneut."
        }
    }

    /// Ergebnis von `connectWithStoredLogin` in einem Satz (verbunden / Anmeldung nötig / Passwort abgelehnt)
    static func resultText(_ r: StoredLoginReport) -> String {
        var parts: [String] = []
        if !r.connected.isEmpty { parts.append("Verbunden: \(r.connected.joined(separator: ", ")).") }
        if r.rejected {
            let which = r.rejectedPortals.isEmpty ? "" : " (\(r.rejectedPortals.joined(separator: ", ")))"
            parts.append("Passwort abgelehnt\(which). Bitte prüfe es und speichere es neu.")
        }
        let open = r.needsLogin.filter { !r.rejectedPortals.contains($0) }
        if !open.isEmpty { parts.append("Anmeldung nötig: \(open.joined(separator: ", ")).") }
        if parts.isEmpty { return r.noCredential ? "Noch kein Passwort gespeichert." : "Gespeichert." }
        return parts.joined(separator: " ")
    }

    var body: some View {
        if let c = containers.active {
            let store = containers.studip.websiteDataStore
            let uni = c.key.university
            let slots = Self.slots(sameEverywhere: same, university: uni)
            let overall: SlotStatus = containers.hasStoredLogin ? .saved("") : (UniAutoLogin.wasRejected(store) ? .rejected : .missing)
            UFCard {
                UFCardHead(Self.title, icon: "user") {
                    UFBadge(Self.badge(overall).text, tone: Self.badge(overall).tone)
                }
                Text(Self.text(uni))
                    .ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if uni == .luh {
                    Toggle(isOn: Binding(get: { same }, set: { v in
                        UniAutoLogin.sameEverywhere = v
                        same = v
                        result = nil
                        revision += 1
                    })) {
                        Text(Self.sameTitle).ufFont(14.5, 550).foregroundStyle(UF.text)
                    }
                    .tint(UF.accent)
                    .accessibilityIdentifier("settings.unilogin.same")
                    .padding(.top, 8)
                }
                ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                    SettingsDivider().padding(.vertical, 12)
                    UniLoginSlotForm(slot: slot, store: store, onSaved: { connect() }, onRemoved: {
                        result = nil
                        revision += 1
                        toast.show(Self.deletedText, seconds: 3)
                    })
                }
                SettingsDivider().padding(.vertical, 12)
                if busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(Self.connectingText).ufFont(13.12, 600).foregroundStyle(UF.text2)
                    }
                    .accessibilityIdentifier("settings.unilogin.result")
                } else if let result {
                    Text(result).ufFont(13.12, 600).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.unilogin.result")
                }
                Text(Self.note).ufFont(12.16).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .id(revision)
        }
    }

    /// Nach "Speichern": gleich verbinden (Stud.IP, QIS, Uni-Mail) und das Ergebnis kurz zeigen
    private func connect() {
        result = nil
        busy = true
        revision += 1
        Task { @MainActor in
            let r = await containers.connectWithStoredLogin(userAction: true)
            result = Self.resultText(r)
            busy = false
            revision += 1
        }
    }
}

/// Ein Formular der Karte: Benutzername, Passwort, "Speichern", Status und "Entfernen" fuer einen Eintrag
/// (nil = gemeinsamer Zugang). Das Passwort steht nur im sicheren Feld und ist nach dem Speichern wieder leer.
struct UniLoginSlotForm: View {
    let slot: UniAutoLogin.Portal?
    let store: WKWebsiteDataStore
    let onSaved: () -> Void
    let onRemoved: () -> Void
    @State private var name = ""
    @State private var secret = ""
    @State private var problem: String?
    /// iPhone: Knoepfe in voller Breite
    @Environment(\.ufCompact) private var compact

    /// Kennungen fuer Bedienungshilfen und Tests ("settings.unilogin.<shared|studip|qis|sogo>.<feld>")
    static func identifier(_ slot: UniAutoLogin.Portal?, _ part: String) -> String {
        "settings.unilogin.\(slot?.rawValue ?? "shared").\(part)"
    }

    var body: some View {
        let status = UniAutoLoginCard.status(slot, store: store)
        let shared = slot == nil ? nil : UniAutoLogin.storedUsername(portal: nil, store: store)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(slot?.title ?? "Für alle Dienste").ufFont(14.5, 600).foregroundStyle(UF.text)
                Spacer()
                UFBadge(UniAutoLoginCard.badge(status).text, tone: UniAutoLoginCard.badge(status).tone)
            }
            Text(UniAutoLoginCard.statusText(status, portal: slot != nil, shared: shared))
                .ufFont(12.8, status == .rejected ? 600 : 400)
                .foregroundStyle(status == .rejected ? UF.warn : UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(Self.identifier(slot, "status"))
            UFTextField("Benutzername", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(Self.identifier(slot, "name"))
            UFTextField("Passwort", text: $secret, secure: true)
                .accessibilityIdentifier(Self.identifier(slot, "secret"))
            if let problem {
                Text(problem).ufFont(12.8, 600).foregroundStyle(UF.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if compact {
                // iPhone: Knoepfe untereinander in voller Breite (Daumen)
                VStack(spacing: 8) {
                    UFWideButton("Speichern", kind: .primary) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || secret.isEmpty)
                        .accessibilityIdentifier(Self.identifier(slot, "save"))
                    if case .saved = status {
                        UFWideButton("Entfernen", icon: "trash", kind: .danger) { remove() }
                            .accessibilityIdentifier(Self.identifier(slot, "remove"))
                    }
                }
            } else {
                HStack(spacing: 8) {
                    UFButton("Speichern", kind: .primary, size: .small) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || secret.isEmpty)
                        .accessibilityIdentifier(Self.identifier(slot, "save"))
                    if case .saved = status {
                        UFButton("Entfernen", icon: "trash", kind: .danger, size: .small) { remove() }
                            .accessibilityIdentifier(Self.identifier(slot, "remove"))
                    }
                }
            }
        }
        .onAppear {
            if name.isEmpty { name = UniAutoLogin.storedUsername(portal: slot, store: store) ?? "" }
        }
    }

    private func remove() {
        UniAutoLogin.forget(portal: slot, store: store)
        onRemoved()
    }

    private func save() {
        let r = slot.map { UniAutoLogin.saveTyped(username: name, password: secret, portal: $0, store: store) }
            ?? UniAutoLogin.saveTyped(username: name, password: secret, store: store)
        problem = UniAutoLoginCard.saveMessage(r)
        guard r == .saved else { return }
        secret = ""
        onSaved()
    }
}
