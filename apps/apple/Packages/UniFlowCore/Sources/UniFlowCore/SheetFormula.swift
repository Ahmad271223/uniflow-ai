import Foundation

/// Tabelle ("Excel", Auftrag des Inhabers 25./26.11.2026): Zellbezuege, Werte und das Rechenwerk fuer Formeln.
/// Alles selbst geschrieben, kein Fremdbaustein (Lizenzpruefung in der Unterlage). Deutsche Schreibweise wie in Excel:
/// `=SUMME(A1:A5)`, Argumente mit `;`, Dezimalkomma - die englischen Namen und der Punkt gehen genauso.

// MARK: - Bezuege

/// Zelle: Spalte und Zeile ab 0 (A1 = 0/0)
public struct SheetRef: Hashable, Sendable, Comparable {
    public var col: Int
    public var row: Int

    public init(col: Int, row: Int) { self.col = col; self.row = row }

    public static func < (a: SheetRef, b: SheetRef) -> Bool { a.row != b.row ? a.row < b.row : a.col < b.col }

    /// 0 → A, 25 → Z, 26 → AA
    public static func colName(_ c: Int) -> String {
        guard c >= 0 else { return "?" }
        var n = c, s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(65 + n % 26))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    public static func colIndex(_ name: String) -> Int? {
        let u = name.uppercased().unicodeScalars
        guard !u.isEmpty, u.count <= 2, u.allSatisfy({ (65...90).contains($0.value) }) else { return nil }
        return u.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }

    public var name: String { SheetRef.colName(col) + "\(row + 1)" }

    /// "B12" (auch "$b$12")
    public init?(_ name: String) {
        guard let t = SheetFormula.RefTok(Array(name.trimmingCharacters(in: .whitespaces))) else { return nil }
        self = t.ref
    }
}

/// Bereich A1:B3, immer von links oben nach rechts unten
public struct SheetRange: Hashable, Sendable {
    public var from: SheetRef
    public var to: SheetRef

    public init(_ a: SheetRef, _ b: SheetRef) {
        from = SheetRef(col: min(a.col, b.col), row: min(a.row, b.row))
        to = SheetRef(col: max(a.col, b.col), row: max(a.row, b.row))
    }

    public init(_ a: SheetRef) { self.init(a, a) }

    public init?(_ name: String) {
        let parts = name.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || parts.count == 2, let a = SheetRef(parts[0]) else { return nil }
        guard parts.count == 2 else { self.init(a); return }
        guard let b = SheetRef(parts[1]) else { return nil }
        self.init(a, b)
    }

    public var name: String { from == to ? from.name : from.name + ":" + to.name }
    public var rows: ClosedRange<Int> { from.row...to.row }
    public var cols: ClosedRange<Int> { from.col...to.col }
    public var count: Int { rows.count * cols.count }
    public func contains(_ r: SheetRef) -> Bool { rows.contains(r.row) && cols.contains(r.col) }

    /// Zellen zeilenweise
    public var refs: [SheetRef] {
        var out: [SheetRef] = []
        out.reserveCapacity(count)
        for r in rows { for c in cols { out.append(SheetRef(col: c, row: r)) } }
        return out
    }
}

// MARK: - Werte

public enum SheetError: String, Error, Sendable, CaseIterable {
    case div0 = "#DIV/0!"
    case value = "#WERT!"
    case name = "#NAME?"
    case ref = "#BEZUG!"
    case cycle = "#ZIRKEL!"
    case num = "#ZAHL!"
    case na = "#NV"
    case syntax = "#FEHLER!"

    /// Erklaerung in einfachen Worten (Anzeige unter der Eingabezeile)
    public var hint: String {
        switch self {
        case .div0: return "Geteilt durch null."
        case .value: return "Hier steht Text, wo eine Zahl gebraucht wird."
        case .name: return "Diese Funktion kenne ich nicht."
        case .ref: return "Die Zelle, auf die die Formel zeigt, gibt es nicht mehr."
        case .cycle: return "Die Formel rechnet mit sich selbst."
        case .num: return "Mit dieser Zahl geht die Rechnung nicht."
        case .na: return "Nichts Passendes gefunden."
        case .syntax: return "Die Formel ist nicht vollständig."
        }
    }
}

public enum SheetValue: Equatable, Sendable {
    case empty
    case number(Double)
    case text(String)
    case bool(Bool)
    case error(SheetError)

    public var isEmpty: Bool { self == .empty }
    public var number: Double? { if case .number(let d) = self { return d }; return nil }
    public var error: SheetError? { if case .error(let e) = self { return e }; return nil }
}

/// Zahlen lesen und schreiben (deutsch: Komma, Punkt als Tausender)
public enum SheetText {
    /// "12,5" "12.5" "1.234,56" "50 %" "3,20 €" → Zahl; `hint`: "p" Prozent, "e" Euro
    public static func parseNumber(_ input: String) -> (value: Double, hint: String?)? {
        var s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var hint: String?
        if s.hasSuffix("%") { hint = "p"; s.removeLast() } else if s.hasSuffix("€") { hint = "e"; s.removeLast() } else if s.hasPrefix("€") { hint = "e"; s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        guard let first = s.unicodeScalars.first, !s.isEmpty else { return nil }
        guard (48...57).contains(first.value) || "+-,.".unicodeScalars.contains(first) else { return nil }
        let hasComma = s.contains(","), hasDot = s.contains(".")
        if hasComma && hasDot {
            // das letzte der beiden Zeichen trennt die Nachkommastellen, das andere die Tausender
            let decimal: Character = s.lastIndex(of: ",")! > s.lastIndex(of: ".")! ? "," : "."
            s.removeAll { $0 == (decimal == "," ? "." : ",") }
            if decimal == "," { s = s.replacingOccurrences(of: ",", with: ".") }
        } else if hasComma {
            guard s.filter({ $0 == "," }).count == 1 else { return nil }
            s = s.replacingOccurrences(of: ",", with: ".")
        } else if hasDot, isGrouped(s) {
            // "1.500" und "1.000.000" sind deutsch geschrieben Tausender (so schreibt die Tabelle sie auch selbst)
            s.removeAll { $0 == "." }
        } else if s.filter({ $0 == "." }).count > 1 {
            return nil
        }
        // nur Ziffern, ein Punkt, Vorzeichen, Exponent - kein "inf", "nan", "0x10"
        let allowed = Set("0123456789.+-eE")
        guard s.allSatisfy({ allowed.contains($0) }), s.contains(where: { $0.isNumber }), let d = Double(s), d.isFinite else { return nil }
        return (hint == "p" ? d / 100 : d, hint)
    }

    /// "1.500", "-12.345.678": ein bis drei Ziffern (nicht mit 0 vorn), dann Dreiergruppen mit Punkt
    static func isGrouped(_ s: String) -> Bool {
        var t = Substring(s)
        if t.hasPrefix("-") || t.hasPrefix("+") { t = t.dropFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let head = parts.first, (1...3).contains(head.count), head.first != "0" else { return false }
        return parts.allSatisfy { $0.allSatisfy { ("0"..."9").contains($0) } } && parts.dropFirst().allSatisfy { $0.count == 3 }
    }

    /// Getippte Zahl, die man so stehen laesst, wie sie getippt wurde: mit Punkt statt Komma ("14.30", "3.14") oder mit
    /// Exponent ("1E3") - gerechnet wird damit, aber aus "14.30" wird in der Anzeige nicht "14,3"
    public static func keepsTyped(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.contains("%") || t.contains("€") { return false }
        if t.contains(where: { $0 == "e" || $0 == "E" }) { return true }
        return t.contains(".") && !t.contains(",") && !isGrouped(t)
    }

    /// Zwei gerechnete Zahlen gelten als gleich, wenn sie sich erst in der 13. Stelle unterscheiden (0,1+0,2 = 0,3)
    public static func same(_ a: Double, _ b: Double) -> Bool {
        a == b || abs(a - b) <= 1e-13 * max(abs(a), abs(b))
    }

    /// Zahl ohne festes Format: ganze Zahlen ohne Komma, sonst bis zu 10 gueltige Stellen
    public static func general(_ d: Double) -> String {
        guard d.isFinite else { return SheetError.num.rawValue }
        if d == d.rounded(), abs(d) < 1e15 { return String(format: "%.0f", d == 0 ? 0 : d) }
        return String(format: "%.10g", d).replacingOccurrences(of: ".", with: ",")
    }

    /// Feste Nachkommastellen, Tausenderpunkt
    public static func fixed(_ d: Double, decimals: Int) -> String {
        guard d.isFinite else { return SheetError.num.rawValue }
        let n = min(6, max(0, decimals))
        // kaufmaennisch runden (12,5 → 13), nicht wie "%.0f" zur geraden Zahl; kleiner Schubs gegen 2,675 = 2,67499999
        let f = pow(10.0, Double(n))
        let rounded = (abs(d) * f * (1 + 1e-12)).rounded() / f
        var s = String(format: "%.\(n)f", rounded.isFinite ? rounded : abs(d))
        var frac = ""
        if let dot = s.firstIndex(of: ".") {
            frac = "," + s[s.index(after: dot)...]
            s = String(s[..<dot])
        }
        var grouped = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0, i % 3 == 0 { grouped.append(".") }
            grouped.append(ch)
        }
        let body = String(grouped.reversed()) + frac
        let zero = !body.contains(where: { $0 != "0" && $0 != "," && $0 != "." })
        return (d < 0 && !zero ? "-" : "") + body
    }

    public static func text(_ v: SheetValue) -> String {
        switch v {
        case .empty: return ""
        case .number(let d): return general(d)
        case .text(let s): return s
        case .bool(let b): return b ? "WAHR" : "FALSCH"
        case .error(let e): return e.rawValue
        }
    }
}

// MARK: - Formeln

public enum SheetFormula {

