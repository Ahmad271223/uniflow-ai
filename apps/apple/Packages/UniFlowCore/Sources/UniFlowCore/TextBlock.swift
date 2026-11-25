import Foundation

/// Textbloecke im Dokument ("wie Word", Auftrag des Inhabers 25.11.2026): getippter Text auf blanko und linierten
/// Seiten, mehrere Bloecke je Seite, gemischte Formatierung innerhalb eines Blocks (fett, kursiv, unterstrichen,
/// durchgestrichen, markiert, Farbe, Schriftart, Schriftgroesse) und auf linierten Seiten immer auf den Zeilen.
///
/// Speicherformat: ein Textblock bleibt ein Objekt `type: "text"` des gemeinsamen Notizformats (wie `createText` im
/// Web-Editor), mit zusaetzlichen Feldern:
/// - `block: 1` - neuer Textblock (die App setzt ihn mit ihrem eigenen Zeilensatz, Anzeige = Bearbeiten = Export),
/// - `runs: [{text, bold?, italic?, underline?, strike?, mark?, fill?, fontFamily?, fontSize?}]` - Abschnitte mit
///   eigener Formatierung; nur Felder, die von der Grundformatierung des Objekts abweichen. Gueltig nur, solange die
///   Abschnitte aneinandergereiht genau `text` ergeben (aendert eine aeltere App oder der Web-Editor den Text, gilt
///   wieder die Grundformatierung - nichts geht kaputt),
/// - `strike`, `mark` - Grundformatierung, die das alte Format nicht kennt,
/// - `snap: "lines"` - der Block sitzt auf den Linien der Vorlage (liniert, Cornell).
///
/// Bewusst KEIN neuer Objekttyp: aeltere App-Versionen (bis 1.0.7) und der Web-Editor zeigen den Block als normales
/// Textfeld in der Grundformatierung, und `SolutionValidator` (Community) lehnt unbekannte Typen ab - ein neuer Typ
/// haette geteilte Loesungen bei allen mit aelterer App unlesbar gemacht.
public enum TextBlock {

    // MARK: Linienraster

    /// Abstand der Linien (liniert, Cornell) und die erste Linie, wie `TemplateGeometry`
    public static let lineStep = TemplateGeometry.step("lined")
    public static let firstLine = 60.0
    /// Innenabstand eines Textobjekts (wie `ObjectGeometry.textPadding` in der App und Konva im Web)
    public static let padding = 4.0
    /// Platz unter der Grundlinie fuer Unterlaengen (g, p, y), als Anteil des Zeilenabstands
    public static let descentShare = 0.2
    public static var baselineDrop: Double { lineStep * descentShare }

    /// Vorlagen mit Schreiblinien: dort rasten Textbloecke ein
    public static func hasLines(_ template: String?) -> Bool { template == "lined" || template == "cornell" }

    /// Schriftgroesse neuer Bloecke: auf Linien etwas groesser (24 pt Zeilenabstand), sonst wie bisher
    public static let linedFontSize = 16.0
    public static let plainFontSize = 14.0

    // MARK: Auswahl in der Leiste

    /// Schriftarten (Familienname in iPadOS/macOS; die ersten vier kennt auch jeder Browser)
    public static let fonts: [(family: String, title: String)] = [
        ("Arial", "Arial"), ("Times New Roman", "Times New Roman"), ("Georgia", "Georgia"), ("Courier New", "Courier New"),
        ("Helvetica Neue", "Helvetica Neue"), ("Avenir Next", "Avenir Next"), ("Palatino", "Palatino"),
        ("American Typewriter", "Schreibmaschine"), ("Noteworthy", "Handschrift"), ("Marker Felt", "Filzstift"),
        ("Chalkboard SE", "Tafel"),
    ]
    public static let sizes: [Double] = [10, 12, 14, 16, 18, 20, 24, 28, 36, 48]
    public static let sizeRange: ClosedRange<Double> = 6...200
    /// Farben zum Markieren (wie der Textmarker) und fuer die Schrift
    public static let markColors = PageObjectEdit.markerColors + ["#ffb35c"]
    public static let textColors = ["#1d2130", "#2f7fd1", "#e5322d", "#2e9e5b", "#f08c1f", "#7a4fd6"]
    /// Hoechstzahl an Abschnitten je Block (mehr wird beim Speichern zusammengefasst gar nicht erst erzeugt; beim
    /// Lesen gilt dann die Grundformatierung)
    public static let maxRuns = 4_000

