import SwiftUI
import UniFlowCore

/// Formeln in KI-Texten lesbar zeigen (04.11.2026, erweitert 07.11.2026): die Umformung macht `MathText` im Kern
/// (LaTeX und ASCII-Schreibweisen -> Unicode: x², 10⁻³, aₙ, √x, ∫, ε, ≤ …). Hoch- und Tiefstellungen, die Unicode
/// nicht kennt (Buchstaben, ∞, Integralgrenzen), zeigt `attributed` als echte kleine, hoch- bzw. tiefgestellte Schrift.
/// Nur fuer die Anzeige: gespeicherte Antworten und Tests bleiben, wie sie sind.
enum FormulaText {
    /// lesbarer Text ohne Markierungen (Vorschauen, reine Text-Ansichten)
    static func render(_ text: String) -> String { MathText.plain(text) }

    /// lesbarer Text mit echter Hoch-/Tiefstellung; `size` ist die Schriftgroesse des umgebenden Texts
    static func attributed(_ text: String, size: CGFloat, weight: CGFloat = 400) -> AttributedString {
        scripted(AttributedString(MathText.render(text)), size: size, weight: weight)
    }

    /// Markierungen von `MathText.render` in einem schon gebauten AttributedString (z. B. aus Markdown) in
    /// Hoch-/Tiefstellung wandeln; ohne Markierung bleibt der Text, wie er ist
    static func scripted(_ input: AttributedString, size: CGFloat, weight: CGFloat = 400) -> AttributedString {
        var a = input
        let chars = String(a.characters)
        guard chars.contains(MathText.supOpen) || chars.contains(MathText.subOpen) else { return a }
        let small = Font(UFTypeface.font(max(9, size * 0.72), max(weight, 500)))
        var guardCount = 0
        while guardCount < 200 {
            guardCount += 1
            let sup = a.characters.firstIndex(of: MathText.supOpen)
            let sub = a.characters.firstIndex(of: MathText.subOpen)
            guard let open = [sup, sub].compactMap({ $0 }).min() else { break }
            let isSup = open == sup
            let afterOpen = a.characters.index(after: open)
            guard let close = a.characters[afterOpen...].firstIndex(of: MathText.close) else {
                a.removeSubrange(open..<afterOpen)                       // offene Markierung: nur das Zeichen weg
                continue
            }
            var inner = AttributedString(a[afterOpen..<close])
            // innere Markierungen (sollte es nicht geben) entfernen
            for m in [MathText.supOpen, MathText.subOpen] {
                while let k = inner.characters.firstIndex(of: m) { inner.removeSubrange(k..<inner.characters.index(after: k)) }
            }
            inner.font = small
            inner.baselineOffset = isSup ? size * 0.36 : -size * 0.16
            a.replaceSubrange(open..<a.characters.index(after: close), with: inner)
        }
        // uebrig gebliebene Endmarkierungen weg
        while let k = a.characters.firstIndex(of: MathText.close) { a.removeSubrange(k..<a.characters.index(after: k)) }
        return a
    }
}
