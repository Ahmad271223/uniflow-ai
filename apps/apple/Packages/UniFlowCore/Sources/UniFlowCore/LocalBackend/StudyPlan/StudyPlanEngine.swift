import Foundation

/// Persoenlicher Studienverlauf wie app/study_plan.py (Auftrag des Inhabers 04.11.2026,
/// docs/STUDIENVERLAUF-2026-11-04.md): Katalog + QIS-Zeilen + Einstellungen + Tag -> Semesterliste mit Modulen,
/// Status, Verschiebungen und Hinweisen. Dieselben Regeln und Reihenfolgen wie dort (Kopf von app/study_plan.py);
/// gegen Python geprueft mit fixtures/study-plan-engine/engine.json (tools/gen-study-plan-fixture.py).
///
/// Semester als Zahl: Jahr * 2 + (1 fuer WS, 0 fuer SS). Texte werden wie in Python nach Codepunkten verglichen
/// (`PyText`, `PyRegex`), Zahlen aus dem Katalog als Double (der Wert ist derselbe wie Pythons int/float).
public enum StudyPlanEngine {
    public static let disclaimer = "Verbindlich ist die Prüfungsordnung deiner Hochschule."
    static let noCatalog = "Für deinen Studiengang gibt es noch keinen Katalog."
    static let settingsKey = "study_plan"
    static let targetLP = 30.0
    static let capLP = 36.0
    static let behindLP = 10.0
    static let electiveKinds: Set<String> = ["wahlpflicht", "wahl"]
    static let noteRank: [String: Int] = ["endgueltig": 0, "letzter_versuch": 1, "voraussetzung": 2, "ueberlast": 3, "rueckstand": 4]

