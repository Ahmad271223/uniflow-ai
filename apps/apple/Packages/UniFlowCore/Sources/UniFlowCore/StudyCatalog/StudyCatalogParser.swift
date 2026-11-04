import Foundation

/// Angaben des Studiengangs fuer den Kopf des Katalogs (aus dem Register) und die Quelle
public struct StudyCatalogMeta: Equatable, Sendable {
    public var university: String
    public var program: String
    public var degree: String
    public var po: String
    public var code: String
    public var catalogTerm: String
    public var regularSemesters: Int?
    public var totalLP: Double?
    public var sourceURL: String?
    public var fetchedAt: String?
    public var sha256: String?

    public init(university: String, program: String, degree: String, po: String, code: String, catalogTerm: String,
                regularSemesters: Int? = nil, totalLP: Double? = nil, sourceURL: String? = nil, fetchedAt: String? = nil, sha256: String? = nil) {
        self.university = university
        self.program = program
        self.degree = degree
        self.po = po
        self.code = code
        self.catalogTerm = catalogTerm
        self.regularSemesters = regularSemesters
        self.totalLP = totalLP
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
        self.sha256 = sha256
    }
}

/// Ergebnis des Parsers: Katalog im geteilten Format (Schluessel in fester Reihenfolge wie Python) und die lokalen
/// Modultexte {modul_id: {content, goals, literature}}
public struct ParsedStudyCatalog: Sendable {
    public var catalog: PyJSON
    public var texts: PyJSON

    /// Kanonischer Text wie `json.dumps(..., ensure_ascii=False)` (Fixture expected.json, Feld dumps)
    public var catalogDumps: String { catalog.dumps(ensureASCII: false) }
    public var textsDumps: String { texts.dumps(ensureASCII: false) }
    public var moduleCount: Int { catalog.json["modules"]?.array?.count ?? 0 }
}

/// Parser fuer das Format der LUH-Modulkataloge (modkat, FEI) wie `parse_luh_modkat` in app/study_catalog.py:
/// Inhaltsverzeichnis -> Bereiche und Module mit Seite, je Modul die Felder unter ihren Ueberschriften. Jede Regel
/// und Reihenfolge gleich, damit beide auf der Fixture dasselbe JSON liefern (StudyCatalogParserTests).
public enum StudyCatalogParser {
    static let maxText = 500

    static let factLabels: [String: String] = [
        "Sprache": "language", "Modultitel englisch": "title_en", "Kompetenzbereich": "area_name", "Modultyp": "kind",
        "Prüfungsform": "exam", "Prüfungsbewertung": "grading", "Studienleistung": "coursework",
        "Empfohlenes Fachsemester": "semester", "Studentische Arbeitsleistung": "workload",
        "Frequenz der Lehrveranstaltung": "frequency", "Frequenz": "frequency", "Schwerpunkt / Micro-Degree": "focus",
        "Bei Seminar: Semesterthema (dt/en)": "seminar", "Organisationseinheit": "org", "Modulverantwortung": "responsible",
        "Organisationseinheit Modulverantwortung": "org", "Webseite": "website",
        // neuere Form (modkat-full, ab WS 2026/27)
        "LP (ECTS)": "lp", "SWS": "sws_only", "regelhaftes Lehrangebot": "frequency", "Gewählte Prüfungsform": "exam",
        "Prüfungsbewertungen": "grading", "Zuständigkeit": "unit", "Einordnung und Belegungsmöglichkeit in Studiengänge": "placement",
        "Dozent/in": "lecturer", "Prüfer/in": "examiner", "Prüfungsanmeldung": "registration",
        "Schwerpunkt / Micro-Degree Bei Seminar: Semesterthema (dt/en)": "focus",
    ]
    static let textLabels: [String: String] = [
        "Qualifikationsziele": "goals", "Inhalt": "content", "Inhalt und Stoffplan": "content",
        "Teilnahmevoraussetzungen und -empfehlungen": "prereq",
        "Literatur": "literature", "Weitere Angaben": "notes",
    ]
    static let textOrder = ["goals", "content", "prereq", "literature", "notes"]
    static let prefixLabels: [(String, String)] = [("Angebot im ", "offer"), ("SWS LP", "sws")]
    static let suffixLabels = ["Sprache"]

