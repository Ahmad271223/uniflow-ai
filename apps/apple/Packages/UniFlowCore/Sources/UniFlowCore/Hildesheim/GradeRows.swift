import Foundation

/// Notenspiegel-Tabellen (HIS QIS/LSF) als Zeilen von Zellentexten -> Leistungen (`qis.parse_grade_rows`), die eine
/// Fassung im Kern. Gesammelt wird der Hildesheimer Notenspiegel ueber `LSFClient.grades` (Tabellenauswahl,
/// Stammdaten-Schutz `QISParser.isStammdaten`, Reiter der Studiengaenge); `QISPage` (QIS der LUH, erst V2) liest
/// seine Tabellen ebenfalls hiermit.
/// Hildesheim: vor der Kopfzeile steht "Abschluss: ...", Spalten "Prüfungsnr." / "Bezeichnung der Leistung ...",
/// mehrere Abschluesse in einer Tabelle, Modulzeilen ohne Note/Status und "Prüfung vorhanden" sind keine Leistungen.
/// Stammdaten (Name, Anschrift, Matrikelnummer) stehen ausserhalb dieser Tabellen und werden nie gelesen; steht doch
/// eine Stammdaten-Zeile in einer Leistungstabelle, wird sie uebersprungen (zusaetzlich zu Python).
public enum GradeRows {

    static let headers: [String: String] = [
        "bezeichnung": "text", "leistung": "text", "prüfungsnr": "pruefungsnr", "nr": "pruefungsnr", "prüfungstext": "text",
        "text": "text", "semester": "semester", "note": "note", "status": "status", "credits": "credits", "ects": "credits",
        "bonus": "credits", "versuch": "versuch", "vermerk": "status", "datum": "datum", "prüfungsdatum": "datum",
        // LUH-Kopfzeile wie qis.GRADE_HEADERS (28.10.2026 am PC, fehlte hier: LP der Spalte "LP" wurden nicht gelesen) und
        // "PrfNr." wie auf der echten Seite "Info über angemeldete Prüfungen" (12.11.2026: ohne Nummer fielen
        // gleichnamige Leistungen eines Semesters beim Entfernen der Doppelten zusammen)
        "prfgnr": "pruefungsnr", "pnr": "pruefungsnr", "lp": "credits", "leistungspunkte": "credits", "cp": "credits",
        "kreditpunkte": "credits", "punkte": "credits", "prfnr": "pruefungsnr", "prüfungsnummer": "pruefungsnr",
        "pruefungsnr": "pruefungsnr",
        // abgekuerzte Koepfe anderer HIS-Fassungen (12.11.2026): "Sem.", "Prüfungssemester", "Vers.", "VS"
        "sem": "semester", "prüfungssemester": "semester", "vers": "versuch", "vs": "versuch",
    ]
    private static let nonWordRE = HText.regex("[^\\wäöüß]+")
    private static let abschlussRE = HText.regex("^(Abschluss:.*?PO-Version:\\s*\\d+)", [.caseInsensitive])

    /// Spalte der Pruefungsart (`qis.ART_HEADERS`): "Prf.Art" (echter LUH-Notenspiegel, 12.11.2026), "Prüfungsart", "Art"
    static let artHeaders: Set<[String]> = [["prf", "art"], ["prfart"], ["prüfungsart"], ["pruefungsart"], ["art"],
                                            ["prüfungs", "art"], ["pruefungs", "art"]]

