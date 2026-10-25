import Foundation

/// Notenspiegel-Tabellen (HIS QIS/LSF) als Zeilen von Zellentexten -> Leistungen (`qis.parse_grade_rows`).
/// Hildesheim: vor der Kopfzeile steht "Abschluss: ...", Spalten "Prüfungsnr." / "Bezeichnung der Leistung ...",
/// mehrere Abschluesse in einer Tabelle, Modulzeilen ohne Note/Status und "Prüfung vorhanden" sind keine Leistungen.
/// Stammdaten (Name, Anschrift, Matrikelnummer) stehen ausserhalb dieser Tabellen und werden nie gelesen.
public enum GradeRows {

    public struct Grade: Sendable, Equatable {
        public var abschluss: String
        public var raw: String
        public var fields: [String: String]       // pruefungsnr, text, semester, note, status, credits, versuch, datum

        public subscript(_ key: String) -> String? { fields[key] }
    }

    static let headers: [String: String] = [
        "bezeichnung": "text", "leistung": "text", "prüfungsnr": "pruefungsnr", "nr": "pruefungsnr", "prüfungstext": "text",
        "text": "text", "semester": "semester", "note": "note", "status": "status", "credits": "credits", "ects": "credits",
        "bonus": "credits", "versuch": "versuch", "vermerk": "status", "datum": "datum", "prüfungsdatum": "datum",
    ]
    private static let nonWordRE = HText.regex("[^\\wäöüß]+")
    private static let abschlussRE = HText.regex("^(Abschluss:.*?PO-Version:\\s*\\d+)", [.caseInsensitive])

    static func headerMap(_ cells: [String]) -> [String?] {
        cells.map { h in
            let words = HText.replace(nonWordRE, in: h.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), with: " ")
                .split(separator: " ")
            return words.first.flatMap { headers[String($0)] }
        }
    }

    public static func parse(rows: [[String]], abschluss: String = "") -> [Grade] {
        var out: [Grade] = []
        var mapped: [String?]?
        var ab = abschluss
        for rawCells in rows {
            let cells = rawCells.map { HText.collapse($0) }
            let joined = cells.filter { !$0.isEmpty }.joined(separator: " ")
            if joined.lowercased().hasPrefix("abschluss:") {
                let found = HText.match(abschlussRE, joined)?.groups[1] ?? nil
                ab = String((found ?? joined).prefix(160))
                mapped = nil
                continue
            }
            let hm = headerMap(cells)
            if hm.contains("text"), hm.contains("note") {
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
            if !(fields["text"] ?? "").isEmpty && (!note.isEmpty || !status.isEmpty) {
                out.append(Grade(abschluss: ab, raw: cells.joined(separator: " | "), fields: fields))
            }
        }
        return out
    }
}