    /// Bezug in einer Formel, mit `$` fuer "fest"
    struct RefTok: Equatable {
        /// So weit kann eine Formel zeigen (vier Ziffern, zwei Buchstaben) - auch ueber den Rand der Tabelle hinaus
        static let maxRow = 9_999, maxCol = 26 * 27
        var col: Int
        var row: Int
        var absCol = false
        var absRow = false

        var ref: SheetRef { SheetRef(col: col, row: row) }
        var name: String { (absCol ? "$" : "") + SheetRef.colName(col) + (absRow ? "$" : "") + "\(row + 1)" }

        init(col: Int, row: Int, absCol: Bool = false, absRow: Bool = false) {
            self.col = col; self.row = row; self.absCol = absCol; self.absRow = absRow
        }

        /// `$A$1`, `b12`: ein bis zwei Buchstaben, ein bis vier Ziffern
        init?(_ c: [Character]) {
            var i = 0
            func ascii(_ ch: Character) -> UInt8? { ch.asciiValue }
            if i < c.count, c[i] == "$" { absCol = true; i += 1 }
            var letters = ""
            while i < c.count, let a = ascii(c[i]), (65...90).contains(a) || (97...122).contains(a) { letters.append(c[i]); i += 1 }
            guard (1...2).contains(letters.count), let col = SheetRef.colIndex(letters) else { return nil }
            if i < c.count, c[i] == "$" { absRow = true; i += 1 }
            var digits = ""
            while i < c.count, let a = ascii(c[i]), (48...57).contains(a) { digits.append(c[i]); i += 1 }
            guard i == c.count, (1...4).contains(digits.count), let n = Int(digits), n >= 1 else { return nil }
            self.col = col
            self.row = n - 1
        }
    }

    enum Tok: Equatable {
        case num(Double)
        case str(String)
        case ident(String)
        case ref(RefTok)
        case op(String)
        case lparen, rparen, sep, colon
        case err(SheetError)
        case bad
    }

    struct Token: Equatable {
        let tok: Tok
        let start: Int
        let end: Int
    }

    static func isDigit(_ c: Character) -> Bool { c.asciiValue.map { (48...57).contains($0) } ?? false }

    /// Englische Namen, die es deutsch anders gibt (`IF`, `SUM`): Wer so schreibt, trennt meist auch mit Komma
    static let englishOnly: Set<String> = Set(german.values).subtracting(german.keys)

    /// Zerlegt den Teil nach dem `=`. Deutsch trennt `;` und das Komma steht in Zahlen ("1,5"). Formeln in englischer
    /// Schreibweise (`=IF(A1>50,1,0)`, `=SUM(10,20,30)`) trennen mit Komma: Steht kein `;` in der Formel und ist ein
    /// Komma eindeutig Trenner oder der Funktionsname englisch, dann trennt jedes Komma.
    static func tokenize(_ c: [Character]) -> [Token] {
        let first = tokenize(c, commaSeparates: false)
        guard c.contains(","), !first.contains(where: { $0.tok == .sep && c[$0.start] == ";" }) else { return first }
        let commaSep = first.contains { $0.tok == .sep }
        let english = first.enumerated().contains { i, t in
            guard case .ident(let name) = t.tok, i + 1 < first.count, first[i + 1].tok == .lparen else { return false }
            return englishOnly.contains(name)
        }
        return commaSep || english ? tokenize(c, commaSeparates: true) : first
    }

    private static let openQuotes: Set<Character> = ["\"", "„", "“", "”", "«", "»"]

    static func tokenize(_ c: [Character], commaSeparates: Bool) -> [Token] {
        var out: [Token] = []
        var i = 0
        // ausserhalb von Klammern ist ein Komma immer das Dezimalkomma (`=SUM(A1:A3)*1,19`)
        var depth = 0
        func decimalComma() -> Bool { !(commaSeparates && depth > 0) }
        func peek(_ k: Int) -> Character? { i + k < c.count ? c[i + k] : nil }
        while i < c.count {
            let ch = c[i], start = i
            if ch.isWhitespace { i += 1; continue }
            if isDigit(ch) || (((ch == "," && decimalComma()) || ch == ".") && peek(1).map(isDigit) == true && !(out.last.map { endsOperand($0.tok) } ?? false)) {
                var s = ""
                while i < c.count, isDigit(c[i]) { s.append(c[i]); i += 1 }
                // Dezimalkomma oder -punkt nur, wenn eine Ziffer folgt ("1,5"; in "A1;2,B2" trennt das Komma)
                if i + 1 < c.count, (c[i] == "," && decimalComma()) || c[i] == ".", isDigit(c[i + 1]) {
                    s.append(".")
                    i += 1
                    while i < c.count, isDigit(c[i]) { s.append(c[i]); i += 1 }
                }
                if i < c.count, c[i] == "e" || c[i] == "E" {
                    var j = i + 1
                    if j < c.count, c[j] == "+" || c[j] == "-" { j += 1 }
                    if j < c.count, isDigit(c[j]) {
                        s.append("e")
                        if c[i + 1] == "-" { s.append("-") }
                        i = j
                        while i < c.count, isDigit(c[i]) { s.append(c[i]); i += 1 }
                    }
                }
                if s.hasPrefix(".") { s = "0" + s }
                out.append(Token(tok: Double(s).map { $0.isFinite ? Tok.num($0) : .bad } ?? .bad, start: start, end: i))
                continue
            }
            // die iPad-Tastatur macht aus " gern „ und “: gilt genauso
            if openQuotes.contains(ch) {
                var s = ""
                i += 1
                var closed = false
                while i < c.count {
                    if openQuotes.contains(c[i]) {
                        if c[i] == "\"", i + 1 < c.count, c[i + 1] == "\"" { s.append("\""); i += 2; continue }
                        closed = true
                        i += 1
                        break
                    }
                    s.append(c[i])
                    i += 1
                }
                out.append(Token(tok: closed ? .str(s) : .bad, start: start, end: i))
                continue
            }
            if ch.isLetter || ch == "$" || ch == "_" {
                var word: [Character] = []
                while i < c.count {
                    let x = c[i]
                    if x.isLetter || isDigit(x) || x == "_" || x == "$" { word.append(x); i += 1; continue }
                    // "STABW.S": Punkt nur vor einem Buchstaben
                    if x == ".", i + 1 < c.count, c[i + 1].isLetter { word.append(x); i += 1; continue }
                    break
                }
                var j = i
                while j < c.count, c[j].isWhitespace { j += 1 }
                let call = j < c.count && c[j] == "("
                if !call, let r = RefTok(word) {
                    out.append(Token(tok: .ref(r), start: start, end: i))
                } else {
                    out.append(Token(tok: .ident(String(word).uppercased()), start: start, end: i))
                }
                continue
            }
            if ch == "#" {
                var s = "#"
                i += 1
                while i < c.count, c[i].isLetter || isDigit(c[i]) || c[i] == "/" || c[i] == "!" || c[i] == "?" {
                    s.append(c[i]); i += 1
                    if s.hasSuffix("!") || s.hasSuffix("?") { break }
                }
                let e = SheetError(rawValue: s.uppercased()) ?? (s.uppercased() == "#REF!" ? .ref : nil)
                out.append(Token(tok: e.map(Tok.err) ?? .bad, start: start, end: i))
                continue
            }
            i += 1
            switch ch {
            case "(": depth += 1; out.append(Token(tok: .lparen, start: start, end: i))
            case ")": depth = max(0, depth - 1); out.append(Token(tok: .rparen, start: start, end: i))
            case ";", ",": out.append(Token(tok: .sep, start: start, end: i))
            case ":": out.append(Token(tok: .colon, start: start, end: i))
            case "<":
                if i < c.count, c[i] == "=" || c[i] == ">" { let o = "<" + String(c[i]); i += 1; out.append(Token(tok: .op(o), start: start, end: i)) }
                else { out.append(Token(tok: .op("<"), start: start, end: i)) }
            case ">":
                if i < c.count, c[i] == "=" { i += 1; out.append(Token(tok: .op(">="), start: start, end: i)) }
                else { out.append(Token(tok: .op(">"), start: start, end: i)) }
            case "+", "-", "*", "/", "^", "&", "=", "%": out.append(Token(tok: .op(String(ch)), start: start, end: i))
            case "×", "·": out.append(Token(tok: .op("*"), start: start, end: i))
            case "÷": out.append(Token(tok: .op("/"), start: start, end: i))
            case "≤": out.append(Token(tok: .op("<="), start: start, end: i))
            case "≥": out.append(Token(tok: .op(">="), start: start, end: i))
            case "≠": out.append(Token(tok: .op("<>"), start: start, end: i))
            case "−", "–": out.append(Token(tok: .op("-"), start: start, end: i))
            default: out.append(Token(tok: .bad, start: start, end: i))
            }
        }
        return out
    }

