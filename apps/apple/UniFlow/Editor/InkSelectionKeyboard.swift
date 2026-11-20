import ObjectiveC
import PencilKit
import UIKit

/// Lasso-Auswahl von PencilKit ohne Bildschirmtastatur (Meldung des Inhabers 20.11.2026: "Wenn man etwas umkreist und
/// verschieben will oder das Umkreiste kopiert und woanders einfuegt, haengt es kurz, und unten kommt ein halber
/// Bildschirm, irgendein blaeuliches Fenster auf - ab und zu").
///
/// Nach dem Einkreisen nimmt die Auswahl von PencilKit den Fokus (damit Kopieren, Einfuegen, Loeschen sie erreichen).
/// Diese Auswahl ist seit Apples Schreibwerkzeugen ein Texteingabefeld (`UITextInput`) ohne eigene Eingabeansicht:
/// iPadOS blendet deshalb die Bildschirmtastatur ein, sobald die Beruehrung nicht vom Pencil kam (Auswahl mit dem Finger
/// ziehen, "Einfügen" im Menue antippen) - das "blaeuliche Fenster", und waehrend sie hochfaehrt, steht die App kurz.
/// Bis 11.11.2026 hing Apples Werkzeugpalette an der Zeichenflaeche und nahm der Tastatur den Platz; die feste Leiste
/// tut das nicht.
///
/// Abhilfe: Die Auswahl bekommt eine leere Eingabeansicht. Dann zeigt iPadOS keine Bildschirmtastatur; Kopieren,
/// Einfuegen, Loeschen, Verschieben und eine angeschlossene Tastatur (Entf loescht die Auswahl) bleiben, wie sie sind.
/// Hat Apple der Auswahl selbst eine Eingabeansicht gegeben, bleibt deren.
@MainActor
enum InkSelectionKeyboard {
    /// Leere Eingabeansicht (eine fuer alle: es hat immer nur ein Element den Fokus). UIKit fragt nur auf dem
    /// Hauptthread danach.
    nonisolated(unsafe) static let emptyInputView: UIView = {
        let v = UIView(frame: .zero)
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }()

    /// Klassen, die schon eine Eingabeansicht bekommen haben
    private static var done = Set<ObjectIdentifier>()

    /// Name der Auswahl in PencilKit (iPadOS 18 bis 27). Fehlt die Klasse, greift `suppress(for:)` beim ersten Mal.
    static let selectionClassName = "PKSelectionView"

    /// Beim Aufbau des Editors: die Auswahl von PencilKit vorab ohne Tastatur
    static func install() {
        guard let cls = NSClassFromString(selectionClassName), cls is UIView.Type else { return }
        give(cls)
    }

    /// Fokus in einer Zeichenflaeche, der Text annimmt, aber keine Eingabeansicht hat (die Auswahl von PencilKit, auch
    /// wenn sie in einer neuen iPadOS-Fassung anders heisst): seine Klasse bekommt die leere Eingabeansicht und die
    /// schon erscheinende Tastatur geht gleich wieder. `true`, wenn etwas geaendert wurde.
    @discardableResult
    static func suppress(for responder: UIResponder?) -> Bool {
        guard let r = responder, needsSuppression(r) else { return false }
        guard give(type(of: r)) else { return false }
        r.reloadInputViews()
        return true
    }

    /// Nimmt Text an, hat keine Eingabeansicht und steckt in einer Zeichenflaeche (keine Textfelder unserer Objekte)
    static func needsSuppression(_ r: UIResponder) -> Bool {
        guard r is UIKeyInput, !(r is UITextView), !(r is UITextField), r.inputView == nil, let v = r as? UIView else { return false }
        var cur: UIView? = v.superview
        while let c = cur {
            if c is PKCanvasView { return true }
            cur = c.superview
        }
        return false
    }

    /// Eingabeansicht fuer alle Elemente der Klasse `cls`; nur, wenn die Klasse selbst keine hat (`class_addMethod`
    /// aendert nie eine vorhandene Umsetzung)
    @discardableResult
    private static func give(_ cls: AnyClass) -> Bool {
        let id = ObjectIdentifier(cls)
        guard !done.contains(id) else { return false }
        done.insert(id)
        let block: @convention(block) (AnyObject) -> UIView? = { me in
            guard PencilTuning.inkSelectionWithoutKeyboard else { return nil }      // Gegenprobe: wie bis 1.0.7
            // auch keine Leiste ueber der (leeren) Eingabeansicht: Kurzbefehle (Rueckgaengig, Einsetzen) weg
            if let item = (me as? UIResponder)?.inputAssistantItem, !item.leadingBarButtonGroups.isEmpty || !item.trailingBarButtonGroups.isEmpty {
                item.leadingBarButtonGroups = []
                item.trailingBarButtonGroups = []
            }
            return InkSelectionKeyboard.emptyInputView
        }
        return class_addMethod(cls, #selector(getter: UIResponder.inputView), imp_implementationWithBlock(block), "@@:")
    }
}