    private static let termRE = PyRegex(#"^\s*(WiSe|SoSe|Wintersemester|Sommersemester|WS|SS)\s*(\d{2,4})(?:\s*/\s*(\d{2,4}))?\s*$"#, ignoreCase: true)
    private static let roman: [String: String] = ["i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7",
                                                  "viii": "8", "ix": "9", "x": "10"]
    private static let filler: Set<String> = ["modul", "pl", "sl", "pruefungsleistung", "studienleistung", "modulpruefung",
                                              "pruefung", "klausur", "und", "u"]
    private static let nonAlnum = PyRegex("[^a-z0-9]+")
    private static let registeredRE = PyRegex("^an$|angemeldet")
    private static let programRE = PyRegex(#"\s*\(.*$"#)
    private static let digitsRE = PyRegex(#"[0-9]{1,3}\z"#)

    // MARK: Semester

    /// "WiSe 25/26", "WS 2025/26", "Wintersemester 2025/2026", "SoSe 26", "SS 2026" -> Zahl, sonst nil
    public static func parseTerm(_ s: String?) -> Int? {
        guard let s, let m = termRE.match(s), let ys = m.group(2), var year = PyText.int(digits: ys), let kind = m.group(1) else { return nil }
        if year < 100 { year += 2000 }
        let k = PyText.lower(kind)
        let winter = k.hasPrefix("wi") || k.hasPrefix("ws")
        return year * 2 + (winter ? 1 : 0)
    }

    static func parseTerm(_ v: JSONValue?) -> Int? { parseTerm(v?.string) }

    /// "WiSe 26/27", "SoSe 27"
    public static func termName(_ t: Int) -> String {
        let year = t / 2
        func two(_ n: Int) -> String { String(format: "%02d", n % 100) }
        return t % 2 == 1 ? "WiSe \(two(year))/\(two(year + 1))" : "SoSe \(two(year))"
    }

    /// Oktober bis Maerz: WS (Jahr des Oktobers), April bis September: SS; `today` als "YYYY-MM-DD"
    public static func currentTerm(_ today: String) -> Int {
        let u = Array(today.utf8)
        func num(_ r: Range<Int>) -> Int { r.reduce(0) { $0 * 10 + Int(u.count > $1 ? u[$1] : 48) - 48 } }
        let year = num(0..<4), month = num(5..<7)
        if month >= 10 { return year * 2 + 1 }
        if month <= 3 { return (year - 1) * 2 + 1 }
        return year * 2
    }

    /// WS | SS | beide
    static func turnusOf(_ v: JSONValue?) -> String {
        let s = PyText.lower(v?.string ?? "")
        let ws = PyText.contains(s, "ws") || PyText.contains(s, "winter")
        let ss = PyText.contains(s, "ss") || PyText.contains(s, "sommer")
        if ws && !ss { return "WS" }
        if ss && !ws { return "SS" }
        return "beide"
    }

    static func fits(_ t: Int, _ turnus: String) -> Bool { turnus == "beide" || (turnus == "WS") == (t % 2 == 1) }

    static func nextFit(_ t: Int, _ turnus: String) -> Int {
        var t = t
        while !fits(t, turnus) { t += 1 }
        return t
    }

    // MARK: Namen und Zahlen

    /// Namensschluessel fuer die Zuordnung QIS-Zeile/Kurs/App-Modul -> Katalogmodul (`name_key`)
    public static func nameKey(_ text: String) -> String {
        let s = PyText.lower(UniRules.classify(text).subject)
        var folded = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0xE4: folded.append(contentsOf: "ae".unicodeScalars)
            case 0xF6: folded.append(contentsOf: "oe".unicodeScalars)
            case 0xFC: folded.append(contentsOf: "ue".unicodeScalars)
            case 0xDF: folded.append(contentsOf: "ss".unicodeScalars)
            default: folded.append(u)
            }
        }
        let toks = PyText.split(nonAlnum.sub(String(folded), " "), " ").filter { !$0.isEmpty }
        let mapped = toks.map { toks.count > 1 ? (roman[$0] ?? $0) : $0 }
        let kept = mapped.filter { !filler.contains($0) }
        return (kept.isEmpty ? mapped : kept).joined(separator: " ")
    }

    static func nameKey(_ v: JSONValue?) -> String { nameKey(v?.string ?? "") }

    /// Zahl aus dem Katalog (kein Wahrheitswert) oder nil
    static func num(_ v: JSONValue?) -> Double? { v?.double }

    static func lpOf(_ m: [String: JSONValue]) -> Double {
        let v = num(m["lp"]) ?? 0
        return v == 0 ? 0 : v
    }

    static func numJSON(_ v: JSONValue?) -> JSONValue { num(v).map(JSONValue.number) ?? .null }

    /// LP fuer Texte: 12 -> "12", 7.5 -> "7,5"
    static func fmtLP(_ x: Double) -> String {
        if x == x.rounded() { return String(Int(x)) }
        return String(format: "%.1f", x).replacingOccurrences(of: ".", with: ",")
    }

    /// `str(v).strip()` als Zahl, wenn es 1-3 Ziffern sind
    static func intOrNil(_ v: JSONValue?) -> Int? {
        let s: String
        switch v {
        case .string(let t)?: s = PyText.strip(t)
        case .number(let d)?: s = d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : ""
        default: s = ""
        }
        guard digitsRE.match(s) != nil else { return nil }
        return Int(s)
    }

    static func textOf(_ v: JSONValue?) -> String { v?.string ?? "" }

    static func opt(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
    static func opt(_ i: Int?) -> JSONValue { i.map { .number(Double($0)) } ?? .null }

    /// `str(v or "")` (PO als Text oder Zahl)
    static func pyStr(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s)?: return s
        case .number(let d)?:
            if d == 0 { return "" }
            return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : PyJSON.repr(d)
        case .bool(true)?: return "True"
        default: return ""
        }
    }

    private static func starts(_ s: String, _ prefix: String) -> Bool { s.unicodeScalars.starts(with: prefix.unicodeScalars) }

    /// passed | final | failed | registered | nil (abgemeldet, krank ...)
    static func rowResult(_ r: [String: JSONValue]) -> String? {
        let s = PyText.lower(PyText.strip(textOf(r["status"])))
        if ["bestanden", "anerkannt", "be"].contains(s) { return "passed" }
        if starts(s, "endgültig") || starts(s, "endgueltig") || s == "en" { return "final" }
        if starts(s, "nicht bestanden") || s == "nb" { return "failed" }
        if registeredRE.found(in: s) { return "registered" }
        if s.isEmpty && PyText.strip(textOf(r["note"])) == "5,0" { return "failed" }
        return nil
    }

