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

    /// `qis._header_map`: erstes Wort jeder Spalte -> Feldname
    static func headerMap(_ cells: [String]) -> [String?] {
        cells.map { h in
            let words = HText.replace(nonWordRE, in: h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), with: " ")
                .split(separator: " ")
            return words.first.flatMap { headers[String($0)] }
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
            guard let text = fields["text"], !text.isEmpty, !note.isEmpty || !status.isEmpty else { continue }
            out.append(QISGrade(pruefungsnr: fields["pruefungsnr"], text: text, semester: fields["semester"], note: fields["note"],
                                status: fields["status"], credits: fields["credits"], versuch: fields["versuch"], datum: fields["datum"],
                                abschluss: ab, raw: cells.joined(separator: " | ")))
        }
        return out
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
