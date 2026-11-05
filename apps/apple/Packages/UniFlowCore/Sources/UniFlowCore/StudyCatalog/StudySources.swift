import Foundation

/// Register der Modulkatalog-Quellen (packages/shared-contracts/study-sources.json, im Kern als `StudySourcesData.json`
/// eingebettet; tools/gen-study-catalog-fixture.py schreibt beide gleich) und die Zuordnung QIS `abschluss` -> Eintrag
/// wie `match_program` in app/study_catalog.py.
public struct StudySources: Sendable {
    public let json: JSONValue

    public init(json: JSONValue) { self.json = json }

    /// Register dieses Builds
    public static let bundled: StudySources = {
        StudySources(json: (try? JSONValue.parse(StudySourcesData.json)) ?? .object(["v": .number(1), "universities": .array([])]))
    }()

    /// Vorschlag zu einem QIS-Studiengang
    public struct Match: Equatable, Sendable {
        public var university: String
        public var programID: String?
        public var program: String?
        public var degree: String?
        public var po: String
        public var code: String
        public var qisLabel: String?
        public var qisPO: String?
        public var needsConfirmation: Bool

        /// Form wie das Python-Ergebnis (Fixture registry-cases.json)
        public var json: JSONValue {
            func t(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
            return .object(["university": .string(university), "program_id": t(programID), "program": t(program), "degree": t(degree),
                            "po": .string(po), "code": .string(code), "qis_label": t(qisLabel), "qis_po": t(qisPO),
                            "needs_confirmation": .bool(needsConfirmation)])
        }
    }

    // MARK: QIS-Bezeichnung

    public struct Abschluss: Equatable, Sendable {
        public var name: String
        public var po: String?
        /// "B" oder "M", nil ohne Angabe
        public var degree: String?
    }