    /// Nach diesem Zeichen kann kein neuer Wert anfangen (",5" nach einer Zahl ist ein Trenner, keine ",5")
    private static func endsOperand(_ t: Tok) -> Bool {
        switch t {
        case .num, .str, .ref, .rparen, .err: return true
        case .ident: return true
        case .op(let o): return o == "%"
        default: return false
        }
    }

    // MARK: Baum

    indirect enum Node: Equatable {
        case num(Double)
        case str(String)
        case bool(Bool)
        case err(SheetError)
        case missing
        case ref(SheetRef)
        case range(SheetRange)
        case unary(String, Node)
        case percent(Node)
        case binary(String, Node, Node)
        case call(String, [Node])
    }

    struct Failure: Error { let error: SheetError }

    /// So tief duerfen Klammern und Funktionen ineinander stecken (der Stapel am iPad ist klein)
    static let maxNesting = 40

    private struct Parser {
        let t: [Token]
        var p = 0
        var depth = 0

        var cur: Tok? { p < t.count ? t[p].tok : nil }

        mutating func comparison() throws -> Node {
            var l = try concat()
            while case .op(let o)? = cur, ["=", "<>", "<", ">", "<=", ">="].contains(o) {
                p += 1
                l = .binary(o, l, try concat())
            }
            return l
        }

        mutating func concat() throws -> Node {
            var l = try additive()
            while cur == .op("&") { p += 1; l = .binary("&", l, try additive()) }
            return l
        }

        mutating func additive() throws -> Node {
            var l = try multiplicative()
            while case .op(let o)? = cur, o == "+" || o == "-" { p += 1; l = .binary(o, l, try multiplicative()) }
            return l
        }

        mutating func multiplicative() throws -> Node {
            var l = try power()
            while case .op(let o)? = cur, o == "*" || o == "/" { p += 1; l = .binary(o, l, try power()) }
            return l
        }

        mutating func power() throws -> Node {
            var l = try unary()
            while cur == .op("^") { p += 1; l = .binary("^", l, try unary()) }
            return l
        }

        mutating func unary() throws -> Node {
            // "--5", "-+-5": Vorzeichen der Reihe nach, ohne Verschachtelung
            var negative = false, signs = 0
            while case .op(let o)? = cur, o == "-" || o == "+" {
                p += 1
                signs += 1
                if o == "-" { negative.toggle() }
            }
            if signs > 0 {
                let inner = try unary()
                return negative ? .unary("-", inner) : inner
            }
            var n = try primary()
            while cur == .op("%") { p += 1; n = .percent(n) }
            return n
        }

        mutating func primary() throws -> Node {
            guard let tok = cur else { throw Failure(error: .syntax) }
            p += 1
            depth += 1
            defer { depth -= 1 }
            guard depth <= SheetFormula.maxNesting else { throw Failure(error: .syntax) }
            switch tok {
            case .num(let d): return .num(d)
            case .str(let s): return .str(s)
            case .err(let e): return .err(e)
            case .ref(let a):
                if cur == .colon {
                    guard p + 1 < t.count, case .ref(let b) = t[p + 1].tok else { throw Failure(error: .syntax) }
                    p += 2
                    return .range(SheetRange(a.ref, b.ref))
                }
                return .ref(a.ref)
            case .lparen:
                let n = try comparison()
                guard cur == .rparen else { throw Failure(error: .syntax) }
                p += 1
                return n
            case .ident(let name):
                if cur == .lparen {
                    p += 1
                    var args: [Node] = []
                    if cur == .rparen { p += 1; return .call(name, []) }
                    while true {
                        if cur == .sep || cur == .rparen { args.append(.missing) } else { args.append(try comparison()) }
                        if cur == .sep { p += 1; continue }
                        guard cur == .rparen else { throw Failure(error: .syntax) }
                        p += 1
                        break
                    }
                    return .call(name, args)
                }
                switch name {
                case "WAHR", "TRUE": return .bool(true)
                case "FALSCH", "FALSE": return .bool(false)
                default: throw Failure(error: .name)
                }
            default:
                throw Failure(error: .syntax)
            }
        }
    }

    /// Alle Bezuege eines Formelbaums (einzelne Zellen als Bereich aus einer Zelle)
    static func ranges(in node: Node, _ visit: (SheetRange) -> Void) {
        switch node {
        case .ref(let r): visit(SheetRange(r))
        case .range(let r): visit(r)
        case .unary(_, let x), .percent(let x): ranges(in: x, visit)
        case .binary:
            var cur = node
            while case .binary(_, let l, let r) = cur { ranges(in: r, visit); cur = l }
            ranges(in: cur, visit)
        case .call(_, let args): for a in args { ranges(in: a, visit) }
        default: break
        }
    }

    /// Formel (mit oder ohne `=` am Anfang) lesen
    static func parse(_ formula: String) -> Result<Node, Failure> {
        var c = Array(formula)
        if let f = c.firstIndex(where: { !$0.isWhitespace }), c[f] == "=" { c.removeSubrange(...f) }
        let tokens = tokenize(c)
        if tokens.contains(where: { $0.tok == .bad }) { return .failure(Failure(error: .syntax)) }
        var parser = Parser(t: tokens)
        do {
            let n = try parser.comparison()
            guard parser.p == tokens.count else { return .failure(Failure(error: .syntax)) }
            return .success(n)
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(Failure(error: .syntax))
        }
    }

    public static func isFormula(_ raw: String) -> Bool {
        let t = raw.drop(while: { $0.isWhitespace })
        return t.hasPrefix("=") && t.count > 1
    }

    // MARK: Bezuege umschreiben

