import Foundation

/// Mathematik in KI-Texten lesbar machen (07.11.2026, Wunsch des Inhabers): LaTeX-Fragmente (`$…$`, `$$…$$`, `\( \)`,
/// `\[ \]`, `\frac`, `\sqrt`, `\int`, `\sum`, `^{}`, `_{}` …) und ASCII-Schreibweisen (`x^2`, `10^-3`, `a_n`, `sqrt(x)`,
/// `<=`, `->`, ausgeschriebene griechische Buchstaben) werden zu Unicode-Zeichen. Reine Textumformung ohne Web-Ansicht
/// und ohne Netz; Code (``` und `…`) und Adressen bleiben unveraendert.
///
/// Hoch- und Tiefstellungen, die Unicode sauber kennt (Ziffern, + − = ( ), n, i), werden zu ² ⁻³ ₙ; alles andere
/// (Buchstaben, ∞, Ausdruecke wie bei ∫₋∞^∞) wird zwischen Markierungen gesetzt (`supOpen`/`subOpen` … `close`), die
/// die Ansicht als echte kleine, hoch- bzw. tiefgestellte Schrift zeigt (`plain` macht daraus lesbaren Text fuer
/// Vorschauen). Idempotent: ein zweiter Durchlauf aendert nichts.
public enum MathText {
    /// Beginn einer Hochstellung (Zeichen aus dem privaten Bereich, nie in echten Texten)
    public static let supOpen: Character = "\u{E000}"
    /// Beginn einer Tiefstellung
    public static let subOpen: Character = "\u{E002}"
    /// Ende einer Hoch- oder Tiefstellung
    public static let close: Character = "\u{E001}"

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ",
    ]
    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "n": "ₙ", "i": "ᵢ",
    ]
    /// schon hoch-/tiefgestellte Zeichen (fuer Idempotenz und um sie nicht doppelt zu markieren)
    private static let scriptChars = Set(superscripts.values).union(subscripts.values)

    // MARK: - Oeffentlich

    /// Text mit Formeln -> lesbarer Text mit Hoch-/Tief-Markierungen (fuer die Ansicht, siehe `plain`)
    public static func render(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = ""
        for seg in segments(text) {
            out += seg.protected ? seg.text : convert(seg.text)
        }
        return out
    }

    /// Wie `render`, aber ohne Markierungen (Vorschauen, Barrierefreiheit, Teilen): x_{k} -> x_k, e^{jωt} -> e^(jωt)
    public static func plain(_ text: String) -> String {
        stripMarkers(render(text))
    }

    /// Markierungen eines schon umgeformten Texts in lesbaren Text wandeln
    public static func stripMarkers(_ s: String) -> String {
        guard s.contains(supOpen) || s.contains(subOpen) else { return s }
        var out = ""
        var stack: [(sup: Bool, start: String.Index)] = []
        var buffer: [String] = []
        for c in s {
            if c == supOpen || c == subOpen {
                stack.append((c == supOpen, s.startIndex)); buffer.append("")
            } else if c == close, let top = stack.popLast(), let body = buffer.popLast() {
                let piece = (top.sup ? "^" : "_") + (body.count > 1 ? "(\(body))" : body)
                if buffer.isEmpty { out += piece } else { buffer[buffer.count - 1] += piece }
            } else if buffer.isEmpty {
                out.append(c)
            } else {
                buffer[buffer.count - 1].append(c)
            }
        }
        for b in buffer { out += b }                           // offene Markierung: Inhalt bleibt
        return out
    }

    // MARK: - Abschnitte (Code und Adressen bleiben)

    struct Segment { var text: String; var protected: Bool }

    static func segments(_ s: String) -> [Segment] {
        guard s.contains("`") || s.contains("://") || s.contains("](") else { return [Segment(text: s, protected: false)] }
        let pattern = #"```[\s\S]*?(```|$)|`[^`\n]+`|\]\([^)\s]*\)|<?(https?|mailto):[^\s)>\]]+>?|www\.[^\s)>\]]+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [Segment(text: s, protected: false)] }
        let ns = s as NSString
        var out: [Segment] = []
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { out.append(Segment(text: ns.substring(with: NSRange(location: last, length: m.range.location - last)), protected: false)) }
            out.append(Segment(text: ns.substring(with: m.range), protected: true))
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(Segment(text: ns.substring(from: last), protected: false)) }
        return out
    }

    /// LaTeX in JSON ohne verdoppelten Backslash: `"\frac"` kommt als Seitenvorschub + "rac", `"\theta"` als Tab +
    /// "heta", `"\beta"` als Rueckschritt + "eta" an. Nur diese eindeutigen Faelle werden repariert.
    static func repairEscapes(_ s: String) -> String {
        guard s.contains("\u{0C}") || s.contains("\u{08}") || s.contains("\t") else { return s }
        var t = s
        t = t.replacingOccurrences(of: "\u{0C}", with: "\\f")                  // \frac, \forall (Seitenvorschub kommt sonst nie vor)
        t = t.replacingOccurrences(of: "\u{08}", with: "\\b")                  // \beta, \bar, \binom, \begin
        for name in ["theta", "times", "textbf", "text", "tfrac", "tilde"] {
            let tail = String(name.dropFirst())
            t = t.replacingOccurrences(of: "\t" + tail, with: "\\" + name)
        }
        return t
    }

    // MARK: - Umformung eines ungeschuetzten Abschnitts

    static func convert(_ s: String) -> String {
        var t = repairEscapes(s)
        if t.contains("$") || t.contains("\\(") || t.contains("\\[") { t = mathSpans(t) }
        if t.contains("\\") { t = latex(t, inMath: false) }
        t = ascii(t)
        t = scripts(t)
        return t
    }

    /// `$$…$$`, `\[…\]`, `\(…\)`, `$…$` -> Inhalt umgeformt, Grenzen weg. Einzelnes `$` nur, wenn direkt dahinter und
    /// davor kein Leerzeichen steht und keine Ziffer folgt (Preise wie "5 $" bleiben).
    static func mathSpans(_ s: String) -> String {
        var t = s
        let patterns = [#"\$\$([\s\S]+?)\$\$"#, #"\\\[([\s\S]+?)\\\]"#, #"\\\(([\s\S]+?)\\\)"#, #"\$(?=[^\s$])([^$\n]{1,400}?)(?<=[^\s$\\])\$(?!\d)"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = t as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let inner = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                out += scripts(latex(inner, inMath: true))
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            t = out
        }
        return t
    }

    // MARK: - LaTeX

    private static let symbols: [String: String] = [
        // griechisch
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operatoren und grosse Zeichen
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮", "sum": "∑", "prod": "∏", "coprod": "∐", "infty": "∞",
        "partial": "∂", "nabla": "∇", "cdot": "·", "cdots": "⋯", "ldots": "…", "dots": "…", "vdots": "⋮", "ddots": "⋱",
        "times": "×", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "•",
        "otimes": "⊗", "oplus": "⊕", "odot": "⊙", "sqrt": "√", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ",
        "aleph": "ℵ", "wp": "℘", "degree": "°", "prime": "′",
        // Relationen
        "le": "≤", "leq": "≤", "leqslant": "≤", "ge": "≥", "geq": "≥", "geqslant": "≥", "ne": "≠", "neq": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫",
        "perp": "⊥", "parallel": "∥", "mid": "|", "nmid": "∤", "models": "⊨", "vdash": "⊢", "coloneqq": "≔",
        // Pfeile
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "Rightarrow": "⇒", "implies": "⇒",
        "Leftarrow": "⇐", "Leftrightarrow": "⇔", "iff": "⇔", "leftrightarrow": "↔", "mapsto": "↦",
        "uparrow": "↑", "downarrow": "↓", "longrightarrow": "⟶", "Longrightarrow": "⟹", "rightleftharpoons": "⇌",
        // Mengen und Logik
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "bigcup": "⋃", "bigcap": "⋂", "setminus": "∖", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨",
        "vee": "∨", "top": "⊤", "bot": "⊥", "oplus_": "⊕",
        // Klammern
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "lvert": "|",
        "rvert": "|", "vert": "|", "lVert": "‖", "rVert": "‖", "Vert": "‖",
        // Funktionen (aufrecht)
        "sin": "sin", "cos": "cos", "tan": "tan", "cot": "cot", "sec": "sec", "csc": "csc", "arcsin": "arcsin",
        "arccos": "arccos", "arctan": "arctan", "sinh": "sinh", "cosh": "cosh", "tanh": "tanh", "exp": "exp",
        "log": "log", "ln": "ln", "lg": "lg", "lim": "lim", "limsup": "lim sup", "liminf": "lim inf", "max": "max",
        "min": "min", "sup": "sup", "inf": "inf", "det": "det", "dim": "dim", "ker": "ker", "deg": "deg", "gcd": "ggT",
        "arg": "arg", "sgn": "sgn", "Pr": "Pr", "mod": "mod", "bmod": "mod", "pmod": "mod",
        // Abstaende und Groessen ohne Zeichen
        "quad": " ", "qquad": "  ", "left": "", "right": "", "big": "", "Big": "", "bigg": "", "Bigg": "",
        "bigl": "", "bigr": "", "Bigl": "", "Bigr": "", "biggl": "", "biggr": "", "displaystyle": "", "textstyle": "",
        "limits": "", "nolimits": "", "nonumber": "", "notag": "", "middle": "", "label": "",
    ]
    private static let blackboard: [Character: String] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ", "E": "𝔼", "K": "𝕂"]
    private static let fractions: [String: String] = [
        "1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾", "1/5": "⅕", "2/5": "⅖", "3/5": "⅗", "4/5": "⅘",
        "1/6": "⅙", "5/6": "⅚", "1/8": "⅛", "3/8": "⅜", "5/8": "⅝", "7/8": "⅞",
    ]

    /// LaTeX-Befehle umformen. `inMath`: Inhalt zwischen Formelgrenzen (dort fallen auch `{}`, `&` und `\\` weg).
    static func latex(_ s: String, inMath: Bool) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { out.append(c); break }
                let n = s[next]
                if !n.isLetter {
                    // Zeichenbefehle: \, \; \! \  \{ \} \| \\ \% \$ \&
                    switch n {
                    case ",", ";", ":", " ", ">": out.append(" ")
                    case "!": break
                    case "{": out.append("\u{E010}")
                    case "}": out.append("\u{E011}")
                    case "|": out.append("‖")
                    case "\\": out.append(inMath ? " " : "\n")
                    case "%", "$", "&", "#", "_": out.append(n)
                    default: out.append(c); out.append(n)
                    }
                    i = s.index(after: next)
                    continue
                }
                var j = next
                while j < s.endIndex, s[j].isLetter { j = s.index(after: j) }
                let name = String(s[next..<j])
                let (repl, end) = command(name, s, after: j)
                out += repl
                i = end
                continue
            }
            if inMath {
                if c == "{" { out.append("\u{E012}") } else if c == "}" { out.append("\u{E013}") } else if c == "&" {
                    // Ausrichtung: weg
                } else { out.append(c) }
            } else {
                out.append(c)
            }
            i = s.index(after: i)
        }
        if inMath {
            // Gruppen, die zu ^/_ gehoeren, behalten ihre Klammer; uebrige Klammern fallen weg
            out = keepScriptGroups(out)
        }
        out = out.replacingOccurrences(of: "\u{E010}", with: "{").replacingOccurrences(of: "\u{E011}", with: "}")
        return collapseSpaces(out)
    }

    /// In Formeln: `{`/`}` direkt hinter ^ oder _ bleiben (fuer `scripts`), alle anderen Gruppenklammern fallen weg
    private static func keepScriptGroups(_ s: String) -> String {
        var out = ""
        var stack: [Bool] = []                         // true = Klammer behalten
        var prev: Character = " "
        for c in s {
            if c == "\u{E012}" {
                let keep = prev == "^" || prev == "_"
                stack.append(keep)
                if keep { out.append("{") }
            } else if c == "\u{E013}" {
                if stack.popLast() == true { out.append("}") }
            } else {
                out.append(c)
            }
            prev = c
        }
        return out
    }

    private static func collapseSpaces(_ s: String) -> String {
        guard s.contains("  ") else { return s }
        var out = ""
        var lastSpace = false
        for c in s {
            if c == " " { if !lastSpace { out.append(c) }; lastSpace = true } else { out.append(c); lastSpace = false }
        }
        return out
    }

    /// Ein Befehl `\name` an der Stelle `after` (direkt hinter dem Namen) -> Ersatz und Ende im Text
    private static func command(_ name: String, _ s: String, after j: String.Index) -> (String, String.Index) {
        func arg(_ from: String.Index) -> (String, String.Index)? {
            var k = from
            while k < s.endIndex, s[k] == " " { k = s.index(after: k) }
            guard k < s.endIndex else { return nil }
            if s[k] == "{", let g = group(s, from: s.index(after: k)) { return (g.text, g.end) }
            if s[k] == "\\" {                               // \frac\alpha\beta: ein Befehl als Argument
                var e = s.index(after: k)
                while e < s.endIndex, s[e].isLetter { e = s.index(after: e) }
                if e > s.index(after: k) { return (String(s[k..<e]), e) }
            }
            if s[k].isLetter || s[k].isNumber { return (String(s[k]), s.index(after: k)) }
            return nil
        }
        func inner(_ t: String) -> String { scripts(latex(t, inMath: true)) }
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            guard let a = arg(j), let b = arg(a.1) else { return ("", j) }
            return (fraction(inner(a.0), inner(b.0)), b.1)
        case "binom", "dbinom", "tbinom":
            guard let a = arg(j), let b = arg(a.1) else { return ("", j) }
            return ("(\(inner(a.0)) über \(inner(b.0)))", b.1)
        case "sqrt":
            var k = j
            var index = ""
            if k < s.endIndex, s[k] == "[", let close = s[k...].firstIndex(of: "]") {
                index = String(s[s.index(after: k)..<close]); k = s.index(after: close)
            }
            guard let a = arg(k) else { return ("√", j) }
            let body = inner(a.0)
            let root = index.isEmpty ? "√" : (index == "3" ? "∛" : index == "4" ? "∜" : sup(inner(index)) + "√")
            return (root + (isAtom(body) ? body : "(\(body))"), a.1)
        case "text", "textrm", "textit", "textbf", "mathrm", "mathit", "mathbf", "mathsf", "mathtt", "operatorname",
             "boldsymbol", "bm", "mbox", "textnormal", "mathcal", "mathscr", "mathfrak", "emph":
            guard let a = arg(j) else { return ("", j) }
            return (name.hasPrefix("text") || name == "mbox" || name == "emph" ? a.0 : inner(a.0), a.1)
        case "mathbb":
            guard let a = arg(j) else { return ("", j) }
            return (a.0.count == 1 ? (blackboard[Character(a.0)] ?? a.0) : a.0, a.1)
        case "hat", "widehat": return accent("\u{0302}", arg(j), j)
        case "bar", "overline": return accent("\u{0305}", arg(j), j)
        case "tilde", "widetilde": return accent("\u{0303}", arg(j), j)
        case "dot": return accent("\u{0307}", arg(j), j)
        case "ddot": return accent("\u{0308}", arg(j), j)
        case "vec", "overrightarrow": return accent("\u{20D7}", arg(j), j)
        case "underline":
            guard let a = arg(j) else { return ("", j) }
            return (inner(a.0), a.1)
        case "begin", "end":
            guard let a = arg(j) else { return ("", j) }
            _ = a
            var e = a.1
            // \begin{array}{cc}: Spaltenangabe weg
            if name == "begin", e < s.endIndex, s[e] == "{", let g = group(s, from: s.index(after: e)), g.text.allSatisfy({ "lcr| ".contains($0) }) { e = g.end }
            return ("", e)
        case "color", "textcolor":
            guard let a = arg(j) else { return ("", j) }
            return ("", a.1)
        default:
            if let sym = symbols[name] {
                // Funktionsnamen und Woerter brauchen Abstand zum naechsten Buchstaben (\sin x, \lim_{…})
                if sym.count > 1, j < s.endIndex, s[j].isLetter { return (sym + " ", j) }
                return (sym, j)
            }
            return (name, j)                                          // unbekannt: Name ohne Backslash
        }
    }

    private static func accent(_ mark: String, _ a: (String, String.Index)?, _ j: String.Index) -> (String, String.Index) {
        guard let a else { return ("", j) }
        let body = scripts(latex(a.0, inMath: true))
        if body.count == 1 { return (body + mark, a.1) }
        return (body, a.1)
    }

    private static func fraction(_ a: String, _ b: String) -> String {
        if let f = fractions["\(a)/\(b)"] { return f }
        return "\(wrap(a))/\(wrap(b))"
    }

    /// einzelnes Zeichen, Zahl oder Wort (auch mit Hoch-/Tiefstellung) braucht keine Klammer
    static func isAtom(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count <= 1 { return true }
        if t.hasPrefix("("), t.hasSuffix(")"), balanced(String(t.dropFirst().dropLast())) { return true }
        // Funktionsanwendung wie f(x) oder n(n+1): Name, dann genau eine Klammer bis zum Ende
        if t.hasSuffix(")"), let open = t.firstIndex(of: "("), open > t.startIndex,
           t[..<open].allSatisfy({ $0.isLetter || $0.isNumber }),
           let g = group(t, from: t.index(after: open), open: "(", close: ")"), g.end == t.endIndex { return true }
        return t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "," || scriptChars.contains($0) || $0 == supOpen || $0 == subOpen || $0 == close }
    }

    private static func balanced(_ s: String) -> Bool {
        var d = 0
        for c in s { if c == "(" { d += 1 } else if c == ")" { d -= 1; if d < 0 { return false } } }
        return d == 0
    }

    private static func wrap(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return isAtom(t) ? t : "(\(t))"
    }

    /// Inhalt einer geschweiften Gruppe ab `start` (direkt hinter `{`), mit Verschachtelung
    static func group(_ s: String, from start: String.Index, open: Character = "{", close: Character = "}") -> (text: String, end: String.Index)? {
        var depth = 1
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if c == open { depth += 1 } else if c == close {
                depth -= 1
                if depth == 0 { return (String(s[start..<i]), s.index(after: i)) }
            }
            i = s.index(after: i)
        }
        return nil
    }

    // MARK: - ASCII-Schreibweisen

    /// ausgeschriebene griechische Buchstaben (klein), die allein als Variable stehen
    private static let greekWords: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "theta": "θ", "kappa": "κ", "lambda": "λ", "mu": "μ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ",
        "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
    ]
    /// grosse Schreibweise vor Bindestrich ("Epsilon-Definition" -> "ε-Definition"); das Zeichen ist das kleine,
    /// ausser es ist als grosses ueblich
    private static let greekCapitalWords: [String: String] = [
        "Alpha": "α", "Beta": "β", "Gamma": "γ", "Delta": "δ", "Epsilon": "ε", "Zeta": "ζ", "Theta": "θ", "Kappa": "κ",
        "Lambda": "λ", "Mu": "μ", "Pi": "π", "Rho": "ρ", "Sigma": "σ", "Tau": "τ", "Phi": "φ", "Chi": "χ",
        "Psi": "ψ", "Omega": "ω",
    ]
    /// harmlose Woerter hinter dem Bindestrich, bei denen der Name ein Wort bleibt (Alpha-Version, Pi-Day …)
    private static let greekExceptions: Set<String> = [
        "version", "versionen", "test", "tests", "tester", "testerin", "phase", "release", "blocker", "tier", "tiere",
        "männchen", "maennchen", "weibchen", "day", "tag", "kanal", "zentauri", "centauri", "strahlung", "strahlen",
        "teilchen", "zerfall", "funktion", "verteilung", "kalkül", "kalkuel", "säure", "saeure", "fettsäure", "fettsäuren",
        "kappa", "programm", "software", "build", "app", "nutzer",
    ]
    /// Ausnahmen, bei denen das grosse Zeichen gemeint ist (Gamma-Funktion -> Γ-Funktion bleibt als Wort, s. oben)
    private static let operators: [(String, String)] = [
        ("<=>", "⇔"), ("<->", "↔"), ("<=", "≤"), (">=", "≥"), ("!=", "≠"), ("=/=", "≠"), ("=>", "⇒"), ("->", "→"),
        ("+/-", "±"), ("+-", "±"), ("~=", "≈"),
    ]

    static func ascii(_ s: String) -> String {
        var t = s
        // Operatoren (nicht in Pfeil-Ketten wie "-->" oder HTML "<!--")
        if t.contains("=") || t.contains("->") || t.contains("+-") || t.contains("+/-") || t.contains("~=") || t.contains("<-") {
            for (a, b) in operators {
                t = replaceToken(t, a, b)
            }
        }
        if t.range(of: "integral", options: .caseInsensitive) != nil { t = integralWords(t) }
        if t.contains("sqrt") { t = sqrtCalls(t) }
        if t.contains(" * ") { t = starOperator(t) }
        t = greek(t)
        return t
    }

    /// Operator ersetzen, wenn er nicht Teil einer laengeren Zeichenfolge aus <, >, =, -, ! ist
    private static func replaceToken(_ s: String, _ token: String, _ repl: String) -> String {
        guard s.contains(token) else { return s }
        let opChars: Set<Character> = ["<", ">", "=", "-", "!", "/", "+", "~"]
        var out = ""
        var i = s.startIndex
        let tk = Array(token)
        while i < s.endIndex {
            if s[i...].hasPrefix(token) {
                let before = i > s.startIndex ? s[s.index(before: i)] : " "
                let endIdx = s.index(i, offsetBy: tk.count)
                let after = endIdx < s.endIndex ? s[endIdx] : " "
                if !opChars.contains(before) && !opChars.contains(after) {
                    out += repl
                    i = endIdx
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    /// "integral von -unendlich bis unendlich von |x(t)|^2 dt" -> "∫₋∞^∞ |x(t)|² dt" (Grenzen als Tief-/Hochstellung)
    private static func integralWords(_ s: String) -> String {
        let p = #"(?i)\b(?:das\s+)?integral\s+von\s+(\S+)\s+bis\s+(\S+)\s+(?:(?:von|über|ueber)\s+)?"#
        guard let re = try? NSRegularExpression(pattern: p) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            func bound(_ r: NSRange) -> String {
                var b = ns.substring(with: r)
                for (w, r) in [("-unendlich", "−∞"), ("−unendlich", "−∞"), ("+unendlich", "∞"), ("unendlich", "∞"), ("-infinity", "−∞"), ("infinity", "∞"), ("-inf", "−∞"), ("inf", "∞")] where b.lowercased() == w {
                    b = r
                }
                if b.hasPrefix("-") { b = "−" + b.dropFirst() }
                return b
            }
            out += "∫" + sub(bound(m.range(at: 1))) + sup(bound(m.range(at: 2))) + " "
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// `sqrt(x)` -> √x, `sqrt(x+1)` -> √(x+1)
    private static func sqrtCalls(_ s: String) -> String {
        var out = s
        var from = out.startIndex
        while let r = out.range(of: "sqrt(", range: from..<out.endIndex) {
            if r.lowerBound > out.startIndex, out[out.index(before: r.lowerBound)].isLetter { from = r.upperBound; continue }
            guard let g = group(out, from: r.upperBound, open: "(", close: ")") else { break }
            let body = g.text
            let repl = "√" + (isAtom(body) ? body : "(\(body))")
            out.replaceSubrange(r.lowerBound..<g.end, with: repl)
            from = out.index(r.lowerBound, offsetBy: repl.count)
        }
        return out
    }

    /// " * " zwischen Ausdruecken: Ziffern -> ·, sonst Faltung/Operator ∗ (x[n] * h[n])
    private static func starOperator(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var k = 0
        while k < chars.count {
            if k + 2 < chars.count, chars[k] == " ", chars[k + 1] == "*", chars[k + 2] == " ", k > 0, k + 3 < chars.count {
                let a = chars[k - 1], b = chars[k + 3]
                let operand: (Character) -> Bool = { $0.isLetter || $0.isNumber || ")]}|".contains($0) || scriptChars.contains($0) }
                let operandStart: (Character) -> Bool = { $0.isLetter || $0.isNumber || "([{|√".contains($0) }
                if operand(a), operandStart(b) {
                    out += (a.isNumber && b.isNumber) ? " · " : " ∗ "
                    k += 3
                    continue
                }
            }
            out.append(chars[k])
            k += 1
        }
        return out
    }

    /// ausgeschriebene griechische Buchstaben als Variable -> Zeichen
    private static func greek(_ s: String) -> String {
        guard s.rangeOfCharacter(from: CharacterSet(charactersIn: "aAbBgGdDeEzZtTkKlLmMpPrRsScChHoO")) != nil else { return s }
        let names = (greekWords.keys.map { $0 } + greekCapitalWords.keys.map { $0 }).sorted { $0.count > $1.count }.joined(separator: "|")
        let p = #"(?<![\p{L}\p{N}_\\/@.])("# + names + #")(?![\p{L}\p{N}_])"#
        guard let re = try? NSRegularExpression(pattern: p) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1))
            let end = m.range.location + m.range.length
            let rest = ns.substring(from: end)
            var repl: String?
            if let lower = greekWords[word] {
                // klein: als Variable, ausser vor Bindestrich mit harmlosem Wort
                repl = hyphenException(rest) ? nil : lower
            } else if let cap = greekCapitalWords[word] {
                // gross nur vor Bindestrich mit Buchstaben ("Epsilon-Definition", "Epsilon-Delta-Kriterium") oder vor
                // einem Formelzeichen ("jedes Epsilon > 0")
                if rest.hasPrefix("-"), rest.dropFirst().first?.isLetter == true, !hyphenException(rest) { repl = cap }
                else if let f = rest.trimmingCharacters(in: .whitespaces).first, rest.hasPrefix(" "), "<>=≤≥≠→∈".contains(f) { repl = cap }
                else if rest.hasPrefix("_") || rest.hasPrefix("^") { repl = cap }
            }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += repl ?? word
            last = end
        }
        out += ns.substring(from: last)
        return out
    }

    private static func hyphenException(_ rest: String) -> Bool {
        guard rest.hasPrefix("-") else { return false }
        let word = rest.dropFirst().prefix { $0.isLetter }.lowercased()
        return greekExceptions.contains(word) || word.isEmpty && rest.dropFirst().first?.isNumber == true
    }

    // MARK: - Hoch- und Tiefstellung

    /// Hochstellung: abbildbar -> Unicode, sonst markiert
    static func sup(_ body: String) -> String { script(body, table: superscripts, open: supOpen) }
    /// Tiefstellung: abbildbar -> Unicode, sonst markiert
    static func sub(_ body: String) -> String { script(body, table: subscripts, open: subOpen) }

    private static func script(_ body: String, table: [Character: Character], open: Character) -> String {
        let b = body.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return "" }
        if b.allSatisfy({ table[$0] != nil }) { return String(b.map { table[$0]! }) }
        // ohne innere Markierungen (eine Ebene reicht fuer die Ansicht)
        return String(open) + stripMarkers(b).replacingOccurrences(of: "-", with: "−") + String(close)
    }

    /// `x^2`, `x^{10}`, `e^(-2t)`, `10^-3`, `a_n`, `a_{i+1}` -> Hoch-/Tiefstellung
    static func scripts(_ s: String) -> String {
        guard s.contains("^") || s.contains("_") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "^" || c == "_", i > s.startIndex, s.index(after: i) < s.endIndex else { out.append(c); i = s.index(after: i); continue }
            let prev = s[s.index(before: i)]
            let prevOK = prev.isLetter || prev.isNumber || ")]}|′'∫∑∏∮".contains(prev) || scriptChars.contains(prev) || prev == close
            guard prevOK else { out.append(c); i = s.index(after: i); continue }
            let next = s.index(after: i)
            var body: String
            var end: String.Index
            var parenGroup = false
            if s[next] == "{", let g = group(s, from: s.index(after: next)) {
                body = g.text; end = g.end
            } else if s[next] == "(", let g = group(s, from: s.index(after: next), open: "(", close: ")"), g.text.count <= 40 {
                body = g.text; end = g.end; parenGroup = true
            } else {
                // ohne Klammer: Zahl (auch mit Vorzeichen), ein Buchstabe, ∞ oder ein Strich
                var j = next
                if s[j] == "-" || s[j] == "+" || s[j] == "−" { j = s.index(after: j) }
                while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
                if j < s.endIndex, s[j] == ".", s.index(after: j) < s.endIndex, s[s.index(after: j)].isNumber, j > next {
                    j = s.index(after: j); while j < s.endIndex, s[j].isNumber { j = s.index(after: j) }
                }
                if j == next || (j == s.index(after: next) && !s[next].isNumber) {
                    // kein Ziffernlauf: ein Buchstabe oder ∞ (auch hinter Vorzeichen: x^-n)
                    if j < s.endIndex, s[j].isLetter || s[j] == "∞" || s[j] == "*" || s[j] == "′" { j = s.index(after: j) }
                    else { j = next }
                }
                if j == next { out.append(c); i = next; continue }
                body = String(s[next..<j]); end = j
                // mitten in einem Bezeichner (is_int, list_items, max_value): kein Index, der Text bleibt
                if end < s.endIndex, s[end].isLetter || s[end] == "_" || s[end].isNumber, !(body.first?.isNumber ?? false) { out.append(c); i = next; continue }
                if c == "_", prev.isLetter, body.count == 1, body.first!.isLetter, i > s.index(after: s.startIndex),
                   s[s.index(i, offsetBy: -2)].isLetter, s[s.index(i, offsetBy: -2)] != " " {
                    // snake_case wie "my_x": vor dem Unterstrich ein Wort aus mehreren Buchstaben -> bleibt
                    let wordStart = s[..<i].lastIndex(where: { !$0.isLetter && !$0.isNumber }).map { s.index(after: $0) } ?? s.startIndex
                    if s.distance(from: wordStart, to: i) > 3 { out.append(c); i = next; continue }
                }
            }
            let rendered = scripts(body)
            out += c == "^" ? sup(rendered) : sub(rendered)
            // e^(-2t)u(t): Malpunkt zwischen Exponent in Klammern und folgender Funktion
            if parenGroup, c == "^", end < s.endIndex, s[end].isLetter { out += "·" }
            i = end
        }
        return out
    }
}
