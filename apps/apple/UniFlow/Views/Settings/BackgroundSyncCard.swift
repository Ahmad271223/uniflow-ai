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
        let files = university == .hildesheim ? "Learnweb" : university == .hsh ? "Moodle" : "Stud.IP"
        let login = BackgroundNotice.loginNeeded([files])?.title ?? ""
        return "Die Mitteilung nennt nur die Zahl, nie Dateinamen („3 neue Dateien aus \(files)“). Läuft die Anmeldung ab, meldet StudiNow dich mit dem gespeicherten Uni-Zugang still neu an (falls gespeichert und unten erlaubt). Klappt das nicht, kommt einmal „\(login)“."
    }

    /// Erklaerung unter den Mitteilungen zu Noten, Nachrichten und Ankuendigungen (Version 1.3/1.4)
    static let newsText = "Jede Art hat einen eigenen Schalter. Stud.IP-Nachrichten nennen nur die Zahl, nie Absender oder Betreff. Neue Noten nennen das Modul; den Notenwert nur, wenn du es unten erlaubst – sonst stünde er auf dem Sperrbildschirm."

    static func label(_ kind: BackgroundNewsKind, university: UniversityKey? = nil) -> String {
        switch kind {
        case .grades: return "Neue Noten"
        case .messages: return university == .hildesheim ? "Learnweb-Nachrichten" : "Stud.IP-Nachrichten"
        case .announcements: return "Ankündigungen"
        }
    }

    /// Erklaerung unter "Im Hintergrund neu anmelden"
    static let reloginText = "Nur mit dem Uni-Zugang, den du unter „Uni-Zugang“ gespeichert hast. Er liegt nur im Schlüsselbund dieses Geräts und geht nie an einen Server von StudiNow. Höchstens ein Versuch je Dienst in 6 Stunden; ein abgelehntes Passwort wird gelöscht und nie erneut gesendet."

    /// Am Mac ("Designed for iPad"): eigener Takt, solange die App laeuft
    static let macText = "Am Mac gleicht StudiNow zusätzlich alle 20 bis 30 Minuten ab, solange die App geöffnet ist – auch wenn sie nicht vorn ist."

    static let deniedText = "Mitteilungen für StudiNow sind ausgeschaltet. Erlaube sie in den iPad-Einstellungen unter „Mitteilungen“ und schalte „Benachrichtigen“ danach hier erneut ein."

    static let refreshOffText = "Die Hintergrundaktualisierung ist in den iPad-Einstellungen ausgeschaltet (Allgemein → Hintergrundaktualisierung). Bis dahin gleicht StudiNow nur beim Öffnen ab."

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
        @State private var newsOn: [BackgroundNewsKind: Bool] = [:]
        @State private var gradeValue = false
        @State private var relogin = true

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
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("background.timing")
                if enabled, background.refreshStatus() != .available {
                    Text(BackgroundSyncCard.refreshOffText)
                        .ufFont(12.8, 600).foregroundStyle(UF.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                // Linien trennen die beiden Schalter und den Stand des letzten Laufs (vorher nur Abstand)
                SettingsDivider().padding(.vertical, 12)
                Toggle(isOn: Binding(get: { notify }, set: { v in setNotify(v) })) {
                    Text("Benachrichtigen bei neuen Dateien").ufFont(14.5, 550).foregroundStyle(UF.text)
                }
                .tint(UF.accent)
                .disabled(!enabled || asking)
                .accessibilityIdentifier("background.notify")
                Text(BackgroundSyncCard.notifyText(background.containers.key?.university))
                    .ufFont(12.8).foregroundStyle(UF.muted)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint)
                        .ufFont(12.8, 600).foregroundStyle(UF.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .accessibilityIdentifier("background.hint")
                }
                SettingsDivider().padding(.vertical, 12)
                newsSection
                SettingsDivider().padding(.vertical, 12)
                Toggle(isOn: Binding(get: { relogin }, set: { v in
                    relogin = v
                    background.news.relogin = v
                })) {
                    Text("Im Hintergrund neu anmelden").ufFont(14.5, 550).foregroundStyle(UF.text)
                }
                .tint(UF.accent)
                .disabled(!enabled)
                .accessibilityIdentifier("background.relogin")
                Text(BackgroundSyncCard.reloginText)
                    .ufFont(12.8).foregroundStyle(UF.muted)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
                if MacBackgroundTicker.isMac {
                    Text(BackgroundSyncCard.macText)
                        .ufFont(12.8).foregroundStyle(UF.muted)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("background.mac")
                }
                SettingsDivider().padding(.vertical, 12)
                // liest den Stand nach jedem Lauf neu (`revision`)
                Text(BackgroundSyncCard.lastRunText(background.revision >= 0 ? background.lastRecord : nil, now: Date()))
                    .ufFont(13.12, 600).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("background.last")
                // Abgleich der Notizen zwischen deinen Geraeten ist Pro AI: in Free und Plus sichtbar mit Schloss
                // (Auftrag des Inhabers 12.11.2026); mit Pro AI steht er in der Karte des StudiNow-Kontos
                DeviceSyncLockRow()
                #if DEBUG
                // Im Simulator lehnt iOS BGTaskScheduler ab ("not available on this platform", Code 1): derselbe Lauf
                // wie beim Start durch iOS, nur von Hand
                UFButton("Langen Hintergrundlauf starten (Debug)", size: .small) {
                    Task { _ = await background.perform(.processing) }
                }
                .padding(.top, 8)
                .accessibilityIdentifier("background.debugRun")
                #endif
            }
            .onAppear {
                enabled = background.settings.enabled
                notify = background.settings.notify
                for k in BackgroundNewsKind.allCases { newsOn[k] = background.news.isOn(k) }
                gradeValue = background.news.gradeValue
                relogin = background.news.relogin
            }
        }

        /// Arten mit eigenem Schalter; Nachrichten nur an Hochschulen mit Stud.IP bzw. Learnweb (Uni Hildesheim, 12.11.2026)
        private var kinds: [BackgroundNewsKind] {
            let u = background.containers.key?.university
            let messages = u?.profile.studipBase != nil || u == .hildesheim
            return BackgroundNewsKind.allCases.filter { $0 != .messages || messages }
        }

        @ViewBuilder private var newsSection: some View {
            Text("Mitteilungen").ufFont(13.12, 650).foregroundStyle(UF.text2)
                .padding(.bottom, 4)
            ForEach(kinds, id: \.self) { kind in
                Toggle(isOn: Binding(get: { newsOn[kind] ?? false }, set: { v in setNews(kind, v) })) {
                    Text(BackgroundSyncCard.label(kind, university: background.containers.key?.university)).ufFont(14.5, 550).foregroundStyle(UF.text)
                }
                .tint(UF.accent)
                .disabled(!enabled || asking)
                .accessibilityIdentifier("background.news.\(kind)")
                if kind == .grades {
                    Toggle(isOn: Binding(get: { gradeValue }, set: { v in
                        gradeValue = v
                        background.news.gradeValue = v
                    })) {
                        Text("Notenwert in der Mitteilung zeigen").ufFont(13.5, 500).foregroundStyle(UF.text2)
                    }
                    .tint(UF.accent)
                    .padding(.leading, 16)
                    .disabled(!enabled || !(newsOn[.grades] ?? false))
                    .accessibilityIdentifier("background.news.gradeValue")
                }
            }
            Text(BackgroundSyncCard.newsText)
                .ufFont(12.8).foregroundStyle(UF.muted)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }

        /// Einschalten fragt iOS (einmal; abgelehnt: Hinweis, Schalter bleibt aus)
        private func setNews(_ kind: BackgroundNewsKind, _ v: Bool) {
            hint = nil
            newsOn[kind] = v
            asking = v
            Task {
                let ok = await background.setNewsNotify(kind, v)
                asking = false
                if v, !ok {
                    newsOn[kind] = false
                    hint = BackgroundSyncCard.deniedText
                }
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

/// "Notizen auf allen deinen Geräten" (`UFFeature.deviceSync`, Pro AI) ohne Pro AI: Zeile mit Schloss "ab Pro AI",
/// Antippen oeffnet die Tarifwahl. Mit Pro AI nichts (der Abgleich steht in der Karte des StudiNow-Kontos).
struct DeviceSyncLockRow: View {
    @ObservedObject private var ent = Entitlements.shared
    @Environment(\.ufProAIOfferHidden) private var proAIOfferHidden

    var body: some View {
        if let lock = UFLock.plan(.deviceSync, plan: ent.plan), !(lock == .proAI && proAIOfferHidden) {
            SettingsDivider().padding(.vertical, 12)
            UFLockedButton(plan: lock, title: UFFeature.deviceSync.title, identifier: "settings.deviceSync.locked") {
                HStack(spacing: 8) {
                    UFIcon(UFFeature.deviceSync.icon, size: 16).foregroundStyle(UF.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UFFeature.deviceSync.title).ufFont(14.5, 550).foregroundStyle(UF.text)
                        Text(UFFeature.deviceSync.detail ?? "").ufFont(12.8).foregroundStyle(UF.muted)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
            }
        }
    }
}
