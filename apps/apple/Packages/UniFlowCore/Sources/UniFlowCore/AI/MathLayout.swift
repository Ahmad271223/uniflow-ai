import Foundation

/// Block-Formel als Baum fuer die gesetzte Darstellung (18.11.2026, Antwortstil wie ChatGPT): Brueche uebereinander,
/// Hochzahlen, Wurzeln, Kaesten (`\boxed`), Klammern in Formelhoehe. Die App zeichnet den Baum mit SwiftUI
/// (`MathFormulaView`), ganz ohne Web-Ansicht, Skripte oder Netz. Der Umfang ist das, was KI-Antworten in Mathe,
/// Elektrotechnik und Informatik brauchen; alles Unbekannte bleibt als Text stehen, nichts geht verloren.
public indirect enum MathNode: Equatable, Sendable {
    /// Folge von Teilen nebeneinander
    case row([MathNode])
    /// Variable (kursiv): x, y, i, α
    case ident(String)
    case number(String)
    /// aufrechtes Zeichen ohne Abstand: Klammern, Komma, ∞, Vorzeichen
    case symbol(String)
    /// Rechen- oder Vergleichszeichen mit Abstand links und rechts: + − = · × ≤ →
    case op(String)
    /// aufrechter Text: \text{…}, Funktionsnamen (sin, lim)
    case text(String)
    case frac(MathNode, MathNode)
    case scripts(MathNode, sup: MathNode?, sub: MathNode?)
    case sqrt(MathNode, index: MathNode?)
    /// Ergebnis im Kasten
    case boxed(MathNode)
    /// \left( … \right): Klammern so hoch wie der Inhalt ("" = keine)
    case fenced(String, MathNode, String)
    /// Abstand in em
    case space(Double)

    /// hoeher als eine Textzeile (Bruch darin): Klammern und Wurzel werden dann gezeichnet statt geschrieben
    public var isTall: Bool {
        switch self {
        case .frac: return true
        case .row(let xs): return xs.contains { $0.isTall }
        case .scripts(let b, _, _): return b.isTall
        case .sqrt(let b, _), .boxed(let b): return b.isTall
        case .fenced(_, let b, _): return b.isTall
        default: return false
        }
    }

    /// lesbarer Text (Barrierefreiheit, Kopieren): (3+4i)/(1−2i), x², √2
    public var plain: String {
        switch self {
        case .row(let xs): return xs.map(\.plain).joined()
        case .ident(let s), .number(let s), .symbol(let s), .text(let s): return s
        case .op(let s): return " \(s) "
        case .frac(let a, let b): return "\(Self.wrapped(a))/\(Self.wrapped(b))"
        case .scripts(let b, let sup, let sub):
            return b.plain + (sub.map { Self.script($0, MathText.subscripts, "_") } ?? "") + (sup.map { Self.script($0, MathText.superscripts, "^") } ?? "")
        case .sqrt(let b, let index): return (index.map { "\($0.plain)" } ?? "") + "√" + Self.wrapped(b)
        case .boxed(let b): return b.plain
        case .fenced(let l, let b, let r): return l + b.plain + r
        case .space(let em): return em >= 0.5 ? "  " : (em > 0 ? " " : "")
        }
    }

    /// Hoch-/Tiefstellung als Unicode (², ₁), sonst ^(…) bzw. _(…)
    private static func script(_ n: MathNode, _ table: [Character: Character], _ mark: String) -> String {
        let p = n.plain.replacingOccurrences(of: " ", with: "")
        let mapped = p.compactMap { table[$0] }
        return mapped.count == p.count && !p.isEmpty ? String(mapped) : mark + (p.count == 1 ? p : "(\(p))")
    }

    private static func wrapped(_ n: MathNode) -> String {
        let p = n.plain.trimmingCharacters(in: .whitespaces)
        return MathText.isAtom(p) ? p : "(\(p))"
    }
}

public enum MathLayout {
    /// LaTeX einer Block-Formel (ohne `$$`) -> Zeilen (getrennt an `\\`); nil ohne Inhalt
    public static func parse(_ latex: String) -> [MathNode]? {
        var p = Parser(Array(MathText.repairEscapes(latex)))
        let lines = p.lines().map(simplify).filter { $0 != .row([]) }
        return lines.isEmpty ? nil : lines
    }

