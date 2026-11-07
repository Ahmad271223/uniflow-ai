import Foundation

/// Formeln in KI-Texten lesbar machen, ohne Web-Ansicht (04.11.2026; erweitert 07.11.2026 fuer die KI-Hilfe:
/// "ε statt epsilon, das richtige hoch 2 statt ^2"). Reine Textumformung auf Unicode: griechische Buchstaben (auch
/// ausgeschrieben, kleingeschrieben: "epsilon > 0"), Hoch- und Tiefstellung, Wurzel, Brueche als a/b, Vergleichs-,
/// Mengen- und Pfeilzeichen, LaTeX-Formelgrenzen ($...$, $$...$$, \(...\), \[...\]) weg.
///
/// - `render(_:)`: Klartext (Wochentest, Karteikarten): nicht abbildbare Hoch-/Tiefstellung bleibt als `^(a+b)`.
/// - `render(_:rich:)` mit `rich: true` (KI-Hilfe, `AIMarkdownText`): nicht abbildbare Hoch-/Tiefstellung steht
///   zwischen den Marken `supOpen`/`subOpen` ... `scriptClose`; `AIMarkdown.styled` setzt sie als echte, kleinere
///   hoch- bzw. tiefgestellte Schrift. Dazu `<=` -> ≤, `->` -> →, `!=` -> ≠, `=>` -> ⇒, `\frac{1}{2}` -> ½, `√(2)` -> √2.
///
/// Nie angefasst: Inline-Code in Backticks, Linkziele `](...)`, Adressen (http/https). Ausserhalb einer Formel bleiben
/// unbekannte Backslash-Folgen stehen (Pfade, `\n`); in einer Formel bleibt von unbekannten Befehlen der Inhalt.
enum FormulaText {
    /// Marken fuer echte Hoch-/Tiefstellung (nur `rich`), private Unicode-Zeichen
    static let supOpen: Character = "\u{E000}"
    static let subOpen: Character = "\u{E001}"
    static let scriptClose: Character = "\u{E002}"
    // Platzhalter fuer \{ \} \_ \$, damit sie nicht als Gruppe, Index oder Formelgrenze gelten
    private static let lbrace: Character = "\u{E010}", rbrace: Character = "\u{E011}"
    private static let underscore: Character = "\u{E012}", dollar: Character = "\u{E013}"

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "n": "ⁿ", "i": "ⁱ", "(": "⁽", ")": "⁾", "k": "ᵏ", "m": "ᵐ", "x": "ˣ", "t": "ᵗ",
        "∘": "°", "°": "°", "′": "′", "*": "*",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "n": "ₙ", "i": "ᵢ", "k": "ₖ", "m": "ₘ", "x": "ₓ", "j": "ⱼ", "(": "₍", ")": "₎",
    ]
    private static let signs: Set<Character> = ["+", "-", "−"]
    /// `\name` -> Zeichen (der Name wird ganz gelesen: `\leq` ist nie `\le` + "q", `\inf` nie `\in` + "f")
    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "le": "≤", "leq": "≤", "leqslant": "≤", "ge": "≥", "geq": "≥", "geqslant": "≥", "ne": "≠", "neq": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫",
        "pm": "±", "mp": "∓", "cdot": "·", "times": "×", "div": "÷", "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "•",
        "infty": "∞", "partial": "∂", "nabla": "∇", "emptyset": "∅", "varnothing": "∅", "ell": "ℓ", "hbar": "ℏ",
        "prime": "′", "degree": "°", "angle": "∠", "perp": "⊥", "parallel": "∥", "mid": "|", "nmid": "∤",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "setminus": "∖", "bigcup": "⋃", "bigcap": "⋂",
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨",
        "vee": "∨", "oplus": "⊕", "otimes": "⊗", "top": "⊤", "bot": "⊥",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "Leftrightarrow": "⇔", "implies": "⇒", "impliedby": "⇐", "iff": "⇔", "mapsto": "↦",
        "longrightarrow": "⟶", "longleftarrow": "⟵", "Longrightarrow": "⟹", "Longleftrightarrow": "⟺",
        "uparrow": "↑", "downarrow": "↓",
        "sum": "Σ", "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮",
        "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
        "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖", "vert": "|", "Vert": "‖",
        "quad": "  ", "qquad": "   ",
        // nur Satz, kein Zeichen
        "left": "", "right": "", "big": "", "Big": "", "bigg": "", "Bigg": "", "bigl": "", "bigr": "", "Bigl": "", "Bigr": "",
        "displaystyle": "", "textstyle": "", "limits": "", "nolimits": "",
    ]
    /// Funktionsnamen: ohne Backslash, aufrecht wie im Lehrbuch
    private static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "ln", "log",
        "lg", "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "dim", "ker", "deg", "gcd", "arg",
        "mod", "bmod", "Pr", "Re", "Im",
    ]
    private static let sets: [Character: String] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ", "K": "𝕂"]
    private static let calligraphic: [Character: String] = Dictionary(uniqueKeysWithValues: zip(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "𝒜ℬ𝒞𝒟ℰℱ𝒢ℋℐ𝒥𝒦ℒℳ𝒩𝒪𝒫𝒬ℛ𝒮𝒯𝒰𝒱𝒲𝒳𝒴𝒵".map { String($0) }))
    /// Akzente als kombinierende Zeichen (x̄, p̂, x̃, ẋ, v⃗)
    private static let accents: [String: String] = [
        "bar": "\u{0304}", "overline": "\u{0305}", "hat": "\u{0302}", "widehat": "\u{0302}", "tilde": "\u{0303}",
        "widetilde": "\u{0303}", "dot": "\u{0307}", "ddot": "\u{0308}", "vec": "\u{20D7}",
    ]
    /// Befehle, von denen nur der Inhalt bleibt (`\mathbb` und `\mathcal` mit eigenen Zeichen)
    private static let textArgs: Set<String> = [
        "text", "textrm", "textbf", "textit", "textsf", "texttt", "mathrm", "mathbf", "mathit", "mathsf", "mathtt",
        "boldsymbol", "bm", "operatorname", "mbox", "underline", "emph", "mathbb", "mathcal", "mathscr", "mathfrak",
    ]
    private static let fracs: Set<String> = ["frac", "dfrac", "tfrac", "cfrac"]
    private static let binoms: Set<String> = ["binom", "dbinom", "tbinom"]
    private static let vulgar: [String: String] = ["1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾", "1/5": "⅕", "1/6": "⅙", "1/8": "⅛"]
    /// Ausgeschriebene, kleingeschriebene Namen ohne Backslash ("epsilon > 0", "epsilon-Umgebung"); deutsche Nomen
    /// stehen gross ("das Epsilon", "Delta") und bleiben. Nicht dabei: nu ("im nu"), psi (Druckeinheit).
    private static let greekWords: [String: String] = [
        "epsilon": "ε", "varepsilon": "ε", "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "zeta": "ζ",
        "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "varphi": "φ", "chi": "χ", "omega": "ω",
    ]
    /// nur `rich`: Schreibweisen mit Tastaturzeichen -> Zeichen (laengere zuerst)
    private static let operators: [(String, String)] = [
        ("<==>", "⟺"), ("<=>", "⇔"), ("==>", "⟹"), ("=>", "⇒"), ("<=", "≤"), (">=", "≥"), ("!=", "≠"),
        ("-->", "⟶"), ("->", "→"), ("+/-", "±"), ("~=", "≈"),
    ]
    /// `\,` `\;` `\!` ... (Abstaende, maskierte Zeichen)
    private static let escapes: [Character: String] = [",": " ", ";": " ", ":": " ", "!": "", " ": " ", "|": "‖", "%": "%", "&": "&", "#": "#"]

    /// Text mit Formeln -> lesbarer Klartext; nichts geht verloren, nur die Schreibweise aendert sich
    static func render(_ text: String) -> String { render(text, rich: false) }

    /// Wie `render(_:)`; mit `rich` fuer die KI-Hilfe (Marken fuer echte Hoch-/Tiefstellung, Pfeile und Vergleiche,
    /// ½, √2). Das Ergebnis von `rich` ist fuer `AIMarkdown.styled` gedacht (Markdown, `\_` bleibt maskiert).
    static func render(_ text: String, rich: Bool) -> String {
        guard !text.isEmpty else { return text }
        let s = Array(text)
        let n = s.count
        var out = "", pos = 0, i = 0
        while i < n {
            var end: Int?
            if s[i] == "`" {
                if let j = find(s, "`", from: i + 1) { end = j + 1 }
            } else if s[i] == "]", i + 1 < n, s[i + 1] == "(" {
                if let j = find(s, ")", from: i + 2) { end = j + 1 }
            } else if s[i] == "h", starts(s, "http://", at: i) || starts(s, "https://", at: i) {
                var j = i
                while j < n, !s[j].isWhitespace { j += 1 }
                end = j
            }
            guard let e = end else { i += 1; continue }
            out += convert(String(s[pos..<i]), rich: rich)
            out += String(s[i..<e])
            pos = e
            i = e
        }
        out += convert(String(s[pos..<n]), rich: rich)
        return out
    }

    // MARK: Formelbereiche

    private static func convert(_ text: String, rich: Bool) -> String {
        guard !text.isEmpty else { return text }
        let t = text.replacingOccurrences(of: "\\$", with: String(dollar))
            .replacingOccurrences(of: "\\{", with: String(lbrace))
            .replacingOccurrences(of: "\\}", with: String(rbrace))
            .replacingOccurrences(of: "\\_", with: String(underscore))
        let s = Array(t)
        var out = "", i = 0, plain = 0
        while i < s.count {
            if s[i] == "$" || s[i] == "\\", let m = mathRange(s, i) {
                out += core(String(s[plain..<i]), rich: rich, math: false)
                out += core(String(s[m.from..<m.to]), rich: rich, math: true)
                i = m.next
                plain = m.next
                continue
            }
            i += 1
        }
        out += core(String(s[plain..<s.count]), rich: rich, math: false)
        return out.replacingOccurrences(of: String(dollar), with: "$")
            .replacingOccurrences(of: String(lbrace), with: "{")
            .replacingOccurrences(of: String(rbrace), with: "}")
            .replacingOccurrences(of: String(underscore), with: rich ? "\\_" : "_")
    }

    /// Formel ab `i`: `$$...$$`, `\[...\]`, `\(...\)` oder `$...$` (nach `$` kein Leerzeichen, vor dem schliessenden
    /// keins und danach keine Ziffer: "5$ und 10$" ist keine Formel)
    private static func mathRange(_ s: [Character], _ i: Int) -> (from: Int, to: Int, next: Int)? {
        for (opening, closing) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)")] where starts(s, opening, at: i) {
            guard let j = find(s, closing, from: i + 2), j > i + 2 else { return nil }
            return (i + 2, j, j + 2)
        }
        guard s[i] == "$", i + 1 < s.count, !s[i + 1].isWhitespace else { return nil }
        var j = i + 1
        while j < s.count {
            if s[j] == "$", !s[j - 1].isWhitespace, !(j + 1 < s.count && digit(s[j + 1])) { return (i + 1, j, j + 1) }
            j += 1
        }
        return nil
    }

    /// ein Stueck Text (`math`: innerhalb einer Formel)
    private static func core(_ text: String, rich: Bool, math: Bool) -> String {
        guard !text.isEmpty else { return text }
        var s = text
        if math {
            s = environments(s).replacingOccurrences(of: "\\\\", with: rich ? "\n" : "; ").replacingOccurrences(of: "&", with: "")
        }
        s = commands(s, rich: rich, math: math)
        if !math { s = greek(s) }
        s = s.replacingOccurrences(of: "sqrt(", with: "√(")
        if rich {
            s = shortRoots(s)
            for (a, b) in operators { s = s.replacingOccurrences(of: a, with: b) }
        }
        s = scripts(s, rich: rich, math: math)
        if math {
            s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }   // Leerzeichen zaehlen in Formeln nicht
        }
        return s
    }

    /// `\begin{...}` und `\end{...}` weg (aligned, cases, pmatrix: der Inhalt bleibt)
    private static func environments(_ text: String) -> String {
        var s = text
        for tag in ["\\begin{", "\\end{"] {
            while let r = s.range(of: tag), let e = s.range(of: "}", range: r.upperBound..<s.endIndex) {
                s.removeSubrange(r.lowerBound..<e.upperBound)
            }
        }
        return s
    }

    // MARK: Befehle

    private static func commands(_ text: String, rich: Bool, math: Bool) -> String {
        let s = Array(text)
        let n = s.count
        var out = "", i = 0
        func inner(_ x: String) -> String {
            scripts(commands(x, rich: rich, math: math), rich: rich, math: math).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while i < n {
            guard s[i] == "\\", i + 1 < n else { out.append(s[i]); i += 1; continue }
            var j = i + 1
            while j < n, asciiLetter(s[j]) { j += 1 }
            let name = String(s[(i + 1)..<j])
            if name.isEmpty {
                if let e = escapes[s[i + 1]] { out += e; i += 2 } else { out.append(s[i]); i += 1 }
                continue
            }
            if fracs.contains(name) || binoms.contains(name) {
                if let a = arg(s, j), let b = arg(s, a.end) {
                    let x = inner(a.text), y = inner(b.text)
                    if binoms.contains(name) {
                        out += "(\(x) über \(y))"
                    } else if rich, let v = vulgar["\(x)/\(y)"] {
                        out += v
                    } else {
                        out += "\(wrap(x))/\(wrap(y))"
                    }
                    i = b.end
                    continue
                }
            } else if name == "sqrt" {
                var k = j
                var index = ""
                if k < n, s[k] == "[", let e = find(s, "]", from: k) {
                    index = inner(String(s[(k + 1)..<e]))
                    k = e + 1
                }
                if let a = arg(s, k) {
                    let x = inner(a.text)
                    var root = "√" + (rich && !x.isEmpty && x.allSatisfy(alnum) ? x : "(\(x))")
                    if !index.isEmpty {
                        let raised = index.allSatisfy({ superscripts[$0] != nil })
                        root = (raised ? String(index.map { superscripts[$0]! }) : "\(index). ") + root
                    }
                    out += root
                    i = a.end
                    continue
                }
                out += "√"
                i = j
                continue
            } else if accents[name] != nil || textArgs.contains(name) {
                if let a = arg(s, j) {
                    if let mark = accents[name] {
                        let x = inner(a.text)
                        if name == "overline", x.count > 1 {
                            out += x.map { String($0) + "\u{0305}" }.joined()
                        } else if x.count == 1 {
                            out += x + (name == "overline" ? "\u{0304}" : mark)
                        } else {
                            out += "(\(x))" + mark
                        }
                    } else {
                        let x = commands(a.text, rich: rich, math: math)
                        if name == "mathbb" {
                            out += x.map { sets[$0] ?? String($0) }.joined()
                        } else if name == "mathcal" || name == "mathscr" {
                            out += x.map { calligraphic[$0] ?? String($0) }.joined()
                        } else {
                            out += x
                        }
                    }
                    i = a.end
                    continue
                }
            } else if let symbol = symbols[name] {
                out += symbol
                i = j
                continue
            } else if functions.contains(name) {
                out += name
                i = j
                continue
            } else if math {
                // unbekannt in einer Formel: der Inhalt bleibt, sonst der Name ohne Backslash
                if j < n, s[j] == "{", let g = group(s, j + 1, "{", "}") {
                    out += commands(g.text, rich: rich, math: math)
                    i = g.end
                    continue
                }
                out += name
                i = j
                continue
            }
            out += String(s[i..<j])                    // ausserhalb einer Formel bleibt Unbekanntes stehen (Pfade, \n)
            i = j
        }
        return out
    }

    /// Argument ab `i`: `{Gruppe}`, `\befehl` oder ein Zeichen (Leerzeichen davor zaehlen nicht)
    private static func arg(_ s: [Character], _ i: Int) -> (text: String, end: Int)? {
        var j = i
        while j < s.count, s[j] == " " { j += 1 }
        guard j < s.count else { return nil }
        if s[j] == "{" { return group(s, j + 1, "{", "}") }
        if s[j] == "\\" {
            var k = j + 1
            while k < s.count, asciiLetter(s[k]) { k += 1 }
            return k > j + 1 ? (String(s[j..<k]), k) : nil
        }
        if s[j] == "}" || s[j] == "^" || s[j] == "_" { return nil }
        return (String(s[j]), j + 1)
    }

    /// `(a+b)` bleibt, ein einzelnes Zeichen oder Wort bleibt, sonst Klammern fuer einen Bruch
    private static func wrap(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 1 || t.allSatisfy(alnum) { return t }
        let a = Array(t)
        if a[0] == "(", let g = group(a, 1, "(", ")"), g.end == a.count { return t }
        return "(" + t + ")"
    }

    /// nur `rich`: √(2) -> √2, √(x) -> √x (nur Buchstaben und Ziffern in der Klammer)
    private static func shortRoots(_ text: String) -> String {
        let s = Array(text)
        var out = "", i = 0
        while i < s.count {
            if s[i] == "√", i + 1 < s.count, s[i + 1] == "(" {
                var j = i + 2
                while j < s.count, alnum(s[j]) { j += 1 }
                if j > i + 2, j < s.count, s[j] == ")" {
                    out += "√" + String(s[(i + 2)..<j])
                    i = j + 1
                    continue
                }
            }
            out.append(s[i])
            i += 1
        }
        return out
    }

    /// "epsilon > 0" -> "ε > 0": nur ganze, kleingeschriebene Woerter (nicht in "Alphabet", "Mutter", "api")
    private static func greek(_ text: String) -> String {
        let s = Array(text)
        var out = "", i = 0
        while i < s.count {
            let c = s[i]
            if c.isASCII, c.isLowercase, i == 0 || !(s[i - 1].isLetter || s[i - 1] == "\\") {
                var j = i
                while j < s.count, asciiLetter(s[j]) { j += 1 }
                if let g = greekWords[String(s[i..<j])], !(j < s.count && s[j].isNumber) {
                    out += g
                    i = j
                    continue
                }
                while j < s.count, s[j].isLetter { j += 1 }      // Wort geht mit Umlaut weiter ("für")
                out += String(s[i..<j])
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    // MARK: Hoch- und Tiefstellung

    /// `x^2`, `x^{10}`, `x^(n+1)`, `a_n`, `a_{i+1}` -> Hoch-/Tiefstellung; jedes Zeichen abbildbar: Unicode (x², aₙ),
    /// sonst mit `rich` Marken fuer echte Hochstellung, ohne `rich` bleibt `^(a+b)`
    private static func scripts(_ text: String, rich: Bool, math: Bool) -> String {
        let s = Array(text)
        let n = s.count
        var out = "", i = 0
        while i < n {
            let c = s[i]
            guard c == "^" || c == "_", i > 0, i + 1 < n, !s[i - 1].isWhitespace, !s[i + 1].isWhitespace else {
                out.append(c)
                i += 1
                continue
            }
            let table = c == "^" ? superscripts : subscripts
            let next = i + 1
            var parenForm = false
            let body: String, end: Int
            if s[next] == "{" {
                guard let g = group(s, next + 1, "{", "}") else { out.append(c); i += 1; continue }
                body = g.text
                end = g.end
            } else if s[next] == "(" {
                // "Funktion_(siehe oben)" ist kein Index: ausserhalb einer Formel ohne Leerzeichen
                guard let g = group(s, next + 1, "(", ")"), math || c == "^" || !g.text.contains(where: { $0.isWhitespace }) else {
                    out.append(c)
                    i += 1
                    continue
                }
                body = g.text
                end = g.end
                parenForm = true
            } else {
                // ohne Klammer: Ziffern (auch mit Vorzeichen), ein Buchstabe oder ein Zeichen wie ∘ und ′
                var j = next
                if signs.contains(s[j]) { j += 1 }
                while j < n, digit(s[j]) { j += 1 }
                if j == next || (j == next + 1 && signs.contains(s[next])) {
                    if j < n, s[j].isLetter {
                        j += 1
                    } else if j == next, table[s[j]] != nil, s[j] != "(", s[j] != ")" {
                        j += 1
                    }
                }
                if j == next { out.append(c); i += 1; continue }
                // mitten in einem Bezeichner (is_int, list_items): kein Index, der Text bleibt
                if !math, c == "_", j < n, s[j].isLetter || s[j] == "_" { out.append(c); i += 1; continue }
                body = String(s[next..<j])
                end = j
            }
            var inner = scripts(body, rich: rich, math: math).trimmingCharacters(in: .whitespacesAndNewlines)
            if parenForm, inner.count == 1 { inner = "(" + inner + ")" }          // f^(n): Ableitung, Klammern bleiben
            if inner.isEmpty { out.append(c); i += 1; continue }
            if inner.allSatisfy({ table[$0] != nil }) {
                out += String(inner.map { table[$0]! })
            } else if rich {
                out.append(c == "^" ? supOpen : subOpen)
                out += inner.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                out.append(scriptClose)
            } else {
                out.append(c)
                out += inner.count == 1 || (parenForm && inner.hasPrefix("(")) ? inner : "(" + inner + ")"
            }
            i = end
        }
        return out
    }

    // MARK: Hilfen

    /// Inhalt einer Klammer ab `start` (direkt hinter der oeffnenden), mit Verschachtelung
    private static func group(_ s: [Character], _ start: Int, _ opening: Character, _ closing: Character) -> (text: String, end: Int)? {
        var depth = 1, i = start
        while i < s.count {
            if s[i] == opening {
                depth += 1
            } else if s[i] == closing {
                depth -= 1
                if depth == 0 { return (String(s[start..<i]), i + 1) }
            }
            i += 1
        }
        return nil
    }

    private static func starts(_ s: [Character], _ prefix: String, at i: Int) -> Bool {
        let p = Array(prefix)
        guard i >= 0, i + p.count <= s.count else { return false }
        for k in 0..<p.count where s[i + k] != p[k] { return false }
        return true
    }

    private static func find(_ s: [Character], _ needle: String, from: Int) -> Int? {
        let p = Array(needle)
        guard let first = p.first else { return nil }
        var i = max(0, from)
        while i + p.count <= s.count {
            if s[i] == first, p.count == 1 || starts(s, needle, at: i) { return i }
            i += 1
        }
        return nil
    }

    private static func digit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    private static func asciiLetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
    private static func alnum(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}
