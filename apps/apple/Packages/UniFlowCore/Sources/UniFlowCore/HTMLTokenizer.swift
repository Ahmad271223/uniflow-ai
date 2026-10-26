import Foundation

// Kleiner HTML-Leser fuer serverseitig gerenderte Seiten (Notenspiegel des LSF Hildesheim ueber `HTMLScanner` in
// `LSFClient.grades`, CAS-Anmeldeseite, Opencast-Aufzeichnungen ueber `OpencastParser`). Diese Seiten sind kein wohlgeformtes HTML (offene td/tr,
// Layout-Tabellen ineinander, Attribute ohne Anfuehrungszeichen). Statt eines Parsers ein Durchlauf ueber die Bytes:
// Start- und End-Tags mit Attributen und Text; Kommentare, Doctype und Verarbeitungsanweisungen fallen weg, der
// Inhalt von script, style, title und textarea ist Rohtext bis zum passenden End-Tag.

/// Ein Baustein der Seite.
enum HTMLToken: Equatable {
    /// Start-Tag: Name klein, Attribute mit kleinem Namen und dekodiertem Wert (doppelte: der erste gilt)
    case start(String, [String: String])
    /// End-Tag, Name klein
    case end(String)
    /// Text zwischen Tags, Entities dekodiert
    case text(String)
    /// Inhalt von script, style, title oder textarea, nicht dekodiert (fuer diese Elemente gibt es kein start/end)
    case raw(String, String)
}

enum HTMLTokenizer {
    /// Elemente, deren Inhalt bis zum End-Tag Rohtext ist
    static let rawTextElements: Set<String> = ["script", "style", "title", "textarea"]

    static func tokens(_ html: String) -> [HTMLToken] {
        let b = Array(html.utf8)
        let n = b.count
        var out: [HTMLToken] = []
        var i = 0
        var textStart = 0

        func isAlpha(_ c: UInt8) -> Bool { (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A }
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
        func lower(_ s: ArraySlice<UInt8>) -> String { String(decoding: s.map { isAlpha($0) ? $0 | 0x20 : $0 }, as: UTF8.self) }
        func find(_ needle: [UInt8], from: Int, caseless: Bool = false) -> Int? {
            guard needle.count <= n else { return nil }
            var k = from
            while k + needle.count <= n {
                var hit = true
                for (o, c) in needle.enumerated() {
                    let x = b[k + o]
                    if caseless ? (isAlpha(x) ? x | 0x20 : x) != c : x != c { hit = false; break }
                }
                if hit { return k }
                k += 1
            }
            return nil
        }
        func flush(_ end: Int) {
            if end > textStart { out.append(.text(QISParser.decodeEntities(String(decoding: b[textStart..<end], as: UTF8.self)))) }
        }

        while i < n {
            guard b[i] == UInt8(ascii: "<"), i + 1 < n else { i += 1; continue }
            let c = b[i + 1]
            if c == UInt8(ascii: "!") || c == UInt8(ascii: "?") {
                flush(i)
                if c == UInt8(ascii: "!"), i + 3 < n, b[i + 2] == UInt8(ascii: "-"), b[i + 3] == UInt8(ascii: "-") {
                    i = find(Array("-->".utf8), from: i + 4).map { $0 + 3 } ?? n
                } else {
                    i = find([UInt8(ascii: ">")], from: i + 2).map { $0 + 1 } ?? n
                }
                textStart = i
                continue
            }
            if c == UInt8(ascii: "/"), i + 2 < n, isAlpha(b[i + 2]) {
                flush(i)
                var j = i + 2
                while j < n, isAlpha(b[j]) || isDigit(b[j]) { j += 1 }
                out.append(.end(lower(b[(i + 2)..<j])))
                i = find([UInt8(ascii: ">")], from: j).map { $0 + 1 } ?? n
                textStart = i
                continue
            }
            guard isAlpha(c) else { i += 1; continue }
            flush(i)
            var j = i + 1
            while j < n, isAlpha(b[j]) || isDigit(b[j]) || b[j] == UInt8(ascii: "-") || b[j] == UInt8(ascii: ":") { j += 1 }
            let name = lower(b[(i + 1)..<j])
            var attrs: [String: String] = [:]
            attrLoop: while j < n {
                while j < n, isSpace(b[j]) { j += 1 }
                guard j < n else { break }
                if b[j] == UInt8(ascii: ">") { j += 1; break }
                if b[j] == UInt8(ascii: "/") { j += 1; continue }
                let ns = j
                while j < n, !isSpace(b[j]), b[j] != UInt8(ascii: "="), b[j] != UInt8(ascii: ">"),
                      !(b[j] == UInt8(ascii: "/") && j + 1 < n && b[j + 1] == UInt8(ascii: ">")) { j += 1 }
                if j == ns { j += 1; continue attrLoop }
                let attr = lower(b[ns..<j])
                while j < n, isSpace(b[j]) { j += 1 }
                var value = ""
                if j < n, b[j] == UInt8(ascii: "=") {
                    j += 1
                    while j < n, isSpace(b[j]) { j += 1 }
                    if j < n, b[j] == UInt8(ascii: "\"") || b[j] == UInt8(ascii: "'") {
                        let q = b[j]
                        j += 1
                        let vs = j
                        while j < n, b[j] != q { j += 1 }
                        value = String(decoding: b[vs..<j], as: UTF8.self)
                        if j < n { j += 1 }
                    } else {
                        let vs = j
                        while j < n, !isSpace(b[j]), b[j] != UInt8(ascii: ">") { j += 1 }
                        value = String(decoding: b[vs..<j], as: UTF8.self)
                    }
                }
                if attrs[attr] == nil { attrs[attr] = QISParser.decodeEntities(value) }
            }
            i = j
            textStart = i
            if rawTextElements.contains(name) {
                // Rohtext bis zum passenden End-Tag
                let close = find(Array("</\(name)".utf8), from: i, caseless: true) ?? n
                out.append(.raw(name, String(decoding: b[i..<close], as: UTF8.self)))
                i = close < n ? (find([UInt8(ascii: ">")], from: close).map { $0 + 1 } ?? n) : n
                textStart = i
                continue
            }
            out.append(.start(name, attrs))
        }
        flush(n)
        return out
    }
}
