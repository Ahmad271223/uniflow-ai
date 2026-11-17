import Foundation

/// Schriftbild zum Vergleichen (16./17.11.2026) - ERLEDIGT, bleibt nur als leere Huelle.
///
/// Die beiden versteckten Testvarianten sind seit 17.11.2026 fester Bestandteil der Werkzeugleiste und brauchen keine
/// Auswahl mehr (Auftrag des Inhabers: "Schrift wirklich dünner und feiner machen und auch diese Füller-Schriftart
/// hinzufügen"):
/// - "Feiner Fineliner": die Stufen 0,25 und 0,35 gehoeren zum Fineliner (`EditorToolState.Tool.widths`).
/// - "Stift als Füller": Es gibt das eigene Werkzeug "Füller" (`EditorToolState.Tool.fountain`); der Stift bleibt Stift.
///
/// Diese Huelle gibt es nur noch, weil die Zeile "Schriftbild (Test)" in `Views/Settings/PencilFeelSettingsRows.swift`
/// sie nennt und die Einstellungen am 17.11. gleichzeitig von anderer Stelle bearbeitet wurden. Die Zeile erscheint
/// nie (`visible` ist immer false); sie und diese Datei koennen zusammen entfernt werden. Ein frueher gemerkter Wert
/// unter `key` wird nicht mehr gelesen.
enum PencilLab: String {
    case standard

    static let key = "uniflow.stiftLabor"
    static let changed = Notification.Name("uniflow.stiftLabor.geaendert")
    static let visible = false
    static let title = "Schriftbild (Test)"
    static let options: [(value: String, label: String)] = [("standard", "Wie bisher")]
    static let note = ""
}
