import Foundation

/// Zwei weitere Leser fuer Modulhandbuecher der Universitaet Hildesheim, deren Module als mehrspaltige Tabellen gesetzt
/// sind, wie app/study_catalog_hildesheim_layout.py, Regel fuer Regel gleich (Fixture
/// packages/shared-contracts/fixtures/study-catalog-hildesheim-layout, StudyCatalogHildesheimLayoutParserTests).
///
/// Eingabe sind Seitentexte im Layout-Modus: die Spalten einer Tabellenzeile stehen in einer Textzeile, getrennt durch
/// mindestens zwei Leerzeichen (am PC pypdf mit extraction_mode="layout"). `layoutLines` macht daraus je Zeile die
/// Zellen mit ihrer Spalte (Codepunkte ab Zeilenanfang).
///
/// `kuerzelFormat` ("hildesheim-kuerzel-modultabelle"): Studienordnungen des Fachs Informatik im Lehramt ab 2026.
/// Titelzeile "INF-B1: „Titel“" (steht auf jeder Folgeseite noch einmal), Tabellenkopf "Studiensemester | Dauer des
/// Moduls | Häufigkeit des Angebots | Status Modul" mit den Werten darunter, "Lehr-/Lernformen; Arbeitsaufwand" mit einer
/// Zeile je Teilmodul und den LP in der letzten Spalte (eine Zeile "s. RStO ...   13" nennt die LP des ganzen Moduls),
/// Pruefungsform aus der Spalte "Prüfungsformen". Pflicht oder Wahlpflicht: "Status Modul"; steht dort nur ein Verweis,
/// gilt die Anlage der Studienvarianten ("Pflichtmodule: INF-B1, ..." je Variante): Pflicht nur, wenn in JEDER Variante
/// Pflichtmodul, sonst Wahlpflicht.
///
/// `kennnummerFormat` ("hildesheim-kennnummer-tabelle"): Masterstudiengang Barrierefreie Kommunikation. Titelzeile
/// "BK 1 Titel", Kopf "Kennnummer | Workload | Credits | Studiensemester | Häufigkeit des Angebots | Dauer" mit den
/// Werten darunter, nummerierte Zeilen "1 Lehrveranstaltungen" bis "11 Sonstige Informationen"; Studien- und
/// Pruefungsleistung aus Zeile 6 bzw. 7. Alle Module Pflicht, die Masterarbeit `abschluss`.
///
/// Was nicht sicher lesbar ist, bleibt leer; `prerequisites` und `language` bleiben leer.
public enum StudyCatalogHildesheimLayoutParser {
    public static let kuerzelFormat = "hildesheim-kuerzel-modultabelle"
    public static let kennnummerFormat = "hildesheim-kennnummer-tabelle"
    static let maxText = 500
    /// Pruefungs- und Studienleistung im Grundstock hoechstens so lang
    static let maxFact = 200

    static let headerRx = #"^Verkündungsblatt der (?:Stiftung )?Universität Hildesheim ?[-–] ?Heft .*[-–] ?Seite ?[0-9]+ ?[-–]?$"#
    static let annexRx = "^Anlage ([0-9]+)[a-z]? ?: ?(.*)$"
    static let finalRx = "bachelorarbeit|masterarbeit|abschlussarbeit|^abschlussmodul"
    static let noneValues: Set<String> = ["", "-", "–", "keine", "keiner", "nein", "entfällt"]
    static let referenceRx = #"^(?:s\. |siehe )"#
    static let joinWords: Set<String> = ["und", "oder", "bzw", "bzw.", "sowie"]
    static let firstIntRx = "[0-9]{1,2}"
    static let numberRx = "^[0-9]{1,3}(?:,[0-9])?$"
    static let hoursRx = "^(?:[0-9]{1,4}|-)$"
    static let spaceBeforeRx = " ([),;.])"
    static let spaceAfterRx = #"\( "#