    /// Einzelne Zeile: alle Zeilen nebeneinander (fuer Inline-Formeln)
    public static func parseLine(_ latex: String) -> MathNode? {
        guard let lines = parse(latex) else { return nil }
        return lines.count == 1 ? lines[0] : .row(Array(lines.map { [$0, .space(1)] }.joined().dropLast()))
    }

    /// Zwischenspeicher fuer haeufige Formeln (die Antwort wird beim Scrollen oft neu gezeichnet)
    private static let cache = NSCache<NSString, Box>()
    private final class Box { let lines: [MathNode]?; init(_ l: [MathNode]?) { lines = l } }

    public static func cachedParse(_ latex: String) -> [MathNode]? {
        if let hit = cache.object(forKey: latex as NSString) { return hit.lines }
        let lines = parse(latex)
        cache.setObject(Box(lines), forKey: latex as NSString)
        return lines
    }

    static func simplify(_ n: MathNode) -> MathNode {
        switch n {
        case .row(let xs):
            let inner = xs.map(simplify)
            return inner.count == 1 ? inner[0] : .row(inner)
        case .frac(let a, let b): return .frac(simplify(a), simplify(b))
        case .scripts(let b, let sup, let sub): return .scripts(simplify(b), sup: sup.map(simplify), sub: sub.map(simplify))
        case .sqrt(let b, let i): return .sqrt(simplify(b), index: i.map(simplify))
        case .boxed(let b): return .boxed(simplify(b))
        case .fenced(let l, let b, let r): return .fenced(l, simplify(b), r)
        default: return n
        }
    }

    // MARK: - Zeichenklassen

    /// Zeichen mit Abstand (binaer bzw. Relation)
    static let operators: Set<String> = ["+", "−", "=", "<", ">", "·", "×", "÷", "±", "∓", "≤", "≥", "≠", "≈", "≡", "∼", "≃",
                                         "≅", "∝", "≪", "≫", "→", "←", "⇒", "⇐", "⇔", "↔", "↦", "⟶", "⟹", "∈", "∉", "⊂",
                                         "⊆", "⊃", "⊇", "∪", "∩", "∖", "∧", "∨", "⊕", "⊗", "∘", "≔", ":="]
    static let blackboard: [String: String] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ", "E": "𝔼", "K": "𝕂"]
    static let accents: [String: String] = ["hat": "\u{0302}", "widehat": "\u{0302}", "bar": "\u{0305}", "overline": "\u{0305}",
                                            "tilde": "\u{0303}", "widetilde": "\u{0303}", "dot": "\u{0307}", "ddot": "\u{0308}",
                                            "vec": "\u{20D7}", "overrightarrow": "\u{20D7}"]
    static let spaces: [String: Double] = ["quad": 1, "qquad": 2, "enspace": 0.5, "thinspace": 0.17, "medspace": 0.22,
                                           "thickspace": 0.28]
    /// Befehle ohne Zeichen
    static let ignored: Set<String> = ["displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "nonumber", "notag",
                                       "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl",
                                       "Biggr", "middle", "label", "tag", "phantom", "hphantom", "vphantom", "mathstrut", "strut"]

    // MARK: - Parser

    struct Parser {
        let s: [Character]
        var i = 0

        init(_ s: [Character]) { self.s = s }

        var atEnd: Bool { i >= s.count }
        func peek(_ k: Int = 0) -> Character? { i + k < s.count ? s[i + k] : nil }

        /// ganze Formel in Zeilen
        mutating func lines() -> [MathNode] {
            var out: [MathNode] = []
            var current: [MathNode] = []
            while true {
                let (row, stop) = parseRow(top: true)
                current += row
                switch stop {
                case .lineBreak:
                    out.append(.row(current)); current = []
                case .brace:                                     // ueberzaehlige } ueberspringen
                    i += 1
                case .right:                                     // \right ohne \left: samt Klammer weg
                    i += 1 + "right".count
                    skipSpaces()
                    _ = delimiter()
                case .end, .bracket:
                    out.append(.row(current))
                    return out
                }
            }
        }

        enum Stop { case end, brace, right, lineBreak, bracket }

