import Foundation

/// Leser fuer "Studienordnung inklusive Modulhandbuch" der Universitaet Hildesheim (Fachbereich 1, z. B. Bachelor
/// Sozialpaedagogik) wie app/study_catalog_hildesheim.py, Regel fuer Regel gleich (Fixture
/// packages/shared-contracts/fixtures/study-catalog-hildesheim, StudyCatalogHildesheimParserTests). Fuer eigene
/// Katalog-Links: der modkat-Leser (`StudyCatalogParser`) findet in diesen PDFs kein Modul.
///
/// Aufbau: Paragrafen-Text, "Anlage 1" (mit "Gesamtzahl der Leistungspunkte"), "Anlage 2 Studienablaufplan", "Anlage 3
/// Modulhandbuch" mit einer zweispaltigen Tabelle je Modul (links Feldname, rechts Wert): Bezeichnung "Modul 3: Titel",
/// Kompetenzen und Lernziele, Lerninhalte (darin Teilmodule "TM 1: Titel (Seminar; 2 SWS; 2 LP (WiSe))"),
/// Leistungspunkte, Semesterwochenstunden, Studienleistung(en), Lehr- und Lernformen, Verwendbarkeit des Moduls,
/// Pruefungsleistung(en), Arbeitsaufwand (Workload), Empfohlene(s) Fachsemester, Voraussetzung(en) fuer die Teilnahme
/// am Modul / Zulassung zur Pruefung, Moduldauer, Haeufigkeit (des Angebots), Zustaendige Staendige
/// Pruefungskommission, Modulverantwortliche. Seitenkopf "Verkündungsblatt der Universität Hildesheim - Heft N - ... -
/// Seite N -" oder "Lesefassung" + "(Stand TT.MM.JJJJ)".
///
/// WICHTIG am Geraet: `PDFPage.string` stellt in diesen PDFs oft die Feldnamen-Spalte vor die Werte ("Bezeichnung
/// Kompetenzen und Lernziele Lerninhalte Modul 2: ..."). Deshalb die Textstuecke mit Lage nehmen
/// (`StudyCatalogPDF.planItems`, im Lauf `env.planText`) und mit `rowPages` zu Tabellenzeilen ordnen; das Ergebnis geht
/// an `head`, `parse` und `details`. `detect` geht auch mit dem rohen Text (`env.pdfText`). Auf dem rohen Text findet
/// `parse` die Module, laesst aber alles weg, was nicht sicher zuzuordnen ist (nur Titel, LP, Teilmodule, Texte).
///
/// Was nicht sicher lesbar ist, bleibt leer: `semester` nur aus "Empfohlene(s) Fachsemester" in klarer Form (erste
/// Zahl), Anlage 2 wird nicht gelesen; `code` null (die Modulnummer ist keine QIS-Pruefungsnummer), `areas` leer.
public enum StudyCatalogHildesheimParser {
    public static let format = "hildesheim-studienordnung"
    static let maxText = 500
    static let maxPartTitle = 200
    static let rowTolerance = 3.0

    static let headerRx = [
        #"^Verkündungsblatt der (?:Stiftung )?Universität Hildesheim ?[-–] ?Heft .*[-–] ?Seite ?[0-9]+ ?[-–]?$"#,
        "^Lesefassung$",
        #"^\(Stand:? ?[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{4}\)$"#,
    ]
    static let titlePhrase = "Studienordnung inklusive Modulhandbuch"
    static let moduleRx = "^Bezeichnung:? ((?:(?:Kompetenzen und Lernziele|Lerninhalte) )*)Modul ?([0-9]{1,2}) ?: ?(.+)$"
    static let annexRx = "^Anlage [0-9]+[a-z]?(?: |:|$)"