    static func isBereich(_ r: [String: JSONValue]) -> Bool {
        r["level"]?.string == "bereich" || GradesModel.bereichRE.match(textOf(r["text"])) != nil
    }

    /// Voraussetzungen als Modul-ids (nur Texte aus einer Liste)
    static func prereqs(_ m: [String: JSONValue]) -> [String] { m["prerequisites"]?.array?.compactMap(\.string) ?? [] }

    // MARK: Katalog waehlen

    /// Bibliotheksschluessel sha256("luh|TIBSc22|WS 2025/26")
    public static func catalogKey(_ c: JSONValue) -> String {
        let raw = "\(textOf(c["university"]))|\(textOf(c["code"]))|\(textOf(c["catalog_term"]))"
        return SolutionSHA256.hex(Data(raw.utf8))
    }

    static func validCatalog(_ c: JSONValue) -> Bool { c["modules"]?.array != nil }

    /// Haeufigster Wert (bei Gleichstand der zuerst gesehene), wie `Counter` + `next(...)`
    private static func mostCommon(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        var counts: [[UInt32]: Int] = [:]
        for n in names { counts[n.unicodeScalars.map(\.value), default: 0] += 1 }
        let best = counts.values.max() ?? 0
        return names.first { counts[$0.unicodeScalars.map(\.value)] == best }
    }

    /// Studiengang aus QIS `abschluss` ohne Klammerzusatz
    static func programOf(_ grades: [[String: JSONValue]]) -> String? {
        mostCommon(grades.map { PyText.strip(programRE.sub(textOf($0["abschluss"]))) }.filter { !$0.isEmpty })
    }

    static func abschlussOf(_ grades: [[String: JSONValue]]) -> String? {
        mostCommon(grades.map { PyText.strip(textOf($0["abschluss"])) }.filter { !$0.isEmpty })
    }

    private static func rankGreater(_ a: JSONValue, _ b: JSONValue) -> Bool {
        let pa = pyStr(a["po"]), pb = pyStr(b["po"])
        if pa != pb || !pa.unicodeScalars.elementsEqual(pb.unicodeScalars) { return PyText.less(pb, pa) }
        let ta = parseTerm(a["catalog_term"]) ?? -1, tb = parseTerm(b["catalog_term"]) ?? -1
        if ta != tb { return ta > tb }
        return PyText.less(textOf(b["code"]), textOf(a["code"]))
    }

    /// (Katalog, nil) oder (nil, Grund-Code no_catalog | no_catalog_po), wie `pick_catalog`
    public static func pickCatalog(_ catalogs: [JSONValue], settings: [String: JSONValue],
                                   grades: [[String: JSONValue]]) -> (catalog: JSONValue?, reason: String?) {
        var cands = catalogs.filter(validCatalog)
        if cands.isEmpty { return (nil, "no_catalog") }
        let po = PyText.strip(textOf(settings["po"]))
        if !po.isEmpty {
            cands = cands.filter { pyStr($0["po"]) == po || textOf($0["code"]) == po }
            if cands.isEmpty { return (nil, "no_catalog_po") }
        }
        if let program = programOf(grades) {
            let key = nameKey(program)
            let same = cands.filter { nameKey($0["program"]) == key }
            if !same.isEmpty { cands = same }
        }
        var best = cands[0]
        for c in cands.dropFirst() where rankGreater(c, best) { best = c }
        return (best, nil)
    }

    // MARK: Plan

    struct ModuleState {
        var status: String
        var term: Int?
        var attempt: Int?
        var grade: String?
        var movedFrom: String?
        var reason: String?
        var failed: Int
        var final: Bool

        /// Naechster bzw. angemeldeter Versuch ist der dritte, oder endgueltig nicht bestanden
        var lastAttempt: Bool {
            if status == "bestanden" { return false }
            return final || (status == "nicht_bestanden" && attempt == 2) || (status == "angemeldet" && attempt == 3)
        }
    }

    struct Result {
        var plan: [String: JSONValue]
        var state: [String: ModuleState]
        var hist: [String: [[String: JSONValue]]]
        var modules: [[String: JSONValue]]
        var byID: [String: [String: JSONValue]]
    }