    // MARK: Formatierung

    public struct Style: Hashable, Sendable {
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        public var strike: Bool
        /// Markierfarbe ("#rrggbb"), leer = nicht markiert
        public var mark: String
        public var fill: String
        public var fontFamily: String
        public var fontSize: Double

        public init(bold: Bool = false, italic: Bool = false, underline: Bool = false, strike: Bool = false, mark: String = "",
                    fill: String = "#1d2130", fontFamily: String = "Arial", fontSize: Double = 14) {
            self.bold = bold; self.italic = italic; self.underline = underline; self.strike = strike
            self.mark = mark; self.fill = fill; self.fontFamily = fontFamily; self.fontSize = fontSize
        }
    }

    public struct Run: Hashable, Sendable {
        public var text: String
        public var style: Style
        public init(text: String, style: Style) { self.text = text; self.style = style }
    }

    /// Aenderung an der Formatierung (Leiste): auf eine Auswahl im Text oder auf ganze Bloecke
    public enum Change: Equatable, Sendable {
        case bold(Bool), italic(Bool), underline(Bool), strike(Bool)
        case mark(String), fill(String), fontFamily(String), fontSize(Double), sizeDelta(Double)

        public func applied(to s: Style) -> Style {
            var out = s
            switch self {
            case .bold(let v): out.bold = v
            case .italic(let v): out.italic = v
            case .underline(let v): out.underline = v
            case .strike(let v): out.strike = v
            case .mark(let v): out.mark = v
            case .fill(let v): out.fill = v
            case .fontFamily(let v): out.fontFamily = v
            case .fontSize(let v): out.fontSize = clampedSize(v)
            case .sizeDelta(let d): out.fontSize = clampedSize(s.fontSize + d)
            }
            return out
        }
    }

    public static func clampedSize(_ v: Double) -> Double {
        guard v.isFinite else { return plainFontSize }
        return min(sizeRange.upperBound, max(sizeRange.lowerBound, (v * 2).rounded() / 2))
    }

    /// Neuer Textblock (setzt die App selbst) - im Unterschied zum einfachen Textfeld aus dem Web und zur Haftnotiz
    public static func isBlock(_ o: JSONValue) -> Bool {
        guard o["type"]?.string == "text" else { return false }
        return o["block"]?.double != nil || o["runs"]?.array != nil || o["snap"]?.string != nil
    }

    /// Grundformatierung des Objekts (die Felder, die auch aeltere Apps und das Web lesen)
    public static func baseStyle(_ o: JSONValue) -> Style {
        Style(bold: o["bold"]?.bool ?? false, italic: o["italic"]?.bool ?? false, underline: o["underline"]?.bool ?? false,
              strike: o["strike"]?.bool ?? false, mark: o["mark"]?.string ?? "",
              fill: nonEmpty(o["fill"]?.string) ?? "#1d2130", fontFamily: nonEmpty(o["fontFamily"]?.string) ?? "Arial",
              fontSize: clampedSize(o["fontSize"]?.double ?? plainFontSize))
    }

    private static func nonEmpty(_ s: String?) -> String? { (s ?? "").isEmpty ? nil : s }

    /// Abschnitte des Blocks. Ohne `runs` oder wenn sie nicht (mehr) zum Text passen: ein Abschnitt in der
    /// Grundformatierung. Leerer Text: keine Abschnitte.
    public static func runs(_ o: JSONValue) -> [Run] {
        let text = o["text"]?.string ?? ""
        guard !text.isEmpty else { return [] }
        let base = baseStyle(o)
        guard let raw = o["runs"]?.array, !raw.isEmpty, raw.count <= maxRuns else { return [Run(text: text, style: base)] }
        var out: [Run] = []
        out.reserveCapacity(raw.count)
        var joined = ""
        for r in raw {
            guard let t = r["text"]?.string else { return [Run(text: text, style: base)] }
            var s = base
            if let v = r["bold"]?.bool { s.bold = v }
            if let v = r["italic"]?.bool { s.italic = v }
            if let v = r["underline"]?.bool { s.underline = v }
            if let v = r["strike"]?.bool { s.strike = v }
            if let v = r["mark"]?.string { s.mark = v }
            if let v = nonEmpty(r["fill"]?.string) { s.fill = v }
            if let v = nonEmpty(r["fontFamily"]?.string) { s.fontFamily = v }
            if let v = r["fontSize"]?.double { s.fontSize = clampedSize(v) }
            joined += t
            if !t.isEmpty { out.append(Run(text: t, style: s)) }
        }
        return joined == text ? out : [Run(text: text, style: base)]
    }

