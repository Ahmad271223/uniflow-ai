import Foundation

// Eine Markdown-Datei der Wissensbibliothek: Kopfdaten (YAML-Front-Matter), Abschnitte je Ueberschrift (Sprungziele
// fuer die Suche: "## [Q1] Seite 3") und Markierungen (Loesungsstatus, [sic], Verweise "identisch mit G0035 Seite 31").

/// Kopfdaten zwischen zwei `---`-Zeilen am Dateianfang. Tolerant (MAC-ANLEITUNG 3): einfache `schluessel: wert`-Zeilen,
/// Werte in Anfuehrungszeichen oder ohne, Listen (`- …`) auch mit Unterfeldern (`- kurz: Q1` / `titel: …`), Blocktext
/// (`|`, `>`). Unbekannte Felder bleiben erhalten, aber ungenutzt; fehlende sind leer. Alle Werte sind Text.
public struct KnowledgeFrontMatter: Equatable, Sendable {
    /// einfache Felder (`typ: uebung-geloest`)
    public var fields: [String: String] = [:]
    /// Listenfelder; ein Eintrag mit Unterfeldern wird zu einer Zeile ("Q1: titel (Seiten 1-30)")
    public var lists: [String: [String]] = [:]
    /// Reihenfolge der Schluessel wie in der Datei
    public var keys: [String] = []

    public init() {}

    public subscript(_ key: String) -> String? {
        if let v = fields[key], !v.isEmpty { return v }
        if let l = lists[key], !l.isEmpty { return l.joined(separator: "; ") }
        return nil
    }

    /// Werte eines Felds als Liste (einfaches Feld = ein Eintrag)
    public func values(_ key: String) -> [String] {
        if let l = lists[key], !l.isEmpty { return l }
        if let v = fields[key], !v.isEmpty { return [v] }
        return []
    }

    /// Quellen (`quellen`, selten `quelle`)
    public var sources: [String] { values("quellen") + values("quelle") }