    // erstes Format
    static let code = "[A-Z][A-Za-z]{1,6}[-_][A-Za-z]{1,4}[0-9]{1,2}"
    static let kTitleRx = "^(" + code + ") ?: ?[„“”\"](.+?)[“”„\"](?: .*)?$"
    static let kCodeRx = "(?<![A-Za-z0-9_-])" + code + "(?![A-Za-z0-9])"
    static let kRequiredRx = "^Pflichtmodule ?: ?(.*)$"
    static let kElectiveRx = "^Wahlpflichtmodule ?:"
    static let kEndRx = "^Abkürzungen ?:"
    static let kReqRx = "^Voraussetzung(?:en)? für die$"
    static let kCourseworkRx = "^Studienleistung(?:en)?$"
    static let kExamMarkRx = "^T?MP$"
    static let kPartRx = #"^(TM ?[0-9]{1,2})\b"#
    /// Wertspalte, solange kein Tabellenkopf "Studiensemester | Dauer ..." sie nennt
    static let kValueCol = 30
    /// Zellen bis so viele Zeichen vor der Wertspalte gehoeren noch zur Feldnamen-Spalte
    static let kLabelGap = 4
    static let colTolerance = 2
    /// Abschnitte, die ueber den Kolumnentitel der Folgeseite weiterlaufen
    static let kKeep: Set<String> = ["content", "forms"]

    // zweites Format
    static let nTitleRx = "^([A-Z]{1,4}) ?([0-9]{1,2}) (.+)$"
    static let nHeadKey = "KennnummerWorkloadCredits"
    static let nWorkloadRx = "^([0-9]{2,4}) ?h$"
    static let nSemesterRx = #"^([1-9])\."#
    static let nRowRx = "^[0-9]{1,2}$"
    static let nRows: [(String, String)] = [
        ("Lehrveranstaltungen", "courses"), ("Lernergebnisse", "goals"), ("Inhalte", "content"), ("Lehrformen", "forms"),
        ("Teilnahmevoraussetzungen", "prereq"), ("Prüfungsformen", "exam"), ("Voraussetzungen für die Vergabe", "credit"),
        ("Verwendung des Moduls", "usage"), ("Stellenwert", "weight"), ("Modulbeauftragte", "lead"),
        ("Sonstige Informationen", "remarks"),
    ]
    static let nCourseworkRx = "^Studienleistung(?:en)? ?:?$"
    static let nExamRx = "^Prüfungsleistung(?:en)? ?:?$"
    static let nItemRx = #"^[0-9]{1,2}\.[0-9]"#
    static let nLabelIndent = 3
    static let nTitleBack = 2

    // MARK: Zeilen und Werte

    /// Zelle einer Layout-Zeile: Spalte (Codepunkte ab Zeilenanfang) und Text
    public struct Cell: Equatable, Sendable {
        public var col: Int
        public var text: String

        var json: PyJSON { .array([.int(String(col)), .string(text)]) }
    }

