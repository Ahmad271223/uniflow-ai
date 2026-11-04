import Foundation

/// Textstueck einer PDF-Seite mit Lage in Leserichtung (links oben 0/0): x = linke Kante, y = senkrechte Mitte der
/// Zeile. Am Geraet aus PDFKit (`StudyCatalogPDF.planItems`), am PC aus pypdf (`pdf_items` in app/study_catalog.py).
public struct StudyPlanTextItem: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var text: String

    public init(x: Double, y: Double, text: String) {
        self.x = x
        self.y = y
        self.text = text
    }
}

/// Studienverlaufsplan der LUH-FEI (eine Seite aus PowerPoint: Semester als Zeilen "1." + "SEMESTER", Module als Kaesten
/// mit Titel, Lehrperson und "2V+2Ü | 5 ECTS") lesen und in den Modulkatalog mischen, Regel fuer Regel wie
/// `parse_study_plan` und `merge_study_plan` in app/study_catalog.py (Fixture plan-expected.json, byte-gleich).
public enum StudyPlanSheet {
    public static let format = "luh-fei-verlaufsplan"
    static let maxText = 500

    static let labelRx = #"^([0-9]{1,2})\. ?(?:fach)?semester$"#
    static let labelNumRx = #"^([0-9]{1,2})\.$"#
    static let labelWordRx = "^(?:fach)?semester$"
    static let lpRx = #"([0-9]+(?:[.,][0-9]+)?)(?: ?- ?([0-9]+(?:[.,][0-9]+)?))? ?(?:ECTS|LP)\b"#
    static let unitRx = "^(?:ECTS|LP)$"
    static let swsUnit = "(?:LÜ|LU|PR|PJ|SE|TU|V|Ü|U|S|L|P|T)"
    static let swsRx = "^(?:[0-9]+ ?" + swsUnit + "|(?:PR|PJ|SE|LÜ) ?[0-9]+)(?: ?\\+ ?[0-9]+ ?" + swsUnit + ")*$"
    static let inklRx = #" (?:inkl\.?|inklusive|einschl\.?|einschließlich) .*$"#
    static let stop: Set<String> = ["der", "die", "das", "des", "dem", "den", "und", "oder", "in", "im", "fuer", "von", "vom", "zu",
                                    "zur", "zum", "mit", "the", "of", "and", "a", "an", "for"]

    // MARK: Lesen

    /// Treffer mit Lage (Anfang in Codepunkten nicht noetig: Text davor und ab dem Treffer)
    static func lpSplit(_ s: String) -> (before: String, match: String, g1: String, g2: String?)? {
        let rx = CatalogRx.regex(lpRx)
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              let whole = Range(m.range, in: s), let r1 = Range(m.range(at: 1), in: s) else { return nil }
        let g2 = m.range(at: 2).location == NSNotFound ? nil : Range(m.range(at: 2), in: s).map { String(s[$0]) }
        return (String(s[..<whole.lowerBound]), String(s[whole.lowerBound...]), String(s[r1]), g2)
    }