    static let footerRx = "^[0-9]+ / [0-9]+$"
    static let headerRx = #"^Modulkatalog .+? \((?:Wintersemester|Sommersemester) [0-9]{4}(?:/[0-9]{4})?\) ?"#
    static let standRx = #"^Stand: [0-9]{2}\.[0-9]{2}\.[0-9]{4} ?"#
    static let tocRx = #"^(.*?) ?(?:\. ?){4,}([0-9]+)$"#
    static let tableHeadRx = #"^Modul LP SWS\b"#
    static let placementRx = "^(.+?) - "
    static let sectionRx = #"^([0-9]+(?:\.[0-9]+)*)\. (.+)$"#
    static let areaInfoRx = "^Information zum Kompetenzbereich: ?(.*)$"
    static let lpRangeRx = #"([0-9]+(?:[.,][0-9]+)?)(?: ?- ?([0-9]+(?:[.,][0-9]+)?))? ?LP"#
    static let lpRx = #"([0-9]+(?:[.,][0-9]+)?) ?LP\b"#
    static let workloadRx = #"(?:Gesamt:? ?)?([0-9]+) ?(?:h\b|Stunden)"#
    static let semesterRx = #"([0-9]+)\. ?Fachsemester"#
    static let semesterHintRx = #"Empfohlen (?:für|ab) (?:das|dem) ([0-9]+)\."#
    static let klausurRx = #"^Klausur(?: \(K\))?(?:,? \(?([0-9]+) ?min\)?| \( ?min\))?$"#
    static let courseworkRx = #"^([0-9]+), ?([^:]*?) ?(?::.*)?$"#
    static let finalRx = "bachelorarbeit|masterarbeit|abschlussarbeit"

    // MARK: Zeilen

    /// Normalisierte Zeilen je Seite ohne Kopf- und Fusszeile (`clean_pages`)
    public static func cleanPages(_ pages: [String]) -> [[String]] {
        pages.map { text in
            StudyCatalogText.normalizeLines(text).compactMap { line -> String? in
                if CatalogRx.matches(footerRx, line) { return nil }
                var rest = CatalogRx.match(headerRx, line) != nil ? CatalogRx.sub(headerRx, "", line) : line
                if CatalogRx.match(standRx, rest) != nil { rest = CatalogRx.sub(standRx, "", rest) }
                rest = StudyCatalogText.strip(rest)
                return rest.isEmpty ? nil : rest
            }
        }
    }

    struct TocEntry {
        var isArea: Bool
        var title: String
        var page: Int
        var number: String = ""
    }

    /// Eintraege des Inhaltsverzeichnisses (`_toc`): ab der ersten Seite mit drei Eintraegen bis vor die erste Seite
    /// ohne Eintrag; mehrere Nummern vor einem Titel ("1. 2. Kompetenzbereiche", so setzt PDFKit die Nummernspalte
    /// zusammen): die erste gehoert zum Titel, die weiteren der Reihe nach zu den naechsten Eintraegen ohne Nummer
    static func toc(_ pages: [[String]]) -> [TocEntry] {
        var out: [TocEntry] = []
        var started = false
        var displaced: [String] = []
        for lines in pages {
            let hits = lines.filter { CatalogRx.matches(tocRx, $0) }.count
            if hits < (started ? 1 : 3) {
                if started { break }
                continue
            }
            started = true
            var pending = ""
            for l in lines {
                guard let m = CatalogRx.match(tocRx, l) else {
                    pending = StudyCatalogText.strip(pending + " " + l)
                    continue
                }
                let title = StudyCatalogText.strip(pending + " " + (m[1] ?? ""))
                pending = ""
                let page = Int(m[2] ?? "") ?? 0
                if let s = CatalogRx.match(sectionRx, title) {
                    var rest = s[2] ?? ""
                    while let more = CatalogRx.match(sectionRx, rest), let n = more[1] ?? nil, !n.contains(".") {
                        displaced.append(n)
                        rest = more[2] ?? ""
                    }
                    out.append(TocEntry(isArea: true, title: rest, page: page, number: s[1] ?? ""))
                } else if !displaced.isEmpty {
                    out.append(TocEntry(isArea: true, title: title, page: page, number: displaced.removeFirst()))
                } else {
                    out.append(TocEntry(isArea: false, title: title, page: page))
                }
            }
        }
        return out
    }