    /// Seitentexte im Layout-Modus -> je Seite die nichtleeren Zeilen als Zellen: NFKC, jeder Zeilenumbruch gleich,
    /// Tabulator zu Leerzeichen; eine Zelle endet an zwei oder mehr Leerzeichen. Der Seitenkopf des Verkuendungsblatts
    /// faellt weg (`layout_lines`).
    public static func layoutLines(_ pages: [String]) -> [[[Cell]]] {
        pages.map { text in
            var lines: [[Cell]] = []
            var cells: [Cell] = []
            var start = 0, index = 0, spaces = 0
            var cur = String.UnicodeScalarView()
            func flush() {
                if !cur.isEmpty { cells.append(Cell(col: start, text: String(cur))) }
                if !cells.isEmpty, !CatalogRx.matches(headerRx, cells.map(\.text).joined(separator: " ")) { lines.append(cells) }
                cells = []
                cur = String.UnicodeScalarView()
                start = 0
                index = 0
                spaces = 0
            }
            for u in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
                let v = u.value
                if StudyCatalogText.breaks.contains(v) { flush(); continue }
                if StudyCatalogText.drops.contains(v) { continue }
                defer { index += 1 }
                if v == 0x20 || v == 0x09 {
                    spaces += 1
                    continue
                }
                if !cur.isEmpty && spaces >= 2 {
                    cells.append(Cell(col: start, text: String(cur)))
                    cur = String.UnicodeScalarView()
                }
                if cur.isEmpty {
                    start = index
                } else if spaces == 1 {
                    cur.append(" ")
                }
                cur.append(u)
                spaces = 0
            }
            flush()
            return lines
        }
    }

    static func line(_ cells: [Cell]) -> String { cells.map(\.text).joined(separator: " ") }

    /// Zeilenstuecke -> ein Text; Silbentrennung am Zeilenende faellt weg ("Ausarbei-" + "tung"), "Haupt-" + "und" bleibt
    /// (`_join`)
    static func join(_ parts: [String]) -> String {
        var t = ""
        for p in parts where !p.isEmpty {
            let lower = p.unicodeScalars.first?.properties.isLowercase ?? false
            if t.hasSuffix("-") && lower && !joinWords.contains(p.components(separatedBy: " ").first ?? "") {
                t = String(t.dropLast()) + p
            } else {
                t = t.isEmpty ? p : t + " " + p
            }
        }
        let ns = t as NSString
        let closed = CatalogRx.regex(spaceBeforeRx).stringByReplacingMatches(in: t, range: NSRange(location: 0, length: ns.length), withTemplate: "$1")
        return CatalogRx.sub(spaceAfterRx, "(", closed)
    }

    /// Studien-/Pruefungsleistung: zusammengefuegt, "-", "keine", "--- entfällt ---" -> nil (`_fact`)
    static func fact(_ parts: [String]) -> String? {
        let s = join(parts)
        if noneValues.contains(StudyCatalogText.strip(s, " -–").lowercased()) { return nil }
        return StudyCatalogText.strip(s, " ;,")
    }

    /// Eintraege (je Eintrag die Zeilenstuecke) -> mit "; " verbunden, hoechstens `maxFact` Zeichen; ohne `references`
    /// faellt ein reiner Verweis ("s. RStO ...") weg (`_facts`)
    static func facts(_ items: [[String]], references: Bool = true) -> String? {
        let all = items.compactMap { fact($0) }.filter { !$0.isEmpty && (references || CatalogRx.match(referenceRx, $0) == nil) }
        return all.isEmpty ? nil : StudyCatalogHildesheimParser.clip(all.joined(separator: "; "), maxFact)
    }

    static func season(_ text: String) -> String { StudyCatalogHildesheimParser.season(text) }

    static func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    static func findAll(_ pattern: String, _ s: String) -> [String] {
        let ns = s as NSString
        return CatalogRx.regex(pattern).matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func catalog(_ meta: StudyCatalogMeta, areas: [PyJSON], modules: [PyJSON]) -> PyJSON {
        let str = StudyCatalogParser.str
        return .object([
            .init("v", .int("1")), .init("university", .string(meta.university)), .init("program", .string(meta.program)),
            .init("degree", .string(meta.degree)), .init("po", .string(meta.po)), .init("catalog_term", .string(meta.catalogTerm)),
            .init("code", .string(meta.code)), .init("regular_semesters", meta.regularSemesters.map { .int(String($0)) } ?? .null),
            .init("total_lp", StudyCatalogParser.num(meta.totalLP)),
            .init("source", .object([.init("url", str(meta.sourceURL)), .init("fetched_at", str(meta.fetchedAt)), .init("sha256", str(meta.sha256))])),
            .init("areas", .array(areas)), .init("modules", .array(modules)),
        ])
    }

    // swiftlint:disable:next function_parameter_count
    static func module(id: String, title: String, code: String, area: String?, kind: String, lp: Double?, semester: Int?, turnus: String,
                       exam: String?, coursework: String?, workload: Int?, page: Int) -> PyJSON {
        let str = StudyCatalogParser.str
        return .object([
            .init("id", .string(id)), .init("title", .string(StudyCatalogText.prefix(title, maxText))), .init("code", .string(code)),
            .init("area", str(area)), .init("kind", .string(kind)), .init("lp", StudyCatalogParser.num(lp)),
            .init("semester", semester.map { .int(String($0)) } ?? .null), .init("turnus", .string(turnus)), .init("exam", str(exam)),
            .init("coursework", str(coursework)), .init("prerequisites", .array([])), .init("language", .null),
            .init("workload_h", workload.map { .int(String($0)) } ?? .null), .init("source_page", .int(String(page))),
        ])
    }

    static func moduleTexts(content: [String], goals: [String]) -> PyJSON {
        let str = StudyCatalogParser.str
        return .object([.init("content", str(content.isEmpty ? nil : content.joined(separator: "\n"))),
                        .init("goals", str(goals.isEmpty ? nil : goals.joined(separator: "\n"))), .init("literature", .null)])
    }

    // MARK: hildesheim-kuerzel-modultabelle

    struct KuerzelRaw {
        var code: String
        var title: String
        var page: Int
        var semester: Int?
        var freq: String?
        var status: String?
        /// je Teilmodul [Kontaktzeit, Selbststudium, LP]
        var rows: [[String]] = []
        var total: Double?
        /// je Pruefung (Teilmodul, Stuecke der Pruefungsform)
        var exams: [(part: String, pieces: [String])] = []
        /// Eintraege, je Eintrag die Stuecke; ein neuer beginnt mit "TM1"
        var coursework: [[String]] = []
        var content: [String] = []
    }

    /// -> (Rohmodule, Pflichtmodule je Studienvariante) (`_kuerzel_read`)
    static func kuerzelRead(_ pages: [String]) -> (mods: [KuerzelRaw], variants: [[String]]) {
        var mods: [KuerzelRaw] = []
        var variants: [[String]] = []
        var collecting = false
        var cur: Int?
        var section: String?
        var valueCol = kValueCol
        var formCol: Int?, descCol: Int?
        for (p, lines) in layoutLines(pages).enumerated() {
            for cells in lines {
                let text = line(cells)
                let indent = cells[0].col
                if indent < valueCol - kLabelGap && (CatalogRx.match(annexRx, text) != nil || CatalogRx.match(kEndRx, text) != nil) {
                    cur = nil
                    collecting = false
                    section = nil
                    continue
                }
                if indent < valueCol - kLabelGap, let t = CatalogRx.match(kTitleRx, text) {
                    collecting = false
                    if let c = cur, mods[c].code == t[1] {     // Kolumnentitel der Folgeseite
                        if !kKeep.contains(section ?? "") { section = nil }
                        continue
                    }
                    mods.append(KuerzelRaw(code: t[1] ?? "", title: StudyCatalogText.strip(t[2] ?? ""), page: p + 1))
                    cur = mods.count - 1
                    section = "head"
                    valueCol = kValueCol
                    continue
                }
                guard let c = cur else {
                    // Anlage "Beschreibung der Studienvarianten": Pflichtmodule je Variante
                    if let m = CatalogRx.match(kRequiredRx, text) {
                        variants.append(findAll(kCodeRx, m[1] ?? ""))
                        collecting = true
                    } else if collecting {
                        if CatalogRx.match(kElectiveRx, text) != nil {
                            collecting = false
                        } else {
                            variants[variants.count - 1] += findAll(kCodeRx, text)
                        }
                    }
                    continue
                }
                let label = cells.filter { $0.col < valueCol - kLabelGap }.map(\.text).joined(separator: " ")
                let vals = cells.filter { $0.col >= valueCol - kLabelGap }
                if !label.isEmpty {
                    var key: String?
                    if label.hasPrefix("Für das Modul verantwortliche Person") {
                        key = "lead"
                    } else if label == "Studiensemester", let first = vals.first, first.text.hasPrefix("Dauer") {
                        key = "table"
                        valueCol = first.col
                    } else if label.hasPrefix("Inhalte und") {
                        key = "content"
                    } else if label.hasPrefix("Lehr-/") {
                        key = "forms"
                    } else if CatalogRx.match(kReqRx, label) != nil {
                        key = vals.contains { $0.text.hasPrefix("Art der") } ? "exam" : "req"
                    } else if CatalogRx.match(kCourseworkRx, label) != nil {
                        key = "coursework"
                    } else if label.hasPrefix("Verwendbarkeit des") {
                        key = "usage"
                    } else if label.hasPrefix("Zuständige Ständige") {
                        key = "board"
                    } else if section == "req" && label.hasPrefix("Vergabe von") {
                        key = "exam"
                    } else if section == "req" && (label.hasPrefix("Teilnahme") || label.hasPrefix("Zulassung zur")) {
                        section = "other"
                    }
                    if key == "exam" {
                        formCol = vals.first { $0.text.hasPrefix("Prüfungsfor") }?.col
                        descCol = vals.first { $0.text.hasPrefix("Prüfungsleistung") }?.col
                        section = key
                        continue
                    }
                    if let key {
                        section = key
                        if key == "table" { continue }
                    }
                }
                switch section {
                case "table":
                    if mods[c].semester == nil, let m = CatalogRx.match(firstIntRx, label) {
                        mods[c].semester = Int(m[0] ?? "")
                        mods[c].freq = vals.count >= 2 ? vals[1].text : nil
                        let status = vals.dropFirst(2).map(\.text).joined(separator: " ")
                        mods[c].status = status.isEmpty ? nil : status
                    }
                case "content":
                    if !vals.isEmpty { mods[c].content.append(line(vals)) }
                case "forms":
                    let n = vals.count
                    if n >= 4 && CatalogRx.matches(numberRx, vals[n - 1].text) && CatalogRx.matches(hoursRx, vals[n - 3].text)
                        && CatalogRx.matches(hoursRx, vals[n - 4].text) {
                        mods[c].rows.append([vals[n - 4].text, vals[n - 3].text, vals[n - 1].text])
                    } else if n >= 2 && CatalogRx.matches(numberRx, vals[n - 1].text) && CatalogRx.match(firstIntRx, vals[0].text) == nil {
                        mods[c].total = number(vals[n - 1].text)   // "s. RStO ...   13": LP des ganzen Moduls
                    }
                case "coursework":
                    if !vals.isEmpty {
                        let line = line(vals)
                        if !mods[c].coursework.isEmpty && CatalogRx.match(kPartRx, line) == nil {
                            mods[c].coursework[mods[c].coursework.count - 1].append(line)
                        } else {
                            mods[c].coursework.append([line])
                        }
                    }
                case "exam":
                    guard let formCol else { break }
                    let lo = formCol - colTolerance
                    let hi: Int? = descCol.flatMap { $0 > formCol ? $0 - colTolerance : nil }
                    let form = vals.filter { $0.col >= lo && (hi == nil || $0.col < hi!) }.map(\.text).joined(separator: " ")
                    if let mark = vals.firstIndex(where: { $0.col < lo && CatalogRx.matches(kExamMarkRx, $0.text) }) {
                        mods[c].exams.append((vals[..<mark].map(\.text).joined(separator: " "), form.isEmpty ? [] : [form]))
                    } else if !form.isEmpty && !mods[c].exams.isEmpty {
                        mods[c].exams[mods[c].exams.count - 1].pieces.append(form)
                    }
                default:
                    break
                }
            }
        }
        return (mods, variants)
    }

    /// Hat das Dokument Module mit Titelzeile "INF-B1: „Titel“" und dem Tabellenkopf "Studiensemester | Dauer ..."?
    /// (`is_kuerzel_modultabelle`)
    public static func detectKuerzel(pages: [String]) -> Bool {
        kuerzelRead(pages).mods.contains { $0.semester != nil }
    }

    /// -> (Art, Bereich): "Status Modul", sonst die Pflichtmodule der Studienvarianten (Pflicht nur, wenn in jeder)
    static func kuerzelKind(_ r: KuerzelRaw, _ variants: [[String]]) -> (String, String?) {
        if CatalogRx.search(finalRx, r.title.lowercased()) != nil { return ("abschluss", nil) }
        let status = (r.status ?? "").lowercased()
        if status.hasPrefix("pflicht") { return ("pflicht", nil) }
        if status.hasPrefix("wahlpflicht") { return ("wahlpflicht", nil) }
        if status.hasPrefix("wahl") { return ("wahl", nil) }
        if !variants.isEmpty {
            return variants.allSatisfy { $0.contains(r.code) } ? ("pflicht", "pflichtmodule") : ("wahlpflicht", "wahlpflichtmodule")
        }
        return ("pflicht", nil)
    }

    /// Layout-Seitentexte -> Katalog im geteilten Format und lokale Modultexte (`parse_kuerzel_modultabelle`)
    public static func parseKuerzel(pages: [String], meta: StudyCatalogMeta) -> ParsedStudyCatalog {
        let (all, variants) = kuerzelRead(pages)
        let raw = all.filter { $0.semester != nil || !$0.rows.isEmpty || $0.total != nil }
        var ids = Set<String>()
        var modules: [PyJSON] = []
        var textJSON: [PyJSON.Member] = []
        var used: [String] = []
        for r in raw {
            let id = StudyCatalogParser.unique(StudyCatalogText.slug(r.title), &ids)
            let (kind, area) = kuerzelKind(r, variants)
            if let area, !used.contains(area) { used.append(area) }
            var lp = r.total
            if lp == nil && !r.rows.isEmpty { lp = r.rows.reduce(0.0) { $0 + number($1[2]) } }
            let hours = r.rows.reduce(0) { sum, row in sum + row.prefix(2).reduce(0) { $0 + ($1 == "-" ? 0 : (Int($1) ?? 0)) } }
            let exams: [[String]] = r.exams.map { e in
                let part = CatalogRx.match(kPartRx, e.part)?[1] ?? nil
                return (part != nil && !e.pieces.isEmpty ? [part! + ":"] : []) + e.pieces
            }
            modules.append(module(id: id, title: r.title, code: r.code, area: area, kind: kind, lp: lp, semester: r.semester,
                                  turnus: season(r.freq ?? ""), exam: facts(exams), coursework: facts(r.coursework, references: false),
                                  workload: hours == 0 ? nil : hours, page: r.page))
            textJSON.append(.init(id, moduleTexts(content: r.content, goals: [])))
        }
        let names = [("pflichtmodule", "Pflichtmodule", "pflicht"), ("wahlpflichtmodule", "Wahlpflichtmodule", "wahlpflicht")]
        let areas: [PyJSON] = names.filter { used.contains($0.0) }.map {
            .object([.init("id", .string($0.0)), .init("name", .string($0.1)), .init("lp_required", .null), .init("lp_max", .null),
                     .init("kind", .string($0.2))])
        }
        return ParsedStudyCatalog(catalog: catalog(meta, areas: areas, modules: modules), texts: .object(textJSON))
    }

    // MARK: hildesheim-kennnummer-tabelle

    struct KennnummerRaw {
        var code: String
        var title: String
        var page: Int
        var workload: Int?
        var lp: Double?
        var semester: Int?
        var freq: [String] = []
        var sections: [String: [String]] = [:]
    }

    /// Rohmodule (`_kennnummer_read`)
    static func kennnummerRead(_ pages: [String]) -> [KennnummerRaw] {
        var flat: [(page: Int, cells: [Cell])] = []
        for (p, lines) in layoutLines(pages).enumerated() {
            for cells in lines { flat.append((p + 1, cells)) }
        }
        let texts = flat.map { line($0.cells) }
        var starts: [(title: Int, head: Int, match: [String?])] = []
        for (h, text) in texts.enumerated() where text.replacingOccurrences(of: " ", with: "").contains(nHeadKey) {
            for back in 1...nTitleBack {
                let k = h - back
                if k >= 0, flat[k].cells[0].col <= nLabelIndent, let m = CatalogRx.match(nTitleRx, texts[k]) {
                    starts.append((k, h, m))
                    break
                }
            }
        }
        var mods: [KennnummerRaw] = []
        for (n, s) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].title : flat.count
            var r = KennnummerRaw(code: (s.match[1] ?? "") + " " + (s.match[2] ?? ""), title: StudyCatalogText.strip(s.match[3] ?? ""),
                                  page: flat[s.title].page)
            let running = r.code + " " + r.title
            var freqCol: Int?, durCol: Int?
            var key: String?
            for i in (s.head + 1)..<max(end, s.head + 1) {
                let cells = flat[i].cells
                let text = texts[i]
                if CatalogRx.match(annexRx, text) != nil && cells[0].col <= nLabelIndent { break }
                if text == running { continue }                // Kolumnentitel der Folgeseite
                if r.workload == nil && key == nil {
                    guard let w = cells.firstIndex(where: { CatalogRx.matches(nWorkloadRx, $0.text) }) else { continue }
                    r.workload = Int(CatalogRx.match(nWorkloadRx, cells[w].text)?[1] ?? "")
                    if w + 1 < cells.count && CatalogRx.matches(numberRx, cells[w + 1].text) { r.lp = number(cells[w + 1].text) }
                    if w + 2 < cells.count, let m = CatalogRx.match(nSemesterRx, cells[w + 2].text) { r.semester = Int(m[1] ?? "") }
                    if w + 3 < cells.count {
                        freqCol = cells[w + 3].col
                        r.freq.append(cells[w + 3].text)
                    }
                    durCol = w + 4 < cells.count ? cells[w + 4].col : nil
                    continue
                }
                var name: String?
                if cells[0].col <= nLabelIndent && cells.count >= 2 && CatalogRx.matches(nRowRx, cells[0].text) {
                    name = nRows.first { cells[1].text.hasPrefix($0.0) }?.1
                }
                if let name {
                    key = name
                    if r.sections[name] == nil { r.sections[name] = [] }
                    continue
                }
                guard let key else {
                    if let freqCol {                           // umbrochene Werte der Kopfzeile: nur die Spalte Haeufigkeit
                        r.freq += cells.filter { $0.col >= freqCol - colTolerance && (durCol == nil || $0.col < durCol! - colTolerance) }.map(\.text)
                    }
                    continue
                }
                r.sections[key, default: []].append(text)
            }
            mods.append(r)
        }
        return mods
    }

    /// Hat das Dokument Module mit dem Tabellenkopf "Kennnummer | Workload | Credits"? (`is_kennnummer_tabelle`)
    public static func detectKennnummer(pages: [String]) -> Bool {
        kennnummerRead(pages).contains { $0.workload != nil }
    }

    /// Zeilen eines Abschnitts -> (plain, coursework, exam): Teile unter "Studienleistung(en):" / "Prüfungsleistung:",
    /// davor `plain`; ein neuer Eintrag beginnt mit einer Teilmodulnummer "2.1" (`_kennnummer_split`)
    static func kennnummerSplit(_ lines: [String]) -> (plain: String?, coursework: String?, exam: String?) {
        var parts: [String: [[String]]] = ["plain": [], "coursework": [], "exam": []]
        var sub = "plain"
        for line in lines {
            if CatalogRx.match(nCourseworkRx, line) != nil {
                sub = "coursework"
            } else if CatalogRx.match(nExamRx, line) != nil {
                sub = "exam"
            } else if !(parts[sub] ?? []).isEmpty && CatalogRx.match(nItemRx, line) == nil {
                parts[sub]![parts[sub]!.count - 1].append(line)
            } else {
                parts[sub]!.append([line])
            }
        }
        return (facts(parts["plain"] ?? []), facts(parts["coursework"] ?? []), facts(parts["exam"] ?? []))
    }

    /// Layout-Seitentexte -> Katalog im geteilten Format und lokale Modultexte (`parse_kennnummer_tabelle`)
    public static func parseKennnummer(pages: [String], meta: StudyCatalogMeta) -> ParsedStudyCatalog {
        var ids = Set<String>()
        var modules: [PyJSON] = []
        var textJSON: [PyJSON.Member] = []
        for r in kennnummerRead(pages) where r.workload != nil || r.lp != nil {
            let id = StudyCatalogParser.unique(StudyCatalogText.slug(r.title), &ids)
            let exam = kennnummerSplit(r.sections["exam"] ?? []), credit = kennnummerSplit(r.sections["credit"] ?? [])
            let kind = CatalogRx.search(finalRx, r.title.lowercased()) != nil ? "abschluss" : "pflicht"
            modules.append(module(id: id, title: r.title, code: r.code, area: nil, kind: kind, lp: r.lp, semester: r.semester,
                                  turnus: season(join(r.freq)), exam: exam.plain ?? exam.exam ?? credit.exam,
                                  coursework: exam.coursework ?? credit.coursework, workload: r.workload, page: r.page))
            textJSON.append(.init(id, moduleTexts(content: r.sections["content"] ?? [], goals: r.sections["goals"] ?? [])))
        }
        return ParsedStudyCatalog(catalog: catalog(meta, areas: [], modules: modules), texts: .object(textJSON))
    }
}
