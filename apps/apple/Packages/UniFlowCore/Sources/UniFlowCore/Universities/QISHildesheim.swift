import Foundation

// Notenspiegel des LSF Hildesheim (gleiche HIS-QIS-Software wie an der LUH, anderer Tabellenaufbau), Regeln wie
// qis.parse_grade_rows und Test test_grade_rows_hildesheim_layout:
//  - vor der Kopfzeile steht eine Zeile "Abschluss: ..."; die Kopfzeile darf irgendwo in der Tabelle stehen,
//    mehrere Abschluesse in einer Tabelle
//  - Spalten "Pruefungsnr." (mit Punkt), "Bezeichnung der Leistung / der Lehrveranstaltung", "Note", "Status",
//    "Bonus" (= LP)
//  - Modulzeilen ohne Note und Status sowie Zeilen "Pruefung vorhanden" sind keine Leistungen
// Die LUH-Regeln (QISParser.grades) bleiben unveraendert. Stammdaten werden nie gelesen: Stammdaten-Tabellen
// verwirft schon QISPage.parse, einzelne Stammdaten-Zeilen ueberspringt diese Auswertung zusaetzlich.

/// Aufbau des Notenspiegels je Hochschule.
public enum QISGradeLayout: String, Sendable, Hashable, Codable {
    /// QIS der LUH (QISParser.grades, Kopfzeile in den ersten Zeilen)
    case luh
    /// LSF Hildesheim (qis.parse_grade_rows)
    case hildesheim
}

extension QISPage {
    /// Leistungen aller Tabellen der Seite nach dem Aufbau der Hochschule (LUH unveraendert).
    public func grades(abschluss: String = "", layout: QISGradeLayout) -> [QISGrade] {
        switch layout {
        case .luh: return grades(abschluss: abschluss)
        case .hildesheim:
            return QISParser.merge(tables.flatMap { QISParser.parseGradeRows($0.rows.map { $0.map(\.text) }, abschluss: abschluss) })
        }
    }

    /// Anzahl der Tabellen mit Leistungs-Kopfzeile nach dem Aufbau der Hochschule.
    public func gradeTableCount(layout: QISGradeLayout) -> Int {
        switch layout {
        case .luh: return gradeTableCount
        case .hildesheim:
            return tables.filter { t in t.rows.contains { QISParser.isGradeHeader(QISParser.pyHeaderMap($0.map(\.text))) } }.count
        }
    }
}

extension QISParser {
    /// GRADE_HEADERS aus qis.py (erstes Wort der Spalte) samt den Schreibweisen ohne Umlaut.
    static let pyGradeHeaders: [String: String] = [
        "bezeichnung": "text", "leistung": "text", "prüfungsnr": "pruefungsnr", "pruefungsnr": "pruefungsnr",
        "nr": "pruefungsnr", "prüfungstext": "text", "pruefungstext": "text", "text": "text", "semester": "semester",
        "note": "note", "status": "status", "credits": "credits", "ects": "credits", "bonus": "credits",
        "versuch": "versuch", "vermerk": "status", "datum": "datum", "prüfungsdatum": "datum", "pruefungsdatum": "datum",
    ]

    /// Wie `qis._header_map`: alles ausser Buchstaben (auch Umlaute), Ziffern und "_" wird zu Leerzeichen, erstes Wort.
    static func pyHeaderMap(_ cells: [String]) -> [String?] {
        cells.map { h in
            let lower = h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().precomposedStringWithCanonicalMapping
            let spaced = String(lower.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : " " })
            return spaced.split(separator: " ").first.flatMap { pyGradeHeaders[String($0)] }
        }
    }

    static func isGradeHeader(_ keys: [String?]) -> Bool { keys.contains("text") && keys.contains("note") }

    /// Stammdaten-Zeile (Matrikelnummer, Geburtsdatum, Anschrift ...): nie auswerten.
    static func isStammdatenRow(_ cells: [String]) -> Bool {
        let labels = ["matrikelnummer", "matrikelnr", "geburtsdatum", "geburtsort", "anschrift"]
        return cells.contains { c in let l = c.lowercased(); return labels.contains { l.hasPrefix($0) } }
    }

    /// Wie `qis.parse_grade_rows`: Zellentexte der Zeilen einer Tabelle -> Leistungen.
    public static func parseGradeRows(_ rows: [[String]], abschluss: String = "") -> [QISGrade] {
        var out: [QISGrade] = []
        var mapped: [String?]?
        var ab = abschluss
        for raw in rows {
            let cells = raw.map(clean)
            guard !isStammdatenRow(cells) else { continue }
            let joined = cells.filter { !$0.isEmpty }.joined(separator: " ")
            if joined.lowercased().hasPrefix("abschluss:") {
                let m = LearnwebParsing.firstMatch(#"(Abschluss:.*?PO-Version:\s*\d+)"#, in: joined, caseless: true)?.groups[0]
                ab = String((m ?? joined).prefix(160))
                mapped = nil
                continue
            }
            let hm = pyHeaderMap(cells)
            if isGradeHeader(hm) {
                mapped = hm
                continue
            }
            guard let keys = mapped, cells.count >= 3 else { continue }
            var rec: [String: String] = [:]
            for (k, v) in zip(keys, cells) { if let k, rec[k] == nil { rec[k] = v } }
            let note = rec["note"] ?? "", status = rec["status"] ?? ""
            if status.lowercased() == "prüfung vorhanden", note.isEmpty { continue }   // Modul-/Kontozeile
            guard let text = rec["text"], !text.isEmpty, !note.isEmpty || !status.isEmpty else { continue }
            out.append(QISGrade(pruefungsnr: rec["pruefungsnr"], text: text, semester: rec["semester"], note: rec["note"],
                                status: rec["status"], credits: rec["credits"], versuch: rec["versuch"], datum: rec["datum"],
                                abschluss: ab, raw: cells.joined(separator: " | ")))
        }
        return out
    }
}
