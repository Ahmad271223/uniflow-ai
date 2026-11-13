import Foundation

/// Smart Planner 2.0 wie app/smart_planner.py (Auftrag des Inhabers vom 12.11.2026, docs/SMART-PLANNER-2.md):
/// deterministischer Stundenplaner ohne Datenbank, Uhr und KI, nur ganze Zahlen. Ein- und Ausgabe sind JSON wie in
/// Python; Ergebnisgleichheit: `SmartPlannerParityTests` gegen smart-planner.json (tools/gen-smart-planner-fixture.py).
///
/// Harte Bedingungen: nur in freien Fenstern (Termine, Schlaf, Freizeit, Verpflichtungen, Arbeit, feste Bloecke sind
/// abgezogen), heute nicht vor jetzt, nie am oder nach dem Klausurtag, je Tag hoechstens Nutzungsquote x freie Zeit.
/// Machbarkeit kumuliert je Klausur; bei Unterdeckung kein scheinbar vollstaendiger Plan, sondern Optionen.
enum SmartPlanner {
    static let unit = 15
    static let kindRank: [String: Int] = ["klausur": 0, "uebung": 1, "vorlesung": 2, "loesung": 3, "skript": 4]

    struct PlanError: Error, CustomStringConvertible {
        let description: String
    }

    typealias Iv = (a: Int, b: Int)

