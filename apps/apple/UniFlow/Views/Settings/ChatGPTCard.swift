import SwiftUI
import UniFlowCore

/// Einstellungen → Erweitert → "KI über mein ChatGPT" (wie am PC, docs/KI-CHATGPT-PLAN.md): verbinden mit Zustimmung
/// (Apple 5.1.2), verbundenes Konto, Modell, Schalter, "Nutzung verwalten", trennen. Nur sichtbar, wenn
/// `ChatGPTLink.available` (Debug oder von OpenAI vergebene Client-ID).
struct ChatGPTCard: View {
    @EnvironmentObject private var link: ChatGPTLink
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.openURL) private var openURL

    /// Hinweis vor dem ersten Verbinden: was an OpenAI geht und was nicht
    static let consentText = "Wenn du eine KI-Funktion antippst (Frage im Editor, Wochentest, Zusammenfassung), schickt Studora den Text der Seite oder deiner Markierung, deine Frage und die Namen von Kurs und Datei an OpenAI. Studora speichert Anfragen und Antworten auf keinem Server; die Anmeldung bei ChatGPT liegt nur im Schlüsselbund dieses iPads. Die Nutzung zählt gegen dein ChatGPT-Abo, es gelten die Datenschutzbestimmungen von OpenAI. Du kannst die Verbindung jederzeit trennen."

    var body: some View {
        UFCard {
            UFCardHead("KI über mein ChatGPT", icon: "bulb") { badge }
            Text("Fragen im Editor, Wochentests und Zusammenfassungen über dein eigenes ChatGPT-Abo (Plus oder Pro). In jedem Tarif von Studora; ohne ChatGPT-Abo gibt es keine KI.")
                .ufFont(13.12).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let s = link.status, s.connected {
                connected(s)
            } else {
                UFButton(link.connecting ? "Verbinde …" : "ChatGPT verbinden", icon: "log-out", kind: .primary, size: .small) {
                    Task {
                        guard await overlay.confirm("KI über ChatGPT verbinden?\n\n" + Self.consentText) else { return }
                        await link.connect()
                    }
                }
                .disabled(link.connecting || link.status == nil)
                .accessibilityIdentifier("chatgpt.connect")
                .padding(.top, 8)
            }
            if let m = link.message {
                HStack(alignment: .top, spacing: 7.2) {
                    UFIcon("alert", size: 14)
                    Text(m).fixedSize(horizontal: false, vertical: true)
                }
                .ufFont(13.12).foregroundStyle(UF.bad).padding(.top, 5.6)
                .accessibilityIdentifier("chatgpt.message")
            }
        }
        .task { await link.refresh() }
    }

    private var badge: some View {
        let s = link.status
        if s?.needsReauth == true { return UFBadge("neu verbinden", tone: .warn) }
        if s?.enabledForAI == true { return UFBadge("an", tone: .ok) }
        if s?.connected == true { return UFBadge("verbunden", tone: .neutral) }
        return UFBadge("nicht verbunden", tone: .neutral)
    }

    @ViewBuilder private func connected(_ s: ChatGPTSession.Status) -> some View {
        VStack(alignment: .leading, spacing: 9.6) {
            Text("Verbunden als \([s.name, s.email].compactMap { $0 }.joined(separator: " · "))")
                .ufFont(13.12, 600).foregroundStyle(UF.text)
            if s.needsReauth {
                Text("Die Anmeldung bei ChatGPT ist abgelaufen. Bitte neu verbinden.").ufFont(13.12).foregroundStyle(UF.warn)
                UFButton("Neu verbinden", icon: "sync", kind: .primary, size: .small) { Task { await link.connect() } }
            } else if !s.sharing {
                Text("Die Nutzung deines ChatGPT-Abos wurde bei der Anmeldung nicht freigegeben. Trenne die Verbindung und verbinde neu, um sie zu erlauben.")
                    .ufFont(13.12).foregroundStyle(UF.warn).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: Binding(get: { s.useForAI }, set: { (v: Bool) in _ = Task<Void, Never> { await link.setUseForAI(v) } })) {
                Text("KI-Anfragen über mein ChatGPT").ufFont(14.5, 550).foregroundStyle(UF.text)
            }
            .tint(UF.accent)
            .accessibilityIdentifier("chatgpt.use")
            HStack(spacing: 9.6) {
                Text("Modell").ufFont(13.12, 600).foregroundStyle(UF.text)
                if link.models.isEmpty {
                    Text(s.model.isEmpty ? "–" : s.model).ufFont(13.12).foregroundStyle(UF.muted)
                    UFButton("Modelle laden", size: .small) { Task { await link.loadModels() } }
                } else {
                    UFSelect(options: link.models.map { ($0, $0) },
                             selection: Binding(get: { s.model }, set: { (v: String) in _ = Task<Void, Never> { await link.setModel(v) } }), small: true)
                }
            }
            UFFlexWrap(gap: 9.6) {
                UFButton("Nutzung verwalten", icon: "layers", size: .small) {
                    if let u = URL(string: ChatGPTConstants.usageHelpURL) { openURL(u) }
                }
                UFButton("Trennen", icon: "log-out", kind: .danger, size: .small) {
                    Task { if await overlay.confirm("Verbindung mit ChatGPT trennen? Die Anmeldung wird von diesem iPad gelöscht.") { await link.disconnect() } }
                }
                .accessibilityIdentifier("chatgpt.disconnect")
            }
        }
        .padding(.top, 8)
        .task { if link.models.isEmpty, !s.needsReauth { await link.loadModels() } }
    }
}