    static func label(_ line: String) -> (String, String?)? {
        if let k = factLabels[line] { return (k, nil) }
        if let k = textLabels[line] { return (k, nil) }
        for (prefix, key) in prefixLabels where line.hasPrefix(prefix) {
            return (key, StudyCatalogText.strip(String(line.dropFirst(prefix.count))))
        }
        return nil
    }

    /// Felder eines Moduls (`_module_fields`): Kopf, dann Feld -> Zeilen; Texte nur in fester Reihenfolge
    static func moduleFields(_ lines: [String], title: String) -> [String: [String]] {
        var fields: [String: [String]] = ["_head": []]
        var current = "_head"
        var inText = -1
        for line in lines {
            var found = label(line)
            if found == nil && current == "_head" {
                for suf in suffixLabels where line.hasSuffix(" " + suf) {
                    let head = String(line.dropLast(suf.count + 1))
                    if title.hasPrefix(head) {
                        fields["_head", default: []].append(head)
                        found = (factLabels[suf]!, nil)
                        break
                    }
                }
                if let (key, _) = found {
                    current = key
                    if fields[current] == nil { fields[current] = [] }
                    continue
                }
            }
            if let (key, _) = found {
                if let pos = textOrder.firstIndex(of: key) {
                    if pos <= inText { found = nil } else { inText = pos }
                } else if inText >= 0 || fields[key] != nil {
                    found = nil
                }
            }
            guard let (key, inline) = found else {
                fields[current, default: []].append(line)
                continue
            }
            current = key
            if fields[current] == nil { fields[current] = [] }
            if let inline, !inline.isEmpty { fields["_" + key, default: []].append(inline) }
        }
        return fields
    }

    static func join(_ lines: [String]?, _ sep: String = " ") -> String {
        StudyCatalogText.strip((lines ?? []).joined(separator: sep))
    }

    static func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    static func exam(_ value: String) -> String? {
        let s = StudyCatalogText.strip(CatalogRx.sub(" +,", ",", value))
        if s.isEmpty || ["keine", "-"].contains(s.lowercased()) { return nil }
        if let m = CatalogRx.match(klausurRx, s) {
            if let n = m[1] ?? nil { return "Klausur \(n) min" }
            return "Klausur"
        }
        return StudyCatalogText.prefix(s, maxText)
    }

    static func coursework(_ value: String) -> String? {
        let s = StudyCatalogText.strip(value)
        if s.isEmpty || ["keine", "-", "nein"].contains(s.lowercased()) { return nil }
        if let m = CatalogRx.match(courseworkRx, s), let n = Int(m[1] ?? "") {
            if n == 0 { return nil }
            let term = StudyCatalogText.strip(m[2] ?? "", " ,")
            let word = n == 1 ? "Studienleistung" : "Studienleistungen"
            return "\(n) \(word)" + (term.isEmpty ? "" : " (\(term))")
        }
        return StudyCatalogText.prefix(s, maxText)
    }

    static func turnus(frequency: String, offer: String, hasOffer: Bool, season: String) -> String {
        let f = frequency.lowercased()
        if f.contains("jedes semester") { return "WS+SS" }
        if f.contains("winter") { return "WS" }
        if f.contains("sommer") { return "SS" }
        if f.hasPrefix("jährlich") && hasOffer {
            let o = offer.lowercased()
            if o.contains("vorlesung") || o.contains("lehrveranstaltung") { return season }
            if o.contains("nur prüfung") { return season == "WS" ? "SS" : "WS" }
        }
        return "unbekannt"
    }