    static let degreeHints: [(String, String)] = [
        (#"\bbachelor\b|\bb\.?\s?sc\b|\bb\.?\s?a\b|\bb\.?\s?eng\b"#, "B"),
        (#"\bmaster\b|\bm\.?\s?sc\b|\bm\.?\s?a\b|\bm\.?\s?eng\b"#, "M"),
    ]

    /// LSF Hildesheim: "Abschluss: [82] Bachelor Studiengang: [052] B.A. Erziehungswissenschaft PO-Version: 2022"
    /// (`_his_abschluss`); Abschlussart aus der Abkuerzung vor dem Namen, sonst aus dem Abschluss
    static func hisAbschluss(_ text: String, po: String?) -> Abschluss? {
        guard let m = CatalogRx.match(#"^\s*Abschluss:\s*(?:\[[^\]]*\]\s*)?(.*?)\s*Studiengang:\s*(?:\[[^\]]*\]\s*)?(.*)$"#,
                                      text.replacingOccurrences(of: "\n", with: " "), ignoreCase: true) else { return nil }
        var rest = CatalogRx.sub(#"PO[- ]?Version:?\s*[0-9]{4}.*$"#, " ", m[2] ?? "", ignoreCase: true)
        var degree: String?
        if let d = CatalogRx.match(#"^\s*([BM])\s?\.?\s?(?:A|Sc|Ed|Eng|Mus)\b\.?"#, rest, ignoreCase: true), let whole = d[0] {
            degree = (d[1] ?? "").uppercased()
            rest = String(rest.dropFirst(whole.count))
        }
        if degree == nil {
            for (rx, d) in degreeHints where CatalogRx.search(rx, m[1] ?? "", ignoreCase: true) != nil {
                degree = d
                break
            }
        }
        let name = StudyCatalogText.strip(CatalogRx.sub(#"\s+"#, " ", rest), " ,;:-.")
        return Abschluss(name: name, po: po, degree: degree)
    }

    /// "Technische Informatik (PO-Version 2017)" -> Name, PO, Abschlussart (`parse_abschluss`)
    public static func parseAbschluss(_ label: String) -> Abschluss {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let po = CatalogRx.search(#"PO[- ]?Version:?\s*([0-9]{4})"#, text, ignoreCase: true)?[1] ?? nil
        if let his = hisAbschluss(text, po: po) { return his }
        var name = CatalogRx.sub(#"\(\s*PO[- ]?Version[^)]*\)"#, " ", text, ignoreCase: true)
        name = CatalogRx.sub(#"PO[- ]?Version:?\s*[0-9]{4}"#, " ", name, ignoreCase: true)
        name = CatalogRx.sub(#"^Abschluss:\s*"#, "", name, ignoreCase: true)
        var degree: String?
        for (rx, d) in degreeHints where CatalogRx.search(rx, name, ignoreCase: true) != nil {
            degree = d
            name = CatalogRx.sub(rx, " ", name, ignoreCase: true)
            break
        }
        name = StudyCatalogText.strip(CatalogRx.sub(#"\s+"#, " ", name), " ,;:-")
        return Abschluss(name: name, po: po, degree: degree)
    }

    static func degreeClass(_ degree: String?) -> String { (degree ?? "").uppercased().hasPrefix("M") ? "M" : "B" }

    var universities: [JSONValue] { json["universities"]?.array ?? [] }

    func university(_ id: String) -> JSONValue? { universities.first { $0["id"]?.string == id } }

    static func text(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s)?: return s
        case .number(let n)?: return n == n.rounded() ? String(Int(n)) : String(n)
        default: return ""
        }
    }

    static func newestPO(_ program: JSONValue) -> JSONValue? {
        var best: JSONValue?
        for p in program["pos"]?.array ?? [] {
            guard let b = best else { best = p; continue }
            let a = (text(p["po"]), text(p["code"])), c = (text(b["po"]), text(b["code"]))
            if a > c { best = p }
        }
        return best
    }

    /// QIS `abschluss` (und optional bestaetigte PO bzw. Kuerzel) -> Vorschlag, nil ohne passenden Eintrag
    public func match(label: String, university: String = "luh", po: String? = nil) -> Match? {
        let parsed = Self.parseAbschluss(label)
        let key = StudyCatalogText.nameKey(parsed.name)
        guard !key.isEmpty, let uni = self.university(university) else { return nil }
        var cands = (uni["programs"]?.array ?? []).filter { p in
            let names = [Self.text(p["program"])] + (p["qis_names"]?.array ?? []).map { Self.text($0) }
            return Set(names.map(StudyCatalogText.nameKey)).contains(key)
        }
        if let d = parsed.degree { cands = cands.filter { Self.degreeClass($0["degree"]?.string) == d } }
        guard !cands.isEmpty else { return nil }
        // Bachelor zuerst, sonst Reihenfolge des Registers (stabil)
        let prog = cands.enumerated().sorted { (Self.degreeClass($0.element["degree"]?.string), $0.offset) < (Self.degreeClass($1.element["degree"]?.string), $1.offset) }[0].element
        let pos = prog["pos"]?.array ?? []
        var chosen: JSONValue?
        var confirmed = false
        if let po, !po.isEmpty {
            chosen = pos.first { Self.text($0["po"]) == po || Self.text($0["code"]) == po }
            confirmed = chosen != nil
        }
        if chosen == nil, let q = parsed.po {
            chosen = pos.first { Self.text($0["po"]) == q }
            confirmed = chosen != nil
        }
        if chosen == nil { chosen = Self.newestPO(prog) }
        guard let c = chosen, let code = c["code"]?.string else { return nil }
        return Match(university: university, programID: prog["id"]?.string, program: prog["program"]?.string, degree: prog["degree"]?.string,
                     po: Self.text(c["po"]), code: code, qisLabel: label, qisPO: parsed.po, needsConfirmation: !confirmed)
    }

    /// Eintrag zu einem Kuerzel ohne QIS-Bezeichnung (bestaetigte PO "TIBSc22")
    public func match(code: String, university: String = "luh", qisLabel: String? = nil) -> Match? {
        guard let (_, prog, po) = entry(university: university, code: code) else { return nil }
        return Match(university: university, programID: prog["id"]?.string, program: prog["program"]?.string, degree: prog["degree"]?.string,
                     po: Self.text(po["po"]), code: code, qisLabel: qisLabel, qisPO: nil, needsConfirmation: false)
    }

    /// (Hochschule, Studiengang, PO) zum Kuerzel
    public func entry(university: String, code: String) -> (JSONValue, JSONValue, JSONValue)? {
        guard let uni = self.university(university) else { return nil }
        for prog in uni["programs"]?.array ?? [] {
            for po in prog["pos"]?.array ?? [] where po["code"]?.string == code { return (uni, prog, po) }
        }
        return nil
    }

    func source(_ uni: JSONValue, _ po: JSONValue) -> JSONValue? {
        (uni["sources"]?.array ?? []).first { $0["id"]?.string == po["source"]?.string }
    }

    /// URL des Katalogs und der Spiegel, in dieser Reihenfolge
    public func sourceURLs(university: String, code: String, term: String) -> [String] {
        guard let (uni, _, po) = entry(university: university, code: code), let src = source(uni, po) else { return [] }
        let patterns = [src["url_pattern"]] + (src["mirror_patterns"]?.array ?? []).map { Optional($0) }
        return patterns.compactMap { $0?.string }.filter { !$0.isEmpty }.map {
            $0.replacingOccurrences(of: "{code}", with: code).replacingOccurrences(of: "{term}", with: StudyCatalogText.termSlug(term))
        }
    }

    /// Quelle des Studienverlaufsplans zum Kuerzel (nur https und bekanntes Format), wie `study_plan_source`
    public func studyPlanURL(university: String, code: String) -> String? {
        guard let (_, _, po) = entry(university: university, code: code), let sp = po["study_plan"],
              sp["format"]?.string == StudyPlanSheet.format, let url = sp["url"]?.string, url.hasPrefix("https://") else { return nil }
        return url
    }

    /// Katalogsemester zum Versuchen: das laufende (wenn neuer als alle bekannten und erlaubt), dann die bekannten
    public func candidateTerms(university: String, code: String, today: String) -> [String] {
        guard let (uni, _, po) = entry(university: university, code: code) else { return [] }
        var seen = Set<String>()
        let known = (po["catalog_terms"]?.array ?? []).compactMap(\.string)
            .filter { StudyCatalogText.termNumber($0) != nil && seen.insert($0).inserted }
            .sorted { StudyCatalogText.termNumber($0)! > StudyCatalogText.termNumber($1)! }
        let cur = StudyCatalogText.currentTerm(today: today)
        if source(uni, po)?["probe_current_term"]?.bool == true,
           known.isEmpty || StudyCatalogText.termNumber(cur)! > StudyCatalogText.termNumber(known[0])! {
            return [cur] + known
        }
        return known
    }

    /// Angaben des Studiengangs fuer den Parser (Kopf des Katalogs)
    public func meta(university: String, code: String, term: String) -> StudyCatalogMeta? {
        guard let (_, prog, po) = entry(university: university, code: code) else { return nil }
        return StudyCatalogMeta(university: university, program: prog["program"]?.string ?? "", degree: prog["degree"]?.string ?? "",
                                po: Self.text(po["po"]), code: code, catalogTerm: term, regularSemesters: prog["regular_semesters"]?.int,
                                totalLP: prog["total_lp"]?.double)
    }
}
