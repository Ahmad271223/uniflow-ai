import Foundation

/// Zuordnung der Seiten einer neuen Original-Fassung zu den Seiten der alten ueber den Seitentext (S7, Entwurf in
/// docs/IPAD-OHNE-PC.md, Abschnitt 2; app/*.py kennt keine neuen Fassungen mit Notizen).
///
/// Verglichen werden Woerter: Text wie die Skriptsuche normalisiert (`ScriptSearch.normalize`, zerlegte Umlaute),
/// klein geschrieben, Leerraum zusammengefasst, jede Ziffernfolge als "#" (Seitenzahlen und Datum in der Fusszeile
/// verschieben sich mit jeder eingefuegten Folie). Reihenfolge:
/// 1. gleich (sicher): die Seitenfolgen beider Fassungen ausgerichtet (`SequenceMatcher` ueber die Seiten, ohne
///    autojunk). Ein gemeinsamer Block gleicher Seiten zaehlt, wenn er eine Seite enthaelt, deren Text in beiden
///    Fassungen genau einmal vorkommt (Anker); darin sind eindeutige Seiten sicher, mehrfach vorkommende nur, wenn
///    auch beide Nachbarn im Block liegen (oder die Seite am Anfang bzw. Ende beider Fassungen steht). Eindeutige
///    Seiten ausserhalb der Bloecke wurden verschoben und folgen ihrem Text.
/// 2. wiederholt (zu pruefen): uebrige Seiten, deren Text mehrfach vorkommt ("Platz für Notizen", Gliederung,
///    "Fragen?", Seiten, die sich nur in Zahlen unterscheiden), nach ihrer Lage: gleicher Abstand zur naechsten
///    zugeordneten Seite davor, dann zu der danach, sonst die naechstgelegene freie Seite mit diesem Text
/// 3. aehnlich (zu pruefen): `SequenceMatcher.ratio()` ab 0.6 wie `difflib.get_close_matches`, mit denselben
///    Vorfiltern (`real_quick_ratio` aus den Laengen, `quick_ratio` aus vorberechneten Haeufigkeiten), je alter Seite die
///    fuenf aussichtsreichsten neuen; vergeben nach hoechster Aehnlichkeit, bei Gleichstand der kleinere Abstand der
///    Seitenzahlen, dann die fruehere Seite
/// 4. Position (zu pruefen): uebrige Seiten, bei denen auf einer Seite der Text fehlt (Scans, Leerseiten), im selben
///    Abstand zur naechsten zugeordneten Seite davor, sonst danach (ohne jede Zuordnung Seite fuer Seite). Hat eine
///    Fassung gar keinen Text, Seite fuer Seite (`byPosition`).
/// Alles andere gilt als entfernt (alte Seite) bzw. neu (neue Seite).
public enum PageMatch {
    /// `difflib.get_close_matches(cutoff=0.6)`
    public static let minimumRatio = 0.6
    /// je alter Seite hoechstens so viele Kandidaten fuer `ratio()` (nach `quick_ratio()`)
    static let candidatesPerPage = 5

    public enum Kind: String, Sendable, Equatable {
        case same = "gleich"
        case repeated = "wiederholt"
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

    /// Seite in der Ausrichtung: ihre Woerter; alle Seiten ohne Text haben denselben Schluessel (sie halten einen Block
    /// zusammen, zugeordnet werden sie erst in Schritt 4)
    private enum Key: Hashable {
        case text([String])
        case blank
    }