    /// Jeden Bezug (einzeln oder Bereich) ersetzen; `nil` heisst: Den Bezug gibt es nicht mehr (`#BEZUG!`). Alles
    /// andere der Formel bleibt Zeichen fuer Zeichen, wie der Nutzer es getippt hat.
    static func rewriting(_ raw: String, _ change: (RefTok, RefTok?) -> (RefTok, RefTok?)?) -> String {
        guard isFormula(raw) else { return raw }
        let all = Array(raw)
        guard let eq = all.firstIndex(of: "=") else { return raw }
        let c = Array(all[(eq + 1)...])
        let t = tokenize(c)
        var out: [Character] = Array(all[...eq])
        var pos = 0, i = 0
        while i < t.count {
            guard case .ref(let a) = t[i].tok else { i += 1; continue }
            var b: RefTok?
            var last = i
            if i + 2 < t.count, t[i + 1].tok == .colon, case .ref(let x) = t[i + 2].tok { b = x; last = i + 2 }
            out.append(contentsOf: c[pos..<t[i].start])
            if let (na, nb) = change(a, b) {
                out.append(contentsOf: na.name)
                if let nb { out.append(":"); out.append(contentsOf: nb.name) }
            } else {
                out.append(contentsOf: SheetError.ref.rawValue)
            }
            pos = t[last].end
            i = last + 1
        }
        out.append(contentsOf: c[pos...])
        return String(out)
    }

    /// Formel an eine andere Stelle kopiert: Bezuege ohne `$` wandern mit
    public static func shifted(_ raw: String, dCol: Int, dRow: Int) -> String {
        func move(_ r: RefTok) -> RefTok? {
            var n = r
            if !r.absCol { n.col += dCol }
            if !r.absRow { n.row += dRow }
            return n.col >= 0 && n.row >= 0 && n.col < RefTok.maxCol && n.row < RefTok.maxRow ? n : nil
        }
        return rewriting(raw) { a, b in
            guard let na = move(a) else { return nil }
            guard let b else { return (na, nil) }
            guard let nb = move(b) else { return nil }
            return (na, nb)
        }
    }

    /// Ausgeschnitten und an anderer Stelle eingefuegt (wie in Excel): Bezuege auf Zellen IM ausgeschnittenen Bereich
    /// `block` wandern mit, Bezuege nach draussen bleiben, wo sie waren. Ein Bereich wandert nur, wenn er ganz im Block liegt.
    public static func moved(_ raw: String, block: SheetRange, dCol: Int, dRow: Int) -> String {
        func move(_ r: RefTok) -> RefTok? {
            var n = r
            n.col += dCol
            n.row += dRow
            return n.col >= 0 && n.row >= 0 && n.col < RefTok.maxCol && n.row < RefTok.maxRow ? n : nil
        }
        return rewriting(raw) { a, b in
            let inside = block.contains(a.ref) && (b.map { block.contains($0.ref) } ?? true)
            guard inside else { return (a, b) }
            guard let na = move(a) else { return nil }
            guard let b else { return (na, nil) }
            guard let nb = move(b) else { return nil }
            return (na, nb)
        }
    }

    /// Zeilen (oder Spalten) eingefuegt (`count > 0`) oder geloescht (`count < 0`) ab `index`
    public static func adjusted(_ raw: String, rows: Bool, at index: Int, count: Int) -> String {
        guard count != 0 else { return raw }
        func get(_ r: RefTok) -> Int { rows ? r.row : r.col }
        func set(_ r: RefTok, _ v: Int) -> RefTok { var n = r; if rows { n.row = v } else { n.col = v }; return n }
        return rewriting(raw) { a, b in
            if count > 0 {
                let limit = (rows ? RefTok.maxRow : RefTok.maxCol) - 1
                func ins(_ r: RefTok) -> RefTok { get(r) >= index ? set(r, min(limit, get(r) + count)) : r }
                return (ins(a), b.map(ins))
            }
            let n = -count, end = index + n        // geloescht: index ..< end
            func del(_ v: Int) -> Int? { v < index ? v : (v >= end ? v - n : nil) }
            guard let b else {
                guard let v = del(get(a)) else { return nil }
                return (set(a, v), nil)
            }
            // Bereich: schrumpft, solange etwas uebrig bleibt
            var lo = min(get(a), get(b)), hi = max(get(a), get(b))
            if lo >= index, hi < end { return nil }
            lo = del(lo) ?? index
            hi = del(hi) ?? index - 1
            guard lo <= hi else { return nil }
            let aFirst = get(a) <= get(b)
            return (set(a, aFirst ? lo : hi), set(b, aFirst ? hi : lo))
        }
    }

    /// Zeile umsortiert: Bezuege auf die eigene Zeile gehen mit (`=B3*C3` bleibt die Rechnung dieser Zeile)
    public static func movedRow(_ raw: String, from: Int, to: Int) -> String {
        guard from != to else { return raw }
        return rewriting(raw) { a, b in
            func mv(_ r: RefTok) -> RefTok { var n = r; if !r.absRow, r.row == from { n.row = to }; return n }
            return (mv(a), b.map(mv))
        }
    }

    /// Zellen, die eine Formel liest (fuer die farbige Anzeige beim Tippen)
    public static func references(_ raw: String) -> [SheetRange] {
        guard isFormula(raw), let eq = raw.firstIndex(of: "=") else { return [] }
        let t = tokenize(Array(raw[raw.index(after: eq)...]))
        var out: [SheetRange] = []
        var i = 0
        while i < t.count {
            if case .ref(let a) = t[i].tok {
                if i + 2 < t.count, t[i + 1].tok == .colon, case .ref(let b) = t[i + 2].tok {
                    out.append(SheetRange(a.ref, b.ref)); i += 3; continue
                }
                out.append(SheetRange(a.ref))
            }
            i += 1
        }
        return out
    }

    // MARK: Funktionen

    /// Deutsche Namen → englischer Name (beide gehen)
    static let german: [String: String] = [
        "SUMME": "SUM", "MITTELWERT": "AVERAGE", "ANZAHL": "COUNT", "ANZAHL2": "COUNTA", "ANZAHLLEEREZELLEN": "COUNTBLANK",
        "PRODUKT": "PRODUCT", "STABW": "STDEV", "STABW.S": "STDEV", "STDEV.S": "STDEV", "STABWN": "STDEVP", "STABW.N": "STDEVP",
        "STDEV.P": "STDEVP", "VARIANZ": "VAR", "VAR.S": "VAR", "VARIANZEN": "VARP", "VAR.P": "VARP", "WENN": "IF",
        "WENNFEHLER": "IFERROR", "UND": "AND", "ODER": "OR", "NICHT": "NOT", "RUNDEN": "ROUND", "ABRUNDEN": "ROUNDDOWN",
        "AUFRUNDEN": "ROUNDUP", "GANZZAHL": "INT", "WURZEL": "SQRT", "POTENZ": "POWER", "REST": "MOD",
        "SUMMEWENN": "SUMIF", "ZÄHLENWENN": "COUNTIF", "ZAEHLENWENN": "COUNTIF", "MITTELWERTWENN": "AVERAGEIF",
        "SVERWEIS": "VLOOKUP", "VERKETTEN": "CONCAT", "TEXTKETTE": "CONCAT", "CONCATENATE": "CONCAT", "LÄNGE": "LEN",
        "LAENGE": "LEN", "LINKS": "LEFT", "RECHTS": "RIGHT", "TEIL": "MID", "GROSS": "UPPER", "KLEIN": "LOWER",
        "GLÄTTEN": "TRIM", "GLAETTEN": "TRIM", "WERT": "VALUE", "ISTLEER": "ISBLANK", "ISTZAHL": "ISNUMBER",
        "ISTTEXT": "ISTEXT", "ISTFEHLER": "ISERROR", "KGRÖSSTE": "LARGE", "KGROESSTE": "LARGE", "KKLEINSTE": "SMALL",
        "RANG": "RANK", "SUMMENPRODUKT": "SUMPRODUCT", "ZÄHLENWENNS": "COUNTIFS", "ZAEHLENWENNS": "COUNTIFS",
        "SUMMEWENNS": "SUMIFS", "MITTELWERTWENNS": "AVERAGEIFS", "WENNS": "IFS", "ISTNV": "ISNA", "WENNNV": "IFNA",
        "VERGLEICH": "MATCH",
    ]