    /// Feldnamen der Modultabelle: Schluessel, Muster des Namens am Zeilenanfang
    static let labels: [(String, String)] = [
        ("goals", "Kompetenzen und Lernziele"),
        ("content", "Lerninhalte"),
        ("lp", "Leistungspunkte"),
        ("sws", "Semesterwochenstunden"),
        ("coursework", "Studienleistung(?:en)?"),
        ("forms", "Lehr- und Lernformen"),
        ("usage", "Verwendbarkeit des Moduls"),
        ("exam", "Prüfungsleistung(?:en)?"),
        ("workload", #"Arbeitsaufwand(?: \([Ww]orkload\))?"#),
        ("semester", #"Empf\w* Fachsemester"#),
        ("req", "Voraussetzung(?:en)? für die"),
        ("duration", "Moduldauer"),
        ("freq", "Häufigkeit(?: des Angebots)?"),
        ("board", "Zuständige Ständige"),
        ("lead", "Modulverantwortliche(?:r|/r)?"),
    ]
    static let labelRx: [(String, String)] = labels.map { ($0.0, "^(?:" + $0.1 + "):?(?: (.*))?$") }
    static let prereqPartRx = "^Teilnahme am Modul:?(?: (.*))?$"
    static let admissionPartRx = "^Zulassung (?:zur (?:Modul)?[Pp]rüfung|zu den Prüfungen):?(?: (.*))?$"
    static let boardPartRx = "^Prüfungskommission:?(?: (.*))?$"
    static let bareSemesterRx = "^Semester (.+)$"

    static let semesterValueRx = #"^([1-9])\. ?(?:(?:-|–|−|/|und|bis|oder) ?[1-9]\. ?)?(?:Fach)?[Ss]emester$"#
    static let semesterWordRx = "^(erstes|zweites|drittes|viertes|fünftes|sechstes|siebtes|achtes)"
        + "(?: (?:bis|und|oder) (?:erstes|zweites|drittes|viertes|fünftes|sechstes|siebtes|achtes))?"
        + " (?:fach)?semester$"
    static let semesterWords = ["erstes": 1, "zweites": 2, "drittes": 3, "viertes": 4, "fünftes": 5, "sechstes": 6, "siebtes": 7, "achtes": 8]
    static let lpValueRx = #"^([0-9]+(?:,[0-9]+)?)(?: ?LP)?(?: \(.*)?$"#
    static let lpForRx = "^([0-9]+(?:,[0-9]+)?) ?LP für "
    static let swsValueRx = #"^([0-9]+(?:,[0-9]+)?)(?: ?SWS)?(?: \(.*)?$"#
    static let workloadValueRx = #"^([0-9]+) ?(?:Stunden|Std\.?|h)(?: |$)"#
    static let reasonRx = "^Begründung:"
    /// Verweise auf andere Module in den Voraussetzungen: "des Moduls 2", "(Modul 6)", "der Module 1 und 3"
    static let moduleRefRx = #"\bModul(?:s|e|en)? ([0-9]{1,2}(?:(?:, ?| und | sowie )[0-9]{1,2})*)\b"#
    static let numberRx = "[0-9]+"
    static let finalRx = "bachelorarbeit|masterarbeit|abschlussarbeit|^abschlussmodul"
    static let noneValues: Set<String> = ["", "-", "–", "keine", "keiner", "nein", "entfällt"]

    /// Teilmodule in "Lerninhalte": "TM 1: Titel (Seminar; 2 SWS; 2 LP (WiSe))", "TM 2: Titel (2 SWS / 4,5 LP)",
    /// "TM 3: Titel (2 SWS; 3 LP) (SoSe)", "(2 SWS / 3 + 3 LP)"
    static let partStartRx = "(?:^| )TM ?([0-9]{1,2}) ?:(?: ?:)? ?"
    static let partSpecRx = #"^(.*?) ?\((?:([^()0-9;]*?) ?; ?)?([0-9]+) ?SWS ?[;/]? ?"#
        + #"([0-9]+(?:,[0-9]+)?(?: ?\+ ?[0-9]+(?:,[0-9]+)?)*) ?LP ?\)?(?: ?\(([^()]*)\))?"#
    static let seasonRx = "(?:WiSe|SoSe|WS|SS|Wintersemester|Sommersemester)"
    static let partTermRx = "^" + seasonRx + "(?: ?(?:,|/|und|oder) ?" + seasonRx + ")*$"

    static let everyTermRx = "jede[sm] semester"
    static let winterRx = #"winter|\bwise\b|\bws\b"#
    static let summerRx = #"sommer|\bsose\b|\bss\b"#

    static let programRx = titlePhrase + " für den (Bachelor|Master) ?-? ?[Ss]tudiengang (.+?) im Fachbereich"
    static let standRx = #"^\(Stand:? ?([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})\)$"#
    static let heftRx = "^Verkündungsblatt der (?:Stiftung )?Universität Hildesheim ?[-–] ?Heft ([0-9]+) .*?"
        + #"\(([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})\)"#
    static let validFromRx = "zum (Winter|Sommer)semester ((?:[0-9] ?){4})(?:/ ?[0-9]{2,4})? aufgenommen"
    static let totalLPRx = "Gesamtzahl der Leistungspunkte:? ([0-9]+(?:,[0-9]+)?)$"
    static let degrees: [(String, String, String)] = [
        ("Bachelor", "Bachelor of Arts", "B.A."), ("Bachelor", "Bachelor of Science", "B.Sc."),
        ("Bachelor", "Bachelor of Education", "B.Ed."), ("Master", "Master of Arts", "M.A."),
        ("Master", "Master of Science", "M.Sc."), ("Master", "Master of Education", "M.Ed."),
    ]
    /// Felder, die bei vermischter Reihenfolge (roher PDFKit-Text) in allen Modulen wegfallen
    static let mixedUnsure = ["sws", "coursework", "exam", "workload", "semester", "prereq", "admission", "freq"]

    // MARK: Zeilen

    /// Textstuecke mit Lage je Seite (`StudyCatalogPDF.planItems`) -> Seitentexte, eine Zeile je Tabellenzeile: nach y
    /// geordnet, Stuecke bis 3 Punkte unter dem ersten der Zeile gehoeren dazu, in der Zeile von links nach rechts
    /// (`row_pages`)
    public static func rowPages(_ items: [[StudyPlanTextItem]]) -> [String] {
        items.map { page in
            let order = page.indices.sorted { (page[$0].y, $0) < (page[$1].y, $1) }
            var rows: [[Int]] = []
            var y0 = 0.0
            for i in order {
                if rows.isEmpty || page[i].y - y0 > rowTolerance {
                    rows.append([])
                    y0 = page[i].y
                }
                rows[rows.count - 1].append(i)
            }
            return rows.map { row in
                row.sorted { (page[$0].x, $0) < (page[$1].x, $1) }.map { page[$0].text }.joined(separator: " ")
            }.joined(separator: "\n")
        }
    }

    /// Normalisierte Zeilen je Seite ohne Seitenkopf (`clean_pages`)
    public static func cleanPages(_ pages: [String]) -> [[String]] {
        pages.map { text in
            StudyCatalogText.normalizeLines(text).filter { line in !headerRx.contains { CatalogRx.matches($0, line) } }
        }
    }

    /// Feldname am Zeilenanfang -> (Schluessel, Rest der Zeile)
    static func label(_ line: String) -> (String, String)? {
        for (key, rx) in labelRx {
            if let m = CatalogRx.match(rx, line) { return (key, m[1] ?? "") }
        }
        if let m = CatalogRx.match(bareSemesterRx, line), let rest = m[1], semester(rest) != nil { return ("semester", rest) }
        return nil
    }

    /// Raender weg, leer -> nil, hoechstens `limit` Zeichen (am Wortende gekuerzt, mit "…")
    static func clip(_ s: String, _ limit: Int = maxText) -> String? {
        var t = StudyCatalogText.strip(s, " ;,")
        if t.isEmpty { return nil }
        if StudyCatalogText.length(t) > limit {
            let cut = StudyCatalogText.prefix(t, limit - 1)
            if let r = cut.range(of: " ", options: [.backwards, .literal]) {
                t = String(cut[..<r.lowerBound]) + "…"
            } else {
                t = cut + "…"
            }
        }
        return t
    }

    /// Alle Treffer eines Musters (`re.finditer`): Bereich und Gruppen
    static func all(_ pattern: String, _ s: String) -> [(range: NSRange, groups: [String?])] {
        let ns = s as NSString
        return CatalogRx.regex(pattern).matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (m.range, (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) })
        }
    }