    /// Nachbarn mit gleicher Formatierung zusammenfassen, leere Abschnitte weglassen
    public static func merged(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for r in runs where !r.text.isEmpty {
            if let last = out.last, last.style == r.style { out[out.count - 1].text += r.text } else { out.append(r) }
        }
        return out
    }

    /// Text und Abschnitte in das Objekt schreiben. `text` wird der aneinandergereihte Text; `runs` nur, wenn ein
    /// Abschnitt von der Grundformatierung abweicht. Das Objekt gilt danach als Textblock (`block`).
    public static func setting(_ runs: [Run], in o: JSONValue) -> JSONValue {
        guard var obj = o.object else { return o }
        let list = merged(runs)
        let base = baseStyle(o)
        obj["text"] = .string(list.map(\.text).joined())
        obj["block"] = 1
        if list.count > maxRuns || list.allSatisfy({ $0.style == base }) {
            obj.removeValue(forKey: "runs")
        } else {
            obj["runs"] = .array(list.map { r in
                var j: [String: JSONValue] = ["text": .string(r.text)]
                if r.style.bold != base.bold { j["bold"] = .bool(r.style.bold) }
                if r.style.italic != base.italic { j["italic"] = .bool(r.style.italic) }
                if r.style.underline != base.underline { j["underline"] = .bool(r.style.underline) }
                if r.style.strike != base.strike { j["strike"] = .bool(r.style.strike) }
                if r.style.mark != base.mark { j["mark"] = .string(r.style.mark) }
                if r.style.fill != base.fill { j["fill"] = .string(r.style.fill) }
                if r.style.fontFamily != base.fontFamily { j["fontFamily"] = .string(r.style.fontFamily) }
                if r.style.fontSize != base.fontSize { j["fontSize"] = .number(r.style.fontSize) }
                return .object(j)
            })
        }
        return .object(obj)
    }

    /// Grundformatierung in die Felder des Objekts schreiben (die Abschnitte behalten ihr Aussehen)
    static func settingBase(_ s: Style, in o: JSONValue) -> JSONValue {
        let keep = runs(o)
        guard var obj = o.object else { return o }
        obj["bold"] = .bool(s.bold); obj["italic"] = .bool(s.italic); obj["underline"] = .bool(s.underline)
        obj["strike"] = .bool(s.strike); obj["mark"] = .string(s.mark)
        obj["fill"] = .string(s.fill); obj["fontFamily"] = .string(s.fontFamily); obj["fontSize"] = .number(s.fontSize)
        if obj["snap"]?.string == "lines" { obj["lineHeight"] = .number(webLineHeight(fontSize: s.fontSize)) }
        return setting(keep, in: .object(obj))
    }

    /// Formatierung, in der die meisten Zeichen stehen (bei Gleichstand die fruehere)
    public static func dominantStyle(_ runs: [Run]) -> Style? {
        var count: [Style: Int] = [:]
        var order: [Style] = []
        for r in runs where !r.text.isEmpty {
            if count[r.style] == nil { order.append(r.style) }
            count[r.style, default: 0] += r.text.utf16.count
        }
        return order.max { (count[$0] ?? 0) < (count[$1] ?? 0) }
    }

    /// Ergebnis des Bearbeitens speichern: Text und Abschnitte, und als Grundformatierung die, in der die meisten
    /// Zeichen stehen - aeltere Apps und das Web zeigen den Block dann so aehnlich wie moeglich, und ein Block in nur
    /// einer Formatierung braucht keine Abschnitte.
    public static func saving(_ runs: [Run], in o: JSONValue) -> JSONValue {
        let list = merged(runs)
        guard let main = dominantStyle(list) else { return setting([], in: o) }
        // erst die Grundformatierung (mit leerem Text, damit keine alten Abschnitte umgerechnet werden), dann der Text
        var empty = o
        empty["text"] = ""
        empty["runs"] = nil
        return setting(list, in: settingBase(main, in: empty))
    }