    public static func parse(_ yaml: String) -> KnowledgeFrontMatter {
        var fm = KnowledgeFrontMatter()
        var key: String?
        /// Unterfelder des laufenden Listeneintrags
        var item: [(String, String)]?
        /// Blocktext (`|`/`>`) des laufenden Felds
        var block: [String]?

        func finishItem() {
            guard let k = key, let pairs = item else { return }
            fm.lists[k, default: []].append(Self.itemText(pairs))
            item = nil
        }
        func finishBlock() {
            guard let k = key, let b = block else { return }
            fm.fields[k] = b.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            block = nil
        }

        for raw in yaml.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indented = line.first == " " || line.first == "\t"
            if !indented, let (k, v) = Self.pair(trimmed) {
                finishItem(); finishBlock()
                key = k
                if !fm.keys.contains(k) { fm.keys.append(k) }
                if ["|", "|-", ">", ">-", "|+", ">+"].contains(v) { block = []; continue }
                if !v.isEmpty { fm.fields[k] = Self.unquote(v) }
                continue
            }
            guard key != nil else { continue }
            if block != nil { block?.append(trimmed); continue }
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                finishItem()
                let rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let (k, v) = Self.pair(rest), !Self.looksLikeText(rest) {
                    item = [(k, Self.unquote(v))]
                } else if !rest.isEmpty {
                    fm.lists[key!, default: []].append(Self.unquote(rest))
                }
                continue
            }
            if item != nil, let (k, v) = Self.pair(trimmed) {
                item?.append((k, Self.unquote(v)))
                continue
            }
            // Fortsetzungszeile: am letzten Listeneintrag bzw. am Feld anhaengen
            if var pairs = item, !pairs.isEmpty {
                pairs[pairs.count - 1].1 += " " + Self.unquote(trimmed)
                item = pairs
            } else if let k = key, var l = fm.lists[k], !l.isEmpty {
                l[l.count - 1] += " " + Self.unquote(trimmed)
                fm.lists[k] = l
            } else if let k = key {
                fm.fields[k] = ((fm.fields[k] ?? "") + " " + Self.unquote(trimmed)).trimmingCharacters(in: .whitespaces)
            }
        }
        finishItem(); finishBlock()
        return fm
    }

    /// "schluessel: wert" mit einfachem Schluessel (Buchstaben, Ziffern, `_`, `-`); sonst nil
    static func pair(_ s: String) -> (String, String)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let k = String(s[..<colon])
        guard !k.isEmpty, k.count <= 40, k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        let after = s[s.index(after: colon)...]
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }  // "http://…" ist kein Paar
        return (k, after.trimmingCharacters(in: .whitespaces))
    }

    /// Listeneintrag in Anfuehrungszeichen ist Text, auch wenn ein Doppelpunkt darin steht
    private static func looksLikeText(_ s: String) -> Bool { s.hasPrefix("\"") || s.hasPrefix("'") }

    static func unquote(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            return String(t.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") {
            return String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return t
    }

    /// Eintrag mit Unterfeldern als eine Zeile: "Q1: titel (Seiten 1-30)", sonst die Werte mit " · "
    static func itemText(_ pairs: [(String, String)]) -> String {
        let d = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        if let title = d["titel"] ?? d["quelle"] ?? d["datei"] {
            var s = d["kurz"].map { "\($0): " } ?? ""
            s += title
            if let p = d["seiten"] ?? d["pdf_seiten"], !p.isEmpty { s += " (Seiten \(p))" }
            return s
        }
        return pairs.map(\.1).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Abschnitt einer Datei: Text ab einer Ueberschrift der Ebene 1 oder 2 bis zur naechsten (die Ueberschrift gehoert
/// dazu). Abschnitt 0 kann Text vor der ersten Ueberschrift sein.
public struct KnowledgeSection: Equatable, Sendable, Identifiable {
    public var index: Int
    /// Ueberschrift ohne `#` ("[Q1] Seite 3: Titelfolie"); nil fuer Text vor der ersten Ueberschrift
    public var heading: String?
    public var level: Int
    public var markdown: String
    public var id: Int { index }
}

/// Eine gelesene Markdown-Datei.
public struct KnowledgeDocument: Equatable, Sendable {
    public var frontMatter: KnowledgeFrontMatter?
    /// Text ohne Kopfdaten
    public var body: String
    public var sections: [KnowledgeSection]

    public static func parse(_ text: String) -> KnowledgeDocument {
        // Zeilenenden vereinheitlichen: "\r\n" ist in Swift EIN Zeichen und trennt sonst keine Zeilen (der PC-Export
        // schreibt etwa die Haelfte der Dateien mit CRLF)
        let (yaml, body) = splitFrontMatter(KnowledgeText.lines(text))
        return KnowledgeDocument(frontMatter: yaml.map(KnowledgeFrontMatter.parse), body: body, sections: sections(body))
    }

    /// Kopfdaten abtrennen: erste Zeile `---`, Ende an der naechsten Zeile `---` (oder `...`). Ohne Ende kein Kopf.
    public static func splitFrontMatter(_ text: String) -> (String?, String) {
        var t = Substring(text)
        if t.hasPrefix("\u{FEFF}") { t = t.dropFirst() }
        guard t.hasPrefix("---") else { return (nil, String(t)) }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, String(t)) }
        for i in 1..<lines.count {
            let l = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if l == "---" || l == "..." {
                let yaml = lines[1..<i].joined(separator: "\n")
                let body = i + 1 < lines.count ? lines[(i + 1)...].joined(separator: "\n") : ""
                return (yaml, body)
            }
        }
        return (nil, String(t))
    }

    /// Abschnitte je Ueberschrift der Ebene 1 und 2 (nicht in Codebloecken)
    public static func sections(_ body: String) -> [KnowledgeSection] {
        var out: [KnowledgeSection] = []
        var current: [Substring] = []
        var heading: String?
        var level = 0
        var inCode = false
        func flush() {
            let md = current.joined(separator: "\n")
            if heading != nil || !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(KnowledgeSection(index: out.count, heading: heading, level: level, markdown: md))
            }
            current = []
        }
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inCode.toggle() }
            if !inCode, let h = headingOf(line), h.level <= 2 {
                flush()
                heading = h.text
                level = h.level
            }
            current.append(line)
        }
        flush()
        return out
    }

    static func headingOf(_ line: Substring) -> (level: Int, text: String)? {
        var level = 0
        var rest = line
        while rest.first == "#", level < 7 { level += 1; rest = rest.dropFirst() }
        guard level > 0, level <= 6, rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    /// Abschnitt zu einem Sprungziel: "s12" (Abschnittsnummer) oder ein Text wie "[Q1] Seite 3", "Seite 31", "Folie 2",
    /// "Aufgabe 1-2" (Ueberschrift enthaelt ihn, danach keine weitere Ziffer: "Seite 3" trifft nicht "Seite 31")
    public func sectionIndex(for anchor: String) -> Int? {
        if anchor.hasPrefix("s"), let n = Int(anchor.dropFirst()), sections.indices.contains(n) { return n }
        let hint = KnowledgeText.searchForm(anchor).trimmingCharacters(in: .whitespaces)
        guard !hint.isEmpty else { return nil }
        return sections.first { s in
            guard let h = s.heading else { return false }
            return KnowledgeMarks.containsBounded(KnowledgeText.searchForm(h), hint)
        }?.index
    }
}