    public static func match(old: [String], new: [String]) -> Result {
        let wo = old.map(words), wn = new.map(words)
        if (!wo.isEmpty && wo.allSatisfy(\.isEmpty)) || (!wn.isEmpty && wn.allSatisfy(\.isEmpty)) {
            return byPosition(oldCount: old.count, newCount: new.count)
        }
        var newOf: [Int: Pair] = [:]                 // alte Seite (0-basiert) -> Paar
        var taken = Set<Int>()                       // neue Seiten (0-basiert)
        func assign(_ i: Int, _ j: Int, _ kind: Kind, _ ratio: Double) {
            newOf[i] = Pair(old: i + 1, new: j + 1, kind: kind, ratio: ratio)
            taken.insert(j)
        }

        // 1. gleich: Ausrichtung der Seitenfolgen. In einem Block mit Anker sind eindeutige Seiten sicher, mehrfach
        // vorkommende nur mit beiden Nachbarn im selben Block (bzw. am Anfang oder Ende beider Fassungen): sonst gehoert
        // z. B. eine Notizseite vor einem Kapitel in der einen Fassung zum Kapitel davor, in der anderen zu einem neuen.
        // Danach eindeutige verschobene Seiten.
        var inOld: [[String]: Int] = [:], inNew: [[String]: [Int]] = [:]
        for w in wo where !w.isEmpty { inOld[w, default: 0] += 1 }
        for (j, w) in wn.enumerated() where !w.isEmpty { inNew[w, default: []].append(j) }
        func unique(_ w: [String]) -> Bool { !w.isEmpty && inOld[w] == 1 && inNew[w]?.count == 1 }
        let ka = wo.map { $0.isEmpty ? Key.blank : .text($0) }, kb = wn.map { $0.isEmpty ? Key.blank : .text($0) }
        for blk in SequenceMatcher(ka, kb, autojunk: false).matchingBlocks()
        where (blk.i..<(blk.i + blk.size)).contains(where: { unique(wo[$0]) }) {
            for k in 0..<blk.size {
                let i = blk.i + k, j = blk.j + k
                guard !wo[i].isEmpty else { continue }
                let left = k > 0 || (i == 0 && j == 0)
                let right = k < blk.size - 1 || (i == wo.count - 1 && j == wn.count - 1)
                if unique(wo[i]) || (left && right) { assign(i, j, .same, 1) }
            }
        }
        for (i, w) in wo.enumerated() where newOf[i] == nil && unique(w) {
            if let j = inNew[w]?.first, !taken.contains(j) { assign(i, j, .same, 1) }
        }

        // 2. wiederholt: gleicher Text, nach der Lage zu den Nachbarn (zuerst gleicher Abstand zur Seite davor, dann
        // zur Seite danach, sonst die naechstgelegene, bei Gleichstand die fruehere)
        for (i, w) in wo.enumerated() where newOf[i] == nil && !w.isEmpty {
            let free = (inNew[w] ?? []).filter { !taken.contains($0) }
            guard !free.isEmpty else { continue }
            let expected = expectedPositions(i, newOf, count: wo.count)
            func rank(_ j: Int) -> (Int, Int, Int) {
                (expected.firstIndex(of: j) ?? expected.count, expected.map { abs($0 - j) }.min() ?? abs(i - j), j)
            }
            guard let j = free.min(by: { rank($0) < rank($1) }) else { continue }
            assign(i, j, .repeated, 1)
        }

        // 3. aehnlich
        let co = wo.map(SequenceMatcher<String>.counts), cn = wn.map(SequenceMatcher<String>.counts)
        var matchers: [Int: SequenceMatcher<String>] = [:]           // je neuer Seite einmal (b2j wie set_seq2)
        var candidates: [(ratio: Double, i: Int, j: Int)] = []
        let freeNew = wn.indices.filter { !taken.contains($0) && !wn[$0].isEmpty }
        for i in wo.indices where newOf[i] == nil && !wo[i].isEmpty {
            var quick: [(q: Double, j: Int)] = []
            for j in freeNew {
                guard SequenceMatcher<String>.realQuickRatio(wo[i].count, wn[j].count) >= minimumRatio else { continue }
                let q = SequenceMatcher.quickRatio(counts: co[i], length: wo[i].count, counts: cn[j], length: wn[j].count)
                if q >= minimumRatio { quick.append((q, j)) }
            }
            quick.sort { a, b in
                if a.q != b.q { return a.q > b.q }
                let da = abs(a.j - i), db = abs(b.j - i)
                return da != db ? da < db : a.j < b.j
            }
            for c in quick.prefix(candidatesPerPage) {
                var m = matchers[c.j] ?? SequenceMatcher([], wn[c.j])
                matchers[c.j] = m
                m.setSeq1(wo[i])
                let r = m.ratio()
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
            assign(c.i, c.j, .similar, c.ratio)
        }

        // 4. Position: zuerst Seiten ohne Text auf beiden Seiten, dann auf einer Seite (Scan statt Text und umgekehrt)
        for both in [true, false] {
            for i in wo.indices where newOf[i] == nil && (!both || wo[i].isEmpty) {
                var options = expectedPositions(i, newOf, count: wo.count)
                if options.isEmpty { options.append(i) }
                guard let j = options.first(where: { j in
                    wn.indices.contains(j) && !taken.contains(j) && (both ? wn[j].isEmpty : (wo[i].isEmpty || wn[j].isEmpty))
                }) else { continue }
                assign(i, j, .position, 0)
            }
        }
        return Result(oldCount: old.count, newCount: new.count, pairs: newOf.keys.sorted().compactMap { newOf[$0] })
    }

    /// Erwartete neue Seite (0-basiert) einer alten Seite `i`: gleicher Abstand zur naechsten zugeordneten Seite davor,
    /// dann zu der danach
    private static func expectedPositions(_ i: Int, _ newOf: [Int: Pair], count: Int) -> [Int] {
        var out: [Int] = []
        if let p = (0..<i).last(where: { newOf[$0] != nil }), let q = newOf[p]?.new { out.append((q - 1) + (i - p)) }
        if let s = ((i + 1)..<max(i + 1, count)).first(where: { newOf[$0] != nil }), let t = newOf[s]?.new {
            out.append((t - 1) - (s - i))
        }
        return out
    }
}
