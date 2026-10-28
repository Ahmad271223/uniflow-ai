import SwiftUI
import UniFlowCore

// Hochschule in den Einstellungen (docs/AUFTRAG-HILDESHEIM-IPAD.md Abschnitt 1 und 2): aktuelle Hochschule, Wechsel
// mit dem Hinweis, dass die Daten der anderen Hochschule getrennt bleiben, und "Daten dieser Hochschule löschen".
// Dazu der Rahmen um die Oberflaeche: sie erscheint erst mit offenem Container und baut sich bei jedem Wechsel neu auf.

/// Oberflaeche nur mit offenem Container der gewaehlten Hochschule; neu aufgebaut bei jedem Wechsel (alle Ansichten
/// laden dann aus dem neuen Container, nichts bleibt aus dem alten stehen)
struct ContainerGate<Content: View>: View {
    @EnvironmentObject private var containers: ContainerManager
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let problem = containers.problem {
            ContainerProblemView(message: problem)
        } else if containers.active != nil {
            content().id(containers.generation)
        } else {
            ProgressView().tint(UF.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(UF.bg.ignoresSafeArea())
        }
    }
}

/// Container laesst sich nicht oeffnen (gehoert einer anderen Hochschule oder einem anderen Konto, Umzug gescheitert):
/// verstaendliche Meldung statt gemischter Daten
struct ContainerProblemView: View {
    let message: String
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var containers: ContainerManager

    var body: some View {
        OnboardingPage {
            UFCard {
                UFCardHead("Speicher nicht geöffnet", icon: "alert")
                Text(message)
                    .ufFont(14.5).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("container.problem")
                Text("Damit sich die Daten verschiedener Hochschulen und Konten nie mischen, öffnet Studora diesen Speicher nicht. Es wurde nichts gelöscht.")
                    .ufFont(13.12).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                UFFlexWrap(gap: 9.6) {
                    UFButton("Erneut versuchen", icon: "refresh", kind: .primary) { containers.sync(account: account) }
                    UFButton("Hochschule wählen", icon: "graduation") { account.clearUniversity() }
                }
                .padding(.top, 12.8)
            }
        }
    }
}

/// Karte "Hochschule" neben Konto und Tarif
struct UniversitySettingsCard: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var overlay: UFOverlay

    var body: some View {
        let uni = account.university
        UFCard {
            UFCardHead("Hochschule", icon: "graduation") {
                if let uni { UFBadge(uni.profile.short, tone: .ok) }
            }
            Text(uni?.profile.name ?? "Keine Hochschule gewählt").ufFont(14.5, 600).foregroundStyle(UF.text)
            Text("Jede Hochschule hat auf diesem iPad ihren eigenen Speicher: Datenbank, Dateien, Notizen und Anmeldungen bleiben getrennt.")
                .ufFont(13.12).foregroundStyle(UF.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            UFButton("Hochschule wechseln", icon: "refresh", size: .small) { overlay.modal { UniversitySwitchDialog() } }
                .accessibilityIdentifier("settings.university.switch")
                .padding(.top, 9.6)
            // Loeschen abgesetzt unter einer Linie, nicht neben "Wechseln" (Befund 27.10.: beim Wechseln verwechselt)
            if let uni {
                Divider().padding(.vertical, 9.6)
                Text("Zum Wechseln musst du nichts löschen. Löschen nur, wenn du diese Hochschule auf diesem iPad nicht mehr nutzt.")
                    .ufFont(12.5).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
                UFButton("Daten dieser Hochschule löschen", icon: "trash", kind: .danger, size: .small) {
                    overlay.modal { DeleteUniversityDataDialog(university: uni) }
                }
                .padding(.top, 6.4)
            }
        }
    }
}