/// Verweis "identisch mit G0035 Seite 31" auf eine andere Einheit desselben Fachs.
public struct KnowledgeLink: Codable, Hashable, Sendable {
    /// Kennung der Einheit ("G0035")
    public var unit: String
    /// Sprungziel in der Einheit ("Seite 31", "[Q1] Seite 4", "Folie 2", "Aufgabe 1-2"), nil ohne Angabe
    public var hint: String?

    public init(unit: String, hint: String? = nil) {
        self.unit = unit
        self.hint = hint
    }

    /// "G0035 · Seite 31"
    public var label: String { hint.map { "\(unit) · \($0)" } ?? unit }
}

/// Markierungen im Text (MAC-ANLEITUNG 3, Tabelle "Markierungen").
public struct KnowledgeMarks: Codable, Equatable, Sendable {
    /// "KI-Lösung, ungeprüft": keine offizielle Lösung. In der App deutlich kennzeichnen.
    public var kiUnchecked = false
    /// "unabhängig gelöst: ja" bzw. "…, unabhängig gelöst, …": erst selbst gelöst, dann verglichen
    public var independent = false
    /// "nachgerechnet, nicht unabhängig gelöst": Musterloesung war bekannt, der Weg wurde nachgerechnet
    public var recomputed = false
    /// Anzahl "[sic]" (Fehler der Vorlage mit Beleg)
    public var sic = 0
    /// Anzahl "[Name entfernt]"
    public var namesRemoved = 0
    /// Verweise "identisch mit G00xx …" (ohne Wiederholungen, in Reihenfolge)
    public var links: [KnowledgeLink] = []

    public init() {}

    public var isEmpty: Bool { !kiUnchecked && !independent && !recomputed && sic == 0 && links.isEmpty }

    public mutating func merge(_ o: KnowledgeMarks) {
        kiUnchecked = kiUnchecked || o.kiUnchecked
        independent = independent || o.independent
        recomputed = recomputed || o.recomputed
        sic += o.sic
        namesRemoved += o.namesRemoved
        for l in o.links where !links.contains(l) { links.append(l) }
    }

    /// Texte, die "KI-Lösung, ungeprüft" bedeuten (im Export kommt auch "KI-Lösung, nicht bestätigt" vor)
    public static let kiUncheckedPhrases = ["ki-lösung, ungeprüft", "ki-lösung, nicht bestätigt"]

    public static func scan(_ text: String) -> KnowledgeMarks {
        var m = KnowledgeMarks()
        let lower = KnowledgeText.searchForm(text)
        m.kiUnchecked = kiUncheckedPhrases.contains { lower.contains($0) }
        // "unabhängig gelöst" mit "nicht " davor = nachgerechnet, sonst unabhaengig
        var from = lower.startIndex
        while let r = lower.range(of: "unabhängig gelöst", range: from..<lower.endIndex) {
            let start: String.Index = lower.index(r.lowerBound, offsetBy: -6, limitedBy: lower.startIndex) ?? lower.startIndex
            let before: Substring = lower[start..<r.lowerBound]
            if before.hasSuffix("nicht ") { m.recomputed = true } else { m.independent = true }
            from = r.upperBound
        }
        if lower.contains("nachgerechnet, nicht unabhängig") { m.recomputed = true }
        m.sic = count("[sic]", in: lower)
        m.namesRemoved = count("[name entfernt]", in: lower)
        m.links = lower.contains("identisch mit") ? links(in: text) : []
        return m
    }

    static func count(_ needle: String, in hay: String) -> Int {
        var n = 0
        var from = hay.startIndex
        while let r = hay.range(of: needle, range: from..<hay.endIndex) { n += 1; from = r.upperBound }
        return n
    }

    /// Verweise "identisch mit G0035 Seite 31 → Erklärung dort", "identisch mit G0001/G0002", "identisch mit
    /// G0020–G0022", "identisch mit G0059 [Q2] Aufgabe 1-2". Ein Sprungziel gilt nur fuer einen einzelnen Verweis.
    public static func links(in text: String) -> [KnowledgeLink] {
        var out: [KnowledgeLink] = []
        let chars = Array(text)
        let needle = Array("identisch mit ")
        var i = 0
        while i + needle.count < chars.count {
            guard chars[i] == "i" || chars[i] == "I" else { i += 1; continue }
            var ok = true
            for k in 1..<needle.count where chars[i + k] != needle[k] { ok = false; break }
            guard ok else { i += 1; continue }
            var j = i + needle.count
            var ids: [String] = []
            while j < chars.count {
                guard chars[j] == "G" else { break }
                var k = j + 1
                while k < chars.count, chars[k].isASCII, chars[k].isNumber { k += 1 }
                // mindestens vier Ziffern, kein Buchstabe dahinter ("G006x" ist ein Platzhalter im Text, kein Verweis)
                guard k - j >= 5, k == chars.count || !chars[k].isLetter else { break }
                ids.append(String(chars[j..<k]))
                j = k
                // Trenner zwischen Kennungen: "/", "–", "-", ",", " und "
                var t = j
                while t < chars.count, chars[t] == " " { t += 1 }
                if t < chars.count, "/–-,".contains(chars[t]) {
                    t += 1
                    while t < chars.count, chars[t] == " " { t += 1 }
                    if t < chars.count, chars[t] == "G" { j = t; continue }
                } else if t + 4 < chars.count, String(chars[t..<t + 4]) == "und ", chars[t + 4] == "G" {
                    j = t + 4
                    continue
                }
                break
            }
            var hint: String?
            if ids.count == 1 { hint = Self.hint(chars, from: j) }
            for id in ids {
                let l = KnowledgeLink(unit: id, hint: ids.count == 1 ? hint : nil)
                if !out.contains(l) { out.append(l) }
            }
            i = max(j, i + 1)
        }
        return out
    }

