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
            guard !(p["pos"]?.array ?? []).isEmpty else { return false }       // Nebenfaecher ohne Katalog ordnen nichts zu
            let names = [Self.text(p["program"])] + (p["qis_names"]?.array ?? []).map { Self.text($0) } + Self.lsfKeys(p)
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

    /// `lsf_keys`: LSF-Schreibweisen eines Studiengangs fuer die Zuordnung, ganz und ohne Abschluss vorn; nur genaue Treffer
    static func lsfKeys(_ p: JSONValue) -> [String] {
        var out: [String] = []
        for n in (p["lsf_names"]?.array ?? []).compactMap(\.string) {
            out.append(n)
            if let d = CatalogRx.match(#"^\s*([BM])\s?\.?\s?(?:A|Sc|Ed|Eng|Mus)\b\.?"#, n, ignoreCase: true), let whole = d[0] {
                out.append(String(n.dropFirst(whole.count)))
            }
        }
        return out
    }

    /// Eintrag zu einem Kuerzel ohne QIS-Bezeichnung (bestaetigte PO "TIBSc22")
    public func match(code: String, university: String = "luh", qisLabel: String? = nil) -> Match? {
        guard let (_, prog, po) = entry(university: university, code: code) else { return nil }
        return Match(university: university, programID: prog["id"]?.string, program: prog["program"]?.string, degree: prog["degree"]?.string,
                     po: Self.text(po["po"]), code: code, qisLabel: qisLabel, qisPO: nil, needsConfirmation: false)
    }

    /// Suche "Was studierst du?" wie `study_catalog.program_matches`: jedes Wort der Anfrage steckt in einem Wort von
    /// Name, Abschluss oder Fachbereich; Abschlusskuerzel zaehlen nicht; Kurzformen der Uni-Seiten ueber Wortfolgen im Namen
    static let searchAliases: [(String, [String])] = [
        ("informationsmanagement und informationstechnologie", ["imit"]),
        ("internationales informationsmanagement", ["iim"]),
        ("deutsch als zweitsprache", ["daz", "daf"]),
        ("haupt und realschulen", ["hrs"]),
        ("grund haupt und realschulen", ["ghr"]),
        ("internationale kommunikation und uebersetzen", ["ikue", "iku"]),
        ("polyvalenter zwei faecher bachelor", ["2fb", "zweifach"]),
    ]
    static let degreeWords: Set<String> = ["a", "b", "m", "sc", "ed", "ba", "bsc", "ma", "msc", "med"]

    public static func searchWords(_ text: String) -> [String] { StudyCatalogText.tokens(StudyCatalogText.fold(text)) }

    /// Passt ein Eintrag aus `programs` (bzw. `GET /api/study-catalog/programs`) zur Suche?
    /// Suche ueber die Liste wie `study_catalog.filter_programs`: zuerst Name, Abschluss, LSF-Schreibweisen; nur ohne
    /// Treffer auch die Fakultaet
    public static func filterPrograms<T>(_ items: [T], query: String, json: (T) -> JSONValue) -> [T] {
        let hits = items.filter { programMatches(json($0), query: query) }
        return hits.isEmpty ? items.filter { programMatches(json($0), query: query, faculty: true) } : hits
    }

    public static func filterPrograms(_ items: [JSONValue], query: String) -> [JSONValue] {
        filterPrograms(items, query: query) { $0 }
    }

    public static func programMatches(_ p: JSONValue, query: String, faculty: Bool = false) -> Bool {
        let words = searchWords(query).filter { !degreeWords.contains($0) }
        guard !words.isEmpty else { return true }
        let name = searchWords(p["program"]?.string ?? "").joined(separator: " ")
        let lsf = (p["lsf_names"]?.array ?? []).compactMap(\.string).joined(separator: " ")
        let fac = faculty ? p["faculty"]?.string ?? "" : ""
        var hay = searchWords("\(p["program"]?.string ?? "") \(p["degree"]?.string ?? "") \(fac) \(lsf)")
        for (phrase, short) in searchAliases where name.contains(phrase) { hay += short }
        return words.allSatisfy { w in hay.contains { $0.contains(w) } }
    }

    /// `programs`: Studiengaenge des Registers zur Auswahl ([{id, program, degree, faculty, regular_semesters, total_lp,
    /// pos: [{po, code, catalog_terms, loadable}]}] nach Name); Eintraege ohne Katalog haben `pos: []`. `loadable`: der
    /// Katalog laesst sich laden (Muster der Quelle) oder liegt im Grundstock (`seedCodes`).
    public func programs(university: String, seedCodes: Set<String> = []) -> [JSONValue] {
        guard let uni = self.university(university) else { return [] }
        var out: [(key: String, degree: String, value: JSONValue)] = []
        for p in uni["programs"]?.array ?? [] {
            var pos: [JSONValue] = []
            for x in p["pos"]?.array ?? [] {
                let src = source(uni, x)
                let code = x["code"]?.string
                let pattern = src?["url_pattern"]?.string ?? ""
                pos.append(.object(["po": .string(Self.text(x["po"])), "code": code.map { .string($0) } ?? .null,
                                    "catalog_terms": .array(x["catalog_terms"]?.array ?? []),
                                    "loadable": .bool(!pattern.isEmpty || code.map { seedCodes.contains($0) } ?? false)]))
            }
            let program = p["program"]?.string ?? ""
            var item: [String: JSONValue] = ["id": p["id"] ?? .null, "program": p["program"] ?? .null, "degree": p["degree"] ?? .null,
                                             "faculty": p["faculty"] ?? .null, "regular_semesters": p["regular_semesters"] ?? .null,
                                             "total_lp": p["total_lp"] ?? .null, "pos": .array(pos)]
            if let k = p["kind"]?.string, !k.isEmpty { item["kind"] = .string(k) }
            if let n = p["lsf_names"]?.array, !n.isEmpty { item["lsf_names"] = .array(n) }
            out.append((StudyCatalogText.nameKey(program), p["degree"]?.string ?? "", .object(item)))
        }
        return out.sorted { a, b in
            a.key != b.key ? PyText.less(a.key, b.key) : PyText.less(a.degree, b.degree)
        }.map(\.value)
    }

    /// `code_for_catalog_url`: Kuerzel des Registers, dessen Katalog unter diesem Link liegt (eingefuegter Link zu einem
    /// bekannten Katalog kommt aus dem Grundstock, 14.11.2026)
    public func code(forCatalogURL url: String?, university: String) -> String? {
        let want = (url ?? "").trimmingCharacters(in: .whitespaces)
        guard !want.isEmpty, let uni = self.university(university) else { return nil }
        for p in uni["programs"]?.array ?? [] {
            for po in p["pos"]?.array ?? [] where po["url"]?.string == want { if let c = po["code"]?.string { return c } }
        }
        return nil
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
