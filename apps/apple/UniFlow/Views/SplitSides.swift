import CoreGraphics
import Foundation

/// Schreibhand und geteilte Ansicht ("Daneben öffnen"): welche Seite die Spalte daneben bekommt, und das Tauschen der
/// Seiten an der Kopfzeile (UniFlowTests/SplitSidesAppTests.swift).
///
/// Einstellung "Schreibhand" (`uniflow.hand`, "right" | "left", Standard "right"): "Seitenleiste und Skript in der
/// geteilten Ansicht liegen auf der Seite der freien Hand".
enum SplitSides {
    /// Schluessel der getauschten Paare (Hauptdokument|Spalte daneben, durch Zeilenumbruch getrennt)
    static let swappedKey = "uniflow.splitSwapped"
    /// so viele getauschte Paare bleiben gemerkt (die aeltesten fallen heraus)
    static let maxSwapped = 100

    /// Seite der freien Hand: Rechtshaender links, Linkshaender rechts; ein unbekannter Wert gilt wie der Standard
    static func freeHandLeft(hand: String) -> Bool { hand != "left" }

    /// Was in der Spalte daneben liegt
    enum Role: Equatable {
        /// zum Lesen (Skript, Loesung): Seite der freien Hand
        case reference
        /// zum Schreiben (leeres Blatt, Uebungsblatt neben der Folie): Seite der Schreibhand
        case writing
    }

    /// Uebungsblatt, Loesung oder Klausur (wie `isExercise` in views-doc.js)
    static func isExercise(_ f: LibFile) -> Bool {
        if ["uebung", "loesung", "klausur"].contains(f.doc_type ?? "") { return true }
        let text = (f.name + " " + (f.studip_folder ?? "")).lowercased()
        return ["übung", "uebung", "blatt", "aufgabe"].contains { text.contains($0) }
    }

    /// Rolle der Spalte daneben; `side` nil = Loesung zum Ansehen
    static func role(side: LibFile?, primary: LibFile) -> Role {
        .reference
    }

    /// Spalte daneben links (true) oder rechts; `swapped` = an der Kopfzeile getauscht
    static func sidePaneLeft(hand: String, role: Role, swapped: Bool = false) -> Bool {
        let free = freeHandLeft(hand: hand)
        let left = role == .reference ? free : !free
        return swapped ? !left : left
    }

    // MARK: Seiten tauschen

    /// Kennung des Paars; `side` = Datei daneben oder "loesung:<id>"
    static func pairKey(primary: String, side: String) -> String { primary + "|" + side }

    static func isSwapped(_ stored: String, key: String) -> Bool {
        stored.split(separator: "\n").contains { $0 == key }
    }

    /// gemerkte Paare nach einem Tausch (getauscht -> zurueck, sonst neu ans Ende)
    static func toggling(_ stored: String, key: String) -> String {
        var keys = stored.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if let i = keys.firstIndex(of: key) { keys.remove(at: i) } else { keys.append(key) }
        return keys.suffix(maxSwapped).joined(separator: "\n")
    }

    /// Loslassen beim Ziehen an der Kopfzeile: nur ueber der anderen Haelfte wird getauscht
    static func dropSwaps(sidePaneLeft: Bool, x: CGFloat, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        return sidePaneLeft ? x > width / 2 : x < width / 2
    }

    /// Text unter "Lösung daneben ansehen" (die Loesung liegt auf der Seite der freien Hand)
    static func solutionHint(hand: String) -> String {
        "Links deine Folie, rechts die Lösung auf derselben Seite."
    }
}