        /// Teile bis zum Ende, `}` (verbraucht nicht), `\right` (verbraucht nicht) oder `\\` (nur `top`, verbraucht)
        mutating func parseRow(top: Bool = false, untilBracket: Bool = false) -> ([MathNode], Stop) {
            var out: [MathNode] = []
            while let c = peek() {
                if c == "}" { return (out, .brace) }
                if untilBracket, c == "]" { return (out, .bracket) }
                if c == "\\", peek(1) == "\\" {
                    i += 2
                    if top { return (out, .lineBreak) }
                    out.append(.space(1))
                    continue
                }
                if c == "\\", lookingAtCommand("right") { return (out, .right) }
                if c == "^" || c == "_" {
                    i += 1
                    let arg = parseArgument()
                    attach(&out, arg, sup: c == "^")
                    continue
                }
                if let n = parseAtom(previous: out.last) { append(&out, n) }
            }
            return (out, .end)
        }

        func lookingAtCommand(_ name: String) -> Bool {
            guard peek() == "\\" else { return false }
            let chars = Array(name)
            for (k, ch) in chars.enumerated() where peek(1 + k) != ch { return false }
            if let after = peek(1 + chars.count), after.isLetter { return false }
            return true
        }

        mutating func append(_ out: inout [MathNode], _ n: MathNode) {
            // Vorzeichen: + oder − am Anfang, nach einem Rechenzeichen, einer oeffnenden Klammer oder einem Komma
            if case .op(let o) = n, o == "−" || o == "+" || o == "±" {
                let unary: Bool
                switch out.last {
                case nil: unary = true
                case .op?: unary = true
                case .symbol(let x)?: unary = ["(", "[", "{", ",", ";", "|", "⟨"].contains(x)
                default: unary = false
                }
                if unary { out.append(.symbol(o)); return }
            }
            out.append(n)
        }

        mutating func attach(_ out: inout [MathNode], _ arg: MathNode, sup: Bool) {
            let base = out.popLast() ?? .row([])
            if case .scripts(let b, let up, let down) = base {
                if sup, up == nil { out.append(.scripts(b, sup: arg, sub: down)); return }
                if !sup, down == nil { out.append(.scripts(b, sup: up, sub: arg)); return }
            }
            out.append(sup ? .scripts(base, sup: arg, sub: nil) : .scripts(base, sup: nil, sub: arg))
        }

        mutating func skipSpaces() { while let c = peek(), c == " " || c == "\n" || c == "\t" { i += 1 } }

        /// Argument eines Befehls bzw. von ^/_: {Gruppe}, ein Befehl oder ein Zeichen
        mutating func parseArgument() -> MathNode {
            skipSpaces()
            guard let c = peek() else { return .row([]) }
            if c == "{" {
                i += 1
                let (row, _) = parseRow()
                if peek() == "}" { i += 1 }
                return .row(row)
            }
            if c == "\\" { return parseAtom(previous: nil) ?? .row([]) }
            i += 1
            return classify(c)
        }

        /// Text einer {Gruppe} ohne Umformung (\text{…})
        mutating func rawGroup() -> String {
            skipSpaces()
            guard peek() == "{" else {
                if let c = peek() { i += 1; return String(c) }
                return ""
            }
            i += 1
            var depth = 1
            var out = ""
            while let c = peek() {
                i += 1
                if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { break } }
                out.append(c)
            }
            return out
        }

        mutating func parseAtom(previous: MathNode?) -> MathNode? {
            guard let c = peek() else { return nil }
            if c == " " || c == "\n" || c == "\t" || c == "&" { i += 1; return nil }
            if c == "~" { i += 1; return .space(0.33) }
            if c == "{" {
                i += 1
                let (row, _) = parseRow()
                if peek() == "}" { i += 1 }
                return .row(row)
            }
            if c == "\\" { return parseCommand() }
            if c.isNumber {
                var num = ""
                while let d = peek(), d.isNumber || ((d == "." || d == ",") && peek(1)?.isNumber == true && !num.isEmpty) {
                    num.append(d); i += 1
                }
                return .number(num)
            }
            i += 1
            return classify(c)
        }

        func classify(_ c: Character) -> MathNode {
            switch c {
            case "-", "−": return .op("−")
            case "*": return .op("·")
            case "'": return .symbol("′")
            case ":": return peek() == "=" ? .symbol(":") : .op(":")
            default:
                let s = String(c)
                if MathLayout.operators.contains(s) { return .op(s) }
                if c.isLetter { return .ident(s) }
                if c.isNumber { return .number(s) }
                return .symbol(s)
            }
        }

