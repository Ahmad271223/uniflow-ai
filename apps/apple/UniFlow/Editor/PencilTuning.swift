import Foundation

/// Schreibgefuehl mit dem Apple Pencil (Auftrag des Inhabers 13.11.2026, Messung in `PencilFeelTests`). Jeder Schalter
/// steht auf der neuen Fassung; `false` ist die Gegenprobe "so war es vorher" fuer die Messung im selben Testlauf.
enum PencilTuning {
    /// Radierer und Lasso melden waehrend der Bewegung jede geloeschte bzw. verschobene Stelle. Vorher sicherte jede
    /// Meldung die ganze Seite (umrechnen und auf die Platte, Hauptthread) - auf vollen Seiten ruckelte das Radieren.
    /// Jetzt einmal beim Absetzen (`canvasViewDidEndUsingTool`), wie beim Stift. Die Sicherung sofort beim Absetzen
    /// (Audit P60/P61: Strich uebersteht einen Abbruch 0 ms danach) bleibt unveraendert.
    static var saveOnLift = true
    /// Nach einem Zoom nur die sichtbaren Seiten in der neuen Schaerfe anlegen. Vorher auch die geparkten (bis 6
    /// unsichtbare Seiten, gezoomt bis ~130 MB je Seite); sie bekommen den Zoom ohnehin beim Wiederanzeigen.
    static var rescaleVisibleOnly = true
    /// Zoom-Anzeige ("100 %") und gemerkte Stelle hoechstens alle `zoomPublishInterval` Sekunden melden (plus ein
    /// letztes Mal am Ende). Vorher bei jedem Bild des Pinchens: jedes Mal rechnete SwiftUI die ganze Dokumentansicht neu.
    static var throttleZoomPublish = true
    static let zoomPublishInterval: TimeInterval = 0.12
    /// Meldung des Inhabers 16.11.2026 ("beim Absetzen geht der Strich kurz weg"): Wird der eben beendete Strich
    /// ersetzt (erkannte Form, Glaettung "Leicht"/"Aus"), setzt der Editor die ganze Zeichnung neu, und PencilKit
    /// zeichnet alles neu - bis dahin fehlte die Tinte. Jetzt liegt solange ein Deckbild darueber
    /// (`PageInkView.replaceLastStroke`). `false`: ohne Deckbild, wie bis 17.11.
    static var coverWhenStrokeIsReplaced = true
}