    /// Fuer die Auswahl in der App: Name, Muster zum Einsetzen und eine Zeile Erklaerung
    public static let catalog: [(name: String, pattern: String, hint: String)] = [
        ("SUMME", "SUMME(A1:A5)", "Zählt alle Zahlen zusammen."),
        ("MITTELWERT", "MITTELWERT(A1:A5)", "Der Durchschnitt."),
        ("MIN", "MIN(A1:A5)", "Die kleinste Zahl."),
        ("MAX", "MAX(A1:A5)", "Die größte Zahl."),
        ("ANZAHL", "ANZAHL(A1:A5)", "Wie viele Zahlen es sind."),
        ("ANZAHL2", "ANZAHL2(A1:A5)", "Wie viele Zellen gefüllt sind."),
        ("WENN", "WENN(A1>=50;\"bestanden\";\"nicht bestanden\")", "Prüft etwas und zeigt das eine oder das andere."),
        ("RUNDEN", "RUNDEN(A1;1)", "Rundet auf so viele Stellen nach dem Komma."),
        ("SUMMEWENN", "SUMMEWENN(A1:A5;\">10\";B1:B5)", "Zählt nur zusammen, was zur Bedingung passt."),
        ("ZÄHLENWENN", "ZÄHLENWENN(A1:A5;\"ja\")", "Zählt die Zellen, die zur Bedingung passen."),
        ("MITTELWERTWENN", "MITTELWERTWENN(A1:A5;\">0\")", "Durchschnitt nur der passenden Zellen."),
        ("ZÄHLENWENNS", "ZÄHLENWENNS(A1:A5;\"ja\";B1:B5;\">10\")", "Zählt, was zu allen Bedingungen passt."),
        ("SUMMEWENNS", "SUMMEWENNS(C1:C5;A1:A5;\"ja\";B1:B5;\">10\")", "Zählt zusammen, was zu allen Bedingungen passt."),
        ("SUMMENPRODUKT", "SUMMENPRODUKT(A1:A5;B1:B5)", "Malnehmen und zusammenzählen – etwa Note mal Leistungspunkte."),
        ("MEDIAN", "MEDIAN(A1:A5)", "Der Wert in der Mitte."),
        ("STABW", "STABW(A1:A5)", "Wie stark die Zahlen streuen."),
        ("SVERWEIS", "SVERWEIS(A1;D1:E10;2;FALSCH)", "Sucht einen Wert in einer Liste und holt die Zelle daneben."),
        ("INDEX", "INDEX(A1:C10;2;3)", "Holt die Zelle in Zeile 2, Spalte 3 des Bereichs."),
        ("VERGLEICH", "VERGLEICH(A1;D1:D10;0)", "Sagt, an welcher Stelle der Liste ein Wert steht."),
        ("WENNFEHLER", "WENNFEHLER(A1/B1;0)", "Zeigt etwas anderes, wenn die Rechnung nicht geht."),
        ("WENNS", "WENNS(A1>=90;\"sehr gut\";A1>=50;\"bestanden\";WAHR;\"nicht bestanden\")", "Mehrere Prüfungen nacheinander."),
        ("UND", "UND(A1>0;B1>0)", "Wahr, wenn alles stimmt."),
        ("ODER", "ODER(A1>0;B1>0)", "Wahr, wenn eines stimmt."),
        ("ABS", "ABS(A1)", "Die Zahl ohne Minus."),
        ("WURZEL", "WURZEL(A1)", "Die Wurzel."),
        ("POTENZ", "POTENZ(A1;2)", "Hoch rechnen."),
        ("REST", "REST(A1;2)", "Der Rest beim Teilen."),
        ("GANZZAHL", "GANZZAHL(A1)", "Schneidet die Stellen nach dem Komma ab."),
        ("AUFRUNDEN", "AUFRUNDEN(A1;0)", "Rundet immer nach oben."),
        ("ABRUNDEN", "ABRUNDEN(A1;0)", "Rundet immer nach unten."),
        ("PRODUKT", "PRODUKT(A1:A5)", "Nimmt alle Zahlen miteinander mal."),
        ("KGRÖSSTE", "KGRÖSSTE(A1:A5;2)", "Die zweitgrößte, drittgrößte … Zahl."),
        ("KKLEINSTE", "KKLEINSTE(A1:A5;2)", "Die zweitkleinste, drittkleinste … Zahl."),
        ("RANG", "RANG(A1;A1:A5)", "Der Platz einer Zahl in der Liste."),
        ("VERKETTEN", "VERKETTEN(A1;\" \";B1)", "Hängt Texte aneinander."),
        ("LÄNGE", "LÄNGE(A1)", "Wie viele Zeichen ein Text hat."),
        ("LINKS", "LINKS(A1;3)", "Die ersten Zeichen eines Textes."),
        ("RECHTS", "RECHTS(A1;3)", "Die letzten Zeichen eines Textes."),
        ("TEIL", "TEIL(A1;2;3)", "Zeichen aus der Mitte eines Textes."),
        ("GROSS", "GROSS(A1)", "Alles in Großbuchstaben."),
        ("KLEIN", "KLEIN(A1)", "Alles in Kleinbuchstaben."),
        ("PI", "PI()", "Die Kreiszahl."),
        ("SIN", "SIN(A1)", "Sinus (Winkel im Bogenmaß)."),
        ("COS", "COS(A1)", "Kosinus (Winkel im Bogenmaß)."),
        ("TAN", "TAN(A1)", "Tangens (Winkel im Bogenmaß)."),
        ("EXP", "EXP(A1)", "e hoch die Zahl."),
        ("LN", "LN(A1)", "Natürlicher Logarithmus."),
        ("LOG10", "LOG10(A1)", "Logarithmus zur Basis 10."),
    ]

    // MARK: Rechnen

    enum Arg {
        case one(SheetValue)
        case many(SheetRange, [SheetValue])

        var values: [SheetValue] {
            switch self {
            case .one(let v): return [v]
            case .many(_, let a): return a
            }
        }
    }

    struct Evaluator {
        let cell: (SheetRef) -> SheetValue

        // MARK: Umwandeln

        static func number(_ v: SheetValue) -> Result<Double, SheetError> {
            switch v {
            case .empty: return .success(0)
            case .number(let d): return .success(d)
            case .bool(let b): return .success(b ? 1 : 0)
            case .text(let s): return SheetText.parseNumber(s).map { .success($0.value) } ?? .failure(.value)
            case .error(let e): return .failure(e)
            }
        }

        static func truth(_ v: SheetValue) -> Result<Bool, SheetError> {
            switch v {
            case .empty: return .success(false)
            case .number(let d): return .success(d != 0)
            case .bool(let b): return .success(b)
            case .text(let s):
                switch s.uppercased() {
                case "WAHR", "TRUE": return .success(true)
                case "FALSCH", "FALSE": return .success(false)
                default: return .failure(.value)
                }
            case .error(let e): return .failure(e)
            }
        }

        static func finite(_ d: Double) -> SheetValue { d.isFinite ? .number(d) : .error(.num) }

        /// Ganze Zahl aus einem Argument (Stelle, Spalte, Anzahl); nil bei Unsinn wie 1E20
        static func int(_ d: Double) -> Int? { d.isFinite && abs(d) < 1e9 ? Int(d.rounded(.towardZero)) : nil }

        static let german = Locale(identifier: "de_DE")