        /// Befehl ab `\`
        mutating func parseCommand() -> MathNode? {
            i += 1                                               // Backslash
            guard let n = peek() else { return .symbol("\\") }
            if !n.isLetter {
                i += 1
                switch n {
                case ",": return .space(0.17)
                case ":", ">": return .space(0.22)
                case ";": return .space(0.28)
                case " ": return .space(0.25)
                case "!": return nil
                case "{": return .symbol("{")
                case "}": return .symbol("}")
                case "|": return .symbol("‖")
                default: return .symbol(String(n))
                }
            }
            var name = ""
            while let ch = peek(), ch.isLetter { name.append(ch); i += 1 }
            switch name {
            case "frac", "dfrac", "tfrac", "cfrac":
                let a = parseArgument(), b = parseArgument()
                return .frac(a, b)
            case "binom", "dbinom", "tbinom":
                let a = parseArgument(), b = parseArgument()
                return .fenced("(", .row([a, .text(" über "), b]), ")")
            case "sqrt":
                skipSpaces()
                var index: MathNode?
                if peek() == "[" {
                    i += 1
                    let (row, _) = parseRow(untilBracket: true)
                    if peek() == "]" { i += 1 }
                    index = .row(row)
                }
                return .sqrt(parseArgument(), index: index)
            case "boxed", "fbox", "framebox":
                return .boxed(parseArgument())
            case "text", "textrm", "textnormal", "mbox", "textup", "textit", "textbf", "textsf", "texttt", "emph":
                return .text(rawGroup())
            case "operatorname", "mathrm":
                let t = rawGroup()
                return t.count == 1 ? .symbol(t) : .text(t)
            case "mathbf", "mathit", "boldsymbol", "bm", "mathcal", "mathscr", "mathfrak", "mathsf", "mathtt", "underline":
                return parseArgument()
            case "mathbb":
                let t = rawGroup()
                return .symbol(MathLayout.blackboard[t] ?? t)
            case "left":
                skipSpaces()
                let open = delimiter()
                let (row, stop) = parseRow()
                var close = ""
                if stop == .right {
                    i += 1 + "right".count
                    skipSpaces()
                    close = delimiter()
                }
                return .fenced(open, .row(row), close)
            case "right":
                skipSpaces()
                _ = delimiter()
                return nil
            case "begin", "end":
                let env = rawGroup()
                if name == "begin", env.hasPrefix("array") || env.hasPrefix("tabular") {
                    skipSpaces()
                    if peek() == "{" { _ = rawGroup() }
                }
                if env == "cases" { return name == "begin" ? .symbol("{") : nil }
                if env.hasSuffix("matrix") { return .symbol(name == "begin" ? (env.hasPrefix("b") ? "[" : "(") : (env.hasPrefix("b") ? "]" : ")")) }
                return nil
            case "color":
                _ = rawGroup()
                return nil
            case "textcolor":
                _ = rawGroup()
                return parseArgument()
            default:
                if MathLayout.ignored.contains(name) { return nil }
                if let em = MathLayout.spaces[name] { return .space(em) }
                if let mark = MathLayout.accents[name] {
                    let arg = parseArgument()
                    switch arg {
                    case .ident(let x): return .ident(x + mark)
                    case .row(let xs) where xs.count == 1: if case .ident(let x) = xs[0] { return .ident(x + mark) }; return arg
                    default: return arg
                    }
                }
                guard let sym = MathText.symbol(name) else { return .text(name) }
                if sym.isEmpty { return nil }
                if sym.trimmingCharacters(in: .whitespaces).isEmpty { return .space(Double(sym.count)) }
                if MathLayout.operators.contains(sym) { return .op(sym) }
                if sym.count > 1 { return .text(sym) }                           // sin, lim, ggT
                if let ch = sym.first, ch.isLetter, ch.isLowercase { return .ident(sym) }   // griechisch klein
                return .symbol(sym)
            }
        }

        /// Klammer hinter \left bzw. \right: ( [ \{ | \| \langle . (keine)
        mutating func delimiter() -> String {
            guard let c = peek() else { return "" }
            if c == "\\" {
                i += 1
                if let n = peek(), !n.isLetter {
                    i += 1
                    switch n { case "{": return "{"; case "}": return "}"; case "|": return "‖"; default: return String(n) }
                }
                var name = ""
                while let ch = peek(), ch.isLetter { name.append(ch); i += 1 }
                return MathText.symbol(name) ?? ""
            }
            i += 1
            return c == "." ? "" : String(c)
        }
    }
}