    /// Zeilenhoehe (Vielfaches der Schriftgroesse), mit der aeltere Apps und das Web denselben Zeilenabstand zeigen
    static func webLineHeight(fontSize: Double) -> Double {
        ((lineStep / max(1, fontSize)) * 1000).rounded() / 1000
    }

    /// Formatierung des ganzen Blocks aendern: Grundformatierung und alle Abschnitte
    public static func applying(_ change: Change, to o: JSONValue) -> JSONValue {
        guard o["type"]?.string == "text" else { return o }
        let changed = runs(o).map { Run(text: $0.text, style: change.applied(to: $0.style)) }
        let based = settingBase(change.applied(to: baseStyle(o)), in: o)
        return setting(changed, in: based)
    }

    /// Formatierung der Bloecke mit diesen IDs aendern (Objektliste einer Seite)
    public static func applying(_ change: Change, to objects: [JSONValue], ids: Set<String>) -> [JSONValue] {
        objects.map { o in
            guard let id = o["id"]?.string, ids.contains(id), o["type"]?.string == "text" else { return o }
            return applying(change, to: o)
        }
    }

    /// Ausrichtung (links, mittig, rechts) der Bloecke mit diesen IDs
    public static let alignments = ["left", "center", "right"]
    public static func aligning(_ align: String, _ objects: [JSONValue], ids: Set<String>) -> [JSONValue] {
        guard alignments.contains(align) else { return objects }
        return objects.map { o in
            guard let id = o["id"]?.string, ids.contains(id), o["type"]?.string == "text" else { return o }
            return PageObjectEdit.set([o], ids: [id], "align", .string(align)).first ?? o
        }
    }

    /// Was alle Zeichen des Blocks gemeinsam haben (Anzeige in der Leiste); bei leerem Text die Grundformatierung.
    /// Gemischte Werte: Schalter aus, `mark` leer; Farbe, Schriftart und Groesse vom ersten Abschnitt.
    public static func commonStyle(_ runs: [Run], fallback: Style) -> Style {
        guard var s = runs.first?.style else { return fallback }
        for r in runs.dropFirst() {
            s.bold = s.bold && r.style.bold
            s.italic = s.italic && r.style.italic
            s.underline = s.underline && r.style.underline
            s.strike = s.strike && r.style.strike
            if s.mark != r.style.mark { s.mark = "" }
        }
        return s
    }

    // MARK: Anlegen

    /// Neuer Textblock am Tippunkt (Seitenpunkte). Auf einer Seite mit Linien sitzt die erste Zeile auf der Linie
    /// unter dem Tippunkt; `pageWidth` begrenzt die Breite auf den Platz bis zum rechten Rand.
    public static func block(id: String, x: Double, y: Double, template: String?, pageWidth: Double? = nil, text: String = "") -> JSONValue {
        let lined = hasLines(template)
        var o = PageObjectEdit.text(id: id, x: lined ? x - padding : x, y: y, text: text).object ?? [:]
        o["block"] = 1
        var width = 320.0
        if let pageWidth, pageWidth.isFinite, pageWidth > 0 {
            let left = o["x"]?.double ?? x
            width = min(max(pageWidth - left - 36, 140), pageWidth)
        }
        o["width"] = .number(PageObjectEdit.r2(width))
        if lined {
            o["snap"] = "lines"
            o["fontSize"] = .number(linedFontSize)
            o["lineHeight"] = .number(webLineHeight(fontSize: linedFontSize))
            o["y"] = .number(snappedY(forBaselineNear: y))
        } else {
            o["fontSize"] = .number(plainFontSize)
            o["lineHeight"] = 1.3
        }
        return .object(o)
    }

    // MARK: Einrasten auf den Linien

    /// Der Block rastet ein (gedrehte Bloecke nicht: ihre Zeilen laufen nicht mehr entlang der Linien)
    public static func isSnapped(_ o: JSONValue) -> Bool {
        guard o["type"]?.string == "text", o["snap"]?.string == "lines" else { return false }
        let rot = (o["rotation"]?.double ?? 0).truncatingRemainder(dividingBy: 360)
        return abs(rot) < 0.01
    }

