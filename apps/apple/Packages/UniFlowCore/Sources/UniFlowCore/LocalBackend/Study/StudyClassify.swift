import Foundation

/// Einordnung ohne KI wie app/study.py (docs/IPAD-OHNE-PC.md, S4):
/// - `effectiveType`: Dokumenttyp aus Stud.IP-Ordner und Dateiname (schlaegt die KI-Einschaetzung, wenn eindeutig)
/// - `weekHint`: Lehrwoche aus Dateiname/Ordner ("Blatt 3", "VL03", "02A")
/// Fach und Art eines Kurses (`studip_sync.classify`) stehen mit den uebrigen Regeln aller Quellen in `UniRules`.
/// Dieselben Muster in derselben Reihenfolge; `PyRegex` sorgt fuer dieselbe Bedeutung wie Pythons `re`.
/// Gegen Python geprueft mit packages/shared-contracts/fixtures/local-backend/study-modules.json.
public enum StudyClassify {
    // MARK: study.effective_type

    /// Bezeichnungen fuer die Einschaetzung der KI (`lab` in effective_type)
    public static let typeLabels = ["vorlesung": "Vorlesung", "uebung": "Übung", "loesung": "Lösung", "skript": "Skript",
                                    "klausur": "Klausur", "organisatorisch": "Organisatorisches"]

