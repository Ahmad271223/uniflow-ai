import SwiftUI
import UniFlowCore

// Karte "Im Hintergrund abgleichen" in den Einstellungen (S8, UniFlow/Services/BackgroundSync.swift): an/aus (Vorgabe
// an), "Benachrichtigen bei neuen Dateien" (erst dieser Schalter fragt iOS nach der Erlaubnis, nie der Start der App),
// der Satz zur Regel (8 bis 18 Uhr, alle 30 Minuten, 17.11.2026) mit ehrlichem Hinweis zu iOS und der letzte
// Hintergrundlauf des offenen Containers.

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

    /// Regel des Inhabers (17.11.2026, `AutoSyncSchedule.standard`) und ehrlicher Hinweis, dass iOS die Hintergrund-Laeufe
    /// steuert. Der erste Satz steht immer da, der Rest hinter "Mehr dazu".
    static let timingText = "\(timingShort) Solange StudiNow geöffnet ist, gilt das genau so. Ist die App geschlossen, versucht StudiNow es im Hintergrund – wann und wie oft das wirklich geschieht, entscheidet iOS (Akku, Nutzung der App, Netz, Stromsparmodus, Hintergrundaktualisierung); oft seltener als alle 30 Minuten, manchmal gar nicht. Wer die App im App-Umschalter wegwischt, bekommt bis zum nächsten Öffnen keinen Hintergrund-Abgleich. „Sync“ fragt immer sofort ab, zu jeder Uhrzeit. Der längere Lauf erzeugt dabei auch fällige Wochentests, wenn die KI verbunden ist – auch bei ausgeschaltetem Abgleich."

    /// Erste Saetze der Erklaerungen: bleiben sichtbar, der ganze Text steht hinter "Mehr dazu" (17.11.2026)
    static let timingShort = "Zwischen 8 und 18 Uhr gleicht StudiNow alle 30 Minuten ab. Außerhalb nur, wenn du auf Sync tippst."
    static func notifyShort(_ university: UniversityKey?) -> String {
        let text = notifyText(university)
        return text.range(of: "). ").map { String(text[..<$0.lowerBound]) + ")." } ?? text
    }
    static let newsShort = "Jede Art hat einen eigenen Schalter."
    /// Titel der kleinen Karte (Auftrag des Inhabers 17.11.2026)
    static let notificationsTitle = "Mitteilungen"
    static let reloginShort = "Nur mit dem Uni-Zugang, den du unter „Uni-Zugang“ gespeichert hast."

    /// Erklaerung unter "Benachrichtigen" mit der Quelle der Hochschule
    static func notifyText(_ university: UniversityKey?) -> String {
        let files = university == .hildesheim ? "Learnweb" : university == .hsh ? "Moodle" : "Stud.IP"
        let login = BackgroundNotice.loginNeeded([files])?.title ?? ""
        return "Die Mitteilung nennt nur die Zahl, nie Dateinamen („3 neue Dateien aus \(files)“). Läuft die Anmeldung ab, meldet StudiNow dich mit dem gespeicherten Uni-Zugang still neu an (falls gespeichert und unten erlaubt). Klappt das nicht, kommt einmal „\(login)“."
    }

    /// Erklaerung unter den Mitteilungen zu Noten, Nachrichten und Ankuendigungen (Version 1.3/1.4)
    static let newsText = "Jede Art hat einen eigenen Schalter. Mitteilungen kommen nur nach einem Abgleich von selbst (zwischen 8 und 18 Uhr), nie nach einem Tipp auf „Sync“, und nie zweimal für dasselbe. Neue Noten stehen nur als „Neue Note eingetragen“ da – ohne Note und ohne Modul, weil Mitteilungen auf dem Sperrbildschirm erscheinen. Nachrichten und Uni-Mails nennen nur die Zahl, nie Absender oder Betreff. Ausfall und Raumänderung gelten für deine Termine von heute und morgen."

    static func label(_ kind: BackgroundNewsKind, university: UniversityKey? = nil) -> String {
        switch kind {
        case .schedule: return "Ausfall und Raumänderung (heute, morgen)"
        case .grades: return "Neue Noten"
        case .messages: return university == .hildesheim ? "Learnweb-Nachrichten" : "Stud.IP-Nachrichten"
        case .announcements: return "Ankündigungen"
        }
    }

    /// Erklaerung unter "Im Hintergrund neu anmelden"
    static let reloginText = "Nur mit dem Uni-Zugang, den du unter „Uni-Zugang“ gespeichert hast. Er liegt nur im Schlüsselbund dieses Geräts und geht nie an einen Server von StudiNow. Gilt für Stud.IP, QIS, Uni-Mail, Learnweb, LSF, Moodle und das Campusmanagement – nur zwischen 8 und 18 Uhr und höchstens ein Versuch je Dienst in 30 Minuten; nach einem Fehlschlag erst nach einem Tag wieder. Ein abgelehntes Passwort wird gelöscht und nie erneut gesendet."

    /// Am Mac ("Designed for iPad"): eigener Takt, solange die App laeuft
    static let macText = "Am Mac gleicht StudiNow zwischen 8 und 18 Uhr alle 30 Minuten ab, solange die App geöffnet ist – auch wenn sie nicht vorn ist."

    static let deniedText = "Mitteilungen für StudiNow sind ausgeschaltet. Erlaube sie in den \(UFDevice.textName)-Einstellungen unter „Mitteilungen“ und schalte „Benachrichtigen“ danach hier erneut ein."

    static let refreshOffText = "Die Hintergrundaktualisierung ist in den \(UFDevice.textName)-Einstellungen ausgeschaltet (Allgemein → Hintergrundaktualisierung). Bis dahin gleicht StudiNow nur ab, solange die App geöffnet ist."

    /// "Letzter Hintergrundlauf: 08:14 – Listen: 3 neue Dateien"
    static func lastRunText(_ r: BackgroundSyncRecord?, now: Date) -> String {
        guard let r else { return "Letzter Hintergrundlauf: noch keiner" }
        return "Letzter Hintergrundlauf: \(HildesheimConnection.time(r.finishedAt, now: now)) – \(r.text)"
    }

    private struct Panel: View {
        @ObservedObject var background: BackgroundSyncController
        @State private var enabled = true
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
                // lange Erklaerungen hinter "Mehr dazu" (17.11.2026): zu steht der erste Satz da, offen der ganze Text
                SettingsMore(summary: BackgroundSyncCard.timingShort, text: BackgroundSyncCard.timingText, identifier: "background.timing")
                    .padding(.top, 4)
                if enabled, background.refreshStatus() != .available {
                    Text(BackgroundSyncCard.refreshOffText)
                        .ufFont(12.8, 600).foregroundStyle(UF.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                // Mitteilungen stehen seit 17.11.2026 in der eigenen kleinen Karte darunter (`SyncNotificationsCard`)
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
                SettingsMore(summary: BackgroundSyncCard.reloginShort, text: BackgroundSyncCard.reloginText, identifier: "background.reloginText")
                    .padding(.top, 4)
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
                relogin = background.news.relogin
            }
        }
    }
}

