import Foundation

/// Zuordnung der Seiten einer neuen Original-Fassung zu den Seiten der alten ueber den Seitentext (S7, Entwurf in
/// docs/IPAD-OHNE-PC.md, Abschnitt 2; app/*.py kennt keine neuen Fassungen mit Notizen).
///
/// Verglichen werden Woerter: Text wie die Skriptsuche normalisiert (`ScriptSearch.normalize`, zerlegte Umlaute),
/// klein geschrieben, Leerraum zusammengefasst, jede Ziffernfolge als "#" (Seitenzahlen und Datum in der Fusszeile
/// verschieben sich mit jeder eingefuegten Folie). Reihenfolge:
/// 1. gleich: gleiche Woerter -> Seite zu Seite (bei mehreren gleichen Seiten der Reihe nach), sicher
/// 2. aehnlich: `SequenceMatcher.ratio()` (derselbe difflib-Port wie `ModuleGuess`) ab 0.6 wie
///    `difflib.get_close_matches`, mit denselben Vorfiltern (`real_quick_ratio`, `quick_ratio`), je alter Seite die
///    fuenf aussichtsreichsten neuen; vergeben nach hoechster Aehnlichkeit, bei Gleichstand der kleinere Abstand der
///    Seitenzahlen, dann die fruehere Seite; zu pruefen
/// 3. Position: Seiten ohne Text auf beiden Seiten (Scans, Leerseiten) im selben Abstand zur naechsten zugeordneten
///    Seite davor, sonst danach (ohne jede Zuordnung Seite fuer Seite); zu pruefen
/// Alles andere gilt als entfernt (alte Seite) bzw. neu (neue Seite). Verschobene Seiten folgen ihrem Text.
public enum PageMatch {
    /// `difflib.get_close_matches(cutoff=0.6)`
    public static let minimumRatio = 0.6
    /// je alter Seite hoechstens so viele Kandidaten fuer `ratio()` (nach `quick_ratio()`)
    static let candidatesPerPage = 5

    public enum Kind: String, Sendable, Equatable {
        case same = "gleich"
        case similar = "aehnlich"
        case position = "position"
    }

    public struct Pair: Equatable, Sendable {
        /// Seiten 1-basiert
        public let old: Int
        public let new: Int
        public let kind: Kind
        public let ratio: Double
    }

    public struct Result: Equatable, Sendable {
        public let oldCount: Int
        public let newCount: Int
        /// nach alter Seite
        public let pairs: [Pair]

        public func pair(old i: Int) -> Pair? { pairs.first { $0.old == i } }
        public func newIndex(old i: Int) -> Int? { pair(old: i)?.new }
        /// alte Seiten ohne Gegenstueck
        public var removed: [Int] {
            let used = Set(pairs.map(\.old))
            return oldCount > 0 ? (1...oldCount).filter { !used.contains($0) } : []
        }
        /// neue Seiten ohne Gegenstueck
        public var added: [Int] {
            let used = Set(pairs.map(\.new))
            return newCount > 0 ? (1...newCount).filter { !used.contains($0) } : []
        }
    }

    private static let digits = PyRegex(#"\d+"#)
    private static let spaces = PyRegex(#"\s+"#)

    /// Woerter einer Seite fuer den Vergleich
    public static func words(_ text: String) -> [String] {
        let flat = PyText.strip(spaces.sub(digits.sub(PyText.lower(ScriptSearch.normalize(text)), "#"), " "))
        return flat.isEmpty ? [] : PyText.split(flat, " ")
    }

    /// Ohne Seitentexte (alte Fassung nicht mehr lesbar): Seite fuer Seite, alle zu pruefen
    public static func byPosition(oldCount: Int, newCount: Int) -> Result {
        let n = min(oldCount, newCount)
        return Result(oldCount: oldCount, newCount: newCount,
                      pairs: n > 0 ? (1...n).map { Pair(old: $0, new: $0, kind: .position, ratio: 0) } : [])
    }

    public static func match(old: [String], new: [String]) -> Result {
        let wo = old.map(words), wn = new.map(words)
        var newOf: [Int: Pair] = [:]                 // alte Seite (0-basiert) -> Paar
        var taken = Set<Int>()                       // neue Seiten (0-basiert)

        // 1. gleich
        var waiting: [[String]: [Int]] = [:]
        for (j, w) in wn.enumerated() where !w.isEmpty { waiting[w, default: []].append(j) }
        for (i, w) in wo.enumerated() where !w.isEmpty {
            guard var queue = waiting[w], !queue.isEmpty else { continue }
            let j = queue.removeFirst()
            waiting[w] = queue
            newOf[i] = Pair(old: i + 1, new: j + 1, kind: .same, ratio: 1)
            taken.insert(j)
        }

        // 2. aehnlich
        var candidates: [(ratio: Double, i: Int, j: Int)] = []
        let freeNew = wn.indices.filter { !taken.contains($0) && !wn[$0].isEmpty }
        for i in wo.indices where newOf[i] == nil && !wo[i].isEmpty {
            var quick: [(q: Double, j: Int, m: SequenceMatcher<String>)] = []
            for j in freeNew {
                let m = SequenceMatcher(wo[i], wn[j])
                guard m.realQuickRatio() >= minimumRatio else { continue }
                let q = m.quickRatio()
                if q >= minimumRatio { quick.append((q, j, m)) }
            }
            quick.sort { a, b in
                if a.q != b.q { return a.q > b.q }
                let da = abs(a.j - i), db = abs(b.j - i)
                return da != db ? da < db : a.j < b.j
            }
            for c in quick.prefix(candidatesPerPage) {
                let r = c.m.ratio()
                if r >= minimumRatio { candidates.append((r, i, c.j)) }
            }
        }
        candidates.sort { a, b in
            if a.ratio != b.ratio { return a.ratio > b.ratio }
            let da = abs(a.i - a.j), db = abs(b.i - b.j)
            if da != db { return da < db }
            return a.i != b.i ? a.i < b.i : a.j < b.j
        }
        for c in candidates where newOf[c.i] == nil && !taken.contains(c.j) {
            newOf[c.i] = Pair(old: c.i + 1, new: c.j + 1, kind: .similar, ratio: c.ratio)
            taken.insert(c.j)
        }

        // 3. Position (beide Seiten ohne Text)
        for i in wo.indices where newOf[i] == nil && wo[i].isEmpty {
            var options: [Int] = []
            if let p = (0..<i).last(where: { newOf[$0] != nil }), let q = newOf[p]?.new { options.append((q - 1) + (i - p)) }
            if let s = ((i + 1)..<max(i + 1, wo.count)).first(where: { newOf[$0] != nil }), let t = newOf[s]?.new {
                options.append((t - 1) - (s - i))
            }
            if options.isEmpty { options.append(i) }
            guard let j = options.first(where: { wn.indices.contains($0) && !taken.contains($0) && wn[$0].isEmpty }) else { continue }
            newOf[i] = Pair(old: i + 1, new: j + 1, kind: .position, ratio: 0)
            taken.insert(j)
        }
        return Result(oldCount: old.count, newCount: new.count, pairs: newOf.keys.sorted().compactMap { newOf[$0] })
    }
}
