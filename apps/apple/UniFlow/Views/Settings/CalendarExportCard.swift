import SwiftUI
import UniFlowCore

/// Karte "Termine im Kalender" (26.11.2026, UniFlow/Services/CalendarExport.swift): Schalter (Vorgabe aus; erst er
/// fragt iOS nach der Erlaubnis), Zeitraum, was mit hinein soll, Stand des letzten Abgleichs. Ausschalten fragt nach
/// und entfernt den Kalender "StudiNow".
struct CalendarExportCard: View {
    @ObservedObject private var export = CalendarExport.shared
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.ufDemoActive) private var demo
    @State private var busy = false

    var body: some View {
        UFCard {
            UFCardHead(CalendarExport.title, icon: "calendar") {
                UFBadge(export.settings.enabled ? "an" : "aus", tone: export.settings.enabled ? .ok : .neutral)
            }
            Toggle(isOn: Binding(get: { export.settings.enabled }, set: { v in toggle(v) })) {
                Text("In die Kalender-App eintragen").ufFont(14.5, 550).foregroundStyle(UF.text)
            }
            .tint(UF.accent)
            .disabled(busy)
            .accessibilityIdentifier("calendarExport.enabled")
            SettingsMore(summary: CalendarExport.short, text: "\(CalendarExport.short) \(CalendarExport.longText)", identifier: "calendarExport.text")
                .padding(.top, 4)
            if let text = export.statusText() {
                Text(text)
                    .ufFont(12.8, 600)
                    .foregroundStyle(isProblem ? UF.warn : UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .accessibilityIdentifier("calendarExport.status")
            }
            if demo, export.settings.enabled {
                Text("Mit Beispielinhalten trägt StudiNow nichts in deinen Kalender ein.")
                    .ufFont(12.8).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            if export.settings.enabled {
                SettingsDivider().padding(.vertical, 12)
                Text("Zeitraum").ufFont(13.12, 600).foregroundStyle(UF.text2)
                UFSegmented(options: CalendarExportSettings.Range.allCases.map { ($0, $0.label) },
                            selection: Binding(get: { export.settings.range }, set: { v in change { $0.range = v } }))
                    .padding(.top, 4)
                    .accessibilityIdentifier("calendarExport.range")
                option("Abgaben und Fristen", \.deadlines, id: "deadlines")
                option("Klausuren und Prüfungen", \.exams, id: "exams")
                option("Ausfälle als „Fällt aus“ zeigen", \.cancelled, id: "cancelled")
                option("Feiertage und vorlesungsfreie Zeit", \.holidays, id: "holidays")
            }
        }
    }

    private var isProblem: Bool {
        switch export.status {
        case .denied, .writeOnly, .failed, .calendarDeleted: return true
        default: return false
        }
    }

    private func option(_ label: String, _ path: WritableKeyPath<CalendarExportSettings, Bool>, id: String) -> some View {
        Toggle(isOn: Binding(get: { export.settings[keyPath: path] }, set: { v in change { $0[keyPath: path] = v } })) {
            Text(label).ufFont(14.5, 550).foregroundStyle(UF.text)
        }
        .tint(UF.accent)
        .padding(.top, 8)
        .accessibilityIdentifier("calendarExport.\(id)")
    }

    private func change(_ f: @escaping (inout CalendarExportSettings) -> Void) {
        Task { await export.update(f, api: session.api, demo: demo) }
    }

    private func toggle(_ on: Bool) {
        busy = true
        Task {
            defer { busy = false }
            if !on, !(await overlay.confirm(CalendarExport.offConfirm)) { return }
            await export.setEnabled(on, api: session.api, demo: demo)
        }
    }
}

/// Karte "Widget „Nachrichten“" (26.11.2026): was das Widget zeigen darf. Vorgabe: Zahl, Absender und Betreff auf dem
/// Home-Bildschirm; auf dem Sperrbildschirm nur Zahl und Absender; nie ein Nachrichtentext ohne den Schalter.
struct MessagesWidgetCard: View {
    @Environment(\.uniMail) private var uniMail
    @EnvironmentObject private var containers: ContainerManager
    @State private var prefs = MessagesWidgetPrefs.load()

    var body: some View {
        UFCard {
            UFCardHead("Widget „Nachrichten“", icon: "mail")
            Text(MessagesWidgetPrefs.intro)
                .ufFont(12.8).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
            toggle("Betreff auf dem Sperrbildschirm", \.lockSubjects, id: "lockSubjects")
            toggle("Anfang des Nachrichtentexts zeigen", \.preview, id: "preview")
            if uniMail != nil { toggle("Uni-Mail mitzählen", \.mail, id: "mail") }
        }
    }

    private func toggle(_ label: String, _ path: WritableKeyPath<MessagesWidgetPrefs, Bool>, id: String) -> some View {
        Toggle(isOn: Binding(get: { prefs[keyPath: path] }, set: { v in
            prefs[keyPath: path] = v
            prefs.save()
            Task { await HomeWidgetSync.refresh(api: containers.active?.api) }
        })) {
            Text(label).ufFont(14.5, 550).foregroundStyle(UF.text)
        }
        .tint(UF.accent)
        .padding(.top, 8)
        .accessibilityIdentifier("messagesWidget.\(id)")
    }
}
