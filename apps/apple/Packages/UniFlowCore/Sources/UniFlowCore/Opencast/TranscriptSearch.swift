import Foundation

/// Suche in einer Mitschrift (1.0.8, docs/WHISPER-MITSCHRIFT.md): Wort oder Wortfolge eintippen, Treffer mit Ausschnitt
/// und der Stelle in der Aufnahme sehen, antippen – Ton oder Video springt dorthin. Ohne Netz, ohne KI.
///
/// Gross-/Kleinschreibung und Umlaute spielen keine Rolle ("naherung" findet "Näherung", "strasse" findet "Straße").
/// Die Stelle ist geschaetzt: eine Mitschrift kennt nur Anfang und Ende eines Abschnitts (rund eine Minute); der
/// Treffer liegt anteilig dazwischen, mit ein paar Sekunden Vorlauf, damit der Satz von vorn zu hoeren ist.
public enum TranscriptSearch {
    public struct Hit: Equatable, Sendable, Identifiable {
        /// laufende Nummer in der Trefferliste
        public let id: Int
        /// Index des Abschnitts in der Mitschrift
        public let section: Int
        /// geschaetzte Stelle in der Aufnahme (Sekunden)
        public let time: Double
        /// Ausschnitt: Text vor dem Treffer, der Treffer in der Schreibweise der Mitschrift, Text danach
        public let before: String
        public let match: String
        public let after: String
    }

    /// Ab so vielen Zeichen wird gesucht
    public static let minQuery = 2
    public static let maxHits = 200
    /// Vorlauf vor der geschaetzten Stelle (Sekunden)
    static let lead = 4.0
    static let contextBefore = 48
    static let contextAfter = 72

    /// Eingabe aufraeumen: Raender weg, mehrere Leerzeichen zu einem; "" wenn zu kurz
    public static func normalized(_ query: String) -> String {
        let q = query.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return q.count >= minQuery ? q : ""
    }

    /// Vergleichsform eines Textes Zeichen fuer Zeichen, mit dem Index des Ursprungszeichens je Vergleichszeichen
    /// (ein "ß" wird zu "ss": zwei Vergleichszeichen zeigen auf dasselbe Ursprungszeichen)
    static func fold(_ text: String) -> (chars: [Character], origin: [Int]) {
        var chars: [Character] = []
        var origin: [Int] = []
        chars.reserveCapacity(text.count)
        origin.reserveCapacity(text.count)
        for (i, c) in text.enumerated() {
            if c.isWhitespace {
                chars.append(" ")
                origin.append(i)
                continue
            }
            for f in String(c).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased() {
                chars.append(f)
                origin.append(i)
            }
        }
        return (chars, origin)
    }

    /// Alle Stellen von `needle` in `hay` (ohne Ueberlappung)
    static func positions(of needle: [Character], in hay: [Character]) -> [Int] {
        guard !needle.isEmpty, hay.count >= needle.count else { return [] }
        var out: [Int] = []
        var i = 0
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == needle[0], hay[i..<(i + needle.count)].elementsEqual(needle) {
                out.append(i)
                i += needle.count
            } else {
                i += 1
            }
        }
        return out
    }

    /// Geschaetzte Stelle eines Treffers im Abschnitt
    static func time(in section: TranscriptSection, offset: Int, length: Int) -> Double {
        guard section.end > section.start, length > 0 else { return max(0, section.start) }
        let t = section.start + Double(offset) / Double(length) * (section.end - section.start) - lead
        return max(0, max(section.start, min(t, section.end)))
    }

    /// Treffer in der Reihenfolge der Mitschrift. Die Eingabe gilt als Wortfolge; findet sich die Folge nirgends und
    /// besteht sie aus mehreren Woertern, zaehlen Abschnitte, in denen alle Woerter vorkommen (Treffer am ersten Wort).
    public static func hits(_ sections: [TranscriptSection], query: String, limit: Int = maxHits) -> [Hit] {
        let q = normalized(query)
        guard !q.isEmpty, limit > 0 else { return [] }
        let needle = fold(q).chars
        let folded = sections.map { fold($0.text) }
        var out: [Hit] = []

        func add(_ index: Int, at position: Int, length: Int) {
            let original = Array(sections[index].text)
            let f = folded[index]
            guard position < f.origin.count, position + length - 1 < f.origin.count else { return }
            let from = f.origin[position], to = f.origin[position + length - 1]
            var start = max(0, from - contextBefore)
            // am Wortanfang beginnen
            if start > 0 { while start < from, !original[start - 1].isWhitespace { start += 1 } }
            var end = min(original.count, to + 1 + contextAfter)
            if end < original.count { while end > to + 1, !original[end - 1].isWhitespace { end -= 1 } }
            let before = (start > 0 ? "… " : "") + String(original[start..<from])
            let after = String(original[(to + 1)..<end]).trimmingCharacters(in: .newlines)
            out.append(Hit(id: out.count, section: index, time: time(in: sections[index], offset: from, length: original.count),
                           before: before, match: String(original[from...to]),
                           after: end < original.count ? after.trimmingCharacters(in: .whitespaces) + " …" : after))
        }

        for (i, f) in folded.enumerated() {
            for p in positions(of: needle, in: f.chars) {
                if out.count >= limit { return out }
                add(i, at: p, length: needle.count)
            }
        }
        if !out.isEmpty { return out }

        let words = q.split(separator: " ").map { fold(String($0)).chars }.filter { !$0.isEmpty }
        guard words.count >= 2 else { return [] }
        for (i, f) in folded.enumerated() {
            let firsts = words.map { positions(of: $0, in: f.chars).first }
            guard firsts.allSatisfy({ $0 != nil }), let p = firsts[0] else { continue }
            if out.count >= limit { break }
            add(i, at: p, length: words[0].count)
        }
        return out
    }

    /// Zeile ueber der Trefferliste
    public static func summary(_ count: Int, limit: Int = maxHits) -> String {
        switch count {
        case 0: return "Keine Treffer."
        case 1: return "1 Treffer"
        default: return count >= limit ? "Mehr als \(limit) Treffer – die ersten \(limit)" : "\(count) Treffer"
        }
    }
}
