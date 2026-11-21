import UIKit

// Geteilte Ansicht: Hauptdokument und Dokument daneben (z. B. die Notiz) teilen sich Leiste und Verlauf. Welcher der
// beiden Editoren gemeint ist, wenn ein Bild eingefuegt oder die Auswahl geloescht wird, entscheidet die letzte
// Beruehrung (`EditorToolState.activeEditor`).
//
// Meldung des Inhabers am iPad (21.11.2026): "Wenn man das Hauptdokument auf hat und daneben eine Notiz öffnet, was
// schreibt und ein Bild einfügen will, dann kann man das Bild nur aufs Hauptdokument packen […]. Auf die Notiz geht kein
// Bild drauf." Ursache: "Bild aus Fotos/Dateien" und "Einfügen" gingen immer an den Editor des Hauptdokuments, und das
// Dokument daneben hatte keinen Objektmodus (ein Bild liess sich dort weder auswaehlen noch verschieben).

/// Sieht jede Beruehrung eines Editors in dem Moment, in dem sie aufsetzt (Finger, Stift, Maus), und meldet sie. Erkennt
/// nie etwas, haelt keine Beruehrung zurueck und laesst sich nicht verdraengen (wie `InkTouchTracker`); nach der Meldung
/// ist er fuer diese Beruehrung fertig.
final class EditorTouchMarker: UIGestureRecognizer {
    var onTouch: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [UITouch.TouchType.direct, .indirect, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) }
    }

    convenience init() { self.init(target: nil, action: nil) }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch?()
        state = .failed
    }
}

extension PDFEditorController {
    /// Objektwerkzeuge, die auch im Dokument daneben greifen: Antippen und Lasso (auswaehlen, verschieben, Groesse
    /// aendern, loeschen). Text, Haftnotiz, Formen, "Text markieren" und "Bereich an KI" legen nur im Hauptdokument an.
    static let sideObjectTools: Set<ObjectEditing.Tool> = [.select, .lasso]

    /// Jede Beruehrung dieses Editors macht ihn zu dem, in dem gearbeitet wird
    func installActiveEditorMarker() {
        let marker = EditorTouchMarker()
        marker.onTouch = { [weak self] in self?.becomeActiveEditor() }
        pdfView.addGestureRecognizer(marker)
        tools.register(self)
        if ownsToolPicker, tools.activeEditor == nil { becomeActiveEditor() }
    }

    func becomeActiveEditor() { tools.setActiveEditor(self) }

    /// Der Editor, in dem zuletzt gearbeitet wurde, solange er zu sehen ist und beschrieben werden darf; sonst dieser
    /// (gefragt wird der Editor des Hauptdokuments: ist die Notiz daneben zu oder nie beruehrt, bleibt alles bei ihm).
    var activeEditor: PDFEditorController {
        if let a = tools.activeEditor, a !== self, a.viewIfLoaded?.window != nil, a.writable { return a }
        return self
    }

    /// Das Dokument daneben verschwindet: Bilder gehen wieder ins Hauptdokument. Hatte es noch eine Auswahl, erfaehrt
    /// die Objektleiste das einen Durchlauf spaeter - nicht mitten im Abbau der Ansicht, waehrend SwiftUI aktualisiert.
    func resignActiveEditor() {
        // Schritte "Bild ins andere Dokument" brauchen beide Dokumente: sie enden mit diesem
        for step in tools.transferSteps { editUndo.removeAllActions(withTarget: step) }
        tools.transferSteps = []
        guard tools.activeEditor === self else { return }
        guard objects.hasSelection else { tools.setActiveEditor(nil); return }
        let tools = tools
        DispatchQueue.main.async { [weak self] in
            if let self {
                if tools.activeEditor === self { tools.setActiveEditor(nil) }
            } else {
                tools.onActiveSelection?(0)
            }
        }
    }
}