    private static let orga = PyRegex("klausurergebnis|raumverteilung|organisat|termine|ankuendigung|ankündigung")
    private static let solution = PyRegex(#"l(ö|oe)s|\blsg\b|_lsg|lsg\.|solution|musterl"#)
    private static let examSolution = PyRegex(#"klausur|kurztest|\bkk\d|\bgk\d?"#)
    private static let exam = PyRegex(#"alte klausur|altklausur|probeklausur|klausur|kurztest|\bkk\d|\bgk\d?\b|exam"#)
    private static let oldExam = PyRegex(#"alte klausur|altklausur|\bws ?\d|\bss ?\d"#)
    private static let groupExercise = PyRegex(#"gruppen(ü|ue)bung|\bg(ü|ue|u)\d"#)
    private static let hallExercise = PyRegex(#"h(ö|oe)rsaal|zentral(ü|ue)bung|\bz(ü|ue)\d|\bh(ü|ue)\d|\bhu\d"#)
    private static let tutorial = PyRegex(#"tutorium|\btut\d"#)
    private static let exercise = PyRegex(#"(ü|ue)bung|blatt|\bueb\d|\bub\d|exercise|aufgaben|sheet"#)
    private static let notes = PyRegex("mitschrift")
    private static let lectureWords = PyRegex("vorlesung|folien")
    private static let script = PyRegex("skript|script")
    private static let lecture = PyRegex(#"vorlesung|folien|slides|\bvl\d|lecture"#)

    /// `effective_type(name, folder, ai_type) -> (doc_type, label)`; label z. B. "Gruppenübung", "Altklausur".
    public static func effectiveType(name: String?, folder: String?, aiType: String?) -> (type: String, label: String) {
        let fl = PyText.lower("\(folder ?? "") / \(name ?? "")")
        let nm = PyText.lower(name ?? "")
        if orga.found(in: fl) { return ("organisatorisch", "Organisatorisches") }
        if solution.found(in: nm) { return ("loesung", examSolution.found(in: fl) ? "Klausur-Lösung" : "Lösung") }
        if exam.found(in: fl) { return ("klausur", oldExam.found(in: fl) ? "Altklausur" : "Klausur") }
        if groupExercise.found(in: fl) { return ("uebung", "Gruppenübung") }
        if hallExercise.found(in: fl) { return ("uebung", "Hörsaalübung") }
        if tutorial.found(in: fl) { return ("uebung", "Tutorium") }
        if exercise.found(in: fl) { return ("uebung", "Übung") }
        if notes.found(in: fl), !lectureWords.found(in: fl) { return ("skript", "Mitschrift") }
        if script.found(in: fl) { return ("skript", "Skript") }
        if lecture.found(in: fl) { return ("vorlesung", "Vorlesung") }
        let t = (aiType?.isEmpty ?? true) ? "sonstiges" : aiType!                      // ai_type or "sonstiges"
        return (t, typeLabels[t] ?? "Sonstiges")
    }

    // MARK: study.week_hint

    private static let extensionSuffix = PyRegex(#"\.[a-z0-9]+$"#)
    private static let weekWord = PyRegex(#"(?:woche|kw|blatt|(?:ü|ue|u)bung|ueb|aufgabenblatt|serie|vl|vorlesung|folien|kapitel|kap|gu|g(?:ü|ue)|z(?:ü|ue)|h(?:ü|ue)|hu|tut)[ _\-]*0?(\d{1,2})(?!\d)"#)
    private static let bareNumber = PyRegex(#"^0?(\d{1,2})[a-z]?$"#)
    private static let leadingZero = PyRegex(#"(?<!\d)0(\d)(?!\d)"#)

    /// `week_hint(name, folder)`: Wochennummer aus Dateiname/Ordner ('Blatt 3', 'ueb2', 'GU01', '02A', 'VL03',
    /// 'Woche 4'); nil, wenn unklar.
    public static func weekHint(name: String?, folder: String?) -> Int? {
        let stem = extensionSuffix.sub(PyText.lower(name ?? ""))
        for src in [stem, PyText.split(PyText.lower(folder ?? ""), "/").last ?? ""] {
            if let m = weekWord.search(src), let n = m.group(1).flatMap(PyText.int(digits:)), (1...16).contains(n) { return n }
        }
        if let m = bareNumber.match(stem), let n = m.group(1).flatMap(PyText.int(digits:)), (1...16).contains(n) { return n }   // '02A', '01B'
        if let m = leadingZero.search(stem), let n = m.group(1).flatMap(PyText.int(digits:)), (1...9).contains(n) { return n }   // 'Prog1-01-Intro' -> 1
        return nil
    }

    // MARK: study.enrich_file

    /// Arten mit Lehrwoche aus Name/Ordner (`week_hint`); bei allen anderen ist die Woche nur die der Aenderung
    public static let lectureWeekTypes: Set<String> = ["vorlesung", "uebung", "loesung", "skript"]

    /// `enrich_file(f)`: `ai_doc_type` = Einschaetzung aus `analysis`, `doc_type`/`sub_label` aus `effectiveType`,
    /// `week_hint` nur fuer Vorlesung, Uebung, Loesung und Skript (`lectureWeekTypes`), `source` aus `fileSource`.
    public static func enrichFile(_ f: [String: JSONValue]) -> [String: JSONValue] {
        var out = f
        let ai = f["doc_type"] ?? .null
        let (t, label) = effectiveType(name: f["name"]?.string, folder: f["studip_folder"]?.string, aiType: ai.string)
        out["ai_doc_type"] = ai
        out["doc_type"] = .string(t)
        out["sub_label"] = .string(label)
        let hint = lectureWeekTypes.contains(t) ? weekHint(name: f["name"]?.string, folder: f["studip_folder"]?.string) : nil
        out["week_hint"] = hint.map { .number(Double($0)) } ?? .null
        out["source"] = .string(fileSource(f))
        return out
    }

    // MARK: study.file_source

    /// `file_source(f)`: Herkunft einer Datei fuer die Geraete: "own" (eigenes Dokument, Kurs `__user__`), "learnweb"
    /// (IDs "lw-..." oder pluginfile.php in der Adresse, wie filestream.is_learnweb) oder "studip". Vergleiche nach
    /// Codepunkten wie Python (`startswith`, `in`); fehlt `download_url` in der Zeile (`_file_rows`), zaehlt nur die ID.
    public static func fileSource(_ f: [String: JSONValue]) -> String {
        if case .string(let course)? = f["course_id"], Array(course.unicodeScalars) == Array("__user__".unicodeScalars) {
            return "own"
        }
        let id = LocalModules.truthy(f["id"]) ? (f["id"]?.string ?? f["id"]?.jsonString() ?? "") : ""
        let url = LocalModules.truthy(f["download_url"]) ? (f["download_url"]?.string ?? "") : ""
        if Array(id.unicodeScalars.prefix(3)) == Array("lw-".unicodeScalars) || PyText.contains(url, "pluginfile.php") {
            return "learnweb"
        }
        return "studip"
    }
}