    /// {Modul-id: [Zeilen]} und die nicht zugeordneten Texte (sortiert, ohne Doppelte)
    static func match(_ mods: [[String: JSONValue]], _ grades: [[String: JSONValue]]) -> ([String: [[String: JSONValue]]], [String]) {
        var byCode: [String: String] = [:], byKey: [String: String] = [:]
        for m in mods {
            let id = m["id"]?.string ?? ""
            let code = PyText.strip(textOf(m["code"]))
            if !code.isEmpty, byCode[code] == nil { byCode[code] = id }
            let k = nameKey(m["title"])
            if !k.isEmpty, byKey[k] == nil { byKey[k] = id }
        }
        var hist: [String: [[String: JSONValue]]] = [:]
        var unmatched: [String] = []
        for r in grades where !isBereich(r) {
            let nr = PyText.strip(textOf(r["pruefungsnr"]))
            var mid = nr.isEmpty ? nil : byCode[nr]
            if mid == nil { mid = byKey[nameKey(r["text"])] }
            guard let id = mid else {
                let t = PyText.strip(textOf(r["text"]))
                if !t.isEmpty, !unmatched.contains(where: { $0.unicodeScalars.elementsEqual(t.unicodeScalars) }) { unmatched.append(t) }
                continue
            }
            hist[id, default: []].append(r)
        }
        return (hist, unmatched.sorted(by: PyText.less))
    }

    /// (Fehlversuche, Semester des letzten Fehlversuchs, endgueltig)
    static func attempts(_ rows: [[String: JSONValue]]) -> (Int, Int?, Bool) {
        let failed = rows.filter { ["failed", "final"].contains(rowResult($0) ?? "") }
        if failed.isEmpty { return (0, nil, false) }
        let versuche = failed.map { intOrNil($0["versuch"]) ?? 0 }
        var terms: [Int?] = []
        for r in failed {
            let t = parseTerm(r["semester"])
            if !terms.contains(where: { $0 == t }) { terms.append(t) }
        }
        let n = max(versuche.max() ?? 0, terms.count)
        let known = terms.compactMap { $0 }
        let final = failed.contains { rowResult($0) == "final" } || n >= 3
        return (n, known.max(), final)
    }