    // MARK: Python-Werte

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
    }

    static func ceilDiv(_ a: Int, _ b: Int) -> Int { -floorDiv(-a, b) }

    /// `int(v or 0)`
    static func num(_ v: JSONValue?) -> Int {
        switch v {
        case .number(let d)?: return d.isFinite ? Int(d) : 0
        case .string(let s)?: return Int(s) ?? 0
        case .bool(let b)?: return b ? 1 : 0
        default: return 0
        }
    }

    /// Wahrheitswert wie Python (`x.get(k, True)`)
    static func truthy(_ v: JSONValue?, default d: Bool) -> Bool {
        switch v {
        case nil: return d
        case .null?: return false
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0
        case .string(let s)?: return !s.isEmpty
        case .array(let a)?: return !a.isEmpty
        case .object(let o)?: return !o.isEmpty
        }
    }

    /// `str(v)` fuer IDs (ganze Zahlen ohne ".0")
    static func pyStr(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s)?: return s
        case .number(let d)?: return d == d.rounded() && abs(d) < 9.0e15 ? String(Int(d)) : String(d)
        case .bool(let b)?: return b ? "True" : "False"
        default: return "None"
        }
    }

    static func less(_ a: String, _ b: String) -> Bool { PyText.less(a, b) }

    static func n(_ i: Int) -> JSONValue { .number(Double(i)) }

    static func ivs(_ v: JSONValue?) -> [Iv] {
        (v?.array ?? []).compactMap { x in
            guard let p = x.array, p.count >= 2 else { return nil }
            return (num(p[0]), num(p[1]))
        }
    }

    static func ivJSON(_ xs: [Iv]) -> JSONValue { .array(xs.map { .array([n($0.a), n($0.b)]) }) }

    /// "12,5 h" / "320 h"
    static func hoursText(_ minutes: Int) -> String {
        let tenths = (abs(minutes) * 10 + 30) / 60
        let t = tenths % 10 == 0 ? "\(tenths / 10) h" : "\(tenths / 10),\(tenths % 10) h"
        return minutes < 0 ? "-" + t : t
    }

    // MARK: Intervalle

    static func merge(_ xs: [Iv]) -> [Iv] {
        var out: [Iv] = []
        for x in xs.filter({ $0.b > $0.a }).sorted(by: { $0.a != $1.a ? $0.a < $1.a : $0.b < $1.b }) {
            if let last = out.last, x.a <= last.b {
                out[out.count - 1].b = max(last.b, x.b)
            } else {
                out.append(x)
            }
        }
        return out
    }

    static func subtract(_ windows: [Iv], _ busy: [Iv]) -> [Iv] {
        var out: [Iv] = []
        let bs = merge(busy)
        for w in merge(windows) {
            var cur = w.a
            for x in bs {
                if x.b <= cur || x.a >= w.b { continue }
                if x.a > cur { out.append((cur, x.a)) }
                cur = max(cur, x.b)
                if cur >= w.b { break }
            }
            if cur < w.b { out.append((cur, w.b)) }
        }
        return out
    }

    static func usable(_ windows: [Iv], minBlock: Int, notBefore: Int?) -> [Iv] {
        var out: [Iv] = []
        for w in windows {
            var a = w.a
            if let nb = notBefore { a = max(a, nb) }
            a = ceilDiv(a, unit) * unit
            let b = floorDiv(w.b, unit) * unit
            if b - a >= max(minBlock, unit) { out.append((a, b)) }
        }
        return out
    }

    // MARK: Tagesrahmen

    static let frameDefaults: [String: JSONValue] = ["sleep_minutes": 600, "bedtime": 1380, "leisure_minutes": 120,
                                                     "learn_days": [0, 1, 2, 3, 4, 5, 6]]

    /// `day_frame(settings, weekday)`
    static func dayFrame(_ settings: [String: JSONValue], weekday: Int) -> (frame: Iv, reserve: Iv?)? {
        let s = frameDefaults.merging(settings) { $1 }
        let days = (s["learn_days"]?.array ?? []).map { num($0) }
        guard days.contains(weekday) else { return nil }
        let bed = num(s["bedtime"]), sleep = num(s["sleep_minutes"]), leisure = num(s["leisure_minutes"])
        if sleep >= 1440 || sleep < 0 || leisure < 0 { return nil }
        let wake = floorDiv(bed + sleep, 1440) * -1440 + bed + sleep
        let end = bed > wake ? bed : 1440
        if end - leisure <= wake { return nil }
        return ((wake, end - leisure), leisure > 0 ? (end - leisure, end) : nil)
    }

    /// `build_days(dates, settings)`
    static func buildDays(_ dates: [JSONValue], settings: [String: JSONValue]) -> [JSONValue] {
        let s = frameDefaults.merging(settings) { $1 }
        return dates.map { d in
            let wd = num(d["weekday"])
            let date = d["date"] ?? .null
            guard let fr = dayFrame(s, weekday: wd) else {
                return ["date": date, "weekday": n(wd), "windows": [], "reserve": []]
            }
            let commit: [Iv] = (s["commitments"]?.array ?? []).compactMap { c in
                guard let w = c["weekday"], w == .number(Double(wd)) else { return nil }
                return (num(c["start"]), num(c["end"]))
            }
            let busy = ivs(d["busy"]) + commit
            return ["date": date, "weekday": n(wd), "windows": ivJSON(subtract([fr.frame], busy)),
                    "reserve": ivJSON(fr.reserve.map { subtract([$0], busy) } ?? [])]
        }
    }

    // MARK: Eingabe

    struct Day {
        let date: String
        let weekday: Int
        let windows: [Iv]
        let reserve: [Iv]
    }

    struct Settings {
        var utilization: Int
        var minBlock: Int
        var maxBlock: Int
        var brk: Int
        var maxDay: Int
        var maxWeek: Int
    }

    struct Fixed {
        let module: JSONValue
        let date: String
        let start: Int
        let end: Int
        let counts: Bool
    }

    struct Mod {
        let id: JSONValue
        let order: Int
        var E: Int
        let rem: Int
        let need: Int
        let fixed: Int
        let exam: String?
        let priority: Int
        let exam2: String?
        let passed: Bool
    }

    struct Pref {
        let module: JSONValue
        let date: String
        let start: Int
        let end: Int
    }

    struct Input {
        let days: [Day]
        let fixed: [Fixed]
        let prefer: [Pref]
        let now: Int?
        let settings: Settings
        let modules: [Mod]
        let partial: Bool

        init(_ inp: JSONValue) throws {
            days = (inp["days"]?.array ?? []).map {
                Day(date: $0["date"]?.string ?? "", weekday: num($0["weekday"]), windows: ivs($0["windows"]), reserve: ivs($0["reserve"]))
            }
            fixed = (inp["fixed"]?.array ?? []).map {
                Fixed(module: $0["module_id"] ?? .null, date: $0["date"]?.string ?? "", start: num($0["start"]), end: num($0["end"]),
                      counts: truthy($0["counts"], default: true))
            }
            prefer = (inp["prefer"]?.array ?? []).map {
                Pref(module: $0["module_id"] ?? .null, date: $0["date"]?.string ?? "", start: num($0["start"]), end: num($0["end"]))
            }
            now = inp["now_minute"].flatMap { $0.isNull ? nil : num($0) }
            var s = ["utilization": 60, "min_block": 30, "max_block": 120, "break": 10, "max_day_minutes": 0, "max_week_minutes": 0] as [String: JSONValue]
            for (k, v) in inp["settings"]?.object ?? [:] { s[k] = v }
            let minBlock = max(unit, num(s["min_block"]))
            settings = Settings(utilization: min(100, max(1, num(s["utilization"]))), minBlock: minBlock,
                                maxBlock: max(minBlock, num(s["max_block"])), brk: floorDiv(max(0, num(s["break"])), 5) * 5,
                                maxDay: num(s["max_day_minutes"]), maxWeek: num(s["max_week_minutes"]))
            partial = truthy(inp["accept_partial"], default: false)
            let h = days.count
            var index: [String: Int] = [:]
            for (i, d) in days.enumerated() where index[d.date] == nil { index[d.date] = i }
            let first = days.first?.date ?? "", last = days.last?.date ?? ""
            var mods: [Mod] = []
            for (k, m) in (inp["modules"]?.array ?? []).enumerated() {
                let exam = m["exam_date"]?.string
                let e: Int
                if let exam {
                    if h == 0 || !less(first, exam) { e = 0 } else if let i = index[exam] { e = i } else if less(last, exam) { e = h } else {
                        throw PlanError(description: "Klausurtag fehlt in den Tagen: \(exam)")
                    }
                } else {
                    e = h
                }
                let id = m["id"] ?? .null
                let fx = fixed.filter { $0.module == id && $0.counts && (exam == nil || less($0.date, exam!)) }.reduce(0) { $0 + $1.end - $1.start }
                let need = max(0, num(m["remaining_minutes"]) - fx)
                let pr = num(m["priority"])
                mods.append(Mod(id: id, order: k, E: e, rem: e > 0 ? ceilDiv(need, unit) : 0, need: need, fixed: fx, exam: exam,
                                priority: pr == 0 ? 2 : pr, exam2: m["exam_date_2"]?.string, passed: exam != nil && e == 0))
            }
            modules = mods
        }
    }

    // MARK: Kapazitaet

    static func windows(_ inp: Input, extra: Int = 0, gross: Bool = false) -> [[Iv]] {
        var fixed: [String: [Iv]] = [:]
        if !gross { for b in inp.fixed { fixed[b.date, default: []].append((b.start, b.end)) } }
        return inp.days.enumerated().map { i, d in
            var ws = d.windows
            if extra > 0 {
                var left = extra
                for r in merge(d.reserve) {
                    let take = min(left, r.b - r.a)
                    if take > 0 {
                        ws.append((r.a, r.a + take))
                        left -= take
                    }
                }
            }
            let free = subtract(merge(ws), fixed[d.date] ?? [])
            return usable(free, minBlock: inp.settings.minBlock, notBefore: i == 0 ? inp.now : nil)
        }
    }

    static func caps(_ inp: Input, _ wins: [[Iv]], quota: Int) -> [Int] {
        let dm = floorDiv(inp.settings.maxDay, unit), wk = floorDiv(inp.settings.maxWeek, unit)
        var out: [Int] = []
        var used = 0
        var prev: Int?
        for (i, d) in inp.days.enumerated() {
            var c = wins[i].reduce(0) { $0 + floorDiv($1.b - $1.a, unit) } * quota / 100
            if dm != 0 { c = min(c, dm) }
            if wk != 0 {
                if prev == nil || d.weekday <= prev! { used = 0 }
                c = min(c, max(0, wk - used))
                used += c
            }
            prev = d.weekday
            out.append(c)
        }
        return out
    }

    /// `_fixed_units`: Einheiten fester Bloecke je Tag innerhalb der nutzbaren Zeit
    static func fixedUnits(_ inp: Input, _ gwins: [[Iv]]) -> [Int] {
        var per: [String: [Iv]] = [:]
        for b in inp.fixed { per[b.date, default: []].append((b.start, b.end)) }
        return inp.days.enumerated().map { i, d in
            var n = 0
            for x in merge(per[d.date] ?? []) {
                for w in gwins[i] { n += max(0, min(x.b, w.b) - max(x.a, w.a)) }
            }
            return floorDiv(n, unit)
        }
    }

    /// `_net`: Tagesbudget mit festen Bloecken
    static func net(_ inp: Input, quota: Int, extra: Int = 0) -> (cap: [Int], gcap: [Int], wins: [[Iv]]) {
        let gw = windows(inp, extra: extra, gross: true)
        let nw = windows(inp, extra: extra)
        let gcap = caps(inp, gw, quota: quota)
        let fx = fixedUnits(inp, gw)
        let free = nw.map { $0.reduce(0) { $0 + floorDiv($1.b - $1.a, unit) } }
        return (gcap.indices.map { max(0, min(gcap[$0] - fx[$0], free[$0])) }, gcap, nw)
    }

    static func prefix(_ cap: [Int]) -> [Int] {
        var p = [0]
        for c in cap { p.append(p[p.count - 1] + c) }
        return p
    }

    struct Deadline {
        let E: Int
        let need: Int
        let available: Int
        let missing: Int
        let modules: [JSONValue]
    }

    static func deadlines(_ mods: [Mod], _ p: [Int], rem: [Int: Int]? = nil) -> [Deadline] {
        let rem = rem ?? Dictionary(uniqueKeysWithValues: mods.map { ($0.order, $0.rem) })
        let es = Set(mods.filter { $0.E > 0 && rem[$0.order]! > 0 }.map(\.E)).sorted()
        return es.map { e in
            let need = mods.filter { $0.E > 0 && $0.E <= e }.reduce(0) { $0 + rem[$1.order]! }
            return Deadline(E: e, need: need, available: p[e], missing: max(0, need - p[e]),
                            modules: mods.filter { $0.E == e && rem[$0.order]! > 0 }.map(\.id))
        }
    }

    static func feasible(_ mods: [Mod], _ p: [Int], rem: [Int: Int]? = nil) -> Bool {
        deadlines(mods, p, rem: rem).allSatisfy { $0.missing == 0 }
    }

    // MARK: Verteilen

    /// `_place`: bisherige Lagen zuerst, dann der Reihe nach in die erste freie Luecke
    static func place(_ ws: [Iv], wants: [(key: Int, units: Int)], minU: Int, maxU: Int, brk: Int,
                      prefer: [Int: [Iv]]? = nil) -> [(key: Int, a: Int, b: Int)] {
        var free: [[Iv]] = ws.map { [$0] }
        var out: [(key: Int, a: Int, b: Int)] = []
        func take(_ k: Int, _ j: Int, _ a: Int, _ b: Int) {
            let x = free[k][j]
            var repl: [Iv] = []
            if a > x.a { repl.append((x.a, a)) }
            if x.b > b { repl.append((b, x.b)) }
            free[k].replaceSubrange(j...j, with: repl)
        }
        var left: [Int: Int] = [:]
        for w in wants { left[w.key] = w.units }
        for w in wants {
            let pref = (prefer?[w.key] ?? []).sorted { $0.a != $1.a ? $0.a < $1.a : $0.b < $1.b }
            for slot in pref {
                let u = floorDiv(slot.b - slot.a, unit)
                if u <= 0 || u > left[w.key]! { continue }
                var spot: (Int, Int)?
                outer: for k in free.indices {
                    for (j, x) in free[k].enumerated() where x.a <= slot.a && slot.b <= x.b {
                        spot = (k, j)
                        break outer
                    }
                }
                if let (k, j) = spot {
                    take(k, j, slot.a, slot.b)
                    out.append((w.key, slot.a, slot.b))
                    left[w.key]! -= u
                }
            }
        }
        for w in wants {
            var rest = left[w.key]!
            for k in free.indices {
                var j = 0
                while rest > 0 && j < free[k].count {
                    let x = free[k][j]
                    var start = x.a
                    if brk > 0 && out.contains(where: { $0.b == x.a }) {
                        let loss = floorDiv(x.b - x.a, unit) - floorDiv(x.b - x.a - brk, unit)
                        let spare = free.reduce(0) { $0 + $1.reduce(0) { $0 + floorDiv($1.b - $1.a, unit) } } - left.values.reduce(0, +)
                        if floorDiv(x.b - x.a - brk, unit) >= min(rest, maxU) && spare >= loss { start = x.a + brk }
                    }
                    var p = min(rest, maxU, floorDiv(x.b - start, unit))
                    if p < rest && rest - p < minU && rest - minU >= minU { p = min(p, rest - minU) }
                    if p <= 0 || (p < minU && p < rest) {
                        j += 1
                        continue
                    }
                    take(k, j, start, start + p * unit)
                    out.append((w.key, start, start + p * unit))
                    rest -= p
                    left[w.key] = rest
                }
                if rest == 0 { break }
            }
            left[w.key] = rest
        }
        return out.enumerated().sorted { $0.element.a != $1.element.a ? $0.element.a < $1.element.a : $0.offset < $1.offset }.map(\.element)
    }

    /// `_module_fixed`: je Modul und Tag die Einheiten seiner festen, angerechneten Bloecke vor der Klausur
    static func moduleFixed(_ inp: Input, _ mods: [Mod]) -> [Int: [Int: Int]] {
        var index: [String: Int] = [:]
        for (i, d) in inp.days.enumerated() where index[d.date] == nil { index[d.date] = i }
        var out: [Int: [Int: Int]] = [:]
        for m in mods {
            var per: [Int: Int] = [:]
            for b in inp.fixed where b.module == m.id && b.counts {
                if let i = index[b.date], i < m.E { per[i, default: 0] += floorDiv(b.end - b.start, unit) }
            }
            out[m.order] = per
        }
        return out
    }

    static func allocate(_ inp: Input, _ mods: [Mod], _ wins: [[Iv]], _ cap: [Int], _ p: [Int], gcap: [Int], mfix: [Int: [Int: Int]])
        -> (blocks: [(module: Int, day: Int, a: Int, b: Int)], rem: [Int: Int], planned: [Int: Int]) {
        let minU = inp.settings.minBlock / unit, maxU = inp.settings.maxBlock / unit
        let gp = prefix(gcap)
        var later = Dictionary(uniqueKeysWithValues: mfix.map { ($0.key, $0.value.values.reduce(0, +)) })
        var prefer: [String: [Int: [Iv]]] = [:]
        for b in inp.prefer {
            if let o = mods.first(where: { $0.id == b.module })?.order { prefer[b.date, default: [:]][o, default: []].append((b.start, b.end)) }
        }
        var rem = Dictionary(uniqueKeysWithValues: mods.map { ($0.order, $0.rem) })
        var planned: [Int: Int] = [:]
        var blocks: [(module: Int, day: Int, a: Int, b: Int)] = []
        for d in inp.days.indices {
            if d > 0 { for m in mods { later[m.order]! -= mfix[m.order]![d - 1] ?? 0 } }
            let act = mods.filter { rem[$0.order]! > 0 && $0.E > d }.sorted { $0.E != $1.E ? $0.E < $1.E : $0.order < $1.order }
            let c = cap[d]
            if act.isEmpty || c == 0 { continue }
            var x: [Int: Int] = [:]
            for m in act {
                let o = m.order
                let cf = gp[m.E] - gp[d], r = rem[o]! + later[o]!
                x[o] = cf > 0 ? min(rem[o]!, max(0, ceilDiv(r * gcap[d], cf) - (mfix[o]![d] ?? 0))) : 0
            }
            for m in act {
                let o = m.order
                if x[o]! > 0 && x[o]! < minU && rem[o]! > x[o]! { x[o] = min(minU, rem[o]!) }
            }
            var left = c
            for m in act {
                x[m.order] = min(x[m.order]!, left)
                left -= x[m.order]!
            }
            for e in Set(act.map(\.E)).sorted() {
                let group = act.filter { $0.E <= e }
                let need = group.reduce(0) { $0 + rem[$1.order]! } - (p[e] - p[d + 1])
                let delta = need - group.reduce(0) { $0 + x[$1.order]! }
                if delta <= 0 { continue }
                var take = min(delta, c - x.values.reduce(0, +))
                for m in act.reversed() {
                    if take >= delta { break }
                    if m.E > e {
                        let t = min(x[m.order]!, delta - take)
                        x[m.order]! -= t
                        take += t
                    }
                }
                for m in group {
                    if take == 0 { break }
                    let a = min(take, rem[m.order]! - x[m.order]!)
                    x[m.order]! += a
                    take -= a
                }
            }
            let wants = act.filter { x[$0.order]! > 0 }.map { (key: $0.order, units: x[$0.order]!) }
            for pc in place(wins[d], wants: wants, minU: minU, maxU: maxU, brk: inp.settings.brk, prefer: prefer[inp.days[d].date]) {
                rem[pc.key]! -= (pc.b - pc.a) / unit
                planned[pc.key, default: 0] += pc.b - pc.a
                blocks.append((pc.key, d, pc.a, pc.b))
            }
        }
        blocks.sort { $0.day != $1.day ? $0.day < $1.day : $0.a < $1.a }
        return (blocks, rem, planned)
    }

    // MARK: Optionen

    static func reduceGoals(_ mods: [Mod], _ p: [Int]) -> [Int: Int] {
        var rem = Dictionary(uniqueKeysWithValues: mods.map { ($0.order, $0.rem) })
        var cut = Dictionary(uniqueKeysWithValues: mods.map { ($0.order, 0) })
        for e in Set(mods.filter { $0.E > 0 }.map(\.E)).sorted() {
            let group = mods.filter { $0.E > 0 && $0.E <= e }.sorted { $0.E != $1.E ? $0.E < $1.E : $0.order < $1.order }
            let miss = group.reduce(0) { $0 + rem[$1.order]! } - p[e]
            if miss <= 0 { continue }
            let total = group.reduce(0) { $0 + rem[$1.order]! }
            var parts = Dictionary(uniqueKeysWithValues: group.map { ($0.order, miss * rem[$0.order]! / total) })
            var left = miss - parts.values.reduce(0, +)
            for m in group {
                if left == 0 { break }
                if rem[m.order]! - parts[m.order]! > 0 {
                    parts[m.order]! += 1
                    left -= 1
                }
            }
            for (o, v) in parts {
                rem[o]! -= v
                cut[o]! += v
            }
        }
        return cut
    }

    static func options(_ inp: Input, _ mods: [Mod], _ p: [Int]) -> [JSONValue] {
        var out: [JSONValue] = []
        let quota = inp.settings.utilization
        var qs = Array(stride(from: quota + 5, to: 100, by: 5)) + [100]
        qs = qs.filter { $0 > quota }
        if let q = qs.first(where: { feasible(mods, prefix(net(inp, quota: $0).cap)) }) {
            out.append(["kind": "nutzungsquote", "value": n(q), "text": .string("Nutzungsquote der freien Zeit von \(quota) % auf \(q) % erhöhen")])
        } else if quota < 100 {
            out.append(["kind": "nutzungsquote", "value": .null, "text": "Auch 100 % der freien Zeit reichen allein nicht."])
        }
        let most = inp.days.map { merge($0.reserve).reduce(0) { $0 + $1.b - $1.a } }.max() ?? 0
        var found: Int?
        if most >= unit {
            for extra in stride(from: unit, through: most, by: unit)
                where feasible(mods, prefix(net(inp, quota: quota, extra: extra).cap)) {
                found = extra
                break
            }
        }
        if let found {
            out.append(["kind": "freizeit", "minutes_per_day": n(found), "text": .string("Freizeit an Lerntagen um \(hoursText(found)) pro Tag senken")])
        } else if most > 0 {
            out.append(["kind": "freizeit", "minutes_per_day": .null, "text": "Auch ohne Freizeit reicht die Zeit allein nicht."])
        }
        let cut = reduceGoals(mods, p)
        let cuts: [JSONValue] = mods.filter { cut[$0.order]! > 0 }.map { ["module_id": $0.id, "minutes": n(cut[$0.order]! * unit)] }
        if !cuts.isEmpty {
            out.append(["kind": "ziele", "cuts": .array(cuts),
                        "text": .string("Ziele senken: " + cuts.map { hoursText(num($0["minutes"])) }.joined(separator: ", ") + " weniger")])
        }
        let blocked = Set(deadlines(mods, p).filter { $0.missing > 0 }.flatMap { $0.modules.map { pyStr($0) } })
        var index: [String: Int] = [:]
        for (i, d) in inp.days.enumerated() where index[d.date] == nil { index[d.date] = i }
        for m in mods {
            guard blocked.contains(pyStr(m.id)), m.exam != nil else { continue }
            func ok(_ e2: Int) -> Bool {
                feasible(mods.map { x in
                    var y = x
                    if x.order == m.order { y.E = e2 }
                    return y
                }, p)
            }
            if let second = m.exam2, let i2 = index[second], i2 > m.E, ok(i2) {
                out.append(["kind": "zweittermin", "module_id": m.id, "date": .string(second), "text": .string("Zweittermin am \(second) schreiben")])
                continue
            }
            if m.E + 1 < inp.days.count, let e2 = (m.E + 1..<inp.days.count).first(where: ok) {
                let d2 = inp.days[e2].date
                out.append(["kind": "spaeterer_termin", "module_id": m.id, "date": .string(d2), "text": .string("Klausur frühestens am \(d2) schreiben")])
            }
        }
        let order = mods.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.E != b.E ? a.E < b.E : a.order < b.order
        }
        var rem = Dictionary(uniqueKeysWithValues: mods.map { ($0.order, 0) })
        var covered: [JSONValue] = [], dropped: [JSONValue] = []
        for m in order where m.rem != 0 {
            rem[m.order] = m.rem
            if feasible(mods, p, rem: rem) {
                covered.append(m.id)
            } else {
                rem[m.order] = 0
                dropped.append(m.id)
            }
        }
        if !covered.isEmpty && !dropped.isEmpty {
            out.append(["kind": "prioritaeten", "covered": .array(covered), "dropped": .array(dropped),
                        "text": "Nach Priorität planen: wichtigste Module voll, die übrigen nur mit Restzeit"])
        }
        out.append(["kind": "teilplan", "text": "Trotzdem planen: Teilplan mit der vorhandenen Zeit (fehlende Stunden bleiben offen)"])
        return out
    }

    // MARK: Planen

    /// `plan(inp)`
    static func plan(_ json: JSONValue) throws -> JSONValue {
        let inp = try Input(json)
        let mods = inp.modules
        let nt = net(inp, quota: inp.settings.utilization)
        let wins = nt.wins, cap = nt.cap
        let p = prefix(cap)
        let dl = deadlines(mods, p)
        let ok = dl.allSatisfy { $0.missing == 0 }
        var out: [String: JSONValue] = [
            "status": "ok", "feasible": .bool(ok), "blocks": [], "options": [], "message": .null,
            "capacity_minutes": .array(cap.map { n($0 * unit) }),
            "deadlines": .array(dl.map { x in
                ["date": x.E < inp.days.count ? .string(inp.days[x.E].date) : .null, "need_minutes": n(x.need * unit),
                 "available_minutes": n(x.available * unit), "missing_minutes": n(x.missing * unit), "modules": .array(x.modules)]
            }),
        ]
        func modOut(_ m: Mod, planned: Int, remUnits: Int) -> JSONValue {
            ["id": m.id, "need_minutes": n(m.need), "fixed_minutes": n(m.fixed), "planned_minutes": n(planned),
             "unplanned_minutes": n(m.E > 0 ? remUnits * unit : 0), "exam_passed": .bool(m.passed)]
        }
        if !ok {
            var worst = dl[0]
            for x in dl.dropFirst() where (x.missing, x.E) > (worst.missing, worst.E) { worst = x }
            out["status"] = "unterdeckt"
            out["missing_minutes"] = n(worst.missing * unit)
            out["message"] = .string("\(hoursText(worst.need * unit)) nötig, \(hoursText(worst.available * unit)) verfügbar, fehlen \(hoursText(worst.missing * unit))")
            out["options"] = .array(options(inp, mods, p))
            if !inp.partial {
                out["modules"] = .array(mods.map { modOut($0, planned: 0, remUnits: $0.rem) })
                return .object(out)
            }
            out["status"] = "teilplan"
        }
        let (blocks, rem, planned) = allocate(inp, mods, wins, cap, p, gcap: nt.gcap, mfix: moduleFixed(inp, mods))
        out["blocks"] = .array(blocks.map { b in
            ["module_id": mods[b.module].id, "date": .string(inp.days[b.day].date), "start": n(b.a), "end": n(b.b), "minutes": n(b.b - b.a)]
        })
        out["modules"] = .array(mods.map { modOut($0, planned: planned[$0.order] ?? 0, remUnits: rem[$0.order]!) })
        if ok && mods.contains(where: { rem[$0.order]! > 0 }) {
            out["status"] = "teilweise"
            let miss = mods.reduce(0) { $0 + rem[$1.order]! } * unit
            out["message"] = .string("\(hoursText(miss)) passen nicht in die freien Fenster (zu kleine Lücken).")
        }
        return .object(out)
    }

    // MARK: Lernzeit

    /// `credit(sessions, now_ts)`: anerkannte Lernzeit je Modul und je Block (siehe Python)
    static func credit(_ sessions: [JSONValue], nowTs: Int) -> JSONValue {
        var latest: [String: JSONValue] = [:]
        var order: [String] = []
        for x in sessions {
            let u = x["uuid"]?.string ?? ""
            if let old = latest[u] {
                if less(old["updated_at"]?.string ?? "", x["updated_at"]?.string ?? "") { latest[u] = x }
            } else {
                latest[u] = x
                order.append(u)
            }
        }
        let live = order.compactMap { latest[$0] }.filter { !truthy($0["deleted"], default: false) }
        func pk(_ x: JSONValue) -> String? {
            guard let v = x["package_id"], !v.isNull else { return nil }
            return pyStr(v)
        }
        var blockLast: [String: JSONValue] = [:]
        for x in live where x["kind"]?.string == "block" {
            guard let k = pk(x) else { continue }
            if let b = blockLast[k] {
                let bu = b["updated_at"]?.string ?? "", xu = x["updated_at"]?.string ?? ""
                if less(bu, xu) || (bu == xu && less(b["uuid"]?.string ?? "", x["uuid"]?.string ?? "")) { blockLast[k] = x }
            } else {
                blockLast[k] = x
            }
        }
        var byModule: [String: Int] = [:], byBlock: [String: Int] = [:]
        var segs: [(a: Int, b: Int, uuid: String, mid: String, pk: String?)] = []
        for x in live {
            let p = pk(x), mid = pyStr(x["module_id"])
            if x["kind"]?.string == "block" {
                guard let p, blockLast[p]?["uuid"] == x["uuid"] else { continue }
                let m = max(0, num(x["minutes"])) * 60
                byModule[mid, default: 0] += m
                byBlock[p, default: 0] += m
                continue
            }
            if let p, blockLast[p] != nil { continue }
            if let sg = x["segments"]?.array, !sg.isEmpty {
                for s in sg {
                    guard let pair = s.array, pair.count >= 2 else { continue }
                    let a = num(pair[0])
                    let b = min(pair[1].isNull ? nowTs : num(pair[1]), nowTs)
                    if b > a { segs.append((a, b, x["uuid"]?.string ?? "", mid, p)) }
                }
            } else {
                let m = max(0, num(x["minutes"])) * 60
                byModule[mid, default: 0] += m
                if let p { byBlock[p, default: 0] += m }
            }
        }
        segs.sort { x, y in
            if x.a != y.a { return x.a < y.a }
            if x.b != y.b { return x.b < y.b }
            if x.uuid != y.uuid { return less(x.uuid, y.uuid) }
            if x.mid != y.mid { return less(x.mid, y.mid) }
            return less(x.pk ?? "", y.pk ?? "")
        }
        var covered: Int?
        for s in segs {
            let start = covered.map { max(s.a, $0) } ?? s.a
            if s.b > start {
                byModule[s.mid, default: 0] += s.b - start
                if let p = s.pk { byBlock[p, default: 0] += s.b - start }
            }
            covered = covered.map { max($0, s.b) } ?? s.b
        }
        return ["modules": .object(byModule.mapValues { n($0 / 60) }), "blocks": .object(byBlock.mapValues { n($0 / 60) })]
    }

    // MARK: Abgleich mit dem bestehenden Plan

    /// `diff(existing, new)`: gleiche Bloecke behalten ihre ID
    static func diff(_ existing: [JSONValue], _ new: [JSONValue]) -> JSONValue {
        func key(_ b: JSONValue) -> String {
            "\(pyStr(b["module_id"]))\u{1}\(b["date"]?.string ?? "")\u{1}\(num(b["start"]))\u{1}\(num(b["end"]))"
        }
        let sorted = existing.sorted { x, y in
            let dx = x["date"]?.string ?? "", dy = y["date"]?.string ?? ""
            if dx != dy { return less(dx, dy) }
            if num(x["start"]) != num(y["start"]) { return num(x["start"]) < num(y["start"]) }
            return num(x["id"]) < num(y["id"])
        }
        var pool: [String: [JSONValue]] = [:]
        for b in sorted { pool[key(b), default: []].append(b["id"] ?? .null) }
        var keep: [JSONValue] = [], add: [JSONValue] = []
        for b in new {
            let k = key(b)
            if var ids = pool[k], !ids.isEmpty {
                keep.append(ids.removeFirst())
                pool[k] = ids
            } else {
                add.append(b)
            }
        }
        let remove = pool.values.flatMap { $0 }.sorted { num($0) < num($1) }
        return ["keep": .array(keep.sorted { num($0) < num($1) }), "remove": .array(remove), "add": .array(add)]
    }

    // MARK: Material

    /// `assign_materials(blocks, materials, max_block)`
    static func assignMaterials(_ blocks: [JSONValue], _ materials: [JSONValue], maxBlock: Int = 120) -> JSONValue {
        struct B {
            let id: JSONValue
            let module: String
            let date: String
            let start: Int
            let minutes: Int
            var used: Int
        }
        var bl = blocks.map {
            B(id: $0["id"] ?? .null, module: pyStr($0["module_id"]), date: $0["date"]?.string ?? "", start: num($0["start"]),
              minutes: num($0["minutes"]), used: num($0["used"]))
        }.sorted { x, y in
            if x.date != y.date { return less(x.date, y.date) }
            if x.start != y.start { return x.start < y.start }
            return num(x.id) < num(y.id)
        }
        func rank(_ f: JSONValue) -> Int { kindRank[f["kind"]?.string ?? ""] ?? 5 }
        let mats = materials.sorted { x, y in
            let fx = x["from_date"]?.string ?? "", fy = y["from_date"]?.string ?? ""
            if fx != fy { return less(fx, fy) }
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            return less(x["file_id"]?.string ?? "", y["file_id"]?.string ?? "")
        }
        var assign: [JSONValue] = [], overflow: [JSONValue] = []
        for f in mats {
            let e = num(f["est"])
            let est = max(unit, e == 0 ? 45 : e)
            let from = f["from_date"]?.string ?? "", module = pyStr(f["module_id"])
            var need = est
            var got: [(index: Int, take: Int)] = []
            for i in bl.indices {
                if need == 0 || got.count == 4 { break }
                if bl[i].module != module || less(bl[i].date, from) { continue }
                let take = min(need, bl[i].minutes - bl[i].used)
                if take <= 0 || (take < need && take < unit) { continue }
                bl[i].used += take
                need -= take
                got.append((i, take))
            }
            if need == 0 {
                for (k, g) in got.enumerated() {
                    assign.append(["file_id": f["file_id"] ?? .null, "block_id": bl[g.index].id, "part": n(k + 1), "parts": n(got.count), "minutes": n(g.take)])
                }
            } else {
                for g in got { bl[g.index].used -= g.take }
                overflow.append(["file_id": f["file_id"] ?? .null, "module_id": f["module_id"] ?? .null, "kind": f["kind"] ?? .null, "est": n(est)])
            }
        }
        overflow.sort { x, y in
            rank(x) != rank(y) ? rank(x) < rank(y) : less(x["file_id"]?.string ?? "", y["file_id"]?.string ?? "")
        }
        return ["assign": .array(assign), "overflow": .array(overflow)]
    }

    // MARK: Prognose

    /// `module_stats(m)`
    static func moduleStats(_ m: JSONValue) -> JSONValue {
        let target = max(0, num(m["target_minutes"])), learned = max(0, num(m["learned_minutes"]))
        let lecture = max(0, num(m["lecture_minutes"]))
        let remaining = max(0, target - learned - lecture)
        let days: Int? = m["days_left"].flatMap { $0.isNull ? nil : num($0) }
        var perWeek: JSONValue = .null
        if let days, days > 0 { perWeek = n(ceilDiv(remaining * 7, days)) }
        let adh: Int = m["adherence"].flatMap { $0.isNull ? nil : max(0, min(100, num($0))) } ?? 100
        let planned = max(0, num(m["planned_minutes"]))
        let forecast = learned + lecture + planned * adh / 100
        let pct = target != 0 ? forecast * 100 / target : 100
        let status: String
        if remaining == 0 {
            status = "erreicht"
        } else if let days, days <= 0 {
            status = "vorbei"
        } else if pct >= 100 {
            status = "auf_kurs"
        } else if pct >= 90 {
            status = "knapp"
        } else {
            status = "gefaehrdet"
        }
        return ["target_minutes": n(target), "learned_minutes": n(learned), "lecture_minutes": n(lecture),
                "remaining_minutes": n(remaining), "days_left": days.map(n) ?? .null, "per_week_minutes": perWeek,
                "planned_minutes": n(planned), "forecast_minutes": n(forecast), "forecast_percent": n(pct), "status": .string(status)]
    }
}
