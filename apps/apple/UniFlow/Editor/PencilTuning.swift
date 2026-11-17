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
    /// Meldung des Inhabers 17.11.2026 ("ab und zu geht ein Strich ganz weg"): Jedes Absetzen gehoert zu SEINEM Strich
    /// (`PageInkView.lifts`), ersetzt wird nur, wenn kein weiterer Strich unterwegs ist, und solange ein abgesetzter
    /// Strich noch nicht gemeldet ist, wird die Seite nicht aus dem Speicher (neu) geladen: der Strich waere in dem
    /// geladenen Stand noch nicht enthalten. `false`: wie bis 17.11. - ein gemerktes Absetzen, Laden sofort
    /// (Gegenprobe im Test `EditorStrichBleibtTests`).
    static var liftBelongsToItsStroke = true
    /// Glaettung "Leicht"/"Aus" baut den Strich nach dem Absetzen aus den Messpunkten neu und setzt dafuer die Zeichnung
    /// neu - bei JEDEM Strich. Gemessen 17.11.2026 (`EditorStrichBleibtTests`): PencilKit verliert dann einen Strich,
    /// der wenige Millisekunden nach diesem Neu-Setzen beginnt (er wird gezeichnet, aber nie in die Zeichnung
    /// uebernommen: 7 bis 9 von 10 bei 8 ms Abstand), und kann danach ganz aufhoeren, Striche zu liefern. Das laesst
    /// sich nicht sicher verhindern (niemand weiss, wann der naechste Strich beginnt). Darum ist der Neubau AUS:
    /// Nach einem normalen Strich wird die Zeichnung in keiner Einstellung mehr neu gesetzt, die Einstellung
    /// "Glaettung" ist ausgeblendet. `true`: wie bis 17.11. (mit Deckbild und den Sicherungen dieses Tages), fuer die
    /// Gegenprobe im Test und falls der Inhaber die Glaettung trotz des Risikos zurueck will.
    static var rebuildFromRawPointsAfterLift = false
    /// So lange muss die Zeichenflaeche unberuehrt sein, bevor eine geladene Seite aus dem Speicher neu gesetzt wird
    /// (fremde Aenderung): nie mitten im Schreibfluss
    static let reloadQuietSeconds: CFTimeInterval = 1
}