    static func hasLetter(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
            default: return false
            }
        }
    }

    static func isMeta(_ t: String) -> Bool {
        lpSplit(t) != nil || CatalogRx.matches(unitRx, t) || CatalogRx.matches(swsRx, t) || !hasLetter(t)
    }

    /// Zeilen eines Kastens verbinden (`_plan_join`)
    static func join(_ lines: [String]) -> String {
        var out = ""
        for line in lines {
            if out.isEmpty {
                out = line
            } else if out.hasSuffix("-") && !out.hasSuffix(" -") && out.unicodeScalars.count > 1 {
                let lower = line.unicodeScalars.first?.properties.isLowercase ?? false
                out = lower ? String(String.UnicodeScalarView(out.unicodeScalars.dropLast())) + line : out + line
            } else {
                out += " " + line
            }
        }
        return out
    }

    struct Item {
        var x: Double
        var y: Double
        var text: String
        var index: Int
    }

    static func before(_ a: Item, _ b: Item, yFirst: Bool) -> Bool {
        let ka = yFirst ? (a.y, a.x) : (a.x, a.y), kb = yFirst ? (b.y, b.x) : (b.x, b.y)
        if ka.0 != kb.0 { return ka.0 < kb.0 }
        if ka.1 != kb.1 { return ka.1 < kb.1 }
        return a.index < b.index
    }

    /// Textstuecke je Seite -> {entries: [{semester, title, text, lp, lp_max}], footnote} (`parse_study_plan`)
    public static func parse(pages: [[StudyPlanTextItem]]) -> PyJSON {
        var entries: [PyJSON] = []
        var footnote: String?
        for raw in pages {
            var items: [Item] = []
            for it in raw {
                let t = StudyCatalogText.normalizeLines(it.text).joined(separator: " ")
                if t.isEmpty { continue }
                if let m = lpSplit(t) {
                    let b = StudyCatalogText.strip(m.before, " |")
                    if !b.isEmpty && hasLetter(b) && !CatalogRx.matches(swsRx, b) {
                        items.append(Item(x: it.x, y: it.y, text: b, index: items.count))
                        items.append(Item(x: it.x, y: it.y, text: m.match, index: items.count))
                        continue
                    }
                }
                items.append(Item(x: it.x, y: it.y, text: t, index: items.count))
            }
            // Semester-Beschriftungen
            var labels: [(y: Double, n: Int, x: Double, i: Int)] = []
            var used = Set<Int>()
            for o in items {
                if let m = CatalogRx.match(labelRx, o.text, ignoreCase: true), let n = Int(m[1] ?? "") {
                    labels.append((o.y, n, o.x, o.index))
                    used.insert(o.index)
                    continue
                }
                guard let m = CatalogRx.match(labelNumRx, o.text), let n = Int(m[1] ?? "") else { continue }
                let words = items.filter {
                    !used.contains($0.index) && $0.index != o.index && CatalogRx.match(labelWordRx, $0.text, ignoreCase: true) != nil
                        && abs($0.x - o.x) <= 40 && $0.y - o.y > 0 && $0.y - o.y <= 40
                }.map { ($0.y - o.y, $0.index) }
                if let w = words.min(by: { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }) {
                    labels.append((o.y, n, o.x, o.index))
                    used.insert(o.index)
                    used.insert(w.1)
                }
            }
            if labels.count < 2 { continue }
            labels.sort { a, b in
                if a.y != b.y { return a.y < b.y }
                if a.n != b.n { return a.n < b.n }
                if a.x != b.x { return a.x < b.x }
                return a.i < b.i
            }
            let diffs = (0..<(labels.count - 1)).map { labels[$0 + 1].y - labels[$0].y }.sorted()
            let spacing = diffs[diffs.count / 2]
            if spacing <= 0 { continue }
            var bands: [(n: Int, top: Double, bottom: Double)] = []
            for (k, l) in labels.enumerated() {
                let bottom = k + 1 < labels.count ? labels[k + 1].y - 0.25 * spacing : l.y + 0.75 * spacing
                bands.append((l.n, l.y - 0.25 * spacing, bottom))
            }
            func inBand(_ y: Double) -> Bool { bands.contains { $0.top <= y && y < $0.bottom } }

            let free = items.filter { !used.contains($0.index) }
            // Fussnote "* ..."
            let outside = free.filter { !inBand($0.y) }
            let stars = outside.filter { $0.text.hasPrefix("*") }.sorted { before($0, $1, yFirst: true) }
            if let first = stars.first, footnote == nil {
                var lines: [String] = []
                var last: Double?
                for o in outside.filter({ abs($0.x - first.x) <= 3 && $0.y >= first.y }).sorted(by: { before($0, $1, yFirst: true) }) {
                    if let l = last, o.y - l > 0.25 * spacing { break }
                    lines.append(o.text)
                    last = o.y
                }
                let f = String(join(lines).drop { $0 == "*" || $0 == " " })
                footnote = f.isEmpty ? nil : f
            }
            // Spalten je Semester
            var perBand: [(n: Int, inside: [Item], anchors: [Double])] = []
            for b in bands {
                let inside = free.filter { b.top <= $0.y && $0.y < b.bottom }
                let content = inside.filter { !isMeta($0.text) }.sorted { before($0, $1, yFirst: false) }
                var anchors: [Double] = []
                for o in content where anchors.isEmpty || o.x - anchors.last! > 4 { anchors.append(o.x) }
                perBand.append((b.n, inside, anchors))
            }
            let allAnchors = Set(perBand.flatMap(\.anchors)).sorted()
            let gaps = perBand.flatMap { band in zip(band.anchors, band.anchors.dropFirst()).map { $1 - $0 } }
            let pitch = gaps.min() ?? spacing
            let right = allAnchors.last.map { $0 + pitch } ?? 0
            for band in perBand {
                var content: [Double: [Item]] = [:], meta: [Double: [Item]] = [:]
                for o in band.inside {
                    if isMeta(o.text) {
                        if let a = band.anchors.filter({ $0 <= o.x + 4 }).max(), o.x <= right { meta[a, default: []].append(o) }
                    } else if let a = band.anchors.filter({ $0 <= o.x }).max() {
                        content[a, default: []].append(o)
                    }
                }
                for a in band.anchors {
                    let lines = (content[a] ?? []).sorted { before($0, $1, yFirst: true) }
                    let metas = (meta[a] ?? []).sorted { before($0, $1, yFirst: true) }
                    guard let first = lines.first, let m = lpSplit(metas.map(\.text).joined(separator: " ")) else { continue }
                    var segs: [[Item]] = [[first]]
                    for (prev, cur) in zip(lines, lines.dropFirst()) {
                        if cur.y - prev.y > 0.2 * spacing { segs.append([cur]) } else { segs[segs.count - 1].append(cur) }
                    }
                    let title = join(segs[0].map(\.text))
                    let text = segs.map { join($0.map(\.text)) }.joined(separator: " ")
                    entries.append(.object([
                        .init("semester", .int(String(band.n))), .init("title", .string(StudyCatalogText.prefix(title, maxText))),
                        .init("text", .string(StudyCatalogText.prefix(text, maxText))),
                        .init("lp", StudyCatalogParser.num(StudyCatalogParser.number(m.g1))),
                        .init("lp_max", m.g2.map { StudyCatalogParser.num(StudyCatalogParser.number($0)) } ?? .null),
                    ]))
                }
            }
        }
        return .object([.init("entries", .array(entries)),
                        .init("footnote", footnote.map { .string(StudyCatalogText.prefix($0, maxText)) } ?? .null)])
    }

    // MARK: Mischen

    static func tokens(_ text: String) -> [String] {
        StudyCatalogText.tokens(StudyCatalogText.fold(text)).map { StudyCatalogText.roman[$0] ?? $0 }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur.append(Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Bereiche, die ein Wahlkasten (mit Fussnote) nennt (`_plan_areas`)
    static func areas(_ text: String, _ areas: [(id: String, name: String)]) -> [String] {
        let toks = tokens(text).filter { !stop.contains($0) }
        let have = Set(toks)
        var sig: [String: [String]] = [:]
        for a in areas { sig[a.id] = tokens(a.name).filter { !stop.contains($0) } }
        var out: [String] = []
        for a in areas {
            let s = sig[a.id] ?? []
            if s.isEmpty || out.contains(a.id) { continue }
            if s.allSatisfy(have.contains) {
                out.append(a.id)
                continue
            }
            let group = areas.filter { Array((sig[$0.id] ?? []).prefix(1)) == Array(s.prefix(1)) }
            if group.count < 2 { continue }
            let seconds = Set(group.compactMap { b -> String? in let t = sig[b.id] ?? []; return t.count > 1 ? t[1] : nil })
            if toks.indices.contains(where: { k in toks[k] == s[0] && (k + 1 >= toks.count || !seconds.contains(toks[k + 1])) }) {
                out.append(a.id)
            }
        }
        return out
    }

    static func slotTitle(_ text: String) -> String {
        let s = StudyCatalogText.strip(CatalogRx.sub(" {2,}", " ", text.replacingOccurrences(of: "*", with: "")))
        let t = StudyCatalogText.prefix(s, maxText)
        return t.isEmpty ? "Wahlmodul" : t
    }

    /// Katalog + Plan -> (Katalog mit `semester` laut Plan und `plan_slots`, nicht zugeordnete Kaesten), wie
    /// `merge_study_plan`. `source` (url, fetched_at, sha256) kommt als `study_plan` in den Katalog.
    public static func merge(catalog: PyJSON, plan: PyJSON, source: (url: String, fetchedAt: String?, sha256: String?)? = nil) -> (PyJSON, [String]) {
        let areaList: [(id: String, name: String)] = (catalog.planMember("areas")?.planArray ?? []).compactMap { a in
            guard let id = a.planMember("id")?.planString else { return nil }
            return (id, a.planMember("name")?.planString ?? "")
        }
        var modules = catalog.planMember("modules")?.planArray ?? []
        let modIdx = modules.indices.filter { modules[$0].planMember("id")?.planString != nil }
        let mtoks = modIdx.map { tokens(modules[$0].planMember("title")?.planString ?? "") }
        let mkeys = mtoks.map { $0.joined() }
        var akeys: [String: String] = [:]
        for a in areaList { let k = tokens(a.name).joined(); if akeys[k] == nil { akeys[k] = a.id } }
        let footnote = plan.planMember("footnote")?.planString ?? ""
        var assigned: [String: Int] = [:]
        var slots: [PyJSON] = []
        var slotAreas: [[String]] = []
        var unmatched: [String] = []

        func numOrNull(_ v: PyJSON?) -> PyJSON {
            switch v {
            case .int?, .float?: return v!
            default: return .null
            }
        }
        func slot(_ e: PyJSON, _ ids: [String]) {
            let t = e.planMember("text")?.planString.flatMap { $0.isEmpty ? nil : $0 } ?? e.planMember("title")?.planString ?? ""
            slots.append(.object([.init("semester", e.planMember("semester") ?? .null), .init("title", .string(slotTitle(t))),
                                  .init("areas", .array(ids.map { .string($0) })), .init("lp", numOrNull(e.planMember("lp"))),
                                  .init("lp_max", numOrNull(e.planMember("lp_max")))]))
            slotAreas.append(ids)
        }

        for e in plan.planMember("entries")?.planArray ?? [] {
            guard let sem = e.planMember("semester")?.planInt, let title = e.planMember("title")?.planString else { continue }
            let toks = tokens(CatalogRx.sub(inklRx, "", title, ignoreCase: true))
            let key = toks.joined()
            if key.isEmpty { continue }
            var hit = mkeys.firstIndex(of: key)
            if hit == nil, let a = akeys[key] {
                slot(e, [a])
                continue
            }
            if hit == nil {
                let pre = mtoks.indices.filter { toks.count < mtoks[$0].count && Array(mtoks[$0].prefix(toks.count)) == toks }
                if pre.count > 1 {
                    var ids: [String] = []
                    for k in pre {
                        if let a = modules[modIdx[k]].planMember("area")?.planString, !ids.contains(a) { ids.append(a) }
                    }
                    slot(e, ids)
                    continue
                }
                hit = pre.first
            }
            if hit == nil && key.unicodeScalars.count >= 12 {
                let ds = mkeys.map { levenshtein(key, $0) }
                let best = ds.min() ?? 99
                if best <= 2 && ds.filter({ $0 == best }).count == 1 { hit = ds.firstIndex(of: best) }
            }
            if let h = hit {
                let id = modules[modIdx[h]].planMember("id")!.planString!
                if assigned[id] == nil { assigned[id] = sem }
                continue
            }
            let full = e.planMember("text")?.planString.flatMap { $0.isEmpty ? nil : $0 } ?? title
            if StudyCatalogText.fold(full).contains("wahl") {
                slot(e, areas(full + (full.contains("*") && !footnote.isEmpty ? " " + footnote : ""), areaList))
                continue
            }
            unmatched.append(title)
        }

        let covered = Set(slotAreas.flatMap { $0 })
        for i in modIdx {
            let m = modules[i]
            let id = m.planMember("id")!.planString!
            if let s = assigned[id] {
                modules[i] = m.planSetting("semester", .int(String(s)))
            } else if ["wahlpflicht", "wahl"].contains(m.planMember("kind")?.planString ?? "")
                        || (m.planMember("area")?.planString.map(covered.contains) ?? false) {
                modules[i] = m.planSetting("semester", .null)
            }
        }
        var out = catalog.planSetting("modules", .array(modules))
        if let source {
            out = out.planSetting("study_plan", .object([.init("url", .string(source.url)),
                                                         .init("fetched_at", source.fetchedAt.map { .string($0) } ?? .null),
                                                         .init("sha256", source.sha256.map { .string($0) } ?? .null)]))
        }
        out = out.planSetting("plan_slots", .array(slots))
        return (out, unmatched)
    }
}

extension PyJSON {
    func planMember(_ key: String) -> PyJSON? {
        guard case .object(let ms) = self else { return nil }
        return ms.first { $0.key == key }?.value
    }

    func planSetting(_ key: String, _ value: PyJSON) -> PyJSON {
        guard case .object(var ms) = self else { return self }
        if let i = ms.firstIndex(where: { $0.key == key }) { ms[i].value = value } else { ms.append(.init(key, value)) }
        return .object(ms)
    }

    var planString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var planArray: [PyJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Ganze Zahl wie `_is_int` in Python (auch 5.0)
    var planInt: Int? {
        switch self {
        case .int(let s): return Int(s)
        case .float(let d): return d.isFinite && d == d.rounded(.towardZero) ? Int(d) : nil
        default: return nil
        }
    }
}