/// Kleine Karte "Mitteilungen" (Auftrag des Inhabers 17.11.2026): jede Art einzeln, Vorgabe aus, erst das Einschalten
/// einer Art fragt iOS nach der Erlaubnis. Neue Dateien (gebuendelt), Stud.IP- bzw. Learnweb-Nachrichten, Uni-Mail,
/// Ausfall und Raumaenderung heute/morgen, neue Noten (nur "Neue Note eingetragen"), Ankuendigungen. Kennungen wie vorher
/// in der Karte "Im Hintergrund abgleichen" (`background.notify`, `background.news.*`).
struct SyncNotificationsCard: View {
    @Environment(\.backgroundSync) private var background

    var body: some View {
        if let background { Panel(background: background) }
    }

    private struct Panel: View {
        @ObservedObject var background: BackgroundSyncController
        @State private var notify = false
        @State private var mail = false
        @State private var asking = false
        @State private var hint: String?
        @State private var newsOn: [BackgroundNewsKind: Bool] = [:]

        var body: some View {
            UFCard {
                UFCardHead(BackgroundSyncCard.notificationsTitle, icon: "bell")
                Toggle(isOn: Binding(get: { notify }, set: { v in setNotify(v) })) {
                    Text("Neue Dateien").ufFont(14.5, 550).foregroundStyle(UF.text)
                }
                .tint(UF.accent)
                .disabled(asking)
                .accessibilityIdentifier("background.notify")
                SettingsMore(summary: BackgroundSyncCard.notifyShort(background.containers.key?.university),
                             text: BackgroundSyncCard.notifyText(background.containers.key?.university), identifier: "background.notifyText")
                    .padding(.top, 4)
                ForEach(kinds, id: \.self) { kind in
                    Toggle(isOn: Binding(get: { newsOn[kind] ?? false }, set: { v in setNews(kind, v) })) {
                        Text(BackgroundSyncCard.label(kind, university: background.containers.key?.university)).ufFont(14.5, 550).foregroundStyle(UF.text)
                    }
                    .tint(UF.accent)
                    .disabled(asking)
                    .accessibilityIdentifier("background.news.\(kind)")
                    if kind == .messages, background.containers.uniMail != nil {
                        Toggle(isOn: Binding(get: { mail }, set: { v in setMail(v) })) {
                            Text("Neue Uni-Mails").ufFont(14.5, 550).foregroundStyle(UF.text)
                        }
                        .tint(UF.accent)
                        .disabled(asking)
                        .accessibilityIdentifier("background.news.unimail")
                    }
                }
                SettingsMore(summary: BackgroundSyncCard.newsShort, text: BackgroundSyncCard.newsText, identifier: "background.newsText")
                    .padding(.top, 4)
                if let hint {
                    Text(hint)
                        .ufFont(12.8, 600).foregroundStyle(UF.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .accessibilityIdentifier("background.hint")
                }
            }
            .onAppear {
                notify = background.settings.notify
                mail = background.containers.uniMail?.notify ?? false
                for k in BackgroundNewsKind.allCases { newsOn[k] = background.news.isOn(k) }
            }
        }

        /// Arten mit eigenem Schalter; Nachrichten nur an Hochschulen mit Stud.IP bzw. Learnweb (Uni Hildesheim, 12.11.2026)
        private var kinds: [BackgroundNewsKind] {
            let u = background.containers.key?.university
            let messages = u?.profile.studipBase != nil || u == .hildesheim
            return BackgroundNewsKind.allCases.filter { $0 != .messages || messages }
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

        /// Uni-Mail: derselbe Schalter wie in der Karte der Uni-Mail (`UniMailConnection.notify`)
        private func setMail(_ v: Bool) {
            hint = nil
            mail = v
            asking = v
            Task {
                let ok = await background.setMailNotify(v)
                asking = false
                let on = v && ok
                mail = on
                background.containers.uniMail?.notify = on
                if v, !ok { hint = BackgroundSyncCard.deniedText }
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
