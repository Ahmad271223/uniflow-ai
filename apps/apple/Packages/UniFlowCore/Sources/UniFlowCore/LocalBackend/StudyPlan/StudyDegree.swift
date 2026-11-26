import Foundation

// Mehr-Faecher-Studiengang und "bestanden je Semester" (app/study_plan.py, 26.11.2026, echtes Konto Uni Hildesheim): das
// LSF fuehrt jedes Fach eines Zwei-Faecher-Bachelors als eigenen "Studiengang" unter demselben Abschluss ("Abschluss: [B5]
// Polyvalenter Zwei-Fächer-Bachelor … Studiengang: [105] Mathematik PO-Version: 2025", dazu Wirtschaft, Erziehungs- und
// Sozialwissenschaften, Philosophie). Vorher galten die anderen Faecher als "Früheres Studium" oder zaehlten im Katalog
// des gewaehlten Fachs mit ("69 von 72 LP"). Sie sind zusammen EIN Studiengang: Bachelor 180 LP, Master 120 LP.
extension StudyPlanEngine {
    private static let combinedRE = PyRegex(#"zwei[- ]?f(?:ä|ae)cher|zwei[- ]?fach|2[- ]?f(?:ä|ae)cher|mehr[- ]?f(?:ä|ae)cher|mehrfach|kombi|lehramt"#,
                                            ignoreCase: true)
    private static let hisLabelRE = PyRegex(#"^\s*Abschluss:\s*((?:\[[^\]]*\]\s*)?.*?)\s*Studiengang:\s*(?:\[[^\]]*\]\s*)?(.*?)\s*$"#,
                                            ignoreCase: true)
    private static let hisPORE = PyRegex(#"PO[- ]?Version:?\s*([0-9]{4})"#, ignoreCase: true)
    private static let hisPOTailRE = PyRegex(#"PO[- ]?Version:?\s*[0-9]{4}.*$"#, ignoreCase: true)
    private static let bracketRE = PyRegex(#"^\[[^\]]*\]\s*"#)
    private static let spaceRE = PyRegex(#"\s+"#)
    private static let gradeCellRE = PyRegex(#"[0-9],[0-9]{1,2}\z"#)
    /// Text des Kontos in einer Leistungszeile (`GradeRows.accountPrefix`, `qis.ACCOUNT_PREFIX`)
    static let accountPrefix = "Gesamtkonto: "

    struct HISLabel: Equatable {
        /// Abschluss mit Nummer ("[B5] Polyvalenter Zwei-Fächer-Bachelor …"): Schluessel des Studiengangs
        var degreeKey: String
        var degree: String
        var subject: String
        var po: String?
    }

    /// `his_label`: 'Abschluss: [B5] <Abschluss> Studiengang: [105] <Fach> PO-Version: 2025'; nil fuer andere
    /// Bezeichnungen (QIS der LUH)
    static func hisLabel(_ label: String?) -> HISLabel? {
        let text = PyText.strip(label ?? "")
        guard let m = hisLabelRE.match(text) else { return nil }
        let po = hisPORE.search(text)?.group(1)
        let subject = stripChars(spaceRE.sub(hisPOTailRE.sub(m.group(2) ?? "", " "), " "), " ,;:-.")
        let key = PyText.strip(spaceRE.sub(m.group(1) ?? "", " "))
        let degree = PyText.strip(bracketRE.sub(key))
        return HISLabel(degreeKey: key, degree: degree, subject: subject.isEmpty ? "Ohne Angabe" : subject, po: po)
    }

    /// `str.strip(chars)`
    private static func stripChars(_ s: String, _ chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        var u = Array(s.unicodeScalars)
        while let f = u.first, set.contains(f) { u.removeFirst() }
        while let l = u.last, set.contains(l) { u.removeLast() }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: u)
        return String(out)
    }

    struct CombinedDegree: Equatable {
        var degree: String
        /// Bezeichnungen der Faecher in der Reihenfolge des ersten Auftretens
        var labels: [String]
    }

    /// `combined_degree`: Faecher eines Mehr-Faecher-Studiengangs im Notenspiegel. Nur wenn mindestens zwei Faecher
    /// denselben Abschluss tragen und der Abschluss ein Mehr-Faecher-Studiengang ist; ein Wechsel des Studiengangs im
    /// selben Abschluss ("Bachelor") bleibt "Früheres Studium". Bei mehreren der des aktuellen Studiengangs.
    static func combinedDegree(_ grades: [[String: JSONValue]]) -> CombinedDegree? {
        var order: [String] = [], groups: [String: CombinedDegree] = [:]
        for r in grades {
            let label = PyText.strip(textOf(r["abschluss"]))
            guard !label.isEmpty, let h = hisLabel(label), combinedRE.search(h.degree) != nil else { continue }
            if groups[h.degreeKey] == nil {
                groups[h.degreeKey] = CombinedDegree(degree: h.degree, labels: [])
                order.append(h.degreeKey)
            }
            if !groups[h.degreeKey]!.labels.contains(label) { groups[h.degreeKey]!.labels.append(label) }
        }
        let keys = order.filter { groups[$0]!.labels.count >= 2 }
        guard !keys.isEmpty else { return nil }
        if let current = hisLabel(abschlussOf(grades)), keys.contains(current.degreeKey) { return groups[current.degreeKey] }
        var best = keys[0]
        for k in keys.dropFirst() where groups[k]!.labels.count > groups[best]!.labels.count { best = k }
        return groups[best]
    }

    /// `degree_total`: Bachelor 180, Master 120, sonst unbekannt
    static func degreeTotal(_ name: String) -> Int? {
        let n = name.lowercased()
        return n.contains("bachelor") ? 180 : n.contains("master") ? 120 : nil
    }

    private static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .none, .some(.null): return false
        case .some(.bool(let b)): return b
        case .some(.string(let s)): return !s.isEmpty
        case .some(.number(let d)): return d != 0
        default: return true
        }
    }

    /// `degree_overview`: Ueberblick ueber den ganzen Mehr-Faecher-Studiengang (LP aller Faecher wie Uni & Noten, die
    /// Gesamtzahl, je Fach Name, PO, LP, bestandene Leistungen; `current` = Zeilen des Fachs, dessen Katalog geplant wird;
    /// dazu das Gesamtkonto des LSF). `.null` ohne Mehr-Faecher-Studiengang.
    static func degreeOverview(_ grades: [[String: JSONValue]], current: [[String: JSONValue]], lpManual: Double? = nil) -> JSONValue {
        guard let deg = combinedDegree(grades) else { return .null }
        let mine = Set(current.map { PyText.strip(textOf($0["abschluss"])) })
        var subjects: [JSONValue] = [], sum = 0.0
        for label in deg.labels {
            let rows = grades.filter { PyText.strip(textOf($0["abschluss"])) == label && $0["source"]?.string != "anmeldung" }
            let h = hisLabel(label)
            let lp = GradesModel.round1(PyMath.sum(rows.map { num($0["lp_counted"]) ?? 0 }))
            sum += lp
            subjects.append(["label": .string(label), "program": .string(h?.subject ?? "Ohne Angabe"), "po": opt(h?.po),
                             "lp_done": .number(lp), "passed": .number(Double(rows.filter { truthy($0["counted"]) }.count)),
                             "current": .bool(mine.contains(label))])
        }
        var officialLP: JSONValue = .null, officialGrade: JSONValue = .null
        for r in grades {
            let text = textOf(r["text"])
            guard text.hasPrefix(accountPrefix), text.lowercased().contains("gesamtnote"),
                  deg.labels.contains(PyText.strip(textOf(r["abschluss"]))) else { continue }
            let lp = creditsOf(r)
            officialLP = lp == 0 ? .null : .number(lp)
            let cells = textOf(r["raw"]).components(separatedBy: " | ").map(PyText.strip)
            if let g = cells.dropFirst().first(where: { gradeCellRE.match($0) != nil && $0 != "0,0" && $0 != "0,00" }) {
                officialGrade = .string(g)
            }
            break
        }
        return ["name": .string(deg.degree), "lp_total": opt(degreeTotal(deg.degree)),
                "lp_done": .number(GradesModel.round1(sum + (lpManual ?? 0))), "official_lp": officialLP,
                "official_grade": officialGrade, "subjects": .array(subjects)]
    }

    /// `passed_terms`: bestanden je Semester (Wunsch des Inhabers 26.11.2026: "erkennen, in welchem Semester man was
    /// bestanden hat"): jede zaehlende Leistung des Notenspiegels mit ihrem Semester (Spalte "Semester", sonst aus dem
    /// Pruefungsdatum), aelteste zuerst; ohne erkennbares Semester am Ende (term null). Unabhaengig vom Katalog, alle Faecher.
    static func passedTerms(_ grades: [[String: JSONValue]]) -> [JSONValue] {
        var byTerm: [Int: (lp: Double, rows: [JSONValue])] = [:]
        var unknown: (lp: Double, rows: [JSONValue])?
        for r in grades where truthy(r["counted"]) && r["source"]?.string != "anmeldung" {
            let lp = num(r["lp_counted"]) ?? 0
            let note = textOf(r["note"])
            let row: JSONValue = ["text": r["text"] ?? .null, "lp": .number(lp), "note": note.isEmpty ? .null : .string(note),
                                  "program": opt(hisLabel(textOf(r["abschluss"]))?.subject)]
            if let t = rowTerm(r) {
                byTerm[t, default: (0, [])].lp += lp
                byTerm[t]!.rows.append(row)
            } else {
                unknown = ((unknown?.lp ?? 0) + lp, (unknown?.rows ?? []) + [row])
            }
        }
        var out: [JSONValue] = byTerm.keys.sorted().map { t in
            ["term": .number(Double(t)), "name": .string(termName(t)), "lp": .number(GradesModel.round1(byTerm[t]!.lp)),
             "rows": .array(byTerm[t]!.rows)]
        }
        if let u = unknown { out.append(["term": .null, "name": .null, "lp": .number(GradesModel.round1(u.lp)), "rows": .array(u.rows)]) }
        return out
    }
}