    // MARK: Werte

    static func semester(_ value: String) -> Int? {
        if let m = CatalogRx.match(semesterValueRx, value) { return Int(m[1] ?? "") }
        if let m = CatalogRx.match(semesterWordRx, value.lowercased()) { return semesterWords[m[1] ?? ""] }
        return nil
    }

    static func decimal(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    static func lp(_ lines: [String]) -> Double? {
        guard let first = lines.first else { return nil }
        if CatalogRx.match(lpForRx, first) != nil {
            return lines.reduce(0.0) { sum, l in sum + (CatalogRx.match(lpForRx, l).map { decimal($0[1] ?? "") } ?? 0) }
        }
        return CatalogRx.match(lpValueRx, first).map { decimal($0[1] ?? "") }
    }

    /// Studien-/Pruefungsleistung: Wert bis vor "Begründung:", "keine" -> nil
    static func fact(_ lines: [String]) -> String? {
        var kept: [String] = []
        for l in lines {
            if CatalogRx.match(reasonRx, l) != nil { break }
            kept.append(l)
        }
        let s = StudyCatalogText.strip(kept.joined(separator: " "))
        return noneValues.contains(s.lowercased()) ? nil : clip(s)
    }

    static func season(_ text: String) -> String {
        let t = text.lowercased()
        if CatalogRx.search(everyTermRx, t) != nil { return "WS+SS" }
        let winter = CatalogRx.search(winterRx, t) != nil, summer = CatalogRx.search(summerRx, t) != nil
        if winter && summer { return "WS+SS" }
        return winter ? "WS" : (summer ? "SS" : "unbekannt")
    }

    struct Part: Equatable {
        var number: Int
        var title: String
        var kind: String?
        var sws: Int
        var lp: Double
        var term: String?

        var json: PyJSON {
            .object([.init("number", .int(String(number))), .init("title", .string(title)), .init("kind", StudyCatalogParser.str(kind)),
                     .init("sws", .int(String(sws))), .init("lp", StudyCatalogParser.num(lp)), .init("term", StudyCatalogParser.str(term))])
        }
    }

    /// Teilmodule aus den Zeilen von "Lerninhalte" (nur mit Angabe "(… SWS … LP)")
    static func parts(_ content: [String]) -> [Part] {
        let text = content.joined(separator: " ")
        let ns = text as NSString
        let starts = all(partStartRx, text)
        var out: [Part] = []
        for (k, s) in starts.enumerated() {
            let from = s.range.location + s.range.length
            let to = k + 1 < starts.count ? starts[k + 1].range.location : ns.length
            let piece = ns.substring(with: NSRange(location: from, length: to - from))
            guard let m = CatalogRx.match(partSpecRx, piece), let title = clip(StudyCatalogText.strip(m[1] ?? "", " :"), maxPartTitle) else { continue }
            let lp = (m[4] ?? "").components(separatedBy: "+").reduce(0.0) { $0 + decimal(StudyCatalogText.strip($1)) }
            let term = StudyCatalogText.strip(m[5] ?? "")
            let kind = StudyCatalogText.strip(m[2] ?? "", " ,")
            out.append(Part(number: Int(s.groups[1] ?? "") ?? 0, title: title, kind: kind.isEmpty ? nil : kind, sws: Int(m[3] ?? "") ?? 0,
                            lp: lp, term: CatalogRx.match(partTermRx, term) != nil ? season(term) : nil))
        }
        return out
    }

    // MARK: Module

    struct Raw {
        var number: Int
        var title: String
        var page: Int
        var fields: [String: [String]] = ["_head": []]
        var unsure = Set<String>()
        var id = ""

        /// Zeilen eines Felds, leer wenn der Wert nicht sicher zuzuordnen ist (`_sure`)
        func sure(_ key: String) -> [String] { unsure.contains(key) ? [] : (fields[key] ?? []) }
    }

    /// Rohmodule (`_read`). `unsure`: der Feldname stand mit weiteren Feldnamen in einer Zeile (roher PDFKit-Text), der
    /// Wert ist nicht sicher zuzuordnen. Kommt das irgendwo im Dokument vor, gelten in allen Modulen nur noch Titel,
    /// Leistungspunkte, Teilmodule und die Texte.
    static func read(_ clean: [[String]]) -> [Raw] {
        var mods: [Raw] = []
        var cur: Int?
        var key = "_head"
        for (p, lines) in clean.enumerated() {
            for line in lines {
                if let m = CatalogRx.match(moduleRx, line) {
                    var r = Raw(number: Int(m[2] ?? "") ?? 0, title: StudyCatalogText.strip(m[3] ?? ""), page: p + 1)
                    key = "_head"
                    if !(m[1] ?? "").isEmpty {             // Feldnamen vor dem Titel: Ziele und Inhalte nicht zu trennen
                        r.fields["goals"] = []
                        r.fields["content"] = []
                        r.unsure.formUnion(["goals", "content", "_head"])
                        key = "content"
                    }
                    mods.append(r)
                    cur = mods.count - 1
                    continue
                }
                guard let c = cur else { continue }
                if CatalogRx.match(annexRx, line) != nil {  // weitere Anlage nach dem Modulhandbuch
                    cur = nil
                    continue
                }
                if key == "req" {
                    var m = CatalogRx.match(prereqPartRx, line)
                    var name = "prereq"
                    if m == nil {
                        m = CatalogRx.match(admissionPartRx, line)
                        name = "admission"
                    }
                    if let m, mods[c].fields[name] == nil {
                        mods[c].fields[name] = mods[c].fields.removeValue(forKey: "req") ?? []
                        if mods[c].unsure.remove("req") != nil { mods[c].unsure.insert(name) }
                        key = name
                        if let rest = m[1], !rest.isEmpty { mods[c].fields[key, default: []].append(rest) }
                        continue
                    }
                }
                if key == "board", mods[c].fields["_board"] == nil, let m = CatalogRx.match(boardPartRx, line) {
                    mods[c].fields["_board"] = []
                    if let rest = m[1], !rest.isEmpty { mods[c].fields[key, default: []].append(rest) }
                    continue
                }
                guard let found = label(line), mods[c].fields[found.0] == nil else {
                    mods[c].fields[key, default: []].append(line)
                    continue
                }
                var rest = found.1
                key = found.0
                mods[c].fields[key] = []
                var more = rest.isEmpty ? nil : label(rest)
                while let next = more, mods[c].fields[next.0] == nil {   // mehrere Feldnamen in einer Zeile
                    mods[c].unsure.formUnion([key, next.0])
                    key = next.0
                    rest = next.1
                    mods[c].fields[key] = []
                    more = rest.isEmpty ? nil : label(rest)
                }
                if !rest.isEmpty { mods[c].fields[key, default: []].append(rest) }
            }
        }
        let mixed = mods.contains { !$0.unsure.isEmpty }
        for i in mods.indices {
            let head = mods[i].fields["_head"] ?? []
            if !head.isEmpty && head.count <= 2 && !mods[i].unsure.contains("_head") {
                mods[i].title = mods[i].title + " " + head.joined(separator: " ")
            }
            if mixed { mods[i].unsure.formUnion(mixedUnsure) }
        }
        return mods
    }

    /// Ist das eine "Studienordnung inklusive Modulhandbuch" mit Modultabellen ("Bezeichnung Modul 1: ...")? Geht auch
    /// mit dem rohen PDFKit-Text (`is_hildesheim_sto`).
    public static func detect(pages: [String]) -> Bool {
        let clean = cleanPages(pages)
        guard let first = clean.first, first.joined(separator: " ").contains(titlePhrase) else { return false }
        return clean.contains { $0.contains { CatalogRx.match(moduleRx, $0) != nil } }
    }

    /// Kopf aus Titelseite und Paragrafen (`hildesheim_sto_head`); Unbekanntes ist nil
    public struct Head: Equatable, Sendable {
        /// Name des Studiengangs, z. B. "Sozialpädagogik"
        public var program: String?
        /// "Bachelor" oder "Master"
        public var level: String?
        /// "B.A.", "M.A." usw. nur, wenn die PDF "Bachelor of Arts" o. ae. nennt, sonst gleich `level`
        public var degree: String?
        /// "JJJJ-MM-TT" aus "(Stand TT.MM.JJJJ)" der Lesefassung, sonst Datum des Hefts
        public var stand: String?
        /// Nummer des Verkuendungsblatts
        public var heft: String?
        /// Jahr des Stands
        public var po: String?
        /// aus "gilt erstmals ... zum Wintersemester 2025/26 aufgenommen", sonst das Semester des Stands
        public var catalogTerm: String?
        /// "Gesamtzahl der Leistungspunkte"
        public var totalLP: Double?

        public var json: PyJSON {
            let str = StudyCatalogParser.str
            return .object([.init("program", str(program)), .init("level", str(level)), .init("degree", str(degree)),
                            .init("stand", str(stand)), .init("heft", str(heft)), .init("po", str(po)),
                            .init("catalog_term", str(catalogTerm)), .init("total_lp", StudyCatalogParser.num(totalLP))])
        }
    }

    static func iso(_ y: String?, _ m: String?, _ d: String?) -> String {
        "\(y ?? "")-" + String(format: "%02d", Int(m ?? "") ?? 0) + "-" + String(format: "%02d", Int(d ?? "") ?? 0)
    }

    public static func head(pages: [String]) -> Head {
        let raw = pages.map(StudyCatalogText.normalizeLines)
        let clean = cleanPages(pages)
        let first = (clean.first ?? []).joined(separator: " ")
        var h = Head()
        if let m = CatalogRx.search(programRx, first) {
            h.level = m[1]
            var program = StudyCatalogText.strip(m[2] ?? "", " „“\"")
            for word in ["und", "oder"] {                  // pypdf-Luecke "Sozial - und"
                program = program.replacingOccurrences(of: " - \(word) ", with: "- \(word) ")
            }
            h.program = program
            h.degree = h.level
        }
        let top = Array((raw.first ?? []).prefix(6))
        for l in top {
            if let m = CatalogRx.match(standRx, l) {
                h.stand = iso(m[3], m[2], m[1])
                break
            }
        }
        for l in top {
            if let m = CatalogRx.match(heftRx, l) {
                h.heft = m[1]
                if h.stand == nil { h.stand = iso(m[4], m[3], m[2]) }
                break
            }
        }
        // Text vor dem Modulhandbuch
        var before: [String] = []
        for lines in clean {
            if let k = lines.firstIndex(where: { CatalogRx.match(moduleRx, $0) != nil }) {
                before += lines[..<k]
                break
            }
            before += lines
        }
        let text = before.joined(separator: " ")
        if let level = h.level, let d = degrees.first(where: { $0.0 == level && text.contains($0.1) }) { h.degree = d.2 }
        if let m = CatalogRx.search(validFromRx, text), let y = Int((m[2] ?? "").replacingOccurrences(of: " ", with: "")) {
            h.catalogTerm = m[1] == "Winter" ? StudyCatalogText.winter(y) : "SS \(y)"
        } else if let stand = h.stand {
            h.catalogTerm = StudyCatalogText.currentTerm(today: stand)
        }
        for l in before {
            if let m = CatalogRx.search(totalLPRx, l) {
                h.totalLP = decimal(m[1] ?? "")
                break
            }
        }
        h.po = h.stand.map { StudyCatalogText.prefix($0, 4) }
        return h
    }

    /// Rohmodule mit ids (aus dem Titel, eindeutig) in der Reihenfolge der PDF
    static func modules(_ pages: [String]) -> [Raw] {
        var raw = read(cleanPages(pages))
        var ids = Set<String>()
        for i in raw.indices { raw[i].id = StudyCatalogParser.unique(StudyCatalogText.slug(raw[i].title), &ids) }
        return raw
    }

    /// Seitentexte -> Katalog im geteilten Format und lokale Modultexte, Form wie `StudyCatalogParser.parse`
    /// (`parse_hildesheim_sto`). Leere Angaben in `meta` (program, degree, po, catalogTerm, totalLP) kommen aus `head`.
    public static func parse(pages: [String], meta: StudyCatalogMeta) -> ParsedStudyCatalog {
        let raw = modules(pages)
        let h = head(pages: pages)
        var byNumber: [Int: String] = [:]
        for r in raw where byNumber[r.number] == nil { byNumber[r.number] = r.id }
        let str = StudyCatalogParser.str, num = StudyCatalogParser.num
        var moduleJSON: [PyJSON] = []
        var textJSON: [PyJSON.Member] = []
        for r in raw {
            let semLines = r.sure("semester")
            let work = r.sure("workload")
            let workload = work.first.flatMap { CatalogRx.match(workloadValueRx, $0) }.flatMap { Int($0[1] ?? "") }
            var turnus = season(r.sure("freq").joined(separator: " "))
            if turnus == "unbekannt" && !r.unsure.contains("freq") {   // sonst aus den Angaben der Teilmodule
                let terms = parts(r.fields["content"] ?? []).map(\.term)
                let seasons = Set(terms.compactMap { $0 })
                if !terms.isEmpty && !terms.contains(nil) { turnus = seasons.count > 1 ? "WS+SS" : (seasons.first ?? "unbekannt") }
            }
            var pre: [String] = []
            for ref in all(moduleRefRx, (r.sure("prereq") + r.sure("admission")).joined(separator: " ")) {
                for n in all(numberRx, ref.groups[1] ?? "") {
                    if let id = byNumber[Int(n.groups[0] ?? "") ?? -1], id != r.id, !pre.contains(id) { pre.append(id) }
                }
            }
            let isFinal = CatalogRx.search(finalRx, r.title.lowercased()) != nil
            moduleJSON.append(.object([
                .init("id", .string(r.id)), .init("title", .string(StudyCatalogText.prefix(r.title, maxText))), .init("code", .null),
                .init("area", .null), .init("kind", .string(isFinal ? "abschluss" : "pflicht")), .init("lp", num(lp(r.sure("lp")))),
                .init("semester", (semLines.isEmpty ? nil : semester(semLines.joined(separator: " "))).map { .int(String($0)) } ?? .null),
                .init("turnus", .string(turnus)), .init("exam", str(fact(r.sure("exam")))), .init("coursework", str(fact(r.sure("coursework")))),
                .init("prerequisites", .array(pre.map { .string($0) })), .init("language", .null),
                .init("workload_h", workload.map { .int(String($0)) } ?? .null), .init("source_page", .int(String(r.page))),
            ]))
            func text(_ k: String) -> String? { let s = (r.fields[k] ?? []).joined(separator: "\n"); return s.isEmpty ? nil : s }
            textJSON.append(.init(r.id, .object([.init("content", str(text("content"))), .init("goals", str(text("goals"))), .init("literature", .null)])))
        }
        func pick(_ own: String, _ other: String?) -> PyJSON { own.isEmpty ? str(other) : .string(own) }
        let catalog = PyJSON.object([
            .init("v", .int("1")), .init("university", .string(meta.university)), .init("program", pick(meta.program, h.program)),
            .init("degree", pick(meta.degree, h.degree)), .init("po", pick(meta.po, h.po)),
            .init("catalog_term", .string(meta.catalogTerm.isEmpty ? (h.catalogTerm ?? "") : meta.catalogTerm)),
            .init("code", .string(meta.code)), .init("regular_semesters", meta.regularSemesters.map { .int(String($0)) } ?? .null),
            .init("total_lp", num(meta.totalLP ?? h.totalLP)),
            .init("source", .object([.init("url", str(meta.sourceURL)), .init("fetched_at", str(meta.fetchedAt)), .init("sha256", str(meta.sha256))])),
            .init("areas", .array([])), .init("modules", .array(moduleJSON)),
        ])
        return ParsedStudyCatalog(catalog: catalog, texts: .object(textJSON))
    }

    /// Angaben, die das geteilte Katalogformat nicht traegt (`hildesheim_sto_details`): {modul_id: {number, sws, parts}}
    /// mit der Modulnummer, den Semesterwochenstunden (Zahl oder null) und den Teilmodulen [{number, title, kind, sws,
    /// lp, term}] (kind z. B. "Seminar", term "WS", "SS", "WS+SS" oder null). ids wie in `parse`.
    public static func details(pages: [String]) -> PyJSON {
        .object(modules(pages).map { r in
            let sws = r.sure("sws").first.flatMap { CatalogRx.match(swsValueRx, $0) }.map { decimal($0[1] ?? "") }
            return .init(r.id, .object([.init("number", .int(String(r.number))), .init("sws", StudyCatalogParser.num(sws)),
                                        .init("parts", .array(parts(r.fields["content"] ?? []).map(\.json)))]))
        })
    }
}
