import Foundation

/// Kurznamen fuer enge Bloecke im Lernkalender (Woche, 3 Tage), Schritt fuer Schritt wie app/static/plan-names.js;
/// die gemeinsamen Faelle stehen in packages/shared-contracts/fixtures/plan-names/cases.json (Web und Swift).
///
/// 1. Titel bereinigen: Kursnummer am Anfang ("11051 ...", "7002 - ..."), Uebungs-/Tutoriumswort vorn oder hinten
///    (wird zum Praefix "Ue "), Vorlesungswort vorn, eingeklammerte Zusaetze ("(fuer Elektrotechnik)") und ", Tranche ..."
///    zaehlen nicht.
/// 2. Feste Eintraege nur am Anfang des bereinigten Titels (ganze Woerter), sonst allgemein: ein Wort bis 8 Buchstaben
///    bleibt, laengere werden an einer Silbengrenze gekuerzt ("Psych."); zwei Woerter je drei Buchstaben ("SigSys"); ab
///    drei Woertern die Anfangsbuchstaben ("EGI"). Fuellwoerter fallen weg, roemische Zahlen und Nummern bleiben.
/// 3. Haben verschiedene Faecher (Modul, bereinigter Titel, fester Eintrag) denselben Kurznamen, wird er verlaengert,
///    bis er eindeutig ist: feste Eintraege werden allgemein, sonst bekommt das erste Wort, in dem sich die Faecher
///    unterscheiden, einen Buchstaben mehr (ein Wort: naechste Silbengrenze), zuletzt der ganze Titel.
/// Gearbeitet wird auf Unicode-Skalaren (wie die Codepunkte in JavaScript), nicht auf Graphemen.
public enum PlanNames {
    private typealias S = [Unicode.Scalar]

    private static let separators = Set("-–—/,;:+&.|·()[]\"'„“”".unicodeScalars)
    private static let vowels = Set("aeiouyäöüàáâéèêëíìîïóòôúùû".unicodeScalars.map { String($0) })
    private static let stop: Set<String> = ["der", "die", "das", "des", "dem", "den", "und", "oder", "für", "fuer", "in", "im", "ins", "zu",
        "zum", "zur", "von", "vom", "mit", "an", "am", "auf", "aus", "bei", "über", "ueber", "unter", "nach", "vor", "ohne", "sowie", "bzw",
        "als", "ein", "eine", "einer", "eines", "einem", "einen", "the", "of", "and", "or", "for", "to", "a", "on", "with", "at", "by",
        "from", "into"]
    private static let exercise: Set<String> = ["übung", "uebung", "übungen", "gruppenübung", "gruppenuebung", "hörsaalübung",
        "hoersaaluebung", "zentralübung", "tutorium", "tutorien", "fragestunde", "fragestunden"]
    private static let lecture: Set<String> = ["vorlesung", "vl"]
    private static let linkers: Set<String> = ["zu", "zur", "zum"]
    /// Feste Kurznamen: ganze Woerter am Anfang (klein geschrieben, " & " gilt als "und"); Nummern danach werden angehaengt
    private static let fixed: [([String], String)] = [
        (["mathematik", "für", "die", "ingenieurwissenschaften", "iii"], "Numerik"), (["numerik"], "Numerik"),
        (["mathematik", "für", "die", "ingenieurwissenschaften", "ii"], "Mathe II"), (["mathematik", "ii"], "Mathe II"),
        (["mathematik", "für", "die", "ingenieurwissenschaften", "i"], "Mathe I"), (["mathematik", "i"], "Mathe I"),
        (["signale", "und", "systeme"], "SigSys"), (["datenstrukturen", "und", "algorithmen"], "DSA"),
        (["programmieren", "ii"], "Prog II"), (["programmieren", "i"], "Prog I"), (["einführung", "in", "die", "informatik"], "Info"),
        (["grundlagen", "digitaler", "systeme"], "DigiSys"), (["digitale", "systeme"], "DigiSys"),
    ]