    /// Oberkante eines eingerasteten Blocks, dessen erste Grundlinie auf der Linie `index` sitzt (0 = erste Linie)
    public static func y(forLine index: Int) -> Double {
        PageObjectEdit.r2(firstLine + Double(index) * lineStep - lineStep + baselineDrop - padding)
    }

    /// Naechste Oberkante, bei der die Grundlinien auf den Linien sitzen (nie ueber der ersten Linie)
    public static func snappedY(_ y: Double) -> Double {
        guard y.isFinite else { return self.y(forLine: 0) }
        let index = ((y - self.y(forLine: 0)) / lineStep).rounded()
        return self.y(forLine: Int(max(0, min(index, 100_000))))
    }

    /// Oberkante fuer einen Block, dessen erste Zeile auf der Linie unter dem Punkt `y` stehen soll (Antippen
    /// zwischen zwei Linien schreibt auf die untere, wie man mit dem Stift ansetzt)
    public static func snappedY(forBaselineNear y: Double) -> Double {
        guard y.isFinite else { return self.y(forLine: 0) }
        let index = ((y - firstLine) / lineStep - 0.15).rounded(.up)
        return self.y(forLine: Int(max(0, min(index, 100_000))))
    }

    /// Senkrechter Weg in ganzen Zeilen (Verschieben eingerasteter Bloecke)
    public static func snappedDelta(_ dy: Double) -> Double {
        guard dy.isFinite else { return 0 }
        return (dy / lineStep).rounded() * lineStep
    }

    /// Eingerastete Bloecke (alle oder die mit diesen IDs) zurueck auf die Linien setzen. Aendert nichts, wenn sie
    /// schon sitzen: darf nach jeder Aenderung laufen (Verschieben, Groesse, Einfuegen, Duplizieren).
    public static func resnapped(_ objects: [JSONValue], ids: Set<String>? = nil) -> [JSONValue] {
        objects.map { o in
            guard isSnapped(o), ids == nil || (o["id"]?.string).map({ ids!.contains($0) }) == true, var obj = o.object else { return o }
            let y = snappedY(o["y"]?.double ?? 0)
            guard obj["y"]?.double != y else { return o }
            obj["y"] = .number(y)
            return .object(obj)
        }
    }

    public static func containsSnapped(_ objects: [JSONValue], ids: Set<String>) -> Bool {
        objects.contains { o in (o["id"]?.string).map(ids.contains) == true && isSnapped(o) }
    }

    // MARK: Listen (Aufzaehlung und Nummerierung als Zeilenanfang im Text)

    public enum ListKind: Equatable, Sendable { case bullet, number }

    public static let bullet = "• "

    /// Listenzeichen am Anfang einer Zeile: Art, Laenge des Zeichens (UTF-16) und bei Nummern die Zahl
    public static func listPrefix(of line: String) -> (kind: ListKind, length: Int, number: Int)? {
        if line.hasPrefix(bullet) { return (.bullet, bullet.utf16.count, 0) }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4, let n = Int(digits), line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (.number, digits.count + 2, n)
    }

    public static func prefix(_ kind: ListKind, number: Int) -> String { kind == .bullet ? bullet : "\(number). " }

    /// Was die Eingabetaste am Ende der Zeile `line` tut: die Liste mit dem naechsten Zeichen fortsetzen, oder - bei
    /// einem leeren Listenpunkt - die Liste beenden (`endLength` Zeichen des leeren Punkts entfernen). `nil`: keine Liste.
    public static func listContinuation(after line: String) -> (insert: String?, endLength: Int)? {
        guard let p = listPrefix(of: line) else { return nil }
        if line.utf16.count == p.length { return (nil, p.length) }
        return ("\n" + prefix(p.kind, number: p.number + 1), 0)
    }

    /// Zeilen als Liste setzen oder die Liste wieder entfernen (alle Zeilen haben schon dieses Zeichen: entfernen).
    /// Nummern zaehlen ab 1; ein anderes Listenzeichen wird ersetzt.
    public static func togglingList(_ kind: ListKind, lines: [String]) -> [String] {
        let all = !lines.isEmpty && lines.allSatisfy { listPrefix(of: $0)?.kind == kind }
        var n = 0
        return lines.map { line in
            var rest = Substring(line)
            if let p = listPrefix(of: line) { rest = line[String.Index(utf16Offset: p.length, in: line)...] }
            if all { return String(rest) }
            n += 1
            return prefix(kind, number: n) + rest
        }
    }
}
