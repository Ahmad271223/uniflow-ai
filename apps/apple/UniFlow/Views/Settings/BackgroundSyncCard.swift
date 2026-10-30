import SwiftUI
import UniFlowCore

// Karte "Im Hintergrund abgleichen" in den Einstellungen (S8, UniFlow/Services/BackgroundSync.swift): an/aus (Vorgabe
// an), "Benachrichtigen bei neuen Dateien" (erst dieser Schalter fragt iOS nach der Erlaubnis, nie der Start der App),
// ein ehrlicher Satz zu den Zeiten und der letzte Hintergrundlauf des offenen Containers.

private struct BackgroundSyncKey: EnvironmentKey {
    static let defaultValue: BackgroundSyncController? = nil
}

extension EnvironmentValues {
    /// Hintergrundabgleich der App; nil in Ansichten, die ihn nicht gesetzt bekommen (dann fehlt die Karte)
    var backgroundSync: BackgroundSyncController? {
        get { self[BackgroundSyncKey.self] }
        set { self[BackgroundSyncKey.self] = newValue }
    }
}

struct BackgroundSyncCard: View {
    @Environment(\.backgroundSync) private var background

    var body: some View {
        if let background { Panel(background: background) }
    }

    /// Ehrlicher Satz zu den Zeiten (Wunsch 8/15/20 Uhr, iOS garantiert keine Uhrzeit)
    static let timingText = "iOS entscheidet, wann genau; frühestens 8, 15 und 20 Uhr. Ein kurzer Lauf holt neue Kurse, Dateilisten und den Stundenplan, ein längerer mit Netz lädt die neuen Dateien. Sicher ist der Abgleich beim Öffnen der App. Der längere Lauf erzeugt dabei auch fällige Wochentests, wenn die KI verbunden ist – auch bei ausgeschaltetem Abgleich."

    /// Erklaerung unter "Benachrichtigen" mit der Quelle der Hochschule
    static func notifyText(_ university: UniversityKey?) -> String {
        let files = university == .hildesheim ? "Learnweb" : "Stud.IP"
        let login = BackgroundNotice.loginNeeded([files])?.title ?? ""
        return "Die Mitteilung nennt nur die Zahl, nie Dateinamen („3 neue Dateien aus \(files)“). Läuft die Anmeldung ab, kommt einmal „\(login)“ – im Hintergrund meldet sich Studora nie selbst an und benutzt keine gemerkten Zugangsdaten."
    }

    static let deniedText = "Mitteilungen für Studora sind ausgeschaltet. Erlaube sie in den iPad-Einstellungen unter „Mitteilungen“ und schalte „Benachrichtigen“ danach hier erneut ein."

    static let refreshOffText = "Die Hintergrundaktualisierung ist in den iPad-Einstellungen ausgeschaltet (Allgemein → Hintergrundaktualisierung). Bis dahin gleicht Studora nur beim Öffnen ab."

    /// "Letzter Hintergrundlauf: 08:14 – Listen: 3 neue Dateien"
    static func lastRunText(_ r: BackgroundSyncRecord?, now: Date) -> String {
        guard let r else { return "Letzter Hintergrundlauf: noch keiner" }
        return "Letzter Hintergrundlauf: \(HildesheimConnection.time(r.finishedAt, now: now)) – \(r.text)"
    }

    private struct Panel: View {
        @ObservedObject var background: BackgroundSyncController
        @State private var enabled = true
        @State private var notify = false
        @State private var asking = false
        @State private var hint: String?

        var body: some View {
            UFCard {
                UFCardHead("Im Hintergrund abgleichen", icon: "sync") {
                    UFBadge(enabled ? "an" : "aus", tone: enabled ? .ok : .neutral)
                }
                Toggle(isOn: Binding(get: { enabled }, set: { v in
                    enabled = v
                    background.setEnabled(v)
                })) {
                    Text("Im Hintergrund abgleichen").ufFont(14.5, 550).foregroundStyle(UF.text)
                }
                .tint(UF.accent)
                .accessibilityIdentifier("background.enabled")
                Text(BackgroundSyncCard.timingText)
                    .ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("background.timing")
                if enabled, background.refreshStatus() != .available {
                    Text(BackgroundSyncCard.refreshOffText)
                        .ufFont(12.8, 600).foregroundStyle(UF.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                Toggle(isOn: Binding(get: { notify }, set: { v in setNotify(v) })) {
                    Text("Benachrichtigen bei neuen Dateien").ufFont(14.5, 550).foregroundStyle(UF.text)
                }
                .tint(UF.accent)
                .disabled(!enabled || asking)
                .accessibilityIdentifier("background.notify")
                .padding(.top, 9.6)
                Text(BackgroundSyncCard.notifyText(background.containers.key?.university))
                    .ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint)
                        .ufFont(12.8, 600).foregroundStyle(UF.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .accessibilityIdentifier("background.hint")
                }
                // liest den Stand nach jedem Lauf neu (`revision`)
                Text(BackgroundSyncCard.lastRunText(background.revision >= 0 ? background.lastRecord : nil, now: Date()))
                    .ufFont(13.12, 600).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9.6)
                    .accessibilityIdentifier("background.last")
            }
            .onAppear {
                enabled = background.settings.enabled
                notify = background.settings.notify
            }
        }

        /// Einschalten fragt iOS (einmal; abgelehnt: Hinweis, Schalter bleibt aus)
        private func setNotify(_ v: Bool) {
            hint = nil
            notify = v
            asking = v
            Task {
                let ok = await background.setNotify(v)
                asking = false
                if v, !ok {
                    notify = false
                    hint = BackgroundSyncCard.deniedText
                }
            }
        }
    }
}
