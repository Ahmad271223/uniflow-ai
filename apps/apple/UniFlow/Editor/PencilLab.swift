import Foundation
import PencilKit

/// Schriftbild zum Vergleichen am echten iPad (Wunsch des Inhabers 16.11.2026: "Striche noch duenner", "Schreibstil
/// wie bei Notability und GoodNotes"). Drei Varianten, zwischen denen man in den Einstellungen umschaltet. Jede wirkt
/// schon WAEHREND des Schreibens (PencilKit zeichnet so) - nichts wird nach dem Absetzen ersetzt, darum kann dabei
/// auch nichts flackern. Vorhandene Notizen aendern sich nicht: Jeder Strich behaelt die Tinte, mit der er
/// geschrieben wurde.
///
/// Gemessen im Simulator (`EditorStrichBleibtTests.testMessungWieDuennPencilKitSchreibt`, gleichmaessiger Druck):
/// - Stift (Tinte "pen") auf der duennsten Stufe 0,88: gezeichnet 2,2 pt dick; duenner nimmt PencilKit nicht an
///   (verlangt 0,40 -> es bleibt 0,88). Mit dem Apple Pencil schwankt die Dicke mit dem Druck.
/// - Fineliner (Tinte "monoline") auf 0,50: gezeichnet 1,0 pt, gleichmaessig. Verlangt man 0,25, nimmt PencilKit das
///   an und zeichnet 0,5 pt - halb so dick, obwohl 0,50 als Untergrenze gemeldet wird (`validWidthRange`).
/// - Fueller (Tinte "fountainPen") auf 1,50: gezeichnet 0,5 pt, mit Druck und Neigung an- und abschwellend.
///
/// Die Auswahl ist nur zu sehen, wenn sie freigeschaltet ist (`visible`): Start der App mit dem Zusatz
/// `-uniflow.stiftLabor.sichtbar YES` (einmal genuegt, es wird gemerkt). Ohne Freischaltung und ohne Auswahl gilt
/// "Wie bisher" - fuer alle Nutzer aendert sich nichts.
enum PencilLab: String, CaseIterable {
    /// Wie bisher: Stift mit Kugelschreiber-Tinte ab 0,88, Fineliner ab 0,50
    case standard
    /// Der Fineliner bekommt zwei duennere Stufen (0,25 und 0,35) und sein Schieber reicht bis 0,25
    case fine = "fein"
    /// Das Werkzeug "Stift" schreibt mit Fueller-Tinte (duenner Grundstrich, schwillt mit Druck an)
    case fountain = "fueller"

    static let key = "uniflow.stiftLabor"
    static let visibleKey = "uniflow.stiftLabor.sichtbar"
    /// Auswahl geaendert: offene Editoren setzen das Werkzeug ihrer Zeichenflaechen neu (`EditorToolState`)
    static let changed = Notification.Name("uniflow.stiftLabor.geaendert")

    static var current: PencilLab {
        UserDefaults.standard.string(forKey: key).flatMap(PencilLab.init(rawValue:)) ?? .standard
    }

    /// Ist die Auswahl in den Einstellungen zu sehen? Beim Start mit `-uniflow.stiftLabor.sichtbar YES` ja, und ab da
    /// immer (der Startzusatz allein gaelte nur fuer diesen einen Start).
    static var visible: Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: visibleKey) else { return false }
        if d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[visibleKey] == nil { d.set(true, forKey: visibleKey) }
        return true
    }

    static let title = "Schriftbild (Test)"
    static let options: [(value: String, label: String)] = [("standard", "Wie bisher"), ("fein", "Feiner Fineliner"), ("fueller", "Stift als Füller")]
    static let note = "Zum Vergleichen. Feiner Fineliner: zwei dünnere Stufen beim Fineliner (ganz links), gleichmäßig dünn. "
        + "Stift als Füller: Der Stift schreibt mit Füller-Tinte, dünner Grundstrich, mit Druck kräftiger. "
        + "Gilt für neue Striche; was schon geschrieben ist, bleibt wie es ist."

    /// Stufen des Fineliners unterhalb der gemeldeten Untergrenze von PencilKit (nur Variante "fein")
    static let fineSteps: [CGFloat] = [0.25, 0.35]
    /// duennste Breite, die der Editor in der Variante "fein" vom Fineliner verlangt
    static let fineMinimum: CGFloat = 0.25

    /// Untergrenze der Breite fuer eine Tinte: die von PencilKit, in der Variante "fein" beim Fineliner darunter
    static func lowerBound(for ink: PKInkingTool.InkType) -> CGFloat {
        let limit = ink.validWidthRange.lowerBound
        return ink == .monoline && current == .fine ? min(limit, fineMinimum) : limit
    }
}