        /// Vergleich wie in Excel: Zahlen vor Text vor Wahrheitswerten, Text ohne Gross/Klein
        static func compare(_ a: SheetValue, _ b: SheetValue) -> Int {
            func rank(_ v: SheetValue) -> Int {
                switch v {
                case .empty, .number: return 0
                case .text: return 1
                case .bool: return 2
                case .error: return 3
                }
            }
            var x = a, y = b
            if x.isEmpty, case .text = y { x = .text("") }
            if y.isEmpty, case .text = x { y = .text("") }
            if x.isEmpty, case .bool = y { x = .bool(false) }
            if y.isEmpty, case .bool = x { y = .bool(false) }
            if rank(x) != rank(y) { return rank(x) < rank(y) ? -1 : 1 }
            switch (x, y) {
            case (.text(let s), .text(let t)):
                let r = s.compare(t, options: [.caseInsensitive], locale: Self.german)
                return r == .orderedSame ? 0 : (r == .orderedAscending ? -1 : 1)
            case (.bool(let s), .bool(let t)): return s == t ? 0 : (!s ? -1 : 1)
            default:
                let s = x.number ?? 0, t = y.number ?? 0
                return SheetText.same(s, t) ? 0 : (s < t ? -1 : 1)
            }
        }

        // MARK: Auswerten

        func arg(_ n: Node) -> Arg {
            switch n {
            case .range(let r):
                guard r.count <= Sheet.maxRows * Sheet.maxCols else { return .one(.error(.ref)) }
                return .many(r, r.refs.map(cell))
            case .ref(let r): return .many(SheetRange(r), [cell(r)])
            default: return .one(value(n))
            }
        }

        func value(_ n: Node) -> SheetValue {
            switch n {
            case .num(let d): return .number(d)
            case .str(let s): return .text(s)
            case .bool(let b): return .bool(b)
            case .err(let e): return .error(e)
            case .missing: return .empty
            case .ref(let r): return cell(r)
            case .range(let r): return r.count == 1 ? cell(r.from) : .error(.value)
            case .unary(_, let x):
                switch Self.number(value(x)) {
                case .success(let d): return .number(-d)
                case .failure(let e): return .error(e)
                }
            case .percent(let x):
                switch Self.number(value(x)) {
                case .success(let d): return .number(d / 100)
                case .failure(let e): return .error(e)
                }
            case .binary:
                // "1+2+3+…" haengt links tief ineinander: der Reihe nach rechnen statt hinabzusteigen
                var chain: [(String, Node)] = [], cur = n
                while case .binary(let op, let l, let r) = cur { chain.append((op, r)); cur = l }
                var acc = value(cur)
                for (op, r) in chain.reversed() { acc = binary(op, acc, value(r)) }
                return acc
            case .call(let name, let args):
                let v = call(name, args)
                if case .number(let d) = v, !d.isFinite { return .error(.num) }
                return v
            }
        }

        func binary(_ op: String, _ a: SheetValue, _ b: SheetValue) -> SheetValue {
            if let e = a.error { return .error(e) }
            if let e = b.error { return .error(e) }
            switch op {
            case "&": return .text(SheetText.text(a) + SheetText.text(b))
            case "=": return .bool(Self.compare(a, b) == 0)
            case "<>": return .bool(Self.compare(a, b) != 0)
            case "<": return .bool(Self.compare(a, b) < 0)
            case ">": return .bool(Self.compare(a, b) > 0)
            case "<=": return .bool(Self.compare(a, b) <= 0)
            case ">=": return .bool(Self.compare(a, b) >= 0)
            default: break
            }
            guard case .success(let x) = Self.number(a), case .success(let y) = Self.number(b) else { return .error(.value) }
            switch op {
            case "+": return Self.finite(x + y)
            case "-": return Self.finite(x - y)
            case "*": return Self.finite(x * y)
            case "/": return y == 0 ? .error(.div0) : Self.finite(x / y)
            case "^":
                let p = pow(x, y)
                return p.isNaN ? .error(.num) : Self.finite(p)
            default: return .error(.syntax)
            }
        }

        /// Zahlen aus Argumenten: in Bereichen zaehlen nur Zahlen, einzeln getippte Werte werden umgewandelt
        func numbers(_ args: [Arg]) -> Result<[Double], SheetError> {
            var out: [Double] = []
            for a in args {
                switch a {
                case .many(_, let vs):
                    for v in vs {
                        if let e = v.error { return .failure(e) }
                        if let d = v.number { out.append(d) }
                    }
                case .one(let v):
                    if v.isEmpty { continue }
                    switch Self.number(v) {
                    case .success(let d): out.append(d)
                    case .failure(let e): return .failure(e)
                    }
                }
            }
            return .success(out)
        }

        func scalar(_ a: Arg) -> SheetValue {
            switch a {
            case .one(let v): return v
            case .many(_, let vs): return vs.count == 1 ? vs[0] : .error(.value)
            }
        }

        func call(_ rawName: String, _ nodes: [Node]) -> SheetValue {
            let name = SheetFormula.german[rawName] ?? rawName
            // erst pruefen, dann nur den gewaehlten Zweig rechnen
            switch name {
            case "IF":
                guard (2...3).contains(nodes.count) else { return .error(.syntax) }
                switch Self.truth(value(nodes[0])) {
                case .failure(let e): return .error(e)
                case .success(let t):
                    if t { return value(nodes[1]) }
                    return nodes.count == 3 ? value(nodes[2]) : .bool(false)
                }
            case "IFERROR":
                guard nodes.count == 2 else { return .error(.syntax) }
                let v = value(nodes[0])
                return v.error == nil ? v : value(nodes[1])
            case "IFNA":
                guard nodes.count == 2 else { return .error(.syntax) }
                let v = value(nodes[0])
                return v.error == .na ? value(nodes[1]) : v
            case "IFS":
                guard nodes.count >= 2, nodes.count % 2 == 0 else { return .error(.syntax) }
                for i in stride(from: 0, to: nodes.count, by: 2) {
                    switch Self.truth(value(nodes[i])) {
                    case .failure(let e): return .error(e)
                    case .success(let t): if t { return value(nodes[i + 1]) }
                    }
                }
                return .error(.na)
            default: break
            }
            return apply(name, nodes, nodes.map(arg))
        }

