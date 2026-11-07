import SwiftUI
import UniFlowCore

/// Einstellungen → Erweitert → "Eigenes ChatGPT" (Auftrag des Inhabers vom 07.11.2026): OpenAI-API-Schluessel
/// eintragen (nur Schluesselbund dieses iPads, nie an StudiNow), Verbindung testen (`GET /v1/models`), Modell waehlen,
/// Schalter, Schluessel loeschen. In jedem Tarif, auch Free (Entscheidung 05.11.2026); die Anfragen rechnet OpenAI
/// ueber das Konto des Nutzers ab.
struct OpenAIKeyCard: View {
    @ObservedObject var link: OpenAIKeyLink
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.openURL) private var openURL
    @State private var draft = ""

    var body: some View {
        UFCard {
            UFCardHead("Eigenes ChatGPT", icon: "sparkles") { badge }
            Text("Mit deinem eigenen OpenAI-Schlüssel antwortet die KI direkt von deinem iPad aus: Fragen im Editor, Karteikarten, Wochentests und der KI-Lernplan – in jedem Tarif. Der Schlüssel bleibt nur auf diesem iPad; OpenAI rechnet die Anfragen über dein Konto ab.")
                .ufFont(13.12).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let s = link.status, s.hasKey {
                connected(s)
            } else {
                enter
            }
            if let m = link.message {
                HStack(alignment: .top, spacing: 7.2) {
                    UFIcon(link.lastCheckOK ? "check" : "alert", size: 14)
                    Text(m).fixedSize(horizontal: false, vertical: true)
                }
                .ufFont(13.12).foregroundStyle(link.lastCheckOK ? UF.ok : UF.bad).padding(.top, 5.6)
                .accessibilityIdentifier("openaiKey.message")
            }
        }
        .task { await link.refresh() }
    }

    private var badge: some View {
        let s = link.status
        if s?.enabledForAI == true { return UFBadge("an", tone: .ok) }
        if s?.hasKey == true { return UFBadge("eingetragen", tone: .neutral) }
        return UFBadge("nicht eingetragen", tone: .neutral)
    }

    /// Ohne Schluessel: Feld, Hinweis, Link zur OpenAI-Seite, "Prüfen und speichern"
    private var enter: some View {
        VStack(alignment: .leading, spacing: 9.6) {
            Text(OpenAIKeyLink.consentText).ufFont(13.12).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("openaiKey.consent")
            UFTextField("OpenAI-API-Schlüssel (sk-…)", text: $draft, secure: true)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("OpenAI-API-Schlüssel")
                .accessibilityIdentifier("openaiKey.field")
            UFFlexWrap(gap: 9.6) {
                UFButton(link.busy ? "Prüfe …" : "Prüfen und speichern", icon: "sparkles", kind: .primary, size: .small) {
                    let key = draft
                    Task {
                        await link.save(key: key)
                        if link.status?.hasKey == true { draft = "" }
                    }
                }
                .disabled(link.busy || OpenAIKeyRules.normalize(draft) == nil || link.status == nil)
                .accessibilityIdentifier("openaiKey.save")
                UFButton("Schlüssel bei OpenAI erstellen", icon: "share", size: .small) {
                    if let u = URL(string: OpenAIKeyRules.keysURL) { openURL(u) }
                }
                .accessibilityIdentifier("openaiKey.create")
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private func connected(_ s: OpenAIKeySession.Status) -> some View {
        VStack(alignment: .leading, spacing: 9.6) {
            SettingsValue(label: "Schlüssel", value: s.keyHint + (s.checked ? " · geprüft" : " · noch nicht geprüft"))
            SettingsDivider()
            Toggle(isOn: Binding(get: { s.useForAI }, set: { (v: Bool) in _ = Task<Void, Never> { await link.setUseForAI(v) } })) {
                Text("KI-Anfragen über mein ChatGPT").ufFont(14.5, 550).foregroundStyle(UF.text)
            }
            .tint(UF.accent)
            .accessibilityIdentifier("openaiKey.use")
            SettingsDivider()
            HStack(spacing: 9.6) {
                Text("Modell").ufFont(14.5, 550).foregroundStyle(UF.text)
                Spacer(minLength: 8)
                if link.models.isEmpty {
                    Text(s.model.isEmpty ? "–" : s.model).ufFont(13.12).foregroundStyle(UF.muted)
                    UFButton("Modelle laden", size: .small) { Task { await link.loadModels() } }.disabled(link.busy)
                } else {
                    UFSelect(options: link.models.map { ($0, $0) },
                             selection: Binding(get: { s.model }, set: { (v: String) in _ = Task<Void, Never> { await link.setModel(v) } }), small: true)
                        .accessibilityIdentifier("openaiKey.model")
                }
            }
            Text("Standard ist \(OpenAIKeyRules.defaultModel) (günstig). Größere Modelle antworten besser, kosten bei OpenAI aber mehr.")
                .ufFont(12.5).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            SettingsDivider()
            UFFlexWrap(gap: 9.6) {
                UFButton(link.busy ? "Prüfe …" : "Verbindung testen", icon: "sync", size: .small) { Task { await link.test() } }
                    .disabled(link.busy)
                    .accessibilityIdentifier("openaiKey.test")
                UFButton("Verbrauch bei OpenAI", icon: "layers", size: .small) {
                    if let u = URL(string: OpenAIKeyRules.usageURL) { openURL(u) }
                }
            }
            SettingsDangerZone {
                UFButton("Schlüssel löschen", icon: "trash", kind: .danger, size: .small) {
                    Task { if await overlay.confirm("OpenAI-Schlüssel von diesem iPad löschen? Die KI über dein eigenes ChatGPT ist danach aus.") { await link.remove() } }
                }
                .accessibilityIdentifier("openaiKey.remove")
            }
        }
        .padding(.top, 8)
        .task { if link.models.isEmpty { await link.loadModels() } }
    }
}
