import Foundation

/// `difflib.SequenceMatcher(None, a, b).ratio()` wie in Python: Ratcliff/Obershelp ueber Unicode-Codepunkte, mit
/// "autojunk" (bei b ab 200 Zeichen gelten Zeichen, die oefter als 1 % + 1 vorkommen, als haeufig und beginnen keinen
/// Treffer). Gleiche Reihenfolge der Suche wie `find_longest_match`/`get_matching_blocks`, damit Gleichstaende gleich
/// ausgehen. Gebraucht von `guess_module` (app/timetable.py).
enum PySequenceMatcher {
    static func ratio(_ a: String, _ b: String) -> Double {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        let length = a.count + b.count
        guard length > 0 else { return 1.0 }
        return 2.0 * Double(matches(a, b)) / Double(length)
    }

    /// Summe der Laengen aller passenden Bloecke (`get_matching_blocks`)
    static func matches(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        var b2j: [Unicode.Scalar: [Int]] = [:]
        for (j, ch) in b.enumerated() { b2j[ch, default: []].append(j) }
        if b.count >= 200 {
            let ntest = b.count / 100 + 1
            for (ch, idx) in b2j where idx.count > ntest { b2j[ch] = nil }
        }

        func longest(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (i: Int, j: Int, k: Int) {
            var besti = alo, bestj = blo, bestsize = 0
            var j2len: [Int: Int] = [:]
            for i in alo..<max(alo, ahi) {
                var next: [Int: Int] = [:]
                for j in b2j[a[i]] ?? [] {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (j2len[j - 1] ?? 0) + 1
                    next[j] = k
                    if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
                }
                j2len = next
            }
            // ueber haeufige Zeichen verlaengern (ohne isjunk gibt es keine Junk-Zeichen)
            while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] {
                besti -= 1; bestj -= 1; bestsize += 1
            }
            while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] {
                bestsize += 1
            }
            return (besti, bestj, bestsize)
        }

        var queue = [(0, a.count, 0, b.count)]
        var total = 0
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = longest(alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            total += k
            if alo < i && blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return total
    }
}
