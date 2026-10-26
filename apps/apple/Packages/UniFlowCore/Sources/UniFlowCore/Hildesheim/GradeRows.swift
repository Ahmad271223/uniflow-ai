import Foundation

/// Notenspiegel-Tabellen (HIS QIS/LSF) als Zeilen von Zellentexten -> Leistungen (`qis.parse_grade_rows`), die eine
/// Fassung fuer das LSF Hildesheim (`LSFClient.grades`, `QISPage.grades(layout: .hildesheim)`).
/// Hildesheim: vor der Kopfzeile steht "Abschluss: ...", Spalten "Prüfungsnr." / "Bezeichnung der Leistung ...",
/// mehrere Abschluesse in einer Tabelle, Modulzeilen ohne Note/Status und "Prüfung vorhanden" sind keine Leistungen.
/// Stammdaten (Name, Anschrift, Matrikelnummer) stehen ausserhalb dieser Tabellen und werden nie gelesen; steht doch
/// eine Stammdaten-Zeile in einer Leistungstabelle, wird sie uebersprungen (zusaetzlich zu Python).
public enum GradeRows {

    static let headers: [String: String] = [
        "bezeichnung": "text", "leistung": "text", "prüfungsnr": "pruefungsnr", "nr": "pruefungsnr", "prüfungstext": "text",
        "text": "text", "semester": "semester", "note": "note", "status": "status", "credits": "credits", "ects": "credits",
        "bonus": "credits", "versuch": "versuch", "vermerk": "status", "datum": "datum", "prüfungsdatum": "datum",
    ]
    private static let nonWordRE = HText.regex("[^\\wäöüß]+")
    private static let abschlussRE = HText.regex("^(Abschluss:.*?PO-Version:\\s*\\d+)", [.caseInsensitive])

    /// `qis._header_map`: erstes Wort jeder Spalte -> Feldname
    static func headerMap(_ cells: [String]) -> [String?] {
        cells.map { h in
            let words = HText.replace(nonWordRE, in: h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), with: " ")
                .split(separator: " ")
            return words.first.flatMap { headers[String($0)] }
        }
    }

    static func isHeader(_ map: [String?]) -> Bool { map.contains("text") && map.contains("note") }

    /// Stammdaten-Zeile (Matrikelnummer, Geburtsdatum, Anschrift ...): nie auswerten
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
            let note = fields["note"] ?? "", status = fields["status"] ?? ""
            if status.lowercased() == "prüfung vorhanden" && note.isEmpty { continue }
            guard let text = fields["text"], !text.isEmpty, !note.isEmpty || !status.isEmpty else { continue }
            out.append(QISGrade(pruefungsnr: fields["pruefungsnr"], text: text, semester: fields["semester"], note: fields["note"],
                                status: fields["status"], credits: fields["credits"], versuch: fields["versuch"], datum: fields["datum"],
                                abschluss: ab, raw: cells.joined(separator: " | ")))
        }
        return out
    }
}

/// Aufbau des Notenspiegels je Hochschule (`UniversityProfile.gradeLayout`).
public enum QISGradeLayout: String, Sendable, Hashable, Codable {
    /// QIS der LUH (QISParser.grades, Kopfzeile in den ersten Zeilen)
    case luh
    /// LSF Hildesheim (`GradeRows`, qis.parse_grade_rows)
    case hildesheim

    /// Bescheinigungs-Links (verpublish) sammeln wie `qis.PROFILES[<uni>]["documents"]`: LUH ja, Hildesheim nein
    /// (der PC speichert dort keine Bescheinigungen und kein Transcript).
    public var collectsDocuments: Bool {
        switch self {
        case .luh: return true
        case .hildesheim: return false
        }
    }
}

extension QISPage {
    /// Leistungen aller Tabellen der Seite nach dem Aufbau der Hochschule (LUH unveraendert). Stammdaten-Tabellen
    /// verwirft schon `QISPage.parse`.
    public func grades(abschluss: String = "", layout: QISGradeLayout) -> [QISGrade] {
        switch layout {
        case .luh: return grades(abschluss: abschluss)
        case .hildesheim: return QISParser.merge(tables.flatMap { GradeRows.parse(rows: $0.rows.map { $0.map(\.text) }, abschluss: abschluss) })
        }
    }

    /// Anzahl der Tabellen mit Leistungs-Kopfzeile nach dem Aufbau der Hochschule.
    public func gradeTableCount(layout: QISGradeLayout) -> Int {
        switch layout {
        case .luh: return gradeTableCount
        case .hildesheim: return tables.filter { t in t.rows.contains { GradeRows.isHeader(GradeRows.headerMap($0.map(\.text))) } }.count
        }
    }
}
