import SwiftUI
import UniFlowCore

// "Daten zurückholen" (24.11.2026, `DeletedDataHold`): Nach "Konto löschen" ohne "Auch sofort endgültig löschen"
// liegen Dateien, Dokumente, Notizen und Einstellungen 30 Tage in einem geschuetzten Bereich des Geraets. Meldet sich
// dieselbe Apple-ID wieder an, fragt die App einmal (`HeldDataQuestionHost`); danach steht es unter Einstellungen →
// Konto (`HeldDataSection`). Endgueltig loeschen und zurueckholen nur nach Face ID / Geraetecode (`DeleteAccountGate`).

enum HeldDataText {
    static let title = "Gelöschte Daten zurückholen?"

    static func date(_ d: Date?) -> String {
        guard let d else { return "–" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: d)
    }

    /// Erklaerung im Dialog und in den Einstellungen
    static func explanation(deletedAt: Date?, expiresAt: Date?) -> String {
        UFDevice.adapt("Am \(date(deletedAt)) wurde auf diesem iPad „Konto löschen“ ausgeführt. Deine Dateien, eigenen Dokumente, Notizen und Einstellungen von damals bewahrt StudiNow bis \(date(expiresAt)) auf; danach sind sie endgültig gelöscht. Zurückholen bringt sie wieder an ihren Platz. Uni-Anmeldungen und gespeicherte Passwörter wurden sofort gelöscht – die gibst du neu ein. Das StudiNow-Konto beim Dienst bleibt gelöscht; was dort abgeglichen war, kommt dadurch nicht zurück.")
    }

    static let restore = "Daten zurückholen"
    static let discard = "Endgültig löschen"
    static let later = "Später"
    static let restored = "Deine Daten sind wieder da."
    static let discarded = "Die aufbewahrten Daten sind endgültig gelöscht."

    /// Merker "einmal gefragt" je Eintrag (der Ordnername enthaelt nur die Kurzkennung, nie die Apple-ID)
    static func offeredKey(_ hold: DeletedDataHold) -> String { "uniflow.heldData.offered." + hold.folder.lastPathComponent }
}

/// Rueckfrage "Gelöschte Daten zurückholen?" mit Bestaetigung durch die Besitzerin oder den Besitzer
struct RestoreHeldDataDialog: View {
    let hold: DeletedDataHold
    let userID: String
    @EnvironmentObject private var containers: ContainerManager
    @Environment(\.ufClose) private var close
    @State private var busy = false
    @State private var gate = DeleteAccountGate()
    @State private var typed = ""
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        UFDialog(HeldDataText.title, icon: "arrow.uturn.backward") {
            VStack(alignment: .leading, spacing: 9.6) {
                Text(HeldDataText.explanation(deletedAt: hold.deletedAt, expiresAt: hold.expiresAt))
                if gate.needsTypedConfirmation && !gate.ownerConfirmed {
                    UFField(DeleteAccountText.typedConfirmationLabel) {
                        UFTextField(DeleteAccountGate.typedWord, text: $typed)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                }
                if let m = gate.message ?? result {
                    Text(m).ufFont(13.12, 600).foregroundStyle(failed || gate.message != nil ? UF.bad : UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("heldData.message")
                }
            }
            .ufFont(13.12).foregroundStyle(UF.text2)
            .fixedSize(horizontal: false, vertical: true)
        } foot: {
            UFButton(result == nil || failed ? HeldDataText.later : "Schließen") { close() }
            if result == nil || failed {
                UFButton(HeldDataText.discard, kind: .ghost) { run(restore: false) }.disabled(busy)
                UFButton(HeldDataText.restore, icon: "arrow.uturn.backward", kind: .primary) { run(restore: true) }.disabled(busy)
                    .accessibilityIdentifier("heldData.restore")
            }
        }
    }

    private func run(restore: Bool) {
        busy = true
        Task {
            var g = gate
            let step = await g.tap(typed: typed)
            gate = g
            guard step == .proceed else { busy = false; return }
            let problem = restore ? await containers.restoreHeldData(userID: userID) : containers.discardHeldData(userID: userID)
            failed = problem != nil
            result = problem ?? (restore ? HeldDataText.restored : HeldDataText.discarded)
            busy = false
        }
    }
}

/// Einstellungen → Konto: solange Daten aufbewahrt werden
struct HeldDataSection: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var overlay: UFOverlay

    var body: some View {
        let _ = containers.heldDataChanges
        if let userID = account.account?.userID, let hold = containers.heldData(userID: userID).first {
            VStack(alignment: .leading, spacing: 7.2) {
                SettingsDivider().padding(.vertical, 6)
                Text("Gelöschte Daten").ufFont(14.5, 650).foregroundStyle(UF.text)
                Text(HeldDataText.explanation(deletedAt: hold.deletedAt, expiresAt: hold.expiresAt))
                    .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                UFButton(HeldDataText.restore + " …", icon: "arrow.uturn.backward", size: .small) {
                    overlay.modal { RestoreHeldDataDialog(hold: hold, userID: userID) }
                }
                .accessibilityIdentifier("settings.heldData")
            }
        }
    }
}

/// Einmal je Eintrag von selbst fragen, sobald das Konto eingerichtet und ein Container offen ist; nie ueber einem
/// anderen Dialog, nie beim Schreiben, nicht unter XCTest
struct HeldDataQuestionHost: ViewModifier {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var overlay: UFOverlay

    func body(content: Content) -> some View {
        content.task(id: containers.generation) { await check() }
    }

    private func check() async {
        guard !StudIPSync.isUnderTest(), account.stage == .ready, containers.active != nil,
              let userID = account.account?.userID, let hold = containers.heldData(userID: userID).first else { return }
        let key = HeldDataText.offeredKey(hold)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled, overlay.modals.isEmpty, !OpenDocuments.shared.writing else { return }
        UserDefaults.standard.set(true, forKey: key)
        _ = overlay.modal { RestoreHeldDataDialog(hold: hold, userID: userID) }
    }
}