    /// Sprungziel hinter der Kennung: " [Q1] Seite 4", " Seite 31", " Folie 2", " Aufgabe 1-2"
    private static func hint(_ chars: [Character], from start: Int) -> String? {
        var j = start
        guard j < chars.count, chars[j] == " " else { return nil }
        j += 1
        var prefix = ""
        if j + 4 < chars.count, chars[j] == "[", chars[j + 1] == "Q" {
            var k = j + 2
            while k < chars.count, chars[k].isNumber { k += 1 }
            guard k < chars.count, chars[k] == "]", k + 1 < chars.count, chars[k + 1] == " " else { return nil }
            prefix = String(chars[j...k]) + " "
            j = k + 2
        }
        for word in ["Seite ", "Folie ", "Aufgabe "] {
            let w = Array(word)
            guard j + w.count < chars.count, Array(chars[j..<j + w.count]) == w else { continue }
            var k = j + w.count
            while k < chars.count, chars[k].isLetter || chars[k].isNumber || chars[k] == "." || chars[k] == "-" { k += 1 }
            var token = String(chars[(j + w.count)..<k])
            while let last = token.last, last == "." || last == "-" { token.removeLast() }
            guard !token.isEmpty, token.first?.isNumber == true || token.count <= 3 else { return nil }
            return prefix + word + token
        }
        return nil
    }

    /// `needle` in `hay` (beide schon in Suchform), davor und danach kein Buchstabe und keine Ziffer
    public static func containsBounded(_ hay: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var from = hay.startIndex
        while let r = hay.range(of: needle, range: from..<hay.endIndex) {
            let beforeOK = r.lowerBound == hay.startIndex || !isWordChar(hay[hay.index(before: r.lowerBound)], next: needle.first)
            let afterOK = r.upperBound == hay.endIndex || !isWordChar(hay[r.upperBound], next: needle.last)
            if beforeOK && afterOK { return true }
            from = hay.index(after: r.lowerBound)
        }
        return false
    }

    /// Wortzeichen an der Grenze; nach "]" oder ")" am Rand des Suchtexts ist die Grenze immer erfuellt
    private static func isWordChar(_ c: Character, next: Character?) -> Bool {
        if let n = next, !(n.isLetter || n.isNumber) { return false }
        return c.isLetter || c.isNumber
    }
}

/// Zuordnung Stud.IP-Datei -> Einheiten ueber die Titel in `quellen` (MAC-ANLEITUNG 4.4).
public enum KnowledgeSourceMatch {
    /// Vergleichsform aller Quellen einer Einheit (ein Text, Eintraege mit "\n" getrennt)
    public static func blob(_ sources: [String]) -> String {
        sources.map(KnowledgeText.titleForm).joined(separator: "\n")
    }

    /// Kandidaten aus Titel und Dateiname einer Datei (ohne Endung), in Vergleichsform, mindestens 5 Zeichen
    public static func candidates(title: String?, fileName: String?) -> [String] {
        var out: [String] = []
        for raw in [title, fileName].compactMap({ $0 }) {
            var s = raw
            let ext = (s as NSString).pathExtension.lowercased()
            if ["pdf", "pptx", "ppt", "docx", "doc", "zip", "png", "jpg", "jpeg"].contains(ext) { s = (s as NSString).deletingPathExtension }
            let t = KnowledgeText.titleForm(s)
            if t.count >= 5, !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// Kommt einer der Kandidaten in den Quellen vor (als ganzes Stueck, nicht als Teil eines Worts oder einer Zahl)?
    public static func matches(candidates: [String], blob: String) -> Bool {
        candidates.contains { KnowledgeMarks.containsBounded(blob, $0) }
    }
}
