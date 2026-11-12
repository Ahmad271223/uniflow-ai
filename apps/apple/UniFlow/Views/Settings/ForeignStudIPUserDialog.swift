import SwiftUI
import UniFlowCore

/// Datentrennung je Stud.IP-Benutzer (12.11.2026, Entscheidung "fragen, dann neu beginnen", `StudIPUserMark`): meldet
/// sich im Datenbereich einer Hochschule ein anderer Stud.IP-Benutzer an als bisher, haelt der Abgleich an, bevor er
/// etwas schreibt (`StudIPSync.foreignUser`), und dieser Dialog fragt. "Neu beginnen" nutzt den vorhandenen Weg "Daten
/// dieser Hochschule löschen" und gleicht danach fuer den neuen Benutzer ab (`ContainerManager.restartForNewStudIPUser`);
/// "Abbrechen" meldet den neuen Benutzer ab, damit sich der bisherige wieder anmelden kann.
enum ForeignStudIPUserText {
    static let title = "Anderer Stud.IP-Benutzer"
    static func text(_ university: UniversityKey?) -> String {
        let name = university.map { "der \($0.profile.name)" } ?? "dieser Hochschule"
        return UFDevice.adapt("Bei Stud.IP ist gerade ein anderer Benutzer angemeldet als der, dessen Daten \(name) auf diesem iPad liegen. Damit sich die Daten zweier Personen nicht mischen, hat StudiNow den Abgleich angehalten und nichts gespeichert.")
    }
    static let restart = "Bisherige Daten löschen und neu beginnen"
    static let restartNote = UFDevice.adapt("„Neu beginnen“ löscht alle Daten dieser Hochschule auf diesem iPad (Kurse, Dateien, Notizen, Lernplan) und gleicht danach für den neuen Benutzer ab. Das lässt sich nicht rückgängig machen.")
    static let cancel = "Abbrechen"
    static let cancelNote = "„Abbrechen“ meldet den neuen Benutzer ab. Melde dich danach wieder mit dem bisherigen Stud.IP-Benutzer an."
}

/// Unsichtbar an der Wurzel (RootView): oeffnet den Dialog, sobald der Abgleich einen anderen Benutzer meldet
struct ForeignStudIPUserGate: View {
    @EnvironmentObject private var studip: StudIPSync
    @EnvironmentObject private var overlay: UFOverlay

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: studip.foreignUser, initial: true) { _, on in
                if on { _ = overlay.modal { ForeignStudIPUserDialog() } }
            }
    }
}

/// Die Frage selbst (eigener kleiner Ansichtstyp, `ViewTypeDepthAppTests`)
struct ForeignStudIPUserDialog: View {
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var busy = false

    var body: some View {
        UFDialog(ForeignStudIPUserText.title, icon: "alert") {
            VStack(alignment: .leading, spacing: 9.6) {
                Text(ForeignStudIPUserText.text(containers.key?.university))
                Text(ForeignStudIPUserText.restartNote).foregroundStyle(UF.bad)
                Text(ForeignStudIPUserText.cancelNote)
            }
            .ufFont(13.12).foregroundStyle(UF.text2)
            .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton(ForeignStudIPUserText.cancel) {
                busy = true
                Task {
                    await containers.studip.signOut()
                    close()
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("foreignUser.cancel")
            UFButton(ForeignStudIPUserText.restart, icon: "trash", kind: .danger) {
                busy = true
                Task {
                    let problem = await containers.restartForNewStudIPUser()
                    close()
                    if let problem { toast.show(problem, seconds: 6) }
                }
            }
            .disabled(busy)
            .accessibilityIdentifier("foreignUser.restart")
        }
    }
}