    static func kind(_ value: String) -> String? {
        let v = value.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        return ["pflicht": "pflicht", "p": "pflicht", "wahlpflicht": "wahlpflicht", "wp": "wahlpflicht", "wahl": "wahl", "w": "wahl"][v]
    }

    static func isWordChar(_ u: Unicode.Scalar) -> Bool { u.properties.isAlphabetic || u.properties.numericType != nil }

    /// Nennt der Text den Titel als ganzes Wort? (`_mentions`, Positionen in Codepunkten wie Python)
    static func mentions(_ text: String, _ title: String) -> Bool {
        let hay = Array(text.lowercased().unicodeScalars), needle = Array(title.lowercased().unicodeScalars)
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        var i = 0
        while i + needle.count <= hay.count {
            if Array(hay[i..<(i + needle.count)]) == needle {
                let beforeOK = i == 0 || !isWordChar(hay[i - 1])
                let j = i + needle.count
                let afterOK = j >= hay.count || !isWordChar(hay[j])
                if beforeOK && afterOK { return true }
            }
            i += 1
        }
        return false
    }

    static func unique(_ base: String, _ seen: inout Set<String>) -> String {
        var out = base, n = 2
        while seen.contains(out) {
            out = "\(base)-\(n)"
            n += 1
        }
        seen.insert(out)
        return out
    }

    static func num(_ d: Double?) -> PyJSON {
        guard let d else { return .null }
        if d == d.rounded(), abs(d) < 1e15 { return .int(String(Int(d))) }
        return .float(d)
    }

    static func str(_ s: String?) -> PyJSON { s.map { .string($0) } ?? .null }

    struct Area {
        var id: String
        var name: String
        var lpRequired: Double?
        var lpMax: Double?
        var kind: String
    }

    struct Module {
        var id: String
        var title: String
        var area: String?
        var kind: String?
        var lp: Double?
        var semester: Int?
        var turnus: String
        var exam: String?
        var coursework: String?
        var prerequisites: [String] = []
        var language: String?
        var workload: Int?
        var page: Int
        var prereqText: String
        var content: String?
        var goals: String?
        var literature: String?
    }

