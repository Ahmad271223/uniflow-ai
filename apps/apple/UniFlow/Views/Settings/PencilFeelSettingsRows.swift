import SwiftUI

/// Stift-Einstellungen "Glättung" und "Formen erkennen" (Wunsch des Inhabers 13.11.2026), je Geraet. Eigener kleiner
/// Typ, damit die Einstellungsseite nicht tiefer wird (`ViewTypeDepthAppTests`).
struct PencilFeelSettingsRows: View {
    @AppStorage(PencilSmoothing.key) private var smoothing = PencilSmoothing.standard.rawValue
    @AppStorage(ShapeSnapSetting.key) private var shapes = true

    var body: some View {
        SettingsRow(PencilSmoothing.title, icon: "pen", note: PencilSmoothing.note) {
            UFSegmented(options: PencilSmoothing.options, selection: $smoothing)
                .accessibilityIdentifier("settings.pencilSmoothing")
        }
        SettingsDivider()
        SettingsRow(ShapeSnapSetting.title, icon: "square", note: ShapeSnapSetting.note) {
            Toggle(isOn: $shapes) { Text(shapes ? "An" : "Aus").ufFont(13.12).foregroundStyle(UF.muted) }
                .tint(UF.accent)
                .fixedSize()
                .accessibilityLabel(ShapeSnapSetting.title)
                .accessibilityIdentifier("settings.shapeSnap")
        }
    }
}
