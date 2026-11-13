import SwiftUI

/// Einstellungen → "Auf diesem iPad": Lage der Werkzeugleiste im Dokument (Auftrag des Inhabers 12.11.2026: "fest oben
/// oder unten, man kann aussuchen, oder weiterhin schwebend, in Einstellung"). Je Geraet gemerkt
/// (`EditorToolbarPlacement.key`), ein offenes Dokument folgt sofort. Am Mac ohne "Schwebend" (Apples Palette fehlt dort).
struct EditorToolbarPlacementRow: View {
    @AppStorage(EditorToolbarPlacement.key) private var raw = EditorToolbarPlacement.standard.rawValue

    static let title = "Werkzeugleiste"

    var body: some View {
        let choices = EditorToolbarPlacement.choices(isMac: PDFEditorController.isMac)
        let current = EditorToolbarPlacement.resolve(raw, isMac: PDFEditorController.isMac)
        SettingsRow(Self.title, icon: "pen", note: current.detail) {
            UFSegmented(options: choices.map { ($0.rawValue, $0.title) },
                        selection: Binding(get: { current.rawValue }, set: { raw = $0 }))
                .accessibilityIdentifier("settings.toolbarPlacement")
        }
    }
}