        /// Die eigentliche Funktion, wenn alle Argumente gerechnet sind. Eigene Funktion und nie eingebettet: Ihr
        /// Speicherbedarf auf dem Stapel ist gross und soll nicht je Verschachtelung (`ABS(ABS(…))`) anfallen.
        @inline(never)
        func apply(_ name: String, _ nodes: [Node], _ args: [Arg]) -> SheetValue {
            func num(_ i: Int, _ fallback: Double? = nil) -> Result<Double, SheetError> {
                guard i < args.count, nodes[i] != .missing else { return fallback.map { .success($0) } ?? .failure(.syntax) }
                return Self.number(scalar(args[i]))
            }
            func txt(_ i: Int) -> Result<String, SheetError> {
                guard i < args.count else { return .failure(.syntax) }
                let v = scalar(args[i])
                if let e = v.error { return .failure(e) }
                return .success(SheetText.text(v))
            }
            func one(_ f: (Double) -> SheetValue) -> SheetValue {
                guard args.count == 1 else { return .error(.syntax) }
                switch num(0) {
                case .success(let d): return f(d)
                case .failure(let e): return .error(e)
                }
            }
            func two(_ second: Double? = nil, _ f: (Double, Double) -> SheetValue) -> SheetValue {
                guard (second == nil ? 2...2 : 1...2).contains(args.count) else { return .error(.syntax) }
                guard case .success(let a) = num(0) else { return .error(num(0).failureValue ?? .value) }
                guard case .success(let b) = num(1, second) else { return .error(num(1, second).failureValue ?? .value) }
                return f(a, b)
            }
            func agg(_ f: ([Double]) -> SheetValue) -> SheetValue {
                switch numbers(args) {
                case .success(let n): return f(n)
                case .failure(let e): return .error(e)
                }
            }
            func variance(_ n: [Double], sample: Bool) -> SheetValue {
                let k = Double(n.count) - (sample ? 1 : 0)
                guard k > 0 else { return .error(.div0) }
                let m = n.reduce(0, +) / Double(n.count)
                return .number(n.reduce(0) { $0 + ($1 - m) * ($1 - m) } / k)
            }
            func rounded(_ x: Double, _ digits: Double, _ rule: FloatingPointRoundingRule) -> SheetValue {
                let f = pow(10, digits.rounded(.towardZero))
                guard f.isFinite, f != 0 else { return .error(.num) }
                // 2,675 soll 2,68 werden: kleinen Schubs gegen die Darstellung als 2,67499999
                var scaled = x * f
                // 0,1+0,2 ist im Rechner 0,30000000000000004: was (fast) glatt ist, gilt als glatt - sonst macht
                // AUFRUNDEN daraus 0,4 und ABRUNDEN aus 0,7+0,1 nur 0,7
                if SheetText.same(scaled, scaled.rounded()) { scaled = scaled.rounded() }
                let nudged = rule == .toNearestOrAwayFromZero ? scaled + (scaled >= 0 ? 1 : -1) * abs(scaled) * 1e-12 : scaled
                return Self.finite(nudged.rounded(rule) / f)
            }

            switch name {
            case "SUM": return agg { Self.finite($0.reduce(0, +)) }
            case "PRODUCT": return agg { Self.finite($0.isEmpty ? 0 : $0.reduce(1, *)) }
            case "AVERAGE": return agg { $0.isEmpty ? .error(.div0) : Self.finite($0.reduce(0, +) / Double($0.count)) }
            case "MIN": return agg { .number($0.min() ?? 0) }
            case "MAX": return agg { .number($0.max() ?? 0) }
            case "MEDIAN":
                return agg { n in
                    guard !n.isEmpty else { return .error(.num) }
                    let s = n.sorted(), m = s.count / 2
                    return .number(s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2)
                }
            case "STDEV": return agg { n in
                guard case .number(let v) = variance(n, sample: true) else { return .error(.div0) }
                return .number(v.squareRoot())
            }
            case "STDEVP": return agg { n in
                guard case .number(let v) = variance(n, sample: false) else { return .error(.div0) }
                return .number(v.squareRoot())
            }
            case "VAR": return agg { variance($0, sample: true) }
            case "VARP": return agg { variance($0, sample: false) }
            case "COUNT":
                var k = 0
                for a in args {
                    switch a {
                    case .many(_, let vs): k += vs.filter { $0.number != nil }.count
                    case .one(let v): if case .success = Self.number(v), !v.isEmpty { k += 1 }
                    }
                }
                return .number(Double(k))
            case "COUNTA": return .number(Double(args.flatMap(\.values).filter { !$0.isEmpty }.count))
            case "COUNTBLANK": return .number(Double(args.flatMap(\.values).filter { $0.isEmpty || $0 == .text("") }.count))
            case "AND", "OR":
                guard !args.isEmpty else { return .error(.syntax) }
                var all = true, any = false, seen = false
                for a in args {
                    switch a {
                    case .many(_, let vs):
                        for v in vs {
                            if let e = v.error { return .error(e) }
                            if case .text = v { continue }
                            if v.isEmpty { continue }
                            guard case .success(let t) = Self.truth(v) else { continue }
                            seen = true; all = all && t; any = any || t
                        }
                    case .one(let v):
                        switch Self.truth(v) {
                        case .success(let t): seen = true; all = all && t; any = any || t
                        case .failure(let e): return .error(e)
                        }
                    }
                }
                guard seen else { return .error(.value) }
                return .bool(name == "AND" ? all : any)
            case "NOT":
                guard args.count == 1 else { return .error(.syntax) }
                switch Self.truth(scalar(args[0])) {
                case .success(let t): return .bool(!t)
                case .failure(let e): return .error(e)
                }
            case "ROUND": return two(0) { rounded($0, $1, .toNearestOrAwayFromZero) }
            case "ROUNDDOWN": return two(0) { rounded($0, $1, .towardZero) }
            case "ROUNDUP": return two(0) { rounded($0, $1, .awayFromZero) }
            case "INT": return one { .number((SheetText.same($0, $0.rounded()) ? $0.rounded() : $0).rounded(.down)) }
            case "ABS": return one { .number(abs($0)) }
            case "SQRT": return one { $0 < 0 ? .error(.num) : .number($0.squareRoot()) }
            case "POWER": return two { let p = pow($0, $1); return p.isNaN ? .error(.num) : Self.finite(p) }
            case "MOD": return two { $1 == 0 ? .error(.div0) : Self.finite($0 - $1 * ($0 / $1).rounded(.down)) }
            case "EXP": return one { Self.finite(exp($0)) }
            case "LN": return one { $0 <= 0 ? .error(.num) : .number(log($0)) }
            case "LOG10": return one { $0 <= 0 ? .error(.num) : .number(log10($0)) }
            case "LOG": return two(10) { $0 <= 0 || $1 <= 0 || $1 == 1 ? .error(.num) : .number(log($0) / log($1)) }
            case "PI": return args.isEmpty ? .number(Double.pi) : .error(.syntax)
            case "SIN": return one { .number(sin($0)) }
            case "COS": return one { .number(cos($0)) }
            case "TAN": return one { Self.finite(tan($0)) }
            case "SUMIF", "AVERAGEIF", "COUNTIF":
                guard name == "COUNTIF" ? args.count == 2 : (2...3).contains(args.count) else { return .error(.syntax) }
                let test = Criterion(scalar(args[1]))
                let source = args[0].values
                let target = args.count == 3 ? args[2].values : source
                var sum = 0.0, k = 0
                for (i, v) in source.enumerated() where test.matches(v) {
                    if name == "COUNTIF" { k += 1; continue }
                    guard i < target.count else { continue }
                    if let e = target[i].error { return .error(e) }
                    if let d = target[i].number { sum += d; k += 1 }
                }
                if name == "COUNTIF" { return .number(Double(k)) }
                if name == "SUMIF" { return Self.finite(sum) }
                return k == 0 ? .error(.div0) : Self.finite(sum / Double(k))
            case "COUNTIFS", "SUMIFS", "AVERAGEIFS":
                // SUMMEWENNS(Summenbereich; Bereich1; Bedingung1; …), ZÄHLENWENNS(Bereich1; Bedingung1; …)
                let first = name == "COUNTIFS" ? 0 : 1
                guard args.count > first, (args.count - first) % 2 == 0 else { return .error(.syntax) }
                let pairs = stride(from: first, to: args.count, by: 2).map { (args[$0].values, Criterion(scalar(args[$0 + 1]))) }
                let n = pairs[0].0.count
                guard pairs.allSatisfy({ $0.0.count == n }) else { return .error(.value) }
                let target = name == "COUNTIFS" ? [] : args[0].values
                guard name == "COUNTIFS" || target.count == n else { return .error(.value) }
                var sum = 0.0, k = 0
                for i in 0..<n where pairs.allSatisfy({ $0.1.matches($0.0[i]) }) {
                    if name == "COUNTIFS" { k += 1; continue }
                    if let e = target[i].error { return .error(e) }
                    if let d = target[i].number { sum += d; k += 1 }
                }
                if name == "COUNTIFS" { return .number(Double(k)) }
                if name == "SUMIFS" { return Self.finite(sum) }
                return k == 0 ? .error(.div0) : Self.finite(sum / Double(k))
            case "SUMPRODUCT":
                guard !args.isEmpty else { return .error(.syntax) }
                let lists = args.map(\.values)
                guard lists.allSatisfy({ $0.count == lists[0].count }) else { return .error(.value) }
                var sum = 0.0
                for i in 0..<lists[0].count {
                    var p = 1.0
                    for l in lists {
                        if let e = l[i].error { return .error(e) }
                        p *= l[i].number ?? 0
                    }
                    sum += p
                }
                return Self.finite(sum)
            case "LARGE", "SMALL":
                guard args.count == 2 else { return .error(.syntax) }
                guard case .success(let kD) = num(1) else { return .error(num(1).failureValue ?? .value) }
                guard case .success(let n) = numbers([args[0]]) else { return .error(numbers([args[0]]).failureValue ?? .value) }
                guard let k = Self.int(kD), k >= 1, k <= n.count else { return .error(.num) }
                let s = n.sorted()
                return .number(name == "LARGE" ? s[s.count - k] : s[k - 1])
            case "RANK":
                guard (2...3).contains(args.count) else { return .error(.syntax) }
                guard case .success(let x) = num(0) else { return .error(num(0).failureValue ?? .value) }
                guard case .success(let order) = num(2, 0) else { return .error(num(2, 0).failureValue ?? .value) }
                guard case .success(let n) = numbers([args[1]]) else { return .error(numbers([args[1]]).failureValue ?? .value) }
                guard n.contains(where: { SheetText.same($0, x) }) else { return .error(.na) }
                return .number(Double(n.filter { !SheetText.same($0, x) && (order == 0 ? $0 > x : $0 < x) }.count + 1))
            case "VLOOKUP":
                guard (3...4).contains(args.count), case .many(let range, let vs) = args[1] else { return .error(.syntax) }
                guard case .success(let colD) = num(2) else { return .error(num(2).failureValue ?? .value) }
                let key = scalar(args[0])
                if let e = key.error { return .error(e) }
                var approx = true
                if args.count == 4, nodes[3] != .missing {
                    guard case .success(let t) = Self.truth(scalar(args[3])) else { return .error(.value) }
                    approx = t
                }
                let width = range.cols.count
                guard let col = Self.int(colD), col >= 1, col <= width else { return .error(.ref) }
                var found: Int?
                for r in 0..<range.rows.count {
                    let v = vs[r * width]
                    if v.isEmpty { continue }
                    let c = Self.compare(v, key)
                    if c == 0 { found = r; break }
                    if approx { if c < 0 { found = r } else { break } }
                }
                guard let row = found else { return .error(.na) }
                return vs[row * width + col - 1]
            case "INDEX":
                guard (2...3).contains(args.count), case .many(let range, let vs) = args[0] else { return .error(.syntax) }
                guard case .success(let aD) = num(1, 1) else { return .error(num(1, 1).failureValue ?? .value) }
                guard case .success(let bD) = num(2, 1) else { return .error(num(2, 1).failureValue ?? .value) }
                guard var row = Self.int(aD), var col = Self.int(bD) else { return .error(.ref) }
                // eine einzelne Zeile: die eine Zahl meint die Spalte
                if range.rows.count == 1, args.count == 2 { col = row; row = 1 }
                guard row >= 1, col >= 1, row <= range.rows.count, col <= range.cols.count else { return .error(.ref) }
                return vs[(row - 1) * range.cols.count + col - 1]
            case "MATCH":
                guard (2...3).contains(args.count), case .many(let range, let vs) = args[1] else { return .error(.syntax) }
                guard range.rows.count == 1 || range.cols.count == 1 else { return .error(.na) }
                let key = scalar(args[0])
                if let e = key.error { return .error(e) }
                guard case .success(let kind) = num(2, 1) else { return .error(num(2, 1).failureValue ?? .value) }
                var found: Int?
                for (i, v) in vs.enumerated() where !v.isEmpty && v.error == nil {
                    let c = Self.compare(v, key)
                    if c == 0 { found = i; break }
                    if kind > 0 { if c < 0 { found = i } else { break } }       // aufsteigend: der letzte, der kleiner ist
                    if kind < 0 { if c > 0 { found = i } else { break } }       // absteigend: der letzte, der groesser ist
                }
                return found.map { .number(Double($0 + 1)) } ?? .error(.na)
            case "CONCAT":
                var s = ""
                for v in args.flatMap(\.values) {
                    if let e = v.error { return .error(e) }
                    s += SheetText.text(v)
                }
                return .text(s)
            case "LEN", "UPPER", "LOWER", "TRIM", "VALUE":
                guard args.count == 1 else { return .error(.syntax) }
                guard case .success(let s) = txt(0) else { return .error(txt(0).failureValue ?? .value) }
                switch name {
                case "LEN": return .number(Double(s.count))
                case "UPPER": return .text(s.uppercased())
                case "LOWER": return .text(s.lowercased())
                case "TRIM": return .text(s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
                default: return SheetText.parseNumber(s).map { .number($0.value) } ?? .error(.value)
                }
            case "LEFT", "RIGHT":
                guard (1...2).contains(args.count) else { return .error(.syntax) }
                guard case .success(let s) = txt(0) else { return .error(txt(0).failureValue ?? .value) }
                guard case .success(let nD) = num(1, 1) else { return .error(num(1, 1).failureValue ?? .value) }
                guard nD >= 0 else { return .error(.value) }
                let n = Int(min(nD, 100_000))
                return .text(name == "LEFT" ? String(s.prefix(n)) : String(s.suffix(n)))
            case "MID":
                guard args.count == 3 else { return .error(.syntax) }
                guard case .success(let s) = txt(0) else { return .error(txt(0).failureValue ?? .value) }
                guard case .success(let a) = num(1) else { return .error(num(1).failureValue ?? .value) }
                guard case .success(let nD) = num(2) else { return .error(num(2).failureValue ?? .value) }
                guard a >= 1, nD >= 0 else { return .error(.value) }
                return .text(String(s.dropFirst(Int(min(a, 100_000)) - 1).prefix(Int(min(nD, 100_000)))))
            case "ISBLANK": return args.count == 1 ? .bool(scalar(args[0]).isEmpty) : .error(.syntax)
            case "ISNUMBER": return args.count == 1 ? .bool(scalar(args[0]).number != nil) : .error(.syntax)
            case "ISTEXT":
                guard args.count == 1 else { return .error(.syntax) }
                if case .text = scalar(args[0]) { return .bool(true) }
                return .bool(false)
            case "ISERROR": return args.count == 1 ? .bool(scalar(args[0]).error != nil) : .error(.syntax)
            case "ISNA": return args.count == 1 ? .bool(scalar(args[0]).error == .na) : .error(.syntax)
            default: return .error(.name)
            }
        }
    }