    // MARK: Zeichen

    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 9...13, 32, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff: return true
        default: return false
        }
    }
    private static func str(_ s: S) -> String { var out = String.UnicodeScalarView(); out.append(contentsOf: s); return String(out) }
    private static func lower(_ s: String) -> String { s.lowercased() }
    private static func isDigit(_ c: Unicode.Scalar) -> Bool { ("0"..."9").contains(c) }

    /// collapse: Leerraum zu einem Leerzeichen, vorn und hinten weg
    private static func collapse(_ s: String) -> String {
        var out = S(), gap = false
        for c in s.unicodeScalars {
            if isSpace(c) { gap = !out.isEmpty } else {
                if gap { out.append(" ") }
                out.append(c)
                gap = false
            }
        }
        return str(out)
    }
    private static func words(_ s: String) -> [String] {
        s.unicodeScalars.split(separator: " ", omittingEmptySubsequences: true).map { str(Array($0)) }
    }
    private static func trim(_ s: String, _ chars: String) -> String {
        let set = Set(chars.unicodeScalars), a = Array(s.unicodeScalars)
        var i = 0, j = a.count
        while i < j && set.contains(a[i]) { i += 1 }
        while j > i && set.contains(a[j - 1]) { j -= 1 }
        return str(Array(a[i..<j]))
    }
    private static func withoutColon(_ w: String) -> String {
        var a = Array(w.unicodeScalars)
        if a.last == ":" { a.removeLast() }
        return str(a)
    }
    private static func isNumberToken(_ w: String) -> Bool {
        let a = Array(withoutColon(w).unicodeScalars)
        return !a.isEmpty && isDigit(a[0]) && a.allSatisfy { isDigit($0) || $0 == "." || $0 == "/" }
    }
    private static func isDash(_ w: String) -> Bool { w == "-" || w == "–" || w == "—" || w == ":" }
    private static func dropNumber(_ w: [String]) -> [String] {
        var w = w
        if w.count > 1 && isNumberToken(w[0]) {
            w.removeFirst()
            if w.count > 1 && isDash(w[0]) { w.removeFirst() }
        }
        return w
    }

    /// Eingeklammerte Zusaetze entfernen (auch "[...]"); true, wenn einer davon nur "Uebung", "Tutorium" ... ist
    private static func dropBrackets(_ s: String) -> (text: String, exercise: Bool) {
        let a = Array(s.unicodeScalars)
        var out = S(), ex = false, i = 0
        while i < a.count {
            let close: Unicode.Scalar? = a[i] == "(" ? ")" : a[i] == "[" ? "]" : nil
            guard let close, let j = a[(i + 1)...].firstIndex(of: close) else {
                out.append(a[i]); i += 1; continue
            }
            if exercise.contains(lower(collapse(str(Array(a[(i + 1)..<j]))))) { ex = true }
            while let last = out.last, isSpace(last) { out.removeLast() }
            out.append(" ")
            i = j + 1
        }
        return (str(out), ex)
    }

    /// Titel -> Praefix fuer Uebungen (oder "") und bereinigter Titel
    public static func parseTitle(_ title: String?) -> (pre: String, base: String) {
        let nfc = (title ?? "").precomposedStringWithCanonicalMapping
        var w = dropNumber(words(collapse(nfc))), pre = ""
        if w.count > 1 {
            let first = lower(w[0]), colon = first.unicodeScalars.last == ":", w0 = colon ? withoutColon(first) : first
            if exercise.contains(w0) || lecture.contains(w0) {
                var rest = Array(w.dropFirst())
                if !colon && rest.count > 1 && (linkers.contains(lower(rest[0])) || rest[0] == ":") { rest.removeFirst() }
                if exercise.contains(w0) { pre = "Ü " }
                w = dropNumber(rest)
            }
        }
        let br = dropBrackets(w.joined(separator: " "))
        if br.exercise { pre = "Ü " }
        w = words(collapse(br.text))
        // "... - Fragestunden", "... - Tutorium", "... Uebung" am Ende
        var i = w.count - 1
        while i > 0 {
            if isDash(w[i]) && i + 1 < w.count && exercise.contains(lower(w[i + 1])) { w = Array(w[..<i]); pre = "Ü "; break }
            i -= 1
        }
        if w.count > 1, let last = w.last, exercise.contains(lower(last)) { w.removeLast(); pre = "Ü " }
        if let tr = w.indices.first(where: { $0 > 0 && lower(trim(w[$0], ",")) == "tranche" }) { w = Array(w[..<tr]) }
        var base = trim(w.joined(separator: " "), " -–—:,(")
        if base.isEmpty { base = collapse(nfc) }
        return (pre, base)
    }

    // MARK: Zerlegung

    private static func tokens(_ base: String) -> [String] {
        var out: [String] = [], cur = S()
        for c in base.replacingOccurrences(of: " & ", with: " und ").unicodeScalars {
            if isSpace(c) || separators.contains(c) {
                if !cur.isEmpty { out.append(str(cur)) }
                cur = []
            } else {
                cur.append(c)
            }
        }
        if !cur.isEmpty { out.append(str(cur)) }
        return out
    }
    private static func isDesignator(_ w: String) -> Bool {
        let a = Array(w.unicodeScalars)
        if (1...4).contains(a.count) && a.allSatisfy({ $0 == "I" || $0 == "V" || $0 == "X" }) { return true }
        if a.count == 1 && ("A"..."Z").contains(a[0]) { return true }
        var k = 0
        while k < a.count && isDigit(a[k]) { k += 1 }
        return k > 0 && (k == a.count || (k == a.count - 1 && ("a"..."z").contains(a[k])))
    }
    private static func cap(_ s: String) -> String {
        let a = Array(s.unicodeScalars)
        guard let first = a.first else { return "" }
        return String(first).uppercased() + str(Array(a.dropFirst()))
    }
    private static func prefix(_ s: String, _ n: Int) -> String { str(Array(s.unicodeScalars.prefix(n))) }
    private static func length(_ s: String) -> Int { s.unicodeScalars.count }
    private static func isVowel(_ c: Unicode.Scalar) -> Bool { vowels.contains(lower(String(c))) }

    /// Kuerzungen eines langen Worts an Silbengrenzen ("Psychologie" -> "Psych.", "Psychol.", ...), zuletzt das ganze Wort
    private static func cuts(_ w: String) -> [String] {
        let a = Array(w.unicodeScalars)
        if a.count <= 8 { return [w] }
        var out: [String] = []
        for p in 3..<a.count where isVowel(a[p]) && !isVowel(a[p - 1]) { out.append(str(Array(a[..<p])) + ".") }
        if out.isEmpty { out.append(str(Array(a.prefix(6))) + ".") }
        out.append(w)
        return out
    }

    private struct Analysis {
        let base: String
        let fixed: String?
        let sig: [String]
        let des: [String]
        var words: [String] { Array(sig.prefix(6)) }
    }

    private static func analyse(_ base: String) -> Analysis {
        let toks = tokens(base), low = toks.map(lower)
        var fixedName: String?, rest = 0
        for (seq, name) in fixed where seq.count <= low.count && seq.enumerated().allSatisfy({ low[$0.offset] == $0.element }) {
            fixedName = name; rest = seq.count; break
        }
        var sig: [String] = [], des: [String] = []
        for (i, w) in toks.enumerated() {
            if i > 0 && isDesignator(w) { des.append(w) } else if !stop.contains(low[i]) { sig.append(w) }
        }
        let fixedDes = toks.enumerated().filter { $0.offset >= rest && $0.offset > 0 && isDesignator($0.element) }.map(\.element)
        return Analysis(base: base, fixed: fixedName.map { fixedDes.isEmpty ? $0 : $0 + " " + fixedDes.joined(separator: " ") },
                        sig: sig, des: des)
    }

    private enum Mode { case fixed, gen, full }
    private struct State: Equatable {
        var mode: Mode
        var cut = 0
        var lens: [Int]
    }

    private static func start(_ a: Analysis) -> State {
        State(mode: a.fixed != nil ? .fixed : .gen, lens: a.words.map { _ in a.words.count == 2 ? 3 : 1 })
    }

    private static func candidate(_ a: Analysis, _ st: State) -> String {
        if st.mode == .fixed, let f = a.fixed { return f }
        if st.mode == .full || a.sig.isEmpty { return a.base }
        let core: String
        if a.sig.count == 1 {
            let c = cuts(a.sig[0])
            core = c[min(st.cut, c.count - 1)]
        } else {
            core = a.words.enumerated().map { cap(prefix($0.element, st.lens[$0.offset])) }.joined()
        }
        return a.des.isEmpty ? core : core + " " + a.des.joined(separator: " ")
    }

    // MARK: Oeffentlich

    /// Kurzname ohne Blick auf andere Faecher
    public static func tinyName(_ title: String?) -> String {
        let p = parseTitle(title), a = analyse(p.base)
        return p.pre + candidate(a, start(a))
    }

    /// Kurznamen fuer alle Titel eines Plans: (Titel, Modul-ID) -> Titel -> Kurzname. Verschiedene Faecher bekommen
    /// verschiedene Kurznamen (ein Fach: gleiches Modul, gleicher bereinigter Titel oder gleicher fester Eintrag).
    public static func tinyNames(_ items: [(title: String, module: String?)]) -> [String: String] {
        var titles: [String] = [], modsOf: [String: Set<String>] = [:]
        for it in items {
            if modsOf[it.title] == nil { modsOf[it.title] = []; titles.append(it.title) }
            if let m = it.module, !m.isEmpty { modsOf[it.title]?.insert(m) }
        }
        // Faecher: Titel mit gleichem Modul, bereinigtem Titel oder festem Eintrag gehoeren zusammen (Union-Find)
        var parent: [String: String] = [:]
        func find(_ k: String) -> String {
            var k = k
            while let p = parent[k], p != k { k = p }
            return k
        }
        func union(_ x: String, _ y: String) {
            if parent[x] == nil { parent[x] = x }
            if parent[y] == nil { parent[y] = y }
            let a = find(x), b = find(y)
            if a != b { parent[max(a, b)] = min(a, b) }
        }
        struct Info { let t: String; let pre: String; let a: Analysis; var st: State; var fach = "" }
        var info = titles.map { t -> Info in
            let p = parseTitle(t), a = analyse(p.base)
            return Info(t: t, pre: p.pre, a: a, st: start(a))
        }
        for x in info {
            union("t:" + x.t, "n:" + lower(x.a.base))
            if let f = x.a.fixed { union("t:" + x.t, "f:" + f) }       // fester Eintrag: "Mathematik I" = "Mathematik fuer die ... I"
            for m in modsOf[x.t] ?? [] { union("t:" + x.t, "m:" + m) }
        }
        for i in info.indices { info[i].fach = find("t:" + info[i].t) }

        for _ in 0..<200 {
            var groups: [String: [Int]] = [:]
            for (i, x) in info.enumerated() { groups[candidate(x.a, x.st), default: []].append(i) }
            var changed = false
            for g in groups.values where Set(g.map { info[$0].fach }).count >= 2 {
                let fixedOnes = g.filter { info[$0].st.mode == .fixed }
                if !fixedOnes.isEmpty {
                    for i in fixedOnes { info[i].st = start(info[i].a); info[i].st.mode = .gen }
                    changed = true
                    continue
                }
                let gens = g.filter { info[$0].st.mode == .gen && !info[$0].a.sig.isEmpty }
                guard let firstGen = gens.first else { continue }
                let m = info[firstGen].a.words.count
                if m >= 2 && gens.allSatisfy({ info[$0].a.words.count == m }) {
                    var j: Int?
                    for k in 0..<m where j == nil {
                        let differ = Set(gens.map { lower(info[$0].a.words[k]) }).count > 1
                        if differ && gens.contains(where: { info[$0].st.lens[k] < length(info[$0].a.words[k]) }) { j = k }
                    }
                    if let j {
                        for i in gens where info[i].st.lens[j] < length(info[i].a.words[j]) { info[i].st.lens[j] += 1 }
                    } else {
                        for i in gens { info[i].st.mode = .full }
                    }
                } else if gens.allSatisfy({ info[$0].a.sig.count == 1 }) {
                    for i in gens {
                        if info[i].st.cut < cuts(info[i].a.sig[0]).count - 1 { info[i].st.cut += 1 } else { info[i].st.mode = .full }
                    }
                } else {
                    for i in gens { info[i].st.mode = .full }
                }
                changed = true
            }
            if !changed { break }
        }
        var out: [String: String] = [:]
        for x in info { out[x.t] = x.pre + candidate(x.a, x.st) }
        return out
    }

    /// Modul-ID eines Termins oder Pakets als Text wie `String(module_id)` in JavaScript (3 -> "3")
    public static func moduleKey(_ v: JSONValue?) -> String? {
        switch v {
        case .number(let d)?: return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s)?: return s.isEmpty ? nil : s
        default: return nil
        }
    }
}