/// Wechsel der Hochschule: Auswahl, klarer Hinweis auf die getrennten Daten, danach sofort der Speicher der neuen
struct UniversitySwitchDialog: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var selection: UniversityKey?

    var body: some View {
        let current = account.university
        let target = selection ?? current
        UFDialog("Hochschule wechseln", icon: "graduation") {
            VStack(alignment: .leading, spacing: 9.6) {
                ForEach(UniversityKey.allCases, id: \.self) { u in
                    UniversityOption(university: u, selected: target == u, current: current == u) { selection = u }
                }
                if let current, let target, target != current {
                    Text(Self.notice(from: current, to: target))
                        .ufFont(13.12).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .accessibilityIdentifier("university.switch.notice")
                }
                ContainerSyncGate { syncing in
                    if syncing { ContainerSyncNotice(action: "Wechseln") }
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            // gesperrt, solange ein Abgleich laeuft: sonst liefe er im abgeloesten Speicher weiter, und nach dem
            // Zurueckwechseln liesse sich ein zweiter Abgleich desselben Speichers starten (gemeinsamer Zwischenordner)
            ContainerSyncGate { syncing in
                UFButton("Wechseln", icon: "arrow-right", kind: .primary) {
                    guard let target, target != current, !syncing else { return }
                    overlay.closeAll()
                    account.chooseUniversity(target)                   // RootView oeffnet den Container der neuen Hochschule
                    toast.show("Jetzt mit dem Speicher der \(target.profile.name).", seconds: 3)
                }
                .disabled(target == nil || target == current || syncing)
                .accessibilityIdentifier("university.switch.confirm")
            }
        }
    }

    /// Hinweis vor dem Wechsel: nichts wird geloescht oder uebertragen
    static func notice(from old: UniversityKey, to new: UniversityKey) -> String {
        "Die Daten der \(old.profile.name) bleiben getrennt auf diesem iPad erhalten – Dateien, Notizen, Lernplan und Anmeldungen. "
            + "Nichts davon wird in die \(new.profile.name) übernommen. Studora arbeitet danach sofort mit dem Speicher der \(new.profile.name); "
            + "zurückwechseln kannst du jederzeit hier."
    }
}

/// Inhalt, der sich mit dem Stand der Abgleiche des offenen Containers neu zeichnet (Stud.IP, Learnweb/LSF):
/// Loeschknoepfe sind gesperrt, solange einer laeuft. `ContainerManager` haelt einen laufenden Abgleich vor dem
/// Loeschen ohnehin an und wartet auf ihn; die Sperre sagt das vorher.
struct ContainerSyncGate<Content: View>: View {
    @EnvironmentObject private var containers: ContainerManager
    @ViewBuilder let content: (_ syncing: Bool) -> Content

    var body: some View {
        StudIPObserver(studip: containers.studip, hildesheim: containers.hildesheim, content: content)
    }

    private struct StudIPObserver: View {
        @ObservedObject var studip: StudIPSync
        let hildesheim: HildesheimConnection?
        let content: (Bool) -> Content

        var body: some View {
            if let hildesheim {
                HildesheimObserver(connection: hildesheim, studipRunning: studip.isRunning, content: content)
            } else {
                content(studip.isRunning)
            }
        }
    }

    private struct HildesheimObserver: View {
        @ObservedObject var connection: HildesheimConnection
        let studipRunning: Bool
        let content: (Bool) -> Content

        var body: some View { content(studipRunning || connection.isRunning) }
    }
}

/// Hinweis in den Loeschdialogen, solange ein Abgleich laeuft
struct ContainerSyncNotice: View {
    /// "Löschen" bzw. "Wechseln"
    var action = "Löschen"

    var body: some View {
        Text("Gerade läuft ein Abgleich. \(action) ist möglich, sobald er fertig ist.")
            .ufFont(13.12, 600).foregroundStyle(UF.warn)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("container.delete.syncing")
    }
}

/// "Daten dieser Hochschule löschen": genau dieser Container mit Anmeldung, Learnweb-Schluessel und Webdaten
struct DeleteUniversityDataDialog: View {
    let university: UniversityKey
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var busy = false

    var body: some View {
        UFDialog("Daten der \(university.profile.name) löschen?", icon: "trash") {
            VStack(alignment: .leading, spacing: 9.6) {
                Text(Self.explanation(university))
                    .ufFont(13.12).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                ContainerSyncGate { syncing in
                    if syncing { ContainerSyncNotice() }
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            ContainerSyncGate { syncing in
                UFButton("Endgültig löschen", icon: "trash", kind: .danger) {
                    guard let user = account.account?.userID else { return }
                    busy = true
                    Task {
                        overlay.closeAll()
                        if let problem = await containers.deleteUniversityData(DataContainerKey(userID: user, university: university)) {
                            toast.show(problem, seconds: 6)
                        } else {
                            toast.show("Die Daten der \(university.profile.name) wurden von diesem iPad gelöscht.", seconds: 4)
                        }
                    }
                }
                .disabled(busy || syncing)
            }
        }
    }

    static func explanation(_ u: UniversityKey) -> String {
        let other = UniversityKey.allCases.first { $0 != u }?.profile.name ?? "anderen Hochschule"
        return "Auf diesem iPad werden für dein Konto alle Daten der \(u.profile.name) gelöscht: Kurse, Lernplan und Einstellungen, "
            + "heruntergeladene Dateien, eigene Dokumente und Notizen, Zwischenspeicher und die Anmeldung in der Webansicht"
            + (u.profile.tokenServices.isEmpty ? ". " : " samt Learnweb-Schlüssel. ")
            + "Die Daten der \(other) bleiben unberührt. Das lässt sich nicht rückgängig machen. "
            + "Zum Wechseln der Hochschule musst du nichts löschen."
    }
}