    /// Seitentexte eines LUH-Modulkatalogs -> Katalog und lokale Modultexte
    public static func parse(pages: [String], meta: StudyCatalogMeta) -> ParsedStudyCatalog {
        let clean = cleanPages(pages)
        var term = meta.catalogTerm
        if term.isEmpty, let first = clean.first { term = StudyCatalogText.termFromTitle(first.joined(separator: " ")) ?? "" }
        let season = term.hasPrefix("SS") ? "SS" : "WS"
        let entries = toc(clean)
        let n = clean.count
        let starts = Array(Set(entries.map(\.page))).sorted()

        func block(_ page: Int) -> [String] {
            let next = starts.first { $0 > page } ?? (n + 1)
            var out: [String] = []
            for p in page..<max(page + 1, next) where p >= 1 && p <= n { out += clean[p - 1] }
            return out
        }

        func areaInfo(_ e: TocEntry) -> [String?]? {
            guard e.page >= 1 && e.page <= n else { return nil }
            return clean[e.page - 1].lazy.compactMap({ CatalogRx.match(areaInfoRx, $0) }).first
        }
        // Kapitel ("1." mit "1.1." darunter) und Abschnitte ohne Bereichsangabe sind keine Bereiche, sobald irgendein
        // Abschnitt eine Bereichsangabe hat
        let numbers = entries.filter(\.isArea).map(\.number)
        let chapters = Set(numbers.filter { n in numbers.contains { $0.hasPrefix(n + ".") } })
        let anyInfo = entries.contains { $0.isArea && !chapters.contains($0.number) && areaInfo($0) != nil }

        var areas: [Area] = []
        var areaIDs = Set<String>()
        var areaPages: [Int] = []
        var modules: [Module] = []
        var moduleIDs = Set<String>()
        var currentArea: Area?
        var raw: [(TocEntry, Area?, [String: [String]])] = []
        for e in entries {
            if e.isArea {
                let info = areaInfo(e)
                if chapters.contains(e.number) || (anyInfo && info == nil) {
                    currentArea = nil
                    continue
                }
                var lpReq: Double?, lpMax: Double?
                var kind = "pflicht"
                if let info {
                    let text = info[1] ?? ""
                    if let m = CatalogRx.search(lpRangeRx, text) {
                        lpReq = number(m[1] ?? "0")
                        lpMax = (m[2] ?? nil).map(number)
                    }
                    let tail = text.contains(",") ? String(text[text.range(of: ",", options: .backwards)!.upperBound...]) : ""
                    kind = self.kind(StudyCatalogText.strip(tail)) ?? "pflicht"
                }
                if CatalogRx.search(finalRx, e.title, ignoreCase: true) != nil { kind = "abschluss" }
                let a = Area(id: unique(StudyCatalogText.slug(e.title), &areaIDs), name: e.title, lpRequired: lpReq, lpMax: lpMax, kind: kind)
                areas.append(a)
                areaPages.append(e.page)
                currentArea = a
                continue
            }
            raw.append((e, currentArea, moduleFields(block(e.page), title: e.title)))
        }

        // neuere Form: Bereich aus der Tabelle "Modul LP SWS ..." der Bereichsseiten (Titel, dahinter die LP-Zahl)
        let tables = areaPages.map { StudyPlanSheet.join(block($0)) }
        if areaPages.contains(where: { p in block(p).contains { CatalogRx.matches(tableHeadRx, $0) } }) {
            for k in raw.indices where raw[k].1 == nil {
                let rx = "(?:^| )" + NSRegularExpression.escapedPattern(for: raw[k].0.title) + " [0-9]"
                raw[k].1 = tables.firstIndex { CatalogRx.search(rx, $0) != nil }.map { areas[$0] }
            }
            // sonst ueber das Kuerzel der Einordnung ("TIBSc25 - GI - Programmieren I"), das andere Module desselben
            // Bereichs schon zeigen (PDFKit setzt umbrochene Tabellenzeilen manchmal auseinander)
            func abbr(_ f: [String: [String]]) -> String? {
                for line in f["placement"] ?? [] where !meta.code.isEmpty && line.hasPrefix(meta.code + " - ") {
                    return CatalogRx.match(placementRx, String(line.dropFirst(meta.code.count + 3))).flatMap { $0[1] ?? nil }
                }
                return nil
            }
            var byAbbr: [String: Area] = [:]
            for r in raw { if let a = abbr(r.2), let area = r.1, byAbbr[a] == nil { byAbbr[a] = area } }
            for k in raw.indices where raw[k].1 == nil {
                if let a = abbr(raw[k].2), let area = byAbbr[a] { raw[k].1 = area }
            }
        }

        for (e, area, f) in raw {
            let id = unique(StudyCatalogText.slug(e.title), &moduleIDs)
            let lp = (CatalogRx.search(lpRx, join(f["sws"])) ?? CatalogRx.search(lpRx, join(f["lp"]))).map { number($0[1] ?? "0") }
            var semester = CatalogRx.search(semesterRx, join(f["semester"])).flatMap { Int($0[1] ?? "") }
            if semester == nil {
                semester = CatalogRx.search(semesterHintRx, join(f["prereq"]) + " " + join(f["notes"])).flatMap { Int($0[1] ?? "") }
            }
            if let s = semester, !(1...20).contains(s) { semester = nil }
            let workload = CatalogRx.search(workloadRx, join(f["workload"])).flatMap { Int($0[1] ?? "") }
            let language = join(Array((f["language"] ?? []).prefix(1))).lowercased()
            func text(_ k: String) -> String? { let s = join(f[k], "\n"); return s.isEmpty ? nil : s }
            modules.append(Module(
                id: id, title: e.title, area: area?.id, kind: kind(join(Array((f["kind"] ?? []).prefix(1)))), lp: lp, semester: semester,
                turnus: turnus(frequency: join(f["frequency"]), offer: join(f["offer"]), hasOffer: f["offer"] != nil, season: season),
                exam: exam(join(f["exam"])), coursework: coursework(join(f["coursework"])),
                language: language.isEmpty ? nil : StudyCatalogText.prefix(language, maxText), workload: workload, page: e.page,
                prereqText: join(f["prereq"]), content: text("content"), goals: text("goals"), literature: text("literature")))
        }

        // Art aus dem Bereich, wenn der Katalog keine nennt (ausdrueckliche Wahl(pflicht) im Bereich: Rest = Kern)
        for a in areas {
            let idx = modules.indices.filter { modules[$0].area == a.id }
            let total = idx.reduce(0.0) { $0 + (modules[$1].lp ?? 0) }
            let explicitChoice = idx.contains { ["wahlpflicht", "wahl"].contains(modules[$0].kind ?? "") }
            for i in idx {
                if a.kind == "abschluss" {
                    modules[i].kind = "abschluss"
                } else if modules[i].kind == nil {
                    if a.kind == "wahl" {
                        modules[i].kind = "wahl"
                    } else if explicitChoice {
                        modules[i].kind = "pflicht"
                    } else if a.lpMax != nil || (a.lpRequired.map { total > $0 } ?? false) {
                        modules[i].kind = "wahlpflicht"
                    } else {
                        modules[i].kind = "pflicht"
                    }
                }
            }
        }
        for i in modules.indices where modules[i].kind == nil { modules[i].kind = "pflicht" }
        for i in modules.indices {
            modules[i].prerequisites = modules.filter { $0.id != modules[i].id && mentions(modules[i].prereqText, $0.title) }.map(\.id)
        }

        let areaJSON: [PyJSON] = areas.map {
            .object([.init("id", .string($0.id)), .init("name", .string($0.name)), .init("lp_required", num($0.lpRequired)),
                     .init("lp_max", num($0.lpMax)), .init("kind", .string($0.kind))])
        }
        let moduleJSON: [PyJSON] = modules.map { m in
            .object([.init("id", .string(m.id)), .init("title", .string(m.title)), .init("code", .null), .init("area", str(m.area)),
                     .init("kind", .string(m.kind ?? "pflicht")), .init("lp", num(m.lp)), .init("semester", m.semester.map { .int(String($0)) } ?? .null),
                     .init("turnus", .string(m.turnus)), .init("exam", str(m.exam)), .init("coursework", str(m.coursework)),
                     .init("prerequisites", .array(m.prerequisites.map { .string($0) })), .init("language", str(m.language)),
                     .init("workload_h", m.workload.map { .int(String($0)) } ?? .null), .init("source_page", .int(String(m.page)))])
        }
        let catalog = PyJSON.object([
            .init("v", .int("1")), .init("university", .string(meta.university)), .init("program", .string(meta.program)),
            .init("degree", .string(meta.degree)), .init("po", .string(meta.po)), .init("catalog_term", .string(term)),
            .init("code", .string(meta.code)), .init("regular_semesters", meta.regularSemesters.map { .int(String($0)) } ?? .null),
            .init("total_lp", num(meta.totalLP)),
            .init("source", .object([.init("url", str(meta.sourceURL)), .init("fetched_at", str(meta.fetchedAt)), .init("sha256", str(meta.sha256))])),
            .init("areas", .array(areaJSON)), .init("modules", .array(moduleJSON)),
        ])
        let texts = PyJSON.object(modules.map { m in
            .init(m.id, .object([.init("content", str(m.content)), .init("goals", str(m.goals)), .init("literature", str(m.literature))]))
        })
        return ParsedStudyCatalog(catalog: catalog, texts: texts)
    }
}
