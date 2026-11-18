import Foundation

/// Klausur und Loesung zusammenfuehren wie app/exam_pairs.py: eine Regel fuer die Anzeige (Block "Klausuren &
/// Altklausuren" im Moduldetail, `LocalModules.detail`) und fuer den Aufgabenindex der Wochentests
/// (`Weekly.linkSolutions`), 17.11.2026.
/// - `links(files)`: zu jeder Aufgabendatei eines Moduls ihre Loesungsdatei(en), ueber Dateiname und Ordner
/// - `groups(files, found)`: Klausuren und Loesungen eines Blocks nach Jahrgang, neuester zuerst; jede Klausur mit
///   ihrer Loesung direkt darunter, Sammel-Loesungen und Loesungen ohne erkannte Klausur am Ende ihres Jahrgangs
/// Dieselben Muster in derselben Reihenfolge wie Python; gegen Python geprueft mit
/// packages/shared-contracts/fixtures/local-backend/exam-pairs.json (`ExamPairsTests`).
public enum ExamPairs {
    // MARK: Schluessel

    /// `SOL_PIECE`: "sol" als eigenes Wortstueck vor einer Nummer, vor "_" oder "." oder am Ende ("sol1b.pdf",
    /// "kk1_sol.pdf"), nie mitten im Wort ("Solar", "Konsole", "Sol-Gel"); auch fuer `StudyClassify.solution`
    static let solPiece = #"(?<![a-zäöüß])sol(?=[ _\-]?\d|[_.]|$)"#
    static let ext = PyRegex(#"\.[a-z0-9]+$"#)
    /// `SOL_WORDS`: was aus dem Dateinamen faellt, bevor Aufgabe und Loesung verglichen werden: Loesungswoerter,
    /// Fuellwoerter als eigenes Wort ("Lösungen zu PK" -> "pk") und Trennzeichen
    static let solWords = PyRegex(#"musterl(ö|oe)sung(en)?|l(ö|oe)sung(en)?|l(ö|oe)s\b|lsg|solutions?|"# + solPiece
        + #"|(?<![a-zäöüß])(zu[rm]?|f(ü|ue)r|von)(?![a-zäöüß])|mit|und|_|-|\s|\(|\)"#)
    /// `PAPER`: Papierformat vorn oder hinten ("A4-Loesung-Klausur-WS2122")
    static let paper = PyRegex(#"^a[345][ _\-]+|[ _\-]+a[345]$"#)
    /// `ID_TAIL`: "kk1b" -> "1b": Buchstaben, dann die Kennung ab der ersten Ziffer
    static let idTail = PyRegex(#"^[a-zäöüß]+(\d.*)$"#)
    static let digitRuns = PyRegex(#"\d+"#)

    /// `stem(name)`
    static func stem(_ name: String?) -> String { ext.sub(PyText.lower(name ?? "")) }

    /// `solution_key(name)`
    static func solutionKey(_ name: String?) -> String { solWords.sub(stem(name)) }

    /// `plain_key(name)`: Schluessel ohne Papierformat am Rand, sonst stoert die 4 aus "A4" den Zahlenvergleich. Nur
    /// wenn genug Name uebrig bleibt: "A4.pdf" und "A4_lsg.pdf" (Aufgabe 4) behalten ihren Schluessel "a4".
    static func plainKey(_ name: String?) -> String {
        let k = solWords.sub(paper.sub(stem(name)))
        return PyText.length(k) >= 4 ? k : solutionKey(name)
    }

    /// `numbers(key)`: Nummern im Schluessel ("übungsblatt10" -> [10]); der Teilwort-Rueckfall darf "Blatt 1" nie mit
    /// "Blatt 10" verbinden (Audit P49-06, 08.11.2026)
    static func numbers(_ key: String) -> [Int] { digitRuns.findAll(key).compactMap(PyText.int(digits:)) }

    /// Kennung aus `ID_TAIL`; nil ohne
    static func tail(_ key: String) -> String? { idTail.match(key)?.group(1) }

    // MARK: links

    /// `folder_of(f)`: Kurs und Stud.IP-Ordner (derselbe Ordnername in zwei Kursen ist nicht derselbe Ordner)
    public struct Folder: Hashable {
        public var course: String?
        public var name: String

        init(_ f: [String: JSONValue]) {
            course = f["course_id"]?.string
            name = f["studip_folder"]?.string ?? ""
        }
    }

    /// Art des Treffers in `links`
    public static let name = "name", ident = "kennung", whole = "sammel", module = "modul"

    /// Loesungsdateien einer Aufgabendatei
    public struct Link: Equatable {
        public var kind: String
        public var files: [String]
    }

    private static func id(_ f: [String: JSONValue]) -> String { f["id"]?.string ?? "" }

    /// `links(files)`: Loesungsdateien je Aufgabendatei; Dateien ohne Loesung fehlen. `files`: Dateien eines Moduls
    /// mit id, name, course_id, studip_folder und doc_type ("loesung" = Loesung, alles andere = Aufgabendatei,
    /// "klausur" = Klausur). Reihenfolge, der erste Treffer gilt:
    /// 1. `name`: gleicher Ordner (Kurs + Stud.IP-Ordner), gleicher Name ohne Loesungswort oder Teilwort mit gleichen Zahlen
    /// 2. `ident`: gleicher Ordner, gleiche Kennung ("kk1b.pdf" und "sol1b.pdf"); nur wenn im Ordner genau eine
    ///    Aufgabendatei und genau eine Loesungsdatei diese Kennung haben
    /// 3. `whole`: gleicher Ordner, Sammeldatei ("Lösungen.pdf" neben den Klausuren): nur Klausuren, nur mit
    ///    Ordnernamen, nur wenn es im Ordner genau eine Sammeldatei gibt
    /// 4. `module`: ganzes Modul wie vor dem 17.11.2026, aber nie ueber Jahrgaenge hinweg
    public static func links(_ files: [[String: JSONValue]]) -> [String: Link] {
        let sols = files.filter { $0["doc_type"]?.string == "loesung" }
        let tasks = files.filter { $0["doc_type"]?.string != "loesung" }
        if sols.isEmpty { return [:] }
        var key: [String: String] = [:], plain: [String: String] = [:]
        for f in files {
            key[id(f)] = solutionKey(f["name"]?.string)
            plain[id(f)] = plainKey(f["name"]?.string)
        }
        var terms: [String: Term] = [:]
        for s in sols { terms[id(s)] = term(folder: s["studip_folder"]?.string, name: s["name"]?.string) }

        struct TableID: Hashable {
            var folder: Folder?
            var plain: Bool
        }
        struct Table { var keys: [String] = [], byKey: [String: [String]] = [:] }
        var tables: [TableID: Table] = [:]
        /// Loesungsdateien zum Schluessel der Datei: gleicher Schluessel, sonst Teilwort mit gleichen Zahlen
        func named(_ tid: String, _ folder: Folder?, plain usePlain: Bool) -> [String]? {
            let table = TableID(folder: folder, plain: usePlain)
            let field = usePlain ? plain : key
            if tables[table] == nil {
                var t = Table()
                for s in sols where folder == nil || Folder(s) == folder {
                    let k = field[id(s)] ?? ""
                    if t.byKey[k] == nil { t.keys.append(k) }
                    t.byKey[k, default: []].append(id(s))
                }
                tables[table] = t
            }
            let t = tables[table]!, k = field[tid] ?? ""
            if let hit = t.byKey[k] { return hit }
            return t.keys.first { kk in
                !kk.isEmpty && !k.isEmpty && (PyText.contains(k, kk) || PyText.contains(kk, k))
                    && min(PyText.length(kk), PyText.length(k)) >= 4 && numbers(kk) == numbers(k)
            }.flatMap { t.byKey[$0] }
        }

        struct FolderTail: Hashable {
            var folder: Folder
            var tail: String
        }
        var solFiles: [Folder: [String: [String]]] = [:], taskFiles: [FolderTail: [String]] = [:]
        for s in sols { solFiles[Folder(s), default: [:]][key[id(s)] ?? "", default: []].append(id(s)) }
        for t in tasks {
            if let tl = tail(key[id(t)] ?? "") { taskFiles[FolderTail(folder: Folder(t), tail: tl), default: []].append(id(t)) }
        }

        var out: [String: Link] = [:]
        for t in tasks {
            let tid = id(t), folder = Folder(t)
            if let hit = named(tid, folder, plain: false) ?? named(tid, folder, plain: true) {
                out[tid] = Link(kind: name, files: hit)
                continue
            }
            if let tl = tail(key[tid] ?? ""), let twins = solFiles[folder]?[tl], twins.count == 1,
               taskFiles[FolderTail(folder: folder, tail: tl)]?.count == 1 {
                out[tid] = Link(kind: ident, files: twins)
                continue
            }
            if t["doc_type"]?.string == "klausur", !folder.name.isEmpty, let all = solFiles[folder]?[""], all.count == 1 {
                out[tid] = Link(kind: whole, files: all)
                continue
            }
            if var hit = named(tid, nil, plain: false) ?? named(tid, nil, plain: true) {
                let own = term(folder: t["studip_folder"]?.string, name: t["name"]?.string)
                hit = hit.filter { own == nil || terms[$0] == nil || terms[$0] == own }
                if !hit.isEmpty { out[tid] = Link(kind: module, files: hit) }
            }
        }
        return out
    }

    // MARK: Jahrgang

    /// Jahrgang einer Datei: hoeherer Rang = neuer
    public struct Term: Equatable {
        public var rank: Int
        public var label: String
    }

    /// `TERM`: Semester im Ordner oder Namen ("WS 20/21", "WS25/26", "WiSe 2022/23", "SoSe 23", "SS2023"); mitten im
    /// Namen nur gross geschrieben nach Kleinbuchstabe oder Ziffer ("KK1aWS2425lsg"), nie "abschluss2023", "news24"
    static let termRE = PyRegex(#"(?:(?<![A-Za-zÄÖÜäöüß])([Ww][Ii][Ss][Ee]|[Ww][Ss]|[Ss][Oo][Ss][Ee]|[Ss][Ss])|(?<=[a-z0-9äöüß])(WiSe|WS|SoSe|SS))"#
        + #"([ _'\-]?)([0-9]{2,4})(?![0-9])"#)
    /// `TERM_WORD` (auf Kleinschreibung)
    static let termWord = PyRegex(#"(?<![a-zäöüß])(winter|sommer)(?:semester)?([ _'\-]?)([0-9]{2,4})(?![0-9])"#)
    /// `YEAR`: "Klausur_2019.pdf"
    static let year = PyRegex(#"(?<![0-9])(19[89][0-9]|20[0-4][0-9])(?![0-9])"#)
    static let anyExt = PyRegex(#"\.[A-Za-z0-9]+$"#)

    private static func term(winter: Bool, year: Int) -> Term {
        winter ? Term(rank: year * 2 + 1, label: String(format: "WS %02d/%02d", year % 100, (year + 1) % 100))
               : Term(rank: year * 2, label: String(format: "SS %02d", year % 100))
    }

    /// `_term_of(winter, gap, digits)`: "23", "2023", bei Winter auch "2324". "2021" direkt am Wort ("WS2021") ist das
    /// Paar 20/21, mit Abstand ("WS 2021") das Jahr. nil, wenn die Ziffern kein Jahr sind.
    private static func termOf(winter: Bool, gap: String, digits: String) -> Term? {
        let n = digits.count
        guard let all = Int(digits), let head = Int(digits.prefix(2)) else { return nil }
        let pair = n == 4 && winter && (Int(digits.suffix(2)) ?? -1) == (head + 1) % 100
        let year4 = n == 4 && (1990...2049).contains(all)
        if n == 2 || (pair && !(year4 && !gap.isEmpty)) { return term(winter: winter, year: (head >= 90 ? 1900 : 2000) + head) }
        if year4 { return term(winter: winter, year: all) }
        return nil
    }

    /// `_terms(text)`: alle Jahrgaenge in der Reihenfolge des Textes: Semester, sonst ausgeschriebenes Semester, sonst Jahr
    private static func terms(_ text: String) -> [Term] {
        var out = termRE.matches(text).compactMap { m -> Term? in
            let word = PyText.lower(m.group(1) ?? m.group(2) ?? "")
            return termOf(winter: word == "ws" || word == "wise", gap: m.group(3) ?? "", digits: m.group(4) ?? "")
        }
        if out.isEmpty {
            out = termWord.matches(PyText.lower(text)).compactMap { m in
                termOf(winter: m.group(1) == "winter", gap: m.group(2) ?? "", digits: m.group(3) ?? "")
            }
        }
        if out.isEmpty {
            out = year.matches(text).compactMap { m in m.group(1).flatMap { y in Int(y).map { Term(rank: $0 * 2, label: y) } } }
        }
        return out
    }

    /// `term(folder, name)`: der letzte Jahrgang im Ordnerpfad ("Alte Klausuren/WS 22/23" -> "WS 22/23"), sonst der
    /// erste im Namen ohne Endung ("KK1aWS2425lsg.pdf" -> "WS 24/25"); nil ohne Jahrgang
    public static func term(folder: String?, name: String?) -> Term? {
        if let t = terms(folder ?? "").last { return t }
        return terms(anyExt.sub(name ?? "")).first
    }

    // MARK: groups

    public static let exam = "klausur", solution = "loesung", extra = "weitere_loesung"
    static let noFolder = "Ohne Ordner"
    static let nameParts = PyRegex(#"[0-9]+|[^0-9]+"#)

    /// `_by_name(f)`: Reihenfolge nach Name wie von Hand sortiert: Zahlen nach ihrem Wert ("KK2" vor "KK10"), sonst
    /// Kleinschreibung; dann der Name selbst und die ID
    private struct NameKey {
        var parts: [(Int, Int, String)], name: String, id: String

        init(_ f: [String: JSONValue]) {
            name = f["name"]?.string ?? ""
            id = f["id"]?.string ?? ""
            parts = ExamPairs.nameParts.findAll(PyText.lower(name)).map { x in
                guard let first = x.unicodeScalars.first, ("0"..."9").contains(first) else { return (1, 0, x) }
                let d = String(String.UnicodeScalarView(x.unicodeScalars.drop { $0 == "0" }))
                return (0, d.unicodeScalars.count, d)
            }
        }

        static func less(_ a: NameKey, _ b: NameKey) -> Bool {
            for (x, y) in zip(a.parts, b.parts) {
                if x.0 != y.0 { return x.0 < y.0 }
                if x.1 != y.1 { return x.1 < y.1 }
                if PyText.less(x.2, y.2) { return true }
                if PyText.less(y.2, x.2) { return false }
            }
            if a.parts.count != b.parts.count { return a.parts.count < b.parts.count }
            if PyText.less(a.name, b.name) { return true }
            if PyText.less(b.name, a.name) { return false }
            return PyText.less(a.id, b.id)
        }
    }

    private static func byName(_ files: [[String: JSONValue]]) -> [[String: JSONValue]] {
        files.map { (NameKey($0), $0) }.sorted { NameKey.less($0.0, $1.0) }.map(\.1)
    }

    /// Gruppe einer Datei: Jahrgaenge zuerst (neuester vorn), dann Ordner nach Name, zuletzt Dateien ohne Ordner
    private struct GroupKey: Hashable {
        var a: Int, b: Int, c: String, label: String

        init(_ f: [String: JSONValue]) {
            if let t = ExamPairs.term(folder: f["studip_folder"]?.string, name: f["name"]?.string) {
                (a, b, c, label) = (0, -t.rank, t.label, t.label)
            } else {
                label = f["studip_folder"]?.string ?? ""
                (a, b, c) = (label.isEmpty ? 2 : 1, 0, PyText.lower(label))
            }
        }

        static func less(_ x: GroupKey, _ y: GroupKey) -> Bool {
            if x.a != y.a { return x.a < y.a }
            if x.b != y.b { return x.b < y.b }
            if PyText.less(x.c, y.c) { return true }
            if PyText.less(y.c, x.c) { return false }
            return PyText.less(x.label, y.label)
        }
    }

    /// `groups(files, found)`: Klausuren und Loesungen eines Blocks nach Jahrgang: [{"label", "files"}], neuester
    /// Jahrgang zuerst, danach die Dateien ohne Jahrgang je Ordner, zuletzt die ohne Ordner. In einer Gruppe steht jede
    /// Klausur (nach Name) mit ihrer Loesung direkt darunter (`exam_role` "loesung", `solution_of` = ID der Klausur),
    /// am Ende die Sammel-Loesungen und die Loesungen ohne erkannte Klausur (`exam_role` "weitere_loesung"). Eine
    /// Klausur ohne Loesung steht allein. Jede Datei steht genau einmal da, keine verschwindet.
    /// `files`: Dateien des Blocks mit doc_type "klausur" oder "loesung"; `found`: `links` ueber die Dateien des Moduls.
    public static func groups(_ files: [[String: JSONValue]], _ found: [String: Link]) -> [JSONValue] {
        let exams = byName(files.filter { $0["doc_type"]?.string == "klausur" })
        let sols = byName(files.filter { $0["doc_type"]?.string == "loesung" })
        let solIDs = Set(sols.map(id))
        var out: [GroupKey: [JSONValue]] = [:]
        func add(_ f: [String: JSONValue], role: String, of examID: String?) {
            var row = f
            row["exam_role"] = .string(role)
            row["solution_of"] = examID.map { .string($0) } ?? .null
            out[GroupKey(f), default: []].append(.object(row))
        }
        // erst die sicheren Paare aus dem eigenen Ordner, dann die ueber das ganze Modul: jede Loesung steht nur einmal
        var owner: [String: String] = [:]
        for kinds in [[name, ident], [module]] {
            for e in exams {
                guard let link = found[id(e)], kinds.contains(link.kind) else { continue }
                for sid in link.files where solIDs.contains(sid) && owner[sid] == nil { owner[sid] = id(e) }
            }
        }
        for e in exams {
            add(e, role: exam, of: nil)
            // die Loesung steht in der Gruppe ihrer Klausur
            for s in sols where owner[id(s)] == id(e) {
                var row = s
                row["exam_role"] = .string(solution)
                row["solution_of"] = .string(id(e))
                out[GroupKey(e), default: []].append(.object(row))
            }
        }
        for s in sols where owner[id(s)] == nil { add(s, role: extra, of: nil) }
        return out.keys.sorted(by: GroupKey.less).map { k in
            .object(["label": .string(k.label.isEmpty ? noFolder : k.label), "files": .array(out[k]!)])
        }
    }
}
