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
    private static let creditsRE = PyRegex(#"[0-9]{1,3}(?:[.,][0-9]{1,2})?\z"#)

    // Wahlbereiche (05.11.2026), wie AREA_TYPE_RULES in app/study_plan.py: Typ eines Bereichs aus dem Namen
    static let areaTypeRules: [(String, PyRegex)] = [
        ("abschluss", PyRegex("bachelorarbeit|masterarbeit|abschlussarbeit")),
        ("studium_generale", PyRegex("studium generale")),
        ("schluessel", PyRegex("schluesselkompetenz|soft skills|zusatzkompetenz|ueberfachlich")),
        ("praktikum", PyRegex("betriebspraktikum|fachpraktikum|industriepraktikum|berufspraktikum|berufspraktische")),
        ("seminar", PyRegex("seminar|akademisches arbeiten")),
        ("labor", PyRegex("labor|praktikum")),
        ("projekt", PyRegex("projekt")),
        ("schwerpunkt", PyRegex("schwerpunkt|vertiefungsrichtung|studienrichtung|profilbereich")),
        ("nebenfach", PyRegex("nebenfach|anwendungsfach")),
        ("vertiefung", PyRegex("vertiefung|spezialisierung")),
    ]
    static let areaTypes: Set<String> = Set(areaTypeRules.map(\.0)).union(["pflicht", "wahlpflicht", "wahl"])
    static let groupTypes: [String] = ["schwerpunkt", "nebenfach"]
    static let groupLabels: [String: String] = ["schwerpunkt": "Schwerpunkt", "nebenfach": "Nebenfach",
                                                "vertiefungsrichtung": "Vertiefungsrichtung", "studienrichtung": "Studienrichtung"]
    static let earlyTypes: Set<String> = ["studium_generale", "schluessel", "seminar"]
    static let unitLP = 5.0
    static let maxAreaSlots = 8
    static let maxUnknownSlots = 4
    private static let customIDRE = PyRegex(#"eigen-[0-9]{1,4}\z"#)
    static let maxCustom = 40
    static let maxCustomTitle = 120

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

    // MARK: Wahlbereiche und eigene Lage (05.11.2026)

    /// klein, Umlaute ausgeschrieben (`fold`)
    static func fold(_ v: JSONValue?) -> String { fold(textOf(v)) }

    static func fold(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for u in PyText.lower(text).unicodeScalars {
            switch u.value {
            case 0xE4: out.append(contentsOf: "ae".unicodeScalars)
            case 0xF6: out.append(contentsOf: "oe".unicodeScalars)
            case 0xFC: out.append(contentsOf: "ue".unicodeScalars)
            case 0xDF: out.append(contentsOf: "ss".unicodeScalars)
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// Typ eines Bereichs (`area_type_of`): Name, sonst Modultitel (Haelfte "Seminar"/"Labor"), sonst Art
    static func areaTypeOf(_ name: JSONValue?, kind: String, titles: [String]) -> String {
        let f = fold(name)
        for (t, rx) in areaTypeRules where rx.found(in: f) { return t }
        if kind != "abschluss" && titles.count >= 2 {
            for word in ["seminar", "labor"] where 2 * titles.filter({ PyText.contains(fold($0), word) }).count >= titles.count {
                return word
            }
        }
        return kind
    }

    /// LP einer QIS-Zeile ("5", "7,5"), sonst 0 (`credits_of`)
    static func creditsOf(_ r: [String: JSONValue]) -> Double {
        let s = PyText.strip(textOf(r["credits"]))
        guard creditsRE.match(s) != nil else { return 0 }
        return Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// ganze Zahl (auch 5.0) oder nil (`_int_value`)
    static func intValue(_ v: JSONValue?) -> Int? {
        guard case .number(let d)? = v, d.isFinite, d == d.rounded(), abs(d) < 1e15 else { return nil }
        return Int(d)
    }

    private static func sortedKeys(_ o: [String: JSONValue]) -> [String] { o.keys.sorted(by: PyText.less) }

    /// {Gruppe: Bereichs-id} (`clean_tracks`)
    static func cleanTracks(_ v: JSONValue?) -> [(String, String)] {
        guard let o = v?.object else { return [] }
        return sortedKeys(o).compactMap { k in
            guard !k.isEmpty, let x = o[k]?.string, !x.isEmpty else { return nil }
            return (k, x)
        }
    }

    /// {Modul-id: Semestername} (`clean_placements`)
    static func cleanPlacements(_ v: JSONValue?) -> [(String, String)] {
        guard let o = v?.object else { return [] }
        return sortedKeys(o).compactMap { k in
            guard !k.isEmpty, let t = parseTerm(o[k]) else { return nil }
            return (k, termName(t))
        }
    }

    /// Liste von ids, sortiert, ohne Doppelte (`clean_ids`)
    static func cleanIDs(_ v: JSONValue?) -> [String] {
        guard let list = v?.array else { return [] }
        var out: [String] = []
        for e in list.compactMap(\.string) where !e.isEmpty && !out.contains(where: { $0.unicodeScalars.elementsEqual(e.unicodeScalars) }) {
            out.append(e)
        }
        return out.sorted(by: PyText.less)
    }

    struct CustomEntry {
        var id: String?
        var title: String
        var lp: Double
        var area: String?
        var semester: Int?

        var json: [String: JSONValue] {
            ["id": opt(id), "title": .string(title), "lp": .number(lp), "area": opt(area), "semester": opt(semester)]
        }

        var stored: PyJSON {
            let lpJSON: PyJSON = lp == lp.rounded() && abs(lp) < 1e15 ? .int(String(Int(lp))) : .float(lp)
            return .object([PyJSON.Member("id", id.map(PyJSON.string) ?? .null), PyJSON.Member("title", .string(title)),
                            PyJSON.Member("lp", lpJSON), PyJSON.Member("area", area.map(PyJSON.string) ?? .null),
                            PyJSON.Member("semester", semester.map { .int(String($0)) } ?? .null)])
        }
    }

    /// Eigene Eintraege (`clean_custom`): Titel noetig (hoechstens 120 Zeichen), LP 0..60, Fachsemester 1..20, ids
    /// "eigen-<n>", fehlende neu
    static func cleanCustom(_ v: JSONValue?) -> [CustomEntry] {
        let items = v?.array?.compactMap(\.object) ?? []
        var rows: [CustomEntry] = [], used: [String] = []
        for c in items {
            let title = PyText.strip(PyText.slice(PyText.strip(textOf(c["title"])), 0, maxCustomTitle))
            if title.isEmpty { continue }
            var lp = num(c["lp"]).flatMap { $0 >= 0 && $0 <= 60 ? $0 : nil } ?? 0
            if lp == 0 { lp = 0 }
            let sem = intValue(c["semester"])
            var cid: String? = textOf(c["id"])
            if let x = cid, customIDRE.match(x) == nil || used.contains(x) { cid = nil }
            if let x = cid { used.append(x) }
            let area = textOf(c["area"])
            rows.append(CustomEntry(id: cid, title: title, lp: lp, area: area.isEmpty ? nil : area,
                                    semester: sem.flatMap { (1...20).contains($0) ? $0 : nil }))
            if rows.count >= maxCustom { break }
        }
        var n = 1
        for i in rows.indices where rows[i].id == nil {
            while used.contains("eigen-\(n)") { n += 1 }
            rows[i].id = "eigen-\(n)"
            used.append("eigen-\(n)")
        }
        return rows
    }

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
        var placed = false

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
    /// (Pruefungsnummer -> Modul-id, Namensschluessel -> Modul-id), jeweils das erste Modul (`_index`)
    static func index(_ mods: [[String: JSONValue]]) -> ([String: String], [String: String]) {
        var byCode: [String: String] = [:], byKey: [String: String] = [:]
        for m in mods {
            let id = m["id"]?.string ?? ""
            let code = PyText.strip(textOf(m["code"]))
            if !code.isEmpty, byCode[code] == nil { byCode[code] = id }
            let k = nameKey(m["title"])
            if !k.isEmpty, byKey[k] == nil { byKey[k] = id }
        }
        return (byCode, byKey)
    }

    static func rowModule(_ r: [String: JSONValue], _ byCode: [String: String], _ byKey: [String: String]) -> String? {
        let nr = PyText.strip(textOf(r["pruefungsnr"]))
        return (nr.isEmpty ? nil : byCode[nr]) ?? byKey[nameKey(r["text"])]
    }

    static func match(_ mods: [[String: JSONValue]], _ grades: [[String: JSONValue]]) -> ([String: [[String: JSONValue]]], [String]) {
        let (byCode, byKey) = index(mods)
        var hist: [String: [[String: JSONValue]]] = [:]
        var unmatched: [String] = []
        for r in grades where !isBereich(r) {
            guard let id = rowModule(r, byCode, byKey) else {
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

        func semOf(_ m: [String: JSONValue]) -> Int? {
            guard let s = num(m["semester"]), s >= 1 else { return nil }
            return Int(s)
        }

        // Bereiche (Wahlbereiche, 05.11.2026), wie app/study_plan.py: Mitglieder aus module.area und `areas[].modules`,
        // Art aus den Modulen, Typ aus dem Namen, Gruppen fuer Schwerpunkt/Nebenfach (eins waehlen)
        var areaList: [[String: JSONValue]] = [], areaBy: [String: [String: JSONValue]] = [:]
        for v in catalog["areas"]?.array ?? [] {
            guard let a = v.object, let id = a["id"]?.string, !id.isEmpty, areaBy[id] == nil else { continue }
            areaBy[id] = a
            areaList.append(a)
        }
        func aidOf(_ a: [String: JSONValue]) -> String { a["id"]!.string! }
        var members: [String: [String]] = [:], memberSets: [String: Set<String>] = [:]
        for a in areaList {
            let listed = Set(a["modules"]?.array?.compactMap(\.string) ?? [])
            let ids = mods.filter { $0["area"]?.string == aidOf(a) || listed.contains(idOf($0)) }.map(idOf)
            members[aidOf(a)] = ids
            memberSets[aidOf(a)] = Set(ids)
        }
        var memOf: [String: [String]] = [:]
        for m in mods {
            let prim = m["area"]?.string.flatMap { areaBy[$0] != nil ? $0 : nil }
            memOf[idOf(m)] = (prim.map { [$0] } ?? []) + areaList.map(aidOf).filter { $0 != prim && memberSets[$0]!.contains(idOf(m)) }
        }
        var akind: [String: String] = [:], atype: [String: String] = [:]
        for a in areaList {
            let aid = aidOf(a)
            let kinds = members[aid]!.map { textOf(byID[$0]!["kind"]) }
            var k: String
            if textOf(a["kind"]) == "abschluss" || (!kinds.isEmpty && kinds.allSatisfy { $0 == "abschluss" }) {
                k = "abschluss"
            } else if kinds.contains("wahlpflicht") {
                k = "wahlpflicht"
            } else if kinds.contains("wahl") {
                k = "wahl"
            } else if !kinds.isEmpty {
                k = num(a["lp_max"]) == nil ? "pflicht" : "wahlpflicht"
            } else {
                k = ["pflicht", "wahlpflicht", "wahl"].contains(textOf(a["kind"])) ? textOf(a["kind"]) : "pflicht"
            }
            akind[aid] = k
            let t = textOf(a["type"])
            atype[aid] = areaTypes.contains(t) ? t : areaTypeOf(a["name"], kind: k, titles: members[aid]!.map { textOf(byID[$0]!["title"]) })
        }
        var groupOrder: [String] = [], groupIDs: [String: [String]] = [:]
        for a in areaList {
            var g = textOf(a["group"])
            if g.isEmpty, groupTypes.contains(atype[aidOf(a)]!) { g = atype[aidOf(a)]! }
            guard !g.isEmpty else { continue }
            if groupIDs[g] == nil { groupOrder.append(g) }
            groupIDs[g, default: []].append(aidOf(a))
        }
        groupOrder = groupOrder.filter { groupIDs[$0]!.count >= 2 }
        var groupOf: [String: String] = [:]
        for g in groupOrder { for aid in groupIDs[g]! { groupOf[aid] = g } }
        // gewaehlter Schwerpunkt je Gruppe: Einstellung, sonst der mit den meisten LP bestandener/angemeldeter Module
        let wanted = Dictionary(cleanTracks(settings["tracks"]), uniquingKeysWith: { a, _ in a })
        var track: [String: String] = [:], trackAuto: [String: Bool] = [:]
        for g in groupOrder {
            let ids = groupIDs[g]!
            if let w = wanted[g], ids.contains(w) { track[g] = w; trackAuto[g] = false; continue }
            var best: String?, score = 0.0
            for aid in ids {
                let sc = members[aid]!.filter { byID[$0]!["area"]?.string == aid
                    && (hist[$0] ?? []).contains { ["passed", "registered"].contains(rowResult($0) ?? "") } }
                    .reduce(0.0) { $0 + lpOf(byID[$1]!) }
                if sc > score { best = aid; score = sc }
            }
            if let best { track[g] = best; trackAuto[g] = true }
        }
        let active = Set(areaList.map(aidOf).filter { groupOf[$0] == nil || track[groupOf[$0]!] == $0 })
        let choice = areaList.map(aidOf).filter { active.contains($0) && electiveKinds.contains(akind[$0]!) && atype[$0] != "abschluss" }

        // Module im Plan: Pflicht, gewaehlte Wahlmodule und alles aus QIS; "Nicht belegen" nimmt ein Modul heraus (ausser
        // QIS kennt es); Pflichtmodule eines nicht gewaehlten Schwerpunkts fehlen ebenso
        let excluded = Set(cleanIDs(settings["excluded"]))
        let included = mods.filter { m in
            let id = idOf(m)
            if hist[id] != nil { return true }
            if excluded.contains(id) { return false }
            if electiveKinds.contains(textOf(m["kind"])) { return chosen.contains(id) }
            guard let prim = m["area"]?.string, groupOf[prim] != nil, !active.contains(prim) else { return true }
            return chosen.contains(id)
        }.map(idOf)
        let includedSet = Set(included)
        // eigene Lage je Modul: Semester als Zahl; Bestandenes bleibt im Semester aus QIS
        var placed: [String: Int] = [:], placedOrder: [String] = []
        for (k, v) in cleanPlacements(settings["placements"])
        where includedSet.contains(k) && !(hist[k] ?? []).contains(where: { rowResult($0) == "passed" }) {
            placed[k] = parseTerm(v)!
            placedOrder.append(k)
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
        func fitsSlot(_ mid: String, _ s: (Int, [JSONValue])) -> Bool {
            s.1.isEmpty || memOf[mid]!.contains { s.1.contains(.string($0)) }
        }
        for mid in included {                                       // eigener Platz: belegt einen Platz in dem Semester
            guard let p = placed[mid] else { continue }
            for (k, s) in slots.enumerated() where !taken.contains(k) && start + s.0 - 1 == p && fitsSlot(mid, s) {
                taken.insert(k)
                break
            }
        }
        let elect = included.filter { electiveKinds.contains(textOf(byID[$0]?["kind"])) && semOf(byID[$0]!) == nil && placed[$0] == nil }
        for mid in elect.filter({ hist[$0] != nil }) + elect.filter({ hist[$0] == nil }) {
            for (k, s) in slots.enumerated() where !taken.contains(k) && fitsSlot(mid, s) {
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
            let own = placed[mid]
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
                if let own, own >= begin { st.term = own; st.placed = true }
            } else if let own {
                st.status = "plan"; st.term = own; st.placed = true
                if own < lower {
                    st.term = nextFit(lower, turnus); st.placed = false; st.movedFrom = termName(own)
                    st.reason = "Noch nicht abgelegt – nachholen"
                }
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
                    guard (st.status == "plan" || st.status == "nicht_bestanden") && !st.placed else { continue }
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
                let cands = included.filter { state[$0]!.term == t && state[$0]!.status == "plan" && !state[$0]!.placed
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

        // Eigene Eintraege: Stand aus einer nicht zugeordneten QIS-Zeile mit gleichem Namensschluessel, sonst im
        // gewaehlten Fachsemester (fruehestens jetzt)
        let (byCode, byKey) = index(mods)
        let loose = grades.filter { !isBereich($0) && rowModule($0, byCode, byKey) == nil }
        var custom: [(Int, [String: JSONValue])] = []
        for c in cleanCustom(settings["custom"]) {
            let key = nameKey(c.title)
            let rows = key.isEmpty ? [] : loose.filter { nameKey($0["text"]) == key }
            let passedRows = rows.filter { rowResult($0) == "passed" }
            let area = c.area.flatMap { active.contains($0) ? $0 : nil }
            var e: [String: JSONValue] = [
                "id": opt(c.id), "title": .string(c.title), "code": .null, "kind": .string(area.map { akind[$0]! } ?? "wahl"),
                "area": opt(area), "lp": .number(c.lp), "semester": opt(c.semester), "turnus": .null, "status": .null,
                "attempt": .null, "grade": .null, "moved_from": .null, "reason": .null, "last_attempt": false, "placed": false,
                "hints": [], "custom": true]
            let t: Int
            if !passedRows.isEmpty {
                var best = passedRows[0]
                for r in passedRows.dropFirst() where (parseTerm(r["semester"]) ?? -1) >= (parseTerm(best["semester"]) ?? -1) { best = r }
                let g = PyText.strip(textOf(best["note"]))
                e["status"] = "bestanden"
                e["grade"] = g.isEmpty ? .null : .string(g)
                t = max(parseTerm(best["semester"]) ?? current, start)
            } else if rows.contains(where: { rowResult($0) == "registered" }) {
                t = current
                e["status"] = "angemeldet"
            } else {
                t = max(c.semester.map { start + $0 - 1 } ?? lower, lower)
                e["status"] = .string(t <= current ? "offen" : "geplant")
            }
            custom.append((t, e))
        }

        // Stand je Bereich: jedes Modul zaehlt einmal, im eigenen Bereich, sonst im ersten aktiven Bereich mit Platz
        var target: [String: Double?] = [:]
        for a in areaList {
            let aid = aidOf(a), req = num(a["lp_required"]), mx = num(a["lp_max"])
            if let req, req > 0 {
                target[aid] = req
            } else if groupOf[aid] != nil, active.contains(aid), let mx, mx != 0 {
                target[aid] = mx
            } else {
                target[aid] = .some(nil)
            }
        }
        var used: [String: Double] = [:], done: [String: Double] = [:], counted: [String: [String]] = [:], nDone: [String: Int] = [:]
        for a in areaList { used[aidOf(a)] = 0; done[aidOf(a)] = 0; counted[aidOf(a)] = []; nDone[aidOf(a)] = 0 }
        func count(_ cands: [String], _ ident: String, _ lp: Double, _ passed: Bool) {
            let pick = cands.first { x in target[x]!.map { used[x]! < $0 } ?? true } ?? cands[0]
            used[pick]! += lp
            counted[pick]!.append(ident)
            if passed { done[pick]! += lp; nDone[pick]! += 1 }
        }
        for mid in included {
            let cands = memOf[mid]!.filter { active.contains($0) }
            if !cands.isEmpty { count(cands, mid, lpOf(byID[mid]!), state[mid]!.status == "bestanden") }
        }
        for (_, e) in custom {
            if let a = e["area"]?.string { count([a], e["id"]!.string!, e["lp"]!.double!, e["status"]?.string == "bestanden") }
        }

        // Plaetze im Semester fuer offene Wahl (freie Plaetze laut Verlaufsplan, sonst aus offenen LP/Modulen, Gruppe
        // ohne Wahl: ein Platz "... waehlen")
        var unit: [String: Double] = [:], mreq: [String: Int?] = [:]
        for a in areaList {
            let aid = aidOf(a)
            let lps = members[aid]!.map { lpOf(byID[$0]!) }.filter { $0 > 0 }.sorted()
            unit[aid] = lps.isEmpty ? unitLP : lps[(lps.count - 1) / 2]
            let n = intValue(a["modules_required"])
            mreq[aid] = .some(n.flatMap { $0 >= 1 ? $0 : nil })
        }
        var openLP: [String: Double?] = [:], openN: [String: Int?] = [:], room: [String: Double?] = [:], nslots: [String: Int] = [:]
        for a in areaList {
            let aid = aidOf(a)
            openLP[aid] = .some(target[aid]!.map { $0 - used[aid]! })
            openN[aid] = .some(mreq[aid]!.map { $0 - counted[aid]!.count })
            let mx = num(a["lp_max"])
            room[aid] = .some(mx.flatMap { $0 != 0 ? $0 - used[aid]! : nil })
            nslots[aid] = 0
        }
        var customLP: [Int: Double] = [:], slotLP: [Int: Double] = [:]
        for (t, e) in custom { customLP[t, default: 0] += e["lp"]!.double! }
        var places: [(Int, [String: JSONValue])] = []
        func isOpen(_ aid: String) -> Bool {
            if let o = openLP[aid]! { return o > 0 }
            if let n = openN[aid]! { return n > 0 }
            return false
        }
        func isUnknown(_ aid: String) -> Bool { openLP[aid]! == nil && openN[aid]! == nil && room[aid]! == nil }
        func termLoad(_ t: Int) -> Double { load(t) + (customLP[t] ?? 0) + (slotLP[t] ?? 0) }
        func hintOf(_ aids: [String]) -> Int {
            for aid in aids {
                if let h = intValue(areaBy[aid]!["semester"]), (1...20).contains(h) { return h }
            }
            let sems = aids.flatMap { aid in members[aid]!.compactMap { semOf(byID[$0]!) } }.sorted()
            if !sems.isEmpty { return sems[(sems.count - 1) / 2] }
            if aids.contains(where: { earlyTypes.contains(atype[$0]!) }) { return max(1, (regular + 1) / 2) }
            return max(1, regular - 1)
        }
        func pickTerm(_ h: Int) -> Int {
            let lo = max(start + h - 1, lower)
            var best = lo
            for t in lo...max(lastRegular, lo) where termLoad(t) < termLoad(best) { best = t }
            return best
        }
        func place(_ t: Int, _ kind: String, _ title: String, _ area: String?, _ areas: [String], _ group: String?,
                   _ lp: Double?, _ lpMax: Double?, _ fach: Int) {
            places.append((t, ["id": .string("platz-\(places.count + 1)"), "kind": .string(kind), "title": .string(title),
                               "area": opt(area), "areas": .array(areas.map(JSONValue.string)), "group": opt(group),
                               "type": .string(area.map { atype[$0]! } ?? group ?? "wahl"),
                               "area_kind": .string(area.map { akind[$0]! } ?? "wahlpflicht"),
                               "lp": lp.map(JSONValue.number) ?? .null, "lp_max": lpMax.map(JSONValue.number) ?? .null,
                               "fachsemester": .number(Double(fach))]))
            slotLP[t, default: 0] += lp ?? 0
            if let area { nslots[area]! += 1 }
        }
        let rawSlots = (catalog["plan_slots"]?.array ?? []).compactMap { v -> [String: JSONValue]? in
            guard let o = v.object, let d = num(o["semester"]), d >= 1, d == d.rounded() else { return nil }
            return o
        }
        func slotAreas(_ o: [String: JSONValue]) -> [String] { o["areas"]?.array?.compactMap(\.string) ?? [] }
        var referenced = Set<String>()
        for o in rawSlots {
            let ar = slotAreas(o)
            referenced.formUnion(ar.isEmpty ? choice : ar)
        }
        for (k, o) in rawSlots.enumerated() where !taken.contains(k) {
            let ar = slotAreas(o)
            let cands = ar.isEmpty ? choice : ar.filter { choice.contains($0) }
            guard let pick = cands.first(where: isOpen) ?? cands.first(where: { room[$0]!.map { $0 > 0 } ?? false })
                    ?? cands.first(where: isUnknown) else { continue }
            let lp = num(o["lp"]).flatMap { $0 > 0 ? $0 : nil } ?? unit[pick]!
            if let r = room[pick]! { room[pick] = .some(r - lp) }
            if let x = openLP[pick]! { openLP[pick] = .some(x - lp) }
            if let x = openN[pick]! { openN[pick] = .some(x - 1) }
            let fach = Int(num(o["semester"])!)
            let title = textOf(o["title"])
            place(max(start + fach - 1, lower), "slot", title.isEmpty ? textOf(areaBy[pick]!["name"]) : title, pick, cands, nil, lp,
                  num(o["lp_max"]), fach)
        }
        var unknownLeft = maxUnknownSlots
        for aid in choice where !referenced.contains(aid) {
            let o = openLP[aid]!
            var n: Int
            if let o {
                n = o > 0 ? Int((o / unit[aid]!).rounded(.up)) : 0
            } else if let x = openN[aid]! {
                n = max(0, x)
            } else if counted[aid]!.isEmpty && unknownLeft > 0 {       // ohne LP-Angabe: ein Platz, solange nichts gewaehlt
                n = 1
                unknownLeft -= 1
            } else {
                n = 0
            }
            let h = hintOf([aid])
            var step = unit[aid]!
            if let o, step < 3, n > 1 { n = 1; step = o }
            for j in 0..<min(n, maxAreaSlots) {
                let lp = o.map { min(step, $0 - Double(j) * step) } ?? step
                place(pickTerm(h), "area", textOf(areaBy[aid]!["name"]), aid, [aid], groupOf[aid], lp, nil, h)
            }
        }
        for g in groupOrder where track[g] == nil {
            let ids = groupIDs[g]!
            var lps: [Double] = []
            for aid in ids {
                let req = num(areaBy[aid]!["lp_required"]), mx = num(areaBy[aid]!["lp_max"])
                let v = (req.flatMap { $0 > 0 ? $0 : nil }) ?? mx
                if let v, v != 0 { lps.append(v) }
            }
            let h = hintOf(ids)
            place(pickTerm(h), "track", "\(groupLabels[g] ?? g) wählen", nil, ids, g, lps.max(), nil, h)
        }

        // Semesterliste
        let last = ([lastRegular] + included.map { state[$0]!.term! } + custom.map(\.0) + places.map(\.0)).max()!
        var semesters: [JSONValue] = []
        var semesterLP: [(Int, String, Double)] = []
        if start <= last {
            for t in start...last {
                let ids = included.filter { state[$0]!.term == t }
                    .sorted { (semOf(byID[$0]!) ?? 99, order[$0]!) < (semOf(byID[$1]!) ?? 99, order[$1]!) }
                let mine = custom.filter { $0.0 == t }.map(\.1)
                let here = places.filter { $0.0 == t }.map(\.1)
                let lp = ids.reduce(0.0) { $0 + lpOf(byID[$1]!) } + mine.reduce(0.0) { $0 + $1["lp"]!.double! }
                semesterLP.append((t, termName(t), lp))
                semesters.append(["term": .string(termName(t)), "fachsemester": .number(Double(t - start + 1)),
                                  "current": .bool(t == current), "lp": .number(lp),
                                  "modules": .array(ids.map { .object(entry(byID[$0]!, state[$0]!, moduleHints(byID[$0]!, state[$0]!, state, byID))) }
                                                    + mine.map(JSONValue.object)),
                                  "slots": .array(here.map(JSONValue.object)),
                                  "lp_slots": .number(here.reduce(0.0) { $0 + ($1["lp"]?.double ?? 0) })])
            }
        }

        let lpDone = included.reduce(0.0) { $0 + (state[$1]!.status == "bestanden" ? lpOf(byID[$1]!) : 0) }
            + custom.reduce(0.0) { $0 + ($1.1["status"]?.string == "bestanden" ? $1.1["lp"]!.double! : 0) }
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
                              "chosen": .bool(chosen.contains(id)), "included": .bool(st != nil), "status": opt(st?.status),
                              "areas": .array(memOf[id]!.map(JSONValue.string)), "turnus": m["turnus"] ?? .null,
                              "excluded": .bool(excluded.contains(id))])
        }

        var areasOut: [JSONValue] = []
        for a in areaList {
            let aid = aidOf(a)
            let tg = target[aid]!
            areasOut.append(.object([
                "id": .string(aid), "name": .string(textOf(a["name"])), "type": .string(atype[aid]!), "kind": .string(akind[aid]!),
                "group": opt(groupOf[aid]), "active": .bool(active.contains(aid)),
                "choice": .bool(electiveKinds.contains(akind[aid]!) && atype[aid] != "abschluss"),
                "lp_required": numJSON(a["lp_required"]), "lp_max": numJSON(a["lp_max"]), "target": tg.map(JSONValue.number) ?? .null,
                "modules_required": opt(mreq[aid]!), "lp_done": .number(done[aid]!), "lp_planned": .number(used[aid]! - done[aid]!),
                "lp_open": tg.map { .number(max(0, $0 - used[aid]!)) } ?? .null,
                "count": .number(Double(counted[aid]!.count)), "count_done": .number(Double(nDone[aid]!)),
                "options": .number(Double(members[aid]!.count)), "chosen": .array(counted[aid]!.map(JSONValue.string)),
                "slots": .number(Double(nslots[aid]!)), "rule": opt(textOf(a["rule"]).isEmpty ? nil : textOf(a["rule"])),
            ]))
        }
        let groupsOut: [JSONValue] = groupOrder.map { g in
            .object(["id": .string(g), "label": .string(groupLabels[g] ?? g), "options": .array(groupIDs[g]!.map(JSONValue.string)),
                     "chosen": opt(track[g]), "auto": .bool(trackAuto[g] ?? false)])
        }
        var excludedOut: [JSONValue] = []
        for m in mods where excluded.contains(idOf(m)) && state[idOf(m)] == nil {
            excludedOut.append(["id": .string(idOf(m)), "title": .string(textOf(m["title"])), "kind": m["kind"] ?? .null,
                                "lp": .number(lpOf(m)), "semester": opt(semOf(m))])
        }
        var placementsOut: [String: JSONValue] = [:]
        for k in placedOrder { placementsOut[k] = .string(termName(placed[k]!)) }

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
            "areas": .array(areasOut), "groups": .array(groupsOut), "excluded": .array(excludedOut),
            "placements": .object(placementsOut),
        ]
        return Result(plan: plan, state: state, hist: hist, modules: mods, byID: byID)
    }

    static func entry(_ m: [String: JSONValue], _ st: ModuleState, _ hints: [String] = []) -> [String: JSONValue] {
        ["id": m["id"] ?? .null, "title": .string(textOf(m["title"])), "code": m["code"] ?? .null, "kind": m["kind"] ?? .null,
         "area": m["area"] ?? .null, "lp": .number(lpOf(m)), "semester": numJSON(m["semester"]), "turnus": m["turnus"] ?? .null,
         "status": .string(st.status), "attempt": opt(st.attempt), "grade": opt(st.grade),
         "moved_from": opt(st.movedFrom), "reason": opt(st.reason), "last_attempt": .bool(st.lastAttempt),
         "placed": .bool(st.placed), "hints": .array(hints.map(JSONValue.string))]
    }

    /// Hinweise je Modul (`module_hints`): Turnus passt nicht zum Semester, Voraussetzung nicht davor oder nicht im Plan
    static func moduleHints(_ m: [String: JSONValue], _ st: ModuleState, _ state: [String: ModuleState],
                            _ byID: [String: [String: JSONValue]]) -> [String] {
        guard st.status != "bestanden", let t = st.term else { return [] }
        var out: [String] = []
        let turnus = turnusOf(m["turnus"])
        if !fits(t, turnus) {
            out.append("Laut Katalog nur im \(turnus == "WS" ? "Wintersemester" : "Sommersemester") angeboten")
        }
        for p in prereqs(m) {
            guard let pm = byID[p] else { continue }
            let ptitle = textOf(pm["title"])
            if let ps = state[p] {
                if ps.status != "bestanden", let pt = ps.term, pt >= t { out.append("Voraussetzung \(ptitle) liegt nicht davor") }
            } else {
                out.append("Voraussetzung \(ptitle) ist nicht im Plan")
            }
        }
        return out
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
                "lp_expected": 0, "notes": [], "electives": [], "unmatched": [], "disclaimer": .string(disclaimer),
                "areas": [], "groups": [], "excluded": [], "placements": [:]]
    }
}