    /// Der volle Stand (fuer Plan und Moduldetail), wie `compute`
    static func compute(catalog: JSONValue, grades: [[String: JSONValue]], settings: [String: JSONValue], today: String) -> Result {
        var mods: [[String: JSONValue]] = []
        var seen: Set<String> = []
        for v in catalog["modules"]?.array ?? [] {
            guard let m = v.object, let id = m["id"]?.string, !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            mods.append(m)
        }
        var order: [String: Int] = [:], byID: [String: [String: JSONValue]] = [:]
        for (i, m) in mods.enumerated() {
            let id = m["id"]!.string!
            order[id] = i
            byID[id] = m
        }
        func idOf(_ m: [String: JSONValue]) -> String { m["id"]?.string ?? "" }
        let current = currentTerm(today)
        let (hist, unmatched) = match(mods, grades)

        var start: Int
        if let s = parseTerm(settings["start_term"]) {
            start = s
        } else {
            let known = grades.filter { !isBereich($0) }.compactMap { parseTerm($0["semester"]) }
            start = known.min() ?? current
        }
        var regular = 6
        if let r = num(catalog["regular_semesters"]), r > 0 { regular = Int(r) }
        let lastRegular = start + regular - 1
        let lower = max(current, start)

        let chosen = settings["electives"]?.array?.compactMap(\.string) ?? []
        let included = mods.map(idOf).filter { id in
            !electiveKinds.contains(textOf(byID[id]?["kind"])) || chosen.contains(id) || hist[id] != nil
        }

        func semOf(_ m: [String: JSONValue]) -> Int? {
            guard let s = num(m["semester"]), s >= 1 else { return nil }
            return Int(s)
        }

        // Plaetze fuer Wahlmodule laut Studienverlaufsplan (`plan_slots`), wie in app/study_plan.py: gewaehlte
        // Wahl(pflicht)module ohne Fachsemester belegen der Reihe nach den ersten freien Platz ihres Bereichs (leere
        // Bereichsliste = jeder); Module mit QIS-Zeilen zuerst
        let slots = (catalog["plan_slots"]?.array ?? []).compactMap { v -> (Int, [JSONValue])? in
            guard let o = v.object, let d = num(o["semester"]), d >= 1, d == d.rounded() else { return nil }
            return (Int(d), o["areas"]?.array ?? [])
        }
        var slotSem: [String: Int] = [:]
        var taken = Set<Int>()
        let elect = included.filter { electiveKinds.contains(textOf(byID[$0]?["kind"])) && semOf(byID[$0]!) == nil }
        for mid in elect.filter({ hist[$0] != nil }) + elect.filter({ hist[$0] == nil }) {
            let area = byID[mid]?["area"] ?? .null
            for (k, s) in slots.enumerated() where !taken.contains(k) && (s.1.isEmpty || s.1.contains(area)) {
                taken.insert(k)
                slotSem[mid] = s.0
                break
            }
        }

        var state: [String: ModuleState] = [:]
        for mid in included {
            let m = byID[mid]!, rows = hist[mid] ?? []
            let turnus = turnusOf(m["turnus"])
            let (failedN, lastFail, final) = attempts(rows)
            let passed = rows.filter { rowResult($0) == "passed" }
            let registered = rows.filter { rowResult($0) == "registered" }
            var st = ModuleState(status: "", term: nil, attempt: nil, grade: nil, movedFrom: nil, reason: nil, failed: failedN, final: final)
            let rec = (semOf(m) ?? slotSem[mid]).map { start + $0 - 1 }
            if !passed.isEmpty {
                var best = passed[0]
                for r in passed.dropFirst() where (parseTerm(r["semester"]) ?? -1) >= (parseTerm(best["semester"]) ?? -1) { best = r }
                var t = parseTerm(best["semester"]) ?? (rec.map { min($0, current) } ?? current)
                t = max(t, start)
                let g = PyText.strip(textOf(best["note"]))
                st.status = "bestanden"; st.term = t; st.attempt = failedN + 1; st.grade = g.isEmpty ? nil : g
            } else if !registered.isEmpty {
                let vs = registered.compactMap { intOrNil($0["versuch"]) }.filter { $0 != 0 }
                st.status = "angemeldet"; st.term = current; st.attempt = vs.max() ?? failedN + 1
            } else if failedN > 0 {
                let begin = max(lastFail.map { $0 + 1 } ?? current, lower)
                st.status = "nicht_bestanden"; st.term = nextFit(begin, turnus); st.attempt = failedN
                st.movedFrom = lastFail.map(termName); st.reason = "Nicht bestanden – nächster Versuch"
            } else if let rec {
                let t = nextFit(max(rec, start), turnus)
                st.status = "plan"; st.term = t
                if t != rec {
                    st.movedFrom = termName(rec)
                    st.reason = "Wird nur im \(turnus == "WS" ? "Wintersemester" : "Sommersemester") angeboten"
                }
                if t < lower {
                    st.term = nextFit(lower, turnus); st.movedFrom = termName(rec); st.reason = "Noch nicht abgelegt – nachholen"
                }
            } else {
                st.status = "plan"                                          // ohne Fachsemester: unten auffuellen
            }
            state[mid] = st
        }

        func load(_ t: Int) -> Double {
            included.reduce(0) { $0 + (state[$1]!.term == t ? lpOf(byID[$1]!) : 0) }
        }

        for mid in included where state[mid]!.term == nil {
            let m = byID[mid]!
            let turnus = turnusOf(m["turnus"])
            var t = nextFit(lower, turnus)
            while t <= lastRegular && load(t) + lpOf(m) > targetLP { t = nextFit(t + 1, turnus) }
            if t > lastRegular { t = nextFit(max(lower, lastRegular), turnus) }
            state[mid]!.term = t
        }

        func move(_ mid: String, _ t: Int, _ reason: String) {
            if state[mid]!.movedFrom == nil { state[mid]!.movedFrom = termName(state[mid]!.term!) }
            state[mid]!.term = t
            state[mid]!.reason = reason
        }

        func fixPrerequisites() {
            for _ in 0...included.count {
                var changed = false
                for mid in included {
                    let st = state[mid]!
                    guard st.status == "plan" || st.status == "nicht_bestanden" else { continue }
                    var need: Int?, needID: String?
                    for p in prereqs(byID[mid]!) {
                        guard let ps = state[p], ps.status != "bestanden" else { continue }
                        if need == nil || ps.term! > need! { need = ps.term; needID = p }
                    }
                    if let need, let needID, st.term! <= need {
                        move(mid, nextFit(need + 1, turnusOf(byID[mid]!["turnus"])),
                             "Voraussetzung \(textOf(byID[needID]!["title"])) zuerst")
                        changed = true
                    }
                }
                if !changed { return }
            }
        }

        fixPrerequisites()
        var t = lower
        while !included.isEmpty && t <= included.map({ state[$0]!.term! }).max()! {
            while load(t) > capLP {
                let cands = included.filter { state[$0]!.term == t && state[$0]!.status == "plan"
                    && electiveKinds.contains(textOf(byID[$0]!["kind"])) }
                guard var pick = cands.first else { break }
                func key(_ i: String) -> (Int, Int) { (semOf(byID[i]!) ?? 99, order[i]!) }
                for i in cands.dropFirst() where key(i) > key(pick) { pick = i }
                move(pick, nextFit(t + 1, turnusOf(byID[pick]!["turnus"])), "Mehr als \(Int(capLP)) LP im Semester")
                fixPrerequisites()
            }
            t += 1
        }

        for mid in included where state[mid]!.status == "plan" {
            state[mid]!.status = state[mid]!.term! <= current ? "offen" : "geplant"
        }

        // Semesterliste
        let last = max(lastRegular, included.map { state[$0]!.term! }.max() ?? lastRegular)
        var semesters: [JSONValue] = []
        var semesterLP: [(Int, String, Double)] = []
        if start <= last {
            for t in start...last {
                let ids = included.filter { state[$0]!.term == t }
                    .sorted { (semOf(byID[$0]!) ?? 99, order[$0]!) < (semOf(byID[$1]!) ?? 99, order[$1]!) }
                let lp = ids.reduce(0.0) { $0 + lpOf(byID[$1]!) }
                semesterLP.append((t, termName(t), lp))
                semesters.append(["term": .string(termName(t)), "fachsemester": .number(Double(t - start + 1)),
                                  "current": .bool(t == current), "lp": .number(lp),
                                  "modules": .array(ids.map { .object(entry(byID[$0]!, state[$0]!)) })])
            }
        }

        let lpDone = included.reduce(0.0) { $0 + (state[$1]!.status == "bestanden" ? lpOf(byID[$1]!) : 0) }
        let total = num(catalog["total_lp"]) ?? 0
        let lpTotal = total != 0 ? total : included.reduce(0.0) { $0 + lpOf(byID[$1]!) }
        let lpExpected = included.reduce(0.0) { acc, id in
            guard let s = semOf(byID[id]!), start + s - 1 < current else { return acc }
            return acc + lpOf(byID[id]!)
        }

        var notes: [[String: JSONValue]] = []
        for mid in included {
            let m = byID[mid]!, st = state[mid]!
            let title = textOf(m["title"])
            if st.status != "bestanden" && st.final {
                notes.append(note("endgueltig", mid, "\(title): endgültig nicht bestanden – sprich mit der Studienberatung."))
            } else if (st.status == "nicht_bestanden" && st.attempt == 2) || (st.status == "angemeldet" && st.attempt == 3) {
                notes.append(note("letzter_versuch", mid, "\(title): Letzter Versuch – sprich mit der Studienberatung."))
            }
            if st.status == "bestanden" { continue }
            for p in prereqs(m) {
                guard let pm = byID[p] else { continue }
                let ptitle = textOf(pm["title"])
                if let ps = state[p] {
                    if ps.status != "bestanden" && st.status == "angemeldet" {
                        notes.append(note("voraussetzung", mid, "\(title): Voraussetzung \(ptitle) ist noch nicht bestanden."))
                    }
                } else {
                    notes.append(note("voraussetzung", mid, "\(title): Voraussetzung \(ptitle) ist nicht im Plan."))
                }
            }
        }
        for (t, name, lp) in semesterLP where t >= lower && lp > capLP {
            notes.append(note("ueberlast", nil, "\(name): \(fmtLP(lp)) LP geplant, mehr als \(Int(capLP)) LP (Richtwert \(Int(targetLP)) LP)."))
        }
        if current > start && lpExpected - lpDone >= behindLP {
            notes.append(note("rueckstand", nil, "Du liegst \(fmtLP(lpExpected - lpDone)) LP hinter dem Studienverlaufsplan: "
                              + "\(fmtLP(lpDone)) von \(fmtLP(lpExpected)) LP bis zum Ende des \(current - start). Fachsemesters."))
        }
        notes = LocalTimetable.stableSorted(notes) { noteRank[$0["kind"]!.string!]! < noteRank[$1["kind"]!.string!]! }

        var electives: [JSONValue] = []
        for m in mods where electiveKinds.contains(textOf(m["kind"])) {
            let id = idOf(m), st = state[id]
            electives.append(["id": .string(id), "title": .string(textOf(m["title"])), "kind": m["kind"] ?? .null,
                              "area": m["area"] ?? .null, "lp": .number(lpOf(m)), "semester": opt(semOf(m)),
                              "chosen": .bool(chosen.contains(id)), "included": .bool(st != nil), "status": opt(st?.status)])
        }

        let plan: [String: JSONValue] = [
            "available": true, "reason": .null, "message": .null,
            "university": catalog["university"] ?? .null, "program": catalog["program"] ?? .null,
            "degree": catalog["degree"] ?? .null, "po": catalog["po"] ?? .null, "code": catalog["code"] ?? .null,
            "catalog_term": catalog["catalog_term"] ?? .null,
            "start_term": .string(termName(start)), "current_term": .string(termName(current)),
            "current_fachsemester": .number(Double(current - start + 1)),
            "semesters": .array(semesters), "lp_done": .number(lpDone), "lp_total": .number(lpTotal),
            "lp_expected": .number(lpExpected), "notes": .array(notes.map(JSONValue.object)), "electives": .array(electives),
            "unmatched": .array(unmatched.map(JSONValue.string)), "disclaimer": .string(disclaimer),
        ]
        return Result(plan: plan, state: state, hist: hist, modules: mods, byID: byID)
    }