    /// `qis._header_map`: erstes Wort jeder Spalte -> Feldname; "Prf.Art" -> art
    static func headerMap(_ cells: [String]) -> [String?] {
        cells.map { h in
            let words = HText.replace(nonWordRE, in: h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), with: " ")
                .split(separator: " ").map(String.init)
            if artHeaders.contains(words) { return "art" }
            return words.first.flatMap { headers[$0] }
        }
    }

    static func isHeader(_ map: [String?]) -> Bool { map.contains("text") && map.contains("note") }

    /// Stammdaten-Zeile (Matrikelnummer, Geburtsdatum, Anschrift ...): nie auswerten; die eine Liste, auch fuer ganze
    /// Tabellen (`QISParser.isStammdaten`)
    static func isStammdatenRow(_ cells: [String]) -> Bool {
        let labels = ["matrikelnummer", "matrikelnr", "geburtsdatum", "geburtsort", "anschrift"]
        return cells.contains { c in let l = c.lowercased(); return labels.contains { l.hasPrefix($0) } }
    }

    public static func parse(rows: [[String]], abschluss: String = "") -> [QISGrade] {
        var out: [QISGrade] = []
        var mapped: [String?]?
        var ab = abschluss
        for rawCells in rows {
            let cells = rawCells.map { HText.collapse($0) }
            guard !isStammdatenRow(cells) else { continue }
            let joined = cells.filter { !$0.isEmpty }.joined(separator: " ")
            if joined.lowercased().hasPrefix("abschluss:") {
                let found = HText.match(abschlussRE, joined)?.groups[1] ?? nil
                ab = String((found ?? joined).prefix(160))
                mapped = nil
                continue
            }
            let hm = headerMap(cells)
            if isHeader(hm) {
                mapped = hm
                continue
            }
            guard let map = mapped, cells.count >= 3 else { continue }
            var fields: [String: String] = [:]
            for (k, v) in zip(map, cells) {
                if let k, fields[k] == nil { fields[k] = v }
            }
            // Nummer in der ersten Spalte, Kopf unbekannt (qis.parse_grade_rows, 12.11.2026)
            if (fields["pruefungsnr"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty, let first = cells.first, !first.isEmpty,
               first.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) {
                fields["pruefungsnr"] = first
            }
            let note = fields["note"] ?? "", status = fields["status"] ?? ""
            if status.lowercased() == "prüfung vorhanden" && note.isEmpty { continue }
            // Konto-Zeilen des LSF (`lsfCells`) bleiben auch ohne Note und Status: sie trennen die Faecher
            guard let text = fields["text"], !text.isEmpty, !note.isEmpty || !status.isEmpty || text.hasPrefix(accountPrefix) else { continue }
            out.append(QISGrade(pruefungsnr: fields["pruefungsnr"], text: text, semester: fields["semester"], note: fields["note"],
                                status: fields["status"], credits: fields["credits"], versuch: fields["versuch"], datum: fields["datum"],
                                abschluss: ab, raw: cells.joined(separator: " | ")))
        }
        return out
    }

    // MARK: Echter Notenspiegel des LSF Hildesheim (26.11.2026)

    /// Text des Kontos (Summe eines Fachs oder aller Faecher) in einer Leistungszeile, wie HIS selbst es nennt
    /// ("Gesamtkonto studienbegleitender Prüfungen"); `GradesModel.isBereichText` erkennt die Zeile daran als Summe.
    public static let accountPrefix = "Gesamtkonto: "

    private static let numberRE = HText.regex(#"^\d+(,\d+)?$"#)

    /// Zellen einer Zeile des LSF-Notenspiegels, eine je Spalte (colspan aufgefaechert wie `QISPage.spread`). Eine
    /// Konto-Zeile (LP-Summe eines Fachs, "10 | Mathematik", "800 | Psychologie") erkennt man am Aufbau: Nummer in der
    /// ersten Zelle, die Bezeichnung reicht ueber zwei Spalten (echter Notenspiegel, 26.11.2026). Sie bekommt
    /// `accountPrefix` und bleibt damit beim Lesen erhalten, auch ohne Note und Status. Ohne sie haengte die
    /// Rechenlogik Teilleistungen des naechsten Fachs an das letzte bestandene Modul davor (4 LP fehlten).
    static func lsfCells(_ row: [HTMLTableCell]) -> [String] {
        var cells = QISPage.spread(row)
        if row.count >= 3, row[1].colspan >= 2, !row[1].isHeader, !row[1].text.lowercased().hasPrefix("gesamtkonto") {
            let nr = HText.collapse(row[0].text)
            if !nr.isEmpty, nr.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }), row[0].colspan == 1 {
                cells[1] = accountPrefix + HText.collapse(row[1].text)
            }
        }
        return cells
    }

    private static func filled(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Ausfuehrliche Zeile (Reiter des Studiengangs): mit Semester, Versuch oder Datum
    static func isDetailed(_ g: QISGrade) -> Bool { filled(g.semester) || filled(g.versuch) || filled(g.datum) }

    /// Der Notenspiegel des LSF Hildesheim nennt jede Leistung zweimal: in der Uebersicht kurz (Nr., Bezeichnung, Note,
    /// Status, Bonus) und auf dem Reiter des Studiengangs ausfuehrlich (dazu Semester, Pruefungsart, Versuch, Datum).
    /// Beide Fassungen zusammen zaehlten doppelt, weil die kurze ohne Versuch als Modulzeile gilt: am echten Konto
    /// 105 statt 51 LP (26.11.2026; das LSF nennt in seinen Konto-Zeilen selbst 51). Es bleibt die ausfuehrliche Zeile,
    /// die kurze nur, wenn es zur selben Leistung (Studiengang, Nummer, Bezeichnung) keine ausfuehrliche gibt.
    public static func preferDetailed(_ grades: [QISGrade]) -> [QISGrade] {
        func key(_ g: QISGrade) -> [String] { [g.abschluss ?? "", g.pruefungsnr ?? "", HText.collapse(g.text).lowercased()] }
        let detailed = Set(grades.filter(isDetailed).map(key))
        return grades.filter { isDetailed($0) || !detailed.contains(key($0)) }
    }

    /// Konto-Zeilen des LSF ("10 | Mathematik | 0,0 | | 17", "8992 | Vorläufige Gesamtnote aller Fächer | 3,45 | | 51"):
    /// die Summe der Leistungspunkte eines Fachs bzw. aller Faecher, keine Leistung. Sie fassen Spalten zusammen; ohne
    /// aufgefaecherte Zellen (so am 26.11.2026 auf dem iPad gespeichert) rutschen die Spalten: die LP stehen unter
    /// "Status", die Note unter "Semester". Erkannt wird beides: die verrutschte Zeile an der Zahl in der Status-Spalte,
    /// die gerade Zeile an "ohne Status, Note 0,0 oder Gesamtnote/Gesamtkonto im Text, LP als Zahl". Die Felder werden
    /// zurechtgerueckt und der Text bekommt `accountPrefix`, damit die Zeile ueberall als Summe gilt (nie als
    /// bestandene Leistung, nie als Modul einer Pruefung). Zeilen mit Versuch oder Datum sind immer Leistungen.
    public static func accounts(_ grades: [QISGrade]) -> [QISGrade] {
        func number(_ s: String?) -> String? {
            let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return HText.match(numberRE, t) != nil ? t : nil
        }
        func named(_ g: QISGrade, note: String?, credits: String) -> QISGrade {
            var out = g
            out.note = note
            out.semester = nil
            out.status = nil
            out.versuch = nil                 // leere Zellen des Reiters: Uebersicht und Reiter nennen dasselbe Konto
            // ohne Nummer: mehrere Faecher tragen dieselbe Konto-Nummer ("10"), die Rechenlogik hielte sie sonst fuer
            // dieselbe Zeile und liesse alle bis auf die erste fallen (`GradesModel.model`); so gilt die Bezeichnung
            out.pruefungsnr = nil
            // auch in der Rohzeile (die Rechenlogik fuellt fehlende Felder daraus): "10 | …" -> "Konto 10 | …"
            if let first = out.raw.unicodeScalars.first, first.value >= 48, first.value <= 57 { out.raw = "Konto " + out.raw }
            out.datum = nil
            out.credits = credits
            if !out.text.lowercased().hasPrefix("gesamtkonto") { out.text = accountPrefix + out.text }
            return out
        }
        return grades.map { g in
            guard !filled(g.versuch), !filled(g.datum) else { return g }
            // verrutscht: LP unter "Status", Note (falls vorhanden) unter "Semester"
            if let lp = number(g.status) { return named(g, note: number(g.semester) ?? (filled(g.note) ? g.note : nil), credits: lp) }
            // gerade: kein Status, kein Semester, LP als Zahl, Note 0,0 (Fach) oder eine Gesamtnote/ein Gesamtkonto laut Text
            guard !filled(g.status), !filled(g.semester), let lp = number(g.credits) else { return g }
            let text = g.text.lowercased()
            let zero = (g.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "0,0"
            guard zero || text.contains("gesamtnote") || text.hasPrefix("gesamtkonto") else { return g }
            return named(g, note: filled(g.note) ? g.note : nil, credits: lp)
        }
    }
}

/// Aufbau des Notenspiegels je Hochschule (`UniversityProfile.gradeLayout`, wie `qis.PROFILES` am PC).
public enum QISGradeLayout: String, Sendable, Hashable, Codable {
    /// QIS der LUH (`QISPage`, `QISCollector`, erst V2)
    case luh
    /// LSF Hildesheim (`LSFClient.grades` mit `GradeRows`, qis.parse_grade_rows)
    case hildesheim
    /// Hochschule Hannover: Leistungen in HISinOne (`HISinOne.grades`), sonst das alte QIS (icms) wie die LUH
    case hisinone

    /// Bescheinigungs-Links (verpublish) sammeln wie `qis.PROFILES[<uni>]["documents"]`: LUH ja, Hildesheim nein
    /// (der PC speichert dort keine Bescheinigungen und kein Transcript).
    public var collectsDocuments: Bool {
        switch self {
        case .luh: return true
        case .hildesheim, .hisinone: return false
        }
    }
}
