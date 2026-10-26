import Foundation

/// Modul zu einem Kurs- oder Termintitel wie `timetable.guess_module` in app/timetable.py (Namensaehnlichkeit mit
/// Modulen und schon zugeordneten Kursen). Gebraucht von `POST /api/modules/auto-assign`; der Stundenplan-Import
/// (S5) braucht dieselbe Funktion.
public enum ModuleGuess {
    private static let token = PyRegex("[a-zäöü0-9]+")

    /// `guess_module(conn, title)`: Modul-ID ab einer Aehnlichkeit von 0.55, sonst nil
    public static func guessModule(_ c: SQLiteConnection, title: String?) throws -> SQLiteValue? {
        let mods = try c.query("SELECT id, name FROM modules")
        let courses = try c.query("SELECT module_id, title FROM courses WHERE module_id IS NOT NULL")
        let t = PyText.lower(title ?? "")
        var best: SQLiteValue? = .none                                     // nicht nil: SQLiteValue kennt nil als NULL
        var score = 0.0
        for m in mods {
            let n = PyText.lower(m["name"]?.string ?? "")
            var sc = SequenceMatcher(t, n).ratio()
            if PyText.contains(t, n) || PyText.contains(n, t) { sc = max(sc, 0.9) }
            // Kurztitel wie "Mathe I", "DuA", "GDS", "ET"
            let toks = token.findAll(n).filter { PyText.length($0) > 2 }
            let hit = toks.filter { PyText.contains(t, $0) }.count
            if !toks.isEmpty, Double(hit) / Double(toks.count) >= 0.5 {
                sc = max(sc, 0.6 + 0.4 * Double(hit) / Double(toks.count))
            }
            if sc > score { best = m["id"]; score = sc }
        }
        for course in courses {
            let n = PyText.lower(course["title"]?.string ?? "")
            var sc = SequenceMatcher(t, n).ratio()
            if PyText.contains(t, n) || PyText.contains(n, t) { sc = max(sc, 0.9) }
            if sc > score { best = course["module_id"]; score = sc }
        }
        return score >= 0.55 ? best : .none
    }
}

/// `difflib.SequenceMatcher(None, a, b)` aus Pythons Standardbibliothek, soweit `ratio()`, `quick_ratio()` und
/// `real_quick_ratio()` es brauchen: Folgen beliebiger Elemente (Texte als Codepunkte, Seitentexte als Woerter),
/// kein Muell-Filter, "autojunk" (haeufige Elemente ab 200 Elementen in b) wie dort. Gleiche Suche nach dem laengsten
/// gemeinsamen Block (frueheste Stelle in a, dann in b), also auch dieselben Bloecke und dasselbe Ergebnis. Die eine
/// Fassung fuer Modulnamen (`ModuleGuess`, Stundenplan) und die Seitenzuordnung einer neuen Fassung (`PageMatch`).
struct SequenceMatcher<Element: Hashable> {
    let a: [Element]
    let b: [Element]
    private var b2j: [Element: [Int]] = [:]

    init(_ a: [Element], _ b: [Element]) {
        self.a = a
        self.b = b
        for (i, elt) in self.b.enumerated() { b2j[elt, default: []].append(i) }
        let n = self.b.count
        if n >= 200 {
            let ntest = n / 100 + 1
            for (elt, idxs) in b2j where idxs.count > ntest { b2j[elt] = nil }
        }
    }

    /// `find_longest_match(alo, ahi, blo, bhi)` ohne Muell (bjunk ist leer, die Verlaengerung um Muell entfaellt)
    func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (i: Int, j: Int, size: Int) {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<max(alo, ahi) {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
            }
            j2len = newj2len
        }
        while besti > alo, bestj > blo, a[besti - 1] == b[bestj - 1] {
            besti -= 1; bestj -= 1; bestsize += 1
        }
        while besti + bestsize < ahi, bestj + bestsize < bhi, a[besti + bestsize] == b[bestj + bestsize] {
            bestsize += 1
        }
        return (besti, bestj, bestsize)
    }

    /// Summe der Laengen aus `get_matching_blocks()`
    func matches() -> Int {
        var queue = [(0, a.count, 0, b.count)]
        var total = 0
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = findLongestMatch(alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            total += k
            if alo < i, blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi, j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return total
    }

    /// `ratio()`: 2 * Treffer / (len(a) + len(b)), 1.0 fuer zwei leere Folgen
    func ratio() -> Double { Self.ratio(matches(), a.count + b.count) }

    /// `quick_ratio()`: obere Schranke von `ratio()` ueber die Schnittmenge als Multimengen
    func quickRatio() -> Double {
        var avail: [Element: Int] = [:]
        for elt in b { avail[elt, default: 0] += 1 }
        var matches = 0
        for elt in a {
            let numb = avail[elt, default: 0]
            avail[elt] = numb - 1
            if numb > 0 { matches += 1 }
        }
        return Self.ratio(matches, a.count + b.count)
    }

    /// `real_quick_ratio()`: obere Schranke nur aus den Laengen
    func realQuickRatio() -> Double { Self.ratio(min(a.count, b.count), a.count + b.count) }

    /// `_calculate_ratio(matches, length)`
    private static func ratio(_ matches: Int, _ length: Int) -> Double {
        length > 0 ? 2.0 * Double(matches) / Double(length) : 1.0
    }
}

extension SequenceMatcher where Element == Unicode.Scalar {
    /// Texte als Folgen von Codepunkten wie `SequenceMatcher(None, str_a, str_b)`
    init(_ a: String, _ b: String) { self.init(Array(a.unicodeScalars), Array(b.unicodeScalars)) }
}