    static func entry(_ m: [String: JSONValue], _ st: ModuleState) -> [String: JSONValue] {
        ["id": m["id"] ?? .null, "title": .string(textOf(m["title"])), "code": m["code"] ?? .null, "kind": m["kind"] ?? .null,
         "area": m["area"] ?? .null, "lp": .number(lpOf(m)), "semester": numJSON(m["semester"]), "turnus": m["turnus"] ?? .null,
         "status": .string(st.status), "attempt": opt(st.attempt), "grade": opt(st.grade),
         "moved_from": opt(st.movedFrom), "reason": opt(st.reason), "last_attempt": .bool(st.lastAttempt)]
    }

    static func note(_ kind: String, _ moduleID: String?, _ text: String) -> [String: JSONValue] {
        ["kind": .string(kind), "tone": .string((noteRank[kind] ?? 9) <= 1 ? "bad" : "warn"), "module_id": opt(moduleID),
         "text": .string(text)]
    }

    /// Der Plan (`build_plan`)
    public static func buildPlan(catalog: JSONValue, grades: [[String: JSONValue]], settings: [String: JSONValue],
                                 today: String) -> JSONValue {
        .object(compute(catalog: catalog, grades: grades, settings: settings, today: today).plan)
    }

    /// Ohne Katalog: reason als Code, message als Text (`unavailable`)
    static func unavailable(_ reason: String, po: String?) -> [String: JSONValue] {
        let message = reason == "no_catalog_po" ? "Für die Prüfungsordnung \(po ?? "None") gibt es noch keinen Katalog." : noCatalog
        return ["available": false, "reason": .string(reason), "message": .string(message), "university": .null,
                "program": .null, "degree": .null, "po": .null, "code": .null, "catalog_term": .null, "start_term": .null,
                "current_term": .null, "current_fachsemester": .null, "semesters": [], "lp_done": 0, "lp_total": 0,
                "lp_expected": 0, "notes": [], "electives": [], "unmatched": [], "disclaimer": .string(disclaimer)]
    }
}
