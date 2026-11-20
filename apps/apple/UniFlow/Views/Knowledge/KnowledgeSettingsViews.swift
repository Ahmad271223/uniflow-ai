import SwiftUI
import UniFlowCore

/// Einstellungen -> Erweitert -> "Wissensbibliothek" (20.11.2026): Schalter (Standard aus), Stand, Einlesen, Entfernen.
/// Aus: nirgends in der App zu sehen; die eingelesenen Dateien bleiben, bis man sie entfernt.
struct KnowledgeSettingsCard: View {
    @AppStorage(KnowledgeLibrarySetting.key) private var enabled = false
    @ObservedObject private var center = KnowledgeLibraryCenter.shared
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var overlay: UFOverlay

    static let text = "Eigene Erklärungen und Lösungen zu deinen Unterlagen aus einem Ordner oder einer ZIP-Datei lesen. " + KnowledgeTexts.privacy

    var body: some View {
        UFCard {
            UFCardHead("Wissensbibliothek", icon: "bookmark") {
                UFBadge(enabled ? "an" : "aus", tone: enabled ? .ok : .neutral)
            }
            Toggle(isOn: $enabled) {
                Text("Wissensbibliothek anzeigen").ufFont(14.5, 550).foregroundStyle(UF.text)
            }
            .tint(UF.accent)
            .accessibilityIdentifier("knowledge.enabled")
            Text(Self.text).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            if enabled {
                SettingsDivider().padding(.vertical, 10)
                if let lib = center.current {
                    Text(KnowledgeFormat.standLine(lib.manifest)).ufFont(13.2, 550).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("knowledge.stand")
                    UFFlexWrap(gap: 8) {
                        UFButton("Öffnen", icon: "bookmark", kind: .primary, size: .small) { router.go(.knowledge()) }
                        UFButton("Entfernen", icon: "trash", kind: .danger, size: .small) {
                            Task {
                                guard await overlay.confirm("Wissensbibliothek von diesem Gerät entfernen? Deine Notizen und Dateien bleiben. Du kannst sie jederzeit neu einlesen.") else { return }
                                await center.remove()
                            }
                        }
                        .accessibilityIdentifier("knowledge.remove")
                    }
                    .padding(.top, 6)
                }
                KnowledgeImportButtons().padding(.top, 8)
                KnowledgeMessage().padding(.top, 6)
            }
        }
        .task(id: enabled) { if enabled { await center.ensureLoaded() } }
    }
}

/// Dokumentinformation einer geoeffneten Datei: "Erklärung/Lösung ansehen", wenn ihr Titel oder Dateiname in den
/// Quellen einer Einheit steht. Ohne Schalter, ohne Bibliothek oder ohne Treffer: nichts.
struct KnowledgeSourceLinkSection: View {
    let title: String
    let fileName: String
    @AppStorage(KnowledgeLibrarySetting.key) private var enabled = false
    @ObservedObject private var center = KnowledgeLibraryCenter.shared
    @EnvironmentObject private var router: UFRouter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let units = enabled ? (center.current?.units(matchingTitle: title, fileName: fileName) ?? []) : []
        if !units.isEmpty {
            Section("Wissensbibliothek") {
                ForEach(units.prefix(6)) { u in
                    Button {
                        dismiss()
                        router.go(.knowledge(unit: u.key))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Erklärung/Lösung ansehen")
                            Text(u.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .accessibilityIdentifier("knowledge.openFromDoc")
                }
            }
        }
    }
}

/// Laedt die Bibliothek im Hintergrund, sobald der Schalter an ist (fuer Suche und Dokumentinformation)
struct KnowledgeLibraryPreload: ViewModifier {
    @AppStorage(KnowledgeLibrarySetting.key) private var enabled = false

    func body(content: Content) -> some View {
        content.task(id: enabled) {
            if enabled { await KnowledgeLibraryCenter.shared.ensureLoaded() }
        }
    }
}