    /// Bedingung von SUMMEWENN / ZÄHLENWENN: ">10", "<>ja", "a*", 5
    struct Criterion {
        var op = "="
        var number: Double?
        var text = ""
        var any = false

        init(_ v: SheetValue) {
            switch v {
            case .number(let d): number = d
            case .bool(let b): text = b ? "WAHR" : "FALSCH"
            case .empty: text = ""
            case .error: any = false; op = "!"
            case .text(let s):
                var rest = Substring(s)
                for o in [">=", "<=", "<>", ">", "<", "="] where rest.hasPrefix(o) {
                    op = o
                    rest = rest.dropFirst(o.count)
                    break
                }
                if let n = SheetText.parseNumber(String(rest)) { number = n.value } else { text = String(rest) }
            }
        }

        func matches(_ v: SheetValue) -> Bool {
            if op == "!" { return false }
            if let n = number {
                // die Zahl 5 trifft auch den Text "5" (nur bei gleich/ungleich, wie in Excel)
                var typed: Double?
                if case .text(let s) = v, op == "=" || op == "<>" { typed = SheetText.parseNumber(s)?.value }
                guard let d = v.number ?? typed else { return op == "<>" }
                switch op {
                case "=": return SheetText.same(d, n)
                case "<>": return !SheetText.same(d, n)
                case ">": return d > n
                case "<": return d < n
                case ">=": return d > n || SheetText.same(d, n)
                default: return d < n || SheetText.same(d, n)
                }
            }
            if v.error != nil { return false }
            let s = SheetText.text(v)
            // "1*" meint Text, der mit 1 anfaengt - nicht die Zahl 12
            if case .number = v, text.contains("*") || text.contains("?") { return op == "<>" }
            switch op {
            case "=": return Self.wildcard(text, s)
            case "<>": return !Self.wildcard(text, s)
            default:
                guard case .text = v else { return false }
                let c = Evaluator.compare(v, .text(text))
                return op == ">" ? c > 0 : op == "<" ? c < 0 : op == ">=" ? c >= 0 : c <= 0
            }
        }

        /// `*` beliebig viele Zeichen, `?` genau eines; ohne Gross/Klein
        static func wildcard(_ pattern: String, _ text: String) -> Bool {
            let p = Array(pattern.lowercased()), t = Array(text.lowercased())
            guard p.contains("*") || p.contains("?") else { return p == t }
            var pi = 0, ti = 0, star = -1, mark = 0
            while ti < t.count {
                if pi < p.count, p[pi] == "?" || p[pi] == t[ti] { pi += 1; ti += 1 }
                else if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
                else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
                else { return false }
            }
            while pi < p.count, p[pi] == "*" { pi += 1 }
            return pi == p.count
        }
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e }; return nil }
}
