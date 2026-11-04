import Foundation

/// Formeln in Aufgabentexten lesbar machen (04.11.2026), ohne Web-Ansicht: der Prompt verlangt "LaTeX-frei, Formeln
/// als Text", die KI liefert trotzdem mal `$x^2$` oder `\frac{1}{2}`. Reine Textumformung auf Unicode (Hoch- und
/// Tiefstellung, Wurzel, Brueche als a/b, griechische Buchstaben, Vergleichs- und Mengenzeichen); was nicht sicher
/// abbildbar ist, bleibt wie es ist. Keine Darstellung als gesetzte Formel, nur ein lesbarer Text.
enum FormulaText {
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "n": "ⁿ", "i": "ⁱ", "(": "⁽", ")": "⁾", "k": "ᵏ", "m": "ᵐ", "x": "ˣ", "t": "ᵗ",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "n": "ₙ", "i": "ᵢ", "k": "ₖ", "m": "ₘ", "x": "ₓ", "j": "ⱼ", "(": "₍", ")": "₎",
    ]
    /// `\name` -> Zeichen (laengere Namen zuerst, damit `\leq` nicht als `\le` + "q" endet)
    private static let commands: [(String, String)] = [
        ("\\leqslant", "≤"), ("\\geqslant", "≥"), ("\\rightarrow", "→"), ("\\leftarrow", "←"), ("\\Rightarrow", "⇒"),
        ("\\Leftrightarrow", "⇔"), ("\\leftrightarrow", "↔"), ("\\left", ""), ("\\right", ""), ("\\lnot", "¬"), ("\\neg", "¬"),
        ("\\varepsilon", "ε"), ("\\varphi", "φ"), ("\\subseteq", "⊆"),
        ("\\supseteq", "⊇"), ("\\emptyset", "∅"), ("\\partial", "∂"), ("\\nabla", "∇"), ("\\approx", "≈"), ("\\lambda", "λ"),
        ("\\Lambda", "Λ"), ("\\infty", "∞"), ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\Gamma", "Γ"),
        ("\\delta", "δ"), ("\\Delta", "Δ"), ("\\epsilon", "ε"), ("\\theta", "θ"), ("\\Theta", "Θ"), ("\\kappa", "κ"),
        ("\\sigma", "σ"), ("\\Sigma", "Σ"), ("\\omega", "ω"), ("\\Omega", "Ω"), ("\\ldots", "…"), ("\\cdots", "⋯"),
        ("\\dots", "…"), ("\\cdot", "·"), ("\\times", "×"), ("\\equiv", "≡"), ("\\notin", "∉"), ("\\subset", "⊂"),
        ("\\supset", "⊃"), ("\\forall", "∀"), ("\\exists", "∃"), ("\\prod", "∏"), ("\\sum", "Σ"), ("\\int", "∫"),
        ("\\neq", "≠"), ("\\leq", "≤"), ("\\geq", "≥"), ("\\lim", "lim"), ("\\log", "log"), ("\\sin", "sin"), ("\\cos", "cos"),
        ("\\tan", "tan"), ("\\exp", "exp"), ("\\max", "max"), ("\\min", "min"), ("\\mu", "μ"), ("\\pi", "π"), ("\\phi", "φ"),
        ("\\rho", "ρ"), ("\\tau", "τ"), ("\\eta", "η"), ("\\xi", "ξ"), ("\\psi", "ψ"), ("\\chi", "χ"), ("\\nu", "ν"),
        ("\\ne", "≠"), ("\\le", "≤"), ("\\ge", "≥"), ("\\to", "→"), ("\\pm", "±"), ("\\in", "∈"), ("\\cup", "∪"),
        ("\\cap", "∩"), ("\\land", "∧"), ("\\lor", "∨"), ("\\mid", "|"), ("\\quad", "  "),
        ("\\,", " "), ("\\;", " "), ("\\!", ""), ("\\ ", " "),
    ]
    private static let sets: [String: String] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ"]

    /// Text mit Formeln -> lesbarer Text; nichts geht verloren, nur die Schreibweise aendert sich
    static func render(_ text: String) -> String {
        guard text.contains("\\") || text.contains("^") || text.contains("_") || text.contains("$") || text.contains("sqrt(") else { return text }
        var s = text
        // Formelgrenzen weg
        for d in ["\\(", "\\)", "\\[", "\\]", "$$", "$"] { s = s.replacingOccurrences(of: d, with: "") }
        s = braces(s, command: "\\frac", apply: { a, b in "\(wrap(a))/\(wrap(b))" })
        s = braces(s, command: "\\dfrac", apply: { a, b in "\(wrap(a))/\(wrap(b))" })
        s = single(s, command: "\\sqrt", apply: { "√(\($0))" })
        s = single(s, command: "\\text", apply: { $0 })
        s = single(s, command: "\\mathrm", apply: { $0 })
        s = single(s, command: "\\mathbf", apply: { $0 })
        s = single(s, command: "\\mathbb", apply: { sets[$0] ?? $0 })
        s = single(s, command: "\\overline", apply: { "‾\($0)‾" })
        s = single(s, command: "\\vec", apply: { "\($0)⃗" })
        for (c, r) in commands { s = s.replacingOccurrences(of: c, with: r) }
        s = s.replacingOccurrences(of: "sqrt(", with: "√(")
        s = scripts(s, marker: "_", table: subscripts)                  // erst der Index, dann der Exponent (a_n^2)
        s = scripts(s, marker: "^", table: superscripts)
        return s
    }

    /// `(a+b)` bleibt, ein einzelnes Zeichen oder Wort bleibt, sonst Klammern fuer einen Bruch
    private static func wrap(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count <= 1 || t.allSatisfy({ $0.isLetter || $0.isNumber }) || (t.hasPrefix("(") && t.hasSuffix(")")) { return t }
        return "(\(t))"
    }

    /// `\cmd{a}{b}` -> apply(a, b); ohne beide Gruppen bleibt der Text
    private static func braces(_ s: String, command: String, apply: (String, String) -> String) -> String {
        var out = s
        while let r = out.range(of: command + "{") {
            guard let a = group(out, from: r.upperBound), out[a.end...].hasPrefix("{"),
                  let b = group(out, from: out.index(after: a.end)) else { break }
            out.replaceSubrange(r.lowerBound..<b.end, with: apply(render(a.text), render(b.text)))
        }
        return out
    }

    /// `\cmd{a}` -> apply(a); `\cmd x` (ein Zeichen) ebenso
    private static func single(_ s: String, command: String, apply: (String) -> String) -> String {
        var out = s
        var from = out.startIndex
        while let r = out.range(of: command, range: from..<out.endIndex) {
            if out[r.upperBound...].hasPrefix("{"), let g = group(out, from: out.index(after: r.upperBound)) {
                let repl = apply(render(g.text))
                out.replaceSubrange(r.lowerBound..<g.end, with: repl)
                from = out.index(r.lowerBound, offsetBy: repl.count)
            } else if r.upperBound < out.endIndex, out[r.upperBound] == " ", out.index(after: r.upperBound) < out.endIndex {
                let c = out.index(after: r.upperBound)
                let repl = apply(String(out[c]))
                out.replaceSubrange(r.lowerBound...c, with: repl)
                from = out.index(r.lowerBound, offsetBy: repl.count)
            } else {
                from = r.upperBound
            }
        }
        return out
    }

    /// Inhalt einer geschweiften Gruppe ab `start` (direkt hinter `{`), mit Verschachtelung
    private static func group(_ s: String, from start: String.Index) -> (text: String, end: String.Index)? {
        var depth = 1
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if c == "{" { depth += 1 } else if c == "}" {
                depth -= 1
                if depth == 0 { return (String(s[start..<i]), s.index(after: i)) }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// `x^2`, `x^{10}`, `a_n`, `a_{i+1}` -> Hoch-/Tiefstellung, wenn jedes Zeichen abbildbar ist; sonst bleibt es
    private static func scripts(_ s: String, marker: Character, table: [Character: Character]) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == marker, i > s.startIndex, s.index(after: i) < s.endIndex else { out.append(c); i = s.index(after: i); continue }
            let prev = s[s.index(before: i)]
            guard prev.isLetter || prev.isNumber || prev == ")" || prev == "]" else { out.append(c); i = s.index(after: i); continue }
            let next = s.index(after: i)
            var body: String
            var end: String.Index
            if s[next] == "{", let g = group(s, from: s.index(after: next)) {
                body = g.text; end = g.end
            } else {
                // ohne Klammer: Ziffern (auch mit Vorzeichen) oder ein einzelner Buchstabe
                var j = next
                if s[j] == "-" || s[j] == "+" { j = s.index(after: j) }
                while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
                if j == next, s[next].isLetter { j = s.index(after: next) }
                if j == next { out.append(c); i = next; continue }
                body = String(s[next..<j]); end = j
                // mitten in einem Bezeichner (is_int, list_items): kein Index, der Text bleibt
                if end < s.endIndex, s[end].isLetter || s[end] == "_" { out.append(c); i = next; continue }
            }
            if !body.isEmpty, body.allSatisfy({ table[$0] != nil }) {
                out.append(contentsOf: body.map { table[$0]! })
            } else {
                out.append(marker); out.append(body.count > 1 ? "(\(body))" : body)
            }
            i = end
        }
        return out
    }
}
